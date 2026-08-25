//! Test aggregator: pulls in unit tests from every module and provides
//! integration tests that run complete PHP snippets end-to-end.

const std = @import("std");

comptime {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("value.zig");
    _ = @import("interp.zig");
    _ = @import("test_lexer.zig");
    _ = @import("test_parser.zig");
    _ = @import("tests_impl.zig");
    _ = @import("test_register.zig");
}
