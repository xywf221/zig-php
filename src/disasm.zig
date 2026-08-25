//! Dev tool: disassemble the bytecode for a PHP snippet.
//!
//! Usage: zig run src/disasm.zig -- '<?php ...code...'

const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const compiler_mod = @import("compiler.zig");

pub fn main(init: std.process.Init) !void {
    var out_buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &fw.interface;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();
    const code = it.next() orelse return;
    const arena = init.arena.allocator();
    var lx = lexer.Lexer.init(code);
    const toks = try lx.tokenize(arena);
    var diag: parser.Diag = .{};
    const prog_ast = try parser.parse(arena, toks, &diag);
    var bc_diag: compiler_mod.Diag = .{};
    const prog = try compiler_mod.Compiler.compile(arena, prog_ast, &bc_diag);

    try dumpFn(out, "<main>", prog.main_func);
    var fit = prog.funcs.iterator();
    while (fit.next()) |e| {
        try out.print("\n", .{});
        try dumpFn(out, e.key_ptr.*, e.value_ptr.*);
    }
    try out.flush();
}

fn dumpFn(out: *std.Io.Writer, name: []const u8, f: anytype) !void {
    try out.print("; ---- {s} (arity={d}, nlocals={d}, ntemps={d}) ----\n", .{ name, f.arity, f.nlocals, f.ntemps });
    for (f.chunk.code.items, 0..) |ins, i| {
        try out.print("{d: >4} {s} a={d} b={d} c={d}\n", .{ i, @tagName(ins.op), ins.a, ins.b, ins.c });
    }
    for (f.chunk.consts.items, 0..) |c, i| {
        switch (c) {
            .str_ => |st| try out.print("const[{d}] = \"{s}\"\n", .{ i, st.data }),
            else => try out.print("const[{d}] = {any}\n", .{ i, c }),
        }
    }
}
