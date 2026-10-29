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
const ast_json = @import("ast_json");
const glob_pattern_matcher = @import("glob_pattern_matcher");

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
                for (f.inv().marks) |mark| {
                    if (std.mem.eql(u8, mark, "@preamble_then_call")) break :blk_kc true;
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

/// The call that produced a nested site's branch: the continuation whose
/// children list holds `site` — `flow.body` itself when the site sits on the
/// flow head. Returns a REAL-tree pointer (walks `program.items`, not the
/// site view's shallow-copied items), so `&result.node.?.invocation`
/// resolves in the functional-replacement pass.
fn findSiteProducer(items: []const ast.Item, site: *const ast.Continuation) ?*const ast.Continuation {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                for (f.body.continuations) |*c| {
                    if (c == site) return &f.body;
                }
                if (findSiteProducerInConts(f.body.continuations, site)) |p| return p;
            },
            .module_decl => |*m| {
                if (findSiteProducer(m.items, site)) |p| return p;
            },
            else => {},
        }
    }
    return null;
}
fn findSiteProducerInConts(conts: []const ast.Continuation, site: *const ast.Continuation) ?*const ast.Continuation {
    for (conts) |*cont| {
        for (cont.continuations) |*c| {
            if (c == site) return cont;
        }
        if (findSiteProducerInConts(cont.continuations, site)) |p| return p;
    }
    return null;
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
        // The REAL holding continuation — a back-pointer so a transform can
        // recover the enclosing scope the view detaches (emitter_helpers.
        // scopeAtSite walks the real program from the containing flow down
        // to this continuation).
        .site_of = holding,
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
/// The module an appended declaration ADDRESSES itself into — its qualified
/// path, not the file it was synthesized from. A transform firing inside an
/// imported module mints declarations for that module; dropping them at program
/// top level leaves every consumer that reads structure disagreeing with every
/// consumer that reads the path. `shape_checker` registers top-level decls under
/// the ENTRY file's name, so a declaration qualified `app.lib` sitting at top
/// level is registered as `input:…` and its own impl flow can never find it
/// (690_079).
fn appendedItemModule(item: ast.Item) ?[]const u8 {
    return switch (item) {
        .event_decl => |ed| ed.path.module_qualifier,
        // A proc is its event's body. Leaving it at top level while the event
        // moves into the module separates the pair, and the event emits with a
        // stub handler instead of the proc's code.
        .proc_decl => |pd| pd.path.module_qualifier,
        .flow => |f| if (f.impl_of) |io| io.module_qualifier else null,
        // Host lines carry no path; the module they declare themselves into is
        // the only signal, and a synthesized cell sets it to the namespace its
        // accessors were minted under.
        .host_line => |h| h.module,
        // Inline code is the same signal one item type over: a synthesized Zig
        // unit (regex's automaton, field's dispatch table) whose call site is
        // emitted inside the module struct. Zig gives a sibling struct no path
        // to the entry struct, so an unrouted unit is emitted where nothing can
        // reach it.
        .inline_code => |ic| ic.module,
        // A host type is a declaration like any other: it must sit in the same
        // struct as the code that names it, because Zig gives a sibling struct
        // no path to the entry struct. It carries no path and no location, so
        // `module` is the ONLY signal it has (115_005).
        .host_type_decl => |h| h.module,
        else => null,
    };
}

/// Where an appended item was SYNTHESIZED — the file the transform ran over.
/// A file path belongs to no naming domain, so it settles the question
/// `appendedItemModule` cannot.
fn appendedItemFile(item: ast.Item) ?[]const u8 {
    return switch (item) {
        .event_decl => |ed| ed.location.file,
        .proc_decl => |pd| pd.location.file,
        .flow => |f| f.location.file,
        .host_line => |h| h.location.file,
        .inline_code => |ic| ic.location.file,
        else => null,
    };
}

/// The module an appended item belongs inside, as a `logical_name` the rest of
/// the program agrees on.
///
/// A transform names its home with `flow.module`, and that is the FILE-derived
/// name — `lib` for `lib.k`. Every routing and resolution key in the program is
/// the IMPORT-derived logical name — `app.lib`. In the entry file the two words
/// coincide, which is why nothing diverged until a transform's subject lived in
/// a module. So the name a transform hands us is a HINT: honour it when it
/// names a module that exists, and otherwise ask the item which FILE it was
/// synthesized at and match that against the module's canonical path.
fn appendedItemHome(program: *const Program, item: ast.Item) ?[]const u8 {
    if (appendedItemModule(item)) |named| {
        for (program.items) |pit| {
            if (pit == .module_decl and std.mem.eql(u8, pit.module_decl.logical_name, named)) return named;
        }
    }
    const file = appendedItemFile(item) orelse return null;
    if (file.len == 0) return null;
    const file_dir = std.fs.path.dirname(file);
    for (program.items) |pit| {
        if (pit != .module_decl) continue;
        if (std.mem.eql(u8, pit.module_decl.canonical_path, file)) return pit.module_decl.logical_name;
        // A directory module's canonical_path is the DIRECTORY (`mymod/`),
        // while an item synthesized in `mymod/index.k` names the file — the
        // file belongs to the module whose directory is its parent.
        if (file_dir) |dir| {
            if (std.mem.eql(u8, pit.module_decl.canonical_path, dir)) return pit.module_decl.logical_name;
        }
    }
    return null;
}

fn appendItems(allocator: std.mem.Allocator, program: *const Program, extra: []const ast.Item) !*const Program {
    // Anything naming a module that exists in this program goes inside it; the
    // rest keeps top-level placement.
    var top_level = try std.ArrayList(ast.Item).initCapacity(allocator, extra.len);
    defer top_level.deinit(allocator);

    var any_routed = false;
    for (extra) |ai| {
        var routed = false;
        if (appendedItemHome(program, ai) != null) {
            routed = true;
            any_routed = true;
        }
        if (!routed) try top_level.append(allocator, ai);
    }

    const new_items = try allocator.alloc(ast.Item, program.items.len + top_level.items.len);
    for (program.items, 0..) |pit, i| {
        new_items[i] = pit;
        if (!any_routed or pit != .module_decl) continue;
        const mod = pit.module_decl.logical_name;

        var extra_here: usize = 0;
        for (extra) |ai| {
            const m = appendedItemHome(program, ai) orelse continue;
            if (std.mem.eql(u8, m, mod)) extra_here += 1;
        }
        if (extra_here == 0) continue;

        const merged = try allocator.alloc(ast.Item, pit.module_decl.items.len + extra_here);
        @memcpy(merged[0..pit.module_decl.items.len], pit.module_decl.items);
        var w = pit.module_decl.items.len;
        for (extra) |ai| {
            const m = appendedItemHome(program, ai) orelse continue;
            if (std.mem.eql(u8, m, mod)) {
                merged[w] = ai;
                w += 1;
            }
        }
        var md = pit.module_decl;
        md.items = merged;
        new_items[i] = ast.Item{ .module_decl = md };
    }
    @memcpy(new_items[program.items.len..], top_level.items);

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
            // replace node + children. `retarget_producer` rewrites the call
            // that PRODUCED the site's branch instead — the runner finds it
            // in the real program (site-view items are shallow copies: the
            // continuation arrays are shared, but `flow.body` itself is
            // copied, so only a real-tree lookup resolves a flow head).
            const target_inv = if (nr.retarget_producer) blk: {
                const producer = findSiteProducer(current.items, sr.holding) orelse {
                    log.err("TRANSFORM ERROR: retarget_producer found no call holding the site.\n", .{});
                    return error.TransformSiteNotFound;
                };
                if (producer.node == null or producer.node.? != .invocation) {
                    log.err("TRANSFORM ERROR: retarget_producer resolved to a non-invocation node.\n", .{});
                    return error.TransformSiteNotFound;
                }
                break :blk &producer.node.?.invocation;
            } else &sr.holding.node.?.invocation;
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
fn countMatchingFlowsInProgram(allocator: std.mem.Allocator, transform: *const TransformEntry, program: *const Program) usize {
    var count: usize = 0;

    for (program.items) |item| {
        switch (item) {
            .flow => |flow| {
                count += countMatchingInFlow(allocator, &flow, transform, program);
            },
            .immediate_impl => {},
            .module_decl => |module| {
                for (module.items) |mod_item| {
                    switch (mod_item) {
                        .flow => |flow| {
                            count += countMatchingInFlow(allocator, &flow, transform, program);
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
fn countMatchingInFlow(allocator: std.mem.Allocator, flow: *const ast.Flow, transform: *const TransformEntry, program: *const Program) usize {
    return countMatchingInContinuation(allocator, &flow.body, transform, program);
}

/// Recursively count matching invocations in a site (node + branch handlers).
fn countMatchingInContinuation(allocator: std.mem.Allocator, cont: *const ast.Continuation, transform: *const TransformEntry, program: *const Program) usize {
    var count: usize = 0;

    if (cont.node) |node| {
        if (node == .invocation) {
            if (flowStillMatchesTransform(allocator, &node.invocation, transform, program)) {
                count += 1;
            }
        }
    }

    for (cont.continuations) |*child| {
        count += countMatchingInContinuation(allocator, child, transform, program);
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
fn invocationMatchesEntry(allocator: std.mem.Allocator, node: ASTNode, transform: *const TransformEntry, program: *const Program) bool {
    if (node != .invocation) return false;
    if (!qualifierGateOpen(node.invocation, transform)) return false;
    if (!node.matchesTransform(transform.name)) return false;
    if (shadowedByLocalEvent(allocator, node.invocation, transform, program)) return false;
    return true;
}

/// Local-first shadowing: a source-bare invocation whose name the MAIN
/// MODULE declares as an event is local — an imported module's legacy
/// transform must not capture it (the 120_002 name-priority rule). After
/// canonicalization every path carries a qualifier; "bare in source" means
/// the qualifier is the main module (or, pre-canonicalize, null). Globs are
/// exempt (taps capture user events by design); qualified-only entries never
/// reach this (the qualifier gate already decided).
fn shadowedByLocalEvent(allocator: std.mem.Allocator, inv: *const Invocation, transform: *const TransformEntry, program: *const Program) bool {
    if (!transform.from_module) return false;
    if (inv.path.module_qualifier) |mq| {
        if (!std.mem.eql(u8, mq, program.main_module_name)) return false;
    }
    if (std.mem.indexOfScalar(u8, transform.name, '*') != null) return false;
    return hasLocalEventDecl(allocator, program, inv.path.segments);
}

/// The main module's event-decl path set, memoized per program-items epoch.
/// `hasLocalEventDecl` sits inside the transform-match predicate — once per
/// (invocation × module transform) per full-tree rewalk — so an unmemoized
/// O(top-level items) scan there was the compile's innermost hot loop.
/// Epoch key is the items slice header, the flatItems-memo contract: every
/// structural write-back mints a fresh top-level array (a changed header means
/// rebuild), and in-place content edits cannot remove a declaration.
var local_events_epoch_ptr: usize = 0;
var local_events_epoch_len: usize = std.math.maxInt(usize);
var local_events_set: ?std.StringHashMap(void) = null;

/// Join path segments with '.' into `buf`; returns the written slice.
fn joinPathInto(buf: []u8, segments: []const []const u8) []const u8 {
    var w: usize = 0;
    for (segments, 0..) |s, i| {
        if (i > 0) {
            if (w >= buf.len) break;
            buf[w] = '.';
            w += 1;
        }
        if (w + s.len > buf.len) break;
        @memcpy(buf[w..][0..s.len], s);
        w += s.len;
    }
    return buf[0..w];
}

/// Stack-buffer twin of joinPathKey — NUL-separated lookup keys.
fn joinPathKeyInto(buf: []u8, segments: []const []const u8) ?[]const u8 {
    var w: usize = 0;
    for (segments, 0..) |s, i| {
        if (i > 0) {
            if (w >= buf.len) return null;
            buf[w] = 0;
            w += 1;
        }
        if (w + s.len > buf.len) return null;
        @memcpy(buf[w..][0..s.len], s);
        w += s.len;
    }
    return buf[0..w];
}

fn joinPathKey(allocator: std.mem.Allocator, segments: []const []const u8) []const u8 {
    var len: usize = 0;
    for (segments, 0..) |s, i| len += s.len + @intFromBool(i > 0);
    const key = allocator.alloc(u8, len) catch unreachable;
    var w: usize = 0;
    for (segments, 0..) |s, i| {
        if (i > 0) {
            key[w] = 0;
            w += 1;
        }
        @memcpy(key[w..][0..s.len], s);
        w += s.len;
    }
    return key;
}

/// True if the program's main module (top-level items) declares an event
/// with exactly these path segments.
fn hasLocalEventDecl(allocator: std.mem.Allocator, program: *const Program, segments: []const []const u8) bool {
    if (local_events_epoch_ptr != @intFromPtr(program.items.ptr) or local_events_epoch_len != program.items.len) {
        var set = std.StringHashMap(void).init(allocator);
        for (program.items) |*item| {
            if (item.* != .event_decl) continue;
            set.put(joinPathKey(allocator, item.event_decl.path.segments), {}) catch unreachable;
        }
        local_events_set = set;
        local_events_epoch_ptr = @intFromPtr(program.items.ptr);
        local_events_epoch_len = program.items.len;
    }
    var buf: [512]u8 = undefined;
    const key = joinPathKeyInto(&buf, segments) orelse return false;
    return local_events_set.?.contains(key);
}

/// Qualified-only gate: entries with a qualifier fire only when the
/// invocation spells that module qualifier. Legacy entries (null) pass.
fn qualifierGateOpen(inv: *const Invocation, transform: *const TransformEntry) bool {
    const required = transform.qualifier orelse return true;
    const spelled = inv.path.module_qualifier orelse return false;
    return std.mem.eql(u8, spelled, required);
}

fn flowStillMatchesTransform(allocator: std.mem.Allocator, inv: *const Invocation, transform: *const TransformEntry, program: *const Program) bool {
    if (!qualifierGateOpen(inv, transform)) return false;
    if (shadowedByLocalEvent(allocator, inv, transform, program)) return false;
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

    // Glob + exact matching via the canonical segment matcher
    const matches = glob_pattern_matcher.matchSegment(transform_name, inv_path);

    if (!matches) {
        return false; // Different event path - transform properly replaced itself
    }

    // Check if it has the @pass_ran mark (if so, it won't be transformed again)
    for (inv.marks) |mark| {
        if (std.mem.eql(u8, mark, "@pass_ran(\"transform\")")) {
            return false; // Has @pass_ran, won't match again
        }
    }

    // Still matches transform path without @pass_ran -> would infinite loop!
    return true;
}

/// Transform handler entry in the dispatch table
/// Ordered transform stages. `walkAndTransform` runs the fixed-point once per
/// stage in THIS declared order (pre → pre_late → main → post), so a `.pre`
/// transform is guaranteed to reach fixed point before any `.main`/`.post`
/// transform runs — the producer-before-consumer ordering that source order
/// alone cannot promise (a type-EMITTING transform must complete before a
/// transform that CONSUMES the type). `.pre_late` sits between: it consumes
/// decls `.pre` producers synthesized (component-generated tors, store cells)
/// yet still completes before `.main` `claims_descendants` transforms lift
/// raw subtrees. Set via `[transform|pre]` / `[transform|pre_late]` /
/// `[transform|post]`; untagged transforms are `.main`, so an all-`.main`
/// program is byte-identical to the legacy single-set fixed point.
pub const Stage = enum { pre, pre_late, main, post };

pub const TransformEntry = struct {
    /// Which ordered stage this transform runs in (see `Stage`).
    stage: Stage = .main,

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

    /// Declared intra-transform ordering edges ([transform|contract:requires("x")]).
    /// Frontend-validated (KORU185); carried here so witness/oracle surfaces
    /// can read the contract that produced the order they observe.
    requires: []const []const u8 = &.{},

    /// Declared blast-radius bound ([transform|contract:preserves("kind",...)]):
    /// top-level items of the named kinds must be bit-identical across this
    /// transform's write-backs. The SITE item is always licensed — it is the
    /// point of application, not collateral. Violations refuse with KORU186.
    /// Empty = the transform declares no bound (the honest default).
    preserves: []const []const u8 = &.{},

    /// Declared obligation predicates ([transform|contract:obliges("pred",...)]):
    /// claims about the write-back's touches the runner must DECIDE — not
    /// just bounds it must stay in. `contract:preserves` says which kinds may not
    /// be touched; obliges say what must be true of the touches made:
    ///   "kind-stable"  — rm and add hold the same multiset of item kinds:
    ///                    rewrite in place, no top-level fabrication or
    ///                    deletion.
    ///   "matched-only" — every removed non-site item contains an
    ///                    invocation matching this transform's dispatch
    ///                    predicate: consume only what called you.
    ///   "consume-only" — every invocation path the write-back removed IS
    ///                    the transform's own consumed call (inv- ⊆
    ///                    {site path}): it may not silently delete or
    ///                    rename away another call.
    /// Violations refuse with KORU187; satisfied obligations commit as
    /// `transform-oblige` witness lines for the oracle to re-decide.
    /// Empty = no obligations claimed (the honest default).
    obligations: []const []const u8 = &.{},

    /// Handler function that takes (node, program, allocator, ctx) and returns a
    /// SiteResult — the site-local write-back ABI. The handler describes its
    /// change as a value (replace this site / append these items); the RUNNER
    /// owns all placement. Handlers never splice into the whole program.
    /// - node: The ASTNode being transformed (will be .invocation for transforms)
    /// - program: The current program AST (immutable to the handler)
    /// - allocator: For any allocations needed during transformation
    /// - ctx: The live CompilerContext, opaque here to avoid the circular
    ///   import (same move as `Program.type_registry`); the generated
    ///   `call_handler_*` casts it back for handlers that declare it. Null on
    ///   entry points that carry no context — a handler that declares `ctx`
    ///   and reaches one asserts rather than receiving a synthesized value.
    handler_fn: *const fn (node: ASTNode, program: *const Program, allocator: std.mem.Allocator, ctx: ?*anyopaque) anyerror!ast.SiteResult,
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
    ctx: ?*anyopaque,
) !*Program {
    return walkAndTransformStages(program, transforms, allocator, null, ctx);
}

/// As `walkAndTransform`, but runs ONLY the given stage's fixed-point when
/// `only_stage` is non-null (null = all stages, pre → main → post). This is
/// what lets the PIPELINE sprinkle a single named stage where it belongs —
/// e.g. run `.pre` before the frontend's template pass so a transform that
/// GRAFTS a `~for` (over a variable it defines) dissolves first, and the
/// template pass then processes the graft normally. `.pre` transforms carry
/// `@pass_ran`, so a later all-stages run re-visits them as no-ops.
pub fn walkAndTransformStages(
    program: *const Program,
    transforms: []const TransformEntry,
    allocator: std.mem.Allocator,
    only_stage: ?Stage,
    ctx: ?*anyopaque,
) !*Program {
    var current_program = program;
    // Pass budget, not a loop detector. The fixed point applies ONE transform
    // per pass (walkOnce returns after the first found — deterministic
    // single-write ordering), so a program with N transform sites needs N
    // passes. Measured 2026-08-15: a store with 512 literal `insert` flows
    // needs ~512 passes (~21s); 1024 flows needs >1000 passes and DIED with
    // a misleading "infinite loop" at the old cap of 1000 — it was not
    // diverging, it was just past the budget. 100_000 allows ~100k-site
    // programs (impractical wall-clock below: the per-pass cost makes >5k
    // sites take minutes) while a GENUINE loop — a transform re-firing on
    // its own output — still terminates the build, loudly, after a bounded
    // burn. The blessed bulk path for large data is the loop form
    // (`for(0..N) ! each i |> insert(...)`) — ONE flow, ONE pass.
    const MAX_ITERATIONS: usize = 100_000; // Circuit breaker to prevent infinite loops

    // STAGED fixed-point: run the fixed-point iteration once per stage, in the
    // declared order (pre → main → post). A `.pre` transform reaches fixed
    // point before any `.main` runs, and `.main` before `.post` — the
    // producer-before-consumer guarantee source order cannot give. WITHIN a
    // stage this is exactly the legacy single-set fixed point, so an
    // all-`.main` program (every untagged transform) behaves identically.
    for ([_]Stage{ .pre, .pre_late, .main, .post }) |stage| {
        if (only_stage) |os| {
            if (stage != os) continue;
        }
        // Filter the transform set to this stage (the set is tiny).
        var staged: std.ArrayList(TransformEntry) = .empty;
        defer staged.deinit(allocator);
        for (transforms) |t| {
            if (t.stage == stage) try staged.append(allocator, t);
        }
        if (staged.items.len == 0) continue;

        // Name-keyed dispatch for this stage's entry set — built once, the
        // index is transform-invariant across every rewalk of the fixed point.
        const dispatch = Dispatch.build(allocator, staged.items);

        var iteration: usize = 0;
        while (true) {
            iteration += 1;

            // Circuit breaker: prevent infinite loops
            if (iteration > MAX_ITERATIONS) {
                log.debug("ERROR: Transform pass budget exceeded ({d} single-transform passes) — either a transform re-fires on its own output (a true loop) or the program has more transform sites than the budget allows\n", .{MAX_ITERATIONS});
                return error.TransformInfiniteLoop;
            }

            const result = try walkOnce(current_program, staged.items, &dispatch, allocator, ctx);

            if (result.found) {
                current_program = result.program;
            } else {
                break;
            }
        }
    }

    if (only_stage == null and transform_app_witness_enabled and transform_app_witness_count > 0) {
        std.debug.print("[witness] site transform-app-census transform transform count={d} obliges={d}\n", .{ transform_app_witness_count, transform_app_oblige_count });
    }

    return @constCast(current_program);
}

/// Result of walking the AST once
const WalkResult = struct {
    found: bool, // Did we find and apply a transform?
    program: *const Program, // Updated program (if found=true) or original (if found=false)
};

/// Name-keyed transform dispatch. The walk used to run the full match
/// predicate (path rebuild + glob match + shadowing) for EVERY transform at
/// EVERY invocation node, per rewalk — O(nodes × transforms × passes). Most
/// entries are exact names (matchSegment on a non-glob name is eql), so they
/// index by the invocation's joined segment path; glob entries keep their
/// per-node pattern check. Candidates must still be tried in declared order —
/// exact hits and glob hits merge ascending by index so "first match wins"
/// is unchanged.
const Dispatch = struct {
    /// exact name → transform indexes, ascending
    exact: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)),
    /// indexes of glob-named entries, ascending
    glob: std.ArrayListUnmanaged(usize),

    fn build(allocator: std.mem.Allocator, transforms: []const TransformEntry) Dispatch {
        var d: Dispatch = .{ .exact = .{}, .glob = .{} };
        for (transforms, 0..) |t, i| {
            if (std.mem.indexOfScalar(u8, t.name, '*') != null) {
                d.glob.append(allocator, i) catch unreachable;
            } else {
                const gop = d.exact.getOrPut(allocator, t.name) catch unreachable;
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.append(allocator, i) catch unreachable;
            }
        }
        return d;
    }

    /// Ordered candidate indexes for `inv_path` — exact-name hits merged with
    /// glob hits, ascending by declared index so "first match wins" is
    /// unchanged. Null on buffer overflow: the caller falls back to the
    /// original full scan rather than dropping a candidate.
    fn candidateIdxs(d: *const Dispatch, transforms: []const TransformEntry, inv_path: []const u8, buf: []usize) ?[]const usize {
        const ex: []const usize = if (d.exact.get(inv_path)) |l| l.items else &.{};
        const gl = d.glob.items;
        if (ex.len + gl.len > buf.len) return null;
        var n: usize = 0;
        var ei: usize = 0;
        var gi: usize = 0;
        while (ei < ex.len or gi < gl.len) {
            if (ei < ex.len and (gi >= gl.len or ex[ei] < gl[gi])) {
                buf[n] = ex[ei];
                ei += 1;
            } else {
                if (!glob_pattern_matcher.matchSegment(transforms[gl[gi]].name, inv_path)) {
                    gi += 1;
                    continue;
                }
                buf[n] = gl[gi];
                gi += 1;
            }
            n += 1;
        }
        return buf[0..n];
    }
};

/// Walk the AST once, applying the FIRST transform found and returning immediately
fn walkOnce(
    program: *const Program,
    transforms: []const TransformEntry,
    dispatch: *const Dispatch,
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
) !WalkResult {
    // Start from the program root
    const root = ASTNode{ .program = @constCast(program) };
    return try walkNode(root, program, transforms, dispatch, allocator, .none, ctx);
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
    dispatch: *const Dispatch,
    allocator: std.mem.Allocator,
    position: SitePosition,
    ctx: ?*anyopaque,
) anyerror!WalkResult {
    // Claimed-region transforms are checked BEFORE children on the nearest
    // lexical container that owns the invocation. This is the one place where
    // we intentionally violate normal depth-first ordering.
    if (getClaimCandidate(node, position)) |candidate| {
        if (!candidate.node.isAlreadyTransformed()) {
            var cpbuf: [256]u8 = undefined;
            const cpath = joinPathInto(&cpbuf, candidate.node.invocation.path.segments);
            var cbuf: [512]usize = undefined;
            const cc = dispatch.candidateIdxs(transforms, cpath, &cbuf);
            if (cc) |idxs| {
                for (idxs) |ti| {
                    const transform = transforms[ti];
                    if (!transform.claims_descendants) continue;
                    if (!invocationMatchesEntry(allocator, candidate.node, &transform, program)) continue;

                    const claim_result = try applyTransform(candidate.node, candidate.position, program, transform, allocator, ctx);
                    if (claim_result.found) {
                        return claim_result;
                    }

                    break;
                }
            } else {
                for (transforms) |transform| {
                    if (!transform.claims_descendants) continue;
                    if (!invocationMatchesEntry(allocator, candidate.node, &transform, program)) continue;

                    const claim_result = try applyTransform(candidate.node, candidate.position, program, transform, allocator, ctx);
                    if (claim_result.found) {
                        return claim_result;
                    }

                    break;
                }
            }
        }
    }

    // DEPTH-FIRST: Walk children first
    const children = try node.children(allocator);
    defer allocator.free(children);

    for (children) |child| {
        const result = try walkNode(child, program, transforms, dispatch, allocator, childPosition(node, child, position), ctx);
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
        var mbuf: [512]usize = undefined;
        if (dispatch.candidateIdxs(transforms, debug_path[0..debug_len], &mbuf)) |idxs| {
            for (idxs) |ti| {
                const transform = transforms[ti];
                if (transform.claims_descendants) continue;
                if (invocationMatchesEntry(allocator, node, &transform, program)) {
                    return try applyTransform(node, position, program, transform, allocator, ctx);
                }
            }
        } else {
            for (transforms) |transform| {
                if (transform.claims_descendants) continue;
                if (invocationMatchesEntry(allocator, node, &transform, program)) {
                    return try applyTransform(node, position, program, transform, allocator, ctx);
                }
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
                            const result = try transform.handler_fn(node, program, allocator, ctx);

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

// ============================================================================
// K2 Use B — whole-program transform accounting (witness kind: transform-app)
// ============================================================================
//
// Site-local results (replacement / replacement_node / appended) are confined
// to their site by construction — the runner's splice is the single write-
// back point. `whole_program` is the ONE escape where a handler can rewrite
// items outside its site (koru_std/taps.kz is the only producer), and the
// comptime-only-site removal is the one other top-level removal. When
// `std/witness:enforce` flips `transform_app_witness_enabled` on, each such
// application commits an accounting line — added/removed top-level items
// keyed by canonical-AST digest — for an independent oracle to rule on.
// Declared blast-radius bounds (which items a transform MAY touch) are
// pass-graph surface; this instrument exposes the truth first.
pub var transform_app_witness_enabled: bool = false;
var transform_app_witness_count: usize = 0;
/// transform-oblige lines emitted — counted separately so the census can
/// commit both counts and the oracle can check each against its own kind.
var transform_app_oblige_count: usize = 0;

/// Canonical digest of ONE top-level item — the per-item granularity the
/// pre/post artifact diffs at. Null only when the serializer fails.
fn itemDigest(allocator: std.mem.Allocator, item: *const ast.Item, main_module_name: []const u8) ?u64 {
    const one = [_]ast.Item{item.*};
    const view = ast.Program{
        .items = &one,
        .main_module_name = main_module_name,
        .allocator = allocator,
    };
    const json = ast_json.serializeCanon(allocator, &view) catch return null;
    return std.hash.Fnv1a_64.hash(json);
}

fn nodeHoldsContinuation(allocator: std.mem.Allocator, node: ASTNode, needle: *const ast.Continuation) bool {
    if (node == .continuation and node.continuation == needle) return true;
    const kids = node.children(allocator) catch return false;
    for (kids) |kid| {
        if (nodeHoldsContinuation(allocator, kid, needle)) return true;
    }
    return false;
}

/// Index of the top-level item carrying the site — the wrapper flow for root
/// sites, the containing top-level item for nested ones.
fn siteItemIndex(allocator: std.mem.Allocator, program: *const Program, sr: SiteRef) ?usize {
    if (sr.wrapper) |w| {
        for (program.items, 0..) |*it, i| {
            if (it.* == .flow and &it.flow == w) return i;
        }
        return null;
    }
    for (program.items, 0..) |*it, i| {
        if (nodeHoldsContinuation(allocator, .{ .item = @constCast(it) }, sr.holding)) return i;
    }
    return null;
}

/// One changed top-level item in a write-back's accounting — digest for
/// identity, kind for the declared `contract:preserves` bound, is_site for the
/// license every transform holds over its own point of application,
/// matched for the `matched-only` obligation (item contains an
/// invocation the transform would fire on — it was "called" there).
const DiffItem = struct {
    digest: u64,
    kind: []const u8,
    is_site: bool,
    matched: bool = false,
};

/// The committed accounting for one whole-program write-back: the site's
/// item index/digest and the pre/post multiset diff as tagged items.
const AppAccounting = struct {
    site_index: ?usize,
    site_digest: ?u64,
    rm: []DiffItem,
    add: []DiffItem,
    /// Invocation-path multiset delta — the granularity an `additive`-
    /// class obligation is decidable over: which call spellings the
    /// write-back gained and lost, by path, with multiplicities.
    inv_add: []PathCount,
    inv_rm: []PathCount,
    /// The consumed call's canonical path — the path-level anchor
    /// `consume-only` bounds `inv_rm` against.
    site_path: ?[]const u8,
    malformed: bool,
};

const PathCount = struct {
    path: []const u8,
    count: u32,
};

/// Canonical `module:seg.seg` spelling — same key shape dead_strip's
/// pathToStringInner commits, so a transform-delta path and a strip-use
/// path spell identically and cross-channel checks can join them.
fn deltaPathKey(allocator: std.mem.Allocator, path: *const ast.DottedPath) ![]u8 {
    var len: usize = 0;
    if (path.module_qualifier) |mq| len += mq.len + 1;
    for (path.segments, 0..) |s, i| len += s.len + @intFromBool(i > 0);
    const buf = try allocator.alloc(u8, len);
    var pos: usize = 0;
    if (path.module_qualifier) |mq| {
        @memcpy(buf[pos .. pos + mq.len], mq);
        pos += mq.len;
        buf[pos] = ':';
        pos += 1;
    }
    for (path.segments, 0..) |s, i| {
        if (i > 0) {
            buf[pos] = '.';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + s.len], s);
        pos += s.len;
    }
    return buf;
}

fn bumpDeltaPath(map: *std.StringHashMap(u32), allocator: std.mem.Allocator, path: *const ast.DottedPath) !void {
    const key = try deltaPathKey(allocator, path);
    const gop = try map.getOrPut(key);
    if (gop.found_existing) {
        allocator.free(key);
        gop.value_ptr.* += 1;
    } else {
        gop.value_ptr.* = 1;
    }
}

/// Invocation-path walk — the same node dispatch dead_strip's
/// collectUsedPaths uses, minus the inline-body text scrape (a text
/// spelling is not an invocation; the delta law counts AST calls only).
const DeltaError = std.mem.Allocator.Error;

fn collectDeltaNodePaths(allocator: std.mem.Allocator, node: *const ast.Node, map: *std.StringHashMap(u32)) DeltaError!void {
    switch (node.*) {
        .invocation => |*inv| try bumpDeltaPath(map, allocator, &inv.path),
        .label_with_invocation => |*lwi| try bumpDeltaPath(map, allocator, &lwi.invocation.path),
        .conditional_block => |*cb| for (cb.nodes) |*n| try collectDeltaNodePaths(allocator, n, map),
        .conditional => |*n| for (n.branches) |*br| try collectDeltaContPaths(allocator, br.body, map),
        .foreach => |*n| for (n.branches) |*br| try collectDeltaContPaths(allocator, br.body, map),
        .switch_result => |*n| for (n.branches) |*br| try collectDeltaContPaths(allocator, br.body, map),
        else => {},
    }
}

fn collectDeltaContPaths(allocator: std.mem.Allocator, conts: []const ast.Continuation, map: *std.StringHashMap(u32)) DeltaError!void {
    for (conts) |*c| {
        if (c.node) |*n| try collectDeltaNodePaths(allocator, n, map);
        try collectDeltaContPaths(allocator, c.continuations, map);
    }
}

fn collectDeltaItemPaths(allocator: std.mem.Allocator, items: []const ast.Item, map: *std.StringHashMap(u32)) DeltaError!void {
    for (items) |*it| {
        switch (it.*) {
            .flow => |*fl| {
                try bumpDeltaPath(map, allocator, &fl.inv().path);
                try collectDeltaContPaths(allocator, fl.body.continuations, map);
            },
            .event_tap => |*tap| {
                if (tap.source) |*s| try bumpDeltaPath(map, allocator, s);
                if (tap.destination) |*d| try bumpDeltaPath(map, allocator, d);
                try collectDeltaContPaths(allocator, tap.continuations, map);
            },
            .module_decl => |*mod| try collectDeltaItemPaths(allocator, mod.items, map),
            .proc_decl => |*pd| {
                for (pd.inline_flows) |*fl| {
                    try bumpDeltaPath(map, allocator, &fl.inv().path);
                    try collectDeltaContPaths(allocator, fl.body.continuations, map);
                }
            },
            .immediate_impl => |*impl| try bumpDeltaPath(map, allocator, &impl.event_path),
            else => {},
        }
    }
}

/// Path multiset of a program's invocations — one canonical key per call.
fn invocationMultiset(allocator: std.mem.Allocator, program: *const Program) !std.StringHashMap(u32) {
    var map = std.StringHashMap(u32).init(allocator);
    try collectDeltaItemPaths(allocator, program.items, &map);
    return map;
}

/// Sorted `path×count` slices of `post − pre` and `pre − post`.
fn multisetDelta(allocator: std.mem.Allocator, pre: *const std.StringHashMap(u32), post: *const std.StringHashMap(u32)) !struct { add: []PathCount, rm: []PathCount } {
    var add: std.ArrayList(PathCount) = .empty;
    var rm: std.ArrayList(PathCount) = .empty;
    var it = post.iterator();
    while (it.next()) |e| {
        const p = pre.get(e.key_ptr.*) orelse 0;
        if (e.value_ptr.* > p) try add.append(allocator, .{ .path = e.key_ptr.*, .count = e.value_ptr.* - p });
    }
    var it2 = pre.iterator();
    while (it2.next()) |e| {
        const q = post.get(e.key_ptr.*) orelse 0;
        if (e.value_ptr.* > q) try rm.append(allocator, .{ .path = e.key_ptr.*, .count = e.value_ptr.* - q });
    }
    const lt = struct {
        fn f(_: void, a: PathCount, b: PathCount) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.f;
    std.mem.sort(PathCount, add.items, {}, lt);
    std.mem.sort(PathCount, rm.items, {}, lt);
    return .{ .add = try add.toOwnedSlice(allocator), .rm = try rm.toOwnedSlice(allocator) };
}

fn itemKindName(item: *const ast.Item) []const u8 {
    return @tagName(item.*);
}

/// Does this top-level item carry an invocation the transform would fire
/// on? Same predicate as the walk (invocationMatchesEntry via the count
/// helpers) so the obligation and the dispatch can never drift — an item
/// "called" the transform iff one of its invocations still matches.
fn itemContainsMatch(allocator: std.mem.Allocator, it: *const ast.Item, transform: *const TransformEntry, program: *const Program) bool {
    switch (it.*) {
        .flow => |*flow| return countMatchingInFlow(allocator, flow, transform, program) > 0,
        .module_decl => |*module| {
            for (module.items) |*mod_item| {
                if (mod_item.* == .flow and countMatchingInFlow(allocator, &mod_item.flow, transform, program) > 0) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn computeAppAccounting(allocator: std.mem.Allocator, pre: *const Program, post: *const Program, sr: SiteRef, transform: *const TransformEntry) ?AppAccounting {
    const site_idx = siteItemIndex(allocator, pre, sr);
    const site_digest = if (site_idx) |i| itemDigest(allocator, &pre.items[i], pre.main_module_name) else null;
    const site_path: ?[]const u8 = if (site_idx) |i|
        (if (pre.items[i] == .flow) (deltaPathKey(allocator, &pre.items[i].flow.inv().path) catch null) else null)
    else
        null;

    const post_digests = allocator.alloc(?u64, post.items.len) catch return null;
    for (post.items, 0..) |*it, i| post_digests[i] = itemDigest(allocator, it, post.main_module_name);
    const used = allocator.alloc(bool, post.items.len) catch return null;
    @memset(used, false);

    var malformed = site_digest == null;
    var rm: std.ArrayList(DiffItem) = .empty;
    for (pre.items, 0..) |*it, pi| {
        const d = itemDigest(allocator, it, pre.main_module_name) orelse {
            malformed = true;
            continue;
        };
        var matched = false;
        for (post_digests, 0..) |pd, j| {
            if (used[j]) continue;
            if (pd != null and pd.? == d) {
                used[j] = true;
                matched = true;
                break;
            }
        }
        if (!matched) rm.append(allocator, .{ .digest = d, .kind = itemKindName(it), .is_site = site_idx != null and pi == site_idx.?, .matched = itemContainsMatch(allocator, it, transform, pre) }) catch {};
    }
    var add: std.ArrayList(DiffItem) = .empty;
    for (post_digests, 0..) |pd, j| {
        if (used[j]) continue;
        if (pd) |d| {
            add.append(allocator, .{ .digest = d, .kind = itemKindName(&post.items[j]), .is_site = false }) catch {};
        } else {
            malformed = true;
        }
    }
    // Invocation-path delta — runner-measured, never handler-reported:
    // the transform's semantic claim is checked against what the trees
    // actually spell, not what the handler says it did.
    var inv_add: []PathCount = &.{};
    var inv_rm: []PathCount = &.{};
    var pre_ms = invocationMultiset(allocator, pre) catch {
        malformed = true;
        return .{ .site_index = site_idx, .site_digest = site_digest, .rm = rm.toOwnedSlice(allocator) catch &.{}, .add = add.toOwnedSlice(allocator) catch &.{}, .inv_add = &.{}, .inv_rm = &.{}, .site_path = site_path, .malformed = malformed };
    };
    var post_ms = invocationMultiset(allocator, post) catch {
        malformed = true;
        return .{ .site_index = site_idx, .site_digest = site_digest, .rm = rm.toOwnedSlice(allocator) catch &.{}, .add = add.toOwnedSlice(allocator) catch &.{}, .inv_add = &.{}, .inv_rm = &.{}, .site_path = site_path, .malformed = malformed };
    };
    const delta = multisetDelta(allocator, &pre_ms, &post_ms) catch {
        malformed = true;
        return .{ .site_index = site_idx, .site_digest = site_digest, .rm = rm.toOwnedSlice(allocator) catch &.{}, .add = add.toOwnedSlice(allocator) catch &.{}, .inv_add = &.{}, .inv_rm = &.{}, .site_path = site_path, .malformed = malformed };
    };
    inv_add = delta.add;
    inv_rm = delta.rm;

    return .{
        .site_index = site_idx,
        .site_digest = site_digest,
        .rm = rm.toOwnedSlice(allocator) catch &.{},
        .add = add.toOwnedSlice(allocator) catch &.{},
        .inv_add = inv_add,
        .inv_rm = inv_rm,
        .site_path = site_path,
        .malformed = malformed,
    };
}

/// Is `kind` inside the transform's declared invariant set? Bare atoms mean
/// "preserve exactly these"; `!`-atoms mean "preserve all EXCEPT these"
/// (closed under vocabulary growth — the frontend refuses mixed modes, so
/// the list is always uniformly one shape).
fn kindIsPreserved(preserves: []const []const u8, kind: []const u8) bool {
    var except_mode = false;
    for (preserves) |a| {
        if (a.len > 0 and a[0] == '!') except_mode = true;
    }
    for (preserves) |a| {
        if (except_mode) {
            if (a.len > 1 and a[0] == '!' and std.mem.eql(u8, a[1..], kind)) return false;
        } else {
            if (std.mem.eql(u8, a, kind)) return true;
        }
    }
    return except_mode;
}

/// The declared blast-radius bound: anything a write-back removes or adds
/// beyond the site item must be a kind the transform did NOT preserve.
/// Refusal, not a flag — the bound is the contract.
fn checkPreservesBound(acc: *const AppAccounting, transform: *const TransformEntry, sr: SiteRef) !void {
    if (transform.preserves.len == 0) return;
    for (acc.rm) |di| {
        if (di.is_site) continue;
        if (kindIsPreserved(transform.preserves, di.kind)) {
            const loc = sr.holding.location;
            std.debug.print(
                "error[KORU186]: transform '{s}' removed a '{s}' item, but its declared `contract:preserves` bound holds that kind invariant\n" ++
                    "  --> {s}:{d}:{d}\n" ++
                    "  declared bound: contract:preserves({s}) — the site item is licensed, collateral is not\n" ++
                    "  fix: narrow the write-back, or drop the kind from `contract:preserves` if the touch is legitimate\n\n",
                .{ transform.name, di.kind, loc.file, loc.line, loc.column, joinSliceInline(transform.preserves) },
            );
            return error.TransformBlastRadiusExceeded;
        }
    }
    for (acc.add) |di| {
        if (kindIsPreserved(transform.preserves, di.kind)) {
            const loc = sr.holding.location;
            std.debug.print(
                "error[KORU186]: transform '{s}' added a '{s}' item, but its declared `contract:preserves` bound holds that kind invariant\n" ++
                    "  --> {s}:{d}:{d}\n" ++
                    "  declared bound: contract:preserves({s}) — additions outside the site count against the bound\n" ++
                    "  fix: narrow the write-back, or drop the kind from `contract:preserves` if the add is legitimate\n\n",
                .{ transform.name, di.kind, loc.file, loc.line, loc.column, joinSliceInline(transform.preserves) },
            );
            return error.TransformBlastRadiusExceeded;
        }
    }
}

/// Appended top-level items on a site-local result are still write-backs
/// outside the site — the same bound applies.
fn checkPreservesAppended(transform: *const TransformEntry, appended: []const ast.Item) !void {
    if (transform.preserves.len == 0) return;
    for (appended) |*it| {
        const kind = itemKindName(it);
        if (kindIsPreserved(transform.preserves, kind)) {
            std.debug.print(
                "error[KORU186]: transform '{s}' appended a '{s}' item, but its declared `contract:preserves` bound holds that kind invariant\n" ++
                    "  declared bound: contract:preserves({s})\n" ++
                    "  fix: append a non-preserved kind, or drop the kind from `contract:preserves`\n\n",
                .{ transform.name, kind, joinSliceInline(transform.preserves) },
            );
            return error.TransformBlastRadiusExceeded;
        }
    }
}

var preserves_join_buf: [512]u8 = undefined;
fn joinSliceInline(items: []const []const u8) []const u8 {
    var fbs = std.io.fixedBufferStream(&preserves_join_buf);
    const w = fbs.writer();
    for (items, 0..) |s, i| {
        if (i > 0) w.writeAll(",") catch break;
        w.writeAll(s) catch break;
    }
    return fbs.getWritten();
}

// ============================================================================
// ARM ACCOUNTING — a named continuation on a transform site is an obligation:
// it must ride into the write-back or be declared consumed (690_364's `| done`
// class, generalized to every transform). A transform that builds its
// replacement from selected arms claims a vocabulary; a named arm outside it
// parses, then evaporates — never runs, no diagnostic. The per-site audits
// (ast_functional.unclaimedContinuation) catch it where the author remembered;
// THIS check is the floor: every named input arm must appear in the result's
// own continuations (recursively — legitimate transplants land deeper, or in
// appended items) or in `result.consumed_arms`, else the write-back refuses.
//
// Two results are exempt by kind, not by sniffing:
//   .is_refusal items — a refusal IS the site's verdict; the arms die with the
//      site, they do not evaporate (typed on the item, set by ast.refusal).
//   whole_program — the documented escape hatch (tap); the site-local fields
//      do not apply, the same license the blast-radius bound gives it.
// ============================================================================

fn collectNodeArms(node: *const ast.Node, set: *std.StringHashMap(void)) error{OutOfMemory}!void {
    // Arms transplanted INTO a node's own branch bodies (kernel's pairwise
    // moves `sub_continuations` into a foreach `step` branch) still count as
    // carried — same name-matching approximation as the slice walk.
    const branches: []const ast.NamedBranch = switch (node.*) {
        .foreach => |*fe| fe.branches,
        .conditional => |*cond| cond.branches,
        .switch_result => |*sw| sw.branches,
        else => return,
    };
    for (branches) |*b| try collectContArms(b.body, set);
}

fn collectContArms(conts: []const ast.Continuation, set: *std.StringHashMap(void)) error{OutOfMemory}!void {
    for (conts) |*c| {
        const bname = std.mem.trim(u8, c.branch, " ");
        if (bname.len != 0) try set.put(bname, {});
        if (c.node) |*n| try collectNodeArms(n, set);
        try collectContArms(c.continuations, set);
    }
}

fn collectItemArms(item: *const ast.Item, set: *std.StringHashMap(void)) error{OutOfMemory}!void {
    switch (item.*) {
        .flow => |*f| try collectContArms(&.{f.body}, set),
        .module_decl => |*m| for (m.items) |*it| try collectItemArms(it, set),
        else => {},
    }
}

fn auditArmAccounting(
    allocator: std.mem.Allocator,
    sr: SiteRef,
    transform_name: []const u8,
    result: ast.SiteResult,
) !void {
    if (result.whole_program != null) return;
    if (result.replacement == null and result.replacement_node == null) {
        // Appended-only: the splice leaves the site untouched — the arms
        // cannot drop, by definition.
        return;
    }
    if (result.replacement) |*repl| {
        if (repl.* == .inline_code and repl.inline_code.is_refusal) return;
    }

    var accounted = std.StringHashMap(void).init(allocator);
    defer accounted.deinit();
    if (result.replacement) |*repl| try collectItemArms(repl, &accounted);
    if (result.replacement_node) |nr| {
        // The splice semantics are the accounting:
        //  - root site + inline_code node → the whole flow dissolves into an
        //    Item.inline_code; the site's continuations AND any provided
        //    children are all dropped — nothing is carried.
        //  - `children: null` keeps the site's existing continuations
        //    (node-only replace), so the input arms are carried verbatim.
        //  - `retarget_producer` rewrites a node elsewhere in the program and
        //    leaves the site's continuations untouched — also carried.
        //  - non-null children at a live site is a fresh vocabulary.
        if (nr.node != .inline_code or sr.wrapper == null) {
            if (nr.children != null and !nr.retarget_producer) {
                try collectContArms(nr.children.?, &accounted);
            } else {
                try collectContArms(sr.holding.continuations, &accounted);
            }
            // The new node itself may hold transplanted arms inside its own
            // branch bodies (pairwise moves the site's sub_continuations into
            // a foreach `step` branch).
            try collectNodeArms(&nr.node, &accounted);
        }
    }
    for (result.appended) |*it| try collectItemArms(it, &accounted);
    for (result.consumed_arms) |name| try accounted.put(name, {});

    for (sr.holding.continuations) |*c| {
        const bname = std.mem.trim(u8, c.branch, " ");
        if (bname.len == 0) continue;
        if (!accounted.contains(bname)) {
            const loc = c.location;
            std.debug.print(
                "error[KORU188]: transform '{s}' dropped unclaimed arm '| {s}' — named arms on a transform site are obligations: carry the arm into the write-back or list it in `consumed_arms`\n" ++
                    "  --> {s}:{d}:{d}\n" ++
                    "  declared consumed: {s}\n" ++
                    "  fix: carry the arm into the replacement/appended items, add it to `consumed_arms` if the transform consumes it, or refuse the arm yourself for a better diagnostic\n\n",
                .{ transform_name, bname, loc.file, loc.line, loc.column, if (result.consumed_arms.len == 0) "none" else joinSliceInline(result.consumed_arms) },
            );
            return error.TransformAccountingFailed;
        }
    }
}

/// Commit the accounting for one whole-program write-back: site digest plus
/// the multiset diff of top-level item digests (pre vs post), tagged with
/// item kinds and the transform's declared `contract:preserves` bound so the oracle
/// can rule on blast-radius containment, not just multiset honesty.
fn emitTransformAppLine(allocator: std.mem.Allocator, pre: *const Program, transform_name: []const u8, verdict: []const u8, preserves: []const []const u8, obligations: []const []const u8, acc: AppAccounting) void {
    if (!transform_app_witness_enabled) return;
    transform_app_witness_count += 1;
    var site_path_buf: [512]u8 = undefined;
    const site_path: []const u8 = if (acc.site_index) |i| (if (pre.items[i] == .flow) joinPathInto(&site_path_buf, pre.items[i].flow.inv().path.segments) else "?") else "?";

    var line: std.ArrayList(u8) = .empty;
    const w = line.writer(allocator);
    if (acc.malformed) {
        w.print("[witness] site transform-app {s} {s} MALFORMED", .{ transform_name, site_path }) catch {};
    } else {
        w.print("[witness] site transform-app {s} {s} {s} site=", .{ transform_name, site_path, verdict }) catch {};
        w.print("{x:0>16}", .{acc.site_digest.?}) catch {};
        // The consumed call's canonical spelling — the site field above is
        // bare segments; `consume-only` tests `inv- ⊆ {sitepath}`.
        if (acc.site_path) |canon| {
            w.print(";sitepath={s}", .{canon}) catch {};
        }
        w.print(";preserves=", .{}) catch {};
        for (preserves, 0..) |k, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{s}", .{k}) catch {};
        }
        w.print(";rm=", .{}) catch {};
        for (acc.rm, 0..) |di, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{x:0>16}", .{di.digest}) catch {};
        }
        w.print(";rmk=", .{}) catch {};
        for (acc.rm, 0..) |di, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{s}", .{di.kind}) catch {};
        }
        w.print(";add=", .{}) catch {};
        for (acc.add, 0..) |di, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{x:0>16}", .{di.digest}) catch {};
        }
        w.print(";addk=", .{}) catch {};
        for (acc.add, 0..) |di, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{s}", .{di.kind}) catch {};
        }
        w.print(";inv+=", .{}) catch {};
        for (acc.inv_add, 0..) |pc, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{s}*{d}", .{ pc.path, pc.count }) catch {};
        }
        w.print(";inv-=", .{}) catch {};
        for (acc.inv_rm, 0..) |pc, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{s}*{d}", .{ pc.path, pc.count }) catch {};
        }
        w.print(";obliges=", .{}) catch {};
        for (obligations, 0..) |o, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{s}", .{o}) catch {};
        }
    }
    std.debug.print("{s}\n", .{line.items});
}

/// The comptime-only-site removal: the flow carrying the site is dropped
/// wholesale — the accounting is the singleton {site} removal.
fn emitTransformGcLine(allocator: std.mem.Allocator, program: *const Program, target_inv: *const Invocation, transform_name: []const u8) void {
    if (!transform_app_witness_enabled) return;
    transform_app_witness_count += 1;
    for (program.items) |*it| {
        if (it.* == .flow and it.flow.inv() == target_inv) {
            var path_buf: [512]u8 = undefined;
            const path = joinPathInto(&path_buf, it.flow.inv().path.segments);
            if (itemDigest(allocator, it, program.main_module_name)) |d| {
                std.debug.print("[witness] site transform-app {s} {s} gc site={x:0>16};rm={x:0>16};add=\n", .{ transform_name, path, d, d });
            } else {
                std.debug.print("[witness] site transform-app {s} {s} MALFORMED digest\n", .{ transform_name, path });
            }
            return;
        }
    }
    std.debug.print("[witness] site transform-app {s} ? MALFORMED gc-site-not-found\n", .{transform_name});
}

/// Does an obligation atom name a declared predicate? The frontend
/// (pass_graph.validate) already refused unknown atoms — this is the
/// runner-side mirror so a hand-built table cannot smuggle a claim the
/// decider does not know.
fn obligeIsDeclared(transform: *const TransformEntry, atom: []const u8) bool {
    for (transform.obligations) |o| {
        if (std.mem.eql(u8, o, atom)) return true;
    }
    return false;
}

fn kindMultisetEqual(a: []const DiffItem, b: []const DiffItem) bool {
    if (a.len != b.len) return false;
    var used: [512]bool = undefined;
    if (b.len > used.len) return false;
    @memset(used[0..b.len], false);
    for (a) |di| {
        var found = false;
        for (b, 0..) |dj, j| {
            if (!used[j] and std.mem.eql(u8, di.kind, dj.kind)) {
                used[j] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// The declared obligations — claims about the touches a write-back
/// actually made. `contract:preserves` bounds WHICH kinds may move; an oblige
/// decides what must be TRUE of the moves. Refusal, not a flag —
/// a claim that fails is a contract broken, KORU187.
/// Returns the per-obligation verdict the witness line commits.
fn checkObligations(allocator: std.mem.Allocator, acc: *const AppAccounting, transform: *const TransformEntry, sr: SiteRef) !void {
    if (transform.obligations.len == 0) return;
    if (obligeIsDeclared(transform, "kind-stable")) {
        // The site item is licensed — it is the point of application, and a
        // transform that consumes its own site (taps removes `~tap()`) is not
        // deleting collateral. The bound compares collateral rm kinds to add.
        var rm_collateral: std.ArrayList(DiffItem) = .empty;
        for (acc.rm) |di| {
            if (!di.is_site) rm_collateral.append(allocator, di) catch return error.TransformAccountingFailed;
        }
        if (!kindMultisetEqual(rm_collateral.items, acc.add)) {
            const loc = sr.holding.location;
            std.debug.print(
                "error[KORU187]: transform '{s}' violated its declared `kind-stable` obligation — the write-back's collateral removals ({d} item(s)) and additions ({d}) carry differing kind multisets\n" ++
                    "  --> {s}:{d}:{d}\n" ++
                    "  declared obligation: contract:obliges(\"kind-stable\") — a rewrite-in-place contract: no top-level item may be fabricated or deleted outright; the site item is licensed\n" ++
                    "  fix: keep the write-back's rm/add kind multisets equal, or drop the obligation if fabrication/deletion is intended\n\n",
                .{ transform.name, rm_collateral.items.len, acc.add.len, loc.file, loc.line, loc.column },
            );
            return error.TransformObligationViolated;
        }
    }
    if (obligeIsDeclared(transform, "matched-only")) {
        for (acc.rm) |di| {
            if (di.is_site) continue;
            if (!di.matched) {
                const loc = sr.holding.location;
                std.debug.print(
                    "error[KORU187]: transform '{s}' violated its declared `matched-only` obligation — a '{s}' item (digest {x:0>16}) was removed without containing an invocation this transform fires on\n" ++
                        "  --> {s}:{d}:{d}\n" ++
                        "  declared obligation: contract:obliges(\"matched-only\") — a transform consumes only items it was called on; the site item is licensed, collateral must match\n" ++
                        "  fix: narrow the write-back to matched items, or drop the obligation if touching unmatched items is intended\n\n",
                    .{ transform.name, di.kind, di.digest, loc.file, loc.line, loc.column },
                );
                return error.TransformObligationViolated;
            }
        }
    }
    if (obligeIsDeclared(transform, "consume-only")) {
        // Every invocation path the write-back removed must be the path the
        // transform fired on — the handler consumes its own call and may
        // add calls freely, but silently deleting (or renaming away) some
        // other call is collateral the path multiset catches.
        for (acc.inv_rm) |pc| {
            if (acc.site_path == null or !std.mem.eql(u8, pc.path, acc.site_path.?)) {
                const loc = sr.holding.location;
                std.debug.print(
                    "error[KORU187]: transform '{s}' violated its declared `consume-only` obligation — the write-back removed {d} invocation(s) of '{s}', which is not the consumed call '{s}'\n" ++
                        "  --> {s}:{d}:{d}\n" ++
                        "  declared obligation: contract:obliges(\"consume-only\") — every removed invocation path is the transform's own consumed call; additions are free, removals may not touch another path\n" ++
                        "  fix: keep collateral invocations spelling the same path, or drop the obligation if removing other calls is intended\n\n",
                    .{ transform.name, pc.count, pc.path, acc.site_path orelse "?", loc.file, loc.line, loc.column },
                );
                return error.TransformObligationViolated;
            }
        }
    }
}

/// Commit the decided obligations as witness lines — one per declared
/// predicate, carrying the claim plus any evidence not already on the
/// app line. Lines only ever carry verdict `ok`: a violation refuses
/// before this point, so an `ok` claim the evidence does not support is
/// a forgery. `kind-stable` and `consume-only` carry NO fields — their
/// whole evidence is the sibling transform-app line's commits
/// (site/rmk/addk for kinds; sitepath/inv-= for removed call paths),
/// and emitting it twice from the same accounting would not check
/// anything new; `matched-only` commits `justified=` — the digest set
/// of collateral removals containing a matching invocation — which the
/// app line does not carry and the oracle cannot re-derive without the AST.
fn emitObligeLines(allocator: std.mem.Allocator, pre: *const Program, transform: *const TransformEntry, acc: AppAccounting) void {
    if (!transform_app_witness_enabled) return;
    if (transform.obligations.len == 0) return;
    if (acc.malformed) return; // the app line already commits MALFORMED — no honest verdict exists to emit
    var site_path_buf: [512]u8 = undefined;
    const site_path: []const u8 = if (acc.site_index) |i| (if (pre.items[i] == .flow) joinPathInto(&site_path_buf, pre.items[i].flow.inv().path.segments) else "?") else "?";
    for (transform.obligations) |ob| {
        transform_app_oblige_count += 1;
        var line: std.ArrayList(u8) = .empty;
        const w = line.writer(allocator);
        w.print("[witness] site transform-oblige {s} {s} {s} ok", .{ transform.name, site_path, ob }) catch {};
        if (std.mem.eql(u8, ob, "matched-only")) {
            w.print(";justified=", .{}) catch {};
            var first = true;
            for (acc.rm) |di| {
                if (di.is_site or !di.matched) continue;
                if (!first) w.print(",", .{}) catch {};
                first = false;
                w.print("{x:0>16}", .{di.digest}) catch {};
            }
        }
        std.debug.print("{s}\n", .{line.items});
    }
}

fn applyTransform(
    node: ASTNode,
    position: SitePosition,
    program: *const Program,
    transform: TransformEntry,
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
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

    const result = try transform.handler_fn(handler_node, handler_program, allocator, ctx);

    // Empty SiteResult = no-op: the handler declined / already processed this
    // invocation (e.g. inline_body present but not yet @pass_ran-annotated).
    // Mark the REAL invocation so the walker skips it, and keep going — don't
    // abort the pipeline. (Mirrors the old same-pointer signal.)
    if (result.replacement == null and result.replacement_node == null and result.whole_program == null and result.appended.len == 0) {
        log.debug("Transform '{s}' produced an empty SiteResult, marking as processed\n", .{transform.name});
        const mutable_inv = @constCast(node.invocation);
        const new_marks = allocator.alloc([]const u8, mutable_inv.marks.len + 1) catch {
            return error.TransformReturnedSamePointer;
        };
        for (mutable_inv.marks, 0..) |mark, mi| {
            new_marks[mi] = mark;
        }
        new_marks[mutable_inv.marks.len] = "@pass_ran(\"transform\")";
        mutable_inv.marks = new_marks;

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
                emitTransformGcLine(allocator, program, node.invocation, transform.name);
                return WalkResult{ .found = true, .program = np };
            }
        }

        // Continue walking — don't abort the entire transform pipeline
        return WalkResult{ .found = false, .program = program };
    }

    // Declared blast-radius: appended items are write-backs outside the site
    // even on the site-local path — the `contract:preserves` bound applies.
    try checkPreservesAppended(&transform, result.appended);

    // Arm accounting: every named input arm is carried or declared consumed.
    try auditArmAccounting(allocator, sr, transform.name, result);

    // Place the change. The runner owns the splice — root site replaces its
    // flow Item, nested site replaces the holding continuation, appended items
    // go to the top level. This is the single write-back point.
    const spliced = try spliceSiteResult(allocator, program, sr, result);

    // K2 Use B: a whole_program result is the one splice that can touch items
    // outside the site — commit the pre/post accounting before the progress
    // check below. Nested-position wp is excluded: its `post` is a rewrite of
    // the synthetic site VIEW, not the real program (and KORU124 errors it).
    // The accounting also carries the declared `contract:preserves` bound — a
    // write-back exceeding it refuses (KORU186) instead of being recorded.
    if (result.whole_program != null and sr.wrapper != null) {
        const acc = computeAppAccounting(allocator, program, spliced, sr, &transform) orelse {
            std.debug.print("[witness] site transform-app {s} ? MALFORMED oom\n", .{transform.name});
            return error.TransformAccountingFailed;
        };
        try checkPreservesBound(&acc, &transform, sr);
        try checkObligations(allocator, &acc, &transform, sr);
        emitTransformAppLine(allocator, program, transform.name, "wp", transform.preserves, transform.obligations, acc);
        emitObligeLines(allocator, program, &transform, acc);
    }

    // CIRCUIT BREAKER: Verify the transform made progress.
    // Count matching invocations before and after - if the count didn't
    // decrease, the transform isn't making progress (infinite loop).
    const count_before = countMatchingFlowsInProgram(allocator, &transform, program);
    const count_after = countMatchingFlowsInProgram(allocator, &transform, spliced);

    if (count_after >= count_before and count_before > 0) {
        // Continuation/nested-position whole-program transforms: for a nested
        // site the runner hands the handler a synthetic top-level VIEW of the
        // site (siteView), but a `whole_program` result short-circuits the
        // graft-back (spliceSiteResult returns wp verbatim), so the handler
        // rewrites the synthetic copy and the REAL nested invocation is never
        // replaced — the count can't drop. This is a genuine capability
        // frontier (210_024_source_scope_capture), NOT an infinite loop. Teach
        // it at the koru level with a source location instead of leaking a raw
        // host panic through evaluate-comptime's @panic.
        if (sr.wrapper == null and result.whole_program != null) {
            const loc = sr.holding.location;
            std.debug.print(
                "error[KORU124]: transform '{s}' invoked in continuation position is not supported here\n" ++
                    "  --> {s}:{d}:{d}\n" ++
                    "  this transform uses the whole-program escape, which matches flow-root invocations only; a continuation-position invocation is never rewritten (frontier: 210_024_source_scope_capture).\n" ++
                    "  fix: invoke '{s}' at top level, or have it return a site-local SiteResult instead of a whole_program.\n\n",
                .{ transform.name, loc.file, loc.line, loc.column, transform.name },
            );
            return error.TransformContinuationPositionUnsupported;
        }

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
        log.err("  2. Add @pass_ran(\"transform\") mark to the new invocation\n", .{});
        log.err("\n", .{});
        return error.TransformDidNotReplace;
    }

    return WalkResult{ .found = true, .program = spliced };
}

/// Check if an invocation matches an [expand] event and handle it.
/// Nested sites get the same lift/graft treatment as transform handlers, so
/// expansion is position-agnostic too.
/// [expand]-declared event paths, memoized per program-items epoch — the same
/// items-header contract as local_events above. The walk asked this once per
/// invocation node and paid a full program scan for the answer every time.
var expand_epoch_ptr: usize = 0;
var expand_epoch_len: usize = std.math.maxInt(usize);
var expand_set: ?std.StringHashMap(void) = null;

fn expandDeclSet(allocator: std.mem.Allocator, program: *const Program) *const std.StringHashMap(void) {
    if (expand_epoch_ptr != @intFromPtr(program.items.ptr) or expand_epoch_len != program.items.len) {
        var set = std.StringHashMap(void).init(allocator);
        for (program.items) |*item| {
            switch (item.*) {
                .event_decl => |*ed| {
                    if (annotation_parser.hasPart(ed.annotations, "expand"))
                        set.put(joinPathKey(allocator, ed.path.segments), {}) catch unreachable;
                },
                .module_decl => |*md| {
                    for (md.items) |*mi| {
                        if (mi.* == .event_decl and annotation_parser.hasPart(mi.event_decl.annotations, "expand"))
                            set.put(joinPathKey(allocator, mi.event_decl.path.segments), {}) catch unreachable;
                    }
                },
                else => {},
            }
        }
        expand_set = set;
        expand_epoch_ptr = @intFromPtr(program.items.ptr);
        expand_epoch_len = program.items.len;
    }
    return &expand_set.?;
}

fn handleExpandIfMatches(
    node: ASTNode,
    position: SitePosition,
    program: *const Program,
    allocator: std.mem.Allocator,
) !WalkResult {
    const invocation = node.invocation;

    // Build the invocation path for matching
    var path_buf: [256]u8 = undefined;
    const inv_path = joinPathInto(&path_buf, invocation.path.segments);

    // An [expand] decl matching this path applies its template; the decl
    // itself is unused, so set membership is the whole question.
    var key_buf: [512]u8 = undefined;
    if (joinPathKeyInto(&key_buf, invocation.path.segments)) |key| {
        if (expandDeclSet(allocator, program).contains(key))
            return try applyExpandAtSite(node, position, program, inv_path, allocator);
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
    const result: ast.SiteResult = .{ .replacement = repl };
    // Expand carries the site body verbatim today — the arm check runs anyway:
    // a template that ever stops carrying arms is the same evaporation.
    try auditArmAccounting(allocator, sr, inv_path, result);
    const spliced = try spliceSiteResult(allocator, program, sr, result);
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
    const new_inv_marks = try allocator.alloc([]const u8, invocation.marks.len + 1);
    for (invocation.marks, 0..) |mark, i| {
        new_inv_marks[i] = mark;
    }
    new_inv_marks[invocation.marks.len] = try allocator.dupe(u8, "@pass_ran(\"transform\")");

    const new_invocation = ast.Invocation{
        .path = invocation.path,
        .args = invocation.args,
        .annotations = invocation.annotations,
        .marks = new_inv_marks,
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
