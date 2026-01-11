// Phantom Semantic Checker - Validates module-qualified phantom states
const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const phantom_parser = @import("phantom_parser");

/// Checks that module-qualified phantom states reference valid imported modules
pub const PhantomSemanticChecker = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    module_map: std.StringHashMap([]const u8),
    label_map: std.StringHashMap(*const ast.EventDecl),

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !PhantomSemanticChecker {
        return PhantomSemanticChecker{
            .allocator = allocator,
            .reporter = reporter,
            .module_map = std.StringHashMap([]const u8).init(allocator),
            .label_map = std.StringHashMap(*const ast.EventDecl).init(allocator),
        };
    }

    pub fn deinit(self: *PhantomSemanticChecker) void {
        self.module_map.deinit();
        self.label_map.deinit();
    }

    /// Check phantom types in the entire AST
    pub fn check(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !void {
        std.debug.print("\n[PHANTOM-CHECK] Starting phantom semantic check for program with {d} items\n", .{source_ast.items.len});
        // Track if we found any errors (but continue checking to find all of them)
        var has_errors = false;

        // Pass 1: Build module resolution map from imports
        try self.buildModuleMap(source_ast);

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
            std.debug.print("[PHANTOM] Returning ValidationFailed - annotations_valid={}, flows_valid={}\n", .{annotations_valid, flows_valid});
            return error.ValidationFailed;
        }
        std.debug.print("[PHANTOM] All validation passed!\n", .{});
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


    fn validatePhantomAnnotations(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !bool {
        var has_errors = false;

        for (source_ast.items) |item| {
            switch (item) {
                .event_decl => |event_decl| {
                    // Check input fields
                    for (event_decl.input.fields) |field| {
                        if (field.phantom) |phantom_str| {
                            const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location);
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
                                const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location);
                                if (!phantom_valid) {
                                    has_errors = true;
                                    // Continue checking for more errors
                                }
                            }
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
                                    const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location);
                                    if (!phantom_valid) {
                                        has_errors = true;
                                        // Continue checking for more errors
                                    }
                                }
                            }

                            for (event_decl.branches) |branch| {
                                for (branch.payload.fields) |field| {
                                    if (field.phantom) |phantom_str| {
                                        const phantom_valid = try self.validatePhantom(phantom_str, event_decl.path.segments[0], event_decl.location);
                                        if (!phantom_valid) {
                                            has_errors = true;
                                            // Continue checking for more errors
                                        }
                                    }
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

    fn validatePhantom(self: *PhantomSemanticChecker, phantom_str: []const u8, event_name: []const u8, location: errors.SourceLocation) !bool {
        var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
        defer phantom.deinit(self.allocator);

        switch (phantom) {
            .concrete => |concrete| {
                if (concrete.module_path) |mod_path| {
                    if (!self.module_map.contains(mod_path)) {
                        try self.reporter.addError(
                            .KORU040, // Unknown event/proc/subflow - using for unknown module
                            location.line,
                            location.column,
                            "Unknown module '{s}' in phantom type annotation '{s}' (event: {s}). Module not imported.",
                            .{mod_path, phantom_str, event_name}
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
                // Validate each member of the union
                for (u.members) |member| {
                    if (member.module_path) |mod_path| {
                        if (!self.module_map.contains(mod_path)) {
                            try self.reporter.addError(
                                .KORU040,
                                location.line,
                                location.column,
                                "Unknown module '{s}' in phantom type annotation '{s}' (event: {s}). Module not imported.",
                                .{mod_path, phantom_str, event_name}
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
        var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
        defer phantom.deinit(self.allocator);

        switch (phantom) {
            .concrete => |concrete| {
                const canonical_module = if (concrete.module_path) |mod_path| blk: {
                    // Already has module qualifier - resolve it through module_map
                    if (self.module_map.get(mod_path)) |canonical| {
                        break :blk canonical;
                    } else {
                        // Module not found - use as-is (error will be caught in validation)
                        break :blk mod_path;
                    }
                } else blk: {
                    // No module qualifier - use the defining module
                    break :blk defining_module;
                };

                // Build canonical form: module:state or module:state!
                const cleanup_suffix = if (concrete.requires_cleanup) "!" else "";
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{s}:{s}{s}",
                    .{canonical_module, concrete.name, cleanup_suffix}
                );
            },
            .variable => {
                // State variables don't get canonicalized - they're constraints
                return try self.allocator.dupe(u8, phantom_str);
            },
            .state_union => |u| {
                // Canonicalize each member of the union
                var result: std.ArrayListUnmanaged(u8) = .{};
                errdefer result.deinit(self.allocator);

                // Add consume prefix if present
                if (u.consumes_obligation) {
                    try result.append(self.allocator, '!');
                }

                for (u.members, 0..) |member, i| {
                    if (i > 0) try result.append(self.allocator, '|');

                    const canonical_module = if (member.module_path) |mod_path| blk: {
                        if (self.module_map.get(mod_path)) |canonical| {
                            break :blk canonical;
                        } else {
                            break :blk mod_path;
                        }
                    } else blk: {
                        break :blk defining_module;
                    };

                    // Append module:state
                    try result.appendSlice(self.allocator, canonical_module);
                    try result.append(self.allocator, ':');
                    try result.appendSlice(self.allocator, member.name);
                }

                return result.toOwnedSlice(self.allocator);
            },
        }
    }

    /// Binding context tracks phantom states of variables in scope
    const BindingContext = struct {
        bindings: std.StringHashMap([]const u8), // variable name → phantom state string
        cleanup_obligations: std.StringHashMap(void), // track bindings with ! states that need cleanup
        disposed_bindings: std.StringHashMap(void), // track bindings that have been disposed (poisoned)
        outer_scope_obligations: std.StringHashMap(void), // track obligations from outside @scope boundary
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) BindingContext {
            return BindingContext{
                .bindings = std.StringHashMap([]const u8).init(allocator),
                .cleanup_obligations = std.StringHashMap(void).init(allocator),
                .disposed_bindings = std.StringHashMap(void).init(allocator),
                .outer_scope_obligations = std.StringHashMap(void).init(allocator),
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

            // Free cleanup obligation keys
            var cleanup_iter = self.cleanup_obligations.keyIterator();
            while (cleanup_iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.cleanup_obligations.deinit();

            // Free disposed binding keys
            var disposed_iter = self.disposed_bindings.keyIterator();
            while (disposed_iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.disposed_bindings.deinit();

            // Free outer scope obligation keys
            var outer_iter = self.outer_scope_obligations.keyIterator();
            while (outer_iter.next()) |key| {
                self.allocator.free(key.*);
            }
            self.outer_scope_obligations.deinit();
        }

        fn set(self: *BindingContext, name: []const u8, phantom_state: []const u8) !void {
            // Remove old binding if exists
            if (self.bindings.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }

            // Add new binding
            const name_copy = try self.allocator.dupe(u8, name);
            const phantom_copy = try self.allocator.dupe(u8, phantom_state);
            try self.bindings.put(name_copy, phantom_copy);

            // Check if this phantom state has cleanup obligation (! suffix)
            var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_state);
            defer phantom.deinit(self.allocator);

            switch (phantom) {
                .concrete => |concrete| {
                    if (concrete.requires_cleanup) {
                        // Track this binding as requiring cleanup
                        const obligation_key = try self.allocator.dupe(u8, name);
                        try self.cleanup_obligations.put(obligation_key, {});
                        std.debug.print("[CLEANUP] Tracking cleanup obligation for '{s}' with state '{s}'\n", .{name, phantom_state});
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

        fn get(self: *BindingContext, name: []const u8) ?[]const u8 {
            return self.bindings.get(name);
        }

        /// Create a child context that inherits parent's state
        fn inherit(parent: *const BindingContext, allocator: std.mem.Allocator) !BindingContext {
            var child = BindingContext.init(allocator);

            // Inherit all bindings
            var bind_iter = parent.bindings.iterator();
            while (bind_iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = try allocator.dupe(u8, entry.value_ptr.*);
                try child.bindings.put(key, value);
            }

            // Inherit cleanup obligations
            var clean_iter = parent.cleanup_obligations.keyIterator();
            while (clean_iter.next()) |key| {
                const key_copy = try allocator.dupe(u8, key.*);
                try child.cleanup_obligations.put(key_copy, {});
            }

            // Inherit disposed bindings
            var disposed_iter = parent.disposed_bindings.keyIterator();
            while (disposed_iter.next()) |key| {
                const key_copy = try allocator.dupe(u8, key.*);
                try child.disposed_bindings.put(key_copy, {});
            }

            // Inherit outer scope obligations (already marked as outer)
            var outer_iter = parent.outer_scope_obligations.keyIterator();
            while (outer_iter.next()) |key| {
                const key_copy = try allocator.dupe(u8, key.*);
                try child.outer_scope_obligations.put(key_copy, {});
            }

            return child;
        }

        /// Create a child context that marks all inherited cleanup obligations as "outer scope"
        /// Used when entering a @scope boundary - these obligations cannot be satisfied inside the scope
        fn inheritWithScope(parent: *const BindingContext, allocator: std.mem.Allocator) !BindingContext {
            var child = BindingContext.init(allocator);

            // Inherit all bindings
            var bind_iter = parent.bindings.iterator();
            while (bind_iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = try allocator.dupe(u8, entry.value_ptr.*);
                try child.bindings.put(key, value);
            }

            // Inherit cleanup obligations AND mark them as outer scope
            var clean_iter = parent.cleanup_obligations.keyIterator();
            while (clean_iter.next()) |key| {
                const key_copy = try allocator.dupe(u8, key.*);
                try child.cleanup_obligations.put(key_copy, {});
                // Mark as outer scope - these cannot be satisfied inside @scope
                const outer_key = try allocator.dupe(u8, key.*);
                try child.outer_scope_obligations.put(outer_key, {});
            }

            // Inherit disposed bindings
            var disposed_iter = parent.disposed_bindings.keyIterator();
            while (disposed_iter.next()) |key| {
                const key_copy = try allocator.dupe(u8, key.*);
                try child.disposed_bindings.put(key_copy, {});
            }

            // Also inherit any already-marked outer scope obligations from parent
            var outer_iter = parent.outer_scope_obligations.keyIterator();
            while (outer_iter.next()) |key| {
                if (!child.outer_scope_obligations.contains(key.*)) {
                    const key_copy = try allocator.dupe(u8, key.*);
                    try child.outer_scope_obligations.put(key_copy, {});
                }
            }

            return child;
        }

        /// Remove cleanup obligation for a binding (called when it's properly cleaned up)
        fn clearCleanupObligation(self: *BindingContext, name: []const u8) void {
            if (self.cleanup_obligations.fetchRemove(name)) |kv| {
                self.allocator.free(kv.key);
                std.debug.print("[CLEANUP] Cleared cleanup obligation for '{s}'\n", .{name});
            }
        }

        /// Mark a binding as disposed (poisoned - cannot be used anymore)
        fn markDisposed(self: *BindingContext, name: []const u8) !void {
            const disposed_key = try self.allocator.dupe(u8, name);
            try self.disposed_bindings.put(disposed_key, {});
            std.debug.print("[CLEANUP] Marked '{s}' as disposed (poisoned)\n", .{name});
        }

        /// Check if a binding has been disposed
        fn isDisposed(self: *BindingContext, name: []const u8) bool {
            return self.disposed_bindings.contains(name);
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
    };

    /// Event info for flow validation
    const EventInfo = struct {
        decl: *const ast.EventDecl,
    };

    fn validatePhantomFlows(self: *PhantomSemanticChecker, source_ast: *const ast.Program) !bool {
        std.debug.print("[PHANTOM-FLOW] Pass 2: Validating phantom flows\n", .{});

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
        std.debug.print("[PHANTOM-FLOW] Built event map with {} events\n", .{event_map.count()});

        // Validate all flows/procs, tracking module context
        return self.validateItems(source_ast.items, &event_map, null);
    }

    fn validateItems(self: *PhantomSemanticChecker, items: []const ast.Item, event_map: *std.StringHashMap(EventInfo), current_module: ?[]const u8) !bool {
        var has_errors = false;

        for (items) |item| {
            switch (item) {
                .flow => |*flow| {
                    const module = flow.module; // Already qualified for top-level or from module_decl.items walk
                    std.debug.print("[PHANTOM-FLOW] Validating flow in module '{s}'\n", .{module});
                    if (!try self.validateFlow(flow, event_map, module, null)) {
                        has_errors = true;
                    }
                },
                .proc_decl => |*proc| {
                    const module = proc.module;
                    std.debug.print("[PHANTOM-FLOW] Validating proc '{s}' in module '{s}'\n", .{try self.pathToString(proc.path), module});
                    for (proc.inline_flows) |*flow| {
                        if (!try self.validateFlow(flow, event_map, module, null)) {
                            has_errors = true;
                        }
                    }
                },
                .subflow_impl => |*sub| {
                    if (sub.body == .flow) {
                        const module = current_module orelse "input"; // Need to pass module context down
                        std.debug.print("[PHANTOM-FLOW] Validating subflow in module '{s}'\n", .{module});

                        // Look up the event this subflow implements
                        const impl_event_name = try self.pathToString(sub.event_path);
                        defer self.allocator.free(impl_event_name);

                        const impl_qualified = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}:{s}",
                            .{module, impl_event_name}
                        );
                        defer self.allocator.free(impl_qualified);

                        const impl_event: ?*const ast.EventDecl = if (event_map.get(impl_qualified)) |info| info.decl else null;

                        if (impl_event) |ev| {
                            std.debug.print("[PHANTOM-FLOW]   Subflow implements event: '{s}'\n", .{impl_qualified});
                            _ = ev;
                        } else {
                            std.debug.print("[PHANTOM-FLOW]   Subflow event '{s}' not found in event map\n", .{impl_qualified});
                        }

                        if (!try self.validateFlow(&sub.body.flow, event_map, module, impl_event)) {
                            has_errors = true;
                        }
                    }
                },
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

                    // Store with module:event format (using : separator, not .)
                    const qualified_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}:{s}",
                        .{event_decl.module, event_name}
                    );
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
                            const qualified_name = try std.fmt.allocPrint(
                                self.allocator,
                                "{s}:{s}",
                                .{module.logical_name, event_name}
                            );
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
        implementing_event: ?*const ast.EventDecl,  // Event this flow implements (for branch_constructor escape checking)
    ) !bool {
        // Skip flows that have been transformed by [transform] events.
        // Transformed flows have valid structure by construction - the transform
        // replaced the comptime event structure with a runtime node structure.
        for (flow.invocation.annotations) |ann| {
            if (std.mem.startsWith(u8, ann, "@pass_ran")) {
                return true;  // Valid - transform output is correct by construction
            }
        }

        var has_errors = false;

        // Get the event name from path segments
        const event_name = try self.pathToString(flow.invocation.path);
        defer self.allocator.free(event_name);

        // Determine the module - use module_qualifier if present, otherwise current_module
        const module_name = flow.invocation.path.module_qualifier orelse current_module;

        // Build fully-qualified event name (module:event)
        const qualified_name = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{module_name, event_name}
        );
        defer self.allocator.free(qualified_name);

        std.debug.print("[PHANTOM-FLOW]   Flow invokes: '{s}' in module '{s}' → qualified: '{s}'\n",
            .{event_name, module_name, qualified_name});

        const event_info = event_map.get(qualified_name) orelse {
            std.debug.print("[PHANTOM-FLOW]   Event '{s}' not found in map, skipping\n", .{qualified_name});
            // Event not found - shape_checker will catch this, we just skip
            return true;
        };

        std.debug.print("[PHANTOM-FLOW]   Found event '{s}', validating continuations\n", .{qualified_name});

        // For each continuation, validate phantom state flows
        // Pass both: current_module (where flow is defined, for name resolution)
        // and module_name (where event is defined, for phantom qualification)
        for (flow.continuations) |*cont_ptr| {
            const cont_valid = try self.validateContinuation(cont_ptr, event_info.decl, module_name, current_module, event_map, flow.location, null, implementing_event);
            if (!cont_valid) {
                has_errors = true;
                // Continue checking for more errors
            }
        }

        return !has_errors;
    }

    fn validateContinuation(
        self: *PhantomSemanticChecker,
        cont: *const ast.Continuation,
        event_decl: *const ast.EventDecl,
        event_module: ?[]const u8,  // Module where the event is defined (for phantom qualification)
        flow_module: []const u8,    // Module where the flow is defined (for name resolution)
        event_map: *std.StringHashMap(EventInfo),
        location: errors.SourceLocation,
        parent_context: ?*const BindingContext,  // Optional parent context to inherit from
        implementing_event: ?*const ast.EventDecl,  // Event this flow implements (for branch_constructor escape)
    ) anyerror!bool {
        var has_errors = false;

        std.debug.print("[PHANTOM-FLOW]   Continuation branch: '{s}'\n", .{cont.branch});

        // Debug: print event path and branches
        const event_path = try self.pathToString(event_decl.path);
        defer self.allocator.free(event_path);
        std.debug.print("[PHANTOM-FLOW]   Event has path: '{s}', {} branches:\n", .{event_path, event_decl.branches.len});
        for (event_decl.branches) |branch| {
            std.debug.print("[PHANTOM-FLOW]     - '{s}'\n", .{branch.name});
        }

        // Void events (0 branches) have implicit continuations - skip branch validation
        // The continuation just chains to the next event after the void event completes
        if (event_decl.branches.len == 0) {
            std.debug.print("[PHANTOM-FLOW]   (void event - skipping branch validation)\n", .{});
            // Create binding context for void event continuation
            var void_context = if (parent_context) |parent|
                try BindingContext.inherit(parent, self.allocator)
            else
                BindingContext.init(self.allocator);
            defer void_context.deinit();

            // Still validate the step if present
            if (cont.node) |*step| {
                const step_valid = try self.validateStep(step, &void_context, event_map, flow_module, location);
                if (!step_valid) {
                    return false;
                }

                // If step is an invocation, nested continuations belong to THAT event, not the void parent
                switch (step.*) {
                    .invocation => |*inv| {
                        const step_event_name = try self.pathToString(inv.path);
                        defer self.allocator.free(step_event_name);
                        const step_module = inv.path.module_qualifier orelse flow_module;
                        const step_qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ step_module, step_event_name });
                        defer self.allocator.free(step_qualified);

                        if (event_map.get(step_qualified)) |step_event_info| {
                            // Validate nested continuations against the step's event
                            for (cont.continuations) |*nested| {
                                const nested_valid = try self.validateContinuation(nested, step_event_info.decl, step_module, flow_module, event_map, location, &void_context, implementing_event);
                                if (!nested_valid) {
                                    return false;
                                }
                            }
                            return true;
                        }
                    },
                    else => {},
                }
            }
            // Validate nested continuations recursively (fallback: against void event)
            for (cont.continuations) |*nested| {
                const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, &void_context, implementing_event);
                if (!nested_valid) {
                    return false;
                }
            }
            return true;
        }

        // Catch-all continuations (|?) don't reference a specific branch
        // They handle all unhandled branches, so skip branch validation
        if (cont.is_catchall) {
            std.debug.print("[PHANTOM-FLOW]   (catch-all continuation - skipping branch validation)\n", .{});
            // Still validate nested continuations if present
            for (cont.continuations) |*nested| {
                const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, null, implementing_event);
                if (!nested_valid) {
                    return false;
                }
            }
            return true;
        }

        // Empty-branch continuations (|> ...) are void chain continuations
        // They don't reference a branch - they chain after a void event in the pipeline
        // NOTE: This is different from void EVENTS (0 branches) - this handles the continuation SYNTAX
        if (cont.branch.len == 0) {
            std.debug.print("[PHANTOM-FLOW]   (empty-branch void chain continuation - handling step/nested)\n", .{});
            // Create binding context for void chain continuation
            var void_chain_context = if (parent_context) |parent|
                try BindingContext.inherit(parent, self.allocator)
            else
                BindingContext.init(self.allocator);
            defer void_chain_context.deinit();

            // Validate the step if present
            if (cont.node) |*step| {
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
                            // Validate nested continuations against the step's event
                            for (cont.continuations) |*nested| {
                                const nested_valid = try self.validateContinuation(nested, step_event_info.decl, step_module, flow_module, event_map, location, &void_chain_context, implementing_event);
                                if (!nested_valid) {
                                    return false;
                                }
                            }
                            return true;
                        }
                    },
                    .inline_code => {
                        // inline_code is a void step (e.g., from print.ln transform)
                        // Nested continuations should still be validated against the PARENT event
                        // (not as a void chain) because they might be branch handlers for a previous invocation
                        // For example: |> work() |> print.ln("...") | done |> ...
                        // The | done |> is a branch of work(), not a void chain
                        for (cont.continuations) |*nested| {
                            const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, &void_chain_context, implementing_event);
                            if (!nested_valid) {
                                return false;
                            }
                        }
                        return true;
                    },
                    else => {},
                }
            }

            // Fallback: validate nested continuations (no step or unrecognized step)
            for (cont.continuations) |*nested| {
                const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, &void_chain_context, implementing_event);
                if (!nested_valid) {
                    return false;
                }
            }
            return true;
        }

        // Find the branch in the event declaration
        var branch_payload: ?*const ast.Shape = null;
        var branch_decl: ?*const ast.Branch = null;
        for (event_decl.branches) |*branch| {
            if (std.mem.eql(u8, branch.name, cont.branch)) {
                branch_payload = &branch.payload;
                branch_decl = branch;
                break;
            }
        }

        if (branch_payload == null) {
            // Unknown branch - this is an error!

            // Build list of available branches for error message
            var branch_list = std.ArrayList(u8){};
            defer branch_list.deinit(self.allocator);
            const writer = branch_list.writer(self.allocator);

            for (event_decl.branches, 0..) |branch, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("'{s}'", .{branch.name});
            }

            try self.reporter.addError(
                .KORU030, // Shape mismatch
                location.line,
                location.column,
                "Continuation expects branch '{s}' but event '{s}' only produces: {s}",
                .{cont.branch, event_path, branch_list.items}
            );
            return false;
        }

        // Build binding context - inherit from parent if provided
        var context = if (parent_context) |parent|
            try BindingContext.inherit(parent, self.allocator)
        else
            BindingContext.init(self.allocator);
        defer context.deinit();

        // Add binding with phantom states from branch payload
        // If there's no explicit binding, synthesize "_" to track the obligation
        const binding_name = cont.binding orelse "_";
        {
            for (branch_payload.?.fields) |field| {
                if (field.phantom) |phantom_str| {
                    // Construct field access: binding.field_name
                    const field_path = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}.{s}",
                        .{binding_name, field.name}
                    );
                    defer self.allocator.free(field_path);

                    // Canonicalize phantom state using event's qualified module name
                    const module_for_canon = event_module orelse event_decl.module;
                    const canonical_phantom = try self.canonicalizePhantomState(
                        phantom_str,
                        module_for_canon
                    );
                    defer self.allocator.free(canonical_phantom);

                    try context.set(field_path, canonical_phantom);
                }
            }
        }

        // Add branch-level phantoms (context state)
        if (branch_decl) |bd| {
            std.debug.print("[PHANTOM-FLOW]   Branch '{s}' has {} annotations\n", .{ bd.name, bd.annotations.len });
            for (bd.annotations, 0..) |ann, i| {
                std.debug.print("[PHANTOM-FLOW]     Branch Annotation[{}]: '{s}' (isPhantom={})\n", .{ i, ann, isPhantomAnnotation(ann) });
                if (isPhantomAnnotation(ann)) {
                    const module_for_canon = event_module orelse event_decl.module;
                    const canonical = try self.canonicalizePhantomState(ann, module_for_canon);
                    defer self.allocator.free(canonical);
                    std.debug.print("[PHANTOM-FLOW]     Storing context phantom for branch '{s}': '{s}' (canonical: '{s}')\n", .{ bd.name, ann, canonical });
                    try context.set("", canonical);
                }
            }
        }

        const step_count: usize = if (cont.node != null) 1 else 0;
        std.debug.print("[PHANTOM-FLOW]   Pipeline has {} steps\n", .{step_count});
        // Debug: print what's in the pipeline
        if (cont.node) |step| {
            std.debug.print("[PHANTOM-FLOW]     Step 0: {s}\n", .{@tagName(step)});
        }
        // Validate pipeline steps with this context
        // Use flow_module for name resolution (where the flow is defined)
        if (cont.node) |*step| {
            // If this is a label declaration, record it
            switch (step.*) {
                .label_with_invocation => |lwi| {
                    if (lwi.is_declaration) {
                        // Look up the event being invoked to use its signature for the label
                        const inv_event_name = try self.pathToString(lwi.invocation.path);
                        defer self.allocator.free(inv_event_name);
                        
                        const inv_module_name = lwi.invocation.path.module_qualifier orelse flow_module;
                        const qualified_name = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{inv_module_name, inv_event_name});
                        defer self.allocator.free(qualified_name);

                        if (event_map.get(qualified_name)) |inv_info| {
                            std.debug.print("[PHANTOM-FLOW]   Recording label '#{s}' mapping to event '{s}'\n", .{lwi.label, qualified_name});
                            try self.label_map.put(lwi.label, inv_info.decl);
                        } else {
                            std.debug.print("[PHANTOM-FLOW]   WARNING: Label '#{s}' points to unknown event '{s}'\n", .{lwi.label, qualified_name});
                        }
                    }
                },
                else => {},
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
            }
        }
        if (is_terminator) {
            const terminator_type = if (cont.node) |n| @tagName(n) else "empty";
            std.debug.print("[CLEANUP] Terminator detected ({s}), checking for uncleaned resources\n", .{terminator_type});
            if (context.hasUncleanedResources()) {
                const uncleaned = try context.getUncleanedResources(self.allocator);
                defer self.allocator.free(uncleaned);

                std.debug.print("[CLEANUP] Uncleaned resources found: {}\n", .{uncleaned.len});
                for (uncleaned) |resource| {
                    std.debug.print("[CLEANUP]   - '{s}'\n", .{resource});
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
                        std.debug.print("[CLEANUP] Branch constructor returns '{s}'\n", .{bc.branch_name});

                        if (implementing_event) |impl_ev| {
                            // Find the branch in the implementing event's declaration
                            for (impl_ev.branches) |branch| {
                                if (std.mem.eql(u8, branch.name, bc.branch_name)) {
                                    return_branch_fields = branch.payload.fields;
                                    std.debug.print("[CLEANUP]   Found return branch '{s}' with {} fields\n", .{bc.branch_name, branch.payload.fields.len});
                                    break;
                                }
                            }
                            if (return_branch_fields == null) {
                                std.debug.print("[CLEANUP]   WARNING: Branch '{s}' not found in implementing event\n", .{bc.branch_name});
                            }
                        } else {
                            std.debug.print("[CLEANUP]   No implementing_event - cannot check return signature\n", .{});
                        }
                    }
                }

                var lost_count: usize = 0;
                var first_lost: ?[]const u8 = null;

                for (uncleaned) |resource| {
                    // For hard terminals (_), all uncleaned resources are errors
                    var documented_escape = false;

                    // Only check for escape through signature if NOT a hard terminal
                    if (!is_hard_terminal) {
                        // Use return_branch_fields if available (branch_constructor case),
                        // otherwise fall back to incoming branch_payload
                        const fields_to_check = return_branch_fields orelse (if (branch_payload) |bp| bp.fields else null);

                        if (fields_to_check) |fields| {
                            for (fields) |field| {
                                if (field.phantom) |phantom_str| {
                                    // Parse to check for ! suffix
                                    var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
                                    defer phantom.deinit(self.allocator);

                                    switch (phantom) {
                                        .concrete => |concrete| {
                                            if (concrete.requires_cleanup) {
                                                // This field has ! in the signature
                                                // Check if it matches our uncleaned resource
                                                // Resource is "binding.field", so extract the field name
                                                if (std.mem.lastIndexOf(u8, resource, ".")) |dot_idx| {
                                                    const resource_field = resource[dot_idx + 1..];
                                                    if (std.mem.eql(u8, resource_field, field.name)) {
                                                        documented_escape = true;
                                                        std.debug.print("[CLEANUP]   '{s}' escapes through signature field '{s}' with [!]\n", .{resource, field.name});
                                                        break;
                                                    }
                                                }
                                            }
                                        },
                                        .variable => {},
                                        .state_union => {}, // Unions can't have cleanup markers
                                    }
                                }
                            }
                        }
                    }

                    if (!documented_escape) {
                        std.debug.print("[CLEANUP]   '{s}' NOT in signature - obligation lost\n", .{resource});
                        if (first_lost == null) {
                            first_lost = resource;
                        }
                        lost_count += 1;
                    }
                }

                // Only error if there are truly lost obligations (not documented in signature)
                if (lost_count > 0) {
                    std.debug.print("[CLEANUP] Lost obligations: {} - auto_dispose_inserter should have handled this\n", .{lost_count});

                    // Report error for each lost obligation
                    // (This is a safety net - inserter should have handled or errored)

                    // Use the same fields we used for detection
                    const fields_for_error = return_branch_fields orelse (if (branch_payload) |bp| bp.fields else null);

                    for (uncleaned) |resource| {
                        // Skip if it escapes through signature
                        var escapes = false;

                        // For hard terminals, nothing escapes
                        if (!is_hard_terminal) {
                            if (fields_for_error) |fields| {
                                for (fields) |field| {
                                    if (field.phantom) |phantom_str| {
                                        var phantom = try phantom_parser.PhantomState.parse(self.allocator, phantom_str);
                                        defer phantom.deinit(self.allocator);
                                        switch (phantom) {
                                            .concrete => |concrete| {
                                                if (concrete.requires_cleanup) {
                                                    if (std.mem.lastIndexOf(u8, resource, ".")) |dot_idx| {
                                                        if (std.mem.eql(u8, resource[dot_idx + 1..], field.name)) {
                                                            escapes = true;
                                                            break;
                                                        }
                                                    }
                                                }
                                            },
                                            .variable => {},
                                            .state_union => {}, // Unions can't have cleanup markers
                                        }
                                    }
                                }
                            }
                        }
                        if (escapes) continue;

                        // Get the phantom state for this resource
                        const phantom_state = context.get(resource) orelse {
                            std.debug.print("[CLEANUP] No phantom state found for '{s}'\n", .{resource});
                            continue;
                        };

                        // Report error - obligation was not satisfied
                        try self.reporter.addError(
                            .KORU030,
                            location.line,
                            location.column,
                            "Resource '{s}' with cleanup obligation '{s}' was not disposed. Call the disposal event explicitly.",
                            .{resource, phantom_state}
                        );
                        has_errors = true;
                    }
                } else {
                    std.debug.print("[CLEANUP] ✓ All obligations either cleaned or documented in signature\n", .{});
                }
            } else {
                std.debug.print("[CLEANUP] ✓ No uncleaned resources at terminator\n", .{});
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
                const qualified_name = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}:{s}",
                    .{module_name, event_name}
                );
                defer self.allocator.free(qualified_name);

                std.debug.print("[PHANTOM-FLOW]   Nested continuations belong to last invocation: '{s}'\n", .{qualified_name});

                const nested_event_info = event_map.get(qualified_name) orelse {
                    std.debug.print("[PHANTOM-FLOW]   Event '{s}' not found, skipping nested continuations\n", .{qualified_name});
                    return !has_errors;
                };

                // Validate nested continuations against the invoked event (not parent event)
                // Pass the current context down so disposed bindings propagate
                for (cont.continuations) |*nested| {
                    const nested_valid = try self.validateContinuation(nested, nested_event_info.decl, module_name, flow_module, event_map, location, &context, implementing_event);
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
                    std.debug.print("[PHANTOM-FLOW]   Step is inline_code (void completion), validating nested continuations as void event chain\n", .{});
                    for (cont.continuations) |*nested| {
                        const nested_valid = try self.validateContinuationAsVoidChain(nested, flow_module, event_map, location, &context, implementing_event);
                        if (!nested_valid) {
                            has_errors = true;
                        }
                    }
                } else {
                    // No invocations in pipeline - nested continuations still belong to parent event
                    std.debug.print("[PHANTOM-FLOW]   No invocations in pipeline, nested continuations belong to parent event\n", .{});
                    for (cont.continuations) |*nested| {
                        const nested_valid = try self.validateContinuation(nested, event_decl, event_module, flow_module, event_map, location, &context, implementing_event);
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
        location: errors.SourceLocation,
        parent_context: ?*const BindingContext,
        implementing_event: ?*const ast.EventDecl,
    ) anyerror!bool {
        var has_errors = false;

        std.debug.print("[PHANTOM-FLOW]   Void chain continuation, branch: '{s}'\n", .{cont.branch});

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
                        const qualified_name = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}:{s}",
                            .{resolved_module, event_name}
                        );
                        defer self.allocator.free(qualified_name);

                        if (event_map.get(qualified_name)) |event_info| {
                            // Validate nested continuations against this event
                            for (cont.continuations) |*nested| {
                                const nested_valid = try self.validateContinuation(nested, event_info.decl, resolved_module, flow_module orelse "unknown", event_map, location, &context, implementing_event);
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
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Continuation expects branch '{s}' but void event chain has no branches",
                .{cont.branch}
            );
            has_errors = true;
        }

        return !has_errors;
    }

    fn validateStep(
        self: *PhantomSemanticChecker,
        step: *const ast.Step,
        context: *BindingContext,
        event_map: *std.StringHashMap(EventInfo),
        current_module: ?[]const u8,
        location: errors.SourceLocation
    ) !bool {
        var has_errors = false;
        std.debug.print("[PHANTOM-FLOW] Validating step: {s}\n", .{@tagName(step.*)});

        switch (step.*) {
            .invocation => |inv| {
                return self.validateSingleInvocation(&inv, context, event_map, current_module, location);
            },
            .label_with_invocation => |lwi| {
                // If it's a declaration, validate the inner invocation
                if (lwi.is_declaration) {
                    return self.validateSingleInvocation(&lwi.invocation, context, event_map, current_module, location);
                } else {
                    // It's a jump without semantic args (legacy)
                    return true;
                }
            },
            .label_jump => |lj| {
                // Look up the target event for this label
                const target_decl = self.label_map.get(lj.label) orelse {
                    std.debug.print("[PHANTOM-FLOW]   Label '@{s}' not found in map, skipping jump validation\n", .{lj.label});
                    return true;
                };

                // Validate jump arguments against target event's signature
                for (lj.args) |arg| {
                    const arg_valid = try self.validateArgument(arg, target_decl, target_decl.module, context, location);
                    if (!arg_valid) {
                        has_errors = true;
                    }
                }

                // Validate event-level phantom preconditions for the jump
                const context_valid = try self.validateEventContextPhantom(target_decl, target_decl.module, context, location, lj.label);
                if (!context_valid) has_errors = true;

                return !has_errors;
            },
            .conditional_block => |cb| {
                for (cb.nodes) |*s| {
                    const inner_valid = try self.validateStep(s, context, event_map, current_module, location);
                    if (!inner_valid) has_errors = true;
                }
                return !has_errors;
            },
            .foreach => |fe| {
                std.debug.print("[PHANTOM-FLOW] Validating foreach with {} branches\n", .{fe.branches.len});
                for (fe.branches) |*branch| {
                    const branch_valid = try self.validateNamedBranchRecursive(branch, context, event_map, current_module, location);
                    if (!branch_valid) has_errors = true;
                }
                return !has_errors;
            },
            .conditional => |cond| {
                std.debug.print("[PHANTOM-FLOW] Validating conditional with {} branches\n", .{cond.branches.len});
                for (cond.branches) |*branch| {
                    const branch_valid = try self.validateNamedBranchRecursive(branch, context, event_map, current_module, location);
                    if (!branch_valid) has_errors = true;
                }
                return !has_errors;
            },
            .switch_result => |sr| {
                std.debug.print("[PHANTOM-FLOW] Validating switch_result with {} branches\n", .{sr.branches.len});
                for (sr.branches) |*branch| {
                    const branch_valid = try self.validateNamedBranchRecursive(branch, context, event_map, current_module, location);
                    if (!branch_valid) has_errors = true;
                }
                return !has_errors;
            },
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

    /// Validate a NamedBranch (from foreach or conditional)
    /// Handles @scope annotations to track outer-scope obligations
    /// This function does NOT call validateStep to avoid mutual recursion
    fn validateNamedBranchRecursive(
        self: *PhantomSemanticChecker,
        branch: *const ast.NamedBranch,
        parent_context: *BindingContext,
        event_map: *std.StringHashMap(EventInfo),
        current_module: ?[]const u8,
        location: errors.SourceLocation
    ) !bool {
        var has_errors = false;

        // Check if this branch has @scope annotation
        const has_scope = blk: {
            for (branch.annotations) |ann| {
                if (std.mem.eql(u8, ann, "@scope")) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        std.debug.print("[PHANTOM-FLOW] Validating branch '{s}' (has_scope={}, {} continuations)\n", .{branch.name, has_scope, branch.body.len});

        // Create context for this branch
        // If @scope, use inheritWithScope to mark existing obligations as outer-scope
        var branch_context = if (has_scope)
            try BindingContext.inheritWithScope(parent_context, self.allocator)
        else
            try BindingContext.inherit(parent_context, self.allocator);
        defer branch_context.deinit();

        // Validate each continuation in the branch body
        for (branch.body) |*cont| {
            // NOTE: We do NOT check outer-scope obligations at terminators inside @scope.
            // Outer obligations are "suspended" - they'll be checked when the OUTER scope
            // terminates (e.g., in the `done` branch after a for-loop).
            // The auto_dispose_inserter handles the actual disposal logic, respecting @scope.

            // Validate the step if present - handle recursively for nested structures
            if (cont.node) |step| {
                switch (step) {
                    .foreach => |fe| {
                        for (fe.branches) |*inner_branch| {
                            const valid = try self.validateNamedBranchRecursive(inner_branch, &branch_context, event_map, current_module, location);
                            if (!valid) has_errors = true;
                        }
                    },
                    .conditional => |cond| {
                        for (cond.branches) |*inner_branch| {
                            const valid = try self.validateNamedBranchRecursive(inner_branch, &branch_context, event_map, current_module, location);
                            if (!valid) has_errors = true;
                        }
                    },
                    .switch_result => |sr| {
                        for (sr.branches) |*inner_branch| {
                            const valid = try self.validateNamedBranchRecursive(inner_branch, &branch_context, event_map, current_module, location);
                            if (!valid) has_errors = true;
                        }
                    },
                    .invocation => |inv| {
                        const valid = try self.validateSingleInvocation(&inv, &branch_context, event_map, current_module, location);
                        if (!valid) has_errors = true;
                    },
                    else => {
                        // Other step types (terminal, inline_code, etc.) don't need recursive validation
                    },
                }
            }

            // Recursively validate nested continuations
            for (cont.continuations) |*nested| {
                // NOTE: Same as above - we don't check outer-scope obligations at terminators.
                // They're suspended inside @scope and will be checked by the outer scope.

                // Validate nested step - handle recursively for nested structures
                if (nested.node) |step| {
                    switch (step) {
                        .foreach => |fe| {
                            for (fe.branches) |*inner_branch| {
                                const valid = try self.validateNamedBranchRecursive(inner_branch, &branch_context, event_map, current_module, location);
                                if (!valid) has_errors = true;
                            }
                        },
                        .conditional => |cond| {
                            for (cond.branches) |*inner_branch| {
                                const valid = try self.validateNamedBranchRecursive(inner_branch, &branch_context, event_map, current_module, location);
                                if (!valid) has_errors = true;
                            }
                        },
                        .switch_result => |sr| {
                            for (sr.branches) |*inner_branch| {
                                const valid = try self.validateNamedBranchRecursive(inner_branch, &branch_context, event_map, current_module, location);
                                if (!valid) has_errors = true;
                            }
                        },
                        .invocation => |inv| {
                            const valid = try self.validateSingleInvocation(&inv, &branch_context, event_map, current_module, location);
                            if (!valid) has_errors = true;
                        },
                        else => {},
                    }
                }
            }
        }

        return !has_errors;
    }

    fn validateSingleInvocation(
        self: *PhantomSemanticChecker,
        inv: *const ast.Invocation,
        context: *BindingContext,
        event_map: *std.StringHashMap(EventInfo),
        current_module: ?[]const u8,
        location: errors.SourceLocation
    ) !bool {
        var has_errors = false;
        // Get the event name from path segments
        const event_name = try self.pathToString(inv.path);
        defer self.allocator.free(event_name);

        // Determine the module - use module_qualifier if present, otherwise current_module
        const module_name = inv.path.module_qualifier orelse current_module;

        // Build fully-qualified event name (module:event)
        const qualified_name = if (module_name) |mod|
            try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{mod, event_name})
        else
            try self.allocator.dupe(u8, event_name);
        defer self.allocator.free(qualified_name);

        std.debug.print("[PHANTOM-FLOW]   Single invocation: '{s}' → qualified: '{s}'\n", .{event_name, qualified_name});

        const event_info = event_map.get(qualified_name) orelse {
            std.debug.print("[PHANTOM-FLOW]   Event '{s}' not found in map, skipping step\n", .{qualified_name});
            return true;
        };

        // Validate each argument against event signature
        for (inv.args) |arg| {
            const arg_valid = try self.validateArgument(arg, event_info.decl, module_name, context, location);
            if (!arg_valid) {
                has_errors = true;
            }
        }

        // Validate event-level phantom preconditions
        const context_valid = try self.validateEventContextPhantom(event_info.decl, module_name, context, location, event_name);
        if (!context_valid) has_errors = true;

        return !has_errors;
    }

    fn validateEventContextPhantom(
        self: *PhantomSemanticChecker,
        event_decl: *const ast.EventDecl,
        event_module: ?[]const u8,
        context: *BindingContext,
        location: errors.SourceLocation,
        event_name: []const u8
    ) !bool {
        var has_errors = false;
        std.debug.print("[PHANTOM-FLOW]   Checking event context phantoms for '{s}' ({} annotations)\n", .{ event_name, event_decl.annotations.len });
        for (event_decl.annotations, 0..) |ann, i| {
            std.debug.print("[PHANTOM-FLOW]     Annotation[{}]: '{s}' (isPhantom={})\n", .{ i, ann, isPhantomAnnotation(ann) });
            if (isPhantomAnnotation(ann)) {
                // Precondition found!
                const provided_state = context.get("") orelse "";
                std.debug.print("[PHANTOM-FLOW]     Precondition found: '{s}', current context: '{s}'\n", .{ ann, provided_state });

                const canonical_expected = try self.canonicalizePhantomState(ann, event_module orelse event_decl.module);
                defer self.allocator.free(canonical_expected);

                const provided_phantom = context.get("") orelse {
                    // Error: context-level phantom required but not provided
                    std.debug.print("[PHANTOM-FLOW] ❌ CONTEXT MISMATCH! Expected {s} but no context state defined\n", .{canonical_expected});
                    try self.reporter.addError(
                        .KORU030,
                        location.line,
                        location.column,
                        "Phantom state mismatch for event '{s}': expected context state '{s}' but no context state is defined",
                        .{event_name, canonical_expected}
                    );
                    has_errors = true;
                    continue;
                };

                const canonical_provided = try self.canonicalizePhantomState(provided_phantom, event_module orelse event_decl.module);
                defer self.allocator.free(canonical_provided);

                std.debug.print("[PHANTOM-FLOW] Comparing context phantoms: expected={s}, provided={s}\n", .{canonical_expected, canonical_provided});

                const compatible = try phantom_parser.areCompatible(self.allocator, canonical_expected, canonical_provided);
                if (!compatible) {
                    std.debug.print("[PHANTOM-FLOW] ❌ CONTEXT MISMATCH!\n", .{});
                    try self.reporter.addError(
                        .KORU030,
                        location.line,
                        location.column,
                        "Phantom state mismatch for event '{s}': expected context state '{s}' but found '{s}'",
                        .{event_name, canonical_expected, canonical_provided}
                    );
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

    fn validateArgument(
        self: *PhantomSemanticChecker,
        arg: ast.Arg,
        event_decl: *const ast.EventDecl,
        event_module: ?[]const u8,  // Qualified module name from event lookup
        context: *BindingContext,
        location: errors.SourceLocation
    ) !bool {
        // Find the field in event input
        var expected_phantom: ?[]const u8 = null;
        for (event_decl.input.fields) |field| {
            if (std.mem.eql(u8, field.name, arg.name)) {
                expected_phantom = field.phantom;
                break;
            }
        }

        if (expected_phantom == null) {
            // No phantom state expected for this field
            return true;
        }

        // Debug: print what we're looking for
        std.debug.print("[PHANTOM-FLOW] Checking arg '{s}' with value '{s}'\n", .{arg.name, arg.value});
        std.debug.print("[PHANTOM-FLOW]   Expected phantom: '{s}'\n", .{expected_phantom.?});

        // Check if the binding has been disposed
        if (context.isDisposed(arg.value)) {
            std.debug.print("[CLEANUP] ❌ USE AFTER DISPOSAL DETECTED!\n", .{});
            try self.reporter.addError(
                .KORU030,
                location.line,
                location.column,
                "Use-after-disposal: binding '{s}' was already disposed and cannot be used",
                .{arg.value}
            );
            return false;
        }

        // Get the provided phantom state from context
        const provided_phantom = context.get(arg.value) orelse {
            std.debug.print("[PHANTOM-FLOW]   No binding found for '{s}' in context\n", .{arg.value});
            // Value is not a tracked binding - might be a literal
            return true;
        };

        std.debug.print("[PHANTOM-FLOW]   Provided phantom: '{s}'\n", .{provided_phantom});

        // Canonicalize both phantom states for proper comparison
        // Use event_module (qualified module name from lookup) for proper canonicalization
        const module_for_canon = event_module orelse event_decl.module;
        const canonical_expected = try self.canonicalizePhantomState(
            expected_phantom.?,
            module_for_canon
        );
        defer self.allocator.free(canonical_expected);

        // Provided phantom is already qualified, but might not be canonical - canonicalize it too
        // We need to parse it to get its module, then resolve through module_map
        const canonical_provided = try self.canonicalizePhantomState(
            provided_phantom,
            module_for_canon  // Use event's qualified module as fallback if provided has no module
        );
        defer self.allocator.free(canonical_provided);

        std.debug.print("[PHANTOM-FLOW]   Canonical expected: '{s}'\n", .{canonical_expected});
        std.debug.print("[PHANTOM-FLOW]   Canonical provided: '{s}'\n", .{canonical_provided});

        // Check compatibility using canonicalized phantom states
        const compatible = try phantom_parser.areCompatible(
            self.allocator,
            canonical_expected,
            canonical_provided
        );

        if (!compatible) {
            std.debug.print("[PHANTOM-FLOW] ❌ MISMATCH DETECTED!\n", .{});
            try self.reporter.addError(
                .KORU030, // Shape mismatch
                location.line,
                location.column,
                "Phantom state mismatch: expected '{s}' but got '{s}' for argument '{s}'",
                .{canonical_expected, canonical_provided, arg.name}
            );
            // Return false to indicate error, but don't stop checking
            return false;
        }

        std.debug.print("[PHANTOM-FLOW]   ✓ Compatible\n", .{});

        // Check if this event consumes the obligation (marked with ! prefix)
        var expected_phantom_parsed = try phantom_parser.PhantomState.parse(self.allocator, expected_phantom.?);
        defer expected_phantom_parsed.deinit(self.allocator);

        switch (expected_phantom_parsed) {
            .concrete => |concrete| {
                if (concrete.consumes_obligation) {
                    std.debug.print("[CLEANUP] Event parameter has [!{s}] - consumes obligation\n", .{concrete.name});
                    // This event disposes the resource - clear the cleanup obligation
                    context.clearCleanupObligation(arg.value);
                    // Mark the binding as disposed (poisoned - cannot be used anymore)
                    try context.markDisposed(arg.value);
                }
            },
            .variable => {},
            .state_union => |u| {
                if (u.consumes_obligation) {
                    std.debug.print("[CLEANUP] Event parameter has union with [!] - consumes obligation\n", .{});
                    // Union with consume marker - clear the cleanup obligation
                    context.clearCleanupObligation(arg.value);
                    // Mark the binding as disposed
                    try context.markDisposed(arg.value);
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
                return try std.fmt.allocPrint(
                    self.allocator,
                    "{s}:{s}",
                    .{module_name.?, concrete.name}
                );
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
        if (path.segments.len == 0) return try self.allocator.dupe(u8, "");
        if (path.segments.len == 1) return try self.allocator.dupe(u8, path.segments[0]);

        // Calculate total length
        var total_len: usize = path.segments[0].len;
        for (path.segments[1..]) |seg| {
            total_len += 1 + seg.len; // dot + segment
        }

        // Build string
        var result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        @memcpy(result[pos..pos + path.segments[0].len], path.segments[0]);
        pos += path.segments[0].len;

        for (path.segments[1..]) |seg| {
            result[pos] = '.';
            pos += 1;
            @memcpy(result[pos..pos + seg.len], seg);
            pos += seg.len;
        }

        return result;
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
    try ctx.markDisposed("file");

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
    try parent.markDisposed("file");

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
