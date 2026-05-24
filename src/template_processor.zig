// Template processor pass.
//
// Rewrites procs whose variant chain starts with `template`: the body is
// rendered through the Liquid engine with the proc's input fields available
// as template context, then the `template` tag is removed from the variant
// chain. Downstream passes see a plain `~proc foo|zig { ... }` (or whatever
// the next variant tag was).
//
// This implements the `host[:processor]` / pipe-variant story documented in
// memory: variants form an ordered pipeline, each processor removes its own
// tag when it's done, the remaining tags drive downstream emission.

const std = @import("std");
const ast = @import("ast");
const liquid = @import("liquid");
const log = @import("log");

const TEMPLATE_TAG = "template";

/// Walk the AST and process every proc whose variant chain begins with
/// `template|...`. Mutates ProcDecl.body and ProcDecl.target in place.
pub fn processTemplateProcs(
    program: *const ast.Program,
    allocator: std.mem.Allocator,
) !void {
    try processItems(@constCast(program.items), allocator);
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

fn processProc(pd: *ast.ProcDecl, allocator: std.mem.Allocator) !void {
    const target = pd.target orelse return;

    // Match `template` as the FIRST tag in the chain — everything between
    // start and the first `|` (or end of string).
    const first_sep = std.mem.indexOfScalar(u8, target, '|') orelse target.len;
    const first_tag = target[0..first_sep];
    if (!std.mem.eql(u8, first_tag, TEMPLATE_TAG)) return;

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
