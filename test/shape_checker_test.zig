const std = @import("std");
const testing = std.testing;
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const ast = @import("ast");
const shape_checker = @import("shape_checker");

test "validate complete flow" {
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u8 }
        \\
        \\~file.read (path:"test.txt")
        \\| success s |> _
        \\| failure f |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should pass - all branches covered
    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate incomplete flow" {
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u8 }
        \\
        \\~file.read (path:"test.txt")
        \\| success s |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should fail - missing failure branch
    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.IncompleteBranchCoverage, result);
}

test "validate proc without event" {
    const source =
        \\~proc mystery.handler {
        \\    return .ok(.{});
        \\}
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should fail - proc without matching event
    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.ProcWithoutEvent, result);
}

test "validate flow with unknown event" {
    const source =
        \\~nonexistent.event (arg:"value")
        \\| ok |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should fail - unknown event
    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.UnknownEvent, result);
}

test "validate event tap with known events" {
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u8 }
        \\
        \\~event audit.log { message: []const u8, path: []const u8 }
        \\
        \\~file.read -> audit.log
        \\| success s |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should pass - valid tap with known events
    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate event tap with wildcard destination" {
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u8 }
        \\
        \\~file.read -> *
        \\| failure f |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should pass - tap doesn't need to be exhaustive
    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate event tap with unknown source" {
    const source =
        \\~event audit.log { message: []const u8 }
        \\
        \\~unknown.event -> audit.log
        \\| branch b |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should fail - unknown source event
    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.UnknownEvent, result);
}

test "validate event tap with invalid branch" {
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u8 }
        \\
        \\~file.read -> *
        \\| nonexistent n |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should fail - invalid branch name
    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.UnknownBranch, result);
}

test "validate event tap non-exhaustive is OK" {
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u8 }
        \\| timeout {}
        \\
        \\~file.read -> *
        \\| success s |> _
        \\| failure f |> _
        \\// Note: timeout branch not handled - this is OK for taps!
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should pass - taps don't need to be exhaustive
    try checker.checkSourceFile(&parse_result.source_file);
}

test "validate wildcard tap with transition branch" {
    const source =
        \\~* -> *
        \\| transition t |> _
    ;
    
    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();
    
    // Should pass - transition branch is special for universal taps
    try checker.checkSourceFile(&parse_result.source_file);
}

test "void event with branch constructor in inline flow should fail" {
    const source =
        \\~event helper { input: u32 }
        \\| ok { value: u32 }
        \\
        \\~event test_event { input: u32 }
        \\
        \\~proc helper {
        \\    return .{ .ok = .{ .value = e.input * 2 } };
        \\}
        \\
        \\~proc test_event {
        \\    ~helper(input: e.input)
        \\    | ok o |> result { value: o.value }
        \\}
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz");
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = parser.reporter;
    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &reporter);
    defer checker.deinit();

    // Should fail - inline flow creates .result branch but test_event has no output branches (void)
    const result = checker.checkSourceFile(&parse_result.source_file);
    try testing.expectError(error.BranchDoesNotExist, result);
}