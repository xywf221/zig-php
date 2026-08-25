//! Runtime value ("zval") system and PHP type semantics.
//!
//! Implements PHP's weak-typing rules: truthiness, loose comparisons,
//! string-to-number coercion, array key normalization and string conversion.
//!
//! Known simplifications vs. real PHP:
//!   * float formatting uses Zig's shortest decimal representation instead
//!     of PHP's precision=14 / scientific notation rules,
//!   * array-vs-array comparison orders by element count only,
//!   * NaN/INF handling follows PHP only loosely.

const std = @import("std");

/// Cons-cell rope: a chain of string chunks accumulated by repeated
/// concatenation. `rest` is always `.str_` or `.rope_`; the total length is
/// cached so truthiness checks never allocate.
pub const Rope = struct {
    rest: Value,
    chunk: []const u8,
    len: usize,

    pub fn cons(a: std.mem.Allocator, rest: Value, chunk: []const u8) !*Rope {
        const r = try a.create(Rope);
        r.* = .{ .rest = rest, .chunk = chunk, .len = byteLen(rest) + chunk.len };
        return r;
    }

    fn byteLen(v: Value) usize {
        return switch (v) {
            .str_ => |s| s.len,
            .rope_ => |r| r.len,
            else => unreachable,
        };
    }

    /// Flatten the whole chain into one freshly allocated buffer.
    pub fn flatten(self: *const Rope, a: std.mem.Allocator) ![]const u8 {
        const buf = try a.alloc(u8, self.len);
        var node = self;
        var pos = self.len;
        while (true) {
            pos -= node.chunk.len;
            @memcpy(buf[pos..][0..node.chunk.len], node.chunk);
            switch (node.rest) {
                .str_ => |s| {
                    pos -= s.len;
                    @memcpy(buf[pos..][0..s.len], s);
                    break;
                },
                .rope_ => |nr| node = nr,
                else => unreachable,
            }
        }
        std.debug.assert(pos == 0);
        return buf;
    }
};

/// A class instance. Property lookup is linear over declared properties
/// (classes in this subset are small); identity is pointer equality.
pub const Object = struct {
    class_name: []const u8,
    props: std.ArrayList(ObjProp) = .empty,

    pub const ObjProp = struct { name: []const u8, val: Value };

    pub fn create(a: std.mem.Allocator, class_name: []const u8) !*Object {
        const o = try a.create(Object);
        o.* = .{ .class_name = class_name };
        return o;
    }

    pub fn get(self: *const Object, name: []const u8) ?Value {
        for (self.props.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.val;
        }
        return null;
    }

    /// PHP: reading an undeclared property is a warning + null (we return
    /// null); WRITING an undeclared property creates it dynamically.
    pub fn set(self: *Object, a: std.mem.Allocator, name: []const u8, val: Value) !void {
        for (self.props.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                p.val = val;
                return;
            }
        }
        try self.props.append(a, .{ .name = name, .val = val });
    }
};

pub const Key = union(enum) {
    int: i64,
    str: []const u8,

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .int => |x| switch (b) {
                .int => |y| x == y,
                .str => false,
            },
            .str => |x| switch (b) {
                .str => |y| std.mem.eql(u8, x, y),
                .int => false,
            },
        };
    }

    pub fn toValue(self: Key) Value {
        return switch (self) {
            .int => |i| .{ .int_ = i },
            .str => |s| .{ .str_ = s },
        };
    }
};

pub const Value = union(enum) {
    null_,
    bool_: bool,
    int_: i64,
    float_: f64,
    str_: []const u8,
    /// Lazily concatenated string produced by `.` / `.=`. Materializes
    /// (O(total length)) the first time raw bytes are needed.
    rope_: *const Rope,
    array_: *Array,
    obj_: *Object,

    pub const Array = struct {
        entries: std.ArrayList(Entry) = .empty,
        next_index: i64 = 0,
        /// Hash indexes over `entries` positions. Key normalization
        /// guarantees `.str` keys are non-numeric strings, so byte equality
        /// is the correct semantics for the string index.
        int_ix: std.AutoHashMapUnmanaged(i64, u32) = .empty,
        str_ix: std.StringHashMapUnmanaged(u32) = .empty,

        pub const Entry = struct { key: Key, val: Value };

        pub fn create(a: std.mem.Allocator) !*Array {
            const arr = try a.create(Array);
            arr.* = .{};
            return arr;
        }

        pub fn find(self: *const Array, key: Key) ?u32 {
            return switch (key) {
                .int => |i| self.int_ix.get(i),
                .str => |s| self.str_ix.get(s),
            };
        }

        pub fn get(self: *const Array, key: Key) ?Value {
            if (self.find(key)) |i| return self.entries.items[i].val;
            return null;
        }

        fn indexPut(self: *Array, a: std.mem.Allocator, pos: u32, key: Key) !void {
            switch (key) {
                .int => |i| try self.int_ix.put(a, i, pos),
                .str => |s| try self.str_ix.put(a, s, pos),
            }
        }

        /// Insert or update with PHP key normalization.
        pub fn set(self: *Array, a: std.mem.Allocator, key: Key, val: Value) !void {
            // Fast path: an int key at/past next_index cannot exist yet
            // (keys are normalized, so nothing higher has been stored).
            const may_exist = !(key == .int and key.int >= self.next_index);
            if (may_exist) {
                if (self.find(key)) |pos| {
                    self.entries.items[pos].val = val;
                    return;
                }
            }
            const pos: u32 = @intCast(self.entries.items.len);
            try self.entries.append(a, .{ .key = key, .val = val });
            try self.indexPut(a, pos, key);
            if (key == .int and key.int >= self.next_index) {
                self.next_index = key.int + 1;
            }
        }

        pub fn appendVal(self: *Array, a: std.mem.Allocator, val: Value) !void {
            try self.set(a, .{ .int = self.next_index }, val);
        }

        pub fn count(self: *const Array) usize {
            return self.entries.items.len;
        }

        /// Renumber integer keys sequentially (after structural mutations
        /// like shift/unshift/pop) and rebuild both hash indexes.
        pub fn reindex(self: *Array, a: std.mem.Allocator) void {
            self.int_ix.clearRetainingCapacity();
            self.str_ix.clearRetainingCapacity();
            var idx: i64 = 0;
            for (self.entries.items, 0..) |*e, pos| {
                if (e.key == .int) e.key = .{ .int = idx };
                self.indexPut(a, @intCast(pos), e.key) catch {};
                idx += 1;
            }
            self.next_index = idx;
        }
    };

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null_ => "null",
            .bool_ => "bool",
            .int_ => "int",
            .float_ => "float",
            .str_, .rope_ => "string",
            .array_ => "array",
            .obj_ => "object",
        };
    }

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null_ => false,
            .bool_ => |b| b,
            .int_ => |i| i != 0,
            .float_ => |f| f != 0.0,
            .str_ => |s| s.len > 0 and !std.mem.eql(u8, s, "0"),
            // Zero-allocation: only a single "0" byte is falsy.
            .rope_ => |r| r.len > 0 and !(r.len == 1 and firstByte(r) == '0'),
            .array_ => |arr| arr.count() > 0,
            .obj_ => true,
        };
    }

    fn firstByte(r: *const Rope) u8 {
        var node = r;
        while (true) {
            if (node.rest == .rope_) node = node.rest.rope_ else return node.rest.str_[0];
        }
    }
};



/// Convert any value to its PHP string representation.
pub fn toString(v: Value, a: std.mem.Allocator) ![]const u8 {
    return switch (v) {
        .null_ => "",
        .bool_ => |b| if (b) "1" else "",
        .int_ => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float_ => |f| try fmtFloat(f, a),
        .str_ => |s| s,
        .rope_ => |r| r.flatten(a),
        .array_ => "Array",
        // Callers that need PHP's fatal-object-conversion semantics must
        // reject objects before calling; this fallback keeps toString total.
        .obj_ => "Object",
    };
}

pub fn fmtFloat(f: f64, a: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    if (std.math.isNan(f)) return "NAN";
    if (std.math.isPositiveInf(f)) return "INF";
    if (std.math.isNegativeInf(f)) return "-INF";
    if (@abs(f) < 9.007199254740992e15 and f == @trunc(f)) {
        return std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(f))});
    }
    return std.fmt.allocPrint(a, "{d}", .{f});
}

/// Normalize a value into an array key following PHP rules:
/// int stays, bool -> 0/1, float -> truncate, null -> "", numeric strings
/// become ints, everything else keeps its string form.
pub fn makeKey(v: Value, a: std.mem.Allocator) !Key {
    return switch (v) {
        .null_ => .{ .str = "" },
        .bool_ => |b| .{ .int = @intFromBool(b) },
        .int_ => |i| .{ .int = i },
        .float_ => |f| .{ .int = @intFromFloat(@trunc(f)) },
        .str_ => |s| blk: {
            if (canonicalIntString(s)) |i| break :blk .{ .int = i };
            break :blk .{ .str = s };
        },
        .rope_ => |r| try makeKey(.{ .str_ = try r.flatten(a) }, a),
        .array_, .obj_ => fatalKey(),
    };
}

fn fatalKey() Key {
    unreachable; // caller must reject arrays as keys before calling
}

/// If s is a canonical decimal integer string ("42", "-7"), return its value.
fn canonicalIntString(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

// ---------------------------------------------------------------------------
// Numeric coercion
// ---------------------------------------------------------------------------

pub const Number = union(enum) {
    int: i64,
    float: f64,

    pub fn toFloat(self: Number) f64 {
        return switch (self) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
        };
    }
};

/// Full-string numeric check per PHP 8: optional surrounding whitespace,
/// sign, digits, optional fraction and/or exponent.
pub fn numericString(s_in: []const u8) ?Number {
    var s = std.mem.trim(u8, s_in, " \t\n\r\x0b\x0c");
    if (s.len == 0) return null;
    if (s[0] == '+' or s[0] == '-') s = s[1..];
    var mantissa_digits: usize = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) mantissa_digits += 1;
    var has_dot = false;
    if (i < s.len and s[i] == '.') {
        has_dot = true;
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) mantissa_digits += 1;
    }
    if (mantissa_digits == 0) return null;
    var has_exp = false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        var exp_digits: usize = 0;
        while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) exp_digits += 1;
        if (exp_digits > 0) {
            has_exp = true;
            i = j;
        }
    }
    if (i != s.len) return null; // trailing garbage
    if (!has_dot and !has_exp) {
        // Pure integer (possibly huge): clamp via float if it doesn't fit.
        if (std.fmt.parseInt(i64, s_in, 10)) |iv| {
            return .{ .int = iv };
        } else |_| {}
    }
    const f = std.fmt.parseFloat(f64, s) catch return null;
    return .{ .float = f };
}

/// Leading-number coercion used by arithmetic operators: reads the longest
/// numeric prefix, returns 0 when there is none (PHP semantics).
pub fn leadingNumber(s: []const u8) Number {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const digits_start = i;
    var int_val: i128 = 0;
    var int_len: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        if (int_val < 1 << 62) int_val = int_val * 10 + (s[i] - '0');
        int_len += 1;
    }
    if (i < s.len and s[i] == '.') {
        // Fractional part present -> float.
        var j = i + 1;
        var frac_digits: []const u8 = "";
        const frac_start = j;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        frac_digits = s[frac_start..j];
        if (int_len > 0 or frac_digits.len > 0) {
            var buf: [400]u8 = undefined;
            const end = @min(j + 24, s.len);
            const sub = s[digits_start..@min(end, digits_start + 380)];
            _ = &buf;
            const f = std.fmt.parseFloat(f64, sub) catch 0;
            return .{ .float = if (neg) -f else f };
        }
    }
    if (int_len == 0) return .{ .int = 0 };
    const iv: i64 = if (neg) -@as(i64, @intCast(int_val)) else @intCast(int_val);
    return .{ .int = iv };
}

/// Coerce any scalar to a number for arithmetic operations.
pub fn toNumber(v: Value, mem: std.mem.Allocator) Number {
    return switch (v) {
        .null_ => .{ .int = 0 },
        .bool_ => |b| .{ .int = @intFromBool(b) },
        .int_ => |i| .{ .int = i },
        .float_ => |f| .{ .float = f },
        .str_ => |s| leadingNumber(s),
        .rope_ => blk: {
            const s = toString(v, mem) catch break :blk .{ .int = 0 };
            break :blk leadingNumber(s);
        },
        .array_, .obj_ => .{ .int = 0 }, // callers must reject arrays/objects beforehand
    };
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn numOrder(a: f64, b: f64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    if (a == b) return .eq;
    return .eq; // NaN: treat as equal-ish (documented deviation)
}

fn strcmpOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x != y) return if (x < y) .lt else .gt;
    }
    if (a.len == b.len) return .eq;
    return if (a.len < b.len) .lt else .gt;
}

/// Loose comparison (`<`, `>`, `==`) approximating PHP 8 semantics.
pub fn looseCmp(a_in: Value, b_in: Value, mem: std.mem.Allocator) !std.math.Order {
    // Materialize ropes once; the rest of the machinery works on plain strings.
    // See strictEq for why the reassignment must be split.
    var a = a_in;
    var b = b_in;
    if (a == .rope_) {
        const s = try toString(a, mem);
        a = .{ .str_ = s };
    }
    if (b == .rope_) {
        const s = try toString(b, mem);
        b = .{ .str_ = s };
    }

    // Fast path: identical scalar types compare directly.
    if (a == .int_ and b == .int_) return std.math.order(a.int_, b.int_);
    if (a == .str_ and b == .str_) {
        // PHP 8: two numeric strings compare numerically.
        if (numericString(a.str_)) |na| {
            if (numericString(b.str_)) |nb| return numOrder(na.toFloat(), nb.toFloat());
        }
        return strcmpOrder(a.str_, b.str_);
    }

    // Booleans (and anything compared against one) compare by truthiness.
    if (a == .bool_ or b == .bool_) {
        const ta = @intFromBool(a.truthy());
        const tb = @intFromBool(b.truthy());
        return std.math.order(ta, tb);
    }

    // null vs string compares "" against the string (PHP 8).
    if (a == .null_ and b == .str_) return strcmpOrder("", b.str_);
    if (a == .str_ and b == .null_) return strcmpOrder(a.str_, "");

    // Numbers.
    const a_num = a == .int_ or a == .float_;
    const b_num = b == .int_ or b == .float_;

    if (a_num and b_num) {
        return numOrder(toNumber(a, mem).toFloat(), toNumber(b, mem).toFloat());
    }

    // null vs number -> 0
    if (a == .null_ and b_num) return numOrder(0, toNumber(b, mem).toFloat());
    if (b == .null_ and a_num) return numOrder(toNumber(a, mem).toFloat(), 0);

    // number vs string: numeric comparison iff the string is fully numeric,
    // otherwise both sides are compared as strings (PHP 8 rule).
    if (a_num and b == .str_) {
        if (numericString(b.str_)) |n| {
            return numOrder(toNumber(a, mem).toFloat(), n.toFloat());
        }
        return strcmpOrder(try toString(a, mem), b.str_);
    }
    if (a == .str_ and b_num) {
        if (numericString(a.str_)) |n| {
            return numOrder(n.toFloat(), toNumber(b, mem).toFloat());
        }
        return strcmpOrder(a.str_, try toString(b, mem));
    }

    if (a == .str_ and b == .str_) {
        // PHP 8: two numeric strings compare numerically ("10" < "9" is
        // false); otherwise byte-wise.
        if (numericString(a.str_)) |na| {
            if (numericString(b.str_)) |nb| {
                return numOrder(na.toFloat(), nb.toFloat());
            }
        }
        return strcmpOrder(a.str_, b.str_);
    }

    // Arrays.
    if (a == .array_ and b == .array_) {
        return std.math.order(a.array_.count(), b.array_.count());
    }
    if (a == .array_) return .gt;
    if (b == .array_) return .lt;

    // Objects: loose equality compares class + properties (PHP 8 rule);
    // ordering falls back to class-name comparison (documented deviation).
    if (a == .obj_ and b == .obj_) {
        const oa = a.obj_;
        const ob = b.obj_;
        if (!std.mem.eql(u8, oa.class_name, ob.class_name)) {
            return strcmpOrder(oa.class_name, ob.class_name);
        }
        if (oa.props.items.len != ob.props.items.len) {
            return std.math.order(oa.props.items.len, ob.props.items.len);
        }
        for (oa.props.items, ob.props.items) |pa, pb| {
            if (!std.mem.eql(u8, pa.name, pb.name)) return .gt;
            if (!(try looseEq(pa.val, pb.val, mem))) return .gt;
        }
        return .eq;
    }
    if (a == .obj_) return .gt;
    if (b == .obj_) return .lt;

    unreachable;
}

pub fn looseEq(a: Value, b: Value, mem: std.mem.Allocator) std.mem.Allocator.Error!bool {
    if (a == .int_ and b == .int_) return a.int_ == b.int_;
    return (try looseCmp(a, b, mem)) == .eq;
}

/// Strict equality (`===`). Arrays compare deeply and order-sensitively.
pub fn strictEq(a_in: Value, b_in: Value, mem: std.mem.Allocator) std.mem.Allocator.Error!bool {
    var a = a_in;
    var b = b_in;
    // Ropes are an internal representation; compare as strings.
    // NOTE: must not write `a = .{...toString(a)...}` in one statement:
    // result-location semantics construct the new union in place, clobbering
    // `a` before the call reads it.
    if (a == .rope_) {
        const s = try toString(a, mem);
        a = .{ .str_ = s };
    }
    if (b == .rope_) {
        const s = try toString(b, mem);
        b = .{ .str_ = s };
    }
    // PHP object identity: === compares instance pointers.
    if (a == .obj_ or b == .obj_) return a == .obj_ and b == .obj_ and a.obj_ == b.obj_;
    if (@as(std.meta.Tag(Value), a) != @as(std.meta.Tag(Value), b)) return false;
    return switch (a) {
        .null_ => true,
        .bool_ => |x| x == b.bool_,
        .int_ => |x| x == b.int_,
        .float_ => |x| x == b.float_,
        .str_ => |x| blk: {
            break :blk std.mem.eql(u8, x, b.str_);
        },
        .array_ => |x| try arraysStrictEq(x, b.array_, mem),
        else => unreachable,
    };
}

fn keyTagsMatch(a: Key, b: Key) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

fn arraysStrictEq(x: *Value.Array, y: *Value.Array, mem: std.mem.Allocator) std.mem.Allocator.Error!bool {
    if (x.count() != y.count()) return false;
    for (x.entries.items, y.entries.items) |ex, ey| {
        if (!ex.key.eql(ey.key)) return false;
        if (!keyTagsMatch(ex.key, ey.key)) return false;
        if (!(strictEq(ex.val, ey.val, mem) catch false)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "truthiness" {
    try t.expect(!(@as(Value, .null_)).truthy());
    try t.expect(!(@as(Value, .{ .int_ = 0 })).truthy());
    try t.expect((@as(Value, .{ .int_ = -1 })).truthy());
    try t.expect(!(@as(Value, .{ .str_ = "" })).truthy());
    try t.expect(!(@as(Value, .{ .str_ = "0" })).truthy());
    try t.expect((@as(Value, .{ .str_ = "0.0" })).truthy());
    try t.expect(!(@as(Value, .{ .bool_ = false })).truthy());
}

test "toString" {
    const a = t.allocator;
    const s1 = try toString(.{ .int_ = -42 }, a);
    defer a.free(s1);
    try t.expectEqualStrings("-42", s1);
    const s2 = try toString(.{ .float_ = 1.5 }, a);
    defer a.free(s2);
    try t.expectEqualStrings("1.5", s2);
    const s3 = try toString(.{ .float_ = 2.0 }, a);
    defer a.free(s3);
    try t.expectEqualStrings("2", s3);
}

test "numeric strings" {
    try t.expect(numericString("123") != null);
    try t.expect(numericString(" 12.5 ") != null);
    try t.expect(numericString("1e3") != null);
    try t.expect(numericString("abc") == null);
    try t.expect(numericString("123abc") == null);
    const n = leadingNumber("42abc");
    try t.expectEqual(@as(i64, 42), n.int);
}

test "rope strict equality" {
    const a = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const m = arena_state.allocator();
    const r1 = try Rope.cons(m, .{ .str_ = "x" }, "y");
    const r2 = try Rope.cons(m, .{ .rope_ = r1 }, "z");
    try t.expect(try strictEq(.{ .rope_ = r2 }, .{ .str_ = "xyz" }, m));
}

test "rope flatten debug" {
    const a = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const m = arena_state.allocator();
    const r1 = try Rope.cons(m, .{ .str_ = "x" }, "y");
    const flat = try r1.flatten(m);
    try t.expectEqualStrings("xy", flat);
    const r2 = try Rope.cons(m, .{ .rope_ = r1 }, "z");
    const flat2 = try r2.flatten(m);
    try t.expectEqualStrings("xyz", flat2);
    const ts = try toString(.{ .rope_ = r2 }, m);
    try t.expectEqualStrings("xyz", ts);
}

test "rope strict eq steps" {
    const a = t.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const m = arena_state.allocator();
    const r1 = try Rope.cons(m, .{ .str_ = "x" }, "y");
    const r2 = try Rope.cons(m, .{ .rope_ = r1 }, "z");
    const mat = try toString(.{ .rope_ = r2 }, m);
    try t.expectEqualStrings("xyz", mat);
    try t.expect(strictEq(.{ .str_ = mat }, .{ .str_ = "xyz" }, m) catch false);
}



test "rope strict eq dissected" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const m = arena_state.allocator();
    const r1 = try Rope.cons(m, .{ .str_ = "x" }, "y");
    const r2 = try Rope.cons(m, .{ .rope_ = r1 }, "z");
    const v1: Value = .{ .rope_ = r2 };
    const result = try strictEq(v1, .{ .str_ = "xyz" }, m);
    std.debug.print("result={}\n", .{result});
}
