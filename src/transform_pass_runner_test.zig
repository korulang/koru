const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const ast_functional = @import("ast_functional");
const transform_pass_runner = @import("transform_pass_runner");

var observed_order: [8][]const u8 = undefined;
var observed_count: usize = 0;
var outer_saw_inner_inline = false;

fn resetObservations() void {
    observed_count = 0;
    outer_saw_inner_inline = false;
}

fn recordObservation(name: []const u8) void {
    observed_order[observed_count] = name;
    observed_count += 1;
}

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

fn makeProgramWithNestedInvocation(allocator: std.mem.Allocator) !*ast.Program {
    const inner_invocation = try makeInvocation(allocator, "inner");
    const outer_invocation = try makeInvocation(allocator, "outer");

    const conts = try allocator.alloc(ast.Continuation, 1);
    conts[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "ok"),
        .binding = null,
        .condition = null,
        .node = ast.Node{ .invocation = inner_invocation },
        .indent = 0,
        .continuations = try allocator.alloc(ast.Continuation, 0),
    };

    const items = try allocator.alloc(ast.Item, 1);
    items[0] = ast.Item{
        .flow = ast.Flow{
            .invocation = outer_invocation,
            .continuations = conts,
            .annotations = try allocator.alloc([]const u8, 0),
            .module = try allocator.dupe(u8, "test"),
        },
    };

    const program = try allocator.create(ast.Program);
    program.* = ast.Program{
        .items = items,
        .module_annotations = try allocator.alloc([]const u8, 0),
        .main_module_name = try allocator.dupe(u8, "test"),
        .allocator = allocator,
    };
    return program;
}

fn innerTransform(node: ast.ASTNode, program: *const ast.Program, allocator: std.mem.Allocator) !*const ast.Program {
    recordObservation("inner");

    const lowered = ast.Node{
        .inline_code = try allocator.dupe(u8, "// inner lowered"),
    };
    const replaced = try ast_functional.replaceInvocationNodeRecursive(allocator, program, node.invocation, lowered) orelse {
        return error.TestReplaceFailed;
    };

    const result = try allocator.create(ast.Program);
    result.* = replaced;
    return result;
}

fn outerTransform(node: ast.ASTNode, program: *const ast.Program, allocator: std.mem.Allocator) !*const ast.Program {
    _ = node;
    _ = allocator;

    recordObservation("outer");

    const flow = program.items[0].flow;
    const child_node = flow.continuations[0].node orelse return error.MissingChildNode;
    outer_saw_inner_inline = child_node == .inline_code;

    return program;
}

test "transform runner prefers nested transform before outer owner candidate" {
    resetObservations();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try makeProgramWithNestedInvocation(allocator);
    const transforms = [_]transform_pass_runner.TransformEntry{
        .{ .name = "inner", .handler_fn = innerTransform },
        .{ .name = "outer", .handler_fn = outerTransform },
    };

    const transformed = try transform_pass_runner.walkAndTransform(original, &transforms, allocator);

    try testing.expectEqual(@as(usize, 2), observed_count);
    try testing.expectEqualStrings("inner", observed_order[0]);
    try testing.expectEqualStrings("outer", observed_order[1]);
    try testing.expect(outer_saw_inner_inline);
    _ = transformed;
}
