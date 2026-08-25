//! Token definitions for the zphp lexer.
//!
//! Tokens are zero-copy: `text` always points into the original source
//! buffer, so no allocation happens during lexing.

const std = @import("std");

pub const Kind = enum {
    // Literals
    int,
    float,
    string, // raw contents between the quotes (escapes unprocessed)
    ident,
    variable, // $name (text includes the '$')

    // Keywords
    kw_if,
    kw_elseif,
    kw_else,
    kw_while,
    kw_do,
    kw_for,
    kw_foreach,
    kw_as,
    kw_function,
    kw_return,
    kw_break,
    kw_continue,
    kw_echo,
    kw_print,
    kw_true,
    kw_false,
    kw_null,
    kw_and,
    kw_or,
    kw_xor,
    kw_array,
    kw_isset,
    kw_empty,

    // Punctuation
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    lbrace, // {
    rbrace, // }
    comma, // ,
    semicolon, // ;
    colon, // :
    question, // ?
    dbl_arrow, // =>
    dbl_colon, // ::  (lexed, rejected by parser)
    object_op, // ->  (lexed, rejected by parser)

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    concat, // .
    pow, // **
    assign, // =
    eq, // ==
    neq, // != or <>
    identical, // ===
    not_identical, // !==
    spaceship, // <=>
    lt,
    gt,
    lte,
    gte,
    logic_and, // &&
    logic_or, // ||
    bang, // !
    incr, // ++
    decr, // --
    plus_eq,
    minus_eq,
    mul_eq,
    div_eq,
    mod_eq,
    concat_eq, // .=
    pow_eq, // **=
    coalesce, // ??
    coalesce_eq, // ??=
    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    shl, // <<
    shr, // >>

    eof,
};

pub const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "if", .kw_if },
    .{ "elseif", .kw_elseif },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "do", .kw_do },
    .{ "for", .kw_for },
    .{ "foreach", .kw_foreach },
    .{ "as", .kw_as },
    .{ "function", .kw_function },
    .{ "return", .kw_return },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "echo", .kw_echo },
    .{ "print", .kw_print },
    .{ "true", .kw_true },
    .{ "True", .kw_true },
    .{ "TRUE", .kw_true },
    .{ "false", .kw_false },
    .{ "False", .kw_false },
    .{ "FALSE", .kw_false },
    .{ "null", .kw_null },
    .{ "NULL", .kw_null },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "xor", .kw_xor },
    .{ "array", .kw_array },
    .{ "isset", .kw_isset },
    .{ "empty", .kw_empty },
});

pub const Token = struct {
    kind: Kind,
    /// Slice into the original source text.
    text: []const u8,
    line: u32,
    /// For `.string` tokens: true when quoted with `'` (escapes limited to
    /// \' and \\); false when quoted with `"` (full escape set + interpolation).
    single_quoted: bool = false,
};
