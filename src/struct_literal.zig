// Koru struct-literal → liquid record tree.
// ==========================================
//
// A small parser that projects a Koru struct literal — `{ name: expr, ... }`
// or bare puns `{ a, b }` / `{ p.x, p.y }` — into a `liquid.Value` record node,
// the universal walkable shape the template engine consumes. One entry in the
// "parser palette" (docs/PARSER_PALETTE.md): the smartness lives here in Zig
// with real errors; a per-target walker template emits the result (Zig
// `.{ .name = expr }`, JS `{ name: expr }`, …).
//
// LAW (nothing is positional; punning is mandatory):
//   - Bare entry `label` / `acc.sum` → pun by last segment (name = label / sum).
//   - Bare expression `a.x + 1` → REJECT (name the target: `x: expr`).
//   - Redundant `x: x` / `sum: acc.sum` → REJECT (write the pun).
// Positional assignment is never allowed. The one carve-out is a SINGLETON
// bare non-punnable expression under `allow_singleton_expression` — capture's
// existing-value seed (`capture { entity }` / `capture { expr }`).
//
// Field VALUES are kept as opaque raw text (Model A — pasted verbatim per
// target); only the STRUCTURE (field order + names) is parsed out. Nested
// struct values pass through untouched for now (no field-value recursion).
//
// Node shapes (every node is a `record` Context with a `kind` field):
//   struct → kind="struct", children = array of field records
//   field  → kind="field",  name = "<ident>", value = raw expression text
//            (name is "" ONLY for the singleton-expression carve-out)

const std = @import("std");
const liquid = @import("liquid");
const Allocator = std.mem.Allocator;
const Value = liquid.Value;
const Context = liquid.Context;

pub const ParseError = error{
    OutOfMemory,
    NotAStruct,
    UnterminatedStruct,
    BareEntryNotPunnable,
    RedundantExplicitLabel,
};

/// Options for `parseFields` / `parse`. Defaults enforce the pun law.
pub const ParseOptions = struct {
    /// Allow a single bare non-punnable entry (capture's existing-expression
    /// seed: `capture { entity }`). Write blocks (`captured`, `insert`,
    /// `stored`) leave this false so a lone bare expression is rejected.
    allow_singleton_expression: bool = false,
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

    // Trailing field (or the sole field). A whitespace-only tail is a trailing
    // comma, not a field — `{ a: T, }` is the same record as `{ a: T }`.
    // Appending the empty slice made projectRawFields refuse BareEntryNotPunnable,
    // so writeBareReturnType fell back to pasting the record verbatim and `string`
    // never lowered (020_063, Ward's info tor).
    const tail = body[field_start..];
    if (std.mem.trim(u8, tail, " \t\n\r").len > 0) {
        try fields.append(allocator, tail);
    }
    return fields.toOwnedSlice(allocator);
}

/// Find the first TOP-LEVEL `:` in `field`, honoring nesting and strings.
/// Returns its index, or null if the field is bare (no top-level colon).
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

/// The field name a value would pun to — the segment after the last `.`, or
/// the whole token when there's no dot — or `null` when the value CANNOT pun.
/// Mirrors `lexer.punnableName` (kept local so this module stays free of a
/// lexer import; the two must stay in lockstep).
pub fn punnableName(value: []const u8) ?[]const u8 {
    if (value.len == 0) return null;
    for (value) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => {},
            else => return null,
        }
    }
    if (std.mem.indexOf(u8, value, "..") != null) return null;
    if (value[0] == '.' or value[value.len - 1] == '.') return null;
    if (value[0] >= '0' and value[0] <= '9') return null;

    return if (std.mem.lastIndexOfScalar(u8, value, '.')) |dot_idx|
        value[dot_idx + 1 ..]
    else
        value;
}

fn projectRawFields(
    allocator: Allocator,
    raw_fields: []const []const u8,
    opts: ParseOptions,
) ParseError![]const StructField {
    var out = try std.ArrayList(StructField).initCapacity(allocator, raw_fields.len);
    for (raw_fields) |raw| {
        if (topLevelColon(raw)) |colon| {
            const name = std.mem.trim(u8, raw[0..colon], " \t\n\r");
            const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r");
            if (punnableName(value)) |punned| {
                if (std.mem.eql(u8, punned, name)) return error.RedundantExplicitLabel;
            }
            try out.append(allocator, .{ .name = name, .value = value });
        } else {
            const value = std.mem.trim(u8, raw, " \t\n\r");
            if (punnableName(value)) |punned| {
                try out.append(allocator, .{ .name = punned, .value = value });
            } else if (opts.allow_singleton_expression and raw_fields.len == 1) {
                // Capture existing-expression seed: `capture { entity }` /
                // `capture { expr }` — not a field write.
                try out.append(allocator, .{ .name = "", .value = value });
            } else {
                return error.BareEntryNotPunnable;
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Parse a Koru struct literal into a liquid record tree. All nodes are
/// allocated with `allocator`; use an arena so the tree frees in one shot.
pub fn parse(allocator: Allocator, input: []const u8) ParseError!Value {
    return parseWithOptions(allocator, input, .{});
}

pub fn parseWithOptions(allocator: Allocator, input: []const u8, opts: ParseOptions) ParseError!Value {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return error.NotAStruct;
    }
    const body = trimmed[1 .. trimmed.len - 1];
    const raw_fields = try splitFields(allocator, body);
    const fields = try projectRawFields(allocator, raw_fields, opts);

    var children = try std.ArrayList(*Context).initCapacity(allocator, fields.len);
    for (fields) |f| {
        const field_node = try allocator.create(Context);
        field_node.* = Context.init(allocator);
        try field_node.put("kind", .{ .string = "field" });
        try field_node.put("name", .{ .string = f.name });
        try field_node.put("value", .{ .string = f.value });
        try children.append(allocator, field_node);
    }

    const node = try allocator.create(Context);
    node.* = Context.init(allocator);
    try node.put("kind", .{ .string = "struct" });
    try node.put("children", .{ .array = try children.toOwnedSlice(allocator) });
    return Value{ .record = node };
}

/// A parsed struct-literal field: a resolved name and its raw value expression
/// text. Bare puns are resolved (name = last path segment); the empty-name
/// carve-out is only the singleton existing-expression seed.
pub const StructField = struct {
    /// Field name (last-segment pun for bare entries). Empty only for the
    /// singleton-expression carve-out (`allow_singleton_expression`).
    name: []const u8,
    /// Raw value expression text, trimmed (opaque — per-target paste).
    value: []const u8,
};

/// Teaching diagnostic for a `ParseError` from the pun law.
pub fn describeError(err: ParseError) []const u8 {
    return switch (err) {
        error.BareEntryNotPunnable => "positional assignment is never allowed — name the target (`x: expr`); a bare entry must be a punnable name or path",
        error.RedundantExplicitLabel => "punning is mandatory — drop the redundant label and write the bare pun",
        error.NotAStruct => "not a struct literal",
        error.UnterminatedStruct => "unterminated struct literal",
        error.OutOfMemory => "out of memory",
    };
}

/// Recognized Koru-native base types for the `value[type]` annotation.
/// A closed allowlist on purpose: it is what keeps `acc.arr[i]` (indexing)
/// and `[1, 2, 3]` (array literals) untouched by peelBaseType.
pub fn isBaseType(s: []const u8) bool {
    const types = [_][]const u8{
        "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
        "usize", "isize", "f16", "f32", "f64", "bool",
    };
    for (types) |t| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

/// Peel an OPTIONAL Koru-native base-type annotation `value[type]` off a field
/// value: `10[i32]` → `{ .value = "10", .type = "i32" }`. Strings and bare
/// numbers carry no annotation (type ""), since a string literal IS its type
/// and a bare number takes the target default. Only a recognized base type
/// counts (see isBaseType). THE single parser for the annotation — `const`'s
/// parse_fields filter (template_processor) and `capture`'s seed builder
/// (koru_std/control.kz) both call THIS, so their lowerings cannot drift.
pub fn peelBaseType(field_value: []const u8) struct { value: []const u8, type: []const u8 } {
    if (field_value.len < 3 or field_value[field_value.len - 1] != ']') return .{ .value = field_value, .type = "" };
    const lb = std.mem.lastIndexOfScalar(u8, field_value, '[') orelse return .{ .value = field_value, .type = "" };
    const inner = field_value[lb + 1 .. field_value.len - 1];
    const prefix = std.mem.trim(u8, field_value[0..lb], " \t");
    if (prefix.len == 0 or !isBaseType(inner)) return .{ .value = field_value, .type = "" };
    return .{ .value = prefix, .type = inner };
}

/// Parse a Koru struct literal into ordered (name, value) field pairs. Bare
/// entries are resolved to puns; bare expressions and redundant labels error.
pub fn parseFields(allocator: Allocator, input: []const u8) ParseError![]const StructField {
    return parseFieldsWithOptions(allocator, input, .{});
}

pub fn parseFieldsWithOptions(allocator: Allocator, input: []const u8, opts: ParseOptions) ParseError![]const StructField {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return error.NotAStruct;
    }
    const raw_fields = try splitFields(allocator, trimmed[1 .. trimmed.len - 1]);
    return projectRawFields(allocator, raw_fields, opts);
}

// --- Classification predicates: "what kind of `{ ... }` is this?" -----------
// Single source of truth shared by the parser (to classify a `-> { ... }`
// produce body structurally instead of as raw host code) and every emitter
// (to lower a record literal per target). Kept here beside the struct parser
// so the answer to "is this a Koru record literal" lives in one place.

fn isIdentStartChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStartChar(c) or (c >= '0' and c <= '9');
}

/// `{ name: value, ... }` — a named-field record literal (has `ident :`).
pub fn isKoruStructLiteral(value: []const u8) bool {
    if (value.len < 2) return false;
    if (value[0] != '{' or value[value.len - 1] != '}') return false;

    const inner = value[1 .. value.len - 1];
    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;
        if (isIdentStartChar(inner[i])) {
            var j = i + 1;
            while (j < inner.len and isIdentChar(inner[j])) : (j += 1) {}
            while (j < inner.len and (inner[j] == ' ' or inner[j] == '\t')) : (j += 1) {}
            if (j < inner.len and inner[j] == ':') return true;
        }
        i += 1;
    }
    return false;
}

/// `{ i64 }` / `{ 0[i64] }` / `{ *mod:Type<state!> }` — a ONE-slot block whose
/// single entry carries no `name:` label. The identity form: one thing, unnamed.
///
/// Distinct from `isKoruStructLiteral`, which scans for `ident :` ANYWHERE and so
/// reports true for `{ *koru/curl:Pending<open!> }` on the strength of `curl:`.
/// A field label is not "a colon somewhere" — it is a colon immediately after the
/// entry's LEADING identifier, so this check is anchored rather than searching.
///
/// Punnability is deliberately not consulted. `{ i64 }` puns to a column called
/// `i64` under the ordinary pun law, which is exactly the reading a one-column
/// store must not take; what decides the shape here is whether a name was
/// WRITTEN, not whether the text could serve as one.
pub fn isIdentityBlock(value: []const u8) bool {
    if (value.len < 2) return false;
    if (value[0] != '{' or value[value.len - 1] != '}') return false;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t\n\r");
    if (inner.len == 0) return false;

    // More than one top-level entry is a field list, whatever it is labelled.
    var depth: i32 = 0;
    var k: usize = 0;
    while (k < inner.len) : (k += 1) {
        switch (inner[k]) {
            '"' => {
                k += 1;
                while (k < inner.len and inner[k] != '"') : (k += 1) {
                    if (inner[k] == '\\') k += 1;
                }
            },
            '{', '(', '[', '<' => depth += 1,
            '}', ')', ']', '>' => depth -= 1,
            ',' => if (depth == 0) return false,
            else => {},
        }
    }

    // A leading `name:` makes it a named field, not the identity form.
    if (isIdentStartChar(inner[0])) {
        var j: usize = 1;
        while (j < inner.len and isIdentChar(inner[j])) : (j += 1) {}
        while (j < inner.len and (inner[j] == ' ' or inner[j] == '\t')) : (j += 1) {}
        if (j < inner.len and inner[j] == ':') return false;
    }
    return true;
}

/// `{ p.x, p.y }` field-punning shorthand — no `field:` labels, dot paths only.
pub fn isFieldPunningLiteral(value: []const u8) bool {
    if (value.len < 2) return false;
    if (value[0] != '{' or value[value.len - 1] != '}') return false;
    if (isKoruStructLiteral(value)) return false;

    const inner = value[1 .. value.len - 1];
    var depth: i32 = 0;
    var has_dot_at_depth_0 = false;
    var has_comma_at_depth_0 = false;
    var has_operator_at_depth_0 = false;
    for (inner) |c| {
        switch (c) {
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => depth -= 1,
            ':', '=' => if (depth == 0) return false,
            '.' => if (depth == 0) {
                has_dot_at_depth_0 = true;
            },
            ',' => if (depth == 0) {
                has_comma_at_depth_0 = true;
            },
            '+', '-', '*', '/' => if (depth == 0) {
                has_operator_at_depth_0 = true;
            },
            else => {},
        }
    }
    if (has_dot_at_depth_0 and !has_operator_at_depth_0) return true;
    if (has_comma_at_depth_0) return true;
    return false;
}

/// `{ expr }` plain-value braces from branch/bare-return constructors — not a
/// Zig block, not a record. The residual `{ ... }` shape once the two record
/// kinds above are ruled out.
pub fn isBracedPlainExpression(value: []const u8) bool {
    if (value.len < 2) return false;
    if (value[0] != '{' or value[value.len - 1] != '}') return false;
    if (isKoruStructLiteral(value)) return false;
    if (isFieldPunningLiteral(value)) return false;
    return true;
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

test "bare path entries pun by last segment (not positional)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_struct", filter);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("src", .{ .string = "{ acc.sum, acc.count }" });

    const tmpl = "{% const s = parse_struct(src) %}" ++
        "{% for f in s.children %}{{ f.name }}={{ f.value }} {% endfor %}";

    const result = try liquid.renderWithEnv(allocator, tmpl, &ctx, null, .{ .filters = &filters });
    try std.testing.expectEqualStrings("sum=acc.sum count=acc.count ", result);
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

test "parseFields: named + bare puns; reject bare expression and redundant label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const named = try parseFields(allocator, "{ sum: acc.sum + @as(i64, item), count: acc.count + 1 }");
    try std.testing.expectEqual(@as(usize, 2), named.len);
    try std.testing.expectEqualStrings("sum", named[0].name);
    try std.testing.expectEqualStrings("acc.sum + @as(i64, item)", named[0].value);
    try std.testing.expectEqualStrings("count", named[1].name);
    try std.testing.expectEqualStrings("acc.count + 1", named[1].value);

    const punned = try parseFields(allocator, "{ acc.sum, acc.count }");
    try std.testing.expectEqual(@as(usize, 2), punned.len);
    try std.testing.expectEqualStrings("sum", punned[0].name);
    try std.testing.expectEqualStrings("acc.sum", punned[0].value);
    try std.testing.expectEqualStrings("count", punned[1].name);
    try std.testing.expectEqualStrings("acc.count", punned[1].value);

    // Reordered bare paths still land by NAME, not index.
    const reordered = try parseFields(allocator, "{ acc.count, acc.sum }");
    try std.testing.expectEqualStrings("count", reordered[0].name);
    try std.testing.expectEqualStrings("sum", reordered[1].name);

    try std.testing.expectError(error.BareEntryNotPunnable, parseFields(allocator, "{ a.x + 1, a.y + 100 }"));
    try std.testing.expectError(error.RedundantExplicitLabel, parseFields(allocator, "{ label: label }"));
    try std.testing.expectError(error.RedundantExplicitLabel, parseFields(allocator, "{ sum: acc.sum }"));

    // Bare punnable singleton always puns (name == value → capture existing-var).
    const alone = try parseFields(allocator, "{ entity }");
    try std.testing.expectEqualStrings("entity", alone[0].name);
    try std.testing.expectEqualStrings("entity", alone[0].value);

    // Singleton non-punnable expression: only with the capture-seed carve-out.
    try std.testing.expectError(error.BareEntryNotPunnable, parseFields(allocator, "{ a + 1 }"));
    const seed = try parseFieldsWithOptions(allocator, "{ a + 1 }", .{ .allow_singleton_expression = true });
    try std.testing.expectEqual(@as(usize, 1), seed.len);
    try std.testing.expectEqualStrings("", seed[0].name);
    try std.testing.expectEqualStrings("a + 1", seed[0].value);
}

test "empty struct literal yields no fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = try parse(allocator, "{}");
    try std.testing.expectEqual(@as(usize, 0), v.record.get("children").?.array.len);
}
