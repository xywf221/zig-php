//! Lexer / tokenizer for the zphp interpreter.
//!
//! Produces a flat, zero-copy token slice from PHP source text. The input
//! must contain an opening `<?php` tag; everything after a closing `?>` is
//! ignored (raw HTML passthrough is not supported in the minimal core).

const std = @import("std");
const tok = @import("token.zig");

pub const Token = tok.Token;
pub const Kind = tok.Kind;

pub const Error = error{
    MissingOpenTag,
    UnexpectedCharacter,
    UnterminatedString,
    UnterminatedComment,
} || std.mem.Allocator.Error;

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,

    pub fn init(src: []const u8) Lexer {
        var l = Lexer{ .src = src };
        // Skip a UTF-8 BOM if present.
        if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) l.pos = 3;
        return l;
    }

    fn eof(self: *const Lexer) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *const Lexer) ?u8 {
        return if (self.eof()) null else self.src[self.pos];
    }

    fn peekAt(self: *const Lexer, off: usize) ?u8 {
        return if (self.pos + off < self.src.len) self.src[self.pos + off] else null;
    }

    fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    fn startsWith(self: *const Lexer, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    /// Tokenize the whole source into a flat token slice ending with `.eof`.
    pub fn tokenize(self: *Lexer, gpa: std.mem.Allocator) Error![]Token {
        var list: std.ArrayList(Token) = .empty;
        errdefer list.deinit(gpa);

        // Require the opening tag (leading whitespace is tolerated).
        while (!self.eof() and isSpace(self.peek().?)) _ = self.advance();
        if (!self.startsWith("<?php")) return error.MissingOpenTag;
        self.pos += 5;

        while (true) {
            try self.skipTrivia();
            if (self.eof()) break;
            if (self.startsWith("?>")) break;
            const token = try self.scanToken();
            try list.append(gpa, token);
        }

        try list.append(gpa, .{ .kind = .eof, .text = "", .line = self.line });
        return list.toOwnedSlice(gpa);
    }

    fn skipTrivia(self: *Lexer) Error!void {
        while (!self.eof()) {
            const c = self.peek().?;
            if (isSpace(c)) {
                _ = self.advance();
                continue;
            }
            // Line comments: // and #
            if (c == '#' or (c == '/' and self.peekAt(1) == '/')) {
                while (!self.eof() and self.peek().? != '\n' and !self.startsWith("?>")) _ = self.advance();
                continue;
            }
            // Block comments: /* ... */
            if (c == '/' and self.peekAt(1) == '*') {
                _ = self.advance();
                _ = self.advance();
                while (true) {
                    if (self.eof()) return error.UnterminatedComment;
                    if (self.peek().? == '*' and self.peekAt(1) == '/') {
                        _ = self.advance();
                        _ = self.advance();
                        break;
                    }
                    _ = self.advance();
                }
                continue;
            }
            return;
        }
    }

    fn scanToken(self: *Lexer) Error!Token {
        const start = self.pos;
        const line = self.line;
        const c = self.advance();

        // Identifiers & keywords. Bytes >= 0x80 are allowed (PHP identifiers).
        if (isIdentStart(c)) {
            while (!self.eof() and isIdentChar(self.peek().?)) _ = self.advance();
            const text = self.src[start..self.pos];
            const kind = tok.keywords.get(text) orelse .ident;
            return .{ .kind = kind, .text = text, .line = line };
        }

        // Variables.
        if (c == '$') {
            if (self.eof() or !isIdentStart(self.peek().?))
                return error.UnexpectedCharacter;
            while (!self.eof() and isIdentChar(self.peek().?)) _ = self.advance();
            return .{ .kind = .variable, .text = self.src[start..self.pos], .line = line };
        }

        // Numbers: decimal int/float, hex int, leading-dot float (.5).
        if (std.ascii.isDigit(c) or (c == '.' and self.peek() != null and std.ascii.isDigit(self.peek().?))) {
            self.pos = start; // rescan uniformly
            return self.scanNumber(line);
        }

        // Strings.
        if (c == '\'' or c == '"')
            return self.scanString(c, line);

        // Operators, longest match first.
        return self.scanOperator(c, line);
    }

    fn scanNumber(self: *Lexer, line: u32) Error!Token {
        const start = self.pos;
        var is_float = false;

        // Octal (0 followed by octal digits).
        if (self.peekAt(0) == '0' and self.peekAt(1) != null and self.peekAt(1).? >= '0' and self.peekAt(1).? <= '7') {
            self.pos += 1;
            const digits_start = self.pos;
            while (!self.eof() and self.peek().? >= '0' and self.peek().? <= '7') _ = self.advance();
            if (!self.eof() and std.ascii.isDigit(self.peek().?)) return error.UnexpectedCharacter;
            return .{ .kind = .int, .text = self.src[digits_start - 1 .. self.pos], .line = line };
        }

        // Hexadecimal.
        if (self.peekAt(0) == '0' and (self.peekAt(1) == 'x' or self.peekAt(1) == 'X')) {
            self.pos += 2;
            if (self.eof() or !std.ascii.isHex(self.peek().?)) return error.UnexpectedCharacter;
            while (!self.eof() and std.ascii.isHex(self.peek().?)) _ = self.advance();
            return .{ .kind = .int, .text = self.src[start..self.pos], .line = line };
        }

        while (!self.eof()) {
            const c = self.peek().?;
            if (std.ascii.isDigit(c)) {
                _ = self.advance();
            } else if (c == '.' and !is_float) {
                is_float = true;
                _ = self.advance();
            } else if ((c == 'e' or c == 'E') and
                self.peekAt(1) != null and
                (std.ascii.isDigit(self.peekAt(1).?) or
                    ((self.peekAt(1).? == '+' or self.peekAt(1).? == '-') and
                        self.peekAt(2) != null and std.ascii.isDigit(self.peekAt(2).?))))
            {
                is_float = true;
                _ = self.advance(); // e
                _ = self.advance(); // sign
            } else break;
        }

        return .{
            .kind = if (is_float) .float else .int,
            .text = self.src[start..self.pos],
            .line = line,
        };
    }

    fn scanString(self: *Lexer, quote: u8, line: u32) Error!Token {
        // Position after the opening quote.
        const content_start = self.pos;
        while (true) {
            if (self.eof()) return error.UnterminatedString;
            const c = self.advance();
            if (c == '\\') {
                if (self.eof()) return error.UnterminatedString;
                _ = self.advance(); // skip escaped char
            } else if (c == quote) {
                return .{
                    .kind = .string,
                    .text = self.src[content_start .. self.pos - 1],
                    .line = line,
                    .single_quoted = quote == '\'',
                };
            } else if (c == '{' and self.peek() == '$') {
                // "{$arr["key"]}" — balance braces so embedded quotes do
                // not terminate the string (PHP lexer behavior).
                var depth: usize = 1;
                while (depth > 0) {
                    if (self.eof()) return error.UnterminatedString;
                    const d = self.advance();
                    if (d == '\\') {
                        if (self.eof()) return error.UnterminatedString;
                        _ = self.advance();
                    } else if (d == '{') {
                        depth += 1;
                    } else if (d == '}') {
                        depth -= 1;
                    }
                }
            }
        }
    }

    fn scanOperator(self: *Lexer, first: u8, line: u32) Error!Token {
        const src = self.src;
        const i = self.pos; // position after the first char

        // Three-char operators.
        if (i + 2 <= src.len) {
            const t3 = src[i - 1 .. i + 2];
            if (std.mem.eql(u8, t3, "===")) {
                self.pos += 2;
                return self.op(.identical, line);
            }
            if (std.mem.eql(u8, t3, "!==")) {
                self.pos += 2;
                return self.op(.not_identical, line);
            }
            if (std.mem.eql(u8, t3, "<=>")) {
                self.pos += 2;
                return self.op(.spaceship, line);
            }
            if (std.mem.eql(u8, t3, "**=")) {
                self.pos += 2;
                return self.op(.pow_eq, line);
            }
            if (std.mem.eql(u8, t3, "??=")) {
                self.pos += 2;
                return self.op(.coalesce_eq, line);
            }
        }

        // Two-char operators.
        if (i < src.len) {
            const pair = @as(u16, src[i - 1]) << 8 | src[i];
            const kind: ?Kind = switch (pair) {
                0x3D3D => .eq, // ==
                0x213D => .neq, // !=
                0x3C3E => .neq, // <>
                0x3C3D => .lte, // <=
                0x3E3D => .gte, // >=
                0x2626 => .logic_and, // &&
                0x7C7C => .logic_or, // ||
                0x2B2B => .incr, // ++
                0x2D2D => .decr, // --
                0x2B3D => .plus_eq, // +=
                0x2D3D => .minus_eq, // -=
                0x2A3D => .mul_eq, // *=
                0x2F3D => .div_eq, // /=
                0x253D => .mod_eq, // %=
                0x2E3D => .concat_eq, // .=
                0x2A2A => .pow, // **
                0x3D3E => .dbl_arrow, // =>
                0x3F3F => .coalesce, // ??
                0x3F3D => .coalesce_eq, // ??=
                0x3C3C => .shl, // <<
                0x3E3E => .shr, // >>
                0x2D3E => .object_op, // ->
                0x3A3A => .dbl_colon, // ::
                else => null,
            };
            if (kind) |k| {
                self.pos += 1;
                return self.op(k, line);
            }
        }

        // Single-char operators / punctuation.
        const kind: Kind = switch (first) {
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            ',' => .comma,
            ';' => .semicolon,
            ':' => .colon,
            '?' => .question,
            '=' => .assign,
            '<' => .lt,
            '>' => .gt,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '.' => .concat,
            '&' => .amp,
            '|' => .pipe,
            '^' => .caret,
            '~' => .tilde,
            '!' => .bang,
            else => return error.UnexpectedCharacter,
        };
        return self.op(kind, line);
    }

    fn op(self: *Lexer, kind: Kind, line: u32) Token {
        _ = self;
        return .{ .kind = kind, .text = "", .line = line };
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0b or c == 0x0c;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "tokenize basics" {
    var l = Lexer.init("<?php $a = 42 + 1.5;");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(Kind.variable, toks[0].kind);
    try t.expectEqualStrings("$a", toks[0].text);
    try t.expectEqual(Kind.assign, toks[1].kind);
    try t.expectEqual(Kind.int, toks[2].kind);
    try t.expectEqualStrings("42", toks[2].text);
    try t.expectEqual(Kind.plus, toks[3].kind);
    try t.expectEqual(Kind.float, toks[4].kind);
    try t.expectEqual(Kind.semicolon, toks[5].kind);
    try t.expectEqual(Kind.eof, toks[6].kind);
}

test "tokenize strings" {
    var l = Lexer.init("<?php 'hi\\'s' \"a\\\"b\"");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqualStrings("hi\\'s", toks[0].text);
    try t.expectEqualStrings("a\\\"b", toks[1].text);
}

test "keywords and hex" {
    var l = Lexer.init("<?php if elseif function 0xFF");
    const toks = try l.tokenize(t.allocator);
    defer t.allocator.free(toks);
    try t.expectEqual(Kind.kw_if, toks[0].kind);
    try t.expectEqual(Kind.kw_elseif, toks[1].kind);
    try t.expectEqual(Kind.kw_function, toks[2].kind);
    try t.expectEqual(Kind.int, toks[3].kind);
    try t.expectEqualStrings("0xFF", toks[3].text);
}

test "missing open tag" {
    var l = Lexer.init("echo 1;");
    try t.expectError(error.MissingOpenTag, l.tokenize(t.allocator));
}
