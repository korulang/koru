const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const type_inference = @import("type_inference");
const branch_checker = @import("branch_checker");

/// The shape checker validates that:
/// 1. Event continuations cover all branches
/// 2. Shapes match at each pipeline step
/// 3. Labels are applied with matching shapes
/// 4. Proc returns match their event declaration

pub const ShapeChecker = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    
    // Symbol table for tracking events, procs, labels, subflows
    events: std.StringHashMap(EventInfo),
    procs: std.StringHashMap(ProcInfo),
    labels: std.StringHashMap(LabelInfo),
    subflow_impls: std.StringHashMap(SubflowImplInfo),
    
    // Type inference engine
    type_engine: type_inference.TypeInference,
    
    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !ShapeChecker {
        return ShapeChecker{
            .allocator = allocator,
            .reporter = reporter,
            .events = std.StringHashMap(EventInfo).init(allocator),
            .procs = std.StringHashMap(ProcInfo).init(allocator),
            .labels = std.StringHashMap(LabelInfo).init(allocator),
            .subflow_impls = std.StringHashMap(SubflowImplInfo).init(allocator),
            .type_engine = try type_inference.TypeInference.init(allocator, reporter),
        };
    }
    
    pub fn deinit(self: *ShapeChecker) void {
        // TODO/FIXME: Temporarily disabled EventDecl cleanup to prevent crashes
        // ISSUE: Mixed allocator ownership - some events are allocated by emitter's allocator
        //        but we're trying to free them with shape_checker's allocator
        // IMPACT: ~46 small memory leaks per compilation (process ends anyway)
        // FIX: Implement proper ownership model - either:
        //      1. Always use shape_checker's allocator for events stored here
        //      2. Track which allocator owns each event
        //      3. Use arena allocator that doesn't need individual frees
        // See TECHNICAL_DEBT.md for full details
        
        var events_iter = self.events.iterator();
        while (events_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // TEMPORARILY COMMENTED OUT - causes invalid free crashes
            // const event_decl = entry.value_ptr.decl;
            // for (event_decl.path.segments) |segment| {
            //     self.allocator.free(segment);
            // }
            // self.allocator.free(event_decl.path.segments);
            // self.allocator.free(event_decl.branches);
            // self.allocator.destroy(event_decl);
        }
        self.events.deinit();
        
        var procs_iter = self.procs.iterator();
        while (procs_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.procs.deinit();
        
        var labels_iter = self.labels.iterator();
        while (labels_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.jump_sites.deinit(self.allocator);
        }
        self.labels.deinit();
        self.subflow_impls.deinit();
        self.type_engine.deinit();
    }
    
    /// Check if two shapes are structurally equal (ignoring phantom states)
    /// Phantom state compatibility is checked separately by phantom_semantic_checker
    pub fn shapesEqual(self: *ShapeChecker, a: ast.Shape, b: ast.Shape) bool {
        _ = self;
        if (a.fields.len != b.fields.len) return false;

        // Check that all fields in 'a' exist in 'b' with same base type
        // NOTE: Phantom states are IGNORED - they're checked by phantom_semantic_checker
        for (a.fields) |field_a| {
            var found = false;
            for (b.fields) |field_b| {
                if (std.mem.eql(u8, field_a.name, field_b.name)) {
                    // Types must match exactly (base type only, phantom states ignored)
                    if (!std.mem.eql(u8, field_a.type, field_b.type)) {
                        return false; // Same name, different type
                    }

                    found = true;
                    break;
                }
            }
            if (!found) return false; // Field not found in b
        }

        return true; // All fields match
    }
    /// Check if a set of branches covers all required branches
    pub fn checkBranchCoverage(
        self: *ShapeChecker,
        event_branches: []const ast.Branch,
        continuations: []const ast.Continuation,
    ) !bool {
        // Check for DUPLICATE branch handlers at the same level
        // This catches incorrect indentation where someone writes:
        //   | done x |> event1()
        //   | done y |> event2()   <- WRONG: should be indented if handling event1's done
        for (continuations, 0..) |cont, i| {
            for (continuations[i + 1 ..]) |other| {
                if (std.mem.eql(u8, cont.branch, other.branch)) {
                    // Duplicate branch handler!
                    try self.reporter.addError(
                        .SHAPE002,
                        0,
                        0,
                        "Duplicate handler for branch '{s}'. If the second handler is for a chained event's result, it must be indented further.",
                        .{cont.branch},
                    );
                    return false;
                }
            }
        }

        // Check that every REQUIRED event branch has a matching continuation
        // Optional branches (marked with ?) don't need to be handled
        for (event_branches) |branch| {
            // Skip optional branches - they don't need to be handled
            if (branch.is_optional) continue;

            var found = false;
            for (continuations) |cont| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Missing required branch coverage
                return false;
            }
        }
        
        // Check for extra branches (continuations for non-existent branches)
        for (continuations) |cont| {
            var found = false;
            for (event_branches) |branch| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                // Unknown branch
                return false;
            }
        }
        
        return true;
    }
    
    /// Check an entire source file for shape consistency
    pub fn checkSourceFile(self: *ShapeChecker, source_file: *const ast.Program) !void {
        // First pass: collect all events, procs, labels, subflows
        for (source_file.items) |*item| {  // Changed to pointer iteration!
            switch (item.*) {
                .event_decl => |*event| {
                    // Main module events need module qualification too!
                    // Build full path: "main_module_name:event.path"
                    var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                    errdefer buf.deinit(self.allocator);

                    try buf.appendSlice(self.allocator, source_file.main_module_name);
                    try buf.append(self.allocator, ':');
                    for (event.path.segments, 0..) |segment, i| {
                        if (i > 0) try buf.append(self.allocator, '.');
                        try buf.appendSlice(self.allocator, segment);
                    }
                    const path = try buf.toOwnedSlice(self.allocator);

                    try self.events.put(path, EventInfo{
                        .decl = event,
                        .line = 0, // TODO: track line numbers
                    });

                    // Also register with type inference engine
                    try self.type_engine.registerEvent(path, event.branches);
                },
                .proc_decl => |*proc| {
                    // Main module procs need module qualification too!
                    var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                    errdefer buf.deinit(self.allocator);

                    try buf.appendSlice(self.allocator, source_file.main_module_name);
                    try buf.append(self.allocator, ':');
                    for (proc.path.segments, 0..) |segment, i| {
                        if (i > 0) try buf.append(self.allocator, '.');
                        try buf.appendSlice(self.allocator, segment);
                    }
                    const path = try buf.toOwnedSlice(self.allocator);

                    try self.procs.put(path, ProcInfo{
                        .decl = proc,
                        .line = 0,
                    });
                },
                .label_decl => |*label| {
                    // Determine if pre or post invocation based on continuations
                    const is_pre = label.continuations.len > 0;
                    
                    try self.labels.put(label.name, LabelInfo{
                        .decl = label,
                        .expected_shape = null, // Will determine from usage
                        .line = 0,
                        .is_pre_invocation = is_pre,
                        .jump_sites = try std.ArrayList(LabelInfo.JumpSite).initCapacity(self.allocator, 0),
                    });
                },
                .subflow_impl => |*subflow| {
                    // Subflow implementations are validated against their event
                    const event_path = try self.pathToString(subflow.event_path);
                    defer self.allocator.free(event_path);
                    try self.subflow_impls.put(event_path, SubflowImplInfo{
                        .impl = subflow,
                        .line = 0,
                    });
                },
                .module_decl => |*module| {
                    // Process items from imported modules
                    // Events from modules must be registered with module qualifier (e.g., "std.io:println")
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .event_decl => |*event| {
                                // Build full path: "module.logical_name:event.path"
                                var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                                errdefer buf.deinit(self.allocator);

                                try buf.appendSlice(self.allocator, module.logical_name);
                                try buf.append(self.allocator, ':');
                                for (event.path.segments, 0..) |segment, i| {
                                    if (i > 0) try buf.append(self.allocator, '.');
                                    try buf.appendSlice(self.allocator, segment);
                                }
                                const path = try buf.toOwnedSlice(self.allocator);

                                try self.events.put(path, EventInfo{
                                    .decl = event,
                                    .line = 0,
                                });
                                try self.type_engine.registerEvent(path, event.branches);
                            },
                            .proc_decl => |*proc| {
                                // Build full path with module qualifier (same as events)
                                var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                                errdefer buf.deinit(self.allocator);

                                try buf.appendSlice(self.allocator, module.logical_name);
                                try buf.append(self.allocator, ':');
                                for (proc.path.segments, 0..) |segment, i| {
                                    if (i > 0) try buf.append(self.allocator, '.');
                                    try buf.appendSlice(self.allocator, segment);
                                }
                                const path = try buf.toOwnedSlice(self.allocator);

                                try self.procs.put(path, ProcInfo{
                                    .decl = proc,
                                    .line = 0,
                                });
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        
        // Second pass: validate flows, taps, proc implementations, and subflows
        for (source_file.items) |*item| {  // Changed to pointer iteration!
            switch (item.*) {
                .flow => |*flow| {
                    try self.validateFlow(flow, flow.location, source_file);
                },
                .event_tap => |*tap| {
                    try self.validateEventTap(tap, tap.location);
                },
                .proc_decl => |*proc| {
                    try self.validateProc(proc, null);
                },
                .subflow_impl => |*subflow| {
                    // Subflow body can be either a flow or an immediate value
                    switch (subflow.body) {
                        .flow => |*flow| try self.validateFlow(flow, flow.location, source_file),
                        .immediate => {
                            // Immediate values (like branch constructors) are already validated
                            // during parsing and type inference. No additional validation needed.
                        },
                    }
                },
                .module_decl => |*module| {
                    // Validate flows and taps in imported modules
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .flow => |*flow| {
                                try self.validateFlow(flow, flow.location, source_file);
                            },
                            .event_tap => |*tap| {
                                try self.validateEventTap(tap, tap.location);
                            },
                            .proc_decl => |*proc| {
                                // Pass module qualifier so proc can be looked up correctly
                                try self.validateProc(proc, module.logical_name);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // After all validation, check if any errors were reported
        if (self.reporter.hasErrors()) {
            return error.ValidationFailed;
        }
    }
    
    fn pathToString(self: *ShapeChecker, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        errdefer buf.deinit(self.allocator);

        // Include module qualifier if present (e.g., "std.io:println")
        // This is critical for validating module-qualified event references
        if (path.module_qualifier) |mq| {
            try buf.appendSlice(self.allocator, mq);
            try buf.append(self.allocator, ':');
        }

        for (path.segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Find a glob pattern event that matches the given event name
    /// Used when exact event lookup fails to find matching templates like log.*
    fn findGlobMatch(self: *ShapeChecker, event_name: []const u8) ?EventInfo {
        var events_iter = self.events.iterator();
        while (events_iter.next()) |entry| {
            const pattern = entry.key_ptr.*;
            // Only check patterns that contain wildcards
            if (std.mem.indexOfScalar(u8, pattern, '*') == null) continue;

            // Extract the event path part (after : if present)
            const pattern_event = if (std.mem.indexOfScalar(u8, pattern, ':')) |colon_idx|
                pattern[colon_idx + 1 ..]
            else
                pattern;

            const event_path = if (std.mem.indexOfScalar(u8, event_name, ':')) |colon_idx|
                event_name[colon_idx + 1 ..]
            else
                event_name;

            if (matchGlob(pattern_event, event_path)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    /// Simple glob matching for event patterns
    fn matchGlob(pattern: []const u8, value: []const u8) bool {
        // Full wildcard matches anything
        if (std.mem.eql(u8, pattern, "*")) return true;

        // Prefix wildcard: *.suffix
        if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, value, suffix);
        }

        // Suffix wildcard with dot: prefix.*
        if (pattern.len > 2 and pattern[pattern.len - 2] == '.' and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 2];
            return std.mem.startsWith(u8, value, prefix) and
                value.len > prefix.len and value[prefix.len] == '.';
        }

        // Bare suffix wildcard: prefix*
        if (pattern.len > 1 and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, value, prefix);
        }

        // Bare prefix wildcard: *suffix
        if (pattern.len > 1 and pattern[0] == '*') {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, value, suffix);
        }

        // Middle wildcard: prefix.*.suffix
        if (std.mem.indexOfScalar(u8, pattern, '*')) |star_idx| {
            const prefix = pattern[0..star_idx];
            const suffix = pattern[star_idx + 1 ..];
            return std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, suffix) and
                value.len >= prefix.len + suffix.len;
        }

        return false;
    }

    /// Check if a path is a namespace wildcard (e.g., "http.*")
    fn isNamespaceWildcard(path: ast.DottedPath) bool {
        if (path.segments.len == 0) return false;
        const last_segment = path.segments[path.segments.len - 1];
        return std.mem.eql(u8, last_segment, "*");
    }

    /// Get the namespace prefix from a wildcard path (e.g., "http.*" -> "http")
    fn getNamespacePrefix(self: *ShapeChecker, path: ast.DottedPath) ![]const u8 {
        if (path.segments.len == 0) return error.InvalidPath;

        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        errdefer buf.deinit(self.allocator);

        // All segments except the last one (which should be "*")
        for (path.segments[0..path.segments.len - 1], 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }

        return try buf.toOwnedSlice(self.allocator);
    }
    
    fn validateFlow(self: *ShapeChecker, flow: *const ast.Flow, location: errors.SourceLocation, source_file: *const ast.Program) !void {
        // Skip flows that have been transformed by [transform] events.
        // Transformed flows have valid structure by construction - the transform
        // replaced the comptime event structure with a runtime node structure.
        // The new structure can't match the original event's shape because it's
        // a completely different representation (e.g., capture -> CaptureNode).
        for (flow.invocation.annotations) |ann| {
            if (std.mem.startsWith(u8, ann, "@pass_ran")) {
                return;  // Skip validation - transform output is valid by construction
            }
        }

        // Clear labels from previous flows - labels are flow-scoped
        var label_it = self.labels.iterator();
        while (label_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.jump_sites.deinit(self.allocator);
        }
        self.labels.clearRetainingCapacity();

        // If this flow defines a post-invocation label, validate it
        if (flow.post_label) |label_name| {
            // Check if label was already declared
            if (self.labels.get(label_name)) |_| {
                std.debug.print("ERROR: Duplicate label '{s}' defined\n", .{label_name});
                return error.DuplicateLabel;
            }
            // Register post-invocation label
            try self.labels.put(try self.allocator.dupe(u8, label_name), LabelInfo{
                .decl = null, // Flow-based label, not a LabelDecl
                .expected_shape = null, // Will be determined from flow output
                .line = 0,
                .is_pre_invocation = false,
                .jump_sites = try std.ArrayList(LabelInfo.JumpSite).initCapacity(self.allocator, 0),
            });
        }
        
        // If this flow defines a pre-invocation label, validate it
        if (flow.pre_label) |label_name| {
            // Check if label was already declared
            if (self.labels.get(label_name)) |_| {
                std.debug.print("ERROR: Duplicate label '{s}' defined\n", .{label_name});
                return error.DuplicateLabel;
            }
            // Register pre-invocation label
            try self.labels.put(try self.allocator.dupe(u8, label_name), LabelInfo{
                .decl = null, // Flow-based label, not a LabelDecl
                .expected_shape = null, // Will be determined from flow input
                .line = 0,
                .is_pre_invocation = true,
                .jump_sites = try std.ArrayList(LabelInfo.JumpSite).initCapacity(self.allocator, 0),
            });
        }
        
        // Get the event being invoked
        const event_name = try self.pathToString(flow.invocation.path);
        defer self.allocator.free(event_name);  // Free temp string after lookup

        // Try to get the event. If it doesn't exist with unqualified name,
        // and the path has no module qualifier, try with main module qualification
        var event_info = self.events.get(event_name);

        if (event_info == null and flow.invocation.path.module_qualifier == null) {
            // No explicit module qualifier - try with main module name
            var qualified_name_buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer qualified_name_buf.deinit(self.allocator);

            try qualified_name_buf.appendSlice(self.allocator, source_file.main_module_name);
            try qualified_name_buf.append(self.allocator, ':');
            try qualified_name_buf.appendSlice(self.allocator, event_name);

            const qualified_name = try qualified_name_buf.toOwnedSlice(self.allocator);
            defer self.allocator.free(qualified_name);

            event_info = self.events.get(qualified_name);
        }

        // If exact match failed, try glob pattern matching
        if (event_info == null) {
            event_info = self.findGlobMatch(event_name);
        }

        const final_event_info = event_info orelse {
            std.debug.print("ERROR: Unknown event '{s}'\n", .{event_name});
            // Check if it's a subflow implementation
            if (self.subflow_impls.get(event_name)) |subflow_impl| {
                // Subflow implementation exists - it implements this event
                // Get the event declaration for branch validation
                const event = self.events.get(event_name) orelse {
                    _ = subflow_impl;
                    return error.SubflowWithoutEvent;
                };
                // Check branch coverage (with terminal marker awareness)
                const covered = try self.checkBranchCoverageWithTerminals(
                    event.decl.branches,
                    flow.continuations,
                    location,
                );

                if (!covered) {
                    return error.IncompleteBranchCoverage;
                }
                return;
            }
            // Unknown event
            return error.UnknownEvent;
        };
        
        // Check branch coverage (with terminal marker awareness)
        const covered = try self.checkBranchCoverageWithTerminals(
            final_event_info.decl.branches,
            flow.continuations,
            location,
        );

        if (!covered) {
            return error.IncompleteBranchCoverage;
        }
    }
    
    fn validateEventTap(self: *ShapeChecker, tap: *const ast.EventTap, location: errors.SourceLocation) !void {
        // Determine which events this tap observes
        var matched_events = try std.ArrayList(EventInfo).initCapacity(self.allocator, 0);
        defer matched_events.deinit(self.allocator);

        // If source is specified (not wildcard), validate it exists
        if (tap.source) |source| {
            // Check if this is a namespace wildcard (e.g., "http.*")
            if (isNamespaceWildcard(source)) {
                const prefix = try self.getNamespacePrefix(source);
                defer self.allocator.free(prefix);

                // Validate that at least one event matches this namespace prefix
                var found_match = false;
                var event_it = self.events.iterator();
                while (event_it.next()) |entry| {
                    const event_name = entry.key_ptr.*;
                    if (std.mem.startsWith(u8, event_name, prefix) and
                        (event_name.len == prefix.len or event_name[prefix.len] == '.')) {
                        found_match = true;
                        break;
                    }
                }

                if (!found_match) {
                    const source_path = try self.pathToString(source);
                    defer self.allocator.free(source_path);
                    std.debug.print("WARNING: Namespace wildcard '{s}' matches no events\n", .{source_path});
                    // Don't fail - it might be intentional (observing optional modules)
                }
            } else {
                // Regular event path - must exist (unless it's a meta-event)
                const source_path = try self.pathToString(source);
                defer self.allocator.free(source_path);

                // Check if this is a meta-event (koru:start, koru:end)
                // Meta-events have module_qualifier="koru" and segments=["start"|"end"]
                const is_meta_event = (source.module_qualifier != null and
                                      std.mem.eql(u8, source.module_qualifier.?, "koru") and
                                      source.segments.len == 1 and
                                      (std.mem.eql(u8, source.segments[0], "start") or
                                       std.mem.eql(u8, source.segments[0], "end")));

                if (!is_meta_event and self.events.get(source_path) == null) {
                    std.debug.print("ERROR: Unknown source event '{s}' in tap\n", .{source_path});
                    try self.reporter.addError(.KORU040, location.line, location.column, "unknown source event '{s}' in tap", .{source_path});
                    // Continue checking for more errors
                }
            }
        }

        // If destination is specified (not wildcard), validate it exists
        if (tap.destination) |dest| {
            // Check if this is a namespace wildcard (e.g., "http.*")
            if (isNamespaceWildcard(dest)) {
                const prefix = try self.getNamespacePrefix(dest);
                defer self.allocator.free(prefix);

                // Validate that at least one event matches this namespace prefix
                var found_match = false;
                var event_it = self.events.iterator();
                while (event_it.next()) |entry| {
                    const event_name = entry.key_ptr.*;
                    if (std.mem.startsWith(u8, event_name, prefix) and
                        (event_name.len == prefix.len or event_name[prefix.len] == '.')) {
                        found_match = true;
                        break;
                    }
                }

                if (!found_match) {
                    const dest_path = try self.pathToString(dest);
                    defer self.allocator.free(dest_path);
                    std.debug.print("WARNING: Namespace wildcard '{s}' matches no events\n", .{dest_path});
                    // Don't fail - it might be intentional
                }
            } else {
                // Regular event path - must exist
                const dest_path = try self.pathToString(dest);
                defer self.allocator.free(dest_path);

                if (self.events.get(dest_path) == null) {
                    std.debug.print("ERROR: Unknown destination event '{s}' in tap\n", .{dest_path});
                    try self.reporter.addError(.KORU040, location.line, location.column, "unknown destination event '{s}' in tap", .{dest_path});
                    // Continue checking for more errors
                }
            }
        }
        
        // Find the event we're tapping (for shape validation)
        // For output taps: use source event
        // For input taps: use destination event
        const event_to_validate = if (tap.is_input_tap) 
            tap.destination 
        else 
            tap.source;
            
        if (event_to_validate) |event_path| {
            const path_str = try self.pathToString(event_path);
            defer self.allocator.free(path_str);

            if (self.events.get(path_str)) |event_info| {
                // Tap continuations are like flow continuations - they handle branches
                // from INVOKED events in the pipeline, NOT from the source event being tapped.
                // The pipeline steps themselves will be validated by checkBranchCoverageWithTerminals
                // when the tap is processed. No need to validate branch names here.
                _ = event_info; // Keep for future pipeline validation if needed
            }
        } else if (!tap.is_input_tap) {
            // Wildcard output tap - we can't validate branches without knowing the event
            // This is OK - will be checked at compile time when matching actual events
            // For now, just ensure continuations are well-formed
            for (tap.continuations) |cont| {
                if (cont.branch.len == 0 and !std.mem.eql(u8, cont.branch, "transition")) {
                    std.debug.print("ERROR: Invalid branch name in wildcard tap\n", .{});
                    try self.reporter.addError(.KORU021, location.line, location.column, "invalid branch name in wildcard tap", .{});
                    // Continue checking for more errors
                }
            }
        }
    }
    
    fn validateTapContinuations(
        self: *ShapeChecker,
        event_decl: *const ast.EventDecl,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
    ) !void {
        // Check that each continuation branch exists in the event
        for (continuations) |cont| {
            var found = false;
            for (event_decl.branches) |branch| {
                if (std.mem.eql(u8, branch.name, cont.branch)) {
                    found = true;
                    // TODO: Validate binding type matches branch payload
                    break;
                }
            }

            // Special case: Metatypes (capitalized to signal compiler magic)
            // Transition, Profile, and Audit are available on ALL transitions
            if (!found and std.mem.eql(u8, cont.branch, "Transition")) {
                // Transition meta-type: full transition data with enum-based fields
                found = true;
            }

            if (!found and std.mem.eql(u8, cont.branch, "Profile")) {
                // Profile meta-type: for performance profiling with timestamps
                found = true;
            }

            if (!found and std.mem.eql(u8, cont.branch, "Audit")) {
                // Audit meta-type: for audit logging
                found = true;
            }

            if (!found) {
                std.debug.print("ERROR: Event '{s}.{s}' has no branch '{s}'\n",
                    .{event_decl.path.segments[0], event_decl.path.segments[event_decl.path.segments.len - 1], cont.branch});
                try self.reporter.addError(.KORU021, location.line, location.column, "event '{s}.{s}' has no branch '{s}'",
                    .{event_decl.path.segments[0], event_decl.path.segments[event_decl.path.segments.len - 1], cont.branch});
                // Continue checking for more errors
            }
        }

        // Note: We do NOT check exhaustiveness for taps
        // Taps can observe only the branches they care about
    }
    
    fn checkBranchCoverageWithTerminals(
        self: *ShapeChecker,
        event_branches: []const ast.Branch,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
    ) !bool {
        // Track if we found any errors (but continue checking to find all of them)
        var has_errors = false;

        // Use pure BranchChecker for branch name validation
        // Convert AST types to BranchChecker types
        var declared = try std.ArrayList(branch_checker.BranchChecker.DeclaredBranch).initCapacity(
            self.allocator,
            event_branches.len,
        );
        defer declared.deinit(self.allocator);

        for (event_branches) |branch| {
            try declared.append(self.allocator, .{
                .name = branch.name,
                .is_optional = branch.is_optional,
            });
        }

        // Convert continuations, handling special cases:
        // - Skip empty branch names (void event chains)
        // - Metatypes (Transition, Profile, Audit) are always valid
        // - Transition also acts as catchall
        var handled = try std.ArrayList(branch_checker.BranchChecker.HandledBranch).initCapacity(
            self.allocator,
            continuations.len,
        );
        defer handled.deinit(self.allocator);

        for (continuations) |cont| {
            // Skip empty branch names - void event chains
            if (cont.branch.len == 0) continue;

            // Check for metatypes - these are always valid, skip them
            const is_metatype = std.mem.eql(u8, cont.branch, "Transition") or
                std.mem.eql(u8, cont.branch, "Profile") or
                std.mem.eql(u8, cont.branch, "Audit");

            // Transition acts as a catchall
            const is_catchall = cont.is_catchall or std.mem.eql(u8, cont.branch, "Transition");

            if (!is_metatype) {
                try handled.append(self.allocator, .{
                    .name = cont.branch,
                    .has_when_guard = cont.condition != null,
                    .is_catchall = is_catchall,
                });
            } else if (is_catchall) {
                // Transition is a metatype but also a catchall - add it as catchall only
                try handled.append(self.allocator, .{
                    .name = "",
                    .has_when_guard = false,
                    .is_catchall = true,
                });
            }
        }

        // Validate using pure BranchChecker
        var result = try branch_checker.BranchChecker.validate(
            self.allocator,
            declared.items,
            handled.items,
        );
        defer branch_checker.BranchChecker.freeResult(self.allocator, &result);

        // Report errors
        for (result.missing_branches) |branch_name| {
            std.debug.print("ERROR: Branch '{s}' must be handled but no continuation found\n", .{branch_name});
            try self.reporter.addError(.KORU022, location.line, location.column,
                "branch '{s}' must be handled but no continuation found", .{branch_name});
            has_errors = true;
        }

        for (result.unknown_branches) |branch_name| {
            std.debug.print("ERROR: Continuation references unknown branch '{s}'\n", .{branch_name});
            try self.reporter.addError(.KORU021, location.line, location.column,
                "continuation references unknown branch '{s}'", .{branch_name});
            has_errors = true;
        }

        // Pre-pass: Register all label declarations from continuation pipelines
        for (continuations) |cont| {
            try self.registerContinuationLabels(&cont);
        }

        // Second pass: Validate all label jumps reference declared labels
        for (continuations) |cont| {
            try self.validateContinuationLabelJumps(&cont);
        }

        // For each continuation, check if it properly handles or terminates
        for (continuations) |cont| {
            // Check if this continuation terminates with _
            if (cont.node) |step| {
                if (step == .terminal) {
                    // This branch terminates, no further checking needed
                    continue;
                }

                // Check if the step produces branches that need handling
                if (step == .terminal) {
                    // Found a terminal marker, this path is handled
                    continue;
                }

                // Handle label jumps - CRITICAL for type safety!
                if (step == .label_apply) {
                    try self.validateLabelJump(step.label_apply, null, &cont);
                    continue;
                }

                if (step == .label_with_invocation) {
                    if (step.label_with_invocation.is_declaration) {
                        // This is a label declaration (#label event(...))
                        // Register the label if not already registered
                        const label_name = step.label_with_invocation.label;
                        if (self.labels.get(label_name) == null) {
                            try self.labels.put(try self.allocator.dupe(u8, label_name), LabelInfo{
                                .decl = null,
                                .expected_shape = null,
                                .line = 0,
                                .is_pre_invocation = true,  // Continuation labels are pre-invocation style
                                .jump_sites = try std.ArrayList(LabelInfo.JumpSite).initCapacity(self.allocator, 0),
                            });
                        }
                    } else {
                        // This is a label jump (@label event(...)) - OLD STYLE, should not be generated anymore
                        try self.validateLabelJump(
                            step.label_with_invocation.label,
                            &step.label_with_invocation.invocation,
                            &cont
                        );
                    }
                    continue;
                }

                if (step == .label_jump) {
                    // New style label jump: @label(args)
                    // Look up the label to get the event it refers to
                    const label_info = self.labels.get(step.label_jump.label);
                    if (label_info == null) {
                        std.debug.print("ERROR: Unknown label '{s}'\n", .{step.label_jump.label});
                        return error.UnknownLabel;
                    }
                    // For now, just validate that the label exists
                    // Full type checking happens in validateLabelJump
                    continue;
                }

                // Branch constructors produce a single branch and don't need nested handling
                if (step == .branch_constructor) {
                    // Validate the branch constructor
                    try self.validateBranchConstructor(&step.branch_constructor, &cont);
                    continue;
                }

                // Validate ALL invocations in the pipeline, not just the last one
                if (step == .invocation) {
                    const nested_event_name = try self.pathToString(step.invocation.path);
                    defer self.allocator.free(nested_event_name);

                    const nested_event_info = self.events.get(nested_event_name) orelse {
                        // Unknown event in pipeline - must fail!
                        std.debug.print("ERROR: Unknown event '{s}' in pipeline\n", .{nested_event_name});
                        return error.UnknownEvent;
                    };

                    // This is the only step, check nested continuations
                    if (cont.continuations.len == 0 and nested_event_info.decl.branches.len > 0) {
                        // Missing nested continuations for branching step
                        try self.reporter.addError(.KORU022, location.line, location.column,
                            "event '{s}' invoked in pipeline but its branches are not handled",
                            .{nested_event_name});
                        has_errors = true;
                        // Continue checking for more errors
                    }

                    // Recursively check nested continuation coverage
                    const nested_covered = try self.checkBranchCoverageWithTerminals(
                        nested_event_info.decl.branches,
                        cont.continuations,
                        location,
                    );
                    if (!nested_covered) {
                        return false;
                    }
                }

                // Handle foreach nodes - recurse into their branches
                if (step == .foreach) {
                    for (step.foreach.branches) |*branch| {
                        // Recursively validate the continuations inside each branch
                        const branch_valid = try self.validateNestedContinuations(
                            branch.body,
                            location,
                        );
                        if (!branch_valid) {
                            has_errors = true;
                        }
                    }
                    // Also check this continuation's nested continuations
                    if (cont.continuations.len > 0) {
                        const nested_valid = try self.validateNestedContinuations(
                            cont.continuations,
                            location,
                        );
                        if (!nested_valid) {
                            has_errors = true;
                        }
                    }
                    continue;
                }

                // Handle conditional nodes - recurse into their branches
                if (step == .conditional) {
                    for (step.conditional.branches) |*branch| {
                        // Recursively validate the continuations inside each branch
                        const branch_valid = try self.validateNestedContinuations(
                            branch.body,
                            location,
                        );
                        if (!branch_valid) {
                            has_errors = true;
                        }
                    }
                    // Also check this continuation's nested continuations
                    if (cont.continuations.len > 0) {
                        const nested_valid = try self.validateNestedContinuations(
                            cont.continuations,
                            location,
                        );
                        if (!nested_valid) {
                            has_errors = true;
                        }
                    }
                    continue;
                }

                // Handle capture nodes - recurse into their branches
                if (step == .capture) {
                    for (step.capture.branches) |*branch| {
                        // Recursively validate the continuations inside each branch
                        const branch_valid = try self.validateNestedContinuations(
                            branch.body,
                            location,
                        );
                        if (!branch_valid) {
                            has_errors = true;
                        }
                    }
                    // Also check this continuation's nested continuations
                    if (cont.continuations.len > 0) {
                        const nested_valid = try self.validateNestedContinuations(
                            cont.continuations,
                            location,
                        );
                        if (!nested_valid) {
                            has_errors = true;
                        }
                    }
                    continue;
                }
            }
        }

        // Return false if we found any errors during validation
        return !has_errors;
    }

    /// Recursively validate continuations inside control flow nodes
    fn validateNestedContinuations(
        self: *ShapeChecker,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
    ) anyerror!bool {
        var all_valid = true;

        for (continuations) |*cont| {
            // Validate label jumps in this continuation
            try self.validateContinuationLabelJumps(cont);

            // If there's a step, check it
            if (cont.node) |step| {
                // Handle invocations - check branch coverage
                if (step == .invocation) {
                    const nested_event_name = try self.pathToString(step.invocation.path);
                    defer self.allocator.free(nested_event_name);

                    if (self.events.get(nested_event_name)) |nested_event_info| {
                        // Check nested continuation coverage
                        if (cont.continuations.len == 0 and nested_event_info.decl.branches.len > 0) {
                            try self.reporter.addError(.KORU022, location.line, location.column,
                                "event '{s}' invoked but its branches are not handled",
                                .{nested_event_name});
                            all_valid = false;
                        } else {
                            const covered = try self.checkBranchCoverageWithTerminals(
                                nested_event_info.decl.branches,
                                cont.continuations,
                                location,
                            );
                            if (!covered) {
                                all_valid = false;
                            }
                        }
                    }
                }

                // Recurse into nested control flow nodes
                if (step == .foreach) {
                    for (step.foreach.branches) |*branch| {
                        const valid = try self.validateNestedContinuations(branch.body, location);
                        if (!valid) all_valid = false;
                    }
                }
                if (step == .conditional) {
                    for (step.conditional.branches) |*branch| {
                        const valid = try self.validateNestedContinuations(branch.body, location);
                        if (!valid) all_valid = false;
                    }
                }
                if (step == .capture) {
                    for (step.capture.branches) |*branch| {
                        const valid = try self.validateNestedContinuations(branch.body, location);
                        if (!valid) all_valid = false;
                    }
                }
            }

            // Always recurse into nested continuations
            if (cont.continuations.len > 0) {
                const valid = try self.validateNestedContinuations(cont.continuations, location);
                if (!valid) all_valid = false;
            }
        }

        return all_valid;
    }
    
    fn validateProc(self: *ShapeChecker, proc: *const ast.ProcDecl, module_qualifier: ?[]const u8) !void {
        // Build the full path for lookup
        // If module_qualifier is provided, prepend it (e.g., "std.io:println")
        const path = if (module_qualifier) |mq| blk: {
            var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            errdefer buf.deinit(self.allocator);

            try buf.appendSlice(self.allocator, mq);
            try buf.append(self.allocator, ':');
            for (proc.path.segments, 0..) |segment, i| {
                if (i > 0) try buf.append(self.allocator, '.');
                try buf.appendSlice(self.allocator, segment);
            }
            break :blk try buf.toOwnedSlice(self.allocator);
        } else blk: {
            break :blk try self.pathToString(proc.path);
        };
        defer self.allocator.free(path);  // Free temp string after lookup

        const event_info = self.events.get(path) orelse {
            // Proc without matching event
            return error.ProcWithoutEvent;
        };

        // Validate inline flows extracted from proc body
        // These have different validation rules than top-level flows
        for (proc.inline_flows) |*inline_flow| {
            try self.validateInlineFlow(inline_flow, event_info);
        }
    }

    fn validateInlineFlow(self: *ShapeChecker, flow: *const ast.Flow, proc_event: ?EventInfo) !void {
        // Check for duplicate branch handlers at each level (recursively)
        try self.checkDuplicateBranchHandlers(flow.continuations);

        // Inline flows with super_shape create union types - different validation
        if (flow.super_shape) |_| {
            // Still need to validate that the invoked event exists
            const event_name = try self.pathToString(flow.invocation.path);
            defer self.allocator.free(event_name);

            _ = self.events.get(event_name) orelse {
                return error.UnknownEvent;
            };

            // Note: We don't validate branch constructors against the proc's event here.
            // Inline flows with super_shapes can be assigned to variables (intermediate values)
            // or returned from procs. Only return flows need to match the proc's output,
            // and that's handled by the emitter when it generates the return statement.
            // The super_shape itself ensures the flow produces valid branches.
            _ = proc_event;
            return;
        }

        // Inline flow without super_shape - valid if continuations handle the branches
        // This is the case for fire-and-forget flows inside procs that invoke other events
        // Example:
        //   ~parse.source(...)
        //   | parsed result |> handle_success(result)
        //   | parse_error err |> handle_error(err)
        //
        // We still need to validate the event exists and branches are covered
        const event_name = try self.pathToString(flow.invocation.path);
        defer self.allocator.free(event_name);

        const event_info = self.events.get(event_name) orelse {
            return error.UnknownEvent;
        };

        // Check branch coverage for the inline flow
        const covered = try self.checkBranchCoverage(
            event_info.decl.branches,
            flow.continuations,
        );
        if (!covered) {
            return error.IncompleteBranchCoverage;
        }
        _ = proc_event;
    }

    /// Check for duplicate branch handlers at the same level (recursively)
    /// This catches incorrect indentation like:
    ///   | done x |> event1()
    ///   | done y |> event2()   <- WRONG: should be indented if handling event1's done
    fn checkDuplicateBranchHandlers(self: *ShapeChecker, continuations: []const ast.Continuation) !void {
        // Check for duplicates at this level
        for (continuations, 0..) |cont, i| {
            for (continuations[i + 1 ..]) |other| {
                if (std.mem.eql(u8, cont.branch, other.branch)) {
                    // Duplicate branch handler!
                    try self.reporter.addError(
                        .SHAPE002,
                        0,
                        0,
                        "Duplicate handler for branch '{s}'. If the second handler is for a chained event's result, it must be indented further.",
                        .{cont.branch},
                    );
                    return error.DuplicateBranchHandler;
                }
            }
        }

        // Recursively check nested continuations
        for (continuations) |cont| {
            try self.checkDuplicateBranchHandlers(cont.continuations);
        }
    }

    fn validateLabelJump(
        self: *ShapeChecker,
        label_name: []const u8,
        invocation: ?*const ast.Invocation,
        continuation: *const ast.Continuation,
    ) !void {
        // Look up the label
        const label_info = self.labels.getPtr(label_name) orelse {
            // Label doesn't exist!
            std.debug.print("ERROR: Jump to unknown label '{s}'\n", .{label_name});
            return error.UnknownLabel;
        };
        
        // Check if this is a parameterized jump
        const is_parameterized = invocation != null;
        
        // For pre-invocation labels (~#label pattern), we expect parameters
        if (label_info.is_pre_invocation) {
            if (!is_parameterized) {
                std.debug.print("ERROR: Pre-invocation label '{s}' requires parameters\n", .{label_name});
                return error.LabelRequiresParameters;
            }
            
            // Validate the invocation parameters match expected shape
            if (invocation) |inv| {
                // TODO: Validate that inv matches the expected event shape at the label
                _ = inv;
            }
        } else {
            // Post-invocation label (#label pattern) - no parameters expected
            if (is_parameterized) {
                std.debug.print("ERROR: Post-invocation label '{s}' does not accept parameters\n", .{label_name});
                return error.LabelDoesNotAcceptParameters;
            }
        }
        
        // Record this jump site for later validation
        try label_info.jump_sites.append(self.allocator, .{
            .line = 0, // TODO: Track actual line numbers
            .provided_shape = null, // TODO: Extract actual shape from context
            .is_parameterized = is_parameterized,
        });
        
        // Validate shape compatibility
        // For post-invocation labels, the current continuation's branch output must match
        // For pre-invocation labels, the invocation parameters must match
        _ = continuation;
    }

    fn registerContinuationLabels(self: *ShapeChecker, cont: *const ast.Continuation) !void {
        // Recursively register all label declarations in this continuation tree
        if (cont.node) |step| {
            if (step == .label_with_invocation and step.label_with_invocation.is_declaration) {
                const label_name = step.label_with_invocation.label;
                if (self.labels.get(label_name) == null) {
                    try self.labels.put(try self.allocator.dupe(u8, label_name), LabelInfo{
                        .decl = null,
                        .expected_shape = null,
                        .line = 0,
                        .is_pre_invocation = true,
                        .jump_sites = try std.ArrayList(LabelInfo.JumpSite).initCapacity(self.allocator, 0),
                    });
                }
            }
        }
        // Recursively process nested continuations
        for (cont.continuations) |nested| {
            try self.registerContinuationLabels(&nested);
        }
    }

    fn validateContinuationLabelJumps(self: *ShapeChecker, cont: *const ast.Continuation) !void {
        // Recursively validate all label jumps in this continuation tree
        if (cont.node) |step| {
            if (step == .label_with_invocation and !step.label_with_invocation.is_declaration) {
                // Old style label jump - validate it references a declared label
                const label_name = step.label_with_invocation.label;
                if (self.labels.get(label_name) == null) {
                    std.debug.print("ERROR: Unknown label '{s}'\n", .{label_name});
                    return error.UnknownLabel;
                }
            }
            if (step == .label_jump) {
                // New style label jump - validate it references a declared label
                const label_name = step.label_jump.label;
                if (self.labels.get(label_name) == null) {
                    std.debug.print("ERROR: Unknown label '{s}'\n", .{label_name});
                    return error.UnknownLabel;
                }
            }
        }
        // Recursively process nested continuations
        for (cont.continuations) |nested| {
            try self.validateContinuationLabelJumps(&nested);
        }
    }

    fn validateBranchConstructor(
        self: *ShapeChecker,
        constructor: *const ast.BranchConstructor,
        continuation: *const ast.Continuation,
    ) !void {
        // If there's a binding, we can use it for type context
        if (continuation.binding) |binding| {
            // Register the binding type for this branch
            // Note: Type engine will take ownership of these allocations
            const branch_type = type_inference.BranchType{
                .name = try self.type_engine.allocator.dupe(u8, continuation.branch),
                .fields = try self.type_engine.allocator.alloc(type_inference.FieldType, 0),
            };
            
            try self.type_engine.bindings.put(
                try self.type_engine.allocator.dupe(u8, binding),
                type_inference.TypeInfo{ .branch = branch_type },
            );
        }
        
        // Infer and validate the branch constructor type
        const inferred = try self.type_engine.inferBranchConstructor(
            @constCast(constructor), // Safe because we don't modify in inference
            null, // TODO: Provide expected type from context
        );
        
        // Validate that the constructed branch is valid
        switch (inferred) {
            .branch => |branch| {
                // Successfully inferred a branch type
                // TODO: Check if this branch is valid for the current flow context
                _ = branch;
            },
            else => {
                // Unexpected type from branch constructor
                return error.InvalidBranchConstructor;
            },
        }
    }
};

// Info structures for symbol table
pub const EventInfo = struct {
    decl: *const ast.EventDecl,
    line: usize,
};

const ProcInfo = struct {
    decl: *const ast.ProcDecl,
    line: usize,
};

const LabelInfo = struct {
    decl: ?*const ast.LabelDecl, // Optional - can be null for flow-defined labels
    expected_shape: ?ShapeUnion, // The shape this label expects
    line: usize,
    is_pre_invocation: bool, // True for ~#label pattern, false for #label pattern
    jump_sites: std.ArrayList(JumpSite), // Track all jumps to this label for validation
    
    const JumpSite = struct {
        line: usize,
        provided_shape: ?ShapeUnion,
        is_parameterized: bool, // True for @label(args) pattern
    };
};

const SubflowImplInfo = struct {
    impl: *const ast.SubflowImpl,
    line: usize,
};

// Shape union represents the branches an event can produce
const ShapeUnion = struct {
    branches: []BranchShape,
    
    const BranchShape = struct {
        name: []const u8,
        shape: ast.Shape,
    };
};

// Tests
test "shapes equal - empty shapes" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    const empty_a = ast.Shape{ .fields = &[_]ast.Field{} };
    const empty_b = ast.Shape{ .fields = &[_]ast.Field{} };
    
    try std.testing.expect(checker.shapesEqual(empty_a, empty_b));
}

test "shapes equal - same fields" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    var fields_a = [_]ast.Field{
        .{ .name = "path", .type = "[]const u8" },
        .{ .name = "errno", .type = "u8" },
    };
    var fields_b = [_]ast.Field{
        .{ .name = "errno", .type = "u8" },
        .{ .name = "path", .type = "[]const u8" },
    };
    
    const shape_a = ast.Shape{ .fields = &fields_a };
    const shape_b = ast.Shape{ .fields = &fields_b };
    
    // Order shouldn't matter
    try std.testing.expect(checker.shapesEqual(shape_a, shape_b));
}

test "shapes equal - different types" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    var fields_a = [_]ast.Field{
        .{ .name = "errno", .type = "u8" },
    };
    var fields_b = [_]ast.Field{
        .{ .name = "errno", .type = "u16" },
    };
    
    const shape_a = ast.Shape{ .fields = &fields_a };
    const shape_b = ast.Shape{ .fields = &fields_b };
    
    try std.testing.expect(!checker.shapesEqual(shape_a, shape_b));
}

test "shapes equal - missing field" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    var fields_a = [_]ast.Field{
        .{ .name = "path", .type = "[]const u8" },
        .{ .name = "errno", .type = "u8" },
    };
    var fields_b = [_]ast.Field{
        .{ .name = "path", .type = "[]const u8" },
    };
    
    const shape_a = ast.Shape{ .fields = &fields_a };
    const shape_b = ast.Shape{ .fields = &fields_b };
    
    try std.testing.expect(!checker.shapesEqual(shape_a, shape_b));
}

test "branch coverage - complete" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    const branches = [_]ast.Branch{
        .{ .name = "success", .payload = ast.Shape{ .fields = &[_]ast.Field{} } },
        .{ .name = "failure", .payload = ast.Shape{ .fields = &[_]ast.Field{} } },
    };
    
    const continuations = [_]ast.Continuation{
        .{ .branch = "success", .binding = null, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
        .{ .branch = "failure", .binding = null, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{} },
    };
    
    try std.testing.expect(try checker.checkBranchCoverage(&branches, &continuations));
}

test "branch coverage - missing branch" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    const branches = [_]ast.Branch{
        .{ .name = "success", .payload = ast.Shape{ .fields = &[_]ast.Field{} } },
        .{ .name = "failure", .payload = ast.Shape{ .fields = &[_]ast.Field{} } },
    };
    
    const continuations = [_]ast.Continuation{
        .{
            .branch = "success",
            .binding = null,
            .condition = null,
            .node = null,
            .indent = 0,
            .continuations = &[_]ast.Continuation{},
            .location = errors.SourceLocation{ .file = "internal", .line = 0, .column = 0 },
        },
    };
    
    try std.testing.expect(!try checker.checkBranchCoverage(&branches, &continuations));
}

test "branch coverage - unknown branch" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    const branches = [_]ast.Branch{
        .{ .name = "success", .payload = ast.Shape{ .fields = &[_]ast.Field{} } },
    };
    
    const continuations = [_]ast.Continuation{
        .{
            .branch = "success",
            .binding = null,
            .condition = null,
            .node = null,
            .indent = 0,
            .continuations = &[_]ast.Continuation{},
            .location = errors.SourceLocation{ .file = "internal", .line = 0, .column = 0 },
        },
        .{
            .branch = "unknown",
            .binding = null,
            .condition = null,
            .node = null,
            .indent = 0,
            .continuations = &[_]ast.Continuation{},
            .location = errors.SourceLocation{ .file = "internal", .line = 0, .column = 0 },
        },
    };
    
    try std.testing.expect(!try checker.checkBranchCoverage(&branches, &continuations));
}