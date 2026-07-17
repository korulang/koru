const std = @import("std");
const testing = std.testing;
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const shape_checker = @import("shape_checker");

test "validate complete flow" {
    // A genuine multi-branch event: two branches make it a real tag union, so
    // it escapes the single-branch collapse (a lone `| ok i32` is now the
    // retired one-variant form → bare return `-> i32`, PARSE003). Payloads are
    // identity form (`| ok i32`) — a single-field struct `| ok { v: i32 }` is
    // itself illegal (must be identity). Handling BOTH branches is the
    // complete-coverage case this test pins; the sibling `validate incomplete
    // flow` handles only `ok` and expects IncompleteBranchCoverage.
    const source =
        \\~event A { x: i32 }
        \\| ok i32
        \\| err string
        \\
        \\~A => ok x
        \\
        \\~A(x: 1)
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

test "validate incomplete flow" {
    const source =
        \\~event read { path: string }
        \\| ok { contents: string, errno: u8 }
        \\| err { errno: u8, message: string }
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
        \\~proc mystery-handler|zig {
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
        \\~event read { path: string }
        \\| ok { contents: string, size: u32 }
        \\| err { errno: u8, message: string }
        \\
        \\~event audit-log { message: string, path: string }
        \\| ok {}
        \\
        \\~tap(read -> audit-log)
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
        \\~event read { path: string }
        \\| ok { contents: string, size: u32 }
        \\| err { errno: u8, message: string }
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
        \\~event audit-log { message: string, path: string }
        \\| ok {}
        \\
        \\~tap(missing -> audit-log)
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
        \\~event read { path: string }
        \\| ok { contents: string, size: u32 }
        \\| err { errno: u8, message: string }
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
        \\~event read { path: string }
        \\| ok { contents: string, size: u32 }
        \\| err { errno: u8, message: string }
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
        \\~event test-event { input: u32 }
        \\| ok {}
        \\
        \\~proc helper|zig {
        \\    return .{ .ok = .{ .value = e.input * 2, .tag = 0 } };
        \\}
        \\
        \\~proc test-event|zig {
        \\    ~helper(e.input)
        \\    | ok o |> result { o.value }
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

// A binding-position destructure (`| ok { a, b }`) unpacks the branch payload by
// field NAME. These pin the koru-level wall: names are validated against the
// payload shape at shape-check time (KORU036), never leaked to generated Zig.
// Destructuring happens at BINDING, never in the event declaration.
test "binding destructure of an unknown payload field is a koru error (KORU036)" {
    const source =
        \\~event A { x: i32 }
        \\| ok { a: i32, b: u8 }
        \\| err string
        \\
        \\~A => ok { a: 1, b: 2 }
        \\
        \\~A(x: 1)
        \\| ok { nonexistent } |> _
        \\| err _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    checker.checkSourceFile(&parse_result.source_file) catch {};

    var found_koru036 = false;
    for (parser.reporter.errors.items) |e| {
        if (e.code == .KORU036) found_koru036 = true;
    }
    try testing.expect(found_koru036);
}

test "binding destructure of real payload fields raises no KORU036" {
    const source =
        \\~event A { x: i32 }
        \\| ok { a: i32, b: u8 }
        \\| err string
        \\
        \\~A => ok { a: 1, b: 2 }
        \\
        \\~A(x: 1)
        \\| ok { a, b } |> _
        \\| err _ |> _
    ;

    var parser = try Parser.init(testing.allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var checker = try shape_checker.ShapeChecker.init(testing.allocator, &parser.reporter);
    defer checker.deinit();

    checker.checkSourceFile(&parse_result.source_file) catch {};

    for (parser.reporter.errors.items) |e| {
        try testing.expect(e.code != .KORU036);
    }
}
