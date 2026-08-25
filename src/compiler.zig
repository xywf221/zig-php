//! Register bytecode compiler: AST -> three-address code.
//!
//! Code generation is *target-directed*: `compileInto(dst, expr)` emits code
//! that leaves the expression's value in register `dst`, eliminating all
//! operand-stack shuffling. Locals live in fixed registers; temporaries are
//! allocated from a free list above them.
//!
//! Scope model (matching PHP):
//!   * the top-level script is an ordinary function frame — its variables
//!     are registers (invisible to called functions, since the minimal core
//!     has no `global` keyword),
//!   * each declared function gets a fresh register file.

const std = @import("std");
const ast = @import("ast.zig");
const valmod = @import("value.zig");
const opcode = @import("opcode.zig");
const chunkmod = @import("chunk.zig");

const Op = opcode.Op;
const Value = valmod.Value;
const Chunk = chunkmod.Chunk;
const Func = chunkmod.Func;

pub const Error = error{ SyntaxError, OutOfMemory };

pub const Diag = struct {
    msg: []const u8 = "",
    line: u32 = 0,
};

pub const Program = struct {
    main_func: *Func,
    funcs: std.StringHashMapUnmanaged(*Func) = .empty,
    /// Functions declared unconditionally at the top level — hoisted at VM
    /// startup. Conditional declarations register via declare_func instead.
    hoisted: std.StringHashMapUnmanaged(void) = .empty,
    classes: std.StringHashMapUnmanaged(*ClassInfo) = .empty,
    hoisted_classes: std.StringHashMapUnmanaged(void) = .empty,
    /// Trait declarations awaiting `use` inside classes.
    traits: std.StringHashMapUnmanaged(ast.Stmt.ClassDecl) = .empty,
};

/// One property in a class's flattened layout (parent props first).
pub const ClassProp = struct {
    name: []const u8,
    default: valmod.Value,
};

pub const ClassInfo = struct {
    name: []const u8,
    parent_name: ?[]const u8 = null,
    /// Resolved at VM startup.
    parent: ?*ClassInfo = null,
    /// Own properties as declared; VM flattens with parent layout on use.
    own_props: []const ClassProp = &.{},
    methods: std.StringHashMapUnmanaged(*Func) = .empty,
    is_interface: bool = false,
    /// Implemented interfaces (checked by instanceof / type checks).
    interfaces: []const []const u8 = &.{},
    /// Static property defaults (flattened with parents at VM init).
    static_defaults: []const ClassProp = &.{},
    /// Runtime static property storage (allocated at VM init).
    statics: ?*std.StringHashMapUnmanaged(Value) = null,

    /// Walk the chain looking for a method (child overrides parent).
    pub fn findMethod(self: *ClassInfo, name: []const u8) ?*Func {
        var c: ?*ClassInfo = self;
        while (c) |cls| : (c = cls.parent) {
            if (cls.methods.get(name)) |f| return f;
        }
        return null;
    }

    /// True when this class implements/extends `iface` (transitively).
    pub fn implementsIface(self: *ClassInfo, iface: []const u8) bool {
        if (std.mem.eql(u8, self.name, iface)) return true;
        for (self.interfaces) |i| {
            if (std.mem.eql(u8, i, iface)) return true;
        }
        if (self.parent) |p| return p.implementsIface(iface);
        return false;
    }
};

pub const Compiler = struct {
    const FnCtx = struct {
        func: *Func,
        locals: std.StringHashMapUnmanaged(usize) = .empty,
        /// Slots proven assigned before a read (flow-insensitive).
        defined: std.AutoHashMapUnmanaged(usize, void) = .empty,
        /// Slots that participate in PHP references (`=&`, by-ref params).
        /// Accesses to these are rewritten to ld_ref/st_ref.
        ref_slots: std.AutoHashMapUnmanaged(usize, void) = .empty,
        next_temp: u32 = 0,
        free_list: std.ArrayList(u32) = .empty,
        nhidden: u32 = 0,
        arena: std.mem.Allocator,

        /// Reserve a local slot (pre-pass) or look it up (codegen).
        fn resolveLocal(self: *FnCtx, a: std.mem.Allocator, name: []const u8) Error!usize {
            if (self.locals.get(name)) |s| return s;
            const slot = self.locals.count();
            try self.locals.put(a, name, slot);
            self.func.nlocals = @max(self.func.nlocals, slot + 1);
            return slot;
        }

        fn markDefined(self: *FnCtx, slot: usize) void {
            self.defined.put(self.arena, slot, {}) catch {};
        }

        fn alloc(self: *FnCtx) u32 {
            if (self.free_list.items.len > 0) return self.free_list.pop().?;
            const r = self.next_temp;
            self.next_temp += 1;
            self.func.ntemps = self.next_temp;
            return r;
        }

        fn freeReg(self: *FnCtx, r: u32) void {
            self.free_list.append(self.arena, r) catch {};
        }

        fn allocBlock(self: *FnCtx, n: usize) u32 {
            const base = self.next_temp;
            self.next_temp += @intCast(n);
            self.func.ntemps = self.next_temp;
            return base;
        }

        fn freeBlock(self: *FnCtx, base: u32, n: usize) void {
            var i: usize = n;
            while (i > 0) : (i -= 1) {
                self.free_list.append(self.arena, base + @as(u32, @intCast(i)) - 1) catch {};
            }
        }

        fn newHidden(self: *FnCtx) u32 {
            const h = self.nhidden;
            self.nhidden += 2; // snapshot + cursor
            self.func.nhidden = self.nhidden;
            return h;
        }
    };

    /// An evaluated operand: either a live register or an owning temporary.
    const Reg = struct {
        reg: u32,
        owned: bool,

        fn release(self: Reg, ctx: **FnCtx) void {
            if (self.owned) ctx.*.freeReg(self.reg);
        }
    };

    const LoopCtx = struct {
        continue_addr: usize = 0,
        is_foreach: bool = false,
        next_addr: usize = 0,
        continue_jumps: std.ArrayList(usize) = .empty,
        break_jumps: std.ArrayList(usize) = .empty,
    };

    arena: std.mem.Allocator,
    diag: *Diag,
    ctx: *FnCtx,
    chunk: *Chunk,
    loops: std.ArrayList(*LoopCtx) = .empty,
    /// For compile-time callee lookup (by-ref argument promotion).
    program: *Program,

    // -- entry points ------------------------------------------------------------

    /// Pre-pass: collect every variable name so local slots are known before
    /// codegen starts — temporaries must never overlap them.
    fn reserveLocals(arena: std.mem.Allocator, stmts: []const *ast.Stmt, ctx: *FnCtx) Error!void {
        for (stmts) |s| try reserveLocalsStmt(arena, s, ctx);
    }

    fn reserveLocalsStmt(arena: std.mem.Allocator, st: *ast.Stmt, ctx: *FnCtx) Error!void {
        switch (st.kind) {
            .expr => |e| try reserveLocalsExpr(arena, e, ctx),
            .echo => |exprs| for (exprs) |e| try reserveLocalsExpr(arena, e, ctx),
            .block => |stmts| try reserveLocals(arena, stmts, ctx),
            .if_stmt => |info| {
                for (info.branches) |b| {
                    try reserveLocalsExpr(arena, b.cond, ctx);
                    try reserveLocalsStmt(arena, b.body, ctx);
                }
                if (info.else_body) |eb| try reserveLocalsStmt(arena, eb, ctx);
            },
            .while_stmt => |w| {
                try reserveLocalsExpr(arena, w.cond, ctx);
                try reserveLocalsStmt(arena, w.body, ctx);
            },
            .do_while => |dw| {
                try reserveLocalsStmt(arena, dw.body, ctx);
                try reserveLocalsExpr(arena, dw.cond, ctx);
            },
            .for_stmt => |f| {
                for (f.init) |e| try reserveLocalsExpr(arena, e, ctx);
                if (f.cond) |c2| try reserveLocalsExpr(arena, c2, ctx);
                for (f.step) |e| try reserveLocalsExpr(arena, e, ctx);
                try reserveLocalsStmt(arena, f.body, ctx);
            },
            .foreach => |fe| {
                try reserveLocalsExpr(arena, fe.subject, ctx);
                if (fe.key) |k| _ = try ctx.resolveLocal(arena, k);
                _ = try ctx.resolveLocal(arena, fe.val);
                try reserveLocalsStmt(arena, fe.body, ctx);
            },
            .ret => |e| if (e) |x| try reserveLocalsExpr(arena, x, ctx),
            else => {},
        }
    }

    fn reserveLocalsExpr(arena: std.mem.Allocator, e: *ast.Expr, ctx: *FnCtx) Error!void {
        switch (e.kind) {
            .var_ref => |name| _ = try ctx.resolveLocal(arena, name),
            .static_get => {},
            .static_set => |ss| {
                try reserveLocalsExpr(arena, ss.value, ctx);
            },
            .static_call => |sc| {
                for (sc.args) |arg| try reserveLocalsExpr(arena, arg, ctx);
            },
.ref_arg => |inner| {
                try reserveLocalsExpr(arena, inner, ctx);
                if (inner.kind == .var_ref) {
                    const slot = try ctx.resolveLocal(arena, inner.kind.var_ref);
                    try ctx.ref_slots.put(arena, slot, {});
                }
            },
            .assign => |a| {
                if (a.by_ref) {
                    // Both sides of `=&` share a container.
                    if (a.target.kind == .var_ref) {
                        const tslot = try ctx.resolveLocal(arena, a.target.kind.var_ref);
                        try ctx.ref_slots.put(arena, tslot, {});
                    }
                    if (a.value.kind == .var_ref) {
                        const vslot = try ctx.resolveLocal(arena, a.value.kind.var_ref);
                        try ctx.ref_slots.put(arena, vslot, {});
                    }
                }
                try reserveLocalsExpr(arena, a.target, ctx);
                try reserveLocalsExpr(arena, a.value, ctx);
            },
            .interp_str => |parts| {
                for (parts) |part| {
                    switch (part) {
                        .var_ref => |name| _ = try ctx.resolveLocal(arena, name),
                        .var_index => |vi| _ = try ctx.resolveLocal(arena, vi.name),
                        .literal => {},
                    }
                }
            },
            .array_lit => |items| {
                for (items) |item| {
                    if (item.key) |ke| try reserveLocalsExpr(arena, ke, ctx);
                    try reserveLocalsExpr(arena, item.val, ctx);
                }
            },
            .unary => |u| try reserveLocalsExpr(arena, u.operand, ctx),
            .binary => |b| {
                try reserveLocalsExpr(arena, b.lhs, ctx);
                try reserveLocalsExpr(arena, b.rhs, ctx);
            },
            .ternary => |tn| {
                try reserveLocalsExpr(arena, tn.cond, ctx);
                if (tn.then) |t| try reserveLocalsExpr(arena, t, ctx);
                try reserveLocalsExpr(arena, tn.els, ctx);
            },
            .inc_dec => |d| try reserveLocalsExpr(arena, d.target, ctx),
            .call => |c| {
                for (c.args) |arg| try reserveLocalsExpr(arena, arg, ctx);
            },
            .index => |ix| {
                try reserveLocalsExpr(arena, ix.base, ctx);
                if (ix.index) |ie| try reserveLocalsExpr(arena, ie, ctx);
            },
            .isset => |exprs| for (exprs) |x| try reserveLocalsExpr(arena, x, ctx),
            .empty => |x| try reserveLocalsExpr(arena, x, ctx),
            .new => |n| for (n.args) |arg| try reserveLocalsExpr(arena, arg, ctx),
            .prop_get => |p| try reserveLocalsExpr(arena, p.obj, ctx),
            .method_call => |m| {
                try reserveLocalsExpr(arena, m.obj, ctx);
                for (m.args) |arg| try reserveLocalsExpr(arena, arg, ctx);
            },
            .instanceof => |io| try reserveLocalsExpr(arena, io.operand, ctx),
            else => {}, // literals contain no variables
        }
    }

    pub fn compile(arena: std.mem.Allocator, prog_ast: []const *ast.Stmt, diag: *Diag) Error!*Program {
        const program = try arena.create(Program);
        program.* = .{ .main_func = undefined };

        const main_func = try arena.create(Func);
        main_func.* = .{ .name = "<main>", .arity = 0 };
        // Collect functions/classes FIRST so codegen can resolve callees
        // (needed for by-reference argument promotion).
        try collectFuncs(arena, prog_ast, program, diag);

        var main_ctx = FnCtx{ .func = main_func, .arena = arena };
        try reserveLocals(arena, prog_ast, &main_ctx);
        main_ctx.next_temp = @intCast(main_func.nlocals);
        {
            var c = Compiler{ .arena = arena, .diag = diag, .ctx = &main_ctx, .chunk = &main_func.chunk, .program = program };
            try c.compileStmts(prog_ast);
            _ = try c.emit(.return_null, 0);
        }
        program.main_func = main_func;
        return program;
    }

    fn collectFuncs(arena: std.mem.Allocator, stmts: []const *ast.Stmt, program: *Program, diag: *Diag) Error!void {
        for (stmts) |s| try collectFuncsStmt(arena, s, program, diag, true);
    }

    /// Walk a nested body: declarations inside never hoist.
    fn collectFuncsNested(arena: std.mem.Allocator, stmts: []const *ast.Stmt, program: *Program, diag: *Diag) Error!void {
        for (stmts) |s| try collectFuncsStmt(arena, s, program, diag, false);
    }

    /// Walk every statement tree — functions may be declared conditionally
    /// or nested inside other functions. Only direct top-level declarations
    /// are marked hoisted.
    fn collectFuncsStmt(arena: std.mem.Allocator, st: *ast.Stmt, program: *Program, diag: *Diag, hoist: bool) Error!void {
        switch (st.kind) {
            .class_decl => |cd| {
                if (cd.is_trait) {
                    if (!program.traits.contains(cd.name)) try program.traits.put(arena, cd.name, cd);
                } else if (!program.classes.contains(cd.name)) { // first wins
                    const info = try compileClassUnit(arena, cd, diag, program);
                    try program.classes.put(arena, cd.name, info);
                }
                if (hoist and !cd.is_trait) try program.hoisted_classes.put(arena, cd.name, {});
            },
            .func_decl => |fd| {
                if (!program.funcs.contains(fd.name)) { // first wins
                    const f = try compileFuncUnit(arena, fd, diag, false, program);
                    try program.funcs.put(arena, fd.name, f);
                }
                if (hoist) try program.hoisted.put(arena, fd.name, {});
                try collectFuncsNested(arena, fd.body, program, diag);
            },
            .block => |stmts| try collectFuncs(arena, stmts, program, diag),
            .if_stmt => |info| {
                for (info.branches) |b| try collectFuncsStmt(arena, b.body, program, diag, false);
                if (info.else_body) |eb| try collectFuncsStmt(arena, eb, program, diag, false);
            },
            .while_stmt => |w| try collectFuncsStmt(arena, w.body, program, diag, false),
            .do_while => |dw| try collectFuncsStmt(arena, dw.body, program, diag, false),
            .for_stmt => |fr| try collectFuncsStmt(arena, fr.body, program, diag, false),
            .foreach => |fe| try collectFuncsStmt(arena, fe.body, program, diag, false),
            else => {},
        }
    }

    fn compileClassUnit(arena: std.mem.Allocator, cd: ast.Stmt.ClassDecl, diag: *Diag, program: *Program) Error!*ClassInfo {
        const info = try arena.create(ClassInfo);
        info.* = .{
            .name = cd.name,
            .parent_name = cd.extends,
            .is_interface = cd.is_interface,
            .interfaces = cd.implements,
        };

        // Trait flattening: `use T` copies trait methods (class wins).
        var methods: std.ArrayList(ast.Stmt.FuncDecl) = .empty;
        for (cd.uses) |tname| {
            const tr = program.traits.get(tname) orelse {
                diag.msg = try std.fmt.allocPrint(arena, "Trait '{s}' not found (declare traits before use)", .{tname});
                diag.line = 0;
                return error.SyntaxError;
            };
            for (tr.methods) |m| try methods.append(arena, m);
        }
        for (cd.methods) |m| try methods.append(arena, m); // class overrides traits

        // Interface conformance: every interface method must exist.
        for (cd.implements) |iname| {
            const iface = program.classes.get(iname) orelse {
                diag.msg = try std.fmt.allocPrint(arena, "Interface '{s}' not found (declare interfaces before use)", .{iname});
                diag.line = 0;
                return error.SyntaxError;
            };
            if (!iface.is_interface) {
                diag.msg = try std.fmt.allocPrint(arena, "'{s}' is not an interface", .{iname});
                diag.line = 0;
                return error.SyntaxError;
            }
            var im_it = iface.methods.iterator();
            while (im_it.next()) |im_e| {
                const im_name = im_e.key_ptr.*;
                var found = false;
                for (methods.items) |m| {
                    if (std.mem.eql(u8, m.name, im_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    diag.msg = try std.fmt.allocPrint(arena, "{s} contains 1 abstract method and must therefore be declared abstract or implement {s}::{s}()", .{ cd.name, iname, im_name });
                    diag.line = 0;
                    return error.SyntaxError;
                }
            }
        }

        // Static property defaults.
        const sprops = try arena.alloc(ClassProp, cd.static_props.len);
        for (cd.static_props, 0..) |p, i| {
            sprops[i] = .{ .name = p.name, .default = p.default orelse valmod.Value.null_ };
        }
        info.static_defaults = sprops;

        const props = try arena.alloc(ClassProp, cd.props.len);
        for (cd.props, 0..) |p, i| {
            props[i] = .{ .name = p.name, .default = p.default orelse valmod.Value.null_ };
        }
        info.own_props = props;

        for (methods.items) |m| {
            if (info.methods.contains(m.name)) continue; // first wins
            const is_abstract = cd.is_interface;
            _ = is_abstract;
            const f = try compileMethodUnit(arena, m, diag, program, cd.name, m.is_static);
            try info.methods.put(arena, m.name, f);
        }
        return info;
    }

    /// Method variant of compileFuncUnit: binds cls context, honours
    /// static-ness (no implicit $this), accepts empty bodies (interfaces).
    fn compileMethodUnit(arena: std.mem.Allocator, fd: ast.Stmt.FuncDecl, diag: *Diag, program: *Program, cls_name: []const u8, is_static: bool) Error!*Func {
        const f = try compileFuncUnit(arena, fd, diag, !is_static, program);
        f.cls_name = cls_name;
        f.is_static = is_static;
        return f;
    }

    fn compileFuncUnit(arena: std.mem.Allocator, fd: ast.Stmt.FuncDecl, diag: *Diag, implicit_this: bool, program: *Program) Error!*Func {
        const f = try arena.create(Func);
        f.* = .{
            .name = fd.name,
            .arity = fd.params.len + (if (implicit_this) @as(usize, 1) else 0),
            .defaults = try arena.alloc(?Value, if (implicit_this) fd.params.len + 1 else fd.params.len),
        };
        for (f.defaults) |*d| d.* = null;

        // The minimal core supports constant default values only.
        const param_base: usize = if (implicit_this) 1 else 0;
        for (fd.params, 0..) |p, i| {
            if (p.default) |de| {
                f.defaults[param_base + i] = constEval(de, arena) orelse {
                    diag.msg = try std.fmt.allocPrint(arena, "unsupported default parameter expression in {s}() (compile-time constants only)", .{fd.name});
                    diag.line = de.line;
                    return error.SyntaxError;
                };
            }
        }

        var ctx = FnCtx{ .func = f, .arena = arena };
        // Parameters occupy the first registers.
        if (implicit_this) {
            const tslot = try ctx.resolveLocal(arena, "this");
            ctx.markDefined(tslot);
        }
        var by_ref_params = try arena.alloc(bool, fd.params.len);
        for (fd.params, 0..) |p, pi| {
            const pslot = try ctx.resolveLocal(arena, p.name);
            ctx.markDefined(pslot); // parameters are always defined
            by_ref_params[pi] = p.by_ref;
            if (p.by_ref) try ctx.ref_slots.put(arena, pslot, {});
        }
        f.by_ref_params = by_ref_params;
        try reserveLocals(arena, fd.body, &ctx);
        ctx.next_temp = @intCast(f.nlocals);
        var c = Compiler{ .arena = arena, .diag = diag, .ctx = &ctx, .chunk = &f.chunk, .program = program };
        try c.compileStmts(fd.body);
        _ = try c.emit(.return_null, 0);
        return f;
    }

    // -- low-level emit helpers ------------------------------------------------------

    fn emit(self: *Compiler, op: Op, line: u32) Error!usize {
        return self.emit3(op, 0, 0, 0, line);
    }

    fn emit1(self: *Compiler, op: Op, a: u32, line: u32) Error!usize {
        return self.emit3(op, a, 0, 0, line);
    }

    fn emit2(self: *Compiler, op: Op, a: u32, b: u32, line: u32) Error!usize {
        return self.emit3(op, a, b, 0, line);
    }

    fn emit3(self: *Compiler, op: Op, a: u32, b: u32, cc: u32, line: u32) Error!usize {
        _ = self.chunk.emit(self.arena, .{ .op = op, .a = a, .b = b, .c = cc }, line) catch return error.OutOfMemory;
        return self.chunk.code.items.len - 1;
    }

    fn emitInline(self: *Compiler, word: u32, line: u32) Error!usize {
        return self.emit1(.inline_arg, word, line);
    }

    /// Patch a jump's target (.a) to point after the current instruction.
    fn patchA(self: *Compiler, addr: usize) Error!void {
        self.chunk.code.items[addr].a = @intCast(self.chunk.code.items.len);
    }

    /// Same, for two-operand conditional jumps whose target lives in .b
    /// (.a holds the condition register).
    fn patchB(self: *Compiler, addr: usize) Error!void {
        self.chunk.code.items[addr].b = @intCast(self.chunk.code.items.len);
    }

    /// Patch a jump's .b to an explicit address.
    fn patchBAt(self: *Compiler, addr: usize, target: usize) Error!void {
        self.chunk.code.items[addr].b = @intCast(target);
    }

    fn here(self: *Compiler) usize {
        return self.chunk.code.items.len;
    }

    fn nameConst(self: *Compiler, name: []const u8) Error!u32 {
        const boxed = valmod.newStr(self.arena, name) catch return error.OutOfMemory;
        return self.chunk.addConst(self.arena, .{ .str_ = boxed }) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn fail(self: *Compiler, line: u32, comptime fmt: []const u8, args: anytype) Error {
        if (self.diag.msg.len == 0) {
            self.diag.msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            self.diag.line = line;
        }
        return error.SyntaxError;
    }

    // -- statements --------------------------------------------------------------------

    fn compileStmts(self: *Compiler, stmts: []const *ast.Stmt) Error!void {
        for (stmts) |s| try self.compileStmt(s);
    }

    fn compileBody(self: *Compiler, body: *ast.Stmt) Error!void {
        switch (body.kind) {
            .block => |stmts| try self.compileStmts(stmts),
            else => try self.compileStmt(body),
        }
    }

    fn compileStmt(self: *Compiler, s: *ast.Stmt) Error!void {
        const line = s.line;
        switch (s.kind) {
            .nop => {},
            .expr => |e| try self.compileExprStmt(e),
            .echo => |exprs| {
                const base = self.ctx.allocBlock(exprs.len);
                for (exprs, 0..) |e, i| {
                    try self.compileInto(base + @as(u32, @intCast(i)), e);
                }
                _ = try self.emit2(.echo, base, @intCast(exprs.len), line);
                self.ctx.freeBlock(base, exprs.len);
            },
            .block => |stmts| try self.compileStmts(stmts),

            .if_stmt => |info| {
                var end_jumps: std.ArrayList(usize) = .empty;
                for (info.branches) |branch| {
                    const tc = try self.exprToTemp(branch.cond);
                    const jf = try self.emit2(.jmp_if_false, tc.reg, 0, branch.cond.line);
                    tc.release(&self.ctx);
                    try self.compileBody(branch.body);
                    try end_jumps.append(self.arena, try self.emit(.jmp, line));
                    try self.patchB(jf);
                }
                if (info.else_body) |eb| try self.compileBody(eb);
                for (end_jumps.items) |j| try self.patchA(j);
            },

            .while_stmt => |w| {
                const lc = try self.newLoop();
                lc.continue_addr = self.here();

                var fused_exit: ?usize = null;
                var exit_jump: ?usize = null;
                if (try self.tryEmitCondJump(w.cond, line)) |pos| {
                    fused_exit = pos;
                } else {
                    const tc = try self.exprToTemp(w.cond);
                    exit_jump = try self.emit2(.jmp_if_false, tc.reg, 0, line);
                    tc.release(&self.ctx);
                }
                try self.compileBody(w.body);
                _ = try self.emit1(.jmp, @intCast(lc.continue_addr), line);
                if (fused_exit) |pos| {
                    self.chunk.code.items[pos].a = @intCast(self.here());
                } else if (exit_jump) |ej| {
                    try self.patchB(ej);
                }
                try self.endLoop(lc);
            },

            .do_while => |dw| {
                const body_start = self.here();
                const lc = try self.newLoop();

                try self.compileBody(dw.body);
                lc.continue_addr = self.here(); // continue -> condition test
                const tc = try self.exprToTemp(dw.cond);
                _ = try self.emit2(.jmp_if_true, tc.reg, @intCast(body_start), line);
                tc.release(&self.ctx);
                try self.endLoop(lc);
            },

            .for_stmt => |f| {
                for (f.init) |e| try self.compileExprStmt(e);
                const cond_addr = self.here();
                const lc = try self.newLoop();
                lc.continue_addr = 0;

                var fused_exit: ?usize = null;
                var exit_jump: ?usize = null;
                if (f.cond) |cond| {
                    if (try self.tryEmitCondJump(cond, line)) |pos| {
                        fused_exit = pos;
                    } else {
                        const tc = try self.exprToTemp(cond);
                        exit_jump = try self.emit2(.jmp_if_false, tc.reg, 0, line);
                        tc.release(&self.ctx);
                    }
                }
                try self.compileBody(f.body);
                const step_addr = self.here();
                lc.continue_addr = step_addr;
                for (f.step) |e| try self.compileExprStmt(e);
                _ = try self.emit1(.jmp, @intCast(cond_addr), line);
                if (exit_jump) |ej| try self.patchB(ej);
                if (fused_exit) |pos| self.chunk.code.items[pos].a = @intCast(self.here());
                try self.endLoop(lc);
            },

            .foreach => |fe| {
                const rs = try self.exprToTemp(fe.subject);
                const hidden = self.ctx.newHidden();
                _ = try self.emit3(.foreach_init, hidden, hidden + 1, rs.reg, line);
                rs.release(&self.ctx);

                const lc = try self.newLoop();
                lc.is_foreach = true;
                lc.next_addr = self.here();
                const key_out: u32 = if (fe.key) |_| try self.slotOf(fe.key.?, line) else opcode.no_reg;
                const val_slot = try self.slotOf(fe.val, line);
                _ = try self.emit2(.foreach_next, key_out, val_slot, line);
                self.ctx.markDefined(val_slot);
                if (fe.key) |k| {
                    const ks = try self.slotOf(k, line);
                    self.ctx.markDefined(ks);
                }
                _ = try self.emitInline(opcode.packForeach(hidden, fe.key != null), line);
                const exit_pos = try self.emitInline(0, line);

                try self.compileBody(fe.body);
                _ = try self.emit1(.jmp, @intCast(lc.next_addr), line);
                self.chunk.code.items[exit_pos].a = @intCast(self.here());
                try self.endLoopForeach(lc);
            },

            .func_decl => |fd| {
                const k = try self.nameConst(fd.name);
                _ = try self.emit1(.declare_func, k, line);
            },

            .class_decl => |cd| {
                // Conditional declaration point; hoisted classes were already
                // registered at VM startup and this is an idempotent no-op.
                const k = try self.nameConst(cd.name);
                _ = try self.emit1(.declare_class, k, line);
            },

            .throw_stmt => |e| {
                const tv = try self.exprToTemp(e);
                _ = try self.emit2(.throw_v, 0, tv.reg, line);
                tv.release(&self.ctx);
            },

            .try_stmt => |ts| {
                // Layout:
                //   try_start   (inline-patched .a = handler address)
                //   body...
                //   try_end
                //   jmp END
                // HANDLER:
                //   for each clause: catch_match / jmp_if_false next;
                //                    fallthrough => clause body
                //   rethrow
                // CLAUSE_i: catch_store slot_i; body_i; jmp END
                const start = self.here();
                _ = try self.emit1(.try_start, 0, line);
                try self.compileBody(ts.body);
                _ = try self.emit1(.try_end, 0, line);

                var end_jumps: std.ArrayList(usize) = .empty;
                try end_jumps.append(self.arena, try self.emit1(.jmp, 0, line));

                const handler_pos = self.here();
                self.chunk.code.items[start].a = @intCast(handler_pos);

                // Deferred patch targets: clause i's mismatch jump goes to
                // clause i+1's check (or the rethrow for the last one).
                var check_starts: std.ArrayList(usize) = .empty;
                var mismatch_jumps: std.ArrayList(usize) = .empty;
                for (ts.catches) |cl| {
                    try check_starts.append(self.arena, self.here());
                    const slot = try self.ctx.resolveLocal(self.arena, cl.var_name);
                    self.ctx.markDefined(slot);
                    const mr = self.ctx.alloc();
                    const types_ix: u32 = @intCast(self.chunk.catch_types.items.len);
                    try self.chunk.catch_types.append(self.arena, cl.types);
                    _ = try self.emit3(.catch_match, mr, 0, types_ix, line);
                    try mismatch_jumps.append(self.arena, try self.emit2(.jmp_if_false, mr, 0, line));
                    self.ctx.freeReg(mr);
                    _ = try self.emit2(.catch_store, @intCast(slot), 0, line);
                    try self.compileBody(cl.body);
                    try end_jumps.append(self.arena, try self.emit1(.jmp, 0, line));
                }
                const rethrow_pos = self.here();
                _ = try self.emit1(.rethrow, 0, line);
                for (mismatch_jumps.items, 0..) |j, i| {
                    const target = if (i + 1 < check_starts.items.len)
                        check_starts.items[i + 1]
                    else
                        rethrow_pos;
                    try self.patchBAt(j, target);
                }

                const end_pos = self.here();
                for (end_jumps.items) |j| self.chunk.code.items[j].a = @intCast(end_pos);
            },

            .ret => |maybe_e| {
                if (maybe_e) |e| {
                    const t = try self.exprToTemp(e);
                    _ = try self.emit1(.return_val, t.reg, line);
                    t.release(&self.ctx);
                } else {
                    _ = try self.emit(.return_null, line);
                }
            },

            .brk => |level| try self.jumpOut(level, false, line),
            .cont => |level| try self.jumpOut(level, true, line),
        }
    }

    fn slotOf(self: *Compiler, name: []const u8, line: u32) Error!u32 {
        _ = line;
        const slot = try self.ctx.resolveLocal(self.arena, name);
        return @intCast(slot);
    }

    fn newLoop(self: *Compiler) Error!*LoopCtx {
        const lc = try self.arena.create(LoopCtx);
        lc.* = .{};
        try self.loops.append(self.arena, lc);
        return lc;
    }

    fn jumpOut(self: *Compiler, level: u32, is_continue: bool, line: u32) Error!void {
        if (self.loops.items.len < level) {
            const kw: []const u8 = if (is_continue) "continue" else "break";
            return self.fail(line, "{s} outside of loop", .{kw});
        }
        const lc = self.loops.items[self.loops.items.len - level];
        if (is_continue and lc.is_foreach and level == 1) {
            _ = try self.emit1(.jmp, @intCast(lc.next_addr), line);
            return;
        }
        const j = try self.emit(.jmp, line);
        if (is_continue) {
            try lc.continue_jumps.append(self.arena, j);
        } else {
            try lc.break_jumps.append(self.arena, j);
        }
    }

    fn endLoop(self: *Compiler, lc: *LoopCtx) Error!void {
        _ = self.loops.pop();
        for (lc.continue_jumps.items) |j| {
            self.chunk.code.items[j].a = @intCast(lc.continue_addr);
        }
        for (lc.break_jumps.items) |j| try self.patchA(j);
    }

    fn endLoopForeach(self: *Compiler, lc: *LoopCtx) Error!void {
        _ = self.loops.pop();
        for (lc.continue_jumps.items) |j| {
            self.chunk.code.items[j].a = @intCast(lc.next_addr);
        }
        for (lc.break_jumps.items) |j| try self.patchA(j);
    }

    // -- expressions -----------------------------------------------------------------------

    fn binOpOf(op: ast.BinOp) Op {
        return switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
            .concat => .concat,
            .eq => .eq,
            .neq => .neq,
            .identical => .identical,
            .not_identical => .not_identical,
            .spaceship => .spaceship,
            .lt => .lt,
            .gt => .gt,
            .lte => .lte,
            .gte => .gte,
            .bit_and => .bit_and,
            .bit_or => .bit_or,
            .bit_xor => .bit_xor,
            .shl => .shl,
            .shr => .shr,
            else => unreachable,
        };
    }

    /// Evaluate an expression into a freshly allocated temporary.
    fn exprToTemp(self: *Compiler, e: *ast.Expr) Error!Reg {
        const r = self.ctx.alloc();
        try self.compileInto(r, e);
        return .{ .reg = r, .owned = true };
    }

    /// Evaluate an expression; plain variable reads reuse their slot without
    /// a copy (callers must not free unowned registers).
    fn exprToReg(self: *Compiler, e: *ast.Expr, line: u32) Error!Reg {
        if (e.kind == .var_ref) {
            const name = e.kind.var_ref;
            const slot = try self.ctx.resolveLocal(self.arena, name);
            try self.checkDefined(slot, name, line);
            // Reference slots must be dereferenced into a temp.
            if (self.ctx.ref_slots.contains(slot)) {
                const tmp = self.ctx.alloc();
                _ = try self.emit2(.ld_ref, tmp, @intCast(slot), line);
                return .{ .reg = tmp, .owned = true };
            }
            return .{ .reg = @intCast(slot), .owned = false };
        }
        return self.exprToTemp(e);
    }

    /// Emit an undefined-variable warning instruction for reads of locals
    /// never assigned anywhere in this function (flow-insensitive).
    fn checkDefined(self: *Compiler, slot: usize, name: []const u8, line: u32) Error!void {
        if (self.ctx.defined.contains(slot)) return;
        const boxed = valmod.newStr(self.arena, name) catch return error.OutOfMemory;
        const ci = try self.ctx.func.chunk.addConst(self.arena, .{ .str_ = boxed });
        _ = try self.emit1(.warn_undef, ci, line);
    }

    fn compileBinary(self: *Compiler, b: anytype, dst: u32, line: u32) Error!void {
        switch (b.op) {
            .coalesce => {
                // ?? reads without an undefined warning (PHP semantics).
                if (b.lhs.kind == .var_ref) {
                    const slot = try self.ctx.resolveLocal(self.arena, b.lhs.kind.var_ref);
                    const t = try self.exprToTemp(b.rhs);
                    _ = try self.emit3(.coalesce, dst, @intCast(slot), t.reg, line);
                    t.release(&self.ctx);
                    return;
                }
                const t1 = try self.exprToTemp(b.lhs);
                const t2 = try self.exprToTemp(b.rhs);
                _ = try self.emit3(.coalesce, dst, t1.reg, t2.reg, line);
                t2.release(&self.ctx);
                t1.release(&self.ctx);
            },
            .logic_and => {
                const t1 = try self.exprToTemp(b.lhs);
                _ = try self.emit2(.to_bool, t1.reg, t1.reg, line);
                _ = try self.emit1(.ld_false, dst, line); // pessimistic
                const jf = try self.emit2(.jmp_if_false, t1.reg, 0, line);
                const t2 = try self.exprToTemp(b.rhs);
                _ = try self.emit2(.to_bool, t2.reg, t2.reg, line);
                if (dst != t2.reg) _ = try self.emit2(.mov, dst, t2.reg, line);
                t2.release(&self.ctx);
                try self.patchB(jf);
                t1.release(&self.ctx);
            },
            .logic_or => {
                const t1 = try self.exprToTemp(b.lhs);
                _ = try self.emit2(.to_bool, t1.reg, t1.reg, line);
                _ = try self.emit1(.ld_true, dst, line); // pessimistic
                const jt = try self.emit2(.jmp_if_true, t1.reg, 0, line);
                const t2 = try self.exprToTemp(b.rhs);
                _ = try self.emit2(.to_bool, t2.reg, t2.reg, line);
                if (dst != t2.reg) _ = try self.emit2(.mov, dst, t2.reg, line);
                t2.release(&self.ctx);
                try self.patchB(jt);
                t1.release(&self.ctx);
            },
            .logic_xor => {
                const t1 = try self.exprToTemp(b.lhs);
                const t2 = try self.exprToTemp(b.rhs);
                // xor == neq on truthiness
                _ = try self.emit2(.to_bool, t1.reg, t1.reg, line);
                _ = try self.emit2(.to_bool, t2.reg, t2.reg, line);
                _ = try self.emit3(.neq, dst, t1.reg, t2.reg, line);
                t2.release(&self.ctx);
                t1.release(&self.ctx);
            },
            else => {
                const r1 = try self.exprToReg(b.lhs, line);
                const r2 = try self.exprToReg(b.rhs, line);
                _ = try self.emit3(binOpOf(b.op), dst, r1.reg, r2.reg, line);
                r2.release(&self.ctx);
                r1.release(&self.ctx);
            },
        }
    }

    fn compileInto(self: *Compiler, dst: u32, e: *ast.Expr) Error!void {
        const line = e.line;
        switch (e.kind) {
            .int_lit => |i| {
                const k = try self.chunk.addConst(self.arena, .{ .int_ = i });
                _ = try self.emit2(.ld_const, dst, k, line);
            },
            .float_lit => |f| {
                const k = try self.chunk.addConst(self.arena, .{ .float_ = f });
                _ = try self.emit2(.ld_const, dst, k, line);
            },
            .str_lit => |st| {
                const boxed = try valmod.newStr(self.arena, st);
                const k = try self.chunk.addConst(self.arena, .{ .str_ = boxed });
                _ = try self.emit2(.ld_const, dst, k, line);
            },
            .bool_lit => |b| _ = try self.emit1(if (b) .ld_true else .ld_false, dst, line),
            .null_lit => _ = try self.emit1(.ld_null, dst, line),

            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                try self.checkDefined(slot, name, line);
                if (self.ctx.ref_slots.contains(slot)) {
                    _ = try self.emit2(.ld_ref, dst, @intCast(slot), line);
                } else if (dst != slot) {
                    _ = try self.emit2(.mov, dst, @intCast(slot), line);
                }
            },

            .interp_str => |parts| {
                if (parts.len == 0) {
                    const empty = try valmod.newStr(self.arena, "");
                    const k = try self.chunk.addConst(self.arena, .{ .str_ = empty });
                    _ = try self.emit2(.ld_const, dst, k, line);
                    return;
                }
                const base = self.ctx.allocBlock(parts.len);
                for (parts, 0..) |part, i| {
                    const r = base + @as(u32, @intCast(i));
                    switch (part) {
                        .literal => |lit| {
                            const boxed = try valmod.newStr(self.arena, lit);
                            const k = try self.chunk.addConst(self.arena, .{ .str_ = boxed });
                            _ = try self.emit2(.ld_const, r, k, line);
                        },
                        .var_ref => |name| {
                            const slot = try self.ctx.resolveLocal(self.arena, name);
                            try self.checkDefined(slot, name, line);
                            if (self.ctx.ref_slots.contains(slot)) {
                                _ = try self.emit2(.ld_ref, r, @intCast(slot), line);
                            } else {
                                _ = try self.emit2(.mov, r, @intCast(slot), line);
                            }
                        },
                        .var_index => |vi| {
                            const slot = try self.ctx.resolveLocal(self.arena, vi.name);
                            try self.checkDefined(slot, vi.name, line);
                            if (self.ctx.ref_slots.contains(slot)) {
                                _ = try self.emit2(.ld_ref, r, @intCast(slot), line);
                            } else {
                                _ = try self.emit2(.mov, r, @intCast(slot), line);
                            }
                            for (vi.keys) |key| {
                                const tk = self.ctx.alloc();
                                switch (key) {
                                    .str => |ks| {
                                        const boxed = try valmod.newStr(self.arena, ks);
                                        const k = try self.chunk.addConst(self.arena, .{ .str_ = boxed });
                                        _ = try self.emit2(.ld_const, tk, k, line);
                                    },
                                    .int => |iv| {
                                        const k = try self.chunk.addConst(self.arena, .{ .int_ = iv });
                                        _ = try self.emit2(.ld_const, tk, k, line);
                                    },
                                }
                                _ = try self.emit3(.get_index, r, r, tk, line);
                                self.ctx.freeReg(tk);
                            }
                        },
                    }
                }
                if (parts.len > 1) {
                    _ = try self.emit3(.strconcat, dst, base, @intCast(parts.len), line);
                } else {
                    _ = try self.emit2(.mov, dst, base, line);
                }
                self.ctx.freeBlock(base, parts.len);
            },

            .array_lit => |items| {
                _ = try self.emit1(.new_array, dst, line);
                for (items) |item| {
                    if (item.key) |ke| {
                        const tk = try self.exprToTemp(ke);
                        const tv = try self.exprToTemp(item.val);
                        _ = try self.emit3(.set_index, dst, tk.reg, tv.reg, line);
                        tv.release(&self.ctx);
                        tk.release(&self.ctx);
                    } else {
                        const tv = try self.exprToTemp(item.val);
                        _ = try self.emit2(.append_arr, dst, tv.reg, line);
                        tv.release(&self.ctx);
                    }
                }
            },

            .unary => |u| {
                const t = try self.exprToTemp(u.operand);
                const op: Op = switch (u.op) {
                    .neg => .neg,
                    .pos => .pos,
                    .not => .not,
                    .bit_not => .bit_not,
                };
                _ = try self.emit2(op, dst, t.reg, line);
                t.release(&self.ctx);
            },

            .binary => |b| try self.compileBinary(b, dst, line),

            .ternary => |tn| {
                const tc = try self.exprToTemp(tn.cond);
                if (tn.then) |then_e| {
                    const jf = try self.emit2(.jmp_if_false, tc.reg, 0, line);
                    tc.release(&self.ctx);
                    try self.compileInto(dst, then_e);
                    const jend = try self.emit(.jmp, line);
                    try self.patchB(jf);
                    try self.compileInto(dst, tn.els);
                    try self.patchA(jend);
                } else {
                    // Shorthand `$a ?: b`: cond is also the then-value.
                    _ = try self.emit2(.mov, dst, tc.reg, line);
                    _ = try self.emit2(.jmp_if_true, dst, 0, line);
                    tc.release(&self.ctx);
                    try self.compileInto(dst, tn.els);
                }
            },

            .assign => try self.compileAssign(dst, e, line),

            .inc_dec => |d| try self.compileIncDec(dst, d.target, d.up, d.postfix, line),

            .call => |c| {
                // Reserve at least one register so the result slot always
                // exists even for zero-argument calls.
                const n = @max(c.args.len, 1);
                const base = self.ctx.allocBlock(n);
                // Resolve the callee at compile time to learn by-ref params.
                const callee: ?*Func = self.program.funcs.get(c.name);
                for (c.args, 0..) |ae, i| {
                    const arg_dst = base + @as(u32, @intCast(i));
                    if (ae.kind == .ref_arg) {
                        try self.compileInto(arg_dst, ae);
                        continue;
                    }
                    if (callee) |cf| {
                        // By-ref parameter with an lvalue argument?
                        if (i < cf.by_ref_params.len and cf.by_ref_params[i]) {
                            switch (ae.kind) {
                                .var_ref => |vn| {
                                    const vslot = try self.ctx.resolveLocal(self.arena, vn);
                                    try self.checkDefined(vslot, vn, line);
                                    try self.ctx.ref_slots.put(self.arena, vslot, {});
                                    _ = try self.emit2(.make_ref_cell, arg_dst, @intCast(vslot), line);
                                    continue;
                                },
                                .index => |ix| {
                                    const tb = try self.exprToReg(ix.base, line);
                                    const tk = try self.exprToTemp(ix.index orelse
                                        return self.fail(line, "cannot reference-append", .{}));
                                    _ = try self.emit3(.elem_cell, arg_dst, tb.reg, tk.reg, line);
                                    tk.release(&self.ctx);
                                    tb.release(&self.ctx);
                                    continue;
                                },
                                else => {},
                            }
                        }
                    }
                    try self.compileInto(arg_dst, ae);
                }
                const k = try self.nameConst(c.name);
                _ = try self.emit3(.call, @intCast(c.args.len), base, k, line);
                // Result overwrites regs[base].
                if (dst != base) _ = try self.emit2(.mov, dst, base, line);
                self.ctx.freeBlock(base, n);
            },

            .index => |ix| {
                const tb = try self.exprToReg(ix.base, line);
                const tk = try self.exprToTemp(ix.index orelse {
                    return self.fail(line, "cannot read from array without an index", .{});
                });
                _ = try self.emit3(.get_index, dst, tb.reg, tk.reg, line);
                tk.release(&self.ctx);
                tb.release(&self.ctx);
            },

            .new => |n| {
                // Convention: regs[base] = instance slot, args at base+1..
                const n2 = n.args.len + 1;
                const base = self.ctx.allocBlock(n2);
                for (n.args, 0..) |ae, i| try self.compileInto(base + 1 + @as(u32, @intCast(i)), ae);
                const k = try self.nameConst(n.class_name);
                _ = try self.emit3(.new_obj, @intCast(n.args.len), base, k, line);
                if (dst != base) _ = try self.emit2(.mov, dst, base, line);
                self.ctx.freeBlock(base, n2);
            },

            .prop_get => |pg| {
                const to = try self.exprToReg(pg.obj, line);
                const k = try self.nameConst(pg.name);
                _ = try self.emit3(.get_prop, dst, to.reg, k, line);
                to.release(&self.ctx);
            },

            .method_call => |mc| {
                // Convention: regs[base] = instance (becomes $this),
                // regs[base+1..] = declared arguments.
                const n2 = mc.args.len + 1;
                const base = self.ctx.allocBlock(n2);
                const to = try self.exprToReg(mc.obj, line);
                _ = try self.emit2(.mov, base, to.reg, line);
                to.release(&self.ctx);
                for (mc.args, 0..) |ae, i| try self.compileInto(base + 1 + @as(u32, @intCast(i)), ae);
                const k = try self.nameConst(mc.name);
                _ = try self.emit3(.call_method, @intCast(mc.args.len), base, k, line);
                // Result overwrites regs[base].
                if (dst != base) _ = try self.emit2(.mov, dst, base, line);
                self.ctx.freeBlock(base, n2);
            },

            .instanceof => |io| {
                const t = try self.exprToTemp(io.operand);
                const k = try self.nameConst(io.class_name);
                _ = try self.emit3(.instanceof, dst, t.reg, k, line);
                t.release(&self.ctx);
            },

            .static_get => |sg| {
                const kcls = try self.nameConst(sg.cls);
                const kname = try self.nameConst(sg.name);
                _ = try self.emit3(.static_get, dst, kcls, kname, line);
            },
            .static_set => |ss| {
                const tv = try self.exprToTemp(ss.value);
                const kcls = try self.nameConst(ss.cls);
                const kname = try self.nameConst(ss.name);
                _ = try self.emit3(.static_set, kcls, kname, tv.reg, line);
                _ = try self.emit2(.mov, dst, tv.reg, line);
                tv.release(&self.ctx);
            },
            .static_call => |sc| {
                const n2 = @max(sc.args.len, 1);
                const base = self.ctx.allocBlock(n2);
                for (sc.args, 0..) |ae, i| try self.compileInto(base + @as(u32, @intCast(i)), ae);
                const kn = try self.nameConst(sc.name);
                const kc = try self.nameConst(sc.cls);
                _ = try self.emit3(.static_call, @intCast(sc.args.len), base, kn, line);
                _ = try self.emitInline(kc, line); // class const idx as inline word
                if (dst != base) _ = try self.emit2(.mov, dst, base, line);
                self.ctx.freeBlock(base, n2);
            },
            .ref_arg => |inner| {
                // By-reference argument: materialize the lvalue's container.
                switch (inner.kind) {
                    .var_ref => |name| {
                        const slot = try self.ctx.resolveLocal(self.arena, name);
                        try self.checkDefined(slot, name, line);
                        _ = try self.emit2(.make_ref_cell, dst, @intCast(slot), line);
                    },
                    .index => |ix| {
                        const tb = try self.exprToReg(ix.base, line);
                        const tk = try self.exprToTemp(ix.index orelse
                            return self.fail(line, "cannot reference-append", .{}));
                        _ = try self.emit3(.elem_cell, dst, tb.reg, tk.reg, line);
                        tk.release(&self.ctx);
                        tb.release(&self.ctx);
                    },
                    else => return self.fail(line, "only variables can be passed by reference", .{}),
                }
            },

            .isset => |exprs| {
                try self.compileIssetOne(dst, exprs[0], line);
                for (exprs[1..]) |x| {
                    const jf = try self.emit2(.jmp_if_false, dst, 0, line);
                    try self.compileIssetOne(dst, x, line);
                    try self.patchB(jf);
                }
            },

            .empty => |inner| {
                const t = try self.exprToTemp(inner);
                _ = try self.emit2(.to_bool, t.reg, t.reg, line);
                _ = try self.emit2(.not, dst, t.reg, line);
                t.release(&self.ctx);
            },
        }
    }

    fn compileIssetOne(self: *Compiler, dst: u32, x: *ast.Expr, line: u32) Error!void {
        switch (x.kind) {
            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                _ = try self.emit2(.isset_local, dst, @intCast(slot), line);
            },
            .index => |ix| {
                const tb = try self.exprToReg(ix.base, line);
                const tk = try self.exprToTemp(ix.index orelse {
                    return self.fail(line, "invalid isset() operand", .{});
                });
                _ = try self.emit3(.isset_index, dst, tb.reg, tk.reg, line);
                tk.release(&self.ctx);
                tb.release(&self.ctx);
            },
            else => {
                const t = try self.exprToTemp(x);
                _ = try self.emit2(.is_not_null, dst, t.reg, line);
                t.release(&self.ctx);
            },
        }
    }

    /// Leave a vivified array pointer in `dst` — the array that receives the
    /// caller's key write (`$undefined['a']['b'] = 1` auto-vivifies).
    fn compileContainerPath(self: *Compiler, dst: u32, base: *ast.Expr, line: u32) Error!void {
        switch (base.kind) {
            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                if (self.ctx.ref_slots.contains(slot)) {
                    // Reference to the container: deref first.
                    _ = try self.emit2(.ld_ref, dst, @intCast(slot), line);
                } else {
                    _ = try self.emit2(.vivify_local, dst, @intCast(slot), line);
                }
            },
            .index => |ix| {
                const parent = self.ctx.alloc();
                try self.compileContainerPath(parent, ix.base, line);
                const tk = try self.exprToTemp(ix.index orelse {
                    return self.fail(line, "invalid assignment target", .{});
                });
                _ = try self.emit3(.subcontainer, dst, parent, tk.reg, line);
                self.ctx.freeReg(tk.reg);
                self.ctx.freeReg(parent);
            },
            else => return self.fail(line, "invalid assignment target", .{}),
        }
    }

    fn compileAssign(self: *Compiler, dst: u32, e: *ast.Expr, line: u32) Error!void {
        const a = e.kind.assign;
        switch (a.target.kind) {
            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                const is_ref = self.ctx.ref_slots.contains(slot);

                // `$lhs =& $rhs` — share containers.
                if (a.by_ref and a.op == .assign) {
                    switch (a.value.kind) {
                        .var_ref => {
                            const rslot = try self.ctx.resolveLocal(self.arena, a.value.kind.var_ref);
                            try self.checkDefined(rslot, a.value.kind.var_ref, line);
                            // Promote the source slot and copy its cell into
                            // the target slot.
                            _ = try self.emit2(.make_ref_cell, @intCast(rslot), @intCast(rslot), line);
                            _ = try self.emit2(.bind_ref, @intCast(slot), @intCast(rslot), line);
                        },
                        else => return self.fail(line, "=& expects a variable on the right-hand side", .{}),
                    }
                    self.ctx.markDefined(slot);
                    if (dst != slot) _ = try self.emit2(.mov, dst, @intCast(slot), line);
                    return;
                }

                if (is_ref) {
                    // Dereferenced read-modify-write through the shared cell.
                    switch (a.op) {
                        .assign => {
                            const tv = try self.exprToTemp(a.value);
                            _ = try self.emit2(.st_ref, @intCast(slot), @intCast(tv.reg), line);
                            tv.release(&self.ctx);
                        },
                        .coalesce => {
                            const told = self.ctx.alloc();
                            _ = try self.emit2(.ld_ref, told, @intCast(slot), line);
                            const tv = try self.exprToTemp(a.value);
                            _ = try self.emit3(.coalesce, told, told, tv.reg, line);
                            _ = try self.emit2(.st_ref, @intCast(slot), told, line);
                            self.ctx.freeReg(tv.reg);
                            self.ctx.freeReg(told);
                        },
                        else => {
                            try self.checkDefined(slot, name, line);
                            const told = self.ctx.alloc();
                            _ = try self.emit2(.ld_ref, told, @intCast(slot), line);
                            const tv = try self.exprToTemp(a.value);
                            _ = try self.emit3(binOpOf(compoundBinOp(a.op)), tv.reg, told, tv.reg, line);
                            _ = try self.emit2(.st_ref, @intCast(slot), tv.reg, line);
                            self.ctx.freeReg(tv.reg);
                            self.ctx.freeReg(told);
                        },
                    }
                    self.ctx.markDefined(slot);
                    if (dst != slot) {
                        _ = try self.emit2(.ld_ref, dst, @intCast(slot), line);
                    }
                    return;
                }

                switch (a.op) {
                    .assign => {
                        try self.compileInto(@intCast(slot), a.value);
                        self.ctx.markDefined(slot);
                    },
                    .coalesce => {
                        const tv = try self.exprToReg(a.value, line);
                        _ = try self.emit3(.coalesce, @intCast(slot), @intCast(slot), tv.reg, line);
                        tv.release(&self.ctx);
                        self.ctx.markDefined(slot);
                    },
                    else => {
                        // Reading the target is itself a potential undef read.
                        try self.checkDefined(slot, name, line);
                        const tv = try self.exprToReg(a.value, line);
                        _ = try self.emit3(binOpOf(compoundBinOp(a.op)), @intCast(slot), @intCast(slot), tv.reg, line);
                        tv.release(&self.ctx);
                        self.ctx.markDefined(slot);
                    },
                }
                if (dst != slot) _ = try self.emit2(.mov, dst, @intCast(slot), line);
            },

            .index => |ix| {
                const parent = self.ctx.alloc();
                try self.compileContainerPath(parent, ix.base, line);

                if (ix.index == null) {
                    // $a[] = v — append
                    if (a.op != .assign) {
                        return self.fail(line, "[] operator supports only append assignment", .{});
                    }
                    const tv = try self.exprToTemp(a.value);
                    _ = try self.emit2(.append_arr, parent, tv.reg, line);
                    if (dst != tv.reg) _ = try self.emit2(.mov, dst, tv.reg, line);
                    tv.release(&self.ctx);
                    self.ctx.freeReg(parent);
                    return;
                }

                const tk = try self.exprToTemp(ix.index.?);

                switch (a.op) {
                    .assign => {
                        const tv = try self.exprToTemp(a.value);
                        _ = try self.emit3(.set_index, parent, tk.reg, tv.reg, line);
                        if (dst != tv.reg) _ = try self.emit2(.mov, dst, tv.reg, line);
                        tv.release(&self.ctx);
                    },
                    .coalesce => {
                        const told = self.ctx.alloc();
                        _ = try self.emit3(.get_index, told, parent, tk.reg, line);
                        const tv = try self.exprToTemp(a.value);
                        _ = try self.emit3(.coalesce, told, told, tv.reg, line);
                        _ = try self.emit3(.set_index, parent, tk.reg, told, line);
                        if (dst != told) _ = try self.emit2(.mov, dst, told, line);
                        self.ctx.freeReg(tv.reg);
                        self.ctx.freeReg(told);
                    },
                    else => {
                        const told = self.ctx.alloc();
                        _ = try self.emit3(.get_index, told, parent, tk.reg, line);
                        const tv = try self.exprToTemp(a.value);
                        _ = try self.emit3(binOpOf(compoundBinOp(a.op)), tv.reg, told, tv.reg, line);
                        _ = try self.emit3(.set_index, parent, tk.reg, tv.reg, line);
                        if (dst != tv.reg) _ = try self.emit2(.mov, dst, tv.reg, line);
                        self.ctx.freeReg(tv.reg);
                        self.ctx.freeReg(told);
                    },
                }
                self.ctx.freeReg(tk.reg);
                self.ctx.freeReg(parent);
            },

            .static_get => |sg| {
                // Cls::$name = v / += etc.
                const kcls = try self.nameConst(sg.cls);
                const kname = try self.nameConst(sg.name);
                if (a.op == .assign) {
                    const tv = try self.exprToTemp(a.value);
                    _ = try self.emit3(.static_set, kcls, kname, tv.reg, line);
                    _ = try self.emit2(.mov, dst, tv.reg, line);
                    tv.release(&self.ctx);
                } else {
                    const told = self.ctx.alloc();
                    _ = try self.emit3(.static_get, told, kcls, kname, line);
                    const tv = try self.exprToTemp(a.value);
                    _ = try self.emit3(binOpOf(compoundBinOp(a.op)), tv.reg, told, tv.reg, line);
                    _ = try self.emit3(.static_set, kcls, kname, tv.reg, line);
                    if (dst != tv.reg) _ = try self.emit2(.mov, dst, tv.reg, line);
                    self.ctx.freeReg(tv.reg);
                    self.ctx.freeReg(told);
                }
            },

            .prop_get => |pg| {
                const to = try self.exprToTemp(pg.obj);
                const k = try self.nameConst(pg.name);
                switch (a.op) {
                    .assign => {
                        const tv = try self.exprToTemp(a.value);
                        _ = try self.emit3(.set_prop, to.reg, k, tv.reg, line);
                        if (dst != tv.reg) _ = try self.emit2(.mov, dst, tv.reg, line);
                        tv.release(&self.ctx);
                    },
                    else => {
                        const told = self.ctx.alloc();
                        _ = try self.emit3(.get_prop, told, to.reg, k, line);
                        const tv = try self.exprToTemp(a.value);
                        _ = try self.emit3(binOpOf(compoundBinOp(a.op)), tv.reg, told, tv.reg, line);
                        _ = try self.emit3(.set_prop, to.reg, k, tv.reg, line);
                        if (dst != tv.reg) _ = try self.emit2(.mov, dst, tv.reg, line);
                        self.ctx.freeReg(tv.reg);
                        self.ctx.freeReg(told);
                    },
                }
                to.release(&self.ctx);
            },

            else => return self.fail(line, "invalid assignment target", .{}),
        }
    }

    fn compileIncDec(self: *Compiler, dst: u32, target: *ast.Expr, up: bool, postfix: bool, line: u32) Error!void {
        switch (target.kind) {
            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                try self.checkDefined(slot, name, line);
                if (self.ctx.ref_slots.contains(slot)) {
                    // ld_ref / inc / st_ref sequence.
                    const told = self.ctx.alloc();
                    _ = try self.emit2(.ld_ref, told, @intCast(slot), line);
                    if (postfix) {
                        const told_old = self.ctx.alloc();
                        _ = try self.emit2(.mov, told_old, told, line);
                        _ = try self.emit1(if (up) .inc_l else .dec_l, told, line);
                        _ = try self.emit2(.st_ref, @intCast(slot), told, line);
                        // Result register may BE the slot (statement fusion);
                        // never overwrite it with a raw value.
                        if (dst != slot) _ = try self.emit2(.mov, dst, told_old, line);
                        self.ctx.freeReg(told_old);
                    } else {
                        _ = try self.emit1(if (up) .inc_l else .dec_l, told, line);
                        _ = try self.emit2(.st_ref, @intCast(slot), told, line);
                        if (dst != slot) _ = try self.emit2(.mov, dst, told, line);
                    }
                    self.ctx.freeReg(told);
                    self.ctx.markDefined(slot);
                } else if (postfix) {
                    // dst = old; slot = old +/- 1
                    const op: Op = if (up) .post_inc_l else .post_dec_l;
                    _ = try self.emit2(op, dst, @intCast(slot), line);
                } else {
                    // slot +/-= 1; dst = new
                    const op: Op = if (up) .inc_l else .dec_l;
                    _ = try self.emit1(op, @intCast(slot), line);
                    if (dst != slot) _ = try self.emit2(.mov, dst, @intCast(slot), line);
                }
                self.ctx.markDefined(slot);
            },
            .index => |ix| {
                const parent = self.ctx.alloc();
                try self.compileContainerPath(parent, ix.base, line);
                const tk = try self.exprToTemp(ix.index orelse {
                    return self.fail(line, "cannot increment without an index", .{});
                });
                if (postfix) {
                    const op: Op = if (up) .post_inc_idx else .post_dec_idx;
                    _ = try self.emit3(op, dst, parent, tk.reg, line);
                } else {
                    const op: Op = if (up) .inc_idx else .dec_idx;
                    _ = try self.emit3(op, parent, tk.reg, 0, line);
                    _ = try self.emit3(.get_index, dst, parent, tk.reg, line); // new value
                }
                self.ctx.freeReg(tk.reg);
                self.ctx.freeReg(parent);
            },
            .static_get => |sg| {
                const kcls = try self.nameConst(sg.cls);
                const kname = try self.nameConst(sg.name);
                if (postfix) {
                    const told = self.ctx.alloc();
                    _ = try self.emit3(.static_get, told, kcls, kname, line);
                    _ = try self.emit1(if (up) .inc_l else .dec_l, told, line);
                    _ = try self.emit3(.static_set, kcls, kname, told, line);
                    _ = try self.emit2(.mov, dst, told, line); // old value
                    self.ctx.freeReg(told);
                } else {
                    const told = self.ctx.alloc();
                    _ = try self.emit3(.static_get, told, kcls, kname, line);
                    _ = try self.emit1(if (up) .inc_l else .dec_l, told, line);
                    _ = try self.emit3(.static_set, kcls, kname, told, line);
                    _ = try self.emit2(.mov, dst, told, line); // new value
                    self.ctx.freeReg(told);
                }
            },
            .prop_get => |pg| {
                const to = try self.exprToTemp(pg.obj);
                const k = try self.nameConst(pg.name);
                if (postfix) {
                    // dst = old value
                    const op: Op = if (up) .prop_post_inc else .prop_post_dec;
                    _ = try self.emit3(op, dst, to.reg, k, line);
                } else {
                    // dst = new value
                    const op: Op = if (up) .prop_pre_inc else .prop_pre_dec;
                    _ = try self.emit3(op, dst, to.reg, k, line);
                }
                to.release(&self.ctx);
            },
            else => return self.fail(line, "invalid increment/decrement target", .{}),
        }
    }

    fn compileExprStmt(self: *Compiler, e: *ast.Expr) Error!void {
        const line = e.line;
        // Statement-level fusion: assignments/inc-dec whose results are
        // discarded write straight into their target register.
        switch (e.kind) {
            .assign => |a| {
                if (a.target.kind == .var_ref) {
                    // Compile with dst == target slot; no extra move.
                    const slot = try self.ctx.resolveLocal(self.arena, a.target.kind.var_ref);
                    try self.compileAssign(@intCast(slot), e, line);
                    return;
                }
                if (a.target.kind == .index) {
                    const discard = self.ctx.alloc();
                    try self.compileAssign(discard, e, line);
                    self.ctx.freeReg(discard);
                    return;
                }
            },
            .inc_dec => |d| {
                // Pre-increment as a statement is a pure in-place mutation;
                // its (new-value) result is discarded.
                switch (d.target.kind) {
                    .var_ref => |name| {
                        const slot = try self.ctx.resolveLocal(self.arena, name);
                        try self.compileIncDec(@intCast(slot), d.target, d.up, false, line);
                        return;
                    },
                    .index => {
                        const discard = self.ctx.alloc();
                        try self.compileIncDec(discard, d.target, d.up, false, line);
                        self.ctx.freeReg(discard);
                        return;
                    },
                    else => {},
                }
            },
            else => {},
        }
        const t = try self.exprToTemp(e);
        t.release(&self.ctx);
    }

    // -- fused compare-and-branch -------------------------------------------------

    fn release(self: *Compiler, r: Reg) void {
        if (r.owned) self.ctx.freeReg(r.reg);
    }

    fn cmpSelOf(op: ast.BinOp) ?opcode.CmpSel {
        return switch (op) {
            .lt => .lt,
            .gt => .gt,
            .lte => .lte,
            .gte => .gte,
            .eq => .eq,
            .neq => .neq,
            else => null,
        };
    }

    const FusedOperand = union(enum) {
        local: u32,
        constant: u32, // const pool index
    };

    fn fusedOperand(self: *Compiler, e: *ast.Expr) Error!?FusedOperand {
        switch (e.kind) {
            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                if (slot > 0x1FFF) return null;
                return .{ .local = @intCast(slot) };
            },
            else => {
                const cv = constEval(e, self.arena) orelse return null;
                const idx = self.chunk.addConst(self.arena, cv) catch return error.OutOfMemory;
                if (idx > 0xFFFFFF) return null;
                return .{ .constant = idx };
            },
        }
    }

    /// Fuse `local CMP (local|const)` loop conditions into a single
    /// compare-and-branch instruction. Returns the position of the inline
    /// word holding the loop-exit target, or null when not applicable.
    fn tryEmitCondJump(self: *Compiler, cond: *ast.Expr, line: u32) Error!?usize {
        if (cond.kind != .binary) return null;
        const b = cond.kind.binary;
        var sel = cmpSelOf(b.op) orelse return null;

        var lhs = try self.fusedOperand(b.lhs);
        var rhs = try self.fusedOperand(b.rhs);

        if (lhs == null or rhs == null) return null;

        // Normalize to local-first form.
        if (lhs.? == .constant) {
            sel = switch (sel) {
                .lt => .gt,
                .gt => .lt,
                .lte => .gte,
                .gte => .lte,
                .eq => .eq,
                .neq => .neq,
            };
            const tmp = lhs;
            lhs = rhs;
            rhs = tmp;
        }
        if (lhs.? != .local) return null; // const CMP const: pointless

        const slot: u32 = lhs.?.local;
        switch (rhs.?) {
            .local => |slot2| {
                const arg: u32 = @as(u32, @intFromEnum(sel)) << 26 |
                    (slot2 << 13) | slot;
                _ = try self.emit1(.if_cmp_jmp_ll, arg, line);
                return try self.emitInline(0, line); // target patched by caller
            },
            .constant => |ci| {
                const arg: u32 = (@as(u32, @intFromEnum(sel)) << 24) | slot;
                _ = try self.emit1(.if_cmp_jmp_lc, arg, line);
                _ = try self.emitInline(ci, line);
                return try self.emitInline(0, line);
            },
        }
    }
};

fn compoundBinOp(op: ast.AssignOp) ast.BinOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .concat => .concat,
        .coalesce => unreachable,
        .assign => unreachable,
    };
}

/// Evaluate a compile-time constant expression (literal / unary minus).
fn constEval(e: *ast.Expr, a: std.mem.Allocator) ?Value {
    return switch (e.kind) {
        .int_lit => |i| Value{ .int_ = i },
        .float_lit => |f| Value{ .float_ = f },
        .str_lit => |st| blk: {
            const s = valmod.newStr(a, st) catch break :blk null;
            break :blk Value{ .str_ = s };
        },
        .bool_lit => |b| Value{ .bool_ = b },
        .null_lit => Value.null_,
        .unary => |u| switch (u.op) {
            .neg => switch (constEval(u.operand, a) orelse return null) {
                .int_ => |i| Value{ .int_ = -i },
                .float_ => |fl| Value{ .float_ = -fl },
                else => null,
            },
            .pos => constEval(u.operand, a),
            else => null,
        },
        else => null,
    };
}
