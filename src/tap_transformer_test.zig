// Unit tests for tap_transformer.zig
// Tests AST transformation-based tap injection

const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const tap_transformer = @import("tap_transformer");
const tap_registry_module = @import("tap_registry");

test "tap_transformer: basic subflow tap insertion" {
    const allocator = testing.allocator;

    // Create a minimal AST with:
    // 1. An event tap: ~double(source: main:add_five, branch: result) => observer()
    // 2. A subflow: ~add_five = five | result |> doubled { n: result.n }

    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 2);
    defer items.deinit(allocator);

    // Create event tap
    const tap_path = ast.DottedPath{
        .module_qualifier = null,
        .segments = &[_][]const u8{"observer"},
    };

    var tap_continuations = try std.ArrayList(ast.Continuation).initCapacity(allocator, 1);
    defer tap_continuations.deinit(allocator);

    const tap_pipeline = try allocator.alloc(ast.Step, 1);
    tap_pipeline[0] = ast.Step{
        .invocation = ast.Invocation{
            .path = tap_path,
            .args = &[_]ast.Arg{},
        },
    };

    const tap_cont = ast.Continuation{
        .branch = "result",
        .binding = null,
        .binding_type = .branch_payload,
        .condition = null,
        .condition_expr = null,
        .pipeline = tap_pipeline,
        .indent = 0,
        .nested = &[_]ast.Continuation{},
    };
    try tap_continuations.append(allocator, tap_cont);

    const event_tap = ast.EventTap{
        .annotations = &[_][]const u8{},
        .source_event_pattern = ast.EventPattern{
            .module_qualifier = "main",
            .path = &[_][]const u8{"add_five"},
            .wildcard = false,
        },
        .continuations = try tap_continuations.toOwnedSlice(),
        .module = "",
    };

    try items.append(ast.Item{ .event_tap = event_tap });

    // Create subflow with continuation: five | result |> doubled { n: result.n }
    const five_invocation = ast.Invocation{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &[_][]const u8{"five"},
        },
        .args = &[_]ast.Arg{},
    };

    const doubled_invocation = ast.Invocation{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &[_][]const u8{"doubled"},
        },
        .args = &[_]ast.Arg{
            ast.Arg{ .name = "n", .value = "result.n" },
        },
    };

    const doubled_step = ast.Step{ .invocation = doubled_invocation };
    const result_pipeline = try allocator.alloc(ast.Step, 1);
    result_pipeline[0] = doubled_step;

    var subflow_continuations = try std.ArrayList(ast.Continuation).initCapacity(allocator, 1);
    defer subflow_continuations.deinit(allocator);

    const result_cont = ast.Continuation{
        .branch = "result",
        .binding = "result",
        .binding_type = .branch_payload,
        .condition = null,
        .condition_expr = null,
        .pipeline = result_pipeline,
        .indent = 0,
        .nested = &[_]ast.Continuation{},
    };
    try subflow_continuations.append(allocator, result_cont);

    const subflow = ast.SubflowImpl{
        .annotations = &[_][]const u8{},
        .event_path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &[_][]const u8{"add_five"},
        },
        .body = ast.SubflowBody{
            .flow = ast.Flow{
                .invocation = five_invocation,
                .continuations = try subflow_continuations.toOwnedSlice(),
                .super_shape = null,
                .inline_flows = &[_]ast.Flow{},
            },
        },
        .module = "",
    };

    try items.append(ast.Item{ .subflow_impl = subflow });

    const source_ast = ast.Program{
        .items = try items.toOwnedSlice(),
        .module_annotations = &[_][]const u8{},
        .main_module_name = "main",
        .allocator = allocator,
    };

    // Build tap registry
    var tap_registry = try tap_registry_module.buildTapRegistry(source_ast.items, allocator);
    defer tap_registry.deinit();

    // Transform AST (use .all mode for test - include all taps)
    const transformed_ast = try tap_transformer.transformAst(&source_ast, &tap_registry, .all, allocator);
    defer allocator.destroy(transformed_ast);
    defer allocator.free(transformed_ast.items);

    // Verify transformation
    try testing.expect(transformed_ast.items.len == 2);

    // Find the transformed subflow
    const transformed_subflow = transformed_ast.items[1].subflow_impl;
    const flow = transformed_subflow.body.flow;

    // Check that continuation pipeline now has 2 steps: observer() + doubled()
    try testing.expect(flow.continuations.len == 1);
    const cont = flow.continuations[0];

    std.debug.print("\n[TEST] Continuation has {} pipeline steps\n", .{cont.pipeline.len});

    // The transformation should prepend the tap invocation
    // Expected: [observer(), doubled()]
    try testing.expect(cont.pipeline.len == 2);

    // First step should be the tap (observer)
    try testing.expect(cont.pipeline[0] == .invocation);
    const tap_invocation = cont.pipeline[0].invocation;
    try testing.expectEqualStrings("observer", tap_invocation.path.segments[0]);

    // Second step should be the original (doubled)
    try testing.expect(cont.pipeline[1] == .invocation);
    const original_invocation = cont.pipeline[1].invocation;
    try testing.expectEqualStrings("doubled", original_invocation.path.segments[0]);

    std.debug.print("[TEST] ✅ Tap transformation verified: tap prepended to continuation pipeline\n", .{});
}

test "tap_transformer: no taps means no transformation" {
    const allocator = testing.allocator;

    // Create AST with subflow but NO taps
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 1);
    defer items.deinit(allocator);

    const five_invocation = ast.Invocation{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &[_][]const u8{"five"},
        },
        .args = &[_]ast.Arg{},
    };

    const doubled_invocation = ast.Invocation{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &[_][]const u8{"doubled"},
        },
        .args = &[_]ast.Arg{
            ast.Arg{ .name = "n", .value = "10" },
        },
    };

    const doubled_step = ast.Step{ .invocation = doubled_invocation };
    const result_pipeline = try allocator.alloc(ast.Step, 1);
    result_pipeline[0] = doubled_step;

    var subflow_continuations = try std.ArrayList(ast.Continuation).initCapacity(allocator, 1);
    defer subflow_continuations.deinit(allocator);

    const result_cont = ast.Continuation{
        .branch = "result",
        .binding = null,
        .binding_type = .branch_payload,
        .condition = null,
        .condition_expr = null,
        .pipeline = result_pipeline,
        .indent = 0,
        .nested = &[_]ast.Continuation{},
    };
    try subflow_continuations.append(allocator, result_cont);

    const subflow = ast.SubflowImpl{
        .annotations = &[_][]const u8{},
        .event_path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &[_][]const u8{"add_five"},
        },
        .body = ast.SubflowBody{
            .flow = ast.Flow{
                .invocation = five_invocation,
                .continuations = try subflow_continuations.toOwnedSlice(),
                .super_shape = null,
                .inline_flows = &[_]ast.Flow{},
            },
        },
        .module = "",
    };

    try items.append(ast.Item{ .subflow_impl = subflow });

    const source_ast = ast.Program{
        .items = try items.toOwnedSlice(),
        .module_annotations = &[_][]const u8{},
        .main_module_name = "main",
        .allocator = allocator,
    };

    // Build tap registry (empty)
    var tap_registry = try tap_registry_module.buildTapRegistry(source_ast.items, allocator);
    defer tap_registry.deinit();

    // Transform AST (use .all mode for test - include all taps)
    const transformed_ast = try tap_transformer.transformAst(&source_ast, &tap_registry, .all, allocator);
    defer allocator.destroy(transformed_ast);
    defer allocator.free(transformed_ast.items);

    // Verify NO transformation (pipeline still has 1 step)
    const transformed_subflow = transformed_ast.items[0].subflow_impl;
    const flow = transformed_subflow.body.flow;
    const cont = flow.continuations[0];

    try testing.expect(cont.pipeline.len == 1);
    try testing.expectEqualStrings("doubled", cont.pipeline[0].invocation.path.segments[0]);

    std.debug.print("[TEST] ✅ No taps = no transformation verified\n", .{});
}
