// Benchmark: break down the FULL interpreter pipeline
//
// Measures each stage separately to find where the 88x gap is.
// Compares against Python's 7,342 ns/op for eval("add(\"10\", \"20\")")

const std = @import("std");
const flow_parser = @import("flow_parser");
const koru_parser = @import("parser");
const koru_errors = @import("errors");
const ast = @import("ast");

const ITERATIONS: u64 = 50_000;
const SOURCE = "~add(a: 3, b: 4)";

pub fn main() void {
    std.debug.print("\n", .{});
    std.debug.print("Pipeline Breakdown ({d} iterations)\n", .{ITERATIONS});
    std.debug.print("Target: Python eval() = 7,342 ns/op\n", .{});
    std.debug.print("============================================================\n\n", .{});

    // ----------------------------------------------------------------
    // 1. Arena alloc + dealloc only (no parsing)
    // ----------------------------------------------------------------
    {
        const start = std.time.nanoTimestamp();
        var i: u64 = 0;
        while (i < ITERATIONS) : (i += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            arena.deinit();
        }
        const end = std.time.nanoTimestamp();
        printStage("1. Arena lifecycle", start, end);
    }

    // ----------------------------------------------------------------
    // 2. Arena + flow_parser.parseFlow
    // ----------------------------------------------------------------
    {
        const start = std.time.nanoTimestamp();
        var i: u64 = 0;
        while (i < ITERATIONS) : (i += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            _ = flow_parser.parseFlow(arena.allocator(), SOURCE);
        }
        const end = std.time.nanoTimestamp();
        printStage("2. Arena + flow parse", start, end);
    }

    // ----------------------------------------------------------------
    // 3. Arena + full parser init + parse
    // ----------------------------------------------------------------
    {
        const start = std.time.nanoTimestamp();
        var i: u64 = 0;
        while (i < ITERATIONS) : (i += 1) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            var reporter = koru_errors.ErrorReporter.init(allocator, "b", SOURCE) catch continue;
            _ = &reporter;
            var parser = koru_parser.Parser.init(allocator, SOURCE, "b", &[_][]const u8{}, null) catch continue;
            _ = &parser;
            _ = parser.parse() catch continue;
        }
        const end = std.time.nanoTimestamp();
        printStage("3. Arena + full parse", start, end);
    }

    // ----------------------------------------------------------------
    // 4. Shared arena + flow parse (pure parse cost)
    // ----------------------------------------------------------------
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const start = std.time.nanoTimestamp();
        var i: u64 = 0;
        while (i < ITERATIONS) : (i += 1) {
            _ = arena.reset(.retain_capacity);
            _ = flow_parser.parseFlow(arena.allocator(), SOURCE);
        }
        const end = std.time.nanoTimestamp();
        printStage("4. Flow parse only", start, end);
    }

    // ----------------------------------------------------------------
    // 5. Shared arena + full parse (pure parse cost)
    // ----------------------------------------------------------------
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const start = std.time.nanoTimestamp();
        var i: u64 = 0;
        while (i < ITERATIONS) : (i += 1) {
            _ = arena.reset(.retain_capacity);
            const allocator = arena.allocator();

            var reporter = koru_errors.ErrorReporter.init(allocator, "b", SOURCE) catch continue;
            _ = &reporter;
            var parser = koru_parser.Parser.init(allocator, SOURCE, "b", &[_][]const u8{}, null) catch continue;
            _ = &parser;
            _ = parser.parse() catch continue;
        }
        const end = std.time.nanoTimestamp();
        printStage("5. Full parse only", start, end);
    }

    std.debug.print("\n============================================================\n", .{});
    std.debug.print("Python compile(): 7,065 ns | Python eval(): 7,342 ns\n", .{});
    std.debug.print("============================================================\n", .{});
}

fn printStage(name: []const u8, start: i128, end: i128) void {
    const elapsed_ns: u64 = @intCast(end - start);
    const per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  {s: <28} {d:>8.0} ns/op\n", .{ name, per_op });
}
