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

/// Zig primitive names. Binding one of these as a local is a compile error
/// ("name shadows primitive"), yet every one of them is a legal Koru
/// identifier — so they need `@"..."` escaping exactly like keywords do
/// (230_018). The arbitrary-width `u*`/`i*` family is matched structurally
/// below, not listed here.
const zig_primitives = std.StaticStringMap(void).initComptime(.{
    .{ "anyerror", {} },
    .{ "anyopaque", {} },
    .{ "bool", {} },
    .{ "c_char", {} },
    .{ "c_int", {} },
    .{ "c_long", {} },
    .{ "c_longdouble", {} },
    .{ "c_longlong", {} },
    .{ "c_short", {} },
    .{ "c_uint", {} },
    .{ "c_ulong", {} },
    .{ "c_ulonglong", {} },
    .{ "c_ushort", {} },
    .{ "comptime_float", {} },
    .{ "comptime_int", {} },
    .{ "f128", {} },
    .{ "f16", {} },
    .{ "f32", {} },
    .{ "f64", {} },
    .{ "f80", {} },
    .{ "false", {} },
    .{ "isize", {} },
    .{ "noreturn", {} },
    .{ "null", {} },
    .{ "true", {} },
    .{ "type", {} },
    .{ "undefined", {} },
    .{ "usize", {} },
    .{ "void", {} },
});

/// `u<digits>` / `i<digits>` — Zig's arbitrary-width integer family, all of
/// them primitives no local may shadow.
fn isZigIntPrimitive(name: []const u8) bool {
    if (name.len < 2) return false;
    if (name[0] != 'u' and name[0] != 'i') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Check if an identifier needs escaping for Zig
/// Returns true for:
/// - Zig keywords (const, fn, etc.)
/// - Zig primitive names (u8, bool, type, …) — locals may not shadow them
/// - Identifiers starting with @ (npm scoped packages like @koru)
/// - Identifiers containing non-identifier chars (hyphens, etc.)
pub fn needsEscaping(name: []const u8) bool {
    // Already escaped: @"..."
    if (name.len >= 3 and name[0] == '@' and name[1] == '"' and name[name.len - 1] == '"') {
        return false;
    }

    if (zig_keywords.has(name)) return true;
    if (zig_primitives.has(name)) return true;
    if (isZigIntPrimitive(name)) return true;
    if (name.len == 0) return false;
    // Starts with @ (npm scoped packages like @koru)
    if (name[0] == '@') return true;
    // Contains characters that aren't valid in Zig identifiers
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return true;
    }
    // Starts with digit
    if (std.ascii.isDigit(name[0])) return true;
    return false;
}

/// True when a name carries a kebab `-`, which is legal in Koru and illegal in
/// a Zig identifier.
///
/// A kebab name has exactly one correct Zig spelling and it is the MANGLE, not
/// the escape: `parse-error` becomes `parse_error`, never `@"parse-error"`.
/// Both are legal Zig, which is what makes this dangerous — a union declaring
/// the field one way and a switch arm naming it the other both compile in
/// isolation and disagree only when they meet.
pub fn hasKebab(name: []const u8) bool {
    for (name) |c| {
        if (c == '-') return true;
    }
    return false;
}

/// Append a name mangled for Zig: kebab `-` → `_`. The result is always a
/// valid identifier, so it never needs `@"…"` on top.
pub fn appendMangled(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    for (name) |c| {
        try list.append(allocator, if (c == '-') '_' else c);
    }
}

/// Append a BRANCH NAME as Zig: mangled when kebab, escaped when it collides
/// with a keyword, verbatim otherwise.
///
/// Every site that writes a branch name — the union's field, a switch arm, a
/// constructor — must go through one spelling, and this is it. They used not
/// to: `emitter_helpers.writeBranchName` mangled, and the escaper family here
/// did not, so a union written by one and switched on by the other disagreed.
///
/// NOT PINNED BY A MINIMAL TEST, and that is stated rather than implied. The
/// mismatch was found in orisha, whose router transform switches on six kebab
/// branches of `std/runtime:run`; routing these sites through one spelling
/// removed that error, and a full --no-cache board with the change moved
/// nothing (1442 -> 1445, every flip attributable elsewhere). Three minimal
/// shapes were tried and all pass with AND without the change — see
/// 020_062_kebab_branch_across_a_module_boundary, which says so in its own
/// header. The distinguishing case is on the transform-generated path and has
/// not been isolated.
pub fn appendBranchName(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    if (hasKebab(name)) {
        try appendMangled(list, allocator, name);
        return;
    }
    try appendEscapedIdentifier(list, allocator, name);
}

/// Escape a Zig identifier if needed (keyword, @-prefix, special chars)
/// Caller owns the returned memory
pub fn escapeZigIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (needsEscaping(name)) {
        return std.fmt.allocPrint(allocator, "@\"{s}\"", .{name});
    }
    // Not a keyword, return the name as-is (caller must dupe if needed)
    return name;
}

/// Write an escaped identifier to a writer
pub fn writeEscapedIdentifier(writer: anytype, name: []const u8) !void {
    if (needsEscaping(name)) {
        try writer.print("@\"{s}\"", .{name});
    } else {
        try writer.writeAll(name);
    }
}

/// Append an escaped identifier to an ArrayList
pub fn appendEscapedIdentifier(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    if (needsEscaping(name)) {
        try list.appendSlice(allocator, "@\"");
        try list.appendSlice(allocator, name);
        try list.appendSlice(allocator, "\"");
    } else {
        try list.appendSlice(allocator, name);
    }
}

/// A `:` inside a `[...]` span is keyed addressing — `store[key: value]` —
/// pinned aspirational at 690_018 (the `key:` decl emits no lookup machinery
/// and the bracket interior splices verbatim into `__koru_resolve`, producing
/// invalid host code). Every consumer that accepts `store[...]` must honor or
/// refuse that shape; this is the refusal detector. Quote- and depth-aware;
/// colons at bracket-depth 0 (a format spec, a field separator) do not count.
pub fn colonInsideBrackets(text: []const u8) bool {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '[' => depth += 1,
            ']' => {
                if (depth > 0) depth -= 1;
            },
            ':' => {
                if (depth > 0) return true;
            },
            else => {},
        }
    }
    return false;
}

/// `{{ v:d:N }}` — Koru owns the `d:<digits>` width semantic (ruled
/// 2026-10-24, pinned by 620_005): space-pad left to N columns, sign only
/// when negative — C's `%Nd`, the shape every external oracle (CLBG, PLB
/// nsieve) expects. Zig 0.15's `{d:N}` prints an explicit '+' on positive
/// signed integers, and the C#/JS emitters drop the width outright, so a
/// spec passed verbatim lets one host's quirk become the surface. The
/// emitters instead wrap the arg as `__koru_pad_i(N, <arg>)` under `{f}`.
/// Returns the width digits (leading zeros stripped — `08` is not a Zig
/// int literal) when `format_spec` is exactly `d:<digits>`, else null:
/// `d:.N` (precision) and every other spec keep their existing path.
pub fn decimalPadWidth(format_spec: []const u8) ?[]const u8 {
    if (format_spec.len <= 2 or format_spec[0] != 'd' or format_spec[1] != ':') return null;
    const digits = format_spec[2..];
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
    }
    const trimmed = std.mem.trimLeft(u8, digits, "0");
    return if (trimmed.len == 0) "0" else trimmed;
}

/// Decimal index scan for the `__koru_*_N` splice markers — returns the
/// digits' value and advances `pos` past them, or null when no digit is
/// there (`pos` untouched past the first non-digit).
pub fn scanDecimalIndex(text: []const u8, pos: *usize) ?usize {
    var idx: usize = 0;
    var saw_digit = false;
    while (pos.* < text.len and text[pos.*] >= '0' and text[pos.*] <= '9') : (pos.* += 1) {
        idx = idx * 10 + (text[pos.*] - '0');
        saw_digit = true;
    }
    return if (saw_digit) idx else null;
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

/// A closing delimiter inside the opaque expression value had no matching
/// opener. The value is pasted-verbatim raw text (Model A — see
/// struct_literal.zig), so we don't diagnose it here: we refuse to mis-parse
/// it and let the caller paste the raw expression, where the host (Zig)
/// rejects the imbalance loudly. The alternative — decrementing an unsigned
/// depth past zero — is an integer-overflow panic on user input.
const ExprParseError = std.mem.Allocator.Error || error{UnbalancedExpression};

/// Copy a `"…"` string literal through VERBATIM, honouring backslash escapes,
/// and return the index just past its closing quote.
///
/// Every delimiter this lowering reacts to — `{ } , ( ) [ ]` — is also ordinary
/// text inside a string, and the walk below cannot tell the two apart on its
/// own. It did not try until 2026-08-10, so `body: "{\"status\":\"ok\"}"` came
/// out of the emitter as `".{\"status\":\"ok\"}"`: the brace opening the JSON
/// was read as a struct literal opening and collected the `.` that Zig's
/// anonymous-struct syntax needs. The program compiled and served a response
/// body with a stray leading dot in it — wrong output, no diagnostic anywhere.
/// A JSON body is the ordinary case for a web handler, so this was reachable
/// from the first API route anyone writes.
///
/// An unterminated literal copies to the end rather than running off it; the
/// host compiler is the one that gets to complain about that.
fn copyStringLiteral(
    allocator: std.mem.Allocator,
    input: []const u8,
    start: usize,
    result: *std.ArrayList(u8),
) std.mem.Allocator.Error!usize {
    var i = start;
    try result.append(allocator, input[i]); // opening quote
    i += 1;
    while (i < input.len) {
        const c = input[i];
        try result.append(allocator, c);
        i += 1;
        if (c == '\\') {
            // Escaped character is part of the literal whatever it is — including
            // an escaped quote, which must not end the scan.
            if (i < input.len) {
                try result.append(allocator, input[i]);
                i += 1;
            }
        } else if (c == '"') {
            break;
        }
    }
    return i;
}

/// Convert a Koru struct literal to Zig anonymous struct syntax
/// Input:  "{ field: value, other: value2 }"
/// Output: ".{ .field = value, .other = value2 }"
/// Caller owns returned memory.
pub fn koruStructToZig(allocator: std.mem.Allocator, koru_struct: []const u8) ExprParseError![]const u8 {
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
            try skipWhitespaceEcho(allocator, input, &i, &result);
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
            try skipWhitespaceEcho(allocator, input, &i, &result);
            // Now at next field position
            if (i < input.len and input[i] != '}') {
                const field_result = try parseFieldAndValue(allocator, input, i, &result);
                i = field_result;
            }
        } else if (c == '}') {
            // Closing brace - just output it
            try result.append(allocator, '}');
            i += 1;
        } else if (c == '"') {
            // A string literal is opaque text — no delimiter inside it is one.
            i = try copyStringLiteral(allocator, input, i, &result);
        } else {
            // Other characters (shouldn't happen at top level, but pass through)
            try result.append(allocator, c);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// NOTE: `koruStructToConstDecls` (the old Zig string-builder for `const {}`
// module decls) was removed 2026-06-04. `const` is now a per-target template
// over the `parse_fields` filter (koru_std/declarations.kz + template_processor.zig),
// so field parsing lives in one place both targets call — see
// [[project_const_as_type_system_checkpoint]].

/// Advance past whitespace, echoing it into `result` — the round-trip
/// copy keeps the author's spacing.
fn skipWhitespaceEcho(allocator: std.mem.Allocator, input: []const u8, i: *usize, result: *std.ArrayList(u8)) ExprParseError!void {
    while (i.* < input.len and (input[i.*] == ' ' or input[i.*] == '\t' or input[i.*] == '\n')) {
        try result.append(allocator, input[i.*]);
        i.* += 1;
    }
}

/// Parse a field name, colon, and value. Output as ".fieldname = value"
/// Returns the new position after the value.
fn parseFieldAndValue(
    allocator: std.mem.Allocator,
    input: []const u8,
    start: usize,
    result: *std.ArrayList(u8),
) ExprParseError!usize {
    var i = start;

    // Read field name (identifier) — kebab-greedy: an infix `-` joins one
    // Koru name (`pos-tempo`); subtraction needs spaces, and a field name is
    // never arithmetic.
    const field_start = i;
    while (i < input.len) {
        const c = input[i];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            i += 1;
        } else if (c == '-' and i + 1 < input.len and
            (std.ascii.isAlphanumeric(input[i + 1]) or input[i + 1] == '_'))
        {
            i += 1;
        } else break;
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
        // Output ".fieldname = " — the field name carries the canonical
        // spelling (kebab mangles, keywords escape), same as the decl.
        try result.append(allocator, '.');
        try appendBranchName(result, allocator, field_name);
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
        try appendBranchName(result, allocator, field_name);
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
) ExprParseError!usize {
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

        if (c == '"') {
            // A string literal is opaque text. Every branch below reacts to a
            // delimiter, and a string may contain all of them — a JSON body
            // being the case that made this reachable. Copy it through whole,
            // so nothing inside it opens a brace, closes one, or ends a value.
            i = try copyStringLiteral(allocator, input, i, result);
        } else if (c == '{') {
            // Check what precedes the '{':
            // Array literals: [3]i32{ 0, 0, 0 } - no '.', no field parsing
            // Typed struct literals: IntConfig{ value: 42 } - no '.', YES field parsing  
            // Anonymous struct literals: { field: value } - add '.', YES field parsing
            var is_array_init = false;
            var is_typed_struct = false;
            if (i > 0) {
                var j = i - 1;
                // Skip whitespace
                while (j > 0 and (input[j] == ' ' or input[j] == '\t')) {
                    j -= 1;
                }
                if (input[j] == ']') {
                    is_array_init = true;
                } else if (std.ascii.isAlphanumeric(input[j]) or input[j] == '_') {
                    is_typed_struct = true;
                }
            }
            brace_depth += 1;
            if (!is_array_init and !is_typed_struct) {
                try result.append(allocator, '.');
            }
            try result.append(allocator, '{');
            i += 1;
            // Skip whitespace
            try skipWhitespaceEcho(allocator, input, &i, result);
            // Parse nested fields for struct literals (typed or anonymous), NOT for array initializers
            if (!is_array_init and i < input.len and input[i] != '}') {
                i = try parseFieldAndValue(allocator, input, i, result);
            }
        } else if (c == '}') {
            if (brace_depth == 0) return error.UnbalancedExpression;
            brace_depth -= 1;
            try result.append(allocator, '}');
            i += 1;
        } else if (c == '(') {
            paren_depth += 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == ')') {
            if (paren_depth == 0) return error.UnbalancedExpression;
            paren_depth -= 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == '[') {
            bracket_depth += 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == ']') {
            if (bracket_depth == 0) return error.UnbalancedExpression;
            bracket_depth -= 1;
            try result.append(allocator, c);
            i += 1;
        } else if (c == ',' and brace_depth > 0) {
            // Comma inside nested struct - handle next field
            try result.append(allocator, ',');
            i += 1;
            // Skip whitespace
            try skipWhitespaceEcho(allocator, input, &i, result);
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

// A string field's contents are text, not syntax. Every delimiter this lowering
// reacts to can appear inside one, and a JSON body carries most of them at once —
// which is how an ordinary web handler reached it: `{"status":"ok"}` came out as
// `.{"status":"ok"}`, because the brace opening the JSON was read as a struct
// literal and collected the `.` Zig's anonymous-struct syntax needs. It compiled
// and served the wrong bytes.
test "koruStructToZig leaves braces inside a string literal alone" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ body: \"{\\\"status\\\":\\\"ok\\\"}\" }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .body = \"{\\\"status\\\":\\\"ok\\\"}\" }", result);
}

test "koruStructToZig leaves commas and brackets inside a string literal alone" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ body: \"a,b[c](d)\", n: 1 }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .body = \"a,b[c](d)\", .n = 1 }", result);
}

// An escaped quote must not end the literal — otherwise the scan resumes inside
// what is still string text and starts reacting to its delimiters again.
test "koruStructToZig respects an escaped quote inside a string literal" {
    const allocator = std.testing.allocator;
    const result = try koruStructToZig(allocator, "{ body: \"say \\\" then {x}\", n: 2 }");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".{ .body = \"say \\\" then {x}\", .n = 2 }", result);
}

// Regression: a stray closing delimiter inside a value used to underflow the
// unsigned depth counter (integer-overflow panic on user input). It must now
// surface as a clean error so the caller can paste the raw expression and let
// the host compiler reject the imbalance loudly.
test "koruStructToZig stray ']' returns error, never panics" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnbalancedExpression, koruStructToZig(allocator, "{ a: foo] }"));
}

test "koruStructToZig stray ')' returns error, never panics" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnbalancedExpression, koruStructToZig(allocator, "{ a: foo) }"));
}

// 230_021: a bound name that IS a Zig keyword must not be rewritten in the
// keyword's own position — `var n:` is a declaration, not a reference to a
// param named `var`. The reference positions (after `=`, at end of an
// expression) still get the escaped spelling.
test "replaceIdentifier spares keyword positions for a keyword name" {
    const allocator = std.testing.allocator;
    const result = try replaceIdentifier(allocator,
        \\var n: i32 = var;
        \\const m = var + 1;
        \\x = var
        \\y = 1;
    , "var", "@\"var\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\var n: i32 = @"var";
        \\const m = @"var" + 1;
        \\x = @"var"
        \\y = 1;
    , result);
}

test "replaceIdentifier spares the keyword's punctuator forms" {
    const allocator = std.testing.allocator;
    // `if (`, `return;`, `break :`, `error.` — keyword grammar, untouched;
    // the operand `return` in `x = return` is a reference and rewrites.
    const result = try replaceIdentifier(allocator,
        \\x = return;
        \\if (x) y else z;
        \\return;
    , "return", "@\"return\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\x = @"return";
        \\if (x) y else z;
        \\return;
    , result);
}

// ============================================================================
// KORU MODULE-WRAPPER PREFIX
// ============================================================================
// All Zig code we emit for a Koru module is wrapped in `pub const koru_<name>
// = struct { ... }`. The "koru_" prefix exists so that user-imported Zig
// identifiers (e.g. `const vaxis = @import("vaxis");`) don't collide with the
// wrapper name.
//
// Phase 1: only the TOP segment of a dotted path is prefixed, so
// "std.io" emits as "koru_std.io" — the nested wrapper for `io` is bare.
// Phase 2 (current): every segment is prefixed, so "std.io" becomes
// "koru_std.koru_io".

pub const KORU_PREFIX: []const u8 = "koru_";

/// When true, only the first (top-level) segment of a dotted module path
/// receives the `koru_` prefix. When false, every segment is prefixed.
/// All koru-module-path emission sites consult this — flip it to enable
/// Phase 2 (prefix-every-segment) atomically.
pub const KORU_PREFIX_TOP_ONLY: bool = false;

/// Returns the koru wrapper prefix for a given segment position.
/// Phase 1: `"koru_"` for the first segment, `""` for the rest.
/// Phase 2: `"koru_"` for every segment.
pub fn koruWrapperPrefix(is_first_segment: bool) []const u8 {
    if (KORU_PREFIX_TOP_ONLY) {
        return if (is_first_segment) KORU_PREFIX else "";
    } else {
        return KORU_PREFIX;
    }
}

/// Build a Zig-emitter module path from a Koru logical module name.
/// "std.io" -> "koru_std.io" (Phase 1) / "koru_std.koru_io" (Phase 2).
/// Caller owns the returned slice.
/// Does NOT escape segments — callers that need Zig-identifier escaping
/// (e.g. writeModulePath in emitter_helpers) should iterate segments
/// themselves and apply the prefix via koruWrapperPrefix.
pub fn buildKoruModulePath(allocator: std.mem.Allocator, logical_name: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var splitter = std.mem.splitScalar(u8, logical_name, '.');
    var is_first = true;
    while (splitter.next()) |segment| {
        if (!is_first) {
            try buf.append(allocator, '.');
        }
        try buf.appendSlice(allocator, koruWrapperPrefix(is_first));
        try buf.appendSlice(allocator, segment);
        is_first = false;
    }
    return buf.toOwnedSlice(allocator);
}

test "buildKoruModulePath single segment" {
    const allocator = std.testing.allocator;
    const result = try buildKoruModulePath(allocator, "logger");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("koru_logger", result);
}

test "buildKoruModulePath dotted path" {
    const allocator = std.testing.allocator;
    const result = try buildKoruModulePath(allocator, "std.io");
    defer allocator.free(result);
    // Phase 2: every segment prefixed
    try std.testing.expectEqualStrings("koru_std.koru_io", result);
}

test "buildKoruModulePath three segments" {
    const allocator = std.testing.allocator;
    const result = try buildKoruModulePath(allocator, "std.io.print");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("koru_std.koru_io.koru_print", result);
}

test "koruWrapperPrefix Phase 2" {
    try std.testing.expectEqualStrings("koru_", koruWrapperPrefix(true));
    try std.testing.expectEqualStrings("koru_", koruWrapperPrefix(false));
}

// ============================================================================
// THE KORU EXPRESSION LOWERING — one pass, one vocabulary, two targets
// ============================================================================
//
// Koru expression text used to be lowered in exactly one place: inside the JS
// emitter, reachable only from text the emitter itself wrote. Every OTHER route
// an expression takes to a host — a `std/store` query guard spliced into a
// generated proc body, a `std/kernel` op body, any transform that assembles host
// text — carried it past that pass untouched. Three symptoms, one cause: a guard
// reached `node` as `hp > 40 and kind == 1`, and `@sqrt(dsq)` reached it with the
// `@` still on it, while `js_emitter` had known how to lower both for months.
//
// So the pass lives here, as a pure function any caller can reach, and
// `js_emitter` is now one of its callers rather than its owner. `koruStructToZig`
// above is the same shape and the reason this file is the right home.
//
// WHAT THE VOCABULARY IS. `lowerBuiltin` below is the list of operations Koru
// names with an `@`, and it is the closest thing the language has to a written
// definition of its own operation set. That is not an accident of the JS port —
// it is a CONSEQUENCE of it. A single target never has to say what its
// vocabulary is, because the host's own spelling answers every question by
// default. A second target cannot pass anything through, so it has to name what
// it knows and refuse the rest, and naming-and-refusing is what a definition is.
//
// RULED 2026-08-07 (Lars): the Zig spelling stays the Koru spelling for now, and
// the exact shape of the vocabulary is deliberately NOT settled yet. What matters
// at this rung is that a vocabulary EXISTS in one place with one home. So the
// `.zig` arm is the identity: Koru's operators are a Zig subset (`and` and `or`
// are Zig keywords, arithmetic and comparison are shared, `++` is Zig's own
// concat), and Zig accepts an unmodelled `@foo` because it is a Zig builtin.
//
// THE IDENTITY CLAIM'S PREMISE HAS TWO MEASURED HOLES, both fixed by rewriting
// rather than by touching the ruling (which is about the VOCABULARY — the `@`
// operations — not about these two operators): `==`/`!=` on strings
// (2026-08-07) and `%` on a signed integer (2026-09-17). Both are operators the
// language already had a meaning for in every other organ. "Arithmetic and
// comparison are shared" is what has to be checked per OPERATOR: `%` is the
// same GLYPH in both hosts and is still not the same operator, because Zig
// defines it only on unsigned integers. See the spelling section below.
//
// WHAT THAT DEFERS, said plainly so it does not go invisible: the vocabulary is
// ENFORCED on JS and ABSENT on Zig. A `.k` naming an `@foo` nobody modelled is
// accepted by one target and refused by the other, so the table can drift into
// "whatever JS happened to need" — the one-direction-of-a-symmetry shape this
// repo has been bitten by before. Closing it means growing the `.zig` arm from
// identity to table-consulting, which is a WALL and will turn things red on
// purpose. That is the next rung and it is a language ruling, not a refactor.

/// Which host the expression is being rendered for.
pub const HostTarget = enum { zig, js, cs };

/// WHAT KIND OF TEXT THIS IS, which decides how much of the lowering applies.
///
/// - `koru_expr` — a Koru EXPRESSION: a `when` guard, a `stored` block's
///   right-hand side. Every identifier in it is a REFERENCE to a binding.
/// - `koru_body` — Koru-authored STATEMENT text: a `std/kernel:pairwise` op
///   body is `const dx = k.other.x - k.x; …`, written in host syntax and
///   spliced whole. Needs the operator and `@`-builtin lowering; its
///   identifiers are NOT all references.
/// - `host_text` — already rendered into the host's own language by a template.
///
/// Two rewrites key off this and they split it differently, which is the reason
/// there are three modes and not two:
///
/// `++` is Koru's concatenation and must become `+`, but in already-rendered
/// host text a `++` is a genuine JavaScript increment — so it fires for both
/// Koru modes and not for `host_text`.
///
/// The RESERVED-WORD rename fires for `koru_expr` ALONE. It renames an
/// identifier JavaScript cannot bind, which is only sound where every
/// identifier is a reference. In a `koru_body` the same words are host
/// KEYWORDS: applied there it turned `const dx = …` into `const$ dx = …` and
/// broke 390_020, which is what taught this mode to exist.
///
/// Everything else is lowered in all three — a `when` guard arrives as Koru text
/// while the identical condition, baked into a `~[template]proc for|js` body, arrives
/// as host text, and lowering only one door leaves the other emitting `a and b`.
pub const ExprMode = enum { koru_expr, koru_body, host_text };

pub const LowerError = error{ UnsupportedBuiltin, OutOfMemory };

/// Filled in when `lowerKoruExpr` returns `error.UnsupportedBuiltin`, so the
/// caller can name the operation in its own diagnostic rather than reporting
/// that something, somewhere, was not understood.
pub const LowerDiag = struct { unknown_builtin: []const u8 = "" };

/// Render Koru expression text for `target`. Caller owns the result.
pub fn lowerKoruExpr(
    allocator: std.mem.Allocator,
    text: []const u8,
    target: HostTarget,
    mode: ExprMode,
    diag: ?*LowerDiag,
) LowerError![]const u8 {
    if (target == .zig) {
        // The `.zig` arm is the identity for the OPERATION VOCABULARY (ruled
        // 2026-08-07, above) — but "arithmetic and comparison are shared" has
        // two holes, and they are the rewrites this arm carries:
        //
        //   `==` on two strings — Koru's is value equality (comptime_eval.zig
        //   folds it with `mem.eql`; the interpreter and the JS target agree)
        //   and Zig refuses it on slices at Stage D ("cannot compare strings
        //   with =="), so a literal-grounded comparison becomes
        //   `@import("std").mem.eql(u8, …)`.
        //
        //   `%` on a signed integer — Zig's `%` is unsigned-only, Koru's is
        //   C's truncated remainder (`comptime_eval.zig` folds it with
        //   `@rem`, "the C-parity choice"), so it becomes `@rem(lhs, rhs)`.
        //
        // Both are semantic, not vocabulary: the operation is the one Koru
        // already has, spelled for this host. See the operator-spelling section
        // below for the boundary of what the rewrite can read.
        if (mode != .host_text) {
            if (rewriteZigExpr(allocator, text) catch null) |rewritten| {
                return rewritten;
            }
        }
        return allocator.dupe(u8, text);
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, text.len + 32);
    errdefer out.deinit(allocator);
    if (target == .cs) {
        try lowerCsInto(&out, allocator, text, mode, diag);
    } else {
        try lowerJsInto(&out, allocator, text, mode, diag);
    }
    return out.toOwnedSlice(allocator);
}

/// JAVASCRIPT'S RESERVED WORDS — the names a Koru program may legally choose and
/// JavaScript may not bind.
///
/// Koru's own store vocabulary walks straight into this: `! updated { old, new }`
/// names its payload fields `old` and `new`, and `new` is a JS keyword, so the
/// destructure emitted `const new = __koru_input.new;` and node refused the whole
/// program. Nothing about the Koru is wrong, so refusing at the declaration would
/// be refusing a correct program because of the host — the rename happens here
/// instead (ruled 2026-08-07).
///
/// `true`, `false`, `null` and `undefined` are DELIBERATELY ABSENT. They are
/// values with the same meaning in both languages, and renaming them in an
/// expression would turn a literal into an undefined name. The list is keywords
/// that cannot be BOUND, not every word JS treats specially.
const JS_RESERVED = [_][]const u8{
    "arguments", "await",     "break",  "case",       "catch",  "class",
    "const",     "continue",  "debugger", "default",  "delete", "do",
    "else",      "enum",      "eval",   "export",     "extends", "finally",
    "for",       "function",  "if",     "implements", "import", "in",
    "instanceof", "interface", "let",   "new",        "package", "private",
    "protected", "public",    "return", "static",     "super",  "switch",
    "this",      "throw",     "try",    "typeof",     "var",    "void",
    "while",     "with",      "yield",
};

fn isJsReserved(name: []const u8) bool {
    for (JS_RESERVED) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// C#'S RESERVED WORDS — the names a Koru program may legally choose and C#
/// may not bind. Same rule as JS_RESERVED: keywords that cannot be BOUND,
/// not every word C# treats specially — `true`/`false`/`null` are literals
/// with the same meaning in both languages and are absent on purpose.
const CS_RESERVED = [_][]const u8{
    "abstract", "as",       "base",     "bool",    "break",    "byte",
    "case",     "catch",    "char",     "checked", "class",    "const",
    "continue", "decimal",  "default",  "delegate", "do",      "double",
    "else",     "enum",     "event",    "explicit", "extern",  "finally",
    "fixed",    "float",    "for",      "foreach", "goto",     "if",
    "implicit", "in",       "int",      "interface", "internal", "is",
    "lock",     "long",     "namespace", "new",    "object",   "operator",
    "out",      "override", "params",   "private", "protected", "public",
    "readonly", "ref",      "return",   "sbyte",   "sealed",   "short",
    "sizeof",   "stackalloc", "static", "string",  "struct",   "switch",
    "this",     "throw",    "try",      "typeof",  "uint",     "ulong",
    "unchecked", "unsafe",  "ushort",   "using",   "virtual",  "void",
    "volatile", "while",
};

fn isCsReserved(name: []const u8) bool {
    for (CS_RESERVED) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// Public face of the C# reserved-word test — the cs emitter's binding
/// boundary (`writeBinding`) consults it to decide the `@`-verbatim escape.
/// Kept separate from `isJsReserved`'s `needsJsMangle` shape: C# has no
/// `$`-suffix collision class, so no stem-stripping is needed.
pub fn isCsReservedForEmit(name: []const u8) bool {
    return isCsReserved(name);
}

/// The C# spelling of a Koru name in BINDING position. C# has the native
/// mechanism JS lacks — `@event` is a verbatim identifier, still readable —
/// so the mangle is the host's own escape rather than a `$` suffix.
/// Caller owns the result.
pub fn mangleCsIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (!isCsReserved(name)) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "@{s}", .{name});
}

/// Does this name need renaming to be BOUND in JavaScript?
///
/// Reserved words do. So does a name that would COLLIDE with a renamed one:
/// `mangleJsIdent` appends `$`, and Koru's parser permits `$` inside a name
/// (700_000 pins `~test:name$with#special@chars`), so a program could contain a
/// literal `new$` that the rename would alias onto. Stripping trailing `$`s and
/// re-testing the stem makes the mapping injective — `new` -> `new$`,
/// `new$` -> `new$$` — instead of merely unlikely to collide.
pub fn needsJsMangle(name: []const u8) bool {
    var stem = name;
    while (stem.len > 0 and stem[stem.len - 1] == '$') stem = stem[0 .. stem.len - 1];
    return isJsReserved(stem);
}

/// The JS spelling of a Koru name in BINDING position. Caller owns the result.
///
/// PROPERTY KEYS DO NOT COME HERE, and that asymmetry is the design rather than
/// an omission: a reserved word is a perfectly legal key in ES5+, `writeMember`
/// already brackets the ones JS cannot spell at all, and — the load-bearing
/// reason — object literals are also written as RAW HOST TEXT by transforms
/// (`std/store` emits `{ old: __koru_old, new: value_0 }` from its own string
/// builder, which never passes through this function). Renaming keys here would
/// desynchronise the emitter's reader from the transform's writer, silently, and
/// the result would be `undefined` rather than a syntax error.
pub fn mangleJsIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (!needsJsMangle(name)) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}$", .{name});
}

/// HOW A HOST SPELLS THE SHAPES A TRANSFORM EMITS — the sibling of
/// `lowerKoruExpr` one level up. That function renders an EXPRESSION; this one
/// renders the STRUCTURE a generated body is built out of, where the two hosts
/// differ in shape rather than in syntax.
///
/// A terminal branch value is the clearest case. Zig returns a tagged-union
/// literal; JS returns `{ tag: "<name>", <name>: payload }` — the payload key
/// REPEATS the branch name (js_emitter.zig:594 writes it, :1381 and :2847 read
/// it back). Nothing about `.{ .full = x }` suggests that, so a site spelling it
/// by hand gets it right the first four times and wrong the fifth.
///
/// This lives here, not in the transform that first needed it, for the reason
/// `lowerKoruExpr` does: `std/store` emits these shapes from `new` AND from
/// `query`, and a second copy beside the first is how the two spellings drift.
/// Compiler-side placement also matters — a helper hoisted to a `.kz` module's
/// own scope is emitted into every program that imports it, 90 dead lines of
/// compiler machinery in a shipped artifact.
pub const HostShape = struct {
    /// `| name <value>` — a payload that IS the value.
    /// The cs spelling of `name` in a member position — kebab and the
    /// dotted-name join both fold to underscores (the emitter's `writeIdent`
    /// does the same to the declared member) and a reserved word takes the
    /// `@` escape.
    pub fn csMember(alloc: std.mem.Allocator, name: []const u8) []const u8 {
        return mangleCsIdent(alloc, csFolded(alloc, name)) catch unreachable;
    }

    /// `csMember` minus the `@` keyword escape — for positions where the
    /// name is glued behind a longer identifier (`__koru_read_<field>`)
    /// and can never itself be a keyword. Zig's `@"name"` escape also
    /// surfaces here — `@` is only legal as a C# identifier PREFIX, so
    /// glued positions strip it (csMember re-adds it via mangleCsIdent
    /// when the bare name is a keyword).
    pub fn csFolded(alloc: std.mem.Allocator, name: []const u8) []const u8 {
        const de_kebabed = std.mem.replaceOwned(u8, alloc, name, "-", "_") catch unreachable;
        const de_dotted = std.mem.replaceOwned(u8, alloc, de_kebabed, ".", "_") catch unreachable;
        return std.mem.replaceOwned(u8, alloc, de_dotted, "@", "") catch unreachable;
    }

    /// A branch-payload member name spelled for C# — `csMember` folded, plus
    /// the one struct-member collision the Output shape creates: `tag` is the
    /// discriminator member, so a branch literally named `tag` (a `tag`
    /// column's apply arm, 690_336) carries its payload as `__ktag`.
    /// The emitter maps the same branch name at payload READ sites
    /// (`writeMember`/destructure bases in cs_emitter.zig).
    pub fn csPayloadMember(alloc: std.mem.Allocator, name: []const u8) []const u8 {
        const m = csMember(alloc, name);
        return if (std.mem.eql(u8, m, "tag")) "__ktag" else m;
    }

    pub fn branchOne(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        const esc_name = escapeZigIdentifier(alloc, name) catch name;
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "{{ tag: \"{s}\", {s}: {s} }}", .{ name, name, value }) catch unreachable,
            // `Output`, not an anonymous object — a cs handler's return type
            // is the declared Output struct, and `new {…}` cannot convert.
            .cs => std.fmt.allocPrint(alloc, "new Output {{ tag = \"{s}\", {s} = {s} }}", .{ name, csPayloadMember(alloc, name), value }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, ".{{ .{s} = {s} }}", .{ esc_name, value }) catch unreachable,
        };
    }

    /// `| name` — a branch that carries nothing.
    pub fn branchEmpty(alloc: std.mem.Allocator, t: HostTarget, name: []const u8) []const u8 {
        const esc_name = escapeZigIdentifier(alloc, name) catch name;
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "{{ tag: \"{s}\", {s}: {{}} }}", .{ name, name }) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "new Output {{ tag = \"{s}\", {s} = new {{ }} }}", .{ name, csPayloadMember(alloc, name) }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, ".{{ .{s} = .{{}} }}", .{esc_name}) catch unreachable,
        };
    }

    /// `| name { a, b }` — a record payload. `body` is the already-joined field
    /// list in the host's own spelling, which `payloadPair` produces — cs's
    /// payload member is the generated `<name>_payload` struct nested in the
    /// event class WHEN the decl is a real record, so its pairs spell
    /// member-init `f = v` and the produce constructs `new <name>_payload
    /// { … }`, resolvable bare inside the handler the way `Output` is.
    /// `decl_fields` carries the arity rule the transform side enforces
    /// upstream: a single-field payload collapses to the value's own type
    /// (`__type_ref` identity, or no record at all), so a record decl has
    /// 2+ fields and any smaller count keeps the anonymous object — its
    /// member is `dynamic`.
    pub fn branchRec(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, body: []const u8, decl_fields: usize) []const u8 {
        const esc_name = escapeZigIdentifier(alloc, name) catch name;
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "{{ tag: \"{s}\", {s}: {{ {s} }} }}", .{ name, name, body }) catch unreachable,
            .cs => if (decl_fields >= 2)
                std.fmt.allocPrint(alloc, "new Output {{ tag = \"{s}\", {s} = new {s}_payload {{ {s} }} }}", .{ name, csPayloadMember(alloc, name), csMember(alloc, name), body }) catch unreachable
            else
                std.fmt.allocPrint(alloc, "new Output {{ tag = \"{s}\", {s} = new {{ {s} }} }}", .{ name, csPayloadMember(alloc, name), body }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, ".{{ .{s} = .{{ {s} }} }}", .{ esc_name, body }) catch unreachable,
        };
    }

    /// One `name = value` pair inside a record payload or argument object.
    pub fn recField(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        const esc_name = escapeZigIdentifier(alloc, name) catch name;
        // C# member-INIT position is as reserved as binding position: a field
        // named `new` writes `new = v` and CS1526s — the verbatim @-escape is
        // the spelling (`@new = v`), and the declared member is mangleCsIdent'd
        // the same way so the two sides agree.
        const cs_name = csMember(alloc, name);
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, value }) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "{s} = {s}", .{ cs_name, value }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, ".{s} = {s}", .{ esc_name, value }) catch unreachable,
        };
    }

    /// A handler's ARGUMENT object — `.{ … }` on Zig, `{ … }` on JS,
    /// `new { … }` on C# (an anonymous object — the dynamic-readable record).
    /// Not a branch: nothing is tagged, it is just the input record. `body` is
    /// the already-joined pair list from `recField`; empty for a no-arg call.
    pub fn argRec(alloc: std.mem.Allocator, t: HostTarget, body: []const u8) []const u8 {
        if (body.len == 0) return switch (t) {
            .js => "{}",
            .cs => "new { }",
            .zig => ".{}",
        };
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "{{ {s} }}", .{body}) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "new {{ {s} }}", .{body}) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, ".{{ {s} }}", .{body}) catch unreachable,
        };
    }

    /// A record-payload field pair. cs payloads construct the generated
    /// `<b>_payload` struct — member-init `f = v` — so every field count
    /// spells recField there; the tuple spelling is gone. js/zig spellings
    /// coincide at any count.
    pub fn payloadPair(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        return recField(alloc, t, name, value);
    }

    /// An ARM's record payload at its fire — zig `.{ … }`, js `{ … }`,
    /// cs `new <arm>_payload { … }` matching the struct-typed arm
    /// parameter (see `armParamCsType`) when the arm decl is a real record.
    /// `decl_fields` is the same arity rule `branchRec` carries: a
    /// single-field arm payload is the identity value, so a record arm
    /// decl has 2+ fields and any smaller count keeps the anonymous
    /// record. `body` is the already-joined `payloadPair` list; the text
    /// lands inside the arm's event class, where the nested payload
    /// struct resolves bare.
    pub fn armPayload(alloc: std.mem.Allocator, t: HostTarget, arm: []const u8, body: []const u8, decl_fields: usize) []const u8 {
        return switch (t) {
            .js, .zig => argRec(alloc, t, body),
            .cs => if (decl_fields >= 2)
                std.fmt.allocPrint(alloc, "new {s}_payload {{ {s} }}", .{ csMember(alloc, arm), body }) catch unreachable
            else
                argRec(alloc, t, body),
        };
    }

    /// The argument object at a SYNTHESIZED `<ev>_event.handler(…)` call site.
    /// C# handlers take the declared `Input` struct — `new <ns><ev>_event.Input
    /// { … }` — where JS's `{ … }` and Zig's `.{ … }` are literals; an
    /// anonymous `new { … }` (argRec's cs arm) has no conversion to `Input`.
    /// `ns`/`ev` are the same qualifier and basename the caller already wrote
    /// ahead of `_event.handler(`.
    pub fn callArg(alloc: std.mem.Allocator, t: HostTarget, ns: []const u8, ev: []const u8, body: []const u8) []const u8 {
        return switch (t) {
            .js, .zig => argRec(alloc, t, body),
            .cs => std.fmt.allocPrint(alloc, "new {s}{s}_event.Input {{ {s} }}", .{ ns, ev, body }) catch unreachable,
        };
    }

    /// A COLUMN-ORDINAL DISPATCH. The arms' statements are largely the same text
    /// on both hosts (`__koru_store_x.hp[__koru_r] = value_0;` needs no
    /// translation); what differs is the frame. Zig writes a switch EXPRESSION
    /// whose arms are `blk: { … break :blk v; }`, closed with `else =>
    /// unreachable`. JS writes a switch STATEMENT whose arms `return`, followed
    /// by a throw — falling out of a JS switch yields `undefined`, and the
    /// caller would read that as a branch object.
    pub fn switchHead(t: HostTarget) []const u8 {
        return switch (t) {
            .js, .cs => "switch (field) {\n",
            .zig => "return switch (field) {\n",
        };
    }

    pub fn switchArmOpen(alloc: std.mem.Allocator, t: HostTarget, ordinal: usize) []const u8 {
        return switch (t) {
            .js, .cs => std.fmt.allocPrint(alloc, "  case {d}: {{ ", .{ordinal}) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "    {d} => blk: {{ ", .{ordinal}) catch unreachable,
        };
    }

    pub fn switchArmClose(alloc: std.mem.Allocator, t: HostTarget, value: []const u8) []const u8 {
        return switch (t) {
            .js, .cs => std.fmt.allocPrint(alloc, "return {s}; }}\n", .{value}) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "break :blk {s}; }},\n", .{value}) catch unreachable,
        };
    }

    pub fn switchTail(alloc: std.mem.Allocator, t: HostTarget, unit: []const u8, store: []const u8) []const u8 {
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "}}\nthrow new Error(\"{s}: field index \" + field + \" is not a column of store '{s}'\");", .{ unit, store }) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "}}\nthrow new global::System.Exception(\"{s}: field index \" + field + \" is not a column of store '{s}'\");", .{ unit, store }) catch unreachable,
            .zig => "    else => unreachable,\n};",
        };
    }

    /// `row` arrives DENSE and is `usize` already — all targets bind it
    /// straight through, keeping one name for the statements above to share.
    pub fn rowHead(t: HostTarget) []const u8 {
        return switch (t) {
            .js => "const __koru_r = row;\n",
            .cs => "var __koru_r = row;\n",
            .zig => "const __koru_r: usize = row;\n",
        };
    }

    /// A COUNTED LOOP over `0..limit`, binding `cursor`. Zig's range-`for`,
    /// JS's `let`-clause, and C#'s `var`-clause are the same loop and share
    /// nothing textually.
    pub fn loopHead(alloc: std.mem.Allocator, t: HostTarget, cursor: []const u8, limit: []const u8) []const u8 {
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "for (let {s} = 0; {s} < {s}; {s}++) {{\n", .{ cursor, cursor, limit, cursor }) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "for (var {s} = 0; {s} < {s}; {s}++) {{\n", .{ cursor, cursor, limit, cursor }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "for (0..{s}) |{s}| {{\n", .{ limit, cursor }) catch unreachable,
        };
    }

    /// Bind a loop-local binding. Zig warns on an unused local, and a projected
    /// column the body never reads is normal, so the Zig arm carries the `_ = &x`
    /// discard. JS and C# have no such rule and the discard is a syntax error
    /// there.
    pub fn constBind(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        return switch (t) {
            .js => std.fmt.allocPrint(alloc, "const {s} = {s};\n", .{ name, value }) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "var {s} = {s};\n", .{ name, value }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "const {s} = {s};\n_ = &{s};\n", .{ name, value, name }) catch unreachable,
        };
    }

    /// A dense cursor used where the host expects a signed integer. Zig needs
    /// the cast; JS has one number type; C# casts the CLR way. `__koru_intcast`
    /// rather than `@intCast` on Zig: the cursor is `usize`, so release builds
    /// bitcast the sign flip instead of paying @intCast's in-loop `llvm.assume`.
    pub fn asI64(alloc: std.mem.Allocator, t: HostTarget, expr: []const u8) []const u8 {
        return switch (t) {
            .js => alloc.dupe(u8, expr) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "((long)({s}))", .{expr}) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "__koru_intcast(i64, {s})", .{expr}) catch unreachable,
        };
    }

    /// A dense cursor used as an INDEX. Same split, different target type.
    pub fn asIndex(alloc: std.mem.Allocator, t: HostTarget, expr: []const u8) []const u8 {
        return switch (t) {
            .js => alloc.dupe(u8, expr) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "((int)({s}))", .{expr}) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "__koru_intcast(usize, {s})", .{expr}) catch unreachable,
        };
    }
};

fn exprIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Is `text[at]` (a `&`) in PREFIX position — Zig address-of — rather than infix
/// bitwise-and? Prefix means nothing that could END an operand precedes it.
/// `a & b` is infix and means the same thing in both languages; `&items` is an
/// address JS does not have.
///
/// The one case a character test alone gets wrong is a preceding KEYWORD. In
/// `for (const x of &items)` the char before is `f`, which looks exactly like the
/// end of an identifier — but `of` cannot END an operand, it demands one. That is
/// the shape the `~[template]proc for|js` body renders for every `~for(&xs)` in the
/// corpus, so the scan reads back a whole WORD and asks what the word is.
fn exprPrefixPosition(text: []const u8, at: usize) bool {
    var j = at;
    while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
    if (j == 0) return true;
    const p = text[j - 1];
    if (!(exprIdentChar(p) or p == ')' or p == ']' or p == '}' or p == '"' or p == '\'')) return true;
    if (!exprIdentChar(p)) return false;
    var w = j;
    while (w > 0 and exprIdentChar(text[w - 1])) w -= 1;
    const operand_expecting = [_][]const u8{
        "of",     "in",   "return", "typeof", "case", "new",
        "delete", "void", "yield",  "await",  "instanceof",
    };
    for (operand_expecting) |kw| {
        if (std.mem.eql(u8, text[w..j], kw)) return true;
    }
    return false;
}

/// At `text[at] == '['`, is this the opening of a Zig ARRAY LITERAL type prefix
/// (`[_]i32{`, `[3]i32{`, `[2][2]i32{`)? Returns the index just past the `{` when
/// so. An ordinary INDEX (`arr[i]`) has no brace after the type slot.
fn exprArrayLiteralOpen(text: []const u8, at: usize) ?usize {
    var j = at;
    var dims: usize = 0;
    while (j < text.len and text[j] == '[') {
        const close = std.mem.indexOfScalarPos(u8, text, j, ']') orelse return null;
        if (std.mem.indexOfScalarPos(u8, text[0..close], j + 1, '[') != null) return null;
        j = close + 1;
        dims += 1;
    }
    if (dims == 0) return null;
    while (j < text.len and (exprIdentChar(text[j]) or text[j] == '.' or text[j] == '*' or text[j] == ' ')) j += 1;
    if (j >= text.len or text[j] != '{') return null;
    return j + 1;
}

/// At `text[at] == '{'` opening a `.{ … }`, are its top-level entries POSITIONAL
/// (`.{ 0, 0 }` — a tuple, i.e. a JS array) rather than NAMED (`.{ .ok = v }` — a
/// branch constructor, whose JS shape this lowering deliberately does not guess)?
/// An empty `.{}` counts as positional: it is the void payload.
fn exprPositionalTuple(text: []const u8, at: usize) bool {
    var j = at + 1;
    var depth: usize = 0;
    while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '(', '[', '{' => depth += 1,
            ')', ']' => depth -= 1,
            '}' => {
                if (depth == 0) return true;
                depth -= 1;
            },
            '.' => if (depth == 0 and j + 1 < text.len and exprIdentChar(text[j + 1])) return false,
            else => {},
        }
    }
    return true;
}

/// The C# arm, deliberately narrow — the K# vertical's vocabulary. Walk the
/// text once, leave string and char literals untouched, rewrite the tokens
/// C# cannot parse, and REFUSE the Zig builtins rather than guess a spelling:
/// the table is empty on purpose so an unmodelled operation fails here, loud,
/// instead of reaching csc as plausible text. C# has no `$` in identifiers
/// but does have `@`-verbatim names, so a reserved binding mangles to `@name`.
///
/// What is NOT lowered yet — by design of the vertical, not oversight: `if
/// (c) a else b` (Koru ternary, needs `c ? a : b`), typed decls `var x: T`,
/// `.{…}` struct literals, `[…]` array literals, `&` prefix. All produce
/// text csc rejects, so they fail loud one stage down — but they are
/// compile errors at dotnet build, not emission refusals, and the distance
/// between those is the honest gap a real port closes next.
fn lowerCsInto(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    mode: ExprMode,
    diag: ?*LowerDiag,
) LowerError!void {
    var i: usize = 0;
    var quote: ?u8 = null;
    // One entry per open `[` we are inside, saying whether its closer must be
    // written as `}` — the decision the literal-position `new dynamic[] {`
    // rewrite makes at the opener has to survive to the matching `]`.
    var bracket_is_literal: [64]bool = undefined;
    var bracket_depth: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (quote) |q| {
            if (c == '\\' and i + 1 < text.len) {
                try out.appendSlice(allocator, text[i .. i + 2]);
                i += 2;
                continue;
            }
            if (c == q) quote = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        // `++` is Koru's concatenation, spelled Zig's way — in C# it is the
        // increment operator, so `a ++ b` is a syntax error, not a wrong answer.
        // Host text is already C#, so its `++` is a genuine increment and stays.
        if (mode != .host_text and c == '+' and i + 1 < text.len and text[i + 1] == '+') {
            try out.append(allocator, '+');
            i += 2;
            continue;
        }
        // `and`/`or` word-boundary anchored — `android`, `.or_else` untouched.
        // `==`/`!=`/`%` pass through by C#'s OWN semantics: C# string == is
        // value equality (Koru's meaning — the hole the .zig arm patches is
        // absent), and C# % is truncated remainder, the C-parity choice
        // comptime_eval already folds.
        if ((c == 'a' or c == 'o') and (i == 0 or (!exprIdentChar(text[i - 1]) and text[i - 1] != '.'))) {
            const word: ?[]const u8 = if (std.mem.startsWith(u8, text[i..], "and"))
                "&&"
            else if (std.mem.startsWith(u8, text[i..], "or"))
                "||"
            else
                null;
            if (word) |cs_op| {
                const len: usize = if (cs_op[0] == '&') 3 else 2;
                if (i + len >= text.len or !exprIdentChar(text[i + len])) {
                    try out.appendSlice(allocator, cs_op);
                    i += len;
                    continue;
                }
            }
        }
        // `.len` — the member JavaScript patched onto prototypes; C# has no
        // such escape hatch, so the lowering rewrites to `.Length`. `x.len()`
        // becomes `x.Length()` — a compile error one stage down, still loud.
        // The lookahead is bounds-guarded: an expr ENDING in `.len` lowers
        // too (store rewrites mint `__koru_store_<name>.len` placeholders).
        // EXEMPTION: `__koru_store_<s>.len` is not a length expression — `len`
        // is a real field the cell class declares, and `.Length` would name a
        // member that does not exist (690_073's sweep bound read).
        var store_cell_len = false;
        if (c == '.' and i + 3 < text.len and
            std.mem.eql(u8, text[i + 1 .. i + 4], "len") and
            (i + 4 >= text.len or !exprIdentChar(text[i + 4])))
        {
            var j = i;
            while (j > 0 and exprIdentChar(text[j - 1])) j -= 1;
            store_cell_len = std.mem.startsWith(u8, text[j..i], "__koru_store_");
            if (!store_cell_len) {
                try out.appendSlice(allocator, ".Length");
                i += 4;
                continue;
            }
        }
        // Zig builtins: the cs table lives in `lowerCsBuiltin` — a real cast
        // and Math.* spellings, not the JS arm's paren-wraps. C# has no
        // `@name(` call syntax, so a `@` here is a genuine builtin in either
        // mode; a non-call `@` (host text) falls through verbatim.
        if (c == '@') {
            if (try lowerCsBuiltin(out, allocator, text, i, diag)) |after| {
                i = after;
                continue;
            }
        }
        // Zig ADDRESS-OF in prefix position. C# records and arrays are heap
        // references already, so `&x` lowers to `x` — the same identity the
        // JS arm takes. `&scalar` at a call boundary is the `__KoruBox`
        // write-back in emitInvocationWithContinuations; anywhere else it
        // snapshots, and a `.data` read on it fails LOUDLY, not wrongly.
        // `&&` keeps both chars — the second `&` reads as prefix position
        // to exprPrefixPosition and must not be erased. An INFIX `&` is
        // bitwise-and in both languages.
        if (c == '&' and exprPrefixPosition(text, i) and
            (i + 1 >= text.len or text[i + 1] != '&'))
        {
            i += 1;
            continue;
        }
        // Kebab ident fold, koru_expr only: an unspaced `-` between ident
        // chars is a Koru name joiner (`pos-tempo` → `pos_tempo`), never
        // subtraction — same rule as ZigExprParser.parseIdentName and the
        // zig emitter's writeBinding. Host text's `-` is genuine C#
        // arithmetic and stays.
        if (mode == .koru_expr and c == '-' and i > 0 and i + 1 < text.len and
            exprIdentChar(text[i - 1]) and exprIdentChar(text[i + 1]))
        {
            try out.append(allocator, '_');
            i += 1;
            continue;
        }
        // Zig optional-unwrap `.?`. On `dynamic` the operand is already
        // null-or-value, so the suffix is identity and drops out
        // (`e.? == x` → `e == x`, 320_147). Runs in BOTH modes: `.?` is
        // never valid C# — `?.`/`??` spell the real operators in a
        // different order — so host text authored `.?` can only be a Koru
        // unwrap spliced into template text.
        if (c == '.' and i + 1 < text.len and text[i + 1] == '?') {
            i += 2;
            continue;
        }
        // Koru LIST literal `[a, b]`: passed verbatim, C# reads a collection
        // expression — legal only where a target type exists, and
        // `foreach (var x in […])` supplies none (CS9176). In LITERAL
        // position — no operand closer precedes — spell `new dynamic[] {…}`:
        // `dynamic[]` iterates, indexes, and reads `.Length` everywhere a
        // Koru list can appear. An index/slice `[` (after an identifier,
        // `)`, `]`, a quote, or a digit — all inside exprIdentChar or the
        // closer set) stays verbatim. `.koru_expr` only: in host text `[` is
        // a genuine C# collection expression or attribute the author chose.
        if (mode == .koru_expr and c == '[') {
            // Zig inferred-length array literal `[_]T{...}` — a typed list
            // literal: `new T[] { ... }`. Seen before the operand-closes
            // check because `[_` always reads literal-position (after `=`,
            // `(`, `,`) and would otherwise emit `new dynamic[] {_}T{…}`.
            if (i + 2 < text.len and text[i + 1] == '_' and text[i + 2] == ']') {
                var t_end = i + 3;
                while (t_end < text.len and text[t_end] != '{') t_end += 1;
                if (t_end < text.len) {
                    try out.appendSlice(allocator, "new ");
                    try out.appendSlice(allocator, csType(std.mem.trim(u8, text[i + 3 .. t_end], " \t")));
                    try out.appendSlice(allocator, "[] {");
                    i = t_end + 1;
                    continue;
                }
            }
            var l = out.items.len;
            while (l > 0 and std.ascii.isWhitespace(out.items[l - 1])) l -= 1;
            const operand_closes = l > 0 and
                (exprIdentChar(out.items[l - 1]) or out.items[l - 1] == ')' or
                    out.items[l - 1] == ']' or out.items[l - 1] == '"' or
                    out.items[l - 1] == '\'' or out.items[l - 1] == '.');
            if (bracket_depth < bracket_is_literal.len) {
                bracket_is_literal[bracket_depth] = !operand_closes;
                bracket_depth += 1;
                if (!operand_closes) {
                    try out.appendSlice(allocator, "new dynamic[] {");
                    i += 1;
                    continue;
                }
            }
        }
        if (c == ']' and bracket_depth > 0) {
            bracket_depth -= 1;
            if (bracket_is_literal[bracket_depth]) {
                try out.append(allocator, '}');
                i += 1;
                continue;
            }
        }
        // RESERVED-WORD rename — `.koru_expr` only, same rule as the JS arm:
        // in `.host_text` the words are GENUINE C# (`return`, `if (…)`) and
        // renaming them would destroy working host code. Anchored to ident
        // start: a non-match emits one char and re-enters, so without the
        // anchor `read_ref` splits at `_` and `ref` escapes mid-identifier
        // (`__koru_read_@ref` — 690_242's CS1003). `.` is not an ident char,
        // so member names still escape (`a.ref` → `a.@ref`).
        if (mode == .koru_expr and (c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) and
            (i == 0 or !exprIdentChar(text[i - 1]))) {
            var w = i;
            while (w < text.len and exprIdentChar(text[w])) w += 1;
            const word = text[i..w];
            if (isCsReserved(word)) {
                try out.append(allocator, '@');
                try out.appendSlice(allocator, word);
                i = w;
                continue;
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
}

/// The JS arm: walk the text once, leave string and char literals untouched, and
/// rewrite the constructs JavaScript cannot parse.
fn lowerJsInto(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    mode: ExprMode,
    diag: ?*LowerDiag,
) LowerError!void {
    var i: usize = 0;
    var quote: ?u8 = null;
    // One entry per open `{` we are inside, saying whether its closer must be
    // written as `]`. A Zig ARRAY literal opens with a brace and closes with one;
    // JavaScript's opens and closes with brackets, so the decision made at the
    // opener has to survive to the matching closer.
    var brace_is_bracket: [64]bool = undefined;
    var brace_depth: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (quote) |q| {
            if (c == '\\' and i + 1 < text.len) {
                try out.appendSlice(allocator, text[i .. i + 2]);
                i += 2;
                continue;
            }
            if (c == q) quote = null;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        // `++` is Koru's concatenation, spelled Zig's way. In JavaScript it is the
        // increment operator, so an unlowered `a ++ b` is a SYNTAX error rather
        // than a wrong answer. Host text is already JavaScript, so its `++` is a
        // genuine increment and stays.
        if (mode != .host_text and c == '+' and i + 1 < text.len and text[i + 1] == '+') {
            try out.append(allocator, '+');
            i += 2;
            continue;
        }
        // `and`/`or` are word-boundary anchored, so `android` and `.or_else` are
        // untouched. Lowered in BOTH modes — see `ExprMode`.
        if ((c == 'a' or c == 'o') and (i == 0 or (!exprIdentChar(text[i - 1]) and text[i - 1] != '.'))) {
            const word: ?[]const u8 = if (std.mem.startsWith(u8, text[i..], "and"))
                "&&"
            else if (std.mem.startsWith(u8, text[i..], "or"))
                "||"
            else
                null;
            if (word) |js_op| {
                const len: usize = if (js_op[0] == '&') 3 else 2;
                if (i + len >= text.len or !exprIdentChar(text[i + len])) {
                    try out.appendSlice(allocator, js_op);
                    i += len;
                    continue;
                }
            }
        }
        if (c == '@') {
            if (try lowerBuiltin(out, allocator, text, i, diag)) |after| {
                i = after;
                continue;
            }
        }
        // Inline conditional EXPRESSION — `if (c) a else b`. Koru spells the
        // ternary exactly as Zig does; JavaScript needs `c ? a : b`, and
        // without this the `if`/`else` fall through to the reserved-word
        // rename below and surface as `if$`/`else$` — a syntax error in the
        // emitted file (390_120).
        //
        // Koru modes only: in `.host_text` a bare `if` is a real JavaScript
        // statement (`if (x) return y;`) and must pass through. A `(`-conditioned
        // `if` whose next token is `{` is a STATEMENT in the Koru modes too —
        // `if (c) {…} else {…}` inside a kernel op body — and is left alone.
        if (mode != .host_text and c == 'i') {
            if (try jsInlineIf(out, allocator, text, i, mode, diag)) |after| {
                i = after;
                continue;
            }
        }
        // Typed DECLARATION — `var nx: f64 = 0.0`, `const p: *Frame<frame> = …`.
        // Koru statement text (kernel op bodies) is Zig-shaped; the `: type`
        // annotation has no JS spelling and arrived verbatim as a syntax error
        // (390_120). The keyword + ident + `:` shape is required — a bare `x: 1`
        // arg label or object literal cannot reach this arm.
        if (mode != .host_text and (c == 'v' or c == 'c' or c == 'l')) {
            if (try jsTypedDecl(out, allocator, text, i)) |after| {
                i = after;
                continue;
            }
        }
        // A BINDING REFERENCE that JavaScript cannot spell. `! updated { old,
        // new }` binds `new`, and the arm's own expression reads it back:
        // `board.pool + new - old`. Renaming the declaration and not this would
        // trade a syntax error for an undefined name, which is worse.
        //
        // `.koru_expr` ONLY. In `.host_text` the words are GENUINE JavaScript —
        // `new Foo()`, `typeof x`, `return` — and renaming them would destroy
        // working host code. Same discipline, and the same reason, as `++`.
        //
        // Word-boundary anchored and never after a `.`, so `x.new` (a property
        // key, legal in JS and written unmangled by the transforms) is untouched.
        if (mode == .koru_expr and exprIdentChar(c) and !(c >= '0' and c <= '9') and
            (i == 0 or (!exprIdentChar(text[i - 1]) and text[i - 1] != '.' and text[i - 1] != '@')))
        {
            var e = i;
            while (e < text.len and (exprIdentChar(text[e]) or text[e] == '$')) e += 1;
            const word = text[i..e];
            if (needsJsMangle(word)) {
                try out.appendSlice(allocator, word);
                try out.append(allocator, '$');
                i = e;
                continue;
            }
        }
        // ZIG-SHAPED EXPRESSION TEXT, lowered in BOTH modes — unlike `++` and
        // `and`/`or`, which are real JavaScript and must stay `.koru_expr`-only.
        // Neither shape below has ANY valid JavaScript reading, so neither can
        // misfire on genuine host text.
        //
        // Zig ADDRESS-OF in prefix position. A JS array or object IS a reference,
        // so taking its address is the identity. An INFIX `&` is bitwise-and in
        // both languages and is left alone — position is the whole discriminator.
        if (c == '&' and exprPrefixPosition(text, i)) {
            i += 1;
            continue;
        }
        // Zig WRAPPING operators `*%` `+%` `-%`. The JS int model is a double,
        // and the neighbouring bitwise ops (`^`, `&`, `|`) already coerce to
        // i32 — so `Math.imul` is the bit-exact spelling of `*%` here and the
        // `| 0` coercion is `+%`/`-%`. Without this the spelling leaks verbatim
        // and the emitted file is a syntax error, not a wrong answer.
        if ((c == '*' or c == '+' or c == '-') and i + 1 < text.len and text[i + 1] == '%') {
            if (try jsWrapOp(out, allocator, text, i, diag)) |after| {
                i = after;
                continue;
            }
        }
        // Zig ARRAY literal: `[_]i32{1, 2, 3}`. The type prefix has no JS
        // counterpart and the braces become brackets.
        if (c == '[') {
            if (exprArrayLiteralOpen(text, i)) |after_brace| {
                if (brace_depth < brace_is_bracket.len) {
                    brace_is_bracket[brace_depth] = true;
                    brace_depth += 1;
                    try out.append(allocator, '[');
                    i = after_brace;
                    continue;
                }
            }
        }
        // Anonymous POSITIONAL tuple: `.{ 0, 0 }`. Only the positional form —
        // `.{ .ok = v }` is a BRANCH constructor whose JS shape is
        // `{ tag: "ok", ok: v }`, and quietly lowering it to a plain object would
        // produce a wrong answer rather than a syntax error. That one stays raw.
        if (c == '.' and i + 1 < text.len and text[i + 1] == '{' and exprPositionalTuple(text, i + 1)) {
            if (brace_depth < brace_is_bracket.len) {
                brace_is_bracket[brace_depth] = true;
                brace_depth += 1;
                try out.append(allocator, '[');
                i += 2;
                continue;
            }
        }
        if (c == '{' and brace_depth < brace_is_bracket.len) {
            brace_is_bracket[brace_depth] = false;
            brace_depth += 1;
        }
        if (c == '}' and brace_depth > 0) {
            brace_depth -= 1;
            try out.appendSlice(allocator, if (brace_is_bracket[brace_depth]) "]" else "}");
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
}

/// Operand capture for the `*%` `+%` `-%` lowerings in `lowerJsInto`.
/// `text[at]` is the operator's first character (the `%` follows it). The LHS
/// sits at the END of `out` — already appended — and is pulled back off; the
/// RHS is the next term in `text`. A term is a balanced `(...)`/`[...]`/`{...}`
/// group or an atom: identifier/dotted path, numeric literal, or a call.
/// Returns the source index just past the RHS, or null when either side is not
/// a shape this can capture — the op then falls through verbatim, a loud syntax
/// error downstream rather than a silent wrong answer.
fn jsWrapOp(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize,
    diag: ?*LowerDiag,
) LowerError!?usize {
    // --- LHS: trailing operand of the already-emitted text.
    var l = out.items.len;
    while (l > 0 and std.ascii.isWhitespace(out.items[l - 1])) l -= 1;
    if (l == 0) return null;
    const l_end = l;
    const last = out.items[l - 1];
    if (last == ')' or last == ']' or last == '}') {
        const open: u8 = switch (last) {
            ')' => '(',
            ']' => '[',
            '}' => '{',
            else => unreachable,
        };
        var depth: usize = 0;
        while (l > 0) {
            l -= 1;
            const ch = out.items[l];
            if (ch == last) depth += 1;
            if (ch == open) {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (depth != 0) return null;
    } else if (exprIdentChar(last) or last == '.') {
        while (l > 0 and (exprIdentChar(out.items[l - 1]) or out.items[l - 1] == '.')) l -= 1;
    } else return null;
    const lhs = try allocator.dupe(u8, out.items[l..l_end]);
    defer allocator.free(lhs);
    out.shrinkRetainingCapacity(l);

    // --- RHS: next term in the source text.
    var j = at + 2;
    while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
    if (j >= text.len) return null;
    var r_end = j;
    if (text[j] == '(' or text[j] == '[' or text[j] == '{') {
        var depth: usize = 0;
        while (r_end < text.len) {
            const ch = text[r_end];
            if (ch == '"' or ch == '\'' or ch == '`') {
                r_end = jsSkipQuoted(text, r_end);
                continue;
            }
            if (ch == '(' or ch == '[' or ch == '{') depth += 1;
            if (ch == ')' or ch == ']' or ch == '}') {
                depth -= 1;
                if (depth == 0) {
                    r_end += 1;
                    break;
                }
            }
            r_end += 1;
        }
        if (depth != 0) return null;
    } else {
        while (r_end < text.len and (exprIdentChar(text[r_end]) or text[r_end] == '.' or text[r_end] == '@')) r_end += 1;
        // An atom followed by `(` is a call — take the balanced group too.
        if (r_end < text.len and text[r_end] == '(') {
            var depth: usize = 0;
            var k = r_end;
            while (k < text.len) {
                const ch = text[k];
                if (ch == '"' or ch == '\'' or ch == '`') {
                    k = jsSkipQuoted(text, k);
                    continue;
                }
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        k += 1;
                        break;
                    }
                }
                k += 1;
            }
            if (depth != 0) return null;
            r_end = k;
        }
    }
    if (r_end == j) return null;

    if (text[at] == '*') {
        try out.appendSlice(allocator, "Math.imul(");
        try out.appendSlice(allocator, lhs);
        try out.appendSlice(allocator, ", ");
        try lowerJsInto(out, allocator, text[j..r_end], .koru_expr, diag);
        try out.append(allocator, ')');
    } else {
        try out.appendSlice(allocator, "((");
        try out.appendSlice(allocator, lhs);
        try out.append(allocator, text[at]);
        try lowerJsInto(out, allocator, text[j..r_end], .koru_expr, diag);
        try out.appendSlice(allocator, ") | 0)");
    }
    return r_end;
}

/// Skip a quoted literal opening at `text[i]` (`"`, `'`, or backtick).
/// Returns the index just past the closer, or `text.len` if unterminated.
fn jsSkipQuoted(text: []const u8, i: usize) usize {
    const q = text[i];
    var j = i + 1;
    while (j < text.len) {
        if (text[j] == '\\') {
            j += 2;
            continue;
        }
        if (text[j] == q) return j + 1;
        j += 1;
    }
    return text.len;
}

/// Word at `text[at]` — boundary-checked on both sides, so `ifdef` and
/// `x.if` never match. `wlen` is the word's length.
fn jsWordAt(text: []const u8, at: usize, comptime word: []const u8) bool {
    if (!std.mem.startsWith(u8, text[at..], word)) return false;
    if (at + word.len < text.len and exprIdentChar(text[at + word.len])) return false;
    if (at > 0 and (exprIdentChar(text[at - 1]) or text[at - 1] == '.')) return false;
    return true;
}

/// Lower the inline conditional expression `if (c) a else b` starting at
/// `text[at] == 'i'` to `(c ? a : b)`, returning the index just past it —
/// or null when the `if` is not that shape (a statement `if (c) {…}`, an
/// unparenthesised condition, a missing `else`, an identifier tail). All
/// three spans re-enter `lowerJsInto`, so nested forms (`else if` chains,
/// an if-expression inside a branch) lower recursively.
///
/// The matching `else` is found by counting nested if-expressions at
/// paren-depth 0: each needs its own `else`, so a depth-0 `else` with
/// pending ifs belongs to the innermost one. The else-branch ends at the
/// first depth-0 `,` `)` `]` `}` `;` — the delimiters an expression text is
/// embedded in — or at end of input.
fn jsInlineIf(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize,
    mode: ExprMode,
    diag: ?*LowerDiag,
) LowerError!?usize {
    if (!jsWordAt(text, at, "if")) return null;
    var j = at + 2;
    while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
    if (j >= text.len or text[j] != '(') return null;
    const cond_open = j;

    var depth: usize = 0;
    var k = j;
    while (k < text.len) {
        const ch = text[k];
        if (ch == '"' or ch == '\'' or ch == '`') {
            k = jsSkipQuoted(text, k);
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) break;
        }
        k += 1;
    }
    if (k >= text.len or depth != 0) return null;
    const cond_close = k;

    var m = cond_close + 1;
    while (m < text.len and std.ascii.isWhitespace(text[m])) m += 1;
    if (m >= text.len or text[m] == '{') return null;

    var pending: usize = 0;
    var else_at: ?usize = null;
    k = m;
    depth = 0;
    scan: while (k < text.len) {
        const ch = text[k];
        if (ch == '"' or ch == '\'' or ch == '`') {
            k = jsSkipQuoted(text, k);
            continue;
        }
        switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}', ',', ';' => {
                if (depth == 0) return null; // the expression ended before any else
                if (ch != ',' and ch != ';') depth -= 1;
            },
            else => {
                if (depth == 0 and jsWordAt(text, k, "if")) {
                    var n = k + 2;
                    while (n < text.len and std.ascii.isWhitespace(text[n])) n += 1;
                    if (n < text.len and text[n] == '(') {
                        pending += 1;
                        k += 2;
                        continue :scan;
                    }
                }
                if (depth == 0 and jsWordAt(text, k, "else")) {
                    if (pending == 0) {
                        else_at = k;
                        break :scan;
                    }
                    pending -= 1;
                    k += 4;
                    continue :scan;
                }
            },
        }
        k += 1;
    }
    const else_pos = else_at orelse return null;

    k = else_pos + 4;
    depth = 0;
    while (k < text.len) {
        const ch = text[k];
        if (ch == '"' or ch == '\'' or ch == '`') {
            k = jsSkipQuoted(text, k);
            continue;
        }
        switch (ch) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ',', ';' => if (depth == 0) break,
            else => {},
        }
        k += 1;
    }

    try out.append(allocator, '(');
    try lowerJsInto(out, allocator, text[cond_open + 1 .. cond_close], mode, diag);
    try out.appendSlice(allocator, " ? ");
    try lowerJsInto(out, allocator, text[m..else_pos], mode, diag);
    try out.appendSlice(allocator, " : ");
    try lowerJsInto(out, allocator, text[else_pos + 4 .. k], mode, diag);
    try out.append(allocator, ')');
    return k;
}

/// Lower a typed declaration `var|const|let name: T = …` starting at
/// `text[at]` by emitting `kw name` and resuming at the initializer's `=`
/// (or the `;`/newline ending a bare decl). Returns null when the word is
/// not followed by `ident :` — arg labels, object keys, destructuring, and
/// `for (const x of …)` all fail the shape and pass through.
///
/// The annotation scan tracks bracket depth so `*Frame<frame>` and slice
/// types don't confuse the `=`/`;` search, and refuses `=` characters that
/// are really `==`, `=>`, `<=`, `>=`, `!=` (never legal in a type anyway —
/// the refusal just keeps a weird annotation verbatim instead of
/// half-eaten).
fn jsTypedDecl(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize,
) LowerError!?usize {
    inline for (.{ "var", "const", "let" }) |kw| {
        if (jsWordAt(text, at, kw)) {
            var j = at + kw.len;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            if (j >= text.len or !exprIdentChar(text[j]) or (text[j] >= '0' and text[j] <= '9')) return null;
            while (j < text.len and exprIdentChar(text[j])) j += 1;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            if (j >= text.len or text[j] != ':') return null;
            if (j + 1 < text.len and (text[j + 1] == ':' or text[j + 1] == '=')) return null;

            try out.appendSlice(allocator, text[at..j]);
            var depth: usize = 0;
            var k = j + 1;
            while (k < text.len) {
                const ch = text[k];
                if (ch == '"' or ch == '\'' or ch == '`') {
                    k = jsSkipQuoted(text, k);
                    continue;
                }
                switch (ch) {
                    '(', '[', '{', '<' => depth += 1,
                    ')', ']', '}', '>' => {
                        if (depth == 0) return null;
                        depth -= 1;
                    },
                    '=' => {
                        const next_eq = k + 1 < text.len and (text[k + 1] == '=' or text[k + 1] == '>');
                        const prev_cmp = k > 0 and (text[k - 1] == '<' or text[k - 1] == '>' or text[k - 1] == '!' or text[k - 1] == '=');
                        if (depth == 0 and !next_eq and !prev_cmp) return k;
                    },
                    ';', '\n' => if (depth == 0) return k,
                    else => {},
                }
                k += 1;
            }
            return null;
        }
    }
    return null;
}

/// `$mod.` → bare, for `|js` proc bodies. A `.kjs` facet's module-level host
/// lines emit as file-scope JS, so the sanctioned `$mod.X` spelling resolves
/// to plain `X` under every lowering — the decl-site `handler` and the
/// inline-splice paths alike. The JS twin of `rewriteModToBare`
/// (emitter_helpers.zig), kept here rather than imported: emitter_helpers is
/// the Zig CodeEmitter's module, and this file is where the JS vocabulary
/// lives. Quote- and comment-aware (JS has block comments, which the Zig twin
/// never meets).
pub fn jsModBare(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, body.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var q: u8 = 0;
    while (i < body.len) {
        const c = body[i];
        if (q != 0) {
            try out.append(allocator, c);
            if (c == '\\') {
                if (i + 1 < body.len) try out.append(allocator, body[i + 1]);
                i += 2;
                continue;
            }
            if (c == q) q = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            q = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            while (i < body.len and body[i] != '\n') : (i += 1) try out.append(allocator, body[i]);
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
            try out.appendSlice(allocator, "/*");
            i += 2;
            while (i < body.len and !(body[i] == '*' and i + 1 < body.len and body[i + 1] == '/')) : (i += 1) {
                try out.append(allocator, body[i]);
            }
            if (i < body.len) {
                try out.appendSlice(allocator, "*/");
                i += 2;
            }
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], "$mod.") and
            (i == 0 or !exprIdentChar(body[i - 1])))
        {
            i += "$mod.".len;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// THE VOCABULARY — twice. `lowerBuiltin` (js) and `lowerCsBuiltin` (cs) each
/// lower one `@`-operation starting at `text[at] == '@'`, returning the index
/// just past it, or null when the `@` does not open a call at all (so the
/// caller writes it through unchanged).
///
/// Every operation Koru names with an `@` is listed in the target's table,
/// and an operation that is not listed is REFUSED rather than passed through.
/// That refusal is the only reason each list is a definition instead of a
/// description.
///
/// The C# host spelling of a declared Koru type — shared by the cs emitter's
/// Input/Output/arm surfaces AND this file's `@as` lowering, so the two can
/// never drift on what `i64` means. `usize` concretizes `long`: a Koru usize
/// is unsigned, but `ulong` refuses arithmetic and comparison against every
/// signed type on this host (the tranche's int+ulong binder deaths), and C#
/// indexes and lengths are signed by convention. Unknown spellings → dynamic:
/// the escape-hatch type, not a claim about the type.
pub fn csType(koru_type: []const u8) []const u8 {
    const pairs = [_][2][]const u8{
        .{ "i64", "long" },      .{ "i32", "int" },    .{ "i16", "short" },
        .{ "i8", "sbyte" },      .{ "u64", "ulong" },  .{ "u32", "uint" },
        .{ "u16", "ushort" },    .{ "u8", "byte" },    .{ "f64", "double" },
        .{ "f32", "float" },     .{ "bool", "bool" },  .{ "string", "string" },
        .{ "char", "char" },     .{ "usize", "long" },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, koru_type, p[0])) return p[1];
    }
    return "dynamic";
}

/// The cs arm's builtin table — `lowerBuiltin`'s twin, but C# is a statically
/// typed host, so the JS spellings don't transplant: casts carry their type
/// (`@as` → `(T)(x)`), math goes through `System.Math`, and `@panic` needs a
/// thrown delegate because C# `throw` is not a general expression. Same
/// refusal contract: unknown name → UnsupportedBuiltin with diag set.
fn lowerCsBuiltin(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize,
    diag: ?*LowerDiag,
) LowerError!?usize {
    var p = at + 1;
    while (p < text.len and exprIdentChar(text[p])) p += 1;
    const name = text[at + 1 .. p];
    if (name.len == 0) return null;
    if (p >= text.len or text[p] != '(') return null;

    // Balanced-paren scan, top-level comma split — `lowerBuiltin`'s shape.
    const args_start = p + 1;
    var depth: usize = 1;
    var j = args_start;
    var split: ?usize = null;
    while (j < text.len and depth > 0) : (j += 1) {
        switch (text[j]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => if (depth == 1 and split == null) {
                split = j;
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    const args_end = j - 1;
    const first = std.mem.trim(u8, text[args_start .. split orelse args_end], " \t");
    const second = if (split) |s| std.mem.trim(u8, text[s + 1 .. args_end], " \t") else "";

    const eql = std.mem.eql;
    // Type-carrying casts: the JS paren-wrap is a no-op there, but on this
    // host the cast is the lowering — `@as(i64, x)` → `(long)(x)`.
    if (eql(u8, name, "as") or eql(u8, name, "enumFromInt")) {
        try out.append(allocator, '(');
        try out.appendSlice(allocator, csType(first));
        try out.appendSlice(allocator, ")(");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
    }
    // `@bitCast` with no spelled target: the integer lanes reinterpret
    // bit-identically through a `long`/`ulong` round-trip (`(long)(ulong)x`
    // is the 64-bit move; narrower ints truncate the same bits a bitCast
    // would keep). Float bitcasts would need BitConverter — no site yet.
    if (eql(u8, name, "bitCast")) {
        try out.appendSlice(allocator, "(long)((ulong)(");
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    // Casts WITHOUT a spelled target: Zig infers it from context, C# cannot,
    // so emit the bare grouping — the enclosing construct's own cast (`@as`,
    // the typed-Input `(<T>)(…)`) is where the conversion lands. Inventing a
    // width here would be a silent-truncation bug, not a lowering.
    if (eql(u8, name, "intCast") or eql(u8, name, "truncate") or
        eql(u8, name, "floatFromInt") or eql(u8, name, "intFromEnum") or
        eql(u8, name, "floatCast"))
    {
        try out.append(allocator, '(');
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
    }
    const unary_wrapped = [_]struct { name: []const u8, prefix: []const u8, suffix: []const u8 }{
        // A bool is 0/1 — the ternary; Convert.ToInt32 unboxes oddly under dynamic.
        .{ .name = "intFromBool", .prefix = "((", .suffix = ") ? 1 : 0)" },
        // Zig's @intFromFloat truncates toward zero; a C# `long` cast does too.
        .{ .name = "intFromFloat", .prefix = "(long)(", .suffix = ")" },
        // Hardware popcount exists — System.Numerics is the tight-layer API.
        .{ .name = "popCount", .prefix = "global::System.Numerics.BitOperations.PopCount((ulong)(", .suffix = "))" },
        .{ .name = "exp2", .prefix = "global::System.Math.Pow(2, ", .suffix = ")" },
    };
    for (unary_wrapped) |uw| {
        if (eql(u8, name, uw.name)) {
            try out.appendSlice(allocator, uw.prefix);
            try lowerCsInto(out, allocator, first, .koru_expr, diag);
            try out.appendSlice(allocator, uw.suffix);
            return j;
        }
    }
    if (eql(u8, name, "divTrunc") or eql(u8, name, "divExact")) {
        // C# `/` on integers truncates toward zero — @divTrunc for free.
        // @divExact's no-remainder contract is asserted on the Zig lane; like
        // the JS arm we emit the bare division (same honesty bound).
        try out.appendSlice(allocator, "((");
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") / (");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    if (eql(u8, name, "divFloor")) {
        try out.appendSlice(allocator, "global::System.Math.Floor((");
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") / (double)(");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    if (eql(u8, name, "rem")) {
        try out.appendSlice(allocator, "((");
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") % (");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    if (eql(u8, name, "mod")) {
        // Euclidean: Zig's @mod is non-negative for a positive divisor, C#'s %
        // keeps the dividend's sign — same double-application the JS arm uses.
        try out.appendSlice(allocator, "((((");
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") % (");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, ")) + (");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, ")) % (");
        try lowerCsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    const math_map = [_]struct { name: []const u8, member: []const u8 }{
        .{ .name = "min", .member = "Min" },       .{ .name = "max", .member = "Max" },
        .{ .name = "abs", .member = "Abs" },       .{ .name = "sqrt", .member = "Sqrt" },
        .{ .name = "sin", .member = "Sin" },       .{ .name = "cos", .member = "Cos" },
        .{ .name = "tan", .member = "Tan" },       .{ .name = "exp", .member = "Exp" },
        .{ .name = "log", .member = "Log" },       .{ .name = "log2", .member = "Log2" },
        .{ .name = "log10", .member = "Log10" },   .{ .name = "floor", .member = "Floor" },
        .{ .name = "ceil", .member = "Ceiling" },  .{ .name = "trunc", .member = "Truncate" },
    };
    for (math_map) |m| {
        if (eql(u8, name, m.name)) {
            try out.appendSlice(allocator, "global::System.Math.");
            try out.appendSlice(allocator, m.member);
            try out.append(allocator, '(');
            try lowerCsInto(out, allocator, first, .koru_expr, diag);
            if (split != null) {
                try out.appendSlice(allocator, ", ");
                try lowerCsInto(out, allocator, second, .koru_expr, diag);
            }
            try out.append(allocator, ')');
            return j;
        }
    }

    // ABORT WITH A MESSAGE. `throw` is an expression in only a few C# slots,
    // so the IIFE spelling the JS arm invented is the portable one — a thrown
    // delegate call sits in any value position.
    if (eql(u8, name, "panic")) {
        try out.appendSlice(allocator, "((global::System.Func<dynamic>)(() => { throw new global::System.Exception(\"\" + (");
        try lowerCsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ")); }))()");
        return j;
    }

    if (diag) |d| d.unknown_builtin = name;
    return LowerError.UnsupportedBuiltin;
}

fn lowerBuiltin(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    at: usize,
    diag: ?*LowerDiag,
) LowerError!?usize {
    var p = at + 1;
    while (p < text.len and exprIdentChar(text[p])) p += 1;
    const name = text[at + 1 .. p];
    if (name.len == 0) return null;
    if (p >= text.len or text[p] != '(') return null;

    // Balanced-paren scan for the argument list, then split it at TOP-LEVEL
    // commas only — `@as(i64, @intCast(i))` nests.
    const args_start = p + 1;
    var depth: usize = 1;
    var j = args_start;
    var split: ?usize = null;
    while (j < text.len and depth > 0) : (j += 1) {
        switch (text[j]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => if (depth == 1 and split == null) {
                split = j;
            },
            else => {},
        }
    }
    if (depth != 0) return null; // unbalanced — not a call we can read
    const args_end = j - 1; // index of the closing ')'
    const first = std.mem.trim(u8, text[args_start .. split orelse args_end], " \t");
    const second = if (split) |s| std.mem.trim(u8, text[s + 1 .. args_end], " \t") else "";

    const eql = std.mem.eql;
    // Representation casts: JavaScript has ONE number type, so the cast is the
    // value. `@as`/`@enumFromInt` carry the type first, the value second.
    if (eql(u8, name, "as") or eql(u8, name, "enumFromInt") or eql(u8, name, "bitCast")) {
        try out.append(allocator, '(');
        try lowerJsInto(out, allocator, if (split != null) second else first, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
    }
    if (eql(u8, name, "intCast") or eql(u8, name, "truncate") or
        eql(u8, name, "floatFromInt") or eql(u8, name, "intFromEnum") or
        eql(u8, name, "floatCast"))
    {
        try out.append(allocator, '(');
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
    }
    // Single-arg builtins that differ only in their JS wrapper prefix.
    const unary_wrapped = [_]struct { name: []const u8, prefix: []const u8 }{
        // A bool IS 0/1 once it is a number, and JS `+true` is 1. `Number(...)`
        // is the spelling that cannot be misread as string concatenation when
        // the operand is spliced next to a `+`.
        .{ .name = "intFromBool", .prefix = "Number(" },
        .{ .name = "intFromFloat", .prefix = "Math.trunc(" },
        // JS bitwise operators coerce to 32 bits, so the population count is
        // done on the value itself rather than through `>>`/`&`, which would
        // silently answer for the low 32 bits of a 53-bit-safe integer.
        .{ .name = "popCount", .prefix = "((v) => { let n = 0; let x = v; while (x > 0) { n += x % 2; x = Math.floor(x / 2); } return n; })(" },
        .{ .name = "exp2", .prefix = "Math.pow(2, " },
    };
    for (unary_wrapped) |uw| {
        if (eql(u8, name, uw.name)) {
            try out.appendSlice(allocator, uw.prefix);
            try lowerJsInto(out, allocator, first, .koru_expr, diag);
            try out.append(allocator, ')');
            return j;
        }
    }
    if (eql(u8, name, "divTrunc") or eql(u8, name, "divFloor") or eql(u8, name, "divExact")) {
        try out.appendSlice(allocator, if (eql(u8, name, "divTrunc")) "Math.trunc((" else if (eql(u8, name, "divFloor")) "Math.floor((" else "((");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") / (");
        try lowerJsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    if (eql(u8, name, "rem")) {
        try out.appendSlice(allocator, "((");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") % (");
        try lowerJsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    if (eql(u8, name, "mod")) {
        // Euclidean: Zig's @mod is non-negative for a positive divisor,
        // JavaScript's `%` keeps the dividend's sign.
        try out.appendSlice(allocator, "((((");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, ") % (");
        try lowerJsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, ")) + (");
        try lowerJsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, ")) % (");
        try lowerJsInto(out, allocator, second, .koru_expr, diag);
        try out.appendSlice(allocator, "))");
        return j;
    }
    if (eql(u8, name, "min") or eql(u8, name, "max") or
        eql(u8, name, "abs") or eql(u8, name, "sqrt") or
        eql(u8, name, "sin") or eql(u8, name, "cos") or
        eql(u8, name, "tan") or eql(u8, name, "exp") or
        eql(u8, name, "log") or eql(u8, name, "log2") or
        eql(u8, name, "log10") or eql(u8, name, "floor") or
        eql(u8, name, "ceil") or eql(u8, name, "trunc"))
    {
        try out.appendSlice(allocator, "Math.");
        try out.appendSlice(allocator, name);
        try out.append(allocator, '(');
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        if (split != null) {
            try out.appendSlice(allocator, ", ");
            try lowerJsInto(out, allocator, second, .koru_expr, diag);
        }
        try out.append(allocator, ')');
        return j;
    }

    // ABORT WITH A MESSAGE. Koru's only unconditional failure, and the one
    // operation in this table that is a STATEMENT rather than a value — Zig's
    // `@panic` has type `noreturn`, and `throw` is JavaScript's. A store's
    // `[tree]` cycle guard reaches here (695_002) and so does every generated
    // invariant that refuses rather than returns.
    if (eql(u8, name, "panic")) {
        try out.appendSlice(allocator, "(() => { throw new Error(");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.appendSlice(allocator, "); })()");
        return j;
    }

    if (diag) |d| d.unknown_builtin = name;
    return LowerError.UnsupportedBuiltin;
}

// ============================================================================
// Textual hygiene over host (Zig) code
// ============================================================================

/// Byte mask over Zig source text: `true` where an identifier could occur as
/// code, `false` inside the regions where a name is just text — string
/// literals, char literals, `//` comments, and `\\` multiline-string lines.
/// Every textual tool over host code consults this, because a name inside a
/// literal is not a declaration and not a reference (the corrupted-sentence
/// bug 230_016 pins).
pub fn zigCodeMask(allocator: std.mem.Allocator, text: []const u8) ![]bool {
    const mask = try allocator.alloc(bool, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') : (i += 1) mask[i] = false;
            continue;
        }
        if (c == '\\' and i + 1 < text.len and text[i + 1] == '\\') {
            // Zig multiline string literal: `\\` to end of line is text.
            while (i < text.len and text[i] != '\n') : (i += 1) mask[i] = false;
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            mask[i] = false;
            i += 1;
            while (i < text.len and text[i] != quote and text[i] != '\n') {
                mask[i] = false;
                if (text[i] == '\\' and i + 1 < text.len) {
                    i += 1;
                    mask[i] = false;
                }
                i += 1;
            }
            if (i < text.len and text[i] == quote) {
                mask[i] = false;
                i += 1;
            }
            continue;
        }
        mask[i] = true;
        i += 1;
    }
    return mask;
}

/// Punctuators a keyword's own grammar places after it — the keyword forms
/// whose next token is not a name: `if (`, `catch |`, `break :`, `return;`,
/// `else {`, `error.`, `extern "`. The identifier follow (`var n`, `try f()`,
/// `return x`) is keyword position for EVERY keyword — two adjacent
/// identifiers parse only inside keyword grammar — so that check lives in
/// isZigKeywordPosition and this table holds only the exceptions.
const zig_keyword_follow = std.StaticStringMap([]const u8).initComptime(.{
    .{ "if", "(" },
    .{ "while", "(" },
    .{ "for", "(" },
    .{ "switch", "(" },
    .{ "fn", "(" },
    .{ "asm", "(" },
    .{ "align", "(" },
    .{ "callconv", "(" },
    .{ "linksection", "(" },
    .{ "volatile", "(" },
    .{ "enum", "({" },
    .{ "union", "({" },
    .{ "catch", "|" },
    .{ "errdefer", "|{" },
    .{ "break", ":;" },
    .{ "continue", ":;" },
    .{ "return", ";" },
    .{ "else", "{" },
    .{ "struct", "{" },
    .{ "opaque", "{" },
    .{ "error", "{." },
    .{ "test", "\"{" },
    .{ "comptime", "{" },
    .{ "nosuspend", "{" },
    .{ "suspend", "{" },
    .{ "defer", "{" },
    .{ "orelse", "{" },
    .{ "extern", "\"" },
});

/// Statement-only keywords — the ones that can never open an operand. For
/// these, an operand-introducer before the occurrence overrides the follow
/// rule: `x = var` reads the param even when the next line starts with a name
/// (which would otherwise parse as the declared name of a `var` decl).
/// Expression keywords are exempt — `x = if (c) a else b` and `x = comptime
/// {}` are real keyword uses in operand position.
const zig_stmt_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "var", {} },
    .{ "const", {} },
    .{ "return", {} },
    .{ "break", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "errdefer", {} },
    .{ "pub", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "usingnamespace", {} },
    .{ "noalias", {} },
    .{ "noinline", {} },
});

/// Keywords whose own grammar ends in an operand — `orelse var`,
/// `return var`, `a and var` — so a following name is a reference, never
/// the keyword's declared name.
const zig_operand_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "orelse", {} },
    .{ "catch", {} },
    .{ "else", {} },
    .{ "return", {} },
    .{ "break", {} },
    .{ "continue", {} },
    .{ "and", {} },
    .{ "or", {} },
    .{ "try", {} },
});

/// Whether the token ending just before `start` puts the occurrence in
/// OPERAND position — `x = var`, `f(var)`, `x.var`, `=> var`, `orelse var`.
/// mask marks comments and strings so `x = // note\n var` still sees the `=`.
fn operandPreceded(text: []const u8, mask: []const bool, start: usize) bool {
    var j = start;
    while (j > 0) {
        const c = text[j - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or !mask[j - 1]) {
            j -= 1;
            continue;
        }
        break;
    }
    if (j == 0) return false;
    const c = text[j - 1];
    if (std.mem.indexOfScalar(u8, "=([,:?.+-*/%!~<>&|^", c) != null) return true;
    if (std.ascii.isAlphabetic(c) or c == '_') {
        var k = j;
        while (k > 0 and (std.ascii.isAlphanumeric(text[k - 1]) or text[k - 1] == '_')) k -= 1;
        return zig_operand_keywords.has(text[k..j]);
    }
    return false;
}

/// Whether the keyword occurrence spanning `start..end` is in KEYWORD
/// position — what surrounds it is what that keyword's grammar takes, not
/// what a reference would sit in. Followed by a name (`var n`, `const @"x"`,
/// `comptime var`, `try f()`, `return x` — juxtaposed identifiers parse only
/// inside keyword grammar) or by the punctuator its form leads with
/// (zig_keyword_follow: `if (`, `catch |`, `break :`, `return;`, `error.`).
/// Statement keywords in operand position are references instead — `x =
/// var` reads the param named `var` (230_021).
fn isZigKeywordPosition(text: []const u8, mask: []const bool, start: usize, end: usize, name: []const u8) bool {
    if (zig_stmt_keywords.has(name) and operandPreceded(text, mask, start)) return false;
    var k = end;
    while (k < text.len) {
        const c = text[k];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            k += 1;
            continue;
        }
        if (c == '/' and k + 1 < text.len and text[k + 1] == '/') {
            while (k < text.len and text[k] != '\n') k += 1;
            continue;
        }
        break;
    }
    if (k >= text.len) return false;
    const c = text[k];
    if (std.ascii.isAlphabetic(c) or c == '_' or c == '@') return true;
    const follows = zig_keyword_follow.get(name) orelse return false;
    return std.mem.indexOfScalar(u8, follows, c) != null;
}

/// Word-boundary token scan, quote- and comment-aware.
pub fn containsToken(body: []const u8, token: []const u8) bool {
    var i: usize = 0;
    var q: u8 = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (q != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == q) {
                q = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            q = c;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], token)) {
            const before_ok = i == 0 or !(std.ascii.isAlphanumeric(body[i - 1]) or body[i - 1] == '_' or body[i - 1] == '.');
            const after = i + token.len;
            const after_ok = after >= body.len or !(std.ascii.isAlphanumeric(body[after]) or body[after] == '_');
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

/// Replace word-boundary-matched identifier occurrences in text — but only
/// where the occurrence is code (see zigCodeMask). Rewriting a name inside a
/// string literal ships a corrupted program that still compiles (230_016).
/// When the name is itself a Zig keyword, an occurrence in the keyword's own
/// position is not a reference either: `var n: i32 = var` declares with the
/// first `var` and reads the param with the second — rewriting both emits
/// `@"var" n: i32`, a Zig syntax error in code the author never wrote
/// (230_021).
pub fn replaceIdentifier(allocator: std.mem.Allocator, text: []const u8, old_name: []const u8, new_name: []const u8) ![]const u8 {
    if (old_name.len == 0) return try allocator.dupe(u8, text);

    const mask = try zigCodeMask(allocator, text);
    defer allocator.free(mask);

    const is_keyword = zig_keywords.has(old_name);

    var result = try std.ArrayList(u8).initCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (mask[i] and i + old_name.len <= text.len and std.mem.eql(u8, text[i .. i + old_name.len], old_name)) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(text[i - 1]) and text[i - 1] != '_');
            const after_idx = i + old_name.len;
            const after_ok = (after_idx >= text.len) or (!std.ascii.isAlphanumeric(text[after_idx]) and text[after_idx] != '_');
            // Member position is not a reference: `.name` binds to the left
            // side's namespace (struct-literal label, member access, enum
            // literal), never to the in-scope identifier — rewriting it emits
            // field names the type never declared (230_023). `..` is the
            // range operator, not member access: `0..m` still names m.
            const member_position = i > 0 and text[i - 1] == '.' and (i < 2 or text[i - 2] != '.');
            if (before_ok and after_ok and !member_position) {
                if (is_keyword and isZigKeywordPosition(text, mask, i, after_idx, old_name)) {
                    try result.appendSlice(allocator, old_name);
                } else {
                    try result.appendSlice(allocator, new_name);
                }
                i += old_name.len;
                continue;
            }
        }
        try result.append(allocator, text[i]);
        i += 1;
    }
    return try result.toOwnedSlice(allocator);
}

/// Collect the payload-capture names a chunk of Zig code declares — the
/// `|name|` groups after `)`, `else`, or `catch`. Multi-captures and `*name`
/// pointer captures contribute each identifier. Appends to `out`; names are
/// slices into `text`.
pub fn collectZigCaptureNames(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    const mask = try zigCodeMask(allocator, text);
    defer allocator.free(mask);

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!mask[i] or text[i] != '|') continue;
        // The token before the `|` decides whether this is a capture group.
        var j = i;
        while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t' or text[j - 1] == '\n')) j -= 1;
        const is_capture = j > 0 and (text[j - 1] == ')' or
            (j >= 4 and std.mem.eql(u8, text[j - 4 .. j], "else")) or
            (j >= 5 and std.mem.eql(u8, text[j - 5 .. j], "catch")));
        if (!is_capture) continue;
        // Parse `| [*]ident (, [*]ident)* |`; bail on anything else.
        var k = i + 1;
        var parsed_any = false;
        while (true) {
            while (k < text.len and (text[k] == ' ' or text[k] == '*')) k += 1;
            const name_start = k;
            while (k < text.len and (std.ascii.isAlphanumeric(text[k]) or text[k] == '_')) k += 1;
            if (k == name_start) break;
            try out.append(allocator, text[name_start..k]);
            parsed_any = true;
            while (k < text.len and text[k] == ' ') k += 1;
            if (k < text.len and text[k] == ',') {
                k += 1;
                continue;
            }
            break;
        }
        if (parsed_any and k < text.len and text[k] == '|') {
            i = k;
        }
    }
}

// ============================================================================
// THE ZIG SPELLING OF KORU OPERATORS — the two the host does not share
// ============================================================================
//
// Koru expression text is pasted into Zig verbatim, and for `+ - * < and or ++`
// that is the whole story: the hosts spell them the same way. Two operators
// Koru HAD a meaning for reached Zig as the wrong spelling, each refused by the
// host at Stage D with its own builtin list:
//
//   `==` / `!=` on STRINGS is VALUE equality. Every organ that already has an
//   opinion agrees: the comptime fold (`comptime_eval.zig`, `.equal` on two
//   `.string`s is `mem.eql`), the interpreter (`koru_std/interpreter.kz`), and
//   the JS target (verbatim `==` — which in JavaScript IS string value
//   equality). Zig refuses `[]const u8 == []const u8` outright ("cannot
//   compare strings with ==") — one target implementing what the other three
//   meant.
//
//   `%` on a SIGNED runtime integer is C's truncated remainder. Zig's `%` is
//   UNSIGNED-ONLY (`signed integers and floats must use @rem or @mod`), and
//   Koru's is `@rem` in every organ that has an opinion — the comptime fold
//   folds `.modulo` with `@rem`, its own comment calling that "the C-parity
//   choice", and the JS target passes `%` through, JS `%` on numbers being
//   that same truncated remainder. So `n % 2` compiled on JS and died on Zig.
//
// WHAT REWRITES: `%` → `@rem(lhs, rhs)`, the identical operator for unsigned
// operands and the only one Zig accepts for signed; and a `==` / `!=` whose
// either operand is a double-quoted string LITERAL (the syntactically
// decidable subset, and the whole dispatch family — "is this command/route/
// config-key equal to that word") → `@import("std").mem.eql(u8, lhs, rhs)`,
// negated for `!=`. Each rewrite is spliced back with every other byte of the
// expression preserved.
//
// WHAT DOES NOT (yet): `a == b` where both sides are string-TYPED names, and
// `/` on signed integers (`@divTrunc` for ints, `/` for floats — deciding
// which needs a type oracle at a site that carries none; pinned by
// 030_143_signed_runtime_division, NEEDS_RULING). Both still fail loudly at
// Stage D on Zig and work on JS — the remaining half of this symmetry, not a
// silent wrong answer.
//
// The scan is CONSERVATIVE BY CONSTRUCTION: the text is parsed with a small
// span-tracking expression parser, and anything it does not fully recognize —
// statement text, bit operators, struct literals, host-only syntax — returns
// null and the caller keeps the original bytes. Unchanged regions are copied
// from the source by span, never re-rendered, so a non-matching expression is
// byte-identical.

const ZigExprError = error{ NoParse, OutOfMemory };

/// A parsed subexpression: its rendered text (rewritten iff `changed`),
/// its source span, and whether it is exactly one string literal.
const ZigExprPiece = struct {
    text: []const u8,
    start: usize,
    end: usize,
    is_string_lit: bool,
    changed: bool,
};

const ZigExprParser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize,

    fn skipWs(self: *ZigExprParser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn peek(self: *ZigExprParser) u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else 0;
    }

    /// Word-boundary keyword match at the current position.
    fn atKeyword(self: *ZigExprParser, kw: []const u8) bool {
        if (self.pos + kw.len > self.text.len) return false;
        if (!std.mem.eql(u8, self.text[self.pos .. self.pos + kw.len], kw)) return false;
        if (self.pos > 0 and exprIdentChar(self.text[self.pos - 1])) return false;
        const after = self.pos + kw.len;
        if (after < self.text.len and exprIdentChar(self.text[after])) return false;
        return true;
    }

    /// Combine a left-associative binary chain step. When neither side was
    /// rewritten the piece is the original source slice; otherwise the two
    /// rendered halves are joined by the ORIGINAL inter-operand bytes (the
    /// operator and its spacing), so nothing outside a rewrite is respelled.
    fn combine(self: *ZigExprParser, left: ZigExprPiece, right: ZigExprPiece) ZigExprError!ZigExprPiece {
        if (!left.changed and !right.changed) {
            return .{ .text = self.text[left.start..right.end], .start = left.start, .end = right.end, .is_string_lit = false, .changed = false };
        }
        const joined = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            left.text, self.text[left.end..right.start], right.text,
        }) catch return ZigExprError.OutOfMemory;
        return .{ .text = joined, .start = left.start, .end = right.end, .is_string_lit = false, .changed = true };
    }

    /// A left-associative keyword/symbol binary-op level: `l op r op r …`
    /// where `op` reads as either the host keyword (`or`, `and`) or its
    /// C-style symbol (`||`, `&&`). `next` parses the tighter level.
    fn parseKeywordBinOp(
        self: *ZigExprParser,
        comptime keyword: []const u8,
        comptime symbol: []const u8,
        comptime next: fn (*ZigExprParser) ZigExprError!ZigExprPiece,
    ) ZigExprError!ZigExprPiece {
        var left = try next(self);
        while (true) {
            self.skipWs();
            if (self.atKeyword(keyword)) {
                self.pos += keyword.len;
            } else if (self.pos + 1 < self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + 2], symbol)) {
                self.pos += symbol.len;
            } else break;
            const right = try next(self);
            left = try self.combine(left, right);
        }
        return left;
    }

    fn parseOr(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        return self.parseKeywordBinOp("or", "||", parseAnd);
    }

    fn parseAnd(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        return self.parseKeywordBinOp("and", "&&", parseEq);
    }

    /// Literal operands that only compile under a `==` with its expected
    /// type on the other side — `.audio`, `null`, `0`, `'x'`, `true`,
    /// `undefined`, `{ ... }`. Binding them to `const` in a dispatch block
    /// would strand them without a result type, so a comparison carrying
    /// one stays verbatim. String literals are not listed: they take the
    /// mem.eql path first.
    fn eqOperandNeedsTypeContext(text: []const u8) bool {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return true;
        if (t[0] == '.' or t[0] == '{' or t[0] == '\'' or t[0] == '"') return true;
        if (std.ascii.isDigit(t[0])) return true;
        if ((t[0] == '-' or t[0] == '+') and t.len > 1 and std.ascii.isDigit(t[1])) return true;
        for ([_][]const u8{ "true", "false", "null", "undefined" }) |kw| {
            if (std.mem.eql(u8, t, kw)) return true;
        }
        return false;
    }

    /// THE REWRITE LEVEL. `==` / `!=` with a string-literal operand becomes
    /// the `mem.eql` call; every other comparison combines verbatim.
    fn parseEq(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        var left = try self.parseCmp();
        while (true) {
            self.skipWs();
            var negated = false;
            if (self.pos + 1 < self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + 2], "==")) {
                self.pos += 2;
            } else if (self.pos + 1 < self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + 2], "!=")) {
                negated = true;
                self.pos += 2;
            } else break;
            const right = try self.parseCmp();
            if (left.is_string_lit or right.is_string_lit) {
                // Optional-aware: `?string == "lit"` must answer false on
                // null, not hand mem.eql a ?[]const u8 (backend Zig refuses)
                // nor unwrap-panic. The @typeInfo checks are comptime — for
                // non-optional operands this folds back to a plain mem.eql.
                // Presence bits compare first: null==null is true,
                // null==value is false without evaluating the payload.
                const call = std.fmt.allocPrint(self.allocator, "{s}(blk: {{ const __koru_l = {s}; const __koru_r = {s}; const __koru_ln = if (@typeInfo(@TypeOf(__koru_l)) == .optional) __koru_l == null else false; const __koru_rn = if (@typeInfo(@TypeOf(__koru_r)) == .optional) __koru_r == null else false; break :blk (__koru_ln == __koru_rn) and (__koru_ln or @import(\"std\").mem.eql(u8, if (@typeInfo(@TypeOf(__koru_l)) == .optional) __koru_l.? else __koru_l, if (@typeInfo(@TypeOf(__koru_r)) == .optional) __koru_r.? else __koru_r)); }})", .{
                    if (negated) "!" else "", left.text, right.text,
                }) catch return ZigExprError.OutOfMemory;
                left = .{ .text = call, .start = left.start, .end = right.end, .is_string_lit = false, .changed = true };
            } else if (!eqOperandNeedsTypeContext(left.text) and !eqOperandNeedsTypeContext(right.text)) {
                // No literal on either side — `h1 == h2`, `a.b == c.d`,
                // `f() == g()`. Bare `==` on two strings is uncompilable
                // Zig; the rewrite has no type oracle, so the emitted code
                // asks: when both payload types are u8 strings this is the
                // presence-aware mem.eql above, anything else is `==`. All
                // checks are comptime — a non-string pair folds to `l == r`
                // and never analyzes the mem.eql arm. Literals are skipped
                // because `const r = .audio` / `= null` / `= 0` would need
                // the type context the bare `==` already supplies.
                const call = std.fmt.allocPrint(self.allocator, "{s}(blk: {{ const __koru_l = {s}; const __koru_r = {s}; const __koru_lo = @typeInfo(@TypeOf(__koru_l)) == .optional; const __koru_ro = @typeInfo(@TypeOf(__koru_r)) == .optional; const __koru_lp = if (__koru_lo) @typeInfo(@TypeOf(__koru_l)).optional.child else @TypeOf(__koru_l); const __koru_rp = if (__koru_ro) @typeInfo(@TypeOf(__koru_r)).optional.child else @TypeOf(__koru_r); const __koru_ls = __koru_str: {{ const __koru_ty = @typeInfo(__koru_lp); if (__koru_ty == .array) break :__koru_str __koru_ty.array.child == u8; if (__koru_ty == .pointer) {{ const __koru_ptr = __koru_ty.pointer; if (__koru_ptr.size == .slice and __koru_ptr.child == u8) break :__koru_str true; break :__koru_str __koru_ptr.size == .one and @typeInfo(__koru_ptr.child) == .array and @typeInfo(__koru_ptr.child).array.child == u8; }} break :__koru_str false; }}; const __koru_rs = __koru_str: {{ const __koru_ty = @typeInfo(__koru_rp); if (__koru_ty == .array) break :__koru_str __koru_ty.array.child == u8; if (__koru_ty == .pointer) {{ const __koru_ptr = __koru_ty.pointer; if (__koru_ptr.size == .slice and __koru_ptr.child == u8) break :__koru_str true; break :__koru_str __koru_ptr.size == .one and @typeInfo(__koru_ptr.child) == .array and @typeInfo(__koru_ptr.child).array.child == u8; }} break :__koru_str false; }}; if (__koru_ls and __koru_rs) {{ const __koru_ln = if (__koru_lo) __koru_l == null else false; const __koru_rn = if (__koru_ro) __koru_r == null else false; break :blk (__koru_ln == __koru_rn) and (__koru_ln or @import(\"std\").mem.eql(u8, if (__koru_lo) __koru_l.? else __koru_l, if (__koru_ro) __koru_r.? else __koru_r)); }} else break :blk __koru_l == __koru_r; }})", .{
                    if (negated) "!" else "", left.text, right.text,
                }) catch return ZigExprError.OutOfMemory;
                left = .{ .text = call, .start = left.start, .end = right.end, .is_string_lit = false, .changed = true };
            } else {
                left = try self.combine(left, right);
            }
        }
        return left;
    }

    fn parseCmp(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        var left = try self.parseConcat();
        while (true) {
            self.skipWs();
            if (self.pos + 1 < self.text.len and
                (std.mem.eql(u8, self.text[self.pos .. self.pos + 2], "<=") or
                    std.mem.eql(u8, self.text[self.pos .. self.pos + 2], ">=")))
            {
                self.pos += 2;
            } else if ((self.peek() == '<' or self.peek() == '>') and
                // `<<` / `>>` are bit shifts this parser does not model.
                !(self.pos + 1 < self.text.len and (self.text[self.pos + 1] == '<' or self.text[self.pos + 1] == '>')))
            {
                self.pos += 1;
            } else break;
            const right = try self.parseConcat();
            left = try self.combine(left, right);
        }
        return left;
    }

    fn parseConcat(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        var left = try self.parseAdd();
        while (true) {
            self.skipWs();
            if (self.pos + 1 < self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + 2], "++")) {
                self.pos += 2;
            } else break;
            const right = try self.parseAdd();
            left = try self.combine(left, right);
        }
        return left;
    }

    fn parseAdd(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        var left = try self.parseMul();
        while (true) {
            self.skipWs();
            const c = self.peek();
            // Not `++` (concat, handled above) and not a `-` glued to an
            // identifier (kebab names are consumed by parseIdent).
            if (c == '+' and !(self.pos + 1 < self.text.len and self.text[self.pos + 1] == '+')) {
                self.pos += 1;
            } else if (c == '-') {
                self.pos += 1;
            } else break;
            const right = try self.parseMul();
            left = try self.combine(left, right);
        }
        return left;
    }

    /// THE SECOND REWRITE LEVEL. `*` and `/` are tokens both hosts spell the
    /// same way; `%` is not (see the section header) — it renders as the
    /// `@rem` builtin call, which is that same operator for an unsigned
    /// operand and the only spelling Zig accepts for a signed one.
    ///
    /// Tighter than `parseAdd`, so only the operands of THIS `%` move:
    /// `a + b % c` → `a + @rem(b, c)`, `a % b * c` → `@rem(a, b) * c`.
    fn parseMul(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        var left = try self.parseUnary();
        while (true) {
            self.skipWs();
            const c = self.peek();
            if (c != '*' and c != '/' and c != '%') break;
            self.pos += 1;
            const right = try self.parseUnary();
            if (c != '%') {
                left = try self.combine(left, right);
                continue;
            }
            const call = std.fmt.allocPrint(self.allocator, "@rem({s}, {s})", .{ left.text, right.text }) catch return ZigExprError.OutOfMemory;
            left = .{ .text = call, .start = left.start, .end = right.end, .is_string_lit = false, .changed = true };
        }
        return left;
    }

    /// A conditional EXPRESSION: `if (<cond>) <then> else <else>`, the Zig
    /// spelling a `.k` body writes (`-> if (n % 2 == 0) 1 else 0`). Its whole
    /// point here is the CONDITION: that is where a `%` or a literal-grounded
    /// string `==` sits, one nesting level below the operator the caller's text
    /// starts with.
    ///
    /// The shape is Zig's, not Koru's: `if` needs a parenthesized condition and
    /// an `else` arm. A statement `if (c) { … }` — block arms, no `else`, a
    /// trailing `;` — does not read here and returns NoParse, so the caller
    /// keeps its bytes. The `else` that a nested `if` binds to is the NEAREST
    /// one, exactly as both hosts read it.
    fn parseConditional(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        const start = self.pos;
        self.pos += 2; // `if`
        self.skipWs();
        if (self.peek() != '(') return ZigExprError.NoParse;
        self.pos += 1;
        const cond = try self.parseOr();
        self.skipWs();
        if (self.peek() != ')') return ZigExprError.NoParse;
        self.pos += 1;
        const then_piece = try self.parseOr();
        self.skipWs();
        if (!self.atKeyword("else")) return ZigExprError.NoParse;
        self.pos += 4;
        const else_piece = try self.parseOr();
        if (!cond.changed and !then_piece.changed and !else_piece.changed) {
            return .{ .text = self.text[start..else_piece.end], .start = start, .end = else_piece.end, .is_string_lit = false, .changed = false };
        }
        const joined = std.fmt.allocPrint(self.allocator, "if ({s}) {s} else {s}", .{ cond.text, then_piece.text, else_piece.text }) catch return ZigExprError.OutOfMemory;
        return .{ .text = joined, .start = start, .end = else_piece.end, .is_string_lit = false, .changed = true };
    }

    fn parseUnary(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        self.skipWs();
        const start = self.pos;
        if (self.peek() == '!' or self.peek() == '-') {
            self.pos += 1;
            const operand = try self.parseUnary();
            if (!operand.changed) {
                return .{ .text = self.text[start..operand.end], .start = start, .end = operand.end, .is_string_lit = false, .changed = false };
            }
            const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                self.text[start..operand.start], operand.text,
            }) catch return ZigExprError.OutOfMemory;
            return .{ .text = joined, .start = start, .end = operand.end, .is_string_lit = false, .changed = true };
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        var result = try self.parsePrimary();
        while (true) {
            // No skipWs here: postfix binds tightly, and a space before `(`
            // or `[` in guard text is not a call we need to model.
            const c = self.peek();
            if (c == '.' and self.pos + 1 < self.text.len and self.text[self.pos + 1] == '?') {
                // Optional unwrap `.?` — an opaque suffix like a field name.
                const dot_at = self.pos;
                self.pos += 2;
                if (result.changed) {
                    const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ result.text, self.text[dot_at..self.pos] }) catch return ZigExprError.OutOfMemory;
                    result = .{ .text = joined, .start = result.start, .end = self.pos, .is_string_lit = false, .changed = true };
                } else {
                    result = .{ .text = self.text[result.start..self.pos], .start = result.start, .end = self.pos, .is_string_lit = false, .changed = false };
                }
            } else if (c == '.') {
                if (self.pos + 1 >= self.text.len or !exprIdentStartChar(self.text[self.pos + 1])) return ZigExprError.NoParse;
                const dot_at = self.pos;
                self.pos += 1;
                const field_start = self.pos;
                _ = try self.parseIdentName();
                // A field segment is a Koru name arriving through
                // host-flavored text: `f.pos-tempo` must carry the decl's
                // spelling (`f.pos_tempo`) or Zig reads it as subtraction.
                const field_name = self.text[field_start..self.pos];
                const suffix = if (hasKebab(field_name) or needsEscaping(field_name)) blk: {
                    var b = std.ArrayList(u8).initCapacity(self.allocator, field_name.len + 4) catch return ZigExprError.OutOfMemory;
                    b.append(self.allocator, '.') catch return ZigExprError.OutOfMemory;
                    appendBranchName(&b, self.allocator, field_name) catch return ZigExprError.OutOfMemory;
                    break :blk b.toOwnedSlice(self.allocator) catch return ZigExprError.OutOfMemory;
                } else self.text[dot_at..self.pos];
                if (result.changed or suffix.ptr != self.text[dot_at..self.pos].ptr) {
                    const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ result.text, suffix }) catch return ZigExprError.OutOfMemory;
                    result = .{ .text = joined, .start = result.start, .end = self.pos, .is_string_lit = false, .changed = true };
                } else {
                    result = .{ .text = self.text[result.start..self.pos], .start = result.start, .end = self.pos, .is_string_lit = false, .changed = false };
                }
            } else if (c == '(' or c == '[') {
                const inner = try self.parseBalanced(c);
                if (inner.changed or result.changed) {
                    const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ result.text, inner.text }) catch return ZigExprError.OutOfMemory;
                    result = .{ .text = joined, .start = result.start, .end = self.pos, .is_string_lit = false, .changed = true };
                } else {
                    result = .{ .text = self.text[result.start..self.pos], .start = result.start, .end = self.pos, .is_string_lit = false, .changed = false };
                }
            } else break;
        }
        return result;
    }

    /// A balanced `(...)` / `[...]` region in postfix position (call
    /// arguments, an index). Each top-level comma segment is offered the FULL
    /// rewrite independently, so `@intFromBool(s == "x")` rewrites while an
    /// argument this parser cannot read keeps its own bytes — per-segment
    /// identity, never per-expression abandonment.
    fn parseBalanced(self: *ZigExprParser, open: u8) ZigExprError!ZigExprPiece {
        const close: u8 = if (open == '(') ')' else ']';
        const start = self.pos;
        self.pos += 1;
        var out = std.ArrayList(u8).initCapacity(self.allocator, 8) catch return ZigExprError.OutOfMemory;
        out.append(self.allocator, open) catch return ZigExprError.OutOfMemory;
        var changed = false;
        var seg_start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '"' or c == '\'') {
                try self.skipStringLike(c);
                continue;
            }
            if (c == '(' or c == '[' or c == '{') depth += 1;
            if (c == ')' or c == ']' or c == '}') {
                if (depth == 0) {
                    if (c != close) return ZigExprError.NoParse;
                    const seg = self.text[seg_start..self.pos];
                    const low = try self.rewriteArg(open, seg);
                    if (low) |l| {
                        changed = true;
                        out.appendSlice(self.allocator, l) catch return ZigExprError.OutOfMemory;
                    } else {
                        out.appendSlice(self.allocator, seg) catch return ZigExprError.OutOfMemory;
                    }
                    out.append(self.allocator, close) catch return ZigExprError.OutOfMemory;
                    self.pos += 1;
                    return .{
                        .text = if (changed) (out.toOwnedSlice(self.allocator) catch return ZigExprError.OutOfMemory) else self.text[start..self.pos],
                        .start = start,
                        .end = self.pos,
                        .is_string_lit = false,
                        .changed = changed,
                    };
                }
                depth -= 1;
            }
            if (c == ',' and depth == 0) {
                const seg = self.text[seg_start..self.pos];
                const low = try self.rewriteArg(open, seg);
                if (low) |l| {
                    changed = true;
                    out.appendSlice(self.allocator, l) catch return ZigExprError.OutOfMemory;
                } else {
                    out.appendSlice(self.allocator, seg) catch return ZigExprError.OutOfMemory;
                }
                out.append(self.allocator, ',') catch return ZigExprError.OutOfMemory;
                seg_start = self.pos + 1;
            }
            self.pos += 1;
        }
        return ZigExprError.NoParse;
    }

    /// Skip a `"…"` or `'…'` literal including escapes; pos lands after the
    /// closing quote.
    fn skipStringLike(self: *ZigExprParser, quote: u8) ZigExprError!void {
        self.pos += 1;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == quote) {
                self.pos += 1;
                return;
            }
            self.pos += 1;
        }
        return ZigExprError.NoParse;
    }

    fn parseIdentName(self: *ZigExprParser) ZigExprError!void {
        if (!exprIdentStartChar(self.peek())) return ZigExprError.NoParse;
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (exprIdentChar(c)) {
                self.pos += 1;
            } else if (c == '-' and self.pos + 1 < self.text.len and exprIdentChar(self.text[self.pos + 1])) {
                // Kebab-greedy, mirroring expression_parser.zig: an unspaced
                // `-` joins identifier segments; subtraction needs spaces.
                self.pos += 1;
            } else break;
        }
    }

    fn parsePrimary(self: *ZigExprParser) ZigExprError!ZigExprPiece {
        self.skipWs();
        const start = self.pos;
        const c = self.peek();
        // `if (<cond>) <then> else <else>` — a body-position conditional, which
        // is where the rewrites are most often NESTED: `-> if (n % 2 == 0) 1
        // else 0`, `if (cmd == "start") … else …`. Read BEFORE the identifier
        // branch, which would otherwise take `if` for a name.
        if (self.atKeyword("if")) return self.parseConditional();
        if (c == '"') {
            try self.skipStringLike('"');
            return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = true, .changed = false };
        }
        if (c == '\'') {
            try self.skipStringLike('\'');
            return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
        }
        if (c == '(') {
            self.pos += 1;
            const inner = try self.parseOr();
            self.skipWs();
            if (self.peek() != ')') return ZigExprError.NoParse;
            self.pos += 1;
            if (!inner.changed) {
                return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
            }
            const joined = std.fmt.allocPrint(self.allocator, "({s})", .{inner.text}) catch return ZigExprError.OutOfMemory;
            return .{ .text = joined, .start = start, .end = self.pos, .is_string_lit = false, .changed = true };
        }
        if (c == '@') {
            self.pos += 1;
            const name_start = self.pos;
            try self.parseIdentName();
            const name = self.text[name_start..self.pos];
            self.skipWs();
            if (self.peek() != '(') return ZigExprError.NoParse;
            if (std.mem.eql(u8, name, "as")) {
                if (self.tryAsIntCast(start)) |piece| {
                    return piece;
                } else |err| switch (err) {
                    ZigExprError.NoParse => {},
                    else => return err,
                }
            }
            const inner = try self.parseBalanced('(');
            if (!inner.changed) {
                return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
            }
            const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.text[start..inner.start], inner.text }) catch return ZigExprError.OutOfMemory;
            return .{ .text = joined, .start = start, .end = self.pos, .is_string_lit = false, .changed = true };
        }
        if (std.ascii.isDigit(c)) {
            // Number: consume the token loosely (hex/float/underscores); a
            // malformed number surfaces as NoParse at the next operator.
            while (self.pos < self.text.len) {
                const nc = self.text[self.pos];
                if (std.ascii.isAlphanumeric(nc) or nc == '_' or nc == '.') {
                    self.pos += 1;
                } else break;
            }
            return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
        }
        if (c == '.' and self.pos + 1 < self.text.len and exprIdentStartChar(self.text[self.pos + 1])) {
            // Enum literal `.foo` — readable, and flagged context-needing
            // by eqOperandNeedsTypeContext (its text still starts `.`).
            self.pos += 1;
            try self.parseIdentName();
            return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
        }
        if (exprIdentStartChar(c)) {
            try self.parseIdentName();
            return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
        }
        return ZigExprError.NoParse;
    }

    /// `@as(T, @intCast(x))` — the canonical Koru cast — routes through
    /// `__koru_intcast`: Zig's `@intCast` emits an in-loop `llvm.assume`
    /// (operand-fits hint) that the vectorizer declines on a runtime-bound
    /// loop, measured 5.9ms scalar vs 1.5ms vectorized for the same loop.
    /// The helper bitcasts same-width sign flips in release modes and keeps
    /// the real fit-check where safety is on. NoParse — pos restored — when
    /// the second argument is not exactly an `@intCast` call.
    fn tryAsIntCast(self: *ZigExprParser, start: usize) ZigExprError!ZigExprPiece {
        const save = self.pos;
        blk: {
            self.pos += 1; // consume '('
            self.skipWs();
            const t_start = self.pos;
            var depth: usize = 0;
            var comma: usize = 0;
            var found = false;
            while (self.pos < self.text.len) {
                const ch = self.text[self.pos];
                if (ch == '"' or ch == '\'') {
                    self.skipStringLike(ch) catch break :blk;
                    continue;
                }
                if (ch == '(' or ch == '[' or ch == '{') depth += 1;
                if (ch == ')' or ch == ']' or ch == '}') {
                    if (depth == 0) break :blk;
                    depth -= 1;
                }
                if (ch == ',' and depth == 0) {
                    comma = self.pos;
                    found = true;
                    break;
                }
                self.pos += 1;
            }
            if (!found) break :blk;
            const ty = self.text[t_start..comma];
            self.pos = comma + 1;
            self.skipWs();
            const m = matchIntCastText(self.text, self.pos) orelse break :blk;
            self.pos = m.end;
            self.skipWs();
            if (self.peek() != ')') break :blk;
            self.pos += 1;
            const inner = rewriteZigExprInner(self.allocator, m.inner) orelse m.inner;
            const text = std.fmt.allocPrint(self.allocator, "__koru_intcast({s}, {s})", .{ ty, inner }) catch return ZigExprError.OutOfMemory;
            return .{ .text = text, .start = start, .end = self.pos, .is_string_lit = false, .changed = true };
        }
        self.pos = save;
        return ZigExprError.NoParse;
    }

    /// One comma-separated segment inside a balanced region. In `[` — postfix
    /// index position — a segment that is exactly `@intCast(x)` coerces to
    /// `usize`, and the same `__koru_intcast` route applies: the assume would
    /// sit inside the loop just the same.
    fn rewriteArg(self: *ZigExprParser, open: u8, seg: []const u8) ZigExprError!?[]const u8 {
        if (open == '[') {
            const t = std.mem.trim(u8, seg, " \t\n\r");
            if (matchIntCastText(t, 0)) |m| {
                if (m.end == t.len) {
                    const inner = rewriteZigExprInner(self.allocator, m.inner) orelse m.inner;
                    return std.fmt.allocPrint(self.allocator, "__koru_intcast(usize, {s})", .{inner}) catch return ZigExprError.OutOfMemory;
                }
            }
        }
        return rewriteZigExprInner(self.allocator, seg);
    }
};

/// If `text` starting at `pos` is `@intCast( <expr> )`, returns the inner
/// expression slice and the offset just past its closing paren — else null.
/// Paren depth alone is right: the argument is one expression, so the first
/// depth-0 `)` ends it.
fn matchIntCastText(text: []const u8, pos: usize) ?struct { inner: []const u8, end: usize } {
    if (!std.mem.startsWith(u8, text[pos..], "@intCast")) return null;
    var p = pos + "@intCast".len;
    if (p < text.len and exprIdentChar(text[p])) return null;
    while (p < text.len and std.ascii.isWhitespace(text[p])) p += 1;
    if (p >= text.len or text[p] != '(') return null;
    const inner_start = p + 1;
    p += 1;
    var depth: usize = 1;
    while (p < text.len) : (p += 1) {
        const c = text[p];
        if (c == '"' or c == '\'') {
            const q = c;
            p += 1;
            while (p < text.len) : (p += 1) {
                if (text[p] == '\\') {
                    p += 1;
                    continue;
                }
                if (text[p] == q) break;
            }
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return .{ .inner = text[inner_start..p], .end = p + 1 };
        }
    }
    return null;
}

fn exprIdentStartChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Rewrite the operators in one Koru expression whose Zig spelling differs —
/// `%` into `@rem`, a literal-grounded string `==` / `!=` into `mem.eql`.
/// Returns null when the text carries no such operator OR cannot be fully read
/// as an expression — in both cases the caller keeps the original bytes, so
/// this can never corrupt text it does not understand. The result (when
/// non-null) is owned by the caller; every intermediate lives in an arena.
pub fn rewriteZigExpr(allocator: std.mem.Allocator, text: []const u8) ZigExprError!?[]const u8 {
    // Fast reject: none of the three trigger substrings — nothing to parse at
    // all. This is the common case on the emission path, so it is one scan.
    if (!zigExprMayRewrite(text)) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rewritten = rewriteZigExprInner(arena.allocator(), text) orelse return null;
    return allocator.dupe(u8, rewritten) catch return ZigExprError.OutOfMemory;
}

/// Could this text contain an operator the rewrite acts on? Substring-level, so
/// a `%` inside a string literal answers yes — the parse itself then finds
/// nothing to change and the caller keeps its bytes.
fn zigExprMayRewrite(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, '%') != null or
        std.mem.indexOf(u8, text, "==") != null or
        std.mem.indexOf(u8, text, "!=") != null or
        std.mem.indexOf(u8, text, "@intCast") != null) return true;
    return hasNonZigFieldName(text);
}

/// A `.name` segment whose name is not a legal Zig identifier — kebab
/// (`f.pos-tempo`) or a keyword (`f.type`). Both need the canonical spelling;
/// without this trigger a bare field read never reaches the parser.
fn hasNonZigFieldName(text: []const u8) bool {
    var i: usize = 0;
    var in_string: u8 = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string != 0) {
            if (c == in_string and text[i - 1] != '\\') in_string = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = c;
            continue;
        }
        if (c != '.') continue;
        var j = i + 1;
        if (j >= text.len or !exprIdentStartChar(text[j])) continue;
        const start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_' or text[j] == '-')) j += 1;
        const seg = text[start..j];
        if (hasKebab(seg) or needsEscaping(seg)) return true;
    }
    return false;
}

/// Arena-side worker: parse and rewrite, or null for identity. Recursion
/// (call-argument segments in `parseBalanced`) re-enters HERE so every
/// intermediate shares one arena and one lifetime.
fn rewriteZigExprInner(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (!zigExprMayRewrite(text)) return null;
    var parser = ZigExprParser{ .allocator = allocator, .text = text, .pos = 0 };
    const piece = parser.parseOr() catch return null;
    parser.skipWs();
    if (parser.pos < text.len) return null; // trailing content — not a whole expression
    if (!piece.changed) return null;
    // Preserve the original leading/trailing whitespace around the expression.
    const lead = blk: {
        var i: usize = 0;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        break :blk text[0..i];
    };
    const trail = blk: {
        var i: usize = text.len;
        while (i > 0 and std.ascii.isWhitespace(text[i - 1])) i -= 1;
        break :blk text[i..];
    };
    if (lead.len == 0 and trail.len == 0) return piece.text;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ lead, piece.text, trail }) catch return null;
}

// The optional-aware emission shape: presence bits first (null==null true,
// null==value false without touching the payload), comptime @typeInfo
// dispatch unwraps optionals only when they are optionals. For non-optional
// operands the emitted code comptime-folds back to a plain mem.eql.
fn optEqBlock(comptime l: []const u8, comptime r: []const u8) []const u8 {
    return "(blk: { const __koru_l = " ++ l ++ "; const __koru_r = " ++ r ++ "; const __koru_ln = if (@typeInfo(@TypeOf(__koru_l)) == .optional) __koru_l == null else false; const __koru_rn = if (@typeInfo(@TypeOf(__koru_r)) == .optional) __koru_r == null else false; break :blk (__koru_ln == __koru_rn) and (__koru_ln or @import(\"std\").mem.eql(u8, if (@typeInfo(@TypeOf(__koru_l)) == .optional) __koru_l.? else __koru_l, if (@typeInfo(@TypeOf(__koru_r)) == .optional) __koru_r.? else __koru_r)); })";
}

test "string equality: literal RHS in a guard rewrites to optional-aware mem.eql" {
    const out = (try rewriteZigExpr(std.testing.allocator, "cmd == \"start\"")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(optEqBlock("cmd", "\"start\""), out);
}

test "string equality: literal LHS and != negates" {
    const out = (try rewriteZigExpr(std.testing.allocator, "\"stop\" != cmd")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("!" ++ comptime optEqBlock("\"stop\"", "cmd"), out);
}

test "string equality: compound guard rewrites only the string comparison" {
    const out = (try rewriteZigExpr(std.testing.allocator, "name == \"lars\" and age > 40")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(comptime optEqBlock("name", "\"lars\"") ++ " and age > 40", out);
}

test "string equality: field access operand" {
    const out = (try rewriteZigExpr(std.testing.allocator, "req.path == \"/health\"")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(optEqBlock("req.path", "\"/health\""), out);
}

test "string equality: numeric comparisons are untouched (null)" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "acc.floor == -1 and acc.pos == 0"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "c == '('"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "pv == 0"));
}

test "string equality: an == inside a string literal does not fire" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "\"a == b\""));
}

test "remainder: % rewrites to @rem at every operand type" {
    const out = (try rewriteZigExpr(std.testing.allocator, "n % 2")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@rem(n, 2)", out);
}

test "remainder: only this operator's operands move (precedence)" {
    const sum = (try rewriteZigExpr(std.testing.allocator, "a + b % c")).?;
    defer std.testing.allocator.free(sum);
    try std.testing.expectEqualStrings("a + @rem(b, c)", sum);

    const mul = (try rewriteZigExpr(std.testing.allocator, "a % b * c")).?;
    defer std.testing.allocator.free(mul);
    try std.testing.expectEqualStrings("@rem(a, b) * c", mul);

    // Chained remainder nests left-associatively, like the operator it replaces.
    const chain = (try rewriteZigExpr(std.testing.allocator, "a % b % c")).?;
    defer std.testing.allocator.free(chain);
    try std.testing.expectEqualStrings("@rem(@rem(a, b), c)", chain);
}

test "remainder: a condition carrying both rewrites lowers both" {
    const out = (try rewriteZigExpr(std.testing.allocator, "n % 2 == 0 and cmd == \"go\"")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@rem(n, 2) == 0 and " ++ comptime optEqBlock("cmd", "\"go\""), out);
}

test "remainder: a % inside a string literal does not fire" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "\"50% off\""));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "@import(\"std\").fmt.bufPrint(&b, \"{d}%\", .{share})"));
}

test "remainder: a % nested in a body conditional still lowers" {
    const out = (try rewriteZigExpr(std.testing.allocator, "if (n % 2 == 0) 1 else 0")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("if (@rem(n, 2) == 0) 1 else 0", out);
}

test "conditional: a nested if binds its else to the nearest if" {
    const out = (try rewriteZigExpr(std.testing.allocator, "if (a == 1) if (b % 2 == 0) x else y else z")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("if (a == 1) if (@rem(b, 2) == 0) x else y else z", out);
}

test "conditional: a statement if (block arms, no else) is left alone" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "if (n % 2 == 0) { x = 1; }"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "if (n % 2 == 0) x = 1;"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "if (n % 2 == 0) 1"));
}

test "division: bare / is left alone (needs a type oracle — 030_143)" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "n / 2"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "total / count + 1"));
}

test "string equality: unreadable text returns null, never a guess" {
    // Bit ops, statements, struct literals — all outside the modeled subset.
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "(mask >> j) & 1 == \"x\""));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "const dx = a == \"x\";"));
}

test "string equality: rewrites inside builtin-call arguments" {
    const out = (try rewriteZigExpr(std.testing.allocator, "@intFromBool(s == \"x\")")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@intFromBool(" ++ comptime optEqBlock("s", "\"x\"") ++ ")", out);
}

// The no-literal dispatch shape: both payload types are interrogated at
// comptime — u8 strings take the presence-aware mem.eql arm, everything
// else folds to a plain `==`. Literal operands are skipped because they
// need the result-type context a bare `==` supplies.
fn optEqDispatchBlock(comptime l: []const u8, comptime r: []const u8) []const u8 {
    return "(blk: { const __koru_l = " ++ l ++ "; const __koru_r = " ++ r ++ "; const __koru_lo = @typeInfo(@TypeOf(__koru_l)) == .optional; const __koru_ro = @typeInfo(@TypeOf(__koru_r)) == .optional; const __koru_lp = if (__koru_lo) @typeInfo(@TypeOf(__koru_l)).optional.child else @TypeOf(__koru_l); const __koru_rp = if (__koru_ro) @typeInfo(@TypeOf(__koru_r)).optional.child else @TypeOf(__koru_r); const __koru_ls = __koru_str: { const __koru_ty = @typeInfo(__koru_lp); if (__koru_ty == .array) break :__koru_str __koru_ty.array.child == u8; if (__koru_ty == .pointer) { const __koru_ptr = __koru_ty.pointer; if (__koru_ptr.size == .slice and __koru_ptr.child == u8) break :__koru_str true; break :__koru_str __koru_ptr.size == .one and @typeInfo(__koru_ptr.child) == .array and @typeInfo(__koru_ptr.child).array.child == u8; } break :__koru_str false; }; const __koru_rs = __koru_str: { const __koru_ty = @typeInfo(__koru_rp); if (__koru_ty == .array) break :__koru_str __koru_ty.array.child == u8; if (__koru_ty == .pointer) { const __koru_ptr = __koru_ty.pointer; if (__koru_ptr.size == .slice and __koru_ptr.child == u8) break :__koru_str true; break :__koru_str __koru_ptr.size == .one and @typeInfo(__koru_ptr.child) == .array and @typeInfo(__koru_ptr.child).array.child == u8; } break :__koru_str false; }; if (__koru_ls and __koru_rs) { const __koru_ln = if (__koru_lo) __koru_l == null else false; const __koru_rn = if (__koru_ro) __koru_r == null else false; break :blk (__koru_ln == __koru_rn) and (__koru_ln or @import(\"std\").mem.eql(u8, if (__koru_lo) __koru_l.? else __koru_l, if (__koru_ro) __koru_r.? else __koru_r)); } else break :blk __koru_l == __koru_r; })";
}

test "string equality: identifier == identifier lowers to the type-dispatch block" {
    const out = (try rewriteZigExpr(std.testing.allocator, "left == right")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(comptime optEqDispatchBlock("left", "right"), out);
}

test "string equality: identifier != identifier negates the dispatch" {
    const out = (try rewriteZigExpr(std.testing.allocator, "a.b != c.d")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("!" ++ comptime optEqDispatchBlock("a.b", "c.d"), out);
}

test "string equality: literal-carrying comparisons stay verbatim" {
    // Numbers, enum literals, null, bools — the bare `==` supplies the
    // result-type context a `const` binding would strand them without.
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "acc.floor == -1"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "k == .audio"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "x == null"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "flag == true"));
}

test "intCast: @as-wrapped cast routes through __koru_intcast" {
    const out = (try rewriteZigExpr(std.testing.allocator, "@as(i64, @intCast(i))")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("__koru_intcast(i64, i)", out);
}

test "intCast: a cast inside a larger expression rewrites only the cast" {
    const out = (try rewriteZigExpr(std.testing.allocator, "acc.sum + @as(i64, @intCast(i)) * 3")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("acc.sum + __koru_intcast(i64, i) * 3", out);
}

test "intCast: index-position bare cast coerces to usize" {
    const out = (try rewriteZigExpr(std.testing.allocator, "s[@intCast(i)] == 34")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("s[__koru_intcast(usize, i)] == 34", out);
}

test "intCast: a cast nested inside call arguments still lowers" {
    const out = (try rewriteZigExpr(std.testing.allocator, "visit(@as(i64, @intCast(i)), flag)")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("visit(__koru_intcast(i64, i), flag)", out);
}

test "intCast: a bare cast stays verbatim (no inferred type to feed it)" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "x = @intCast(i)"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "@intCast(i)"));
}

test "intCast: @as with a non-intCast second argument is left alone" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "@as(i64, x + 1)"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteZigExpr(std.testing.allocator, "@as(i64, @bitCast(i))"));
}
