const std = @import("std");
const log = @import("log");
const ast = @import("ast");
const emitter = @import("emitter_helpers");
const visitor_mod = @import("ast_visitor");
const tap_registry_module = @import("tap_registry");
const type_registry_module = @import("type_registry");
const annotation_parser = @import("annotation_parser");
const codegen_utils = @import("codegen_utils");

// Sentinel value for tap function context (prevents infinite recursion)
const TAP_FUNCTION_CONTEXT: usize = 9999;

/// Extract declared name from a host line like "const name = ..." or "pub var foo = ..."
fn extractDeclaredName(content: []const u8) ?[]const u8 {
    var s = content;
    // Skip leading whitespace
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    // Skip "pub "
    if (s.len >= 4 and std.mem.eql(u8, s[0..4], "pub ")) s = s[4..];
    // Skip whitespace after pub
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    // Check for "const " or "var "
    if (s.len >= 6 and std.mem.eql(u8, s[0..6], "const ")) {
        s = s[6..];
    } else if (s.len >= 4 and std.mem.eql(u8, s[0..4], "var ")) {
        s = s[4..];
    } else {
        return null;
    }
    // Skip whitespace
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
    // Extract identifier (alphanumeric + underscore)
    var end: usize = 0;
    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '_')) {
        end += 1;
    }
    if (end == 0) return null;
    return s[0..end];
}

/// Collect all module-level declared names from items in the same scope.
/// These are names that would cause Zig shadowing errors if used as local bindings.
fn collectDeclaredNames(items: []const ast.Item, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    for (items) |item| {
        switch (item) {
            .host_line => |hl| {
                if (extractDeclaredName(hl.content)) |name| {
                    try names.append(allocator, name);
                }
            },
            .inline_code => |ic| {
                if (extractDeclaredName(ic.code)) |name| {
                    try names.append(allocator, name);
                }
            },
            .host_type_decl => |htd| {
                try names.append(allocator, htd.name);
            },
            else => {},
        }
    }
    return names;
}

/// Check if a field name would shadow a module-level declaration
fn nameIsShadowed(name: []const u8, declared_names: []const []const u8) bool {
    for (declared_names) |dn| {
        if (std.mem.eql(u8, name, dn)) return true;
    }
    return false;
}

/// Replace word-boundary-matched identifier occurrences in text.
/// Returns a new allocated string with all occurrences of `old_name` (as a whole identifier)
/// replaced with `new_name`.
fn replaceIdentifier(allocator: std.mem.Allocator, text: []const u8, old_name: []const u8, new_name: []const u8) ![]const u8 {
    if (old_name.len == 0) return try allocator.dupe(u8, text);

    // Count replacements to calculate output size
    var count: usize = 0;
    var i: usize = 0;
    while (i + old_name.len <= text.len) {
        if (std.mem.eql(u8, text[i .. i + old_name.len], old_name)) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(text[i - 1]) and text[i - 1] != '_');
            const after_idx = i + old_name.len;
            const after_ok = (after_idx >= text.len) or (!std.ascii.isAlphanumeric(text[after_idx]) and text[after_idx] != '_');
            if (before_ok and after_ok) {
                count += 1;
                i += old_name.len;
                continue;
            }
        }
        i += 1;
    }

    if (count == 0) return try allocator.dupe(u8, text);

    // Calculate output size: original - (count * old) + (count * new)
    const new_len = text.len - (count * old_name.len) + (count * new_name.len);
    const result = try allocator.alloc(u8, new_len);

    var pos: usize = 0;
    i = 0;
    while (i < text.len) {
        if (i + old_name.len <= text.len and std.mem.eql(u8, text[i .. i + old_name.len], old_name)) {
            const before_ok = (i == 0) or (!std.ascii.isAlphanumeric(text[i - 1]) and text[i - 1] != '_');
            const after_idx = i + old_name.len;
            const after_ok = (after_idx >= text.len) or (!std.ascii.isAlphanumeric(text[after_idx]) and text[after_idx] != '_');
            if (before_ok and after_ok) {
                @memcpy(result[pos .. pos + new_name.len], new_name);
                pos += new_name.len;
                i += old_name.len;
                continue;
            }
        }
        result[pos] = text[i];
        pos += 1;
        i += 1;
    }
    return result[0..pos];
}

/// Strip phantom type annotations from a type string
/// e.g., "*Resource[state!]" -> "*Resource", "[]const u8" -> "[]const u8"
fn stripPhantom(type_str: []const u8) []const u8 {
    // Find '[' that starts phantom annotation
    for (type_str, 0..) |c, i| {
        if (c == '[') {
            // Check if this is a phantom annotation (not a slice type)
            // Slice types: []const u8, [N]T - have ] immediately or digits
            // Phantom types: *T[state], T[state!] - have identifiers
            if (i > 0 and type_str[i - 1] != ']') {
                return type_str[0..i];
            }
        }
    }
    return type_str;
}

/// Write a path segment with special chars mangled to valid Zig identifiers
/// e.g., "log" -> "log", "*" -> "_star_", "foo.bar" -> "foo_bar"
fn writeMangledSegment(code_emitter: *emitter.CodeEmitter, segment: []const u8) !void {
    var start: usize = 0;
    for (segment, 0..) |c, i| {
        if (c == '*') {
            // Write everything before the *
            if (i > start) {
                try code_emitter.write(segment[start..i]);
            }
            try code_emitter.write("_star_");
            start = i + 1;
        } else if (c == '.') {
            // Replace dots with underscores for valid Zig identifiers
            if (i > start) {
                try code_emitter.write(segment[start..i]);
            }
            try code_emitter.write("_");
            start = i + 1;
        }
    }
    // Write any remaining characters after last special char
    if (start < segment.len) {
        try code_emitter.write(segment[start..]);
    }
}

/// Emit inline statement code dedented and reindented to current emitter level.
fn emitInlineStmtDedented(code_emitter: *emitter.CodeEmitter, inline_code: []const u8) !void {
    // Build current indent string (4 spaces per level).
    var indent_buf: [64]u8 = undefined;
    var indent_pos: usize = 0;
    var idx: usize = 0;
    while (idx < code_emitter.indent_level) : (idx += 1) {
        @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
        indent_pos += 4;
    }
    const indent_str = indent_buf[0..indent_pos];

    // Find minimum indentation across non-empty lines.
    var min_indent: usize = std.math.maxInt(usize);
    var i: usize = 0;
    while (i < inline_code.len) {
        var line_end = i;
        while (line_end < inline_code.len and inline_code[line_end] != '\n') {
            line_end += 1;
        }

        var j = i;
        var count: usize = 0;
        while (j < line_end and (inline_code[j] == ' ' or inline_code[j] == '\t')) : (j += 1) {
            count += 1;
        }
        if (j < line_end) {
            if (count < min_indent) min_indent = count;
        }

        i = line_end;
        if (i < inline_code.len and inline_code[i] == '\n') i += 1;
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;

    // Emit lines with dedent + current indent.
    i = 0;
    while (i < inline_code.len) {
        var line_end = i;
        while (line_end < inline_code.len and inline_code[line_end] != '\n') {
            line_end += 1;
        }

        // Check if line has non-whitespace content.
        var has_content = false;
        var k = i;
        while (k < line_end) : (k += 1) {
            if (inline_code[k] != ' ' and inline_code[k] != '\t') {
                has_content = true;
                break;
            }
        }

        if (has_content) {
            try code_emitter.write(indent_str);
            var start = i;
            var skipped: usize = 0;
            while (start < line_end and skipped < min_indent and (inline_code[start] == ' ' or inline_code[start] == '\t')) {
                start += 1;
                skipped += 1;
            }
            try code_emitter.write(inline_code[start..line_end]);
        }

        try code_emitter.write("\n");
        i = line_end;
        if (i < inline_code.len and inline_code[i] == '\n') i += 1;
    }
}

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
    current_module_name: ?[]const u8,  // Current module being emitted (for variant registry lookups)
    current_module_prefix: ?[]const u8,  // Current Zig module path prefix (e.g., "koru_orisha")
    module_comptime_flows: std.ArrayList(ComptimeFlowCall),  // Collected comptime flow calls from modules
    koru_start_flow_name: ?[]const u8,  // Name of koru:start meta-event flow (if present)
    koru_end_flow_name: ?[]const u8,    // Name of koru:end meta-event flow (if present)

    const ComptimeFlowCall = struct {
        call_path: []const u8,
        returns_program: bool,
    };

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
            .current_module_name = null,  // Set during module emission
            .current_module_prefix = null,
            .module_comptime_flows = .empty,
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
                            std.mem.indexOf(u8, field.type, "Program") != null) {
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

    /// Result of scanning for metatypes in AST
    /// Also collects events/branches for Transition enum generation
    const MetatypeScanResult = struct {
        profile: bool = false,
        transition: bool = false,
        audit: bool = false,
        // Events and branches found in metatype_binding steps (for Transition enums)
        // Use Managed variant for simpler API (stores allocator internally)
        events: std.array_list.Managed([]const u8),
        branches: std.array_list.Managed([]const u8),

        fn init(allocator: std.mem.Allocator) MetatypeScanResult {
            return .{
                .events = std.array_list.Managed([]const u8).init(allocator),
                .branches = std.array_list.Managed([]const u8).init(allocator),
            };
        }

        fn deinit(self: *MetatypeScanResult) void {
            self.events.deinit();
            self.branches.deinit();
        }

        fn addEvent(self: *MetatypeScanResult, event: []const u8) !void {
            if (event.len == 0) return;
            // Check for duplicates
            for (self.events.items) |e| {
                if (std.mem.eql(u8, e, event)) return;
            }
            try self.events.append(event);
        }

        fn addBranch(self: *MetatypeScanResult, branch: []const u8) !void {
            // Check for duplicates (empty branches are valid - void events)
            for (self.branches.items) |b| {
                if (std.mem.eql(u8, b, branch)) return;
            }
            try self.branches.append(branch);
        }

        fn merge(self: *MetatypeScanResult, other: *const MetatypeScanResult) !void {
            if (other.profile) self.profile = true;
            if (other.transition) self.transition = true;
            if (other.audit) self.audit = true;
            for (other.events.items) |e| try self.addEvent(e);
            for (other.branches.items) |b| try self.addBranch(b);
        }
    };

    /// Scan AST items for metatype_binding steps to detect Profile/Transition/Audit metatypes
    /// Also collects events and branches for building EventEnum/BranchEnum
    /// This is needed because ~tap() transforms the AST directly without using the tap registry
    fn scanForMetatypes(items: []const ast.Item, allocator: std.mem.Allocator) !MetatypeScanResult {
        var result = MetatypeScanResult.init(allocator);
        for (items) |item| {
            switch (item) {
                .flow => |flow| {
                    var found = try scanContinuationsForMetatypes(flow.continuations, allocator);
                    defer found.deinit();
                    try result.merge(&found);
                },
                .module_decl => |mod| {
                    var nested = try scanForMetatypes(mod.items, allocator);
                    defer nested.deinit();
                    try result.merge(&nested);
                },
                // immediate_impl has no continuations to scan for metatypes.
                // Flow-based impls (impl_of != null) are already caught by .flow above.
                .immediate_impl => {},
                else => {},
            }
        }
        return result;
    }

    fn scanContinuationsForMetatypes(conts: []const ast.Continuation, allocator: std.mem.Allocator) !MetatypeScanResult {
        var result = MetatypeScanResult.init(allocator);
        for (conts) |cont| {
            if (cont.node) |step| {
                if (step == .metatype_binding) {
                    const mb = step.metatype_binding;
                    if (std.mem.eql(u8, mb.metatype, "Profile")) {
                        result.profile = true;
                    } else if (std.mem.eql(u8, mb.metatype, "Transition")) {
                        result.transition = true;
                        // Collect events and branches for Transition enum
                        try result.addEvent(mb.source_event);  // source_event is non-optional
                        if (mb.dest_event) |dst| try result.addEvent(dst);  // dest_event is optional
                        try result.addBranch(mb.branch);
                    } else if (std.mem.eql(u8, mb.metatype, "Audit")) {
                        result.audit = true;
                    }
                }
            }
            // Recurse into nested continuations
            if (cont.continuations.len > 0) {
                var found = try scanContinuationsForMetatypes(cont.continuations, allocator);
                defer found.deinit();
                try result.merge(&found);
            }
        }
        return result;
    }

    /// Emit code for a Program using the visitor pattern
    pub fn emit(self: *VisitorEmitter, source_file: *const ast.Program) !void {
        // TODO: Use the visitor pattern properly with context threading
        // For now, we iterate manually to avoid the context threading complexity

        log.debug("\n==== VisitorEmitter.emit() START ====\n", .{});
        log.debug("Total items in source_file: {}\n", .{source_file.items.len});
        if (log.level == .debug) {
            for (source_file.items, 0..) |item, idx| {
                log.debug("  [{}] Item type: {s}\n", .{idx, @tagName(item)});
                if (item == .flow) {
                    log.debug("       Flow invokes: {s}\n", .{item.flow.invocation.path.segments[0]});
                }
                if (item == .parse_error) {
                    log.debug("       PARSE ERROR MESSAGE: {s}\n", .{item.parse_error.message});
                    log.debug("       Raw text: {s}\n", .{item.parse_error.raw_text});
                }
            }
        }

        // Store main_module_name for use in tap canonical event naming
        self.main_module_name = source_file.main_module_name;

        // PRE-SCAN: Determine if we're emitting ANY items from main module
        // This determines whether main module host_lines should be emitted
        self.emitting_from_main = self.scanEmittingFromMain(source_file);
        log.debug("Emitting from main module: {}\n", .{self.emitting_from_main});

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

        // Phase 1.6: Generate tap functions (event observers)
        // These wrap tap continuations and are called at tap injection points

        // Check tap registry for metatype usage (old tap transformer)
        // AND scan AST for metatype_binding steps (new ~tap() library syntax)
        // These are "magical ambient types" emitted at top level when needed
        var ast_metatypes = try scanForMetatypes(self.all_items, self.allocator);
        defer ast_metatypes.deinit();
        const has_base_transition = self.tap_registry.hasTransitionTaps() or ast_metatypes.transition;
        const has_profiling_transition = self.tap_registry.hasProfileTaps() or ast_metatypes.profile;
        const has_audit_transition = self.tap_registry.hasAuditTaps() or ast_metatypes.audit;
        const has_taps = self.tap_registry.entries.items.len > 0;
        // AST-collected events/branches from metatype_binding steps (for ~tap() library syntax)
        const has_ast_events_or_branches = ast_metatypes.events.items.len > 0 or ast_metatypes.branches.items.len > 0;

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
            .ast_items = self.all_items,  // Full AST for event declaration lookup
            .is_sync = true, // Tap functions call handlers synchronously (no try/!)
            .tap_registry = self.tap_registry,
            .type_registry = self.type_registry,
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
        const has_registry_events_or_branches = if (has_taps) blk: {
            const events = try self.tap_registry.getReferencedEvents();
            defer self.tap_registry.allocator.free(events);
            const branches = try self.tap_registry.getReferencedBranches();
            defer self.tap_registry.allocator.free(branches);
            break :blk events.len > 0 or branches.len > 0;
        } else false;

        // Events/branches can come from tap_registry (old style) OR AST metatype_binding (new ~tap() style)
        const has_referenced_events_or_branches = has_registry_events_or_branches or has_ast_events_or_branches;

        // Only emit Transition metatype if we have EventEnum/BranchEnum to reference
        const can_emit_transition = has_base_transition and has_referenced_events_or_branches;
        if (has_referenced_events_or_branches or has_base_transition or has_profiling_transition or has_audit_transition) {
            try emitter.emitTapsNamespace(self.code_emitter, self.tap_registry, can_emit_transition, has_profiling_transition, has_audit_transition, ast_metatypes.events.items, ast_metatypes.branches.items);
        }

        // Phase 2: Generate main function that calls flows OR comptime_main for comptime flows
        // Runtime mode: emit main() that calls flow0(), flow1(), etc.
        // Comptime mode: emit comptime_main() that calls comptime_flow0(), comptime_flow1(), etc.
        if (self.emit_mode == .comptime_only) {
            // ========================================================================
            // COMPTIME MODE: Emit comptime_main() that calls all comptime flows
            // Returns *const Program — comptime flows may modify the AST
            // ========================================================================
            try self.code_emitter.write("pub fn comptime_main(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) *const __koru_ast.Program {\n");
            self.code_emitter.indent();

            // Thread program through comptime flows (program-returning flows update it)
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("var current_program = program;\n");
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &current_program;\n");
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &allocator;\n");

            // Emit calls to all comptime flows in sequence
            // IMPORTANT: Only call flows that were actually emitted (skip [norun])
            var i: usize = 0;
            for (source_file.items) |item| {
                if (item == .flow) {
                    const flow = item.flow;
                    // Impl flows are handled by the abstract event handler, not as standalone
                    if (flow.impl_of != null) continue;
                    const invokes_comptime_event = self.flowInvokesComptimeEvent(&flow, source_file.items);

                    // Only emit calls to comptime flows that are not [norun] or [transform]
                    if (invokes_comptime_event) {
                        // Check if this flow invokes a [norun] or [transform] event
                        const event_decl = self.findEventDeclInItems(self.all_items, &flow.invocation.path);
                        var flow_returns_program = false;
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
                            // Check if event returns a program
                            for (decl.branches) |branch| {
                                for (branch.payload.fields) |field| {
                                    if (std.mem.eql(u8, field.name, "program")) {
                                        flow_returns_program = true;
                                        break;
                                    }
                                }
                                if (flow_returns_program) break;
                            }
                        }

                        try self.code_emitter.writeIndent();
                        if (flow_returns_program) {
                            // Thread program through: capture return value
                            try self.code_emitter.write("current_program = main_module.comptime_flow");
                        } else {
                            try self.code_emitter.write("main_module.comptime_flow");
                        }
                        var num_buf: [32]u8 = undefined;
                        const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{i});
                        try self.code_emitter.write(num_str);
                        if (flow_returns_program) {
                            try self.code_emitter.write("(current_program, allocator);\n");
                        } else {
                            try self.code_emitter.write("(current_program, allocator);\n");
                        }
                        i += 1;
                    }
                }
            }

            // Also call comptime flows from imported modules
            for (self.module_comptime_flows.items) |flow_info| {
                try self.code_emitter.writeIndent();
                if (flow_info.returns_program) {
                    try self.code_emitter.write("current_program = ");
                }
                try self.code_emitter.write(flow_info.call_path);
                try self.code_emitter.write("(current_program, allocator);\n");
            }

            // Return the (potentially modified) program
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("return current_program;\n");

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
                        // Impl flows are handled by the abstract event handler, not counted
                        if (flow.impl_of != null) continue;

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
                            // Impl flows are handled by the abstract event handler, not called standalone
                            if (flow.impl_of != null) continue;

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

            // Test discovery block - enables zig test to find tests nested in main_module
            try self.code_emitter.write("\ntest {\n    @import(\"std\").testing.refAllDeclsRecursive(@This());\n}\n");
        }
    }

    fn visitItem(self: *VisitorEmitter, item: *const ast.Item, module_annotations: []const []const u8, items_to_search: []const ast.Item) !void {
        switch (item.*) {
            .event_decl => |*event| {
                // Check if this event has comptime parameters (Source/Expression/Program)
                // Events with these parameters are implicitly comptime, regardless of annotations
                var has_comptime_params = false;
                for (event.input.fields) |field| {
                    if (field.is_source or
                        field.is_expression or
                        std.mem.indexOf(u8, field.type, "Program") != null) {
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
                // Flows with impl_of are implementation overrides — they're emitted
                // inside the abstract event handler, not as standalone functions.
                if (flow.impl_of != null) return;

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

                // Detect if this comptime event returns a program (for comptime program return)
                var comptime_returns_program = false;
                var comptime_program_branch: []const u8 = "";
                if (invokes_comptime_event and self.emit_mode == .comptime_only) {
                    const ct_event_decl = self.findEventDeclInItems(self.all_items, &flow.invocation.path);
                    if (ct_event_decl) |ct_decl| {
                        for (ct_decl.branches) |branch| {
                            for (branch.payload.fields) |field| {
                                if (std.mem.eql(u8, field.name, "program")) {
                                    comptime_returns_program = true;
                                    comptime_program_branch = branch.name;
                                    break;
                                }
                            }
                            if (comptime_returns_program) break;
                        }
                    }
                }

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
                        // Record module comptime flows for comptime_main generation
                        if (self.current_module_prefix) |mod_prefix| {
                            var call_buf: std.ArrayList(u8) = .empty;
                            try call_buf.appendSlice(self.allocator, mod_prefix);
                            try call_buf.appendSlice(self.allocator, ".comptime_flow");
                            var flow_num_buf: [32]u8 = undefined;
                            const flow_num_str = try std.fmt.bufPrint(&flow_num_buf, "{}", .{self.flow_counter});
                            try call_buf.appendSlice(self.allocator, flow_num_str);
                            const call_str = try call_buf.toOwnedSlice(self.allocator);
                            try self.module_comptime_flows.append(self.allocator, .{
                                .call_path = call_str,
                                .returns_program = comptime_returns_program,
                            });
                        }
                    } else {
                        try self.code_emitter.write("flow");
                    }
                    var num_buf: [32]u8 = undefined;
                    const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{self.flow_counter});
                    try self.code_emitter.write(num_str);
                }

                // Comptime flows receive program and allocator for AST introspection
                if (invokes_comptime_event and self.emit_mode == .comptime_only) {
                    if (comptime_returns_program) {
                        try self.code_emitter.write("(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) *const __koru_ast.Program {\n");
                    } else {
                        try self.code_emitter.write("(program: *const __koru_ast.Program, allocator: __koru_std.mem.Allocator) void {\n");
                    }
                } else {
                    try self.code_emitter.write("() void {\n");
                }
                self.code_emitter.indent();

                // Suppress unused parameter warnings for comptime flows (using & works whether used or not)
                if (invokes_comptime_event and self.emit_mode == .comptime_only) {
                    try self.code_emitter.writeIndent();
                    try self.code_emitter.write("_ = &program;\n");
                    try self.code_emitter.writeIndent();
                    try self.code_emitter.write("_ = &allocator;\n");
                }

                // Create emission context for this flow
                // NOTE: ast_items uses all_items (full AST) for event declaration lookup (needed for loops)
                // while items_to_search is used for scoped implementation search
                var ctx = emitter.EmissionContext{
                    .allocator = self.allocator,
                    .ast_items = self.all_items,
                    .is_sync = true, // Top-level flows are synchronous
                    .tap_registry = self.tap_registry,
                    .type_registry = self.type_registry,
                    .main_module_name = self.main_module_name,
                    .emit_mode = self.emit_mode,
                    .module_annotations = module_annotations,
                    // For program-returning comptime flows with no continuations,
                    // capture result in a named variable instead of discarding
                    .comptime_result_binding = if (comptime_returns_program) "result_0" else null,
                };

                // Emit the flow body (invocation + continuations)
                try emitter.emitFlow(self.code_emitter, &ctx, &flow);

                // Comptime program return: extract program from handler result
                if (comptime_returns_program and comptime_program_branch.len > 0) {
                    try self.code_emitter.writeIndent();
                    try self.code_emitter.write("return result_0.");
                    try self.code_emitter.write(comptime_program_branch);
                    try self.code_emitter.write(".program;\n");
                }

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
            .immediate_impl => {
                // Immediate impls are handled inside event emission - skip here
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
                                .type_registry = self.type_registry,
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
        // Glob patterns (e.g., log.*) get mangled: log.* becomes log__star__event
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub const ");
        for (event.path.segments, 0..) |segment, idx| {
            if (idx > 0) {
                try self.code_emitter.write("_");
            }
            // Mangle glob wildcards: * -> _star_
            try writeMangledSegment(self.code_emitter, segment);
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
            } else if (eql(u8, field.type, "Program")) {
                try self.code_emitter.write("*const __koru_ast.Program");
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
                        } else if (eql(u8, field.type, "Program")) {
                            try self.code_emitter.write("*const __koru_ast.Program");
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

        // For abstract events, check if there's a cross-module override.
        // Flow-based impls: .flow with impl_of != null and isImpl() (cross-module)
        // Immediate impls: .immediate_impl with isImpl() (cross-module)
        var has_impl_override = false;
        if (event.hasAnnotation("abstract")) {
            // First check module-local items
            for (items_to_search) |item| {
                switch (item) {
                    .flow => |flow| {
                        if (flow.impl_of) |impl_path| {
                            if (flow.isImpl() and impl_path.segments.len == event.path.segments.len) {
                                var path_matches = true;
                                for (impl_path.segments, 0..) |seg, j| {
                                    if (!eql(u8, seg, event.path.segments[j])) {
                                        path_matches = false;
                                        break;
                                    }
                                }
                                if (path_matches) {
                                    has_impl_override = true;
                                    break;
                                }
                            }
                        }
                    },
                    .immediate_impl => |ii| {
                        if (ii.isImpl() and ii.event_path.segments.len == event.path.segments.len) {
                            var path_matches = true;
                            for (ii.event_path.segments, 0..) |seg, j| {
                                if (!eql(u8, seg, event.path.segments[j])) {
                                    path_matches = false;
                                    break;
                                }
                            }
                            if (path_matches) {
                                has_impl_override = true;
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }
            // ALSO check top-level items for cross-module impls
            // Cross-module: flow.module != flow.impl_of.module_qualifier (or ii.module != ii.event_path.module_qualifier)
            if (!has_impl_override) {
                if (event.path.module_qualifier) |event_module| {
                    for (self.all_items) |top_item| {
                        switch (top_item) {
                            .flow => |flow| {
                                if (flow.impl_of) |impl_path| {
                                    // Cross-module check: where it's defined != what it targets
                                    const is_cross_module = if (impl_path.module_qualifier) |impl_mq|
                                        !eql(u8, flow.module, impl_mq)
                                    else
                                        false;
                                    if (flow.isImpl() or is_cross_module) {
                                        if (impl_path.module_qualifier) |impl_module| {
                                            if (eql(u8, impl_module, event_module) and
                                                impl_path.segments.len == event.path.segments.len)
                                            {
                                                var path_matches = true;
                                                for (impl_path.segments, 0..) |seg, j| {
                                                    if (!eql(u8, seg, event.path.segments[j])) {
                                                        path_matches = false;
                                                        break;
                                                    }
                                                }
                                                if (path_matches) {
                                                    has_impl_override = true;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            .immediate_impl => |ii| {
                                // Cross-module check for immediate impls
                                const is_cross_module = if (ii.event_path.module_qualifier) |ii_mq|
                                    !eql(u8, ii.module, ii_mq)
                                else
                                    false;
                                if (ii.isImpl() or is_cross_module) {
                                    if (ii.event_path.module_qualifier) |ii_module| {
                                        if (eql(u8, ii_module, event_module) and
                                            ii.event_path.segments.len == event.path.segments.len)
                                        {
                                            var path_matches = true;
                                            for (ii.event_path.segments, 0..) |seg, j| {
                                                if (!eql(u8, seg, event.path.segments[j])) {
                                                    path_matches = false;
                                                    break;
                                                }
                                            }
                                            if (path_matches) {
                                                has_impl_override = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                }
            }
        }

        // For abstract events with impl override, first emit the default as _default_handler
        // This allows the impl to delegate to it (emitted BEFORE the main handler)
        // The default can be either a proc_decl (Zig body) or a flow with impl_of (non-cross-module flow body)
        if (has_impl_override) {
            var emitted_default_handler = false;

            // First try to find a proc_decl (Zig body default)
            // After resolve_abstract_impl, the default proc's path is renamed to <event>.default
            for (items_to_search) |item| {
                if (item == .proc_decl) {
                    const proc = item.proc_decl;
                    if (proc.path.segments.len == event.path.segments.len) {
                        var path_matches = true;
                        for (proc.path.segments, 0..) |seg, j| {
                            const event_seg = event.path.segments[j];
                            // Check if proc segment matches event segment OR event segment + ".default"
                            if (!eql(u8, seg, event_seg)) {
                                // Try matching with .default suffix
                                if (seg.len == event_seg.len + 8 and
                                    std.mem.startsWith(u8, seg, event_seg) and
                                    std.mem.endsWith(u8, seg, ".default"))
                                {
                                    // Matches with .default suffix
                                } else {
                                    path_matches = false;
                                    break;
                                }
                            }
                        }
                        if (path_matches) {
                            if (proc.target) |target| {
                                if (!eql(u8, target, "zig")) continue;
                            }
                            // Emit the proc as _default_handler (before handler function)
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("fn _default_handler(__koru_event_input: Input) Output {\n");
                            self.code_emitter.indent_level += 1;

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

                            var indent_buf: [64]u8 = undefined;
                            var indent_pos: usize = 0;
                            var idx: usize = 0;
                            while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                indent_pos += 4;
                            }
                            const indent_str = indent_buf[0..indent_pos];

                            try self.code_emitter.emitReindentedText(proc.body, indent_str);
                            try self.code_emitter.write("\n");

                            self.code_emitter.indent_level -= 1;
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("}\n");
                            emitted_default_handler = true;
                            break;
                        }
                    }
                }
            }

            // If no proc found, look for a non-impl flow with impl_of (flow-based default)
            // This handles cases like ~coordinate = context_create(...) | ... (flow-based default)
            // After resolve_abstract_impl, the default flow's impl_of path is renamed to <event>.default
            if (!emitted_default_handler) {
                for (items_to_search) |item| {
                    if (item == .flow) {
                        const flow = item.flow;
                        if (flow.impl_of) |impl_path| {
                            // Only consider non-cross-module flows (default implementations, not overrides)
                            if (!flow.isImpl() and impl_path.segments.len == event.path.segments.len) {
                                var path_matches = true;
                                for (impl_path.segments, 0..) |seg, j| {
                                    const event_seg = event.path.segments[j];
                                    // Check if flow segment matches event segment OR event segment + ".default"
                                    if (!eql(u8, seg, event_seg)) {
                                        // Try matching with .default suffix
                                        if (seg.len == event_seg.len + 8 and
                                            std.mem.startsWith(u8, seg, event_seg) and
                                            std.mem.endsWith(u8, seg, ".default"))
                                        {
                                            // Matches with .default suffix
                                        } else {
                                            path_matches = false;
                                            break;
                                        }
                                    }
                                }
                                if (path_matches) {
                                    // Emit the flow as _default_handler
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("fn _default_handler(__koru_event_input: Input) Output {\n");
                                    self.code_emitter.indent_level += 1;

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

                                    // Generate the flow invocation and continuations
                                    if (flow.inline_body) |inline_code_raw| {
                                        // Transform set inline_body -- emit inline instead of handler call
                                        const inline_stmt_marker = "//@koru:inline_stmt\n";
                                        var inline_code = inline_code_raw;
                                        var is_inline_stmt = false;
                                        if (std.mem.indexOf(u8, inline_code, inline_stmt_marker)) |marker_idx| {
                                            is_inline_stmt = true;
                                            inline_code = inline_code[marker_idx + inline_stmt_marker.len..];
                                        }

                                        if (is_inline_stmt) {
                                            const has_named_branches = blk: {
                                                for (flow.continuations) |cont| {
                                                    if (cont.branch.len > 0) break :blk true;
                                                }
                                                break :blk false;
                                            };
                                            if (has_named_branches) {
                                                try self.code_emitter.writeIndent();
                                                try self.code_emitter.write("@compileError(\"inline_stmt cannot be used with named continuations\");\n");
                                            } else {
                                                try emitInlineStmtDedented(self.code_emitter, inline_code);
                                            }
                                        } else {
                                            try self.code_emitter.writeIndent();
                                            try self.code_emitter.write("const result = ");

                                            // If inline code uses __KORU_INLINE__ placeholder,
                                            // wrap in a labeled block and replace the placeholder.
                                            const placeholder = "__KORU_INLINE__";
                                            if (std.mem.indexOf(u8, inline_code, placeholder) != null) {
                                                try self.code_emitter.write("__koru_inline__: ");
                                                // Replace all occurrences of placeholder with label
                                                var scan_pos: usize = 0;
                                                while (scan_pos < inline_code.len) {
                                                    if (scan_pos + placeholder.len <= inline_code.len and
                                                        std.mem.eql(u8, inline_code[scan_pos .. scan_pos + placeholder.len], placeholder))
                                                    {
                                                        try self.code_emitter.write("__koru_inline__");
                                                        scan_pos += placeholder.len;
                                                    } else {
                                                        try self.code_emitter.write(inline_code[scan_pos .. scan_pos + 1]);
                                                        scan_pos += 1;
                                                    }
                                                }
                                            } else {
                                                try self.code_emitter.write(inline_code);
                                            }
                                            try self.code_emitter.write(";\n");
                                        }
                                    } else {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const result = ");

                                        // Emit the event call
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
                                    }

                                    // Emit continuations
                                    var indent_buf: [64]u8 = undefined;
                                    var indent_pos: usize = 0;
                                    var idx: usize = 0;
                                    while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                        @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                        indent_pos += 4;
                                    }
                                    const indent_str = indent_buf[0..indent_pos];

                                    const source_event_name = try emitter.buildCanonicalEventName(&flow.invocation.path, self.allocator, self.main_module_name);
                                    try emitter.emitSubflowContinuations(self.code_emitter, flow.continuations, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "koru_std.compiler");

                                    self.code_emitter.indent_level -= 1;
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("}\n");
                                    emitted_default_handler = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Handler function
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub fn handler(__koru_event_input: Input) Output {\n");
        self.code_emitter.indent_level += 1;

        // Find implementation
        var found_impl = false;
        log.debug("  [emitEventDecl] Searching for implementation of event: ", .{});
        for (event.path.segments) |seg| {
            log.debug("{s}.", .{seg});
        }
        log.debug(" in {} items\n", .{items_to_search.len});

        // FIRST: Check top-level items for cross-module overrides (e.g., ~std.compiler:coordinate = ...)
        // This ensures user-defined overrides take precedence over module-internal implementations
        // Flow-based impls: .flow with impl_of != null
        // Immediate impls: .immediate_impl
        if (has_impl_override) {
            if (event.path.module_qualifier) |event_module| {
                for (self.all_items) |top_item| {
                    switch (top_item) {
                        .immediate_impl => |ii| {
                            // Cross-module check for immediate impls
                            const is_cross_module = if (ii.event_path.module_qualifier) |ii_mq|
                                !eql(u8, ii.module, ii_mq)
                            else
                                false;
                            if (is_cross_module or ii.isImpl()) {
                                if (ii.event_path.module_qualifier) |ii_module| {
                                    if (eql(u8, ii_module, event_module) and
                                        ii.event_path.segments.len == event.path.segments.len)
                                    {
                                        var matches = true;
                                        for (ii.event_path.segments, 0..) |seg, j| {
                                            if (!eql(u8, seg, event.path.segments[j])) {
                                                matches = false;
                                                break;
                                            }
                                        }
                                        if (matches) {
                                            const bc = &ii.value;
                                            log.debug("  [emitEventDecl] Found cross-module immediate override for {s}:{s}\n", .{event_module, event.path.segments[0]});
                                            // Generate implicit input bindings for immediate impls
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
                                            var value_ctx = emitter.EmissionContext{
                                                .allocator = self.allocator,
                                                .main_module_name = self.main_module_name,
                                            };
                                            try self.code_emitter.writeIndent();
                                            try self.code_emitter.write("return .{ .");
                                            try emitter.writeBranchName(self.code_emitter, bc.branch_name);
                                            try self.code_emitter.write(" = ");
                                            if (bc.plain_value) |pv| {
                                                const trimmed = std.mem.trim(u8, pv, " \t");
                                                if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                                                    if (self.findBranchField(event, bc.branch_name, null)) |field| {
                                                        try emitter.emitArrayLiteralForField(self.code_emitter, &value_ctx, field, pv);
                                                    } else {
                                                        try emitter.emitValue(self.code_emitter, &value_ctx, pv);
                                                    }
                                                } else {
                                                    try emitter.emitValue(self.code_emitter, &value_ctx, pv);
                                                }
                                            } else {
                                                try self.code_emitter.write(".{");
                                                for (bc.fields, 0..) |field, k| {
                                                    if (k > 0) try self.code_emitter.write(", ");
                                                    try self.code_emitter.write(" .");
                                                    try self.code_emitter.write(field.name);
                                                    try self.code_emitter.write(" = ");
                                                    const value = if (field.expression_str) |expr| expr else field.type;
                                                    const trimmed = std.mem.trim(u8, value, " \t");
                                                    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                                                        if (self.findBranchField(event, bc.branch_name, field.name)) |branch_field| {
                                                            try emitter.emitArrayLiteralForField(self.code_emitter, &value_ctx, branch_field, value);
                                                        } else {
                                                            try emitter.emitValue(self.code_emitter, &value_ctx, value);
                                                        }
                                                    } else {
                                                        try emitter.emitValue(self.code_emitter, &value_ctx, value);
                                                    }
                                                }
                                                try self.code_emitter.write(" }");
                                            }
                                            try self.code_emitter.write(" };\n");
                                            found_impl = true;
                                        }
                                    }
                                }
                            }
                        },
                        .flow => |flow| {
                            if (flow.impl_of) |impl_path| {
                                // Cross-module check for flow-based impls
                                const is_cross_module = if (impl_path.module_qualifier) |impl_mq|
                                    !eql(u8, flow.module, impl_mq)
                                else
                                    false;
                                if (is_cross_module or flow.isImpl()) {
                                    if (impl_path.module_qualifier) |impl_module| {
                                        if (eql(u8, impl_module, event_module) and
                                            impl_path.segments.len == event.path.segments.len)
                                        {
                                            var matches = true;
                                            for (impl_path.segments, 0..) |seg, j| {
                                                if (!eql(u8, seg, event.path.segments[j])) {
                                                    matches = false;
                                                    break;
                                                }
                                            }
                                            if (matches) {
                                                log.debug("  [emitEventDecl] Found cross-module flow override for {s}:{s}\n", .{event_module, event.path.segments[0]});
                                                // Cross-module override with flow body (delegation pattern)
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

                                                // Generate the invocation (or inline_body if transform set it)
                                                if (flow.inline_body) |inline_code_raw| {
                                                    // Transform set inline_body -- emit inline instead of handler call
                                                    const inline_stmt_marker = "//@koru:inline_stmt\n";
                                                    var inline_code = inline_code_raw;
                                                    var is_inline_stmt = false;
                                                    if (std.mem.indexOf(u8, inline_code, inline_stmt_marker)) |marker_idx| {
                                                        is_inline_stmt = true;
                                                        inline_code = inline_code[marker_idx + inline_stmt_marker.len..];
                                                    }

                                                    if (is_inline_stmt) {
                                                        const has_named_branches = blk: {
                                                            for (flow.continuations) |cont| {
                                                                if (cont.branch.len > 0) break :blk true;
                                                            }
                                                            break :blk false;
                                                        };
                                                        if (has_named_branches) {
                                                            try self.code_emitter.writeIndent();
                                                            try self.code_emitter.write("@compileError(\"inline_stmt cannot be used with named continuations\");\n");
                                                        } else {
                                                            try emitInlineStmtDedented(self.code_emitter, inline_code);
                                                        }
                                                    } else {
                                                        try self.code_emitter.writeIndent();
                                                        try self.code_emitter.write("const result = ");

                                                        // If inline code uses __KORU_INLINE__ placeholder,
                                                        // wrap in a labeled block and replace the placeholder.
                                                        const placeholder2 = "__KORU_INLINE__";
                                                        if (std.mem.indexOf(u8, inline_code, placeholder2) != null) {
                                                            try self.code_emitter.write("__koru_inline__: ");
                                                            var scan_pos2: usize = 0;
                                                            while (scan_pos2 < inline_code.len) {
                                                                if (scan_pos2 + placeholder2.len <= inline_code.len and
                                                                    std.mem.eql(u8, inline_code[scan_pos2 .. scan_pos2 + placeholder2.len], placeholder2))
                                                                {
                                                                    try self.code_emitter.write("__koru_inline__");
                                                                    scan_pos2 += placeholder2.len;
                                                                } else {
                                                                    try self.code_emitter.write(inline_code[scan_pos2 .. scan_pos2 + 1]);
                                                                    scan_pos2 += 1;
                                                                }
                                                            }
                                                        } else {
                                                            try self.code_emitter.write(inline_code);
                                                        }
                                                        try self.code_emitter.write(";\n");
                                                    }
                                                } else {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("const result = ");

                                                    // Check if this is a self-call (delegating to default)
                                                    const is_self_call = blk: {
                                                        // For cross-module impl, self-call means calling the same event
                                                        if (flow.invocation.path.module_qualifier) |inv_mq| {
                                                            if (eql(u8, inv_mq, event_module) and
                                                                flow.invocation.path.segments.len == event.path.segments.len)
                                                            {
                                                                var segs_match = true;
                                                                for (flow.invocation.path.segments, 0..) |seg, j| {
                                                                    if (!eql(u8, seg, event.path.segments[j])) {
                                                                        segs_match = false;
                                                                        break;
                                                                    }
                                                                }
                                                                if (segs_match) break :blk true;
                                                            }
                                                        }
                                                        break :blk false;
                                                    };

                                                    if (is_self_call) {
                                                        try self.code_emitter.write("_default_handler(.{");
                                                    } else {
                                                        if (flow.invocation.path.module_qualifier) |mq| {
                                                            try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                                            try self.code_emitter.write(".");
                                                        }
                                                        for (flow.invocation.path.segments, 0..) |seg, idx| {
                                                            if (idx > 0) try self.code_emitter.write("_");
                                                            try self.code_emitter.write(seg);
                                                        }
                                                        try self.code_emitter.write("_event.handler(.{");
                                                    }

                                                    // Write arguments
                                                    for (flow.invocation.args, 0..) |arg, k| {
                                                        if (k > 0) try self.code_emitter.write(", ");
                                                        try self.code_emitter.write(" .");
                                                        try self.code_emitter.write(arg.name);
                                                        try self.code_emitter.write(" = ");
                                                        try self.code_emitter.write(arg.value);
                                                    }
                                                    try self.code_emitter.write(" });\n");
                                                }

                                                // Generate switch on result with continuations
                                                var indent_buf: [64]u8 = undefined;
                                                var indent_pos: usize = 0;
                                                var idx: usize = 0;
                                                while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                                    @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                                    indent_pos += 4;
                                                }
                                                const indent_str = indent_buf[0..indent_pos];

                                                const source_event_name = try emitter.buildCanonicalEventName(&flow.invocation.path, self.allocator, self.main_module_name);
                                                try emitter.emitSubflowContinuations(self.code_emitter, flow.continuations, 0, indent_str, self.all_items, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "main_module");

                                                found_impl = true;
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                    if (found_impl) break;
                }
            }
        }

        // THEN: Search in module-local items
        if (!found_impl) {
        for (items_to_search) |impl_item| {
            switch (impl_item) {
                .proc_decl => |proc| {
                    // Skip proc_decl if this is an abstract event with a cross-module override
                    if (has_impl_override) continue;

                    if (proc.path.segments.len == event.path.segments.len) {
                        var matches = true;
                        for (proc.path.segments, 0..) |seg, j| {
                            if (!eql(u8, seg, event.path.segments[j])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            // Variant-aware handler selection:
                            // 1. Check variant registry for this event
                            // 2. If variant registered, use the proc whose target matches
                            // 3. If no variant registered, use target=null or target="zig"
                            const registered_variant = blk: {
                                // Use current_module_name (set during module emission) for correct canonical name
                                const module_for_lookup = self.current_module_name orelse self.main_module_name;
                                const canonical = emitter.buildCanonicalEventName(&event.path, self.allocator, module_for_lookup) catch break :blk @as(?[]const u8, null);
                                defer self.allocator.free(canonical);
                                // Copy so it outlives the defer
                                if (emitter.getVariant(canonical)) |v| {
                                    break :blk @as(?[]const u8, self.allocator.dupe(u8, v) catch null);
                                }
                                break :blk @as(?[]const u8, null);
                            };
                            defer if (registered_variant) |rv| self.allocator.free(rv);

                            if (proc.target) |target| {
                                if (registered_variant) |rv| {
                                    // Variant registered: only use the proc that matches
                                    if (!eql(u8, target, rv)) continue;
                                } else {
                                    // No variant registered: only use zig/default
                                    if (!eql(u8, target, "zig")) continue;
                                }
                            } else {
                                // proc.target == null (bare proc): skip if a specific variant was registered
                                if (registered_variant != null) continue;
                            }

                            // Generate source marker for proc
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("// >>> PROC: ");
                            for (proc.path.segments, 0..) |seg, idx| {
                                if (idx > 0) try self.code_emitter.write(".");
                                try self.code_emitter.write(seg);
                            }
                            try self.code_emitter.write("\n");

                            // Collect module-level names to detect shadowing
                            var declared_names = try collectDeclaredNames(items_to_search, self.allocator);
                            defer declared_names.deinit(self.allocator);

                            // Generate implicit input bindings (skip shadowed fields)
                            for (event.input.fields) |field| {
                                if (!nameIsShadowed(field.name, declared_names.items)) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("const ");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(" = __koru_event_input.");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(";\n");
                                }
                            }
                            // Suppress unused variable warnings
                            for (event.input.fields) |field| {
                                if (!nameIsShadowed(field.name, declared_names.items)) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(";\n");
                                }
                            }

                            // Keep _ = &__koru_event_input for backwards compatibility
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("_ = &__koru_event_input;\n");

                            // Rewrite proc body: replace shadowed field names with __koru_event_input.field
                            var proc_body: []const u8 = proc.body;
                            for (event.input.fields) |field| {
                                if (nameIsShadowed(field.name, declared_names.items)) {
                                    const replacement = try std.fmt.allocPrint(self.allocator, "__koru_event_input.{s}", .{field.name});
                                    proc_body = try replaceIdentifier(self.allocator, proc_body, field.name, replacement);
                                }
                            }

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

                            try self.code_emitter.emitReindentedText(proc_body, indent_str);
                            try self.code_emitter.write("\n");
                            found_impl = true;
                            break;
                        }
                    }
                },
                .immediate_impl => |ii| {
                    // Immediate branch return implementation
                    log.debug("    Checking immediate_impl: ", .{});
                    for (ii.event_path.segments) |seg| {
                        log.debug("{s}.", .{seg});
                    }
                    log.debug("\n", .{});

                    if (ii.event_path.segments.len == event.path.segments.len) {
                        var matches = true;
                        for (ii.event_path.segments, 0..) |seg, j| {
                            if (!eql(u8, seg, event.path.segments[j])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            const bc = &ii.value;
                            log.debug("    Found matching immediate_impl!\n", .{});
                            // Generate implicit input bindings for immediate impls
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
                            var value_ctx = emitter.EmissionContext{
                                .allocator = self.allocator,
                                .main_module_name = self.main_module_name,
                            };
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("return .{ .");
                            try emitter.writeBranchName(self.code_emitter, bc.branch_name);
                            try self.code_emitter.write(" = ");
                            // Check for plain value (non-struct branch)
                            if (bc.plain_value) |pv| {
                                const trimmed = std.mem.trim(u8, pv, " \t");
                                if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                                    if (self.findBranchField(event, bc.branch_name, null)) |field| {
                                        try emitter.emitArrayLiteralForField(self.code_emitter, &value_ctx, field, pv);
                                    } else {
                                        try emitter.emitValue(self.code_emitter, &value_ctx, pv);
                                    }
                                } else {
                                    try emitter.emitValue(self.code_emitter, &value_ctx, pv);
                                }
                            } else {
                                try self.code_emitter.write(".{");
                                for (bc.fields, 0..) |field, k| {
                                    if (k > 0) try self.code_emitter.write(", ");
                                    try self.code_emitter.write(" .");
                                    try self.code_emitter.write(field.name);
                                    try self.code_emitter.write(" = ");
                                    // Use expression_str if present (for expressions), otherwise use type
                                    const value = if (field.expression_str) |expr| expr else field.type;
                                    const trimmed = std.mem.trim(u8, value, " \t");
                                    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                                        if (self.findBranchField(event, bc.branch_name, field.name)) |branch_field| {
                                            try emitter.emitArrayLiteralForField(self.code_emitter, &value_ctx, branch_field, value);
                                        } else {
                                            try emitter.emitValue(self.code_emitter, &value_ctx, value);
                                        }
                                    } else {
                                        try emitter.emitValue(self.code_emitter, &value_ctx, value);
                                    }
                                }
                                try self.code_emitter.write(" }");
                            }
                            try self.code_emitter.write(" };\n");
                            found_impl = true;
                            break;
                        }
                    }
                },
                .flow => |flow| {
                    // Flow-based implementation (only match flows with impl_of set)
                    if (flow.impl_of) |impl_path| {
                        log.debug("    Checking impl flow: ", .{});
                        for (impl_path.segments) |seg| {
                            log.debug("{s}.", .{seg});
                        }
                        log.debug("\n", .{});

                        if (impl_path.segments.len == event.path.segments.len) {
                            var matches = true;
                            for (impl_path.segments, 0..) |seg, j| {
                                if (!eql(u8, seg, event.path.segments[j])) {
                                    matches = false;
                                    break;
                                }
                            }
                            if (matches) {
                                log.debug("    Found matching impl flow!\n", .{});
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
                                        .type_registry = self.type_registry,
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
                                    // Check if continuations have named branches (need switch)
                                    const has_named_branches = blk: {
                                        for (flow.continuations) |cont| {
                                            if (cont.branch.len > 0) break :blk true;
                                        }
                                        break :blk false;
                                    };

                                    if (has_named_branches) {
                                        // Branching continuations -- emit: const result = <inline>; switch(result) { ... }
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const result = ");

                                        // If inline code uses __KORU_INLINE__ placeholder,
                                        // wrap in a labeled block and replace the placeholder.
                                        const placeholder3 = "__KORU_INLINE__";
                                        if (std.mem.indexOf(u8, inline_code, placeholder3) != null) {
                                            try self.code_emitter.write("__koru_inline__: ");
                                            var scan_pos3: usize = 0;
                                            while (scan_pos3 < inline_code.len) {
                                                if (scan_pos3 + placeholder3.len <= inline_code.len and
                                                    std.mem.eql(u8, inline_code[scan_pos3 .. scan_pos3 + placeholder3.len], placeholder3))
                                                {
                                                    try self.code_emitter.write("__koru_inline__");
                                                    scan_pos3 += placeholder3.len;
                                                } else {
                                                    try self.code_emitter.write(inline_code[scan_pos3 .. scan_pos3 + 1]);
                                                    scan_pos3 += 1;
                                                }
                                            }
                                        } else {
                                            try self.code_emitter.write(inline_code);
                                        }
                                        try self.code_emitter.write(";\n");

                                        var indent_buf: [64]u8 = undefined;
                                        var indent_pos: usize = 0;
                                        var idx: usize = 0;
                                        while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                            @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                            indent_pos += 4;
                                        }
                                        const indent_str = indent_buf[0..indent_pos];

                                        const source_event_name = try emitter.buildCanonicalEventName(&flow.invocation.path, self.allocator, self.main_module_name);
                                        try emitter.emitSubflowContinuations(self.code_emitter, flow.continuations, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "main_module");
                                    } else {
                                        // Void/pipeline continuations -- emit inline code + branch constructors
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
                                        _ = indent_str;

                                        try self.code_emitter.emitReindentedText(inline_code, indent_buf[0..indent_pos]);
                                        try self.code_emitter.write("\n");

                                        for (flow.continuations) |cont| {
                                            if (cont.branch.len == 0) {
                                                if (cont.node) |step| {
                                                    if (step == .branch_constructor) {
                                                        const bc = &step.branch_constructor;
                                                        var value_ctx = emitter.EmissionContext{
                                                            .allocator = self.allocator,
                                                            .main_module_name = self.main_module_name,
                                                        };
                                                        try self.code_emitter.writeIndent();
                                                        try self.code_emitter.write("return .{ .");
                                                        try emitter.writeBranchName(self.code_emitter, bc.branch_name);
                                                        try self.code_emitter.write(" = .{");
                                                        for (bc.fields, 0..) |field, k| {
                                                            if (k > 0) try self.code_emitter.write(",");
                                                            try self.code_emitter.write(" .");
                                                            try self.code_emitter.write(field.name);
                                                            try self.code_emitter.write(" = ");
                                                            const value = if (field.expression_str) |expr| expr else field.type;
                                                            const trimmed = std.mem.trim(u8, value, " \t");
                                                            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                                                                if (self.findBranchField(event, bc.branch_name, field.name)) |branch_field| {
                                                                    try emitter.emitArrayLiteralForField(self.code_emitter, &value_ctx, branch_field, value);
                                                                } else {
                                                                    try emitter.emitValue(self.code_emitter, &value_ctx, value);
                                                                }
                                                            } else {
                                                                try emitter.emitValue(self.code_emitter, &value_ctx, value);
                                                            }
                                                        }
                                                        try self.code_emitter.write(" } };\n");
                                                    }
                                                }
                                            }
                                        }
                                    }
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

                                    // Check if this is a self-call (impl calling the same event to delegate to default)
                                    // This happens in override patterns like: ~mod:foo = foo(x: 42) | ok |> ...
                                    const is_self_call = blk: {
                                        if (!has_impl_override) break :blk false;
                                        if (flow.invocation.path.segments.len != event.path.segments.len) break :blk false;
                                        for (flow.invocation.path.segments, 0..) |seg, j| {
                                            if (!std.mem.eql(u8, seg, event.path.segments[j])) break :blk false;
                                        }
                                        break :blk true;
                                    };

                                    if (is_self_call) {
                                        // Self-call: delegate to _default_handler
                                        try self.code_emitter.write("_default_handler(.{");
                                    } else {
                                        // Regular call: use the event handler
                                        // Check if event is module-qualified
                                        if (flow.invocation.path.module_qualifier) |mq| {
                                            // Use writeModulePath to properly sanitize module references
                                            // (e.g., entry module -> "main_module", "logger" -> "koru_logger")
                                            try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                            try self.code_emitter.write(".");
                                        }
                                        // Join all segments with underscores
                                        for (flow.invocation.path.segments, 0..) |seg, idx| {
                                            if (idx > 0) try self.code_emitter.write("_");
                                            try self.code_emitter.write(seg);
                                        }
                                        try self.code_emitter.write("_event.handler(.{");
                                    }

                                    // Write arguments, mapping from input parameters
                                    // Look up event signature to get parameter names for positional args
                                    const event_canonical_name = try emitter.buildCanonicalEventName(&flow.invocation.path, self.allocator, self.main_module_name);
                                    defer self.allocator.free(event_canonical_name);
                                    const event_type = self.type_registry.getEventType(event_canonical_name);
                                    var value_ctx = emitter.EmissionContext{
                                        .allocator = self.allocator,
                                        .main_module_name = self.main_module_name,
                                    };

                                    for (flow.invocation.args, 0..) |arg, k| {
                                        if (k > 0) try self.code_emitter.write(", ");
                                        try self.code_emitter.write(" .");

                                        // Check if this is a positional arg (name == value indicates synthesized name)
                                        // If so, use the parameter name from the event signature
                                        const param_name = if (std.mem.eql(u8, arg.name, arg.value)) blk: {
                                            // Positional arg - get name from event signature
                                            if (event_type) |et| {
                                                if (et.input_shape) |shape| {
                                                    if (k < shape.fields.len) {
                                                        break :blk shape.fields[k].name;
                                                    }
                                                }
                                            }
                                            // Fallback: use arg.name (might produce invalid Zig)
                                            break :blk arg.name;
                                        } else arg.name;

                                        try self.code_emitter.write(param_name);
                                        try self.code_emitter.write(" = ");

                                        if (arg.value.len >= 2 and arg.value[0] == '[' and arg.value[arg.value.len - 1] == ']') {
                                            const field = blk: {
                                                if (invoked_event) |inv_event| {
                                                    for (inv_event.input.fields) |*field| {
                                                        if (std.mem.eql(u8, field.name, param_name)) {
                                                            break :blk field;
                                                        }
                                                    }
                                                }
                                                break :blk null;
                                            };
                                            if (field) |field_info| {
                                                try emitter.emitArrayLiteralForField(self.code_emitter, &value_ctx, field_info, arg.value);
                                            } else {
                                                return error.ArrayLiteralMissingType;
                                            }
                                        } else {
                                            try emitter.emitValue(self.code_emitter, &value_ctx, arg.value);
                                        }
                                    }
                                    // NOTE: Comptime injection of program/allocator is now handled
                                    // by emitArgs in emitter_helpers.zig
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

                                    try emitter.emitSubflowContinuations(self.code_emitter, flow.continuations, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "main_module");
                                }
                                found_impl = true;
                                break;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        }

        // NOTE: Special case for compiler.coordinate removed - abstract/impl handles it

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

                // AUTO-PROC SYNTHESIS: Check if we can generate a passthrough
                // Conditions: single branch, all output fields have matching input fields
                const can_passthrough = blk: {
                    if (event.branches.len != 1) break :blk false;
                    for (first_branch.payload.fields) |out_field| {
                        var found_match = false;
                        for (event.input.fields) |in_field| {
                            if (eql(u8, out_field.name, in_field.name)) {
                                // Compare base types (strip phantom annotations like [state!])
                                const out_base = stripPhantom(out_field.type);
                                const in_base = stripPhantom(in_field.type);
                                if (eql(u8, out_base, in_base)) {
                                    found_match = true;
                                    break;
                                }
                            }
                        }
                        if (!found_match) break :blk false;
                    }
                    break :blk first_branch.payload.fields.len > 0;
                };

                // Return with proper field values
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("return .{ .");
                try emitter.writeBranchName(self.code_emitter, first_branch.name);
                try self.code_emitter.write(" = ");

                if (is_identity) {
                    // Identity type: emit value directly (no struct wrapper)
                    const field_type = first_branch.payload.fields[0].type;
                    if (can_passthrough) {
                        // Passthrough: use input value
                        try self.code_emitter.write("__koru_event_input.");
                        try self.code_emitter.write(first_branch.payload.fields[0].name);
                    } else if (eql(u8, field_type, "i32") or eql(u8, field_type, "i64") or
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

                    // Generate values for each field in the branch
                    for (first_branch.payload.fields) |field| {
                        try self.code_emitter.write(" .");
                        try self.code_emitter.write(field.name);
                        try self.code_emitter.write(" = ");

                        if (can_passthrough) {
                            // Passthrough: use input value
                            try self.code_emitter.write("__koru_event_input.");
                            try self.code_emitter.write(field.name);
                        } else if (eql(u8, field.type, "i32")) {
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

        // Emit variant handlers for registry-selected variants only.
        // Non-zig variants (gpu, js, etc.) are only emitted if explicitly
        // selected via build:variants — their bodies may be foreign code
        // (GLSL, JS) that would fail Zig compilation if emitted verbatim.
        const module_for_variant_lookup = self.current_module_name orelse self.main_module_name;
        const event_canonical = emitter.buildCanonicalEventName(&event.path, self.allocator, module_for_variant_lookup) catch null;
        defer if (event_canonical) |ec| self.allocator.free(ec);

        for (items_to_search) |impl_item| {
            switch (impl_item) {
                .proc_decl => |proc| {
                    // Only emit handlers for variant procs (target != null and target != "zig")
                    if (proc.target) |target| {
                        if (eql(u8, target, "zig")) continue;

                        // Only emit if this variant is registered (selected for use)
                        const is_registered = if (event_canonical) |ec|
                            if (emitter.getVariant(ec)) |rv| eql(u8, rv, target) else false
                        else
                            false;
                        if (!is_registered) continue;

                        // Check if this proc matches the event
                        if (proc.path.segments.len != event.path.segments.len) continue;
                        var matches = true;
                        for (proc.path.segments, 0..) |seg, j| {
                            if (!eql(u8, seg, event.path.segments[j])) {
                                matches = false;
                                break;
                            }
                        }
                        if (!matches) continue;

                        // Emit variant handler
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("pub fn ");
                        try emitter.writeHandlerName(self.code_emitter, self.allocator, target);
                        try self.code_emitter.write("(__koru_event_input: Input) Output {");
                        try emitter.writeVariantComment(self.code_emitter, target);
                        try self.code_emitter.write("\n");
                        self.code_emitter.indent_level += 1;

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

                        // Emit proc body
                        var indent_buf: [64]u8 = undefined;
                        var indent_pos: usize = 0;
                        var k: usize = 0;
                        while (k < self.code_emitter.indent_level) : (k += 1) {
                            @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                            indent_pos += 4;
                        }
                        const indent_str = indent_buf[0..indent_pos];
                        try self.code_emitter.emitReindentedText(proc.body, indent_str);
                        try self.code_emitter.write("\n");

                        // Close variant handler
                        self.code_emitter.indent_level -= 1;
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("}\n");
                    }
                },
                else => {},
            }
        }

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
        // Escape module names that aren't valid Zig identifiers (e.g., @koru, test-pkg)
        if (codegen_utils.needsEscaping(node.name)) {
            try self.code_emitter.write("@\"");
            try self.code_emitter.write(node.name);
            try self.code_emitter.write("\"");
        } else {
            try self.code_emitter.write(node.name);
        }
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
            // Track current module name and Zig prefix for variant registry lookups
            const prev_module_name = self.current_module_name;
            const prev_module_prefix = self.current_module_prefix;
            self.current_module_name = module.logical_name;
            // Build Zig path prefix: "orisha" → "koru_orisha", "std.build" → "koru_std.build"
            const prefix = blk: {
                var buf: std.ArrayList(u8) = .empty;
                buf.appendSlice(self.allocator, "koru_") catch break :blk @as(?[]const u8, null);
                // Replace dots in logical_name with dots in Zig path
                buf.appendSlice(self.allocator, module.logical_name) catch break :blk @as(?[]const u8, null);
                break :blk buf.toOwnedSlice(self.allocator) catch null;
            };
            self.current_module_prefix = prefix;
            defer {
                self.current_module_name = prev_module_name;
                self.current_module_prefix = prev_module_prefix;
                if (prefix) |p| self.allocator.free(p);
            }

            for (module.items) |*module_item| {
                // Skip host lines - already emitted above
                if (module_item.* != .host_line) {
                    // Use the module's OWN annotations, not the top-level file's annotations
                    // This is critical for [comptime|runtime] modules like std.io
                    // NOTE: module.items is used for scoped implementation search
                    // EmissionContext.ast_items is set to all_items for event declaration lookup
                    try self.visitItem(module_item, module.annotations, module.items);
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
                        log.debug("DEBUG findEventDeclInItemsWithModule: FOUND EVENT! Annotations: {}\n", .{event.annotations.len});
                        for (event.annotations) |ann| {
                            log.debug("  - '{s}'\n", .{ann});
                        }
                        return event;
                    }
                },
                .module_decl => |*module| {
                    log.debug("DEBUG: Recursing into module '{s}'\n", .{module.logical_name});
                    // Pass the module's logical_name as context when recursing
                    if (self.findEventDeclInItemsWithModule(module.items, path, module.logical_name)) |found| {
                        log.debug("DEBUG findEventDeclInItemsWithModule: Returning found event from module '{s}', annotations: {}\n", .{module.logical_name, found.annotations.len});
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

        log.debug("DEBUG pathsEqualWithModule:\n", .{});
        log.debug("  a: module={s} segments=", .{if (a.module_qualifier) |m| m else "null"});
        for (a.segments) |s| log.debug("{s}.", .{s});
        log.debug("\n  b: module={s} segments=", .{if (b.module_qualifier) |m| m else "null"});
        for (b.segments) |s| log.debug("{s}.", .{s});
        log.debug("\n  current_module={s}\n", .{if (current_module) |m| m else "null"});

        // Case 1: Both have module qualifiers - they must match
        if (a_has_module and b_has_module) {
            const mq_a = a.module_qualifier.?;
            const mq_b = b.module_qualifier.?;
            if (!moduleQualifiersMatch(mq_a, mq_b)) {
                log.debug("  -> MISMATCH (both have modules, don't match)\n", .{});
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
                log.debug("  -> MISMATCH (one has module, can't determine context)\n", .{});
                return false;
            }

            // Check if effective module matches the module_qualifier
            if (!moduleQualifiersMatch(effective_module.?, module_qual)) {
                log.debug("  -> MISMATCH (effective_module '{s}' doesn't match module_qual '{s}')\n", .{effective_module.?, module_qual});
                return false;
            }

            // Module context matches! Continue to check segments
            log.debug("  -> Module context matches (effective='{s}', qual='{s}'), checking segments...\n", .{effective_module.?, module_qual});
        }

        // Check segments match
        if (a.segments.len != b.segments.len) {
            log.debug("  -> MISMATCH (segment lengths differ: {} vs {})\n", .{a.segments.len, b.segments.len});
            return false;
        }

        for (a.segments, 0..) |segment, idx| {
            if (!std.mem.eql(u8, segment, b.segments[idx])) {
                log.debug("  -> MISMATCH (segment {} differs: '{s}' vs '{s}')\n", .{idx, segment, b.segments[idx]});
                return false;
            }
        }

        log.debug("  -> MATCH! Returning TRUE\n", .{});
        return true;
    }

    /// Check if a flow invokes an event with comptime parameters (Source/Program)
    /// OR an event with ~[comptime] or ~[norun] annotations
    /// Flows that invoke comptime events are implicitly comptime themselves
    fn flowInvokesComptimeEvent(self: *VisitorEmitter, flow: *const ast.Flow, items: []const ast.Item) bool {
        _ = items; // Unused - we search in self.all_items instead

        log.debug("=== flowInvokesComptimeEvent DEBUG ===\n", .{});
        log.debug("  all_items.len = {}\n", .{self.all_items.len});

        // DEBUG: List all modules in all_items and their events
        for (self.all_items) |item| {
            if (item == .module_decl) {
                log.debug("  Module in all_items: '{s}' with {} items\n", .{item.module_decl.logical_name, item.module_decl.items.len});
                if (std.mem.eql(u8, item.module_decl.logical_name, "std.package")) {
                    log.debug("    std.package contents:\n", .{});
                    for (item.module_decl.items) |mod_item| {
                        switch (mod_item) {
                            .event_decl => |evt| {
                                log.debug("      Event:", .{});
                                for (evt.path.segments) |seg| {
                                    log.debug(" {s}", .{seg});
                                }
                                log.debug(" [annotations: {}]\n", .{evt.annotations.len});
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
        log.debug("  Looking for event: '{s}' in mode={s}\n", .{event_name, @tagName(self.emit_mode)});

        // CRITICAL: Check the current AST being emitted FIRST (it may have been transformed!)
        // self.all_items contains the actual AST we're emitting (potentially transformed)
        // TypeRegistry contains the ORIGINAL frontend AST before transformations
        log.debug("  Checking current AST for event: '{s}'\n", .{event_name});
        const event_decl = self.findEventDeclInItems(self.all_items, &flow.invocation.path);
        log.debug("  AST event lookup result for '{s}': {}\n", .{event_name, event_decl != null});

        if (event_decl) |decl| {
            // Found event in current AST - check its parameters and annotations directly
            log.debug("  Found event '{s}' in AST, module: '{s}'\n", .{event_name, decl.module});
            log.debug("  Event path segments:", .{});
            for (decl.path.segments) |seg| {
                log.debug(" {s}", .{seg});
            }
            log.debug("\n", .{});

            // Check if event has comptime parameters
            for (decl.input.fields) |field| {
                if (field.is_source or field.is_expression or
                    std.mem.indexOf(u8, field.type, "Program") != null or
                    std.mem.eql(u8, field.type, "Expression")) {
                    log.debug("  Event has comptime parameter: {s}\n", .{field.name});
                    return true;
                }
            }

            // Check for comptime or norun annotations
            log.debug("  Event '{s}' annotations array length: {}\n", .{event_name, decl.annotations.len});
            for (decl.annotations) |ann| {
                log.debug("    annotation: '{s}'\n", .{ann});
            }
            const has_comptime = annotation_parser.hasPart(decl.annotations, "comptime");
            const has_norun = annotation_parser.hasPart(decl.annotations, "norun");
            log.debug("  has_comptime={} has_norun={}\n", .{has_comptime, has_norun});

            if (has_comptime or has_norun) {
                log.debug("  Returning TRUE from AST check\n", .{});
                return true;  // Event is comptime-only (should not be emitted to runtime)
            }

            // Event in AST is runtime (no Source params, no comptime annotations)
            log.debug("  Returning FALSE - AST event is runtime\n", .{});
            return false;
        }

        // Event not in current AST - fall back to TypeRegistry (for imported events)
        log.debug("  Event not in current AST, checking TypeRegistry\n", .{});
        const event_type = self.type_registry.getEventType(event_name);
        log.debug("  TypeRegistry lookup result: {}\n", .{event_type != null});

        if (event_type == null) {
            // Event not found in AST or TypeRegistry. This could be:
            // 1. A typo in the event name
            // 2. A missing import
            // 3. An event that will be generated by a derive handler at backend compile time
            //
            // For case 3 (derive-generated events), the backend's run_pass() will create the event
            // before final code generation. Return false to treat as a runtime event.
            log.debug("  Event '{s}' not in AST/TypeRegistry - may be derive-generated\n", .{event_name});

            return false;
        }

        const event = event_type.?;

        // Check if event has comptime parameters by examining input_shape
        if (event.input_shape) |shape| {
            for (shape.fields) |field| {
                if (field.is_source or field.is_expression or
                    std.mem.indexOf(u8, field.type, "Program") != null or
                    std.mem.eql(u8, field.type, "Expression")) {
                    log.debug("  TypeRegistry event has comptime parameter\n", .{});
                    return true;
                }
            }
        }

        // TypeRegistry event doesn't have comptime parameters
        // (Note: TypeRegistry doesn't store annotations, so we can't check those)
        log.debug("  Returning FALSE - TypeRegistry event is runtime\n", .{});
        return false;
    }

    fn findBranchField(
        self: *VisitorEmitter,
        event: *const ast.EventDecl,
        branch_name: []const u8,
        field_name: ?[]const u8,
    ) ?*const ast.Field {
        _ = self;
        for (event.branches) |branch| {
            if (!std.mem.eql(u8, branch.name, branch_name)) continue;
            if (field_name) |name| {
                for (branch.payload.fields) |*field| {
                    if (std.mem.eql(u8, field.name, name)) return field;
                }
            } else if (branch.payload.fields.len > 0) {
                return &branch.payload.fields[0];
            }
            return null;
        }
        return null;
    }

    // TODO: Implement visitor callbacks once context threading is solved
    // For now, we use manual iteration in visitItem()
};
