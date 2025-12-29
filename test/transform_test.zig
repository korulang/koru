const std = @import("std");
const ast = @import("ast");
const transform = @import("ast_transform");
const visitor = @import("ast_visitor");
const inline_transform = @import("transforms/inline_small_events.zig");

// Helper to create owned path segments
fn createPath(allocator: std.mem.Allocator, segments: []const []const u8) ![][]const u8 {
    var result = try allocator.alloc([]const u8, segments.len);
    for (segments, 0..) |seg, i| {
        result[i] = try allocator.dupe(u8, seg);
    }
    return result;
}

test "transform context initialization" {
    const allocator = std.testing.allocator;
    
    // Create a simple AST
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ .zig_line = try allocator.dupe(u8, "const std = @import(\"std\");") });
    
    var test_branches = try allocator.alloc(ast.Branch, 1);
    test_branches[0] = .{ 
        .name = try allocator.dupe(u8, "done"), 
        .payload = .{ .fields = try allocator.alloc(ast.Field, 0) } 
    };
    
    try items.append(allocator, .{
        .event_decl = .{
            .path = .{ .segments = try createPath(allocator, &[_][]const u8{"test"}) },
            .input = .{ .fields = try allocator.alloc(ast.Field, 0) },
            .branches = test_branches,
            .is_public = false,
        },
    });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    // Create transform context
    var ctx = try transform.TransformContext.init(allocator, &source_file);
    defer ctx.deinit();
    
    // Verify initialization
    try std.testing.expect(ctx.original_ast == &source_file);
    try std.testing.expect(ctx.current_ast == &source_file);
}

test "clone node - event" {
    const allocator = std.testing.allocator;
    
    // Create an event node
    var event_branches = try allocator.alloc(ast.Branch, 2);
    event_branches[0] = .{ 
        .name = try allocator.dupe(u8, "success"), 
        .payload = .{ .fields = try allocator.alloc(ast.Field, 0) } 
    };
    event_branches[1] = .{ 
        .name = try allocator.dupe(u8, "failure"), 
        .payload = .{ .fields = try allocator.alloc(ast.Field, 0) } 
    };
    
    var original_item = ast.Item{
        .event_decl = .{
            .path = .{ .segments = try createPath(allocator, &[_][]const u8{"test", "event"}) },
            .input = .{ .fields = try allocator.alloc(ast.Field, 0) },
            .branches = event_branches,
            .is_public = true,
        },
    };
    defer original_item.deinit(allocator);
    const original = original_item;
    
    // Clone it
    const cloned = try transform.cloneNode(allocator, original);
    defer {
        var mut_cloned = cloned;
        mut_cloned.deinit(allocator);
    }
    
    // Verify the clone
    switch (cloned) {
        .event_decl => |event| {
            try std.testing.expect(event.is_public == true);
            try std.testing.expect(event.branches.len == 2);
            try std.testing.expectEqualStrings(event.branches[0].name, "success");
            try std.testing.expectEqualStrings(event.branches[1].name, "failure");
        },
        else => try std.testing.expect(false),
    }
}

test "visitor pattern - collecting visitor" {
    const allocator = std.testing.allocator;
    
    // Create an AST with various node types
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ .zig_line = "const std = @import(\"std\");" });
    var event1_segments = try allocator.alloc([]const u8, 1);
    event1_segments[0] = try allocator.dupe(u8, "event1");
    
    var event1_branches = try allocator.alloc(ast.Branch, 1);
    event1_branches[0] = .{ 
        .name = try allocator.dupe(u8, "done"), 
        .payload = .{ .fields = try allocator.alloc(ast.Field, 0) } 
    };
    
    try items.append(allocator, .{
        .event_decl = .{
            .path = .{ .segments = event1_segments },
            .input = .{ .fields = try allocator.alloc(ast.Field, 0) },
            .branches = event1_branches,
            .is_public = false,
        },
    });
    var proc1_segments = try allocator.alloc([]const u8, 1);
    proc1_segments[0] = try allocator.dupe(u8, "event1");
    
    try items.append(allocator, .{
        .proc_decl = .{
            .path = .{ .segments = proc1_segments },
            .body = try allocator.dupe(u8, "return .{ .done = .{} };"),
        },
    });
    var flow1_segments = try allocator.alloc([]const u8, 1);
    flow1_segments[0] = try allocator.dupe(u8, "event1");
    
    var flow1_continuations = try allocator.alloc(ast.Continuation, 1);
    flow1_continuations[0] = .{ 
        .branch = try allocator.dupe(u8, "done"), 
        .binding = null, 
        .condition = null, 
        .pipeline = try allocator.alloc(ast.Step, 0), 
        .indent = 0, 
        .nested = try allocator.alloc(ast.Continuation, 0) 
    };
    
    try items.append(allocator, .{
        .flow = .{
            .invocation = .{
                .path = .{ .segments = flow1_segments },
                .args = try allocator.alloc(ast.Arg, 0),
            },
            .continuations = flow1_continuations,
            .pre_label = null,
            .post_label = null,
        },
    });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    // Create and run collecting visitor
    var collector = try visitor.CollectingVisitor.init(allocator);
    defer collector.deinit();
    
    try collector.base.visit(&source_file);
    
    // Verify collections
    try std.testing.expect(collector.events.items.len == 1);
    try std.testing.expect(collector.procs.items.len == 1);
    try std.testing.expect(collector.flows.items.len == 1);
}

test "inline small events - detection" {
    const allocator = std.testing.allocator;
    
    // Create an AST with a small proc
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"small"}) },
            .input = .{ .fields = @constCast(&[_]ast.Field{
                .{ .name = "x", .type = "i32" },
            }) },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "result", .payload = .{ .fields = @constCast(&[_]ast.Field{
                    .{ .name = "value", .type = "i32" },
                }) } },
            }),
            .is_public = false,
        },
    });
    try items.append(allocator, .{
        .proc_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"small"}) },
            .body = "return .{ .result = .{ .value = e.x + 1 } };",
        },
    });
    var flow_args = try allocator.alloc(ast.Arg, 1);
    flow_args[0] = .{ 
        .name = try allocator.dupe(u8, "x"), 
        .value = try allocator.dupe(u8, "42") 
    };
    
    var flow_continuations = try allocator.alloc(ast.Continuation, 1);
    flow_continuations[0] = .{ 
        .branch = try allocator.dupe(u8, "result"), 
        .binding = try allocator.dupe(u8, "r"), 
        .condition = null, 
        .pipeline = try allocator.alloc(ast.Step, 0), 
        .indent = 0, 
        .nested = try allocator.alloc(ast.Continuation, 0) 
    };
    
    try items.append(allocator, .{
        .flow = .{
            .invocation = .{
                .path = .{ .segments = try createPath(allocator, &[_][]const u8{"small"}) },
                .args = flow_args,
            },
            .continuations = flow_continuations,
            .pre_label = null,
            .post_label = null,
        },
    });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    // Run inline transformation
    const inlined_count = try inline_transform.transformAST(allocator, &source_file);
    
    // Should detect the small proc as inlinable
    try std.testing.expect(inlined_count > 0);
}

test "transform context - parent tracking" {
    const allocator = std.testing.allocator;
    
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ .zig_line = "test" });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    var ctx = try transform.TransformContext.init(allocator, &source_file);
    defer ctx.deinit();
    
    // Test parent tracking
    try std.testing.expect(ctx.currentParent() == null);
    
    try ctx.pushParent(&source_file.items[0]);
    try std.testing.expect(ctx.currentParent() != null);
    
    ctx.popParent();
    try std.testing.expect(ctx.currentParent() == null);
}

test "transform context - mark transformed" {
    const allocator = std.testing.allocator;
    
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ .zig_line = "test" });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    var ctx = try transform.TransformContext.init(allocator, &source_file);
    defer ctx.deinit();
    
    // Test transformation tracking
    try std.testing.expect(!ctx.hasTransformed("test_key"));
    
    try ctx.markTransformed("test_key");
    try std.testing.expect(ctx.hasTransformed("test_key"));
}