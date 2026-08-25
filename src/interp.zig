//! Tree-walking interpreter for zphp.
//!
//! Execution model:
//!   * one flat variable table per frame (globals for the top level,
//!     a fresh `Env` per function call),
//!   * control flow (`break` / `continue` / `return`) is signalled with
//!     Zig errors and caught by the nearest loop / call frame,
//!   * all runtime allocations come from an arena that lives for the
//!     whole script run — no manual refcounting, QuickJS-style simplicity
//!     without the bookkeeping.

const std = @import("std");
const ast = @import("ast.zig");
const valmod = @import("value.zig");
const builtins = @import("builtins.zig");

pub const Value = valmod.Value;

pub const Error = error{
    Fatal,
    Break,
    Continue,
    Return,
    OutOfMemory,
} || std.Io.Writer.Error;

pub const MAX_CALL_DEPTH: u32 = 512;

/// A single activation frame's variable table.
pub const Env = struct {
    vars: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn get(self: *const Env, name: []const u8) ?Value {
        return self.vars.get(name);
    }

    pub fn put(self: *Env, a: std.mem.Allocator, name: []const u8, v: Value) !void {
        try self.vars.put(a, name, v);
    }
};

pub const Interp = struct {
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    globals: Env = .{},
    funcs: std.StringHashMapUnmanaged(*ast.Stmt.FuncDecl) = .empty,

    // Control-flow payloads (errors cannot carry data).
    ret_val: Value = .null_,
    brk_left: u32 = 0,
    cont_left: u32 = 0,

    // Diagnostics.
    msg: []const u8 = "",
    line: u32 = 0,
    depth: u32 = 0,

    pub fn init(arena: std.mem.Allocator, out: *std.Io.Writer) Interp {
        return .{ .arena = arena, .out = out };
    }

    /// PHP hoists unconditional top-level function declarations, so a call
    /// earlier in the file than its definition still works.
    pub fn registerTopLevelFuncs(self: *Interp, prog: []const *ast.Stmt) !void {
        for (prog) |s| {
            if (s.kind == .func_decl) {
                try self.funcs.put(self.arena, s.kind.func_decl.name, &s.kind.func_decl);
            }
        }
    }

    pub fn execProgram(self: *Interp, prog: []const *ast.Stmt) Error!void {
        try self.execBlock(prog, &self.globals);
    }

    pub fn fatalF(self: *Interp, line: u32, comptime fmt: []const u8, args: anytype) Error {
        self.msg = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        self.line = line;
        return error.Fatal;
    }

    // -- statements ----------------------------------------------------------

    pub fn execBlock(self: *Interp, stmts: []const *ast.Stmt, env: *Env) Error!void {
        for (stmts) |s| try self.execStmt(s, env);
    }

    fn execStmt(self: *Interp, s: *ast.Stmt, env: *Env) Error!void {
        switch (s.kind) {
            .nop => {},
            .expr => |e| _ = try self.eval(e, env),
            .echo => |exprs| {
                for (exprs) |e| {
                    const v = try self.eval(e, env);
                    try self.out.writeAll(try valmod.toString(v, self.arena));
                }
            },
            .block => |stmts| try self.execBlock(stmts, env),
            .if_stmt => |info| {
                for (info.branches) |branch| {
                    const c = try self.eval(branch.cond, env);
                    if (c.truthy()) {
                        try self.execStmt(branch.body, env);
                        return;
                    }
                }
                if (info.else_body) |eb| try self.execStmt(eb, env);
            },
            .while_stmt => |w| {
                while (true) {
                    const c = try self.eval(w.cond, env);
                    if (!c.truthy()) break;
                    if ((try self.runLoopBody(w.body, env)) == .brk) break;
                }
            },
            .do_while => |dw| {
                while (true) {
                    if ((try self.runLoopBody(dw.body, env)) == .brk) break;
                    const c = try self.eval(dw.cond, env);
                    if (!c.truthy()) break;
                }
            },
            .for_stmt => |f| {
                for (f.init) |e| _ = try self.eval(e, env);
                while (true) {
                    if (f.cond) |c| {
                        const cv = try self.eval(c, env);
                        if (!cv.truthy()) break;
                    }
                    if ((try self.runLoopBody(f.body, env)) == .brk) break;
                    for (f.step) |e| _ = try self.eval(e, env);
                }
            },
            .foreach => |fe| {
                var subject = try self.eval(fe.subject, env);
                if (subject == .null_) subject = .{ .array_ = try Value.Array.create(self.arena) };
                if (subject != .array_) {
                    return self.fatalF(s.line, "foreach() argument must be of type array, {s} given", .{subject.typeName()});
                }
                const arr = subject.array_;
                // Snapshot so the body can safely mutate the array.
                const snapshot = try self.arena.dupe(Value.Array.Entry, arr.entries.items);
                for (snapshot) |entry| {
                    if (fe.key) |k| try env.put(self.arena, k, entry.key.toValue());
                    try env.put(self.arena, fe.val, entry.val);
                    if ((try self.runLoopBody(fe.body, env)) == .brk) break;
                }
            },
            .func_decl => |fd| {
                // Conditional declarations register when execution reaches them.
                try self.funcs.put(self.arena, fd.name, &s.kind.func_decl);
            },
            .ret => |e| {
                self.ret_val = if (e) |expr| try self.eval(expr, env) else .null_;
                return error.Return;
            },
            .brk => |level| {
                self.brk_left = level;
                return error.Break;
            },
            .cont => |level| {
                self.cont_left = level;
                return error.Continue;
            },
        }
    }

    /// Execute a loop body, translating break/continue levels.
    /// Returns `.brk` when this loop must terminate now.
    fn runLoopBody(self: *Interp, body: *ast.Stmt, env: *Env) Error!enum { none, brk } {
        self.execStmt(body, env) catch |err| switch (err) {
            error.Break => {
                if (self.brk_left > 1) {
                    self.brk_left -= 1;
                    return error.Break; // propagate to outer loop
                }
                self.brk_left = 0;
                return .brk; // this loop exits
            },
            error.Continue => {
                if (self.cont_left > 1) {
                    self.cont_left -= 1;
                    return error.Continue; // propagate to outer loop
                }
                self.cont_left = 0;
                return .none; // next iteration
            },
            else => return err,
        };
        return .none;
    }

    // -- expressions -----------------------------------------------------------

    pub fn eval(self: *Interp, e: *ast.Expr, env: *Env) Error!Value {
        switch (e.kind) {
            .int_lit => |i| return .{ .int_ = i },
            .float_lit => |f| return .{ .float_ = f },
            .str_lit => |s| return .{ .str_ = s },
            .bool_lit => |b| return .{ .bool_ = b },
            .null_lit => return .null_,
            .var_ref => |name| {
                return env.get(name) orelse .null_;
            },
            .interp_str => |parts| {
                var buf: std.ArrayList(u8) = .empty;
                for (parts) |part| {
                    switch (part) {
                        .literal => |lit| try buf.appendSlice(self.arena, lit),
                        .var_ref => |name| {
                            const v = env.get(name) orelse .null_;
                            try buf.appendSlice(self.arena, try valmod.toString(v, self.arena));
                        },
                        .var_index => |vi| {
                            const v = try self.readVarIndex(vi.name, vi.keys, e.line, env);
                            try buf.appendSlice(self.arena, try valmod.toString(v, self.arena));
                        },
                    }
                }
                return .{ .str_ = buf.items };
            },
            .array_lit => |items| {
                const arr = try Value.Array.create(self.arena);
                for (items) |item| {
                    const v = try self.eval(item.val, env);
                    if (item.key) |ke| {
                        const kv = try self.eval(ke, env);
                        if (kv == .array_) return self.fatalF(e.line, "illegal array key of type array", .{});
                        try arr.set(self.arena, try valmod.makeKey(kv, self.arena), v);
                    } else {
                        try arr.appendVal(self.arena, v);
                    }
                }
                return .{ .array_ = arr };
            },
            .unary => |u| return self.evalUnary(u.op, u.operand, e.line, env),
            .binary => |b| return self.evalBinary(b.op, b.lhs, b.rhs, e.line, env),
            .ternary => |tn| {
                const c = try self.eval(tn.cond, env);
                if (c.truthy()) {
                    if (tn.then) |then_e| return self.eval(then_e, env);
                    return c; // shorthand `$a ?: b`
                }
                return self.eval(tn.els, env);
            },
            .assign => |a| return self.evalAssign(a.target, a.op, a.value, e.line, env),
            .inc_dec => |d| return self.evalIncDec(d.target, d.up, d.postfix, e.line, env),
            .call => |c| return self.evalCall(c.name, c.args, e.line, env),
            .index => |ix| {
                const base = try self.eval(ix.base, env);
                return self.indexRead(base, ix.index, e.line, env);
            },
            .isset => |exprs| {
                for (exprs) |x| {
                    if (!(try self.evalIsset(x, env))) return .{ .bool_ = false };
                }
                return .{ .bool_ = true };
            },
            .empty => |x| {
                const v = try self.evalOrNull(x, env);
                return .{ .bool_ = !v.truthy() };
            },
        }
    }

    /// Evaluate an expression treating undefined variables as null instead
    /// of raising warnings (isset/empty semantics).
    fn evalOrNull(self: *Interp, e: *ast.Expr, env: *Env) Error!Value {
        switch (e.kind) {
            .var_ref => |name| return env.get(name) orelse .null_,
            .index => |ix| {
                const base = env_or: {
                    if (ix.base.kind == .var_ref) {
                        break :env_or env.get(ix.base.kind.var_ref) orelse .null_;
                    }
                    break :env_or try self.eval(ix.base, env);
                };
                if (base == .null_) return .null_;
                return self.indexRead(base, ix.index, e.line, env);
            },
            else => return self.eval(e, env),
        }
    }

    fn evalIsset(self: *Interp, e: *ast.Expr, env: *Env) Error!bool {
        const v = try self.evalOrNull(e, env);
        return v != .null_;
    }

    fn readVarIndex(
        self: *Interp,
        name: []const u8,
        keys: []const ast.IndexKey,
        line: u32,
        env: *Env,
    ) Error!Value {
        var base = env.get(name) orelse return .null_;
        for (keys) |key| {
            const kv: Value = switch (key) {
                .str => |ks| .{ .str_ = ks },
                .int => |iv| .{ .int_ = iv },
            };
            base = try self.indexReadValue(base, kv, line);
        }
        return base;
    }

    /// Shared index read used by both expression indexing and interpolation.
    fn indexReadValue(self: *Interp, base: Value, key_v: Value, line: u32) Error!Value {
        switch (base) {
            .array_ => |arr| {
                if (key_v == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                return arr.get(try valmod.makeKey(key_v, self.arena)) orelse .null_;
            },
            .str_ => |s| {
                if (key_v != .int_ and key_v != .float_) return .{ .str_ = "" };
                const i_f = valmod.toNumber(key_v).toFloat();
                if (i_f < 0 or i_f >= @as(f64, @floatFromInt(s.len))) return .{ .str_ = "" };
                const i: usize = @intFromFloat(i_f);
                return .{ .str_ = s[i .. i + 1] };
            },
            .null_ => return .null_, // reading from null yields null
            else => return self.fatalF(line, "cannot use {s} value as array", .{base.typeName()}),
        }
    }

    fn indexRead(self: *Interp, base: Value, index: ?*ast.Expr, line: u32, env: *Env) Error!Value {
        switch (base) {
            .array_ => |arr| {
                const ke = index orelse return self.fatalF(line, "cannot read from array without an index", .{});
                const kv = try self.eval(ke, env);
                if (kv == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                return arr.get(try valmod.makeKey(kv, self.arena)) orelse .null_;
            },
            .str_ => |s| {
                const ke = index orelse return self.fatalF(line, "cannot read from string without an index", .{});
                const kv = try self.eval(ke, env);
                // Only numeric offsets index strings; anything else reads as
                // "" (matching the VM; PHP warns).
                if (kv != .int_ and kv != .float_) return .{ .str_ = "" };
                const i_f = valmod.toNumber(kv).toFloat();
                if (i_f < 0 or i_f >= @as(f64, @floatFromInt(s.len))) return .{ .str_ = "" };
                const i: usize = @intFromFloat(i_f);
                return .{ .str_ = s[i .. i + 1] };
            },
            .null_ => return .null_, // reading from null yields null
            else => return self.fatalF(line, "cannot use {s} value as array", .{base.typeName()}),
        }
    }

    fn evalUnary(self: *Interp, op: ast.UnOp, operand_e: *ast.Expr, line: u32, env: *Env) Error!Value {
        const v = try self.eval(operand_e, env);
        switch (op) {
            .not => return .{ .bool_ = !v.truthy() },
            .neg => {
                const n = valmod.toNumber(v);
                return switch (n) {
                    .int => |i| .{ .int_ = -i },
                    .float => |f| .{ .float_ = -f },
                };
            },
            .pos => {
                const n = valmod.toNumber(v);
                return switch (n) {
                    .int => |i| .{ .int_ = i },
                    .float => |f| .{ .float_ = f },
                };
            },
            .bit_not => {
                const n = valmod.toNumber(v);
                return switch (n) {
                    .int => |i| .{ .int_ = ~i },
                    .float => return self.fatalF(line, "unsupported operand type for ~", .{}),
                };
            },
        }
    }

    fn evalBinary(self: *Interp, op: ast.BinOp, lhs_e: *ast.Expr, rhs_e: *ast.Expr, line: u32, env: *Env) Error!Value {
        // Short-circuit operators evaluate lazily.
        switch (op) {
            .logic_and => {
                const l = try self.eval(lhs_e, env);
                if (!l.truthy()) return .{ .bool_ = false };
                return .{ .bool_ = (try self.eval(rhs_e, env)).truthy() };
            },
            .logic_or => {
                const l = try self.eval(lhs_e, env);
                if (l.truthy()) return .{ .bool_ = true };
                return .{ .bool_ = (try self.eval(rhs_e, env)).truthy() };
            },
            .coalesce => {
                const l = try self.evalOrNullCoalesce(lhs_e, env);
                if (l != .null_) return l;
                return self.eval(rhs_e, env);
            },
            else => {},
        }

        const l = try self.eval(lhs_e, env);
        const r = try self.eval(rhs_e, env);

        switch (op) {
            .add => return self.arith(.add, l, r, line),
            .sub => return self.arith(.sub, l, r, line),
            .mul => return self.arith(.mul, l, r, line),
            .div => return self.arith(.div, l, r, line),
            .mod => return self.arith(.mod, l, r, line),
            .pow => return self.arith(.pow, l, r, line),
            .concat => {
                const ls = try valmod.toString(l, self.arena);
                const rs = try valmod.toString(r, self.arena);
                return .{ .str_ = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ ls, rs }) };
            },
            .eq => return .{ .bool_ = try valmod.looseEq(l, r, self.arena) },
            .neq => return .{ .bool_ = !(try valmod.looseEq(l, r, self.arena)) },
            .identical => return .{ .bool_ = valmod.strictEq(l, r) },
            .not_identical => return .{ .bool_ = !valmod.strictEq(l, r) },
            .spaceship => {
                const ord = try valmod.looseCmp(l, r, self.arena);
                return .{ .int_ = switch (ord) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                } };
            },
            .lt => return .{ .bool_ = (try valmod.looseCmp(l, r, self.arena)) == .lt },
            .gt => return .{ .bool_ = (try valmod.looseCmp(l, r, self.arena)) == .gt },
            .lte => return .{ .bool_ = (try valmod.looseCmp(l, r, self.arena)) != .gt },
            .gte => return .{ .bool_ = (try valmod.looseCmp(l, r, self.arena)) != .lt },
            .logic_xor => return .{ .bool_ = l.truthy() != r.truthy() },
            .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                const li = try self.wantIntOperand(l, line, op);
                const ri = try self.wantIntOperand(r, line, op);
                return switch (op) {
                    .bit_and => .{ .int_ = li & ri },
                    .bit_or => .{ .int_ = li | ri },
                    .bit_xor => .{ .int_ = li ^ ri },
                    .shl => blk: {
                        if (ri < 0 or ri > 63) break :blk .{ .int_ = 0 };
                        break :blk .{ .int_ = li << @intCast(ri) };
                    },
                    .shr => blk: {
                        if (ri < 0 or ri > 63) break :blk .{ .int_ = if (li < 0) -1 else 0 };
                        break :blk .{ .int_ = li >> @intCast(ri) };
                    },
                    else => unreachable,
                };
            },
            else => unreachable,
        }
    }

    /// `??` needs isset-style semantics on its left side.
    fn evalOrNullCoalesce(self: *Interp, e: *ast.Expr, env: *Env) Error!Value {
        return self.evalOrNull(e, env);
    }

    fn wantIntOperand(self: *Interp, v: Value, line: u32, op: anytype) Error!i64 {
        if (v == .float_) return self.fatalF(line, "unsupported operand types for bitwise operator", .{});
        _ = op;
        return valmod.toNumber(v).int;
    }

    const ArithKind = enum { add, sub, mul, div, mod, pow };

    fn arith(self: *Interp, kind: ArithKind, l: Value, r: Value, line: u32) Error!Value {
        if (l == .array_ or r == .array_) {
            // array + array is union in PHP; not supported in the minimal core.
            return self.fatalF(line, "unsupported operand types: {s} and {s}", .{ l.typeName(), r.typeName() });
        }
        const ln = valmod.toNumber(l);
        const rn = valmod.toNumber(r);

        // Integer path when both sides are ints.
        if (ln == .int and rn == .int) {
            const a = ln.int;
            const b = rn.int;
            switch (kind) {
                .add => {
                    const res = @addWithOverflow(a, b);
                    if (res[1] == 0) return .{ .int_ = res[0] };
                    return .{ .float_ = @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b)) };
                },
                .sub => {
                    const res = @subWithOverflow(a, b);
                    if (res[1] == 0) return .{ .int_ = res[0] };
                    return .{ .float_ = @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b)) };
                },
                .mul => {
                    const res = @mulWithOverflow(a, b);
                    if (res[1] == 0) return .{ .int_ = res[0] };
                    return .{ .float_ = @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b)) };
                },
                .div => {
                    if (b == 0) return self.fatalF(line, "Division by zero", .{});
                    if (@rem(a, b) == 0) return .{ .int_ = @divTrunc(a, b) };
                    return .{ .float_ = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b)) };
                },
                .mod => {
                    if (b == 0) return self.fatalF(line, "Modulo by zero", .{});
                    return .{ .int_ = @rem(a, b) };
                },
                .pow => {
                    if (b >= 0 and b <= 62) {
                        return .{ .int_ = ipow(a, b) };
                    }
                    const f = std.math.pow(f64, @floatFromInt(a), @floatFromInt(b));
                    return .{ .float_ = f };
                },
            }
        }

        // Float path.
        const a = ln.toFloat();
        const b = rn.toFloat();
        return switch (kind) {
            .add => .{ .float_ = a + b },
            .sub => .{ .float_ = a - b },
            .mul => .{ .float_ = a * b },
            .div => blk: {
                if (b == 0.0) return self.fatalF(line, "Division by zero", .{});
                break :blk .{ .float_ = a / b };
            },
            .mod => blk: {
                if (b == 0.0) return self.fatalF(line, "Modulo by zero", .{});
                break :blk .{ .int_ = @rem(@as(i64, @intFromFloat(@trunc(a))), @as(i64, @intFromFloat(@trunc(b)))) };
            },
            .pow => .{ .float_ = std.math.pow(f64, a, b) },
        };
    }

    fn ipow(base: i64, exp: i64) i64 {
        var result: i64 = 1;
        var b = base;
        var e: u6 = @intCast(exp);
        while (e > 0) : (e -= 1) result *|= b;
        _ = &b;
        return result;
    }

    // -- assignment ----------------------------------------------------------

    fn evalAssign(self: *Interp, target: *ast.Expr, op: ast.AssignOp, value_e: *ast.Expr, line: u32, env: *Env) Error!Value {
        switch (target.kind) {
            .var_ref => |name| {
                var new_v: Value = undefined;
                if (op == .coalesce) {
                    const existing = env.get(name) orelse .null_;
                    if (existing != .null_) return existing;
                    new_v = try self.eval(value_e, env);
                } else {
                    const rhs = try self.eval(value_e, env);
                    new_v = if (op == .assign)
                        rhs
                    else
                        try self.applyCompound(op, env.get(name) orelse .null_, rhs, line);
                }
                try env.put(self.arena, name, new_v);
                return new_v;
            },
            .index => |ix| {
                // Resolve (auto-vivifying) the container array.
                const container = try self.resolveContainer(ix.base, line, env);
                if (ix.index) |ke| {
                    const kv = try self.eval(ke, env);
                    if (kv == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const key = try valmod.makeKey(kv, self.arena);
                    var new_v: Value = undefined;
                    if (op == .coalesce) {
                        const existing = container.get(key) orelse .null_;
                        if (existing != .null_) return existing;
                        new_v = try self.eval(value_e, env);
                    } else {
                        const rhs = try self.eval(value_e, env);
                        new_v = if (op == .assign)
                            rhs
                        else
                            try self.applyCompound(op, container.get(key) orelse .null_, rhs, line);
                    }
                    try container.set(self.arena, key, new_v);
                    return new_v;
                } else {
                    // $a[] = v — append
                    if (op != .assign) return self.fatalF(line, "[] operator supports only append assignment", .{});
                    const rhs = try self.eval(value_e, env);
                    try container.appendVal(self.arena, rhs);
                    return rhs;
                }
            },
            else => return self.fatalF(line, "invalid assignment target", .{}),
        }
    }

    fn applyCompound(self: *Interp, op: ast.AssignOp, old: Value, rhs: Value, line: u32) Error!Value {
        return switch (op) {
            .assign => rhs,
            .add => try self.arith(.add, old, rhs, line),
            .sub => try self.arith(.sub, old, rhs, line),
            .mul => try self.arith(.mul, old, rhs, line),
            .div => try self.arith(.div, old, rhs, line),
            .mod => try self.arith(.mod, old, rhs, line),
            .pow => try self.arith(.pow, old, rhs, line),
            .concat => blk: {
                const os = try valmod.toString(old, self.arena);
                const rs = try valmod.toString(rhs, self.arena);
                break :blk .{ .str_ = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ os, rs }) };
            },
            .coalesce => if (old != .null_) old else rhs,
        };
    }

    /// Walk an lvalue chain ($a, $a[k], $a[k][j], ...) and return the
    /// innermost array, auto-vivifying missing slots like PHP does.
    fn resolveContainer(self: *Interp, e: *ast.Expr, line: u32, env: *Env) Error!*Value.Array {
        switch (e.kind) {
            .var_ref => |name| {
                if (env.get(name)) |v| {
                    switch (v) {
                        .array_ => |arr| return arr,
                        .null_ => {},
                        else => return self.fatalF(line, "cannot use a {s} value as an array", .{v.typeName()}),
                    }
                }
                const arr = try Value.Array.create(self.arena);
                try env.put(self.arena, name, .{ .array_ = arr });
                return arr;
            },
            .index => |ix| {
                const parent = try self.resolveContainer(ix.base, line, env);
                if (ix.index) |ke| {
                    const kv = try self.eval(ke, env);
                    if (kv == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const key = try valmod.makeKey(kv, self.arena);
                    const existing = parent.get(key);
                    switch (existing orelse .null_) {
                        .array_ => |arr| return arr,
                        .null_ => {
                            const arr = try Value.Array.create(self.arena);
                            try parent.set(self.arena, key, .{ .array_ = arr });
                            return arr;
                        },
                        else => |v| return self.fatalF(line, "cannot use a {s} value as an array", .{v.typeName()}),
                    }
                } else {
                    return self.fatalF(line, "cannot append to nested index during auto-vivification", .{});
                }
            },
            else => return self.fatalF(line, "invalid assignment target", .{}),
        }
    }

    fn evalIncDec(self: *Interp, target: *ast.Expr, up: bool, postfix: bool, line: u32, env: *Env) Error!Value {
        // Read current value.
        const old: Value = switch (target.kind) {
            .var_ref => |name| env.get(name) orelse .null_,
            .index => |ix| blk: {
                const base = try self.eval(ix.base, env);
                break :blk try self.indexRead(base, ix.index, line, env);
            },
            else => return self.fatalF(line, "invalid increment/decrement target", .{}),
        };

        // Compute next value (PHP rules: null++ -> 1, non-numeric strings
        // unchanged, floats step by 1).
        const next: Value = blk: {
            if (old == .null_) break :blk if (up) Value{ .int_ = 1 } else Value.null_;
            if (old == .str_) {
                // Non-numeric strings are left untouched (PHP semantics).
                if (valmod.numericString(old.str_) == null) break :blk old;
            }
            const n = valmod.toNumber(old);
            break :blk switch (n) {
                .int => |i| .{ .int_ = if (up) i +% 1 else i -% 1 },
                .float => |f| .{ .float_ = if (up) f + 1 else f - 1 },
            };
        };

        // Write back.
        switch (target.kind) {
            .var_ref => |name| try env.put(self.arena, name, next),
            .index => |ix| {
                const base = try self.eval(ix.base, env);
                if (base == .array_) {
                    const ke = ix.index orelse return self.fatalF(line, "cannot increment without an index", .{});
                    const kv = try self.eval(ke, env);
                    try base.array_.set(self.arena, try valmod.makeKey(kv, self.arena), next);
                }
            },
            else => unreachable,
        }

        return if (postfix) old else next;
    }

    // -- calls -----------------------------------------------------------------

    fn evalCall(self: *Interp, name: []const u8, args_e: []const *ast.Expr, line: u32, env: *Env) Error!Value {
        // Evaluate arguments eagerly.
        const args = try self.arena.alloc(Value, args_e.len);
        for (args_e, 0..) |ae, i| args[i] = try self.eval(ae, env);

        // User-defined functions shadow nothing; check them first.
        if (self.funcs.get(name)) |fd| {
            return self.callUser(fd, @constCast(args), line);
        }

        // The reference tree engine has no builtin access (parity snippets
        // avoid them); the bytecode VM hosts builtins.
        _ = &args;
        return self.fatalF(line, "Call to undefined function {s}()", .{name});
    }

    fn callUser(self: *Interp, fd: *ast.Stmt.FuncDecl, args: []const Value, line: u32) Error!Value {
        if (args.len > fd.params.len) {
            return self.fatalF(line, "{s}() expects at most {d} argument(s), {d} given", .{ fd.name, fd.params.len, args.len });
        }
        if (self.depth >= MAX_CALL_DEPTH) {
            return self.fatalF(line, "Maximum function nesting level of {d} reached, aborting", .{MAX_CALL_DEPTH});
        }

        var local = Env{};
        for (fd.params, 0..) |param, i| {
            if (i < args.len) {
                try local.put(self.arena, param.name, args[i]);
            } else if (param.default) |de| {
                try local.put(self.arena, param.name, try self.eval(de, &local));
            } else {
                return self.fatalF(line, "Too few arguments to function {s}()", .{fd.name});
            }
        }

        self.depth += 1;
        defer self.depth -= 1;

        self.execBlock(fd.body, &local) catch |err| switch (err) {
            error.Return => return self.ret_val,
            else => return err,
        };
        return .null_;
    }
};
