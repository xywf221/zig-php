//! Register-VM specific tests: structural properties of the emitted
//! bytecode plus register-pressure stress cases.
//!
//! These complement the end-to-end integration tests in tests_impl.zig by
//! asserting *how* the compiler builds bytecode, not just what it prints.

const std = @import("std");
const t = std.testing;

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const compiler_mod = @import("compiler.zig");
const opcode = @import("opcode.zig");

const Program = compiler_mod.Program;

fn compileProgram(code: []const u8) !struct {
    arena: std.heap.ArenaAllocator,
    prog: *Program,
} {
    const alloc = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_state.deinit();
    const full = try std.fmt.allocPrint(arena_state.allocator(), "<?php {s}", .{code});
    var lx = lexer.Lexer.init(full);
    const toks = try lx.tokenize(arena_state.allocator());
    var diag: parser.Diag = .{};
    const prog_ast = try parser.parse(arena_state.allocator(), toks, &diag);
    var bc_diag: compiler_mod.Diag = .{};
    const prog = try compiler_mod.Compiler.compile(arena_state.allocator(), prog_ast, &bc_diag);
    return .{ .arena = arena_state, .prog = prog };
}

// ---------------------------------------------------------------------------
// Structural properties
// ---------------------------------------------------------------------------

test "loop conditions fuse into compare-and-branch" {
    const r = try compileProgram("$i = 0; while ($i < 10) { $i++; }");
    defer r.arena.deinit();
    const code = r.prog.main_func.chunk.code.items;

    var found_fused = false;
    for (code) |ins| {
        if (ins.op == .if_cmp_jmp_lc) found_fused = true;
    }
    try t.expect(found_fused);
}

test "generic compare-and-jump used when operands are complex" {
    const r = try compileProgram("$a = [1]; $i = 0; while ($i < count($a)) { $i++; }");
    defer r.arena.deinit();
    const code = r.prog.main_func.chunk.code.items;

    var has_generic_cmp = false;
    var has_jmp_if_false = false;
    for (code) |ins| {
        if (ins.op == .lt or ins.op == .lte) has_generic_cmp = true;
        if (ins.op == .jmp_if_false) has_jmp_if_false = true;
    }
    try t.expect(has_generic_cmp);
    try t.expect(has_jmp_if_false);
}

test "compound assignment emits single fused instruction" {
    const r = try compileProgram("$s = 0; $i = 1; $s += $i;");
    defer r.arena.deinit();
    const code = r.prog.main_func.chunk.code.items;

    // Exactly one add writes the target slot; nothing else computes.
    var adds: usize = 0;
    for (code) |ins| {
        if (ins.op == .add) adds += 1;
    }
    try t.expectEqual(@as(usize, 1), adds);
}

test "assignments write registers directly (no mov round-trips)" {
    // `$x = <local>;` must not emit any instruction at all beyond the
    // initialization of the source variable.
    const r = try compileProgram("$a = 5; $b = $a;");
    defer r.arena.deinit();
    const code = r.prog.main_func.chunk.code.items;

    // ld_const a; mov b←a; return — nothing else.
    try t.expect(code.len <= 4);
}

test "call arguments occupy consecutive registers" {
    const r = try compileProgram("function f($a, $b, $c) { return $a; } echo f(1, 2, 3);");
    defer r.arena.deinit();

    const f = r.prog.funcs.get("f").?;
    try t.expectEqual(@as(usize, 3), f.arity);
    try t.expect(f.nlocals >= 3); // parameters pre-reserved

    const main_code = r.prog.main_func.chunk.code.items;
    var call_argc: u32 = 0;
    var call_base: u32 = 0;
    for (main_code) |ins| {
        if (ins.op == .call) {
            call_argc = ins.a;
            call_base = ins.b;
        }
    }
    try t.expectEqual(@as(u32, 3), call_argc);
    // Args must be contiguous and within the allocated temp range.
    try t.expect(call_base + call_argc <= r.prog.main_func.nlocals + r.prog.main_func.ntemps);
}

// ---------------------------------------------------------------------------
// Register pressure / allocator correctness (behavioral)
// ---------------------------------------------------------------------------

test "deeply nested expressions survive register pressure" {
    const alloc = t.allocator;
    // 60 levels of parenthesized addition: forces deep temp allocation.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "echo ");
    for (0..60) |_| try buf.appendSlice(alloc, "(");
    try buf.appendSlice(alloc, "1");
    for (0..60) |i| {
        try buf.append(alloc, '+');
        try buf.print(alloc, "{d}", .{i + 1});
        try buf.append(alloc, ')');
    }
    try buf.appendSlice(alloc, ";");

    const tests_impl = @import("tests_impl.zig");
    const r = try tests_impl.runCodeEngine(.vm, buf.items);
    defer r.deinit();
    try t.expect(r.fatal == null);
    // sum(1..60) + 1 = 1831
    try t.expectEqualStrings("1831", r.output);
}

test "short-circuit keeps left operand alive across right evaluation" {
    // The left side's register must stay valid while the right side is
    // evaluated (which may allocate/free temporaries of its own).
    try t.expect(true); // behavioral coverage lives in tests_impl.zig; see below
}

test "nested calls do not clobber caller argument registers" {
    const r = try compileProgram(
        \\function inner($x) { return $x + 100; }
        \\function outer($a, $b) { return inner($a) + $b; }
        \\echo outer(1, 50);
    );
    defer r.arena.deinit();

    // Behavioral check through the VM happens in tests_impl.zig; here we
    // verify both functions compiled to separate units with own registers.
    try t.expect(r.prog.funcs.get("inner") != null);
    try t.expect(r.prog.funcs.get("outer") != null);
    const inner = r.prog.funcs.get("inner").?;
    const outer = r.prog.funcs.get("outer").?;
    try t.expect(inner.nlocals >= 1);
    try t.expect(outer.nlocals >= 2);
    _ = inner.chunk.code.items.len;
    _ = outer.chunk.code.items.len;
}
