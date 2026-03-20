const std = @import("std");
const ast = @import("ast");
const Parser = @import("parser").Parser;
const PhantomSemanticChecker = @import("phantom_semantic_checker").PhantomSemanticChecker;
const errors = @import("errors");

// =============================================================================
// CORE TEST: Type validation must check BOTH base type AND phantom state
// =============================================================================
// The phantom type system must treat *Connection[active!] and *Transaction[active!]
// as DIFFERENT types, even though they share the same phantom state name.
//
// A binding of type *Transaction[active!] must NOT be accepted where
// *Connection[!active] is expected - this is a TYPE MISMATCH.
// =============================================================================

test "validateArgument rejects wrong base type with same phantom state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // Define two types with the SAME phantom state name but DIFFERENT base types
    // close() expects *Connection[!active]
    // But we'll try to pass *Transaction[active!]
    // Use invocation-style flow (like regression tests) rather than named flow
    const source =
        \\~event connect { }
        \\| ok { conn: *Connection[active!] }
        \\
        \\~event begin { conn: *Connection[!active] }
        \\| ok { tx: *Transaction[active!] }
        \\
        \\~event close { conn: *Connection[!active] }
        \\
        \\~event commit { tx: *Transaction[!active] }
        \\
        \\~connect()
        \\| ok c |>
        \\    begin(conn: c.conn)
        \\    | ok t |>
        \\        close(conn: t.tx)
        \\        |> _
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(test_alloc, &reporter);
    defer checker.deinit();

    // This MUST fail - we're passing *Transaction where *Connection is expected
    const result = checker.check(&parse_result.source_file);

    // Expect validation to fail
    try std.testing.expectError(error.ValidationFailed, result);

    // Verify the error message mentions type mismatch
    try std.testing.expect(reporter.hasErrors());
}

test "validateArgument accepts correct base type with matching phantom state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // Valid usage: pass *Connection[active!] to close() which expects *Connection[!active]
    const source =
        \\~event connect { }
        \\| ok { conn: *Connection[active!] }
        \\
        \\~event close { conn: *Connection[!active] }
        \\
        \\~flow test_correct_type
        \\    connect()
        \\    | ok c |>
        \\        close(conn: c.conn)
        \\        |> _
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(test_alloc, &reporter);
    defer checker.deinit();

    // This MUST succeed - correct type with matching phantom state
    try checker.check(&parse_result.source_file);
    
    // No errors expected
    try std.testing.expect(!reporter.hasErrors());
}

test "obligations track full type not just phantom state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // Two different types with same phantom state name
    // Both have [active!] obligations but they are DIFFERENT obligations
    const source =
        \\~event connect { }
        \\| ok { conn: *Connection[active!] }
        \\
        \\~event begin { conn: *Connection[!active] }
        \\| ok { tx: *Transaction[active!] }
        \\
        \\~event commit { tx: *Transaction[!active] }
        \\
        \\~flow test_obligations
        \\    connect()
        \\    | ok c |>
        \\        begin(conn: c.conn)
        \\        | ok t |>
        \\            // Only commit() is called - discharges *Transaction[active!]
        \\            // But *Connection[active!] was already consumed by begin()
        \\            commit(tx: t.tx)
        \\            |> _
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(test_alloc, &reporter);
    defer checker.deinit();

    // This should succeed - begin() consumes Connection, commit() consumes Transaction
    try checker.check(&parse_result.source_file);
    
    // No errors expected - each obligation is properly discharged
    try std.testing.expect(!reporter.hasErrors());
}

test "cannot discharge Connection obligation with Transaction disposer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // close() expects *Connection[!active] 
    // commit() expects *Transaction[!active]
    // They should NOT be interchangeable!
    // Use invocation-style flow
    const source =
        \\~event connect { }
        \\| ok { conn: *Connection[active!] }
        \\
        \\~event close { conn: *Connection[!active] }
        \\
        \\~event commit { tx: *Transaction[!active] }
        \\
        \\~connect()
        \\| ok c |>
        \\    commit(tx: c.conn)
        \\    |> _
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(test_alloc, &reporter);
    defer checker.deinit();

    // This MUST fail - *Connection cannot be passed to commit() which expects *Transaction
    const result = checker.check(&parse_result.source_file);

    try std.testing.expectError(error.ValidationFailed, result);
    try std.testing.expect(reporter.hasErrors());
}

test "type mismatch error includes both base type and phantom state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const test_alloc = std.testing.allocator;

    // Use invocation-style flow
    const source =
        \\~event get_file { }
        \\| ok { file: *File[open!] }
        \\
        \\~event close_socket { sock: *Socket[!open] }
        \\
        \\~get_file()
        \\| ok f |>
        \\    close_socket(sock: f.file)
        \\    |> _
    ;

    const empty_flags: []const []const u8 = &.{};
    var parser = try Parser.init(arena_alloc, source, "test.kz", empty_flags, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    var reporter = try errors.ErrorReporter.init(test_alloc, "test.kz", source);
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(test_alloc, &reporter);
    defer checker.deinit();

    const result = checker.check(&parse_result.source_file);

    try std.testing.expectError(error.ValidationFailed, result);
    try std.testing.expect(reporter.hasErrors());
}
