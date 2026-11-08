const std = @import("std");
const ast = @import("ast");

// Define explicit error set to avoid circular inference
const CloneError = error{
    OutOfMemory,
};

/// Functional AST Manipulation
///
/// This module provides purely functional operations for AST transformation.
/// All operations are immutable - they create new AST nodes rather than mutating existing ones.
/// This enables:
/// - Safe multi-pass compilation
/// - Transformation composition
/// - Source features
/// - Undo/redo capabilities
///
/// Core principle: AST in → AST out, no side effects
/// Result type for transformations that might fail
pub const TransformResult = union(enum) {
    ok: ast.Program,
    err: TransformError,
};

pub const TransformError = struct {
    message: []const u8,
    location: ?SourceLocation = null,
};

pub const SourceLocation = struct {
    line: usize,
    column: usize,
    file: []const u8,
};

/// Deinit the first `count` slots of a partially-filled item array, then
/// free the backing storage — the errdefer half of alloc-then-fill.
fn deinitItemsPrefix(allocator: std.mem.Allocator, items: []ast.Item, count: usize) void {
    for (items[0..], 0..) |*item, i| {
        if (i >= count) break;
        item.deinit(allocator);
    }
    allocator.free(items);
}

/// Free a slice of duplicated strings, then the slice itself.
fn freeDupedStrings(allocator: std.mem.Allocator, strings: [][]const u8) void {
    for (strings) |s| allocator.free(s);
    allocator.free(strings);
}

/// Reassemble a Program around rebuilt items/annotations — the main name
/// is re-duped and the allocator carried, but type_registry is dropped:
/// cloned Programs don't inherit the registry; transforms rebuild it.
fn rebuildProgram(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    items: []const ast.Item,
    module_annotations: []const []const u8,
) !ast.Program {
    return .{
        .items = items,
        .module_annotations = module_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
}

/// Map a transformation function over all items in a Program
/// Returns a new Program with transformed items
pub fn mapItems(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    transform_fn: fn (allocator: std.mem.Allocator, item: *const ast.Item) anyerror!ast.Item,
) !ast.Program {
    var new_items = try allocator.alloc(ast.Item, source.items.len);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len);

    for (source.items, 0..) |*item, i| {
        new_items[i] = try transform_fn(allocator, item);
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// Filter items based on a predicate
/// Returns a new Program containing only items that match the predicate
pub fn filterItems(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    predicate: fn (item: *const ast.Item) bool,
) !ast.Program {
    var filtered = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer filtered.deinit(allocator);

    for (source.items) |*item| {
        if (predicate(item)) {
            // Deep copy the item that matches
            const copied = try cloneItem(allocator, item);
            try filtered.append(allocator, copied);
        }
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, try filtered.toOwnedSlice(allocator), new_annotations);
}

/// Fold over the AST, accumulating a result
pub fn foldAST(
    comptime T: type,
    source: *const ast.Program,
    initial: T,
    folder: fn (acc: T, item: *const ast.Item) T,
) T {
    var result = initial;
    for (source.items) |*item| {
        result = folder(result, item);
    }
    return result;
}

/// Replace an item at a specific index with a new item
/// Returns a new Program with the replacement
pub fn replaceAt(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    index: usize,
    new_item: ast.Item,
) !ast.Program {
    if (index >= source.items.len) return error.IndexOutOfBounds;

    var new_items = try allocator.alloc(ast.Item, source.items.len);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len);

    // Copy all items, replacing at the specified index
    for (source.items, 0..) |*item, i| {
        if (i == index) {
            new_items[i] = new_item;
        } else {
            new_items[i] = try cloneItem(allocator, item);
        }
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// Replace an item anywhere in the tree by matching on the target flow pointer
/// Recursively searches into module_decl items
/// Returns a new Program with the replacement, or null if target not found
pub fn replaceFlowRecursive(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    target_flow: *const ast.Flow,
    new_item: ast.Item,
) !?ast.Program {
    // Try to replace in items, recursively searching module_decls
    const result = try replaceFlowInItems(allocator, source.items, target_flow, new_item);
    if (result.found) {
        return try programWithItems(allocator, source, result.items);
    }

    // Fallback: replace invocation inside continuations (nested transforms)
    if (new_item == .flow) {
        const replace_result = try replaceInvocationInItems(allocator, source.items, target_flow.inv(), &new_item.flow);
        if (replace_result.found) {
            return try programWithItems(allocator, source, replace_result.items);
        }
    }
    return null;
}

pub fn replaceInvocationNodeRecursive(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    target_invocation: *const ast.Invocation,
    new_node: ast.Node,
) !?ast.Program {
    const result = try replaceInvocationNodeInItems(allocator, source.items, target_invocation, new_node);
    if (result.found) {
        return try programWithItems(allocator, source, result.items);
    }
    return null;
}

pub fn replaceInvocationNodeAndContinuationsRecursive(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    target_invocation: *const ast.Invocation,
    new_node: ast.Node,
    new_continuations: []const ast.Continuation,
    mark_transformed: bool,
) !?ast.Program {
    const result = try replaceInvocationNodeAndContinuationsInItems(
        allocator,
        source.items,
        target_invocation,
        new_node,
        new_continuations,
        mark_transformed,
    );
    if (result.found) {
        return try programWithItems(allocator, source, result.items);
    }
    return null;
}

const ReplaceResult = struct {
    found: bool,
    items: []ast.Item,
};

const ReplaceContResult = struct {
    found: bool,
    conts: []ast.Continuation,
};

/// Rebuild a Program around a replaced items slice: everything else carries
/// over cloned, unchanged items keep sharing nodes per the contract above.
fn programWithItems(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    items: []ast.Item,
) !ast.Program {
    return rebuildProgram(allocator, source, items, try cloneStringSlice(allocator, source.module_annotations));
}

/// Rebuild a ModuleDecl around a replaced items slice — the module_decl arm
/// every items-walker below spells identically.
fn cloneModuleDeclWithItems(
    allocator: std.mem.Allocator,
    mod: *const ast.ModuleDecl,
    items: []ast.Item,
) !ast.ModuleDecl {
    return ast.ModuleDecl{
        .logical_name = try allocator.dupe(u8, mod.logical_name),
        .canonical_path = try allocator.dupe(u8, mod.canonical_path),
        .items = items,
        .is_system = mod.is_system,
        .annotations = try cloneStringSlice(allocator, mod.annotations),
        .location = mod.location,
    };
}

/// The items-walk skeleton shared by every `replace*InItems` walker:
/// module_decls recurse, every other item goes through `map_item` (null =
/// share unchanged), and a mapped item flips `found`.
fn mapItemsRecursive(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    ctx: anytype,
    map_item: anytype,
) !ReplaceResult {
    var new_items = try allocator.alloc(ast.Item, items.len);
    var found = false;

    for (items, 0..) |*item, i| {
        if (item.* == .module_decl) {
            const mod = &item.module_decl;
            const sub_result = try mapItemsRecursive(allocator, mod.items, ctx, map_item);
            if (sub_result.found) {
                new_items[i] = ast.Item{ .module_decl = try cloneModuleDeclWithItems(allocator, mod, sub_result.items) };
                found = true;
            } else {
                new_items[i] = item.*;
            }
        } else if (try map_item(allocator, ctx, item)) |mapped| {
            new_items[i] = mapped;
            found = true;
        } else {
            new_items[i] = item.*;
        }
    }

    return ReplaceResult{ .found = found, .items = new_items };
}

/// Write-back rebuilds share UNCHANGED items by value. The new items array is
/// fresh, but an item the rebuild did not touch is copied as a bare struct and
/// keeps pointing at the same underlying nodes as the abandoned program. This
/// is the O(change) rebuild contract: deep-cloning every unchanged item per
/// write-back was O(program) per transformed site and is what made even a
/// 10-line store program pay ~2.6 GB (the 003_ecs SIGKILL path, via
/// AutoDischargeInserter's per-flow rebuilds). Sharing is safe here because
/// the site runner re-derives site refs from the CURRENT program on every walk
/// and abandons the previous program after each splice; it already
/// shallow-copies items when building site programs (transform_pass_runner.zig
/// spliceSiteProgram); and the metacircular pipeline already accepts in-place
/// mutation of the writable seed (compiler.kz context-create). A caller that
/// needs EXCLUSIVE ownership of unchanged items must deep-clone them itself.
const ReplaceFlowCtx = struct {
    target_flow: *const ast.Flow,
    new_item: ast.Item,
};

fn mapReplaceFlowItem(allocator: std.mem.Allocator, ctx: ReplaceFlowCtx, item: *const ast.Item) !?ast.Item {
    _ = allocator;
    if (item.* == .flow and @intFromPtr(&item.flow) == @intFromPtr(ctx.target_flow)) {
        return ctx.new_item;
    }
    return null;
}

fn replaceFlowInItems(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    target_flow: *const ast.Flow,
    new_item: ast.Item,
) !ReplaceResult {
    return mapItemsRecursive(allocator, items, ReplaceFlowCtx{ .target_flow = target_flow, .new_item = new_item }, mapReplaceFlowItem);
}

const ReplaceNodeCtx = struct {
    target: *const ast.Invocation,
    new_node: ast.Node,
};

fn mapReplaceNodeItem(allocator: std.mem.Allocator, ctx: ReplaceNodeCtx, item: *const ast.Item) !?ast.Item {
    if (item.* != .flow) return null;
    const flow = &item.flow;
    const cont_result = try replaceInvocationNodeInContinuations(allocator, flow.body.continuations, ctx.target, ctx.new_node);
    if (!cont_result.found) return null;
    return ast.Item{ .flow = try cloneFlowWithContinuations(allocator, flow, cont_result.conts) };
}

fn replaceInvocationNodeInItems(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    target_invocation: *const ast.Invocation,
    new_node: ast.Node,
) !ReplaceResult {
    return mapItemsRecursive(allocator, items, ReplaceNodeCtx{ .target = target_invocation, .new_node = new_node }, mapReplaceNodeItem);
}

const ReplaceNodeContsCtx = struct {
    target: *const ast.Invocation,
    new_node: ast.Node,
    new_continuations: []const ast.Continuation,
    mark_transformed: bool,
};

fn mapReplaceNodeContsItem(allocator: std.mem.Allocator, ctx: ReplaceNodeContsCtx, item: *const ast.Item) !?ast.Item {
    if (item.* != .flow) return null;
    const flow = &item.flow;
    // The flow HEAD itself can be the target: a branch-arm
    // transform retargeting its producer (NodeReplacement's
    // `retarget_producer`) points at `flow.body.node.invocation`,
    // which the continuation walk below never reaches.
    // `label_with_invocation` lifts to `pre_label` — the parser's
    // own spelling of `#label` at flow-root position — so the
    // emitter sees one canonical fold shape.
    const head_is_target = if (flow.body.node) |*bnode|
        bnode.* == .invocation and &bnode.invocation == ctx.target
    else
        false;
    if (head_is_target) {
        var new_flow = try cloneFlowWithContinuations(
            allocator,
            flow,
            try cloneContinuationSlice(allocator, ctx.new_continuations),
        );
        if (ctx.new_node == .label_with_invocation) {
            const lwi = ctx.new_node.label_with_invocation;
            new_flow.pre_label = try allocator.dupe(u8, lwi.label);
            new_flow.body.node = ast.Node{ .invocation = lwi.invocation };
        } else {
            new_flow.body.node = ctx.new_node;
        }
        return ast.Item{ .flow = new_flow };
    }
    const cont_result = try replaceInvocationNodeAndContinuationsInContinuations(
        allocator,
        flow.body.continuations,
        ctx.target,
        ctx.new_node,
        ctx.new_continuations,
        ctx.mark_transformed,
    );
    if (!cont_result.found) return null;
    return ast.Item{ .flow = try cloneFlowWithContinuations(allocator, flow, cont_result.conts) };
}

fn replaceInvocationNodeAndContinuationsInItems(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    target_invocation: *const ast.Invocation,
    new_node: ast.Node,
    new_continuations: []const ast.Continuation,
    mark_transformed: bool,
) !ReplaceResult {
    return mapItemsRecursive(allocator, items, ReplaceNodeContsCtx{
        .target = target_invocation,
        .new_node = new_node,
        .new_continuations = new_continuations,
        .mark_transformed = mark_transformed,
    }, mapReplaceNodeContsItem);
}

fn replaceInvocationNodeInContinuations(
    allocator: std.mem.Allocator,
    conts: []const ast.Continuation,
    target_invocation: *const ast.Invocation,
    new_node: ast.Node,
) !ReplaceContResult {
    var new_conts = try allocator.alloc(ast.Continuation, conts.len);
    var found = false;

    for (conts, 0..) |*cont, i| {
        var replaced = false;
        if (cont.node) |*step| {
            if (step.* == .invocation) {
                if (&step.invocation == target_invocation) {
                    new_conts[i] = try cloneContinuationWithReplacedNode(allocator, cont, new_node);
                    found = true;
                    replaced = true;
                }
            }
        }

        if (!replaced) {
            if (cont.continuations.len > 0) {
                const sub = try replaceInvocationNodeInContinuations(allocator, cont.continuations, target_invocation, new_node);
                if (sub.found) {
                    new_conts[i] = try cloneContinuationWithReplacedNested(allocator, cont, sub.conts);
                    found = true;
                    continue;
                }
            }
            new_conts[i] = try cloneContinuation(allocator, cont);
        }
    }

    return ReplaceContResult{ .found = found, .conts = new_conts };
}

fn replaceInvocationNodeAndContinuationsInContinuations(
    allocator: std.mem.Allocator,
    conts: []const ast.Continuation,
    target_invocation: *const ast.Invocation,
    new_node: ast.Node,
    new_continuations: []const ast.Continuation,
    mark_transformed: bool,
) !ReplaceContResult {
    var new_conts = try allocator.alloc(ast.Continuation, conts.len);
    var found = false;

    for (conts, 0..) |*cont, i| {
        var replaced = false;
        if (cont.node) |*step| {
            if (step.* == .invocation) {
                if (&step.invocation == target_invocation) {
                    const cloned_conts = try cloneContinuationSlice(allocator, new_continuations);
                    new_conts[i] = try cloneContinuationWithNodeAndContinuations(
                        allocator,
                        cont,
                        new_node,
                        cloned_conts,
                        mark_transformed,
                    );
                    found = true;
                    replaced = true;
                }
            }
        }

        if (!replaced) {
            if (cont.continuations.len > 0) {
                const sub = try replaceInvocationNodeAndContinuationsInContinuations(
                    allocator,
                    cont.continuations,
                    target_invocation,
                    new_node,
                    new_continuations,
                    mark_transformed,
                );
                if (sub.found) {
                    new_conts[i] = try cloneContinuationWithReplacedNested(allocator, cont, sub.conts);
                    found = true;
                    continue;
                }
            }
            new_conts[i] = try cloneContinuation(allocator, cont);
        }
    }

    return ReplaceContResult{ .found = found, .conts = new_conts };
}

const ReplaceInvCtx = struct {
    target: *const ast.Invocation,
    new_flow: *const ast.Flow,
};

fn mapReplaceInvItem(allocator: std.mem.Allocator, ctx: ReplaceInvCtx, item: *const ast.Item) !?ast.Item {
    if (item.* != .flow) return null;
    const flow = &item.flow;
    const cont_result = try replaceInvocationInContinuations(allocator, flow.body.continuations, ctx.target, ctx.new_flow);
    if (!cont_result.found) return null;
    return ast.Item{ .flow = try cloneFlowWithContinuations(allocator, flow, cont_result.conts) };
}

fn replaceInvocationInItems(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    target_invocation: *const ast.Invocation,
    new_flow: *const ast.Flow,
) !ReplaceResult {
    return mapItemsRecursive(allocator, items, ReplaceInvCtx{ .target = target_invocation, .new_flow = new_flow }, mapReplaceInvItem);
}

fn replaceInvocationInContinuations(
    allocator: std.mem.Allocator,
    conts: []const ast.Continuation,
    target_invocation: *const ast.Invocation,
    new_flow: *const ast.Flow,
) !ReplaceContResult {
    if (!continuationsContainInvocation(conts, target_invocation)) {
        return ReplaceContResult{ .found = false, .conts = &[_]ast.Continuation{} };
    }

    var new_conts = try allocator.alloc(ast.Continuation, conts.len);
    var found = false;

    for (conts, 0..) |*cont, i| {
        var replaced = false;
        if (cont.node) |*step| {
            if (step.* == .invocation) {
                if (invocationsEqual(&step.invocation, target_invocation)) {
                    new_conts[i] = try cloneContinuationWithReplacedInvocation(allocator, cont, new_flow);
                    found = true;
                    replaced = true;
                }
            }
        }

        if (!replaced) {
            if (cont.continuations.len > 0) {
                const sub = try replaceInvocationInContinuations(allocator, cont.continuations, target_invocation, new_flow);
                if (sub.found) {
                    new_conts[i] = try cloneContinuationWithReplacedNested(allocator, cont, sub.conts);
                    found = true;
                    continue;
                }
            }
            new_conts[i] = try cloneContinuation(allocator, cont);
        }
    }

    return ReplaceContResult{ .found = found, .conts = new_conts };
}

fn cloneContinuationWithReplacedInvocation(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    new_flow: *const ast.Flow,
) CloneError!ast.Continuation {
    if (new_flow.inline_body != null) {
        const empty_conts = try allocator.alloc(ast.Continuation, 0);
        return cloneContinuationWithNodeAndContinuations(
            allocator,
            cont,
            .{ .inline_code = new_flow.inline_body.? },
            empty_conts,
            false,
        );
    }

    var inv = new_flow.inv().*;
    if (new_flow.inline_body != null and inv.inline_body == null) {
        inv.inline_body = new_flow.inline_body;
    }
    const new_node = ast.Node{ .invocation = try cloneInvocation(allocator, &inv) };
    const new_continuations = try cloneContinuationSlice(allocator, new_flow.body.continuations);

    return cloneContinuationWithNodeAndContinuations(allocator, cont, new_node, new_continuations, false);
}

/// The shared clone tail for continuations: every field deep-cloned except
/// `node`, `continuations`, and `is_transformed_subtree`, which the caller
/// supplies (pass `mark_transformed = false` to inherit the original flag).
fn cloneContinuationWithNodeAndContinuations(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    new_node: ?ast.Node,
    new_continuations: []const ast.Continuation,
    mark_transformed: bool,
) CloneError!ast.Continuation {
    var binding_annotations = try allocator.alloc([]const u8, cont.binding_annotations.len);
    errdefer allocator.free(binding_annotations);
    for (cont.binding_annotations, 0..) |ann, i| {
        binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    var binding_marks = try allocator.alloc([]const u8, cont.binding_marks.len);
    errdefer allocator.free(binding_marks);
    for (cont.binding_marks, 0..) |mark, i| {
        binding_marks[i] = try allocator.dupe(u8, mark);
    }

    return .{
        .branch = try allocator.dupe(u8, cont.branch),
        .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
        .destructure = try ast.copyDestructure(allocator, cont.destructure),
        .destructure_named = cont.destructure_named,
        .produce = try ast.copyDestructure(allocator, cont.produce),
        .binding_annotations = binding_annotations,
        .binding_marks = binding_marks,
        .binding_type = cont.binding_type,
        .kind = cont.kind,
        .is_catchall = cont.is_catchall,
        .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
        .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
        .post_condition = if (cont.post_condition) |c| try allocator.dupe(u8, c) else null,
        .condition_expr = cont.condition_expr,
        .node = new_node,
        .indent = cont.indent,
        .continuations = new_continuations,
        // The grafted subtree (capture's `''` void-chain) inherits the transform
        // exemption from the nested holding continuation. Falls back to the
        // original continuation's flag when this isn't a preamble graft.
        .is_transformed_subtree = mark_transformed or cont.is_transformed_subtree,
        .location = cont.location,
    };
}

fn cloneContinuationWithReplacedNode(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    new_node: ast.Node,
) CloneError!ast.Continuation {
    var new_continuations = try allocator.alloc(ast.Continuation, cont.continuations.len);
    errdefer allocator.free(new_continuations);

    for (cont.continuations, 0..) |*n, i| {
        new_continuations[i] = try cloneContinuation(allocator, n);
    }

    return cloneContinuationWithNodeAndContinuations(allocator, cont, new_node, new_continuations, false);
}

fn cloneContinuationWithReplacedNested(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    new_nested: []const ast.Continuation,
) CloneError!ast.Continuation {
    const cloned_step = if (cont.node) |*step| try cloneStep(allocator, step) else null;

    return cloneContinuationWithNodeAndContinuations(allocator, cont, cloned_step, new_nested, false);
}

pub fn cloneContinuationSlice(
    allocator: std.mem.Allocator,
    continuations: []const ast.Continuation,
) CloneError![]ast.Continuation {
    var cloned_conts = try allocator.alloc(ast.Continuation, continuations.len);
    errdefer allocator.free(cloned_conts);
    for (continuations, 0..) |*cont, i| {
        cloned_conts[i] = try cloneContinuation(allocator, cont);
    }
    return cloned_conts;
}

/// The shared clone tail for flows: every field deep-cloned except `body`,
/// which the caller supplies (already-cloned). `super_shape` is dropped on
/// all clone paths — see the TODO below.
fn cloneFlowWithBody(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    new_body: ast.Continuation,
) CloneError!ast.Flow {
    return .{
        .body = new_body,
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .super_shape = null, // TODO: clone super_shape if needed
        .inline_body = if (flow.inline_body) |body| try allocator.dupe(u8, body) else null,
        .preamble_code = if (flow.preamble_code) |preamble| try allocator.dupe(u8, preamble) else null,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .location = flow.location,
        .module = try allocator.dupe(u8, flow.module),
        .annotations = try cloneStringSlice(allocator, flow.annotations),
        .impl_of = if (flow.impl_of) |io| try cloneDottedPath(allocator, &io) else null,
        .impl_variant = if (flow.impl_variant) |v| try allocator.dupe(u8, v) else null,
        .is_impl = flow.is_impl,
    };
}

fn cloneFlowWithContinuations(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    continuations: []const ast.Continuation,
) CloneError!ast.Flow {
    const body = ast.rootSite(try cloneInvocation(allocator, flow.inv()), continuations, flow.location);
    return cloneFlowWithBody(allocator, flow, body);
}

fn invocationsEqual(a: *const ast.Invocation, b: *const ast.Invocation) bool {
    if (!pathsEqual(a.path, b.path)) return false;
    if (a.args.len != b.args.len) return false;
    for (a.args, 0..) |*arg, i| {
        const other = &b.args[i];
        if (!std.mem.eql(u8, arg.name, other.name)) return false;
        if (!std.mem.eql(u8, arg.value, other.value)) return false;
    }
    return true;
}

fn continuationsContainInvocation(
    conts: []const ast.Continuation,
    target_invocation: *const ast.Invocation,
) bool {
    for (conts) |*cont| {
        if (cont.node) |*step| {
            if (step.* == .invocation) {
                if (invocationsEqual(&step.invocation, target_invocation)) {
                    return true;
                }
            }
        }
        if (continuationsContainInvocation(cont.continuations, target_invocation)) {
            return true;
        }
    }
    return false;
}

/// Insert an item at a specific index
/// Returns a new Program with the item inserted
pub fn insertAt(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    index: usize,
    new_item: ast.Item,
) !ast.Program {
    if (index > source.items.len) return error.IndexOutOfBounds;

    var new_items = try allocator.alloc(ast.Item, source.items.len + 1);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len + 1);

    // Copy items before insertion point
    for (source.items[0..index], 0..) |*item, i| {
        new_items[i] = try cloneItem(allocator, item);
    }

    // Insert new item
    new_items[index] = new_item;

    // Copy items after insertion point
    for (source.items[index..], 0..) |*item, i| {
        new_items[index + 1 + i] = try cloneItem(allocator, item);
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// Remove an item at a specific index
/// Returns a new Program without the item
pub fn removeAt(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    index: usize,
) !ast.Program {
    if (index >= source.items.len) return error.IndexOutOfBounds;
    if (source.items.len == 0) return error.EmptySourceFile;

    var new_items = try allocator.alloc(ast.Item, source.items.len - 1);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len - 1);

    // Copy items before removal point
    for (source.items[0..index], 0..) |*item, i| {
        new_items[i] = try cloneItem(allocator, item);
    }

    // Copy items after removal point
    for (source.items[index + 1 ..], 0..) |*item, i| {
        new_items[index + i] = try cloneItem(allocator, item);
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// The logical name of the module_decl containing `flow`, or null when the
/// flow sits at the program's top level. `flow.module` is the FILE-derived
/// name (`lib`); cross-module paths resolve through the import-derived
/// logical name (`app.lib`) — parsed decls carry it, so synthesized paths
/// minted off `flow.module` land in a namespace nothing looks up
/// (115_018/115_045 measured this for store and grid, 115_050–052 for
/// channel, rings, pump and supervisor).
pub fn moduleHome(prog: *const ast.Program, flow: *const ast.Flow) ?[]const u8 {
    const W = struct {
        fn scan(its: []const ast.Item, want: *const ast.Flow, enclosing: ?[]const u8) ?[]const u8 {
            for (its) |*pi| {
                switch (pi.*) {
                    .flow => |*f| {
                        if (f == want) return enclosing;
                    },
                    .module_decl => |*md| {
                        if (scan(md.items, want, md.logical_name)) |hit| return hit;
                    },
                    else => {},
                }
            }
            return null;
        }
    };
    return W.scan(prog.items, flow, null);
}

/// The real flow whose continuation tree holds `target`. A nested transform
/// site arrives as a view — `flow.body` is a copy, `site_of` the real
/// continuation — so the view itself is never found by a tree scan;
/// resolve through the continuation it mirrors.
pub fn containingFlow(prog: *const ast.Program, target: *const ast.Continuation) ?*const ast.Flow {
    const W = struct {
        fn holds(conts: []const ast.Continuation, t: *const ast.Continuation) bool {
            for (conts) |*c| {
                if (c == t) return true;
                if (holds(c.continuations, t)) return true;
            }
            return false;
        }
        fn scan(its: []const ast.Item, t: *const ast.Continuation) ?*const ast.Flow {
            for (its) |*pi| {
                switch (pi.*) {
                    .flow => |*f| {
                        if (&f.body == t or holds(f.body.continuations, t)) return f;
                    },
                    .module_decl => |*md| {
                        if (scan(md.items, t)) |hit| return hit;
                    },
                    else => {},
                }
            }
            return null;
        }
    };
    return W.scan(prog.items, target);
}

/// A proto entry's flat leaf list as record text (`{ f: t, f2: t2 }`), or
/// null when `name` is not a registered compound. Two forms answer: the
/// erased `// proto Name: f: t, ...` marker (post-transform, already merged
/// across `<:` parents) and a live `std/proto(Name)`/`std/types:proto(Name)`
/// declaration flow (pre-transform, raw block — the marker is the merged
/// form and wins when both are present). Callers that need only the leaf
/// types split on top-level commas; the `{`/`}` wrapper makes it a drop-in
/// for record return-type parsers (seedRecordFieldObligations).
pub fn protoRecordText(
    allocator: std.mem.Allocator,
    prog: *const ast.Program,
    name: []const u8,
) !?[]const u8 {
    const W = struct {
        fn isCompoundDoor(inv: *const ast.Invocation) bool {
            if (inv.path.segments.len != 1) return false;
            const verb = inv.path.segments[0];
            const mq = inv.path.module_qualifier orelse return false;
            const types_door = std.mem.eql(u8, verb, "proto") and
                (std.mem.eql(u8, mq, "std.types") or std.mem.eql(u8, mq, "std/types"));
            const default_door = std.mem.eql(u8, verb, "default") and
                (std.mem.eql(u8, mq, "std.proto") or std.mem.eql(u8, mq, "std/proto"));
            return types_door or default_door;
        }

        fn entryName(inv: *const ast.Invocation) []const u8 {
            if (inv.args.len == 0) return "";
            const a0 = inv.args[0];
            var n = if (a0.had_explicit_label) blk: {
                const label = std.mem.trim(u8, a0.name, " \t");
                break :blk if (std.mem.endsWith(u8, label, "<"))
                    std.mem.trim(u8, label[0 .. label.len - 1], " \t")
                else
                    label;
            } else std.mem.trim(u8, a0.value, " \t");
            if (n.len >= 2 and n[0] == '"' and n[n.len - 1] == '"') n = n[1 .. n.len - 1];
            return n;
        }

        // The marker's field list — `// proto Env: r1: *T<o!>, n: i64` —
        // arrives comma-joined; wrap it back into record text.
        fn wrapFields(alloc: std.mem.Allocator, flat: []const u8) ?[]const u8 {
            const t = std.mem.trim(u8, flat, " \t");
            if (t.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{{ {s} }}", .{t}) catch unreachable;
        }

        fn scan(alloc: std.mem.Allocator, its: []const ast.Item, want: []const u8) ?[]const u8 {
            for (its) |*pi| {
                switch (pi.*) {
                    .flow => |*f| {
                        if (f.body.node) |*node| {
                            if (node.* == .invocation and isCompoundDoor(&node.invocation)) {
                                if (std.mem.eql(u8, entryName(&node.invocation), want)) {
                                    for (node.invocation.args) |a| {
                                        if (a.source_value) |sv| {
                                            return wrapFields(alloc, sv.text);
                                        }
                                    }
                                }
                            }
                        }
                    },
                    .inline_code => |*ic| {
                        var lines = std.mem.splitScalar(u8, ic.code, '\n');
                        while (lines.next()) |raw| {
                            const line = std.mem.trimLeft(u8, raw, " \t");
                            const prefix = "// proto ";
                            if (!std.mem.startsWith(u8, line, prefix)) continue;
                            const colon = std.mem.indexOfScalar(u8, line[prefix.len..], ':') orelse continue;
                            const nm = std.mem.trim(u8, line[prefix.len .. prefix.len + colon], " \t");
                            if (!std.mem.eql(u8, nm, want)) continue;
                            return wrapFields(alloc, line[prefix.len + colon + 1 ..]);
                        }
                    },
                    .module_decl => |*md| {
                        if (scan(alloc, md.items, want)) |hit| return hit;
                    },
                    else => {},
                }
            }
            return null;
        }
    };
    return W.scan(allocator, prog.items, name);
}

/// Program-wide scan for an event_decl whose path matches qualifier +
/// segments exactly (`null` qualifier matches a bare path). Recurses into
/// module_decl items — generated units and module-side decls both count.
pub fn findEventDecl(
    prog: *const ast.Program,
    qualifier: ?[]const u8,
    segments: []const []const u8,
) ?*const ast.EventDecl {
    const W = struct {
        fn match(p: ast.DottedPath, mq: ?[]const u8, segs: []const []const u8) bool {
            if (p.segments.len != segs.len) return false;
            for (p.segments, segs) |a, b| {
                if (!std.mem.eql(u8, a, b)) return false;
            }
            return std.mem.eql(u8, p.module_qualifier orelse "", mq orelse "");
        }
        fn scan(its: []const ast.Item, mq: ?[]const u8, segs: []const []const u8) ?*const ast.EventDecl {
            for (its) |*pi| {
                switch (pi.*) {
                    .event_decl => |*ed| {
                        if (match(ed.path, mq, segs)) return ed;
                    },
                    .module_decl => |*md| {
                        if (scan(md.items, mq, segs)) |hit| return hit;
                    },
                    else => {},
                }
            }
            return null;
        }
    };
    return W.scan(prog.items, qualifier, segments);
}

/// Find all items matching a predicate
pub fn findAll(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    predicate: fn (item: *const ast.Item) bool,
) ![]ast.Item {
    var matches = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer matches.deinit(allocator);

    for (source.items) |*item| {
        if (predicate(item)) {
            try matches.append(allocator, try cloneItem(allocator, item));
        }
    }

    return try matches.toOwnedSlice(allocator);
}

/// Transform only items matching a predicate
pub fn transformWhere(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    predicate: fn (item: *const ast.Item) bool,
    transform_fn: fn (allocator: std.mem.Allocator, item: *const ast.Item) anyerror!ast.Item,
) !ast.Program {
    var new_items = try allocator.alloc(ast.Item, source.items.len);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len);

    for (source.items, 0..) |*item, i| {
        if (predicate(item)) {
            new_items[i] = try transform_fn(allocator, item);
        } else {
            new_items[i] = try cloneItem(allocator, item);
        }
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// Transform only items matching a predicate, with context
pub fn transformWhereWithContext(
    comptime Context: type,
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    context: Context,
    predicate: fn (item: *const ast.Item) bool,
    transform_fn: fn (ctx: Context, allocator: std.mem.Allocator, item: *const ast.Item) anyerror!ast.Item,
) !ast.Program {
    var new_items = try allocator.alloc(ast.Item, source.items.len);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len);

    for (source.items, 0..) |*item, i| {
        if (predicate(item)) {
            new_items[i] = try transform_fn(context, allocator, item);
        } else {
            new_items[i] = try cloneItem(allocator, item);
        }
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// Compose multiple transformations into a single transformation
pub fn compose(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    transformations: []const fn (allocator: std.mem.Allocator, source: *const ast.Program) anyerror!ast.Program,
) !ast.Program {
    var result = try cloneSourceFile(allocator, source);
    defer if (transformations.len > 0) result.deinit();

    for (transformations, 0..) |transform, i| {
        const new_result = try transform(allocator, &result);
        if (i > 0) result.deinit(); // Clean up intermediate results
        result = new_result;
    }

    return result;
}

/// Deep clone a Program
pub fn cloneSourceFile(allocator: std.mem.Allocator, source: *const ast.Program) !ast.Program {
    var new_items = try allocator.alloc(ast.Item, source.items.len);
    errdefer deinitItemsPrefix(allocator, new_items, source.items.len);

    for (source.items, 0..) |*item, i| {
        new_items[i] = try cloneItem(allocator, item);
    }

    // Clone module_annotations
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer {
        for (new_annotations[0..], 0..) |annotation, i| {
            if (i >= source.module_annotations.len) break;
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }

    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return rebuildProgram(allocator, source, new_items, new_annotations);
}

/// Safely deinit an AST, skipping PROGRAM_AST (stack-allocated)
/// This is used by compiler passes to cleanup input ASTs while avoiding
/// freeing the compile-time constant PROGRAM_AST from backend.zig
///
/// NOTE: This is for COMPILER code that doesn't have access to &PROGRAM_AST.
/// Generated backend.zig code should use its own maybeDeinitAst() helper instead.
pub fn maybeDeinit(program_ast: *const ast.Program, source_ast: *const ast.Program) void {
    if (source_ast == program_ast) {
        // This is PROGRAM_AST (stack-allocated compile-time constant) - don't deinit
        return;
    }

    // Heap-allocated AST - safe to deinit
    var mutable_ast = @constCast(source_ast);
    mutable_ast.deinit();
}

/// Deep clone an Item
pub fn cloneItem(allocator: std.mem.Allocator, item: *const ast.Item) CloneError!ast.Item {
    switch (item.*) {
        .module_decl => |module| {
            return .{ .module_decl = try cloneModuleDecl(allocator, &module) };
        },
        .event_decl => |event| {
            return .{ .event_decl = try cloneEventDecl(allocator, &event) };
        },
        .proc_decl => |proc| {
            return .{ .proc_decl = try cloneProcDecl(allocator, &proc) };
        },
        .flow => |flow| {
            return .{ .flow = try cloneFlow(allocator, &flow) };
        },
        .label_decl => |label| {
            return .{ .label_decl = try cloneLabelDecl(allocator, &label) };
        },
        .immediate_impl => |ii| {
            return .{ .immediate_impl = try cloneImmediateImpl(allocator, &ii) };
        },
        .import_decl => |import| {
            return .{ .import_decl = try cloneImportDecl(allocator, &import) };
        },
        .event_tap => |tap| {
            return .{ .event_tap = try cloneEventTap(allocator, &tap) };
        },
        .host_line => |line| {
            return .{ .host_line = try cloneHostLine(allocator, &line) };
        },
        .comment => |c| {
            return .{ .comment = ast.Comment{
                .content = try allocator.dupe(u8, c.content),
                .location = c.location,
                .module = if (c.module.len > 0) try allocator.dupe(u8, c.module) else "",
            } };
        },
        .host_type_decl => |host_type| {
            return .{ .host_type_decl = try cloneHostTypeDecl(allocator, &host_type) };
        },
        .parse_error => |error_node| {
            // Parse errors can appear in interactive/IDE mode
            // Clone them so AST transformations don't crash
            return .{ .parse_error = ast.ParseErrorNode{
                .error_code = error_node.error_code,
                .message = try allocator.dupe(u8, error_node.message),
                .location = error_node.location,
                .raw_text = try allocator.dupe(u8, error_node.raw_text),
                .hint = if (error_node.hint) |h| try allocator.dupe(u8, h) else null,
            } };
        },
        .native_loop => |native_loop| {
            return .{ .native_loop = try cloneNativeLoop(allocator, &native_loop) };
        },
        .fused_event => |fused_event| {
            return .{ .fused_event = try cloneFusedEvent(allocator, &fused_event) };
        },
        .inlined_event => |inlined_event| {
            return .{ .inlined_event = try cloneInlinedEvent(allocator, &inlined_event) };
        },
        .inline_code => |ic| {
            return .{ .inline_code = ast.InlineCode{
                .code = try allocator.dupe(u8, ic.code),
                .location = ic.location,
                .module = try allocator.dupe(u8, ic.module),
            } };
        },
        .facet_decl => |fd| {
            var fields = try allocator.alloc(ast.FacetField, fd.fields.len);
            for (fd.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = try allocator.dupe(u8, field.name),
                    .type = try allocator.dupe(u8, field.type),
                    .lo = field.lo,
                    .hi = field.hi,
                    .eq = field.eq,
                    .clamp = field.clamp,
                };
            }
            return .{ .facet_decl = ast.FacetDecl{
                .name = try allocator.dupe(u8, fd.name),
                .module = try allocator.dupe(u8, fd.module),
                .target = if (fd.target) |t| try allocator.dupe(u8, t) else null,
                .fields = fields,
                .location = fd.location,
            } };
        },
    }
}

fn cloneModuleDecl(allocator: std.mem.Allocator, module: *const ast.ModuleDecl) CloneError!ast.ModuleDecl {
    // Clone items array
    var items = try allocator.alloc(ast.Item, module.items.len);
    errdefer allocator.free(items);

    for (module.items, 0..) |*item, i| {
        items[i] = try cloneItem(allocator, item);
    }

    // Clone annotations array
    var annotations = try allocator.alloc([]const u8, module.annotations.len);
    errdefer allocator.free(annotations);
    for (module.annotations, 0..) |ann, i| {
        annotations[i] = try allocator.dupe(u8, ann);
    }

    return .{
        .logical_name = try allocator.dupe(u8, module.logical_name),
        .canonical_path = try allocator.dupe(u8, module.canonical_path),
        .items = items,
        .is_system = module.is_system,
        .annotations = annotations,
        .location = module.location,
    };
}

fn cloneHostLine(allocator: std.mem.Allocator, line: *const ast.HostLine) !ast.HostLine {
    return .{
        .content = try allocator.dupe(u8, line.content),
        .location = line.location,
        .module = try allocator.dupe(u8, line.module),
    };
}

fn cloneHostTypeDecl(allocator: std.mem.Allocator, host_type: *const ast.HostTypeDecl) !ast.HostTypeDecl {
    return .{
        .name = try allocator.dupe(u8, host_type.name),
        .shape = try cloneShape(allocator, &host_type.shape),
        .module = try allocator.dupe(u8, host_type.module),
    };
}

fn cloneEventDecl(allocator: std.mem.Allocator, event: *const ast.EventDecl) !ast.EventDecl {
    var branches = try allocator.alloc(ast.Branch, event.branches.len);
    errdefer allocator.free(branches);

    for (event.branches, 0..) |*branch, i| {
        branches[i] = try cloneBranch(allocator, branch);
    }

    var annotations = try allocator.alloc([]const u8, event.annotations.len);
    for (event.annotations, 0..) |ann, i| {
        annotations[i] = try allocator.dupe(u8, ann);
    }

    return .{
        .path = try cloneDottedPath(allocator, &event.path),
        .input = try cloneShape(allocator, &event.input),
        .branches = branches,
        .return_type = if (event.return_type) |rt| try allocator.dupe(u8, rt) else null,
        .return_phantom = if (event.return_phantom) |rp| try allocator.dupe(u8, rp) else null,
        .is_public = event.is_public,
        .is_implicit_flow = event.is_implicit_flow,
        .annotations = annotations,
        .prose = try allocator.dupe(u8, event.prose),
        .is_pure = event.is_pure,
        .is_transitively_pure = event.is_transitively_pure,
        .location = event.location,
        .module = try allocator.dupe(u8, event.module),
    };
}

fn cloneProcDecl(allocator: std.mem.Allocator, proc: *const ast.ProcDecl) !ast.ProcDecl {
    // Clone annotations
    var annotations = try allocator.alloc([]const u8, proc.annotations.len);
    for (proc.annotations, 0..) |ann, i| {
        annotations[i] = try allocator.dupe(u8, ann);
    }

    return .{
        .path = try cloneDottedPath(allocator, &proc.path),
        .body = try cloneSource(allocator, &proc.body),
        .annotations = annotations,
        .prose = try allocator.dupe(u8, proc.prose),
        .target = if (proc.target) |t| try allocator.dupe(u8, t) else null,
        .is_impl = proc.is_impl,
        .is_pure = proc.is_pure,
        .is_transitively_pure = proc.is_transitively_pure,
        .location = proc.location,
        .module = try allocator.dupe(u8, proc.module),
    };
}

fn cloneFlow(allocator: std.mem.Allocator, flow: *const ast.Flow) CloneError!ast.Flow {
    // Clone the body continuation generically — its node may be an invocation
    // (the common case) OR a non-invocation (e.g. inline_code, after a root-site
    // transform lowered the flow's invocation in place). Don't assume invocation.
    const body = try cloneContinuation(allocator, &flow.body);
    return cloneFlowWithBody(allocator, flow, body);
}

fn cloneLabelDecl(allocator: std.mem.Allocator, label: *const ast.LabelDecl) !ast.LabelDecl {
    var continuations = try allocator.alloc(ast.Continuation, label.continuations.len);
    errdefer allocator.free(continuations);

    for (label.continuations, 0..) |*cont, i| {
        continuations[i] = try cloneContinuation(allocator, cont);
    }

    return .{
        .name = try allocator.dupe(u8, label.name),
        .continuations = continuations,
    };
}

fn cloneImmediateImpl(allocator: std.mem.Allocator, ii: *const ast.ImmediateImpl) !ast.ImmediateImpl {
    return .{
        .event_path = try cloneDottedPath(allocator, &ii.event_path),
        .value = try cloneBranchConstructor(allocator, &ii.value),
        .annotations = try cloneStringSlice(allocator, ii.annotations),
        .location = ii.location,
        .module = try allocator.dupe(u8, ii.module),
    };
}

fn cloneImportDecl(allocator: std.mem.Allocator, import: *const ast.ImportDecl) !ast.ImportDecl {
    return .{
        .path = try allocator.dupe(u8, import.path),
        .local_name = if (import.local_name) |n| try allocator.dupe(u8, n) else null,
        .location = import.location,
        .module = try allocator.dupe(u8, import.module),
    };
}

fn cloneEventTap(allocator: std.mem.Allocator, tap: *const ast.EventTap) !ast.EventTap {
    const source = if (tap.source) |s| try cloneDottedPath(allocator, &s) else null;
    const destination = if (tap.destination) |d| try cloneDottedPath(allocator, &d) else null;

    var continuations = try allocator.alloc(ast.Continuation, tap.continuations.len);
    errdefer allocator.free(continuations);
    for (tap.continuations, 0..) |cont, i| {
        continuations[i] = try cloneContinuation(allocator, &cont);
    }

    return .{
        .source = source,
        .destination = destination,
        .continuations = continuations,
        .is_input_tap = tap.is_input_tap,
        .annotations = try allocator.alloc([]const u8, 0), // TODO: clone annotations if needed
        .location = tap.location,
        .module = try allocator.dupe(u8, tap.module),
    };
}

pub fn cloneDottedPath(allocator: std.mem.Allocator, path: *const ast.DottedPath) !ast.DottedPath {
    var segments = try allocator.alloc([]const u8, path.segments.len);
    errdefer allocator.free(segments);

    for (path.segments, 0..) |segment, i| {
        segments[i] = try allocator.dupe(u8, segment);
    }

    return .{
        .module_qualifier = if (path.module_qualifier) |mq| try allocator.dupe(u8, mq) else null,
        .segments = segments,
    };
}

fn cloneShape(allocator: std.mem.Allocator, shape: *const ast.Shape) !ast.Shape {
    var fields = try allocator.alloc(ast.Field, shape.fields.len);
    errdefer allocator.free(fields);

    for (shape.fields, 0..) |*field, i| {
        fields[i] = try cloneField(allocator, field);
    }

    // Preserve `is_wildcard` (bare `*` payload) across clones — otherwise a
    // pipeline transform silently resets it and codegen loses the `anytype` handler.
    return .{ .fields = fields, .is_wildcard = shape.is_wildcard };
}

fn cloneField(allocator: std.mem.Allocator, field: *const ast.Field) !ast.Field {
    return .{
        .name = try allocator.dupe(u8, field.name),
        .type = try allocator.dupe(u8, field.type),
        .module_path = if (field.module_path) |mp| try allocator.dupe(u8, mp) else null,
        .phantom = if (field.phantom) |p| try allocator.dupe(u8, p) else null,
        .type_annotations = blk: {
            const anns = try allocator.alloc([]const u8, field.type_annotations.len);
            for (field.type_annotations, 0..) |a, i| anns[i] = try allocator.dupe(u8, a);
            break :blk anns;
        },
        .is_source = field.is_source,
        .is_file = field.is_file,
        .is_embed_file = field.is_embed_file,
        .is_expression = field.is_expression,
        .expression = field.expression, // Pointer copy - original persists
        .expression_str = if (field.expression_str) |e| try allocator.dupe(u8, e) else null,
        .owns_expression = false, // Cloned fields don't own the expression
        .default = if (field.default) |d| try allocator.dupe(u8, d) else null,
        // Restored: dropped on every clone until 2026-08-02, so a cloned
        // comptime shape silently lost its InvocationMeta marker.
        .is_invocation_meta = field.is_invocation_meta,
    };
}

pub fn cloneSource(allocator: std.mem.Allocator, source: *const ast.Source) !ast.Source {
    const bindings = try allocator.alloc(ast.ScopeBinding, source.scope.bindings.len);
    for (source.scope.bindings, 0..) |b, i| {
        bindings[i] = .{
            .name = try allocator.dupe(u8, b.name),
            .type = try allocator.dupe(u8, b.type),
            .value_ref = try allocator.dupe(u8, b.value_ref),
        };
    }
    return .{
        .text = try allocator.dupe(u8, source.text),
        .location = source.location,
        .scope = .{ .bindings = bindings },
        .phantom_type = if (source.phantom_type) |pt| try allocator.dupe(u8, pt) else null,
    };
}

fn cloneBranch(allocator: std.mem.Allocator, branch: *const ast.Branch) !ast.Branch {
    // Clone annotations array
    var cloned_annotations = try allocator.alloc([]const u8, branch.annotations.len);
    errdefer allocator.free(cloned_annotations);
    for (branch.annotations, 0..) |annotation, i| {
        cloned_annotations[i] = try allocator.dupe(u8, annotation);
    }

    // Clone resume arms (multi-arm resume sum)
    var cloned_arms: ?[]const ast.ResumeArm = null;
    if (branch.resume_arms) |arms| {
        const out = try allocator.alloc(ast.ResumeArm, arms.len);
        for (arms, 0..) |*arm, i| {
            out[i] = .{
                .name = try allocator.dupe(u8, arm.name),
                .type = if (arm.type) |t| try allocator.dupe(u8, t) else null,
                .phantom = if (arm.phantom) |p| try allocator.dupe(u8, p) else null,
            };
        }
        cloned_arms = out;
    }

    return .{
        .name = try allocator.dupe(u8, branch.name),
        .payload = try cloneShape(allocator, &branch.payload),
        .is_optional = branch.is_optional,
        // is_panic must survive the clone — a dropped flag silently demotes a
        // panic branch to a required one downstream.
        .is_panic = branch.is_panic,
        .kind = branch.kind,
        .resume_type = if (branch.resume_type) |rt| try allocator.dupe(u8, rt) else null,
        .resume_phantom = if (branch.resume_phantom) |rp| try allocator.dupe(u8, rp) else null,
        .resume_arms = cloned_arms,
        .annotations = cloned_annotations,
    };
}

pub fn cloneInvocation(allocator: std.mem.Allocator, invocation: *const ast.Invocation) CloneError!ast.Invocation {
    var args = try allocator.alloc(ast.Arg, invocation.args.len);
    errdefer allocator.free(args);

    for (invocation.args, 0..) |*arg, i| {
        args[i] = try cloneArg(allocator, arg);
    }

    var annotations = try allocator.alloc([]const u8, invocation.annotations.len);
    errdefer allocator.free(annotations);
    for (invocation.annotations, 0..) |ann, i| {
        annotations[i] = try allocator.dupe(u8, ann);
    }

    var marks = try allocator.alloc([]const u8, invocation.marks.len);
    errdefer allocator.free(marks);
    for (invocation.marks, 0..) |mark, i| {
        marks[i] = try allocator.dupe(u8, mark);
    }

    var return_binding_annotations = try allocator.alloc([]const u8, invocation.return_binding_annotations.len);
    errdefer allocator.free(return_binding_annotations);
    for (invocation.return_binding_annotations, 0..) |ann, i| {
        return_binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    return .{
        .path = try cloneDottedPath(allocator, &invocation.path),
        .args = args,
        .annotations = annotations,
        .marks = marks,
        .inserted_by_tap = invocation.inserted_by_tap,
        .from_opaque_tap = invocation.from_opaque_tap,
        .source_module = if (invocation.source_module.len > 0)
            try allocator.dupe(u8, invocation.source_module)
        else
            "",
        .variant = if (invocation.variant) |v|
            try allocator.dupe(u8, v)
        else
            null,
        .return_binding = if (invocation.return_binding) |rb|
            try allocator.dupe(u8, rb)
        else
            null,
        .return_binding_annotations = return_binding_annotations,
        .return_destructure = try ast.copyDestructure(allocator, invocation.return_destructure),
        .return_destructure_named = invocation.return_destructure_named,
        .inline_body = if (invocation.inline_body) |ib|
            try allocator.dupe(u8, ib)
        else
            null,
        .preamble_code = if (invocation.preamble_code) |pc|
            try allocator.dupe(u8, pc)
        else
            null,
    };
}

fn cloneArg(allocator: std.mem.Allocator, arg: *const ast.Arg) CloneError!ast.Arg {
    // FOOTGUN (documented 2026-06-30): source_value / expression_value /
    // parsed_expression are SHALLOW pointer copies. The old comment claimed
    // safety because "PROGRAM_AST persists" — that's stale; the baked-in
    // PROGRAM_AST is gone since the Dynamic-AST change. These copies are safe
    // ONLY because the whole pipeline runs on a single compile arena freed at
    // process exit, so the pointed-to nodes outlive every clone. If that
    // invariant is ever broken (a scratch arena deinit'd mid-pipeline), these
    // MUST be deep-cloned — needing recursive cloneExpression/cloneSource/
    // cloneCapturedExpression helpers that do not exist yet. Same shallow copy
    // applies to Continuation.condition_expr below.
    return .{
        .name = try allocator.dupe(u8, arg.name),
        .value = try allocator.dupe(u8, arg.value),
        .source_value = arg.source_value,
        .expression_value = arg.expression_value,
        .parsed_expression = arg.parsed_expression,
        .phantom_type = if (arg.phantom_type) |pt| try allocator.dupe(u8, pt) else null,
    };
}

pub fn cloneContinuation(allocator: std.mem.Allocator, cont: *const ast.Continuation) CloneError!ast.Continuation {
    const cloned_step = if (cont.node) |*step| try cloneStep(allocator, step) else null;

    var continuations = try allocator.alloc(ast.Continuation, cont.continuations.len);
    errdefer allocator.free(continuations);

    for (cont.continuations, 0..) |*n, i| {
        continuations[i] = try cloneContinuation(allocator, n);
    }

    return cloneContinuationWithNodeAndContinuations(allocator, cont, cloned_step, continuations, false);
}

fn cloneStep(allocator: std.mem.Allocator, step: *const ast.Step) CloneError!ast.Step {
    switch (step.*) {
        .invocation => |inv| {
            return .{ .invocation = try cloneInvocation(allocator, &inv) };
        },
        .label_apply => |label| {
            return .{ .label_apply = try allocator.dupe(u8, label) };
        },
        .label_with_invocation => |lwi| {
            return .{ .label_with_invocation = .{
                .label = try allocator.dupe(u8, lwi.label),
                .invocation = try cloneInvocation(allocator, &lwi.invocation),
                .is_declaration = lwi.is_declaration,
            } };
        },
        .label_jump => |lj| {
            var cloned_args = try allocator.alloc(ast.Arg, lj.args.len);
            for (lj.args, 0..) |*arg, i| {
                cloned_args[i] = try cloneArg(allocator, arg);
            }
            return .{ .label_jump = .{
                .label = try allocator.dupe(u8, lj.label),
                .args = cloned_args,
            } };
        },
        .terminal => {
            return .terminal;
        },
        .branch_constructor => |bc| {
            return .{ .branch_constructor = try cloneBranchConstructor(allocator, &bc) };
        },
        .conditional_block => |cb| {
            // Clone the nodes array
            var cloned_nodes = try allocator.alloc(ast.Node, cb.nodes.len);
            errdefer allocator.free(cloned_nodes);

            for (cb.nodes, 0..) |*inner_step, i| {
                cloned_nodes[i] = try cloneStep(allocator, inner_step);
            }

            return .{
                .conditional_block = .{
                    .condition = if (cb.condition) |c| try allocator.dupe(u8, c) else null,
                    .condition_expr = cb.condition_expr, // Expression cloning is complex, for now just copy pointer
                    .nodes = cloned_nodes,
                },
            };
        },
        .metatype_binding => |mb| {
            // Clone metatype binding (Profile/Transition/Audit struct construction)
            return .{ .metatype_binding = .{
                .metatype = try allocator.dupe(u8, mb.metatype),
                .binding = try allocator.dupe(u8, mb.binding),
                .source_event = try allocator.dupe(u8, mb.source_event),
                .dest_event = if (mb.dest_event) |dest| try allocator.dupe(u8, dest) else null,
                .branch = try allocator.dupe(u8, mb.branch),
            } };
        },
        .inline_code => |code| {
            return .{ .inline_code = try allocator.dupe(u8, code) };
        },
        .expression => |code| {
            return .{ .expression = try allocator.dupe(u8, code) };
        },
        .foreach => |fe| {
            // Clone foreach - uses uniform NamedBranch structure
            return .{ .foreach = .{
                .iterable = try allocator.dupe(u8, fe.iterable),
                .element_type = if (fe.element_type) |et| try allocator.dupe(u8, et) else null,
                .branches = try cloneNamedBranches(allocator, fe.branches),
            } };
        },
        .conditional => |cond| {
            // Clone conditional - uses uniform NamedBranch structure
            return .{
                .conditional = .{
                    .condition = try allocator.dupe(u8, cond.condition),
                    .condition_expr = cond.condition_expr, // Expression cloning is complex, for now just copy pointer
                    .branches = try cloneNamedBranches(allocator, cond.branches),
                },
            };
        },
        .switch_result => |sr| {
            // Clone switch_result - uses uniform NamedBranch structure
            return .{ .switch_result = .{
                .expression = try allocator.dupe(u8, sr.expression),
                .branches = try cloneNamedBranches(allocator, sr.branches),
            } };
        },
        .assignment => |asgn| {
            // Clone assignment - fields need recursive cloning
            var cloned_fields = try allocator.alloc(ast.Field, asgn.fields.len);
            errdefer allocator.free(cloned_fields);
            for (asgn.fields, 0..) |*field, i| {
                cloned_fields[i] = try cloneField(allocator, field);
            }
            return .{ .assignment = .{
                .target = try allocator.dupe(u8, asgn.target),
                .fields = cloned_fields,
            } };
        },
    }
}

fn cloneBranchConstructor(allocator: std.mem.Allocator, bc: *const ast.BranchConstructor) CloneError!ast.BranchConstructor {
    var fields = try allocator.alloc(ast.Field, bc.fields.len);
    errdefer allocator.free(fields);

    for (bc.fields, 0..) |*field, i| {
        fields[i] = try cloneField(allocator, field);
    }

    return .{
        .branch_name = try allocator.dupe(u8, bc.branch_name),
        .fields = fields,
        .plain_value = if (bc.plain_value) |pv| try allocator.dupe(u8, pv) else null,
        .has_expressions = bc.has_expressions,
        .is_bare_return = bc.is_bare_return,
    };
}

fn cloneNamedBranch(allocator: std.mem.Allocator, branch: *const ast.NamedBranch) CloneError!ast.NamedBranch {
    var cloned_body = try allocator.alloc(ast.Continuation, branch.body.len);
    errdefer allocator.free(cloned_body);

    for (branch.body, 0..) |*cont, i| {
        cloned_body[i] = try cloneContinuation(allocator, cont);
    }

    // Clone annotations and marks (critical for @scope — it lives in marks)
    var cloned_annotations = try allocator.alloc([]const u8, branch.annotations.len);
    for (branch.annotations, 0..) |ann, i| {
        cloned_annotations[i] = try allocator.dupe(u8, ann);
    }
    var cloned_marks = try allocator.alloc([]const u8, branch.marks.len);
    for (branch.marks, 0..) |mark, i| {
        cloned_marks[i] = try allocator.dupe(u8, mark);
    }

    return .{
        .name = try allocator.dupe(u8, branch.name),
        .body = cloned_body,
        .binding = if (branch.binding) |b| try allocator.dupe(u8, b) else null,
        .produce = try ast.copyDestructure(allocator, branch.produce),
        .is_optional = branch.is_optional,
        .annotations = cloned_annotations,
        .marks = cloned_marks,
    };
}

fn cloneNamedBranches(allocator: std.mem.Allocator, branches: []const ast.NamedBranch) CloneError![]ast.NamedBranch {
    var cloned = try allocator.alloc(ast.NamedBranch, branches.len);
    errdefer allocator.free(cloned);

    for (branches, 0..) |*branch, i| {
        cloned[i] = try cloneNamedBranch(allocator, branch);
    }

    return cloned;
}

// ============================================================================
// Pipeline Manipulation Functions
// ============================================================================
// These functions enable transforms to modify continuations within flows.
// Used by ~if, ~for, and other control flow transforms.

/// Replace a step in a continuation's pipeline, returning a new Flow.
/// The flow is cloned with the specified step replaced.
pub fn replacePipelineStep(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    cont_idx: usize,
    step_idx: usize,
    new_step: ast.Step,
) CloneError!ast.Flow {
    // Clone continuations array
    var new_continuations = try allocator.alloc(ast.Continuation, flow.body.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.body.continuations, 0..) |*cont, i| {
        if (i == cont_idx) {
            // This is the continuation to modify - clone with replaced step
            new_continuations[i] = try cloneContinuationWithReplacedStep(allocator, cont, step_idx, new_step);
        } else {
            // Clone unchanged
            new_continuations[i] = try cloneContinuation(allocator, cont);
        }
    }

    // Clone the rest of the flow
    return cloneFlowWithContinuations(allocator, flow, new_continuations);
}

/// Clone a continuation with one step replaced
fn cloneContinuationWithReplacedStep(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    step_idx: usize,
    new_step: ast.Step,
) CloneError!ast.Continuation {
    // Replace the step if index is 0 and step exists
    const replaced_step = if (step_idx == 0) new_step else if (cont.node) |*step| try cloneStep(allocator, step) else null;

    // Clone continuations
    var new_continuations = try allocator.alloc(ast.Continuation, cont.continuations.len);
    errdefer allocator.free(new_continuations);

    for (cont.continuations, 0..) |*n, i| {
        new_continuations[i] = try cloneContinuation(allocator, n);
    }

    return cloneContinuationWithNodeAndContinuations(allocator, cont, replaced_step, new_continuations, false);
}

/// Filter nested continuations in a flow's continuation, returning a new Flow.
/// Keeps only nested continuations where keep_fn returns true for the branch name.
pub fn filterNestedContinuations(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    cont_idx: usize,
    keep_fn: *const fn (branch: []const u8) bool,
) CloneError!ast.Flow {
    // Clone continuations array
    var new_continuations = try allocator.alloc(ast.Continuation, flow.body.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.body.continuations, 0..) |*cont, i| {
        if (i == cont_idx) {
            // This is the continuation to modify - clone with filtered nested
            new_continuations[i] = try cloneContinuationWithFilteredNested(allocator, cont, keep_fn);
        } else {
            // Clone unchanged
            new_continuations[i] = try cloneContinuation(allocator, cont);
        }
    }

    // Clone the rest of the flow
    return cloneFlowWithContinuations(allocator, flow, new_continuations);
}

/// Clone a continuation with filtered nested continuations
fn cloneContinuationWithFilteredNested(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    keep_fn: *const fn (branch: []const u8) bool,
) CloneError!ast.Continuation {
    // Clone step
    const cloned_step = if (cont.node) |*step| try cloneStep(allocator, step) else null;

    // Count how many continuations to keep
    var keep_count: usize = 0;
    for (cont.continuations) |*n| {
        if (keep_fn(n.branch)) {
            keep_count += 1;
        }
    }

    // Clone only the continuations that pass the filter
    var new_continuations = try allocator.alloc(ast.Continuation, keep_count);
    errdefer allocator.free(new_continuations);

    var j: usize = 0;
    for (cont.continuations) |*n| {
        if (keep_fn(n.branch)) {
            new_continuations[j] = try cloneContinuation(allocator, n);
            j += 1;
        }
    }

    return cloneContinuationWithNodeAndContinuations(allocator, cont, cloned_step, new_continuations, false);
}

/// Helper to clone a string slice
fn cloneStringSlice(allocator: std.mem.Allocator, slice: []const []const u8) CloneError![][]const u8 {
    var result = try allocator.alloc([]const u8, slice.len);
    errdefer allocator.free(result);

    for (slice, 0..) |s, i| {
        result[i] = try allocator.dupe(u8, s);
    }

    return result;
}

// ============================================================================
// PATH-BASED NESTED CONTINUATION MANIPULATION
// ============================================================================
// These functions operate on continuations at arbitrary depth in the AST.
// A "continuation path" is a slice of indices representing the traversal:
//   path = [0]      -> flow.body.continuations[0]
//   path = [0, 1]   -> flow.body.continuations[0].continuations[1]
//   path = [0, 1, 2] -> flow.body.continuations[0].continuations[1].continuations[2]

/// Replace a step in a deeply nested continuation's pipeline.
/// cont_path specifies the path through nested continuations to reach the target.
pub fn replacePipelineStepAtPath(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    cont_path: []const usize,
    step_idx: usize,
    new_step: ast.Step,
) CloneError!ast.Flow {
    if (cont_path.len == 0) {
        return error.OutOfMemory; // Invalid path
    }

    // Clone continuations array with the modified one
    var new_continuations = try allocator.alloc(ast.Continuation, flow.body.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.body.continuations, 0..) |*cont, i| {
        if (i == cont_path[0]) {
            // This is the continuation to descend into
            if (cont_path.len == 1) {
                // Target is this continuation - replace the step
                new_continuations[i] = try cloneContinuationWithReplacedStep(allocator, cont, step_idx, new_step);
            } else {
                // Need to go deeper - recursively modify nested
                new_continuations[i] = try cloneContinuationWithModifiedNested(allocator, cont, cont_path[1..], step_idx, new_step);
            }
        } else {
            new_continuations[i] = try cloneContinuation(allocator, cont);
        }
    }

    return cloneFlowWithContinuations(allocator, flow, new_continuations);
}

/// Clone a continuation with a nested continuation modified (recursively)
fn cloneContinuationWithModifiedNested(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    remaining_path: []const usize,
    step_idx: usize,
    new_step: ast.Step,
) CloneError!ast.Continuation {
    // Clone step unchanged
    const cloned_step = if (cont.node) |*step| try cloneStep(allocator, step) else null;

    // Clone continuations with one modified
    var new_continuations = try allocator.alloc(ast.Continuation, cont.continuations.len);
    errdefer allocator.free(new_continuations);

    for (cont.continuations, 0..) |*n, i| {
        if (i == remaining_path[0]) {
            // This is the continuation to descend into
            if (remaining_path.len == 1) {
                // Target is this continuation - replace the step
                new_continuations[i] = try cloneContinuationWithReplacedStep(allocator, n, step_idx, new_step);
            } else {
                // Go deeper
                new_continuations[i] = try cloneContinuationWithModifiedNested(allocator, n, remaining_path[1..], step_idx, new_step);
            }
        } else {
            new_continuations[i] = try cloneContinuation(allocator, n);
        }
    }

    return cloneContinuationWithNodeAndContinuations(allocator, cont, cloned_step, new_continuations, false);
}

/// Filter nested continuations at a specific path in the continuation tree.
pub fn filterNestedContinuationsAtPath(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    cont_path: []const usize,
    keep_fn: *const fn (branch: []const u8) bool,
) CloneError!ast.Flow {
    if (cont_path.len == 0) {
        return error.OutOfMemory; // Invalid path
    }

    var new_continuations = try allocator.alloc(ast.Continuation, flow.body.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.body.continuations, 0..) |*cont, i| {
        if (i == cont_path[0]) {
            if (cont_path.len == 1) {
                // Target is this continuation - filter its nested
                new_continuations[i] = try cloneContinuationWithFilteredNested(allocator, cont, keep_fn);
            } else {
                // Go deeper
                new_continuations[i] = try cloneContinuationWithFilterAtPath(allocator, cont, cont_path[1..], keep_fn);
            }
        } else {
            new_continuations[i] = try cloneContinuation(allocator, cont);
        }
    }

    return cloneFlowWithContinuations(allocator, flow, new_continuations);
}

/// Clone a continuation with filtering applied at a nested path
fn cloneContinuationWithFilterAtPath(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    remaining_path: []const usize,
    keep_fn: *const fn (branch: []const u8) bool,
) CloneError!ast.Continuation {
    // Clone step unchanged
    const cloned_step = if (cont.node) |*step| try cloneStep(allocator, step) else null;

    // Clone continuations with one filtered or descend deeper
    var new_continuations = try allocator.alloc(ast.Continuation, cont.continuations.len);
    errdefer allocator.free(new_continuations);

    for (cont.continuations, 0..) |*n, i| {
        if (i == remaining_path[0]) {
            if (remaining_path.len == 1) {
                // Target - filter its continuations
                new_continuations[i] = try cloneContinuationWithFilteredNested(allocator, n, keep_fn);
            } else {
                // Go deeper
                new_continuations[i] = try cloneContinuationWithFilterAtPath(allocator, n, remaining_path[1..], keep_fn);
            }
        } else {
            new_continuations[i] = try cloneContinuation(allocator, n);
        }
    }

    return cloneContinuationWithNodeAndContinuations(allocator, cont, cloned_step, new_continuations, false);
}

/// Visitor pattern for traversing the AST without mutation
pub fn visit(
    source: *const ast.Program,
    context: anytype,
    visitor: fn (ctx: @TypeOf(context), item: *const ast.Item) void,
) void {
    for (source.items) |*item| {
        visitor(context, item);
    }
}

/// Find the first item matching a predicate
pub fn findFirst(
    source: *const ast.Program,
    predicate: fn (item: *const ast.Item) bool,
) ?*const ast.Item {
    for (source.items) |*item| {
        if (predicate(item)) return item;
    }
    return null;
}

/// Count items matching a predicate
pub fn countWhere(
    source: *const ast.Program,
    predicate: fn (item: *const ast.Item) bool,
) usize {
    var count: usize = 0;
    for (source.items) |*item| {
        if (predicate(item)) count += 1;
    }
    return count;
}

/// Compare two DottedPaths for equality
pub fn pathsEqual(p1: ast.DottedPath, p2: ast.DottedPath) bool {
    // Check module qualifiers
    if (p1.module_qualifier != null and p2.module_qualifier != null) {
        if (!std.mem.eql(u8, p1.module_qualifier.?, p2.module_qualifier.?)) {
            return false;
        }
    } else if (p1.module_qualifier != null or p2.module_qualifier != null) {
        return false;
    }

    // Check segment count
    if (p1.segments.len != p2.segments.len) return false;

    // Check each segment
    for (p1.segments, p2.segments) |s1, s2| {
        if (!std.mem.eql(u8, s1, s2)) return false;
    }

    return true;
}

/// Find an event declaration by its dotted path
/// Searches through all items (including inside modules) for matching event
pub fn findEventByPath(
    source: *const ast.Program,
    path: ast.DottedPath,
) ?*const ast.EventDecl {
    // Search top-level items
    for (source.items) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                if (pathsEqual(event.path, path)) {
                    return event;
                }
            },
            .module_decl => |*module| {
                // Search inside module
                for (module.items) |*module_item| {
                    if (module_item.* == .event_decl) {
                        const event = &module_item.event_decl;
                        if (pathsEqual(event.path, path)) {
                            return event;
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// Find an event declaration by its canonical name string
/// Canonical format: "module.path:event.name" or just "event.name"
/// Examples: "std.graphics:blur", "std.io:print.ln", "my_event"
/// A module path written with `/` (the import spelling) and the same path
/// written with `.` (the logical spelling) name the same module. Koru has no
/// pair of distinct modules these could confuse, so one comparison covers both.
fn modulePathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '/') @as(u8, '.') else ca;
        const nb = if (cb == '/') @as(u8, '.') else cb;
        if (na != nb) return false;
    }
    return true;
}

pub fn findEventByCanonicalName(
    source: *const ast.Program,
    canonical_name: []const u8,
) ?*const ast.EventDecl {
    // Parse canonical name into module qualifier and event path
    // Format: "module.path:event.name" or just "event.name"
    var module_qualifier: ?[]const u8 = null;
    var event_path: []const u8 = canonical_name;

    if (std.mem.indexOfScalar(u8, canonical_name, ':')) |colon_idx| {
        module_qualifier = canonical_name[0..colon_idx];
        event_path = canonical_name[colon_idx + 1 ..];
    }

    // Search through all items
    for (source.items) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                if (eventMatchesCanonical(event, module_qualifier, event_path)) {
                    return event;
                }
            },
            .module_decl => |*module| {
                // Check if module matches the qualifier.
                //
                // A CALLER SPELLS THIS THE WAY THE PROGRAM IMPORTS IT. Every
                // canonical name a user writes by hand — a `build:variants`
                // key, most of all — is copied off an import line, so it reads
                // `mylib/pump`, while `logical_name` is the dotted
                // `mylib.pump`. An exact compare therefore refused every
                // SUBMODULE event: `variants` took its `invalid-event` branch,
                // which the documented idiom discards with `_`, so the
                // registration silently did not happen and every call site kept
                // the default handler. Orisha's `~[build(linux)]` epoll line had
                // never once taken effect.
                //
                // Top-level events hid it: `input:pump` has no separator to
                // disagree about, and every variant test in the suite used one.
                const module_matches = if (module_qualifier) |mq|
                    modulePathEql(module.logical_name, mq)
                else
                    true; // No qualifier means search all modules

                if (module_matches) {
                    for (module.items) |*module_item| {
                        if (module_item.* == .event_decl) {
                            const event = &module_item.event_decl;
                            // For module items, check without module qualifier
                            if (eventMatchesCanonical(event, null, event_path)) {
                                return event;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// Check if an event matches a canonical path
fn eventMatchesCanonical(
    event: *const ast.EventDecl,
    module_qualifier: ?[]const u8,
    event_path: []const u8,
) bool {
    // Check module qualifier if specified
    if (module_qualifier) |mq| {
        if (event.path.module_qualifier) |eq| {
            if (!std.mem.eql(u8, mq, eq)) return false;
        } else {
            return false; // Event has no module qualifier but one was expected
        }
    }

    // Build event path string from segments
    // event_path could be "blur" or "print.ln"
    var path_buf: [256]u8 = undefined;
    var path_len: usize = 0;

    path_len = event.path.writeSegments(&path_buf, path_len);

    return std.mem.eql(u8, path_buf[0..path_len], event_path);
}

/// Prune all items marked with [backend] annotation
/// Returns a new Program without backend-only items
/// This is used by compiler.emit.zig to remove comptime-only constructs before generating runtime code
pub fn pruneBackendOnly(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
) !ast.Program {
    const Predicate = struct {
        fn pred(item: *const ast.Item) bool {
            switch (item.*) {
                .event_decl => |event| {
                    // Check annotations - skip if marked [backend]
                    for (event.annotations) |ann| {
                        if (std.mem.eql(u8, ann, "backend")) {
                            return false; // Skip this item
                        }
                    }
                    return true; // Keep it
                },
                .proc_decl => |proc| {
                    // Also check proc annotations
                    for (proc.annotations) |ann| {
                        if (std.mem.eql(u8, ann, "backend")) {
                            return false;
                        }
                    }
                    return true;
                },
                // All other item types are kept (no annotations to check)
                .module_decl, .flow, .event_tap, .label_decl, .immediate_impl, .import_decl, .host_line, .host_type_decl => return true,
            }
        }
    };

    return filterItems(allocator, source, Predicate.pred);
}

/// Filter to keep only modules with a specific annotation
/// Returns a new Program containing only modules that have the required annotation
/// Top-level items without module context are kept if source_file has the annotation
pub fn filterByAnnotation(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    required_annotation: []const u8,
) !ast.Program {
    var filtered_items = try std.ArrayList(ast.Item).initCapacity(allocator, 0);
    defer filtered_items.deinit(allocator);

    // Check if source file itself has the annotation
    var source_has_annotation = false;
    for (source.module_annotations) |ann| {
        if (std.mem.eql(u8, ann, required_annotation)) {
            source_has_annotation = true;
            break;
        }
    }

    for (source.items) |*item| {
        switch (item.*) {
            .module_decl => {
                // Check if this module has the required annotation
                // Module annotations are stored in module_annotations of the Program
                // but we need to check if the module's logical_name has the annotation
                // For now, we'll create a filtered module with only matching items

                // Actually, we want to keep the ENTIRE module if it has the annotation
                // The module itself doesn't have annotations - the SOURCE FILE does
                // So we need to walk modules and check their source annotations

                // For simplicity: keep all module_decls for now - they'll be filtered
                // by the emitter based on the module's file annotations
                try filtered_items.append(allocator, try cloneItem(allocator, item));
            },
            else => {
                // For non-module items, keep them if source has annotation
                if (source_has_annotation) {
                    try filtered_items.append(allocator, try cloneItem(allocator, item));
                }
            },
        }
    }

    // Keep module annotations
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer freeDupedStrings(allocator, new_annotations);
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = try filtered_items.toOwnedSlice(allocator),
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
}

// NOTE: Generic pruneByAnnotations function would go here
// For now, we only need pruneBackendOnly which handles the [backend] annotation
// If we need more generic annotation pruning in the future, we can add it here

// ============================================================
// Continuation-Level Navigation
// ============================================================
// These helpers navigate Flow and Continuation structures,
// complementing the existing Item-level navigation above.
// Used for metaprogramming (threading, macros, DSLs, etc.)

/// Find a continuation branch by name in a flow
/// Returns the first continuation matching the branch name, or null if not found
/// Example: findContinuationByBranch(spawn_flow, "run") finds | run |> ...
pub fn findContinuationByBranch(
    flow: *const ast.Flow,
    branch_name: []const u8,
) ?*const ast.Continuation {
    return findContinuationByBranchInSlice(flow.body.continuations, branch_name);
}

/// Find a continuation branch by name in an arbitrary continuation slice
/// Returns the first continuation matching the branch name, or null if not found
pub fn findContinuationByBranchInSlice(
    continuations: []const ast.Continuation,
    branch_name: []const u8,
) ?*const ast.Continuation {
    for (continuations) |*cont| {
        if (std.mem.eql(u8, cont.branch, branch_name)) {
            return cont;
        }
    }
    return null;
}

/// Find the continuation whose node is the target invocation.
/// Recurses into nested continuations.
pub fn findContinuationContainingInvocation(
    continuations: []const ast.Continuation,
    target_invocation: *const ast.Invocation,
) ?*const ast.Continuation {
    for (continuations) |*cont| {
        if (cont.node) |*node| {
            if (node.* == .invocation and &node.invocation == target_invocation) {
                return cont;
            }
        }

        if (findContinuationContainingInvocation(cont.continuations, target_invocation)) |found| {
            return found;
        }
    }

    return null;
}

pub const LexicalSubtreeWalkControl = enum {
    continue_walk,
    stop,
};

pub const LexicalSubtreeVisit = union(enum) {
    continuation: *const ast.Continuation,
    node: struct {
        continuation: ?*const ast.Continuation,
        node: *const ast.Node,
    },
    invocation: struct {
        continuation: ?*const ast.Continuation,
        invocation: *const ast.Invocation,
    },
};

/// Walk a lexical continuation subtree in source order.
///
/// Visits:
/// - the continuation itself
/// - its node/invocation (if present)
/// - any nested continuation bodies reachable through the continuation tree
/// - branch bodies nested inside structured AST nodes (foreach/conditional/capture/switch_result)
pub fn walkLexicalContinuationSubtree(
    comptime Context: type,
    root: *const ast.Continuation,
    context: *Context,
    visitor: fn (context: *Context, visit: LexicalSubtreeVisit) anyerror!LexicalSubtreeWalkControl,
) anyerror!void {
    _ = try walkLexicalContinuationSubtreeInner(Context, root, context, visitor);
}

fn walkLexicalContinuationSubtreeInner(
    comptime Context: type,
    continuation: *const ast.Continuation,
    context: *Context,
    visitor: fn (context: *Context, visit: LexicalSubtreeVisit) anyerror!LexicalSubtreeWalkControl,
) anyerror!bool {
    if (try visitor(context, .{ .continuation = continuation }) == .stop) {
        return true;
    }

    if (continuation.node) |*node| {
        if (try walkLexicalNodeInner(Context, node, continuation, context, visitor)) {
            return true;
        }
    }

    for (continuation.continuations) |*nested| {
        if (try walkLexicalContinuationSubtreeInner(Context, nested, context, visitor)) {
            return true;
        }
    }

    return false;
}

fn walkLexicalNodeInner(
    comptime Context: type,
    node: *const ast.Node,
    owning_continuation: ?*const ast.Continuation,
    context: *Context,
    visitor: fn (context: *Context, visit: LexicalSubtreeVisit) anyerror!LexicalSubtreeWalkControl,
) anyerror!bool {
    switch (node.*) {
        .invocation => |*invocation| {
            if (try visitor(context, .{ .invocation = .{
                .continuation = owning_continuation,
                .invocation = invocation,
            } }) == .stop) {
                return true;
            }
        },
        else => {
            if (try visitor(context, .{ .node = .{
                .continuation = owning_continuation,
                .node = node,
            } }) == .stop) {
                return true;
            }
        },
    }

    switch (node.*) {
        .conditional_block => |*cb| {
            for (cb.nodes) |*child_node| {
                if (try walkLexicalNodeInner(Context, child_node, owning_continuation, context, visitor)) {
                    return true;
                }
            }
        },
        .foreach => |*fe| {
            for (fe.branches) |*branch| {
                for (branch.body) |*cont| {
                    if (try walkLexicalContinuationSubtreeInner(Context, cont, context, visitor)) {
                        return true;
                    }
                }
            }
        },
        .conditional => |*cond| {
            for (cond.branches) |*branch| {
                for (branch.body) |*cont| {
                    if (try walkLexicalContinuationSubtreeInner(Context, cont, context, visitor)) {
                        return true;
                    }
                }
            }
        },
        .switch_result => |*sr| {
            for (sr.branches) |*branch| {
                for (branch.body) |*cont| {
                    if (try walkLexicalContinuationSubtreeInner(Context, cont, context, visitor)) {
                        return true;
                    }
                }
            }
        },
        else => {},
    }

    return false;
}

/// Get all continuation branches from a flow (cloned)
/// Returns a new array containing clones of all continuations
/// Caller owns the returned slice and must free it with allocator.free() after deinit'ing each continuation
pub fn getAllContinuations(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
) ![]ast.Continuation {
    var continuations = try allocator.alloc(ast.Continuation, flow.body.continuations.len);
    errdefer allocator.free(continuations);

    for (flow.body.continuations, 0..) |*cont, i| {
        continuations[i] = try cloneContinuation(allocator, cont);
    }

    return continuations;
}

/// Count nested continuations recursively
/// Used for complexity analysis and determining nesting depth
/// Example: | ok |> worker(x: 1) | done |> _ has 1 nested continuation
pub fn countNestedContinuations(continuation: *const ast.Continuation) usize {
    var count: usize = continuation.continuations.len;
    for (continuation.continuations) |*nested| {
        count += countNestedContinuations(nested);
    }
    return count;
}

// ============================================================
// AST Construction (Builders)
// ============================================================
// These helpers create AST nodes from scratch (not cloning).
// Used for code generation in comptime procs (threading, macros, etc.)

/// Create a simple dotted path from a string
/// Parses "module:segment1.segment2" into DottedPath structure
/// Examples:
///   "worker" -> DottedPath{ .module_qualifier = null, .segments = ["worker"] }
///   "thread:spawn" -> DottedPath{ .module_qualifier = "thread", .segments = ["spawn"] }
///   "io.print" -> DottedPath{ .module_qualifier = null, .segments = ["io", "print"] }
pub fn createDottedPath(
    allocator: std.mem.Allocator,
    path_str: []const u8,
) !ast.DottedPath {
    // Check for module qualifier (before ':')
    var module_qualifier: ?[]const u8 = null;
    var segments_part: []const u8 = path_str;

    if (std.mem.indexOf(u8, path_str, ":")) |colon_idx| {
        module_qualifier = try allocator.dupe(u8, path_str[0..colon_idx]);
        segments_part = path_str[colon_idx + 1 ..];
    }

    // Split segments by '.'
    var segments_list = std.ArrayList([]const u8).init(allocator);
    defer segments_list.deinit();

    var iter = std.mem.split(u8, segments_part, ".");
    while (iter.next()) |segment| {
        if (segment.len > 0) {
            try segments_list.append(try allocator.dupe(u8, segment));
        }
    }

    return ast.DottedPath{
        .module_qualifier = module_qualifier,
        .segments = try segments_list.toOwnedSlice(),
    };
}

/// Create a flow from invocation + continuations
/// This is the primary builder for creating flows in metaprogramming
/// Example:
///   const flow = try createFlow(allocator, invocation, &[_]ast.Continuation{done_cont}, "main");
pub fn createFlow(
    allocator: std.mem.Allocator,
    invocation: ast.Invocation,
    continuations: []const ast.Continuation,
    module: []const u8,
) !ast.Flow {
    // Clone continuations to ensure ownership
    var cloned_conts = try allocator.alloc(ast.Continuation, continuations.len);
    errdefer allocator.free(cloned_conts);

    for (continuations, 0..) |*cont, i| {
        cloned_conts[i] = try cloneContinuation(allocator, cont);
    }

    return ast.Flow{
        .body = ast.rootSite(invocation, cloned_conts, .{ .file = "generated", .line = 0, .column = 0 }),
        .pre_label = null,
        .super_shape = null,
        .is_pure = true, // Flows are locally pure by default
        .is_transitively_pure = false, // Will be computed by purity checker
        .location = .{ .line = 0, .column = 0, .file = "" }, // Generated code has no source location
        .module = try allocator.dupe(u8, module),
    };
}

/// Create an event declaration
/// Used to generate new event definitions in metaprogramming
/// Example:
///   const event = try createEventDecl(allocator, path, input_shape, branches, "main");
pub fn createEventDecl(
    allocator: std.mem.Allocator,
    path: ast.DottedPath,
    input: ast.Shape,
    branches: []const ast.Branch,
    module: []const u8,
) !ast.EventDecl {
    // Clone branches to ensure ownership
    var cloned_branches = try allocator.alloc(ast.Branch, branches.len);
    errdefer allocator.free(cloned_branches);

    for (branches, 0..) |*branch, i| {
        cloned_branches[i] = try cloneBranch(allocator, branch);
    }

    return ast.EventDecl{
        .path = path,
        .input = input,
        .branches = cloned_branches,
        .is_public = false, // Generated events are private by default
        .is_implicit_flow = false,
        .annotations = &[_][]const u8{}, // No annotations by default
        .is_pure = false,
        .is_transitively_pure = false,
        .location = .{ .line = 0, .column = 0, .file = "" }, // Generated code
        .module = try allocator.dupe(u8, module),
    };
}

/// Create an impl flow (a flow that implements a named event)
/// Used to generate subflow definitions from extracted continuation branches.
/// Returns a Flow with impl_of set to the given event_path.
/// Example:
///   const impl_flow = try createImplFlow(allocator, event_path, flow, "main");
pub fn createImplFlow(
    allocator: std.mem.Allocator,
    event_path: ast.DottedPath,
    body_flow: ast.Flow,
    module: []const u8,
) !ast.Flow {
    // Start from the body_flow and set impl_of
    var result = body_flow;
    result.impl_of = event_path;
    result.location = .{ .line = 0, .column = 0, .file = "" }; // Generated code
    result.module = try allocator.dupe(u8, module);
    return result;
}

// ============================================================
// Hygiene Utilities (Name Generation)
// ============================================================
// These helpers prevent name collisions in generated code.
// Used for generating unique identifiers in metaprogramming.

/// Check if an event with the given name exists in the AST
/// Searches through all items (including inside modules) for matching event
/// Used before generating new events to avoid collisions
pub fn eventExists(
    source: *const ast.Program,
    event_name: []const u8,
) bool {
    for (source.items) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                // Check if any segment matches the event name
                for (event.path.segments) |segment| {
                    if (std.mem.eql(u8, segment, event_name)) {
                        return true;
                    }
                }
            },
            .module_decl => |*module| {
                // Search inside modules
                for (module.items) |*module_item| {
                    if (module_item.* == .event_decl) {
                        const event = &module_item.event_decl;
                        for (event.path.segments) |segment| {
                            if (std.mem.eql(u8, segment, event_name)) {
                                return true;
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

/// Generate a unique identifier with the given prefix
/// Uses a counter to ensure uniqueness across the AST
/// Example: generateUniqueName(allocator, source, "__thread_run_")
///          -> "__thread_run_0", "__thread_run_1", etc.
/// The caller owns the returned string and must free it
pub fn generateUniqueName(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    prefix: []const u8,
) ![]const u8 {
    var counter: usize = 0;
    while (true) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{d}", .{ prefix, counter });

        // Check if this name exists in the AST
        if (!eventExists(source, candidate)) {
            return candidate; // Found a unique name
        }

        // Name exists, try next counter
        allocator.free(candidate);
        counter += 1;

        // Safety: prevent infinite loops (should never reach this)
        if (counter > 1000000) {
            return error.TooManyGeneratedNames;
        }
    }
}

// ============================================================
// Continuation Analysis
// ============================================================
// extractContinuationAsFlow used to live here — it converted the nested
// invoke+branches encoding into the top-level one. The dual encoding is
// gone (Flow.body IS a Continuation), so the conversion has no job left.

/// Infer output branches from a continuation
/// Analyzes the continuation's nested branches to determine what outputs it produces
/// This is used to generate the output shape for extracted subflows
///
/// Example:
///   | run |> worker(x: 1)
///     | done d |> continue { result: d.value }
///
///   Would infer: [Branch{ .name = "continue", ... }]
///
/// Note: This is a simple heuristic - it looks at the outermost nested branch names
/// More complex analysis (looking at branch constructors, etc.) could be added later
pub fn inferContinuationOutputBranches(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
) ![]ast.Branch {
    // Collect unique branch names from nested continuations
    var branch_names = std.ArrayList([]const u8).init(allocator);
    defer {
        for (branch_names.items) |name| {
            allocator.free(name);
        }
        branch_names.deinit();
    }

    for (continuation.continuations) |*nested| {
        // Check if we already have this branch
        var found = false;
        for (branch_names.items) |existing| {
            if (std.mem.eql(u8, existing, nested.branch)) {
                found = true;
                break;
            }
        }

        if (!found) {
            try branch_names.append(try allocator.dupe(u8, nested.branch));
        }
    }

    // Create Branch structures with empty payloads
    // The shape-checker will fill in actual types during validation
    var branches = try allocator.alloc(ast.Branch, branch_names.items.len);
    errdefer allocator.free(branches);

    for (branch_names.items, 0..) |name, i| {
        branches[i] = ast.Branch{
            .name = try allocator.dupe(u8, name),
            .payload = .{ .fields = &[_]ast.Field{} }, // Empty payload - shape-checker will infer
            .is_optional = false,
            .kind = .terminal,
            .resume_type = null,
        };
    }

    return branches;
}

// ============================================================
// IR Node Cloning
// ============================================================
// Clone functions for IR (Intermediate Representation) nodes
// created by optimization passes

fn cloneNativeLoop(allocator: std.mem.Allocator, loop: *const ast.NativeLoop) CloneError!ast.NativeLoop {
    // Clone done_field_values array
    var cloned_field_values = try allocator.alloc(ast.NativeLoop.FieldValue, loop.done_field_values.len);
    errdefer allocator.free(cloned_field_values);

    for (loop.done_field_values, 0..) |field_value, i| {
        cloned_field_values[i] = ast.NativeLoop.FieldValue{
            .field_name = try allocator.dupe(u8, field_value.field_name),
            .value_expr = try allocator.dupe(u8, field_value.value_expr),
        };
    }

    return .{
        .event_path = try cloneDottedPath(allocator, &loop.event_path),
        .variable = try allocator.dupe(u8, loop.variable),
        .start_expr = try allocator.dupe(u8, loop.start_expr),
        .end_expr = try allocator.dupe(u8, loop.end_expr),
        .step_expr = if (loop.step_expr) |step| try allocator.dupe(u8, step) else null,
        .body_code = try allocator.dupe(u8, loop.body_code),
        .body_source = if (loop.body_source) |*bs| try cloneDottedPath(allocator, bs) else null,
        .exit_branch_name = try allocator.dupe(u8, loop.exit_branch_name),
        .done_field_values = cloned_field_values,
        .style = loop.style,
        .optimized_from = if (loop.optimized_from) |*of| try cloneDottedPath(allocator, of) else null,
        .optimized_from_flow = loop.optimized_from_flow, // Pointer copy - doesn't own the flow
        .location = loop.location,
        .module = try allocator.dupe(u8, loop.module),
    };
}

fn cloneFusedEvent(allocator: std.mem.Allocator, fused: *const ast.FusedEvent) CloneError!ast.FusedEvent {
    var source_events = try allocator.alloc(ast.DottedPath, fused.source_events.len);
    errdefer allocator.free(source_events);

    for (fused.source_events, 0..) |*se, i| {
        source_events[i] = try cloneDottedPath(allocator, se);
    }

    var branches = try allocator.alloc(ast.Branch, fused.branches.len);
    errdefer allocator.free(branches);

    for (fused.branches, 0..) |*branch, i| {
        branches[i] = try cloneBranch(allocator, branch);
    }

    return .{
        .event_path = try cloneDottedPath(allocator, &fused.event_path),
        .source_events = source_events,
        .fused_body = try allocator.dupe(u8, fused.fused_body),
        .input = try cloneShape(allocator, &fused.input),
        .branches = branches,
        .provenance = try allocator.dupe(u8, fused.provenance),
        .location = fused.location,
        .module = try allocator.dupe(u8, fused.module),
    };
}

fn cloneInlinedEvent(allocator: std.mem.Allocator, inlined: *const ast.InlinedEvent) CloneError!ast.InlinedEvent {
    return .{
        .event_path = try cloneDottedPath(allocator, &inlined.event_path),
        .inline_body = try allocator.dupe(u8, inlined.inline_body),
        .original_proc = inlined.original_proc, // Pointer copy - doesn't own the proc
        .inlined_from = try cloneDottedPath(allocator, &inlined.inlined_from),
        .location = inlined.location,
        .module = try allocator.dupe(u8, inlined.module),
    };
}

// ============================================================
// Binding Type Resolution
// ============================================================
// These helpers resolve the types of bindings captured in Source parameters.
// CRITICAL: This relies on transform execution order - transforms must run
// in dependency order (source order) so that when we resolve a binding type,
// any upstream transforms have already run and modified the AST.

/// Result of binding type resolution
pub const ResolvedBinding = struct {
    event_name: []const u8, // Name of the event that produced this binding (e.g., "getUserData")
    branch_name: []const u8, // Branch name that produced this binding (e.g., "data")
    fields: []const ast.Field, // Fields from the branch payload
    module: []const u8, // Module containing the event
};

/// Find the flow that contains a specific invocation by walking the AST
/// This compares invocations by pointer equality (same invocation object in memory)
fn findFlowContainingInvocation(
    program: *const ast.Program,
    target_invocation: *const ast.Invocation,
) ?*const ast.Flow {
    // Walk all items looking for flows
    for (program.items) |*item| {
        if (item.* == .flow) {
            const flow = &item.flow;

            // Check if this flow's top-level invocation matches
            if (flow.inv() == target_invocation) {
                return flow;
            }

            // Check continuations for matching invocation
            if (flowContainsInvocationInContinuations(flow, target_invocation)) {
                return flow;
            }
        }
    }

    return null;
}

/// Recursively check if a flow's continuations contain the target invocation
fn flowContainsInvocationInContinuations(
    flow: *const ast.Flow,
    target_invocation: *const ast.Invocation,
) bool {
    for (flow.body.continuations) |*cont| {
        // Check step
        if (cont.node) |*step| {
            if (step.* == .invocation) {
                if (&step.invocation == target_invocation) {
                    return true;
                }
            }
        }

        // Recursively check nested continuations
        if (continuationContainsInvocation(cont, target_invocation)) {
            return true;
        }
    }

    return false;
}

/// Recursively check if a continuation contains the target invocation
fn continuationContainsInvocation(
    cont: *const ast.Continuation,
    target_invocation: *const ast.Invocation,
) bool {
    for (cont.continuations) |*nested| {
        // Check nested node
        if (nested.node) |*step| {
            if (step.* == .invocation) {
                if (&step.invocation == target_invocation) {
                    return true;
                }
            }
        }

        // Recursively check further nested continuations
        if (continuationContainsInvocation(nested, target_invocation)) {
            return true;
        }
    }

    return false;
}

/// Resolve the type of a binding by walking the program AST
///
/// Given a binding from a continuation (e.g., "u" from "| data u |>"),
/// this function walks the AST to find:
/// 1. Which flow contains the continuation with this binding
/// 2. Which event that flow invokes
/// 3. Which branch produced the binding
/// 4. What fields that branch has
///
/// This is used by transform handlers to get type information about captured bindings.
///
/// IMPORTANT: The binding's `type` field is set to "unknown" by the parser.
/// Type resolution MUST be done by AST walking because:
/// 1. The type depends on what event+branch produced the value
/// 2. That event might itself be a transform that modifies the AST
/// 3. Transforms run in source order, so upstream transforms complete before downstream ones
///
/// Example:
///   ~getUserData()  // Produces { data { name: []const u8, age: i32 } }
///   | data u |> renderHTML [HTML]{ $[u.name] }
///
///   Inside renderHTML's transform handler:
///   const resolved = try resolveBindingType(allocator, binding, invocation, program);
///   // resolved.event_name = "getUserData"
///   // resolved.branch_name = "data"
///   // resolved.fields = [Field{ name="name", type="[]const u8" }, Field{ name="age", type="i32" }]
///
/// Params:
///   allocator: For any temporary allocations during resolution
///   binding: The binding to resolve (from source.scope.bindings)
///   invocation: The invocation that's using this binding (e.g., renderHTML)
///   program: The current program AST (may have been transformed by earlier passes)
///
/// Returns:
///   ResolvedBinding with type information
///
/// Errors:
///   - FlowNotFound: Couldn't find a flow containing this invocation
///   - BindingNotFound: Couldn't find the binding in any continuation
///   - EventNotFound: Couldn't find the event declaration
///   - BranchNotFound: Couldn't find the branch in the event
pub fn resolveBindingType(
    allocator: std.mem.Allocator,
    binding: ast.ScopeBinding,
    invocation: *const ast.Invocation,
    program: *const ast.Program,
) !ResolvedBinding {
    _ = allocator; // For future use if we need temporary allocations

    // Find the flow that contains this invocation
    const containing_flow = findFlowContainingInvocation(program, invocation) orelse return error.FlowNotFound;

    // Find which continuation has this binding
    var target_branch: ?[]const u8 = null;
    for (containing_flow.body.continuations) |cont| {
        if (cont.binding) |b| {
            if (std.mem.eql(u8, b, binding.name)) {
                target_branch = cont.branch;
                break;
            }
        }
    }

    if (target_branch == null) {
        return error.BindingNotFound;
    }

    // The flow's invocation tells us which event produced this binding
    const event_path = containing_flow.inv().path;

    // Find the event declaration in the program
    for (program.items) |item| {
        if (item == .event_decl) {
            const event = item.event_decl;

            // Check if paths match
            if (event.path.segments.len != event_path.segments.len) continue;

            var matches = true;
            for (event.path.segments, event_path.segments) |seg1, seg2| {
                if (!std.mem.eql(u8, seg1, seg2)) {
                    matches = false;
                    break;
                }
            }

            if (!matches) continue;

            // Found the event! Now find the branch
            for (event.branches) |branch| {
                if (std.mem.eql(u8, branch.name, target_branch.?)) {
                    // Found it!
                    return ResolvedBinding{
                        .event_name = event.path.segments[0],
                        .branch_name = branch.name,
                        .fields = branch.payload.fields,
                        .module = event.module,
                    };
                }
            }

            return error.BranchNotFound;
        }
    }

    return error.EventNotFound;
}

/// Collect every invocation reachable inside a continuation tree — plain
/// `.invocation` steps and `#label step(...)` declarations
/// (`label_with_invocation`) alike — into `out`.
pub fn collectContinuedInvocations(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    out: *std.ArrayList(*const ast.Invocation),
) !void {
    if (cont.node) |*n| {
        switch (n.*) {
            .invocation => |*i| try out.append(allocator, i),
            .label_with_invocation => |*lwi| try out.append(allocator, &lwi.invocation),
            else => {},
        }
    }
    for (cont.continuations) |*k| try collectContinuedInvocations(allocator, k, out);
}

/// Collect every continuation whose NODE is an invocation satisfying `match`,
/// descending the whole continuation tree (children of a match included — a
/// site inside a site's arm is still a site). The CONTINUATION is the site,
/// not the node: its `.continuations` are the invocation's arms and its
/// `.location` is the site's own source position — the same view
/// transform_pass_runner's siteView hands the nested site's transform.
/// `is_transformed_subtree` grafts are skipped: a transform-synthesized
/// invocation is generated output, not an authored site.
pub fn collectInvSites(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    context: anytype,
    match: *const fn (context: @TypeOf(context), inv: *const ast.Invocation) bool,
    out: *std.ArrayList(*const ast.Continuation),
) !void {
    for (cont.continuations) |*c| {
        if (c.node) |*n| {
            if (n.* == .invocation and match(context, &n.invocation)) try out.append(allocator, c);
        }
        if (!c.is_transformed_subtree) try collectInvSites(allocator, c, context, match, out);
    }
}

/// True when `arm` reaches an invocation satisfying `match` — spelled in
/// its own continuation tree, or inside a subflow impl it invokes. Impl
/// reachability follows program-level flows whose `impl_of`'s last path
/// segment names the called event, transitively with a visited set.
///
/// The impl match is last-segment only: over-match across modules is the
/// safe direction for a "might this happen" question (a false positive
/// costs the caller its conservative path; a false negative misses a real
/// reachability).
pub fn armReachesInvocation(
    allocator: std.mem.Allocator,
    program_items: []const *const ast.Item,
    arm: *const ast.Continuation,
    context: anytype,
    match: *const fn (context: @TypeOf(context), inv: *const ast.Invocation) bool,
) !bool {
    var visited = std.AutoHashMap(usize, void).init(allocator);
    defer visited.deinit();
    return armReachesInvocationImpl(allocator, program_items, arm, context, match, &visited);
}

fn armReachesInvocationImpl(
    allocator: std.mem.Allocator,
    program_items: []const *const ast.Item,
    arm: *const ast.Continuation,
    context: anytype,
    match: *const fn (context: @TypeOf(context), inv: *const ast.Invocation) bool,
    visited: *std.AutoHashMap(usize, void),
) !bool {
    var invs: std.ArrayList(*const ast.Invocation) = .empty;
    defer invs.deinit(allocator);
    try collectContinuedInvocations(allocator, arm, &invs);
    for (invs.items) |inv| {
        if (match(context, inv)) return true;
        if (inv.path.segments.len == 0) continue;
        const called = inv.path.segments[inv.path.segments.len - 1];
        for (program_items) |pi| {
            if (pi.* != .flow) continue;
            const f = &pi.flow;
            const impl = f.impl_of orelse continue;
            if (impl.segments.len == 0) continue;
            if (!std.mem.eql(u8, impl.segments[impl.segments.len - 1], called)) continue;
            if (visited.contains(@intFromPtr(f))) continue;
            try visited.put(@intFromPtr(f), {});
            if (try armReachesInvocationImpl(allocator, program_items, &f.body, context, match, visited)) return true;
        }
    }
    return false;
}

/// Facet enforcement surface — the shared std/refine machinery a consumer's
/// transform calls at comptime. `std/refine` leaves typed `Item.facet_decl`
/// nodes in the program tree (|pre stage); these helpers resolve which facet
/// governs a proto element, emit the boundary guard, and construct the
/// canonical enforcement branch set. The consumer supplies policy — where
/// its write boundary sits, which extra panic branches it declares — and
/// the protocol lives here: a second consumer enforces by calling, never
/// by re-deriving facet_decl layout or home scoping.
/// The scalar vocabulary — the bases `std/proto` fields accept and the
/// terminal verbs `std/proto:<scalar>(Name)` mints, one list shared by
/// every door and consumer. A terminal verb IS its host scalar:
/// `std/proto:i64(Port)` emits `const Port = i64` and a
/// `// proto-terminal Port: i64` marker.
pub const scalars = [_][]const u8{
    "i8",  "i16",  "i32",  "i64",
    "u8",  "u16",  "u32",  "u64",
    "f32", "f64",  "bool", "string",
};

pub const int_scalars = [_][]const u8{
    "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
};

pub fn isScalar(name: []const u8) bool {
    for (scalars) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

pub fn isIntScalar(name: []const u8) bool {
    for (int_scalars) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Deep-copy a `[]const u8 → []const u8` map's entries into `dst` — duped
/// keys and values owned by `allocator`. Shared by the scope-inherit loops
/// in the checker/inserter.
pub fn dupeStringMapInto(
    allocator: std.mem.Allocator,
    src: std.StringHashMap([]const u8),
    dst: *std.StringHashMap([]const u8),
) !void {
    var it = src.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        try dst.put(key, value);
    }
}

/// Deep-copy a `[]const u8` key-set's members into `dst`.
pub fn dupeKeySetInto(
    allocator: std.mem.Allocator,
    src: std.StringHashMap(void),
    dst: *std.StringHashMap(void),
) !void {
    var it = src.keyIterator();
    while (it.next()) |key| {
        try dst.put(try allocator.dupe(u8, key.*), {});
    }
}

/// Free every key and value string `map` owns, then deinit it.
pub fn freeStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

/// Free every key a key-set map owns, then deinit it.
pub fn freeKeySet(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) void {
    var it = map.keyIterator();
    while (it.next()) |key| {
        allocator.free(key.*);
    }
    map.deinit();
}

/// `"mod:name"`, falling back to `fallback_module` when the parsed state
/// carries no module path of its own.
pub fn qualifiedStateName(allocator: std.mem.Allocator, module_path: ?[]const u8, fallback_module: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ module_path orelse fallback_module, name });
}

pub const facets = struct {
    /// Canonical branch names — the enforcement contract every consumer
    /// shares. `ok` is the sole non-panic terminal a bare `|>` rides;
    /// `violated` is the `?!` a refine guard produces into.
    pub const ok = "ok";
    pub const violated = "violated";

    /// Dotted proto leaf name (`pos.x`) → flat record/param name (`pos_x`).
    pub fn flat(alloc: std.mem.Allocator, fname: []const u8) []const u8 {
        return std.mem.replaceOwned(u8, alloc, fname, ".", "_") catch unreachable;
    }

    /// The type name an `elem` spelling addresses — `home:Name` → `Name`.
    fn elemName(elem: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, elem, " \t");
        return if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |ci|
            std.mem.trim(u8, trimmed[ci + 1 ..], " \t")
        else
            trimmed;
    }

    /// The logical home of `elem`'s proto declaration — the enclosing
    /// module_decl's logical_name, or the entry module for a top-level
    /// decl. A qualified `home:Name` elem answers directly; a bare elem
    /// resolves by scoped walk (flow.module is the file stem, not the
    /// logical home — the same reason refine's scopeOfFlow walks
    /// module_decls).
    pub fn protoHome(prog: *const ast.Program, elem: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, elem, " \t");
        if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |ci| {
            const qual = std.mem.trim(u8, trimmed[0..ci], " \t");
            if (qual.len > 0) {
                return std.mem.replaceOwned(u8, std.heap.page_allocator, qual, "/", ".") catch unreachable;
            }
        }
        const want_name = trimmed;
        const S = struct {
            fn isProtoDoor(f: *const ast.Flow, name: []const u8) bool {
                const inv = f.inv();
                if (inv.path.segments.len != 1) return false;
                const verb = inv.path.segments[0];
                const mq = inv.path.module_qualifier orelse return false;
                const types_door = std.mem.eql(u8, verb, "proto") and
                    (std.mem.eql(u8, mq, "std.types") or std.mem.eql(u8, mq, "std/types"));
                const default_door = std.mem.eql(u8, verb, "default") and
                    (std.mem.eql(u8, mq, "std.proto") or std.mem.eql(u8, mq, "std/proto"));
                if (!(types_door or default_door)) return false;
                if (inv.args.len == 0) return false;
                var nm = inv.args[0].value;
                if (nm.len >= 2 and nm[0] == '"' and nm[nm.len - 1] == '"') nm = nm[1 .. nm.len - 1];
                return std.mem.eql(u8, nm, name);
            }

            fn findIn(items: []const ast.Item, name: []const u8, scope: []const u8, out: *[]const u8) bool {
                for (items) |*pi| {
                    switch (pi.*) {
                        .flow => |*f| {
                            if (isProtoDoor(f, name)) {
                                out.* = scope;
                                return true;
                            }
                        },
                        .module_decl => |*m| {
                            if (findIn(m.items, name, m.logical_name, out)) return true;
                        },
                        else => {},
                    }
                }
                return false;
            }
        };
        var home: []const u8 = "";
        if (S.findIn(prog.items, want_name, prog.main_module_name, &home)) return home;
        return null;
    }

    /// The facet_decl a `std/refine` transform left for `name` in `home` —
    /// the typed inter-transform declaration (Item variant, never text).
    /// `home == null` matches any home — the bare-elem post-erase
    /// fallback: when the proto decl flow is already gone, its `// proto`
    /// marker carries no home to resolve against, so the facet's own
    /// `fd.module` (the declaration's logical home, always present) is
    /// the identity.
    /// The UNIVERSAL facet only (`fd.target == null`) — the read every
    /// existing consumer makes; target-scoped facets are invisible here.
    pub fn find(prog: *const ast.Program, name: []const u8, home: ?[]const u8) ?*const ast.FacetDecl {
        return findInScope(prog, name, home, null);
    }

    /// The facet a `target`-scoped consumer reads: the scope's own
    /// materialized meet when a `|target` refine ran, else the universal
    /// facet (unscoped blocks still govern every target).
    pub fn findFor(prog: *const ast.Program, name: []const u8, home: ?[]const u8, target: []const u8) ?*const ast.FacetDecl {
        return findInScope(prog, name, home, target) orelse find(prog, name, home);
    }

    fn findInScope(prog: *const ast.Program, name: []const u8, home: ?[]const u8, target: ?[]const u8) ?*const ast.FacetDecl {
        const S = struct {
            fn findIn(items: []const ast.Item, n: []const u8, h: ?[]const u8, t: ?[]const u8) ?*const ast.FacetDecl {
                for (items) |*pi| {
                    switch (pi.*) {
                        .facet_decl => |*fd| {
                            const scope_match = if (t) |tt|
                                fd.target != null and std.mem.eql(u8, fd.target.?, tt)
                            else
                                fd.target == null;
                            if (scope_match and std.mem.eql(u8, fd.name, n) and (h == null or std.mem.eql(u8, fd.module, h.?))) return fd;
                        },
                        .module_decl => |*m| {
                            if (findIn(m.items, n, h, t)) |hit| return hit;
                        },
                        else => {},
                    }
                }
                return null;
            }
        };
        return S.findIn(prog.items, name, home, target);
    }

    fn emptyBranch(alloc: std.mem.Allocator, name: []const u8) ast.Branch {
        return ast.Branch{
            .name = alloc.dupe(u8, name) catch unreachable,
            .payload = ast.Shape{ .fields = &.{} },
            .kind = .terminal,
            .annotations = &.{},
        };
    }

    /// `?name` — ignorable terminal; a missing handler synthesizes a no-op.
    pub fn optBranch(alloc: std.mem.Allocator, name: []const u8) ast.Branch {
        var b = emptyBranch(alloc, name);
        b.is_optional = true;
        return b;
    }

    /// `?!name` — panic terminal; a missing handler synthesizes @panic,
    /// a handled one supervises (the store:take precedent).
    pub fn panicBranch(alloc: std.mem.Allocator, name: []const u8) ast.Branch {
        var b = emptyBranch(alloc, name);
        b.is_panic = true;
        return b;
    }

    /// `?!name` carrying a string payload (e.g. `violated` — the offending
    /// field's flat name).
    pub fn panicStrBranch(alloc: std.mem.Allocator, name: []const u8) ast.Branch {
        var b = panicBranch(alloc, name);
        const fields = alloc.alloc(ast.Field, 1) catch unreachable;
        fields[0] = ast.Field{
            .name = alloc.dupe(u8, "__type_ref") catch unreachable,
            .type = alloc.dupe(u8, "string") catch unreachable,
        };
        b.payload = ast.Shape{ .fields = fields };
        return b;
    }

    /// The canonical enforcement branch set: `?ok` + `?!violated string`
    /// + caller-named extra panic branches (e.g. list's `?!oom` — the
    /// extras are consumer policy, not refine's).
    pub fn enforceBranches(alloc: std.mem.Allocator, panic_extras: []const []const u8) []ast.Branch {
        const br = alloc.alloc(ast.Branch, 2 + panic_extras.len) catch unreachable;
        br[0] = optBranch(alloc, ok);
        br[1] = panicStrBranch(alloc, violated);
        for (panic_extras, 0..) |name, i| br[2 + i] = panicBranch(alloc, name);
        return br;
    }

    /// The expression a boundary should test or store for a facet field —
    /// the value's own name, or the saturation expression when the field
    /// carries `& clamp(lo, hi)`. Bounds judge the POST-clamp value
    /// (normalize first, then check), so guards and record writes share
    /// this one spelling.
    ///
    /// `ff` is any facet field — the typed node (`ast.FacetField`) or the
    /// fold's own record (`koru_refine.Field`): same terms, two structs.
    /// The hosts a facet's guard/sink text can spell. A local enum rather
    /// than codegen_utils's HostTarget — importing it would draw the whole
    /// lowering table into a module that only needs three cases.
    pub const FacetHost = enum { zig, js, cs };

    /// `host` picks the host's spelling, so a consumer emitting JavaScript
    /// saturates with JavaScript.
    pub fn normExprFor(alloc: std.mem.Allocator, ff: anytype, name: []const u8, host: FacetHost) []const u8 {
        const c = ff.clamp orelse return name;
        return switch (host) {
            .js => std.fmt.allocPrint(alloc, "Math.min(Math.max({s}, {d}), {d})", .{ name, c.lo, c.hi }) catch unreachable,
            .cs => std.fmt.allocPrint(alloc, "global::System.Math.Min(global::System.Math.Max({s}, {d}L), {d}L)", .{ name, c.lo, c.hi }) catch unreachable,
            .zig => std.fmt.allocPrint(alloc, "@min(@max({s}, {d}), {d})", .{ name, c.lo, c.hi }) catch unreachable,
        };
    }

    /// True when a field carries a term a boundary can JUDGE — the question
    /// `predicate` answers, asked without building the text. A clamp alone is
    /// not one: it rewrites the value, it does not rule on it. Every site
    /// asks here, so a new atom kind cannot reach one boundary and miss
    /// another (`std/store`'s own prelude asks it too — finding that it did
    /// not is what made this a function).
    pub fn hasTerms(ff: anytype) bool {
        return ff.lo != null or ff.hi != null or ff.eq != null or ff.alts != null;
    }

    /// The judgeable predicate for one met field — null when the field
    /// carries no term a boundary can test. `expr` is what to test, already
    /// rendered for the host and already normalized by `normExprFor`.
    ///
    /// This is the ONE home for the rule "what does this facet require of a
    /// value". Every consumer's guard comes through here — the list's
    /// synthesized `push` and the store's insert prelude both do — so a new
    /// atom kind cannot reach one boundary and miss another, and the two
    /// enforcers cannot disagree about what a field's facet says.
    pub fn predicate(alloc: std.mem.Allocator, ff: anytype, expr: []const u8, host: FacetHost) ?[]const u8 {
        const alts: ?[]const i64 = ff.alts;
        const has_alts = alts != null and alts.?.len > 0;
        if (!hasTerms(ff)) return null;
        const conj = if (host == .zig) " and " else " && ";
        var cond = std.ArrayList(u8).initCapacity(alloc, 64) catch unreachable;
        if (has_alts) {
            // Membership: the met set is the reachable values for this field,
            // so a boundary admits exactly its members.
            cond.appendSlice(alloc, "(") catch unreachable;
            for (alts.?, 0..) |v, i| {
                if (i > 0) cond.appendSlice(alloc, if (host == .zig) " or " else " || ") catch unreachable;
                cond.appendSlice(alloc, std.fmt.allocPrint(alloc, "{s} == {d}", .{ expr, v }) catch unreachable) catch unreachable;
            }
            cond.appendSlice(alloc, ")") catch unreachable;
        }
        if (ff.eq) |b| {
            if (cond.items.len > 0) cond.appendSlice(alloc, conj) catch unreachable;
            cond.appendSlice(alloc, std.fmt.allocPrint(alloc, "{s} == {d}", .{ expr, b.value }) catch unreachable) catch unreachable;
        } else {
            if (ff.lo) |b| {
                if (cond.items.len > 0) cond.appendSlice(alloc, conj) catch unreachable;
                cond.appendSlice(alloc, std.fmt.allocPrint(alloc, "{s} {s} {d}", .{ expr, if (b.exclusive) ">" else ">=", b.value }) catch unreachable) catch unreachable;
            }
            if (ff.hi) |b| {
                if (cond.items.len > 0) cond.appendSlice(alloc, conj) catch unreachable;
                cond.appendSlice(alloc, std.fmt.allocPrint(alloc, "{s} {s} {d}", .{ expr, if (b.exclusive) "<" else "<=", b.value }) catch unreachable) catch unreachable;
            }
        }
        return cond.items;
    }

    /// The write-side expression for a proto field of `elem` — the flat
    /// name, or the clamped expression when the facet normalizes it. A
    /// consumer embeds this where the value lands (list's record init);
    /// unclamped fields get the flat name back, so the call is free.
    pub fn valueExpr(
        alloc: std.mem.Allocator,
        prog: *const ast.Program,
        elem: []const u8,
        field_name: []const u8,
    ) []const u8 {
        const base = flat(alloc, field_name);
        const fd = find(prog, elemName(elem), protoHome(prog, elem)) orelse return base;
        for (fd.fields) |*ff| {
            if (std.mem.eql(u8, flat(alloc, ff.name), base)) return normExprFor(alloc, ff, base, .zig);
        }
        return base;
    }

    /// Prepend per-field bounds guards to `body`: for every refined field,
    /// `if (!(cond)) { return .{ .violated = "<field>" }; }` — the
    /// condition tests the normalized expression, so a clamped field's
    /// bounds judge the value that will actually be stored. A violation
    /// produces into the `?!violated` panic branch — unhandled it is the
    /// same synthesized @panic, handled it supervises. Returns `body`
    /// unchanged when the element type carries no facet.
    pub fn guardBody(
        alloc: std.mem.Allocator,
        prog: *const ast.Program,
        elem: []const u8,
        body: []const u8,
    ) []const u8 {
        // Home is advisory: qualified elems and live decls pin it; an erased
        // decl leaves only the marker, so a bare elem falls back to
        // name-only (the proto marker read's own rule).
        const home = protoHome(prog, elem);
        const fd = find(prog, elemName(elem), home) orelse return body;

        var out = std.ArrayList(u8).initCapacity(alloc, 128) catch unreachable;
        for (fd.fields) |*ff| {
            const pname = flat(alloc, ff.name);
            const vname = normExprFor(alloc, ff, pname, .zig);
            const cond = predicate(alloc, ff, vname, .zig) orelse continue;
            const guard = std.fmt.allocPrint(
                alloc,
                "if (!({s})) {{\n    return .{{ .{s} = \"{s}\" }};\n}}\n",
                .{ cond, violated, pname },
            ) catch unreachable;
            out.appendSlice(alloc, guard) catch unreachable;
        }
        out.appendSlice(alloc, body) catch unreachable;
        return out.items;
    }
};

/// One segment of a record `{ ... }` text — a record type's `name: type`
/// pair or a produce literal's `name: value` / pun `name`.
pub const RecordFieldText = struct {
    name: []const u8,
    value: []const u8,
};

/// Split a `{ ... }` text — a record type (`{ h: *H<owned!>, n: i64 }`) or a
/// produce literal (`{ h, f: x }`) — into top-level `name: value` segments.
/// A segment with no `:` is a pun: the field takes the trailing identifier
/// (`{ rec.moved }` is field `moved` fed by `rec.moved`). Commas nested
/// inside `<...>`, `{...}`, `[...]`, `(...)` do not split. Returns null when
/// the text is not a `{...}` group. The returned slice is caller-owned; the
/// segment strings borrow from `record_text`.
pub fn recordFieldTexts(allocator: std.mem.Allocator, record_text: []const u8) !?[]RecordFieldText {
    const trimmed = std.mem.trim(u8, record_text, " \t");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;
    const inner = trimmed[1 .. trimmed.len - 1];
    var fields = std.ArrayList(RecordFieldText).empty;
    errdefer fields.deinit(allocator);
    var seg_start: usize = 0;
    var depth: i32 = 0;
    var i: usize = 0;
    while (i <= inner.len) : (i += 1) {
        const at_end = i == inner.len;
        const c = if (at_end) ',' else inner[i];
        switch (c) {
            '<', '{', '[', '(' => depth += 1,
            '>', '}', ']', ')' => depth -= 1,
            else => {},
        }
        if (!(at_end or (c == ',' and depth == 0))) continue;
        const seg = std.mem.trim(u8, inner[seg_start..i], " \t");
        seg_start = i + 1;
        if (seg.len == 0) continue;
        if (std.mem.indexOfScalar(u8, seg, ':')) |colon| {
            try fields.append(allocator, .{
                .name = std.mem.trim(u8, seg[0..colon], " \t"),
                .value = std.mem.trim(u8, seg[colon + 1 ..], " \t"),
            });
        } else {
            var name = seg;
            if (std.mem.lastIndexOfScalar(u8, seg, '.')) |dot| name = seg[dot + 1 ..];
            try fields.append(allocator, .{ .name = name, .value = seg });
        }
    }
    return try fields.toOwnedSlice(allocator);
}
