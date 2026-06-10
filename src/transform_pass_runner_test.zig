const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const ast_functional = @import("ast_functional");
const transform_pass_runner = @import("transform_pass_runner");

var observed_order: [8][]const u8 = undefined;
var observed_count: usize = 0;
var outer_saw_inner_inline = false;
var outer_saw_raw_inner_invocation = false;

fn resetObservations() void {
    observed_count = 0;
    outer_saw_inner_inline = false;
    outer_saw_raw_inner_invocation = false;
}

fn recordObservation(name: []const u8) void {
    observed_order[observed_count] = name;
    observed_count += 1;
}

fn makeInvocation(allocator: std.mem.Allocator, name: []const u8, has_runtime_arg: bool) !ast.Invocation {
    const segments = try allocator.alloc([]const u8, 1);
    segments[0] = try allocator.dupe(u8, name);

    const args = if (has_runtime_arg) blk: {
        const runtime_args = try allocator.alloc(ast.Arg, 1);
        runtime_args[0] = ast.Arg{
            .name = try allocator.dupe(u8, "x"),
            .value = try allocator.dupe(u8, "1"),
        };
        break :blk runtime_args;
    } else try allocator.alloc(ast.Arg, 0);

    return ast.Invocation{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = segments,
        },
        .args = args,
        .annotations = try allocator.alloc([]const u8, 0),
    };
}

fn makeProgramWithNestedInvocation(allocator: std.mem.Allocator) !*ast.Program {
    const inner_invocation = try makeInvocation(allocator, "inner", false);
    const outer_invocation = try makeInvocation(allocator, "outer", true);

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
            .body = ast.rootSite(outer_invocation, conts, .{ .file = "generated", .line = 0, .column = 0 }),
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

fn innerTransform(node: ast.ASTNode, program: *const ast.Program, allocator: std.mem.Allocator) !ast.SiteResult {
    _ = node;
    _ = program;
    recordObservation("inner");

    // Site-local write-back: the handler DESCRIBES its change (replace this
    // site with lowered inline_code) and returns it as a value. The runner
    // owns placement — it splices this into the nested site directly, no
    // lift/graft, no whole-program clone here.
    const lowered_item = ast.Item{ .inline_code = ast.InlineCode{
        .code = try allocator.dupe(u8, "// inner lowered"),
        .location = .{ .file = "generated", .line = 0, .column = 0 },
        .module = try allocator.dupe(u8, "test"),
    } };
    return .{ .replacement = lowered_item };
}

fn outerTransform(node: ast.ASTNode, program: *const ast.Program, allocator: std.mem.Allocator) !ast.SiteResult {
    _ = node;
    _ = allocator;

    recordObservation("outer");

    const flow = program.items[0].flow;
    const child_node = flow.body.continuations[0].node orelse return error.MissingChildNode;
    outer_saw_inner_inline = child_node == .inline_code;

    return .{}; // no-op: observe only
}

fn outerClaimingTransform(node: ast.ASTNode, program: *const ast.Program, allocator: std.mem.Allocator) !ast.SiteResult {
    _ = node;
    _ = allocator;

    recordObservation("outer");

    const flow = program.items[0].flow;
    const child_node = flow.body.continuations[0].node orelse return error.MissingChildNode;
    if (child_node == .invocation) {
        outer_saw_raw_inner_invocation = std.mem.eql(u8, child_node.invocation.path.segments[0], "inner");
    }

    return .{}; // no-op: observe only
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

test "claimed transform checks self before descendants and sees raw child invocation" {
    resetObservations();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try makeProgramWithNestedInvocation(allocator);
    const transforms = [_]transform_pass_runner.TransformEntry{
        .{ .name = "inner", .handler_fn = innerTransform },
        .{ .name = "outer", .claims_descendants = true, .handler_fn = outerClaimingTransform },
    };

    const transformed = try transform_pass_runner.walkAndTransform(original, &transforms, allocator);

    try testing.expectEqual(@as(usize, 2), observed_count);
    try testing.expectEqualStrings("outer", observed_order[0]);
    try testing.expectEqualStrings("inner", observed_order[1]);
    try testing.expect(outer_saw_raw_inner_invocation);
    _ = transformed;
}
