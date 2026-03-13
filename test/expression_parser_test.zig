const std = @import("std");
const testing = std.testing;
const expression_parser = @import("expression_parser");
const ast = @import("ast");
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
    
    try testing.expect(expr.node.binary.left.node == .literal);
    try testing.expectEqualStrings("1", expr.node.binary.left.node.literal.number);

    try testing.expect(expr.node.binary.right.node == .literal);
    try testing.expectEqualStrings("2", expr.node.binary.right.node.literal.number);
}

test "parse arithmetic precedence" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "1 + 2 * 3");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // Should parse as 1 + (2 * 3)
    try testing.expect(expr.node == .binary);
    if (expr.node != .binary) {
        std.debug.print("Expected binary, got: {}\n", .{expr.node});
        return error.TestUnexpectedResult;
    }
    if (expr.node.binary.op != .add) {
        std.debug.print("Expected add as root op, got: {}\n", .{expr.node.binary.op});
        return error.TestUnexpectedResult;
    }
    try testing.expect(expr.node.binary.op == .add);
    
    try testing.expect(expr.node.binary.left.node == .literal);
    try testing.expectEqualStrings("1", expr.node.binary.left.node.literal.number);

    try testing.expect(expr.node.binary.right.node == .binary);
    try testing.expect(expr.node.binary.right.node.binary.op == .multiply);
    try testing.expectEqualStrings("2", expr.node.binary.right.node.binary.left.node.literal.number);
    try testing.expectEqualStrings("3", expr.node.binary.right.node.binary.right.node.literal.number);
}

test "parse comparison operators" {
    const allocator = testing.allocator;
    
    const test_cases = [_]struct {
        input: []const u8,
        expected_op: expression_parser.BinaryOperator,
    }{
        .{ .input = "a == b", .expected_op = .equal },
        .{ .input = "a != b", .expected_op = .not_equal },
        .{ .input = "a < b", .expected_op = .less },
        .{ .input = "a <= b", .expected_op = .less_equal },
        .{ .input = "a > b", .expected_op = .greater },
        .{ .input = "a >= b", .expected_op = .greater_equal },
    };
    
    for (test_cases) |tc| {
        var parser = ExpressionParser.init(allocator, tc.input);
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .binary);
        try testing.expect(expr.node.binary.op == tc.expected_op);
        try testing.expectEqualStrings("a", expr.node.binary.left.node.identifier);
        try testing.expectEqualStrings("b", expr.node.binary.right.node.identifier);
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
        try testing.expect(expr.node.unary.op == .negate);
        try testing.expectEqualStrings("42", expr.node.unary.operand.node.literal.number);
    }
    
    // Test logical NOT
    {
        var parser = ExpressionParser.init(allocator, "!true");
        defer parser.deinit();
        
        const expr = try parser.parse();
        defer freeExpression(allocator, expr);
        
        try testing.expect(expr.node == .unary);
        try testing.expect(expr.node.unary.op == .not);
        try testing.expect(expr.node.unary.operand.node.literal.boolean == true);
    }
}

test "parse field access" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "obj.field");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .field_access);
    try testing.expectEqualStrings("obj", expr.node.field_access.object.node.identifier);
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
    try testing.expect(inner.node == .field_access);
    try testing.expectEqualStrings("b", inner.node.field_access.field);
    try testing.expectEqualStrings("a", inner.node.field_access.object.node.identifier);
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
    
    try testing.expect(expr.node.binary.left.node == .grouped);
    const inner = expr.node.binary.left.node.grouped;
    try testing.expect(inner.node == .binary);
    try testing.expect(inner.node.binary.op == .add);
    try testing.expectEqualStrings("1", inner.node.binary.left.node.literal.number);
    try testing.expectEqualStrings("2", inner.node.binary.right.node.literal.number);

    try testing.expectEqualStrings("3", expr.node.binary.right.node.literal.number);
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
    try testing.expect(left.node == .binary);
    try testing.expect(left.node.binary.op == .and_op);

    // Left-left: a.status == 200
    const ll = left.node.binary.left;
    try testing.expect(ll.node == .binary);
    try testing.expect(ll.node.binary.op == .equal);
    try testing.expect(ll.node.binary.left.node == .field_access);
    try testing.expectEqualStrings("200", ll.node.binary.right.node.literal.number);

    // Left-right: b.valid
    const lr = left.node.binary.right;
    try testing.expect(lr.node == .field_access);
    try testing.expectEqualStrings("valid", lr.node.field_access.field);

    // Right side: c > 0
    const right = expr.node.binary.right;
    try testing.expect(right.node == .binary);
    try testing.expect(right.node.binary.op == .greater);
    try testing.expectEqualStrings("c", right.node.binary.left.node.identifier);
    try testing.expectEqualStrings("0", right.node.binary.right.node.literal.number);
}

test "parse string concatenation" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "\"hello\" ++ \" \" ++ \"world\"");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // Should parse as ("hello" ++ " ") ++ "world"
    try testing.expect(expr.node == .binary);
    try testing.expect(expr.node.binary.op == .string_concat);
    try testing.expectEqualStrings("world", expr.node.binary.right.node.literal.string);

    const left = expr.node.binary.left;
    try testing.expect(left.node == .binary);
    try testing.expect(left.node.binary.op == .string_concat);
    try testing.expectEqualStrings("hello", left.node.binary.left.node.literal.string);
    try testing.expectEqualStrings(" ", left.node.binary.right.node.literal.string);
}


test "parse builtin call @as" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "@as(i32, 5)");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .builtin_call);
    try testing.expectEqualStrings("as", expr.node.builtin_call.name);
    try testing.expect(expr.node.builtin_call.args.len == 2);
    try testing.expect(expr.node.builtin_call.args[0].node == .identifier);
    try testing.expectEqualStrings("i32", expr.node.builtin_call.args[0].node.identifier);
    try testing.expect(expr.node.builtin_call.args[1].node == .literal);
    try testing.expectEqualStrings("5", expr.node.builtin_call.args[1].node.literal.number);
}

test "parse builtin call @intCast" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "@intCast(x)");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .builtin_call);
    try testing.expectEqualStrings("intCast", expr.node.builtin_call.name);
    try testing.expect(expr.node.builtin_call.args.len == 1);
    try testing.expect(expr.node.builtin_call.args[0].node == .identifier);
}

test "parse array indexing" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "arr[0]");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .array_index);
    try testing.expect(expr.node.array_index.object.node == .identifier);
    try testing.expectEqualStrings("arr", expr.node.array_index.object.node.identifier);
    try testing.expect(expr.node.array_index.index.node == .literal);
    try testing.expectEqualStrings("0", expr.node.array_index.index.node.literal.number);
}

test "parse nested array indexing with field access" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "acc.dv[i][0]");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // acc.dv[i][0] → array_index(array_index(field_access(acc, dv), i), 0)
    try testing.expect(expr.node == .array_index);
    try testing.expectEqualStrings("0", expr.node.array_index.index.node.literal.number);

    const inner = expr.node.array_index.object;
    try testing.expect(inner.node == .array_index);
    try testing.expect(inner.node.array_index.index.node == .identifier);
    try testing.expectEqualStrings("i", inner.node.array_index.index.node.identifier);

    const fa = inner.node.array_index.object;
    try testing.expect(fa.node == .field_access);
    try testing.expectEqualStrings("dv", fa.node.field_access.field);
    try testing.expectEqualStrings("acc", fa.node.field_access.object.node.identifier);
}

test "parse conditional expression" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "if(x > 5) a else b");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .conditional);
    try testing.expect(expr.node.conditional.condition.node == .binary);
    try testing.expect(expr.node.conditional.then_expr.node == .identifier);
    try testing.expectEqualStrings("a", expr.node.conditional.then_expr.node.identifier);
    try testing.expect(expr.node.conditional.else_expr.node == .identifier);
    try testing.expectEqualStrings("b", expr.node.conditional.else_expr.node.identifier);
}

test "parse complex expression with builtin" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "acc.sum + @as(i64, item) * cfg.multiplier");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    // acc.sum + (@as(i64, item) * cfg.multiplier)
    try testing.expect(expr.node == .binary);
    try testing.expect(expr.node.binary.op == .add);
    try testing.expect(expr.node.binary.left.node == .field_access);

    const right = expr.node.binary.right;
    try testing.expect(right.node == .binary);
    try testing.expect(right.node.binary.op == .multiply);
    try testing.expect(right.node.binary.left.node == .builtin_call);
    try testing.expectEqualStrings("as", right.node.binary.left.node.builtin_call.name);
}

test "parse function call" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "foo(x, y)");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expr.node == .function_call);
    try testing.expect(expr.node.function_call.args.len == 2);
    try testing.expect(expr.node.function_call.callee.node == .identifier);
    try testing.expectEqualStrings("foo", expr.node.function_call.callee.node.identifier);
}

test "containsFunctionCall returns false for pure expressions" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "acc.sum + @as(i64, item)");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(!expression_parser.containsFunctionCall(expr));
}

test "containsFunctionCall returns true for function calls" {
    const allocator = testing.allocator;
    var parser = ExpressionParser.init(allocator, "foo(x)");
    defer parser.deinit();

    const expr = try parser.parse();
    defer freeExpression(allocator, expr);

    try testing.expect(expression_parser.containsFunctionCall(expr));
}

// ============================================================================
// tryParseArgExpression tests
// ============================================================================

/// Local test helper: attempt to parse an arg's value as an expression.
/// Mirrors the logic in parser.tryParseArgExpression / flow_parser.tryParseArgExpr.
fn tryParseArgExpression(allocator: std.mem.Allocator, arg: *ast.Arg) void {
    const trimmed = std.mem.trim(u8, arg.value, " \t");
    if (trimmed.len == 0 or trimmed[0] == '{') return;

    var expr_p = ExpressionParser.init(allocator, arg.value);
    defer expr_p.deinit();

    if (expr_p.parse()) |expr| {
        const remaining = std.mem.trim(u8, expr_p.input[expr_p.pos..], " \t");
        if (remaining.len == 0) {
            arg.parsed_expression = expr;
        } else {
            var mutable_expr = @constCast(expr);
            mutable_expr.deinit(allocator);
        }
    } else |_| {}
}

test "tryParseArgExpression parses number literal" {
    const allocator = testing.allocator;
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "x"),
        .value = try allocator.dupe(u8, "42"),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    try testing.expect(arg.parsed_expression != null);
    try testing.expect(arg.parsed_expression.?.node == .literal);
    try testing.expect(arg.parsed_expression.?.node.literal == .number);
}

test "tryParseArgExpression parses binary expression" {
    const allocator = testing.allocator;
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "x"),
        .value = try allocator.dupe(u8, "a + b"),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    try testing.expect(arg.parsed_expression != null);
    try testing.expect(arg.parsed_expression.?.node == .binary);
}

test "tryParseArgExpression parses field access" {
    const allocator = testing.allocator;
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "x"),
        .value = try allocator.dupe(u8, "obj.field"),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    try testing.expect(arg.parsed_expression != null);
    try testing.expect(arg.parsed_expression.?.node == .field_access);
}

test "tryParseArgExpression parses builtin call" {
    const allocator = testing.allocator;
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "x"),
        .value = try allocator.dupe(u8, "@as(i32, x)"),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    try testing.expect(arg.parsed_expression != null);
    try testing.expect(arg.parsed_expression.?.node == .builtin_call);
}

test "tryParseArgExpression skips source blocks" {
    const allocator = testing.allocator;
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "source"),
        .value = try allocator.dupe(u8, "{ some source block }"),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    try testing.expect(arg.parsed_expression == null);
}

test "tryParseArgExpression leaves null for unparseable values" {
    const allocator = testing.allocator;
    // Module path with colons — not a valid expression
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "target"),
        .value = try allocator.dupe(u8, "std.io:write"),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    // Should be null because ":write" remains after parsing "std.io"
    try testing.expect(arg.parsed_expression == null);
}

test "tryParseArgExpression leaves null for empty value" {
    const allocator = testing.allocator;
    var arg = ast.Arg{
        .name = try allocator.dupe(u8, "x"),
        .value = try allocator.dupe(u8, ""),
    };
    tryParseArgExpression(allocator, &arg);
    defer arg.deinit(allocator);

    try testing.expect(arg.parsed_expression == null);
}

fn freeExpression(allocator: std.mem.Allocator, expr: *Expression) void {
    switch (expr.node) {
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
        .builtin_call => |bc| {
            for (bc.args) |arg| {
                freeExpression(allocator, arg);
            }
            allocator.free(bc.args);
            allocator.free(bc.name);
        },
        .array_index => |ai| {
            freeExpression(allocator, ai.object);
            freeExpression(allocator, ai.index);
        },
        .conditional => |c| {
            freeExpression(allocator, c.condition);
            freeExpression(allocator, c.then_expr);
            freeExpression(allocator, c.else_expr);
        },
        .function_call => |fc| {
            freeExpression(allocator, fc.callee);
            for (fc.args) |arg| {
                freeExpression(allocator, arg);
            }
            allocator.free(fc.args);
        },
    }
    allocator.destroy(expr);
}