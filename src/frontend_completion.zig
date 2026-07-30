//! Completion candidates for editor tooling — import paths and module events.

const std = @import("std");
const ast = @import("ast");
const file_types = @import("file_types");
const frontend_introspect = @import("frontend_introspect.zig");
const frontend_hover = @import("frontend_hover.zig");

pub const CompletionItem = struct {
    label: []const u8,
    insert: []const u8,
    detail: ?[]const u8 = null,
    kind: []const u8,
};

pub const CompletionResult = struct {
    start_column: u32,
    end_column: u32,
    items: []CompletionItem,
};

pub fn deinitResult(allocator: std.mem.Allocator, result: CompletionResult) void {
    for (result.items) |item| {
        allocator.free(item.label);
        allocator.free(item.insert);
        if (item.detail) |d| allocator.free(d);
        allocator.free(item.kind);
    }
    allocator.free(result.items);
}

fn isRefChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/' or c == '.' or c == ':';
}

fn lineAtSource(source: []const u8, line_1: u32) ?[]const u8 {
    var line_start: usize = 0;
    var cur_line: u32 = 1;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            if (cur_line == line_1) return source[line_start..i];
            line_start = i + 1;
            cur_line += 1;
        }
    }
    if (cur_line == line_1) return source[line_start..];
    return null;
}

fn refSpanAt(line: []const u8, col0: usize) struct { start: usize, end: usize, text: []const u8 } {
    const end = @min(col0, line.len);
    var start = end;
    while (start > 0 and isRefChar(line[start - 1])) start -= 1;
    while (start > 0 and line[start - 1] == ':') {
        start -= 1;
        while (start > 0 and isRefChar(line[start - 1])) start -= 1;
    }
    return .{ .start = start, .end = end, .text = if (end > start) line[start..end] else "" };
}

fn importSpanAt(line: []const u8, col0: usize) ?struct { start: usize, end: usize, text: []const u8 } {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    if (!std.mem.startsWith(u8, line[i..], "import ")) return null;
    i += "import ".len;
    while (i < line.len and line[i] == ' ') i += 1;
    const start = i;
    const end = @min(col0, line.len);
    if (col0 < start) return null;
    return .{ .start = start, .end = end, .text = if (end > start) line[start..end] else "" };
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

fn eventDisplayName(module_logical: []const u8, event_name: []const u8, buf: []u8) []const u8 {
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

fn startsWithPrefix(hay: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, hay, prefix);
}

fn appendItem(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(CompletionItem),
    label: []const u8,
    insert: []const u8,
    detail: ?[]const u8,
    kind: []const u8,
) !void {
    try list.append(allocator, .{
        .label = try allocator.dupe(u8, label),
        .insert = try allocator.dupe(u8, insert),
        .detail = if (detail) |d| try allocator.dupe(u8, d) else null,
        .kind = try allocator.dupe(u8, kind),
    });
}

fn collectEvents(
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    module_slash: []const u8,
    event_prefix: []const u8,
    list: *std.ArrayList(CompletionItem),
) !void {
    var logical_buf: [256]u8 = undefined;
    const module_logical = modulePathToLogical(module_slash, &logical_buf);

    var sig_buf: [512]u8 = undefined;
    var display_buf: [320]u8 = undefined;

    const consider = struct {
        fn one(
            allocator2: std.mem.Allocator,
            items: *std.ArrayList(CompletionItem),
            mod_logical: []const u8,
            ed: *const ast.EventDecl,
            prefix: []const u8,
            sig: []u8,
            display: []u8,
        ) !void {
            const event_name = if (ed.path.segments.len > 0)
                ed.path.segments[ed.path.segments.len - 1]
            else
                return;
            if (prefix.len > 0 and !std.mem.startsWith(u8, event_name, prefix)) return;

            const label = eventDisplayName(mod_logical, event_name, display);
            const detail = formatSignature(ed, sig);
            const insert = if (prefix.len > 0) event_name[prefix.len..] else event_name;
            try appendItem(allocator2, items, label, insert, detail, "function");
        }
    }.one;

    for (program.items) |*item| {
        switch (item.*) {
            .event_decl => |*ed| {
                if (!std.mem.eql(u8, program.main_module_name, module_logical)) continue;
                try consider(allocator, list, program.main_module_name, ed, event_prefix, &sig_buf, &display_buf);
            },
            .module_decl => |*mod| {
                if (!std.mem.eql(u8, mod.logical_name, module_logical)) continue;
                for (mod.items) |*mi| {
                    if (mi.* != .event_decl) continue;
                    try consider(allocator, list, mod.logical_name, &mi.event_decl, event_prefix, &sig_buf, &display_buf);
                }
            },
            else => {},
        }
    }
}

fn resolveAliasDir(
    ctx: *frontend_introspect.Context,
    alias: []const u8,
) ![]const u8 {
    var result = try (&ctx.resolver).resolveBoth(alias, null);
    defer result.deinit(ctx.gpa);

    if (result.dir_path) |d| return try ctx.gpa.dupe(u8, d);
    if (result.file_path) |f| {
        const dir = std.fs.path.dirname(f) orelse return error.AliasNotFound;
        return try ctx.gpa.dupe(u8, dir);
    }
    return error.AliasNotFound;
}

fn walkModulePaths(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    logical_prefix: []const u8,
    filter_prefix: []const u8,
    list: *std.ArrayList(CompletionItem),
    depth: usize,
) !void {
    if (depth > 6 or list.items.len > 400) return;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file) {
            if (!file_types.isKoruFile(entry.name)) continue;
            const basename = entry.name;
            const ext = file_types.koruExtensionOf(basename) orelse continue;
            const stem = basename[0 .. basename.len - ext.len];
            if (std.mem.eql(u8, stem, "index")) continue;

            const path = if (logical_prefix.len == 0)
                try allocator.dupe(u8, stem)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ logical_prefix, stem });
            defer allocator.free(path);

            if (filter_prefix.len > 0 and !startsWithPrefix(path, filter_prefix)) continue;
            if (filter_prefix.len > 0 and std.mem.eql(u8, path, filter_prefix)) continue;

            const insert = if (filter_prefix.len > 0 and path.len > filter_prefix.len)
                path[filter_prefix.len..]
            else
                path;
            try appendItem(allocator, list, path, insert, null, "module");
        } else if (entry.kind == .directory) {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            const sub_logical = if (logical_prefix.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ logical_prefix, entry.name });
            defer allocator.free(sub_logical);

            if (filter_prefix.len > 0 and !startsWithPrefix(filter_prefix, sub_logical) and
                !startsWithPrefix(sub_logical, filter_prefix)) continue;

            const sub_dir = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(sub_dir);
            try walkModulePaths(allocator, sub_dir, sub_logical, filter_prefix, list, depth + 1);
        }
    }
}

fn collectImportPaths(
    allocator: std.mem.Allocator,
    ctx: *frontend_introspect.Context,
    prefix: []const u8,
    list: *std.ArrayList(CompletionItem),
) !void {
    const slash = std.mem.indexOfScalar(u8, prefix, '/');
    const alias = if (slash) |s| prefix[0..s] else prefix;
    const remainder = if (slash) |s| prefix[s + 1 ..] else "";

    if (ctx.project_config.paths.get(alias)) |_| {
        const base_dir = resolveAliasDir(ctx, alias) catch return;
        defer ctx.gpa.free(base_dir);

        var sub_dir = base_dir;
        var sub_logical = try allocator.dupe(u8, alias);
        defer allocator.free(sub_logical);

        if (remainder.len > 0) {
            const candidate = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, remainder });
            defer allocator.free(candidate);
            if (ModuleResolver.isDirectory(candidate)) {
                sub_dir = candidate;
                allocator.free(sub_logical);
                sub_logical = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ alias, remainder });
            }
        }

        try walkModulePaths(allocator, sub_dir, sub_logical, prefix, list, 0);
        return;
    }

    var iter = ctx.project_config.paths.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (prefix.len > 0 and !startsWithPrefix(name, prefix) and !startsWithPrefix(prefix, name)) continue;
        const insert = if (prefix.len > 0 and name.len > prefix.len) name[prefix.len..] else name;
        try appendItem(allocator, list, name, insert, null, "module");
    }
}

const ModuleResolver = @import("module_resolver").ModuleResolver;

pub fn completeAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const ast.Program,
    ctx: *frontend_introspect.Context,
    line: u32,
    column: u32,
) !CompletionResult {
    const line_text = lineAtSource(source, line) orelse return .{
        .start_column = column,
        .end_column = column,
        .items = &.{},
    };

    const col0 = if (column > 0) @min(column - 1, line_text.len) else 0;

    var list = try std.ArrayList(CompletionItem).initCapacity(allocator, 32);
    errdefer list.deinit(allocator);

    var start_col: u32 = @intCast(col0 + 1);
    var end_col: u32 = @intCast(col0 + 1);

    if (importSpanAt(line_text, col0)) |imp| {
        start_col = @intCast(imp.start + 1);
        end_col = @intCast(imp.end + 1);
        try collectImportPaths(allocator, ctx, imp.text, &list);
    } else {
        const span = refSpanAt(line_text, col0);
        start_col = @intCast(span.start + 1);
        end_col = @intCast(span.end + 1);

        if (std.mem.indexOfScalar(u8, span.text, ':')) |colon| {
            const module_slash = span.text[0..colon];
            const event_prefix = span.text[colon + 1 ..];
            try collectEvents(allocator, program, module_slash, event_prefix, &list);
        } else if (span.text.len > 0 and (std.mem.indexOfScalar(u8, span.text, '/') != null or
            std.mem.startsWith(u8, span.text, "std") or
            std.mem.startsWith(u8, span.text, "koru") or
            std.mem.startsWith(u8, span.text, "lib")))
        {
            try collectImportPaths(allocator, ctx, span.text, &list);
        }
    }

    return .{
        .start_column = start_col,
        .end_column = end_col,
        .items = try list.toOwnedSlice(allocator),
    };
}

pub fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return frontend_hover.jsonEscape(allocator, s);
}

pub fn serializeJson(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    result: CompletionResult,
    id: ?i64,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 512);
    errdefer buf.deinit(allocator);

    const file_esc = try jsonEscape(allocator, file_path);
    defer allocator.free(file_esc);

    try buf.appendSlice(allocator, "{\"type\":\"completion\"");
    if (id) |req_id| {
        var id_buf: [32]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&id_buf, ",\"id\":{d}", .{req_id}));
    }
    try buf.appendSlice(allocator, ",\"file\":\"");
    try buf.appendSlice(allocator, file_esc);
    try buf.appendSlice(allocator, "\",\"startColumn\":");
    var num_buf: [16]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{result.start_column}));
    try buf.appendSlice(allocator, ",\"endColumn\":");
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{result.end_column}));
    try buf.appendSlice(allocator, ",\"items\":[");

    for (result.items, 0..) |item, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        const label_esc = try jsonEscape(allocator, item.label);
        defer allocator.free(label_esc);
        const insert_esc = try jsonEscape(allocator, item.insert);
        defer allocator.free(insert_esc);
        const kind_esc = try jsonEscape(allocator, item.kind);
        defer allocator.free(kind_esc);

        try buf.appendSlice(allocator, "{\"label\":\"");
        try buf.appendSlice(allocator, label_esc);
        try buf.appendSlice(allocator, "\",\"insert\":\"");
        try buf.appendSlice(allocator, insert_esc);
        try buf.appendSlice(allocator, "\",\"kind\":\"");
        try buf.appendSlice(allocator, kind_esc);
        try buf.appendSlice(allocator, "\"");

        if (item.detail) |detail| {
            const detail_esc = try jsonEscape(allocator, detail);
            defer allocator.free(detail_esc);
            try buf.appendSlice(allocator, ",\"detail\":\"");
            try buf.appendSlice(allocator, detail_esc);
            try buf.appendSlice(allocator, "\"");
        }

        try buf.appendSlice(allocator, "}");
    }

    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}
