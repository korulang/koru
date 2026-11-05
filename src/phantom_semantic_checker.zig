// Phantom Semantic Checker - Validates module-qualified phantom states
const log = @import("log");
const std = @import("std");

const ast = @import("ast");
const ast_functional = @import("ast_functional");
const errors = @import("errors");
const phantom_parser = @import("phantom_parser");

// Access compiler flags via root (backend.zig generates CompilerEnv)
const root = @import("root");
const CompilerEnv = if (@hasDecl(root, "CompilerEnv")) root.CompilerEnv else struct {
    // Fallback for unit tests where CompilerEnv doesn't exist
    pub fn hasFlag(_: []const u8) bool {
        return false;
    }
};

/// `errors.writeCandidateNames` wants a plain fn; these candidates are already
/// display strings.
fn ownName(name: []const u8) []const u8 {
    return name;
}

/// Checks that module-qualified phantom states reference valid imported modules
pub const PhantomSemanticChecker = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    module_map: std.StringHashMap([]const u8),
    label_map: std.StringHashMap(LabelTarget),
    disposal_event_map: std.StringHashMap(DisposalEventInfo),
    /// `~[prototype]` module opt-in (see ShapeChecker.prototype_mode). Relaxes
    /// the "handled a branch the event doesn't produce" wall (KORU030) for
    /// TERMINAL continuations — the doodle where handler arms lead the event's
    /// declaration (400_165). Set from module_annotations in check_phantom.
    prototype_mode: bool = false,
    /// Which slice of flow analysis this run performs. `.full` (check-phantom-
    /// semantic, post-auto-discharge) runs everything, including the flow-exit
    /// obligation-balance walls — those must see the inserted disposal calls,
    /// or every auto-dischargeable obligation reads as a leak. `.args_only`
    /// (check-phantom-args, PRE-auto-discharge) runs only the argument-located
    /// call-site checks: state threading + per-argument phantom mismatch. Those
    /// depend on nothing auto-discharge inserts (insertions land at terminators,
    /// downstream of every user call), so running them first lets the PRECISE
    /// "Phantom state mismatch" diagnostics preempt the inserter's generic
    /// "was not discharged" wall (330_040/330_100 — the diagnostic-precision
    /// half of the signature-pass reordering, see checkSignatures).
    check_mode: CheckMode = .full,
    /// Declared-type identities (registry rung 1): names minted by std/types
    /// declaration tors. Same rule as type_registry.populateFromItem's
    /// declared-type scan — a small consumer-side copy until the gray-zone
    /// registry is threaded (the two-walls drift hazard, accepted for the
    /// first green; the two scans must stay in sync). Powers the nominal
    /// distinctness check: only when BOTH sides are registered declared
    /// types and differ does the checker refuse (030_132/133, 340_006) —
    /// a literal into a nominal wrapper (`string` -> Username) stays legal.
    declared_types: std.StringHashMap(void),
    /// The program(s) this run checks — [0] is the transformed AST (`// proto`
    /// markers live there), [1] the pre-transform twin (live `std/proto`
    /// declaration flows) when the caller keeps one. seedRecordFieldObligations
    /// resolves a bare compound return type (`-> Env`) to its leaf list so a
    /// proto with owned `*mod:Type<state!>` fields seeds `binding.field` debts
    /// exactly like an inline record return (699_031).
    src_asts: [2]?*const ast.Program = .{ null, null },

    pub const CheckMode = enum { full, args_only };

    /// Information about an event for disposal suggestions
    const DisposalEventInfo = struct {
        decl: *const ast.EventDecl,
        module_name: []const u8,
    };

    /// A `#label`'s target: the round event's decl plus the module name the
    /// label's invocation resolved under. `decl.module` is the parse-time file
    /// stem — for module items that is `m`, not the logical `app.m` every
    /// canonicalization anchors on (330_134's twin at `@label` re-entry).
    const LabelTarget = struct {
        decl: *const ast.EventDecl,
        module: []const u8,
    };

    /// A declared-type identity's registration site: where the declaring flow
    /// sits, whether the registrant is a compound PROTO entry, and whether it
    /// is a terminal declared through `std/proto`. The collision wall's honor
    /// question asks both of the latter — two proto declarations of one name
    /// are a loud error; the legacy nominal wrappers stay idempotent.
    const DeclaredTypeSite = struct {
        location: errors.SourceLocation,
        is_proto: bool,
        is_terminal: bool,
        is_foreign: bool,
        is_node: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !PhantomSemanticChecker {
        return PhantomSemanticChecker{
            .allocator = allocator,
            .reporter = reporter,
            .module_map = std.StringHashMap([]const u8).init(allocator),
            .label_map = std.StringHashMap(LabelTarget).init(allocator),
            .disposal_event_map = std.StringHashMap(DisposalEventInfo).init(allocator),
            .declared_types = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *PhantomSemanticChecker) void {
        // Free allocated disposal event map keys
        var iter = self.disposal_event_map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.disposal_event_map.deinit();
        self.module_map.deinit();
        self.label_map.deinit();
        var declared_iter = self.declared_types.keyIterator();
        while (declared_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.declared_types.deinit();
    }

    /// Build the declared-type identity set (registry rung 1). Mirrors
    /// type_registry.populateFromItem's declared-type scan: a flow invoking a
    /// std/types declaration tor (`struct`, nominal wrappers) declares a type
    /// under its first argument's name. Same rule, two copies — the drift
    /// hazard (concepts: two walls guarding one rule) is accepted until the
    /// gray-zone registry threads; the two scans must stay in sync.
    fn buildDeclaredTypes(self: *PhantomSemanticChecker, declared_types_ast: *const ast.Program) !void {
        var iter = self.declared_types.keyIterator();
        while (iter.next()) |key| self.allocator.free(key.*);
        self.declared_types.clearRetainingCapacity();
        // One registration site per declared identity, keyed by (home, name):
        // two homes may mint one bare name as two distinct concepts, and the
        // loud two-registrant collision fires only on a second registrant in
        // the SAME home (proto rung, 2026-08-23; module rung, 2026-09-04).
        var sites = std.StringHashMap(DeclaredTypeSite).init(self.allocator);
        defer {
            var site_iter = sites.keyIterator();
            while (site_iter.next()) |key| self.allocator.free(key.*);
            sites.deinit();
        }
        try self.scanDeclaredTypes(declared_types_ast.items, declared_types_ast.main_module_name, &sites);
    }

    fn scanDeclaredTypes(self: *PhantomSemanticChecker, items: []const ast.Item, home: []const u8, sites: *std.StringHashMap(DeclaredTypeSite)) !void {
        for (items) |item| {
            switch (item) {
                .flow => |flow| {
                    const inv = flow.inv();
                    const mq = inv.path.module_qualifier;
                    const types_tor = if (mq) |mqv|
                        std.mem.eql(u8, mqv, "std.types") or std.mem.eql(u8, mqv, "std/types")
                    else
                        true;
                    // Proto default-door rung (2026-09-03): `std/proto(Name)`
                    // is the compound front door — the default-event rule
                    // rewrites a bare module call into `std/proto:default(Name)`
                    // at import time (import_pipeline.zig
                    // rewriteDefaultEventCalls), so the declaration lands here
                    // with the canonical dotted mq "std.proto" and the verb
                    // "default". Same entry, second spelling; both register.
                    const proto_door = if (mq) |mqv|
                        std.mem.eql(u8, mqv, "std.proto") or std.mem.eql(u8, mqv, "std/proto")
                    else
                        false;
                    // Foreign rung: `std/foreign:struct(Name)` registers a
                    // host-owned identity — same registry, same collision law,
                    // no derived container.
                    const foreign_door = if (mq) |mqv|
                        std.mem.eql(u8, mqv, "std.foreign") or std.mem.eql(u8, mqv, "std/foreign")
                    else
                        false;
                    // Tree rung: `std/tree:node(Name)` registers a node kind —
                    // Koru-owned heap identity in the SAME registry. Same
                    // collision law: a proto and a node sharing one name in one
                    // home refuse at declaration (the C# class/struct rule).
                    const tree_door = if (mq) |mqv|
                        std.mem.eql(u8, mqv, "std.tree") or std.mem.eql(u8, mqv, "std/tree")
                    else
                        false;
                    if ((types_tor or proto_door or foreign_door or tree_door) and inv.path.segments.len > 0) {
                        const last_seg = inv.path.segments[inv.path.segments.len - 1];
                        // The decl-tor verbs are `struct` plus the scalar
                        // vocabulary — `std/proto:i64(Port)` spells the host
                        // scalar as the verb (ast_functional.scalars).
                        const is_decl_tor = std.mem.eql(u8, last_seg, "struct") or
                            ast_functional.isScalar(last_seg);
                        // PROTO rung (2026-08-23): `std/types:proto(Name)` is
                        // the declared-type front door. The proto NAME is one
                        // declared identity, and the container it promises to
                        // derive — `List_<Name>` — is a SECOND, registered
                        // here so that the nominal-distinctness gate refuses
                        // values over two different protos' containers at the
                        // KORU layer (container identities are distinct no
                        // matter how much the shapes agree).
                        const is_proto = std.mem.eql(u8, last_seg, "proto") or
                            (proto_door and std.mem.eql(u8, last_seg, "default"));
                        // A terminal declared through `std/proto` is also an
                        // identity, so its name collides loudly. It does not
                        // derive a container: terminals terminate, they are not
                        // compounds.
                        const is_terminal = proto_door and ast_functional.isScalar(last_seg);
                        // A foreign entry is an identity from the host side of
                        // the airlock: collides loudly, derives nothing.
                        const is_foreign = foreign_door and std.mem.eql(u8, last_seg, "struct");
                        // A tree node entry is a Koru-owned heap identity:
                        // collides loudly, derives nothing through this door.
                        const is_node = tree_door and std.mem.eql(u8, last_seg, "node");
                        if ((is_decl_tor or is_proto or is_foreign or is_node) and inv.args.len > 0) {
                            var name = inv.args[0].value;
                            // `<:` extension rides the labeled-arg split —
                            // `std/proto(Dog <: Animal)` arrives as
                            // (name: "Dog <", value: "Animal"), so the
                            // declared entry is the label minus '<'.
                            if (inv.args[0].had_explicit_label) {
                                const label = std.mem.trim(u8, inv.args[0].name, " \t");
                                name = if (std.mem.endsWith(u8, label, "<"))
                                    std.mem.trim(u8, label[0 .. label.len - 1], " \t")
                                else
                                    label;
                            }
                            if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"')
                                name = name[1 .. name.len - 1];
                            if (name.len > 0) {
                                const site = DeclaredTypeSite{
                                    .location = flow.location,
                                    .is_proto = is_proto,
                                    .is_terminal = is_terminal,
                                    .is_foreign = is_foreign,
                                    .is_node = is_node,
                                };
                                try self.registerDeclaredIdentity(name, home, site, sites);
                                if (is_proto) {
                                    // The container identity a proto derives.
                                    const container = try std.fmt.allocPrint(self.allocator, "List_{s}", .{name});
                                    const container_site = DeclaredTypeSite{
                                        .location = flow.location,
                                        .is_proto = true,
                                        .is_terminal = false,
                                        .is_foreign = false,
                                        .is_node = false,
                                    };
                                    try self.registerDeclaredIdentity(container, home, container_site, sites);
                                }
                            }
                        }
                    }
                },
                .module_decl => |module| try self.scanDeclaredTypes(module.items, module.logical_name, sites),
                else => {},
            }
        }
    }

    /// Register one declared identity, refusing a second registrant in the
    /// SAME home loudly — two declaration sites in one module claiming the
    /// same entry are a collision (the hindsight of the two-walls doctrine:
    /// idempotent registration made the SECOND declaration a silent no-op;
    /// the proto rung makes it a KORU error citing BOTH registrants, per the
    /// 2026-08-23 rulings). A second home minting the same bare name is a
    /// distinct concept, not a collision (module rung).
    fn registerDeclaredIdentity(
        self: *PhantomSemanticChecker,
        name: []const u8,
        home: []const u8,
        site: DeclaredTypeSite,
        sites: *std.StringHashMap(DeclaredTypeSite),
    ) !void {
        // Identity is (home, name): the composite key carries the home the
        // bare `declared_types` membership set deliberately drops (the
        // nominal gate answers "is this name minted anywhere" and stays bare).
        const composite = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ home, name });
        errdefer self.allocator.free(composite);
        if (sites.get(composite)) |prior| {
            // This home already registered the name — the collision wall
            // fires when at least one of the two registrants is a compound
            // PROTO entry or a `std/proto` terminal (both ruled identity
            // front doors); the legacy nominal wrappers stay idempotent.
            const collides = site.is_proto or site.is_terminal or site.is_foreign or site.is_node or prior.is_proto or prior.is_terminal or prior.is_foreign or prior.is_node;
            if (collides) {
                const prior_loc = prior.location;
                log.debug("[PHANTOM] ❌ DUPLICATE PROTO DECLARATION '{s}'\n", .{name});
                if (site.is_node or prior.is_node) {
                    try self.reporter.addError(
                        .KORU030,
                        site.location.line,
                        site.location.column,
                        "duplicate registry entry '{s}' — a name is registered once per home, whatever its kind (proto, terminal, foreign, tree node); the declaration at {s}:{d} collides with the prior registration at {s}:{d}",
                        .{ name, site.location.file, self.reporter.userLineIn(site.location), prior_loc.file, self.reporter.userLineIn(prior_loc) },
                    );
                } else if (site.is_foreign or prior.is_foreign) {
                    try self.reporter.addError(
                        .KORU030,
                        site.location.line,
                        site.location.column,
                        "duplicate foreign entry '{s}' — a foreign entry is registered once; the declaration at {s}:{d} collides with the prior registration at {s}:{d}",
                        // Line numbers embedded in the prose must read in user
                        // coordinates — the caret's line goes through
                        // classifyLine, the prose numbers do not (userLineIn).
                        .{ name, site.location.file, self.reporter.userLineIn(site.location), prior_loc.file, self.reporter.userLineIn(prior_loc) },
                    );
                } else {
                    try self.reporter.addError(
                        .KORU030,
                        site.location.line,
                        site.location.column,
                        "duplicate proto declaration '{s}' — a proto entry is registered once; the declaration at {s}:{d} collides with the prior registration at {s}:{d}",
                        .{ name, site.location.file, self.reporter.userLineIn(site.location), prior_loc.file, self.reporter.userLineIn(prior_loc) },
                    );
                }
                return error.ValidationFailed;
            }
            return;
        }
        try sites.put(composite, site);
        if (!self.declared_types.contains(name)) {
            const bare = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(bare);
            try self.declared_types.put(bare, {});
        }
    }

    /// Check phantom types in the entire AST
    pub fn check(self: *PhantomSemanticChecker, source_ast: *const ast.Program, declared_types_ast: *const ast.Program) !void {
        log.debug("\n[PHANTOM-CHECK] Starting phantom semantic check for program with {d} items\n", .{source_ast.items.len});
        // Track if we found any errors (but continue checking to find all of them)
        var has_errors = false;
        self.src_asts = .{ source_ast, declared_types_ast };

        // Pass 1: Build module resolution map from imports
        try self.buildModuleMap(source_ast);

        // Build event map for disposal suggestions
        try self.buildDisposalEventMap(source_ast);

        // Declared-type identities for the nominal-distinctness check — from
        // the PRE-TRANSFORM ast: the struct declaration flows are consumed
        // into inline_code before this pass runs, so only the original sees them.
        try self.buildDeclaredTypes(declared_types_ast);

        // Reset label map for this run
        self.label_map.clearRetainingCapacity();

        // Pass 1: Validate all phantom annotations (syntax, modules exist)
        const annotations_valid = try self.validatePhantomAnnotations(source_ast);
        if (!annotations_valid) {
            has_errors = true;
            // Continue checking for more errors
        }

        // Pass 2: Validate phantom state flows (compatibility checking)
        // Reset label map for each check run
        self.label_map.clearRetainingCapacity();
        const flows_valid = try self.validatePhantomFlows(source_ast);
        if (!flows_valid) {
            has_errors = true;
            // Continue checking for more errors
        }

        // Return error if we found any issues
        if (has_errors) {
            log.debug("[PHANTOM] Returning ValidationFailed - annotations_valid={}, flows_valid={}\n", .{ annotations_valid, flows_valid });
            return error.ValidationFailed;
        }
        log.debug("[PHANTOM] All validation passed!\n", .{});
    }

    /// Signature-only validation: the declaration-shape checks (phantom syntax,
    /// polarity on event signatures — KORU033, unknown phantom modules — KORU040)
    /// WITHOUT the obligation-flow analysis of `check()`. This is the entry point
    /// for the `check-phantom-signatures` pipeline pass, which runs BEFORE
    /// auto-discharge insertion: an illegal polarity on an event's own signature
    /// (e.g. issuing `<owned!>` on an INPUT parameter) must be rejected before any
    /// obligation-FLOW pass reasons about programs using that event — otherwise
    /// auto-discharge halts first with a spurious KORU030 leak and the real
    /// declaration error stays dormant (pin 330_110).
    pub fn checkSignatures(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !void {
        log.debug("\n[PHANTOM-CHECK] Starting phantom signature check for program with {d} items\n", .{source_ast.items.len});
        self.src_asts = .{ source_ast, null };
        try self.buildModuleMap(source_ast);
        const annotations_valid = try self.validatePhantomAnnotations(source_ast);
        if (!annotations_valid) {
            log.debug("[PHANTOM] Signature validation failed\n", .{});
            return error.ValidationFailed;
        }
        log.debug("[PHANTOM] Signature validation passed\n", .{});
    }

    /// Argument-located validation only: the call-site checks (state threading,
    /// per-argument phantom mismatch — the precise "Phantom state mismatch"
    /// family) WITHOUT the flow-exit obligation-balance walls of `check()`.
    /// This is the entry point for the `check-phantom-args` pipeline pass,
    /// which runs BEFORE auto-discharge insertion: a call-site mismatch the
    /// user can point at (`dispose(res.h)` consuming an obligation the value
    /// doesn't hold, an argument in the wrong state) must be reported with its
    /// precise, argument-located diagnostic — not preempted by the inserter's
    /// generic "was not discharged" wall, which never acknowledges the
    /// explicit discharge already present in the source (330_040, 330_100).
    /// The exit-balance walls stay in `check()` after insertion, where the
    /// inserted disposal calls exist to be credited.
    pub fn checkArguments(self: *PhantomSemanticChecker, source_ast: *const ast.Program, declared_types_ast: *const ast.Program) !void {
        log.debug("\n[PHANTOM-CHECK] Starting phantom argument check for program with {d} items\n", .{source_ast.items.len});
        self.src_asts = .{ source_ast, declared_types_ast };
        self.check_mode = .args_only;
        defer self.check_mode = .full;
        try self.buildModuleMap(source_ast);
        try self.buildDisposalEventMap(source_ast);
        try self.buildDeclaredTypes(declared_types_ast);
        self.label_map.clearRetainingCapacity();
        const flows_valid = try self.validatePhantomFlows(source_ast);
        if (!flows_valid) {
            log.debug("[PHANTOM] Argument validation failed\n", .{});
            return error.ValidationFailed;
        }
        log.debug("[PHANTOM] Argument validation passed\n", .{});
    }

    fn buildModuleMap(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !void {
        for (source_ast.items) |item| {
            switch (item) {
                .import_decl => |imp| {
                    const local_name = imp.local_name orelse imp.path;
                    try self.module_map.put(local_name, imp.path);
                },
                .module_decl => |mod| {
                    // Map logical name to logical name (for phantom state canonicalization)
                    // We want "app.fs:opened" not "tests/.../fs.kz:opened"
                    try self.module_map.put(mod.logical_name, mod.logical_name);
                },
                else => {},
            }
        }
    }

    /// Build a map of all events for disposal suggestions
    fn buildDisposalEventMap(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !void {
        // Index-based iteration to get stable pointers into the AST. Capturing
        // by value (|item|) yields a stack-local copy that dies at the end of
        // the iteration; pointers taken into that copy (via |*event_decl|)
        // dangle once the loop advances. See module_decl branch below.
        for (source_ast.items, 0..) |_, top_idx| {
            switch (source_ast.items[top_idx]) {
                .event_decl => |*event_decl| {
                    const qualified_name = try self.buildDisposalQualifiedEventName(event_decl);
                    try self.disposal_event_map.put(qualified_name, .{
                        .decl = event_decl,
                        .module_name = event_decl.module,
                    });
                },
                .module_decl => |mod| {
                    // Add events from submodules - use module's logical_name for full path
                    // Use index-based iteration to get stable pointers
                    for (mod.items, 0..) |_, idx| {
                        switch (mod.items[idx]) {
                            .event_decl => |*event_decl| {
                                const qualified_name = try self.buildDisposalQualifiedEventNameWithModule(event_decl, mod.logical_name);
                                try self.disposal_event_map.put(qualified_name, .{
                                    .decl = event_decl,
                                    .module_name = mod.logical_name,
                                });
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Build qualified event name like "module:event" or "module:event[!]"
    fn buildDisposalQualifiedEventName(self: *PhantomSemanticChecker, event_decl: *const ast.EventDecl) ![]const u8 {
        // Part-facet decls carry the part stem in .module but qualify under
        // the primary — same owner rule as buildEventMap (330_136).
        const owner = event_decl.path.module_qualifier orelse event_decl.module;
        return self.buildDisposalQualifiedEventNameWithModule(event_decl, owner);
    }

    /// Build qualified event name with explicit module name
    fn buildDisposalQualifiedEventNameWithModule(self: *PhantomSemanticChecker, event_decl: *const ast.EventDecl, module_name: []const u8) ![]const u8 {
        const event_name = try self.pathToString(event_decl.path);
        defer self.allocator.free(event_name);
        const has_default = for (event_decl.annotations) |ann| {
            if (std.mem.eql(u8, ann, "!")) break true;
        } else false;

        if (has_default) {
            return std.fmt.allocPrint(self.allocator, "{s}:{s}[!]", .{ module_name, event_name });
        } else {
            return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_name });
        }
    }

    fn obligationBaseTypeMatchesField(obligation_base_type: []const u8, field_type: []const u8) bool {
        if (std.mem.eql(u8, field_type, obligation_base_type)) return true;
        if (std.mem.lastIndexOf(u8, obligation_base_type, ":")) |colon| {
            return std.mem.eql(u8, field_type, obligation_base_type[colon + 1 ..]);
        }
        return false;
    }

    /// A tor that consumes <!state> on `base_type` but hands the SAME obligation
    /// back on an exit has settled nothing — calling it leaves the author owing
    /// exactly what they owed before. It is not a disposal candidate, and the
    /// auto-discharge inserter has always known that (`eventReIssuesObligation`,
    /// auto_discharge_inserter.zig:2597). This is the same predicate, so the
    /// disabled-mode KORU030 message reaches the same conclusion the inserter
    /// reaches — the disagreement 330_118 pins is two answers to one question,
    /// not a missing sentence.
    ///
    /// A CONVERTING tor stays a candidate: one that consumes <!open> on P and
    /// issues an obligation on a DIFFERENT base type has settled this debt,
    /// whatever it opened elsewhere. Hence the `base_type` guard on every arm.
    ///
    /// EVERY-EXIT rule (330_133): exclusion requires conservation on EVERY
    /// exit. One exit that converts — issues a different state, drops the
    /// value, or never touches the base type — settles the debt on that path,
    /// and the tor stays a candidate. Returning "reissues" on the FIRST
    /// conserving arm made partially-converting tors vanish from candidacy
    /// entirely while their converting arm was being called explicitly.
    fn eventReIssuesObligation(
        self: *PhantomSemanticChecker,
        event_decl: *const ast.EventDecl,
        base_state: []const u8,
        obligation_base_type: []const u8,
    ) bool {
        const base_state_name = if (std.mem.lastIndexOfScalar(u8, base_state, ':')) |idx|
            base_state[idx + 1 ..]
        else
            base_state;

        const Reissues = struct {
            fn check(alloc: std.mem.Allocator, phantom_text: []const u8, want: []const u8) bool {
                var parsed = phantom_parser.PhantomState.parse(alloc, phantom_text) catch return false;
                defer parsed.deinit(alloc);
                switch (parsed) {
                    .concrete => |c| return c.requires_cleanup and std.mem.eql(u8, c.name, want),
                    .state_union => |u| {
                        for (u.members) |m| {
                            if (m.requires_cleanup and std.mem.eql(u8, m.name, want)) return true;
                        }
                        return false;
                    },
                    .variable => return false,
                }
            }
        };

        // Bare return carrying the base type: re-issue only if its phantom
        // re-mints the SAME cleanup obligation. Matching type with no phantom
        // (or a non-cleanup phantom) means the debt is not handed back here —
        // this exit settles it.
        var any_exit = false;
        if (event_decl.return_type) |rt| {
            if (obligationBaseTypeMatchesField(obligation_base_type, rt)) {
                any_exit = true;
                const rp = event_decl.return_phantom orelse return false;
                if (!Reissues.check(self.allocator, rp, base_state_name)) return false;
            }
        }
        for (event_decl.branches) |branch| {
            var arm_carries = false;
            var arm_reissues = true;
            for (branch.payload.fields) |field| {
                if (!obligationBaseTypeMatchesField(obligation_base_type, field.type)) continue;
                arm_carries = true;
                const fp = field.phantom orelse {
                    arm_reissues = false;
                    break;
                };
                if (!Reissues.check(self.allocator, fp, base_state_name)) {
                    arm_reissues = false;
                    break;
                }
            }
            if (!arm_carries) return false; // this arm never touches the debt — settled here
            if (!arm_reissues) return false; // carries the value but not the SAME debt — converted
            any_exit = true;
        }
        // No payload-bearing exits at all: the plain void disposer. The debt
        // ends at the call — the opposite of re-issuing.
        return any_exit;
    }

    /// Find events that can discharge a given phantom state obligation
    /// Returns a list of event names that consume the given phantom state
    fn findDisposalEventsForState(self: *PhantomSemanticChecker, phantom_state: []const u8, obligation_base_type: []const u8) !std.ArrayList([]const u8) {
        var results = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);

        // Strip the ! suffix to get base state
        var base_state = phantom_state;
        if (std.mem.endsWith(u8, base_state, "!")) {
            base_state = base_state[0 .. base_state.len - 1];
        }

        // Search all events for <!state> parameters
        var iter = self.disposal_event_map.iterator();
        while (iter.next()) |entry| {
            const event_decl = entry.value_ptr.decl;

            if (self.eventReIssuesObligation(event_decl, base_state, obligation_base_type)) continue;

            for (event_decl.input.fields) |field| {
                if (field.phantom) |field_phantom| {
                    if (!obligationBaseTypeMatchesField(obligation_base_type, field.type)) continue;
                    // Parse to check if it consumes this state
                    var parsed = phantom_parser.PhantomState.parse(self.allocator, field_phantom) catch continue;
                    defer parsed.deinit(self.allocator);

                    switch (parsed) {
                        .concrete => |concrete| {
                            if (concrete.consumes_obligation) {
                                // Build full state name - canonicalize using event's module if no module specified
                                const consumer_state = try ast_functional.qualifiedStateName(self.allocator, concrete.module_path, entry.value_ptr.module_name, concrete.name);
                                defer self.allocator.free(consumer_state);

                                if (std.mem.eql(u8, consumer_state, base_state)) {
                                    // The map key is canonical (`std.io:free`),
                                    // dot-joined; the diagnostic names the
                                    // surface spelling the parser accepts
                                    // (`std/io:free`) — 335_056.
                                    const surface = try self.allocator.dupe(u8, entry.key_ptr.*);
                                    if (std.mem.lastIndexOfScalar(u8, surface, ':')) |colon| {
                                        for (surface[0..colon]) |*c| {
                                            if (c.* == '.') c.* = '/';
                                        }
                                    }
                                    try results.append(self.allocator, surface);
                                }
                            }
                        },
                        .variable => {},
                        .state_union => |u| {
                            // Discharge keys on the UNION, not the member:
                            // validateArgument settles the obligation when ANY
                            // member consumes, even if the matched member only
                            // borrows (`<!opened|closing>` discharges
                            // <closing!> — 330_124). This list is suggestion-
                            // only, so it must name every union discharger.
                            var any_consumes = false;
                            for (u.members) |m| {
                                if (m.consumes_obligation) {
                                    any_consumes = true;
                                    break;
                                }
                            }
                            for (u.members) |member| {
                                if (!member.consumes_obligation and !any_consumes) continue;
                                const consumer_state = try ast_functional.qualifiedStateName(self.allocator, member.module_path, entry.value_ptr.module_name, member.name);
                                defer self.allocator.free(consumer_state);

                                if (std.mem.eql(u8, consumer_state, base_state)) {
                                    // Same surface-spelling rewrite as the
                                    // concrete branch above — canonical keys
                                    // dot-join, diagnostics spell `/`.
                                    const surface = try self.allocator.dupe(u8, entry.key_ptr.*);
                                    if (std.mem.lastIndexOfScalar(u8, surface, ':')) |colon| {
                                        for (surface[0..colon]) |*c| {
                                            if (c.* == '.') c.* = '/';
                                        }
                                    }
                                    try results.append(self.allocator, surface);
                                    break;
                                }
                            }
                        },
                    }
                }
            }
        }

        return results;
    }

    fn validatePhantomAnnotations(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !bool {
        var has_errors = false;

        for (source_ast.items) |item| {
            switch (item) {
                .event_decl => |event_decl| {
                    // Check input fields
                    for (event_decl.input.fields) |field| {
                        if (field.phantom) |phantom_str| {
                            const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location, true);
                            if (!phantom_valid) {
                                has_errors = true;
                                // Continue checking for more errors
                            }
                        }
                    }

                    // Check branch output fields
                    for (event_decl.branches) |branch| {
                        for (branch.payload.fields) |field| {
                            if (field.phantom) |phantom_str| {
                                const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location, false);
                                if (!phantom_valid) {
                                    has_errors = true;
                                    // Continue checking for more errors
                                }
                            }
                        }
                    }

                    // Check the bare-return (`-> T<phantom>`) output phantom — same
                    // output rule as branch fields (e.g. reject `!`-consume on output).
                    if (event_decl.return_phantom) |phantom_str| {
                        const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location, false);
                        if (!phantom_valid) {
                            has_errors = true;
                        }
                    }
                },
                .module_decl => |module| {
                    // Check events in imported library modules
                    for (module.items) |mod_item| {
                        if (mod_item == .event_decl) {
                            const event_decl = mod_item.event_decl;

                            for (event_decl.input.fields) |field| {
                                if (field.phantom) |phantom_str| {
                                    const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location, true);
                                    if (!phantom_valid) {
                                        has_errors = true;
                                        // Continue checking for more errors
                                    }
                                }
                            }

                            for (event_decl.branches) |branch| {
                                for (branch.payload.fields) |field| {
                                    if (field.phantom) |phantom_str| {
                                        const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location, false);
                                        if (!phantom_valid) {
                                            has_errors = true;
                                            // Continue checking for more errors
                                        }
                                    }
                                }
                            }

                            if (event_decl.return_phantom) |phantom_str| {
                                const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location, false);
                                if (!phantom_valid) {
                                    has_errors = true;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }

        return !has_errors;
    }

    /// Parse a signature field's phantom and report whether it carries a
    /// cleanup-requiring concrete state ([!]) — every escape walk asks
    /// exactly this of the field it lands on.
    fn phantomRequiresCleanup(self: *PhantomSemanticChecker, phantom_str: []const u8) !bool {
        var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
        defer phantom.deinit(self.allocator);
        return switch (phantom) {
            .concrete => |concrete| concrete.requires_cleanup,
            .variable, .state_union => false,
        };
    }

    /// Whether a tracked binding's phantom carries the `scoped` class
    /// (`<name@class>` — see koru_std/phantom_parser.zig). A scoped debt may
    /// not occupy output position: `->` returns, branch payloads, and store
    /// columns all refuse it. The class lives on the VALUE's phantom, so the
    /// produce edge checks the resource, not the declared output.
    fn bindingHasScopedClass(
        self: *PhantomSemanticChecker,
        context: *BindingContext,
        name: []const u8,
    ) !bool {
        const phantom = context.get(name) orelse return false;
        var parsed = phantom_parser.PhantomState.parse(self.allocator, phantom) catch return false;
        defer parsed.deinit(self.allocator);
        return switch (parsed) {
            .concrete => |c| c.hasClass("scoped"),
            else => false,
        };
    }

    /// Does this value carry the `scoped` class — on its own binding or on any
    /// carrier prefix? Classes describe lifetime, and a projection's lifetime
    /// is its carrier's: `l.text` rides `l`'s frame exactly as `l` does.
    /// Identities do NOT descend this way (`b.text` is not `b`'s identity), so
    /// this walk is deliberately class-only.
    fn argHasScopedClass(
        self: *PhantomSemanticChecker,
        context: *BindingContext,
        arg_value: []const u8,
    ) !bool {
        const name = std.mem.trim(u8, arg_value, " \t");
        if (name.len == 0) return false;
        for (name) |c| {
            if (!isIdentChar(c) and c != '.') return false;
        }
        var prefix_end: usize = 0;
        while (prefix_end < name.len) {
            var seg = prefix_end;
            while (seg < name.len and name[seg] != '.') seg += 1;
            if (try self.bindingHasScopedClass(context, name[0..seg])) return true;
            prefix_end = seg + 1;
        }
        return false;
    }

    /// The classes a param position declares — `string<*@scoped>` accepts
    /// classed args (any identity + scoped), `string<*>`/`string` do not.
    /// `scoped` is the only confinement class today; `static` carries no rule
    /// and deliberately does not participate.
    fn expectedHasScopedClass(self: *PhantomSemanticChecker, expected_phantom: ?[]const u8) bool {
        const ep = expected_phantom orelse return false;
        var parsed = phantom_parser.PhantomState.parse(self.allocator, ep) catch return false;
        defer parsed.deinit(self.allocator);
        return switch (parsed) {
            .concrete => |c| c.hasClass("scoped"),
            .state_union => |u| blk: {
                for (u.members) |m| {
                    if (m.hasClass("scoped")) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    /// A produced value may not carry the `scoped` class — output position is
    /// where a frame-bound borrow escapes into a scope that outlives its
    /// frame. Covers every produce shape a branch_constructor spells: bare
    /// `-> expr`, `-> { f: expr }` record-literal produce, `=> { f: expr }`
    /// payload fields. The produced expr's own binding AND every tracked
    /// `expr.<field>` beneath it are checked — `-> r` rides `r.text` out
    /// just as surely as `-> r.text` does.
    fn refuseScopedProduce(
        self: *PhantomSemanticChecker,
        bc: *const ast.BranchConstructor,
        context: *BindingContext,
        location: errors.SourceLocation,
        implementing_event: ?*const ast.EventDecl,
    ) !bool {
        var reported = false;
        // A bare `-> expr` into a declared `*@scoped` output is a
        // class-preserving reissue, not an escape: the caller binds the value
        // still-scoped. Record-literal and `=>` field produce keep refusing —
        // caller-side record-field class conferral is not enforced yet, so
        // legalizing a declared `*@scoped` field would launder the class
        // through a hole that does not confer it back.
        const output_accepts_scoped = if (implementing_event) |impl_ev|
            self.expectedHasScopedClass(impl_ev.return_phantom)
        else
            false;
        if (bc.plain_value) |pv| {
            const expr = std.mem.trim(u8, pv, " \t");
            if (try ast_functional.recordFieldTexts(self.allocator, expr)) |fields| {
                defer self.allocator.free(fields);
                for (fields) |f| {
                    if (try self.refuseIfScopedProduced(f.value, context, location)) reported = true;
                }
            } else if (!output_accepts_scoped) {
                if (try self.refuseIfScopedProduced(expr, context, location)) reported = true;
            }
        }
        for (bc.fields) |f| {
            if (f.expression_str) |expr| {
                if (try self.refuseIfScopedProduced(expr, context, location)) reported = true;
            }
        }
        return reported;
    }

    /// Refuse one produced expression if its binding — or any tracked
    /// `expr.<field>` beneath it — carries the `scoped` class. Only
    /// identifier/path expressions can name bindings; anything else
    /// (literals, compound exprs) simply does not resolve.
    fn refuseIfScopedProduced(
        self: *PhantomSemanticChecker,
        expr: []const u8,
        context: *BindingContext,
        location: errors.SourceLocation,
    ) !bool {
        var reported = false;
        const name = std.mem.trim(u8, expr, " \t");
        if (name.len == 0) return false;
        for (name) |c| {
            if (!isIdentChar(c) and c != '.') return false;
        }
        // The full path and every prefix of it: a scoped RECORD's fields ride
        // its class — `-> l.text` escapes `l`'s scoped value under a field
        // name just as `-> l` does under the whole name.
        var prefix_end: usize = 0;
        while (prefix_end < name.len) {
            var seg = prefix_end;
            while (seg < name.len and name[seg] != '.') seg += 1;
            const prefix = name[0..seg];
            if (try self.bindingHasScopedClass(context, prefix)) {
                try self.reportScopedProduce(name, location);
                reported = true;
                break;
            }
            prefix_end = seg + 1;
        }
        // `-> r` carries every tracked `r.<field>` with it — a scoped field
        // on the produced record escapes under the record's clean name.
        var it = context.bindings.keyIterator();
        while (it.next()) |key| {
            const binding = key.*;
            if (binding.len <= name.len + 1) continue;
            if (!std.mem.startsWith(u8, binding, name)) continue;
            if (binding[name.len] != '.') continue;
            if (try self.bindingHasScopedClass(context, binding)) {
                try self.reportScopedProduce(binding, location);
                reported = true;
            }
        }
        return reported;
    }

    fn reportScopedProduce(
        self: *PhantomSemanticChecker,
        name: []const u8,
        location: errors.SourceLocation,
    ) !void {
        try self.reporter.addError(
            .KORU030,
            location.line,
            location.column,
            "'{s}' is @scoped — it dies with this frame and may not be produced out. Consume it in place, or copy it out first (std/string:from-page + take / fmt.blk)",
            .{name},
        );
    }

    fn validatePhantom(self: *PhantomSemanticChecker, phantom_str: []const u8, event_name: []const u8, location: errors.SourceLocation, is_input: bool) !bool {
        // `event_decl.location` is stored in USER coordinates
        // (parser.getUserDeclStartLocation — `--ast-json` reads it raw, pinned
        // by 210_164) while `addError` expects parser coordinates and
        // `classifyLine` subtracts the injected prelude at render. Handing the
        // decl location through untranslated double-subtracts: the caret lands
        // one line early — on the blank line above `~tor`, or `:0` for a decl
        // on line 1. Convert back to parser coordinates here.
        const report_line = if (std.mem.eql(u8, location.file, self.reporter.file_name))
            location.line + self.reporter.injection_line_count
        else
            location.line;

        var phantom = phantom_parser.PhantomState.parse(self.allocator, phantom_str) catch |err| {
            if (err == error.InvalidPhantomState) {
                // `<!*>` (or any `!`-marked `*`) names a settlement promise
                // with no named contract — refuse it here, by name. Other
                // malformed spellings get the generic wording.
                const wildcard_consume = std.mem.indexOfScalar(u8, phantom_str, '!') != null and
                    std.mem.indexOfScalar(u8, phantom_str, '*') != null;
                if (wildcard_consume) {
                    try self.reporter.addError(
                        .KORU033,
                        report_line,
                        location.column,
                        "Invalid phantom annotation '<{s}>' (tor: {s}): '!' promises to settle a NAMED obligation's contract — '*' names none. Use '<!module:state>' to discharge, or '<*>' to borrow any qualification.",
                        .{ phantom_str, event_name },
                    );
                } else {
                    try self.reporter.addError(
                        .KORU033,
                        report_line,
                        location.column,
                        "Invalid phantom annotation '<{s}>' (tor: {s}).",
                        .{ phantom_str, event_name },
                    );
                }
                return false;
            }
            return err;
        };
        defer phantom.deinit(self.allocator);

        switch (phantom) {
            .concrete => |concrete| {
                // Check for obligation issuance (! suffix) on input - this is invalid
                // You can only ISSUE obligations on outputs, not inputs
                if (is_input and concrete.requires_cleanup) {
                    try self.reporter.addError(
                        .KORU033,
                        report_line,
                        location.column,
                        "Cannot issue obligation '<{s}>' on input parameter (event: {s}). Use '<!{s}>' to consume an existing obligation, or remove the '!' suffix.",
                        .{ phantom_str, event_name, concrete.name },
                    );
                    return false;
                }

                // Check for obligation consumption (! prefix) on output - this is invalid
                // You can only CONSUME obligations on inputs, not outputs
                if (!is_input and concrete.consumes_obligation) {
                    try self.reporter.addError(
                        .KORU033,
                        report_line,
                        location.column,
                        "Cannot consume obligation '<{s}>' on output parameter (event: {s}). Use '<{s}!>' to issue a new obligation, or remove the '!' prefix.",
                        .{ phantom_str, event_name, concrete.name },
                    );
                    return false;
                }

                if (concrete.module_path) |mod_path| {
                    if ((try self.lookupModule(mod_path)) == null) {
                        try self.reporter.addError(
                            .KORU040, // Unknown event/proc/subflow - using for unknown module
                            report_line,
                            location.column,
                            "Unknown module '{s}' in phantom type annotation '{s}' (event: {s}). Module not imported.",
                            .{ mod_path, phantom_str, event_name },
                        );
                        // Return false to indicate error, but don't stop checking
                        return false;
                    }
                }
            },
            .variable => {
                // State variables are always valid (they're constraints, not concrete states)
            },
            .state_union => |u| {
                // State unions can only appear on inputs (they accept multiple states)
                // The phantom_parser already rejects unions with ! suffix (requires_cleanup)
                // Validate each member of the union
                for (u.members) |member| {
                    if (member.module_path) |mod_path| {
                        if ((try self.lookupModule(mod_path)) == null) {
                            try self.reporter.addError(
                                .KORU040,
                                report_line,
                                location.column,
                                "Unknown module '{s}' in phantom type annotation '{s}' (event: {s}). Module not imported.",
                                .{ mod_path, phantom_str, event_name },
                            );
                            return false;
                        }
                    }
                }
            },
        }

        return true;
    }

    // ========================================================================
    // Pass 2: Flow Analysis - Phantom State Compatibility Checking
    // ========================================================================

    /// Canonicalize a base type to its fully-qualified form
    ///
    /// Examples:
    ///   - "*Connection" in module "app.db" → "app.db:*Connection"
    ///   - "*User" with field.module_path "app.users" → "app.users:*User"
    ///
    /// This ensures base types from different modules with the same name
    /// are correctly distinguished during comparison.
    /// Resolve a module path through module_map, tolerating slash/dot separator
    /// differences. Users write the slash canon (KORU035: `*Field<std/field:field>`),
    /// but the phantom subsystem keys modules in dot form (`std.field`). Try the path
    /// as written, then with `/`<->`.` swapped, so either spelling resolves.
    /// Returns the canonical module value (owned by module_map) or null if unknown.
    fn lookupModule(self: *PhantomSemanticChecker, mod_path: []const u8) !?[]const u8 {
        if (self.module_map.get(mod_path)) |canonical| return canonical;
        const swapped = try self.allocator.alloc(u8, mod_path.len);
        defer self.allocator.free(swapped);
        for (mod_path, 0..) |ch, i| {
            swapped[i] = switch (ch) {
                '/' => '.',
                '.' => '/',
                else => ch,
            };
        }
        return self.module_map.get(swapped);
    }

    fn canonicalizeBaseType(
        self: *PhantomSemanticChecker,
        base_type: []const u8,
        field_module_path: ?[]const u8,
        defining_module: []const u8,
    ) ![]const u8 {
        // If the field has an explicit module path (cross-module type reference),
        // resolve it through module_map. Otherwise use the defining module.
        const canonical_module = if (field_module_path) |mod_path| blk: {
            if (try self.lookupModule(mod_path)) |canonical| {
                break :blk canonical;
            } else {
                // Module not found in map - use as-is
                break :blk mod_path;
            }
        } else defining_module;

        return try std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{ canonical_module, base_type },
        );
    }

    /// The type's own name, with every module qualifier, pointer marker and
    /// optional marker removed. `app.db:*Connection` -> `Connection`,
    /// `*app/lib/db:Transaction` -> `Transaction`, `?*File` -> `File`,
    /// `string` -> `string`. The qualifier can sit on either side of the `*`
    /// depending on whether the form was canonicalized here or written that
    /// way in source, so the last `:` is the only reliable seam.
    fn bareTypeName(base_type: []const u8) []const u8 {
        const after_module = if (std.mem.lastIndexOfScalar(u8, base_type, ':')) |c|
            base_type[c + 1 ..]
        else
            base_type;
        var i: usize = 0;
        while (i < after_module.len and (after_module[i] == '*' or after_module[i] == '?')) i += 1;
        return after_module[i..];
    }

    /// A type is optional when the first character after its module qualifier
    /// is `?` — `?*File`, `?i32`, `mod:?*Handle`.
    fn typeIsOptional(t: []const u8) bool {
        const after_module = if (std.mem.lastIndexOfScalar(u8, t, ':')) |c|
            t[c + 1 ..]
        else
            t;
        return after_module.len > 0 and after_module[0] == '?';
    }

    /// Two base types name the same type when their bare names agree AND they
    /// carry the same pointer depth. The module qualifier is deliberately not
    /// compared — see the long note at the base-type check for why it cannot be
    /// trusted, and what that costs.
    ///
    /// Optionality is compared asymmetrically: `*T` provided into a `?*T`
    /// parameter is the wrap Zig applies for free, while `?*T` provided into a
    /// required `*T` is a mismatch the backend would refuse — catch it here.
    fn baseTypesMatch(a: []const u8, b: []const u8) bool {
        if (!std.mem.eql(u8, bareTypeName(a), bareTypeName(b))) return false;
        if (std.mem.count(u8, a, "*") != std.mem.count(u8, b, "*")) return false;
        if (typeIsOptional(b) and !typeIsOptional(a)) return false;
        return true;
    }

    /// Canonicalize a phantom state to its fully-qualified form
    ///
    /// Examples:
    ///   - *File[open] in module "lib/fileops" → *File[lib/fileops:open]
    ///   - *File[fs:open] where fs→"koru/std/fs" → *File[koru/std/fs:open]
    ///   - *File[koru/std/fs:open] → *File[koru/std/fs:open] (already canonical)
    fn canonicalizePhantomState(
        self: *PhantomSemanticChecker,
        phantom_str: []const u8,
        defining_module: []const u8,
    ) ![]const u8 {
        return self.canonicalizePhantomStateWithBase(phantom_str, defining_module, null);
    }

    /// Resolve a field's base-type module qualifier (e.g. `app/lib/db` in
    /// `*app/lib/db:Transaction`) through the import map. Returns null when the
    /// base type carries no module — a primitive like `string`/`f32` — so a bare
    /// phantom on it falls back to the writing module (its only home).
    fn baseTypeModule(self: *PhantomSemanticChecker, field_module_path: ?[]const u8) !?[]const u8 {
        const mod_path = field_module_path orelse return null;
        return (try self.lookupModule(mod_path)) orelse mod_path;
    }

    /// Module half of a qualified type string (`*std/list:List_i64` → looked-up
    /// `std.list`). Used when a return type carries the qualifier in the string
    /// rather than on a Field.module_path.
    fn typeStringModule(self: *PhantomSemanticChecker, type_str: []const u8) !?[]const u8 {
        var base = std.mem.trim(u8, type_str, " \t");
        if (std.mem.indexOfScalar(u8, base, '<')) |lt| base = base[0..lt];
        const prefixes = [_][]const u8{ "[]const ", "?*const ", "*const ", "[]", "?*", "?", "*" };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, base, prefix)) {
                base = base[prefix.len..];
                break;
            }
        }
        const colon = std.mem.lastIndexOfScalar(u8, base, ':') orelse return null;
        if (colon == 0) return null;
        return (try self.lookupModule(base[0..colon])) orelse base[0..colon];
    }

    /// Canonicalize a phantom state, resolving a BARE state to `base_type_module`
    /// when the base type has a home module, else to `defining_module`. This is
    /// the ratified rule: a bare phantom self-resolves to the base type's module
    /// (`*app/lib/db:Transaction<active>` → `app/lib/db:active`); a primitive base
    /// has no module, so bare resolves to the writing module (`f32<celsius>` in
    /// module X → `X:celsius`). An explicitly-qualified state always names its own
    /// module and is unaffected.
    fn canonicalizePhantomStateWithBase(
        self: *PhantomSemanticChecker,
        phantom_str: []const u8,
        defining_module: []const u8,
        base_type_module: ?[]const u8,
    ) ![]const u8 {
        const bare_module = base_type_module orelse defining_module;
        // `<*>` is the any-qualification wildcard, not a state — it has no
        // home module and must survive canonicalization intact.
        if (std.mem.eql(u8, phantom_str, "*")) return try self.allocator.dupe(u8, phantom_str);
        var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
        defer phantom.deinit(self.allocator);

        switch (phantom) {
            .concrete => |concrete| {
                const canonical_module = if (concrete.module_path) |mod_path| blk: {
                    // Already has module qualifier - resolve it through module_map
                    if (try self.lookupModule(mod_path)) |canonical| {
                        break :blk canonical;
                    } else {
                        // Module not found - use as-is (error will be caught in validation)
                        break :blk mod_path;
                    }
                } else blk: {
                    // No module qualifier - self-resolve to the base type's module
                    break :blk bare_module;
                };

                // Build canonical form: module:state, module:state!@class…,
                // module:state! — `!` rides the name atom ahead of the join;
                // classes are sorted in parse, so the join is already
                // canonical.
                const cleanup_suffix = if (concrete.requires_cleanup) "!" else "";
                var canon: std.ArrayListUnmanaged(u8) = .{};
                errdefer canon.deinit(self.allocator);
                try canon.appendSlice(self.allocator, canonical_module);
                try canon.append(self.allocator, ':');
                try canon.appendSlice(self.allocator, concrete.name);
                try canon.appendSlice(self.allocator, cleanup_suffix);
                for (concrete.classes) |cls| {
                    try canon.append(self.allocator, '@');
                    try canon.appendSlice(self.allocator, cls);
                }
                return canon.toOwnedSlice(self.allocator);
            },
            .variable => {
                // State variables don't get canonicalized - they're constraints
                return try self.allocator.dupe(u8, phantom_str);
            },
            .state_union => |u| {
                // Canonicalize each member of the union
                var result: std.ArrayListUnmanaged(u8) = .{};
                errdefer result.deinit(self.allocator);

                for (u.members, 0..) |member, i| {
                    if (i > 0) try result.append(self.allocator, '|');
                    // Per-member ! prefix
                    if (member.consumes_obligation) try result.append(self.allocator, '!');

                    // `*` is the catch-all, not a state — it has no home
                    // module and carries verbatim.
                    if (std.mem.eql(u8, member.name, "*")) {
                        try result.append(self.allocator, '*');
                        continue;
                    }

                    const canonical_module = if (member.module_path) |mod_path| blk: {
                        if (try self.lookupModule(mod_path)) |canonical| {
                            break :blk canonical;
                        } else {
                            break :blk mod_path;
                        }
                    } else blk: {
                        break :blk bare_module;
                    };

                    // Append module:state@class…
                    try result.appendSlice(self.allocator, canonical_module);
                    try result.append(self.allocator, ':');
                    try result.appendSlice(self.allocator, member.name);
                    for (member.classes) |cls| {
                        try result.append(self.allocator, '@');
                        try result.appendSlice(self.allocator, cls);
                    }
                }

                return result.toOwnedSlice(self.allocator);
            },
        }
    }

    /// Binding context tracks phantom states of variables in scope
    /// Each binding tracks BOTH the phantom state AND the base type
    const BindingContext = struct {
        /// Full type information for a binding
        const BindingInfo = struct {
            phantom_state: []const u8, // e.g., "app.db:active!"
            base_type: []const u8, // e.g., "*Connection"
        };

        bindings: std.StringHashMap(BindingInfo), // variable name → full type info
        cleanup_obligations: std.StringHashMap(void), // track bindings with ! states that need cleanup
        disposed_bindings: std.StringHashMap([]const u8), // binding name -> the SITE that disposed it (event#arg=value), so re-validation of the same consuming site passes while a second consume from a DIFFERENT site is use-after-discharge
        outer_scope_obligations: std.StringHashMap(void), // track obligations from outside @scope boundary
        join_live_obligations: std.StringHashMap(void), // obligations inherited by a named arm that a join continuation follows — live-through the arm, settle at the join (twin of auto_discharge_inserter's join_watermark)
        /// Declared-type-only bindings (registry rung 1): a phantom-less
        /// payload's base type, recorded so the nominal-distinctness check
        /// (validateArgument's no-phantom gate) can compare it against the
        /// expected param WITHOUT touching the phantom machinery. Kept apart
        /// from `bindings` on purpose — a phantom-less value registered in
        /// `bindings` with an empty state would leak into the phantom
        /// comparison paths ("has no tracked phantom state" would stop firing;
        /// an empty state would be canonicalized). Separate table, separate
        /// life: zero risk to existing phantom behavior.
        base_types: std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) BindingContext {
            return BindingContext{
                .bindings = std.StringHashMap(BindingInfo).init(allocator),
                .cleanup_obligations = std.StringHashMap(void).init(allocator),
                .disposed_bindings = std.StringHashMap([]const u8).init(allocator),
                .outer_scope_obligations = std.StringHashMap(void).init(allocator),
                .join_live_obligations = std.StringHashMap(void).init(allocator),
                .base_types = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *BindingContext) void {
            var iter = self.bindings.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.phantom_state);
                self.allocator.free(entry.value_ptr.base_type);
            }
            self.bindings.deinit();

            // Free base-type-only bindings
            ast_functional.freeStringMap(self.allocator, &self.base_types);

            // Free cleanup obligation keys
            ast_functional.freeKeySet(self.allocator, &self.cleanup_obligations);

            // Free disposed binding keys and site values
            ast_functional.freeStringMap(self.allocator, &self.disposed_bindings);

            // Free outer scope obligation keys
            ast_functional.freeKeySet(self.allocator, &self.outer_scope_obligations);

            // Free join-live obligation keys
            ast_functional.freeKeySet(self.allocator, &self.join_live_obligations);
        }

        /// Record a phantom-less binding's declared type. See base_types doc.
        fn setBaseType(self: *BindingContext, name: []const u8, base_type: []const u8) !void {
            if (self.base_types.getPtr(name)) |info| {
                const new_copy = try self.allocator.dupe(u8, base_type);
                self.allocator.free(info.*);
                info.* = new_copy;
                return;
            }
            const name_copy = try self.allocator.dupe(u8, name);
            const type_copy = try self.allocator.dupe(u8, base_type);
            try self.base_types.put(name_copy, type_copy);
        }

        /// Set a binding with both phantom state and base type
        fn setWithType(self: *BindingContext, name: []const u8, phantom_state: []const u8, base_type: []const u8) !void {
            // Remove old binding if exists
            if (self.bindings.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.phantom_state);
                self.allocator.free(kv.value.base_type);
            }

            // Add new binding
            const name_copy = try self.allocator.dupe(u8, name);
            const phantom_copy = try self.allocator.dupe(u8, phantom_state);
            const type_copy = try self.allocator.dupe(u8, base_type);
            try self.bindings.put(name_copy, .{
                .phantom_state = phantom_copy,
                .base_type = type_copy,
            });

            // Check if this phantom state has cleanup obligation (! suffix)
            var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_state);
            defer phantom.deinit(self.allocator);

            switch (phantom) {
                .concrete => |concrete| {
                    if (concrete.requires_cleanup) {
                        // Track this binding as requiring cleanup
                        const obligation_key = try self.allocator.dupe(u8, name);
                        try self.cleanup_obligations.put(obligation_key, {});
                        log.debug("[CLEANUP] Tracking cleanup obligation for '{s}' with type '{s}[{s}]'\n", .{ name, base_type, phantom_state });
                    }
                },
                .variable => {},
                .state_union => {
                    // State unions cannot have cleanup obligations (they can't be output)
                    // They may have consumes_obligation (! prefix) for input, but that's
                    // handled at invocation time, not binding time
                },
            }
        }

        /// Legacy set function - calls setWithType with empty base type
        /// TODO: Remove this once all callers are updated to use setWithType
        fn set(self: *BindingContext, name: []const u8, phantom_state: []const u8) !void {
            try self.setWithType(name, phantom_state, "");
        }

        /// Get full binding info (phantom state + base type)
        fn getInfo(self: *BindingContext, name: []const u8) ?BindingInfo {
            return self.bindings.get(name);
        }

        /// Get just the phantom state (for backwards compatibility)
        fn get(self: *BindingContext, name: []const u8) ?[]const u8 {
            if (self.bindings.get(name)) |info| {
                return info.phantom_state;
            }
            return null;
        }

        /// Get the base type for a binding
        fn getBaseType(self: *BindingContext, name: []const u8) ?[]const u8 {
            // Registry rung 1: a phantom-less binding records its declared
            // type on the separate base_types table; consult it first, then
            // fall back to the phantom-tracked binding.
            if (self.base_types.get(name)) |t| return t;
            if (self.bindings.get(name)) |info| {
                return info.base_type;
            }
            return null;
        }

        /// Deep-copy `src`'s BindingInfo entries into `dst` (duped keys and
        /// field strings owned by `allocator`).
        fn dupeBindingsInto(
            allocator: std.mem.Allocator,
            src: std.StringHashMap(BindingInfo),
            dst: *std.StringHashMap(BindingInfo),
        ) !void {
            var it = src.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try dst.put(key, .{
                    .phantom_state = try allocator.dupe(u8, entry.value_ptr.phantom_state),
                    .base_type = try allocator.dupe(u8, entry.value_ptr.base_type),
                });
            }
        }

        /// Create a child context that inherits parent's state
        fn inherit(parent: *const BindingContext, allocator: std.mem.Allocator) !BindingContext {
            var child = BindingContext.init(allocator);

            // Inherit all bindings (copy full BindingInfo)
            try dupeBindingsInto(allocator, parent.bindings, &child.bindings);

            // Inherit base-type-only bindings (registry rung 1)
            try ast_functional.dupeStringMapInto(allocator, parent.base_types, &child.base_types);

            // Inherit cleanup obligations
            try ast_functional.dupeKeySetInto(allocator, parent.cleanup_obligations, &child.cleanup_obligations);

            // Inherit disposed bindings (with their disposing sites)
            try ast_functional.dupeStringMapInto(allocator, parent.disposed_bindings, &child.disposed_bindings);

            // Inherit outer scope obligations (already marked as outer)
            try ast_functional.dupeKeySetInto(allocator, parent.outer_scope_obligations, &child.outer_scope_obligations);

            // Inherit join-live markings — an obligation live-through an
            // enclosing arm's join stays live-through deeper in that arm.
            try ast_functional.dupeKeySetInto(allocator, parent.join_live_obligations, &child.join_live_obligations);

            return child;
        }

        /// Create a child context that marks all inherited cleanup obligations as "outer scope"
        /// Used when entering a @scope boundary - these obligations cannot be satisfied inside the scope
        fn inheritWithScope(parent: *const BindingContext, allocator: std.mem.Allocator) !BindingContext {
            var child = BindingContext.init(allocator);

            // Inherit all bindings (copy full BindingInfo)
            try dupeBindingsInto(allocator, parent.bindings, &child.bindings);

            // Inherit base-type-only bindings (registry rung 1)
            try ast_functional.dupeStringMapInto(allocator, parent.base_types, &child.base_types);

            // Inherit cleanup obligations AND mark them as outer scope -
            // they cannot be satisfied inside @scope
            try ast_functional.dupeKeySetInto(allocator, parent.cleanup_obligations, &child.cleanup_obligations);
            try ast_functional.dupeKeySetInto(allocator, parent.cleanup_obligations, &child.outer_scope_obligations);

            // Inherit disposed bindings (with their disposing sites)
            try ast_functional.dupeStringMapInto(allocator, parent.disposed_bindings, &child.disposed_bindings);

            // Also inherit any already-marked outer scope obligations from parent
            var outer_iter = parent.outer_scope_obligations.keyIterator();
            while (outer_iter.next()) |key| {
                if (!child.outer_scope_obligations.contains(key.*)) {
                    const key_copy = try allocator.dupe(u8, key.*);
                    try child.outer_scope_obligations.put(key_copy, {});
                }
            }

            // Inherit join-live markings (as in `inherit`)
            try ast_functional.dupeKeySetInto(allocator, parent.join_live_obligations, &child.join_live_obligations);

            return child;
        }

        /// Remove cleanup obligation for a binding (called when it's properly cleaned up)
        fn clearCleanupObligation(self: *BindingContext, name: []const u8) void {
            if (self.cleanup_obligations.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                log.debug("[CLEANUP] Cleared cleanup obligation for '{s}'\n", .{name});
            }
        }

        /// Mark a binding as disposed (poisoned), recording WHICH site consumed
        /// it so re-validation of that same site is not misread as double-use.
        fn markDisposed(self: *BindingContext, name: []const u8, site: []const u8) !void {
            if (self.disposed_bindings.contains(name)) return; // keep the FIRST disposing site
            const disposed_key = try self.allocator.dupe(u8, name);
            const site_copy = try self.allocator.dupe(u8, site);
            try self.disposed_bindings.put(disposed_key, site_copy);
            log.debug("[CLEANUP] Marked '{s}' as discharged (poisoned) at site '{s}'\n", .{ name, site });
        }

        /// Check if a binding has been disposed
        fn isDisposed(self: *BindingContext, name: []const u8) bool {
            return self.disposed_bindings.contains(name);
        }

        /// The site that disposed a binding (null if not disposed)
        fn disposalSite(self: *BindingContext, name: []const u8) ?[]const u8 {
            return self.disposed_bindings.get(name);
        }

        /// Check if there are any uncleaned resources
        fn hasUncleanedResources(self: *BindingContext) bool {
            return self.cleanup_obligations.count() > 0;
        }

        /// Get list of bindings with uncleaned resources (for error reporting)
        fn getUncleanedResources(self: *BindingContext, allocator: std.mem.Allocator) ![][]const u8 {
            const count = self.cleanup_obligations.count();
            if (count == 0) return &[_][]const u8{};

            var list = try allocator.alloc([]const u8, count);
            var iter = self.cleanup_obligations.keyIterator();
            var i: usize = 0;
            while (iter.next()) |key| : (i += 1) {
                list[i] = key.*;
            }
            return list;
        }

        /// Does this binding hold a live obligation that `<!state>` could settle?
        ///
        /// The alternative predicate for the debt-exists check at the consume
        /// site (see `enforce_debt_exists`). Measured identical to parsing the
        /// provided phantom: both close 335_054 / 335_055 and both refuse
        /// delegation while 330_076 is red. Kept because it reads the authority
        /// directly rather than re-deriving it from a string.
        fn owesObligation(self: *BindingContext, name: []const u8) bool {
            return self.cleanup_obligations.contains(name) or
                self.outer_scope_obligations.contains(name);
        }

        /// Check if there are any outer-scope uncleaned resources
        /// These are obligations from outside a @scope boundary that cannot be satisfied inside
        fn hasOuterScopeObligations(self: *BindingContext) bool {
            // Check if any uncleaned resource is also marked as outer scope
            var iter = self.cleanup_obligations.keyIterator();
            while (iter.next()) |key| {
                if (self.outer_scope_obligations.contains(key.*)) {
                    return true;
                }
            }
            return false;
        }

        /// Get list of outer-scope uncleaned resources (for error reporting)
        fn getOuterScopeObligations(self: *BindingContext, allocator: std.mem.Allocator) ![][]const u8 {
            var count: usize = 0;
            var iter = self.cleanup_obligations.keyIterator();
            while (iter.next()) |key| {
                if (self.outer_scope_obligations.contains(key.*)) {
                    count += 1;
                }
            }
            if (count == 0) return &[_][]const u8{};

            var list = try allocator.alloc([]const u8, count);
            iter = self.cleanup_obligations.keyIterator();
            var i: usize = 0;
            while (iter.next()) |key| {
                if (self.outer_scope_obligations.contains(key.*)) {
                    list[i] = key.*;
                    i += 1;
                }
            }
            return list;
        }

        /// Check if a specific obligation is from outer scope
        fn isOuterScope(self: *BindingContext, name: []const u8) bool {
            return self.outer_scope_obligations.contains(name);
        }

        /// Check if a specific obligation is live-through a downstream join
        /// continuation (the arm's leaf is not an exit for it).
        fn isJoinLive(self: *BindingContext, name: []const u8) bool {
            return self.join_live_obligations.contains(name);
        }

        /// Mark every obligation inherited so far as live-through a join that
        /// follows this named arm. Call right after the context is built —
        /// obligations bound later (inside the arm) stay the arm's own.
        fn markInheritedJoinLive(self: *BindingContext) !void {
            var iter = self.cleanup_obligations.keyIterator();
            while (iter.next()) |key| {
                if (!self.join_live_obligations.contains(key.*)) {
                    const key_copy = try self.allocator.dupe(u8, key.*);
                    try self.join_live_obligations.put(key_copy, {});
                }
            }
        }
    };

    /// Event info for flow validation
    const EventInfo = struct {
        decl: *const ast.EventDecl,
    };

    fn validatePhantomFlows(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !bool {
        log.debug("[PHANTOM-FLOW] Pass 2: Validating phantom flows\n", .{});

        // Build event map for lookup (module:event → EventInfo)
        var event_map = std.StringHashMap(EventInfo).init(self.allocator);
        defer {
            // Free all the keys we allocated
            var key_iter = event_map.keyIterator();
            while (key_iter.next()) |key| {
                self.allocator.free(key.*);
            }
            event_map.deinit();
        }

        try self.buildEventMap(source_ast, &event_map);
        log.debug("[PHANTOM-FLOW] Built event map with {} events\n", .{event_map.count()});

        // Validate all flows/procs, tracking module context
        return self.validateItems(source_ast.items, &event_map, null);
    }

    fn validateItems(self: *PhantomSemanticChecker, items: []const ast.Item, event_map: *std.StringHashMap(EventInfo), current_module: ?[]const u8) !bool {
        var has_errors = false;

        for (items) |item| {
            switch (item) {
                .flow => |*flow| {
                    if (flow.impl_of) |impl_path| {
                        const module = current_module orelse "input";
                        log.debug("[PHANTOM-FLOW] Validating impl flow in module '{s}'\n", .{module});

                        const impl_event_name = try self.pathToString(impl_path);
                        defer self.allocator.free(impl_event_name);

                        // The module component of the event_map key the impl
                        // resolved under — the name every other canonicalization
                        // in this frame anchors on (the logical `app.m`), NOT
                        // `event_decl.module`, which is the parse-time file stem
                        // (`m`) for module items (330_134).
                        var impl_module: ?[]const u8 = null;

                        // event_map is keyed by the event's canonical module. For
                        // metacircular impls `current_module` carries it
                        // (`std.compiler`); for a plain user program `current_module`
                        // is null (→ "input") and the event lives under `flow.module`
                        // (e.g. `min_flowparam`). Try both so the implementing event
                        // resolves in either case — this is what lets a user flow's
                        // own phantom-typed parameters get seeded (see validateFlow).
                        const impl_event: ?*const ast.EventDecl = blk: {
                            const q1 = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module, impl_event_name });
                            defer self.allocator.free(q1);
                            if (event_map.get(q1)) |info| {
                                impl_module = module;
                                break :blk info.decl;
                            }
                            const q2 = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ flow.module, impl_event_name });
                            defer self.allocator.free(q2);
                            if (event_map.get(q2)) |info| {
                                impl_module = flow.module;
                                break :blk info.decl;
                            }
                            break :blk null;
                        };

                        if (impl_event) |ev| {
                            log.debug("[PHANTOM-FLOW]   Impl flow implements event: '{s}'\n", .{impl_event_name});
                            _ = ev;
                        } else {
                            log.debug("[PHANTOM-FLOW]   Impl event '{s}' not found in event map\n", .{impl_event_name});
                        }

                        if (!try self.validateFlow(flow, event_map, module, impl_event, impl_module)) {
                            has_errors = true;
                        }
                    } else {
                        const module = flow.module;
                        log.debug("[PHANTOM-FLOW] Validating flow in module '{s}'\n", .{module});
                        if (!try self.validateFlow(flow, event_map, module, null, null)) {
                            has_errors = true;
                        }
                    }
                },
                .proc_decl => {},
                .module_decl => |module| {
                    // Recursively validate items in module
                    if (!try self.validateItems(module.items, event_map, module.logical_name)) {
                        has_errors = true;
                    }
                },
                else => {},
            }
        }

        return !has_errors;
    }

    fn buildEventMap(self: *PhantomSemanticChecker, source_ast: *const ast.Program, event_map: *std.StringHashMap(EventInfo)) !void {
        // Build event map from both top-level events (user code) and module events (libraries)
        for (source_ast.items) |*item| {
            switch (item.*) {
                .event_decl => |*event_decl| {
                    // Top-level event (user code) - use event.module metadata
                    const event_name = try self.pathToString(event_decl.path);
                    defer self.allocator.free(event_name);

                    // A `part` facet's decls merge in with .module = the part's
                    // stem (input.comp) while their path carries the primary
                    // module_qualifier (input) that call sites qualify under.
                    // Key by the owner the calls spell — 330_136.
                    const owner = event_decl.path.module_qualifier orelse event_decl.module;
                    // Store with module:event format (using : separator, not .)
                    const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ owner, event_name });
                    try event_map.put(qualified_name, EventInfo{ .decl = event_decl });
                },
                .module_decl => |module| {
                    // Events in imported library modules
                    for (module.items) |*mod_item| {
                        if (mod_item.* == .event_decl) {
                            const event_decl = &mod_item.event_decl;
                            const event_name = try self.pathToString(event_decl.path);
                            defer self.allocator.free(event_name);

                            // Store with module:event format (using : separator, not .)
                            const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module.logical_name, event_name });
                            try event_map.put(qualified_name, EventInfo{ .decl = event_decl });
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn validateFlow(
        self: *PhantomSemanticChecker,
        flow: *const ast.Flow,
        event_map: *std.StringHashMap(EventInfo),
        current_module: []const u8,
        implementing_event: ?*const ast.EventDecl, // Event this flow implements (for branch_constructor escape checking)
        impl_module: ?[]const u8, // event_map key module impl_event resolved under (≠ event_decl.module for module items)
    ) !bool {
        var has_errors = false;

        // Get the event name from path segments
        const event_name = try self.pathToString(flow.inv().path);
        defer self.allocator.free(event_name);

        // Determine the module - use module_qualifier if present, otherwise current_module
        const module_name = flow.inv().path.module_qualifier orelse current_module;

        // Build fully-qualified event name (module:event)
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_name });
        defer self.allocator.free(qualified_name);

        log.debug("[PHANTOM-FLOW]   Flow invokes: '{s}' in module '{s}' → qualified: '{s}'\n", .{ event_name, module_name, qualified_name });

        const event_info = event_map.get(qualified_name) orelse {
            log.debug("[PHANTOM-FLOW]   Event '{s}' not found in map, skipping\n", .{qualified_name});
            // Event not found - shape_checker will catch this, we just skip
            return true;
        };

        log.debug("[PHANTOM-FLOW]   Found event '{s}', validating continuations\n", .{qualified_name});

        // A pre-label fold head (`~spin = #loop step(h)`) declares the label on
        // the flow itself (Flow.pre_label) — the flow's own invocation is the
        // fold's round event. Register it so back-edge `@label` jumps validate
        // their args (use-after-discharge, obligation routing) instead of
        // silently skipping on a label_map miss. The mid-chain form
        // (`... |> #loop step(...)`) registers in validateContinuation.
        if (flow.pre_label) |pre_label| {
            try self.label_map.put(pre_label, .{ .decl = event_info.decl, .module = module_name });
            if (!try self.validateLabelArgNames(flow.inv().args, event_info.decl, flow.location, "#label call")) {
                has_errors = true;
            }
        }

        // Validate root invocation args (e.g. bare literals at phantom-required params).
        // Continuation validation only covers args on nested steps, not the flow head.
        var root_context = BindingContext.init(self.allocator);
        defer root_context.deinit();

        // Seed the implementing event's phantom-carrying parameters into the root
        // context, so the flow body can reference them. Example: a user flow
        // `use1 = std/field:clear(f) |> ...` implements event
        // `use1 { f: *Field<std/field:field> }`; without seeding `f`, the moment the
        // body passes `f` to another phantom event it reads as untracked (KORU030).
        // Borrow params (`<field>`, no `!`) carry no obligation, so no leak is
        // synthesized. A bare phantom on a qualified type (`*std/field:Field<field>`)
        // self-resolves to the type's module (330_112); the old spelling restated
        // that module on the phantom and is refused.
        if (implementing_event) |impl_ev| {
            for (impl_ev.input.fields) |field| {
                if (field.phantom) |phantom_str| {
                    // Seed BORROW params (`<state>`) and CONSUME params
                    // (`<!state>` / `<mod:!state>`). LINEAR TRANSFER, ruled
                    // 2026-07-02: the event decl is the contract — a host proc
                    // is TRUSTED to perform the discharge it promises (the
                    // escape hatch), while a pure subflow impl is CHECKED: the
                    // consumed obligation enters the body live (`state!`) and
                    // the checker proves it is discharged exactly once (onward
                    // consume, issuing output branch) — a drop leaks loudly,
                    // a double-consume is use-after-discharge. Supersedes the
                    // old at-the-door reading that made consuming events
                    // host-only (330_076 flips to a positive pin; 330_079/080
                    // remain the true linearity walls).
                    //
                    // An ISSUE marker on an input (`<state!>`) stays unseeded —
                    // rejected by directionality (validatePhantom is_input).
                    const canonical_phantom = try self.canonicalizePhantomStateWithBase(
                        phantom_str,
                        impl_module orelse impl_ev.module,
                        try self.baseTypeModule(field.module_path),
                    );
                    defer self.allocator.free(canonical_phantom);
                    // Markers must be read off the RAW spelling: the concrete arm of
                    // canonicalizePhantomStateWithBase re-renders `module:state` and
                    // keeps only the issue suffix (`state!`) — a consume prefix
                    // (`!state`) does not survive it (the union arm preserves it;
                    // the concrete arm never did). Parsing the canonical string here
                    // is what silently turned every transferred debt into a borrow.
                    var parsed = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
                    defer parsed.deinit(self.allocator);
                    const concrete = switch (parsed) {
                        .concrete => |c| c,
                        .state_union => |u| {
                            // A BORROW union (`<a|b>`) tracks the union itself:
                            // re-passing it to a param spelled the same way
                            // typechecks, while a concrete `<a>` callee refuses
                            // because the member cannot be proven. A union with
                            // any consume member stays unseeded — the body
                            // cannot name which member's debt it holds.
                            var any_consume = false;
                            for (u.members) |m| {
                                if (m.consumes_obligation) any_consume = true;
                            }
                            if (!any_consume) {
                                const union_base_type = try self.canonicalizeBaseType(field.type, field.module_path, impl_module orelse impl_ev.module);
                                defer self.allocator.free(union_base_type);
                                try root_context.setWithType(field.name, canonical_phantom, union_base_type);
                            }
                            continue;
                        },
                        else => continue,
                    };
                    if (concrete.requires_cleanup) continue; // issue-on-input: directionality rejects
                    const canonical_base_type = try self.canonicalizeBaseType(field.type, field.module_path, impl_module orelse impl_ev.module);
                    defer self.allocator.free(canonical_base_type);
                    if (concrete.consumes_obligation) {
                        // The held debt spells `module:name!@class…` — `!`
                        // rides the name atom ahead of the join; a class
                        // can't owe a debt.
                        const held = blk: {
                            if (std.mem.indexOfScalar(u8, canonical_phantom, '@')) |at| {
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}!{s}", .{ canonical_phantom[0..at], canonical_phantom[at..] });
                            }
                            break :blk try std.fmt.allocPrint(self.allocator, "{s}!", .{canonical_phantom});
                        };
                        defer self.allocator.free(held);
                        try root_context.setWithType(field.name, held, canonical_base_type);
                        // The marker exists so CONSUME SITES can tell "I was
                        // given this" from "I was only shown this" (the
                        // debt-exists wall reads the binding's recorded state).
                        // It must NOT feed the leak audit: a terminal disposer
                        // settles the debt invisibly (its proc/use IS the
                        // implementation — measured on the store's generated
                        // impls, 690_053 et al., 20 reds when this obligation
                        // stood). The silent-drop wall is the inserter's.
                        root_context.clearCleanupObligation(field.name);
                    } else {
                        try root_context.setWithType(field.name, canonical_phantom, canonical_base_type);
                    }
                }
            }
        }

        for (flow.inv().args, 0..) |arg, arg_idx| {
            const arg_valid = try self.validateArgument(arg, arg_idx, event_info.decl, module_name, &root_context, flow.location, null);
            if (!arg_valid) {
                has_errors = true;
            }
        }

        // Bare-return bind at the FLOW HEAD: `~create(...): c |> transition(r: c)`
        // binds `c` to create's `-> T<phantom>` return. Record its phantom in the
        // root context so the chained continuation sees `c`'s obligation — the
        // flow-head twin of the nested-continuation bare-return bind handled in
        // validateContinuation. Without it, `c` reaches `transition(r: c)` with no
        // tracked obligation. (The nested case never fires for a top-level head.)
        if (flow.inv().return_binding) |rb| {
            if (event_info.decl.return_phantom) |rp| {
                const ret_home = if (event_info.decl.return_type) |rt| try self.typeStringModule(rt) else null;
                const canonical_phantom = try self.canonicalizePhantomStateWithBase(rp, module_name, ret_home);
                defer self.allocator.free(canonical_phantom);
                if (event_info.decl.return_type) |rt| {
                    const canonical_base_type = try self.canonicalizeBaseType(rt, null, module_name);
                    defer self.allocator.free(canonical_base_type);
                    try root_context.setWithType(rb, canonical_phantom, canonical_base_type);
                } else {
                    try root_context.set(rb, canonical_phantom);
                }
            } else if (event_info.decl.return_type) |rt| {
                // No whole-value phantom, but a record return may carry per-field
                // obligations (`-> { h: *Handle<owned!>, g: *Handle<owned!> }`).
                // Seed each so a field projection / destructured field discharge
                // is credited (challenge 007). Uses the head's destructure (if
                // any) to key destructured obligation fields by scalar name.
                //
                // Subflow-implemented tors seed identically: the produce edge
                // verifies every `<state!>` field of the declared record is fed
                // by a live obligation before it escapes (auto_discharge_inserter's
                // verifyProducedFieldObligations), so the declared record type is
                // a checked contract, not a claim — `dispose(res.h)` on a subflow-
                // returned record is credited exactly like a proc-returned one.
                try self.seedRecordFieldObligations(rb, rt, module_name, flow.inv().return_destructure, &root_context);
                // Registry rung 1: a phantom-less bare return whose type is a
                // declared identity (not a record) records its base type so
                // the nominal-distinctness check can compare it downstream
                // (030_132/133, 340_006 — the bare-return spelling the parser
                // demands for a single produced payload).
                if (rt.len > 0 and std.mem.indexOfScalar(u8, rt, '{') == null) {
                    const canonical_base_type = try self.canonicalizeBaseType(rt, null, module_name);
                    defer self.allocator.free(canonical_base_type);
                    try root_context.setBaseType(rb, canonical_base_type);
                }
            }
        }

        // For each continuation, validate phantom state flows
        // Pass both: current_module (where flow is defined, for name resolution)
        // and module_name (where event is defined, for phantom qualification).
        // Pass root_context so the flow-head bare-return bind propagates.
        for (flow.body.continuations, 0..) |*cont_ptr, cont_idx| {
            const cont_valid = try self.validateContinuation(cont_ptr, event_info.decl, module_name, current_module, event_map, flow.location, &root_context, implementing_event, cont_ptr.branch.len != 0 and joinFollows(flow.body.continuations, cont_idx), flow.inv());
            if (!cont_valid) {
                has_errors = true;
                // Continue checking for more errors
            }
        }

        return !has_errors;
    }

    /// Register a bare-return bind (`call(...): name`) into `context`, tracking
    /// `name` with the invoked event's `-> T<phantom>` return obligation. This is
    /// the same recording done at the flow head (line ~1056) and for a named
    /// branch's nested continuations (line ~1806) — factored out so an
    /// INTERMEDIATE step in a bare-return chain (`make(): h |> t1(h): a |> ...`)
    /// records `a` too. Without it only the flow head's bind survives, so the
    /// second link onward reaches its consumer with no tracked obligation
    /// (spurious KORU030). `step_module` is the call-site qualifier the step's
    /// required-state canonicalization also uses.
    fn recordBareReturnBind(
        self: *PhantomSemanticChecker,
        inv: *const ast.Invocation,
        step_decl: *const ast.EventDecl,
        step_module: []const u8,
        context: *BindingContext,
    ) anyerror!void {
        const rb = inv.return_binding orelse return;
        try self.recordReturnObligationAs(rb, inv.return_destructure, step_decl, step_module, context);
    }

    /// Record a bare-return call's `-> T<phantom>` obligation against an
    /// arbitrary binding NAME. `recordBareReturnBind` routes the `: name`
    /// spelling here; the named-label spelling (`| made c |>` on a bare-return
    /// callee) routes here from validateContinuation's 0-branch path, because
    /// the emitter lowers both spellings to the same direct bind — the label is
    /// binding sugar, and the checker must credit whichever name the author
    /// chose, or the obligation detaches from every name the flow can discharge
    /// through.
    fn recordReturnObligationAs(
        self: *PhantomSemanticChecker,
        rb: []const u8,
        destructure: []const ast.DestructureField,
        step_decl: *const ast.EventDecl,
        step_module: []const u8,
        context: *BindingContext,
    ) anyerror!void {
        if (step_decl.return_phantom) |rp| {
            const ret_home = if (step_decl.return_type) |rt| try self.typeStringModule(rt) else null;
            const canonical_phantom = try self.canonicalizePhantomStateWithBase(rp, step_module, ret_home);
            defer self.allocator.free(canonical_phantom);
            if (step_decl.return_type) |rt| {
                const canonical_base_type = try self.canonicalizeBaseType(rt, null, step_module);
                defer self.allocator.free(canonical_base_type);
                try context.setWithType(rb, canonical_phantom, canonical_base_type);
            } else {
                try context.set(rb, canonical_phantom);
            }
            return;
        }
        // No WHOLE-VALUE phantom does not mean no obligation: a record return
        // (`-> { h: *Handle<owned!>, g: *Handle<owned!> }`) carries its debts
        // per FIELD. The flow head seeds those; without the same seeding here a
        // record producer is tracked only when it happens to be the first call
        // in its chain, and prepending any step — even a void one — loses every
        // field obligation and reports KORU030 against valid code (330_116).
        // Chain position has no bearing on whether a field carries a debt.
        if (step_decl.return_type) |rt| {
            // Same seeding as the head — subflow-implemented producers thread
            // their field obligations across the boundary now that the produce
            // edge verifies them (auto_discharge_inserter's
            // verifyProducedFieldObligations); chain position says nothing
            // about whether a field carries a debt.
            try self.seedRecordFieldObligations(rb, rt, step_module, destructure, context);
        }
    }

    /// Seed the per-field obligations of a record RETURN into `context`, so a
    /// field projection (`s.h`) or destructured field binding (`h`) is a
    /// first-class tracked entity the discharge machinery can credit. This is
    /// the phantom-checker twin of the auto-discharge inserter's
    /// `seedRecordFieldObligations`: without it, `dispose(x: s.h)` looks up an
    /// untracked value and reports the misleading "argument carries no
    /// obligation here" (challenge 007 — field-granular obligation narrowing).
    ///
    /// `binding` is the whole-record bind name (`s`, or the synthetic
    /// `__ret_destr_N` when the head destructures). `destructure`, when
    /// non-empty, names the fields peeled onto their own scalar bindings — each
    /// obligation field it names is keyed by that scalar NAME (`h`), matching
    /// what the user discharges; an obligation field it does NOT name stays
    /// keyed `binding.field` (an unreachable key → a guaranteed leak, exactly
    /// the ordinary "every obligation must be discharged" rule, 330_103).
    fn seedRecordFieldObligations(
        self: *PhantomSemanticChecker,
        binding: []const u8,
        return_type: []const u8,
        module_name: []const u8,
        destructure: []const ast.DestructureField,
        context: *BindingContext,
    ) !void {
        var trimmed = std.mem.trim(u8, return_type, " \t");
        // A bare compound name (`-> Env`) stands for its registered leaf
        // list — the proto IS the record's declared shape. Resolve it so a
        // proto carrying owned `*mod:Type<state!>` leaves seeds per-path
        // debts (`binding.fd`) exactly like an inline record return (699_031).
        var owned_shape: ?[]const u8 = null;
        defer if (owned_shape) |s| self.allocator.free(s);
        if (!(trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}')) {
            var name = trimmed;
            if (std.mem.indexOfScalar(u8, name, '<')) |lt| name = std.mem.trimRight(u8, name[0..lt], " \t");
            for (self.src_asts) |mprog| {
                const prog = mprog orelse continue;
                if (try ast_functional.protoRecordText(self.allocator, prog, name)) |shape| {
                    owned_shape = shape;
                    trimmed = shape;
                    break;
                }
            }
        }
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return;
        const inner = trimmed[1 .. trimmed.len - 1];
        var seg_start: usize = 0;
        var depth: i32 = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            const c = if (at_end) ',' else inner[i];
            switch (c) {
                '<', '{', '[', '(' => depth += 1,
                '>', '}', ']', ')' => depth -= 1,
                else => {},
            }
            if (!(at_end or (c == ',' and depth == 0))) continue;
            const seg = std.mem.trim(u8, inner[seg_start..i], " \t");
            seg_start = i + 1;
            if (seg.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, seg, ':') orelse continue;
            const f_name = std.mem.trim(u8, seg[0..colon], " \t");
            const f_value = std.mem.trim(u8, seg[colon + 1 ..], " \t");
            if (f_name.len == 0) continue;
            const lt = std.mem.indexOfScalar(u8, f_value, '<') orelse continue;
            var ph_depth: usize = 0;
            var close: ?usize = null;
            for (f_value[lt..], lt..) |pc, pj| {
                if (pc == '<') ph_depth += 1 else if (pc == '>') {
                    ph_depth -= 1;
                    if (ph_depth == 0) {
                        close = pj;
                        break;
                    }
                }
            }
            const gt = close orelse continue;
            const phantom_content = std.mem.trim(u8, f_value[lt + 1 .. gt], " \t");
            // `<state>` fields without `!` carry no cleanup debt, but a
            // CLASSED phantom (`name@scoped`) still needs tracking — the
            // class rules (no produce, etc.) are enforced off the binding's
            // phantom text, not the obligation set.
            if (!std.mem.endsWith(u8, phantom_content, "!") and
                std.mem.indexOfScalar(u8, phantom_content, '@') == null) continue;
            const base_type = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{
                std.mem.trim(u8, f_value[0..lt], " \t"),
                f_value[gt + 1 ..],
            });
            defer self.allocator.free(base_type);
            const canonical = try self.canonicalizePhantomStateWithBase(
                phantom_content,
                module_name,
                try self.typeStringModule(base_type),
            );
            defer self.allocator.free(canonical);
            const canonical_base_type = try self.canonicalizeBaseType(base_type, null, module_name);
            defer self.allocator.free(canonical_base_type);

            // Choose the tracking key: a destructured obligation field is keyed by
            // its scalar binding name; otherwise by the `binding.field` projection.
            var named_in_destructure = false;
            if (destructure.len > 0) {
                for (destructure) |df| {
                    if (std.mem.eql(u8, df.name, f_name)) {
                        named_in_destructure = true;
                        break;
                    }
                }
            }
            const key = if (named_in_destructure)
                try self.allocator.dupe(u8, f_name)
            else
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ binding, f_name });
            defer self.allocator.free(key);

            try context.setWithType(key, canonical, canonical_base_type);
        }
    }

    /// A bare-return produce (`-> expr` under a subflow impl, parsed as a
    /// `.branch_constructor` with `is_bare_return`) must feed each declared
    /// `<state!>` field a LIVE obligation of that state — the caller is seeded
    /// `result.<field>` debts on the declared type alone (deadbolt frontier 1).
    /// The inserter's obligation context cannot reliably see a mid-body
    /// consume through its sibling-clone walks, but THIS context's
    /// `disposed_bindings` poisons a consumed feeder on every path, so the
    /// discharge check lives here: a field fed by a discharged or never-owned
    /// binding refuses at the pack rather than crossing as a debt the caller
    /// cannot pay — including the caller's own `dispose(result.field)`.
    fn verifyProduceFieldFeeders(
        self: *PhantomSemanticChecker,
        bc: *const ast.BranchConstructor,
        return_type: []const u8,
        context: *BindingContext,
        location: errors.SourceLocation,
    ) !void {
        const declared = (try ast_functional.recordFieldTexts(self.allocator, return_type)) orelse return;
        defer self.allocator.free(declared);
        for (declared) |df| {
            // Only a cleanup-carrying field (`<state!>`) is a debt to verify;
            // borrow (`<state>`) and plain fields are the shape checker's.
            const lt = std.mem.indexOfScalar(u8, df.value, '<') orelse continue;
            var ph_depth: usize = 0;
            var close: ?usize = null;
            for (df.value[lt..], lt..) |pc, pj| {
                if (pc == '<') ph_depth += 1 else if (pc == '>') {
                    ph_depth -= 1;
                    if (ph_depth == 0) {
                        close = pj;
                        break;
                    }
                }
            }
            const gt = close orelse continue;
            if (!std.mem.endsWith(u8, std.mem.trim(u8, df.value[lt + 1 .. gt], " \t"), "!")) continue;

            // The feeder spelling: a literal field's value, or `<expr>.<field>`
            // for a path produce (`-> r` carries `r.h`-shaped keys).
            var owned_feeder: ?[]u8 = null;
            defer if (owned_feeder) |f| self.allocator.free(f);
            const feeder: ?[]const u8 = if (bc.plain_value) |plain| blk: {
                const t = std.mem.trim(u8, plain, " \t");
                // `-> f(...)` forwards the inner call's declared return —
                // its boundary already guarantees the fields.
                if (std.mem.indexOfScalar(u8, t, '(') != null) return;
                if (try ast_functional.recordFieldTexts(self.allocator, t)) |segs| {
                    defer self.allocator.free(segs);
                    var v: ?[]const u8 = null;
                    for (segs) |seg| {
                        if (std.mem.eql(u8, seg.name, df.name)) {
                            v = seg.value;
                            break;
                        }
                    }
                    break :blk v;
                }
                owned_feeder = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ t, df.name });
                break :blk owned_feeder.?;
            } else blk: {
                var v: ?[]const u8 = null;
                for (bc.fields) |f| {
                    if (std.mem.eql(u8, f.name, df.name)) {
                        v = f.expression_str orelse f.name;
                        break;
                    }
                }
                break :blk v;
            };
            // A missing literal field is the shape checker's find; a call
            // in the value forwards that call's own declared return.
            const v = feeder orelse continue;
            if (std.mem.indexOfScalar(u8, v, '(') != null) continue;
            if (context.isDisposed(v)) {
                try self.reporter.addError(
                    .KORU030,
                    location.line,
                    location.column,
                    "Produced record field '{s}' is fed '{s}', which was already discharged — a produced obligation must still be live at the produce.",
                    .{ df.name, v },
                );
                return error.ValidationFailed;
            }
            if (!context.cleanup_obligations.contains(v)) {
                try self.reporter.addError(
                    .KORU030,
                    location.line,
                    location.column,
                    "Produced record field '{s}' is fed '{s}', which holds no live obligation to hand the caller — it was never acquired or is phantom-less.",
                    .{ df.name, v },
                );
                return error.ValidationFailed;
            }
        }
    }

    /// Report every undischarged obligation still held at a HARD terminal
    /// (`|> _`). The named-branch terminator path performs this inline with
    /// escape analysis for branch constructors; a hard terminal permits no
    /// escape, so the check reduces to: anything uncleaned — outer-scope
    /// obligations excepted — is a KORU030 leak. The message mirrors the
    /// inline path's, listing the discharger(s) so the error points at the
    /// fix. Returns true if any leak was reported.
    fn reportLeaksAtHardTerminal(
        self: *PhantomSemanticChecker,
        context: *BindingContext,
        location: errors.SourceLocation,
    ) !bool {
        // Exit-balance wall: only the post-insertion full pass may judge it —
        // pre-insertion, auto-discharge hasn't placed the disposals yet.
        if (self.check_mode == .args_only) return false;
        if (!context.hasUncleanedResources()) return false;
        const uncleaned = try context.getUncleanedResources(self.allocator);
        defer self.allocator.free(uncleaned);

        var has_errors = false;
        for (uncleaned) |resource| {
            if (context.isOuterScope(resource)) continue;
            // Join-live obligations settle at the join continuation after the
            // enclosing named arm — the arm's leaf is not an exit for them.
            if (context.isJoinLive(resource)) continue;
            const binding_info = context.getInfo(resource) orelse continue;
            const phantom_state = binding_info.phantom_state;

            // `_auto_N` is a name the compiler minted for a value the author
            // discarded; quoting it back asks them to look for something they
            // never wrote. The resource's TYPE is what they DID write.
            const display_name = if (std.mem.indexOf(u8, resource, ".")) |dot_idx|
                resource[dot_idx + 1 ..]
            else if (std.mem.startsWith(u8, resource, "_auto_") and binding_info.base_type.len > 0)
                binding_info.base_type
            else
                resource;
            try self.reportUndischargedObligation(display_name, phantom_state, binding_info.base_type, location);
            has_errors = true;
        }
        return has_errors;
    }

    /// The KORU030 report for one undischarged obligation — no candidates
    /// is a dead end ("No tor accepts <!state>"); a nonempty list is the
    /// `Call:` choice. `phantom_state` may carry a "module:state" prefix.
    fn reportUndischargedObligation(
        self: *PhantomSemanticChecker,
        display_name: []const u8,
        phantom_state: []const u8,
        base_type: []const u8,
        location: errors.SourceLocation,
    ) !void {
        const display_state = if (std.mem.lastIndexOf(u8, phantom_state, ":")) |colon_idx|
            phantom_state[colon_idx + 1 ..]
        else
            phantom_state;

        var disposal_events = try self.findDisposalEventsForState(phantom_state, base_type);
        defer {
            for (disposal_events.items) |item| {
                self.allocator.free(item);
            }
            disposal_events.deinit(self.allocator);
        }

        if (disposal_events.items.len == 0) {
            // The consume spelling takes `!` off the NAME — `scratch!` →
            // `<!scratch>`, `scratch!@scoped` → `<!scratch@scoped>`.
            const state_without_bang = if (std.mem.endsWith(u8, display_state, "!"))
                display_state[0 .. display_state.len - 1]
            else if (std.mem.indexOf(u8, display_state, "!@")) |bang_at|
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ display_state[0..bang_at], display_state[bang_at + 1 ..] })
            else
                display_state;
            defer if (!std.mem.endsWith(u8, display_state, "!") and !std.mem.eql(u8, state_without_bang, display_state)) self.allocator.free(state_without_bang);
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Resource '{s}' carries obligation <{s}> was not discharged. No tor accepts <!{s}>.",
                .{ display_name, display_state, state_without_bang },
            );
        } else {
            // Number agreement: one candidate is an instruction
            // (`Call: finalize`), several are a choice set.
            var options = try std.ArrayList(u8).initCapacity(self.allocator, 0);
            defer options.deinit(self.allocator);
            const n_candidates = try errors.writeCandidateNames([]const u8, ownName, null, "", self.allocator, &options, disposal_events.items);
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Resource '{s}' carries obligation <{s}> was not discharged. Call{s}: {s}",
                .{ display_name, display_state, errors.oneOfInfix(n_candidates), options.items },
            );
        }
    }

    /// Does an unnamed continuation follow index `i` in this sibling list?
    /// Named siblings (`| then`, `| else`) are alternative arms; a later
    /// UNNAMED sibling (`|> ...`) is the join continuation emitted once after
    /// whichever arm ran. Twin of auto_discharge_inserter's joinFollows.
    fn joinFollows(conts: []const ast.Continuation, i: usize) bool {
        var j = i + 1;
        while (j < conts.len) : (j += 1) {
            if (conts[j].branch.len == 0) return true;
        }
        return false;
    }

    /// Validate each nested continuation in order, early-out on the first
    /// failure — an arm followed by a join may not be bare-branchless.
    fn validateNestedContinuations(
        self: *PhantomSemanticChecker,
        cont: *const ast.Continuation,
        event_decl: *const ast.EventDecl,
        event_module: ?[]const u8,
        flow_module: []const u8,
        event_map: *std.StringHashMap(EventInfo),
        location: errors.SourceLocation,
        context: ?*const BindingContext,
        implementing_event: ?*const ast.EventDecl,
    ) anyerror!bool {
        // The arms nested under `cont` fire from cont's own step — when that
        // step is an invocation it is the firing call a `!`-arm custody
        // revive (validateContinuation's .effect block) may consider.
        const nested_firing: ?*const ast.Invocation = if (cont.node) |*step| switch (step.*) {
            .invocation => |*inv| inv,
            .label_with_invocation => |*lwi| &lwi.invocation,
            else => null,
        } else null;
        for (cont.continuations, 0..) |*nested, nested_idx| {
            const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, context, implementing_event, nested.branch.len != 0 and joinFollows(cont.continuations, nested_idx), nested_firing);
            if (!nested_valid) {
                return false;
            }
        }
        return true;
    }

    fn validateContinuation(
        self: *PhantomSemanticChecker,
        cont: *const ast.Continuation,
        event_decl: *const ast.EventDecl,
        event_module: ?[]const u8, // Module where the event is defined (for phantom qualification)
        flow_module: []const u8, // Module where the flow is defined (for name resolution)
        event_map: *std.StringHashMap(EventInfo),
        caller_location: errors.SourceLocation,
        parent_context: ?*const BindingContext, // Optional parent context to inherit from
        implementing_event: ?*const ast.EventDecl, // Event this flow implements (for branch_constructor escape)
        is_join_arm: bool, // This continuation is a named arm followed by a join — obligations inherited at entry are live-through
        firing_inv: ?*const ast.Invocation, // The invocation whose call fired this arm — null when unknown
    ) anyerror!bool {
        var has_errors = false;

        // The arm owns the error: every diagnostic raised for this continuation —
        // branch, step, argument, or exit-balance — names ITS line, not the flow
        // head the caller threaded down (fa026be34's convention: the arm's own
        // location, falling back to the caller's when the parser left line 0).
        const location = if (cont.location.line != 0) cont.location else caller_location;

        // Transform-grafted subtrees are synthesized, not user-authored — and a
        // fused/flattened loop body cannot be linearity-judged (one straight-line
        // pass re-uses iteration bindings, reading as false use-after-discharge).
        // Same short-circuit flow_checker and shape_checker apply; mistakes
        // inside the graft are caught downstream by the Zig backend.
        //
        // But the mark lives on the synthesized NODE, and a transform that
        // bottoms its chain out in the flow's authored continuations
        // (std/store:stored's envwrite chain) leaves user code as a CHILD of
        // a marked node — pruning here deadened every check on the tail: a
        // `stored` write in a `!` arm hid `window.size(win: w)` from the
        // discharge ledger entirely (330_145). Skip the synthesized node,
        // still walk its children — each carries its own mark. Children
        // dispatch against the synthesized node's invoked tor, exactly as
        // the named-branch walk does below; an unresolvable one keeps the
        // old blanket-skip rather than guessing.
        if (cont.is_transformed_subtree) {
            var graft_event: ?struct { decl: *const ast.EventDecl, module: ?[]const u8 } = null;
            const graft_inv: ?*const ast.Invocation = if (cont.node) |*step| switch (step.*) {
                .invocation => |*inv| inv,
                .label_with_invocation => |*lwi| &lwi.invocation,
                else => null,
            } else null;
            if (graft_inv) |inv| {
                const graft_name = try self.pathToString(inv.path);
                defer self.allocator.free(graft_name);
                const graft_module = inv.path.module_qualifier orelse flow_module;
                const graft_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graft_module, graft_name });
                defer self.allocator.free(graft_qualified);
                if (event_map.get(graft_qualified)) |ei| {
                    graft_event = .{ .decl = ei.decl, .module = graft_module };
                }
            }
            if (graft_event) |ge| {
                for (cont.continuations, 0..) |*nested, nested_idx| {
                    const nested_valid = try self.validateContinuation(nested, ge.decl, ge.module, flow_module, event_map, location, parent_context, implementing_event, nested.branch.len != 0 and joinFollows(cont.continuations, nested_idx), graft_inv);
                    if (!nested_valid) has_errors = true;
                }
            }
            return !has_errors;
        }

        log.debug("[PHANTOM-FLOW]   Continuation branch: '{s}'\n", .{cont.branch});

        // Debug: print event path and branches
        const event_path = try self.pathToString(event_decl.path);
        defer self.allocator.free(event_path);
        log.debug("[PHANTOM-FLOW]   Event has path: '{s}', {} branches:\n", .{ event_path, event_decl.branches.len });
        for (event_decl.branches) |branch| {
            log.debug("[PHANTOM-FLOW]     - '{s}'\n", .{branch.name});
        }

        // Void events (0 branches) have implicit continuations - skip branch validation
        // The continuation just chains to the next event after the void event completes
        if (event_decl.branches.len == 0) {
            log.debug("[PHANTOM-FLOW]   (void event - skipping branch validation)\n", .{});
            // Create binding context for void event continuation
            var void_context = if (parent_context) |parent|
                try BindingContext.inherit(parent, self.allocator)
            else
                BindingContext.init(self.allocator);
            defer void_context.deinit();

            // A named arm followed by a join continuation keeps its inherited
            // obligations live past the arm's leaf — they settle at the join.
            if (is_join_arm) try void_context.markInheritedJoinLive();

            // A NAMED LABEL with a binding on a bare-return callee
            // (`create(...) | made c |> ...`) is binding sugar for `: c` — the
            // emitter lowers both to the same direct bind. Credit the label's
            // binding with the callee's return obligation, exactly as the
            // `: name` head bind (validateEventFlow) and the mid-chain bind
            // (recordBareReturnBind) do, so a downstream discharge through the
            // label's name is seen and an undischarged one is reported against
            // the name the author wrote.
            if (cont.branch.len > 0) {
                if (cont.binding) |cb| {
                    if (!std.mem.eql(u8, cb, "_")) {
                        const callee_module = event_module orelse flow_module;
                        try self.recordReturnObligationAs(cb, cont.destructure, event_decl, callee_module, &void_context);
                    }
                }
            }

            // Still validate the step if present
            if (cont.node) |*step| {
                // A `#label` decl on a void chain is the same declaration the
                // branch path registers — without this the label never reaches
                // `label_map` and a later `@label` jump skips
                // `validateLabelArgNames` entirely (`~start() |> #loop ...`
                // then `| next c |> @loop(badname: c)` died in backend Zig).
                if (!try self.registerContinuationLabel(step, flow_module, event_map, location)) {
                    return false;
                }
                const step_valid = try self.validateStep(step, &void_context, event_map, flow_module, location);
                if (!step_valid) {
                    return false;
                }

                // If step is an invocation, nested continuations belong to THAT event, not the void parent.
                // A `#loop event(...)` label declaration is the same: its arms
                // (`| again`/`| stop`, `| more`/`| fin`) are branches of the
                // LABEL's invoked event, not the void head. Resolve through its
                // inner invocation so the arms validate against the real event
                // (e.g. `icount`) and pick up their `@scope` outer-scope marking
                // — without this they fall to the fallback below, validate against
                // the 0-branch void head, re-enter THIS void path, and the
                // back-edge `@loop` drop-check never sees a carried obligation as
                // outer-scope (spurious KORU030 for a held obligation that escapes
                // after the loop, e.g. 330_085). The named-branch head takes the
                // equivalent path via validateContinuation's nested-step handling.
                const step_inv: ?*const ast.Invocation = switch (step.*) {
                    .invocation => |*inv| inv,
                    .label_with_invocation => |*lwi| if (lwi.is_declaration) &lwi.invocation else null,
                    else => null,
                };
                if (step_inv) |inv| {
                    const step_event_name = try self.pathToString(inv.path);
                    defer self.allocator.free(step_event_name);
                    const step_module = inv.path.module_qualifier orelse flow_module;
                    const step_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ step_module, step_event_name });
                    defer self.allocator.free(step_qualified);

                    if (event_map.get(step_qualified)) |step_event_info| {
                        // Record this step's bare-return bind so a chained
                        // consumer (`make(): h |> t1(h): a |> fin(h: a)`) sees `a`'s
                        // obligation — the intermediate-step twin of the flow-head bind.
                        try self.recordBareReturnBind(inv, step_event_info.decl, step_module, &void_context);
                        // Validate nested continuations against the step's event
                        if (!try self.validateNestedContinuations(cont, step_event_info.decl, step_module, flow_module, event_map, location, &void_context, implementing_event)) {
                            return false;
                        }
                        // END OF CHAIN = A FLOW EXIT. With no nested continuation
                        // there is nothing further to discharge into, so this is a
                        // real exit and must balance — the same rule the hard
                        // terminal (`|> _`) below already enforces. Without this,
                        // a top-level bare-return chain (`light(): lamp |> log(x)`)
                        // returned true holding an undischarged obligation: the
                        // `.terminal` guard below is UNSATISFIABLE here, because
                        // KORU010 permits `_` only as a branch-handler body. That
                        // is the whole reason the `| branch lamp` spelling enforced
                        // and the `: lamp` spelling did not (330_113/114 vs the
                        // 330_115 control).
                        if (cont.continuations.len == 0) {
                            if (try self.reportLeaksAtHardTerminal(&void_context, location)) {
                                return false;
                            }
                        }
                        return true;
                    }
                }
            }
            // Flow exit on a HARD terminal (`|> _`) after a bare-return
            // (0-branch) head/step: run the same undischarged-obligation check
            // the named-branch terminator path performs below (its
            // is_terminator block). This void-event path used to return true
            // without ever balance-checking, so a leak held at the exit of a
            // bare-return chain was silently accepted whenever insertion was
            // opted out (--auto-discharge=disable / ~[strict] — 330_025,
            // 330_070): the enforcement side must see every flow exit the
            // insertion side sees (the 400_137 rule, one path further in).
            // A hard terminal permits no documented escape, so the check is
            // exactly: anything uncleaned — outer-scope excepted — is KORU030.
            if (cont.node) |exit_node| {
                if (exit_node == .terminal) {
                    if (try self.reportLeaksAtHardTerminal(&void_context, location)) {
                        return false;
                    }
                }
                // A `-> expr` produce under a void-produce chain exits here, not
                // through the is_terminator block below — the same
                // live-obligation-into-`<state!>`-field rule applies (deadbolt
                // frontier 1: `dispose(h) -> { h }` must refuse at the pack).
                if (exit_node == .branch_constructor) {
                    const exit_bc = &exit_node.branch_constructor;
                    if (self.check_mode == .full) {
                        if (try self.refuseScopedProduce(exit_bc, &void_context, location, implementing_event)) {
                            return false;
                        }
                    }
                    if (exit_bc.is_bare_return) {
                        if (implementing_event) |impl_ev| {
                            if (impl_ev.return_type) |rt| {
                                if (self.check_mode == .full) try self.verifyProduceFieldFeeders(exit_bc, rt, &void_context, location);
                            }
                        }
                    }
                }
            }

            // Validate nested continuations recursively (fallback: against void event)
            return self.validateNestedContinuations(cont, event_decl, event_module, flow_module, event_map, location, &void_context, implementing_event);
        }

        // Residual continuations (|*) don't reference a specific branch
        // They handle all unhandled branches, so skip branch validation
        if (cont.is_catchall) {
            log.debug("[PHANTOM-FLOW]   (catch-all continuation - skipping branch validation)\n", .{});
            // Still validate nested continuations if present
            return self.validateNestedContinuations(cont, event_decl, event_module, flow_module, event_map, location, null, implementing_event);
        }

        // Empty-branch continuations (|> ...) are void chain continuations
        // They don't reference a branch - they chain after a void event in the pipeline
        // NOTE: This is different from void EVENTS (0 branches) - this handles the continuation SYNTAX
        if (cont.branch.len == 0) {
            log.debug("[PHANTOM-FLOW]   (empty-branch void chain continuation - handling step/nested)\n", .{});
            // Create binding context for void chain continuation
            var void_chain_context = if (parent_context) |parent|
                try BindingContext.inherit(parent, self.allocator)
            else
                BindingContext.init(self.allocator);
            defer void_chain_context.deinit();

            // Validate the step if present
            if (cont.node) |*step| {
                if (!try self.registerContinuationLabel(step, flow_module, event_map, location)) {
                    return false;
                }
                const step_valid = try self.validateStep(step, &void_chain_context, event_map, flow_module, location);
                if (!step_valid) {
                    return false;
                }

                // If step is an invocation, nested continuations belong to THAT event
                switch (step.*) {
                    .invocation => |*inv| {
                        const step_event_name = try self.pathToString(inv.path);
                        defer self.allocator.free(step_event_name);
                        const step_module = inv.path.module_qualifier orelse flow_module;
                        const step_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ step_module, step_event_name });
                        defer self.allocator.free(step_qualified);

                        if (event_map.get(step_qualified)) |step_event_info| {
                            // Record this step's bare-return bind so a chained
                            // consumer sees its obligation (intermediate-step twin
                            // of the flow-head bind).
                            try self.recordBareReturnBind(inv, step_event_info.decl, step_module, &void_chain_context);
                            // Validate nested continuations against the step's event
                            return self.validateNestedContinuations(cont, step_event_info.decl, step_module, flow_module, event_map, location, &void_chain_context, implementing_event);
                        }
                    },
                    .inline_code => {
                        // inline_code is a void step (e.g., from print.ln transform)
                        // Nested continuations should still be validated against the PARENT event
                        // (not as a void chain) because they might be branch handlers for a previous invocation
                        // For example: |> work() |> print.ln("...") | done |> ...
                        // The | done |> is a branch of work(), not a void chain
                        return self.validateNestedContinuations(cont, event_decl, event_module, flow_module, event_map, location, &void_chain_context, implementing_event);
                    },
                    else => {},
                }
            }

            // Fallback: validate nested continuations (no step or unrecognized step)
            return self.validateNestedContinuations(cont, event_decl, event_module, flow_module, event_map, location, &void_chain_context, implementing_event);
        }

        // Find the branch in the event declaration: exact name first, then a
        // declared raw-name CLASS branch (literally named `*`, spelled
        // `| \`*\` *` in the decl) catches any remaining name — the contract
        // form of transform events like std/regex:match, where the handled
        // name is data (a pattern), not an identifier. Mirrors
        // branch_checker.resolveDeclared.
        var branch_payload: ?*const ast.Shape = null;
        var branch_decl: ?*const ast.Branch = null;
        for (event_decl.branches) |*branch| {
            if (std.mem.eql(u8, branch.name, cont.branch)) {
                branch_payload = &branch.payload;
                branch_decl = branch;
                break;
            }
        }
        if (branch_decl == null) {
            for (event_decl.branches) |*branch| {
                if (std.mem.eql(u8, branch.name, "*")) {
                    branch_payload = &branch.payload;
                    branch_decl = branch;
                    break;
                }
            }
        }

        // KORU025 (marker/kind): the call-site marker must match the branch's
        // declared KIND — `!` handles an effect arm the invocation FIRES, `|`
        // matches an outcome branch it RETURNS. This site is where transform-
        // generated events (store `take`/`query` → `__store_take_<s>`) first
        // expose their branch kinds; the shape checker's KORU025 runs pre-
        // transform and never sees them, so `! item` on take's `| item` outcome
        // was silently miscompiled into a leak (400_171/172). Single-sourced
        // through errors.branchKindMismatch so local and store events read the
        // same. Catch-alls and the raw-name `*` class already resolved above.
        if (branch_decl) |decl| {
            if (decl.kind != cont.kind) {
                try errors.branchKindMismatch(
                    self.reporter,
                    cont.location,
                    cont.branch,
                    if (decl.kind == .effect) .effect else .terminal,
                    if (cont.kind == .effect) .effect else .terminal,
                );
                return false;
            }
        }

        if (branch_payload == null) {
            // ~[prototype]: an undeclared TERMINAL arm is the "handle a branch the
            // event doesn't produce yet" doodle (400_165). It can never fire (the
            // event never produces it), so there are no phantom/obligation
            // semantics to validate — let it slide instead of KORU030. Undeclared
            // EFFECT arms stay errors (parity with the terminal-only relaxation).
            if (self.prototype_mode and cont.kind != .effect) return true;

            // Unknown branch - this is an error!

            // Build list of available branches for error message
            var branch_list = std.ArrayList(u8){};
            defer branch_list.deinit(self.allocator);
            const writer = branch_list.writer(self.allocator);

            for (event_decl.branches, 0..) |branch, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("'{s}'", .{branch.name});
            }

            try self.reporter.addError(.KORU030, // Shape mismatch
                location.line, location.column, "Continuation expects branch '{s}' but event '{s}' only produces: {s}", .{ cont.branch, event_path, branch_list.items });
            return false;
        }

        // Check for the @scope mark on the binding (e.g., | each _ |>, stamped
        // by a pass — surface syntax cannot spell marks).
        // ALSO treat an effect branch (`! line`, `! each`) as a scope boundary: it
        // lowers to a host loop firing 0..N times, so an OUTER obligation must not
        // be required to discharge INSIDE the effect body (that would be a
        // per-iteration double-free) — it discharges after the loop (done/failed).
        // This is the checker-side twin of the auto-discharge inserter's
        // kind==.effect scope entry; the @scope mark was previously the only
        // recognized loop boundary, leaving stdlib effects invisible to both passes.
        const has_scope = blk: {
            if (cont.kind == .effect) break :blk true;
            for (cont.binding_marks) |mark| {
                if (std.mem.eql(u8, mark, "@scope")) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        // Build binding context - inherit from parent if provided
        // If @scope, mark inherited obligations as outer-scope
        var context = if (parent_context) |parent|
            if (has_scope)
                try BindingContext.inheritWithScope(parent, self.allocator)
            else
                try BindingContext.inherit(parent, self.allocator)
        else
            BindingContext.init(self.allocator);
        defer context.deinit();

        // A named arm followed by a join continuation keeps its inherited
        // obligations live past the arm's leaf — they settle at the join.
        // (Checker-side twin of the inserter's join_watermark.)
        if (is_join_arm) try context.markInheritedJoinLive();

        // A `!` arm runs INSIDE the callee's loop body. A binding the firing
        // call consumed through `<!state>` params is the loop's live value
        // for the arm's duration — `frames(win: w)` takes `<!opened|!active>`
        // and during `! frame` the window really is opened|active, which is
        // why borrows like `window.size` declare exactly those states. The
        // disposed mark the call left is right for code AFTER the call and
        // wrong inside its own `!` arms: revive the binding here as live
        // with the consumed states minus the `!` — the obligations moved to
        // the loop's custody and `| done`-style arms re-issue them when it
        // returns. Without this, an ambient use inside a `!` arm was
        // refused outright (or silently passed under a transform graft —
        // the marked-node descent above is what used to hide it): 330_145.
        if (cont.kind == .effect) {
            // Custody is identified by the firing call's own argument nodes:
            // the disposal site's `/<arg-ptr>` suffix is the arg's value-string
            // pointer, so only a discharge THIS invocation performed revives —
            // a binding a prior call discharged stays dead inside the arm.
            if (firing_inv) |finv| {
                for (finv.args, 0..) |arg, arg_idx| {
                    const site = context.disposalSite(arg.value) orelse continue;
                    const site_suffix = try std.fmt.allocPrint(self.allocator, "/{x}", .{@intFromPtr(arg.value.ptr)});
                    defer self.allocator.free(site_suffix);
                    if (!std.mem.endsWith(u8, site, site_suffix)) continue;

                    // Only `<!state>`-consuming params hand custody to the loop;
                    // a borrow or produce param discharges nothing inside it.
                    // Positional args resolve to their field by position.
                    var live_phantom: ?[]const u8 = null;
                    for (event_decl.input.fields, 0..) |field, field_idx| {
                        const matches = if (arg.name.len != 0)
                            std.mem.eql(u8, field.name, arg.name)
                        else
                            field_idx == arg_idx;
                        if (!matches) continue;
                        const param_phantom = field.phantom orelse break;
                        if (std.mem.indexOfScalar(u8, param_phantom, '!') == null) break;
                        const live_text = try self.allocator.alloc(u8, param_phantom.len);
                        defer self.allocator.free(live_text);
                        var li: usize = 0;
                        for (param_phantom) |pc| {
                            if (pc != '!') {
                                live_text[li] = pc;
                                li += 1;
                            }
                        }
                        const module_for_canon = event_module orelse event_decl.module;
                        live_phantom = try self.canonicalizePhantomStateWithBase(
                            live_text[0..li],
                            module_for_canon,
                            try self.baseTypeModule(field.module_path),
                        );
                        break;
                    }

                    if (live_phantom) |lp| {
                        defer self.allocator.free(lp);
                        // setWithType removes the old entry — and frees the old
                        // base_type — before it dupes; a slice of that old entry
                        // passed straight in aliases freed memory.
                        const live_base = try self.allocator.dupe(u8, context.getBaseType(arg.value) orelse "");
                        defer self.allocator.free(live_base);
                        try context.setWithType(arg.value, lp, live_base);
                        if (context.disposed_bindings.fetchRemove(arg.value)) |kv| {
                            self.allocator.free(kv.key);
                            self.allocator.free(kv.value);
                        }
                    }
                }
            }
        }

        // Add binding with phantom states from branch payload
        // If there's no explicit binding, synthesize "_" to track the obligation
        const binding_name = cont.binding orelse "_";
        {
            for (branch_payload.?.fields) |field| {
                // A destructure arm (`| compressed { data }`) peels the
                // payload's fields onto scalar bindings — the obligation
                // rides the LOCAL name the author wrote (`data`), never
                // `_.data`: without the remap the scalar is a plain binding,
                // `io:free(data)` sees "no live obligation" (KORU030), and
                // the real debt sits under the discard name where the exit
                // check cannot see it — the runtime leak counter was the
                // only thing that ever caught it. Fields the destructure
                // does not peel keep `binding.field` (an unreachable key —
                // the ordinary guaranteed-leak rule).
                const destructured_path = blk: {
                    if (cont.destructure.len > 0) {
                        for (cont.destructure) |df| {
                            if (std.mem.indexOfScalar(u8, df.path, '.') == null and
                                std.mem.eql(u8, df.path, field.name) and
                                !std.mem.eql(u8, df.name, "_"))
                            {
                                break :blk try self.allocator.dupe(u8, df.name);
                            }
                        }
                    }
                    break :blk null;
                };
                const is_identity = std.mem.eql(u8, field.name, "__type_ref");
                const field_path = destructured_path orelse if (is_identity)
                    try self.allocator.dupe(u8, binding_name)
                else
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ binding_name, field.name });
                defer self.allocator.free(field_path);
                if (field.phantom) |phantom_str| {

                    // Canonicalize phantom state using event's qualified module name
                    const module_for_canon = event_module orelse event_decl.module;
                    const canonical_phantom = try self.canonicalizePhantomStateWithBase(
                        phantom_str,
                        module_for_canon,
                        try self.baseTypeModule(field.module_path),
                    );
                    defer self.allocator.free(canonical_phantom);

                    // Canonicalize base type using field's module_path or defining module
                    const canonical_base_type = try self.canonicalizeBaseType(
                        field.type,
                        field.module_path,
                        module_for_canon,
                    );
                    defer self.allocator.free(canonical_base_type);

                    // Store both phantom state AND base type (both canonicalized)
                    try context.setWithType(field_path, canonical_phantom, canonical_base_type);
                } else if (field.type.len > 0 and !std.mem.eql(u8, field.type, "\x00")) {
                    // Phantom-less payload — record the base type on the
                    // separate base_types table (registry rung 1) so the
                    // nominal-distinctness check (validateArgument's no-phantom
                    // gate) can compare it against the expected param. The
                    // field_path is the hoisted destructure/binding key the
                    // phantom branch just spelled.
                    const module_for_canon = event_module orelse event_decl.module;
                    const canonical_base_type = try self.canonicalizeBaseType(
                        field.type,
                        field.module_path,
                        module_for_canon,
                    );
                    defer self.allocator.free(canonical_base_type);
                    try context.setBaseType(field_path, canonical_base_type);
                }
            }
        }

        // Add branch-level phantoms (context state)
        if (branch_decl) |bd| {
            log.debug("[PHANTOM-FLOW]   Branch '{s}' has {} annotations\n", .{ bd.name, bd.annotations.len });
            for (bd.annotations, 0..) |ann, i| {
                log.debug("[PHANTOM-FLOW]     Branch Annotation[{}]: '{s}' (isPhantom={})\n", .{ i, ann, isPhantomAnnotation(ann) });
                if (isPhantomAnnotation(ann)) {
                    const module_for_canon = event_module orelse event_decl.module;
                    const canonical = try self.canonicalizePhantomState(ann, module_for_canon);
                    defer self.allocator.free(canonical);
                    log.debug("[PHANTOM-FLOW]     Storing context phantom for branch '{s}': '{s}' (canonical: '{s}')\n", .{ bd.name, ann, canonical });
                    try context.set("", canonical);
                }
            }
        }

        const step_count: usize = if (cont.node != null) 1 else 0;
        log.debug("[PHANTOM-FLOW]   Pipeline has {} steps\n", .{step_count});
        // Debug: print what's in the pipeline
        if (cont.node) |step| {
            log.debug("[PHANTOM-FLOW]     Step 0: {s}\n", .{@tagName(step)});
        }
        // Validate pipeline steps with this context
        // Use flow_module for name resolution (where the flow is defined)
        if (cont.node) |*step| {
            // If this is a label declaration, record it
            if (!try self.registerContinuationLabel(step, flow_module, event_map, location)) {
                has_errors = true;
            }

            const step_valid = try self.validateStep(step, &context, event_map, flow_module, location);
            if (!step_valid) {
                has_errors = true;
                // Continue checking for more errors
            }
        }

        // Check for terminator: pipeline contains a 'terminal' step, 'branch_constructor' step,
        // OR (empty pipeline AND no nested continuations)
        // Branch constructors are ALSO flow terminators - they end the flow and return a value.
        var is_terminator = cont.node == null and cont.continuations.len == 0;
        if (cont.node) |step| {
            if (step == .terminal or step == .branch_constructor) {
                is_terminator = true;
            } else if (step == .invocation and cont.continuations.len == 0) {
                // Implicit exit: a pipeline ending on an invocation with no
                // nested continuations leaves the flow here. The insertion
                // side has always treated this as an implicit terminator
                // (auto_discharge_inserter, "treat as implicit terminator");
                // without the same rule on the ENFORCEMENT side, an
                // obligation born in an effect-handler pipeline
                // (`! each i |> std/field:new | field f |> print.ln(...)`)
                // was never balance-checked, so --auto-discharge=disable and
                // ~[strict] silently accepted the leak (400_137).
                is_terminator = true;
            }
        }
        if (is_terminator and self.check_mode == .full) {
            // Exit-balance wall: gated to the post-insertion full pass — the
            // args-only pre-pass would read every not-yet-inserted disposal
            // as a leak.
            const terminator_type = if (cont.node) |n| @tagName(n) else "empty";
            log.debug("[CLEANUP] Terminator detected ({s}), checking for uncleaned resources\n", .{terminator_type});

            // A bare-return produce must hand a live obligation into every
            // declared `<state!>` field — independent of whether anything is
            // left uncleaned (a consumed feeder leaves NOTHING to leak).
            if (cont.node) |node| {
                if (node == .branch_constructor) {
                    const bc = &node.branch_constructor;
                    // A `@scoped` value may occupy output position only where
                    // the declared output itself carries `scoped` — bare
                    // `->`, `=>` payload fields, record-literal produce.
                    if (try self.refuseScopedProduce(bc, &context, location, implementing_event)) {
                        has_errors = true;
                    }
                    if (bc.is_bare_return) {
                        if (implementing_event) |impl_ev| {
                            if (impl_ev.return_type) |rt| {
                                try self.verifyProduceFieldFeeders(bc, rt, &context, location);
                            }
                        }
                    }
                }
            }

            if (context.hasUncleanedResources()) {
                const uncleaned = try context.getUncleanedResources(self.allocator);
                defer self.allocator.free(uncleaned);

                log.debug("[CLEANUP] Uncleaned resources found: {}\n", .{uncleaned.len});
                for (uncleaned) |resource| {
                    log.debug("[CLEANUP]   - '{s}'\n", .{resource});
                }

                // Determine what fields to check for documented escape.
                // - For terminal (_): NO escape allowed
                // - For branch_constructor: Check the IMPLEMENTING event's branch signature
                // - For other terminators: Fall back to incoming branch_payload
                const is_hard_terminal = if (cont.node) |node| node == .terminal else false;
                const is_branch_constructor = if (cont.node) |node| node == .branch_constructor else false;

                // For branch_constructor, find the return branch's fields from the implementing event
                var return_branch_fields: ?[]const ast.Field = null;
                if (is_branch_constructor) {
                    if (cont.node) |node| {
                        const bc = &node.branch_constructor;
                        log.debug("[CLEANUP] Branch constructor returns '{s}'\n", .{bc.branch_name});

                        if (implementing_event) |impl_ev| {
                            // Find the branch in the implementing event's declaration
                            for (impl_ev.branches) |branch| {
                                if (std.mem.eql(u8, branch.name, bc.branch_name)) {
                                    return_branch_fields = branch.payload.fields;
                                    log.debug("[CLEANUP]   Found return branch '{s}' with {} fields\n", .{ bc.branch_name, branch.payload.fields.len });
                                    break;
                                }
                            }
                            if (return_branch_fields == null) {
                                log.debug("[CLEANUP]   WARNING: Branch '{s}' not found in implementing event\n", .{bc.branch_name});
                            }
                        } else {
                            log.debug("[CLEANUP]   No implementing_event - cannot check return signature\n", .{});
                        }
                    }
                }

                var lost_count: usize = 0;
                var first_lost: ?[]const u8 = null;
                var scoped_reported = std.StringHashMap(void).init(self.allocator);
                defer {
                    var it = scoped_reported.keyIterator();
                    while (it.next()) |key| self.allocator.free(key.*);
                    scoped_reported.deinit();
                }

                for (uncleaned) |resource| {
                    // Outer-scope obligations are the outer scope's responsibility -
                    // skip them regardless of whether THIS continuation is the @scope
                    // boundary itself or a deeper nested cont inside the boundary.
                    if (context.isOuterScope(resource)) {
                        continue;
                    }
                    // Join-live obligations settle at the join continuation
                    // after the enclosing named arm — the arm's leaf is not
                    // an exit for them.
                    if (context.isJoinLive(resource)) {
                        continue;
                    }
                    // `<name@scoped>` debts have NO legal end at a terminator:
                    // the class means the value may not occupy output
                    // position, so any scoped obligation still live here —
                    // produced out or left to die — is the violation itself.
                    if (try self.bindingHasScopedClass(&context, resource)) {
                        const display_name = if (std.mem.indexOf(u8, resource, ".")) |dot_idx|
                            resource[dot_idx + 1 ..]
                        else
                            resource;
                        try self.reporter.addError(
                            .KORU030,
                            location.line,
                            location.column,
                            "obligation '{s}' is @scoped — it dies with this frame and may not be produced out. Consume it in place, or copy it out first (std/string:from-page + take / fmt.blk)",
                            .{display_name},
                        );
                        has_errors = true;
                        try scoped_reported.put(try self.allocator.dupe(u8, resource), {});
                        continue;
                    }

                    // For hard terminals (_), all uncleaned resources are errors
                    var documented_escape = false;

                    // Only check for escape through signature if NOT a hard terminal
                    if (!is_hard_terminal) {
                        // For branch_constructor, check if the VALUE being passed matches the resource
                        if (is_branch_constructor) {
                            if (cont.node) |node| {
                                const bc = &node.branch_constructor;
                                // Identity branch constructors use plain_value instead of fields
                                if (bc.plain_value) |plain| {
                                    if (std.mem.eql(u8, plain, resource)) {
                                        if (return_branch_fields) |sig_fields| {
                                            for (sig_fields) |sig_field| {
                                                if (sig_field.phantom) |phantom_str| {
                                                    if (try self.phantomRequiresCleanup(phantom_str)) {
                                                        documented_escape = true;
                                                        log.debug("[CLEANUP]   '{s}' escapes through identity branch constructor with [!]\n", .{resource});
                                                    }
                                                }
                                                break;
                                            }
                                        }
                                    } else if (std.mem.startsWith(u8, resource, plain) and resource.len > plain.len and resource[plain.len] == '.') {
                                        // `-> r` pass-through: the produced record's `r.<field>`
                                        // keys escape through the impl's declared `<state!>`
                                        // return-record fields (return_branch_fields is only
                                        // populated from impl branches — a `->` record return
                                        // has none, so the field list is parsed off the type).
                                        if (implementing_event) |impl_ev| {
                                            if (impl_ev.return_type) |rt| {
                                                if (try ast_functional.recordFieldTexts(self.allocator, rt)) |declared| {
                                                    defer self.allocator.free(declared);
                                                    const fname = resource[plain.len + 1 ..];
                                                    for (declared) |df| {
                                                        if (!std.mem.eql(u8, df.name, fname)) continue;
                                                        if (std.mem.indexOfScalar(u8, df.value, '<') != null and std.mem.indexOfScalar(u8, df.value, '!') != null) {
                                                            documented_escape = true;
                                                            log.debug("[CLEANUP]   '{s}' escapes through `-> {s}` field '{s}' with [!]\n", .{ resource, plain, df.name });
                                                        }
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    } else if (try ast_functional.recordFieldTexts(self.allocator, plain)) |produced| {
                                        // `-> { h, n: 7 }` / `-> { e.h, e.n }`: the plain_value
                                        // is itself a record literal — a resource named by a
                                        // field VALUE escapes through the declared `<state!>`
                                        // field it packs into, the escape-side mirror of
                                        // verifyProduceFieldFeeders for this same shape.
                                        defer self.allocator.free(produced);
                                        if (implementing_event) |impl_ev| {
                                            if (impl_ev.return_type) |rt| {
                                                if (try ast_functional.recordFieldTexts(self.allocator, rt)) |declared| {
                                                    defer self.allocator.free(declared);
                                                    for (produced) |seg| {
                                                        if (!std.mem.eql(u8, seg.value, resource)) continue;
                                                        for (declared) |df| {
                                                            if (!std.mem.eql(u8, df.name, seg.name)) continue;
                                                            if (std.mem.indexOfScalar(u8, df.value, '<') != null and std.mem.indexOfScalar(u8, df.value, '!') != null) {
                                                                documented_escape = true;
                                                                log.debug("[CLEANUP]   '{s}' escapes through `-> record literal` field '{s}' with [!]\n", .{ resource, df.name });
                                                            }
                                                            break;
                                                        }
                                                        if (documented_escape) break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } else {
                                    // Check each field in the constructor
                                    for (bc.fields) |bc_field| {
                                        // Check if this field's value matches the uncleaned resource
                                        if (bc_field.expression_str) |expr_str| {
                                            if (std.mem.eql(u8, expr_str, resource)) {
                                                // Found the resource being passed - check if output has [!]
                                                if (return_branch_fields) |sig_fields| {
                                                    for (sig_fields) |sig_field| {
                                                        if (std.mem.eql(u8, sig_field.name, bc_field.name)) {
                                                            if (sig_field.phantom) |phantom_str| {
                                                                if (try self.phantomRequiresCleanup(phantom_str)) {
                                                                    documented_escape = true;
                                                                    log.debug("[CLEANUP]   '{s}' escapes through branch constructor field '{s}' with [!]\n", .{ resource, bc_field.name });
                                                                }
                                                            }
                                                            break;
                                                        }
                                                    }
                                                }
                                                if (documented_escape) break;
                                            }
                                        }
                                    }
                                }
                            }
                        } else if (cont.node != null and cont.node.? == .expression) {
                            // A bare-return produce (`-> expr`) under a subflow
                            // impl hands each declared `<state!>` field's
                            // obligation to the caller — the inserter verifies
                            // the fields are actually fed live obligations at
                            // the pack, so a resource routed into a cleanup-
                            // carrying field escapes by name.
                            if (implementing_event) |impl_ev| {
                                if (impl_ev.return_type) |rt| {
                                    if (cont.node) |node| {
                                        const expr = std.mem.trim(u8, node.expression, " \t");
                                        if (std.mem.indexOfScalar(u8, expr, '(') == null) {
                                            if (try ast_functional.recordFieldTexts(self.allocator, expr)) |produced| {
                                                defer self.allocator.free(produced);
                                                if (try ast_functional.recordFieldTexts(self.allocator, rt)) |declared| {
                                                    defer self.allocator.free(declared);
                                                    for (produced) |seg| {
                                                        if (!std.mem.eql(u8, seg.value, resource)) continue;
                                                        for (declared) |df| {
                                                            if (!std.mem.eql(u8, df.name, seg.name)) continue;
                                                            if (std.mem.indexOfScalar(u8, df.value, '<') != null and std.mem.indexOfScalar(u8, df.value, '!') != null) {
                                                                documented_escape = true;
                                                            }
                                                            break;
                                                        }
                                                    }
                                                }
                                            } else {
                                                // `-> r` pass-through: the record's `r.<field>` keys escape
                                                // through the declared cleanup fields.
                                                if (try ast_functional.recordFieldTexts(self.allocator, rt)) |declared| {
                                                    defer self.allocator.free(declared);
                                                    for (declared) |df| {
                                                        if (std.mem.indexOfScalar(u8, df.value, '<') == null or std.mem.indexOfScalar(u8, df.value, '!') == null) continue;
                                                        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ expr, df.name });
                                                        defer self.allocator.free(key);
                                                        if (std.mem.eql(u8, key, resource)) {
                                                            documented_escape = true;
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // Non-branch-constructor case: use the old field name matching
                            const fields_to_check = if (branch_payload) |bp| bp.fields else null;
                            if (fields_to_check) |fields| {
                                for (fields) |field| {
                                    if (field.phantom) |phantom_str| {
                                        if (try self.phantomRequiresCleanup(phantom_str)) {
                                            if (std.mem.lastIndexOf(u8, resource, ".")) |dot_idx| {
                                                const resource_field = resource[dot_idx + 1 ..];
                                                if (std.mem.eql(u8, resource_field, field.name)) {
                                                    documented_escape = true;
                                                    log.debug("[CLEANUP]   '{s}' escapes through signature field '{s}' with [!]\n", .{ resource, field.name });
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (!documented_escape) {
                        log.debug("[CLEANUP]   '{s}' NOT in signature - obligation lost\n", .{resource});
                        if (first_lost == null) {
                            first_lost = resource;
                        }
                        lost_count += 1;
                    }
                }

                // Only error if there are truly lost obligations (not documented in signature)
                if (lost_count > 0) {
                    log.debug("[CLEANUP] Lost obligations: {} - auto_discharge_inserter should have handled this\n", .{lost_count});

                    // Report error for each lost obligation
                    // (This is a safety net - inserter should have handled or errored)

                    // Use the same fields we used for detection
                    const fields_for_error = return_branch_fields orelse (if (branch_payload) |bp| bp.fields else null);

                    for (uncleaned) |resource| {
                        // A refused @scoped produce was reported already.
                        if (scoped_reported.contains(resource)) continue;

                        // Skip if it escapes through signature
                        var escapes = false;

                        // For hard terminals, nothing escapes
                        if (!is_hard_terminal) {
                            // For branch_constructor, check VALUE match (same as detection above)
                            if (is_branch_constructor) {
                                if (cont.node) |node| {
                                    const bc = &node.branch_constructor;
                                    // Identity branch constructors use plain_value
                                    if (bc.plain_value) |plain| {
                                        if (std.mem.eql(u8, plain, resource)) {
                                            if (return_branch_fields) |sig_fields| {
                                                for (sig_fields) |sig_field| {
                                                    if (sig_field.phantom) |phantom_str| {
                                                        if (try self.phantomRequiresCleanup(phantom_str)) {
                                                            escapes = true;
                                                        }
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    } else {
                                        for (bc.fields) |bc_field| {
                                            if (bc_field.expression_str) |expr_str| {
                                                if (std.mem.eql(u8, expr_str, resource)) {
                                                    if (return_branch_fields) |sig_fields| {
                                                        for (sig_fields) |sig_field| {
                                                            if (std.mem.eql(u8, sig_field.name, bc_field.name)) {
                                                                if (sig_field.phantom) |phantom_str| {
                                                                    if (try self.phantomRequiresCleanup(phantom_str)) {
                                                                        escapes = true;
                                                                    }
                                                                }
                                                                break;
                                                            }
                                                        }
                                                    }
                                                    if (escapes) break;
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                if (fields_for_error) |fields| {
                                    for (fields) |field| {
                                        if (field.phantom) |phantom_str| {
                                            if (try self.phantomRequiresCleanup(phantom_str)) {
                                                if (std.mem.lastIndexOf(u8, resource, ".")) |dot_idx| {
                                                    if (std.mem.eql(u8, resource[dot_idx + 1 ..], field.name)) {
                                                        escapes = true;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if (escapes) continue;

                        // Get the phantom state for this resource
                        const binding_info = context.getInfo(resource) orelse {
                            log.debug("[CLEANUP] No phantom state found for '{s}'\n", .{resource});
                            continue;
                        };
                        const phantom_state = binding_info.phantom_state;

                        // Report error - obligation was not satisfied
                        // Format names for display - extract field name from paths like "_.conn"
                        const display_name = if (std.mem.indexOf(u8, resource, ".")) |dot_idx|
                            resource[dot_idx + 1 ..]
                        else
                            resource;
                        try self.reportUndischargedObligation(display_name, phantom_state, binding_info.base_type, location);
                        has_errors = true;
                    }
                } else {
                    log.debug("[CLEANUP] ✓ All obligations either cleaned or documented in signature\n", .{});
                }
            } else {
                log.debug("[CLEANUP] ✓ No uncleaned resources at terminator\n", .{});
            }
        }

        // Validate nested continuations
        // Nested continuations belong to the LAST invocation in the pipeline, not the parent event
        if (cont.continuations.len > 0) {
            // Check if the single step is an invocation (or contains one)
            var last_invocation: ?*const ast.Invocation = null;
            if (cont.node) |step| {
                switch (step) {
                    .invocation => |*inv| {
                        last_invocation = inv;
                    },
                    .label_with_invocation => |*lwi| {
                        // Labels wrap invocations - extract the inner invocation
                        last_invocation = &lwi.invocation;
                    },
                    else => {},
                }
            }

            if (last_invocation) |inv| {
                // Look up the event invoked by the last step
                const event_name = try self.pathToString(inv.path);
                defer self.allocator.free(event_name);

                const module_name = inv.path.module_qualifier orelse flow_module;
                const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_name });
                defer self.allocator.free(qualified_name);

                log.debug("[PHANTOM-FLOW]   Nested continuations belong to last invocation: '{s}'\n", .{qualified_name});

                const nested_event_info = event_map.get(qualified_name) orelse {
                    log.debug("[PHANTOM-FLOW]   Event '{s}' not found, skipping nested continuations\n", .{qualified_name});
                    return !has_errors;
                };

                // Bare-return bind: `call(...): owned` introduces `owned` carrying the
                // invoked event's `return_phantom` — the `-> T<phantom>` twin of a
                // `| branch owned` payload phantom (recorded above for the branch
                // form). Without this, a migrated transfer/obligation event (e.g.
                // `take` → `-> *String<instance!>`) leaves the bound name with no
                // tracked state, so a downstream consumer (`append(s: owned)`) fails
                // its phantom precondition. Mirrors the branch-payload recording.
                if (inv.return_binding) |rb| {
                    // Route through the shared recorder so a record return's
                    // per-FIELD obligations seed too — whole-value-only
                    // seeding left `make(): r` under a `! each` arm holding an
                    // untracked `r.h` (330_135).
                    try self.recordReturnObligationAs(rb, inv.return_destructure, nested_event_info.decl, module_name, &context);
                }

                // Validate nested continuations against the invoked event (not parent event)
                // Pass the current context down so disposed bindings propagate
                for (cont.continuations, 0..) |*nested, nested_idx| {
                    const nested_valid = try self.validateContinuation(nested, nested_event_info.decl, module_name, flow_module, event_map, location, &context, implementing_event, nested.branch.len != 0 and joinFollows(cont.continuations, nested_idx), inv);
                    if (!nested_valid) {
                        has_errors = true;
                        // Continue checking for more errors
                    }
                }
            } else {
                // Check if step is inline_code (from comptime transforms like print.ln)
                // inline_code represents void completions - nested continuations should be allowed
                var is_inline_code = false;
                if (cont.node) |step| {
                    if (step == .inline_code) {
                        is_inline_code = true;
                    }
                }

                if (is_inline_code) {
                    // inline_code is a void completion (e.g., from print.ln transform)
                    // Nested continuations should be validated as void event chain
                    // validateContinuationAsVoidChain handles invocation steps correctly -
                    // it looks up the event and validates nested branches against it
                    log.debug("[PHANTOM-FLOW]   Step is inline_code (void completion), validating nested continuations as void event chain\n", .{});
                    for (cont.continuations) |*nested| {
                        const nested_valid = try self.validateContinuationAsVoidChain(nested, flow_module, event_map, location, &context, implementing_event);
                        if (!nested_valid) {
                            has_errors = true;
                        }
                    }
                } else {
                    // No invocations in pipeline - nested continuations still belong to parent event
                    log.debug("[PHANTOM-FLOW]   No invocations in pipeline, nested continuations belong to parent event\n", .{});
                    for (cont.continuations, 0..) |*nested, nested_idx| {
                        const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, &context, implementing_event, nested.branch.len != 0 and joinFollows(cont.continuations, nested_idx), firing_inv);
                        if (!nested_valid) {
                            has_errors = true;
                            // Continue checking for more errors
                        }
                    }
                }
            }
        }

        return !has_errors;
    }

    /// Validate a continuation as part of a void event chain (e.g., after inline_code)
    /// This allows empty-branch continuations without checking against a parent event's branches
    fn validateContinuationAsVoidChain(
        self: *PhantomSemanticChecker,
        cont: *const ast.Continuation,
        flow_module: ?[]const u8,
        event_map: *std.StringHashMap(EventInfo),
        caller_location: errors.SourceLocation,
        parent_context: ?*const BindingContext,
        implementing_event: ?*const ast.EventDecl,
    ) anyerror!bool {
        var has_errors = false;

        // The arm owns the error (same convention as validateContinuation).
        const location = if (cont.location.line != 0) cont.location else caller_location;

        log.debug("[PHANTOM-FLOW]   Void chain continuation, branch: '{s}'\n", .{cont.branch});

        // Create context for this continuation
        var context = if (parent_context) |parent|
            try BindingContext.inherit(parent, self.allocator)
        else
            BindingContext.init(self.allocator);
        defer context.deinit();

        // Empty branch is valid in void chains
        if (cont.branch.len == 0) {
            // Validate the step if present
            if (cont.node) |*step| {
                if (!try self.registerContinuationLabel(step, flow_module orelse "unknown", event_map, location)) {
                    has_errors = true;
                }
                const step_valid = try self.validateStep(step, &context, event_map, flow_module, location);
                if (!step_valid) {
                    has_errors = true;
                }

                // Check if step is an invocation - if so, nested continuations belong to that event
                switch (step.*) {
                    .invocation => |*inv| {
                        // Look up the event
                        const event_name = try self.pathToString(inv.path);
                        defer self.allocator.free(event_name);
                        const resolved_module = inv.path.module_qualifier orelse flow_module orelse "unknown";
                        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ resolved_module, event_name });
                        defer self.allocator.free(qualified_name);

                        if (event_map.get(qualified_name)) |event_info| {
                            // Validate nested continuations against this event
                            for (cont.continuations, 0..) |*nested, nested_idx| {
                                const nested_valid = try self.validateContinuation(nested, event_info.decl, resolved_module, flow_module orelse "unknown", event_map, location, &context, implementing_event, nested.branch.len != 0 and joinFollows(cont.continuations, nested_idx), inv);
                                if (!nested_valid) {
                                    has_errors = true;
                                }
                            }
                            return !has_errors;
                        }
                    },
                    .inline_code => {
                        // Another inline_code - recursively validate as void chain
                        for (cont.continuations) |*nested| {
                            const nested_valid = try self.validateContinuationAsVoidChain(nested, flow_module, event_map, location, &context, implementing_event);
                            if (!nested_valid) {
                                has_errors = true;
                            }
                        }
                        return !has_errors;
                    },
                    else => {},
                }
            }

            // No step or unknown step type - recursively validate nested as void chain
            for (cont.continuations) |*nested| {
                const nested_valid = try self.validateContinuationAsVoidChain(nested, flow_module, event_map, location, &context, implementing_event);
                if (!nested_valid) {
                    has_errors = true;
                }
            }
        } else {
            // Non-empty branch in void chain is an error
            try self.reporter.addError(.KORU030, location.line, location.column, "Continuation expects branch '{s}' but void event chain has no branches", .{cont.branch});
            has_errors = true;
        }

        return !has_errors;
    }

    /// A `#label` on a continuation step is a declaration wherever it sits —
    /// branch continuation, void-event chain, or empty-branch chain. Register
    /// it against the invoked event so a later `@label` jump resolves in
    /// `label_map`, and name-check the anchor call's args against that event.
    /// Returns false when the anchor's args offend (the error is reported here).
    fn registerContinuationLabel(
        self: *PhantomSemanticChecker,
        step: *const ast.Step,
        flow_module: []const u8,
        event_map: *std.StringHashMap(EventInfo),
        location: errors.SourceLocation,
    ) !bool {
        switch (step.*) {
            .label_with_invocation => |lwi| {
                if (!lwi.is_declaration) return true;
                // Look up the event being invoked to use its signature for the label
                const inv_event_name = try self.pathToString(lwi.invocation.path);
                defer self.allocator.free(inv_event_name);

                const inv_module_name = lwi.invocation.path.module_qualifier orelse flow_module;
                const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module_name, inv_event_name });
                defer self.allocator.free(qualified_name);

                if (event_map.get(qualified_name)) |inv_info| {
                    log.debug("[PHANTOM-FLOW]   Recording label '#{s}' mapping to event '{s}'\n", .{ lwi.label, qualified_name });
                    try self.label_map.put(lwi.label, .{ .decl = inv_info.decl, .module = inv_module_name });
                    return try self.validateLabelArgNames(lwi.invocation.args, inv_info.decl, location, "#label call");
                } else {
                    log.debug("[PHANTOM-FLOW]   WARNING: Label '#{s}' points to unknown tor '{s}'\n", .{ lwi.label, qualified_name });
                    return true;
                }
            },
            else => return true,
        }
    }

    fn validateStep(self: *PhantomSemanticChecker, step: *const ast.Step, context: *BindingContext, event_map: *std.StringHashMap(EventInfo), current_module: ?[]const u8, location: errors.SourceLocation) !bool {
        var has_errors = false;
        log.debug("[PHANTOM-FLOW] Validating step: {s}\n", .{@tagName(step.*)});

        switch (step.*) {
            .invocation => |inv| {
                return self.validateSingleInvocation(&inv, context, event_map, current_module, location);
            },
            .label_with_invocation => |lwi| {
                // A declaration `#label event(args)` seeds the fold by invoking
                // `event` ONCE before the first iteration. Its consuming (`<!X>`)
                // inputs discharge the seed binding's obligation in the REAL
                // context — the re-issued `<X!>` obligation arrives fresh on the
                // body's output branches (`again v` / `stop r`), NOT on the seed
                // binding. Validating in a throwaway scoped copy (as this used to)
                // discarded that consumption, so the seed binding (e.g. `h0` in
                // `made h0 |> #loop step(h: h0)`) reached the loop's exit
                // terminator still "live" and — because auto_discharge_inserter
                // also failed to credit the seed — either triggered a spurious
                // KORU030 or got a double-free auto-dispose inserted next to the
                // escaped pointer (330_074/084/086). Validating in `context`
                // propagates the consume/clear so the exit branch sees no leftover
                // obligation. The @scope outer-scope markings on `context` (applied
                // by validateContinuation when entering the scoped continuation)
                // are already correct for the body; the seed itself runs once at
                // the head, so consuming the (non-outer) seed binding here is sound.
                if (lwi.is_declaration) {
                    return self.validateSingleInvocation(&lwi.invocation, context, event_map, current_module, location);
                } else {
                    // It's a jump without semantic args (legacy)
                    return true;
                }
            },
            .label_jump => |lj| {
                // Look up the target event for this label
                const target = self.label_map.get(lj.label);
                if (target) |t| {
                    if (!try self.validateLabelArgNames(lj.args, t.decl, location, "@jump")) {
                        has_errors = true;
                    }
                    // Validate jump arguments against target event's signature
                    for (lj.args, 0..) |arg, arg_idx| {
                        const arg_valid = try self.validateArgument(arg, arg_idx, t.decl, t.module, context, location, lj.label);
                        if (!arg_valid) {
                            has_errors = true;
                        }
                    }

                    // Validate event-level phantom preconditions for the jump
                    const context_valid = try self.validateEventContextPhantom(t.decl, t.module, context, location, lj.label);
                    if (!context_valid) has_errors = true;
                } else {
                    log.debug("[PHANTOM-FLOW]   Label '@{s}' not found in map, skipping jump arg validation\n", .{lj.label});
                }

                // Label jumps must not drop cleanup obligations. This holds for
                // BOTH forward jumps and back-edge jumps to a declared label
                // (`#loop` / `@loop`): a carried obligation must either be routed
                // into the loop head's consuming input via a jump arg (so the next
                // iteration re-consumes it) or be discharged before the jump.
                //
                // Back-edge jumps were previously exempt wholesale on the assumption
                // that "obligations survive across iterations" — but that exemption
                // also let a back-edge that DROPS the carried obligation pass
                // (330_075_back_edge_drops_obligation), leaking it to a stage-D raw
                // Zig error instead of a clean diagnostic. Conservation is now
                // verified, not assumed. Green: 330_074 / 330_083 (carry routed via
                // arg, or consumed before the jump). Caught: 330_075 / 370_020.
                //
                // LIMITATION 1 (per-loop obligation ownership): this per-jump check
                // requires every live non-outer-scope obligation at the back-edge to
                // route into THIS loop's head. For nested loops an obligation
                // belonging to an enclosing loop is live at the inner back-edge but
                // is not the inner head's to consume; the @scope mechanism marks
                // such obligations outer-scope (skipped below), but loop nesting
                // alone does not yet create that boundary. Nested label-folds that
                // carry an outer obligation through an inner back-edge are not
                // exercised by any current regression test and would need
                // SCC-scoped ownership to be fully sound.
                //
                // LIMITATION 2 (reverse direction): this enforces the "live
                // obligation must be carried" half of back-edge conservation. The
                // reverse half — every consuming (`<!...>`) input of the loop head
                // must be supplied by a jump arg — is not yet checked here; a body
                // that disposes the carried obligation and back-edges with empty
                // hands still falls to a stage-D error today.
                if (context.hasUncleanedResources() and self.check_mode == .full) {
                    // Back-edge conservation is an obligation-balance judgment —
                    // post-insertion full pass only (see the terminator gate).
                    const uncleaned = try context.getUncleanedResources(self.allocator);
                    defer self.allocator.free(uncleaned);

                    for (uncleaned) |resource| {
                        if (context.isOuterScope(resource)) {
                            continue;
                        }
                        var passed = false;
                        for (lj.args) |arg| {
                            if (std.mem.eql(u8, arg.value, resource)) {
                                passed = true;
                                break;
                            }
                        }
                        if (!passed) {
                            // Report the binding under its source-level name —
                            // the same display rules as reportLeaksAtHardTerminal:
                            // `s.handle` reads "handle", and the `_auto_N`
                            // renames the inserter mints for `_` captures are
                            // internal, so fall back to the base type.
                            const binding_info = context.getInfo(resource);
                            const display_name = if (std.mem.indexOf(u8, resource, ".")) |dot_idx|
                                resource[dot_idx + 1 ..]
                            else if (std.mem.startsWith(u8, resource, "_auto_") and binding_info != null and binding_info.?.base_type.len > 0)
                                binding_info.?.base_type
                            else
                                resource;
                            try self.reporter.addError(.KORU030, location.line, location.column, "Label jump '@{s}' drops cleanup obligation for '{s}' - pass it as an argument or discharge it before jumping", .{ lj.label, display_name });
                            has_errors = true;
                        }
                    }
                }

                return !has_errors;
            },
            .conditional_block => |cb| {
                for (cb.nodes) |*s| {
                    const inner_valid = try self.validateStep(s, context, event_map, current_module, location);
                    if (!inner_valid) has_errors = true;
                }
                return !has_errors;
            },
            .foreach => |fe| return self.validateNamedBranchList("foreach", fe.branches, context, event_map, current_module, location, &has_errors),
            .conditional => |cond| return self.validateNamedBranchList("conditional", cond.branches, context, event_map, current_module, location, &has_errors),
            .switch_result => |sr| return self.validateNamedBranchList("switch_result", sr.branches, context, event_map, current_module, location, &has_errors),
            .branch_constructor => |bc| {
                // Validate phantom states in inline branch construction
                for (bc.fields) |field| {
                    if (field.phantom) |phantom_str| {
                        _ = phantom_str; // TODO: Validate that the provided value matches the phantom annotation
                    }
                }
                return true;
            },
            else => {
                // Other step types don't involve phantom states
                return true;
            },
        }
    }

    /// Validate each named arm of a multi-branch construct, accumulating
    /// failures into has_errors so every broken arm still reports.
    fn validateNamedBranchList(
        self: *PhantomSemanticChecker,
        label: []const u8,
        branches: []const ast.NamedBranch,
        context: *BindingContext,
        event_map: *std.StringHashMap(EventInfo),
        current_module: ?[]const u8,
        location: errors.SourceLocation,
        has_errors: *bool,
    ) !bool {
        log.debug("[PHANTOM-FLOW] Validating {s} with {} branches\n", .{ label, branches.len });
        for (branches) |*branch| {
            const branch_valid = try self.validateNamedBranchRecursive(branch, context, event_map, current_module, location);
            if (!branch_valid) has_errors.* = true;
        }
        return !has_errors.*;
    }

    /// Validate a NamedBranch (from foreach or conditional)
    /// Handles @scope annotations to track outer-scope obligations
    /// This function does NOT call validateStep to avoid mutual recursion
    fn validateNamedBranchRecursive(self: *PhantomSemanticChecker, branch: *const ast.NamedBranch, parent_context: *BindingContext, event_map: *std.StringHashMap(EventInfo), current_module: ?[]const u8, caller_location: errors.SourceLocation) !bool {
        var has_errors = false;

        // Check if this branch has the @scope mark
        const has_scope = blk: {
            for (branch.marks) |mark| {
                if (std.mem.eql(u8, mark, "@scope")) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        log.debug("[PHANTOM-FLOW] Validating branch '{s}' (has_scope={}, {} continuations)\n", .{ branch.name, has_scope, branch.body.len });

        // Create context for this branch
        // If @scope, use inheritWithScope to mark existing obligations as outer-scope
        var branch_context = if (has_scope)
            try BindingContext.inheritWithScope(parent_context, self.allocator)
        else
            try BindingContext.inherit(parent_context, self.allocator);
        defer branch_context.deinit();

        // Validate each continuation in the branch body
        for (branch.body) |*cont| {
            // The arm owns the error (same convention as validateContinuation):
            // a NamedBranch carries no location of its own, so each body
            // continuation names its own line, falling back to the caller's.
            const location = if (cont.location.line != 0) cont.location else caller_location;
            // NOTE: We do NOT check outer-scope obligations at terminators inside @scope.
            // Outer obligations are "suspended" - they'll be checked when the OUTER scope
            // terminates (e.g., in the `done` branch after a for-loop).
            // The auto_discharge_inserter handles the actual disposal logic, respecting @scope.

            // Validate the step if present - handle recursively for nested structures
            if (cont.node) |step| {
                if (!try self.validateStepBranches(step, &branch_context, event_map, current_module, location)) has_errors = true;
            }

            // Resolve the event whose branches the nested continuations represent.
            // Nested continuations of `cont` are branches of cont.node when cont.node is
            // an invocation. validateContinuation needs the event_decl to add the
            // continuation's binding to the context with the correct phantom state.
            var nested_event_decl: ?*const ast.EventDecl = null;
            var nested_event_module: ?[]const u8 = null;
            var nested_firing_inv: ?*const ast.Invocation = null;
            if (cont.node) |*step_for_nested| switch (step_for_nested.*) {
                .invocation => |*inv_for_nested| {
                    nested_firing_inv = inv_for_nested;
                    const ev_name = try self.pathToString(inv_for_nested.path);
                    defer self.allocator.free(ev_name);
                    nested_event_module = inv_for_nested.path.module_qualifier orelse current_module;
                    const qualified = if (nested_event_module) |m|
                        try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ m, ev_name })
                    else
                        try self.allocator.dupe(u8, ev_name);
                    defer self.allocator.free(qualified);
                    if (event_map.get(qualified)) |info| nested_event_decl = info.decl;
                },
                else => {},
            };

            // Recursively validate nested continuations
            for (cont.continuations, 0..) |*nested, nested_idx| {
                // NOTE: We do NOT check outer-scope obligations at terminators inside @scope.
                // Outer obligations are "suspended" - they'll be checked when the outer scope
                // terminates. The auto_discharge_inserter handles disposal, respecting @scope.

                // The nested arm owns its errors: fall back to the enclosing
                // continuation's location only when the arm carries none.
                const nested_location = if (nested.location.line != 0) nested.location else location;

                // If we know the parent invocation's event, route through validateContinuation
                // so the binding (e.g. identity capture from `| opened f |>`) gets registered
                // before the inner step is validated. Without this, synthesized disposal calls
                // referencing those bindings see an empty context and fail.
                if (nested_event_decl) |ev_decl| {
                    const valid = try self.validateContinuation(
                        nested,
                        ev_decl,
                        nested_event_module,
                        current_module orelse "",
                        event_map,
                        nested_location,
                        &branch_context,
                        null,
                        nested.branch.len != 0 and joinFollows(cont.continuations, nested_idx),
                        nested_firing_inv,
                    );
                    if (!valid) has_errors = true;
                    continue;
                }

                // Fallback: parent step isn't an invocation we can resolve. Validate
                // recursively for nested structures (best effort, no binding tracking).
                if (nested.node) |step| {
                    if (!try self.validateStepBranches(step, &branch_context, event_map, current_module, nested_location)) has_errors = true;
                }
            }
        }

        return !has_errors;
    }

    /// Validate a step's nested branch structures: foreach/conditional/
    /// switch_result recurse into validateNamedBranchRecursive per branch; a
    /// bare invocation validates standalone. Other step types have no nested
    /// structure and pass.
    fn validateStepBranches(self: *PhantomSemanticChecker, step: ast.Node, context: *BindingContext, event_map: *std.StringHashMap(EventInfo), current_module: ?[]const u8, location: errors.SourceLocation) anyerror!bool {
        var valid = true;
        switch (step) {
            .foreach => |fe| {
                for (fe.branches) |*inner_branch| {
                    if (!try self.validateNamedBranchRecursive(inner_branch, context, event_map, current_module, location)) valid = false;
                }
            },
            .conditional => |cond| {
                for (cond.branches) |*inner_branch| {
                    if (!try self.validateNamedBranchRecursive(inner_branch, context, event_map, current_module, location)) valid = false;
                }
            },
            .switch_result => |sr| {
                for (sr.branches) |*inner_branch| {
                    if (!try self.validateNamedBranchRecursive(inner_branch, context, event_map, current_module, location)) valid = false;
                }
            },
            .invocation => |inv| {
                if (!try self.validateSingleInvocation(&inv, context, event_map, current_module, location)) valid = false;
            },
            else => {},
        }
        return valid;
    }

    fn validateSingleInvocation(self: *PhantomSemanticChecker, inv: *const ast.Invocation, context: *BindingContext, event_map: *std.StringHashMap(EventInfo), current_module: ?[]const u8, location: errors.SourceLocation) !bool {
        var has_errors = false;
        // Get the event name from path segments
        const event_name = try self.pathToString(inv.path);
        defer self.allocator.free(event_name);

        // Determine the module - use module_qualifier if present, otherwise current_module
        const module_name = inv.path.module_qualifier orelse current_module;

        // Build fully-qualified event name (module:event)
        const qualified_name = if (module_name) |mod|
            try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mod, event_name })
        else
            try self.allocator.dupe(u8, event_name);
        defer self.allocator.free(qualified_name);

        log.debug("[PHANTOM-FLOW]   Single invocation: '{s}' → qualified: '{s}'\n", .{ event_name, qualified_name });

        const event_info = event_map.get(qualified_name) orelse {
            log.debug("[PHANTOM-FLOW]   Event '{s}' not found in map, skipping step\n", .{qualified_name});
            return true;
        };

        // Validate each argument against event signature
        for (inv.args, 0..) |arg, arg_idx| {
            const arg_valid = try self.validateArgument(arg, arg_idx, event_info.decl, module_name, context, location, null);
            if (!arg_valid) {
                has_errors = true;
            }
        }

        // Validate event-level phantom preconditions
        const context_valid = try self.validateEventContextPhantom(event_info.decl, module_name, context, location, event_name);
        if (!context_valid) has_errors = true;

        return !has_errors;
    }

    fn validateEventContextPhantom(self: *PhantomSemanticChecker, event_decl: *const ast.EventDecl, event_module: ?[]const u8, context: *BindingContext, location: errors.SourceLocation, event_name: []const u8) !bool {
        var has_errors = false;
        log.debug("[PHANTOM-FLOW]   Checking event context phantoms for '{s}' ({} annotations)\n", .{ event_name, event_decl.annotations.len });
        for (event_decl.annotations, 0..) |ann, i| {
            log.debug("[PHANTOM-FLOW]     Annotation[{}]: '{s}' (isPhantom={})\n", .{ i, ann, isPhantomAnnotation(ann) });
            if (isPhantomAnnotation(ann)) {
                // Precondition found!
                const provided_state = context.get("") orelse "";
                log.debug("[PHANTOM-FLOW]     Precondition found: '{s}', current context: '{s}'\n", .{ ann, provided_state });

                const canonical_expected = try self.canonicalizePhantomState(ann, event_module orelse event_decl.module);
                defer self.allocator.free(canonical_expected);

                const provided_phantom = context.get("") orelse {
                    // Error: context-level phantom required but not provided
                    log.debug("[PHANTOM-FLOW] ❌ CONTEXT MISMATCH! Expected {s} but no context state defined\n", .{canonical_expected});
                    try self.reporter.addError(.KORU030, location.line, location.column, "Phantom state mismatch for event '{s}': expected context state '{s}' but no context state is defined", .{ event_name, canonical_expected });
                    has_errors = true;
                    continue;
                };

                const canonical_provided = try self.canonicalizePhantomState(provided_phantom, event_module orelse event_decl.module);
                defer self.allocator.free(canonical_provided);

                log.debug("[PHANTOM-FLOW] Comparing context phantoms: expected={s}, provided={s}\n", .{ canonical_expected, canonical_provided });

                const compatible = try phantom_parser.areCompatible(self.allocator, canonical_expected, canonical_provided);
                if (!compatible) {
                    log.debug("[PHANTOM-FLOW] ❌ CONTEXT MISMATCH!\n", .{});
                    try self.reporter.addError(.KORU030, location.line, location.column, "Phantom state mismatch for event '{s}': expected context state '{s}' but found '{s}'", .{ event_name, canonical_expected, canonical_provided });
                    has_errors = true;
                }
            }
        }
        return !has_errors;
    }

    fn isPhantomAnnotation(ann: []const u8) bool {
        // Simple heuristic: starts with Type[ or *Type[
        // In the future, this should be more robust or defined by a list of phantom types
        const has_open = std.mem.indexOf(u8, ann, "[") != null;
        const has_close = std.mem.endsWith(u8, ann, "]");
        return has_open and has_close;
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    /// The format specifier of an interpolation slot (`:d`, `:s`, `:f`, `:any`)
    /// is grammar, not a binding read — `{{ text:s }}` must never be read as a
    /// use of a binding called `s`. Returns the expression half of the slot.
    fn slotExpression(slot: []const u8) []const u8 {
        const body = std.mem.trim(u8, slot, " \t");
        const colon = std.mem.lastIndexOfScalar(u8, body, ':') orelse return body;
        const spec = body[colon + 1 ..];
        for ([_][]const u8{ "d", "s", "f", "any" }) |known| {
            if (std.mem.eql(u8, spec, known)) return std.mem.trim(u8, body[0..colon], " \t");
        }
        return body;
    }

    /// Report every DISCHARGED binding this argument reads.
    ///
    /// Two read shapes reach a plain-typed consumer: the argument value IS the
    /// binding (`print.ln(response)`), or the binding is read from inside a
    /// `{{ … }}` interpolation slot of a string literal
    /// (`print.ln("got {{response:s}}")`). The second is the one that mattered —
    /// the argument's own text is a literal, so a name comparison on it sees
    /// nothing. A slot's HEAD names a binding (`{{ r.sum:d }}` reads `r`), and
    /// so can the whole dotted PATH: an obligation carried on a record field is
    /// disposed under the composite key `r.k`, so both are tested (335_052).
    fn reportStaleReads(
        self: *PhantomSemanticChecker,
        arg: ast.Arg,
        context: *BindingContext,
        location: errors.SourceLocation,
    ) !bool {
        var found = false;

        if (context.isDisposed(arg.value)) {
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Use-after-discharge: binding '{s}' was already discharged and cannot be used",
                .{arg.value},
            );
            found = true;
        }

        const texts = [_][]const u8{
            arg.value,
            if (arg.expression_value) |ev| ev.text else "",
        };
        for (texts) |text| {
            var cursor: usize = 0;
            while (std.mem.indexOfPos(u8, text, cursor, "{{")) |open| {
                const close = std.mem.indexOfPos(u8, text, open + 2, "}}") orelse break;
                const expr = slotExpression(text[open + 2 .. close]);
                cursor = close + 2;

                var i: usize = 0;
                while (i < expr.len) {
                    if (!isIdentChar(expr[i])) {
                        i += 1;
                        continue;
                    }
                    const start = i;
                    while (i < expr.len and isIdentChar(expr[i])) i += 1;
                    // Only a HEAD starts a path; a segment reached through `.`
                    // was already consumed by the loop below.
                    if (start > 0 and expr[start - 1] == '.') continue;

                    // The head names a binding, and so may the DOTTED PATH.
                    // An obligation carried on a record field is disposed under
                    // the composite key `r.k` — that is the name the argument
                    // path reports — so a scan that stopped at the head could
                    // never see one, and `{{ r.k:s }}` read a discharged field
                    // in silence while `show(h: r.k)` was refused.
                    // Test the head, then each dotted extension of it.
                    var end = i;
                    while (true) {
                        const name = expr[start..end];
                        if (context.isDisposed(name)) {
                            try self.reporter.addError(
                                .KORU030,
                                location.line,
                                location.column,
                                "Use-after-discharge: binding '{s}' was already discharged and cannot be used",
                                .{name},
                            );
                            found = true;
                        }
                        if (end >= expr.len or expr[end] != '.') break;
                        var seg = end + 1;
                        while (seg < expr.len and isIdentChar(expr[seg])) seg += 1;
                        if (seg == end + 1) break;
                        end = seg;
                    }
                    i = end;
                }
            }
        }

        return found;
    }

    /// A `#label` call and every `@label` jump seeds/re-seeds `<label>_<name>`
    /// state vars keyed by ARG NAME — each arg's effective name must be a
    /// field of the target event, or the emit writes an undeclared var / an
    /// invalid struct field and stage-D reports a raw Zig error. Positional
    /// index-resolution is meaningless here (the vars are named, not slotted);
    /// field-access args carry their leaf in arg.name (`a.text` → `text`), so
    /// bare and labeled spellings take the same test. Measured: a bogus label
    /// (`bogus: a`) and a bare non-field (`a` vs param `draft`) both emitted
    /// `loop_<name>` with no declaration, and an under-filled jump dropped
    /// the rest of the struct (`missing struct field`).
    fn validateLabelArgNames(
        self: *PhantomSemanticChecker,
        args: []const ast.Arg,
        decl: *const ast.EventDecl,
        location: errors.SourceLocation,
        site: []const u8, // "@jump" | "#label call" — which surface the arg sits on
    ) !bool {
        var ok = true;
        for (args) |arg| {
            var names_field = false;
            for (decl.input.fields) |field| {
                if (std.mem.eql(u8, field.name, arg.name)) {
                    names_field = true;
                    break;
                }
            }
            if (!names_field) {
                const target_name = try self.pathToString(decl.path);
                defer self.allocator.free(target_name);
                try self.reporter.addError(
                    .KORU043,
                    location.line,
                    location.column,
                    "{s} arg '{s}' names no field of '{s}' — label args re-seed loop state by param name",
                    .{ site, arg.name, target_name },
                );
                ok = false;
            }
        }
        return ok;
    }

    fn validateArgument(
        self: *PhantomSemanticChecker,
        arg: ast.Arg,
        arg_idx: usize,
        event_decl: *const ast.EventDecl,
        event_module: ?[]const u8, // Qualified module name from event lookup
        context: *BindingContext,
        location: errors.SourceLocation,
        site_tag: ?[]const u8, // discriminates call KINDS at one event (back-edge jump vs seed) so positional args don't alias their site keys
    ) !bool {
        // Find the field in event input - get both phantom AND base type.
        // A NAMED arg (`free(s: owned)`) carries the param name in arg.name; a
        // POSITIONAL arg (`free(s1)`) carries the VALUE in both arg.name and
        // arg.value, so it resolves by POSITION. Matching positional args by
        // name silently missed the param — and its <!state> consumption —
        // whenever the binding name differed from the param name (610_012's
        // trap, fixed in auto_discharge_inserter 2026-06-12; this is the same
        // fix on the enforcement side).
        var expected_phantom: ?[]const u8 = null;
        var expected_base_type_raw: ?[]const u8 = null;
        var expected_module_path: ?[]const u8 = null;
        // resolveArgFieldIndex: a bare pun names its field even when a desugar
        // appended it late — index is the fallback only for a name that is no
        // field (the `free(s1)` positional case 610_012 needs).
        if (ast.resolveArgFieldIndex(arg, arg_idx, event_decl.input.fields)) |fi| {
            const field = event_decl.input.fields[fi];
            expected_phantom = field.phantom;
            expected_base_type_raw = field.type;
            expected_module_path = field.module_path;
        }

        // `<*>` — the any-qualification wildcard — takes the no-requirement
        // path: marked or unmarked args accepted, nothing consumed. Classes
        // ride a separate axis from identity: `*` accepts any STATE, while
        // `*@scoped` additionally declares it may receive frame-bound values.
        const any_qualification = if (expected_phantom) |ep| blk: {
            const name_end = std.mem.indexOfScalar(u8, ep, '@') orelse ep.len;
            break :blk std.mem.eql(u8, ep[0..name_end], "*");
        } else false;
        if (expected_phantom == null or any_qualification) {
            // Class confinement: a `scoped` value may enter only a param that
            // declares the class. `l.text` into `string`/`<*>` laundered the
            // borrow — the callee bound it unqualified and could produce it
            // back out (620_013). `<*@scoped>` is the sink contract: any
            // identity, frame-bound included — and it binds scoped inside, so
            // the callee's own produce edges refuse the same escape.
            if (!self.expectedHasScopedClass(expected_phantom) and
                (try self.argHasScopedClass(context, arg.value) or
                    (arg.phantom_type != null and self.expectedHasScopedClass(arg.phantom_type))))
            {
                try self.reporter.addError(
                    .KORU030,
                    location.line,
                    location.column,
                    "argument '{s}' is @scoped — it dies with its frame and parameter '{s}' declares no scoped acceptance. Declare it 'string<*@scoped>' (the borrow stays confined inside the callee), or copy it out first (std/string:from-page + take / fmt.blk)",
                    .{ arg.value, arg.name },
                );
                return false;
            }
            if (!any_qualification and expected_base_type_raw != null) {
                // A qualifier is part of the type: an unqualified param names
                // the PLAIN type — `string` is not `string<state>`. A
                // qualified argument is a type mismatch, not a satisfied
                // absence of requirements; the param spells `<state>`,
                // `<a|b>`, or `<*>` to accept qualified values.
                var qualified_state: ?[]const u8 = null;
                if (arg.phantom_type) |asserted| {
                    qualified_state = asserted;
                } else if (context.getInfo(arg.value)) |info| {
                    qualified_state = info.phantom_state;
                } else if (std.mem.indexOfScalar(u8, arg.value, '.')) |dot_idx| {
                    // Field projections are tracked under their own key; a
                    // renamed prefix falls back to field-name suffix, the
                    // same lookup the state-required path performs.
                    const suffix = arg.value[dot_idx..];
                    var it = context.bindings.iterator();
                    while (it.next()) |entry| {
                        if (std.mem.endsWith(u8, entry.key_ptr.*, suffix)) {
                            qualified_state = entry.value_ptr.phantom_state;
                            break;
                        }
                    }
                }
                if (qualified_state) |qs| {
                    try self.reporter.addError(
                        .KORU030,
                        location.line,
                        location.column,
                        "Type mismatch: argument '{s}' is qualified as '{s}<{s}>' but parameter '{s}' accepts only unqualified '{s}' — declare '<*>' to accept any qualification",
                        .{ arg.value, expected_base_type_raw.?, qs, arg.name, expected_base_type_raw.? },
                    );
                    return false;
                }
            }
            // Nominal distinctness (registry rung 1): when BOTH the expected
            // param type and the provided binding's type are registered
            // declared types and differ, refuse at the Koru layer — pins
            // 030_132/133, 340_006 demand a koru error naming both types. NOT
            // a blanket name compare: a literal into a nominal wrapper
            // (`string` -> Username) has an unregistered provided side and
            // must stay legal (030_142), while two distinct declared types
            // are never interchangeable regardless of shape.
            if (expected_base_type_raw) |exp| {
                if (context.getBaseType(arg.value)) |provided| {
                    // Canonicalized provided types carry a module stamp
                    // (`input:box#f64`); the registry keys BARE identities, so
                    // strip any qualifier before comparing.
                    const exp_bare = if (std.mem.lastIndexOfScalar(u8, exp, ':')) |ci| exp[ci + 1 ..] else exp;
                    const prov_bare = if (std.mem.lastIndexOfScalar(u8, provided, ':')) |ci| provided[ci + 1 ..] else provided;
                    if (self.declared_types.contains(exp_bare) and
                        self.declared_types.contains(prov_bare) and
                        !std.mem.eql(u8, exp_bare, prov_bare))
                    {
                        log.debug("[PHANTOM-FLOW] ❌ NOMINAL DISTINCTNESS: expected '{s}' got '{s}'\n", .{ exp_bare, prov_bare });
                        try self.reporter.addError(
                            .KORU030,
                            location.line,
                            location.column,
                            "Type mismatch: expected '{s}' but got '{s}' for argument '{s}' — declared types are distinct (nominal distinctness)",
                            .{ exp_bare, prov_bare, arg.name },
                        );
                        return false;
                    }
                }
            }
            // No phantom state expected for this field — but disposal is a
            // property of the BINDING, not of what the consumer wants. A
            // discharged binding is stale everywhere, and the plain-typed sink
            // (`std/io:print.ln`) is precisely where a stale taint does its
            // damage. Returning unconditionally here made use-after-discharge
            // fire only when the stale value flowed into ANOTHER phantom-aware
            // tor — blind at the sink the tracking exists to guard
            // (335_047/335_048).
            //
            // A no-phantom param can never BE the disposing site (disposal is
            // marked only where a `<!state>` param consumes), so the
            // re-validation exemption the consuming path needs does not apply.
            return !try self.reportStaleReads(arg, context, location);
        }

        // Class confinement applies on the qualified path too: `scratch@scoped`
        // into `string<scratch>` laundered the confinement class off the value —
        // the param must declare it (`string<scratch@scoped>` / `<*@scoped>`).
        if (!self.expectedHasScopedClass(expected_phantom) and
            (try self.argHasScopedClass(context, arg.value) or
                (arg.phantom_type != null and self.expectedHasScopedClass(arg.phantom_type))))
        {
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "argument '{s}' is @scoped — it dies with its frame and parameter '{s}' declares no scoped acceptance. Declare it with '@scoped' (the borrow stays confined inside the callee), or copy it out first (std/string:from-page + take / fmt.blk)",
                .{ arg.value, arg.name },
            );
            return false;
        }

        // A null literal into an optional-typed param is absence, not a state
        // violation — `?*T<live>` accepts it the same as `?i32` does, and there
        // is no binding to track or discharge. Without this, an optional
        // phantom param is compulsory-absent: it can only be omitted, never
        // explicitly nulled.
        if (std.mem.eql(u8, arg.value, "null")) {
            if (expected_base_type_raw) |raw| {
                if (typeIsOptional(raw)) return true;
            }
        }

        // Canonicalize expected base type
        const module_for_canon = event_module orelse event_decl.module;
        const expected_base_type = try self.canonicalizeBaseType(
            expected_base_type_raw.?,
            expected_module_path,
            module_for_canon,
        );
        defer self.allocator.free(expected_base_type);

        // Debug: print what we're looking for
        log.debug("[PHANTOM-FLOW] Checking arg '{s}' with value '{s}'\n", .{ arg.name, arg.value });
        log.debug("[PHANTOM-FLOW]   Expected type: '{s}[{s}]'\n", .{ expected_base_type, expected_phantom.? });

        // Author-asserted phantom label on a literal or parenthesized expression
        // (e.g. `c: 22.5<celsius>`). Trust the assertion — check that the asserted
        // label is compatible with what the event requires. No binding lookup.
        if (arg.phantom_type) |asserted| {
            const canonical_expected = try self.canonicalizePhantomState(expected_phantom.?, module_for_canon);
            defer self.allocator.free(canonical_expected);
            const canonical_asserted = try self.canonicalizePhantomState(asserted, module_for_canon);
            defer self.allocator.free(canonical_asserted);

            const compatible = try phantom_parser.areCompatible(self.allocator, canonical_expected, canonical_asserted);
            if (!compatible) {
                try self.reporter.addError(
                    .KORU030,
                    location.line,
                    location.column,
                    "Phantom state mismatch: argument '{s}' asserts '<{s}>' but event requires '<{s}>'.",
                    .{ arg.name, canonical_asserted, canonical_expected },
                );
                return false;
            }
            return true;
        }

        // The identity of THIS consuming site: which event param is eating which
        // binding. Fold bodies get validated by more than one walk (branch
        // continuation + void-chain), so the same syntactic consume can be
        // re-checked — that is not a double-use. A consume of an already-
        // disposed binding from a DIFFERENT site is (330_079/080).
        const event_path_str = try self.pathToString(event_decl.path);
        defer self.allocator.free(event_path_str);
        // The arg's VALUE POINTER identifies the syntactic site: each parsed
        // node owns its arg strings, so two textual `free(s)` steps get
        // distinct keys (610_006 double-free stays caught) while a re-walk of
        // the SAME node reuses the same allocation and dedupes.
        const site_key = try std.fmt.allocPrint(self.allocator, "{s}@{s}#{s}={s}/{x}", .{ site_tag orelse "call", event_path_str, arg.name, arg.value, @intFromPtr(arg.value.ptr) });
        defer self.allocator.free(site_key);

        // Check if the binding has been disposed
        if (context.isDisposed(arg.value)) {
            if (context.disposalSite(arg.value)) |site| {
                if (std.mem.eql(u8, site, site_key)) {
                    // Re-validation of the very site that disposed it — sound.
                    return true;
                }
            }
            log.debug("[CLEANUP] ❌ USE AFTER DISPOSAL DETECTED!\n", .{});
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Use-after-discharge: binding '{s}' was already discharged and cannot be used",
                .{arg.value},
            );
            return false;
        }

        // Get the full binding info (phantom state + base type) from context
        const binding_info = context.getInfo(arg.value) orelse {
            log.debug("[PHANTOM-FLOW]   No binding found for '{s}' in context\n", .{arg.value});
            // Value is not a tracked binding.
            // If the event REQUIRES a phantom state (expected_phantom is set),
            // then passing an untracked value is an error - we can't verify the state.
            // For example: query(conn: *Connection[connected]) requires the input to be
            // in [connected] state, but if we got *Connection (no phantom) from another
            // event, that's a type mismatch.
            //
            // HOWEVER: Earlier compiler passes (like auto-discharge) may rename bindings
            // (e.g., outermost_f -> _auto_2), so the argument value may not match
            // the original binding name in our context. For field accesses (containing .),
            // we can try to match by field name suffix since the field name is stable.
            //
            // If the argument looks like a field access and we find a matching field
            // name in the context, we should use that binding instead.
            if (std.mem.indexOf(u8, arg.value, ".")) |dot_idx| {
                const field_suffix = arg.value[dot_idx..]; // e.g., ".file"
                // Search for any binding ending with this field suffix
                var iter = context.bindings.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.endsWith(u8, entry.key_ptr.*, field_suffix)) {
                        // Found a matching binding - use it
                        log.debug("[PHANTOM-FLOW]   Found binding by field suffix: '{s}' matches '{s}'\n", .{ entry.key_ptr.*, arg.value });
                        // Continue with validation using this binding
                        const matched_info = entry.value_ptr.*;
                        // Validate phantom state compatibility (same as below)
                        const canonical_expected = try self.canonicalizePhantomState(expected_phantom.?, module_for_canon);
                        defer self.allocator.free(canonical_expected);
                        const canonical_provided = try self.canonicalizePhantomState(matched_info.phantom_state, module_for_canon);
                        defer self.allocator.free(canonical_provided);

                        const compatible = try phantom_parser.areCompatible(self.allocator, canonical_expected, canonical_provided);
                        if (!compatible) {
                            try self.reporter.addError(
                                .KORU030,
                                location.line,
                                location.column,
                                "Phantom state mismatch: expected '{s}' but got '{s}' for argument '{s}'",
                                .{ canonical_expected, canonical_provided, arg.name },
                            );
                            return false;
                        }

                        // Check if this event consumes the obligation
                        var expected_phantom_parsed = try phantom_parser.PhantomState.parse(self.allocator, expected_phantom.?);
                        defer expected_phantom_parsed.deinit(self.allocator);
                        switch (expected_phantom_parsed) {
                            .concrete => |concrete| {
                                if (concrete.consumes_obligation) {
                                    // Find and clear the matched binding's obligation
                                    context.clearCleanupObligation(entry.key_ptr.*);
                                    try context.markDisposed(entry.key_ptr.*, "field-suffix");
                                }
                            },
                            .variable => {},
                            .state_union => |u| {
                                var any_consumes = false;
                                for (u.members) |m| if (m.consumes_obligation) {
                                    any_consumes = true;
                                    break;
                                };
                                if (any_consumes) {
                                    context.clearCleanupObligation(entry.key_ptr.*);
                                    try context.markDisposed(entry.key_ptr.*, "field-suffix");
                                }
                            },
                        }
                        return true;
                    }
                }
            }

            // No matching binding found - this is an error if phantom state is required
            // Parse expected_phantom to check what kind of requirement it is:
            // - [state] (no !) = requirement - the value MUST be in this state
            // - <!state> (prefix !) = consumption - consumes an existing obligation
            // Both cases require the binding to be tracked with the correct state.
            var expected_parsed = try phantom_parser.PhantomState.parse(self.allocator, expected_phantom.?);
            defer expected_parsed.deinit(self.allocator);

            switch (expected_parsed) {
                .concrete => |concrete| {
                    // Whether it's a requirement or consumption, we need the binding tracked.
                    // Hints use the user-facing state spelling (e.g. `<owned!>`), never the
                    // internal canonicalized form (`input:owned`), which is not writable syntax.
                    if (concrete.consumes_obligation) {
                        // <!state> - consumption - argument must carry the obligation to consume.
                        // Name the VALUE the user wrote (`s.h`), not just the parameter (`x`):
                        // a field projection IS now a tracked entity (challenge 007), so if we
                        // reach here the value genuinely holds no live `<{name}!>` obligation
                        // (never acquired, or already discharged) — say so, don't blame it for a
                        // checker blind spot.
                        try self.reporter.addError(
                            .KORU030,
                            location.line,
                            location.column,
                            "Phantom state mismatch: '{s}' (parameter '{s}') holds no live '<{s}!>' obligation to consume here — it was never acquired or has already been discharged. Pass a value that still holds its '<{s}!>' obligation.",
                            .{ arg.value, arg.name, concrete.name, concrete.name },
                        );
                    } else {
                        // [state] - requirement - argument must be in this state
                        try self.reporter.addError(
                            .KORU030,
                            location.line,
                            location.column,
                            "Phantom state mismatch: argument '{s}' has no tracked phantom state, but this event requires state '<{s}>'.",
                            .{ arg.name, expected_phantom.? },
                        );
                    }
                    return false;
                },
                .variable => {
                    // State variable - the event is polymorphic, any state is fine
                    // (or no state - the variable will be bound at the call site)
                    return true;
                },
                .state_union => |u| {
                    // A union carrying the `*` catch-all accepts any
                    // qualification — including an unqualified value.
                    for (u.members) |m| {
                        if (std.mem.eql(u8, m.name, "*")) return true;
                    }
                    // State union - the event accepts multiple states
                    // If the binding isn't tracked, we can't verify it's in one of those states
                    try self.reporter.addError(
                        .KORU030,
                        location.line,
                        location.column,
                        "Phantom state mismatch: argument '{s}' has no tracked phantom state, but event requires one of '<{s}>'.",
                        .{ arg.name, expected_phantom.? },
                    );
                    return false;
                },
            }
        };

        const provided_phantom = binding_info.phantom_state;
        const provided_base_type = binding_info.base_type;

        log.debug("[PHANTOM-FLOW]   Provided type: '{s}[{s}]'\n", .{ provided_base_type, provided_phantom });

        // Base type checking. Unconditional since 2026-08-10; it used to sit
        // behind `--strict-base-types`, off by default, because it compared the
        // MODULE-QUALIFIED forms and the qualifier is not reliable: there is no
        // type -> declaring-module map anywhere in this checker, so
        // canonicalizeBaseType stamps a bare type name with whichever module
        // happened to be WRITING it. The two sides then disagree on the prefix
        // while naming the identical type.
        //
        // Measured 2026-08-10 by forcing the old comparison on for a full board:
        // 5 false positives, every one of that exact shape, and zero of any
        // other shape --
        //   expected 'input:*File'          got 'app.lib.mipmap:*File'
        //   expected 'input:string'         got 'app.lib.store:string'
        //   expected 'app.lib.taint:string' got 'input:string'
        //   expected 'std.field:*Field'     got 'input:*Field'
        // Three of those qualify a PRIMITIVE, where a module prefix is
        // meaningless outright; baseTypeModule below already knows that and
        // returns null for one, but this comparison never got the same
        // treatment. So the flag was not guarding against imprecision in
        // general -- it was guarding against one defect, and hiding the check's
        // whole value to do it.
        //
        // Comparing the unqualified names refuses every genuine mismatch the
        // old form did (2104_10..13: `Connection` vs `Transaction`, same
        // prefix) with none of the false positives.
        //
        // BLIND SPOT, stated rather than discovered later: two DIFFERENT types
        // sharing one bare name across modules (`a:*Handle` vs `b:*Handle`)
        // compare equal here and reach the backend, where Zig's nominal typing
        // refuses them. Closing that needs the type -> declaring-module map
        // that does not exist yet; until it does, the qualifier carries no
        // information and comparing it only invents disagreements.
        if (provided_base_type.len > 0 and !baseTypesMatch(expected_base_type, provided_base_type)) {
            log.debug("[PHANTOM-FLOW] ❌ BASE TYPE MISMATCH!\n", .{});
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Type mismatch: expected '{s}<{s}>' but got '{s}<{s}>' for argument '{s}'",
                .{ expected_base_type, expected_phantom.?, provided_base_type, provided_phantom, arg.name },
            );
            return false;
        }

        // Canonicalize both phantom states for proper comparison.
        // A BARE expected phantom self-resolves to the base type's module
        // (`*app/lib/db:Transaction<!active>` → `app/lib/db:active`), not the
        // consuming event's writing module; a primitive base falls back to the
        // writing module inside canonicalizePhantomStateWithBase.
        const expected_base_mod = try self.baseTypeModule(expected_module_path);
        const canonical_expected = try self.canonicalizePhantomStateWithBase(
            expected_phantom.?,
            module_for_canon,
            expected_base_mod,
        );
        defer self.allocator.free(canonical_expected);

        // Provided phantom is already qualified, but might not be canonical - canonicalize it too
        // We need to parse it to get its module, then resolve through module_map
        const canonical_provided = try self.canonicalizePhantomState(
            provided_phantom,
            module_for_canon, // Use event's qualified module as fallback if provided has no module
        );
        defer self.allocator.free(canonical_provided);

        log.debug("[PHANTOM-FLOW]   Canonical expected: '{s}'\n", .{canonical_expected});
        log.debug("[PHANTOM-FLOW]   Canonical provided: '{s}'\n", .{canonical_provided});

        // Check compatibility using canonicalized phantom states
        const compatible = try phantom_parser.areCompatible(
            self.allocator,
            canonical_expected,
            canonical_provided,
        );

        if (!compatible) {
            log.debug("[PHANTOM-FLOW] ❌ PHANTOM STATE MISMATCH!\n", .{});
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Phantom state mismatch: expected '{s}' but got '{s}' for argument '{s}'",
                .{ canonical_expected, canonical_provided, arg.name },
            );
            // Return false to indicate error, but don't stop checking
            return false;
        }

        log.debug("[PHANTOM-FLOW]   ✓ Type and phantom state compatible\n", .{});

        // Check if this event consumes the obligation (marked with ! prefix)
        var expected_phantom_parsed = try phantom_parser.PhantomState.parse(self.allocator, expected_phantom.?);
        defer expected_phantom_parsed.deinit(self.allocator);

        switch (expected_phantom_parsed) {
            .concrete => |concrete| {
                if (concrete.consumes_obligation) {
                    log.debug("[CLEANUP] Event parameter has [!{s}] - consumes obligation\n", .{concrete.name});
                    // A DEBT MUST EXIST BEFORE IT CAN BE SETTLED. The state
                    // already matched above, and that is weaker than it looks:
                    // `<!owned>` accepts `<owned!>` (the debt) AND bare
                    // `<owned>` (no debt), because compatibility asks only
                    // whether the STATE lines up. A bare `<state>` return mints
                    // nothing, so `<!state>` frees what the program does not
                    // own — and POISONS the binding on the way through, which is
                    // how one object reaches two live names and is released
                    // twice with no lying proc body (335_054 / 335_055).
                    //
                    // Ruled by Lars 2026-08-06. A `<!state>` PARAMETER means the
                    // caller handed the debt in, so the body may settle it once —
                    // the impl-param seeding threads the marker in as `state!`
                    // (reading it off the RAW spelling; canonicalization drops a
                    // consume prefix), which is what lets this predicate tell
                    // "I was given this" from "I was only shown this".
                    //
                    // Both predicates were measured and both behave identically
                    // on the corpus: `context.owesObligation(arg.value)` (the
                    // cleanup set) and the parse of `canonical_provided` below.
                    // The latter is kept because it needs no side table.
                    const enforce_debt_exists = true;
                    if (enforce_debt_exists) {
                        var provided_parsed = try phantom_parser.PhantomState.parse(self.allocator, canonical_provided);
                        defer provided_parsed.deinit(self.allocator);
                        const provided_owes = switch (provided_parsed) {
                            .concrete => |c| c.requires_cleanup,
                            .state_union => |u| blk: {
                                for (u.members) |m| if (m.requires_cleanup) break :blk true;
                                break :blk false;
                            },
                            .variable => true, // polymorphic: the caller's state decides
                        };
                        if (!provided_owes) {
                            try self.reporter.addError(
                                .KORU030,
                                location.line,
                                location.column,
                                "Phantom state mismatch: '{s}' (parameter '{s}') holds state '{s}' with no obligation attached — '<!{s}>' settles a debt, and this value never incurred one.",
                                .{ arg.value, arg.name, canonical_provided, concrete.name },
                            );
                            return false;
                        }
                    }
                    // This event disposes the resource - clear the cleanup obligation
                    context.clearCleanupObligation(arg.value);
                    // Mark the binding as disposed (poisoned - cannot be used anymore)
                    try context.markDisposed(arg.value, site_key);
                }
            },
            .variable => {},
            .state_union => |u| {
                var any_consumes = false;
                for (u.members) |m| if (m.consumes_obligation) {
                    any_consumes = true;
                    break;
                };
                if (any_consumes) {
                    log.debug("[CLEANUP] Event parameter has union member with [!] - consumes obligation\n", .{});
                    context.clearCleanupObligation(arg.value);
                    try context.markDisposed(arg.value, site_key);
                }
            },
        }

        return true;
    }

    /// Qualify a local phantom state with a module name
    /// - "open" + "mipmap" → "mipmap:open"
    /// - "fs:open" + "mipmap" → "fs:open" (already qualified, unchanged)
    /// - "M'_" + "mipmap" → "M'_" (state variable, unchanged)
    /// - "open" + null → "open" (no module, unchanged)
    fn qualifyPhantomState(self: *PhantomSemanticChecker, phantom_str: []const u8, module_name: ?[]const u8) ![]const u8 {
        // No module name? Return unchanged
        if (module_name == null) return phantom_str;

        // Parse to check if it's already qualified or is a state variable
        var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
        defer phantom.deinit(self.allocator);

        switch (phantom) {
            .concrete => |concrete| {
                // Already module-qualified? Return unchanged
                if (concrete.module_path != null) {
                    return phantom_str;
                }

                // Local state - qualify it with module name
                return try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name.?, concrete.name });
            },
            .variable => {
                // State variables are not qualified with modules
                return phantom_str;
            },
            .state_union => {
                // State unions are not qualified - they may have mixed modules
                return phantom_str;
            },
        }
    }

    fn pathToString(self: *PhantomSemanticChecker, path: ast.DottedPath) ![]const u8 {
        return std.mem.join(self.allocator, ".", path.segments);
    }
};

// ============================================================================
// Unit Tests for BindingContext
// ============================================================================
// These tests verify the core obligation tracking logic that powers Koru's
// phantom type system. BindingContext tracks:
// - Variable bindings and their phantom states
// - Cleanup obligations (resources with ! suffix that must be disposed)
// - Disposed bindings (poisoned - cannot be reused after disposal)
// - Scope boundaries (@scope annotation handling)

// Use full path to avoid ambiguity with internal declaration
const TestBindingContext = PhantomSemanticChecker.BindingContext;

test "BindingContext - basic set and get" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    // Set a binding without obligation
    try ctx.set("file", "open");

    // Get should return the value
    const value = ctx.get("file");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("open", value.?);

    // Unknown binding returns null
    try std.testing.expect(ctx.get("unknown") == null);
}

test "BindingContext - overwrite binding" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    try ctx.set("file", "open");
    try ctx.set("file", "closed"); // Overwrite

    const value = ctx.get("file");
    try std.testing.expectEqualStrings("closed", value.?);
}

test "BindingContext - cleanup obligation tracking with ! suffix" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    // State WITHOUT obligation marker
    try ctx.set("safe_file", "closed");
    try std.testing.expect(!ctx.hasUncleanedResources());

    // State WITH obligation marker (! suffix)
    try ctx.set("risky_file", "opened!");
    try std.testing.expect(ctx.hasUncleanedResources());

    // Verify the obligation is tracked
    const uncleaned = try ctx.getUncleanedResources(allocator);
    defer allocator.free(uncleaned);
    try std.testing.expectEqual(@as(usize, 1), uncleaned.len);
    try std.testing.expectEqualStrings("risky_file", uncleaned[0]);
}

test "BindingContext - module-qualified obligation tracking" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    // Module-qualified state with obligation
    try ctx.set("handle", "fs:opened!");
    try std.testing.expect(ctx.hasUncleanedResources());

    const uncleaned = try ctx.getUncleanedResources(allocator);
    defer allocator.free(uncleaned);
    try std.testing.expectEqual(@as(usize, 1), uncleaned.len);
}

test "BindingContext - clear cleanup obligation" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    try ctx.set("file", "opened!");
    try std.testing.expect(ctx.hasUncleanedResources());

    // Clear the obligation (simulating disposal)
    ctx.clearCleanupObligation("file");
    try std.testing.expect(!ctx.hasUncleanedResources());
}

test "BindingContext - disposal poisoning" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    try ctx.set("file", "opened!");

    // Not disposed yet
    try std.testing.expect(!ctx.isDisposed("file"));

    // Mark as disposed
    try ctx.markDisposed("file", "close()");

    // Now it's poisoned
    try std.testing.expect(ctx.isDisposed("file"));

    // Unknown bindings are not disposed
    try std.testing.expect(!ctx.isDisposed("other"));
}

test "BindingContext - multiple obligations" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    try ctx.set("file1", "opened!");
    try ctx.set("file2", "opened!");
    try ctx.set("file3", "closed"); // No obligation

    try std.testing.expect(ctx.hasUncleanedResources());

    const uncleaned = try ctx.getUncleanedResources(allocator);
    defer allocator.free(uncleaned);
    try std.testing.expectEqual(@as(usize, 2), uncleaned.len);

    // Clear one
    ctx.clearCleanupObligation("file1");

    const remaining = try ctx.getUncleanedResources(allocator);
    defer allocator.free(remaining);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
}

test "BindingContext - inherit from parent" {
    const allocator = std.testing.allocator;

    // Create parent context
    var parent = TestBindingContext.init(allocator);
    defer parent.deinit();

    try parent.set("inherited_file", "opened!");
    try parent.set("safe_data", "valid");

    // Create child that inherits
    var child = try TestBindingContext.inherit(&parent, allocator);
    defer child.deinit();

    // Child should see parent's bindings
    try std.testing.expectEqualStrings("opened!", child.get("inherited_file").?);
    try std.testing.expectEqualStrings("valid", child.get("safe_data").?);

    // Child inherits cleanup obligations
    try std.testing.expect(child.hasUncleanedResources());

    // Child modifications don't affect parent
    try child.set("child_only", "new!");
    try std.testing.expect(parent.get("child_only") == null);
}

test "BindingContext - inherit disposed state" {
    const allocator = std.testing.allocator;

    var parent = TestBindingContext.init(allocator);
    defer parent.deinit();

    try parent.set("file", "opened!");
    try parent.markDisposed("file", "close()");

    var child = try TestBindingContext.inherit(&parent, allocator);
    defer child.deinit();

    // Child inherits disposed state - file is poisoned
    try std.testing.expect(child.isDisposed("file"));
}

test "BindingContext - inheritWithScope marks obligations as outer" {
    const allocator = std.testing.allocator;

    var parent = TestBindingContext.init(allocator);
    defer parent.deinit();

    try parent.set("outer_file", "opened!");

    // Create child with @scope boundary
    var scoped_child = try TestBindingContext.inheritWithScope(&parent, allocator);
    defer scoped_child.deinit();

    // Child sees the binding
    try std.testing.expectEqualStrings("opened!", scoped_child.get("outer_file").?);

    // Child has the obligation
    try std.testing.expect(scoped_child.hasUncleanedResources());

    // But it's marked as outer scope!
    try std.testing.expect(scoped_child.isOuterScope("outer_file"));
    try std.testing.expect(scoped_child.hasOuterScopeObligations());
}

test "BindingContext - new obligations inside scope are not outer" {
    const allocator = std.testing.allocator;

    var parent = TestBindingContext.init(allocator);
    defer parent.deinit();

    try parent.set("outer_file", "opened!");

    var scoped_child = try TestBindingContext.inheritWithScope(&parent, allocator);
    defer scoped_child.deinit();

    // Add new obligation inside the scope
    try scoped_child.set("inner_file", "opened!");

    // outer_file is outer scope
    try std.testing.expect(scoped_child.isOuterScope("outer_file"));

    // inner_file is NOT outer scope (created inside)
    try std.testing.expect(!scoped_child.isOuterScope("inner_file"));

    // Both have uncleaned resources
    try std.testing.expect(scoped_child.hasUncleanedResources());
}

test "BindingContext - getOuterScopeObligations" {
    const allocator = std.testing.allocator;

    var parent = TestBindingContext.init(allocator);
    defer parent.deinit();

    try parent.set("outer1", "opened!");
    try parent.set("outer2", "opened!");

    var scoped_child = try TestBindingContext.inheritWithScope(&parent, allocator);
    defer scoped_child.deinit();

    try scoped_child.set("inner", "opened!");

    const outer_obligations = try scoped_child.getOuterScopeObligations(allocator);
    defer allocator.free(outer_obligations);

    // Should have 2 outer obligations
    try std.testing.expectEqual(@as(usize, 2), outer_obligations.len);

    // Total uncleaned is 3 (2 outer + 1 inner)
    const all_uncleaned = try scoped_child.getUncleanedResources(allocator);
    defer allocator.free(all_uncleaned);
    try std.testing.expectEqual(@as(usize, 3), all_uncleaned.len);
}

test "BindingContext - clearing outer scope obligation" {
    const allocator = std.testing.allocator;

    var parent = TestBindingContext.init(allocator);
    defer parent.deinit();

    try parent.set("file", "opened!");

    var scoped_child = try TestBindingContext.inheritWithScope(&parent, allocator);
    defer scoped_child.deinit();

    try std.testing.expect(scoped_child.isOuterScope("file"));

    // Clear the obligation (e.g., if we call dispose inside scope - which is allowed)
    scoped_child.clearCleanupObligation("file");

    // No longer has uncleaned resources
    try std.testing.expect(!scoped_child.hasUncleanedResources());
    try std.testing.expect(!scoped_child.hasOuterScopeObligations());
}

test "BindingContext - nested scope inheritance" {
    const allocator = std.testing.allocator;

    // Grandparent
    var gp = TestBindingContext.init(allocator);
    defer gp.deinit();
    try gp.set("gp_file", "opened!");

    // Parent with @scope
    var parent = try TestBindingContext.inheritWithScope(&gp, allocator);
    defer parent.deinit();
    try parent.set("parent_file", "opened!");

    // Child with another @scope
    var child = try TestBindingContext.inheritWithScope(&parent, allocator);
    defer child.deinit();
    try child.set("child_file", "opened!");

    // gp_file is outer to both parent and child
    try std.testing.expect(parent.isOuterScope("gp_file"));
    try std.testing.expect(child.isOuterScope("gp_file"));

    // parent_file is outer to child (because of second @scope)
    try std.testing.expect(!parent.isOuterScope("parent_file"));
    try std.testing.expect(child.isOuterScope("parent_file"));

    // child_file is not outer to anyone
    try std.testing.expect(!child.isOuterScope("child_file"));
}

test "BindingContext - state variable does not create obligation" {
    const allocator = std.testing.allocator;
    var ctx = TestBindingContext.init(allocator);
    defer ctx.deinit();

    // State variable (no obligation - it's a constraint, not a concrete state)
    try ctx.set("generic", "M'owned|borrowed");
    try std.testing.expect(!ctx.hasUncleanedResources());

    // Wildcard state variable
    try ctx.set("any", "F'_");
    try std.testing.expect(!ctx.hasUncleanedResources());
}

// ============================================================================
// Phantom State Mismatch Unit Tests
// Tests the full check() path with synthetic ASTs.
//
// ASTs must be built inline (not via helper function) because Zig struct
// literals reference stack-allocated arrays that become dangling after return.
// ============================================================================

test "PhantomSemanticChecker - state mismatch rejected" {
    const allocator = std.testing.allocator;

    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "// phantom test");
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(allocator, &reporter);
    defer checker.deinit();

    // Event A: ~event open_file {} | opened { file: *File[open] }
    var event_a_output_fields = [_]ast.Field{
        .{ .name = "file", .type = "*File", .phantom = "open" },
    };
    var event_a_branches = [_]ast.Branch{
        .{ .name = "opened", .payload = .{ .fields = &event_a_output_fields }, .is_optional = false },
    };

    // Event B: ~event read_file { file: *File[closed] } | done {}
    var event_b_input_fields = [_]ast.Field{
        .{ .name = "file", .type = "*File", .phantom = "closed" },
    };
    var event_b_done_fields = [_]ast.Field{};
    var event_b_branches = [_]ast.Branch{
        .{ .name = "done", .payload = .{ .fields = &event_b_done_fields }, .is_optional = false },
    };

    // Flow: ~open_file() | opened o |> read_file(file: o.file) | done |> _
    var terminal_cont = [_]ast.Continuation{
        .{
            .branch = "done",
            .binding = null,
            .condition = null,
            .node = .terminal,
            .indent = 2,
            .continuations = &[_]ast.Continuation{},
        },
    };
    var flow_args = [_]ast.Arg{
        .{ .name = "file", .value = "o.file" },
    };
    var flow_conts = [_]ast.Continuation{
        .{
            .branch = "opened",
            .binding = "o",
            .condition = null,
            .node = .{ .invocation = .{
                .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"read_file"}) },
                .args = &flow_args,
            } },
            .indent = 1,
            .continuations = &terminal_cont,
        },
    };

    var items = [_]ast.Item{
        .{ .event_decl = .{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"open_file"}) },
            .input = .{ .fields = &[_]ast.Field{} },
            .branches = &event_a_branches,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 1, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .event_decl = .{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"read_file"}) },
            .input = .{ .fields = &event_b_input_fields },
            .branches = &event_b_branches,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 5, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .flow = .{
            .body = ast.rootSite(.{
                .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"open_file"}) },
                .args = &[_]ast.Arg{},
            }, &flow_conts, .{ .line = 8, .column = 0, .file = "test.kz" }),
            .location = .{ .line = 8, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
    };

    const program = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .main_module_name = "input",
        .allocator = allocator,
    };

    // check() should return ValidationFailed
    const result = checker.check(&program, &program);
    try std.testing.expectError(error.ValidationFailed, result);

    // Verify error message mentions phantom state mismatch
    try std.testing.expect(reporter.errors.items.len > 0);
    const err_msg = reporter.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "Phantom state mismatch") != null);
}

test "PhantomSemanticChecker - matching states accepted" {
    const allocator = std.testing.allocator;

    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "// phantom test");
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(allocator, &reporter);
    defer checker.deinit();

    // Event A: ~event open_file {} | opened { file: *File[open] }
    var event_a_output_fields = [_]ast.Field{
        .{ .name = "file", .type = "*File", .phantom = "open" },
    };
    var event_a_branches = [_]ast.Branch{
        .{ .name = "opened", .payload = .{ .fields = &event_a_output_fields }, .is_optional = false },
    };

    // Event B: ~event read_file { file: *File[open] } | done {} — MATCHES [open]
    var event_b_input_fields = [_]ast.Field{
        .{ .name = "file", .type = "*File", .phantom = "open" },
    };
    var event_b_done_fields = [_]ast.Field{};
    var event_b_branches = [_]ast.Branch{
        .{ .name = "done", .payload = .{ .fields = &event_b_done_fields }, .is_optional = false },
    };

    // Flow: ~open_file() | opened o |> read_file(file: o.file) | done |> _
    var terminal_cont = [_]ast.Continuation{
        .{
            .branch = "done",
            .binding = null,
            .condition = null,
            .node = .terminal,
            .indent = 2,
            .continuations = &[_]ast.Continuation{},
        },
    };
    var flow_args = [_]ast.Arg{
        .{ .name = "file", .value = "o.file" },
    };
    var flow_conts = [_]ast.Continuation{
        .{
            .branch = "opened",
            .binding = "o",
            .condition = null,
            .node = .{ .invocation = .{
                .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"read_file"}) },
                .args = &flow_args,
            } },
            .indent = 1,
            .continuations = &terminal_cont,
        },
    };

    var items = [_]ast.Item{
        .{ .event_decl = .{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"open_file"}) },
            .input = .{ .fields = &[_]ast.Field{} },
            .branches = &event_a_branches,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 1, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .event_decl = .{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"read_file"}) },
            .input = .{ .fields = &event_b_input_fields },
            .branches = &event_b_branches,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 5, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .flow = .{
            .body = ast.rootSite(.{
                .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"open_file"}) },
                .args = &[_]ast.Arg{},
            }, &flow_conts, .{ .line = 8, .column = 0, .file = "test.kz" }),
            .location = .{ .line = 8, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
    };

    const program = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .main_module_name = "input",
        .allocator = allocator,
    };

    // check() should succeed — no errors
    try checker.check(&program, &program);
    try std.testing.expectEqual(@as(usize, 0), reporter.errors.items.len);
}

test "PhantomSemanticChecker - cross-module state mismatch rejected" {
    const allocator = std.testing.allocator;

    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "// phantom test");
    defer reporter.deinit();

    var checker = try PhantomSemanticChecker.init(allocator, &reporter);
    defer checker.deinit();

    // Event A: ~event open_file {} | opened { file: *File[fs:open] }
    var event_a_output_fields = [_]ast.Field{
        .{ .name = "file", .type = "*File", .phantom = "fs:open" },
    };
    var event_a_branches = [_]ast.Branch{
        .{ .name = "opened", .payload = .{ .fields = &event_a_output_fields }, .is_optional = false },
    };

    // Event B: ~event read_file { file: *File[mipmap:open] } | done {} — DIFFERENT MODULE
    var event_b_input_fields = [_]ast.Field{
        .{ .name = "file", .type = "*File", .phantom = "mipmap:open" },
    };
    var event_b_done_fields = [_]ast.Field{};
    var event_b_branches = [_]ast.Branch{
        .{ .name = "done", .payload = .{ .fields = &event_b_done_fields }, .is_optional = false },
    };

    // Flow: ~open_file() | opened o |> read_file(file: o.file) | done |> _
    var terminal_cont = [_]ast.Continuation{
        .{
            .branch = "done",
            .binding = null,
            .condition = null,
            .node = .terminal,
            .indent = 2,
            .continuations = &[_]ast.Continuation{},
        },
    };
    var flow_args = [_]ast.Arg{
        .{ .name = "file", .value = "o.file" },
    };
    var flow_conts = [_]ast.Continuation{
        .{
            .branch = "opened",
            .binding = "o",
            .condition = null,
            .node = .{ .invocation = .{
                .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"read_file"}) },
                .args = &flow_args,
            } },
            .indent = 1,
            .continuations = &terminal_cont,
        },
    };

    var items = [_]ast.Item{
        .{ .import_decl = .{
            .path = "fs",
            .local_name = null,
            .location = .{ .line = 0, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .import_decl = .{
            .path = "mipmap",
            .local_name = null,
            .location = .{ .line = 0, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .event_decl = .{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"open_file"}) },
            .input = .{ .fields = &[_]ast.Field{} },
            .branches = &event_a_branches,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 1, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .event_decl = .{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"read_file"}) },
            .input = .{ .fields = &event_b_input_fields },
            .branches = &event_b_branches,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 5, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
        .{ .flow = .{
            .body = ast.rootSite(.{
                .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"open_file"}) },
                .args = &[_]ast.Arg{},
            }, &flow_conts, .{ .line = 8, .column = 0, .file = "test.kz" }),
            .location = .{ .line = 8, .column = 0, .file = "test.kz" },
            .module = "input",
        } },
    };

    const program = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .main_module_name = "input",
        .allocator = allocator,
    };

    const result = checker.check(&program, &program);
    try std.testing.expectError(error.ValidationFailed, result);

    try std.testing.expect(reporter.errors.items.len > 0);
    const err_msg = reporter.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "Phantom state mismatch") != null);
}
