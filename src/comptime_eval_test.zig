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

// ============================================================
// The flow walker (rung two) — countdown through a fake thunk table
// ============================================================
//
// The AST below is hand-built to the EXACT shape Stage A parses for
// 310_091_aspire_comptime_loop (verified against its program_ast.zig):
//
//   countdown = #loop tick(n: 5)
//   | go i when i > 0 |> @loop(n: i - 1)
//   | go i |> report(v: i)
//
// tick and report are fake thunks here — the generated Stage A table calls
// compiled handlers; the walker cannot tell the difference, which is the
// point of the table.

var tick_calls: std.ArrayListUnmanaged(i64) = .{};
var reported: std.ArrayListUnmanaged(i64) = .{};
var thunk_arena: ?std.mem.Allocator = null;

fn tickThunk(allocator: std.mem.Allocator, args: []const comptime_eval.ArgValue) comptime_eval.EvalError!comptime_eval.ThunkResult {
    _ = allocator;
    if (args.len != 1 or !std.mem.eql(u8, args[0].name, "n")) return error.UnknownField;
    const n = try args[0].value.expectInt();
    tick_calls.append(thunk_arena.?, n) catch return error.OutOfMemory;
    return .{ .branch = "go", .payload = .{ .int = n } };
}

fn reportThunk(allocator: std.mem.Allocator, args: []const comptime_eval.ArgValue) comptime_eval.EvalError!comptime_eval.ThunkResult {
    _ = allocator;
    if (args.len != 1 or !std.mem.eql(u8, args[0].name, "v")) return error.UnknownField;
    const v = try args[0].value.expectInt();
    reported.append(thunk_arena.?, v) catch return error.OutOfMemory;
    return .{}; // void: no branch, no payload
}

fn segPath(arena: std.mem.Allocator, name: []const u8) !ast.DottedPath {
    const segments = try arena.alloc([]const u8, 1);
    segments[0] = name;
    return .{ .segments = segments };
}

test "flow walker: when-guarded #loop countdown through the thunk table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    tick_calls = .{};
    reported = .{};
    thunk_arena = arena;

    // | go i when i > 0 |> @loop(n: i - 1)
    const jump_args = try arena.alloc(ast.Arg, 1);
    jump_args[0] = .{ .name = "n", .value = "i - 1" };
    // | go i |> report(v: i)
    const report_args = try arena.alloc(ast.Arg, 1);
    report_args[0] = .{ .name = "v", .value = "i" };

    const arms = try arena.alloc(ast.Continuation, 2);
    arms[0] = .{
        .branch = "go",
        .binding = "i",
        .condition = "i > 0",
        .node = .{ .label_jump = .{ .label = "loop", .args = jump_args } },
        .indent = 1,
        .continuations = &.{},
    };
    arms[1] = .{
        .branch = "go",
        .binding = "i",
        .condition = null,
        .node = .{ .invocation = .{ .path = try segPath(arena, "report"), .args = report_args } },
        .indent = 1,
        .continuations = &.{},
    };

    // countdown = #loop tick(n: 5)
    const head_args = try arena.alloc(ast.Arg, 1);
    head_args[0] = .{ .name = "n", .value = "5" };
    const countdown = ast.Flow{
        .body = .{
            .branch = "",
            .binding = null,
            .condition = null,
            .node = .{ .invocation = .{ .path = try segPath(arena, "tick"), .args = head_args } },
            .indent = 0,
            .continuations = arms,
        },
        .pre_label = "loop",
        .impl_of = try segPath(arena, "countdown"),
    };

    const items = try arena.alloc(ast.Item, 1);
    items[0] = .{ .flow = countdown };

    var evaluator = Evaluator.init(arena);
    const thunks = [_]comptime_eval.Thunk{
        .{ .event_name = "tick", .call = &tickThunk },
        .{ .event_name = "report", .call = &reportThunk },
    };
    evaluator.setThunks(&thunks);

    // Invoke countdown() the way the Folder will: by path, no args.
    const result = try evaluator.invokePath(items, &(try segPath(arena, "countdown")), &.{});

    // tick ran 6 times (5..0), report exactly once with the terminal 0.
    try std.testing.expectEqualSlices(i64, &.{ 5, 4, 3, 2, 1, 0 }, tick_calls.items);
    try std.testing.expectEqualSlices(i64, &.{0}, reported.items);
    try std.testing.expect(result.branch == null);
    try std.testing.expect(result.payload == null);
}

test "flow walker: unhandled branch and non-terminating loop fail loudly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    tick_calls = .{};
    reported = .{};
    thunk_arena = arena;

    // A labeled flow whose single arm ALWAYS jumps: must hit the iteration
    // wall loudly, never hang.
    const arms = try arena.alloc(ast.Continuation, 1);
    const jump_args2 = try arena.alloc(ast.Arg, 1);
    jump_args2[0] = .{ .name = "n", .value = "i" };
    arms[0] = .{
        .branch = "go",
        .binding = "i",
        .condition = null,
        .node = .{ .label_jump = .{ .label = "loop", .args = jump_args2 } },
        .indent = 1,
        .continuations = &.{},
    };
    const head_args = try arena.alloc(ast.Arg, 1);
    head_args[0] = .{ .name = "n", .value = "1" };
    const spin = ast.Flow{
        .body = .{
            .branch = "",
            .binding = null,
            .condition = null,
            .node = .{ .invocation = .{ .path = try segPath(arena, "tick"), .args = head_args } },
            .indent = 0,
            .continuations = arms,
        },
        .pre_label = "loop",
        .impl_of = try segPath(arena, "spin"),
    };
    const items = try arena.alloc(ast.Item, 1);
    items[0] = .{ .flow = spin };

    var evaluator = Evaluator.init(arena);
    const thunks = [_]comptime_eval.Thunk{
        .{ .event_name = "tick", .call = &tickThunk },
    };
    evaluator.setThunks(&thunks);

    const err = evaluator.invokePath(items, &(try segPath(arena, "spin")), &.{});
    try std.testing.expectError(error.UnsupportedConstruct, err);
    try std.testing.expect(std.mem.indexOf(u8, evaluator.diag, "iterations") != null);

    // And a branch no arm handles names itself in the diagnostic.
    var evaluator2 = Evaluator.init(arena);
    const bad_thunks = [_]comptime_eval.Thunk{
        .{ .event_name = "tick", .call = &tickThunk },
    };
    evaluator2.setThunks(&bad_thunks);
    const bad_arms = try arena.alloc(ast.Continuation, 1);
    bad_arms[0] = .{
        .branch = "done",
        .binding = null,
        .condition = null,
        .node = null,
        .indent = 1,
        .continuations = &.{},
    };
    const head_args2 = try arena.alloc(ast.Arg, 1);
    head_args2[0] = .{ .name = "n", .value = "1" };
    const mismatched = ast.Flow{
        .body = .{
            .branch = "",
            .binding = null,
            .condition = null,
            .node = .{ .invocation = .{ .path = try segPath(arena, "tick"), .args = head_args2 } },
            .indent = 0,
            .continuations = bad_arms,
        },
        .impl_of = try segPath(arena, "mismatched"),
    };
    const items2 = try arena.alloc(ast.Item, 1);
    items2[0] = .{ .flow = mismatched };
    const err2 = evaluator2.invokePath(items2, &(try segPath(arena, "mismatched")), &.{});
    try std.testing.expectError(error.UnsupportedConstruct, err2);
    try std.testing.expect(std.mem.indexOf(u8, evaluator2.diag, "go") != null);
}

// ============================================================================
// Annotation entry evaluation — provider chain, symbol rule, narrowing heads
// ============================================================================

const Provider = comptime_eval.Provider;

fn entry(arena: std.mem.Allocator, provider: *const Provider, text: []const u8) !comptime_eval.EntryResult {
    return comptime_eval.evalAnnotationEntry(arena, provider, text);
}

test "entry: bare atom resolves through flags, absent is false" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"profile"};
    const p = Provider{ .flags = &flags };

    try std.testing.expect((try entry(arena, &p, "profile")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "debug")).truthy);
}

test "entry: valued flag comparison with quoted RHS" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"build=release"};
    const p = Provider{ .flags = &flags };

    try std.testing.expect((try entry(arena, &p, "build == \"release\"")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "build == \"debug\"")).truthy);
}

test "entry: bare RHS is a symbol (ruled 2026-07-20)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"build=release"};
    const p = Provider{ .flags = &flags };

    // `release` is NOT a flag; as a symbol the comparison is true anyway.
    try std.testing.expect((try entry(arena, &p, "build == release")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "build == debug")).truthy);
}

test "entry: kebab and path atoms resolve as single identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{ "fast-scan", "target=std/explain" };
    const p = Provider{ .flags = &flags };

    try std.testing.expect((try entry(arena, &p, "fast-scan")).truthy);
    try std.testing.expect((try entry(arena, &p, "target == std/explain")).truthy);
}

test "entry: numeric flag values order-compare" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"version=15"};
    const p = Provider{ .flags = &flags };

    try std.testing.expect((try entry(arena, &p, "version >= 15")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "version > 15")).truthy);
}

test "entry: and/or/not compose with truthiness" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{ "profile", "build=release" };
    const p = Provider{ .flags = &flags };

    try std.testing.expect((try entry(arena, &p, "profile && build == \"release\"")).truthy);
    try std.testing.expect((try entry(arena, &p, "debug || profile")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "!profile")).truthy);
    try std.testing.expect((try entry(arena, &p, "!debug")).truthy);
}

test "entry: narrowing heads pin one provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"profile"};
    const p = Provider{ .flags = &flags, .command = "explain" };

    try std.testing.expect((try entry(arena, &p, "cflag(profile)")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "cflag(missing)")).truthy);
    try std.testing.expect((try entry(arena, &p, "command(explain)")).truthy);
    try std.testing.expect(!(try entry(arena, &p, "command(deps)")).truthy);
}

test "entry: unknown narrowing head fails loudly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = Provider{};
    try std.testing.expectError(error.UnsupportedConstruct, entry(arena, &p, "flock(profile)"));
}

test "entry: feral text fails loudly for an evaluating consumer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = Provider{};
    var diag: []const u8 = "";
    try std.testing.expectError(
        error.UnsupportedConstruct,
        comptime_eval.evalAnnotationEntryDiag(arena, &p, "inline@500", &diag),
    );
}

test "entry: resolution trace carries provenance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"build=release"};
    const p = Provider{ .flags = &flags };

    const r = try entry(arena, &p, "build == \"release\"");
    try std.testing.expectEqual(@as(usize, 1), r.trace.len);
    try std.testing.expectEqualStrings("build = \"release\" (compiler flag)", r.trace[0]);
}

test "entry: juxtaposed feral text is trailing garbage, never a silent prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const flags = [_][]const u8{"profile"};
    const p = Provider{ .flags = &flags };

    // Without consume-all this would silently evaluate as bare `profile`
    // (true!) and gate an import on garbage.
    try std.testing.expectError(
        error.UnsupportedConstruct,
        entry(arena, &p, "profile \"with spaces\" 1000Hz"),
    );
}
