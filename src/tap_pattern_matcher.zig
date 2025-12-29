// Tap Pattern Matcher - Module-Qualified Pattern Matching for Tap Registration
// =============================================================================
//
// This module provides compile-time pattern matching for tap registration.
// Since all pattern matching happens during code generation, there is zero
// runtime cost - only matching taps are emitted to the final binary.
//
// Pattern Syntax:
//   module:event -> branch
//
// Wildcard Support:
//   - Full wildcard: * matches anything
//   - Prefix wildcard: *.io matches std.io, test.io, etc
//   - Suffix wildcard: file.* matches file.read, file.write, etc
//
// Scoping Rules (consistent with event calls):
//   - Unqualified tap in module "logger" → auto-scoped to "logger:event"
//   - Qualified tap → used as-is
//   - * → universal wildcard
//
// Examples:
//   std.io:file.read -> success   // Specific typed tap
//   std.io:* -> success            // Any std.io event going to success
//   *.io:file.read -> error        // Any io module's file.read going to error
//   * -> *                          // Universal (requires metatype)
//
// Branch Globbing:
//   Branches do NOT support glob patterns because different branches have
//   different typed shapes. You can only match exact branch names or use *
//   for universal matching (which requires metatypes).

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

// =============================================================================
// UNIT TESTS
// =============================================================================

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
