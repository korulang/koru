// Glob Matcher - Pattern Matching with Captures for Koru
// ======================================================
//
// CODEX: Implement this module to satisfy all tests in glob_matcher_spec_test.zig
//
// Run tests with: zig test src/glob_matcher_spec_test.zig
//
// Requirements:
// 1. Zero allocations for simple matches (use fixed-size capture array)
// 2. Captures are slices into the original input (no copying)
// 3. Comptime-compatible where possible
// 4. Handle all wildcard patterns: *, prefix.*, *.suffix, prefix*, *suffix, a.*.b, *.*.*
//
// Reference: glob_pattern_matcher.zig has a simpler matchSegment() without captures

const std = @import("std");

/// Maximum number of captures supported (wildcards in pattern)
pub const MAX_CAPTURES = 16;

/// Result of a glob match operation
pub const Match = struct {
    matched: bool,
    /// Captured segments - slices into the original input string
    /// Length equals number of wildcards in pattern (0 if no match or no wildcards)
    captures: []const []const u8,

    // Internal storage for captures (no allocation needed)
    _capture_storage: [MAX_CAPTURES][]const u8 = undefined,
    _capture_count: usize = 0,

    pub fn init(matched: bool, captures: []const []const u8) Match {
        var result = Match{
            .matched = matched,
            .captures = &[_][]const u8{},
        };
        if (matched and captures.len > 0) {
            for (captures, 0..) |cap, i| {
                if (i >= MAX_CAPTURES) break;
                result._capture_storage[i] = cap;
            }
            result._capture_count = @min(captures.len, MAX_CAPTURES);
            result.captures = result._capture_storage[0..result._capture_count];
        }
        return result;
    }

    pub fn noMatch() Match {
        return .{ .matched = false, .captures = &[_][]const u8{} };
    }
};

/// Match a glob pattern against a value, returning captures for each wildcard
///
/// Pattern syntax:
///   *           - matches anything (captures entire match)
///   prefix.*    - matches prefix.anything (captures after dot)
///   *.suffix    - matches anything.suffix (captures before dot)
///   prefix*     - matches prefix + anything (captures suffix)
///   *suffix     - matches anything + suffix (captures prefix)
///   a.*.b       - matches a.X.b (captures X)
///   *.*.*       - matches X.Y.Z (captures X, Y, Z)
///
/// Examples:
///   match("log.*", "log.error")     -> { matched: true, captures: ["error"] }
///   match("*.*.*", "192.168.1")     -> { matched: true, captures: ["192", "168", "1"] }
///   match("ring*", "ring[T:u32]")   -> { matched: true, captures: ["[T:u32]"] }
///
pub fn match(pattern: []const u8, value: []const u8) Match {
    // TODO: CODEX - Implement this!
    //
    // Algorithm hints:
    // 1. Split pattern and value by '.' into segments
    // 2. Match segments pairwise, handling wildcards
    // 3. For each *, capture the corresponding part of value
    // 4. Handle bare wildcards (no dot): prefix*, *suffix, *mid*
    //
    // Edge cases to handle:
    // - Empty pattern/value
    // - Pattern with no wildcards (exact match, no captures)
    // - Multiple consecutive wildcards *.*
    // - Wildcards at start/middle/end
    // - Special chars in value: [], :, /

    _ = pattern;
    _ = value;
    return Match.noMatch();
}

/// Match module and event patterns separately (for tap-style patterns)
///
/// Example: matchSegmented("std.io", "file.*", "std.io", "file.read")
///          -> { matched: true, captures: ["read"] }
///
pub fn matchSegmented(
    module_pattern: []const u8,
    event_pattern: []const u8,
    module_value: []const u8,
    event_value: []const u8,
) Match {
    // TODO: CODEX - Implement this!
    //
    // Match module_pattern against module_value
    // Match event_pattern against event_value
    // Combine captures from both matches

    _ = module_pattern;
    _ = event_pattern;
    _ = module_value;
    _ = event_value;
    return Match.noMatch();
}

/// Check if a string contains glob wildcard patterns
pub fn isPattern(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '*') != null;
}

/// Count the number of wildcards in a pattern
pub fn countWildcards(pattern: []const u8) usize {
    var count: usize = 0;
    for (pattern) |c| {
        if (c == '*') count += 1;
    }
    return count;
}

// =============================================================================
// INTERNAL HELPERS - Codex can add more as needed
// =============================================================================

fn splitByDot(s: []const u8) []const []const u8 {
    // TODO: Split string by '.' - may need comptime buffer or caller-provided storage
    _ = s;
    return &[_][]const u8{};
}
