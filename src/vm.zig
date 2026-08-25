//! Stack-based bytecode VM for zphp.
//!
//! Execution model (QuickJS-flavored):
//!   * one shared operand stack; each frame owns a base offset,
//!   * per-frame local slot arrays + foreach temp slots,
//!   * flat dispatch loop over `Op` — no AST re-walking, no pointer
//!     chasing through node unions on hot paths.
//!
//! Frame-pointer discipline: `runFrame` re-derives the current frame
//! pointer after every operation that can mutate the frame list (call /
//! return); all other opcodes cannot touch it, so hot paths keep a stable
//! pointer. Instruction pointers are written back before those mutations.

const std = @import("std");
const valmod = @import("value.zig");
const opcode = @import("opcode.zig");
const chunkmod = @import("chunk.zig");
const builtins = @import("builtins.zig");
const compiler_mod = @import("compiler.zig");

const Op = opcode.Op;
const Value = valmod.Value;
const Func = chunkmod.Func;

pub const Error = error{
    Fatal,
    OutOfMemory,
} || std.Io.Writer.Error;

pub const MAX_CALL_DEPTH: u32 = 512;

pub const Vm = struct {
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    program: *compiler_mod.Program,
    globals: std.StringHashMapUnmanaged(Value) = .empty,
    /// Functions registered so far (top-level set is preloaded; conditional
    /// declarations register when execution reaches them).
    funcs: std.StringHashMapUnmanaged(*Func) = .empty,

    stack: std.ArrayList(Value) = .empty,
    frames: std.ArrayList(Frame) = .empty,

    // Diagnostics.
    msg: []const u8 = "",
    line: u32 = 0,

    const Frame = struct {
        func: *Func,
        ip: usize,
        locals: []Value,
        temps: []Value,
        stack_base: usize,
    };

    pub fn init(arena: std.mem.Allocator, out: *std.Io.Writer, program: *compiler_mod.Program) Vm {
        var vm = Vm{ .arena = arena, .out = out, .program = program };
        // Preload all compiled declarations (PHP hoists unconditional
        // top-level functions; conditional ones also register via
        // declare_func when execution reaches them).
        var it = program.funcs.iterator();
        while (it.next()) |entry| {
            vm.funcs.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch {};
        }
        return vm;
    }

    pub fn fatalF(self: *Vm, line: u32, comptime fmt: []const u8, args: anytype) Error {
        self.msg = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        self.line = line;
        return error.Fatal;
    }

    /// Execute the program (main function) to completion.
    pub fn run(self: *Vm) Error!void {
        const mainf = self.program.main_func;
        const main_locals = try self.arena.alloc(Value, mainf.nlocals);
        for (main_locals) |*l| l.* = .null_;
        try self.frames.append(self.arena, .{
            .func = mainf,
            .ip = 0,
            .locals = main_locals,
            .temps = try self.arena.alloc(Value, mainf.ntemps),
            .stack_base = 0,
        });
        try self.runFrame();
    }

    fn push(self: *Vm, v: Value) Error!void {
        try self.stack.append(self.arena, v);
    }

    fn pop(self: *Vm) Value {
        return self.stack.pop().?;
    }

    fn peek(self: *Vm) Value {
        return self.stack.items[self.stack.items.len - 1];
    }

    /// Run frames until the bottom frame returns.
    fn runFrame(self: *Vm) Error!void {
        while (self.frames.items.len > 0) {
            try self.dispatch();
        }
    }

    /// Run the top frame until it returns or calls deeper.
    fn dispatch(self: *Vm) Error!void {
        const fi = self.frames.items.len - 1;
        var f = &self.frames.items[fi];
        const code = f.func.chunk.code.items;
        const consts = f.func.chunk.consts.items;
        const lines = f.func.chunk.lines.items;

        while (true) {
            if (f.ip >= code.len) {
                // Implicit end of function body.
                try self.popFrame(.null_);
                return;
            }
            const instr = code[f.ip];
            const line = lines[f.ip];
            f.ip += 1;

            switch (instr.op) {
                .pop => _ = self.pop(),
                .dup => try self.push(self.peek()),
                .dup2 => {
                    const b = self.stack.items[self.stack.items.len - 1];
                    const a = self.stack.items[self.stack.items.len - 2];
                    try self.push(a);
                    try self.push(b);
                },

                .const_k => try self.push(consts[instr.arg]),
                .null_ => try self.push(.null_),
                .true_ => try self.push(.{ .bool_ = true }),
                .false_ => try self.push(.{ .bool_ = false }),
                .inline_arg => {}, // data word

                .get_local => try self.push(f.locals[instr.arg]),
                .set_local => f.locals[instr.arg] = self.pop(),
                .get_global => try self.push(self.globals.get(consts[instr.arg].str_) orelse .null_),
                .set_global => try self.globals.put(self.arena, consts[instr.arg].str_, self.pop()),

                .declare_func => {
                    const f2 = self.program.funcs.get(consts[instr.arg].str_) orelse
                        return self.fatalF(line, "internal: uncompiled function", .{});
                    try self.funcs.put(self.arena, consts[instr.arg].str_, f2);
                },

                .get_container_local => {
                    switch (f.locals[instr.arg]) {
                        .array_ => |arr| try self.push(.{ .array_ = arr }),
                        .null_ => {
                            const arr = try Value.Array.create(self.arena);
                            f.locals[instr.arg] = .{ .array_ = arr };
                            try self.push(.{ .array_ = arr });
                        },
                        else => |v| return self.fatalF(line, "cannot use a {s} value as an array", .{v.typeName()}),
                    }
                },
                .get_container_global => {
                    const name = consts[instr.arg].str_;
                    if (self.globals.get(name)) |v| {
                        switch (v) {
                            .array_ => |arr| try self.push(.{ .array_ = arr }),
                            .null_ => {
                                const arr = try Value.Array.create(self.arena);
                                try self.globals.put(self.arena, name, .{ .array_ = arr });
                                try self.push(.{ .array_ = arr });
                            },
                            else => |vv| return self.fatalF(line, "cannot use a {s} value as an array", .{vv.typeName()}),
                        }
                    } else {
                        const arr = try Value.Array.create(self.arena);
                        try self.globals.put(self.arena, name, .{ .array_ = arr });
                        try self.push(.{ .array_ = arr });
                    }
                },
                .subcontainer => {
                    const key = try valmod.makeKey(self.pop(), self.arena);
                    const parent_val = self.pop();
                    if (parent_val != .array_) {
                        return self.fatalF(line, "cannot use a {s} value as an array", .{parent_val.typeName()});
                    }
                    const parent = parent_val.array_;
                    const existing: ?*Value.Array = blk: {
                        const v = parent.get(key) orelse break :blk null;
                        break :blk switch (v) {
                            .array_ => |arr| arr,
                            .null_ => null,
                            else => |vv| return self.fatalF(line, "cannot use a {s} value as an array", .{vv.typeName()}),
                        };
                    };
                    const sub = existing orelse blk: {
                        const arr = try Value.Array.create(self.arena);
                        try parent.set(self.arena, key, .{ .array_ = arr });
                        break :blk arr;
                    };
                    try self.push(.{ .array_ = sub });
                },

                .new_array => {
                    const n = instr.arg;
                    const arr = try Value.Array.create(self.arena);
                    const base = self.stack.items.len - n;
                    for (self.stack.items[base..]) |v| {
                        try arr.appendVal(self.arena, v);
                    }
                    self.stack.shrinkRetainingCapacity(base);
                    try self.push(.{ .array_ = arr });
                },
                .new_array_kv => {
                    const pairs = instr.arg;
                    const arr = try Value.Array.create(self.arena);
                    const base = self.stack.items.len - 2 * pairs;
                    var i: usize = base;
                    while (i < self.stack.items.len) : (i += 2) {
                        const kv = try valmod.makeKey(self.stack.items[i], self.arena);
                        try arr.set(self.arena, kv, self.stack.items[i + 1]);
                    }
                    self.stack.shrinkRetainingCapacity(base);
                    try self.push(.{ .array_ = arr });
                },
                .get_index => {
                    const key_v = self.pop();
                    const container = self.pop();
                    try self.push(try self.indexRead(container, key_v, line));
                },
                .set_index => {
                    const v = self.pop();
                    const key_v = self.pop();
                    const container = self.pop();
                    if (container != .array_) {
                        return self.fatalF(line, "cannot use a {s} value as an array", .{container.typeName()});
                    }
                    if (key_v == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                    try container.array_.set(self.arena, try valmod.makeKey(key_v, self.arena), v);
                    try self.push(v); // assignment expression value
                },
                .append_index => {
                    const v = self.pop();
                    const container = self.pop();
                    if (container != .array_) {
                        return self.fatalF(line, "cannot use a {s} value as an array", .{container.typeName()});
                    }
                    try container.array_.appendVal(self.arena, v);
                    try self.push(v);
                },
                .isset_index => {
                    const key_v = self.pop();
                    const container = self.pop();
                    const result: bool = switch (container) {
                        .null_ => false,
                        .array_ => |arr| blk: {
                            if (key_v == .array_) break :blk false;
                            break :blk arr.get(try valmod.makeKey(key_v, self.arena)) != null;
                        },
                        .str_ => |st| key_v == .int_ and key_v.int_ >= 0 and key_v.int_ < st.len,
                        else => false,
                    };
                    try self.push(.{ .bool_ = result });
                },

                .add => try self.binOp(.add, line),
                .sub => try self.binOp(.sub, line),
                .mul => try self.binOp(.mul, line),
                .div => try self.binOp(.div, line),
                .mod => try self.binOp(.mod, line),
                .pow => try self.binOp(.pow, line),
                .concat => {
                    const r = try valmod.toString(self.pop(), self.arena);
                    const l = try valmod.toString(self.pop(), self.arena);
                    try self.push(.{ .str_ = try std.fmt.allocPrint(self.arena, "{s}{s}", .{ l, r })});
                },

                .bit_and => try self.intBin(.bit_and, line),
                .bit_or => try self.intBin(.bit_or, line),
                .bit_xor => try self.intBin(.bit_xor, line),
                .shl => try self.intBin(.shl, line),
                .shr => try self.intBin(.shr, line),
                .bit_not => {
                    const v = self.peek();
                    if (v == .float_) return self.fatalF(line, "unsupported operand type for ~", .{});
                    const n = valmod.toNumber(self.pop());
                    try self.push(.{ .int_ = ~n.int });
                },

                .eq => try self.cmpOp(.eq, line),
                .neq => try self.cmpOp(.neq, line),
                .identical => {
                    const r = self.pop();
                    const l = self.pop();
                    try self.push(.{ .bool_ = valmod.strictEq(l, r) });
                },
                .not_identical => {
                    const r = self.pop();
                    const l = self.pop();
                    try self.push(.{ .bool_ = !valmod.strictEq(l, r) });
                },
                .lt => try self.cmpOp(.lt, line),
                .gt => try self.cmpOp(.gt, line),
                .lte => try self.cmpOp(.lte, line),
                .gte => try self.cmpOp(.gte, line),
                .spaceship => {
                    const r = self.pop();
                    const l = self.pop();
                    const ord = try valmod.looseCmp(l, r, self.arena);
                    try self.push(.{ .int_ = switch (ord) {
                        .lt => @as(i64, -1),
                        .eq => 0,
                        .gt => 1,
                    } });
                },

                .neg => {
                    const n = valmod.toNumber(self.pop());
                    try self.push(switch (n) {
                        .int => |i| Value{ .int_ = -i },
                        .float => |fl| Value{ .float_ = -fl },
                    });
                },
                .pos => {
                    const n = valmod.toNumber(self.pop());
                    try self.push(switch (n) {
                        .int => |i| Value{ .int_ = i },
                        .float => |fl| Value{ .float_ = fl },
                    });
                },
                .not => {
                    const v = self.pop();
                    try self.push(.{ .bool_ = !v.truthy() });
                },
                .to_bool => {
                    const v = self.pop();
                    try self.push(.{ .bool_ = v.truthy() });
                },
                .is_not_null => {
                    const v = self.pop();
                    try self.push(.{ .bool_ = v != .null_ });
                },

                .jmp => {
                    f.ip = instr.arg;
                    continue;
                },
                .jmp_if_false => {
                    if (!self.pop().truthy()) {
                        f.ip = instr.arg;
                        continue;
                    }
                },
                .jmp_if_true => {
                    if (self.pop().truthy()) {
                        f.ip = instr.arg;
                        continue;
                    }
                },
                .jmp_if_false_keep => {
                    if (!self.peek().truthy()) {
                        self.stack.items[self.stack.items.len - 1] = .{ .bool_ = false };
                        f.ip = instr.arg;
                        continue;
                    }
                },
                .jmp_if_true_keep => {
                    if (self.peek().truthy()) {
                        self.stack.items[self.stack.items.len - 1] = .{ .bool_ = true };
                        f.ip = instr.arg;
                        continue;
                    }
                },
                .jmp_if_true_raw => {
                    if (self.peek().truthy()) {
                        f.ip = instr.arg;
                        continue;
                    }
                },
                .coalesce => {
                    const rhs = self.pop();
                    const lhs = self.pop();
                    try self.push(if (lhs != .null_) lhs else rhs);
                },

                .strconcat => {
                    const n = instr.arg;
                    const base = self.stack.items.len - n;
                    var buf: std.ArrayList(u8) = .empty;
                    for (self.stack.items[base..]) |v| {
                        try buf.appendSlice(self.arena, try valmod.toString(v, self.arena));
                    }
                    self.stack.shrinkRetainingCapacity(base);
                    try self.push(.{ .str_ = buf.items });
                },
                .echo => {
                    const n = instr.arg;
                    const base = self.stack.items.len - n;
                    for (self.stack.items[base..]) |v| {
                        try self.out.writeAll(try valmod.toString(v, self.arena));
                    }
                    self.stack.shrinkRetainingCapacity(base);
                },

                .pre_inc_local => try self.incLocalSlot(f, instr.arg, true, true),
                .post_inc_local => try self.incLocalSlot(f, instr.arg, true, false),
                .pre_dec_local => try self.incLocalSlot(f, instr.arg, false, true),
                .post_dec_local => try self.incLocalSlot(f, instr.arg, false, false),
                .pre_inc_global => try self.incGlobal(consts[instr.arg].str_, true, true),
                .post_inc_global => try self.incGlobal(consts[instr.arg].str_, true, false),
                .pre_dec_global => try self.incGlobal(consts[instr.arg].str_, false, true),
                .post_dec_global => try self.incGlobal(consts[instr.arg].str_, false, false),
                .pre_inc_index => try self.incIndex(true, true, line),
                .post_inc_index => try self.incIndex(true, false, line),
                .pre_dec_index => try self.incIndex(false, true, line),
                .post_dec_index => try self.incIndex(false, false, line),

                .call => {
                    const name_const = opcode.unpackCallName(instr.arg);
                    const argc = opcode.unpackCallArgc(instr.arg);
                    try self.doCall(consts[name_const].str_, argc, line);
                    return; // re-derive frame in dispatch()
                },
                .return_val => {
                    const result = self.pop();
                    try self.popFrame(result);
                    return; // re-derive / unwind in runFrame
                },
                .return_null => {
                    try self.popFrame(.null_);
                    return;
                },

                .foreach_init => try self.foreachInit(instr.arg, line),
                .foreach_next => {
                    // Loop-exit target lives in the following inline word.
                    const end_target = code[f.ip].arg; // already points past the inline word
                    if (try self.foreachAdvance(instr.arg)) {
                        f.ip = end_target;
                        continue;
                    }
                    f.ip += 1; // skip inline word on fallthrough
                },

                .isset_local => try self.push(.{ .bool_ = f.locals[instr.arg] != .null_ }),
                .isset_global => {
                    const v = self.globals.get(consts[instr.arg].str_) orelse .null_;
                    try self.push(.{ .bool_ = v != .null_ });
                },
            }
        }
    }

    // -- helpers -------------------------------------------------------------------

    const ArithKind = enum { add, sub, mul, div, mod, pow };
    const BitKind = enum { bit_and, bit_or, bit_xor, shl, shr };

    fn binOp(self: *Vm, kind: ArithKind, line: u32) Error!void {
        const r = self.pop();
        const l = self.pop();

        if (l == .array_ or r == .array_) {
            return self.fatalF(line, "unsupported operand types: {s} and {s}", .{ l.typeName(), r.typeName() });
        }
        const ln = valmod.toNumber(l);
        const rn = valmod.toNumber(r);

        // Integer fast path.
        if (ln == .int and rn == .int) {
            const a = ln.int;
            const b = rn.int;
            switch (kind) {
                .add => {
                    const res = @addWithOverflow(a, b);
                    if (res[1] == 0) return self.push(.{ .int_ = res[0] });
                    return self.push(.{ .float_ = @as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b)) });
                },
                .sub => {
                    const res = @subWithOverflow(a, b);
                    if (res[1] == 0) return self.push(.{ .int_ = res[0] });
                    return self.push(.{ .float_ = @as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b)) });
                },
                .mul => {
                    const res = @mulWithOverflow(a, b);
                    if (res[1] == 0) return self.push(.{ .int_ = res[0] });
                    return self.push(.{ .float_ = @as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b)) });
                },
                .div => {
                    if (b == 0) return self.fatalF(line, "Division by zero", .{});
                    if (@rem(a, b) == 0) return self.push(.{ .int_ = @divTrunc(a, b) });
                    return self.push(.{ .float_ = @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b)) });
                },
                .mod => {
                    if (b == 0) return self.fatalF(line, "Modulo by zero", .{});
                    return self.push(.{ .int_ = @rem(a, b) });
                },
                .pow => {
                    if (b >= 0 and b <= 62) {
                        var result: i64 = 1;
                        var i: i64 = 0;
                        while (i < b) : (i += 1) result *|= a;
                        return self.push(.{ .int_ = result });
                    }
                    return self.push(.{ .float_ = std.math.pow(f64, @floatFromInt(a), @floatFromInt(b)) });
                },
            }
        }

        // Float path.
        const a = ln.toFloat();
        const b = rn.toFloat();
        switch (kind) {
            .add => try self.push(.{ .float_ = a + b }),
            .sub => try self.push(.{ .float_ = a - b }),
            .mul => try self.push(.{ .float_ = a * b }),
            .div => {
                if (b == 0.0) return self.fatalF(line, "Division by zero", .{});
                try self.push(.{ .float_ = a / b });
            },
            .mod => {
                if (b == 0.0) return self.fatalF(line, "Modulo by zero", .{});
                try self.push(.{ .int_ = @rem(@as(i64, @intFromFloat(@trunc(a))), @as(i64, @intFromFloat(@trunc(b)))) });
            },
            .pow => try self.push(.{ .float_ = std.math.pow(f64, a, b) }),
        }
    }

    fn intBin(self: *Vm, kind: BitKind, line: u32) Error!void {
        _ = line;
        const rv = self.pop();
        const lv = self.pop();
        const li = valmod.toNumber(lv).int;
        const ri = valmod.toNumber(rv).int;
        const result: i64 = switch (kind) {
            .bit_and => li & ri,
            .bit_or => li | ri,
            .bit_xor => li ^ ri,
            .shl => if (ri < 0 or ri > 63) 0 else li << @intCast(ri),
            .shr => if (ri < 0 or ri > 63) (if (li < 0) @as(i64, -1) else 0) else li >> @intCast(ri),
        };
        try self.push(.{ .int_ = result });
    }

    fn cmpOp(self: *Vm, kind: enum { eq, neq, lt, gt, lte, gte }, line: u32) Error!void {
        _ = line;
        const r = self.pop();
        const l = self.pop();
        const result: bool = switch (kind) {
            .eq => try valmod.looseEq(l, r, self.arena),
            .neq => !(try valmod.looseEq(l, r, self.arena)),
            .lt => (try valmod.looseCmp(l, r, self.arena)) == .lt,
            .gt => (try valmod.looseCmp(l, r, self.arena)) == .gt,
            .lte => (try valmod.looseCmp(l, r, self.arena)) != .gt,
            .gte => (try valmod.looseCmp(l, r, self.arena)) != .lt,
        };
        try self.push(.{ .bool_ = result });
    }

    fn indexRead(self: *Vm, container: Value, key_v: Value, line: u32) Error!Value {
        switch (container) {
            .array_ => |arr| {
                if (key_v == .array_) return self.fatalF(line, "illegal offset type: array", .{});
                return arr.get(try valmod.makeKey(key_v, self.arena)) orelse .null_;
            },
            .str_ => |st| {
                const fl = valmod.toNumber(key_v).toFloat();
                if (fl < 0 or fl >= @as(f64, @floatFromInt(st.len))) return .{ .str_ = "" };
                const i: usize = @intFromFloat(fl);
                return .{ .str_ = st[i .. i + 1] };
            },
            .null_ => return .null_,
            else => return self.fatalF(line, "cannot use {s} value as array", .{container.typeName()}),
        }
    }

    fn incLocalSlot(self: *Vm, f: *Frame, slot: usize, up: bool, pre: bool) Error!void {
        const next = incValue(f.locals[slot], up);
        const old = f.locals[slot];
        f.locals[slot] = next;
        try self.push(if (pre) next else old);
    }

    fn incGlobal(self: *Vm, name: []const u8, up: bool, pre: bool) Error!void {
        const old = self.globals.get(name) orelse .null_;
        const next = incValue(old, up);
        try self.globals.put(self.arena, name, next);
        try self.push(if (pre) next else old);
    }

    fn incIndex(self: *Vm, up: bool, pre: bool, line: u32) Error!void {
        const key_v = self.pop();
        const container = self.pop();
        if (container != .array_) {
            return self.fatalF(line, "cannot use a {s} value as an array", .{container.typeName()});
        }
        if (key_v == .array_) return self.fatalF(line, "illegal offset type: array", .{});
        const key = try valmod.makeKey(key_v, self.arena);
        const arr = container.array_;
        const old = arr.get(key) orelse .null_;
        const next = incValue(old, up);
        try arr.set(self.arena, key, next);
        try self.push(if (pre) next else old);
    }

    fn incValue(old: Value, up: bool) Value {
        if (old == .null_) {
            return if (up) Value{ .int_ = 1 } else Value.null_;
        }
        if (old == .str_ and valmod.numericString(old.str_) == null) {
            return old; // non-numeric strings untouched (PHP semantics)
        }
        const n = valmod.toNumber(old);
        return switch (n) {
            .int => |i| Value{ .int_ = if (up) i +% 1 else i -% 1 },
            .float => |fl| Value{ .float_ = if (up) fl + 1 else fl - 1 },
        };
    }

    fn foreachInit(self: *Vm, temp: u32, line: u32) Error!void {
        const subject = self.pop();
        const f = &self.frames.items[self.frames.items.len - 1];
        if (subject == .null_) {
            f.temps[temp] = .{ .array_ = try Value.Array.create(self.arena) };
        } else if (subject == .array_) {
            f.temps[temp] = subject;
        } else {
            return self.fatalF(line, "foreach() argument must be of type array, {s} given", .{subject.typeName()});
        }
        f.temps[temp + 1] = .{ .int_ = 0 };
    }

    /// Advance the iterator; pushes [key?] value when items remain.
    /// Returns true when exhausted (caller jumps).
    fn foreachAdvance(self: *Vm, packed_arg: u32) Error!bool {
        const temp = opcode.unpackForeachTemp(packed_arg);
        const has_key = opcode.unpackForeachHasKey(packed_arg);
        const f = &self.frames.items[self.frames.items.len - 1];
        const snapshot = f.temps[temp].array_.entries.items;
        const i: usize = @intCast(f.temps[temp + 1].int_);
        if (i >= snapshot.len) return true;

        const entry = snapshot[i];
        f.temps[temp + 1] = .{ .int_ = @intCast(i + 1) };
        if (has_key) try self.push(entry.key.toValue());
        try self.push(entry.val);
        return false;
    }

    fn doCall(self: *Vm, name: []const u8, argc: u32, line: u32) Error!void {
        if (self.funcs.get(name)) |callee| {
            if (argc > callee.arity) {
                return self.fatalF(line, "{s}() expects at most {d} argument(s), {d} given", .{ name, callee.arity, argc });
            }
            if (self.frames.items.len >= MAX_CALL_DEPTH) {
                return self.fatalF(line, "Maximum function nesting level of {d} reached, aborting", .{MAX_CALL_DEPTH});
            }

            // Move args from the operand stack into the new frame's locals.
            const stack_base = self.stack.items.len - argc;
            const args = try self.arena.dupe(Value, self.stack.items[stack_base..]);
            self.stack.shrinkRetainingCapacity(stack_base);

            const nslots = @max(callee.nlocals, callee.arity);
            const locals = try self.arena.alloc(Value, nslots);
            for (locals) |*l| l.* = .null_;
            for (args, 0..) |a, i| locals[i] = a;
            // Constant defaults for missing params.
            var i: usize = argc;
            while (i < callee.arity) : (i += 1) {
                if (i < callee.defaults.len) {
                    locals[i] = callee.defaults[i] orelse {
                        return self.fatalF(line, "Too few arguments to function {s}()", .{name});
                    };
                } else {
                    return self.fatalF(line, "Too few arguments to function {s}()", .{name});
                }
            }

            try self.frames.append(self.arena, .{
                .func = callee,
                .ip = 0,
                .locals = locals,
                .temps = try self.arena.alloc(Value, callee.ntemps),
                .stack_base = self.stack.items.len,
            });

            // Execute the callee to completion (recursion into dispatch).
            // Depth is bounded by MAX_CALL_DEPTH so native-stack recursion
            // stays within limits.
            try self.dispatch();
            return;
        }

        // Builtins receive a view of the operand stack.
        if (argc > 255) return self.fatalF(line, "too many arguments", .{});
        const stack_base = self.stack.items.len - argc;
        const args = self.stack.items[stack_base..];
        if (try builtins.call(self, name, args, line)) |result| {
            self.stack.shrinkRetainingCapacity(stack_base);
            try self.push(result);
            return;
        }

        return self.fatalF(line, "Call to undefined function {s}()", .{name});
    }

    fn popFrame(self: *Vm, result: Value) Error!void {
        const frame = self.frames.pop().?;
        self.stack.shrinkRetainingCapacity(frame.stack_base);
        // Leave the result for the caller (or as script result at top level).
        try self.push(result);
    }
};
