//! Register-based bytecode VM for zphp.
//!
//! Execution model (QuickJS-flavored):
//!   * each frame owns a flat register file: locals at [0..nlocals),
//!     expression temporaries above,
//!   * no operand stack — three-address instructions read and write
//!     registers directly,
//!   * calls place arguments in consecutive caller registers; the callee's
//!     return value overwrites the first argument register,
//!   * hidden per-frame storage hosts foreach snapshot iterators.

const std = @import("std");
const valmod = @import("value.zig");
const opcode = @import("opcode.zig");
const chunkmod = @import("chunk.zig");
const compiler_mod = @import("compiler.zig");
const builtins = @import("builtins.zig");

const Op = opcode.Op;
const Value = valmod.Value;
const Func = chunkmod.Func;

pub const Error = error{
    Fatal,
    Thrown,
    OutOfMemory,
} || std.Io.Writer.Error;

pub const MAX_CALL_DEPTH: u32 = 512;

pub const Vm = struct {
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    /// Warning stream (stderr); null disables warnings.
    err: ?*std.Io.Writer,
    program: *compiler_mod.Program,
    /// Functions registered so far (conditional declarations register when
    /// execution reaches them).
    funcs: std.StringHashMapUnmanaged(*Func) = .empty,
    /// Classes whose declaration statement has executed.
    declared_classes: std.StringHashMapUnmanaged(void) = .empty,

    frames: std.ArrayList(Frame) = .empty,
    /// Pooled register files for call frames (bounded recycling).
    reg_pool: std.ArrayList([]Value) = .empty,
    /// Pending exception during unwinding (null when not throwing).
    pending_ex: ?*valmod.Object = null,

    // Diagnostics.
    msg: []const u8 = "",
    line: u32 = 0,

    const Frame = struct {
        func: *Func,
        ip: usize,
        regs: []Value,
        /// foreach snapshot/cursor pairs, indexed by hidden id.
        hidden: []Value,
        /// Active try regions (stack; top = innermost).
        tries: std.ArrayList(usize) = .empty,
        /// Where to store this frame's return value in the CALLER's registers.
        result_reg: u32,
    };

    pub fn init(arena: std.mem.Allocator, out: *std.Io.Writer, err: ?*std.Io.Writer, program: *compiler_mod.Program) Vm {
        var vm = Vm{ .arena = arena, .out = out, .err = err, .program = program };
        // Preload only unconditional top-level declarations (PHP hoisting);
        // conditional ones register via declare_func when execution reaches
        // them.
        var it = program.hoisted.keyIterator();
        while (it.next()) |key| {
            if (program.funcs.get(key.*)) |f| {
                vm.funcs.put(arena, key.*, f) catch {};
            }
        }
        var cit = program.hoisted_classes.keyIterator();
        while (cit.next()) |key| {
            vm.declared_classes.put(arena, key.*, {}) catch {};
        }
        // (Baseline JIT removed — see docs/JIT_DESIGN.md for the post-mortem.)

        // Resolve parent links (all classes are compiled by now) and set up
        // static property storage flattened with parent defaults.
        var pit = program.classes.iterator();
        while (pit.next()) |entry| {
            const info = entry.value_ptr.*;
            if (info.parent_name) |pname| info.parent = program.classes.get(pname);
        }
        var sit = program.classes.iterator();
        while (sit.next()) |entry| {
            const info = entry.value_ptr.*;
            if (!info.is_interface and info.statics == null) {
                const map = arena.create(std.StringHashMapUnmanaged(Value)) catch continue;
                map.* = .empty;
                // Parent-first flattening.
                var chain: [64]*compiler_mod.ClassInfo = undefined;
                var depth: usize = 0;
                var c2: ?*compiler_mod.ClassInfo = info;
                while (c2) |cl| : (c2 = cl.parent) {
                    if (depth >= 64) break;
                    chain[depth] = cl;
                    depth += 1;
                }
                var di: usize = depth;
                while (di > 0) {
                    di -= 1;
                    for (chain[di].static_defaults) |p| {
                        map.put(arena, p.name, p.default) catch {};
                    }
                }
                info.statics = map;
                // Interfaces in the chain need statics maps too? no.
            }
        }
        return vm;
    }

    pub fn fatalF(self: *Vm, line: u32, comptime fmt: []const u8, args: anytype) Error {
        self.msg = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        self.line = line;
        return error.Fatal;
    }

    /// Emit a PHP-style warning to stderr (stdout output is unaffected).
    fn warn(self: *Vm, line: u32, comptime fmt: []const u8, args: anytype) void {
        const e = self.err orelse return;
        e.print("Warning: " ++ fmt ++ " in zphp on line {d}\n", args ++ .{line}) catch {};
    }

    fn newFrameRegs(self: *Vm, f: *Func) Error![]Value {
        const need = f.nlocals + f.ntemps;
        // Reuse a pooled register file when one is big enough.
        if (self.reg_pool.items.len > 0) {
            const last = self.reg_pool.items[self.reg_pool.items.len - 1];
            if (last.len >= need) {
                _ = self.reg_pool.pop();
                for (last[0..f.nlocals]) |*r| r.* = .null_;
                return last[0..need];
            }
        }
        const regs = try self.arena.alloc(Value, need);
        // Locals must start as null (undefined-variable semantics);
        // temporaries are always written before read, so leaving them
        // uninitialized is safe.
        for (regs[0..f.nlocals]) |*r| r.* = .null_;
        return regs;
    }

    /// Execute the program (main function) to completion.
    pub fn run(self: *Vm) Error!void {
        const mainf = self.program.main_func;
        try self.frames.ensureTotalCapacity(self.arena, MAX_CALL_DEPTH + 4);
        try self.frames.append(self.arena, .{
            .func = mainf,
            .ip = 0,
            .regs = try self.newFrameRegs(mainf),
            .hidden = try self.arena.alloc(Value, mainf.nhidden),
            .result_reg = opcode.no_reg,
        });
        try self.runFrame();
    }

    /// Run frames until the bottom frame returns. An exception escaping the
    /// top-level script becomes an uncaught fatal.
    fn runFrame(self: *Vm) Error!void {
        while (self.frames.items.len > 0) {
            self.dispatch() catch |e| switch (e) {
                error.Thrown => {
                    // Unwind main-frame regions first (top-level try).
                    const f = &self.frames.items[self.frames.items.len - 1];
                    if (self.unwindToRegion()) |handler_ip| {
                        f.ip = handler_ip;
                        continue;
                    }
                    if (self.pending_ex) |ex| {
                        const msg = try valmod.toString(ex.get("message") orelse .null_, self.arena);
                        const eline: u32 = switch (ex.get("line") orelse .null_) {
                            .int_ => |i| @intCast(@max(i, 0)),
                            else => 0,
                        };
                        return self.fatalF(eline, "Uncaught {s}: {s}", .{ ex.class_name, msg });
                    }
                    return e;
                },
                else => return e,
            };
        }
    }

    /// Run the top frame until it returns or calls deeper.
    ///
    /// NOTE: `f` is re-derived at the top of every iteration — nested calls
    /// append to `frames`, and an ArrayList realloc would otherwise leave
    /// this pointer dangling (latent bug that silently corrupted execution).
    fn dispatch(self: *Vm) Error!void {
        // SAFETY: run() pre-reserves capacity for MAX_CALL_DEPTH frames, so
        // the frames storage never reallocates during execution and this
        // pointer stays valid for the whole dispatch.
        var f = &self.frames.items[self.frames.items.len - 1];
        const code = f.func.chunk.code.items;
        const consts = f.func.chunk.consts.items;
        const lines = f.func.chunk.lines.items;

        while (true) {
            // Single bounds check guards both code[] and lines[] (they are
            // kept exactly parallel by Chunk.emit).
            if (f.ip >= code.len) {
                // Implicit end of function body.
                try self.popFrame(.null_);
                return;
            }
            const ins = code[f.ip];
            const line = lines[f.ip]; // bounds covered by the check above
            const regs = f.regs;
            f.ip += 1;

            switch (ins.op) {
                .ld_const => regs[ins.a] = consts[ins.b],
                .ld_null => regs[ins.a] = .null_,
                .ld_true => regs[ins.a] = .{ .bool_ = true },
                .ld_false => regs[ins.a] = .{ .bool_ = false },
                .mov => regs[ins.a] = regs[ins.b],
                .inline_arg => {}, // data word

                .declare_func => {
                    const fname = consts[ins.a].str_.data;
                    const cf = self.program.funcs.get(fname) orelse
                        return self.fatalF(line, "internal: uncompiled function", .{});
                    try self.funcs.put(self.arena, fname, cf);
                },

                .new_array => regs[ins.a] = .{ .array_ = try Value.Array.create(self.arena) },
                .append_arr => {
                    const arr = try self.wantArray(regs[ins.a], line);
                    try arr.appendVal(self.arena, regs[ins.b]);
                },
                .set_index => {
                    const arr = try self.wantArray(regs[ins.a], line);
                    if (regs[ins.b] == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const skey = try valmod.makeKey(regs[ins.b], self.arena);
                    // Write through reference cells (PHP element aliases).
                    if (arr.get(skey)) |existing| {
                        if (existing == .ref_) {
                            existing.ref_.val = regs[ins.c];
                            continue;
                        }
                    }
                    try arr.set(self.arena, skey, regs[ins.c]);
                },
                .get_index => {
                    regs[ins.a] = (try self.indexRead(regs[ins.b], regs[ins.c], line)).resolveDeep();
                },
                .isset_index => {
                    const container = regs[ins.b];
                    const key_v = regs[ins.c];
                    regs[ins.a] = .{ .bool_ = switch (container) {
                        .null_ => false,
                        .array_ => |arr| blk: {
                            if (key_v == .array_) break :blk false;
                            const found = arr.get(try valmod.makeKey(key_v, self.arena)) orelse break :blk false;
                            break :blk found != .null_;
                        },
                        .str_ => |st| key_v == .int_ and key_v.int_ >= 0 and key_v.int_ < st.data.len,
                        else => false,
                    } };
                },
                .vivify_local => {
                    switch (f.regs[ins.b]) {
                        .array_ => |arr| regs[ins.a] = .{ .array_ = arr },
                        .null_ => {
                            const arr = try Value.Array.create(self.arena);
                            f.regs[ins.b] = .{ .array_ = arr };
                            regs[ins.a] = .{ .array_ = arr };
                        },
                        else => |v| return self.fatalF(line, "cannot use a {s} value as an array", .{v.typeName()}),
                    }
                },
                .subcontainer => {
                    const parent_val = regs[ins.b];
                    if (parent_val != .array_) {
                        return self.fatalF(line, "cannot use a {s} value as an array", .{parent_val.typeName()});
                    }
                    if (regs[ins.c] == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const parent = parent_val.array_;
                    const key = try valmod.makeKey(regs[ins.c], self.arena);
                    const existing: ?*Value.Array = blk: {
                        const v = parent.get(key) orelse break :blk null;
                        break :blk switch (v) {
                            .array_ => |arr| arr,
                            .null_ => null,
                            else => |vv| return self.fatalF(line, "cannot use a {s} value as an array", .{vv.typeName()}),
                        };
                    };
                    const sub = existing orelse blk: {
                        const arr = try Value.Array.create(self.arena);
                        try parent.set(self.arena, key, .{ .array_ = arr });
                        break :blk arr;
                    };
                    regs[ins.a] = .{ .array_ = sub };
                },

                .add => regs[ins.a] = try self.arithRaw(.add, regs[ins.b], regs[ins.c], line),
                .sub => regs[ins.a] = try self.arithRaw(.sub, regs[ins.b], regs[ins.c], line),
                .mul => regs[ins.a] = try self.arithRaw(.mul, regs[ins.b], regs[ins.c], line),
                .div => regs[ins.a] = try self.arithRaw(.div, regs[ins.b], regs[ins.c], line),
                .mod => regs[ins.a] = try self.arithRaw(.mod, regs[ins.b], regs[ins.c], line),
                .pow => regs[ins.a] = try self.arithRaw(.pow, regs[ins.b], regs[ins.c], line),
                .concat => {
                    // Rope cons when the left side is already string-shaped:
                    // repeated `.=`/`.` chains become O(total) instead of
                    // O(n^2) copying. Materialization is deferred until raw
                    // bytes are needed.
                    const l = regs[ins.b];
                    const r = try valmod.toString(regs[ins.c], self.arena);
                    regs[ins.a] = switch (l) {
                        .str_, .rope_ => .{ .rope_ = try valmod.Rope.cons(self.arena, l, r) },
                        else => blk: {
                            const ls = try valmod.toString(l, self.arena);
                            const joined = try std.mem.concat(self.arena, u8, &.{ ls, r });
                            break :blk .{ .str_ = try valmod.newStr(self.arena, joined) };
                        },
                    };
                },

                .bit_and => regs[ins.a] = try self.intBin(.bit_and, regs[ins.b], regs[ins.c]),
                .bit_or => regs[ins.a] = try self.intBin(.bit_or, regs[ins.b], regs[ins.c]),
                .bit_xor => regs[ins.a] = try self.intBin(.bit_xor, regs[ins.b], regs[ins.c]),
                .shl => regs[ins.a] = try self.intBin(.shl, regs[ins.b], regs[ins.c]),
                .shr => regs[ins.a] = try self.intBin(.shr, regs[ins.b], regs[ins.c]),

                .eq => regs[ins.a] = .{ .bool_ = try valmod.looseEq(regs[ins.b], regs[ins.c], self.arena) },
                .neq => regs[ins.a] = .{ .bool_ = !(try valmod.looseEq(regs[ins.b], regs[ins.c], self.arena)) },
                .lt => regs[ins.a] = .{ .bool_ = (try valmod.looseCmp(regs[ins.b], regs[ins.c], self.arena)) == .lt },
                .gt => regs[ins.a] = .{ .bool_ = (try valmod.looseCmp(regs[ins.b], regs[ins.c], self.arena)) == .gt },
                .lte => regs[ins.a] = .{ .bool_ = (try valmod.looseCmp(regs[ins.b], regs[ins.c], self.arena)) != .gt },
                .gte => regs[ins.a] = .{ .bool_ = (try valmod.looseCmp(regs[ins.b], regs[ins.c], self.arena)) != .lt },
                .spaceship => {
                    const ord = try valmod.looseCmp(regs[ins.b], regs[ins.c], self.arena);
                    regs[ins.a] = .{ .int_ = switch (ord) {
                        .lt => @as(i64, -1),
                        .eq => 0,
                        .gt => 1,
                    } };
                },
                .identical => regs[ins.a] = .{ .bool_ = try valmod.strictEq(regs[ins.b], regs[ins.c], self.arena) },
                .not_identical => regs[ins.a] = .{ .bool_ = !try valmod.strictEq(regs[ins.b], regs[ins.c], self.arena) },

                .neg => regs[ins.a] = switch (valmod.toNumber(regs[ins.b], self.arena)) {
                    .int => |i| Value{ .int_ = -i },
                    .float => |fl| Value{ .float_ = -fl },
                },
                .pos => regs[ins.a] = switch (valmod.toNumber(regs[ins.b], self.arena)) {
                    .int => |i| Value{ .int_ = i },
                    .float => |fl| Value{ .float_ = fl },
                },
                .not => regs[ins.a] = .{ .bool_ = !regs[ins.b].truthy() },
                .to_bool => regs[ins.a] = .{ .bool_ = regs[ins.b].truthy() },
                .bit_not => {
                    if (regs[ins.b] == .float_) return self.fatalF(line, "unsupported operand type for ~", .{});
                    regs[ins.a] = .{ .int_ = ~valmod.toNumber(regs[ins.b], self.arena).int };
                },
                .is_not_null => regs[ins.a] = .{ .bool_ = regs[ins.b] != .null_ },
                .declare_class => {
                    const name = consts[ins.a].str_.data;
                    self.declared_classes.put(self.arena, name, {}) catch {};
                },
                .new_obj => {
                    const cls_name = consts[ins.c].str_.data;
                    // Builtin exception classes: synthesize message/code/line.
                    if (self.program.classes.get(cls_name) == null and isBuiltinException(cls_name)) {
                        const msg: []const u8 = if (ins.a > 0)
                            try valmod.toString(f.regs[ins.b + 1], self.arena)
                        else
                            "";
                        const obj = try self.newBuiltinException(cls_name, msg, line);
                        regs[ins.b] = .{ .obj_ = obj };
                    } else {
                    if (!self.declared_classes.contains(cls_name)) {
                        return self.fatalF(line, "Class \"{s}\" not found", .{cls_name});
                    }
                    const info = self.program.classes.get(cls_name) orelse
                        return self.fatalF(line, "Class \"{s}\" not found", .{cls_name});
                    const obj = try valmod.Object.create(self.arena, cls_name);
                    // Flattened layout: parent props first.
                    var chain_buf: [64]*compiler_mod.ClassInfo = undefined;
                    var depth: usize = 0;
                    var c: ?*compiler_mod.ClassInfo = info;
                    while (c) |cl| : (c = cl.parent) {
                        if (depth >= 64) return self.fatalF(line, "inheritance chain too deep", .{});
                        chain_buf[depth] = cl;
                        depth += 1;
                    }
                    var di: usize = depth;
                    while (di > 0) {
                        di -= 1;
                        for (chain_buf[di].own_props) |p| {
                            try obj.props.append(self.arena, .{ .name = p.name, .val = p.default });
                        }
                    }
                    regs[ins.b] = .{ .obj_ = obj };
                    if (info.findMethod("__construct")) |ctor| {
                        // ctor(this, args...): instance at b, args at b+1..b+argc.
                        // Result goes nowhere: the instance stays in regs[b].
                        try self.invokeUser(ctor, ins.b + 1, ins.a, opcode.no_reg, obj, line);
                    }
                    }
                },
                .get_prop => {
                    const o = regs[ins.b];
                    if (o != .obj_) return self.fatalF(line, "attempt to read property on {s}", .{o.typeName()});
                    const name = consts[ins.c].str_.data;
                    const got: Value = o.obj_.get(name) orelse blk: {
                        self.warn(line, "Undefined property: {s}::${s}", .{ o.obj_.class_name, name });
                        break :blk .null_;
                    };
                    regs[ins.a] = got.resolveDeep();
                },
                .set_prop => {
                    const o = regs[ins.a];
                    if (o != .obj_) return self.fatalF(line, "attempt to assign property on {s}", .{o.typeName()});
                    const pname = consts[ins.b].str_.data;
                    if (o.obj_.get(pname)) |existing| {
                        if (existing == .ref_) {
                            existing.ref_.val = regs[ins.c];
                            continue;
                        }
                    }
                    try o.obj_.set(self.arena, pname, regs[ins.c]);
                },
                .call_method => {
                    const obj_val = f.regs[ins.b];
                    if (obj_val != .obj_) return self.fatalF(line, "call to member function on {s}", .{obj_val.typeName()});
                    const mname0 = consts[ins.c].str_.data;
                    // Builtin exception accessors.
                    if (isBuiltinException(obj_val.obj_.class_name)) {
                        if (std.mem.eql(u8, mname0, "getMessage")) {
                            regs[ins.b] = obj_val.obj_.get("message") orelse .null_;
                            continue;
                        }
                        if (std.mem.eql(u8, mname0, "getCode")) {
                            regs[ins.b] = obj_val.obj_.get("code") orelse .null_;
                            continue;
                        }
                        if (std.mem.eql(u8, mname0, "getLine")) {
                            regs[ins.b] = obj_val.obj_.get("line") orelse .null_;
                            continue;
                        }
                    }
                    const cls_name = obj_val.obj_.class_name;
                    const info = self.program.classes.get(cls_name) orelse
                        return self.fatalF(line, "Class \"{s}\" not found", .{cls_name});
                    const mname = consts[ins.c].str_.data;
                    const mf = info.findMethod(mname) orelse
                        return self.fatalF(line, "Call to undefined method {s}::{s}()", .{ cls_name, mname });
                    // mf(this at slot 0, params at 1..): instance in regs[b],
                    // declared args at b+1..; result overwrites regs[b].
                    try self.invokeUser(mf, ins.b + 1, ins.a, ins.b, obj_val.obj_, line);
                },
                .instanceof => {
                    const o = regs[ins.b];
                    const target = consts[ins.c].str_.data;
                    regs[ins.a] = .{ .bool_ = o == .obj_ and self.classExtends(o.obj_.class_name, target) };
                },
                .prop_pre_inc, .prop_pre_dec => {
                    const up = ins.op == .prop_pre_inc;
                    const o = regs[ins.b];
                    if (o != .obj_) return self.fatalF(line, "attempt to modify property on {s}", .{o.typeName()});
                    const k = consts[ins.c].str_.data;
                    const old = o.obj_.get(k) orelse .null_;
                    const nv = incValue(old, up, self.arena);
                    try o.obj_.set(self.arena, k, nv);
                    regs[ins.a] = nv;
                },
                .prop_post_inc, .prop_post_dec => {
                    const up = ins.op == .prop_post_inc;
                    const o = regs[ins.b];
                    if (o != .obj_) return self.fatalF(line, "attempt to modify property on {s}", .{o.typeName()});
                    const k = consts[ins.c].str_.data;
                    const old = o.obj_.get(k) orelse .null_;
                    const nv = incValue(old, up, self.arena);
                    try o.obj_.set(self.arena, k, nv);
                    regs[ins.a] = old;
                },

                // -- static members ---------------------------------------------------
                .static_get => {
                    const cls = try self.resolveStaticClass(f, consts[ins.b].str_.data, line);
                    const name = consts[ins.c].str_.data;
                    const store = staticsFor(cls);
                    regs[ins.a] = store.get(name) orelse blk: {
                        self.warn(line, "Undefined static property: {s}::${s}", .{ cls.name, name });
                        break :blk .null_;
                    };
                },
                .static_set => {
                    const cls = try self.resolveStaticClass(f, consts[ins.a].str_.data, line);
                    const name = consts[ins.b].str_.data;
                    try staticsFor(cls).put(self.arena, name, regs[ins.c]);
                },
                .static_call => {
                    const cls_ci: u32 = code[f.ip].a; // inline word
                    f.ip += 1;
                    const cls = try self.resolveStaticClass(f, consts[cls_ci].str_.data, line);
                    const mname = consts[ins.c].str_.data;
                    const mf = cls.findMethod(mname) orelse
                        return self.fatalF(line, "Call to undefined method {s}::{s}()", .{ cls.name, mname });
                    if (!mf.is_static) {
                        // PHP allows calling non-static via ::? Deprecated; fatal for clarity.
                        return self.fatalF(line, "Non-static method {s}::{s}() cannot be called statically", .{ cls.name, mname });
                    }
                    try self.invokeUser(mf, ins.b, ins.a, ins.b, null, line);
                },

                // -- exceptions -------------------------------------------------------
                .try_start => {
                    try f.tries.append(self.arena, ins.a); // handler address
                },
                .try_end => {
                    _ = f.tries.pop();
                },
                .throw_v => {
                    const v = regs[ins.b];
                    if (v != .obj_ or !self.isThrowableClass(v.obj_.class_name)) {
                        return self.fatalF(line, "Uncaught Error: Value of type {s} is not throwable", .{v.typeName()});
                    }
                    self.pending_ex = v.obj_;
                    try self.throwInCurrentFrame(f);
                },
                .bind_ref => {
                    const cell = regs[ins.b];
                    if (cell != .ref_) return self.fatalF(line, "internal: bind_ref source is not a reference", .{});
                    regs[ins.a] = cell;
                },
                .ld_ref => {
                    regs[ins.a] = regs[ins.b].resolveDeep();
                },
                .st_ref => {
                    const cur = regs[ins.a];
                    if (cur == .ref_) cur.ref_.val = regs[ins.b] else regs[ins.a] = regs[ins.b];
                },
                .make_ref_cell => {
                    if (regs[ins.b] == .ref_) {
                        regs[ins.a] = regs[ins.b];
                    } else {
                        const cell = try self.arena.create(valmod.Cell);
                        cell.* = .{ .val = regs[ins.b] };
                        const boxed: Value = .{ .ref_ = cell };
                        regs[ins.b] = boxed;
                        regs[ins.a] = boxed;
                    }
                },
                .elem_cell => {
                    const arr = try self.wantArray(regs[ins.b], line);
                    if (regs[ins.c] == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const key = try valmod.makeKey(regs[ins.c], self.arena);
                    if (arr.get(key)) |existing| {
                        if (existing == .ref_) {
                            regs[ins.a] = existing;
                            continue;
                        }
                    }
                    const cur = arr.get(key) orelse .null_;
                    const cell = try self.arena.create(valmod.Cell);
                    cell.* = .{ .val = cur };
                    try arr.set(self.arena, key, .{ .ref_ = cell });
                    regs[ins.a] = .{ .ref_ = cell };
                },
                .rethrow => {
                    if (self.pending_ex == null) return self.fatalF(line, "internal: rethrow without pending exception", .{});
                    try self.throwInCurrentFrame(f);
                },
                .catch_match => {
                    const ex = self.pending_ex.?;
                    const types = f.func.chunk.catch_types.items[ins.c];
                    var matched = false;
                    for (types) |ty| {
                        if (self.exMatches(ex.class_name, ty)) {
                            matched = true;
                            break;
                        }
                    }
                    regs[ins.a] = .{ .bool_ = matched };
                },
                .catch_store => {
                    regs[ins.a] = .{ .obj_ = self.pending_ex.? };
                    self.pending_ex = null;
                },
                .warn_undef => {
                    const name = f.func.chunk.consts.items[ins.a].str_.data;
                    self.warn(line, "Undefined variable ${s}", .{name});
                },
                .coalesce => regs[ins.a] = if (regs[ins.b] != .null_) regs[ins.b] else regs[ins.c],

                .strconcat => {
                    const base = ins.b;
                    const n = ins.c;
                    var buf: std.ArrayList(u8) = .empty;
                    for (regs[base .. base + n]) |v| {
                        try buf.appendSlice(self.arena, try valmod.toString(v, self.arena));
                    }
                    regs[ins.a] = .{ .str_ = try valmod.newStr(self.arena, buf.items) };
                },
                .echo => {
                    const base = ins.a;
                    const n = ins.b;
                    for (regs[base .. base + n]) |v| {
                        try self.out.writeAll(try valmod.toString(v, self.arena));
                    }
                },

                .inc_l => regs[ins.a] = incValue(regs[ins.a], true, self.arena),
                .dec_l => regs[ins.a] = incValue(regs[ins.a], false, self.arena),
                .post_inc_l => {
                    const old = regs[ins.b];
                    regs[ins.b] = incValue(old, true, self.arena);
                    regs[ins.a] = old;
                },
                .post_dec_l => {
                    const old = regs[ins.b];
                    regs[ins.b] = incValue(old, false, self.arena);
                    regs[ins.a] = old;
                },
                .inc_idx, .dec_idx => {
                    const up = ins.op == .inc_idx;
                    const container = try self.wantArray(regs[ins.a], line);
                    if (regs[ins.b] == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const key = try valmod.makeKey(regs[ins.b], self.arena);
                    const old = container.get(key) orelse .null_;
                    try container.set(self.arena, key, incValue(old, up, self.arena));
                },
                .post_inc_idx, .post_dec_idx => {
                    const up = ins.op == .post_inc_idx;
                    const container = try self.wantArray(regs[ins.b], line);
                    if (regs[ins.c] == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    const key = try valmod.makeKey(regs[ins.c], self.arena);
                    const old = container.get(key) orelse .null_;
                    regs[ins.a] = old;
                    try container.set(self.arena, key, incValue(old, up, self.arena));
                },

                .call => {
                    // a = argc, b = args base register, c = name const index
                    try self.doCall(consts[ins.c].str_.data, ins.a, ins.b, line);
                    return; // re-derive frame in dispatch()
                },
                .return_val => {
                    try self.popFrame(regs[ins.a]);
                    return;
                },
                .return_null => {
                    try self.popFrame(.null_);
                    return;
                },

                .foreach_init => {
                    const subject = regs[ins.c];
                    // PHP iterates a snapshot taken at loop start; in-loop
                    // mutations must not affect this iteration.
                    const snap: Value = switch (subject) {
                        .array_ => |arr| blk: {
                            const copy = try Value.Array.create(self.arena);
                            try copy.entries.appendSlice(self.arena, arr.entries.items);
                            copy.next_index = arr.next_index;
                            break :blk .{ .array_ = copy };
                        },
                        .null_ => .{ .array_ = try Value.Array.create(self.arena) },
                        else => return self.fatalF(line, "foreach() argument must be of type array, {s} given", .{subject.typeName()}),
                    };
                    f.hidden[ins.a] = snap;
                    f.hidden[ins.b] = .{ .int_ = 0 };
                },
                .foreach_next => {
                    const packed_arg = code[f.ip].a; // inline word 1
                    const target = code[f.ip + 1].a; // inline word 2
                    f.ip += 2;

                    const hid = opcode.unpackForeachHidden(packed_arg);
                    const has_key = opcode.unpackForeachHasKey(packed_arg);
                    const snapshot = f.hidden[hid].array_.entries.items;
                    const i: usize = @intCast(f.hidden[hid + 1].int_);

                    if (i >= snapshot.len) {
                        f.ip = target;
                        continue;
                    }
                    const entry = snapshot[i];
                    f.hidden[hid + 1] = .{ .int_ = @intCast(i + 1) };
                    if (has_key and ins.a != opcode.no_reg) {
                        regs[ins.a] = try entry.key.toValue(self.arena);
                    } else if (!has_key and ins.a != opcode.no_reg) {
                        return self.fatalF(line, "internal: unexpected key binding", .{});
                    }
                    if (regs[ins.b] == .ref_) regs[ins.b].ref_.val = entry.val else regs[ins.b] = entry.val;
                    continue;
                },

                .isset_local => regs[ins.a] = .{ .bool_ = f.regs[ins.b] != .null_ },

                .jmp => {
                    f.ip = ins.a;
                    continue;
                },
                .jmp_if_false => {
                    if (!regs[ins.a].truthy()) {
                        f.ip = ins.b;
                        continue;
                    }
                },
                .jmp_if_true => {
                    if (regs[ins.a].truthy()) {
                        f.ip = ins.b;
                        continue;
                    }
                },
                .if_cmp_jmp_ll => {
                    // arg = sel<<26 | b_slot<<13 | a_slot
                    const sel: opcode.CmpSel = @enumFromInt(@as(u8, @intCast((ins.a >> 26) & 0x7)));
                    const ra = ins.a & 0x1FFF;
                    const rb = (ins.a >> 13) & 0x1FFF;
                    const target = code[f.ip].a; // inline word
                    f.ip += 1;
                    if (!(try self.cmpBool(cmpSelToKind(sel), regs[ra], regs[rb]))) {
                        f.ip = target;
                        continue;
                    }
                    continue;
                },
                .if_cmp_jmp_lc => {
                    // arg = sel<<24 | slot; inline1 = const idx; inline2 = target
                    const sel: opcode.CmpSel = @enumFromInt(@as(u8, @intCast((ins.a >> 24) & 0x7)));
                    const slot = ins.a & 0xFFFFFF;
                    const const_idx = code[f.ip].a;
                    const target = code[f.ip + 1].a;
                    f.ip += 2;
                    if (!(try self.cmpBool(cmpSelToKind(sel), regs[slot], consts[const_idx]))) {
                        f.ip = target;
                        continue;
                    }
                    continue;
                },
            }
        }
    }

    fn cmpSelToKind(sel: opcode.CmpSel) CmpKind {
        return switch (sel) {
            .lt => .lt,
            .gt => .gt,
            .lte => .lte,
            .gte => .gte,
            .eq => .eq,
            .neq => .neq,
        };
    }

    fn cmpBool(self: *Vm, kind: CmpKind, l: Value, r: Value) Error!bool {
        // Fast path: int-vs-int needs no loose-comparison machinery.
        if (l == .int_ and r == .int_) {
            return switch (kind) {
                .eq => l.int_ == r.int_,
                .neq => l.int_ != r.int_,
                .lt => l.int_ < r.int_,
                .gt => l.int_ > r.int_,
                .lte => l.int_ <= r.int_,
                .gte => l.int_ >= r.int_,
            };
        }
        return switch (kind) {
            .eq => try valmod.looseEq(l, r, self.arena),
            .neq => !(try valmod.looseEq(l, r, self.arena)),
            .lt => (try valmod.looseCmp(l, r, self.arena)) == .lt,
            .gt => (try valmod.looseCmp(l, r, self.arena)) == .gt,
            .lte => (try valmod.looseCmp(l, r, self.arena)) != .gt,
            .gte => (try valmod.looseCmp(l, r, self.arena)) != .lt,
        };
    }

    const CmpKind = enum { eq, neq, lt, gt, lte, gte };

    const ArithKind = enum { add, sub, mul, div, mod, pow };
    const BitKind = enum { bit_and, bit_or, bit_xor, shl, shr };

    fn wantArray(self: *Vm, v: Value, line: u32) Error!*Value.Array {
        return switch (v) {
            .array_ => |arr| arr,
            else => self.fatalF(line, "cannot use a {s} value as an array", .{v.typeName()}),
        };
    }

    fn indexRead(self: *Vm, base: Value, key_v: Value, line: u32) Error!Value {
        switch (base) {
            .array_ => |arr| {
                if (key_v == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                const key = try valmod.makeKey(key_v, self.arena);
                if (arr.get(key)) |v| return v;
                const ks = try valmod.toString(key_v, self.arena);
                self.warn(line, "Undefined array key \"{s}\"", .{ks});
                return .null_;
            },
            .str_ => |st| {
                if (key_v != .int_ and key_v != .float_) return .{ .str_ = try valmod.newStr(self.arena, "") };
                const fl = valmod.toNumber(key_v, self.arena).toFloat();
                if (fl < 0 or fl >= @as(f64, @floatFromInt(st.data.len))) return .{ .str_ = try valmod.newStr(self.arena, "") };
                const i: usize = @intFromFloat(fl);
                return .{ .str_ = try valmod.newStr(self.arena, st.data[i .. i + 1]) };
            },
            .null_ => return .null_,
            else => return self.fatalF(line, "cannot use {s} value as array", .{base.typeName()}),
        }
    }

    fn arithRaw(self: *Vm, kind: ArithKind, l: Value, r: Value, line: u32) Error!Value {
        if (l == .array_ or r == .array_ or l == .obj_ or r == .obj_) {
            return self.fatalF(line, "unsupported operand types: {s} and {s}", .{ l.typeName(), r.typeName() });
        }
        // PHP 8 string arithmetic rules:
        //   fully numeric           -> clean
        //   leading-numeric ("5x")  -> Warning "A non-numeric value encountered"
        //   non-numeric ("abc", "") -> fatal TypeError, order-aware message
        inline for ([2]Value{ l, r }) |side| {
            switch (side) {
                .str_, .rope_ => {
                    const s = try valmod.toString(side, self.arena);
                    if (valmod.numericString(s) == null) {
                        const t = std.mem.trimStart(u8, s, " \t\n\r\x0b\x0c");
                        const has_numeric_prefix = blk: {
                            if (t.len == 0) break :blk false;
                            var i: usize = 0;
                            if (t[0] == '+' or t[0] == '-') i = 1;
                            break :blk i < t.len and (std.ascii.isDigit(t[i]) or t[i] == '.');
                        };
                        if (!has_numeric_prefix) {
                            const op_sym: []const u8 = switch (kind) {
                                .add => "+", .sub => "-", .mul => "*",
                                .div => "/", .mod => "%", .pow => "**",
                            };
                            const msg = try std.fmt.allocPrint(self.arena, "Unsupported operand types: {s} {s} {s}", .{ l.typeName(), op_sym, r.typeName() });
                            try self.throwBuiltin(line, "TypeError", msg);
                            return .null_;
                        }
                        self.warn(line, "A non-numeric value encountered", .{});
                    }
                },
                else => {},
            }
        }
        const ln = valmod.toNumber(l, self.arena);
        const rn = valmod.toNumber(r, self.arena);

        if (ln == .int and rn == .int) {
            const x = ln.int;
            const y = rn.int;
            switch (kind) {
                .add => {
                    const res = @addWithOverflow(x, y);
                    if (res[1] == 0) return .{ .int_ = res[0] };
                    return .{ .float_ = @as(f64, @floatFromInt(x)) + @as(f64, @floatFromInt(y)) };
                },
                .sub => {
                    const res = @subWithOverflow(x, y);
                    if (res[1] == 0) return .{ .int_ = res[0] };
                    return .{ .float_ = @as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(y)) };
                },
                .mul => {
                    const res = @mulWithOverflow(x, y);
                    if (res[1] == 0) return .{ .int_ = res[0] };
                    return .{ .float_ = @as(f64, @floatFromInt(x)) * @as(f64, @floatFromInt(y)) };
                },
                .div => {
                    if (y == 0) {
                        try self.throwBuiltin(line, "DivisionByZeroError", "Division by zero");
                        return .null_; // unreachable: throwBuiltin always errors
                    }
                    if (@rem(x, y) == 0) return .{ .int_ = @divTrunc(x, y) };
                    return .{ .float_ = @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y)) };
                },
                .mod => {
                    if (y == 0) return self.fatalF(line, "Modulo by zero", .{});
                    return .{ .int_ = @rem(x, y) };
                },
                .pow => {
                    if (y >= 0 and y <= 62) {
                        var result: i64 = 1;
                        var i: i64 = 0;
                        while (i < y) : (i += 1) result *|= x;
                        return .{ .int_ = result };
                    }
                    return .{ .float_ = std.math.pow(f64, @floatFromInt(x), @floatFromInt(y)) };
                },
            }
        }

        const x = ln.toFloat();
        const y = rn.toFloat();
        return switch (kind) {
            .add => .{ .float_ = x + y },
            .sub => .{ .float_ = x - y },
            .mul => .{ .float_ = x * y },
            .div => blk: {
                if (y == 0.0) return self.fatalF(line, "Division by zero", .{});
                break :blk Value{ .float_ = x / y };
            },
            .mod => blk: {
                if (y == 0.0) return self.fatalF(line, "Modulo by zero", .{});
                break :blk Value{ .int_ = @rem(@as(i64, @intFromFloat(@trunc(x))), @as(i64, @intFromFloat(@trunc(y)))) };
            },
            .pow => .{ .float_ = std.math.pow(f64, x, y) },
        };
    }

    fn intBin(self: *Vm, kind: BitKind, l: Value, r: Value) Error!Value {
        const li = valmod.toNumber(l, self.arena).int;
        const ri = valmod.toNumber(r, self.arena).int;
        const result: i64 = switch (kind) {
            .bit_and => li & ri,
            .bit_or => li | ri,
            .bit_xor => li ^ ri,
            .shl => if (ri < 0 or ri > 63) 0 else li << @intCast(ri),
            .shr => if (ri < 0 or ri > 63) (if (li < 0) @as(i64, -1) else 0) else li >> @intCast(ri),
        };
        return .{ .int_ = result };
    }

    fn incValue(old: Value, up: bool, mem: std.mem.Allocator) Value {
        if (old == .null_) {
            return if (up) Value{ .int_ = 1 } else Value.null_;
        }
        // Non-numeric strings are untouched (PHP semantics); a rope is
        // "touched" only if it holds numeric content, which toNumber handles.
        if (old == .str_ and valmod.numericString(old.str_.data) == null) {
            return old;
        }
        const n = valmod.toNumber(old, mem);
        return switch (n) {
            .int => |i| Value{ .int_ = if (up) i +% 1 else i -% 1 },
            .float => |fl| Value{ .float_ = if (up) fl + 1 else fl - 1 },
        };
    }

    fn doCall(self: *Vm, name: []const u8, argc: u32, base_reg: u32, line: u32) Error!void {
        if (self.funcs.get(name)) |callee| {
            if (argc > callee.arity) {
                return self.fatalF(line, "{s}() expects at most {d} argument(s), {d} given", .{ name, callee.arity, argc });
            }
            if (self.frames.items.len >= MAX_CALL_DEPTH) {
                return self.fatalF(line, "Maximum function nesting level of {d} reached, aborting", .{MAX_CALL_DEPTH});
            }

            const caller = &self.frames.items[self.frames.items.len - 1];

            const callee_regs = try self.newFrameRegs(callee);
            // Copy arguments directly (caller/callee register files never
            // overlap, so no intermediate buffer is needed).
            for (0..argc) |i| callee_regs[i] = caller.regs[base_reg + i];
            var i: usize = argc;
            while (i < callee.arity) : (i += 1) {
                if (i < callee.defaults.len) {
                    callee_regs[i] = callee.defaults[i] orelse
                        return self.fatalF(line, "Too few arguments to function {s}()", .{name});
                } else {
                    return self.fatalF(line, "Too few arguments to function {s}()", .{name});
                }
            }

            try self.frames.append(self.arena, .{
                .func = callee,
                .ip = 0,
                .regs = callee_regs,
                .hidden = try self.arena.alloc(Value, callee.nhidden),
                .result_reg = base_reg, // written back into caller's registers
            });

            // Execute callee to completion; depth bounded by MAX_CALL_DEPTH.
            // An escaping exception unwinds INTO this frame: check our active
            // try regions around the call site before propagating further.
            if (self.dispatch()) |_| {
                return;
            } else |e| switch (e) {
                error.Thrown => {
                    _ = self.frames.pop(); // discard aborted callee
                    if (self.unwindToRegion()) |handler_ip| {
                        self.frames.items[self.frames.items.len - 1].ip = handler_ip;
                        return; // caller continues into its catch dispatcher
                    }
                    return e;
                },
                else => return e,
            }
        }

        // Builtins receive a view of the caller's registers.
        const caller = &self.frames.items[self.frames.items.len - 1];
        const args = caller.regs[base_reg .. base_reg + argc];
        if (try builtins.call(self, name, args, line)) |result| {
            caller.regs[base_reg] = result;
            return;
        }

        return self.fatalF(line, "Call to undefined function {s}()", .{name});
    }

    /// Invoke a compiled method/function: `this_obj` lands in callee slot 0
    /// (when non-null), declared args copy from caller regs[args_base..],
    /// defaults fill the rest, and the return value is written back to
    /// caller's result_dst register.
    /// Pop the innermost active try region of the current (top) frame and
    /// return its handler address; null when no region is active.
    fn unwindToRegion(self: *Vm) ?usize {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (frame.tries.items.len == 0) return null;
        return frame.tries.pop();
    }

    /// Static builtin exception hierarchy (Throwable root implied).
    const exception_parents = [_]struct { child: []const u8, parent: []const u8 }{
        .{ .child = "RuntimeException", .parent = "Exception" },
        .{ .child = "LogicException", .parent = "Exception" },
        .{ .child = "Error", .parent = "Throwable" },
        .{ .child = "Exception", .parent = "Throwable" },
        .{ .child = "TypeError", .parent = "Error" },
        .{ .child = "ValueError", .parent = "Error" },
        .{ .child = "ArithmeticError", .parent = "Error" },
        .{ .child = "DivisionByZeroError", .parent = "ArithmeticError" },
        .{ .child = "ArgumentCountError", .parent = "TypeError" },
        .{ .child = "UnhandledMatchError", .parent = "Error" },
    };

    /// True when `name` names a builtin exception class.
    fn isBuiltinException(name: []const u8) bool {
        if (std.mem.eql(u8, name, "Throwable")) return true;
        for (exception_parents) |e| {
            if (std.mem.eql(u8, e.child, name)) return true;
        }
        return false;
    }

    fn exceptionParentOf(name: []const u8) ?[]const u8 {
        for (exception_parents) |e| {
            if (std.mem.eql(u8, e.child, name)) return e.parent;
        }
        return null;
    }

    /// Create a builtin exception instance: props message/code/line.
    fn newBuiltinException(self: *Vm, class_name: []const u8, msg: []const u8, line: u32) !*valmod.Object {
        const obj = try valmod.Object.create(self.arena, class_name);
        try obj.props.append(self.arena, .{ .name = "message", .val = .{ .str_ = try valmod.newStr(self.arena, msg) } });
        try obj.props.append(self.arena, .{ .name = "code", .val = .{ .int_ = 0 } });
        try obj.props.append(self.arena, .{ .name = "line", .val = .{ .int_ = @intCast(line) } });
        return obj;
    }

    /// Resolve the class named `given` relative to the current method's
    /// class ("self"/"parent"/"static" keywords).
    fn resolveStaticClass(self: *Vm, f: *Frame, given: []const u8, line: u32) Error!*compiler_mod.ClassInfo {
        if (std.mem.eql(u8, given, "self") or std.mem.eql(u8, given, "static")) {
            const cn = f.func.cls_name orelse
                return self.fatalF(line, "cannot use {s} outside of a class", .{given});
            return self.program.classes.get(cn) orelse
                return self.fatalF(line, "Class \"{s}\" not found", .{cn});
        }
        if (std.mem.eql(u8, given, "parent")) {
            const cn = f.func.cls_name orelse
                return self.fatalF(line, "cannot use parent outside of a class", .{});
            const cls = self.program.classes.get(cn) orelse
                return self.fatalF(line, "Class \"{s}\" not found", .{cn});
            return cls.parent orelse
                return self.fatalF(line, "cannot use parent when extending nothing", .{});
        }
        return self.program.classes.get(given) orelse
            return self.fatalF(line, "Class \"{s}\" not found", .{given});
    }

    fn staticsFor(cls: *compiler_mod.ClassInfo) *std.StringHashMapUnmanaged(Value) {
        return cls.statics.?;
    }

    /// True when thrown class is catchable as `target` (builtin hierarchy +
    /// user classes).
    fn exMatches(self: *Vm, thrown_class: []const u8, target: []const u8) bool {
        var cur: ?[]const u8 = thrown_class;
        while (cur) |c| : (cur = exceptionParentOf(c)) {
            if (std.mem.eql(u8, c, target)) return true;
            // User-defined parent chain (only when not purely builtin).
            if (!isBuiltinException(c)) {
                if (self.classExtends(c, target)) return true;
                break;
            }
        }
        return false;
    }

    /// Throw from the current frame: jump to its innermost region handler or
    /// start unwinding to the caller.
    fn throwInCurrentFrame(self: *Vm, f: *Frame) Error!void {
        _ = self;
        if (f.tries.items.len > 0) {
            f.ip = f.tries.pop().?;
            return;
        }
        return error.Thrown;
    }

    fn isThrowableClass(self: *Vm, name: []const u8) bool {
        if (isBuiltinException(name)) return true;
        return self.classExtends(name, "Exception") or self.classExtends(name, "Throwable");
    }

    /// Set pending exception of a builtin class and throw.
    fn throwBuiltin(self: *Vm, line: u32, class_name: []const u8, msg: []const u8) Error!void {
        self.pending_ex = try self.newBuiltinException(class_name, msg, line);
        const frame = &self.frames.items[self.frames.items.len - 1];
        return self.throwInCurrentFrame(frame);
    }

    fn invokeUser(self: *Vm, callee: *Func, args_base: u32, argc: u32, result_dst: u32, this_obj: ?*valmod.Object, line: u32) Error!void {
        if (self.frames.items.len >= MAX_CALL_DEPTH) {
            return self.fatalF(line, "Maximum function nesting level of {d} reached, aborting", .{MAX_CALL_DEPTH});
        }
        const caller = &self.frames.items[self.frames.items.len - 1];
        const callee_regs = try self.newFrameRegs(callee);
        var dst_i: usize = 0;
        if (this_obj) |o| {
            callee_regs[0] = .{ .obj_ = o };
            dst_i = 1;
        }
        for (0..argc) |i| {
            if (dst_i + i >= callee_regs.len) break;
            callee_regs[dst_i + i] = caller.regs[args_base + i];
        }
        const filled = dst_i + argc;
        var i: usize = filled;
        while (i < callee.arity) : (i += 1) {
            if (i < callee.defaults.len) {
                callee_regs[i] = callee.defaults[i] orelse
                    return self.fatalF(line, "Too few arguments to {s}()", .{callee.name});
            } else {
                return self.fatalF(line, "Too few arguments to {s}()", .{callee.name});
            }
        }
        try self.frames.append(self.arena, .{
            .func = callee,
            .ip = 0,
            .regs = callee_regs,
            .hidden = try self.arena.alloc(Value, callee.nhidden),
            .result_reg = result_dst,
        });
        if (self.dispatch()) |_| {
            return;
        } else |e| switch (e) {
            error.Thrown => {
                _ = self.frames.pop(); // discard aborted callee
                if (self.unwindToRegion()) |handler_ip| {
                    self.frames.items[self.frames.items.len - 1].ip = handler_ip;
                    return;
                }
                return e;
            },
            else => return e,
        }
    }

    /// True when class `name` is or inherits from `ancestor`.
    fn classExtends(self: *Vm, name: []const u8, ancestor: []const u8) bool {
        if (std.mem.eql(u8, name, ancestor)) return true;
        var cur = self.program.classes.get(name);
        while (cur) |cls| : (cur = cls.parent) {
            // Interfaces on every class in the chain count too.
            for (cls.interfaces) |ifn| {
                if (self.ifaceSatisfied(ifn, ancestor)) return true;
            }
            if (cls.parent_name) |pn| {
                if (std.mem.eql(u8, pn, ancestor)) return true;
                cur = self.program.classes.get(pn); // continue from parent
                if (cur == null) return false;
            } else return false;
        }
        return false;
    }

    /// Interface hierarchy check: iface == target, extends target, or any of
    /// its parents matches.
    fn ifaceSatisfied(self: *Vm, iface: []const u8, target: []const u8) bool {
        var cur: ?[]const u8 = iface;
        while (cur) |i| : (cur = blk: {
            const ic = self.program.classes.get(i) orelse break :blk null;
            break :blk ic.parent_name;
        }) {
            if (std.mem.eql(u8, i, target)) return true;
        }
        return false;
    }

    fn popFrame(self: *Vm, result: Value) Error!void {
        const frame = self.frames.pop().?;
        // Recycle the register file (bounded pool; arena frees the rest).
        if (self.reg_pool.items.len < 64) try self.reg_pool.append(self.arena, frame.regs);
        if (self.frames.items.len > 0 and frame.result_reg != opcode.no_reg) {
            const caller = &self.frames.items[self.frames.items.len - 1];
            caller.regs[frame.result_reg] = result;
        }
    }
};
