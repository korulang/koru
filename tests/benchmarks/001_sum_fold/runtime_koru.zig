// Direct Zig version with RUNTIME N to prevent compile-time folding
const std = @import("std");

pub fn main() void {
    // Get N from command line to prevent compile-time optimization
    var args = std.process.args();
    _ = args.next(); // skip program name

    const n_str = args.next() orelse "100000000";
    const N: usize = std.fmt.parseInt(usize, n_str, 10) catch 100000000;

    var sum: i64 = 0;
    for (0..N) |i| {
        sum += @as(i64, @intCast(i)) + 1;
    }

    std.debug.print("Zig runtime sum: {d}\n", .{sum});
}
