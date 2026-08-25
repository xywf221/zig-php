//! Bytecode instruction set for the zphp VM.
//!
//! Fixed-size instructions (opcode + u32 operand) over an operand stack,
//! in the spirit of QuickJS's bytecode design. Operands reference either
//! the chunk's constant pool (by index) or frame-local variable slots.
//!
//! `Op.inline_arg` is not a real instruction: it reserves one word of
//! immediate data in the stream, consumed by the preceding instruction
//! (used e.g. by `foreach_next` for its loop-exit target).

const std = @import("std");

pub const Op = enum(u8) {
    // -- stack manipulation ---------------------------------------------------
    pop, // a -> (empty)
    dup, // a -> a a
    dup2, // a b -> a b a b

    // -- constants --------------------------------------------------------------
    const_k, // push consts[arg]
    null_, // push null
    true_,
    false_,
    /// Data word, never executed.
    inline_arg,

    // -- variables ----------------------------------------------------------------
    get_local, // push locals[arg]
    set_local, // pop into locals[arg]
    get_global, // push globals[name=consts[arg]] (null when unset)
    set_global, // pop into globals

    // -- function registration --------------------------------------------------------
    /// Register program.funcs[consts[arg]] into the runtime function table
    /// (conditional declarations register when execution reaches them).
    declare_func,

    // -- containers -----------------------------------------------------------------
    /// Push the auto-vivified array held by a variable.
    get_container_local, // arg = slot
    get_container_global, // arg = name const
    /// [parent key] -> vivify parent[key] as array, leave [sub_array].
    subcontainer,

    // -- arrays ------------------------------------------------------------------------
    new_array, // pop arg values -> array (sequential keys)
    new_array_kv, // pop 2*arg (key,value) pairs -> array
    get_index, // [container key] -> value
    set_index, // [container key value] -> value (assignment result)
    append_index, // [container value] -> value
    isset_index, // [container key] -> bool

    // -- arithmetic / concat (pop 2, push 1) ---------------------------------------------
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    concat,

    // -- bitwise -------------------------------------------------------------------------
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    bit_not, // unary

    // -- comparison (loose unless noted) ----------------------------------------------------
    eq,
    neq,
    identical,
    not_identical,
    lt,
    gt,
    lte,
    gte,
    spaceship,

    // -- unary ------------------------------------------------------------------------------
    neg,
    pos,
    not, // logical !
    to_bool, // coerce truthiness
    is_not_null, // isset() semantics for arbitrary expressions

    // -- jumps (arg = absolute instruction index) ----------------------------------------------
    jmp,
    /// Pop top; jump when falsy.
    jmp_if_false,
    /// Pop top; jump when truthy.
    jmp_if_true,
    /// Peek top; when falsy overwrite it with `false` and jump (for `&&`).
    jmp_if_false_keep,
    /// Peek top; when truthy overwrite it with `true` and jump (for `||`).
    jmp_if_true_keep,
    /// Peek top; jump when truthy without any modification (for `?:`).
    jmp_if_true_raw,
    /// [a b] -> winner of `??` (a unless a === null, else b).
    coalesce,
    /// Logical xor: pop 2, push bool(truthiness differs).
    logic_xor,

    // -- strings / output --------------------------------------------------------------------------
    strconcat, // pop arg values, string-convert each, join, push
    echo, // pop arg values, print in push order

    // -- inc/dec --------------------------------------------------------------------------------------
    pre_inc_local,
    post_inc_local,
    pre_dec_local,
    post_dec_local,
    pre_inc_global, // arg = name const
    post_inc_global,
    pre_dec_global,
    post_dec_global,
    pre_inc_index, // [container key]
    post_inc_index,
    pre_dec_index,
    post_dec_index,

    // -- calls / returns ----------------------------------------------------------------------------------
    /// arg = packCall(name_const, argc); pops argc args (pushed left-to-right).
    call,
    return_val, // pop, return
    return_null,

    // -- foreach --------------------------------------------------------------------------------------------
    /// Pop subject (array|null); store snapshot iterator in temps[arg .. arg+1].
    foreach_init,
    /// Packed arg = temp<<1 | has_key. Followed by an `inline_arg` word giving
    /// the loop-exit instruction index. When items remain, pushes the key
    /// (if has_key) then the value; otherwise jumps to the exit target.
    foreach_next,

    // -- isset on plain variables -----------------------------------------------------------------------------
    isset_local,
    isset_global, // arg = name const
};

/// One decoded instruction.
pub const Instr = struct {
    op: Op,
    arg: u32 = 0,
};

pub fn packCall(name_const: u32, argc: u32) u32 {
    return (name_const << 8) | (argc & 0xFF);
}

pub fn unpackCallName(arg: u32) u32 {
    return arg >> 8;
}

pub fn unpackCallArgc(arg: u32) u32 {
    return arg & 0xFF;
}

pub fn packForeach(temp: u32, has_key: bool) u32 {
    return (temp << 1) | @intFromBool(has_key);
}

pub fn unpackForeachTemp(arg: u32) u32 {
    return arg >> 1;
}

pub fn unpackForeachHasKey(arg: u32) bool {
    return arg & 1 != 0;
}
