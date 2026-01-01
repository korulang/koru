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

        const BindingInfo = struct {
            phantom_state: []const u8,
            field_name: []const u8, // e.g., "file" for f.file
        };

        fn init(allocator: std.mem.Allocator) BindingContext {
            return .{
                .bindings = std.StringHashMap([]const u8).init(allocator),
                .cleanup_obligations = std.StringHashMap(BindingInfo).init(allocator),
                .allocator = allocator,
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
                });
            }

            return new_ctx;
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

        // Walk continuations looking for terminators with obligations
        var context = BindingContext.init(self.allocator);
        defer context.deinit();

        for (flow.continuations) |*cont| {
            const result = try self.checkContinuation(cont, event_info.decl, module_name, &context, program, flow);
            if (result.transformed) return result;
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
                if (context.hasObligations()) {
                    return try self.insertDisposals(cont, &context, program, flow, event_decl, module_name);
                }
            }

            // Check invocations for obligation satisfaction
            // (when binding is passed to [!state] parameter)
            if (node == .invocation) {
                try self.checkInvocationSatisfiesObligations(&context, &node.invocation, module_name);
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

            const result = try self.checkContinuation(nested, nested_event, nested_module, &context, program, flow);
            if (result.transformed) return result;
        }

        return .{ .transformed = false, .program = program };
    }

    /// Check if an invocation satisfies any obligations (explicit cleanup)
    fn checkInvocationSatisfiesObligations(
        self: *AutoDisposeInserter,
        context: *BindingContext,
        invocation: *const ast.Invocation,
        module_name: []const u8,
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
                            // This parameter consumes an obligation - check if arg satisfies one
                            // The arg.value should be something like "f.file"
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
        var obl_iter = context.obligations();
        while (obl_iter.next()) |entry| {
            const binding_path = entry.key_ptr.*;
            const info = entry.value_ptr.*;

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

            // Replace in the flow
            const new_flow = try self.replaceContInFlow(flow, cont, new_cont);

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

        return .{
            .invocation = try ast_functional.cloneInvocation(self.allocator, &flow.invocation),
            .continuations = new_continuations,
            .location = flow.location,
            .module = try self.allocator.dupe(u8, flow.module),
            .pre_label = if (flow.pre_label) |l| try self.allocator.dupe(u8, l) else null,
        };
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

        return .{
            .invocation = new_invocation,
            .continuations = flow.continuations,
            .location = flow.location,
            .module = flow.module,
            .pre_label = flow.pre_label,
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
};
