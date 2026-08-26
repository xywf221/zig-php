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
//! Scratch registers: rax/r9/r10/r11 (all volatile under Win64).

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

/// Compiled artifact: executable memory + invoke entry.
pub const Code = struct {
    mem: []u8,

    /// Execute the JITed body. Returns deopt resume ip or 0 on normal
    /// completion (result written to *out).
    pub fn run(self: *Code, regs: [*]Value, out: *Value, vm: *anyopaque) u64 {
        const FnTy = *const fn (regs: [*]Value, out: *Value, vm: *anyopaque) u64;
        const f: FnTy = @ptrCast(@alignCast(self.mem.ptr));
        return f(regs, out, vm);
    }
};

/// One-time Value-layout probe: payload word at offset 0, tag byte at
/// offset 8, tag ordinal < 256. JIT stays disabled when the compiler lays
/// values out differently than assumed by the emitted encodings.
pub fn probeLayout() bool {
    probe_ok = false;

    var v: Value = .{ .int_ = 0x1122334455667788 };
    const w: *const [2]u64 = @ptrCast(&v);
    if (!(w[0] == 0x1122334455667788)) return false; // payload first
    if ((w[1] & ~@as(u64, 0xFF)) != 0) return false; // tag fits one byte
    const t_int: u8 = @intCast(w[1]);

    var nv: Value = .null_;
    const nw: *const [2]u64 = @ptrCast(&nv);
    if ((nw[1] & ~@as(u64, 0xFF)) != 0) return false;
    const t_null: u8 = @intCast(nw[1]);
    if (t_int == t_null) return false;

    probe_ok = true;
    tag_int = t_int;
    tag_null = t_null;
    return true;
}

// ---------------------------------------------------------------------------
// x86-64 emitter
// ---------------------------------------------------------------------------

// Scratch register numbers (low 3 bits + REX extension flag).
const R = struct {
    const rax: u8 = 0;
    const rcx: u8 = 1;
    const rdx: u8 = 2;
    const r9: u8 = 9;
    const r10: u8 = 10;
    const r11: u8 = 11;
};

const Emitter = struct {
    buf: std.ArrayList(u8),
    arena: std.mem.Allocator,
    /// Jump fixups: patch rel32 at `at` to point at `label`.
    fixups: std.ArrayList(Fixup),
    /// Label -> emitted offset.
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

    // -- encoders -------------------------------------------------------------
    //
    // Register operands are full register numbers (0..15); helpers add REX
    // bits as needed. Memory operands use rcx as base with disp32.

    fn rex(r: u8, rm: u8) u8 {
        return 0x48 | (if (r >= 8) @as(u8, 4) else 0) | (if (rm >= 8) @as(u8, 1) else 0);
    }

    /// movabs r64, imm64
    fn movabs(self: *Emitter, reg: u8, imm: u64) !void {
        try self.byte(0x48 | (if (reg >= 8) @as(u8, 1) else 0));
        try self.byte(0xB8 + (reg & 7));
        try self.imm64(imm);
    }

    /// mov r64, [rcx + disp32]
    fn load(self: *Emitter, reg: u8, disp: i32) !void {
        try self.byte(rex(reg, 1));
        try self.byte(0x8B);
        try self.byte(0x80 | ((reg & 7) << 3) | 1); // mod=10 rm=001(rcx)
        try self.imm32(disp);
    }

    /// mov [rcx + disp32], r64
    fn store(self: *Emitter, disp: i32, reg: u8) !void {
        try self.byte(rex(reg, 1));
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

    /// cmp rax, r64
    fn cmp_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(0, reg));
        try self.byte(0x39);
        try self.byte(0xC0 | (reg & 7));
    }

    /// add rax, r64
    fn add_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(0, reg));
        try self.byte(0x01);
        try self.byte(0xC0 | (reg & 7));
    }

    /// sub rax, r64
    fn sub_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(0, reg));
        try self.byte(0x29);
        try self.byte(0xC0 | (reg & 7));
    }

    /// imul rax, r64
    fn imul_rax_r(self: *Emitter, reg: u8) !void {
        try self.byte(rex(0, reg));
        try self.bytes(&.{ 0x0F, 0xAF });
        try self.byte(0xC0 | (reg & 7));
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

    /// mov [rdx], r64
    fn store_indirect_rdx(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, 2));
        try self.byte(0x89);
        try self.byte(0x00 | ((reg & 7) << 3) | 2); // mod=00 rm=010(rdx)
    }

    /// mov [rdx + 8], r64
    fn store_indirect_rdx_8(self: *Emitter, reg: u8) !void {
        try self.byte(rex(reg, 2));
        try self.byte(0x89);
        try self.byte(0x40 | ((reg & 7) << 3) | 2); // mod=01 rm=010 disp8
        try self.byte(8);
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
    if (func.nlocals + func.ntemps > 64 or func.nhidden > 0 or func.by_ref_params.len > 0) {
        diag.reason = "register/iterator/ref limits";
        return null;
    }
    const code_items = func.chunk.code.items;
    if (code_items.len > max_jit_bytes) {
        diag.reason = "function too large";
        return null;
    }
    var e = Emitter.init(arena);

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
            .if_cmp_jmp_lc => {
                const sel: opcode.CmpSel = @enumFromInt(@as(u8, @intCast((ins.a >> 24) & 0x7)));
                switch (sel) {
                    .lt, .gt, .lte, .gte, .eq, .neq => {},
                }
                ip += 2; // two inline words follow
            },
            else => {
                diag.reason = "unsupported instruction";
                return null;
            },
        }
    }

    // Prologue: stash vm pointer (arrives in r8) into callee-saved r15.
    try e.bytes(&.{ 0x41, 0x54 }); // push r15
    try e.bytes(&.{ 0x4D, 0x89, 0xC7 }); // mov r15, r8

    // Pass 2: emit.
    ip = 0;
    while (ip < code_items.len) : (ip += 1) {
        e.bind(@intCast(ip));
        const ins = code_items[ip];
        switch (ins.op) {
            .ld_const => {
                const cv = func.chunk.consts.items[ins.b];
                try emit_store_int(&e, @intCast(ins.a), @bitCast(cv.int_), tag_int);
            },
            .mov => {
                try emit_load_guarded(&e, @intCast(ins.b), tag_int, @intCast(ip));
                try emit_store_rax(&e, @intCast(ins.a), tag_int);
            },
            .add, .sub, .mul => {
                try emit_load_guarded(&e, @intCast(ins.b), tag_int, @intCast(ip));
                try e.cmp_m_imm32(@intCast(@as(i64, ins.c) * 16 + 8), tag_int);
                try e.mov_eax_imm(@intCast(ip));
                try e.jcc_label(.ne, LABEL_DEOPT);
                try e.load(R.r9, @intCast(@as(i64, ins.c) * 16));
                switch (ins.op) {
                    .add => try e.add_rax_r(R.r9),
                    .sub => try e.sub_rax_r(R.r9),
                    .mul => try e.imul_rax_r(R.r9),
                    else => unreachable,
                }
                try e.mov_eax_imm(@intCast(ip));
                try e.jcc_label(.o, LABEL_DEOPT);
                try emit_store_rax(&e, @intCast(ins.a), tag_int);
            },
            .inc_l => {
                try emit_load_guarded(&e, @intCast(ins.a), tag_int, @intCast(ip));
                try e.movabs(R.r10, 1);
                try e.add_rax_r(R.r10);
                try e.mov_eax_imm(@intCast(ip));
                try e.jcc_label(.o, LABEL_DEOPT);
                try emit_store_rax(&e, @intCast(ins.a), tag_int);
            },
            .if_cmp_jmp_lc => {
                const sel: opcode.CmpSel = @enumFromInt(@as(u8, @intCast((ins.a >> 24) & 0x7)));
                const slot: u8 = @intCast(ins.a & 0xFFFFFF);
                const cv = func.chunk.consts.items[code_items[ip + 1].a];
                if (cv != .int_) {
                    diag.reason = "non-int compare constant";
                    return null;
                }
                const target: u32 = code_items[ip + 2].a;
                try emit_load_guarded(&e, slot, tag_int, @intCast(ip));
                const imm: i64 = @bitCast(cv.int_);
                if (imm >= std.math.minInt(i32) and imm <= std.math.maxInt(i32)) {
                    try e.bytes(&.{ 0x48, 0x81, 0xF8 }); // cmp rax, imm32
                    try e.imm32(@intCast(imm));
                } else {
                    try e.movabs(R.r10, @bitCast(cv.int_));
                    try e.cmp_rax_r(R.r10);
                }
                // Opcode semantic: if !(a SEL c) goto target.
                const taken: Emitter.Cond = switch (sel) {
                    .lt => .l,
                    .gt => .g,
                    .lte => .le,
                    .gte => .ge,
                    .eq => .e,
                    .neq => .ne,
                };
                try e.jcc_label(taken, target);
                ip += 2; // consumed inline words
            },
            .jmp => try e.jmp_label(ins.a),
            .return_val => {
                const slot: u8 = @intCast(ins.a);
                const d: i64 = @as(i64, slot) * 16;
                // Accept int or null only; anything else deoptimizes.
                try e.cmp_m_imm32(@intCast(d + 8), tag_int);
                try e.mov_eax_imm(@intCast(ip));
                try e.jcc_label(.e, LABEL_RET_COPY);
                try e.cmp_m_imm32(@intCast(d + 8), tag_null);
                try e.mov_eax_imm(@intCast(ip));
                try e.jcc_label(.e, LABEL_RET_COPY);
                try e.jmp_label(LABEL_DEOPT);

                e.bind(LABEL_RET_COPY);
                // Copy payload + full tag word into *out (rdx).
                try e.load(R.r10, @intCast(d)); // r10 = payload
                try e.load(R.r11, @intCast(d + 8)); // r11 = tag word
                try e.store_indirect_rdx(R.r10); // [rdx] = r10
                try e.store_indirect_rdx_8(R.r11); // [rdx+8] = r11
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

    // Normal exit: rax = 0.
    e.bind(LABEL_NORMAL);
    try e.xor_eax_eax();

    // Deopt exit: rax = resume bytecode ip (>0 signals deopt). Falls through
    // from NORMAL into this single `ret`.
    e.bind(LABEL_DEOPT);
    try e.ret();

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

fn emit_load_guarded(e: *Emitter, slot: u8, t_int: u8, ip: u32) !void {
    const d: i64 = @as(i64, slot) * 16;
    try e.cmp_m_imm32(@intCast(d + 8), t_int);
    try e.mov_eax_imm(@intCast(ip));
    try e.jcc_label(.ne, LABEL_DEOPT);
    try e.load(R.rax, @intCast(d)); // rax = payload
}

fn emit_store_int(e: *Emitter, slot: u8, payload: u64, tag: u8) !void {
    try e.movabs(R.rax, payload);
    try emit_store_rax(e, slot, tag);
}

fn emit_store_rax(e: *Emitter, slot: u8, tag: u8) !void {
    const d: i64 = @as(i64, slot) * 16;
    try e.store(@intCast(d), R.rax); // payload
    // tag qword (imm32 sign-extended writes zero high bytes)
    try e.bytes(&.{ 0x48, 0xC7, 0x81 });
    try e.imm32(@intCast(d + 8));
    try e.imm32(tag);
}

// -- executable memory -------------------------------------------------------

fn allocExec(len: usize) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        const win = std.os.windows;
        var base: win.PVOID = undefined;
        var size: usize = std.mem.alignForward(usize, len, 4096);
        const status = win.ntdll.NtAllocateVirtualMemory(
            win.GetCurrentProcess(),
            &base,
            0,
            &size,
            .{ .COMMIT = true, .RESERVE = true },
            .{ .EXECUTE_READWRITE = true },
        );
        if (status != .SUCCESS) return error.OutOfMemory;
        const p: [*]u8 = @ptrCast(base);
        return p[0..len];
    }
    const mem = try std.posix.mmap(null, std.mem.alignForward(usize, len, 4096), std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    return mem[0..len];
}
