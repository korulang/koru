const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const expression_codegen = @import("expression_codegen");

test "generate simple literal" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    const expr = ast.Expression{
        .node = .{ .literal = .{ .number = "42" } },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("42", code);
}

test "generate string literal" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    const expr = ast.Expression{
        .node = .{ .literal = .{ .string = "hello" } },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("\"hello\"", code);
}

test "generate binary operations" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create: 5 + 3
    var expr = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .add,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(expr.node.binary.left);
    defer allocator.destroy(expr.node.binary.right);
    
    expr.node.binary.left.* = ast.Expression{
        .node = .{ .literal = .{ .number = "5" } },
    };
    expr.node.binary.right.* = ast.Expression{
        .node = .{ .literal = .{ .number = "3" } },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("5 + 3", code);
}

test "generate comparison operations" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create: x > 10
    var expr = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .greater,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(expr.node.binary.left);
    defer allocator.destroy(expr.node.binary.right);
    
    expr.node.binary.left.* = ast.Expression{
        .node = .{ .identifier = "x" },
    };
    expr.node.binary.right.* = ast.Expression{
        .node = .{ .literal = .{ .number = "10" } },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("x > 10", code);
}

test "generate logical operations with proper Zig syntax" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Test AND: a && b
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
            .node = .{ .identifier = "a" },
        };
        expr.node.binary.right.* = ast.Expression{
            .node = .{ .identifier = "b" },
        };
        
        const code = try codegen.generate(&expr);
        defer allocator.free(code);
        
        try testing.expectEqualStrings("a and b", code);
    }
    
    // Test OR: x || y
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
            .node = .{ .identifier = "x" },
        };
        expr.node.binary.right.* = ast.Expression{
            .node = .{ .identifier = "y" },
        };
        
        const code = try codegen.generate(&expr);
        defer allocator.free(code);
        
        try testing.expectEqualStrings("x or y", code);
    }
}

test "generate unary operations" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create: !flag
    var expr = ast.Expression{
        .node = .{
            .unary = .{
                .op = .not,
                .operand = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(expr.node.unary.operand);
    
    expr.node.unary.operand.* = ast.Expression{
        .node = .{ .identifier = "flag" },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("!flag", code);
}

test "generate field access" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create: user.name
    var expr = ast.Expression{
        .node = .{
            .field_access = .{
                .object = try allocator.create(ast.Expression),
                .field = "name",
            },
        },
    };
    defer allocator.destroy(expr.node.field_access.object);
    
    expr.node.field_access.object.* = ast.Expression{
        .node = .{ .identifier = "user" },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("user.name", code);
}

test "generate grouped expression" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create: (a + b)
    const inner = try allocator.create(ast.Expression);
    defer allocator.destroy(inner);
    
    inner.* = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .add,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(inner.node.binary.left);
    defer allocator.destroy(inner.node.binary.right);
    
    inner.node.binary.left.* = ast.Expression{
        .node = .{ .identifier = "a" },
    };
    inner.node.binary.right.* = ast.Expression{
        .node = .{ .identifier = "b" },
    };
    
    const expr = ast.Expression{
        .node = .{ .grouped = inner },
    };
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("(a + b)", code);
}

test "generate complex nested expression" {
    const allocator = testing.allocator;
    
    var codegen = expression_codegen.ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create: response.status == 200 && response.ok
    const status_access = ast.Expression{
        .node = .{
            .field_access = .{
                .object = try allocator.create(ast.Expression),
                .field = "status",
            },
        },
    };
    defer allocator.destroy(status_access.node.field_access.object);
    status_access.node.field_access.object.* = ast.Expression{
        .node = .{ .identifier = "response" },
    };
    
    const status_eq = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .equal,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(status_eq.node.binary.left);
    defer allocator.destroy(status_eq.node.binary.right);
    status_eq.node.binary.left.* = status_access;
    status_eq.node.binary.right.* = ast.Expression{
        .node = .{ .literal = .{ .number = "200" } },
    };
    
    const ok_access = ast.Expression{
        .node = .{
            .field_access = .{
                .object = try allocator.create(ast.Expression),
                .field = "ok",
            },
        },
    };
    defer allocator.destroy(ok_access.node.field_access.object);
    ok_access.node.field_access.object.* = ast.Expression{
        .node = .{ .identifier = "response" },
    };
    
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
    expr.node.binary.left.* = status_eq;
    expr.node.binary.right.* = ok_access;
    
    const code = try codegen.generate(&expr);
    defer allocator.free(code);
    
    try testing.expectEqualStrings("response.status == 200 and response.ok", code);
}

test "generate where condition" {
    const allocator = testing.allocator;
    
    // Create: x > 5
    var expr = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .greater,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(expr.node.binary.left);
    defer allocator.destroy(expr.node.binary.right);
    
    expr.node.binary.left.* = ast.Expression{
        .node = .{ .identifier = "x" },
    };
    expr.node.binary.right.* = ast.Expression{
        .node = .{ .literal = .{ .number = "5" } },
    };
    
    const code = try expression_codegen.generateWhereCondition(
        allocator,
        &expr,
        null,
    );
    defer allocator.free(code);
    
    try testing.expectEqualStrings("if (x > 5)", code);
}

test "generate continuation with where clause" {
    const allocator = testing.allocator;
    
    // Create expression: value > 100
    var expr = ast.Expression{
        .node = .{
            .binary = .{
                .left = try allocator.create(ast.Expression),
                .op = .greater,
                .right = try allocator.create(ast.Expression),
            },
        },
    };
    defer allocator.destroy(expr.node.binary.left);
    defer allocator.destroy(expr.node.binary.right);
    
    expr.node.binary.left.* = ast.Expression{
        .node = .{ .identifier = "value" },
    };
    expr.node.binary.right.* = ast.Expression{
        .node = .{ .literal = .{ .number = "100" } },
    };
    
    const cont = ast.Continuation{
        .branch = "ok",
        .binding = "value",
        .condition = "value > 100",
        .condition_expr = &expr,
        .pipeline = &[_]ast.Step{},
        .indent = 0,
        .nested = &[_]ast.Continuation{},
    };
    
    const code = try expression_codegen.generateContinuationWithWhere(
        allocator,
        &cont,
        4,
    );
    defer allocator.free(code);
    
    // Check structure
    try testing.expect(std.mem.indexOf(u8, code, ".ok => |value|") != null);
    try testing.expect(std.mem.indexOf(u8, code, "if (value > 100)") != null);
}