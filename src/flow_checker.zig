const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const branch_checker = @import("branch_checker");
const annotation_parser = @import("annotation_parser");

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
                .subflow_impl => |*subflow| {
                    // Validate subflow implementations (e.g., ~event_name = for(...))
                    if (subflow.body == .flow) {
                        try self.validateFlow(&subflow.body.flow, subflow.body.flow.location);
                    }
                },
                .proc_decl => |*proc| {
                    // Check inline flows in proc declarations for duplicate branch handlers
                    // Only in backend mode (semantic check that may need transforms applied)
                    if (self.mode == .all) {
                        for (proc.inline_flows) |*inline_flow| {
                            try self.checkDuplicateBranchHandlers(inline_flow.continuations, inline_flow.location);
                        }
                    }
                },
                .module_decl => |*module| {
                    // Validate flows in imported modules
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .flow => |*flow| {
                                try self.validateFlow(flow, flow.location);
                            },
                            .subflow_impl => |*subflow| {
                                if (subflow.body == .flow) {
                                    try self.validateFlow(&subflow.body.flow, subflow.body.flow.location);
                                }
                            },
                            .proc_decl => |*proc| {
                                // Only in backend mode
                                if (self.mode == .all) {
                                    for (proc.inline_flows) |*inline_flow| {
                                        try self.checkDuplicateBranchHandlers(inline_flow.continuations, inline_flow.location);
                                    }
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

        // === FRONTEND CHECKS (syntactic, always run) ===
        // These run even for transformed flows

        // Skip when-clause checks for transformed flows (structure has changed)
        if (!is_transformed) {
            // Validate when-clause exhaustiveness for all continuations (KORU050, KORU051)
            try self.validateWhenClauseExhaustiveness(flow.continuations, location);
        }

        // Recursively validate nested continuations and bindings
        // KORU100 runs even for transformed flows - checks inside ForeachNode etc.
        for (flow.continuations) |*cont| {
            if (!is_transformed) {
                try self.validateContinuationWhenClauses(cont, location);
            }
            // KORU100: Unused binding check
            // In frontend mode, skip for [transform] invocations (binding usage not visible until after transform)
            // In backend mode (all), check everything (transforms have run)
            try self.validateBindingUsage(cont);
        }

        // === BACKEND CHECKS (semantic, require event lookups and transforms) ===

        if (self.mode == .all and !is_transformed) {
            // Validate branch coverage (KORU021, KORU022)
            // Only run in 'all' mode - requires transforms to be applied first
            // Skip for transformed flows - their branch structure has changed
            try self.validateBranchCoverage(flow, location);
        }
    }

    fn validateBindingUsage(self: *FlowChecker, cont: *const ast.Continuation) !void {
        // If this continuation has a binding (other than _ or _auto_*), check if it's used
        // Bindings starting with _ are explicit discards or synthetic bindings from auto-dispose
        if (cont.binding) |binding| {
            if (!std.mem.startsWith(u8, binding, "_")) {
                // In frontend mode, skip check if node is a [transform] invocation
                // (transforms consume bindings in ways not visible until after transform runs)
                const skip_check = self.mode == .frontend and self.isTransformInvocation(cont);

                if (!skip_check and !self.isBindingUsed(cont, binding)) {
                    // ERROR: Unused binding
                    try self.reporter.addErrorWithHint(
                        .KORU100,
                        cont.location.line,
                        cont.location.column,
                        "unused binding '{s}'",
                        .{binding},
                        "remove the binding if not needed",
                        .{},
                    );
                }
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

    /// Check if a continuation's node is an invocation of a [transform] event
    fn isTransformInvocation(self: *FlowChecker, cont: *const ast.Continuation) bool {
        const node = cont.node orelse return false;
        if (node != .invocation) return false;

        const inv = node.invocation;

        // Look up the event declaration to check for [transform] annotation
        if (self.findEventDecl(&inv.path)) |event_decl| {
            return annotation_parser.hasPart(event_decl.annotations, "transform");
        }

        return false;
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
            },
            .branch_constructor => |bc| {
                for (bc.fields) |field| {
                    const value = if (field.expression_str) |expr| expr else field.type;
                    if (containsIdentifier(value, binding)) return true;
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
            .capture => |cap| {
                if (containsIdentifier(cap.init_expr, binding)) return true;
                for (cap.branches) |*branch| {
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
                std.debug.print("ERROR: Branch '{s}' has {d} when-clauses but no else case (non-exhaustive)\n",
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
                std.debug.print("ERROR: Branch '{s}' has {d} else cases (ambiguous)\n",
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
        const event_decl = self.findEventDecl(&flow.invocation.path) orelse {
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
            });
        }

        // Convert continuations to BranchChecker format
        var handled = try std.ArrayList(branch_checker.BranchChecker.HandledBranch).initCapacity(
            self.allocator,
            flow.continuations.len,
        );
        defer handled.deinit(self.allocator);

        for (flow.continuations) |*cont| {
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
                std.debug.print("ERROR: Required branch '{s}' not handled in flow invoking '{s}'\n",
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
            std.debug.print("ERROR: Unknown branch '{s}' - event has no such branch\n", .{branch_name});
            try self.reporter.addError(
                .KORU021,
                location.line,
                location.column,
                "unknown branch '{s}' - event has no such branch",
                .{branch_name},
            );
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
