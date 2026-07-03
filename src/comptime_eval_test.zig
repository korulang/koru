const std = @import("std");
const ast = @import("ast");
const expression_parser = @import("expression_parser");
const comptime_eval = @import("comptime_eval");

const Evaluator = comptime_eval.Evaluator;
const Env = comptime_eval.Env;
const Value = comptime_eval.Value;
const Cell = comptime_eval.Cell;

fn evalStr(arena: std.mem.Allocator, env: *Env, source: []const u8) !Value {
    var parser = expression_parser.ExpressionParser.init(arena, source);
    const expr = try parser.parse();
    var evaluator = Evaluator.init(arena);
    return evaluator.evalExpr(env, expr) catch |err| {
        std.debug.print("eval failed on `{s}`: {s} — {s}\n", .{ source, @errorName(err), evaluator.diag });
        return err;
    };
}

test "arithmetic precedence and grouping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = Env.init(arena);

    try std.testing.expectEqual(@as(i64, 7), (try evalStr(arena, &env, "1 + 2 * 3")).int);
    try std.testing.expectEqual(@as(i64, 9), (try evalStr(arena, &env, "(1 + 2) * 3")).int);
    try std.testing.expectEqual(@as(i64, 3), (try evalStr(arena, &env, "10 / 3")).int);
    try std.testing.expectEqual(@as(i64, 1), (try evalStr(arena, &env, "10 % 3")).int);
    try std.testing.expectEqual(@as(i64, -4), (try evalStr(arena, &env, "-4")).int);
}

test "identifiers resolve through the environment chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var outer = Env.init(arena);
    try outer.bind("x", .{ .int = 41 });
    var inner = outer.child();
    try inner.bind("y", .{ .int = 1 });

    try std.testing.expectEqual(@as(i64, 42), (try evalStr(arena, &inner, "x + y")).int);

    var evaluator = Evaluator.init(arena);
    var parser = expression_parser.ExpressionParser.init(arena, "zz + 1");
    const expr = try parser.parse();
    try std.testing.expectError(error.UnknownIdentifier, evaluator.evalExpr(&inner, expr));
    try std.testing.expect(std.mem.indexOf(u8, evaluator.diag, "zz") != null);
}

test "cell field access — the capture-fold shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cell = try arena.create(Cell);
    cell.* = .{};
    try cell.put(arena, "s", .{ .int = 40 });

    var env = Env.init(arena);
    try env.bind("a", .{ .cell = cell });
    try env.bind("i", .{ .int = 2 });

    // The 310_090 update expression shape: a.s + @as(i64, @intCast(i))
    try std.testing.expectEqual(@as(i64, 42), (try evalStr(arena, &env, "a.s + @as(i64, @intCast(i))")).int);

    // Writes are visible through the shared cell pointer.
    try cell.put(arena, "s", .{ .int = 100 });
    try std.testing.expectEqual(@as(i64, 102), (try evalStr(arena, &env, "a.s + i")).int);
}

test "comparisons, booleans, short-circuit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = Env.init(arena);
    try env.bind("n", .{ .int = 5 });

    try std.testing.expect((try evalStr(arena, &env, "n > 0")).boolean);
    try std.testing.expect(!(try evalStr(arena, &env, "n != 5")).boolean);
    // Right side of `and` must not evaluate when left is false:
    // `boom` is unbound, so non-short-circuit evaluation would error.
    try std.testing.expect(!(try evalStr(arena, &env, "n < 0 and boom > 1")).boolean);
    try std.testing.expect((try evalStr(arena, &env, "n > 0 or boom > 1")).boolean);
}

test "array indexing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = try arena.alloc(Value, 3);
    items[0] = .{ .int = 10 };
    items[1] = .{ .int = 20 };
    items[2] = .{ .int = 30 };

    var env = Env.init(arena);
    try env.bind("arr", .{ .array = items });
    try env.bind("i", .{ .int = 1 });

    try std.testing.expectEqual(@as(i64, 20), (try evalStr(arena, &env, "arr[i]")).int);
    try std.testing.expectEqual(@as(i64, 40), (try evalStr(arena, &env, "arr[0] + arr[2]")).int);

    var evaluator = Evaluator.init(arena);
    var parser = expression_parser.ExpressionParser.init(arena, "arr[3]");
    const expr = try parser.parse();
    try std.testing.expectError(error.IndexOutOfBounds, evaluator.evalExpr(&env, expr));
}

test "if-else conditional expressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = Env.init(arena);
    try env.bind("i", .{ .int = 3 });

    try std.testing.expectEqual(@as(i64, 1), (try evalStr(arena, &env, "if (i > 0) 1 else 2")).int);
    try std.testing.expectEqual(@as(i64, 2), (try evalStr(arena, &env, "if (i > 9) 1 else 2")).int);
}

test "float promotion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = Env.init(arena);

    const v = try evalStr(arena, &env, "1 + 2.5");
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), v.float, 1e-12);
}

test "unsupported constructs fail loudly with a named diagnostic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env = Env.init(arena);

    var evaluator = Evaluator.init(arena);
    var parser = expression_parser.ExpressionParser.init(arena, "@floatFromInt(3)");
    const expr = try parser.parse();
    try std.testing.expectError(error.UnsupportedBuiltin, evaluator.evalExpr(&env, expr));
    try std.testing.expect(std.mem.indexOf(u8, evaluator.diag, "floatFromInt") != null);
}
