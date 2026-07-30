//! Frontend diagnostics for editor tooling — parse errors from the reporter and AST.

const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

pub const Diagnostic = struct {
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    hint: ?[]const u8 = null,
};

pub fn freeSlice(allocator: std.mem.Allocator, diags: []Diagnostic) void {
    for (diags) |d| {
        allocator.free(d.severity);
        allocator.free(d.code);
        allocator.free(d.message);
        if (d.hint) |h| allocator.free(h);
    }
    allocator.free(diags);
}

fn filesMatch(display_file: []const u8, loc_file: []const u8) bool {
    if (std.mem.eql(u8, display_file, loc_file)) return true;
    return std.mem.eql(u8, std.fs.path.basename(display_file), std.fs.path.basename(loc_file));
}

pub fn collectReporter(
    allocator: std.mem.Allocator,
    reporter: *const errors.ErrorReporter,
    display_file: []const u8,
) ![]Diagnostic {
    _ = display_file;
    var list = try std.ArrayList(Diagnostic).initCapacity(allocator, reporter.errors.items.len);

    for (reporter.errors.items) |err| {
        const line: u32 = if (err.location.line > 0) @intCast(err.location.line) else 1;
        const column: u32 = if (err.location.column > 0) @intCast(err.location.column) else 1;
        const end_column: u32 = column + @as(u32, @intCast(@max(err.span_length, 1)));

        try list.append(allocator, .{
            .line = line,
            .column = column,
            .end_line = line,
            .end_column = end_column,
            .severity = try allocator.dupe(u8, "error"),
            .code = try allocator.dupe(u8, @tagName(err.code)),
            .message = try allocator.dupe(u8, err.message),
            .hint = if (err.hint) |h| try allocator.dupe(u8, h) else null,
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn collectProgramParseErrors(
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    display_file: []const u8,
) ![]Diagnostic {
    var list = try std.ArrayList(Diagnostic).initCapacity(allocator, 4);

    for (program.items) |item| {
        if (item != .parse_error) continue;
        const pe = item.parse_error;
        if (!filesMatch(display_file, pe.location.file)) continue;

        const line: u32 = if (pe.location.line > 0) @intCast(pe.location.line) else 1;
        const column: u32 = if (pe.location.column > 0) @intCast(pe.location.column) else 1;

        try list.append(allocator, .{
            .line = line,
            .column = column,
            .end_line = line,
            .end_column = column + 1,
            .severity = try allocator.dupe(u8, "error"),
            .code = try allocator.dupe(u8, @tagName(pe.error_code)),
            .message = try allocator.dupe(u8, pe.message),
            .hint = if (pe.hint) |h| try allocator.dupe(u8, h) else null,
        });
    }

    return try list.toOwnedSlice(allocator);
}

pub fn merge(
    allocator: std.mem.Allocator,
    a: []Diagnostic,
    b: []Diagnostic,
) ![]Diagnostic {
    if (a.len == 0) return b;
    if (b.len == 0) return a;

    var list = try std.ArrayList(Diagnostic).initCapacity(allocator, a.len + b.len);

    try list.appendSlice(allocator, a);
    try list.appendSlice(allocator, b);
    allocator.free(a);
    allocator.free(b);
    return try list.toOwnedSlice(allocator);
}

pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, s.len + 16);
    errdefer list.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\\' => try list.appendSlice(allocator, "\\"),
            '"' => try list.appendSlice(allocator, "\\\""),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Serialize `{"type":"diagnostics","file":"…","items":[…]}` for CCP.
pub fn serializeJson(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    diags: []const Diagnostic,
    id: ?i64,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer buf.deinit(allocator);

    const file_esc = try jsonEscape(allocator, file_path);
    defer allocator.free(file_esc);

    try buf.appendSlice(allocator, "{\"type\":\"diagnostics\"");
    if (id) |req_id| {
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, ",\"id\":{d}", .{req_id});
        try buf.appendSlice(allocator, id_str);
    }
    try buf.appendSlice(allocator, ",\"file\":\"");
    try buf.appendSlice(allocator, file_esc);
    try buf.appendSlice(allocator, "\",\"items\":[");

    for (diags, 0..) |d, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        const msg_esc = try jsonEscape(allocator, d.message);
        defer allocator.free(msg_esc);
        const code_esc = try jsonEscape(allocator, d.code);
        defer allocator.free(code_esc);

        try buf.appendSlice(allocator, "{\"line\":");
        var num_buf: [16]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{d.line}));
        try buf.appendSlice(allocator, ",\"column\":");
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{d.column}));
        try buf.appendSlice(allocator, ",\"endLine\":");
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{d.end_line}));
        try buf.appendSlice(allocator, ",\"endColumn\":");
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{d.end_column}));
        try buf.appendSlice(allocator, ",\"severity\":\"");
        try buf.appendSlice(allocator, d.severity);
        try buf.appendSlice(allocator, "\",\"code\":\"");
        try buf.appendSlice(allocator, code_esc);
        try buf.appendSlice(allocator, "\",\"message\":\"");
        try buf.appendSlice(allocator, msg_esc);
        try buf.appendSlice(allocator, "\"");

        if (d.hint) |hint| {
            const hint_esc = try jsonEscape(allocator, hint);
            defer allocator.free(hint_esc);
            try buf.appendSlice(allocator, ",\"hint\":\"");
            try buf.appendSlice(allocator, hint_esc);
            try buf.appendSlice(allocator, "\"");
        }

        try buf.appendSlice(allocator, "}");
    }

    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}
