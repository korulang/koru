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
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
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
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
            // Now at next field position
            if (i < input.len and input[i] != '}') {
                const field_result = try parseFieldAndValue(allocator, input, i, &result);
                i = field_result;
            }
        } else if (c == '}') {
            // Closing brace - just output it
            try result.append(allocator, '}');
            i += 1;
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

/// Parse a field name, colon, and value. Output as ".fieldname = value"
/// Returns the new position after the value.
fn parseFieldAndValue(
    allocator: std.mem.Allocator,
    input: []const u8,
    start: usize,
    result: *std.ArrayList(u8),
) ExprParseError!usize {
    var i = start;

    // Read field name (identifier)
    const field_start = i;
    while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) {
        i += 1;
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
        // Output ".fieldname = "
        try result.append(allocator, '.');
        try result.appendSlice(allocator, field_name);
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
        try result.appendSlice(allocator, field_name);
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

        if (c == '{') {
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
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
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
            while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n')) {
                try result.append(allocator, input[i]);
                i += 1;
            }
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
// WHAT THAT DEFERS, said plainly so it does not go invisible: the vocabulary is
// ENFORCED on JS and ABSENT on Zig. A `.k` naming an `@foo` nobody modelled is
// accepted by one target and refused by the other, so the table can drift into
// "whatever JS happened to need" — the one-direction-of-a-symmetry shape this
// repo has been bitten by before. Closing it means growing the `.zig` arm from
// identity to table-consulting, which is a WALL and will turn things red on
// purpose. That is the next rung and it is a language ruling, not a refactor.

/// Which host the expression is being rendered for.
pub const HostTarget = enum { zig, js };

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
/// while the identical condition, baked into a `for|template|js` body, arrives
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
        // 2026-08-07, above) — but "comparison is shared" has one hole: `==`
        // on two strings. Koru's `==` is value equality (comptime_eval.zig
        // folds it with `mem.eql`; the interpreter and the JS target agree),
        // and Zig has no spelling for that on slices — pasted through, it is
        // a raw Stage-D "cannot compare strings with ==". So the one rewrite
        // this arm carries is semantic, not vocabulary: a literal-grounded
        // string comparison becomes `@import("std").mem.eql(u8, …)`.
        if (mode != .host_text) {
            if (rewriteStringEqualityZig(allocator, text) catch null) |rewritten| {
                return rewritten;
            }
        }
        return allocator.dupe(u8, text);
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, text.len + 32);
    errdefer out.deinit(allocator);
    try lowerJsInto(&out, allocator, text, mode, diag);
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
    pub fn branchOne(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "{{ tag: \"{s}\", {s}: {s} }}", .{ name, name, value }) catch unreachable
        else
            std.fmt.allocPrint(alloc, ".{{ .{s} = {s} }}", .{ name, value }) catch unreachable;
    }

    /// `| name` — a branch that carries nothing.
    pub fn branchEmpty(alloc: std.mem.Allocator, t: HostTarget, name: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "{{ tag: \"{s}\", {s}: {{}} }}", .{ name, name }) catch unreachable
        else
            std.fmt.allocPrint(alloc, ".{{ .{s} = .{{}} }}", .{name}) catch unreachable;
    }

    /// `| name { a, b }` — a record payload. `body` is the already-joined field
    /// list in the host's own spelling, which `recField` produces.
    pub fn branchRec(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, body: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "{{ tag: \"{s}\", {s}: {{ {s} }} }}", .{ name, name, body }) catch unreachable
        else
            std.fmt.allocPrint(alloc, ".{{ .{s} = .{{ {s} }} }}", .{ name, body }) catch unreachable;
    }

    /// One `name = value` pair inside a record payload or argument object.
    pub fn recField(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, value }) catch unreachable
        else
            std.fmt.allocPrint(alloc, ".{s} = {s}", .{ name, value }) catch unreachable;
    }

    /// A handler's ARGUMENT object — `.{ … }` on Zig, `{ … }` on JS. Not a
    /// branch: nothing is tagged, it is just the input record. `body` is the
    /// already-joined pair list from `recField`; empty for a no-arg call.
    pub fn argRec(alloc: std.mem.Allocator, t: HostTarget, body: []const u8) []const u8 {
        if (body.len == 0) return if (t == .js) "{}" else ".{}";
        return if (t == .js)
            std.fmt.allocPrint(alloc, "{{ {s} }}", .{body}) catch unreachable
        else
            std.fmt.allocPrint(alloc, ".{{ {s} }}", .{body}) catch unreachable;
    }

    /// A COLUMN-ORDINAL DISPATCH. The arms' statements are largely the same text
    /// on both hosts (`__koru_store_x.hp[__koru_r] = value_0;` needs no
    /// translation); what differs is the frame. Zig writes a switch EXPRESSION
    /// whose arms are `blk: { … break :blk v; }`, closed with `else =>
    /// unreachable`. JS writes a switch STATEMENT whose arms `return`, followed
    /// by a throw — falling out of a JS switch yields `undefined`, and the
    /// caller would read that as a branch object.
    pub fn switchHead(t: HostTarget) []const u8 {
        return if (t == .js) "switch (field) {\n" else "return switch (field) {\n";
    }

    pub fn switchArmOpen(alloc: std.mem.Allocator, t: HostTarget, ordinal: usize) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "  case {d}: {{ ", .{ordinal}) catch unreachable
        else
            std.fmt.allocPrint(alloc, "    {d} => blk: {{ ", .{ordinal}) catch unreachable;
    }

    pub fn switchArmClose(alloc: std.mem.Allocator, t: HostTarget, value: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "return {s}; }}\n", .{value}) catch unreachable
        else
            std.fmt.allocPrint(alloc, "break :blk {s}; }},\n", .{value}) catch unreachable;
    }

    pub fn switchTail(alloc: std.mem.Allocator, t: HostTarget, unit: []const u8, store: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "}}\nthrow new Error(\"{s}: field index \" + field + \" is not a column of store '{s}'\");", .{ unit, store }) catch unreachable
        else
            "    else => unreachable,\n};";
    }

    /// `row` arrives DENSE, so Zig only needs the index cast; JS has no such
    /// distinction and binds it straight through, keeping one name for the
    /// statements above to share.
    pub fn rowHead(t: HostTarget) []const u8 {
        return if (t == .js) "const __koru_r = row;\n" else "const __koru_r = @as(usize, @intCast(row));\n";
    }

    /// A COUNTED LOOP over `0..limit`, binding `cursor`. Zig's range-`for` and
    /// JS's three-clause `for` are the same loop and share nothing textually.
    pub fn loopHead(alloc: std.mem.Allocator, t: HostTarget, cursor: []const u8, limit: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "for (let {s} = 0; {s} < {s}; {s}++) {{\n", .{ cursor, cursor, limit, cursor }) catch unreachable
        else
            std.fmt.allocPrint(alloc, "for (0..{s}) |{s}| {{\n", .{ limit, cursor }) catch unreachable;
    }

    /// Bind a loop-local `const`. Zig warns on an unused local, and a projected
    /// column the body never reads is normal, so the Zig arm carries the `_ = &x`
    /// discard. JS has no such rule and the discard is a syntax error there.
    pub fn constBind(alloc: std.mem.Allocator, t: HostTarget, name: []const u8, value: []const u8) []const u8 {
        return if (t == .js)
            std.fmt.allocPrint(alloc, "const {s} = {s};\n", .{ name, value }) catch unreachable
        else
            std.fmt.allocPrint(alloc, "const {s} = {s};\n_ = &{s};\n", .{ name, value, name }) catch unreachable;
    }

    /// A dense cursor used where the host expects a signed integer. Zig needs
    /// the cast; JS has one number type.
    pub fn asI64(alloc: std.mem.Allocator, t: HostTarget, expr: []const u8) []const u8 {
        return if (t == .js)
            alloc.dupe(u8, expr) catch unreachable
        else
            std.fmt.allocPrint(alloc, "@as(i64, @intCast({s}))", .{expr}) catch unreachable;
    }

    /// A dense cursor used as an INDEX. Same split, different target type.
    pub fn asIndex(alloc: std.mem.Allocator, t: HostTarget, expr: []const u8) []const u8 {
        return if (t == .js)
            alloc.dupe(u8, expr) catch unreachable
        else
            std.fmt.allocPrint(alloc, "@as(usize, @intCast({s}))", .{expr}) catch unreachable;
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
/// the shape the `for|template|js` body renders for every `~for(&xs)` in the
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

/// THE VOCABULARY. Lower one `@`-operation starting at `text[at] == '@'`,
/// returning the index just past it, or null when the `@` does not open a call at
/// all (so the caller writes it through unchanged).
///
/// Every operation Koru names with an `@` is listed here, and an operation that
/// is not listed is REFUSED rather than passed through. That refusal is the only
/// reason this list is a definition instead of a description.
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
    // A bool IS 0/1 once it is a number, and JS `+true` is 1. `Number(...)` is
    // the spelling that cannot be misread as string concatenation when the
    // operand is spliced next to a `+`.
    if (eql(u8, name, "intFromBool")) {
        try out.appendSlice(allocator, "Number(");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
    }
    if (eql(u8, name, "intFromFloat")) {
        try out.appendSlice(allocator, "Math.trunc(");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
    }
    // JS bitwise operators coerce to 32 bits, so the population count is done on
    // the value itself rather than through `>>`/`&`, which would silently answer
    // for the low 32 bits of a 53-bit-safe integer.
    if (eql(u8, name, "popCount")) {
        try out.appendSlice(allocator, "((v) => { let n = 0; let x = v; while (x > 0) { n += x % 2; x = Math.floor(x / 2); } return n; })(");
        try lowerJsInto(out, allocator, first, .koru_expr, diag);
        try out.append(allocator, ')');
        return j;
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
    if (eql(u8, name, "min") or eql(u8, name, "max") or eql(u8, name, "abs") or eql(u8, name, "sqrt")) {
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

/// Replace word-boundary-matched identifier occurrences in text — but only
/// where the occurrence is code (see zigCodeMask). Rewriting a name inside a
/// string literal ships a corrupted program that still compiles (230_016).
pub fn replaceIdentifier(allocator: std.mem.Allocator, text: []const u8, old_name: []const u8, new_name: []const u8) ![]const u8 {
    if (old_name.len == 0) return try allocator.dupe(u8, text);

    const mask = try zigCodeMask(allocator, text);
    defer allocator.free(mask);

    var result = try std.ArrayList(u8).initCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (mask[i] and i + old_name.len <= text.len and std.mem.eql(u8, text[i .. i + old_name.len], old_name)) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(text[i - 1]) and text[i - 1] != '_');
            const after_idx = i + old_name.len;
            const after_ok = (after_idx >= text.len) or (!std.ascii.isAlphanumeric(text[after_idx]) and text[after_idx] != '_');
            if (before_ok and after_ok) {
                try result.appendSlice(allocator, new_name);
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
// RUNTIME STRING EQUALITY — the Zig spelling of Koru's `==` on strings
// ============================================================================
//
// Koru's `==` on two strings is VALUE equality. Every organ that already has
// an opinion agrees: the comptime fold (`comptime_eval.zig`, `.equal` on two
// `.string`s is `mem.eql`), the interpreter (`koru_std/interpreter.kz`), and
// the JS target (verbatim `==` — which in JavaScript IS string value
// equality). The Zig target was the odd one out: the expression text was
// pasted through, and `[]const u8 == []const u8` is a Zig compile error, so a
// `when` guard or `if` condition comparing strings died at Stage D quoting the
// host ("cannot compare strings with ==") — one target implementing what the
// other three meant.
//
// WHAT REWRITES: a `==` / `!=` whose either operand is a double-quoted string
// LITERAL — the syntactically decidable subset, and the whole dispatch family
// ("is this command/route/config-key equal to that word"). It becomes
// `@import("std").mem.eql(u8, lhs, rhs)` (negated for `!=`), spliced back
// with every other byte of the expression preserved.
//
// WHAT DOES NOT (yet): `a == b` where both sides are string-TYPED names.
// Deciding that needs a type oracle at the rewrite site; guessing would
// rewrite numeric comparisons into `mem.eql` and corrupt working code. Those
// comparisons still fail loudly at Stage D on Zig (and work on JS) — the
// remaining half of this symmetry, not a silent wrong answer.
//
// The scan is CONSERVATIVE BY CONSTRUCTION: the text is parsed with a small
// span-tracking expression parser, and anything it does not fully recognize —
// statement text, bit operators, struct literals, host-only syntax — returns
// null and the caller keeps the original bytes. Unchanged regions are copied
// from the source by span, never re-rendered, so a non-matching expression is
// byte-identical.

const StrEqError = error{ NoParse, OutOfMemory };

/// A parsed subexpression: its rendered text (rewritten iff `changed`),
/// its source span, and whether it is exactly one string literal.
const StrEqPiece = struct {
    text: []const u8,
    start: usize,
    end: usize,
    is_string_lit: bool,
    changed: bool,
};

const StrEqParser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize,

    fn skipWs(self: *StrEqParser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn peek(self: *StrEqParser) u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else 0;
    }

    /// Word-boundary keyword match at the current position.
    fn atKeyword(self: *StrEqParser, kw: []const u8) bool {
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
    fn combine(self: *StrEqParser, left: StrEqPiece, right: StrEqPiece) StrEqError!StrEqPiece {
        if (!left.changed and !right.changed) {
            return .{ .text = self.text[left.start..right.end], .start = left.start, .end = right.end, .is_string_lit = false, .changed = false };
        }
        const joined = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            left.text, self.text[left.end..right.start], right.text,
        }) catch return StrEqError.OutOfMemory;
        return .{ .text = joined, .start = left.start, .end = right.end, .is_string_lit = false, .changed = true };
    }

    fn parseOr(self: *StrEqParser) StrEqError!StrEqPiece {
        var left = try self.parseAnd();
        while (true) {
            self.skipWs();
            if (self.atKeyword("or")) {
                self.pos += 2;
            } else if (self.pos + 1 < self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + 2], "||")) {
                self.pos += 2;
            } else break;
            const right = try self.parseAnd();
            left = try self.combine(left, right);
        }
        return left;
    }

    fn parseAnd(self: *StrEqParser) StrEqError!StrEqPiece {
        var left = try self.parseEq();
        while (true) {
            self.skipWs();
            if (self.atKeyword("and")) {
                self.pos += 3;
            } else if (self.pos + 1 < self.text.len and std.mem.eql(u8, self.text[self.pos .. self.pos + 2], "&&")) {
                self.pos += 2;
            } else break;
            const right = try self.parseEq();
            left = try self.combine(left, right);
        }
        return left;
    }

    /// THE REWRITE LEVEL. `==` / `!=` with a string-literal operand becomes
    /// the `mem.eql` call; every other comparison combines verbatim.
    fn parseEq(self: *StrEqParser) StrEqError!StrEqPiece {
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
                const call = std.fmt.allocPrint(self.allocator, "{s}@import(\"std\").mem.eql(u8, {s}, {s})", .{
                    if (negated) "!" else "", left.text, right.text,
                }) catch return StrEqError.OutOfMemory;
                left = .{ .text = call, .start = left.start, .end = right.end, .is_string_lit = false, .changed = true };
            } else {
                left = try self.combine(left, right);
            }
        }
        return left;
    }

    fn parseCmp(self: *StrEqParser) StrEqError!StrEqPiece {
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

    fn parseConcat(self: *StrEqParser) StrEqError!StrEqPiece {
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

    fn parseAdd(self: *StrEqParser) StrEqError!StrEqPiece {
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

    fn parseMul(self: *StrEqParser) StrEqError!StrEqPiece {
        var left = try self.parseUnary();
        while (true) {
            self.skipWs();
            const c = self.peek();
            if (c == '*' or c == '/' or c == '%') {
                self.pos += 1;
            } else break;
            const right = try self.parseUnary();
            left = try self.combine(left, right);
        }
        return left;
    }

    fn parseUnary(self: *StrEqParser) StrEqError!StrEqPiece {
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
            }) catch return StrEqError.OutOfMemory;
            return .{ .text = joined, .start = start, .end = operand.end, .is_string_lit = false, .changed = true };
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *StrEqParser) StrEqError!StrEqPiece {
        var result = try self.parsePrimary();
        while (true) {
            // No skipWs here: postfix binds tightly, and a space before `(`
            // or `[` in guard text is not a call we need to model.
            const c = self.peek();
            if (c == '.') {
                if (self.pos + 1 >= self.text.len or !exprIdentStartChar(self.text[self.pos + 1])) return StrEqError.NoParse;
                const dot_at = self.pos;
                self.pos += 1;
                _ = try self.parseIdentName();
                if (result.changed) {
                    const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ result.text, self.text[dot_at..self.pos] }) catch return StrEqError.OutOfMemory;
                    result = .{ .text = joined, .start = result.start, .end = self.pos, .is_string_lit = false, .changed = true };
                } else {
                    result = .{ .text = self.text[result.start..self.pos], .start = result.start, .end = self.pos, .is_string_lit = false, .changed = false };
                }
            } else if (c == '(' or c == '[') {
                const inner = try self.parseBalanced(c);
                if (inner.changed or result.changed) {
                    const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ result.text, inner.text }) catch return StrEqError.OutOfMemory;
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
    fn parseBalanced(self: *StrEqParser, open: u8) StrEqError!StrEqPiece {
        const close: u8 = if (open == '(') ')' else ']';
        const start = self.pos;
        self.pos += 1;
        var out = std.ArrayList(u8).initCapacity(self.allocator, 8) catch return StrEqError.OutOfMemory;
        out.append(self.allocator, open) catch return StrEqError.OutOfMemory;
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
                    if (c != close) return StrEqError.NoParse;
                    const seg = self.text[seg_start..self.pos];
                    const low = rewriteStrEqInner(self.allocator, seg);
                    if (low) |l| {
                        changed = true;
                        out.appendSlice(self.allocator, l) catch return StrEqError.OutOfMemory;
                    } else {
                        out.appendSlice(self.allocator, seg) catch return StrEqError.OutOfMemory;
                    }
                    out.append(self.allocator, close) catch return StrEqError.OutOfMemory;
                    self.pos += 1;
                    return .{
                        .text = if (changed) (out.toOwnedSlice(self.allocator) catch return StrEqError.OutOfMemory) else self.text[start..self.pos],
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
                const low = rewriteStrEqInner(self.allocator, seg);
                if (low) |l| {
                    changed = true;
                    out.appendSlice(self.allocator, l) catch return StrEqError.OutOfMemory;
                } else {
                    out.appendSlice(self.allocator, seg) catch return StrEqError.OutOfMemory;
                }
                out.append(self.allocator, ',') catch return StrEqError.OutOfMemory;
                seg_start = self.pos + 1;
            }
            self.pos += 1;
        }
        return StrEqError.NoParse;
    }

    /// Skip a `"…"` or `'…'` literal including escapes; pos lands after the
    /// closing quote.
    fn skipStringLike(self: *StrEqParser, quote: u8) StrEqError!void {
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
        return StrEqError.NoParse;
    }

    fn parseIdentName(self: *StrEqParser) StrEqError!void {
        if (!exprIdentStartChar(self.peek())) return StrEqError.NoParse;
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

    fn parsePrimary(self: *StrEqParser) StrEqError!StrEqPiece {
        self.skipWs();
        const start = self.pos;
        const c = self.peek();
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
            if (self.peek() != ')') return StrEqError.NoParse;
            self.pos += 1;
            if (!inner.changed) {
                return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
            }
            const joined = std.fmt.allocPrint(self.allocator, "({s})", .{inner.text}) catch return StrEqError.OutOfMemory;
            return .{ .text = joined, .start = start, .end = self.pos, .is_string_lit = false, .changed = true };
        }
        if (c == '@') {
            self.pos += 1;
            try self.parseIdentName();
            self.skipWs();
            if (self.peek() != '(') return StrEqError.NoParse;
            const inner = try self.parseBalanced('(');
            if (!inner.changed) {
                return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
            }
            const joined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.text[start..inner.start], inner.text }) catch return StrEqError.OutOfMemory;
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
        if (exprIdentStartChar(c)) {
            try self.parseIdentName();
            return .{ .text = self.text[start..self.pos], .start = start, .end = self.pos, .is_string_lit = false, .changed = false };
        }
        return StrEqError.NoParse;
    }
};

fn exprIdentStartChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Rewrite literal-grounded string `==` / `!=` in one Koru expression into the
/// Zig value-equality spelling. Returns null when the text has no such
/// comparison OR cannot be fully read as an expression — in both cases the
/// caller keeps the original bytes, so this can never corrupt text it does
/// not understand. The result (when non-null) is owned by the caller; every
/// intermediate lives in an arena.
pub fn rewriteStringEqualityZig(allocator: std.mem.Allocator, text: []const u8) StrEqError!?[]const u8 {
    // Fast reject: no `==` / `!=` — nothing to parse at all.
    if (std.mem.indexOf(u8, text, "==") == null and std.mem.indexOf(u8, text, "!=") == null) return null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rewritten = rewriteStrEqInner(arena.allocator(), text) orelse return null;
    return allocator.dupe(u8, rewritten) catch return StrEqError.OutOfMemory;
}

/// Arena-side worker: parse and rewrite, or null for identity. Recursion
/// (call-argument segments in `parseBalanced`) re-enters HERE so every
/// intermediate shares one arena and one lifetime.
fn rewriteStrEqInner(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "==") == null and std.mem.indexOf(u8, text, "!=") == null) return null;
    var parser = StrEqParser{ .allocator = allocator, .text = text, .pos = 0 };
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

test "string equality: literal RHS in a guard rewrites to mem.eql" {
    const out = (try rewriteStringEqualityZig(std.testing.allocator, "cmd == \"start\"")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@import(\"std\").mem.eql(u8, cmd, \"start\")", out);
}

test "string equality: literal LHS and != negates" {
    const out = (try rewriteStringEqualityZig(std.testing.allocator, "\"stop\" != cmd")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("!@import(\"std\").mem.eql(u8, \"stop\", cmd)", out);
}

test "string equality: compound guard rewrites only the string comparison" {
    const out = (try rewriteStringEqualityZig(std.testing.allocator, "name == \"lars\" and age > 40")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@import(\"std\").mem.eql(u8, name, \"lars\") and age > 40", out);
}

test "string equality: field access operand" {
    const out = (try rewriteStringEqualityZig(std.testing.allocator, "req.path == \"/health\"")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@import(\"std\").mem.eql(u8, req.path, \"/health\")", out);
}

test "string equality: numeric comparisons are untouched (null)" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "acc.floor == -1 and acc.pos == 0"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "c == '('"));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "pv == 0"));
}

test "string equality: an == inside a string literal does not fire" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "\"a == b\""));
}

test "string equality: unreadable text returns null, never a guess" {
    // Bit ops, statements, struct literals — all outside the modeled subset.
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "(mask >> j) & 1 == \"x\""));
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "const dx = a == \"x\";"));
}

test "string equality: rewrites inside builtin-call arguments" {
    const out = (try rewriteStringEqualityZig(std.testing.allocator, "@intFromBool(s == \"x\")")).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("@intFromBool(@import(\"std\").mem.eql(u8, s, \"x\"))", out);
}

test "string equality: identifier == identifier is left alone (needs a type oracle)" {
    try std.testing.expectEqual(@as(?[]const u8, null), try rewriteStringEqualityZig(std.testing.allocator, "left == right"));
}
