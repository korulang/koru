// ============================================================================
// Annotation Parser - Shared Utilities for Parametrized Annotations
// ============================================================================
// This library provides parsing and querying utilities for Koru annotations.
//
// Koru annotations are stored as opaque strings in the AST:
//   annotations: []const []const u8 = &[_][]const u8{}
//
// Simple annotations: "pure", "comptime", "norun"
// Parametrized annotations: "depends_on(\"a\", \"b\")", "timeout(30)", "retry(3)"
//
// This library enables:
// - Frontend: Parse build orchestration annotations
// - Backend: Parse comptime metaprogramming annotations
// - Future: Any parametrized annotation (cache, retry, timeout, etc.)
//
// Design Philosophy:
// - Parser treats annotations as opaque strings
// - This library interprets the syntax
// - Separation of concerns: syntax vs semantics
// ============================================================================

const std = @import("std");

/// AnnotationCall represents a parsed parametrized annotation
/// Example: "depends_on(\"compile\", \"test\")" →
///   AnnotationCall{ .name = "depends_on", .args = ["compile", "test"] }
pub const AnnotationCall = struct {
    name: []const u8,
    args: [][]const u8,

    /// Free all memory associated with this annotation call
    pub fn deinit(self: *AnnotationCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.args) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.args);
    }
};

/// Parse a single annotation string into an AnnotationCall
/// Returns null if the annotation is not a parametrized call (simple annotation)
/// Returns error if the annotation has invalid syntax
///
/// Examples:
///   parseCall("depends_on(\"a\", \"b\")") → AnnotationCall{ name="depends_on", args=["a", "b"] }
///   parseCall("pure") → null (simple annotation)
///   parseCall("timeout(30)") → AnnotationCall{ name="timeout", args=["30"] }
///   parseCall("invalid(") → error.InvalidSyntax
pub fn parseCall(allocator: std.mem.Allocator, annotation: []const u8) !?AnnotationCall {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, annotation, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Find opening parenthesis
    const open_paren_pos = std.mem.indexOf(u8, trimmed, "(") orelse {
        // No parenthesis → simple annotation
        return null;
    };

    // Extract name (everything before '(')
    const name = std.mem.trim(u8, trimmed[0..open_paren_pos], " \t");
    if (name.len == 0) return error.InvalidSyntax;

    // Find closing parenthesis
    if (trimmed[trimmed.len - 1] != ')') {
        return error.InvalidSyntax;
    }

    // Extract argument list (everything between '(' and ')')
    const args_str = trimmed[open_paren_pos + 1 .. trimmed.len - 1];

    // Parse arguments (comma-separated, quoted strings)
    var args = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    // If empty args, return empty list
    const args_trimmed = std.mem.trim(u8, args_str, " \t");
    if (args_trimmed.len == 0) {
        return AnnotationCall{
            .name = try allocator.dupe(u8, name),
            .args = try args.toOwnedSlice(allocator),
        };
    }

    // Parse comma-separated arguments
    // State machine to handle quoted strings with commas inside
    var i: usize = 0;
    var current_arg_start: usize = 0;
    var in_string: bool = false;
    var escape_next: bool = false;

    while (i < args_trimmed.len) : (i += 1) {
        const c = args_trimmed[i];

        if (escape_next) {
            escape_next = false;
            continue;
        }

        if (c == '\\') {
            escape_next = true;
            continue;
        }

        if (c == '"') {
            in_string = !in_string;
            continue;
        }

        if (c == ',' and !in_string) {
            // Found argument boundary
            const arg_str = std.mem.trim(u8, args_trimmed[current_arg_start..i], " \t");
            const parsed_arg = try parseArgumentValue(allocator, arg_str);
            try args.append(allocator, parsed_arg);
            current_arg_start = i + 1;
        }
    }

    // Handle last argument
    if (current_arg_start < args_trimmed.len) {
        const arg_str = std.mem.trim(u8, args_trimmed[current_arg_start..], " \t");
        const parsed_arg = try parseArgumentValue(allocator, arg_str);
        try args.append(allocator, parsed_arg);
    }

    return AnnotationCall{
        .name = try allocator.dupe(u8, name),
        .args = try args.toOwnedSlice(allocator),
    };
}

/// Parse a single argument value, handling quoted strings and unquoted literals
/// Examples:
///   "\"hello\"" → "hello" (strip quotes, handle escapes)
///   "42" → "42" (keep as-is)
fn parseArgumentValue(allocator: std.mem.Allocator, arg_str: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, arg_str, " \t");

    // If it starts and ends with quotes, it's a string literal
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        const inner = trimmed[1 .. trimmed.len - 1];
        // Handle escape sequences
        return try unescapeString(allocator, inner);
    }

    // Otherwise, keep as-is (number, identifier, etc.)
    return try allocator.dupe(u8, trimmed);
}

/// Unescape a string (handle \", \\, \n, etc.)
fn unescapeString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, s.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            const next = s[i + 1];
            switch (next) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                'r' => try result.append(allocator, '\r'),
                else => {
                    // Unknown escape, keep both characters
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                },
            }
            i += 1; // Skip the next character
        } else {
            try result.append(allocator, s[i]);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if an annotation list contains a simple annotation
/// Example: hasSimple(annotations, "pure") checks for ~[pure]
pub fn hasSimple(annotations: []const []const u8, name: []const u8) bool {
    for (annotations) |ann| {
        if (std.mem.eql(u8, ann, name)) return true;
    }
    return false;
}

/// Check if an annotation list contains an annotation part in a compound annotation
/// Compound annotations use | as separator: comptime|transform, comptime|norun
/// Example: hasPart(annotations, "transform") returns true for [comptime|transform]
/// Example: hasPart(annotations, "comptime") returns true for both [comptime] and [comptime|transform]
pub fn hasPart(annotations: []const []const u8, part_name: []const u8) bool {
    for (annotations) |ann| {
        // Check if annotation matches exactly (simple case)
        if (std.mem.eql(u8, ann, part_name)) return true;

        // Check if annotation contains the part as a pipe-separated component
        var iter = std.mem.splitScalar(u8, ann, '|');
        while (iter.next()) |ann_part| {
            const trimmed = std.mem.trim(u8, ann_part, " \t");
            if (std.mem.eql(u8, trimmed, part_name)) return true;
        }
    }
    return false;
}

/// Check if an event has the [keyword] annotation
/// Events with [keyword] can be invoked without module qualification
pub fn isKeyword(annotations: []const []const u8) bool {
    return hasPart(annotations, "keyword");
}

/// Get a parametrized annotation call by name
/// Returns the parsed AnnotationCall if found, null otherwise
/// Example: getCall(annotations, "depends_on") → AnnotationCall with args
pub fn getCall(
    allocator: std.mem.Allocator,
    annotations: []const []const u8,
    name: []const u8,
) !?AnnotationCall {
    for (annotations) |ann| {
        // Try to parse as a call
        if (try parseCall(allocator, ann)) |call| {
            // Check if the name matches
            if (std.mem.eql(u8, call.name, name)) {
                return call;
            }
            // Name doesn't match, clean up and continue
            var mutable_call = call;
            mutable_call.deinit(allocator);
        }
    }
    return null;
}

// ============================================================================
// Block tokenizer — nesting- and string-aware entry delimiting
// ============================================================================
// An annotation block is a LIST OF ENTRIES: pipe-separated inline, bullet-
// separated vertical. The pipe is a list delimiter and semantically silent —
// it never delimits inside nested ()/[]/{} pairs or "..." strings, so entries
// like `custom(foo(bar: 1))`, `other[x, y]`, and `doc("a|b")` stay whole.
// These two functions are the ONLY place that knowledge lives; the parser and
// every downstream consumer delimit through them, never with indexOf/split.

/// Scan `text` for the `]` that CLOSES an annotation block whose opening `[`
/// has already been consumed — the first `]` at nesting depth 0. Nested
/// `[...]`/`(...)`/`{...}` pairs and `"..."` strings (with `\` escapes) are
/// skipped over. Returns null when the closer is not in `text` (the vertical
/// form, where the block closes on a later line).
pub fn findBlockClose(text: []const u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '(', '{' => depth += 1,
            ')', '}' => {
                if (depth > 0) depth -= 1;
            },
            ']' => {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

/// Split annotation-block content (the text between the block's brackets)
/// into top-level entries: pipes at depth 0 delimit; pipes inside nested
/// pairs or strings belong to their entry. Entries are trimmed and empty
/// entries dropped. The returned entries are slices into `content` (no
/// copies); the caller owns (and frees) only the outer slice.
pub fn splitEntries(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var entries = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer entries.deinit(allocator);
    var depth: usize = 0;
    var in_string = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '(', '{' => depth += 1,
            ']', ')', '}' => {
                if (depth > 0) depth -= 1;
            },
            '|' => {
                if (depth == 0) {
                    const entry = std.mem.trim(u8, content[start..i], " \t");
                    if (entry.len > 0) try entries.append(allocator, entry);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, content[start..], " \t");
    if (last.len > 0) try entries.append(allocator, last);
    return entries.toOwnedSlice(allocator);
}

/// Scan annotation-block content for a character that LOOKS like a separator but
/// is not one, and return its offset into `content`.
///
/// Annotations delimit on `|`. A `,` at depth 0 is therefore never a separator
/// and never part of a well-formed entry either — `~[default, depends_on(x)]`
/// parses as ONE entry spelled `"default, depends_on(x)"`, which matches no
/// annotation, so the block silently means nothing it appears to mean. That
/// exact shape shipped in `koru_std/build.kz` and dropped a real `depends_on`
/// dependency with no diagnostic; it is the reason this predicate exists.
///
/// Depth and strings are tracked with the same rules as `splitEntries`, because
/// the comma that IS legal must keep being legal: `depends_on(a, b)` is one
/// entry's argument list (depth 1) and `doc("a, b")` is inside a string. Only a
/// top-level comma is a mistake.
pub fn findInvalidSeparator(content: []const u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '(', '{' => depth += 1,
            ']', ')', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => {
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Rewrite `content`'s top-level `,` separators as `|`, leaving every nested and
/// in-string comma untouched — the corrected spelling to show the author.
///
/// A diagnostic that echoes the broken text back teaches nothing; the whole
/// value of refusing this shape is handing over the form that works. Depth and
/// string rules are shared with `findInvalidSeparator` and `splitEntries`, so
/// the suggestion can never differ from what the parser would then accept.
/// A `, ` collapses to a single `|` rather than `| ` so the result matches the
/// canonical spelling used everywhere in the tree (`~[comptime|transform]`).
/// Caller owns the returned buffer.
pub fn suggestPipeSeparators(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, content.len);
    errdefer out.deinit(allocator);

    var depth: usize = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_string) {
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < content.len) {
                i += 1;
                try out.append(allocator, content[i]);
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => {
                in_string = true;
                try out.append(allocator, c);
            },
            '[', '(', '{' => {
                depth += 1;
                try out.append(allocator, c);
            },
            ']', ')', '}' => {
                if (depth > 0) depth -= 1;
                try out.append(allocator, c);
            },
            ',' => {
                if (depth == 0) {
                    try out.append(allocator, '|');
                    // Swallow the run of spaces/tabs that followed the comma so
                    // `a, b` becomes `a|b` and not `a| b`.
                    while (i + 1 < content.len and (content[i + 1] == ' ' or content[i + 1] == '\t')) i += 1;
                } else {
                    try out.append(allocator, c);
                }
            },
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "findBlockClose - flat block" {
    try std.testing.expectEqual(@as(?usize, 4), findBlockClose("pure]event x"));
}

test "findBlockClose - skips nested pairs" {
    // custom(foo[1])]rest → the closer is after the balanced nesting
    const text = "custom(foo[1])]rest";
    try std.testing.expectEqual(@as(?usize, 14), findBlockClose(text));
}

test "findBlockClose - skips strings with escapes and brackets" {
    const text = "doc(\"a ] b \\\" ]\")]x";
    try std.testing.expectEqual(@as(?usize, 17), findBlockClose(text));
}

test "findBlockClose - vertical form returns null" {
    try std.testing.expectEqual(@as(?usize, null), findBlockClose(""));
    try std.testing.expectEqual(@as(?usize, null), findBlockClose("- comptime"));
    try std.testing.expectEqual(@as(?usize, null), findBlockClose("balanced [x] only"));
}

test "splitEntries - flat pipes with and without spaces" {
    const allocator = std.testing.allocator;
    const entries = try splitEntries(allocator, "comptime|transform | fuseable");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("comptime", entries[0]);
    try std.testing.expectEqualStrings("transform", entries[1]);
    try std.testing.expectEqualStrings("fuseable", entries[2]);
}

test "splitEntries - pipes inside nesting and strings stay put" {
    const allocator = std.testing.allocator;
    const entries = try splitEntries(allocator, "custom(a|b) | other[x|y] | doc(\"p|q\")");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("custom(a|b)", entries[0]);
    try std.testing.expectEqualStrings("other[x|y]", entries[1]);
    try std.testing.expectEqualStrings("doc(\"p|q\")", entries[2]);
}

test "splitEntries - expression-shaped entries survive whole" {
    const allocator = std.testing.allocator;
    const entries = try splitEntries(allocator, "build == \"release\" | version >= 15");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("build == \"release\"", entries[0]);
    try std.testing.expectEqualStrings("version >= 15", entries[1]);
}

test "splitEntries - empty entries dropped" {
    const allocator = std.testing.allocator;
    const entries = try splitEntries(allocator, " | a || b | ");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a", entries[0]);
    try std.testing.expectEqualStrings("b", entries[1]);
}

test "findInvalidSeparator - top-level comma is the real-world defect" {
    // The exact shape that shipped in koru_std/build.kz and silently dropped a
    // depends_on dependency.
    try std.testing.expectEqual(@as(?usize, 7), findInvalidSeparator("default, depends_on(compile_backend)"));
}

test "findInvalidSeparator - argument-list commas stay legal" {
    // depth 1: one entry's own argument list, which is correct syntax.
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("depends_on(a, b)"));
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("build(\"debug\", \"trace\")"));
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("other[x, y]"));
}

test "findInvalidSeparator - commas inside strings stay legal" {
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("doc(\"a, b\")"));
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("doc(\"esc \\\" , still inside\")"));
}

test "findInvalidSeparator - well-formed pipe blocks are clean" {
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("comptime|transform"));
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator("default|depends_on(compile_backend)"));
}

test "findInvalidSeparator - a comma after a closed call is still top level" {
    // Regression guard on the depth bookkeeping: the `(` ... `)` must return to
    // depth 0 so the following comma is caught rather than swallowed.
    try std.testing.expectEqual(@as(?usize, 16), findInvalidSeparator("depends_on(a, b), default"));
}

test "suggestPipeSeparators - the real-world defect gets its fix spelled out" {
    const allocator = std.testing.allocator;
    const fixed = try suggestPipeSeparators(allocator, "default, depends_on(compile_backend)");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("default|depends_on(compile_backend)", fixed);
}

test "suggestPipeSeparators - nested and quoted commas survive untouched" {
    const allocator = std.testing.allocator;
    const fixed = try suggestPipeSeparators(allocator, "build(\"a, b\"), other[x, y]");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("build(\"a, b\")|other[x, y]", fixed);
}

test "suggestPipeSeparators - already-correct content round-trips" {
    const allocator = std.testing.allocator;
    const fixed = try suggestPipeSeparators(allocator, "comptime|transform");
    defer allocator.free(fixed);
    try std.testing.expectEqualStrings("comptime|transform", fixed);
}

test "suggestPipeSeparators - the suggestion is what splitEntries then accepts" {
    // The two functions must never disagree: whatever the hint tells the author
    // to write has to split into the entries they were trying to express.
    const allocator = std.testing.allocator;
    const fixed = try suggestPipeSeparators(allocator, "default, depends_on(a, b)");
    defer allocator.free(fixed);
    const entries = try splitEntries(allocator, fixed);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("default", entries[0]);
    try std.testing.expectEqualStrings("depends_on(a, b)", entries[1]);
    try std.testing.expectEqual(@as(?usize, null), findInvalidSeparator(fixed));
}

test "parseCall - simple annotation returns null" {
    const allocator = std.testing.allocator;
    const result = try parseCall(allocator, "pure");
    try std.testing.expect(result == null);
}

test "parseCall - empty args" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "timeout()")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("timeout", result.name);
    try std.testing.expectEqual(@as(usize, 0), result.args.len);
}

test "parseCall - single quoted arg" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "depends_on(\"compile\")")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("compile", result.args[0]);
}

test "parseCall - multiple quoted args" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "depends_on(\"compile\", \"test\", \"lint\")")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 3), result.args.len);
    try std.testing.expectEqualStrings("compile", result.args[0]);
    try std.testing.expectEqualStrings("test", result.args[1]);
    try std.testing.expectEqualStrings("lint", result.args[2]);
}

test "parseCall - numeric arg" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "timeout(30)")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("timeout", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("30", result.args[0]);
}

test "parseCall - whitespace tolerance" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "  depends_on ( \"a\" , \"b\" )  ")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.args.len);
    try std.testing.expectEqualStrings("a", result.args[0]);
    try std.testing.expectEqualStrings("b", result.args[1]);
}

test "parseCall - escaped quotes" {
    const allocator = std.testing.allocator;
    var result = (try parseCall(allocator, "msg(\"Hello \\\"world\\\"\")")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("msg", result.name);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("Hello \"world\"", result.args[0]);
}

test "hasSimple - finds simple annotation" {
    const annotations = &[_][]const u8{ "pure", "comptime", "norun" };
    try std.testing.expect(hasSimple(annotations, "pure"));
    try std.testing.expect(hasSimple(annotations, "comptime"));
    try std.testing.expect(!hasSimple(annotations, "async"));
}

test "hasPart - finds parts in compound annotations" {
    const annotations = &[_][]const u8{ "comptime|transform", "runtime", "comptime|norun" };

    // Should find both parts of compound annotations
    try std.testing.expect(hasPart(annotations, "comptime"));
    try std.testing.expect(hasPart(annotations, "transform"));
    try std.testing.expect(hasPart(annotations, "norun"));

    // Should find simple annotations too
    try std.testing.expect(hasPart(annotations, "runtime"));

    // Should not find non-existent parts
    try std.testing.expect(!hasPart(annotations, "async"));
    try std.testing.expect(!hasPart(annotations, "pure"));
}

test "getCall - finds parametrized annotation" {
    const allocator = std.testing.allocator;
    const annotations = &[_][]const u8{ "pure", "depends_on(\"a\", \"b\")", "comptime" };

    var result = (try getCall(allocator, annotations, "depends_on")).?;
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("depends_on", result.name);
    try std.testing.expectEqual(@as(usize, 2), result.args.len);
    try std.testing.expectEqualStrings("a", result.args[0]);
    try std.testing.expectEqualStrings("b", result.args[1]);
}

test "getCall - returns null when not found" {
    const allocator = std.testing.allocator;
    const annotations = &[_][]const u8{ "pure", "comptime" };

    const result = try getCall(allocator, annotations, "depends_on");
    try std.testing.expect(result == null);
}
