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

/// Convert a replacement Item into a continuation node + children, for
/// splicing into a NESTED site (a continuation, not a top-level Item).
/// Harvested from the old graft path: a flow becomes its invocation + branch
/// continuations (migrating inline_body to the canonical Invocation slot);
/// inline_code becomes a raw host-code node with no children.
const NodeConv = struct {
    node: ast.Node,
    children: []const ast.Continuation,
    /// True only for the preamble graft (capture & friends): the children are a
    /// synthesized `''` void-chain that must inherit the transform exemption at
    /// the nested holding continuation. See ast.Continuation.is_transformed_subtree.
    mark_transformed: bool = false,
};
fn itemToNode(item: *const ast.Item) !NodeConv {
    switch (item.*) {
        .flow => |*f| {
            // @preamble_then_call (escape-driven stack alloc, field:new.on-stack): the
            // preamble declares caller-frame stack vars and we STILL make the routed
            // call — UNLIKE ~const/~capture, whose preamble REPLACES the call. Carry the
            // preamble on the invocation (Invocation.preamble_code) and fall through to
            // the normal invocation node below; the nested emitter emits it before the call.
            const keep_call = blk_kc: {
                for (f.inv().annotations) |ann| {
                    if (std.mem.eql(u8, ann, "@preamble_then_call")) break :blk_kc true;
                }
                break :blk_kc false;
            };
            if (f.preamble_code != null and !keep_call) {
                const preamble = f.preamble_code.?;
                // A preamble-producing transform (e.g. `capture`: the
                // `var <cell> = …;` decl) at a NESTED site. At flow level the
                // emitter emits the preamble verbatim, then the body
                // continuations directly, and SKIPS the marker invocation
                // (emitter_helpers.zig:3801). A void `inline_code` node
                // reproduces that contract exactly: the preamble emits
                // verbatim, and because `inline_code` is a void step
                // (emitter_helpers.zig:7379) its children emit directly as a
                // void chain (:7492) — not as result-switch arms. The marker
                // invocation is dropped here, mirroring the flow-level skip.
                return .{
                    .node = ast.Node{ .inline_code = preamble },
                    .children = f.body.continuations,
                    .mark_transformed = true,
                };
            }
            var new_inv = f.inv().*;
            // Flow.inline_body delegates to Invocation.inline_body (canonical).
            if (f.inline_body != null and new_inv.inline_body == null) {
                new_inv.inline_body = f.inline_body;
            }
            // Carry a @preamble_then_call preamble onto the invocation so the nested
            // emitter can emit it before the routed handler call.
            if (f.preamble_code) |preamble| {
                new_inv.preamble_code = preamble;
            }
            return .{ .node = ast.Node{ .invocation = new_inv }, .children = f.body.continuations };
        },
        .inline_code => |*ic| {
            return .{ .node = ast.Node{ .inline_code = ic.code }, .children = &[_]ast.Continuation{} };
        },
        else => {
            log.err("TRANSFORM ERROR: a nested transform site must be replaced by a flow or inline_code item, got {s}.\n", .{@tagName(item.*)});
            return error.TransformNestedSiteBadItem;
        },
    }
}

/// Find the flow containing a holding continuation (to copy module / purity
/// onto the synthetic site-view flow). Recurses into module_decls.
fn findContainingFlow(items: []const ast.Item, target: *const ast.Continuation) ?*const ast.Flow {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                if (contHoldsTarget(f.body.continuations, target)) return f;
            },
            .module_decl => |*m| {
                if (findContainingFlow(m.items, target)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}
fn contHoldsTarget(conts: []const ast.Continuation, target: *const ast.Continuation) bool {
    for (conts) |*cont| {
        if (cont == target) return true;
        if (contHoldsTarget(cont.continuations, target)) return true;
    }
    return false;
}

/// A read-only view of a nested site AS a top-level flow. Handlers build their
/// replacement from `item.flow.body`, so they must read the SITE's invocation
/// and children — not the containing flow's. This wraps the site continuation
/// in a synthetic top-level flow appended to a program copy. It is READ-only:
/// the heavy old graft (marker + path navigation) is gone — write-back is the
/// runner's SiteResult splice into the real program afterwards.
const SiteView = struct { program: *const Program, node: ASTNode };
fn siteView(allocator: std.mem.Allocator, program: *const Program, holding: *ast.Continuation) !SiteView {
    const containing = findContainingFlow(program.items, holding) orelse {
        log.err("TRANSFORM RUNNER BUG: nested transform site not reachable from program root.\n", .{});
        return error.TransformSiteNotInProgram;
    };
    const site_flow = ast.Flow{
        .body = holding.*,
        .location = holding.location,
        .module = containing.module,
        .is_pure = containing.is_pure,
        .is_transitively_pure = containing.is_transitively_pure,
    };
    const site_items = try allocator.alloc(ast.Item, program.items.len + 1);
    @memcpy(site_items[0..program.items.len], program.items);
    site_items[program.items.len] = ast.Item{ .flow = site_flow };
    const site_program = try allocator.create(Program);
    site_program.* = program.*;
    site_program.items = site_items;
    return .{
        .program = site_program,
        .node = ASTNode{ .invocation = site_items[program.items.len].flow.invMut() },
    };
}

/// Append new top-level items to a program, returning a fresh program.
fn appendItems(allocator: std.mem.Allocator, program: *const Program, extra: []const ast.Item) !*const Program {
    const new_items = try allocator.alloc(ast.Item, program.items.len + extra.len);
    @memcpy(new_items[0..program.items.len], program.items);
    @memcpy(new_items[program.items.len..], extra);
    const np = try allocator.create(Program);
    np.* = program.*;
    np.items = new_items;
    return np;
}

/// The site-local write-back: place a handler's SiteResult into the program.
/// The runner OWNS all placement — this is the single splice point that the
/// per-handler `replaceFlowRecursive` calls collapsed into. Root sites replace
/// their flow Item directly; nested sites replace the holding continuation's
/// invocation (node + children) functionally, keyed on the original pointer
/// (valid because handlers no longer clone the program). Appended items are
/// added to the top level. Returns the original program pointer if nothing
/// changed (the no-op signal the caller checks before reaching here).
fn spliceSiteResult(
    allocator: std.mem.Allocator,
    program: *const Program,
    sr: SiteRef,
    result: ast.SiteResult,
) !*const Program {
    // Whole-program escape: the handler rewrote the entire program (e.g. tap).
    // Use it verbatim; site-local placement does not apply.
    if (result.whole_program) |wp| return wp;

    var current: *const Program = program;

    if (result.replacement) |*repl| {
        if (sr.wrapper) |flow| {
            // Root site: the site IS a flow's Item — replace it wholesale.
            const maybe = try ast_functional.replaceFlowRecursive(allocator, current, flow, repl.*);
            const np = maybe orelse {
                log.err("TRANSFORM ERROR: root site flow not found during write-back.\n", .{});
                return error.TransformSiteNotFound;
            };
            const boxed = try allocator.create(Program);
            boxed.* = np;
            current = boxed;
        } else {
            // Nested site: replace the holding continuation's invocation in
            // place (node + branch continuations), keyed on the original
            // invocation pointer.
            const conv = try itemToNode(repl);
            const target_inv = &sr.holding.node.?.invocation;
            const maybe = try ast_functional.replaceInvocationNodeAndContinuationsRecursive(
                allocator,
                current,
                target_inv,
                conv.node,
                conv.children,
                conv.mark_transformed,
            );
            const np = maybe orelse {
                log.err("TRANSFORM ERROR: nested site invocation not found during write-back.\n", .{});
                return error.TransformSiteNotFound;
            };
            const boxed = try allocator.create(Program);
            boxed.* = np;
            current = boxed;
        }
    }

    if (result.replacement_node) |nr| {
        if (sr.wrapper) |flow| {
            // Root site. A flow's body node must be an invocation (shape
            // checker, emitter, clone all assume it). So:
            //  - inline_code node → the flow DISSOLVES into a top-level
            //    Item.inline_code (e.g. `step`, removed after init fusion).
            //  - invocation node → rebuild the flow with the new invocation body.
            // (A non-invocation, non-inline_code node at a flow root has no
            // representation — reject loudly rather than forge a bad flow.)
            const new_item: ast.Item = switch (nr.node) {
                .inline_code => |code| ast.Item{ .inline_code = ast.InlineCode{
                    .code = code,
                    .location = flow.location,
                    .module = flow.module,
                } },
                .invocation => blk: {
                    var new_flow = flow.*;
                    var new_body = flow.body;
                    new_body.node = nr.node;
                    if (nr.children) |ch| new_body.continuations = ch;
                    new_flow.body = new_body;
                    break :blk ast.Item{ .flow = new_flow };
                },
                else => {
                    log.err("TRANSFORM ERROR: cannot replace a root-site flow body with a {s} node — only invocation or inline_code are representable at a flow root.\n", .{@tagName(nr.node)});
                    return error.TransformBadRootNode;
                },
            };
            const maybe = try ast_functional.replaceFlowRecursive(allocator, current, flow, new_item);
            const np = maybe orelse {
                log.err("TRANSFORM ERROR: root site flow not found during node write-back.\n", .{});
                return error.TransformSiteNotFound;
            };
            const boxed = try allocator.create(Program);
            boxed.* = np;
            current = boxed;
        } else {
            // Nested site: replace the holding continuation's invocation node.
            // null children → keep existing (node-only replace); non-null →
            // replace node + children.
            const target_inv = &sr.holding.node.?.invocation;
            const maybe = if (nr.children) |ch|
                try ast_functional.replaceInvocationNodeAndContinuationsRecursive(allocator, current, target_inv, nr.node, ch, false)
            else
                try ast_functional.replaceInvocationNodeRecursive(allocator, current, target_inv, nr.node);
            const np = maybe orelse {
                log.err("TRANSFORM ERROR: nested site invocation not found during node write-back.\n", .{});
                return error.TransformSiteNotFound;
            };
            const boxed = try allocator.create(Program);
            boxed.* = np;
            current = boxed;
        }
    }

    if (result.appended.len > 0) {
        current = try appendItems(allocator, current, result.appended);
    }

    return current;
}


/// Count how many invocations in the program match the transform.
/// Includes both top-level flows AND nested invocations in continuations.
/// Used to detect infinite loops: if the count doesn't decrease after a transform,
/// the transform isn't making progress.
fn countMatchingFlowsInProgram(transform: *const TransformEntry, program: *const Program) usize {
    var count: usize = 0;

    for (program.items) |item| {
        switch (item) {
            .flow => |flow| {
                count += countMatchingInFlow(&flow, transform, program);
            },
            .immediate_impl => {},
            .module_decl => |module| {
                for (module.items) |mod_item| {
                    switch (mod_item) {
                        .flow => |flow| {
                            count += countMatchingInFlow(&flow, transform, program);
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
fn countMatchingInFlow(flow: *const ast.Flow, transform: *const TransformEntry, program: *const Program) usize {
    return countMatchingInContinuation(&flow.body, transform, program);
}

/// Recursively count matching invocations in a site (node + branch handlers).
fn countMatchingInContinuation(cont: *const ast.Continuation, transform: *const TransformEntry, program: *const Program) usize {
    var count: usize = 0;

    if (cont.node) |node| {
        if (node == .invocation) {
            if (flowStillMatchesTransform(&node.invocation, transform, program)) {
                count += 1;
            }
        }
    }

    for (cont.continuations) |*child| {
        count += countMatchingInContinuation(child, transform, program);
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

/// THE dispatch predicate: does this node fire this transform?
/// One function so walk-time matching and progress-counting can never drift.
fn invocationMatchesEntry(node: ASTNode, transform: *const TransformEntry, program: *const Program) bool {
    if (node != .invocation) return false;
    if (!qualifierGateOpen(node.invocation, transform)) return false;
    if (!node.matchesTransform(transform.name)) return false;
    if (shadowedByLocalEvent(node.invocation, transform, program)) return false;
    return true;
}

/// Local-first shadowing: a source-bare invocation whose name the MAIN
/// MODULE declares as an event is local — an imported module's legacy
/// transform must not capture it (the 120_002 name-priority rule). After
/// canonicalization every path carries a qualifier; "bare in source" means
/// the qualifier is the main module (or, pre-canonicalize, null). Globs are
/// exempt (taps capture user events by design); qualified-only entries never
/// reach this (the qualifier gate already decided).
fn shadowedByLocalEvent(inv: *const Invocation, transform: *const TransformEntry, program: *const Program) bool {
    if (!transform.from_module) return false;
    if (inv.path.module_qualifier) |mq| {
        if (!std.mem.eql(u8, mq, program.main_module_name)) return false;
    }
    if (std.mem.indexOfScalar(u8, transform.name, '*') != null) return false;
    return hasLocalEventDecl(program, inv.path.segments);
}

/// True if the program's main module (top-level items) declares an event
/// with exactly these path segments.
fn hasLocalEventDecl(program: *const Program, segments: []const []const u8) bool {
    for (program.items) |item| {
        if (item != .event_decl) continue;
        const decl = item.event_decl;
        if (decl.path.segments.len != segments.len) continue;
        var equal = true;
        for (decl.path.segments, segments) |a, b| {
            if (!std.mem.eql(u8, a, b)) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

/// Qualified-only gate: entries with a qualifier fire only when the
/// invocation spells that module qualifier. Legacy entries (null) pass.
fn qualifierGateOpen(inv: *const Invocation, transform: *const TransformEntry) bool {
    const required = transform.qualifier orelse return true;
    const spelled = inv.path.module_qualifier orelse return false;
    return std.mem.eql(u8, spelled, required);
}

fn flowStillMatchesTransform(inv: *const Invocation, transform: *const TransformEntry, program: *const Program) bool {
    if (!qualifierGateOpen(inv, transform)) return false;
    if (shadowedByLocalEvent(inv, transform, program)) return false;
    const transform_name = transform.name;
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

    /// Qualified-only dispatch: when set, an invocation fires this transform
    /// ONLY if it spells this module qualifier (dotted user form, e.g.
    /// "std.regex"). Proc-transforms (`~[transform]proc` on an ordinary
    /// event) set this — they never capture bare names, which kills the
    /// wrong-module-capture soundness bug structurally. Null = legacy
    /// bare-segment matching (globs included).
    qualifier: ?[]const u8 = null,

    /// True when the transform lives in an imported module (legacy
    /// bare-matchable entries). Local-first shadowing applies: a bare
    /// invocation that resolves to a MAIN-MODULE event declaration is local,
    /// and an imported module's transform must not capture it. Glob entries
    /// are exempt — taps capture user events by design.
    from_module: bool = false,

    /// When true, this transform claims its lexical descendants and is checked
    /// before child traversal. This lets region-owning constructs see raw
    /// downstream structure before peer transforms rewrite it.
    claims_descendants: bool = false,

    /// Handler function that takes (node, program, allocator) and returns a
    /// SiteResult — the site-local write-back ABI. The handler describes its
    /// change as a value (replace this site / append these items); the RUNNER
    /// owns all placement. Handlers never splice into the whole program.
    /// - node: The ASTNode being transformed (will be .invocation for transforms)
    /// - program: The current program AST (immutable to the handler)
    /// - allocator: For any allocations needed during transformation
    handler_fn: *const fn (node: ASTNode, program: *const Program, allocator: std.mem.Allocator) anyerror!ast.SiteResult,
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
                if (!invocationMatchesEntry(candidate.node, &transform, program)) continue;

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
            if (invocationMatchesEntry(node, &transform, program)) {
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
                            const result = try transform.handler_fn(node, program, allocator);

                            if (result.replacement == null and result.replacement_node == null and result.whole_program == null and result.appended.len == 0) {
                                log.debug("ERROR: Derive handler '{s}' produced an empty SiteResult!\n", .{handler_name});
                                return error.TransformReturnedSamePointer;
                            }

                            // Derive operates at the ITEM level: `replacement`
                            // swaps the derived event_decl (re-annotated so it
                            // isn't re-processed); `appended` are the generated
                            // declarations. Build the new program directly,
                            // matching the source item by pointer identity.
                            const target_item: *const ast.Item = node.item;
                            const new_items = try allocator.alloc(ast.Item, program.items.len + result.appended.len);
                            var w: usize = 0;
                            for (program.items) |*pit| {
                                if (pit == target_item and result.replacement != null) {
                                    new_items[w] = result.replacement.?;
                                } else {
                                    new_items[w] = pit.*;
                                }
                                w += 1;
                            }
                            for (result.appended) |ai| {
                                new_items[w] = ai;
                                w += 1;
                            }
                            const np = try allocator.create(Program);
                            np.* = program.*;
                            np.items = new_items[0..w];
                            return WalkResult{ .found = true, .program = np };
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
        .flow => |flow| blk: {
            // Only a flow whose body node is an invocation is a transform site.
            // After a site-local splice a flow's body can be inline_code (e.g. a
            // root-site kernel op lowered to a loop) — that is already-lowered,
            // not a candidate.
            const body_node = flow.body.node orelse break :blk null;
            if (body_node != .invocation) break :blk null;
            break :blk ClaimCandidate{
                .node = ASTNode{ .invocation = flow.invMut() },
                .position = .{ .site = .{ .holding = &flow.body, .wrapper = flow } },
            };
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
    // Position-agnostic site contract: the handler sees its invocation and
    // describes its change as a SiteResult; THIS function owns all placement
    // (root replace / nested replace / append). No lifting, no grafting.
    const sr: SiteRef = switch (position) {
        .site => |s| s,
        .none, .opaque_position => {
            log.err("TRANSFORM ERROR: transform '{s}' matched an invocation at an unsupported AST position (e.g. inside a conditional_block). Transforms can fire on flow invocations and continuation steps only.\n", .{transform.name});
            return error.TransformAtUnsupportedPosition;
        },
    };

    // Nested sites: hand the handler a read-view where its site IS a top-level
    // flow, so `item.flow.body` reads the SITE's invocation + children (not the
    // containing flow's). Root sites already see the real flow item. Write-back
    // is the SiteResult splice into the REAL program, below.
    var handler_node = node;
    var handler_program = program;
    if (sr.wrapper == null) {
        const view = try siteView(allocator, program, sr.holding);
        handler_node = view.node;
        handler_program = view.program;
    }

    const result = try transform.handler_fn(handler_node, handler_program, allocator);

    // Empty SiteResult = no-op: the handler declined / already processed this
    // invocation (e.g. inline_body present but not yet @pass_ran-annotated).
    // Mark the REAL invocation so the walker skips it, and keep going — don't
    // abort the pipeline. (Mirrors the old same-pointer signal.)
    if (result.replacement == null and result.replacement_node == null and result.whole_program == null and result.appended.len == 0) {
        log.debug("Transform '{s}' produced an empty SiteResult, marking as processed\n", .{transform.name});
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

    // Place the change. The runner owns the splice — root site replaces its
    // flow Item, nested site replaces the holding continuation, appended items
    // go to the top level. This is the single write-back point.
    const spliced = try spliceSiteResult(allocator, program, sr, result);

    // CIRCUIT BREAKER: Verify the transform made progress.
    // Count matching invocations before and after - if the count didn't
    // decrease, the transform isn't making progress (infinite loop).
    const count_before = countMatchingFlowsInProgram(&transform, program);
    const count_after = countMatchingFlowsInProgram(&transform, spliced);

    if (count_after >= count_before and count_before > 0) {
        log.err("\n", .{});
        log.err("╔══════════════════════════════════════════════════════════════════╗\n", .{});
        log.err("║  TRANSFORM ERROR: Invocation not replaced!                       ║\n", .{});
        log.err("╚══════════════════════════════════════════════════════════════════╝\n", .{});
        log.err("\n", .{});
        log.err("Transform '{s}' produced a SiteResult, but matching invocations\n", .{transform.name});
        log.err("didn't decrease ({d} before, {d} after) - infinite loop detected.\n", .{ count_before, count_after });
        log.err("\n", .{});
        log.err("FIX: Your transform must either:\n", .{});
        log.err("  1. Change the invocation path (e.g., 'query.src' -> 'query.src.impl')\n", .{});
        log.err("  2. Add @pass_ran(\"transform\") annotation to the new invocation\n", .{});
        log.err("\n", .{});
        return error.TransformDidNotReplace;
    }

    return WalkResult{ .found = true, .program = spliced };
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

/// Apply an [expand] template at any AST position. The template produces a
/// replacement flow Item; the runner's site-local splice places it (root site
/// replaces the flow, nested site replaces the holding continuation).
fn applyExpandAtSite(
    node: ASTNode,
    position: SitePosition,
    program: *const Program,
    inv_path: []const u8,
    allocator: std.mem.Allocator,
) !WalkResult {
    const sr: SiteRef = switch (position) {
        .site => |s| s,
        .none, .opaque_position => {
            log.err("TRANSFORM ERROR: [expand] event '{s}' invoked at an unsupported AST position (e.g. inside a conditional_block). Expansion works on flow invocations and continuation steps only.\n", .{inv_path});
            return error.TransformAtUnsupportedPosition;
        },
    };
    const maybe_item = try applyExpandTemplate(node, position, program, inv_path, allocator);
    const repl = maybe_item orelse return WalkResult{ .found = false, .program = program };
    const spliced = try spliceSiteResult(allocator, program, sr, .{ .replacement = repl });
    return WalkResult{ .found = true, .program = spliced };
}

/// Render an [expand] template into a replacement flow Item (or null if there
/// is no template / rendering failed). The BODY (branch continuations) and the
/// invocation come from the SITE itself — root site uses the flow's own body,
/// a nested site uses the holding continuation — so expansion is position-
/// agnostic without any lift/graft. Non-structural flow fields (location,
/// purity, labels) come from the containing flow.
fn applyExpandTemplate(
    node: ASTNode,
    position: SitePosition,
    program: *const Program,
    event_name: []const u8,
    allocator: std.mem.Allocator,
) !?ast.Item {
    const invocation = node.invocation;

    // Look up template by event name
    const template_source = template_utils.lookupTemplate(program, event_name) orelse {
        log.debug("[EXPAND] WARNING: No template found for '{s}'\n", .{event_name});
        return null;
    };

    // Build Liquid context from invocation args (Expression parameters)
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    for (invocation.args) |arg| {
        if (arg.expression_value) |expr_val| {
            ctx.put(arg.name, .{ .string = expr_val.text }) catch {
                log.debug("[EXPAND] ERROR: Failed to add arg to context\n", .{});
                return null;
            };
        }
    }

    // Render template with Liquid engine
    const inline_body = liquid.render(allocator, template_source, &ctx) catch |err| {
        log.debug("[EXPAND] ERROR: Liquid render failed: {}\n", .{err});
        return null;
    };

    // Base flow supplies the non-structural fields; the BODY comes from the
    // site (below), so this works for both root and nested sites.
    const containing_item = ASTNode.findContainingItem(program, invocation) orelse {
        log.debug("[EXPAND] ERROR: Could not find containing item\n", .{});
        return null;
    };
    const base_flow = if (containing_item.* == .flow)
        &containing_item.flow
    else {
        log.debug("[EXPAND] ERROR: Containing item is not a flow\n", .{});
        return null;
    };

    // @pass_ran on the site invocation so it isn't re-expanded.
    const new_inv_annotations = try allocator.alloc([]const u8, invocation.annotations.len + 1);
    for (invocation.annotations, 0..) |ann, i| {
        new_inv_annotations[i] = ann;
    }
    new_inv_annotations[invocation.annotations.len] = try allocator.dupe(u8, "@pass_ran(\"transform\")");

    const new_invocation = ast.Invocation{
        .path = invocation.path,
        .args = invocation.args,
        .annotations = new_inv_annotations,
        .inserted_by_tap = invocation.inserted_by_tap,
        .from_opaque_tap = invocation.from_opaque_tap,
    };

    // Body comes from the SITE: root → the flow's own body; nested → the
    // holding continuation. Branch continuations are preserved; only the node
    // (invocation) is swapped. inline_body carries the template output and the
    // emitter generates the switch.
    var new_body: ast.Continuation = switch (position) {
        .site => |sr| if (sr.wrapper != null) base_flow.body else sr.holding.*,
        else => base_flow.body,
    };
    new_body.node = .{ .invocation = new_invocation };

    var new_flow = base_flow.*;
    new_flow.body = new_body;
    new_flow.inline_body = inline_body;
    return ast.Item{ .flow = new_flow };
}
