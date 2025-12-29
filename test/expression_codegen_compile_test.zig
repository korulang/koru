const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const expression_codegen = @import("expression_codegen");

test "generated logical operators compile in Zig" {
    const allocator = testing.allocator;
    
    // Test AND operator
    {
        var expr = ast.Expression{
            .node = .{
                .binary = .{
                    .left = try allocator.create(ast.Expression),
                    .op = .and_op,
                    .right = try allocator.create(ast.Expression),
                },
            },
        };
        defer allocator.destroy(expr.node.binary.left);
        defer allocator.destroy(expr.node.binary.right);
        
        expr.node.binary.left.* = ast.Expression{
            .node = .{ .literal = .{ .boolean = true } },
        };
        expr.node.binary.right.* = ast.Expression{
            .node = .{ .literal = .{ .boolean = false } },
        };
        
        var codegen = expression_codegen.ExpressionCodegen.init(allocator);
        defer codegen.deinit();
        
        const code = try codegen.generate(&expr);
        defer allocator.free(code);
        
        // Verify it generates 'and' (correct Zig logical operator)
        try testing.expectEqualStrings("true and false", code);
        
        // Test that the generated code compiles by creating a test program
        const test_program = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\test "generated code compiles" {{
            \\    const result = {s};
            \\    try std.testing.expect(result == false);
            \\}}
        , .{code});
        defer allocator.free(test_program);
        
        // Write to temp file
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        
        const test_file = try tmp_dir.dir.createFile("test_and.zig", .{});
        defer test_file.close();
        try test_file.writeAll(test_program);
        
        // Compile and run the test
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "test", "test_and.zig" },
            .cwd_dir = tmp_dir.dir,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        // Check compilation succeeded
        try testing.expect(result.term == .Exited);
        try testing.expectEqual(@as(u8, 0), result.term.Exited);
    }
    
    // Test OR operator
    {
        var expr = ast.Expression{
            .node = .{
                .binary = .{
                    .left = try allocator.create(ast.Expression),
                    .op = .or_op,
                    .right = try allocator.create(ast.Expression),
                },
            },
        };
        defer allocator.destroy(expr.node.binary.left);
        defer allocator.destroy(expr.node.binary.right);
        
        expr.node.binary.left.* = ast.Expression{
            .node = .{ .literal = .{ .boolean = true } },
        };
        expr.node.binary.right.* = ast.Expression{
            .node = .{ .literal = .{ .boolean = false } },
        };
        
        var codegen = expression_codegen.ExpressionCodegen.init(allocator);
        defer codegen.deinit();
        
        const code = try codegen.generate(&expr);
        defer allocator.free(code);
        
        // Verify it generates 'or' (correct Zig logical operator)
        try testing.expectEqualStrings("true or false", code);
        
        // Test that the generated code compiles
        const test_program = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\test "generated code compiles" {{
            \\    const result = {s};
            \\    try std.testing.expect(result == true);
            \\}}
        , .{code});
        defer allocator.free(test_program);
        
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();
        
        const test_file = try tmp_dir.dir.createFile("test_or.zig", .{});
        defer test_file.close();
        try test_file.writeAll(test_program);
        
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "test", "test_or.zig" },
            .cwd_dir = tmp_dir.dir,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        try testing.expect(result.term == .Exited);
        try testing.expectEqual(@as(u8, 0), result.term.Exited);
    }
}

test "complex expression with all operators compiles" {
    const allocator = testing.allocator;
    
    // Build: (x > 5 && y < 10) || (z == 0)
    const x_gt_5 = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .greater,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(x_gt_5.node.binary.left);
    defer allocator.destroy(x_gt_5.node.binary.right);
    x_gt_5.node.binary.left.* = .{ .node = .{ .identifier = "x" } };
    x_gt_5.node.binary.right.* = .{ .node = .{ .literal = .{ .number = "5" } } };
    
    const y_lt_10 = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .less,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(y_lt_10.node.binary.left);
    defer allocator.destroy(y_lt_10.node.binary.right);
    y_lt_10.node.binary.left.* = .{ .node = .{ .identifier = "y" } };
    y_lt_10.node.binary.right.* = .{ .node = .{ .literal = .{ .number = "10" } } };
    
    const and_expr = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .and_op,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(and_expr.node.binary.left);
    defer allocator.destroy(and_expr.node.binary.right);
    and_expr.node.binary.left.* = x_gt_5;
    and_expr.node.binary.right.* = y_lt_10;
    
    const z_eq_0 = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .equal,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(z_eq_0.node.binary.left);
    defer allocator.destroy(z_eq_0.node.binary.right);
    z_eq_0.node.binary.left.* = .{ .node = .{ .identifier = "z" } };
    z_eq_0.node.binary.right.* = .{ .node = .{ .literal = .{ .number = "0" } } };
    
    const or_expr = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .or_op,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(or_expr.node.binary.left);
    defer allocator.destroy(or_expr.node.binary.right);
    or_expr.node.binary.left.* = and_expr;
    or_expr.node.binary.right.* = z_eq_0;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    const code = try codegen.generate(&or_expr);
    defer allocator.free(code);
    
    // Should generate: x > 5 and y < 10 or z == 0 (proper Zig operators)
    try testing.expect(std.mem.indexOf(u8, code, "and") != null);
    try testing.expect(std.mem.indexOf(u8, code, "or") != null);
    try testing.expect(std.mem.indexOf(u8, code, "&&") == null);
    try testing.expect(std.mem.indexOf(u8, code, "||") == null);
    
    std.debug.print("\nGenerated expression: {s}\n", .{code});
    
    // Test compilation with actual values
    const test_program = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\test "complex expression compiles" {{
        \\    const x: i32 = 6;
        \\    const y: i32 = 8;
        \\    const z: i32 = 0;
        \\    const result = {s};
        \\    try std.testing.expect(result == true);
        \\}}
    , .{code});
    defer allocator.free(test_program);
    
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const test_file = try tmp_dir.dir.createFile("test_complex.zig", .{});
    defer test_file.close();
    try test_file.writeAll(test_program);
    
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig", "test", "test_complex.zig" },
        .cwd_dir = tmp_dir.dir,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("Compilation failed:\n{s}\n", .{result.stderr});
    }
    
    try testing.expect(result.term == .Exited);
    try testing.expectEqual(@as(u8, 0), result.term.Exited);
}