// Hand-written Zig baseline for loop with work body optimization test
// This is what the Koru optimizer SHOULD generate with work event inlined

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const array = try allocator.alloc(u64, 10_000);
    defer allocator.free(array);

    // Initialize array
    var i: u64 = 0;
    while (i < 10_000) : (i += 1) {
        array[i] = i;
    }

    // Process loop with inlined work body
    var sum: u64 = 0;
    for (array) |value| {
        const squared = value * value;
        sum += squared;
    }

    std.debug.print("Sum: {}\n", .{sum});
}
