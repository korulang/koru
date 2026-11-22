const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const ast_functional = @import("ast_functional");

fn makeInvocation(allocator: std.mem.Allocator, name: []const u8) !ast.Invocation {
    const segments = try allocator.alloc([]const u8, 1);
    segments[0] = try allocator.dupe(u8, name);

    return ast.Invocation{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = segments,
        },
        .args = try allocator.alloc(ast.Arg, 0),
        .annotations = try allocator.alloc([]const u8, 0),
    };
}

test "findContinuationContainingInvocation returns the owning continuation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const target_invocation = try makeInvocation(allocator, "pairwise");
    const nested = try allocator.alloc(ast.Continuation, 1);
    nested[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "kernel"),
        .binding = try allocator.dupe(u8, "k"),
        .condition = null,
        .node = ast.Node{ .invocation = target_invocation },
        .indent = 4,
        .continuations = try allocator.alloc(ast.Continuation, 0),
    };

    const root = try allocator.alloc(ast.Continuation, 1);
    root[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "ok"),
        .binding = null,
        .condition = null,
        .node = null,
        .indent = 0,
        .continuations = nested,
    };

    const found = ast_functional.findContinuationContainingInvocation(root, &nested[0].node.?.invocation);
    try testing.expect(found != null);
    try testing.expect(found.? == &nested[0]);
}

test "walkLexicalContinuationSubtree visits lexical nodes in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const child_continuations = try allocator.alloc(ast.Continuation, 1);
    child_continuations[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "done"),
        .binding = null,
        .condition = null,
        .node = ast.Node{ .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, "done"),
            .fields = try allocator.alloc(ast.Field, 0),
        } },
        .indent = 4,
        .continuations = try allocator.alloc(ast.Continuation, 0),
    };

    const root = ast.Continuation{
        .branch = try allocator.dupe(u8, "kernel"),
        .binding = try allocator.dupe(u8, "k"),
        .condition = null,
        .node = ast.Node{ .invocation = try makeInvocation(allocator, "pairwise") },
        .indent = 0,
        .continuations = child_continuations,
    };

    const Seen = struct {
        items: [4][]const u8 = undefined,
        len: usize = 0,

        fn push(self: *@This(), item: []const u8) void {
            self.items[self.len] = item;
            self.len += 1;
        }

        fn visit(self: *@This(), visit_info: ast_functional.LexicalSubtreeVisit) !ast_functional.LexicalSubtreeWalkControl {
            switch (visit_info) {
                .continuation => |cont| self.push(cont.branch),
                .invocation => |info| self.push(info.invocation.path.segments[0]),
                .node => |info| switch (info.node.*) {
                    .branch_constructor => self.push("branch_constructor"),
                    else => self.push("node"),
                },
            }
            return .continue_walk;
        }
    };

    var seen = Seen{};
    try ast_functional.walkLexicalContinuationSubtree(Seen, &root, &seen, Seen.visit);

    try testing.expectEqual(@as(usize, 4), seen.len);
    try testing.expectEqualStrings("kernel", seen.items[0]);
    try testing.expectEqualStrings("pairwise", seen.items[1]);
    try testing.expectEqualStrings("done", seen.items[2]);
    try testing.expectEqualStrings("branch_constructor", seen.items[3]);
}

test "replaceInvocationNodeAndContinuationsRecursive shares untouched continuation forests" {
    // Regression pin for the splice-site arena blowup: the continuation
    // walkers must return null on a miss so unchanged flows keep sharing
    // their continuation slices. The eager version deep-cloned every
    // continuation of every flow per splice (~9.3 GiB over 140 calls).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Untouched flow: a wide arm forest the walker must NOT clone.
    const untouched_conts = try allocator.alloc(ast.Continuation, 64);
    for (untouched_conts, 0..) |*c, i| {
        c.* = ast.Continuation{
            .branch = try allocator.dupe(u8, "arm"),
            .binding = null,
            .condition = null,
            .node = ast.Node{ .invocation = try makeInvocation(allocator, "leaf") },
            .indent = i,
            .continuations = try allocator.alloc(ast.Continuation, 0),
        };
    }
    const untouched_body = ast.rootSite(
        try makeInvocation(allocator, "untouched"),
        untouched_conts,
        .{ .file = "t", .line = 0, .column = 0 },
    );

    // Target flow: the target invocation sits in one arm's node.
    const target_holder = try allocator.alloc(ast.Continuation, 1);
    target_holder[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "ok"),
        .binding = null,
        .condition = null,
        .node = ast.Node{ .invocation = try makeInvocation(allocator, "target") },
        .indent = 0,
        .continuations = try allocator.alloc(ast.Continuation, 0),
    };
    const target_body = ast.rootSite(
        try makeInvocation(allocator, "driver"),
        target_holder,
        .{ .file = "t", .line = 0, .column = 0 },
    );

    const items = try allocator.alloc(ast.Item, 2);
    items[0] = ast.Item{ .flow = .{ .body = target_body } };
    items[1] = ast.Item{ .flow = .{ .body = untouched_body } };
    var program = ast.Program{ .items = items, .allocator = allocator };

    const result = try ast_functional.replaceInvocationNodeAndContinuationsRecursive(
        allocator,
        &program,
        &target_holder[0].node.?.invocation,
        ast.Node{ .invocation = try makeInvocation(allocator, "spliced") },
        try allocator.alloc(ast.Continuation, 0),
        false,
    );
    try testing.expect(result != null);
    const out = result.?;
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // The untouched flow's continuation slice must be the SAME allocation —
    // a clone would mint a fresh pointer and pay the forest copy the audit
    // measured at ~9.3 GiB per transform window.
    const untouched_out = &out.items[1].flow;
    try testing.expectEqual(untouched_conts.ptr, untouched_out.body.continuations.ptr);
    try testing.expectEqual(untouched_conts.len, untouched_out.body.continuations.len);

    // Sanity: the target arm really was spliced, so the walk ran.
    const target_out = &out.items[0].flow;
    const spliced = target_out.body.continuations[0].node.?;
    try testing.expectEqualStrings("spliced", spliced.invocation.path.segments[0]);
}
