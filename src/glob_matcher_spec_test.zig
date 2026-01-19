// Glob Matcher Specification Tests
// =================================
//
// This file defines the COMPLETE specification for Koru's glob pattern matching.
// Implement glob_matcher.zig to make all these tests pass.
//
// The glob matcher is used for:
// - Event name globbing: ~event log.* matches ~log.error AND ~log.error.fatal
// - Transform matching: transforms with glob patterns
// - Generics: ring.new* matches ring.new[T:u32,N:1024]
// - Pattern branches: [*.*.*.167] for IP matching, etc.
//
// SEMANTICS:
// - `*` is GREEDY: matches zero or more of ANY character (including dots)
// - Dots have NO special meaning - they're just characters
// - Multiple `*`s: each captures MINIMALLY to allow pattern to match
// - Last `*` captures everything remaining
//
// Examples:
//   log.*     + log.error.fatal  -> match, captures ["error.fatal"]
//   *.*.*     + a.b.c.d          -> match, captures ["a", "b", "c.d"]
//   *middle*  + startmiddleend   -> match, captures ["start", "end"]
//
// REQUIREMENTS:
// 1. Zero runtime allocations for simple matches
// 2. Captures returned as slices into the original input (no copying)
// 3. Comptime-compatible where possible
//
// CODEX: Implement src/glob_matcher.zig to satisfy these tests.
// The existing glob_pattern_matcher.zig has a simple matchSegment() you can reference,
// but we need the full capture-supporting implementation.

const std = @import("std");
const glob = @import("glob_matcher.zig");

// =============================================================================
// BASIC MATCHING (no captures needed)
// =============================================================================

test "full wildcard * matches anything" {
    try std.testing.expect(glob.match("*", "anything").matched);
    try std.testing.expect(glob.match("*", "log.error").matched);
    try std.testing.expect(glob.match("*", "").matched);
    try std.testing.expect(glob.match("*", "a.b.c.d.e").matched);
}

test "exact match" {
    try std.testing.expect(glob.match("log.error", "log.error").matched);
    try std.testing.expect(glob.match("foo", "foo").matched);
    try std.testing.expect(!glob.match("log.error", "log.warn").matched);
    try std.testing.expect(!glob.match("foo", "bar").matched);
    try std.testing.expect(!glob.match("foo", "foobar").matched);
    try std.testing.expect(!glob.match("foobar", "foo").matched);
}

test "suffix glob: pattern.*" {
    // log.* should match log.error, log.warn, log.info
    try std.testing.expect(glob.match("log.*", "log.error").matched);
    try std.testing.expect(glob.match("log.*", "log.warn").matched);
    try std.testing.expect(glob.match("log.*", "log.x").matched);

    // GREEDY: log.* also matches nested paths (star crosses dots)
    try std.testing.expect(glob.match("log.*", "log.error.fatal").matched);
    try std.testing.expect(glob.match("log.*", "log.http.request.headers").matched);

    // Should NOT match
    try std.testing.expect(!glob.match("log.*", "log").matched);        // No suffix (need at least empty after dot)
    try std.testing.expect(!glob.match("log.*", "logger.error").matched); // Different prefix
    try std.testing.expect(!glob.match("log.*", "xlog.error").matched);   // Prefix mismatch
}

test "prefix glob: *.suffix" {
    // *.io should match std.io, test.io, foo.io
    try std.testing.expect(glob.match("*.io", "std.io").matched);
    try std.testing.expect(glob.match("*.io", "test.io").matched);
    try std.testing.expect(glob.match("*.io", "x.io").matched);

    // GREEDY: * can contain dots, but pattern must still END with .io
    try std.testing.expect(glob.match("*.io", "deeply.nested.module.io").matched);

    // Should NOT match
    try std.testing.expect(!glob.match("*.io", "io").matched);          // No prefix (need something before .io)
    try std.testing.expect(!glob.match("*.io", "std.io.extra").matched); // Doesn't END with .io
    try std.testing.expect(!glob.match("*.io", "std.iox").matched);      // Suffix mismatch
}

test "bare suffix glob: prefix*" {
    // ring* should match ring, ring[T:u32], ringbuffer
    try std.testing.expect(glob.match("ring*", "ring").matched);
    try std.testing.expect(glob.match("ring*", "ring[T:u32]").matched);
    try std.testing.expect(glob.match("ring*", "ring[T:u32,N:1024]").matched);
    try std.testing.expect(glob.match("ring*", "ringbuffer").matched);

    // Should NOT match
    try std.testing.expect(!glob.match("ring*", "rin").matched);        // Too short
    try std.testing.expect(!glob.match("ring*", "xring").matched);      // Prefix before
    try std.testing.expect(!glob.match("ring*", "rong").matched);       // Different
}

test "bare prefix glob: *suffix" {
    // *Handler should match EventHandler, RequestHandler, Handler
    try std.testing.expect(glob.match("*Handler", "EventHandler").matched);
    try std.testing.expect(glob.match("*Handler", "RequestHandler").matched);
    try std.testing.expect(glob.match("*Handler", "Handler").matched);

    // Should NOT match
    try std.testing.expect(!glob.match("*Handler", "Handlerx").matched);    // Extra suffix
    try std.testing.expect(!glob.match("*Handler", "EventHandle").matched); // Wrong suffix
}

test "middle glob: prefix.*.suffix" {
    // game.*.update should match game.player.update, game.enemy.update
    try std.testing.expect(glob.match("game.*.update", "game.player.update").matched);
    try std.testing.expect(glob.match("game.*.update", "game.enemy.update").matched);
    try std.testing.expect(glob.match("game.*.update", "game.x.update").matched);

    // Should NOT match
    try std.testing.expect(!glob.match("game.*.update", "game.update").matched);           // No middle
    try std.testing.expect(!glob.match("game.*.update", "game.player.render").matched);    // Wrong suffix
    try std.testing.expect(!glob.match("game.*.update", "xgame.player.update").matched);   // Wrong prefix
}

test "multiple wildcards: *.*.*" {
    // *.*.* requires exactly two literal dots, with * capturing between/around them
    try std.testing.expect(glob.match("*.*.*", "a.b.c").matched);
    try std.testing.expect(glob.match("*.*.*", "foo.bar.baz").matched);
    try std.testing.expect(glob.match("*.*.*", "192.168.1").matched);

    // GREEDY: Last * can capture across dots
    try std.testing.expect(glob.match("*.*.*", "a.b.c.d").matched);      // captures: ["a", "b", "c.d"]
    try std.testing.expect(glob.match("*.*.*", "a.b.c.d.e.f").matched);  // captures: ["a", "b", "c.d.e.f"]

    // Should NOT match (not enough dots for the two literal dots in pattern)
    try std.testing.expect(!glob.match("*.*.*", "a.b").matched);   // Only one dot
    try std.testing.expect(!glob.match("*.*.*", "a").matched);     // No dots
    try std.testing.expect(!glob.match("*.*.*", "nodots").matched); // No dots
}

test "mixed pattern: prefix.*.middle.*" {
    try std.testing.expect(glob.match("std.*.io.*", "std.fs.io.read").matched);
    try std.testing.expect(glob.match("std.*.io.*", "std.net.io.write").matched);

    // GREEDY: each * can span dots, but literals must still appear in order
    try std.testing.expect(glob.match("std.*.io.*", "std.deeply.nested.io.read.write").matched);

    try std.testing.expect(!glob.match("std.*.io.*", "std.fs.io").matched);      // Missing content after last dot
    try std.testing.expect(!glob.match("std.*.io.*", "std.io.read").matched);    // Missing .io. in middle
}

// =============================================================================
// CAPTURES - The important part!
// =============================================================================

test "capture: suffix glob log.* captures suffix" {
    const result = glob.match("log.*", "log.error");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("error", result.captures[0]);
}

test "capture: greedy suffix glob captures across dots" {
    const result = glob.match("log.*", "log.error.fatal.details");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("error.fatal.details", result.captures[0]);
}

test "capture: prefix glob *.io captures prefix" {
    const result = glob.match("*.io", "std.io");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("std", result.captures[0]);
}

test "capture: bare suffix ring* captures suffix" {
    const result = glob.match("ring*", "ring[T:u32,N:1024]");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("[T:u32,N:1024]", result.captures[0]);
}

test "capture: bare suffix with empty capture" {
    const result = glob.match("ring*", "ring");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("", result.captures[0]);
}

test "capture: middle glob captures middle segment" {
    const result = glob.match("game.*.update", "game.player.update");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("player", result.captures[0]);
}

test "capture: multiple wildcards capture all" {
    const result = glob.match("*.*.*", "192.168.1");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 3), result.captures.len);
    try std.testing.expectEqualStrings("192", result.captures[0]);
    try std.testing.expectEqualStrings("168", result.captures[1]);
    try std.testing.expectEqualStrings("1", result.captures[2]);
}

test "capture: greedy multiple wildcards - last captures rest" {
    // With more dots than wildcards, last * gets the remainder
    const result = glob.match("*.*.*", "a.b.c.d.e");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 3), result.captures.len);
    try std.testing.expectEqualStrings("a", result.captures[0]);      // minimal
    try std.testing.expectEqualStrings("b", result.captures[1]);      // minimal
    try std.testing.expectEqualStrings("c.d.e", result.captures[2]);  // greedy (rest)
}

test "capture: IP-style pattern *.*.*.167" {
    const result = glob.match("*.*.*.167", "192.168.1.167");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 3), result.captures.len);
    try std.testing.expectEqualStrings("192", result.captures[0]);
    try std.testing.expectEqualStrings("168", result.captures[1]);
    try std.testing.expectEqualStrings("1", result.captures[2]);
}

test "capture: complex pattern std.*.io.*" {
    const result = glob.match("std.*.io.*", "std.fs.io.read");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 2), result.captures.len);
    try std.testing.expectEqualStrings("fs", result.captures[0]);
    try std.testing.expectEqualStrings("read", result.captures[1]);
}

test "capture: full wildcard captures entire input" {
    const result = glob.match("*", "anything.here.really");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("anything.here.really", result.captures[0]);
}

test "capture: no wildcards means no captures" {
    const result = glob.match("exact.match", "exact.match");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.captures.len);
}

test "capture: non-match has empty captures" {
    const result = glob.match("log.*", "notlog.error");
    try std.testing.expect(!result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.captures.len);
}

// =============================================================================
// UTILITY FUNCTIONS
// =============================================================================

test "isPattern: detects wildcards" {
    try std.testing.expect(glob.isPattern("*"));
    try std.testing.expect(glob.isPattern("log.*"));
    try std.testing.expect(glob.isPattern("*.io"));
    try std.testing.expect(glob.isPattern("ring*"));
    try std.testing.expect(glob.isPattern("*.*.*"));
    try std.testing.expect(glob.isPattern("game.*.update"));

    try std.testing.expect(!glob.isPattern("log.error"));
    try std.testing.expect(!glob.isPattern("exact"));
    try std.testing.expect(!glob.isPattern("no.wildcards.here"));
}

test "countWildcards: counts asterisks" {
    try std.testing.expectEqual(@as(usize, 1), glob.countWildcards("*"));
    try std.testing.expectEqual(@as(usize, 1), glob.countWildcards("log.*"));
    try std.testing.expectEqual(@as(usize, 3), glob.countWildcards("*.*.*"));
    try std.testing.expectEqual(@as(usize, 2), glob.countWildcards("std.*.io.*"));
    try std.testing.expectEqual(@as(usize, 0), glob.countWildcards("no.wildcards"));
}

// =============================================================================
// EDGE CASES
// =============================================================================

test "edge: empty pattern matches empty string" {
    try std.testing.expect(glob.match("", "").matched);
    try std.testing.expect(!glob.match("", "nonempty").matched);
}

test "edge: empty input with wildcard" {
    try std.testing.expect(glob.match("*", "").matched);
    try std.testing.expect(!glob.match("a*", "").matched);  // Needs at least 'a'
}

test "edge: consecutive wildcards *.*" {
    // *.* means "something dot something"
    try std.testing.expect(glob.match("*.*", "a.b").matched);
    try std.testing.expect(!glob.match("*.*", "nodot").matched);
}

test "edge: wildcard at start and end *middle*" {
    try std.testing.expect(glob.match("*middle*", "startmiddleend").matched);
    try std.testing.expect(glob.match("*middle*", "middle").matched);
    try std.testing.expect(glob.match("*middle*", "middleend").matched);
    try std.testing.expect(glob.match("*middle*", "startmiddle").matched);
    try std.testing.expect(!glob.match("*middle*", "nomatch").matched);
}

test "capture: *middle* captures before and after" {
    const result = glob.match("*middle*", "startmiddleend");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 2), result.captures.len);
    try std.testing.expectEqualStrings("start", result.captures[0]);
    try std.testing.expectEqualStrings("end", result.captures[1]);
}

test "capture: *middle* with empty captures" {
    // "middle" alone - both captures are empty
    const result1 = glob.match("*middle*", "middle");
    try std.testing.expect(result1.matched);
    try std.testing.expectEqual(@as(usize, 2), result1.captures.len);
    try std.testing.expectEqualStrings("", result1.captures[0]);
    try std.testing.expectEqualStrings("", result1.captures[1]);

    // "middleend" - first capture empty
    const result2 = glob.match("*middle*", "middleend");
    try std.testing.expect(result2.matched);
    try std.testing.expectEqualStrings("", result2.captures[0]);
    try std.testing.expectEqualStrings("end", result2.captures[1]);

    // "startmiddle" - second capture empty
    const result3 = glob.match("*middle*", "startmiddle");
    try std.testing.expect(result3.matched);
    try std.testing.expectEqualStrings("start", result3.captures[0]);
    try std.testing.expectEqualStrings("", result3.captures[1]);
}

test "edge: special characters in literals" {
    // Brackets, colons, slashes should be matched literally
    try std.testing.expect(glob.match("[GET /users/:id]", "[GET /users/:id]").matched);
    try std.testing.expect(glob.match("ring.new[*]", "ring.new[T:u32]").matched);

    const result = glob.match("ring.new[*]", "ring.new[T:u32]");
    try std.testing.expect(result.matched);
    try std.testing.expectEqualStrings("T:u32", result.captures[0]);
}

test "edge: dots are just characters - no special meaning" {
    // Dots in the VALUE are just characters, * matches them freely
    const result = glob.match("ring*", "ring.buffer");
    try std.testing.expect(result.matched);
    try std.testing.expectEqualStrings(".buffer", result.captures[0]);

    // Dots in the PATTERN are literals that must match exactly
    const result2 = glob.match("a.b.*", "a.b.c.d.e");
    try std.testing.expect(result2.matched);
    try std.testing.expectEqualStrings("c.d.e", result2.captures[0]);
}

test "edge: dots inside brackets captured correctly" {
    // Brackets are just characters too - * inside captures everything
    const result = glob.match("ring.new[*]", "ring.new[T:std.io.File]");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("T:std.io.File", result.captures[0]);
}

// =============================================================================
// SEGMENT-BASED MATCHING (for module:event patterns)
// =============================================================================

test "matchSegmented: module:event style" {
    // For tap patterns like "std.io:file.*"
    const result = glob.matchSegmented("std.io", "file.*", "std.io", "file.read");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("read", result.captures[0]);
}

test "matchSegmented: wildcard module" {
    const result = glob.matchSegmented("*", "file.read", "std.io", "file.read");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.captures.len);
    try std.testing.expectEqualStrings("std.io", result.captures[0]);
}

test "matchSegmented: wildcard both" {
    const result = glob.matchSegmented("*.io", "*", "std.io", "anything");
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(@as(usize, 2), result.captures.len);
    try std.testing.expectEqualStrings("std", result.captures[0]);
    try std.testing.expectEqualStrings("anything", result.captures[1]);
}

// =============================================================================
// COMPILE-TIME SUPPORT (bonus points)
// =============================================================================

// Note: These tests verify comptime compatibility AFTER implementation works.
// Uncomment once match() is implemented correctly.

// test "comptime: pattern matching works at comptime" {
//     comptime {
//         const result = glob.match("log.*", "log.error");
//         if (!result.matched) @compileError("Should match");
//         if (result.captures.len != 1) @compileError("Should have 1 capture");
//     }
// }

test "comptime: isPattern works at comptime" {
    // isPattern is already implemented and should work at comptime
    comptime {
        if (!glob.isPattern("log.*")) @compileError("Should be pattern");
        if (glob.isPattern("exact")) @compileError("Should not be pattern");
    }
}
