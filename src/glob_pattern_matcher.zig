// Glob Pattern Matcher - Wildcard Pattern Matching for Koru
// =============================================================================
//
// This module provides compile-time glob pattern matching used throughout Koru:
// - Event globbing: ~event log.* matches ~log.error, ~log.warn, etc.
// - Transform matching: transform runner matches invocations to glob patterns
// - Tap registration: module:event -> branch patterns
// - Generics: ring.new[T:u32] matches ring.new* pattern
//
// Wildcard Support:
//   - Full wildcard: * matches anything
//   - Prefix wildcard: *.io matches std.io, test.io, etc
//   - Suffix wildcard: file.* matches file.read, file.write, etc
//   - Bare suffix: print* matches println, printf, etc
//
// Examples:
//   log.*        matches log.error, log.warn, log.info
//   *.transform  matches image.transform, audio.transform
//   ring.new*    matches ring.new, ring.new[T:u32,N:1024]
//   *            matches anything (universal wildcard)
//
// All pattern matching happens at compile time - zero runtime cost.

const std = @import("std");

/// A parsed tap pattern with module, event, and branch components
pub const Pattern = struct {
    module_pattern: []const u8,  // "std.io", "*.io", "*"
    event_pattern: []const u8,   // "file.read", "file.*", "*"
    branch_name: []const u8,     // "success", "*" (exact only, no glob)

    /// Check if this pattern matches a concrete transition
    /// Returns true if all three components match
    pub fn matches(self: Pattern, module: []const u8, event: []const u8, branch: []const u8) bool {
        return matchSegment(self.module_pattern, module) and
               matchSegment(self.event_pattern, event) and
               matchSegment(self.branch_name, branch);
    }

    /// Create a pattern from separate components (useful for testing)
    pub fn init(module_pattern: []const u8, event_pattern: []const u8, branch_name: []const u8) Pattern {
        return .{
            .module_pattern = module_pattern,
            .event_pattern = event_pattern,
            .branch_name = branch_name,
        };
    }
};

/// Match a single segment with wildcard support
/// Supports: exact match, full wildcard (*), prefix wildcard (*.foo), suffix wildcard (foo.*, foo*)
pub fn matchSegment(pattern: []const u8, value: []const u8) bool {
    // Full wildcard matches anything
    if (std.mem.eql(u8, pattern, "*")) return true;

    // Exact match
    if (std.mem.eql(u8, pattern, value)) return true;

    // Prefix wildcard: *.io matches std.io, test.io
    if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
        const suffix = pattern[1..]; // includes the dot
        return std.mem.endsWith(u8, value, suffix);
    }

    // Suffix wildcard with dot: file.* matches file.read, file.write
    if (pattern.len > 2 and pattern[pattern.len - 2] == '.' and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 2]; // excludes the .*
        return std.mem.startsWith(u8, value, prefix) and
               value.len > prefix.len and value[prefix.len] == '.';
    }

    // Bare suffix wildcard: print* matches println, print, printf
    // (handles patterns without dot before asterisk)
    if (pattern.len > 1 and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1]; // everything before *
        return std.mem.startsWith(u8, value, prefix);
    }

    return false;
}

/// Check if a string contains a glob wildcard pattern
/// Returns true if the string contains '*', meaning it's a pattern, not a literal
pub fn isGlobPattern(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '*') != null;
}

// =============================================================================
// UNIT TESTS
// =============================================================================

test "isGlobPattern: detects wildcards" {
    try std.testing.expect(isGlobPattern("*"));
    try std.testing.expect(isGlobPattern("log.*"));
    try std.testing.expect(isGlobPattern("*.io"));
    try std.testing.expect(isGlobPattern("ring.new*"));
    try std.testing.expect(!isGlobPattern("log.error"));
    try std.testing.expect(!isGlobPattern("exact.match"));
}

test "matchSegment: full wildcard matches anything" {
    try std.testing.expect(matchSegment("*", "anything"));
    try std.testing.expect(matchSegment("*", "std.io"));
    try std.testing.expect(matchSegment("*", ""));
}

test "matchSegment: exact match" {
    try std.testing.expect(matchSegment("std.io", "std.io"));
    try std.testing.expect(matchSegment("file.read", "file.read"));
    try std.testing.expect(!matchSegment("std.io", "std.fs"));
    try std.testing.expect(!matchSegment("file.read", "dir.read"));
}

test "matchSegment: prefix wildcard" {
    // *.io matches anything ending in .io
    try std.testing.expect(matchSegment("*.io", "std.io"));
    try std.testing.expect(matchSegment("*.io", "test.io"));
    try std.testing.expect(matchSegment("*.io", "my.cool.io"));
    try std.testing.expect(!matchSegment("*.io", "std.fs"));
    try std.testing.expect(!matchSegment("*.io", "io")); // No dot before io
}

test "matchSegment: suffix wildcard with dot" {
    // file.* matches anything starting with file.
    try std.testing.expect(matchSegment("file.*", "file.read"));
    try std.testing.expect(matchSegment("file.*", "file.write"));
    try std.testing.expect(matchSegment("file.*", "file.open.async"));
    try std.testing.expect(!matchSegment("file.*", "dir.read"));
    try std.testing.expect(!matchSegment("file.*", "file")); // No dot after file
}

test "matchSegment: bare suffix wildcard" {
    // print* matches anything starting with print (no dot required)
    try std.testing.expect(matchSegment("print*", "println"));
    try std.testing.expect(matchSegment("print*", "print"));
    try std.testing.expect(matchSegment("print*", "printf"));
    try std.testing.expect(matchSegment("print*", "print.ln")); // also matches dotted
    try std.testing.expect(!matchSegment("print*", "sprint")); // doesn't start with print
    try std.testing.expect(!matchSegment("print*", "prin")); // too short
}

test "Pattern: exact match on all components" {
    const pattern = Pattern.init("std.io", "file.read", "success");

    try std.testing.expect(pattern.matches("std.io", "file.read", "success"));
    try std.testing.expect(!pattern.matches("std.fs", "file.read", "success"));
    try std.testing.expect(!pattern.matches("std.io", "file.write", "success"));
    try std.testing.expect(!pattern.matches("std.io", "file.read", "error"));
}

test "Pattern: wildcard on module" {
    const pattern = Pattern.init("*.io", "file.read", "success");

    try std.testing.expect(pattern.matches("std.io", "file.read", "success"));
    try std.testing.expect(pattern.matches("test.io", "file.read", "success"));
    try std.testing.expect(!pattern.matches("std.fs", "file.read", "success"));
}

test "Pattern: wildcard on event" {
    const pattern = Pattern.init("std.io", "file.*", "success");

    try std.testing.expect(pattern.matches("std.io", "file.read", "success"));
    try std.testing.expect(pattern.matches("std.io", "file.write", "success"));
    try std.testing.expect(!pattern.matches("std.io", "dir.read", "success"));
}

test "Pattern: wildcard on branch (universal tap)" {
    const pattern = Pattern.init("std.io", "file.read", "*");

    try std.testing.expect(pattern.matches("std.io", "file.read", "success"));
    try std.testing.expect(pattern.matches("std.io", "file.read", "error"));
    try std.testing.expect(pattern.matches("std.io", "file.read", "anything"));
}

test "Pattern: multiple wildcards" {
    const pattern = Pattern.init("*.io", "file.*", "success");

    try std.testing.expect(pattern.matches("std.io", "file.read", "success"));
    try std.testing.expect(pattern.matches("test.io", "file.write", "success"));
    try std.testing.expect(!pattern.matches("std.fs", "file.read", "success"));
    try std.testing.expect(!pattern.matches("std.io", "dir.read", "success"));
}

test "Pattern: universal pattern" {
    const pattern = Pattern.init("*", "*", "*");

    try std.testing.expect(pattern.matches("std.io", "file.read", "success"));
    try std.testing.expect(pattern.matches("test.lib", "compute", "result"));
    try std.testing.expect(pattern.matches("", "", "")); // Even empty strings
}

test "Pattern: compiler pipeline example" {
    // ~compiler:frontend -> ready
    const pattern = Pattern.init("compiler", "frontend", "ready");

    try std.testing.expect(pattern.matches("compiler", "frontend", "ready"));
    try std.testing.expect(!pattern.matches("compiler", "backend", "ready"));
}

test "Pattern: compiler glob example" {
    // ~compiler:* -> ready (any compiler event going to ready)
    const pattern = Pattern.init("compiler", "*", "ready");

    try std.testing.expect(pattern.matches("compiler", "frontend", "ready"));
    try std.testing.expect(pattern.matches("compiler", "backend", "ready"));
    try std.testing.expect(pattern.matches("compiler", "analysis", "ready"));
    try std.testing.expect(!pattern.matches("compiler", "frontend", "error"));
}
