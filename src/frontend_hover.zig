//! Hover / definition lookup on the post-import frontend AST.

const std = @import("std");
const ast = @import("ast");

pub const HoverResult = struct {
    contents: []const u8,
    definition_file: []const u8,
    definition_line: u32,
    definition_column: u32,
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/' or c == '.' or c == ':';
}

/// Expand from cursor to a Koru reference token (e.g. `std/store:new`).
pub fn qualifiedRefAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    line_1: u32,
    column_1: u32,
) ![]const u8 {
    var line_start: usize = 0;
    var cur_line: u32 = 1;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (cur_line == line_1) break;
            line_start = i + 1;
            cur_line += 1;
        }
    }
    if (cur_line != line_1) return allocator.dupe(u8, "");

    const line_end = blk: {
        var i = line_start;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        break :blk i;
    };
    const line = source[line_start..line_end];
    if (line.len == 0) return allocator.dupe(u8, "");

    const col0 = if (column_1 > 0) @min(column_1 - 1, line.len) else 0;

    if (col0 < line.len and isIdentChar(line[col0])) {
        var start = col0;
        var end = col0 + 1;
        while (start > 0 and isIdentChar(line[start - 1])) start -= 1;
        while (end < line.len and isIdentChar(line[end])) end += 1;
        if (start > 0 and line[start - 1] == ':') {
            var qstart = start - 1;
            while (qstart > 0 and isIdentChar(line[qstart - 1])) qstart -= 1;
            start = qstart;
        }
        return extractSpan(allocator, line, start, end);
    }

    // Cursor on whitespace, `(`, etc. — walk left to the preceding token.
    var pos = col0;
    while (pos > 0 and (line[pos - 1] == ' ' or line[pos - 1] == '(' or line[pos - 1] == '\t')) pos -= 1;
    if (pos > 0 and isIdentChar(line[pos - 1])) {
        var start = pos;
        while (start > 0 and isIdentChar(line[start - 1])) start -= 1;
        if (start > 0 and line[start - 1] == ':') {
            var qstart = start - 1;
            while (qstart > 0 and isIdentChar(line[qstart - 1])) qstart -= 1;
            start = qstart;
        }
        return extractSpan(allocator, line, start, pos);
    }

    // Scan right for a token ahead of the cursor.
    var right = col0;
    while (right < line.len and !isIdentChar(line[right])) right += 1;
    if (right < line.len) {
        const start = right;
        var end = right + 1;
        while (end < line.len and isIdentChar(line[end])) end += 1;
        return extractSpan(allocator, line, start, end);
    }

    return allocator.dupe(u8, "");
}

fn extractSpan(allocator: std.mem.Allocator, line: []const u8, start: usize, end: usize) ![]const u8 {
    const trimmed_end = end;
    var trimmed_start = start;
    while (trimmed_start < trimmed_end and (line[trimmed_start] == '(' or line[trimmed_start] == ' ')) : (trimmed_start += 1) {}
    var final_end = trimmed_end;
    while (final_end > trimmed_start and (line[final_end - 1] == '(' or line[final_end - 1] == ' ')) : (final_end -= 1) {}
    if (final_end <= trimmed_start) return allocator.dupe(u8, "");
    return allocator.dupe(u8, line[trimmed_start..final_end]);
}

fn modulePathToLogical(path: []const u8, buf: []u8) []const u8 {
    var j: usize = 0;
    for (path) |c| {
        if (j >= buf.len) break;
        buf[j] = if (c == '/') '.' else c;
        j += 1;
    }
    return buf[0..j];
}

fn lastColon(path: []const u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, path, ':');
}

fn eventDisplayName(module_logical: []const u8, event_name: []const u8, buf: []u8) []const u8 {
    // std.store + new → std/store:new
    var logical_slash: [256]u8 = undefined;
    var j: usize = 0;
    for (module_logical) |c| {
        if (j >= logical_slash.len) break;
        logical_slash[j] = if (c == '.') '/' else c;
        j += 1;
    }
    const mod_slash = logical_slash[0..j];
    const written = std.fmt.bufPrint(buf, "{s}:{s}", .{ mod_slash, event_name }) catch return event_name;
    return written;
}

fn eventMatchesRef(
    ed: *const ast.EventDecl,
    module_logical: []const u8,
    ref: []const u8,
) bool {
    const event_name = if (ed.path.segments.len > 0)
        ed.path.segments[ed.path.segments.len - 1]
    else
        return false;

    var display_buf: [320]u8 = undefined;
    const display = eventDisplayName(module_logical, event_name, &display_buf);

    if (std.mem.eql(u8, ref, display)) return true;
    if (std.mem.eql(u8, ref, event_name)) return true;

    if (lastColon(ref)) |colon| {
        var mod_buf: [256]u8 = undefined;
        const ref_mod = modulePathToLogical(ref[0..colon], &mod_buf);
        const ref_ev = ref[colon + 1 ..];
        if (std.mem.eql(u8, module_logical, ref_mod) and std.mem.eql(u8, event_name, ref_ev)) {
            return true;
        }
    }

    return false;
}

fn findEventInModule(mod: *const ast.ModuleDecl, ref: []const u8) ?*const ast.EventDecl {
    for (mod.items) |*item| {
        if (item.* != .event_decl) continue;
        if (eventMatchesRef(&item.event_decl, mod.logical_name, ref)) {
            return &item.event_decl;
        }
    }
    return null;
}

fn findEvent(program: *const ast.Program, ref: []const u8) ?struct {
    ed: *const ast.EventDecl,
    module_logical: []const u8,
} {
    if (ref.len == 0) return null;

    for (program.items) |*item| {
        if (item.* == .event_decl) {
            if (eventMatchesRef(&item.event_decl, program.main_module_name, ref)) {
                return .{ .ed = &item.event_decl, .module_logical = program.main_module_name };
            }
        }
        if (item.* != .module_decl) continue;
        if (findEventInModule(&item.module_decl, ref)) |ed| {
            return .{ .ed = ed, .module_logical = item.module_decl.logical_name };
        }
    }
    return null;
}

fn formatSignature(ed: *const ast.EventDecl, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if (ed.path.segments.len > 0) {
        for (ed.path.segments, 0..) |seg, i| {
            if (i > 0) w.writeAll(".") catch {};
            w.writeAll(seg) catch {};
        }
    }
    w.writeAll("(") catch {};
    if (ed.input.is_wildcard) {
        w.writeAll("*") catch {};
    } else {
        for (ed.input.fields, 0..) |f, i| {
            if (i > 0) w.writeAll(", ") catch {};
            w.print("{s}: {s}", .{ f.name, f.type }) catch {};
        }
    }
    w.writeAll(")") catch {};
    if (ed.return_type) |rt| w.print(" -> {s}", .{rt}) catch {};
    return fbs.getWritten();
}

pub fn hoverAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const ast.Program,
    line: u32,
    column: u32,
) !?HoverResult {
    const ref = try qualifiedRefAt(allocator, source, line, column);
    defer allocator.free(ref);
    if (ref.len == 0) return null;

    const found = findEvent(program, ref) orelse return null;
    const ed = found.ed;

    var display_buf: [320]u8 = undefined;
    const display = eventDisplayName(found.module_logical, ed.path.segments[ed.path.segments.len - 1], &display_buf);

    var sig_buf: [2048]u8 = undefined;
    const sig = formatSignature(ed, &sig_buf);

    const file = ed.location.file;
    const base = if (std.mem.lastIndexOfScalar(u8, file, '/')) |ix| file[ix + 1 ..] else file;

    var ann_buf: [512]u8 = undefined;
    var ann_written: []const u8 = "";
    if (ed.annotations.len > 0) {
        var fbs = std.io.fixedBufferStream(&ann_buf);
        const w = fbs.writer();
        w.writeAll("\n\n`[") catch {};
        for (ed.annotations, 0..) |ann, i| {
            if (i > 0) w.writeAll("|") catch {};
            w.writeAll(ann) catch {};
        }
        w.writeAll("]`") catch {};
        ann_written = fbs.getWritten();
    }

    const contents = try std.fmt.allocPrint(allocator, "**{s}**\n\n`{s}`\n\n`{s}:{d}`{s}", .{
        display,
        sig,
        base,
        ed.location.line,
        ann_written,
    });

    return .{
        .contents = contents,
        .definition_file = try allocator.dupe(u8, ed.location.file),
        .definition_line = @intCast(ed.location.line),
        .definition_column = if (ed.location.column > 0) @intCast(ed.location.column) else 1,
    };
}

pub fn deinitHoverResult(allocator: std.mem.Allocator, hr: HoverResult) void {
    allocator.free(hr.contents);
    allocator.free(hr.definition_file);
}

pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, s.len + 16);
    defer list.deinit(allocator);
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
