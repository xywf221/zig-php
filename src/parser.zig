//! Recursive-descent parser for the zphp interpreter.
//!
//! Consumes the flat token slice produced by the lexer and builds an
//! arena-allocated AST. Operator precedence follows PHP:
//!
//!   assignment  <  ternary ?:  <  ??  <  or  <  xor  <  and  <
//!   == != === !==  <  relational  <  + - .  <  * / %  <  **  <  unary
//!
//! `**` is right-associative and binds tighter than prefix unary operators,
//! so `-2 ** 2 === -4` like in real PHP.

const std = @import("std");
const tok = @import("token.zig");
const ast = @import("ast.zig");
const valmod = @import("value.zig");

const Token = tok.Token;
const Kind = tok.Kind;

pub const Error = error{ SyntaxError, OutOfMemory };

/// Parse a token slice into an arena-allocated program (list of statements).
pub fn parse(arena: std.mem.Allocator, toks: []const Token, diag: *Diag) Error![]const *ast.Stmt {
    var p = Parser{ .arena = arena, .toks = toks, .diag = diag };
    return p.parseProgram();
}

pub const Diag = struct {
    msg: []const u8 = "",
    line: u32 = 0,
};

pub const Parser = struct {
    arena: std.mem.Allocator,
    toks: []const Token,
    i: usize = 0,
    diag: *Diag,

    // -- helpers ------------------------------------------------------------

    fn cur(self: *Parser) Token {
        return self.toks[self.i];
    }

    fn advance(self: *Parser) Token {
        const t = self.toks[self.i];
        if (t.kind != .eof) self.i += 1;
        return t;
    }

    fn check(self: *Parser, kind: Kind) bool {
        return self.cur().kind == kind;
    }

    fn accept(self: *Parser, kind: Kind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: Kind) Error!Token {
        if (!self.check(kind)) {
            return self.fail("syntax error, unexpected '{s}', expected {s}", .{ self.cur().text, describe(kind) });
        }
        return self.advance();
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        if (self.diag.msg.len == 0) {
            self.diag.msg = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
            self.diag.line = self.cur().line;
        }
        return error.SyntaxError;
    }

    fn expr(self: *Parser, kind: ast.Expr.Kind, line: u32) Error!*ast.Expr {
        const node = try self.arena.create(ast.Expr);
        node.* = .{ .line = line, .kind = kind };
        return node;
    }

    fn stmt(self: *Parser, kind: ast.Stmt.Kind, line: u32) Error!*ast.Stmt {
        const node = try self.arena.create(ast.Stmt);
        node.* = .{ .line = line, .kind = kind };
        return node;
    }

    // -- program & statements ------------------------------------------------

    fn parseProgram(self: *Parser) Error![]const *ast.Stmt {
        var list: std.ArrayList(*ast.Stmt) = .empty;
        while (!self.check(.eof)) {
            try list.append(self.arena, try self.parseStatement());
        }
        return list.toOwnedSlice(self.arena);
    }

    /// A statement body: either a braced block or a single statement.
    fn parseBody(self: *Parser) Error!*ast.Stmt {
        if (self.accept(.lbrace)) {
            var list: std.ArrayList(*ast.Stmt) = .empty;
            while (!self.accept(.rbrace)) {
                if (self.check(.eof)) return self.fail("unexpected end of file, expected '}}'", .{});
                try list.append(self.arena, try self.parseStatement());
            }
            return self.stmt(.{ .block = try list.toOwnedSlice(self.arena) }, self.toks[self.i].line);
        }
        return self.parseStatement();
    }

    fn parseParenBody(self: *Parser) Error!*ast.Stmt {
        // Bodies after control structures may be `{ ... }` (handled by
        // parseBody); we just delegate.
        return self.parseBody();
    }

    fn parseStatement(self: *Parser) Error!*ast.Stmt {
        const t = self.cur();
        switch (t.kind) {
            .semicolon => {
                _ = self.advance();
                return self.stmt(.nop, t.line);
            },
            .lbrace => return self.parseBody(),
            .kw_echo => return self.parseEcho(),
            .kw_if => return self.parseIf(),
            .kw_while => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const cond = try self.parseExpr();
                _ = try self.expect(.rparen);
                const body = try self.parseParenBody();
                return self.stmt(.{ .while_stmt = .{ .cond = cond, .body = body } }, t.line);
            },
            .kw_do => {
                _ = self.advance();
                const body = try self.parseParenBody();
                if (!self.accept(.kw_while)) return self.fail("expected 'while' after do-block", .{});
                _ = try self.expect(.lparen);
                const cond = try self.parseExpr();
                _ = try self.expect(.rparen);
                _ = try self.expect(.semicolon);
                return self.stmt(.{ .do_while = .{ .cond = cond, .body = body } }, t.line);
            },
            .kw_for => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const init_exprs = try self.parseExprList(.semicolon);
                _ = try self.expect(.semicolon);
                const cond: ?*ast.Expr = if (self.check(.semicolon)) null else try self.parseExpr();
                _ = try self.expect(.semicolon);
                const step = try self.parseExprList(.rparen);
                _ = try self.expect(.rparen);
                const body = try self.parseParenBody();
                return self.stmt(.{ .for_stmt = .{
                    .init = init_exprs,
                    .cond = cond,
                    .step = step,
                    .body = body,
                } }, t.line);
            },
            .kw_foreach => return self.parseForeach(),
            .kw_function => return self.parseFunction(),
            .kw_class => return self.parseClassDecl(),
            .kw_interface => return self.parseInterfaceDecl(),
            .kw_trait => return self.parseTraitDecl(),
            .kw_throw => {
                _ = self.advance();
                const e = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.stmt(.{ .throw_stmt = e }, t.line);
            },
            .kw_try => return self.parseTry(),
            .kw_return => {
                _ = self.advance();
                var val: ?*ast.Expr = null;
                if (!self.check(.semicolon)) val = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.stmt(.{ .ret = val }, t.line);
            },
            .kw_break, .kw_continue => {
                _ = self.advance();
                var level: u32 = 1;
                if (self.check(.int)) {
                    const n = try self.parseIntToken(self.advance());
                    if (n < 1) return self.fail("break/continue level must be >= 1", .{});
                    level = @intCast(n);
                }
                _ = try self.expect(.semicolon);
                const k: ast.Stmt.Kind = if (t.kind == .kw_break) .{ .brk = level } else .{ .cont = level };
                return self.stmt(k, t.line);
            },
            else => {
                const e = try self.parseExpr();
                _ = try self.expect(.semicolon);
                return self.stmt(.{ .expr = e }, t.line);
            },
        }
    }

    fn parseEcho(self: *Parser) Error!*ast.Stmt {
        const t = self.advance(); // echo
        var list: std.ArrayList(*ast.Expr) = .empty;
        while (true) {
            try list.append(self.arena, try self.parseExpr());
            if (!self.accept(.comma)) break;
        }
        _ = try self.expect(.semicolon);
        return self.stmt(.{ .echo = try list.toOwnedSlice(self.arena) }, t.line);
    }

    fn parseIf(self: *Parser) Error!*ast.Stmt {
        const t = self.advance(); // if
        _ = try self.expect(.lparen);
        var branches: std.ArrayList(ast.Stmt.Branch) = .empty;
        const cond = try self.parseExpr();
        _ = try self.expect(.rparen);
        const body = try self.parseParenBody();
        try branches.append(self.arena, .{ .cond = cond, .body = body });

        var else_body: ?*ast.Stmt = null;
        while (true) {
            if (self.accept(.kw_elseif)) {
                _ = try self.expect(.lparen);
                const c2 = try self.parseExpr();
                _ = try self.expect(.rparen);
                const b2 = try self.parseParenBody();
                try branches.append(self.arena, .{ .cond = c2, .body = b2 });
            } else if (self.accept(.kw_else)) {
                if (self.check(.kw_if)) {
                    // `else if` chains as an elseif branch.
                    _ = self.advance();
                    _ = try self.expect(.lparen);
                    const c2 = try self.parseExpr();
                    _ = try self.expect(.rparen);
                    const b2 = try self.parseParenBody();
                    try branches.append(self.arena, .{ .cond = c2, .body = b2 });
                } else {
                    else_body = try self.parseParenBody();
                    break;
                }
            } else break;
        }

        return self.stmt(.{ .if_stmt = .{
            .branches = try branches.toOwnedSlice(self.arena),
            .else_body = else_body,
        } }, t.line);
    }

    fn parseForeach(self: *Parser) Error!*ast.Stmt {
        const t = self.advance(); // foreach
        _ = try self.expect(.lparen);
        const subject = try self.parseExpr();
        if (!self.accept(.kw_as)) return self.fail("expected 'as' in foreach", .{});

        var key: ?[]const u8 = null;
        var val: []const u8 = undefined;

        const first = try self.expect(.variable);
        if (self.accept(.dbl_arrow)) {
            key = first.text[1..];
            const v = try self.expect(.variable);
            val = v.text[1..];
        } else {
            val = first.text[1..];
        }
        _ = try self.expect(.rparen);
        const body = try self.parseParenBody();
        return self.stmt(.{ .foreach = .{
            .subject = subject,
            .key = key,
            .val = val,
            .body = body,
        } }, t.line);
    }

    fn parseFunction(self: *Parser) Error!*ast.Stmt {
        return self.parseFunctionOpts(false);
    }

    /// `allow_abstract` accepts `function m(...);` (interface methods).
    fn parseFunctionOpts(self: *Parser, allow_abstract: bool) Error!*ast.Stmt {
        const t = self.advance(); // function
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lparen);

        var params: std.ArrayList(ast.Stmt.Param) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                const by_ref = self.accept(.amp);
                const p = try self.expect(.variable);
                var default_val: ?*ast.Expr = null;
                if (self.accept(.assign)) default_val = try self.parseExpr();
                try params.append(self.arena, .{ .name = p.text[1..], .default = default_val, .by_ref = by_ref });
                if (!self.accept(.comma)) break;
            }
        }
        _ = try self.expect(.rparen);
        if (allow_abstract and self.accept(.semicolon)) {
            return self.stmt(.{ .func_decl = .{
                .name = name_tok.text,
                .params = try params.toOwnedSlice(self.arena),
                .body = &.{},
            } }, t.line);
        }
        const body = try self.parseBody();
        return self.stmt(.{ .func_decl = .{
            .name = name_tok.text,
            .params = try params.toOwnedSlice(self.arena),
            .body = blk: {
                // Normalize body into a block statement for uniform execution.
                switch (body.kind) {
                    .block => |b| break :blk b,
                    else => {
                        const arr = try self.arena.alloc(*ast.Stmt, 1);
                        arr[0] = body;
                        break :blk arr;
                    },
                }
            },
        } }, t.line);
    }

    /// Parse a comma-separated expression list terminated by `end`.
    /// Call arguments may be `&$var` (by-reference).
    fn parseCallArgs(self: *Parser, end: Kind) Error![]const *ast.Expr {
        var list: std.ArrayList(*ast.Expr) = .empty;
        if (!self.check(end)) {
            while (true) {
                if (self.check(.amp) and self.toks[self.i + 1].kind == .variable) {
                    const line = self.advance().line;
                    const inner = try self.parseUnary(); // parses $var (and subscripts)
                    try list.append(self.arena, try self.expr(.{ .ref_arg = inner }, line));
                } else {
                    try list.append(self.arena, try self.parseExpr());
                }
                if (!self.accept(.comma)) break;
            }
        }
        return list.toOwnedSlice(self.arena);
    }

    fn parseExprList(self: *Parser, end: Kind) Error![]const *ast.Expr {
        var list: std.ArrayList(*ast.Expr) = .empty;
        if (!self.check(end)) {
            while (true) {
                try list.append(self.arena, try self.parseExpr());
                if (!self.accept(.comma)) break;
            }
        }
        return list.toOwnedSlice(self.arena);
    }

    // -- expressions ----------------------------------------------------------

    fn parseExpr(self: *Parser) Error!*ast.Expr {
        return self.parseAssign();
    }

    fn assignOpOf(kind: Kind) ?ast.AssignOp {
        return switch (kind) {
            .assign => .assign,
            .plus_eq => .add,
            .minus_eq => .sub,
            .mul_eq => .mul,
            .div_eq => .div,
            .mod_eq => .mod,
            .concat_eq => .concat,
            .pow_eq => .pow,
            .coalesce_eq => .coalesce,
            else => null,
        };
    }

    fn binOpOf(kind: Kind) ?ast.BinOp {
        return ast.BinOp.fromToken(kind);
    }

    fn parseAssign(self: *Parser) Error!*ast.Expr {
        const left = try self.parseTernary();
        if (assignOpOf(self.cur().kind)) |op| {
            if (!left.isLvalue()) {
                return self.fail("cannot assign to this expression", .{});
            }
            const line = self.advance().line;
            // `$x =& $y` / `$x = &$y`: reference binding.
            var by_ref = false;
            if (op == .assign and self.accept(.amp)) by_ref = true;
            const value = try self.parseAssign(); // right-associative
            return self.expr(.{ .assign = .{
                .target = left,
                .op = op,
                .value = value,
                .by_ref = by_ref,
            } }, line);
        }
        return left;
    }

    fn parseTernary(self: *Parser) Error!*ast.Expr {
        const cond = try self.parseCoalesce();
        if (!self.check(.question)) return cond;
        const line = self.advance().line;
        var then_e: ?*ast.Expr = null;
        if (!self.check(.colon)) {
            then_e = try self.parseAssign();
        }
        _ = try self.expect(.colon);
        const els = try self.parseTernary();
        return self.expr(.{ .ternary = .{ .cond = cond, .then = then_e, .els = els } }, line);
    }

    fn makeBinary(self: *Parser, op: ast.BinOp, lhs: *ast.Expr, rhs: *ast.Expr, line: u32) Error!*ast.Expr {
        return self.expr(.{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } }, line);
    }

    fn parseCoalesce(self: *Parser) Error!*ast.Expr {
        var l = try self.parseOr();
        while (self.check(.coalesce)) {
            const line = self.advance().line;
            const r = try self.parseOr();
            l = try self.makeBinary(.coalesce, l, r, line);
        }
        return l;
    }

    fn parseOr(self: *Parser) Error!*ast.Expr {
        var l = try self.parseXor();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .logic_or => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseXor();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    fn parseXor(self: *Parser) Error!*ast.Expr {
        var l = try self.parseAnd();
        while (self.check(.kw_xor)) {
            const line = self.advance().line;
            const r = try self.parseAnd();
            l = try self.makeBinary(.logic_xor, l, r, line);
        }
        return l;
    }

    fn parseAnd(self: *Parser) Error!*ast.Expr {
        var l = try self.parseBitOr();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .logic_and => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseBitOr();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    // PHP binds & ^ | below equality but above && / ||.
    fn parseBitOr(self: *Parser) Error!*ast.Expr {
        var l = try self.parseBitXor();
        while (self.check(.pipe)) {
            const line = self.advance().line;
            const r = try self.parseBitXor();
            l = try self.makeBinary(.bit_or, l, r, line);
        }
        return l;
    }

    fn parseBitXor(self: *Parser) Error!*ast.Expr {
        var l = try self.parseBitAnd();
        while (self.check(.caret)) {
            const line = self.advance().line;
            const r = try self.parseBitAnd();
            l = try self.makeBinary(.bit_xor, l, r, line);
        }
        return l;
    }

    fn parseBitAnd(self: *Parser) Error!*ast.Expr {
        var l = try self.parseEquality();
        while (self.check(.amp)) {
            const line = self.advance().line;
            const r = try self.parseEquality();
            l = try self.makeBinary(.bit_and, l, r, line);
        }
        return l;
    }

    fn parseEquality(self: *Parser) Error!*ast.Expr {
        var l = try self.parseRelational();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .eq, .neq, .identical, .not_identical, .spaceship => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseRelational();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    fn parseRelational(self: *Parser) Error!*ast.Expr {
        var l = try self.parseShift();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .lt, .gt, .lte, .gte => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseShift();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    // `<<` / `>>` sit between additive/multiplicative and relational in PHP.
    fn parseShift(self: *Parser) Error!*ast.Expr {
        var l = try self.parseAdditive();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .shl, .shr => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseAdditive();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    fn parseAdditive(self: *Parser) Error!*ast.Expr {
        var l = try self.parseMultiplicative();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .add, .sub, .concat => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseMultiplicative();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    fn parseMultiplicative(self: *Parser) Error!*ast.Expr {
        var l = try self.parseUnary();
        while (true) {
            const op = binOpOf(self.cur().kind) orelse break;
            switch (op) {
                .mul, .div, .mod => {},
                else => break,
            }
            const line = self.advance().line;
            const r = try self.parseUnary();
            l = try self.makeBinary(op, l, r, line);
        }
        return l;
    }

    /// `**` binds tighter than unary on the left: `-2 ** 2 == -4`.
    fn parsePowBase(self: *Parser) Error!*ast.Expr {
        const l = try self.parsePostfix();
        if (self.check(.pow)) {
            const line = self.advance().line;
            const r = try self.parseUnary(); // right-assoc; RHS may be signed
            return self.expr(.{ .binary = .{ .op = .pow, .lhs = l, .rhs = r } }, line);
        }
        return l;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        const line = self.cur().line;
        switch (self.cur().kind) {
            .bang => {
                _ = self.advance();
                const operand = try self.parseUnary();
                return self.expr(.{ .unary = .{ .op = .not, .operand = operand } }, line);
            },
            .minus => {
                _ = self.advance();
                const operand = try self.parseUnary();
                return self.expr(.{ .unary = .{ .op = .neg, .operand = operand } }, line);
            },
            .plus => {
                _ = self.advance();
                const operand = try self.parseUnary();
                return self.expr(.{ .unary = .{ .op = .pos, .operand = operand } }, line);
            },
            .tilde => {
                _ = self.advance();
                const operand = try self.parseUnary();
                return self.expr(.{ .unary = .{ .op = .bit_not, .operand = operand } }, line);
            },
            .incr, .decr => {
                const up = self.advance().kind == .incr;
                const target = try self.parseUnary();
                if (!target.isLvalue()) return self.fail("cannot increment/decrement this expression", .{});
                return self.expr(.{ .inc_dec = .{
                    .target = target,
                    .up = up,
                    .postfix = false,
                } }, line);
            },
            else => return self.parsePowBase(),
        }
    }

    fn parsePostfix(self: *Parser) Error!*ast.Expr {
        var e = try self.parsePrimary();
        while (true) {
            const line = self.cur().line;
            switch (self.cur().kind) {
                .lbracket => {
                    _ = self.advance();
                    if (self.accept(.rbracket)) {
                        e = try self.expr(.{ .index = .{ .base = e, .index = null } }, line);
                        continue;
                    }
                    const idx = try self.parseExpr();
                    _ = try self.expect(.rbracket);
                    e = try self.expr(.{ .index = .{ .base = e, .index = idx } }, line);
                },
                .lparen => {
                    // Function call: callee must be a plain name.
                    const name: []const u8 = switch (e.kind) {
                        .var_ref => |n| n,
                        .str_lit => |s| s, // bare constant fallback used as name
                        else => return self.fail("syntax error, unexpected '('", .{}),
                    };
                    _ = self.advance();
                    const args = try self.parseCallArgs(.rparen);
                    _ = try self.expect(.rparen);
                    e = try self.expr(.{ .call = .{ .name = name, .args = args } }, line);
                },
                .dbl_colon => {
                    // Static access: preceding must be a class-name token
                    // (ident / self / parent — captured as var_ref).
                    _ = self.advance();
                    var cls: []const u8 = "";
                    switch (e.kind) {
                        .var_ref => |n| cls = n,
                        .str_lit => |x| cls = x,
                        else => return self.fail("dynamic '::' access is not supported", .{}),
                    }
                    if (self.check(.variable)) {
                        const pt = self.advance(); // $prop
                        e = try self.expr(.{ .static_get = .{ .cls = cls, .name = pt.text[1..] } }, line);
                    } else {
                        const mt = try self.expect(.ident);
                        if (self.check(.lparen)) {
                            _ = self.advance();
                            const args = if (self.check(.rparen)) try self.arena.alloc(*ast.Expr, 0) else try self.parseCallArgs(.rparen);
                            _ = try self.expect(.rparen);
                            e = try self.expr(.{ .static_call = .{ .cls = cls, .name = mt.text, .args = args } }, line);
                        } else {
                            return self.fail("class constants are not supported", .{});
                        }
                    }
                },
                .object_op => {
                    _ = self.advance();
                    const name_tok = try self.expect(.ident);
                    if (self.check(.lparen)) {
                        _ = self.advance();
                        const args = if (self.check(.rparen)) try self.arena.alloc(*ast.Expr, 0) else try self.parseCallArgs(.rparen);
                        _ = try self.expect(.rparen);
                        e = try self.expr(.{ .method_call = .{ .obj = e, .name = name_tok.text, .args = args } }, line);
                    } else {
                        e = try self.expr(.{ .prop_get = .{ .obj = e, .name = name_tok.text } }, line);
                    }
                },
                .kw_instanceof => {
                    _ = self.advance();
                    const cls = try self.expect(.ident);
                    e = try self.expr(.{ .instanceof = .{ .operand = e, .class_name = cls.text } }, line);
                },
                .incr, .decr => {
                    if (!e.isLvalue()) return self.fail("cannot increment/decrement this expression", .{});
                    const up = self.advance().kind == .incr;
                    e = try self.expr(.{ .inc_dec = .{
                        .target = e,
                        .up = up,
                        .postfix = true,
                    } }, line);
                },
                else => return e,
            }
        }
    }

    fn parseIntToken(self: *Parser, t: Token) Error!i64 {
        // PHP-style octal: 0 followed by octal digits (e.g. 010 == 8).
        if (t.text.len > 1 and t.text[0] == '0' and
            std.ascii.isDigit(t.text[1]) and t.text[1] < '8')
        {
            return std.fmt.parseInt(i64, t.text[1..], 8) catch {
                return self.fail("invalid integer literal '{s}'", .{t.text});
            };
        }
        return std.fmt.parseInt(i64, t.text, 0) catch {
            return self.fail("invalid integer literal '{s}'", .{t.text});
        };
    }

    fn parseFloatToken(self: *Parser, t: Token) Error!f64 {
        return std.fmt.parseFloat(f64, t.text) catch {
            return self.fail("invalid float literal '{s}'", .{t.text});
        };
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        const t = self.cur();
        switch (t.kind) {
            .int => {
                _ = self.advance();
                return self.expr(.{ .int_lit = try self.parseIntToken(t) }, t.line);
            },
            .float => {
                _ = self.advance();
                return self.expr(.{ .float_lit = try self.parseFloatToken(t) }, t.line);
            },
            .string => {
                _ = self.advance();
                return self.parseStringLiteral(t);
            },
            .variable => {
                _ = self.advance();
                return self.expr(.{ .var_ref = t.text[1..] }, t.line);
            },
            .kw_true => {
                _ = self.advance();
                return self.expr(.{ .bool_lit = true }, t.line);
            },
            .kw_false => {
                _ = self.advance();
                return self.expr(.{ .bool_lit = false }, t.line);
            },
            .kw_null => {
                _ = self.advance();
                return self.expr(.null_lit, t.line);
            },
            .kw_new => {
            _ = self.advance();
            const cls = try self.expect(.ident);
            _ = try self.expect(.lparen);
            const args = if (self.check(.rparen)) try self.arena.alloc(*ast.Expr, 0) else try self.parseExprList(.rparen);
            _ = try self.expect(.rparen);
            return self.expr(.{ .new = .{ .class_name = cls.text, .args = args } }, t.line);
        },
        .kw_this => {
            _ = self.advance();
            return self.expr(.{ .var_ref = "this" }, t.line);
        },
        .kw_self, .kw_parent => {
            _ = self.advance();
            return self.expr(.{ .var_ref = t.text }, t.line); // consumed by '::'
        },
        .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return inner;
            },
            .lbracket => {
                _ = self.advance();
                const items = try self.parseArrayItems(.rbracket);
                _ = try self.expect(.rbracket);
                return self.expr(.{ .array_lit = items }, t.line);
            },
            .kw_isset => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const exprs = try self.parseExprList(.rparen);
                _ = try self.expect(.rparen);
                return self.expr(.{ .isset = exprs }, t.line);
            },
            .kw_empty => {
                _ = self.advance();
                _ = try self.expect(.lparen);
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                return self.expr(.{ .empty = inner }, t.line);
            },
            .ident => {
                // A bare identifier is an Error under PHP 8 semantics...
                // unless it's immediately called as a function name or used
                // as a static class name (`Cls::`).
                if (self.toks[self.i + 1].kind == .lparen) {
                    _ = self.advance();
                    return self.expr(.{ .str_lit = t.text }, t.line);
                }
                if (self.toks[self.i + 1].kind == .dbl_colon) {
                    _ = self.advance();
                    return self.expr(.{ .str_lit = t.text }, t.line);
                }
                return self.fail("undefined constant '{s}' (PHP 8 semantics)", .{t.text});
            },
            else => {
                if (t.text.len > 0) {
                    return self.fail("syntax error, unexpected '{s}'", .{t.text});
                }
                return self.fail("syntax error, unexpected end of file", .{});
            },
        }
    }

    fn parseTry(self: *Parser) Error!*ast.Stmt {
        const t = self.advance(); // try
        const body = try self.parseBody();

        var catches: std.ArrayList(ast.Stmt.CatchClause) = .empty;
        while (self.check(.kw_catch)) {
            _ = self.advance();
            _ = try self.expect(.lparen);
            var types: std.ArrayList([]const u8) = .empty;
            while (true) {
                const ct = try self.expect(.ident);
                try types.append(self.arena, ct.text);
                if (!self.accept(.pipe)) break;
            }
            const vt = try self.expect(.variable);
            _ = try self.expect(.rparen);
            const cbody = try self.parseBody();
            try catches.append(self.arena, .{
                .types = try types.toOwnedSlice(self.arena),
                .var_name = vt.text[1..],
                .body = cbody,
            });
        }
        if (catches.items.len == 0) {
            if (self.check(.ident) and std.mem.eql(u8, self.cur().text, "finally")) {
                return self.fail("finally is not supported", .{});
            }
            return self.fail("try statement must have at least one catch block", .{});
        }
        return self.stmt(.{ .try_stmt = .{
            .body = body,
            .catches = try catches.toOwnedSlice(self.arena),
        } }, t.line);
    }

    /// class Name extends Base { props & methods }
    /// Visibility keywords are accepted and ignored (all members public).
    fn parseClassDecl(self: *Parser) Error!*ast.Stmt {
        return self.parseClassLike(false);
    }

    fn parseInterfaceDecl(self: *Parser) Error!*ast.Stmt {
        return self.parseClassLike(true);
    }

    fn parseTraitDecl(self: *Parser) Error!*ast.Stmt {
        const t = self.advance(); // trait
        const name_tok = try self.expect(.ident);
        _ = try self.expect(.lbrace);
        var methods: std.ArrayList(ast.Stmt.FuncDecl) = .empty;
        while (!self.check(.rbrace)) {
            _ = self.accept(.kw_public) or self.accept(.kw_private) or self.accept(.kw_protected);
            if (self.check(.kw_function)) {
                const m = try self.parseFunction();
                try methods.append(self.arena, m.kind.func_decl);
            } else {
                return self.fail("unexpected '{s}' in trait body", .{self.cur().text});
            }
        }
        _ = try self.expect(.rbrace);
        return self.stmt(.{ .class_decl = .{
            .name = name_tok.text,
            .extends = null,
            .props = &.{},
            .methods = try methods.toOwnedSlice(self.arena),
            .is_trait = true,
        } }, t.line);
    }

    fn parseClassLike(self: *Parser, is_interface: bool) Error!*ast.Stmt {
        const t = self.advance(); // class / interface
        const name_tok = try self.expect(.ident);
        var extends: ?[]const u8 = null;
        if (self.accept(.kw_extends)) {
            extends = (try self.expect(.ident)).text;
        }
        var implements: std.ArrayList([]const u8) = .empty;
        if (self.accept(.kw_implements)) {
            while (true) {
                const it = try self.expect(.ident);
                try implements.append(self.arena, it.text);
                if (!self.accept(.comma)) break;
            }
        }
        _ = try self.expect(.lbrace);

        var props: std.ArrayList(ast.Stmt.PropDecl) = .empty;
        var static_props: std.ArrayList(ast.Stmt.PropDecl) = .empty;
        var methods: std.ArrayList(ast.Stmt.FuncDecl) = .empty;
        var uses: std.ArrayList([]const u8) = .empty;
        while (!self.check(.rbrace)) {
            var is_static = false;
            if (self.accept(.kw_public) or self.accept(.kw_private) or self.accept(.kw_protected)) {
                // visibility ignored
            }
            if (self.accept(.kw_static)) is_static = true;
            if (self.check(.kw_use)) {
                _ = self.advance();
                while (true) {
                    const tn = try self.expect(.ident);
                    try uses.append(self.arena, tn.text);
                    if (!self.accept(.comma)) break;
                }
                _ = try self.expect(.semicolon);
                continue;
            }
            if (self.check(.kw_function)) {
                const m = try self.parseFunctionOpts(is_interface);
                var fd = m.kind.func_decl;
                fd.is_static = is_static;
                try methods.append(self.arena, fd);
            } else if (self.check(.variable)) {
                const p = self.advance();
                var default_val: ?valmod.Value = null;
                if (self.accept(.assign)) {
                    default_val = try self.parseConstDefault();
                }
                _ = try self.expect(.semicolon);
                const decl = ast.Stmt.PropDecl{ .name = p.text[1..], .default = default_val };
                if (is_interface) {
                    return self.fail("interfaces cannot have properties", .{});
                }
                if (is_static) try static_props.append(self.arena, decl) else try props.append(self.arena, decl);
            } else {
                return self.fail("unexpected '{s}' in class body", .{self.cur().text});
            }
        }
        _ = try self.expect(.rbrace);
        return self.stmt(.{ .class_decl = .{
            .name = name_tok.text,
            .extends = extends,
            .implements = try implements.toOwnedSlice(self.arena),
            .uses = try uses.toOwnedSlice(self.arena),
            .static_props = try static_props.toOwnedSlice(self.arena),
            .props = try props.toOwnedSlice(self.arena),
            .methods = try methods.toOwnedSlice(self.arena),
            .is_interface = is_interface,
        } }, t.line);
    }

    /// Property defaults accept literals only.
    fn parseConstDefault(self: *Parser) Error!valmod.Value {
        const t = self.advance();
        return switch (t.kind) {
            .int => .{ .int_ = try self.parseIntToken(t) },
            .float => .{ .float_ = try self.parseFloatToken(t) },
            .string => blk: {
                const text = if (t.single_quoted)
                    try unescapeSingleQuoted(self.arena, t.text)
                else
                    t.text; // no interpolation in defaults
                const boxed = try valmod.newStr(self.arena, text);
                break :blk valmod.Value{ .str_ = boxed };
            },
            .kw_true => .{ .bool_ = true },
            .kw_false => .{ .bool_ = false },
            .kw_null => .null_,
            .minus => {
                const n = self.advance();
                switch (n.kind) {
                    .int => return valmod.Value{ .int_ = -try self.parseIntToken(n) },
                    .float => return valmod.Value{ .float_ = -try self.parseFloatToken(n) },
                    else => return self.fail("unsupported property default", .{}),
                }
            },
            else => return self.fail("property default must be a constant expression", .{}),
        };
    }

    fn parseArrayItems(self: *Parser, end: Kind) Error![]const ast.Expr.Elem {
        var list: std.ArrayList(ast.Expr.Elem) = .empty;
        if (!self.check(end)) {
            while (true) {
                const first = try self.parseExpr();
                if (self.accept(.dbl_arrow)) {
                    const val = try self.parseExpr();
                    try list.append(self.arena, .{ .key = first, .val = val });
                } else {
                    try list.append(self.arena, .{ .key = null, .val = first });
                }
                if (!self.accept(.comma)) break;
                if (self.check(end)) break; // trailing comma
            }
        }
        return list.toOwnedSlice(self.arena);
    }

    fn parseStringLiteral(self: *Parser, t: Token) Error!*ast.Expr {
        if (t.single_quoted) {
            // Single quotes: only \' and \\ escapes, no interpolation.
            const unescaped = try unescapeSingleQuoted(self.arena, t.text);
            return self.expr(.{ .str_lit = unescaped }, t.line);
        }
        // Double quotes: process escapes & $var interpolation.
        const parts = try splitInterpolated(self.arena, t.text);
        if (parts.len == 1 and parts[0] == .literal) {
            return self.expr(.{ .str_lit = parts[0].literal }, t.line);
        }
        return self.expr(.{ .interp_str = parts }, t.line);
    }
};

// ---------------------------------------------------------------------------
// Escape processing & string interpolation
// ---------------------------------------------------------------------------

/// Single-quoted strings only recognize \' and \\ escapes.
fn unescapeSingleQuoted(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len and (raw[i + 1] == '\'' or raw[i + 1] == '\\')) {
            i += 1;
        }
        try out.append(arena, raw[i]);
    }
    return out.items;
}

// Note: double-quoted strings are always processed by splitInterpolated()
// above, which handles both escapes and $var interpolation.

/// Split a double-quoted string into literal / variable parts, processing
/// escape sequences. Supports `$name`, `$name[key]` (bare word or integer),
/// and the `{$name}` / `{$name[key]}` brace forms.
fn splitInterpolated(arena: std.mem.Allocator, raw: []const u8) ![]ast.StrPart {
    var parts: std.ArrayList(ast.StrPart) = .empty;
    var buf: std.ArrayList(u8) = .empty;

    const flushLit = struct {
        fn f(a: std.mem.Allocator, list: *std.ArrayList(ast.StrPart), b: *std.ArrayList(u8)) !void {
            if (b.items.len > 0) {
                try list.append(a, .{ .literal = try a.dupe(u8, b.items) });
                b.clearRetainingCapacity();
            }
        }
    }.f;

    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];

        // Escape sequences.
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            const e = raw[i];
            switch (e) {
                'n' => try buf.append(arena, '\n'),
                't' => try buf.append(arena, '\t'),
                'r' => try buf.append(arena, '\r'),
                'v' => try buf.append(arena, 0x0b),
                'f' => try buf.append(arena, 0x0c),
                'e' => try buf.append(arena, 0x1b),
                '0' => try buf.append(arena, 0),
                '\\' => try buf.append(arena, '\\'),
                '$' => try buf.append(arena, '$'),
                '"' => try buf.append(arena, '"'),
                '{', '}' => try buf.append(arena, raw[i]), // \{ \} escape the brace
                'x' => {
                    // \xHH
                    var v: u16 = 0;
                    var n: usize = 0;
                    while (n < 2 and i + 1 < raw.len and std.ascii.isHex(raw[i + 1])) {
                        i += 1;
                        v = v * 16 + hexVal(raw[i]);
                        n += 1;
                    }
                    try buf.append(arena, @intCast(v));
                },
                else => {
                    // Unknown escape: keep both characters (PHP behavior).
                    try buf.append(arena, '\\');
                    try buf.append(arena, e);
                },
            }
            i += 1;
            continue;
        }

        // {$name} and {$name[k1][k2]...} brace form (quoted keys allowed).
        if (c == '{' and i + 1 < raw.len and raw[i + 1] == '$') {
            var j = i + 2;
            if (readIdent(raw, &j)) |name| {
                var keys: std.ArrayList(ast.IndexKey) = .empty;
                while (j < raw.len and raw[j] == '[') {
                    const start = j;
                    if (readIndexKey(raw, &j)) |key| {
                        try keys.append(arena, key);
                    } else {
                        j = start; // not a valid chain; rewind
                        break;
                    }
                }
                if (j < raw.len and raw[j] == '}') {
                    j += 1;
                    try flushLit(arena, &parts, &buf);
                    try appendVarPart(arena, &parts, name, keys.items);
                    i = j;
                    continue;
                }
            }
        }

        // $name and $name[key] (single level, PHP's simple syntax)
        if (c == '$' and i + 1 < raw.len and isIdentStartB(raw[i + 1])) {
            var j = i + 1;
            const name = readIdent(raw, &j).?;
            var keys: std.ArrayList(ast.IndexKey) = .empty;
            if (j < raw.len and raw[j] == '[') {
                if (readIndexKey(raw, &j)) |key| {
                    try keys.append(arena, key);
                }
            }
            try flushLit(arena, &parts, &buf);
            try appendVarPart(arena, &parts, name, keys.items);
            i = j;
            continue;
        }

        try buf.append(arena, c);
        i += 1;
    }
    try flushLit(arena, &parts, &buf);
    return parts.toOwnedSlice(arena);
}

/// Read `[key]` starting at raw[j.*] == '['; advances past the closing ']'.
/// Keys may be bare identifiers, integers, or (used from the brace form)
/// quoted strings. Returns null when the form is invalid.
fn readIndexKey(raw: []const u8, j: *usize) ?ast.IndexKey {
    if (j.* >= raw.len or raw[j.*] != '[') return null;
    var k = j.* + 1;

    // Quoted string key.
    if (k < raw.len and (raw[k] == '\'' or raw[k] == '"')) {
        const q = raw[k];
        const ks = k + 1;
        var e = ks;
        while (e < raw.len and raw[e] != q) e += 1;
        if (e < raw.len and e + 1 < raw.len and raw[e + 1] == ']') {
            j.* = e + 2;
            return .{ .str = raw[ks..e] };
        }
        return null;
    }

    // Bare identifier.
    if (readIdentUntil(raw, &k, ']')) |key| {
        if (k < raw.len and raw[k] == ']') {
            j.* = k + 1;
            return .{ .str = key };
        }
        return null;
    }

    // Integer.
    var iv: i64 = 0;
    var any = false;
    while (k < raw.len and std.ascii.isDigit(raw[k])) : (k += 1) {
        iv = iv * 10 + (raw[k] - '0');
        any = true;
    }
    if (any and k < raw.len and raw[k] == ']') {
        j.* = k + 1;
        return .{ .int = iv };
    }
    return null;
}

fn appendVarPart(
    arena: std.mem.Allocator,
    parts: *std.ArrayList(ast.StrPart),
    name: []const u8,
    keys: []const ast.IndexKey,
) !void {
    if (keys.len > 0) {
        try parts.append(arena, .{ .var_index = .{
            .name = name,
            .keys = try arena.dupe(ast.IndexKey, keys),
        } });
    } else {
        try parts.append(arena, .{ .var_ref = name });
    }
}

fn hexVal(c: u8) u16 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

fn isIdentStartB(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentCharB(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// Reads an identifier starting at raw[j.*]; advances j past it.
/// Returns null when there is no identifier at that position.
fn readIdent(raw: []const u8, j: *usize) ?[]const u8 {
    const start = j.*;
    if (j.* >= raw.len or !isIdentStartB(raw[j.*])) return null;
    while (j.* < raw.len and isIdentCharB(raw[j.*])) j.* += 1;
    return raw[start..j.*];
}

/// Like readIdent but stops before `stop` without consuming it.
fn readIdentUntil(raw: []const u8, j: *usize, stop: u8) ?[]const u8 {
    const start = j.*;
    if (j.* >= raw.len or !isIdentStartB(raw[j.*]) or raw[j.*] == stop) return null;
    while (j.* < raw.len and raw[j.*] != stop and isIdentCharB(raw[j.*])) j.* += 1;
    if (j.* >= raw.len or raw[j.*] != stop) {
        j.* = start;
        return null;
    }
    return raw[start..j.*];
}

fn describe(kind: Kind) []const u8 {
    return switch (kind) {
        .int => "integer",
        .float => "float",
        .string => "string",
        .ident => "identifier",
        .variable => "variable",
        .eof => "end of file",
        else => "'token'",
    };
}
