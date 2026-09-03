const std = @import("std");

const log = @import("log");
const ast = @import("ast");
const errors = @import("errors");
const type_inference = @import("type_inference");
const branch_checker = @import("branch_checker");

/// The shape checker validates that:
/// 1. Event continuations cover all branches
/// 2. Shapes match at each pipeline step
/// 3. Labels are applied with matching shapes
/// 4. Proc returns match their event declaration

pub const ForeignEntry = struct {
    fields: [][]const u8,
};

pub const ShapeChecker = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,

    // Symbol table for tracking events, procs, labels, subflows
    events: std.StringHashMap(EventInfo),
    procs: std.StringHashMap(ProcInfo),
    labels: std.StringHashMap(LabelInfo),
    impl_flows: std.StringHashMap(ImplFlowInfo),
    // Foreign airlock registry (rung 2): foreign entry name → presence-claimed
    // field names. Built by scanning `std/foreign:struct(Name)` decl flows;
    // bare-name keyed (module rung for foreign is unbuilt, same as the nominal
    // gate). Owns keys and field-name strings.
    foreign_entries: std.StringHashMap(ForeignEntry),
    // Type inference engine
    type_engine: type_inference.TypeInference,

    /// Main module name from the program being checked (e.g. "test" for test.kz).
    /// Used to resolve unqualified event/proc references.
    main_module_name: []const u8 = "",

    /// `~[prototype]` module opt-in: relaxes required TERMINAL-branch coverage
    /// so an unhandled `|` branch is a synthesized `@panic` hole instead of a
    /// KORU022 error. Set by the check-structure pass from module_annotations.
    /// Never leaks to production: without the annotation this stays false and
    /// exhaustiveness is enforced as usual (400_160/400_161).
    prototype_mode: bool = false,

    /// The flow being validated carries `@shape_valid` — a transform's explicit
    /// claim about output it produced. MEASURED 2026-07-29: every program that
    /// depends on that claim depends on exactly ONE thing — branch coverage for
    /// an arm the transform CONSUMED (`capture` dissolves `! as`, `constructor`
    /// dissolves `! construct`; the arm is gone on purpose). So the claim
    /// relaxes coverage and NOTHING else, and every other check runs on the
    /// transform's output exactly as on hand-written code.
    ///
    /// It used to return early from validateFlow, skipping the whole checker —
    /// never measured, just the widest thing that made the tests pass. Riding
    /// `prototype_mode`'s channel keeps one relaxation path, not two.
    vouched_flow: bool = false,

    /// Subflow-implemented effects: when validating a flow that implements an
    /// event (`impl_of` set), this holds the implemented event's declaration so
    /// calls to its own effect arms — `ping = pong(x)`, `! each i |> each(i)` —
    /// resolve as ARM-FIRES instead of unknown events. Firing is a call
    /// (ruled 2026-07-02); only the declaring event's impl may fire its arms.
    current_impl_event: ?*const ast.EventDecl = null,

    /// The program carries `~test(...)` blocks. A test body reaches this pass as
    /// an UNPARSED `Source` string — std/testing lowers it at test-generation,
    /// which runs AFTER check-structure (compiler.kz:757). The mocks inside it
    /// (`~payment.charge => success "tx123"`) ARE implementations, and no walk of
    /// this AST can find them. So while test blocks are present, "invoked but has
    /// no implementation ANYWHERE" is not a claim this pass is in a position to
    /// make, and KORU047 stands down (395_008).
    program_has_test_blocks: bool = false,

    /// PRESENCE (`if(arm)` / `when arm`, ruled 2026-07-03): optional-arm names
    /// whose presence is established on the current walk path — pushed entering
    /// the `| then` of `if(<arm>)` and any continuation guarded `when <arm>`,
    /// popped on the way out. validateArmFire consults this to wall unguarded
    /// value-resuming optional fires (KORU130).
    presence_arms: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !ShapeChecker {
        return ShapeChecker{
            .allocator = allocator,
            .reporter = reporter,
            .events = std.StringHashMap(EventInfo).init(allocator),
            .procs = std.StringHashMap(ProcInfo).init(allocator),
            .labels = std.StringHashMap(LabelInfo).init(allocator),
            .impl_flows = std.StringHashMap(ImplFlowInfo).init(allocator),
            .foreign_entries = std.StringHashMap(ForeignEntry).init(allocator),
            .type_engine = try type_inference.TypeInference.init(allocator, reporter),
        };
    }
    
    pub fn deinit(self: *ShapeChecker) void {
        // Note: EventInfo/ProcInfo/ImplFlowInfo store POINTERS to AST data,
        // not copies. The AST is owned by the parser and freed there.
        // We only free the key strings that we allocated.

        var events_iter = self.events.iterator();
        while (events_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
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

        var impl_flow_iter = self.impl_flows.iterator();
        while (impl_flow_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.impl_flows.deinit();
        var foreign_iter = self.foreign_entries.iterator();
        while (foreign_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.fields) |f| self.allocator.free(f);
            self.allocator.free(entry.value_ptr.fields);
        }
        self.foreign_entries.deinit();
        self.presence_arms.deinit(self.allocator);
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
        // Check for DUPLICATE branch handlers at the same level — routed
        // through the shared kind-aware rule (BranchChecker.firstDuplicateSibling),
        // same source of truth as checkDuplicateBranchHandlers.
        {
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
                const cont = continuations[dup.index];
                if (dup.name.len == 0) {
                    try self.reporter.addErrorAtLocation(
                        .SHAPE002,
                        cont.location,
                        branch_checker.BranchChecker.duplicate_unnamed_msg,
                        .{},
                    );
                } else {
                    try self.reporter.addErrorAtLocation(
                        .SHAPE002,
                        cont.location,
                        branch_checker.BranchChecker.duplicate_terminal_fmt,
                        .{dup.name},
                    );
                }
                return false;
            }
        }

        // Check that every REQUIRED event branch has a matching continuation
        // Optional branches (marked with ?) don't need to be handled
        for (event_branches) |branch| {
            // Skip optional branches - they don't need to be handled
            if (branch.is_optional) continue;
            // Skip panic branches - ignorable (unhandled => synthesized @panic)
            if (branch.is_panic) continue;

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
    
    /// A lowered `~test(...)` block. std/testing's `test` keyword is a
    /// TRANSFORM: by the time check-structure runs, each test body has already
    /// become an `inline_code` item spelling
    /// `const test_<name>_module = struct { ... }` (koru_std/testing.kz:313
    /// mints that name). The mocks the body declared —
    /// `~payment.charge => success "tx123"` — live inside that generated module
    /// and ARE implementations, but they are TEXT here, not items this pass can
    /// resolve. See `program_has_test_blocks`.
    fn itemIsLoweredTestModule(item: *const ast.Item) bool {
        if (item.* != .inline_code) return false;
        const code = item.inline_code.code;
        return std.mem.startsWith(u8, code, "const test_") and
            std.mem.indexOf(u8, code, "_module = struct") != null;
    }

    /// Check an entire source file for shape consistency
    pub fn checkSourceFile(self: *ShapeChecker, source_file: *const ast.Program) !void {
        self.main_module_name = source_file.main_module_name;
        try self.buildForeignEntries(source_file.items);
        for (source_file.items) |*item| {
            if (itemIsLoweredTestModule(item)) {
                self.program_has_test_blocks = true;
                break;
            }
        }
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
                    // Note: key ownership transfers to hashmap, freed in deinit
                    try self.labels.put(try self.allocator.dupe(u8, label.name), LabelInfo{
                        .decl = label,
                        .expected_shape = null, // Will determine from usage
                        .line = 0,
                        .is_pre_invocation = is_pre,
                        .jump_sites = try std.ArrayList(LabelInfo.JumpSite).initCapacity(self.allocator, 0),
                    });
                },
                .flow => |*flow| {
                    // Register impl flows (flows with impl_of set)
                    if (flow.impl_of) |impl_path| {
                        const event_path = try self.pathToString(impl_path);
                        // Note: key ownership transfers to hashmap, freed in deinit
                        try self.impl_flows.put(event_path, ImplFlowInfo{
                            .flow = flow,
                            .line = 0,
                        });
                    }
                },
                .immediate_impl => |*ii| {
                    const event_path = try self.pathToString(ii.event_path);
                    try self.impl_flows.put(event_path, ImplFlowInfo{
                        .flow = null, // immediate impl, not a flow
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
        
        // Pass 1.5: link implementations to events. Impl items may precede
        // their event declarations, and module decls carry impl flows and
        // immediate impls the first pass doesn't register — so linking runs
        // as its own pass once every event is in the table. KORU047 reads
        // EventInfo.has_impl instead of re-deriving key spellings per site.
        for (source_file.items) |*item| {
            switch (item.*) {
                .proc_decl => |*proc| try self.markEventImplemented(proc.path, null),
                .flow => |*flow| {
                    if (flow.impl_of) |impl_path| try self.markEventImplemented(impl_path, null);
                },
                .immediate_impl => |*ii| try self.markEventImplemented(ii.event_path, null),
                .module_decl => |*module| {
                    for (module.items) |*module_item| {
                        switch (module_item.*) {
                            .proc_decl => |*proc| try self.markEventImplemented(proc.path, module.logical_name),
                            .flow => |*mflow| {
                                if (mflow.impl_of) |impl_path| try self.markEventImplemented(impl_path, module.logical_name);
                            },
                            .immediate_impl => |*ii| try self.markEventImplemented(ii.event_path, module.logical_name),
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
                .immediate_impl => |*ii| {
                    try self.validateImmediateImplShape(ii);
                    // Immediate values (like branch constructors) are already validated
                    // during parsing and type inference. No additional validation needed.
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

    /// Look up a registered event by path, trying module qualification and globs.
    fn lookupEventInfo(self: *ShapeChecker, path: ast.DottedPath) !?EventInfo {
        const event_name = try self.pathToString(path);
        defer self.allocator.free(event_name);

        if (self.events.get(event_name)) |info| return info;

        if (path.module_qualifier == null and self.main_module_name.len > 0) {
            var qualified_name_buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer qualified_name_buf.deinit(self.allocator);

            try qualified_name_buf.appendSlice(self.allocator, self.main_module_name);
            try qualified_name_buf.append(self.allocator, ':');
            try qualified_name_buf.appendSlice(self.allocator, event_name);

            const qualified_name = try qualified_name_buf.toOwnedSlice(self.allocator);
            defer self.allocator.free(qualified_name);

            if (self.events.get(qualified_name)) |info| return info;
        }

        if (self.findGlobMatch(event_name)) |info| return info;
        return null;
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
    
    fn validateFlow(self: *ShapeChecker, flow: *const ast.Flow, location: errors.SourceLocation, _: *const ast.Program) !void {
        // @shape_valid is an EXPLICIT, rare exemption from shape checking.
        // A transform must consciously stamp it on output the checker cannot
        // model (genuinely host-opaque rewrites). @pass_ran deliberately does
        // NOT exempt: "a pass ran" is a historical fact, not a validity
        // guarantee — transform output must be valid like any other AST.
        const prev_vouched = self.vouched_flow;
        defer self.vouched_flow = prev_vouched;
        for (flow.inv().annotations) |ann| {
            if (std.mem.startsWith(u8, ann, "@shape_valid")) {
                self.vouched_flow = true;
            }
        }

        // Clear labels from previous flows - labels are flow-scoped
        var label_it = self.labels.iterator();
        while (label_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.jump_sites.deinit(self.allocator);
        }
        self.labels.clearRetainingCapacity();

        // If this flow defines a pre-invocation label, validate it
        if (flow.pre_label) |label_name| {
            // Check if label was already declared
            if (self.labels.get(label_name)) |_| {
                log.debug("ERROR: Duplicate label '{s}' defined\n", .{label_name});
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
        
        // Subflow-implemented effects: resolve the implemented event (if any)
        // so arm-calls anywhere in this flow's body validate as arm-fires.
        const saved_impl_event = self.current_impl_event;
        self.current_impl_event = blk: {
            const impl_path = flow.impl_of orelse break :blk null;
            const impl_info = (try self.lookupEventInfo(impl_path)) orelse break :blk null;
            break :blk impl_info.decl;
        };
        defer self.current_impl_event = saved_impl_event;

        // Get the event being invoked
        const event_name = try self.pathToString(flow.inv().path);
        defer self.allocator.free(event_name);  // Free temp string after lookup

        const final_event_info = try self.lookupEventInfo(flow.inv().path) orelse {
            log.debug("ERROR: Unknown event '{s}'\n", .{event_name});
            // Inside the declaring event's impl, the event's own effect arms
            // are callable — the impl head `ping = pong(x)` FIRES the arm.
            if (self.armOfImplEvent(flow.inv().path)) |arm| {
                try self.validateArmFire(arm, flow.inv(), flow.body.continuations, location);
                return;
            }
            // Check if it's a subflow implementation
            if (self.impl_flows.get(event_name)) |impl_flow_info| {
                // Implementation exists - it implements this event
                // Get the event declaration for branch validation
                const event = self.events.get(event_name) orelse {
                    _ = impl_flow_info;
                    try self.reporter.addErrorAtLocation(
                        .KORU040,
                        location,
                        "subflow '{s}' has no matching event declaration",
                        .{event_name},
                    );
                    return error.SubflowWithoutEvent;
                };
                // Check branch coverage (with terminal marker awareness)
                const covered = try self.checkBranchCoverageWithTerminals(
                    event_name,
                    event.decl.branches,
                    flow.body.continuations,
                    location,
                    flow.inv(),
                    event.decl.return_type != null,
                );

                if (!covered) {
                    // Error already reported by checkBranchCoverageWithTerminals
                    return error.IncompleteBranchCoverage;
                }
                return;
            }
            // Unknown event. Pit-of-success wall: if the name matches an
            // effect arm of a declared event, the user tried to fire an arm
            // from OUTSIDE that event's impl — say so instead of leaving them
            // with a bare "unknown event".
            if (self.findEventOwningEffectArm(flow.inv().path)) |owner| {
                const owner_name = try self.pathToString(owner.path);
                defer self.allocator.free(owner_name);
                try self.reporter.addErrorAtLocation(
                    .KORU040,
                    location,
                    "'{s}' is an effect arm of tor '{s}' — only that tor's own implementation may fire it",
                    .{ flow.inv().path.segments[flow.inv().path.segments.len - 1], owner_name },
                );
                return error.UnknownEvent;
            }
            try self.reporter.addErrorAtLocation(
                .KORU040,
                location,
                "unknown tor '{s}'",
                .{event_name},
            );
            return error.UnknownEvent;
        };

        // Check branch coverage (with terminal marker awareness)
        const covered = try self.checkBranchCoverageWithTerminals(
            event_name,
            final_event_info.decl.branches,
            flow.body.continuations,
            location,
            flow.inv(),
            final_event_info.decl.return_type != null,
        );

        if (!covered) {
            return error.IncompleteBranchCoverage;
        }

        try self.checkInvokedEventImplemented(final_event_info, flow.inv(), flow.impl_of != null, location);
    }

    /// Mark the event targeted by an implementation item. Tries the impl's own
    /// spelling, then the enclosing module's qualification, then the main
    /// module's — the same key shapes event registration uses. A miss is fine
    /// here (proc-without-event is KORU050's domain, not KORU047's).
    ///
    /// Abstract events: resolve_abstract_impl rewires their impls to CHILD
    /// paths (`event.default`, variant overrides) and synthesizes child event
    /// decls — while invocations still target the PARENT. So each candidate
    /// also marks the parent event when that parent is `[abstract]`; the
    /// child-path impl IS the parent's implementation.
    fn markEventImplemented(self: *ShapeChecker, path: ast.DottedPath, module_name: ?[]const u8) !void {
        const spelled = try self.pathToString(path);
        defer self.allocator.free(spelled);

        const quals = [_]?[]const u8{
            null,
            if (path.module_qualifier == null) module_name else null,
            if (path.module_qualifier == null and self.main_module_name.len > 0) self.main_module_name else null,
        };
        for (quals) |maybe_q| {
            var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer buf.deinit(self.allocator);
            if (maybe_q) |q| {
                try buf.appendSlice(self.allocator, q);
                try buf.append(self.allocator, ':');
            }
            try buf.appendSlice(self.allocator, spelled);
            if (self.events.getPtr(buf.items)) |info| {
                info.has_impl = true;
            }
            // Abstract parent: strip the last `.segment` of the key and mark
            // the parent iff it is an [abstract] event.
            if (std.mem.lastIndexOfScalar(u8, buf.items, '.')) |dot_idx| {
                const colon_idx = std.mem.indexOfScalar(u8, buf.items, ':') orelse 0;
                if (dot_idx > colon_idx) {
                    if (self.events.getPtr(buf.items[0..dot_idx])) |parent| {
                        if (parent.decl.hasAnnotation("abstract")) parent.has_impl = true;
                    }
                }
            }
        }
    }

    /// Pit-of-success wall (KORU047): an event that is INVOKED but has NO
    /// implementation anywhere must fail loudly HERE. Otherwise the emitter's
    /// !found_impl path synthesizes a silent stub — `return undefined;` for a
    /// `-> T` event, first-branch zero-defaults for `|` events — and the
    /// program prints a confident wrong answer at runtime. The stub stays
    /// legitimate only where it is provably never called (comptime-only,
    /// [norun], wildcard shape-only events) or where auto-proc passthrough
    /// synthesizes real behavior; those shapes are exempted below, mirroring
    /// the emitter's own synthesis conditions.
    fn checkInvokedEventImplemented(
        self: *ShapeChecker,
        event_info: EventInfo,
        inv: *const ast.Invocation,
        /// True only for the HEAD of a subflow-implementation flow — that head
        /// IS the implementation, not a call. A step further down the same
        /// flow's chain is an ordinary call and must be checked.
        is_impl_head: bool,
        location: errors.SourceLocation,
    ) !void {
        const event = event_info.decl;

        // Registration already linked an implementation to this event.
        if (event_info.has_impl) return;

        // A subflow-implementation head is the implementation, not a call.
        if (is_impl_head) return;

        // An implementation may be sitting in an unparsed `~test` body.
        if (self.program_has_test_blocks) return;

        // Never-emitted / never-run events cannot reach a live stub.
        if (event.hasAnnotation("norun")) return;
        if (event.isComptimeOnly()) return;

        // Glob-declared events (log.*) resolve many spellings to one decl;
        // implementation probing by invocation spelling would false-positive.
        const decl_path = try self.pathToString(event.path);
        defer self.allocator.free(decl_path);
        if (std.mem.indexOfScalar(u8, decl_path, '*') != null) return;

        // Does this event NEED an implementation? Two questions, and only the
        // second is shared with the emitter.
        //
        // `[abstract]` is a contract that an implementation exists SOMEWHERE —
        // invoking one with neither default nor override is an error whatever
        // its output shape (resolve_abstract_impl's own doctrine: "Neither
        // default nor override: error if invoked"). That is about where code
        // lives, not about what an empty body would return, so it stays here.
        //
        // The rest is the shape question — would the empty body have to INVENT
        // an answer — and the emitter asks it identically when deciding what to
        // write. One predicate serves both; this used to be a hand-kept copy of
        // the emitter's synthesis conditions.
        if (!event.hasAnnotation("abstract") and !ast.stubWouldFabricate(event)) return;

        const inv_name = try self.pathToString(inv.path);
        defer self.allocator.free(inv_name);
        const short_name = inv.path.segments[inv.path.segments.len - 1];
        try self.reporter.addErrorAtLocation(
            .KORU047,
            location,
            "event '{s}' is invoked but has no implementation — without one the compiler would silently stub it to return zero-defaults. Implement it with a proc (`~proc {s}|zig {{ ... }}`), a bare-return impl (`~{s} -> <value>`), a branch constructor (`~{s} => <branch> <value>`), or a subflow (`~{s} = <flow>`)",
            .{ inv_name, short_name, short_name, short_name, short_name },
        );
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
                    log.debug("WARNING: Namespace wildcard '{s}' matches no events\n", .{source_path});
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

                if (!is_meta_event and (try self.lookupEventInfo(source)) == null) {
                    log.debug("ERROR: Unknown source event '{s}' in tap\n", .{source_path});
                    try self.reporter.addErrorAtLocation(.KORU040, location, "unknown source tor '{s}' in tap", .{source_path});
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
                    log.debug("WARNING: Namespace wildcard '{s}' matches no events\n", .{dest_path});
                    // Don't fail - it might be intentional
                }
            } else {
                // Regular event path - must exist
                const dest_path = try self.pathToString(dest);
                defer self.allocator.free(dest_path);

                if ((try self.lookupEventInfo(dest)) == null) {
                    log.debug("ERROR: Unknown destination event '{s}' in tap\n", .{dest_path});
                    try self.reporter.addErrorAtLocation(.KORU040, location, "unknown destination event '{s}' in tap", .{dest_path});
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

            if ((try self.lookupEventInfo(event_path))) |event_info| {
                _ = event_info;
            }
        } else if (!tap.is_input_tap) {
            // Wildcard output tap - we can't validate branches without knowing the event
            // This is OK - will be checked at compile time when matching actual events
            // For now, just ensure continuations are well-formed
            for (tap.continuations) |cont| {
                if (cont.branch.len == 0 and !std.mem.eql(u8, cont.branch, "transition")) {
                    log.debug("ERROR: Invalid branch name in wildcard tap\n", .{});
                    try self.reporter.addErrorAtLocation(.KORU021, location, "invalid branch name in wildcard tap", .{});
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
                log.debug("ERROR: Event '{s}.{s}' has no branch '{s}'\n",
                    .{event_decl.path.segments[0], event_decl.path.segments[event_decl.path.segments.len - 1], cont.branch});
                try self.reporter.addErrorAtLocation(.KORU021, location, "event '{s}.{s}' has no branch '{s}'",
                    .{event_decl.path.segments[0], event_decl.path.segments[event_decl.path.segments.len - 1], cont.branch});
                // Continue checking for more errors
            }
        }

        // Note: We do NOT check exhaustiveness for taps
        // Taps can observe only the branches they care about
    }
    
    /// If `path` names an effect arm of the event currently being implemented
    /// (single segment, module qualifier absent or matching the event's own),
    /// return that arm. Non-impl flows have no current_impl_event, so arm
    /// names never resolve outside the declaring event's implementation.
    fn armOfImplEvent(self: *ShapeChecker, path: ast.DottedPath) ?*const ast.Branch {
        const impl_ev = self.current_impl_event orelse return null;
        if (path.segments.len != 1) return null;
        if (path.module_qualifier) |mq| {
            const emq = impl_ev.path.module_qualifier orelse return null;
            if (!std.mem.eql(u8, mq, emq)) return null;
        }
        for (impl_ev.branches) |*b| {
            if (b.kind == .effect and std.mem.eql(u8, b.name, path.segments[0])) return b;
        }
        return null;
    }

    /// PRESENCE: a bare identifier — the only shape an arm name in condition
    /// position can take. Anything with operators, calls, spaces or dots is a
    /// runtime value condition, never a presence test.
    fn isBareIdent(text: []const u8) bool {
        if (text.len == 0) return false;
        for (text, 0..) |ch, i| {
            const alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
            const digit = ch >= '0' and ch <= '9';
            if (i == 0) {
                if (!alpha) return false;
            } else if (!(alpha or digit or ch == '-')) return false;
        }
        return true;
    }

    /// PRESENCE: resolve condition-position text against the enclosing impl
    /// event's effect arms. Inside the declaring event's impl, an arm's bare
    /// name in `if`-condition / `when`-guard position IS the presence
    /// expression (arm-first, ruled 2026-07-03). Null outside impls or for
    /// non-arm conditions.
    fn presenceArmByName(self: *ShapeChecker, text: []const u8) ?*const ast.Branch {
        const impl_ev = self.current_impl_event orelse return null;
        const trimmed = std.mem.trim(u8, text, " \t");
        if (!isBareIdent(trimmed)) return null;
        for (impl_ev.branches) |*b| {
            if (b.kind == .effect and std.mem.eql(u8, b.name, trimmed)) return b;
        }
        return null;
    }

    /// PRESENCE: an invocation that is a presence test — `if(<arm>)` inside
    /// the arm's declaring event's impl. Returns the tested arm.
    fn presenceTestedArm(self: *ShapeChecker, inv: *const ast.Invocation) ?*const ast.Branch {
        if (inv.path.segments.len == 0) return null;
        if (!std.mem.eql(u8, inv.path.segments[inv.path.segments.len - 1], "if")) return null;
        if (inv.args.len != 1) return null;
        const text = if (inv.args[0].expression_value) |ev| ev.text else inv.args[0].value;
        return self.presenceArmByName(text);
    }

    /// PRESENCE: is `arm`'s presence established on the current walk path?
    fn presenceEstablished(self: *ShapeChecker, arm_name: []const u8) bool {
        for (self.presence_arms.items) |n| {
            if (std.mem.eql(u8, n, arm_name)) return true;
        }
        return false;
    }

    /// Find a declared event owning an effect arm named by `path`'s last
    /// segment. Diagnostic aid only: when an arm is called outside its
    /// event's impl, the error can name the owner instead of "unknown event".
    fn findEventOwningEffectArm(self: *ShapeChecker, path: ast.DottedPath) ?*const ast.EventDecl {
        if (path.segments.len != 1) return null;
        const name = path.segments[0];
        var it = self.events.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.decl.branches) |*b| {
                if (b.kind == .effect and std.mem.eql(u8, b.name, name)) return entry.value_ptr.decl;
            }
        }
        return null;
    }

    /// Validate an arm-fire: a call to one of the implemented event's own
    /// effect arms from inside its impl subflow. The consuming shape is fixed
    /// by the arm's declaration (mirroring what the proc side gets from Zig):
    ///   - void arm      → bare call; nothing to bind, no branches to handle
    ///   - `-> T` resume → call-site `:` bind, then ordinary continuation
    ///   - multi-arm sum → `|` branches at the firing site, ALL arms handled
    ///     (the proc side gets this exhaustiveness from Zig's switch)
    fn validateArmFire(
        self: *ShapeChecker,
        arm: *const ast.Branch,
        inv: *const ast.Invocation,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
    ) anyerror!void {
        // PRESENCE WALL (KORU130): a `?` optional arm that RESUMES a value may
        // be absent — an unguarded fire would bind a value that might not
        // exist. No no-op can be synthesized (a fn with a mandatory return and
        // an empty body is not a thing) and a fabricated default would be a
        // silent fallback, so the fire must sit under a presence test on the
        // arm (`if(<arm>) | then` or `when <arm>`).
        if (arm.is_optional and (arm.resume_type != null or arm.resume_arms != null) and
            !self.presenceEstablished(arm.name))
        {
            try self.reporter.addErrorAtLocation(.KORU130, location,
                "effect '{s}' is optional and resumes a value — a consumer may omit the handler, so the fire must sit under a presence test: if({s}) | then |> {s}(...): ... | else |> <your fallback>",
                .{ arm.name, arm.name, arm.name });
            return error.ValidationFailed;
        }

        // Payload shape at the firing site follows the BRANCH convention
        // (arms are branches, and firing is construction's call-twin):
        //   - payloadless arm  → bare fire, `ask()`        (like `=> timeout`)
        //   - identity payload → one bare value, `pong(x)` (like `=> done n`)
        //   - record payload   → NAMED fields, `token(kind: 1, val: n)`
        //     (like `=> result { halved: ..., quadrupled: ... }`)
        // Ruled 2026-07-02. A positional fire against a record arm reads as
        // punning and is rejected; a named arg whose value happens to equal
        // its field name (`token(kind: kind)`) is named, and fine.
        const is_identity_payload = arm.payload.fields.len == 1 and
            std.mem.eql(u8, arm.payload.fields[0].name, "__type_ref");
        if (arm.payload.fields.len == 0 and !arm.payload.is_wildcard) {
            if (inv.args.len != 0) {
                try self.reporter.addErrorAtLocation(.KORU030, location,
                    "effect '{s}' carries no payload — fire it bare: {s}()",
                    .{ arm.name, arm.name });
                return error.ValidationFailed;
            }
        } else if (is_identity_payload or arm.payload.is_wildcard) {
            if (inv.args.len != 1) {
                try self.reporter.addErrorAtLocation(.KORU030, location,
                    "effect '{s}' carries a single anonymous payload — fire it with exactly one value: {s}(value)",
                    .{ arm.name, arm.name });
                return error.ValidationFailed;
            }
        } else {
            var field_names = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer field_names.deinit(self.allocator);
            for (arm.payload.fields, 0..) |*f, fi| {
                if (fi > 0) try field_names.appendSlice(self.allocator, ", ");
                try field_names.appendSlice(self.allocator, f.name);
                try field_names.appendSlice(self.allocator, ": ...");
            }
            var shape_errors = false;
            for (inv.args) |arg| {
                const known = for (arm.payload.fields) |*f| {
                    if (std.mem.eql(u8, f.name, arg.name)) break true;
                } else false;
                if (known) continue;
                if (std.mem.eql(u8, arg.name, arg.value)) {
                    try self.reporter.addErrorAtLocation(.KORU030, location,
                        "effect '{s}' carries a record payload — fire it with named fields: {s}({s})",
                        .{ arm.name, arm.name, field_names.items });
                } else {
                    try self.reporter.addErrorAtLocation(.KORU021, location,
                        "effect '{s}' has no payload field '{s}' (fields: {s})",
                        .{ arm.name, arg.name, field_names.items });
                }
                shape_errors = true;
            }
            for (arm.payload.fields) |*f| {
                const provided = for (inv.args) |arg| {
                    if (std.mem.eql(u8, arg.name, f.name)) break true;
                } else false;
                if (!provided) {
                    try self.reporter.addErrorAtLocation(.KORU022, location,
                        "effect '{s}' payload field '{s}' missing at the firing site ({s}({s}))",
                        .{ arm.name, f.name, arm.name, field_names.items });
                    shape_errors = true;
                }
            }
            if (shape_errors) return error.ValidationFailed;
        }

        if (arm.resume_arms) |arms| {
            if (inv.return_binding != null) {
                try self.reporter.addErrorAtLocation(.KORU102, location,
                    "effect '{s}' resumes with named arms — handle them as `|` branches at the firing site, not a `:` bind",
                    .{arm.name});
                return error.ValidationFailed;
            }
            var has_errors = false;
            for (continuations) |*cont| {
                if (cont.branch.len == 0) continue;
                const known = for (arms) |*ra| {
                    if (std.mem.eql(u8, ra.name, cont.branch)) break true;
                } else false;
                if (!known) {
                    var arm_names = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                    defer arm_names.deinit(self.allocator);
                    for (arms, 0..) |*ra, ai| {
                        if (ai > 0) try arm_names.appendSlice(self.allocator, ", ");
                        try arm_names.appendSlice(self.allocator, ra.name);
                    }
                    try self.reporter.addErrorAtLocation(.KORU021, cont.location,
                        "effect '{s}' has no resume arm '{s}' (arms: {s})",
                        .{ arm.name, cont.branch, arm_names.items });
                    has_errors = true;
                }
            }
            for (arms) |*ra| {
                const handled = for (continuations) |*cont| {
                    if (std.mem.eql(u8, cont.branch, ra.name)) break true;
                } else false;
                if (!handled) {
                    try self.reporter.addErrorAtLocation(.KORU022, location,
                        "resume arm '{s}' of effect '{s}' must be handled at the firing site",
                        .{ ra.name, arm.name });
                    has_errors = true;
                }
            }
            if (has_errors) return error.ValidationFailed;
            _ = try self.validateNestedContinuations(continuations, location);
            return;
        }
        if (arm.resume_type) |rt| {
            for (continuations) |*cont| {
                if (cont.branch.len != 0) {
                    try self.reporter.addErrorAtLocation(.KORU102, cont.location,
                        "effect '{s}' is declared `-> {s}` (single payload, no arms) — bind it at the call site (`{s}(...): name`)",
                        .{ arm.name, rt, arm.name });
                    return error.ValidationFailed;
                }
            }
            _ = try self.validateNestedContinuations(continuations, location);
            return;
        }
        // Void arm: fire-and-continue, nothing comes back.
        if (inv.return_binding != null) {
            try self.reporter.addErrorAtLocation(.KORU102, location,
                "effect '{s}' carries no resume value — remove the `:` bind", .{arm.name});
            return error.ValidationFailed;
        }
        for (continuations) |*cont| {
            if (cont.branch.len != 0) {
                try self.reporter.addErrorAtLocation(.KORU021, cont.location,
                    "effect '{s}' carries no resume value — there are no branches to handle at the firing site",
                    .{arm.name});
                return error.ValidationFailed;
            }
        }
        _ = try self.validateNestedContinuations(continuations, location);
    }

    /// Resolve a handled continuation branch name against declared event
    /// branches: exact name first, then a declared raw-name CLASS branch
    /// (literally named `*`, spelled `| \`*\` *` in the decl) catches any
    /// remaining name. Mirrors branch_checker.resolveDeclared.
    fn resolveDeclaredBranch(event_branches: []const ast.Branch, name: []const u8) ?*const ast.Branch {
        for (event_branches) |*b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        for (event_branches) |*b| {
            if (std.mem.eql(u8, b.name, "*")) return b;
        }
        return null;
    }

    /// Comma-joined declared branch names for a diagnostic hint, into a
    /// caller-owned stack buffer (the refusal path must not allocate).
    ///
    /// KNOWINGLY a second copy of flow_checker.branchNameList — that one is
    /// private to a module this one does not import, and branch_checker, the
    /// only module both see, declares "No AST awareness: works on branch
    /// names, not node types" (branch_checker.zig:11) so it cannot host an
    /// `ast.Branch` helper. Converging the two wants a shared diagnostics
    /// helper module, which is a separate change; recorded here rather than
    /// left for a reader to discover.
    fn declaredBranchNames(buf: []u8, branches: []const ast.Branch) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        for (branches, 0..) |b, i| {
            if (i > 0) w.writeAll(", ") catch break;
            w.writeAll(b.name) catch break;
        }
        if (fbs.getWritten().len == 0) return "(none)";
        return fbs.getWritten();
    }

    fn checkBranchCoverageWithTerminals(
        self: *ShapeChecker,
        event_name: []const u8,
        event_branches: []const ast.Branch,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
        // The invocation these continuations handle, when the caller has it.
        // Presence resolution needs it: `if(<arm>)` establishes the arm for
        // the `| then` subtree, and `if(<required arm>)` is the KORU131 wall.
        parent_inv: ?*const ast.Invocation,
        bare_return: bool,
    ) !bool {
        // Bare-return events (`-> T`) have no branch tags. A named `| tag`
        // continuation is the one-variant union (PARSE003's use-site twin):
        // bind the value with `: name`. Empty names are the rest of a `|>`
        // chain; `_` is produce sugar; `!` arms are 0..N, not tags of this
        // return; transform-grafted subtrees are comptime data, not user
        // dispatch. The chain hanging off the head still walks as a pipeline.
        if (bare_return) {
            var tagged = false;
            for (continuations) |cont| {
                if (cont.is_transformed_subtree) continue;
                if (cont.kind == .effect) continue;
                if (cont.branch.len == 0) continue;
                if (std.mem.eql(u8, cont.branch, "_")) continue;
                const loc = if (cont.location.line != 0) cont.location else location;
                try self.reporter.addErrorAtLocationWithHint(
                    .KORU021,
                    loc,
                    "continuation branch '{s}' on tor '{s}' — a bare return has no tags",
                    .{ cont.branch, event_name },
                    "bind the value with `: name`, not `| {s}`",
                    .{cont.branch},
                );
                tagged = true;
            }
            const pipeline_ok = try self.validatePipelineSteps(event_branches, continuations, location, parent_inv);
            return pipeline_ok and !tagged;
        }

        // Track if we found any errors (but continue checking to find all of them)
        var has_errors = false;

        // PRESENCE WALL (KORU131): `if(<required arm>)` — a required arm is
        // always installed (exhaustiveness guarantees a handler), so testing
        // for it is a meaningless always-true and almost certainly a misread
        // of the contract. Reject and say why, never fold to `true` silently.
        if (parent_inv) |pinv| {
            if (self.presenceTestedArm(pinv)) |arm| {
                if (!arm.is_optional) {
                    try self.reporter.addErrorAtLocation(.KORU131, location,
                        "presence test on '{s}' — a required arm is always installed (exhaustiveness guarantees a handler), so `if({s})` is always true; presence tests are for `?` optional arms",
                        .{ arm.name, arm.name });
                    has_errors = true;
                }
            }
        }

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
                .is_panic = branch.is_panic,
                .kind = if (branch.kind == .effect) .effect else .terminal,
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

            // PRESENCE (ruled 2026-07-03): a `when <optional arm>` guard is a
            // COMPTIME partition over CONSUMERS — per consumer it is
            // all-or-nothing, statically known — not a runtime per-firing hole
            // (the 210_084/085 rationale), so it counts as FULL coverage of
            // the branch. A presence test on a REQUIRED arm is the KORU131
            // wall, same as in `if` position.
            const presence_guard: ?*const ast.Branch = if (cont.condition) |c| self.presenceArmByName(c) else null;
            if (presence_guard) |arm| {
                if (!arm.is_optional) {
                    try self.reporter.addErrorAtLocation(.KORU131, cont.location,
                        "presence test on '{s}' — a required arm is always installed (exhaustiveness guarantees a handler), so `when {s}` is always true; presence tests are for `?` optional arms",
                        .{ arm.name, arm.name });
                    has_errors = true;
                }
            }

            if (!is_metatype) {
                try handled.append(self.allocator, .{
                    .name = cont.branch,
                    .has_when_guard = cont.condition != null and presence_guard == null,
                    .is_catchall = is_catchall,
                    .kind = if (cont.kind == .effect) .effect else .terminal,
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

        // Branch kind-mismatch check (KORU025): a `!` (effect) decl branch
        // must be handled by a `!` continuation, and a `|` (terminal) decl
        // branch by a `|` continuation. Catch-alls are exempt — they match by
        // kind elsewhere. Handled names resolve exact-first, then against a
        // declared raw-name CLASS branch (`*`).
        for (continuations) |cont| {
            if (cont.is_catchall or cont.branch.len == 0) continue;
            const is_metatype = std.mem.eql(u8, cont.branch, "Transition") or
                std.mem.eql(u8, cont.branch, "Profile") or
                std.mem.eql(u8, cont.branch, "Audit");
            if (is_metatype) continue;
            if (resolveDeclaredBranch(event_branches, cont.branch)) |decl| {
                if (decl.kind != cont.kind) {
                    try errors.branchKindMismatch(
                        self.reporter,
                        cont.location,
                        cont.branch,
                        if (decl.kind == .effect) .effect else .terminal,
                        if (cont.kind == .effect) .effect else .terminal,
                    );
                    has_errors = true;
                }
            }
        }

        // Validate using pure BranchChecker (prototype mode relaxes terminal
        // exhaustiveness — the missing arm becomes a synthesized @panic hole).
        var result = try branch_checker.BranchChecker.validateWithMode(
            self.allocator,
            declared.items,
            handled.items,
            self.prototype_mode,
        );
        defer branch_checker.BranchChecker.freeResult(self.allocator, &result);

        // Report errors.
        //
        // A VOUCHED flow reports no missing branch. That is the whole content of
        // `@shape_valid`: a transform DISSOLVED the arms — capture turns `! as`
        // into a cell preamble, constructor turns `! construct` into a comptime
        // list — so the declaration's arms have no handler ON PURPOSE.
        //
        // It is deliberately NOT routed through `prototype_mode`, which reads
        // adjacent and is the wrong channel: that relaxes TERMINAL coverage
        // only (:35), and every arm a transform dissolves is an EFFECT arm.
        // MEASURED by probe 2026-07-29 — the flag was set and KORU022 fired
        // anyway, because `! as` is not a `|`.
        //
        // Everything else in this checker still runs on the transform's output.
        // The claim buys exactly coverage, which is all any program was ever
        // measured to need from it.
        for (result.missing_branches) |branch_name| {
            if (self.vouched_flow) continue;
            // A branch whose handlers are ALL behind `when` guards is not
            // "unhandled" — it is non-exhaustive. Say so (KORU050, the same
            // teaching message the flow checker uses), never the misleading
            // "no continuation found". Since when-clause judging moved
            // post-transform (2026-07-17), this site is the first responder.
            var guarded_only = false;
            for (continuations) |cont| {
                if (std.mem.eql(u8, cont.branch, branch_name) and cont.condition != null) {
                    guarded_only = true;
                    break;
                }
            }
            if (guarded_only) {
                try self.reporter.addErrorAtLocation(.KORU050, location,
                    "branch '{s}' has when-guarded handlers but no else case - a fire where every guard is false silently does nothing; add one continuation without 'when'", .{branch_name});
                has_errors = true;
                continue;
            }
            log.debug("ERROR: Branch '{s}' must be handled but no continuation found\n", .{branch_name});
            try self.reporter.addErrorAtLocation(.KORU022, location,
                "branch '{s}' must be handled but no continuation found", .{branch_name});
            has_errors = true;
        }

        for (result.unknown_branches) |branch_name| {
            log.debug("ERROR: Continuation references unknown branch '{s}'\n", .{branch_name});
            // Build list of available branches for helpful error message
            var available_branches = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer available_branches.deinit(self.allocator);
            for (event_branches, 0..) |branch, i| {
                if (i > 0) try available_branches.appendSlice(self.allocator, ", ");
                try available_branches.appendSlice(self.allocator, branch.name);
            }
            const available_str = if (available_branches.items.len > 0)
                available_branches.items
            else
                "(none)";
            try self.reporter.addErrorAtLocation(.KORU021, location,
                "event '{s}' has no branch '{s}' (available: {s})", .{ event_name, branch_name, available_str });
            has_errors = true;
        }

        // KORU028: a terminal `|` branch is a continuation that runs at most
        // once, so it may have at most one unguarded handler. Two unconditional
        // handlers for the same terminal branch are ambiguous. (Effect `!`
        // branches are exempt — they may be linked any number of times.)
        for (result.duplicate_terminal_branches) |branch_name| {
            try self.reporter.addErrorAtLocation(.KORU028, location,
                "terminal branch '{s}' has more than one unguarded handler — a `|` continuation runs at most once; distinguish them with `when` guards or remove the duplicate", .{branch_name});
            has_errors = true;
        }

        // Enforce payload branches to bind or explicitly discard
        for (continuations) |cont| {
            if (cont.branch.len == 0) continue;
            const is_metatype = std.mem.eql(u8, cont.branch, "Transition") or
                std.mem.eql(u8, cont.branch, "Profile") or
                std.mem.eql(u8, cont.branch, "Audit");
            if (is_metatype) continue;

            if (resolveDeclaredBranch(event_branches, cont.branch)) |branch| {
                const has_payload = branch.payload.is_wildcard or branch.payload.fields.len > 0;
                const has_binding = cont.binding != null or cont.destructure.len > 0;
                if (has_payload and !has_binding) {
                    try self.reporter.addErrorAtLocation(.KORU030, location,
                        "branch '{s}' has payload but no binding", .{cont.branch});
                    has_errors = true;
                }
                // The void half of the linear rule: a branch that carries
                // nothing has nothing to bind OR discard — `_` included.
                // A destructure on a void branch is the same error.
                if (!has_payload and has_binding) {
                    try self.reporter.addErrorAtLocation(.KORU101, location,
                        "branch '{s}' carries no payload — remove the binding '{s}'",
                        .{ cont.branch, cont.binding orelse "{...}" });
                    has_errors = true;
                }
                // A binding-position destructure (`| ok { a, b }`) unpacks the
                // payload by field NAME — validate each name against the payload
                // shape at the koru level. Otherwise an unknown field
                // (`| ok { nonexistent }`) reaches codegen and leaks as a raw host
                // `no field named` Zig error (210_147). Destructuring happens at
                // BINDING, never in the declaration; only record payloads have
                // named fields (wildcard/identity have none to destructure).
                if (!branch.payload.is_wildcard) {
                    const is_identity = branch.payload.fields.len == 1 and
                        std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref");
                    if (!is_identity) {
                        for (cont.destructure) |df| {
                            if (std.mem.eql(u8, df.name, "_")) continue;
                            var field_exists = false;
                            for (branch.payload.fields) |pf| {
                                if (std.mem.eql(u8, pf.name, df.name)) {
                                    field_exists = true;
                                    break;
                                }
                            }
                            if (!field_exists) {
                                var fnames = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                                defer fnames.deinit(self.allocator);
                                for (branch.payload.fields, 0..) |pf, fi| {
                                    if (fi > 0) try fnames.appendSlice(self.allocator, ", ");
                                    try fnames.appendSlice(self.allocator, pf.name);
                                }
                                try self.reporter.addErrorAtLocation(.KORU036, cont.location,
                                    "destructure field '{s}' is not a field of branch '{s}' (payload fields: {s})",
                                    .{ df.name, branch.name, fnames.items });
                                has_errors = true;
                            }
                        }
                    }
                }
            }
        }

        // The pipeline walk is not tag validation: a chain step must resolve,
        // be implemented, and have its own branches covered no matter what the
        // HEAD returns.
        if (!try self.validatePipelineSteps(event_branches, continuations, location, parent_inv)) {
            has_errors = true;
        }

        // Return false if we found any errors during validation
        return !has_errors;
    }

    /// The per-continuation STEP walk: label registration/jumps, glyph
    /// discipline, branch constructors, and every invocation in the pipeline
    /// (resolution, implementation, nested branch coverage).
    ///
    /// Split out of checkBranchCoverageWithTerminals because it is orthogonal to
    /// branch TAGS. A bare-return head (`-> T`) has no tags — named `| tag`
    /// continuations are refused above — but the chain hanging off it is an
    /// ordinary pipeline. Folding the two together meant one
    /// `if (bare_return) return true` silenced the whole walk, and an unknown
    /// tor or an unimplemented one mid-chain reached codegen (510_116/117, and
    /// a raw Zig "has no member named" for KORU040).
    fn validatePipelineSteps(
        self: *ShapeChecker,
        event_branches: []const ast.Branch,
        continuations: []const ast.Continuation,
        location: errors.SourceLocation,
        parent_inv: ?*const ast.Invocation,
    ) anyerror!bool {
        var has_errors = false;

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
            // A transform-owned subtree (std/parser grammar rule arms, store's
            // synthesized capture-cell chains) is comptime data the transform
            // has already consumed and validated — not user dispatch. Skip its
            // coverage walk entirely. Mirrors the SHAPE002 recursion skip.
            if (cont.is_transformed_subtree) continue;
            // PRESENCE scope: entering the `| then` of `if(<optional arm>)`,
            // or a continuation guarded `when <optional arm>`, establishes the
            // arm's presence for everything validated inside this subtree —
            // fires of the arm in here are guarded (KORU130 stands down).
            var presence_pushed: usize = 0;
            if (parent_inv) |pinv| {
                if (self.presenceTestedArm(pinv)) |arm| {
                    if (arm.is_optional and std.mem.eql(u8, cont.branch, "then")) {
                        try self.presence_arms.append(self.allocator, arm.name);
                        presence_pushed += 1;
                    }
                }
            }
            if (cont.condition) |c| {
                if (self.presenceArmByName(c)) |arm| {
                    if (arm.is_optional) {
                        try self.presence_arms.append(self.allocator, arm.name);
                        presence_pushed += 1;
                    }
                }
            }
            defer for (0..presence_pushed) |_| {
                _ = self.presence_arms.pop();
            };

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
                        log.debug("ERROR: Unknown label '{s}'\n", .{step.label_jump.label});
                        return error.UnknownLabel;
                    }
                    // For now, just validate that the label exists
                    // Full type checking happens in validateLabelJump
                    continue;
                }

                // Glyph discipline, produce side: `->` produces the single
                // anonymous resume value. When the effect declares named resume
                // ARMS, there is no anonymous value — the handler must SELECT
                // an arm with `=>`. (Dual of the KORU102 below.)
                if (step == .expression) {
                    if (resolveDeclaredBranch(event_branches, cont.branch)) |b| {
                        if (b.kind == .effect and b.resume_arms != null) {
                            try self.reporter.addErrorAtLocation(.KORU102, cont.location,
                                "`->` produces a single resume value, but '{s}' declares named resume arms — construct one with `=>` (e.g. `=> {s} ...`)",
                                .{ cont.branch, b.resume_arms.?[0].name });
                            continue;
                        }
                    }
                }

                // Branch constructors produce a single branch and don't need nested handling
                if (step == .branch_constructor) {
                    // Bare-return produce (`! ask -> { a, b }`): the `->` produces the
                    // single anonymous resume VALUE, not a `=>`-constructed branch. The
                    // parser encodes a record resume value as a branch_constructor with
                    // an empty branch_name and `is_bare_return`; the scalar form takes
                    // the `.expression` path above. Route it to the SAME produce-side
                    // rule: it is legal against a `-> T` resume (that IS the value it
                    // produces), and illegal only when the effect declares named resume
                    // ARMS (then there is no anonymous value — select an arm with `=>`).
                    // Never the `=>`-construct wall below, whose own advice — "use `->`"
                    // — the author already followed.
                    if (step.branch_constructor.is_bare_return) {
                        if (resolveDeclaredBranch(event_branches, cont.branch)) |b| {
                            if (b.kind == .effect and b.resume_arms != null) {
                                try self.reporter.addErrorAtLocation(.KORU102, cont.location,
                                    "`->` produces a single resume value, but '{s}' declares named resume arms — construct one with `=>` (e.g. `=> {s} ...`)",
                                    .{ cont.branch, b.resume_arms.?[0].name });
                            }
                        }
                        continue;
                    }
                    // Glyph discipline: `=>` CONSTRUCTS a branch. It is illegal when
                    // the handled effect/event produces a single payload (`-> T`) —
                    // there is no branch to construct; the payload is produced with
                    // `->`. (See project_resume_glyph_rules_and_phase2.)
                    if (resolveDeclaredBranch(event_branches, cont.branch)) |b| {
                        if (b.resume_type) |rt| {
                            try self.reporter.addErrorAtLocation(.KORU102, cont.location,
                                "`=>` constructs a branch, but '{s}' is declared `-> {s}` (single payload, no branches) — use `->` to produce it",
                                .{ cont.branch, rt });
                            continue;
                        }
                        // Multi-arm resume: the constructed name must be one of
                        // the declared arms. Without this wall, an unknown arm
                        // would sail through to a raw Zig error in the emitted
                        // union construction.
                        if (b.kind == .effect) {
                            if (b.resume_arms) |arms| {
                                const bc_name = step.branch_constructor.branch_name;
                                const known = for (arms) |*arm| {
                                    if (std.mem.eql(u8, arm.name, bc_name)) break true;
                                } else false;
                                if (!known) {
                                    var arm_names = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                                    defer arm_names.deinit(self.allocator);
                                    for (arms, 0..) |*arm, ai| {
                                        if (ai > 0) try arm_names.appendSlice(self.allocator, ", ");
                                        try arm_names.appendSlice(self.allocator, arm.name);
                                    }
                                    try self.reporter.addErrorAtLocation(.KORU021, cont.location,
                                        "effect '{s}' has no resume arm '{s}' (arms: {s})",
                                        .{ cont.branch, bc_name, arm_names.items });
                                    has_errors = true;
                                }
                                // Arm constructs resolve against the effect's
                                // resume sum, not the event's branch set — skip
                                // the event-branch constructor validation.
                                continue;
                            }
                        }
                    }
                    // Ordinary OUTCOME branches: the constructed name must be
                    // one the IMPLEMENTED tor declares — the same wall the
                    // effect resume-arm sibling above has carried since it was
                    // written, for the same stated reason ("without this wall,
                    // an unknown arm would sail through to a raw Zig error in
                    // the emitted union construction").
                    //
                    // It was missing here, and that is the whole defect: the
                    // wall exists on the IMMEDIATE-IMPL path as
                    // flow_checker.checkImplMatchesDecl, whose own comment
                    // names this failure and cites 510_112/113/114 — and
                    // 510_114's header memorialises the very Zig leak
                    // (`no field named 'nope' … get_input_event.Output`) that
                    // a flow-nested constructor still produced. `=>` vs `|>`
                    // is decided by the delimiter alone (parser.zig:7696), so
                    // a wrong name reaches here preserved verbatim as a branch
                    // name and nothing downstream had an opinion about it.
                    //
                    // Resolves against `current_impl_event`, NOT the handled
                    // event's `event_branches`: `| else => nosuchbranch` names
                    // a branch of the tor being IMPLEMENTED, while
                    // `event_branches` belongs to the tor being invoked (`if`).
                    // Silent when the impl event is unknown, mirroring
                    // checkImplMatchesDecl's "says nothing rather than
                    // guessing" discipline.
                    if (!self.prototype_mode and !self.vouched_flow) {
                        if (self.current_impl_event) |impl_ev| {
                            const bc_name = step.branch_constructor.branch_name;
                            if (bc_name.len > 0 and impl_ev.branches.len > 0 and
                                resolveDeclaredBranch(impl_ev.branches, bc_name) == null)
                            {
                                const impl_name = if (impl_ev.path.segments.len > 0)
                                    impl_ev.path.segments[impl_ev.path.segments.len - 1]
                                else
                                    "?";
                                var names_buf: [512]u8 = undefined;
                                try self.reporter.addErrorAtLocation(.KORU021, cont.location,
                                    "tor '{s}' has no branch '{s}' (declared branches are: {s})",
                                    .{ impl_name, bc_name, declaredBranchNames(&names_buf, impl_ev.branches) });
                                has_errors = true;
                            }
                        }
                    }
                    // Validate the branch constructor
                    try self.validateBranchConstructor(&step.branch_constructor, &cont);
                    continue;
                }

                // Validate ALL invocations in the pipeline, not just the last one
                if (step == .invocation) {
                    const nested_event_name = try self.pathToString(step.invocation.path);
                    defer self.allocator.free(nested_event_name);

                    // Resolve via lookupEventInfo so unqualified references to
                    // main-module events (including a flow calling ITSELF —
                    // value recursion) match the "main_module:name" key.
                    const nested_event_info = (try self.lookupEventInfo(step.invocation.path)) orelse {
                        // Arm-fire as a chain step: `! each i |> each(i)` inside
                        // the declaring event's impl calls the event's own arm.
                        if (self.armOfImplEvent(step.invocation.path)) |arm| {
                            try self.validateArmFire(arm, &step.invocation, cont.continuations, location);
                            continue;
                        }
                        // Unknown event in pipeline - must fail! Report with the
                        // name and location: this used to return a bare error
                        // that the coordinator rendered as a nameless "Unknown
                        // event referenced" with no KORU code or position.
                        log.debug("ERROR: Unknown event '{s}' in pipeline\n", .{nested_event_name});
                        if (self.findEventOwningEffectArm(step.invocation.path)) |owner| {
                            const owner_name = try self.pathToString(owner.path);
                            defer self.allocator.free(owner_name);
                            try self.reporter.addErrorAtLocation(.KORU040, location,
                                "'{s}' is an effect arm of tor '{s}' — only that tor's own implementation may fire it",
                                .{ step.invocation.path.segments[step.invocation.path.segments.len - 1], owner_name });
                            return error.UnknownEvent;
                        }
                        try self.reporter.addErrorAtLocation(.KORU040, location,
                            "unknown tor '{s}' in pipeline", .{nested_event_name});
                        return error.UnknownEvent;
                    };

                    // KORU047 at every chain position, not just position one.
                    // The emitter stubs an unimplemented event wherever it is
                    // called, so the wall has to reach wherever a call can sit
                    // (510_116, and 510_117 for what the stub produces).
                    try self.checkInvokedEventImplemented(nested_event_info, &step.invocation, false, location);

                    // This is the only step, check nested continuations
                    if (cont.continuations.len == 0 and nested_event_info.decl.branches.len > 0) {
                        // Missing nested continuations for branching step
                        try self.reporter.addErrorAtLocation(.KORU022, location,
                            "event '{s}' invoked in pipeline but its branches are not handled",
                            .{nested_event_name});
                        has_errors = true;
                        // Continue checking for more errors
                    }

                    // Recursively check nested continuation coverage
                    const nested_covered = try self.checkBranchCoverageWithTerminals(
                        nested_event_name,
                        nested_event_info.decl.branches,
                        cont.continuations,
                        location,
                        &step.invocation,
                        nested_event_info.decl.return_type != null,
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
                            try self.reporter.addErrorAtLocation(.KORU022, location,
                                "event '{s}' invoked but its branches are not handled",
                                .{nested_event_name});
                            all_valid = false;
                        } else {
                            const covered = try self.checkBranchCoverageWithTerminals(
                                nested_event_name,
                                nested_event_info.decl.branches,
                                cont.continuations,
                                location,
                                &step.invocation,
                                nested_event_info.decl.return_type != null,
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

        if (self.events.get(path) != null) return;

        if (module_qualifier == null and self.main_module_name.len > 0 and proc.path.module_qualifier == null) {
            var qualified_name_buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
            defer qualified_name_buf.deinit(self.allocator);

            try qualified_name_buf.appendSlice(self.allocator, self.main_module_name);
            try qualified_name_buf.append(self.allocator, ':');
            try qualified_name_buf.appendSlice(self.allocator, path);

            const qualified_name = try qualified_name_buf.toOwnedSlice(self.allocator);
            defer self.allocator.free(qualified_name);

            if (self.events.get(qualified_name) != null) return;
        }

        // Proc without matching event
        return error.ProcWithoutEvent;
    }

    fn validateInlineFlow(self: *ShapeChecker, flow: *const ast.Flow, proc_event: ?EventInfo) !void {
        // @shape_valid only — mirrors validateFlow's top-level rule. @pass_ran
        // does NOT exempt: a pass having run is not a validity guarantee.
        const prev_vouched = self.vouched_flow;
        defer self.vouched_flow = prev_vouched;
        for (flow.inv().annotations) |ann| {
            if (std.mem.startsWith(u8, ann, "@shape_valid")) {
                self.vouched_flow = true;
            }
        }

        // Check for duplicate branch handlers at each level (recursively). On a
        // hit the tree is structurally ambiguous — the coverage checks below
        // would only re-describe the same defect, so stop here; the SHAPE002 is
        // already reported and ValidationFailed keeps the failure loud.
        if (try self.checkDuplicateBranchHandlers(flow.body.continuations)) {
            return error.ValidationFailed;
        }

        // Inline flows with super_shape create union types - different validation
        if (flow.super_shape) |_| {
            // Still need to validate that the invoked event exists
            const event_name = try self.pathToString(flow.inv().path);
            defer self.allocator.free(event_name);

            _ = self.events.get(event_name) orelse {
                // Loud, not silent: name the event so the failure is actionable.
                try self.reporter.addErrorAtLocation(
                    .KORU040,
                    flow.location,
                    "unknown tor '{s}'",
                    .{event_name},
                );
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
        const event_name = try self.pathToString(flow.inv().path);
        defer self.allocator.free(event_name);

        const event_info = self.events.get(event_name) orelse {
            try self.reporter.addErrorAtLocation(
                .KORU040,
                flow.location,
                "unknown tor '{s}'",
                .{event_name},
            );
            return error.UnknownEvent;
        };

        // Check branch coverage for the inline flow using the version with proper error reporting
        const covered = try self.checkBranchCoverageWithTerminals(
            event_name,
            event_info.decl.branches,
            flow.body.continuations,
            flow.location,
            flow.inv(),
            event_info.decl.return_type != null,
        );
        if (!covered) {
            // Error already reported by checkBranchCoverageWithTerminals
            return error.IncompleteBranchCoverage;
        }
        _ = proc_event;
    }

    /// Check for duplicate branch handlers at the same level (recursively).
    /// The RULE lives in BranchChecker.firstDuplicateSibling — the single
    /// source of truth shared with FlowChecker: effect (`!`) links may repeat
    /// freely; a terminal (`|`) branch allows at most one unguarded handler
    /// per level; guards and catch-alls never count. This adapter converts
    /// siblings, reports at the offending continuation's own source location,
    /// and recurses — it NEVER returns a raw error (the reporter carries the
    /// failure; checkSourceFile fails via hasErrors → ValidationFailed).
    /// Returns true when any duplicate was reported, so the caller can
    /// short-circuit judgments that would re-describe the same defect.
    fn checkDuplicateBranchHandlers(self: *ShapeChecker, continuations: []const ast.Continuation) !bool {
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
            const cont = continuations[dup.index];
            if (dup.name.len == 0) {
                try self.reporter.addErrorAtLocation(
                    .SHAPE002,
                    cont.location,
                    branch_checker.BranchChecker.duplicate_unnamed_msg,
                    .{},
                );
            } else {
                try self.reporter.addErrorAtLocation(
                    .SHAPE002,
                    cont.location,
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
            // apply. Mirrors the flow-level transform skip.
            if (cont.is_transformed_subtree) continue;
            if (try self.checkDuplicateBranchHandlers(cont.continuations)) {
                found = true;
            }
        }

        return found;
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
            log.debug("ERROR: Jump to unknown label '{s}'\n", .{label_name});
            try self.reporter.addErrorAtLocation(
                .KORU041,
                continuation.location,
                "unknown label '@{s}'",
                .{label_name},
            );
            return error.UnknownLabel;
        };

        // Check if this is a parameterized jump
        const is_parameterized = invocation != null;

        // For pre-invocation labels (~#label pattern), we expect parameters
        if (label_info.is_pre_invocation) {
            if (!is_parameterized) {
                log.debug("ERROR: Pre-invocation label '{s}' requires parameters\n", .{label_name});
                try self.reporter.addErrorAtLocation(
                    .KORU045,
                    continuation.location,
                    "label '@{s}' requires parameters (it's a pre-invocation label)",
                    .{label_name},
                );
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
                log.debug("ERROR: Post-invocation label '{s}' does not accept parameters\n", .{label_name});
                try self.reporter.addErrorAtLocation(
                    .KORU046,
                    continuation.location,
                    "label '@{s}' does not accept parameters (it's a post-invocation label)",
                    .{label_name},
                );
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
        // (continuation is used above for location reporting)
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
                    log.debug("ERROR: Unknown label '{s}'\n", .{label_name});
                    try self.reporter.addErrorAtLocation(
                        .KORU041,
                        cont.location,
                        "unknown label '@{s}'",
                        .{label_name},
                    );
                    return error.UnknownLabel;
                }
            }
            if (step == .label_jump) {
                // New style label jump - validate it references a declared label
                const label_name = step.label_jump.label;
                if (self.labels.get(label_name) == null) {
                    log.debug("ERROR: Unknown label '{s}'\n", .{label_name});
                    try self.reporter.addErrorAtLocation(
                        .KORU041,
                        cont.location,
                        "unknown label '@{s}'",
                        .{label_name},
                    );
                    return error.UnknownLabel;
                }
            }
        }
        // Recursively process nested continuations
        for (cont.continuations) |nested| {
            try self.validateContinuationLabelJumps(&nested);
        }
    }

    /// Validate a top-level subflow impl: `~event = branch { ... }` or `~event = branch value`.
    ///
    /// The branch declaration determines the valid constructor shape:
    /// - Identity branch (`| X Type`): must be constructed with a bare value (`X v` or `X { v }`).
    ///   Reject struct-init syntax (`X { field: v }`) — it targets a field that doesn't exist.
    /// - Multi-field struct (`| X { a: A, b: B }`): must be constructed with matching fields.
    ///   Reject bare-value construction.
    /// - Void branch (`| X`): must be constructed with no payload.
    ///
    /// Note: single-field struct branches are forbidden at declaration time (parser.zig),
    /// so they do not appear here.
    /// Build the foreign airlock registry from `std/foreign:struct(Name)` decl
    /// flows. Mirrors phantom_semantic_checker.scanDeclaredTypes' foreign door
    /// and type_registry's scan, plus the field presence-claims the deref check
    /// needs. Bare-name keyed; second registrant overwrites (the duplicate wall
    /// lives in the phantom checker — this table only answers field questions).
    fn buildForeignEntries(self: *ShapeChecker, items: []const ast.Item) !void {
        var it = self.foreign_entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.fields) |f| self.allocator.free(f);
            self.allocator.free(entry.value_ptr.fields);
        }
        self.foreign_entries.clearRetainingCapacity();
        try self.scanForeignItems(items);
    }

    fn scanForeignItems(self: *ShapeChecker, items: []const ast.Item) !void {
        for (items) |item| {
            switch (item) {
                .flow => |flow| try self.scanForeignFlow(&flow),
                .inline_code => |ic| try self.scanForeignMarker(ic.code),
                .module_decl => |module| try self.scanForeignItems(module.items),
                else => {},
            }
        }
    }

    /// The self-erased form the `std/foreign:struct` transform leaves behind
    /// (`// foreign Name: f, g`). The checker runs after transforms, so this
    /// is the form it usually meets — same fixed point as list's proto marker
    /// fallback. A live decl flow (pre-erase) is handled by scanForeignFlow.
    fn scanForeignMarker(self: *ShapeChecker, code: []const u8) !void {
        const prefix = "// foreign ";
        if (!std.mem.startsWith(u8, code, prefix)) return;
        const colon = std.mem.indexOfScalar(u8, code, ':') orelse return;
        const name = std.mem.trim(u8, code[prefix.len..colon], " \t");
        if (name.len == 0) return;
        if (self.foreign_entries.contains(name)) return;
        const text = code[colon + 1 ..];
        var count: usize = 0;
        var tok1 = std.mem.tokenizeAny(u8, text, "\n,");
        while (tok1.next()) |raw| {
            const field = std.mem.trim(u8, raw, " \t\r");
            if (field.len == 0) continue;
            if (std.mem.indexOfScalar(u8, field, ':') != null) continue;
            count += 1;
        }
        const fields = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(fields);
        var w: usize = 0;
        var tok2 = std.mem.tokenizeAny(u8, text, "\n,");
        while (tok2.next()) |raw| {
            const field = std.mem.trim(u8, raw, " \t\r");
            if (field.len == 0) continue;
            if (std.mem.indexOfScalar(u8, field, ':') != null) continue;
            fields[w] = try self.allocator.dupe(u8, field);
            w += 1;
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        if (try self.foreign_entries.fetchPut(key, .{ .fields = fields[0..w] })) |old| {
            self.allocator.free(old.key);
            for (old.value.fields) |f| self.allocator.free(f);
            self.allocator.free(old.value.fields);
        }
    }

    fn scanForeignFlow(self: *ShapeChecker, flow: *const ast.Flow) !void {
        const inv = flow.inv();
        const mq = inv.path.module_qualifier orelse return;
        const is_foreign_door = std.mem.eql(u8, mq, "std.foreign") or std.mem.eql(u8, mq, "std/foreign");
        if (!is_foreign_door) return;
        if (inv.path.segments.len == 0) return;
        if (!std.mem.eql(u8, inv.path.segments[inv.path.segments.len - 1], "struct")) return;
        if (inv.args.len == 0) return;
        var name = inv.args[0].value;
        if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
        name = std.mem.trim(u8, name, " \t");
        if (name.len == 0) return;
        var src: ?[]const u8 = null;
        for (inv.args) |a| {
            if (a.source_value) |sv| {
                src = sv.text;
                break;
            }
        }
        const text = src orelse return;
        var count: usize = 0;
        var lines1 = std.mem.splitScalar(u8, text, '\n');
        while (lines1.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r,");
            if (line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, line, ':') != null) continue;
            count += 1;
        }
        const fields = try self.allocator.alloc([]const u8, count);
        errdefer self.allocator.free(fields);
        var w: usize = 0;
        var lines2 = std.mem.splitScalar(u8, text, '\n');
        while (lines2.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r,");
            if (line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, line, ':') != null) continue;
            fields[w] = try self.allocator.dupe(u8, line);
            w += 1;
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        if (try self.foreign_entries.fetchPut(key, .{ .fields = fields[0..w] })) |old| {
            self.allocator.free(old.key);
            for (old.value.fields) |f| self.allocator.free(f);
            self.allocator.free(old.value.fields);
        }
    }

    /// Refuse `binding.field` when the binding's type is a foreign entry that
    /// does not claim the field. Present fields wave through silently — host
    /// linkage (what `*File` lowers to) is the later rung, not this check.
    fn checkForeignDeref(self: *ShapeChecker, ii: *const ast.ImmediateImpl, decl: *const ast.EventDecl, plain: []const u8) !void {
        const text = std.mem.trim(u8, plain, " \t");
        const dot = std.mem.indexOfScalar(u8, text, '.') orelse return;
        if (dot == 0 or dot + 1 >= text.len) return;
        const base = std.mem.trim(u8, text[0..dot], " \t");
        if (base.len == 0) return;
        for (base) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (c >= '0' and c <= '9');
            if (!ok) return;
        }
        var rest = std.mem.trim(u8, text[dot + 1 ..], " \t");
        if (rest.len == 0) return;
        if (rest[0] == '.' or rest[rest.len - 1] == '.') return;
        const end = std.mem.indexOfAny(u8, rest, ". \t+-*/%()[]{},:;\"'") orelse rest.len;
        const field = std.mem.trim(u8, rest[0..end], " \t");
        if (field.len == 0) return;
        var binding_type: ?[]const u8 = null;
        for (decl.input.fields) |f| {
            if (std.mem.eql(u8, f.name, base)) {
                binding_type = f.type;
                break;
            }
        }
        const btype = binding_type orelse return;
        var t = std.mem.trim(u8, btype, " \t");
        while (t.len > 0 and (t[0] == '*' or t[0] == '?' or t[0] == '!')) t = std.mem.trim(u8, t[1..], " \t");
        if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
        var cut: usize = t.len;
        for (t, 0..) |c, i| {
            if (c == '<' or c == '[' or c == ' ' or c == '!' or c == '?' or c == '*') {
                cut = i;
                break;
            }
        }
        t = t[0..cut];
        if (std.mem.lastIndexOfScalar(u8, t, ':')) |ci| t = t[ci + 1 ..];
        t = std.mem.trim(u8, t, " \t");
        if (t.len == 0) return;
        const entry = self.foreign_entries.get(t) orelse return;
        for (entry.fields) |f| {
            if (std.mem.eql(u8, f, field)) return;
        }
        var list = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        defer list.deinit(self.allocator);
        for (entry.fields, 0..) |f, i| {
            if (i > 0) try list.appendSlice(self.allocator, ", ");
            try list.appendSlice(self.allocator, f);
        }
        try self.reporter.addErrorAtLocation(
            .KORU030,
            ii.location,
            "foreign entry '{s}' has no field '{s}' (fields: {s}) — a foreign deref names a registered presence claim; the host owns substance",
            .{ t, field, list.items },
        );
    }

    fn validateImmediateImplShape(
        self: *ShapeChecker,
        ii: *const ast.ImmediateImpl,
    ) !void {
        const event_path = try self.pathToString(ii.event_path);
        defer self.allocator.free(event_path);

        const event_info = self.events.get(event_path) orelse {
            // Event not found in symbol table — another pass reports this.
            return;
        };

        // Foreign rung 2: a bare-return produce of `binding.field` against a
        // foreign-typed binding is a presence-claim check at the Koru layer.
        // Present fields wave through (host linkage is the later rung);
        // unregistered fields are refused here, naming field and entry.
        if (ii.value.is_bare_return) {
            if (ii.value.plain_value) |pv| {
                try self.checkForeignDeref(ii, event_info.decl, pv);
            }
        }

        const constructor = &ii.value;

        // Find the declared branch matching the constructor name.
        var declared_branch: ?*const ast.Branch = null;
        for (event_info.decl.branches) |*br| {
            if (std.mem.eql(u8, br.name, constructor.branch_name)) {
                declared_branch = br;
                break;
            }
        }
        const branch = declared_branch orelse {
            // Unknown branch — another pass reports this.
            return;
        };

        // Wildcard payloads (bare `*`) accept any constructor shape.
        if (branch.payload.is_wildcard) return;

        // Classify declared shape.
        const decl_is_identity = branch.payload.fields.len == 1 and
            std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref");
        const decl_is_void = branch.payload.fields.len == 0;
        // Else: multi-field struct (declared with 2+ named fields).

        // Classify constructor shape.
        const ctor_has_plain_value = constructor.plain_value != null;
        const ctor_has_fields = constructor.fields.len > 0;

        if (decl_is_identity) {
            if (ctor_has_fields) {
                const decl_type = branch.payload.fields[0].type;
                try self.reporter.addErrorAtLocation(
                    .KORU030,
                    ii.location,
                    "branch '{s}' of event '{s}' is declared identity ('| {s} {s}') — construct with '{s} value', not '{s} {{ ... }}'",
                    .{ constructor.branch_name, event_path, constructor.branch_name, decl_type, constructor.branch_name, constructor.branch_name },
                );
            }
            // Bare value or empty is acceptable for identity.
        } else if (decl_is_void) {
            if (ctor_has_fields or ctor_has_plain_value) {
                try self.reporter.addErrorAtLocation(
                    .KORU030,
                    ii.location,
                    "branch '{s}' of event '{s}' is declared void — construct with just '{s}', no payload",
                    .{ constructor.branch_name, event_path, constructor.branch_name },
                );
            }
        } else {
            // Declared multi-field struct.
            if (ctor_has_plain_value) {
                try self.reporter.addErrorAtLocation(
                    .KORU030,
                    ii.location,
                    "branch '{s}' of event '{s}' has multi-field payload — construct with '{s} {{ field: value, ... }}'",
                    .{ constructor.branch_name, event_path, constructor.branch_name },
                );
            }
            // TODO: verify constructor field names match declared field names.
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
    /// Set during registration when ANY implementation kind (proc, impl flow,
    /// immediate impl) resolves to this event. KORU047 reads this instead of
    /// re-deriving registration key spellings at the invocation site.
    has_impl: bool = false,
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

const ImplFlowInfo = struct {
    flow: ?*const ast.Flow, // null for immediate impls
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

// ============================================================================
// `for` SHAPE CONTRACT (full pipeline, via checkBranchCoverageWithTerminals)
//
// `for` declares `! each *` (effect, required) and `| ?done` (terminal,
// optional). These pin the kind-aware rules end to end: KORU028 fires for a
// duplicated unguarded terminal handler, and the legal shape stays clean.
// ============================================================================

test "for shape: two unguarded done handlers - KORU028" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();

    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();

    const branches = [_]ast.Branch{
        .{ .name = "each", .payload = ast.Shape{ .fields = &[_]ast.Field{} }, .kind = .effect },
        .{ .name = "done", .payload = ast.Shape{ .fields = &[_]ast.Field{} }, .is_optional = true, .kind = .terminal },
    };

    const loc = errors.SourceLocation{ .file = "internal", .line = 0, .column = 0 };
    const continuations = [_]ast.Continuation{
        .{ .branch = "each", .binding = null, .kind = .effect, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{}, .location = loc },
        .{ .branch = "done", .binding = null, .kind = .terminal, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{}, .location = loc },
        .{ .branch = "done", .binding = null, .kind = .terminal, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{}, .location = loc },
    };

    const covered = try checker.checkBranchCoverageWithTerminals("for", &branches, &continuations, loc, null, false);
    try std.testing.expect(!covered);

    var saw_koru028 = false;
    for (reporter.errors.items) |err| {
        if (err.code == .KORU028) saw_koru028 = true;
    }
    try std.testing.expect(saw_koru028);
}

test "for shape: each plus single done - valid" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();

    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();

    const branches = [_]ast.Branch{
        .{ .name = "each", .payload = ast.Shape{ .fields = &[_]ast.Field{} }, .kind = .effect },
        .{ .name = "done", .payload = ast.Shape{ .fields = &[_]ast.Field{} }, .is_optional = true, .kind = .terminal },
    };

    const loc = errors.SourceLocation{ .file = "internal", .line = 0, .column = 0 };
    const continuations = [_]ast.Continuation{
        .{ .branch = "each", .binding = null, .kind = .effect, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{}, .location = loc },
        .{ .branch = "done", .binding = null, .kind = .terminal, .condition = null, .node = null, .indent = 0, .continuations = &[_]ast.Continuation{}, .location = loc },
    };

    const covered = try checker.checkBranchCoverageWithTerminals("for", &branches, &continuations, loc, null, false);
    try std.testing.expect(covered);
}
