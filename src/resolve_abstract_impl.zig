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

    // Find the override implementation first, by identity rather than by a
    // yes/no answer. Canonicalization stamps the enclosing module onto an
    // unqualified impl, so after it runs a same-module impl and an override
    // are indistinguishable by qualifier — both predicates below match the
    // SAME item. Taking the override as a pointer lets the default search
    // exclude it, so a lone implementation is never mistaken for a
    // default/override pair and renamed out from under its own tor.
    const override_impl = findOverrideImpl(ctx.all_items, event, current_module);

    // Find default implementation (same module), never the override itself
    const default_impl = findDefaultImpl(module_items, event_name, current_module, override_impl);
    const has_override = override_impl != null;

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
/// Returns pointer to the Item (proc_decl, flow with impl_of, or immediate_impl)
/// `exclude` is the item already claimed as the override — the same declaration
/// must never be counted as both halves of the pair.
fn findDefaultImpl(
    items: []const ast.Item,
    event_name: []const u8,
    current_module: ?[]const u8,
    exclude: ?*const ast.Item,
) ?*ast.Item {
    for (@constCast(items)) |*item| {
        if (exclude) |ex| {
            if (item == ex) continue;
        }
        switch (item.*) {
            .proc_decl => |proc| {
                if (proc.path.segments.len > 0 and std.mem.eql(u8, proc.path.segments[0], event_name)) {
                    return item;
                }
            },
            .flow => |flow| {
                // Check impl flows (flows with impl_of set)
                if (flow.impl_of) |impl_path| {
                    // Default impl is in the SAME module as the abstract event
                    // After canonicalization, it may have module_qualifier set to the current module
                    const is_same_module = if (impl_path.module_qualifier) |mq|
                        current_module != null and std.mem.eql(u8, mq, current_module.?)
                    else
                        true; // No qualifier means local (same module)

                    if (is_same_module and
                        impl_path.segments.len > 0 and
                        std.mem.eql(u8, impl_path.segments[0], event_name))
                    {
                        return item;
                    }
                }
            },
            .immediate_impl => |ii| {
                // Check immediate impls
                const is_same_module = if (ii.event_path.module_qualifier) |mq|
                    current_module != null and std.mem.eql(u8, mq, current_module.?)
                else
                    true;

                if (is_same_module and
                    ii.event_path.segments.len > 0 and
                    std.mem.eql(u8, ii.event_path.segments[0], event_name))
                {
                    return item;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Find the override implementation (cross-module), by identity.
/// A `~proc` is never an override — only a flow or an immediate impl can be one,
/// so the default search can still find a same-file proc after excluding this.
fn findOverrideImpl(
    all_items: []const ast.Item,
    event: *const ast.EventDecl,
    current_module: ?[]const u8,
) ?*ast.Item {
    const target_module = current_module orelse event.path.module_qualifier orelse return null;
    const event_name = if (event.path.segments.len > 0) event.path.segments[0] else return null;

    for (@constCast(all_items)) |*item| {
        switch (item.*) {
            .flow => |flow| {
                // Override: impl flow with module_qualifier pointing to the abstract's module
                if (flow.impl_of) |impl_path| {
                    if (impl_path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, target_module) and
                            impl_path.segments.len > 0 and
                            std.mem.eql(u8, impl_path.segments[0], event_name))
                        {
                            return item;
                        }
                    }
                }
            },
            .immediate_impl => |ii| {
                // Override: immediate impl with module_qualifier pointing to the abstract's module
                if (ii.event_path.module_qualifier) |mq| {
                    if (std.mem.eql(u8, mq, target_module) and
                        ii.event_path.segments.len > 0 and
                        std.mem.eql(u8, ii.event_path.segments[0], event_name))
                    {
                        return item;
                    }
                }
            },
            else => {},
        }
    }
    return null;
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
        .flow => |*flow| {
            // Replace first segment of impl_of with `event.default`
            if (flow.impl_of) |*impl_path| {
                if (impl_path.segments.len > 0) {
                    var new_segments = try allocator.alloc([]const u8, impl_path.segments.len);
                    new_segments[0] = new_name;
                    for (impl_path.segments[1..], 1..) |seg, i| {
                        new_segments[i] = seg;
                    }
                    impl_path.segments = new_segments;
                }
            }
        },
        .immediate_impl => |*ii| {
            // Replace first segment with `event.default`
            if (ii.event_path.segments.len > 0) {
                var new_segments = try allocator.alloc([]const u8, ii.event_path.segments.len);
                new_segments[0] = new_name;
                for (ii.event_path.segments[1..], 1..) |seg, i| {
                    new_segments[i] = seg;
                }
                ii.event_path.segments = new_segments;
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
            .flow => |flow| {
                if (flow.impl_of) |impl_path| {
                    if (impl_path.segments.len > 0) {
                        const seg = impl_path.segments[0];
                        if (std.mem.endsWith(u8, seg, ".default")) {
                            const prefix = seg[0 .. seg.len - ".default".len];
                            if (std.mem.eql(u8, prefix, event_name)) {
                                return true;
                            }
                        }
                    }
                }
            },
            .immediate_impl => |ii| {
                if (ii.event_path.segments.len > 0) {
                    const seg = ii.event_path.segments[0];
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

    // Preserve the original event's own annotations (notably phase markers
    // like `comptime`/`runtime`) — the created `.default` decl otherwise goes
    // through the exact same EmitMode filtering (shouldFilter in
    // emitter_helpers.zig) as any other event_decl, and that filter looks at
    // item-level annotations OR the enclosing module's annotations. For
    // koru_std modules (blanket module-level `[comptime]`, e.g.
    // koru_std/compiler.kz) an item with no phase annotation still passes.
    // For externally-imported library modules with no module-level
    // `[comptime]`, dropping the item's own `comptime` annotation here (as
    // this used to do, replacing it with just `["retain"]`) silently filtered
    // the `.default` decl out of comptime-only emission, so `<event>_default_event`
    // was never emitted as a module member — even though resolution had
    // correctly created and retained the decl in the AST.
    //
    // @retain: .default is called from override's generated Zig code
    // (_default_handler), not from Koru flows, so the dead strip can't see
    // the reference — append it alongside the preserved annotations.
    var new_annotations = try allocator.alloc([]const u8, event.annotations.len + 1);
    @memcpy(new_annotations[0..event.annotations.len], event.annotations);
    new_annotations[event.annotations.len] = "retain";

    return ast.EventDecl{
        .path = .{
            .segments = new_segments,
            .module_qualifier = event.path.module_qualifier,
        },
        .input = event.input,
        .branches = event.branches,
        // Bare-return abstracts (`-> CompilerContext`) carry their output on
        // return_type, not branches — the `.default` child must inherit it or
        // its Output degrades to void and every delegating override breaks.
        .return_type = event.return_type,
        .return_phantom = event.return_phantom,
        .annotations = new_annotations,
        .is_public = false, // .default is internal
        .location = event.location,
        .module = event.module, // Same module as the abstract
    };
}
