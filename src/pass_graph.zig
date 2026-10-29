//! Declared pass graph — `~[contract:requires("a","b")]` on a tor declares
//! ordering edges: every named pass must have executed before the declaring
//! pass runs.
//!
//! The checker's two jobs:
//!   1. The declared edge digraph itself must be sound: every required name
//!      resolves to a decl, and the edges admit a linearization (acyclic).
//!      That is a property of the declarations alone — a cycle is refused
//!      even if the members never share a chain.
//!   2. Every flow chain (`~x = a() |> b()`) is an observation of actual
//!      order. Segment invocations expand through their own `~x =` impl
//!      flows, so a `contract:requires` edge between members of different segments
//!      (analysis requiring an elaborate pass) is checked against the
//!      flattened pipeline at `coordinate`, not left unverifiable.
//!
//! Rules of the order check, and why:
//!   - Both parties present in a chain: every occurrence of each required
//!     pass must precede every occurrence of the requirer. (A pass that runs
//!     twice — desugar-chains is the canonical case — is "established" only
//!     after its LAST run; checking all positions is the strict reading.)
//!   - Requirer present, required absent: refused only at ROOTS — flows
//!     never invoked inside another flow's chain (`coordinate`, user
//!     overrides of it, top-level program flows). A non-root chain like
//!     `~analysis` is invoked inside `coordinate` where outer segments
//!     legitimately provide the required pass; refusing there would deny
//!     the composition the mechanism exists to check.
//!
//! `contract:requires` on a pipeline tor names pass *order*. On a
//! `[transform]` decl it is an INTRA-transform edge: the required transform
//! must occupy a strictly earlier stage (pre < main < post). Same-stage
//! ordering is fixed-point walk order — not a declarable contract — so a
//! same-stage `contract:requires` refuses rather than pretend.
//!
//! `contract:preserves("kind",...)` on a `[transform]` decl is the
//! blast-radius bound: top-level items of the named kinds must be
//! bit-identical across the transform's write-backs (LLVM
//! PreservedAnalyses semantics). The frontend validates the atoms against
//! the Item union vocabulary; the runner enforces the bound on
//! whole_program/appended write-backs (KORU186). `contract:preserves` on a
//! non-transform decl refuses — a bound with no write-back to constrain is
//! a dead assertion. `contract:obliges` is the same claim for obligation
//! predicates the runner can decide.
//!
//! Naming: the `contract:` namespace separates these declared-claim
//! annotations from `std/compiler:requires` the build-dep directive tor
//! (call position) and `depends_on` the schedule-me edge (build steps,
//! store rules — those topo-sort; contract edges validate authored order
//! and refuse). Ruled by Lars, 2026-10-17.

const std = @import("std");
const ast = @import("ast");
const annotation_parser = @import("annotation_parser");
const errors = @import("errors");

/// Transform stages as an ordering — pre < main < post. A `contract:requires` edge
/// between transforms is satisfiable only when the producer sits strictly
/// earlier; the intra-stage fixed point promises no order at all.
const TransformStage = enum(u8) { pre = 0, main = 1, post = 2 };

fn stageOf(annotations: []const []const u8) TransformStage {
    if (annotation_parser.hasPart(annotations, "pre")) return .pre;
    if (annotation_parser.hasPart(annotations, "post")) return .post;
    return .main;
}

/// Top-level item kinds a `contract:preserves` bound may name — the Item union tag
/// vocabulary, closed: an atom that spells nothing refuses instead of
/// silently bounding nothing. An atom prefixed `!` is an EXCEPTION: the
/// bound then means "all kinds preserved except the named ones" — closed
/// under vocabulary growth, where a bare enumeration silently widens when
/// a new kind appears. Mixing bare and `!` atoms in one `contract:preserves` is
/// refused: which mode the bound means would be a guess.
const item_kinds = [_][]const u8{
    "module_decl",   "event_decl",    "proc_decl",      "flow",
    "event_tap",     "label_decl",    "immediate_impl", "import_decl",
    "host_line",     "host_type_decl", "parse_error",   "native_loop",
    "fused_event",   "inlined_event", "inline_code",    "facet_decl",
};

/// Obligation predicates a `[transform]` decl may claim (`contract:obliges(...)`) —
/// mechanically decided by the runner on every whole_program write-back,
/// each committed as a `transform-oblige` witness line the Lean oracle
/// re-decides. `contract:preserves` says which kinds a transform may NOT touch;
/// an oblige says what must be TRUE of the touches it does make — the
/// third gap class (touches never justified) closed as a contract:
///   kind-stable  — rm and add hold the same multiset of item kinds:
///                  the write-back rewrites in place; it may not
///                  fabricate or delete a top-level item outright.
///   matched-only — every removed non-site item contains an invocation
///                  matching this transform's own dispatch predicate:
///                  the transform consumes only items it was called on.
///   consume-only — every invocation path the write-back removed IS the
///                  transform's own consumed call: inv- ⊆ {site path}.
///                  Additions are free (a transform's job is inserting
///                  calls); removals may not touch another path.
/// An atom naming no known predicate refuses — a declared obligation
/// the runner cannot decide is a claim checked by nobody.
const oblige_names = [_][]const u8{
    "kind-stable",
    "matched-only",
    "consume-only",
};

const PassDecl = struct {
    /// Last segment of the decl path ("check-structure").
    name: []const u8,
    /// Module-qualified spelling "module:name" for diagnostics and qualified
    /// matching (module separators normalized: '/' and '.' both -> '.').
    qualified: []const u8,
    requires: []const []const u8,
    preserves: []const []const u8,
    /// Declared obligation predicates — claims about the write-back's
    /// touches the runner must decide, not just bounds it must stay in.
    obliges: []const []const u8,
    /// True on `[transform]` decls — their requires are intra-transform
    /// stage edges, not pipeline positions.
    is_transform: bool,
    stage: TransformStage,
    location: errors.SourceLocation,
};

/// A pass invocation observed in a flow chain, in execution order.
const Step = struct {
    /// Last path segment as invoked.
    name: []const u8,
    /// Normalized module qualifier ("" when bare).
    qualifier: []const u8,
};

fn normalizeQualifier(allocator: std.mem.Allocator, q: []const u8) ![]const u8 {
    const copy = try allocator.dupe(u8, q);
    for (copy) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return copy;
}

fn lastSegment(path: ast.DottedPath) []const u8 {
    if (path.segments.len == 0) return "";
    return path.segments[path.segments.len - 1];
}

fn declQualifier(decl: *const ast.EventDecl) []const u8 {
    if (decl.path.module_qualifier) |mq| return mq;
    return decl.module;
}

/// Collect declared edges + impl flows. Returns false (via error) through
/// the caller on violation — this function only gathers.
/// A `[transform]` decl — a resolution target for intra-transform requires
/// edges. Collected whether or not it declares edges of its own.
const TransformDecl = struct {
    name: []const u8,
    qualified: []const u8,
    stage: TransformStage,
    location: errors.SourceLocation,
};

const Graph = struct {
    decls: std.ArrayList(PassDecl),
    /// Every [transform] decl in the program — the transform namespace that
    /// transform-level `contract:requires` resolves against.
    transforms: std.ArrayList(TransformDecl),
    /// impl flows by last-segment name — expansion targets.
    impl_flows: std.StringHashMapUnmanaged(std.ArrayList(*const ast.Flow)),
    /// Every flow item (impl or top-level), each a chain to check.
    flows: std.ArrayList(*const ast.Flow),
    allocator: std.mem.Allocator,
};

fn collect(allocator: std.mem.Allocator, items: []const ast.Item) !Graph {
    var g: Graph = .{
        .decls = .empty,
        .transforms = .empty,
        .impl_flows = .{},
        .flows = .empty,
        .allocator = allocator,
    };
    try collectItems(allocator, &g, items);
    return g;
}

/// Decls and pipeline chains nest inside module_decl items — compiler.kz's
/// coordinate/analysis chains live there, not at top level. A collector that
/// skipped them would leave the seeded edges unchecked: a declared contract
/// nobody reads is worse than none — it looks enforced while doing nothing.
fn collectItems(allocator: std.mem.Allocator, g: *Graph, items: []const ast.Item) !void {
    for (items) |*item| {
        switch (item.*) {
            .module_decl => |*md| try collectItems(allocator, g, md.items),
            .event_decl => |*decl| {
                const is_transform = annotation_parser.hasPart(decl.annotations, "transform");
                const name = lastSegment(decl.path);
                const qual = if (declQualifier(decl).len > 0)
                    try std.fmt.allocPrint(allocator, "{s}:{s}", .{ try normalizeQualifier(allocator, declQualifier(decl)), name })
                else
                    name;
                if (is_transform) {
                    try g.transforms.append(allocator, .{
                        .name = name,
                        .qualified = qual,
                        .stage = stageOf(decl.annotations),
                        .location = decl.location,
                    });
                }
                var requires: std.ArrayList([]const u8) = .empty;
                if (try annotation_parser.getCall(allocator, decl.annotations, "contract:requires")) |call| {
                    var c = call;
                    defer c.deinit(allocator);
                    for (c.args) |arg| try requires.append(allocator, try allocator.dupe(u8, arg));
                }
                var preserves: std.ArrayList([]const u8) = .empty;
                if (try annotation_parser.getCall(allocator, decl.annotations, "contract:preserves")) |call| {
                    var c = call;
                    defer c.deinit(allocator);
                    for (c.args) |arg| try preserves.append(allocator, try allocator.dupe(u8, arg));
                }
                var obliges: std.ArrayList([]const u8) = .empty;
                if (try annotation_parser.getCall(allocator, decl.annotations, "contract:obliges")) |call| {
                    var c = call;
                    defer c.deinit(allocator);
                    for (c.args) |arg| try obliges.append(allocator, try allocator.dupe(u8, arg));
                }
                // Pre-rename spellings must refuse, not silently stop binding —
                // a bare `requires`/`preserves`/`obliges` that parses but names
                // nothing is an unchecked contract.
                for ([_][]const u8{ "requires", "preserves", "obliges" }) |legacy| {
                    if (try annotation_parser.getCall(allocator, decl.annotations, legacy)) |call| {
                        var c = call;
                        defer c.deinit(allocator);
                        std.debug.print("error[KORU185]: `{s}` declares `{s}(...)`, which no longer names a contract — the declared-claim vocabulary is namespaced\n  {s}:{d}: spell it `contract:{s}(...)`\n", .{ name, legacy, decl.location.file, decl.location.line, legacy });
                        std.process.exit(1);
                    }
                }
                if (requires.items.len == 0 and preserves.items.len == 0 and obliges.items.len == 0) continue;
                try g.decls.append(allocator, .{
                    .name = name,
                    .qualified = qual,
                    .requires = try requires.toOwnedSlice(allocator),
                    .preserves = try preserves.toOwnedSlice(allocator),
                    .obliges = try obliges.toOwnedSlice(allocator),
                    .is_transform = is_transform,
                    .stage = stageOf(decl.annotations),
                    .location = decl.location,
                });
            },
            .flow => |*flow| {
                try g.flows.append(allocator, flow);
                if (flow.impl_of) |io| {
                    const key = lastSegment(io);
                    const gop = try g.impl_flows.getOrPut(allocator, key);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(allocator, flow);
                }
            },
            else => {},
        }
    }
}

/// Every event_decl name, module-nested ones included — a `contract:requires` that
/// resolves against only the top level would refuse the stdlib's own edges.
/// `nontransform_names` (optional) additionally collects just the names of
/// decls that are NOT [transform]s — a transform decl is an event_decl, so
/// the full name set alone cannot tell a pipeline entity from a transform.
fn collectDeclNames(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), nontransform_names: ?*std.StringHashMapUnmanaged(void), items: []const ast.Item) !void {
    for (items) |*item| {
        switch (item.*) {
            .module_decl => |*md| try collectDeclNames(allocator, set, nontransform_names, md.items),
            .event_decl => |*decl| {
                try set.put(allocator, lastSegment(decl.path), {});
                if (nontransform_names) |nt| {
                    if (!annotation_parser.hasPart(decl.annotations, "transform")) {
                        try nt.put(allocator, lastSegment(decl.path), {});
                    }
                }
            },
            else => {},
        }
    }
}

/// Depth-first cycle check over the resolved edge digraph.
/// edges: index into decls -> indexes of required decls. A required name that
/// resolved only to an impl flow (segment name) contributes no decl edge.
fn checkDag(g: *const Graph, decl_by_name: std.StringHashMapUnmanaged(usize)) !void {
    const n = g.decls.items.len;
    const color = try g.allocator.alloc(u8, n); // 0 white 1 gray 2 black
    defer g.allocator.free(color);
    @memset(color, 0);

    const Ctx = struct {
        g: *const Graph,
        decl_by_name: *const std.StringHashMapUnmanaged(usize),
        color: []u8,

        fn dfs(self: *@This(), i: usize, trail: *std.ArrayList(usize)) !void {
            self.color[i] = 1;
            try trail.append(self.g.allocator, i);
            for (self.g.decls.items[i].requires) |req| {
                const req_last = if (std.mem.indexOfScalar(u8, req, ':')) |ci| req[ci + 1 ..] else req;
                const j = self.decl_by_name.get(req_last) orelse continue;
                if (self.color[j] == 1) {
                    // Found a cycle — report the trail from j to i plus j.
                    var msg = std.ArrayList(u8){};
                    var started = false;
                    for (trail.items) |t| {
                        if (t == j) started = true;
                        if (!started) continue;
                        try msg.appendSlice(self.g.allocator, self.g.decls.items[t].name);
                        try msg.appendSlice(self.g.allocator, " requires ");
                    }
                    try msg.appendSlice(self.g.allocator, self.g.decls.items[j].name);
                    std.debug.print("error[KORU185]: pass-graph cycle — {s}\n  the declared edges admit no ordering; a chain satisfying one arm violates the other\n  fix: break the cycle — one of these `contract:requires` is not an ordering fact but a coincidence of current order\n", .{msg.items});
                    std.process.exit(1);
                }
                if (self.color[j] == 0) try self.dfs(j, trail);
            }
            _ = trail.pop();
            self.color[i] = 2;
        }
    };
    var ctx: Ctx = .{ .g = g, .decl_by_name = &decl_by_name, .color = color };
    var trail: std.ArrayList(usize) = .empty;
    for (0..n) |i| {
        if (color[i] == 0) try ctx.dfs(i, &trail);
    }
}

/// Flatten a flow's chain into ordered steps, expanding invoked names through
/// their impl flows. `visited` holds flows already expanded on this path —
/// a recursive impl contributes its name but is not re-entered.
fn flattenChain(
    g: *const Graph,
    cont: *const ast.Continuation,
    visited: *std.AutoHashMapUnmanaged(*const ast.Flow, void),
    out: *std.ArrayList(Step),
) !void {
    if (cont.node) |*node| {
        switch (node.*) {
            .invocation => |*inv| {
                const name = lastSegment(inv.path);
                const qual: []const u8 = if (inv.path.module_qualifier) |mq|
                    try normalizeQualifier(g.allocator, mq)
                else
                    "";
                try out.append(g.allocator, .{ .name = name, .qualifier = qual });
                if (g.impl_flows.get(name)) |impls| {
                    for (impls.items) |impl| {
                        if (visited.contains(impl)) continue;
                        try visited.put(g.allocator, impl, {});
                        try flattenChain(g, &impl.body, visited, out);
                    }
                }
            },
            else => {},
        }
    }
    for (cont.continuations) |*sub| try flattenChain(g, sub, visited, out);
}

/// Which flows are invoked inside another flow's chain — non-roots skip the
/// "required pass never runs" refusal since outer context may provide it.
fn invokedNames(g: *const Graph) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .{};
    for (g.flows.items) |flow| {
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(g.allocator);
        var visited: std.AutoHashMapUnmanaged(*const ast.Flow, void) = .{};
        defer visited.deinit(g.allocator);
        try flattenChain(g, &flow.body, &visited, &steps);
        for (steps.items) |s| try set.put(g.allocator, s.name, {});
    }
    return set;
}

/// Resolve a transform-level `contract:requires` argument to a TransformDecl —
/// bare last-segment or `module:name` qualified. A bare name hitting
/// multiple transforms is refused as ambiguous rather than resolved by
/// fiat (same discipline as every other edge in this module).
fn resolveTransform(g: *const Graph, req: []const u8) ?*const TransformDecl {
    var req_last = req;
    var req_qual: []const u8 = "";
    if (std.mem.indexOfScalar(u8, req, ':')) |ci| {
        req_qual = req[0..ci];
        req_last = req[ci + 1 ..];
    }
    var found: ?*const TransformDecl = null;
    var count: usize = 0;
    for (g.transforms.items) |*t| {
        if (!std.mem.eql(u8, t.name, req_last)) continue;
        if (req_qual.len > 0) {
            var buf: [256]u8 = undefined;
            if (req_qual.len > buf.len) continue;
            @memcpy(buf[0..req_qual.len], req_qual);
            for (buf[0..req_qual.len]) |*c| {
                if (c.* == '/') c.* = '.';
            }
            const qual_norm = buf[0..req_qual.len];
            const t_qual = if (std.mem.indexOfScalar(u8, t.qualified, ':')) |ci| t.qualified[0..ci] else "";
            if (!std.mem.eql(u8, t_qual, qual_norm)) continue;
        }
        found = t;
        count += 1;
    }
    if (count > 1 and req_qual.len == 0) {
        std.debug.print("error[KORU185]: `contract:requires` argument `{s}` names {d} different transforms — a bare name cannot pick between them\n  fix: qualify the edge (module:name) so the contract names exactly one transform\n", .{ req, count });
        std.process.exit(1);
    }
    return found;
}

fn matchStep(g: *const Graph, step: Step, req: []const u8) bool {
    _ = g;
    var req_last = req;
    var req_qual: []const u8 = "";
    if (std.mem.indexOfScalar(u8, req, ':')) |ci| {
        req_qual = req[0..ci];
        req_last = req[ci + 1 ..];
    }
    if (!std.mem.eql(u8, step.name, req_last)) return false;
    if (req_qual.len == 0) return true;
    var buf: [256]u8 = undefined;
    if (req_qual.len > buf.len) return false;
    @memcpy(buf[0..req_qual.len], req_qual);
    for (buf[0..req_qual.len]) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return std.mem.eql(u8, step.qualifier, buf[0..req_qual.len]);
}

/// What the validation observed — declared edges, transform stage rows,
/// and the root-chain orders the order check actually walked. The backend
/// bakes these into `pass-graph-*` witness lines under enforce so the
/// oracle re-decides linearization from artifacts, not from "it compiled".
pub const DeclaredEdge = struct {
    consumer: []const u8,
    req: []const u8,
};
pub const ObservedOrder = struct {
    chain: []const u8,
    steps: []const []const u8,
};
pub const StageRow = struct {
    name: []const u8,
    stage: []const u8, // "pre" | "main" | "post"
};
pub const Summary = struct {
    edges: []const DeclaredEdge = &.{},
    tedges: []const DeclaredEdge = &.{},
    tstages: []const StageRow = &.{},
    orders: []const ObservedOrder = &.{},
};

/// Entry point. Walks the parsed program; refuses via KORU185 on
/// unresolvable edges, cycles, or order violations. Returns what it
/// checked — the witness payload the backend commits under enforce.
pub fn validate(allocator: std.mem.Allocator, items: []const ast.Item) !Summary {
    var g = try collect(allocator, items);
    if (g.decls.items.len == 0 and g.transforms.items.len == 0) return .{}; // no declared edges — nothing to check

    // All decls (declared AND unannotated) indexed by last segment — required
    // names resolve against the whole tor namespace, not just edge-holders.
    var decl_by_name: std.StringHashMapUnmanaged(usize) = .{};
    var all_names: std.StringHashMapUnmanaged(void) = .{};
    var nontransform_names: std.StringHashMapUnmanaged(void) = .{};
    try collectDeclNames(allocator, &all_names, &nontransform_names, items);
    for (g.decls.items, 0..) |*d, i| {
        try decl_by_name.put(allocator, d.name, i);
    }
    // impl-flow names also resolve (segment names like `elaborate`).
    var flow_names: std.StringHashMapUnmanaged(void) = .{};
    var fit = g.impl_flows.iterator();
    while (fit.next()) |e| try flow_names.put(allocator, e.key_ptr.*, {});

    // 1. Every required name must resolve to something real. Transform
    // decls resolve in their own namespace — step 2b carries the
    // transform-shaped diagnostic for edges that name nothing there.
    for (g.decls.items) |*d| {
        if (d.is_transform) continue;
        for (d.requires) |req| {
            const req_last = if (std.mem.indexOfScalar(u8, req, ':')) |ci| req[ci + 1 ..] else req;
            if (!all_names.contains(req_last) and !flow_names.contains(req_last)) {
                std.debug.print("error[KORU185]: pass `{s}` requires `{s}`, but no tor or pipeline segment named `{s}` exists in this program\n  {s}:{d}: the edge names a pass identity, not an intention — the check refuses rather than guess which decl was meant\n  fix: fix the spelling, or declare the pass — a `contract:requires` that names nothing is a dead assertion\n", .{ d.name, req, req_last, d.location.file, d.location.line });
                std.process.exit(1);
            }
        }
    }

    // 2. Declared edges must be acyclic (linearizable) on their own.
    try checkDag(&g, decl_by_name);

    // 2b. Transform surface: `contract:requires` on a [transform] decl resolves inside
    // the transform namespace and is satisfiable only across stages — the
    // intra-stage fixed point orders by first-found walk, which no declared
    // edge can bind. `contract:preserves` atoms must name real Item kinds; on a
    // non-transform decl it is refused as a bound constraining nothing.
    for (g.decls.items) |*d| {
        if (!d.is_transform) {
            if (d.preserves.len > 0) {
                std.debug.print("error[KORU185]: `{s}` declares `contract:preserves`, but it is not a [transform] decl\n  {s}:{d}: contract:preserves bounds a transform's write-back blast radius — on a pipeline pass there is no write-back for it to constrain\n  fix: drop the annotation, or move it to the transform decl it belongs to\n", .{ d.name, d.location.file, d.location.line });
                std.process.exit(1);
            }
            if (d.obliges.len > 0) {
                std.debug.print("error[KORU185]: `{s}` declares `contract:obliges`, but it is not a [transform] decl\n  {s}:{d}: contract:obliges are claims about a transform's write-back — on a pipeline pass there is no write-back for them to constrain\n  fix: drop the annotation, or move it to the transform decl it belongs to\n", .{ d.name, d.location.file, d.location.line });
                std.process.exit(1);
            }
            // The converse edge is refused too: a pipeline tor requiring a
            // transform orders against a surface that runs inside the
            // transform stage — the chain can never satisfy it, and in a
            // non-root chain the "absent" tolerance would let a dead edge
            // stand. A name that is BOTH a pipeline entity and a transform
            // resolves as pipeline — declarer-side ambiguity the decl owns.
            for (d.requires) |req| {
                const req_last = if (std.mem.indexOfScalar(u8, req, ':')) |ci| req[ci + 1 ..] else req;
                if (resolveTransform(&g, req) != null and
                    !nontransform_names.contains(req_last) and
                    !flow_names.contains(req_last))
                {
                    std.debug.print("error[KORU185]: pass `{s}` requires `{s}`, but `{s}` is a transform, not a pipeline pass\n  {s}:{d}: pipeline `contract:requires` edges are intra-pipeline — a transform never runs as a chain step; ordering against one is declared by the transform's stage, not by naming it here\n  fix: name the pass this one depends on, or drop the edge\n", .{ d.name, req, req_last, d.location.file, d.location.line });
                    std.process.exit(1);
                }
            }
            continue;
        }
        var saw_bare = false;
        var saw_except = false;
        for (d.preserves) |atom| {
            const body = if (std.mem.startsWith(u8, atom, "!")) atom[1..] else atom;
            if (atom.len > 0 and atom[0] == '!') saw_except = true else saw_bare = true;
            var known = false;
            for (item_kinds) |k| {
                if (std.mem.eql(u8, body, k)) known = true;
            }
            if (!known or body.len == 0) {
                std.debug.print("error[KORU185]: transform `{s}` preserves `{s}`, which names no top-level item kind\n  {s}:{d}: a bound spelled with an unknown atom constrains nothing — refusing rather than letting a typo stand as a contract\n  known kinds: module_decl event_decl proc_decl flow event_tap label_decl immediate_impl import_decl host_line host_type_decl parse_error native_loop fused_event inlined_event inline_code facet_decl\n  fix: fix the spelling, or widen the vocabulary deliberately\n", .{ d.name, atom, d.location.file, d.location.line });
                std.process.exit(1);
            }
        }
        if (saw_bare and saw_except) {
            std.debug.print("error[KORU185]: transform `{s}` mixes bare and `!` atoms in `contract:preserves` — the bound's mode is ambiguous\n  {s}:{d}: bare atoms mean \"preserve exactly these kinds\"; `!` atoms mean \"preserve all EXCEPT these\" — one declaration cannot mean both\n  fix: pick one mode — enumerate the preserved kinds, or list the exceptions as `!kind`\n", .{ d.name, d.location.file, d.location.line });
            std.process.exit(1);
        }
        for (d.obliges) |atom| {
            var known = false;
            for (oblige_names) |o| {
                if (std.mem.eql(u8, atom, o)) known = true;
            }
            if (!known) {
                std.debug.print("error[KORU185]: transform `{s}` obliges `{s}`, which names no known obligation predicate\n  {s}:{d}: an obligation the runner cannot decide is a claim checked by nobody — refusing rather than letting the word stand as a contract\n  known obligations: kind-stable matched-only consume-only\n  fix: fix the spelling, or widen the vocabulary deliberately\n", .{ d.name, atom, d.location.file, d.location.line });
                std.process.exit(1);
            }
        }
        for (d.requires) |req| {
            const target = resolveTransform(&g, req) orelse {
                const req_last = if (std.mem.indexOfScalar(u8, req, ':')) |ci| req[ci + 1 ..] else req;
                const exists = all_names.contains(req_last) or flow_names.contains(req_last);
                if (exists) {
                    std.debug.print("error[KORU185]: transform `{s}` requires `{s}`, but `{s}` is not a transform\n  {s}:{d}: transform `contract:requires` edges are intra-transform — ordering against pipeline passes is declared by the transform's stage ([transform|pre]/[transform|post]), not by naming a pipeline step\n  fix: name the transform this one depends on, or drop the edge\n", .{ d.name, req, req_last, d.location.file, d.location.line });
                } else {
                    std.debug.print("error[KORU185]: transform `{s}` requires `{s}`, but no transform named `{s}` exists in this program\n  {s}:{d}: the edge names a transform identity, not an intention — the check refuses rather than guess which decl was meant\n  fix: fix the spelling, or declare the transform — a `contract:requires` that names nothing is a dead assertion\n", .{ d.name, req, req_last, d.location.file, d.location.line });
                }
                std.process.exit(1);
            };
            if (@intFromEnum(target.stage) >= @intFromEnum(d.stage)) {
                std.debug.print("error[KORU185]: transform `{s}` requires `{s}`, but `{s}` runs in the {s} stage — not before `{s}`'s {s} stage\n  {s}:{d}: within a stage the fixed point applies transforms in first-found walk order — same-stage ordering is not a declarable contract, and a later stage never ran earlier\n  fix: move the producer to an earlier stage, or drop the edge\n", .{ d.name, req, req, @tagName(target.stage), d.name, @tagName(d.stage), d.location.file, d.location.line });
                std.process.exit(1);
            }
        }
    }

    // 3. Order check against observed chains — and commit the root chains'
    // resolved steps as the observed orders the oracle re-decides against.
    const invoked = try invokedNames(&g);
    var orders: std.ArrayList(ObservedOrder) = .empty;

    for (g.flows.items) |flow| {
        var steps: std.ArrayList(Step) = .empty;
        defer steps.deinit(allocator);
        var visited: std.AutoHashMapUnmanaged(*const ast.Flow, void) = .{};
        defer visited.deinit(allocator);
        try flattenChain(&g, &flow.body, &visited, &steps);
        if (steps.items.len == 0) continue;
        // Root = never invoked inside another flow's chain — its ordering is
        // the full execution context, so an absent required pass is a refusal
        // there. Non-roots (segments like `elaborate`) are embedded in a wider
        // chain that legitimately provides the name.
        const root = if (flow.impl_of) |io| !invoked.contains(lastSegment(io)) else true;
        if (root) {
            var step_names: std.ArrayList([]const u8) = .empty;
            for (steps.items) |s| {
                const spelling = if (s.qualifier.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}:{s}", .{ s.qualifier, s.name })
                else
                    s.name;
                try step_names.append(allocator, spelling);
            }
            const chain_name = if (flow.impl_of) |io|
                lastSegment(io)
            else
                lastSegment(flow.inv().path);
            try orders.append(allocator, .{
                .chain = if (chain_name.len > 0) chain_name else "?",
                .steps = try step_names.toOwnedSlice(allocator),
            });
        }

        for (g.decls.items) |*d| {
            // Transform decls can appear as chain steps (`~tap()` — the
            // fixed point still finds the site) — but their requires are
            // intra-transform stage edges, checked in 2b; reading them as
            // pipeline positions would refuse an edge the chain cannot
            // express either way.
            if (d.is_transform) continue;
            if (d.requires.len == 0) continue;
            for (steps.items, 0..) |s, i| {
                if (!std.mem.eql(u8, s.name, d.name)) continue;
                for (d.requires) |req| {
                    var last_req_pos: ?usize = null;
                    for (steps.items, 0..) |rs, j| {
                        if (matchStep(&g, rs, req)) last_req_pos = j;
                    }
                    if (last_req_pos) |p| {
                        if (p >= i) {
                            std.debug.print("error[KORU185]: `{s}` requires `{s}`, but the resolved chain runs `{s}` only at a later position\n  chain: {s}\n  the annotation is the contract and the chain is the observation — disagreement is a refusal, not a reorder\n  fix: move `{s}` earlier in the chain, or correct the declared edge\n", .{ d.name, req, req, chainRepr(allocator, steps.items) catch "?", req });
                            std.process.exit(1);
                        }
                    } else if (root) {
                        std.debug.print("error[KORU185]: `{s}` requires `{s}`, but the root pipeline never runs `{s}`\n  a `contract:requires` that its own pipeline cannot satisfy is a dead edge — the check refuses rather than let it stand unverifiable\n  fix: run `{s}` before `{s}` in the chain, or drop the declared edge\n", .{ d.name, req, req, req, d.name });
                        std.process.exit(1);
                    }
                }
            }
        }
    }

    // 4. Commit what was checked: every declared edge (pipeline and
    // transform surfaces kept distinct), every transform's stage row, and
    // the root orders observed in step 3.
    var edges: std.ArrayList(DeclaredEdge) = .empty;
    var tedges: std.ArrayList(DeclaredEdge) = .empty;
    for (g.decls.items) |*d| {
        for (d.requires) |req| {
            const edge: DeclaredEdge = .{ .consumer = d.name, .req = req };
            if (d.is_transform) {
                try tedges.append(allocator, edge);
            } else {
                try edges.append(allocator, edge);
            }
        }
    }
    var tstages: std.ArrayList(StageRow) = .empty;
    for (g.transforms.items) |*t| {
        try tstages.append(allocator, .{ .name = t.name, .stage = @tagName(t.stage) });
    }
    return .{
        .edges = try edges.toOwnedSlice(allocator),
        .tedges = try tedges.toOwnedSlice(allocator),
        .tstages = try tstages.toOwnedSlice(allocator),
        .orders = try orders.toOwnedSlice(allocator),
    };
}

fn chainRepr(allocator: std.mem.Allocator, steps: []const Step) ![]const u8 {
    var buf = std.ArrayList(u8){};
    for (steps, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(allocator, " |> ");
        if (s.qualifier.len > 0) {
            try buf.appendSlice(allocator, s.qualifier);
            try buf.appendSlice(allocator, ":");
        }
        try buf.appendSlice(allocator, s.name);
    }
    return buf.toOwnedSlice(allocator);
}
