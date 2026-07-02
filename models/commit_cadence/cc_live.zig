const std = @import("std");
const fx = @import("model");

// cc_live — ONE-TICK live eval of the commit-cadence model THROUGH the engine.
// The commit-msg hook feeds it this commit's gap_min; it runs the engine-compiled
// @block and prints "<gap> <alarm>". This is the real model running per commit —
// never a re-implementation of the threshold rule.
//
//   cc_live <gap_min> [threshold]   ->   "<gap_min> <alarm 0|1>"

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // argv[0]
    const gap_s = args.next() orelse usage();
    const gap = std.fmt.parseFloat(f64, gap_s) catch usage();
    const threshold: f64 = if (args.next()) |t| (std.fmt.parseFloat(f64, t) catch 79) else 79;

    var st: fx.State = .{};
    st.slider1 = threshold; // the characterized in-sample cadence ceiling
    _ = fx.init(&st);
    st.gap_min = gap;
    _ = fx.block(&st);

    var stdout_buffer: [128]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("{d:.1} {d:.0}\n", .{ gap, st.alarm });
    try out.flush();
}

fn usage() noreturn {
    std.debug.print("usage: cc_live <gap_min> [threshold]\n", .{});
    std.process.exit(2);
}
