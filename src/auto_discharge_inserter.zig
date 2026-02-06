// Auto-Dispose Inserter - Inserts disposal calls before flow terminators
const log = @import("log");
//
// This pass runs BEFORE phantom_semantic_checker. It:
// 1. Tracks binding contexts and their phantom obligations
// 2. At flow terminators, checks for unsatisfied obligations
// 3. For exactly 1 disposal option: inserts the call
// 4. For 0 or >1 options: produces an error
//
// The checker then validates normally (acts as safety net).

const std = @import("std");
const ast = @import("ast");
const ast_functional = @import("ast_functional");
const errors = @import("errors");
const phantom_parser = @import("phantom_parser");

pub const AutoDischargeInserter = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    event_map: std.StringHashMap(EventInfo),
    synthetic_binding_counter: u32,
    warn_mode: bool, // When true, emit warnings about auto-inserted disposals

    /// Error set for recursive functions that need explicit error types
    pub const RecursiveError = std.mem.Allocator.Error || error{ ValidationFailed, NoSpaceLeft };

    /// Information about an event's phantom annotations
    const EventInfo = struct {
        decl: *const ast.EventDecl,
        module_name: []const u8,
    };

    /// A disposal event that can satisfy an obligation
    const DisposalEvent = struct {
        qualified_name: []const u8,
        event_decl: *const ast.EventDecl,
        field_name: []const u8,
        is_default: bool, // Has [!] annotation - preferred for auto-discharge
    };

    /// Check if a continuation has @scope annotation (marks scope boundary)
    fn hasScope(cont: *const ast.Continuation) bool {
        for (cont.binding_annotations) |ann| {
            if (std.mem.eql(u8, ann, "@scope")) return true;
        }
        return false;
    }

    /// Check if a NamedBranch has @scope annotation (marks scope boundary)
    fn branchHasScope(branch: *const ast.NamedBranch) bool {
        for (branch.annotations) |ann| {
            if (std.mem.eql(u8, ann, "@scope")) return true;
        }
        return false;
    }

    /// Check if a binding escapes via a branch constructor field
    /// Returns true if the binding (or binding.field) appears in any field value
    fn bindingEscapesViaBranchConstructor(bc: *const ast.BranchConstructor, binding_name: []const u8) bool {
        for (bc.fields) |field| {
            // Check if field expression_str references the binding
            // e.g., binding "f" matches field expression "f.file" or just "f"
            const value = field.expression_str orelse continue;
            if (std.mem.startsWith(u8, value, binding_name)) {
                // Make sure it's the actual binding, not a prefix match
                // "f.file" starts with "f", and next char is '.' or end of string
                if (value.len == binding_name.len) {
                    return true; // Exact match
                }
                if (value.len > binding_name.len and value[binding_name.len] == '.') {
                    return true; // Binding.field pattern
                }
            }
        }
        return false;
    }

    /// Binding context tracks phantom states of variables in scope
    const BindingContext = struct {
        bindings: std.StringHashMap([]const u8), // variable name → phantom state
        cleanup_obligations: std.StringHashMap(BindingInfo), // binding → obligation info
        allocator: std.mem.Allocator,
        scope_depth: u32, // Current scope depth (increments when entering loop body)
        is_repeating: bool, // True if we're inside a loop's `each` branch
        loop_entry_scope: ?u32, // Scope depth when we entered current @scope boundary (null if not in scope)

        const BindingInfo = struct {
            phantom_state: []const u8,
            field_name: []const u8, // e.g., "file" for f.file
            scope_depth: u32, // Scope where obligation was created
        };

        fn init(allocator: std.mem.Allocator) BindingContext {
            return .{
                .bindings = std.StringHashMap([]const u8).init(allocator),
                .cleanup_obligations = std.StringHashMap(BindingInfo).init(allocator),
                .allocator = allocator,
                .scope_depth = 0,
                .is_repeating = false,
                .loop_entry_scope = null,
            };
        }

        fn deinit(self: *BindingContext) void {
            var iter = self.bindings.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.bindings.deinit();

            var obl_iter = self.cleanup_obligations.iterator();
            while (obl_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.phantom_state);
                self.allocator.free(entry.value_ptr.field_name);
            }
            self.cleanup_obligations.deinit();
        }

        /// Add a binding with its phantom state
        fn addBinding(self: *BindingContext, name: []const u8, phantom_state: []const u8, field_name: []const u8) !void {
            const name_copy = try self.allocator.dupe(u8, name);
            const phantom_copy = try self.allocator.dupe(u8, phantom_state);

            try self.bindings.put(name_copy, phantom_copy);

            // Check if this has a cleanup obligation (! suffix)
            if (std.mem.endsWith(u8, phantom_state, "!")) {
                const field_copy = try self.allocator.dupe(u8, field_name);
                const obl_key = try self.allocator.dupe(u8, name);
                try self.cleanup_obligations.put(obl_key, .{
                    .phantom_state = try self.allocator.dupe(u8, phantom_state),
                    .field_name = field_copy,
                    .scope_depth = self.scope_depth, // Record which scope created this obligation
                });
            }
        }

        /// Clear a cleanup obligation (when it's been satisfied)
        fn clearObligation(self: *BindingContext, name: []const u8) void {
            if (self.cleanup_obligations.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.phantom_state);
                self.allocator.free(kv.value.field_name);
            }
        }

        /// Check if there are unsatisfied obligations
        fn hasObligations(self: *BindingContext) bool {
            return self.cleanup_obligations.count() > 0;
        }

        /// Get iterator over obligations
        fn obligations(self: *BindingContext) std.StringHashMap(BindingInfo).Iterator {
            return self.cleanup_obligations.iterator();
        }

        /// Clone context for branch exploration
        fn clone(self: *const BindingContext, allocator: std.mem.Allocator) !BindingContext {
            var new_ctx = BindingContext.init(allocator);
            new_ctx.scope_depth = self.scope_depth;
            new_ctx.is_repeating = self.is_repeating;
            new_ctx.loop_entry_scope = self.loop_entry_scope;

            var bind_iter = self.bindings.iterator();
            while (bind_iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try allocator.dupe(u8, entry.value_ptr.*);
                try new_ctx.bindings.put(key, val);
            }

            var obl_iter = self.cleanup_obligations.iterator();
            while (obl_iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try new_ctx.cleanup_obligations.put(key, .{
                    .phantom_state = try allocator.dupe(u8, entry.value_ptr.phantom_state),
                    .field_name = try allocator.dupe(u8, entry.value_ptr.field_name),
                    .scope_depth = entry.value_ptr.scope_depth,
                });
            }

            return new_ctx;
        }

        /// Enter a loop construct (records scope at loop entry)
        fn enterLoop(self: *BindingContext) void {
            if (self.loop_entry_scope == null) {
                self.loop_entry_scope = self.scope_depth;
            }
        }

        /// Enter a new scope (for @scope boundaries - loops, taps, custom constructs)
        fn enterScope(self: *BindingContext, is_scoped: bool) void {
            self.scope_depth += 1;
            // is_scoped means we're inside a @scope boundary - outer resources cannot be discharged here
            self.is_repeating = is_scoped;
            // Record scope entry point when entering a @scope boundary
            if (is_scoped and self.loop_entry_scope == null) {
                self.loop_entry_scope = self.scope_depth;
            }
        }

        /// Check if there are obligations from before we entered the current loop
        fn hasPreLoopObligations(self: *BindingContext) bool {
            const entry_scope = self.loop_entry_scope orelse return false;
            var iter = self.cleanup_obligations.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.scope_depth < entry_scope) return true;
            }
            return false;
        }

        /// Get first pre-loop obligation for error message
        fn getFirstPreLoopObligation(self: *BindingContext) ?struct { name: []const u8, state: []const u8 } {
            const entry_scope = self.loop_entry_scope orelse return null;
            var iter = self.cleanup_obligations.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.scope_depth < entry_scope) {
                    return .{ .name = entry.key_ptr.*, .state = entry.value_ptr.phantom_state };
                }
            }
            return null;
        }

        /// Check if there are obligations from outer scopes that would need disposal
        fn hasOuterScopeObligations(self: *BindingContext) bool {
            var iter = self.cleanup_obligations.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.scope_depth < self.scope_depth) {
                    return true;
                }
            }
            return false;
        }

        /// Get obligations from current scope only
        fn currentScopeObligations(self: *BindingContext) std.StringHashMap(BindingInfo).Iterator {
            // Note: Caller must filter by scope_depth
            return self.cleanup_obligations.iterator();
        }
    };

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter, warn_mode: bool) !AutoDischargeInserter {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .event_map = std.StringHashMap(EventInfo).init(allocator),
            .synthetic_binding_counter = 0,
            .warn_mode = warn_mode,
        };
    }

    pub fn deinit(self: *AutoDischargeInserter) void {
        var iter = self.event_map.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.event_map.deinit();
    }

    /// Main entry point - run the auto-discharge pass on a program
    pub fn run(self: *AutoDischargeInserter, program: *const ast.Program) !*const ast.Program {
        // Step 1: Build event map
        try self.buildEventMap(program);

        // Check for validation errors (e.g., [!] on branched events)
        if (self.reporter.hasErrors()) {
            const stderr_writer = std.debug.lockStderrWriter(&.{});
            defer std.debug.unlockStderrWriter();
            try self.reporter.printErrors(stderr_writer);
            return error.ValidationFailed;
        }

        // Step 2: Transform all flows (structural + terminator disposals)
        var current_program = program;
        var iteration: u32 = 0;
        const max_iterations: u32 = 100000;

        while (iteration < max_iterations) : (iteration += 1) {
            const result = try self.transformOneFlow(current_program, .full);
            if (result.transformed) {
                current_program = result.program;
            } else {
                // No more transformations needed
                break;
            }
        }

        // Step 3: Scope-exit insertion pass on a stable tree
        iteration = 0;
        while (iteration < max_iterations) : (iteration += 1) {
            const result = try self.transformOneFlow(current_program, .scope_exit_only);
            if (result.transformed) {
                current_program = result.program;
            } else {
                break;
            }
        }

        return current_program;
    }

    /// Build map of all events and their phantom annotations
    fn buildEventMap(self: *AutoDischargeInserter, program: *const ast.Program) !void {
        // IMPORTANT: Use |*item| to get pointers into the actual slice, not copies!
        for (program.items) |*item| {
            switch (item.*) {
                .event_decl => {
                    const event_decl = &item.event_decl;
                    const event_name = try self.pathToString(event_decl.path);
                    defer self.allocator.free(event_name);

                    // Validate: [!] annotation requires auto-dischargeable event (0 or 1 branches)
                    if (eventHasDefaultAnnotation(event_decl) and event_decl.branches.len > 1) {
                        try self.reporter.addError(
                            .KORU083,
                            event_decl.location.line,
                            event_decl.location.column,
                            "[!] annotation requires single-outcome event - events with multiple branches require manual handling",
                            .{},
                        );
                    }

                    const qualified_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}:{s}",
                        .{ event_decl.module, event_name },
                    );
                    try self.event_map.put(qualified_name, .{
                        .decl = event_decl,
                        .module_name = event_decl.module,
                    });
                },
                .module_decl => {
                    const module = &item.module_decl;
                    // Also need pointers here!
                    for (module.items) |*mod_item| {
                        if (mod_item.* == .event_decl) {
                            const event_decl = &mod_item.event_decl;
                            const event_name = try self.pathToString(event_decl.path);
                            defer self.allocator.free(event_name);

                            // Validate: [!] annotation requires void event (no branches)
                            if (eventHasDefaultAnnotation(event_decl) and event_decl.branches.len > 0) {
                                try self.reporter.addError(
                                    .KORU083,
                                    event_decl.location.line,
                                    event_decl.location.column,
                                    "[!] annotation requires void event (no branches) - branched events cannot be auto-discharged",
                                    .{},
                                );
                            }

                            const qualified_name = try std.fmt.allocPrint(
                                self.allocator,
                                "{s}:{s}",
                                .{ module.logical_name, event_name },
                            );
                            try self.event_map.put(qualified_name, .{
                                .decl = event_decl,
                                .module_name = module.logical_name,
                            });
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// Result of attempting to transform a flow
    const TransformResult = struct {
        transformed: bool,
        program: *const ast.Program,
    };

    const TransformMode = enum {
        full,
        scope_exit_only,
    };

    /// Try to find and transform one flow that needs auto-discharge
    fn transformOneFlow(
        self: *AutoDischargeInserter,
        program: *const ast.Program,
        mode: TransformMode,
    ) !TransformResult {
        // Walk all items looking for flows with unsatisfied obligations at terminators
        // IMPORTANT: Use |*item| to get pointers into the actual slice!
        for (program.items, 0..) |*item, item_idx| {
            switch (item.*) {
                .flow => {
                    const flow = &item.flow;
                    const result = try self.checkAndTransformFlow(flow, program, item_idx, mode);
                    if (result.transformed) return result;
                },
                .subflow_impl => {
                    const subflow = &item.subflow_impl;
                    if (subflow.body == .flow) {
                        const flow = &subflow.body.flow;
                        const result = try self.checkAndTransformFlow(flow, program, item_idx, mode);
                        if (result.transformed) return result;
                    }
                },
                .module_decl => {
                    const module = &item.module_decl;
                    for (module.items, 0..) |*mod_item, mod_item_idx| {
                        _ = mod_item_idx;
                        if (mod_item.* == .flow) {
                            const flow = &mod_item.flow;
                            const result = try self.checkAndTransformFlow(flow, program, item_idx, mode);
                            if (result.transformed) return result;
                        } else if (mod_item.* == .subflow_impl) {
                            const subflow = &mod_item.subflow_impl;
                            if (subflow.body == .flow) {
                                const flow = &subflow.body.flow;
                                const result = try self.checkAndTransformFlow(flow, program, item_idx, mode);
                                if (result.transformed) return result;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a flow for obligations at terminators and transform if needed
    fn checkAndTransformFlow(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        program: *const ast.Program,
        _: usize,
        mode: TransformMode,
    ) !TransformResult {
        if (mode == .full) {
            // Skip already-processed flows
            for (flow.invocation.annotations) |ann| {
                if (std.mem.startsWith(u8, ann, "@auto_discharge_ran")) {
                    return .{ .transformed = false, .program = program };
                }
            }
        }

        // Get event info for this flow
        const event_name = try self.pathToString(flow.invocation.path);
        defer self.allocator.free(event_name);

        const module_name = flow.invocation.path.module_qualifier orelse flow.module;
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_name });
        defer self.allocator.free(qualified_name);

        const event_info = self.event_map.get(qualified_name) orelse {
            return .{ .transformed = false, .program = program };
        };

        // Synthesize continuations for unhandled optional branches
        // This ensures all optional branches get switch cases and auto-discharge can handle them
        if (mode == .full) {
            if (try self.synthesizeOptionalBranches(flow, event_info.decl)) |new_flow| {
                // Replace the flow in the program with the synthesized version
                const new_program = try ast_functional.replaceFlowRecursive(
                    self.allocator,
                    program,
                    flow,
                    .{ .flow = new_flow.* },
                ) orelse {
                    return .{ .transformed = false, .program = program };
                };

                const result_ptr = try self.allocator.create(ast.Program);
                result_ptr.* = new_program;
                return .{ .transformed = true, .program = result_ptr };
            }
        }

        // Walk continuations looking for terminators with obligations
        var context = BindingContext.init(self.allocator);
        defer context.deinit();

        for (flow.continuations) |*cont| {
            // If this continuation has @scope annotation, enter a new scope
            // The @scope annotation is the source of truth - not the event name
            if (hasScope(cont)) {
                var scoped_context = try context.clone(self.allocator);
                defer scoped_context.deinit();
                scoped_context.enterScope(true); // @scope means we're in a scoped boundary

                const result = try self.checkContinuation(cont, event_info.decl, module_name, &scoped_context, program, flow, mode);
                if (result.transformed) return result;

                if (mode == .scope_exit_only) {
                    // SCOPE EXIT: Check for remaining obligations in this scoped continuation
                    if (scoped_context.hasObligations()) {
                        var obl_iter = scoped_context.obligations();
                        while (obl_iter.next()) |entry| {
                            const binding_name = entry.key_ptr.*;
                            const info = entry.value_ptr.*;

                            const disposals = try self.findDisposalEvents(info.phantom_state);
                            defer self.allocator.free(disposals);

                            const disposal = selectDisposal(disposals) orelse {
                                if (disposals.len == 0) {
                                    try self.reporter.addError(
                                        .KORU030,
                                        flow.location.line,
                                        flow.location.column,
                                        "No disposal event found for resource '{s}' with state '{s}' at scope exit.",
                                        .{ binding_name, info.phantom_state },
                                    );
                                } else {
                                    try self.reporter.addError(
                                        .KORU030,
                                        flow.location.line,
                                        flow.location.column,
                                        "Multiple disposal options for resource '{s}' at scope exit. Discharge explicitly in your code.",
                                        .{binding_name},
                                    );
                                }
                                return error.ValidationFailed;
                            };

                            // Find the continuation with this binding and insert disposal
                            const scope_exit_result = try self.insertScopeExitDisposalInCont(
                                cont,
                                binding_name,
                                disposal,
                                program,
                                flow,
                            );
                            if (scope_exit_result.transformed) return scope_exit_result;
                        }
                    }
                }
            } else {
                const result = try self.checkContinuation(cont, event_info.decl, module_name, &context, program, flow, mode);
                if (result.transformed) return result;
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a continuation for terminators with obligations
    fn checkContinuation(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        event_decl: *const ast.EventDecl,
        module_name: []const u8,
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        mode: TransformMode,
    ) !TransformResult {
        // Clone context for this branch
        var context = try parent_context.clone(self.allocator);
        defer context.deinit();

        // Handle discard binding (_) - synthesize a real binding name
        // This must happen BEFORE we process the continuation so the binding can be used
        if (mode == .full) {
            if (cont.binding) |binding_name| {
                if (std.mem.eql(u8, binding_name, "_")) {
                    // Generate synthetic binding to replace _
                    const synthetic_name = try self.generateSyntheticBinding();

                    // Clone the continuation with the new binding (preserves all metadata)
                    const new_cont = try self.cloneContinuationWithBinding(cont, synthetic_name);

                    // Replace this continuation in the flow
                    const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont.*);

                    // Replace the flow in the program
                    const new_program = try ast_functional.replaceFlowRecursive(
                        self.allocator,
                        program,
                        flow,
                        .{ .flow = new_flow },
                    ) orelse {
                        return .{ .transformed = false, .program = program };
                    };

                    const result_ptr = try self.allocator.create(ast.Program);
                    result_ptr.* = new_program;

                    // Return transformed - the next iteration will process with the real binding
                    return .{ .transformed = true, .program = result_ptr };
                }
            }
        }

        // Add bindings from this branch
        if (cont.binding) |binding_name| {
            // Find the branch in the event declaration
            for (event_decl.branches) |branch| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    // Add each field with phantom annotation
                    for (branch.payload.fields) |field| {
                        if (field.phantom) |phantom_str| {
                            // For identity branches (field name is __type_ref),
                            // use just the binding name since the value IS the binding
                            // For struct branches, use binding.field_name
                            const is_identity = std.mem.eql(u8, field.name, "__type_ref");
                            const field_path = if (is_identity)
                                try self.allocator.dupe(u8, binding_name)
                            else
                                try std.fmt.allocPrint(
                                    self.allocator,
                                    "{s}.{s}",
                                    .{ binding_name, field.name },
                                );
                            defer self.allocator.free(field_path);

                            // Canonicalize phantom state with module
                            const canonical = try self.canonicalizePhantom(phantom_str, module_name);
                            defer self.allocator.free(canonical);

                            try context.addBinding(field_path, canonical, field.name);
                        }
                    }
                    break;
                }
            }
        }

        // Check if this continuation has a terminal node or branch constructor
        // Both are flow terminators that should trigger auto-discharge
        if (cont.node) |node| {
            const is_terminator = (node == .terminal or node == .branch_constructor);
            if (is_terminator) {
                // Found a terminator - check for unsatisfied obligations
                // Only dispose obligations from CURRENT scope
                // Outer-scope obligations will be handled at a non-repeating terminal (like `done`)

                // IMPORTANT: For branch_constructor, check if obligations ESCAPE via the return fields
                // If an obligation is returned (e.g., got_file { file: f.file }), it should NOT be disposed
                if (node == .branch_constructor) {
                    const bc = &node.branch_constructor;
                    // Collect escaping bindings (max 16 should be plenty)
                    var escaping_bindings: [16][]const u8 = undefined;
                    var escaping_count: usize = 0;

                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (bindingEscapesViaBranchConstructor(bc, entry.key_ptr.*)) {
                            if (escaping_count < 16) {
                                escaping_bindings[escaping_count] = entry.key_ptr.*;
                                escaping_count += 1;
                            }
                        }
                    }

                    // Remove escaping obligations (they transfer to the caller)
                    for (escaping_bindings[0..escaping_count]) |binding| {
                        _ = context.cleanup_obligations.remove(binding);
                    }
                }

                if (context.hasObligations()) {
                    // Count how many obligations are from current scope
                    var current_scope_count: u32 = 0;
                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (entry.value_ptr.scope_depth == context.scope_depth) {
                            current_scope_count += 1;
                        }
                    }

                    if (mode == .full) {
                        if (current_scope_count > 0) {
                            // We have current-scope obligations to dispose
                            return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                        }
                        // Outer-scope obligations exist but not current-scope ones
                        // In a repeating context, this is OK - they'll be handled at `done`
                        // In a non-repeating context, they should be disposed here
                        if (!context.is_repeating) {
                            // Non-repeating: dispose all remaining obligations
                            return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                        }
                        // Repeating: outer obligations will flow through to `done`
                    }
                }
            }

            // Check invocations for obligation satisfaction
            // (when binding is passed to [!state] parameter)
            if (node == .invocation) {
                try self.checkInvocationSatisfiesObligations(&context, &node.invocation, module_name, flow);
            }

            // Handle foreach nodes - recurse into branches with scope tracking
            if (node == .foreach) {
                const result = try self.checkForeachNode(node.foreach.branches, &context, program, flow, module_name, mode);
                if (result.transformed) return result;
            }

            // Handle conditional nodes - recurse into branches WITHOUT cloning
            // Conditionals run exactly one branch, so obligation clearing in any branch
            // should propagate to the parent context (use checkForeachBranchContinuation
            // which doesn't clone, unlike checkContinuation which does)
            if (node == .conditional) {
                const cond = &node.conditional;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        const result = try self.checkForeachBranchContinuation(body_cont, &context, program, flow, module_name, mode);
                        if (result.transformed) return result;
                    }
                }
            }
        }

        // Check nested continuations
        for (cont.continuations) |*nested| {
            // For nested continuations, we need to determine the event they belong to
            // This requires looking at the node in cont (if it's an invocation)
            var nested_event = event_decl;
            var nested_module = module_name;

            if (cont.node) |node| {
                if (node == .invocation) {
                    const inv_event_name = try self.pathToString(node.invocation.path);
                    defer self.allocator.free(inv_event_name);
                    const inv_module = node.invocation.path.module_qualifier orelse module_name;
                    const inv_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, inv_event_name });
                    defer self.allocator.free(inv_qualified);

                    if (self.event_map.get(inv_qualified)) |info| {
                        nested_event = info.decl;
                        nested_module = info.module_name;
                    }
                }
            }

            // If this continuation has @scope annotation, treat it as a scope boundary
            // The @scope annotation is the source of truth - not the event name
            if (hasScope(nested)) {
                var scoped_context = try context.clone(self.allocator);
                defer scoped_context.deinit();
                scoped_context.enterScope(true); // @scope means we're in a scoped boundary

                const result = try self.checkContinuation(nested, nested_event, nested_module, &scoped_context, program, flow, mode);
                if (result.transformed) return result;
            } else {
                const result = try self.checkContinuation(nested, nested_event, nested_module, &context, program, flow, mode);
                if (result.transformed) return result;
            }
        }

        // CRITICAL: If we reach end of a pipeline (no nested continuations) and this isn't
        // already a terminator, treat as implicit terminator and check obligations.
        // This handles void event chains like: ~acquire() | ok r |> print.ln("...")
        // where the flow ends without explicit `|> _`
        if (cont.continuations.len == 0) {
            const has_explicit_terminator = if (cont.node) |node|
                (node == .terminal or node == .branch_constructor)
            else
                false;

            if (!has_explicit_terminator and context.hasObligations()) {
                // Count how many obligations are from current scope
                var current_scope_count: u32 = 0;
                var obl_iter = context.obligations();
                while (obl_iter.next()) |entry| {
                    if (entry.value_ptr.scope_depth == context.scope_depth) {
                        current_scope_count += 1;
                    }
                }

                if (mode == .full) {
                    if (current_scope_count > 0) {
                        // We have current-scope obligations at end of pipeline - need to dispose
                        return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                    }
                    // Outer-scope obligations in repeating context will flow to `done`
                    if (!context.is_repeating) {
                        return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                    }
                }
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a foreach node for terminators with obligations
    /// Handles scope tracking: `each` branch is repeating, `done` is not
    fn checkForeachNode(
        self: *AutoDischargeInserter,
        branches: []const ast.NamedBranch, // The foreach branches
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        module_name: []const u8,
        mode: TransformMode,
    ) RecursiveError!TransformResult {
        // Increment scope BEFORE recording loop entry
        // This ensures obligations created before the loop are at a lower scope
        parent_context.scope_depth += 1;

        // Mark that we're inside a loop - obligations from before this point
        // cannot be auto-discharged inside any branch of this loop
        parent_context.enterLoop();

        // Process each branch of the foreach
        for (branches) |*branch| {
            // Check for @scope annotation (replaces old "each" branch name check)
            const is_scope_boundary = branchHasScope(branch);

            if (is_scope_boundary) {
                // Scoped branch (like "each") - clone context and enter new scope
                // Obligations cleared here don't propagate to parent (each iteration is independent)
                var branch_context = try parent_context.clone(self.allocator);
                defer branch_context.deinit();
                branch_context.enterScope(true);

                // Process continuations in this branch
                for (branch.body) |*body_cont| {
                    const result = try self.checkForeachBranchContinuation(
                        body_cont,
                        &branch_context,
                        program,
                        flow,
                        module_name,
                        mode,
                    );
                    if (result.transformed) return result;
                }

                if (mode == .scope_exit_only) {
                    // SCOPE EXIT: Check for remaining obligations that need disposal
                    // These are obligations created in this scope that weren't discharged by an explicit terminal
                    if (branch_context.hasObligations()) {
                        var obl_iter = branch_context.obligations();
                        while (obl_iter.next()) |entry| {
                            const binding_name = entry.key_ptr.*;
                            const info = entry.value_ptr.*;

                            // Find disposal event for this obligation
                            const disposals = try self.findDisposalEvents(info.phantom_state);
                            defer self.allocator.free(disposals);

                            const disposal = selectDisposal(disposals) orelse {
                                if (disposals.len == 0) {
                                    try self.reporter.addError(
                                        .KORU030,
                                        flow.location.line,
                                        flow.location.column,
                                        "No disposal event found for resource '{s}' with state '{s}' at scope exit.",
                                        .{ binding_name, info.phantom_state },
                                    );
                                } else {
                                    try self.reporter.addError(
                                        .KORU030,
                                        flow.location.line,
                                        flow.location.column,
                                        "Multiple disposal options for resource '{s}' at scope exit. Discharge explicitly in your code.",
                                        .{binding_name},
                                    );
                                }
                                return error.ValidationFailed;
                            };

                            // Find the continuation that created this binding and insert disposal
                            const result = try self.insertScopeExitDisposal(
                                branch,
                                binding_name,
                                disposal,
                                program,
                                flow,
                            );
                            if (result.transformed) return result;
                        }
                    }
                }
            } else {
                // Non-scoped branch (like "done") - use parent context directly
                // Obligations cleared here DO propagate to parent (runs once after loop)
                for (branch.body) |*body_cont| {
                    const result = try self.checkForeachBranchContinuation(
                        body_cont,
                        parent_context,
                        program,
                        flow,
                        module_name,
                        mode,
                    );
                    if (result.transformed) return result;
                }
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a continuation inside a foreach branch (no event_decl binding tracking)
    /// If use_parent_directly is true, modifications affect parent_context (for non-scoped branches)
    fn checkForeachBranchContinuation(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        module_name: []const u8,
        mode: TransformMode,
    ) RecursiveError!TransformResult {
        // Use parent context directly - caller is responsible for cloning if needed
        const context = parent_context;

        // Handle discard binding (_) - synthesize a real binding name
        // This must happen BEFORE we process the continuation so the binding can be used
        if (mode == .full) {
            if (cont.binding) |binding_name| {
                if (std.mem.eql(u8, binding_name, "_")) {
                    // Generate synthetic binding to replace _
                    const synthetic_name = try self.generateSyntheticBinding();

                    // Clone the continuation with the new binding (preserves all metadata)
                    const new_cont = try self.cloneContinuationWithBinding(cont, synthetic_name);

                    // Replace this continuation in the flow
                    const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont.*);

                    // Replace the flow in the program
                    const new_program = try ast_functional.replaceFlowRecursive(
                        self.allocator,
                        program,
                        flow,
                        .{ .flow = new_flow },
                    ) orelse {
                        return .{ .transformed = false, .program = program };
                    };

                    const result_ptr = try self.allocator.create(ast.Program);
                    result_ptr.* = new_program;

                    // Return transformed - the next iteration will process with the real binding
                    return .{ .transformed = true, .program = result_ptr };
                }
            }
        }

        // Check if this continuation has a node
        if (cont.node) |node| {
            const is_terminator = (node == .terminal or node == .branch_constructor);
            if (is_terminator) {
                // Found a terminator - check for obligations to dispose
                //
                // NOTE: Pre-loop obligations in repeating context are OK here!
                // They "flow through" the loop and will be handled at the `done` branch.
                // We only error for pre-loop obligations when:
                // 1. Trying to INSERT auto-disposal (checked in insertDisposalsInForeach)
                // 2. Manually disposing via invocation (checked in checkInvocationSatisfiesObligations)

                // IMPORTANT: For branch_constructor, check if obligations ESCAPE via the return fields
                // If an obligation is returned (e.g., got_file { file: f.file }), it should NOT be disposed
                if (node == .branch_constructor) {
                    const bc = &node.branch_constructor;
                    // Collect escaping bindings (max 16 should be plenty)
                    var escaping_bindings: [16][]const u8 = undefined;
                    var escaping_count: usize = 0;

                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (bindingEscapesViaBranchConstructor(bc, entry.key_ptr.*)) {
                            if (escaping_count < 16) {
                                escaping_bindings[escaping_count] = entry.key_ptr.*;
                                escaping_count += 1;
                            }
                        }
                    }

                    // Remove escaping obligations (they transfer to the caller)
                    for (escaping_bindings[0..escaping_count]) |binding| {
                        _ = context.cleanup_obligations.remove(binding);
                    }
                }

                // Check for current-scope obligations to dispose
                if (context.hasObligations()) {
                    // Count how many obligations are from current scope
                    var current_scope_count: u32 = 0;
                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (entry.value_ptr.scope_depth == context.scope_depth) {
                            current_scope_count += 1;
                        }
                    }

                    if (mode == .full) {
                        if (current_scope_count > 0) {
                            // We have current-scope obligations to dispose
                            return try self.insertDisposalsInForeach(cont, context, program, flow);
                        }
                        // Outer-scope obligations exist but not current-scope ones
                        // In a repeating context, this is OK - they'll be handled at `done`
                        // In a non-repeating context, they should be disposed here
                        if (!context.is_repeating) {
                            // Non-repeating: dispose all remaining obligations
                            return try self.insertDisposalsInForeach(cont, context, program, flow);
                        }
                        // Repeating: outer obligations will flow through to `done`
                    }
                }
            }

            // Handle invocations - look up event and check for obligation satisfaction + binding creation
            if (node == .invocation) {
                const invocation = &node.invocation;
                try self.checkInvocationSatisfiesObligations(context, invocation, module_name, flow);

                // Also add any bindings from this invocation's continuations
                const inv_event_name = try self.pathToString(invocation.path);
                defer self.allocator.free(inv_event_name);
                const inv_module = invocation.path.module_qualifier orelse module_name;
                const inv_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, inv_event_name });
                defer self.allocator.free(inv_qualified);

                if (self.event_map.get(inv_qualified)) |info| {
                    const event_decl = info.decl;

                    // Process nested continuations with the event's binding info
                    for (cont.continuations) |*nested| {
                        // Add binding from nested continuation if it matches event branch
                        if (nested.binding) |binding_name| {
                            for (event_decl.branches) |ev_branch| {
                                if (std.mem.eql(u8, ev_branch.name, nested.branch)) {
                                    for (ev_branch.payload.fields) |field| {
                                        if (field.phantom) |phantom_str| {
                                            // For identity branches (field name is __type_ref),
                                            // use just the binding name since the value IS the binding
                                            // For struct branches, use binding.field_name
                                            const is_identity = std.mem.eql(u8, field.name, "__type_ref");
                                            const field_path = if (is_identity)
                                                try self.allocator.dupe(u8, binding_name)
                                            else
                                                try std.fmt.allocPrint(
                                                    self.allocator,
                                                    "{s}.{s}",
                                                    .{ binding_name, field.name },
                                                );
                                            defer self.allocator.free(field_path);

                                            const canonical = try self.canonicalizePhantom(phantom_str, info.module_name);
                                            defer self.allocator.free(canonical);

                                            try context.addBinding(field_path, canonical, field.name);
                                        }
                                    }
                                    break;
                                }
                            }
                        }

                        const result = try self.checkForeachBranchContinuation(nested, context, program, flow, info.module_name, mode);
                        if (result.transformed) return result;
                    }
                }
                // If event not found, still recurse into continuations
                else {
                    for (cont.continuations) |*nested| {
                        const result = try self.checkForeachBranchContinuation(nested, context, program, flow, module_name, mode);
                        if (result.transformed) return result;
                    }
                }

                // DON'T return early - fall through to end-of-pipeline check below
            }

            // Handle nested foreach
            if (node == .foreach) {
                const result = try self.checkForeachNode(node.foreach.branches, context, program, flow, module_name, mode);
                if (result.transformed) return result;
            }

            // Handle conditional
            if (node == .conditional) {
                const cond = &node.conditional;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        const result = try self.checkForeachBranchContinuation(body_cont, context, program, flow, module_name, mode);
                        if (result.transformed) return result;
                    }
                }
            }
        }

        // Check nested continuations (skip if already handled by invocation processing above)
        const already_processed_continuations = if (cont.node) |n| n == .invocation else false;
        if (!already_processed_continuations) {
            for (cont.continuations) |*nested| {
                const result = try self.checkForeachBranchContinuation(nested, context, program, flow, module_name, mode);
                if (result.transformed) return result;
            }
        }

        // CRITICAL: If we reach end of a pipeline (no nested continuations) and this isn't
        // already a terminator, treat as implicit terminator and check obligations
        if (cont.continuations.len == 0) {
            const has_explicit_terminator = if (cont.node) |node|
                (node == .terminal or node == .branch_constructor)
            else
                false;

            if (!has_explicit_terminator and context.hasObligations()) {
                // Count how many obligations are from current scope
                var current_scope_count: u32 = 0;
                var obl_iter = context.obligations();
                while (obl_iter.next()) |entry| {
                    if (entry.value_ptr.scope_depth == context.scope_depth) {
                        current_scope_count += 1;
                    }
                }

                if (mode == .full) {
                    if (current_scope_count > 0) {
                        // We have current-scope obligations at end of pipeline - need to dispose
                        return try self.insertDisposalsInForeach(cont, context, program, flow);
                    }
                    // Outer-scope obligations in repeating context will flow to `done`
                    if (!context.is_repeating) {
                        return try self.insertDisposalsInForeach(cont, context, program, flow);
                    }
                }
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Insert disposals for obligations inside a foreach (placeholder - needs AST surgery)
    fn insertDisposalsInForeach(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) RecursiveError!TransformResult {

        // Find obligations to dispose based on scope rules
        var obl_iter = context.obligations();
        while (obl_iter.next()) |entry| {
            // In repeating context: only dispose current-scope obligations
            // In non-repeating context: dispose all obligations
            const should_dispose = if (context.is_repeating)
                entry.value_ptr.scope_depth == context.scope_depth
            else
                true; // Dispose all in non-repeating context

            if (should_dispose) {
                const binding_path = entry.key_ptr.*;
                const info = entry.value_ptr.*;

                const disposals = try self.findDisposalEvents(info.phantom_state);
                defer self.allocator.free(disposals);

                // Use selectDisposal to handle [!] default annotation
                const disposal = selectDisposal(disposals) orelse {
                    // Ambiguous or no disposal found
                    if (disposals.len == 0) {
                        try self.reporter.addError(
                            .KORU030,
                            flow.location.line,
                            flow.location.column,
                            "No disposal event found for resource '{s}' with state '{s}'.",
                            .{ binding_path, info.phantom_state },
                        );
                    } else {
                        var options_buf: [1024]u8 = undefined;
                        var fbs = std.io.fixedBufferStream(&options_buf);
                        for (disposals, 0..) |d, i| {
                            if (i > 0) try fbs.writer().writeAll(", ");
                            try fbs.writer().writeAll(d.qualified_name);
                        }
                        try self.reporter.addError(
                            .KORU030,
                            flow.location.line,
                            flow.location.column,
                            "Multiple disposal options for resource '{s}': {s}. Discharge explicitly in your code.",
                            .{ binding_path, fbs.getWritten() },
                        );
                    }
                    return error.ValidationFailed;
                };

                // Emit warning about auto-discharge insertion (only in warn mode)
                if (self.warn_mode) {
                    std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' to dispose '{s}' (state: {s})\n", .{
                        disposal.qualified_name,
                        binding_path,
                        info.phantom_state,
                    });
                }

                // Create new continuation with disposal
                const new_cont = try self.createDisposalContinuation(cont, binding_path, disposal);

                // Find and replace this continuation in the flow
                // This is tricky because it's nested inside a foreach
                const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont);
                const marked_flow = try self.markFlowProcessed(new_flow);

                const new_program = try ast_functional.replaceFlowRecursive(
                    self.allocator,
                    program,
                    flow,
                    .{ .flow = marked_flow },
                ) orelse {
                    return .{ .transformed = false, .program = program };
                };

                const result_ptr = try self.allocator.create(ast.Program);
                result_ptr.* = new_program;

                return .{ .transformed = true, .program = result_ptr };
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check if an invocation satisfies any obligations (explicit cleanup)
    /// Also validates that manual disposal doesn't happen in repeating context for pre-loop obligations
    fn checkInvocationSatisfiesObligations(
        self: *AutoDischargeInserter,
        context: *BindingContext,
        invocation: *const ast.Invocation,
        module_name: []const u8,
        flow: *const ast.Flow,
    ) !void {
        // Look up the event being invoked
        const event_name = try self.pathToString(invocation.path);
        defer self.allocator.free(event_name);

        const inv_module = invocation.path.module_qualifier orelse module_name;
        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ inv_module, event_name });
        defer self.allocator.free(qualified_name);

        const event_info = self.event_map.get(qualified_name) orelse return;
        const event_decl = event_info.decl;

        // Check each argument to see if it satisfies an obligation
        for (invocation.args) |arg| {
            // Find the corresponding parameter in the event declaration
            for (event_decl.input.fields) |field| {
                if (std.mem.eql(u8, field.name, arg.name)) {
                    // Check if this parameter consumes an obligation
                    if (field.phantom) |phantom_str| {
                        var parsed = phantom_parser.PhantomState.parse(self.allocator, phantom_str) catch continue;
                        defer parsed.deinit(self.allocator);

                        // Check if parameter consumes obligation (concrete or union with ! prefix)
                        const consumes = switch (parsed) {
                            .concrete => |c| c.consumes_obligation,
                            .state_union => |u| u.consumes_obligation,
                            .variable => false,
                        };

                        if (consumes) {
                            // ERROR: Cannot manually dispose outer-scope obligation inside @scope boundary
                            // This applies to ANY @scope (loops, taps, custom constructs) - not just loops
                            // is_repeating is true when we're inside a @scope boundary
                            if (context.is_repeating) {
                                if (context.loop_entry_scope) |scope_entry| {
                                    if (context.cleanup_obligations.get(arg.value)) |obl_info| {
                                        if (obl_info.scope_depth < scope_entry) {
                                            try self.reporter.addError(
                                                .KORU032,
                                                flow.location.line,
                                                flow.location.column,
                                                "Cannot dispose outer-scope resource '{s}' inside @scope boundary. Handle outside the scope or escape via branch constructor.",
                                                .{arg.value},
                                            );
                                            return error.ValidationFailed;
                                        }
                                    }
                                }
                            }

                            // This parameter consumes an obligation - clear it
                            context.clearObligation(arg.value);
                        }
                    }
                    break;
                }
            }
        }
    }

    /// Insert disposal calls for unsatisfied obligations
    fn insertDisposals(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        event_decl: *const ast.EventDecl,
        module_name: []const u8,
    ) !TransformResult {
        _ = event_decl;
        _ = module_name;


        // For each obligation, find disposal events
        // In repeating context, only dispose current-scope obligations
        var obl_iter = context.obligations();
        while (obl_iter.next()) |entry| {
            const binding_path = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            // Skip outer-scope obligations in repeating context
            if (context.is_repeating and info.scope_depth < context.scope_depth) {
                continue;
            }

            const disposals = try self.findDisposalEvents(info.phantom_state);
            defer self.allocator.free(disposals);

            // Use selectDisposal to handle [!] default annotation
            const disposal = selectDisposal(disposals) orelse {
                // Ambiguous or no disposal found
                if (disposals.len == 0) {
                    try self.reporter.addError(
                        .KORU030,
                        flow.location.line,
                        flow.location.column,
                        "No disposal event found for resource '{s}' with state '{s}'. Library must define an event with [!{s}] parameter.",
                        .{ binding_path, info.phantom_state, info.phantom_state },
                    );
                } else {
                    var options_buf: [1024]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&options_buf);
                    for (disposals, 0..) |d, i| {
                        if (i > 0) try fbs.writer().writeAll(", ");
                        try fbs.writer().writeAll(d.qualified_name);
                    }
                    try self.reporter.addError(
                        .KORU030,
                        flow.location.line,
                        flow.location.column,
                        "Multiple disposal options for resource '{s}': {s}. Discharge explicitly in your code.",
                        .{ binding_path, fbs.getWritten() },
                    );
                }
                return error.ValidationFailed;
            };

            // Emit warning about auto-discharge insertion (only in warn mode)
            if (self.warn_mode) {
                std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' to dispose '{s}' (state: {s})\n", .{
                    disposal.qualified_name,
                    binding_path,
                    info.phantom_state,
                });
            }

            // Create the transformed continuation
            const new_cont = try self.createDisposalContinuation(
                cont,
                binding_path,
                disposal,
            );

            // Replace in the flow - use replaceContinuationAnywhere to handle nested continuations
            const new_flow = try self.replaceContinuationAnywhere(flow, cont, new_cont);

            // Mark flow as processed
            const marked_flow = try self.markFlowProcessed(new_flow);

            // Replace in program
            const new_program = try ast_functional.replaceFlowRecursive(
                self.allocator,
                program,
                flow,
                .{ .flow = marked_flow },
            ) orelse {
                return .{ .transformed = false, .program = program };
            };

            const result_ptr = try self.allocator.create(ast.Program);
            result_ptr.* = new_program;

            return .{ .transformed = true, .program = result_ptr };
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check if an event has the [!] annotation (marks it as default for auto-discharge)
    fn eventHasDefaultAnnotation(event_decl: *const ast.EventDecl) bool {
        for (event_decl.annotations) |ann| {
            if (std.mem.eql(u8, ann, "!")) return true;
        }
        return false;
    }

    /// Select the disposal to use from a list of candidates
    /// Returns the single disposal if unambiguous, or null if ambiguous/none
    /// Selection logic:
    /// - 1 disposal → use it
    /// - Multiple disposals → filter to [!] annotated ones
    ///   - 1 default → use it
    ///   - 0 or >1 defaults → ambiguous (return null)
    fn selectDisposal(disposals: []const DisposalEvent) ?DisposalEvent {
        if (disposals.len == 0) return null;
        if (disposals.len == 1) return disposals[0];

        // Multiple disposals - look for [!] default
        var default_count: usize = 0;
        var default_disposal: ?DisposalEvent = null;
        for (disposals) |d| {
            if (d.is_default) {
                default_count += 1;
                default_disposal = d;
            }
        }

        // Exactly one default among multiple options
        if (default_count == 1) return default_disposal;

        // 0 or >1 defaults = ambiguous
        return null;
    }

    /// Find all events that can dispose a given phantom state
    fn findDisposalEvents(self: *AutoDischargeInserter, phantom_state: []const u8) ![]DisposalEvent {
        var results = try std.ArrayList(DisposalEvent).initCapacity(self.allocator, 4);

        // Strip the ! suffix to get base state
        var base_state = phantom_state;
        if (std.mem.endsWith(u8, base_state, "!")) {
            base_state = base_state[0 .. base_state.len - 1];
        }

        // Search all events for [!state] parameters
        var iter = self.event_map.iterator();
        while (iter.next()) |entry| {
            const event_decl = entry.value_ptr.decl;

            // Skip events with multiple branches - they require manual handling
            // Events with 0 branches (void) or 1 branch (single outcome) can be auto-discharged
            if (event_decl.branches.len > 1) continue;

            const is_default = eventHasDefaultAnnotation(event_decl);

            for (event_decl.input.fields) |field| {
                if (field.phantom) |field_phantom| {
                    // Parse to check if it consumes this state
                    var parsed = phantom_parser.PhantomState.parse(self.allocator, field_phantom) catch continue;
                    defer parsed.deinit(self.allocator);

                    switch (parsed) {
                        .concrete => |concrete| {
                            if (concrete.consumes_obligation) {
                                // Build full state name - canonicalize using event's module if no module specified
                                const consumer_state = if (concrete.module_path) |mod|
                                    try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mod, concrete.name })
                                else
                                    // Use event's module to canonicalize
                                    try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.value_ptr.module_name, concrete.name });
                                defer self.allocator.free(consumer_state);

                                if (std.mem.eql(u8, consumer_state, base_state)) {
                                    try results.append(self.allocator, .{
                                        .qualified_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                                        .event_decl = event_decl,
                                        .field_name = try self.allocator.dupe(u8, field.name),
                                        .is_default = is_default,
                                    });
                                }
                            }
                        },
                        .variable => {},
                        .state_union => |u| {
                            if (u.consumes_obligation) {
                                // Check if any member of the union matches the base_state
                                for (u.members) |member| {
                                    const consumer_state = if (member.module_path) |mod|
                                        try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mod, member.name })
                                    else
                                        try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ entry.value_ptr.module_name, member.name });
                                    defer self.allocator.free(consumer_state);

                                    if (std.mem.eql(u8, consumer_state, base_state)) {
                                        try results.append(self.allocator, .{
                                            .qualified_name = try self.allocator.dupe(u8, entry.key_ptr.*),
                                            .event_decl = event_decl,
                                            .field_name = try self.allocator.dupe(u8, field.name),
                                            .is_default = is_default,
                                        });
                                        break; // Found a match, don't add duplicates
                                    }
                                }
                            }
                        },
                    }
                }
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Create a new continuation with disposal call inserted at the end
    /// Handles two cases:
    /// 1. Original node is a terminator → insert disposal before terminal
    /// 2. Original node is an invocation (void event) → append disposal after invocation
    fn createDisposalContinuation(
        self: *AutoDischargeInserter,
        original: *const ast.Continuation,
        binding_path: []const u8,
        disposal: DisposalEvent,
    ) !ast.Continuation {
        // Parse disposal event name to get path components
        const colon_idx = std.mem.indexOf(u8, disposal.qualified_name, ":") orelse 0;
        const disposal_module = disposal.qualified_name[0..colon_idx];
        const disposal_event = disposal.qualified_name[colon_idx + 1 ..];

        // Create invocation for disposal call
        var segments = try self.allocator.alloc([]const u8, 1);
        segments[0] = try self.allocator.dupe(u8, disposal_event);

        var args = try self.allocator.alloc(ast.Arg, 1);
        args[0] = .{
            .name = try self.allocator.dupe(u8, disposal.field_name),
            .value = try self.allocator.dupe(u8, binding_path),
            .expression_value = null,
            .source_value = null,
        };

        const disposal_invocation = ast.Invocation{
            .path = .{
                .segments = segments,
                .module_qualifier = try self.allocator.dupe(u8, disposal_module),
            },
            .args = args,
            .annotations = &[_][]const u8{},
        };

        // Check if original node is a terminator or an invocation
        const original_is_terminator = if (original.node) |node|
            (node == .terminal or node == .branch_constructor)
        else
            true; // null node treated as implicit terminal

        // Handle disposal event being void (no branches) vs having branches
        const disposal_is_void = disposal.event_decl.branches.len == 0;

        if (original_is_terminator) {
            // Case 1: Original is a terminator - insert disposal BEFORE terminal
            // Result: disposal() |> _
            var after_disposal_cont: []ast.Continuation = undefined;
            if (disposal_is_void) {
                // Void disposal event - use empty branch (void continuation)
                after_disposal_cont = try self.allocator.alloc(ast.Continuation, 1);
                after_disposal_cont[0] = .{
                    .branch = "", // Empty branch = void continuation
                    .binding = null,
                    .binding_annotations = &[_][]const u8{},
                    .condition = null,
                    .node = original.node, // Preserve original terminal
                    .indent = original.indent + 1,
                    .continuations = &[_]ast.Continuation{},
                    .location = original.location,
                };
            } else {
                // Disposal event with branches - use first branch name
                var disposal_branch: []const u8 = "done";
                for (disposal.event_decl.branches) |branch| {
                    disposal_branch = branch.name;
                    break;
                }
                after_disposal_cont = try self.allocator.alloc(ast.Continuation, 1);
                after_disposal_cont[0] = .{
                    .branch = try self.allocator.dupe(u8, disposal_branch),
                    .binding = try self.allocator.dupe(u8, "_"),
                    .binding_annotations = &[_][]const u8{},
                    .condition = null,
                    .node = original.node, // Preserve original terminal
                    .indent = original.indent + 1,
                    .continuations = &[_]ast.Continuation{},
                    .location = original.location,
                };
            }

            // Return with disposal as the node
            return .{
                .branch = try self.allocator.dupe(u8, original.branch),
                .binding = if (original.binding) |b| try self.allocator.dupe(u8, b) else null,
                .binding_annotations = original.binding_annotations,
                .condition = if (original.condition) |c| try self.allocator.dupe(u8, c) else null,
                .node = .{ .invocation = disposal_invocation },
                .indent = original.indent,
                .continuations = after_disposal_cont,
                .location = original.location,
            };
        } else {
            // Case 2: Original is an invocation (void event chain)
            // Need to: keep original invocation, append disposal after it
            // Result: original_invocation() |> disposal() |> _

            // Create the terminal continuation (final step)
            const terminal_cont = ast.Continuation{
                .branch = "", // void continuation
                .binding = null,
                .binding_annotations = &[_][]const u8{},
                .condition = null,
                .node = .{ .terminal = {} },
                .indent = original.indent + 2,
                .continuations = &[_]ast.Continuation{},
                .location = original.location,
            };

            // Create disposal continuation with terminal inside
            var disposal_cont_children = try self.allocator.alloc(ast.Continuation, 1);
            if (disposal_is_void) {
                disposal_cont_children[0] = terminal_cont;
            } else {
                // Disposal with branches - wrap terminal in branch continuation
                var disposal_branch: []const u8 = "done";
                for (disposal.event_decl.branches) |branch| {
                    disposal_branch = branch.name;
                    break;
                }
                disposal_cont_children[0] = .{
                    .branch = try self.allocator.dupe(u8, disposal_branch),
                    .binding = try self.allocator.dupe(u8, "_"),
                    .binding_annotations = &[_][]const u8{},
                    .condition = null,
                    .node = .{ .terminal = {} },
                    .indent = original.indent + 2,
                    .continuations = &[_]ast.Continuation{},
                    .location = original.location,
                };
            }

            const disposal_cont = ast.Continuation{
                .branch = "", // void continuation after original invocation
                .binding = null,
                .binding_annotations = &[_][]const u8{},
                .condition = null,
                .node = .{ .invocation = disposal_invocation },
                .indent = original.indent + 1,
                .continuations = disposal_cont_children,
                .location = original.location,
            };

            // Create new continuations array: [disposal_cont]
            var new_continuations = try self.allocator.alloc(ast.Continuation, 1);
            new_continuations[0] = disposal_cont;

            // Return original invocation with disposal appended
            return .{
                .branch = try self.allocator.dupe(u8, original.branch),
                .binding = if (original.binding) |b| try self.allocator.dupe(u8, b) else null,
                .binding_annotations = original.binding_annotations,
                .condition = if (original.condition) |c| try self.allocator.dupe(u8, c) else null,
                .node = original.node, // Keep original invocation!
                .indent = original.indent,
                .continuations = new_continuations,
                .location = original.location,
            };
        }
    }

    /// Insert disposal at scope exit for a binding
    /// Finds the continuation with the given binding and adds disposal to its continuations
    fn insertScopeExitDisposal(
        self: *AutoDischargeInserter,
        branch: *const ast.NamedBranch,
        binding_name: []const u8,
        disposal: DisposalEvent,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) RecursiveError!TransformResult {
        // Extract base binding name (before any field access like `.file`)
        // e.g., "_auto_1.file" -> "_auto_1"
        const base_binding = if (std.mem.indexOf(u8, binding_name, ".")) |dot_idx|
            binding_name[0..dot_idx]
        else
            binding_name;

        // Find the continuation that has this binding
        const target_cont = self.findContinuationByBinding(branch.body, base_binding) orelse {
            // Binding not found - might be a synthetic binding from discard or nested structure
            return .{ .transformed = false, .program = program };
        };

        // Create disposal invocation
        const colon_idx = std.mem.indexOf(u8, disposal.qualified_name, ":") orelse 0;
        const disposal_module = disposal.qualified_name[0..colon_idx];
        const disposal_event = disposal.qualified_name[colon_idx + 1 ..];

        var segments = try self.allocator.alloc([]const u8, 1);
        segments[0] = try self.allocator.dupe(u8, disposal_event);

        var args = try self.allocator.alloc(ast.Arg, 1);
        args[0] = .{
            .name = try self.allocator.dupe(u8, disposal.field_name),
            .value = try self.allocator.dupe(u8, binding_name),
            .expression_value = null,
            .source_value = null,
        };

        const disposal_invocation = ast.Invocation{
            .path = .{
                .segments = segments,
                .module_qualifier = try self.allocator.dupe(u8, disposal_module),
            },
            .args = args,
            .annotations = &[_][]const u8{},
        };

        // Create disposal continuation with terminal
        const disposal_is_void = disposal.event_decl.branches.len == 0;
        var disposal_branch_name: []const u8 = "";
        if (!disposal_is_void) {
            for (disposal.event_decl.branches) |b| {
                disposal_branch_name = b.name;
                break;
            }
        }

        var terminal_conts = try self.allocator.alloc(ast.Continuation, 1);
        terminal_conts[0] = .{
            .branch = if (disposal_is_void) "" else try self.allocator.dupe(u8, disposal_branch_name),
            .binding = if (disposal_is_void) null else try self.allocator.dupe(u8, "_"),
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .terminal = {} },
            .indent = target_cont.indent + 2,
            .continuations = &[_]ast.Continuation{},
            .location = target_cont.location,
        };

        const disposal_cont = ast.Continuation{
            .branch = "", // void continuation
            .binding = null,
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .invocation = disposal_invocation },
            .indent = target_cont.indent + 1,
            .continuations = terminal_conts,
            .location = target_cont.location,
        };

        // Create new continuation with disposal appended to its continuations
        var new_conts = try self.allocator.alloc(ast.Continuation, target_cont.continuations.len + 1);
        for (target_cont.continuations, 0..) |c, i| {
            new_conts[i] = try ast_functional.cloneContinuation(self.allocator, &c);
        }
        new_conts[target_cont.continuations.len] = disposal_cont;

        const new_target_cont = ast.Continuation{
            .branch = try self.allocator.dupe(u8, target_cont.branch),
            .binding = if (target_cont.binding) |b| try self.allocator.dupe(u8, b) else null,
            .binding_annotations = target_cont.binding_annotations,
            .condition = if (target_cont.condition) |c| try self.allocator.dupe(u8, c) else null,
            .node = target_cont.node,
            .indent = target_cont.indent,
            .continuations = new_conts,
            .location = target_cont.location,
        };

        // Replace the continuation in the flow
        const new_flow = try self.replaceContinuationAnywhere(flow, target_cont, new_target_cont);
        const marked_flow = try self.markFlowProcessed(new_flow);

        const new_program = try ast_functional.replaceFlowRecursive(
            self.allocator,
            program,
            flow,
            .{ .flow = marked_flow },
        ) orelse {
            return .{ .transformed = false, .program = program };
        };

        const result_ptr = try self.allocator.create(ast.Program);
        result_ptr.* = new_program;

        if (self.warn_mode) {
            std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' at scope exit for '{s}'\n", .{
                disposal.qualified_name,
                binding_name,
            });
        }

        return .{ .transformed = true, .program = result_ptr };
    }

    /// Insert disposal at scope exit for a binding within a continuation (for flow-level scopes)
    fn insertScopeExitDisposalInCont(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        binding_name: []const u8,
        disposal: DisposalEvent,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) RecursiveError!TransformResult {
        // Search for the continuation with this binding starting from the given cont
        const target_cont = if (cont.binding) |b|
            if (std.mem.eql(u8, b, binding_name)) cont else self.findContinuationInCont(cont, binding_name)
        else
            self.findContinuationInCont(cont, binding_name);

        const actual_target = target_cont orelse {
            return .{ .transformed = false, .program = program };
        };

        // Create disposal invocation
        const colon_idx = std.mem.indexOf(u8, disposal.qualified_name, ":") orelse 0;
        const disposal_module = disposal.qualified_name[0..colon_idx];
        const disposal_event = disposal.qualified_name[colon_idx + 1 ..];

        var segments = try self.allocator.alloc([]const u8, 1);
        segments[0] = try self.allocator.dupe(u8, disposal_event);

        var args = try self.allocator.alloc(ast.Arg, 1);
        args[0] = .{
            .name = try self.allocator.dupe(u8, disposal.field_name),
            .value = try self.allocator.dupe(u8, binding_name),
            .expression_value = null,
            .source_value = null,
        };

        const disposal_invocation = ast.Invocation{
            .path = .{
                .segments = segments,
                .module_qualifier = try self.allocator.dupe(u8, disposal_module),
            },
            .args = args,
            .annotations = &[_][]const u8{},
        };

        // Create disposal continuation with terminal
        const disposal_is_void = disposal.event_decl.branches.len == 0;
        var disposal_branch_name: []const u8 = "";
        if (!disposal_is_void) {
            for (disposal.event_decl.branches) |b| {
                disposal_branch_name = b.name;
                break;
            }
        }

        var terminal_conts = try self.allocator.alloc(ast.Continuation, 1);
        terminal_conts[0] = .{
            .branch = if (disposal_is_void) "" else try self.allocator.dupe(u8, disposal_branch_name),
            .binding = if (disposal_is_void) null else try self.allocator.dupe(u8, "_"),
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .terminal = {} },
            .indent = actual_target.indent + 2,
            .continuations = &[_]ast.Continuation{},
            .location = actual_target.location,
        };

        const disposal_cont = ast.Continuation{
            .branch = "",
            .binding = null,
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .{ .invocation = disposal_invocation },
            .indent = actual_target.indent + 1,
            .continuations = terminal_conts,
            .location = actual_target.location,
        };

        // Append disposal to target's continuations
        var new_conts = try self.allocator.alloc(ast.Continuation, actual_target.continuations.len + 1);
        for (actual_target.continuations, 0..) |c, i| {
            new_conts[i] = try ast_functional.cloneContinuation(self.allocator, &c);
        }
        new_conts[actual_target.continuations.len] = disposal_cont;

        const new_target_cont = ast.Continuation{
            .branch = try self.allocator.dupe(u8, actual_target.branch),
            .binding = if (actual_target.binding) |b| try self.allocator.dupe(u8, b) else null,
            .binding_annotations = actual_target.binding_annotations,
            .condition = if (actual_target.condition) |c| try self.allocator.dupe(u8, c) else null,
            .node = actual_target.node,
            .indent = actual_target.indent,
            .continuations = new_conts,
            .location = actual_target.location,
        };

        const new_flow = try self.replaceContinuationAnywhere(flow, actual_target, new_target_cont);
        const marked_flow = try self.markFlowProcessed(new_flow);

        const new_program = try ast_functional.replaceFlowRecursive(
            self.allocator,
            program,
            flow,
            .{ .flow = marked_flow },
        ) orelse {
            return .{ .transformed = false, .program = program };
        };

        const result_ptr = try self.allocator.create(ast.Program);
        result_ptr.* = new_program;

        if (self.warn_mode) {
            std.debug.print("warning[AUTO-DISCHARGE]: Inserting '{s}' at scope exit for '{s}'\n", .{
                disposal.qualified_name,
                binding_name,
            });
        }

        return .{ .transformed = true, .program = result_ptr };
    }

    /// Find a continuation with a specific binding within a continuation tree
    fn findContinuationInCont(self: *AutoDischargeInserter, cont: *const ast.Continuation, binding_name: []const u8) ?*const ast.Continuation {
        _ = self;
        // Check nested continuations
        if (cont.continuations.len > 0) {
            if (findContinuationByBindingRecursive(cont.continuations, binding_name)) |found| {
                return found;
            }
        }
        // Check node's nested structures
        if (cont.node) |node| {
            switch (node) {
                .foreach => |fe| {
                    for (fe.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                .conditional => |cond| {
                    for (cond.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Find a continuation that has a specific binding name
    fn findContinuationByBinding(self: *AutoDischargeInserter, conts: []const ast.Continuation, binding_name: []const u8) ?*const ast.Continuation {
        _ = self;
        for (conts) |*cont| {
            if (cont.binding) |b| {
                if (std.mem.eql(u8, b, binding_name)) {
                    return cont;
                }
            }
            // Recursively search in nested continuations
            if (cont.continuations.len > 0) {
                if (findContinuationByBindingRecursive(cont.continuations, binding_name)) |found| {
                    return found;
                }
            }
            // Search in node's nested structures
            if (cont.node) |node| {
                switch (node) {
                    .invocation => |inv| {
                        _ = inv;
                        // Invocations have their continuations in cont.continuations, already searched
                    },
                    .foreach => |fe| {
                        for (fe.branches) |*branch| {
                            if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                                return found;
                            }
                        }
                    },
                    .conditional => |cond| {
                        for (cond.branches) |*branch| {
                            if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                                return found;
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    /// Replace a continuation in a flow
    fn replaceContInFlow(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        old_cont: *const ast.Continuation,
        new_cont: ast.Continuation,
    ) !ast.Flow {
        var new_continuations = try self.allocator.alloc(ast.Continuation, flow.continuations.len);

        for (flow.continuations, 0..) |*cont, i| {
            if (@intFromPtr(cont) == @intFromPtr(old_cont)) {
                new_continuations[i] = new_cont;
            } else {
                new_continuations[i] = try ast_functional.cloneContinuation(self.allocator, cont);
            }
        }

        // Clone annotations
        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| {
            new_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        return .{
            .invocation = try ast_functional.cloneInvocation(self.allocator, &flow.invocation),
            .continuations = new_continuations,
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .post_label = if (flow.post_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
        };
    }

    /// Replace a continuation anywhere in the flow (including inside foreach nodes)
    fn replaceContinuationAnywhere(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        old_cont: *const ast.Continuation,
        new_cont: ast.Continuation,
    ) !ast.Flow {
        var new_continuations = try self.allocator.alloc(ast.Continuation, flow.continuations.len);

        for (flow.continuations, 0..) |*cont, i| {
            new_continuations[i] = try self.replaceContinuationInTree(cont, old_cont, new_cont);
        }

        // Clone annotations
        var new_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| {
            new_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        return .{
            .invocation = try ast_functional.cloneInvocation(self.allocator, &flow.invocation),
            .continuations = new_continuations,
            .annotations = new_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .post_label = if (flow.post_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
        };
    }

    /// Recursively replace a continuation in the tree
    fn replaceContinuationInTree(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        old_cont: *const ast.Continuation,
        new_cont: ast.Continuation,
    ) !ast.Continuation {
        // Check if this is the continuation we're looking for
        if (@intFromPtr(cont) == @intFromPtr(old_cont)) {
            return new_cont;
        }

        // Clone this continuation but recurse into nested structures
        var cloned = try ast_functional.cloneContinuation(self.allocator, cont);

        // If the node contains nested structures (foreach, conditional), we need to recurse
        if (cont.node) |node| {
            if (node == .foreach) {
                const foreach = &node.foreach;
                var new_branches = try self.allocator.alloc(ast.NamedBranch, foreach.branches.len);
                for (foreach.branches, 0..) |*branch, bi| {
                    var new_body = try self.allocator.alloc(ast.Continuation, branch.body.len);
                    for (branch.body, 0..) |*body_cont, bci| {
                        new_body[bci] = try self.replaceContinuationInTree(body_cont, old_cont, new_cont);
                    }
                    // Clone annotations (critical for @scope)
                    var cloned_anns = try self.allocator.alloc([]const u8, branch.annotations.len);
                    for (branch.annotations, 0..) |ann, ai| {
                        cloned_anns[ai] = try self.allocator.dupe(u8, ann);
                    }
                    new_branches[bi] = .{
                        .name = try self.allocator.dupe(u8, branch.name),
                        .body = new_body,
                        .binding = if (branch.binding) |b| try self.allocator.dupe(u8, b) else null,
                        .is_optional = branch.is_optional,
                        .annotations = cloned_anns,
                    };
                }
                cloned.node = .{ .foreach = .{
                    .iterable = try self.allocator.dupe(u8, foreach.iterable),
                    .element_type = if (foreach.element_type) |t| try self.allocator.dupe(u8, t) else null,
                    .branches = new_branches,
                } };
            } else if (node == .conditional) {
                const cond = &node.conditional;
                var new_branches = try self.allocator.alloc(ast.NamedBranch, cond.branches.len);
                for (cond.branches, 0..) |*branch, bi| {
                    var new_body = try self.allocator.alloc(ast.Continuation, branch.body.len);
                    for (branch.body, 0..) |*body_cont, bci| {
                        new_body[bci] = try self.replaceContinuationInTree(body_cont, old_cont, new_cont);
                    }
                    // Clone annotations (critical for @scope)
                    var cloned_anns = try self.allocator.alloc([]const u8, branch.annotations.len);
                    for (branch.annotations, 0..) |ann, ai| {
                        cloned_anns[ai] = try self.allocator.dupe(u8, ann);
                    }
                    new_branches[bi] = .{
                        .name = try self.allocator.dupe(u8, branch.name),
                        .body = new_body,
                        .binding = if (branch.binding) |b| try self.allocator.dupe(u8, b) else null,
                        .is_optional = branch.is_optional,
                        .annotations = cloned_anns,
                    };
                }
                cloned.node = .{ .conditional = .{
                    .condition = try self.allocator.dupe(u8, cond.condition),
                    .condition_expr = cond.condition_expr, // TODO: clone if needed
                    .branches = new_branches,
                } };
            }
        }

        // Recurse into nested continuations
        if (cont.continuations.len > 0) {
            var new_nested = try self.allocator.alloc(ast.Continuation, cont.continuations.len);
            for (cont.continuations, 0..) |*nested, ni| {
                new_nested[ni] = try self.replaceContinuationInTree(nested, old_cont, new_cont);
            }
            cloned.continuations = new_nested;
        }

        return cloned;
    }

    /// Mark a flow as processed with @auto_discharge_ran annotation
    fn markFlowProcessed(self: *AutoDischargeInserter, flow: ast.Flow) !ast.Flow {
        var new_annotations = try self.allocator.alloc([]const u8, flow.invocation.annotations.len + 1);

        for (flow.invocation.annotations, 0..) |ann, i| {
            new_annotations[i] = try self.allocator.dupe(u8, ann);
        }
        new_annotations[flow.invocation.annotations.len] = try self.allocator.dupe(u8, "@auto_discharge_ran");

        var new_invocation = try ast_functional.cloneInvocation(self.allocator, &flow.invocation);
        new_invocation.annotations = new_annotations;

        // Clone flow annotations
        var new_flow_annotations = try self.allocator.alloc([]const u8, flow.annotations.len);
        for (flow.annotations, 0..) |ann, i| {
            new_flow_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        return .{
            .invocation = new_invocation,
            .continuations = flow.continuations,
            .annotations = new_flow_annotations,
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
            .post_label = if (flow.post_label) |l| try self.allocator.dupe(u8, l) else null,
            .super_shape = flow.super_shape,
            .inline_body = if (flow.inline_body) |b| try self.allocator.dupe(u8, b) else null,
            .preamble_code = if (flow.preamble_code) |p| try self.allocator.dupe(u8, p) else null,
            .is_pure = flow.is_pure,
            .is_transitively_pure = flow.is_transitively_pure,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
        };
    }

    /// Canonicalize a phantom state with module prefix
    fn canonicalizePhantom(self: *AutoDischargeInserter, phantom_str: []const u8, module: []const u8) ![]const u8 {
        var parsed = phantom_parser.PhantomState.parse(self.allocator, phantom_str) catch {
            // If parsing fails, return unchanged
            return try self.allocator.dupe(u8, phantom_str);
        };
        defer parsed.deinit(self.allocator);

        switch (parsed) {
            .concrete => |concrete| {
                const mod = concrete.module_path orelse module;
                const cleanup_suffix = if (concrete.requires_cleanup) "!" else "";
                return try std.fmt.allocPrint(self.allocator, "{s}:{s}{s}", .{ mod, concrete.name, cleanup_suffix });
            },
            .variable => {
                return try self.allocator.dupe(u8, phantom_str);
            },
            .state_union => {
                // Unions are not canonicalized - they may have mixed modules
                return try self.allocator.dupe(u8, phantom_str);
            },
        }
    }

    /// Convert a dotted path to a string
    fn pathToString(self: *AutoDischargeInserter, path: ast.DottedPath) ![]const u8 {
        if (path.segments.len == 0) return try self.allocator.dupe(u8, "");
        if (path.segments.len == 1) return try self.allocator.dupe(u8, path.segments[0]);

        var total_len: usize = path.segments[0].len;
        for (path.segments[1..]) |seg| {
            total_len += 1 + seg.len;
        }

        var result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        @memcpy(result[pos .. pos + path.segments[0].len], path.segments[0]);
        pos += path.segments[0].len;

        for (path.segments[1..]) |seg| {
            result[pos] = '.';
            pos += 1;
            @memcpy(result[pos .. pos + seg.len], seg);
            pos += seg.len;
        }

        return result;
    }

    /// Generate a unique synthetic binding name
    fn generateSyntheticBinding(self: *AutoDischargeInserter) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "_auto_{d}", .{self.synthetic_binding_counter});
        self.synthetic_binding_counter += 1;
        return name;
    }

    /// Clone a continuation with a new binding name
    /// This preserves ALL metadata by copying fields, only changing the binding
    fn cloneContinuationWithBinding(
        self: *AutoDischargeInserter,
        cont: *const ast.Continuation,
        new_binding: []const u8,
    ) !*const ast.Continuation {
        const new_cont = try self.allocator.create(ast.Continuation);
        // Copy all fields from original (preserves all pointers/metadata)
        new_cont.* = cont.*;
        // Override just the binding
        new_cont.binding = try self.allocator.dupe(u8, new_binding);
        return new_cont;
    }

    /// Synthesize continuations for unhandled optional branches
    /// This ensures:
    /// 1. All optional branches get proper switch cases (runtime safety)
    /// 2. Auto-discharge can insert disposals for obligations in optional branches
    fn synthesizeOptionalBranches(
        self: *AutoDischargeInserter,
        flow: *const ast.Flow,
        event_decl: *const ast.EventDecl,
    ) !?*const ast.Flow {
        // Find which branches are already handled
        var handled = std.StringHashMap(void).init(self.allocator);
        defer handled.deinit();

        for (flow.continuations) |*cont| {
            if (cont.is_catchall) {
                // Catch-all handles all optional branches - no synthesis needed
                return null;
            }
            try handled.put(cont.branch, {});
        }

        // Find optional branches that need synthesis
        var missing_optional = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer missing_optional.deinit(self.allocator);

        for (event_decl.branches) |branch| {
            if (branch.is_optional and !handled.contains(branch.name)) {
                try missing_optional.append(self.allocator, branch.name);
            }
        }

        if (missing_optional.items.len == 0) {
            return null; // Nothing to synthesize
        }

        // Create new continuations array with synthesized branches
        const new_len = flow.continuations.len + missing_optional.items.len;
        var new_continuations = try self.allocator.alloc(ast.Continuation, new_len);
        errdefer self.allocator.free(new_continuations);

        // Copy existing continuations
        for (flow.continuations, 0..) |*cont, i| {
            new_continuations[i] = try ast_functional.cloneContinuation(self.allocator, cont);
        }

        // Add synthesized continuations for missing optional branches
        for (missing_optional.items, 0..) |branch_name, i| {
            const idx = flow.continuations.len + i;
            new_continuations[idx] = ast.Continuation{
                .branch = try self.allocator.dupe(u8, branch_name),
                .binding = try self.allocator.dupe(u8, "_"), // Discard binding - auto-discharge will synthesize _auto_N
                .binding_annotations = &[_][]const u8{},
                .binding_type = .branch_payload,
                .is_catchall = false,
                .catchall_metatype = null,
                .condition = null,
                .condition_expr = null,
                .node = .{ .terminal = {} }, // Terminal - triggers auto-discharge check
                .indent = 0,
                .continuations = &[_]ast.Continuation{},
                .location = flow.location,
            };
        }

        // Create new flow with synthesized continuations
        const new_flow = try self.allocator.create(ast.Flow);
        new_flow.* = flow.*;
        new_flow.continuations = new_continuations;

        return new_flow;
    }
};

/// Standalone recursive helper for finding continuation by binding (outside struct for recursive calls)
fn findContinuationByBindingRecursive(conts: []const ast.Continuation, binding_name: []const u8) ?*const ast.Continuation {
    for (conts) |*cont| {
        if (cont.binding) |b| {
            if (std.mem.eql(u8, b, binding_name)) {
                return cont;
            }
        }
        // Recursively search in nested continuations
        if (cont.continuations.len > 0) {
            if (findContinuationByBindingRecursive(cont.continuations, binding_name)) |found| {
                return found;
            }
        }
        // Search in node's nested structures
        if (cont.node) |node| {
            switch (node) {
                .foreach => |fe| {
                    for (fe.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                .conditional => |cond| {
                    for (cond.branches) |*branch| {
                        if (findContinuationByBindingRecursive(branch.body, binding_name)) |found| {
                            return found;
                        }
                    }
                },
                else => {},
            }
        }
    }
    return null;
}
