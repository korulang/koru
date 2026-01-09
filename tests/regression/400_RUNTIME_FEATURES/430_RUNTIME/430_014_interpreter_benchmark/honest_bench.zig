const std = @import("std");

const FieldValue = struct { name: []const u8, value: []const u8 };
const DispatchResult = struct { branch: []const u8, fields: []const FieldValue, numeric_result: i64 = 0 };
const Arg = struct { name: []const u8, value: i64 };
const Path = struct { module_qualifier: ?[]const u8, segments: []const []const u8 };
const Invocation = struct { path: Path, args: []const Arg };

// Multiple handlers to prevent inlining
fn add_handler(a: i64, b: i64) i64 { return a + b; }
fn mul_handler(a: i64, b: i64) i64 { return a * b; }
fn sub_handler(a: i64, b: i64) i64 { return a - b; }
fn div_handler(a: i64, b: i64) i64 { return if (b != 0) @divTrunc(a, b) else 0; }

fn getArgNumeric(args: []const Arg, name: []const u8) i64 {
    for (args) |arg| {
        if (std.mem.eql(u8, arg.name, name)) return arg.value;
    }
    return 0;
}

// TRUE dynamic dispatch - event name determined at runtime
fn dispatch(inv: *const Invocation, out_result: *DispatchResult) !void {
    var name_buf: [256]u8 = undefined;
    var name_len: usize = 0;
    for (inv.path.segments, 0..) |seg, i| {
        if (i > 0) { name_buf[name_len] = '.'; name_len += 1; }
        @memcpy(name_buf[name_len..][0..seg.len], seg);
        name_len += seg.len;
    }
    const event_name = name_buf[0..name_len];

    const a = getArgNumeric(inv.args, "a");
    const b = getArgNumeric(inv.args, "b");

    // Multiple branches - compiler can't optimize away!
    if (std.mem.eql(u8, event_name, "add")) {
        out_result.* = .{ .branch = "ok", .fields = &[_]FieldValue{}, .numeric_result = add_handler(a, b) };
    } else if (std.mem.eql(u8, event_name, "mul")) {
        out_result.* = .{ .branch = "ok", .fields = &[_]FieldValue{}, .numeric_result = mul_handler(a, b) };
    } else if (std.mem.eql(u8, event_name, "sub")) {
        out_result.* = .{ .branch = "ok", .fields = &[_]FieldValue{}, .numeric_result = sub_handler(a, b) };
    } else if (std.mem.eql(u8, event_name, "div")) {
        out_result.* = .{ .branch = "ok", .fields = &[_]FieldValue{}, .numeric_result = div_handler(a, b) };
    } else {
        return error.EventDenied;
    }
}

pub fn main() void {
    const ITERATIONS: u64 = 10_000_000;

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Event names - RUNTIME selected!
    const events = [_][]const u8{ "add", "mul", "sub", "div" };
    
    const start = std.time.nanoTimestamp();

    var sum: i64 = 0;
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        const event_idx = random.intRangeAtMost(usize, 0, 3);
        const a = random.intRangeAtMost(i64, 1, 100);
        const b = random.intRangeAtMost(i64, 1, 100);
        
        const segments = [_][]const u8{ events[event_idx] };
        const path = Path{ .module_qualifier = null, .segments = &segments };
        var args_array = [_]Arg{ 
            .{ .name = "a", .value = a },
            .{ .name = "b", .value = b },
        };
        const inv = Invocation{ .path = path, .args = &args_array };

        var result: DispatchResult = undefined;
        dispatch(&inv, &result) catch {};
        sum += result.numeric_result;
    }
    
    const end = std.time.nanoTimestamp();
    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec = @as(f64, @floatFromInt(ITERATIONS)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);
    
    std.debug.print("HONEST Koru: {d:.2}ms, {d:.0} ops/sec, sum={d}\n", .{elapsed_ms, ops_per_sec, sum});
}
