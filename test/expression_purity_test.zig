const std = @import("std");
const testing = std.testing;
const expression_parser = @import("expression_parser");
const ExpressionParser = expression_parser.ExpressionParser;

test "containsFunctionCall detects function calls" {
    const allocator = testing.allocator;

    // foo(x) → function_call → true
    {
        var parser = ExpressionParser.init(allocator, "foo(x)");
        defer parser.deinit();
        const expr = try parser.parse();
        defer expr.deinit(allocator);
        try testing.expect(expression_parser.containsFunctionCall(expr));
    }

    // obj.method(x) → function_call → true
    {
        var parser = ExpressionParser.init(allocator, "obj.method(x)");
        defer parser.deinit();
        const expr = try parser.parse();
        defer expr.deinit(allocator);
        try testing.expect(expression_parser.containsFunctionCall(expr));
    }

    // helper(g.msg) nested in binary → true
    {
        var parser = ExpressionParser.init(allocator, "a + helper(g.msg)");
        defer parser.deinit();
        const expr = try parser.parse();
        defer expr.deinit(allocator);
        try testing.expect(expression_parser.containsFunctionCall(expr));
    }
}

test "containsFunctionCall allows pure expressions" {
    const allocator = testing.allocator;

    const pure_expressions = [_][]const u8{
        "42",
        "true",
        "x",
        "obj.field",
        "a + b",
        "a.b + c.d * 2",
        "@as(i32, 5)",
        "@intCast(x)",
        "arr[0]",
        "acc.dv[i][0]",
        "acc.sum + @as(i64, item)",
    };

    for (pure_expressions) |expr_str| {
        var parser = ExpressionParser.init(allocator, expr_str);
        defer parser.deinit();
        const expr = parser.parse() catch |err| {
            std.debug.print("Failed to parse '{s}': {}\n", .{ expr_str, err });
            return err;
        };
        defer expr.deinit(allocator);
        try testing.expect(!expression_parser.containsFunctionCall(expr));
    }
}

test "containsFunctionCall detects nested function calls in builtins" {
    const allocator = testing.allocator;

    // @as(i32, foo(x)) has a function_call nested inside builtin_call
    var parser = ExpressionParser.init(allocator, "@as(i32, foo(x))");
    defer parser.deinit();
    const expr = try parser.parse();
    defer expr.deinit(allocator);
    try testing.expect(expression_parser.containsFunctionCall(expr));
}
