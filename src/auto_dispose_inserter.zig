// Auto-Dispose Inserter - Inserts disposal calls before flow terminators
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

pub const AutoDisposeInserter = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    event_map: std.StringHashMap(EventInfo),
    synthetic_binding_counter: u32,

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
    };

    /// Binding context tracks phantom states of variables in scope
    const BindingContext = struct {
        bindings: std.StringHashMap([]const u8), // variable name → phantom state
        cleanup_obligations: std.StringHashMap(BindingInfo), // binding → obligation info
        allocator: std.mem.Allocator,
        scope_depth: u32, // Current scope depth (increments when entering loop body)
        is_repeating: bool, // True if we're inside a loop's `each` branch
        loop_entry_scope: ?u32, // Scope depth when we entered the current loop (null if not in loop)

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

        /// Enter a new scope (for loop bodies)
        fn enterScope(self: *BindingContext, is_repeating: bool) void {
            self.scope_depth += 1;
            self.is_repeating = is_repeating;
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

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !AutoDisposeInserter {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .event_map = std.StringHashMap(EventInfo).init(allocator),
            .synthetic_binding_counter = 0,
        };
    }

    pub fn deinit(self: *AutoDisposeInserter) void {
        var iter = self.event_map.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.event_map.deinit();
    }

    /// Main entry point - run the auto-dispose pass on a program
    pub fn run(self: *AutoDisposeInserter, program: *const ast.Program) !*const ast.Program {
        // Step 1: Build event map
        try self.buildEventMap(program);

        // Step 2: Transform all flows
        var current_program = program;
        var iteration: u32 = 0;
        const max_iterations: u32 = 100000;

        while (iteration < max_iterations) : (iteration += 1) {
            const result = try self.transformOneFlow(current_program);
            if (result.transformed) {
                current_program = result.program;
            } else {
                // No more transformations needed
                break;
            }
        }

        return current_program;
    }

    /// Build map of all events and their phantom annotations
    fn buildEventMap(self: *AutoDisposeInserter, program: *const ast.Program) !void {
        // IMPORTANT: Use |*item| to get pointers into the actual slice, not copies!
        for (program.items) |*item| {
            switch (item.*) {
                .event_decl => {
                    const event_decl = &item.event_decl;
                    const event_name = try self.pathToString(event_decl.path);
                    defer self.allocator.free(event_name);

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

    /// Try to find and transform one flow that needs auto-dispose
    fn transformOneFlow(self: *AutoDisposeInserter, program: *const ast.Program) !TransformResult {
        // Walk all items looking for flows with unsatisfied obligations at terminators
        // IMPORTANT: Use |*item| to get pointers into the actual slice!
        for (program.items, 0..) |*item, item_idx| {
            switch (item.*) {
                .flow => {
                    const flow = &item.flow;
                    const result = try self.checkAndTransformFlow(flow, program, item_idx);
                    if (result.transformed) return result;
                },
                .module_decl => {
                    const module = &item.module_decl;
                    for (module.items, 0..) |*mod_item, mod_item_idx| {
                        if (mod_item.* == .flow) {
                            const flow = &mod_item.flow;
                            _ = mod_item_idx;
                            const result = try self.checkAndTransformFlow(flow, program, item_idx);
                            if (result.transformed) return result;
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
        self: *AutoDisposeInserter,
        flow: *const ast.Flow,
        program: *const ast.Program,
        _: usize,
    ) !TransformResult {
        // Skip already-processed flows
        for (flow.invocation.annotations) |ann| {
            if (std.mem.startsWith(u8, ann, "@auto_dispose_ran")) {
                return .{ .transformed = false, .program = program };
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

        // Check if this is a loop-like flow (for, while, loop)
        const is_loop_flow = std.mem.eql(u8, event_name, "for") or
            std.mem.eql(u8, event_name, "while") or
            std.mem.eql(u8, event_name, "loop");

        // Walk continuations looking for terminators with obligations
        var context = BindingContext.init(self.allocator);
        defer context.deinit();

        for (flow.continuations) |*cont| {
            // If this is a loop flow and we're in the "each" branch, enter a new scope
            if (is_loop_flow and std.mem.eql(u8, cont.branch, "each")) {
                var loop_context = try context.clone(self.allocator);
                defer loop_context.deinit();
                loop_context.enterScope(true); // Repeating scope

                const result = try self.checkContinuation(cont, event_info.decl, module_name, &loop_context, program, flow);
                if (result.transformed) return result;
            } else {
                const result = try self.checkContinuation(cont, event_info.decl, module_name, &context, program, flow);
                if (result.transformed) return result;
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a continuation for terminators with obligations
    fn checkContinuation(
        self: *AutoDisposeInserter,
        cont: *const ast.Continuation,
        event_decl: *const ast.EventDecl,
        module_name: []const u8,
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
    ) !TransformResult {
        // Clone context for this branch
        var context = try parent_context.clone(self.allocator);
        defer context.deinit();

        // Handle discard binding (_) - synthesize a real binding name
        // This must happen BEFORE we process the continuation so the binding can be used
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

        // Add bindings from this branch
        if (cont.binding) |binding_name| {
            // Find the branch in the event declaration
            for (event_decl.branches) |branch| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    // Add each field with phantom annotation
                    for (branch.payload.fields) |field| {
                        if (field.phantom) |phantom_str| {
                            const field_path = try std.fmt.allocPrint(
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

        // Check if this continuation has a terminal node
        if (cont.node) |node| {
            if (node == .terminal) {
                // Found a terminator - check for unsatisfied obligations
                // Only dispose obligations from CURRENT scope
                // Outer-scope obligations will be handled at a non-repeating terminal (like `done`)
                if (context.hasObligations()) {
                    // Count how many obligations are from current scope
                    var current_scope_count: u32 = 0;
                    var obl_iter = context.obligations();
                    while (obl_iter.next()) |entry| {
                        if (entry.value_ptr.scope_depth == context.scope_depth) {
                            current_scope_count += 1;
                        }
                    }

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

            // Check invocations for obligation satisfaction
            // (when binding is passed to [!state] parameter)
            if (node == .invocation) {
                try self.checkInvocationSatisfiesObligations(&context, &node.invocation, module_name, flow);
            }

            // Handle foreach nodes - recurse into branches with scope tracking
            if (node == .foreach) {
                const result = try self.checkForeachNode(node.foreach.branches, &context, program, flow, module_name);
                if (result.transformed) return result;
            }

            // Handle conditional nodes - recurse into branches
            if (node == .conditional) {
                const cond = &node.conditional;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        const result = try self.checkContinuation(body_cont, event_decl, module_name, &context, program, flow);
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
            var is_loop_invocation = false;

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

                    // Check if this is a loop-like invocation (for, while, etc.)
                    // by looking at the event name
                    is_loop_invocation = std.mem.eql(u8, inv_event_name, "for") or
                        std.mem.eql(u8, inv_event_name, "while") or
                        std.mem.eql(u8, inv_event_name, "loop");
                }
            }

            // If this is a loop invocation and we're entering the "each" branch,
            // treat it as a scope boundary (before the transform creates ForeachNode)
            if (is_loop_invocation and std.mem.eql(u8, nested.branch, "each")) {
                var loop_context = try context.clone(self.allocator);
                defer loop_context.deinit();
                loop_context.enterScope(true); // Repeating scope

                const result = try self.checkContinuation(nested, nested_event, nested_module, &loop_context, program, flow);
                if (result.transformed) return result;
            } else {
                const result = try self.checkContinuation(nested, nested_event, nested_module, &context, program, flow);
                if (result.transformed) return result;
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a foreach node for terminators with obligations
    /// Handles scope tracking: `each` branch is repeating, `done` is not
    fn checkForeachNode(
        self: *AutoDisposeInserter,
        branches: []const ast.NamedBranch, // The foreach branches
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        module_name: []const u8,
    ) RecursiveError!TransformResult {
        // Increment scope BEFORE recording loop entry
        // This ensures obligations created before the loop are at a lower scope
        parent_context.scope_depth += 1;

        // Mark that we're inside a loop - obligations from before this point
        // cannot be auto-disposed inside any branch of this loop
        parent_context.enterLoop();

        // Process each branch of the foreach
        for (branches) |*branch| {
            // The "each" branch is the repeating scope boundary
            const is_each_branch = std.mem.eql(u8, branch.name, "each");

            // Clone context and set up scope for this branch
            var branch_context = try parent_context.clone(self.allocator);
            defer branch_context.deinit();

            if (is_each_branch) {
                // Enter a new repeating scope for the "each" branch (runs N times)
                branch_context.enterScope(true);
            }
            // Note: branches without [@scope] stay at parent scope and is_repeating = false
            // (unless parent was already repeating, which is inherited via clone)

            // Process continuations in this branch
            for (branch.body) |*body_cont| {
                // We need a dummy event_decl for the body - use the flow's event
                // or create a synthetic one. For now, use a placeholder approach
                // where we look up events for any invocations we encounter.
                const result = try self.checkForeachBranchContinuation(
                    body_cont,
                    &branch_context,
                    program,
                    flow,
                    module_name,
                );
                if (result.transformed) return result;
            }
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check a continuation inside a foreach branch (no event_decl binding tracking)
    fn checkForeachBranchContinuation(
        self: *AutoDisposeInserter,
        cont: *const ast.Continuation,
        parent_context: *BindingContext,
        program: *const ast.Program,
        flow: *const ast.Flow,
        module_name: []const u8,
    ) RecursiveError!TransformResult {
        // Clone context for this continuation
        var context = try parent_context.clone(self.allocator);
        defer context.deinit();

        // Handle discard binding (_) - synthesize a real binding name
        // This must happen BEFORE we process the continuation so the binding can be used
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

        // Check if this continuation has a node
        if (cont.node) |node| {
            if (node == .terminal) {
                // Found a terminator - check for obligations to dispose
                //
                // NOTE: Pre-loop obligations in repeating context are OK here!
                // They "flow through" the loop and will be handled at the `done` branch.
                // We only error for pre-loop obligations when:
                // 1. Trying to INSERT auto-disposal (checked in insertDisposalsInForeach)
                // 2. Manually disposing via invocation (checked in checkInvocationSatisfiesObligations)

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

                    if (current_scope_count > 0) {
                        // We have current-scope obligations to dispose
                        return try self.insertDisposalsInForeach(cont, &context, program, flow);
                    }
                    // Outer-scope obligations exist but not current-scope ones
                    // In a repeating context, this is OK - they'll be handled at `done`
                    // In a non-repeating context, they should be disposed here
                    if (!context.is_repeating) {
                        // Non-repeating: dispose all remaining obligations
                        return try self.insertDisposalsInForeach(cont, &context, program, flow);
                    }
                    // Repeating: outer obligations will flow through to `done`
                }
            }

            // Handle invocations - look up event and check for obligation satisfaction + binding creation
            if (node == .invocation) {
                const invocation = &node.invocation;
                try self.checkInvocationSatisfiesObligations(&context, invocation, module_name, flow);

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
                                            const field_path = try std.fmt.allocPrint(
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

                        const result = try self.checkForeachBranchContinuation(nested, &context, program, flow, info.module_name);
                        if (result.transformed) return result;
                    }
                }
                // If event not found, still recurse into continuations
                else {
                    for (cont.continuations) |*nested| {
                        const result = try self.checkForeachBranchContinuation(nested, &context, program, flow, module_name);
                        if (result.transformed) return result;
                    }
                }

                return .{ .transformed = false, .program = program };
            }

            // Handle nested foreach
            if (node == .foreach) {
                const result = try self.checkForeachNode(node.foreach.branches, &context, program, flow, module_name);
                if (result.transformed) return result;
            }

            // Handle conditional
            if (node == .conditional) {
                const cond = &node.conditional;
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        const result = try self.checkForeachBranchContinuation(body_cont, &context, program, flow, module_name);
                        if (result.transformed) return result;
                    }
                }
            }
        }

        // Check nested continuations
        for (cont.continuations) |*nested| {
            const result = try self.checkForeachBranchContinuation(nested, &context, program, flow, module_name);
            if (result.transformed) return result;
        }

        return .{ .transformed = false, .program = program };
    }

    /// Insert disposals for obligations inside a foreach (placeholder - needs AST surgery)
    fn insertDisposalsInForeach(
        self: *AutoDisposeInserter,
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

                if (disposals.len == 0) {
                    try self.reporter.addError(
                        .KORU030,
                        flow.location.line,
                        flow.location.column,
                        "No disposal event found for resource '{s}' with state '{s}'.",
                        .{ binding_path, info.phantom_state },
                    );
                    return error.ValidationFailed;
                } else if (disposals.len > 1) {
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
                        "Multiple disposal options for resource '{s}': {s}.",
                        .{ binding_path, fbs.getWritten() },
                    );
                    return error.ValidationFailed;
                }

                // Insert the disposal - this requires finding and replacing the continuation in the AST
                const disposal = disposals[0];

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
        self: *AutoDisposeInserter,
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

                        if (parsed == .concrete and parsed.concrete.consumes_obligation) {
                            // ERROR: Cannot manually dispose pre-loop obligation in repeating context
                            if (context.is_repeating) {
                                // Check if this is a pre-loop obligation
                                const loop_entry = context.loop_entry_scope orelse 0;
                                if (context.cleanup_obligations.get(arg.value)) |obl_info| {
                                    if (obl_info.scope_depth < loop_entry) {
                                        try self.reporter.addError(
                                            .KORU032,
                                            flow.location.line,
                                            flow.location.column,
                                            "Cannot dispose outer-scope resource '{s}' inside repeating loop body. Handle at '| done |>' or escape via branch constructor.",
                                            .{arg.value},
                                        );
                                        return error.ValidationFailed;
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
        self: *AutoDisposeInserter,
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

            if (disposals.len == 0) {
                // Error: no disposal event found
                try self.reporter.addError(
                    .KORU030,
                    flow.location.line,
                    flow.location.column,
                    "No disposal event found for resource '{s}' with state '{s}'. Library must define an event with [!{s}] parameter.",
                    .{ binding_path, info.phantom_state, info.phantom_state },
                );
                return error.ValidationFailed;
            } else if (disposals.len > 1) {
                // Error: multiple disposal options
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
                    "Multiple disposal options for resource '{s}': {s}. Be explicit about which to use.",
                    .{ binding_path, fbs.getWritten() },
                );
                return error.ValidationFailed;
            }

            // Exactly one disposal - insert it!
            const disposal = disposals[0];


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

    /// Find all events that can dispose a given phantom state
    fn findDisposalEvents(self: *AutoDisposeInserter, phantom_state: []const u8) ![]DisposalEvent {
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
                                    });
                                }
                            }
                        },
                        .variable => {},
                    }
                }
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    /// Create a new continuation with disposal call inserted before terminal
    fn createDisposalContinuation(
        self: *AutoDisposeInserter,
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

        // Find the first branch of the disposal event to create continuation
        var disposal_branch: []const u8 = "done"; // default
        for (disposal.event_decl.branches) |branch| {
            disposal_branch = branch.name;
            break;
        }

        // Create terminal continuation
        var terminal_cont = try self.allocator.alloc(ast.Continuation, 1);
        terminal_cont[0] = .{
            .branch = try self.allocator.dupe(u8, disposal_branch),
            .binding = null,
            .binding_annotations = &[_][]const u8{},
            .condition = null,
            .node = .terminal,
            .indent = original.indent + 1,
            .continuations = &[_]ast.Continuation{},
            .location = original.location,
        };

        // Return modified continuation with invocation instead of terminal
        return .{
            .branch = try self.allocator.dupe(u8, original.branch),
            .binding = if (original.binding) |b| try self.allocator.dupe(u8, b) else null,
            .binding_annotations = original.binding_annotations,
            .condition = if (original.condition) |c| try self.allocator.dupe(u8, c) else null,
            .node = .{ .invocation = disposal_invocation },
            .indent = original.indent,
            .continuations = terminal_cont,
            .location = original.location,
        };
    }

    /// Replace a continuation in a flow
    fn replaceContInFlow(
        self: *AutoDisposeInserter,
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
        self: *AutoDisposeInserter,
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
        self: *AutoDisposeInserter,
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
                    new_branches[bi] = .{
                        .name = try self.allocator.dupe(u8, branch.name),
                        .body = new_body,
                        .binding = if (branch.binding) |b| try self.allocator.dupe(u8, b) else null,
                        .is_optional = branch.is_optional,
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
                    new_branches[bi] = .{
                        .name = try self.allocator.dupe(u8, branch.name),
                        .body = new_body,
                        .binding = if (branch.binding) |b| try self.allocator.dupe(u8, b) else null,
                        .is_optional = branch.is_optional,
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

    /// Mark a flow as processed with @auto_dispose_ran annotation
    fn markFlowProcessed(self: *AutoDisposeInserter, flow: ast.Flow) !ast.Flow {
        var new_annotations = try self.allocator.alloc([]const u8, flow.invocation.annotations.len + 1);

        for (flow.invocation.annotations, 0..) |ann, i| {
            new_annotations[i] = try self.allocator.dupe(u8, ann);
        }
        new_annotations[flow.invocation.annotations.len] = try self.allocator.dupe(u8, "@auto_dispose_ran");

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
    fn canonicalizePhantom(self: *AutoDisposeInserter, phantom_str: []const u8, module: []const u8) ![]const u8 {
        var parsed = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
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
        }
    }

    /// Convert a dotted path to a string
    fn pathToString(self: *AutoDisposeInserter, path: ast.DottedPath) ![]const u8 {
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
    fn generateSyntheticBinding(self: *AutoDisposeInserter) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "_auto_{d}", .{self.synthetic_binding_counter});
        self.synthetic_binding_counter += 1;
        return name;
    }

    /// Clone a continuation with a new binding name
    /// This preserves ALL metadata by copying fields, only changing the binding
    fn cloneContinuationWithBinding(
        self: *AutoDisposeInserter,
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
};
