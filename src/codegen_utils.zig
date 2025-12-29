const std = @import("std");

/// Zig keywords that need to be escaped when used as identifiers
const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "align", {} },
    .{ "allowzero", {} },
    .{ "and", {} },
    .{ "anyframe", {} },
    .{ "anytype", {} },
    .{ "asm", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "callconv", {} },
    .{ "catch", {} },
    .{ "comptime", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "errdefer", {} },
    .{ "error", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "fn", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "inline", {} },
    .{ "linksection", {} },
    .{ "noalias", {} },
    .{ "noinline", {} },
    .{ "nosuspend", {} },
    .{ "opaque", {} },
    .{ "or", {} },
    .{ "orelse", {} },
    .{ "packed", {} },
    .{ "pub", {} },
    .{ "resume", {} },
    .{ "return", {} },
    .{ "struct", {} },
    .{ "suspend", {} },
    .{ "switch", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "try", {} },
    .{ "union", {} },
    .{ "unreachable", {} },
    .{ "usingnamespace", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
});

/// Check if an identifier needs escaping for Zig
pub fn needsEscaping(name: []const u8) bool {
    return zig_keywords.has(name);
}

/// Escape a Zig identifier if it's a keyword
/// Caller owns the returned memory
pub fn escapeZigIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (zig_keywords.has(name)) {
        return std.fmt.allocPrint(allocator, "@\"{s}\"", .{name});
    }
    // Not a keyword, return the name as-is (caller must dupe if needed)
    return name;
}

/// Write an escaped identifier to a writer
pub fn writeEscapedIdentifier(writer: anytype, name: []const u8) !void {
    if (zig_keywords.has(name)) {
        try writer.print("@\"{s}\"", .{name});
    } else {
        try writer.writeAll(name);
    }
}

/// Append an escaped identifier to an ArrayList
pub fn appendEscapedIdentifier(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    if (zig_keywords.has(name)) {
        try list.appendSlice(allocator, "@\"");
        try list.appendSlice(allocator, name);
        try list.appendSlice(allocator, "\"");
    } else {
        try list.appendSlice(allocator, name);
    }
}

// ============================================================================
// STRUCT LITERAL CONVERSION
// ============================================================================
//
// Converts Koru struct literal syntax to Zig anonymous struct syntax:
//   Koru: { field: value, other: value2 }
//   Zig:  .{ .field = value, .other = value2 }
//
// This is THE canonical way to initialize structs in Koru.
// Used by ~capture and anywhere struct literals appear.
//
// Handles:
//   - Multiple fields
//   - Nested structs: { outer: { inner: 1 } }
//   - Complex values with colons: { arr: @as([]const u8, "hi") }
//   - Whitespace preservation

/// Convert a Koru struct literal to Zig anonymous struct syntax
/// Input:  "{ field: value, other: value2 }"
/// Output: ".{ .field = value, .other = value2 }"
/// Caller owns returned memory.
pub fn koruStructToZig(allocator: std.mem.Allocator, koru_struct: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, koru_struct.len + 16);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    const input = std.mem.trim(u8, koru_struct, " \t\n\r");

    while (i < input.len) {
        const c = input[i];

        if (c == '{') {
            // Opening brace becomes .{
            try result.append(allocator, '.');
            try result.append(allocator, '{');
            i += 1;
            // Skip whitespace after {
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
            // Now we're at field position - read field name
            if (i < input.len and input[i] != '}') {
                const field_result = try parseFieldAndValue(allocator, input, i, &result);
                i = field_result;
            }
        } else if (c == ',') {
            // Comma - output it, then read next field
            try result.append(allocator, ',');
            i += 1;
            // Skip whitespace after comma
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
            // Now at next field position
            if (i < input.len and input[i] != '}') {
                const field_result = try parseFieldAndValue(allocator, input, i, &result);
                i = field_result;
            }
        } else if (c == '}') {
            // Closing brace - just output it
            try result.append(allocator, '}');
            i += 1;
        } else {
            // Other characters (shouldn't happen at top level, but pass through)
            try result.append(allocator, c);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse a field name, colon, and value. Output as ".fieldname = value"
/// Returns the new position after the value.
fn parseFieldAndValue(
    allocator: std.mem.Allocator,
    input: []const u8,
    start: usize,
    result: *std.ArrayList(u8),
) std.mem.Allocator.Error!usize {
    var i = start;

    // Read field name (identifier)
    const field_start = i;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
        i += 1;
    }
    const field_name = input[field_start..i];

    if (field_name.len == 0) {
        // No field name - might be empty struct or error, just return
        return i;
    }

    // Skip whitespace before colon
    while (i < input.len and (input[i] == ' ' or input[i] == '\t')) {
        i += 1;
    }

    // Expect colon
    if (i < input.len and input[i] == ':') {
        // Output ".fieldname = "
        try result.append(allocator, '.');
        try result.appendSlice(allocator, field_name);
        try result.appendSlice(allocator, " = ");
        i += 1; // skip colon

        // Skip whitespace after colon
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) {
            i += 1;
        }

        // Now read the value until we hit a comma or closing brace at depth 0
        i = try parseValue(allocator, input, i, result);
    } else {
        // No colon - just output the field name as-is (error recovery)
        try result.appendSlice(allocator, field_name);
    }

    return i;
}

/// Parse a value expression, handling nested braces/parens/brackets
/// Outputs the value (converting nested Koru structs to Zig)
/// Returns position after the value (at comma, closing brace, or end)
fn parseValue(
    allocator: std.mem.Allocator,
    input: []const u8,
    start: usize,
    result: *std.ArrayList(u8),
) std.mem.Allocator.Error!usize {
    var i = start;
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;

    while (i < input.len) {
        const c = input[i];

        // Check for end of value at depth 0
        if (brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
            if (c == ',' or c == '}') {
                break;
            }
        }

        if (c == '{') {
            // Nested struct - recursively convert
            brace_depth += 1;
            try result.append(allocator, '.');
            try result.append(allocator, '{');
            i += 1;
            // Skip whitespace
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
            // Parse nested fields
            if (i < input.len and input[i] != '}') {
                i = try parseFieldAndValue(allocator, input, i, result);
            }
        } else if (c == '}') {
            brace_depth -= 1;
            try result.append(allocator, '}');
            i += 1;
        } else if (c == '(') {
            paren_depth += 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == ')') {
            paren_depth -= 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == '[') {
            bracket_depth += 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == ']') {
            bracket_depth -= 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == ',' and brace_depth > 0) {
            // Comma inside nested struct - handle next field
            try result.append(allocator, ',');
            i += 1;
            // Skip whitespace
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
            // Parse next field in nested struct
            if (i < input.len and input[i] != '}') {
                i = try parseFieldAndValue(allocator, input, i, result);
            }
        } else {
            // Regular character - pass through
            try result.append(allocator, c);
            i += 1;
        }
    }

    return i;
}

// Tests for struct literal conversion
test "koruStructToZig simple" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ total: 0 }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .total = 0 }", result);
}

test "koruStructToZig multiple fields" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ a: 1, b: 2 }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .a = 1, .b = 2 }", result);
}

test "koruStructToZig with @as type annotation" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ total: @as(i32, 0) }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .total = @as(i32, 0) }", result);
}

test "koruStructToZig nested struct" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ outer: { inner: 1 } }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .outer = .{ .inner = 1 } }", result);
}
