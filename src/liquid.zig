// Minimal Liquid Template Engine for Koru
// ========================================
//
// A simple, runtime Liquid-like template engine for code generation.
// Designed to be extended for Oya (full Liquid with filters, etc.)
//
// Supported syntax:
//   {{ variable }}                    - Output value
//   {% if key %}...{% endif %}        - Conditional block
//   {% unless key %}...{% endunless %} - Inverted conditional
//   {% for item in array %}...{% endfor %} - Iteration
//
// Usage:
//   var ctx = Context.init(allocator);
//   try ctx.put("name", .{ .string = "Player" });
//   try ctx.put("is_pub", .{ .boolean = true });
//   const result = try render(allocator, template, &ctx);

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Value type for template context.
///
/// `record` is a walkable tree node: a `Context` whose entries are the node's
/// named fields (`op`, `value`, `kind`, …), with sub-nodes stored as further
/// `record` values and ordered children stored under an `array` entry. This is
/// the template-facing projection of the `WalkNode` spine (see
/// docs/PARSER_PALETTE.md): one generic shape every parser produces, walked by
/// `{% case node.kind %}` / `{{ node.field }}` / `{% render … %}`.
pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    array: []const *Context,
    record: *const Context,

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .boolean => |b| b,
            .array => |a| a.len > 0,
            .record => true,
        };
    }
};

/// Template context - maps variable names to values.
///
/// `{% for h in ... %}` binds each item context under a name (`scope_name`)
/// with a `parent` fallback, so the loop body can reference item fields as
/// `{{ h.link }}` while outer vars (`{{ n }}`) still resolve through the parent.
pub const Context = struct {
    allocator: Allocator,
    data: std.StringHashMap(Value),
    /// Outer scope to fall back to when a key isn't found locally (loop bodies).
    parent: ?*const Context = null,
    /// Loop-item binding name (e.g. "h"); `scope_name.field` resolves into `scope`.
    scope_name: ?[]const u8 = null,
    /// The item context bound to `scope_name`.
    scope: ?*const Context = null,

    pub fn init(allocator: Allocator) Context {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.data.deinit();
    }

    pub fn put(self: *Context, key: []const u8, value: Value) !void {
        try self.data.put(key, value);
    }

    pub fn get(self: *const Context, key: []const u8) ?Value {
        // Exact full-key match FIRST. Callers (template_processor) store literal
        // dotted keys like `continuations["done"].continue` whole and rely on
        // exact-match — so this must win before any `.`-splitting, or those keys
        // would resolve to the wrong head segment.
        if (self.data.get(key)) |v| return v;

        // Dotted access: split `head.tail` and walk one step.
        if (std.mem.indexOfScalar(u8, key, '.')) |dot| {
            const head = key[0..dot];
            const tail = key[dot + 1 ..];

            // `<scope_name>.field` → resolve `field` (itself possibly dotted) in scope.
            if (self.scope_name) |sn| {
                if (std.mem.eql(u8, head, sn)) {
                    if (self.scope) |sc| return sc.get(tail);
                }
            }
            // `<record_var>.field` → recurse into the record node. This is what
            // lets a walker descend named child fields: `node.left.op`, etc.
            if (self.data.get(head)) |hv| {
                if (hv == .record) return hv.record.get(tail);
            }
        }

        // Bare access into the bound loop scope (back-compat: `{% for c in xs %}`
        // bodies may reference item fields unprefixed as `{{ name }}`).
        if (self.scope) |sc| {
            if (sc.get(key)) |v| return v;
        }
        if (self.parent) |p| return p.get(key);
        return null;
    }
};

/// A registry of named sub-templates, keyed by name, that `{% render "name" %}`
/// resolves against. This is what makes recursive tree walks expressible: a
/// walker template descends by rendering itself (or a sibling) on a child node.
pub const TemplateRegistry = std.StringHashMap([]const u8);

/// A callable parser/transform invoked from `{% const x = name(args) %}`. Takes
/// the resolved argument values and returns a `Value` — typically a `.record`
/// tree node (e.g. `parse_json`, `parse_expr`). The smartness lives here, in
/// Zig; the template only orchestrates the walk (docs/PARSER_PALETTE.md §2).
pub const Filter = *const fn (allocator: Allocator, args: []const Value) anyerror!Value;

/// A registry of callable filters, keyed by name.
pub const FilterRegistry = std.StringHashMap(Filter);

/// Render-time environment: the registries a template can call out to. Bundled
/// so the render signatures stay stable as we add capabilities.
pub const RenderEnv = struct {
    templates: ?*const TemplateRegistry = null,
    filters: ?*const FilterRegistry = null,
};

/// Render a template with the given context.
pub fn render(allocator: Allocator, template: []const u8, ctx: *const Context) ![]u8 {
    return renderCollectDiag(allocator, template, ctx, null);
}

/// Like `renderCollectDiag`, but with a `RenderEnv` (named sub-templates +
/// callable filters) so `{% render %}` can recurse and `{% const x = f(a) %}`
/// can call parsers. The tree-walker path.
pub fn renderWithEnv(
    allocator: Allocator,
    template: []const u8,
    ctx: *const Context,
    diag_out: ?*?[]const u8,
    env: RenderEnv,
) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, template.len);
    errdefer output.deinit(allocator);
    try renderTo(template, ctx, output.writer(allocator), diag_out, env);
    return try output.toOwnedSlice(allocator);
}

/// Like `render`, but routes a render-time diagnostic back to the caller instead
/// of panicking blind. The offending text is written to `diag_out` (a slice into
/// `template`, valid as long as the template buffer lives) alongside the error:
///
///   - `error.CompError` — a `{% comp error %}` was reached; the detail is the
///     template author's message.
///   - `error.InvalidIfCondition` — an `{% if %}` / `{% unless %}` condition the
///     engine cannot parse; the detail is the condition text.
///
/// The caller knows the invocation's source location, so it is the one that can
/// turn either into a located Koru diagnostic.
pub fn renderCollectDiag(
    allocator: Allocator,
    template: []const u8,
    ctx: *const Context,
    diag_out: ?*?[]const u8,
) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, template.len);
    errdefer output.deinit(allocator);

    try renderTo(template, ctx, output.writer(allocator), diag_out, .{});

    return try output.toOwnedSlice(allocator);
}

/// Render a template directly to a writer. `diag_out` is an optional sink for
/// the offending text of a render-time diagnostic (see `renderCollectDiag`);
/// when null, a `{% comp error %}` panics — no caller is positioned to render a
/// located diagnostic — while a malformed condition still returns its error.
/// `env` carries the named-template and filter registries the template can call
/// out to.
pub fn renderTo(
    template: []const u8,
    ctx: *const Context,
    writer: anytype,
    diag_out: ?*?[]const u8,
    env: RenderEnv,
) anyerror!void {
    var pos: usize = 0;

    // `{% const %}` bindings live in a lazily-created overlay scope whose parent
    // is `ctx`, so they're visible to the rest of THIS block (and nested blocks,
    // which get `cur` as parent) but die when this render returns — lexical
    // scoping for free. `cur` is what every lookup/recursion uses.
    var locals: ?Context = null;
    defer if (locals) |*l| l.deinit();
    var cur: *const Context = ctx;

    while (pos < template.len) {
        // Look for next tag - find whichever comes first: {{ or {%
        const output_tag = std.mem.indexOfPos(u8, template, pos, "{{");
        const logic_tag = std.mem.indexOfPos(u8, template, pos, "{%");

        // Determine which tag comes first (if any)
        const next_tag: ?struct { start: usize, is_output: bool } = blk: {
            if (output_tag) |o| {
                if (logic_tag) |l| {
                    break :blk .{ .start = @min(o, l), .is_output = o < l };
                }
                break :blk .{ .start = o, .is_output = true };
            } else if (logic_tag) |l| {
                break :blk .{ .start = l, .is_output = false };
            }
            break :blk null;
        };

        if (next_tag) |tag| {
            // Output literal text before tag
            try writer.writeAll(template[pos..tag.start]);

            if (tag.is_output) {
                // {{ variable }} - output tag
                if (std.mem.indexOfPos(u8, template, tag.start + 2, "}}")) |end| {
                    const tag_content = std.mem.trim(u8, template[tag.start + 2 .. end], " \t");

                    // Output variable value
                    if (cur.get(tag_content)) |value| {
                        switch (value) {
                            .string => |s| try writer.writeAll(s),
                            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                            .array => try writer.writeAll("[array]"),
                            .record => try writer.writeAll("[node]"),
                        }
                    }

                    pos = end + 2;
                    continue;
                }
            } else {
                // {% logic %} - logic tag
                if (std.mem.indexOfPos(u8, template, tag.start + 2, "%}")) |end| {
                    const tag_content = std.mem.trim(u8, template[tag.start + 2 .. end], " \t");

                    // `{% comp error %}MESSAGE{% endcomp %}` — a template-author
                    // diagnostic. Reaching it during render means the template's
                    // contract was violated (e.g. a required branch is absent);
                    // surface the author's message and fail the compile rather
                    // than letting a cryptic host-language error through later.
                    if (std.mem.eql(u8, tag_content, "comp error")) {
                        const msg_start = end + 2;
                        const ec = findEndTag(template, msg_start, "endcomp") orelse return error.UnmatchedCompError;
                        const msg = std.mem.trim(u8, template[msg_start..ec.start], " \t\r\n");
                        // Hand the message back to a caller that can locate it,
                        // or panic if nobody's collecting (no source context).
                        if (diag_out) |sink| {
                            sink.* = msg;
                            return error.CompError;
                        }
                        std.debug.panic("comp error: {s}", .{msg});
                    }

                    // Parse the tag
                    if (std.mem.startsWith(u8, tag_content, "if ")) {
                        const cond_text = std.mem.trim(u8, tag_content[3..], " \t");
                        const block_end = findEndTag(template, end + 2, "endif") orelse return error.UnmatchedIf;
                        const inner = template[end + 2 .. block_end.start];

                        // Split on a depth-0 `{% else %}`, if present.
                        const then_part, const else_part = if (findElseTag(inner)) |e|
                            .{ inner[0..e.start], inner[e.end..] }
                        else
                            .{ inner, inner[inner.len..] };

                        const cond = evalCondition(cond_text, cur) catch |err| {
                            if (diag_out) |sink| sink.* = cond_text;
                            return err;
                        };
                        if (cond) {
                            try renderTo(then_part, cur, writer, diag_out, env);
                        } else {
                            try renderTo(else_part, cur, writer, diag_out, env);
                        }

                        pos = block_end.end;
                        continue;
                    }

                    if (std.mem.startsWith(u8, tag_content, "unless ")) {
                        const cond_text = std.mem.trim(u8, tag_content[7..], " \t");
                        const block_end = findEndTag(template, end + 2, "endunless") orelse return error.UnmatchedUnless;
                        const inner = template[end + 2 .. block_end.start];

                        // `unless` is `if` negated — same condition grammar, so a
                        // malformed one is just as loud here.
                        const should_render = !(evalCondition(cond_text, cur) catch |err| {
                            if (diag_out) |sink| sink.* = cond_text;
                            return err;
                        });
                        if (should_render) {
                            try renderTo(inner, cur, writer, diag_out, env);
                        }

                        pos = block_end.end;
                        continue;
                    }

                    if (std.mem.startsWith(u8, tag_content, "for ")) {
                        // Parse "for item in array"
                        const rest = std.mem.trim(u8, tag_content[4..], " \t");
                        const in_pos = std.mem.indexOf(u8, rest, " in ") orelse return error.InvalidForSyntax;
                        const item_name = std.mem.trim(u8, rest[0..in_pos], " \t");
                        const array_name = std.mem.trim(u8, rest[in_pos + 4 ..], " \t");

                        const block_end = findEndTag(template, end + 2, "endfor") orelse return error.UnmatchedFor;
                        const inner = template[end + 2 .. block_end.start];

                        // Iterate over array. Each item is bound under `item_name`
                        // (so the body references fields as `{{ item_name.field }}`)
                        // with the enclosing ctx as parent (so outer vars resolve).
                        if (cur.get(array_name)) |value| {
                            switch (value) {
                                .array => |items| {
                                    for (items) |item_ctx| {
                                        var loop_ctx = Context.init(cur.allocator);
                                        defer loop_ctx.deinit();
                                        loop_ctx.parent = cur;
                                        loop_ctx.scope_name = item_name;
                                        loop_ctx.scope = item_ctx;
                                        // Also bind the item by name as a record,
                                        // so it can be passed whole to `{% render
                                        // …, x: item %}`, not just dotted into.
                                        try loop_ctx.put(item_name, .{ .record = item_ctx });
                                        try renderTo(inner, &loop_ctx, writer, diag_out, env);
                                    }
                                },
                                else => {},
                            }
                        }

                        pos = block_end.end;
                        continue;
                    }

                    // `{% case KEY %}{% when "LIT" %}…{% else %}…{% endcase %}` —
                    // many-way dispatch on a string value (typically `node.kind`).
                    // Renders the first `when` whose literal equals KEY's string
                    // value, else the `else` clause if present. This is the
                    // walker's node-kind dispatch.
                    if (std.mem.startsWith(u8, tag_content, "case ")) {
                        const key = std.mem.trim(u8, tag_content[5..], " \t");
                        const block_end = findEndTag(template, end + 2, "endcase") orelse return error.UnmatchedCase;
                        const inner = template[end + 2 .. block_end.start];

                        const target: ?[]const u8 = if (cur.get(key)) |v|
                            (if (v == .string) v.string else null)
                        else
                            null;

                        try renderCase(inner, target, cur, writer, diag_out, env);
                        pos = block_end.end;
                        continue;
                    }

                    // `{% const NAME = RHS %}` — bind-once. RHS is a single
                    // filter call `f(args)`, a bare variable, or a string literal
                    // — NEVER an expression (navigation happens at use-site). This
                    // is parse-once-walk-many: `{% const tree = parse_json(src) %}`.
                    // See docs/PARSER_PALETTE.md §4.
                    if (std.mem.startsWith(u8, tag_content, "const ")) {
                        const decl = std.mem.trim(u8, tag_content[6..], " \t");
                        const eq = std.mem.indexOfScalar(u8, decl, '=') orelse return error.InvalidConst;
                        const name = std.mem.trim(u8, decl[0..eq], " \t");
                        const rhs = std.mem.trim(u8, decl[eq + 1 ..], " \t");

                        if (locals == null) {
                            locals = Context.init(ctx.allocator);
                            locals.?.parent = ctx;
                            cur = &locals.?;
                        }
                        if (try evalConstRhs(rhs, cur, ctx.allocator, env.filters)) |val| {
                            try locals.?.put(name, val);
                        }

                        pos = end + 2;
                        continue;
                    }

                    // `{% render "NAME", VAR: PATH %}` — render the named
                    // sub-template with PATH (which must resolve to a record node)
                    // bound under VAR. Recursing on a child node is how the walker
                    // descends the tree; the strict-sub-node discipline (a render
                    // target should be a child of the current node) keeps walks
                    // total. See docs/PARSER_PALETTE.md §6.
                    if (std.mem.startsWith(u8, tag_content, "render ")) {
                        try renderInclude(tag_content[7..], cur, writer, diag_out, env);
                        pos = end + 2;
                        continue;
                    }

                    // Unknown tag - skip it
                    pos = end + 2;
                    continue;
                }
            }
        }

        // No more tags - output rest of template
        try writer.writeAll(template[pos..]);
        break;
    }
}

const BlockEnd = struct {
    start: usize,  // Start of {% end... %}
    end: usize,    // After %}
};

/// Find a depth-0 `{% else %}` inside an if-block's inner text. Nested
/// if/for/unless/comp blocks increment depth so we only match the else that
/// belongs to THIS if. Returns null if there's no else at this level.
fn findElseTag(template: []const u8) ?BlockEnd {
    var pos: usize = 0;
    var depth: usize = 0;
    while (std.mem.indexOfPos(u8, template, pos, "{%")) |tag_start| {
        const tag_end = std.mem.indexOfPos(u8, template, tag_start + 2, "%}") orelse break;
        const tc = std.mem.trim(u8, template[tag_start + 2 .. tag_end], " \t");
        if (std.mem.startsWith(u8, tc, "if ") or
            std.mem.startsWith(u8, tc, "for ") or
            std.mem.startsWith(u8, tc, "unless ") or
            std.mem.startsWith(u8, tc, "case ") or
            std.mem.startsWith(u8, tc, "comp error"))
        {
            depth += 1;
        } else if (std.mem.eql(u8, tc, "endif") or
            std.mem.eql(u8, tc, "endfor") or
            std.mem.eql(u8, tc, "endunless") or
            std.mem.eql(u8, tc, "endcase") or
            std.mem.eql(u8, tc, "endcomp"))
        {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and std.mem.eql(u8, tc, "else")) {
            return .{ .start = tag_start, .end = tag_end + 2 };
        }
        pos = tag_end + 2;
    }
    return null;
}

fn findEndTag(template: []const u8, start_pos: usize, end_tag: []const u8) ?BlockEnd {
    var pos = start_pos;
    var depth: usize = 1;

    // Determine what tag type we're looking for
    const start_tag = if (std.mem.eql(u8, end_tag, "endif"))
        "if "
    else if (std.mem.eql(u8, end_tag, "endunless"))
        "unless "
    else if (std.mem.eql(u8, end_tag, "endfor"))
        "for "
    else if (std.mem.eql(u8, end_tag, "endcomp"))
        "comp error"
    else if (std.mem.eql(u8, end_tag, "endcase"))
        "case "
    else
        return null;

    while (pos < template.len) {
        if (std.mem.indexOfPos(u8, template, pos, "{%")) |tag_start| {
            if (std.mem.indexOfPos(u8, template, tag_start + 2, "%}")) |tag_end| {
                const tag_content = std.mem.trim(u8, template[tag_start + 2 .. tag_end], " \t");

                if (std.mem.startsWith(u8, tag_content, start_tag)) {
                    depth += 1;
                } else if (std.mem.eql(u8, tag_content, end_tag)) {
                    depth -= 1;
                    if (depth == 0) {
                        return .{
                            .start = tag_start,
                            .end = tag_end + 2,
                        };
                    }
                }

                pos = tag_end + 2;
                continue;
            }
        }
        break;
    }

    return null;
}

const ClauseKind = enum { when_clause, else_clause };
const Clause = struct {
    tag_start: usize,
    body_start: usize,
    kind: ClauseKind,
    literal: []const u8, // meaningful only for `when_clause`
};

/// The condition grammar of `{% if %}` / `{% unless %}`, in full:
///
///     <cond>    := <key> | <operand> ("==" | "!=") <operand>
///     <operand> := <key> | "<literal>"
///
/// A bare `<key>` is truthiness (`Value.truthy`), and a missing key is false.
/// A comparison is on TEXT: each side resolves to its string form, and a missing
/// key reads as the empty string — so `{% if x != "" %}` is the honest test for
/// "x is bound and non-empty".
///
/// Anything outside this grammar is `error.InvalidIfCondition`. There is no
/// silent-false path: before this parser existed the whole condition was taken
/// as one variable NAME, so `{% if arm.guard != "" %}` looked up a variable
/// literally called `arm.guard != ""`, missed, and rendered `{% else %}` every
/// time — a branch that reads as live and is dead code (`320_138`, `250_012`).
fn evalCondition(text: []const u8, ctx: *const Context) !bool {
    if (findComparison(text)) |c| {
        const lhs = try operandText(text[0..c.lhs_end], ctx);
        const rhs = try operandText(text[c.rhs_start..], ctx);
        const equal = std.mem.eql(u8, lhs, rhs);
        return if (c.negated) !equal else equal;
    }
    // No operator, so the whole text must be a bare key. A key never contains
    // whitespace, so anything that does is a condition this engine does not
    // understand (`a and b`, `x > 1`, …) — and saying so out loud is the point.
    if (!isKey(text)) return error.InvalidIfCondition;
    return if (ctx.get(text)) |v| v.truthy() else false;
}

const Comparison = struct { lhs_end: usize, rhs_start: usize, negated: bool };

/// Locate a top-level `==` / `!=`, skipping any inside a quoted literal — keys
/// carry quotes too (`continuations["done"]`), so quote-tracking is what keeps
/// `continuations["done"] != ""` splitting at the right operator.
fn findComparison(text: []const u8) ?Comparison {
    var in_quote = false;
    var i: usize = 0;
    while (i + 1 < text.len) : (i += 1) {
        if (text[i] == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        const negated = text[i] == '!' and text[i + 1] == '=';
        if (negated or (text[i] == '=' and text[i + 1] == '=')) {
            return .{ .lhs_end = i, .rhs_start = i + 2, .negated = negated };
        }
    }
    return null;
}

/// Resolve one side of a comparison to its text. A quoted literal is itself; a
/// key is looked up, with a missing key reading as empty (same contract as the
/// bare-key truthiness path). An `array` or `record` has no text form — `[array]`
/// and `[node]` are display placeholders, never values to compare — so reaching
/// for one is a template bug, not a false.
fn operandText(raw: []const u8, ctx: *const Context) ![]const u8 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return error.InvalidIfCondition;
    if (t[0] == '"') {
        if (t.len < 2 or t[t.len - 1] != '"') return error.InvalidIfCondition;
        return t[1 .. t.len - 1];
    }
    if (!isKey(t)) return error.InvalidIfCondition;
    const v = ctx.get(t) orelse return "";
    return switch (v) {
        .string => |s| s,
        .boolean => |b| if (b) "true" else "false",
        .array, .record => error.InvalidIfCondition,
    };
}

/// A context key: non-empty and whitespace-free. Quotes and brackets are legal —
/// `template_processor` stores literal dotted keys like `continuations["done"]`.
fn isKey(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') return false;
    }
    return true;
}

/// Strip a single pair of surrounding double quotes, if present.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

/// Find the next depth-0 `{% when "LIT" %}` or `{% else %}` clause in a case
/// block's inner text, starting at `from`. Nested blocks increment depth so
/// only clauses belonging to THIS case match.
fn findNextClause(inner: []const u8, from: usize) ?Clause {
    var pos = from;
    var depth: usize = 0;
    while (std.mem.indexOfPos(u8, inner, pos, "{%")) |tag_start| {
        const tag_end = std.mem.indexOfPos(u8, inner, tag_start + 2, "%}") orelse break;
        const tc = std.mem.trim(u8, inner[tag_start + 2 .. tag_end], " \t");
        if (std.mem.startsWith(u8, tc, "if ") or
            std.mem.startsWith(u8, tc, "for ") or
            std.mem.startsWith(u8, tc, "unless ") or
            std.mem.startsWith(u8, tc, "case ") or
            std.mem.startsWith(u8, tc, "comp error"))
        {
            depth += 1;
        } else if (std.mem.eql(u8, tc, "endif") or
            std.mem.eql(u8, tc, "endfor") or
            std.mem.eql(u8, tc, "endunless") or
            std.mem.eql(u8, tc, "endcase") or
            std.mem.eql(u8, tc, "endcomp"))
        {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and std.mem.startsWith(u8, tc, "when ")) {
            return .{
                .tag_start = tag_start,
                .body_start = tag_end + 2,
                .kind = .when_clause,
                .literal = stripQuotes(std.mem.trim(u8, tc[5..], " \t")),
            };
        } else if (depth == 0 and std.mem.eql(u8, tc, "else")) {
            return .{ .tag_start = tag_start, .body_start = tag_end + 2, .kind = .else_clause, .literal = "" };
        }
        pos = tag_end + 2;
    }
    return null;
}

/// Render the body of the first `{% when %}` whose literal equals `target`, or
/// the `{% else %}` body if no `when` matches. `target` null (KEY missing or
/// non-string) matches only `else`.
fn renderCase(
    inner: []const u8,
    target: ?[]const u8,
    ctx: *const Context,
    writer: anytype,
    diag_out: ?*?[]const u8,
    env: RenderEnv,
) anyerror!void {
    var pos: usize = 0;
    var else_body: ?[]const u8 = null;
    while (findNextClause(inner, pos)) |clause| {
        const next = findNextClause(inner, clause.body_start);
        const body_end = if (next) |n| n.tag_start else inner.len;
        const body = inner[clause.body_start..body_end];
        switch (clause.kind) {
            .when_clause => {
                if (target) |t| {
                    if (std.mem.eql(u8, clause.literal, t)) {
                        try renderTo(body, ctx, writer, diag_out, env);
                        return;
                    }
                }
            },
            .else_clause => else_body = body,
        }
        pos = clause.body_start;
    }
    if (else_body) |eb| try renderTo(eb, ctx, writer, diag_out, env);
}

/// Evaluate a `{% const %}` right-hand side. Per the discipline, the RHS is
/// exactly one of: a filter call `name(arg, …)`, a bare variable reference, or a
/// string literal — NEVER an arithmetic/operator expression. Returns null when a
/// bare reference doesn't resolve (the binding is then skipped).
fn evalConstRhs(
    rhs: []const u8,
    ctx: *const Context,
    allocator: Allocator,
    filters: ?*const FilterRegistry,
) anyerror!?Value {
    const s = std.mem.trim(u8, rhs, " \t");
    if (s.len == 0) return null;

    // String literal.
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return Value{ .string = s[1 .. s.len - 1] };
    }

    // Filter call: `name(arg, arg, …)`.
    if (std.mem.indexOfScalar(u8, s, '(')) |lp| {
        if (s[s.len - 1] != ')') return error.InvalidConst;
        const name = std.mem.trim(u8, s[0..lp], " \t");
        const args_str = s[lp + 1 .. s.len - 1];

        const reg = filters orelse return error.NoFilters;
        const f = reg.get(name) orelse return error.UnknownFilter;

        var args = try std.ArrayList(Value).initCapacity(allocator, 0);
        defer args.deinit(allocator);
        var it = std.mem.splitScalar(u8, args_str, ',');
        while (it.next()) |raw| {
            const a = std.mem.trim(u8, raw, " \t");
            if (a.len == 0) continue;
            if (a.len >= 2 and a[0] == '"' and a[a.len - 1] == '"') {
                try args.append(allocator, .{ .string = a[1 .. a.len - 1] });
            } else if (ctx.get(a)) |v| {
                try args.append(allocator, v);
            } else {
                // An unresolved bare argument is a contract violation, not a
                // silent empty — fail loud.
                return error.UnresolvedArgument;
            }
        }
        return try f(allocator, args.items);
    }

    // Bare variable reference (navigation lives at the use-site, not here).
    return ctx.get(s);
}

/// Handle `{% render "NAME", VAR: PATH %}`: render the registered template NAME
/// with PATH (which must resolve to a record node) bound under VAR as the scope.
/// The bare form `{% render "NAME" %}` renders in the current context.
fn renderInclude(
    args: []const u8,
    ctx: *const Context,
    writer: anytype,
    diag_out: ?*?[]const u8,
    env: RenderEnv,
) anyerror!void {
    const reg = env.templates orelse return; // no registry → nothing to render
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0 or trimmed[0] != '"') return error.InvalidRender;
    const name_end = std.mem.indexOfScalarPos(u8, trimmed, 1, '"') orelse return error.InvalidRender;
    const name = trimmed[1..name_end];

    const body = reg.get(name) orelse return error.UnknownTemplate;

    var rest = std.mem.trim(u8, trimmed[name_end + 1 ..], " \t");
    if (rest.len > 0 and rest[0] == ',') {
        rest = std.mem.trim(u8, rest[1..], " \t");
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.InvalidRender;
        const var_name = std.mem.trim(u8, rest[0..colon], " \t");
        const path = std.mem.trim(u8, rest[colon + 1 ..], " \t");

        const pv = ctx.get(path) orelse return; // unresolved path → render nothing
        if (pv != .record) return; // only record nodes are walkable
        var sub = Context.init(ctx.allocator);
        defer sub.deinit();
        sub.parent = ctx;
        sub.scope_name = var_name;
        sub.scope = pv.record;
        try renderTo(body, &sub, writer, diag_out, env);
    } else {
        try renderTo(body, ctx, writer, diag_out, env);
    }
}

// Tests
test "simple interpolation" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "Player" });

    const result = try render(allocator, "const {{ name }} = struct {};", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("const Player = struct {};", result);
}

test "if conditional - true" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("is_pub", .{ .boolean = true });
    try ctx.put("name", .{ .string = "Player" });

    const result = try render(allocator, "{% if is_pub %}pub {% endif %}const {{ name }} = struct {};", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("pub const Player = struct {};", result);
}

test "if condition - comparison against a literal" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("guard", .{ .string = "x == 1" });
    try ctx.put("empty", .{ .string = "" });

    const cases = [_]struct { tmpl: []const u8, want: []const u8 }{
        // The shape a dispatch template needs: bound-and-non-empty vs not.
        .{ .tmpl = "{% if guard != \"\" %}Y{% else %}N{% endif %}", .want = "Y" },
        .{ .tmpl = "{% if empty != \"\" %}Y{% else %}N{% endif %}", .want = "N" },
        // A missing key reads as the empty string, matching the bare-key path
        // where a missing key is false.
        .{ .tmpl = "{% if nope != \"\" %}Y{% else %}N{% endif %}", .want = "N" },
        .{ .tmpl = "{% if nope == \"\" %}Y{% else %}N{% endif %}", .want = "Y" },
        .{ .tmpl = "{% if guard == \"x == 1\" %}Y{% else %}N{% endif %}", .want = "Y" },
        .{ .tmpl = "{% if guard == \"other\" %}Y{% else %}N{% endif %}", .want = "N" },
        // `unless` is `if` negated over the same grammar.
        .{ .tmpl = "{% unless guard != \"\" %}Y{% endunless %}N", .want = "N" },
    };
    for (cases) |c| {
        const result = try render(allocator, c.tmpl, &ctx);
        defer allocator.free(result);
        try std.testing.expectEqualStrings(c.want, result);
    }
}

test "if condition - an operand may be a key carrying quotes" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    // template_processor stores literal dotted keys whole, quotes included.
    try ctx.put("continuations[\"done\"].continue", .{ .string = "__koru_continue_0" });

    const result = try render(
        allocator,
        "{% if continuations[\"done\"].continue != \"\" %}Y{% else %}N{% endif %}",
        &ctx,
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Y", result);
}

test "if condition - outside the grammar is loud, never false" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("a", .{ .string = "1" });
    try ctx.put("items", .{ .array = &.{} });

    // Each of these once resolved to "look up a variable named <the whole
    // condition>", missed, and rendered `{% else %}` — silently, forever.
    const bad = [_][]const u8{
        "{% if a and a %}Y{% endif %}",
        "{% if a > 1 %}Y{% endif %}",
        "{% if a == %}Y{% endif %}",
        "{% if == \"1\" %}Y{% endif %}",
        "{% if a == \"unterminated %}Y{% endif %}",
        "{% if items == \"\" %}Y{% endif %}", // an array has no text form
        "{% unless a and a %}Y{% endunless %}",
    };
    for (bad) |tmpl| {
        try std.testing.expectError(error.InvalidIfCondition, render(allocator, tmpl, &ctx));
    }
}

test "if conditional - false" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("is_pub", .{ .boolean = false });
    try ctx.put("name", .{ .string = "Player" });

    const result = try render(allocator, "{% if is_pub %}pub {% endif %}const {{ name }} = struct {};", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("const Player = struct {};", result);
}

test "unless conditional" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("is_private", .{ .boolean = false });

    const result = try render(allocator, "{% unless is_private %}pub {% endunless %}fn foo() void {}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("pub fn foo() void {}", result);
}

test "for loop" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create array items
    var item1 = Context.init(allocator);
    defer item1.deinit();
    try item1.put("name", .{ .string = "red" });

    var item2 = Context.init(allocator);
    defer item2.deinit();
    try item2.put("name", .{ .string = "green" });

    var item3 = Context.init(allocator);
    defer item3.deinit();
    try item3.put("name", .{ .string = "blue" });

    const items = [_]*Context{ &item1, &item2, &item3 };
    try ctx.put("colors", .{ .array = &items });

    const result = try render(allocator, "{% for c in colors %}{{ name }}, {% endfor %}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("red, green, blue, ", result);
}

// --- Tree-walker primitives (docs/PARSER_PALETTE.md) ---

test "case dispatch on node.kind + record field access" {
    const allocator = std.testing.allocator;

    // node = number{ value: "42" }
    var num = Context.init(allocator);
    defer num.deinit();
    try num.put("kind", .{ .string = "number" });
    try num.put("value", .{ .string = "42" });

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("node", .{ .record = &num });

    const tmpl = "{% case node.kind %}" ++
        "{% when \"number\" %}{{ node.value }}" ++
        "{% when \"string\" %}\"{{ node.value }}\"" ++
        "{% else %}?{% endcase %}";

    const result = try render(allocator, tmpl, &ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "recursive render walks a binary expression tree" {
    const allocator = std.testing.allocator;

    // Build 1 + 2 * 3  →  binary(+, num(1), binary(*, num(2), num(3)))
    var one = Context.init(allocator);
    defer one.deinit();
    try one.put("kind", .{ .string = "number" });
    try one.put("value", .{ .string = "1" });

    var two = Context.init(allocator);
    defer two.deinit();
    try two.put("kind", .{ .string = "number" });
    try two.put("value", .{ .string = "2" });

    var three = Context.init(allocator);
    defer three.deinit();
    try three.put("kind", .{ .string = "number" });
    try three.put("value", .{ .string = "3" });

    var mul = Context.init(allocator);
    defer mul.deinit();
    try mul.put("kind", .{ .string = "binary" });
    try mul.put("op", .{ .string = "*" });
    try mul.put("left", .{ .record = &two });
    try mul.put("right", .{ .record = &three });

    var add = Context.init(allocator);
    defer add.deinit();
    try add.put("kind", .{ .string = "binary" });
    try add.put("op", .{ .string = "+" });
    try add.put("left", .{ .record = &one });
    try add.put("right", .{ .record = &mul });

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("node", .{ .record = &add });

    var registry = TemplateRegistry.init(allocator);
    defer registry.deinit();
    // The walker: dispatch on kind, recurse on named child fields. Note this
    // emits always-flat (no precedence parens yet) — L2; inherited-attribute
    // precedence is the L3 follow-up (docs/PARSER_PALETTE.md §6).
    const expr_tmpl = "{% case node.kind %}" ++
        "{% when \"number\" %}{{ node.value }}" ++
        "{% when \"binary\" %}{% render \"expr\", node: node.left %} {{ node.op }} {% render \"expr\", node: node.right %}" ++
        "{% endcase %}";
    try registry.put("expr", expr_tmpl);

    const result = try renderWithEnv(
        allocator,
        "{% render \"expr\", node: node %}",
        &ctx,
        null,
        .{ .templates = &registry },
    );
    defer allocator.free(result);
    try std.testing.expectEqualStrings("1 + 2 * 3", result);
}

// A test filter: `parse_pair("a:b")` → record node{ kind:"pair", left:"a", right:"b" }.
// Stands in for a real parser (parse_json/parse_expr) to exercise the const +
// filter + walk path end to end on the arena allocator.
fn testParsePair(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const s = args[0].string;
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadPair;

    const node = try allocator.create(Context);
    node.* = Context.init(allocator);
    try node.put("kind", .{ .string = "pair" });
    try node.put("left", .{ .string = s[0..colon] });
    try node.put("right", .{ .string = s[colon + 1 ..] });
    return Value{ .record = node };
}

test "const binds a filter call result, then the body walks it" {
    // Arena: the filter allocates a node tree that must outlive the call.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_pair", testParsePair);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("src", .{ .string = "key:value" });

    const tmpl = "{% const p = parse_pair(src) %}" ++
        "{% case p.kind %}{% when \"pair\" %}{{ p.left }}={{ p.right }}{% endcase %}";

    const result = try renderWithEnv(allocator, tmpl, &ctx, null, .{ .filters = &filters });
    try std.testing.expectEqualStrings("key=value", result);
}

test "const is lexically scoped to its block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_pair", testParsePair);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("flag", .{ .boolean = true });
    try ctx.put("src", .{ .string = "in:ner" });

    // `p` is declared inside the if-body; referencing it outside resolves to
    // nothing (empty), proving the binding died with the block.
    const tmpl = "{% if flag %}{% const p = parse_pair(src) %}{{ p.left }}{% endif %}[{{ p.left }}]";

    const result = try renderWithEnv(allocator, tmpl, &ctx, null, .{ .filters = &filters });
    try std.testing.expectEqualStrings("in[]", result);
}
