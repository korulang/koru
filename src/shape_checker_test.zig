const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("parser.zig").Parser;
const ShapeChecker = @import("shape_checker.zig").ShapeChecker;
const errors = @import("errors.zig");

// Regression test for the pointer bug where shape checker was storing
// pointers to temporary copies of AST nodes, causing event branches
// to get mixed up between different events.
test "shape checker stores correct event pointers - regression" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event A { x: i32 }
        \\| ok { y: i32 }
        \\
        \\~event B { msg: []const u8 }
        \\| done {}
        \\
        \\~A (x: 1)
        \\| ok |> _
        \\
        \\~B (msg: "test")
        \\| done |> _
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var source_file = try parser.parse();
    defer source_file.deinit();
    
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", source);
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    // This should NOT error - each flow should validate against its own event
    try checker.checkSourceFile(&source_file);
    
    // Verify no errors were reported
    try std.testing.expect(!reporter.hasErrors());
}

// Test that the shape checker correctly validates branches
test "shape checker validates correct branches for each event" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event First { }
        \\| alpha {}
        \\| beta {}
        \\
        \\~event Second { }
        \\| gamma {}
        \\| delta {}
        \\
        \\~proc First {
        \\    return .@"alpha"(.{});
        \\}
        \\
        \\~proc Second {
        \\    return .@"gamma"(.{});
        \\}
        \\
        \\~First ()
        \\| alpha |> _
        \\| beta |> _
        \\
        \\~Second ()
        \\| gamma |> _
        \\| delta |> _
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var source_file = try parser.parse();
    defer source_file.deinit();
    
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", source);
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    // Should pass - each event's branches are properly covered
    try checker.checkSourceFile(&source_file);
    try std.testing.expect(!reporter.hasErrors());
}

// Test that mixing up branches between events would fail
test "shape checker detects wrong branch names" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event First { }
        \\| alpha {}
        \\
        \\~event Second { }
        \\| beta {}
        \\
        \\~First ()
        \\| beta |> _  // WRONG - First doesn't have 'beta'
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var source_file = try parser.parse();
    defer source_file.deinit();
    
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", source);
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    // Should fail - First doesn't have a 'beta' branch
    const result = checker.checkSourceFile(&source_file);
    try std.testing.expectError(error.IncompleteBranchCoverage, result);
}