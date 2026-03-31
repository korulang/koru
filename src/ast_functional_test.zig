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
