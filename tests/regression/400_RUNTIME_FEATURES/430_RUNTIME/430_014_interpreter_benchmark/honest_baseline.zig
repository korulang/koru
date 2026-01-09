const std = @import("std");

fn add_handler(a: i64, b: i64) i64 { return a + b; }
fn mul_handler(a: i64, b: i64) i64 { return a * b; }
fn sub_handler(a: i64, b: i64) i64 { return a - b; }
fn div_handler(a: i64, b: i64) i64 { return if (b != 0) @divTrunc(a, b) else 0; }

pub fn main() void {
    const ITERATIONS: u64 = 10_000_000;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    
    const start = std.time.nanoTimestamp();

    var sum: i64 = 0;
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        const event_idx = random.intRangeAtMost(usize, 0, 3);
        const a = random.intRangeAtMost(i64, 1, 100);
        const b = random.intRangeAtMost(i64, 1, 100);
        
        // Direct switch - no string matching, no dispatch overhead
        const result = switch (event_idx) {
            0 => add_handler(a, b),
            1 => mul_handler(a, b),
            2 => sub_handler(a, b),
            3 => div_handler(a, b),
            else => 0,
        };
        sum += result;
    }
    
    const end = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(ITERATIONS)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
    
    std.debug.print("HONEST baseline: {d:.2}ms, {d:.0} ops/sec, sum={d}\n", .{elapsed_ms, ops_per_sec, sum});
}
