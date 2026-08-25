//! Builtin function library for zphp — intentionally near-empty for now.
//!
//! This module is the single extension point for native functions. To add
//! one: write `fn my_fn(in: *Interp, args: []const Value) Error!Value`,
//! register it in the `table` map below, done. Argument validation helpers
//! will grow here as the library does.

const std = @import("std");
const valmod = @import("value.zig");
const interp_mod = @import("interp.zig");

const Interp = interp_mod.Interp;
const Value = valmod.Value;
const Error = interp_mod.Error;

const BuiltinFn = *const fn (in: *Interp, args: []const Value) Error!Value;

// TODO(builtins): populate the standard library (string/array/math/type
// functions). See docs/roadmap in README.md.

const table = std.StaticStringMap(BuiltinFn).initComptime(.{
    // .{ "strlen", &fn_strlen },  -- example of the registration format
});

/// Returns null if `name` is not a builtin (caller raises "undefined function").
pub fn call(in: *Interp, name: []const u8, args: []const Value, line: u32) Error!?Value {
    _ = line;
    const f = table.get(name) orelse return null;
    return try f(in, args);
}
