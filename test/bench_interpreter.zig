// Benchmark: interpreter runSourceFast vs runSource (full parser)
// Measures end-to-end eval path including parsing + execution.

const std = @import("std");
const interpreter = @import("interpreter");
const parser = @import("parser");
const errors = @import("errors");
const flow_parser = @import("flow_parser");

const ITERATIONS: u64 = 200_000;

const SOURCE =
    "~add(a: 3, b: 4)\n" ++
    "    | ok r |> result { value: r }\n";

fn dispatchAdd(_: *const @import("ast").Invocation, out: *interpreter.DispatchResult) anyerror!void {
    const fields = &[_]interpreter.NamedField{
        .{ .name = "r", .value = .{ .int_val = 7 } },
    };
    out.branch = "ok";
    out.fields = fields;
}

fn benchRunSourceFast() f64 {
    const start = std.time.nanoTimestamp();
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        const result = interpreter.runSourceFast(SOURCE, &dispatchAdd, parser, errors, parser);
        switch (result) {
            .result => {},
            else => return 0,
        }
    }
    const end = std.time.nanoTimestamp();
    return printStage("runSourceFast", start, end);
}

fn benchRunSourceFastCached() f64 {
    const start = std.time.nanoTimestamp();
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        const result = interpreter.runSourceFastCached(SOURCE, &dispatchAdd, parser, errors, parser);
        switch (result) {
            .result => {},
            else => return 0,
        }
    }
    const end = std.time.nanoTimestamp();
    return printStage("runSourceFastCached", start, end);
}

fn benchRunSource() f64 {
    const start = std.time.nanoTimestamp();
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        const result = interpreter.runSource(SOURCE, &dispatchAdd, parser, errors);
        switch (result) {
            .result => {},
            else => return 0,
        }
    }
    const end = std.time.nanoTimestamp();
    return printStage("runSource", start, end);
}

fn printStage(name: []const u8, start: i128, end: i128) f64 {
    const elapsed_ns: u64 = @intCast(end - start);
    const per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
    const ops_per_sec = 1_000_000_000.0 / per_op;
    std.debug.print("  {s: <14} {d:>8.0} ns/op | {d:>9.0} ops/sec\n", .{ name, per_op, ops_per_sec });
    return ops_per_sec;
}

pub fn main() void {
    std.debug.print("\nInterpreter Benchmark ({d} iterations)\n", .{ITERATIONS});
    std.debug.print("============================================================\n", .{});

    // Ensure fast path can parse the source
    switch (flow_parser.parseFlow(std.heap.page_allocator, SOURCE)) {
        .flow => {},
        .err => |e| {
            std.debug.print("flow_parser failed: {s} (line {d})\n", .{ e.message, e.line });
            return;
        },
    }

    // Warmup
    _ = interpreter.runSourceFast(SOURCE, &dispatchAdd, parser, errors, parser);

    const cached_ops = benchRunSourceFastCached();
    const fast_ops = benchRunSourceFast();
    const full_ops = benchRunSource();

    if (cached_ops > 0 and full_ops > 0) {
        const speedup = cached_ops / full_ops;
        std.debug.print("  Cached speedup: {d:.2}x\n", .{speedup});
    }
    if (fast_ops > 0 and full_ops > 0) {
        const speedup = fast_ops / full_ops;
        std.debug.print("  Fast speedup:   {d:.2}x\n", .{speedup});
    }

    std.debug.print("============================================================\n", .{});
}
