const std = @import("std");
const ast = @import("ast");
const ast_mangle = @import("ast_mangle");
const lexer = @import("lexer");
const errors = @import("errors");
const type_registry = @import("type_registry");
const expression_parser = @import("expression_parser");
const struct_literal = @import("struct_literal");
const annotation_parser = @import("annotation_parser");
const comptime_eval = @import("comptime_eval");
const ModuleResolver = @import("module_resolver").ModuleResolver;
const module_resolver_mod = @import("module_resolver");
const file_types = @import("file_types");

// Re-export ExpressionParser for runtime use (e.g., interpreter ~if)
pub const ExpressionParser = expression_parser.ExpressionParser;

// Debug logging disabled by default - set to true for verbose parser debugging
const DEBUG = false;
fn log_debug(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) std.debug.print(fmt, args);
}

/// Attempt to parse an arg's value as an expression and store the result.
/// Values that don't parse (types, source blocks, module paths, partial matches) silently remain null.
pub fn tryParseArgExpression(allocator: std.mem.Allocator, arg: *ast.Arg) void {
    const trimmed = std.mem.trim(u8, arg.value, " \t");
    // Skip source blocks — not expressions
    if (trimmed.len >= 1 and trimmed[0] == '{') return;
    // Skip empty values
    if (trimmed.len == 0) return;

    var expr_parser = expression_parser.ExpressionParser.init(allocator, arg.value);
    defer expr_parser.deinit();

    if (expr_parser.parse()) |expr| {
        // Verify parser consumed ALL input (avoid partial matches like "i32" → "i" + leftover "32")
        const remaining = std.mem.trim(u8, expr_parser.input[expr_parser.pos..], " \t");
        if (remaining.len == 0) {
            arg.parsed_expression = expr;
        } else {
            // Partial parse — not a valid expression, free it
            var mutable_expr = @constCast(expr);
            mutable_expr.deinit(allocator);
        }
    } else |_| {}
}

/// Check if line has a source block pattern: `eventName { ... }` or `eventName(args) { ... }`
/// Source blocks are opaque - their content should not affect parsing decisions.
/// Returns true if there's a `{` that's NOT inside parentheses AND no `=` before it.
/// The `=` check distinguishes source blocks from subflow impls with branch constructors:
/// Net paren balance of a line, QUOTE-AWARE: parens inside string ("...") or
/// char ('...') literals are text, not structure. Backslash escapes honored.
/// A quote-blind count mistakes `if(c == '(')` for an unbalanced line — the
/// multiline joiner then swallows following branch lines (pinned by 210_122).
fn netParens(s: []const u8) i32 {
    var depth: i32 = 0;
    var quote: u8 = 0; // 0 = not in a literal; otherwise the delimiter
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1; // skip the escaped char
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(' => depth += 1,
            ')' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

/// Net brace depth of a line, quote-aware (braces inside string/char
/// literals are text, not structure — the paren twin of `netParens`).
/// The multi-line source-block gatherer uses this to know WHEN a block
/// actually closes: an indent-only heuristic swallowed a following branch
/// line whenever an inline block closed mid-line (`} |> self { … }`),
/// silently discarding that branch's header (pinned by 210_139).
fn netBraces(s: []const u8) i32 {
    var depth: i32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
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
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

///   - Source block:   `~event { content }`      - no = before {
///   - Subflow impl:   `~event = branch { ... }` - has = before {
fn hasSourceBlock(s: []const u8) bool {
    var paren_depth: i32 = 0;
    var in_string = false;
    var seen_equals = false;
    var seen_arrow = false;

    for (s, 0..) |c, i| {
        // Track string state (skip escaped quotes)
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }

        if (in_string) continue;

        // Track paren depth
        if (c == '(') paren_depth += 1;
        if (c == ')') paren_depth -= 1;

        // Track if we've seen = at top level (indicates subflow impl)
        if (c == '=' and paren_depth == 0) {
            seen_equals = true;
        }

        // Track if we've seen `->` at top level. A `{` after a top-level `->` is
        // the bare-return body (e.g. `~run -> { total: x*2 }`), not a source
        // block — let it fall through to the isBareReturnImpl dispatch.
        if (c == '-' and paren_depth == 0 and i + 1 < s.len and s[i + 1] == '>') {
            seen_arrow = true;
        }

        // A `{` at paren_depth 0, with no prior `=` or `->`, means source block
        if (c == '{' and paren_depth == 0) {
            return !seen_equals and !seen_arrow;
        }
    }

    return false;
}

/// Find '=' at the top level (not inside (), {}, or strings)
/// Used inside parseSubflowImpl to find the split point
fn findTopLevelEquals(s: []const u8) ?usize {
    var paren_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;

    for (s, 0..) |c, i| {
        // Track string state (skip escaped quotes)
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }

        if (in_string) continue;

        // Track nesting depth
        if (c == '(') paren_depth += 1;
        if (c == ')') paren_depth -= 1;
        if (c == '{') brace_depth += 1;
        if (c == '}') brace_depth -= 1;

        // Only match = at top level
        if (c == '=' and paren_depth == 0 and brace_depth == 0) {
            return i;
        }
    }

    return null;
}

fn indexOfTopLevelArrow(s: []const u8) ?usize {
    var paren_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (c == '(') paren_depth += 1;
        if (c == ')') paren_depth -= 1;
        if (c == '{') brace_depth += 1;
        if (c == '}') brace_depth -= 1;

        if (c == '-' and paren_depth == 0 and brace_depth == 0 and i + 1 < s.len and s[i + 1] == '>') {
            return i;
        }
    }

    return null;
}

fn hasTopLevelArrow(s: []const u8) bool {
    return indexOfTopLevelArrow(s) != null;
}

/// First BIND colon at paren/brace depth 0 — a `:` whose previous non-blank
/// character is `)`, i.e. the `event(args): name` form. That is the head scan's
/// own definition of a bind colon (arg colons live inside the parens; a module
/// qualifier's colon precedes its `(`), applied to the WHOLE line instead of
/// only the first call, because in a chain the bind may sit on any step.
fn indexOfTopLevelBindColon(s: []const u8) ?usize {
    var paren_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;

    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (c == '(') paren_depth += 1;
        if (c == ')') paren_depth -= 1;
        if (c == '{') brace_depth += 1;
        if (c == '}') brace_depth -= 1;

        if (c != ':' or paren_depth != 0 or brace_depth != 0) continue;
        var j = i;
        while (j > 0) {
            j -= 1;
            if (s[j] == ' ' or s[j] == '\t') continue;
            if (s[j] == ')') return i;
            break;
        }
    }

    return null;
}

/// Index of the first top-level construct/produce arrow — `=>` (construct) or
/// `->` (produce) — outside parens, braces, and string literals. An invocation
/// HEAD ends here: everything after the arrow is a bare-return continuation that
/// the caller re-parses from the original line. Used to isolate the head so the
/// source-block pre-checks never mistake a braced constructor payload
/// (`... => final { r }`) for a source block on the branch name (pinned 100_085).
fn indexOfTopLevelHeadArrow(s: []const u8) ?usize {
    var paren_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '(') paren_depth += 1;
        if (c == ')') paren_depth -= 1;
        if (c == '{') brace_depth += 1;
        if (c == '}') brace_depth -= 1;
        if (paren_depth == 0 and brace_depth == 0 and
            (c == '=' or c == '-') and i + 1 < s.len and s[i + 1] == '>')
        {
            return i;
        }
    }
    return null;
}

/// Return `s` with a trailing `// ...` line comment removed (the `//` must be
/// outside a string literal). Used so body-glyph detection never trips on a
/// `->`/`|>`/`=>` that lives inside a trailing comment.
fn stripTrailingLineComment(s: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '/' and s[i + 1] == '/') {
            return lexer.trim(s[0..i]);
        }
    }
    return s;
}

/// `~event -> expr` is a bare-return implementation (the `->` twin of the `=>`
/// branch constructor). Distinguished from a call-site `~event(args) -> d` bind
/// by the absence of call parens on the event name: an impl has a top-level `->`
/// with no `(` before it.
fn isBareReturnImpl(s: []const u8) bool {
    const arrow = indexOfTopLevelArrow(s) orelse return false;
    // A call site (`~event(args): b`) has parens on the name — not an impl.
    if (std.mem.indexOfScalar(u8, s[0..arrow], '(') != null) return false;
    // A bare-return body is a single value expression. If it carries top-level
    // branch continuations (`|` / `|>`) it's continuation/tap syntax (e.g. the
    // abandoned `~src -> * | branch` output-tap form), not a bare return — let it
    // fall through to the invocation path, which rejects a stray top-level `->`.
    const body = s[arrow + 2 ..];
    var depth: i32 = 0;
    var in_str = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '"' and (i == 0 or body[i - 1] != '\\')) {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '(' or c == '{' or c == '[') {
            depth += 1;
        } else if (c == ')' or c == '}' or c == ']') {
            depth -= 1;
        } else if (depth == 0 and c == '|') {
            return false;
        }
    }
    return true;
}

const ReturnArrowSplit = struct {
    head: []const u8, // decl tail with the `-> T` suffix removed (NOT owned — slice of input)
    return_type: ?[]const u8 = null, // owned dupe, or null
    return_phantom: ?[]const u8 = null, // owned dupe, or null
};

/// Split a `-> T` (optionally `-> *R<phantom>`) return suffix off an event/flow
/// decl tail. Scans at bracket/brace/angle/paren depth 0 so an arrow inside a
/// `{...}` input payload, a `<...>` phantom, or `[...]` annotation is ignored —
/// only the top-level return arrow is split. Caller owns the duped type/phantom.
/// This is the event-level analogue of the effect-branch `-> U` resume parsing.
///
/// `decl_line` is the 1-based line `s` was written on. It must be passed in:
/// by the time this runs the cursor has already advanced past the declaration,
/// so deriving a location from `self.current` here blames the line after the
/// one at fault — which on a file ending in the declaration is past EOF.
fn splitTrailingReturnArrow(self: *Parser, s: []const u8, decl_line: usize) !ReturnArrowSplit {
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    var arrow_at: ?usize = null;
    while (i + 1 < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '(' or c == '{' or c == '[' or c == '<') {
            depth += 1;
        } else if (c == ')' or c == '}' or c == ']' or c == '>') {
            depth -= 1;
        } else if (depth == 0 and c == '-' and s[i + 1] == '>') {
            arrow_at = i;
            break;
        }
    }
    if (arrow_at == null) return .{ .head = s };

    const head = lexer.trim(s[0..arrow_at.?]);
    var rt = lexer.trim(s[arrow_at.? + 2 ..]);
    // A trailing line comment is not part of the type. Branch payloads have
    // always dropped theirs; the bare-return suffix did not, so
    // `-> *Data<gc>  // GC-managed` carried the prose into the emitted Zig as
    // `pub const Output = *Data  // GC-managed;` (524). Scan at depth 0 and
    // outside strings so a `//` inside `{ ... }` or a literal survives.
    {
        var cdepth: i32 = 0;
        var cin_str = false;
        var k: usize = 0;
        while (k + 1 < rt.len) : (k += 1) {
            const c = rt[k];
            if (c == '"' and (k == 0 or rt[k - 1] != '\\')) {
                cin_str = !cin_str;
                continue;
            }
            if (cin_str) continue;
            if (c == '(' or c == '{' or c == '[' or c == '<') {
                cdepth += 1;
            } else if (c == ')' or c == '}' or c == ']' or c == '>') {
                cdepth -= 1;
            } else if (cdepth == 0 and c == '/' and rt[k + 1] == '/') {
                rt = lexer.trim(rt[0..k]);
                break;
            }
        }
    }
    var return_phantom: ?[]const u8 = null;
    // Capture a trailing `<phantom>` on the return type, mirroring the
    // effect-branch resume-type phantom capture at the `| !` parser.
    if (rt.len > 0 and rt[rt.len - 1] == '>') {
        var angle_depth: i32 = 0;
        var j: usize = rt.len - 1;
        const end_pos = j;
        var start_pos: ?usize = null;
        while (j > 0) : (j -= 1) {
            if (rt[j] == '>') {
                angle_depth += 1;
            } else if (rt[j] == '<') {
                angle_depth -= 1;
                if (angle_depth == 0) {
                    start_pos = j;
                    break;
                }
            }
        }
        if (start_pos) |start| {
            if (start > 0) {
                const content = rt[start + 1 .. end_pos];
                if (content.len > 0) {
                    return_phantom = try self.allocator.dupe(u8, content);
                    rt = lexer.trim(rt[0..start]);
                }
            }
        }
    }
    // `[]const u8` is not a Koru surface type in a return position either — the
    // same wall as payloads, on the phantom-stripped base. `string` is the
    // canonical text type; the slice is only the Zig lowering.
    if (std.mem.eql(u8, rt, "[]const u8")) {
        try self.reporter.addError(
            .PARSE003,
            decl_line,
            1,
            "'[]const u8' is not a Koru return type. Use 'string' for text — it lowers to []const u8 for Zig",
            .{},
        );
        return error.ParseError;
    }
    const return_type: ?[]const u8 = if (rt.len > 0) try self.allocator.dupe(u8, rt) else null;
    return .{ .head = head, .return_type = return_type, .return_phantom = return_phantom };
}

/// A `-> { ... }` type string carrying exactly ONE top-level field. Such a
/// single-field record collapses to the scalar (`-> T`) in every produce
/// position — bare return (`-> { a }`, 210_149) and effect-arm resume
/// (`! ask -> { a }`, 210_150) — the produce-side twin of the single-field
/// branch-payload rule (2032/8680). Legal forms are the scalar `-> T` or a
/// multi-field record `-> { a, b, ... }`. Returns false for scalars (no
/// braces), empty braces (a distinct error), and 2+-field records.
fn isSingleFieldRecordType(t: []const u8) bool {
    const s = std.mem.trim(u8, t, " \t");
    if (s.len < 2 or s[0] != '{' or s[s.len - 1] != '}') return false;
    const inner = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
    if (inner.len == 0) return false;
    // Count top-level fields = top-level commas + 1 (commas nested in
    // <>/{}/[]/() — e.g. a phantom `*H<owned!>` or nested record — don't split).
    var depth: i32 = 0;
    var fields: usize = 1;
    for (inner) |c| {
        switch (c) {
            '<', '{', '[', '(' => depth += 1,
            '>', '}', ']', ')' => depth -= 1,
            ',' => if (depth == 0) {
                fields += 1;
            },
            else => {},
        }
    }
    return fields == 1;
}

/// Find '{' at top level (not inside (), [] or strings)
/// startsWithKeyword: true iff `s` begins with `keyword` AND the next char is
/// a non-identifier (whitespace / `{` / `(` / EOL). Prevents `~process_int`
/// from being mis-classified as `~proc`, etc.
fn startsWithKeyword(s: []const u8, keyword: []const u8) bool {
    if (!std.mem.startsWith(u8, s, keyword)) return false;
    if (s.len == keyword.len) return true;
    const next = s[keyword.len];
    return !(std.ascii.isAlphanumeric(next) or next == '_');
}

fn findTopLevelBrace(s: []const u8) ?usize {
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_string = false;

    for (s, 0..) |c, i| {
        if (c == '"' and (i == 0 or s[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }

        if (in_string) continue;

        if (c == '(') paren_depth += 1;
        if (c == ')') paren_depth -= 1;
        if (c == '[') bracket_depth += 1;
        if (c == ']') bracket_depth -= 1;

        if (c == '{' and paren_depth == 0 and bracket_depth == 0) {
            return i;
        }
    }

    return null;
}

/// Parser error set - explicit to avoid circular dependency issues
pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
    UnexpectedEOF, // Match the actual error used in the code
    InvalidEventDeclaration,
    InvalidProcDeclaration,
    InvalidFlowSyntax,
    InvalidContinuation,
    MissingEventImplementation,
    DuplicateDeclaration,
    TypeRegistryError,
};

/// Result of parsing that includes both the AST and type registry
pub const ParseResult = struct {
    source_file: ast.Program,
    registry: type_registry.TypeRegistry,

    pub fn deinit(self: *ParseResult) void {
        self.source_file.deinit();
        self.registry.deinit();
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lines: [][]const u8,
    current: usize,
    reporter: errors.ErrorReporter,

    // Parser state
    context_stack: std.ArrayList(Context),
    // Events can be implemented by procs or subflows
    registry: type_registry.TypeRegistry, // Type registry for all declarations

    // Content after the closing `}` of a MULTI-LINE event input shape (the
    // `-> SiteResult` of a `}\n`-closing decl). parseEventInputShapeFromLine
    // stashes it here because its return value is the Shape alone; the event
    // decl parser consumes it as the bare-return suffix. Single-line decls
    // never set this — their post-shape text is handled on the decl line.
    multiline_shape_tail: ?[]const u8 = null,
    /// 1-based line the stashed tail was written on — the shape's CLOSING line,
    /// not the tor header. A diagnostic about `} -> T` belongs on the line the
    /// author wrote it on.
    multiline_shape_tail_line: usize = 0,

    // Flag to indicate if we're parsing the compiler bootstrap library
    // When true, procs in this file cannot use inline flows (metacircular requirement)
    is_compiler_library: bool,

    // True when parsing a `.k` file: pure Koru, no host lines. The `~` host->Koru
    // switch is forbidden at line start (there is no host to switch from); every
    // construct line is Koru. `//` comments are handled by the Koru parser itself
    // (no host backend to forward them to).
    is_k: bool,

    // FOUNDATIONAL: Module context for all parsed items
    module_name: []const u8, // Canonical module path (e.g., "input", "lib/fs")

    // Global inline flow counter - must match emitter's global numbering
    inline_flow_counter: u32,
    // Monotonic counter for the synthetic temp a bind-position destructure
    // (`~f(): { x } |>`) binds the return to before emitting per-field consts.
    destructure_ret_counter: u32 = 0,

    // Rationale prose from the vertical annotation block currently being
    // attached. A vertical block is flattened to a synthetic `~[a|b]construct`
    // line and re-parsed, so the prose cannot ride the text — it waits here and
    // the decl constructor takes it. Owned; replaced or freed, never leaked.
    pending_prose: []const u8 = "",

    // Parse mode: false = lenient (continue past errors), true = fail-fast (stop at first error)
    fail_fast: bool,

    // Set true when parse() succeeds and registry ownership moves to ParseResult
    registry_transferred: bool,

    // Compiler flags for conditional compilation (e.g., ~[profile]import)
    compiler_flags: []const []const u8,
    // Process env for the import gate's provider chain (cflags → env →
    // absent-is-false). Built lazily on the first gated import.
    gate_env_map: ?std.process.EnvMap = null,

    // Module resolver for imports (null for bootstrap/help parsing)
    resolver: ?*ModuleResolver,

    const Context = union(enum) {
        top_level,
        in_event,
        in_proc,
        in_subflow_impl,
        in_flow,
        in_continuation: struct {
            branch: []const u8,
            binding: ?[]const u8,
        },
    };

    fn isInProc(self: *Parser) bool {
        // Check if any context in the stack allows full expressions
        // Both procs and subflow impls are implementation code that allows arithmetic/complex expressions
        for (self.context_stack.items) |ctx| {
            switch (ctx) {
                .in_proc, .in_subflow_impl => return true,
                else => {},
            }
        }
        return false;
    }

    /// Get current source location for error reporting and AST metadata
    fn getCurrentLocation(self: *Parser) errors.SourceLocation {
        return self.getLineLocation(self.current, 0);
    }

    /// Get source location for a specific line and indent (column)
    fn getLineLocation(self: *Parser, line_idx: usize, indent: usize) errors.SourceLocation {
        return .{
            .file = self.reporter.file_name,
            .line = if (line_idx < self.lines.len) line_idx + 1 else self.lines.len,
            .column = indent,
        };
    }

    /// Read a source file for [type]"path" syntax
    /// Resolves relative paths from the current file's directory
    fn readSourceFile(self: *Parser, path: []const u8) ![]const u8 {
        const fs = std.fs;

        // Get the directory of the current file being parsed
        const current_file = self.reporter.file_name;
        const dir_end = std.mem.lastIndexOf(u8, current_file, "/") orelse 0;
        const current_dir = if (dir_end > 0) current_file[0..dir_end] else ".";

        // Build full path (relative to current file's directory)
        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = if (path[0] == '/' or path[0] == '~')
            // Absolute path - use as-is
            path
        else blk: {
            // Relative path - resolve from current file's directory
            const written = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ current_dir, path }) catch {
                return error.PathTooLong;
            };
            break :blk written;
        };

        // Open and read the file
        const file = fs.cwd().openFile(full_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            return err;
        };

        return content;
    }

    pub fn init(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8, compiler_flags: []const []const u8, resolver: ?*ModuleResolver) !Parser {
        // Parser init
        var lines_list = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        var iter = std.mem.splitScalar(u8, source, '\n');
        while (iter.next()) |line| {
            try lines_list.append(allocator, line);
        }
        // Lines parsed

        var context_stack = try std.ArrayList(Context).initCapacity(allocator, 8);
        try context_stack.append(allocator, .top_level);

        // Derive module name from file_name
        // Module name is the filename with its Koru extension stripped.
        // Examples:
        //   "input.kz" → "input"
        //   "test_lib/graphics.kjs" → "graphics"
        //   "koru_std/profiler.kz" → "profiler"
        // This enables circular imports and consistent naming across the codebase
        const basename = std.fs.path.basename(file_name);
        const file_ext = file_types.koruExtensionOf(basename);
        const module_name = blk: {
            if (file_ext) |ext| {
                const name_without_ext = basename[0 .. basename.len - ext.len];
                break :blk try allocator.dupe(u8, name_without_ext);
            } else {
                break :blk try allocator.dupe(u8, basename);
            }
        };
        // `.k` is the pure-Koru contract/source file: no host bytes, no `~`.
        const is_k = if (file_ext) |ext| std.mem.eql(u8, ext, ".k") else false;

        return Parser{
            .allocator = allocator,
            .lines = try lines_list.toOwnedSlice(allocator),
            .current = 0,
            .reporter = try errors.ErrorReporter.init(allocator, file_name, source),
            .context_stack = context_stack,
            // No subflow tracking needed - events are the interface
            .registry = type_registry.TypeRegistry.init(allocator),
            .is_compiler_library = false, // Default to false, caller can set if needed
            .is_k = is_k,
            .module_name = module_name,
            .inline_flow_counter = 0, // Global counter across all procs
            .fail_fast = false, // Default to lenient mode (continue past errors)
            .registry_transferred = false,
            .compiler_flags = compiler_flags, // Flags for conditional imports
            .resolver = resolver, // Module resolver for import paths
        };
    }

    pub fn deinit(self: *Parser) void {
        if (self.pending_prose.len > 0) self.allocator.free(self.pending_prose);
        if (self.gate_env_map) |*m| m.deinit();
        self.allocator.free(self.lines);
        self.reporter.deinit();
        self.context_stack.deinit(self.allocator);
        self.allocator.free(self.module_name);

        // Free subflow names
        // Clean shutdown
        if (!self.registry_transferred) {
            self.registry.deinit();
        }
    }

    /// Create an error node for lenient parsing mode
    /// Captures the raw source text and error details for IDE tooling
    fn createErrorNode(self: *Parser, start_line: usize, end_line: usize) !ast.ParseErrorNode {
        // Capture the raw text that failed to parse
        const actual_end = @min(end_line, self.lines.len);
        var raw_text_list = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer raw_text_list.deinit(self.allocator);

        for (start_line..actual_end) |i| {
            if (i < self.lines.len) {
                try raw_text_list.appendSlice(self.allocator, self.lines[i]);
                try raw_text_list.append(self.allocator, '\n');
            }
        }

        // Get the last error from reporter (the one that just occurred)
        const last_error = if (self.reporter.errors.items.len > 0)
            self.reporter.errors.items[self.reporter.errors.items.len - 1]
        else
            // Fallback if no error was recorded
            errors.ParseError{
                .code = .PARSE001,
                .message = try self.allocator.dupe(u8, "parse error"),
                .location = self.getCurrentLocation(),
                .hint = null,
            };

        return ast.ParseErrorNode{
            .error_code = last_error.code,
            .message = try self.allocator.dupe(u8, last_error.message),
            .location = last_error.location,
            .raw_text = try raw_text_list.toOwnedSlice(self.allocator),
            .hint = if (last_error.hint) |h| try self.allocator.dupe(u8, h) else null,
        };
    }

    /// Recover to the next Koru construct (next line starting with ~)
    /// Used in lenient parsing mode to skip past errors
    fn recoverToNextConstruct(self: *Parser) void {
        // Scan forward to next line starting with ~
        while (self.current < self.lines.len) {
            self.current += 1;
            if (self.current >= self.lines.len) break;

            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);
            if (lexer.startsWith(trimmed, "~")) break;
        }
    }

    /// Rejects `name: value` at a call site when the value, if punned, would
    /// produce the same name — e.g. `echo(v: v)` or `echo(v: p.x.v)`. The
    /// punned forms (`echo(v)`, `echo(p.x.v)`) are canonical; the explicit
    /// label adds nothing and is forbidden.
    fn checkRedundantPunning(self: *Parser, parsed_args: []const lexer.ArgPair, line: usize) !void {
        for (parsed_args) |arg| {
            if (lexer.isRedundantExplicitLabel(arg)) {
                try self.reporter.addErrorWithHint(
                    .PARSE005,
                    line,
                    1,
                    "redundant explicit label '{s}:' — the value '{s}' already puns to '{s}'",
                    .{ arg.name, arg.value, arg.name },
                    "drop the label: write '{s}' instead of '{s}: {s}'",
                    .{ arg.value, arg.name, arg.value },
                );
                return error.ParseError;
            }
        }
    }

    pub fn parse(self: *Parser) !ParseResult {
        // Parse all items in the source file
        // Starting parse

        var items = try std.ArrayList(ast.Item).initCapacity(self.allocator, 8);
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        var module_annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (module_annotations.items) |annotation| {
                self.allocator.free(annotation);
            }
            module_annotations.deinit(self.allocator);
        }

        // Parse each line
        while (self.current < self.lines.len) {
            // Process line

            var line = self.lines[self.current];
            var trimmed = lexer.trim(line);

            if (trimmed.len == 0) {
                self.current += 1;
                continue;
            }

            // `.k` files are pure Koru — no host lines, no `~` ceremony.
            if (self.is_k) {
                // Comments are the Koru parser's job here (no host backend to
                // forward them to).
                if (lexer.isCommentLine(line)) {
                    self.current += 1;
                    continue;
                }
                // `~` is the host->Koru switch; in a host-free file it is
                // meaningless. One way to write things — forbid it outright.
                if (trimmed[0] == '~') {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        lexer.getIndent(line) + 1,
                        "'~' is the host->Koru switch and has no meaning in a pure-Koru '.k' file — write the construct without it",
                        .{},
                    );
                    return error.ParseError;
                }
                // Host declarations (Zig/JS) have no place in a pure-Koru file.
                // Catch the common ones explicitly so the failure names the
                // boundary at the offending line instead of mis-parsing into a
                // cryptic downstream validation error. The "no native constant"
                // gap this names is exactly the aspiration: a self-contained `.k`
                // program needs Koru-native constants/functions to exist.
                // NOTE: `const` is NOT here — it is a Koru keyword
                // (declarations.kz), not host syntax. It lowers per-target and
                // is legal in `.k`.
                // A visibility qualifier cannot decide the question by itself —
                // `pub` is legal Koru here (`pub tor`, `pub proc`). So strip it
                // and judge the DECLARATION KEYWORD underneath, or every
                // qualified spelling walks past a wall that lists only the bare
                // one and dies later as a host error naming compiler internals.
                const qualifier = lexer.afterPrefix(trimmed, "pub ");
                const decl_body = qualifier orelse trimmed;
                const host_decls = [_][]const u8{ "var ", "comptime ", "fn ", "inline fn ", "export fn ", "extern fn " };
                for (host_decls) |kw| {
                    if (std.mem.startsWith(u8, decl_body, kw)) {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current + 1,
                            lexer.getIndent(line) + 1,
                            "host syntax '{s}{s}' is not valid in a pure-Koru '.k' file — constants, functions, and types live in a '.kz'/'.kjs' companion (Koru has no native constant/function declaration yet)",
                            .{ if (qualifier != null) "pub " else "", lexer.trim(kw) },
                        );
                        return error.ParseError;
                    }
                }
                // Branch/continuation lines (`|`, `!`) belong to a construct and
                // are consumed by it; anything else at top level is a construct.
                // Synthesize the leading `~` the surface no longer writes so the
                // existing construct machinery runs unchanged.
                if (trimmed[0] != '|' and trimmed[0] != '!') {
                    self.lines[self.current] = try std.fmt.allocPrint(self.allocator, "~{s}", .{trimmed});
                    line = self.lines[self.current];
                    trimmed = lexer.trim(line);
                }
            }

            // `.k` synthesizes `~` on top-level constructs above. Every other
            // `.k*` file (`.kz`, `.kjs`, …) requires the author to write `~`
            // before each Koru construct — including imports (`~import`).

            if (lexer.startsWith(line, "~")) {
                // Check if this is a module-level annotation: ~[annotation] on its own line
                const after_tilde = lexer.trim(trimmed[1..]);

                if (std.mem.startsWith(u8, after_tilde, "[")) {
                    // Parse annotation block (supports both inline ~[a|b] and vertical ~[\n-a\n-b\n])
                    const current_before = self.current;
                    const result = self.parseAnnotationBlock(after_tilde, self.current) catch |err| {
                        if (self.fail_fast) {
                            return err;
                        }
                        // Lenient mode: create error node and skip to next
                        // construct. The failed block scan ran the cursor to
                        // EOF looking for a `]`, so recovery must start again
                        // from the line that OPENED the block — otherwise there
                        // is nothing left to scan and every construct below the
                        // malformed annotation is dropped without a trace.
                        self.current = current_before;
                        const start_line = self.current;
                        self.recoverToNextConstruct();
                        const error_node = try self.createErrorNode(start_line, self.current);
                        try items.append(self.allocator, .{ .parse_error = error_node });
                        continue;
                    };
                    const used_vertical_syntax = (self.current != current_before);
                    // The block is about to be flattened into a synthetic inline
                    // line; park its prose so the declaration that comes out the
                    // other side can claim it.
                    self.stashProse(result.prose);

                    // If there's nothing after the closing bracket, check if the next line has a construct
                    if (result.remaining.len == 0) {
                        // Look ahead to see if the next line has a Koru construct
                        // For inline syntax, we need to look at the NEXT line (self.current + 1)
                        // For vertical syntax, self.current already points to the line after the ]
                        const next_line_idx = if (used_vertical_syntax) self.current else self.current + 1;
                        const has_construct_on_next_line = if (next_line_idx < self.lines.len) blk: {
                            const next_line = self.lines[next_line_idx];
                            const next_trimmed = lexer.trim(next_line);
                            // A line starting with `~` is a fresh switch into Koru mode,
                            // so it always begins a NEW construct. An annotation line can
                            // never attach forward onto it — the annotation is therefore
                            // module-level, and the `~`-line is parsed as its own item.
                            // (This is what keeps `~[strict]` above `~import` from collapsing
                            // into `~[strict]~import`, which produced a bogus PARSE003.)
                            // Annotations attach forward ONLY to continuation lines that do
                            // not re-enter Koru with `~` — e.g. `~[comptime|norun]` above a
                            // bare `pub event ...` / `proc ...` / `ns:flow(...)` line.
                            if (next_trimmed.len > 0 and next_trimmed[0] == '~') {
                                break :blk false;
                            }
                            // Check for flow call patterns: word.word:event(...) or word(...)
                            // But exclude comments and empty lines
                            if (next_trimmed.len == 0 or std.mem.startsWith(u8, next_trimmed, "//")) {
                                break :blk false;
                            }
                            // Look for identifier patterns (flow calls, event, proc, etc.)
                            // Simple heuristic: starts with letter or contains ( or : or event/proc keywords
                            const looks_like_construct =
                                std.mem.indexOf(u8, next_trimmed, "(") != null or
                                std.mem.indexOf(u8, next_trimmed, ":") != null or
                                std.mem.startsWith(u8, next_trimmed, "pub ") or
                                std.mem.startsWith(u8, next_trimmed, "tor ") or
                                std.mem.startsWith(u8, next_trimmed, "proc ");
                            break :blk looks_like_construct;
                        } else false;

                        if (!has_construct_on_next_line) {
                            // It's a module-level annotation — no declaration to
                            // own the prose.
                            self.clearProse();
                            for (result.annotations) |ann| {
                                try module_annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
                            }
                            for (result.annotations) |ann| {
                                self.allocator.free(ann);
                            }
                            self.allocator.free(result.annotations);

                            // For inline syntax, advance to next line; for vertical, parseAnnotationBlock already did
                            if (!used_vertical_syntax) {
                                self.current += 1;
                            }
                            continue;
                        }

                        // There IS a construct on the next line - treat this as an item-level annotation
                        // The construct is on the next line, so synthesize ~[annotations]construct_text and parse it
                        const construct_line = self.lines[next_line_idx];
                        const construct_trimmed = lexer.trim(construct_line);
                        // Remove the leading ~ from the construct if present (for events/procs)
                        // For flow calls, there might be no ~
                        const construct_content = if (construct_trimmed.len > 0 and construct_trimmed[0] == '~')
                            if (construct_trimmed.len > 1) construct_trimmed[1..] else ""
                        else
                            construct_trimmed;

                        // Conditional import, annotation-block-above-construct
                        // form: the block's entries gate the import exactly as
                        // they would inline (they are the same entry list —
                        // bullets and pipes tokenize identically).
                        if (std.mem.startsWith(u8, construct_content, "import ")) {
                            self.clearProse(); // imports do not carry prose yet
                            const keep = try self.gateImportEntries(result.annotations, construct_content, next_line_idx);
                            for (result.annotations) |ann| {
                                self.allocator.free(ann);
                            }
                            self.allocator.free(result.annotations);
                            if (keep) {
                                // Re-enter the main loop on a plain ~import line.
                                const normalized_line = try std.fmt.allocPrint(self.allocator, "~{s}", .{construct_content});
                                self.lines[next_line_idx] = normalized_line;
                                self.current = next_line_idx;
                            } else {
                                self.current = next_line_idx + 1;
                            }
                            continue;
                        }

                        // Build annotation string: [ann1|ann2|ann3]
                        var ann_str = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                        defer ann_str.deinit(self.allocator);
                        try ann_str.append(self.allocator, '[');
                        for (result.annotations, 0..) |ann, i| {
                            if (i > 0) try ann_str.append(self.allocator, '|');
                            try ann_str.appendSlice(self.allocator, ann);
                        }
                        try ann_str.append(self.allocator, ']');

                        const synthetic_line = try std.fmt.allocPrint(self.allocator, "~{s}{s}", .{ ann_str.items, construct_content });
                        defer self.allocator.free(synthetic_line);

                        // Temporarily replace the next line with the synthetic line
                        const saved_line = self.lines[next_line_idx];
                        self.lines[next_line_idx] = synthetic_line;
                        const saved_current = self.current;
                        self.current = next_line_idx;

                        // Parse the Koru construct
                        const item = self.parseKoruConstruct() catch |err| {
                            self.lines[next_line_idx] = saved_line;
                            // Clean up annotations
                            for (result.annotations) |ann| {
                                self.allocator.free(ann);
                            }
                            self.allocator.free(result.annotations);
                            if (self.fail_fast) {
                                return err;
                            }
                            // Ensure valid range for error node (start <= end)
                            const error_start = @min(saved_current, next_line_idx);
                            const error_end = @max(saved_current, next_line_idx) + 1;
                            const error_node = try self.createErrorNode(error_start, error_end);
                            try items.append(self.allocator, .{ .parse_error = error_node });
                            // Skip past BOTH the annotation line and the failed construct line to avoid infinite loop
                            // Use max in case parseKoruConstruct advanced self.current partway through a multi-line construct
                            self.current = @max(self.current, next_line_idx + 1);
                            continue;
                        };

                        // Clean up annotations
                        for (result.annotations) |ann| {
                            self.allocator.free(ann);
                        }
                        self.allocator.free(result.annotations);

                        // Restore the original line
                        self.lines[next_line_idx] = saved_line;
                        try items.append(self.allocator, item);
                        continue;
                    }

                    // If there IS something after ], it's an item-level construct (event/proc/import).
                    //
                    // For vertical syntax, the construct text comes from result.remaining and we
                    // need to re-attach the annotations as ~[ann1|ann2|...]{construct} so the
                    // recursive parseKoruConstruct call sees them. Naively synthesizing
                    // ~{remaining} (as an earlier version did) silently dropped annotations on
                    // every vertical-block-with-construct-on-bracket-line, breaking 310_008's
                    // verify.sh and 310_040 in ways the compile-only regression runner missed.
                    //
                    // For inline syntax, the construct is on the SAME line as the original
                    // ~[a|b|c]construct, so we just fall through to normal parsing which sees
                    // the annotations directly in the source.
                    if (used_vertical_syntax) {
                        // Conditional import, vertical form with the construct
                        // on the close-bracket line (`]import app/x`): gate on
                        // the block's entries before any synthesis.
                        if (std.mem.startsWith(u8, result.remaining, "import ")) {
                            const line_with_bracket = self.current - 1;
                            self.clearProse(); // imports do not carry prose yet
                            const keep = try self.gateImportEntries(result.annotations, result.remaining, line_with_bracket);
                            for (result.annotations) |ann| {
                                self.allocator.free(ann);
                            }
                            self.allocator.free(result.annotations);
                            if (keep) {
                                // Re-enter the main loop on a plain ~import line.
                                const normalized_line = try std.fmt.allocPrint(self.allocator, "~{s}", .{result.remaining});
                                self.lines[line_with_bracket] = normalized_line;
                                self.current = line_with_bracket;
                            }
                            continue;
                        }

                        // Build annotation string: [ann1|ann2|ann3]
                        var ann_str = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                        defer ann_str.deinit(self.allocator);
                        try ann_str.append(self.allocator, '[');
                        for (result.annotations, 0..) |ann, i| {
                            if (i > 0) try ann_str.append(self.allocator, '|');
                            try ann_str.appendSlice(self.allocator, ann);
                        }
                        try ann_str.append(self.allocator, ']');

                        // Now safe to free the parsed annotations — they're in ann_str
                        for (result.annotations) |ann| {
                            self.allocator.free(ann);
                        }
                        self.allocator.free(result.annotations);

                        // Strip leading ~ from remaining if present (for events/procs); flow
                        // calls won't have one. Then synthesize ~[ann1|ann2|...]construct.
                        const remaining_no_tilde = if (result.remaining.len > 0 and result.remaining[0] == '~')
                            (if (result.remaining.len > 1) result.remaining[1..] else "")
                        else
                            result.remaining;

                        const synthetic_line = try std.fmt.allocPrint(
                            self.allocator,
                            "~{s}{s}",
                            .{ ann_str.items, remaining_no_tilde },
                        );
                        defer self.allocator.free(synthetic_line);

                        // Temporarily replace the line BEFORE current (which has the ]) with the synthetic line
                        const line_with_bracket = self.current - 1;
                        const saved_line = self.lines[line_with_bracket];
                        self.lines[line_with_bracket] = synthetic_line;
                        const saved_current = self.current;
                        self.current = line_with_bracket;

                        // Parse the Koru construct
                        const item = self.parseKoruConstruct() catch |err| {
                            self.lines[line_with_bracket] = saved_line;
                            self.current = saved_current;
                            if (self.fail_fast) {
                                return err;
                            }
                            const error_node = try self.createErrorNode(line_with_bracket, saved_current);
                            try items.append(self.allocator, .{ .parse_error = error_node });
                            continue;
                        };

                        // Restore the original line, but DON'T restore self.current!
                        // parseKoruConstruct advanced past the event and its branches, and we want to keep that
                        self.lines[line_with_bracket] = saved_line;
                        try items.append(self.allocator, item);
                        continue;
                    } else {
                        // Inline: the construct is on the same line, so fall through to normal
                        // parsing which sees the original ~[a|b|c]construct text. Free the
                        // duplicate annotations parsed by parseAnnotationBlock — the normal path
                        // will re-parse them from the source line.
                        for (result.annotations) |ann| {
                            self.allocator.free(ann);
                        }
                        self.allocator.free(result.annotations);
                    }
                }

                // Conditional imports, inline form: ~[entries]import — entries
                // evaluate through the shared annotation-entry vocabulary
                // (comptime_eval + provider chain), replacing the old
                // string-equality flag match whose only failure mode was
                // SILENT drop. Delimiting is findBlockClose (nesting- and
                // string-aware), so entries containing `]` never confuse the
                // gate.
                if (std.mem.startsWith(u8, after_tilde, "[")) {
                    if (annotation_parser.findBlockClose(after_tilde[1..])) |close_idx| {
                        const after_close = lexer.trim(after_tilde[1 + close_idx + 1 ..]);
                        if (std.mem.startsWith(u8, after_close, "import ")) {
                            const ann_str = after_tilde[1 .. 1 + close_idx];
                            try self.rejectInvalidAnnotationSeparator(ann_str, self.current);
                            const entries = try annotation_parser.splitEntries(self.allocator, ann_str);
                            defer self.allocator.free(entries);

                            const keep = try self.gateImportEntries(entries, after_close, self.current);
                            if (!keep) {
                                self.current += 1;
                                continue;
                            }

                            // Kept — normalize "~[entries]import ..." to "~import ..."
                            const normalized_line = try std.fmt.allocPrint(self.allocator, "~{s}", .{after_close});
                            self.lines[self.current] = normalized_line;
                        }
                    }
                }

                // Otherwise, it's an item-level construct
                const start_line = self.current;
                const item = self.parseKoruConstruct() catch |err| {
                    // Always propagate fatal module errors (even in lenient mode)
                    if (err == error.UnknownImportAlias or err == error.ModuleNotFound) {
                        return err;
                    }
                    if (self.fail_fast) {
                        return err;
                    }
                    // Lenient mode: reset position and skip to next construct
                    // (parseKoruConstruct may have advanced self.current past EOF while looking for closing braces)
                    self.current = start_line;
                    self.recoverToNextConstruct();
                    const error_node = try self.createErrorNode(start_line, self.current);
                    try items.append(self.allocator, .{ .parse_error = error_node });
                    continue;
                };
                try items.append(self.allocator, item);
            } else if (lexer.startsWith(line, "|")) {
                try self.reporter.addError(
                    .KORU010,
                    self.current + 1,
                    lexer.getIndent(line) + 1,
                    "stray continuation line without Koru construct",
                    .{},
                );
                self.current += 1;
            } else {
                // Host-embedded `.k*` files: Koru module constructs require `~`.
                // Pure `.k` synthesizes it above; this catches bare Koru keywords
                // (import, event, proc, …) that skipped the switch — no import-only
                // special case.
                if (!self.is_k and looksLikeBareKoruModuleConstruct(trimmed)) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        lexer.getIndent(line) + 1,
                        "Koru constructs in host-embedded files (`.kz`, `.kjs`, etc.) must start with `~` — the host→Koru switch",
                        .{},
                    );
                    return error.ParseError;
                }
                // Pass through host language line
                const owned_line = try self.allocator.dupe(u8, line);
                try items.append(self.allocator, .{ .host_line = .{
                    .content = owned_line,
                    .location = self.getCurrentLocation(),
                    .module = try self.allocator.dupe(u8, self.module_name),
                } });
                self.current += 1;
            }
        }

        // KEBAB-CANONICAL: no parse-boundary normalization. Names stay
        // byte-for-byte as written through the whole pipeline; kebab -> snake
        // happens ONLY at emitter identifier-formation (writeBranchName and
        // friends). Quoted branch names (`…`/[…]) are just source encoding for
        // names — a name is a name; the pipeline never rewrites one.

        self.registry_transferred = true;
        return ParseResult{
            .source_file = ast.Program{
                .items = try items.toOwnedSlice(self.allocator),
                .module_annotations = try module_annotations.toOwnedSlice(self.allocator),
                .main_module_name = try self.allocator.dupe(u8, self.module_name),
                .allocator = self.allocator,
            },
            .registry = self.registry,
        };
    }

    const AnnotationBlockResult = struct {
        annotations: [][]const u8, // Owned slice, caller must free individual strings and the slice
        /// Content after the closing ] (for inline syntax)
        /// For vertical syntax, this is always empty since ] is on its own line or line ending
        remaining: []const u8,
        /// The block's non-bullet lines — rationale addressed to the reader —
        /// trimmed and newline-joined. Owned by the caller when non-empty; always
        /// empty for inline blocks, which have no line to hold prose on.
        prose: []const u8 = "",
    };

    /// Hand a vertical block's prose to whichever declaration the block attaches
    /// to.
    ///
    /// An EMPTY prose never clears the stash, and that is load-bearing rather
    /// than sloppy: a vertical block is flattened into a synthetic
    /// `~[a|b]construct` line and fed back through the dispatcher, so the same
    /// block gets scanned a second time — inline, where prose cannot exist. If
    /// that second pass cleared the stash, no vertical block would ever reach
    /// its declaration. Blocks that end up owning no declaration clear it
    /// explicitly instead (`clearProse`).
    fn stashProse(self: *Parser, prose: []const u8) void {
        if (prose.len == 0) return;
        if (self.pending_prose.len > 0) self.allocator.free(self.pending_prose);
        self.pending_prose = prose;
    }

    /// Drop prose that turned out to have no declaration to attach to — a
    /// module-level annotation, a gated-out import, a block whose construct
    /// failed to parse. Without this the orphan would ride forward onto the next
    /// declaration built, which is worse than losing it.
    fn clearProse(self: *Parser) void {
        if (self.pending_prose.len > 0) self.allocator.free(self.pending_prose);
        self.pending_prose = "";
    }

    /// Take the stashed prose, transferring ownership to the caller. Empty when
    /// the declaration carried an inline block or none at all.
    fn takePendingProse(self: *Parser) []const u8 {
        const prose = self.pending_prose;
        self.pending_prose = "";
        return prose;
    }

    /// Markdown bullet markers — '-', '*', '+' all valid in a vertical
    /// annotation block. Each bullet line is one flag; non-bullet lines are
    /// prose, silently discarded.
    fn isBulletMarker(c: u8) bool {
        return c == '-' or c == '*' or c == '+';
    }

    /// PARSE007 — refuse a `,` where annotations delimit on `|`.
    ///
    /// `~[default, depends_on(x)]` is not two annotations; it is one entry
    /// spelled `"default, depends_on(x)"` that matches nothing, so the block
    /// silently means less than it reads. That shape shipped in the stdlib's own
    /// default build steps and dropped a real dependency, which is the whole
    /// argument for failing loud here: the cost of the silence was two defects
    /// hidden for as long as they existed.
    ///
    /// `content` is the text BETWEEN the block's brackets. Every caller derives
    /// it by slicing `self.lines[line_idx]`, so the offending column is
    /// recoverable by offset — but some lines are synthesized (a vertical block
    /// is re-fed as `~[a|b]construct`), and a synthetic slice is not a subslice
    /// of the line it is reported against. The containment check is what keeps a
    /// caret from pointing at a column that does not exist; column 0 when it
    /// cannot be derived is honest, a fabricated offset is not.
    fn rejectInvalidAnnotationSeparator(self: *Parser, content: []const u8, line_idx: usize) !void {
        const bad = annotation_parser.findInvalidSeparator(content) orelse return;

        var column: usize = 0;
        if (line_idx < self.lines.len) {
            const line = self.lines[line_idx];
            const line_base = @intFromPtr(line.ptr);
            const content_base = @intFromPtr(content.ptr);
            if (content_base >= line_base and content_base + content.len <= line_base + line.len) {
                column = (content_base - line_base) + bad;
            }
        }

        const suggestion = try annotation_parser.suggestPipeSeparators(self.allocator, content);
        defer self.allocator.free(suggestion);

        try self.reporter.addErrorWithHint(
            .PARSE007,
            line_idx + 1,
            column,
            "invalid annotation separator ',' in '[{s}]' — annotations separate on '|'",
            .{content},
            "write '[{s}]'; a comma inside a call's argument list (depends_on(a, b)) is a different thing and stays legal",
            .{suggestion},
        );
        return error.InvalidAnnotationSeparator;
    }

    /// Parse annotation block supporting both inline and vertical syntax:
    /// - Inline: [a|b|c] on same line
    /// - Vertical: [\n-a\n-b\n-c\n] across multiple lines
    /// Returns annotations and content after ] (caller owns annotations)
    /// `opening_line_idx` is the ZERO-based index of the line the `~[` sits on —
    /// the same basis as `self.current`, which is what every caller derives it
    /// from. It becomes a 1-based line only at the reporter, like everywhere
    /// else in this file.
    fn parseAnnotationBlock(self: *Parser, content_with_bracket: []const u8, opening_line_idx: usize) !AnnotationBlockResult {
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (annotations.items) |ann| {
                self.allocator.free(ann);
            }
            annotations.deinit(self.allocator);
        }

        // Rationale prose accrues here as the block is scanned. Lines land
        // trimmed, so the canonical printer can re-indent them and a reparse
        // yields this exact buffer — that is what keeps the vertical form
        // round-trippable.
        var prose_buf = std.ArrayList(u8){};
        errdefer prose_buf.deinit(self.allocator);

        // Check if the block's closing ] is on the same line (inline syntax).
        // Nesting- and string-aware: entries like custom(foo[1]) or doc("a]b")
        // never close the block early, and pipes inside them never delimit.
        if (annotation_parser.findBlockClose(content_with_bracket[1..])) |rel_close| {
            // Inline syntax: [a|b|c]
            const close_bracket = rel_close + 1;
            const ann_str = content_with_bracket[1..close_bracket];
            try self.rejectInvalidAnnotationSeparator(ann_str, opening_line_idx);
            const entries = try annotation_parser.splitEntries(self.allocator, ann_str);
            defer self.allocator.free(entries);
            for (entries) |entry| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, entry));
            }
            const remaining = content_with_bracket[close_bracket + 1 ..];
            prose_buf.deinit(self.allocator); // inline blocks are one line: no room for prose
            return AnnotationBlockResult{
                .annotations = try annotations.toOwnedSlice(self.allocator),
                .remaining = remaining,
            };
        }

        // Vertical syntax: [\n-a\n-b\n]
        // The opening [ is at end of current line, advance to next line
        self.current += 1;

        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            // Skip empty lines and comments
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
                self.current += 1;
                continue;
            }

            // Check if this line contains the block's closing ] — nesting- and
            // string-aware, so a bullet like `- custom(foo[1])` or prose
            // mentioning `tests[3]` never closes the block early.
            if (annotation_parser.findBlockClose(trimmed)) |bracket_idx| {
                // Found closing bracket
                // Check if there's a bullet annotation on this line before the ]
                if (trimmed.len > 0 and isBulletMarker(trimmed[0])) {
                    const bullet_content = lexer.trim(trimmed[1..bracket_idx]); // Skip the - and content after ]
                    if (bullet_content.len > 0) {
                        try self.rejectInvalidAnnotationSeparator(bullet_content, self.current);
                        const entries = try annotation_parser.splitEntries(self.allocator, bullet_content);
                        defer self.allocator.free(entries);
                        for (entries) |entry| {
                            try annotations.append(self.allocator, try self.allocator.dupe(u8, entry));
                        }
                    }
                }
                const remaining = lexer.trim(trimmed[bracket_idx + 1 ..]); // Content after ]
                self.current += 1;
                return AnnotationBlockResult{
                    .annotations = try annotations.toOwnedSlice(self.allocator),
                    .remaining = remaining,
                    .prose = try prose_buf.toOwnedSlice(self.allocator),
                };
            }

            // Check if line starts with a markdown bullet marker (-, *, +)
            // — this is a flag entry. Anything else on its own line is prose,
            // captured onto the declaration as rationale. The annotation block is
            // a markdown buffer where bullets are canonical flags and prose is
            // human rationale. Discipline (why-not-what, no double-definitions)
            // is held in docs, not enforced by the parser.
            // Bullet content splits through the same tokenizer as inline
            // entries, so vertical and inline blocks produce identical lists.
            if (trimmed.len > 1 and isBulletMarker(trimmed[0]) and (trimmed[1] == ' ' or trimmed[1] == '\t')) {
                const bullet_content = lexer.trim(trimmed[1..]); // Skip the bullet marker
                if (bullet_content.len > 0) {
                    try self.rejectInvalidAnnotationSeparator(bullet_content, self.current);
                    const entries = try annotation_parser.splitEntries(self.allocator, bullet_content);
                    defer self.allocator.free(entries);
                    for (entries) |entry| {
                        try annotations.append(self.allocator, try self.allocator.dupe(u8, entry));
                    }
                }
                self.current += 1;
                continue;
            }

            // Prose line — the reader's half of the block. Stored trimmed and
            // newline-joined; the frontend never reads it, consumers do.
            if (prose_buf.items.len > 0) try prose_buf.append(self.allocator, '\n');
            try prose_buf.appendSlice(self.allocator, trimmed);
            self.current += 1;
            continue;
        }

        // Ran out of lines without finding ]. Blame the line that OPENED the
        // block — the scan ended at EOF, which is nowhere the author can act on.
        try self.reporter.addError(.PARSE003, opening_line_idx + 1, 1, "unclosed annotation bracket", .{});
        return error.ParseError;
    }

    /// True when `trimmed` begins a Koru module-level construct. Host-embedded
    /// files must prefix these with `~`; pure `.k` synthesizes `~` before parse.
    fn looksLikeBareKoruModuleConstruct(trimmed: []const u8) bool {
        const prefixes = [_][]const u8{
            "import ",
            "pub tor",
            "tor ",
            "proc ",
            "pub proc ",
        };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, trimmed, prefix)) return true;
        }
        return false;
    }

    fn gateEnvMap(self: *Parser) ?*const std.process.EnvMap {
        if (self.gate_env_map == null) {
            self.gate_env_map = std.process.getEnvMap(self.allocator) catch null;
        }
        return if (self.gate_env_map) |*m| m else null;
    }

    fn activeCommand(self: *const Parser) ?[]const u8 {
        for (self.compiler_flags) |f| {
            if (std.mem.startsWith(u8, f, "command=")) return f["command=".len..];
        }
        return null;
    }

    /// The import gate — the first consumer of the annotation-entry
    /// vocabulary, and the one that IS the core language: it runs at parse
    /// time and decides what the AST contains. Its contract is therefore the
    /// strictest: every entry MUST evaluate (loud KORU150 otherwise — the
    /// same annotation that is legally inert on an event is an error on an
    /// import, because an inert entry here is silent gating). ANY truthy
    /// entry keeps the import; an excluded import gets a loud resolution
    /// report with each entry's verdict and provenance.
    fn gateImportEntries(self: *Parser, entries: []const []const u8, import_text: []const u8, report_line: usize) !bool {
        const provider = comptime_eval.Provider{
            .flags = self.compiler_flags,
            .env_map = self.gateEnvMap(),
            .command = self.activeCommand(),
        };
        var any_true = false;
        var report = try std.ArrayList(u8).initCapacity(self.allocator, 128);
        defer report.deinit(self.allocator);
        const w = report.writer(self.allocator);
        for (entries) |entry| {
            var diag: []const u8 = "";
            const res = comptime_eval.evalAnnotationEntryDiag(self.allocator, &provider, entry, &diag) catch {
                try self.reporter.addError(
                    .KORU150,
                    report_line + 1,
                    1,
                    "conditional import: the gate cannot evaluate entry `{s}` ({s}). Entries deciding AST membership must evaluate — the vocabulary is bare flag atoms, comparisons, and/or/not, and cflag()/env()/command()",
                    .{ entry, diag },
                );
                return error.ParseError;
            };
            if (res.truthy) any_true = true;
            w.print("  `{s}` -> {s}", .{ entry, if (res.truthy) "true" else "false" }) catch return error.OutOfMemory;
            for (res.trace) |t| w.print("  [{s}]", .{t}) catch return error.OutOfMemory;
            w.print("\n", .{}) catch return error.OutOfMemory;
        }
        if (!any_true) {
            std.debug.print("[import gate] {s}:{d}: `{s}` excluded — no entry true\n{s}", .{ self.module_name, report_line + 1, import_text, report.items });
        }
        return any_true;
    }

    fn parseKoruConstruct(self: *Parser) !ast.Item {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file in parseKoruConstruct",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);

        // Remove the ~ prefix
        const after_tilde = lexer.trim(trimmed[1..]);

        // Check for annotations first: ~[annotation]construct
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer {
            for (annotations.items) |ann| {
                self.allocator.free(ann);
            }
            annotations.deinit(self.allocator);
        }

        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            // Parse annotation block (supports both inline ~[a|b] and vertical ~[\n-a\n-b\n])
            const result = try self.parseAnnotationBlock(after_tilde, self.current);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            self.stashProse(result.prose);

            for (result.annotations) |ann| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
            }

            remaining = lexer.trim(result.remaining);
        }

        // Now check for constructs
        if (lexer.startsWith(remaining, "pub tor")) {
            // Public event declaration with annotations
            return .{ .event_decl = try self.parseEventDeclWithAnnotations(true, annotations.items) };
        } else if (lexer.startsWith(remaining, "import ")) {
            // Note: Conditional imports (~[flag]import) are already filtered out
            // at a higher level in parse(), so if we reach here the import is allowed
            return .{ .import_decl = try self.parseImportDecl() };
        } else if (lexer.startsWith(remaining, "pub event ") or lexer.startsWith(remaining, "event ")) {
            // `event` is not a Koru keyword. Declarations are introduced with `tor`.
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                1,
                "'event' is not a Koru keyword - a declaration is introduced with 'tor' (e.g. 'tor jump {{ how-high: i32 }}')",
                .{},
            );
            return error.ParseError;
        } else if (lexer.startsWith(remaining, "tor ")) {
            // Private event declaration with annotations
            return .{ .event_decl = try self.parseEventDeclWithAnnotations(false, annotations.items) };
        } else if (lexer.startsWith(remaining, "pub proc ") or lexer.startsWith(remaining, "pub ~proc")) {
            // pub proc is not valid - only events can be public
            // Also catch "pub ~proc" variant
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                1,
                "'pub' is not valid on proc declarations - only events can be public",
                .{},
            );
            return error.ParseError;
        } else if (lexer.startsWith(remaining, "proc ")) {
            return .{ .proc_decl = try self.parseProcDeclWithAnnotations(annotations.items) };
        } else if (lexer.startsWith(after_tilde, "#")) {
            // New label anchor syntax or pre-invocation label
            return try self.parseLabelAnchor();
        } else if (lexer.startsWith(after_tilde, "@")) {
            // Old syntax - we'll deprecate this for standalone labels
            return .{ .label_decl = try self.parseLabelDecl() };
        } else if (hasSourceBlock(remaining)) {
            // Source block detected: ~event { ... } or ~event(args) { ... }
            // Source blocks are opaque - route to flow parsing BEFORE checking for =
            // This prevents `{ a = b }` from being misinterpreted as subflow impl
            const directive_line = self.current + 1;
            const flow = try self.parseFlow(annotations.items);
            // A `std/compiler:paths` block has to act HERE, mid-descent: parse and
            // resolve are one pass (parseImportDecl resolves inline), so an alias
            // declared for a later import must land before that import is read.
            // Unlike flag.declare, this cannot wait for a post-parse harvest.
            try self.applyPathsDirective(&flow, directive_line);
            return .{ .flow = flow };
        } else if (findTopLevelEquals(remaining) != null) {
            // Event implementation via subflow: ~event.name = ...
            // NOTE: This only matches = outside of source blocks (checked above)
            return try self.parseSubflowImpl(annotations.items);
        } else if (isBareReturnImpl(remaining)) {
            // `~event -> expr` : bare-return impl (the `->` twin of `=>`).
            return try self.parseSubflowImpl(annotations.items);
        } else if (std.mem.indexOfScalar(u8, remaining, '(') != null) {
            // It's an invocation with args
            return .{ .flow = try self.parseFlow(annotations.items) };
        } else {
            // Flow invocation without args
            return .{ .flow = try self.parseFlow(annotations.items) };
        }
    }

    fn parseEventInputShape(self: *Parser, event_line: []const u8, event_line_index: usize) !ast.Shape {
        const trimmed_line = lexer.trim(event_line);

        if (std.mem.indexOf(u8, trimmed_line, "{")) |brace_start| {
            return self.parseEventInputShapeFromLine(trimmed_line, brace_start);
        }

        return self.parseEventInputShapeFromFollowingLines(event_line_index);
    }

    fn parseEventInputShapeFromLine(self: *Parser, line: []const u8, brace_start: usize) !ast.Shape {
        const close_offset = blk: {
            var depth: i32 = 0;
            var i = brace_start;
            while (i < line.len) : (i += 1) {
                if (line[i] == '{') {
                    depth += 1;
                } else if (line[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        break :blk i - brace_start;
                    }
                }
            }
            break :blk null;
        };

        if (close_offset) |off| {
            const content = lexer.trim(line[brace_start + 1 .. brace_start + off]);
            return self.parseShape(content);
        }

        var shape_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer shape_content.deinit(self.allocator);

        const first_line_content = lexer.trim(line[brace_start + 1 ..]);
        if (first_line_content.len > 0) {
            try shape_content.appendSlice(self.allocator, first_line_content);
            try shape_content.append(self.allocator, ',');
        }

        var brace_depth: i32 = 1;
        const start_line = self.current;

        while (self.current < self.lines.len and brace_depth > 0) {
            const current_line = self.lines[self.current];
            self.current += 1;

            const trimmed = lexer.trim(current_line);
            if (trimmed.len == 0) continue;

            // Track braces properly, skipping those in strings/comments
            var in_string = false;
            var string_char: ?u8 = null;
            var closing_brace_idx: ?usize = null;

            for (trimmed, 0..) |c, idx| {
                // Skip line comments
                if (!in_string and c == '/' and idx + 1 < trimmed.len and trimmed[idx + 1] == '/') {
                    break;
                }

                // Handle string literals
                if (!in_string and (c == '"' or c == '\'')) {
                    in_string = true;
                    string_char = c;
                } else if (in_string) {
                    if (c == '\\' and idx + 1 < trimmed.len) {
                        continue; // Escaped char handled by next iteration
                    } else if (c == string_char) {
                        in_string = false;
                        string_char = null;
                    }
                } else {
                    // Not in string or comment - count braces
                    if (c == '{') brace_depth += 1;
                    if (c == '}') {
                        brace_depth -= 1;
                        if (brace_depth == 0) {
                            closing_brace_idx = idx;
                            break;
                        }
                    }
                }
            }

            if (closing_brace_idx) |end_idx| {
                const final_content = lexer.trim(trimmed[0..end_idx]);
                if (final_content.len > 0) {
                    try shape_content.appendSlice(self.allocator, final_content);
                }
                // Text AFTER the closing `}` (a bare-return `-> T` suffix on
                // the close line) is the DECL's business, not the shape's —
                // stash it for parseEventDeclWithAnnotations. Dropping it
                // here silently ate `} -> SiteResult` return types.
                if (end_idx + 1 < trimmed.len) {
                    const tail = lexer.trim(trimmed[end_idx + 1 ..]);
                    if (tail.len > 0) {
                        self.multiline_shape_tail = tail;
                        // `self.current` was advanced past this line at the top
                        // of the loop, so it already IS the 1-based close line.
                        self.multiline_shape_tail_line = self.current;
                    }
                }
            } else if (brace_depth > 0) {
                try shape_content.appendSlice(self.allocator, trimmed);
                try shape_content.append(self.allocator, ',');
            }
        }

        if (brace_depth != 0) {
            try self.reporter.addError(
                .PARSE004,
                start_line,
                @intCast(brace_start + 1), // Convert to 1-based column
                "unmatched '{{' in tor shape",
                .{},
            );
            return error.ParseError;
        }

        return self.parseShape(shape_content.items);
    }

    fn parseEventInputShapeFromFollowingLines(self: *Parser, event_line_index: usize) !ast.Shape {
        const error_line = event_line_index + 1; // convert to 1-based for reporting
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
                self.current += 1;
                continue;
            }

            if (lexer.isBranchContinuation(line)) {
                try self.reporter.addError(
                    .PARSE003,
                    error_line,
                    1,
                    "tor declaration missing input shape",
                    .{},
                );
                return error.ParseError;
            }

            if (std.mem.indexOf(u8, trimmed, "{")) |brace_start| {
                self.current += 1;
                return self.parseEventInputShapeFromLine(trimmed, brace_start);
            }

            try self.reporter.addError(
                .PARSE003,
                error_line,
                1,
                "tor declaration missing input shape",
                .{},
            );
            return error.ParseError;
        }

        try self.reporter.addError(
            .PARSE003,
            error_line,
            1,
            "tor declaration missing input shape",
            .{},
        );
        return error.ParseError;
    }

    /// A `|target` variant tag belongs on a `~proc`, never on the `~tor` that
    /// declares the contract: the tor names WHAT is done, the proc's variant
    /// names HOW and for which target. Without this wall `|` is not an
    /// identifier terminator, so `~tor compute|zig {}` mints a declaration
    /// literally named `compute|zig` that no `~proc compute|zig` and no
    /// `~compute()` call site can ever match — three spellings of one
    /// construct, and a frontend with nothing left to disagree with.
    ///
    /// Scoped to `~tor` on purpose. A proc's variant is split off before its
    /// name is validated, and a same-line branch (`~tor ping | ok`) is
    /// whitespace-separated, so neither reaches this check.
    fn rejectVariantTagOnTor(self: *Parser, raw: []const u8, line_index: usize) !void {
        var end: usize = 0;
        while (end < raw.len) : (end += 1) {
            const c = raw[end];
            if (c == '[' or c == '<' or c == '(' or c == '{' or c == ' ' or c == '\t') break;
        }
        const name_part = raw[0..end];
        const bar = std.mem.indexOfScalar(u8, name_part, '|') orelse return;
        try self.reporter.addErrorWithHint(
            .PARSE003,
            line_index + 1,
            1,
            "'{s}' is a variant tag and has no meaning on a '~tor' — a tor declares WHAT is done, and only a '~proc' carries the '|target' that says how",
            .{name_part[bar..]},
            "declare '~tor {s}' and put the variant on its implementation: '~proc {s} {{ ... }}'",
            .{ name_part[0..bar], name_part },
        );
        return error.ParseError;
    }

    /// Reject `_` in a Koru NAME. Kebab `-` is the sole word separator for Koru
    /// names; `_` is reserved for digit separators in numeric literals (rule G4).
    /// We won't accept both spellings — a snake name must fail loudly. The check
    /// is on the BARE name only (it stops at a generic `[`, phantom `<`, paren,
    /// brace, or whitespace) so type params and phantom states are unaffected.
    /// Runs on the RAW source name, before kebab→snake normalization.
    fn rejectSnakeName(self: *Parser, raw: []const u8, line_index: usize, kind: []const u8) !void {
        var end: usize = 0;
        while (end < raw.len) : (end += 1) {
            const c = raw[end];
            if (c == '[' or c == '<' or c == '(' or c == '{' or c == ' ' or c == '\t') break;
        }
        const name_part = raw[0..end];
        // Leading-underscore names (`__compiler_marker`, `_internal`) are the
        // reserved compiler-internal convention — kebab cannot express them
        // (a name can't start with `-`), so they are exempt from the rule.
        if (name_part.len > 0 and name_part[0] == '_') return;
        if (std.mem.indexOfScalar(u8, name_part, '_') != null) {
            try self.reporter.addError(
                .KORU034,
                line_index + 1,
                1,
                "'_' is not allowed in a Koru {s} name '{s}' — use '-' for word separation ('_' is reserved for digit separators)",
                .{ kind, name_part },
            );
            return error.ParseError;
        }
    }

    /// Reject `.` used as a NAMESPACE separator. `/` is the sole namespace
    /// separator (matching the import string + filesystem); `.` is member access
    /// AFTER the `:` pivot. So a `.` in the module-qualifier (the part before the
    /// top-level `:`) is the old dot-namespace form and must fail loudly. Member
    /// dots after `:` (`std/io:print.ln`) and qualifier-less local paths
    /// (`read.ln`) are unaffected.
    fn rejectDotNamespace(self: *Parser, raw: []const u8, line_index: usize) !void {
        // The namespace qualifier is the part before the qualifier `:`, which
        // always precedes the call's opening `(` (args) or `{` (source block).
        // A `:` AFTER `(`/`{` is an arg key or source-block field — never a
        // qualifier — and its preceding text may legitimately contain `.`
        // (e.g. `fail { r.score, reason: .. }`). Restrict the scan to the head.
        const limit = std.mem.indexOfAny(u8, raw, "({") orelse raw.len;
        const head = raw[0..limit];
        const colon = lexer.findModuleQualifierColon(head) orelse return; // no qualifier
        const qualifier = head[0..colon];
        if (std.mem.indexOfScalar(u8, qualifier, '.') != null) {
            try self.reporter.addError(
                .KORU035,
                line_index + 1,
                1,
                "'.' is not a namespace separator in '{s}' — use '/' (e.g. 'std/io:...', not 'std.io:...'). '.' is member access after ':'.",
                .{qualifier},
            );
            return error.ParseError;
        }
    }

    fn parseEventDeclWithAnnotations(self: *Parser, is_public: bool, annotations: [][]const u8) !ast.EventDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing tor declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const line = self.lines[self.current];
        self.current += 1;
        const event_line_index = self.current - 1;

        // Parse: ~[annotations]pub event <path> { <fields> } or ~[annotations]event <path> { <fields> }
        const trimmed = lexer.trim(line);
        const after_tilde = lexer.trim(trimmed[1..]); // Skip ~

        // Skip past annotations if present (both inline and vertical syntax)
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            const result = try self.parseAnnotationBlock(after_tilde, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            // We don't need the annotations, just skip past them — but this
            // re-scan is the only place the prose survives when the block was
            // written directly above the construct, so it is stashed here.
            self.stashProse(result.prose);
            remaining = lexer.trim(result.remaining);
        }

        // Strip the tor keyword (with optional pub prefix)
        const after_event = if (lexer.afterPrefix(remaining, "pub tor")) |ae|
            ae
        else if (lexer.afterPrefix(remaining, "tor")) |ae|
            ae
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "malformed tor declaration",
                .{},
            );
            return error.ParseError;
        };

        // Split a top-level `-> T` return suffix off the decl line BEFORE path /
        // shape / same-line-branch parsing, so none of them see the return arrow.
        const trimmed_after_event_raw = lexer.trim(after_event);
        const return_split = try splitTrailingReturnArrow(self, trimmed_after_event_raw, event_line_index + 1);
        var return_type = return_split.return_type;
        var return_phantom = return_split.return_phantom;
        errdefer {
            if (return_type) |rt| self.allocator.free(rt);
            if (return_phantom) |rp| self.allocator.free(rp);
        }
        const trimmed_after_event = return_split.head;
        const brace_idx_opt = std.mem.indexOf(u8, trimmed_after_event, "{");
        const parsed_path_str = if (brace_idx_opt) |idx|
            lexer.trim(trimmed_after_event[0..idx])
        else
            trimmed_after_event;

        if (parsed_path_str.len == 0) {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "tor declaration missing name",
                .{},
            );
            return error.ParseError;
        }

        try self.rejectVariantTagOnTor(parsed_path_str, event_line_index);
        try self.rejectSnakeName(parsed_path_str, event_line_index, "tor");
        var path = try lexer.parseQualifiedPath(self.allocator, parsed_path_str, ast);
        errdefer path.deinit(self.allocator);
        log_debug("PARSER parseEventDeclWithAnnotations: Just parsed event path: module={s} segments=", .{if (path.module_qualifier) |m| m else "null"});
        for (path.segments) |s| log_debug("{s}.", .{s});
        log_debug("\n", .{});

        const shape_source = if (brace_idx_opt) |idx|
            trimmed_after_event[idx..]
        else
            "";
        var input = try self.parseEventInputShape(shape_source, event_line_index);
        errdefer input.deinit(self.allocator);

        // A MULTI-LINE shape's closing line may carry the bare-return suffix
        // (`} -> SiteResult`); the shape parser stashes it. Anything else
        // after the close is a loud error — the pre-fix behavior silently
        // dropped it, which ate return types without a trace.
        if (self.multiline_shape_tail) |tail| {
            self.multiline_shape_tail = null;
            const tail_line = self.multiline_shape_tail_line;
            self.multiline_shape_tail_line = 0;
            if (return_type == null and std.mem.startsWith(u8, tail, "->")) {
                const tail_split = try splitTrailingReturnArrow(self, tail, tail_line);
                return_type = tail_split.return_type;
                return_phantom = tail_split.return_phantom;
            } else {
                try self.reporter.addError(
                    .PARSE003,
                    tail_line,
                    1,
                    "unexpected content after the closing '}}' of a multi-line tor shape: '{s}' (only a bare return `-> T` may follow)",
                    .{tail},
                );
                return error.ParseError;
            }
        }

        // Parse branches (both same-line and continuation lines)
        var branches = try std.ArrayList(ast.Branch).initCapacity(self.allocator, 8);
        errdefer {
            for (branches.items) |*branch| {
                branch.deinit(self.allocator);
            }
            branches.deinit(self.allocator);
        }

        // Check for trailing annotations on the event (e.g., ~event foo() [annotation])
        // These can be on the same line as the closing brace of the input shape
        var trailing_annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            for (trailing_annotations.items) |ann| self.allocator.free(ann);
            trailing_annotations.deinit(self.allocator);
        }

        // First, check same-line branches and trailing annotations
        if (brace_idx_opt) |brace_idx| {
            // Find where the input shape ends in trimmed_after_event
            const shape_end_opt = blk: {
                var depth: i32 = 0;
                var i = brace_idx;
                while (i < trimmed_after_event.len) : (i += 1) {
                    if (trimmed_after_event[i] == '{') {
                        depth += 1;
                    } else if (trimmed_after_event[i] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            break :blk i + 1;
                        }
                    }
                }
                break :blk null;
            };

            if (shape_end_opt) |shape_end| {
                var branch_content = lexer.trim(trimmed_after_event[shape_end..]);

                // Check for trailing annotations before branches
                if (lexer.startsWith(branch_content, "[")) {
                    // Find the matching closing bracket of the annotation block
                    const close_bracket_idx = blk: {
                        var depth: i32 = 0;
                        var i: usize = 0;
                        while (i < branch_content.len) : (i += 1) {
                            if (branch_content[i] == '[') {
                                depth += 1;
                            } else if (branch_content[i] == ']') {
                                depth -= 1;
                                if (depth == 0) {
                                    break :blk i;
                                }
                            }
                        }
                        break :blk null;
                    } orelse {
                        try self.reporter.addError(
                            .PARSE003,
                            event_line_index + 1,
                            @intCast(shape_end + 1), // Column where the annotation block starts
                            "tor annotation missing closing ']'",
                            .{},
                        );
                        return error.ParseError;
                    };

                    const annotation_content = lexer.trim(branch_content[1..close_bracket_idx]);
                    var iter = std.mem.splitScalar(u8, annotation_content, '|');
                    while (iter.next()) |ann| {
                        const trimmed_ann = lexer.trim(ann);
                        if (trimmed_ann.len > 0) {
                            try trailing_annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                        }
                    }
                    branch_content = lexer.trim(branch_content[close_bracket_idx + 1 ..]);
                }

                // Parse all branches on this line (separated by |)
                while (branch_content.len > 0 and branch_content[0] == '|') {
                    // Skip the | separator
                    branch_content = lexer.trim(branch_content[1..]);
                    if (branch_content.len == 0) break;

                    // Deferred branch decl (`| &<branch>`) — REMOVED (retired
                    // 2026-07-15, frag-deferred-deref-repudiated). Rejected loudly
                    // so the old form fails at compile time; the AST variant and
                    // `is_deferred` flag are gone.
                    if (lexer.startsWith(branch_content, "&")) {
                        try self.reporter.addError(
                            .PARSE003,
                            event_line_index + 1,
                            1,
                            "deferred branch `| &<branch>` was removed — the deferred/deref mechanism is retired. Declare the call site with a required effect-branch instead.",
                            .{},
                        );
                        return error.ParseError;
                    }

                    // Check for ?! prefix (panic branch) before ? (optional).
                    // `?!` is ONE marker: omit handler => synthesized @panic(...)
                    // (UNSAFE to ignore). Not `?` (optional) + `!` (effect).
                    var is_panic = false;
                    var is_optional = false;
                    if (lexer.startsWith(branch_content, "?!")) {
                        is_panic = true;
                        branch_content = lexer.trim(branch_content[2..]);
                    } else if (lexer.startsWith(branch_content, "?")) {
                        is_optional = true;
                        branch_content = lexer.trim(branch_content[1..]);
                    }

                    // Find branch name (everything before {)
                    const branch_brace_idx = std.mem.indexOf(u8, branch_content, "{") orelse {
                        try self.reporter.addError(
                            .PARSE003,
                            event_line_index + 1,
                            1,
                            "branch missing payload shape",
                            .{},
                        );
                        return error.ParseError;
                    };

                    const branch_name = lexer.trim(branch_content[0..branch_brace_idx]);
                    try self.rejectSnakeName(branch_name, event_line_index, "branch");

                    // Find the matching closing brace for the payload
                    const payload_end = blk: {
                        var depth: i32 = 0;
                        var i: usize = branch_brace_idx;
                        while (i < branch_content.len) : (i += 1) {
                            if (branch_content[i] == '{') {
                                depth += 1;
                            } else if (branch_content[i] == '}') {
                                depth -= 1;
                                if (depth == 0) {
                                    break :blk i + 1;
                                }
                            }
                        }
                        break :blk branch_content.len;
                    };

                    // Parse the payload shape
                    const payload_str = branch_content[branch_brace_idx..payload_end];
                    const payload = try self.parseBranchPayloadShape(payload_str);

                    // Check for duplicate branch names
                    for (branches.items) |existing| {
                        if (std.mem.eql(u8, existing.name, branch_name)) {
                            try self.reporter.addError(
                                .PARSE003,
                                event_line_index + 1,
                                1,
                                "duplicate branch name '{s}'",
                                .{branch_name},
                            );
                            return error.ParseError;
                        }
                    }

                    const branch = ast.Branch{
                        .name = try self.allocator.dupe(u8, branch_name),
                        .payload = payload,
                        .is_optional = is_optional,
                        .is_panic = is_panic,
                    };

                    try branches.append(self.allocator, branch);

                    // Move past this branch to check for more
                    branch_content = lexer.trim(branch_content[payload_end..]);
                }
            }
        } else {
            // Multi-line or complex shape - self.current should be at the line after }
            // Check for trailing annotations on the line containing the closing brace
            const last_shape_line = self.lines[self.current - 1];
            if (std.mem.lastIndexOf(u8, last_shape_line, "}")) |close_idx| {
                var after_brace = lexer.trim(last_shape_line[close_idx + 1 ..]);
                if (lexer.startsWith(after_brace, "[")) {
                    // Find the matching closing bracket of the annotation block
                    const close_bracket_idx = blk: {
                        var depth: i32 = 0;
                        var i: usize = 0;
                        while (i < after_brace.len) : (i += 1) {
                            if (after_brace[i] == '[') {
                                depth += 1;
                            } else if (after_brace[i] == ']') {
                                depth -= 1;
                                if (depth == 0) {
                                    break :blk i;
                                }
                            }
                        }
                        break :blk null;
                    } orelse {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current,
                            @intCast(close_idx + 1),
                            "tor annotation missing closing ']'",
                            .{},
                        );
                        return error.ParseError;
                    };

                    const annotation_content = lexer.trim(after_brace[1..close_bracket_idx]);
                    var iter = std.mem.splitScalar(u8, annotation_content, '|');
                    while (iter.next()) |ann| {
                        const trimmed_ann = lexer.trim(ann);
                        if (trimmed_ann.len > 0) {
                            try trailing_annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                        }
                    }
                }
            }
        }

        // Then check for continuation lines (multi-line branch syntax)
        var seen_terminal_branch: bool = false;
        while (self.current < self.lines.len) {
            const next_line = self.lines[self.current];
            if (!lexer.isBranchContinuation(next_line)) break;

            // Capture the branch's line BEFORE parseBranch advances self.current,
            // so the KORU023 error points at the offending branch line.
            const branch_line = self.current + 1;
            var branch = try self.parseBranch();

            // Indented `|` lines under a `!` are its resume-arm sum (210_092);
            // base-indent `|` lines fall through as terminal siblings.
            if (branch.kind == .effect) {
                try self.collectIndentedResumeArms(&branch, lexer.getIndent(self.lines[branch_line - 1]));
            }

            // Ordering rule: effect `!` branches must precede terminal `|` branches.
            if (branch.kind == .effect and seen_terminal_branch) {
                try errors.terminalBeforeEffect(&self.reporter, branch_line, 1, branch.name, .decl);
            }
            if (branch.kind == .terminal) seen_terminal_branch = true;

            // Reject incoherent obligation markers on effect-branch signatures.
            try self.validateEffectBranchObligation(branch, branch_line);

            // Check for duplicate branch names
            for (branches.items) |existing| {
                if (std.mem.eql(u8, existing.name, branch.name)) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current,
                        1,
                        "duplicate branch name '{s}'",
                        .{branch.name},
                    );
                    return error.ParseError;
                }
            }

            try branches.append(self.allocator, branch);
        }

        // Check if this is an implicit flow event
        const is_implicit_flow = self.checkImplicitFlowEvent(&input);

        // `Expression`/`Source` params do NOT imply `[comptime]`. Representation
        // (a captured source string) and timing (when the event runs) are
        // orthogonal axes: an `Expression` is just another way to pass a string,
        // and it can survive to runtime the same way it survives comptime. The
        // old auto-stamp coupled them, which wrongly flipped runtime-emitting
        // keyword templates (`~if`/`~for`) to pure-comptime and filtered their
        // lowered code out of the runtime module. Comptime is now EXPLICIT: an
        // event is comptime-only iff it carries `[comptime]` in its annotations.
        // Combined annotations (passed-in + trailing)
        var all_annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer all_annotations.deinit(self.allocator);

        for (annotations) |ann| {
            try all_annotations.append(self.allocator, ann);
        }
        for (trailing_annotations.items) |ann| {
            try all_annotations.append(self.allocator, ann);
        }

        // Validate: [keyword] requires pub
        for (all_annotations.items) |ann| {
            if (std.mem.eql(u8, ann, "keyword")) {
                if (!is_public) {
                    try self.reporter.addError(
                        .PARSE003,
                        event_line_index,
                        1,
                        "[keyword] annotation requires 'pub' - only public events can be keywords",
                        .{},
                    );
                    return error.ParseError;
                }
                break;
            }
        }

        // Reject single void-returning TERMINAL branch: a lone `| branch` with no
        // payload carries nothing and is redundant — use a void event (0 branches).
        // This is a CONTINUATION (`|`) rule only. An EFFECT (`!`) arm is a yield
        // point that MULTIFIRES (the "heartbeat" — `! beat` fires 0..N per proc
        // run), so a lone payloadless effect arm is NOT redundant and is allowed
        // (ruled 2026-06-27; pinned by 400_152). Effect branches allow
        // {0, one payloadless arm, many}; terminal branches do not.
        if (branches.items.len == 1 and branches.items[0].kind == .terminal and branches.items[0].payload.fields.len == 0 and !branches.items[0].payload.is_wildcard) {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "single branch '{s}' with no payload is redundant - remove it to make this a void tor (no branches)",
                .{branches.items[0].name},
            );
            return error.ParseError;
        }

        // Reject single PAYLOAD-carrying TERMINAL branch (210_131, the
        // single-return form): a lone `| value T` lowers to a one-variant tag
        // union — a tag plus double data movement for a value with exactly ONE
        // shape. One branch is never the right shape: zero outputs => void
        // event, one output => a bare return `-> T`, two-or-more => a real
        // tagged union. Panic (`| ?!`) lone branches are not value returns and
        // stay legal.
        //
        // WILDCARD EXEMPTION: a lone `| c *` is NOT a one-variant union. The `*`
        // is a declaration-time signal that this branch is filled by N guarded
        // dispatch arms at the use site (the `~cond` shape — `cond(x) | c b when
        // g -> v …`), inherently multi-way, never a single shape. This mirrors
        // the payloadless sibling above, which already exempts `!is_wildcard`.
        if (branches.items.len == 1 and branches.items[0].kind == .terminal and
            !branches.items[0].is_panic and
            branches.items[0].payload.fields.len > 0)
        {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "single continuation branch '{s}' carrying a payload is a one-variant tag union — declare the single output as a bare return instead: `-> <type>`",
                .{branches.items[0].name},
            );
            return error.ParseError;
        }

        // Braced single-field payload (`| ok { c: i32 }`) → collapse the redundant
        // braces to identity (`| ok i32`). This is the multi-branch case — a SOLE
        // such branch was caught above as a one-variant tag union (bare return),
        // so by here identity is the correct one-hop advice. Identity payloads
        // carry the __type_ref sentinel; a real field name means the user wrote
        // explicit braces around a single field. (Moved from per-branch parse so
        // the advice can be count-aware — see parseBranch.)
        for (branches.items) |*br| {
            if (br.payload.is_wildcard) continue;
            if (br.payload.fields.len != 1) continue;
            if (std.mem.eql(u8, br.payload.fields[0].name, "__type_ref")) continue;
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "single field in braces - use identity syntax '| {s} {s}' instead of '| {s} {{ {s}: {s} }}'",
                .{ br.name, br.payload.fields[0].type, br.name, br.payload.fields[0].name, br.payload.fields[0].type },
            );
            return error.ParseError;
        }

        // Single-field record RETURN (`-> { a: i64 }`) collapses to the scalar
        // `-> i64` — the produce-side sibling of the single-field branch payload
        // above; only a 2+-field record earns the braces. (210_149)
        if (return_type) |rt| {
            if (isSingleFieldRecordType(rt)) {
                try self.reporter.addError(
                    .PARSE003,
                    event_line_index + 1,
                    1,
                    "single field in record return `{s}` — collapse to the scalar `-> <type>`; a record return is for two or more fields",
                    .{rt},
                );
                return error.ParseError;
            }
        }

        // `[transform]` declares WHAT (a transformation intent); `[comptime]`
        // declares WHERE (it emits into the backend). A transform tor without
        // `[comptime]` is never registered as a pass, so it silently does
        // nothing at every call site — the author's mistake is invisible.
        //
        // The invariant is universal and was, until now, unenforced: MEASURED
        // 2026-07-31, every `[transform]` tor declaration in koru_std/ and
        // tests/ carries `[comptime]`. The lone exception is 210_029, the test
        // that exists to have this refused.
        if (annotation_parser.hasPart(all_annotations.items, "transform") and
            !annotation_parser.hasPart(all_annotations.items, "comptime"))
        {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "tor '{s}' has [transform] but is missing [comptime] — [transform] declares the intent, [comptime] is what emits the pass; without both the transform is never registered and every call site silently does nothing",
                .{if (path.segments.len > 0) path.segments[path.segments.len - 1] else "?"},
            );
            return error.ParseError;
        }

        // Copy annotations verbatim — comptime is explicit, never synthesized.
        var annotations_copy = try self.allocator.alloc([]const u8, all_annotations.items.len);
        for (all_annotations.items, 0..) |ann, i| {
            annotations_copy[i] = try self.allocator.dupe(u8, ann);
        }

        var event_decl = ast.EventDecl{
            .path = path,
            .input = input,
            .branches = try branches.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .return_phantom = return_phantom,
            .is_public = is_public,
            .is_implicit_flow = is_implicit_flow,
            .annotations = annotations_copy,
            .prose = self.takePendingProse(),
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
        // Ownership transferred into event_decl; disarm the errdefer above.
        return_type = null;
        return_phantom = null;

        // Normalize kebab names -> snake BEFORE registration: the registry
        // KEBAB-CANONICAL: registry deep-copies the names verbatim (kebab).
        // Lookups come through the same verbatim path; emission lowers.

        log_debug("PARSER: Created EventDecl module='{s}', path.module_qualifier={s}\n", .{ event_decl.module, if (event_decl.path.module_qualifier) |m| m else "null" });

        // Register the event with the type registry
        const path_str = try self.pathToString(event_decl.path);
        defer self.allocator.free(path_str);
        try self.registry.registerEvent(path_str, &event_decl);

        return event_decl;
    }

    fn parseEventDecl(self: *Parser, is_public: bool) !ast.EventDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing tor declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const line = self.lines[self.current];
        self.current += 1;
        const event_line_index = self.current - 1;

        // Parse: ~[pub] tor[annotations] <path> { <fields> }
        const after_event = if (lexer.afterPrefix(line, "~pub tor")) |ae|
            ae
        else if (lexer.afterPrefix(line, "~tor")) |ae|
            ae
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "malformed tor declaration",
                .{},
            );
            return error.ParseError;
        };

        // Check for annotations: [pure|fusible|...]
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer annotations.deinit(self.allocator);

        var path_start = after_event;
        const trimmed_after = lexer.trim(after_event);
        if (std.mem.startsWith(u8, trimmed_after, "[")) {
            // Parse annotation block (supports both inline event[a|b] and vertical event[\n-a\n-b\n])
            const result = try self.parseAnnotationBlock(trimmed_after, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            // Trailing vertical block (`tor foo[\n- tag\n prose\n]`): the prose
            // belongs to the declaration being built a few lines below.
            self.stashProse(result.prose);

            for (result.annotations) |ann| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
            }

            path_start = lexer.trim(result.remaining);
        }

        const trimmed_path_start = lexer.trim(path_start);
        const brace_idx_opt = std.mem.indexOf(u8, trimmed_path_start, "{");
        const parsed_path_str = if (brace_idx_opt) |idx|
            lexer.trim(trimmed_path_start[0..idx])
        else
            trimmed_path_start;

        if (parsed_path_str.len == 0) {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "tor declaration missing name",
                .{},
            );
            return error.ParseError;
        }

        try self.rejectVariantTagOnTor(parsed_path_str, event_line_index);
        try self.rejectSnakeName(parsed_path_str, event_line_index, "tor");
        var path = try lexer.parseQualifiedPath(self.allocator, parsed_path_str, ast);
        errdefer path.deinit(self.allocator);

        const shape_source = if (brace_idx_opt) |idx|
            trimmed_path_start[idx..]
        else
            "";
        var input = try self.parseEventInputShape(shape_source, event_line_index);
        errdefer input.deinit(self.allocator);

        // Parse branches (continuation lines starting with |)
        var branches = try std.ArrayList(ast.Branch).initCapacity(self.allocator, 8);
        errdefer {
            for (branches.items) |*branch| {
                branch.deinit(self.allocator);
            }
            branches.deinit(self.allocator);
        }

        var seen_terminal_branch_v2: bool = false;
        while (self.current < self.lines.len) {
            const next_line = self.lines[self.current];
            if (!lexer.isBranchContinuation(next_line)) break;

            const branch_line = self.current + 1;
            var branch = try self.parseBranch();

            // Indented `|` lines under a `!` are its resume-arm sum (210_092);
            // base-indent `|` lines fall through as terminal siblings.
            if (branch.kind == .effect) {
                try self.collectIndentedResumeArms(&branch, lexer.getIndent(self.lines[branch_line - 1]));
            }

            // Ordering rule: effect `!` branches must precede terminal `|` branches.
            if (branch.kind == .effect and seen_terminal_branch_v2) {
                try errors.terminalBeforeEffect(&self.reporter, branch_line, 1, branch.name, .decl);
            }
            if (branch.kind == .terminal) seen_terminal_branch_v2 = true;

            // Reject incoherent obligation markers on effect-branch signatures.
            try self.validateEffectBranchObligation(branch, branch_line);

            // Check for duplicate branch names
            for (branches.items) |existing| {
                if (std.mem.eql(u8, existing.name, branch.name)) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current,
                        1,
                        "duplicate branch name '{s}'",
                        .{branch.name},
                    );
                    return error.ParseError;
                }
            }

            try branches.append(self.allocator, branch);
            // parseBranch handles line advancement including multi-line payloads
        }

        // Check if this is an implicit flow event
        const is_implicit_flow = self.checkImplicitFlowEvent(&input);

        var event_decl = ast.EventDecl{
            .path = path,
            .input = input,
            .branches = try branches.toOwnedSlice(self.allocator),
            .is_public = is_public,
            .is_implicit_flow = is_implicit_flow,
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .prose = self.takePendingProse(),
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };

        // KEBAB-CANONICAL: registry deep-copies the names verbatim (kebab).
        // See the matching note at the other EventDecl registration site.

        // Register the event with the type registry
        const path_str = try self.pathToString(event_decl.path);
        defer self.allocator.free(path_str);
        try self.registry.registerEvent(path_str, &event_decl);

        return event_decl;
    }

    fn parseProcDeclWithAnnotations(self: *Parser, annotations: [][]const u8) !ast.ProcDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing proc declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const line = self.lines[self.current];
        self.current += 1;

        // Parse: ~[annotations]proc <path> { ... }
        const trimmed = lexer.trim(line);
        const after_tilde = lexer.trim(trimmed[1..]); // Skip ~

        // Skip past annotations if present (both inline and vertical syntax)
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            const result = try self.parseAnnotationBlock(after_tilde, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            // We don't need the annotations, just skip past them — but this
            // re-scan is the only place the prose survives when the block was
            // written directly above the construct, so it is stashed here.
            self.stashProse(result.prose);
            remaining = lexer.trim(result.remaining);
        }

        // Reject "pub proc" - only events can be public
        if (lexer.afterPrefix(remaining, "pub proc")) |_| {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "'pub' is not valid on proc declarations - only events can be public",
                .{},
            );
            return error.ParseError;
        }

        // Handle "proc" prefix
        const after_proc = if (lexer.afterPrefix(remaining, "proc")) |ap|
            ap
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "malformed proc declaration",
                .{},
            );
            return error.ParseError;
        };

        // Find the path (everything before {)
        // Proc bodies are always host language in braces. The = syntax is for flows only.
        const brace_idx_opt = std.mem.indexOf(u8, after_proc, "{");
        const equals_idx_opt = std.mem.indexOf(u8, after_proc, "=");

        // Reject ~proc X = ... syntax — procs contain host language, not flow expressions
        if (equals_idx_opt) |equals_idx| {
            if (brace_idx_opt == null or equals_idx < brace_idx_opt.?) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "proc declarations must use braces for host language code. The '=' syntax is only valid on flows.",
                    .{},
                );
                return error.ParseError;
            }
        }

        const delimiter_idx = brace_idx_opt orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "proc declaration missing body",
                .{},
            );
            return error.ParseError;
        };

        const parsed_path_str = lexer.trim(after_proc[0..delimiter_idx]);

        // Check for |variant suffix (e.g., "blur|gpu" or "compute|naive")
        var target: ?[]const u8 = null;
        var path_for_parsing = parsed_path_str;

        if (std.mem.indexOfScalar(u8, parsed_path_str, '|')) |pipe_idx| {
            // Split at pipe: path before, variant after
            path_for_parsing = lexer.trim(parsed_path_str[0..pipe_idx]);
            const target_str = lexer.trim(parsed_path_str[pipe_idx + 1 ..]);
            if (target_str.len > 0) {
                target = try self.allocator.dupe(u8, target_str);
            }
        }

        try self.rejectSnakeName(path_for_parsing, self.current, "proc");
        var path = try lexer.parseQualifiedPath(self.allocator, path_for_parsing, ast);
        errdefer path.deinit(self.allocator);

        // Proc bodies are always host language in braces
        // Capture the body's start line BEFORE extractProcBody advances self.current,
        // so inline-flow rejection can point at the right source location.
        const body_start_line = self.current;
        var raw_body_owned = true;
        const raw_body = try self.extractProcBody(after_proc[delimiter_idx..]);
        errdefer if (raw_body_owned) self.allocator.free(raw_body);

        // Check if this proc has the [raw] annotation - if so, skip inline flow extraction
        var has_raw_annotation = false;
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann, "raw")) {
                has_raw_annotation = true;
                break;
            }
        }

        // Extract inline flows and get modified body (unless [raw] annotation is present)
        const extraction_result = if (has_raw_annotation) blk: {
            raw_body_owned = false;
            break :blk FlowExtractionResult{ .flows = &.{}, .modified_body = raw_body };
        } else blk: {
            const result = try self.extractInlineFlows(raw_body, path, body_start_line);
            self.allocator.free(raw_body);
            raw_body_owned = false;
            break :blk result;
        };

        // Copy annotations
        var annotations_copy = try self.allocator.alloc([]const u8, annotations.len);
        for (annotations, 0..) |ann, i| {
            annotations_copy[i] = try self.allocator.dupe(u8, ann);
        }

        // Check for ~[pure] annotation
        var is_pure = false;
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann, "pure")) {
                is_pure = true;
                break;
            }
        }

        return ast.ProcDecl{
            .path = path,
            .body = ast.Source{
                .text = extraction_result.modified_body,
                .location = self.getCurrentLocation(),
                .scope = ast.CapturedScope{ .bindings = &[_]ast.ScopeBinding{} },
                .phantom_type = null,
            },
            .inline_flows = extraction_result.flows,
            .annotations = annotations_copy,
            .prose = self.takePendingProse(),
            .target = target,
            .is_pure = is_pure,
            // is_transitively_pure defaults to false, will be set by purity checker
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }

    fn parseProcDecl(self: *Parser) !ast.ProcDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing proc declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const line = self.lines[self.current];
        self.current += 1;

        // Parse: ~proc[annotations] <path> { ... }
        const after_proc = lexer.afterPrefix(line, "~proc") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "malformed proc declaration",
                .{},
            );
            return error.ParseError;
        };

        // Check for annotations: [pure|async|...]
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer annotations.deinit(self.allocator);

        var path_start = after_proc;
        const trimmed_after = lexer.trim(after_proc);
        if (std.mem.startsWith(u8, trimmed_after, "[")) {
            // Parse annotation block (supports both inline proc[a|b] and vertical proc[\n-a\n-b\n])
            const result = try self.parseAnnotationBlock(trimmed_after, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            // Trailing vertical block (`tor foo[\n- tag\n prose\n]`): the prose
            // belongs to the declaration being built a few lines below.
            self.stashProse(result.prose);

            for (result.annotations) |ann| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
            }

            path_start = lexer.trim(result.remaining);
        }

        // Find the path (everything before the first {)
        const brace_idx = std.mem.indexOf(u8, path_start, "{") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "proc declaration missing body",
                .{},
            );
            return error.ParseError;
        };

        const parsed_path_str = lexer.trim(path_start[0..brace_idx]);

        // Check for |variant suffix (e.g., "blur|gpu" or "compute|naive")
        var target: ?[]const u8 = null;
        var path_for_parsing = parsed_path_str;

        if (std.mem.indexOfScalar(u8, parsed_path_str, '|')) |pipe_idx| {
            // Split at pipe: path before, variant after
            path_for_parsing = lexer.trim(parsed_path_str[0..pipe_idx]);
            const target_str = lexer.trim(parsed_path_str[pipe_idx + 1 ..]);
            if (target_str.len > 0) {
                target = try self.allocator.dupe(u8, target_str);
            }
        }

        try self.rejectSnakeName(path_for_parsing, self.current, "proc");
        var path = try lexer.parseQualifiedPath(self.allocator, path_for_parsing, ast);
        errdefer path.deinit(self.allocator);

        // Extract the body (balanced braces).
        // Capture the body's start line BEFORE extractProcBody advances self.current,
        // so inline-flow rejection can point at the right source location.
        const body_start_line = self.current;
        var raw_body_owned = true;
        const raw_body = try self.extractProcBody(path_start[brace_idx..]);
        errdefer if (raw_body_owned) self.allocator.free(raw_body);

        // Check if this proc has the [raw] annotation - if so, skip inline flow extraction
        var has_raw_annotation = false;
        for (annotations.items) |ann| {
            if (std.mem.eql(u8, ann, "raw")) {
                has_raw_annotation = true;
                break;
            }
        }

        // Extract inline flows and get modified body (unless [raw] annotation is present)
        const extraction_result = if (has_raw_annotation) blk: {
            raw_body_owned = false;
            break :blk FlowExtractionResult{ .flows = &.{}, .modified_body = raw_body };
        } else blk: {
            const result = try self.extractInlineFlows(raw_body, path, body_start_line);
            self.allocator.free(raw_body);
            raw_body_owned = false;
            break :blk result;
        };

        // Debug output for flow extraction
        const path_debug = try self.pathToString(path);
        defer self.allocator.free(path_debug);

        // Debug: Show modified body if flows were found
        if (extraction_result.flows.len > 0 or extraction_result.modified_body.len != raw_body.len) {}

        const proc_decl = ast.ProcDecl{
            .path = path,
            .body = ast.Source{
                .text = extraction_result.modified_body,
                .location = self.getCurrentLocation(),
                .scope = ast.CapturedScope{ .bindings = &[_]ast.ScopeBinding{} },
                .phantom_type = null,
            },
            .inline_flows = extraction_result.flows,
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .prose = self.takePendingProse(),
            .target = target,
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };

        // Register the proc with the type registry
        const path_str = try self.pathToString(proc_decl.path);
        defer self.allocator.free(path_str);
        try self.registry.registerProc(path_str, &proc_decl);

        return proc_decl;
    }

    const FlowExtractionResult = struct {
        modified_body: []const u8,
        flows: []ast.Flow,
    };

    fn extractInlineFlows(self: *Parser, body: []const u8, proc_path: ast.DottedPath, body_start_line: usize) !FlowExtractionResult {
        var extracted_flows = try std.ArrayList(ast.Flow).initCapacity(self.allocator, 0);
        errdefer {
            for (extracted_flows.items) |*flow| {
                flow.deinit(self.allocator);
            }
            extracted_flows.deinit(self.allocator);
        }

        var modified_body = try std.ArrayList(u8).initCapacity(self.allocator, body.len);
        defer modified_body.deinit(self.allocator);

        // Split body into lines for processing
        var body_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
        defer body_lines.deinit(self.allocator);

        var line_iter = std.mem.splitScalar(u8, body, '\n');
        while (line_iter.next()) |line| {
            try body_lines.append(self.allocator, line);
        }

        // Process line by line
        var i: usize = 0;
        // Note: Using self.inline_flow_counter (global) instead of local counter
        // This ensures numbering matches the emitter's global numbering

        while (i < body_lines.items.len) {
            const line = body_lines.items[i];
            const trimmed = lexer.trim(line);
            const current_indent = lexer.getIndent(line);

            // Check if this line contains an inline flow
            // Patterns: "~...", "return ~...", "const name = ~..."
            //
            // Keyword filter uses word-boundary check — `~process_int` must not
            // be mis-read as `~proc`, and `~event_handler` must not be mis-read
            // as `~event`. The next char after the keyword must be a non-identifier
            // (space, `{`, `(`, end-of-line, etc.) for it to count as a keyword.
            const has_inline_flow = blk: {
                if (lexer.startsWith(trimmed, "~")) {
                    if (startsWithKeyword(trimmed, "~proc") or
                        startsWithKeyword(trimmed, "~tor") or
                        startsWithKeyword(trimmed, "~import") or
                        startsWithKeyword(trimmed, "~pub") or
                        startsWithKeyword(trimmed, "~for") or
                        startsWithKeyword(trimmed, "~if") or
                        startsWithKeyword(trimmed, "~else") or
                        startsWithKeyword(trimmed, "~while") or
                        startsWithKeyword(trimmed, "~match") or
                        startsWithKeyword(trimmed, "~struct") or
                        startsWithKeyword(trimmed, "~type"))
                    {
                        // host-language keyword, not an inline flow
                    } else {
                        break :blk true;
                    }
                }
                if (lexer.startsWith(trimmed, "return ~")) {
                    break :blk true;
                }
                if (lexer.startsWith(trimmed, "const ")) {
                    if (std.mem.indexOf(u8, trimmed, " = ~")) |_| {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            if (has_inline_flow) {
                // FEATURE GATE: inline flows in proc bodies are currently disabled.
                // The extraction + codegen path below is preserved (unreachable from
                // user code) so we can re-enable the feature later by removing this
                // rejection block. See koru/CLAUDE.md and the regression-triage doc.
                try errors.inlineFlowInProc(
                    &self.reporter,
                    body_start_line + i,
                    current_indent + 1,
                    trimmed,
                );
                return error.ParseError;
            }

            if (false) {
                // Found an inline flow!

                // Collect all lines belonging to this flow
                var flow_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
                defer flow_lines.deinit(self.allocator);

                // Add the first line (the ~ line)
                try flow_lines.append(self.allocator, line);
                i += 1;

                // Collect continuation lines (including nested ones)
                var brace_depth: i32 = 0;

                // Check if the first line has unmatched braces (skip braces in strings/comments)
                brace_depth += lexer.countBraceDepthChange(trimmed);

                while (i < body_lines.items.len) {
                    const next_line = body_lines.items[i];
                    const next_trimmed = lexer.trim(next_line);
                    const next_indent = lexer.getIndent(next_line);

                    // A line belongs to the flow if:
                    // 1. It starts with | and has indent > the flow's indent (continuation)
                    // 2. It's part of a multi-line constructor (brace_depth > 0)
                    // 3. It's an empty line or comment within the flow structure
                    if (next_trimmed.len == 0 or lexer.startsWith(next_trimmed, "//")) {
                        // Could be part of the flow - check if we should continue
                        // Look ahead to see if there are more flow lines
                        var j = i + 1;
                        var found_more_flow = false;
                        while (j < body_lines.items.len) {
                            const peek_line = body_lines.items[j];
                            const peek_trimmed = lexer.trim(peek_line);
                            const peek_indent = lexer.getIndent(peek_line);

                            if (peek_trimmed.len > 0 and !lexer.startsWith(peek_trimmed, "//")) {
                                if (lexer.startsWith(peek_trimmed, "|") and peek_indent >= current_indent) {
                                    found_more_flow = true;
                                }
                                break;
                            }
                            j += 1;
                        }

                        if (found_more_flow) {
                            try flow_lines.append(self.allocator, next_line);

                            // Update brace depth for empty/comment lines (skip braces in strings/comments)
                            brace_depth += lexer.countBraceDepthChange(next_trimmed);

                            i += 1;
                        } else {
                            break;
                        }
                    } else if (lexer.startsWith(next_trimmed, "|") and next_indent >= current_indent) {
                        // This is a continuation at same or greater indent
                        try flow_lines.append(self.allocator, next_line);

                        // Update brace depth for continuation lines (skip braces in strings/comments)
                        brace_depth += lexer.countBraceDepthChange(next_trimmed);

                        i += 1;
                    } else if (brace_depth > 0) {
                        // We're inside a multi-line constructor
                        // Check if this line is part of the constructor (field or closing brace)
                        const is_valid_constructor_line = blk: {
                            // Check if it's a closing brace
                            if (std.mem.eql(u8, next_trimmed, "}")) {
                                break :blk true;
                            }
                            // For lines with greater indent, check if it looks like a field
                            if (next_indent > current_indent) {
                                // Check if it looks like a field definition (name: value)
                                if (std.mem.indexOf(u8, next_trimmed, ":") != null) {
                                    // Make sure it's not a Zig statement like const x: Type
                                    if (!lexer.startsWith(next_trimmed, "const ") and
                                        !lexer.startsWith(next_trimmed, "var ") and
                                        !lexer.startsWith(next_trimmed, "fn ") and
                                        !lexer.startsWith(next_trimmed, "if ") and
                                        !lexer.startsWith(next_trimmed, "while ") and
                                        !lexer.startsWith(next_trimmed, "for "))
                                    {
                                        break :blk true;
                                    }
                                }
                            }
                            break :blk false;
                        };

                        if (is_valid_constructor_line) {
                            try flow_lines.append(self.allocator, next_line);

                            // Update brace depth (skip braces in strings/comments)
                            brace_depth += lexer.countBraceDepthChange(next_trimmed);

                            i += 1;
                        } else {
                            // Not a valid constructor line, stop collecting
                            break;
                        }
                    } else {
                        // Not a continuation, end of flow
                        break;
                    }
                }

                // Parse the collected flow
                var parsed_flow = try self.parseCollectedFlow(flow_lines.items, current_indent);

                // Use UnionCollector to analyze branches and build SuperShape
                const union_collector = @import("union_collector");
                var collector = union_collector.UnionCollector.init(self.allocator);
                var collection_result = try collector.collectFromFlow(&parsed_flow);
                defer collection_result.deinit(self.allocator);

                // Transfer ownership of super_shape to the flow
                if (collection_result.transferSuperShape()) |super_shape| {
                    parsed_flow.super_shape = super_shape;
                }

                // Check for conflicts and report them
                if (collection_result.has_conflicts) {
                    for (collection_result.conflicts) |_| {
                        // TODO: Report as semantic error - branch has conflicting shapes
                        // For now, we'll continue but the code generator will need to handle this
                    }
                }

                try extracted_flows.append(self.allocator, parsed_flow);

                // Generate a unique name for this flow (global counter)
                self.inline_flow_counter += 1;
                const flow_name = try std.fmt.allocPrint(self.allocator, "__inline_flow_{d}", .{self.inline_flow_counter});
                defer self.allocator.free(flow_name);

                // Generate replacement based on the pattern
                const replacement = blk: {
                    // Create indentation string
                    const indent_str = try self.allocator.alloc(u8, current_indent);
                    defer self.allocator.free(indent_str);
                    @memset(indent_str, ' ');

                    // INLINE FLOW FIX: Pass ALL proc parameters, not just first invocation's args
                    // Look up the proc's event to get its full input shape
                    const proc_path_str = try self.pathToString(proc_path);
                    defer self.allocator.free(proc_path_str);

                    const args_str = if (self.registry.getEventType(proc_path_str)) |event_type| blk2: {
                        // Event found! Use its input shape to generate ALL parameter passing
                        if (event_type.input_shape) |input_shape| {
                            var args_buf = try std.ArrayList(u8).initCapacity(self.allocator, 128);
                            defer args_buf.deinit(self.allocator);

                            // Generate .{ .field1 = field1, .field2 = field2, ... }
                            try args_buf.appendSlice(self.allocator, ".{ ");
                            for (input_shape.fields, 0..) |field, idx| {
                                if (idx > 0) {
                                    try args_buf.appendSlice(self.allocator, ", ");
                                }
                                try args_buf.appendSlice(self.allocator, ".");
                                try args_buf.appendSlice(self.allocator, field.name);
                                try args_buf.appendSlice(self.allocator, " = ");
                                try args_buf.appendSlice(self.allocator, field.name);
                            }
                            try args_buf.appendSlice(self.allocator, " }");

                            break :blk2 try args_buf.toOwnedSlice(self.allocator);
                        } else {
                            // No input shape (event has no parameters)
                            break :blk2 try self.allocator.dupe(u8, ".{}");
                        }
                    } else try self.allocator.dupe(u8, ".{}");
                    defer self.allocator.free(args_str);

                    if (lexer.startsWith(trimmed, "return ~")) {
                        // Terminal flow: return ~... -> return __inline_flow_N(args)
                        break :blk try std.fmt.allocPrint(self.allocator, "{s}return {s}({s});", .{ indent_str, flow_name, args_str });
                    } else if (lexer.startsWith(trimmed, "const ")) {
                        // Assignment flow: const x = ~... -> const x = __inline_flow_N(args)
                        const eq_idx = std.mem.indexOf(u8, trimmed, " = ~") orelse unreachable;
                        const var_decl = trimmed[0 .. eq_idx + 3]; // "const x = "
                        break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}{s}({s});", .{ indent_str, var_decl, flow_name, args_str });
                    } else {
                        // Direct flow: ~...
                        // Check if this is the last non-empty statement in the proc body
                        // If yes, it should implicitly return; otherwise assign to result_N
                        const is_terminal = blk2: {
                            // Look ahead from current position (i) to see if there are more statements
                            var j = i;
                            while (j < body_lines.items.len) : (j += 1) {
                                const remaining_line = body_lines.items[j];
                                const remaining_trimmed = lexer.trim(remaining_line);

                                // Skip empty lines and comments
                                if (remaining_trimmed.len == 0 or lexer.startsWith(remaining_trimmed, "//")) {
                                    continue;
                                }

                                // Found a non-empty, non-comment line after this flow
                                break :blk2 false;
                            }
                            // No more statements found - this is terminal!
                            break :blk2 true;
                        };

                        if (is_terminal) {
                            // Terminal flow with implicit return
                            break :blk try std.fmt.allocPrint(self.allocator, "{s}return {s}({s});", .{ indent_str, flow_name, args_str });
                        } else {
                            // Non-terminal flow: assign to result variable
                            break :blk try std.fmt.allocPrint(self.allocator, "{s}const result_{d} = {s}({s});", .{ indent_str, self.inline_flow_counter, flow_name, args_str });
                        }
                    }
                };
                defer self.allocator.free(replacement);

                try modified_body.appendSlice(self.allocator, replacement);
                try modified_body.append(self.allocator, '\n');
            } else {
                // Not a flow, keep line as-is
                try modified_body.appendSlice(self.allocator, line);
                try modified_body.append(self.allocator, '\n');
                i += 1;
            }
        }

        // Remove trailing newline if present
        if (modified_body.items.len > 0 and modified_body.items[modified_body.items.len - 1] == '\n') {
            _ = modified_body.pop();
        }

        return FlowExtractionResult{
            .modified_body = try modified_body.toOwnedSlice(self.allocator),
            .flows = try extracted_flows.toOwnedSlice(self.allocator),
        };
    }

    fn parseCollectedFlow(self: *Parser, flow_lines: [][]const u8, base_indent: usize) anyerror!ast.Flow {
        // Adjust indentation - make it relative to base_indent
        var adjusted_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, flow_lines.len);
        defer adjusted_lines.deinit(self.allocator);

        for (flow_lines, 0..) |line, idx| {
            const line_indent = lexer.getIndent(line);
            const relative_indent = if (line_indent >= base_indent) line_indent - base_indent else 0;

            // Get the trimmed line
            var trimmed = lexer.trim(line);

            // For the first line, strip any prefix (return, const x = )
            if (idx == 0) {
                if (lexer.startsWith(trimmed, "return ~")) {
                    trimmed = trimmed[7..]; // Skip "return "
                } else if (lexer.startsWith(trimmed, "const ")) {
                    if (std.mem.indexOf(u8, trimmed, " = ~")) |eq_idx| {
                        trimmed = trimmed[eq_idx + 3 ..]; // Skip "const x = "
                    }
                }
            }

            // Create new line with adjusted indentation
            const spaces = try self.allocator.alloc(u8, relative_indent);
            defer self.allocator.free(spaces);
            @memset(spaces, ' ');

            const adjusted_line = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ spaces, trimmed });
            try adjusted_lines.append(self.allocator, adjusted_line);
        }

        // Create a temporary parser with these lines
        var context_stack = try std.ArrayList(Context).initCapacity(self.allocator, 8);
        defer context_stack.deinit(self.allocator);
        try context_stack.append(self.allocator, .in_proc); // We're in a proc context

        var temp_parser = Parser{
            .allocator = self.allocator,
            .lines = adjusted_lines.items,
            .current = 0,
            .reporter = self.reporter,
            .context_stack = context_stack,
            .registry = self.registry,
            .is_compiler_library = self.is_compiler_library,
            .module_name = self.module_name,
            .inline_flow_counter = self.inline_flow_counter, // Inherit parent's counter
            .fail_fast = self.fail_fast, // Inherit parent's fail_fast mode
            .compiler_flags = self.compiler_flags, // Inherit parent's compiler flags
            .resolver = self.resolver, // Inherit parent's resolver
        };

        // Parse the flow (no annotations in embedded context)
        const flow = try temp_parser.parseFlow(&[_][]const u8{});

        // Clean up adjusted lines
        for (adjusted_lines.items) |line| {
            self.allocator.free(line);
        }

        return flow;
    }

    fn pathToString(self: *Parser, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        errdefer buf.deinit(self.allocator);

        // Add module qualifier if present (e.g., "build" in "build:requires")
        if (path.module_qualifier) |mq| {
            try buf.appendSlice(self.allocator, mq);
            try buf.append(self.allocator, ':');
        }

        for (path.segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// `~` for a host-embedding file, nothing for pure `.k`. A hint that shows a
    /// spelling has to show the spelling THIS file uses — a `.k` author who copies
    /// a `~` out of a diagnostic gets a second error for their trouble.
    fn tilde(self: *const Parser) []const u8 {
        return if (self.is_k) "" else "~";
    }

    /// An import alias has to be a bare identifier, because every use site is
    /// `alias/rest` and the first segment is split on `/`. Same rule the import
    /// validator applies, so anything declared here is usable there.
    fn isUsableAlias(alias: []const u8) bool {
        if (alias.len == 0) return false;
        if (!std.ascii.isAlphabetic(alias[0]) and alias[0] != '_') return false;
        for (alias[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        return true;
    }

    /// Apply a `std/compiler:paths { alias: ./path }` declaration to the live
    /// resolver config. A no-op for every other invocation.
    ///
    /// `../` is deliberately allowed here where imports forbid it: the import
    /// validator guards USE sites, which are always alias-relative. A declaration
    /// is where an escape out of the tree gets written down and read, and that is
    /// exactly the job koru.json used to hold.
    fn applyPathsDirective(self: *Parser, flow: *const ast.Flow, directive_line: usize) !void {
        const path = flow.inv().path;
        if (path.segments.len != 1 or !std.mem.eql(u8, path.segments[0], "paths")) return;
        const qualifier = path.module_qualifier orelse return;
        // parseQualifiedPath normalizes `/` to `.`, so the slash and dot spellings
        // arrive here identically.
        if (!std.mem.eql(u8, qualifier, "std.compiler")) return;

        var source_text: ?[]const u8 = null;
        for (flow.inv().args) |arg| {
            if (std.mem.eql(u8, arg.name, "source")) source_text = arg.value;
        }
        const body = source_text orelse {
            try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths requires a block: {s}std/compiler:paths {{ alias: ./path }}", .{self.tilde()});
            return error.ParseError;
        };

        const resolver = self.resolver orelse {
            try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths declares import aliases, so it needs a module resolver - this parse was started without one", .{});
            return error.ParseError;
        };

        var lines = std.mem.tokenizeAny(u8, body, "\n");
        while (lines.next()) |raw| {
            var line = lexer.trim(raw);
            if (std.mem.indexOf(u8, line, "//")) |c| line = lexer.trim(line[0..c]);
            if (line.len == 0) continue;
            if (std.mem.endsWith(u8, line, ",")) line = lexer.trim(line[0 .. line.len - 1]);
            if (line.len == 0) continue;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths - each line is `alias: path`, got `{s}`", .{line});
                return error.ParseError;
            };

            const alias = lexer.trim(line[0..colon]);
            const target = lexer.trim(line[colon + 1 ..]);

            if (!isUsableAlias(alias)) {
                try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths - `{s}` cannot be an import alias; an alias is a bare identifier (letters, digits, `_`), because every use site splits on the first `/`", .{alias});
                return error.ParseError;
            }
            if (std.mem.eql(u8, alias, "main")) {
                try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths - the alias `main` is reserved for the entry module", .{});
                return error.ParseError;
            }
            if (target.len == 0) {
                try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths - alias `{s}` has no path", .{alias});
                return error.ParseError;
            }

            // A `{{ flag:name }}` naming a flag nobody supplied is refused at the
            // DECLARATION, not left to resolve into a path that happens to exist.
            var ref_buf: [8][]const u8 = undefined;
            for (module_resolver_mod.ModuleResolver.flagRefs(target, &ref_buf)) |ref| {
                if (resolver.flagValue(ref) == null) {
                    try self.reporter.addError(.KORU172, directive_line, 1, "std/compiler:paths - alias `{s}` interpolates `{{{{ flag:{s} }}}}` but no `--{s}=<value>` was supplied", .{ alias, ref, ref });
                    return error.ParseError;
                }
            }

            try resolver.config.addPath(alias, target);
        }
    }

    /// Check if an event is an implicit flow event
    /// Returns true if the event has exactly one parameter of type Source
    fn checkImplicitFlowEvent(self: *Parser, input: *const ast.Shape) bool {
        _ = self; // Parser context not needed for this check

        // Must have exactly one field
        if (input.fields.len != 1) return false;

        const field = input.fields[0];

        // Check for Source parameter named "source"
        if (std.mem.eql(u8, field.name, "source") and field.is_source) {
            return true;
        }

        return false;
    }

    /// Create an invocation with synthetic Source argument for implicit flow events
    fn createImplicitFlowInvocation(self: *Parser, original: ast.Invocation, continuations: []ast.Continuation, event_type: type_registry.EventType) !ast.Invocation {
        _ = continuations; // No longer needed

        // Determine which field is the implicit flow field. No Source field
        // means there is nothing to inject — return the invocation unchanged.
        // (This was `undefined` + conditional assignment: an event WITHOUT a
        // Source input reaching here read garbage memory and overflowed in
        // the allocator. Latent until 2026-07-02.)
        var flow_field_name: ?[]const u8 = null;

        // EventType has input shape info
        const input_shape = event_type.input_shape orelse return original;
        for (input_shape.fields) |field| {
            if (std.mem.eql(u8, field.type, "Source")) {
                flow_field_name = field.name;
                break;
            }
        }
        const source_field_name = flow_field_name orelse return original;

        // Check if source arg already exists - don't add duplicate
        var has_source_arg = false;
        for (original.args) |arg| {
            if (std.mem.eql(u8, arg.name, source_field_name)) {
                has_source_arg = true;
                break;
            }
        }

        // If source already exists, return original unchanged
        if (has_source_arg) {
            return original;
        }

        // Create new args array with the synthetic Source argument
        var new_args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, original.args.len + 1);
        defer new_args.deinit(self.allocator);

        // Copy existing args
        for (original.args) |arg| {
            try new_args.append(self.allocator, arg);
        }

        // Create synthetic Source argument
        const source_arg = ast.Arg{
            .name = try self.allocator.dupe(u8, source_field_name),
            .value = try self.allocator.dupe(u8, "<implicit_source>"),
        };

        try new_args.append(self.allocator, source_arg);

        // Check if we need to add Program
        for (input_shape.fields) |field| {
            if (std.mem.eql(u8, field.type, "Program")) {
                const ast_arg = ast.Arg{
                    .name = try self.allocator.dupe(u8, field.name),
                    .value = try self.allocator.dupe(u8, "<program_ast>"),
                };
                try new_args.append(self.allocator, ast_arg);
                break;
            }
        }

        return ast.Invocation{
            .path = original.path,
            .args = try new_args.toOwnedSlice(self.allocator),
        };
    }

    fn createImplicitSourceInvocation(self: *Parser, original: ast.Invocation, source_text: []const u8, phantom_type: ?[]const u8, event_type: type_registry.EventType) !ast.Invocation {
        // Find the 'source' field of type Source
        var source_field_name: []const u8 = undefined;
        var found_source = false;
        var alternate_source_name: ?[]const u8 = null;

        const input_shape = event_type.input_shape orelse return original;
        for (input_shape.fields) |field| {
            if (std.mem.eql(u8, field.name, "source") and field.is_source) {
                source_field_name = field.name;
                found_source = true;
                break;
            } else if (field.is_source) {
                // Found a Source parameter with different name
                alternate_source_name = field.name;
            }
        }

        if (!found_source) {
            // Check if there's a Source parameter with a different name
            if (alternate_source_name) |alt_name| {
                // Get event name for error message
                const path_str = try self.pathToString(original.path);
                defer self.allocator.free(path_str);

                try self.reporter.addError(.PARSE001, self.current, 0, "Implicit source block syntax [Type]{{ }} requires parameter named 'source'. Event '{s}' has Source parameter named '{s}'. Either rename parameter to 'source' or use explicit syntax: ~{s}({s}: [Type]{{ }})", .{ path_str, alt_name, path_str, alt_name });
                return error.ParseError;
            }
            return original;
        }

        // Create new args array with the source argument
        var new_args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, original.args.len + 1);
        defer new_args.deinit(self.allocator);

        // Copy existing args
        for (original.args) |arg| {
            try new_args.append(self.allocator, arg);
        }

        // Capture continuation bindings from context stack
        var bindings = try std.ArrayList(ast.ScopeBinding).initCapacity(self.allocator, 4);
        defer bindings.deinit(self.allocator);

        for (self.context_stack.items) |ctx| {
            switch (ctx) {
                .in_continuation => |cont| {
                    if (cont.binding) |binding_name| {
                        // Create scope binding for this continuation variable
                        const scope_binding = ast.ScopeBinding{
                            .name = try self.allocator.dupe(u8, binding_name),
                            .type = try self.allocator.dupe(u8, "unknown"), // Type inference would go here
                            .value_ref = try self.allocator.dupe(u8, binding_name),
                        };
                        try bindings.append(self.allocator, scope_binding);
                    }
                },
                else => {},
            }
        }

        const captured_scope = ast.CapturedScope{
            .bindings = try bindings.toOwnedSlice(self.allocator),
        };

        const source_value = try self.allocator.create(ast.Source);
        source_value.* = ast.Source{
            .text = try self.allocator.dupe(u8, source_text),
            .location = self.getCurrentLocation(),
            .scope = captured_scope,
            .phantom_type = if (phantom_type) |pt| try self.allocator.dupe(u8, pt) else null,
        };

        // Add the source argument with Source value
        const source_arg = ast.Arg{
            .name = try self.allocator.dupe(u8, source_field_name),
            .value = try self.allocator.dupe(u8, source_text), // Keep string value for compatibility
            .source_value = source_value, // Add Source struct with scope
        };

        try new_args.append(self.allocator, source_arg);

        return ast.Invocation{
            .path = original.path,
            .args = try new_args.toOwnedSlice(self.allocator),
            .variant = original.variant,
        };
    }

    /// Create implicit source invocation when event is not in registry
    /// (happens during module imports when fail_fast=false)
    /// Uses default field name "source"
    fn createImplicitSourceInvocationDefault(
        self: *Parser,
        original: ast.Invocation,
        source_text: []const u8,
        phantom_type: ?[]const u8,
    ) !ast.Invocation {
        // Create new args array with the source argument
        var new_args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, original.args.len + 1);
        defer new_args.deinit(self.allocator);

        // Copy existing args
        for (original.args) |arg| {
            try new_args.append(self.allocator, arg);
        }

        // Capture continuation bindings from context stack
        var bindings = try std.ArrayList(ast.ScopeBinding).initCapacity(self.allocator, 4);
        defer bindings.deinit(self.allocator);

        for (self.context_stack.items) |ctx| {
            switch (ctx) {
                .in_continuation => |cont| {
                    if (cont.binding) |binding_name| {
                        const scope_binding = ast.ScopeBinding{
                            .name = try self.allocator.dupe(u8, binding_name),
                            .type = try self.allocator.dupe(u8, "unknown"),
                            .value_ref = try self.allocator.dupe(u8, binding_name),
                        };
                        try bindings.append(self.allocator, scope_binding);
                    }
                },
                else => {},
            }
        }

        const captured_scope = ast.CapturedScope{
            .bindings = try bindings.toOwnedSlice(self.allocator),
        };

        const source_value = try self.allocator.create(ast.Source);
        source_value.* = ast.Source{
            .text = try self.allocator.dupe(u8, source_text),
            .location = self.getCurrentLocation(),
            .scope = captured_scope,
            .phantom_type = if (phantom_type) |pt| try self.allocator.dupe(u8, pt) else null,
        };

        // Add the source argument with default name "source"
        const source_arg = ast.Arg{
            .name = try self.allocator.dupe(u8, "source"),
            .value = try self.allocator.dupe(u8, source_text),
            .source_value = source_value,
        };

        try new_args.append(self.allocator, source_arg);

        return ast.Invocation{
            .path = original.path,
            .args = try new_args.toOwnedSlice(self.allocator),
            .variant = original.variant,
        };
    }

    fn extractProcBody(self: *Parser, start: []const u8) ![]const u8 {
        var depth: i32 = 0;
        var body_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer body_lines.deinit(self.allocator);

        // First line contains the opening brace
        if (!std.mem.startsWith(u8, lexer.trim(start), "{")) {
            return error.ParseError;
        }

        // Debug: Starting extraction

        // Check if it's a single-line body
        // Look for a closing brace AFTER the opening brace
        var brace_count: i32 = 1; // We already have the opening brace
        var single_line_end: ?usize = null;
        for (start[1..], 1..) |c, idx| {
            if (c == '{') brace_count += 1;
            if (c == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    single_line_end = idx;
                    break;
                }
            }
        }

        if (single_line_end) |end_idx| {
            // Single line body - extract everything between the braces
            const body_content = lexer.trim(start[1..end_idx]);
            // Single-line body
            return try self.allocator.dupe(u8, body_content);
        }

        // Multi-line body
        depth = 1;
        // Multi-line body
        try body_lines.append(self.allocator, start[1..]); // Skip opening brace

        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            self.current += 1;

            // Processing line

            // First check if this line would close the proc
            // A proc ends when we see a closing brace that would bring depth to 0
            var temp_depth = depth;
            var in_string = false;
            var in_char = false;
            var escape_count: usize = 0; // Track consecutive backslashes
            var i: usize = 0;

            while (i < line.len) {
                const c = line[i];

                // Skip line comments: everything after // is ignored
                if (!in_string and !in_char and c == '/' and i + 1 < line.len and line[i + 1] == '/') {
                    break; // Rest of line is comment, stop processing
                }

                // Zig multiline string: a `\\` that is NOT inside a `"…"` or
                // `'…'` literal opens a raw line whose remainder is DATA, and
                // it runs to end of line exactly like `//`. Without this the
                // two backslashes cancel in `escape_count` below and every
                // brace in the string moves the depth — in a `std.fmt` format
                // string a literal `}}` then counts as TWO closes, ending the
                // proc early and spilling its tail into the enclosing module.
                // Guarded on `!in_string`/`!in_char` so `"a\\b"` and `'\\'`
                // keep their ordinary escape handling.
                if (!in_string and !in_char and c == '\\' and i + 1 < line.len and line[i + 1] == '\\') {
                    break; // Rest of line is multiline-string content
                }

                // Track escape sequences: odd number of backslashes means next char is escaped
                if (c == '\\') {
                    escape_count += 1;
                    i += 1;
                    continue;
                }
                const is_escaped = (escape_count % 2) == 1;
                escape_count = 0;

                // Handle character literals
                if (c == '\'' and !is_escaped and !in_string) {
                    in_char = !in_char;
                }
                // Handle string literals
                else if (c == '"' and !is_escaped and !in_char) {
                    in_string = !in_string;
                }
                // Count braces only when not in strings or char literals
                else if (!in_string and !in_char) {
                    if (c == '{') temp_depth += 1;
                    if (c == '}') temp_depth -= 1;
                }

                i += 1;
            }

            // Check depth change

            // If this line would make depth go to 0 or negative, the proc is ending
            if (temp_depth <= 0) {
                // Don't include the closing brace line in the body
                // The line has already been consumed (self.current was incremented)
                depth = temp_depth; // Update depth to reflect we found the closing brace
                break;
            }

            // This line is part of the proc body, include it
            // Including line in body
            try body_lines.append(self.allocator, line);
            depth = temp_depth;
        }

        if (depth != 0) {
            log_debug("ERROR: Proc body extraction failed! Final depth = {}, body_lines count = {}\n", .{ depth, body_lines.items.len });
            if (body_lines.items.len > 0) {
                log_debug("  First line: {s}\n", .{body_lines.items[0]});
                if (body_lines.items.len > 1) {
                    const last = body_lines.items[body_lines.items.len - 1];
                    log_debug("  Last line: {s}\n", .{last});
                }
            }
            try self.reporter.addError(
                .PARSE004,
                self.current,
                1,
                "unbalanced braces in proc body",
                .{},
            );
            return error.ParseError;
        }

        // Join lines with newlines
        var total_len: usize = 0;
        for (body_lines.items, 0..) |line, i| {
            total_len += line.len;
            if (i < body_lines.items.len - 1) {
                total_len += 1; // for newline
            }
        }

        if (total_len == 0) {
            return try self.allocator.dupe(u8, "");
        }

        var result = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (body_lines.items, 0..) |line, i| {
            @memcpy(result[offset..][0..line.len], line);
            offset += line.len;
            if (i < body_lines.items.len - 1) {
                result[offset] = '\n';
                offset += 1;
            }
        }

        // Return final body

        return result;
    }

    // NOTE: parseEventTapWithAnnotations and parseEventTap removed.
    // Taps are now a library feature using the transform system.
    // See koru_std/taps.kz for the ~tap() transform implementation.

    fn parseFlow(self: *Parser, annotations: [][]const u8) anyerror!ast.Flow {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing flow",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const location = self.getLineLocation(self.current, lexer.getIndent(self.lines[self.current]));
        const line = self.lines[self.current];
        const head_line_idx = self.current;
        self.current += 1;

        const trimmed = lexer.trim(line);
        const after_tilde = trimmed[1..]; // Skip ~

        // Skip past annotations if present (annotations were already parsed in parseKoruConstruct)
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            // Find the closing ] and skip past it
            if (std.mem.indexOf(u8, after_tilde, "]")) |close_pos| {
                remaining = lexer.trim(after_tilde[close_pos + 1 ..]);
            }
        }

        // Check if this uses implicit Source syntax
        // We look for patterns like:
        //   event_name {           - no args
        //   event_name() {         - empty args
        //   event_name(...) {      - with args
        //   module:event_name {    - module-qualified, no args
        //   event_name [type]"path" - file source syntax
        const trimmed_after = lexer.trim(remaining);

        // Check if it ends with { or <Type>{ - that's the marker for implicit flow/source syntax
        const has_implicit_flow_brace = std.mem.endsWith(u8, trimmed_after, "{");

        // Check if it ends with " and contains >" - that's the marker for file source syntax
        // e.g., ~print <text>"hello.md"
        const has_implicit_file_source = std.mem.endsWith(u8, trimmed_after, "\"") and
            std.mem.indexOf(u8, trimmed_after, ">\"") != null;

        var invocation: ast.Invocation = undefined;
        var uses_implicit_flow = false;
        var uses_implicit_source = false;
        var implicit_source_text: ?[]const u8 = null;
        var implicit_source_phantom_type: ?[]const u8 = null;
        var implicit_source_file_path: ?[]const u8 = null;
        var continuations: []ast.Continuation = undefined;

        if (has_implicit_file_source) {
            // Parse file source syntax: ~event <type>"path"
            // Extract: invocation before <, scope type in <...>, file path in "..."

            // Find the last >" to locate where the path starts
            const quote_start = std.mem.lastIndexOf(u8, trimmed_after, ">\"") orelse unreachable;
            const path_start = quote_start + 2; // Skip >"
            const path_end = trimmed_after.len - 1; // Exclude trailing "
            const file_path = trimmed_after[path_start..path_end];

            // Find the < to extract scope type
            const angle_start = std.mem.lastIndexOf(u8, trimmed_after[0 .. quote_start + 1], "<") orelse {
                try self.reporter.addError(.PARSE001, self.current, 0, "File source syntax requires scope type: ~tor <type>\"path\"", .{});
                return error.ParseError;
            };
            const phantom_type = trimmed_after[angle_start + 1 .. quote_start];

            // Extract invocation string (before the <)
            const invocation_str = lexer.trim(trimmed_after[0..angle_start]);
            invocation = try self.parseEventInvocation(invocation_str);
            errdefer invocation.deinit(self.allocator);

            // Read the file content
            const file_content = self.readSourceFile(file_path) catch |err| {
                try self.reporter.addError(.PARSE001, self.current, 0, "Failed to read source file '{s}': {s}", .{ file_path, @errorName(err) });
                return error.ParseError;
            };

            uses_implicit_source = true;
            implicit_source_text = file_content;
            implicit_source_phantom_type = try self.allocator.dupe(u8, phantom_type);
            implicit_source_file_path = try self.allocator.dupe(u8, file_path);

            // No multi-line block to parse, just get continuations from next lines
            continuations = try self.parseContinuations(lexer.getIndent(line));
        } else if (has_implicit_flow_brace) {
            // Parse event name and args up to the {
            const brace_idx = std.mem.lastIndexOf(u8, remaining, "{") orelse unreachable;
            const invocation_str = lexer.trim(remaining[0..brace_idx]);

            // Detect inline chain: `head() |> ... |> terminal {` where the terminal carries
            // a multi-line source block. The current branch was designed for a single
            // invocation before the `{`; for chains, the source-block decision belongs to
            // the terminal event, not the head. Reuse parsePipelineContinuationBase, which
            // already handles multi-line source blocks for new-line `|>` continuations.
            const inline_pipe_arrow = blk: {
                var i: usize = 0;
                var paren_depth: i32 = 0;
                var brace_depth: i32 = 0;
                var in_string = false;
                while (i + 1 < invocation_str.len) : (i += 1) {
                    const c = invocation_str[i];
                    if (c == '"' and (i == 0 or invocation_str[i - 1] != '\\')) {
                        in_string = !in_string;
                        continue;
                    }
                    if (in_string) continue;
                    if (c == '(') paren_depth += 1;
                    if (c == ')') paren_depth -= 1;
                    if (c == '{') brace_depth += 1;
                    if (c == '}') brace_depth -= 1;
                    if (paren_depth == 0 and brace_depth == 0 and c == '|' and invocation_str[i + 1] == '>') {
                        break :blk i;
                    }
                }
                break :blk null;
            };

            if (inline_pipe_arrow) |pipe_idx| {
                // Chain detected. Split head/tail and route tail through the same
                // continuation parser used by new-line `|>` steps.
                const head_str = lexer.trim(invocation_str[0..pipe_idx]);
                const tail_str = lexer.trim(invocation_str[pipe_idx + 2 ..]);
                const tail_with_brace = try std.fmt.allocPrint(self.allocator, "{s} {{", .{tail_str});
                defer self.allocator.free(tail_with_brace);

                invocation = try self.parseEventInvocation(head_str);
                errdefer invocation.deinit(self.allocator);

                const tail_cont = try self.parsePipelineContinuationBase(
                    tail_with_brace,
                    lexer.getIndent(line),
                    self.getCurrentLocation(),
                );

                var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                try cont_list.append(self.allocator, tail_cont);
                continuations = try cont_list.toOwnedSlice(self.allocator);
            } else {
                invocation = try self.parseEventInvocation(invocation_str);
                errdefer invocation.deinit(self.allocator);

                // Look up the event to determine if it expects Source
                const path_str = try self.pathToString(invocation.path);
                defer self.allocator.free(path_str);

                if (self.registry.getEventType(path_str)) |event_type| {
                    // Check if it has any Source parameter
                    var has_source_param = false;
                    if (event_type.input_shape) |shape| {
                        for (shape.fields) |field| {
                            if (field.is_source) {
                                has_source_param = true;
                                break;
                            }
                        }
                    }

                    if (has_source_param) {
                        // Parse as Source block (raw text) - used by both implicit flow and templates
                        uses_implicit_source = true;
                        const result = try self.parseImplicitSourceBlock(lexer.getIndent(line), null, false);
                        implicit_source_text = result.source;
                        errdefer self.allocator.free(implicit_source_text.?);
                        implicit_source_phantom_type = result.phantom_type;
                        continuations = result.continuations;
                    } else {
                        // Parse as implicit flow block (no Source parameter)
                        uses_implicit_flow = true;
                        continuations = try self.parseImplicitFlowBlock(lexer.getIndent(line));
                    }
                } else {
                    // Event not found in registry - might be a keyword that hasn't been resolved yet.
                    // Assume it takes a Source parameter (optimistic parsing).
                    // If it's truly invalid, later passes will catch it after keyword resolution.
                    uses_implicit_source = true;
                    const result = try self.parseImplicitSourceBlock(lexer.getIndent(line), null, false);
                    implicit_source_text = result.source;
                    errdefer self.allocator.free(implicit_source_text.?);
                    implicit_source_phantom_type = result.phantom_type;
                    continuations = result.continuations;
                }
            }
        } else {
            // Regular invocation (no implicit flow/source block)
            // Note: invocations ending with { are always caught by has_implicit_flow_brace
            // above, so parseEventInvocation is the only path here.
            invocation = try self.parseEventInvocation(remaining);
            errdefer invocation.deinit(self.allocator);

            // Check for invalid inline branch continuations: ~event() | branch |> _
            // Branch continuations must be on a new line - only void chaining (|>) is allowed inline
            // Look for `| ` followed by a word (not > or ?)
            // NOTE: Skip pipes inside { } braces (source blocks) and strings
            {
                var i: usize = 0;
                var brace_depth: i32 = 0;
                var in_string = false;
                while (i < remaining.len) : (i += 1) {
                    const c = remaining[i];

                    // Track string state (skip escaped quotes)
                    if (c == '"' and (i == 0 or remaining[i - 1] != '\\')) {
                        in_string = !in_string;
                        continue;
                    }

                    // Skip everything inside strings
                    if (in_string) continue;

                    // Track brace depth
                    if (c == '{') {
                        brace_depth += 1;
                        continue;
                    }
                    if (c == '}') {
                        brace_depth -= 1;
                        continue;
                    }

                    // Only check pipes at brace_depth 0 (outside source blocks)
                    if (brace_depth == 0 and c == '|' and i + 1 < remaining.len) {
                        const next_char = remaining[i + 1];
                        // |> is valid (void chaining), |? is valid (catch-all)
                        // | followed by space then word is invalid (branch must be on new line)
                        if (next_char == ' ') {
                            // Check if there's a word after the space (branch name)
                            const after_pipe = lexer.trim(remaining[i + 1 ..]);
                            if (after_pipe.len > 0 and after_pipe[0] != '>' and after_pipe[0] != '?') {
                                try self.reporter.addError(.PARSE001, self.current, @as(u16, @intCast(i)), "Branch continuation '|' must start on a new line with proper indentation", .{});
                                return error.ParseError;
                            }
                        }
                    }
                }
            }

            // Check if this line has an inline continuation (|> on same line)
            // This is needed for void event chaining: ~void_event() |> another_event()
            // Must skip |> inside string literals
            const has_inline_continuation = blk: {
                var j: usize = 0;
                var in_str = false;
                while (j < remaining.len) : (j += 1) {
                    const ch = remaining[j];
                    if (ch == '"' and (j == 0 or remaining[j - 1] != '\\')) {
                        in_str = !in_str;
                        continue;
                    }
                    if (!in_str and ch == '|' and j + 1 < remaining.len and remaining[j + 1] == '>') {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            if (has_inline_continuation) {
                // Parse inline continuation from the same line
                continuations = try self.parseInlineContinuation(remaining, lexer.getIndent(line), head_line_idx);
            } else {
                // Parse regular multi-line continuations
                continuations = try self.parseContinuations(lexer.getIndent(line));
            }
        }

        // Check if this is an invocation of an implicit flow event
        const path_str = try self.pathToString(invocation.path);
        defer self.allocator.free(path_str);

        var final_invocation = invocation;
        var final_continuations = continuations;

        if (uses_implicit_flow) {
            // With {} syntax, we need to separate flow items from output continuations
            // and create the synthetic flow parameter
            if (self.registry.getEventType(path_str)) |event_type| {
                // Separate flow items from output continuations
                var flow_ast_items = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 4);
                var output_items = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 4);
                defer flow_ast_items.deinit(self.allocator);
                defer output_items.deinit(self.allocator);

                for (continuations) |cont| {
                    if (std.mem.eql(u8, cont.branch, "<flow_ast_item>")) {
                        try flow_ast_items.append(self.allocator, cont);
                    } else {
                        try output_items.append(self.allocator, cont);
                    }
                }

                // Create synthetic invocation with flow parameter
                final_invocation = try self.createImplicitFlowInvocation(invocation, try flow_ast_items.toOwnedSlice(self.allocator), event_type);

                // Use only the output continuations
                final_continuations = try output_items.toOwnedSlice(self.allocator);
            }
        } else if (uses_implicit_source) {
            // With {} syntax and Source parameter, add the captured text as source parameter
            if (self.registry.getEventType(path_str)) |event_type| {
                final_invocation = try self.createImplicitSourceInvocation(invocation, implicit_source_text.?, implicit_source_phantom_type, event_type);
                // continuations are already the output continuations from parseImplicitSourceBlock
            } else {
                // Event not in registry (happens during module imports when fail_fast=false)
                // Add source parameter with default name "source"
                final_invocation = try self.createImplicitSourceInvocationDefault(invocation, implicit_source_text.?, implicit_source_phantom_type);
            }
            self.allocator.free(implicit_source_text.?);
        } else if (self.registry.getEventType(path_str)) |event_type| {
            if (event_type.is_implicit_flow) {
                // Regular syntax - continuations become flow parameter
                final_invocation = try self.createImplicitFlowInvocation(invocation, continuations, event_type);
            }
        }

        // Duplicate annotations for the Flow (caller will free the original annotations)
        var flow_annotations = try self.allocator.alloc([]const u8, annotations.len);
        for (annotations, 0..) |ann, i| {
            flow_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        // createImplicit* shallow-copies args into a new slice; drop the orphaned local slice
        // (and any variant not carried over) without freeing shared arg payloads.
        if (final_invocation.args.ptr != invocation.args.ptr and invocation.args.len > 0) {
            self.allocator.free(@constCast(invocation.args));
        }
        if (invocation.variant) |v| {
            if (final_invocation.variant == null or !std.mem.eql(u8, final_invocation.variant.?, v)) {
                self.allocator.free(v);
            }
        }

        return ast.Flow{
            .body = ast.rootSite(final_invocation, final_continuations, location),
            .annotations = flow_annotations,
            .pre_label = null, // Pre-label is handled in parseLabelAnchor
            .super_shape = null, // Will be set later for inline flows
            .location = location,
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }

    /// Check if content has an unescaped escape sequence like \n or \t
    /// Returns false for \\n (escaped backslash + n) which is valid in paths

    fn looksLikeZigCode(self: *Parser, content: []const u8) bool {
        _ = self;
        // Detect patterns that indicate Zig code rather than Koru event invocations
        // Note: We allow .{} and @as in ARGUMENTS — paren args (Expression
        // fields) and bare source blocks alike (`capture { total: @as(i32, 0) }`).
        // Both are data carried by the invocation, not flow plumbing. So the
        // check range stops at the first `(` OR `{`, whichever comes first.

        const paren_start = std.mem.indexOf(u8, content, "(");
        const brace_start = std.mem.indexOf(u8, content, "{");
        const args_start = if (paren_start) |p|
            (if (brace_start) |b| @min(p, b) else p)
        else
            brace_start;
        const check_range = if (args_start) |idx| content[0..idx] else content;

        // Check for @import, @as, etc. at the TOP LEVEL (not inside args)
        // This allows ~capture { total: @as(i32, 0) } while blocking ~@as(...)
        if (std.mem.indexOf(u8, check_range, "@import") != null or
            std.mem.indexOf(u8, check_range, "@as") != null or
            std.mem.indexOf(u8, check_range, "@field") != null)
        {
            return true;
        }

        // Check for print patterns with format strings and tuple args
        // Only flag these at TOP LEVEL (before first paren), not inside args
        // This allows valid event names like ~std.log() while blocking actual Zig logging
        if (std.mem.indexOf(u8, check_range, "log_debug(") != null or
            std.mem.indexOf(u8, check_range, "std.log.") != null or
            std.mem.indexOf(u8, check_range, "std.debug.") != null)
        {
            return true;
        }

        // NOTE: we deliberately do NOT flag string literals containing `\n`/`\t`
        // escapes. A string with an escape sequence is perfectly valid Koru — it
        // is just a string passed to an event (`print.ln("a\nb")`). The old
        // heuristic here rejected any positional string arg with `\n`/`\t` as
        // "Zig code", a false positive that keyed args (`print(text: "a\nb")`)
        // happened to dodge (it only matched `("`). Real Zig (`std.debug.print`,
        // `@import`, `@as`) is already caught by the checks above; an escape
        // sequence on its own is not evidence of host code. Regression:
        // 010_007_string_escape_in_flow_arg.

        return false;
    }

    fn parseFlowAstOrSourceArg(self: *Parser, field_name: []const u8, start_line: usize) anyerror!ast.Arg {
        // We're at a line like "field: {"
        // Need to consume lines until we find the closing }
        var content_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer content_lines.deinit(self.allocator);

        // Track the indentation of the closing brace
        var closing_brace_indent: ?usize = null;
        var start_idx = start_line + 1; // Start from line after the opening {

        while (start_idx < self.lines.len) : (start_idx += 1) {
            const line = self.lines[start_idx];
            const trimmed = lexer.trim(line);

            // Check if this line is just a closing brace
            if (std.mem.eql(u8, trimmed, "}") or std.mem.endsWith(u8, trimmed, "},")) {
                // Found the closing brace - record its indentation
                closing_brace_indent = lexer.getIndent(line);
                self.current = start_idx + 1; // Move past the closing brace
                break;
            }

            // Otherwise, this line is part of the content
            try content_lines.append(self.allocator, line);
        }

        // Now dedent the content based on the closing brace position
        const dedent_amount = closing_brace_indent orelse 0;
        var final_content = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer final_content.deinit(self.allocator);

        for (content_lines.items, 0..) |line, i| {
            if (i > 0) try final_content.appendSlice(self.allocator, "\n");

            // Remove dedent_amount spaces from the beginning
            const line_indent = lexer.getIndent(line);
            const start_pos = @min(dedent_amount, line_indent);
            try final_content.appendSlice(self.allocator, line[start_pos..]);
        }

        const string_value = try final_content.toOwnedSlice(self.allocator);

        return ast.Arg{
            .name = try self.allocator.dupe(u8, field_name),
            .value = string_value,
        };
    }

    fn parseEventInvocation(self: *Parser, line: []const u8) anyerror!ast.Invocation {
        // Parse event invocation
        // Strip any `@label` jump anchor before parsing the invocation.
        var clean = lexer.withoutLabel(line);
        log_debug("[DEBUG] parseEventInvocation: input='{s}'\n", .{clean});

        // `/` is the sole namespace separator; reject the old `.`-namespace form.
        try self.rejectDotNamespace(clean, self.current);

        // Detect Zig code patterns and report error
        if (self.looksLikeZigCode(clean)) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "Zig code not allowed in flows. Flows are pure plumbing - use events for computation.",
                .{},
            );
            return error.ZigCodeInFlow;
        }
        // `~event(args): b |> ...`: bind the event's single `-> T` return value to
        // `b`, then continue with `|>`. The bind colon is the top-level `:` right
        // after the call's `)` (arg colons live inside the parens; a module
        // qualifier's `:` precedes the `(`). Strip `: b` so the rest of this parser
        // sees a plain `event(args) |> ...`, and stash the binding.
        var return_binding: ?[]const u8 = null;
        var return_binding_annotations: []const []const u8 = &[_][]const u8{};
        var return_destructure: []const ast.DestructureField = &.{};
        var stitched_clean: ?[]const u8 = null;
        defer if (stitched_clean) |s| self.allocator.free(s);
        bind_colon: {
            var depth: i32 = 0;
            var idx: usize = 0;
            var in_str = false;
            var seen_open = false;
            var close_paren: ?usize = null;
            while (idx < clean.len) : (idx += 1) {
                const c = clean[idx];
                if (c == '"' and (idx == 0 or clean[idx - 1] != '\\')) {
                    in_str = !in_str;
                    continue;
                }
                if (in_str) continue;
                if (c == '(') {
                    depth += 1;
                    seen_open = true;
                } else if (c == ')') {
                    depth -= 1;
                    if (depth == 0 and seen_open) {
                        close_paren = idx;
                        break;
                    }
                }
            }
            if (close_paren) |cp| {
                var j = cp + 1;
                while (j < clean.len and (clean[j] == ' ' or clean[j] == '\t')) : (j += 1) {}
                if (j < clean.len and clean[j] == ':') {
                    var k = j + 1;
                    while (k < clean.len and (clean[k] == ' ' or clean[k] == '\t')) : (k += 1) {}
                    // Bind-position shape-destructure: `~f(): { pos: { x }, label } |> ...`
                    // Brace-balance from `{`, parse the field list (same machinery as
                    // the branch-payload destructure), bind the return to a synthetic
                    // temp, and stitch out `: { ... }` so the rest sees a plain call.
                    if (k < clean.len and clean[k] == '{') {
                        var bdepth: i32 = 0;
                        var b = k;
                        var brace_end: ?usize = null;
                        while (b < clean.len) : (b += 1) {
                            if (clean[b] == '{') bdepth += 1;
                            if (clean[b] == '}') {
                                bdepth -= 1;
                                if (bdepth == 0) {
                                    brace_end = b;
                                    break;
                                }
                            }
                        }
                        const be = brace_end orelse {
                            try self.reporter.addError(
                                .PARSE001,
                                self.current,
                                0,
                                "unclosed '{{' in bind-position destructure (e.g. `~f(): {{ x, y }} |> ...`)",
                                .{},
                            );
                            return error.ParseError;
                        };
                        return_destructure = try self.parseDestructureFields(lexer.trim(clean[k + 1 .. be]), 0);
                        const temp_name = try std.fmt.allocPrint(self.allocator, "__ret_destr_{d}", .{self.destructure_ret_counter});
                        self.destructure_ret_counter += 1;
                        return_binding = temp_name;
                        const before_colon = lexer.trim(clean[0..j]);
                        const after = lexer.trim(clean[be + 1 ..]); // "|> ..." or ""
                        const stitched = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ before_colon, after });
                        stitched_clean = stitched;
                        clean = stitched;
                        break :bind_colon;
                    }
                    var name_end = k;
                    while (name_end < clean.len and
                        (std.ascii.isAlphanumeric(clean[name_end]) or
                            clean[name_end] == '_' or clean[name_end] == '-')) : (name_end += 1)
                    {}
                    if (name_end == k) {
                        try self.reporter.addError(
                            .PARSE001,
                            self.current,
                            0,
                            "expected a binding name after `:` (e.g. `~greet(...): result |> ...`)",
                            .{},
                        );
                        return error.ParseError;
                    }
                    return_binding = try self.allocator.dupe(u8, clean[k..name_end]);
                    // Optional binding annotations: `: r[mutable]` — the call-site twin
                    // of the branch-bind `| result r[mutable]` form. Capture them so the
                    // emitter can honor `[mutable]` (bind `var`, not `const`).
                    var rest_start = name_end;
                    if (name_end < clean.len and clean[name_end] == '[') {
                        const ann_close = std.mem.indexOfScalarPos(u8, clean, name_end, ']') orelse {
                            try self.reporter.addError(
                                .PARSE001,
                                self.current,
                                0,
                                "unterminated binding annotation; expected `]` (e.g. `~greet(...): r[mutable] |> ...`)",
                                .{},
                            );
                            return error.ParseError;
                        };
                        const inner = clean[name_end + 1 .. ann_close];
                        var ann_list = try std.ArrayList([]const u8).initCapacity(self.allocator, 2);
                        errdefer {
                            for (ann_list.items) |a| self.allocator.free(@constCast(a));
                            ann_list.deinit(self.allocator);
                        }
                        var ann_it = std.mem.splitScalar(u8, inner, ',');
                        while (ann_it.next()) |tok| {
                            const t = lexer.trim(tok);
                            if (t.len == 0) continue;
                            try ann_list.append(self.allocator, try self.allocator.dupe(u8, t));
                        }
                        return_binding_annotations = try ann_list.toOwnedSlice(self.allocator);
                        rest_start = ann_close + 1;
                    }
                    const before_colon = lexer.trim(clean[0..j]);
                    const rest = lexer.trim(clean[rest_start..]); // "|> ..." or ""
                    const stitched = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ before_colon, rest });
                    stitched_clean = stitched;
                    clean = stitched;
                }
            }
        }
        errdefer if (return_binding) |rb| self.allocator.free(rb);
        errdefer {
            for (return_binding_annotations) |a| self.allocator.free(@constCast(a));
            if (return_binding_annotations.len > 0) self.allocator.free(@constCast(return_binding_annotations));
        }

        // A top-level `->` with NO preceding `:` bind is the abandoned stray form
        // (`event() -> v`) — reject with the migration hint. A `->` that FOLLOWS a
        // `: bind` is the produce arm (`event(): v -> expr`), the twin of
        // `: v => construct`; it's handled below as a bare-return continuation, so
        // let it through. (The bind-strip above leaves the `-> expr` on `clean`.)
        //
        // `return_binding` is the HEAD call's bind, and the scan above only looks
        // just past the head's `)`. In a chain the bind that owns the arrow may sit
        // on a LATER step (`a() |> b() |> c(): v -> v`), where the head has none.
        // So the question is not whether this line is a chain — it is whether ANY
        // bind stands between the start of the line and the arrow. A chain with no
        // bind at all (`a() |> b() -> v`) is the stray form exactly as much as
        // `a() -> v` is: `v` names nothing either way, and letting it through
        // hands the host an undeclared identifier in generated code (210_184).
        if (return_binding == null) {
            if (indexOfTopLevelArrow(clean)) |arrow_at| {
                const bound_before_arrow = if (indexOfTopLevelBindColon(clean)) |bind_at|
                    bind_at < arrow_at
                else
                    false;
                if (!bound_before_arrow) {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        0,
                        "bind a result with `:` not `->` (e.g. `~greet(...): result |> ...`) — `->` is the produce glyph",
                        .{},
                    );
                    return error.ParseError;
                }
            }
        }

        // Find the first pipe that's not inside parentheses or braces
        var pipe_idx: ?usize = null;
        var paren_depth: i32 = 0;
        var brace_depth: i32 = 0;
        var in_string = false;
        var i: usize = 0;
        while (i < clean.len) : (i += 1) {
            const c = clean[i];
            if (c == '"' and (i == 0 or clean[i - 1] != '\\')) {
                in_string = !in_string;
            } else if (!in_string) {
                if (c == '(') paren_depth += 1;
                if (c == ')') paren_depth -= 1;
                if (c == '{') brace_depth += 1;
                if (c == '}') brace_depth -= 1;
                if (c == '|' and paren_depth == 0 and brace_depth == 0 and i > 0 and clean[i - 1] == ' ') {
                    pipe_idx = i - 1; // Point to the space before the pipe
                    break;
                }
            }
        }

        const invocation_part_full = if (pipe_idx) |idx|
            clean[0..idx]
        else
            clean;

        // The invocation HEAD ends at the first top-level construct/produce arrow
        // (`=> ctor` / `-> expr`). A bare-return bind (`head(): r => final { r }`)
        // leaves the arrow tail glued onto `clean` after the `: r` strip; the
        // caller re-parses that tail into a continuation, so the head parse must
        // stop at the arrow. Without this, the braced constructor payload's `{`
        // trips the source-block detection below and hijacks the parse — freeing
        // the head's args into an undefined AST (SIGSEGV in the serializer;
        // pinned by 100_085). The braceless twin has no `{` and never hit it.
        const invocation_part = if (indexOfTopLevelHeadArrow(invocation_part_full)) |he|
            lexer.trim(invocation_part_full[0..he])
        else
            invocation_part_full;

        // Check for Source block syntax: eventName <Type>{ ... }
        const source_block_marker = std.mem.indexOf(u8, invocation_part, ">{");
        log_debug("[DEBUG] parseEventInvocation: source_block_marker={?d} invocation_part='{s}'\n", .{ source_block_marker, invocation_part });

        if (source_block_marker) |marker_idx| {
            // Find the opening < by searching backwards from >{
            const angle_idx = std.mem.lastIndexOf(u8, invocation_part[0 .. marker_idx + 1], "<");

            if (angle_idx) |a_idx| {
                // This is a Source block invocation!
                const before_angle = lexer.trim(invocation_part[0..a_idx]);

                // Extract scope type from <Type> (we know > is at marker_idx)
                const phantom_type = lexer.trim(invocation_part[a_idx + 1 .. marker_idx]);

                // Extract block content from { ... } (marker_idx + 1 points to { position + 1)
                const brace_start = marker_idx + 1; // Position of {
                const close_brace_idx = lexer.findMatchingBrace(invocation_part, brace_start);
                if (close_brace_idx == null) {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        0,
                        "Source block missing closing brace",
                        .{},
                    );
                    return error.ParseError;
                }

                const source_text = lexer.trim(invocation_part[brace_start + 1 .. close_brace_idx.?]);

                // Check if before_angle has args: event(args)
                // If so, parse path and args separately
                var parsed_path: ast.DottedPath = undefined;
                var existing_args: []const ast.Arg = &[_]ast.Arg{};

                if (std.mem.indexOf(u8, before_angle, "(")) |paren_idx| {
                    // Has args - extract path and parse args
                    const event_name = lexer.trim(before_angle[0..paren_idx]);
                    parsed_path = try lexer.parseQualifiedPath(self.allocator, event_name, ast);

                    // Parse arguments from (...)
                    const args_str = lexer.trim(before_angle[paren_idx..]);
                    var args_list = try std.ArrayList(ast.Arg).initCapacity(self.allocator, 4);
                    defer args_list.deinit(self.allocator);

                    // Find content between ( and )
                    if (args_str.len > 2 and args_str[0] == '(' and args_str[args_str.len - 1] == ')') {
                        const args_content = args_str[1 .. args_str.len - 1];
                        // Simple arg parsing: split by comma, then by colon
                        var arg_iter = std.mem.tokenizeScalar(u8, args_content, ',');
                        while (arg_iter.next()) |arg_part| {
                            const trimmed_arg = lexer.trim(arg_part);
                            if (std.mem.indexOf(u8, trimmed_arg, ":")) |colon_idx| {
                                const name = lexer.trim(trimmed_arg[0..colon_idx]);
                                const value = lexer.trim(trimmed_arg[colon_idx + 1 ..]);
                                try args_list.append(self.allocator, ast.Arg{
                                    .name = try self.allocator.dupe(u8, name),
                                    .value = try self.allocator.dupe(u8, value),
                                });
                            }
                        }
                    }
                    existing_args = try args_list.toOwnedSlice(self.allocator);
                } else {
                    // No args - just parse the path
                    parsed_path = try lexer.parseQualifiedPath(self.allocator, before_angle, ast);
                }

                // Build path string for registry lookup
                const path_str = try self.pathToString(parsed_path);
                defer self.allocator.free(path_str);

                // Look up event type
                log_debug("[DEBUG] parseEventInvocation: path_str='{s}' existing_args.len={d} source_text='{s}'\n", .{ path_str, existing_args.len, source_text });
                if (self.registry.getEventType(path_str)) |event_type| {
                    log_debug("[DEBUG] parseEventInvocation: event found in registry, calling createImplicitSourceInvocation\n", .{});
                    // Create base invocation with existing args
                    const base_invocation = ast.Invocation{
                        .path = parsed_path,
                        .args = existing_args,
                    };

                    // Create invocation with implicit Source parameter added
                    return try self.createImplicitSourceInvocation(base_invocation, source_text, phantom_type, event_type);
                } else {
                    // Event not found in registry - use default source param name "source"
                    log_debug("[DEBUG] parseEventInvocation: event NOT in registry, adding source with default name\n", .{});

                    // Create new args with source
                    var new_args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, existing_args.len + 1);
                    defer new_args.deinit(self.allocator);

                    // Copy existing args
                    for (existing_args) |arg| {
                        try new_args.append(self.allocator, arg);
                    }

                    // Create Source value
                    const source_value = try self.allocator.create(ast.Source);
                    const duped_phantom = if (phantom_type.len > 0) try self.allocator.dupe(u8, phantom_type) else null;
                    source_value.* = ast.Source{
                        .text = try self.allocator.dupe(u8, source_text),
                        .location = self.getCurrentLocation(),
                        .scope = ast.CapturedScope{ .bindings = &[_]ast.ScopeBinding{} },
                        .phantom_type = duped_phantom,
                    };

                    // Add source arg
                    try new_args.append(self.allocator, ast.Arg{
                        .name = try self.allocator.dupe(u8, "source"),
                        .value = try self.allocator.dupe(u8, source_text),
                        .source_value = source_value,
                    });

                    return ast.Invocation{
                        .path = parsed_path,
                        .args = try new_args.toOwnedSlice(self.allocator),
                    };
                }
            }
        }

        // Check for bare source block: eventName { ... } (no type annotation)
        // Must check BEFORE regular invocation parsing
        const bare_brace_idx = findTopLevelBrace(invocation_part);
        if (bare_brace_idx != null) {
            const b_idx = bare_brace_idx.?;
            const before_brace = lexer.trim(invocation_part[0..b_idx]);

            // Find the closing brace
            const close_brace_idx = lexer.findMatchingBrace(invocation_part, b_idx);
            if (close_brace_idx == null) {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "Source block missing closing brace",
                    .{},
                );
                return error.ParseError;
            }

            const source_text = lexer.trim(invocation_part[b_idx + 1 .. close_brace_idx.?]);

            // Parse the base invocation (before the brace) via the normal path so that
            // expr-remapping, expression_value capture, and all other arg processing
            // happens correctly. before_brace has no { so this won't recurse.
            var base_invocation = try self.parseEventInvocation(before_brace);
            errdefer base_invocation.deinit(self.allocator);

            // Build path string for registry lookup
            const path_str = try self.pathToString(base_invocation.path);
            defer self.allocator.free(path_str);

            // Look up event type
            if (self.registry.getEventType(path_str)) |event_type| {
                // Create invocation with implicit Source parameter (no phantom type)
                const result = try self.createImplicitSourceInvocation(base_invocation, source_text, null, event_type);
                if (base_invocation.args.len > 0) {
                    self.allocator.free(@constCast(base_invocation.args));
                }
                return result;
            } else {
                // Event not found in registry - create source arg manually
                var args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, base_invocation.args.len + 1);
                for (base_invocation.args) |arg| {
                    try args.append(self.allocator, arg);
                }
                const source_obj = try self.allocator.create(ast.Source);
                source_obj.* = ast.Source{
                    .text = try self.allocator.dupe(u8, source_text),
                    .location = self.getCurrentLocation(),
                    .phantom_type = null,
                    .scope = ast.CapturedScope{ .bindings = &[_]ast.ScopeBinding{} },
                };
                try args.append(self.allocator, ast.Arg{
                    .name = try self.allocator.dupe(u8, "source"),
                    .value = try self.allocator.dupe(u8, source_text),
                    .source_value = source_obj,
                });
                if (base_invocation.args.len > 0) {
                    self.allocator.free(@constCast(base_invocation.args));
                }
                return ast.Invocation{
                    .path = base_invocation.path,
                    .args = try args.toOwnedSlice(self.allocator),
                    .variant = base_invocation.variant,
                };
            }
        }

        // Regular invocation without Source block
        // Find arguments in just the invocation part
        const paren_idx = std.mem.indexOf(u8, invocation_part, "(");

        const raw_path_str = if (paren_idx) |idx|
            lexer.trim(invocation_part[0..idx])
        else
            lexer.trim(invocation_part);

        // Check for |variant suffix (e.g., "blur|gpu" or "compute|zig[optimized]")
        // Note: variants use [] not () for parameterization to avoid ambiguity with args
        var variant: ?[]const u8 = null;
        var path_str = raw_path_str;

        if (std.mem.indexOfScalar(u8, raw_path_str, '|')) |variant_pipe_idx| {
            // Split at pipe: path before, variant after
            path_str = lexer.trim(raw_path_str[0..variant_pipe_idx]);
            const variant_str = lexer.trim(raw_path_str[variant_pipe_idx + 1 ..]);
            if (variant_str.len > 0) {
                variant = try self.allocator.dupe(u8, variant_str);
            }
        }
        errdefer if (variant) |v| self.allocator.free(v);

        var parsed_path = try lexer.parseQualifiedPath(self.allocator, path_str, ast);
        errdefer parsed_path.deinit(self.allocator);

        // Parse arguments if present
        var args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, 8);
        defer args.deinit(self.allocator);

        if (paren_idx) |idx| {
            // Find the matching closing parenthesis for this opening one.
            // QUOTE-AWARE: parens inside string/char literals ("(" / '(') are
            // text, not structure — a quote-blind scan loses `if(c == '(')`
            // (pinned by 210_122). Backslash escapes honored inside quotes.
            var depth: usize = 1;
            var args_end = idx + 1;
            var quote: u8 = 0; // 0 = not in a literal; otherwise the delimiter
            while (args_end < invocation_part.len and depth > 0) : (args_end += 1) {
                const ch = invocation_part[args_end];
                if (quote != 0) {
                    if (ch == '\\') {
                        args_end += 1; // skip the escaped char
                    } else if (ch == quote) {
                        quote = 0;
                    }
                    continue;
                }
                switch (ch) {
                    '"', '\'' => quote = ch,
                    '(' => depth += 1,
                    ')' => depth -= 1,
                    else => {},
                }
            }

            if (depth != 0) {
                // Unbalanced args are a USER error — never silently drop them
                // (the old behavior compiled `if(c == '(')` with EMPTY args).
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "unbalanced parentheses in invocation arguments",
                    .{},
                );
                return error.ParseError;
            }

            if (depth == 0) {
                const args_str = invocation_part[idx..args_end];
                const parsed_args = try self.parseArgsReported(args_str);
                defer self.allocator.free(parsed_args);

                try self.checkRedundantPunning(parsed_args, self.current);

                // Transfer ownership of the strings to the AST
                for (parsed_args) |arg| {
                    // Reject Zig-style struct syntax in parameter values: name: .{ .field = value }
                    // Koru uses named parameters: name: value — not anonymous struct literals
                    if (lexer.startsWith(arg.value, ".{")) {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current,
                            1,
                            "Zig-style struct syntax '.{{' is not valid in Koru parameter values — pass fields as named parameters instead",
                            .{},
                        );
                        return error.ParseError;
                    }

                    var ast_arg = ast.Arg{
                        .name = arg.name,
                        .value = arg.value,
                        .phantom_type = arg.phantom_type,
                        .had_explicit_label = arg.had_explicit_label,
                    };
                    tryParseArgExpression(self.allocator, &ast_arg);
                    try args.append(self.allocator, ast_arg);
                }
            }
        }

        // Handle implicit `expr` parameter for Expression fields
        // Similar to how `source` works for Source fields
        if (args.items.len > 0) {
            const full_path_str = try self.pathToString(parsed_path);
            defer self.allocator.free(full_path_str);

            if (self.registry.getEventType(full_path_str)) |event_type| {
                if (event_type.input_shape) |input_shape| {
                    // Find if there's an 'expr' field with is_expression=true
                    var has_implicit_expr = false;
                    for (input_shape.fields) |field| {
                        if (std.mem.eql(u8, field.name, "expr") and field.is_expression) {
                            has_implicit_expr = true;
                            break;
                        }
                    }

                    if (has_implicit_expr) {
                        // Check each arg - if its name doesn't match any field, remap to 'expr'
                        // This handles Expression params where the lexer extracted a partial name
                        // from dotted expressions (e.g., "d.value > 10" -> name="value > 10")
                        // Only ONE arg can be implicitly mapped to 'expr'
                        var remapped_expr = false;
                        for (args.items) |*arg| {
                            if (remapped_expr) break;
                            // Skip if already explicitly named 'expr'
                            if (std.mem.eql(u8, arg.name, "expr")) continue;

                            // Check if this arg name matches any field in the event
                            var matches_field = false;
                            for (input_shape.fields) |field| {
                                if (std.mem.eql(u8, field.name, arg.name)) {
                                    matches_field = true;
                                    break;
                                }
                            }

                            if (!matches_field) {
                                // Arg doesn't match any field - remap to implicit 'expr' parameter
                                self.allocator.free(arg.name);
                                arg.name = try self.allocator.dupe(u8, "expr");
                                remapped_expr = true;
                            }
                        }
                    }

                    // Now capture scope for any Expression args
                    for (args.items) |*arg| {
                        // Check if this arg matches an is_expression field
                        for (input_shape.fields) |field| {
                            if (std.mem.eql(u8, field.name, arg.name) and field.is_expression) {
                                // Capture scope bindings from context stack
                                var bindings = try std.ArrayList(ast.ScopeBinding).initCapacity(self.allocator, 4);
                                defer bindings.deinit(self.allocator);

                                for (self.context_stack.items) |ctx| {
                                    switch (ctx) {
                                        .in_continuation => |cont| {
                                            if (cont.binding) |binding_name| {
                                                const scope_binding = ast.ScopeBinding{
                                                    .name = try self.allocator.dupe(u8, binding_name),
                                                    .type = try self.allocator.dupe(u8, "unknown"),
                                                    .value_ref = try self.allocator.dupe(u8, binding_name),
                                                };
                                                try bindings.append(self.allocator, scope_binding);
                                            }
                                        },
                                        else => {},
                                    }
                                }

                                const captured_scope = ast.CapturedScope{
                                    .bindings = try bindings.toOwnedSlice(self.allocator),
                                };

                                const expression_value = try self.allocator.create(ast.CapturedExpression);
                                expression_value.* = ast.CapturedExpression{
                                    .text = try self.allocator.dupe(u8, arg.value),
                                    .location = self.getCurrentLocation(),
                                    .scope = captured_scope,
                                };

                                arg.expression_value = expression_value;
                                break;
                            }
                        }
                    }
                }
            }
        }

        const result_invocation = ast.Invocation{
            .path = parsed_path,
            .args = try args.toOwnedSlice(self.allocator),
            .variant = variant,
            .return_binding = return_binding,
            .return_binding_annotations = return_binding_annotations,
            .return_destructure = return_destructure,
        };
        return_binding = null; // ownership transferred; disarm the errdefer
        return_binding_annotations = &[_][]const u8{}; // ownership transferred; disarm the errdefer
        return_destructure = &.{}; // ownership transferred
        return result_invocation;
    }

    // Parses ~event = ... syntax. Returns either:
    //   Item{ .immediate_impl = ... } for branch constructor bodies
    //   Item{ .flow = Flow{ .impl_of = event_path, ... } } for flow bodies
    /// Duplicate caller-owned annotations for attachment to a produced item
    /// (the caller frees its originals after the parse call returns).
    fn dupeAnnotations(self: *Parser, annotations: [][]const u8) ![]const []const u8 {
        if (annotations.len == 0) return &.{};
        const out = try self.allocator.alloc([]const u8, annotations.len);
        for (annotations, 0..) |ann, i| out[i] = try self.allocator.dupe(u8, ann);
        return out;
    }

    fn parseSubflowImpl(self: *Parser, annotations: [][]const u8) !ast.Item {
        // Indent of the definition line, captured before the body consumes it.
        // In a `.k` the top-level loop has already rewritten this line as
        // `~<trimmed>`, so it reads 0 — which is what a top-level construct's
        // indent is anyway.
        const def_indent = if (self.current < self.lines.len)
            lexer.getIndent(self.lines[self.current])
        else
            0;
        var item = try self.parseSubflowImplBody(annotations);
        self.rejectStrayIndentedBodyLine(def_indent) catch |err| {
            item.deinit(self.allocator);
            return err;
        };
        return item;
    }

    /// The line sitting where a continuation would sit — indented under a
    /// subflow definition — but carrying no continuation glyph. Koru sequences
    /// a body with `|>`; listing statements is not a body form, so nothing
    /// claims this line.
    ///
    /// Unclaimed, it is silently REHOMED: a `.k` promotes it to a top-level
    /// construct (it runs at program start, not when the subflow is called), a
    /// `.kz` hands it to the host verbatim (it surfaces later as a Zig parse
    /// error pointing at generated code). Both spellings lose the author's line.
    /// Refuse it here instead, at the line as written.
    fn rejectStrayIndentedBodyLine(self: *Parser, def_indent: usize) !void {
        if (self.current >= self.lines.len) return;
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);
        // A blank line closes the body; a comment is the chain-comment rule's
        // business (KORU010, rejectChainSplittingComment).
        if (trimmed.len == 0) return;
        if (lexer.isCommentLine(line)) return;
        // Not indented INTO the body — it is a sibling construct, which is legal.
        if (lexer.getIndent(line) <= def_indent) return;
        // `|`, `|>` and `!` are continuation glyphs: parseContinuations took
        // every one it recognised, and rejects the rest with its own diagnostic.
        // `~` re-enters Koru explicitly and opens a construct of its own.
        if (trimmed[0] == '|' or trimmed[0] == '!' or trimmed[0] == '~') return;
        try self.reporter.addErrorWithHint(
            .KORU010,
            self.current + 1,
            lexer.getIndent(line) + 1,
            "line is indented into a subflow body but is not a continuation of it",
            .{},
            "Koru sequences a body with `|>`, not by listing lines. Chain it onto the step above (`… |> {s}`), or dedent it so it reads as the separate flow it would otherwise silently become.",
            .{trimmed},
        );
        return error.ParseError;
    }

    fn parseSubflowImplBody(self: *Parser, annotations: [][]const u8) !ast.Item {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing subflow implementation",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const line = self.lines[self.current];
        const head_line_idx = self.current;
        self.current += 1;

        // Parse: ~event.name = ... or ~module:event = ...
        var after_tilde = lexer.trim(line[1..]);

        // Skip past a leading annotation block — the caller (parseKoruConstruct)
        // already parsed it and hands it in via `annotations`. Without this skip
        // the bracket text leaks INTO the impl path segment (`~[comptime]
        // countdown = ...` registered the subflow as "[comptime] countdown"),
        // mangling the name every later resolution looks up.
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            if (std.mem.indexOf(u8, after_tilde, "]")) |close_pos| {
                after_tilde = lexer.trim(after_tilde[close_pos + 1 ..]);
            }
        }

        // `~event -> expr` : bare-return impl (the `->` twin of `=>`). Returns the
        // event's single unnamed `-> T` value directly — no branch name, no tag.
        if (findTopLevelEquals(after_tilde) == null) {
            if (indexOfTopLevelArrow(after_tilde)) |arrow_idx| {
                const ep_str = lexer.trim(after_tilde[0..arrow_idx]);
                const expr = lexer.trim(after_tilde[arrow_idx + 2 ..]);
                if (expr.len == 0) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current,
                        1,
                        "bare-return impl requires an expression after `->` (e.g. `~double -> a * 2`)",
                        .{},
                    );
                    return error.InvalidSyntax;
                }
                var ep = try lexer.parseQualifiedPath(self.allocator, ep_str, ast);
                errdefer ep.deinit(self.allocator);
                return ast.Item{ .immediate_impl = .{
                    .event_path = ep,
                    .value = .{
                        .branch_name = try self.allocator.dupe(u8, ""),
                        .fields = &.{},
                        .plain_value = try self.allocator.dupe(u8, expr),
                        .has_expressions = true,
                        .is_bare_return = true,
                    },
                    .annotations = try self.dupeAnnotations(annotations),
                    .location = self.getCurrentLocation(),
                    .module = try self.allocator.dupe(u8, self.module_name),
                    .is_impl = ep.module_qualifier != null,
                } };
            }
        }

        const eq_idx = findTopLevelEquals(after_tilde) orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "subflow implementation requires '=' (e.g., ~greet = delegate())",
                .{},
            );
            return error.InvalidSyntax;
        };

        const raw_event_path_str = lexer.trim(after_tilde[0..eq_idx]);

        // Split off optional |variant suffix (e.g. ~greet|en = ...). Variant is
        // a property of this subflow declaration — symmetric with proc-side
        // |variant tags, lives on Flow.impl_variant on the AST side.
        const variant_pipe_idx = lexer.findTopLevelVariantPipe(raw_event_path_str);
        const event_path_str = if (variant_pipe_idx) |i|
            lexer.trim(raw_event_path_str[0..i])
        else
            raw_event_path_str;
        const impl_variant: ?[]const u8 = if (variant_pipe_idx) |i|
            try self.allocator.dupe(u8, lexer.trim(raw_event_path_str[i + 1 ..]))
        else
            null;

        const event_path = try lexer.parseQualifiedPath(self.allocator, event_path_str, ast);

        // `=>` (construct glyph) introduces an immediate branch construction;
        // a plain `=` opens an implementation flow. The glyph is authoritative.
        const is_arrow = eq_idx + 1 < after_tilde.len and after_tilde[eq_idx + 1] == '>';
        const body_start = if (is_arrow) eq_idx + 2 else eq_idx + 1;
        const body_str = lexer.trim(after_tilde[body_start..]);

        // Check if it's a branch constructor (immediate return syntax)
        if (body_str.len > 0) {
            // Reject Zig-style struct syntax: .{ .field = value }
            // Koru uses: branch_name { field: value }
            if (lexer.startsWith(body_str, ".{")) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "Zig-style struct syntax '.{{' is not valid Koru — use 'branch_name {{ field: value }}' instead",
                    .{},
                );
                return error.ParseError;
            }

            // Check for branch constructor pattern: word followed by {
            const brace_idx = std.mem.indexOf(u8, body_str, "{");
            if (brace_idx) |b_idx| {
                const before_brace = lexer.trim(body_str[0..b_idx]);
                // `=>` body with `name {` → immediate branch constructor.
                if (is_arrow and std.mem.indexOf(u8, before_brace, ".") == null and
                    !std.mem.containsAtLeast(u8, before_brace, 1, "("))
                {
                    // It's an immediate branch constructor!
                    // Check if we have closing brace on same line
                    const closing_idx = std.mem.lastIndexOf(u8, body_str, "}");

                    if (closing_idx != null and closing_idx.? > b_idx) {
                        // Single-line, complete branch constructor
                        const branch_constructor = try self.parseBranchConstructorWithContext(body_str);
                        return ast.Item{ .immediate_impl = .{
                            .event_path = event_path,
                            .value = branch_constructor,
                            .location = self.getCurrentLocation(),
                            .module = try self.allocator.dupe(u8, self.module_name),
                            .is_impl = event_path.module_qualifier != null,
                        } };
                    } else {
                        // Multi-line branch constructor starting on this line
                        var constructor_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                        defer constructor_content.deinit(self.allocator);

                        // Add the content from the first line
                        try constructor_content.appendSlice(self.allocator, body_str);
                        try constructor_content.append(self.allocator, ' ');

                        // Track brace depth (already have one open brace)
                        var brace_depth: i32 = 1;

                        while (self.current < self.lines.len and brace_depth > 0) {
                            const curr_line = self.lines[self.current];
                            self.current += 1;

                            const trimmed_line = lexer.trim(curr_line);
                            if (trimmed_line.len == 0) continue;

                            // Count braces (skip braces in strings/comments)
                            brace_depth += lexer.countBraceDepthChange(trimmed_line);

                            // Add this line's content
                            try constructor_content.appendSlice(self.allocator, trimmed_line);
                            if (brace_depth > 0) {
                                try constructor_content.append(self.allocator, ' ');
                            }
                        }

                        // Parse the complete constructor
                        const branch_constructor = try self.parseBranchConstructorWithContext(constructor_content.items);
                        return ast.Item{ .immediate_impl = .{
                            .event_path = event_path,
                            .value = branch_constructor,
                            .location = self.getCurrentLocation(),
                            .module = try self.allocator.dupe(u8, self.module_name),
                            .is_impl = event_path.module_qualifier != null,
                        } };
                    }
                }
            }

            // Check for braceless branch constructor: just identifier or identifier + expression
            // Pattern: no { no () no : means it could be a braceless branch constructor
            const has_brace = std.mem.indexOf(u8, body_str, "{") != null;
            const has_parens = std.mem.indexOf(u8, body_str, "(") != null;
            const has_colon = std.mem.indexOf(u8, body_str, ":") != null;

            if (is_arrow and !has_brace and !has_parens and !has_colon) {
                const first_space = std.mem.indexOfAny(u8, body_str, &[_]u8{ ' ', '\t' });
                const branch_name = if (first_space) |idx| lexer.trim(body_str[0..idx]) else body_str;

                if (branch_name.len > 0 and isValidIdentifier(branch_name)) {
                    // Braceless branch constructor!
                    if (first_space) |idx| {
                        // Has expression: "ok expr"
                        const expr_part = lexer.trim(body_str[idx..]);
                        return ast.Item{ .immediate_impl = .{
                            .event_path = event_path,
                            .value = .{
                                .branch_name = try self.allocator.dupe(u8, branch_name),
                                .fields = &.{},
                                .plain_value = try self.allocator.dupe(u8, expr_part),
                                .has_expressions = true,
                            },
                            .location = self.getCurrentLocation(),
                            .module = try self.allocator.dupe(u8, self.module_name),
                            .is_impl = event_path.module_qualifier != null,
                        } };
                    } else {
                        // Just branch name: "ok"
                        return ast.Item{ .immediate_impl = .{
                            .event_path = event_path,
                            .value = .{
                                .branch_name = try self.allocator.dupe(u8, branch_name),
                                .fields = &.{},
                                .plain_value = null,
                                .has_expressions = false,
                            },
                            .location = self.getCurrentLocation(),
                            .module = try self.allocator.dupe(u8, self.module_name),
                            .is_impl = event_path.module_qualifier != null,
                        } };
                    }
                }
            }

            // Otherwise parse as normal flow with invocation
            // Push in_subflow_impl context to allow full expressions in branch constructors
            try self.context_stack.append(self.allocator, .in_subflow_impl);
            defer _ = self.context_stack.pop();

            // A leading `#name` is a pre-invocation label anchor on the subflow
            // RHS (`~spin = #loop step(...)`) — same shape as the top-level
            // `#label event(...)` form, carried on Flow.pre_label.
            var sub_pre_label: ?[]const u8 = null;
            var inv_str = body_str;
            if (lexer.startsWith(inv_str, "#")) {
                if (std.mem.indexOfAny(u8, inv_str, " \t")) |sp| {
                    const lbl = inv_str[1..sp];
                    if (lbl.len > 0 and isValidIdentifier(lbl)) {
                        sub_pre_label = try self.allocator.dupe(u8, lbl);
                        inv_str = lexer.trim(inv_str[sp + 1 ..]);
                    }
                }
            }

            // A source block may OPEN on the subflow-definition line and close on
            // a later one (`run = std/io:print.blk {` … `}`), which leaves the
            // definition line itself brace-unbalanced. Stitch the following lines
            // on until the braces close, or parseEventInvocation sees a block that
            // never terminates and reports PARSE001 against balanced source.
            //
            // Newline-joined, not space-joined: the block's content is emitted text
            // and a multi-line block keeps its line structure. The `=>` constructor
            // path above space-joins because a constructor's braces carry FIELDS,
            // where layout is not part of the value.
            //
            // Each line is TRIMMED before joining, which is what the statement-level
            // collectors do and what a top-level multi-line block already emits
            // (900_HELLO_WORLD dedents both of its lines). Carrying the source
            // indentation through instead would dedent the first line — it follows
            // the `{` — while keeping it on every later one.
            {
                var block_depth = lexer.countBraceDepthChange(inv_str);
                while (block_depth > 0 and self.current < self.lines.len) {
                    const nt = lexer.trim(self.lines[self.current]);
                    self.current += 1;
                    inv_str = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ inv_str, nt });
                    block_depth += lexer.countBraceDepthChange(nt);
                }
            }

            // Point-free chain over multiple lines: `~head = step` followed by
            // indented `|> step` lines. Stitch those steps onto inv_str so the
            // existing inline-chain machinery (has_inline_chain →
            // parseInlineContinuation, which itself grabs base-indent handlers
            // via parseContinuations) handles the chain AND the dedented choke
            // below it. Stops at the first non-`|>` line (a `| branch` choke) or
            // a dedent to the head level.
            {
                const head_indent = lexer.getIndent(line);
                while (self.current < self.lines.len) {
                    const nl = self.lines[self.current];
                    const nt = lexer.trim(nl);
                    if (nt.len < 2 or nt[0] != '|' or nt[1] != '>') break;
                    if (lexer.getIndent(nl) <= head_indent) break;
                    inv_str = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ inv_str, nt });
                    self.current += 1;
                }
            }

            const invocation = try self.parseEventInvocation(inv_str);

            // If body has an inline |> chain (e.g. `head() |> tail() | branch ...`),
            // parseEventInvocation only captured the head; route the tail through
            // parseInlineContinuation so the next step isn't silently dropped.
            const has_inline_chain = blk: {
                var i: usize = 0;
                var paren_depth: i32 = 0;
                var brace_depth: i32 = 0;
                var in_string = false;
                while (i + 1 < inv_str.len) : (i += 1) {
                    const c = inv_str[i];
                    if (c == '"' and (i == 0 or inv_str[i - 1] != '\\')) {
                        in_string = !in_string;
                        continue;
                    }
                    if (in_string) continue;
                    if (c == '(') paren_depth += 1;
                    if (c == ')') paren_depth -= 1;
                    if (c == '{') brace_depth += 1;
                    if (c == '}') brace_depth -= 1;
                    if (paren_depth == 0 and brace_depth == 0 and c == '|' and inv_str[i + 1] == '>') {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            // Same-line `=> construct` after a bare-return head bind
            // (`~run = head(): v => ok v`): the construct has no `| branch` wrapper
            // (the `: v` bind moved onto the head via return_binding), so neither
            // the `|>` chain path nor the next-line parseContinuations sees it.
            // Detect the depth-0 `=>` and build a void-branch construct continuation.
            const same_line_arrow: ?usize = blk: {
                if (has_inline_chain) break :blk null;
                // Only the bare-return bind shape (`head(): v => construct`). A
                // same-line `head() | branch r => construct` (single-pipe, no bind,
                // e.g. 430_004/007) has NO return_binding and must keep flowing
                // through parseContinuations — never treat its `=>` as the head's.
                if (invocation.return_binding == null) break :blk null;
                var i: usize = 0;
                var pd: i32 = 0;
                var bd: i32 = 0;
                var ins = false;
                while (i + 1 < inv_str.len) : (i += 1) {
                    const c = inv_str[i];
                    if (c == '"' and (i == 0 or inv_str[i - 1] != '\\')) {
                        ins = !ins;
                        continue;
                    }
                    if (ins) continue;
                    if (c == '(') pd += 1;
                    if (c == ')') pd -= 1;
                    if (c == '{') bd += 1;
                    if (c == '}') bd -= 1;
                    if (pd == 0 and bd == 0 and c == '=' and inv_str[i + 1] == '>') break :blk i;
                }
                break :blk null;
            };

            // Same-line `-> produce` after a bare-return head bind
            // (`~combo = head(): v -> v`): the produce arm, twin of the `=>`
            // construct arm above. `->` produces the bound value (or any
            // expression) as the enclosing event's bare `-> T` return, with no
            // `| branch` wrapper. Detect the depth-0 `->` and build a
            // bare-return continuation (same node the flat `~e -> expr` impl uses).
            const same_line_produce: ?usize = blk: {
                if (has_inline_chain) break :blk null;
                if (invocation.return_binding == null) break :blk null;
                var i: usize = 0;
                var pd: i32 = 0;
                var bd: i32 = 0;
                var ins = false;
                while (i + 1 < inv_str.len) : (i += 1) {
                    const c = inv_str[i];
                    if (c == '"' and (i == 0 or inv_str[i - 1] != '\\')) {
                        ins = !ins;
                        continue;
                    }
                    if (ins) continue;
                    if (c == '(') pd += 1;
                    if (c == ')') pd -= 1;
                    if (c == '{') bd += 1;
                    if (c == '}') bd -= 1;
                    if (pd == 0 and bd == 0 and c == '-' and inv_str[i + 1] == '>') break :blk i;
                }
                break :blk null;
            };

            const continuations = if (same_line_produce) |pidx| produce_blk: {
                const produce_str = lexer.trim(inv_str[pidx + 2 ..]);
                const conts = try self.allocator.alloc(ast.Continuation, 1);
                conts[0] = ast.Continuation{
                    .branch = try self.allocator.dupe(u8, ""),
                    .binding = null,
                    .condition = null,
                    .node = .{ .branch_constructor = .{
                        .branch_name = try self.allocator.dupe(u8, ""),
                        .fields = &.{},
                        .plain_value = try self.allocator.dupe(u8, produce_str),
                        .has_expressions = true,
                        .is_bare_return = true,
                    } },
                    .indent = 0,
                    .continuations = &.{},
                };
                break :produce_blk conts;
            } else if (same_line_arrow) |aidx| arrow_blk: {
                const construct_str = lexer.trim(inv_str[aidx + 2 ..]);
                const ctor = try self.parseConstructString(construct_str);
                const conts = try self.allocator.alloc(ast.Continuation, 1);
                conts[0] = ast.Continuation{
                    .branch = try self.allocator.dupe(u8, ""),
                    .binding = null,
                    .condition = null,
                    .node = .{ .branch_constructor = ctor },
                    .indent = 0,
                    .continuations = &.{},
                };
                break :arrow_blk conts;
            } else if (has_inline_chain)
                try self.parseInlineContinuation(inv_str, lexer.getIndent(line), head_line_idx)
            else
                try self.parseContinuations(lexer.getIndent(line));

            return ast.Item{ .flow = .{
                .body = ast.rootSite(invocation, continuations, self.getCurrentLocation()),
                .pre_label = sub_pre_label,
                .impl_of = event_path,
                .impl_variant = impl_variant,
                .annotations = try self.dupeAnnotations(annotations),
                .is_impl = event_path.module_qualifier != null,
                .location = self.getCurrentLocation(),
                .module = try self.allocator.dupe(u8, self.module_name),
            } };
        }

        // Flow body on next line(s) - handle multi-line flows
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "expected subflow body after '='",
                .{},
            );
            return error.UnexpectedEof;
        }

        // Skip blank lines
        while (self.current < self.lines.len) {
            const next_line = self.lines[self.current];
            const trimmed_next = lexer.trim(next_line);
            if (trimmed_next.len > 0) break;
            self.current += 1;
        }

        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "expected subflow body after '='",
                .{},
            );
            return error.UnexpectedEof;
        }
        const body_line = self.lines[self.current];
        const trimmed_body = lexer.trim(body_line);

        // Reject Zig-style struct syntax: .{ .field = value }
        // Koru uses: branch_name { field: value }
        if (lexer.startsWith(trimmed_body, ".{")) {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                1,
                "Zig-style struct syntax '.{{' is not valid Koru — use 'branch_name {{ field: value }}' instead",
                .{},
            );
            return error.ParseError;
        }

        // Check for branch constructor (immediate return syntax)
        const brace_idx = std.mem.indexOf(u8, trimmed_body, "{");
        if (brace_idx) |b_idx| {
            const before_brace = lexer.trim(trimmed_body[0..b_idx]);
            if (std.mem.indexOf(u8, before_brace, ".") == null and
                !std.mem.containsAtLeast(u8, before_brace, 1, "(") and
                !lexer.startsWith(trimmed_body, "|"))
            { // Not a continuation
                // It's an immediate branch constructor!
                // Check if it's multiline by looking for closing brace
                const closing_idx = std.mem.lastIndexOf(u8, trimmed_body, "}");

                if (closing_idx != null and closing_idx.? > b_idx) {
                    // Single-line branch constructor
                    self.current += 1;
                    const branch_constructor = try self.parseBranchConstructorWithContext(trimmed_body);
                    return ast.Item{ .immediate_impl = .{
                        .event_path = event_path,
                        .value = branch_constructor,
                        .location = self.getCurrentLocation(),
                        .module = try self.allocator.dupe(u8, self.module_name),
                        .is_impl = event_path.module_qualifier != null,
                    } };
                } else {
                    // Multi-line branch constructor - collect all lines
                    var constructor_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                    defer constructor_content.deinit(self.allocator);

                    // Add the first line
                    try constructor_content.appendSlice(self.allocator, trimmed_body);
                    try constructor_content.append(self.allocator, ' ');

                    // Track brace depth
                    var brace_depth: i32 = 1;
                    self.current += 1; // Move to next line

                    while (self.current < self.lines.len and brace_depth > 0) {
                        const curr_line = self.lines[self.current];
                        self.current += 1;

                        const trimmed_line = lexer.trim(curr_line);
                        if (trimmed_line.len == 0) continue;

                        // Count braces (skip braces in strings/comments)
                        brace_depth += lexer.countBraceDepthChange(trimmed_line);

                        // Add this line's content
                        try constructor_content.appendSlice(self.allocator, trimmed_line);
                        if (brace_depth > 0) {
                            try constructor_content.append(self.allocator, ' ');
                        }
                    }

                    // Parse the complete constructor
                    const branch_constructor = try self.parseBranchConstructorWithContext(constructor_content.items);
                    return ast.Item{ .immediate_impl = .{
                        .event_path = event_path,
                        .value = branch_constructor,
                        .location = self.getCurrentLocation(),
                        .module = try self.allocator.dupe(u8, self.module_name),
                        .is_impl = event_path.module_qualifier != null,
                    } };
                }
            }
        }

        // Check if the line is an invocation or a continuation
        if (lexer.startsWith(trimmed_body, "|")) {
            // Continuation-only subflow (no explicit invocation on first line)
            // Push in_subflow_impl context to allow full expressions in branch constructors
            try self.context_stack.append(self.allocator, .in_subflow_impl);
            defer _ = self.context_stack.pop();

            // Create a pass-through invocation duplicating the event path
            var dup_segments = try self.allocator.alloc([]const u8, event_path.segments.len);
            for (event_path.segments, 0..) |seg, i| {
                dup_segments[i] = try self.allocator.dupe(u8, seg);
            }
            const invocation = ast.Invocation{
                .path = ast.DottedPath{
                    .module_qualifier = if (event_path.module_qualifier) |mq| try self.allocator.dupe(u8, mq) else null,
                    .segments = dup_segments,
                },
                .args = &.{},
            };

            // Now parse all the continuations starting from current line
            const continuations = try self.parseContinuations(lexer.getIndent(line));

            return ast.Item{ .flow = .{
                .body = ast.rootSite(invocation, continuations, self.getCurrentLocation()),
                .impl_of = event_path,
                .impl_variant = impl_variant,
                .annotations = try self.dupeAnnotations(annotations),
                .is_impl = event_path.module_qualifier != null,
                .location = self.getCurrentLocation(),
                .module = try self.allocator.dupe(u8, self.module_name),
            } };
        }

        // Otherwise parse as normal flow starting with an invocation
        // Push in_subflow_impl context to allow full expressions in branch constructors
        try self.context_stack.append(self.allocator, .in_subflow_impl);
        defer _ = self.context_stack.pop();

        // A leading `#name` is a pre-invocation label anchor (see the
        // same-line body path above).
        var sub_pre_label: ?[]const u8 = null;
        var inv_str = trimmed_body;
        if (lexer.startsWith(inv_str, "#")) {
            if (std.mem.indexOfAny(u8, inv_str, " \t")) |sp| {
                const lbl = inv_str[1..sp];
                if (lbl.len > 0 and isValidIdentifier(lbl)) {
                    sub_pre_label = try self.allocator.dupe(u8, lbl);
                    inv_str = lexer.trim(inv_str[sp + 1 ..]);
                }
            }
        }

        const invocation = try self.parseEventInvocation(inv_str);

        // A `|>` chain written INLINE on the body line parses EXACTLY like its
        // same-line spelling (`~go = a(): v |> b(x: v)`) — the ONE rule for
        // `|>` chains this parser states at parseMultiLinePipeChain. This path
        // was the single place that did not apply it: `parseEventInvocation`
        // captures only the HEAD, so without the route below every tail step
        // was silently discarded and the subflow produced the head's value.
        // Nothing refused it — `go = bump(x: 3): d1 |> bump(x: d1): d2 -> d2`
        // returned 12 on one line and 6 across two (210_200 pins both).
        //
        // The corpus had exactly ONE user (110_006's helper.kz), red for 21
        // days as `KORU100 unused binding 'd1'` — true of the tree the parser
        // built, false of the program written. Line-start `|>` lines are a
        // different shape and already handled by parseContinuations below.
        const body_has_inline_chain = blk: {
            var i: usize = 0;
            var paren_depth: i32 = 0;
            var brace_depth: i32 = 0;
            var in_string = false;
            while (i + 1 < inv_str.len) : (i += 1) {
                const c = inv_str[i];
                if (c == '"' and (i == 0 or inv_str[i - 1] != '\\')) {
                    in_string = !in_string;
                    continue;
                }
                if (in_string) continue;
                if (c == '(') paren_depth += 1;
                if (c == ')') paren_depth -= 1;
                if (c == '{') brace_depth += 1;
                if (c == '}') brace_depth -= 1;
                if (paren_depth == 0 and brace_depth == 0 and c == '|' and inv_str[i + 1] == '>') {
                    break :blk true;
                }
            }
            break :blk false;
        };

        const body_line_idx = self.current;
        self.current += 1; // Move past the invocation line
        const continuations = if (body_has_inline_chain)
            try self.parseInlineContinuation(inv_str, lexer.getIndent(body_line), body_line_idx)
        else
            try self.parseContinuations(lexer.getIndent(body_line));

        return ast.Item{ .flow = .{
            .body = ast.rootSite(invocation, continuations, self.getCurrentLocation()),
            .pre_label = sub_pre_label,
            .impl_of = event_path,
            .impl_variant = impl_variant,
            .annotations = try self.dupeAnnotations(annotations),
            .is_impl = event_path.module_qualifier != null,
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        } };
    }

    fn parseImplicitFlowBlock(self: *Parser, base_indent: usize) ![]ast.Continuation {
        // Parse the flow content inside {} and then any output continuations after
        // Returns ALL continuations - the caller will package the flow part appropriately

        var all_continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (all_continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            all_continuations.deinit(self.allocator);
        }

        // First, parse the flow content inside {}
        var flow_ast_continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 4);
        defer flow_ast_continuations.deinit(self.allocator);

        var inside_braces = true;

        while (self.current < self.lines.len and inside_braces) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            // Check for closing brace
            if (std.mem.eql(u8, trimmed, "}")) {
                self.current += 1;
                inside_braces = false;
                break;
            }

            // Skip empty lines
            if (trimmed.len == 0) {
                self.current += 1;
                continue;
            }

            // Inside {}, we require ~ for each flow
            if (!lexer.startsWith(trimmed, "~")) {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "Flows inside block must start with ~",
                    .{},
                );
                return error.MissingTilde;
            }

            // Parse this flow and its continuations
            const flow_invocation_str = trimmed[1..]; // Skip ~

            // Parse the invocation
            const flow_invocation = try self.parseEventInvocation(flow_invocation_str);

            // Move past the invocation line before parsing continuations
            self.current += 1;

            // Parse its continuations (must be exhaustive!)
            const indent = lexer.getIndent(line);
            const flow_continuations = try self.parseContinuations(indent);

            // Package as a single continuation representing this flow
            // We'll mark it specially so the emitter knows it's a flow item
            const flow_cont = ast.Continuation{
                .branch = try self.allocator.dupe(u8, "<flow_ast_item>"),
                .binding = null,
                .condition = null,
                .node = .{ .invocation = flow_invocation },
                .indent = indent,
                .continuations = flow_continuations,
                .location = self.getCurrentLocation(),
            };

            try flow_ast_continuations.append(self.allocator, flow_cont);
        }

        // Now parse any output continuations after the }
        // These are DIRECT continuations of the invocation (not siblings), so use normal mode
        const output_continuations = try self.parseContinuations(base_indent);

        // Combine: flow items first, then output continuations
        for (flow_ast_continuations.items) |cont| {
            try all_continuations.append(self.allocator, cont);
        }
        for (output_continuations) |cont| {
            try all_continuations.append(self.allocator, cont);
        }

        // The caller will need to distinguish flow items from output continuations
        // For now, we use the special "<flow_ast_item>" branch name as a marker

        return all_continuations.toOwnedSlice(self.allocator);
    }

    fn parseImplicitSourceBlock(self: *Parser, base_indent: usize, phantom_type: ?[]const u8, strict: bool) anyerror!struct { source: []const u8, continuations: []ast.Continuation, phantom_type: ?[]const u8 } {
        // Parse Source content inside {} as raw text, then any output continuations after
        // Source is captured as a string - no parsing of flows inside
        //
        // INDENT-AWARE: We dedent the content by stripping the minimum indentation
        // from all non-empty lines. This allows natural code formatting:
        //
        //   ~print [text]{
        //       <h1>Hello</h1>
        //       <p>World</p>
        //   }
        //
        // Captures "<h1>Hello</h1>\n<p>World</p>\n" (no leading spaces)

        var source_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer source_lines.deinit(self.allocator);

        var inside_braces = true;
        var min_indent: ?usize = null;
        var first_content_indent: ?usize = null;
        var inline_close_line: ?[]const u8 = null;

        // First pass: collect lines and find minimum indentation
        while (self.current < self.lines.len and inside_braces) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);
            const line_indent = lexer.getIndent(line);

            // Track indent of first non-empty content line
            if (first_content_indent == null and trimmed.len > 0 and !std.mem.eql(u8, trimmed, "}")) {
                first_content_indent = line_indent;
            }

            // Check for closing brace - must be on its own line
            // Accept if: less indented than first content line (or at base_indent if no content yet)
            // This handles both top-level and nested-in-pipeline cases
            const close_threshold = first_content_indent orelse base_indent;

            if (std.mem.eql(u8, trimmed, "}") and line_indent < close_threshold) {
                self.current += 1;
                inside_braces = false;
                break;
            }

            // Inline void chain after `}`: `} |> next()` — `|>` is always inline in Koru,
            // so the source block must close at the `}` even when `|>` follows on the same line.
            if (std.mem.startsWith(u8, trimmed, "}") and std.mem.indexOf(u8, trimmed, "|>") != null) {
                inline_close_line = line;
                self.current += 1;
                inside_braces = false;
                break;
            }

            // Track minimum indentation of non-empty lines
            if (trimmed.len > 0) {
                if (min_indent == null or line_indent < min_indent.?) {
                    min_indent = line_indent;
                }
            }

            try source_lines.append(self.allocator, line);
            self.current += 1;
        }

        const dedent = min_indent orelse 0;

        // Calculate total length after dedenting
        const total_len = blk: {
            var len: usize = 0;
            for (source_lines.items) |line| {
                // Dedent: skip first 'dedent' characters if line is long enough
                const dedented_len = if (line.len >= dedent) line.len - dedent else line.len;
                len += dedented_len + 1; // +1 for newline
            }
            break :blk len;
        };

        var source_buf = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (source_lines.items) |line| {
            // Dedent: skip first 'dedent' characters
            const dedented = if (line.len >= dedent) line[dedent..] else line;
            @memcpy(source_buf[pos..][0..dedented.len], dedented);
            pos += dedented.len;
            source_buf[pos] = '\n';
            pos += 1;
        }

        // ONE trailing-edge convention for stored Source text: trimmed. The
        // continuation-position path (parseEventInvocation) has always
        // trimmed; this root-position path kept a trailing newline, so the
        // same block spelled at different positions stored different bytes
        // (canon signal from the printer round-trip harness, 2026-07-02).
        // The trailing newline is layout, not content — consumers that emit
        // newlines normalize themselves (320_093: both conventions printed
        // identical output). Dupe rather than sub-slice: callers free the
        // returned text by its own ptr/len.
        const trimmed_source = std.mem.trimRight(u8, source_buf[0..pos], " \t\r\n");
        const source = try self.allocator.dupe(u8, trimmed_source);
        self.allocator.free(source_buf);

        // Now parse any output continuations after the }
        // In strict mode (pipeline context), only collect continuations MORE indented than base_indent
        // This prevents sibling branches at the pipeline level from being consumed as children
        var output_continuations: []ast.Continuation = undefined;
        if (inline_close_line) |close_line| {
            const trimmed_close = lexer.trim(close_line);
            if (std.mem.indexOf(u8, trimmed_close, "|>")) |pipe_idx| {
                const tail = lexer.trim(trimmed_close[pipe_idx + 2 ..]);
                const close_line_idx = if (self.current > 0) self.current - 1 else self.current;
                const tail_location = self.getLineLocation(close_line_idx, 0);

                // Mirror parsePipelineContinuationBase's Source-block pipeline step without
                // mutual recursion (that path also calls parseImplicitSourceBlock).
                const has_open_brace = std.mem.indexOf(u8, tail, "{") != null;
                const has_close_brace = std.mem.indexOf(u8, tail, "}") != null;
                if (has_open_brace and !has_close_brace) {
                    const brace_idx = std.mem.lastIndexOf(u8, tail, "{") orelse unreachable;
                    const invocation_str = lexer.trim(tail[0..brace_idx]);
                    const temp_invocation = try self.parseEventInvocation(invocation_str);
                    const path_str = try self.pathToString(temp_invocation.path);
                    defer self.allocator.free(path_str);

                    var has_source_param = false;
                    if (self.registry.getEventType(path_str)) |event_type| {
                        if (event_type.input_shape) |shape| {
                            for (shape.fields) |field| {
                                if (field.is_source) {
                                    has_source_param = true;
                                    break;
                                }
                            }
                        }
                    }

                    if (has_source_param) {
                        const tail_source = try self.parseImplicitSourceBlock(base_indent, null, true);
                        var final_invocation: ast.Invocation = undefined;
                        if (self.registry.getEventType(path_str)) |event_type| {
                            final_invocation = try self.createImplicitSourceInvocation(
                                temp_invocation,
                                tail_source.source,
                                tail_source.phantom_type,
                                event_type,
                            );
                        } else {
                            final_invocation = try self.createImplicitSourceInvocationDefault(
                                temp_invocation,
                                tail_source.source,
                                tail_source.phantom_type,
                            );
                        }
                        self.allocator.free(tail_source.source);

                        const step = ast.Step{ .invocation = final_invocation };
                        const tail_cont = ast.Continuation{
                            .branch = try self.allocator.dupe(u8, ""),
                            .binding = null,
                            .condition = null,
                            .condition_expr = null,
                            .node = step,
                            .indent = base_indent,
                            .continuations = tail_source.continuations,
                            .location = tail_location,
                        };
                        var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                        try cont_list.append(self.allocator, tail_cont);
                        output_continuations = try cont_list.toOwnedSlice(self.allocator);
                    } else {
                        const tail_cont = try self.parsePipelineContinuationBase(tail, base_indent, tail_location);
                        var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                        try cont_list.append(self.allocator, tail_cont);
                        output_continuations = try cont_list.toOwnedSlice(self.allocator);
                    }
                } else {
                    const tail_cont = try self.parsePipelineContinuationBase(tail, base_indent, tail_location);
                    var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                    try cont_list.append(self.allocator, tail_cont);
                    output_continuations = try cont_list.toOwnedSlice(self.allocator);
                }
            } else {
                output_continuations = if (strict)
                    try self.parseContinuationsWithMode(base_indent, true)
                else
                    try self.parseContinuations(base_indent);
            }
        } else if (strict) {
            output_continuations = try self.parseContinuationsWithMode(base_indent, true);
        } else {
            output_continuations = try self.parseContinuations(base_indent);
        }

        return .{
            .source = source,
            .continuations = output_continuations,
            .phantom_type = phantom_type,
        };
    }

    /// Parse inline continuation (same-line |> pattern)
    /// Used for void event chaining: ~void_event() |> another_event()
    fn parseInlineContinuation(self: *Parser, full_line: []const u8, indent: usize, line_idx: usize) ![]ast.Continuation {
        // Find the first |> that's not inside parentheses
        var pipe_idx: ?usize = null;
        var paren_depth: i32 = 0;
        var i: usize = 0;
        while (i < full_line.len - 1) : (i += 1) {
            const c = full_line[i];
            if (c == '(') paren_depth += 1;
            if (c == ')') paren_depth -= 1;
            if (c == '|' and full_line[i + 1] == '>' and paren_depth == 0) {
                pipe_idx = i;
                break;
            }
        }

        if (pipe_idx == null) {
            // No inline continuation found
            return &[_]ast.Continuation{};
        }

        // The chain's own source line, from the index the caller read it at —
        // NOT the cursor, which parseContinuations below walks past the
        // following handler lines. Every step of an inline chain lives on this
        // line, and a diagnostic that names a step (KORU100, KORU106) must
        // point at it, not at wherever the cursor happened to stop.
        const chain_location = self.getLineLocation(line_idx, indent);

        // Extract the continuation part after |>
        var continuation_part = lexer.trim(full_line[pipe_idx.? + 2 ..]);

        // A trailing top-level `-> produce` on the LAST step of the chain
        // (`... |> tail(args): v -> expr`) is the produce arm at the end of a
        // chained subflow body (the metacircular `frontend` pipeline shape).
        // `->` is not a chain delimiter (only `|>`/`=>` split), so it rides on
        // the final segment; strip it here and attach a bare-return
        // continuation to the innermost step below — the same node the
        // non-chained `head(): v -> expr` produce uses.
        var produce_tail: ?[]const u8 = null;
        if (indexOfTopLevelArrow(continuation_part)) |aidx| {
            produce_tail = lexer.trim(continuation_part[aidx + 2 ..]);
            continuation_part = lexer.trim(continuation_part[0..aidx]);
        }

        // Parse the pipeline steps from the continuation
        // Inline `~A() |> ...` is a void chain, not a branch handler body.
        //
        // `chain_location`, NOT `getCurrentLocation()`. The head line is already
        // consumed by the time we get here, so the cursor names the line AFTER
        // the chain — and with every stage on one physical line, every step
        // inherited it. A diagnostic on a mid-chain call then pointed at the
        // first branch arm below, i.e. at working code (210_201's second
        // witness). The two continuations built further down already use
        // `chain_location`; only the steps were reading the cursor.
        const steps = try self.parsePipelineSteps(continuation_part, false, chain_location);

        if (steps.len == 0) {
            return &[_]ast.Continuation{};
        }

        // Build chain of continuations from back to front
        // Each step becomes a continuation with empty branch, pointing to the next step
        // Last step gets the nested multi-line continuations

        // parseContinuations (not parseNestedContinuationsForLevel) so same-indent
        // branches under `~A() |> B()` attach to B, matching standalone-head shape.
        const nested_continuations = try self.parseContinuations(indent);

        // Start with the last step's continuations. If the chain ends in a
        // `-> produce` arm, that bare-return continuation is the innermost
        // (attached to the final step); otherwise the multi-line nested
        // continuations are.
        //
        // A produce is a TERMINUS — nothing continues it — so the multi-line
        // handler lines that follow (`! warn m |> …`, the last step's effect
        // arms) are its SIBLINGS on that step, not its children. Nesting them
        // under the produce hid them from the step's effect wiring, so the
        // handler was silently dropped and the produce was emitted as a
        // value-producing step instead of a return (210_189).
        var current_continuations: []ast.Continuation = if (produce_tail) |pt| blk: {
            const conts = try self.allocator.alloc(ast.Continuation, 1 + nested_continuations.len);
            conts[0] = ast.Continuation{
                .branch = try self.allocator.dupe(u8, ""),
                .binding = null,
                .binding_type = .branch_payload,
                .condition = null,
                .condition_expr = null,
                .node = .{ .branch_constructor = .{
                    .branch_name = try self.allocator.dupe(u8, ""),
                    .fields = &.{},
                    .plain_value = try self.allocator.dupe(u8, pt),
                    .has_expressions = true,
                    .is_bare_return = true,
                } },
                .indent = indent,
                .continuations = &.{},
                .location = chain_location,
            };
            @memcpy(conts[1..], nested_continuations);
            self.allocator.free(nested_continuations);
            break :blk conts;
        } else nested_continuations;

        // Work backwards through steps, building the chain
        var step_idx: usize = steps.len;
        while (step_idx > 0) {
            step_idx -= 1;

            const step = steps[step_idx];

            // Create continuation for this step
            var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
            try cont_list.append(self.allocator, ast.Continuation{
                .branch = try self.allocator.dupe(u8, ""), // Empty branch for void event continuation
                .binding = null,
                .binding_type = .branch_payload,
                .condition = null,
                .condition_expr = null,
                .node = step,
                .indent = indent,
                .continuations = current_continuations,
                .location = chain_location,
            });

            current_continuations = try cont_list.toOwnedSlice(self.allocator);
        }

        return current_continuations;
    }

    fn parseContinuations(self: *Parser, base_indent: usize) ![]ast.Continuation {
        return self.parseContinuationsWithMode(base_indent, false);
    }

    /// Caller is on a comment-only line while scanning for branch handlers
    /// inside a flow chain. Peek ahead past further comments and blanks: if
    /// the next meaningful line is a continuation `|`, the comment is
    /// splitting a chain from its branch handlers (or sibling handlers from
    /// each other) — emit KORU010 and return true. Otherwise return false;
    /// the chain has ended at the comment and the caller should bail out.
    fn rejectChainSplittingComment(self: *Parser) !bool {
        var peek = self.current + 1;
        while (peek < self.lines.len) {
            const next = self.lines[peek];
            const trimmed = lexer.trim(next);
            if (trimmed.len == 0) return false;
            if (lexer.isCommentLine(next)) {
                peek += 1;
                continue;
            }
            if (lexer.isContinuationLine(next)) {
                const indent = lexer.getIndent(self.lines[self.current]);
                try self.reporter.addErrorWithHint(
                    .KORU010,
                    self.current + 1,
                    indent + 1,
                    "comment line inside a flow chain",
                    .{},
                    "comments cannot split a flow from its branch handlers. Move the comment above the whole flow, or trail it after a complete line: '| ok |> done()  // note'.",
                    .{},
                );
                return true;
            }
            return false;
        }
        return false;
    }

    /// Parse continuations with optional strict indentation mode.
    /// When require_more_indented is true, only collect continuations that are
    /// MORE indented than base_indent (indent > base_indent). This is used after
    /// Source blocks where sibling continuations should NOT be collected.
    fn parseContinuationsWithMode(self: *Parser, base_indent: usize, require_more_indented: bool) ![]ast.Continuation {
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            continuations.deinit(self.allocator);
        }

        // Determine expected indent for direct children
        // If this is following a ~flow line at indent 0, children are at indent 0 or greater
        // If there's leading space, look for the first continuation to set the level
        var expected_indent: ?usize = null;

        // Ordering rule (KORU023): effect `!` handlers precede terminal `|` handlers
        // at the dispatch site, mirroring the decl-side rule.
        var seen_terminal_handler: bool = false;

        while (self.current < self.lines.len) {
            const line = self.lines[self.current];

            if (lexer.isCommentLine(line)) {
                if (try self.rejectChainSplittingComment()) return error.ParseError;
                break;
            }

            // Check if this is a continuation
            if (!lexer.isContinuationLine(line)) break;

            const indent = lexer.getIndent(line);

            // In strict mode (after Source block), only collect continuations MORE indented than base
            // This ensures sibling continuations at the same level are NOT collected
            if (require_more_indented and indent <= base_indent) break;

            // Set expected indent from first continuation if not set
            if (expected_indent == null) {
                expected_indent = indent;
            }

            // Only take continuations at the expected level
            if (indent != expected_indent.?) break;

            // Parse the continuation (which will also parse its nested continuations)
            const location = self.getLineLocation(self.current, indent);
            const handler_line = self.current + 1;
            self.current += 1; // Move past current line before parsing
            const cont = try self.parseContinuationWithNested(indent, location);

            // Ordering rule check. Catch-all (`!?` / `|?`) handlers are exempt
            // — they're symmetric ends for both sides.
            //
            // A `|>` CHAIN STEP is not a terminal handler. It shares the leading
            // `|` and parses as `.terminal`, but it names no branch — and a
            // flat multi-line chain puts its steps on continuation lines, so
            // counting them here made every arm below the first `|>` look like
            // it came after a terminal. An effect arm then tripped the rule
            // while sitting first in source order, and the hint told the author
            // to move it above handlers it was already above (210_193).
            //
            // The discriminator is the one `reattachArmsToLastStep` already
            // uses: an unnamed step is a step, a named branch is an arm
            // (ast_transform.zig isUnnamedStep).
            if (!cont.is_catchall and cont.branch.len > 0) {
                if (cont.kind == .effect and seen_terminal_handler) {
                    try errors.terminalBeforeEffect(&self.reporter, handler_line, indent + 1, cont.branch, .dispatch);
                }
                if (cont.kind == .terminal) seen_terminal_handler = true;
            }

            try continuations.append(self.allocator, cont);
        }

        return continuations.toOwnedSlice(self.allocator);
    }

    /// Join following line-start `|>` continuation lines onto `head_text`, so a
    /// multi-line pipe chain parses EXACTLY like its inline spelling — the same
    /// stitch the `=` subflow body applies (see parse of `~head = step` +
    /// indented `|> step` lines). ONE rule for `|>` chains everywhere:
    ///   - a branch head (`| ok v |> a()` / `! v x |> a()`) absorbs following
    ///     `|>` lines MORE indented than itself (equal-indent run or staircase —
    ///     both are the same chain);
    ///   - a line-start `|>` step absorbs following `|>` lines at its own
    ///     indent or deeper (consecutive `|>` lines are one chain).
    /// Comments, blanks, `| branch` handler lines, and dedents end the chain.
    /// The stitched text flows into the existing inline-chain machinery, which
    /// builds the canonical nested pyramid — so every checker downstream sees
    /// one shape regardless of how the chain was laid out in source.
    fn stitchPipeChainLines(self: *Parser, head_text: []const u8, head_indent: usize) ![]const u8 {
        const head_is_pipe_step = head_text.len > 1 and head_text[0] == '|' and head_text[1] == '>';
        var text = head_text;
        while (self.current < self.lines.len) {
            const nl = self.lines[self.current];
            const nt = lexer.trim(nl);
            if (nt.len < 2 or nt[0] != '|' or nt[1] != '>') break;
            const ni = lexer.getIndent(nl);
            if (head_is_pipe_step) {
                if (ni < head_indent) break;
            } else {
                if (ni <= head_indent) break;
            }
            // Trailing `//` line-comments must not swallow the joined steps:
            // strip them from each segment before joining (a `//` inside a
            // string literal is data and stays). Reuses the file-level
            // stripTrailingLineComment helper.
            text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{
                stripTrailingLineComment(text),
                stripTrailingLineComment(nt),
            });
            self.current += 1;
        }
        return text;
    }

    fn parseContinuationInternal(self: *Parser, indent: usize, parent_indent: usize, location: errors.SourceLocation) !ast.Continuation {
        _ = parent_indent;
        const line = self.lines[self.current - 1]; // We already incremented
        const trimmed = try self.stitchPipeChainLines(lexer.trim(line), indent);

        // Detect kind from prefix: `|` = terminal, `!` = effect.
        const branch_kind: ast.BranchKind = if (trimmed.len > 0 and trimmed[0] == '!') .effect else .terminal;
        // Skip the | or ! prefix
        const after_bar = lexer.trim(trimmed[1..]);

        var cont: ast.Continuation = undefined;

        if (lexer.startsWith(after_bar, ">")) {
            // Line-start `|>` continues the preceding flow as a pipeline step
            // (point-free chain). Route to the pipeline-continuation parser —
            // its own step validation still rejects `|> _` and bare-value junk
            // (KORU103). Return directly: the branch post-processing below would
            // clobber the pipeline parser's chained-step continuations.
            const step_content = lexer.trim(after_bar[1..]);
            var pcont = try self.parsePipelineContinuationBase(step_content, indent, location);
            pcont.kind = branch_kind;
            return pcont;
        } else if (lexer.startsWith(after_bar, "*")) {
            // Deref continuation (`| *<binding>`) — REMOVED. The deferred/deref
            // mechanism for first-class events is retired (repudiated 2026-07-15):
            // an event cannot travel as a runtime pointer. A required
            // effect-branch expresses "I need something to call here",
            // monomorphized and with no indirection. See
            // frag-deferred-deref-repudiated.
            try self.reporter.addError(
                .PARSE003,
                location.line,
                1,
                "deref continuation `| *<binding>` was removed — the deferred/deref mechanism is retired. Declare the call site with a required effect-branch instead.",
                .{},
            );
            return error.ParseError;
        } else {
            // Branch continuation
            cont = try self.parseBranchContinuationBase(after_bar, indent, location);
        }

        // Initialize continuations as empty, will be filled by caller if needed
        cont.continuations = &[_]ast.Continuation{};
        cont.kind = branch_kind;

        return cont;
    }

    fn parseContinuationWithNested(self: *Parser, indent: usize, location: errors.SourceLocation) anyerror!ast.Continuation {
        const line = self.lines[self.current - 1]; // We already incremented in parseContinuations
        // Multi-line `|>` chain: stitch following line-start `|>` lines onto
        // this continuation's text so the chain parses exactly like its inline
        // spelling (see stitchPipeChainLines).
        const trimmed = try self.stitchPipeChainLines(lexer.trim(line), indent);

        // Detect kind from prefix: `|` = terminal, `!` = effect.
        const branch_kind: ast.BranchKind = if (trimmed.len > 0 and trimmed[0] == '!') .effect else .terminal;
        // Skip the | or ! prefix
        const after_bar = lexer.trim(trimmed[1..]);

        var cont: ast.Continuation = undefined;

        if (lexer.startsWith(after_bar, ">")) {
            // Line-start `|>` continues the preceding flow as a pipeline step
            // (point-free chain). Route to the pipeline-continuation parser,
            // which handles its own chained tail; its step validation still
            // rejects `|> _` and bare-value junk (KORU103).
            const step_content = lexer.trim(after_bar[1..]);
            var pcont = try self.parsePipelineContinuationBase(step_content, indent, location);
            pcont.kind = branch_kind;
            return pcont;
        } else if (lexer.startsWith(after_bar, "*")) {
            // Deref continuation (`| *<binding>`) — REMOVED. The deferred/deref
            // mechanism for first-class events is retired (repudiated 2026-07-15):
            // an event cannot travel as a runtime pointer. A required
            // effect-branch expresses "I need something to call here",
            // monomorphized and with no indirection. See
            // frag-deferred-deref-repudiated.
            try self.reporter.addError(
                .PARSE003,
                location.line,
                1,
                "deref continuation `| *<binding>` was removed — the deferred/deref mechanism is retired. Declare the call site with a required effect-branch instead.",
                .{},
            );
            return error.ParseError;
        } else {
            // Branch continuation
            cont = try self.parseBranchContinuationBase(after_bar, indent, location);
        }

        // Parse nested continuations - ONLY greater indentation means nesting
        // Same-indent continuations are siblings, period. No magic auto-nesting.
        const multi_line_continuations = try self.parseNestedContinuationsForLevel(indent);

        // FIX: If we have inline chained continuations, attach multi-line ones to the deepest
        if (cont.continuations.len > 0 and multi_line_continuations.len > 0) {
            var deepest = &cont.continuations[0];
            while (deepest.continuations.len > 0) {
                deepest = @constCast(&deepest.continuations[0]);
            }
            @constCast(deepest).continuations = multi_line_continuations;
        } else if (cont.continuations.len == 0) {
            cont.continuations = multi_line_continuations;
        }

        cont.kind = branch_kind;
        return cont;
    }

    fn parseNestedContinuationsForLevel(self: *Parser, parent_indent: usize) anyerror![]ast.Continuation {
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            continuations.deinit(self.allocator);
        }

        // Look for continuation lines at greater indentation
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];

            if (lexer.isCommentLine(line)) {
                if (try self.rejectChainSplittingComment()) return error.ParseError;
                break;
            }

            if (!lexer.isContinuationLine(line)) break;

            const indent = lexer.getIndent(line);
            if (indent <= parent_indent) break;

            // Found a nested continuation - parse it and its nested ones recursively
            const location = self.getLineLocation(self.current, indent);
            self.current += 1;
            const cont = try self.parseContinuationWithNested(indent, location);

            // After parsing this continuation, check for its nested ones

            try continuations.append(self.allocator, cont);
        }

        return continuations.toOwnedSlice(self.allocator);
    }

    fn parseContinuation(self: *Parser, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);

        // Skip the | prefix
        const after_bar = lexer.trim(trimmed[1..]);

        if (lexer.startsWith(after_bar, ">")) {
            // Pipeline continuation |>
            return self.parsePipelineContinuation(after_bar[1..], indent, location);
        } else {
            // Branch continuation
            return self.parseBranchContinuation(after_bar, indent, location);
        }
    }

    fn parsePipelineContinuation(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        var cont = try self.parsePipelineContinuationBase(content, indent, location);

        const multi_line_continuations = try self.parseNestedContinuationsForLevel(indent);

        // If we have inline chained continuations, attach multi-line ones to the deepest
        if (cont.continuations.len > 0 and multi_line_continuations.len > 0) {
            var deepest = &cont.continuations[0];
            while (deepest.continuations.len > 0) {
                deepest = @constCast(&deepest.continuations[0]);
            }
            @constCast(deepest).continuations = multi_line_continuations;
        } else if (cont.continuations.len == 0) {
            cont.continuations = multi_line_continuations;
        }

        return cont;
    }

    /// Parse the comma-separated field list of a shape-destructure binding
    /// (inner text, outer braces already stripped). Grammar per field:
    ///   name                  — bind payload.name
    ///   name: Type            — bind with a representation annotation
    ///   name: { ... }         — nested destructure into payload.name
    ///   _                     — discard the slot (named position skipped)
    /// Splitting happens at brace-depth 0 so nested shapes stay intact.
    fn parseDestructureFields(self: *Parser, inner: []const u8, indent: usize) anyerror![]const ast.DestructureField {
        var fields = try std.ArrayList(ast.DestructureField).initCapacity(self.allocator, 4);
        errdefer {
            for (fields.items) |*f| f.deinit(self.allocator);
            fields.deinit(self.allocator);
        }

        var depth: i32 = 0;
        var brk: i32 = 0;
        var start: usize = 0;
        var idx: usize = 0;
        while (idx <= inner.len) : (idx += 1) {
            const at_end = idx == inner.len;
            const split = at_end or (inner[idx] == ',' and depth == 0 and brk == 0);
            if (!at_end) {
                if (inner[idx] == '{') depth += 1;
                if (inner[idx] == '}') depth -= 1;
                // Bracket depth keeps a comma INSIDE an annotation from
                // splitting the entry — `[a(x, y)]n` is one field.
                if (inner[idx] == '[') brk += 1;
                if (inner[idx] == ']') brk -= 1;
            }
            if (!split) continue;

            const item = lexer.trim(inner[start..idx]);
            start = idx + 1;
            if (item.len == 0) continue;

            // PREFIX annotations, the language's normal form: `{ [row]e }`.
            // A destructure entry is a REQUEST and the annotation names what
            // the producer should synthesize for it. Peeled here so every
            // consumer sees a plain name plus a list; whether a given
            // annotation MEANS anything is the consumer's call, and one it
            // must refuse rather than ignore.
            var anns = try std.ArrayList([]const u8).initCapacity(self.allocator, 1);
            errdefer {
                for (anns.items) |a| self.allocator.free(a);
                anns.deinit(self.allocator);
            }
            var rest = item;
            while (rest.len > 0 and rest[0] == '[') {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        indent + 2,
                        "Unterminated annotation on destructure field '{s}' - expected ']'.",
                        .{item},
                    );
                    return error.InvalidBinding;
                };
                const ann = lexer.trim(rest[1..close]);
                if (ann.len > 0) try anns.append(self.allocator, try self.allocator.dupe(u8, ann));
                rest = lexer.trim(rest[close + 1 ..]);
            }

            var name: []const u8 = rest;
            var type_text: ?[]const u8 = null;
            var sub: []const ast.DestructureField = &.{};

            if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
                name = lexer.trim(rest[0..colon]);
                const after = lexer.trim(rest[colon + 1 ..]);
                if (after.len >= 2 and after[0] == '{' and after[after.len - 1] == '}') {
                    sub = try self.parseDestructureFields(lexer.trim(after[1 .. after.len - 1]), indent);
                } else if (after.len > 0) {
                    type_text = try self.allocator.dupe(u8, after);
                } else {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        indent + 2,
                        "Destructure field '{s}' has ':' but no type or nested shape.",
                        .{name},
                    );
                    return error.InvalidBinding;
                }
            }

            if (!std.mem.eql(u8, name, "_") and !isValidIdentifier(name) and !isValidDottedName(name)) {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    indent + 2,
                    "Invalid destructure field name '{s}' - must be a valid identifier, dotted path, or '_'.",
                    .{name},
                );
                return error.InvalidBinding;
            }

            try fields.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .type_text = type_text,
                .sub = sub,
                .annotations = try anns.toOwnedSlice(self.allocator),
            });
        }

        if (fields.items.len == 0) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                indent + 2,
                "Empty destructure binding '{{}}' - name at least one field or bind the payload to a single name.",
                .{},
            );
            return error.InvalidBinding;
        }

        return try fields.toOwnedSlice(self.allocator);
    }

    fn parseBranchContinuationBase(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        // Note: *deref syntax is handled at a higher level, not here

        // Parse: branch [binding] [|> pipeline...]
        // Also handles pattern branches: [pattern expression] binding |> pipeline

        const trimmed_content = lexer.trim(content);

        // Check for pattern branch: [...]  or  raw pattern branch: `...`
        const is_pattern_branch = trimmed_content.len > 0 and trimmed_content[0] == '[';
        const is_raw_branch = trimmed_content.len > 0 and trimmed_content[0] == '`';

        var branch_name: []const u8 = undefined;
        var rest_after_branch: []const u8 = undefined;

        if (is_raw_branch) {
            // Quoted branch name, backtick spelling: `…`. Quoting is source
            // ENCODING — it lets the source express any name (regex ranges,
            // spaces, operators). The INNER content is the name; glyphs never
            // enter the AST. Byte-identical in meaning to the […] spelling.
            var end_pos: usize = 1;
            while (end_pos < trimmed_content.len and trimmed_content[end_pos] != '`') : (end_pos += 1) {}
            if (end_pos >= trimmed_content.len) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    indent + 2,
                    "unmatched '`' in quoted branch name",
                    .{},
                );
                return error.ParseError;
            }
            branch_name = trimmed_content[1..end_pos];
            rest_after_branch = lexer.trim(trimmed_content[end_pos + 1 ..]);
        } else if (is_pattern_branch) {
            // Pattern branch: find matching ] with bracket counting
            // Quoted branch name, bracket spelling: […] (depth-counted; the
            // content may itself contain brackets). EXACTLY equivalent to the
            // backtick spelling — the INNER content is the name.
            var depth: usize = 1;
            var end_pos: usize = 1;
            while (end_pos < trimmed_content.len and depth > 0) : (end_pos += 1) {
                if (trimmed_content[end_pos] == '[') {
                    depth += 1;
                } else if (trimmed_content[end_pos] == ']') {
                    depth -= 1;
                }
            }

            if (depth != 0) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    indent + 2,
                    "unmatched '[' in quoted branch name",
                    .{},
                );
                return error.ParseError;
            }

            // end_pos is one past the matching ']' — inner excludes both glyphs.
            branch_name = trimmed_content[1 .. end_pos - 1];
            rest_after_branch = lexer.trim(trimmed_content[end_pos..]);
        } else {
            // Normal branch: tokenize on space
            var parts = std.mem.tokenizeAny(u8, content, " ");
            branch_name = parts.next() orelse {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    indent + 2,
                    "missing branch name in continuation",
                    .{},
                );
                return error.ParseError;
            };
            rest_after_branch = parts.rest();
        }

        // For non-pattern parsing, we still need a tokenizer for the rest
        var parts = std.mem.tokenizeAny(u8, rest_after_branch, " ");

        // Check for |? catch-all continuation
        if (std.mem.eql(u8, branch_name, "?")) {
            // This is a catch-all continuation: |? [Metatype binding] |> pipeline
            var catchall_metatype: ?[]const u8 = null;
            var binding: ?[]const u8 = null;
            var rest = parts.rest();

            // Check if next token is a metatype (Transition, Profile, or Audit)
            if (parts.peek()) |next| {
                if (std.mem.eql(u8, next, "Transition") or
                    std.mem.eql(u8, next, "Profile") or
                    std.mem.eql(u8, next, "Audit"))
                {
                    catchall_metatype = try self.allocator.dupe(u8, next);
                    _ = parts.next(); // consume metatype

                    // Metatype requires a binding or explicit _ discard
                    // e.g., |? Transition t |> ... or |? Audit _ |> ...
                    if (parts.peek()) |binding_name| {
                        if (std.mem.startsWith(u8, binding_name, "|>")) {
                            try self.reporter.addError(
                                .PARSE001,
                                self.current,
                                indent + 2,
                                "Metatype '{s}' requires a binding (e.g., |? {s} t |>) or explicit discard (|? {s} _ |>).",
                                .{ catchall_metatype.?, catchall_metatype.?, catchall_metatype.? },
                            );
                            return error.ParseError;
                        }
                        // Validate binding is a valid identifier (or _ for discard)
                        if (!std.mem.eql(u8, binding_name, "_") and !lexer.isValidIdentifier(binding_name)) {
                            try self.reporter.addError(
                                .PARSE001,
                                self.current,
                                indent + 2,
                                "Invalid binding '{s}'. Bindings must be valid identifiers or '_' for discard.",
                                .{binding_name},
                            );
                            return error.InvalidBinding;
                        }
                        binding = try self.allocator.dupe(u8, binding_name);
                        _ = parts.next(); // consume binding
                    } else {
                        try self.reporter.addError(
                            .PARSE001,
                            self.current,
                            indent + 2,
                            "Metatype '{s}' requires a binding (e.g., |? {s} t |>) or explicit discard (|? {s} _ |>).",
                            .{ catchall_metatype.?, catchall_metatype.?, catchall_metatype.? },
                        );
                        return error.ParseError;
                    }
                    rest = parts.rest();
                }
            }

            const catch_all_branch = try self.allocator.dupe(u8, "?");
            try self.context_stack.append(self.allocator, .{
                .in_continuation = .{
                    .branch = catch_all_branch,
                    .binding = binding,
                },
            });
            defer {
                _ = self.context_stack.pop();
                self.allocator.free(catch_all_branch);
            }

            // Pay-for-nothing rule: catch-all at the dispatch site disables
            // comptime elision and routes unhandled branches into a handler.
            // That's a real runtime cost (struct construction for metatype
            // variants, routing for bare). If the consumer doesn't engage
            // — body is pure `_` discard — they paid the cost for zero
            // information gain. Strictly worse than the no-catch-all default.
            //
            // Rule: catch-all body must do real work. `|? |> _` and
            // `|? Metatype _ |> _` are rejected; `|? Metatype t |> body` and
            // `|? Metatype _ |> work(...)` are accepted (the latter because
            // the body does work even though the binding is discarded).
            //
            // See `docs/EFFECT_BRANCHES.md` "Dispatch-site catch-all rules".
            if (std.mem.indexOf(u8, rest, "|>")) |idx| {
                const after = std.mem.trim(u8, rest[idx + 2 ..], " \t");
                if (std.mem.eql(u8, after, "_")) {
                    try self.reporter.addError(
                        .KORU026,
                        self.current,
                        indent + 2,
                        "pay-for-nothing catch-all: body discards without engagement. Either remove the catch-all (unhandled optional branches are already no-ops) or use a metatype-bound form that does work (e.g., `|? Transition t |> log(t)`).",
                        .{},
                    );
                    return error.ParseError;
                }
            }

            // Parse step if present
            var step: ?ast.Step = null;

            if (std.mem.indexOf(u8, rest, "|>")) |_| {
                // Catch-all `|? ...` body — branch handler body, `_` allowed as sole step.
                const steps = try self.parsePipelineSteps(rest, true, location);
                defer self.allocator.free(steps);
                if (steps.len > 0) {
                    step = steps[0];
                }
            }

            return ast.Continuation{
                .branch = try self.allocator.dupe(u8, "?"), // Special branch name for catch-all
                .binding = binding,
                .binding_type = .branch_payload,
                .is_catchall = true,
                .catchall_metatype = catchall_metatype,
                .condition = null,
                .condition_expr = null,
                .node = step,
                .indent = indent,
                .continuations = &[_]ast.Continuation{},
                .location = location,
            };
        }

        // Normal branch continuation - validate branch name is a valid identifier.
        // Pattern branches ([...]) and raw pattern branches (`...`) skip this
        // check - the pattern is opaque data for transforms, not an identifier.
        if (!is_pattern_branch and !is_raw_branch and !std.mem.eql(u8, branch_name, "?")) {
            try self.rejectSnakeName(branch_name, self.current, "branch");
        }
        if (!is_pattern_branch and !is_raw_branch and !isValidIdentifier(branch_name)) {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                indent + 2,
                "invalid branch name '{s}' - must be a valid identifier",
                .{branch_name},
            );
            return error.ParseError;
        }

        const owned_branch = try self.allocator.dupe(u8, branch_name);
        errdefer self.allocator.free(owned_branch);

        // Check for binding (with optional annotations like r[mutable])
        var binding: ?[]const u8 = null;
        var binding_annotations: [][]const u8 = &[_][]const u8{};
        var destructure: []const ast.DestructureField = &.{};
        var rest = parts.rest();

        if (parts.peek()) |maybe_brace| {
            if (maybe_brace.len > 0 and maybe_brace[0] == '{') {
                // Shape-destructure at the binding position:
                //   | found { name, age: i64, user: { city } } |> ...
                // Consume whitespace tokens until the brace depth closes, then
                // parse the collected text recursively. Fields bind the
                // payload's same-named fields — by NAME, never by position.
                var collected = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                defer collected.deinit(self.allocator);
                var depth: i32 = 0;
                var closed = false;
                while (parts.peek() != null) {
                    const tok = parts.next().?;
                    if (collected.items.len > 0) try collected.append(self.allocator, ' ');
                    try collected.appendSlice(self.allocator, tok);
                    for (tok) |ch| {
                        if (ch == '{') depth += 1;
                        if (ch == '}') depth -= 1;
                    }
                    if (depth == 0) {
                        closed = true;
                        break;
                    }
                }
                if (!closed or depth != 0) {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        indent + 2,
                        "Unclosed '{{' in destructure binding.",
                        .{},
                    );
                    return error.InvalidBinding;
                }
                const text = collected.items;
                // Strip the outer braces and parse the field list.
                destructure = try self.parseDestructureFields(lexer.trim(text[1 .. text.len - 1]), indent);
                rest = parts.rest();
            }
        }

        if (destructure.len == 0) {
            if (parts.peek()) |next| {
            if (!std.mem.startsWith(u8, next, "|>") and !std.mem.startsWith(u8, next, "=>") and
                !std.mem.startsWith(u8, next, "->") and
                !std.mem.startsWith(u8, next, "@") and !std.mem.eql(u8, next, "when"))
            {
                // Check if binding has annotations: identifier[ann1|ann2|...]
                var identifier: []const u8 = next;

                if (std.mem.indexOf(u8, next, "[")) |bracket_start| {
                    // Has annotations - split into identifier and annotation parts
                    identifier = next[0..bracket_start];

                    // Find closing bracket
                    if (std.mem.indexOf(u8, next, "]")) |bracket_end| {
                        if (bracket_end > bracket_start + 1) {
                            // Parse annotations between [ and ]
                            const ann_str = next[bracket_start + 1 .. bracket_end];
                            var ann_list = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
                            errdefer {
                                for (ann_list.items) |ann| {
                                    self.allocator.free(ann);
                                }
                                ann_list.deinit(self.allocator);
                            }

                            var ann_iter = std.mem.splitScalar(u8, ann_str, '|');
                            while (ann_iter.next()) |ann| {
                                const trimmed_ann = lexer.trim(ann);
                                if (trimmed_ann.len > 0) {
                                    try ann_list.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                                }
                            }
                            binding_annotations = try ann_list.toOwnedSlice(self.allocator);
                        }
                    } else {
                        // Unclosed bracket
                        try self.reporter.addError(
                            .PARSE001,
                            self.current,
                            indent + 2,
                            "Unclosed bracket in binding annotation '{s}'.",
                            .{next},
                        );
                        return error.InvalidBinding;
                    }
                }

                // Validate that the identifier part is valid
                if (!lexer.isValidIdentifier(identifier)) {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        indent + 2,
                        "Invalid binding '{s}'. Bindings must be valid identifiers. Use '|>' for pipelines.",
                        .{identifier},
                    );
                    return error.InvalidBinding;
                }
                // This is a binding
                binding = try self.allocator.dupe(u8, identifier);
                _ = parts.next(); // consume it
                rest = parts.rest();
            }
        }
        }

        // Check for when clause
        var condition: ?[]const u8 = null;
        if (parts.peek()) |next| {
            if (std.mem.eql(u8, next, "when")) {
                _ = parts.next(); // consume "when"

                // Find where the condition ends: at the earliest arm-body
                // delimiter — `|>` chain, `->` produce, or `=>` branch
                // construct. A `when` guard can precede any of them
                // (`when g |> body`, `when g -> value`, `when g => branch`);
                // none of those glyphs is a legal expression operator, so the
                // earliest top-level occurrence unambiguously ends the guard.
                // (320_137: omitting `=>` swallowed `=> catalog` into the
                // condition and emit pasted `if (p == 0 => catalog)`.)
                const remaining = parts.rest();
                const pipe_idx = std.mem.indexOf(u8, remaining, "|>");
                const arrow_idx = indexOfTopLevelHeadArrow(remaining); // `=>` or `->`
                const end_idx: ?usize = if (pipe_idx) |p|
                    (if (arrow_idx) |a| @min(p, a) else p)
                else
                    arrow_idx;

                const condition_str = if (end_idx) |idx|
                    lexer.trim(remaining[0..idx])
                else
                    lexer.trim(remaining);

                if (condition_str.len == 0) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        indent + 2,
                        "missing condition after 'when'",
                        .{},
                    );
                    return error.ParseError;
                }

                // Reject `when (X)` — outer parens enclosing the whole expression
                // are redundant (`when` already delimits the condition). Inner
                // parens for sub-expression grouping stay legal: detect by
                // matching the opening `(` and checking it closes on the very
                // last character of the trimmed condition.
                if (condition_str[0] == '(') {
                    var paren_depth: i32 = 0;
                    var matched_at: ?usize = null;
                    for (condition_str, 0..) |c, i| {
                        if (c == '(') {
                            paren_depth += 1;
                        } else if (c == ')') {
                            paren_depth -= 1;
                            if (paren_depth == 0) {
                                matched_at = i;
                                break;
                            }
                        }
                    }
                    if (matched_at) |m| {
                        if (m == condition_str.len - 1) {
                            try errors.redundantWhenParens(
                                &self.reporter,
                                location.line,
                                indent + 2,
                                condition_str,
                            );
                            return error.ParseError;
                        }
                    }
                }

                condition = try self.allocator.dupe(u8, condition_str);

                // Update rest to skip past the condition — preserving the
                // delimiter (`|>` / `->` / `=>`) so the arm body parses downstream.
                if (end_idx) |idx| {
                    rest = remaining[idx..];
                } else {
                    rest = "";
                }
            }
        }

        // Parse the condition expression if we have one
        var condition_expr: ?*ast.Expression = null;
        if (condition) |cond_str| {
            var expr_parser = expression_parser.ExpressionParser.init(self.allocator, cond_str);
            defer expr_parser.deinit();

            condition_expr = expr_parser.parse() catch |err| {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    indent + 2,
                    "invalid when condition '{s}': {s}",
                    .{ cond_str, @errorName(err) },
                );
                return error.ParseError;
            };
        }

        // Parse step if present. A body is introduced by one of three glyphs,
        // each fixed by the producing event's declaration (see
        // `project_effect_resume_value_syntax`):
        //   `->`  produce the single payload (function-like; the resume value
        //         of a `-> T` effect arm, or a single-payload event's output).
        //   `|>`  chain a step (invocation / void continuation) — NEVER a value.
        //   `=>`  construct a branch (for an event declared with branches).
        var step: ?ast.Step = null;

        // `->` produce body: a single produce expression on the same line; the
        // emitter returns it directly (resume value / bare return). Detected on
        // a comment-stripped view so a `->` inside a trailing `// ...` comment
        // is never mistaken for a producer, and only when neither `|>` nor `=>`
        // is present — those are the chain/branch body-introducers and take
        // precedence; a standalone `->` is the produce case.
        {
            const rest_nc = stripTrailingLineComment(rest);
            if (std.mem.indexOf(u8, rest_nc, "|>") == null and
                std.mem.indexOf(u8, rest_nc, "=>") == null)
            {
                if (indexOfTopLevelArrow(rest_nc)) |arrow_at| {
                    const produced = lexer.trim(rest_nc[arrow_at + 2 ..]);
                    if (produced.len > 0) {
                        // Produce-is-the-call sugar: `-> mix(x: p)` resumes with
                        // the single payload produced by the event call. Parse it
                        // as an invocation so the emitter emits the handler call
                        // and returns its value; otherwise it's a Zig expression.
                        if (looksLikeInvocation(produced)) {
                            step = ast.Step{ .invocation = try self.parseEventInvocation(produced) };
                        } else if (struct_literal.isKoruStructLiteral(produced) or
                            struct_literal.isFieldPunningLiteral(produced))
                        {
                            // `-> { skip: v }` / `-> { p.x, p.y }` is a RECORD
                            // produce, not raw host code. Wrap it as a bare-return
                            // branch constructor — the same node the same-line
                            // produce path builds — so the record lowers through the
                            // shared struct-literal path for every emitter instead of
                            // leaking a verbatim `return { ... }`. Braced plain
                            // expressions (`{ a + b }`) and scalars fall through to
                            // `.expression`, which is correct for them.
                            step = ast.Step{ .branch_constructor = .{
                                .branch_name = try self.allocator.dupe(u8, ""),
                                .fields = &.{},
                                .plain_value = try self.allocator.dupe(u8, produced),
                                .has_expressions = true,
                                .is_bare_return = true,
                            } };
                        } else {
                            step = ast.Step{ .expression = try self.allocator.dupe(u8, produced) };
                        }
                    }
                }
            }
        }

        if (step == null and (std.mem.indexOf(u8, rest, "|>") != null or std.mem.indexOf(u8, rest, "=>") != null)) {
            // Check for multi-line branch constructor in the pipeline
            var full_rest = rest;
            var allocated_rest: ?[]u8 = null;
            defer if (allocated_rest) |ar| self.allocator.free(ar);

            // If the line leaves brace depth open, collect multi-line content.
            // BRACE-AWARE: the gatherer tracks net depth (quote-aware) and
            // stops the moment the block actually closes — whether on a bare
            // `}` line or mid-line (`} |> self { … }`). The old indent-only
            // heuristic ("stop only on a standalone `}`; swallow shallower
            // lines that contain any `}`") silently consumed a FOLLOWING
            // branch line whenever an inline block closed mid-line, dropping
            // that branch's header and binding (pinned by 210_139).
            var is_multiline_source_block = false;
            if (std.mem.indexOf(u8, rest, "{") != null and netBraces(rest) > 0) {
                is_multiline_source_block = true;
                var rest_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                defer rest_buf.deinit(self.allocator);
                try rest_buf.appendSlice(self.allocator, rest);

                var brace_depth: i32 = netBraces(rest);
                while (self.current < self.lines.len and brace_depth > 0) {
                    const next_line = self.lines[self.current];
                    const next_indent = lexer.getIndent(next_line);
                    const next_trimmed = lexer.trim(next_line);

                    // A shallower line with no closing brace can't be part of
                    // this block — malformed input; stop and let downstream
                    // parsing report it.
                    if (next_indent < indent and std.mem.indexOf(u8, next_trimmed, "}") == null) {
                        break;
                    }

                    // Add this line to our content (preserve newlines for Source blocks!)
                    try rest_buf.appendSlice(self.allocator, "\n");
                    try rest_buf.appendSlice(self.allocator, next_trimmed);
                    brace_depth += netBraces(next_trimmed);
                    self.current += 1;
                }

                allocated_rest = try rest_buf.toOwnedSlice(self.allocator);
                full_rest = allocated_rest.?;
            }

            // FIX: Handle multi-line function calls in pipelines
            // If we have unbalanced parentheses (more '(' than ')'), collect lines until balanced
            // Example:
            //   | done a |> step_b(
            //       a: a.result,
            //       b: 20)
            //       | done b |> ...  (nested continuation - MORE indented)
            // QUOTE-AWARE: parens inside string/char literals are text, not
            // structure. A quote-blind count saw `if(c == '(')` as unbalanced
            // and swallowed the following branch lines (pinned by 210_122).
            if (!is_multiline_source_block) {
                var paren_depth: i32 = netParens(full_rest);

                if (paren_depth > 0) {
                    // Unbalanced parens - collect lines until balanced
                    var rest_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                    defer rest_buf.deinit(self.allocator);
                    try rest_buf.appendSlice(self.allocator, full_rest);

                    while (self.current < self.lines.len and paren_depth > 0) {
                        const next_line = self.lines[self.current];
                        const next_trimmed = lexer.trim(next_line);

                        // Skip empty lines
                        if (next_trimmed.len == 0) {
                            self.current += 1;
                            continue;
                        }

                        // Count parens in this line (quote-aware, see above)
                        paren_depth += netParens(next_trimmed);

                        // Add this line to our content (with space separator)
                        try rest_buf.appendSlice(self.allocator, " ");
                        try rest_buf.appendSlice(self.allocator, next_trimmed);
                        self.current += 1;
                    }

                    if (allocated_rest) |ar| self.allocator.free(ar);
                    allocated_rest = try rest_buf.toOwnedSlice(self.allocator);
                    full_rest = allocated_rest.?;
                }
            }

            // After collecting multi-line Source block, parse the event's output branches
            // The cursor is now past the }, pointing at lines like | row |> ...
            // Only collect continuations MORE indented than this branch - siblings stay at parent level
            if (is_multiline_source_block) {
                // Push continuation context so Source blocks can capture the binding
                try self.context_stack.append(self.allocator, .{
                    .in_continuation = .{
                        .branch = owned_branch,
                        .binding = binding,
                    },
                });
                defer _ = self.context_stack.pop();

                // Use strict mode: only collect continuations MORE indented than this branch
                const source_block_continuations = try self.parseContinuationsWithMode(indent, true);
                // Source-block branch body — `_` allowed as sole step.
                const steps_inner = try self.parsePipelineSteps(full_rest, true, location);
                defer self.allocator.free(steps_inner);
                if (steps_inner.len > 0) {
                    // Build chain when body has multiple steps (e.g. `step1() |> step2 { ... }`).
                    // Without this, steps_inner[1..] were silently discarded, dropping any
                    // binding usage in the chain tail and producing false KORU100 errors.
                    // Mirrors the chain-build pattern in the non-multi-line path below.
                    var current_nested: []const ast.Continuation = source_block_continuations;

                    if (steps_inner.len > 1) {
                        var step_idx: usize = steps_inner.len;
                        while (step_idx > 1) { // Skip steps_inner[0], it's the head node
                            step_idx -= 1;

                            var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                            try cont_list.append(self.allocator, ast.Continuation{
                                .branch = try self.allocator.dupe(u8, ""), // Empty branch for void chain step
                                .binding = null,
                                .binding_annotations = &[_][]const u8{},
                                .binding_type = .branch_payload,
                                .condition = null,
                                .condition_expr = null,
                                .node = steps_inner[step_idx],
                                .indent = indent,
                                .continuations = current_nested,
                                .location = location,
                            });

                            current_nested = try cont_list.toOwnedSlice(self.allocator);
                        }
                    }

                    return ast.Continuation{
                        .branch = owned_branch,
                        .binding = binding,
                        .destructure = destructure,
                        .binding_annotations = binding_annotations,
                        .binding_type = .branch_payload,
                        .condition = condition,
                        .condition_expr = condition_expr,
                        .node = steps_inner[0],
                        .indent = indent,
                        .continuations = current_nested,
                        .location = location,
                    };
                }
            }

            // `|>` is inline glue — branch handler body must be on the same line.
            const after_pipe = blk: {
                if (std.mem.indexOf(u8, full_rest, "|>")) |pipe_idx| {
                    break :blk lexer.trim(full_rest[pipe_idx + 2 ..]);
                }
                break :blk full_rest;
            };

            if (after_pipe.len == 0) {
                try self.reporter.addErrorWithHintAndSpan(
                    .PARSE001,
                    location.line,
                    location.column,
                    2,
                    "Branch handler body must follow '|>' on the same line",
                    .{},
                    "Put the step inline after `|>`, e.g. `| ok x |> show(v: x)`. Multi-line argument lists may continue on following lines only when the call starts on the `|>` line.",
                    .{},
                );
                return error.ParseError;
            }

            // Push continuation context so Source blocks can capture the binding
            try self.context_stack.append(self.allocator, .{
                .in_continuation = .{
                    .branch = owned_branch,
                    .binding = binding,
                },
            });
            defer _ = self.context_stack.pop();

            // Handle multi-line source blocks in continuations
            // If full_rest ends with { (after trimming), collect lines until matching }
            const trimmed_rest = lexer.trim(full_rest);
            log_debug("[DEBUG] parseBranchContinuationBase: trimmed_rest='{s}' ends_with_brace={}\n", .{ trimmed_rest, trimmed_rest.len > 0 and trimmed_rest[trimmed_rest.len - 1] == '{' });
            if (trimmed_rest.len > 0 and trimmed_rest[trimmed_rest.len - 1] == '{') {
                // Multi-line source block - collect content
                var source_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                defer source_buf.deinit(self.allocator);

                // Start with the opening line
                try source_buf.appendSlice(self.allocator, full_rest);
                try source_buf.append(self.allocator, '\n');

                // Collect lines until we find matching }
                var brace_depth: i32 = 1;
                while (self.current < self.lines.len and brace_depth > 0) {
                    const src_line = self.lines[self.current];
                    const src_trimmed = lexer.trim(src_line);

                    // Count braces (skip braces in strings/comments)
                    brace_depth += lexer.countBraceDepthChange(src_trimmed);

                    try source_buf.appendSlice(self.allocator, src_line);
                    try source_buf.append(self.allocator, '\n');
                    self.current += 1;
                }

                if (allocated_rest) |ar| self.allocator.free(ar);
                allocated_rest = try source_buf.toOwnedSlice(self.allocator);
                full_rest = allocated_rest.?;
            }

            // A trailing top-level `-> produce` on the LAST step of the arm's
            // chain (`| else |> f(x): v -> g(v)`) is the bare-return produce
            // arm — same chain-tail grammar parseInlineContinuation strips for
            // flow-level chains (020_030). `->` is not a chain delimiter, so it
            // rides on the final segment; without this strip the invocation
            // parser's arg scan silently swallowed it (return_binding kept,
            // produce dropped). Detect on a comment-stripped view.
            var produce_tail: ?[]const u8 = null;
            {
                const full_nc = stripTrailingLineComment(full_rest);
                if (indexOfTopLevelArrow(full_nc)) |aidx| {
                    const pt = lexer.trim(full_nc[aidx + 2 ..]);
                    if (pt.len > 0) {
                        produce_tail = pt;
                        full_rest = lexer.trim(full_nc[0..aidx]);
                    }
                }
            }

            // Branch handler body — `_` allowed as sole step.
            const steps = try self.parsePipelineSteps(full_rest, true, location);
            defer self.allocator.free(steps);

            // The stripped produce becomes the innermost continuation of the
            // chain: a bare-return branch_constructor (the same node the
            // subflow-head `head(): v -> expr` produce uses).
            const produce_conts: []const ast.Continuation = if (produce_tail) |pt| blk: {
                const conts = try self.allocator.alloc(ast.Continuation, 1);
                conts[0] = ast.Continuation{
                    .branch = try self.allocator.dupe(u8, ""),
                    .binding = null,
                    .binding_annotations = &[_][]const u8{},
                    .binding_type = .branch_payload,
                    .condition = null,
                    .condition_expr = null,
                    .node = .{ .branch_constructor = .{
                        .branch_name = try self.allocator.dupe(u8, ""),
                        .fields = &.{},
                        .plain_value = try self.allocator.dupe(u8, pt),
                        .has_expressions = true,
                        .is_bare_return = true,
                    } },
                    .indent = indent,
                    .continuations = &.{},
                    .location = location,
                };
                break :blk conts;
            } else &[_]ast.Continuation{};

            if (steps.len > 0) {
                step = steps[0];

                if (steps.len == 1 and produce_tail != null) {
                    return ast.Continuation{
                        .branch = owned_branch,
                        .binding = binding,
                        .destructure = destructure,
                        .binding_annotations = binding_annotations,
                        .binding_type = .branch_payload,
                        .condition = condition,
                        .condition_expr = condition_expr,
                        .node = step,
                        .indent = indent,
                        .continuations = produce_conts,
                        .location = location,
                    };
                }

                // FIX: Chain additional steps as nested continuations
                // | done |> step1 |> step2 |> step3 should create:
                //   Continuation(step1) -> Continuation(step2) -> Continuation(step3)
                if (steps.len > 1) {
                    // Build chain from back to front; a stripped `-> produce`
                    // sits innermost, attached to the final step.
                    var current_nested: []const ast.Continuation = produce_conts;

                    var step_idx: usize = steps.len;
                    while (step_idx > 1) { // Skip steps[0], it's already in 'step'
                        step_idx -= 1;

                        var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                        try cont_list.append(self.allocator, ast.Continuation{
                            .branch = try self.allocator.dupe(u8, ""), // Empty branch for void continuation
                            .binding = null,
                            .binding_annotations = &[_][]const u8{},
                            .binding_type = .branch_payload,
                            .condition = null,
                            .condition_expr = null,
                            .node = steps[step_idx],
                            .indent = indent,
                            .continuations = current_nested,
                            .location = location,
                        });

                        current_nested = try cont_list.toOwnedSlice(self.allocator);
                    }

                    // Return continuation with first step and chained nested continuations
                    return ast.Continuation{
                        .branch = owned_branch,
                        .binding = binding,
                        .destructure = destructure,
                        .binding_annotations = binding_annotations,
                        .binding_type = .branch_payload,
                        .condition = condition,
                        .condition_expr = condition_expr,
                        .node = step,
                        .indent = indent,
                        .continuations = current_nested, // Points to steps[1] -> steps[2] -> ...
                        .location = location,
                    };
                }
            }
        }

        return ast.Continuation{
            .branch = owned_branch,
            .binding = binding,
            .destructure = destructure,
            .binding_annotations = binding_annotations,
            .binding_type = .branch_payload, // Parser always uses branch_payload; backend determines transition semantics
            .condition = condition,
            .condition_expr = condition_expr,
            .node = step,
            .indent = indent,
            .continuations = &[_]ast.Continuation{}, // Will be filled by caller
            .location = location,
        };
    }

    fn parseNestedContinuations(self: *Parser, parent_indent: usize) ![]ast.Continuation {
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            continuations.deinit(self.allocator);
        }

        // Look for continuation lines at greater indentation
        const saved_current = self.current;
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];

            if (lexer.isCommentLine(line)) {
                if (try self.rejectChainSplittingComment()) return error.ParseError;
                break;
            }

            // Check if this is a continuation line
            if (!lexer.isContinuationLine(line)) break;

            const indent = lexer.getIndent(line);

            // Only take continuations with greater indentation than parent
            if (indent <= parent_indent) break;

            // Parse this continuation and its nested ones
            self.current += 1;
        }

        // Now parse them in a second pass to avoid circular dependencies
        const end_current = self.current;
        self.current = saved_current;

        while (self.current < end_current) {
            const line = self.lines[self.current];

            // Skip comment lines
            if (lexer.isCommentLine(line)) {
                self.current += 1;
                continue;
            }

            if (!lexer.isContinuationLine(line)) break;

            const indent = lexer.getIndent(line);
            if (indent <= parent_indent) break;

            self.current += 1;
            const cont = try self.parseContinuationInternal(indent, parent_indent, self.getLineLocation(self.current - 1, indent));
            try continuations.append(self.allocator, cont);
        }

        return continuations.toOwnedSlice(self.allocator);
    }

    fn parseBranchContinuation(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        var cont = try self.parseBranchContinuationBase(content, indent, location);

        // Advance cursor to look for nested continuations on following lines
        // (parseNestedContinuationsForLevel expects self.current to point at potential nested lines)
        self.current += 1;

        const multi_line_continuations = try self.parseNestedContinuationsForLevel(indent);

        // If we have inline chained continuations (from |> step1 |> step2 |> step3),
        // attach multi-line continuations to the DEEPEST continuation in the chain
        if (cont.continuations.len > 0 and multi_line_continuations.len > 0) {
            // Find the deepest continuation
            var deepest = &cont.continuations[0];
            while (deepest.continuations.len > 0) {
                deepest = @constCast(&deepest.continuations[0]);
            }
            // Attach multi-line continuations to the deepest
            @constCast(deepest).continuations = multi_line_continuations;
        } else if (cont.continuations.len == 0) {
            // No inline chaining, just set multi-line continuations directly
            cont.continuations = multi_line_continuations;
        }
        // else: We have inline continuations but no multi-line ones, keep as-is

        return cont;
    }

    fn parsePipelineContinuationBase(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        // This is a |> continuation (pipeline step on new line)

        // FIRST: Check if this is a Source block invocation (event with Source parameter)
        // Source blocks need special handling - they capture raw text, not collapsed content
        const has_open_brace = std.mem.indexOf(u8, content, "{") != null;
        const has_close_brace = std.mem.indexOf(u8, content, "}") != null;
        log_debug("[DEBUG] parsePipelineContinuationBase: content='{s}' has_open={} has_close={}\n", .{ content, has_open_brace, has_close_brace });
        if (has_open_brace and !has_close_brace) {
            const brace_idx = std.mem.lastIndexOf(u8, content, "{") orelse unreachable;
            const invocation_str = lexer.trim(content[0..brace_idx]);

            // Parse the invocation to get the event path
            const temp_invocation = try self.parseEventInvocation(invocation_str);
            const path_str = try self.pathToString(temp_invocation.path);
            defer self.allocator.free(path_str);

            // Check if this event has a Source parameter
            var has_source_param = false;
            if (self.registry.getEventType(path_str)) |event_type| {
                if (event_type.input_shape) |shape| {
                    for (shape.fields) |field| {
                        if (field.is_source) {
                            has_source_param = true;
                            break;
                        }
                    }
                }
            }

            if (has_source_param) {
                // This IS a Source block - parse it properly!
                log_debug("[DEBUG] parsePipelineContinuationBase: has_source_param=true, path={s}\n", .{path_str});
                const result = try self.parseImplicitSourceBlock(indent, null, true);
                log_debug("[DEBUG] parseImplicitSourceBlock returned source len={d}\n", .{result.source.len});

                // Create the invocation with source_value
                var final_invocation: ast.Invocation = undefined;
                if (self.registry.getEventType(path_str)) |event_type| {
                    final_invocation = try self.createImplicitSourceInvocation(temp_invocation, result.source, result.phantom_type, event_type);
                } else {
                    final_invocation = try self.createImplicitSourceInvocationDefault(temp_invocation, result.source, result.phantom_type);
                }
                self.allocator.free(result.source);

                // Create the step and continuation
                const step = ast.Step{ .invocation = final_invocation };

                return ast.Continuation{
                    .branch = try self.allocator.dupe(u8, ""),
                    .binding = null,
                    .condition = null,
                    .condition_expr = null,
                    .node = step,
                    .indent = indent,
                    .continuations = result.continuations,
                    .location = location,
                };
            }
        }

        // Not a Source block - use regular multi-line branch constructor handling
        var full_content = content;
        var allocated_content: ?[]u8 = null;
        defer if (allocated_content) |ac| self.allocator.free(ac);

        // Check if this might be starting a multi-line branch constructor
        if (std.mem.indexOf(u8, content, "{") != null and std.mem.indexOf(u8, content, "}") == null) {
            // We have an opening brace but no closing brace - look for it on subsequent lines
            var content_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
            defer content_buf.deinit(self.allocator);
            try content_buf.appendSlice(self.allocator, content);

            // Track brace depth to handle nested objects (skip braces in strings/comments)
            var brace_depth: i32 = lexer.countBraceDepthChange(content);

            // Keep reading lines until all braces are matched
            while (self.current < self.lines.len and brace_depth > 0) {
                const next_line = self.lines[self.current];
                const next_indent = lexer.getIndent(next_line);

                // Stop if we hit a line with less indentation (unless it's just closing braces)
                const next_trimmed = lexer.trim(next_line);
                if (next_indent <= indent) {
                    // Check if it's only closing braces
                    var only_closing_braces = true;
                    for (next_trimmed) |c| {
                        if (c != '}' and c != ' ' and c != '\t') {
                            only_closing_braces = false;
                            break;
                        }
                    }
                    if (!only_closing_braces) break;
                }

                // Add this line to our content
                try content_buf.appendSlice(self.allocator, " ");
                try content_buf.appendSlice(self.allocator, next_trimmed);
                self.current += 1;

                // Update brace depth (skip braces in strings/comments)
                brace_depth += lexer.countBraceDepthChange(next_trimmed);
            }

            allocated_content = try content_buf.toOwnedSlice(self.allocator);
            full_content = allocated_content.?;
        }

        // If content is empty, look for body on subsequent indented lines
        if (lexer.trim(full_content).len == 0) {
            // Skip comment lines and find the first real content line
            while (self.current < self.lines.len) {
                const next_line = self.lines[self.current];
                const next_indent = lexer.getIndent(next_line);

                // Must be more indented than the |> line
                if (next_indent <= indent) break;

                // Skip comment lines
                if (lexer.isCommentLine(next_line)) {
                    self.current += 1;
                    continue;
                }

                // Skip blank lines
                if (lexer.trim(next_line).len == 0) {
                    self.current += 1;
                    continue;
                }

                // Found the body line - check if it's a continuation or an invocation
                if (lexer.isContinuationLine(next_line)) {
                    // It's a continuation - let the caller handle nested continuations
                    break;
                }

                // It's an invocation line - parse it as the body
                const body_content = lexer.trim(next_line);
                self.current += 1;

                // Parse the invocation
                // Line-start `|>` continuation (KORU010 territory) — not a branch body.
                const body_steps = try self.parsePipelineSteps(body_content, false, location);
                const body_step: ?ast.Step = if (body_steps.len > 0) body_steps[0] else null;

                // Parse continuations of this invocation (at greater indentation than the |> line)
                // Use `indent` (the |> line's indent), not `next_indent` (the body's indent)
                // This matches the behavior of inline |> where continuations are relative to the |> line
                var body_continuations: []const ast.Continuation = try self.parseNestedContinuationsForLevel(indent);

                // If there are chained steps, build the chain
                if (body_steps.len > 1) {
                    var current_nested: []const ast.Continuation = body_continuations;

                    var step_idx: usize = body_steps.len;
                    while (step_idx > 1) {
                        step_idx -= 1;

                        var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                        try cont_list.append(self.allocator, ast.Continuation{
                            .branch = try self.allocator.dupe(u8, ""),
                            .binding = null,
                            .binding_annotations = &[_][]const u8{},
                            .binding_type = .branch_payload,
                            .condition = null,
                            .condition_expr = null,
                            .node = body_steps[step_idx],
                            .indent = next_indent,
                            .continuations = current_nested,
                            .location = location,
                        });

                        current_nested = try cont_list.toOwnedSlice(self.allocator);
                    }
                    body_continuations = current_nested;
                }

                return ast.Continuation{
                    .branch = try self.allocator.dupe(u8, ""),
                    .binding = null,
                    .condition = null,
                    .condition_expr = null,
                    .node = body_step,
                    .indent = indent,
                    .continuations = body_continuations,
                    .location = location,
                };
            }

            try self.reporter.addError(
                .PARSE001,
                self.current,
                indent,
                "Pipeline continuation '|>' requires a step. Nested flows (~) are not allowed here.",
                .{},
            );
            return error.ParseError;
        }

        // Line-start `|>` continuation (KORU010 territory) — not a branch body.
        const steps = try self.parsePipelineSteps(full_content, false, location);
        const step: ?ast.Step = if (steps.len > 0) steps[0] else null;

        // FIX: Chain additional steps as nested continuations (same as parseBranchContinuationBase)
        if (steps.len > 1) {
            // Build chain from back to front
            var current_nested: []const ast.Continuation = &[_]ast.Continuation{};

            var step_idx: usize = steps.len;
            while (step_idx > 1) { // Skip steps[0], it's already in 'step'
                step_idx -= 1;

                var cont_list = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
                try cont_list.append(self.allocator, ast.Continuation{
                    .branch = try self.allocator.dupe(u8, ""), // Empty branch for void continuation
                    .binding = null,
                    .binding_annotations = &[_][]const u8{},
                    .binding_type = .branch_payload,
                    .condition = null,
                    .condition_expr = null,
                    .node = steps[step_idx],
                    .indent = indent,
                    .continuations = current_nested,
                    .location = location,
                });

                current_nested = try cont_list.toOwnedSlice(self.allocator);
            }

            return ast.Continuation{
                .branch = try self.allocator.dupe(u8, ""), // Empty branch for pipeline continuation
                .binding = null,
                .condition = null,
                .condition_expr = null,
                .node = step,
                .indent = indent,
                .continuations = current_nested, // Points to steps[1] -> steps[2] -> ...
                .location = location,
            };
        }

        return ast.Continuation{
            .branch = try self.allocator.dupe(u8, ""), // Empty branch for pipeline continuation
            .binding = null,
            .condition = null,
            .condition_expr = null,
            .node = step,
            .indent = indent,
            .continuations = &[_]ast.Continuation{}, // Will be filled by caller
            .location = location,
        };
    }

    fn parsePipelineSteps(
        self: *Parser,
        content: []const u8,
        allow_terminal_body: bool,
        location: errors.SourceLocation,
    ) ![]ast.Step {
        var steps = try std.ArrayList(ast.Step).initCapacity(self.allocator, 8);
        errdefer {
            for (steps.items) |*step| {
                step.deinit(self.allocator);
            }
            steps.deinit(self.allocator);
        }

        // Check if there's a @label at the end (without |>)
        var working_content = content;
        var trailing_label: ?[]const u8 = null;
        if (lexer.extractLabel(content)) |label| {
            trailing_label = try self.allocator.dupe(u8, label);
            working_content = lexer.withoutLabel(content);
        }

        // Split on `|>` AND `=>` at brace/paren/bracket depth 0 (outside strings
        // and line comments), tagging each segment with the delimiter that
        // preceded it: `=>` → construction, `|>`/first → ordinary step. The
        // delimiter is authoritative; parseStepKind never guesses from content.
        {
            var seg_start: usize = 0;
            var seg_is_ctor = false; // first segment is never `=>`-introduced
            var depth: i32 = 0;
            var in_str = false;
            var scan_end: usize = working_content.len;
            var k: usize = 0;
            while (k < working_content.len) {
                const c = working_content[k];
                if (in_str) {
                    if (c == '"' and (k == 0 or working_content[k - 1] != '\\')) in_str = false;
                    k += 1;
                    continue;
                }
                if (c == '"') {
                    in_str = true;
                    k += 1;
                    continue;
                }
                if (c == '/' and k + 1 < working_content.len and working_content[k + 1] == '/') {
                    scan_end = k; // line comment — stop here, emit final segment up to it
                    break;
                }
                if (c == '{' or c == '(' or c == '[') {
                    depth += 1;
                    k += 1;
                    continue;
                }
                if (c == '}' or c == ')' or c == ']') {
                    depth -= 1;
                    k += 1;
                    continue;
                }
                if (depth == 0 and k + 1 < working_content.len) {
                    const arrow = working_content[k + 1] == '>';
                    if (arrow and (c == '|' or c == '=')) {
                        const seg = lexer.trim(working_content[seg_start..k]);
                        if (seg.len > 0) {
                            try steps.append(self.allocator, try self.parseStepKind(seg, seg_is_ctor));
                        }
                        seg_is_ctor = (c == '=');
                        k += 2;
                        seg_start = k;
                        continue;
                    }
                }
                k += 1;
            }
            const last = lexer.trim(working_content[seg_start..scan_end]);
            if (last.len > 0) {
                try steps.append(self.allocator, try self.parseStepKind(last, seg_is_ctor));
            }
        }

        // Add trailing label if present
        if (trailing_label) |label| {
            try steps.append(self.allocator, ast.Step{ .label_apply = label });
        }

        // `_` (terminal) is legal ONLY as the sole step of a branch handler body.
        // - At index > 0 or with siblings: meaningless chain (`~A() |> _`,
        //   `| ok |> doX() |> _`, split-pipeline tails like 2104_12).
        // - In non-branch-body context: meaningless even alone — void chains
        //   produce no value to discard.
        for (steps.items, 0..) |step, i| {
            if (step != .terminal) continue;
            if (i > 0 or steps.items.len > 1) {
                try self.reporter.addErrorWithHintAndSpan(
                    .KORU010,
                    location.line,
                    location.column,
                    1,
                    "'_' is only legal as the sole body of a branch handler",
                    .{},
                    "'_' has meaning only as `| branch [binding] |> _`. Chaining `|> _` after another step is meaningless — drop the `|> _`.",
                    .{},
                );
                return error.ParseError;
            }
            if (!allow_terminal_body) {
                try self.reporter.addErrorWithHintAndSpan(
                    .KORU010,
                    location.line,
                    location.column,
                    1,
                    "'_' is only legal as the body of a branch handler",
                    .{},
                    "'_' has meaning only as `| branch [binding] |> _`. Outside a branch handler body — top-level void chain, split-pipeline tail — `|> _` is meaningless.",
                    .{},
                );
                return error.ParseError;
            }
        }

        return steps.toOwnedSlice(self.allocator);
    }

    fn parseStep(self: *Parser, content: []const u8) anyerror!ast.Step {
        // Default: a `|>`-introduced (or first/void) step — never a construction.
        return self.parseStepKind(content, false);
    }

    /// Parse one pipeline step. `force_ctor` is set by the splitter when the
    /// step was introduced by `=>` (the construct glyph). Construction-vs-
    /// invocation is decided by the DELIMITER, never guessed from content —
    /// that is the whole point of the `=>` design.
    fn parseStepKind(self: *Parser, content: []const u8, force_ctor: bool) anyerror!ast.Step {
        // Strip a trailing line comment. String-aware: a step carries invocation
        // arguments, and an argument carries string literals — a URL truncated
        // at its scheme separator reports as unbalanced parentheses (210_171).
        var clean_content = content;
        if (lexer.commentStart(content)) |comment_idx| {
            clean_content = content[0..comment_idx];
        }

        // In-flow compiler annotations: a chain step may carry a leading `[...]`
        // annotation (e.g. `[with]std/parser:grammar(...)`), exactly as a flow
        // head can. `looksLikeInvocation` requires an identifier start, so a
        // leading `[` never begins a valid bare step otherwise — there is no
        // ambiguity to resolve. Peel every leading annotation group (reusing the
        // flow-head `parseAnnotationBlock` path), classify the remainder as the
        // step, and hang the annotations on its invocation.
        {
            var rest = lexer.trim(clean_content);
            if (rest.len > 0 and rest[0] == '[') {
                var anns = try std.ArrayList([]const u8).initCapacity(self.allocator, 2);
                errdefer {
                    for (anns.items) |a| self.allocator.free(a);
                    anns.deinit(self.allocator);
                }
                while (rest.len > 0 and rest[0] == '[') {
                    const block = try self.parseAnnotationBlock(rest, self.current);
                    for (block.annotations) |a| try anns.append(self.allocator, a);
                    self.allocator.free(block.annotations); // strings moved into `anns`; free the slice
                    // Step annotations are inline by construction, so this is
                    // empty in practice; freed rather than assumed.
                    if (block.prose.len > 0) self.allocator.free(block.prose);
                    rest = lexer.trim(block.remaining);
                }
                var inner = try self.parseStepKind(rest, force_ctor);
                const owned = try anns.toOwnedSlice(self.allocator);
                switch (inner) {
                    .invocation => |*inv| inv.annotations = owned,
                    .label_with_invocation => |*lwi| lwi.invocation.annotations = owned,
                    else => {
                        for (owned) |a| self.allocator.free(a);
                        self.allocator.free(owned);
                    },
                }
                return inner;
            }
        }

        // Check for terminal marker (_)
        if (std.mem.eql(u8, lexer.trim(clean_content), "_")) {
            return ast.Step{ .terminal = {} };
        }

        // Check for label anchor declaration (#name event(...))
        if (lexer.startsWith(clean_content, "#")) {
            const after_hash = lexer.trim(clean_content[1..]);

            // Check if there's an event invocation after the label
            // Pattern: #label event(args) or #label event.path(args)
            const space_idx = std.mem.indexOfScalar(u8, after_hash, ' ');
            if (space_idx) |idx| {
                // We have something after the label - check if it looks like an invocation
                const potential_label = after_hash[0..idx];
                const after_space = lexer.trim(after_hash[idx + 1 ..]);

                // Check if what follows looks like an event invocation
                if (std.mem.indexOfScalar(u8, after_space, '(') != null or
                    std.mem.indexOfScalar(u8, after_space, '.') != null)
                {
                    // This is a label declaration pattern: #label event(args)
                    // Parse the invocation part
                    const inv_step = try self.parseStep(after_space);
                    if (inv_step == .invocation) {
                        return ast.Step{
                            .label_with_invocation = .{
                                .label = try self.allocator.dupe(u8, potential_label),
                                .invocation = inv_step.invocation,
                                .is_declaration = true, // # means declaration/anchor
                            },
                        };
                    }
                }
            }

            // If we get here, it's malformed - for now, parse as invocation
            // TODO: Better error handling
            return try self.parseStep(after_hash);
        }

        // Check for label jump (@label(args))
        if (lexer.startsWith(clean_content, "@")) {
            const after_at = lexer.trim(clean_content[1..]);

            // Check if there's a paren (args) after the label: @label(args)
            const paren_idx = std.mem.indexOfScalar(u8, after_at, '(');
            if (paren_idx) |p_idx| {
                // Extract label name (everything before the paren)
                const label_name = lexer.trim(after_at[0..p_idx]);

                // Find the matching closing parenthesis
                var depth: usize = 1;
                var args_end = p_idx + 1;
                while (args_end < after_at.len and depth > 0) : (args_end += 1) {
                    if (after_at[args_end] == '(') depth += 1;
                    if (after_at[args_end] == ')') depth -= 1;
                }

                // Parse the arguments
                const args_str = after_at[p_idx..args_end];
                const parsed_args = try self.parseArgsReported(args_str);
                defer self.allocator.free(parsed_args);

                try self.checkRedundantPunning(parsed_args, self.current);

                // Transfer ownership to AST
                var arg_list = try std.ArrayList(ast.Arg).initCapacity(self.allocator, parsed_args.len);
                defer arg_list.deinit(self.allocator);
                for (parsed_args) |arg| {
                    var ast_arg = ast.Arg{
                        .name = arg.name,
                        .value = arg.value,
                        .phantom_type = arg.phantom_type,
                        .had_explicit_label = arg.had_explicit_label,
                    };
                    tryParseArgExpression(self.allocator, &ast_arg);
                    try arg_list.append(self.allocator, ast_arg);
                }

                return ast.Step{ .label_jump = .{
                    .label = try self.allocator.dupe(u8, label_name),
                    .args = try arg_list.toOwnedSlice(self.allocator),
                } };
            }

            // Simple label apply without args (for compatibility)
            return ast.Step{ .label_apply = try self.allocator.dupe(u8, after_at) };
        }

        // Check for nested flow invocation (~event) - NOT ALLOWED in pipeline steps
        // Flows (~) can only appear at the top level, not nested inside continuations
        if (lexer.startsWith(clean_content, "~")) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "Nested flows (~) are not allowed inside continuations. Use a bare tor call instead: remove the ~ prefix.",
                .{},
            );
            return error.ParseError;
        }

        // `=>`-introduced step: a branch construction. The delimiter is
        // authoritative — we do NOT guess from content (no `is_regular_bc`,
        // no newline-sensitivity). Layout is irrelevant.
        if (force_ctor) {
            return try self.parseConstructionStep(clean_content);
        }

        // `|>`-introduced (or first/void) step: invocation or Zig expression,
        // NEVER a branch constructor. A construction here requires `=>`.
        if (looksLikeInvocation(clean_content)) {
            return ast.Step{ .invocation = try self.parseEventInvocation(clean_content) };
        }

        // Glyph discipline (KORU103): `|>` CHAINS a step — an invocation or a `_`
        // discard — it never introduces a bare VALUE. A value (literal, arithmetic,
        // bare identifier, …) is PRODUCED with `->`. This kills the old
        // `! v p |> p.acc + 1` resume spelling in favour of `! v p -> p.acc + 1`.
        //
        // Point-free chain (option A): a bare identifier-PATH after `|>`
        // (`stage-b`, `std/io:print`) is a PROVISIONAL invocation whose args
        // thread in — accept it here; the desugar resolves it to an event and
        // errors if it isn't one. A value/expression (spaces, operators, a
        // leading digit, literals) still falls through to KORU103 below.
        bare_ident: {
            const bare = lexer.trim(clean_content);
            if (bare.len == 0) break :bare_ident;
            if (!(std.ascii.isAlphabetic(bare[0]) or bare[0] == '_')) break :bare_ident;
            for (bare) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':' or c == '/') continue;
                break :bare_ident;
            }
            return ast.Step{ .invocation = try self.parseEventInvocation(clean_content) };
        }

        if (!std.mem.eql(u8, clean_content, "_")) {
            try self.reporter.addError(
                .KORU103,
                self.current,
                0,
                "`|>` chains a step; it cannot introduce the value `{s}` — produce a value with `->` (e.g. `-> {s}`)",
                .{ clean_content, clean_content },
            );
            return error.ParseError;
        }

        // Anything else at body position is a Zig expression node: string
        // literal, numeric literal, anonymous struct literal, arithmetic
        // expression, effect-branch resume value, etc.
        return ast.Step{ .expression = try self.allocator.dupe(u8, clean_content) };
    }

    /// Parse the content after `=>` into a branch-constructor step. Handles the
    /// brace form (`name { ... }`, `.{ ... }`) and the braceless identity form
    /// (`name`, `name value`). No content heuristics — the `=>` already told us
    /// this is a construction.
    fn parseConstructionStep(self: *Parser, clean_content: []const u8) !ast.Step {
        if (std.mem.indexOf(u8, clean_content, "{") != null) {
            return ast.Step{ .branch_constructor = try self.parseBranchConstructorWithContext(clean_content) };
        }
        const trimmed_content = lexer.trim(clean_content);
        const first_space = std.mem.indexOfAny(u8, trimmed_content, &[_]u8{ ' ', '\t' });
        const candidate_name = if (first_space) |idx| lexer.trim(trimmed_content[0..idx]) else trimmed_content;
        const expr_part = if (first_space) |idx| lexer.trim(trimmed_content[idx..]) else "";
        return ast.Step{ .branch_constructor = .{
            .branch_name = try self.allocator.dupe(u8, candidate_name),
            .fields = &.{},
            .plain_value = if (expr_part.len > 0) try self.allocator.dupe(u8, expr_part) else null,
            .has_expressions = expr_part.len > 0,
        } };
    }

    /// Returns true iff `content` starts with an identifier path followed
    /// by `(` (function-style invocation) or `{` (Source-block invocation).
    /// Used to discriminate invocation-shaped steps from expression steps
    /// at body position.
    fn looksLikeInvocation(content: []const u8) bool {
        var i: usize = 0;
        // Skip leading whitespace
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
        if (i >= content.len) return false;
        // First char must start an identifier path (letter or underscore)
        if (!(std.ascii.isAlphabetic(content[i]) or content[i] == '_')) return false;
        // Consume identifier path: IDENT(.IDENT)*(:IDENT(.IDENT)*)?
        // Also accept `[` `]` for Source-block type hints inside the path.
        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':' or c == '/' or c == '[' or c == ']') continue;
            break;
        }
        // Optional `|variant` suffix (e.g. `std/kernel:self|mlir { ... }`).
        // The `|` must be immediately followed by an identifier start, so this
        // can never swallow a `|>` chain glyph (its next char is `>`).
        if (i + 1 < content.len and content[i] == '|' and
            (std.ascii.isAlphabetic(content[i + 1]) or content[i + 1] == '_'))
        {
            i += 1;
            while (i < content.len) : (i += 1) {
                const c = content[i];
                if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '[' or c == ']') continue;
                break;
            }
        }
        // After the path, skip whitespace
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
        if (i >= content.len) return false;
        // Invocation if next char is `(` (function-style) or `{` (Source-block).
        return content[i] == '(' or content[i] == '{';
    }

    fn splitFieldsRespectingBraces(self: *Parser, fields_str: []const u8) ![][]const u8 {
        var result = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer result.deinit(self.allocator);

        var brace_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        var paren_depth: i32 = 0;
        var in_string = false;
        var field_start: usize = 0;

        var i: usize = 0;
        while (i < fields_str.len) : (i += 1) {
            const c = fields_str[i];

            // Handle string literals
            if (c == '"' and (i == 0 or fields_str[i - 1] != '\\')) {
                in_string = !in_string;
                continue;
            }

            if (in_string) continue;

            // Track brace, bracket, and paren depth
            if (c == '{') brace_depth += 1;
            if (c == '}') brace_depth -= 1;
            if (c == '[') bracket_depth += 1;
            if (c == ']') bracket_depth -= 1;
            if (c == '(') paren_depth += 1;
            if (c == ')') paren_depth -= 1;

            // Split on comma only at top level (outside all nested structures)
            if (c == ',' and brace_depth == 0 and bracket_depth == 0 and paren_depth == 0) {
                const field = lexer.trim(fields_str[field_start..i]);
                if (field.len > 0) {
                    try result.append(self.allocator, field);
                }
                field_start = i + 1;
            }
        }

        // Don't forget the last field
        const last_field = lexer.trim(fields_str[field_start..]);
        if (last_field.len > 0) {
            try result.append(self.allocator, last_field);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn parseBranchConstructor(self: *Parser, content: []const u8) !ast.BranchConstructor {
        return self.parseBranchConstructorWithContext(content, self.isInProc());
    }

    /// Parse a branch-construct string in either form: braced `ok { f: v }`
    /// (delegates to parseBranchConstructorWithContext) or braceless `ok v` /
    /// `ok` (identity construct). Used for a same-line `=> construct` after a
    /// bare-return head bind (`~run = head(): v => ok v`).
    fn parseConstructString(self: *Parser, s: []const u8) !ast.BranchConstructor {
        if (std.mem.indexOfScalar(u8, s, '{') != null) {
            return self.parseBranchConstructorWithContext(s);
        }
        const sp = std.mem.indexOfAny(u8, s, &[_]u8{ ' ', '\t' });
        const branch_name = if (sp) |idx| lexer.trim(s[0..idx]) else s;
        const plain = if (sp) |idx| lexer.trim(s[idx..]) else "";
        return ast.BranchConstructor{
            .branch_name = try self.allocator.dupe(u8, branch_name),
            .fields = &.{},
            .plain_value = if (plain.len > 0) try self.allocator.dupe(u8, plain) else null,
            .has_expressions = plain.len > 0,
        };
    }

    fn parseBranchConstructorWithContext(self: *Parser, content: []const u8) !ast.BranchConstructor {
        // Format: branch_name { field: value, field: value }
        // OR shorthand: .{ .branch_name = .{ fields } }
        const brace_idx = std.mem.indexOf(u8, content, "{") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                1,
                "expected '{{' in branch constructor",
                .{},
            );
            return error.ParseError;
        };

        // Find the closing brace first (needed for both regular and shorthand forms)
        const closing_idx = std.mem.lastIndexOf(u8, content, "}") orelse {
            try self.reporter.addError(
                .PARSE004,
                self.current + 1,
                @intCast(brace_idx + 1),
                "unmatched '{{' in branch constructor",
                .{},
            );
            return error.ParseError;
        };

        var branch_name = lexer.trim(content[0..brace_idx]);
        var fields_content: []const u8 = content[brace_idx + 1 .. closing_idx];

        // Empty constructor braces are a relic: `=> done {}` and `=> done`
        // used to parse to DIFFERENT trees (the braces flipped
        // has_expressions), a two-spellings-one-meaning wart. Ruled illegal
        // 2026-07-02: a payloadless construct has exactly one spelling.
        if (!std.mem.eql(u8, branch_name, ".") and lexer.trim(fields_content).len == 0) {
            try self.reporter.addErrorWithHint(
                .PARSE003,
                self.current + 1,
                @intCast(brace_idx + 1),
                "empty constructor braces on '{s}' — a payloadless branch constructs with its name alone",
                .{branch_name},
                "drop the braces: write '=> {s}' instead of '=> {s} {{}}'",
                .{ branch_name, branch_name },
            );
            return error.ParseError;
        }

        // A regular `name { ... }` construction requires a valid single-identifier
        // branch name (`.` is the `.{ ... }` immediate shorthand, handled below).
        // Rejects malformed names like `invalid name { ... }` (space in name).
        if (!std.mem.eql(u8, branch_name, ".") and !isValidIdentifier(branch_name)) {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                1,
                "invalid branch constructor name '{s}' — must be a single identifier",
                .{branch_name},
            );
            return error.ParseError;
        }

        // Check for .{ shorthand (immediate return)
        // Format: .{ .branch_name = .{ fields } }
        if (std.mem.eql(u8, branch_name, ".")) {
            const inner_content = lexer.trim(content[brace_idx + 1 .. closing_idx]);
            // Format should be: .branch_name = .{ fields }
            // Extract branch_name from .branch_name
            if (lexer.startsWith(inner_content, ".")) {
                const after_dot = inner_content[1..];
                const eq_idx = std.mem.indexOf(u8, after_dot, "=");
                if (eq_idx) |idx| {
                    branch_name = lexer.trim(after_dot[0..idx]);
                    // Extract fields from the inner .{ fields } part
                    const after_eq = lexer.trim(after_dot[idx + 1 ..]);
                    // Find the inner .{ ... }
                    const inner_brace_idx = std.mem.indexOf(u8, after_eq, "{");
                    const inner_closing_idx = std.mem.lastIndexOf(u8, after_eq, "}");
                    if (inner_brace_idx != null and inner_closing_idx != null) {
                        fields_content = after_eq[inner_brace_idx.? + 1 .. inner_closing_idx.?];
                    } else {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current + 1,
                            0,
                            "invalid .{{ shorthand syntax - expected .{{ .branch_name = .{{ fields }} }}",
                            .{},
                        );
                        return error.ParseError;
                    }
                } else {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        0,
                        "invalid .{{ shorthand syntax - expected .{{ .branch_name = ... }}",
                        .{},
                    );
                    return error.ParseError;
                }
            } else {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    0,
                    "invalid .{{ shorthand syntax - expected .{{ .branch_name = ... }}",
                    .{},
                );
                return error.ParseError;
            }
        }

        // Validate branch name is a valid identifier
        if (!isValidIdentifier(branch_name)) {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                0,
                "invalid branch name '{s}' in constructor - must be a valid identifier",
                .{branch_name},
            );
            return error.ParseError;
        }

        const fields_str = lexer.trim(fields_content);

        // Check if this is a plain value (identity branch) vs field punning
        // Plain value: no field separators AND no field access patterns
        // Field punning: contains '.' paths like w.value that should become { value: w.value }
        const is_plain_value = blk: {
            if (fields_str.len == 0) break :blk false;
            var depth: i32 = 0;
            var has_dot_at_depth_0 = false;
            var has_comma_at_depth_0 = false;
            var has_operator_at_depth_0 = false;
            for (fields_str) |c| {
                switch (c) {
                    '{', '(', '[' => depth += 1,
                    '}', ')', ']' => depth -= 1,
                    ':', '=' => if (depth == 0) break :blk false, // Explicit field syntax
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
            // If there's a dot but no operators, it's field punning, not plain value
            // e.g., { w.value } should be { value: w.value }, not identity
            // But { a + b } should be plain value (identity branch)
            if (has_dot_at_depth_0 and !has_operator_at_depth_0) break :blk false;
            // If there are commas, it's multiple fields with punning
            if (has_comma_at_depth_0) break :blk false;
            break :blk true;
        };

        if (is_plain_value) {
            // Plain value syntax: branch { expr } → return .{ .branch = expr }
            // Used for identity branches like: sum a + b
            return ast.BranchConstructor{
                .branch_name = try self.allocator.dupe(u8, branch_name),
                .fields = &.{},
                .plain_value = try self.allocator.dupe(u8, fields_str),
                .has_expressions = true,
            };
        }

        var fields = try std.ArrayList(ast.Field).initCapacity(self.allocator, 4);
        errdefer {
            for (fields.items) |*field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }

        if (fields_str.len > 0) {
            // Parse fields: field: value, field: value
            // But be careful with nested objects that contain commas
            const fields_list = try self.splitFieldsRespectingBraces(fields_str);
            defer self.allocator.free(fields_list);

            for (fields_list) |field_str| {
                const trimmed = lexer.trim(field_str);
                // Support both : and = as field separators
                const colon_idx = std.mem.indexOf(u8, trimmed, ":");
                const eq_idx = std.mem.indexOf(u8, trimmed, "=");
                const sep_idx = if (colon_idx) |c_idx|
                    (if (eq_idx) |e_idx| @min(c_idx, e_idx) else c_idx)
                else
                    eq_idx;

                const field_name: []const u8 = if (sep_idx) |idx| blk: {
                    // Explicit form: name: value or .name = value
                    break :blk lexer.trim(trimmed[0..idx]);
                } else blk: {
                    // Shorthand form - check if it's a field access like b.value
                    const dot_idx = std.mem.lastIndexOf(u8, trimmed, ".");
                    if (dot_idx) |idx| {
                        // Take the field name after the dot
                        break :blk lexer.trim(trimmed[idx + 1 ..]);
                    } else {
                        // Simple identifier - use as is
                        break :blk trimmed;
                    }
                };

                // Reject Zig-style struct syntax: .{ .field = value }
                // Koru uses: branch_name { field: value }
                if (lexer.startsWith(field_name, ".")) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        1,
                        "Zig-style struct syntax '.{s}' is not valid Koru — use 'field_name: value' instead of '.field_name = value'",
                        .{field_name},
                    );
                    return error.ParseError;
                }

                const field_value = if (sep_idx) |idx|
                    lexer.trim(trimmed[idx + 1 ..])
                else
                    trimmed; // The whole expression becomes the value

                // Reject redundant explicit labels: `{ x: x }` and `{ x: p.x }`
                // both pun to `{ x }` / `{ p.x }`. Only fires when the user
                // wrote an explicit separator and punning would produce the
                // same field name — purely syntactic, no false positives.
                if (sep_idx != null) {
                    const punning_arg = lexer.ArgPair{
                        .name = field_name,
                        .value = field_value,
                        .had_explicit_label = true,
                    };
                    if (lexer.isRedundantExplicitLabel(punning_arg)) {
                        try self.reporter.addErrorWithHint(
                            .PARSE005,
                            self.current,
                            1,
                            "redundant explicit label '{s}:' — the value '{s}' already puns to '{s}'",
                            .{ field_name, field_value, field_name },
                            "drop the label: write '{s}' instead of '{s}: {s}'",
                            .{ field_value, field_name, field_value },
                        );
                        return error.ParseError;
                    }
                }

                // Structural validation: reject function calls in branch constructors.
                // Branch constructors must be pure — no side effects, no function calls.
                // Builtins (@as, @intCast), arithmetic, array indexing, and conditionals
                // are allowed. If you need to compute a value, use event chaining.
                // (Shares the one expression-admission predicate with the KORU104
                // wall in flow_checker — never a second implementation.)
                if (expression_parser.textContainsCall(self.allocator, field_value)) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        1,
                        "branch constructor field '{s}' contains a function call — branch constructors must be pure. Use tor chaining instead.",
                        .{field_name},
                    );
                    return error.ParseError;
                }

                // Always store expression string for code generation
                try fields.append(self.allocator, ast.Field{
                    .name = try self.allocator.dupe(u8, field_name),
                    .type = try self.allocator.dupe(u8, "auto"), // Type will be inferred
                    .expression_str = try self.allocator.dupe(u8, field_value),
                    .expression = null,
                    .owns_expression = false,
                });
            }
        }

        // Has expressions if any field has a non-simple value
        const has_expressions = true; // All branch constructors can have expressions now

        return ast.BranchConstructor{
            .branch_name = try self.allocator.dupe(u8, branch_name),
            .fields = try fields.toOwnedSlice(self.allocator),
            .has_expressions = has_expressions,
        };
    }

    fn parseBranchPayloadShape(self: *Parser, branch_line: []const u8) !ast.Shape {
        // Look for opening brace on the current line
        const brace_start = std.mem.indexOf(u8, branch_line, "{") orelse {
            // No shape specified, return empty shape
            return ast.Shape{ .fields = &.{} };
        };

        // Check if closing brace is on the same line - BUT find the MATCHING one
        const close_offset = blk: {
            var depth: i32 = 0;
            var i = brace_start;
            while (i < branch_line.len) : (i += 1) {
                if (branch_line[i] == '{') {
                    depth += 1;
                } else if (branch_line[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        // Found matching closing brace
                        break :blk i - brace_start;
                    }
                }
            }
            break :blk null;
        };

        if (close_offset) |off| {
            // Single-line shape
            const content = lexer.trim(branch_line[brace_start + 1 .. brace_start + off]);
            return self.parseShape(content);
        }

        // Multi-line shape - collect lines until matching brace
        var shape_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer shape_content.deinit(self.allocator);

        // Add content from the first line (after the opening brace)
        const first_line_content = lexer.trim(branch_line[brace_start + 1 ..]);
        if (first_line_content.len > 0) {
            try shape_content.appendSlice(self.allocator, first_line_content);
            try shape_content.append(self.allocator, ',');
        }

        // Track brace depth to handle nested types
        var brace_depth: i32 = 1;
        const start_line = self.current;

        while (self.current < self.lines.len and brace_depth > 0) {
            const line = self.lines[self.current];
            self.current += 1;

            // Skip empty lines
            const trimmed = lexer.trim(line);
            if (trimmed.len == 0) continue;

            // Count braces properly, skipping those in strings/comments
            var in_string = false;
            var string_char: ?u8 = null;
            var closing_brace_idx: ?usize = null;

            for (trimmed, 0..) |c, idx| {
                // Skip line comments
                if (!in_string and c == '/' and idx + 1 < trimmed.len and trimmed[idx + 1] == '/') {
                    break;
                }

                // Handle string literals
                if (!in_string and (c == '"' or c == '\'')) {
                    in_string = true;
                    string_char = c;
                } else if (in_string) {
                    if (c == '\\' and idx + 1 < trimmed.len) {
                        continue; // Escaped char handled by next iteration
                    } else if (c == string_char) {
                        in_string = false;
                        string_char = null;
                    }
                } else {
                    // Not in string or comment - count braces
                    if (c == '{') brace_depth += 1;
                    if (c == '}') {
                        brace_depth -= 1;
                        if (brace_depth == 0) {
                            closing_brace_idx = idx;
                            break;
                        }
                    }
                }
            }

            if (closing_brace_idx) |end_idx| {
                // Found closing brace - extract content before it
                const final_content = lexer.trim(trimmed[0..end_idx]);
                if (final_content.len > 0) {
                    try shape_content.appendSlice(self.allocator, final_content);
                }
                // Don't back up - parseBranch expects current to be at the next line
            } else if (brace_depth > 0) {
                // Add this line's content
                try shape_content.appendSlice(self.allocator, trimmed);
                try shape_content.append(self.allocator, ',');
            }
        }

        if (brace_depth != 0) {
            try self.reporter.addError(
                .PARSE004,
                start_line,
                @intCast(brace_start),
                "unmatched '{{' in branch payload shape",
                .{},
            );
            return error.ParseError;
        }

        return self.parseShape(shape_content.items);
    }

    /// Phantom state in a type position must use ANGLE brackets: `Type<state>`.
    /// The square-bracket form `Type[state]` is otherwise silently swallowed
    /// into the type string (phantom stays null → no obligation checking, false
    /// safety; AST shows `*Resource[active!]` keeps the brackets in `type` and
    /// reports `phantom: null`). Reject it loudly with a fix hint. No-op unless
    /// `s` ends with a phantom-shaped `[...]`.
    fn rejectSquareBracketPhantom(self: *Parser, s: []const u8) !void {
        if (s.len == 0 or s[s.len - 1] != ']') return;
        var depth: i32 = 0;
        var j: usize = s.len - 1;
        var open: ?usize = null;
        while (true) : (j -= 1) {
            if (s[j] == ']') {
                depth += 1;
            } else if (s[j] == '[') {
                depth -= 1;
                if (depth == 0) {
                    open = j;
                    break;
                }
            }
            if (j == 0) break;
        }
        const at = open orelse return;
        if (at == 0) return; // leading `[..]` = slice/array prefix, not phantom
        const content = s[at + 1 .. s.len - 1];
        if (content.len == 0) return;
        // Phantom-shaped content carries a state name (letter) or obligation
        // marker `!`, distinguishing it from a numeric array size like `[3]`.
        var looks_phantom = false;
        for (content) |c| {
            if (std.ascii.isAlphabetic(c) or c == '!') {
                looks_phantom = true;
                break;
            }
        }
        if (!looks_phantom) return;
        // `self.current` has usually drifted past the declaration by the time a
        // shape is parsed, so locate the source line that actually contains the
        // offending `[state]` rather than blaming wherever the cursor landed.
        const bracket_expr = s[at..]; // e.g. "[active!]"
        var report_line: usize = self.current + 1;
        var report_col: usize = 1;
        for (self.lines, 0..) |line_text, idx| {
            if (std.mem.indexOf(u8, line_text, bracket_expr)) |col| {
                report_line = idx + 1;
                report_col = col + 1;
                break;
            }
        }
        try self.reporter.addErrorWithHint(
            .KORU033,
            report_line,
            report_col,
            "invalid phantom-state syntax",
            .{},
            "phantom state uses angle brackets — write `{s}<{s}>`",
            .{ s[0..at], content },
        );
        return error.ParseError;
    }

    /// Cross-module type references use slash-separated module qualifiers — the
    /// same separator as imports (`std/parser`) and call sites
    /// (`std/parser:parse`, rejected dotted by `rejectDotNamespace`). This is the
    /// type-reference twin of that rule: one language rule (`.` is not a namespace
    /// separator), one error code (KORU035), two syntactic sites. The `.` test is
    /// unambiguous here: this path is reached only when a `:` type-selector is
    /// present, and genuine Zig types (`std.mem.Allocator`) never carry a `:`.
    fn rejectDottedModuleQualifier(self: *Parser, module_path: []const u8, base_type: []const u8) !void {
        if (std.mem.indexOfScalar(u8, module_path, '.') == null) return;
        // Locate the offending `module.path:` text rather than blaming the cursor,
        // which has usually drifted past the declaration by shape-parse time.
        const needle = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_path, base_type });
        var report_line: usize = self.current + 1;
        var report_col: usize = 1;
        for (self.lines, 0..) |line_text, idx| {
            if (std.mem.indexOf(u8, line_text, needle)) |col| {
                report_line = idx + 1;
                report_col = col + 1;
                break;
            }
        }
        try self.reporter.addError(
            .KORU035,
            report_line,
            report_col,
            "'.' is not a namespace separator in '{s}' — use '/' (e.g. 'std/io:Type', not 'std.io:Type'). '.' is member access after ':'.",
            .{module_path},
        );
        return error.ParseError;
    }

    /// Effect branches fire 0-to-N times, so obligation markers on their
    /// signature are read from the effect-branch's own scope (see the obligation
    /// model). Two marker directions are incoherent at 0-to-N firing and are
    /// rejected here, at the signature level — never by inspecting a proc body:
    ///
    ///   - payload `<!state>` (discharge): promises to discharge a received
    ///     obligation exactly once via a branch that may fire zero or many
    ///     times. Forbidden. (Issue `<state!>` IS fine: the proc creates one
    ///     obligation per firing and hands it in — see 400_105.)
    ///   - resume `<state!>` (issue): hands the proc a fresh obligation that
    ///     escapes the firing un-discharged. Forbidden. (Discharge `<!state>`
    ///     IS fine: cleaned up in-scope, handed back — see 400_106.)
    ///
    /// Marker direction is purely positional: leading `!` = discharge,
    /// trailing `!` = issue (the convention in phantom_parser + auto_discharge).
    fn validateEffectBranchObligation(self: *Parser, branch: ast.Branch, branch_line: usize) !void {
        if (branch.kind != .effect) return;

        // Payload (proc → handler): a discharge marker is the forbidden
        // "discharge an outer obligation 0-to-N times" promise.
        for (branch.payload.fields) |field| {
            if (field.phantom) |raw| {
                const ph = lexer.trim(raw);
                if (ph.len > 0 and ph[0] == '!') {
                    const col = self.columnOfInLine(branch_line, ph);
                    try self.reporter.addErrorWithHint(
                        .KORU027,
                        branch_line,
                        col,
                        "effect branch payload cannot discharge an obligation",
                        .{},
                        "a `!` effect branch fires 0-to-N times, so `<{s}>` (discharge) is incoherent — drop the leading `!` for plain state matching, or issue one obligation per firing with `<{s}!>`",
                        .{ ph, ph[1..] },
                    );
                    return error.ParseError;
                }
            }
        }

        // Resume (handler → proc): an issue marker is the forbidden
        // "hand back a fresh obligation that escapes the firing" promise.
        if (branch.resume_phantom) |raw| {
            const rp = lexer.trim(raw);
            if (rp.len > 0 and rp[rp.len - 1] == '!') {
                const col = self.columnOfInLine(branch_line, rp);
                try self.reporter.addErrorWithHint(
                    .KORU027,
                    branch_line,
                    col,
                    "effect branch resume type cannot issue an obligation",
                    .{},
                    "a `!` effect branch fires 0-to-N times, so resuming `<{s}>` (issue) would let the obligation escape un-discharged — drop the trailing `!`, or discharge in-scope with `<!{s}>`",
                    .{ rp, rp[0 .. rp.len - 1] },
                );
                return error.ParseError;
            }
        }

        // Resume arms: each arm IS a resume, so the same issue-forbidden rule
        // applies per arm (discharge `<!state>` stays legal per arm, like 400_106).
        if (branch.resume_arms) |arms| {
            for (arms) |*arm| {
                if (arm.phantom) |raw| {
                    const ap = lexer.trim(raw);
                    if (ap.len > 0 and ap[ap.len - 1] == '!') {
                        const col = self.columnOfInLine(branch_line, ap);
                        try self.reporter.addErrorWithHint(
                            .KORU027,
                            branch_line,
                            col,
                            "resume arm '{s}' cannot issue an obligation",
                            .{arm.name},
                            "a `!` effect branch fires 0-to-N times, so resuming `<{s}>` (issue) would let the obligation escape un-discharged — drop the trailing `!`, or discharge in-scope with `<!{s}>`",
                            .{ ap, ap[0 .. ap.len - 1] },
                        );
                        return error.ParseError;
                    }
                }
            }
        }
    }

    /// Locate the 1-based column of `needle` on the given 1-based source line,
    /// for caret placement. Falls back to column 1 if not found.
    fn columnOfInLine(self: *Parser, line_1based: usize, needle: []const u8) usize {
        if (line_1based == 0 or line_1based > self.lines.len) return 1;
        const line_text = self.lines[line_1based - 1];
        if (std.mem.indexOf(u8, line_text, needle)) |idx| return idx + 1;
        return 1;
    }

    /// Find the first `|` at bracket depth 0 in a decl-branch line body, or null.
    /// Used to split same-line resume arms off an effect branch head
    /// (`ask i32 | halved i32 | timeout` → split at the first `|`).
    /// The `>` of a `->` arrow is NOT a closing angle bracket — skip it so a
    /// head like `ask i32 -> i32 | ...` still splits (and then gets rejected
    /// by the both-forms check, with the right error).
    fn findDepth0Pipe(content: []const u8) ?usize {
        var depth: i32 = 0;
        for (content, 0..) |c, idx| {
            if (c == '[' or c == '{' or c == '(' or c == '<') {
                depth += 1;
            } else if (c == '>' and idx > 0 and content[idx - 1] == '-') {
                // `->` arrow, not a bracket
            } else if (c == ']' or c == '}' or c == ')' or c == '>') {
                depth -= 1;
            } else if (depth == 0 and c == '|') {
                return idx;
            }
        }
        return null;
    }

    /// Strip a trailing `<...>` phantom from a type string. Returns the type
    /// without the phantom; writes the phantom content (if any) to `phantom_out`.
    /// Same angle-scan as branch payloads and `-> T` resume types.
    fn splitTrailingPhantom(type_str: []const u8, phantom_out: *?[]const u8) []const u8 {
        phantom_out.* = null;
        if (type_str.len == 0 or type_str[type_str.len - 1] != '>') return type_str;
        var angle_depth: i32 = 0;
        var j: usize = type_str.len - 1;
        const end_pos = j;
        var start_pos: ?usize = null;
        while (j > 0) : (j -= 1) {
            if (type_str[j] == '>') {
                angle_depth += 1;
            } else if (type_str[j] == '<') {
                angle_depth -= 1;
                if (angle_depth == 0) {
                    start_pos = j;
                    break;
                }
            }
        }
        if (start_pos) |start| {
            if (start > 0) {
                const content = type_str[start + 1 .. end_pos];
                if (content.len > 0) {
                    phantom_out.* = content;
                    return lexer.trim(type_str[0..start]);
                }
            }
        }
        return type_str;
    }

    /// Parse one resume arm: `name`, `name Type`, or `name Type<phantom>`.
    fn parseResumeArm(self: *Parser, content: []const u8, line_index: usize) !ast.ResumeArm {
        const trimmed = lexer.trim(content);
        if (trimmed.len == 0) {
            try self.reporter.addError(
                .PARSE003,
                line_index + 1,
                1,
                "empty resume arm - expected 'name' or 'name Type' after '|'",
                .{},
            );
            return error.ParseError;
        }
        if (std.mem.indexOf(u8, trimmed, "->") != null) {
            try self.reporter.addError(
                .PARSE003,
                line_index + 1,
                1,
                "'->' is not allowed in a resume arm - the arm's type IS what the handler resumes with",
                .{},
            );
            return error.ParseError;
        }

        // Arm name: first whitespace-delimited token. `-` is kebab word-glue,
        // same as branch names.
        var name_end: usize = 0;
        while (name_end < trimmed.len and trimmed[name_end] != ' ' and trimmed[name_end] != '\t') : (name_end += 1) {}
        const arm_name = trimmed[0..name_end];
        try self.rejectSnakeName(arm_name, line_index, "resume arm");

        var phantom_src: ?[]const u8 = null;
        const type_src = splitTrailingPhantom(lexer.trim(trimmed[name_end..]), &phantom_src);

        // Same wall as branch payloads: `()` is not a type; a payload-less
        // arm is spelled by omission (`| timeout`).
        if (std.mem.eql(u8, type_src, "()")) {
            try self.reporter.addError(
                .PARSE003,
                line_index + 1,
                1,
                "'()' is not a payload type - a payload-less resume arm is spelled by omission (write `| {s}`)",
                .{arm_name},
            );
            return error.ParseError;
        }

        return ast.ResumeArm{
            .name = try self.allocator.dupe(u8, arm_name),
            .type = if (type_src.len > 0) try self.allocator.dupe(u8, type_src) else null,
            .phantom = if (phantom_src) |p| try self.allocator.dupe(u8, p) else null,
        };
    }

    /// Parse a same-line resume-arm tail: `| halved i32 | timeout` (leading `|`
    /// included). Segments are split on depth-0 `|`.
    fn parseResumeArmList(self: *Parser, arms_src: []const u8, line_index: usize) ![]const ast.ResumeArm {
        var arms = try std.ArrayList(ast.ResumeArm).initCapacity(self.allocator, 2);
        errdefer {
            for (arms.items) |*arm| arm.deinit(self.allocator);
            arms.deinit(self.allocator);
        }

        var rest = arms_src;
        while (rest.len > 0) {
            std.debug.assert(rest[0] == '|');
            const body = rest[1..];
            const next_pipe = findDepth0Pipe(body);
            const segment = if (next_pipe) |np| body[0..np] else body;
            rest = if (next_pipe) |np| body[np..] else "";
            try arms.append(self.allocator, try self.parseResumeArm(segment, line_index));
        }

        try self.rejectDuplicateResumeArms(arms.items, line_index);
        return try arms.toOwnedSlice(self.allocator);
    }

    fn rejectDuplicateResumeArms(self: *Parser, arms: []const ast.ResumeArm, line_index: usize) !void {
        for (arms, 0..) |*arm, i| {
            for (arms[0..i]) |*earlier| {
                if (std.mem.eql(u8, earlier.name, arm.name)) {
                    try self.reporter.addError(
                        .PARSE003,
                        line_index + 1,
                        1,
                        "duplicate resume arm name '{s}'",
                        .{arm.name},
                    );
                    return error.ParseError;
                }
            }
        }
    }

    /// Multi-arm resume sum, indented form (210_092): `|` lines indented under
    /// a `!` decl line are that effect's resume arms — exactly ONE level in,
    /// all aligned. Base-indent `|` lines remain the event's terminal branches.
    /// Called from the decl-branch collection loops right after parseBranch
    /// returns an effect branch; consumes the arm lines.
    fn collectIndentedResumeArms(self: *Parser, branch: *ast.Branch, effect_indent: usize) !void {
        var arms = try std.ArrayList(ast.ResumeArm).initCapacity(self.allocator, 2);
        errdefer {
            for (arms.items) |*arm| arm.deinit(self.allocator);
            arms.deinit(self.allocator);
        }

        var arm_indent: ?usize = null;
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            if (!lexer.isBranchContinuation(line)) break;
            const indent = lexer.getIndent(line);
            if (indent <= effect_indent) break; // base-indent sibling branch

            const line_trimmed = lexer.trim(line);
            if (line_trimmed[0] == '!') {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    1,
                    "effect branches never nest - composition lives in the '|' resume arms",
                    .{},
                );
                return error.ParseError;
            }
            if (arm_indent) |ai| {
                if (indent != ai) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        1,
                        "resume arms must align at exactly one level under their effect branch",
                        .{},
                    );
                    return error.ParseError;
                }
            } else {
                arm_indent = indent;
            }

            var content = lexer.trim(line_trimmed[1..]);
            if (lexer.commentStart(content)) |comment_idx| {
                content = lexer.trim(content[0..comment_idx]);
            }
            try arms.append(self.allocator, try self.parseResumeArm(content, self.current));
            self.current += 1;
        }

        if (arms.items.len == 0) return;

        if (branch.resume_type != null) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "effect branch cannot declare both a '-> T' resume and named resume arms - the arms are the resume",
                .{},
            );
            return error.ParseError;
        }

        // Merge with any same-line arms (mixed spelling is legal: arms riding
        // the `!` line plus indented continuation arms are one flat sum).
        if (branch.resume_arms) |existing| {
            var merged = try std.ArrayList(ast.ResumeArm).initCapacity(self.allocator, existing.len + arms.items.len);
            errdefer merged.deinit(self.allocator);
            try merged.appendSlice(self.allocator, existing);
            try merged.appendSlice(self.allocator, arms.items);
            arms.clearRetainingCapacity();
            self.allocator.free(@constCast(existing));
            branch.resume_arms = try merged.toOwnedSlice(self.allocator);
        } else {
            branch.resume_arms = try arms.toOwnedSlice(self.allocator);
        }
        try self.rejectDuplicateResumeArms(branch.resume_arms.?, self.current);
    }

    fn parseBranch(self: *Parser) !ast.Branch {
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);

        // We'll consume this line
        self.current += 1;

        // Detect branch kind from prefix: `|` = terminal, `!` = effect.
        // isBranchContinuation already validated the first char so we trust it here.
        const branch_kind: ast.BranchKind = if (trimmed.len > 0 and trimmed[0] == '!') .effect else .terminal;
        const after_bar = lexer.trim(trimmed[1..]);

        // Deferred branch decl (`| &<branch>`) — REMOVED (retired 2026-07-15,
        // frag-deferred-deref-repudiated). Rejected loudly instead of parsed.
        var branch_start = after_bar;
        if (lexer.startsWith(after_bar, "&")) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "deferred branch `| &<branch>` was removed — the deferred/deref mechanism is retired. Declare the call site with a required effect-branch instead.",
                .{},
            );
            return error.ParseError;
        }

        // Check for ?! prefix (panic branch) before ? (optional).
        // `?!` is ONE marker: omit handler => synthesized @panic(...)
        // (UNSAFE to ignore). Not `?` (optional) + `!` (effect).
        var is_panic = false;
        var is_optional = false;
        if (lexer.startsWith(branch_start, "?!")) {
            is_panic = true;
            branch_start = lexer.trim(branch_start[2..]);
        } else if (lexer.startsWith(branch_start, "?")) {
            is_optional = true;
            branch_start = lexer.trim(branch_start[1..]);
        }

        // Raw-quoted branch name in a DECL: | `…` or | […] — the same two
        // source encodings continuations accept (quote-decode). The inner
        // content IS the name, byte-for-byte; raw names skip identifier
        // validation (names are bytes). A branch declared with the raw name
        // `*` is a name-CLASS: it matches any handled branch name that no
        // other declared branch matches exactly (see branch contract checks).
        // Extracted before comment/resume/brace scanning so name bytes stay
        // opaque to all later scans.
        var raw_branch_name: ?[]const u8 = null;
        if (branch_start.len > 0 and branch_start[0] == '`') {
            const close = std.mem.indexOfScalarPos(u8, branch_start, 1, '`') orelse {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "unterminated raw branch name - missing closing '`'",
                    .{},
                );
                return error.ParseError;
            };
            raw_branch_name = branch_start[1..close];
            branch_start = lexer.trim(branch_start[close + 1 ..]);
        } else if (branch_start.len > 0 and branch_start[0] == '[') {
            var depth: i32 = 0;
            var close: ?usize = null;
            for (branch_start, 0..) |c, idx| {
                if (c == '[') {
                    depth += 1;
                } else if (c == ']') {
                    depth -= 1;
                    if (depth == 0) {
                        close = idx;
                        break;
                    }
                }
            }
            const end = close orelse {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "unterminated raw branch name - missing closing ']'",
                    .{},
                );
                return error.ParseError;
            };
            raw_branch_name = branch_start[1..end];
            branch_start = lexer.trim(branch_start[end + 1 ..]);
        }

        // Strip inline comments (// ...) so they don't leak into types or annotations.
        // This must happen before any brace/phantom/annotation parsing.
        if (lexer.commentStart(branch_start)) |comment_idx| {
            branch_start = lexer.trim(branch_start[0..comment_idx]);
        }

        // Multi-arm resume sum, single-line form (210_093):
        //     ! ask i32 | halved i32 | timeout
        // `|` segments riding the `!` line at depth 0 are the effect's resume
        // arms. Split them off BEFORE resume-type/payload scanning so the head
        // parses exactly like a plain effect branch. Only effect branches carry
        // arms; a depth-0 `|` on a terminal decl line never occurs (terminal
        // branches are one per line by construction).
        var resume_arms: ?[]const ast.ResumeArm = null;
        errdefer if (resume_arms) |arms| {
            for (arms) |*arm| {
                var mutable_arm = arm.*;
                mutable_arm.deinit(self.allocator);
            }
            self.allocator.free(@constCast(arms));
        };
        if (branch_kind == .effect) {
            if (findDepth0Pipe(branch_start)) |split_idx| {
                const arms_src = branch_start[split_idx..];
                branch_start = lexer.trim(branch_start[0..split_idx]);
                resume_arms = try self.parseResumeArmList(arms_src, self.current - 1);
            }
        }

        // Detect resume type: `-> ResumeT` suffix on effect branches.
        // Scan at bracket/brace depth 0 so we don't trip on `->` inside a struct
        // payload `{ ... }` or a phantom-state `[...]`.
        var resume_type: ?[]const u8 = null;
        var resume_phantom: ?[]const u8 = null;
        {
            var depth: i32 = 0;
            var idx: usize = 0;
            while (idx + 1 < branch_start.len) : (idx += 1) {
                const c = branch_start[idx];
                if (c == '[' or c == '{' or c == '(' or c == '<') {
                    depth += 1;
                } else if (c == ']' or c == '}' or c == ')' or c == '>') {
                    depth -= 1;
                } else if (depth == 0 and c == '-' and branch_start[idx + 1] == '>') {
                    // `->` is the bare-return arrow and belongs on the EVENT
                    // signature (`event x {} -> T`). On a terminal `|` branch
                    // DECL it is illegal — only effect `!` branches carry a
                    // `-> ResumeT` resume type. (A `->` in a branch HANDLER is
                    // fine: that produces the value and is parsed elsewhere.)
                    if (branch_kind == .terminal) {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current - 1,
                            1,
                            "'->' is not allowed in a continuation branch declaration - the bare-return arrow belongs on the tor signature (`tor x {{}} -> T`), not a `|` branch",
                            .{},
                        );
                        return error.ParseError;
                    }
                    var rt = lexer.trim(branch_start[idx + 2 ..]);
                    // Phantom-capture the resume type, same as a branch payload:
                    // `-> *R<!state>` → resume_type `*R`, resume_phantom `!state`.
                    // (Read from the effect-branch scope: `<!state>` discharges here.)
                    if (rt.len > 0 and rt[rt.len - 1] == '>') {
                        var angle_depth: i32 = 0;
                        var j: usize = rt.len - 1;
                        const end_pos = j;
                        var start_pos: ?usize = null;
                        while (j > 0) : (j -= 1) {
                            if (rt[j] == '>') {
                                angle_depth += 1;
                            } else if (rt[j] == '<') {
                                angle_depth -= 1;
                                if (angle_depth == 0) {
                                    start_pos = j;
                                    break;
                                }
                            }
                        }
                        if (start_pos) |start| {
                            if (start > 0) {
                                const content = rt[start + 1 .. end_pos];
                                if (content.len > 0) {
                                    resume_phantom = try self.allocator.dupe(u8, content);
                                    rt = lexer.trim(rt[0..start]);
                                }
                            }
                        }
                    }
                    if (rt.len > 0) {
                        resume_type = try self.allocator.dupe(u8, rt);
                    }
                    branch_start = lexer.trim(branch_start[0..idx]);
                    break;
                }
            }
        }

        // Single-field record resume (`! ask -> { a: i64 }`) collapses to the
        // scalar `! ask -> i64`; only a 2+-field record earns the braces. (210_150)
        if (resume_type) |rt| {
            if (isSingleFieldRecordType(rt)) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "single field in record resume `{s}` — collapse to the scalar `-> <type>`; a record resume is for two or more fields",
                    .{rt},
                );
                return error.ParseError;
            }
        }

        // An effect's resume is EITHER a single anonymous `-> T` OR a named
        // sum of arms — never both (the arms ARE the resume).
        if (resume_type != null and resume_arms != null) {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "effect branch cannot declare both a '-> T' resume and named resume arms - the arms are the resume",
                .{},
            );
            return error.ParseError;
        }

        // Check for struct shape { ... } vs identity type
        const brace_idx = std.mem.indexOf(u8, branch_start, "{");

        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (annotations.items) |ann| self.allocator.free(ann);
            annotations.deinit(self.allocator);
        }

        // Identity branch syntax: | branch Type or | branch Type[annotation]
        // Struct branch syntax: | branch { field: Type } or | branch { field: Type }[annotation]
        if (brace_idx == null) {
            // Identity branch: | branch Type[annotation]
            // Find branch name (first identifier token). `-` is a legal Koru
            // name-char (kebab) and is normalized to `_` downstream; without it
            // here, `| not-found` would split into name `not` + bogus type
            // `-found`. The `->` resume-type case is already stripped above, so a
            // `-` at this point is always kebab word-glue.
            var branch_name: []const u8 = undefined;
            var after_name: []const u8 = undefined;
            if (raw_branch_name) |rn| {
                // Raw-quoted name already extracted; no identifier validation.
                branch_name = rn;
                after_name = branch_start;
            } else {
                var name_end: usize = 0;
                while (name_end < branch_start.len and
                    (std.ascii.isAlphanumeric(branch_start[name_end]) or
                     branch_start[name_end] == '_' or branch_start[name_end] == '-'))
                {
                    name_end += 1;
                }

                if (name_end == 0) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current,
                        1,
                        "branch missing name",
                        .{},
                    );
                    return error.ParseError;
                }

                branch_name = branch_start[0..name_end];

                try self.rejectSnakeName(branch_name, self.current - 1, "branch");

                // Validate branch name is a valid identifier
                if (!isValidIdentifier(branch_name)) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current - 1,
                        1,
                        "invalid branch name '{s}' - must be a valid identifier",
                        .{branch_name},
                    );
                    return error.ParseError;
                }
                after_name = branch_start[name_end..];
            }

            // Rest is the type, possibly with [annotation]
            const type_and_annotation = lexer.trim(after_name);

            // `()` is not a type — an empty payload is spelled by OMISSION
            // (`! ask`, `| done`). The unit exists only on the value side
            // (the proc calls `ask()` positionally). Rejected here so the
            // ML/Rust unit instinct gets a guiding koru-level diagnostic
            // instead of a misleading KORU030 three stages later.
            if (std.mem.eql(u8, type_and_annotation, "()")) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "'()' is not a payload type - an empty payload is spelled by omission (write `! {s}`; resume arms may follow: `! {s} | ok i32 | fail`)",
                    .{ branch_name, branch_name },
                );
                return error.ParseError;
            }

            // Check if this is an empty payload (just branch name, no type)
            if (type_and_annotation.len == 0) {
                // Empty payload - like | done
                return ast.Branch{
                    .name = try self.allocator.dupe(u8, branch_name),
                    .payload = ast.Shape{ .fields = &.{} },
                    .is_optional = is_optional,
                    .is_panic = is_panic,
                    .kind = branch_kind,
                    .resume_type = resume_type,
                    .resume_phantom = resume_phantom,
                    .resume_arms = resume_arms,
                    .annotations = try annotations.toOwnedSlice(self.allocator),
                };
            }

            // Wildcard payload: | branch *
            // Means "has bindable payload, shape unspecified". Distinguishable from
            // identity (| branch *T[state]) because bare `*` has no following type.
            if (std.mem.eql(u8, type_and_annotation, "*")) {
                return ast.Branch{
                    .name = try self.allocator.dupe(u8, branch_name),
                    .payload = ast.Shape{
                        .fields = &.{},
                        .is_wildcard = true,
                    },
                    .is_optional = is_optional,
                    .is_panic = is_panic,
                    .kind = branch_kind,
                    .resume_type = resume_type,
                    .resume_phantom = resume_phantom,
                    .resume_arms = resume_arms,
                    .annotations = try annotations.toOwnedSlice(self.allocator),
                };
            }

            // Identity branches carry the full type string (including any phantom
            // type suffix).  Phantom extraction happens below; we no longer strip
            // trailing [identifier] as a "branch annotation" because bare phantom
            // state literals (e.g. [celsius], [open]) were incorrectly swallowed
            // here.  The only annotation historically used on identity branches
            // ([mutable]) is unused in current code and is better handled as a
            // phantom type or binding annotation in the continuation.
            var type_str = type_and_annotation;

            // Phantom labels: Type<tag>. Angle brackets have no Zig
            // type-position meaning, so any `<...>` at type end is
            // unambiguously phantom.
            var phantom: ?[]const u8 = null;
            if (type_str.len > 0 and type_str[type_str.len - 1] == '>') {
                var angle_depth: i32 = 0;
                var j: usize = type_str.len - 1;
                const end_pos = j;
                var start_pos: ?usize = null;
                while (j > 0) : (j -= 1) {
                    if (type_str[j] == '>') {
                        angle_depth += 1;
                    } else if (type_str[j] == '<') {
                        angle_depth -= 1;
                        if (angle_depth == 0) {
                            start_pos = j;
                            break;
                        }
                    }
                }
                if (start_pos) |start| {
                    if (start > 0) {
                        const angle_content = type_str[start + 1 .. end_pos];
                        if (angle_content.len > 0) {
                            phantom = try self.allocator.dupe(u8, angle_content);
                            type_str = type_str[0..start];
                        }
                    }
                }
            }

            // Reject the square-bracket phantom form `Type[state]` (must be `Type<state>`).
            try self.rejectSquareBracketPhantom(type_str);

            // Canonical text type — same rule as a braced payload field
            // (parseShape), on the phantom-stripped BASE. Reject the raw Zig
            // slice; `string` is KEPT in the AST as the surface type and
            // lowered to []const u8 only at the Zig emission boundary.
            if (std.mem.eql(u8, type_str, "[]const u8")) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "'[]const u8' is not a Koru tor-payload type. Use 'string' for text — it lowers to []const u8 for Zig",
                    .{},
                );
                return error.ParseError;
            }

            // Parse cross-module type reference: module.path:TypeName
            // Handle type prefixes like ?*, *, [], []const that come before the module path
            var module_path: ?[]const u8 = null;
            var actual_type = type_str;
            var type_prefix: []const u8 = "";

            // Strip type prefix before looking for module colon
            const prefixes = [_][]const u8{ "[]const ", "?*const ", "*const ", "[]", "?*", "?", "*" };
            for (prefixes) |prefix| {
                if (std.mem.startsWith(u8, type_str, prefix)) {
                    type_prefix = prefix;
                    type_str = type_str[prefix.len..];
                    break;
                }
            }

            // Parse cross-module type reference
            // Find colon that's NOT inside brackets (to avoid [:0] sentinel syntax)
            const module_colon_idx: ?usize = blk: {
                var bracket_depth: i32 = 0;
                for (type_str, 0..) |c, idx| {
                    if (c == '[') bracket_depth += 1 else if (c == ']') bracket_depth -= 1 else if (c == ':' and bracket_depth == 0) break :blk idx;
                }
                break :blk null;
            };
            if (module_colon_idx) |colon_idx| {
                // Extract module path before the colon
                try self.rejectDottedModuleQualifier(type_str[0..colon_idx], type_str[colon_idx + 1 ..]);
                module_path = try self.allocator.dupe(u8, type_str[0..colon_idx]);
                const base_type = type_str[colon_idx + 1 ..];
                if (type_prefix.len > 0) {
                    actual_type = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ type_prefix, base_type });
                } else {
                    actual_type = try self.allocator.dupe(u8, base_type);
                }
            } else if (type_prefix.len > 0) {
                actual_type = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ type_prefix, type_str });
            } else {
                actual_type = try self.allocator.dupe(u8, type_str);
            }

            // Create identity field with __type_ref convention
            var fields = try self.allocator.alloc(ast.Field, 1);
            fields[0] = ast.Field{
                .name = try self.allocator.dupe(u8, "__type_ref"),
                .type = actual_type,
                .module_path = module_path,
                .phantom = phantom,
            };

            return ast.Branch{
                .name = try self.allocator.dupe(u8, branch_name),
                .payload = ast.Shape{ .fields = fields },
                .is_optional = is_optional,
                .is_panic = is_panic,
                .kind = branch_kind,
                .resume_type = resume_type,
                .resume_phantom = resume_phantom,
                .resume_arms = resume_arms,
                .annotations = try annotations.toOwnedSlice(self.allocator),
            };
        }

        // Struct branch syntax: | branch { field: Type }
        const branch_name = raw_branch_name orelse blk: {
            const scanned = lexer.trim(branch_start[0..brace_idx.?]);

            try self.rejectSnakeName(scanned, self.current - 1, "branch");

            // Validate branch name is a valid identifier
            if (!isValidIdentifier(scanned)) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "invalid branch name '{s}' - must be a valid identifier",
                    .{scanned},
                );
                return error.ParseError;
            }
            break :blk scanned;
        };

        // Parse the payload shape (might be multi-line)
        // Note: parseBranchPayloadShape will advance self.current if multi-line
        var payload = try self.parseBranchPayloadShape(branch_start);
        errdefer payload.deinit(self.allocator);

        // Validate: braces must contain 2+ fields (no empty braces, no single-field braces)
        // Empty braces {} are meaningless - use void events or identity syntax instead
        // Single-field braces { x: T } should use identity syntax: | branch T
        // Exception: wildcards (is_wildcard flag set) are allowed via bare `*`
        // syntax (handled in the identity-path above) — `{ * }` is rejected.
        if (payload.fields.len == 0 and !payload.is_wildcard) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                @intCast(brace_idx.? + 1),
                "empty braces in branch payload - remove braces for void branch or use identity syntax '| {s} Type'",
                .{branch_name},
            );
            return error.ParseError;
        }
        // A single-field brace payload (`| ok { c: i32 }`) collapses to identity
        // (`| ok i32`) — but the RIGHT advice depends on branch count, which isn't
        // known here (per-branch parse). A SOLE such branch is a one-variant tag
        // union and should be a bare return `-> i32`, not identity; only with a
        // sibling branch is identity the target. So the check moved to post-parse
        // (the event-decl validation) where the count is known and can point the
        // user at the right form in one hop. Braced-single-field is distinguished
        // from identity there by the field name (identity carries __type_ref).

        // Find the closing brace position
        const close_brace_idx = blk: {
            var depth: i32 = 0;
            var idx: usize = brace_idx.?;
            while (idx < branch_start.len) : (idx += 1) {
                if (branch_start[idx] == '{') {
                    depth += 1;
                } else if (branch_start[idx] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        break :blk idx;
                    }
                }
            }
            break :blk null;
        };

        if (close_brace_idx) |close_idx| {
            // Single-line shape - check for annotations after }
            const after_brace = lexer.trim(branch_start[close_idx + 1 ..]);
            if (lexer.startsWith(after_brace, "[")) {
                // Find matching ] for the entire annotation block, respecting nested brackets
                const close_bracket_idx = blk: {
                    var depth: i32 = 0;
                    var i: usize = 0;
                    while (i < after_brace.len) : (i += 1) {
                        if (after_brace[i] == '[') {
                            depth += 1;
                        } else if (after_brace[i] == ']') {
                            depth -= 1;
                            if (depth == 0) {
                                break :blk i;
                            }
                        }
                    }
                    break :blk null;
                } orelse {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current - 1,
                        @intCast(close_idx + 1),
                        "branch annotation missing closing ']'",
                        .{},
                    );
                    return error.ParseError;
                };

                const annotation_content = lexer.trim(after_brace[1..close_bracket_idx]);
                // Split on | for multiple annotations
                var iter = std.mem.splitScalar(u8, annotation_content, '|');
                while (iter.next()) |ann| {
                    const trimmed_ann = lexer.trim(ann);
                    if (trimmed_ann.len > 0) {
                        try annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                    }
                }
            }
        }

        return ast.Branch{
            .name = try self.allocator.dupe(u8, branch_name),
            .payload = payload,
            .is_optional = is_optional,
            .is_panic = is_panic,
            .kind = branch_kind,
            .resume_type = resume_type,
            .resume_phantom = resume_phantom,
            .resume_arms = resume_arms,
            .annotations = try annotations.toOwnedSlice(self.allocator),
        };
    }

    /// Split fields on commas, but respect bracket boundaries
    /// e.g., "a: Type[x,y], b: Other" -> ["a: Type[x,y]", "b: Other"]
    /// Check if a string is a valid identifier (letters, numbers, underscores, no leading digit)
    /// A dotted path of valid identifiers (`entity.hp`). Projection-style
    /// destructures (std/store query blocks, ruling 6) carry these; the
    /// parser accepts the shape and consumers judge the semantics
    /// (maximalist-parser tenet — a dotted name that reaches a consumer
    /// with no path semantics is that consumer's diagnostic to raise).
    fn isValidDottedName(name: []const u8) bool {
        var it = std.mem.splitScalar(u8, name, '.');
        var segments: usize = 0;
        while (it.next()) |seg| {
            if (!isValidIdentifier(seg)) return false;
            segments += 1;
        }
        return segments >= 2;
    }

    fn isValidIdentifier(name: []const u8) bool {
        if (name.len == 0) return false;

        // First character must be letter or underscore
        const first = name[0];
        if (!std.ascii.isAlphabetic(first) and first != '_') return false;

        // Rest can be letters, numbers, underscores, or kebab `-` (a legal
        // name-char; mangles to `_` on emit). First char stays letter/`_`.
        for (name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }

        return true;
    }

    /// Split a call's argument list, reporting an unbalanced ')'/']' as a
    /// source-located parse error instead of letting it propagate as an opaque
    /// failure. `lexer.parseArgs` detects the imbalance (it owns the depth
    /// tracking); this is where we have `self.reporter` and `self.current` to
    /// point the diagnostic at the user's call site.
    fn parseArgsReported(self: *Parser, args_str: []const u8) ![]lexer.ArgPair {
        return lexer.parseArgs(self.allocator, args_str) catch |err| switch (err) {
            error.UnbalancedArgs => {
                try self.reporter.addError(
                    .PARSE004,
                    self.current,
                    1,
                    "unbalanced ')' or ']' in arguments — closing delimiter has no matching opener",
                    .{},
                );
                return error.ParseError;
            },
            else => return err,
        };
    }

    fn splitFieldsRespectingBrackets(self: *Parser, content: []const u8) !std.ArrayList([]const u8) {
        var result = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        errdefer result.deinit(self.allocator);

        var bracket_depth: i32 = 0;
        var paren_depth: i32 = 0;
        var field_start: usize = 0;
        var i: usize = 0;

        while (i < content.len) : (i += 1) {
            const ch = content[i];

            if (ch == '[') {
                bracket_depth += 1;
            } else if (ch == ']') {
                bracket_depth -= 1;
                // A closing ']' with no matching '[' drives the depth negative.
                // Left unchecked, the `bracket_depth == 0` gate below stops
                // recognizing top-level commas, silently collapsing the fields
                // and producing a misleading "single field in braces" error.
                // Reject the real cause loudly at the earliest layer.
                if (bracket_depth < 0) {
                    try self.reporter.addError(
                        .PARSE004,
                        self.current,
                        1,
                        "unbalanced ']' in payload shape — closing bracket has no matching '['",
                        .{},
                    );
                    return error.ParseError;
                }
            } else if (ch == '(') {
                paren_depth += 1;
            } else if (ch == ')') {
                paren_depth -= 1;
                if (paren_depth < 0) {
                    try self.reporter.addError(
                        .PARSE004,
                        self.current,
                        1,
                        "unbalanced ')' in payload shape — closing paren has no matching '('",
                        .{},
                    );
                    return error.ParseError;
                }
            } else if (ch == ',' and bracket_depth == 0 and paren_depth == 0) {
                // Found a field separator at top level (outside all brackets and parens)
                const field = lexer.trim(content[field_start..i]);
                if (field.len > 0) {
                    try result.append(self.allocator, field);
                }
                field_start = i + 1;
            }
        }

        // Don't forget the last field
        if (field_start < content.len) {
            const field = lexer.trim(content[field_start..]);
            if (field.len > 0) {
                try result.append(self.allocator, field);
            }
        }

        return result;
    }

    fn parseShape(self: *Parser, content: []const u8) !ast.Shape {
        var fields = try std.ArrayList(ast.Field).initCapacity(self.allocator, 8);
        errdefer {
            for (fields.items) |*field| {
                field.deinit(self.allocator);
            }
            fields.deinit(self.allocator);
        }

        if (content.len == 0) {
            // Empty shape - no bindable payload
            return ast.Shape{ .fields = try fields.toOwnedSlice(self.allocator) };
        }

        // Reject `{ * }` — the wildcard syntax is bare `*`, not braces around `*`.
        if (std.mem.eql(u8, lexer.trim(content), "*")) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "wildcard payload is bare '*' — write '| branch *' instead of '| branch {{ * }}'",
                .{},
            );
            return error.ParseError;
        }

        // Parse fields: name: type, name: type, ...
        // BUT respect brackets - don't split on commas inside []
        var field_strings = try self.splitFieldsRespectingBrackets(content);
        defer field_strings.deinit(self.allocator);

        for (field_strings.items) |field_str| {
            const trimmed_field = lexer.trim(field_str);
            if (trimmed_field.len == 0) continue;

            // Skip comment-only fields (from inline comments like "x: i32,  // comment")
            if (std.mem.startsWith(u8, trimmed_field, "//")) continue;

            const colon_idx = std.mem.indexOf(u8, trimmed_field, ":") orelse {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    1,
                    "field missing type annotation",
                    .{},
                );
                continue;
            };

            const field_name = lexer.trim(trimmed_field[0..colon_idx]);

            // Validate field name is a valid identifier (starts with letter/underscore)
            if (field_name.len > 0) {
                const first_char = field_name[0];
                if (first_char >= '0' and first_char <= '9') {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        1,
                        "field name cannot start with a digit",
                        .{},
                    );
                    continue;
                }
            }

            var field_type = lexer.trim(trimmed_field[colon_idx + 1 ..]);

            // Split the `= <expr>` DEFAULT off the type before anything reads
            // the type. Zig type syntax contains no top-level `=`, so the first
            // one outside brackets is unambiguously the separator; `==`/`!=`/
            // `<=`/`>=` inside a default value all sit after it.
            //
            // Leaving it attached is what shipped: `field.type` came out as
            // `"i32 = 5"`, which the emitter pasted verbatim into the generated
            // Zig `Input` struct — so Zig applied the default and the surface
            // looked implemented, while every Koru pass that reads `field.type`
            // was handed a string that is not a type (400_185, 400_186).
            var field_default: ?[]const u8 = null;
            {
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
                            const rhs = lexer.trim(field_type[k + 1 ..]);
                            if (rhs.len > 0) field_default = try self.allocator.dupe(u8, rhs);
                            field_type = lexer.trim(field_type[0..k]);
                            break;
                        },
                        else => {},
                    }
                }
            }

            // Check for special types: Source, File, EmbedFile, Expression, and InvocationMeta
            // Source can have scope type: Source<HTML>, Source<SQL>, etc.
            // Expression captures Zig expressions verbatim as strings
            // InvocationMeta provides call site metadata for comptime introspection
            var is_source = false;
            var is_file = false;
            var is_embed_file = false;
            var is_expression = false;
            var is_invocation_meta = false;
            if (std.mem.eql(u8, field_type, "Source") or std.mem.startsWith(u8, field_type, "Source<")) {
                is_source = true;
            } else if (std.mem.eql(u8, field_type, "Expression") or std.mem.startsWith(u8, field_type, "Expression<") or
                std.mem.eql(u8, field_type, "?Expression") or std.mem.startsWith(u8, field_type, "?Expression<"))
            {
                is_expression = true;
            } else if (std.mem.eql(u8, field_type, "File")) {
                is_file = true;
            } else if (std.mem.eql(u8, field_type, "EmbedFile")) {
                is_embed_file = true;
            } else if (std.mem.eql(u8, field_type, "InvocationMeta")) {
                is_invocation_meta = true;
            }

            // `expr: ?Expression` is LEGAL, and the corpus is why.
            //
            // It was ruled nonsensical on 2026-08-02 and a refusal was written
            // here, on the argument that `expr` is a syntactic role rather than
            // a parameter and that optionality on it is unreachable — there is
            // no syntax for "skip the positional but keep the later ones", so
            // the only call it could enable is the bare `f()`.
            //
            // The argument is wrong, and `std/kernel:pairwise` is the
            // counterexample: `expr` is its ONLY positional, so "omit it
            // entirely" is an ordinary call and not a gap to skip over. It
            // reads `expr != null` to tell `pairwise { … }` (iterate every
            // pair) from `pairwise(0..n) { … }` (an explicit outer range), and
            // both forms are green in 390. The refusal turned 18 kernel tests
            // red instantly, which is the corpus answering the design question.
            //
            // So `expr` is required-or-optional exactly like any other input.
            // The magic is only in WHICH argument fills it (the first
            // positional), never in whether it must be there. A REQUIRED `expr`
            // with no positional at the call site is KORU080's business, and
            // that is the wall that was actually missing (400_183/184/187).

            // Phantom labels: Type<tag>. Angle brackets have no Zig
            // type-position meaning, so any `<...>` at type end is
            // unambiguously phantom. Opaque capture — analyzers interpret.
            var phantom: ?[]const u8 = null;
            if (!is_source and !is_file and !is_embed_file and !is_expression) {
                if (field_type.len > 0 and field_type[field_type.len - 1] == '>') {
                    var angle_depth: i32 = 0;
                    var i = field_type.len - 1;
                    const end_pos = i;
                    var start_pos: ?usize = null;
                    while (i > 0) : (i -= 1) {
                        if (field_type[i] == '>') {
                            angle_depth += 1;
                        } else if (field_type[i] == '<') {
                            angle_depth -= 1;
                            if (angle_depth == 0) {
                                start_pos = i;
                                break;
                            }
                        }
                    }
                    if (start_pos) |start| {
                        if (start > 0) {
                            const angle_content = field_type[start + 1 .. end_pos];
                            if (angle_content.len > 0) {
                                phantom = try self.allocator.dupe(u8, angle_content);
                                field_type = field_type[0..start];
                            }
                        }
                    }
                }

                // Reject the square-bracket phantom form `Type[state]` (must be `Type<state>`).
                try self.rejectSquareBracketPhantom(field_type);
            }

            // Canonical text type, checked on the phantom-stripped BASE so
            // `[]const u8` and `[]const u8<!tag>` are both caught: the raw Zig
            // slice is not a Koru surface spelling in a payload position. Steer
            // to `string`. `string` itself is KEPT in the AST as the surface
            // type — it survives the whole pipeline (printer/round-trip stay
            // faithful) and is lowered to []const u8 only at the Zig emission
            // boundary. Holds in .k AND .kz.
            if (std.mem.eql(u8, field_type, "[]const u8")) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    1,
                    "'[]const u8' is not a Koru tor-payload type. Use 'string' for text — it lowers to []const u8 for Zig",
                    .{},
                );
                return error.ParseError;
            }

            // Check for cross-module type reference: module.path:TypeName
            // Handle type prefixes like ?*, *, [], []const that come before the module path
            var module_path: ?[]const u8 = null;
            var type_prefix: []const u8 = "";

            // Strip type prefix before looking for module colon
            // Order matters - check longer prefixes first
            const prefixes = [_][]const u8{ "[]const ", "?*const ", "*const ", "[]", "?*", "?", "*" };
            for (prefixes) |prefix| {
                if (std.mem.startsWith(u8, field_type, prefix)) {
                    type_prefix = prefix;
                    field_type = field_type[prefix.len..];
                    break;
                }
            }

            // Count colons - should be 0 (local type) or 1 (cross-module type)
            const colon_count = std.mem.count(u8, field_type, ":");
            if (colon_count > 1) {
                // Multiple colons are ambiguous - which is the module boundary?
                try self.reporter.addError(.PARSE003, self.current + 1, 1, "Multiple colons in type reference '{s}' - expected format 'module.path:Type' or just 'Type'", .{field_type});
                return error.ParseError;
            }

            // Parse cross-module type reference and build owned type string
            const owned_type: []const u8 = blk: {
                if (std.mem.indexOfScalar(u8, field_type, ':')) |module_colon_idx| {
                    try self.rejectDottedModuleQualifier(field_type[0..module_colon_idx], field_type[module_colon_idx + 1 ..]);
                    module_path = try self.allocator.dupe(u8, field_type[0..module_colon_idx]);
                    const base_type = field_type[module_colon_idx + 1 ..];
                    if (type_prefix.len > 0) {
                        break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ type_prefix, base_type });
                    } else {
                        break :blk try self.allocator.dupe(u8, base_type);
                    }
                }
                if (type_prefix.len > 0) {
                    break :blk try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ type_prefix, field_type });
                }
                break :blk try self.allocator.dupe(u8, field_type);
            };

            const field = ast.Field{
                .name = try self.allocator.dupe(u8, field_name),
                .type = owned_type,
                .module_path = module_path,
                .phantom = phantom,
                .is_source = is_source,
                .is_file = is_file,
                .is_embed_file = is_embed_file,
                .is_expression = is_expression,
                .is_invocation_meta = is_invocation_meta,
                .default = field_default,
            };

            try fields.append(self.allocator, field);
        }

        return ast.Shape{ .fields = try fields.toOwnedSlice(self.allocator) };
    }

    // isValidBranchConstructorValue removed — replaced by expression parser
    // structural validation (containsFunctionCall check) at the call site.

    fn parseLabelAnchor(self: *Parser) !ast.Item {
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);
        const after_hash = lexer.trim(trimmed[2..]); // Skip ~#

        // Check if this is a standalone label (~#name) or pre-invocation (~#name event)
        const space_idx = std.mem.indexOf(u8, after_hash, " ");

        if (space_idx) |idx| {
            // Pre-invocation label: ~#name event(args)
            const label_name = after_hash[0..idx];
            const event_part = lexer.trim(after_hash[idx + 1 ..]);

            // Parse the event invocation
            const invocation = try self.parseEventInvocation(event_part);

            // Move to next line and parse continuations
            self.current += 1;
            const continuations = try self.parseContinuations(lexer.getIndent(line));

            return .{ .flow = ast.Flow{
                .body = ast.rootSite(invocation, continuations, self.getCurrentLocation()),
                .pre_label = try self.allocator.dupe(u8, label_name),
                .super_shape = null,
                .location = self.getCurrentLocation(),
                .module = try self.allocator.dupe(u8, self.module_name),
            } };
        } else {
            // Standalone label: ~#name
            self.current += 1;
            const continuations = try self.parseContinuations(lexer.getIndent(line));

            return .{ .label_decl = ast.LabelDecl{
                .name = try self.allocator.dupe(u8, after_hash),
                .continuations = continuations,
            } };
        }
    }

    fn parseLabelDecl(self: *Parser) !ast.LabelDecl {
        const line = self.lines[self.current];
        self.current += 1;

        // Parse: ~@name
        const after_at = lexer.afterPrefix(line, "~@") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "malformed label declaration",
                .{},
            );
            return error.ParseError;
        };

        const name = lexer.trim(after_at);
        const continuations = try self.parseContinuations(lexer.getIndent(line));

        return ast.LabelDecl{
            .name = try self.allocator.dupe(u8, name),
            .continuations = continuations,
        };
    }

    fn parseImportDecl(self: *Parser) !ast.ImportDecl {
        const line = self.lines[self.current];
        self.current += 1;

        // Reached via `~import ...` in host-embedded files, or after `.k` synthesizes
        // the leading `~` on bare `import ...`.
        const t = lexer.trim(line);
        const after_tilde = if (lexer.startsWith(t, "~")) lexer.trim(t[1..]) else t;

        // Skip the "import " part
        const after_import = if (lexer.startsWith(after_tilde, "import "))
            lexer.trim(after_tilde[7..])
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "invalid import syntax",
                .{},
            );
            return error.ParseError;
        };

        // Bare `import` in `.kz` is rejected at the line level in parse() before
        // we get here. A `~` prefix reaching here is normal (~import, ~[flag]import,
        // or `.k` internal synthesis).

        // Extract the path — bare identifier-path only. Quotes are the old form.
        // Strip a trailing `//` end-of-line comment first: an import path uses
        // single-slash separators and never contains `//`, so the first `//`
        // marks a comment (e.g. `~import std/io  // note`).
        var path: []const u8 = undefined;
        const path_str = if (std.mem.indexOf(u8, after_import, "//")) |ci|
            lexer.trim(after_import[0..ci])
        else
            after_import;
        if (lexer.startsWith(path_str, "\"") or lexer.startsWith(path_str, "'")) {
            // An import path is an identifier-path, not a string.
            const stripped = std.mem.trim(u8, path_str, "\"'");
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "imports take a bare path, not a string: write `~import {s}` (no quotes)",
                .{stripped},
            );
            return error.ParseError;
        } else {
            // Unquoted path (for simplicity)
            path = path_str;
        }

        // Validate import path
        // 1. Forbid ../ for security and simplicity (only allowed in koru.json)
        // 1. Forbid ../ for security and simplicity
        if (std.mem.indexOf(u8, path, "../") != null) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "import paths cannot contain '../' - declare an alias for the directory instead: {s}std/compiler:paths {{ name: ../path }}",
                .{self.tilde()},
            );
            return error.ParseError;
        }

        // Extract the alias (first segment)
        const slash_pos = std.mem.indexOf(u8, path, "/");
        const alias_end = slash_pos orelse path.len;
        const alias = path[0..alias_end];

        // 2. Require path to start with a valid alias name (valid identifier)
        const is_valid_alias = blk: {
            if (alias.len == 0) break :blk false;
            const first = alias[0];
            if (!std.ascii.isAlphabetic(first) and first != '_') break :blk false;
            for (alias[1..]) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk false;
            }
            break :blk true;
        };

        if (!is_valid_alias) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "import paths must start with an alias (e.g., 'std/io', 'src/helper') - declare one with {s}std/compiler:paths {{ name: ./path }}",
                .{self.tilde()},
            );
            return error.ParseError;
        }

        // 3. Enforce maximum import depth: alias/a/b (2 segments max)
        if (slash_pos) |first_slash| {
            const path_after_alias = path[first_slash + 1 ..];
            var segment_count: usize = 1; // Count the first segment
            var i: usize = 0;
            while (i < path_after_alias.len) : (i += 1) {
                if (path_after_alias[i] == '/') {
                    segment_count += 1;
                }
            }

            if (segment_count > 2) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "import path too deep: '{s}' has {d} segments after alias (max: 2)\n" ++
                        "  To fix: declare a new alias in the entry file, e.g.:\n" ++
                        "    {s}std/compiler:paths {{ mylib: ./path/to/lib }}\n" ++
                        "  Then use: {s}import mylib/... (Suggested: extract '{s}' as its own alias)",
                    .{ path, segment_count, self.tilde(), self.tilde(), alias },
                );
                return error.ParseError;
            }
        }

        // Derive namespace from import path
        // For alias/path imports: convert / to . (e.g., "std/build" -> "std.build")
        const final_name = blk: {
            var namespace = try std.ArrayList(u8).initCapacity(self.allocator, path.len);
            defer namespace.deinit(self.allocator);

            for (path) |c| {
                if (c == '/') {
                    try namespace.append(self.allocator, '.');
                } else {
                    try namespace.append(self.allocator, c);
                }
            }

            // Strip Koru extension if present
            var result = try namespace.toOwnedSlice(self.allocator);
            if (file_types.koruExtensionOf(result)) |ext| {
                const trimmed = result[0 .. result.len - ext.len];
                const final = try self.allocator.dupe(u8, trimmed);
                self.allocator.free(result);
                break :blk final;
            }
            break :blk result;
        };

        // Parse the imported file to populate registry with public events
        // We use final_name which is the full dotted namespace (e.g., "std.compiler")
        try self.parseAndRegisterImport(path, final_name);

        return ast.ImportDecl{
            .path = try self.allocator.dupe(u8, path),
            .local_name = final_name,
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }

    fn parseAndRegisterImport(self: *Parser, import_path: []const u8, namespace: []const u8) anyerror!void {
        // If no resolver is available (help text parsing), skip import resolution
        const resolver = self.resolver orelse {
            log_debug("Parser: No resolver available, skipping import resolution for: {s}\n", .{import_path});
            return;
        };

        // NOTE: Auto-import of parent modules (e.g., importing $std/io.kz when importing $std/io/file)
        // is handled in main.zig's queueParentImports() during import resolution phase.

        // Use ModuleResolver to resolve the import path
        var result = resolver.resolveBoth(import_path, self.reporter.file_name) catch |err| {
            if (err == error.ModuleNotFound) {
                try errors.moduleNotFound(&self.reporter, self.current, 1, import_path);
            } else if (err == error.UnknownImportAlias) {
                const slash_pos = std.mem.indexOf(u8, import_path, "/");
                const alias_end = slash_pos orelse import_path.len;
                const alias = import_path[0..alias_end];
                try self.reporter.addErrorWithHint(
                    .PARSE003,
                    self.current,
                    1,
                    "unknown import alias: '{s}'",
                    .{alias},
                    "declare the alias in the entry file, e.g. {s}std/compiler:paths {{ {s}: ./path }}",
                    .{ self.tilde(), alias },
                );
            }
            return err;
        };
        defer result.deinit(resolver.allocator); // CRITICAL: Use resolver's allocator, not parser's!

        // Process directory imports (if directory was found)
        if (result.dir_path) |dir_path| {
            // Enumerate all .kz files in the directory
            const files = try resolver.enumerateDirectory(dir_path);
            defer {
                // CRITICAL: Use resolver's allocator (GPA), not parser's allocator (arena)!
                for (files) |file| resolver.allocator.free(file);
                resolver.allocator.free(files);
            }

            for (files) |file_path| {
                // Extract filename without Koru extension for namespace
                const basename = std.fs.path.basename(file_path);
                const file_name = if (file_types.koruExtensionOf(basename)) |ext|
                    basename[0 .. basename.len - ext.len]
                else
                    basename;

                // Combined namespace: namespace.filename
                var combined_namespace_buf: [256]u8 = undefined;
                const combined_namespace = try std.fmt.bufPrint(&combined_namespace_buf, "{s}.{s}", .{ namespace, file_name });

                // Parse and register this file
                try self.parseAndRegisterSingleFile(file_path, combined_namespace);
            }
        }

        // Process file import (if file was found)
        if (result.file_path) |file_path| {
            try self.parseAndRegisterSingleFile(file_path, namespace);

            // Phase 2.1: also parse companion files sharing the stem
            // (e.g. `contract.k` alongside `contract.kz`). The resolver
            // returns only the first-hit; the contract file gets dropped
            // unless we look for its siblings explicitly.
            const companions = try module_resolver_mod.findCompanionFiles(resolver.allocator, file_path);
            defer {
                for (companions) |c| resolver.allocator.free(c);
                resolver.allocator.free(companions);
            }
            for (companions) |companion_path| {
                try self.parseAndRegisterSingleFile(companion_path, namespace);
            }
        }
    }

    fn parseAndRegisterSingleFile(self: *Parser, file_path: []const u8, namespace: []const u8) anyerror!void {
        const resolver = self.resolver orelse return;

        // Check for circular import - if this file is already being parsed, skip it
        // The events will be registered when the original parse completes
        if (resolver.isBeingParsed(file_path)) {
            log_debug("CIRCULAR IMPORT: Skipping '{s}' (already being parsed)\n", .{file_path});
            return;
        }

        // Mark this file as being parsed
        try resolver.markParsing(file_path);
        defer resolver.unmarkParsing(file_path);

        // Read the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            try self.reporter.addError(.PARSE003, self.current, 1, "failed to open import file '{s}': {s}", .{ file_path, @errorName(err) });
            return error.ParseError;
        };
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            try self.reporter.addError(.PARSE003, self.current, 1, "failed to read import file '{s}': {s}", .{ file_path, @errorName(err) });
            return error.ParseError;
        };
        defer self.allocator.free(source);

        // Parse the imported file
        var import_parser = try Parser.init(self.allocator, source, file_path, &[_][]const u8{}, self.resolver);
        defer import_parser.deinit();

        // Parse import - propagate errors with context
        // NOTE: We intentionally don't call import_result.deinit() because we're storing
        // pointers to its EventTypes in our registry. Those need to stay alive.
        var import_result = import_parser.parse() catch |err| {
            // Surface the inner parser's errors before propagating
            if (import_parser.reporter.hasErrors()) {
                // The canonical sink. This site used to hand-roll one with
                // `bufPrint(...) catch return`, which truncated an imported
                // file's diagnostic mid-sentence and said nothing about it.
                import_parser.reporter.printErrors(errors.FileSink.stderr()) catch {};
            }
            return err;
        };

        // Register all public events from the imported file with namespace prefix
        var event_iter = import_result.registry.events.iterator();
        while (event_iter.next()) |entry| {
            const event_path = entry.key_ptr.*;
            const event_type = entry.value_ptr.*;

            // Only register public events
            if (event_type.is_public) {
                // Register with FULL namespace (e.g., "std.compiler:requires")
                const namespaced_path = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ namespace, event_path });
                try self.registry.events.put(namespaced_path, event_type);
            }
        }
    }
};

test "flagRefs finds every {{ flag:name }} in a declared path" {
    const MR = module_resolver_mod.ModuleResolver;
    var buf: [8][]const u8 = undefined;

    const none = MR.flagRefs("./lib/helpers", &buf);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const one = MR.flagRefs("{{ flag:target }}/toolkit", &buf);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("target", one[0]);

    // Two distinct references in one path: the reason this loops rather than
    // substituting a single known string once, the way ENTRY and KORU_HOME do.
    const two = MR.flagRefs("{{ flag:root }}/x/{{ flag:arch }}", &buf);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("root", two[0]);
    try std.testing.expectEqualStrings("arch", two[1]);

    // An unterminated reference is not a reference. It stays in the path and
    // fails resolution loudly rather than being read as a flag named `target`.
    const unterminated = MR.flagRefs("{{ flag:target/toolkit", &buf);
    try std.testing.expectEqual(@as(usize, 0), unterminated.len);
}

test "flagValueIn reads only flags that carry a value" {
    const MR = module_resolver_mod.ModuleResolver;
    const flags = [_][]const u8{ "ccp", "target=wasm32", "auto-discharge=disable" };

    try std.testing.expectEqualStrings("wasm32", MR.flagValueIn(&flags, "target").?);
    try std.testing.expectEqualStrings("disable", MR.flagValueIn(&flags, "auto-discharge").?);

    // A bare flag carries nothing to substitute, so it cannot fill a segment —
    // it must read as absent, not as an empty path.
    try std.testing.expect(MR.flagValueIn(&flags, "ccp") == null);
    try std.testing.expect(MR.flagValueIn(&flags, "never-supplied") == null);
}

// Parser tests - Verifying that parser produces clean AST without validation

test "parser produces AST from simple event" {
    const allocator = std.testing.allocator;

    // Single unnamed output is the bare-return form `-> i32`; a lone
    // payload-carrying branch (`| done i32`) is the retired single-variant
    // spelling PARSE003 now rejects. branches[] is empty; the output lives on
    // return_type.
    const source =
        \\~tor compute { x: i32 } -> i32
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // Verify we got an AST
    try std.testing.expect(parse_result.source_file.items.len == 1);

    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .event_decl);

    const event = item.event_decl;
    try std.testing.expectEqualStrings(event.path.segments[0], "compute");
    try std.testing.expect(event.input.fields.len == 1);
    try std.testing.expectEqualStrings(event.input.fields[0].name, "x");
    try std.testing.expect(event.branches.len == 0);
    try std.testing.expectEqualStrings(event.return_type.?, "i32");
}

test "parser handles flow with continuation" {
    const allocator = std.testing.allocator;

    const source =
        \\~hello()
        \\| greeting g -> ~print(g.message)
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(parse_result.source_file.items.len == 1);

    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .flow);

    const flow = item.flow;
    try std.testing.expectEqualStrings(flow.inv().path.segments[0], "hello");
    try std.testing.expect(flow.body.continuations.len == 1);

    const cont = flow.body.continuations[0];
    try std.testing.expectEqualStrings(cont.branch, "greeting");
    try std.testing.expect(cont.binding != null);
    try std.testing.expectEqualStrings(cont.binding.?, "g");
}

test "parser handles proc declaration" {
    const allocator = std.testing.allocator;

    const source =
        \\~proc compute {
        \\    return .done{ .result = x + y };
        \\}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(parse_result.source_file.items.len == 1);

    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .proc_decl);

    const proc = item.proc_decl;
    try std.testing.expectEqualStrings(proc.path.segments[0], "compute");
    // ProcDecl only stores the body as opaque Zig code
    try std.testing.expect(proc.body.text.len > 0);
}

test "parser handles complex nested proc body extraction" {
    const allocator = std.testing.allocator;

    // Test with complex nested braces, including strings with braces
    const source =
        \\~[raw]proc complex.test {
        \\    const str1 = "test { brace }";
        \\    if (condition) {
        \\        for (items) |item| {
        \\            switch (item) {
        \\                .foo => {
        \\                    const nested = "another { nested } brace";
        \\                    if (true) {
        \\                        doSomething();
        \\                    }
        \\                },
        \\                else => {},
        \\            }
        \\        }
        \\    }
        \\    return result;
        \\}
        \\~something.after.proc()
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // Should have 2 items: the proc and the flow after
    try std.testing.expect(parse_result.source_file.items.len == 2);

    const proc_item = parse_result.source_file.items[0];
    try std.testing.expect(proc_item == .proc_decl);

    const proc = proc_item.proc_decl;
    try std.testing.expectEqualStrings(proc.path.segments[0], "complex");
    try std.testing.expectEqualStrings(proc.path.segments[1], "test");

    // The body should contain all the nested code
    try std.testing.expect(std.mem.indexOf(u8, proc.body.text, "const str1") != null);
    try std.testing.expect(std.mem.indexOf(u8, proc.body.text, "return result") != null);

    // Make sure the flow after the proc was parsed
    const flow_item = parse_result.source_file.items[1];
    try std.testing.expect(flow_item == .flow);
    try std.testing.expectEqualStrings(flow_item.flow.inv().path.segments[0], "something");
}

test "parser handles import statement" {
    const allocator = std.testing.allocator;

    const source =
        \\~import std/array
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(parse_result.source_file.items.len == 1);

    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .import_decl);

    const import = item.import_decl;
    try std.testing.expectEqualStrings(import.path, "std/array");
    try std.testing.expectEqualStrings(import.local_name.?, "std.array");
}

test "parser handles empty file" {
    const allocator = std.testing.allocator;

    const source = "";

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(parse_result.source_file.items.len == 0);
}

test "parser handles Source in event field" {
    const allocator = std.testing.allocator;

    const source =
        \\~tor macro { code: Source } -> Source
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    const event = parse_result.source_file.items[0].event_decl;
    try std.testing.expect(event.input.fields[0].is_source);
    try std.testing.expectEqualStrings(event.input.fields[0].name, "code");
}

test "parser validates branch names" {
    const allocator = std.testing.allocator;

    // Valid branch name
    {
        const source =
            \\~tor test {}
            \\| valid-branch i32
            \\| another-one string
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        defer parser.deinit();

        var parse_result = try parser.parse();
        defer parse_result.deinit();

        try std.testing.expect(parse_result.source_file.items.len == 1);
        try std.testing.expect(parse_result.source_file.items[0] == .event_decl);
        const event = parse_result.source_file.items[0].event_decl;
        try std.testing.expect(event.branches.len == 2);
        // Names are kebab-canonical BYTES through the pipeline — no lowering at parse.
        try std.testing.expectEqualStrings(event.branches[0].name, "valid-branch");
        try std.testing.expectEqualStrings(event.branches[1].name, "another-one");
    }

    // Invalid branch name starting with number
    {
        const source =
            \\~tor test {}
            \\| 123invalid i32
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        parser.fail_fast = true;
        defer parser.deinit();

        const result = parser.parse();

        // Should fail due to invalid branch name
        try std.testing.expectError(error.ParseError, result);
        try std.testing.expect(parser.reporter.hasErrors());
    }
}

test "parser validates branch constructors" {
    const allocator = std.testing.allocator;

    // Valid branch constructor
    {
        const source =
            \\~tor test {}
            \\| ok string
            \\
            \\~test()
            \\| ok => ok { msg: "success" }
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        defer parser.deinit();

        var parse_result = try parser.parse();
        defer parse_result.deinit();

        try std.testing.expect(parse_result.source_file.items.len == 2);
    }

    // Invalid branch constructor with spaces in name
    {
        const source =
            \\~tor test {}
            \\| ok string
            \\
            \\~test()
            \\| ok => invalid name { msg: "fail" }
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        parser.fail_fast = true;
        defer parser.deinit();

        const result = parser.parse();

        // Should fail due to invalid branch name in constructor
        try std.testing.expectError(error.ParseError, result);
    }
}

test "parser handles shorthand notation in branch constructors" {
    const allocator = std.testing.allocator;

    const source =
        \\~tor test {}
        \\| ok { id: i32, value: i32 }
        \\
        \\~test => ok { r.user.id, 0 }
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(parse_result.source_file.items.len == 2);
    const ii = parse_result.source_file.items[1].immediate_impl;
    const bc = ii.value;
    try std.testing.expectEqualStrings(bc.branch_name, "ok");
    try std.testing.expect(bc.fields.len == 2);
    // In shorthand, r.user.id becomes field name "id" with value "r.user.id"
    try std.testing.expectEqualStrings(bc.fields[0].name, "id");
    try std.testing.expect(bc.fields[0].expression_str != null);
    try std.testing.expectEqualStrings(bc.fields[0].expression_str.?, "r.user.id");
    try std.testing.expectEqualStrings(bc.fields[1].name, "0");
    try std.testing.expect(bc.fields[1].expression_str != null);
    try std.testing.expectEqualStrings(bc.fields[1].expression_str.?, "0");
}

test "parser rejects old tap syntax" {
    const allocator = std.testing.allocator;

    // Old tap syntax should be rejected with helpful error message
    // Users should use ~tap(source -> dest) instead

    // Test: ~source -> dest (old output tap syntax)
    {
        const source =
            \\~file.read -> * | error e |> log.error(e)
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        parser.fail_fast = true;
        defer parser.deinit();

        // Should fail with ParseError
        const result = parser.parse();
        try std.testing.expectError(error.ParseError, result);
    }

    // Test: ~* -> dest (old wildcard source syntax)
    {
        const source =
            \\~* -> db.query | sql s |> log.sql(s)
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        parser.fail_fast = true;
        defer parser.deinit();

        const result = parser.parse();
        try std.testing.expectError(error.ParseError, result);
    }

    // Test: ~* -> * (old universal tap syntax)
    {
        const source =
            \\~* -> * |> transition t |> profiler.record(t)
        ;

        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
        parser.fail_fast = true;
        defer parser.deinit();

        const result = parser.parse();
        try std.testing.expectError(error.ParseError, result);
    }
}

test "parser handles when clause with space" {
    const allocator = std.testing.allocator;

    const source =
        \\~poll()
        \\| key k when k.code == 'q' |> quit()
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(parse_result.source_file.items.len == 1);

    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .flow);

    const flow = item.flow;
    try std.testing.expect(flow.body.continuations.len == 1);

    const cont = flow.body.continuations[0];
    try std.testing.expectEqualStrings("key", cont.branch);
    try std.testing.expect(cont.binding != null);
    try std.testing.expectEqualStrings("k", cont.binding.?);

    // THIS IS THE KEY CHECK: condition should be populated
    try std.testing.expect(cont.condition != null);
    try std.testing.expectEqualStrings("k.code == 'q'", cont.condition.?);
}

test "parser handles when clause with parens for grouping" {
    const allocator = std.testing.allocator;

    const source =
        \\~poll()
        \\| key k when k.code == ('q') |> quit()
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    const flow = parse_result.source_file.items[0].flow;
    const cont = flow.body.continuations[0];

    try std.testing.expect(cont.condition != null);
    try std.testing.expectEqualStrings("k.code == ('q')", cont.condition.?);
}

test "parser handles sibling continuations with when guards" {
    const allocator = std.testing.allocator;

    // This is the pattern that caused "2 else cases ambiguous" error
    const source =
        \\~poll()
        \\| key k when k.code == 'q' |> quit()
        \\| key k |> handle_key(k)
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    const flow = parse_result.source_file.items[0].flow;

    // Should have 2 continuations
    try std.testing.expect(flow.body.continuations.len == 2);

    // First continuation: with when guard
    const cont1 = flow.body.continuations[0];
    try std.testing.expectEqualStrings("key", cont1.branch);
    try std.testing.expectEqualStrings("k", cont1.binding.?);
    try std.testing.expect(cont1.condition != null); // HAS when guard
    try std.testing.expectEqualStrings("k.code == 'q'", cont1.condition.?);

    // Second continuation: else case (no when guard)
    const cont2 = flow.body.continuations[1];
    try std.testing.expectEqualStrings("key", cont2.branch);
    try std.testing.expectEqualStrings("k", cont2.binding.?);
    try std.testing.expect(cont2.condition == null); // NO when guard - this is the else case
}

test "parser handles NESTED continuations with when guards" {
    const allocator = std.testing.allocator;

    // This is the pattern from hello.kz that becomes parse_error
    const source =
        \\~run()
        \\| ready t |> poll()
        \\    | key k when k.code == 'q' |> cleanup()
        \\        | done |> _
        \\    | key k |> handle_key(k)
        \\        | done |> _
        \\| err _ |> _
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    // This test CURRENTLY FAILS - the flow is being parsed as a parse_error
    // When fixed, this should become a flow with nested continuations
    try std.testing.expect(parse_result.source_file.items.len == 1);
    try std.testing.expect(parse_result.source_file.items[0] == .flow);

    const flow = parse_result.source_file.items[0].flow;

    // Top level has 2 continuations: ready and err
    try std.testing.expect(flow.body.continuations.len == 2);

    // First top-level continuation: ready t |> poll()
    const ready_cont = flow.body.continuations[0];
    try std.testing.expectEqualStrings("ready", ready_cont.branch);
    try std.testing.expectEqualStrings("t", ready_cont.binding.?);

    // ready should have nested continuations (key with when, key without when)
    // The node should be poll(), and poll's continuations should have when guards
}

test "parser rejects single empty branch as redundant" {
    const allocator = std.testing.allocator;

    const source =
        \\~tor done {}
        \\| done
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    parser.fail_fast = true;
    defer parser.deinit();

    const result = parser.parse();
    try std.testing.expectError(error.ParseError, result);

    // Verify the specific error message
    try std.testing.expect(parser.reporter.hasErrors());
    const first_error = parser.reporter.errors.items[0];
    try std.testing.expectEqual(errors.ErrorCode.PARSE003, first_error.code);
    try std.testing.expect(std.mem.indexOf(u8, first_error.message, "single branch 'done'") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_error.message, "void tor") != null);
}

test "parser allows void event with zero branches" {
    const allocator = std.testing.allocator;

    const source =
        \\~tor done {}
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(!parser.reporter.hasErrors());
    try std.testing.expect(parse_result.source_file.items.len == 1);
    try std.testing.expect(parse_result.source_file.items[0] == .event_decl);
    const event = parse_result.source_file.items[0].event_decl;
    try std.testing.expect(event.branches.len == 0);
}

test "parser rejects single identity branch — collapse to bare return" {
    const allocator = std.testing.allocator;

    // An identity branch carrying a single type payload (`| ok i32`) is a
    // one-variant tag union — no different from a compound single branch
    // (`| ok { .. }`). Both collapse to the bare-return form `-> i32`; the
    // parser enforces it identically (Lars-ruled 2026-07-15: identity single
    // payloads are handled the same as any other single continuation branch).
    const source =
        \\~tor result {}
        \\| ok i32
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    parser.fail_fast = true;
    defer parser.deinit();

    const result = parser.parse();
    try std.testing.expectError(error.ParseError, result);

    try std.testing.expect(parser.reporter.hasErrors());
    const first_error = parser.reporter.errors.items[0];
    try std.testing.expectEqual(errors.ErrorCode.PARSE003, first_error.code);
    try std.testing.expect(std.mem.indexOf(u8, first_error.message, "one-variant tag union") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_error.message, "bare return") != null);
}

test "parser allows two empty branches" {
    const allocator = std.testing.allocator;

    const source =
        \\~tor result {}
        \\| ok
        \\| err
    ;

    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer parser.deinit();

    var parse_result = try parser.parse();
    defer parse_result.deinit();

    try std.testing.expect(!parser.reporter.hasErrors());
    try std.testing.expect(parse_result.source_file.items.len == 1);
    try std.testing.expect(parse_result.source_file.items[0] == .event_decl);
    const event = parse_result.source_file.items[0].event_decl;
    try std.testing.expect(event.branches.len == 2);
}
