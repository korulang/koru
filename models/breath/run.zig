const std = @import("std");
const oracle = @import("oracle");
const fx = @import("model");

// Breath watcher — LOCAL replay over koru's OWN regression-snapshot history.
//
// Cassette = models/breath/faucet.mjs (real test-results/*.json, no synthesis).
// Split = calendar, fixed in data/split.json BEFORE looking at divergence:
//   IS  = snapshots before 2026-05-01 (the Jan–Apr bring-up)
//   OOS = snapshots from 2026-05-01 onward (the mature period)
// depth_floor = 8pp, dur_threshold = 18 = 1.5x the longest IN-SAMPLE sustained
// dip run (12 ticks). Both are DESIGN CONSTANTS, frozen before replay.
//
// PASS contract (loud both ways):
//   - any IN-SAMPLE fire  => the breath/threshold model is wrong (false wake)
//   - zero OOS fires      => the watcher can't raise the signal it exists for
//   - any oracle mismatch => the transpiled model diverged from its mirror
// The honest win: 0 in-sample false fires, an OOS fire on the real long inhale.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const csv_path = "models/breath/data/series.csv";
    const bars = try loadCsv(alloc, csv_path);
    defer {
        for (bars) |b| alloc.free(b.iso);
        alloc.free(bars);
    }

    var model_state: fx.State = .{};
    _ = fx.init(&model_state); // sets peak=0, dip_ticks=0, depth_floor=8, dur_threshold=18

    var ref: oracle.OracleState = .{};
    var mismatch: u32 = 0;

    var is_bars: u32 = 0;
    var oos_bars: u32 = 0;
    var is_max_dip: f64 = 0; // longest in-sample sustained-dip run (characterization)
    var false_fires: u32 = 0; // alarm in-sample — must be 0
    var oos_fires: u32 = 0; // alarm out-of-sample — must be >= 1
    var first_fire_idx: i64 = -1;
    var first_fire_iso: []const u8 = "(none)";
    var first_fire_rate: f64 = 0;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("idx  slice  rate%  dip  alarm  iso\n");
    try out.writeAll("---  -----  -----  ---  -----  ---\n");

    for (bars) |bar| {
        model_state.pass_rate = bar.pass_rate;
        _ = fx.block(&model_state);

        const ref_out = oracle.step(&ref, bar);
        if (@abs(model_state.alarm - ref_out.alarm) > 1e-9) mismatch += 1;
        if (@abs(model_state.dip_ticks - ref_out.dip_ticks) > 1e-9) mismatch += 1;

        const fired = model_state.alarm >= 0.5;

        if (bar.in_sample) {
            is_bars += 1;
            if (model_state.dip_ticks > is_max_dip) is_max_dip = model_state.dip_ticks;
            if (fired) false_fires += 1;
        } else {
            oos_bars += 1;
            if (fired) {
                oos_fires += 1;
                if (first_fire_idx < 0) {
                    first_fire_idx = @intCast(bar.idx);
                    first_fire_iso = bar.iso;
                    first_fire_rate = bar.pass_rate;
                }
            }
        }

        // Print every fire, plus the first OOS bar, for legibility.
        if (fired) {
            const slice = if (bar.in_sample) "IS " else "OOS";
            try out.print("{d:3}  {s}  {d:5.1}  {d:3.0}  {d:5.0}  {s}\n", .{
                bar.idx, slice, bar.pass_rate, model_state.dip_ticks, model_state.alarm, bar.iso,
            });
        }
    }

    try out.writeAll("\n--- breath watcher stats ---\n");
    try out.print("in-sample snapshots:   {d}   (longest in-sample dip run = {d:.0} ticks)\n", .{ is_bars, is_max_dip });
    try out.print("out-of-sample snapshots: {d}\n", .{oos_bars});
    try out.print("depth_floor: 8pp   dur_threshold: 18 ticks (= 1.5x in-sample max dip run)\n", .{});
    try out.print("in-sample FALSE fires: {d}   (must be 0)\n", .{false_fires});
    try out.print("out-of-sample fires:   {d}\n", .{oos_fires});
    if (first_fire_idx >= 0) {
        try out.print("FIRST OOS fire: idx {d}  rate {d:.1}%  at {s}\n", .{ first_fire_idx, first_fire_rate, first_fire_iso });
        try out.print("  -> the long inhale: pass-rate held >= 8pp below its peak past any in-sample breath\n", .{});
    }
    try out.print("oracle mismatches: {d}\n", .{mismatch});
    try out.flush();

    if (mismatch > 0) {
        std.debug.print("FAIL: model diverged from oracle on {d} check(s)\n", .{mismatch});
        return error.OracleMismatch;
    }
    if (18 <= is_max_dip) {
        std.debug.print("FAIL: dur_threshold 18 <= in-sample max dip run {d:.0} — guaranteed false fire\n", .{is_max_dip});
        return error.ThresholdBelowCadence;
    }
    if (false_fires > 0) {
        std.debug.print("FAIL: watcher raised {d} false fire(s) on the in-sample bring-up — breath model wrong\n", .{false_fires});
        return error.FalseFire;
    }
    if (oos_fires == 0) {
        std.debug.print("FAIL: watcher stayed silent across OOS — no sustained inhale caught\n", .{});
        return error.MissedInhale;
    }

    std.debug.print("breath: PASS (0 in-sample false fires; {d} OOS fire(s); first OOS fire idx {d} rate {d:.1}%; oracle ok)\n", .{
        oos_fires, first_fire_idx, first_fire_rate,
    });
}

fn loadCsv(alloc: std.mem.Allocator, path: []const u8) ![]oracle.Bar {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024);
    defer alloc.free(raw);

    var list: std.ArrayList(oracle.Bar) = .{};
    errdefer {
        for (list.items) |b| alloc.free(b.iso);
        list.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next(); // header: idx,iso,pass_rate,passed,inScope,failed,todo

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        var it = std.mem.splitScalar(u8, trimmed, ',');
        const idx_s = it.next() orelse continue;
        const iso = it.next() orelse continue;
        const rate_s = it.next() orelse continue;
        const passed_s = it.next() orelse continue;
        const scope_s = it.next() orelse continue;
        const failed_s = it.next() orelse continue;
        const todo_s = it.next() orelse continue;

        const idx = try std.fmt.parseInt(u32, idx_s, 10);
        const pass_rate = try std.fmt.parseFloat(f64, rate_s);
        const passed = try std.fmt.parseInt(u32, passed_s, 10);
        const in_scope = try std.fmt.parseInt(u32, scope_s, 10);
        const failed = try std.fmt.parseInt(u32, failed_s, 10);
        const todo = try std.fmt.parseInt(u32, todo_s, 10);

        // Calendar split (fixed in split.json BEFORE seeing divergence):
        // IS = snapshots before 2026-05-01; OOS = 2026-05-01 onward.
        const in_sample = std.mem.lessThan(u8, iso, "2026-05-01");

        try list.append(alloc, .{
            .idx = idx,
            .iso = try alloc.dupe(u8, iso),
            .pass_rate = pass_rate,
            .passed = passed,
            .in_scope = in_scope,
            .failed = failed,
            .todo = todo,
            .in_sample = in_sample,
        });
    }

    return try list.toOwnedSlice(alloc);
}
