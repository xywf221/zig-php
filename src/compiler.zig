//! Bytecode compiler: AST -> stack-machine bytecode.
//!
//! Scope model (matching PHP):
//!   * the top-level script reads/writes the globals map,
//!   * each function body gets fresh local slots,
//!   * foreach iterators live in per-frame temp slot pairs.

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

/// Compiled program: top-level script + all function units.
pub const Program = struct {
    main_func: *Func,
    funcs: std.StringHashMapUnmanaged(*Func) = .empty,
};

pub const Compiler = struct {
    arena: std.mem.Allocator,
    diag: *Diag,
    ctx: *FnCtx,
    chunk: *Chunk,
    loops: std.ArrayList(*LoopCtx) = .empty,

    /// Per-function-unit compilation state.
    const FnCtx = struct {
        func: *Func,
        locals: std.StringHashMapUnmanaged(usize) = .empty,
        ntemps: u32 = 0,
        is_global_scope: bool,

        fn resolveLocal(self: *FnCtx, a: std.mem.Allocator, name: []const u8) Error!usize {
            if (self.locals.get(name)) |s| return s;
            const slot = self.locals.count();
            try self.locals.put(a, name, slot);
            self.func.nlocals = @max(self.func.nlocals, slot + 1);
            return slot;
        }

        fn newTemp(self: *FnCtx) u32 {
            const t = self.ntemps;
            self.ntemps += 2; // snapshot + cursor
            self.func.ntemps = self.ntemps;
            return t;
        }
    };

    const LoopCtx = struct {
        /// Where `continue` jumps: condition re-test for while/do-while/for,
        /// iterator advance for foreach.
        continue_addr: usize = 0,
        is_foreach: bool = false,
        next_addr: usize = 0, // foreach_next instruction index
        continue_jumps: std.ArrayList(usize) = .empty,
        break_jumps: std.ArrayList(usize) = .empty,
    };

    // -- entry points ------------------------------------------------------------

    pub fn compile(arena: std.mem.Allocator, prog_ast: []const *ast.Stmt, diag: *Diag) Error!*Program {
        const program = try arena.create(Program);

        // Top-level unit.
        const main_func = try arena.create(Func);
        main_func.* = .{ .name = "<main>", .arity = 0 };
        // Top-level variables live in the main frame's slots rather than the
        // globals map: PHP scoping keeps them invisible to functions anyway
        // (no \ keyword in the minimal core), and slot access avoids
        // a hash lookup per variable operation in hot loops.
        var main_ctx = FnCtx{ .func = main_func, .is_global_scope = false };
        {
            var c = Compiler{ .arena = arena, .diag = diag, .ctx = &main_ctx, .chunk = &main_func.chunk };
            try c.compileStmts(prog_ast);
            _ = try c.rawEmit(.return_null, 0);
        }
        program.* = .{ .main_func = main_func };

        // Function units.
        try collectFuncs(arena, prog_ast, program, diag);
        return program;
    }

    fn collectFuncs(arena: std.mem.Allocator, stmts: []const *ast.Stmt, program: *Program, diag: *Diag) Error!void {
        for (stmts) |s| try collectFuncsStmt(arena, s, program, diag);
    }

    /// Walk every statement tree — functions may be declared conditionally
    /// or nested inside other functions.
    fn collectFuncsStmt(arena: std.mem.Allocator, st: *ast.Stmt, program: *Program, diag: *Diag) Error!void {
        switch (st.kind) {
            .func_decl => |fd| {
                if (program.funcs.contains(fd.name)) return; // first wins
                const f = try compileFuncUnit(arena, fd, diag);
                try program.funcs.put(arena, fd.name, f);
                try collectFuncs(arena, fd.body, program, diag);
            },
            .block => |stmts| try collectFuncs(arena, stmts, program, diag),
            .if_stmt => |info| {
                for (info.branches) |b| try collectFuncsStmt(arena, b.body, program, diag);
                if (info.else_body) |eb| try collectFuncsStmt(arena, eb, program, diag);
            },
            .while_stmt => |w| try collectFuncsStmt(arena, w.body, program, diag),
            .do_while => |dw| try collectFuncsStmt(arena, dw.body, program, diag),
            .for_stmt => |f| try collectFuncsStmt(arena, f.body, program, diag),
            .foreach => |fe| try collectFuncsStmt(arena, fe.body, program, diag),
            else => {},
        }
    }

    fn compileFuncUnit(arena: std.mem.Allocator, fd: ast.Stmt.FuncDecl, diag: *Diag) Error!*Func {
        const f = try arena.create(Func);
        f.* = .{
            .name = fd.name,
            .arity = fd.params.len,
            .defaults = try arena.alloc(?Value, fd.params.len),
        };
        for (f.defaults) |*d| d.* = null;

        // The minimal core supports constant default values only.
        for (fd.params, 0..) |p, i| {
            if (p.default) |de| {
                f.defaults[i] = constEval(de) orelse {
                    diag.msg = try std.fmt.allocPrint(arena, "unsupported default parameter expression in {s}() (compile-time constants only)", .{fd.name});
                    diag.line = de.line;
                    return error.SyntaxError;
                };
            }
        }

        var ctx = FnCtx{ .func = f, .is_global_scope = false };
        var c = Compiler{ .arena = arena, .diag = diag, .ctx = &ctx, .chunk = &f.chunk };
        // Pre-declare parameter slots so argument binding order matches.
        for (fd.params) |p| _ = try ctx.resolveLocal(arena, p.name);
        try c.compileStmts(fd.body);
        _ = try c.rawEmit(.return_null, 0);
        return f;
    }

    // -- low-level emit helpers -----------------------------------------------------

    fn rawEmit(self: *Compiler, op: Op, line: u32) Error!usize {
        _ = self.chunk.emitArg(self.arena, op, 0, line) catch return error.OutOfMemory;
        return self.chunk.code.items.len - 1;
    }

    fn emit(self: *Compiler, op: Op, line: u32) Error!usize {
        return self.emitArg(op, 0, line);
    }

    fn emitArg(self: *Compiler, op: Op, arg: u32, line: u32) Error!usize {
        _ = self.chunk.emitArg(self.arena, op, arg, line) catch return error.OutOfMemory;
        return self.chunk.code.items.len - 1;
    }

    fn emitInline(self: *Compiler, word: u32, line: u32) Error!usize {
        _ = self.chunk.emitArg(self.arena, .inline_arg, word, line) catch return error.OutOfMemory;
        return self.chunk.code.items.len - 1;
    }

    fn patchJmp(self: *Compiler, addr: usize) Error!void {
        self.chunk.code.items[addr].arg = @intCast(self.chunk.code.items.len);
    }

    fn here(self: *Compiler) usize {
        return self.chunk.code.items.len;
    }

    fn nameConst(self: *Compiler, name: []const u8, line: u32) Error!u32 {
        _ = line;
        return self.chunk.addConst(self.arena, .{ .str_ = name }) catch |e| switch (e) {
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

    fn compileStmts(self: *Compiler, stmts: []const *ast.Stmt) Error!void {
        for (stmts) |s| try self.compileStmt(s);
    }

    // -- statements --------------------------------------------------------------------

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
            .expr => |e| {
                // Statement-level fusion: `$x += y;` / `$x -= const;` /
                // `$i++;` discard their results, so a single fused
                // instruction replaces the whole read-modify-write chain.
                if (try self.tryEmitFusedAssignStmt(e)) return;
                try self.compileExpr(e);
                _ = try self.emit(.pop, line);
            },
            .echo => |exprs| {
                for (exprs) |e| try self.compileExpr(e);
                _ = try self.emitArg(.echo, @intCast(exprs.len), line);
            },
            .block => |stmts| try self.compileStmts(stmts),

            .if_stmt => |info| {
                var end_jumps: std.ArrayList(usize) = .empty;
                for (info.branches) |branch| {
                    try self.compileExpr(branch.cond);
                    const jf = try self.emit(.jmp_if_false, branch.cond.line);
                    try self.compileBody(branch.body);
                    try end_jumps.append(self.arena, try self.emit(.jmp, line));
                    try self.patchJmp(jf);
                }
                if (info.else_body) |eb| try self.compileBody(eb);
                for (end_jumps.items) |j| try self.patchJmp(j);
            },

            .while_stmt => |w| {
                const lc = try self.newLoop();
                lc.continue_addr = self.here();

                // Hot-path fusion: `local CMP (local|const)` becomes a
                // single compare-and-branch instruction.
                var fused_exit: ?usize = null;
                if (try self.tryEmitCondJump(w.cond, line)) |pos| {
                    fused_exit = pos;
                } else {
                    try self.compileExpr(w.cond);
                }

                var exit_jump: ?usize = null;
                if (fused_exit == null) exit_jump = try self.emit(.jmp_if_false, line);
                try self.compileBody(w.body);
                _ = try self.emitArg(.jmp, @intCast(lc.continue_addr), line);
                if (fused_exit) |pos| {
                    self.chunk.code.items[pos].arg = @intCast(self.here());
                } else if (exit_jump) |ej| {
                    try self.patchJmp(ej);
                }
                try self.endLoop(lc);
            },

            .do_while => |dw| {
                const body_start = self.here();
                const lc = try self.newLoop();

                try self.compileBody(dw.body);
                lc.continue_addr = self.here(); // continue -> condition test
                try self.compileExpr(dw.cond);
                _ = try self.emitArg(.jmp_if_true, @intCast(body_start), line);
                try self.endLoop(lc);
            },

            .for_stmt => |f| {
                for (f.init) |e| {
                    try self.compileExpr(e);
                    _ = try self.emit(.pop, e.line);
                }
                const cond_addr = self.here();
                const lc = try self.newLoop();
                lc.continue_addr = 0; // patched to step exprs below

                var exit_jump: ?usize = null;
                var fused_exit: ?usize = null;
                if (f.cond) |cond| {
                    if (try self.tryEmitCondJump(cond, line)) |pos| {
                        fused_exit = pos;
                    } else {
                        try self.compileExpr(cond);
                        exit_jump = try self.emit(.jmp_if_false, line);
                    }
                }
                try self.compileBody(f.body);
                const step_addr = self.here();
                lc.continue_addr = step_addr; // continue -> step expressions
                for (f.step) |e| {
                    if (try self.tryEmitFusedAssignStmt(e)) continue;
                    try self.compileExpr(e);
                    _ = try self.emit(.pop, e.line);
                }
                _ = try self.emitArg(.jmp, @intCast(cond_addr), line);
                if (exit_jump) |ej| try self.patchJmp(ej);
                if (fused_exit) |pos| {
                    self.chunk.code.items[pos].arg = @intCast(self.here());
                }
                try self.endLoop(lc);
            },

            .foreach => |fe| {
                try self.compileExpr(fe.subject);
                const temp = self.ctx.newTemp();
                _ = try self.emitArg(.foreach_init, temp, line);

                const lc = try self.newLoop();
                lc.is_foreach = true;
                lc.next_addr = self.here();
                const packed_arg = opcode.packForeach(temp, fe.key != null);
                _ = try self.emitArg(.foreach_next, packed_arg, line);
                // Loop-exit target follows as immediate data.
                const inline_pos = self.here();
                _ = try self.emitInline(0, line); // patched after body

                // Bind value then key — foreach_next pushed [key?] value,
                // so the value sits on top and must be stored first.
                try self.bindForeachVar(fe.val, line);
                if (fe.key) |k| try self.bindForeachVar(k, line);

                try self.compileBody(fe.body);
                _ = try self.emitArg(.jmp, @intCast(lc.next_addr), line);
                self.chunk.code.items[inline_pos].arg = @intCast(self.here());
                try self.endLoopForeach(lc);
            },

            .func_decl => |fd| {
                // Separate units via collectFuncs; this instruction performs
                // runtime registration (conditional-declaration semantics).
                const k = try self.nameConst(fd.name, line);
                _ = try self.emitArg(.declare_func, k, line);
            },

            .ret => |maybe_e| {
                if (maybe_e) |e| {
                    try self.compileExpr(e);
                    _ = try self.emit(.return_val, line);
                } else {
                    _ = try self.emit(.return_null, line);
                }
            },

            .brk => |level| try self.jumpOut(level, false, line),
            .cont => |level| try self.jumpOut(level, true, line),
        }
    }

    // -- fused superinstructions -------------------------------------------------

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
        local: usize,
        constant: u32, // const pool index
    };

    /// Classify an operand for fusion: local slot or compile-time constant.
    fn fusedOperand(self: *Compiler, e: *ast.Expr) Error!?FusedOperand {
        switch (e.kind) {
            .var_ref => |name| {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                if (slot > 0x1FFF) return null;
                return .{ .local = slot };
            },
            else => {
                const cv = constEval(e) orelse return null;
                const idx = self.chunk.addConst(self.arena, cv) catch return error.OutOfMemory;
                return .{ .constant = idx };
            },
        }
    }

    /// Statement `$x <op>= y;` / `$x++;` with discarded result -> one fused
    /// instruction. Returns false when the pattern does not apply.
    fn tryEmitFusedAssignStmt(self: *Compiler, e: *ast.Expr) Error!bool {
        const line = e.line;
        if (e.kind == .inc_dec) {
            const d = e.kind.inc_dec;
            if (!d.postfix) return false;
            if (d.target.kind != .var_ref) return false;
            const slot = try self.ctx.resolveLocal(self.arena, d.target.kind.var_ref);
            const op: Op = if (d.up) .post_inc_local_discard else .post_dec_local_discard;
            _ = try self.emitArg(op, @intCast(slot), line);
            return true;
        }
        if (e.kind != .assign) return false;
        const a = e.kind.assign;
        if (a.target.kind != .var_ref) return false;
        const arith_kind: ArithFusion = switch (a.op) {
            .add => .add,
            .sub => .sub,
            else => return false,
        };
        const dst = try self.ctx.resolveLocal(self.arena, a.target.kind.var_ref);
        if (dst > 0xFFFF) return false;
        const src = try self.fusedOperand(a.value) orelse return false;
        switch (src) {
            .local => |src_slot| {
                if (src_slot > 0xFFFF) return false;
                const op: Op = switch (arith_kind) {
                    .add => .add_set_local_local,
                    .sub => .sub_set_local_local,
                };
                _ = try self.emitArg(op, @intCast(dst | (src_slot << 16)), line);
            },
            .constant => |ci| {
                if (ci > 0xFFFF) return false;
                const op: Op = switch (arith_kind) {
                    .add => .add_set_local_const,
                    .sub => .sub_set_local_const,
                };
                _ = try self.emitArg(op, @intCast(dst | (ci << 16)), line);
            },
        }
        return true;
    }

    const ArithFusion = enum { add, sub };

    /// Fuse `local CMP (local|const)` loop conditions into a single
    /// compare-and-branch instruction. Returns the inline-word position to
    /// patch with the loop-exit target, or null when the pattern does not
    /// apply (caller falls back to the generic path).
    fn tryEmitCondJump(self: *Compiler, cond: *ast.Expr, line: u32) Error!?usize {
        if (cond.kind != .binary) return null;
        const b = cond.kind.binary;
        var sel = cmpSelOf(b.op) orelse return null;

        var lhs = try self.fusedOperand(b.lhs);
        var rhs = try self.fusedOperand(b.rhs);
        // Mirror when the constant/local arrangement needs it:
        // (const CMP local) == (local flip(CMP) const)
        if (lhs != null and lhs.? == .local and rhs != null and rhs.? == .local) {
            // both locals: direct ll form below
        } else if (rhs != null and rhs.? == .local and (lhs == null or lhs.? == .constant)) {
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

        switch (lhs orelse return null) {
            .local => |slot| switch (rhs orelse return null) {
                .local => |slot2| {
                    const arg: u32 = @as(u32, @intFromEnum(sel)) << 26 |
                        (@as(u32, @intCast(slot2)) << 13) |
                        @as(u32, @intCast(slot));
                    _ = try self.emitArg(.cmp_jmp_local_local, arg, line);
                    const inline_pos = try self.emitInline(0, line); // target patched by caller
                    return inline_pos;
                },
                .constant => |ci| {
                    if (ci > 0xFFFFFF) return null;
                    const arg: u32 = (@as(u32, @intFromEnum(sel)) << 24) | @as(u32, @intCast(slot));
                    _ = try self.emitArg(.cmp_jmp_local_const, arg, line);
                    _ = try self.emitInline(ci, line);
                    const target_pos = try self.emitInline(0, line);
                    return target_pos;
                },
            },
            .constant => return null, // const CMP const — no point fusing
        }
    }

    fn bindForeachVar(self: *Compiler, name: []const u8, line: u32) Error!void {
        if (self.ctx.is_global_scope) {
            const k = try self.nameConst(name, line);
            _ = try self.emitArg(.set_global, k, line);
        } else {
            const slot = try self.ctx.resolveLocal(self.arena, name);
            _ = try self.emitArg(.set_local, @intCast(slot), line);
        }
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
            // `continue` in the innermost foreach jumps straight to its
            // iterator-advance instruction.
            _ = try self.emitArg(.jmp, @intCast(lc.next_addr), line);
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
            self.chunk.code.items[j].arg = @intCast(lc.continue_addr);
        }
        for (lc.break_jumps.items) |j| try self.patchJmp(j);
    }

    fn endLoopForeach(self: *Compiler, lc: *LoopCtx) Error!void {
        // continue jumps were redirected at emission time (innermost case);
        // outer-level continues/breaks patch like normal loops.
        _ = self.loops.pop();
        for (lc.continue_jumps.items) |j| {
            self.chunk.code.items[j].arg = @intCast(lc.next_addr);
        }
        for (lc.break_jumps.items) |j| try self.patchJmp(j);
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
            else => unreachable, // short-circuit forms handled in compileBinary
        };
    }

    fn compileBinary(self: *Compiler, b: anytype, line: u32) Error!void {
        switch (b.op) {
            .logic_and => {
                try self.compileExpr(b.lhs);
                const j = try self.emit(.jmp_if_false_keep, line);
                _ = try self.emit(.pop, line);
                try self.compileExpr(b.rhs);
                _ = try self.emit(.to_bool, line);
                try self.patchJmp(j);
            },
            .logic_or => {
                try self.compileExpr(b.lhs);
                const j = try self.emit(.jmp_if_true_keep, line);
                _ = try self.emit(.pop, line);
                try self.compileExpr(b.rhs);
                _ = try self.emit(.to_bool, line);
                try self.patchJmp(j);
            },
            .coalesce => {
                try self.compileExpr(b.lhs);
                try self.compileExpr(b.rhs);
                _ = try self.emit(.coalesce, line);
            },
            .logic_xor => {
                try self.compileExpr(b.lhs);
                try self.compileExpr(b.rhs);
                _ = try self.emit(.logic_xor, line);
            },
            else => {
                try self.compileExpr(b.lhs);
                try self.compileExpr(b.rhs);
                _ = try self.emit(binOpOf(b.op), line);
            },
        }
    }

    fn compileExpr(self: *Compiler, e: *ast.Expr) Error!void {
        const line = e.line;
        switch (e.kind) {
            .int_lit => |i| {
                const k = try self.chunk.addConst(self.arena, .{ .int_ = i });
                _ = try self.emitArg(.const_k, k, line);
            },
            .float_lit => |f| {
                const k = try self.chunk.addConst(self.arena, .{ .float_ = f });
                _ = try self.emitArg(.const_k, k, line);
            },
            .str_lit => |st| {
                const k = try self.chunk.addConst(self.arena, .{ .str_ = st });
                _ = try self.emitArg(.const_k, k, line);
            },
            .bool_lit => |b| _ = try self.emit(if (b) .true_ else .false_, line),
            .null_lit => _ = try self.emit(.null_, line),

            .var_ref => |name| try self.pushVar(name, line),

            .interp_str => |parts| {
                var n: usize = 0;
                for (parts) |part| {
                    switch (part) {
                        .literal => |lit| {
                            const k = try self.chunk.addConst(self.arena, .{ .str_ = lit });
                            _ = try self.emitArg(.const_k, k, line);
                        },
                        .var_ref => |name| try self.pushVar(name, line),
                        .var_index => |vi| {
                            try self.pushVar(vi.name, line);
                            for (vi.keys) |key| {
                                switch (key) {
                                    .str => |ks| {
                                        const k = try self.chunk.addConst(self.arena, .{ .str_ = ks });
                                        _ = try self.emitArg(.const_k, k, line);
                                    },
                                    .int => |iv| {
                                        const k = try self.chunk.addConst(self.arena, .{ .int_ = iv });
                                        _ = try self.emitArg(.const_k, k, line);
                                    },
                                }
                                _ = try self.emit(.get_index, line);
                            }
                        },
                    }
                    n += 1;
                }
                if (n == 0) {
                    const k = try self.chunk.addConst(self.arena, .{ .str_ = "" });
                    _ = try self.emitArg(.const_k, k, line);
                } else if (n > 1) {
                    _ = try self.emitArg(.strconcat, @intCast(n), line);
                }
            },

            .array_lit => |items| {
                // Build in source order so auto-key sequencing matches PHP:
                // [9, 'k' => 2] gives 0=>9 then 'k'=>2.
                _ = try self.emitArg(.new_array, 0, line);
                for (items) |item| {
                    _ = try self.emit(.dup, line); // keep the array under us
                    if (item.key) |ke| {
                        try self.compileExpr(ke);
                        try self.compileExpr(item.val);
                        _ = try self.emit(.set_index, line);
                    } else {
                        try self.compileExpr(item.val);
                        _ = try self.emit(.append_index, line);
                    }
                    // Both ops push the stored value for assignment
                    // expressions; inside a literal only the array remains.
                    _ = try self.emit(.pop, line);
                }
            },

            .unary => |u| {
                try self.compileExpr(u.operand);
                _ = try self.emit(switch (u.op) {
                    .neg => .neg,
                    .pos => .pos,
                    .not => .not,
                    .bit_not => .bit_not,
                }, line);
            },

            .binary => |b| try self.compileBinary(b, line),

            .ternary => |tn| {
                try self.compileExpr(tn.cond);
                if (tn.then) |then_e| {
                    const jf = try self.emit(.jmp_if_false, line);
                    try self.compileExpr(then_e);
                    const jend = try self.emit(.jmp, line);
                    try self.patchJmp(jf);
                    try self.compileExpr(tn.els);
                    try self.patchJmp(jend);
                } else {
                    // Shorthand `$a ?: b`: cond is also the then-value.
                    const jt = try self.emit(.jmp_if_true_raw, line); // truthy: keep cond
                    try self.compileExpr(tn.els);
                    try self.patchJmp(jt);
                }
            },

            .assign => |a| try self.compileAssign(a.target, a.op, a.value, line),
            .inc_dec => |d| try self.compileIncDec(d.target, d.up, d.postfix, line),

            .call => |c| {
                for (c.args) |arg| try self.compileExpr(arg);
                const k = try self.nameConst(c.name, line);
                _ = try self.emitArg(.call, opcode.packCall(k, @intCast(c.args.len)), line);
            },

            .index => |ix| {
                try self.compileExpr(ix.base);
                if (ix.index) |ie| {
                    try self.compileExpr(ie);
                    _ = try self.emit(.get_index, line);
                } else {
                    return self.fail(line, "cannot read from array without an index", .{});
                }
            },

            .isset => |exprs| {
                // isset(a, b, ...) === isset(a) && isset(b) && ...
                try self.compileIssetOne(exprs[0], line);
                for (exprs[1..]) |x| {
                    const j = try self.emit(.jmp_if_false_keep, line);
                    _ = try self.emit(.pop, line);
                    try self.compileIssetOne(x, line);
                    try self.patchJmp(j);
                }
            },

            .empty => |inner| {
                try self.compileExpr(inner);
                _ = try self.emit(.to_bool, line);
                _ = try self.emit(.not, line);
            },
        }
    }

    fn pushVar(self: *Compiler, name: []const u8, line: u32) Error!void {
        if (self.ctx.is_global_scope) {
            const k = try self.nameConst(name, line);
            _ = try self.emitArg(.get_global, k, line);
        } else {
            const slot = try self.ctx.resolveLocal(self.arena, name);
            _ = try self.emitArg(.get_local, @intCast(slot), line);
        }
    }

    fn storeVar(self: *Compiler, name: []const u8, line: u32) Error!void {
        if (self.ctx.is_global_scope) {
            const k = try self.nameConst(name, line);
            _ = try self.emitArg(.set_global, k, line);
        } else {
            const slot = try self.ctx.resolveLocal(self.arena, name);
            _ = try self.emitArg(.set_local, @intCast(slot), line);
        }
    }

    fn compileIssetOne(self: *Compiler, x: *ast.Expr, line: u32) Error!void {
        switch (x.kind) {
            .var_ref => |name| {
                if (self.ctx.is_global_scope) {
                    const k = try self.nameConst(name, line);
                    _ = try self.emitArg(.isset_global, k, line);
                } else {
                    const slot = try self.ctx.resolveLocal(self.arena, name);
                    _ = try self.emitArg(.isset_local, @intCast(slot), line);
                }
            },
            .index => |ix| {
                try self.compileReadPath(ix.base, line);
                if (ix.index) |ie| {
                    try self.compileExpr(ie);
                } else {
                    _ = try self.emit(.null_, line);
                }
                _ = try self.emit(.isset_index, line);
            },
            else => {
                try self.compileExpr(x);
                _ = try self.emit(.is_not_null, line);
            },
        }
    }

    fn compileAssign(self: *Compiler, target: *ast.Expr, op: ast.AssignOp, value: *ast.Expr, line: u32) Error!void {
        switch (target.kind) {
            .var_ref => |name| {
                if (op == .coalesce) {
                    // $x ??= v  ==>  x = (x ?? v)
                    try self.pushVar(name, line);
                    try self.compileExpr(value);
                    _ = try self.emit(.coalesce, line);
                    _ = try self.emit(.dup, line);
                    try self.storeVar(name, line);
                    return;
                }
                if (op != .assign) {
                    try self.pushVar(name, line);
                    try self.compileExpr(value);
                    _ = try self.emit(compoundOp(op), line);
                } else {
                    try self.compileExpr(value);
                }
                // Assignment is an expression: duplicate so the value
                // remains after the store consumes one copy.
                _ = try self.emit(.dup, line);
                try self.storeVar(name, line);
            },

            .index => |ix| {
                // Resolve parent container + key once: [parent key]
                try self.compileContainerPath(ix.base, line);
                if (ix.index) |ke| {
                    try self.compileExpr(ke);
                } else {
                    if (op != .assign) {
                        return self.fail(line, "[] operator supports only append assignment", .{});
                    }
                    try self.compileExpr(value);
                    _ = try self.emit(.append_index, line); // pops container+value, pushes value
                    return;
                }

                if (op == .assign) {
                    try self.compileExpr(value);
                } else {
                    // [P k] -> [P k P k] -> old -> combine with rhs
                    _ = try self.emit(.dup2, line);
                    _ = try self.emit(.get_index, line);
                    try self.compileExpr(value);
                    _ = try self.emit(compoundOp(op), line);
                }
                _ = try self.emit(.set_index, line); // pops [P k v], pushes v
            },

            else => return self.fail(line, "invalid assignment target", .{}),
        }
    }

    /// Leave ONE vivified array pointer on the stack: the array into which
    /// the caller's key will be written. Auto-vivifies every level
    /// (`$undefined['a']['b'] = 1` creates the intermediate arrays).
    fn compileContainerPath(self: *Compiler, base: *ast.Expr, line: u32) Error!void {
        switch (base.kind) {
            .var_ref => |name| {
                if (self.ctx.is_global_scope) {
                    const k = try self.nameConst(name, line);
                    _ = try self.emitArg(.get_container_global, k, line);
                } else {
                    const slot = try self.ctx.resolveLocal(self.arena, name);
                    _ = try self.emitArg(.get_container_local, @intCast(slot), line);
                }
            },
            .index => |ix| {
                try self.compileContainerPath(ix.base, line);
                if (ix.index) |k| {
                    try self.compileExpr(k);
                } else {
                    return self.fail(line, "invalid assignment target", .{});
                }
                _ = try self.emit(.subcontainer, line); // [parent key] -> [vivified sub-array]
            },
            else => return self.fail(line, "invalid assignment target", .{}),
        }
    }

    /// Leave [base key] on the stack WITHOUT vivifying anything (isset path):
    /// a missing variable or index reads as null and isset_index reports false.
    fn compileReadPath(self: *Compiler, base: *ast.Expr, line: u32) Error!void {
        switch (base.kind) {
            .var_ref => |name| try self.pushVar(name, line),
            .index => |ix| {
                try self.compileReadPath(ix.base, line);
                if (ix.index) |k| {
                    try self.compileExpr(k);
                } else {
                    _ = try self.emit(.null_, line);
                }
                _ = try self.emit(.get_index, line); // null-safe read
            },
            else => return self.fail(line, "invalid isset() operand", .{}),
        }
    }

    fn compileIncDec(self: *Compiler, target: *ast.Expr, up: bool, postfix: bool, line: u32) Error!void {
        switch (target.kind) {
        .var_ref => |name| {
            if (self.ctx.is_global_scope) {
                const k = try self.nameConst(name, line);
                const op: Op = switch (up) {
                    true => if (postfix) Op.post_inc_global else Op.pre_inc_global,
                    false => if (postfix) Op.post_dec_global else Op.pre_dec_global,
                };
                _ = try self.emitArg(op, k, line);
            } else {
                const slot = try self.ctx.resolveLocal(self.arena, name);
                const op: Op = switch (up) {
                    true => if (postfix) Op.post_inc_local else Op.pre_inc_local,
                    false => if (postfix) Op.post_dec_local else Op.pre_dec_local,
                };
                _ = try self.emitArg(op, @intCast(slot), line);
            }
        },
            .index => |ix| {
                try self.compileContainerPath(ix.base, line);
                if (ix.index) |ke| {
                    try self.compileExpr(ke);
                } else {
                    return self.fail(line, "cannot increment without an index", .{});
                }
                const op: Op = switch (up) {
                    true => if (postfix) Op.post_inc_index else Op.pre_inc_index,
                    false => if (postfix) Op.post_dec_index else Op.pre_dec_index,
                };
                _ = try self.emit(op, line);
            },
            else => return self.fail(line, "invalid increment/decrement target", .{}),
        }
    }
};

fn compoundOp(op: ast.AssignOp) Op {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .concat => .concat,
        .coalesce => .coalesce, // [old rhs] -> winner
        .assign => unreachable,
    };
}

/// Evaluate a compile-time constant expression (literal / unary minus).
/// Returns null when not constant.
fn constEval(e: *ast.Expr) ?Value {
    return switch (e.kind) {
        .int_lit => |i| Value{ .int_ = i },
        .float_lit => |f| Value{ .float_ = f },
        .str_lit => |st| Value{ .str_ = st },
        .bool_lit => |b| Value{ .bool_ = b },
        .null_lit => Value.null_,
        .unary => |u| switch (u.op) {
            .neg => switch (constEval(u.operand) orelse return null) {
                .int_ => |i| Value{ .int_ = -i },
                .float_ => |fl| Value{ .float_ = -fl },
                else => null,
            },
            .pos => constEval(u.operand),
            else => null,
        },
        else => null,
    };
}
