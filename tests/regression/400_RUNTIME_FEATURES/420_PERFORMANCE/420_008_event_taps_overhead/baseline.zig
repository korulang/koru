// Hand-written Zig baseline with manual instrumentation
// Simulates what event taps compile to: function calls at emission sites

const std = @import("std");

var tap_count: u64 = 0;

// Simulates the tap function
fn tap_point(i: u64) void {
    tap_count += 1;
    // Touch parameter to avoid unused warning
    if (i > 999_999_999) {
        std.debug.print("Impossible\n", .{});
    }
}

fn count_with_taps() void {
    var i: u64 = 0;
    while (i < 1_000_000) : (i += 1) {
        // Manual "taps" - function calls at the same points Koru taps would fire
        if (i % 200_000 == 0) tap_point(i);
        if (i % 200_001 == 0) tap_point(i);
        if (i % 200_002 == 0) tap_point(i);
        if (i % 200_003 == 0) tap_point(i);
        if (i % 200_004 == 0) tap_point(i);
    }
}

pub fn main() !void {
    count_with_taps();
    std.debug.print("Taps called: {}\n", .{tap_count});
}
