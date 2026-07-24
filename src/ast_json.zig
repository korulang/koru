//! Reflective AST ⇄ JSON round-trip.
//!
//! The frontend dumps the parsed program AST to a JSON file on disk; the
//! metacircular backend reads that file at runtime and reconstructs the typed
//! `ast.Program` onto a heap arena. This replaces the old scheme where the AST
//! was serialized into Zig *source* (`program_ast.zig`) and compiled INTO the
//! backend binary as a `pub const` — which forced a fresh backend binary per
//! program and put the AST in read-only `.rodata` (the Linux SIGSEGV that the
//! heap-clone hack in `context-create` worked around).
//!
//! Both directions are GENERIC over the AST node types via `@typeInfo`, so a
//! new AST field needs zero serializer work — it rides the reflection. The only
//! fields that cannot round-trip are skipped by type:
//!   - `std.mem.Allocator`  (rebuilt from the load arena)
//!   - `*anyopaque` / `?*anyopaque`  (e.g. `type_registry`, reset to its default)

const std = @import("std");
const ast = @import("ast");

pub const Program = ast.Program;

// ── skip predicate ──────────────────────────────────────────────────────────
// Fields whose type carries no serializable data. Reconstructed from context.

fn isAllocator(comptime T: type) bool {
    return T == std.mem.Allocator;
}

fn isOpaquePtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child == anyopaque,
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => |p| p.child == anyopaque,
            else => false,
        },
        else => false,
    };
}

fn isSkipped(comptime T: type) bool {
    return isAllocator(T) or isOpaquePtr(T);
}

// ── serialize ───────────────────────────────────────────────────────────────

pub fn serialize(allocator: std.mem.Allocator, program: *const ast.Program) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try writeValue(ast.Program, program.*, allocator, &buf, false);
    return buf.toOwnedSlice(allocator);
}

/// Canonical serialization: identical to `serialize` but with layout/provenance
/// trivia stripped — `location` (source coordinates) and `indent` (raw source
/// indentation on continuations). Two parses of the same PROGRAM (e.g. the
/// original file and its canonical reprint) compare byte-equal under this dump
/// even though every node's coordinates differ. This is the tree-equality
/// surface for the printer round-trip harness.
pub fn serializeCanon(allocator: std.mem.Allocator, program: *const ast.Program) ![]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try writeValue(ast.Program, program.*, allocator, &buf, true);
    return buf.toOwnedSlice(allocator);
}

/// Trivia fields carry WHERE the source was written, never WHAT the program is.
/// Matched by name: the AST uses `location` (errors.SourceLocation) and `indent`
/// (Continuation) uniformly for these.
fn isTrivia(name: []const u8) bool {
    return std.mem.eql(u8, name, "location") or std.mem.eql(u8, name, "indent");
}

fn writeString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(allocator, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

fn writeValue(comptime T: type, value: T, allocator: std.mem.Allocator, buf: *std.ArrayList(u8), strip_trivia: bool) error{OutOfMemory}!void {
    switch (@typeInfo(T)) {
        .bool => try buf.appendSlice(allocator, if (value) "true" else "false"),
        .int, .comptime_int => try buf.print(allocator, "{d}", .{value}),
        .float, .comptime_float => try buf.print(allocator, "{d}", .{value}),
        .@"enum" => try writeString(buf, allocator, @tagName(value)),
        .void => try buf.appendSlice(allocator, "null"),
        .optional => |o| {
            if (value) |inner| {
                try writeValue(o.child, inner, allocator, buf, strip_trivia);
            } else {
                try buf.appendSlice(allocator, "null");
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    try writeString(buf, allocator, value);
                } else {
                    try buf.append(allocator, '[');
                    for (value, 0..) |item, i| {
                        if (i > 0) try buf.append(allocator, ',');
                        try writeValue(p.child, item, allocator, buf, strip_trivia);
                    }
                    try buf.append(allocator, ']');
                }
            },
            .one => try writeValue(p.child, value.*, allocator, buf, strip_trivia),
            else => @compileError("ast_json: unsupported pointer size on " ++ @typeName(T)),
        },
        .array => |a| {
            try buf.append(allocator, '[');
            for (value, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeValue(a.child, item, allocator, buf, strip_trivia);
            }
            try buf.append(allocator, ']');
        },
        .@"struct" => |s| {
            try buf.append(allocator, '{');
            var first = true;
            inline for (s.fields) |f| {
                if (comptime !isSkipped(f.type)) {
                    if (!(strip_trivia and isTrivia(f.name))) {
                        if (!first) try buf.append(allocator, ',');
                        first = false;
                        try writeString(buf, allocator, f.name);
                        try buf.append(allocator, ':');
                        try writeValue(f.type, @field(value, f.name), allocator, buf, strip_trivia);
                    }
                }
            }
            try buf.append(allocator, '}');
        },
        .@"union" => |u| {
            const tag = std.meta.activeTag(value);
            try buf.append(allocator, '{');
            inline for (u.fields) |f| {
                if (tag == @field(std.meta.Tag(T), f.name)) {
                    try writeString(buf, allocator, f.name);
                    try buf.append(allocator, ':');
                    try writeValue(f.type, @field(value, f.name), allocator, buf, strip_trivia);
                }
            }
            try buf.append(allocator, '}');
        },
        else => @compileError("ast_json: unsupported type " ++ @typeName(T)),
    }
}

// ── deserialize ─────────────────────────────────────────────────────────────

pub const ParseError = error{
    OutOfMemory,
    UnexpectedJsonShape,
    UnknownUnionTag,
    UnknownEnumTag,
    MissingRequiredField,
};

/// Parse JSON bytes into a heap `ast.Program`. Everything reachable is allocated
/// on `allocator` (use an arena and free it wholesale at teardown). The returned
/// Program's `.allocator` is set to `allocator`.
pub fn deserialize(allocator: std.mem.Allocator, json_bytes: []const u8) !ast.Program {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    return readValue(ast.Program, parsed.value, allocator);
}

fn readValue(comptime T: type, jv: std.json.Value, allocator: std.mem.Allocator) ParseError!T {
    switch (@typeInfo(T)) {
        .bool => return switch (jv) {
            .bool => |b| b,
            else => error.UnexpectedJsonShape,
        },
        .int => return switch (jv) {
            .integer => |n| @intCast(n),
            else => error.UnexpectedJsonShape,
        },
        .float => return switch (jv) {
            .float => |x| @floatCast(x),
            .integer => |n| @floatFromInt(n),
            else => error.UnexpectedJsonShape,
        },
        .@"enum" => return switch (jv) {
            .string => |s| std.meta.stringToEnum(T, s) orelse error.UnknownEnumTag,
            else => error.UnexpectedJsonShape,
        },
        .void => return {},
        .optional => |o| {
            if (jv == .null) return null;
            return try readValue(o.child, jv, allocator);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    return switch (jv) {
                        .string => |s| try allocator.dupe(u8, s),
                        else => error.UnexpectedJsonShape,
                    };
                }
                const arr = switch (jv) {
                    .array => |a| a,
                    else => return error.UnexpectedJsonShape,
                };
                const out = try allocator.alloc(p.child, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    out[i] = try readValue(p.child, item, allocator);
                }
                return out;
            },
            .one => {
                const ptr = try allocator.create(p.child);
                ptr.* = try readValue(p.child, jv, allocator);
                return ptr;
            },
            else => @compileError("ast_json: unsupported pointer size on " ++ @typeName(T)),
        },
        .array => |a| {
            const arr = switch (jv) {
                .array => |x| x,
                else => return error.UnexpectedJsonShape,
            };
            var out: T = undefined;
            for (0..a.len) |i| {
                out[i] = try readValue(a.child, arr.items[i], allocator);
            }
            return out;
        },
        .@"struct" => |s| {
            const obj = switch (jv) {
                .object => |o| o,
                else => return error.UnexpectedJsonShape,
            };
            var result: T = undefined;
            inline for (s.fields) |f| {
                if (comptime isAllocator(f.type)) {
                    @field(result, f.name) = allocator;
                } else if (comptime isSkipped(f.type)) {
                    @field(result, f.name) = comptime fieldDefault(f);
                } else if (obj.get(f.name)) |fv| {
                    @field(result, f.name) = try readValue(f.type, fv, allocator);
                } else if (comptime f.defaultValue()) |dv| {
                    @field(result, f.name) = dv;
                } else {
                    return error.MissingRequiredField;
                }
            }
            return result;
        },
        .@"union" => |u| {
            const obj = switch (jv) {
                .object => |o| o,
                else => return error.UnexpectedJsonShape,
            };
            if (obj.count() != 1) return error.UnexpectedJsonShape;
            const key = obj.keys()[0];
            inline for (u.fields) |f| {
                if (std.mem.eql(u8, key, f.name)) {
                    const fv = obj.get(f.name).?;
                    return @unionInit(T, f.name, try readValue(f.type, fv, allocator));
                }
            }
            return error.UnknownUnionTag;
        },
        else => @compileError("ast_json: unsupported type " ++ @typeName(T)),
    }
}

fn fieldDefault(comptime f: std.builtin.Type.StructField) f.type {
    return f.defaultValue() orelse @compileError("ast_json: skipped field " ++ f.name ++ " has no default");
}

// ── tests ───────────────────────────────────────────────────────────────────

test "round-trip: minimal Program with one host_line" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = try a.alloc(ast.Item, 1);
    items[0] = .{ .host_line = .{ .content = try a.dupe(u8, "const x = 42;") } };

    const program = ast.Program{
        .items = items,
        .main_module_name = try a.dupe(u8, "input"),
        .allocator = a,
    };

    const json = try serialize(allocator, &program);
    defer allocator.free(json);

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const back = try deserialize(arena2.allocator(), json);

    try std.testing.expectEqual(@as(usize, 1), back.items.len);
    try std.testing.expect(back.items[0] == .host_line);
    try std.testing.expectEqualStrings("const x = 42;", back.items[0].host_line.content);
    try std.testing.expectEqualStrings("input", back.main_module_name);

    // Re-serialize and assert byte-stable round-trip.
    const json2 = try serialize(allocator, &back);
    defer allocator.free(json2);
    try std.testing.expectEqualStrings(json, json2);
}

test "round-trip: parsed program (event + branches + proc + host lines)" {
    const Parser = @import("parser").Parser;
    const allocator = std.testing.allocator;

    const source =
        \\const std = @import("std");
        \\
        \\~tor hello {}
        \\| done
        \\| err string
        \\
        \\const x = 42;
        \\
        \\~proc hello {
        \\    log.debug("Hello!\n", .{});
        \\    return .{ .done = {} };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();
    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // Serialize the freshly-parsed AST.
    const json = try serialize(allocator, &parse_result.source_file);
    defer allocator.free(json);

    // Reconstruct onto an arena, then re-serialize. A byte-stable second pass
    // proves every field survived the round-trip (read → identical write).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const back = try deserialize(arena.allocator(), json);

    const json2 = try serialize(allocator, &back);
    defer allocator.free(json2);

    try std.testing.expectEqualStrings(json, json2);

    // Spot-check structure survived.
    try std.testing.expectEqualStrings(parse_result.source_file.main_module_name, back.main_module_name);
    try std.testing.expectEqual(parse_result.source_file.items.len, back.items.len);
}
