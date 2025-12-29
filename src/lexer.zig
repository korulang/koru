const std = @import("std");

// Line-level lexical analysis helpers

pub const Line = struct {
    content: []const u8,
    indent: usize,
    line_num: usize,
};

/// Count leading spaces in a line
pub fn getIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Trim leading and trailing whitespace
pub fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

/// Check if line starts with a string (after trimming)
pub fn startsWith(line: []const u8, prefix: []const u8) bool {
    const trimmed = trim(line);
    return std.mem.startsWith(u8, trimmed, prefix);
}

/// Check if this is a Koru line (starts with ~ or |)
pub fn isKoruLine(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len == 0) return false;
    return trimmed[0] == '~' or trimmed[0] == '|';
}

/// Check if this is a continuation line (starts with |)
pub fn isContinuationLine(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len == 0) return false;
    return trimmed[0] == '|';
}

/// Check if a string is a valid identifier (starts with letter/underscore, contains only alphanumeric/underscore)
pub fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    
    // Must start with letter or underscore
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    
    // Rest must be alphanumeric or underscore
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    
    return true;
}

/// Extract content after a prefix
pub fn afterPrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    const trimmed = trim(line);
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const rest = trimmed[prefix.len..];
        return trim(rest);
    }
    return null;
}

/// Parse a dotted path (e.g., "file.read")
/// DEPRECATED: Use parseQualifiedPath for new code
pub fn parseDottedPath(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var segments = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (segments.items) |seg| allocator.free(seg);
        segments.deinit(allocator);
    }

    var iter = std.mem.tokenizeScalar(u8, path, '.');
    while (iter.next()) |segment| {
        const owned = try allocator.dupe(u8, segment);
        try segments.append(allocator, owned);
    }

    return segments.toOwnedSlice(allocator);
}

/// Parse a qualified path with optional module qualifier (e.g., "http:request.complete" or "local.event")
pub fn parseQualifiedPath(allocator: std.mem.Allocator, path: []const u8, ast: anytype) !ast.DottedPath {
    // Check for module qualifier (":")
    if (std.mem.indexOf(u8, path, ":")) |colon_idx| {
        // Has module qualifier
        const qualifier = path[0..colon_idx];
        const namespace_part = path[colon_idx + 1..];

        const segments = try parseDottedPath(allocator, namespace_part);

        return ast.DottedPath{
            .module_qualifier = try allocator.dupe(u8, qualifier),
            .segments = segments,
        };
    } else {
        // No module qualifier
        const segments = try parseDottedPath(allocator, path);

        return ast.DottedPath{
            .module_qualifier = null,
            .segments = segments,
        };
    }
}

/// Extract balanced braces content
pub fn extractBraces(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, "{") orelse return null;
    const end = std.mem.lastIndexOf(u8, line, "}") orelse return null;
    if (end <= start) return null;
    return line[start..end + 1];
}

/// Extract content between braces (not including braces)
pub fn extractBracesContent(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, "{") orelse return null;
    const end = std.mem.lastIndexOf(u8, line, "}") orelse return null;
    if (end <= start) return null;
    if (end == start + 1) return ""; // Empty braces
    return trim(line[start + 1..end]);
}

/// Parse arguments in the form (arg1:val1, arg2:val2)
pub const ArgPair = struct { name: []const u8, value: []const u8 };

/// Find the end of a brace-delimited block, handling nested braces
pub fn findMatchingBrace(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '{') return null;
    
    var depth: usize = 1;
    var i = start + 1;
    var in_string = false;
    var string_char: ?u8 = null;
    
    while (i < text.len and depth > 0) {
        const char = text[i];
        
        // Handle string literals - braces inside strings don't count
        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\' and i + 1 < text.len) {
                i += 1; // Skip escaped character
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
        } else {
            // Not in a string - count braces
            if (char == '{') {
                depth += 1;
            } else if (char == '}') {
                depth -= 1;
            }
        }
        
        i += 1;
    }
    
    if (depth == 0) {
        return i - 1; // Return index of closing brace
    }
    return null; // Unmatched braces
}

/// Find the index of a character, but only when at depth 0 (not inside braces, parens, or brackets)
/// Used for finding argument separators like ':' that shouldn't match inside nested structures
pub fn indexOfAtDepthZero(text: []const u8, needle: u8) ?usize {
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;

    for (text, 0..) |char, i| {
        // Handle string literals
        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\' and i + 1 < text.len) {
                continue; // Skip next iteration for escaped char
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
            continue;
        }

        // Track nesting depth
        switch (char) {
            '{' => brace_depth += 1,
            '}' => brace_depth -|= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -|= 1,
            else => {},
        }

        // Check for needle at depth 0
        if (char == needle and brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
            return i;
        }
    }
    return null;
}

pub fn parseArgs(allocator: std.mem.Allocator, args_str: []const u8) ![]ArgPair {
    var args = try std.ArrayList(ArgPair).initCapacity(allocator, 4);
    errdefer {
        for (args.items) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.value);
        }
        args.deinit(allocator);
    }

    // Remove parentheses if present
    const content = if (std.mem.startsWith(u8, args_str, "(") and std.mem.endsWith(u8, args_str, ")"))
        args_str[1..args_str.len - 1]
    else
        args_str;

    // Parse arguments with proper string handling
    var i: usize = 0;
    var arg_start: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;
    var in_braces = false;
    var paren_depth: usize = 0;  // Track nested parentheses for Expression params

    while (i <= content.len) {
        const at_end = i == content.len;
        const char = if (!at_end) content[i] else ',';

        // Track string boundaries
        if (!in_string and !in_braces and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string and char == string_char) {
            in_string = false;
            string_char = null;
        }

        // Track parenthesis depth for Expression params (e.g., func(x, y) shouldn't split at inner comma)
        if (!in_string and !in_braces) {
            if (char == '(') {
                paren_depth += 1;
            } else if (char == ')' and paren_depth > 0) {
                paren_depth -= 1;
            }
        }

        // Track brace boundaries for Source blocks
        if (!in_string and !in_braces and char == '{') {
            // Find the matching closing brace
            if (findMatchingBrace(content, i)) |closing_idx| {
                // Skip to the closing brace
                i = closing_idx;
                in_braces = false;
            } else {
                // Unmatched brace - treat as regular character
                in_braces = true;
            }
        } else if (in_braces and char == '}') {
            in_braces = false;
        }

        // Split on commas that aren't inside strings, braces, or nested parens
        if ((char == ',' or at_end) and !in_string and !in_braces and paren_depth == 0) {
            const arg_slice = trim(content[arg_start..i]);
            if (arg_slice.len > 0) {
                // Use depth-aware colon search to handle { field: value } expressions
                const colon_idx = indexOfAtDepthZero(arg_slice, ':');
                
                if (colon_idx) |idx| {
                    // Explicit form: name: value
                    const name = try allocator.dupe(u8, trim(arg_slice[0..idx]));
                    const value_str = trim(arg_slice[idx + 1..]);
                    
                    // Check if the value is a brace block (for Source)
                    if (std.mem.startsWith(u8, value_str, "{") and std.mem.endsWith(u8, value_str, "}")) {
                        // Include the braces in the value for now
                        // The parser will handle extracting the content
                    }
                    
                    const value = try allocator.dupe(u8, value_str);
                    try args.append(allocator, .{ .name = name, .value = value });
                } else {
                    // Shorthand form: extract field name from dotted expression
                    // e.g., r.data.source -> name: "source", value: "r.data.source"
                    // BUT: Don't use shorthand for:
                    // - Range expressions like "0..p.n" (contains "..")
                    // - Expressions with operators like "r.value > 10" (contains space/operators after last dot)
                    const has_range_op = std.mem.indexOf(u8, arg_slice, "..") != null;

                    // Check if this looks like a complex expression (not just field access)
                    // by seeing if the part after the last dot contains spaces or operators
                    const is_complex_expr = blk: {
                        if (has_range_op) break :blk true;
                        if (std.mem.lastIndexOf(u8, arg_slice, ".")) |last_dot| {
                            const after_dot = arg_slice[last_dot + 1..];
                            // If there's a space, operator, or paren after the field name, it's complex
                            for (after_dot) |c| {
                                if (c == ' ' or c == '>' or c == '<' or c == '=' or
                                    c == '+' or c == '-' or c == '*' or c == '/' or
                                    c == '!' or c == '&' or c == '|' or c == '(' or c == ')') {
                                    break :blk true;
                                }
                            }
                        }
                        break :blk false;
                    };

                    const name = if (!is_complex_expr) blk: {
                        if (std.mem.lastIndexOf(u8, arg_slice, ".")) |last_dot| {
                            break :blk try allocator.dupe(u8, arg_slice[last_dot + 1..]);
                        } else {
                            break :blk try allocator.dupe(u8, arg_slice);
                        }
                    } else try allocator.dupe(u8, arg_slice);
                    const value = try allocator.dupe(u8, arg_slice);
                    try args.append(allocator, .{ .name = name, .value = value });
                }
            }
            arg_start = i + 1;
        }
        
        i += 1;
    }

    return args.toOwnedSlice(allocator);
}

/// Check if a line is a pipeline continuation (starts with |>)
pub fn isPipelineContinuation(line: []const u8) bool {
    const trimmed = trim(line);
    return std.mem.startsWith(u8, trimmed, "|>");
}

/// Check if a line is a branch continuation (starts with | but not |>)
pub fn isBranchContinuation(line: []const u8) bool {
    const trimmed = trim(line);
    return std.mem.startsWith(u8, trimmed, "|") and !std.mem.startsWith(u8, trimmed, "|>");
}

/// Extract label from line (e.g., "@loop" from "... @loop")
pub fn extractLabel(line: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOf(u8, line, "@") orelse return null;
    const label = trim(line[idx + 1..]);
    if (label.len == 0) return null;
    
    // Make sure it's a valid identifier
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            return null;
        }
    }
    
    return label;
}

/// Extract label anchor/declaration (#label) from line
pub fn extractLabelAnchor(line: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOf(u8, line, "#") orelse return null;
    const label = trim(line[idx + 1..]);
    if (label.len == 0) return null;
    
    // Make sure it's a valid identifier
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            return null;
        }
    }
    
    return label;
}

/// Remove label from line if present
pub fn withoutLabel(line: []const u8) []const u8 {
    // Find @ that's at depth 0 (not inside parens/braces) and preceded by space
    // This avoids matching @as, @field, etc. which are Zig builtins
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;
    var last_at_depth_zero: ?usize = null;

    for (line, 0..) |char, i| {
        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\') {
                continue; // Skip escape sequence
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
            continue;
        }

        switch (char) {
            '{' => brace_depth += 1,
            '}' => brace_depth -|= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -|= 1,
            else => {},
        }

        // Only consider @ at depth 0 that's preceded by space (label syntax)
        // This avoids matching @as, @field, @import, etc.
        if (char == '@' and brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
            if (i > 0 and line[i - 1] == ' ') {
                last_at_depth_zero = i;
            }
        }
    }

    if (last_at_depth_zero) |idx| {
        return trim(line[0..idx]);
    }
    return line;
}

/// Remove label anchor from line if present
pub fn withoutLabelAnchor(line: []const u8) []const u8 {
    const idx = std.mem.lastIndexOf(u8, line, "#") orelse return line;
    return trim(line[0..idx]);
}

/// Parse positional arguments for subflow invocations
pub fn parsePositionalArgs(allocator: std.mem.Allocator, args_str: []const u8) ![][]const u8 {
    var args = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (args.items) |arg| {
            allocator.free(arg);
        }
        args.deinit(allocator);
    }
    
    // Remove parentheses if present
    var content = args_str;
    if (startsWith(content, "(") and std.mem.endsWith(u8, content, ")")) {
        content = content[1..content.len - 1];
    }
    
    // Split by comma
    var iter = std.mem.tokenizeScalar(u8, content, ',');
    while (iter.next()) |arg| {
        const trimmed = trim(arg);
        // Keep the value as-is, including quotes if present
        // This preserves the distinction between string literals and identifiers
        try args.append(allocator, try allocator.dupe(u8, trimmed));
    }
    
    return args.toOwnedSlice(allocator);
}

// Tests
test "getIndent" {
    try std.testing.expectEqual(@as(usize, 0), getIndent("no indent"));
    try std.testing.expectEqual(@as(usize, 2), getIndent("  two spaces"));
    try std.testing.expectEqual(@as(usize, 4), getIndent("    four spaces"));
}

test "parseDottedPath" {
    const allocator = std.testing.allocator;
    const segments = try parseDottedPath(allocator, "file.read.async");
    defer {
        for (segments) |seg| allocator.free(seg);
        allocator.free(segments);
    }
    
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("file", segments[0]);
    try std.testing.expectEqualStrings("read", segments[1]);
    try std.testing.expectEqualStrings("async", segments[2]);
}

test "extractBracesContent" {
    try std.testing.expectEqualStrings("path: []const u8", extractBracesContent("{ path: []const u8 }").?);
    try std.testing.expectEqualStrings("", extractBracesContent("{}").?);
    try std.testing.expect(extractBracesContent("no braces") == null);
}


test "parseArgs" {
    const allocator = std.testing.allocator;
    const args = try parseArgs(allocator, "(path:\"file.txt\", mode:read)");
    defer {
        for (args) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.value);
        }
        allocator.free(args);
    }
    
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("path", args[0].name);
    try std.testing.expectEqualStrings("\"file.txt\"", args[0].value);
    try std.testing.expectEqualStrings("mode", args[1].name);
    try std.testing.expectEqualStrings("read", args[1].value);
}

