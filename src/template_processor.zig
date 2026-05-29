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

/// Walk the AST and process every proc whose variant chain begins with
/// `template(once)|...`. Mutates ProcDecl.body and ProcDecl.target in place.
/// Also runs the per-call template pass for bare `|template|...` procs:
/// each invocation site gets its template body rendered with that call's
/// captured args, the result stored on the flow's `inline_body` so the
/// emitter inlines it instead of calling a handler.
pub fn processTemplateProcs(
    program: *const ast.Program,
    allocator: std.mem.Allocator,
) !void {
    const items = @constCast(program.items);
    try processItems(items, allocator);
    try processPerCallInvocations(items, items, allocator);
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
    allocator: std.mem.Allocator,
) !void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| try maybeRenderPerCall(all_items, flow, allocator),
            .module_decl => |*md| try processPerCallInvocations(all_items, @constCast(md.items), allocator),
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
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const proc = findMatchingProc(all_items, &invocation.path) orelse return null;
    const target = proc.target orelse return null;
    const first_sep = firstTagEnd(target);
    const parts = parseTag(target[0..first_sep]);

    if (!std.mem.eql(u8, parts.name, TEMPLATE_TAG)) return null;
    if (parts.args.len != 0) return null; // Skip `template(once)` etc.; only bare `template` is per-call.

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

    // Expose the invoking continuations as `continuations["<branch>"]` → an
    // array of handler sub-contexts { link, binding, guard, kind }. Presence
    // doubles as truthiness. See the template-engine cluster (250_*) for the
    // surface templates program against.
    {
        var by_branch = std.StringHashMap(std.ArrayList(*liquid.Context)).init(allocator);
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

            const gop = try by_branch.getOrPut(cont.branch);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, sub);
        }

        var it = by_branch.iterator();
        while (it.next()) |entry| {
            const arr = try allocator.alloc(*liquid.Context, entry.value_ptr.items.len);
            @memcpy(arr, entry.value_ptr.items);
            const key = try std.fmt.allocPrint(allocator, "continuations[\"{s}\"]", .{entry.key_ptr.*});
            try ctx.put(key, .{ .array = arr });
        }
    }

    var comp_err: ?[]const u8 = null;
    const rendered = liquid.renderCollectCompError(allocator, proc.body, &ctx, &comp_err) catch |err| {
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
    allocator: std.mem.Allocator,
) !void {
    if (flow.inline_body == null) {
        if (try renderTemplateInvocation(all_items, &flow.invocation, flow.continuations, flow.location, allocator)) |rendered| {
            flow.inline_body = rendered;
            log.debug("[TEMPLATE/per-call] rendered '{s}' at top-level call site\n", .{
                if (flow.invocation.path.segments.len > 0) flow.invocation.path.segments[0] else "<?>",
            });
        }
    }

    // Nested template invocations (e.g. `~for` inside a pipeline continuation)
    // get the same per-call rendering, depth-first. The inline_body lands on
    // the continuation's invocation node; emitContinuationBody honors it via the
    // shared emitInlineBodyNode — the SAME path as a top-level flow.
    try renderNestedTemplates(all_items, @constCast(flow.continuations), allocator);
}

/// Walk continuations depth-first, rendering any `for`/template invocation found
/// as a continuation's node. This is what makes nested `~for` (`| result r |>
/// for(0..r) ! each … | done …`) lower the same as a top-level `~for`.
fn renderNestedTemplates(
    all_items: []ast.Item,
    continuations: []ast.Continuation,
    allocator: std.mem.Allocator,
) !void {
    for (continuations) |*cont| {
        if (cont.node) |*node| {
            if (node.* == .invocation and node.invocation.inline_body == null) {
                if (try renderTemplateInvocation(all_items, &node.invocation, cont.continuations, .{ .file = "generated", .line = 0, .column = 0 }, allocator)) |rendered| {
                    node.invocation.inline_body = rendered;
                    log.debug("[TEMPLATE/per-call] rendered nested '{s}'\n", .{
                        if (node.invocation.path.segments.len > 0) node.invocation.path.segments[0] else "<?>",
                    });
                }
            }
        }
        try renderNestedTemplates(all_items, @constCast(cont.continuations), allocator);
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

/// Resolve a flow's invocation path to its target ProcDecl. Searches the
/// whole program (top-level + module_decl recursively). Returns the first
/// proc whose path's last segment matches the invocation's last segment
/// — sufficient for first-cut single-module test programs.
fn findMatchingProc(items: []ast.Item, path: *const ast.DottedPath) ?*ast.ProcDecl {
    if (path.segments.len == 0) return null;
    const target_name = path.segments[path.segments.len - 1];
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*pd| {
                if (pd.path.segments.len == 0) continue;
                const pd_name = pd.path.segments[pd.path.segments.len - 1];
                if (std.mem.eql(u8, pd_name, target_name)) return pd;
            },
            .module_decl => |*md| {
                if (findMatchingProc(@constCast(md.items), path)) |found| return found;
            },
            else => {},
        }
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
    const rendered = liquid.renderCollectCompError(allocator, pd.body, &ctx, &comp_err) catch |err| {
        if (err == error.CompError) {
            emitCompErrorAndExit(pd.location, comp_err orelse "template comp error");
        }
        return err;
    };

    // Replace body with rendered output. NOTE: do NOT free the old slice —
    // the backend's AST lives in program_ast.zig as a static const value
    // and isn't allocator-owned. Leak is acceptable here (one-shot compile).
    pd.body = rendered;

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
