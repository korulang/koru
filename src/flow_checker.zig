const std = @import("std");
const log = @import("log");
const ast = @import("ast");
const errors = @import("errors");
const branch_checker = @import("branch_checker");
const annotation_parser = @import("annotation_parser");
const expression_parser = @import("expression_parser");

/// The flow checker validates control flow properties:
/// 1. When-clause exhaustiveness (exactly one continuation without `when` per branch)
/// 2. When-clause determinism (no ambiguous else cases)
/// 3. Branch coverage (all required branches must be handled)
/// 4. Optional branches (can be skipped, |? catch-all is optional)
///
/// Check modes:
/// - frontend: Syntactic checks (KORU050/051 when-clause, KORU100 unused binding) - runs before transforms
///             Note: KORU100 skips [transform] invocations since binding usage isn't visible until after transform
/// - all: Full validation (KORU100 for transforms, KORU021/022 branch coverage) - runs after transforms

pub const CheckMode = enum {
    /// Frontend mode: Syntactic checks that can run before transforms
    /// Checks: KORU050/051 (when-clause exhaustiveness), KORU100 (unused binding, skips [transform] invocations)
    frontend,

    /// Full mode: All checks including branch coverage
    /// Must run after transforms are applied (backend)
    /// Checks: KORU100 (for transform invocations), KORU021 (unknown branch), KORU022 (missing branch)
    all,
};

pub const FlowChecker = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    ast_items: ?[]const ast.Item,  // Full AST for event lookups
    mode: CheckMode,

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
                    }
                },
                .module_decl => |*module| {
                    // Validate flows in imported modules
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .flow => |*flow| {
                                try self.validateFlow(flow, flow.location);
                            },
                            .proc_decl => {},
                            .immediate_impl => |*ii| {
                                if (self.mode == .frontend) {
                                    try self.checkBranchConstructorPurity(&ii.value, ii.location);
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

        // Check for duplicate branch handlers at each level
        if (!is_transform_flow) {
            try self.checkDuplicateBranchHandlers(flow.body.continuations, location);
        }

        // Skip when-clause checks for transformed flows (structure has changed)
        // Also skip for transform invocations (like ~tap) which use fan-out semantics
        if (!is_transformed and !is_transform_flow) {
            // Validate when-clause exhaustiveness for all continuations (KORU050, KORU051)
            try self.validateWhenClauseExhaustiveness(flow.body.continuations, location);
        }

        // Recursively validate nested continuations and bindings
        // KORU100 runs even for transformed flows - checks inside ForeachNode etc.
        for (flow.body.continuations) |*cont| {
            if (!is_transformed) {
                try self.validateContinuationWhenClauses(cont, location);
            }
            // KORU100: Unused binding check
            // In frontend mode, skip for [transform] invocations (binding usage not visible until after transform)
            // In backend mode (all), check everything (transforms have run)
            try self.validateBindingUsage(cont);
        }

        // === BACKEND CHECKS (semantic, require event lookups and transforms) ===

        // KORU110: bare ~proc declarations (no |variant) are unresolvable.
        // Walk all invocations in this flow and flag any whose event resolves
        // only to bare procs. Runs in both modes — it's a structural rule.
        if (!is_transformed) {
            try self.validateInvocationResolution(flow);
        }

        if (self.mode == .all and !is_transformed) {
            // Validate branch coverage (KORU021, KORU022)
            // Only run in 'all' mode - requires transforms to be applied first
            // Skip for transformed flows - their branch structure has changed
            try self.validateBranchCoverage(flow, location);
        }
    }

    // =========================================================================
    // KORU104 — the expression-admission wall.
    //
    // An expression admits atoms, operators, and builtins — never a call.
    // Composition lives in the flow via explicit binds (`event(args): x |>`),
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
            "nested call in {s} — calls are not expressions; use event chaining: bind the result first",
            .{surface},
            "rewrite as `event(args): x |> ...` and use `x` here",
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
                for (lj.args) |*arg| try self.checkArgPurity(arg, location);
            },
            .deref => |*d| {
                if (d.args) |args| for (args) |*arg| try self.checkArgPurity(arg, location);
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
        for (inv.args) |*arg| {
            if (arg.source_value) |sv| {
                if (is_capture_family) try self.checkCaptureFieldsPurity(sv.text, location);
                continue;
            }
            try self.checkArgPurity(arg, location);
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

    fn checkArgPurity(self: *FlowChecker, arg: *const ast.Arg, location: errors.SourceLocation) anyerror!void {
        // Source-typed arguments are opaque code blocks by design (the
        // metaprogramming surface) — the wall does not judge them. (Capture-
        // family sources are handled field-wise in checkInvocationArgsPurity.)
        if (arg.source_value != null) return;
        // Declared-Expression parameters are the comptime QUOTING surface:
        // the text is captured verbatim and handed to a transform proc as
        // data — it never executes in this flow, so call-shaped text there
        // is not a call. (parser sets expression_value exactly when the
        // event's field is declared `Expression`.)
        if (arg.expression_value != null) return;
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
    /// is a separate design decision (see MULTI_VARIANT_PLAN.md).
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
                "event '{s}' is called but its ~proc declaration has no |variant tag — bare procs are unresolvable",
                .{event_name},
                "tag the proc with a host: `~proc {s}|zig {{ ... }}` (or another host like |gpu, |js)",
                .{event_name},
            );
        }
    }

    fn validateBindingUsage(self: *FlowChecker, cont: *const ast.Continuation) !void {
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
                const deferred = self.isDeferredBindingInvocation(cont);
                const skip_check = is_template_proc or switch (self.mode) {
                    .frontend => deferred,
                    .all => !deferred,
                };

                if (!skip_check and !self.isBindingUsed(cont, binding)) {
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

        // Destructured fields are bindings too: each named field must be
        // used (or spelled `_` to discard the slot). Same deferred-binding
        // skip as above — transform/scope constructs consume bindings later.
        if (cont.destructure.len > 0) {
            const skip_check = self.mode == .frontend and self.isDeferredBindingInvocation(cont);
            if (!skip_check) {
                try self.validateDestructureUsage(cont, cont.destructure);
            }
        }

        // Recursively check nested continuations
        for (cont.continuations) |*nested| {
            try self.validateBindingUsage(nested);
        }

        // Also check inside ForeachNode and ConditionalNode branches
        if (cont.node) |node| {
            if (node == .foreach) {
                for (node.foreach.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        try self.validateBindingUsage(body_cont);
                    }
                }
            } else if (node == .conditional) {
                for (node.conditional.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        try self.validateBindingUsage(body_cont);
                    }
                }
            }
        }
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

    /// True if `path` resolves to a proc whose variant chain begins with
    /// `template` (`|template|zig`, `|template(once)|js`, …). The proc body is a
    /// template rendered in a later pass, so any binding it consumes is not yet
    /// visible to the frontend unused-binding check. Matches on the path's last
    /// segment — sufficient for the single-module programs this guards.
    fn invocationResolvesToTemplateProc(self: *FlowChecker, path: *const ast.DottedPath) bool {
        const items = self.ast_items orelse return false;
        if (path.segments.len == 0) return false;
        const target_name = path.segments[path.segments.len - 1];

        const isTemplateTarget = struct {
            fn check(target: ?[]const u8) bool {
                const t = target orelse return false;
                if (!std.mem.startsWith(u8, t, "template")) return false;
                // Must be the whole first tag: `template` then `|`, `(`, or end.
                return t.len == "template".len or t["template".len] == '|' or t["template".len] == '(';
            }
        }.check;

        const matchProc = struct {
            fn check(proc_items: []const ast.Item, name: []const u8, isTmpl: anytype) bool {
                for (proc_items) |*item| {
                    switch (item.*) {
                        .proc_decl => |*pd| {
                            if (pd.path.segments.len == 0) continue;
                            const pd_name = pd.path.segments[pd.path.segments.len - 1];
                            if (std.mem.eql(u8, pd_name, name) and isTmpl(pd.target)) return true;
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

        return matchProc(items, target_name, isTemplateTarget);
    }

    /// Check if a flow's top-level invocation is a transform event (like ~tap)
    /// Transform flows use fan-out semantics: multiple handlers for the same branch all fire
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
            .deref => |deref| {
                if (containsIdentifier(deref.target, binding)) return true;
                if (deref.args) |args| {
                    for (args) |arg| {
                        if (containsIdentifier(arg.value, binding)) return true;
                    }
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
            try self.validateWhenClauseExhaustiveness(cont.continuations, location);

            // Recursively validate deeper nesting
            for (cont.continuations) |*nested| {
                try self.validateContinuationWhenClauses(nested, location);
            }
        }
    }

    fn validateWhenClauseExhaustiveness(self: *FlowChecker, continuations: []const ast.Continuation, location: errors.SourceLocation) !void {
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
                // ERROR: Not exhaustive - missing else case
                log.debug("ERROR: Branch '{s}' has {d} when-clauses but no else case (non-exhaustive)\n",
                    .{branch_name, branch_continuations.len});
                try self.reporter.addError(
                    .KORU050,
                    location.line,
                    location.column,
                    "branch '{s}' has multiple when-clauses but no else case - add one continuation without 'when'",
                    .{branch_name}
                );
            } else if (else_count > 1) {
                // ERROR: Ambiguous - multiple else cases
                log.debug("ERROR: Branch '{s}' has {d} else cases (ambiguous)\n",
                    .{branch_name, else_count});
                try self.reporter.addError(
                    .KORU051,
                    location.line,
                    location.column,
                    "branch '{s}' has {d} continuations without 'when' (ambiguous) - only one else case allowed",
                    .{branch_name, else_count}
                );
            }
            // else: exactly one else case - valid!
        }
    }

    /// Validate branch coverage: all required branches must be handled
    /// NOTE: This check should only run AFTER transforms are applied (mode == .all)
    /// because transform events replace flows entirely.
    fn validateBranchCoverage(self: *FlowChecker, flow: *const ast.Flow, location: errors.SourceLocation) !void {
        // Find the event definition for this flow
        const event_decl = self.findEventDecl(&flow.inv().path) orelse {
            // Event not found - this is a shape checker error, not flow checker
            // Just skip branch coverage validation
            return;
        };

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
            flow.body.continuations.len,
        );
        defer handled.deinit(self.allocator);

        for (flow.body.continuations) |*cont| {
            // Skip empty branch names - these are void event chains (|> event())
            // where branches are not explicitly handled
            if (cont.branch.len == 0) continue;

            try handled.append(self.allocator, .{
                .name = cont.branch,
                .has_when_guard = cont.condition != null,
                .is_catchall = cont.is_catchall,
            });
        }

        // Validate using pure BranchChecker
        var result = try branch_checker.BranchChecker.validate(
            self.allocator,
            declared.items,
            handled.items,
        );
        defer branch_checker.BranchChecker.freeResult(self.allocator, &result);

        // Report errors for missing branches
        if (result.missing_branches.len > 0) {
            const event_name = if (event_decl.path.segments.len > 0)
                event_decl.path.segments[event_decl.path.segments.len - 1]
            else
                "(unknown)";

            for (result.missing_branches) |branch_name| {
                log.debug("ERROR: Required branch '{s}' not handled in flow invoking '{s}'\n",
                    .{branch_name, event_name});
                try self.reporter.addError(
                    .KORU022,
                    location.line,
                    location.column,
                    "required branch '{s}' not handled - event '{s}' requires this branch",
                    .{branch_name, event_name},
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

        // Fail if any branch coverage errors were found
        if (self.reporter.hasErrors()) {
            return error.FlowValidationFailed;
        }
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

    /// Check for duplicate branch handlers at the same level (indentation error)
    /// This catches patterns like:
    ///   | done sum |> multiply(...)
    ///   | done product |> done { ... }
    /// Where both | done are at the same indent but the second should be nested under the first.
    fn checkDuplicateBranchHandlers(self: *FlowChecker, continuations: []const ast.Continuation, location: errors.SourceLocation) !void {
        // Check for duplicates at this level
        for (continuations, 0..) |cont, i| {
            for (continuations[i + 1 ..]) |other| {
                if (std.mem.eql(u8, cont.branch, other.branch)) {
                    // When-clauses allow multiple handlers for the same branch:
                    //   | high h when (h.x > 10) |> ...
                    //   | high h when (h.x > 5) |> ...
                    //   | high |> ...  (else case)
                    if (cont.condition != null or other.condition != null) continue;

                    // Found duplicate branch at same level - this is an error
                    try self.reporter.addError(
                        .SHAPE002,
                        location.line,
                        location.column,
                        "duplicate handler for branch '{s}' at same indentation level - if the second handles a chained event's result, indent it further",
                        .{cont.branch},
                    );
                    return error.DuplicateBranchHandler;
                }
            }
        }

        // Recursively check nested continuations
        for (continuations) |cont| {
            // A transformed subtree (capture's grafted `''` void-chain) carries
            // the transform exemption — its synthesized children are not
            // user-authored branches, so the duplicate-handler rule does not
            // apply. Mirrors the flow-level `is_transform_flow` skip.
            if (cont.is_transformed_subtree) continue;
            if (cont.continuations.len > 0) {
                try self.checkDuplicateBranchHandlers(cont.continuations, location);
            }
        }
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
    try checker.validateWhenClauseExhaustiveness(&continuations, location);

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
    try checker.validateWhenClauseExhaustiveness(&continuations, location);

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
    try checker.validateWhenClauseExhaustiveness(&continuations, location);

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
    try checker.validateWhenClauseExhaustiveness(&continuations, location);

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
