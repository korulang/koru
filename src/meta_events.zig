const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

/// Meta-Event Injection Pass
///
/// This compiler pass injects synthetic meta-event flows into the AST BEFORE tap transformation.
/// Meta-events like `koru:start` and `koru:end` are used to mark program lifecycle boundaries
/// that taps can observe (e.g., profiler writes header/footer).
///
/// The beauty: Once injected, these become regular AST items that tap transformation handles!
/// No special cases needed - the profiler tap `~koru:start -> * | Profile p |>` just works.

/// Inject meta-event items into the program AST
/// MUST be called AFTER canonicalization (so events get module qualifiers)
/// MUST be called BEFORE tap transformation (so taps can observe these flows)
pub fn injectMetaEvents(allocator: std.mem.Allocator, program: *ast.Program) !void {
    // Calculate how many items we need to add
    // We're adding:
    // - 1 module declaration for 'koru' containing 2 event decls
    // - 2 top-level flows (~koru:start and ~koru:end)
    const items_to_add: usize = 3;
    const old_len = program.items.len;
    const new_len = old_len + items_to_add;

    // Reallocate items array to fit new items
    var new_items = try allocator.alloc(ast.Item, new_len);

    // Copy existing items
    @memcpy(new_items[0..old_len], program.items);

    // Don't free old items array - we're using an arena allocator that will clean up everything
    // when parse_arena.deinit() is called at the end of main()

    // Create koru module with start and end event declarations
    var koru_module_items = try allocator.alloc(ast.Item, 2);

    // Event: koru:start {} | done {}
    var start_event_branches = try allocator.alloc(ast.Branch, 1);
    start_event_branches[0] = ast.Branch{
        .name = try allocator.dupe(u8, "done"),
        .payload = ast.Shape{ .fields = &.{} },
    };

    var start_event_segments = try allocator.alloc([]const u8, 1);
    start_event_segments[0] = try allocator.dupe(u8, "start");

    koru_module_items[0] = ast.Item{
        .event_decl = ast.EventDecl{
            .path = ast.DottedPath{
                .module_qualifier = try allocator.dupe(u8, "koru"),
                .segments = start_event_segments,
            },
            .input = ast.Shape{ .fields = &.{} },
            .branches = start_event_branches,
            .is_public = true,
            .is_implicit_flow = true,
            .annotations = &.{},
            .location = errors.SourceLocation{
                .file = "koru_meta_events",
                .line = 0,
                .column = 0,
            },
            .module = try allocator.dupe(u8, "koru"),
        },
    };

    // Event: koru:end {} | done {}
    var end_event_branches = try allocator.alloc(ast.Branch, 1);
    end_event_branches[0] = ast.Branch{
        .name = try allocator.dupe(u8, "done"),
        .payload = ast.Shape{ .fields = &.{} },
    };

    var end_event_segments = try allocator.alloc([]const u8, 1);
    end_event_segments[0] = try allocator.dupe(u8, "end");

    koru_module_items[1] = ast.Item{
        .event_decl = ast.EventDecl{
            .path = ast.DottedPath{
                .module_qualifier = try allocator.dupe(u8, "koru"),
                .segments = end_event_segments,
            },
            .input = ast.Shape{ .fields = &.{} },
            .branches = end_event_branches,
            .is_public = true,
            .is_implicit_flow = true,
            .annotations = &.{},
            .location = errors.SourceLocation{
                .file = "koru_meta_events",
                .line = 0,
                .column = 0,
            },
            .module = try allocator.dupe(u8, "koru"),
        },
    };

    // Module declaration for 'koru'
    new_items[old_len] = ast.Item{
        .module_decl = ast.ModuleDecl{
            .logical_name = try allocator.dupe(u8, "koru"),
            .canonical_path = try allocator.dupe(u8, "koru_meta_events"),
            .items = koru_module_items,
            .is_system = false,  // NOT a system module - should be emitted in runtime backend only
            .location = errors.SourceLocation{
                .file = "koru_meta_events",
                .line = 0,
                .column = 0,
            },
        },
    };

    // Flow: ~koru:start() | done |> _
    var start_flow_continuations = try allocator.alloc(ast.Continuation, 1);
    start_flow_continuations[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "done"),
        .binding = null,  // Discard pattern (no binding)
        .condition = null,
        .node = null,  // Empty (no node)
        .indent = 0,
        .continuations = &.{},
    };

    var start_flow_segments = try allocator.alloc([]const u8, 1);
    start_flow_segments[0] = try allocator.dupe(u8, "start");

    new_items[old_len + 1] = ast.Item{
        .flow = ast.Flow{
            .invocation = ast.Invocation{
                .path = ast.DottedPath{
                    .module_qualifier = try allocator.dupe(u8, "koru"),
                    .segments = start_flow_segments,
                },
                .args = &.{},
            },
            .continuations = start_flow_continuations,
            .location = errors.SourceLocation{
                .file = "koru_meta_events",
                .line = 0,
                .column = 0,
            },
            .module = try allocator.dupe(u8, "koru"),
        },
    };

    // Flow: ~koru:end() | done |> _
    var end_flow_continuations = try allocator.alloc(ast.Continuation, 1);
    end_flow_continuations[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "done"),
        .binding = null,  // Discard pattern (no binding)
        .condition = null,
        .node = null,  // Empty (no node)
        .indent = 0,
        .continuations = &.{},
    };

    var end_flow_segments = try allocator.alloc([]const u8, 1);
    end_flow_segments[0] = try allocator.dupe(u8, "end");

    new_items[old_len + 2] = ast.Item{
        .flow = ast.Flow{
            .invocation = ast.Invocation{
                .path = ast.DottedPath{
                    .module_qualifier = try allocator.dupe(u8, "koru"),
                    .segments = end_flow_segments,
                },
                .args = &.{},
            },
            .continuations = end_flow_continuations,
            .location = errors.SourceLocation{
                .file = "koru_meta_events",
                .line = 0,
                .column = 0,
            },
            .module = try allocator.dupe(u8, "koru"),
        },
    };

    // Update program items
    program.items = new_items;
}
