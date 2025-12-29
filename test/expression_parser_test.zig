const std = @import("std");
const testing = std.testing;
const expression_parser = @import("expression_parser");
const ExpressionParser = expression_parser.ExpressionParser;
const Expression = expression_parser.Expression;
const BinaryOp = expression_parser.BinaryOp;
const UnaryOp = expression_parser.UnaryOp;
const Literal = expression_parser.Literal;

test "parse simple number literal" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "42");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .literal);
    try testing.expect(expr.node.literal == .number);
    try testing.expectEqualStrings("42", expr.node.literal.number);
}

test "parse simple string literal" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "\"hello world\"");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .literal);
    try testing.expect(expr.node.literal == .string);
    try testing.expectEqualStrings("hello world", expr.node.literal.string);
}

test "parse boolean literals" {
    const allocator = testing.allocator;
    
    // Test true
    {
        var parser = ExpressionParser.init(allocator, "true");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .literal);
        try testing.expect(expr.node.literal == .boolean);
        try testing.expect(expr.node.literal.boolean == true);
    }
    
    // Test false
    {
        var parser = ExpressionParser.init(allocator, "false");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .literal);
        try testing.expect(expr.node.literal == .boolean);
        try testing.expect(expr.node.literal.boolean == false);
    }
}

test "parse simple identifier" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "myVariable");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .identifier);
    try testing.expectEqualStrings("myVariable", expr.node.identifier);
}

test "parse binary addition" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "1 + 2");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .binary);
    try testing.expect(expr.node.binary.op == .add);
    
    try testing.expect(expr.node.binary.left.* == .literal);
    try testing.expectEqualStrings("1", expr.node.binary.left.literal.number);
    
    try testing.expect(expr.node.binary.right.* == .literal);
    try testing.expectEqualStrings("2", expr.node.binary.right.literal.number);
}

test "parse arithmetic precedence" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "1 + 2 * 3");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // Should parse as 1 + (2 * 3)
    try testing.expect(expr.node == .binary);
    if (expr.* != .binary) {
        std.debug.print("Expected binary, got: {}\n", .{expr.*});
        return error.TestUnexpectedResult;
    }
    if (expr.node.binary.op != .add) {
        std.debug.print("Expected add as root op, got: {}\n", .{expr.node.binary.op});
        return error.TestUnexpectedResult;
    }
    try testing.expect(expr.node.binary.op == .add);
    
    try testing.expect(expr.node.binary.left.* == .literal);
    try testing.expectEqualStrings("1", expr.node.binary.left.literal.number);
    
    try testing.expect(expr.node.binary.right.* == .binary);
    try testing.expect(expr.node.binary.right.binary.op == .multiply);
    try testing.expectEqualStrings("2", expr.node.binary.right.binary.left.literal.number);
    try testing.expectEqualStrings("3", expr.node.binary.right.binary.right.literal.number);
}

test "parse comparison operators" {
    const allocator = testing.allocator;
    
    const test_cases = [_]struct {
        input: []const u8,
        expected_op: expression_parser.Operator,
    }{
        .{ .input = "a == b", .expected_op = .equal },
        .{ .input = "a != b", .expected_op = .not_equal },
        .{ .input = "a < b", .expected_op = .less_than },
        .{ .input = "a <= b", .expected_op = .less_equal },
        .{ .input = "a > b", .expected_op = .greater_than },
        .{ .input = "a >= b", .expected_op = .greater_equal },
    };
    
    for (test_cases) |tc| {
        var parser = ExpressionParser.init(allocator, tc.input);
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .binary);
        try testing.expect(expr.node.binary.op == tc.expected_op);
        try testing.expectEqualStrings("a", expr.node.binary.left.identifier);
        try testing.expectEqualStrings("b", expr.node.binary.right.identifier);
    }
}

test "parse logical operators" {
    const allocator = testing.allocator;
    
    // Test AND
    {
        var parser = ExpressionParser.init(allocator, "a && b");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .binary);
        try testing.expect(expr.node.binary.op == .and_op);
    }
    
    // Test OR
    {
        var parser = ExpressionParser.init(allocator, "a || b");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .binary);
        try testing.expect(expr.node.binary.op == .or_op);
    }
}

test "parse unary operators" {
    const allocator = testing.allocator;
    
    // Test negation
    {
        var parser = ExpressionParser.init(allocator, "-42");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .unary);
        try testing.expect(expr.node.unary.op == .subtract);
        try testing.expectEqualStrings("42", expr.node.unary.operand.literal.number);
    }
    
    // Test logical NOT
    {
        var parser = ExpressionParser.init(allocator, "!true");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .unary);
        try testing.expect(expr.node.unary.op == .not_op);
        try testing.expect(expr.node.unary.operand.literal.boolean == true);
    }
}

test "parse field access" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "obj.field");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .field_access);
    try testing.expectEqualStrings("obj", expr.node.field_access.object.identifier);
    try testing.expectEqualStrings("field", expr.node.field_access.field);
}

test "parse chained field access" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "a.b.c");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .field_access);
    try testing.expectEqualStrings("c", expr.node.field_access.field);
    
    const inner = expr.node.field_access.object;
    try testing.expect(inner.* == .field_access);
    try testing.expectEqualStrings("b", inner.field_access.field);
    try testing.expectEqualStrings("a", inner.field_access.object.identifier);
}


test "parse grouped expression" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "(1 + 2) * 3");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // Should parse as (1 + 2) * 3
    try testing.expect(expr.node == .binary);
    try testing.expect(expr.node.binary.op == .multiply);
    
    try testing.expect(expr.node.binary.left.* == .grouped);
    const inner = expr.node.binary.left.grouped;
    try testing.expect(inner.* == .binary);
    try testing.expect(inner.binary.op == .add);
    try testing.expectEqualStrings("1", inner.binary.left.literal.number);
    try testing.expectEqualStrings("2", inner.binary.right.literal.number);
    
    try testing.expectEqualStrings("3", expr.node.binary.right.literal.number);
}

test "parse complex expression with precedence" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "a.status == 200 && b.valid || c > 0");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // Should parse as ((a.status == 200) && b.valid) || (c > 0)
    try testing.expect(expr.node == .binary);
    try testing.expect(expr.node.binary.op == .or_op);
    
    // Left side: (a.status == 200) && b.valid
    const left = expr.node.binary.left;
    try testing.expect(left.* == .binary);
    try testing.expect(left.binary.op == .and_op);
    
    // Left-left: a.status == 200
    const ll = left.binary.left;
    try testing.expect(ll.* == .binary);
    try testing.expect(ll.binary.op == .equal);
    try testing.expect(ll.binary.left.* == .field_access);
    try testing.expectEqualStrings("200", ll.binary.right.literal.number);
    
    // Left-right: b.valid
    const lr = left.binary.right;
    try testing.expect(lr.* == .field_access);
    try testing.expectEqualStrings("valid", lr.field_access.field);
    
    // Right side: c > 0
    const right = expr.node.binary.right;
    try testing.expect(right.* == .binary);
    try testing.expect(right.binary.op == .greater_than);
    try testing.expectEqualStrings("c", right.binary.left.identifier);
    try testing.expectEqualStrings("0", right.binary.right.literal.number);
}

test "parse string concatenation" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "\"hello\" ++ \" \" ++ \"world\"");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // Should parse as ("hello" ++ " ") ++ "world"
    try testing.expect(expr.node == .binary);
    try testing.expect(expr.node.binary.op == .concat);
    try testing.expectEqualStrings("world", expr.node.binary.right.literal.string);
    
    const left = expr.node.binary.left;
    try testing.expect(left.* == .binary);
    try testing.expect(left.binary.op == .concat);
    try testing.expectEqualStrings("hello", left.binary.left.literal.string);
    try testing.expectEqualStrings(" ", left.binary.right.literal.string);
}


fn freeExpression(allocator: std.mem.Allocator, expr: *Expression) void {
    switch (expr.*) {
        .literal => |lit| {
            switch (lit) {
                .number => |n| allocator.free(n),
                .string => |s| allocator.free(s),
                .boolean => {},
            }
        },
        .identifier => |id| allocator.free(id),
        .binary => |bin| {
            freeExpression(allocator, bin.left);
            freeExpression(allocator, bin.right);
        },
        .unary => |un| {
            freeExpression(allocator, un.operand);
        },
        .field_access => |fa| {
            freeExpression(allocator, fa.object);
            allocator.free(fa.field);
        },
        .grouped => |g| {
            freeExpression(allocator, g);
        },
    }
    allocator.destroy(expr);
}