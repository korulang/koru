// ============================================================================
// Annotation Parser - Shared Utilities for Parametrized Annotations
// ============================================================================
// This library provides parsing and querying utilities for Koru annotations.
//
// Koru annotations are stored as opaque strings in the AST:
//   annotations: []const []const u8 = &[_][]const u8{}
//
// Simple annotations: "pure", "comptime", "norun"
// Parametrized annotations: "depends_on(\"a\", \"b\")", "timeout(30)", "retry(3)"
//
// This library enables:
// - Frontend: Parse build orchestration annotations
// - Backend: Parse comptime metaprogramming annotations
// - Future: Any parametrized annotation (cache, retry, timeout, etc.)
//
// Design Philosophy:
// - Parser treats annotations as opaque strings
// - This library interprets the syntax
// - Separation of concerns: syntax vs semantics
// ============================================================================

const std = @import("std");

/// AnnotationCall represents a parsed parametrized annotation
/// Example: "depends_on(\"compile\", \"test\")" →
///   AnnotationCall{ .name = "depends_on", .args = ["compile", "test"] }
pub const AnnotationCall = struct {
    name: []const u8,
    args: [][]const u8,

    /// Free all memory associated with this annotation call
    pub fn deinit(self: *AnnotationCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.args) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.args);
    }
};

/// Parse a single annotation string into an AnnotationCall
/// Returns null if the annotation is not a parametrized call (simple annotation)
/// Returns error if the annotation has invalid syntax
///
/// Examples:
///   parseCall("depends_on(\"a\", \"b\")") → AnnotationCall{ name="depends_on", args=["a", "b"] }
///   parseCall("pure") → null (simple annotation)
///   parseCall("timeout(30)") → AnnotationCall{ name="timeout", args=["30"] }
///   parseCall("invalid(") → error.InvalidSyntax
pub fn parseCall(allocator: std.mem.Allocator, annotation: []const u8) !?AnnotationCall {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, annotation, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Find opening parenthesis
    const open_paren_pos = std.mem.indexOf(u8, trimmed, "(") orelse {
        // No parenthesis → simple annotation
        return null;
    };

    // Extract name (everything before '(')
    const name = std.mem.trim(u8, trimmed[0..open_paren_pos], " \t");
    if (name.len == 0) return error.InvalidSyntax;

    // Find closing parenthesis
    if (trimmed[trimmed.len - 1] != ')') {
        return error.InvalidSyntax;
    }

    // Extract argument list (everything between '(' and ')')
    const args_str = trimmed[open_paren_pos + 1 .. trimmed.len - 1];

    // Parse arguments (comma-separated, quoted strings)
    var args = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    // If empty args, return empty list
    const args_trimmed = std.mem.trim(u8, args_str, " \t");
    if (args_trimmed.len == 0) {
        return AnnotationCall{
            .name = try allocator.dupe(u8, name),
            .args = try args.toOwnedSlice(allocator),
        };
    }

    // Parse comma-separated arguments
    // State machine to handle quoted strings with commas inside
    var i: usize = 0;
    var current_arg_start: usize = 0;
    var in_string: bool = false;
    var escape_next: bool = false;

    while (i < args_trimmed.len) : (i += 1) {
        const c = args_trimmed[i];

        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\') {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (c == ',' and !in_string) {
            // Found argument boundary
            const arg_str = std.mem.trim(u8, args_trimmed[current_arg_start..i], " \t");
            const parsed_arg = try parseArgumentValue(allocator, arg_str);
            try args.append(allocator, parsed_arg);
            current_arg_start = i + 1;
        }
    }

    // Handle last argument
    if (current_arg_start < args_trimmed.len) {
        const arg_str = std.mem.trim(u8, args_trimmed[current_arg_start..], " \t");
        const parsed_arg = try parseArgumentValue(allocator, arg_str);
        try args.append(allocator, parsed_arg);
    }

    return AnnotationCall{
        .name = try allocator.dupe(u8, name),
        .args = try args.toOwnedSlice(allocator),
    };
}

/// Parse a single argument value, handling quoted strings and unquoted literals
/// Examples:
///   "\"hello\"" → "hello" (strip quotes, handle escapes)
///   "42" → "42" (keep as-is)
fn parseArgumentValue(allocator: std.mem.Allocator, arg_str: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, arg_str, " \t");

    // If it starts and ends with quotes, it's a string literal
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        const inner = trimmed[1 .. trimmed.len - 1];
        // Handle escape sequences
        return try unescapeString(allocator, inner);
    }

    // Otherwise, keep as-is (number, identifier, etc.)
    return try allocator.dupe(u8, trimmed);
}

/// Unescape a string (handle \", \\, \n, etc.)
fn unescapeString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const next = s[i + 1];
            switch (next) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                'r' => try result.append(allocator, '\r'),
                else => {
                    // Unknown escape, keep both characters
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                },
            }
            i += 1; // Skip the next character
        } else {
            try result.append(allocator, s[i]);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if an annotation list contains a simple annotation
/// Example: hasSimple(annotations, "pure") checks for ~[pure]
pub fn hasSimple(annotations: []const []const u8, name: []const u8) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann, name)) return true;
    }
    return false;
}

/// Check if an annotation list contains an annotation part in a compound annotation
/// Compound annotations use | as separator: comptime|transform, comptime|norun
/// Example: hasPart(annotations, "transform") returns true for [comptime|transform]
/// Example: hasPart(annotations, "comptime") returns true for both [comptime] and [comptime|transform]
pub fn hasPart(annotations: []const []const u8, part_name: []const u8) bool {
    for (annotations) |ann| {
        // Check if annotation matches exactly (simple case)
        if (std.mem.eql(u8, ann, part_name)) return true;

        // Check if annotation contains the part as a pipe-separated component
        var iter = std.mem.splitScalar(u8, ann, '|');
        while (iter.next()) |ann_part| {
            const trimmed = std.mem.trim(u8, ann_part, " \t");
            if (std.mem.eql(u8, trimmed, part_name)) return true;
        }
    }
    return false;
}

/// Check if an event has the [keyword] annotation
/// Events with [keyword] can be invoked without module qualification
pub fn isKeyword(annotations: []const []const u8) bool {
    return hasPart(annotations, "keyword");
}

/// Get a parametrized annotation call by name
/// Returns the parsed AnnotationCall if found, null otherwise
/// Example: getCall(annotations, "depends_on") → AnnotationCall with args
pub fn getCall(
    allocator: std.mem.Allocator,
    annotations: []const []const u8,
    name: []const u8,
) !?AnnotationCall {
    for (annotations) |ann| {
        // Try to parse as a call
        if (try parseCall(allocator, ann)) |call| {
            // Check if the name matches
            if (std.mem.eql(u8, call.name, name)) {
                return call;
            }
            // Name doesn't match, clean up and continue
            var mutable_call = call;
            mutable_call.deinit(allocator);
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "parseCall - simple annotation returns null" {
    const allocator = std.testing.allocator;
    const result = try parseCall(allocator, "pure");
    try std.testing.expect(result == null);
}

test "parseCall - empty args" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "timeout()")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("timeout", result.name);
    try std.testing.expectEqual(@as(usize, 0), result.args.len);
}

test "parseCall - single quoted arg" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "depends_on(\"compile\")")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("compile", result.args[0]);
}

test "parseCall - multiple quoted args" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "depends_on(\"compile\", \"test\", \"lint\")")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 3), result.args.len);
    try std.testing.expectEqualStrings("compile", result.args[0]);
    try std.testing.expectEqualStrings("test", result.args[1]);
    try std.testing.expectEqualStrings("lint", result.args[2]);
}

test "parseCall - numeric arg" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "timeout(30)")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("timeout", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("30", result.args[0]);
}

test "parseCall - whitespace tolerance" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "  depends_on ( \"a\" , \"b\" )  ")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.args.len);
    try std.testing.expectEqualStrings("a", result.args[0]);
    try std.testing.expectEqualStrings("b", result.args[1]);
}

test "parseCall - escaped quotes" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "msg(\"Hello \\\"world\\\"\")")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("msg", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("Hello \"world\"", result.args[0]);
}

test "hasSimple - finds simple annotation" {
    const annotations = &[_][]const u8{ "pure", "comptime", "norun" };
    try std.testing.expect(hasSimple(annotations, "pure"));
    try std.testing.expect(hasSimple(annotations, "comptime"));
    try std.testing.expect(!hasSimple(annotations, "async"));
}

test "hasPart - finds parts in compound annotations" {
    const annotations = &[_][]const u8{ "comptime|transform", "runtime", "comptime|norun" };

    // Should find both parts of compound annotations
    try std.testing.expect(hasPart(annotations, "comptime"));
    try std.testing.expect(hasPart(annotations, "transform"));
    try std.testing.expect(hasPart(annotations, "norun"));

    // Should find simple annotations too
    try std.testing.expect(hasPart(annotations, "runtime"));

    // Should not find non-existent parts
    try std.testing.expect(!hasPart(annotations, "async"));
    try std.testing.expect(!hasPart(annotations, "pure"));
}

test "getCall - finds parametrized annotation" {
    const allocator = std.testing.allocator;
    const annotations = &[_][]const u8{ "pure", "depends_on(\"a\", \"b\")", "comptime" };

    var result = (try getCall(allocator, annotations, "depends_on")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.args.len);
    try std.testing.expectEqualStrings("a", result.args[0]);
    try std.testing.expectEqualStrings("b", result.args[1]);
}

test "getCall - returns null when not found" {
    const allocator = std.testing.allocator;
    const annotations = &[_][]const u8{ "pure", "comptime" };

    const result = try getCall(allocator, annotations, "depends_on");
    try std.testing.expect(result == null);
}
