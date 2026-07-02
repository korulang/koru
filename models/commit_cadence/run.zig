const std = @import("std");
const oracle = @import("oracle");
const fx = @import("model");

// Commit-cadence watchdog — LOCAL replay over koru-membrane's OWN git history.
//
// Cassette = models/commit_cadence/gitcsv.mjs (real commits, no synthesis).
// Split = the active working SESSION vs the rest, by wall-clock boundary:
//   IS  = commits from 2026-06-30T18:00:00 on (the dense active burst)
//   OOS = genesis + the post-overnight wake-up commit (the stall to catch)
// Threshold = 79 min = 1.5x the longest in-sample inter-commit gap (52.4 min).
//
// PASS contract (two ways to fail, both loud):
//   - any IN-SAMPLE fire  => the cadence/threshold model is wrong (false wake)
//   - zero OOS fires      => the watchdog can't raise the signal it exists for
// (Thin history — 6 commits — so this is a real-but-small demonstration; the
//  contract firms up as the repo accumulates commits.)

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const csv_path = "models/commit_cadence/data/series.csv";
    const bars = try loadCsv(alloc, csv_path);
    defer {
        for (bars) |b| {
            alloc.free(b.iso);
            alloc.free(b.sha);
            alloc.free(b.subject);
        }
        alloc.free(bars);
    }

    const threshold: f64 = 79; // 1.5x the in-sample max gap of 52.4 min

    var model_state: fx.State = .{};
    model_state.slider1 = threshold;
    _ = fx.init(&model_state);

    var ref: oracle.OracleState = .{ .threshold = threshold };
    var mismatch: u32 = 0;

    var is_max_gap: f64 = 0;
    var is_commits: u32 = 0;
    var oos_commits: u32 = 0;
    var false_fires: u32 = 0;
    var oos_fires: u32 = 0;
    var first_fire_idx: i64 = -1;
    var first_fire_sha: []const u8 = "(none)";
    var first_fire_subject: []const u8 = "(none)";
    var first_fire_gap: f64 = 0;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    try out.writeAll("idx  slice  gap_min  alarm  sha           subject\n");
    try out.writeAll("---  -----  -------  -----  ------------  -------\n");

    for (bars) |bar| {
        model_state.gap_min = bar.gap_min;
        _ = fx.block(&model_state);

        const ref_out = oracle.step(&ref, bar);
        if (@abs(model_state.alarm - ref_out.alarm) > 1e-9) mismatch += 1;

        const fired = model_state.alarm >= 0.5;

        if (bar.in_sample) {
            is_commits += 1;
            if (bar.gap_min > is_max_gap) is_max_gap = bar.gap_min;
            if (fired) false_fires += 1;
        } else {
            oos_commits += 1;
            if (fired) {
                oos_fires += 1;
                if (first_fire_idx < 0) {
                    first_fire_idx = @intCast(bar.idx);
                    first_fire_sha = bar.sha;
                    first_fire_subject = bar.subject;
                    first_fire_gap = bar.gap_min;
                }
            }
        }

        const slice = if (bar.in_sample) "IS " else "OOS";
        try out.print("{d:3}  {s}  {d:7.1}  {d:5.0}  {s}  {s}\n", .{
            bar.idx, slice, bar.gap_min, model_state.alarm, bar.sha, bar.subject,
        });
    }

    try out.writeAll("\n--- commit-cadence watchdog stats ---\n");
    try out.print("in-sample commits:   {d}   (longest in-sample gap = {d:.1} min)\n", .{ is_commits, is_max_gap });
    try out.print("out-of-sample commits: {d}\n", .{oos_commits});
    try out.print("threshold:           {d:.0} min   (= 1.5x in-sample max gap)\n", .{threshold});
    try out.print("in-sample FALSE fires: {d}   (must be 0)\n", .{false_fires});
    try out.print("out-of-sample fires:   {d}\n", .{oos_fires});
    if (first_fire_idx >= 0) {
        try out.print("FIRST OOS fire: idx {d}  gap {d:.1} min  claim_id(sha)={s}\n", .{ first_fire_idx, first_fire_gap, first_fire_sha });
        try out.print("  → woke us at: \"{s}\"\n", .{first_fire_subject});
    }
    try out.print("oracle mismatches: {d}\n", .{mismatch});
    try out.flush();

    if (mismatch > 0) {
        std.debug.print("FAIL: model diverged from oracle on {d} bar(s)\n", .{mismatch});
        return error.OracleMismatch;
    }
    if (threshold <= is_max_gap) {
        std.debug.print("FAIL: threshold {d:.0} <= in-sample max gap {d:.1} — guaranteed false fire\n", .{ threshold, is_max_gap });
        return error.ThresholdBelowCadence;
    }
    if (false_fires > 0) {
        std.debug.print("FAIL: watchdog raised {d} false fire(s) on the active in-sample session\n", .{false_fires});
        return error.FalseFire;
    }
    if (oos_fires == 0) {
        std.debug.print("FAIL: watchdog stayed silent across OOS — no real stall caught\n", .{});
        return error.MissedStall;
    }

    std.debug.print("commit-cadence: PASS (0 in-sample false fires; {d} OOS fire(s); first OOS fire idx {d} gap {d:.0}min > threshold {d:.0}min, claim_id={s}; oracle ok)\n", .{
        oos_fires, first_fire_idx, first_fire_gap, threshold, first_fire_sha,
    });
}

fn loadCsv(alloc: std.mem.Allocator, path: []const u8) ![]oracle.Bar {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024);
    defer alloc.free(raw);

    var list: std.ArrayList(oracle.Bar) = .{};
    errdefer {
        for (list.items) |b| {
            alloc.free(b.iso);
            alloc.free(b.sha);
            alloc.free(b.subject);
        }
        list.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next(); // header

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        var it = std.mem.splitScalar(u8, trimmed, ',');
        const idx_s = it.next() orelse continue;
        const iso = it.next() orelse continue;
        const gap_s = it.next() orelse continue;
        const files_s = it.next() orelse continue;
        const ins_s = it.next() orelse continue;
        const del_s = it.next() orelse continue;
        const sha = it.next() orelse continue;
        const subject = it.rest();

        const idx = try std.fmt.parseInt(u32, idx_s, 10);
        const gap_min = try std.fmt.parseFloat(f64, gap_s);
        const files = try std.fmt.parseInt(u32, files_s, 10);
        const ins = try std.fmt.parseInt(u32, ins_s, 10);
        const del = try std.fmt.parseInt(u32, del_s, 10);

        // IS = the active working session (from 18:00 on 06-30). The genesis and
        // the post-overnight wake-up commit (carrying the stall gap) are OOS.
        const in_sample = !std.mem.lessThan(u8, iso, "2026-06-30T18:00:00");

        try list.append(alloc, .{
            .idx = idx,
            .iso = try alloc.dupe(u8, iso),
            .gap_min = gap_min,
            .files = files,
            .ins = ins,
            .del = del,
            .sha = try alloc.dupe(u8, sha),
            .subject = try alloc.dupe(u8, subject),
            .in_sample = in_sample,
        });
    }

    return try list.toOwnedSlice(alloc);
}
