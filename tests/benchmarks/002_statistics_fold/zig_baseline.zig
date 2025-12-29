// Benchmark: Compute 5 statistics in a single pass - hand-written Zig
// Computes: sum, sum_of_squares, count, min, max
// Then derives: mean, variance

const std = @import("std");

pub fn main() void {
    // Get N from command line to prevent compile-time optimization
    var args = std.process.args();
    _ = args.next(); // skip program name

    const n_str = args.next() orelse "100000000";
    const N: usize = std.fmt.parseInt(usize, n_str, 10) catch 100000000;

    var sum: i64 = 0;
    var sum_sq: i64 = 0;
    var count: i64 = 0;
    var min_val: i64 = std.math.maxInt(i64);
    var max_val: i64 = std.math.minInt(i64);

    for (1..N + 1) |i| {
        const x: i64 = @intCast(i);
        sum += x;
        sum_sq += x * x;
        count += 1;
        if (x < min_val) min_val = x;
        if (x > max_val) max_val = x;
    }

    const mean: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
    const variance: f64 = (@as(f64, @floatFromInt(sum_sq)) / @as(f64, @floatFromInt(count))) - (mean * mean);

    std.debug.print("Zig baseline stats:\n", .{});
    std.debug.print("  sum:      {d}\n", .{sum});
    std.debug.print("  count:    {d}\n", .{count});
    std.debug.print("  min:      {d}\n", .{min_val});
    std.debug.print("  max:      {d}\n", .{max_val});
    std.debug.print("  mean:     {d:.6}\n", .{mean});
    std.debug.print("  variance: {d:.6}\n", .{variance});
}
