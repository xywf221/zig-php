//! Register-based instruction set for the zphp VM.
//!
//! Three-address code in the style of Lua / Dalvik: every instruction names
//! its operands by register index instead of pushing/popping an operand
//! stack. Fixed-size instructions `{ op, a, b, c }`.
//!
//! Register layout per frame:
//!   [0 .. nlocals)  parameters and declared locals
//!   [nlocals..nregs) expression temporaries
//! Plus a hidden per-frame storage area for foreach iterators.
//!
//! `Op.inline_arg` words carry immediate data consumed by the preceding
//! instruction (jump targets, iterator ids).

const std = @import("std");

pub const Op = enum(u8) {
    // -- loads -----------------------------------------------------------------
    ld_const, // a = consts[b]
    ld_null, // a
    ld_true, // a
    ld_false, // a
    mov, // a = regs[b]
    inline_arg, // data word, never executed

    // -- arrays ------------------------------------------------------------------
    new_array, // a = []
    append_arr, // arr=a, val=b          (no result)
    set_index, // a(arr)[b(key)] = c(val)
    get_index, // a = b(arr|str)[c(key)]
    isset_index, // a = isset(b[c])
    /// a = array stored at local slot b, vivifying null/missing to [].
    vivify_local,
    /// a = vivify(b(parent arr)[c(key)]) as array
    subcontainer,

    // -- arithmetic / concat (a = b OP c) ---------------------------------------------
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    concat,

    // -- bitwise ------------------------------------------------------------------------
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,

    // -- comparison (loose unless noted; a = bool(b OP c)) ---------------------------------
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    spaceship,
    identical,
    not_identical,

    // -- unary (a = OP b) --------------------------------------------------------------------
    neg,
    pos,
    not,
    to_bool,
    bit_not,
    is_not_null,
    /// Warn "Undefined variable $consts[a]" (no runtime effect).
    warn_undef,
    /// a = (b !== null) ? b : c
    coalesce,

    // -- objects ------------------------------------------------------------------
    /// a = new consts[c](regs[b..b+a]) ; runs __construct when defined
    new_obj,
    /// a = regs[b]->consts[c]
    get_prop,
    /// regs[a]->consts[b] = regs[c]
    set_prop,
    /// a = regs[b] (instance at b, args b+1..) .consts[c]()
    call_method,
    /// a = (regs[b] instanceof consts[c])
    instanceof,
    /// register class consts[a] (conditional declarations)
    declare_class,
    /// property inc/dec: pre forms write new value to a; post write old
    prop_pre_inc,
    prop_pre_dec,
    prop_post_inc,
    prop_post_dec,

    // -- exceptions -----------------------------------------------------------------
    /// push a try region (inline word: handler address, patched)
    try_start,
    /// pop the active try region
    try_end,
    /// throw regs[b]
    throw_v,
    /// a = pending exception class ∈ consts[c] clause types
    catch_match,
    /// a = pending exception value (and clear it)
    catch_store,
    /// re-throw the pending exception (no clause matched)
    rethrow,

    // -- references ------------------------------------------------------------------
    /// a = deref(regs[b])
    ld_ref,
    /// write regs[b] through regs[a]'s cell (a must hold .ref_)
    st_ref,
    /// promote slot b to a shared Cell; a = that cell (.ref_)
    make_ref_cell,
    /// regs[a] = the .ref_ cell in regs[b]
    bind_ref,
    /// a = get-or-create shared Cell for regs[b][regs[c]] (array element)
    elem_cell,

    // -- strings / output ----------------------------------------------------------------------
    strconcat, // a = join(regs[b] .. regs[b+c-1]) stringified
    echo, // print regs[a] .. regs[a+b-1]

    // -- inc/dec ----------------------------------------------------------------------------------
    /// In-place ++/-- of local slot a; no result produced (statement context).
    inc_l,
    dec_l,
    /// a = old; slot = old +/- 1 (expression context).
    post_inc_l,
    post_dec_l,
    /// In-place on a(container arr)[b(key)] (statement context).
    inc_idx,
    dec_idx,
    /// a = old; container[key] = old +/- 1 (expression context).
    post_inc_idx,
    post_dec_idx,

    // -- calls / returns ------------------------------------------------------------------------------
    /// Call consts[c](regs[b .. b+a-1]); result written into regs[b].
    call,
    declare_func, // register program.funcs[consts[a]]
    return_val, // return regs[a]
    return_null,

    // -- foreach ----------------------------------------------------------------------------------------
    /// Snapshot regs[c] into hidden[a]; cursor into hidden[b].
    foreach_init,
    /// Bind next entry: key -> regs[a] (a == NO_REG when key not requested),
    /// value -> regs[b]. Packed arg + target come from following inline words:
    ///   inline1 = hidden_id << 1 | has_key
    ///   inline2 = loop-exit instruction index
    foreach_next,
    // -- isset on plain variables ---------------------------------------------------------------------------
    isset_local, // a(dst) = regs[b] !== null

    // -- control flow ------------------------------------------------------------------------------------------
    jmp, // a = target
    jmp_if_false, // if !truthy(regs[a]) jump b
    jmp_if_true, // if truthy(regs[a]) jump b
    /// Fused compare-and-branch: jump (inline word) when NOT(a SEL b).
    /// arg = sel<<26 | b_slot<<13 | a_slot.
    if_cmp_jmp_ll,
    /// arg = sel<<24 | slot; inline1 = const index; inline2 = target.
    if_cmp_jmp_lc,
};

/// Sentinel register index meaning "not present".
pub const no_reg: u32 = 0xFFFF_FFFF;

pub const CmpSel = enum(u8) { lt, gt, lte, gte, eq, neq };

/// One decoded instruction.
pub const Instr = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
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

pub fn packForeach(hidden: u32, has_key: bool) u32 {
    return (hidden << 1) | @intFromBool(has_key);
}

pub fn unpackForeachHidden(arg: u32) u32 {
    return arg >> 1;
}

pub fn unpackForeachHasKey(arg: u32) bool {
    return arg & 1 != 0;
}
