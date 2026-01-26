const std = @import("std");
const DEBUG = false;  // Set to true for verbose logging
const ast = @import("ast");
const TapRegistry = @import("tap_registry").TapRegistry;
const TapEntry = @import("tap_registry").TapEntry;
const EmitMode = @import("emitter_helpers").EmitMode;
const purity_helpers = @import("compiler_passes/purity_helpers");

/// Check if a tap should be included based on its mode annotations
/// Uses same logic as shouldFilter with explicit override semantics
fn shouldIncludeTap(tap: *const TapEntry, emit_mode: EmitMode) bool {
    // Taps default to runtime if unannotated
    const has_comptime = purity_helpers.hasAnnotation(tap.annotations, "comptime");
    const has_runtime = purity_helpers.hasAnnotation(tap.annotations, "runtime");

    switch (emit_mode) {
        .all => return true,
        .comptime_only => {
            // Include if has [comptime] annotation
            return has_comptime;
        },
        .runtime_only => {
            // Include if has [runtime] OR no mode annotations (default runtime)
            // Exclude if ONLY [comptime]
            return has_runtime or (!has_comptime and !has_runtime);
        },
    }
}

const OpaqueEventSet = std.StringHashMap(void);

fn hasOpaqueAnnotation(annotations: []const []const u8) bool {
    return purity_helpers.hasAnnotation(annotations, "opaque");
}

fn buildOpaqueEventSet(items: []const ast.Item, allocator: std.mem.Allocator) !OpaqueEventSet {
    var set = OpaqueEventSet.init(allocator);
    errdefer deinitOpaqueEventSet(&set, allocator);
    try collectOpaqueEvents(items, allocator, &set);
    return set;
}

fn deinitOpaqueEventSet(set: *OpaqueEventSet, allocator: std.mem.Allocator) void {
    var it = set.keyIterator();
    while (it.next()) |key| {
        allocator.free(key.*);
    }
    set.deinit();
}

fn collectOpaqueEvents(
    items: []const ast.Item,
    allocator: std.mem.Allocator,
    set: *OpaqueEventSet,
) !void {
    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                if (hasOpaqueAnnotation(event.annotations)) {
                    const canonical = try eventDeclToCanonicalName(allocator, &event);
                    if (set.contains(canonical)) {
                        allocator.free(canonical);
                    } else {
                        try set.put(canonical, {});
                    }
                }
            },
            .module_decl => |module| {
                try collectOpaqueEvents(module.items, allocator, set);
            },
            else => {},
        }
    }
}

fn eventDeclToCanonicalName(allocator: std.mem.Allocator, event: *const ast.EventDecl) ![]const u8 {
    var len: usize = event.module.len + 1; // module:
    for (event.path.segments, 0..) |seg, i| {
        if (i > 0) len += 1;
        len += seg.len;
    }

    const result = try allocator.alloc(u8, len);
    var pos: usize = 0;
    @memcpy(result[pos..pos + event.module.len], event.module);
    pos += event.module.len;
    result[pos] = ':';
    pos += 1;

    for (event.path.segments, 0..) |seg, i| {
        if (i > 0) {
            result[pos] = '.';
            pos += 1;
        }
        @memcpy(result[pos..pos + seg.len], seg);
        pos += seg.len;
    }

    return result;
}

/// Transform AST to insert tap invocations as regular flow code
/// This enables the optimizer to see and optimize taps (zero-cost abstraction!)
/// Only inserts taps whose mode annotations match the emit_mode
pub fn transformAst(
    source_ast: *const ast.Program,
    tap_registry: *TapRegistry,
    emit_mode: EmitMode,
    allocator: std.mem.Allocator,
) !*ast.Program {
    if (DEBUG) std.debug.print("TAP TRANSFORMER: Starting AST transformation (mode: {s})\n", .{@tagName(emit_mode)});
    if (DEBUG) std.debug.print("TAP TRANSFORMER: Tap registry has {} entries\n", .{tap_registry.entries.items.len});

    var opaque_events = try buildOpaqueEventSet(source_ast.items, allocator);
    defer deinitOpaqueEventSet(&opaque_events, allocator);

    // Transform all items recursively
    const transformed_items = try transformItems(
        source_ast.items,
        tap_registry,
        emit_mode,
        allocator,
        source_ast.main_module_name,
        &opaque_events,
    );

    // Create new Program with transformed items
    const transformed_ast = try allocator.create(ast.Program);
    transformed_ast.* = ast.Program{
        .items = transformed_items,
        .module_annotations = source_ast.module_annotations,
        .main_module_name = source_ast.main_module_name,
        .allocator = allocator,
    };

    return transformed_ast;
}

/// Recursively transform items, inserting taps into subflows
fn transformItems(
    items: []const ast.Item,
    tap_registry: *TapRegistry,
    emit_mode: EmitMode,
    allocator: std.mem.Allocator,
    main_module_name: []const u8,
    opaque_events: *const OpaqueEventSet,
) ![]const ast.Item {
    var transformed = try std.ArrayList(ast.Item).initCapacity(allocator, items.len);
    defer transformed.deinit(allocator);

    if (DEBUG) std.debug.print("TAP TRANSFORMER: transformItems processing {} items\n", .{items.len});

    for (items) |item| {
        switch (item) {
            .subflow_impl => |subflow| {
                if (DEBUG) std.debug.print("TAP TRANSFORMER: Found subflow for event: {s}\n", .{subflow.event_path.segments[0]});
                // Transform this subflow
                const transformed_subflow = try transformSubflow(
                    &subflow,
                    tap_registry,
                    emit_mode,
                    allocator,
                    main_module_name,
                    opaque_events,
                );
                try transformed.append(allocator, ast.Item{ .subflow_impl = transformed_subflow });
            },
            .flow => |flow| {
                // Transform top-level flows (e.g., ~hello() | done |> _)
                // These are flow-level taps that should fire when the main invocation completes
                if (DEBUG) std.debug.print("TAP TRANSFORMER: Found top-level flow invoking: {s}\n", .{flow.invocation.path.segments[0]});

                if (hasOpaqueAnnotation(flow.annotations)) {
                    try transformed.append(allocator, item);
                    continue;
                }

                // Get the invoked event name
                const invoked_event = try pathToString(flow.invocation.path, allocator);
                defer allocator.free(invoked_event);

                if (DEBUG) std.debug.print("TAP TRANSFORMER: Top-level flow invokes '{s}'\n", .{invoked_event});

                // Transform continuations - check for taps FROM the invoked event ON each branch
                const transformed_continuations = try transformContinuationsWithInvokedEvent(
                    flow.continuations,
                    invoked_event,
                    tap_registry,
                    emit_mode,
                    allocator,
                    opaque_events,
                );

                var new_flow = flow;
                new_flow.continuations = transformed_continuations;
                try transformed.append(allocator, ast.Item{ .flow = new_flow });
            },
            .module_decl => |module| {
                // Recursively transform module items
                const transformed_module_items = try transformItems(
                    module.items,
                    tap_registry,
                    emit_mode,
                    allocator,
                    main_module_name,
                    opaque_events,
                );

                var new_module = module;
                new_module.items = transformed_module_items;
                try transformed.append(allocator, ast.Item{ .module_decl = new_module });
            },
            else => {
                // Pass through unchanged
                try transformed.append(allocator, item);
            },
        }
    }

    return try transformed.toOwnedSlice(allocator);
}

/// Transform a single subflow - the core algorithm
fn transformSubflow(
    subflow: *const ast.SubflowImpl,
    tap_registry: *TapRegistry,
    emit_mode: EmitMode,
    allocator: std.mem.Allocator,
    main_module_name: []const u8,
    opaque_events: *const OpaqueEventSet,
) !ast.SubflowImpl {
    _ = main_module_name; // No longer needed - all paths are canonical

    // Get canonical event name for this subflow (e.g., "main:add_five")
    // After canonicalization, module_qualifier is always set!
    const source_event_canonical = try pathToString(subflow.event_path, allocator);
    defer allocator.free(source_event_canonical);

    // Transform the subflow body
    const transformed_body = switch (subflow.body) {
        .flow => |flow| blk: {
            if (hasOpaqueAnnotation(flow.annotations)) {
                break :blk ast.SubflowBody{ .flow = flow };
            }

            // Get the invoked event name from the main invocation (already canonical!)
            const invoked_event = try pathToString(flow.invocation.path, allocator);
            defer allocator.free(invoked_event);

            if (DEBUG) std.debug.print("TAP TRANSFORMER: Subflow '{s}' invokes '{s}'\n", .{source_event_canonical, invoked_event});

            // Transform continuations - check for taps FROM the invoked event ON each branch
            const transformed_continuations = try transformContinuationsWithInvokedEvent(
                flow.continuations,
                invoked_event,  // Check for taps FROM this event
                tap_registry,
                emit_mode,
                allocator,
                opaque_events,
            );

            var new_flow = flow;
            new_flow.continuations = transformed_continuations;
            break :blk ast.SubflowBody{ .flow = new_flow };
        },
        .immediate => |imm| ast.SubflowBody{ .immediate = imm }, // No transformation needed
    };

    var new_subflow = subflow.*;
    new_subflow.body = transformed_body;
    return new_subflow;
}

/// Transform continuations - insert tap invocations where they match
fn transformContinuationsWithInvokedEvent(
    continuations: []const ast.Continuation,
    invoked_event: []const u8,  // The event being invoked (check for taps FROM this)
    tap_registry: *TapRegistry,
    emit_mode: EmitMode,
    allocator: std.mem.Allocator,
    opaque_events: *const OpaqueEventSet,
) ![]const ast.Continuation {
    // V1: Counter for generating unique binding IDs
    // V2: Will be replaced with structural hash context (API stays the same!)
    var binding_hash_counter: usize = 0;

    return try transformContinuationsWithInvokedEventInternal(
        continuations,
        invoked_event,
        tap_registry,
        emit_mode,
        allocator,
        opaque_events,
        &binding_hash_counter,
    );
}

/// Merge tap continuations with the original continuation
/// When a tap continuation has a branch_constructor (pass-through), replace it with the original step/continuations
fn mergeTapContinuationsWithOriginal(
    tap_continuations: []const ast.Continuation,
    original_step: ?ast.Step,
    original_continuations: []const ast.Continuation,
    tap_binding: ?[]const u8,
    target_binding: []const u8,
    from_opaque_tap: bool,
    allocator: std.mem.Allocator,
) ![]const ast.Continuation {
    if (tap_continuations.len == 0) {
        // No tap continuations - this shouldn't happen for well-formed taps
        // Just return the original continuations
        return original_continuations;
    }

    var result = try std.ArrayList(ast.Continuation).initCapacity(allocator, tap_continuations.len);
    defer result.deinit(allocator);

    for (tap_continuations) |tap_cont| {
        var new_cont = tap_cont;

        // Check if this tap continuation's step is a pass-through point
        // Pass-through can be:
        // 1. A branch_constructor (explicitly passes through, e.g., | done |> result { result: r })
        // 2. A terminal step (tap ends, original flow continues, e.g., | done |> _)
        // 3. No step (null) - original flow continues
        const is_pass_through = if (tap_cont.node) |step|
            step == .branch_constructor or step == .terminal
        else
            true; // No step means pass-through

        if (is_pass_through) {
            // Pass-through: replace tap's step with original step, use original continuations
            if (DEBUG) std.debug.print("TAP TRANSFORMER: Found pass-through point, replacing with original step\n", .{});

            // Rewrite original step to use target_binding if needed
            const rewritten_step = if (original_step) |step| blk: {
                if (tap_binding) |tap_bind| {
                    break :blk try rewriteStepBinding(step, tap_bind, target_binding, from_opaque_tap, allocator);
                } else {
                    break :blk step;
                }
            } else null;

            new_cont.node = rewritten_step;
            new_cont.continuations = original_continuations;
        } else if (tap_cont.continuations.len > 0) {
            // Recurse into nested tap continuations to find pass-through
            new_cont.continuations = try mergeTapContinuationsWithOriginal(
                tap_cont.continuations,
                original_step,
                original_continuations,
                tap_binding,
                target_binding,
                from_opaque_tap,
                allocator,
            );
        }
        // If no pass-through and no nested continuations, keep tap continuation as-is

        try result.append(allocator, new_cont);
    }

    return try result.toOwnedSlice(allocator);
}

/// Rewrite a step's bindings from tap_binding to target_binding
fn rewriteStepBinding(
    step: ast.Step,
    tap_binding: []const u8,
    target_binding: []const u8,
    from_opaque_tap: bool,
    allocator: std.mem.Allocator,
) !ast.Step {
    switch (step) {
        .invocation => |inv| {
            // Rewrite invocation args
            const rewritten_args = try allocator.alloc(ast.Arg, inv.args.len);
            for (inv.args, 0..) |arg, i| {
                var new_arg = arg;
                new_arg.value = try rewriteBindingInValue(arg.value, tap_binding, target_binding, allocator);
                rewritten_args[i] = new_arg;
            }
            var new_inv = inv;
            new_inv.args = rewritten_args;
            new_inv.inserted_by_tap = true;
            new_inv.from_opaque_tap = from_opaque_tap;
            return ast.Step{ .invocation = new_inv };
        },
        else => return step,
    }
}

/// Rewrite a tap step's bindings and mark it as inserted by tap
fn rewriteTapStep(
    step: ast.Step,
    tap_binding: ?[]const u8,
    target_binding: []const u8,
    from_opaque_tap: bool,
    allocator: std.mem.Allocator,
) !ast.Step {
    if (tap_binding) |tb| {
        return try rewriteStepBinding(step, tb, target_binding, from_opaque_tap, allocator);
    } else {
        // No binding to rewrite, just mark as inserted by tap
        switch (step) {
            .invocation => |inv| {
                var new_inv = inv;
                new_inv.inserted_by_tap = true;
                new_inv.from_opaque_tap = from_opaque_tap;
                return ast.Step{ .invocation = new_inv };
            },
            else => return step,
        }
    }
}

/// Internal recursive function that shares the counter across all levels
fn transformContinuationsWithInvokedEventInternal(
    continuations: []const ast.Continuation,
    invoked_event: []const u8,
    tap_registry: *TapRegistry,
    emit_mode: EmitMode,
    allocator: std.mem.Allocator,
    opaque_events: *const OpaqueEventSet,
    binding_hash_counter: *usize,  // Shared counter for all recursion levels!
) ![]const ast.Continuation {
    var transformed = try std.ArrayList(ast.Continuation).initCapacity(allocator, continuations.len);
    defer transformed.deinit(allocator);

    for (continuations) |cont| {
        if (DEBUG) std.debug.print("TAP TRANSFORMER: Checking continuation for branch '{s}'\n", .{cont.branch});

        // Check if this continuation's step is from an opaque tap
        // If so, skip tap insertion to prevent "tap code observing tap code"
        var is_from_opaque_tap = false;
        if (cont.node) |step| {
            const step_from_opaque = switch (step) {
                .invocation => |inv| blk: {
                    if (DEBUG) std.debug.print("TAP TRANSFORMER:   Step: invocation from_opaque_tap={} inserted_by_tap={}\n", .{inv.from_opaque_tap, inv.inserted_by_tap});
                    break :blk inv.from_opaque_tap;
                },
                .metatype_binding => |mb| blk: {
                    if (DEBUG) std.debug.print("TAP TRANSFORMER:   Step: metatype_binding from_opaque_tap={} inserted_by_tap={}\n", .{mb.from_opaque_tap, mb.inserted_by_tap});
                    break :blk mb.from_opaque_tap;
                },
                .conditional_block => |cb| blk: {
                    if (DEBUG) std.debug.print("TAP TRANSFORMER:   Step: conditional_block from_opaque_tap={} inserted_by_tap={}\n", .{cb.from_opaque_tap, cb.inserted_by_tap});
                    break :blk cb.from_opaque_tap;
                },
                else => false,
            };
            if (step_from_opaque) {
                is_from_opaque_tap = true;
            }
        }

        if (is_from_opaque_tap) {
            if (DEBUG) std.debug.print("TAP TRANSFORMER: Skipping tap insertion - continuation is from opaque tap\n", .{});
            // Return continuation unchanged - no tap insertion
            try transformed.append(allocator, cont);
            continue;
        }

        // Find destination event from continuation step
        const destination = try findDestinationEventFromStep(cont.node, allocator);
        defer if (destination) |dest| allocator.free(dest);

        const invoked_is_opaque = opaque_events.contains(invoked_event);

        var matching_taps: []const TapEntry = &[_]TapEntry{};
        var all_matching_count: usize = 0;
        var free_matching_taps = false;

        if (!invoked_is_opaque) {
            // Check for taps FROM the invoked event ON this branch TO destination (or terminal if null)
            const all_matching_taps = try tap_registry.getMatchingTaps(
                invoked_event,
                cont.branch,
                destination,
            );
            defer allocator.free(all_matching_taps);
            all_matching_count = all_matching_taps.len;

            // Filter taps by mode annotations (comptime vs runtime)
            var mode_filtered_taps = try std.ArrayList(TapEntry).initCapacity(allocator, all_matching_taps.len);
            defer mode_filtered_taps.deinit(allocator);

            // Extract module from invoked event for opaque tap filtering
            // After canonicalization, both tap.source_module and event module_qualifier use canonical names
            const invoked_module = if (std.mem.indexOfScalar(u8, invoked_event, ':')) |colon_idx|
                invoked_event[0..colon_idx]
            else
                "";

            for (all_matching_taps) |tap| {
                if (shouldIncludeTap(&tap, emit_mode)) {
                    if (DEBUG) std.debug.print("TAP TRANSFORMER:     Considering tap: is_opaque={} source_module='{s}' invoked_module='{s}'\n", .{tap.is_opaque, tap.source_module, invoked_module});

                    // Skip opaque taps from observing events in their own module (prevents recursion)
                    if (tap.is_opaque and invoked_module.len > 0 and std.mem.eql(u8, tap.source_module, invoked_module)) {
                        if (DEBUG) std.debug.print("TAP TRANSFORMER:     SKIPPING: Opaque tap from module '{s}' observing own module event '{s}'\n", .{tap.source_module, invoked_event});
                        continue;
                    }

                    // Skip ALL taps when inside opaque tap context
                    if (is_from_opaque_tap) {
                        if (DEBUG) std.debug.print("TAP TRANSFORMER:     SKIPPING: Inside opaque tap context\n", .{});
                        continue;
                    }

                    // Skip taps that would match their own step's event (prevents infinite recursion)
                    // This happens with universal taps like ~* -> * | Transition |> observer()
                    // where observer() itself would trigger the same tap
                    if (tap.step) |tap_step| {
                        const tap_event = try findDestinationEventFromStep(tap_step, allocator);
                        defer if (tap_event) |te| allocator.free(te);

                        if (tap_event) |te| {
                            if (std.mem.eql(u8, te, invoked_event)) {
                                if (DEBUG) std.debug.print("TAP TRANSFORMER:     SKIPPING: Tap's own step event '{s}' matches invoked event\n", .{te});
                                continue;
                            }
                        }
                    }

                    try mode_filtered_taps.append(allocator, tap);
                }
            }

            matching_taps = try mode_filtered_taps.toOwnedSlice(allocator);
            free_matching_taps = true;
        }
        defer if (free_matching_taps) allocator.free(matching_taps);

        if (DEBUG) std.debug.print("TAP TRANSFORMER: Checking taps FROM '{s}' ON '{s}' → {d} matches ({d} after mode filtering)\n", .{
            invoked_event,
            cont.branch,
            all_matching_count,
            matching_taps.len,
        });

        // Generate unique binding for tap arg rewriting if needed
        // If user provided explicit binding, use it. Otherwise generate unique one.
        const target_binding = if (matching_taps.len > 0 and cont.binding == null) blk: {
            // Generate unique binding: "{branch}_{hash}"
            // This prevents collisions when multiple continuations have same branch name
            const hash = try calculateBindingHash(binding_hash_counter, allocator);
            defer allocator.free(hash);

            const unique_binding = try std.fmt.allocPrint(
                allocator,
                "{s}_{s}",
                .{cont.branch, hash}
            );
            // NOTE: unique_binding becomes part of the AST (via new_cont.binding)
            // so we DON'T free it - the AST owns it now!
            break :blk unique_binding;
        } else if (cont.binding) |b|
            b
        else
            cont.branch;

        // Transform the step and continuations (insert taps if any match)
        var transformed_step: ?ast.Step = cont.node;
        var transformed_continuations: []const ast.Continuation = cont.continuations;

        if (matching_taps.len > 0) {
            if (DEBUG) std.debug.print("TAP TRANSFORMER: Inserting {d} tap(s) into continuation!\n", .{matching_taps.len});
            if (DEBUG) std.debug.print("TAP TRANSFORMER: Using target_binding: '{s}'\n", .{target_binding});

            // For now, handle the first matching tap (TODO: chain multiple taps)
            const tap = matching_taps[0];

            // Use the tap's step as the new step (rewrite bindings)
            if (tap.step) |tap_step| {
                transformed_step = try rewriteTapStep(
                    tap_step,
                    tap.tap_binding,
                    target_binding,
                    tap.is_opaque,
                    allocator,
                );
            }

            // Merge tap's continuations with the original continuation
            // The tap's pass-through (branch_constructor) gets replaced with original step/continuations
            if (tap.continuations.len > 0) {
                transformed_continuations = try mergeTapContinuationsWithOriginal(
                    tap.continuations,
                    cont.node,           // original step to inject at pass-through
                    cont.continuations,  // original continuations to inject at pass-through
                    tap.tap_binding,
                    target_binding,
                    tap.is_opaque,
                    allocator,
                );
            } else {
                // No tap continuations - keep original continuations
                // This handles simple taps that just call something without pass-through
                transformed_continuations = cont.continuations;
            }
        }

        // CRITICAL: Recursively transform nested continuations!
        // This handles cases like: compute -> format -> display
        // where taps need to fire on BOTH transitions
        // IMPORTANT: Pass the SAME counter through recursion to ensure unique bindings!
        if (transformed_continuations.len > 0) {
            // Determine the source for nested transformations
            // If we just inserted a tap, use the tap's step's event (not the original event!)
            // This prevents infinite recursion where the same tap keeps matching
            var tap_event_for_source: ?[]const u8 = null;
            const nested_source = if (matching_taps.len > 0 and transformed_step != null) blk: {
                // Use the tap's invoked event as source for its continuations
                tap_event_for_source = try findDestinationEventFromStep(transformed_step, allocator);
                if (tap_event_for_source) |te| {
                    break :blk te;
                }
                // Fallback to destination or original event
                break :blk if (destination) |dest| dest else invoked_event;
            } else if (destination) |dest|
                dest
            else
                invoked_event; // If no destination, nested continuations still use same source

            defer if (tap_event_for_source) |te| allocator.free(te);

            // Recursively transform nested continuations with SHARED counter
            transformed_continuations = try transformContinuationsWithInvokedEventInternal(
                transformed_continuations,
                nested_source,
                tap_registry,
                emit_mode,
                allocator,
                opaque_events,
                binding_hash_counter,  // Share the counter!
            );
        }

        var new_cont = cont;
        new_cont.node = transformed_step;
        new_cont.continuations = transformed_continuations;

        // CRITICAL: Set the unique binding so emitter creates the variable
        // This binding matches what tap args reference (rewritten by rewriteTapStep)
        if (matching_taps.len > 0 and cont.binding == null) {
            new_cont.binding = target_binding;
            // target_binding is now owned by the AST - don't free it!
        }

        try transformed.append(allocator, new_cont);
    }

    return try transformed.toOwnedSlice(allocator);
}


/// Calculate unique binding hash for collision avoidance
///
/// **PURPOSE**: Generates unique identifiers to prevent binding collisions when
/// multiple continuations have the same branch name (e.g., .done, .error).
///
/// **V1 Implementation (Current)**: Returns sequential numbers "0", "1", "2"
/// This is a simple counter-based approach that solves 90% of collision cases
/// by ensuring each binding in a scope gets a unique ID.
///
/// **V2 Implementation (Future)**: Will return structural hashes like "a3k8df" based on:
///   - Module context (which file/module?)
///   - Flow context (which flow contains this?)
///   - Position context (where in flow sequence?)
///
/// The V2 upgrade will provide refactor-resistant identifiers that remain stable
/// across code changes. The API will remain the same - callers don't need to change!
///
/// See: docs/design/call-site-geohashing.md for the structural hashing design
fn calculateBindingHash(
    counter: *usize,
    allocator: std.mem.Allocator,
) ![]const u8 {
    // V1: Simple sequential counter
    // Will upgrade to structural geohashing in V2 (API stays the same!)
    const hash = try std.fmt.allocPrint(allocator, "{d}", .{counter.*});
    counter.* += 1;
    return hash;
}


/// Find destination event from continuation step (for new single-step design)
fn findDestinationEventFromStep(
    step: ?ast.Step,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    if (step) |s| {
        switch (s) {
            .invocation => |inv| {
                // Regular invocation - return the event being invoked
                return try pathToString(inv.path, allocator);
            },
            .label_with_invocation => |lwi| {
                // Label loops invoke an event - this IS the destination!
                return try pathToString(lwi.invocation.path, allocator);
            },
            else => return null,
        }
    }
    return null; // No step or terminal continuation
}


/// Rewrite binding references in arg values
/// Replaces "old_binding." with "new_binding." (e.g., "d.result" → "done.result")
fn rewriteBindingInValue(
    value: []const u8,
    old_binding: []const u8,
    new_binding: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    // Look for "old_binding." pattern
    const pattern = try std.fmt.allocPrint(allocator, "{s}.", .{old_binding});
    defer allocator.free(pattern);

    // Check if value contains the pattern
    if (std.mem.indexOf(u8, value, pattern)) |_| {
        // Found it - need to rewrite
        // Build new value by replacing pattern with "new_binding."
        var result = try std.ArrayList(u8).initCapacity(allocator, value.len + new_binding.len);
        defer result.deinit(allocator);

        var pos: usize = 0;
        var remaining = value;

        while (std.mem.indexOf(u8, remaining, pattern)) |match_pos| {
            // Copy everything before the match
            try result.appendSlice(allocator, value[pos..pos + match_pos]);

            // Replace with new_binding.
            try result.appendSlice(allocator, new_binding);
            try result.append(allocator, '.');

            // Move past the matched pattern
            pos += match_pos + pattern.len;
            remaining = value[pos..];
        }

        // Copy remaining text after last match
        try result.appendSlice(allocator, value[pos..]);

        return try result.toOwnedSlice(allocator);
    } else {
        // No pattern found - return original value (no alloc needed, just return the slice)
        return value;
    }
}

// buildCanonicalEventName() removed - no longer needed!
// After canonicalization pass, all DottedPaths have module_qualifier set.
// Use pathToString() directly to get canonical names.

/// Convert DottedPath to string (module:path.to.event)
/// After canonicalization, module_qualifier is ALWAYS present
fn pathToString(path: ast.DottedPath, allocator: std.mem.Allocator) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer result.deinit(allocator);

    // After canonicalization, this is always set!
    // Use fallback if module_qualifier is missing (e.g. manually constructed AST)
    const mq = path.module_qualifier orelse "input";

    try result.appendSlice(allocator, mq);
    try result.append(allocator, ':');

    for (path.segments, 0..) |seg, i| {
        if (i > 0) try result.append(allocator, '.');
        try result.appendSlice(allocator, seg);
    }

    return try result.toOwnedSlice(allocator);
}
