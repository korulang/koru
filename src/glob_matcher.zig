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
// 4. Handle all wildcard patterns with greedy '*' semantics
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
        var result: Match = undefined;
        initFromCaptures(&result, matched, captures);
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
///   prefix.*    - matches prefix + anything (captures suffix)
///   *.suffix    - matches anything + suffix (captures prefix)
///   prefix*     - matches prefix + anything (captures suffix)
///   *suffix     - matches anything + suffix (captures prefix)
///   a.*.b       - matches a + anything + b (captures middle)
///   *.*.*       - matches with literals in order; last * captures rest
///
/// Examples:
///   match("log.*", "log.error")     -> { matched: true, captures: ["error"] }
///   match("*.*.*", "192.168.1")     -> { matched: true, captures: ["192", "168", "1"] }
///   match("ring*", "ring[T:u32]")   -> { matched: true, captures: ["[T:u32]"] }
///
pub fn match(pattern: []const u8, value: []const u8) Match {
    var result: Match = undefined;
    _ = matchInto(&result, pattern, value);
    return result;
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
    var module_match: Match = undefined;
    if (!matchInto(&module_match, module_pattern, module_value)) return Match.noMatch();

    var combined: [MAX_CAPTURES][]const u8 = undefined;
    var idx: usize = 0;
    for (module_match.captures) |cap| {
        combined[idx] = cap;
        idx += 1;
    }

    var event_match: Match = undefined;
    if (!matchInto(&event_match, event_pattern, event_value)) return Match.noMatch();

    if (idx + event_match.captures.len > MAX_CAPTURES) return Match.noMatch();
    for (event_match.captures) |cap| {
        combined[idx] = cap;
        idx += 1;
    }

    var result: Match = undefined;
    initFromCaptures(&result, true, combined[0..idx]);
    return result;
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

fn findNextStar(pattern: []const u8, start_index: usize) ?usize {
    var i: usize = start_index;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '*') return i;
    }
    return null;
}

fn findLiteral(haystack: []const u8, start_index: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start_index;
    if (start_index > haystack.len or needle.len > haystack.len) return null;

    var i: usize = start_index;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn initNoMatch(out: *Match) void {
    out.matched = false;
    out._capture_count = 0;
    out.captures = &[_][]const u8{};
}

fn finalizeMatch(out: *Match, capture_count: usize) void {
    out.matched = true;
    out._capture_count = capture_count;
    out.captures = if (capture_count > 0) out._capture_storage[0..capture_count] else &[_][]const u8{};
}

fn initFromCaptures(out: *Match, matched: bool, captures: []const []const u8) void {
    initNoMatch(out);
    if (!matched or captures.len == 0) {
        out.matched = matched;
        return;
    }

    const count = @min(captures.len, MAX_CAPTURES);
    for (captures[0..count], 0..) |cap, i| {
        out._capture_storage[i] = cap;
    }
    finalizeMatch(out, count);
}

fn matchInto(out: *Match, pattern: []const u8, value: []const u8) bool {
    initNoMatch(out);

    if (pattern.len == 0) {
        if (value.len == 0) {
            out.matched = true;
            return true;
        }
        return false;
    }

    const wildcard_count = countWildcards(pattern);
    if (wildcard_count == 0) {
        if (std.mem.eql(u8, pattern, value)) {
            out.matched = true;
            return true;
        }
        return false;
    }
    if (wildcard_count > MAX_CAPTURES) return false;

    var capture_count: usize = 0;
    var p_index: usize = 0;
    var v_index: usize = 0;

    if (pattern[0] != '*') {
        const first_star = findNextStar(pattern, 0) orelse pattern.len;
        const prefix = pattern[0..first_star];
        if (!std.mem.startsWith(u8, value, prefix)) return false;
        v_index = prefix.len;
        p_index = first_star;
    }

    while (p_index < pattern.len) {
        if (pattern[p_index] != '*') return false;

        const next_star = findNextStar(pattern, p_index + 1);
        const literal_start = p_index + 1;
        const literal_end = next_star orelse pattern.len;
        const literal = pattern[literal_start..literal_end];
        const is_last = next_star == null;

        if (is_last) {
            if (literal.len == 0) {
                out._capture_storage[capture_count] = value[v_index..];
                capture_count += 1;
                finalizeMatch(out, capture_count);
                return true;
            }

            if (!std.mem.endsWith(u8, value, literal)) return false;
            const suffix_start = value.len - literal.len;
            if (suffix_start < v_index) return false;

            out._capture_storage[capture_count] = value[v_index..suffix_start];
            capture_count += 1;
            finalizeMatch(out, capture_count);
            return true;
        }

        if (literal.len == 0) {
            out._capture_storage[capture_count] = value[v_index..v_index];
            capture_count += 1;
            p_index = next_star.?;
            continue;
        }

        const found = findLiteral(value, v_index, literal) orelse return false;
        out._capture_storage[capture_count] = value[v_index..found];
        capture_count += 1;
        v_index = found + literal.len;
        p_index = next_star.?;
    }

    finalizeMatch(out, capture_count);
    return true;
}
