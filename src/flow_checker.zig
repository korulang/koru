const std = @import("std");
const log = @import("log");
const ast = @import("ast");
const errors = @import("errors");
const branch_checker = @import("branch_checker");
const annotation_parser = @import("annotation_parser");
const expression_parser = @import("expression_parser");
const phantom_parser = @import("phantom_parser");

/// The flow checker validates control flow properties:
/// 1. When-clause exhaustiveness (exactly one continuation without `when` per branch)
/// 2. When-clause determinism (no ambiguous else cases)
/// 3. Branch coverage (all required branches must be handled)
/// 4. Optional branches (can be skipped, |? catch-all is optional)
///
/// Check modes:
/// - frontend: Syntactic checks (KORU100 unused binding, KORU104 expression purity) - runs before transforms
///             Note: KORU100 skips [transform] invocations since binding usage isn't visible until after transform
/// - all: Full validation (KORU050/051 when-clause, KORU100 for transforms, KORU021/022 branch coverage) - runs after transforms
///
/// Duplicate-named branches are a COMPTIME EXPRESSION TOOL (ruled 2026-07-17):
/// a transform consumes same-named branches as data (std/parser grammars:
/// ordered-choice alternatives sharing a head). The tree must normalize before
/// emission, so ambiguity (KORU050/051) is only judgeable AFTER transforms —
/// frontend never rejects it.
pub const CheckMode = enum {
    /// Frontend mode: Syntactic checks that can run before transforms
    /// Checks: KORU100 (unused binding, skips [transform] invocations), KORU104
    frontend,

    /// Full mode: All checks including branch coverage
    /// Must run after transforms are applied (backend)
    /// Checks: KORU050/051 (when-clause exhaustiveness), KORU100 (for transforms), KORU021 (unknown branch), KORU022 (missing branch)
    all,
};

pub const FlowChecker = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    ast_items: ?[]const ast.Item, // Full AST for event lookups
    mode: CheckMode,

    /// `~[prototype]` module opt-in — see ShapeChecker.prototype_mode. Set by
    /// the check-flow pass from module_annotations; relaxes terminal-branch
    /// coverage the same way (unhandled `|` => synthesized @panic hole). Note:
    /// flow-check runs AFTER auto-discharge synthesis, so the hole arm usually
    /// already exists by here; this keeps the two checkers consistent.
    prototype_mode: bool = false,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !FlowChecker {
        return initWithMode(allocator, reporter, .all);
    }

    pub fn initWithMode(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter, mode: CheckMode) !FlowChecker {
        return FlowChecker{
            .allocator = allocator,
            .reporter = reporter,
            .ast_items = null,
            .mode = mode,
        };
    }

    pub fn deinit(self: *FlowChecker) void {
        _ = self;
        // No resources to clean up yet
    }

    /// Check an entire source file for control flow validity
    pub fn checkSourceFile(self: *FlowChecker, source_file: *const ast.Program) !void {
        // Store AST for event lookups
        self.ast_items = source_file.items;

        // Walk all flows and validate control flow
        for (source_file.items) |*item| {
            switch (item.*) {
                .flow => |*flow| {
                    try self.validateFlow(flow, flow.location);
                },
                .proc_decl => {},
                // `~event -> expr` bare-return impls are their own item kind;
                // the produce expression rides in value.plain_value and must
                // pass the KORU104 expression-admission wall too.
                .immediate_impl => |*ii| {
                    if (self.mode == .frontend) {
                        try self.checkBranchConstructorPurity(&ii.value, ii.location);
                        try self.checkImplMatchesDecl(ii);
                    }
                },
                .module_decl => |*module| {
                    // KORU141 wall: a comptime-mode module cannot declare taps.
                    // The comptime pipeline does not expand transforms (no
                    // unbounded recompiles by design), so an unexpanded tap-flow
                    // would leak into generated backend code as a bare invocation
                    // carrying raw pattern syntax. Walled here — the earliest
                    // point that sees both the module mode and the tap shape.
                    const comptime_module = annotation_parser.hasPart(module.annotations, "comptime");
                    // Validate flows in imported modules
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .flow => |*flow| {
                                if (self.mode == .frontend and comptime_module and flowIsTapDecl(flow)) {
                                    try self.reporter.addErrorAtLocationWithHint(
                                        .KORU141,
                                        flow.location,
                                        "taps are not supported in a ~[comptime] module — the comptime pipeline does not expand transforms (module '{s}')",
                                        .{module.logical_name},
                                        "drop the tap, or remove the module's comptime mode so the tap runs at runtime (see std/profiler)",
                                        .{},
                                    );
                                    continue;
                                }
                                try self.validateFlow(flow, flow.location);
                            },
                            .proc_decl => {},
                            .immediate_impl => |*ii| {
                                if (self.mode == .frontend) {
                                    try self.checkBranchConstructorPurity(&ii.value, ii.location);
                                    try self.checkImplMatchesDecl(ii);
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Check if any errors were reported
        if (self.reporter.hasErrors()) {
            return error.FlowValidationFailed;
        }
    }

    fn validateFlow(self: *FlowChecker, flow: *const ast.Flow, location: errors.SourceLocation) !void {
        const is_transformed = flow.inline_body != null or flow.preamble_code != null;

        // Check if this flow is a transform invocation (like ~tap)
        // Transform flows allow multi-branch fan-out (multiple handlers for same branch)
        const is_transform_flow = self.isTransformFlow(flow);

        // === FRONTEND CHECKS (syntactic, always run) ===
        // These run even for transformed flows

        // KORU104: the expression-admission wall — calls are not expressions,
        // anywhere. Frontend mode only: it runs pre-transform, so every
        // expression text in the AST is user-authored surface syntax (post-
        // transform nodes carry synthesized code the wall must not judge).
        if (self.mode == .frontend and !is_transformed) {
            try self.checkExpressionPurity(&flow.body);
        }

        // KORU106: the no-shadowing wall. Frontend mode only — the shape is
        // visible on the unexpanded AST, and a transform's lowered output
        // carries synthesized names this rule has no business judging.
        if (self.mode == .frontend and !is_transformed and !is_transform_flow) {
            var scope: std.ArrayList(ScopedBind) = .empty;
            defer scope.deinit(self.allocator);
            try self.checkShadowing(&flow.body, &scope);
        }

        // Check for duplicate branch handlers at each level. On a hit the tree
        // is structurally ambiguous — skip the rest of this flow's judgments
        // (when-clause ambiguity, coverage) so one defect yields ONE diagnostic;
        // other flows still validate, and checkSourceFile fails via the
        // standard hasErrors → FlowValidationFailed path.
        if (!is_transform_flow) {
            if (try self.checkDuplicateBranchHandlers(flow.body.continuations, location)) {
                return;
            }
        }

        // KORU037 (RULING 1): ban a no-op `_` body on an OPTIONAL effect branch.
        // Structural rule — runs in both modes so `--check` catches it at the
        // frontend boundary (pit of success). Needs the event decl, which is in
        // ast_items during both passes.
        if (!is_transform_flow) {
            if (try self.checkOptionalEffectNoop(flow)) return;
        }

        // The declared branches of the event this flow invokes — threaded into
        // the when-clause checker so RULING 2 can tell an OPTIONAL effect branch
        // (no else required) from a required/terminal one (else required).
        const flow_decl = self.findEventDecl(&flow.inv().path);
        const flow_branches: []const ast.Branch = if (flow_decl) |d| d.branches else &.{};

        // When-clause checks judge AMBIGUITY, and ambiguity only exists after
        // transforms have consumed their same-named branches (comptime data —
        // e.g. std/parser ordered-choice alternatives). Post-transform only.
        // Skip for transformed flows (structure has changed) and for transform
        // invocations (like ~tap) which use fan-out semantics.
        if (self.mode == .all and !is_transformed and !is_transform_flow) {
            // Validate when-clause exhaustiveness for all continuations (KORU050, KORU051)
            try self.validateWhenClauseExhaustiveness(flow.body.continuations, location, flow_branches);
        }

        // The flow HEAD's bind-position destructure (`~f(): { name, age } |> ...`)
        // is on flow.body itself, not one of its continuations, so the loop below
        // never sees it. Check its field usage here (usage lives in the head's
        // downstream continuations, which validateDestructureUsage searches).
        if (flow.body.node) |hn| {
            if (hn == .invocation and hn.invocation.return_destructure.len > 0) {
                const skip_check = self.mode == .frontend and self.isDeferredBindingInvocation(&flow.body);
                if (!skip_check) {
                    try self.validateReturnDestructureUsage(&flow.body, hn.invocation.return_destructure);
                }
            }
        }

        // The head's plain chain bind (`~f(): x |> ...`) is on flow.body for the
        // same reason its destructure is, and the continuation loop below never
        // reaches it either.
        try self.validateReturnBindingUsage(&flow.body, self.flowRootIsTransform(flow) or self.isDeferredBindingInvocation(&flow.body));

        // Recursively validate nested continuations and bindings
        // KORU100 runs even for transformed flows - checks inside ForeachNode etc.
        // A flow whose ROOT invocation is a [transform] event consumes its arm
        // bindings as transform DATA (std/parser's `! rule <name>` arms: the
        // binding IS the rule name) — usage is invisible until the transform
        // runs, so frontend defers them, same doctrine as the per-continuation
        // isDeferredBindingInvocation.
        const root_is_transform = self.flowRootIsTransform(flow);
        // The flow head is what these top-level branches hang off; its event
        // decl is where an arm's payload obligation is written.
        const head_path: ?*const ast.DottedPath = if (flow.body.node) |*hn|
            (if (hn.* == .invocation) &hn.invocation.path else null)
        else
            null;
        for (flow.body.continuations) |*cont| {
            // Nested when-clause ambiguity: post-transform only, same ruling
            // as the top-level check above.
            if (self.mode == .all and !is_transformed) {
                try self.validateContinuationWhenClauses(cont, location);
            }
            if (!is_transformed) {
                try self.validateBranchesHangOffPickers(cont);
            }
            // KORU100: Unused binding check
            // In frontend mode, skip for [transform] invocations (binding usage not visible until after transform)
            // In backend mode (all), check everything (transforms have run)
            try self.validateBindingUsage(cont, root_is_transform, head_path);
        }

        // === BACKEND CHECKS (semantic, require event lookups and transforms) ===

        // KORU110: bare ~proc declarations (no |variant) are unresolvable.
        // Walk all invocations in this flow and flag any whose event resolves
        // only to bare procs. Runs in both modes — it's a structural rule.
        if (!is_transformed) {
            try self.validateInvocationResolution(flow);
        }

        if (self.mode == .all and !is_transformed) {
            // Validate branch coverage (KORU021, KORU022) at the flow head AND
            // at every mid-chain call site. Only runs in 'all' mode - requires
            // transforms to be applied first. Skipped for transformed flows -
            // their branch structure has changed.
            try self.validateBranchCoverage(flow, location);
            for (flow.body.continuations) |*cont| {
                try self.validateChainCoverage(cont);
            }

            // Report every offending call site, then fail once.
            if (self.reporter.hasErrors()) {
                return error.FlowValidationFailed;
            }
        }
    }

    // =========================================================================
    // KORU104 — the expression-admission wall.
    //
    // An expression admits atoms, operators, and builtins — never a call.
    // Composition lives in the flow via explicit binds (`tor(args): x |>`),
    // which is what keeps purity, obligation accounting, and lifetime proofs
    // sound: every analysis treats expressions as opaque effect-free
    // computation, so a call hiding inside one is invisible to all of them.
    //
    // This walk is the SINGLE choke point for every expression-carrying
    // position reachable from a flow: invocation arguments (which covers
    // `if(...)` conditions and `for(...)` bounds — both parse as invocation
    // args), `when` clauses, produce (`->`) bodies, branch-constructor and
    // captured fields, label-jump args, and body-position expressions. The
    // per-surface guards that predate it (PARSE003 branch ctors, std/io
    // interpolations) stay as parse-time belts; this is the wall.
    // =========================================================================

    fn reportCallInExpression(self: *FlowChecker, surface: []const u8, location: errors.SourceLocation) !void {
        try self.reporter.addErrorWithHint(
            .KORU104,
            location.line,
            location.column,
            "nested call in {s} — calls are not expressions; use tor chaining: bind the result first",
            .{surface},
            "rewrite as `tor(args): x |> ...` and use `x` here",
            .{},
        );
    }

    fn exprTextHasCall(self: *FlowChecker, text: []const u8) bool {
        if (text.len == 0) return false;
        return expression_parser.textContainsCall(self.allocator, text);
    }

    fn checkExpressionPurity(self: *FlowChecker, cont: *const ast.Continuation) anyerror!void {
        // Transform-grafted subtrees carry synthesized code, not user syntax.
        if (cont.is_transformed_subtree) return;

        if (cont.condition) |c| {
            if (self.exprTextHasCall(c)) {
                try self.reportCallInExpression("the `when` condition", cont.location);
            }
        }
        if (cont.node) |*node| {
            try self.checkNodeExpressionPurity(node, cont.location);
        }
        for (cont.continuations) |*nested| {
            try self.checkExpressionPurity(nested);
        }
    }

    fn checkNodeExpressionPurity(self: *FlowChecker, node: *const ast.Node, location: errors.SourceLocation) anyerror!void {
        switch (node.*) {
            .invocation => |*inv| try self.checkInvocationArgsPurity(inv, location),
            .label_with_invocation => |*lwi| try self.checkInvocationArgsPurity(&lwi.invocation, location),
            .label_jump => |*lj| {
                // A label jump targets a `#label` anchor, not a proc directly —
                // there is no invocation path here to resolve against a
                // `|template|` proc, so the exemption stays as before.
                for (lj.args) |*arg| try self.checkArgPurity(arg, location, true);
            },
            .branch_constructor => |*bc| try self.checkBranchConstructorPurity(bc, location),
            .conditional => |*c| {
                if (self.exprTextHasCall(c.condition)) {
                    try self.reportCallInExpression("the condition", location);
                }
                for (c.branches) |*branch| {
                    for (branch.body) |*bcont| try self.checkExpressionPurity(bcont);
                }
            },
            .conditional_block => |*cb| {
                if (cb.condition) |cnd| {
                    if (self.exprTextHasCall(cnd)) {
                        try self.reportCallInExpression("the condition", location);
                    }
                }
                for (cb.nodes) |*n| try self.checkNodeExpressionPurity(n, location);
            },
            .foreach => |*fe| {
                if (self.exprTextHasCall(fe.iterable)) {
                    try self.reportCallInExpression("an iteration bound", location);
                }
                for (fe.branches) |*branch| {
                    for (branch.body) |*bcont| try self.checkExpressionPurity(bcont);
                }
            },
            .expression => |text| {
                if (self.exprTextHasCall(text)) {
                    try self.reportCallInExpression("an expression body", location);
                }
            },
            // switch_result / assignment / inline_code are transform-generated
            // (never present pre-transform); terminal / labels carry no
            // expression text.
            else => {},
        }
    }

    /// KORU021: the impl FORM must be the form the declaration declared, and a
    /// branch it constructs must be one the declaration declares.
    ///
    /// `-> expr` (bare return) pairs with `EventDecl.return_type`;
    /// `=> <branch> <value>` pairs with `EventDecl.branches`. Get it wrong and
    /// the frontend used to accept both halves and hand the disagreement to
    /// Zig, which reports it against `output_emitted.zig` — a file the author
    /// never opened — in Zig's vocabulary about a union Zig synthesised
    /// (510_112 / 510_113 / 510_114 carry the three raw messages verbatim).
    ///
    /// Every fact needed is present at parse time and in ONE file: the AST
    /// holds `is_bare_return` and `branch_name` on the impl, and `branches` /
    /// `return_type` on the decl. No flow analysis, no inference, no
    /// cross-module reach — so when `findEventDecl` cannot see the decl
    /// (one-file visibility) this says nothing at all rather than guessing.
    fn checkImplMatchesDecl(self: *FlowChecker, ii: *const ast.ImmediateImpl) anyerror!void {
        const decl = self.findEventDecl(&ii.event_path) orelse return;
        // A `~[prototype]` module opts out of branch-shape strictness the same
        // way it opts out of terminal coverage.
        if (self.prototype_mode) return;

        const name = if (ii.event_path.segments.len > 0)
            ii.event_path.segments[ii.event_path.segments.len - 1]
        else
            "?";

        var names_buf: [512]u8 = undefined;

        if (ii.value.is_bare_return) {
            if (decl.branches.len > 0) {
                try self.reporter.addErrorAtLocationWithHint(
                    .KORU021,
                    ii.location,
                    "tor '{s}' declares branches, so its implementation constructs one — a bare return (`->`) produces no branch tag",
                    .{name},
                    "implement it with the branch constructor instead: `~{s} => <branch> <value>`, naming one of: {s}",
                    .{ name, branchNameList(&names_buf, decl) },
                );
            }
            return;
        }

        // Branch-constructor form (`=> <branch> <value>`).
        if (ii.value.branch_name.len == 0) return;
        if (decl.branches.len == 0) {
            try self.reporter.addErrorAtLocationWithHint(
                .KORU021,
                ii.location,
                "tor '{s}' declares no branches, so it has no branch '{s}' to construct",
                .{ name, ii.value.branch_name },
                "it produces a bare return, so implement it that way: `~{s} -> <value>`",
                .{name},
            );
            return;
        }
        for (decl.branches) |b| {
            if (std.mem.eql(u8, b.name, ii.value.branch_name)) return;
            if (std.mem.eql(u8, b.name, "*")) return;
        }
        try self.reporter.addErrorAtLocationWithHint(
            .KORU021,
            ii.location,
            "tor '{s}' has no branch '{s}'",
            .{ name, ii.value.branch_name },
            "declared branches are: {s}",
            .{branchNameList(&names_buf, decl)},
        );
    }

    /// Comma-joined declared branch names, into a caller-owned stack buffer —
    /// this runs only on the refusal path, where an allocation would have to be
    /// freed by a caller that is about to return an error.
    fn branchNameList(buf: []u8, decl: *const ast.EventDecl) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        for (decl.branches, 0..) |b, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.writeAll(b.name) catch break;
        }
        if (fbs.getWritten().len == 0) return "(none)";
        return fbs.getWritten();
    }

    /// Shared by flow-nested branch constructors AND `immediate_impl` items
    /// (the `~event -> expr` bare-return impl parses as its own item kind,
    /// carrying the produce expression in `plain_value`).
    fn checkBranchConstructorPurity(self: *FlowChecker, bc: *const ast.BranchConstructor, location: errors.SourceLocation) anyerror!void {
        if (bc.plain_value) |pv| {
            if (self.exprTextHasCall(pv)) {
                const surface = if (bc.is_bare_return) "a produce (`->`) expression" else "a branch-constructor value";
                try self.reportCallInExpression(surface, location);
            }
        }
        for (bc.fields) |*field| {
            if (field.expression_str) |es| {
                if (self.exprTextHasCall(es)) {
                    var buf: [256]u8 = undefined;
                    const surface = std.fmt.bufPrint(&buf, "field '{s}'", .{field.name}) catch "a field expression";
                    try self.reportCallInExpression(surface, location);
                }
            }
        }
    }

    fn checkInvocationArgsPurity(self: *FlowChecker, inv: *const ast.Invocation, location: errors.SourceLocation) anyerror!void {
        if (inv.inserted_by_tap) return;
        // `capture { ... }` / `captured { ... }` carry their brace payload as a
        // single Source-typed arg — but that source is a FIELD-EXPRESSION LIST,
        // not an opaque code block, so the wall parses and judges it. (The
        // general contract — a transform declaring whether its Source payload
        // is expression-shaped — is an open design item; these two are the
        // shipped constructs that need it today.)
        const segs = inv.path.segments;
        const last_seg: []const u8 = if (segs.len > 0) segs[segs.len - 1] else "";
        const is_capture_family = std.mem.eql(u8, last_seg, "capture") or std.mem.eql(u8, last_seg, "captured");
        // The Expression-field exemption in checkArgPurity is only sound for a
        // genuine QUOTING proc (text handed over as inert data). A `|template|`
        // proc splices its Expression field's text verbatim into emitted code
        // — if/for's `expr` condition executes there — so template targets do
        // NOT get the exemption (see checkArgPurity + invocationResolvesToTemplateProc).
        const allow_expression_exemption = !self.invocationResolvesToTemplateProc(&inv.path);
        for (inv.args) |*arg| {
            if (arg.source_value) |sv| {
                if (is_capture_family) try self.checkCaptureFieldsPurity(sv.text, location);
                continue;
            }
            try self.checkArgPurity(arg, location, allow_expression_exemption);
        }
    }

    /// Judge a capture-family brace payload: `acc: <expr>, n: <expr>` — split
    /// on top-level commas, take the text after each field's first `:`, and
    /// run the one admission predicate on it.
    fn checkCaptureFieldsPurity(self: *FlowChecker, source_text: []const u8, location: errors.SourceLocation) anyerror!void {
        var depth: i32 = 0;
        var in_str = false;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= source_text.len) : (i += 1) {
            const at_end = i == source_text.len;
            if (!at_end) {
                const c = source_text[i];
                if (c == '"' and (i == 0 or source_text[i - 1] != '\\')) {
                    in_str = !in_str;
                    continue;
                }
                if (in_str) continue;
                if (c == '(' or c == '[' or c == '{') {
                    depth += 1;
                    continue;
                }
                if (c == ')' or c == ']' or c == '}') {
                    depth -= 1;
                    continue;
                }
                if (c != ',' or depth != 0) continue;
            }
            const field = std.mem.trim(u8, source_text[start..i], " \t\n");
            start = i + 1;
            const colon = std.mem.indexOfScalar(u8, field, ':') orelse continue;
            const name = std.mem.trim(u8, field[0..colon], " \t");
            const vtext = std.mem.trim(u8, field[colon + 1 ..], " \t\n");
            if (self.exprTextHasCall(vtext)) {
                var buf: [256]u8 = undefined;
                const surface = std.fmt.bufPrint(&buf, "captured field '{s}'", .{name}) catch "a captured field";
                try self.reportCallInExpression(surface, location);
            }
        }
    }

    fn checkArgPurity(self: *FlowChecker, arg: *const ast.Arg, location: errors.SourceLocation, allow_expression_exemption: bool) anyerror!void {
        // Source-typed arguments are opaque code blocks by design (the
        // metaprogramming surface) — the wall does not judge them. (Capture-
        // family sources are handled field-wise in checkInvocationArgsPurity.)
        if (arg.source_value != null) return;
        // Declared-Expression parameters are the comptime QUOTING surface —
        // BUT ONLY for a genuine quoting proc: the text is captured verbatim
        // and handed to a normal proc as inert []const u8 DATA, never executed
        // in this flow (210_036/210_046 pin that verbatim-capture contract).
        // A `[template]` proc is different in kind: its Expression field's
        // text is SPLICED VERBATIM INTO THE EMITTED CODE and DOES execute
        // there (if/for's zero-overhead `expr` condition — control.kz). A call
        // hiding in that text is exactly as illegal as one in a nested
        // condition, so the exemption must not apply to template targets —
        // `allow_expression_exemption` is false for those (see
        // invocationResolvesToTemplateProc), keeping root-position if/for
        // conditions scanned identically to nested ones.
        if (arg.expression_value != null and allow_expression_exemption) return;
        if (self.exprTextHasCall(arg.value)) {
            var buf: [256]u8 = undefined;
            const surface = std.fmt.bufPrint(&buf, "argument '{s}'", .{arg.name}) catch "an argument";
            try self.reportCallInExpression(surface, location);
        }
    }

    /// KORU110: visit every invocation in `flow` (top-level + nested) and verify
    /// the resolution rule. After Phase 1 of MULTI_VARIANT_PLAN, bare ~proc
    /// declarations are parseable but unresolvable — only |variant-tagged
    /// procs participate in resolution.
    fn validateInvocationResolution(self: *FlowChecker, flow: *const ast.Flow) !void {
        try self.checkInvocationVariants(flow.inv(), flow.location);
        for (flow.body.continuations) |*cont| {
            try self.checkContinuationInvocations(cont);
        }
    }

    fn checkContinuationInvocations(self: *FlowChecker, cont: *const ast.Continuation) !void {
        if (cont.node) |node| {
            if (node == .invocation) {
                try self.checkInvocationVariants(&node.invocation, cont.location);
            }
        }
        for (cont.continuations) |*nested| {
            try self.checkContinuationInvocations(nested);
        }
    }

    /// Emit KORU110 if every matching ~proc for this invocation's path is bare
    /// (target == null). Abstract events ([abstract] annotation) are exempt —
    /// they use a distinct override mechanism whose interaction with variants
    /// is a separate design decision (see docs/MULTI_VARIANT_PLAN.md).
    fn checkInvocationVariants(self: *FlowChecker, inv: *const ast.Invocation, location: errors.SourceLocation) !void {
        const items = self.ast_items orelse return;

        // Exempt abstract events: resolution flows through the abstract-override
        // mechanism, not direct proc dispatch.
        if (self.findEventDecl(&inv.path)) |event_decl| {
            if (event_decl.hasAnnotation("abstract")) return;
        }

        var has_match = false;
        var has_variant_proc = false;

        for (items) |*item| {
            switch (item.*) {
                .proc_decl => |*proc| {
                    if (!pathSegmentsEqual(inv.path.segments, proc.path.segments)) continue;
                    has_match = true;
                    if (proc.target != null) has_variant_proc = true;
                },
                .module_decl => |*module| {
                    for (module.items) |*mod_item| {
                        if (mod_item.* != .proc_decl) continue;
                        const proc = mod_item.proc_decl;
                        if (!pathSegmentsEqual(inv.path.segments, proc.path.segments)) continue;
                        has_match = true;
                        if (proc.target != null) has_variant_proc = true;
                    }
                },
                else => {},
            }
        }

        if (has_match and !has_variant_proc) {
            // Build a dotted event name for the diagnostic
            var name_buf = std.ArrayList(u8){};
            defer name_buf.deinit(self.allocator);
            for (inv.path.segments, 0..) |seg, i| {
                if (i > 0) try name_buf.append(self.allocator, '.');
                try name_buf.appendSlice(self.allocator, seg);
            }
            const event_name = name_buf.items;

            try self.reporter.addErrorWithHint(
                .KORU110,
                location.line,
                location.column,
                "tor '{s}' is called but its ~proc declaration has no |variant tag — bare procs are unresolvable",
                .{event_name},
                "tag the proc with a host: `~proc {s}|zig {{ ... }}` (or another host like |gpu, |js)",
                .{event_name},
            );
        }
    }

    /// Does the branch this continuation handles carry a CLEANUP OBLIGATION
    /// (`| ok *Handle<open!>`)? `parent_path` is the invocation these branches
    /// hang off — null where the walk cannot name it, which reads as "no", so
    /// the check stays on by default.
    ///
    /// Unions cannot carry `!` (phantom_parser rejects a union member with the
    /// production marker), and a state variable never does, so `.concrete` is
    /// the only prong that can answer yes.
    fn branchPayloadCarriesObligation(
        self: *FlowChecker,
        parent_path: ?*const ast.DottedPath,
        branch_name: []const u8,
    ) bool {
        const path = parent_path orelse return false;
        const decl = self.findEventDecl(path) orelse return false;
        for (decl.branches) |branch| {
            if (!std.mem.eql(u8, branch.name, branch_name)) continue;
            for (branch.payload.fields) |field| {
                const phantom_str = field.phantom orelse continue;
                var phantom = phantom_parser.PhantomState.parse(self.allocator, phantom_str) catch continue;
                defer phantom.deinit(self.allocator);
                if (phantom == .concrete and phantom.concrete.requires_cleanup) return true;
            }
            return false;
        }
        return false;
    }

    fn validateBindingUsage(
        self: *FlowChecker,
        cont: *const ast.Continuation,
        root_transform: bool,
        parent_path: ?*const ast.DottedPath,
    ) !void {
        // A transform-grafted/consumed subtree carries synthesized structure,
        // not user syntax — its bindings were the transform's data and were
        // validated by the transform itself. Same short-circuit the other
        // structural checks apply to the flag.
        if (cont.is_transformed_subtree) return;

        // If this continuation has a binding (other than _ or _auto_*), check if it's used
        // Bindings starting with _ are explicit discards or synthetic bindings from auto-discharge
        if (cont.binding) |binding| {
            if (!std.mem.startsWith(u8, binding, "_")) {
                // A binding is validated in EXACTLY ONE mode, never both:
                //  - frontend: when its usage is visible on the unexpanded AST
                //    (the normal case — the original identifier is still present).
                //  - all: only when its usage is DEFERRED — invisible until after
                //    transforms run (a [transform] that consumes the binding during
                //    its rewrite, or a template/scope construct).
                // Re-checking an already-frontend-validated binding in `all` mode is
                // what produced false KORU100s: by then the for/while template has
                // renamed the loop variable to `__koru_item` and the capture write
                // has lowered to an `.assignment` that no longer carries the original
                // name, so the scan can't find a binding that is genuinely used
                // (AoC day18's Conway grid: `for r |> for c |> captured { g[r][c]: … }`).
                // The honest place to check a loop variable is frontend, on the
                // intact `.foreach`; `all` only owns the deferred bindings frontend
                // could not yet see.
                // A template-PROC binding (the loop variable of `for`/`while`) is
                // never reliably checkable here: the template renames it to
                // `__koru_item` and may hoist the body into a
                // `__koru_inline_scoped_N` function, so the original name is absent
                // post-expansion. Skip it in BOTH modes (a genuinely-unused loop var
                // is spelled `_`). [transform] DATA bindings are different — their
                // usage IS visible after the transform runs — so they keep the
                // frontend-defer / all-check split below.
                const is_template_proc = if (cont.node) |n|
                    (n == .invocation and self.invocationResolvesToTemplateProc(&n.invocation.path))
                else
                    false;
                // An obligation-carrying payload (`| ok *Handle<open!>`) is
                // settled by auto-discharge, which INSERTS the disposal call —
                // and it runs in the BACKEND, while this check runs in the
                // FRONTEND. So the use KORU100 is hunting for does not exist
                // yet, and whether you may lean on auto-discharge came to
                // depend on an unrelated property of the next step: `print.ln`
                // downstream suppressed the check (its `expr: Expression` is
                // opaque captured syntax), an ordinary tor did not, and the
                // same program was legal or refused by that alone.
                // Skip it in BOTH modes, the way a template-proc binding is
                // skipped: an obligation that never settles is already KORU030's,
                // and KORU030 says it better than "unused binding" does.
                const carries_obligation = self.branchPayloadCarriesObligation(parent_path, cont.branch);
                const deferred = root_transform or self.isDeferredBindingInvocation(cont);
                const skip_check = is_template_proc or carries_obligation or switch (self.mode) {
                    .frontend => deferred,
                    .all => !deferred,
                };

                if (!skip_check and !self.isBindingUsed(cont, binding)) {
                    // A binding continued into a tor that declares NO input is
                    // structurally guaranteed unused: the thread has nowhere to
                    // land. Name the real cause instead of the generic
                    // "unused binding" (the void-input corner, 210_215).
                    var void_input_target: ?[]const u8 = null;
                    if (cont.node) |n| {
                        if (n == .invocation) {
                            if (self.findEventDecl(&n.invocation.path)) |event_decl| {
                                if (event_decl.input.fields.len == 0) {
                                    void_input_target = n.invocation.path.segments[n.invocation.path.segments.len - 1];
                                }
                            }
                        }
                    }
                    if (void_input_target) |target| {
                        try self.reporter.addError(
                            .KORU100,
                            cont.location.line,
                            cont.location.column,
                            "binding '{s}' has nowhere to go — the continuation target '{s}' takes no input",
                            .{ binding, target },
                        );
                    } else {
                        // ERROR: Unused binding
                        try self.reporter.addErrorWithHint(
                            .KORU100,
                            cont.location.line,
                            cont.location.column,
                            "unused binding '{s}'",
                            .{binding},
                            "discard the binding using `_` if not needed",
                            .{},
                        );
                    }
                }
            }
        }

        // Destructured fields are bindings too: each named field must be
        // used (or spelled `_` to discard the slot). Same deferred-binding
        // skip as above — transform/scope constructs consume bindings later.
        if (cont.destructure.len > 0) {
            const skip_check = self.mode == .frontend and (root_transform or self.isDeferredBindingInvocation(cont));
            if (!skip_check) {
                try self.validateDestructureUsage(cont, cont.destructure);
            }
        }

        // Bind-position destructure (`~f(): { name, age } |> ...`) is the same
        // rule: each NAMED return-destructure field must be used downstream (or
        // spelled `_`). It lives on the invocation, not cont.destructure — the
        // bind-site twin of the branch-payload check above.
        if (cont.node) |bn| {
            if (bn == .invocation and bn.invocation.return_destructure.len > 0) {
                const skip_check = self.mode == .frontend and self.isDeferredBindingInvocation(cont);
                if (!skip_check) {
                    try self.validateReturnDestructureUsage(cont, bn.invocation.return_destructure);
                }
            }
        }

        // Recursively check nested continuations. If THIS continuation's node is
        // a [transform] / template proc, its BRANCH continuations carry that
        // transform's arm bindings — their usage is invisible until the transform
        // runs (moved into a generated body, e.g. std/store:sweep's projection →
        // its sweepbody), so defer them to `all` mode exactly as a flow whose ROOT
        // is a transform. This is the nested-position twin of flowRootIsTransform:
        // a transform in continuation position (a `sweep`/`query`-shaped read
        // inside a `! draw`/loop body) otherwise loses the deferral and
        // false-positives KORU100 on projection fields that ARE used downstream.
        const child_deferred = root_transform or self.isDeferredBindingInvocation(cont);

        // The bind-position twin of the arm binding checked above.
        try self.validateReturnBindingUsage(cont, child_deferred);

        // This continuation's node is what ITS branches hang off — the nested
        // twin of the flow head above.
        const own_path: ?*const ast.DottedPath = if (cont.node) |*n|
            (if (n.* == .invocation) &n.invocation.path else null)
        else
            null;

        for (cont.continuations) |*nested| {
            try self.validateBindingUsage(nested, child_deferred, own_path);
        }

        // Also check inside ForeachNode and ConditionalNode branches
        if (cont.node) |node| {
            if (node == .foreach) {
                for (node.foreach.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        try self.validateBindingUsage(body_cont, child_deferred, null);
                    }
                }
            } else if (node == .conditional) {
                for (node.conditional.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        try self.validateBindingUsage(body_cont, child_deferred, null);
                    }
                }
            }
        }
    }

    /// KORU105 — the arm-from-nothing wall (ruled 2026-07-12, std/parser
    /// walk). A terminal `|` branch with no body cannot carry nested
    /// branches: branches hang off a thing that PICKS — an invocation
    /// dispatching, an effect being resumed — and a bodiless arm picks
    /// nothing. The parser nests continuations purely by indentation, so
    /// without this wall the shape parses and drifts through the passes
    /// ungoverned (transforms comptiming over parser-tolerated-but-unruled
    /// AST is the failure this guards). Effect `!` arms are exempt: their
    /// nested `|` arms are the resume sum (400_133 pins the flow-site use;
    /// 210_134 pins decl flatness — and the recursion below still walks
    /// resume arms, so a bodiless resume arm nesting deeper is caught).
    /// Transform-grafted subtrees carry the usual exemption.
    fn validateBranchesHangOffPickers(self: *FlowChecker, cont: *const ast.Continuation) anyerror!void {
        if (cont.is_transformed_subtree) return;
        if (cont.kind == .terminal and cont.node == null and cont.continuations.len > 0) {
            try self.reporter.addErrorWithHint(
                .KORU105,
                cont.location.line,
                cont.location.column,
                "nested branches under bodiless branch '{s}' — nothing picks a branch here",
                .{cont.branch},
                "branches continue from something that picks: give this branch a body (`|> event(...)`) and nest the branches under that invocation",
                .{},
            );
            return;
        }
        for (cont.continuations) |*nested| {
            try self.validateBranchesHangOffPickers(nested);
        }
    }

    /// True when the flow's ROOT invocation is a [transform] event — the arms
    /// of such a flow are the transform's INPUT DATA (pattern branches, rule
    /// declarations), and their bindings are consumed by the rewrite, not by
    /// user code the frontend can see.
    fn flowRootIsTransform(self: *FlowChecker, flow: *const ast.Flow) bool {
        const hn = flow.body.node orelse return false;
        if (hn != .invocation) return false;
        if (self.findEventDecl(&hn.invocation.path)) |event_decl| {
            if (annotation_parser.hasPart(event_decl.annotations, "transform")) return true;
        }
        return false;
    }

    /// Check if a continuation's node is an invocation whose binding usage isn't
    /// determinable at frontend time — a `[transform]` (binding consumed during
    /// rewrite) or a `|template|` proc (the binding's only use is spliced in by
    /// the template at render-time, in a later pass, so it's invisible here;
    /// scope-suspended bindings discharged by auto_discharge are this case too).
    /// In both, a frontend "unused binding" verdict would be premature.
    fn isDeferredBindingInvocation(self: *FlowChecker, cont: *const ast.Continuation) bool {
        const node = cont.node orelse return false;
        if (node != .invocation) return false;

        const inv = node.invocation;

        if (self.findEventDecl(&inv.path)) |event_decl| {
            if (annotation_parser.hasPart(event_decl.annotations, "transform")) return true;
        }

        return self.invocationResolvesToTemplateProc(&inv.path);
    }

    /// True if `path` resolves to a proc carrying the `[template]` ANNOTATION
    /// (the declaration kind lives in the bracket, never the variant slot —
    /// ruling 2026-08-16). The proc body is a template rendered in a later
    /// pass, so any binding it consumes is not yet visible to the frontend
    /// unused-binding check. Matches on the path's last segment — sufficient
    /// for the single-module programs this guards.
    fn invocationResolvesToTemplateProc(self: *FlowChecker, path: *const ast.DottedPath) bool {
        const items = self.ast_items orelse return false;
        if (path.segments.len == 0) return false;
        const target_name = path.segments[path.segments.len - 1];

        const isTemplateProc = struct {
            fn check(pd: *const ast.ProcDecl) bool {
                for (pd.annotations) |ann| {
                    if (std.mem.eql(u8, ann, "template")) return true;
                }
                return false;
            }
        }.check;

        const matchProc = struct {
            fn check(proc_items: []const ast.Item, name: []const u8, isTmpl: anytype) bool {
                for (proc_items) |*item| {
                    switch (item.*) {
                        .proc_decl => |*pd| {
                            if (pd.path.segments.len == 0) continue;
                            const pd_name = pd.path.segments[pd.path.segments.len - 1];
                            if (std.mem.eql(u8, pd_name, name) and isTmpl(pd)) return true;
                        },
                        .module_decl => |*md| {
                            if (check(md.items, name, isTmpl)) return true;
                        },
                        else => {},
                    }
                }
                return false;
            }
        }.check;

        return matchProc(items, target_name, isTemplateProc);
    }

    /// Check if a flow's top-level invocation is a transform event (like ~tap)
    /// Transform flows use fan-out semantics: multiple handlers for the same branch all fire
    /// A tap declaration parses as a plain flow invoking the library event
    /// `tap` (parser.zig: taps are a library feature); this is how the wall
    /// recognizes one before the transform system has claimed it. The path may
    /// already carry the declaring module as qualifier (source-module
    /// population runs before this check), so only the segments decide.
    fn flowIsTapDecl(flow: *const ast.Flow) bool {
        const path = &flow.inv().path;
        return path.segments.len == 1 and
            std.mem.eql(u8, path.segments[0], "tap");
    }

    fn isTransformFlow(self: *FlowChecker, flow: *const ast.Flow) bool {
        // Look up the event declaration for the flow's invocation
        if (self.findEventDecl(&flow.inv().path)) |event_decl| {
            return annotation_parser.hasPart(event_decl.annotations, "transform");
        }
        return false;
    }

    /// KORU100 for destructured fields: every named leaf must be used in
    /// the continuation's body. Nested sub-shapes recurse; only LEAF names
    /// are bindings (an intermediate field with a sub-shape binds nothing).
    /// Bind-position destructure usage check (`~f(): { name, age } |> ...`).
    /// Unlike a branch payload, the destructure DECLARATION lives on the same
    /// node whose result flows downstream, so usage must be searched in the
    /// continuations ONLY — searching the declaring node would count the
    /// declaration itself as a use (a self-reference false positive that let an
    /// unused field slip through).
    fn validateReturnDestructureUsage(self: *FlowChecker, cont: *const ast.Continuation, fields: []const ast.DestructureField) anyerror!void {
        for (fields) |f| {
            if (f.sub.len > 0) {
                try self.validateReturnDestructureUsage(cont, f.sub);
                continue;
            }
            if (std.mem.startsWith(u8, f.name, "_")) continue;
            var used = false;
            for (cont.continuations) |*c| {
                if (self.continuationUsesBindingRecursive(c, f.name)) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                try self.reporter.addErrorWithHint(
                    .KORU100,
                    cont.location.line,
                    cont.location.column,
                    "unused binding '{s}'",
                    .{f.name},
                    "discard the destructured field using `_` if not needed",
                    .{},
                );
            }
        }
    }

    fn validateDestructureUsage(self: *FlowChecker, cont: *const ast.Continuation, fields: []const ast.DestructureField) anyerror!void {
        for (fields) |f| {
            if (f.sub.len > 0) {
                try self.validateDestructureUsage(cont, f.sub);
                continue;
            }
            if (std.mem.startsWith(u8, f.name, "_")) continue;
            if (!self.isBindingUsed(cont, f.name)) {
                try self.reporter.addErrorWithHint(
                    .KORU100,
                    cont.location.line,
                    cont.location.column,
                    "unused binding '{s}'",
                    .{f.name},
                    "discard the destructured field using `_` if not needed",
                    .{},
                );
            }
        }
    }

    /// A chain bind (`event(args): x |> ...`) is the bind-position twin of a
    /// branch-arm binding, and an unused one means the same thing on either
    /// side of the pipe. It lives on the invocation as `return_binding`, not on
    /// `Continuation.binding`, which is why the arm check never saw it — the
    /// diagnostic's name promised "unused binding" while its implementation
    /// covered one spelling of it (510_110, 510_111).
    ///
    /// One exception, and it is not a softening. A bind carrying an obligation
    /// belongs to KORU030, whose message names both the resource and its
    /// disposer and is strictly the better sentence. Such a bind is also not
    /// dead in the first place: obligation enforcement keys off its presence,
    /// and stripping "dead" binds is what once switched that enforcement off
    /// wholesale ([[frag-obligation-enforcement-keys-off-return-binding]]).
    fn validateReturnBindingUsage(self: *FlowChecker, cont: *const ast.Continuation, deferred: bool) !void {
        const node = cont.node orelse return;
        if (node != .invocation) return;

        const binding = node.invocation.return_binding orelse return;
        // `_` and the auto-discharge synthetics are explicit discards.
        if (binding.len == 0 or std.mem.startsWith(u8, binding, "_")) return;

        // The obligation owns this one.
        if (self.findEventDecl(&node.invocation.path)) |event_decl| {
            if (event_decl.return_phantom != null) return;
        }

        // A template proc renames its binding during expansion, so the original
        // name is absent afterwards — the same skip the arm check applies.
        if (self.invocationResolvesToTemplateProc(&node.invocation.path)) return;

        // Validated in EXACTLY ONE mode, never both — same split as the arm
        // binding above: frontend owns bindings whose usage is visible on the
        // unexpanded AST, `all` owns the deferred ones it could not yet see.
        const skip_check = switch (self.mode) {
            .frontend => deferred,
            .all => !deferred,
        };
        if (skip_check) return;

        if (!self.isBindingUsed(cont, binding)) {
            try self.reporter.addErrorWithHint(
                .KORU100,
                cont.location.line,
                cont.location.column,
                "unused binding '{s}'",
                .{binding},
                "discard the binding using `_` if not needed",
                .{},
            );
        }
    }

    // =========================================================================
    // KORU106 — the no-shadowing wall.
    //
    // Koru forbids shadowing, and the pun machinery depends on it: "no
    // shadowing means the in-scope match is always unique — never ambiguous"
    // (ast_transform.zig). Nothing enforced it at the Koru level, so
    // `seed(): n |> bump(n): n` reached Zig as `redeclaration of local
    // constant 'n'` — a host error standing in for a language one, pointing
    // into a file the author never opened (210_173).
    //
    // SCOPE is the path from the flow root to the binding site: an ancestor's
    // bind is in scope, a SIBLING arm's is not (disjoint arms of the same
    // switch never see each other). Frontend mode only — the shape is visible
    // on the unexpanded AST, and post-transform trees carry synthesized names
    // this rule has no business judging.
    //
    // REACH is every binding an author writes: a CHAIN BIND (`event(args): x`)
    // and an ARM BINDING alike — a branch payload, an effect payload, a
    // destructured field.
    //
    // Sibling arms sharing a name are NOT shadowing and stay legal. `| lo x`
    // and `| hi x` are disjoint: only one fires, and neither can see the
    // other's binding. The depth-restore below is what makes that fall out —
    // each child recursion shrinks the scope back, so a sibling's bind is gone
    // before the next sibling's is noted. Nothing special-cases it.
    //
    // What this catches is genuine NESTING: `! item x |> classify(v: x)` with
    // `| lo x` inside that handler. The effect payload is still on the stack
    // when the capture binds, so the inner name hides the outer one. 800_002
    // pins that shape and its prose argued the opposite — that the two names
    // denote one value and the EMITTER should alpha-rename. Lars ruled against
    // it (2026-07-27): it is real shadowing and is refused. The Zig error it
    // used to leak — `capture 'x' shadows function parameter` — was a host
    // sentence standing in for a language one.
    // =========================================================================

    /// `reported` keeps one diagnostic per shadowed binding: a name reused three
    /// times down one chain is ONE problem the author fixes once, and the second
    /// and third sites produce a sentence identical to the first.
    const ScopedBind = struct { name: []const u8, line: usize, reported: bool = false };

    fn checkShadowing(self: *FlowChecker, cont: *const ast.Continuation, scope: *std.ArrayList(ScopedBind)) anyerror!void {
        if (cont.is_transformed_subtree) return;

        const depth = scope.items.len;
        defer scope.shrinkRetainingCapacity(depth);

        // An arm's own payload binding — `| ok x`, `! item x`. Noted BEFORE the
        // node, because the payload is produced upstream and is already live
        // when this continuation's own work happens. Siblings never collide:
        // the defer above restores the depth between them.
        if (cont.binding) |b| {
            try self.noteBind(scope, b, cont.location);
        }

        if (cont.node) |node| {
            if (node == .invocation) {
                const inv = node.invocation;
                // Synthesized call sites (taps, auto-discharge) name their own
                // temporaries; the author never wrote them.
                if (!inv.inserted_by_tap and !inv.from_opaque_tap and
                    !self.invocationResolvesToTemplateProc(&inv.path))
                {
                    if (inv.return_binding) |rb| {
                        try self.noteBind(scope, rb, cont.location);
                    }
                    for (inv.return_destructure) |f| {
                        try self.noteDestructure(scope, f, cont.location);
                    }
                }
            }
        }

        for (cont.continuations) |*child| {
            try self.checkShadowing(child, scope);
        }
    }

    fn noteDestructure(self: *FlowChecker, scope: *std.ArrayList(ScopedBind), f: ast.DestructureField, location: errors.SourceLocation) anyerror!void {
        if (f.sub.len > 0) {
            for (f.sub) |sub| try self.noteDestructure(scope, sub, location);
            return;
        }
        try self.noteBind(scope, f.name, location);
    }

    fn noteBind(self: *FlowChecker, scope: *std.ArrayList(ScopedBind), name: []const u8, location: errors.SourceLocation) anyerror!void {
        // `_` discards and the compiler's own synthetics (`__koru_*`, `__thread*`)
        // are not names an author can collide with.
        if (name.len == 0 or name[0] == '_') return;

        for (scope.items) |*prior| {
            if (std.mem.eql(u8, prior.name, name)) {
                if (prior.reported) return;
                prior.reported = true;
                try self.reporter.addErrorWithHint(
                    .KORU106,
                    location.line,
                    location.column,
                    "'{s}' is already bound at line {d} — this bind would shadow it, and Koru has no shadowing",
                    .{ name, self.reporter.userLine(prior.line) },
                    "give the second bind a different name, or drop it and keep using the one already in scope",
                    .{},
                );
                return;
            }
        }
        try scope.append(self.allocator, .{ .name = name, .line = location.line });
    }

    fn isBindingUsed(self: *FlowChecker, cont: *const ast.Continuation, binding: []const u8) bool {
        // Check if the binding is used in the continuation's condition (when-clause)
        if (cont.condition) |cond| {
            if (containsIdentifier(cond, binding)) return true;
        }

        // Check if the binding is used in the continuation's node
        if (cont.node) |node| {
            if (self.nodeUsesBinding(node, binding)) return true;
        }

        // Recursively check nested continuations
        for (cont.continuations) |*nested| {
            if (self.continuationUsesBindingRecursive(nested, binding)) return true;
        }

        return false;
    }

    fn continuationUsesBindingRecursive(self: *FlowChecker, cont: *const ast.Continuation, binding: []const u8) bool {
        // Check condition
        if (cont.condition) |cond| {
            if (containsIdentifier(cond, binding)) return true;
        }

        // Check node
        if (cont.node) |node| {
            if (self.nodeUsesBinding(node, binding)) return true;
        }

        // Check nested continuations
        for (cont.continuations) |*nested| {
            if (self.continuationUsesBindingRecursive(nested, binding)) return true;
        }

        return false;
    }

    fn nodeUsesBinding(self: *FlowChecker, node: ast.Node, binding: []const u8) bool {
        switch (node) {
            .invocation => |inv| {
                for (inv.args) |arg| {
                    if (containsIdentifier(arg.value, binding)) return true;
                }
                // Transform-grafted generated code on the invocation
                // (Invocation.inline_body) — scan it like inline code.
                if (inv.inline_body) |ib| {
                    if (containsIdentifier(ib, binding)) return true;
                }
            },
            .branch_constructor => |bc| {
                // Check plain_value for shorthand syntax like `e { result.e }`
                if (bc.plain_value) |pv| {
                    if (containsIdentifier(pv, binding)) return true;
                }
                for (bc.fields) |field| {
                    const value = if (field.expression_str) |expr| expr else field.type;
                    if (containsIdentifier(value, binding)) return true;
                }
                // The parser produces a BranchConstructor for `IDENT [EXPR]`
                // shapes at body position (backward compat with subflow
                // rebroadcasts). When branch_name matches the binding, the
                // identifier is ALSO a valid Zig binding-ref reading
                // (effect-branch resume context). Count as use either way.
                if (bc.fields.len == 0 and std.mem.eql(u8, bc.branch_name, binding)) {
                    return true;
                }
            },
            .label_with_invocation => |lwi| {
                for (lwi.invocation.args) |arg| {
                    if (containsIdentifier(arg.value, binding)) return true;
                }
            },
            .label_jump => |lj| {
                for (lj.args) |arg| {
                    if (containsIdentifier(arg.value, binding)) return true;
                }
            },
            .inline_code => |ic| {
                if (containsIdentifier(ic, binding)) return true;
            },
            .expression => |expr| {
                if (containsIdentifier(expr, binding)) return true;
            },
            .foreach => |fe| {
                if (containsIdentifier(fe.iterable, binding)) return true;
                for (fe.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        if (self.continuationUsesBindingRecursive(body_cont, binding)) return true;
                    }
                }
            },
            .conditional => |cond| {
                if (containsIdentifier(cond.condition, binding)) return true;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        if (self.continuationUsesBindingRecursive(body_cont, binding)) return true;
                    }
                }
            },
            .assignment => |asgn| {
                if (std.mem.eql(u8, asgn.target, binding)) return true;
                for (asgn.fields) |field| {
                    const value = if (field.expression_str) |expr| expr else field.type;
                    if (containsIdentifier(value, binding)) return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn validateContinuationWhenClauses(self: *FlowChecker, cont: *const ast.Continuation, location: errors.SourceLocation) !void {
        // A transformed subtree (capture's grafted `''` void-chain) carries the
        // transform exemption — its synthesized `''` children are sequential
        // void-chain steps, not when-guarded branches, so KORU050/051 do not
        // apply. Mirrors the flow-level `is_transformed` skip.
        if (cont.is_transformed_subtree) return;
        // Validate when-clauses in nested continuations
        if (cont.continuations.len > 0) {
            // These continuations handle the event invoked by `cont.node`; look
            // up its declared branches so RULING 2 (optional effect → no else
            // required) applies at nested depth too.
            const nested_branches: []const ast.Branch = blk: {
                const node = cont.node orelse break :blk &.{};
                if (node != .invocation) break :blk &.{};
                const d = self.findEventDecl(&node.invocation.path) orelse break :blk &.{};
                break :blk d.branches;
            };
            try self.validateWhenClauseExhaustiveness(cont.continuations, location, nested_branches);

            // Recursively validate deeper nesting
            for (cont.continuations) |*nested| {
                try self.validateContinuationWhenClauses(nested, location);
            }
        }
    }

    /// RULING 1 — a no-op `_` body on an OPTIONAL effect branch is illegal.
    /// Returns true (and reports KORU037) when the flow contains one, so the
    /// caller short-circuits the rest of this flow's judgments. Subscribing to
    /// an optional effect only to do nothing is pure noise (omit the handler),
    /// AND a hazard: if the branch is later promoted to REQUIRED, a no-op
    /// handler would silently swallow the event instead of surfacing the
    /// must-handle error. A no-op `_` on a REQUIRED effect branch stays legal
    /// (handle-and-ignore carries meaning), and `! b _ |> <action>` stays legal
    /// (discard the payload but actually act — the body is not `_`).
    fn checkOptionalEffectNoop(self: *FlowChecker, flow: *const ast.Flow) !bool {
        const decl = self.findEventDecl(&flow.inv().path) orelse return false;
        var found = false;
        for (flow.body.continuations) |*cont| {
            if (cont.kind != .effect) continue;
            const node = cont.node orelse continue;
            if (node != .terminal) continue; // body must be a bare `_` no-op
            for (decl.branches) |b| {
                if (!std.mem.eql(u8, b.name, cont.branch)) continue;
                if (b.kind != .effect or !b.is_optional) continue;
                try self.reporter.addErrorAtLocationWithHint(
                    .KORU037,
                    cont.location,
                    "no-op `_` body on optional effect branch '{s}' — subscribing to an optional effect only to do nothing is pure noise",
                    .{cont.branch},
                    "omit the handler entirely. A no-op is also a hazard: if '{s}' is later promoted to REQUIRED, this handler would silently swallow the event instead of surfacing the must-handle error. To act, replace `_` with a real step; to intentionally handle-and-ignore, the branch must be REQUIRED (drop the `?`), not optional.",
                    .{cont.branch},
                );
                found = true;
            }
        }
        // Reporter carries the failure; checkSourceFile fails via hasErrors →
        // FlowValidationFailed. Return whether to short-circuit this flow.
        return found;
    }

    fn validateWhenClauseExhaustiveness(self: *FlowChecker, continuations: []const ast.Continuation, location: errors.SourceLocation, declared: []const ast.Branch) !void {
        if (continuations.len == 0) return;

        // Group continuations by branch name
        var branch_groups = std.StringHashMap(std.ArrayList(*const ast.Continuation)).init(self.allocator);
        defer {
            var it = branch_groups.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            branch_groups.deinit();
        }

        for (continuations) |*cont| {
            const entry = try branch_groups.getOrPut(cont.branch);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(*const ast.Continuation){ .items = &.{}, .capacity = 0 };
            }
            try entry.value_ptr.append(self.allocator, cont);
        }

        // Validate each branch group
        var it = branch_groups.iterator();
        while (it.next()) |entry| {
            const branch_name = entry.key_ptr.*;
            const branch_continuations = entry.value_ptr.items;

            // If only one continuation for this branch, no validation needed
            if (branch_continuations.len == 1) continue;

            // Multiple continuations for same branch - validate when-clause exhaustiveness
            var else_count: usize = 0;
            for (branch_continuations) |cont| {
                if (cont.condition == null) {
                    else_count += 1;
                }
            }

            if (else_count == 0) {
                // RULING 2: an OPTIONAL EFFECT branch needs no else. Unmatched
                // guards falling through to nothing is exactly what "optional"
                // means — the effect simply isn't handled that fire, which the
                // optional contract permits. (KORU050 still applies to required
                // and terminal branches, where exhaustiveness matters.)
                if (isOptionalEffectBranchGroup(declared, branch_name, branch_continuations)) continue;

                // ERROR: Not exhaustive - missing else case
                log.debug("ERROR: Branch '{s}' has {d} when-clauses but no else case (non-exhaustive)\n", .{ branch_name, branch_continuations.len });
                try self.reporter.addError(.KORU050, location.line, location.column, "branch '{s}' has multiple when-clauses but no else case - add one continuation without 'when'", .{branch_name});
            } else if (else_count > 1) {
                // Void `!` effect multicast: N unguarded effect handlers are
                // subscribe-all (composition), not exclusive "elses". Matches
                // branch_checker.firstDuplicateSibling (effect links may
                // repeat). Resume-typed effects and `|` outcomes stay exclusive
                // — those still need exactly one unguarded arm. Mixed
                // when-guards + multiple unguarded elses also stay exclusive.
                if (isVoidEffectMulticastGroup(declared, branch_name, branch_continuations)) continue;

                // ERROR: Ambiguous - multiple else cases
                log.debug("ERROR: Branch '{s}' has {d} else cases (ambiguous)\n", .{ branch_name, else_count });
                try self.reporter.addError(.KORU051, location.line, location.column, "branch '{s}' has {d} continuations without 'when' (ambiguous) - only one else case allowed", .{ branch_name, else_count });
            } else {
                // Exactly one unguarded arm — valid ONLY if it comes LAST.
                //
                // An exclusive group emits as an `if (g) { …; return; }` chain
                // with the unguarded arm as the else, and an else TERMINATES
                // the chain: emitter_helpers.zig stops the group at the first
                // unguarded arm. An unguarded arm in any earlier position
                // therefore deletes every arm after it from the artifact —
                // they are not merely unreachable, they are never emitted.
                //
                // The shape trap this exists to catch: KORU050 above tells you
                // to ADD an unguarded arm when a branch has when-guarded
                // handlers, and where you put it silently decides whether your
                // other arms exist. `! name` with no guard means "a subscriber"
                // when every sibling is unguarded (void multicast, exempted in
                // the else_count > 1 arm) but "the fallback" the moment any
                // sibling is guarded. One spelling, two meanings — so say which
                // is in force rather than resolving it in silence. (400_174)
                const last = branch_continuations[branch_continuations.len - 1];
                if (last.condition != null) {
                    var unguarded_idx: usize = 0;
                    for (branch_continuations, 0..) |cont, i| {
                        if (cont.condition == null) {
                            unguarded_idx = i;
                            break;
                        }
                    }
                    const shadowed = branch_continuations.len - unguarded_idx - 1;
                    log.debug("ERROR: Branch '{s}' unguarded arm at {d} shadows {d} later arm(s)\n", .{ branch_name, unguarded_idx, shadowed });
                    try self.reporter.addError(.KORU053, location.line, location.column, "branch '{s}': the unguarded handler is #{d} of {d}, so the {d} when-guarded handler(s) after it are unreachable - an unguarded arm is the else of an exclusive group and must come last", .{ branch_name, unguarded_idx + 1, branch_continuations.len, shadowed });
                }
            }
        }
    }

    /// RULING 2 predicate: is this branch group an OPTIONAL EFFECT branch?
    /// True when the group's handlers are effect (`!`) continuations AND the
    /// declared branch of that name is both `.effect` and `.is_optional`. Such
    /// a branch requires no unguarded else — guards that all miss simply leave
    /// the optional effect unhandled, which its contract allows.
    fn isOptionalEffectBranchGroup(
        declared: []const ast.Branch,
        branch_name: []const u8,
        group: []const *const ast.Continuation,
    ) bool {
        // Handlers must actually be effect continuations.
        for (group) |cont| {
            if (cont.kind != .effect) return false;
        }
        for (declared) |b| {
            if (!std.mem.eql(u8, b.name, branch_name)) continue;
            return b.kind == .effect and b.is_optional;
        }
        return false;
    }

    /// Void-effect multicast: every handler is an unguarded `!` arm and the
    /// declared branch is a non-resuming effect. N such arms all fire (400_173);
    /// KORU051 must not treat them as competing elses. Resume-typed effects
    /// and `|` outcomes are exclusive — one unguarded arm only.
    fn isVoidEffectMulticastGroup(
        declared: []const ast.Branch,
        branch_name: []const u8,
        group: []const *const ast.Continuation,
    ) bool {
        for (group) |cont| {
            if (cont.kind != .effect) return false;
            if (cont.condition != null) return false;
        }
        for (declared) |b| {
            if (!std.mem.eql(u8, b.name, branch_name)) continue;
            if (b.kind != .effect) return false;
            if (b.resume_type != null) return false;
            if (b.resume_arms != null) return false;
            return true;
        }
        // No decl in hand — still all unguarded effects at this site; treat as
        // multicast so a missing decl doesn't invent exclusive ambiguity.
        return true;
    }

    /// Validate branch coverage: all required branches must be handled
    /// NOTE: This check should only run AFTER transforms are applied (mode == .all)
    /// because transform events replace flows entirely.
    fn validateBranchCoverage(self: *FlowChecker, flow: *const ast.Flow, location: errors.SourceLocation) !void {
        try self.validateCoverageAt(&flow.inv().path, flow.body.continuations, location);
    }

    /// Walk the chain. Every continuation whose step is an invocation is itself
    /// a call site, and owes its callee's required branches exactly as the flow
    /// head does. Without this walk the coverage wall reaches one invocation
    /// deep: an unhandled branch anywhere after the head binds the whole branch
    /// union to a name and rides into emission, where the author meets a Zig
    /// error about a type they never wrote (510_109).
    fn validateChainCoverage(self: *FlowChecker, cont: *const ast.Continuation) anyerror!void {
        // Same short-circuit the other structural checks apply: a grafted
        // subtree is the transform's own output, not user syntax.
        if (cont.is_transformed_subtree) return;

        // Both spellings of "a call happens here". A fold head
        // (`#loop step(...)`) is a call site exactly as much as a bare
        // invocation is, and checking only the latter would repeat the very
        // fault this walk exists to fix, one form over.
        if (cont.node) |n| {
            switch (n) {
                .invocation => |inv| try self.validateCoverageAt(&inv.path, cont.continuations, cont.location),
                .label_with_invocation => |lwi| try self.validateCoverageAt(&lwi.invocation.path, cont.continuations, cont.location),
                else => {},
            }
        }

        for (cont.continuations) |*nested| {
            try self.validateChainCoverage(nested);
        }
    }

    /// Coverage for ONE invocation against the continuations that handle it.
    /// Shared by the flow head and every mid-chain call site — a branching
    /// callee owes the same arms wherever it is invoked.
    fn validateCoverageAt(
        self: *FlowChecker,
        path: *const ast.DottedPath,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
    ) !void {
        // Find the event definition for this call site
        const event_decl = self.findEventDecl(path) orelse {
            // Event not found - this is a shape checker error, not flow checker
            // Just skip branch coverage validation
            return;
        };

        // Bare-return events (`-> T`) carry no branch tags — only a single unnamed
        // output. Continuations on such callees use produce syntax (`| _ v -> expr`);
        // the `| label` is binding sugar, not a shape-contract tag. Tag-based
        // KORU021/022 coverage does not apply.
        if (event_decl.return_type != null) return;

        // Convert AST branches to BranchChecker format
        var declared = try std.ArrayList(branch_checker.BranchChecker.DeclaredBranch).initCapacity(
            self.allocator,
            event_decl.branches.len,
        );
        defer declared.deinit(self.allocator);

        for (event_decl.branches) |branch| {
            try declared.append(self.allocator, .{
                .name = branch.name,
                .is_optional = branch.is_optional,
                .is_panic = branch.is_panic,
            });
        }

        // Convert continuations to BranchChecker format
        var handled = try std.ArrayList(branch_checker.BranchChecker.HandledBranch).initCapacity(
            self.allocator,
            continuations.len,
        );
        defer handled.deinit(self.allocator);

        for (continuations) |*cont| {
            // Skip empty branch names - these are void event chains (|> event())
            // where branches are not explicitly handled
            if (cont.branch.len == 0) continue;

            try handled.append(self.allocator, .{
                .name = cont.branch,
                .has_when_guard = cont.condition != null,
                .is_catchall = cont.is_catchall,
                .kind = if (cont.kind == .effect) .effect else .terminal,
            });
        }

        // Validate using pure BranchChecker (prototype mode relaxes terminal
        // exhaustiveness — the missing arm is a synthesized @panic hole).
        var result = try branch_checker.BranchChecker.validateWithMode(
            self.allocator,
            declared.items,
            handled.items,
            self.prototype_mode,
        );
        defer branch_checker.BranchChecker.freeResult(self.allocator, &result);

        // Report errors for missing branches
        if (result.missing_branches.len > 0) {
            const event_name = if (event_decl.path.segments.len > 0)
                event_decl.path.segments[event_decl.path.segments.len - 1]
            else
                "(unknown)";

            for (result.missing_branches) |branch_name| {
                log.debug("ERROR: Required branch '{s}' not handled in flow invoking '{s}'\n", .{ branch_name, event_name });
                try self.reporter.addError(
                    .KORU022,
                    location.line,
                    location.column,
                    "required branch '{s}' not handled - event '{s}' requires this branch",
                    .{ branch_name, event_name },
                );
            }
        }

        // Report errors for unknown branches
        for (result.unknown_branches) |branch_name| {
            log.debug("ERROR: Unknown branch '{s}' - event has no such branch\n", .{branch_name});
            try self.reporter.addError(
                .KORU021,
                location.line,
                location.column,
                "unknown branch '{s}' - event has no such branch",
                .{branch_name},
            );
        }

        // The head/chain sweep reports every call site before failing, so the
        // bail-out lives with the caller rather than here.
    }

    /// Find an event declaration by path
    fn findEventDecl(self: *FlowChecker, path: *const ast.DottedPath) ?*const ast.EventDecl {
        const items = self.ast_items orelse return null;

        const wanted_module = path.module_qualifier;

        // Helper to check if module qualifiers match
        const modulesMatch = struct {
            fn check(wanted: ?[]const u8, event_module: ?[]const u8) bool {
                // If no module qualifier was specified in the lookup, match any
                const w = wanted orelse return true;
                const e = event_module orelse return false;
                return std.mem.eql(u8, w, e);
            }
        }.check;

        // Helper to check if ALL path segments match (not just the last one)
        const pathsMatch = struct {
            fn check(wanted_segs: []const []const u8, event_segs: []const []const u8) bool {
                if (wanted_segs.len != event_segs.len) return false;
                for (wanted_segs, event_segs) |w, e| {
                    if (!std.mem.eql(u8, w, e)) return false;
                }
                return true;
            }
        }.check;

        for (items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    // Check if FULL path matches AND module qualifiers match
                    if (pathsMatch(path.segments, event.path.segments) and
                        modulesMatch(wanted_module, event.path.module_qualifier))
                    {
                        return event;
                    }
                },
                .module_decl => |*module| {
                    // Search in imported modules
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .event_decl => |*event| {
                                // Check FULL path match AND module qualifier
                                if (pathsMatch(path.segments, event.path.segments) and
                                    modulesMatch(wanted_module, event.path.module_qualifier))
                                {
                                    return event;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        return null;
    }

    /// Check for duplicate branch handlers at the same level. The RULE lives in
    /// BranchChecker.firstDuplicateSibling (the single source of truth shared
    /// with ShapeChecker): effect (`!`) links may repeat freely; a terminal
    /// (`|`) branch allows at most one unguarded handler per level; guards and
    /// catch-alls never count. This adapter only converts siblings, reports at
    /// the offending continuation's own source location, and recurses — it
    /// NEVER returns a raw error (the reporter carries the failure; callers
    /// fail via the standard hasErrors → FlowValidationFailed path). Returns
    /// true when any duplicate was reported, so the caller can short-circuit
    /// judgments that would re-describe the same defect.
    fn checkDuplicateBranchHandlers(self: *FlowChecker, continuations: []const ast.Continuation, location: errors.SourceLocation) !bool {
        var found = false;
        var handled = try std.ArrayList(branch_checker.BranchChecker.HandledBranch).initCapacity(
            self.allocator,
            continuations.len,
        );
        defer handled.deinit(self.allocator);
        for (continuations) |cont| {
            try handled.append(self.allocator, .{
                .name = cont.branch,
                .has_when_guard = cont.condition != null,
                .is_catchall = cont.is_catchall,
                .kind = if (cont.kind == .effect) .effect else .terminal,
            });
        }

        if (branch_checker.BranchChecker.firstDuplicateSibling(handled.items)) |dup| {
            // Point at the duplicate handler itself; fall back to the flow's
            // location when the continuation carries no coordinates (synthesized
            // nodes).
            const cont = continuations[dup.index];
            const loc = if (cont.location.line != 0) cont.location else location;
            if (dup.name.len == 0) {
                try self.reporter.addErrorAtLocation(
                    .SHAPE002,
                    loc,
                    branch_checker.BranchChecker.duplicate_unnamed_msg,
                    .{},
                );
            } else {
                try self.reporter.addErrorAtLocation(
                    .SHAPE002,
                    loc,
                    branch_checker.BranchChecker.duplicate_terminal_fmt,
                    .{dup.name},
                );
            }
            found = true;
        }

        // Recursively check nested continuations
        for (continuations) |cont| {
            // A transformed subtree (capture's grafted `''` void-chain) carries
            // the transform exemption — its synthesized children are not
            // user-authored branches, so the duplicate-handler rule does not
            // apply. Mirrors the flow-level `is_transform_flow` skip.
            if (cont.is_transformed_subtree) continue;
            if (cont.continuations.len > 0) {
                if (try self.checkDuplicateBranchHandlers(cont.continuations, location)) {
                    found = true;
                }
            }
        }

        return found;
    }
};

// Tests
test "when-clause exhaustiveness - single continuation" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();

    var checker = try FlowChecker.init(allocator, &reporter);
    defer checker.deinit();

    const continuations = [_]ast.Continuation{
        .{ .branch = "high", .binding = null, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
    };

    const location = errors.SourceLocation{ .file = "test.kz", .line = 1, .column = 1 };
    try checker.validateWhenClauseExhaustiveness(&continuations, location, &.{});

    try std.testing.expect(!reporter.hasErrors());
}

test "when-clause exhaustiveness - valid with else" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();

    var checker = try FlowChecker.init(allocator, &reporter);
    defer checker.deinit();

    const continuations = [_]ast.Continuation{
        .{ .branch = "high", .binding = null, .condition = "h.x > 10", .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
        .{ .branch = "high", .binding = null, .condition = "h.x > 5", .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
        .{ .branch = "high", .binding = null, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
    };

    const location = errors.SourceLocation{ .file = "test.kz", .line = 1, .column = 1 };
    try checker.validateWhenClauseExhaustiveness(&continuations, location, &.{});

    try std.testing.expect(!reporter.hasErrors());
}

test "when-clause exhaustiveness - missing else" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();

    var checker = try FlowChecker.init(allocator, &reporter);
    defer checker.deinit();

    const continuations = [_]ast.Continuation{
        .{ .branch = "high", .binding = null, .condition = "h.x > 10", .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
        .{ .branch = "high", .binding = null, .condition = "h.x > 5", .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
    };

    const location = errors.SourceLocation{ .file = "test.kz", .line = 1, .column = 1 };
    try checker.validateWhenClauseExhaustiveness(&continuations, location, &.{});

    try std.testing.expect(reporter.hasErrors());
}

test "when-clause exhaustiveness - ambiguous else" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();

    var checker = try FlowChecker.init(allocator, &reporter);
    defer checker.deinit();

    const continuations = [_]ast.Continuation{
        .{ .branch = "high", .binding = null, .condition = "h.x > 10", .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
        .{ .branch = "high", .binding = null, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
        .{ .branch = "high", .binding = null, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
    };

    const location = errors.SourceLocation{ .file = "test.kz", .line = 1, .column = 1 };
    try checker.validateWhenClauseExhaustiveness(&continuations, location, &.{});

    try std.testing.expect(reporter.hasErrors());
}

fn isIdentifierChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn pathSegmentsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

fn containsIdentifier(text: []const u8, ident: []const u8) bool {
    var idx: usize = 0;
    while (idx < text.len) {
        const remaining = text[idx..];
        const pos_opt = std.mem.indexOf(u8, remaining, ident) orelse return false;
        const start = idx + pos_opt;
        const end = start + ident.len;

        const valid_start = start == 0 or !isIdentifierChar(text[start - 1]);
        const valid_end = end >= text.len or !isIdentifierChar(text[end]);

        if (valid_start and valid_end) return true;
        idx = end;
    }
    return false;
}
