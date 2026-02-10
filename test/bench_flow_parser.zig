// Benchmark: flow_parser vs full Parser on typical eval input
//
// Two modes:
//   A) Realistic: fresh arena per iteration (matches eval endpoint behavior)
//   B) Isolated: shared arena, measures pure parsing logic
//
// This isolates the exact overhead we're eliminating.

const std = @import("std");
const flow_parser = @import("flow_parser");
const koru_parser = @import("parser");
const koru_errors = @import("errors");

const ITERATIONS: u64 = 50_000;

// The canonical 3-line eval flow from the blog post
const SIMPLE_SOURCE = "~add(a: 3, b: 4)";

const MULTI_LINE_SOURCE =
    \\~add(a: 3, b: 4)
    \\    | sum s |> add(a: s, b: 10)
    \\        | sum s2 |> result { value: s2 }
;

const BRANCHING_SOURCE =
    \\~divide(a: 10, b: 2)
    \\    | ok result |> format(value: result)
    \\    | error e |> fail { message: e }
;

// ============================================================================
// A) Realistic: fresh arena per iteration
// ============================================================================

fn benchFullParserRealistic(source: []const u8, label: []const u8) f64 {
    const start = std.time.nanoTimestamp();

    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var reporter = koru_errors.ErrorReporter.init(allocator, "bench", source) catch continue;
        defer reporter.deinit();

        var parser = koru_parser.Parser.init(allocator, source, "bench", &[_][]const u8{}, null) catch continue;
        defer parser.deinit();

        _ = parser.parse() catch continue;
    }

    const end = std.time.nanoTimestamp();
    return printResult("Full Parser", label, start, end);
}

fn benchFlowParserRealistic(source: []const u8, label: []const u8) f64 {
    const start = std.time.nanoTimestamp();

    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const result = flow_parser.parseFlow(allocator, source);
        switch (result) {
            .flow => {},
            .err => |e| {
                std.debug.print("  ERROR: {s}\n", .{e.message});
                return 0;
            },
        }
    }

    const end = std.time.nanoTimestamp();
    return printResult("Flow Parser", label, start, end);
}

// ============================================================================
// B) Isolated: shared arena (reset per iteration)
// ============================================================================

fn benchFullParserIsolated(source: []const u8, label: []const u8) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.time.nanoTimestamp();

    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        var reporter = koru_errors.ErrorReporter.init(allocator, "bench", source) catch continue;
        _ = &reporter;

        var parser = koru_parser.Parser.init(allocator, source, "bench", &[_][]const u8{}, null) catch continue;
        _ = &parser;

        _ = parser.parse() catch continue;
    }

    const end = std.time.nanoTimestamp();
    return printResult("Full Parser", label, start, end);
}

fn benchFlowParserIsolated(source: []const u8, label: []const u8) f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.time.nanoTimestamp();

    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        const result = flow_parser.parseFlow(allocator, source);
        switch (result) {
            .flow => {},
            .err => |e| {
                std.debug.print("  ERROR: {s}\n", .{e.message});
                return 0;
            },
        }
    }

    const end = std.time.nanoTimestamp();
    return printResult("Flow Parser", label, start, end);
}

// ============================================================================
// Output
// ============================================================================

fn printResult(parser_name: []const u8, label: []const u8, start: i128, end: i128) f64 {
    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(ITERATIONS)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));

    std.debug.print("  {s: <12} [{s: <7}] {d:>8.1}ms | {d:>9.0} ops/sec | {d:>6.0} ns/op\n", .{
        parser_name, label, elapsed_ms, ops_per_sec, per_op_ns,
    });
    return ops_per_sec;
}

fn printSpeedup(flow_ops: f64, full_ops: f64) void {
    if (full_ops > 0) {
        const speedup = flow_ops / full_ops;
        std.debug.print("  Speedup: {d:.2}x\n", .{speedup});
    }
}

pub fn main() void {
    std.debug.print("\n", .{});
    std.debug.print("Flow Parser Benchmark ({d} iterations each)\n", .{ITERATIONS});
    std.debug.print("============================================================\n", .{});

    // Warm up both paths
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        _ = flow_parser.parseFlow(arena.allocator(), SIMPLE_SOURCE);
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var reporter = koru_errors.ErrorReporter.init(allocator, "warmup", SIMPLE_SOURCE) catch unreachable;
        _ = &reporter;
        var parser = koru_parser.Parser.init(allocator, SIMPLE_SOURCE, "warmup", &[_][]const u8{}, null) catch unreachable;
        _ = parser.parse() catch {};
    }

    // ----------------------------------------------------------------
    std.debug.print("\nA) REALISTIC (fresh arena per call — matches eval endpoint)\n", .{});
    std.debug.print("------------------------------------------------------------\n", .{});

    std.debug.print("\n  Simple: ~add(a: 3, b: 4)\n", .{});
    const r1_flow = benchFlowParserRealistic(SIMPLE_SOURCE, "simple");
    const r1_full = benchFullParserRealistic(SIMPLE_SOURCE, "simple");
    printSpeedup(r1_flow, r1_full);

    std.debug.print("\n  Nested (3 lines with continuations):\n", .{});
    const r2_flow = benchFlowParserRealistic(MULTI_LINE_SOURCE, "nested");
    const r2_full = benchFullParserRealistic(MULTI_LINE_SOURCE, "nested");
    printSpeedup(r2_flow, r2_full);

    std.debug.print("\n  Branching (2 continuations):\n", .{});
    const r3_flow = benchFlowParserRealistic(BRANCHING_SOURCE, "branch");
    const r3_full = benchFullParserRealistic(BRANCHING_SOURCE, "branch");
    printSpeedup(r3_flow, r3_full);

    // ----------------------------------------------------------------
    std.debug.print("\nB) ISOLATED (shared arena — pure parsing logic)\n", .{});
    std.debug.print("------------------------------------------------------------\n", .{});

    std.debug.print("\n  Simple: ~add(a: 3, b: 4)\n", .{});
    const i1_flow = benchFlowParserIsolated(SIMPLE_SOURCE, "simple");
    const i1_full = benchFullParserIsolated(SIMPLE_SOURCE, "simple");
    printSpeedup(i1_flow, i1_full);

    std.debug.print("\n  Nested (3 lines with continuations):\n", .{});
    const i2_flow = benchFlowParserIsolated(MULTI_LINE_SOURCE, "nested");
    const i2_full = benchFullParserIsolated(MULTI_LINE_SOURCE, "nested");
    printSpeedup(i2_flow, i2_full);

    std.debug.print("\n  Branching (2 continuations):\n", .{});
    const i3_flow = benchFlowParserIsolated(BRANCHING_SOURCE, "branch");
    const i3_full = benchFullParserIsolated(BRANCHING_SOURCE, "branch");
    printSpeedup(i3_flow, i3_full);

    std.debug.print("\n============================================================\n", .{});
}
