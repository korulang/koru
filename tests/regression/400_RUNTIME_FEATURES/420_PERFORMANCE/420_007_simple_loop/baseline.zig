// Hand-written Zig baseline for label loops
// This is what Koru label loops (#/@) SHOULD compile to
//
// Tests:
// 1. Live loop (sum 0 to 1M) - should be optimized well
// 2. Dead loop (unused result) - should be eliminated entirely

const std = @import("std");

fn count_to_million() u64 {
    var sum: u64 = 0;
    var i: u64 = 0;
    while (i < 10_000_000) : (i += 1) {
        sum += i;
    }
    return sum;
}

// Dead loop - compiler should eliminate this entirely
fn dead_loop() void {
    var i: u64 = 0;
    while (i < 1_000_000) : (i += 1) {
        // Do nothing
    }
}

pub fn main() !void {
    // Live loop
    const result = count_to_million();
    std.debug.print("Sum: {}\n", .{result});

    // Dead loop - result unused
    // In -O ReleaseFast, Zig should eliminate this entirely
    dead_loop();
}
