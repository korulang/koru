const std = @import("std");
const ast = @import("ast");

// =============================================================================
// Abstract/Impl Resolution Pass
// =============================================================================
//
// Simple rename-based resolution for abstract events:
//
// 1. Find events with [abstract] annotation
// 2. Find default implementation (same module as abstract)
// 3. Find override implementation (different module)
// 4. If both exist: rename default to `event.default`
//
// That's it! No magic self-call detection. User explicitly calls `.default`.
//
// Rules:
// - Neither default nor override: error if invoked
// - Default only: default IS the handler (no rename)
// - Override only: override IS the handler
// - Both: override is handler, default renamed to `.default`
//
// =============================================================================

pub const Error = error{
    OutOfMemory,
    AbstractEventNotImplemented,
};

/// Run the resolution pass on the program
/// This mutates the AST: renames defaults to `.default` when overrides exist
pub fn resolve(program: *ast.Program, allocator: std.mem.Allocator) Error!void {
    var ctx = ResolveContext{
        .allocator = allocator,
        .all_items = program.items,
    };

    // Process all items, recursing into modules
    // Use main_module_name for top-level events (allows ~main:event = ... syntax)
    try resolveItems(program.items, &ctx, program.main_module_name);

    // TODO: Report errors if any abstract events are invoked but not implemented
    _ = &ctx;
}

const ResolveContext = struct {
    allocator: std.mem.Allocator,
    all_items: []const ast.Item,
};

fn resolveItems(
    items: []const ast.Item,
    ctx: *ResolveContext,
    current_module: ?[]const u8,
) Error!void {
    for (@constCast(items)) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                if (isAbstract(event)) {
                    try resolveAbstractEvent(event, items, ctx, current_module);
                }
            },
            .module_decl => |*module| {
                // Recurse into module
                try resolveItems(module.items, ctx, module.logical_name);
            },
            else => {},
        }
    }
}

/// Check if an event has the [abstract] annotation
fn isAbstract(event: *const ast.EventDecl) bool {
    for (event.annotations) |ann| {
        if (std.mem.eql(u8, ann, "abstract")) return true;
    }
    return false;
}

fn resolveAbstractEvent(
    event: *ast.EventDecl,
    module_items: []const ast.Item,
    ctx: *ResolveContext,
    current_module: ?[]const u8,
) Error!void {
    const event_name = if (event.path.segments.len > 0) event.path.segments[0] else return;

    // Find default implementation (same module)
    const default_impl = findDefaultImpl(module_items, event_name, current_module);

    // Find override implementation (cross-module, in top-level items)
    const has_override = hasOverrideImpl(ctx.all_items, event, current_module);

    // Apply resolution rules
    if (default_impl == null and !has_override) {
        // Neither - will error if invoked (handled elsewhere)
        return;
    }

    if (default_impl != null and !has_override) {
        // Default only - default IS the handler, no rename needed
        return;
    }

    if (default_impl == null and has_override) {
        // Override only - override IS the handler, no rename needed
        return;
    }

    // BOTH exist - rename default to `.default`
    if (default_impl) |default| {
        try renameToDefault(default, event_name, ctx.allocator);
    }
}

/// Find the default implementation in the same module
/// Default impl is either:
/// - No module_qualifier (local reference in source)
/// - Module_qualifier matches current_module (canonicalized to same module)
/// Returns pointer to the Item (either proc_decl or subflow_impl)
fn findDefaultImpl(items: []const ast.Item, event_name: []const u8, current_module: ?[]const u8) ?*ast.Item {
    for (@constCast(items)) |*item| {
        switch (item.*) {
            .proc_decl => |proc| {
                if (proc.path.segments.len > 0 and std.mem.eql(u8, proc.path.segments[0], event_name)) {
                    return item;
                }
            },
            .subflow_impl => |subflow| {
                // Default impl is in the SAME module as the abstract event
                // After canonicalization, it may have module_qualifier set to the current module
                const is_same_module = if (subflow.event_path.module_qualifier) |mq|
                    current_module != null and std.mem.eql(u8, mq, current_module.?)
                else
                    true; // No qualifier means local (same module)

                if (is_same_module and
                    subflow.event_path.segments.len > 0 and
                    std.mem.eql(u8, subflow.event_path.segments[0], event_name))
                {
                    return item;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Check if an override implementation exists (cross-module)
fn hasOverrideImpl(
    all_items: []const ast.Item,
    event: *const ast.EventDecl,
    current_module: ?[]const u8,
) bool {
    const target_module = current_module orelse event.path.module_qualifier orelse return false;
    const event_name = if (event.path.segments.len > 0) event.path.segments[0] else return false;

    for (@constCast(all_items)) |*item| {
        switch (item.*) {
            .subflow_impl => |*subflow| {
                // Override has a module_qualifier pointing to the abstract's module
                if (subflow.event_path.module_qualifier) |mq| {
                    if (std.mem.eql(u8, mq, target_module) and
                        subflow.event_path.segments.len > 0 and
                        std.mem.eql(u8, subflow.event_path.segments[0], event_name))
                    {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

/// Rename an implementation to `.default`
/// e.g., `coordinate` becomes `coordinate.default`
fn renameToDefault(item: *ast.Item, event_name: []const u8, allocator: std.mem.Allocator) Error!void {
    const new_name = try std.fmt.allocPrint(allocator, "{s}.default", .{event_name});

    switch (item.*) {
        .proc_decl => |*proc| {
            // Replace first segment with `event.default`
            if (proc.path.segments.len > 0) {
                var new_segments = try allocator.alloc([]const u8, proc.path.segments.len);
                new_segments[0] = new_name;
                for (proc.path.segments[1..], 1..) |seg, i| {
                    new_segments[i] = seg;
                }
                proc.path.segments = new_segments;
            }
        },
        .subflow_impl => |*subflow| {
            // Replace first segment with `event.default`
            if (subflow.event_path.segments.len > 0) {
                var new_segments = try allocator.alloc([]const u8, subflow.event_path.segments.len);
                new_segments[0] = new_name;
                for (subflow.event_path.segments[1..], 1..) |seg, i| {
                    new_segments[i] = seg;
                }
                subflow.event_path.segments = new_segments;
            }
        },
        else => {},
    }
}

// =============================================================================
// Event Declaration Duplication (for .default)
// =============================================================================

/// After renaming the default impl, we also need to create the `.default` event declaration
/// This is called from the main compiler pipeline after resolve()
pub fn createDefaultEventDecls(program: *ast.Program, allocator: std.mem.Allocator) Error!void {
    program.items = try createDefaultEventDeclsForItems(program.items, program.items, allocator);
}

fn createDefaultEventDeclsForItems(
    items: []const ast.Item,
    all_items: []const ast.Item,
    allocator: std.mem.Allocator,
) Error![]const ast.Item {
    var new_items = std.ArrayList(ast.Item){
        .items = &.{},
        .capacity = 0,
    };
    errdefer new_items.deinit(allocator);

    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                try new_items.append(allocator, item);

                // If this is an abstract event with a renamed default, create the .default event decl
                if (isAbstract(&event)) {
                    if (shouldCreateDefaultDecl(all_items, &event)) {
                        const default_decl = try createDefaultEventDecl(&event, allocator);
                        try new_items.append(allocator, .{ .event_decl = default_decl });
                    }
                }
            },
            .module_decl => |module| {
                // Recurse into module
                const new_module_items = try createDefaultEventDeclsForItems(module.items, all_items, allocator);
                var new_module = module;
                new_module.items = new_module_items;
                try new_items.append(allocator, .{ .module_decl = new_module });
            },
            else => {
                try new_items.append(allocator, item);
            },
        }
    }

    return new_items.toOwnedSlice(allocator);
}

fn shouldCreateDefaultDecl(items: []const ast.Item, event: *const ast.EventDecl) bool {
    const event_name = if (event.path.segments.len > 0) event.path.segments[0] else return false;

    // Check if there's a renamed default impl (name ends with .default)
    // Search both top-level and inside modules
    return findDefaultImplRecursive(items, event_name, event.path.module_qualifier);
}

fn findDefaultImplRecursive(items: []const ast.Item, event_name: []const u8, target_module: ?[]const u8) bool {
    for (items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                if (proc.path.segments.len > 0) {
                    const seg = proc.path.segments[0];
                    if (std.mem.endsWith(u8, seg, ".default")) {
                        const prefix = seg[0 .. seg.len - ".default".len];
                        if (std.mem.eql(u8, prefix, event_name)) {
                            return true;
                        }
                    }
                }
            },
            .subflow_impl => |subflow| {
                if (subflow.event_path.segments.len > 0) {
                    const seg = subflow.event_path.segments[0];
                    if (std.mem.endsWith(u8, seg, ".default")) {
                        const prefix = seg[0 .. seg.len - ".default".len];
                        if (std.mem.eql(u8, prefix, event_name)) {
                            return true;
                        }
                    }
                }
            },
            .module_decl => |module| {
                // Search inside the target module if specified
                if (target_module) |tm| {
                    if (std.mem.eql(u8, module.logical_name, tm)) {
                        if (findDefaultImplRecursive(module.items, event_name, null)) {
                            return true;
                        }
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn createDefaultEventDecl(event: *const ast.EventDecl, allocator: std.mem.Allocator) Error!ast.EventDecl {
    const event_name = if (event.path.segments.len > 0) event.path.segments[0] else "";
    const default_name = try std.fmt.allocPrint(allocator, "{s}.default", .{event_name});

    var new_segments = try allocator.alloc([]const u8, event.path.segments.len);
    new_segments[0] = default_name;
    for (event.path.segments[1..], 1..) |seg, i| {
        new_segments[i] = seg;
    }

    return ast.EventDecl{
        .path = .{
            .segments = new_segments,
            .module_qualifier = event.path.module_qualifier,
        },
        .input = event.input,
        .branches = event.branches,
        .annotations = &.{}, // No annotations on .default
        .is_public = false, // .default is internal
        .location = event.location,
        .module = event.module, // Same module as the abstract
    };
}
