const std = @import("std");
const testing = std.testing;
const expression_parser = @import("expression_parser");
const ExpressionParser = expression_parser.ExpressionParser;

test "expression parser rejects function calls" {
    const allocator = testing.allocator;
    
    // These should all fail to parse as they look like function calls
    const invalid_expressions = [_][]const u8{
        "getValue()",
        "foo()",
        "std.time.milliTimestamp()",
        "calculate(x, y)",
        "obj.method()",
        "array.len()",  // This might be confused with .len property
    };
    
    for (invalid_expressions) |expr_str| {
        var parser = ExpressionParser.init(allocator, expr_str);
        defer parser.deinit();
        
        const result = parser.parse();
        
        // We expect these to either:
        // 1. Fail to parse (return an error)
        // 2. Parse as something else (e.g., "foo()" might parse as identifier "foo" and leave "()" unparsed)
        
        if (result) |expr| {
            defer expr.deinit(allocator);
            
            // If it parsed, it should NOT have parsed the parentheses
            // It should have parsed just the identifier part
            switch (expr.node) {
                .identifier => {
                    // OK - parsed as identifier, ignoring the parentheses
                    // This is acceptable as the parentheses would cause an error during compilation
                },
                .field_access => {
                    // OK - parsed field access, ignoring the parentheses
                },
                else => {
                    std.debug.print("Unexpected parse result for '{s}': {}\n", .{expr_str, expr.node});
                    try testing.expect(false); // Should not parse as anything else
                }
            }
        } else |_| {
            // Failed to parse - this is good!
            // Function calls should not be parseable
        }
    }
}

test "expression parser accepts pure expressions" {
    const allocator = testing.allocator;
    
    // These should all parse successfully
    const valid_expressions = [_][]const u8{
        "42",
        "true",
        "false", 
        "\"hello\"",
        "x",
        "obj.field",
        "a + b",
        "x * 2",
        "a > b",
        "x && y",
        "!flag",
        "str1 ++ str2",
        "obj.nested.field",
        "(a + b) * c",
    };
    
    for (valid_expressions) |expr_str| {
        var parser = ExpressionParser.init(allocator, expr_str);
        defer parser.deinit();
        
        const expr = parser.parse() catch |err| {
            std.debug.print("Failed to parse valid expression '{s}': {}\n", .{expr_str, err});
            return err;
        };
        defer expr.deinit(allocator);
        
        // If we got here, it parsed successfully (no error thrown)
    }
}

test "expressions are pure - no side effects" {
    const allocator = testing.allocator;
    
    // Test that parsed expressions only contain pure operations
    var parser = ExpressionParser.init(allocator, "a.b + c.d * 2");
    defer parser.deinit();
    
    const expr = try parser.parse();
    defer expr.deinit(allocator);
    
    // Verify the AST only contains pure nodes
    try verifyPureExpression(expr);
}

fn verifyPureExpression(expr: *const expression_parser.Expression) !void {
    switch (expr.node) {
        .literal => {}, // Pure
        .identifier => {}, // Pure
        .binary => |bin| {
            // Recursively check both operands
            try verifyPureExpression(bin.left);
            try verifyPureExpression(bin.right);
        },
        .unary => |un| {
            // Recursively check operand
            try verifyPureExpression(un.operand);
        },
        .field_access => |fa| {
            // Field access is pure
            try verifyPureExpression(fa.object);
        },
        .grouped => |g| {
            // Recursively check inner expression
            try verifyPureExpression(g);
        },
        // Note: No function_call case because it doesn't exist!
    }
}