// Hand-written Zig baseline for loop optimization test
// This is what the Koru optimizer SHOULD generate from the checker event pattern

const std = @import("std");

pub fn main() !void {
    var sum: u64 = 0;

    // Native for loop - what the optimizer should emit
    for (0..10_000_000) |i| {
        sum += i;
    }

    std.debug.print("Sum: {}\n", .{sum});
}
