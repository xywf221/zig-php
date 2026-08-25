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

    pub fn emit(self: *Chunk, a: std.mem.Allocator, ins: Instr, line: u32) !usize {
        try self.code.append(a, ins);
        try self.lines.append(a, line);
        return self.code.items.len - 1;
    }

    pub fn addConst(self: *Chunk, a: std.mem.Allocator, v: Value) !u32 {
        // Deduplicate identical immutable constants.
        for (self.consts.items, 0..) |c, i| {
            if (valmod.strictEq(c, v)) {
                switch (v) {
                    .null_, .bool_, .int_, .float_, .str_ => return @intCast(i),
                    .array_ => {},
                }
            }
        }
        try self.consts.append(a, v);
        return @intCast(self.consts.items.len - 1);
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
    chunk: Chunk = .{},
};
