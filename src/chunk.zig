//! Bytecode chunks: instruction stream, constant pool, line table, and
//! compiled function units.

const std = @import("std");
const opcode = @import("opcode.zig");
const valmod = @import("value.zig");

pub const Value = valmod.Value;

/// One register-machine instruction: opcode + up to three operands.
pub const Instr = struct {
    op: opcode.Op,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
};

pub const Chunk = struct {
    code: std.ArrayList(Instr) = .empty,
    lines: std.ArrayList(u32) = .empty,
    consts: std.ArrayList(Value) = .empty,
    /// Hash dedup for the high-volume constant kinds; float/bool/null are
    /// rare and fall back to a short linear scan.
    int_ix: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    str_ix: std.StringHashMapUnmanaged(u32) = .empty,
    /// Catch clause type lists, indexed by catch_match's c operand.
    catch_types: std.ArrayList([]const []const u8) = .empty,

    pub fn emit(self: *Chunk, a: std.mem.Allocator, ins: Instr, line: u32) !usize {
        try self.code.append(a, ins);
        try self.lines.append(a, line);
        return self.code.items.len - 1;
    }

    pub fn addConst(self: *Chunk, a: std.mem.Allocator, v: Value) !u32 {
        switch (v) {
            .int_ => |i| {
                if (self.int_ix.get(i)) |ix| return ix;
            },
            .str_ => |s| {
                if (self.str_ix.get(s.data)) |ix| return ix;
            },
            .null_, .bool_, .float_, .array_ => {
                for (self.consts.items, 0..) |c, i| {
                    if (try valmod.strictEq(c, v, a)) return @intCast(i);
                }
            },
            else => {},
        }
        const ix: u32 = @intCast(self.consts.items.len);
        try self.consts.append(a, v);
        switch (v) {
            .int_ => |i| try self.int_ix.put(a, i, ix),
            .str_ => |s| try self.str_ix.put(a, s.data, ix),
            else => {},
        }
        return ix;
    }
};

/// A compiled function (or the top-level script).
pub const Func = struct {
    name: []const u8,
    arity: usize,
    /// Parameter + local variable registers.
    nlocals: usize = 0,
    /// Expression temporaries above the locals.
    ntemps: usize = 0,
    /// Hidden foreach-iterator storage (snapshot + cursor pairs).
    nhidden: usize = 0,
    /// Constant default parameter values; null entry = required parameter.
    defaults: []?Value = &.{},
    /// Which parameters are `&by-reference`.
    by_ref_params: []const bool = &.{},
    /// Owning class for methods (self:: resolution); null otherwise.
    cls_name: ?[]const u8 = null,
    /// Baseline-JIT state (opaque *jit.Code when compiled).
    jit_code: ?*anyopaque = null,
    jit_runs: u8 = 0,
    jit_failed: bool = false,
    /// Static method (no instance binding).
    is_static: bool = false,
    chunk: Chunk = .{},
};
