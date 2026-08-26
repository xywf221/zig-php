//! Baseline JIT: translates simple straight-line integer bytecode functions
//! into x86-64 machine code (Windows x64 ABI), with type guards that
//! deoptimize back to the interpreter.
//!
//! Tier-1 supported ops (all-or-nothing per function):
//!   ld_const(int), mov, add/sub/mul(int, overflow -> deopt),
//!   inc_l, if_cmp_jmp_lc(int), jmp, return_val(int/null), return_null
//!
//! Any other instruction aborts compilation of that function.
//!
//! Generated-code contract (Win64):
//!   rcx = regs base ([*]Value)      — kept throughout
//!   rdx = out pointer (*Value)      — normal exit writes the result here
//!   r8  = vm pointer                — stashed in callee-saved r15
//!   returns rax: 0 = completed normally (result written to *out),
//!               >0 = deopt; rax = bytecode ip to resume interpretation.
//!
//! Frame layout inside generated code:
//!   [rsp]      = current bytecode ip (written by every guard)
//!   [rsp+8..]  = unused padding (keeps future helper calls aligned)
//!
//! Scratch registers: rax/r10/r11 (volatile under Win64).

const std = @import("std");
const valmod = @import("value.zig");
const chunk_mod = @import("chunk.zig");
const opcode = @import("opcode.zig");

const Value = valmod.Value;

pub const max_jit_bytes: usize = 4096;

pub var enabled: bool = true;
pub var probe_ok: bool = false;
var tag_int: u8 = 0;
var tag_null: u8 = 0;
/// Byte offset of payload / tag word within the 16-byte Value
/// (discovered by probeLayout — Zig may lay the union either way).
var payload_off: i32 = 0;
var tag_off: i32 = 8;

/// One-time Value-layout probe.
pub fn probeLayout() bool {
    probe_ok = false;

    var v: Value = .{ .int_ = 0x1122334455667788 };
    const w: *const [2]u64 = @ptrCast(&v);
    if (w[0] == 0x1122334455667788 and (w[1] & ~@as(u64, 0xFF)) == 0) {
        payload_off = 0;
        tag_off = 8;
        tag_int = @intCast(w[1]);
    } else if (w[1] == 0x1122334455667788 and (w[0] & ~@as(u64, 0xFF)) == 0) {
        payload_off = 8;
        tag_off = 0;
        tag_int = @intCast(w[0]);
    } else return false;

    var nv: Value = .null_;
    const nw: *const [2]u64 = @ptrCast(&nv);
    const ntag_word: usize = if (tag_off == 0) 0 else 1;
    if ((nw[ntag_word] & ~@as(u64, 0xFF)) != 0) return false;
    const t_null: u8 = @intCast(nw[ntag_word]);
    if (t_null == tag_int) return false;
    tag_null = t_null;

    probe_ok = true;
    return true;
}

/// Compiled artifact: executable memory + invoke entry.
pub const Code = struct {
    mem: []u8,

    /// Execute the JITed body. Returns deopt resume ip or 0 on normal
    /// completion (result written to *out).
    pub fn run(self: *Code, regs: [*]Value, out: *Value, vm: *anyopaque) u64 {
        const FnTy = *const fn (regs: [*]Value, out: *Value, vm: *anyopaque) callconv(.c) u64;
        const f: FnTy = @ptrCast(@alignCast(self.mem.ptr));
        return f(regs, out, vm);
    }
};

// ---------------------------------------------------------------------------
// x86-64 emitter
// ---------------------------------------------------------------------------

const R = struct {
    const rax: u8 = 0;
    const rcx: u8 = 1;
    const rdx: u8 = 2;
    const rsp: u8 = 4;
    const r9: u8 = 9;
    const r10: u8 = 10;
    const r11: u8 = 11;
};

const Emitter = struct {
    buf: std.ArrayList(u8),
    arena: std.mem.Allocator,
    fixups: std.ArrayList(Fixup),
    labels: std.AutoHashMapUnmanaged(u32, usize),

    const Fixup = struct { at: usize, label: u32 };

    fn init(arena: std.mem.Allocator) Emitter {
        return .{ .buf = .empty, .arena = arena, .fixups = .empty, .labels = .empty };
    }

    fn byte(self: *Emitter, b: u8) !void {
        try self.buf.append(self.arena, b);
    }

    fn bytes(self: *Emitter, bs: []const u8) !void {
        try self.buf.appendSlice(self.arena, bs);
    }

    fn imm32(self: *Emitter, v: i32) !void {
        try self.buf.appendSlice(self.arena, &std.mem.toBytes(v));
    }

    fn imm64(self: *Emitter, v: u64) !void {
        try self.buf.appendSlice(self.arena, &std.mem.toBytes(v));
    }

    fn here(self: *Emitter) usize {
        return self.buf.items.len;
    }

    fn rex(r: u8, rm: u8) u8 {
        return 0x48 | (if (r >= 8) @as(u8, 4) else 0) | (if (rm >= 8) @as(u8, 1) else 0);
    }

    /// movabs r64, imm64
    fn movabs_r(self: *Emitter, reg: u8, imm: u64) !void {
        try self.byte(0x48 | (if (reg >= 8) @as(u8, 1) else 0));
        try self.byte(0xB8 + (reg & 7));
        try self.imm64(imm);
    }

    /// mov r64, [rcx + disp32]
    fn load_rcx(self: *Emitter, reg: u8, disp: i32) !void {
        try self.byte(rex(reg, R.rcx));
        try self.byte(0x8B);
        try self.byte(0x80 | ((reg & 7) << 3) | 1);
        try self.imm32(disp);
    }

    /// mov [rcx + disp32], r64
    fn store_rcx(self: *Emitter, disp: i32, reg: u8) !void {
        try self.byte(rex(reg, R.rcx));
        try self.byte(0x89);
        try self.byte(0x80 | ((reg & 7) << 3) | 1);
        try self.imm32(disp);
    }

    /// cmp qword [rcx + disp32], imm32 (sign-extended)
    fn cmp_m_imm32(self: *Emitter, disp: i32, imm: i32) !void {
        try self.bytes(&.{ 0x48, 0x81, 0xB9 });
        try self.imm32(disp);
        try self.imm32(imm);
    }

    /// cmp byte [rcx + disp32], imm8 — used for tag checks because the
    /// interpreter only rewrites the low tag byte on assignment.
    fn cmp_m_byte_imm8(self: *Emitter, disp: i32, imm: u8) !void {
        try self.bytes(&.{ 0x80, 0xB9 });
        try self.imm32(disp);
        try self.byte(imm);
    }

    // Binary ops "rax OP r64".
    //
    // Encoding notes (this is where silent bugs live):
    //   * ADD/SUB/CMP (01/29/39 /r): DEST=r/m field, SRC=reg field.
    //     dest=rax -> rm=000 (no B); src=r64 -> reg bits + REX.R.
    //   * IMUL r64,r/m64 (0F AF /r): DEST=reg field, SRC=rm field.
    //     dest=rax -> reg=000; src=r64 -> rm bits + REX.B.

    /// cmp rax, r64
    fn cmp_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, R.rax)); // R for source reg
        try self.byte(0x39);
        try self.byte(0xC0 | ((reg & 7) << 3));
    }

    /// add rax, r64
    fn add_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, R.rax));
        try self.byte(0x01);
        try self.byte(0xC0 | ((reg & 7) << 3));
    }

    /// sub rax, r64
    fn sub_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, R.rax));
        try self.byte(0x29);
        try self.byte(0xC0 | ((reg & 7) << 3));
    }

    /// imul rax, r64
    fn imul_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(R.rax, reg)); // B for source rm
        try self.bytes(&.{ 0x0F, 0xAF });
        try self.byte(0xC0 | ((reg & 7) << 0) | ((R.rax & 7) << 3));
    }

    /// mov eax, imm32
    fn mov_eax_imm(self: *Emitter, v: i32) !void {
        try self.byte(0xB8);
        try self.imm32(v);
    }

    /// xor eax, eax
    fn xor_eax_eax(self: *Emitter) !void {
        try self.bytes(&.{ 0x31, 0xC0 });
    }

    /// mov dword [rsp], imm32 — record current bytecode ip for deopt
    fn set_ip(self: *Emitter, ip: u32) !void {
        try self.bytes(&.{ 0xC7, 0x04, 0x24 });
        try self.imm32(@intCast(ip));
    }

    const Cond = enum(u8) { o = 0, e = 4, ne = 5, l = 12, ge = 13, le = 14, g = 15 };

    fn jcc_label(self: *Emitter, cond: Cond, label: u32) !void {
        try self.bytes(&.{ 0x0F, 0x80 + @intFromEnum(cond) });
        const at = self.here();
        try self.imm32(0);
        try self.fixups.append(self.arena, .{ .at = at, .label = label });
    }

    fn jmp_label(self: *Emitter, label: u32) !void {
        try self.byte(0xE9);
        const at = self.here();
        try self.imm32(0);
        try self.fixups.append(self.arena, .{ .at = at, .label = label });
    }

    fn bind(self: *Emitter, label: u32) void {
        self.labels.put(self.arena, label, self.here()) catch {};
    }

    /// Shared epilogue: restore stack + r15, return.
    fn epilogue(self: *Emitter) !void {
        try self.bytes(&.{ 0x48, 0x83, 0xC4, 0x18 }); // add rsp, 24
        try self.bytes(&.{ 0x41, 0x5F }); // pop r15
        try self.ret();
    }

    /// mov [rdx], r64
    fn store_indirect_rdx(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, R.rdx));
        try self.byte(0x89);
        try self.byte(0x00 | ((reg & 7) << 3) | 2); // mod=00 rm=010(rdx)
    }

    /// mov [rdx + 8], r64
    fn store_indirect_rdx_8(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, R.rdx));
        try self.byte(0x89);
        try self.byte(0x40 | ((reg & 7) << 3) | 2); // mod=01 rm=010 disp8
        try self.byte(8);
    }

    fn ret(self: *Emitter) !void {
        try self.byte(0xC3);
    }
};

// Pseudo-labels (reserved ids beyond any real bytecode ip).
const LABEL_DEOPT: u32 = std.math.maxInt(u32) - 1;
const LABEL_NORMAL: u32 = std.math.maxInt(u32) - 2;
const LABEL_RET_COPY: u32 = std.math.maxInt(u32) - 3;

// ---------------------------------------------------------------------------
// Compiler
// ---------------------------------------------------------------------------

pub const Diag = struct { reason: []const u8 = "" };

pub fn compile(
    arena: std.mem.Allocator,
    func: *chunk_mod.Func,
    diag: *Diag,
) !?*Code {
    if (!enabled or !probe_ok) return null;
    if (func.nlocals + func.ntemps > 64 or func.nhidden > 0) {
        diag.reason = "register/iterator limits";
        return null;
    }
    for (func.by_ref_params) |br| {
        if (br) {
            diag.reason = "by-reference parameters";
            return null;
        }
    }
    const code_items = func.chunk.code.items;
    if (code_items.len > max_jit_bytes) {
        diag.reason = "function too large";
        return null;
    }

    var e = Emitter.init(arena);

    // Prologue: stash vm pointer (arrives in r8) into callee-saved r15 and
    // reserve [rsp] for the deopt resume ip.
    try e.bytes(&.{ 0x41, 0x54 }); // push r15
    try e.bytes(&.{ 0x48, 0x83, 0xEC, 0x18 }); // sub rsp, 24

    // Pass 1: validate every instruction (skipping inline data words).
    var ip: usize = 0;
    while (ip < code_items.len) : (ip += 1) {
        const ins = code_items[ip];
        switch (ins.op) {
            .ld_const => if (func.chunk.consts.items[ins.b] != .int_) {
                diag.reason = "non-int constant";
                return null;
            },
            .mov, .add, .sub, .mul, .inc_l, .jmp, .return_val, .return_null, .inline_arg => {},
            .if_cmp_jmp_lc, .if_cmp_jmp_ll => {
                const sel: opcode.CmpSel = @enumFromInt(@as(u8, @intCast((ins.a >> 24) & 0x7)));
                switch (sel) {
                    .lt, .gt, .lte, .gte, .eq, .neq => {},
                }
                ip += 1; // one inline word (target)
            },
            else => {
                diag.reason = std.fmt.allocPrint(arena, "unsupported {s} at ip {d}", .{ @tagName(ins.op), ip }) catch "unsupported";
                return null;
            },
        }
    }

    // Pass 2: emit. Every bytecode ip is bound as a label (jump targets).
    ip = 0;
    while (ip < code_items.len) : (ip += 1) {
        e.bind(@intCast(ip));
        const ins = code_items[ip];
        switch (ins.op) {
            .ld_const => {
                const cv = func.chunk.consts.items[ins.b];
                try emit_set_ip(&e, @intCast(ip));
                try emit_store_int(&e, @intCast(ins.a), @bitCast(cv.int_), tag_int);
            },
            .mov => {
                try emit_set_ip(&e, @intCast(ip));
                try e.cmp_m_byte_imm8(@intCast(@as(i64, ins.b) * 16 + tag_off), tag_int);
                try e.jcc_label(.ne, LABEL_DEOPT);
                try e.load_rcx(R.rax, @intCast(@as(i64, ins.b) * 16 + payload_off));
                try emit_store_rax(&e, @intCast(ins.a), tag_int);
            },
            .add, .sub, .mul => {
                try emit_set_ip(&e, @intCast(ip)); // covers BOTH guards
                try e.cmp_m_byte_imm8(@intCast(@as(i64, ins.b) * 16 + tag_off), tag_int);
                try e.jcc_label(.ne, LABEL_DEOPT);
                try e.load_rcx(R.rax, @intCast(@as(i64, ins.b) * 16 + payload_off));
                try e.cmp_m_byte_imm8(@intCast(@as(i64, ins.c) * 16 + tag_off), tag_int);
                try e.jcc_label(.ne, LABEL_DEOPT);
                try e.load_rcx(R.r9, @intCast(@as(i64, ins.c) * 16 + payload_off));
                switch (ins.op) {
                    .add => try e.add_rax_r(R.r9),
                    .sub => try e.sub_rax_r(R.r9),
                    .mul => try e.imul_rax_r(R.r9),
                    else => unreachable,
                }
                try e.jcc_label(.o, LABEL_DEOPT); // int overflow -> interpreter promotes to float
                try emit_store_rax(&e, @intCast(ins.a), tag_int);
            },
            .inc_l => {
                try emit_set_ip(&e, @intCast(ip));
                try e.cmp_m_byte_imm8(@intCast(@as(i64, ins.a) * 16 + tag_off), tag_int);
                try e.jcc_label(.ne, LABEL_DEOPT);
                try e.load_rcx(R.rax, @intCast(@as(i64, ins.a) * 16 + payload_off));
                try e.movabs_r(R.r10, 1);
                try e.add_rax_r(R.r10);
                try e.jcc_label(.o, LABEL_DEOPT);
                try emit_store_rax(&e, @intCast(ins.a), tag_int);
            },
            .if_cmp_jmp_lc, .if_cmp_jmp_ll => {
                const sel: opcode.CmpSel = @enumFromInt(@as(u8, @intCast((ins.a >> 24) & 0x7)));
                try emit_set_ip(&e, @intCast(ip));
                var a_slot: u8 = undefined;
                var c_const: ?i64 = null;
                var c_slot: u8 = undefined;
                if (ins.op == .if_cmp_jmp_lc) {
                    a_slot = @intCast(ins.a & 0xFFFFFF);
                    const cv = func.chunk.consts.items[code_items[ip + 1].a];
                    if (cv != .int_) {
                        diag.reason = "non-int compare constant";
                        return null;
                    }
                    c_const = @bitCast(cv.int_);
                } else {
                    // arg = sel<<26 | b_slot<<13 | a_slot
                    a_slot = @intCast(ins.a & 0x1FFF);
                    c_slot = @intCast((ins.a >> 13) & 0x1FFF);
                }
                const target: u32 = if (ins.op == .if_cmp_jmp_lc)
                    code_items[ip + 2].a
                else
                    code_items[ip + 1].a;

                try e.cmp_m_byte_imm8(@intCast(@as(i64, a_slot) * 16 + tag_off), tag_int);
                try e.jcc_label(.ne, LABEL_DEOPT);
                try e.load_rcx(R.rax, @intCast(@as(i64, a_slot) * 16 + payload_off));
                if (c_const) |imm| {
                    if (imm >= std.math.minInt(i32) and imm <= std.math.maxInt(i32)) {
                        try e.bytes(&.{ 0x48, 0x81, 0xF8 }); // cmp rax, imm32
                        try e.imm32(@intCast(imm));
                    } else {
                        try e.movabs_r(R.r10, @bitCast(imm));
                        try e.cmp_rax_r(R.r10);
                    }
                } else {
                    try e.cmp_m_byte_imm8(@intCast(@as(i64, c_slot) * 16 + tag_off), tag_int);
                    try e.jcc_label(.ne, LABEL_DEOPT);
                    try e.load_rcx(R.r10, @intCast(@as(i64, c_slot) * 16 + payload_off));
                    try e.cmp_rax_r(R.r10);
                }
                // Opcode semantic: JUMP TO TARGET when !(a SEL c).
                // Machine branch therefore uses the INVERTED condition:
                // falling through means the loop condition held.
                const inv: Emitter.Cond = switch (sel) {
                    .lt => .ge,
                    .gt => .le,
                    .lte => .g,
                    .gte => .l,
                    .eq => .ne,
                    .neq => .e,
                };
                try e.jcc_label(inv, target);
                if (ins.op == .if_cmp_jmp_lc) ip += 2; // consumed inline words
            },
            .jmp => try e.jmp_label(ins.a),
            .return_val => {
                const slot: u8 = @intCast(ins.a);
                const base: i64 = @as(i64, slot) * 16;
                try emit_set_ip(&e, @intCast(ip));
                // Accept int or null only; anything else deoptimizes.
                try e.cmp_m_byte_imm8(@intCast(base + tag_off), tag_int);
                try e.jcc_label(.e, LABEL_RET_COPY);
                try e.cmp_m_imm32(@intCast(base + tag_off), tag_null);
                try e.jcc_label(.e, LABEL_RET_COPY);
                try e.jmp_label(LABEL_DEOPT);

                e.bind(LABEL_RET_COPY);
                // Copy payload + full tag word into *out (rdx).
                try e.load_rcx(R.r10, @intCast(base + payload_off));
                try e.load_rcx(R.r11, @intCast(base + tag_off));
                try e.store_indirect_rdx(R.r10); // [rdx] = payload
                try e.store_indirect_rdx_8(R.r11); // [rdx+8] = tag word
                try e.jmp_label(LABEL_NORMAL);
            },
            .return_null => {
                try e.xor_eax_eax();
                try e.store_indirect_rdx(R.rax); // [rdx] = 0
                try e.bytes(&.{ 0x48, 0xC7, 0x42, 0x08 }); // mov qword [rdx+8], imm32
                try e.imm32(tag_null);
                try e.jmp_label(LABEL_NORMAL);
            },
            .inline_arg => {}, // data word
            else => unreachable, // filtered by pass 1
        }
    }

    // Deopt exit: rax = saved resume ip (>0 signals deopt).
    // NOTE: must come BEFORE the normal exit — the normal path previously
    // fell through into this block, turning every completion into a deopt.
    e.bind(LABEL_DEOPT);
    try e.bytes(&.{ 0x8B, 0x04, 0x24 }); // mov eax, [rsp] (32-bit: zero-extends)
    try e.epilogue();

    // Normal exit: rax = 0.
    e.bind(LABEL_NORMAL);
    try e.xor_eax_eax();
    try e.epilogue();

    // Patch fixups now that all labels are bound.
    for (e.fixups.items) |fx| {
        const target = e.labels.get(fx.label) orelse {
            diag.reason = "unbound jump target";
            return null;
        };
        const rel: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(fx.at + 4)));
        std.mem.writeInt(i32, e.buf.items[fx.at..][0..4], rel, .little);
    }

    const mem = try allocExec(e.buf.items.len);
    @memcpy(mem, e.buf.items);
    const code = try arena.create(Code);
    code.* = .{ .mem = mem };
    return code;
}

// -- guarded load/store helpers ---------------------------------------------

/// Record resume ip, then guarded-load an int into rax.
fn emit_set_ip(e: *Emitter, ip: u32) !void {
    try e.bytes(&.{ 0xC7, 0x04, 0x24 }); // mov dword [rsp], imm32
    try e.imm32(@intCast(ip));
}

fn emit_load_guarded(e: *Emitter, slot: u8, t_int: u8, ip: u32) !void {
    try emit_set_ip(e, ip);
    try e.cmp_m_imm32(@intCast(@as(i64, slot) * 16 + tag_off), t_int);
    try e.jcc_label(.ne, LABEL_DEOPT);
    try e.load_rcx(R.rax, @intCast(@as(i64, slot) * 16 + payload_off)); // rax = payload
}

fn emit_store_int(e: *Emitter, slot: u8, payload: u64, tag: u8) !void {
    try e.movabs_r(R.rax, payload);
    try emit_store_rax(e, slot, tag);
}

fn emit_store_rax(e: *Emitter, slot: u8, tag: u8) !void {
    const base: i64 = @as(i64, slot) * 16;
    try e.store_rcx(@intCast(base + payload_off), R.rax); // payload
    // tag word (imm32 sign-extended writes zero high bytes)
    try e.bytes(&.{ 0x48, 0xC7, 0x81 });
    try e.imm32(@intCast(base + tag_off));
    try e.imm32(tag);
}

// -- executable memory -------------------------------------------------------

fn allocExec(len: usize) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        const win = std.os.windows;
        // BaseAddress is IN/OUT: pass NULL (zero) so the system picks the
        // address; the chosen base is written back into this word.
        var base_word: usize = 0;
        var size: usize = std.mem.alignForward(usize, len, 4096);
        const status = win.ntdll.NtAllocateVirtualMemory(
            win.GetCurrentProcess(),
            @ptrCast(&base_word),
            0,
            &size,
            .{ .COMMIT = true, .RESERVE = true },
            .{ .EXECUTE_READWRITE = true },
        );
        if (status != .SUCCESS) return error.OutOfMemory;
        const p: [*]u8 = @ptrFromInt(base_word);
        return p[0..len];
    }
    const mem = try std.posix.mmap(null, std.mem.alignForward(usize, len, 4096), std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    return mem[0..len];
}
