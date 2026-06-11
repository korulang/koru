// Template processor pass.
//
// Two modes, distinguished by variant-arg:
//
//   `~proc foo|template|zig {...}`       — PER-CALL (default, not yet built):
//                                          render the body per invocation
//                                          with call-site captured args in
//                                          the context, inline at call site.
//   `~proc foo|template(once)|zig {...}` — PER-DECL (one-shot): render the
//                                          body once at proc-decl time with
//                                          proc-decl context; result shared
//                                          across all invocations.
//
// Per-call subsumes per-decl semantically, but per-decl is preserved as an
// opt-in for the (probably rare) case where the user wants the contract
// guarantee that the template doesn't depend on call args.
//
// This implements the variant-with-args story already established for
// `|zig(reference)` / `|zig(optimized)` in the suite.

const std = @import("std");
const ast = @import("ast");
const liquid = @import("liquid");
const log = @import("log");
const errors = @import("errors");
const struct_literal = @import("struct_literal");

const TEMPLATE_TAG = "template";
const ONCE_MODE = "once";

/// A `{% comp error %}` reached during template rendering is a template-author
/// contract violation (e.g. a required branch the consumer didn't provide).
/// Surface it as a located Koru diagnostic (KORU120) pointing at the source
/// the template was rendered for, then fail the compile cleanly — never let
/// the host language's downstream error be the one the user sees.
fn emitCompErrorAndExit(location: errors.SourceLocation, message: []const u8) noreturn {
    std.debug.print("error[{s}]: {s}\n  --> {s}:{d}:{d}\n", .{
        @tagName(errors.ErrorCode.KORU120),
        message,
        location.file,
        location.line,
        location.column,
    });
    std.process.exit(1);
}

/// Index of a top-level `..` (range operator) in `s` — one not nested inside
/// `()`/`[]`/`{}` (so a slice like `buf[0..n]` is NOT seen as a range). Null if
/// there is no top-level range. The "simplified ranges for JS" classifier; the
/// richer Zig-subset translator is the deferred follow-up (docs/PARSER_PALETTE.md §8.4).
fn findTopLevelRange(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        switch (s[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '.' => if (depth == 0 and s[i + 1] == '.') return i,
            else => {},
        }
    }
    return null;
}

/// `parse_range(expr)` filter: classify an iterable expression as a range.
/// Returns a record node `{ is_range, lo, hi }` the `for|template|js` body
/// branches on — a range becomes a JS counting loop, anything else stays a
/// `for…of`. This is the simplified-range path that unblocks cross-target `~for`
/// (140_014); it deliberately handles only `LO..HI`, leaving array literals etc.
/// to flow through verbatim (which already works for JS-shaped iterables).
fn parseRangeFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const s = std.mem.trim(u8, args[0].string, " \t");

    const node = try allocator.create(liquid.Context);
    node.* = liquid.Context.init(allocator);
    if (findTopLevelRange(s)) |idx| {
        try node.put("is_range", .{ .boolean = true });
        try node.put("lo", .{ .string = std.mem.trim(u8, s[0..idx], " \t") });
        try node.put("hi", .{ .string = std.mem.trim(u8, s[idx + 2 ..], " \t") });
    } else {
        try node.put("is_range", .{ .boolean = false });
    }
    return liquid.Value{ .record = node };
}

/// Return the index of the next top-level `,` (or end / closing `}`) at or
/// after `start`, treating `{}`/`()`/`[]` nesting and `"…"` string literals as
/// opaque. Mirrors codegen_utils.parseValue's depth tracking — the value of a
/// field runs until the next separator that isn't inside a nested construct.
fn scanValueEnd(s: []const u8, start: usize) usize {
    var i = start;
    var brace: usize = 0;
    var paren: usize = 0;
    var bracket: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
            }
            continue; // i lands on the closing quote; loop's i+=1 steps past it
        }
        switch (c) {
            '{' => brace += 1,
            '}' => {
                if (brace == 0) break; // closing brace of an unstripped struct → end
                brace -= 1;
            },
            '(' => paren += 1,
            ')' => if (paren > 0) {
                paren -= 1;
            },
            '[' => bracket += 1,
            ']' => if (bracket > 0) {
                bracket -= 1;
            },
            // A top-level `,` OR newline ends a field. Newlines inside a nested
            // construct (a multi-line struct value) are protected by depth, so a
            // value may still span lines when braced — only an unnested newline
            // separates fields (the canonical `const { … }` block shape).
            ',', '\n', '\r' => if (brace == 0 and paren == 0 and bracket == 0) break,
            else => {},
        }
    }
    return i;
}

/// Koru-native base types — a bounded, defined set (mirrors the units-of-measure
/// scope guard). Only these are recognized as a `value[type]` annotation; anything
/// else in a trailing `[…]` (array literals `[1,2,3]`, indexing) is left in the value.
/// The `value[type]` annotation parser lives in struct_literal (the projector
/// module) — `const`'s filter here and `capture`'s seed builder both call THAT
/// single implementation, so the two lowerings cannot drift.
const peelBaseType = struct_literal.peelBaseType;

/// `parse_fields(struct_text)` filter: split a brace-optional Koru field list
/// (`name: "X", count: 42[i32]`, or `{ … }`, comma- OR newline-separated) into an
/// array of `{ name, value, type }` record nodes the template iterates with
/// `{% for f in fields %}`. `type` is the OPTIONAL Koru-native base-type annotation
/// (`42[i32]` → value "42", type "i32"); empty when absent. The per-target template
/// branches on `{% if f.type %}` to emit `@as(i32, 42)` (Zig) vs `42` (JS) — the
/// annotation is the first thing that genuinely DIVERGES between the variants. Both
/// `|zig` and `|js` call THIS single parser, so the lowerings cannot drift. The
/// input is a Source's `.text`, so the caller has location context for diagnostics.
fn parseFieldsFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const input = std.mem.trim(u8, args[0].string, " \t\n\r");
    // Accept the field list with or without wrapping braces.
    const body = if (input.len >= 2 and input[0] == '{' and input[input.len - 1] == '}')
        std.mem.trim(u8, input[1 .. input.len - 1], " \t\n\r")
    else
        input;

    var nodes: std.ArrayList(*liquid.Context) = .empty;

    var i: usize = 0;
    while (i < body.len) {
        // Skip whitespace and field separators (`,` or newline).
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or
            body[i] == '\n' or body[i] == '\r' or body[i] == ',')) i += 1;
        if (i >= body.len) break;

        // Field name (identifier).
        const name_start = i;
        while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '_')) i += 1;
        const field_name = body[name_start..i];
        if (field_name.len == 0) break;

        // Skip whitespace, require `:`.
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
        if (i >= body.len or body[i] != ':') break;
        i += 1;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;

        // Value runs until the next top-level separator.
        const value_start = i;
        i = scanValueEnd(body, i);
        const field_value = std.mem.trim(u8, body[value_start..i], " \t\n\r");
        const peeled = peelBaseType(field_value);

        const node = try allocator.create(liquid.Context);
        node.* = liquid.Context.init(allocator);
        try node.put("name", .{ .string = field_name });
        try node.put("value", .{ .string = peeled.value });
        try node.put("type", .{ .string = peeled.type });
        try nodes.append(allocator, node);
    }

    return liquid.Value{ .array = try nodes.toOwnedSlice(allocator) };
}

/// Walk the AST and process every proc whose variant chain begins with
/// `template(once)|...`. Mutates ProcDecl.body and ProcDecl.target in place.
/// Also runs the per-call template pass for bare `|template|...` procs:
/// each invocation site gets its template body rendered with that call's
/// captured args, the result stored on the flow's `inline_body` so the
/// emitter inlines it instead of calling a handler.
pub fn processTemplateProcs(
    program: *const ast.Program,
    allocator: std.mem.Allocator,
    build_lang: []const u8,
) !void {
    const items = @constCast(program.items);
    try processItems(items, allocator);
    try processPerCallInvocations(items, items, build_lang, allocator);
}

fn processItems(items: []ast.Item, allocator: std.mem.Allocator) !void {
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*pd| try processProc(pd, allocator),
            .module_decl => |*md| try processItems(@constCast(md.items), allocator),
            else => {},
        }
    }
}

/// Walk all flows, rendering per-call templates at the invocation site.
/// `all_items` is the full program root (for cross-module proc lookup);
/// `items` is the scope currently being walked.
fn processPerCallInvocations(
    all_items: []ast.Item,
    items: []ast.Item,
    build_lang: []const u8,
    allocator: std.mem.Allocator,
) !void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| try maybeRenderPerCall(all_items, flow, build_lang, allocator),
            .module_decl => |*md| try processPerCallInvocations(all_items, @constCast(md.items), build_lang, allocator),
            else => {},
        }
    }
}

/// Render a bare `|template|` proc for one invocation, returning the rendered
/// inline_body (with the inline_stmt marker), or null if the invocation doesn't
/// resolve to a per-call template proc. Shared by top-level flows and nested
/// continuations so inline-template lowering works at every depth.
fn renderTemplateInvocation(
    all_items: []ast.Item,
    invocation: *const ast.Invocation,
    continuations: []const ast.Continuation,
    location: errors.SourceLocation,
    build_lang: []const u8,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    // The per-call inline render happens UPSTREAM of the emitter's variant pick
    // (the template is spliced inline, not left as a surviving proc), so the
    // selection of `|zig` vs `|js` must happen HERE, keyed on the build language.
    // selectPerCallTemplateProc returns the bare-`|template|<build_lang>` proc,
    // or null if the invocation isn't a per-call template at all. A missing
    // lang variant for an event that DOES have a per-call template is a loud
    // compile error (never a silent fall-through to the `|zig` body on a JS
    // build — that is the leak this whole pass exists to kill).
    const proc = selectPerCallTemplateProc(all_items, &invocation.path, build_lang, location) orelse return null;

    // Build context from invocation args. Named args (`name: value`) key on the
    // arg name; positional args (`~for(&items)`, which parse with name == value)
    // bind to the event's field at that position so `{{ iterable }}` resolves.
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    const event_decl = findEventDeclByLastSegment(all_items, &invocation.path);

    for (invocation.args, 0..) |arg, i| {
        const text = if (arg.expression_value) |expr_val| expr_val.text else arg.value;
        const is_positional = std.mem.eql(u8, arg.name, arg.value);
        const key = if (!is_positional)
            arg.name
        else if (event_decl) |ed| (if (i < ed.input.fields.len) ed.input.fields[i].name else arg.name) else arg.name;
        if (key.len > 0) {
            try ctx.put(key, .{ .string = text });
        }
    }

    // Expose the invoking handlers to the template, SPLIT BY KIND. Effect
    // handlers (`! each`, fire 0-to-N during) land under `effects["<branch>"]`;
    // terminal handlers (`| done`, fire once after) under
    // `continuations["<branch>"]`. The pair is complete — there is no third
    // branch-kind — so this exhausts the surface. Each entry is a sub-context
    // { link, binding, guard, kind, inlined_link }; presence doubles as
    // truthiness. See the template-engine cluster (250_*) for what templates
    // program against. This is a pure SEMANTIC split — the AST keeps one
    // `Continuation` type carrying `kind`; only the template-facing names differ.
    {
        var by_effect = std.StringHashMap(std.ArrayList(*liquid.Context)).init(allocator);
        var by_terminal = std.StringHashMap(std.ArrayList(*liquid.Context)).init(allocator);
        for (continuations, 0..) |cont, idx| {
            if (cont.branch.len == 0) continue; // skip void-chain continuations
            const sub = try allocator.create(liquid.Context);
            sub.* = liquid.Context.init(allocator);
            try sub.put("link", .{ .string = cont.branch });
            try sub.put("binding", .{ .string = cont.binding orelse "" });
            try sub.put("guard", .{ .string = cont.condition orelse "" });
            try sub.put("kind", .{ .string = if (cont.kind == .effect) "effect" else "terminal" });
            // `inlined_link` is a marker the emitter resolves to the handler's
            // body spliced INLINE (in the enclosing scope), vs `link` which is a
            // call to the isolated Handlers fn. `<idx>` is this continuation's
            // position in the node's continuation list — the same slice the
            // emitter resolves against, so it round-trips deterministically.
            const marker = try std.fmt.allocPrint(allocator, "__koru_inline_{d}", .{idx});
            try sub.put("inlined_link", .{ .string = marker });
            // `inlined_link[scope]` splices the body identically AND declares the
            // handler an obligation boundary: the `scoped_` infix is a signal the
            // template_processor scans for post-render to stamp `@scope` on this
            // continuation. Scope is thus a property of the SPLICE SITE the
            // template author chooses, not of the event declaration. Stored under
            // the literal key — liquid's dotted access is exact-match, so
            // `{{ h.inlined_link[scope] }}` resolves here with no parser change.
            const scoped_marker = try std.fmt.allocPrint(allocator, "__koru_inline_scoped_{d}", .{idx});
            try sub.put("inlined_link[scope]", .{ .string = scoped_marker });
            // `continue`: a continuation is CONTINUED (continuation-passing —
            // the producer hands off to the consumer's handler), not called. For
            // terminal handlers, expose a `__koru_continue_<idx>` marker the
            // emitter resolves to the consumer's terminal body at the hand-off
            // point. Effects never get this — they fire during and are called.
            // This is the continuation half of the effect/continuation symmetry
            // (`effects[..]` → call; `continuations[..]` → continue). NB: `.continue`
            // names the concept; the Zig lowering happens to be `return`, but that
            // is a backend detail this surface deliberately does not leak.
            if (cont.kind != .effect) {
                const cont_marker = try std.fmt.allocPrint(allocator, "__koru_continue_{d}", .{idx});
                try sub.put("continue", .{ .string = cont_marker });
            }

            const target_map = if (cont.kind == .effect) &by_effect else &by_terminal;
            const gop = try target_map.getOrPut(cont.branch);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, sub);
        }

        const Putter = struct {
            fn flush(c: *liquid.Context, map: *std.StringHashMap(std.ArrayList(*liquid.Context)), comptime prefix: []const u8, a: std.mem.Allocator) !void {
                var it = map.iterator();
                while (it.next()) |entry| {
                    const arr = try a.alloc(*liquid.Context, entry.value_ptr.items.len);
                    @memcpy(arr, entry.value_ptr.items);
                    const key = try std.fmt.allocPrint(a, prefix ++ "[\"{s}\"]", .{entry.key_ptr.*});
                    try c.put(key, .{ .array = arr });
                }
            }
        };
        try Putter.flush(&ctx, &by_effect, "effects", allocator);
        try Putter.flush(&ctx, &by_terminal, "continuations", allocator);

        // Direct `continuations["<branch>"].continue` keys, so a template writes
        // `{{ continuations["done"].continue }}` WITHOUT iterating — a continuation
        // is continued once, not called N times. Stored under the literal dotted
        // key (liquid's access is exact-match, no parser change). Concatenates
        // markers if a branch carries multiple handlers (when-guards).
        {
            var it = by_terminal.iterator();
            while (it.next()) |entry| {
                var buf: std.ArrayList(u8) = .empty;
                for (entry.value_ptr.items) |sub| {
                    if (sub.get("continue")) |v| {
                        if (v == .string) try buf.appendSlice(allocator, v.string);
                    }
                }
                const key = try std.fmt.allocPrint(allocator, "continuations[\"{s}\"].continue", .{entry.key_ptr.*});
                try ctx.put(key, .{ .string = try buf.toOwnedSlice(allocator) });
            }
        }
    }

    // Per-call templates can call filters (e.g. `parse_range` for cross-target
    // `~for`). Build the registry and render through it.
    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_range", parseRangeFilter);
    try filters.put("parse_fields", parseFieldsFilter);

    var comp_err: ?[]const u8 = null;
    const rendered = liquid.renderWithEnv(allocator, proc.body.text, &ctx, &comp_err, .{ .filters = &filters }) catch |err| {
        if (err == error.CompError) {
            emitCompErrorAndExit(location, comp_err orelse "template comp error");
        }
        return err;
    };

    // Prepend the `inline_stmt` marker so the emitter knows the rendered body is
    // statement-shaped (no trailing `;`). NOTE: we do NOT blank `proc.body` —
    // the emitter stubs `|template|` handlers (`unreachable`), and blanking
    // would corrupt rendering for any *second* invocation of the same template.
    const inline_marker = "//@koru:inline_stmt\n";
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ inline_marker, rendered });
}

fn maybeRenderPerCall(
    all_items: []ast.Item,
    flow: *ast.Flow,
    build_lang: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (flow.inline_body == null) {
        if (try renderTemplateInvocation(all_items, flow.inv(), flow.body.continuations, flow.location, build_lang, allocator)) |rendered| {
            flow.inline_body = rendered;
            log.debug("[TEMPLATE/per-call] rendered '{s}' at top-level call site\n", .{
                if (flow.inv().path.segments.len > 0) flow.inv().path.segments[0] else "<?>",
            });
        }
    }

    // If the rendered body spliced any handler with `[scope]`, stamp `@scope` on
    // the matching continuations so the obligation checker treats each handler
    // body as a per-iteration scope boundary (auto-discharge per loop).
    if (flow.inline_body) |body| {
        try tagScopeFromRenderedBody(body, @constCast(flow.body.continuations), allocator);
    }

    // Nested template invocations (e.g. `~for` inside a pipeline continuation)
    // get the same per-call rendering, depth-first. The inline_body lands on
    // the continuation's invocation node; emitContinuationBody honors it via the
    // shared emitInlineBodyNode — the SAME path as a top-level flow.
    try renderNestedTemplates(all_items, @constCast(flow.body.continuations), build_lang, allocator);
}

/// Scope is declared at the SPLICE SITE, not the event. When a template splices
/// a handler with `{{ h.inlined_link[scope] }}`, that renders a
/// `__koru_inline_scoped_<idx>` marker into the body. After rendering, scan the
/// body for those markers and stamp `@scope` onto the matching continuations'
/// `binding_annotations`. The obligation checker (`auto_discharge_inserter`)
/// reads `@scope` on a continuation and treats that handler body as a scope
/// boundary — per-iteration resource discharge, outer resources suspended. This
/// is how a template construct declares "this spliced body is a scope" without a
/// dedicated node and without baking scope into the event declaration: the
/// template author picks `inlined_link[scope]` exactly where the boundary is.
const SCOPED_SPLICE_MARKER = "__koru_inline_scoped_";

fn tagScopeFromRenderedBody(
    rendered: []const u8,
    continuations: []ast.Continuation,
    allocator: std.mem.Allocator,
) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, pos, SCOPED_SPLICE_MARKER)) |m| {
        var i = m + SCOPED_SPLICE_MARKER.len;
        var idx: usize = 0;
        var saw_digit = false;
        while (i < rendered.len and rendered[i] >= '0' and rendered[i] <= '9') : (i += 1) {
            idx = idx * 10 + (rendered[i] - '0');
            saw_digit = true;
        }
        if (saw_digit and idx < continuations.len) {
            try stampScope(&continuations[idx], allocator);
        }
        pos = i;
    }
}

/// Idempotently add `@scope` to a continuation's `binding_annotations`.
fn stampScope(cont: *ast.Continuation, allocator: std.mem.Allocator) !void {
    for (cont.binding_annotations) |ann| {
        if (std.mem.eql(u8, ann, "@scope")) return;
    }
    const old = cont.binding_annotations;
    const new_anns = try allocator.alloc([]const u8, old.len + 1);
    @memcpy(new_anns[0..old.len], old);
    new_anns[old.len] = "@scope";
    cont.binding_annotations = new_anns;
}

/// Walk continuations depth-first, rendering any `for`/template invocation found
/// as a continuation's node. This is what makes nested `~for` (`| result r |>
/// for(0..r) ! each … | done …`) lower the same as a top-level `~for`.
fn renderNestedTemplates(
    all_items: []ast.Item,
    continuations: []ast.Continuation,
    build_lang: []const u8,
    allocator: std.mem.Allocator,
) !void {
    for (continuations) |*cont| {
        if (cont.node) |*node| {
            if (node.* == .invocation) {
                if (node.invocation.inline_body == null) {
                    if (try renderTemplateInvocation(all_items, &node.invocation, cont.continuations, .{ .file = "generated", .line = 0, .column = 0 }, build_lang, allocator)) |rendered| {
                        node.invocation.inline_body = rendered;
                        log.debug("[TEMPLATE/per-call] rendered nested '{s}'\n", .{
                            if (node.invocation.path.segments.len > 0) node.invocation.path.segments[0] else "<?>",
                        });
                    }
                }
                // Same splice-driven `@scope` stamping for nested constructs.
                if (node.invocation.inline_body) |body| {
                    try tagScopeFromRenderedBody(body, @constCast(cont.continuations), allocator);
                }
            }
        }
        try renderNestedTemplates(all_items, @constCast(cont.continuations), build_lang, allocator);
    }
}

/// Find the event declaration whose path's last segment matches the
/// invocation's last segment (top-level + nested modules). Used to bind
/// positional invocation args to the event's field names.
fn findEventDeclByLastSegment(items: []ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
    if (path.segments.len == 0) return null;
    const target = path.segments[path.segments.len - 1];
    for (items) |*item| {
        switch (item.*) {
            .event_decl => |*ed| {
                if (ed.path.segments.len == 0) continue;
                if (std.mem.eql(u8, ed.path.segments[ed.path.segments.len - 1], target)) return ed;
            },
            .module_decl => |*md| {
                if (findEventDeclByLastSegment(@constCast(md.items), path)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

/// The build-language variant of a bare `|template|<lang>` proc, e.g. `zig`
/// for `for|template|zig` or `js` for `for|template|js`. Returns null if the
/// proc is not a bare per-call template (no `template` tag, OR `template(once)`
/// per-decl, OR a `template|` with no trailing lang segment).
fn perCallTemplateLang(proc: *const ast.ProcDecl) ?[]const u8 {
    const target = proc.target orelse return null;
    const first_sep = firstTagEnd(target);
    const parts = parseTag(target[0..first_sep]);
    if (!std.mem.eql(u8, parts.name, TEMPLATE_TAG)) return null;
    if (parts.args.len != 0) return null; // `template(once)` is per-decl, not per-call.
    if (first_sep >= target.len) return null; // bare `template` with no lang segment.
    // Lang is the segment immediately after `template|`, up to the next `|`.
    const rest = target[first_sep + 1 ..];
    const lang_end = firstTagEnd(rest);
    const lang = parseTag(rest[0..lang_end]).name;
    if (lang.len == 0) return null;
    return lang;
}

/// Surface a missing-target-variant as a fantastic, located Koru diagnostic
/// (KORU121), then fail the compile. This is the loud failure that replaces the
/// old silent `|zig`-body leak onto a non-Zig target: a per-call template
/// construct (`~for`, `~if`, …) was invoked on a `--lang=<build_lang>` build,
/// but the construct only declares `<event>|template|<other-lang>` variants.
fn emitMissingVariantAndExit(
    location: errors.SourceLocation,
    event_name: []const u8,
    build_lang: []const u8,
) noreturn {
    std.debug.print(
        \\error[{s}]: control-flow construct `~{s}` has no `|template|{s}` variant for the `--lang={s}` build
        \\  --> {s}:{d}:{d}
        \\  `~{s}` is a per-call template: its body is spliced inline at the call
        \\  site BEFORE the emitter picks a target, so the variant must be chosen
        \\  here, by build language. This build is `{s}`, but `{s}|template|{s}`
        \\  is not declared.
        \\  fix: add `~proc {s}|template|{s} {{ ... }}` next to the existing
        \\  variants in the construct's source (e.g. koru_std/control.kz), emitting
        \\  a {s}-native body.
        \\
    , .{
        @tagName(errors.ErrorCode.KORU121),
        event_name,
        build_lang,
        build_lang,
        location.file,
        location.line,
        location.column,
        event_name,
        build_lang,
        event_name,
        build_lang,
        event_name,
        build_lang,
        build_lang,
    });
    std.process.exit(1);
}

/// Select the per-call template proc for an invocation, keyed on build language.
///
/// Per-call template selection happens UPSTREAM of the emitter's variant pick,
/// so it must be target-aware HERE — STRICT, with no cross-lang fallback. Walk
/// every proc whose path last-segment matches the invocation's, classify each
/// via `perCallTemplateLang`:
///   - If NONE are per-call templates → return null (ordinary invocation; the
///     caller leaves it untouched).
///   - If a per-call template variant matches `build_lang` exactly → return it.
///   - If per-call template variants exist but NONE match `build_lang` → loud
///     KORU121 (never fall back to `|zig` on a JS build).
fn selectPerCallTemplateProc(
    items: []ast.Item,
    path: *const ast.DottedPath,
    build_lang: []const u8,
    location: errors.SourceLocation,
) ?*ast.ProcDecl {
    if (path.segments.len == 0) return null;
    const target_name = path.segments[path.segments.len - 1];

    const Walker = struct {
        fn search(
            its: []ast.Item,
            name: []const u8,
            blang: []const u8,
            saw_any_template: *bool,
        ) ?*ast.ProcDecl {
            for (its) |*item| {
                switch (item.*) {
                    .proc_decl => |*pd| {
                        if (pd.path.segments.len == 0) continue;
                        const pd_name = pd.path.segments[pd.path.segments.len - 1];
                        if (!std.mem.eql(u8, pd_name, name)) continue;
                        const lang = perCallTemplateLang(pd) orelse continue;
                        saw_any_template.* = true;
                        if (std.mem.eql(u8, lang, blang)) return pd;
                    },
                    .module_decl => |*md| {
                        if (search(@constCast(md.items), name, blang, saw_any_template)) |found| return found;
                    },
                    else => {},
                }
            }
            return null;
        }
    };

    var saw_any_template = false;
    if (Walker.search(items, target_name, build_lang, &saw_any_template)) |pd| return pd;

    // A per-call template construct exists for this event name, but no variant
    // matches the build language — fail loudly rather than leak a wrong-target
    // body. (If `saw_any_template` is false, this wasn't a template invocation
    // at all; leave it for normal handling.)
    if (saw_any_template) {
        emitMissingVariantAndExit(location, target_name, build_lang);
    }
    return null;
}

/// Find the end of the first tag in a variant chain, respecting `(...)`
/// argument groups. For `template(once)|zig`, returns index of the `|`
/// between `)` and `zig`. For `template|zig`, returns index of the first `|`.
fn firstTagEnd(target: []const u8) usize {
    var i: usize = 0;
    var paren_depth: usize = 0;
    while (i < target.len) : (i += 1) {
        const c = target[i];
        if (c == '(') paren_depth += 1
        else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '|' and paren_depth == 0) {
            return i;
        }
    }
    return target.len;
}

/// Split `template(once)` into base name `template` and args `once` (or
/// empty if no args). Returns null base if the tag isn't a valid form.
const TagParts = struct {
    name: []const u8,
    args: []const u8, // empty if no `(...)` group
};

fn parseTag(tag: []const u8) TagParts {
    if (std.mem.indexOfScalar(u8, tag, '(')) |open| {
        // Expect closing paren at end.
        if (tag.len > 0 and tag[tag.len - 1] == ')') {
            return .{ .name = tag[0..open], .args = tag[open + 1 .. tag.len - 1] };
        }
    }
    return .{ .name = tag, .args = "" };
}

fn processProc(pd: *ast.ProcDecl, allocator: std.mem.Allocator) !void {
    const target = pd.target orelse return;

    const first_sep = firstTagEnd(target);
    const first_tag = target[0..first_sep];
    const parts = parseTag(first_tag);

    if (!std.mem.eql(u8, parts.name, TEMPLATE_TAG)) return;

    // Bare `template` (no args) = per-call mode. Handled by
    // processPerCallInvocations later; skip here.
    if (parts.args.len == 0) return;

    if (!std.mem.eql(u8, parts.args, ONCE_MODE)) {
        std.debug.panic(
            "Unknown template mode '({s})' on proc '{s}'. " ++
                "Supported: |template(once)|...",
            .{ parts.args, first_tag },
        );
    }

    // Build Liquid context. First-cut data: the proc's PATH segments are
    // available as `{{ proc_name }}`. Future extensions: input field names
    // (from the matching event_decl), types, annotation flags, comptime
    // values from the call site.
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    var proc_name_buf: [256]u8 = undefined;
    var name_len: usize = 0;
    for (pd.path.segments, 0..) |seg, i| {
        if (i > 0 and name_len < proc_name_buf.len) {
            proc_name_buf[name_len] = '.';
            name_len += 1;
        }
        const remaining = proc_name_buf.len -| name_len;
        const copy_len = @min(seg.len, remaining);
        @memcpy(proc_name_buf[name_len .. name_len + copy_len], seg[0..copy_len]);
        name_len += copy_len;
    }
    const proc_name = try allocator.dupe(u8, proc_name_buf[0..name_len]);
    // Leak — context only outlives the render call.
    try ctx.put("proc_name", .{ .string = proc_name });

    var comp_err: ?[]const u8 = null;
    const rendered = liquid.renderCollectCompError(allocator, pd.body.text, &ctx, &comp_err) catch |err| {
        if (err == error.CompError) {
            emitCompErrorAndExit(pd.location, comp_err orelse "template comp error");
        }
        return err;
    };

    // Replace body text with rendered output, preserving the Source's
    // location/scope/phantom_type provenance. NOTE: do NOT free the old slice —
    // the backend's AST lives in program_ast.zig as a static const value
    // and isn't allocator-owned. Leak is acceptable here (one-shot compile).
    pd.body.text = rendered;

    // Strip the `template|` prefix from the variant chain. Same ownership
    // caveat — don't free the old target slice.
    if (first_sep == target.len) {
        pd.target = null;
    } else {
        const remaining = target[first_sep + 1 ..];
        const new_target = try allocator.dupe(u8, remaining);
        pd.target = new_target;
    }

    log.debug("[TEMPLATE] processed proc body, new target: {s}\n", .{
        if (pd.target) |t| t else "<none>",
    });
}

test "parse_fields: splits brace-optional, comma/newline-separated field lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Case = struct { in: []const u8, names: []const []const u8, vals: []const []const u8, types: []const []const u8 };
    const cases = [_]Case{
        // Comma-separated; values returned VERBATIM (string literal keeps its quotes), no type annotation.
        .{ .in = "name: \"Claude\", count: 42", .names = &.{ "name", "count" }, .vals = &.{ "\"Claude\"", "42" }, .types = &.{ "", "" } },
        // Newline-separated — the canonical `const { … }` block shape.
        .{ .in = "name: \"Claude\"\n    count: 42\n", .names = &.{ "name", "count" }, .vals = &.{ "\"Claude\"", "42" }, .types = &.{ "", "" } },
        // Wrapping braces are accepted and stripped.
        .{ .in = "{ a: 1, b: 2 }", .names = &.{ "a", "b" }, .vals = &.{ "1", "2" }, .types = &.{ "", "" } },
        // A nested struct value's inner comma is NOT a field separator.
        .{ .in = "pt: Point{ x: 1, y: 2 }, n: 3", .names = &.{ "pt", "n" }, .vals = &.{ "Point{ x: 1, y: 2 }", "3" }, .types = &.{ "", "" } },
        // A comma inside a string literal is NOT a field separator.
        .{ .in = "s: \"a, b\"", .names = &.{"s"}, .vals = &.{"\"a, b\""}, .types = &.{""} },
        // Optional `[base_type]` annotation is peeled: value/type split per field.
        .{ .in = "x: 10[i32], y: 20", .names = &.{ "x", "y" }, .vals = &.{ "10", "20" }, .types = &.{ "i32", "" } },
        .{ .in = "ratio: 3.14[f64], flag: true[bool]", .names = &.{ "ratio", "flag" }, .vals = &.{ "3.14", "true" }, .types = &.{ "f64", "bool" } },
        // A leading-`[` array literal is NOT a type annotation (no value before `[`).
        .{ .in = "arr: [1, 2, 3]", .names = &.{"arr"}, .vals = &.{"[1, 2, 3]"}, .types = &.{""} },
        // A non-base-type trailing `[…]` is left in the value.
        .{ .in = "got: thing[99]", .names = &.{"got"}, .vals = &.{"thing[99]"}, .types = &.{""} },
    };

    for (cases) |c| {
        const v = try parseFieldsFilter(a, &.{.{ .string = c.in }});
        try std.testing.expect(v == .array);
        try std.testing.expectEqual(c.names.len, v.array.len);
        for (v.array, 0..) |node, i| {
            try std.testing.expectEqualStrings(c.names[i], node.get("name").?.string);
            try std.testing.expectEqualStrings(c.vals[i], node.get("value").?.string);
            try std.testing.expectEqualStrings(c.types[i], node.get("type").?.string);
        }
    }
}

test "parse_fields: empty / malformed inputs yield an empty field list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "   ", "{}", "{ }" }) |s| {
        const v = try parseFieldsFilter(a, &.{.{ .string = s }});
        try std.testing.expect(v == .array);
        try std.testing.expectEqual(@as(usize, 0), v.array.len);
    }
}
