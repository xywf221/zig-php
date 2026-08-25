//! Abstract syntax tree for the zphp interpreter.
//!
//! Nodes are arena-allocated and immutable after parsing; every node carries
//! the source line it started on for diagnostics.

const std = @import("std");
const valmod = @import("value.zig");

pub const BinOp = enum {
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    pow, // **
    concat, // .
    eq, // ==
    neq, // !=
    identical, // ===
    not_identical, // !==
    spaceship, // <=>
    lt,
    gt,
    lte,
    gte,
    logic_and,
    logic_or,
    logic_xor,
    coalesce, // ??
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,

    pub fn fromToken(kind: anytype) ?BinOp {
        return switch (kind) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
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
            .logic_and => .logic_and,
            .logic_or => .logic_or,
            .kw_and => .logic_and,
            .kw_or => .logic_or,
            .kw_xor => .logic_xor,
            .coalesce => .coalesce,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .shl => .shl,
            .shr => .shr,
            else => null,
        };
    }
};

pub const UnOp = enum {
    neg, // -
    pos, // +
    not, // !
    bit_not, // ~
};

pub const AssignOp = enum {
    assign, // =
    add, // +=
    sub, // -=
    mul, // *=
    div, // /=
    mod, // %=
    concat, // .=
    pow, // **=
    coalesce, // ??=
};

/// One piece of a double-quoted interpolated string.
pub const StrPart = union(enum) {
    /// Plain literal text (escapes already processed).
    literal: []const u8,
    /// `$name` or `{$name}` interpolation.
    var_ref: []const u8,
    /// `$name[key1][key2]...` / `{$name[key]}` chains where each key is an
    /// unquoted identifier or a non-negative integer.
    var_index: struct { name: []const u8, keys: []const IndexKey },
};

/// A key in an interpolated variable chain.
pub const IndexKey = union(enum) {
    str: []const u8,
    int: i64,
};

pub const Expr = struct {
    line: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        int_lit: i64,
        float_lit: f64,
        str_lit: []const u8,
        interp_str: []const StrPart,
        bool_lit: bool,
        null_lit,
        /// Bare variable reference (without the '$').
        var_ref: []const u8,
        array_lit: []const Elem,
        binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
        unary: struct { op: UnOp, operand: *Expr },
        assign: Assign,
        ternary: struct { cond: *Expr, then: ?*Expr, els: *Expr },
        inc_dec: struct { target: *Expr, up: bool, postfix: bool },
        call: struct { name: []const u8, args: []const *Expr },
        /// `$base[index]`; `index == null` only appears as an append
        /// assignment target (`$a[] = ...`).
        index: struct { base: *Expr, index: ?*Expr },
        isset: []const *Expr,
        empty: *Expr,
        /// `new ClassName(args)`
        new: struct { class_name: []const u8, args: []const *Expr },
        /// `$obj->prop`
        prop_get: struct { obj: *Expr, name: []const u8 },
        /// `$obj->method(args)`
        method_call: struct { obj: *Expr, name: []const u8, args: []const *Expr },
        /// `expr instanceof ClassName`
        instanceof: struct { operand: *Expr, class_name: []const u8 },
    };

    pub const Elem = struct { key: ?*Expr, val: *Expr };
    pub const Assign = struct { target: *Expr, op: AssignOp, value: *Expr };

    pub fn isLvalue(self: *const Expr) bool {
        return switch (self.kind) {
            .var_ref, .index, .prop_get => true,
            else => false,
        };
    }
};

pub const Stmt = struct {
    line: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        expr: *Expr,
        echo: []const *Expr,
        if_stmt: If,
        while_stmt: struct { cond: *Expr, body: *Stmt },
        do_while: struct { cond: *Expr, body: *Stmt },
        for_stmt: For,
        foreach: Foreach,
        func_decl: FuncDecl,
        class_decl: ClassDecl,
        ret: ?*Expr,
        brk: u32,
        cont: u32,
        block: []const *Stmt,
        nop,
    };

    pub const If = struct {
        branches: []const Branch, // at least one; elseifs appended
        else_body: ?*Stmt,
    };

    pub const Branch = struct { cond: *Expr, body: *Stmt };

    pub const For = struct {
        init: []const *Expr,
        cond: ?*Expr,
        step: []const *Expr,
        body: *Stmt,
    };

    pub const Foreach = struct {
        subject: *Expr,
        key: ?[]const u8,
        val: []const u8,
        body: *Stmt,
    };

    pub const FuncDecl = struct {
        name: []const u8,
        params: []const Param,
        body: []const *Stmt,
    };

    pub const Param = struct {
        /// Parameter name without '$'.
        name: []const u8,
        default: ?*Expr,
    };

    pub const PropDecl = struct {
        /// Property name without '$'.
        name: []const u8,
        /// Constant default (literal / constant-foldable); null = unset.
        default: ?valmod.Value,
    };

    pub const ClassDecl = struct {
        name: []const u8,
        extends: ?[]const u8,
        props: []const PropDecl,
        methods: []const FuncDecl,
    };
};
