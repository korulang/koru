const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");

/// Check if a proc body is syntactically pure (contains only flows, no host code)
pub fn checkSyntacticPurity(body: []const u8) bool {
    // Split body into lines and check each one
    var lines = std.mem.tokenizeAny(u8, body, "\n");
    while (lines.next()) |line| {
        const trimmed = lexer.trim(line);
        
        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (lexer.startsWith(trimmed, "//")) continue;
        
        // Check if line is a flow (starts with ~) or continuation (starts with |)
        if (!lexer.startsWith(trimmed, "~") and !lexer.startsWith(trimmed, "|")) {
            // Found non-flow code - proc is not pure
            return false;
        }
    }
    
    // All non-empty, non-comment lines are flows or continuations - proc is pure!
    return true;
}

/// Check if annotations contain a specific annotation
pub fn hasAnnotation(annotations: []const []const u8, annotation: []const u8) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann, annotation)) {
            return true;
        }
    }
    return false;
}

/// Convert a DottedPath to a string
pub fn pathToString(allocator: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer buf.deinit();
    for (path.segments, 0..) |seg, i| {
        if (i > 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, seg);
    }
    return try allocator.dupe(u8, buf.items);
}