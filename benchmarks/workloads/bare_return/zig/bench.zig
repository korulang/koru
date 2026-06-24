const std = @import("std");

fn mix(x: u64) u64 {
    return x *% 6364136223846793005 +% 1442695040888963407;
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const n: u64 = if (args.next()) |a| (std.fmt.parseInt(u64, a, 10) catch 1_000_000) else 1_000_000;
    var acc: u64 = 1;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        acc = mix(acc);
    }
    std.debug.print("result = {d}\n", .{acc});
}
