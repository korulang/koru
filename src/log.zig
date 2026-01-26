const std = @import("std");

/// Log levels for compiler output
pub const Level = enum(u2) {
    silent = 0, // Only errors
    normal = 1, // Errors + warnings (default)
    verbose = 2, // Errors + warnings + info
    debug = 3, // Everything
};

/// Global log level - set at startup from CLI flags
pub var level: Level = .normal;

/// Initialize from CLI flags
pub fn init(has_verbose: bool, has_debug: bool) void {
    if (has_debug) {
        level = .debug;
    } else if (has_verbose) {
        level = .verbose;
    } else {
        level = .normal;
    }
}

/// Debug output (--debug only)
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (level == .debug) {
        std.debug.print(fmt, args);
    }
}

/// Verbose output (--verbose or --debug)
pub fn verbose(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) >= @intFromEnum(Level.verbose)) {
        std.debug.print(fmt, args);
    }
}

/// Info output (always shown unless --silent)
pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) >= @intFromEnum(Level.normal)) {
        std.debug.print(fmt, args);
    }
}

/// Error output (always shown)
pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}
