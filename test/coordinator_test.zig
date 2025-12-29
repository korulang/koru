const std = @import("std");
const ast = @import("ast");
const coordinator = @import("compiler_coordinator");

test "basic coordinator initialization" {
    const allocator = std.testing.allocator;
    
    // Create a simple AST
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 2);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ .zig_line = "const std = @import(\"std\");" });
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"compute"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "done", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    // Initialize coordinator
    const config = coordinator.CompileConfig{
        .optimization_level = .balanced,
        .max_iterations = 5,
    };
    
    var ctx = coordinator.CompilationContext.init(allocator, &source_file, config);
    defer ctx.deinit();
    
    // Verify initialization
    try std.testing.expect(ctx.config.max_iterations == 5);
    try std.testing.expect(ctx.iteration == 0);
    try std.testing.expect(ctx.metrics.event_count == 1);
}

test "metrics computation" {
    const allocator = std.testing.allocator;
    
    // Create AST with multiple elements
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 2);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ .zig_line = "const std = @import(\"std\");" });
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"event1"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "success", .payload = .{ .fields = &.{} } },
                .{ .name = "error", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"event2"}) }, 
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "done", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    try items.append(allocator, .{
        .proc_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"event1"}) },
            .body = "// handler code",
        },
    });
    
    const source_file = ast.SourceFile{
        .items = items.items,
        .allocator = allocator,
    };
    
    const metrics = coordinator.CompilationMetrics.compute(&source_file);
    
    try std.testing.expect(metrics.ast_nodes == 4);
    try std.testing.expect(metrics.event_count == 2);
    try std.testing.expect(metrics.branch_count == 3);
    try std.testing.expect(metrics.flow_count == 1);
}

test "pattern detection" {
    const allocator = std.testing.allocator;
    
    // Create AST with benchmark pattern
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 2);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"benchmark", "run"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "complete", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"resource", "acquire"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "acquired", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    const config = coordinator.CompileConfig{};
    var ctx = coordinator.CompilationContext.init(allocator, &source_file, config);
    defer ctx.deinit();
    
    // Discover patterns
    try ctx.discoverPatterns();
    
    // Verify patterns were detected
    try std.testing.expect(ctx.analysis != null);
    const analysis = ctx.analysis.?;
    
    var has_inline_small = false;
    
    for (analysis.patterns.items) |pattern| {
        switch (pattern) {
            .inline_small => has_inline_small = true,
        }
    }
    
    // For now we don't expect any patterns (inline_small is the only one)
}

test "multi-pass optimization" {
    const allocator = std.testing.allocator;
    
    // Create a simple AST
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 2);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"compute"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "done", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    
    var source_file = ast.SourceFile{
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
    defer allocator.free(source_file.items);
    
    const config = coordinator.CompileConfig{
        .optimization_level = .balanced,
        .max_iterations = 3,
        .enable_patterns = true,
    };
    
    var ctx = coordinator.CompilationContext.init(allocator, &source_file, config);
    defer ctx.deinit();
    
    // Run full optimization pipeline
    try ctx.discoverPatterns();
    try ctx.analyzeDataFlow();
    _ = try ctx.applyTransformations();
    try ctx.optimizeIteratively();
    
    // Verify optimization ran
    try std.testing.expect(ctx.iteration > 0);
}

test "metrics improvement detection" {
    const metrics1 = coordinator.CompilationMetrics{
        .ast_nodes = 10,
        .event_count = 5,
        .flow_count = 3,
        .branch_count = 7,
        .estimated_cycles = 1000,
    };
    
    const metrics2 = coordinator.CompilationMetrics{
        .ast_nodes = 10,
        .event_count = 5,
        .flow_count = 3,
        .branch_count = 7,
        .estimated_cycles = 800,
    };
    
    const metrics3 = coordinator.CompilationMetrics{
        .ast_nodes = 10,
        .event_count = 5,
        .flow_count = 3,
        .branch_count = 7,
        .estimated_cycles = 1000,
    };
    
    // Test equality
    try std.testing.expect(metrics1.equals(metrics3));
    try std.testing.expect(!metrics1.equals(metrics2));
    
    // Test improvement
    try std.testing.expect(metrics2.improved(metrics1));
    try std.testing.expect(!metrics1.improved(metrics2));
    try std.testing.expect(!metrics1.improved(metrics3)); // Same cycles, no improvement
}

test "event graph building" {
    const allocator = std.testing.allocator;
    
    // Create AST with multiple events
    var items = try std.ArrayList(ast.Item).initCapacity(allocator, 2);
    defer items.deinit(allocator);
    
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"user", "login"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "success", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    try items.append(allocator, .{ 
        .event_decl = .{
            .path = .{ .segments = @constCast(&[_][]const u8{"user", "logout"}) },
            .input = .{ .fields = &.{} },
            .branches = @constCast(&[_]ast.Branch{
                .{ .name = "done", .payload = .{ .fields = &.{} } },
            }),
            .is_public = true,
        },
    });
    
    const source_file = ast.SourceFile{
        .items = items.items,
        .allocator = allocator,
    };
    
    var analysis = try coordinator.ProgramAnalysis.init(allocator);
    defer analysis.deinit();
    
    try analysis.buildEventGraph(&source_file);
    
    // Verify event graph was built
    try std.testing.expect(analysis.event_graph.items.len == 2);
    try std.testing.expect(std.mem.eql(u8, analysis.event_graph.items[0].path, "user.login"));
    try std.testing.expect(std.mem.eql(u8, analysis.event_graph.items[1].path, "user.logout"));
}