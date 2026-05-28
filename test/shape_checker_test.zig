const std = @import("std");
const testing = std.testing;
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const shape_checker = @import("shape_checker");

test "validate complete flow" {
    const source =
        \\~event A { x: i32 }
        \\| ok i32
        \\
        \\~A(x: 1)
        \\| ok _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate incomplete flow" {
    const source =
        \\~event read { path: []const u8 }
        \\| ok { contents: []const u8, errno: u8 }
        \\| err { errno: u8, message: []const u8 }
        \\
        \\~read(path: "test.txt")
        \\| ok _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.IncompleteBranchCoverage, result);
}

test "validate proc without event" {
    const source =
        \\~proc mystery_handler|zig {
        \\    return .{};
        \\}
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.ProcWithoutEvent, result);
}

test "validate flow with unknown event" {
    const source =
        \\~missing(path: "value")
        \\| ok _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.UnknownEvent, result);
}

test "validate event tap with known events" {
    // ~tap() is lowered by the tap transform; raw parse sees it as ~tap(...) flow.
    if (true) return error.SkipZigTest;
    const source =
        \\~event read { path: []const u8 }
        \\| ok { contents: []const u8, size: u32 }
        \\| err { errno: u8, message: []const u8 }
        \\
        \\~event audit_log { message: []const u8, path: []const u8 }
        \\| ok {}
        \\
        \\~tap(read -> audit_log)
        \\| ok _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate event tap with wildcard destination" {
    if (true) return error.SkipZigTest;
    const source =
        \\~event read { path: []const u8 }
        \\| ok { contents: []const u8, size: u32 }
        \\| err { errno: u8, message: []const u8 }
        \\
        \\~tap(read -> *)
        \\| err _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate event tap with unknown source" {
    if (true) return error.SkipZigTest;
    const source =
        \\~event audit_log { message: []const u8, path: []const u8 }
        \\| ok {}
        \\
        \\~tap(missing -> audit_log)
        \\| ok _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.ValidationFailed, result);
}

test "validate event tap with invalid branch" {
    if (true) return error.SkipZigTest;
    const source =
        \\~event read { path: []const u8 }
        \\| ok { contents: []const u8, size: u32 }
        \\| err { errno: u8, message: []const u8 }
        \\
        \\~tap(read -> *)
        \\| bogus _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.ValidationFailed, result);
}

test "validate event tap non-exhaustive is OK" {
    if (true) return error.SkipZigTest;
    const source =
        \\~event read { path: []const u8 }
        \\| ok { contents: []const u8, size: u32 }
        \\| err { errno: u8, message: []const u8 }
        \\| timeout {}
        \\
        \\~tap(read -> *)
        \\| ok _ |> _
        \\| err _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate wildcard tap with transition branch" {
    if (true) return error.SkipZigTest;
    const source =
        \\~tap(* -> *)
        \\| transition _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    try checker.checkSourceFile(&parse_result.source_file);
}

test "void event with branch constructor in inline flow should fail" {
    if (true) return error.SkipZigTest;
    const source =
        \\~event helper { input: u32 }
        \\| ok { value: u32, tag: u32 }
        \\
        \\~event test_event { input: u32 }
        \\| ok {}
        \\
        \\~proc helper|zig {
        \\    return .{ .ok = .{ .value = e.input * 2, .tag = 0 } };
        \\}
        \\
        \\~proc test_event|zig {
        \\    ~helper(input: e.input)
        \\    | ok o |> result { value: o.value }
        \\}
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.BranchDoesNotExist, result);
}
