// Transform Pass Runner - Generic AST Walker for Transform Handlers
const log = @import("log");
//
// This module provides a clean, reusable way to walk the entire AST and
// apply transform handlers to matching invocations, no matter where they appear.
//
// Uses the unified ASTNode type for generic traversal - no specialized code
// for each nesting level.
//
// Also handles [expand] events automatically by looking up templates and
// interpolating Expression parameters.

const std = @import("std");
const ast = @import("ast");
const ASTNode = ast.ASTNode;
const Program = ast.Program;
const Invocation = ast.Invocation;
const template_utils = @import("template_utils");
const liquid = @import("liquid");
const annotation_parser = @import("annotation_parser");
const ast_functional = @import("ast_functional");

/// Count how many invocations in the program match the transform.
/// Includes both top-level flows AND nested invocations in continuations.
/// Used to detect infinite loops: if the count doesn't decrease after a transform,
/// the transform isn't making progress.
fn countMatchingFlowsInProgram(transform_name: []const u8, program: *const Program) usize {
    var count: usize = 0;

    for (program.items) |item| {
        switch (item) {
            .flow => |flow| {
                count += countMatchingInFlow(&flow, transform_name);
            },
            .immediate_impl => {},
            .module_decl => |module| {
                for (module.items) |mod_item| {
                    switch (mod_item) {
                        .flow => |flow| {
                            count += countMatchingInFlow(&flow, transform_name);
                        },
                        .immediate_impl => {},
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return count;
}

/// Count matching invocations in a flow (including its continuations)
fn countMatchingInFlow(flow: *const ast.Flow, transform_name: []const u8) usize {
    var count: usize = 0;

    // Check the flow's own invocation
    if (flowStillMatchesTransform(&flow.invocation, transform_name)) {
        count += 1;
    }

    // Check invocations in continuations
    count += countMatchingInContinuations(flow.continuations, transform_name);

    return count;
}

/// Recursively count matching invocations in continuations
fn countMatchingInContinuations(continuations: []const ast.Continuation, transform_name: []const u8) usize {
    var count: usize = 0;

    for (continuations) |cont| {
        // Check the continuation's node
        if (cont.node) |node| {
            if (node == .invocation) {
                if (flowStillMatchesTransform(&node.invocation, transform_name)) {
                    count += 1;
                }
            }
        }

        // Recurse into nested continuations
        count += countMatchingInContinuations(cont.continuations, transform_name);
    }

    return count;
}

fn flowStillMatchesTransform(inv: *const Invocation, transform_name: []const u8) bool {
    // Check if it would match the transform (uses just segments, not full path)
    var seg_path_buf: [256]u8 = undefined;
    var seg_path_len: usize = 0;
    for (inv.path.segments, 0..) |seg, i| {
        if (i > 0) {
            seg_path_buf[seg_path_len] = '.';
            seg_path_len += 1;
        }
        if (seg_path_len + seg.len > seg_path_buf.len) return false;
        @memcpy(seg_path_buf[seg_path_len..][0..seg.len], seg);
        seg_path_len += seg.len;
    }
    const inv_path = seg_path_buf[0..seg_path_len];

    // Use glob matching if transform name contains wildcard
    const matches = if (std.mem.indexOfScalar(u8, transform_name, '*') != null)
        matchGlob(transform_name, inv_path)
    else
        std.mem.eql(u8, inv_path, transform_name);

    if (!matches) {
        return false; // Different event path - transform properly replaced itself
    }

    // Check if it has @pass_ran annotation (if so, it won't be transformed again)
    for (inv.annotations) |ann| {
        if (std.mem.eql(u8, ann, "@pass_ran(\"transform\")")) {
            return false; // Has @pass_ran, won't match again
        }
    }

    // Still matches transform path without @pass_ran -> would infinite loop!
    return true;
}

/// Simple glob matching for transform patterns
fn matchGlob(pattern: []const u8, value: []const u8) bool {
    // Full wildcard matches anything
    if (std.mem.eql(u8, pattern, "*")) return true;

    // Prefix wildcard: *.suffix
    if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, value, suffix);
    }

    // Suffix wildcard with dot: prefix.*
    if (pattern.len > 2 and pattern[pattern.len - 2] == '.' and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 2];
        return std.mem.startsWith(u8, value, prefix) and
            value.len > prefix.len and value[prefix.len] == '.';
    }

    // Bare suffix wildcard: prefix*
    if (pattern.len > 1 and pattern[pattern.len - 1] == '*') {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, value, prefix);
    }

    // Bare prefix wildcard: *suffix
    if (pattern.len > 1 and pattern[0] == '*') {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, value, suffix);
    }

    // Middle wildcard: prefix.*.suffix
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star_idx| {
        const prefix = pattern[0..star_idx];
        const suffix = pattern[star_idx + 1 ..];
        return std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, suffix) and
            value.len >= prefix.len + suffix.len;
    }

    return false;
}

/// Transform handler entry in the dispatch table
pub const TransformEntry = struct {
    /// Name of the transform event (e.g., "std.control.if", "renderHTML")
    name: []const u8,

    /// Handler function that takes (node, program, allocator) and returns transformed program
    /// - node: The ASTNode being transformed (will be .invocation for transforms)
    /// - program: The current program AST
    /// - allocator: For any allocations needed during transformation
    handler_fn: *const fn (node: ASTNode, program: *const Program, allocator: std.mem.Allocator) anyerror!*const Program,
};

/// Walk entire AST and apply transforms using fixed-point iteration
///
/// CRITICAL: We use a fixed-point iteration strategy instead of single-pass transformation.
///
/// WHY ITERATE?
/// 1. Pointer Identity: Each transform returns a NEW program with NEW pointers.
///    If we walk once and keep transforming, we'd be comparing pointers from the
///    original parse against a transformed AST - they'll never match!
///
/// 2. Natural Ordering: By restarting from the beginning after each transform,
///    we ensure transforms execute in SOURCE ORDER. Earlier transforms complete
///    before later ones run.
///
/// 3. Transform Chaining: If transform A creates new invocations (e.g., getUserData
///    itself being a transform), the next iteration will catch and transform them.
///
/// 4. Clean Reasoning: Each iteration sees a fresh, consistent AST state.
///    No mixing of old and new pointers.
///
/// ALGORITHM:
///   LOOP:
///     1. Walk current program from START (depth-first)
///     2. Find FIRST transform (deepest first due to depth-first)
///     3. Apply it -> get NEW program
///     4. Start over with NEW program
///     5. Repeat until full walk finds ZERO transforms
///
/// DO NOT "optimize" this to single-pass without understanding the pointer identity issue!
pub fn walkAndTransform(
    program: *const Program,
    transforms: []const TransformEntry,
    allocator: std.mem.Allocator,
) !*Program {
    var current_program = program;
    var iteration: usize = 0;
    const MAX_ITERATIONS: usize = 1000; // Circuit breaker to prevent infinite loops

    // Fixed-point iteration: keep transforming until no more transforms found
    while (true) {
        iteration += 1;

        // Circuit breaker: prevent infinite loops
        if (iteration > MAX_ITERATIONS) {
            log.debug("ERROR: Transform infinite loop after {d} iterations\n", .{MAX_ITERATIONS});
            return error.TransformInfiniteLoop;
        }

        const result = try walkOnce(current_program, transforms, allocator);

        if (result.found) {
            current_program = result.program;
        } else {
            break;
        }
    }

    return @constCast(current_program);
}

/// Result of walking the AST once
const WalkResult = struct {
    found: bool, // Did we find and apply a transform?
    program: *const Program, // Updated program (if found=true) or original (if found=false)
};

/// Walk the AST once, applying the FIRST transform found and returning immediately
fn walkOnce(
    program: *const Program,
    transforms: []const TransformEntry,
    allocator: std.mem.Allocator,
) !WalkResult {
    // Start from the program root
    const root = ASTNode{ .program = @constCast(program) };
    return try walkNode(root, program, transforms, allocator);
}

/// Generic depth-first walker for any ASTNode
/// DEPTH-FIRST: Always check children BEFORE checking self
/// This ensures inner/nested transforms run before outer transforms
fn walkNode(
    node: ASTNode,
    program: *const Program,
    transforms: []const TransformEntry,
    allocator: std.mem.Allocator,
) !WalkResult {
    // DEPTH-FIRST: Walk children first
    const children = try node.children(allocator);
    defer allocator.free(children);

    for (children) |child| {
        const result = try walkNode(child, program, transforms, allocator);
        if (result.found) {
            return result; // Found deeper transform, use it
        }
    }

    // Only check self if no deeper transforms found
    // Only invocations can be transforms
    if (node == .invocation) {
        const inv = node.invocation;

        // Debug: print what invocation we're checking
        var debug_path: [256]u8 = undefined;
        var debug_len: usize = 0;
        for (inv.path.segments, 0..) |seg, idx| {
            if (idx > 0) {
                debug_path[debug_len] = '.';
                debug_len += 1;
            }
            @memcpy(debug_path[debug_len..][0..seg.len], seg);
            debug_len += seg.len;
        }
        // log.debug("[WALK] Checking invocation: {s} (module: {s})\n", .{ debug_path[0..debug_len], inv.path.module_qualifier orelse "<none>" });

        // Skip if already transformed
        if (node.isAlreadyTransformed()) {
            // log.debug("[WALK] -> Skipping (already transformed)\n", .{});
            return WalkResult{ .found = false, .program = program };
        }

        // Check if this invocation matches any transform
        for (transforms) |transform| {
            if (node.matchesTransform(transform.name)) {
                // log.debug("[WALK] -> Matched transform: {s}\n", .{transform.name});
                const transformed = try transform.handler_fn(node, program, allocator);

                // CRITICAL: A transform MUST change the AST. If it returns the same pointer,
                // the flow wasn't replaced and we'll infinite loop trying to transform it again.
                if (transformed == program) {
                    log.debug("ERROR: Transform '{s}' returned same program pointer!\n", .{transform.name});
                    log.debug("ERROR: Transforms MUST replace their flow with different AST.\n", .{});
                    log.debug("ERROR: If this is a [norun] event, remove the [transform] annotation.\n", .{});
                    return error.TransformReturnedSamePointer;
                }

                // CIRCUIT BREAKER: Verify the transform made progress.
                // Count matching flows before and after - if count didn't decrease,
                // the transform isn't making progress (infinite loop).
                const count_before = countMatchingFlowsInProgram(transform.name, program);
                const count_after = countMatchingFlowsInProgram(transform.name, transformed);

                if (count_after >= count_before and count_before > 0) {
                    log.debug("\n", .{});
                    log.debug("╔══════════════════════════════════════════════════════════════════╗\n", .{});
                    log.debug("║  TRANSFORM ERROR: Invocation not replaced!                       ║\n", .{});
                    log.debug("╚══════════════════════════════════════════════════════════════════╝\n", .{});
                    log.debug("\n", .{});
                    log.debug("Transform '{s}' returned a new program, but matching invocations\n", .{transform.name});
                    log.debug("didn't decrease ({d} before, {d} after) - infinite loop detected.\n", .{count_before, count_after});
                    log.debug("\n", .{});
                    log.debug("FIX: Your transform must either:\n", .{});
                    log.debug("  1. Change the invocation path (e.g., 'query.src' -> 'query.src.impl')\n", .{});
                    log.debug("  2. Add @pass_ran(\"transform\") annotation to the new invocation\n", .{});
                    log.debug("\n", .{});
                    return error.TransformDidNotReplace;
                }

                return WalkResult{ .found = true, .program = transformed };
            }
        }

        // Check if this invocation matches an [expand] event
        // log.debug("[WALK] -> Checking for [expand] match\n", .{});
        const expand_result = try handleExpandIfMatches(node, program, allocator);
        if (expand_result.found) {
            // log.debug("[WALK] -> Found [expand] match!\n", .{});
            return expand_result;
        }
        // log.debug("[WALK] -> No transform/expand match\n", .{});
    }

    // Check for [derive(X)] annotations on event declarations
    // This enables ~[derive(parser)]event token {} to generate new events/procs from the declaration
    // Unlike [transform] which mutates invocations, [derive] generates NEW declarations
    if (node == .item) {
        if (node.item.* == .event_decl) {
            const event_decl = &node.item.event_decl;

            // Check for [derive(X)] annotation
            if (annotation_parser.getCall(allocator, event_decl.annotations, "derive") catch null) |call| {
                defer {
                    var mutable_call = call;
                    mutable_call.deinit(allocator);
                }

                // Get the derive handler name from first arg
                if (call.args.len > 0) {
                    const handler_name = call.args[0];
                    // log.debug("[WALK] Derive: {s} on event declaration\n", .{handler_name});

                    // Find matching derive handler in transforms array
                    // Derive handlers are registered alongside transform handlers
                    for (transforms) |transform| {
                        if (std.mem.eql(u8, transform.name, handler_name)) {
                            // log.debug("[WALK] -> Matched derive handler: {s}\n", .{handler_name});
                            const derived = try transform.handler_fn(node, program, allocator);

                            if (derived == program) {
                                log.debug("ERROR: Derive handler '{s}' returned same program pointer!\n", .{handler_name});
                                return error.TransformReturnedSamePointer;
                            }

                            return WalkResult{ .found = true, .program = derived };
                        }
                    }
                    // log.debug("[WALK] -> No handler found for derive: {s}\n", .{handler_name});
                }
            }
        }
    }

    // No transform found at this node
    return WalkResult{ .found = false, .program = program };
}

/// Check if an invocation matches an [expand] event and handle it
fn handleExpandIfMatches(
    node: ASTNode,
    program: *const Program,
    allocator: std.mem.Allocator,
) !WalkResult {
    const invocation = node.invocation;

    // Build the invocation path for matching
    var path_buf: [256]u8 = undefined;
    var path_len: usize = 0;
    for (invocation.path.segments, 0..) |segment, i| {
        if (i > 0) {
            path_buf[path_len] = '.';
            path_len += 1;
        }
        @memcpy(path_buf[path_len..][0..segment.len], segment);
        path_len += segment.len;
    }
    const inv_path = path_buf[0..path_len];

    // Search for matching [expand] event declaration
    for (program.items) |item| {
        switch (item) {
            .event_decl => |event_decl| {
                if (annotation_parser.hasPart(event_decl.annotations, "expand")) {
                    // Build event path for matching
                    var event_path_buf: [256]u8 = undefined;
                    var event_path_len: usize = 0;
                    for (event_decl.path.segments, 0..) |segment, i| {
                        if (i > 0) {
                            event_path_buf[event_path_len] = '.';
                            event_path_len += 1;
                        }
                        @memcpy(event_path_buf[event_path_len..][0..segment.len], segment);
                        event_path_len += segment.len;
                    }
                    const event_path = event_path_buf[0..event_path_len];

                    if (std.mem.eql(u8, inv_path, event_path)) {
                        // Found matching [expand] event - apply template
                        return try applyExpandTemplate(node, program, inv_path, allocator);
                    }
                }
            },
            .module_decl => |module| {
                for (module.items) |mod_item| {
                    if (mod_item == .event_decl) {
                        const event_decl = mod_item.event_decl;
                        if (annotation_parser.hasPart(event_decl.annotations, "expand")) {
                            // Build event path for matching
                            var event_path_buf: [256]u8 = undefined;
                            var event_path_len: usize = 0;
                            for (event_decl.path.segments, 0..) |segment, i| {
                                if (i > 0) {
                                    event_path_buf[event_path_len] = '.';
                                    event_path_len += 1;
                                }
                                @memcpy(event_path_buf[event_path_len..][0..segment.len], segment);
                                event_path_len += segment.len;
                            }
                            const event_path = event_path_buf[0..event_path_len];

                            if (std.mem.eql(u8, inv_path, event_path)) {
                                return try applyExpandTemplate(node, program, inv_path, allocator);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    return WalkResult{ .found = false, .program = program };
}

/// Apply template expansion to an [expand] invocation
fn applyExpandTemplate(
    node: ASTNode,
    program: *const Program,
    event_name: []const u8,
    allocator: std.mem.Allocator,
) !WalkResult {
    const invocation = node.invocation;

    // log.debug("[EXPAND] Processing: {s}\n", .{event_name});

    // Look up template by event name
    const template_source = template_utils.lookupTemplate(program, event_name) orelse {
        log.debug("[EXPAND] WARNING: No template found for '{s}'\n", .{event_name});
        return WalkResult{ .found = false, .program = program };
    };

    // Build Liquid context from invocation args (Expression parameters)
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    for (invocation.args) |arg| {
        if (arg.expression_value) |expr_val| {
            ctx.put(arg.name, .{ .string = expr_val.text }) catch {
                log.debug("[EXPAND] ERROR: Failed to add arg to context\n", .{});
                return WalkResult{ .found = false, .program = program };
            };
        }
    }

    // Render template with Liquid engine
    const inline_body = liquid.render(allocator, template_source, &ctx) catch |err| {
        log.debug("[EXPAND] ERROR: Liquid render failed: {}\n", .{err});
        return WalkResult{ .found = false, .program = program };
    };

    // log.debug("[EXPAND] Generated: {s}\n", .{inline_body});

    // Find the containing flow and update it with inline_body
    const containing_item = ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("[EXPAND] ERROR: Could not find containing item\n", .{});
        return WalkResult{ .found = false, .program = program };
    };

    const flow = if (containing_item.* == .flow)
        &containing_item.flow
    else {
        log.debug("[EXPAND] ERROR: Containing item is not a flow\n", .{});
        return WalkResult{ .found = false, .program = program };
    };

    // Create new invocation with @pass_ran("transform") annotation to prevent re-expansion
    const new_inv_annotations = allocator.alloc([]const u8, flow.invocation.annotations.len + 1) catch {
        log.debug("[EXPAND] ERROR: Failed to allocate annotations\n", .{});
        return WalkResult{ .found = false, .program = program };
    };
    for (flow.invocation.annotations, 0..) |ann, i| {
        new_inv_annotations[i] = ann;
    }
    new_inv_annotations[flow.invocation.annotations.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch {
        log.debug("[EXPAND] ERROR: Failed to dupe annotation\n", .{});
        return WalkResult{ .found = false, .program = program };
    };

    const new_invocation = ast.Invocation{
        .path = flow.invocation.path,
        .args = flow.invocation.args,
        .annotations = new_inv_annotations,
        .inserted_by_tap = flow.invocation.inserted_by_tap,
        .from_opaque_tap = flow.invocation.from_opaque_tap,
    };

    // For expand with continuations:
    // - Set inline_body to the template output (produces union value)
    // - Keep continuations as-is (for validation and branch bodies)
    // - The emitter will detect inline_body + continuations and generate a switch
    //
    // This preserves flow validation (branches match event definition) while
    // still allowing the template to provide the switch expression.

    // Create new flow with inline_body set (emitter handles the switch generation)
    const new_flow = ast.Flow{
        .invocation = new_invocation,
        .continuations = flow.continuations,  // Keep original continuations
        .annotations = flow.annotations,
        .pre_label = flow.pre_label,
        .post_label = flow.post_label,
        .super_shape = flow.super_shape,
        .inline_body = inline_body,  // Template output becomes inline_body
        .preamble_code = flow.preamble_code,
        .is_pure = flow.is_pure,
        .is_transitively_pure = flow.is_transitively_pure,
        .impl_of = flow.impl_of,
        .is_impl = flow.is_impl,
        .location = flow.location,
        .module = flow.module,
    };

    const new_item = ast.Item{ .flow = new_flow };

    // Replace in program
    const maybe_new_program = ast_functional.replaceFlowRecursive(
        allocator,
        program,
        flow,
        new_item,
    ) catch {
        log.debug("[EXPAND] ERROR: Failed to replace flow in program\n", .{});
        return WalkResult{ .found = false, .program = program };
    };

    if (maybe_new_program) |new_program| {
        const result = allocator.create(Program) catch unreachable;
        result.* = new_program;
        return WalkResult{ .found = true, .program = result };
    }

    return WalkResult{ .found = false, .program = program };
}
