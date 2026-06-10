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
const Arg = ast.Arg;
const template_utils = @import("template_utils");
const liquid = @import("liquid");
const annotation_parser = @import("annotation_parser");
const ast_functional = @import("ast_functional");

// ============================================================================
// Position-agnostic transform sites
// ============================================================================
//
// "Invoke an event + handle its branches" has ONE encoding at every depth:
// a `Continuation` (`ast.Flow` is a thin module-level wrapper whose `body`
// is the root Continuation). A transform site is therefore just a
// *Continuation; the only positional datum left is a wrapper-layer one —
// whether the site happens to be some flow's root body, which decides WHICH
// Item the handler's program-level write-back replaces:
//
// - Root sites (site == &flow.body): the handler runs against the real
//   program and its returned program is used as-is (it replaced the Item).
// - Nested sites: the handler ABI is "receive a program, return a whole new
//   program with the site replaced as an Item" (handlers deep-clone
//   untouched items, may append new event decls/procs/host lines). A nested
//   site is not an Item, so the runner WRAPS it: the site Continuation
//   becomes the `body` of a synthetic marker-stamped Flow appended to a
//   program copy (no re-encoding — the body IS the site value). After the
//   handler returns, the result is GRAFTED back: the marker-stamped item's
//   body is spliced into the holding continuation (`Flow.inline_body`
//   migrates to `Invocation.inline_body`, the canonical location;
//   `Item.inline_code` becomes `Node.inline_code`), and any new top-level
//   items the handler inserted are kept.
//
// The wrap/graft residue exists because the HANDLER ABI is item-level and
// deep-cloning (marker rediscovery, path navigation) — it is no longer
// compensation for a dual encoding; there is none.
//
// Transforms either complete or fail loudly: every impossible state on this
// path is a hard error, never a warn-and-continue.

/// Marker prefix stamped into the synthetic flow's location.file so the
/// transformed site can be found again in the handler's returned program.
/// Handlers preserve `flow.location` on their replacement items (all known
/// ones do); a handler that destroys it gets a hard, descriptive error.
const site_marker_prefix = "__koru_lifted_site__:";

/// A transform site reference: the ONE invoke+branches core (a Continuation)
/// plus the wrapper-layer datum of which Item to replace on write-back.
/// `wrapper` is non-null iff the site is that flow's root body. Nothing
/// below the runner's write-back dispatch may consult it.
const SiteRef = struct {
    holding: *ast.Continuation,
    wrapper: ?*ast.Flow,
};

/// Where an invocation sits in the AST, threaded through the walk so the
/// runner never has to re-discover it by pointer-chasing.
const SitePosition = union(enum) {
    /// Not an invocation position (program/item/etc. levels).
    none,
    /// The invocation is the node of this site.
    site: SiteRef,
    /// Any other position (e.g. inside a conditional_block). No transform
    /// has ever legally fired here; matching one is a hard error.
    opaque_position,
};

const SourceLocation = @FieldType(ast.Flow, "location");

/// Everything needed to call a handler against a lifted nested site and
/// graft the result back into the real program.
const LiftedSite = struct {
    /// Program copy with the synthetic site flow appended as the last item.
    site_program: *Program,
    /// `.invocation` node pointing INTO the synthetic flow (so glue code's
    /// `findContainingItem` resolves to the synthetic item).
    site_node: ASTNode,
    /// Marker stamped on the synthetic flow's location.file.
    marker: []const u8,
    /// Location of the REAL containing flow (used to find its clone in the
    /// handler's returned program — handlers deep-clone untouched items, so
    /// pointer identity does not survive; source location does).
    containing_loc: SourceLocation,
    /// Index path of the holding continuation inside the containing flow:
    /// containing.body.continuations[p0].continuations[p1]...[pN] IS the
    /// holding continuation (whose .node is the lifted invocation).
    cont_path: []const usize,
    /// The lifted invocation's original path segments — graft-time sanity
    /// check that the navigation landed on the right continuation.
    original_segments: []const []const u8,
};

/// Locate the top-level (or module-nested) flow containing `target_cont` and
/// record the continuation index path to it. Returns null if not found.
const ContainingSearch = struct {
    flow: *const ast.Flow,
    cont_path: []const usize,

    fn findInConts(
        allocator: std.mem.Allocator,
        conts: []const ast.Continuation,
        target_cont: *const ast.Continuation,
        path: *std.ArrayList(usize),
    ) !bool {
        for (conts, 0..) |*cont, i| {
            try path.append(allocator, i);
            if (cont == target_cont) return true;
            if (try findInConts(allocator, cont.continuations, target_cont, path)) return true;
            _ = path.pop();
        }
        return false;
    }

    fn findInItems(
        allocator: std.mem.Allocator,
        items: []const ast.Item,
        target_cont: *const ast.Continuation,
    ) !?ContainingSearch {
        for (items) |*item| {
            switch (item.*) {
                .flow => |*f| {
                    var path: std.ArrayList(usize) = .empty;
                    if (try findInConts(allocator, f.body.continuations, target_cont, &path)) {
                        return ContainingSearch{ .flow = f, .cont_path = try path.toOwnedSlice(allocator) };
                    }
                    path.deinit(allocator);
                },
                .module_decl => |*m| {
                    if (try findInItems(allocator, m.items, target_cont)) |found| {
                        return found;
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

/// Wrap a nested transform site in a synthetic top-level item: the site
/// Continuation BECOMES the body of a marker-stamped Flow appended to a copy
/// of the program. No re-encoding happens — the body is the same
/// invoke+branches value the walker found (it shares the continuation slice
/// with the real AST; handlers treat the program as immutable and build
/// replacements functionally). The handler runs against this view exactly as
/// it would against a real top-level flow.
fn liftSite(
    allocator: std.mem.Allocator,
    program: *const Program,
    holding_cont: *ast.Continuation,
) !LiftedSite {
    const target_inv = &holding_cont.node.?.invocation;

    const containing = (try ContainingSearch.findInItems(allocator, program.items, holding_cont)) orelse {
        log.err("TRANSFORM RUNNER BUG: could not locate the flow containing a nested transform invocation. The walker handed us a continuation that is not reachable from the program root.\n", .{});
        return error.TransformSiteNotInProgram;
    };

    const marker = try std.fmt.allocPrint(allocator, "{s}{s}:{d}:{d}", .{
        site_marker_prefix,
        holding_cont.location.file,
        holding_cont.location.line,
        holding_cont.location.column,
    });

    const site_flow = ast.Flow{
        .body = holding_cont.*,
        .location = .{
            .file = marker,
            .line = holding_cont.location.line,
            .column = holding_cont.location.column,
        },
        .module = containing.flow.module,
        .is_pure = containing.flow.is_pure,
        .is_transitively_pure = containing.flow.is_transitively_pure,
    };

    const site_items = try allocator.alloc(ast.Item, program.items.len + 1);
    @memcpy(site_items[0..program.items.len], program.items);
    site_items[program.items.len] = ast.Item{ .flow = site_flow };

    const site_program = try allocator.create(Program);
    site_program.* = program.*;
    site_program.items = site_items;

    return LiftedSite{
        .site_program = site_program,
        .site_node = ASTNode{ .invocation = site_items[program.items.len].flow.invMut() },
        .marker = marker,
        .containing_loc = containing.flow.location,
        .cont_path = containing.cont_path,
        .original_segments = target_inv.path.segments,
    };
}

/// Find the (single) item carrying the site marker in the handler's returned
/// program. Only `.flow` and `.inline_code` items count as the site — other
/// item kinds the handler stamped with the same location (event decls, procs,
/// host lines it inserted alongside) are siblings, not the site itself.
fn findSiteItemIndex(items: []const ast.Item, marker: []const u8) !usize {
    var found: ?usize = null;
    for (items, 0..) |*item, i| {
        const loc_file: ?[]const u8 = switch (item.*) {
            .flow => |*f| f.location.file,
            .inline_code => |*ic| ic.location.file,
            else => null,
        };
        if (loc_file) |file| {
            if (std.mem.eql(u8, file, marker)) {
                if (found != null) {
                    log.err("TRANSFORM ERROR: handler produced more than one replacement item for a lifted site (marker {s}). A transform must replace its site with exactly one flow or inline_code item.\n", .{marker});
                    return error.TransformSiteAmbiguous;
                }
                found = i;
            }
        }
    }
    return found orelse {
        log.err("TRANSFORM ERROR: transformed site not found in handler output (marker {s}). The handler must preserve flow.location on its replacement item — that is how the runner grafts a nested site back into position.\n", .{marker});
        return error.TransformSiteLost;
    };
}

const ContFinder = struct {
    fn findFlowByLoc(items: []ast.Item, loc: SourceLocation) ?*ast.Flow {
        for (items) |*item| {
            switch (item.*) {
                .flow => |*f| {
                    if (f.location.line == loc.line and f.location.column == loc.column and
                        std.mem.eql(u8, f.location.file, loc.file))
                    {
                        return f;
                    }
                },
                .module_decl => |*m| {
                    if (findFlowByLoc(@constCast(m.items), loc)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }
};

/// Graft the handler's result back into the real nesting position.
///
/// The returned program contains (a) the transformed site as a top-level item
/// carrying the runner's marker location, (b) a clone of the original
/// containing flow still holding the UNtransformed nested invocation, and (c)
/// any new items the handler inserted. The graft converts (a) into the
/// continuation position inside (b) and drops the synthetic top-level item.
fn graftSite(
    allocator: std.mem.Allocator,
    returned: *const Program,
    lifted: LiftedSite,
) !*const Program {
    const site_idx = try findSiteItemIndex(returned.items, lifted.marker);

    // Convert the transformed site item into a continuation node + children.
    var new_node: ast.Node = undefined;
    var new_children: []const ast.Continuation = &[_]ast.Continuation{};
    switch (returned.items[site_idx]) {
        .flow => |*f| {
            if (f.preamble_code != null) {
                log.err("TRANSFORM ERROR: transform produced preamble_code for a nested site ({s}). preamble_code only exists at flow level; there is no preamble position inside a continuation. The transform must use inline_body (statement-shaped, //@koru:inline_stmt) instead.\n", .{lifted.marker});
                return error.TransformPreambleAtNestedSite;
            }
            var new_inv = f.inv().*;
            // Flow.inline_body delegates to Invocation.inline_body (the
            // canonical location) — migrate it so depth emission sees it.
            if (f.inline_body != null and new_inv.inline_body == null) {
                new_inv.inline_body = f.inline_body;
            }
            new_node = ast.Node{ .invocation = new_inv };
            new_children = f.body.continuations;
        },
        .inline_code => |*ic| {
            // The handler replaced the whole site with raw host code (e.g. a
            // comptime @compileError). The subtree was consumed with it.
            new_node = ast.Node{ .inline_code = ic.code };
            new_children = &[_]ast.Continuation{};
        },
        else => unreachable, // findSiteItemIndex only returns flow/inline_code
    }

    // Locate the containing flow's clone in the returned program and navigate
    // the recorded continuation path to the holding continuation.
    const containing = ContFinder.findFlowByLoc(@constCast(returned.items), lifted.containing_loc) orelse {
        log.err("TRANSFORM ERROR: containing flow ({s}:{d}:{d}) vanished from handler output while grafting a nested transform site. Handlers must not remove or relocate flows other than their own site.\n", .{ lifted.containing_loc.file, lifted.containing_loc.line, lifted.containing_loc.column });
        return error.TransformContainingFlowLost;
    };

    var conts: []const ast.Continuation = containing.body.continuations;
    var holding: *ast.Continuation = undefined;
    for (lifted.cont_path, 0..) |idx, depth| {
        if (idx >= conts.len) {
            log.err("TRANSFORM ERROR: continuation path invalid while grafting a nested transform site ({s}) — the handler restructured the containing flow.\n", .{lifted.marker});
            return error.TransformGraftPathInvalid;
        }
        holding = @constCast(&conts[idx]);
        if (depth + 1 < lifted.cont_path.len) {
            conts = holding.continuations;
        }
    }

    // Sanity: the holding continuation must still carry the UNtransformed
    // original invocation (the handler only transformed the lifted copy).
    const ok = blk: {
        const node = holding.node orelse break :blk false;
        if (node != .invocation) break :blk false;
        const segs = node.invocation.path.segments;
        if (segs.len != lifted.original_segments.len) break :blk false;
        for (segs, lifted.original_segments) |a, b| {
            if (!std.mem.eql(u8, a, b)) break :blk false;
        }
        break :blk true;
    };
    if (!ok) {
        log.err("TRANSFORM ERROR: graft target mismatch for nested transform site ({s}) — the continuation at the recorded path no longer holds the original invocation.\n", .{lifted.marker});
        return error.TransformGraftTargetMismatch;
    }

    // Splice in place — the returned program is handler-fresh and becomes the
    // next walk iteration's input; nothing else references it.
    holding.node = new_node;
    holding.continuations = new_children;

    // Drop the synthetic top-level site item.
    const final_items = try allocator.alloc(ast.Item, returned.items.len - 1);
    var w: usize = 0;
    for (returned.items, 0..) |item, i| {
        if (i == site_idx) continue;
        final_items[w] = item;
        w += 1;
    }

    const final_program = try allocator.create(Program);
    final_program.* = returned.*;
    final_program.items = final_items;
    return final_program;
}

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

/// Count matching invocations in a flow. The flow's root body is just a
/// continuation, so one recursive walk covers every depth — there is no
/// separate "flow's own invocation" case anymore.
fn countMatchingInFlow(flow: *const ast.Flow, transform_name: []const u8) usize {
    return countMatchingInContinuation(&flow.body, transform_name);
}

/// Recursively count matching invocations in a site (node + branch handlers).
fn countMatchingInContinuation(cont: *const ast.Continuation, transform_name: []const u8) usize {
    var count: usize = 0;

    if (cont.node) |node| {
        if (node == .invocation) {
            if (flowStillMatchesTransform(&node.invocation, transform_name)) {
                count += 1;
            }
        }
    }

    for (cont.continuations) |*child| {
        count += countMatchingInContinuation(child, transform_name);
    }

    return count;
}

/// Remove a specific flow from the program by matching the target invocation pointer.
fn removeFlowFromProgram(allocator: std.mem.Allocator, program: *const Program, target_inv: *const Invocation) !?*const Program {
    var new_items: std.ArrayList(ast.Item) = .empty;
    var found = false;
    for (program.items, 0..) |_, idx| {
        const item_ptr = &program.items[idx];
        if (item_ptr.* == .flow and item_ptr.flow.inv() == target_inv) {
            found = true;
            continue; // Skip this flow
        }
        new_items.append(allocator, program.items[idx]) catch return null;
    }
    if (!found) return null;
    const result = allocator.create(Program) catch return null;
    result.* = program.*;
    result.items = new_items.toOwnedSlice(allocator) catch unreachable;
    return result;
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

    /// When true, this transform claims its lexical descendants and is checked
    /// before child traversal. This lets region-owning constructs see raw
    /// downstream structure before peer transforms rewrite it.
    claims_descendants: bool = false,

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
    return try walkNode(root, program, transforms, allocator, .none);
}

/// Compute the SitePosition each child of `node` should be walked with.
/// Only invocation-bearing edges carry position; everything else is .none.
fn childPosition(node: ASTNode, child: ASTNode, inherited: SitePosition) SitePosition {
    switch (node) {
        .flow => |f| {
            // A flow's child is its root site — same SiteRef shape as any
            // nested site, plus the wrapper-layer datum of which Item it is.
            if (child == .continuation) return .{ .site = .{ .holding = &f.body, .wrapper = f } };
            return .none;
        },
        .continuation => |c| {
            // The continuation's own step node (and the invocation inside it)
            // sits at this continuation. If this continuation IS some flow's
            // root body, the inherited position already says so — keep the
            // wrapper. Branch continuations start fresh (.none).
            if (child == .node) {
                const wrapper: ?*ast.Flow = switch (inherited) {
                    .site => |s| if (s.holding == c) s.wrapper else null,
                    else => null,
                };
                return .{ .site = .{ .holding = c, .wrapper = wrapper } };
            }
            return .none;
        },
        .node => {
            if (child == .invocation) {
                // .node passes through the position its parent continuation
                // assigned — unless this is a position no transform supports
                // (conditional_block bodies and the like).
                return switch (inherited) {
                    .site => inherited,
                    else => .opaque_position,
                };
            }
            // conditional_block children are nested step nodes
            return .opaque_position;
        },
        else => return .none,
    }
}

/// Generic depth-first walker for any ASTNode
/// DEPTH-FIRST: Always check children BEFORE checking self
/// This ensures inner/nested transforms run before outer transforms
fn walkNode(
    node: ASTNode,
    program: *const Program,
    transforms: []const TransformEntry,
    allocator: std.mem.Allocator,
    position: SitePosition,
) anyerror!WalkResult {
    // Claimed-region transforms are checked BEFORE children on the nearest
    // lexical container that owns the invocation. This is the one place where
    // we intentionally violate normal depth-first ordering.
    if (getClaimCandidate(node, position)) |candidate| {
        if (!candidate.node.isAlreadyTransformed()) {
            for (transforms) |transform| {
                if (!transform.claims_descendants) continue;
                if (!candidate.node.matchesTransform(transform.name)) continue;

                const claim_result = try applyTransform(candidate.node, candidate.position, program, transform, allocator);
                if (claim_result.found) {
                    return claim_result;
                }

                break;
            }
        }
    }

    // DEPTH-FIRST: Walk children first
    const children = try node.children(allocator);
    defer allocator.free(children);

    for (children) |child| {
        const result = try walkNode(child, program, transforms, allocator, childPosition(node, child, position));
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
            if (transform.claims_descendants) continue;
            if (node.matchesTransform(transform.name)) {
                return try applyTransform(node, position, program, transform, allocator);
            }
        }

        // Check if this invocation matches an [expand] event
        // log.debug("[WALK] -> Checking for [expand] match\n", .{});
        const expand_result = try handleExpandIfMatches(node, position, program, allocator);
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

const ClaimCandidate = struct {
    node: ASTNode,
    position: SitePosition,
};

fn getClaimCandidate(node: ASTNode, position: SitePosition) ?ClaimCandidate {
    return switch (node) {
        .flow => |flow| ClaimCandidate{
            .node = ASTNode{ .invocation = flow.invMut() },
            .position = .{ .site = .{ .holding = &flow.body, .wrapper = flow } },
        },
        .continuation => |cont| blk: {
            if (cont.node) |*step| {
                if (step.* == .invocation) {
                    // If this continuation IS some flow's root body, the
                    // inherited position carries the wrapper.
                    const wrapper: ?*ast.Flow = switch (position) {
                        .site => |sr| if (sr.holding == cont) sr.wrapper else null,
                        else => null,
                    };
                    break :blk ClaimCandidate{
                        .node = ASTNode{ .invocation = @constCast(&step.invocation) },
                        .position = .{ .site = .{ .holding = cont, .wrapper = wrapper } },
                    };
                }
            }
            break :blk null;
        },
        .invocation => ClaimCandidate{ .node = node, .position = position },
        else => null,
    };
}

fn applyTransform(
    node: ASTNode,
    position: SitePosition,
    program: *const Program,
    transform: TransformEntry,
    allocator: std.mem.Allocator,
) !WalkResult {
    // Position-agnostic site contract: handlers ALWAYS see their invocation
    // as a flow's own invocation. A site that already IS some flow's root
    // body runs directly (the wrapper Item gets replaced); any other site is
    // wrapped in a synthetic flow first and the handler's result is grafted
    // back afterwards. This is the write-back dispatch — the ONLY place that
    // may consult the wrapper.
    const lifted: ?LiftedSite = switch (position) {
        .site => |sr| if (sr.wrapper != null) null else try liftSite(allocator, program, sr.holding),
        .none, .opaque_position => {
            log.err("TRANSFORM ERROR: transform '{s}' matched an invocation at an unsupported AST position (e.g. inside a conditional_block). Transforms can fire on flow invocations and continuation steps only.\n", .{transform.name});
            return error.TransformAtUnsupportedPosition;
        },
    };

    const handler_node = if (lifted) |l| l.site_node else node;
    const handler_program = if (lifted) |l| l.site_program else program;

    const transformed = try transform.handler_fn(handler_node, handler_program, allocator);

    // If a transform returns the same pointer, it can't/won't transform
    // this invocation (e.g., already processed via inline_body but not
    // annotated with @pass_ran). Instead of aborting all transforms,
    // mark the invocation as processed so the walker skips it, and
    // continue looking for other transforms.
    //
    // The marking always goes to the REAL invocation (node), never the lifted
    // copy — the synthetic site program is rebuilt from scratch on the next
    // walk iteration, so annotations on the copy would be lost.
    if (transformed == handler_program) {
        log.debug("Transform '{s}' returned same pointer, marking as processed\n", .{transform.name});
        const mutable_inv = @constCast(node.invocation);
        const new_annotations = allocator.alloc([]const u8, mutable_inv.annotations.len + 1) catch {
            return error.TransformReturnedSamePointer;
        };
        for (mutable_inv.annotations, 0..) |ann, ai| {
            new_annotations[ai] = ann;
        }
        new_annotations[mutable_inv.annotations.len] = "@pass_ran(\"transform\")";
        mutable_inv.annotations = new_annotations;

        // Also strip Source/Expression args so the emitter doesn't see
        // comptime-only parameters on a passthrough transform.
        var clean_count: usize = 0;
        for (mutable_inv.args) |arg| {
            if (arg.source_value == null and arg.expression_value == null) {
                clean_count += 1;
            }
        }
        if (clean_count < mutable_inv.args.len) {
            const clean_args = allocator.alloc(Arg, clean_count) catch {
                return error.TransformReturnedSamePointer;
            };
            var ci: usize = 0;
            for (mutable_inv.args) |arg| {
                if (arg.source_value == null and arg.expression_value == null) {
                    clean_args[ci] = arg;
                    ci += 1;
                }
            }
            mutable_inv.args = clean_args;
        }

        // If this is a comptime-only invocation (had Source/Expression args),
        // remove the containing flow from the program so the emitter doesn't
        // try to generate runtime code for a comptime event.
        if (clean_count == 0) {
            // All args were comptime-only — remove this flow entirely
            const new_program = removeFlowFromProgram(allocator, program, node.invocation) catch {
                return WalkResult{ .found = false, .program = program };
            };
            if (new_program) |np| {
                return WalkResult{ .found = true, .program = np };
            }
        }

        // Continue walking — don't abort the entire transform pipeline
        return WalkResult{ .found = false, .program = program };
    }

    // CIRCUIT BREAKER: Verify the transform made progress.
    // Count matching flows before and after - if count didn't decrease,
    // the transform isn't making progress (infinite loop).
    const count_before = countMatchingFlowsInProgram(transform.name, handler_program);
    const count_after = countMatchingFlowsInProgram(transform.name, transformed);

    if (count_after >= count_before and count_before > 0) {
        log.err("\n", .{});
        log.err("╔══════════════════════════════════════════════════════════════════╗\n", .{});
        log.err("║  TRANSFORM ERROR: Invocation not replaced!                       ║\n", .{});
        log.err("╚══════════════════════════════════════════════════════════════════╝\n", .{});
        log.err("\n", .{});
        log.err("Transform '{s}' returned a new program, but matching invocations\n", .{transform.name});
        log.err("didn't decrease ({d} before, {d} after) - infinite loop detected.\n", .{ count_before, count_after });
        log.err("\n", .{});
        log.err("FIX: Your transform must either:\n", .{});
        log.err("  1. Change the invocation path (e.g., 'query.src' -> 'query.src.impl')\n", .{});
        log.err("  2. Add @pass_ran(\"transform\") annotation to the new invocation\n", .{});
        log.err("\n", .{});
        return error.TransformDidNotReplace;
    }

    // Nested site: graft the transformed site back into its real position.
    if (lifted) |l| {
        const grafted = try graftSite(allocator, transformed, l);
        return WalkResult{ .found = true, .program = grafted };
    }

    return WalkResult{ .found = true, .program = transformed };
}

/// Check if an invocation matches an [expand] event and handle it.
/// Nested sites get the same lift/graft treatment as transform handlers, so
/// expansion is position-agnostic too.
fn handleExpandIfMatches(
    node: ASTNode,
    position: SitePosition,
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
                        return try applyExpandAtSite(node, position, program, inv_path, allocator);
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
                                return try applyExpandAtSite(node, position, program, inv_path, allocator);
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

/// Apply an [expand] template at any AST position: direct for flow
/// invocations, lift/graft for continuation steps.
fn applyExpandAtSite(
    node: ASTNode,
    position: SitePosition,
    program: *const Program,
    inv_path: []const u8,
    allocator: std.mem.Allocator,
) !WalkResult {
    switch (position) {
        .site => |sr| {
            if (sr.wrapper != null) {
                return try applyExpandTemplate(node, program, inv_path, allocator);
            }
            const lifted = try liftSite(allocator, program, sr.holding);
            const result = try applyExpandTemplate(lifted.site_node, lifted.site_program, inv_path, allocator);
            if (!result.found) {
                return WalkResult{ .found = false, .program = program };
            }
            const grafted = try graftSite(allocator, result.program, lifted);
            return WalkResult{ .found = true, .program = grafted };
        },
        .none, .opaque_position => {
            log.err("TRANSFORM ERROR: [expand] event '{s}' invoked at an unsupported AST position (e.g. inside a conditional_block). Expansion works on flow invocations and continuation steps only.\n", .{inv_path});
            return error.TransformAtUnsupportedPosition;
        },
    }
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
    const new_inv_annotations = allocator.alloc([]const u8, flow.inv().annotations.len + 1) catch {
        log.debug("[EXPAND] ERROR: Failed to allocate annotations\n", .{});
        return WalkResult{ .found = false, .program = program };
    };
    for (flow.inv().annotations, 0..) |ann, i| {
        new_inv_annotations[i] = ann;
    }
    new_inv_annotations[flow.inv().annotations.len] = allocator.dupe(u8, "@pass_ran(\"transform\")") catch {
        log.debug("[EXPAND] ERROR: Failed to dupe annotation\n", .{});
        return WalkResult{ .found = false, .program = program };
    };

    const new_invocation = ast.Invocation{
        .path = flow.inv().path,
        .args = flow.inv().args,
        .annotations = new_inv_annotations,
        .inserted_by_tap = flow.inv().inserted_by_tap,
        .from_opaque_tap = flow.inv().from_opaque_tap,
    };

    // For expand with continuations:
    // - Set inline_body to the template output (produces union value)
    // - Keep continuations as-is (for validation and branch bodies)
    // - The emitter will detect inline_body + continuations and generate a switch
    //
    // This preserves flow validation (branches match event definition) while
    // still allowing the template to provide the switch expression.

    // Create new flow with inline_body set (emitter handles the switch
    // generation). The body keeps the original branch handlers; only the
    // node (invocation) is swapped.
    var new_body = flow.body;
    new_body.node = .{ .invocation = new_invocation };
    const new_flow = ast.Flow{
        .body = new_body,
        .annotations = flow.annotations,
        .pre_label = flow.pre_label,
        .post_label = flow.post_label,
        .super_shape = flow.super_shape,
        .inline_body = inline_body, // Template output becomes inline_body
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
