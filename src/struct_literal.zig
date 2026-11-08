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
    MissingComma,
    FusedStatement,
    DuplicateField,
    NamelessField,
    TypelessField,
};

/// Options for `parseFields` / `parse`. Defaults enforce the pun law.
pub const ParseOptions = struct {
    /// Allow a single bare non-punnable entry (capture's existing-expression
    /// seed: `capture { entity }`). Write blocks (`captured`, `insert`,
    /// `stored`) leave this false so a lone bare expression is rejected.
    allow_singleton_expression: bool = false,
};

/// `//`-to-EOL comments are transparent inside a struct literal — a trailing
/// comment must never reach the field scanner, where it fuses with the next
/// field's name (`score: i64, // note` then `lives:` parses one field named
/// `note\nlives` and the emitted Zig eats the comma). A `//` inside a string
/// literal is content, so the strip honors `"` … `"` with `\` escapes.
/// Comment bytes collapse to a single space so tokens never fuse across the
/// removal.
fn stripLineComments(allocator: Allocator, text: []const u8) ParseError![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '"') {
            try out.append(allocator, c);
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                try out.append(allocator, text[i]);
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 1;
                    try out.append(allocator, text[i]);
                }
            }
            if (i < text.len) {
                try out.append(allocator, text[i]);
                i += 1;
            }
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            try out.append(allocator, ' ');
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Split a struct-literal body on TOP-LEVEL commas, honoring `{}`/`()`/`[]`
/// nesting and skipping string-literal contents. Returns the raw (untrimmed)
/// field slices. `body` is the text strictly between the outer `{` and `}`.
fn splitFields(allocator: Allocator, body: []const u8) ParseError![]const []const u8 {
    const clean = try stripLineComments(allocator, body);
    var fields = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var depth: usize = 0;
    var field_start: usize = 0;
    var i: usize = 0;

    while (i < clean.len) : (i += 1) {
        const c = clean[i];
        switch (c) {
            '"' => {
                // Skip a string literal whole (escapes preserved).
                i += 1;
                while (i < clean.len and clean[i] != '"') : (i += 1) {
                    if (clean[i] == '\\' and i + 1 < clean.len) i += 1;
                }
            },
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => {
                if (depth == 0) return error.UnterminatedStruct;
                depth -= 1;
            },
            ',' => {
                if (depth == 0) {
                    try fields.append(allocator, clean[field_start..i]);
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
    const tail = clean[field_start..];
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

/// A top-level newline inside a field's VALUE followed by `ident :` is a
/// second field fused to this one for want of a comma — `a: T` then `b: U`
/// written on separate lines with no comma between splits as ONE field whose
/// value is `T\nb: U`, which downstream surfaces report as a bogus type.
/// Returns the fused line's text (`b: U`) when found, null otherwise.
///
/// Whitespace-anchored: `ident:` at depth 0 cannot appear in a value
/// expression (Koru has no labels or ternaries in expression position, and
/// no attested literal carries `<value> <ident>:` mid-line — `std/io:print`
/// is `/`-separated, `mod:Type` sits at value start), so whitespace followed
/// by `ident:` at depth 0 is always a second field that lost its comma —
/// UNLESS the whitespace follows a type prefix: in `*const mod:Type`,
/// `[]const mod:Type`, `?mod:Type`, `[N] mod:Type` the qualifier is part of
/// the field's own type, and the token before the space is the tell
/// (420_010: `[]const threading:WorkerHandle`). The tell is a PREFIX token:
/// `const`-ending (`[]const`, `*const`), bracket-OPENED (`[]`, `[N]`), or a
/// bare `*`/`?`/`?*`. A `]`-closed run that starts with a name or digit is
/// not a prefix — `xs[i]` is indexing and `0[i64]` is a value's `[T]`
/// annotation, so `0[i64] extra: 0` still reads as a fused field; likewise a
/// `*`- or `?`-ending expression tail (`p.*`, `x?`) is a value, and the
/// exemption holds only for the bare prefix tokens.
///
/// The fused head is not only `name:` — a write-path head carries dots and
/// indices (`acc.m:`, `board[i].on:` in `store:stored`/`grid:stored` blocks),
/// so `head` here is `ident ('.' ident | '[' balanced ']')* ':'`.
pub fn fusedFieldLine(value: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '"' => {
                i += 1;
                while (i < value.len and value[i] != '"') : (i += 1) {
                    if (value[i] == '\\' and i + 1 < value.len) i += 1;
                }
            },
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => if (depth > 0) {
                depth -= 1;
            },
            ' ', '\t', '\r', '\n' => if (depth == 0) {
                var t = i;
                while (t > 0 and !std.ascii.isWhitespace(value[t - 1])) : (t -= 1) {}
                const prev_tok = value[t..i];
                // `prev_tok` is one non-whitespace run. A TYPE-PREFIX token —
                // `const`-suffixed, `[`-opened, or a bare `*`/`?`/`?*` —
                // means the `ident:` ahead is a module qualifier inside this
                // field's own type, not a second field boundary.
                const type_prefix = prev_tok.len > 0 and
                    ((std.mem.endsWith(u8, prev_tok, "const") and
                        (prev_tok.len == 5 or !isIdentChar(prev_tok[prev_tok.len - 6]))) or
                        prev_tok[0] == '[' or
                        std.mem.eql(u8, prev_tok, "*") or
                        std.mem.eql(u8, prev_tok, "?") or
                        std.mem.eql(u8, prev_tok, "?*"));
                if (!type_prefix) {
                    var j = i + 1;
                    while (j < value.len and (value[j] == ' ' or value[j] == '\t' or value[j] == '\r' or value[j] == '\n')) : (j += 1) {}
                    if (j < value.len and isIdentStartChar(value[j])) {
                        var k = j + 1;
                        while (k < value.len and isIdentChar(value[k])) : (k += 1) {}
                        // `.field` / `[index]` segments of a write head.
                        while (k < value.len) {
                            if (value[k] == '.') {
                                if (k + 1 < value.len and isIdentStartChar(value[k + 1])) {
                                    k += 1;
                                    while (k < value.len and isIdentChar(value[k])) : (k += 1) {}
                                    continue;
                                }
                                break;
                            }
                            if (value[k] == '[') {
                                var bd: usize = 1;
                                k += 1;
                                while (k < value.len and bd > 0) : (k += 1) {
                                    if (value[k] == '[') bd += 1;
                                    if (value[k] == ']') bd -= 1;
                                }
                                continue;
                            }
                            break;
                        }
                        while (k < value.len and (value[k] == ' ' or value[k] == '\t')) : (k += 1) {}
                        if (k < value.len and value[k] == ':') {
                            var e = k + 1;
                            while (e < value.len and value[e] != '\n') : (e += 1) {}
                            return std.mem.trim(u8, value[j..e], " \t\r");
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// A top-level newline inside a field's VALUE followed by a statement head —
/// `!` (watch/effect), `|` or `|>` (branch/continuation), `~` (tor), `=>`
/// (branch result), or `#` (label) — is a tor line fused into the field for
/// want of a boundary, not expression continuation. The composition fuzzer
/// proved the shape compiles green while the emitted Zig carries the Koru
/// line verbatim (`acc.n = acc.n + 1\n! row e |> ...` fails `zig ast-check`),
/// so this must refuse at parse, not reach emission. Continuation lines of
/// real expressions start with operators (`+ @min(...)`) or operands, never
/// with a statement head. Returns the fused line's text when found, else null.
///
/// `!=` is not a head (comparison could wrap onto it), so `!` requires the
/// next byte be neither `=` nor ident-joined; `|` excludes `||` and `|=`.
fn fusedStatementLine(value: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '"' => {
                i += 1;
                while (i < value.len and value[i] != '"') : (i += 1) {
                    if (value[i] == '\\' and i + 1 < value.len) i += 1;
                }
            },
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => if (depth > 0) {
                depth -= 1;
            },
            '\n' => if (depth == 0) {
                var j = i + 1;
                while (j < value.len and (value[j] == ' ' or value[j] == '\t' or value[j] == '\r')) : (j += 1) {}
                if (j >= value.len) continue;
                const head = switch (value[j]) {
                    '!' => j + 1 >= value.len or
                        (value[j + 1] != '=' and !isIdentChar(value[j + 1])),
                    '~', '#', '|' => true,
                    '=' => j + 1 < value.len and value[j + 1] == '>',
                    else => false,
                };
                if (head) {
                    var e = j;
                    while (e < value.len and value[e] != '\n') : (e += 1) {}
                    return std.mem.trim(u8, value[j..e], " \t\r");
                }
            },
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

/// Two field names are the same binding when their EMITTED identifier is
/// the same: kebab `-` mangles to `_` at identifier-formation on every
/// target (D2), so `a-b` and `a_b` are distinct source spellings that emit
/// one struct member — the second reaches the host as a duplicate member
/// name. Compared byte-wise with `-`/`_` treated as one char class; a
/// case difference or any other byte still distinguishes the names.
pub fn emittedFieldNameEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca == cb) continue;
        const norm_a: u8 = if (ca == '-') '_' else ca;
        const norm_b: u8 = if (cb == '-') '_' else cb;
        if (norm_a != norm_b) return false;
    }
    return true;
}

fn projectRawFields(
    allocator: Allocator,
    raw_fields: []const []const u8,
    opts: ParseOptions,
) ParseError![]const StructField {
    var out = try std.ArrayList(StructField).initCapacity(allocator, raw_fields.len);
    for (raw_fields) |raw| {
        // A field list takes each name once: a second binding for a name
        // already taken is a silent drop downstream, explicit or pun alike.
        // The comparison is on the emitted spelling — `a-b` and `a_b` are
        // one member downstream (kebab mangles to snake at emit).
        const candidate: ?[]const u8 = blk: {
            if (topLevelColon(raw)) |colon| {
                break :blk std.mem.trim(u8, raw[0..colon], " \t\n\r");
            }
            break :blk punnableName(std.mem.trim(u8, raw, " \t\n\r"));
        };
        if (candidate) |cand| {
            for (out.items) |seen| {
                if (emittedFieldNameEql(seen.name, cand)) return error.DuplicateField;
            }
        }
        if (std.mem.trim(u8, raw, " \t\n\r").len == 0) continue;
        if (topLevelColon(raw)) |colon| {
            const name = std.mem.trim(u8, raw[0..colon], " \t\n\r");
            const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r");
            // `: value` — the name was dropped; downstream emitters print the
            // entry as a bare expression and Zig reports a missing initializer.
            if (name.len == 0) return error.NamelessField;
            // `name:` — the value was dropped; downstream emitters print
            // `.name =` with nothing after it.
            if (value.len == 0) return error.TypelessField;
            if (fusedFieldLine(value) != null) return error.MissingComma;
            if (fusedStatementLine(value) != null) return error.FusedStatement;
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
        error.MissingComma => "missing comma between fields — a `name: value` line that does not end in a comma fuses with the next line into one field",
        error.FusedStatement => "a `!` / `|` / `=>` line inside a `{ }` block begins a new step — it cannot continue the field above it",
        error.NamelessField => "field has no name — a field is `name: value` or a bare punnable name; `: value` dropped the name",
        error.TypelessField => "field has no value — a field is `name: value`; `name:` dropped the value",
        error.DuplicateField => "a field list takes each name once — the list cannot carry two fields with the same name",
        error.NotAStruct => "not a struct literal",
        error.UnterminatedStruct => "unterminated struct literal",
        error.OutOfMemory => "out of memory",
    };
}

/// The field name a `DuplicateField` error was raised on, re-derived by
/// re-scanning `input` (cold error path — same pattern as `describeErrorIn`).
/// Returns null when the input no longer parses to a repeat.
pub fn duplicateFieldName(allocator: Allocator, input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;
    const raw_fields = splitFields(allocator, trimmed[1 .. trimmed.len - 1]) catch return null;
    var seen = std.ArrayList([]const u8).initCapacity(allocator, raw_fields.len) catch return null;
    for (raw_fields) |raw| {
        const candidate: ?[]const u8 = blk: {
            if (topLevelColon(raw)) |colon| {
                break :blk std.mem.trim(u8, raw[0..colon], " \t\n\r");
            }
            break :blk punnableName(std.mem.trim(u8, raw, " \t\n\r"));
        };
        if (candidate) |cand| {
            for (seen.items) |s| {
                if (emittedFieldNameEql(s, cand)) return cand;
            }
            seen.append(allocator, cand) catch return null;
        }
    }
    return null;
}

/// The field name a `RedundantExplicitLabel` error was raised on, re-derived
/// by re-scanning `input` (cold error path — same pattern as
/// `duplicateFieldName`). Returns null when the input no longer parses to a
/// redundant label.
pub fn redundantFieldName(allocator: Allocator, input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;
    const raw_fields = splitFields(allocator, trimmed[1 .. trimmed.len - 1]) catch return null;
    for (raw_fields) |raw| {
        const colon = topLevelColon(raw) orelse continue;
        const name = std.mem.trim(u8, raw[0..colon], " \t\n\r");
        const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r");
        if (name.len == 0) continue;
        if (punnableName(value)) |punned| {
            if (std.mem.eql(u8, punned, name)) return name;
        }
    }
    return null;
}

/// The name of the entry a `TypelessField` error was raised on — `name:` with
/// nothing after the colon — re-derived by re-scanning `input` (cold error
/// path, same pattern as `duplicateFieldName`).
pub fn emptyValueFieldName(allocator: Allocator, input: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;
    const raw_fields = splitFields(allocator, trimmed[1 .. trimmed.len - 1]) catch return null;
    for (raw_fields) |raw| {
        const colon = topLevelColon(raw) orelse continue;
        const name = std.mem.trim(u8, raw[0..colon], " \t\n\r");
        const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r");
        if (name.len != 0 and value.len == 0) return name;
    }
    return null;
}

/// `describeError` with the implicated fragment folded in where `input` lets
/// it be re-derived — for MissingComma, the line that fused; for
/// DuplicateField, the name bound twice. Re-scans rather than plumbing a
/// detail out of the parser: the error path is cold, and the callers that
/// surface a refusal (`store:new`, insert/stored, capture) all hold the input.
/// Any other error, or an input that no longer parses the same way, degrades
/// to the static text.
pub fn describeErrorIn(allocator: Allocator, err: ParseError, input: []const u8) []const u8 {
    if (err == error.DuplicateField) {
        if (duplicateFieldName(allocator, input)) |name| {
            return std.fmt.allocPrint(allocator, "field '{s}' is bound twice — a field list takes each name once", .{name}) catch describeError(err);
        }
        return describeError(err);
    }
    if (err == error.FusedStatement) {
        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
            if (splitFields(allocator, trimmed[1 .. trimmed.len - 1])) |raw_fields| {
                for (raw_fields) |raw| {
                    if (topLevelColon(raw)) |colon| {
                        if (fusedStatementLine(std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r"))) |line| {
                            return std.fmt.allocPrint(allocator, "'{s}' is a new step, not part of the field above it — a `!` / `|` / `=>` line cannot continue a field value; move it out of the `{{ }}` block", .{line}) catch describeError(err);
                        }
                    }
                }
            } else |_| {}
        }
        return describeError(err);
    }
    if (err != error.MissingComma) return describeError(err);
    const trimmed = std.mem.trim(u8, input, " \t\n\r");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        if (splitFields(allocator, trimmed[1 .. trimmed.len - 1])) |raw_fields| {
            for (raw_fields) |raw| {
                if (topLevelColon(raw)) |colon| {
                    if (fusedFieldLine(std.mem.trim(u8, raw[colon + 1 ..], " \t\n\r"))) |line| {
                        return std.fmt.allocPrint(allocator, "missing comma — '{s}' began a new field but was read as part of the field above it; separate fields with commas", .{line}) catch describeError(err);
                    }
                }
            }
        } else |_| {}
    }
    return describeError(err);
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

/// Is `el` a TYPE spelling — the element grammar a `Name[params]` bracket
/// tail is allowed to carry (specialization-is-synthesis: brackets on a
/// name are parameters, resolved by synthesis to the underscore-joined
/// concrete decl, never generics application)? Conservative on purpose:
/// a bare identifier counts only when it is a base-type keyword — `note`,
/// `HTML`, `text` stay annotations, so `i64[note]`/`Source[HTML]` keep
/// their `type_annotations` meaning. `*`/`?`/`[]`-prefixed forms, qualified
/// `mod/path:Type` spellings (the `:` is required — `meter/second` is an
/// annotation atom, not a path), and nested `Ident[…]`/`Ident<…>` all
/// count. Anything else — regex atoms, quoted strings, `[a-z…]` classes —
/// is annotation content.
pub fn isTypeParamElement(el_in: []const u8) bool {
    var s = std.mem.trim(u8, el_in, " \t\r\n");
    if (s.len == 0) return false;
    // Peel type prefixes: `*`, `?`, `*const `, `?*`, `[]const `, `[]`.
    while (true) {
        if (std.mem.startsWith(u8, s, "*const ")) {
            s = s[7..];
        } else if (std.mem.startsWith(u8, s, "[]const ")) {
            s = s[8..];
        } else if (s.len > 0 and (s[0] == '*' or s[0] == '?')) {
            s = s[1..];
        } else if (std.mem.startsWith(u8, s, "[]")) {
            s = s[2..];
        } else break;
        s = std.mem.trimLeft(u8, s, " \t");
    }
    if (s.len == 0) return false;
    if (isBaseType(s) or std.mem.eql(u8, s, "string") or std.mem.eql(u8, s, "void")) return true;
    // Qualified type: a `:` at bracket/angle depth 0 with nonempty sides.
    {
        var bd: i32 = 0;
        var ad: i32 = 0;
        for (s, 0..) |c, i| {
            switch (c) {
                '[', '{', '(' => bd += 1,
                ']', '}', ')' => bd -= 1,
                '<' => ad += 1,
                '>' => ad -= 1,
                ':' => if (bd == 0 and ad == 0) {
                    if (i > 0 and i + 1 < s.len) return true;
                },
                else => {},
            }
        }
    }
    // Nested parameterized/phantom type: `Ident[` or `Ident<` head.
    if (isIdentStartChar(s[0])) {
        var i: usize = 1;
        while (i < s.len and isIdentChar(s[i])) : (i += 1) {}
        if (i < s.len and (s[i] == '[' or s[i] == '<')) return true;
        // A qualified path head (`a/b/c:Name` was caught above; `a.b.c` or
        // `a/b/c` module spellings without a colon are not type grammar).
        return false;
    }
    return false;
}

/// Does the content of a `[…]` group read as a comma-separated TYPE-PARAM
/// list (every element a type spelling)? This is the discriminator between
/// `Heap[i64]` (params — stays in the type string, canonicalizes to
/// `Heap_i64`) and `i64[note, tagged]`/`u64[\d+]`/`Source[HTML]`
/// (annotations — peeled into `type_annotations` as before).
pub fn bracketContentIsTypeParams(content: []const u8) bool {
    var depth: i32 = 0;
    var start: usize = 0;
    var saw = false;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        const at_end = i == content.len;
        const c: u8 = if (at_end) ',' else content[i];
        if (!at_end) {
            switch (c) {
                '[', '{', '(', '<' => depth += 1,
                ']', '}', ')', '>' => depth -= 1,
                else => {},
            }
        }
        if (c == ',' and depth == 0) {
            const el = std.mem.trim(u8, content[start..i], " \t\r\n");
            if (el.len == 0 or !isTypeParamElement(el)) return false;
            saw = true;
            start = i + 1;
        }
    }
    return saw;
}

/// Split a shape field's `= <expr>` default off its type text: `i64 = 5` →
/// `{ .type = "i64", .default = "5" }`. THE single parser for the tail —
/// parseShape (parser.zig) splits it off `Field.type` here, and the
/// expression-admission wall (flow_checker.zig) reads it back out of record
/// return-type text. An `=` inside brackets belongs to a nested type, and
/// `==`/`!=`/`<=`/`>=` are comparisons, not defaults.
pub fn splitTypeDefault(field_type: []const u8) struct { type: []const u8, default: ?[]const u8 } {
    var depth: i32 = 0;
    var k: usize = 0;
    while (k < field_type.len) : (k += 1) {
        const ch = field_type[k];
        switch (ch) {
            '[', '(', '{' => depth += 1,
            ']', ')', '}' => depth -= 1,
            '=' => {
                if (depth != 0) continue;
                if (k + 1 < field_type.len and field_type[k + 1] == '=') {
                    k += 1;
                    continue;
                }
                if (k > 0) {
                    const prev = field_type[k - 1];
                    if (prev == '!' or prev == '<' or prev == '>' or prev == '=') continue;
                }
                const rhs = std.mem.trim(u8, field_type[k + 1 ..], " \t\r\n");
                return .{
                    .type = std.mem.trim(u8, field_type[0..k], " \t\r\n"),
                    .default = if (rhs.len > 0) rhs else null,
                };
            },
            else => {},
        }
    }
    return .{ .type = field_type, .default = null };
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

    // Trailing comma is not a field. An empty last slice used to refuse
    // BareEntryNotPunnable, so writeBareReturnType pasted the record verbatim
    // and `string` never lowered.
    const trailing = try parseFields(allocator, "{ a: string, b: i64, }");
    try std.testing.expectEqual(@as(usize, 2), trailing.len);
    try std.testing.expectEqualStrings("a", trailing[0].name);
    try std.testing.expectEqualStrings("string", trailing[0].value);
    try std.testing.expectEqualStrings("b", trailing[1].name);
    try std.testing.expectEqualStrings("i64", trailing[1].value);

    const seed = try parseFieldsWithOptions(allocator, "{ a + 1 }", .{ .allow_singleton_expression = true });
    try std.testing.expectEqual(@as(usize, 1), seed.len);
    try std.testing.expectEqualStrings("", seed[0].name);
    try std.testing.expectEqualStrings("a + 1", seed[0].value);
}

test "comma-less multi-line field list refuses MissingComma naming the fused line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fused = "{ label: *std/string:String<std/string:instance!>\n    done: i64 }";
    try std.testing.expectError(error.MissingComma, parseFields(allocator, fused));
    try std.testing.expectEqualStrings(
        "missing comma — 'done: i64' began a new field but was read as part of the field above it; separate fields with commas",
        describeErrorIn(allocator, error.MissingComma, fused),
    );

    // Comma-separated multi-line lists stay legal; so do values that span
    // lines inside nesting or continue an expression without `ident:`.
    const ok = try parseFields(allocator, "{ a: i64,\n    b: i64\n}");
    try std.testing.expectEqual(@as(usize, 2), ok.len);
    const nested = try parseFields(allocator, "{ a: f(\n    x,\n    y),\n    b: i64 }");
    try std.testing.expectEqual(@as(usize, 2), nested.len);
}

test "empty struct literal yields no fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = try parse(allocator, "{}");
    try std.testing.expectEqual(@as(usize, 0), v.record.get("children").?.array.len);
}
