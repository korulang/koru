const std = @import("std");
const ast = @import("ast");
const Parser = @import("parser").Parser;
const AutoDischargeInserter = @import("auto_discharge_inserter").AutoDischargeInserter;
const errors = @import("errors");

// =============================================================================
// CORE TEST: Same phantom state name, different base types
// =============================================================================
// This is the fundamental test for phantom type obligation matching.
//
// The phantom system tracks obligations by BOTH:
//   1. The phantom state name (e.g., "active")
//   2. The base type (e.g., "*Connection" vs "*Transaction")
//
// A *Connection[active!] obligation can ONLY be discharged by an event
// that accepts *Connection[!active], NOT by one that accepts *Transaction[!active].
// =============================================================================

test "findDisposalEvents filters by base type - same phantom state, different types" {
    // Use arena for parser (it leaks internally), testing allocator for our code
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // Two different types, both with "active" phantom state
    // Connection uses close() to discharge
    // Transaction uses commit() to discharge
    // All events are in module "test" (from filename)
    const source =
        \\~event connect { }
        \\| ok: *Connection[active!]
        \\
        \\~event close[!] { conn: *Connection[!active] }
        \\
        \\~event begin { }
        \\| ok: *Transaction[active!]
        \\
        \\~event commit[!] { tx: *Transaction[!active] }
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var inserter = try AutoDischargeInserter.init(test_alloc, &reporter, false);
    defer inserter.deinit();

    // Build event map from parsed AST
    try inserter.buildEventMap(&parse_result.source_file);

    // Test 1: *Connection[active!] should find ONLY close(), not commit()
    // The phantom state is "test:active" (module:state)
    {
        const disposals = try inserter.findDisposalEvents("test:active!", "*Connection");
        defer {
            for (disposals) |d| {
                test_alloc.free(d.qualified_name);
                test_alloc.free(d.field_name);
            }
            test_alloc.free(disposals);
        }

        try std.testing.expectEqual(@as(usize, 1), disposals.len);
        try std.testing.expectEqualStrings("test:close[!]", disposals[0].qualified_name);
    }

    // Test 2: *Transaction[active!] should find ONLY commit(), not close()
    {
        const disposals = try inserter.findDisposalEvents("test:active!", "*Transaction");
        defer {
            for (disposals) |d| {
                test_alloc.free(d.qualified_name);
                test_alloc.free(d.field_name);
            }
            test_alloc.free(disposals);
        }

        try std.testing.expectEqual(@as(usize, 1), disposals.len);
        try std.testing.expectEqualStrings("test:commit[!]", disposals[0].qualified_name);
    }

    // Test 3: Wrong base type should find NO disposals
    {
        // Looking for active! disposal but with a type that has no disposal event
        const disposals = try inserter.findDisposalEvents("test:active!", "*SomeOtherType");
        defer {
            for (disposals) |d| {
                test_alloc.free(d.qualified_name);
                test_alloc.free(d.field_name);
            }
            test_alloc.free(disposals);
        }

        try std.testing.expectEqual(@as(usize, 0), disposals.len);
    }
}

test "findDisposalEvents handles multiple disposal options for same type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // One type with multiple ways to discharge the same state
    const source =
        \\~event open { path: []const u8 }
        \\| ok: *File[open!]
        \\
        \\~event close[!] { file: *File[!open] }
        \\
        \\~event close_and_delete[!] { file: *File[!open] }
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var inserter = try AutoDischargeInserter.init(test_alloc, &reporter, false);
    defer inserter.deinit();

    try inserter.buildEventMap(&parse_result.source_file);

    // Should find BOTH close and close_and_delete for *File[open!]
    const disposals = try inserter.findDisposalEvents("test:open!", "*File");
    defer {
        for (disposals) |d| {
            test_alloc.free(d.qualified_name);
            test_alloc.free(d.field_name);
        }
        test_alloc.free(disposals);
    }

    try std.testing.expectEqual(@as(usize, 2), disposals.len);

    // Verify both are found (order may vary)
    var found_close = false;
    var found_close_and_delete = false;
    for (disposals) |d| {
        if (std.mem.eql(u8, d.qualified_name, "test:close[!]")) found_close = true;
        if (std.mem.eql(u8, d.qualified_name, "test:close_and_delete[!]")) found_close_and_delete = true;
    }
    try std.testing.expect(found_close);
    try std.testing.expect(found_close_and_delete);
}

test "findDisposalEvents with different types same phantom state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // Two types with same phantom state name but different base types
    // This is the CRITICAL test - verifies that base type filtering works
    const source =
        \\~event connect { }
        \\| ok: *DbConn[connected!]
        \\
        \\~event disconnect[!] { conn: *DbConn[!connected] }
        \\
        \\~event acquire { }
        \\| ok: *PoolConn[connected!]
        \\
        \\~event release[!] { conn: *PoolConn[!connected] }
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var inserter = try AutoDischargeInserter.init(test_alloc, &reporter, false);
    defer inserter.deinit();

    try inserter.buildEventMap(&parse_result.source_file);

    // DbConn[connected!] should ONLY find disconnect, NOT release
    // Even though both consume [!connected], base types differ
    {
        const disposals = try inserter.findDisposalEvents("test:connected!", "*DbConn");
        defer {
            for (disposals) |d| {
                test_alloc.free(d.qualified_name);
                test_alloc.free(d.field_name);
            }
            test_alloc.free(disposals);
        }

        try std.testing.expectEqual(@as(usize, 1), disposals.len);
        try std.testing.expectEqualStrings("test:disconnect[!]", disposals[0].qualified_name);
    }

    // PoolConn[connected!] should ONLY find release, NOT disconnect
    {
        const disposals = try inserter.findDisposalEvents("test:connected!", "*PoolConn");
        defer {
            for (disposals) |d| {
                test_alloc.free(d.qualified_name);
                test_alloc.free(d.field_name);
            }
            test_alloc.free(disposals);
        }

        try std.testing.expectEqual(@as(usize, 1), disposals.len);
        try std.testing.expectEqualStrings("test:release[!]", disposals[0].qualified_name);
    }
}
