const std = @import("std");

// Line-level lexical analysis helpers

pub const Line = struct {
    content: []const u8,
    indent: usize,
    line_num: usize,
};

/// Count leading spaces in a line
pub fn getIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// Trim leading and trailing whitespace
pub fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

/// Check if line starts with a string (after trimming)
pub fn startsWith(line: []const u8, prefix: []const u8) bool {
    const trimmed = trim(line);
    return std.mem.startsWith(u8, trimmed, prefix);
}

/// Check if this is a Koru line (starts with ~ or |)
pub fn isKoruLine(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len == 0) return false;
    return trimmed[0] == '~' or trimmed[0] == '|';
}

/// Check if this is a continuation line (starts with `|` terminal or `!` effect)
pub fn isContinuationLine(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '|') return true;
    // `!` continuation: `! name`, `! ?name`, or `!?` (catch-all). Reject `!=`
    // and other operators by requiring whitespace or `?` after the `!`.
    if (trimmed[0] == '!' and trimmed.len >= 2) {
        const next = trimmed[1];
        return next == ' ' or next == '\t' or next == '?';
    }
    return false;
}

/// Check if this is a comment-only line (starts with //)
pub fn isCommentLine(line: []const u8) bool {
    const trimmed = trim(line);
    if (trimmed.len < 2) return false;
    return trimmed[0] == '/' and trimmed[1] == '/';
}

/// Check if a string is a valid identifier (starts with letter/underscore, contains only alphanumeric/underscore)
pub fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    
    // Must start with letter or underscore
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    
    // Rest must be alphanumeric, underscore, or kebab `-` (a legal name-char;
    // it mangles to `_` on emit). First char stays letter/`_` — names don't
    // start with `-`.
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    
    return true;
}

/// Extract content after a prefix
pub fn afterPrefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    const trimmed = trim(line);
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const rest = trimmed[prefix.len..];
        return trim(rest);
    }
    return null;
}

/// Parse a dotted path (e.g., "file.read")
/// DEPRECATED: Use parseQualifiedPath for new code
/// In-place kebab `-` -> `_`, INFIX only (between two name characters). Mirrors
/// src/ast_mangle.zig: an operator/spaced/edge `-` is not word-glue and is left
/// alone (e.g. a tap's `* -> *` pattern stored as a segment must not become `_>`).
pub fn mangleKebabInPlace(s: []u8) void {
    for (s, 0..) |*c, i| {
        if (c.* != '-') continue;
        if (i == 0 or i + 1 >= s.len) continue;
        const prev = s[i - 1];
        const next = s[i + 1];
        const prev_ok = std.ascii.isAlphanumeric(prev) or prev == '_';
        const next_ok = std.ascii.isAlphanumeric(next) or next == '_';
        if (prev_ok and next_ok) c.* = '_';
    }
}

pub fn parseDottedPath(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var segments = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (segments.items) |seg| allocator.free(seg);
        segments.deinit(allocator);
    }

    var iter = std.mem.tokenizeScalar(u8, path, '.');
    while (iter.next()) |segment| {
        const owned = try allocator.dupe(u8, segment);
        // KEBAB-CANONICAL: segments stay byte-for-byte as written (kebab is the
        // canonical internal form). Registry keys derive from these verbatim
        // segments; registration and lookup stay consistent because BOTH sides
        // come through here. Snake is an EMITTER concern (identifier formation).
        try segments.append(allocator, owned);
    }

    return segments.toOwnedSlice(allocator);
}

/// Parse a qualified path with optional module qualifier (e.g., "http:request.complete" or "local.event")
/// Brackets [], (), <> are respected - colons inside brackets are NOT module qualifiers.
pub fn parseQualifiedPath(allocator: std.mem.Allocator, path: []const u8, ast: anytype) !ast.DottedPath {
    // Find module qualifier colon at bracket depth 0
    // Colons inside brackets (like [T:u32]) are NOT module qualifiers
    const colon_idx = findModuleQualifierColon(path);

    if (colon_idx) |idx| {
        // Has module qualifier
        const qualifier = path[0..idx];
        const namespace_part = path[idx + 1..];

        const segments = try parseDottedPath(allocator, namespace_part);

        const owned_qualifier = try allocator.dupe(u8, qualifier);
        // Namespace separator: `/` is the source form (matches the import string
        // and filesystem), but the registry / canonical names use `.` internally
        // (namespaces are built as `parent.file`). Normalize the qualifier `/`->`.`
        // so a slash call site `std/deps:requires.system` resolves to the same
        // event as the dot form. Member access AFTER the `:` (segments) keeps `.`.
        for (owned_qualifier) |*c| {
            if (c.* == '/') c.* = '.';
        }
        return ast.DottedPath{
            .module_qualifier = owned_qualifier,
            .segments = segments,
        };
    } else {
        // No module qualifier
        const segments = try parseDottedPath(allocator, path);

        return ast.DottedPath{
            .module_qualifier = null,
            .segments = segments,
        };
    }
}

/// Find the position of a top-level variant pipe (`|`) at bracket depth 0.
/// Used to split `event_name|variant` paths into the canonical name and variant tag.
/// Returns null if no top-level pipe found (or if it would conflict with `|>` chain ops,
/// though `|>` is not legal in a subflow declaration's event-path position).
pub fn findTopLevelVariantPipe(path: []const u8) ?usize {
    var bracket_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var angle_depth: i32 = 0;

    for (path, 0..) |c, i| {
        switch (c) {
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '<' => angle_depth += 1,
            '>' => angle_depth -= 1,
            '|' => {
                if (bracket_depth == 0 and paren_depth == 0 and angle_depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Find the position of a module qualifier colon (at bracket depth 0)
/// Returns null if no qualifying colon found
pub fn findModuleQualifierColon(path: []const u8) ?usize {
    var bracket_depth: i32 = 0;  // []
    var paren_depth: i32 = 0;    // ()
    var angle_depth: i32 = 0;    // <>

    for (path, 0..) |c, i| {
        switch (c) {
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '<' => angle_depth += 1,
            '>' => angle_depth -= 1,
            ':' => {
                // Only a module qualifier if at depth 0 for all bracket types
                if (bracket_depth == 0 and paren_depth == 0 and angle_depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Extract balanced braces content
pub fn extractBraces(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, "{") orelse return null;
    const end = std.mem.lastIndexOf(u8, line, "}") orelse return null;
    if (end <= start) return null;
    return line[start..end + 1];
}

/// Extract content between braces (not including braces)
pub fn extractBracesContent(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, "{") orelse return null;
    const end = std.mem.lastIndexOf(u8, line, "}") orelse return null;
    if (end <= start) return null;
    if (end == start + 1) return ""; // Empty braces
    return trim(line[start + 1..end]);
}

/// Parse arguments in the form (arg1:val1, arg2:val2)
pub const ArgPair = struct {
    name: []const u8,
    value: []const u8,
    /// True when the user wrote an explicit `name: value` colon at the call site.
    /// False when the argument was punned (`v` shorthand for `v: v`, or
    /// `p.x` shorthand for `x: p.x`). Used by the parser to reject redundant
    /// explicit labels — if punning would yield the same name, the explicit
    /// form is forbidden.
    had_explicit_label: bool = false,
    /// Author-asserted phantom label captured from a `<label>` suffix on a
    /// literal or parenthesized expression. Null when no suffix was present.
    /// The suffix has been stripped from `value`.
    phantom_type: ?[]const u8 = null,
};

/// Find the end of a brace-delimited block, handling nested braces
pub fn findMatchingBrace(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '{') return null;
    
    var depth: usize = 1;
    var i = start + 1;
    var in_string = false;
    var string_char: ?u8 = null;
    
    while (i < text.len and depth > 0) {
        const char = text[i];
        
        // Handle string literals - braces inside strings don't count
        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\' and i + 1 < text.len) {
                i += 1; // Skip escaped character
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
        } else {
            // Not in a string - count braces
            if (char == '{') {
                depth += 1;
            } else if (char == '}') {
                depth -= 1;
            }
        }
        
        i += 1;
    }
    
    if (depth == 0) {
        return i - 1; // Return index of closing brace
    }
    return null; // Unmatched braces
}

/// Index at which a line comment begins, or null. `//` inside a string literal
/// is string content, not a comment.
///
/// Use this instead of naive `std.mem.indexOf(u8, text, "//")` anywhere the text
/// can carry a string literal. The canonical casualty is an invocation argument
/// holding a URL — `take(n, s: "https://example.com")` truncates at the scheme
/// separator, and what the author sees is a complaint about unbalanced
/// parentheses in a line whose parentheses are balanced.
pub fn commentStart(text: []const u8) ?usize {
    var in_string = false;
    var string_char: ?u8 = null;
    var i: usize = 0;

    while (i < text.len) : (i += 1) {
        const char = text[i];

        if (!in_string and char == '/' and i + 1 < text.len and text[i + 1] == '/') {
            return i;
        }

        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\' and i + 1 < text.len) {
                i += 1; // escaped character — never closes the literal
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
        }
    }

    return null;
}

/// Count the net brace depth change in a string, skipping braces inside strings and comments.
/// Returns positive for net opens, negative for net closes.
/// Use this instead of naive `for (line) |c| if (c == '{') depth += 1` patterns.
pub fn countBraceDepthChange(text: []const u8) i32 {
    var depth: i32 = 0;
    var in_string = false;
    var string_char: ?u8 = null;
    var i: usize = 0;

    while (i < text.len) {
        const char = text[i];

        // Skip line comments - rest of line doesn't count
        if (!in_string and char == '/' and i + 1 < text.len and text[i + 1] == '/') {
            break;
        }

        // Handle string literals - braces inside strings don't count
        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\' and i + 1 < text.len) {
                i += 1; // Skip escaped character
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
        } else {
            // Not in a string or comment - count braces
            if (char == '{') {
                depth += 1;
            } else if (char == '}') {
                depth -= 1;
            }
        }

        i += 1;
    }

    return depth;
}

/// Find the index of a character, but only when at depth 0 (not inside braces, parens, or brackets)
/// Used for finding argument separators like ':' that shouldn't match inside nested structures
pub fn indexOfAtDepthZero(text: []const u8, needle: u8) ?usize {
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;

    // A `while` with an explicit cursor, NOT `for (text, 0..)`: inside a string
    // a backslash escapes the NEXT byte, and skipping it means advancing the
    // cursor by two. A `for` loop's `continue` cannot do that — it steps by one
    // — so `\"` closed the string and every following `:` read as an argument
    // label separator. With an ODD number of escaped quotes ahead of it, a
    // colon inside a string literal became a label: `print.ln("\",\"n\":{{ x:d }}")`
    // split into name `"\",\"n\"` and value `{{ x:d }}"`. The comma splitter in
    // parseArgs already advances by two for exactly this reason (210_196).
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const char = text[i];

        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
            continue;
        }
        if (in_string) {
            if (char == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (char == string_char) {
                in_string = false;
                string_char = null;
            }
            continue;
        }

        // Track nesting depth
        switch (char) {
            '{' => brace_depth += 1,
            '}' => brace_depth -|= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -|= 1,
            else => {},
        }

        // Check for needle at depth 0
        if (char == needle and brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
            return i;
        }
    }
    return null;
}

const PhantomSuffix = struct { value: []const u8, phantom: ?[]const u8 };

/// Extract a trailing `<label>` phantom suffix from an arg-value string.
///
/// Recognised only when the preceding token is a literal or parenthesized
/// expression (`22.5<celsius>`, `"alice"<username>`, `(box.v)<celsius>`).
/// Path/binding suffixes are intentionally not supported here — bindings
/// will carry phantom state natively once the binding-phantom-tracking
/// project lands. Until then, users wrap non-literal values in parens.
///
/// Returns the stripped value + label, or the original value + null if no
/// valid suffix was found.
pub fn extractPhantomSuffix(value_str: []const u8) PhantomSuffix {
    const trimmed = trim(value_str);
    if (trimmed.len < 3 or trimmed[trimmed.len - 1] != '>') {
        return .{ .value = trimmed, .phantom = null };
    }

    // Walk back over label-name chars until we hit `<` or non-label-char.
    var i: usize = trimmed.len - 1; // points at `>`
    while (i > 0) {
        const c = trimmed[i - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            i -= 1;
        } else {
            break;
        }
    }
    // `i` now indexes the first label-name char (or 0). The char before must be `<`.
    if (i == 0 or trimmed[i - 1] != '<') return .{ .value = trimmed, .phantom = null };

    const label = trimmed[i .. trimmed.len - 1];
    if (label.len == 0) return .{ .value = trimmed, .phantom = null };
    // First char must be a valid label-start (letter or underscore — digits not allowed).
    if (!(std.ascii.isAlphabetic(label[0]) or label[0] == '_')) {
        return .{ .value = trimmed, .phantom = null };
    }

    const before = trim(trimmed[0 .. i - 1]); // strip the `<` too
    if (!isLabelAttachableToken(before)) return .{ .value = trimmed, .phantom = null };

    return .{ .value = before, .phantom = label };
}

/// True when `s` is a token that can carry a phantom-label suffix:
/// numeric literal, string literal, or parenthesized expression.
fn isLabelAttachableToken(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return true;
    if (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')') return true;
    return isNumericLiteral(s);
}

/// Decimal numeric literal: optional sign, digits + underscores, optional
/// decimal part, optional scientific exponent. No hex, no leading dot, no
/// char literals for first cut.
fn isNumericLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') i = 1;
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    i += 1;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) : (i += 1) {}
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '_')) : (i += 1) {}
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    }
    return i == s.len;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// String-aware lookahead: does the '<' at `open_idx` have a matching '>'
/// before the end of the argument content? Distinguishes a generic/phantom
/// group (`Option<A, B>`, `32<celsius>`) from a comparison (`x < 5`).
fn hasMatchingAngleClose(content: []const u8, open_idx: usize) bool {
    var depth: usize = 1;
    var i = open_idx + 1;
    var in_string = false;
    var string_char: u8 = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == string_char) {
                in_string = false;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = true;
            string_char = c;
        } else if (c == '<') {
            depth += 1;
        } else if (c == '>') {
            depth -= 1;
            if (depth == 0) return true;
        }
    }
    return false;
}

pub fn parseArgs(allocator: std.mem.Allocator, args_str: []const u8) ![]ArgPair {
    var args = try std.ArrayList(ArgPair).initCapacity(allocator, 4);
    errdefer {
        for (args.items) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.value);
        }
        args.deinit(allocator);
    }

    // Remove parentheses if present
    const content = if (std.mem.startsWith(u8, args_str, "(") and std.mem.endsWith(u8, args_str, ")"))
        args_str[1..args_str.len - 1]
    else
        args_str;

    // Parse arguments with proper string handling
    var i: usize = 0;
    var arg_start: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;
    var in_braces = false;
    var paren_depth: usize = 0;  // Track nested parentheses for Expression params
    var bracket_depth: usize = 0;  // Track nested brackets for array literals [1, 2, 3]
    var angle_depth: usize = 0;  // Track nested angle brackets for generics Option<T, U>

    while (i <= content.len) {
        const at_end = i == content.len;
        const char = if (!at_end) content[i] else ',';

        // Track string boundaries. Inside a string, a backslash escapes the
        // next char: `\"` is DATA, not a closing quote — without the skip, an
        // escaped quote flipped in_string off and every comma in the quoted
        // text split the argument list (210_196, found by kopium's request
        // body carrying prose with commas).
        if (in_string and char == '\\' and !at_end) {
            i += 2;
            continue;
        }
        if (!in_string and !in_braces and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string and char == string_char) {
            in_string = false;
            string_char = null;
        }

        // Track parenthesis depth for Expression params (e.g., func(x, y) shouldn't split at inner comma).
        // A ')' with no matching '(' is unbalanced: reject it instead of clamping
        // to zero (which would swallow the imbalance, mis-split the args, and leak
        // the orphaned delimiter into the emitted host code). '(' and ')' are not
        // overloaded in argument position, so the imbalance is unambiguous.
        if (!in_string and !in_braces) {
            if (char == '(') {
                paren_depth += 1;
            } else if (char == ')') {
                if (paren_depth == 0) return error.UnbalancedArgs;
                paren_depth -= 1;
            }
        }

        // Track bracket depth for array literals (e.g., [1, 2, 3] shouldn't split at inner comma).
        // A ']' with no matching '[' is unbalanced — same reasoning as parens.
        if (!in_string and !in_braces) {
            if (char == '[') {
                bracket_depth += 1;
            } else if (char == ']') {
                if (bracket_depth == 0) return error.UnbalancedArgs;
                bracket_depth -= 1;
            }
        }

        // Track angle bracket depth for generics (e.g., Option<A, B> shouldn't split at inner comma).
        // BOTH '<' and '>' are overloaded as comparison operators in Expression
        // args (`x < 5`, `d.value > 10`), so neither side may be treated as
        // unconditionally structural:
        // - '<' opens a group only when it hugs an identifier on the left
        //   (`Option<`, `32<celsius>`) AND a matching '>' exists ahead. An
        //   unmatched or spaced '<' is a comparison and stays a plain char —
        //   otherwise `if(x < 5)` leaves angle_depth stuck >0 and the
        //   comma-split never fires, silently dropping the entire argument
        //   (pinned by 210_124).
        // - '>' is CLAMPED, not rejected: a lone '>' is a legal comparison.
        if (!in_string and !in_braces) {
            if (char == '<' and i > 0 and isIdentChar(content[i - 1]) and hasMatchingAngleClose(content, i)) {
                angle_depth += 1;
            } else if (char == '>' and angle_depth > 0) {
                angle_depth -= 1;
            }
        }

        // Track brace boundaries for Source blocks
        if (!in_string and !in_braces and char == '{') {
            // Find the matching closing brace
            if (findMatchingBrace(content, i)) |closing_idx| {
                // Skip to the closing brace
                i = closing_idx;
                in_braces = false;
            } else {
                // Unmatched brace - treat as regular character
                in_braces = true;
            }
        } else if (in_braces and char == '}') {
            in_braces = false;
        }

        // Split on commas that aren't inside strings, braces, brackets, angles, or nested parens
        if ((char == ',' or at_end) and !in_string and !in_braces and paren_depth == 0 and bracket_depth == 0 and angle_depth == 0) {
            const arg_slice = trim(content[arg_start..i]);
            if (arg_slice.len > 0) {
                // Use depth-aware colon search to handle { field: value } expressions
                const colon_idx = indexOfAtDepthZero(arg_slice, ':');

                if (colon_idx != null) {
                    const idx = colon_idx.?;
                    // Explicit form: name: value
                    const name = try allocator.dupe(u8, trim(arg_slice[0..idx]));
                    const value_str = trim(arg_slice[idx + 1..]);

                    // Check if the value is a brace block (for Source)
                    if (std.mem.startsWith(u8, value_str, "{") and std.mem.endsWith(u8, value_str, "}")) {
                        // Include the braces in the value for now
                        // The parser will handle extracting the content
                    }

                    const suffix = extractPhantomSuffix(value_str);
                    const value = try allocator.dupe(u8, suffix.value);
                    const phantom = if (suffix.phantom) |p| try allocator.dupe(u8, p) else null;
                    try args.append(allocator, .{ .name = name, .value = value, .had_explicit_label = true, .phantom_type = phantom });
                } else {
                    // Shorthand form: extract field name from dotted expression
                    // e.g., r.data.source -> name: "source", value: "r.data.source"
                    // BUT: Don't use shorthand for:
                    // - Range expressions like "0..p.n" (contains "..")
                    // - Expressions with operators like "r.value > 10" (contains space/operators)
                    const has_range_op = std.mem.indexOf(u8, arg_slice, "..") != null;

                    // Check if this looks like a complex expression (not just field access).
                    // A shorthand field-name extraction is only valid for a PURE dotted-
                    // identifier path (e.g. `r.data.source` -> `source`). Any operator or
                    // space ANYWHERE in the arg makes it complex — including operators
                    // BEFORE the last dot. The previous check only scanned the text after
                    // the last dot, so `d == a.prev` (operators before the dot, plain
                    // `prev` after) was misread as simple field access and the name
                    // became `prev`, dropping the arg for any single-field event (e.g.
                    // `~if`'s `cond`), emitting `if ()`. Scan the whole slice instead.
                    // (Phantom suffixes `<...>` only attach to numeric/string/paren
                    // tokens, which are dotless, so they never reach this dot branch.)
                    const is_complex_expr = blk: {
                        if (has_range_op) break :blk true;
                        for (arg_slice) |c| {
                            if (c == ' ' or c == '>' or c == '<' or c == '=' or
                                c == '+' or c == '-' or c == '*' or c == '/' or
                                c == '!' or c == '&' or c == '|' or c == '(' or c == ')') {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    };

                    const name = if (!is_complex_expr) blk: {
                        if (std.mem.lastIndexOf(u8, arg_slice, ".")) |last_dot| {
                            break :blk try allocator.dupe(u8, arg_slice[last_dot + 1..]);
                        } else {
                            break :blk try allocator.dupe(u8, arg_slice);
                        }
                    } else try allocator.dupe(u8, arg_slice);
                    const suffix = extractPhantomSuffix(arg_slice);
                    const value = try allocator.dupe(u8, suffix.value);
                    const phantom = if (suffix.phantom) |p| try allocator.dupe(u8, p) else null;
                    try args.append(allocator, .{ .name = name, .value = value, .phantom_type = phantom });
                }
            }
            arg_start = i + 1;
        }
        
        i += 1;
    }

    return args.toOwnedSlice(allocator);
}

/// True when the value, if punned, would produce the same name — meaning the
/// explicit `name: value` label is redundant. Only fires when an explicit
/// label was actually written (no false positives on already-punned args).
///
/// A value is "punnable" when it's a bare identifier path: dot-separated
/// identifiers with no operators, parens, brackets, quotes, spaces, or `..`.
/// The punned name is the segment after the last `.`, or the whole string if
/// there's no dot. `v: v` → punned name `v` matches → redundant. `v: p.x` →
/// punned name `x` ≠ `v` → not redundant. `v: 5` → not punnable → not
/// redundant (must keep the label).
/// The parameter name a value would pun to — the segment after the last `.`,
/// or the whole token when there's no dot — or `null` when the value CANNOT
/// pun. A value is punnable only when it's a pure dotted-identifier path: no
/// operators, parens, brackets, quotes, spaces, `..`, leading/trailing dot, or
/// leading digit. Literals (`5`, `"s"`) and expressions (`1 + 2`) return null.
/// This is the single punnability predicate — both PARSE005 (redundant label)
/// and PARSE006 (bare arg names no parameter) resolve punning through it.
pub fn punnableName(value: []const u8) ?[]const u8 {
    if (value.len == 0) return null;
    for (value) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.' => {},
            else => return null,
        }
    }
    // `..` (range op) — `0..n` would slip past the per-char check.
    if (std.mem.indexOf(u8, value, "..") != null) return null;
    // Leading/trailing dot (`.foo` is a Zig enum literal; `foo.` is malformed).
    if (value[0] == '.' or value[value.len - 1] == '.') return null;
    // Leading digit (numeric literals like `0x10`, `42`).
    if (value[0] >= '0' and value[0] <= '9') return null;

    return if (std.mem.lastIndexOfScalar(u8, value, '.')) |dot_idx|
        value[dot_idx + 1 ..]
    else
        value;
}

pub fn isRedundantExplicitLabel(arg: ArgPair) bool {
    if (!arg.had_explicit_label) return false;
    const punned_name = punnableName(arg.value) orelse return false;
    return std.mem.eql(u8, punned_name, arg.name);
}

/// Check if a line is a pipeline continuation (starts with |>)
pub fn isPipelineContinuation(line: []const u8) bool {
    const trimmed = trim(line);
    return std.mem.startsWith(u8, trimmed, "|>");
}

/// Check if a line is a branch continuation (starts with | but not |>)
pub fn isBranchContinuation(line: []const u8) bool {
    const trimmed = trim(line);
    if (std.mem.startsWith(u8, trimmed, "|") and !std.mem.startsWith(u8, trimmed, "|>")) return true;
    // Yielding branches: `! name ...` or `! ?name ...`. The next char must be
    // whitespace or `?` so we don't swallow Zig operators like `!=` that might
    // appear in non-Koru contexts.
    if (std.mem.startsWith(u8, trimmed, "!") and trimmed.len >= 2) {
        const next = trimmed[1];
        if (next == ' ' or next == '\t' or next == '?') return true;
    }
    return false;
}

/// Extract label from line (e.g., "@loop" from "... @loop")
pub fn extractLabel(line: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOf(u8, line, "@") orelse return null;
    const label = trim(line[idx + 1..]);
    if (label.len == 0) return null;
    
    // Make sure it's a valid identifier
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            return null;
        }
    }
    
    return label;
}

/// Remove label from line if present
pub fn withoutLabel(line: []const u8) []const u8 {
    // Find @ that's at depth 0 (not inside parens/braces) and preceded by space
    // This avoids matching @as, @field, etc. which are Zig builtins
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;
    var last_at_depth_zero: ?usize = null;

    for (line, 0..) |char, i| {
        if (!in_string and (char == '"' or char == '\'')) {
            in_string = true;
            string_char = char;
        } else if (in_string) {
            if (char == '\\') {
                continue; // Skip escape sequence
            } else if (char == string_char) {
                in_string = false;
                string_char = null;
            }
            continue;
        }

        switch (char) {
            '{' => brace_depth += 1,
            '}' => brace_depth -|= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -|= 1,
            else => {},
        }

        // Only consider @ at depth 0 that's preceded by space (label syntax)
        // This avoids matching @as, @field, @import, etc.
        if (char == '@' and brace_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
            if (i > 0 and line[i - 1] == ' ') {
                last_at_depth_zero = i;
            }
        }
    }

    if (last_at_depth_zero) |idx| {
        return trim(line[0..idx]);
    }
    return line;
}

/// Parse positional arguments for subflow invocations
pub fn parsePositionalArgs(allocator: std.mem.Allocator, args_str: []const u8) ![][]const u8 {
    var args = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer {
        for (args.items) |arg| {
            allocator.free(arg);
        }
        args.deinit(allocator);
    }
    
    // Remove parentheses if present
    var content = args_str;
    if (startsWith(content, "(") and std.mem.endsWith(u8, content, ")")) {
        content = content[1..content.len - 1];
    }
    
    // Split by comma
    var iter = std.mem.tokenizeScalar(u8, content, ',');
    while (iter.next()) |arg| {
        const trimmed = trim(arg);
        // Keep the value as-is, including quotes if present
        // This preserves the distinction between string literals and identifiers
        try args.append(allocator, try allocator.dupe(u8, trimmed));
    }
    
    return args.toOwnedSlice(allocator);
}

// Tests
test "getIndent" {
    try std.testing.expectEqual(@as(usize, 0), getIndent("no indent"));
    try std.testing.expectEqual(@as(usize, 2), getIndent("  two spaces"));
    try std.testing.expectEqual(@as(usize, 4), getIndent("    four spaces"));
}

test "parseDottedPath" {
    const allocator = std.testing.allocator;
    const segments = try parseDottedPath(allocator, "file.read.async");
    defer {
        for (segments) |seg| allocator.free(seg);
        allocator.free(segments);
    }
    
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("file", segments[0]);
    try std.testing.expectEqualStrings("read", segments[1]);
    try std.testing.expectEqualStrings("async", segments[2]);
}

test "extractBracesContent" {
    try std.testing.expectEqualStrings("path: []const u8", extractBracesContent("{ path: []const u8 }").?);
    try std.testing.expectEqualStrings("", extractBracesContent("{}").?);
    try std.testing.expect(extractBracesContent("no braces") == null);
}


test "parseArgs" {
    const allocator = std.testing.allocator;
    const args = try parseArgs(allocator, "(path:\"file.txt\", mode:read)");
    defer {
        for (args) |arg| {
            allocator.free(arg.name);
            allocator.free(arg.value);
        }
        allocator.free(args);
    }
    
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("path", args[0].name);
    try std.testing.expectEqualStrings("\"file.txt\"", args[0].value);
    try std.testing.expectEqualStrings("mode", args[1].name);
    try std.testing.expectEqualStrings("read", args[1].value);
}
