//! Builtin function library for zphp.
//!
//! Functions receive already-evaluated argument values and return
//! `null` when the name is unknown (the VM then raises
//! "Call to undefined function").

const std = @import("std");
const valmod = @import("value.zig");
const vm_mod = @import("vm.zig");

const Vm = vm_mod.Vm;
const Value = valmod.Value;
const Error = vm_mod.Error;

const BuiltinFn = *const fn (in: *Vm, args: []const Value) Error!Value;

const table = std.StaticStringMap(BuiltinFn).initComptime(.{
    // Strings
    .{ "strlen", &fn_strlen },
    .{ "strtolower", &fn_strtolower },
    .{ "strtoupper", &fn_strtoupper },
    .{ "strrev", &fn_strrev },
    .{ "substr", &fn_substr },
    .{ "strpos", &fn_strpos },
    .{ "str_repeat", &fn_str_repeat },
    .{ "str_replace", &fn_str_replace },
    .{ "trim", &fn_trim },
    .{ "ltrim", &fn_ltrim },
    .{ "rtrim", &fn_rtrim },
    .{ "ucfirst", &fn_ucfirst },
    .{ "lcfirst", &fn_lcfirst },
    .{ "str_contains", &fn_str_contains },
    .{ "str_starts_with", &fn_str_starts_with },
    .{ "str_ends_with", &fn_str_ends_with },
    .{ "sprintf", &fn_sprintf },

    // Arrays
    .{ "count", &fn_count },
    .{ "sizeof", &fn_count },
    .{ "array_push", &fn_array_push },
    .{ "array_pop", &fn_array_pop },
    .{ "array_shift", &fn_array_shift },
    .{ "array_unshift", &fn_array_unshift },
    .{ "array_keys", &fn_array_keys },
    .{ "array_values", &fn_array_values },
    .{ "array_reverse", &fn_array_reverse },
    .{ "array_sum", &fn_array_sum },
    .{ "get_class", &fn_get_class },
    .{ "array_merge", &fn_array_merge },
    .{ "in_array", &fn_in_array },
    .{ "implode", &fn_implode },
    .{ "join", &fn_implode },
    .{ "explode", &fn_explode },
    .{ "range", &fn_range },

    // Math
    .{ "abs", &fn_abs },
    .{ "max", &fn_max },
    .{ "min", &fn_min },
    .{ "sqrt", &fn_sqrt },
    .{ "floor", &fn_floor },
    .{ "ceil", &fn_ceil },
    .{ "round", &fn_round },
    .{ "pow", &fn_pow },
    .{ "intdiv", &fn_intdiv },
    .{ "pi", &fn_pi },

    // Types & introspection
    .{ "intval", &fn_intval },
    .{ "floatval", &fn_floatval },
    .{ "doubleval", &fn_floatval },
    .{ "strval", &fn_strval },
    .{ "boolval", &fn_boolval },
    .{ "is_int", &fn_is_int },
    .{ "is_integer", &fn_is_int },
    .{ "is_long", &fn_is_int },
    .{ "is_float", &fn_is_float },
    .{ "is_double", &fn_is_float },
    .{ "is_string", &fn_is_string },
    .{ "is_array", &fn_is_array },
    .{ "is_bool", &fn_is_bool },
    .{ "is_null", &fn_is_null },
    .{ "is_numeric", &fn_is_numeric },
    .{ "gettype", &fn_gettype },

    // Output & misc
    .{ "var_dump", &fn_var_dump },
    .{ "print_r", &fn_print_r },
});

/// Returns null if `name` is not a builtin.
pub fn call(in: *Vm, name: []const u8, args: []const Value, line: u32) Error!?Value {
    _ = line; // fatal messages inside builtins use position 0 for now
    const f = table.get(name) orelse return null;
    return try f(in, args);
}

// -- argument helpers -----------------------------------------------------------

fn needArgs(in: *Vm, args: []const Value, min: usize, max: usize, sig: []const u8) Error!void {
    if (args.len < min or args.len > max) {
        return in.fatalF(0, "{s}(): expects {s}", .{ sigName(sig), sigParams(sig) });
    }
}

fn sigName(sig: []const u8) []const u8 {
    return sig[0..std.mem.indexOfScalar(u8, sig, '(').?];
}

fn sigParams(sig: []const u8) []const u8 {
    return sig[std.mem.indexOfScalar(u8, sig, '(').? + 1 ..];
}

fn asStr(in: *Vm, v: Value) Error![]const u8 {
    return valmod.toString(v, in.arena);
}

/// Box a byte slice into a string Value.
fn mkStr(in: *Vm, slice: []const u8) Error!Value {
    return .{ .str_ = try valmod.newStr(in.arena, slice) };
}

fn wantInt(in: *Vm, v: Value) i64 {
    return valmod.toNumber(v, in.arena).int;
}

fn wantFloat(in: *Vm, v: Value) f64 {
    return valmod.toNumber(v, in.arena).toFloat();
}

fn wantArray(in: *Vm, v: Value, fname: []const u8) Error!*Value.Array {
    return switch (v) {
        .array_ => |arr| arr,
        else => in.fatalF(0, "{s}(): Argument #1 ($array) must be of type array, {s} given", .{ fname, v.typeName() }),
    };
}

// -- strings ---------------------------------------------------------------------

fn fn_strlen(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "strlen($string)");
    return .{ .int_ = @intCast((try asStr(in, args[0])).len) };
}

fn fn_strtolower(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "strtolower($string)");
    const s = try asStr(in, args[0]);
    const out = try in.arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return try mkStr(in, out);
}

fn fn_strtoupper(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "strtoupper($string)");
    const s = try asStr(in, args[0]);
    const out = try in.arena.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return try mkStr(in, out);
}

fn fn_strrev(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "strrev($string)");
    const s = try asStr(in, args[0]);
    const out = try in.arena.dupe(u8, s);
    std.mem.reverse(u8, out);
    return try mkStr(in, out);
}

fn fn_substr(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 3, "substr($string, $offset, $length = null)");
    const s = try asStr(in, args[0]);
    var start = wantInt(in, args[1]);
    if (start < 0) start += @intCast(s.len);
    if (start < 0 or start >= s.len) return try mkStr(in, "");
    const from: usize = @intCast(start);

    if (args.len == 2) return try mkStr(in, s[from..]);

    var len = wantInt(in, args[2]);
    if (len < 0) len += @intCast(s.len - from);
    if (len <= 0) return try mkStr(in, "");
    const to = @min(from + @as(usize, @intCast(len)), s.len);
    return try mkStr(in, s[from..to]);
}

fn fn_strpos(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 3, "strpos($haystack, $needle, $offset = 0)");
    const hay = try asStr(in, args[0]);
    const needle = try asStr(in, args[1]);
    var offset = if (args.len == 3) wantInt(in, args[2]) else 0;
    if (offset < 0) offset += @intCast(hay.len);
    if (offset < 0 or offset >= hay.len) return .{ .bool_ = false };
    const idx = std.mem.indexOfPos(u8, hay, @intCast(offset), needle) orelse return .{ .bool_ = false };
    return .{ .int_ = @intCast(idx) };
}

fn fn_str_repeat(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "str_repeat($string, $times)");
    const st = try asStr(in, args[0]);
    const times = wantInt(in, args[1]);
    if (times <= 0) return try mkStr(in, "");
    const n: usize = @intCast(times);
    if (st.len * n > 256 * 1024 * 1024) {
        return in.fatalF(0, "str_repeat(): result too large", .{});
    }
    const out = try in.arena.alloc(u8, st.len * n);
    var i: usize = 0;
    while (i < n) : (i += 1) @memcpy(out[i * st.len ..][0..st.len], st);
    return try mkStr(in, out);
}

fn fn_str_replace(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 3, 3, "str_replace($search, $replace, $subject)");
    const search = try asStr(in, args[0]);
    const replace = try asStr(in, args[1]);
    const subject = try asStr(in, args[2]);
    if (search.len == 0) return try mkStr(in, subject);
    return try mkStr(in, try std.mem.replaceOwned(u8, in.arena, subject, search, replace));
}

const ws = " \t\n\r\x00\x0b\x0c";

fn fn_trim(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "trim($string)");
    return try mkStr(in, std.mem.trim(u8, try asStr(in, args[0]), ws));
}

fn fn_ltrim(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "ltrim($string)");
    return try mkStr(in, std.mem.trimStart(u8, try asStr(in, args[0]), ws));
}

fn fn_rtrim(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "rtrim($string)");
    return try mkStr(in, std.mem.trimEnd(u8, try asStr(in, args[0]), ws));
}

fn fn_ucfirst(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "ucfirst($string)");
    const st = try in.arena.dupe(u8, try asStr(in, args[0]));
    if (st.len > 0) st[0] = std.ascii.toUpper(st[0]);
    return try mkStr(in, st);
}

fn fn_lcfirst(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "lcfirst($string)");
    const st = try in.arena.dupe(u8, try asStr(in, args[0]));
    if (st.len > 0) st[0] = std.ascii.toLower(st[0]);
    return try mkStr(in, st);
}

fn fn_str_contains(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "str_contains($haystack, $needle)");
    const hay = try asStr(in, args[0]);
    const needle = try asStr(in, args[1]);
    return .{ .bool_ = needle.len == 0 or std.mem.indexOf(u8, hay, needle) != null };
}

fn fn_str_starts_with(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "str_starts_with($haystack, $needle)");
    return .{ .bool_ = std.mem.startsWith(u8, try asStr(in, args[0]), try asStr(in, args[1])) };
}

fn fn_str_ends_with(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "str_ends_with($haystack, $needle)");
    return .{ .bool_ = std.mem.endsWith(u8, try asStr(in, args[0]), try asStr(in, args[1])) };
}

/// sprintf with %s %d %f %x %X %o %b %e %%; no width/precision support.
fn fn_sprintf(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 255, "sprintf($format, ...$values)");
    const fmt = try asStr(in, args[0]);
    var out: std.ArrayList(u8) = .empty;
    var argi: usize = 1;

    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(in.arena, c);
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        const next_arg: Value = if (argi < args.len) blk: {
            argi += 1;
            break :blk args[argi - 1];
        } else .null_;
        switch (fmt[i]) {
            '%' => try out.append(in.arena, '%'),
            's' => try out.appendSlice(in.arena, try asStr(in, next_arg)),
            'd' => try out.print(in.arena, "{d}", .{wantInt(in, next_arg)}),
            'f' => try out.print(in.arena, "{d}", .{wantFloat(in, next_arg)}),
            'x' => try out.print(in.arena, "{x}", .{wantInt(in, next_arg)}),
            'X' => try out.print(in.arena, "{X}", .{wantInt(in, next_arg)}),
            'o' => try out.print(in.arena, "{o}", .{wantInt(in, next_arg)}),
            'b' => try out.print(in.arena, "{b}", .{wantInt(in, next_arg)}),
            'e', 'E' => try out.print(in.arena, "{e}", .{wantFloat(in, next_arg)}),
            else => {
                try out.append(in.arena, '%');
                try out.append(in.arena, fmt[i]);
            },
        }
    }
    return try mkStr(in, out.items);
}

// -- arrays ------------------------------------------------------------------------

fn fn_get_class(in: *Vm, args: []const Value) Error!Value {
    if (args.len == 1 and args[0] == .obj_) return try mkStr(in, args[0].obj_.class_name);
    return .{ .bool_ = false }; // simplified: no class-scope form
}

fn fn_count(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "count($value)");
    return switch (args[0]) {
        .array_ => |arr| .{ .int_ = @intCast(arr.count()) },
        .null_ => .{ .int_ = 0 },
        else => .{ .int_ = 1 }, // PHP counts scalars as 1
    };
}

fn fn_array_push(in: *Vm, args: []const Value) Error!Value {
    if (args.len < 2) return in.fatalF(0, "array_push(): expects at least 2 arguments", .{});
    const arr = try wantArray(in, args[0], "array_push");
    for (args[1..]) |v| try arr.appendVal(in.arena, v);
    return .{ .int_ = @intCast(arr.count()) };
}

// (Array.reindex lives in value.zig)

fn fn_array_pop(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "array_pop($array)");
    const arr = try wantArray(in, args[0], "array_pop");
    if (arr.entries.items.len == 0) return .null_;
    const last = arr.entries.pop().?.val;
    arr.reindex(in.arena);
    return last;
}

fn fn_array_shift(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "array_shift($array)");
    const arr = try wantArray(in, args[0], "array_shift");
    if (arr.entries.items.len == 0) return .null_;
    const first = arr.entries.orderedRemove(0).val;
    arr.reindex(in.arena);
    return first;
}

fn fn_array_unshift(in: *Vm, args: []const Value) Error!Value {
    if (args.len < 2) return in.fatalF(0, "array_unshift(): expects at least 2 arguments", .{});
    const arr = try wantArray(in, args[0], "array_unshift");
    for (args[1..], 0..) |v, ins_i| {
        try arr.entries.insert(in.arena, ins_i, .{ .key = .{ .int = 0 }, .val = v });
    }
    arr.reindex(in.arena);
    return .{ .int_ = @intCast(arr.count()) };
}

fn fn_array_keys(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "array_keys($array)");
    const arr = try wantArray(in, args[0], "array_keys");
    const out = try Value.Array.create(in.arena);
    for (arr.entries.items) |e| try out.appendVal(in.arena, try e.key.toValue(in.arena));
    return .{ .array_ = out };
}

fn fn_array_values(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "array_values($array)");
    const arr = try wantArray(in, args[0], "array_values");
    const out = try Value.Array.create(in.arena);
    for (arr.entries.items) |e| try out.appendVal(in.arena, e.val);
    return .{ .array_ = out };
}

fn fn_array_reverse(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "array_reverse($array)");
    const arr = try wantArray(in, args[0], "array_reverse");
    const out = try Value.Array.create(in.arena);
    var idx: i64 = 0;
    var i = arr.entries.items.len;
    while (i > 0) : (i -= 1) {
        try out.set(in.arena, .{ .int = idx }, arr.entries.items[i - 1].val);
        idx += 1;
    }
    out.next_index = idx;
    return .{ .array_ = out };
}

fn fn_array_sum(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "array_sum($array)");
    const arr = try wantArray(in, args[0], "array_sum");
    var acc_f: f64 = 0;
    var acc_i: i64 = 0;
    var any_float = false;
    for (arr.entries.items) |e| {
        const n = valmod.toNumber(e.val, in.arena);
        switch (n) {
            .int => |iv| acc_i +%= iv,
            .float => |fv| {
                any_float = true;
                acc_f += fv;
            },
        }
    }
    if (any_float) return .{ .float_ = acc_f + @as(f64, @floatFromInt(acc_i)) };
    return .{ .int_ = acc_i };
}

fn fn_array_merge(in: *Vm, args: []const Value) Error!Value {
    if (args.len < 1) return in.fatalF(0, "array_merge(): expects at least 1 argument", .{});
    const out = try Value.Array.create(in.arena);
    for (args) |a| {
        const arr = try wantArray(in, a, "array_merge");
        for (arr.entries.items) |e| {
            switch (e.key) {
                .int => try out.appendVal(in.arena, e.val),
                .str => |k| try out.set(in.arena, .{ .str = k }, e.val),
            }
        }
    }
    return .{ .array_ = out };
}

fn fn_in_array(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 3, "in_array($needle, $haystack, $strict = false)");
    const arr = try wantArray(in, args[1], "in_array");
    const strict = if (args.len == 3) args[2].truthy() else false;
    for (arr.entries.items) |e| {
        const found = if (strict)
            try valmod.strictEq(e.val, args[0], in.arena)
        else
            try valmod.looseEq(e.val, args[0], in.arena);
        if (found) return .{ .bool_ = true };
    }
    return .{ .bool_ = false };
}

fn fn_implode(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 2, "implode($glue, $array)");
    var glue: []const u8 = "";
    var arr_val: Value = undefined;
    if (args.len == 1) {
        arr_val = args[0];
    } else {
        glue = try asStr(in, args[0]);
        arr_val = args[1];
    }
    const arr = try wantArray(in, arr_val, "implode");
    var buf: std.ArrayList(u8) = .empty;
    for (arr.entries.items, 0..) |e, ei| {
        if (ei > 0) try buf.appendSlice(in.arena, glue);
        try buf.appendSlice(in.arena, try valmod.toString(e.val, in.arena));
    }
    return try mkStr(in, buf.items);
}

fn fn_explode(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "explode($separator, $string)");
    const sep = try asStr(in, args[0]);
    const subject = try asStr(in, args[1]);
    if (sep.len == 0) return in.fatalF(0, "explode(): Argument #1 ($separator) cannot be empty", .{});
    const out = try Value.Array.create(in.arena);
    var iter = std.mem.splitSequence(u8, subject, sep);
    while (iter.next()) |piece| {
        try out.appendVal(in.arena, try mkStr(in, piece));
    }
    return .{ .array_ = out };
}

fn fn_range(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 3, "range($start, $end, $step = 1)");
    var step: i64 = if (args.len == 3) wantInt(in, args[2]) else 1;
    if (step == 0) step = 1;
    const start = wantInt(in, args[0]);
    const end = wantInt(in, args[1]);
    const out = try Value.Array.create(in.arena);
    if (step > 0) {
        var iv = start;
        while (iv <= end) : (iv += step) try out.appendVal(in.arena, .{ .int_ = iv });
    } else {
        var iv = start;
        while (iv >= end) : (iv += step) try out.appendVal(in.arena, .{ .int_ = iv });
    }
    return .{ .array_ = out };
}

// -- math -------------------------------------------------------------------------

fn fn_abs(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "abs($num)");
    return switch (valmod.toNumber(args[0], in.arena)) {
        .int => |i| .{ .int_ = if (i == std.math.minInt(i64)) i else @intCast(@abs(i)) },
        .float => |f| .{ .float_ = @abs(f) },
    };
}

fn extreme(in: *Vm, args: []const Value, want_greater: bool) Error!Value {
    var best: ?Value = null;
    if (args.len == 1 and args[0] == .array_) {
        for (args[0].array_.entries.items) |entry| {
            const c = entry.val;
            if (best == null) {
                best = c;
                continue;
            }
            const ord = try valmod.looseCmp(c, best.?, in.arena);
            if ((ord == .gt) == want_greater) best = c;
        }
        return best orelse .null_;
    }
    if (args.len < 2) return in.fatalF(0, "max()/min(): expects at least 2 arguments or an array", .{});
    for (args) |c| {
        if (best == null) {
            best = c;
            continue;
        }
        const ord = try valmod.looseCmp(c, best.?, in.arena);
        if ((ord == .gt) == want_greater) best = c;
    }
    return best.?;
}

fn fn_max(in: *Vm, args: []const Value) Error!Value {
    return extreme(in, args, true);
}

fn fn_min(in: *Vm, args: []const Value) Error!Value {
    return extreme(in, args, false);
}

fn fn_sqrt(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "sqrt($num)");
    const f = wantFloat(in, args[0]);
    if (f < 0) return .{ .float_ = std.math.nan(f64) };
    return .{ .float_ = @sqrt(f) };
}

fn fn_floor(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "floor($num)");
    return .{ .float_ = @floor(wantFloat(in, args[0])) };
}

fn fn_ceil(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "ceil($num)");
    return .{ .float_ = @ceil(wantFloat(in, args[0])) };
}

fn roundHalfAway(f: f64, precision: i64) f64 {
    if (precision == 0) return @floor(f + 0.5);
    const p = std.math.pow(f64, 10, @floatFromInt(precision));
    return @floor(f * p + 0.5) / p;
}

fn fn_round(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 2, "round($num, $precision = 0)");
    const f = wantFloat(in, args[0]);
    const precision: i64 = if (args.len == 2) wantInt(in, args[1]) else 0;
    return .{ .float_ = roundHalfAway(f, precision) };
}

fn fn_pow(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "pow($base, $exp)");
    const ln = valmod.toNumber(args[0], in.arena);
    const rn = valmod.toNumber(args[1], in.arena);
    if (ln == .int and rn == .int and rn.int >= 0 and rn.int <= 62) {
        var result: i64 = 1;
        var i: i64 = 0;
        while (i < rn.int) : (i += 1) result *|= ln.int;
        return .{ .int_ = result };
    }
    return .{ .float_ = std.math.pow(f64, ln.toFloat(), rn.toFloat()) };
}

fn fn_intdiv(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 2, 2, "intdiv($num1, $num2)");
    const b = wantInt(in, args[1]);
    if (b == 0) return in.fatalF(0, "Division by zero", .{});
    return .{ .int_ = @divTrunc(wantInt(in, args[0]), b) };
}

fn fn_pi(in: *Vm, args: []const Value) Error!Value {
    _ = args;
    _ = in;
    return .{ .float_ = std.math.pi };
}

// -- types -----------------------------------------------------------------------

fn fn_intval(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "intval($value)");
    if (args[0] == .str_) {
        if (valmod.numericString(args[0].str_.data)) |n| {
            return .{ .int_ = switch (n) {
                .int => |iv| iv,
                .float => |fv| @intFromFloat(@trunc(fv)),
            } };
        }
        return .{ .int_ = 0 };
    }
    return .{ .int_ = wantInt(in, args[0]) };
}

fn fn_floatval(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "floatval($value)");
    return .{ .float_ = wantFloat(in, args[0]) };
}

fn fn_strval(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "strval($value)");
    return try mkStr(in, try asStr(in, args[0]));
}

fn fn_boolval(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "boolval($value)");
    return .{ .bool_ = args[0].truthy() };
}

fn fn_is_int(_: *Vm, args: []const Value) Error!Value {
    return .{ .bool_ = args.len > 0 and args[0] == .int_ };
}

fn fn_is_float(_: *Vm, args: []const Value) Error!Value {
    return .{ .bool_ = args.len > 0 and args[0] == .float_ };
}

fn fn_is_string(_: *Vm, args: []const Value) Error!Value {
    return .{ .bool_ = args.len > 0 and args[0] == .str_ };
}

fn fn_is_array(_: *Vm, args: []const Value) Error!Value {
    return .{ .bool_ = args.len > 0 and args[0] == .array_ };
}

fn fn_is_bool(_: *Vm, args: []const Value) Error!Value {
    return .{ .bool_ = args.len > 0 and args[0] == .bool_ };
}

fn fn_is_null(_: *Vm, args: []const Value) Error!Value {
    return .{ .bool_ = args.len > 0 and args[0] == .null_ };
}

fn fn_is_numeric(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "is_numeric($value)");
    return switch (args[0]) {
        .int_, .float_ => .{ .bool_ = true },
        .str_ => |st| .{ .bool_ = valmod.numericString(st.data) != null },
        else => .{ .bool_ = false },
    };
}

fn fn_gettype(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 1, "gettype($value)");
    // PHP keeps the historical names.
    const name: []const u8 = switch (args[0].resolveDeep()) {
        .null_ => "NULL",
        .bool_ => "boolean",
        .int_ => "integer",
        .float_ => "double",
        .str_, .rope_ => "string",
        .array_ => "array",
        .obj_ => "object",
        .ref_ => "reference",
    };
    return try mkStr(in, name);
}

// -- output ------------------------------------------------------------------------

fn dumpValue(in: *Vm, v: Value, indent: u32) Error!void {
    var pad_buf: [128]u8 = .{' '} ** 128;
    const pad = pad_buf[0 .. indent * 2];
    switch (v.resolveDeep()) {
        .null_ => try in.out.print("{s}NULL\n", .{pad}),
        .bool_ => |b| try in.out.print("{s}bool({s})\n", .{ pad, if (b) "true" else "false" }),
        .int_ => |i| try in.out.print("{s}int({d})\n", .{ pad, i }),
        .float_ => |f| try in.out.print("{s}float({s})\n", .{ pad, try valmod.fmtFloat(f, in.arena) }),
        .str_, .rope_ => {
            const st = try valmod.toString(v, in.arena);
            try in.out.print("{s}string({d}) \"{s}\"\n", .{ pad, st.len, st });
        },
        .obj_ => |o| {
            try in.out.print("{s}object({s}) {{\n", .{ pad, o.class_name });
            for (o.props.items) |p| {
                try in.out.print("{s}  [\"{s}\"]=>\n", .{ pad, p.name });
                try dumpValue(in, p.val, indent + 2);
            }
            try in.out.print("{s}}}\n", .{pad});
        },
        .ref_ => unreachable, // resolveDeep above
        .array_ => {
            const arr = v.array_;
            try in.out.print("{s}array({d}) {{\n", .{ pad, arr.count() });
            for (arr.entries.items) |e| {
                switch (e.key) {
                    .int => |k| try in.out.print("{s}  [{d}]=>\n", .{ pad, k }),
                    .str => |k| try in.out.print("{s}  [\"{s}\"]=>\n", .{ pad, k }),
                }
                try dumpValue(in, e.val, indent + 2);
            }
            try in.out.print("{s}}}\n", .{pad});
        },
    }
}

fn fn_var_dump(in: *Vm, args: []const Value) Error!Value {
    for (args) |v| try dumpValue(in, v, 0);
    return .null_;
}

fn printRScalar(in: *Vm, v: Value) Error!void {
    switch (v) {
        .null_ => {},
        .bool_ => |b| try in.out.writeAll(if (b) "1" else ""),
        .array_ => unreachable,
        else => try in.out.writeAll(try valmod.toString(v, in.arena)),
    }
}

fn printRValue(in: *Vm, v: Value, depth: u32) Error!void {
    if (v != .array_) {
        try printRScalar(in, v);
        try in.out.writeAll("\n");
        return;
    }
    const arr = v.array_;
    try in.out.writeAll("Array\n");
    try in.out.print("{s}(\n", .{spaces(depth * 4)});
    for (arr.entries.items) |e| {
        switch (e.key) {
            .int => |k| try in.out.print("{s}[{d}] => ", .{ spaces(depth * 4 + 4), k }),
            .str => |k| try in.out.print("{s}[{s}] => ", .{ spaces(depth * 4 + 4), k }),
        }
        if (e.val == .array_) {
            try printRValue(in, e.val, depth + 2);
            try in.out.writeAll("\n"); // PHP inserts a blank line after nested arrays
        } else {
            try printRScalar(in, e.val);
            try in.out.writeAll("\n");
        }
    }
    try in.out.print("{s})\n", .{spaces(depth * 4)});
}

fn spaces(n: u32) []const u8 {
    const all = "                                                                ";
    return all[0..@min(n * 1, all.len)];
}

fn fn_print_r(in: *Vm, args: []const Value) Error!Value {
    try needArgs(in, args, 1, 2, "print_r($value, $return = false)");
    if (args.len == 2 and args[1].truthy()) {
        // Capture into a string instead of printing.
        var aw: std.Io.Writer.Allocating = .init(in.arena);
        const saved = in.out;
        in.out = &aw.writer;
        defer in.out = saved;
        try printRValue(in, args[0], 0);
        return try mkStr(in, aw.written());
    }
    try printRValue(in, args[0], 0);
    return .{ .bool_ = true };
}
