//! Parser unit tests: assert AST shapes (precedence & associativity).

const std = @import("std");
const t = std.testing;

const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

fn parseExpr(code: []const u8) !struct { arena: std.heap.ArenaAllocator, e: *ast.Expr } {
    const alloc = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    errdefer arena_state.deinit();
    const full = try std.fmt.allocPrint(arena_state.allocator(), "<?php {s};", .{code});
    var lx = lexer.Lexer.init(full);
    const toks = try lx.tokenize(arena_state.allocator());
    var diag: parser.Diag = .{};
    const prog = try parser.parse(arena_state.allocator(), toks, &diag);
    try t.expectEqual(@as(usize, 1), prog.len);
    try t.expect(prog[0].kind == .expr);
    return .{ .arena = arena_state, .e = prog[0].kind.expr };
}

test "multiplication binds tighter than addition" {
    const r = try parseExpr("1 + 2 * 3");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .binary);
    try t.expectEqual(ast.BinOp.add, r.e.kind.binary.op);
    try t.expect(r.e.kind.binary.lhs.kind == .int_lit);
    try t.expect(r.e.kind.binary.rhs.kind == .binary);
    try t.expectEqual(ast.BinOp.mul, r.e.kind.binary.rhs.kind.binary.op);
}

test "parentheses override precedence" {
    const r = try parseExpr("(1 + 2) * 3");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .binary);
    try t.expectEqual(ast.BinOp.mul, r.e.kind.binary.op);
    try t.expect(r.e.kind.binary.lhs.kind == .binary);
}

test "subtraction is left-associative" {
    const r = try parseExpr("100 - 50 - 20");
    defer r.arena.deinit();
    // ((100 - 50) - 20)
    try t.expectEqual(ast.BinOp.sub, r.e.kind.binary.op);
    try t.expect(r.e.kind.binary.lhs.kind == .binary);
}

test "pow is right-associative" {
    const r = try parseExpr("2 ** 3 ** 2");
    defer r.arena.deinit();
    // 2 ** (3 ** 2): rhs is the nested pow.
    try t.expectEqual(ast.BinOp.pow, r.e.kind.binary.op);
    try t.expect(r.e.kind.binary.rhs.kind == .binary);
    try t.expectEqual(ast.BinOp.pow, r.e.kind.binary.rhs.kind.binary.op);
}

test "unary minus binds looser than pow (-2**2 == -4)" {
    const r = try parseExpr("-2 ** 2");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .unary);
    try t.expectEqual(ast.UnOp.neg, r.e.kind.unary.op);
    try t.expect(r.e.kind.unary.operand.kind == .binary);
    try t.expectEqual(ast.BinOp.pow, r.e.kind.unary.operand.kind.binary.op);
}

test "concat shares additive level with +" {
    const r = try parseExpr("'a' . 'b' + 'c'");
    defer r.arena.deinit();
    // (('a'.'b')+'c') — left associative same level
    try t.expect(r.e.kind == .binary);
    try t.expectEqual(ast.BinOp.add, r.e.kind.binary.op);
    try t.expectEqual(ast.BinOp.concat, r.e.kind.binary.lhs.kind.binary.op);
}

test "equality lower than relational" {
    const r = try parseExpr("1 < 2 == true");
    defer r.arena.deinit();
    try t.expectEqual(ast.BinOp.eq, r.e.kind.binary.op);
    try t.expectEqual(ast.BinOp.lt, r.e.kind.binary.lhs.kind.binary.op);
}

test "shift between additive and relational" {
    const r = try parseExpr("1 + 2 << 3 < 10");
    defer r.arena.deinit();
    // ((1+2)<<3) < 10
    try t.expectEqual(ast.BinOp.lt, r.e.kind.binary.op);
    const shift = r.e.kind.binary.lhs;
    try t.expectEqual(ast.BinOp.shl, shift.kind.binary.op);
    try t.expectEqual(ast.BinOp.add, shift.kind.binary.lhs.kind.binary.op);
}

test "bitwise below equality but above logical-and" {
    const r = try parseExpr("1 & 2 && 3");
    defer r.arena.deinit();
    // (1&2) && 3
    try t.expectEqual(ast.BinOp.logic_and, r.e.kind.binary.op);
    try t.expectEqual(ast.BinOp.bit_and, r.e.kind.binary.lhs.kind.binary.op);
}

test "coalesce below or (PHP precedence)" {
    const r = try parseExpr("$a ?? $b || $c");
    defer r.arena.deinit();
    // PHP: ?? is LOWER than ||, so this parses as $a ?? ($b || $c)
    try t.expectEqual(ast.BinOp.coalesce, r.e.kind.binary.op);
    try t.expectEqual(ast.BinOp.logic_or, r.e.kind.binary.rhs.kind.binary.op);
}

test "ternary shape and shorthand" {
    {
        const r = try parseExpr("$a ? 1 : 2");
        defer r.arena.deinit();
        try t.expect(r.e.kind == .ternary);
        try t.expect(r.e.kind.ternary.then != null);
    }
    {
        const r = try parseExpr("$a ?: 2");
        defer r.arena.deinit();
        try t.expect(r.e.kind == .ternary);
        try t.expect(r.e.kind.ternary.then == null); // shorthand
    }
}

test "assignment is right-associative with lvalue check" {
    const r = try parseExpr("$a = $b = 1");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .assign);
    const inner = r.e.kind.assign.value;
    try t.expect(inner.kind == .assign);
}

test "compound assignment ops map correctly" {
    inline for (.{
        .{ "+=", ast.AssignOp.add },
        .{ "-=", ast.AssignOp.sub },
        .{ "*=", ast.AssignOp.mul },
        .{ "/=", ast.AssignOp.div },
        .{ "%=", ast.AssignOp.mod },
        .{ ".=", ast.AssignOp.concat },
        .{ "**=", ast.AssignOp.pow },
        .{ "??=", ast.AssignOp.coalesce },
    }) |case| {
        const r = try parseExpr("$x " ++ case[0] ++ " 1");
        defer r.arena.deinit();
        try t.expectEqual(case[1], r.e.kind.assign.op);
    }
}

test "inc/dec prefix vs postfix" {
    {
        const r = try parseExpr("++$x");
        defer r.arena.deinit();
        try t.expect(r.e.kind == .inc_dec);
        try t.expect(!r.e.kind.inc_dec.postfix);
        try t.expect(r.e.kind.inc_dec.up);
    }
    {
        const r = try parseExpr("$x--");
        defer r.arena.deinit();
        try t.expect(r.e.kind == .inc_dec);
        try t.expect(r.e.kind.inc_dec.postfix);
        try t.expect(!r.e.kind.inc_dec.up);
    }
}

test "index and append lvalues" {
    {
        const r = try parseExpr("$a[0] = 5");
        defer r.arena.deinit();
        try t.expect(r.e.kind == .assign);
        const target = r.e.kind.assign.target;
        try t.expect(target.kind == .index);
        try t.expect(target.kind.index.index != null);
    }
    {
        const r = try parseExpr("$a[] = 5");
        defer r.arena.deinit();
        const target = r.e.kind.assign.target;
        try t.expect(target.kind == .index);
        try t.expect(target.kind.index.index == null); // append marker
    }
}

test "array literal with keys and trailing comma" {
    const r = try parseExpr("[1, 'k' => 2, 3 => 4,]");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .array_lit);
    try t.expectEqual(@as(usize, 3), r.e.kind.array_lit.len);
    try t.expect(r.e.kind.array_lit[0].key == null);
    try t.expect(r.e.kind.array_lit[1].key != null);
    try t.expect(r.e.kind.array_lit[2].key != null);
}

test "call expression args" {
    const r = try parseExpr("foo(1, 2 + 3)");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .call);
    try t.expectEqualStrings("foo", r.e.kind.call.name);
    try t.expectEqual(@as(usize, 2), r.e.kind.call.args.len);
}

test "interpolation parts" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "<?php \"Hello $name, v={$v[0]}!\";";
    var l = lexer.Lexer.init(src);
    const toks = try l.tokenize(a);
    var diag: parser.Diag = .{};
    const prog = try parser.parse(a, toks, &diag);
    try t.expect(prog[0].kind == .expr);
    const e = prog[0].kind.expr;
    try t.expect(e.kind == .interp_str);
    const parts = e.kind.interp_str;
    try t.expectEqual(@as(usize, 5), parts.len);
    try t.expect(parts[0] == .literal);
    try t.expectEqualStrings("Hello ", parts[0].literal);
    try t.expect(parts[1] == .var_ref);
    try t.expectEqualStrings("name", parts[1].var_ref);
    try t.expect(parts[2] == .literal);
    try t.expectEqualStrings(", v=", parts[2].literal);
    try t.expect(parts[3] == .var_index);
    try t.expectEqualStrings("v", parts[3].var_index.name);
    try t.expectEqual(@as(i64, 0), parts[3].var_index.key_int);
    try t.expect(parts[4] == .literal);
    try t.expectEqualStrings("!", parts[4].literal);
}

test "escape processing in double quotes" {
    const r = try parseExpr("\"a\\tb\\nc\\\\d\\$e\"");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .str_lit);
    try t.expectEqualStrings("a\tb\nc\\d$e", r.e.kind.str_lit);
}

test "single-quote escapes only handle slash-quote" {
    const r = try parseExpr("'a\\n\\'b'");
    defer r.arena.deinit();
    try t.expect(r.e.kind == .str_lit);
    try t.expectEqualStrings("a\\n'b", r.e.kind.str_lit); // \n stays literal
}

test "function declaration shape" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "<?php function f($a, $b = 1) { return $a; }";
    var l = lexer.Lexer.init(src);
    const toks = try l.tokenize(a);
    var diag: parser.Diag = .{};
    const prog = try parser.parse(a, toks, &diag);
    try t.expect(prog[0].kind == .func_decl);
    const fd = prog[0].kind.func_decl;
    try t.expectEqualStrings("f", fd.name);
    try t.expectEqual(@as(usize, 2), fd.params.len);
    try t.expect(fd.params[0].default == null);
    try t.expect(fd.params[1].default != null);
}

test "if / elseif / else chain shape" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = "<?php if ($a) {} elseif ($b) {} else {}";
    var l = lexer.Lexer.init(src);
    const toks = try l.tokenize(a);
    var diag: parser.Diag = .{};
    const prog = try parser.parse(a, toks, &diag);
    try t.expect(prog[0].kind == .if_stmt);
    try t.expectEqual(@as(usize, 2), prog[0].kind.if_stmt.branches.len);
    try t.expect(prog[0].kind.if_stmt.else_body != null);
}

test "parse errors report line numbers" {
    const alloc = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const src = "<?php\n$a = 1;\n$b = ;\n";
    var l = lexer.Lexer.init(src);
    const toks = try l.tokenize(arena_state.allocator());
    var diag: parser.Diag = .{};
    try t.expectError(error.SyntaxError, parser.parse(arena_state.allocator(), toks, &diag));
    try t.expectEqual(@as(u32, 3), diag.line);
}

test "legacy array() rejected (PHP 8 target)" {
    const alloc = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const src = "<?php $a = array(1, 2);";
    var l = lexer.Lexer.init(src);
    const toks = try l.tokenize(arena_state.allocator());
    var diag: parser.Diag = .{};
    try t.expectError(error.SyntaxError, parser.parse(arena_state.allocator(), toks, &diag));
}

test "undefined constant rejected (PHP 8 semantics)" {
    if (parseExpr("MY_CONST")) |_| {
        return error.TestUnexpectedResult; // must not parse successfully
    } else |_| {
        // SyntaxError (or OOM) expected.
    }
}
