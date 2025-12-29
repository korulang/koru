// Hand-written Zig baseline for nested loop optimization test
// This is what the Koru optimizer SHOULD generate from nested checker event patterns

const std = @import("std");

pub fn main() !void {
    var sum: u64 = 0;

    // Nested loops - triangular pattern (inner depends on outer)
    var i: u64 = 0;
    while (i < 5000) : (i += 1) {
        var j: u64 = i + 1;
        while (j < 5000) : (j += 1) {
            sum += i * 5000 + j;
        }
    }

    std.debug.print("Sum: {}\n", .{sum});
}
