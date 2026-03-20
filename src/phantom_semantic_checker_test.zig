const std = @import("std");
const ast = @import("ast");
const Parser = @import("parser").Parser;
const PhantomSemanticChecker = @import("phantom_semantic_checker").PhantomSemanticChecker;
const errors = @import("errors");

// =============================================================================
// PHANTOM SEMANTIC CHECKER UNIT TESTS
// =============================================================================
//
// NOTE ON BASE TYPE CHECKING:
// By default, Koru does NOT check base types eagerly. It only validates phantom
// state compatibility. The actual base type checking is delegated to Zig's type
// system, which catches mismatches lazily during compilation.
//
// This design is MORE CORRECT than eager string-based checking because:
// - Zig handles type aliases correctly (const Conn = Connection)
// - Zig handles module-qualified types correctly
// - No false positives from string comparison mismatches
//
// To enable eager base type checking (less accurate but earlier errors), use:
//   koruc --strict-base-types input.kz
//
// Base type checking with --strict-base-types is tested in:
//   tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2104_10_wrong_base_type/
//   tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2104_11_wrong_base_type_reverse/
//
// Lazy Zig type checking (default behavior) is tested in:
//   tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2104_12_wrong_base_type_zig_catches/
//   tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2104_13_wrong_base_type_reverse_zig_catches/
// =============================================================================

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
        \\~connect()
        \\| ok c |>
        \\    close(conn: c.conn)
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

    // This MUST succeed - correct type with matching phantom state
    try checker.check(&parse_result.source_file);
    
    // No errors expected
    try std.testing.expect(!reporter.hasErrors());
}

test "obligations track phantom states through multi-step flow" {
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
        \\~connect()
        \\| ok c |>
        \\    begin(conn: c.conn)
        \\    | ok t |>
        \\        // Only commit() is called - discharges *Transaction[active!]
        \\        // But *Connection[active!] was already consumed by begin()
        \\        commit(tx: t.tx)
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

    // This should succeed - begin() consumes Connection, commit() consumes Transaction
    try checker.check(&parse_result.source_file);
    
    // No errors expected - each obligation is properly discharged
    try std.testing.expect(!reporter.hasErrors());
}
