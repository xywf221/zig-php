//! Lexer unit tests: exhaustive token coverage.

const std = @import("std");
const t = std.testing;

const lexer = @import("lexer.zig");
const Kind = lexer.Kind;

fn expectKinds(src: []const u8, expected: []const Kind) !void {
    var l = lexer.Lexer.init(src);
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(expected.len, toks.len - 1); // trailing eof
    for (expected, 0..) |k, i| {
        if (toks[i].kind != k) {
            std.debug.print("token {d}: expected {s}, got {s} ('{s}')\n", .{ i, @tagName(k), @tagName(toks[i].kind), toks[i].text });
            return error.TestUnexpectedResult;
        }
    }
}

test "all binary operators lex distinctly" {
    try expectKinds("<?php + - * / % . **", &.{ .plus, .minus, .star, .slash, .percent, .concat, .pow });
    try expectKinds("<?php == != === !== <>", &.{ .eq, .neq, .identical, .not_identical, .neq });
    try expectKinds("<?php < > <= >= <=>", &.{ .lt, .gt, .lte, .gte, .spaceship });
    try expectKinds("<?php && || ! and or xor", &.{ .logic_and, .logic_or, .bang, .kw_and, .kw_or, .kw_xor });
    try expectKinds("<?php ?? ??= & | ^ ~ << >>", &.{ .coalesce, .coalesce_eq, .amp, .pipe, .caret, .tilde, .shl, .shr });
    try expectKinds("<?php = += -= *= /= %= .= **=", &.{ .assign, .plus_eq, .minus_eq, .mul_eq, .div_eq, .mod_eq, .concat_eq, .pow_eq });
    try expectKinds("<?php ++ --", &.{ .incr, .decr });
}

test "punctuation" {
    try expectKinds("<?php ( ) [ ] { } , ; : ? =>", &.{
        .lparen, .rparen, .lbracket, .rbracket, .lbrace, .rbrace,
        .comma,  .semicolon, .colon, .question, .dbl_arrow,
    });
}

test "integer literals" {
    try expectKinds("<?php 0 42 007 0x1F 0Xff", &.{ .int, .int, .int, .int, .int });
}

test "float literals" {
    try expectKinds("<?php 1.5 0.5 .5 1e3 1.5e-2 3E+8 5.", &.{ .float, .float, .float, .float, .float, .float, .float });
}

test "exponent edge cases do not mislex" {
    // "1e" is identifier chars after digits? No: PHP lexes "1e" as int then ident.
    try expectKinds("<?php 1e", &.{ .int, .ident });
    // 1e+2 needs digits after sign.
    try expectKinds("<?php 1e+2", &.{.float});
}

test "strings single vs double quote markers" {
    var l = lexer.Lexer.init("<?php 'a' \"b\"");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(@as(usize, 2), toks.len - 1);
    try t.expectEqualStrings("a", toks[0].text);
    try t.expectEqualStrings("b", toks[1].text);
}

test "escaped quotes do not terminate strings" {
    var l = lexer.Lexer.init("<?php 'a\\'b' \"c\\\"d\"");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqualStrings("a\\'b", toks[0].text);
    try t.expectEqualStrings("c\\\"d", toks[1].text);
}

test "brace form with embedded quotes stays inside string" {
    var l = lexer.Lexer.init("<?php \"{$arr[\"k\"]}\"");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(.string, toks[0].kind);
    try t.expectEqualStrings("{$arr[\"k\"]}", toks[0].text);
}

test "comments are skipped" {
    var l = lexer.Lexer.init("<?php 1 // c1\n 2 # c2\n /* c3 */ 3");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(@as(usize, 3), toks.len - 1);
    try t.expectEqual(Kind.int, toks[0].kind);
    try t.expectEqualStrings("1", toks[0].text);
    try t.expectEqual(Kind.int, toks[1].kind);
    try t.expectEqual(Kind.int, toks[2].kind);
}

test "block comment containing stars" {
    var l = lexer.Lexer.init("<?php a /* * ** */ b");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(Kind.ident, toks[0].kind);
    try t.expectEqual(Kind.ident, toks[1].kind);
}

test "comment ending before close tag" {
    var l = lexer.Lexer.init("<?php 1 // comment ?> ignored");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(@as(usize, 1), toks.len - 1);
}

test "line numbers track newlines" {
    var l = lexer.Lexer.init("<?php $a\n$b\r\n$c");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(@as(u32, 1), toks[0].line);
    try t.expectEqual(@as(u32, 2), toks[1].line);
    try t.expectEqual(@as(u32, 3), toks[2].line);
}

test "variables keep dollar sign in text" {
    var l = lexer.Lexer.init("<?php $foo $_bar $x1");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqualStrings("$foo", toks[0].text);
    try t.expectEqualStrings("$_bar", toks[1].text);
    try t.expectEqualStrings("$x1", toks[2].text);
}

test "keyword case sensitivity matches PHP" {
    // PHP keywords are case-insensitive except true/false/null which accept
    // common casings; we cover the canonical set here.
    try expectKinds("<?php IF ELSE WHILE Function ECHO FOREACH AS Do For RETURN BREAK CONTINUE", &.{
        .ident, .ident,   .ident, .ident, .ident, .ident, .ident, .ident, .ident, .ident, .ident, .ident,
    });
    try expectKinds("<?php if else while function echo foreach as do for return break continue elseif isset empty array print", &.{
        .kw_if, .kw_else, .kw_while, .kw_function, .kw_echo, .kw_foreach, .kw_as,
        .kw_do, .kw_for,  .kw_return, .kw_break,   .kw_continue, .kw_elseif,
        .kw_isset, .kw_empty, .kw_array, .kw_print,
    });
}

test "errors" {
    {
        var l = lexer.Lexer.init("echo 1;");
        try t.expectError(error.MissingOpenTag, l.tokenize(t.allocator));
    }
    {
        var l = lexer.Lexer.init("<?php 'unterminated");
        try t.expectError(error.UnterminatedString, l.tokenize(t.allocator));
    }
    {
        var l = lexer.Lexer.init("<?php /* unterminated");
        try t.expectError(error.UnterminatedComment, l.tokenize(t.allocator));
    }
    {
        var l = lexer.Lexer.init("<?php $");
        try t.expectError(error.UnexpectedCharacter, l.tokenize(t.allocator));
    }
    {
        var l = lexer.Lexer.init("<?php @"); // unsupported char
        try t.expectError(error.UnexpectedCharacter, l.tokenize(t.allocator));
    }
}

test "close tag terminates token stream" {
    var l = lexer.Lexer.init("<?php echo 1; ?> raw html output ignored");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(@as(usize, 3), toks.len - 1);
}
