const std = @import("std");
const DEBUG = true;  // Set to true for verbose logging
const ast = @import("ast");
const emitter = @import("emitter_helpers");
const visitor_mod = @import("ast_visitor");
const tap_registry_module = @import("tap_registry");
const type_registry_module = @import("type_registry");
const annotation_parser = @import("annotation_parser");

// Sentinel value for tap function context (prevents infinite recursion)
const TAP_FUNCTION_CONTEXT: usize = 9999;

/// Use EmitMode from emitter_helpers to avoid duplication
pub const EmitMode = emitter.EmitMode;

/// Visitor-based orchestrator that uses the emitter library to generate code
/// This replaces the massive procedural emitter in compiler_bootstrap.kz
pub const VisitorEmitter = struct {
    code_emitter: *emitter.CodeEmitter,
    allocator: std.mem.Allocator,
    all_items: []const ast.Item,
    flow_counter: usize,
    tap_registry: *tap_registry_module.TapRegistry,
    type_registry: *type_registry_module.TypeRegistry,
    emit_mode: EmitMode,
    emitting_from_main: bool,  // Track if we're emitting any items from main module
    main_module_name: ?[]const u8,  // Main module name for qualifying unqualified events in taps
    koru_start_flow_name: ?[]const u8,  // Name of koru:start meta-event flow (if present)
    koru_end_flow_name: ?[]const u8,    // Name of koru:end meta-event flow (if present)

    const ModuleNode = struct {
        name: []const u8,
        modules: std.ArrayList(*const ast.ModuleDecl),
        children: std.ArrayList(*ModuleNode),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, name: []const u8) !ModuleNode {
            return .{
                .name = name,
                .modules = try std.ArrayList(*const ast.ModuleDecl).initCapacity(allocator, 0),
                .children = try std.ArrayList(*ModuleNode).initCapacity(allocator, 0),
                .allocator = allocator,
            };
        }

        fn getOrCreateChild(self: *ModuleNode, allocator: std.mem.Allocator, name: []const u8) !*ModuleNode {
            for (self.children.items) |child| {
                if (std.mem.eql(u8, child.name, name)) {
                    return child;
                }
            }

            const new_node = try allocator.create(ModuleNode);
            new_node.* = try ModuleNode.init(allocator, name);
            try self.children.append(self.allocator, new_node);
            return new_node;
        }
    };

    pub fn init(allocator: std.mem.Allocator, code_emitter: *emitter.CodeEmitter, all_items: []const ast.Item, tap_registry: *tap_registry_module.TapRegistry, type_registry: *type_registry_module.TypeRegistry, emit_mode: EmitMode) VisitorEmitter {
        return .{
            .code_emitter = code_emitter,
            .allocator = allocator,
            .all_items = all_items,
            .flow_counter = 0,
            .tap_registry = tap_registry,
            .type_registry = type_registry,
            .emit_mode = emit_mode,
            .emitting_from_main = false,  // Will be set during emit()
            .main_module_name = null,  // Will be set during emit()
            .koru_start_flow_name = null,  // Will be set if koru:start flow is emitted
            .koru_end_flow_name = null,    // Will be set if koru:end flow is emitted
        };
    }


    /// Check if an item should be filtered out based on emit mode and annotations
    /// Delegates to emitter.shouldFilter to avoid code duplication
    fn shouldFilter(item_annotations: []const []const u8, module_annotations: []const []const u8, module_path: []const u8, mode: EmitMode) bool {
        return emitter.shouldFilter(item_annotations, module_annotations, module_path, mode);
    }

    /// Recursively collect all modules that should be emitted, including nested ones.
    fn collectModulesRecursively(
        self: *VisitorEmitter,
        items: []const ast.Item,
        modules: *std.ArrayList(*const ast.ModuleDecl),
    ) !void {
        // IMPORTANT: Use indexing to get stable pointers, not loop-local copies
        for (0..items.len) |idx| {
            if (items[idx] == .module_decl) {
                const module = &items[idx].module_decl;

                // Check if this module should be emitted
                const module_should_emit = !shouldFilter(&[_][]const u8{}, module.annotations, module.canonical_path, self.emit_mode);
                const has_emittable_items = moduleHasEmittableItems(module, self.emit_mode);

                if (module_should_emit or has_emittable_items) {
                    try modules.append(self.allocator, module);
                }

                // Recursively check nested modules (from imports)
                try self.collectModulesRecursively(module.items, modules);
            }
        }
    }

    /// Check if a module contains ANY items that should be emitted in the current mode.
    /// This allows modules to be emitted even if they have [comptime] annotation,
    /// as long as they contain [runtime] events/procs.
    fn moduleHasEmittableItems(module: *const ast.ModuleDecl, mode: EmitMode) bool {
        for (module.items) |item| {
            switch (item) {
                .event_decl => |event| {
                    // Check if this event should be emitted
                    if (!emitter.shouldFilter(event.annotations, module.annotations, module.canonical_path, mode)) {
                        return true;
                    }
                },
                .proc_decl => |proc| {
                    // Check if this proc should be emitted
                    if (!emitter.shouldFilter(proc.annotations, module.annotations, module.canonical_path, mode)) {
                        return true;
                    }
                },
                .flow => |flow| {
                    // Check if this flow should be emitted
                    if (!emitter.shouldFilter(flow.annotations, module.annotations, module.canonical_path, mode)) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    /// Check if we're emitting ANY items from main module (events, flows, etc.)
    /// Used to determine if host_lines from main should be emitted
    /// IMPORTANT: Only checks top-level items, NOT imported modules
    fn scanEmittingFromMain(self: *VisitorEmitter, source_file: *const ast.Program) bool {
        for (source_file.items) |item| {
            switch (item) {
                .event_decl => |event| {
                    // Check if event has comptime params (implicitly comptime)
                    var has_comptime_params = false;
                    for (event.input.fields) |field| {
                        if (field.is_source or
                            field.is_expression or
                            std.mem.eql(u8, field.type, "ProgramAST") or
                            std.mem.eql(u8, field.type, "Program")) {
                            has_comptime_params = true;
                            break;
                        }
                    }

                    // Check if this event would be emitted
                    if (!has_comptime_params) {
                        if (!shouldFilter(event.annotations, source_file.module_annotations, event.module, self.emit_mode)) {
                            return true;  // Found an emittable event!
                        }
                    } else {
                        // Event has comptime params - emitted in comptime_only mode
                        if (self.emit_mode != .runtime_only) {
                            return true;
                        }
                    }
                },
                .flow => |flow| {
                    // Check if flow invokes comptime event
                    const invokes_comptime_event = self.flowInvokesComptimeEvent(&flow, source_file.items);

                    if (invokes_comptime_event) {
                        // Comptime flows are NEVER emitted as Zig code - run_pass executes from AST
                        // Skip them in the scan (don't count as emittable items)
                        // (continue to next item)
                    } else {
                        // Normal runtime flow: apply standard filtering
                        if (!shouldFilter(&[_][]const u8{}, source_file.module_annotations, flow.module, self.emit_mode)) {
                            return true;  // Found emittable runtime flow!
                        }
                    }
                },
                .proc_decl => {
                    // Procs are tied to events - if event is emitted, proc is too
                    // So we don't need to check procs separately
                },
                .module_decl => {
                    // Skip imported modules - we only care about main module items
                    // Imported modules have their own host_line filtering logic
                },
                else => {},
            }
        }
        return false;  // No emittable items from main
    }

    /// Emit code for a Program using the visitor pattern
    pub fn emit(self: *VisitorEmitter, source_file: *const ast.Program) !void {
        // TODO: Use the visitor pattern properly with context threading
        // For now, we iterate manually to avoid the context threading complexity

        if (DEBUG) std.debug.print("\n==== VisitorEmitter.emit() START ====\n", .{});
        if (DEBUG) std.debug.print("Total items in source_file: {}\n", .{source_file.items.len});

        // Store main_module_name for use in tap canonical event naming
        self.main_module_name = source_file.main_module_name;

        // PRE-SCAN: Determine if we're emitting ANY items from main module
        // This determines whether main module host_lines should be emitted
        self.emitting_from_main = self.scanEmittingFromMain(source_file);
        if (DEBUG) std.debug.print("Emitting from main module: {}\n", .{self.emitting_from_main});

        var modules = try std.ArrayList(*const ast.ModuleDecl).initCapacity(self.allocator, 0);
        defer modules.deinit(self.allocator);

        // Collect ALL modules recursively (including nested ones from imports)
        // This is important because nested modules like std.control need to be checked too
        try self.collectModulesRecursively(source_file.items, &modules);

        // Emit main_module struct start
        try emitter.emitMainModuleStart(self.code_emitter);
        self.code_emitter.indent_level = 1;  // Set indent for main_module contents

        // Phase 1: Emit all declarations inside main_module (events, procs, flows, etc.)
        for (source_file.items) |*item| {
            try self.visitItem(item, source_file.module_annotations, source_file.items);
        }

        // Phase 1.5: Generate inline flow helper functions (still inside main_module!)
        // These are module-level functions that wrap inline flows from procs
        try self.emitInlineFlowFunctions(source_file);

        // Phase 1.6: Generate tap functions (event observers)
        // These wrap tap continuations and are called at tap injection points

        // Check tap registry for metatype usage (not AST, since taps may have been transformed)
        // These are "magical ambient types" emitted at top level when needed
        const has_base_transition = self.tap_registry.hasTransitionTaps();
        const has_profiling_transition = self.tap_registry.hasProfileTaps();
        const has_audit_transition = self.tap_registry.hasAuditTaps();
        const has_taps = self.tap_registry.entries.items.len > 0;

        // Emit TapRegistry if there are any taps (inside main_module)
        if (has_taps) {
            try emitter.emitTapRegistryPlaceholder(self.code_emitter);
        }

        // Emit ALL tap functions at main_module level (including from modules)
        // Taps are universal observers and need to be globally accessible
        var tap_counter: usize = 0;
        var ctx = emitter.EmissionContext{
            .allocator = self.allocator,
            .indent_level = 1,
            .ast_items = source_file.items,
            .is_sync = true, // Tap functions call handlers synchronously (no try/!)
            .tap_registry = self.tap_registry,
            .main_module_name = self.main_module_name,
            .emit_mode = self.emit_mode,
            .module_annotations = source_file.module_annotations,
        };
        try emitter.emitAllTaps(self.code_emitter, &ctx, source_file.items, &tap_counter);

        // Close main_module struct
        self.code_emitter.indent_level = 0;  // Reset indent before closing main_module
        try emitter.emitMainModuleEnd(self.code_emitter);

        // Emit module hierarchy as SIBLINGS to main_module
        try self.emitModuleHierarchy(modules.items, source_file.module_annotations);

        // ========================================================================
        // MODULE-LEVEL INFRASTRUCTURE (taps namespace with metatypes)
        // ========================================================================
        // Taps are compiler infrastructure, not user code, so they live at module level
        // This must come AFTER Phase 1 (where getMatchingTaps populates the registry)
        // and AFTER main_module (so we can reference events/branches)

        // Emit top-level std import for meta-event taps (Profile uses std.time.nanoTimestamp)
        // We use __koru_std to avoid shadowing std imports in modules
        if (has_profiling_transition or has_audit_transition) {
            try self.code_emitter.write("const __koru_std = @import(\"std\");\n");
        }

        // Emit taps namespace at MODULE LEVEL (compiler infrastructure)
        // Includes: EventEnum, BranchEnum, Transition, Profile, Audit metatypes
        const has_referenced_events_or_branches = if (has_taps) blk: {
            const events = try self.tap_registry.getReferencedEvents();
            defer self.tap_registry.allocator.free(events);
            const branches = try self.tap_registry.getReferencedBranches();
            defer self.tap_registry.allocator.free(branches);
            break :blk events.len > 0 or branches.len > 0;
        } else false;

        // Only emit Transition metatype if we have EventEnum/BranchEnum to reference
        const can_emit_transition = has_base_transition and has_referenced_events_or_branches;
        if (has_referenced_events_or_branches or has_base_transition or has_profiling_transition or has_audit_transition) {
            try emitter.emitTapsNamespace(self.code_emitter, self.tap_registry, can_emit_transition, has_profiling_transition, has_audit_transition);
        }

        // Phase 2: Generate main function that calls flows OR comptime_main for comptime flows
        // Runtime mode: emit main() that calls flow0(), flow1(), etc.
        // Comptime mode: emit comptime_main() that calls comptime_flow0(), comptime_flow1(), etc.
        if (self.emit_mode == .comptime_only) {
            // ========================================================================
            // COMPTIME MODE: Emit comptime_main() that calls all comptime flows
            // ========================================================================
            try self.code_emitter.write("pub fn comptime_main() void {\n");
            self.code_emitter.indent();

            // Emit calls to all comptime flows in sequence
            // IMPORTANT: Only call flows that were actually emitted (skip [norun])
            var i: usize = 0;
            for (source_file.items) |item| {
                if (item == .flow) {
                    const flow = item.flow;
                    const invokes_comptime_event = self.flowInvokesComptimeEvent(&flow, source_file.items);

                    // Only emit calls to comptime flows that are not [norun] or [transform]
                    if (invokes_comptime_event) {
                        // Check if this flow invokes a [norun] or [transform] event
                        const event_decl = self.findEventDeclInItems(self.all_items, &flow.invocation.path);
                        if (event_decl) |decl| {
                            const is_norun = annotation_parser.hasPart(decl.annotations, "norun");
                            if (is_norun) {
                                // [norun] flows are never emitted, skip calling them
                                continue;
                            }
                            const is_transform = annotation_parser.hasPart(decl.annotations, "transform");
                            if (is_transform) {
                                // [transform] flows are handled by run_pass(), skip calling them
                                continue;
                            }
                        }

                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("main_module.comptime_flow");
                        var num_buf: [32]u8 = undefined;
                        const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{i});
                        try self.code_emitter.write(num_str);
                        try self.code_emitter.write("();\n");
                        i += 1;
                    }
                }
            }

            // Close comptime_main()
            self.code_emitter.dedent();
            try self.code_emitter.write("}\n");
        } else {
            // ========================================================================
            // RUNTIME MODE: Emit main() that calls all runtime flows
            // ========================================================================
            try emitter.emitMainFunctionStart(self.code_emitter);

            // META-EVENT: koru:start and koru:end taps now in AST via tap_transformer

            // Check for user-defined main() and count flows
            // CRITICAL: Only count items that will ACTUALLY be emitted (respect filtering!)
            var has_user_main = false;
            var flow_count: usize = 0;
            for (source_file.items) |item| {
                switch (item) {
                    .host_line => |line| {
                        // Check if this line will be filtered out
                        if (shouldFilter(&[_][]const u8{}, source_file.module_annotations, line.module, self.emit_mode)) {
                            continue; // Skip filtered lines
                        }
                        // Check if this is a main function definition
                        if (line.content.len >= 11 and std.mem.eql(u8, line.content[0..11], "pub fn main")) {
                            has_user_main = true;
                        }
                    },
                    .flow => |flow| {
                        // Check if transform already ran (look for @pass_ran annotation)
                        var has_pass_ran = false;
                        for (flow.invocation.annotations) |ann| {
                            if (std.mem.startsWith(u8, ann, "@pass_ran")) {
                                has_pass_ran = true;
                                break;
                            }
                        }
                        const is_transformed = flow.inline_body != null or flow.preamble_code != null or has_pass_ran;

                        // Check if flow invokes comptime event (implicitly comptime)
                        const invokes_comptime_event = self.flowInvokesComptimeEvent(&flow, source_file.items);

                        // Apply same filtering logic as visitItem()
                        // Transformed flows bypass filtering
                        const should_skip = if (is_transformed)
                            false
                        else if (!invokes_comptime_event)
                            shouldFilter(&[_][]const u8{}, source_file.module_annotations, flow.module, self.emit_mode)
                        else
                            self.emit_mode == .runtime_only;

                        if (should_skip) {
                            continue; // Skip filtered flows
                        }

                        // Skip meta-event flows in count (they're not user flows)
                        const is_meta_event = flow.invocation.path.module_qualifier != null and
                            std.mem.eql(u8, flow.invocation.path.module_qualifier.?, "koru") and
                            flow.invocation.path.segments.len == 1 and
                            (std.mem.eql(u8, flow.invocation.path.segments[0], "start") or
                             std.mem.eql(u8, flow.invocation.path.segments[0], "end"));

                        if (!is_meta_event) {
                            flow_count += 1;
                        }
                    },
                    .native_loop => {
                        // NativeLoop IR nodes are optimized flows - count them!
                        flow_count += 1;
                    },
                    else => {},
                }
            }

            // If user defined main and no flows, delegate to main_module.main()
            if (has_user_main and flow_count == 0) {
                try self.code_emitter.write("    main_module.main();\n");
            } else {
                // Call koru:start meta-event flow if it exists (fires profiler header, etc.)
                if (self.koru_start_flow_name) |_| {
                    try self.code_emitter.write("    main_module.koru_start_flow();\n");
                }

                // Emit user flow calls
                // CRITICAL: Only emit calls to flows that were ACTUALLY emitted (respect filtering!)
                var i: usize = 0;
                for (source_file.items) |item| {
                    switch (item) {
                        .flow => |flow| {
                            // CRITICAL: Check if transform already ran (look for @pass_ran annotation)
                            var has_pass_ran = false;
                            for (flow.invocation.annotations) |ann| {
                                if (std.mem.startsWith(u8, ann, "@pass_ran")) {
                                    has_pass_ran = true;
                                    break;
                                }
                            }
                            const is_transformed = flow.inline_body != null or flow.preamble_code != null or has_pass_ran;

                            // Check if flow invokes comptime event (implicitly comptime)
                            const invokes_comptime_event = self.flowInvokesComptimeEvent(&flow, source_file.items);

                            // Apply same filtering logic as visitItem()
                            // BUT: transformed flows bypass filtering
                            const should_skip = if (is_transformed)
                                false  // Never skip transformed flows
                            else if (!invokes_comptime_event)
                                shouldFilter(&[_][]const u8{}, source_file.module_annotations, flow.module, self.emit_mode)
                            else
                                self.emit_mode == .runtime_only;

                            if (should_skip) {
                                continue; // Skip filtered flows
                            }

                            // Skip meta-event flows (they're called explicitly)
                            const is_meta_event = flow.invocation.path.module_qualifier != null and
                                std.mem.eql(u8, flow.invocation.path.module_qualifier.?, "koru") and
                                flow.invocation.path.segments.len == 1 and
                                (std.mem.eql(u8, flow.invocation.path.segments[0], "start") or
                                 std.mem.eql(u8, flow.invocation.path.segments[0], "end"));

                            if (is_meta_event) {
                                continue; // Skip - called explicitly
                            }

                            try emitter.emitFlowCallInMain(self.code_emitter, i);
                            i += 1;
                        },
                        .native_loop => {
                            // NativeLoop IR nodes are optimized flows - call them!
                            try emitter.emitFlowCallInMain(self.code_emitter, i);
                            i += 1;
                        },
                        else => {},
                    }
                }

                // Call koru:end meta-event flow if it exists (fires profiler footer, etc.)
                if (self.koru_end_flow_name) |_| {
                    try self.code_emitter.write("    main_module.koru_end_flow();\n");
                }
            }

            // META-EVENT: koru:end taps now in AST via tap_transformer

            // Close regular main()
            try emitter.emitMainFunctionEnd(self.code_emitter);
        }
    }

    fn visitItem(self: *VisitorEmitter, item: *const ast.Item, module_annotations: []const []const u8, items_to_search: []const ast.Item) !void {
        switch (item.*) {
            .event_decl => |*event| {
                // Check if this event has comptime parameters (Source/Expression/ProgramAST)
                // Events with these parameters are implicitly comptime, regardless of annotations
                var has_comptime_params = false;
                for (event.input.fields) |field| {
                    if (field.is_source or
                        field.is_expression or
                        std.mem.eql(u8, field.type, "ProgramAST") or
                        std.mem.eql(u8, field.type, "Program")) {
                        has_comptime_params = true;
                        break;
                    }
                }

                // Events with comptime params are implicitly comptime regardless of annotations
                // Filter based on emit mode
                if (!has_comptime_params) {
                    // Normal filtering based on annotations
                    if (shouldFilter(event.annotations, module_annotations, event.module, self.emit_mode)) {
                        return;
                    }
                } else {
                    // Event has comptime params - treat as implicitly comptime
                    // In runtime_only mode, skip it; in comptime_only mode, emit it
                    if (self.emit_mode == .runtime_only) {
                        return;
                    }
                }

                try self.emitEventDecl(event, items_to_search);
            },
            .host_line => |*line| {
                // Host_lines (imports, type defs, constants) are MODULE-LEVEL dependencies
                // Emit inside the appropriate module struct (module isolation)

                const is_main_module = module_annotations.len == 0;

                if (is_main_module) {
                    // Main module: emit hostlines if ANY items from main are being emitted
                    // This ensures comptime events have access to module-level constants
                    // If emitting_from_main is false, apply filtering (no main items = no hostlines needed)
                    if (!self.emitting_from_main) {
                        if (shouldFilter(&[_][]const u8{}, module_annotations, line.module, self.emit_mode)) {
                            return;
                        }
                    }
                } else {
                    // Imported module - always filter based on module annotations
                    if (shouldFilter(&[_][]const u8{}, module_annotations, line.module, self.emit_mode)) {
                        return;
                    }
                }

                try emitter.emitHostLine(self.code_emitter, line.content);
            },
            .host_type_decl => |*host_type| {
                // HostTypeDecl doesn't have module info, and they're typically user-defined
                // Skip filtering and emit directly

                // Emit: pub const {name} = struct { ... };
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("pub const ");
                try self.code_emitter.write(host_type.name);
                try self.code_emitter.write(" = struct {\n");

                self.code_emitter.indent_level += 1;

                // Emit each field
                for (host_type.shape.fields) |field| {
                    try self.code_emitter.writeIndent();
                    try self.code_emitter.write(field.name);
                    try self.code_emitter.write(": ");
                    try emitter.writeFieldType(self.code_emitter, field, self.main_module_name);
                    try self.code_emitter.write(",\n");
                }

                self.code_emitter.indent_level -= 1;
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("};\n");
            },
            .flow => |flow| {
                // Flows are emitted during Phase 1 (declarations)

                // Check if this flow invokes an event with comptime parameters OR has norun annotation
                // Flows that invoke comptime events are implicitly comptime themselves
                const invokes_comptime_event = self.flowInvokesComptimeEvent(&flow, items_to_search);

                // Special handling for [norun] and [transform] flows - these are never emitted as comptime flows
                // EXCEPTION: If the flow has inline_body OR preamble_code OR @pass_ran annotation, the transform already ran and we MUST emit it
                // Note: @pass_ran is parametrized like @pass_ran("transform"), so check for prefix
                var has_pass_ran = false;
                for (flow.invocation.annotations) |ann| {
                    if (std.mem.startsWith(u8, ann, "@pass_ran")) {
                        has_pass_ran = true;
                        break;
                    }
                }
                const is_transformed = flow.inline_body != null or flow.preamble_code != null or has_pass_ran;
                const event_decl = self.findEventDeclInItems(self.all_items, &flow.invocation.path);
                if (event_decl) |decl| {
                    const is_norun = annotation_parser.hasPart(decl.annotations, "norun");
                    if (is_norun and !is_transformed) {
                        // [norun] events are metadata - NEVER emit as Zig code in ANY mode
                        // They're in the AST and executed by the backend
                        return;
                    }
                    const is_transform = annotation_parser.hasPart(decl.annotations, "transform");
                    if (is_transform and !is_transformed) {
                        // [transform] events are handled by run_pass() - NOT emitted as comptime flows
                        // The transform handler receives invocation/program/allocator from run_pass
                        // BUT if inline_body or preamble_code is set, the transform already ran and produced code!
                        return;
                    }
                }

                if (invokes_comptime_event and !is_transformed) {
                    // This flow invokes a comptime event (marked [comptime] or with comptime params)
                    // Comptime flows: skip in runtime_only mode, emit in comptime_only mode
                    // BUT if is_transformed, the transform already ran - treat as runtime
                    if (self.emit_mode == .runtime_only) {
                        return;  // Skip comptime flows in runtime mode
                    }
                    // Fall through to emit as comptime_flowN() in .comptime_only mode
                    // Skip normal filtering - comptime flows are already filtered by mode
                } else if (!is_transformed) {
                    // Normal filtering for flows without comptime params (and not transformed)
                    if (shouldFilter(&[_][]const u8{}, module_annotations, flow.module, self.emit_mode)) {
                        return;
                    }
                }
                // If is_transformed is true, always fall through to emit the flow

                // Check if this is a meta-event flow (koru:start or koru:end)
                const is_koru_start = flow.invocation.path.module_qualifier != null and
                    std.mem.eql(u8, flow.invocation.path.module_qualifier.?, "koru") and
                    flow.invocation.path.segments.len == 1 and
                    std.mem.eql(u8, flow.invocation.path.segments[0], "start");

                const is_koru_end = flow.invocation.path.module_qualifier != null and
                    std.mem.eql(u8, flow.invocation.path.module_qualifier.?, "koru") and
                    flow.invocation.path.segments.len == 1 and
                    std.mem.eql(u8, flow.invocation.path.segments[0], "end");

                // Emit flow function with appropriate name
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("pub fn ");

                if (is_koru_start) {
                    try self.code_emitter.write("koru_start_flow");
                    self.koru_start_flow_name = "koru_start_flow";
                } else if (is_koru_end) {
                    try self.code_emitter.write("koru_end_flow");
                    self.koru_end_flow_name = "koru_end_flow";
                } else {
                    // Emit comptime_ prefix in .comptime_only mode for comptime flows
                    if (invokes_comptime_event and self.emit_mode == .comptime_only) {
                        try self.code_emitter.write("comptime_flow");
                    } else {
                        try self.code_emitter.write("flow");
                    }
                    var num_buf: [32]u8 = undefined;
                    const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{self.flow_counter});
                    try self.code_emitter.write(num_str);
                }

                try self.code_emitter.write("() void {\n");
                self.code_emitter.indent();

                // Create emission context for this flow
                var ctx = emitter.EmissionContext{
                    .allocator = self.allocator,
                    .ast_items = items_to_search,
                    .is_sync = true, // Top-level flows are synchronous
                    .tap_registry = self.tap_registry,
                    .main_module_name = self.main_module_name,
                    .emit_mode = self.emit_mode,
                    .module_annotations = module_annotations,
                };

                // Emit the flow body (invocation + continuations)
                try emitter.emitFlow(self.code_emitter, &ctx, &flow);

                self.code_emitter.dedent();
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("}\n");

                // Only increment flow_counter for non-meta-event flows
                if (!is_koru_start and !is_koru_end) {
                    self.flow_counter += 1;
                }
            },
            .proc_decl => {
                // Procs are handled inside event emission - skip here
            },
            .event_tap => {
                // Taps are handled implicitly during event emission - skip here
            },
            .module_decl => |*module| {
                _ = module;
                // Modules are emitted separately via emitModuleHierarchy()
            },
            .label_decl => {
                // Labels are handled inside flow emission - skip here
            },
            .subflow_impl => {
                // Subflows are handled inside flow emission - skip here
            },
            .import_decl => {
                // Imports are handled elsewhere - skip here
            },
            .parse_error => {
                // Skip parse_error nodes - they cannot be emitted
                // These exist for IDE tooling in interactive mode
                // Use Program.hasParseErrors() to check before compilation
            },

            // IR nodes (created by optimizer - emit as optimized code!)
            .native_loop => |*loop_ir| {
                // NativeLoop IR: Emit as a function (like Flows)
                // This is a Flow that was optimized to a native loop
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("pub fn ");
                try self.code_emitter.write("flow");
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{self.flow_counter});
                try self.code_emitter.write(num_str);
                try self.code_emitter.write("() void {\n");
                self.code_emitter.indent();

                // Emit variable declarations from original Flow
                // We need to declare accumulators and other mutable state
                if (loop_ir.optimized_from_flow) |original_flow| {
                    for (original_flow.invocation.args) |arg| {
                        // Skip loop variable (handled by for-loop)
                        if (std.mem.eql(u8, arg.name, loop_ir.variable)) continue;
                        // Skip limit (handled by end_expr)
                        if (std.mem.eql(u8, arg.name, "limit")) continue;

                        // Emit variable declaration: var {name}: u64 = {value};
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("var ");
                        try self.code_emitter.write(arg.name);
                        try self.code_emitter.write(": u64 = ");
                        try self.code_emitter.write(arg.value);
                        try self.code_emitter.write(";\n");
                    }
                }

                // Emit the optimized for loop
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("// OPTIMIZED: Native loop from IR\n");
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("for (");
                try self.code_emitter.write(loop_ir.start_expr);
                try self.code_emitter.write("..");
                try self.code_emitter.write(loop_ir.end_expr);
                try self.code_emitter.write(") |");
                try self.code_emitter.write(loop_ir.variable);
                try self.code_emitter.write("| {\n");
                self.code_emitter.indent();
                try self.code_emitter.write(loop_ir.body_code);
                self.code_emitter.dedent();
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("}\n");

                // Emit exit continuation using proper continuation emission
                if (loop_ir.optimized_from_flow) |original_flow| {
                    // Find the exit continuation (dynamically determined by optimizer)
                    for (original_flow.continuations) |*cont| {
                        if (std.mem.eql(u8, cont.branch, loop_ir.exit_branch_name)) {
                            // If the exit continuation has an empty pipeline, skip emission
                            // (the loop just exits without any continuation code)
                            if (cont.node == null) {
                                break;
                            }

                            // Create binding for done branch payload using field values from IR
                            const binding_name = cont.binding orelse "d";

                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("const ");
                            try self.code_emitter.write(binding_name);
                            try self.code_emitter.write(" = .{");

                            // Use the field values captured in the NativeLoop IR
                            for (loop_ir.done_field_values, 0..) |field_value, idx| {
                                if (idx > 0) try self.code_emitter.write(",");
                                try self.code_emitter.write(" .");
                                try self.code_emitter.write(field_value.field_name);
                                try self.code_emitter.write(" = ");
                                try self.code_emitter.write(field_value.value_expr);
                            }

                            try self.code_emitter.write(" };\n");

                            // Create emission context for the continuation
                            var ctx = emitter.EmissionContext{
                                .allocator = self.allocator,
                                .ast_items = self.all_items,
                                .is_sync = true, // NativeLoop continuations are synchronous
                                .tap_registry = self.tap_registry,
                                .main_module_name = self.main_module_name,
                                .emit_mode = self.emit_mode,
                                .module_annotations = &[_][]const u8{}, // NativeLoop has no module annotations
                            };

                            // Emit continuation body (handles pipeline steps)
                            var result_counter: usize = 0;
                            try emitter.emitContinuationBody(self.code_emitter, &ctx, cont, &result_counter);
                            break;
                        }
                    }
                }

                self.code_emitter.dedent();
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("}\n");

                self.flow_counter += 1;
            },
            .fused_event => {
                // FusedEvent IR: Will be emitted as optimized event handler
                // TODO: Implement when fusion optimizer is active
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("// TODO: FusedEvent IR node\n");
            },
            .inlined_event => {
                // InlinedEvent IR: Inlined at callsites
                // TODO: Implement when inlining optimizer is active
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("// TODO: InlinedEvent IR node\n");
            },
            .inline_code => |ic| {
                // InlineCode IR: Template-generated code emitted verbatim at call site
                // This is the foundation for zero-overhead control flow (~if, ~for)
                // The emitter is DUMB - it just outputs what transforms tell it to
                try self.code_emitter.writeIndent();
                try self.code_emitter.write(ic.code);
                try self.code_emitter.write("\n");
            },
        }
    }

    /// Emit a complete event declaration with Input, Output, and handler
    fn emitEventDecl(self: *VisitorEmitter, event: *const ast.EventDecl, all_items: []const ast.Item) !void {
        const eql = std.mem.eql;

        // Use scoped search by default (search within the module's own items)
        // This ensures test_lib.graphics:init finds the graphics module's implementation, not audio's
        const items_to_search = all_items;

        // NOTE: Filtering already done in visitItem() via shouldFilter()
        // No need to re-check compiler annotations or comptime-only here

        // Write the event struct header
        // Join all segments with underscores: ring.dequeue becomes ring_dequeue_event
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub const ");
        for (event.path.segments, 0..) |segment, idx| {
            if (idx > 0) {
                try self.code_emitter.write("_");
            }
            try self.code_emitter.write(segment);
        }
        try self.code_emitter.write("_event = struct {\n");

        // Increase indent for event contents
        self.code_emitter.indent_level += 1;

        // Input struct
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub const Input = struct {\n");
        self.code_emitter.indent_level += 1;

        for (event.input.fields) |field| {
            try self.code_emitter.writeIndent();
            try emitter.writeBranchName(self.code_emitter, field.name);
            try self.code_emitter.write(": ");
            if (field.is_file or field.is_embed_file) {
                try self.code_emitter.write("[]const u8");
            } else if (field.is_source) {
                try self.code_emitter.write("__koru_ast.Source");  // Full Source struct with .text, .scope.bindings, .phantom_type
            } else if (field.is_expression) {
                try self.code_emitter.write("[]const u8");  // Expression captured as string literal
            } else if (eql(u8, field.type, "ProgramAST") or eql(u8, field.type, "Program")) {
                try self.code_emitter.write("*const __koru_Program");
            } else {
                try emitter.writeFieldType(self.code_emitter, field, self.main_module_name);
            }
            try self.code_emitter.write(",\n");
        }

        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("};\n");

        // Output type - void for events with no branches
        try self.code_emitter.writeIndent();
        if (event.branches.len == 0) {
            try self.code_emitter.write("pub const Output = void;\n");
        } else {
            try self.code_emitter.write("pub const Output = union(enum) {\n");
            self.code_emitter.indent_level += 1;

            for (event.branches) |branch| {
                try self.code_emitter.writeIndent();
                try emitter.writeBranchName(self.code_emitter, branch.name);
                try self.code_emitter.write(": ");

                // Check if this branch uses a type reference instead of inline struct
                // Convention: single field named "__type_ref" means use the field's type directly
                if (branch.payload.fields.len == 1 and eql(u8, branch.payload.fields[0].name, "__type_ref")) {
                    // Emit just the type name, not a struct
                    try emitter.writeFieldType(self.code_emitter, branch.payload.fields[0], self.main_module_name);
                    try self.code_emitter.write(",\n");
                } else {
                    // Normal inline struct emission
                    try self.code_emitter.write("struct {\n");
                    self.code_emitter.indent_level += 1;

                    for (branch.payload.fields) |field| {
                        try self.code_emitter.writeIndent();
                        try emitter.writeBranchName(self.code_emitter, field.name);
                        try self.code_emitter.write(": ");
                        if (field.is_source) {
                            try self.code_emitter.write("__koru_ast.Source");  // Full Source struct for consistency
                        } else if (eql(u8, field.type, "ProgramAST") or eql(u8, field.type, "Program")) {
                            try self.code_emitter.write("*const __koru_Program");
                        } else {
                            try emitter.writeFieldType(self.code_emitter, field, self.main_module_name);
                        }
                        try self.code_emitter.write(",\n");
                    }

                    self.code_emitter.indent_level -= 1;
                    try self.code_emitter.writeIndent();
                    try self.code_emitter.write("},\n");
                }
            }

            self.code_emitter.indent_level -= 1;
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("};\n");
        }

        // Handler function
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub fn handler(__koru_event_input: Input) Output {\n");
        self.code_emitter.indent_level += 1;

        // Find implementation
        var found_impl = false;
        if (DEBUG) std.debug.print("  [emitEventDecl] Searching for implementation of event: ", .{});
        for (event.path.segments) |seg| {
            if (DEBUG) std.debug.print("{s}.", .{seg});
        }
        if (DEBUG) std.debug.print(" in {} items\n", .{items_to_search.len});

        for (items_to_search) |impl_item| {
            switch (impl_item) {
                .proc_decl => |proc| {
                    if (proc.path.segments.len == event.path.segments.len) {
                        var matches = true;
                        for (proc.path.segments, 0..) |seg, j| {
                            if (!eql(u8, seg, event.path.segments[j])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            // Skip non-Zig variants
                            if (proc.target) |target| {
                                if (!eql(u8, target, "zig")) {
                                    continue;
                                }
                            }

                            // Generate source marker for proc
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("// >>> PROC: ");
                            for (proc.path.segments, 0..) |seg, idx| {
                                if (idx > 0) try self.code_emitter.write(".");
                                try self.code_emitter.write(seg);
                            }
                            try self.code_emitter.write("\n");

                            // Generate implicit input bindings
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("const ");
                                try self.code_emitter.write(field.name);
                                try self.code_emitter.write(" = __koru_event_input.");
                                try self.code_emitter.write(field.name);
                                try self.code_emitter.write(";\n");
                            }
                            // Suppress unused variable warnings
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = &");
                                try self.code_emitter.write(field.name);
                                try self.code_emitter.write(";\n");
                            }

                            // Keep _ = &__koru_event_input for backwards compatibility
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("_ = &__koru_event_input;\n");

                            // Emit proc body with proper indentation
                            // Calculate indent string based on current indent_level
                            var indent_buf: [64]u8 = undefined;
                            var indent_pos: usize = 0;
                            var i: usize = 0;
                            while (i < self.code_emitter.indent_level) : (i += 1) {
                                @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                indent_pos += 4;
                            }
                            const indent_str = indent_buf[0..indent_pos];

                            try self.code_emitter.emitReindentedText(proc.body, indent_str);
                            try self.code_emitter.write("\n");
                            found_impl = true;
                            break;
                        }
                    }
                },
                .subflow_impl => |subflow| {
                    if (DEBUG) std.debug.print("    Checking subflow: ", .{});
                    for (subflow.event_path.segments) |seg| {
                        if (DEBUG) std.debug.print("{s}.", .{seg});
                    }
                    if (DEBUG) std.debug.print("\n", .{});

                    if (subflow.event_path.segments.len == event.path.segments.len) {
                        var matches = true;
                        for (subflow.event_path.segments, 0..) |seg, j| {
                            if (!eql(u8, seg, event.path.segments[j])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            if (DEBUG) std.debug.print("    ✓ FOUND MATCHING SUBFLOW!\n", .{});
                            switch (subflow.body) {
                                .immediate => |bc| {
                                    // Generate implicit input bindings for immediate subflows
                                    for (event.input.fields) |field| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const ");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(" = __koru_event_input.");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(";\n");
                                    }
                                    // Suppress unused variable warnings
                                    for (event.input.fields) |field| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(";\n");
                                    }
                                    // If no input fields, suppress unused '__koru_event_input' parameter
                                    if (event.input.fields.len == 0) {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &__koru_event_input;\n");
                                    }
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("return .{ .");
                                    try emitter.writeBranchName(self.code_emitter, bc.branch_name);
                                    try self.code_emitter.write(" = ");
                                    // Check for plain value (non-struct branch)
                                    if (bc.plain_value) |pv| {
                                        try self.code_emitter.write(pv);
                                    } else {
                                        try self.code_emitter.write(".{");
                                        for (bc.fields, 0..) |field, k| {
                                            if (k > 0) try self.code_emitter.write(", ");
                                            try self.code_emitter.write(" .");
                                            try self.code_emitter.write(field.name);
                                            try self.code_emitter.write(" = ");
                                            // Use expression_str if present (for expressions), otherwise use type
                                            const value = if (field.expression_str) |expr| expr else field.type;
                                            try self.code_emitter.write(value);
                                        }
                                        try self.code_emitter.write(" }");
                                    }
                                    try self.code_emitter.write(" };\n");
                                },
                                .flow => |flow| {
                                    // Generate implicit input bindings for consistency with procs
                                    for (event.input.fields) |field| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const ");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(" = __koru_event_input.");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(";\n");
                                    }
                                    // Suppress unused variable warnings
                                    for (event.input.fields) |field| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(";\n");
                                    }
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &__koru_event_input;\n");

                                    // Check if the flow has preamble_code (from transforms like ~for, ~if, ~capture)
                                    // This means the flow contains a ForeachNode/ConditionalNode/CaptureNode in continuations
                                    if (flow.preamble_code) |preamble| {
                                        // Emit the preamble (usually a comment like "// ~for transformed")
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write(preamble);
                                        try self.code_emitter.write("\n");

                                        // Create an emission context for continuation emission
                                        // NOTE: is_sync = true prevents "try" from being emitted (handlers don't return errors)
                                        var emitter_ctx = emitter.EmissionContext{
                                            .allocator = self.allocator,
                                            .ast_items = self.all_items,
                                            .tap_registry = self.tap_registry,
                                            .main_module_name = self.main_module_name,
                                            .current_source_event = null,
                                            .label_contexts = null,
                                            .is_sync = true,  // Handler context - no try needed
                                            .in_handler = true,
                                        };

                                        // Emit continuation bodies directly - the continuations contain the control flow node
                                        var result_counter: usize = 0;
                                        for (flow.continuations) |*cont| {
                                            try emitter.emitContinuationBody(self.code_emitter, &emitter_ctx, cont, &result_counter);
                                        }
                                    } else if (flow.inline_body) |inline_code| {
                                        // Emit the inline code directly
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("// >>> INLINE: transformed subflow\n");

                                        // Calculate indent for proper formatting
                                        var indent_buf: [64]u8 = undefined;
                                        var indent_pos: usize = 0;
                                        var idx: usize = 0;
                                        while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                            @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                            indent_pos += 4;
                                        }
                                        const indent_str = indent_buf[0..indent_pos];

                                        try self.code_emitter.emitReindentedText(inline_code, indent_str);
                                        try self.code_emitter.write("\n");
                                    } else {
                                        // Generate the invocation of the inner event
                                        try self.code_emitter.writeIndent();

                                        // Check if the invoked event has mutable branches
                                        const invoked_event = self.findEventDeclInItems(items_to_search, &flow.invocation.path);
                                        const needs_mutable = if (invoked_event) |invoked| blk: {
                                            for (invoked.branches) |branch| {
                                                for (branch.annotations) |ann| {
                                                    if (std.mem.eql(u8, ann, "mutable")) {
                                                        break :blk true;
                                                    }
                                                }
                                            }
                                            break :blk false;
                                        } else false;

                                        if (needs_mutable) {
                                            try self.code_emitter.write("var result = ");
                                        } else {
                                            try self.code_emitter.write("const result = ");
                                        }

                                        // Check if event is module-qualified
                                        if (flow.invocation.path.module_qualifier) |mq| {
                                            // Use writeModulePath to properly sanitize module references
                                            // (e.g., entry module → "main_module", "logger" → "koru_logger")
                                            try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                            try self.code_emitter.write(".");
                                        }
                                        // Join all segments with underscores
                                        for (flow.invocation.path.segments, 0..) |seg, idx| {
                                            if (idx > 0) try self.code_emitter.write("_");
                                            try self.code_emitter.write(seg);
                                        }
                                        try self.code_emitter.write("_event.handler(.{");

                                        // Write arguments, mapping from input parameters
                                        for (flow.invocation.args, 0..) |arg, k| {
                                            if (k > 0) try self.code_emitter.write(", ");
                                            try self.code_emitter.write(" .");
                                            try self.code_emitter.write(arg.name);
                                            try self.code_emitter.write(" = ");
                                            try self.code_emitter.write(arg.value);
                                        }
                                        try self.code_emitter.write(" });\n");

                                        // Generate switch on result
                                        // Calculate indent string for emitSubflowContinuations
                                        var indent_buf: [64]u8 = undefined;
                                        var indent_pos: usize = 0;
                                        var idx: usize = 0;
                                        while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                            @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                            indent_pos += 4;
                                        }
                                        const indent_str = indent_buf[0..indent_pos];

                                        // Build canonical source event name for tap emission
                                        const source_event_name = try emitter.buildCanonicalEventName(&flow.invocation.path, self.allocator, self.main_module_name);

                                        try emitter.emitSubflowContinuations(self.code_emitter, flow.continuations, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name);
                                    }
                                },
                            }
                            found_impl = true;
                            break;
                        }
                    }
                },
                .module_decl => |module| {
                    // Recursively search inside modules for implementations
                    // This is needed when all_items contains module_decl items
                    // and we need to find subflow_impl/proc_decl inside them
                    for (module.items) |module_item| {
                        switch (module_item) {
                            .proc_decl => |proc| {
                                if (proc.path.segments.len == event.path.segments.len) {
                                    var matches = true;
                                    for (proc.path.segments, 0..) |seg, j| {
                                        if (!eql(u8, seg, event.path.segments[j])) {
                                            matches = false;
                                            break;
                                        }
                                    }
                                    if (matches) {
                                        // Skip non-Zig variants
                                        if (proc.target) |target| {
                                            if (!eql(u8, target, "zig")) {
                                                continue;
                                            }
                                        }

                                        // Generate source marker for proc
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("// >>> PROC: ");
                                        for (proc.path.segments, 0..) |seg, idx| {
                                            if (idx > 0) try self.code_emitter.write(".");
                                            try self.code_emitter.write(seg);
                                        }
                                        try self.code_emitter.write("\n");

                                        // Generate implicit input bindings
                                        for (event.input.fields) |field| {
                                            try self.code_emitter.writeIndent();
                                            try self.code_emitter.write("const ");
                                            try self.code_emitter.write(field.name);
                                            try self.code_emitter.write(" = __koru_event_input.");
                                            try self.code_emitter.write(field.name);
                                            try self.code_emitter.write(";\n");
                                        }
                                        // Suppress unused variable warnings
                                        for (event.input.fields) |field| {
                                            try self.code_emitter.writeIndent();
                                            try self.code_emitter.write("_ = &");
                                            try self.code_emitter.write(field.name);
                                            try self.code_emitter.write(";\n");
                                        }

                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &__koru_event_input;\n");

                                        // Emit proc body with proper indentation
                                        var indent_buf: [64]u8 = undefined;
                                        var indent_pos: usize = 0;
                                        var i: usize = 0;
                                        while (i < self.code_emitter.indent_level) : (i += 1) {
                                            @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                            indent_pos += 4;
                                        }
                                        const indent_str = indent_buf[0..indent_pos];

                                        // Emit each line of the proc body
                                        var lines = std.mem.splitSequence(u8, proc.body, "\n");
                                        while (lines.next()) |line| {
                                            // Trim leading whitespace and re-indent
                                            const trimmed = std.mem.trimLeft(u8, line, " \t");
                                            if (trimmed.len > 0) {
                                                try self.code_emitter.write(indent_str);
                                                try self.code_emitter.write(trimmed);
                                                try self.code_emitter.write("\n");
                                            } else if (line.len > 0) {
                                                try self.code_emitter.write("\n");
                                            }
                                        }
                                        found_impl = true;
                                        break;
                                    }
                                }
                            },
                            .subflow_impl => |subflow| {
                                if (DEBUG) std.debug.print("    [module] Checking subflow: ", .{});
                                for (subflow.event_path.segments) |seg| {
                                    if (DEBUG) std.debug.print("{s}.", .{seg});
                                }
                                if (DEBUG) std.debug.print("\n", .{});

                                if (subflow.event_path.segments.len == event.path.segments.len) {
                                    var matches = true;
                                    for (subflow.event_path.segments, 0..) |seg, j| {
                                        if (!eql(u8, seg, event.path.segments[j])) {
                                            matches = false;
                                            break;
                                        }
                                    }
                                    if (matches) {
                                        if (DEBUG) std.debug.print("    [module] ✓ FOUND MATCHING SUBFLOW!\n", .{});
                                        switch (subflow.body) {
                                            .immediate => |bc| {
                                                // Generate implicit input bindings for immediate subflows
                                                for (event.input.fields) |field| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("const ");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(" = __koru_event_input.");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(";\n");
                                                }
                                                // Suppress unused variable warnings
                                                for (event.input.fields) |field| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("_ = &");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(";\n");
                                                }
                                                if (event.input.fields.len == 0) {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("_ = &__koru_event_input;\n");
                                                }
                                                try self.code_emitter.writeIndent();
                                                try self.code_emitter.write("return .{ .");
                                                try emitter.writeBranchName(self.code_emitter, bc.branch_name);
                                                try self.code_emitter.write(" = ");
                                                if (bc.plain_value) |pv| {
                                                    try self.code_emitter.write(pv);
                                                } else {
                                                    try self.code_emitter.write(".{");
                                                    for (bc.fields, 0..) |field, k| {
                                                        if (k > 0) try self.code_emitter.write(", ");
                                                        try self.code_emitter.write(" .");
                                                        try self.code_emitter.write(field.name);
                                                        try self.code_emitter.write(" = ");
                                                        const value = if (field.expression_str) |expr| expr else field.type;
                                                        try self.code_emitter.write(value);
                                                    }
                                                    try self.code_emitter.write(" }");
                                                }
                                                try self.code_emitter.write(" };\n");
                                            },
                                            .flow => |flow| {
                                                // Generate implicit input bindings
                                                for (event.input.fields) |field| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("const ");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(" = __koru_event_input.");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(";\n");
                                                }
                                                for (event.input.fields) |field| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("_ = &");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(";\n");
                                                }
                                                try self.code_emitter.writeIndent();
                                                try self.code_emitter.write("_ = &__koru_event_input;\n");

                                                // Check for preamble_code (from transforms)
                                                if (flow.preamble_code) |preamble| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write(preamble);
                                                    try self.code_emitter.write("\n");

                                                    var emitter_ctx = emitter.EmissionContext{
                                                        .allocator = self.allocator,
                                                        .ast_items = self.all_items,
                                                        .tap_registry = self.tap_registry,
                                                        .main_module_name = self.main_module_name,
                                                        .current_source_event = null,
                                                        .label_contexts = null,
                                                        .is_sync = true,
                                                        .in_handler = true,
                                                    };

                                                    var result_counter: usize = 0;
                                                    for (flow.continuations) |*cont| {
                                                        try emitter.emitContinuationBody(self.code_emitter, &emitter_ctx, cont, &result_counter);
                                                    }
                                                } else if (flow.inline_body) |inline_code| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("// >>> INLINE: transformed subflow\n");

                                                    var indent_buf: [64]u8 = undefined;
                                                    var indent_pos: usize = 0;
                                                    var idx: usize = 0;
                                                    while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                                        @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                                        indent_pos += 4;
                                                    }
                                                    const indent_str = indent_buf[0..indent_pos];

                                                    try self.code_emitter.emitReindentedText(inline_code, indent_str);
                                                    try self.code_emitter.write("\n");
                                                } else {
                                                    // Generate the invocation of the inner event
                                                    try self.code_emitter.writeIndent();

                                                    const invoked_event = self.findEventDeclInItems(items_to_search, &flow.invocation.path);
                                                    const needs_mutable = if (invoked_event) |invoked| blk: {
                                                        for (invoked.branches) |branch| {
                                                            for (branch.annotations) |ann| {
                                                                if (std.mem.eql(u8, ann, "mutable")) {
                                                                    break :blk true;
                                                                }
                                                            }
                                                        }
                                                        break :blk false;
                                                    } else false;

                                                    if (needs_mutable) {
                                                        try self.code_emitter.write("var result = ");
                                                    } else {
                                                        try self.code_emitter.write("const result = ");
                                                    }

                                                    if (flow.invocation.path.module_qualifier) |mq| {
                                                        try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                                        try self.code_emitter.write(".");
                                                    }
                                                    for (flow.invocation.path.segments, 0..) |seg, idx| {
                                                        if (idx > 0) try self.code_emitter.write("_");
                                                        try self.code_emitter.write(seg);
                                                    }
                                                    try self.code_emitter.write("_event.handler(.{");

                                                    for (flow.invocation.args, 0..) |arg, k| {
                                                        if (k > 0) try self.code_emitter.write(", ");
                                                        try self.code_emitter.write(" .");
                                                        try self.code_emitter.write(arg.name);
                                                        try self.code_emitter.write(" = ");
                                                        try self.code_emitter.write(arg.value);
                                                    }
                                                    try self.code_emitter.write(" });\n");

                                                    var indent_buf: [64]u8 = undefined;
                                                    var indent_pos: usize = 0;
                                                    var idx: usize = 0;
                                                    while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                                        @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                                        indent_pos += 4;
                                                    }
                                                    const indent_str = indent_buf[0..indent_pos];

                                                    const source_event_name = try emitter.buildCanonicalEventName(&flow.invocation.path, self.allocator, self.main_module_name);

                                                    try emitter.emitSubflowContinuations(self.code_emitter, flow.continuations, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name);
                                                }
                                            },
                                        }
                                        found_impl = true;
                                        break;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (found_impl) break;
                },
                else => {},
            }
        }

        // SPECIAL CASE: compiler.coordinate can be overridden by users at top level
        // This is the ONLY event that allows cross-module implementation
        if (!found_impl and event.path.segments.len == 2 and
            eql(u8, event.path.segments[0], "compiler") and
            eql(u8, event.path.segments[1], "coordinate")) {
            if (DEBUG) std.debug.print("  [emitEventDecl] compiler.coordinate not found in scoped search, checking top-level for user override\n", .{});

            // Search top-level items for user implementation
            for (self.all_items) |user_item| {
                if (user_item == .subflow_impl) {
                    const subflow = user_item.subflow_impl;
                    if (subflow.event_path.segments.len == 2 and
                        eql(u8, subflow.event_path.segments[0], "compiler") and
                        eql(u8, subflow.event_path.segments[1], "coordinate")) {
                        if (DEBUG) std.debug.print("    ✓ FOUND USER COORDINATOR OVERRIDE!\n", .{});
                        switch (subflow.body) {
                            .immediate => |bc| {
                                for (event.input.fields) |field| {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("const ");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(" = __koru_event_input.");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(";\n");
                                }
                                for (event.input.fields) |field| {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(";\n");
                                }
                                if (event.input.fields.len == 0) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &__koru_event_input;\n");
                                }
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("return .{ .");
                                try emitter.writeBranchName(self.code_emitter, bc.branch_name);
                                try self.code_emitter.write(" = ");
                                // Check for plain value (non-struct branch)
                                if (bc.plain_value) |pv| {
                                    try self.code_emitter.write(pv);
                                } else {
                                    try self.code_emitter.write(".{");
                                    for (bc.fields, 0..) |field, k| {
                                        if (k > 0) try self.code_emitter.write(", ");
                                        try self.code_emitter.write(" .");
                                        try self.code_emitter.write(field.name);
                                        try self.code_emitter.write(" = ");
                                        // Use expression_str if present (for expressions), otherwise use type
                                        const value = if (field.expression_str) |expr| expr else field.type;
                                        try self.code_emitter.write(value);
                                    }
                                    try self.code_emitter.write(" }");
                                }
                                try self.code_emitter.write(" };\n");
                            },
                            .flow => {
                                // Flow-based user coordinators not supported yet
                                // For now, just fall through to default implementation
                            },
                        }
                        found_impl = true;
                        break;
                    }
                }
            }
        }

        if (!found_impl) {
            // Add unused parameter suppression
            // Use & to suppress regardless of whether parameter is accessed
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &__koru_event_input;\n");

            if (event.branches.len > 0) {
                const first_branch = event.branches[0];

                // Check for identity type (single __type_ref field)
                const is_identity = first_branch.payload.fields.len == 1 and
                    eql(u8, first_branch.payload.fields[0].name, "__type_ref");

                // Return with proper field values
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("return .{ .");
                try emitter.writeBranchName(self.code_emitter, first_branch.name);
                try self.code_emitter.write(" = ");

                if (is_identity) {
                    // Identity type: emit value directly (no struct wrapper)
                    const field_type = first_branch.payload.fields[0].type;
                    if (eql(u8, field_type, "i32") or eql(u8, field_type, "i64") or
                        eql(u8, field_type, "u32") or eql(u8, field_type, "u64") or
                        eql(u8, field_type, "usize") or eql(u8, field_type, "isize")) {
                        try self.code_emitter.write("0");
                    } else if (eql(u8, field_type, "[]const u8")) {
                        try self.code_emitter.write("\"\"");
                    } else if (eql(u8, field_type, "bool")) {
                        try self.code_emitter.write("false");
                    } else {
                        try self.code_emitter.write("undefined");
                    }
                    try self.code_emitter.write(" };\n");
                } else {
                    // Struct type: emit with field names
                    try self.code_emitter.write(".{");

                    // Generate default values for each field in the branch
                    for (first_branch.payload.fields) |field| {
                        try self.code_emitter.write(" .");
                        try self.code_emitter.write(field.name);
                        try self.code_emitter.write(" = ");

                        // Generate appropriate default based on type
                        if (eql(u8, field.type, "i32")) {
                            try self.code_emitter.write("0");
                        } else if (eql(u8, field.type, "[]const u8")) {
                            try self.code_emitter.write("\"\"");
                        } else if (eql(u8, field.type, "bool")) {
                            try self.code_emitter.write("false");
                        } else {
                            try self.code_emitter.write("undefined");
                        }
                        try self.code_emitter.write(",");
                    }

                    try self.code_emitter.write("} };\n");
                }
            } else {
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("return undefined;\n");
            }
        }

        // Close handler function
        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("}\n");

        // Close the event struct
        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("};\n");
    }

    fn emitModuleHierarchy(
        self: *VisitorEmitter,
        modules: []*const ast.ModuleDecl,
        module_annotations: []const []const u8,
    ) !void {
        if (modules.len == 0) {
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();
        var root = try ModuleNode.init(arena_allocator, "");

        for (modules) |module| {
            var current = &root;
            var splitter = std.mem.splitScalar(u8, module.logical_name, '.');

            while (splitter.next()) |segment| {
                current = try current.getOrCreateChild(arena_allocator, segment);
            }

            try current.modules.append(current.allocator, module);
        }

        for (root.children.items) |child| {
            try self.emitModuleNode(child, 1, module_annotations);
        }
    }

    fn emitModuleNode(
        self: *VisitorEmitter,
        node: *ModuleNode,
        depth: usize,
        module_annotations: []const []const u8,
    ) !void {
        // Top-level modules (depth==1) are siblings to main_module, so no indent
        // Nested modules (depth>1) get indented
        if (depth > 1) {
            try self.writeIndent(depth - 1);
        }
        try self.code_emitter.write("pub const ");
        // Only prefix top-level modules (depth==1, siblings to main_module)
        if (depth == 1) {
            try self.code_emitter.write("koru_");
        }
        try self.code_emitter.write(node.name);
        try self.code_emitter.write(" = struct {\n");

        // Increase indent level for module contents
        self.code_emitter.indent_level = @intCast(depth);

        // Emit module's own imports and host lines first
        // CRITICAL: If we're emitting this module at all, emit ALL its contents
        // Don't filter individual host lines - the module itself was already filtered
        for (node.modules.items) |module| {
            for (module.items) |*module_item| {
                // Only emit host lines (including imports) at module level
                if (module_item.* == .host_line) {
                    const line = module_item.host_line;
                    // Emit ALL host lines from the module without filtering
                    // If the module shouldn't be emitted, it wouldn't be in the tree at all
                    try emitter.emitHostLine(self.code_emitter, line.content);
                }
            }
        }

        // Then emit other items (events, procs, etc)
        for (node.modules.items) |module| {
            for (module.items) |*module_item| {
                // Skip host lines - already emitted above
                if (module_item.* != .host_line) {
                    // Use the module's OWN annotations, not the top-level file's annotations
                    // This is critical for [comptime|runtime] modules like std.io
                    // CRITICAL: Pass all_items (full AST) for module-qualified event resolution (e.g., vaxis:poll)
                    // Module.items only contains the module's local items, not imported modules
                    try self.visitItem(module_item, module.annotations, self.all_items);
                }
            }
        }

        for (node.children.items) |child| {
            try self.emitModuleNode(child, depth + 1, module_annotations);
        }

        // Note: Tap functions are emitted at main_module level, not inside modules
        // (even if defined in a module file, they're universal observers)

        // Reset indent for closing brace
        // Top-level modules (depth==1) are siblings, so no indent
        if (depth > 1) {
            self.code_emitter.indent_level = @intCast(depth - 1);
            try self.code_emitter.writeIndent();
        } else {
            self.code_emitter.indent_level = 0;
        }
        try self.code_emitter.write("};\n");
    }

    fn writeIndent(self: *VisitorEmitter, depth: usize) !void {
        for (0..depth) |_| {
            try self.code_emitter.write("    ");
        }
    }

    /// Generate inline flow helper functions (fn __inline_flow_N)
    /// These wrap inline flows extracted from proc bodies
    fn emitInlineFlowFunctions(self: *VisitorEmitter, source_file: *const ast.Program) !void {
        // Inline flows reference runtime events, so only emit in runtime or all mode
        // CRITICAL: Skip emission in comptime_only mode to avoid referencing undefined runtime events
        if (self.emit_mode == .comptime_only) {
            return;
        }

        var inline_flow_counter: usize = 0;

        for (source_file.items) |item| {
            switch (item) {
                .proc_decl => |proc| {
                    if (proc.inline_flows.len > 0) {
                        // Generate helper function for each inline flow
                        for (proc.inline_flows) |inline_flow| {
                            inline_flow_counter += 1;

                            // Find the event that matches this proc's path (for input type)
                            const proc_event_name = try self.findProcEventName(&proc);
                            const event_decl = self.findEventDeclForProc(&proc);
                            const uses_args = if (event_decl) |event|
                                self.inlineFlowUsesInput(&inline_flow, event.input.fields)
                            else
                                true;
                            const param_name: []const u8 = if (uses_args) "args" else "_";

                            // Emit function signature: fn __inline_flow_N(args: EventName.Input) ReturnType
                            // Note: inside main_module, so no main_module. prefix needed
                            try self.code_emitter.write("fn __inline_flow_");
                            var counter_buf: [32]u8 = undefined;
                            const counter_str = std.fmt.bufPrint(&counter_buf, "{d}", .{inline_flow_counter}) catch unreachable;
                            try self.code_emitter.write(counter_str);
                            try self.code_emitter.write("(");
                            try self.code_emitter.write(param_name);
                            try self.code_emitter.write(": ");
                            try self.code_emitter.write(proc_event_name);
                            try self.code_emitter.write("_event.Input) ");

                            // Find the invoked event's module (for handler call)
                            const invoked_event_module = self.findEventModule(inline_flow.invocation.path.segments);
                            _ = invoked_event_module; // Not needed since emitFlow handles it

                            // Determine return type based on super_shape vs event Output:
                            // - If super_shape matches event Output: use named event Output type
                            // - Otherwise: generate anonymous union from super_shape
                            const super_shape_matches_event = if (event_decl) |event|
                                self.superShapeMatchesEventOutput(&inline_flow, event)
                            else
                                false;

                            if (super_shape_matches_event) {
                                // Use event's named Output type
                                const return_type = try self.getProcEventReturnType(&proc);
                                try self.code_emitter.write(return_type);
                            } else {
                                // Generate anonymous union from super_shape
                                try self.emitInlineFlowReturnType(&inline_flow);
                            }
                            try self.code_emitter.write(" {\n");

                            // Create emission context for the inline flow
                            var ctx = emitter.EmissionContext{
                                .allocator = self.allocator,
                                .in_handler = true,
                                .input_var = if (uses_args) "args" else null,
                                .input_fields = if (event_decl) |event| event.input.fields else null,
                                .ast_items = self.all_items,
                                .is_sync = true, // Inline flows call synchronous handlers
                                .tap_registry = self.tap_registry,
                                .main_module_name = self.main_module_name,
                                .emit_mode = self.emit_mode,
                                .module_annotations = source_file.module_annotations,
                            };

                            // Emit the flow body (invocation + continuations)
                            try emitter.emitFlow(self.code_emitter, &ctx, &inline_flow);

                            try self.code_emitter.write("}\n\n");
                        }
                    }
                },
                .module_decl => |module| {
                    // Recursively handle procs in modules
                    try self.emitInlineFlowFunctionsFromModule(&module, &inline_flow_counter);
                },
                else => {},
            }
        }
    }

    /// Helper to emit inline flows from module items
    /// Recursively processes procs in modules and their submodules
    fn emitInlineFlowFunctionsFromModule(self: *VisitorEmitter, module: *const ast.ModuleDecl, counter: *usize) !void {
        for (module.items) |item| {
            switch (item) {
                .proc_decl => |proc| {
                    if (proc.inline_flows.len > 0) {
                        // Generate helper function for each inline flow in module procs
                        for (proc.inline_flows) |inline_flow| {
                            counter.* += 1;

                            // Find the event that matches this proc's path (for input type)
                            const proc_event_name = try self.findProcEventName(&proc);
                            const event_decl = self.findEventDeclForProc(&proc);
                            const uses_args = if (event_decl) |event|
                                self.inlineFlowUsesInput(&inline_flow, event.input.fields)
                            else
                                true;
                            const param_name: []const u8 = if (uses_args) "args" else "_";

                            // Emit function signature
                            try self.code_emitter.write("fn __inline_flow_");
                            var counter_buf: [32]u8 = undefined;
                            const counter_str = std.fmt.bufPrint(&counter_buf, "{d}", .{counter.*}) catch unreachable;
                            try self.code_emitter.write(counter_str);
                            try self.code_emitter.write("(");
                            try self.code_emitter.write(param_name);
                            try self.code_emitter.write(": ");
                            try self.code_emitter.write(proc_event_name);
                            try self.code_emitter.write("_event.Input) ");

                            // Determine return type
                            const super_shape_matches_event = if (event_decl) |event|
                                self.superShapeMatchesEventOutput(&inline_flow, event)
                            else
                                false;

                            if (super_shape_matches_event) {
                                const return_type = try self.getProcEventReturnType(&proc);
                                try self.code_emitter.write(return_type);
                            } else {
                                try self.emitInlineFlowReturnType(&inline_flow);
                            }
                            try self.code_emitter.write(" {\n");

                            // Create emission context for the inline flow
                            var ctx = emitter.EmissionContext{
                                .allocator = self.allocator,
                                .in_handler = true,
                                .input_var = if (uses_args) "args" else null,
                                .input_fields = if (event_decl) |event| event.input.fields else null,
                                .ast_items = self.all_items,
                                .is_sync = true,
                                .tap_registry = self.tap_registry,
                                .main_module_name = self.main_module_name,
                                .emit_mode = self.emit_mode,
                                .module_annotations = module.annotations,
                            };

                            // Emit the flow body
                            try emitter.emitFlow(self.code_emitter, &ctx, &inline_flow);

                            try self.code_emitter.write("}\n\n");
                        }
                    }
                },
                .module_decl => |submodule| {
                    // Recursively handle nested modules
                    try self.emitInlineFlowFunctionsFromModule(&submodule, counter);
                },
                else => {},
            }
        }
    }

    /// Find the event name for a proc (e.g., "calculate" for proc calculate)
    fn findProcEventName(self: *VisitorEmitter, proc: *const ast.ProcDecl) ![]const u8 {
        _ = self;
        // For now, just use the last segment of the proc path
        return proc.path.segments[proc.path.segments.len - 1];
    }

    fn findEventDeclForProc(self: *VisitorEmitter, proc: *const ast.ProcDecl) ?*const ast.EventDecl {
        return self.findEventDeclInItems(self.all_items, &proc.path);
    }

    fn findEventDeclInItems(
        self: *VisitorEmitter,
        items: []const ast.Item,
        path: *const ast.DottedPath,
    ) ?*const ast.EventDecl {
        return self.findEventDeclInItemsWithModule(items, path, null);
    }

    fn findEventDeclInItemsWithModule(
        self: *VisitorEmitter,
        items: []const ast.Item,
        path: *const ast.DottedPath,
        current_module: ?[]const u8,
    ) ?*const ast.EventDecl {
        for (items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    if (self.pathsEqualWithModule(&event.path, path, current_module)) {
                        if (DEBUG) std.debug.print("DEBUG findEventDeclInItemsWithModule: FOUND EVENT! Annotations: {}\n", .{event.annotations.len});
                        for (event.annotations) |ann| {
                            if (DEBUG) std.debug.print("  - '{s}'\n", .{ann});
                        }
                        return event;
                    }
                },
                .module_decl => |*module| {
                    if (DEBUG) std.debug.print("DEBUG: Recursing into module '{s}'\n", .{module.logical_name});
                    // Pass the module's logical_name as context when recursing
                    if (self.findEventDeclInItemsWithModule(module.items, path, module.logical_name)) |found| {
                        if (DEBUG) std.debug.print("DEBUG findEventDeclInItemsWithModule: Returning found event from module '{s}', annotations: {}\n", .{module.logical_name, found.annotations.len});
                        return found;
                    }
                },
                else => {},
            }
        }

        return null;
    }

    fn pathsEqual(self: *VisitorEmitter, a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
        _ = self;
        const a_has_module = a.module_qualifier != null;
        const b_has_module = b.module_qualifier != null;
        if (a_has_module != b_has_module) {
            return false;
        }

        if (a_has_module) {
            const mq_a = a.module_qualifier.?;
            const mq_b = b.module_qualifier.?;
            if (!std.mem.eql(u8, mq_a, mq_b)) {
                return false;
            }
        }

        if (a.segments.len != b.segments.len) {
            return false;
        }

        for (a.segments, 0..) |segment, idx| {
            if (!std.mem.eql(u8, segment, b.segments[idx])) {
                return false;
            }
        }

        return true;
    }

    fn qualifierSuffixMatch(long: []const u8, short: []const u8) bool {
        if (long.len <= short.len) return false;
        if (!std.mem.endsWith(u8, long, short)) return false;

        const prefix_idx = long.len - short.len - 1;
        const separator = long[prefix_idx];
        return separator == '.' or separator == ':';
    }

    fn moduleQualifiersMatch(a: []const u8, b: []const u8) bool {
        if (std.mem.eql(u8, a, b)) return true;
        return qualifierSuffixMatch(a, b) or qualifierSuffixMatch(b, a);
    }

    fn pathsEqualWithModule(self: *VisitorEmitter, a: *const ast.DottedPath, b: *const ast.DottedPath, current_module: ?[]const u8) bool {
        const a_has_module = a.module_qualifier != null;
        const b_has_module = b.module_qualifier != null;

        if (DEBUG) std.debug.print("DEBUG pathsEqualWithModule:\n", .{});
        if (DEBUG) std.debug.print("  a: module={s} segments=", .{if (a.module_qualifier) |m| m else "null"});
        for (a.segments) |s| std.debug.print("{s}.", .{s});
        if (DEBUG) std.debug.print("\n  b: module={s} segments=", .{if (b.module_qualifier) |m| m else "null"});
        for (b.segments) |s| std.debug.print("{s}.", .{s});
        if (DEBUG) std.debug.print("\n  current_module={s}\n", .{if (current_module) |m| m else "null"});

        // Case 1: Both have module qualifiers - they must match
        if (a_has_module and b_has_module) {
            const mq_a = a.module_qualifier.?;
            const mq_b = b.module_qualifier.?;
            if (!moduleQualifiersMatch(mq_a, mq_b)) {
                if (DEBUG) std.debug.print("  -> MISMATCH (both have modules, don't match)\n", .{});
                return false;
            }
        }
        // Case 2: One has module qualifier, other doesn't - check if we're inside a matching module
        else if (a_has_module != b_has_module) {
            // Determine which path has the module_qualifier
            const module_qual = if (a_has_module) a.module_qualifier.? else b.module_qualifier.?;

            // Get the effective current module:
            // - If current_module is set, use it (we're inside a module_decl)
            // - If current_module is null, use main_module_name (we're in the main module)
            const effective_module = current_module orelse self.main_module_name;

            // If we can't determine the module context, paths don't match
            if (effective_module == null) {
                if (DEBUG) std.debug.print("  -> MISMATCH (one has module, can't determine context)\n", .{});
                return false;
            }

            // Check if effective module matches the module_qualifier
            if (!moduleQualifiersMatch(effective_module.?, module_qual)) {
                if (DEBUG) std.debug.print("  -> MISMATCH (effective_module '{s}' doesn't match module_qual '{s}')\n", .{effective_module.?, module_qual});
                return false;
            }

            // Module context matches! Continue to check segments
            if (DEBUG) std.debug.print("  -> Module context matches (effective='{s}', qual='{s}'), checking segments...\n", .{effective_module.?, module_qual});
        }

        // Check segments match
        if (a.segments.len != b.segments.len) {
            if (DEBUG) std.debug.print("  -> MISMATCH (segment lengths differ: {} vs {})\n", .{a.segments.len, b.segments.len});
            return false;
        }

        for (a.segments, 0..) |segment, idx| {
            if (!std.mem.eql(u8, segment, b.segments[idx])) {
                if (DEBUG) std.debug.print("  -> MISMATCH (segment {} differs: '{s}' vs '{s}')\n", .{idx, segment, b.segments[idx]});
                return false;
            }
        }

        if (DEBUG) std.debug.print("  -> MATCH! Returning TRUE\n", .{});
        return true;
    }

    /// Check if a flow invokes an event with comptime parameters (Source/ProgramAST)
    /// OR an event with ~[comptime] or ~[norun] annotations
    /// Flows that invoke comptime events are implicitly comptime themselves
    fn flowInvokesComptimeEvent(self: *VisitorEmitter, flow: *const ast.Flow, items: []const ast.Item) bool {
        _ = items; // Unused - we search in self.all_items instead

        if (DEBUG) std.debug.print("=== flowInvokesComptimeEvent DEBUG ===\n", .{});
        if (DEBUG) std.debug.print("  all_items.len = {}\n", .{self.all_items.len});

        // DEBUG: List all modules in all_items and their events
        for (self.all_items) |item| {
            if (item == .module_decl) {
                if (DEBUG) std.debug.print("  Module in all_items: '{s}' with {} items\n", .{item.module_decl.logical_name, item.module_decl.items.len});
                if (std.mem.eql(u8, item.module_decl.logical_name, "std.package")) {
                    if (DEBUG) std.debug.print("    std.package contents:\n", .{});
                    for (item.module_decl.items) |mod_item| {
                        switch (mod_item) {
                            .event_decl => |evt| {
                                if (DEBUG) std.debug.print("      Event:", .{});
                                for (evt.path.segments) |seg| {
                                    if (DEBUG) std.debug.print(" {s}", .{seg});
                                }
                                if (DEBUG) std.debug.print(" [annotations: {}]\n", .{evt.annotations.len});
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        // Build the canonical event name for registry lookup
        // Format: "module:event" or just "event" for unqualified
        var event_name_buf: [256]u8 = undefined;
        var pos: usize = 0;

        if (flow.invocation.path.module_qualifier) |mq| {
            @memcpy(event_name_buf[pos..pos + mq.len], mq);
            pos += mq.len;
            event_name_buf[pos] = ':';
            pos += 1;
        }

        for (flow.invocation.path.segments, 0..) |seg, i| {
            if (i > 0) {
                event_name_buf[pos] = '.';
                pos += 1;
            }
            @memcpy(event_name_buf[pos..pos + seg.len], seg);
            pos += seg.len;
        }

        const event_name = event_name_buf[0..pos];
        if (DEBUG) std.debug.print("  Looking for event: '{s}' in mode={s}\n", .{event_name, @tagName(self.emit_mode)});

        // CRITICAL: Check the current AST being emitted FIRST (it may have been transformed!)
        // self.all_items contains the actual AST we're emitting (potentially transformed)
        // TypeRegistry contains the ORIGINAL frontend AST before transformations
        if (DEBUG) std.debug.print("  Checking current AST for event: '{s}'\n", .{event_name});
        const event_decl = self.findEventDeclInItems(self.all_items, &flow.invocation.path);
        if (DEBUG) std.debug.print("  AST event lookup result for '{s}': {}\n", .{event_name, event_decl != null});

        if (event_decl) |decl| {
            // Found event in current AST - check its parameters and annotations directly
            if (DEBUG) std.debug.print("  Found event '{s}' in AST, module: '{s}'\n", .{event_name, decl.module});
            if (DEBUG) std.debug.print("  Event path segments:", .{});
            for (decl.path.segments) |seg| {
                if (DEBUG) std.debug.print(" {s}", .{seg});
            }
            if (DEBUG) std.debug.print("\n", .{});

            // Check if event has comptime parameters
            for (decl.input.fields) |field| {
                if (field.is_source or field.is_expression or
                    std.mem.eql(u8, field.type, "ProgramAST") or
                    std.mem.eql(u8, field.type, "Program") or
                    std.mem.eql(u8, field.type, "Expression")) {
                    if (DEBUG) std.debug.print("  Event has comptime parameter: {s}\n", .{field.name});
                    return true;
                }
            }

            // Check for comptime or norun annotations
            if (DEBUG) std.debug.print("  Event '{s}' annotations array length: {}\n", .{event_name, decl.annotations.len});
            for (decl.annotations) |ann| {
                if (DEBUG) std.debug.print("    annotation: '{s}'\n", .{ann});
            }
            const has_comptime = annotation_parser.hasPart(decl.annotations, "comptime");
            const has_norun = annotation_parser.hasPart(decl.annotations, "norun");
            if (DEBUG) std.debug.print("  has_comptime={} has_norun={}\n", .{has_comptime, has_norun});

            if (has_comptime or has_norun) {
                if (DEBUG) std.debug.print("  Returning TRUE from AST check\n", .{});
                return true;  // Event is comptime-only (should not be emitted to runtime)
            }

            // Event in AST is runtime (no Source params, no comptime annotations)
            if (DEBUG) std.debug.print("  Returning FALSE - AST event is runtime\n", .{});
            return false;
        }

        // Event not in current AST - fall back to TypeRegistry (for imported events)
        if (DEBUG) std.debug.print("  Event not in current AST, checking TypeRegistry\n", .{});
        const event_type = self.type_registry.getEventType(event_name);
        if (DEBUG) std.debug.print("  TypeRegistry lookup result: {}\n", .{event_type != null});

        if (event_type == null) {
            // FAIL LOUDLY - this should never happen for valid code
            if (DEBUG) std.debug.print("FATAL: flowInvokesComptimeEvent: Event '{s}' not found in AST or TypeRegistry\n", .{event_name});
            if (DEBUG) std.debug.print("  This means the event was invoked but never declared or imported\n", .{});
            @panic("Event not found - this is a compiler bug!");
        }

        const event = event_type.?;

        // Check if event has comptime parameters by examining input_shape
        if (event.input_shape) |shape| {
            for (shape.fields) |field| {
                if (field.is_source or field.is_expression or
                    std.mem.eql(u8, field.type, "ProgramAST") or
                    std.mem.eql(u8, field.type, "Program") or
                    std.mem.eql(u8, field.type, "Expression")) {
                    if (DEBUG) std.debug.print("  TypeRegistry event has comptime parameter\n", .{});
                    return true;
                }
            }
        }

        // TypeRegistry event doesn't have comptime parameters
        // (Note: TypeRegistry doesn't store annotations, so we can't check those)
        if (DEBUG) std.debug.print("  Returning FALSE - TypeRegistry event is runtime\n", .{});
        return false;
    }

    /// Get the return type for a proc's event (e.g., "calculate_event.Output")
    /// Note: Inline flows are emitted inside main_module, so no prefix needed
    fn getProcEventReturnType(self: *VisitorEmitter, proc: *const ast.ProcDecl) ![]const u8 {
        // Build: {proc_name}_event.Output
        // CRITICAL: Must heap-allocate because we return a slice to this buffer!
        const buf = try self.allocator.alloc(u8, 256);
        var pos: usize = 0;

        // Add proc name
        const proc_name = proc.path.segments[proc.path.segments.len - 1];
        @memcpy(buf[pos..pos + proc_name.len], proc_name);
        pos += proc_name.len;

        const suffix = "_event.Output";
        @memcpy(buf[pos..pos + suffix.len], suffix);
        pos += suffix.len;

        return buf[0..pos];
    }

    /// Check if flow's super_shape matches the event's Output branches
    /// If they match, we can use the event's named Output type instead of anonymous union
    fn superShapeMatchesEventOutput(self: *VisitorEmitter, flow: *const ast.Flow, event: *const ast.EventDecl) bool {
        _ = self;

        const super_shape = flow.super_shape orelse return false;

        // Check if branch counts match
        if (super_shape.branches.len != event.branches.len) return false;

        // Check if each branch name matches (order may differ, so check all combinations)
        for (super_shape.branches) |ss_branch| {
            var found = false;
            for (event.branches) |event_branch| {
                if (std.mem.eql(u8, ss_branch.name, event_branch.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        return true;
    }

    /// Emit inline flow return type as a union from super_shape
    /// Example: union(enum) { result: struct { doubled: i32, }, }
    /// Tagged unions allow direct field access like r1.result.doubled
    fn emitInlineFlowReturnType(self: *VisitorEmitter, flow: *const ast.Flow) !void {
        try self.code_emitter.write("union(enum) {");

        // super_shape is optional - use orelse to handle null case
        const super_shape = flow.super_shape orelse {
            // If no super_shape, emit empty union (shouldn't happen)
            try self.code_emitter.write(" }");
            return;
        };

        // Emit each branch from super_shape
        for (super_shape.branches) |branch_variant| {
            try self.code_emitter.write(" ");
            try self.code_emitter.write(branch_variant.name);
            try self.code_emitter.write(": struct {");

            // Emit fields of this branch
            for (branch_variant.payload.fields) |field| {
                try self.code_emitter.write(" ");
                try self.code_emitter.write(field.name);
                try self.code_emitter.write(": ");

                // Determine field type
                if (field.is_source) {
                    try self.code_emitter.write("[]const u8");
                } else if (std.mem.eql(u8, field.type, "auto")) {
                    // For auto types, infer as i32 (simplification)
                    try self.code_emitter.write("i32");
                } else {
                    try emitter.writeFieldType(self.code_emitter, field, self.main_module_name);
                }
                try self.code_emitter.write(",");
            }

            try self.code_emitter.write(" },");
        }

        try self.code_emitter.write(" }");
    }

    fn inlineFlowUsesInput(
        self: *VisitorEmitter,
        flow: *const ast.Flow,
        input_fields: []const ast.Field,
    ) bool {
        if (self.argsUseInput(flow.invocation.args, input_fields)) {
            return true;
        }

        return self.continuationsUseInput(flow.continuations, input_fields);
    }

    fn argsUseInput(
        self: *VisitorEmitter,
        args: []const ast.Arg,
        input_fields: []const ast.Field,
    ) bool {
        for (args) |arg| {
            if (emitter.valueReferencesInputField(arg.value, input_fields)) {
                return true;
            }
            if (self.valueUsesArgsDirectly(arg.value)) {
                return true;
            }
        }

        return false;
    }

    fn continuationsUseInput(
        self: *VisitorEmitter,
        continuations: []const ast.Continuation,
        input_fields: []const ast.Field,
    ) bool {
        for (continuations) |cont| {
            if (self.continuationUsesInput(&cont, input_fields)) {
                return true;
            }
        }

        return false;
    }

    fn continuationUsesInput(
        self: *VisitorEmitter,
        cont: *const ast.Continuation,
        input_fields: []const ast.Field,
    ) bool {
        if (cont.condition) |cond| {
            if (emitter.valueReferencesInputField(cond, input_fields) or self.valueUsesArgsDirectly(cond)) {
                return true;
            }
        }

        // Check if the single step uses input
        if (cont.node) |step| {
            const pipeline = &[_]ast.Step{step};
            if (self.pipelineUsesInput(pipeline, input_fields)) {
                return true;
            }
        }

        return self.continuationsUseInput(cont.continuations, input_fields);
    }

    fn pipelineUsesInput(
        self: *VisitorEmitter,
        pipeline: []const ast.Step,
        input_fields: []const ast.Field,
    ) bool {
        for (pipeline) |step| {
            switch (step) {
                .invocation => |inv| {
                    if (self.argsUseInput(inv.args, input_fields)) {
                        return true;
                    }
                },
                .branch_constructor => |bc| {
                    if (self.branchConstructorUsesInput(&bc, input_fields)) {
                        return true;
                    }
                },
                .deref => |deref| {
                    if (self.valueUsesArgsDirectly(deref.target) or emitter.valueReferencesInputField(deref.target, input_fields)) {
                        return true;
                    }
                    if (deref.args) |args| {
                        if (self.argsUseInput(args, input_fields)) {
                            return true;
                        }
                    }
                },
                .label_with_invocation => |lwi| {
                    if (self.argsUseInput(lwi.invocation.args, input_fields)) {
                        return true;
                    }
                },
                .label_jump => |lj| {
                    if (self.argsUseInput(lj.args, input_fields)) {
                        return true;
                    }
                },
                else => {},
            }
        }

        return false;
    }

    fn branchConstructorUsesInput(
        self: *VisitorEmitter,
        bc: *const ast.BranchConstructor,
        input_fields: []const ast.Field,
    ) bool {
        for (bc.fields) |field| {
            const value = if (field.expression_str) |expr| expr else field.type;
            if (emitter.valueReferencesInputField(value, input_fields) or self.valueUsesArgsDirectly(value)) {
                return true;
            }
        }

        return false;
    }

    fn valueUsesArgsDirectly(self: *VisitorEmitter, value: []const u8) bool {
        _ = self;
        var index: usize = 0;
        while (index < value.len) {
            const remaining = value[index..];
            const pos_opt = std.mem.indexOf(u8, remaining, "args") orelse return false;
            const start = index + pos_opt;
            const end = start + 4;

            if (start > 0) {
                const prev = value[start - 1];
                if (isIdentifierChar(prev)) {
                    index = end;
                    continue;
                }
            }

            if (end == value.len) {
                return true;
            }

            const next_char = value[end];
            if (next_char == '.' or !isIdentifierChar(next_char)) {
                return true;
            }

            index = end;
        }

        return false;
    }

    fn isIdentifierChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    /// Find which module an event is defined in
    fn findEventModule(self: *VisitorEmitter, event_path: []const []const u8) ?[]const u8 {
        return emitter.findEventModule(event_path, self.all_items);
    }

    /// Determine return type for an inline flow
    /// Returns the fully qualified output type (e.g., "main_module.add_event.Output")
    fn getInlineFlowReturnType(self: *VisitorEmitter, flow: *const ast.Flow, event_module: ?[]const u8) ![]const u8 {
        _ = self;

        // Build the return type path: main_module.[module.]event_name.Output
        var buf: [256]u8 = undefined;
        var pos: usize = 0;

        // Start with main_module
        const main_mod = "main_module.";
        @memcpy(buf[pos..pos + main_mod.len], main_mod);
        pos += main_mod.len;

        // Add module if present
        if (event_module) |module| {
            @memcpy(buf[pos..pos + module.len], module);
            pos += module.len;
            buf[pos] = '.';
            pos += 1;
        }

        // Add event name (join path segments with underscores)
        for (flow.invocation.path.segments, 0..) |segment, i| {
            if (i > 0) {
                buf[pos] = '_';
                pos += 1;
            }
            @memcpy(buf[pos..pos + segment.len], segment);
            pos += segment.len;
        }

        // Add _event.Output
        const suffix = "_event.Output";
        @memcpy(buf[pos..pos + suffix.len], suffix);
        pos += suffix.len;

        return buf[0..pos];
    }

    // TODO: Implement visitor callbacks once context threading is solved
    // For now, we use manual iteration in visitItem()
};
