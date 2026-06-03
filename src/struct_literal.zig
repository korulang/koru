// Koru struct-literal → liquid record tree.
// ==========================================
//
// A small parser that projects a Koru struct literal — `{ name: expr, ... }`
// (named) or `{ a, b }` (positional) — into a `liquid.Value` record node, the
// universal walkable shape the template engine consumes. One entry in the
// "parser palette" (docs/PARSER_PALETTE.md): the smartness lives here in Zig
// with real errors; a per-target walker template emits the result (Zig
// `.{ .name = expr }`, JS `{ name: expr }`, …).
//
// This is the foundation for the capture rework: `captured({...})` lowers to a
// general `.assignment`, and the opaque `{...}` is interpreted by the walker
// over THIS record — no koruStructToZig text surgery, no `.capture` node.
//
// Field VALUES are kept as opaque raw text (Model A — pasted verbatim per
// target); only the STRUCTURE (field order + names) is parsed out. Nested
// struct values pass through untouched for now (no field-value recursion).
//
// Node shapes (every node is a `record` Context with a `kind` field):
//   struct → kind="struct", children = array of field records
//   field  → kind="field",  name = "<ident>" | "" (empty ⇒ positional),
//                           value = raw expression text (trimmed)

const std = @import("std");
const liquid = @import("liquid");
const Allocator = std.mem.Allocator;
const Value = liquid.Value;
const Context = liquid.Context;

pub const ParseError = error{
    OutOfMemory,
    NotAStruct,
    UnterminatedStruct,
};

/// Split a struct-literal body on TOP-LEVEL commas, honoring `{}`/`()`/`[]`
/// nesting and skipping string-literal contents. Returns the raw (untrimmed)
/// field slices. `body` is the text strictly between the outer `{` and `}`.
fn splitFields(allocator: Allocator, body: []const u8) ParseError![]const []const u8 {
    var fields = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var depth: usize = 0;
    var field_start: usize = 0;
    var i: usize = 0;

    while (i < body.len) : (i += 1) {
        const c = body[i];
        switch (c) {
            '"' => {
                // Skip a string literal whole (escapes preserved).
                i += 1;
                while (i < body.len and body[i] != '"') : (i += 1) {
                    if (body[i] == '\\' and i + 1 < body.len) i += 1;
                }
            },
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => {
                if (depth == 0) return error.UnterminatedStruct;
                depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    try fields.append(allocator, body[field_start..i]);
                    field_start = i + 1;
                    continue;
                }
            },
            else => {},
        }
    }
    if (depth != 0) return error.UnterminatedStruct;

    // Trailing field (or the sole field). An all-whitespace tail with no prior
    // content means an empty struct `{}` → no fields.
    const tail = body[field_start..];
    if (std.mem.trim(u8, tail, " \t\n\r").len > 0 or fields.items.len > 0) {
        try fields.append(allocator, tail);
    }
    return fields.toOwnedSlice(allocator);
}

/// Find the first TOP-LEVEL `:` in `field`, honoring nesting and strings.
/// Returns its index, or null if the field is positional (no top-level colon).
fn topLevelColon(field: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < field.len) : (i += 1) {
        const c = field[i];
        switch (c) {
            '"' => {
                i += 1;
                while (i < field.len and field[i] != '"') : (i += 1) {
                    if (field[i] == '\\' and i + 1 < field.len) i += 1;
                }
            },
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => if (depth > 0) {
                depth -= 1;
            },
            ':' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

/// Parse a Koru struct literal into a liquid record tree. All nodes are
/// allocated with `allocator`; use an arena so the tree frees in one shot.
pub fn parse(allocator: Allocator, input: []const u8) ParseError!Value {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return error.NotAStruct;
    }
    const body = trimmed[1 .. trimmed.len - 1];

    const raw_fields = try splitFields(allocator, body);

    var children = try std.ArrayList(*Context).initCapacity(allocator, raw_fields.len);
    for (raw_fields) |raw| {
        const field_node = try allocator.create(Context);
        field_node.* = Context.init(allocator);
        try field_node.put("kind", .{ .string = "field" });

        if (topLevelColon(raw)) |colon| {
            const name = std.mem.trim(u8, raw[0..colon], " \t\n\r");
            const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r");
            try field_node.put("name", .{ .string = name });
            try field_node.put("value", .{ .string = value });
        } else {
            // Positional: empty name (falsy in the walker), value is the whole field.
            const value = std.mem.trim(u8, raw, " \t\n\r");
            try field_node.put("name", .{ .string = "" });
            try field_node.put("value", .{ .string = value });
        }
        try children.append(allocator, field_node);
    }

    const node = try allocator.create(Context);
    node.* = Context.init(allocator);
    try node.put("kind", .{ .string = "struct" });
    try node.put("children", .{ .array = try children.toOwnedSlice(allocator) });
    return Value{ .record = node };
}

/// A parsed struct-literal field: a name (empty ⇒ positional) and its raw value
/// expression text. The typed counterpart to the `.record` walk, for Zig-side
/// consumers (the capture transform) that want field pairs directly rather than
/// walking a liquid record by string key.
pub const StructField = struct {
    /// Field name, or "" for a positional field (`{ a, b }`).
    name: []const u8,
    /// Raw value expression text, trimmed (opaque — per-target paste).
    value: []const u8,
};

/// Parse a Koru struct literal into ordered (name, value) field pairs. Same
/// parser as `parse` (single source of struct-splitting truth), but returns a
/// Zig slice instead of a liquid record. Positional fields carry `name = ""`.
pub fn parseFields(allocator: Allocator, input: []const u8) ParseError![]const StructField {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return error.NotAStruct;
    }
    const raw_fields = try splitFields(allocator, trimmed[1 .. trimmed.len - 1]);

    var out = try std.ArrayList(StructField).initCapacity(allocator, raw_fields.len);
    for (raw_fields) |raw| {
        if (topLevelColon(raw)) |colon| {
            try out.append(allocator, .{
                .name = std.mem.trim(u8, raw[0..colon], " \t\n\r"),
                .value = std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r"),
            });
        } else {
            try out.append(allocator, .{
                .name = "",
                .value = std.mem.trim(u8, raw, " \t\n\r"),
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Filter adapter matching `liquid.Filter`: `parse_struct(text)`.
pub fn filter(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    return parse(allocator, args[0].string);
}

// --- Tests: parse a Koru struct, then walk it with the template engine ---

test "parse + walk a named struct literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_struct", filter);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("src", .{ .string = "{ sum: acc.sum + @as(i64, item), count: acc.count + 1 }" });

    // Emit Zig anonymous-struct syntax: `.{ .name = value, ... }`.
    const tmpl = "{% const s = parse_struct(src) %}" ++
        ".{ {% for f in s.children %}.{{ f.name }} = {{ f.value }}, {% endfor %}}";

    const result = try liquid.renderWithEnv(allocator, tmpl, &ctx, null, .{ .filters = &filters });
    try std.testing.expectEqualStrings(
        ".{ .sum = acc.sum + @as(i64, item), .count = acc.count + 1, }",
        result,
    );
}

test "positional struct literal yields empty (falsy) names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_struct", filter);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("src", .{ .string = "{ acc.sum, acc.count }" });

    // The walker branches on `f.name`: present ⇒ named, empty ⇒ positional.
    const tmpl = "{% const s = parse_struct(src) %}" ++
        "{% for f in s.children %}{% if f.name %}NAMED:{{ f.name }}{% else %}POS:{{ f.value }}{% endif %} {% endfor %}";

    const result = try liquid.renderWithEnv(allocator, tmpl, &ctx, null, .{ .filters = &filters });
    try std.testing.expectEqualStrings("POS:acc.sum POS:acc.count ", result);
}

test "value with nested parens does not split on inner commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = try parse(allocator, "{ x: @divTrunc(a, b), y: 1 }");
    const node = v.record;
    const children = node.get("children").?.array;
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings("x", children[0].get("name").?.string);
    try std.testing.expectEqualStrings("@divTrunc(a, b)", children[0].get("value").?.string);
    try std.testing.expectEqualStrings("y", children[1].get("name").?.string);
    try std.testing.expectEqualStrings("1", children[1].get("value").?.string);
}

test "parseFields: named + positional pairs (typed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const named = try parseFields(allocator, "{ sum: acc.sum + @as(i64, item), count: acc.count + 1 }");
    try std.testing.expectEqual(@as(usize, 2), named.len);
    try std.testing.expectEqualStrings("sum", named[0].name);
    try std.testing.expectEqualStrings("acc.sum + @as(i64, item)", named[0].value);
    try std.testing.expectEqualStrings("count", named[1].name);
    try std.testing.expectEqualStrings("acc.count + 1", named[1].value);

    const positional = try parseFields(allocator, "{ acc.sum, acc.count }");
    try std.testing.expectEqual(@as(usize, 2), positional.len);
    try std.testing.expectEqualStrings("", positional[0].name);
    try std.testing.expectEqualStrings("acc.sum", positional[0].value);
    try std.testing.expectEqualStrings("", positional[1].name);
    try std.testing.expectEqualStrings("acc.count", positional[1].value);
}

test "empty struct literal yields no fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = try parse(allocator, "{}");
    try std.testing.expectEqual(@as(usize, 0), v.record.get("children").?.array.len);
}
