//! Lightweight Flow Parser for Interpreter Eval
//!
//! Parses a single Koru flow (invocation + continuations) into ast.Flow
//! without the overhead of the full compiler parser. No type registry,
//! module resolver, or expression parser — just lexer-level parsing.
//!
//! The interpreter's evalFlow() consumes the same AST types directly.

const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");
const errors = @import("errors");
const expression_parser = @import("expression_parser");

// ============================================================================
// Public API
// ============================================================================

pub const ParseErrorInfo = struct {
    message: []const u8,
    line: usize,
    column: usize,
};

pub const FlowParseResult = union(enum) {
    flow: ast.Flow,
    err: ParseErrorInfo,
};

/// Parse a single Koru flow from source text.
/// The `~` prefix is optional — stripped if present, accepted if absent.
/// Returns either a Flow AST node or an error with location info.
pub fn parseFlow(allocator: std.mem.Allocator, source: []const u8) FlowParseResult {
    return parseFlowInternal(allocator, source) catch |err| {
        return .{ .err = .{
            .message = @errorName(err),
            .line = 0,
            .column = 0,
        } };
    };
}

// ============================================================================
// Internal implementation
// ============================================================================

const ParseError = error{
    EmptyInput,
    InvalidInvocation,
    MalformedArgs,
    MalformedContinuation,
    MalformedBranchConstructor,
    MalformedNode,
    UnbalancedParens,
    UnbalancedBraces,
    OutOfMemory,
};

fn parseFlowInternal(allocator: std.mem.Allocator, source: []const u8) ParseError!FlowParseResult {
    const trimmed_source = lexer.trim(source);
    if (trimmed_source.len == 0) {
        return .{ .err = .{
            .message = "Empty input",
            .line = 0,
            .column = 0,
        } };
    }

    // Split source into lines
    const lines = try splitLines(allocator, source);

    // Skip leading blank/comment lines to find the invocation line
    var invocation_line_idx: usize = 0;
    while (invocation_line_idx < lines.len) {
        const line_content = lexer.trim(lines[invocation_line_idx].content);
        if (line_content.len > 0 and !lexer.isCommentLine(lines[invocation_line_idx].content)) {
            break;
        }
        invocation_line_idx += 1;
    }

    if (invocation_line_idx >= lines.len) {
        return .{ .err = .{
            .message = "No invocation found",
            .line = 0,
            .column = 0,
        } };
    }

    // Require ~ prefix — reject non-flow source (event decls, multi-statement, etc.)
    const first_line = lexer.trim(lines[invocation_line_idx].content);
    if (first_line.len == 0 or first_line[0] != '~') {
        return .{ .err = .{
            .message = "Not a flow (missing ~ prefix)",
            .line = lines[invocation_line_idx].line_num,
            .column = 0,
        } };
    }

    // Collect invocation line(s) — handle multi-line args (unbalanced parens)
    const invocation_text = try collectMultiLineConstruct(allocator, lines, invocation_line_idx, '(', ')');

    // Parse the invocation
    const invocation = parseInvocationLine(allocator, invocation_text.text, invocation_text.start_line) catch {
        return .{ .err = .{
            .message = "Invalid invocation syntax",
            .line = lines[invocation_line_idx].line_num,
            .column = 0,
        } };
    };

    // Parse continuations starting after the invocation line(s)
    const cont_start = invocation_text.end_idx + 1;
    const continuations = if (cont_start < lines.len)
        try parseContinuations(allocator, lines, cont_start, 0)
    else
        try allocator.alloc(ast.Continuation, 0);

    return .{ .flow = .{
        .invocation = invocation,
        .continuations = continuations,
        .module = try allocator.dupe(u8, "eval"),
    } };
}

// ============================================================================
// Line splitting and multi-line collection
// ============================================================================

const LineInfo = struct {
    content: []const u8,
    indent: usize,
    line_num: usize,
};

fn splitLines(allocator: std.mem.Allocator, source: []const u8) ParseError![]LineInfo {
    var lines = try std.ArrayList(LineInfo).initCapacity(allocator, 8);

    var line_start: usize = 0;
    var line_num: usize = 1;

    for (source, 0..) |c, i| {
        if (c == '\n') {
            const line_content = source[line_start..i];
            try lines.append(allocator, .{
                .content = line_content,
                .indent = lexer.getIndent(line_content),
                .line_num = line_num,
            });
            line_start = i + 1;
            line_num += 1;
        }
    }

    // Last line (if no trailing newline)
    if (line_start <= source.len) {
        const line_content = source[line_start..];
        if (line_content.len > 0) {
            try lines.append(allocator, .{
                .content = line_content,
                .indent = lexer.getIndent(line_content),
                .line_num = line_num,
            });
        }
    }

    return lines.toOwnedSlice(allocator);
}

const CollectedText = struct {
    text: []const u8,
    start_line: usize,
    end_idx: usize, // index in lines array of last consumed line
};

/// Collect lines for a construct that may span multiple lines due to unbalanced delimiters.
fn collectMultiLineConstruct(
    allocator: std.mem.Allocator,
    lines: []const LineInfo,
    start_idx: usize,
    open_delim: u8,
    close_delim: u8,
) ParseError!CollectedText {
    var depth: i32 = 0;
    var end_idx = start_idx;

    // Count delimiter balance across lines
    var i = start_idx;
    while (i < lines.len) {
        for (lines[i].content) |c| {
            if (c == open_delim) depth += 1;
            if (c == close_delim) depth -= 1;
        }
        end_idx = i;
        if (depth <= 0) break;
        i += 1;
    }

    // If only one line, return it directly (no allocation needed for joining)
    if (end_idx == start_idx) {
        return .{
            .text = lines[start_idx].content,
            .start_line = lines[start_idx].line_num,
            .end_idx = end_idx,
        };
    }

    // Join multiple lines with spaces
    var total_len: usize = 0;
    for (lines[start_idx .. end_idx + 1]) |line| {
        if (total_len > 0) total_len += 1; // space separator
        total_len += lexer.trim(line.content).len;
    }

    var buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (lines[start_idx .. end_idx + 1]) |line| {
        if (pos > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        const trimmed = lexer.trim(line.content);
        @memcpy(buf[pos..][0..trimmed.len], trimmed);
        pos += trimmed.len;
    }

    return .{
        .text = buf,
        .start_line = lines[start_idx].line_num,
        .end_idx = end_idx,
    };
}

// ============================================================================
// Invocation parsing
// ============================================================================

fn parseInvocationLine(allocator: std.mem.Allocator, line: []const u8, line_num: usize) ParseError!ast.Invocation {
    _ = line_num;
    var content = lexer.trim(line);

    // Strip optional ~ prefix
    if (content.len > 0 and content[0] == '~') {
        content = lexer.trim(content[1..]);
    }

    // Find args start (first paren at depth 0)
    const paren_idx = findTopLevelParen(content);

    if (paren_idx) |idx| {
        // Has args: path(args)
        const path_str = lexer.trim(content[0..idx]);
        const args_str = content[idx..]; // includes parens

        const path = lexer.parseQualifiedPath(allocator, path_str, ast) catch return ParseError.InvalidInvocation;
        const arg_pairs = lexer.parseArgs(allocator, args_str) catch return ParseError.MalformedArgs;

        // Convert ArgPair[] to Arg[]
        const args = try convertArgPairs(allocator, arg_pairs);

        return .{
            .path = path,
            .args = args,
        };
    } else {
        // No args: just path — reject if it contains spaces (e.g. "event broken")
        if (std.mem.indexOf(u8, content, " ") != null or std.mem.indexOf(u8, content, "\t") != null) {
            return ParseError.InvalidInvocation;
        }
        const path = lexer.parseQualifiedPath(allocator, content, ast) catch return ParseError.InvalidInvocation;
        return .{
            .path = path,
            .args = try allocator.alloc(ast.Arg, 0),
        };
    }
}

fn findTopLevelParen(text: []const u8) ?usize {
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;

    for (text, 0..) |c, i| {
        if (!in_string and (c == '"' or c == '\'')) {
            in_string = true;
            string_char = c;
        } else if (in_string) {
            if (c == '\\') continue; // skip escape (next char handled by loop)
            if (c == string_char) {
                in_string = false;
                string_char = null;
            }
            continue;
        }

        switch (c) {
            '{' => brace_depth += 1,
            '}' => brace_depth -|= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -|= 1,
            '(' => {
                if (brace_depth == 0 and bracket_depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn convertArgPairs(allocator: std.mem.Allocator, pairs: []const lexer.ArgPair) ParseError![]const ast.Arg {
    var args = try std.ArrayList(ast.Arg).initCapacity(allocator, pairs.len);
    for (pairs) |pair| {
        var arg = ast.Arg{
            .name = try allocator.dupe(u8, pair.name),
            .value = try allocator.dupe(u8, pair.value),
        };
        tryParseArgExpr(allocator, &arg);
        try args.append(allocator, arg);
    }
    return args.toOwnedSlice(allocator);
}

/// Attempt to parse an arg's value as an expression. Unparseable values silently remain null.
fn tryParseArgExpr(allocator: std.mem.Allocator, arg: *ast.Arg) void {
    const trimmed = std.mem.trim(u8, arg.value, " \t");
    if (trimmed.len == 0 or trimmed[0] == '{') return;

    var expr_p = expression_parser.ExpressionParser.init(allocator, arg.value);
    defer expr_p.deinit();

    if (expr_p.parse()) |expr| {
        const remaining = std.mem.trim(u8, expr_p.input[expr_p.pos..], " \t");
        if (remaining.len == 0) {
            arg.parsed_expression = expr;
        } else {
            var mutable_expr = @constCast(expr);
            mutable_expr.deinit(allocator);
        }
    } else |_| {}
}

// ============================================================================
// Continuation parsing
// ============================================================================

fn parseContinuations(
    allocator: std.mem.Allocator,
    lines: []const LineInfo,
    start_idx: usize,
    base_indent: usize,
) ParseError![]const ast.Continuation {
    var continuations = try std.ArrayList(ast.Continuation).initCapacity(allocator, 4);
    var i = start_idx;

    while (i < lines.len) {
        const line = lines[i];
        const trimmed = lexer.trim(line.content);

        // Skip blank and comment lines
        if (trimmed.len == 0 or lexer.isCommentLine(line.content)) {
            i += 1;
            continue;
        }

        // Must be a continuation line (starts with | or |>)
        if (!lexer.isContinuationLine(line.content)) {
            // If indented beyond base, it might be continuation content — skip
            if (line.indent > base_indent) {
                i += 1;
                continue;
            }
            break; // Not a continuation, stop
        }

        // Only process continuations at or deeper than base_indent
        if (line.indent < base_indent) break;

        // Collect multi-line brace constructs on this continuation line
        const collected = try collectMultiLineBraces(allocator, lines, i);

        const cont = try parseSingleContinuation(allocator, collected.text, line.indent, line.line_num);
        const consumed_end = collected.end_idx;

        // Find nested continuations (indented deeper than this one)
        const nested_start = consumed_end + 1;
        const my_indent = line.indent;
        var nested_end = nested_start;
        while (nested_end < lines.len) {
            const nested_line = lines[nested_end];
            const nested_trimmed = lexer.trim(nested_line.content);
            if (nested_trimmed.len == 0 or lexer.isCommentLine(nested_line.content)) {
                nested_end += 1;
                continue;
            }
            if (nested_line.indent <= my_indent) break;
            nested_end += 1;
        }

        var final_cont = cont;
        if (nested_start < nested_end) {
            final_cont.continuations = try parseContinuations(allocator, lines, nested_start, my_indent + 1);
        }

        try continuations.append(allocator, final_cont);
        i = nested_end;
    }

    return continuations.toOwnedSlice(allocator);
}

fn collectMultiLineBraces(
    allocator: std.mem.Allocator,
    lines: []const LineInfo,
    start_idx: usize,
) ParseError!CollectedText {
    // Use lexer's brace depth counting (handles strings/comments)
    var depth: i32 = lexer.countBraceDepthChange(lines[start_idx].content);
    var end_idx = start_idx;

    if (depth > 0) {
        // Unbalanced open braces — collect until balanced
        var j = start_idx + 1;
        while (j < lines.len and depth > 0) {
            depth += lexer.countBraceDepthChange(lines[j].content);
            end_idx = j;
            j += 1;
        }
    }

    if (end_idx == start_idx) {
        return .{
            .text = lines[start_idx].content,
            .start_line = lines[start_idx].line_num,
            .end_idx = end_idx,
        };
    }

    // Join lines
    var total_len: usize = 0;
    for (lines[start_idx .. end_idx + 1]) |line| {
        if (total_len > 0) total_len += 1;
        total_len += lexer.trim(line.content).len;
    }

    var buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (lines[start_idx .. end_idx + 1]) |line| {
        if (pos > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        const trimmed_line = lexer.trim(line.content);
        @memcpy(buf[pos..][0..trimmed_line.len], trimmed_line);
        pos += trimmed_line.len;
    }

    return .{
        .text = buf,
        .start_line = lines[start_idx].line_num,
        .end_idx = end_idx,
    };
}

// ============================================================================
// Single continuation parsing
// ============================================================================

fn parseSingleContinuation(
    allocator: std.mem.Allocator,
    line: []const u8,
    indent: usize,
    line_num: usize,
) ParseError!ast.Continuation {
    var content = lexer.trim(line);

    // Determine if catch-all (|?)
    var is_catchall = false;
    if (std.mem.startsWith(u8, content, "|?")) {
        is_catchall = true;
        content = lexer.trim(content[2..]);
    } else if (std.mem.startsWith(u8, content, "|>")) {
        // Pipeline continuation: |> event()
        content = lexer.trim(content[2..]);
        const node = try parseNode(allocator, content);
        return .{
            .branch = try allocator.dupe(u8, ""),
            .binding = null,
            .condition = null,
            .node = node,
            .indent = indent,
            .continuations = try allocator.alloc(ast.Continuation, 0),
            .location = .{ .file = "eval", .line = line_num, .column = 0 },
        };
    } else if (std.mem.startsWith(u8, content, "|")) {
        content = lexer.trim(content[1..]);
    } else {
        return ParseError.MalformedContinuation;
    }

    // Now content is after the initial | marker.
    // Pattern: branch [binding] [when condition] |> node
    // Or:      branch [binding] [when condition] |> _  (terminal)
    // Or:      branch [binding] |> (no node — empty)

    // Find the |> separator
    const pipe_gt = findPipeGt(content);

    if (pipe_gt) |pg_idx| {
        const before_pipe = lexer.trim(content[0..pg_idx]);
        const after_pipe = lexer.trim(content[pg_idx + 2..]);

        // Parse before |>: branch [binding] [when condition]
        const branch_info = try parseBranchInfo(allocator, before_pipe);

        // Parse after |>: node
        const node = if (after_pipe.len > 0)
            try parseNode(allocator, after_pipe)
        else
            null;

        return .{
            .branch = branch_info.branch,
            .binding = branch_info.binding,
            .is_catchall = is_catchall,
            .condition = branch_info.condition,
            .node = node,
            .indent = indent,
            .continuations = try allocator.alloc(ast.Continuation, 0),
            .location = .{ .file = "eval", .line = line_num, .column = 0 },
        };
    } else {
        // No |> — this is a branch-only line (the node comes from nested continuations)
        const branch_info = try parseBranchInfo(allocator, content);
        return .{
            .branch = branch_info.branch,
            .binding = branch_info.binding,
            .is_catchall = is_catchall,
            .condition = branch_info.condition,
            .node = null,
            .indent = indent,
            .continuations = try allocator.alloc(ast.Continuation, 0),
            .location = .{ .file = "eval", .line = line_num, .column = 0 },
        };
    }
}

/// Find |> that's not inside braces, parens, or strings
fn findPipeGt(text: []const u8) ?usize {
    var brace_depth: usize = 0;
    var paren_depth: usize = 0;
    var in_string = false;
    var string_char: ?u8 = null;

    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (!in_string and (c == '"' or c == '\'')) {
            in_string = true;
            string_char = c;
        } else if (in_string) {
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == string_char) {
                in_string = false;
                string_char = null;
            }
            i += 1;
            continue;
        }

        switch (c) {
            '{' => brace_depth += 1,
            '}' => brace_depth -|= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -|= 1,
            '|' => {
                if (brace_depth == 0 and paren_depth == 0 and i + 1 < text.len and text[i + 1] == '>') {
                    return i;
                }
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

const BranchInfo = struct {
    branch: []const u8,
    binding: ?[]const u8,
    condition: ?[]const u8,
};

fn parseBranchInfo(allocator: std.mem.Allocator, text: []const u8) ParseError!BranchInfo {
    var content = lexer.trim(text);

    // Extract when-clause if present: "branch binding when condition"
    var condition: ?[]const u8 = null;
    if (findWhenKeyword(content)) |when_idx| {
        const when_text = lexer.trim(content[when_idx + 4..]);
        if (when_text.len > 0) {
            condition = try allocator.dupe(u8, when_text);
        }
        content = lexer.trim(content[0..when_idx]);
    }

    // Split remaining into tokens (branch name + optional binding)
    var tokens = std.mem.tokenizeAny(u8, content, " \t");
    const branch_name = tokens.next() orelse "";
    const binding = tokens.next();

    return .{
        .branch = try allocator.dupe(u8, branch_name),
        .binding = if (binding) |b| try allocator.dupe(u8, b) else null,
        .condition = condition,
    };
}

/// Find "when" keyword that's a standalone word (not part of an identifier)
fn findWhenKeyword(text: []const u8) ?usize {
    var i: usize = 0;
    while (i + 4 <= text.len) {
        if (std.mem.eql(u8, text[i .. i + 4], "when")) {
            // Check it's a word boundary
            const before_ok = i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t';
            const after_ok = i + 4 >= text.len or text[i + 4] == ' ' or text[i + 4] == '\t';
            if (before_ok and after_ok) return i;
        }
        i += 1;
    }
    return null;
}

// ============================================================================
// Node parsing
// ============================================================================

fn parseNode(allocator: std.mem.Allocator, content: []const u8) ParseError!ast.Node {
    const trimmed = lexer.trim(content);

    // Terminal: _
    if (std.mem.eql(u8, trimmed, "_")) {
        return .terminal;
    }

    // Branch constructor: name { field: val, ... } or name { val }
    if (isBranchConstructor(trimmed)) {
        const bc = try parseBranchConstructor(allocator, trimmed);
        return .{ .branch_constructor = bc };
    }

    // Braceless branch constructor: a single identifier without parens
    // e.g., | done |> ok
    // But NOT if it looks like an invocation (has parens or dots)
    if (isPlainBranchName(trimmed)) {
        return .{ .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, trimmed),
            .fields = try allocator.alloc(ast.Field, 0),
        } };
    }

    // Branch constructor with plain value expression: "name expr"
    // e.g., "result s" or "result s.Branch"
    // Recognized by: first token is identifier, rest has no parens
    if (std.mem.indexOf(u8, trimmed, "(") == null) {
        if (std.mem.indexOf(u8, trimmed, " ")) |space_idx| {
            const name_part = trimmed[0..space_idx];
            const value_part = lexer.trim(trimmed[space_idx + 1 ..]);
            if (name_part.len > 0 and value_part.len > 0 and
                (std.ascii.isAlphabetic(name_part[0]) or name_part[0] == '_'))
            {
                return .{ .branch_constructor = .{
                    .branch_name = try allocator.dupe(u8, name_part),
                    .fields = try allocator.alloc(ast.Field, 0),
                    .plain_value = try allocator.dupe(u8, value_part),
                } };
            }
        }
    }

    // Invocation: path(args) or just path.with.dots
    const inv = parseInvocationLine(allocator, trimmed, 0) catch return ParseError.MalformedNode;
    return .{ .invocation = inv };
}

fn isBranchConstructor(text: []const u8) bool {
    // name { ... } pattern — find first { and check it's preceded by an identifier
    const brace_idx = std.mem.indexOf(u8, text, "{") orelse return false;
    if (brace_idx == 0) return false;

    // Check that there's a closing brace
    _ = std.mem.lastIndexOf(u8, text, "}") orelse return false;

    // Check that the part before { is a simple name (no parens)
    const before = lexer.trim(text[0..brace_idx]);
    // Must not contain ( — that would be an invocation
    return std.mem.indexOf(u8, before, "(") == null and before.len > 0;
}

fn isPlainBranchName(text: []const u8) bool {
    // A plain branch name is a single identifier with no dots, parens, braces, or spaces
    if (text.len == 0) return false;
    for (text) |c| {
        if (c == '.' or c == '(' or c == ')' or c == '{' or c == '}' or
            c == ' ' or c == '\t' or c == ':')
        {
            return false;
        }
    }
    // Must start with a letter or underscore
    return std.ascii.isAlphabetic(text[0]) or text[0] == '_';
}

fn parseBranchConstructor(allocator: std.mem.Allocator, text: []const u8) ParseError!ast.BranchConstructor {
    // Find the opening brace
    const brace_start = std.mem.indexOf(u8, text, "{") orelse return ParseError.MalformedBranchConstructor;
    const branch_name = lexer.trim(text[0..brace_start]);

    // Find matching closing brace
    const brace_end = lexer.findMatchingBrace(text, brace_start) orelse return ParseError.UnbalancedBraces;
    const inner = lexer.trim(text[brace_start + 1 .. brace_end]);

    if (inner.len == 0) {
        // Empty constructor: name {}
        return .{
            .branch_name = try allocator.dupe(u8, branch_name),
            .fields = try allocator.alloc(ast.Field, 0),
        };
    }

    // Check if inner content has colons (field: value pairs) or is a plain value
    if (lexer.indexOfAtDepthZero(inner, ':')) |_| {
        // Field pairs: name { field1: val1, field2: val2 }
        const fields = try parseFieldPairs(allocator, inner);
        return .{
            .branch_name = try allocator.dupe(u8, branch_name),
            .fields = fields,
        };
    } else {
        // Plain value: name { value }
        return .{
            .branch_name = try allocator.dupe(u8, branch_name),
            .fields = try allocator.alloc(ast.Field, 0),
            .plain_value = try allocator.dupe(u8, inner),
        };
    }
}

fn parseFieldPairs(allocator: std.mem.Allocator, inner: []const u8) ParseError![]const ast.Field {
    // Use lexer.parseArgs which handles comma-separated name: value pairs
    const pairs = lexer.parseArgs(allocator, inner) catch return ParseError.MalformedBranchConstructor;

    var fields = try std.ArrayList(ast.Field).initCapacity(allocator, pairs.len);
    for (pairs) |pair| {
        try fields.append(allocator, .{
            .name = try allocator.dupe(u8, pair.name),
            .type = try allocator.dupe(u8, "unknown"),
            .expression_str = try allocator.dupe(u8, pair.value),
        });
    }
    return fields.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "parseFlow: empty input" {
    const result = parseFlow(std.testing.allocator, "");
    switch (result) {
        .err => |e| try std.testing.expectEqualStrings("Empty input", e.message),
        .flow => return error.ExpectedError,
    }
}

test "parseFlow: whitespace-only input" {
    const result = parseFlow(std.testing.allocator, "   \n  \n  ");
    switch (result) {
        .err => |e| try std.testing.expectEqualStrings("Empty input", e.message),
        .flow => return error.ExpectedError,
    }
}

test "parseFlow: simple invocation no args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "greet");
    switch (result) {
        .flow => |f| {
            try std.testing.expect(f.invocation.path.module_qualifier == null);
            try std.testing.expectEqual(@as(usize, 1), f.invocation.path.segments.len);
            try std.testing.expectEqualStrings("greet", f.invocation.path.segments[0]);
            try std.testing.expectEqual(@as(usize, 0), f.invocation.args.len);
            try std.testing.expectEqual(@as(usize, 0), f.continuations.len);
        },
        .err => |e| {
            std.debug.print("Unexpected error: {s}\n", .{e.message});
            return error.UnexpectedError;
        },
    }
}

test "parseFlow: invocation with args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "add(a: 3, b: 4)");
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.invocation.path.segments.len);
            try std.testing.expectEqualStrings("add", f.invocation.path.segments[0]);
            try std.testing.expectEqual(@as(usize, 2), f.invocation.args.len);
            try std.testing.expectEqualStrings("a", f.invocation.args[0].name);
            try std.testing.expectEqualStrings("3", f.invocation.args[0].value);
            try std.testing.expectEqualStrings("b", f.invocation.args[1].name);
            try std.testing.expectEqualStrings("4", f.invocation.args[1].value);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: ~ prefix stripped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "~add(a: 3)");
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqualStrings("add", f.invocation.path.segments[0]);
            try std.testing.expectEqual(@as(usize, 1), f.invocation.args.len);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: module-qualified path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "math:add(a: 3, b: 4)");
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqualStrings("math", f.invocation.path.module_qualifier.?);
            try std.testing.expectEqualStrings("add", f.invocation.path.segments[0]);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: single continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\add(a: 3, b: 4)
        \\    | sum s |> result { value: s }
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
            const cont = f.continuations[0];
            try std.testing.expectEqualStrings("sum", cont.branch);
            try std.testing.expectEqualStrings("s", cont.binding.?);
            try std.testing.expect(cont.node != null);
            switch (cont.node.?) {
                .branch_constructor => |bc| {
                    try std.testing.expectEqualStrings("result", bc.branch_name);
                    try std.testing.expectEqual(@as(usize, 1), bc.fields.len);
                    try std.testing.expectEqualStrings("value", bc.fields[0].name);
                },
                else => return error.UnexpectedNodeType,
            }
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: multiple continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\divide(a: 10, b: 2)
        \\    | ok result |> format(value: result)
        \\    | error e |> fail { message: e }
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 2), f.continuations.len);
            try std.testing.expectEqualStrings("ok", f.continuations[0].branch);
            try std.testing.expectEqualStrings("result", f.continuations[0].binding.?);
            try std.testing.expectEqualStrings("error", f.continuations[1].branch);
            try std.testing.expectEqualStrings("e", f.continuations[1].binding.?);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: nested continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\add(a: 3, b: 4)
        \\    | sum s |> add(a: s, b: 10)
        \\        | sum s2 |> result { value: s2 }
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
            const outer = f.continuations[0];
            try std.testing.expectEqualStrings("sum", outer.branch);
            // The outer continuation's node is an invocation
            switch (outer.node.?) {
                .invocation => |inv| {
                    try std.testing.expectEqualStrings("add", inv.path.segments[0]);
                },
                else => return error.UnexpectedNodeType,
            }
            // And it has nested continuations
            try std.testing.expectEqual(@as(usize, 1), outer.continuations.len);
            try std.testing.expectEqualStrings("sum", outer.continuations[0].branch);
            try std.testing.expectEqualStrings("s2", outer.continuations[0].binding.?);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: terminal _" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\fire_and_forget()
        \\    | done |> _
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
            switch (f.continuations[0].node.?) {
                .terminal => {},
                else => return error.ExpectedTerminal,
            }
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: pipeline continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\step_one()
        \\    |> step_two()
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
            try std.testing.expectEqualStrings("", f.continuations[0].branch);
            try std.testing.expect(f.continuations[0].binding == null);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: catch-all continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\risky_call()
        \\    |? err |> handle_error(e: err)
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
            try std.testing.expect(f.continuations[0].is_catchall);
            try std.testing.expectEqualStrings("err", f.continuations[0].branch);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: when clause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\check(value: x)
        \\    | ok r when r > 10 |> big_handler(v: r)
        \\    | ok r |> small_handler(v: r)
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 2), f.continuations.len);
            try std.testing.expectEqualStrings("ok", f.continuations[0].branch);
            try std.testing.expectEqualStrings("r", f.continuations[0].binding.?);
            try std.testing.expectEqualStrings("r > 10", f.continuations[0].condition.?);
            try std.testing.expect(f.continuations[1].condition == null);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: comment lines skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\// This is a comment
        \\add(a: 1, b: 2)
        \\    // Another comment
        \\    | sum s |> result { value: s }
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqualStrings("add", f.invocation.path.segments[0]);
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: dotted path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "file.read(path: \"/tmp/test\")");
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 2), f.invocation.path.segments.len);
            try std.testing.expectEqualStrings("file", f.invocation.path.segments[0]);
            try std.testing.expectEqualStrings("read", f.invocation.path.segments[1]);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: braceless branch constructor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\process()
        \\    | done |> ok
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.continuations.len);
            switch (f.continuations[0].node.?) {
                .branch_constructor => |bc| {
                    try std.testing.expectEqualStrings("ok", bc.branch_name);
                    try std.testing.expectEqual(@as(usize, 0), bc.fields.len);
                    try std.testing.expect(bc.plain_value == null);
                },
                else => return error.ExpectedBranchConstructor,
            }
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: no continuations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "fire(target: enemy)");
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqualStrings("fire", f.invocation.path.segments[0]);
            try std.testing.expectEqual(@as(usize, 0), f.continuations.len);
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: branch constructor with plain value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\calc()
        \\    | done |> result { 42 }
    ;

    const result = parseFlow(alloc, source);
    switch (result) {
        .flow => |f| {
            switch (f.continuations[0].node.?) {
                .branch_constructor => |bc| {
                    try std.testing.expectEqualStrings("result", bc.branch_name);
                    try std.testing.expectEqualStrings("42", bc.plain_value.?);
                },
                else => return error.ExpectedBranchConstructor,
            }
        },
        .err => return error.UnexpectedError,
    }
}

test "parseFlow: module is eval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseFlow(alloc, "test()");
    switch (result) {
        .flow => |f| {
            try std.testing.expectEqualStrings("eval", f.module);
        },
        .err => return error.UnexpectedError,
    }
}
