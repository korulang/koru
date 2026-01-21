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

/// Map a transformation function over all items in a Program
/// Returns a new Program with transformed items
pub fn mapItems(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    transform_fn: fn (allocator: std.mem.Allocator, item: *const ast.Item) anyerror!ast.Item,
) !ast.Program {
    var new_items = try allocator.alloc(ast.Item, source.items.len);
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

    for (source.items, 0..) |*item, i| {
        new_items[i] = try transform_fn(allocator, item);
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = try filtered.toOwnedSlice(allocator),
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

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
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
        // Clone module_annotations
        var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
        for (source.module_annotations, 0..) |annotation, i| {
            new_annotations[i] = try allocator.dupe(u8, annotation);
        }

        return ast.Program{
            .items = result.items,
            .module_annotations = new_annotations,
            .main_module_name = try allocator.dupe(u8, source.main_module_name),
            .allocator = allocator,
        };
    }
    return null;
}

const ReplaceResult = struct {
    found: bool,
    items: []ast.Item,
};

fn replaceFlowInItems(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    target_flow: *const ast.Flow,
    new_item: ast.Item,
) !ReplaceResult {
    var new_items = try allocator.alloc(ast.Item, items.len);
    var found = false;

    for (items, 0..) |*item, i| {
        if (item.* == .flow and @intFromPtr(&item.flow) == @intFromPtr(target_flow)) {
            // Found the target flow - replace it
            new_items[i] = new_item;
            found = true;
        } else if (item.* == .subflow_impl and item.subflow_impl.body == .flow and
            @intFromPtr(&item.subflow_impl.body.flow) == @intFromPtr(target_flow))
        {
            // Found target flow inside subflow_impl
            // Check if caller already wrapped in subflow_impl (transforms do this)
            if (new_item == .subflow_impl) {
                // Caller already created proper subflow_impl wrapper - use it directly
                new_items[i] = new_item;
            } else if (new_item == .flow) {
                // Caller passed bare flow - wrap it preserving original metadata
                const orig = &item.subflow_impl;
                new_items[i] = ast.Item{
                    .subflow_impl = ast.SubflowImpl{
                        .event_path = try cloneDottedPath(allocator, &orig.event_path),
                        .body = .{ .flow = new_item.flow },
                        .is_impl = orig.is_impl,
                        .location = orig.location,
                        .module = try allocator.dupe(u8, orig.module),
                    },
                };
            } else {
                // Unexpected item type - clone original
                new_items[i] = try cloneItem(allocator, item);
                continue;
            }
            found = true;
        } else if (item.* == .module_decl) {
            // Recursively search inside module_decl
            const mod = &item.module_decl;
            const sub_result = try replaceFlowInItems(allocator, mod.items, target_flow, new_item);
            if (sub_result.found) {
                // Create new module_decl with replaced items
                new_items[i] = ast.Item{
                    .module_decl = ast.ModuleDecl{
                        .logical_name = try allocator.dupe(u8, mod.logical_name),
                        .canonical_path = try allocator.dupe(u8, mod.canonical_path),
                        .items = sub_result.items,
                        .is_system = mod.is_system,
                        .annotations = try cloneStringSlice(allocator, mod.annotations),
                        .location = mod.location,
                    },
                };
                found = true;
            } else {
                // Not found - clone the item
                new_items[i] = try cloneItem(allocator, item);
            }
        } else {
            // Clone the item unchanged
            new_items[i] = try cloneItem(allocator, item);
        }
    }

    return ReplaceResult{ .found = found, .items = new_items };
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
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len + 1) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

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
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len - 1) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

    // Copy items before removal point
    for (source.items[0..index], 0..) |*item, i| {
        new_items[i] = try cloneItem(allocator, item);
    }

    // Copy items after removal point
    for (source.items[index + 1..], 0..) |*item, i| {
        new_items[index + i] = try cloneItem(allocator, item);
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

    for (source.items, 0..) |*item, i| {
        if (predicate(item)) {
            new_items[i] = try transform_fn(allocator, item);
        } else {
            new_items[i] = try cloneItem(allocator, item);
        }
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

    for (source.items, 0..) |*item, i| {
        if (predicate(item)) {
            new_items[i] = try transform_fn(context, allocator, item);
        } else {
            new_items[i] = try cloneItem(allocator, item);
        }
    }

    // Clone module_annotations (preserve from source)
    var new_annotations = try allocator.alloc([]const u8, source.module_annotations.len);
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
    for (source.module_annotations, 0..) |annotation, i| {
        new_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        .type_registry = null,
    };
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
    errdefer {
        for (new_items[0..], 0..) |*item, i| {
            if (i >= source.items.len) break;
            item.deinit(allocator);
        }
        allocator.free(new_items);
    }

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

    return ast.Program{
        .items = new_items,
        .module_annotations = new_annotations,
        .main_module_name = try allocator.dupe(u8, source.main_module_name),
        .allocator = allocator,
        // Cloned Programs don't inherit registry - transforms can build/clone if needed
        .type_registry = null,
    };
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
        .subflow_impl => |subflow| {
            return .{ .subflow_impl = try cloneSubflowImpl(allocator, &subflow) };
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
        .is_public = event.is_public,
        .is_implicit_flow = event.is_implicit_flow,
        .is_abstract = event.is_abstract,
        .annotations = annotations,
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

    // Clone inline flows
    var inline_flows = try allocator.alloc(ast.Flow, proc.inline_flows.len);
    for (proc.inline_flows, 0..) |flow, i| {
        inline_flows[i] = try cloneFlow(allocator, &flow);
    }

    return .{
        .path = try cloneDottedPath(allocator, &proc.path),
        .body = try allocator.dupe(u8, proc.body),
        .inline_flows = inline_flows,
        .annotations = annotations,
        .target = if (proc.target) |t| try allocator.dupe(u8, t) else null,
        .is_impl = proc.is_impl,
        .is_pure = proc.is_pure,
        .is_transitively_pure = proc.is_transitively_pure,
        .location = proc.location,
        .module = try allocator.dupe(u8, proc.module),
    };
}

fn cloneFlow(allocator: std.mem.Allocator, flow: *const ast.Flow) CloneError!ast.Flow {
    var continuations = try allocator.alloc(ast.Continuation, flow.continuations.len);
    errdefer allocator.free(continuations);

    for (flow.continuations, 0..) |*cont, i| {
        continuations[i] = try cloneContinuation(allocator, cont);
    }

    return .{
        .invocation = try cloneInvocation(allocator, &flow.invocation),
        .continuations = continuations,
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .post_label = if (flow.post_label) |l| try allocator.dupe(u8, l) else null,
        .super_shape = null, // TODO: clone super_shape if needed
        .inline_body = if (flow.inline_body) |body| try allocator.dupe(u8, body) else null,
        .preamble_code = if (flow.preamble_code) |preamble| try allocator.dupe(u8, preamble) else null,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .location = flow.location,
        .module = try allocator.dupe(u8, flow.module),
        .annotations = try cloneStringSlice(allocator, flow.annotations),
    };
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

fn cloneSubflowImpl(allocator: std.mem.Allocator, subflow: *const ast.SubflowImpl) !ast.SubflowImpl {
    return .{
        .event_path = try cloneDottedPath(allocator, &subflow.event_path),
        .body = try cloneSubflowBody(allocator, &subflow.body),
        .is_impl = subflow.is_impl,
        .location = subflow.location,
        .module = try allocator.dupe(u8, subflow.module),
    };
}

fn cloneSubflowBody(allocator: std.mem.Allocator, body: *const ast.SubflowBody) !ast.SubflowBody {
    switch (body.*) {
        .flow => |flow| {
            return .{ .flow = try cloneFlow(allocator, &flow) };
        },
        .immediate => |bc| {
            return .{ .immediate = try cloneBranchConstructor(allocator, &bc) };
        },
    }
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

fn cloneDottedPath(allocator: std.mem.Allocator, path: *const ast.DottedPath) !ast.DottedPath {
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

    return .{ .fields = fields };
}

fn cloneField(allocator: std.mem.Allocator, field: *const ast.Field) !ast.Field {
    return .{
        .name = try allocator.dupe(u8, field.name),
        .type = try allocator.dupe(u8, field.type),
        .module_path = if (field.module_path) |mp| try allocator.dupe(u8, mp) else null,
        .phantom = if (field.phantom) |p| try allocator.dupe(u8, p) else null,
        .is_source = field.is_source,
        .is_file = field.is_file,
        .is_embed_file = field.is_embed_file,
        .is_expression = field.is_expression,
        .expression = field.expression,  // Pointer copy - original persists
        .expression_str = if (field.expression_str) |e| try allocator.dupe(u8, e) else null,
        .owns_expression = false,  // Cloned fields don't own the expression
    };
}

fn cloneBranch(allocator: std.mem.Allocator, branch: *const ast.Branch) !ast.Branch {
    // Clone annotations array
    var cloned_annotations = try allocator.alloc([]const u8, branch.annotations.len);
    errdefer allocator.free(cloned_annotations);
    for (branch.annotations, 0..) |annotation, i| {
        cloned_annotations[i] = try allocator.dupe(u8, annotation);
    }

    return .{
        .name = try allocator.dupe(u8, branch.name),
        .payload = try cloneShape(allocator, &branch.payload),
        .is_deferred = branch.is_deferred,
        .is_optional = branch.is_optional,
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

    return .{
        .path = try cloneDottedPath(allocator, &invocation.path),
        .args = args,
        .annotations = annotations,
        .inserted_by_tap = invocation.inserted_by_tap,
        .from_opaque_tap = invocation.from_opaque_tap,
        .source_module = if (invocation.source_module.len > 0)
            try allocator.dupe(u8, invocation.source_module)
        else
            "",
    };
}

fn cloneArg(allocator: std.mem.Allocator, arg: *const ast.Arg) CloneError!ast.Arg {
    // Copy pointers for source_value and expression_value - the original data
    // in PROGRAM_AST persists, so pointer copies are safe for read-only access
    return .{
        .name = try allocator.dupe(u8, arg.name),
        .value = try allocator.dupe(u8, arg.value),
        .source_value = arg.source_value,
        .expression_value = arg.expression_value,
    };
}

pub fn cloneContinuation(allocator: std.mem.Allocator, cont: *const ast.Continuation) CloneError!ast.Continuation {
    const cloned_step = if (cont.node) |*step| try cloneStep(allocator, step) else null;

    var continuations = try allocator.alloc(ast.Continuation, cont.continuations.len);
    errdefer allocator.free(continuations);

    for (cont.continuations, 0..) |*n, i| {
        continuations[i] = try cloneContinuation(allocator, n);
    }

    // Clone binding annotations
    var binding_annotations = try allocator.alloc([]const u8, cont.binding_annotations.len);
    errdefer allocator.free(binding_annotations);
    for (cont.binding_annotations, 0..) |ann, i| {
        binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    return .{
        .branch = try allocator.dupe(u8, cont.branch),
        .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
        .binding_annotations = binding_annotations,
        .binding_type = cont.binding_type,
        .is_catchall = cont.is_catchall,
        .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
        .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
        .condition_expr = cont.condition_expr, // Pointer copy for now
        .node = cloned_step,
        .indent = cont.indent,
        .continuations = continuations,
        .location = cont.location,
    };
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
            }};
        },
        .label_jump => |lj| {
            var cloned_args = try allocator.alloc(ast.Arg, lj.args.len);
            for (lj.args, 0..) |*arg, i| {
                cloned_args[i] = try cloneArg(allocator, arg);
            }
            return .{ .label_jump = .{
                .label = try allocator.dupe(u8, lj.label),
                .args = cloned_args,
            }};
        },
        .terminal => {
            return .terminal;
        },
        .deref => |d| {
            const args = if (d.args) |a| blk: {
                var cloned_args = try allocator.alloc(ast.Arg, a.len);
                for (a, 0..) |*arg, i| {
                    cloned_args[i] = try cloneArg(allocator, arg);
                }
                break :blk cloned_args;
            } else null;

            return .{ .deref = .{
                .target = try allocator.dupe(u8, d.target),
                .args = args,
            }};
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

            return .{ .conditional_block = .{
                .condition = if (cb.condition) |c| try allocator.dupe(u8, c) else null,
                .condition_expr = cb.condition_expr, // Expression cloning is complex, for now just copy pointer
                .nodes = cloned_nodes,
            }};
        },
        .metatype_binding => |mb| {
            // Clone metatype binding (Profile/Transition/Audit struct construction)
            return .{ .metatype_binding = .{
                .metatype = try allocator.dupe(u8, mb.metatype),
                .binding = try allocator.dupe(u8, mb.binding),
                .source_event = try allocator.dupe(u8, mb.source_event),
                .dest_event = if (mb.dest_event) |dest| try allocator.dupe(u8, dest) else null,
                .branch = try allocator.dupe(u8, mb.branch),
            }};
        },
        .inline_code => |code| {
            return .{ .inline_code = try allocator.dupe(u8, code) };
        },
        .foreach => |fe| {
            // Clone foreach - uses uniform NamedBranch structure
            return .{ .foreach = .{
                .iterable = try allocator.dupe(u8, fe.iterable),
                .element_type = if (fe.element_type) |et| try allocator.dupe(u8, et) else null,
                .branches = try cloneNamedBranches(allocator, fe.branches),
            }};
        },
        .conditional => |cond| {
            // Clone conditional - uses uniform NamedBranch structure
            return .{ .conditional = .{
                .condition = try allocator.dupe(u8, cond.condition),
                .condition_expr = cond.condition_expr, // Expression cloning is complex, for now just copy pointer
                .branches = try cloneNamedBranches(allocator, cond.branches),
            }};
        },
        .capture => |cap| {
            // Clone capture - uses uniform NamedBranch structure
            return .{ .capture = .{
                .init_expr = try allocator.dupe(u8, cap.init_expr),
                .branches = try cloneNamedBranches(allocator, cap.branches),
            }};
        },
        .switch_result => |sr| {
            // Clone switch_result - uses uniform NamedBranch structure
            return .{ .switch_result = .{
                .expression = try allocator.dupe(u8, sr.expression),
                .branches = try cloneNamedBranches(allocator, sr.branches),
            }};
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
            }};
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
    };
}

fn cloneNamedBranch(allocator: std.mem.Allocator, branch: *const ast.NamedBranch) CloneError!ast.NamedBranch {
    var cloned_body = try allocator.alloc(ast.Continuation, branch.body.len);
    errdefer allocator.free(cloned_body);

    for (branch.body, 0..) |*cont, i| {
        cloned_body[i] = try cloneContinuation(allocator, cont);
    }

    // Clone annotations (critical for @scope and other branch-level annotations)
    var cloned_annotations = try allocator.alloc([]const u8, branch.annotations.len);
    for (branch.annotations, 0..) |ann, i| {
        cloned_annotations[i] = try allocator.dupe(u8, ann);
    }

    return .{
        .name = try allocator.dupe(u8, branch.name),
        .body = cloned_body,
        .binding = if (branch.binding) |b| try allocator.dupe(u8, b) else null,
        .is_optional = branch.is_optional,
        .annotations = cloned_annotations,
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
    var new_continuations = try allocator.alloc(ast.Continuation, flow.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.continuations, 0..) |*cont, i| {
        if (i == cont_idx) {
            // This is the continuation to modify - clone with replaced step
            new_continuations[i] = try cloneContinuationWithReplacedStep(allocator, cont, step_idx, new_step);
        } else {
            // Clone unchanged
            new_continuations[i] = try cloneContinuation(allocator, cont);
        }
    }

    // Clone the rest of the flow
    return ast.Flow{
        .invocation = try cloneInvocation(allocator, &flow.invocation),
        .continuations = new_continuations,
        .annotations = try cloneStringSlice(allocator, flow.annotations),
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .post_label = if (flow.post_label) |l| try allocator.dupe(u8, l) else null,
        .super_shape = null, // TODO: clone if needed
        .inline_body = if (flow.inline_body) |body| try allocator.dupe(u8, body) else null,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .location = flow.location,
        .module = try allocator.dupe(u8, flow.module),
    };
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

    // Clone binding annotations
    var binding_annotations = try allocator.alloc([]const u8, cont.binding_annotations.len);
    errdefer allocator.free(binding_annotations);
    for (cont.binding_annotations, 0..) |ann, i| {
        binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    return ast.Continuation{
        .branch = try allocator.dupe(u8, cont.branch),
        .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
        .binding_annotations = binding_annotations,
        .binding_type = cont.binding_type,
        .is_catchall = cont.is_catchall,
        .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
        .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
        .condition_expr = cont.condition_expr, // Pointer copy for now
        .node = replaced_step,
        .indent = cont.indent,
        .continuations = new_continuations,
    };
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
    var new_continuations = try allocator.alloc(ast.Continuation, flow.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.continuations, 0..) |*cont, i| {
        if (i == cont_idx) {
            // This is the continuation to modify - clone with filtered nested
            new_continuations[i] = try cloneContinuationWithFilteredNested(allocator, cont, keep_fn);
        } else {
            // Clone unchanged
            new_continuations[i] = try cloneContinuation(allocator, cont);
        }
    }

    // Clone the rest of the flow
    return ast.Flow{
        .invocation = try cloneInvocation(allocator, &flow.invocation),
        .continuations = new_continuations,
        .annotations = try cloneStringSlice(allocator, flow.annotations),
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .post_label = if (flow.post_label) |l| try allocator.dupe(u8, l) else null,
        .super_shape = null,
        .inline_body = if (flow.inline_body) |body| try allocator.dupe(u8, body) else null,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .location = flow.location,
        .module = try allocator.dupe(u8, flow.module),
    };
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

    // Clone binding annotations
    var binding_annotations = try allocator.alloc([]const u8, cont.binding_annotations.len);
    errdefer allocator.free(binding_annotations);
    for (cont.binding_annotations, 0..) |ann, i| {
        binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    return ast.Continuation{
        .branch = try allocator.dupe(u8, cont.branch),
        .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
        .binding_annotations = binding_annotations,
        .binding_type = cont.binding_type,
        .is_catchall = cont.is_catchall,
        .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
        .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
        .condition_expr = cont.condition_expr,
        .node = cloned_step,
        .indent = cont.indent,
        .continuations = new_continuations,
    };
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
//   path = [0]      -> flow.continuations[0]
//   path = [0, 1]   -> flow.continuations[0].continuations[1]
//   path = [0, 1, 2] -> flow.continuations[0].continuations[1].continuations[2]

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
    var new_continuations = try allocator.alloc(ast.Continuation, flow.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.continuations, 0..) |*cont, i| {
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

    return ast.Flow{
        .invocation = try cloneInvocation(allocator, &flow.invocation),
        .continuations = new_continuations,
        .annotations = try cloneStringSlice(allocator, flow.annotations),
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .post_label = if (flow.post_label) |l| try allocator.dupe(u8, l) else null,
        .super_shape = null,
        .inline_body = if (flow.inline_body) |body| try allocator.dupe(u8, body) else null,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .location = flow.location,
        .module = try allocator.dupe(u8, flow.module),
    };
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

    // Clone binding annotations
    var binding_annotations = try allocator.alloc([]const u8, cont.binding_annotations.len);
    errdefer allocator.free(binding_annotations);
    for (cont.binding_annotations, 0..) |ann, i| {
        binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    return ast.Continuation{
        .branch = try allocator.dupe(u8, cont.branch),
        .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
        .binding_annotations = binding_annotations,
        .binding_type = cont.binding_type,
        .is_catchall = cont.is_catchall,
        .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
        .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
        .condition_expr = cont.condition_expr,
        .node = cloned_step,
        .indent = cont.indent,
        .continuations = new_continuations,
    };
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

    var new_continuations = try allocator.alloc(ast.Continuation, flow.continuations.len);
    errdefer allocator.free(new_continuations);

    for (flow.continuations, 0..) |*cont, i| {
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

    return ast.Flow{
        .invocation = try cloneInvocation(allocator, &flow.invocation),
        .continuations = new_continuations,
        .annotations = try cloneStringSlice(allocator, flow.annotations),
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .post_label = if (flow.post_label) |l| try allocator.dupe(u8, l) else null,
        .super_shape = null,
        .inline_body = if (flow.inline_body) |body| try allocator.dupe(u8, body) else null,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .location = flow.location,
        .module = try allocator.dupe(u8, flow.module),
    };
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

    // Clone binding annotations
    var binding_annotations = try allocator.alloc([]const u8, cont.binding_annotations.len);
    errdefer allocator.free(binding_annotations);
    for (cont.binding_annotations, 0..) |ann, i| {
        binding_annotations[i] = try allocator.dupe(u8, ann);
    }

    return ast.Continuation{
        .branch = try allocator.dupe(u8, cont.branch),
        .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
        .binding_annotations = binding_annotations,
        .binding_type = cont.binding_type,
        .is_catchall = cont.is_catchall,
        .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
        .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
        .condition_expr = cont.condition_expr,
        .node = cloned_step,
        .indent = cont.indent,
        .continuations = new_continuations,
    };
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
                .module_decl,
                .flow,
                .event_tap,
                .label_decl,
                .subflow_impl,
                .import_decl,
                .host_line,
                .host_type_decl => return true,
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
    errdefer {
        for (new_annotations) |annotation| {
            allocator.free(annotation);
        }
        allocator.free(new_annotations);
    }
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
    for (flow.continuations) |*cont| {
        if (std.mem.eql(u8, cont.branch, branch_name)) {
            return cont;
        }
    }
    return null;
}

/// Get all continuation branches from a flow (cloned)
/// Returns a new array containing clones of all continuations
/// Caller owns the returned slice and must free it with allocator.free() after deinit'ing each continuation
pub fn getAllContinuations(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
) ![]ast.Continuation {
    var continuations = try allocator.alloc(ast.Continuation, flow.continuations.len);
    errdefer allocator.free(continuations);

    for (flow.continuations, 0..) |*cont, i| {
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
        .invocation = invocation,
        .continuations = cloned_conts,
        .pre_label = null,
        .post_label = null,
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

/// Create a subflow implementation
/// Used to generate subflow definitions from extracted continuation branches
/// Example:
///   const subflow = try createSubflowImpl(allocator, event_path, flow, "main");
pub fn createSubflowImpl(
    allocator: std.mem.Allocator,
    event_path: ast.DottedPath,
    body_flow: ast.Flow,
    module: []const u8,
) !ast.SubflowImpl {
    return ast.SubflowImpl{
        .event_path = event_path,
        .body = .{ .flow = body_flow },
        .location = .{ .line = 0, .column = 0, .file = "" }, // Generated code
        .module = try allocator.dupe(u8, module),
    };
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
// Continuation Extraction
// ============================================================
// These helpers extract continuation branches as standalone flows.
// Critical for threading - converting continuation branches into callable subflows.

/// Extract a continuation branch as a standalone Flow
/// Converts | run |> worker(x: 1) | done |> _ into a Flow that can be wrapped in SubflowImpl
///
/// Example:
///   const run_cont = findContinuationByBranch(flow, "run");
///   const extracted_flow = try extractContinuationAsFlow(allocator, run_cont, "main");
///   // extracted_flow can now be used to create a subflow
///
/// Limitations:
///   - Currently only supports continuations with a single invocation in the pipeline
///   - Complex pipelines with multiple steps are not yet supported
pub fn extractContinuationAsFlow(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
    module: []const u8,
) !ast.Flow {
    // Check that step exists and is an invocation
    const step = continuation.node orelse return error.ComplexPipelineNotSupported;

    const invocation = switch (step) {
        .invocation => |inv| inv,
        else => return error.PipelineNotInvocation,
    };

    // Clone the invocation
    const cloned_inv = try cloneInvocation(allocator, &invocation);

    // Clone continuations - these become the flow's continuations
    var cloned_continuations = try allocator.alloc(ast.Continuation, continuation.continuations.len);
    errdefer allocator.free(cloned_continuations);

    for (continuation.continuations, 0..) |*nested, i| {
        cloned_continuations[i] = try cloneContinuation(allocator, nested);
    }

    return ast.Flow{
        .invocation = cloned_inv,
        .continuations = cloned_continuations,
        .pre_label = null,
        .post_label = null,
        .super_shape = null,
        .is_pure = true,
        .is_transitively_pure = false,
        .location = .{ .line = 0, .column = 0, .file = "" }, // Generated/extracted code
        .module = try allocator.dupe(u8, module),
    };
}

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
            .is_deferred = false,
            .is_optional = false,
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
    event_name: []const u8,     // Name of the event that produced this binding (e.g., "getUserData")
    branch_name: []const u8,    // Branch name that produced this binding (e.g., "data")
    fields: []const ast.Field,  // Fields from the branch payload
    module: []const u8,         // Module containing the event
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
            if (&flow.invocation == target_invocation) {
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
    for (flow.continuations) |*cont| {
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
    for (containing_flow.continuations) |cont| {
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
    const event_path = containing_flow.invocation.path;

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
