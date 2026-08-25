//! Bytecode chunks: instruction stream, constant pool, line table, and
//! compiled function units.

const std = @import("std");
const opcode = @import("opcode.zig");
const valmod = @import("value.zig");

pub const Value = valmod.Value;

pub const Chunk = struct {
    code: std.ArrayList(opcode.Instr) = .empty,
    lines: std.ArrayList(u32) = .empty,
    consts: std.ArrayList(Value) = .empty,

    pub fn emit(self: *Chunk, a: std.mem.Allocator, op: opcode.Op, line: u32) !usize {
        return self.emitArg(a, op, 0, line);
    }

    pub fn emitArg(self: *Chunk, a: std.mem.Allocator, op: opcode.Op, arg: u32, line: u32) !usize {
        try self.code.append(a, .{ .op = op, .arg = arg });
        try self.lines.append(a, line);
        return self.code.items.len - 1;
    }

    pub fn addConst(self: *Chunk, a: std.mem.Allocator, v: Value) !u32 {
        // Deduplicate identical constants to keep pools small.
        for (self.consts.items, 0..) |c, i| {
            if (valmod.strictEq(c, v)) {
                // Only dedupe immutable scalars.
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
    /// Number of local variable slots (functions only; the top level uses
    /// the globals map).
    nlocals: usize = 0,
    /// Extra scratch slots (foreach iterators).
    ntemps: usize = 0,
    /// Default parameter values; `null` entry = required parameter.
    /// The minimal core supports constant defaults only.
    defaults: []?Value = &.{},
    chunk: Chunk = .{},
};
