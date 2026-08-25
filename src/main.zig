//! zphp — a minimal PHP interpreter written in Zig, in the spirit of
//! QuickJS: small, dependency-free, single binary.
//!
//! Usage:
//!   zphp script.php [args...]
//!   zphp -r "echo 'hello';"
//!   zphp --version | --help

const std = @import("std");
const tokmod = @import("token.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const interp_mod = @import("interp.zig");

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [16 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &fw.interface;

    // ---- argument parsing --------------------------------------------------
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // skip program name

    var script_path: ?[]const u8 = null;
    var inline_code: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--run")) {
            inline_code = args_it.next() orelse {
                try errPrint("zphp: {s} requires an argument\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try out.print("zphp 0.1.0 (minimal PHP interpreter)\n", .{});
            try out.flush();
            return 0;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try out.print(
                \\Usage:
                \\  zphp <script.php>      run a PHP script
                \\  zphp -r "<code>"       run inline PHP code
                \\  zphp -v                show version
                \\
            , .{});
            try out.flush();
            return 0;
        } else if (script_path == null and inline_code == null) {
            script_path = arg;
        } else {
            try errPrint("zphp: unexpected argument '{s}'\n", .{arg});
            return 2;
        }
    }

    // ---- read source ---------------------------------------------------------
    const arena = init.arena.allocator();

    var display_name: []const u8 = "Command line code";
    const source: []const u8 = blk: {
        if (inline_code) |code| {
            break :blk try std.fmt.allocPrint(arena, "<?php {s}", .{code});
        }
        const path = script_path orelse {
            try errPrint("zphp: no input file (try `zphp --help`)\n", .{});
            return 2;
        };
        display_name = path;
        break :blk std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(256 * 1024 * 1024)) catch |e| {
            try errPrint("zphp: failed to open '{s}': {s}\n", .{ path, @errorName(e) });
            return 2;
        };
    };

    // ---- compile & run -------------------------------------------------------
    var lx = lexer.Lexer.init(source);
    const tokens = lx.tokenize(arena) catch |e| {
        try errPrint("Parse error: {s} in {s}\n", .{ lexerErrorName(e), display_name });
        try out.flush();
        return 255;
    };

    var diag: parser.Diag = .{};
    const program = parser.parse(arena, tokens, &diag) catch |e| switch (e) {
        error.SyntaxError => {
            try errPrint("Parse error: {s} in {s} on line {d}\n", .{ diag.msg, display_name, diag.line });
            try out.flush();
            return 255;
        },
        error.OutOfMemory => {
            try errPrint("zphp: out of memory\n", .{});
            return 255;
        },
    };

    var interp = interp_mod.Interp.init(arena, out);
    try interp.registerTopLevelFuncs(program);

    interp.execProgram(program) catch |e| switch (e) {
        error.Fatal => {
            try out.flush();
            try errPrint("PHP Fatal error: Uncaught Error: {s} in {s}:{d}\n", .{ interp.msg, display_name, interp.line });
            try out.print("PHP Fatal error: Uncaught Error: {s} in {s}:{d}\n", .{ interp.msg, display_name, interp.line });
            try out.flush();
            return 255;
        },
        error.OutOfMemory => {
            try errPrint("zphp: out of memory\n", .{});
            return 255;
        },
        else => {
            try errPrint("zphp: internal error: {s}\n", .{@errorName(e)});
            return 70;
        },
    };

    try out.flush();
    return 0;
}

fn lexerErrorName(e: lexer.Error) []const u8 {
    return switch (e) {
        error.MissingOpenTag => "missing opening <?php tag",
        error.UnexpectedCharacter => "unexpected character",
        error.UnterminatedString => "unterminated string literal",
        error.UnterminatedComment => "unterminated block comment",
        error.OutOfMemory => "out of memory",
    };
}

fn errPrint(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print(fmt, args);
}
