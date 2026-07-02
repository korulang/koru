const std = @import("std");

// One bar = one real git commit (the WORK faucet of the dev harness).
pub const Bar = struct {
    idx: u32,
    iso: []const u8,
    gap_min: f64, // minutes since the previous commit (the silence before this one)
    files: u32,
    ins: u32,
    del: u32,
    sha: []const u8,
    subject: []const u8,
    in_sample: bool, // split decided BEFORE looking at divergence
};

pub const OracleState = struct {
    threshold: f64 = 90,
};

pub const OracleOut = struct {
    alarm: f64,
};

pub fn step(s: *OracleState, bar: Bar) OracleOut {
    // Mirrors model.wmfx exactly: the gap that just elapsed before this commit,
    // compared against the learned in-sample cadence ceiling.
    const alarm: f64 = if (bar.gap_min >= s.threshold) 1 else 0;
    return .{ .alarm = alarm };
}
