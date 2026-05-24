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

const TEMPLATE_TAG = "template";
const ONCE_MODE = "once";

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

fn maybeRenderPerCall(
    all_items: []ast.Item,
    flow: *ast.Flow,
    allocator: std.mem.Allocator,
) !void {
    if (flow.inline_body != null) return; // Already has inline_body, skip.

    const proc = findMatchingProc(all_items, &flow.invocation.path) orelse return;
    const target = proc.target orelse return;
    const first_sep = firstTagEnd(target);
    const parts = parseTag(target[0..first_sep]);

    if (!std.mem.eql(u8, parts.name, TEMPLATE_TAG)) return;
    if (parts.args.len != 0) return; // Skip `template(once)` etc.; only bare `template` is per-call.

    // Build context from invocation args. Each captured Expression text is
    // exposed as `{{ argname.text }}` (mirrors `[expand]` arg handling).
    // For first cut, also expose the captured text directly as `{{ argname }}`.
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    for (flow.invocation.args) |arg| {
        if (arg.expression_value) |expr_val| {
            try ctx.put(arg.name, .{ .string = expr_val.text });
        } else {
            // Fallback: arg has no captured Expression — use the raw value.
            try ctx.put(arg.name, .{ .string = arg.value });
        }
    }

    const rendered = try liquid.render(allocator, proc.body, &ctx);

    // Prepend the `inline_stmt` marker so the emitter knows the rendered
    // body is statement-shaped (no trailing `;` needed). Matches the
    // convention used by `print.blk` / other statement-producing transforms.
    const inline_marker = "//@koru:inline_stmt\n";
    const with_marker = try std.fmt.allocPrint(allocator, "{s}{s}", .{ inline_marker, rendered });
    flow.inline_body = with_marker;

    // The proc's handler will still be emitted by the normal emit pass,
    // but no one calls it (every invocation is inlined). Blank the body
    // so the dead handler is valid Zig — the un-rendered template text
    // contains `{{ }}` tokens that aren't Zig. The blanked body is a
    // no-op return; for non-void events this is still a problem, but
    // per-call templates are expected to be void-shaped (they're macros
    // emitting statements, not value-producing functions).
    proc.body = "";

    log.debug("[TEMPLATE/per-call] rendered '{s}' at call site\n", .{
        if (flow.invocation.path.segments.len > 0) flow.invocation.path.segments[0] else "<?>",
    });
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

    const rendered = try liquid.render(allocator, pd.body, &ctx);

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
