// Glob Matcher Specification Tests
// =================================
//
// This file defines the COMPLETE specification for Koru's glob pattern matching.
// Implement glob_matcher.zig to make all these tests pass.
//
// The glob matcher is used for:
// - Event name globbing: ~event log.* matches ~log.error
// - Transform matching: transforms with glob patterns
// - Generics: ring.new* matches ring.new[T:u32,N:1024]
// - Pattern branches: [*.*.*.167] for IP matching, etc.
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

    // Should NOT match
    try std.testing.expect(!glob.match("log.*", "log").matched);        // No suffix
    try std.testing.expect(!glob.match("log.*", "logger.error").matched); // Different prefix
    try std.testing.expect(!glob.match("log.*", "xlog.error").matched);   // Prefix mismatch
}

test "prefix glob: *.suffix" {
    // *.io should match std.io, test.io, foo.io
    try std.testing.expect(glob.match("*.io", "std.io").matched);
    try std.testing.expect(glob.match("*.io", "test.io").matched);
    try std.testing.expect(glob.match("*.io", "x.io").matched);

    // Should NOT match
    try std.testing.expect(!glob.match("*.io", "io").matched);          // No prefix
    try std.testing.expect(!glob.match("*.io", "std.io.extra").matched); // Extra suffix
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
    // *.*.* should match a.b.c
    try std.testing.expect(glob.match("*.*.*", "a.b.c").matched);
    try std.testing.expect(glob.match("*.*.*", "foo.bar.baz").matched);
    try std.testing.expect(glob.match("*.*.*", "192.168.1").matched);

    // Should NOT match (wrong segment count)
    try std.testing.expect(!glob.match("*.*.*", "a.b").matched);
    try std.testing.expect(!glob.match("*.*.*", "a.b.c.d").matched);
    try std.testing.expect(!glob.match("*.*.*", "a").matched);
}

test "mixed pattern: prefix.*.middle.*" {
    try std.testing.expect(glob.match("std.*.io.*", "std.fs.io.read").matched);
    try std.testing.expect(glob.match("std.*.io.*", "std.net.io.write").matched);

    try std.testing.expect(!glob.match("std.*.io.*", "std.fs.io").matched);      // Missing last
    try std.testing.expect(!glob.match("std.*.io.*", "std.io.read").matched);    // Missing middle
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

test "edge: special characters in literals" {
    // Brackets, colons, slashes should be matched literally
    try std.testing.expect(glob.match("[GET /users/:id]", "[GET /users/:id]").matched);
    try std.testing.expect(glob.match("ring.new[*]", "ring.new[T:u32]").matched);

    const result = glob.match("ring.new[*]", "ring.new[T:u32]");
    try std.testing.expect(result.matched);
    try std.testing.expectEqualStrings("T:u32", result.captures[0]);
}

test "edge: dot only separates when in pattern structure" {
    // The dot in "log.*" is structural, but in ring[T:u32] it's not
    const result = glob.match("ring*", "ring.buffer");
    try std.testing.expect(result.matched);
    try std.testing.expectEqualStrings(".buffer", result.captures[0]);
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
