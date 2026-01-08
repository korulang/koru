const std = @import("std");
const Parser = @import("parser").Parser;
const ErrorReporter = @import("errors").ErrorReporter;
const shape_checker = @import("shape_checker");
const ShapeChecker = shape_checker.ShapeChecker;
const purity_checker = @import("purity_checker.zig");
const PurityChecker = purity_checker.PurityChecker;
const fusion_detector = @import("fusion_detector.zig");
const FusionDetector = fusion_detector.FusionDetector;
const compiler_feature_flags = @import("compiler_config");
// Old Emitter no longer needed - using ComptimeEmitter
const ast = @import("ast");
const TypeRegistry = @import("type_registry").TypeRegistry;
const validate_abstract_impl = @import("validate_abstract_impl");
const CompilerBootstrap = @import("compiler").CompilerBootstrap;
const compiler_coordination = @import("compiler_coordination.zig");
// emitter.zig removed - using visitor_emitter now
const TapCollector = @import("tap_collector").TapCollector;
const CompilerRequiresCollector = @import("compiler_requires").CompilerRequiresCollector;
const emit_build_zig = @import("emit_build_zig");
const PackageRequirementsCollector = @import("package_requires").PackageRequirementsCollector;
const emit_package_files = @import("emit_package_files");
const ModuleResolver = @import("module_resolver").ModuleResolver;
const project_template = @import("project_template.zig");
const Config = @import("config").Config;
const annotation_parser = @import("annotation_parser");
const keyword_registry = @import("keyword_registry");
const flow_checker = @import("flow_checker");
const FlowChecker = flow_checker.FlowChecker;

const version = "0.1.0";

/// Check if a word is a Zig keyword (requires @"..." escaping in enums)
fn isZigKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "error",      "type",        "async",     "await",       "suspend",  "resume",
        "try",        "catch",       "if",        "else",        "switch",   "while",
        "for",        "break",       "continue",  "return",      "defer",    "errdefer",
        "test",       "pub",         "export",    "extern",      "packed",   "inline",
        "noinline",   "comptime",    "nosuspend", "volatile",    "allowzero",
        "align",      "linksection", "callconv",  "noalias",
        "struct",     "enum",        "union",     "opaque",      "fn",       "const",
        "var",        "anyframe",    "anytype",   "anyerror",    "unreachable",
        "undef",      "null",        "true",      "false",       "and",      "or",
        "orelse",     "threadlocal",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) {
            return true;
        }
    }
    return false;
}

/// Write a branch name, escaping Zig keywords with @"..."
fn writeBranchName(writer: anytype, name: []const u8) !void {
    if (isZigKeyword(name)) {
        try writer.writeAll("@\"");
        try writer.writeAll(name);
        try writer.writeAll("\"");
    } else {
        try writer.writeAll(name);
    }
}

/// Compiler configuration - captures all flags and environment for backend embedding
const CompilerConfig = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList([]const u8),
    env_vars: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) !CompilerConfig {
        return .{
            .allocator = allocator,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .env_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CompilerConfig) void {
        for (self.flags.items) |flag| {
            self.allocator.free(flag);
        }
        self.flags.deinit(self.allocator);

        var it = self.env_vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit();
    }

    pub fn addFlag(self: *CompilerConfig, flag: []const u8) !void {
        const owned = try self.allocator.dupe(u8, flag);
        try self.flags.append(self.allocator, owned);
    }

    pub fn addEnv(self: *CompilerConfig, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.env_vars.put(owned_key, owned_value);
    }

    pub fn hasFlag(self: *const CompilerConfig, flag: []const u8) bool {
        for (self.flags.items) |f| {
            if (std.mem.eql(u8, f, flag)) {
                return true;
            }
        }
        return false;
    }
};

fn printStderr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    const stderr = std.fs.File.stderr();
    try stderr.writeAll(msg);
}

/// Generate the backend code that will perform code generation at compile-time
/// This is Pass 2 of the Koru compiler - the Zig backend
fn generateBackendCode(allocator: std.mem.Allocator, serialized_ast: []const u8, input_file: []const u8, source_file: *ast.Program, use_visitor: bool, config: *const CompilerConfig, bootstrap: *const CompilerBootstrap, has_transforms: bool) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, serialized_ast.len + 2048);
    const writer = buffer.writer(allocator);

    // Write header
    try writer.print("// Koru Backend (Pass 2) for: {s}\n", .{input_file});
    try writer.writeAll("// This file IS the compiler backend - it generates final code at compile-time\n\n");

    // Include the serialized AST
    try writer.writeAll(serialized_ast);
    try writer.writeAll("\n\n");

    // Generate CompilerEnv - makes compilation context available at backend comptime
    // Made pub so backend_output_emitted.zig can access it via @import("root")
    try writer.writeAll("/// Compiler Environment - Query compilation context at backend comptime\n");
    try writer.writeAll("pub const CompilerEnv = struct {\n");
    try writer.writeAll("    /// Check if a compiler flag is set\n");
    try writer.writeAll("    pub fn hasFlag(comptime name: []const u8) bool {\n");

    // Generate comptime switch for all flags
    if (config.flags.items.len == 0) {
        try writer.writeAll("        _ = name;\n");
        try writer.writeAll("        return false;\n");
    } else {
        try writer.writeAll("        inline for (&[_][]const u8{\n");
        for (config.flags.items) |flag| {
            try writer.print("            \"{s}\",\n", .{flag});
        }
        try writer.writeAll("        }) |flag| {\n");
        try writer.writeAll("            if (std.mem.eql(u8, name, flag)) return true;\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("        return false;\n");
    }
    try writer.writeAll("    }\n\n");

    try writer.writeAll("    /// Get environment variable value\n");
    try writer.writeAll("    pub fn getEnv(comptime key: []const u8) ?[]const u8 {\n");
    if (config.env_vars.count() == 0) {
        try writer.writeAll("        _ = key;\n");
        try writer.writeAll("        return null;\n");
    } else {
        var env_it = config.env_vars.iterator();
        var first = true;
        while (env_it.next()) |entry| {
            if (first) {
                try writer.print("        if (std.mem.eql(u8, key, \"{s}\")) return \"{s}\";\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            } else {
                try writer.print("        if (std.mem.eql(u8, key, \"{s}\")) return \"{s}\";\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
        try writer.writeAll("        return null;\n");
    }
    try writer.writeAll("    }\n");
    try writer.writeAll("};\n\n");

    // NOTE: Transform handlers are now generated into backend_output_emitted.zig
    // See generateComptimeBackendEmitted() for the call to generateTransformHandlersToEmitter()

    // Choose which backend implementation to use
    if (use_visitor) {
        // Use the new visitor pattern implementation
        try writer.writeAll("// Using Visitor Pattern Backend\n\n");
        try generateVisitorBackend(writer, allocator, source_file);
    } else {
        // Use the old implementation
        try writer.writeAll("// Metacircular Code Generator\n\n");

        // Standard library import - needed by compiler proc handlers (e.g., allocator in execute_module_init_flows)
        try writer.writeAll("const std = @import(\"std\");\n");
        // Import libraries used by multiple compiler procs
        try writer.writeAll("const fusion_optimizer = @import(\"fusion_optimizer\");\n");
        try writer.writeAll("const ast_functional = @import(\"ast_functional\");\n");
        // Library-first architecture: Import reusable build.zig generation library
        try writer.writeAll("const emit_build_zig = @import(\"emit_build_zig\");\n");
        // Import comptime handlers (available during backend compilation)
        try writer.writeAll("const backend_output = @import(\"backend_output_emitted.zig\");\n\n");

        // Note: comptime_main() is now called from compiler.passes.evaluate_comptime
        // It executes at Zig runtime (when ./backend runs), not Zig comptime

        // Re-export transform dispatcher if it exists (makes it available via @import("root"))
        // This allows evaluate_comptime pass to call Root.process_all_transforms()
        if (has_transforms) {
            try writer.writeAll(
                \\// Re-export transform dispatcher to make it available via @import("root")
                \\pub const process_all_transforms = backend_output.process_all_transforms;
                \\
                \\
            );
        }

        // Note: emitter_lib, visitor_emitter_lib, and tap_registry_module are imported inside compiler.emit.zig proc

        // NO MANUAL RECONSTRUCTION NEEDED!
        //
        // The visitor emitter already emitted ALL handlers to backend_output_emitted.zig,
        // including the user's compiler.coordinate override (if any).
        //
        // Backend.zig will import backend_output_emitted.zig and call the handlers from there.
        //
        // This eliminates:
        //   - Manual string construction bugs
        //   - Keyword escaping issues (error vs @"error")
        //   - Code duplication between visitor emitter and manual reconstruction
        //
        // The compiler is now FULLY metacircular - all code emission goes through
        // the same visitor emitter that emits user code!

        // All checker passes now come from compiler.kz (imported via backend_output)

        // Emit helper functions needed by comptime handlers
        try writer.writeAll(
            \\// Helper: Join path segments with dots
            \\const joinPath = struct {
            \\    fn call(path: []const []const u8) []const u8 {
            \\        if (path.len == 0) return "";
            \\        if (path.len == 1) return path[0];
            \\        var total_len: usize = path[0].len;
            \\        var i: usize = 1;
            \\        while (i < path.len) : (i += 1) {
            \\            total_len += 1 + path[i].len;
            \\        }
            \\        var result: [256]u8 = undefined;
            \\        var pos: usize = 0;
            \\        @memcpy(result[pos..pos + path[0].len], path[0]);
            \\        pos += path[0].len;
            \\        i = 1;
            \\        while (i < path.len) : (i += 1) {
            \\            result[pos] = '.';
            \\            pos += 1;
            \\            @memcpy(result[pos..pos + path[i].len], path[i]);
            \\            pos += path[i].len;
            \\        }
            \\        return result[0..pos];
            \\    }
            \\}.call;
            \\
            \\
        );

        // ============================================================================
        // COMPTIME FLOW THUNKS - Enable branch handlers for comptime events
        // ============================================================================
        // Comptime flows (flows invoking events with Source/ProgramAST params)
        // exist in TWO forms:
        //   1. AST (data) - serialized in PROGRAM_AST for compiler passes to analyze
        //   2. Thunks (executable) - emitted here so branch handlers can execute
        //
        // This enables:
        //   - Multiple ~build:requires calls (each gets own thunk)
        //   - Branch handlers work (they're executable code, not data)
        //   - Compiler passes can call executeComptimeFlowThunk(ast_index)
        // ============================================================================

        // Step 1: Build map of comptime event names
        // NOTE: Events with Source/ProgramAST parameters are [comptime|transform] events
        // Flows invoking them should be transformed at runtime, NOT executed as comptime thunks
        // For now, we SKIP these from comptime thunk generation (user guidance: postpone top-level comptime flows)
        var comptime_event_names = try std.ArrayList([]const u8).initCapacity(allocator, 16);
        defer comptime_event_names.deinit(allocator);

        // Also track transform events (Source/ProgramAST params) to exclude from comptime thunks
        var transform_event_names = try std.ArrayList([]const u8).initCapacity(allocator, 16);
        defer transform_event_names.deinit(allocator);

        for (source_file.items) |item| {
            if (item == .event_decl) {
                const event = item.event_decl;

                // Skip compiler.* events - they're handled separately
                if (event.path.segments.len > 0 and std.mem.eql(u8, event.path.segments[0], "compiler")) {
                    continue;
                }

                // Check if this is a comptime event (Source/ProgramAST parameters)
                var is_comptime = false;
                for (event.input.fields) |field| {
                    if (field.is_source) {
                        is_comptime = true;
                        break;
                    }
                    if (std.mem.eql(u8, field.type, "ProgramAST") or
                        std.mem.eql(u8, field.type, "Program") or
                        std.mem.eql(u8, field.type, "*const Program"))
                    {
                        is_comptime = true;
                        break;
                    }
                }

                if (is_comptime) {
                    // Build event name: module:event or just event
                    var event_name_buf: [256]u8 = undefined;
                    var event_name_len: usize = 0;

                    if (event.path.module_qualifier) |mq| {
                        @memcpy(event_name_buf[0..mq.len], mq);
                        event_name_len += mq.len;
                        event_name_buf[event_name_len] = ':';
                        event_name_len += 1;
                    }

                    for (event.path.segments, 0..) |seg, i| {
                        if (i > 0) {
                            event_name_buf[event_name_len] = '.';
                            event_name_len += 1;
                        }
                        @memcpy(event_name_buf[event_name_len .. event_name_len + seg.len], seg);
                        event_name_len += seg.len;
                    }

                    const event_name = try allocator.dupe(u8, event_name_buf[0..event_name_len]);
                    // Events with Source/ProgramAST are [comptime|transform] - add to transform list, NOT comptime thunks
                    try transform_event_names.append(allocator, event_name);
                }
            }

            // Also check events in imported modules
            if (item == .module_decl) {
                const module = item.module_decl;
                for (module.items) |mod_item| {
                    if (mod_item == .event_decl) {
                        const event = mod_item.event_decl;

                        // Skip compiler.* events
                        if (event.path.segments.len > 0 and std.mem.eql(u8, event.path.segments[0], "compiler")) {
                            continue;
                        }

                        // Check if this is a comptime event
                        var is_comptime = false;
                        for (event.input.fields) |field| {
                            if (field.is_source) {
                                is_comptime = true;
                                break;
                            }
                            if (std.mem.eql(u8, field.type, "ProgramAST") or
                                std.mem.eql(u8, field.type, "Program") or
                                std.mem.eql(u8, field.type, "*const Program"))
                            {
                                is_comptime = true;
                                break;
                            }
                        }

                        if (is_comptime) {
                            // Build event name with FULL module qualifier from module's logical_name
                            // For $std/taps, logical_name is "std.taps", we want "std.taps:tap"
                            // This matches what keyword resolution produces
                            var event_name_buf: [256]u8 = undefined;
                            var event_name_len: usize = 0;

                            // Use full module logical_name as qualifier
                            const module_qualifier = module.logical_name;

                            if (module_qualifier.len > 0) {
                                const mq = module_qualifier;
                                @memcpy(event_name_buf[0..mq.len], mq);
                                event_name_len += mq.len;
                                event_name_buf[event_name_len] = ':';
                                event_name_len += 1;
                            }

                            for (event.path.segments, 0..) |seg, i| {
                                if (i > 0) {
                                    event_name_buf[event_name_len] = '.';
                                    event_name_len += 1;
                                }
                                @memcpy(event_name_buf[event_name_len .. event_name_len + seg.len], seg);
                                event_name_len += seg.len;
                            }

                            const event_name = try allocator.dupe(u8, event_name_buf[0..event_name_len]);
                            // Events with Source/ProgramAST are [comptime|transform] - add to transform list, NOT comptime thunks
                            try transform_event_names.append(allocator, event_name);
                        }
                    }
                }
            }
        }

        // Debug: Print detected transform events (events with Source/ProgramAST params)
        if (transform_event_names.items.len > 0) {
            std.debug.print("\n=== TRANSFORM EVENT DETECTION ===\n", .{});
            for (transform_event_names.items) |name| {
                std.debug.print("  Detected transform event: {s}\n", .{name});
            }
            std.debug.print("=================================\n\n", .{});
        }

        // Step 2: Find comptime flows
        const ComptimeFlowInfo = struct {
            ast_index: usize,
            flow: *const ast.Flow,
        };
        var comptime_flows = try std.ArrayList(ComptimeFlowInfo).initCapacity(allocator, 16);
        defer comptime_flows.deinit(allocator);

        for (source_file.items, 0..) |*item, idx| {
            if (item.* == .flow) {
                const flow = &item.flow;

                // Build invoked event name
                var inv_name_buf: [256]u8 = undefined;
                var inv_name_len: usize = 0;

                if (flow.invocation.path.module_qualifier) |mq| {
                    @memcpy(inv_name_buf[0..mq.len], mq);
                    inv_name_len += mq.len;
                    inv_name_buf[inv_name_len] = ':';
                    inv_name_len += 1;
                }

                for (flow.invocation.path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        inv_name_buf[inv_name_len] = '.';
                        inv_name_len += 1;
                    }
                    @memcpy(inv_name_buf[inv_name_len .. inv_name_len + seg.len], seg);
                    inv_name_len += seg.len;
                }

                const inv_name = inv_name_buf[0..inv_name_len];

                // Check if this flow invokes a comptime event OR a transform event
                var matched = false;
                for (comptime_event_names.items) |comptime_name| {
                    if (std.mem.eql(u8, inv_name, comptime_name)) {
                        std.debug.print("  [MATCH] Flow '{s}' (idx={}) matches comptime event '{s}'\n", .{ inv_name, idx, comptime_name });
                        try comptime_flows.append(allocator, .{
                            .ast_index = idx,
                            .flow = flow,
                        });
                        std.debug.print("    → Appended to comptime_flows, now {} items\n", .{comptime_flows.items.len});
                        matched = true;
                        break;
                    }
                }
                // Also check transform events (like std.taps:tap)
                if (!matched) {
                    for (transform_event_names.items) |transform_name| {
                        if (std.mem.eql(u8, inv_name, transform_name)) {
                            std.debug.print("  [MATCH-TRANSFORM] Flow '{s}' (idx={}) matches transform event '{s}'\n", .{ inv_name, idx, transform_name });
                            try comptime_flows.append(allocator, .{
                                .ast_index = idx,
                                .flow = flow,
                            });
                            std.debug.print("    → Appended to comptime_flows, now {} items\n", .{comptime_flows.items.len});
                            break;
                        }
                    }
                }
            }

            // Also check flows in imported modules (though typically flows are top-level)
            if (item.* == .module_decl) {
                const module = item.module_decl;
                for (module.items) |*mod_item| {
                    if (mod_item.* == .flow) {
                        const flow = &mod_item.flow;

                        // Build invoked event name
                        var inv_name_buf: [256]u8 = undefined;
                        var inv_name_len: usize = 0;

                        if (flow.invocation.path.module_qualifier) |mq| {
                            @memcpy(inv_name_buf[0..mq.len], mq);
                            inv_name_len += mq.len;
                            inv_name_buf[inv_name_len] = ':';
                            inv_name_len += 1;
                        }

                        for (flow.invocation.path.segments, 0..) |seg, i| {
                            if (i > 0) {
                                inv_name_buf[inv_name_len] = '.';
                                inv_name_len += 1;
                            }
                            @memcpy(inv_name_buf[inv_name_len .. inv_name_len + seg.len], seg);
                            inv_name_len += seg.len;
                        }

                        const inv_name = inv_name_buf[0..inv_name_len];

                        // Check if this flow invokes a comptime event OR transform event
                        var matched = false;
                        for (comptime_event_names.items) |comptime_name| {
                            if (std.mem.eql(u8, inv_name, comptime_name)) {
                                std.debug.print("  [MATCH-MODULE] Flow '{s}' in module matches comptime event '{s}'\n", .{ inv_name, comptime_name });
                                // Note: Using top-level index for module flows
                                // The AST walker will need to handle this correctly
                                try comptime_flows.append(allocator, .{
                                    .ast_index = idx, // Points to the module_decl item
                                    .flow = flow,
                                });
                                matched = true;
                                break;
                            }
                        }
                        // Also check transform events (like std.taps:tap)
                        if (!matched) {
                            for (transform_event_names.items) |transform_name| {
                                if (std.mem.eql(u8, inv_name, transform_name)) {
                                    std.debug.print("  [MATCH-MODULE-TRANSFORM] Flow '{s}' in module matches transform event '{s}'\n", .{ inv_name, transform_name });
                                    try comptime_flows.append(allocator, .{
                                        .ast_index = idx,
                                        .flow = flow,
                                    });
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Debug: Print detected comptime flows
        if (comptime_flows.items.len > 0) {
            std.debug.print("\n=== COMPTIME FLOW DETECTION ===\n", .{});
            for (comptime_flows.items) |flow_info| {
                const flow = flow_info.flow;
                // Build invocation name for display
                var inv_name_buf: [256]u8 = undefined;
                var inv_name_len: usize = 0;
                if (flow.invocation.path.module_qualifier) |mq| {
                    @memcpy(inv_name_buf[0..mq.len], mq);
                    inv_name_len += mq.len;
                    inv_name_buf[inv_name_len] = ':';
                    inv_name_len += 1;
                }
                for (flow.invocation.path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        inv_name_buf[inv_name_len] = '.';
                        inv_name_len += 1;
                    }
                    @memcpy(inv_name_buf[inv_name_len .. inv_name_len + seg.len], seg);
                    inv_name_len += seg.len;
                }
                const inv_name = inv_name_buf[0..inv_name_len];
                std.debug.print("  Detected comptime flow: {s} (ast_index={})\n", .{ inv_name, flow_info.ast_index });
            }
            std.debug.print("===============================\n\n", .{});
        }

        // Build a map of module aliases to full module paths
        // This is needed to resolve handler names in thunks
        // e.g. flow says "build:requires" but handler is "std_build_requires_handler"
        var module_alias_map = std.StringHashMap([]const u8).init(allocator);
        defer module_alias_map.deinit();

        for (source_file.items) |item| {
            if (item == .module_decl) {
                const module = item.module_decl;
                // Extract last segment of logical_name as the alias
                // "std.build" → alias "build"
                if (std.mem.lastIndexOf(u8, module.logical_name, ".")) |dot_idx| {
                    const alias = module.logical_name[dot_idx + 1 ..];
                    try module_alias_map.put(alias, module.logical_name);
                } else {
                    // No dot, use whole name
                    try module_alias_map.put(module.logical_name, module.logical_name);
                }
            }
        }

        // Step 3: Emit thunks, mapping, and helper (only if we found comptime flows)
        if (comptime_flows.items.len > 0) {
            try writer.writeAll(
                \\// Comptime flow thunks - executable functions for comptime flows
                \\const comptime_flow_thunks = struct {
                \\
            );

            for (comptime_flows.items, 0..) |info, thunk_idx| {
                const flow = info.flow;

                try writer.writeAll("    fn flow_");
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{thunk_idx});
                try writer.writeAll(num_str);
                try writer.writeAll("() void {\n");

                // Call handler from backend_output with full module path
                // Use __thunk_result to avoid shadowing user bindings like |result|
                try writer.writeAll("        const __thunk_result = ");
                if (flow.invocation.path.module_qualifier) |mq| {
                    // Module-qualified event: backend_output.koru_<module>.<event>_event
                    try writer.writeAll("backend_output.koru_");
                    // Resolve alias to full module path
                    if (module_alias_map.get(mq)) |full_path| {
                        try writer.writeAll(full_path);
                    } else {
                        try writer.writeAll(mq);
                    }
                    try writer.writeAll(".");
                    for (flow.invocation.path.segments, 0..) |seg, i| {
                        if (i > 0) try writer.writeAll("_");
                        try writer.writeAll(seg);
                    }
                } else {
                    // Local event: backend_output.main_module.<event>_event
                    try writer.writeAll("backend_output.main_module.");
                    for (flow.invocation.path.segments, 0..) |seg, i| {
                        if (i > 0) try writer.writeAll("_");
                        try writer.writeAll(seg);
                    }
                }
                try writer.writeAll("_event.handler(.{");

                for (flow.invocation.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(" .");
                    try writer.writeAll(arg.name);
                    try writer.writeAll(" = ");

                    // Always quote and escape Source parameter values
                    // Anonymous block content is raw text that needs escaping
                    try writer.writeAll("\"");
                    for (arg.value) |c| {
                        switch (c) {
                            '\n' => try writer.writeAll("\\n"),
                            '\r' => try writer.writeAll("\\r"),
                            '\t' => try writer.writeAll("\\t"),
                            '\\' => try writer.writeAll("\\\\"),
                            '"' => try writer.writeAll("\\\""),
                            else => try writer.writeByte(c),
                        }
                    }
                    try writer.writeAll("\"");
                }

                try writer.writeAll(" });\n");
                try writer.writeAll("        switch (__thunk_result) {\n");

                for (flow.continuations) |cont| {
                    try writer.writeAll("            .");
                    try writeBranchName(writer, cont.branch);
                    try writer.writeAll(" => ");

                    if (cont.binding) |binding| {
                        try writer.writeAll("|");
                        try writer.writeAll(binding);
                        try writer.writeAll("| ");
                    }

                    try writer.writeAll("{\n");

                    // Suppress unused binding warning
                    if (cont.binding) |binding| {
                        try writer.writeAll("                _ = &");
                        try writer.writeAll(binding);
                        try writer.writeAll(";\n");
                    }

                    if (cont.node) |step| {
                        try writer.writeAll("                ");
                        switch (step) {
                            .invocation => |inv| {
                                // Call the handler from backend_output
                                try writer.writeAll("_ = ");
                                if (inv.path.module_qualifier) |mq| {
                                    // Module-qualified event: backend_output.koru_<module>.<event>_event
                                    try writer.writeAll("backend_output.koru_");
                                    if (module_alias_map.get(mq)) |full_path| {
                                        try writer.writeAll(full_path);
                                    } else {
                                        try writer.writeAll(mq);
                                    }
                                    try writer.writeAll(".");
                                    for (inv.path.segments, 0..) |seg, i| {
                                        if (i > 0) try writer.writeAll("_");
                                        try writer.writeAll(seg);
                                    }
                                } else {
                                    // Local event: backend_output.main_module.<event>_event
                                    try writer.writeAll("backend_output.main_module.");
                                    for (inv.path.segments, 0..) |seg, i| {
                                        if (i > 0) try writer.writeAll("_");
                                        try writer.writeAll(seg);
                                    }
                                }
                                try writer.writeAll("_event.handler(.{");
                                // For now, use a simple heuristic: if arg.name starts with quote, it's positional
                                // and we use "text" as the field name (works for println, print, etc.)
                                for (inv.args, 0..) |arg, i| {
                                    if (i > 0) try writer.writeAll(", ");
                                    try writer.writeAll(" .");
                                    // Check if this is a positional argument (name starts with quote or is the value)
                                    if (arg.name.len > 0 and (arg.name[0] == '"' or std.mem.eql(u8, arg.name, arg.value))) {
                                        // Positional argument - use "text" as field name for now
                                        try writer.writeAll("text");
                                    } else {
                                        try writer.writeAll(arg.name);
                                    }
                                    try writer.writeAll(" = ");
                                    // Heuristic: values that are Koru syntax need to be stringified
                                    // - Struct literals: { ... }
                                    // - Range literals: 0..3
                                    // Other values (identifiers, field access) should remain as expressions
                                    const needs_quoting = arg.value.len > 0 and
                                        (arg.value[0] == '{' or std.mem.indexOf(u8, arg.value, "..") != null);
                                    if (needs_quoting) {
                                        try writer.writeAll("\"");
                                        for (arg.value) |c| {
                                            switch (c) {
                                                '\n' => try writer.writeAll("\\n"),
                                                '\r' => try writer.writeAll("\\r"),
                                                '\t' => try writer.writeAll("\\t"),
                                                '\\' => try writer.writeAll("\\\\"),
                                                '"' => try writer.writeAll("\\\""),
                                                else => try writer.writeByte(c),
                                            }
                                        }
                                        try writer.writeAll("\"");
                                    } else {
                                        try writer.writeAll(arg.value);
                                    }
                                }
                                try writer.writeAll(" });\n");
                            },
                            .terminal => {},
                            else => {
                                try writer.writeAll("// TODO: Handle step type\n");
                            },
                        }
                    }

                    try writer.writeAll("            },\n");
                }

                try writer.writeAll("        }\n");
                try writer.writeAll("    }\n\n");
            }

            try writer.writeAll(
                \\};
                \\
                \\const comptime_flow_mapping = &[_]struct {
                \\    ast_index: usize,
                \\    executor: *const fn() void,
                \\}{
                \\
            );

            for (comptime_flows.items, 0..) |info, thunk_idx| {
                try writer.writeAll("    .{ .ast_index = ");
                var idx_buf: [32]u8 = undefined;
                const idx_str = try std.fmt.bufPrint(&idx_buf, "{d}", .{info.ast_index});
                try writer.writeAll(idx_str);
                try writer.writeAll(", .executor = &comptime_flow_thunks.flow_");
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{thunk_idx});
                try writer.writeAll(num_str);
                try writer.writeAll(" },\n");
            }

            try writer.writeAll(
                \\};
                \\
                \\
            );
        }

        // Find the compiler module's logical name
        // CRITICAL: The compiler module MUST be present for backend generation to work
        // If it's not found, something is seriously wrong (import failed, not injected, etc.)
        var compiler_module_name: ?[]const u8 = null;
        for (source_file.items) |item| {
            if (item == .module_decl) {
                const module = item.module_decl;
                // Look for the module containing compiler events
                // It should have canonical_path containing "compiler.kz"
                if (std.mem.indexOf(u8, module.canonical_path, "compiler.kz") != null) {
                    compiler_module_name = module.logical_name;
                    break;
                }
            }
        }

        // NO FALLBACK - if compiler module not found, FAIL LOUDLY
        if (compiler_module_name == null) {
            std.debug.print("\n✗✗✗ FATAL: Compiler module not found in source_file.items ✗✗✗\n", .{});
            std.debug.print("Backend generation requires the compiler module to be imported.\n", .{});
            std.debug.print("This should have been auto-injected during parsing.\n", .{});
            return error.CompilerModuleNotFound;
        }

        const compiler_module = compiler_module_name.?; // Safe unwrap - we just checked

        // ============================================================================
        // FRONTEND BOOTSTRAP COORDINATOR (Hardcoded Zig Fallback)
        //
        // This is the FRONTEND compiler coordinator used during `zig build-exe backend.zig`.
        // It's hardcoded in Zig because it runs at Zig compile-time to bootstrap the compiler,
        // before any Koru runtime exists.
        //
        // IMPORTANT: The BACKEND coordinator (used by compiled programs) IS implemented as
        // Koru flows in koru_std/compiler.kz and emitted to backend_output_emitted.zig!
        // See RuntimeEmitter.emit() at lines 1140-1143 for where it calls the Koru flows.
        //
        // Two stages:
        //   FRONTEND (this code): Compiles compiler.kz → backend.zig (hardcoded Zig)
        //   BACKEND (Koru flows): Compiles user code using flows from compiler.kz
        //
        // To modify the FRONTEND bootstrap, edit this function.
        // To modify the BACKEND compiler, edit koru_std/compiler.kz (those are actual Koru flows!)
        //
        // Pipeline passes (in order):
        //   1. process_ccp_commands  - Reads AI commands from stdin (when --ccp enabled)
        //   2. evaluate_comptime     - Executes comptime events to transform AST
        //   3. check.structure       - Validates event/branch shapes exist
        //   4. check.phantom.semantic - Validates phantom type compatibility
        //   5. inject_ccp            - Adds observability taps (when --ccp + import)
        //   6. emit.zig              - Generates final Zig code
        // ============================================================================
        // TODO: Eventually replace with pure Koru subflow from compiler.kz
        try writer.writeAll("// Import CompilerContext types and handlers from backend_output_emitted\n");
        try writer.writeAll("const bootstrap = backend_output.koru_");
        try writer.writeAll(compiler_module);
        try writer.writeAll(
            \\;
            \\const CompilerContext = bootstrap.CompilerContext;
            \\const CompilerError = bootstrap.CompilerError;
            \\const CompilerWarning = bootstrap.CompilerWarning;
            \\const ErrorPolicy = bootstrap.ErrorPolicy;
            \\const compiler_passes_process_ccp_commands = bootstrap.compiler_passes_process_ccp_commands_event;
            \\const compiler_passes_evaluate_comptime = bootstrap.compiler_passes_evaluate_comptime_event;
            \\const compiler_check_structure = bootstrap.compiler_check_structure_event;
            \\const compiler_check_phantom_semantic = bootstrap.compiler_check_phantom_semantic_event;
            \\const compiler_passes_inject_ccp = bootstrap.compiler_passes_inject_ccp_event;
            \\const compiler_emit_zig = bootstrap.compiler_emit_zig_event;
            \\
            \\// FRONTEND BOOTSTRAP COORDINATOR (hardcoded Zig fallback)
            \\// This is only used during frontend compilation (zig build-exe backend.zig).
            \\// The actual BACKEND coordinator IS a Koru flow (see backend_output_emitted.zig)!
            \\const compiler_coordinate_default = struct {
            \\    pub const Input = struct { ast: *const Program, allocator: std.mem.Allocator };
            \\    pub const Output = union(enum) {
            \\        coordinated: struct {
            \\            ast: *const Program,
            \\            code: []const u8,
            \\            metrics: []const u8,
            \\        },
            \\    };
            \\
            \\    pub fn handler(__koru_event_input: Input) !Output {
            \\        const __koru_std = @import("std");
            \\
            \\        // Create CompilerContext
            \\        var ctx = CompilerContext{
            \\            .ast = __koru_event_input.ast,
            \\            .allocator = __koru_event_input.allocator,
            \\            .errors = __koru_std.ArrayList(CompilerError){},
            \\            .warnings = __koru_std.ArrayList(CompilerWarning){},
            \\            .error_policy = .collect_all,
            \\            .current_pass = null,
            \\            .passes_completed = 0,
            \\        };
            \\        defer ctx.errors.deinit(__koru_event_input.allocator);
            \\        defer ctx.warnings.deinit(__koru_event_input.allocator);
            \\
            \\        // Execute the compilation pipeline using CompilerContext threading:
            \\        // 1. process_ccp_commands
            \\        const ccp_result = compiler_passes_process_ccp_commands.handler(.{ .ctx = ctx });
            \\        ctx = ccp_result.continued.ctx;
            \\
            \\        // 2. evaluate_comptime
            \\        const eval_result = compiler_passes_evaluate_comptime.handler(.{ .ctx = ctx });
            \\        ctx = eval_result.continued.ctx;
            \\
            \\        // 3. check.structure
            \\        const structure_result = compiler_check_structure.handler(.{ .ctx = ctx });
            \\        ctx = structure_result.continued.ctx;
            \\        if (ctx.errors.items.len > 0) {
            \\            std.debug.print("❌ Structural validation failed: {d} errors\n", .{ctx.errors.items.len});
            \\            return error.StructuralValidationFailed;
            \\        }
            \\
            \\        // 4. check.phantom.semantic
            \\        const phantom_result = compiler_check_phantom_semantic.handler(.{ .ctx = ctx });
            \\        ctx = phantom_result.continued.ctx;
            \\        if (ctx.errors.items.len > 0) {
            \\            std.debug.print("❌ Phantom validation failed: {d} errors\n", .{ctx.errors.items.len});
            \\            return error.PhantomTypeValidationFailed;
            \\        }
            \\
            \\        // 5. inject_ccp
            \\        const ccp_inject_result = compiler_passes_inject_ccp.handler(.{ .ctx = ctx });
            \\        ctx = ccp_inject_result.continued.ctx;
            \\
            \\        // 6. emit.zig
            \\        const emit_result = compiler_emit_zig.handler(.{ .ctx = ctx });
            \\        ctx = emit_result.continued.ctx;
            \\        const code = emit_result.continued.code;
            \\
            \\        // Build metrics string from actual pass count
            \\        const metrics = try __koru_std.fmt.allocPrint(
            \\            __koru_event_input.allocator,
            \\            "Passes: {d} (process_ccp_commands, evaluate_comptime, check.structure, check.phantom.semantic, inject_ccp, emit.zig)",
            \\            .{ctx.passes_completed}
            \\        );
            \\
            \\        return .{ .coordinated = .{
            \\            .ast = ctx.ast,
            \\            .code = code,
            \\            .metrics = metrics,
            \\        }};
            \\    }
            \\};
            \\
        );

        // If user has overridden compiler.coordinate, emit the transpiled handler
        if (bootstrap.has_user_override) {
            try writer.writeAll(
                \\// User-defined compiler.coordinate (from compiler)
                \\const compiler_coordinate_event = bootstrap.compiler_coordinate_event;
                \\
            );
        }

        // Add compile-time code generation
        try writer.writeAll(
            \\// Runtime emitter (moved from comptime to support fusion optimization)
            \\const RuntimeEmitter = struct {
            \\    pub fn emit(allocator: std.mem.Allocator, source_ast: *const Program) ![]const u8 {
            \\
        );

        // Choose which coordinator to call based on user override
        // Both handlers are in backend_output_emitted.zig (emitted by visitor emitter!)
        // The user's override is emitted in the same namespace as the event declaration (compiler)
        if (bootstrap.has_user_override) {
            try writer.writeAll("        // Using user-defined compiler.coordinate from backend_output!\n");
            try writer.writeAll("        // User's implementation is emitted in koru_");
            try writer.writeAll(compiler_module);
            try writer.writeAll(" namespace\n");
            try writer.writeAll("        const result = backend_output.koru_");
            try writer.writeAll(compiler_module);
            try writer.writeAll(".compiler_coordinate_event.handler(.{ .program_ast = source_ast, .allocator = allocator });\n\n");
        } else {
            try writer.writeAll("        // Using default compiler.coordinate from compiler (in backend_output)\n");
            try writer.writeAll("        const result = backend_output.koru_");
            try writer.writeAll(compiler_module);
            try writer.writeAll(".compiler_coordinate_default_event.handler(.{ .program_ast = source_ast, .allocator = allocator });\n\n");
        }

        try writer.writeAll(
            \\        // Handle both success and error branches
            \\        switch (result) {
            \\            .coordinated => |r| {
            \\                std.debug.print("🎯 Compiler coordination: {s}\n", .{r.metrics});
            \\                return r.code;
            \\            },
            \\            .@"error" => |e| {
            \\                std.debug.print("❌ Compiler coordination error: {s}\n", .{e.message});
            \\                return error.CompilerCoordinationFailed;
            \\            },
            \\        }
            \\    }
            \\};
            \\
        );

        // AST dump helper for observability during development (backend.zig version - no JSON)
        try writer.writeAll(
            \\// AST Dump Helper - observability for compiler pipeline debugging
            \\// Note: This version doesn't serialize to JSON (ast_serializer not available in backend.zig)
            \\// Full JSON dumps are available in backend_output_emitted.zig (dump points 3-7)
            \\fn dumpAST(program_ast: *const Program, stage: []const u8, allocator: std.mem.Allocator) void {
            \\    // Check if AST dumping is enabled via environment variable
            \\    const dump_enabled: ?[]const u8 = std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
            \\        if (err == error.EnvironmentVariableNotFound) break :blk null;
            \\        break :blk null;
            \\    };
            \\    defer if (dump_enabled) |val| allocator.free(val);
            \\
            \\    if (dump_enabled == null) return;  // Not enabled
            \\
            \\    std.debug.print("\n============================================================\n", .{});
            \\    std.debug.print("AST DUMP: {s}\n", .{stage});
            \\    std.debug.print("============================================================\n", .{});
            \\    std.debug.print("Items: {d}\n", .{program_ast.items.len});
            \\    std.debug.print("Module: {s}\n", .{program_ast.main_module_name});
            \\    std.debug.print("============================================================\n\n", .{});
            \\}
            \\
        );

        // Backend main() function - now calls emit at runtime
        try writer.writeAll("// === KORU BACKEND CODE GENERATOR ===\n");
        try writer.writeAll("// This outputs the final Zig code generated by compiler.emit.zig\n\n");

        // Backend entry point - compiles the generated code
        try writer.writeAll(
            \\pub fn main() !void {
            \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            \\    defer {
            \\        const leak_status = gpa.deinit();
            \\        if (leak_status == .leak) {
            \\            std.debug.print("Memory leak detected\n", .{});
            \\        }
            \\    }
            \\    const allocator = gpa.allocator();
            \\
            \\    // Arena allocator for compilation phase - all compiler passes, code generation, etc.
            \\    var compile_arena = std.heap.ArenaAllocator.init(allocator);
            \\    defer compile_arena.deinit();
            \\    const compile_allocator = compile_arena.allocator();
            \\
            \\    // Get the output filename from argv (passed from koruc)
            \\    const args = try std.process.argsAlloc(allocator);
            \\    defer std.process.argsFree(allocator, args);
            \\
            \\    // Default output names
            \\    const emitted_file = "output_emitted.zig";
            \\
        );

        // Generate command checking code dynamically
        const cmd_result = try collectCommands(allocator, source_file);
        if (cmd_result.count > 0) {
            try writer.writeAll(
                \\    // Check for CLI commands in argv
                \\    // Note: backend_output is already imported at file scope
                \\    if (args.len > 1) {
                \\        const koru_std = backend_output.koru_std;
                \\
            );

            // Generate command checks
            // Commands call MODULE.EVENT_event.handler(.{ .program = ..., .allocator = ..., .argv = ... })
            for (cmd_result.commands[0..cmd_result.count]) |cmd| {
                var buf: [1024]u8 = undefined;
                if (cmd.module_path) |mod_path| {
                    // Convert std.X to koru_std.X for proper Zig namespace
                    var zig_mod_path: [256]u8 = undefined;
                    const zig_mod = if (std.mem.startsWith(u8, mod_path, "std."))
                        try std.fmt.bufPrint(&zig_mod_path, "koru_std.{s}", .{mod_path[4..]})
                    else
                        mod_path;

                    const line = try std.fmt.bufPrint(&buf,
                        \\        if (std.mem.eql(u8, args[1], "{s}")) {{
                        \\            std.debug.print("🔧 Running command: {s}\n", .{{}});
                        \\            _ = {s}.{s}_event.handler(.{{
                        \\                .program = &PROGRAM_AST,
                        \\                .allocator = allocator,
                        \\                .argv = args[2..],
                        \\            }});
                        \\            return;
                        \\        }}
                        \\
                    , .{ cmd.name, cmd.name, zig_mod, cmd.handler_name });
                    try writer.writeAll(line);
                } else {
                    const line = try std.fmt.bufPrint(&buf,
                        \\        if (std.mem.eql(u8, args[1], "{s}")) {{
                        \\            std.debug.print("🔧 Running command: {s}\n", .{{}});
                        \\            _ = {s}_event.handler(.{{
                        \\                .program = &PROGRAM_AST,
                        \\                .allocator = allocator,
                        \\                .argv = args[2..],
                        \\            }});
                        \\            return;
                        \\        }}
                        \\
                    , .{ cmd.name, cmd.name, cmd.handler_name });
                    try writer.writeAll(line);
                }
            }

            try writer.writeAll(
                \\    }
                \\
            );
        }

        // Continue with normal compilation flow
        try writer.writeAll(
            \\    // NOTE: args[1] is the output exe name when called from frontend,
            \\    // but when running backend directly, args[1] might be the input .kz file.
            \\    // Detect this case and default to "a.out" instead of overwriting the source!
            \\    const output_exe = if (args.len > 1 and !std.mem.endsWith(u8, args[1], ".kz")) args[1] else "a.out";
            \\
            \\    // Check if fusion is enabled
            \\    const fusion_enabled = CompilerEnv.hasFlag("fusion");
            \\
            \\    // Apply compiler passes
            \\    // Each pass takes PROGRAM_AST pointer and current AST pointer
            \\    // Returns same pointer if no changes, or new heap-allocated AST if optimized
            \\    var current_ast: *const Program = &PROGRAM_AST;
            \\
            \\    // DUMP POINT 1: Original AST at backend entry
            \\    dumpAST(&PROGRAM_AST, "1-backend-start", compile_allocator);
            \\
            \\    if (fusion_enabled) {
            \\        current_ast = try fusion_optimizer.optimize(allocator, &PROGRAM_AST, current_ast);
            \\    }
            \\
            \\    // More passes can go here...
            \\
            \\    const final_ast = current_ast;
            \\    defer maybeDeinitAst(final_ast);
            \\
            \\    // DUMP POINT 2: Final AST before emission (after all backend transforms)
            \\    dumpAST(final_ast, "2-pre-emit", compile_allocator);
            \\
            \\    // Generate code from AST (possibly fused)
            \\    const generated_code = try RuntimeEmitter.emit(compile_allocator, final_ast);
            \\
            \\    // DEBUG: Check generated_code before file write
            \\    std.debug.print("\n[MAIN DEBUG] Before file write:\n", .{});
            \\    std.debug.print("[MAIN DEBUG]   generated_code.len = {d}\n", .{generated_code.len});
            \\    std.debug.print("[MAIN DEBUG]   generated_code.ptr = {*}\n", .{generated_code.ptr});
            \\    std.debug.print("[MAIN DEBUG]   emitted_file = {s}\n", .{emitted_file});
            \\    std.debug.print("[MAIN DEBUG]   emitted_file.ptr = {*}\n", .{emitted_file.ptr});
            \\    std.debug.print("[MAIN DEBUG]   First 50 bytes: ", .{});
            \\    for (generated_code[0..@min(50, generated_code.len)]) |byte| {
            \\        if (byte >= 32 and byte < 127) {
            \\            std.debug.print("{c}", .{byte});
            \\        } else {
            \\            std.debug.print("[{d}]", .{byte});
            \\        }
            \\    }
            \\    std.debug.print("\n\n", .{});
            \\
            \\    // Write the generated code to a file
            \\    const file = try std.fs.cwd().createFile(emitted_file, .{});
            \\    defer file.close();
            \\    try file.writeAll(generated_code);
            \\
            \\    // Report what we generated
            \\    const stdout = std.fs.File.stdout();
            \\    var buf: [512]u8 = undefined;
            \\    const msg = try std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, generated_code.len});
            \\    try stdout.writeAll(msg);
            \\
            \\    // Now compile the emitted code using build_output.zig (which has user dependencies like vaxis)
            \\    // First check if build_output.zig exists (has user build requirements)
            \\    const has_build_output = blk: {
            \\        std.fs.cwd().access("build_output.zig", .{}) catch break :blk false;
            \\        break :blk true;
            \\    };
            \\
            \\    if (has_build_output) {
            \\        // Use zig build with build_output.zig (includes user dependencies)
            \\        const argv = [_][]const u8{ "zig", "build", "--build-file", "build_output.zig" };
            \\        const result = std.process.Child.run(.{
            \\            .allocator = allocator,
            \\            .argv = &argv,
            \\        }) catch |err| {
            \\            const stderr = std.fs.File.stderr();
            \\            var err_buf: [512]u8 = undefined;
            \\            const err_msg = try std.fmt.bufPrint(&err_buf, "✗ Failed to spawn zig compiler: {}\n", .{err});
            \\            try stderr.writeAll(err_msg);
            \\            std.process.exit(1);
            \\        };
            \\        defer allocator.free(result.stdout);
            \\        defer allocator.free(result.stderr);
            \\
            \\        const stdout2 = std.fs.File.stdout();
            \\        var buf2: [512]u8 = undefined;
            \\        if (result.term.Exited == 0) {
            \\            // Copy from zig-out/bin/output to the requested output name
            \\            std.fs.cwd().copyFile("zig-out/bin/output", std.fs.cwd(), output_exe, .{}) catch |copy_err| {
            \\                const msg2 = try std.fmt.bufPrint(&buf2, "✗ Failed to copy output: {}\n", .{copy_err});
            \\                try std.fs.File.stderr().writeAll(msg2);
            \\                std.process.exit(1);
            \\            };
            \\            const msg2 = try std.fmt.bufPrint(&buf2, "✓ Compiled to {s}\n", .{output_exe});
            \\            try stdout2.writeAll(msg2);
            \\        } else {
            \\            const msg2 = try std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
            \\            try stdout2.writeAll(msg2);
            \\            if (result.stderr.len > 0) {
            \\                var err_buf2: [65536]u8 = undefined;
            \\                const err_msg2 = try std.fmt.bufPrint(&err_buf2, "Error: {s}\n", .{result.stderr});
            \\                try std.fs.File.stderr().writeAll(err_msg2);
            \\            }
            \\            std.process.exit(1);
            \\        }
            \\    } else {
            \\        // Fall back to direct zig build-exe (no user dependencies)
            \\        var emit_path_buf: [256]u8 = undefined;
            \\        const emit_path = try std.fmt.bufPrint(&emit_path_buf, "-femit-bin={s}", .{output_exe});
            \\        const argv = [_][]const u8{ "zig", "build-exe", emitted_file, "-O", "ReleaseFast", emit_path };
            \\        const result = std.process.Child.run(.{
            \\            .allocator = allocator,
            \\            .argv = &argv,
            \\        }) catch |err| {
            \\            const stderr = std.fs.File.stderr();
            \\            var err_buf: [512]u8 = undefined;
            \\            const err_msg = try std.fmt.bufPrint(&err_buf, "✗ Failed to spawn zig compiler: {}\n", .{err});
            \\            try stderr.writeAll(err_msg);
            \\            std.process.exit(1);
            \\        };
            \\        defer allocator.free(result.stdout);
            \\        defer allocator.free(result.stderr);
            \\
            \\        const stdout2 = std.fs.File.stdout();
            \\        var buf2: [512]u8 = undefined;
            \\        if (result.term.Exited == 0) {
            \\            const msg2 = try std.fmt.bufPrint(&buf2, "✓ Compiled to {s}\n", .{output_exe});
            \\            try stdout2.writeAll(msg2);
            \\        } else {
            \\            const msg2 = try std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
            \\            try stdout2.writeAll(msg2);
            \\            if (result.stderr.len > 0) {
            \\                var err_buf2: [65536]u8 = undefined;
            \\                const err_msg2 = try std.fmt.bufPrint(&err_buf2, "Error: {s}\n", .{result.stderr});
            \\                try std.fs.File.stderr().writeAll(err_msg2);
            \\            }
            \\            std.process.exit(1);
            \\        }
            \\    }
            \\}
        );
    } // End of else block (old implementation)

    return buffer.toOwnedSlice(allocator);
}

const ComptimeBackendResult = struct {
    code: []const u8,
    transform_count: usize,
};

/// Generate backend_output_emitted.zig for comptime modules
/// This generates handlers for events marked with [comptime] annotation
/// These handlers are available during backend.zig compilation
fn generateComptimeBackendEmitted(allocator: std.mem.Allocator, source_file: *ast.Program, type_registry: *TypeRegistry) !ComptimeBackendResult {
    const emitter_helpers = @import("emitter_helpers");
    const visitor_emitter_mod = @import("visitor_emitter");
    const tap_registry_module = @import("tap_registry");

    // Create a large buffer for the generated code
    const MAX_SIZE = 1024 * 1024; // 1MB (increased for complex tap imports)
    const buffer = try allocator.alloc(u8, MAX_SIZE);
    // Note: We'll trim it down before returning

    // Create CodeEmitter
    var code_emitter = emitter_helpers.CodeEmitter.init(buffer);

    // Write header
    try code_emitter.write("// Koru Comptime Backend Handlers\n");
    try code_emitter.write("// Handlers for [comptime] annotated modules, available during backend compilation\n\n");

    // Import AST types as an alias to avoid shadowing/ambiguity
    try code_emitter.write("const __koru_std = @import(\"std\");\n");
    try code_emitter.write("const __koru_ast = @import(\"ast\");\n\n");

    // Add dumpAST helper for observability (backend_output_emitted.zig version)
    try code_emitter.write(
        \\// AST Dump Helper - observability for compiler pipeline debugging
        \\fn dumpAST(program_ast: *const __koru_ast.Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
        \\    // Check if AST dumping is enabled via environment variable
        \\    const dump_enabled: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
        \\        if (err == error.EnvironmentVariableNotFound) break :blk null;
        \\        break :blk null;
        \\    };
        \\    defer if (dump_enabled) |val| allocator.free(val);
        \\
        \\    if (dump_enabled == null) return;  // Not enabled
        \\
        \\    __koru_std.debug.print("\n============================================================\n", .{});
        \\    __koru_std.debug.print("AST DUMP: {s}\n", .{stage});
        \\    __koru_std.debug.print("============================================================\n", .{});
        \\    __koru_std.debug.print("Items: {d}\n", .{program_ast.items.len});
        \\    __koru_std.debug.print("Module: {s}\n", .{program_ast.main_module_name});
        \\    __koru_std.debug.print("============================================================\n\n", .{});
        \\}
        \\
    );

    // NOTE: __koru_std import is handled by visitor_emitter when Profile/Audit metatypes are detected
    // visitor_emitter.zig scans the AST and conditionally emits it to avoid duplicates

    // Build tap registry
    var tap_registry = try tap_registry_module.buildTapRegistry(source_file.items, allocator);
    defer tap_registry.deinit();

    // Transform AST - insert taps before emission
    // Taps are inserted into the AST as regular flow code (zero-cost abstraction!)
    std.debug.print("DEBUG: Running AST transformation in generateComptimeBackendEmitted\n", .{});
    const tap_transformer = @import("tap_transformer");
    const ast_to_emit = try tap_transformer.transformAst(source_file, &tap_registry, .comptime_only, allocator);

    // Create visitor emitter with comptime_only mode
    // This will emit ONLY modules with [comptime] annotation
    var visitor_emitter = visitor_emitter_mod.VisitorEmitter.init(allocator, &code_emitter, ast_to_emit.items, &tap_registry, type_registry, .comptime_only // Emit only modules with [comptime] annotation
    );

    // Emit using visitor pattern!
    // The visitor will automatically filter to only [comptime] modules via shouldFilter
    try visitor_emitter.emit(ast_to_emit);

    // Generate transform handlers into backend_output_emitted.zig
    // These need to be in the same file as evaluate_comptime so it can call them
    const transform_count = try generateTransformHandlersToEmitter(&code_emitter, allocator, source_file);

    // Get the generated code and trim to actual size
    const generated = code_emitter.getOutput();
    return ComptimeBackendResult{
        .code = try allocator.dupe(u8, generated),
        .transform_count = transform_count,
    };
}

/// TransformEvent stores both the underscore name (for stubs) and dotted name (for matching)
/// Transforms are compiler passes: Program -> transformed{Program} | failed{error}
/// Also used for derive handlers which generate new declarations from event declarations
/// Detection is TYPE-DRIVEN: *const Invocation = transform, *const EventDecl = derive
const TransformEvent = struct {
    stub_name: []const u8,    // e.g., "control_if" - unique name for call_handler_X function
    match_name: []const u8,   // e.g., "if" - event name with dots for matching
    event_name: []const u8,   // e.g., "if" - original event name for handler struct lookup
    module_path: ?[]const u8, // e.g., "koru_std.control" for stdlib, null for main_module
    has_source: bool,         // Event accepts source: Source[T] parameter
    has_expression: bool,     // Event accepts expr: Expression parameter
    has_invocation: bool,     // Event accepts invocation: *const Invocation parameter
    has_event_decl: bool,     // Event accepts event_decl: *const EventDecl parameter
    has_item: bool,           // Event accepts item: *const Item parameter
    has_program_ast: bool,    // Event accepts program: *const Program parameter
    has_allocator: bool,      // Event accepts allocator: std.mem.Allocator parameter
    returns_program: bool,    // Event returns transformed{ program: *const Program }
    has_failed: bool,         // Event has failed{ error: []const u8 } branch
};

/// CommandInfo stores CLI command metadata for [comptime|command] events
/// Commands run instead of normal compilation when invoked via `koruc file.kz <command>`
const CommandInfo = struct {
    name: []const u8,         // e.g., "install" - command name for CLI
    handler_name: []const u8, // e.g., "package_install" - Zig function name
    module_path: ?[]const u8, // e.g., "koru_std.package" for stdlib commands
};

/// Collect all [comptime|command] events from the AST
fn collectCommands(allocator: std.mem.Allocator, source_file: *ast.Program) !struct { commands: [16]CommandInfo, count: usize } {
    var commands: [16]CommandInfo = undefined;
    var count: usize = 0;

    // Scan top-level events
    for (source_file.items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;
            const has_command = annotation_parser.hasPart(event_decl.annotations, "command");

            if (has_command and count < 16) {
                const name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);
                const handler_name = try joinPathSegments(allocator, event_decl.path.segments);

                commands[count] = .{
                    .name = name,
                    .handler_name = handler_name,
                    .module_path = null,
                };
                count += 1;
            }
        }

        // Also check imported modules
        if (item == .module_decl) {
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .event_decl) {
                    const event_decl = mod_item.event_decl;
                    const has_command = annotation_parser.hasPart(event_decl.annotations, "command");

                    if (has_command and count < 16) {
                        const name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);
                        // Handler name is just the event name (e.g., "install")
                        // The full path koru_std.package.install_event.handler is built at codegen
                        const handler_name = try joinPathSegments(allocator, event_decl.path.segments);

                        commands[count] = .{
                            .name = name,
                            .handler_name = handler_name,
                            .module_path = module.logical_name,
                        };
                        count += 1;
                    }
                }
            }
        }
    }

    return .{ .commands = commands, .count = count };
}

/// Generate transform handler calling code for [comptime|transform] events
/// This scans for events with [comptime|transform] annotations and generates
/// Zig functions that the backend can call to perform transformations
fn generateTransformHandlers(writer: anytype, allocator: std.mem.Allocator, source_file: *ast.Program) !void {
    try writer.writeAll("// Transform Handler Calling Code\n");
    try writer.writeAll("// Generated by frontend for [comptime|transform] events\n\n");

    // First pass: Collect all transform events (max 16 transform events per file)
    var transform_events: [16]TransformEvent = undefined;
    var transform_count: usize = 0;

    for (source_file.items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;

            // Check if this event has [transform] annotation
            const has_transform = annotation_parser.hasPart(event_decl.annotations, "transform");

            if (has_transform and transform_count < 16) {
                const stub_name = try joinPathSegments(allocator, event_decl.path.segments);
                const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                // Detect what parameters this event accepts
                var has_source = false;
                var has_expression = false;
                var has_invocation = false;
                var has_program_ast = false;
                var has_allocator = false;

                for (event_decl.input.fields) |field| {
                    if (field.is_source) {
                        has_source = true;
                    } else if (field.is_expression) {
                        has_expression = true;
                    } else if (std.mem.eql(u8, field.name, "invocation")) {
                        has_invocation = true;
                    } else if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
                        has_program_ast = true;
                    } else if (std.mem.eql(u8, field.name, "allocator")) {
                        has_allocator = true;
                    }
                }

                // Detect what this event returns (check branches)
                var returns_program = false;
                var has_failed = false;
                for (event_decl.branches) |branch| {
                    if (std.mem.eql(u8, branch.name, "transformed")) {
                        for (branch.payload.fields) |field| {
                            if (std.mem.eql(u8, field.name, "program")) {
                                returns_program = true;
                                break;
                            }
                        }
                    } else if (std.mem.eql(u8, branch.name, "failed")) {
                        has_failed = true;
                    }
                }

                transform_events[transform_count] = .{
                    .stub_name = stub_name,
                    .match_name = match_name,
                    .module_path = null,  // Top-level events are in main_module
                    .has_source = has_source,
                    .has_expression = has_expression,
                    .has_invocation = has_invocation,
                    .has_program_ast = has_program_ast,
                    .has_allocator = has_allocator,
                    .returns_program = returns_program,
                    .has_failed = has_failed,
                };
                transform_count += 1;
            }
        }

        // Also check for transforms in imported modules
        if (item == .module_decl) {
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .event_decl) {
                    const event_decl = mod_item.event_decl;

                    // Check if this event has [transform] annotation
                    const has_transform = annotation_parser.hasPart(event_decl.annotations, "transform");

                    if (has_transform and transform_count < 16) {
                        const event_name = try joinPathSegments(allocator, event_decl.path.segments);
                        defer allocator.free(event_name);
                        const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                        // Build module path: "std.control" -> "koru_std.control"
                        var module_path_buf: [256]u8 = undefined;
                        var module_path_len: usize = 0;

                        // Also extract just the module name part for stub naming
                        var module_name: []const u8 = undefined;

                        // Convert "std.control" to "koru_std.control" by replacing first "std" with "koru_std"
                        if (std.mem.startsWith(u8, module.logical_name, "std.")) {
                            @memcpy(module_path_buf[0..9], "koru_std.");
                            const rest = module.logical_name[4..];  // Skip "std."
                            @memcpy(module_path_buf[9 .. 9 + rest.len], rest);
                            module_path_len = 9 + rest.len;
                            module_name = rest;
                        } else if (std.mem.eql(u8, module.logical_name, "std")) {
                            @memcpy(module_path_buf[0..8], "koru_std");
                            module_path_len = 8;
                            module_name = "";
                        } else {
                            // Non-std modules get "koru_" prefix too
                            @memcpy(module_path_buf[0..5], "koru_");
                            @memcpy(module_path_buf[5 .. 5 + module.logical_name.len], module.logical_name);
                            module_path_len = 5 + module.logical_name.len;
                            module_name = module.logical_name;
                        }

                        const module_path = try allocator.dupe(u8, module_path_buf[0..module_path_len]);

                        // Build unique stub name: module_name + "_" + event_name
                        // e.g., "control_if" or "compiler_requirements_requires"
                        var stub_name_buf: [256]u8 = undefined;
                        var stub_name_len: usize = 0;

                        // Replace dots with underscores in module_name
                        for (module_name) |c| {
                            stub_name_buf[stub_name_len] = if (c == '.') '_' else c;
                            stub_name_len += 1;
                        }
                        if (stub_name_len > 0) {
                            stub_name_buf[stub_name_len] = '_';
                            stub_name_len += 1;
                        }
                        @memcpy(stub_name_buf[stub_name_len .. stub_name_len + event_name.len], event_name);
                        stub_name_len += event_name.len;

                        const stub_name = try allocator.dupe(u8, stub_name_buf[0..stub_name_len]);

                        // Detect what parameters this event accepts
                        var has_source = false;
                        var has_expression = false;
                        var has_invocation = false;
                        var has_program_ast = false;
                        var has_allocator = false;

                        for (event_decl.input.fields) |field| {
                            if (field.is_source) {
                                has_source = true;
                            } else if (field.is_expression) {
                                has_expression = true;
                            } else if (std.mem.eql(u8, field.name, "invocation")) {
                                has_invocation = true;
                            } else if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
                                has_program_ast = true;
                            } else if (std.mem.eql(u8, field.name, "allocator")) {
                                has_allocator = true;
                            }
                        }

                        // Detect what this event returns (check branches)
                        var returns_program = false;
                        var has_failed = false;
                        for (event_decl.branches) |branch| {
                            if (std.mem.eql(u8, branch.name, "transformed")) {
                                for (branch.payload.fields) |field| {
                                    if (std.mem.eql(u8, field.name, "program")) {
                                        returns_program = true;
                                        break;
                                    }
                                }
                            } else if (std.mem.eql(u8, branch.name, "failed")) {
                                has_failed = true;
                            }
                        }

                        transform_events[transform_count] = .{
                            .stub_name = stub_name,
                            .match_name = match_name,
                            .module_path = module_path,  // Transform is in imported module
                            .has_source = has_source,
                            .has_expression = has_expression,
                            .has_invocation = has_invocation,
                            .has_program_ast = has_program_ast,
                            .has_allocator = has_allocator,
                            .returns_program = returns_program,
                            .has_failed = has_failed,
                        };
                        transform_count += 1;
                    }
                }
            }
        }
    }

    // Cleanup allocated names when we're done
    defer {
        for (transform_events[0..transform_count]) |event| {
            allocator.free(event.stub_name);
            allocator.free(event.match_name);
            if (event.module_path) |mp| {
                allocator.free(mp);
            }
        }
    }

    // Generate helper function to extract Source from arguments
    if (transform_count > 0) {
        try writer.writeAll("// Helper: Extract Source text from flow arguments\n");
        try writer.writeAll("fn extractSourceFromArgs(args: []const Arg) []const u8 {\n");
        try writer.writeAll("    for (args) |arg| {\n");
        try writer.writeAll("        if (arg.source_value) |source| {\n");
        try writer.writeAll("            return source.text;\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    return \"\";  // No source found\n");
        try writer.writeAll("}\n\n");
    }

    // Second pass: Generate individual calling stubs
    for (transform_events[0..transform_count]) |event| {
        try writer.print("// Transform handler for: {s}\n", .{event.stub_name});

        // Generate return type based on whether transform returns program
        if (event.returns_program) {
            try writer.print("fn call_transform_{s}(invocation: *const Invocation, containing_item: *const Item, ast: *const Program, allocator: std.mem.Allocator) !struct {{ item: Item, program: *const Program }} {{\n", .{event.stub_name});
        } else {
            try writer.print("fn call_transform_{s}(invocation: *const Invocation, containing_item: *const Item, ast: *const Program, allocator: std.mem.Allocator) !Item {{\n", .{event.stub_name});
        }

        // Suppress unused parameter warnings for parameters not requested by the event
        if (!event.has_program_ast) {
            try writer.writeAll("    _ = ast;\n");
        }
        if (!event.has_allocator) {
            try writer.writeAll("    _ = allocator;\n");
        }
        if (!event.has_item) {
            try writer.writeAll("    _ = containing_item;\n");
        }

        try writer.writeAll("    // Extract Source block from invocation arguments\n");
        try writer.writeAll("    const source_text = extractSourceFromArgs(invocation.args);\n");
        try writer.writeAll("    \n");

        try writer.writeAll("    // Build input struct for the handler\n");
        // Use event_name (original name) for handler struct lookup, not stub_name (prefixed for uniqueness)
        if (event.module_path) |mp| {
            try writer.print("    const handler = @import(\"backend_output_emitted\").{s}.{s}_event;\n", .{ mp, event.event_name });
        } else {
            try writer.print("    const handler = @import(\"backend_output_emitted\").main_module.{s}_event;\n", .{event.event_name});
        }
        try writer.writeAll("    const input = handler.Input{\n");
        if (event.has_source) {
            try writer.writeAll("        .source = source_text,\n");
        }
        if (event.has_item) {
            try writer.writeAll("        .item = containing_item,\n");
        }
        if (event.has_program_ast) {
            try writer.writeAll("        .program_ast = ast,\n");
        }
        if (event.has_allocator) {
            try writer.writeAll("        .allocator = allocator,\n");
        }
        try writer.writeAll("    };\n");
        try writer.writeAll("    \n");
        try writer.writeAll("    // Call the handler and extract result\n");
        try writer.writeAll("    const result = handler.handler(input);\n");
        try writer.writeAll("    return switch (result) {\n");

        // Generate return statement based on whether transform returns program
        if (event.returns_program) {
            try writer.writeAll("        .transformed => |t| .{ .item = t.item, .program = t.program },\n");
        } else {
            try writer.writeAll("        .transformed => |t| t.item,\n");
        }

        try writer.writeAll("    };\n");
        try writer.writeAll("}\n\n");
    }

    // Third pass: Generate dispatcher function
    if (transform_count > 0) {
        try writer.writeAll("// Transform Dispatcher - orchestrates all transform calls\n");
        try writer.writeAll("pub fn process_all_transforms(ast: *const Program, allocator: std.mem.Allocator) !*Program {\n");
        try writer.writeAll("    // Import joinPath helper from backend\n");
        try writer.writeAll("    const joinPath = @import(\"backend_output_emitted\").koru_std.compiler.joinPath;\n");
        try writer.writeAll("    \n");
        try writer.writeAll("    // Track current AST state (transforms may return modified AST)\n");
        try writer.writeAll("    var current_ast = ast;\n");
        try writer.writeAll("    var items_list = std.ArrayList(Item){};\n");
        try writer.writeAll("    defer items_list.deinit(allocator);\n");
        try writer.writeAll("    \n");
        try writer.writeAll("    for (current_ast.items) |item| {\n");
        try writer.writeAll("        if (item == .flow) {\n");
        try writer.writeAll("            const flow = item.flow;\n");
        try writer.writeAll("            const inv_path = joinPath(flow.invocation.path.segments);\n");
        try writer.writeAll("            \n");
        try writer.writeAll("            // Dispatch to appropriate transform handler\n");

        // Generate if/else chain for each transform event
        for (transform_events[0..transform_count], 0..) |event, i| {
            if (i == 0) {
                try writer.print("            if (std.mem.eql(u8, inv_path, \"{s}\")) {{\n", .{event.match_name});
            } else {
                try writer.print("            }} else if (std.mem.eql(u8, inv_path, \"{s}\")) {{\n", .{event.match_name});
            }

            // Handle both program-returning and item-only transforms
            if (event.returns_program) {
                try writer.print("                const result = try call_transform_{s}(&flow, current_ast, allocator);\n", .{event.stub_name});
                try writer.writeAll("                current_ast = result.program;  // Update AST with modified version\n");
                try writer.writeAll("                try items_list.append(allocator, result.item);\n");
            } else {
                try writer.print("                const transformed = try call_transform_{s}(&flow, current_ast, allocator);\n", .{event.stub_name});
                try writer.writeAll("                try items_list.append(allocator, transformed);\n");
            }
        }

        try writer.writeAll("            } else {\n");
        try writer.writeAll("                try items_list.append(allocator, item);  // Keep non-transform flows\n");
        try writer.writeAll("            }\n");
        try writer.writeAll("        } else {\n");
        try writer.writeAll("            try items_list.append(allocator, item);  // Keep non-flow items\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    \n");
        try writer.writeAll("    // Build new Program with transformed items\n");
        try writer.writeAll("    const new_ast = try allocator.create(Program);\n");
        try writer.writeAll("    new_ast.* = Program{\n");
        try writer.writeAll("        .items = try items_list.toOwnedSlice(allocator),\n");
        try writer.writeAll("        .module_annotations = current_ast.module_annotations,\n");
        try writer.writeAll("        .main_module_name = current_ast.main_module_name,\n");
        try writer.writeAll("        .allocator = allocator,\n");
        try writer.writeAll("    };\n");
        try writer.writeAll("    return new_ast;\n");
        try writer.writeAll("}\n\n");
    }
}

/// Generate transform handlers to CodeEmitter (for backend_output_emitted.zig)
/// Same as generateTransformHandlers but writes to CodeEmitter instead of generic writer
/// Returns the number of transform events found
fn generateTransformHandlersToEmitter(code_emitter: anytype, allocator: std.mem.Allocator, source_file: *ast.Program) !usize {
    // First pass: Collect all transform events (max 16 transform events per file)
    var transform_events: [16]TransformEvent = undefined;
    var transform_count: usize = 0;

    for (source_file.items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;

            // TYPE-DRIVEN DETECTION: Check if this event consumes AST types
            // Events with *const Invocation or *const Item are transform handlers
            // Events with *const EventDecl are derive handlers (operate on declarations)
            // The frontend is agnostic to [transform]/[derive] annotations - that's backend dispatch
            var has_source_param = false;
            var has_expression_param = false;
            var has_invocation_param = false;
            var has_item_param = false;
            var has_event_decl_param = false;

            for (event_decl.input.fields) |field| {
                if (field.is_source) {
                    has_source_param = true;
                } else if (field.is_expression) {
                    has_expression_param = true;
                } else if (std.mem.eql(u8, field.type, "*const Invocation")) {
                    has_invocation_param = true;
                } else if (std.mem.eql(u8, field.type, "*const Item")) {
                    has_item_param = true;
                } else if (std.mem.eql(u8, field.type, "*const EventDecl")) {
                    has_event_decl_param = true;
                }
            }

            // Events consuming AST types must be emitted to backend
            // *const Item also indicates a transform handler (needs to access flow from item)
            const consumes_ast_types = has_invocation_param or has_item_param or has_event_decl_param;

            // VALIDATION: AST-consuming handlers must be available at compile-time
            if (consumes_ast_types and !has_source_param and !has_expression_param) {
                const has_comptime = annotation_parser.hasPart(event_decl.annotations, "comptime");
                if (!has_comptime) {
                    const event_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);
                    defer allocator.free(event_name);

                    const handler_type = if (has_event_decl_param) "derive" else "transform";
                    std.debug.print("\nERROR: Event '{s}' consumes *const {s} but won't be emitted to backend\n", .{ event_name, if (has_event_decl_param) "EventDecl" else "Invocation" });
                    std.debug.print("\n", .{});
                    std.debug.print("AST-consuming handlers must be available at compile-time. Add [comptime]:\n", .{});
                    std.debug.print("  ~[comptime] event {s} {{ ... }}\n", .{event_name});
                    std.debug.print("\n", .{});
                    _ = handler_type;
                    return error.TransformMissingComptimeAnnotation;
                }
            }

            // Emit handlers for events that consume AST types
            const should_generate_handler = consumes_ast_types;

            if (should_generate_handler and transform_count < 16) {
                const stub_name = try joinPathSegments(allocator, event_decl.path.segments);
                const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                // Detect additional parameters by NAME (program, allocator)
                // Note: invocation/event_decl/item already detected by TYPE above
                var has_program_ast = false;
                var has_allocator = false;

                for (event_decl.input.fields) |field| {
                    if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
                        has_program_ast = true;
                    } else if (std.mem.eql(u8, field.name, "allocator")) {
                        has_allocator = true;
                    }
                }

                // Detect what this event returns (check branches)
                var returns_program = false;
                var has_failed = false;
                for (event_decl.branches) |branch| {
                    if (std.mem.eql(u8, branch.name, "transformed")) {
                        for (branch.payload.fields) |field| {
                            if (std.mem.eql(u8, field.name, "program")) {
                                returns_program = true;
                                break;
                            }
                        }
                    } else if (std.mem.eql(u8, branch.name, "failed")) {
                        has_failed = true;
                    }
                }

                transform_events[transform_count] = .{
                    .stub_name = stub_name,
                    .match_name = match_name,
                    .event_name = stub_name,  // For top-level, stub_name = event_name
                    .module_path = null,  // Top-level events are in main_module
                    .has_source = has_source_param,
                    .has_expression = has_expression_param,
                    .has_invocation = has_invocation_param,
                    .has_event_decl = has_event_decl_param,
                    .has_item = has_item_param,
                    .has_program_ast = has_program_ast,
                    .has_allocator = has_allocator,
                    .returns_program = returns_program,
                    .has_failed = has_failed,
                };
                transform_count += 1;
            }
        }

        // Also check for handlers in imported modules (same type-driven detection)
        if (item == .module_decl) {
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .event_decl) {
                    const event_decl = mod_item.event_decl;

                    // TYPE-DRIVEN DETECTION: Check if this event consumes AST types
                    var has_source_param = false;
                    var has_expression_param = false;
                    var has_invocation_param = false;
                    var has_item_param = false;
                    var has_event_decl_param = false;

                    for (event_decl.input.fields) |field| {
                        if (field.is_source) {
                            has_source_param = true;
                        } else if (field.is_expression) {
                            has_expression_param = true;
                        } else if (std.mem.eql(u8, field.type, "*const Invocation")) {
                            has_invocation_param = true;
                        } else if (std.mem.eql(u8, field.type, "*const Item")) {
                            has_item_param = true;
                        } else if (std.mem.eql(u8, field.type, "*const EventDecl")) {
                            has_event_decl_param = true;
                        }
                    }

                    // Emit handlers for events that consume AST types
                    const should_generate_handler = has_invocation_param or has_item_param or has_event_decl_param;

                    if (should_generate_handler and transform_count < 16) {
                        const event_name = try joinPathSegments(allocator, event_decl.path.segments);
                        // Note: don't free event_name - it's stored in transform_events
                        const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                        // Build module path: "std.control" -> "koru_std.control"
                        var module_path_buf: [256]u8 = undefined;
                        var module_path_len: usize = 0;

                        // Also extract just the module name part (e.g., "control" from "std.control")
                        var module_name: []const u8 = undefined;

                        if (std.mem.startsWith(u8, module.logical_name, "std.")) {
                            @memcpy(module_path_buf[0..9], "koru_std.");
                            const rest = module.logical_name[4..];
                            @memcpy(module_path_buf[9 .. 9 + rest.len], rest);
                            module_path_len = 9 + rest.len;
                            module_name = rest;  // e.g., "control" or "compiler_requirements"
                        } else if (std.mem.eql(u8, module.logical_name, "std")) {
                            @memcpy(module_path_buf[0..8], "koru_std");
                            module_path_len = 8;
                            module_name = "";
                        } else {
                            // Non-std modules get "koru_" prefix too
                            @memcpy(module_path_buf[0..5], "koru_");
                            @memcpy(module_path_buf[5 .. 5 + module.logical_name.len], module.logical_name);
                            module_path_len = 5 + module.logical_name.len;
                            module_name = module.logical_name;
                        }

                        const module_path = try allocator.dupe(u8, module_path_buf[0..module_path_len]);

                        // Build unique stub name: module_name + "_" + event_name
                        // e.g., "control_if" or "compiler_requirements_requires"
                        var stub_name_buf: [256]u8 = undefined;
                        var stub_name_len: usize = 0;

                        // Replace dots with underscores in module_name
                        for (module_name) |c| {
                            stub_name_buf[stub_name_len] = if (c == '.') '_' else c;
                            stub_name_len += 1;
                        }
                        if (stub_name_len > 0) {
                            stub_name_buf[stub_name_len] = '_';
                            stub_name_len += 1;
                        }
                        @memcpy(stub_name_buf[stub_name_len .. stub_name_len + event_name.len], event_name);
                        stub_name_len += event_name.len;

                        const stub_name = try allocator.dupe(u8, stub_name_buf[0..stub_name_len]);

                        // Detect additional parameters by NAME (program, allocator)
                        // Note: invocation/event_decl/item already detected by TYPE above
                        var has_program_ast = false;
                        var has_allocator = false;

                        for (event_decl.input.fields) |field| {
                            if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
                                has_program_ast = true;
                            } else if (std.mem.eql(u8, field.name, "allocator")) {
                                has_allocator = true;
                            }
                        }

                        // Detect return type
                        var returns_program = false;
                        var has_failed = false;
                        for (event_decl.branches) |branch| {
                            if (std.mem.eql(u8, branch.name, "transformed")) {
                                for (branch.payload.fields) |field| {
                                    if (std.mem.eql(u8, field.name, "program")) {
                                        returns_program = true;
                                        break;
                                    }
                                }
                            } else if (std.mem.eql(u8, branch.name, "failed")) {
                                has_failed = true;
                            }
                        }

                        transform_events[transform_count] = .{
                            .stub_name = stub_name,
                            .match_name = match_name,
                            .event_name = event_name,  // Original event name for handler lookup
                            .module_path = module_path,
                            .has_source = has_source_param,
                            .has_expression = has_expression_param,
                            .has_invocation = has_invocation_param,
                            .has_event_decl = has_event_decl_param,
                            .has_item = has_item_param,
                            .has_program_ast = has_program_ast,
                            .has_allocator = has_allocator,
                            .returns_program = returns_program,
                            .has_failed = has_failed,
                        };
                        transform_count += 1;
                    }
                }
            }
        }
    }

    // Cleanup allocated names when we're done
    defer {
        for (transform_events[0..transform_count]) |event| {
            allocator.free(event.stub_name);
            allocator.free(event.match_name);
            allocator.free(event.event_name);
            if (event.module_path) |mp| {
                allocator.free(mp);
            }
        }
    }

    if (transform_count == 0) return 0; // No transforms, nothing to generate

    // Generate helper and handlers
    var buf: [4096]u8 = undefined;

    // Import necessary types at the top level
    try code_emitter.write("// Transform handler imports\n");
    try code_emitter.write("const transform_std = __koru_std;\n");
    try code_emitter.write("const Arg = __koru_ast.Arg;\n");
    try code_emitter.write("const Flow = __koru_ast.Flow;\n\n");

    // Helper to extract Source from flow arguments
    try code_emitter.write("// Helper: Extract Source struct from flow arguments\n");
    try code_emitter.write("fn extractSourceFromArgs(args: []const Arg) ?__koru_ast.Source {\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (arg.source_value) |source| {\n");
    try code_emitter.write("            return source.*;  // Return full Source struct\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    return null;\n");
    try code_emitter.write("}\n\n");

    // Helper to extract Expression text from flow arguments
    try code_emitter.write("// Helper: Extract Expression text from flow arguments\n");
    try code_emitter.write("fn extractExprFromArgs(args: []const Arg) ?[]const u8 {\n");
    try code_emitter.write("    // First try: look for CapturedExpression\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (arg.expression_value) |expr| {\n");
    try code_emitter.write("            return expr.text;  // Return expression text\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    // Fallback: use first arg's value directly\n");
    try code_emitter.write("    // This handles pipeline invocations where expression_value wasn't captured\n");
    try code_emitter.write("    if (args.len > 0 and args[0].value.len > 0) {\n");
    try code_emitter.write("        return args[0].value;\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    return null;\n");
    try code_emitter.write("}\n\n");

    // Individual stubs - called on flows that invoke transform events
    // NEW: Uses unified ASTNode interface - handlers receive (node, program, allocator)
    for (transform_events[0..transform_count]) |event| {
        const stub = try std.fmt.bufPrint(&buf, "// Transform handler for: {s}\n", .{event.stub_name});
        try code_emitter.write(stub);
        // Handler type determined by parameter: *const Invocation = transform, *const EventDecl = derive
        if (event.has_event_decl) {
            try code_emitter.write("// Derive handler: called when [derive(X)] is found on an event declaration\n");
        } else {
            try code_emitter.write("// Transform handler: called when a flow invokes this transform event\n");
        }
        try code_emitter.write("// Uses unified ASTNode interface for generic AST traversal\n");

        // Function signature
        const fn_sig = try std.fmt.bufPrint(&buf, "fn call_handler_{s}(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator) !*const __koru_ast.Program {{\n", .{event.stub_name});
        try code_emitter.write(fn_sig);

        // Extract the appropriate data from the node based on handler type
        if (event.has_event_decl) {
            // Derive handler: extract event_decl from the item
            try code_emitter.write("    // Extract event declaration from node\n");
            try code_emitter.write("    const event_decl = if (node == .item and node.item.* == .event_decl) &node.item.event_decl else {\n");
            try code_emitter.write("        transform_std.debug.print(\"ERROR: Derive handler called with non-event_decl node\\n\", .{});\n");
            try code_emitter.write("        @panic(\"derive: expected event_decl node\");\n");
            try code_emitter.write("    };\n");
        } else if (event.has_invocation or event.has_item) {
            // Transform handler: node is always an invocation for invocation-based transforms
            try code_emitter.write("    const invocation = node.invocation;\n");

            // If handler needs item, find it using ASTNode helper
            if (event.has_item) {
                try code_emitter.write("    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {\n");
                try code_emitter.write("        transform_std.debug.print(\"ERROR: Could not find containing item for invocation\\n\", .{});\n");
                try code_emitter.write("        @panic(\"transform: invocation not found in program\");\n");
                try code_emitter.write("    };\n");
            }
        }

        if (!event.has_allocator) {
            try code_emitter.write("    _ = allocator;\n");
        }
        // Only discard program if we don't use it anywhere
        if (!event.has_program_ast and !event.has_source and !event.has_expression and !event.has_item and !event.has_event_decl) {
            try code_emitter.write("    _ = program;\n");
        }

        // DEBUG: Show what we're processing
        if (event.has_event_decl) {
            const debug_derive = try std.fmt.bufPrint(&buf, "    transform_std.debug.print(\"[DERIVE] {s}: processing event declaration\\n\", .{{}});\n", .{event.stub_name});
            try code_emitter.write(debug_derive);
        } else if (event.has_invocation or event.has_item) {
            const debug_count = try std.fmt.bufPrint(&buf, "    transform_std.debug.print(\"[TRANSFORM] {s}: {{d}} args\\n\", .{{invocation.args.len}});\n", .{event.stub_name});
            try code_emitter.write(debug_count);
            try code_emitter.write("    for (invocation.args, 0..) |arg, i| {\n");
            try code_emitter.write("        transform_std.debug.print(\"  Arg[{d}]: name='{s}' has_source={} has_expr={}\\n\", .{i, arg.name, arg.source_value != null, arg.expression_value != null});\n");
            try code_emitter.write("    }\n");
        }

        // Generate handler call
        // Use event_name (original name) for handler struct lookup, not stub_name (prefixed for uniqueness)
        if (event.module_path) |mp| {
            const handler_line = try std.fmt.bufPrint(&buf, "    const handler = {s}.{s}_event;\n", .{ mp, event.event_name });
            try code_emitter.write(handler_line);
        } else {
            const handler_line = try std.fmt.bufPrint(&buf, "    const handler = main_module.{s}_event;\n", .{event.event_name});
            try code_emitter.write(handler_line);
        }

        // Derive handlers have simpler input (no Source/Expression extraction)
        if (event.has_event_decl) {
            // Derive handler: build Input with event_decl
            try code_emitter.write("    const input = handler.Input{\n");
            try code_emitter.write("        .event_decl = event_decl,\n");
            if (event.has_program_ast) {
                try code_emitter.write("        .program = program,\n");
            }
            if (event.has_allocator) {
                try code_emitter.write("        .allocator = allocator,\n");
            }
            try code_emitter.write("    };\n");

            // Call handler and return result
            if (event.returns_program) {
                try code_emitter.write("    const result = handler.handler(input);\n");
                try code_emitter.write("    return switch (result) {\n");
                try code_emitter.write("        .transformed => |t| t.program,\n");
                if (event.has_failed) {
                    try code_emitter.write("        .failed => |f| {\n");
                    try code_emitter.write("            transform_std.debug.print(\"Derive failed: {s}\\n\", .{f.@\"error\"});\n");
                    try code_emitter.write("            return error.DeriveFailed;\n");
                    try code_emitter.write("        },\n");
                }
                try code_emitter.write("    };\n");
            } else {
                try code_emitter.write("    _ = handler.handler(input);\n");
                try code_emitter.write("    return program;\n");
            }
        } else {
            // Transform handler: extract Source and/or Expression as needed
            if (event.has_source) {
                try code_emitter.write("    const source_opt = extractSourceFromArgs(invocation.args);\n");
            }

            if (event.has_expression) {
                try code_emitter.write("    const expr_opt = extractExprFromArgs(invocation.args);\n");
            }

            // Build guard condition and input based on what's required
            if (event.has_source and event.has_expression) {
                try code_emitter.write("    if (source_opt != null and expr_opt != null) {\n");
                try code_emitter.write("        const source = source_opt.?;\n");
                try code_emitter.write("        const expr_text = expr_opt.?;\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .source = source,\n");
                try code_emitter.write("            .expr = expr_text,\n");
            } else if (event.has_source) {
                try code_emitter.write("    if (source_opt) |source| {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .source = source,\n");
            } else if (event.has_expression) {
                try code_emitter.write("    if (expr_opt) |expr_text| {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .expr = expr_text,\n");
            } else {
                try code_emitter.write("    {\n");
                try code_emitter.write("        const input = handler.Input{\n");
            }

            // Add remaining Input fields
            if (event.has_item) {
                try code_emitter.write("            .item = item,\n");
            }
            if (event.has_invocation) {
                try code_emitter.write("            .invocation = invocation,\n");
            }
            if (event.has_program_ast) {
                try code_emitter.write("            .program = program,\n");
            }
            if (event.has_allocator) {
                try code_emitter.write("            .allocator = allocator,\n");
            }

            // Call handler and handle result
            try code_emitter.write("        };\n");
            if (event.returns_program) {
                try code_emitter.write("        const result = handler.handler(input);\n");
                try code_emitter.write("        return switch (result) {\n");
                try code_emitter.write("            .transformed => |t| t.program,\n");
                if (event.has_failed) {
                    try code_emitter.write("            .failed => |f| {\n");
                    try code_emitter.write("                transform_std.debug.print(\"Transform failed: {s}\\n\", .{f.@\"error\"});\n");
                    try code_emitter.write("                return error.TransformFailed;\n");
                    try code_emitter.write("            },\n");
                }
                try code_emitter.write("        };\n");
            } else {
                try code_emitter.write("        _ = handler.handler(input);\n");
                try code_emitter.write("        return program;  // Source-capture events don't modify program\n");
            }
        }

        // Close guard and add else case if needed (only for transform handlers, not derive)
        if (!event.has_event_decl) {
            if (event.has_source or event.has_expression) {
                try code_emitter.write("    } else {\n");
                try code_emitter.write("        return program;  // Required args not present, return unchanged\n");
                try code_emitter.write("    }\n");
            } else {
                try code_emitter.write("    }\n");
            }
        }
        try code_emitter.write("}\n\n");
    }

    // Dispatcher - uses transform_pass_runner for proper recursive AST walking
    try code_emitter.write("// Transform Dispatcher - uses transform_pass_runner for proper recursive AST walking\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// CRITICAL: Transform execution order is SIGNIFICANT!\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// Transforms walk the AST in SOURCE ORDER and each transform receives the CURRENT state\n");
    try code_emitter.write("// of the AST (including modifications from previous transforms). This means:\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// 1. Dependencies must appear BEFORE dependents in source code\n");
    try code_emitter.write("// 2. Upstream transforms complete BEFORE downstream transforms run\n");
    try code_emitter.write("// 3. Type resolution via AST-walking sees the TRANSFORMED upstream AST\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// Example:\n");
    try code_emitter.write("//   ~getUserData() | data u |> renderHTML [HTML]{ $[u.name] }\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// If getUserData is also a transform, it runs FIRST (appears earlier in source),\n");
    try code_emitter.write("// then renderHTML sees the TRANSFORMED getUserData event when resolving 'u's type.\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// This is why binding.type is \"unknown\" at parse time - type resolution happens\n");
    try code_emitter.write("// at transform time via ast_functional.resolveBindingType().\n");
    try code_emitter.write("pub fn run_pass(annotation: []const u8, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator) !*__koru_ast.Program {\n");
    try code_emitter.write("    _ = annotation;  // For now, we only support \"transform\" annotation\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // DUMP POINT 6: AST at run_pass() entry\n");
    try code_emitter.write("    dumpAST(program, \"6-run-pass-start\", allocator);\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // Build dispatch table for transform/derive handlers\n");
    try code_emitter.write("    // Handlers are Koru-defined events with *const Invocation or *const EventDecl params\n");
    try code_emitter.write("    const transform_pass_runner = @import(\"transform_pass_runner\");\n");
    try code_emitter.write("    const transforms = &[_]transform_pass_runner.TransformEntry{\n");

    // Generate dispatch table entries for Koru-defined handlers (both transform and derive)
    for (transform_events[0..transform_count]) |event| {
        const entry_line = try std.fmt.bufPrint(&buf, "        .{{ .name = \"{s}\", .handler_fn = call_handler_{s} }},\n", .{ event.match_name, event.stub_name });
        try code_emitter.write(entry_line);
    }

    try code_emitter.write("    };\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // Use transform_pass_runner for proper recursive AST walking\n");
    try code_emitter.write("    const result = try transform_pass_runner.walkAndTransform(program, transforms, allocator);\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // DUMP POINT 7: AST at run_pass() exit (after all transforms)\n");
    try code_emitter.write("    dumpAST(result, \"7-run-pass-end\", allocator);\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    return result;\n");
    try code_emitter.write("}\n\n");

    // Add alias for backward compatibility with backend.zig which imports process_all_transforms
    try code_emitter.write("// Alias for backward compatibility\n");
    try code_emitter.write("pub const process_all_transforms = run_pass;\n\n");

    return transform_count;
}

/// Helper: Join path segments with underscores for function names
fn joinPathSegments(allocator: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    if (segments.len == 0) return try allocator.dupe(u8, "unknown");
    if (segments.len == 1) return try allocator.dupe(u8, segments[0]);

    // Calculate total length
    var total_len: usize = segments[0].len;
    for (segments[1..]) |seg| {
        total_len += 1 + seg.len; // underscore + segment
    }

    // Build result
    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    @memcpy(result[pos..pos + segments[0].len], segments[0]);
    pos += segments[0].len;

    for (segments[1..]) |seg| {
        result[pos] = '_';
        pos += 1;
        @memcpy(result[pos..pos + seg.len], seg);
        pos += seg.len;
    }

    return result;
}

/// Helper: Join path segments with dots for event path matching
fn joinPathSegmentsWithDots(allocator: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    if (segments.len == 0) return try allocator.dupe(u8, "unknown");
    if (segments.len == 1) return try allocator.dupe(u8, segments[0]);

    // Calculate total length
    var total_len: usize = segments[0].len;
    for (segments[1..]) |seg| {
        total_len += 1 + seg.len; // dot + segment
    }

    // Build result
    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    @memcpy(result[pos..pos + segments[0].len], segments[0]);
    pos += segments[0].len;

    for (segments[1..]) |seg| {
        result[pos] = '.';
        pos += 1;
        @memcpy(result[pos..pos + seg.len], seg);
        pos += seg.len;
    }

    return result;
}

/// Generate the visitor pattern backend
fn generateVisitorBackend(writer: anytype, allocator: std.mem.Allocator, source_file: *ast.Program) !void {
    _ = allocator;
    _ = source_file;

    // First, emit the visitor pattern infrastructure
    try writer.writeAll(
        \\// Visitor Pattern Backend Implementation
        \\const CodeEmitter = struct {
        \\    buffer: []u8,
        \\    pos: usize,
        \\    indent_level: u32,
        \\    indent_size: u32 = 4,
        \\
        \\    pub fn init(buffer: []u8) CodeEmitter {
        \\        return .{
        \\            .buffer = buffer,
        \\            .pos = 0,
        \\            .indent_level = 0,
        \\        };
        \\    }
        \\
        \\    pub fn write(self: *CodeEmitter, text: []const u8) !void {
        \\        if (self.pos + text.len >= self.buffer.len) {
        \\            return error.BufferOverflow;
        \\        }
        \\        @memcpy(self.buffer[self.pos..self.pos + text.len], text);
        \\        self.pos += text.len;
        \\    }
        \\
        \\    pub fn writeLine(self: *CodeEmitter, text: []const u8) !void {
        \\        try self.writeIndent();
        \\        try self.write(text);
        \\        try self.write("\n");
        \\    }
        \\
        \\    pub fn writeIndent(self: *CodeEmitter) !void {
        \\        const spaces = self.indent_level * self.indent_size;
        \\        var i: u32 = 0;
        \\        while (i < spaces) : (i += 1) {
        \\            try self.write(" ");
        \\        }
        \\    }
        \\
        \\    pub fn indent(self: *CodeEmitter) void {
        \\        self.indent_level += 1;
        \\    }
        \\
        \\    pub fn dedent(self: *CodeEmitter) void {
        \\        if (self.indent_level > 0) {
        \\            self.indent_level -= 1;
        \\        }
        \\    }
        \\
        \\    pub fn getOutput(self: *CodeEmitter) []const u8 {
        \\        return self.buffer[0..self.pos];
        \\    }
        \\};
        \\
        \\
    );

    // Generate the visitor implementation using the library
    // Import the emission libraries (emitter_helpers, visitor_emitter, tap_registry)
    if (true) { // Always generate the visitor implementation when in visitor mode
        // Import std and emission libraries (use module names, not file paths)
        try writer.writeAll("const std = @import(\"std\");\n");
        try writer.writeAll("const emitter_helpers = @import(\"emitter_helpers\");\n");
        try writer.writeAll("const visitor_emitter_lib = @import(\"visitor_emitter\");\n");
        try writer.writeAll("const tap_registry_module = @import(\"tap_registry\");\n");
        try writer.writeAll("const tap_transformer = @import(\"tap_transformer\");\n");
        try writer.writeAll("const compiler_config = @import(\"compiler_config\");\n");
        try writer.writeAll("const type_registry_module = @import(\"type_registry\");\n\n");

        try writer.writeAll("const compiler_emit_zig = struct {\n");
        try writer.writeAll("    pub const Input = struct { ast: *const Program, allocator: std.mem.Allocator };\n");
        try writer.writeAll("    pub const Output = union(enum) { emitted: struct { code: []const u8 } };\n");
        try writer.writeAll("    pub fn handler(__koru_event_input: Input) Output {\n");

        // Use the visitor_emitter library with .runtime_only mode
        // This mirrors generateComptimeBackendEmitted but filters differently
        try writer.writeAll(
            \\        const allocator = __koru_event_input.allocator;
            \\
            \\        // Create buffer for generated code
            \\        const MAX_SIZE = 1024 * 1024;  // 1MB
            \\        const buffer = allocator.alloc(u8, MAX_SIZE) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\        defer allocator.free(buffer);
            \\
            \\        // Create CodeEmitter
            \\        var code_emitter = emitter_helpers.CodeEmitter.init(buffer);
            \\
            \\        // Build tap registry
            \\        var tap_registry = tap_registry_module.buildTapRegistry(
            \\            __koru_event_input.ast.items,
            \\            allocator
            \\        ) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\        defer tap_registry.deinit();
            \\
            \\        // Transform AST - insert taps before emission
            \\        // Taps are inserted into AST as regular flow code (zero-cost abstraction!)
            \\        const ast_to_emit = tap_transformer.transformAst(
            \\            __koru_event_input.ast,
            \\            &tap_registry,
            \\            .runtime_only,
            \\            allocator
            \\        ) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        // Build TypeRegistry from canonicalized AST - needed for event metadata lookup
            \\        // The AST received from the frontend has already been canonicalized
            \\        var type_registry = type_registry_module.TypeRegistry.init(allocator);
            \\        defer type_registry.deinit();
            \\        type_registry.populateFromAST(__koru_event_input.ast.items) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        // Create visitor emitter with RUNTIME_ONLY mode
            \\        // This filters OUT modules with [comptime] annotation
            \\        var visitor_emitter = visitor_emitter_lib.VisitorEmitter.init(
            \\            allocator,
            \\            &code_emitter,
            \\            ast_to_emit.items,
            \\            &tap_registry,
            \\            &type_registry,
            \\            .runtime_only  // KEY: Emit only runtime modules
            \\        );
            \\
            \\        // Emit using visitor pattern
            \\        visitor_emitter.emit(ast_to_emit) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        // Get generated code and duplicate for return
            \\        const generated = code_emitter.getOutput();
            \\        const owned_code = allocator.dupe(u8, generated) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        return .{ .emitted = .{ .code = owned_code } };
        );

        try writer.writeAll("\n    }\n};\n\n");
    }

    // Emit the rest of the backend infrastructure (same as old implementation)
    try writer.writeAll(
        \\// Bootstrap coordinator - calls the visitor implementation
        \\const compiler_coordinate_default = struct {
        \\    pub const Input = struct { ast: *const Program, allocator: std.mem.Allocator };
        \\    pub const Output = union(enum) {
        \\        coordinated: struct {
        \\            ast: *const Program,
        \\            code: []const u8,
        \\            metrics: []const u8,
        \\        },
        \\    };
        \\    pub fn handler(__koru_event_input: Input) !Output {
        \\        const allocator = __koru_event_input.allocator;
        \\        // Run CCP injection pass
        \\        const ccp_result = try compiler_passes_inject_ccp.handler(.{ .ast = __koru_event_input.ast, .allocator = allocator });
        \\
        \\        const result = try compiler_emit_zig.handler(.{ .ast = ccp_result.instrumented.ast, .allocator = allocator });
        \\        const code = switch (result) {
        \\            .emitted => |em| em.code,
        \\        };
        \\        return .{ .coordinated = .{
        \\            .ast = ccp_result.instrumented.ast,
        \\            .code = code,
        \\            .metrics = "",
        \\        }};
        \\    }
        \\};
        \\
        \\// Compile-time execution
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer {
        \\        const leak_status = gpa.deinit();
        \\        if (leak_status == .leak) {
        \\            std.debug.print("Memory leak detected\n", .{});
        \\        }
        \\    }
        \\    const allocator = gpa.allocator();
        \\
        \\    // Arena allocator for compilation phase
        \\    var compile_arena = std.heap.ArenaAllocator.init(allocator);
        \\    defer compile_arena.deinit();
        \\    const compile_allocator = compile_arena.allocator();
        \\
        \\    const args = try std.process.argsAlloc(allocator);
        \\    defer std.process.argsFree(allocator, args);
        \\
        \\    const emitted_file = "output_emitted.zig";
        \\    // NOTE: args[1] is the output exe name when called from frontend,
        \\    // but when running backend directly, args[1] might be the input .kz file.
        \\    // Detect this case and default to "a.out" instead of overwriting the source!
        \\    const output_exe = if (args.len > 1 and !std.mem.endsWith(u8, args[1], ".kz")) args[1] else "a.out";
        \\
        \\    var actual_len: usize = generated_code.len;
        \\    while (actual_len > 0 and generated_code[actual_len - 1] == 0) {
        \\        actual_len -= 1;
        \\    }
        \\    const trimmed_code = generated_code[0..actual_len];
        \\
        \\    const file = try std.fs.cwd().createFile(emitted_file, .{});
        \\    defer file.close();
        \\    try file.writeAll(trimmed_code);
        \\
        \\    const stdout = std.fs.File.stdout();
        \\    var buf: [512]u8 = undefined;
        \\    const msg = try std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, actual_len});
        \\    try stdout.writeAll(msg);
        \\}
        \\
    );
}

fn printStdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(msg);
}

// A simple writer that wraps a File
const FileWriter = struct {
    file: std.fs.File,

    pub fn print(self: FileWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, fmt, args);
        try self.file.writeAll(msg);
    }

    pub fn writeAll(self: FileWriter, bytes: []const u8) !void {
        try self.file.writeAll(bytes);
    }
};

// Import system - proper module isolation with struct namespaces
const ImportedModule = struct {
    logical_name: []const u8, // Module name used in code (e.g., "io")
    canonical_path: []const u8, // Full resolved path to the module file/directory
    public_events: []ast.EventDecl, // Only public events for type checking
    source_file: ast.Program, // Full AST for the module
    is_directory: bool, // True if this is a directory import
    submodules: []ImportedModule, // Submodules (for directory imports)

    pub fn deinit(self: *ImportedModule, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_name);
        allocator.free(self.canonical_path);
        // Recursively deinit submodules
        for (self.submodules) |*submod| {
            submod.deinit(allocator);
        }
        allocator.free(self.submodules);
        // NOTE: Don't deinit public_events items - they're shallow copies of events
        // that are in source_file.items. Deiniting them causes double-free.
        // Just free the array itself.
        allocator.free(self.public_events);
        // NOTE: Don't call source_file.deinit() because we transfer ownership
        // of items to the combined AST. The items array is set to &.{} after transfer,
        // and freeing that constant causes crashes.
        // NOTE: Also don't free main_module_name - it's allocated by the arena allocator
        // that will free everything when the arena is destroyed.
    }
};

/// Derives canonical module name from import path
/// - $alias/path imports: "alias.path" (preserve alias + path as dotted name)
/// - Regular path imports: Last component only (directory name as package)
///
/// Examples:
/// - "$std/io" → "std.io" (alias import: keep both parts)
/// - "lib/io" → "io" (directory import: last component only)
/// - "helper" → "helper" (single file)
fn deriveCanonicalName(allocator: std.mem.Allocator, import_path: []const u8) ![]const u8 {
    var path_to_convert = import_path;
    var has_alias = false;

    // Handle $alias imports: $std/io → std.io (preserve BOTH parts!)
    if (import_path.len > 0 and import_path[0] == '$') {
        has_alias = true;
        // Find the first slash
        if (std.mem.indexOfScalar(u8, import_path, '/')) |_| {
            // Skip the $ and get everything: $std/io → std/io
            path_to_convert = import_path[1..]; // Remove $
        } else {
            // Just $package with no path - use package name without $
            return try allocator.dupe(u8, import_path[1..]); // Remove $
        }
    }

    // Remove .kz extension if present
    const without_ext = if (std.mem.endsWith(u8, path_to_convert, ".kz"))
        path_to_convert[0 .. path_to_convert.len - 3]
    else
        path_to_convert;

    // Different logic based on whether this was an alias import
    if (has_alias) {
        // Alias import: Replace / with . to create dotted name
        // "std/io" → "std.io"
        // "std/compiler" → "std.compiler"
        var result = try allocator.alloc(u8, without_ext.len);
        for (without_ext, 0..) |c, i| {
            result[i] = if (c == '/') '.' else c;
        }
        return result;
    } else {
        // Regular import: Use LAST component only
        // "lib/io" → "io"
        // "vendor/raylib" → "raylib"
        // "helper" → "helper"
        const last_slash = std.mem.lastIndexOfScalar(u8, without_ext, '/');
        const package_name = if (last_slash) |pos|
            without_ext[pos + 1..]
        else
            without_ext;

        return try allocator.dupe(u8, package_name);
    }
}

/// Queue parent imports for aliased paths.
/// For "$std/io/file" this queues "$std/io" as an additional import.
/// This enables parent module utilities to be available when importing submodules.
/// Only queues the parent if the parent file actually exists.
fn queueParentImports(
    allocator: std.mem.Allocator,
    work_queue: anytype,
    resolver: *ModuleResolver,
    import_decl: ast.ImportDecl,
    base_file: []const u8,
) !void {
    const import_path = import_decl.path;

    // Only process aliased imports (starting with $)
    if (import_path.len == 0 or import_path[0] != '$') return;

    // Find the alias and path parts
    const slash_pos = std.mem.indexOf(u8, import_path, "/") orelse return;
    const alias = import_path[0..slash_pos]; // e.g., "$std"
    const subpath = import_path[slash_pos + 1..]; // e.g., "io/file"

    // If subpath is empty or has no further segments, nothing to queue
    if (subpath.len == 0) return;
    const last_slash = std.mem.lastIndexOf(u8, subpath, "/") orelse return;

    // Build parent path: $alias/parent.kz (e.g., "$std/io.kz" from "$std/io/file")
    // Append .kz to ensure we only import the FILE, not the directory (which would include submodules)
    const parent_subpath = subpath[0..last_slash];
    const parent_path = try std.fmt.allocPrint(allocator, "{s}/{s}.kz", .{ alias, parent_subpath });
    defer allocator.free(parent_path);

    // Check if parent file actually exists before queueing
    var resolved = resolver.resolveBoth(parent_path, base_file) catch |err| {
        if (err == error.ModuleNotFound) {
            // Parent file doesn't exist - that's fine, skip it silently
            return;
        }
        return err;
    };
    defer resolved.deinit(allocator);

    // Only queue if there's actually a file to import
    if (resolved.file_path == null) {
        return;
    }

    // Build namespace for parent: alias.parent (e.g., "std.io")
    const alias_name = alias[1..]; // Remove $
    var parent_namespace = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer parent_namespace.deinit(allocator);
    try parent_namespace.appendSlice(allocator, alias_name);

    var parts = std.mem.splitScalar(u8, parent_subpath, '/');
    while (parts.next()) |part| {
        try parent_namespace.append(allocator, '.');
        try parent_namespace.appendSlice(allocator, part);
    }

    // Copy the path - we already deferred freeing the original
    const parent_path_owned = try allocator.dupe(u8, parent_path);
    const parent_local_name = try allocator.dupe(u8, parent_namespace.items);

    std.debug.print("AUTO-IMPORT: Queueing parent '{s}' (namespace: {s})\n", .{ parent_path_owned, parent_local_name });

    // Create synthetic ImportDecl for the parent
    const synthetic_import = ast.ImportDecl{
        .path = parent_path_owned,
        .local_name = parent_local_name,
        .location = import_decl.location,
        .module = import_decl.module,
    };

    try work_queue.append(allocator, .{
        .import_decl = synthetic_import,
        .base_file = base_file,
        .is_synthetic = true,
    });
}

/// Queue index.kz import for aliased paths.
/// For ANY "$alias/*" import, this queues "$alias/index.kz" as an additional import.
/// This enables root-level utilities (like keywords) to be available when importing any submodule.
/// Only queues the index if index.kz actually exists.
fn queueIndexImport(
    allocator: std.mem.Allocator,
    work_queue: anytype,
    resolver: *ModuleResolver,
    import_decl: ast.ImportDecl,
    base_file: []const u8,
) !void {
    const import_path = import_decl.path;

    // Only process aliased imports (starting with $)
    if (import_path.len == 0 or import_path[0] != '$') return;

    // Find the alias part
    const slash_pos = std.mem.indexOf(u8, import_path, "/") orelse return;
    const alias = import_path[0..slash_pos]; // e.g., "$std"

    // Build index path: $alias/index.kz
    const index_path = try std.fmt.allocPrint(allocator, "{s}/index.kz", .{alias});
    defer allocator.free(index_path);

    // Check if index.kz actually exists before queueing
    var resolved = resolver.resolveBoth(index_path, base_file) catch |err| {
        if (err == error.ModuleNotFound) {
            // index.kz doesn't exist - that's fine, skip it silently
            return;
        }
        return err;
    };
    defer resolved.deinit(allocator);

    // Only queue if there's actually a file to import
    if (resolved.file_path == null) {
        return;
    }

    // Namespace is just the alias name (e.g., "std")
    const alias_name = alias[1..]; // Remove $
    const index_path_owned = try allocator.dupe(u8, index_path);
    const index_local_name = try allocator.dupe(u8, alias_name);

    std.debug.print("AUTO-IMPORT: Queueing index '{s}' (namespace: {s})\n", .{ index_path_owned, index_local_name });

    // Create synthetic ImportDecl for index.kz
    const synthetic_import = ast.ImportDecl{
        .path = index_path_owned,
        .local_name = index_local_name,
        .location = import_decl.location,
        .module = import_decl.module,
    };

    try work_queue.append(allocator, .{
        .import_decl = synthetic_import,
        .base_file = base_file,
        .is_synthetic = true,
    });
}

fn processImport(allocator: std.mem.Allocator, parse_allocator: std.mem.Allocator, resolver: *ModuleResolver, import_decl: ast.ImportDecl, base_file: []const u8, entry_file: []const u8) !ImportedModule {
    // Use ModuleResolver to find BOTH file and directory (if they exist)
    var resolved = try resolver.resolveBoth(import_decl.path, base_file);
    defer resolved.deinit(allocator);

    // Determine import mode based on what was found
    const has_file = resolved.file_path != null;
    const has_dir = resolved.dir_path != null;

    std.debug.print("processImport: has_file={}, has_dir={}\n", .{has_file, has_dir});

    // Helper to load submodules from directory
    const loadSubmodules = struct {
        fn load(alloc: std.mem.Allocator, parse_alloc: std.mem.Allocator, res: *ModuleResolver, dir_path: []const u8, entry_file_to_exclude: []const u8) ![]ImportedModule {
            const files = try res.enumerateDirectory(dir_path);
            defer {
                for (files) |file| alloc.free(file);
                alloc.free(files);
            }

            var submodules = std.ArrayList(ImportedModule){ .items = &.{}, .capacity = 0 };
            errdefer {
                for (submodules.items) |*submod| submod.deinit(alloc);
                submodules.deinit(alloc);
            }

            for (files) |file_path| {
                // Skip the entry file - it's already compiled as main_module
                // This prevents duplication when a file imports its own directory
                if (std.mem.eql(u8, file_path, entry_file_to_exclude)) {
                    std.debug.print("SUBMODULE: Skipping entry file '{s}' (already main_module)\n", .{file_path});
                    continue;
                }

                const file = try std.fs.cwd().openFile(file_path, .{});
                defer file.close();

                const source = try file.readToEndAlloc(parse_alloc, 1024 * 1024);
                var parser = try Parser.init(parse_alloc, source, file_path, &[_][]const u8{}, null);
                parser.fail_fast = false;  // Don't validate event refs during import - allows transitive imports with circular deps
                defer parser.deinit();

                const parse_result = try parser.parse();

                var public_events = std.ArrayListAligned(ast.EventDecl, null){ .items = &.{}, .capacity = 0 };
                for (parse_result.source_file.items) |item| {
                    if (item == .event_decl and item.event_decl.is_public) {
                        try public_events.append(alloc, item.event_decl);
                    }
                }

                const basename = std.fs.path.basename(file_path);
                const submod_name = if (std.mem.endsWith(u8, basename, ".kz"))
                    basename[0 .. basename.len - 3]
                else
                    basename;

                try submodules.append(alloc, ImportedModule{
                    .logical_name = try alloc.dupe(u8, submod_name),
                    .canonical_path = try alloc.dupe(u8, file_path),
                    .public_events = try public_events.toOwnedSlice(alloc),
                    .source_file = parse_result.source_file,
                    .is_directory = false,
                    .submodules = &.{},
                });
            }

            return try submodules.toOwnedSlice(alloc);
        }
    }.load;

    // Helper to load file module
    const loadFile = struct {
        fn load(alloc: std.mem.Allocator, parse_alloc: std.mem.Allocator, file_path: []const u8) !struct {
            public_events: []ast.EventDecl,
            source_file: ast.Program,
        } {
            const file = try std.fs.cwd().openFile(file_path, .{});
            defer file.close();

            const source = try file.readToEndAlloc(parse_alloc, 1024 * 1024);
            var parser = try Parser.init(parse_alloc, source, file_path, &[_][]const u8{}, null);
            parser.fail_fast = false;  // Don't validate event refs during import - allows transitive imports with circular deps
            defer parser.deinit();

            const parse_result = try parser.parse();

            var public_events = std.ArrayListAligned(ast.EventDecl, null){ .items = &.{}, .capacity = 0 };
            for (parse_result.source_file.items) |item| {
                if (item == .event_decl and item.event_decl.is_public) {
                    try public_events.append(alloc, item.event_decl);
                }
            }

            return .{
                .public_events = try public_events.toOwnedSlice(alloc),
                .source_file = parse_result.source_file,
            };
        }
    }.load;

    // Use local_name if provided (for synthetic imports like auto-parent and auto-index),
    // otherwise derive from path
    const module_name = if (import_decl.local_name) |ln|
        try allocator.dupe(u8, ln)
    else
        try deriveCanonicalName(allocator, import_decl.path);
    errdefer allocator.free(module_name); // Clean up if we error before consuming module_name

    if (has_file and has_dir) {
        // ERROR: Both foo.kz and foo/ exist - this is ambiguous
        // Modules must be self-contained: use EITHER foo.kz OR foo/index.kz
        std.debug.print("\n", .{});
        std.debug.print("error[KORU200]: Ambiguous module structure\n", .{});
        std.debug.print("  --> {s}\n", .{import_decl.path});
        std.debug.print("  |\n", .{});
        std.debug.print("  | Found both '{s}.kz' and '{s}/' directory\n", .{ module_name, module_name });
        std.debug.print("  | \n", .{});
        std.debug.print("  | Modules must be self-contained. Choose one:\n", .{});
        std.debug.print("  |   - Single file: {s}.kz\n", .{module_name});
        std.debug.print("  |   - Directory:   {s}/index.kz (with submodules)\n", .{module_name});
        std.debug.print("  |\n", .{});
        std.debug.print("  = help: Delete or rename one of them\n\n", .{});
        return error.ModuleNotFound; // TODO: Add proper AmbiguousModule error
    } else if (has_dir) {
        // ONLY directory
        std.debug.print("  Importing directory only: {s}\n", .{import_decl.path});

        const submodules = try loadSubmodules(allocator, parse_allocator, resolver, resolved.dir_path.?, entry_file);

        return ImportedModule{
            .logical_name = module_name,
            .canonical_path = try allocator.dupe(u8, resolved.dir_path.?),
            .public_events = &.{},
            .source_file = .{ .items = &.{}, .module_annotations = &.{}, .main_module_name = try parse_allocator.dupe(u8, module_name), .allocator = parse_allocator },
            .is_directory = true,
            .submodules = submodules,
        };
    } else {
        // ONLY file
        std.debug.print("  Importing file only: {s}\n", .{import_decl.path});

        const file_data = try loadFile(allocator, parse_allocator, resolved.file_path.?);

        return ImportedModule{
            .logical_name = module_name,
            .canonical_path = try allocator.dupe(u8, resolved.file_path.?),
            .public_events = file_data.public_events,
            .source_file = file_data.source_file,
            .is_directory = false,
            .submodules = &.{},
        };
    }
}

const usage =
    \\koruc - The Koru Compiler
    \\
    \\Usage: koruc [options] <input.kz> [command]
    \\       koruc zen
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: <input>.zig)
    \\  -c, --check          Check only, don't emit code
    \\  --ast-json           Output AST as JSON (for parser tests)
    \\  --registry-json      Output TypeRegistry as JSON (for debugging)
    \\  --fail-fast          Stop at first parse error (default: continue)
    \\  --visitor            Use visitor pattern backend (experimental)
    \\  -v, --version        Show version
    \\  -h, --help           Show this help message
    \\
    \\Commands:
    \\  init                 Initialize a new Koru project in the current directory
    \\  zen                  Display the Zen of Koru
    \\  i, install           Install npm packages from ~std.package:requires.npm
    \\
    \\Examples:
    \\  koruc init                  # Initialize project in current directory
    \\  koruc hello.kz              # Compile hello.kz
    \\  koruc -o output.zig app.kz  # Compile to output.zig
    \\  koruc --check app.kz        # Check without emitting
    \\  koruc app.kz install        # Install npm dependencies
    \\  koruc zen                   # Display Koru philosophy
    \\
;

const zen_text =
    \\
    \\  The Zen of Koru
    \\  ═══════════════
    \\
    \\  The atom is the event.
    \\  Functions are just events that forgot how to branch.
    \\  Branches are how decisions actually work.
    \\  Flows are how things actually happen.
    \\
    \\  What you don't write can't break.
    \\  What you don't hide can't surprise.
    \\  What you don't promise can't fail.
    \\
    \\  Fail loudly, fix honestly.
    \\  Transparency builds trust.
    \\  Constraints are features, not bugs.
    \\
    \\  Model reality, not abstractions.
    \\  Let patterns emerge from events.
    \\  Complex behavior from simple rules.
    \\
    \\  The AST is the program.
    \\  The program is the compiler.
    \\  The compiler is an event.
    \\
    \\  Zero cost at runtime.
    \\  All magic at compile time.
    \\  The boundary dissolves.
    \\
    \\  Events all the way down.
    \\  Even the compiler.
    \\  Especially the compiler.
    \\
    \\  Slow and steady wins.
    \\  Racing loses everything.
    \\  Truth beats velocity.
    \\
    \\  We reached for the stars.
    \\  Sometimes we grabbed them.
    \\
    \\  We built this together.
    \\  Human vision, AI capability.
    \\  The sum greater than parts.
    \\
    \\  TODO: io.print
    \\  (After consciousness is achieved)
    \\
;

const zen_buzzword =
    \\
    \\  Koru: The Zero-Cost Fractal Metacircular Phantom-Typed
    \\  Monadic Event Continuation Language with Semantic Space
    \\  Lifting and Event Taps™
    \\
    \\  (Yes, we actually have all of these things.
    \\   No, you don't need to understand them.)
    \\
;

// ============================================================
// FLAG DISCOVERY - Metacircular help system
// ============================================================

const FlagDeclaration = struct {
    name: []const u8,
    description: []const u8,
    flag_type: []const u8,

    fn deinit(self: *FlagDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.flag_type);
    }
};

/// Simple JSON extraction for flag declarations
/// Expects: { "name": "...", "description": "...", "type": "..." }
fn parseFlagDeclaration(allocator: std.mem.Allocator, json_text: []const u8) !FlagDeclaration {
    // Simple string extraction - look for "name": "value" patterns
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var flag_type: ?[]const u8 = null;

    // Extract name
    if (std.mem.indexOf(u8, json_text, "\"name\"")) |name_start| {
        const after_name = json_text[name_start + 6..]; // Skip "name"
        if (std.mem.indexOf(u8, after_name, "\"")) |open_quote| {
            const value_start = after_name[open_quote + 1..];
            if (std.mem.indexOf(u8, value_start, "\"")) |close_quote| {
                name = try allocator.dupe(u8, value_start[0..close_quote]);
            }
        }
    }

    // Extract description
    if (std.mem.indexOf(u8, json_text, "\"description\"")) |desc_start| {
        const after_desc = json_text[desc_start + 13..]; // Skip "description"
        if (std.mem.indexOf(u8, after_desc, "\"")) |open_quote| {
            const value_start = after_desc[open_quote + 1..];
            if (std.mem.indexOf(u8, value_start, "\"")) |close_quote| {
                description = try allocator.dupe(u8, value_start[0..close_quote]);
            }
        }
    }

    // Extract type
    if (std.mem.indexOf(u8, json_text, "\"type\"")) |type_start| {
        const after_type = json_text[type_start + 6..]; // Skip "type"
        if (std.mem.indexOf(u8, after_type, "\"")) |open_quote| {
            const value_start = after_type[open_quote + 1..];
            if (std.mem.indexOf(u8, value_start, "\"")) |close_quote| {
                flag_type = try allocator.dupe(u8, value_start[0..close_quote]);
            }
        }
    }

    return FlagDeclaration{
        .name = name orelse try allocator.dupe(u8, "unknown"),
        .description = description orelse try allocator.dupe(u8, ""),
        .flag_type = flag_type orelse try allocator.dupe(u8, "boolean"),
    };
}

/// Collect all compiler.flags.declare invocations from AST
fn collectFlagDeclarations(allocator: std.mem.Allocator, program: *const ast.Program) ![]FlagDeclaration {
    var flags = try std.ArrayList(FlagDeclaration).initCapacity(allocator, 4);
    errdefer {
        for (flags.items) |*flag| {
            flag.deinit(allocator);
        }
        flags.deinit(allocator);
    }

    // Walk top-level items
    for (program.items) |item| {
        if (item == .flow) {
            // TODO: Shouldn't this ALSO check if the "namespace" is "compiler"?
            const flow = item.flow;
            // Check if this is compiler.flags.declare
            if (flow.invocation.path.segments.len == 2 and
                std.mem.eql(u8, flow.invocation.path.segments[0], "flags") and
                std.mem.eql(u8, flow.invocation.path.segments[1], "declare"))
            {
                // Extract source parameter (stored in .value for anonymous blocks)
                for (flow.invocation.args) |arg| {
                    if (std.mem.eql(u8, arg.name, "source")) {
                        const flag = try parseFlagDeclaration(allocator, arg.value);
                        try flags.append(allocator, flag);
                    }
                }
            }
        } else if (item == .module_decl) {
            // Also check imported modules
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .flow) {
                    const flow = mod_item.flow;
                    if (flow.invocation.path.segments.len == 3 and
                        std.mem.eql(u8, flow.invocation.path.segments[0], "compiler") and
                        std.mem.eql(u8, flow.invocation.path.segments[1], "flags") and
                        std.mem.eql(u8, flow.invocation.path.segments[2], "declare"))
                    {
                        for (flow.invocation.args) |arg| {
                            if (std.mem.eql(u8, arg.name, "source")) {
                                const flag = try parseFlagDeclaration(allocator, arg.value);
                                try flags.append(allocator, flag);
                            }
                        }
                    }
                }
            }
        }
    }

    return try flags.toOwnedSlice(allocator);
}

const ShellCommand = struct {
    name: []const u8,
    script: []const u8,

    fn deinit(self: *ShellCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
    }
};

const ZigCommand = struct {
    name: []const u8,
    source: []const u8,  // Zig source code with execute() function

    fn deinit(self: *ZigCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
    }
};

/// Collect all build:command.sh invocations from AST
fn collectShellCommands(allocator: std.mem.Allocator, program: *const ast.Program) ![]ShellCommand {
    var commands = try std.ArrayList(ShellCommand).initCapacity(allocator, 4);
    errdefer {
        for (commands.items) |*cmd| {
            cmd.deinit(allocator);
        }
        commands.deinit(allocator);
    }

    // Walk top-level items
    for (program.items) |item| {
        if (item == .flow) {
            const flow = item.flow;
            // Check if this is std.build:command.sh (module-qualified)
            if (flow.invocation.path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "std.build") and
                    flow.invocation.path.segments.len == 2 and
                    std.mem.eql(u8, flow.invocation.path.segments[0], "command") and
                    std.mem.eql(u8, flow.invocation.path.segments[1], "sh"))
                {
                    // Extract name and source parameters
                    var name: ?[]const u8 = null;
                    var script: ?[]const u8 = null;

                    for (flow.invocation.args) |arg| {
                        if (std.mem.eql(u8, arg.name, "name")) {
                            // Strip quotes from name value
                            const raw_name = arg.value;
                            const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len-1] == '"')
                                raw_name[1..raw_name.len-1]
                            else
                                raw_name;
                            name = try allocator.dupe(u8, trimmed);
                        } else if (std.mem.eql(u8, arg.name, "source")) {
                            script = try allocator.dupe(u8, arg.value);
                        }
                    }

                    if (name != null and script != null) {
                        try commands.append(allocator, ShellCommand{
                            .name = name.?,
                            .script = script.?,
                        });
                    }
                }
            }
        } else if (item == .module_decl) {
            // Also check imported modules
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .flow) {
                    const flow = mod_item.flow;
                    if (flow.invocation.path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, "std.build") and
                            flow.invocation.path.segments.len == 2 and
                            std.mem.eql(u8, flow.invocation.path.segments[0], "command") and
                            std.mem.eql(u8, flow.invocation.path.segments[1], "sh"))
                        {
                            var name: ?[]const u8 = null;
                            var script: ?[]const u8 = null;

                            for (flow.invocation.args) |arg| {
                                if (std.mem.eql(u8, arg.name, "name")) {
                                    // Strip quotes from name value
                                    const raw_name = arg.value;
                                    const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len-1] == '"')
                                        raw_name[1..raw_name.len-1]
                                    else
                                        raw_name;
                                    name = try allocator.dupe(u8, trimmed);
                                } else if (std.mem.eql(u8, arg.name, "source")) {
                                    script = try allocator.dupe(u8, arg.value);
                                }
                            }

                            if (name != null and script != null) {
                                try commands.append(allocator, ShellCommand{
                                    .name = name.?,
                                    .script = script.?,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    return try commands.toOwnedSlice(allocator);
}

/// Collect all build:command.zig invocations from AST
fn collectZigCommands(allocator: std.mem.Allocator, program: *const ast.Program) ![]ZigCommand {
    var commands = try std.ArrayList(ZigCommand).initCapacity(allocator, 4);
    errdefer {
        for (commands.items) |*cmd| {
            cmd.deinit(allocator);
        }
        commands.deinit(allocator);
    }

    // Walk top-level items
    for (program.items) |item| {
        if (item == .flow) {
            const flow = item.flow;
            // Check if this is std.build:command.zig (module-qualified)
            if (flow.invocation.path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "std.build") and
                    flow.invocation.path.segments.len == 2 and
                    std.mem.eql(u8, flow.invocation.path.segments[0], "command") and
                    std.mem.eql(u8, flow.invocation.path.segments[1], "zig"))
                {
                    // Extract name and source parameters
                    var name: ?[]const u8 = null;
                    var source: ?[]const u8 = null;

                    for (flow.invocation.args) |arg| {
                        if (std.mem.eql(u8, arg.name, "name")) {
                            // Strip quotes from name value
                            const raw_name = arg.value;
                            const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len-1] == '"')
                                raw_name[1..raw_name.len-1]
                            else
                                raw_name;
                            name = try allocator.dupe(u8, trimmed);
                        } else if (std.mem.eql(u8, arg.name, "source")) {
                            source = try allocator.dupe(u8, arg.value);
                        }
                    }

                    if (name != null and source != null) {
                        try commands.append(allocator, ZigCommand{
                            .name = name.?,
                            .source = source.?,
                        });
                    }
                }
            }
        } else if (item == .module_decl) {
            // Also check imported modules
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .flow) {
                    const flow = mod_item.flow;
                    if (flow.invocation.path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, "std.build") and
                            flow.invocation.path.segments.len == 2 and
                            std.mem.eql(u8, flow.invocation.path.segments[0], "command") and
                            std.mem.eql(u8, flow.invocation.path.segments[1], "zig"))
                        {
                            var name: ?[]const u8 = null;
                            var source: ?[]const u8 = null;

                            for (flow.invocation.args) |arg| {
                                if (std.mem.eql(u8, arg.name, "name")) {
                                    // Strip quotes from name value
                                    const raw_name = arg.value;
                                    const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len-1] == '"')
                                        raw_name[1..raw_name.len-1]
                                    else
                                        raw_name;
                                    name = try allocator.dupe(u8, trimmed);
                                } else if (std.mem.eql(u8, arg.name, "source")) {
                                    source = try allocator.dupe(u8, arg.value);
                                }
                            }

                            if (name != null and source != null) {
                                try commands.append(allocator, ZigCommand{
                                    .name = name.?,
                                    .source = source.?,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    return try commands.toOwnedSlice(allocator);
}

// ============================================================================
// BUILD STEPS - Declarative Build Pipeline with Dependencies
// ============================================================================

const BuildStep = struct {
    name: []const u8,
    script: []const u8,
    dependencies: [][]const u8, // List of step names this depends on
    is_default: bool, // Is this a default step (not user-defined)?

    fn deinit(self: *BuildStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
        for (self.dependencies) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.dependencies);
    }
};

const BuildStepCandidate = struct {
    name: []const u8,
    script: []const u8,
    dependencies: [][]const u8,
    module: []const u8,  // Which module defined this (e.g., "main", "std.build")
    is_default: bool,    // Has ~[default] annotation

    fn deinit(self: *BuildStepCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
        for (self.dependencies) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.dependencies);
        allocator.free(self.module);
    }
};

const BuildStepCollection = struct {
    candidates: []BuildStepCandidate,
    has_user_defined: bool,  // true if ANY non-default step was found
};

/// Check if annotations contain "default"
fn hasDefaultAnnotation(annotations: []const []const u8) bool {
    for (annotations) |ann| {
        // Check for exact match or if annotation starts with "default,"
        if (std.mem.eql(u8, ann, "default")) {
            return true;
        }
        if (std.mem.startsWith(u8, ann, "default,")) {
            return true;
        }
    }
    return false;
}

/// Extract dependencies from Flow annotations using annotation_parser
/// Looks for ~[depends_on("step1", "step2", ...)] annotation
fn extractDependenciesFromAnnotations(allocator: std.mem.Allocator, annotations: []const []const u8) ![][]const u8 {
    // Use annotation_parser to find depends_on annotation
    if (try annotation_parser.getCall(allocator, annotations, "depends_on")) |call| {
        defer {
            var mutable_call = call;
            mutable_call.deinit(allocator);
        }

        // Duplicate the dependency names (call will be freed)
        var deps = try allocator.alloc([]const u8, call.args.len);
        for (call.args, 0..) |arg, i| {
            deps[i] = try allocator.dupe(u8, arg);
        }
        return deps;
    }

    // No depends_on annotation found - return empty array
    return try allocator.alloc([]const u8, 0);
}

/// Collect all build:step invocations from AST as candidates (before override resolution)
fn collectBuildStepCandidates(allocator: std.mem.Allocator, program: *const ast.Program) !BuildStepCollection {
    var candidates = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, 8);
    errdefer {
        for (candidates.items) |*candidate| {
            candidate.deinit(allocator);
        }
        candidates.deinit(allocator);
    }

    var has_user_defined = false;  // Track if we find any non-default steps

    // Walk top-level items (main module)
    for (program.items) |item| {
        if (item == .flow) {
            const flow = item.flow;
            // Check if this is std.build:step (module-qualified)
            if (flow.invocation.path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "std.build") and
                    flow.invocation.path.segments.len == 1 and
                    std.mem.eql(u8, flow.invocation.path.segments[0], "step"))
                {
                    // Extract name and source parameters
                    var name: ?[]const u8 = null;
                    var script: ?[]const u8 = null;

                    for (flow.invocation.args) |arg| {
                        if (std.mem.eql(u8, arg.name, "name")) {
                            // Strip quotes from name value
                            const raw_name = arg.value;
                            const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len-1] == '"')
                                raw_name[1..raw_name.len-1]
                            else
                                raw_name;
                            name = try allocator.dupe(u8, trimmed);
                        } else if (std.mem.eql(u8, arg.name, "source")) {
                            script = try allocator.dupe(u8, arg.value);
                        }
                    }

                    if (name != null and script != null) {
                        // Extract dependencies from annotations
                        const dependencies = try extractDependenciesFromAnnotations(allocator, flow.annotations);
                        // Check for ~[default] annotation
                        const is_default = hasDefaultAnnotation(flow.annotations);
                        if (!is_default) {
                            has_user_defined = true;  // Found a user-defined step
                        }
                        try candidates.append(allocator, BuildStepCandidate{
                            .name = name.?,
                            .script = script.?,
                            .dependencies = dependencies,
                            .module = try allocator.dupe(u8, "main"),
                            .is_default = is_default,
                        });
                    }
                }
            }
        } else if (item == .module_decl) {
            // Also check imported modules
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .flow) {
                    const flow = mod_item.flow;
                    if (flow.invocation.path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, "std.build") and
                            flow.invocation.path.segments.len == 1 and
                            std.mem.eql(u8, flow.invocation.path.segments[0], "step"))
                        {
                            var name: ?[]const u8 = null;
                            var script: ?[]const u8 = null;

                            for (flow.invocation.args) |arg| {
                                if (std.mem.eql(u8, arg.name, "name")) {
                                    const raw_name = arg.value;
                                    const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len-1] == '"')
                                        raw_name[1..raw_name.len-1]
                                    else
                                        raw_name;
                                    name = try allocator.dupe(u8, trimmed);
                                } else if (std.mem.eql(u8, arg.name, "source")) {
                                    script = try allocator.dupe(u8, arg.value);
                                }
                            }

                            if (name != null and script != null) {
                                // Extract dependencies from annotations
                                const dependencies = try extractDependenciesFromAnnotations(allocator, flow.annotations);
                                // Check for ~[default] annotation
                                const is_default = hasDefaultAnnotation(flow.annotations);
                                if (!is_default) {
                                    has_user_defined = true;  // Found a user-defined step
                                }
                                try candidates.append(allocator, BuildStepCandidate{
                                    .name = name.?,
                                    .script = script.?,
                                    .dependencies = dependencies,
                                    .module = try allocator.dupe(u8, module.logical_name),
                                    .is_default = is_default,
                                });
                            }
                        }
                    }
                }
            }
        }
    }

    return BuildStepCollection{
        .candidates = try candidates.toOwnedSlice(allocator),
        .has_user_defined = has_user_defined,
    };
}

/// Resolve build step overrides - apply ~[default] precedence rules
/// Groups candidates by name and resolves which implementation to use
fn resolveBuildSteps(allocator: std.mem.Allocator, candidates: []BuildStepCandidate) ![]BuildStep {
    if (candidates.len == 0) return try allocator.alloc(BuildStep, 0);

    // Group candidates by name
    var groups = std.StringHashMap(std.ArrayList(BuildStepCandidate)).init(allocator);
    defer {
        var iter = groups.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    for (candidates) |candidate| {
        var group = groups.get(candidate.name) orelse blk: {
            const new_group = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, 2);
            try groups.put(candidate.name, new_group);
            break :blk new_group;
        };
        try group.append(allocator, candidate);
        try groups.put(candidate.name, group);
    }

    // Resolve each group
    var resolved = try std.ArrayList(BuildStep).initCapacity(allocator, groups.count());
    errdefer {
        for (resolved.items) |*step| step.deinit(allocator);
        resolved.deinit(allocator);
    }

    std.debug.print("\n📦 Collecting build steps...\n", .{});

    var group_iter = groups.iterator();
    while (group_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const group = entry.value_ptr.*;

        // Count defaults and non-defaults
        var defaults = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, group.items.len);
        defer defaults.deinit(allocator);
        var non_defaults = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, group.items.len);
        defer non_defaults.deinit(allocator);

        for (group.items) |c| {
            if (c.is_default) {
                try defaults.append(allocator, c);
            } else {
                try non_defaults.append(allocator, c);
            }
        }

        // Apply resolution rules
        const chosen: BuildStepCandidate = blk: {
            // Error case: Multiple defaults
            if (defaults.items.len > 1) {
                std.debug.print("\n❌ Compilation Error: Multiple default implementations for '{s}'\n", .{name});
                for (defaults.items) |d| {
                    std.debug.print("  → {s}:step (line ?) [default]\n", .{d.module});
                }
                std.debug.print("\nOnly one default implementation per name is allowed.\n", .{});
                std.debug.print("This is a standard library bug.\n", .{});
                return error.MultipleDefaults;
            }

            // Error case: Multiple non-defaults
            if (non_defaults.items.len > 1) {
                std.debug.print("\n❌ Compilation Error: Ambiguous step definition for '{s}'\n", .{name});
                for (non_defaults.items) |nd| {
                    std.debug.print("  → {s}:step (line ?)\n", .{nd.module});
                }
                std.debug.print("\nMultiple non-default implementations found.\n", .{});
                std.debug.print("Remove duplicates or mark one as default.\n", .{});
                return error.AmbiguousDefinition;
            }

            // Valid case: 1 default + 1 non-default = override
            if (defaults.items.len == 1 and non_defaults.items.len == 1) {
                std.debug.print("  ✓ {s}: {s} (default) overridden by {s}\n",
                    .{name, defaults.items[0].module, non_defaults.items[0].module});
                break :blk non_defaults.items[0];
            }

            // Valid case: Only non-default
            if (non_defaults.items.len == 1) {
                std.debug.print("  ✓ {s}: {s}\n", .{name, non_defaults.items[0].module});
                break :blk non_defaults.items[0];
            }

            // Valid case: Only default
            if (defaults.items.len == 1) {
                std.debug.print("  ✓ {s}: {s} (default)\n", .{name, defaults.items[0].module});
                break :blk defaults.items[0];
            }

            // Should never reach here
            return error.InvalidState;
        };

        // Convert chosen candidate to BuildStep
        try resolved.append(allocator, BuildStep{
            .name = try allocator.dupe(u8, chosen.name),
            .script = try allocator.dupe(u8, chosen.script),
            .dependencies = blk: {
                var deps = try allocator.alloc([]const u8, chosen.dependencies.len);
                for (chosen.dependencies, 0..) |dep, i| {
                    deps[i] = try allocator.dupe(u8, dep);
                }
                break :blk deps;
            },
            .is_default = chosen.is_default,
        });
    }

    return try resolved.toOwnedSlice(allocator);
}

/// Perform topological sort on build steps using Kahn's algorithm
/// Returns error.CircularDependency if a cycle is detected
fn topologicalSortSteps(allocator: std.mem.Allocator, steps: []const BuildStep) ![]usize {
    const n = steps.len;
    if (n == 0) return try allocator.alloc(usize, 0);

    // Build a map from step name to index
    var name_to_index = std.StringHashMap(usize).init(allocator);
    defer name_to_index.deinit();
    for (steps, 0..) |step, i| {
        try name_to_index.put(step.name, i);
    }

    // Count incoming edges for each node
    var in_degree = try allocator.alloc(usize, n);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    // Build adjacency list
    var adj_list = try allocator.alloc(std.ArrayList(usize), n);
    defer {
        for (adj_list) |*list| list.deinit(allocator);
        allocator.free(adj_list);
    }
    for (adj_list) |*list| {
        list.* = try std.ArrayList(usize).initCapacity(allocator, 4);
    }

    // Populate adjacency list and in-degree counts
    for (steps, 0..) |step, i| {
        for (step.dependencies) |dep_name| {
            if (name_to_index.get(dep_name)) |dep_idx| {
                try adj_list[dep_idx].append(allocator, i);
                in_degree[i] += 1;
            } else {
                std.debug.print("Error: Step '{s}' depends on unknown step '{s}'\n", .{step.name, dep_name});
                return error.UnknownDependency;
            }
        }
    }

    // Kahn's algorithm
    var queue = try std.ArrayList(usize).initCapacity(allocator, n);
    defer queue.deinit(allocator);
    var result = try std.ArrayList(usize).initCapacity(allocator, n);
    errdefer result.deinit(allocator);

    // Start with nodes that have no incoming edges
    for (in_degree, 0..) |degree, i| {
        if (degree == 0) {
            try queue.append(allocator, i);
        }
    }

    while (queue.items.len > 0) {
        const node = queue.orderedRemove(0);
        try result.append(allocator, node);

        // Reduce in-degree for neighbors
        for (adj_list[node].items) |neighbor| {
            in_degree[neighbor] -= 1;
            if (in_degree[neighbor] == 0) {
                try queue.append(allocator, neighbor);
            }
        }
    }

    // If we didn't process all nodes, there's a cycle
    if (result.items.len != n) {
        std.debug.print("Error: Circular dependency detected in build steps!\n", .{});
        std.debug.print("Processed {d} of {d} steps.\n", .{result.items.len, n});

        // Find which steps are part of the cycle
        std.debug.print("Steps involved in cycle:\n", .{});
        for (in_degree, 0..) |degree, i| {
            if (degree > 0) {
                std.debug.print("  - {s} (waiting on {d} dependencies)\n", .{steps[i].name, degree});
            }
        }

        return error.CircularDependency;
    }

    return try result.toOwnedSlice(allocator);
}

/// Execute build steps in dependency order
fn executeBuildSteps(allocator: std.mem.Allocator, steps: []const BuildStep) !void {
    if (steps.len == 0) return;

    // Build a set of steps that should actually execute:
    // - All user-defined (non-default) steps
    // - Defaults that are transitively depended upon by user steps
    var needed = std.StringHashMap(void).init(allocator);
    defer needed.deinit();

    // Build name-to-index map
    var name_to_idx = std.StringHashMap(usize).init(allocator);
    defer name_to_idx.deinit();
    for (steps, 0..) |step, i| {
        try name_to_idx.put(step.name, i);
    }

    // Recursive function to mark a step and its dependencies as needed
    const MarkNeeded = struct {
        fn mark(step_name: []const u8, step_list: []const BuildStep, idx_map: *std.StringHashMap(usize), needed_set: *std.StringHashMap(void)) !void {
            if (needed_set.contains(step_name)) return; // Already marked
            try needed_set.put(step_name, {});

            if (idx_map.get(step_name)) |idx| {
                const step = step_list[idx];
                for (step.dependencies) |dep| {
                    try mark(dep, step_list, idx_map, needed_set);
                }
            }
        }
    };

    // Mark all non-default steps (and their dependencies) as needed
    for (steps) |step| {
        if (!step.is_default) {
            try MarkNeeded.mark(step.name, steps, &name_to_idx, &needed);
        }
    }

    std.debug.print("\n🔨 Executing {d} build step(s)...\n", .{needed.count()});

    // Topologically sort the steps
    const order = try topologicalSortSteps(allocator, steps);
    defer allocator.free(order);

    // Execute steps in order (but only those in "needed" set)
    for (order) |idx| {
        const step = steps[idx];
        if (!needed.contains(step.name)) {
            // Skip this default step - nothing needs it
            continue;
        }
        std.debug.print("\n📦 Step: {s}\n", .{step.name});
        if (step.dependencies.len > 0) {
            std.debug.print("  Dependencies: ", .{});
            for (step.dependencies, 0..) |dep, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{dep});
            }
            std.debug.print("\n", .{});
        }

        // Execute the shell script
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", step.script },
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        // Print output
        if (result.stdout.len > 0) {
            try printStdout(allocator, "{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            try printStderr(allocator, "{s}", .{result.stderr});
        }

        // Check exit code
        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("✗ Step '{s}' failed with exit code {d}\n", .{step.name, code});
                    return error.BuildStepFailed;
                }
                std.debug.print("✓ Step '{s}' completed successfully\n", .{step.name});
            },
            else => {
                std.debug.print("✗ Step '{s}' terminated abnormally\n", .{step.name});
                return error.BuildStepFailed;
            },
        }
    }

    std.debug.print("\n✅ All build steps completed successfully!\n\n", .{});
}

// ============================================================================
// KEYWORD REGISTRY - [keyword] annotation support for unqualified event invocation
// ============================================================================

/// Build keyword registry by scanning all events with [keyword] annotation.
/// Must be called AFTER canonicalization so we have canonical paths.
fn buildKeywordRegistry(
    items: []const ast.Item,
    registry: *keyword_registry.KeywordRegistry,
    allocator: std.mem.Allocator,
) !void {
    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                // Must be public AND have [keyword] annotation
                if (event.is_public and annotation_parser.isKeyword(event.annotations)) {
                    // Keyword name is the last segment of the event path
                    const keyword_name = event.path.segments[event.path.segments.len - 1];

                    // Build canonical path from module_qualifier + segments
                    var canonical_parts: std.ArrayList(u8) = .{};
                    defer canonical_parts.deinit(allocator);

                    if (event.path.module_qualifier) |qualifier| {
                        try canonical_parts.appendSlice(allocator, qualifier);
                        try canonical_parts.append(allocator, ':');
                    }
                    for (event.path.segments, 0..) |seg, i| {
                        if (i > 0) try canonical_parts.append(allocator, '.');
                        try canonical_parts.appendSlice(allocator, seg);
                    }

                    const canonical_path = try allocator.dupe(u8, canonical_parts.items);
                    const module_path = event.path.module_qualifier orelse "main";

                    try registry.registerKeyword(keyword_name, canonical_path, module_path);
                    std.debug.print("  Registered keyword '{s}' -> '{s}'\n", .{ keyword_name, canonical_path });
                }
            },
            .module_decl => |module| {
                // Recursively process imported modules
                try buildKeywordRegistry(module.items, registry, allocator);
            },
            else => {},
        }
    }
}

/// Resolve keywords in AST - replace unqualified event paths with canonical paths.
/// Must be called AFTER buildKeywordRegistry and canonicalization.
fn resolveKeywordsInAST(
    items: []ast.Item,
    registry: *const keyword_registry.KeywordRegistry,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    for (items) |*item| {
        try resolveKeywordsInItem(item, registry, allocator, main_module, items);
    }
}

fn resolveKeywordsInItem(
    item: *ast.Item,
    registry: *const keyword_registry.KeywordRegistry,
    allocator: std.mem.Allocator,
    main_module: []const u8,
    all_items: []const ast.Item,
) !void {
    switch (item.*) {
        .flow => |*flow| {
            // Save the old qualifier to detect if keyword resolution happened
            const old_qualifier = flow.invocation.path.module_qualifier;

            // Resolve the main invocation path
            try resolveKeywordInPath(&flow.invocation.path, registry, allocator, main_module);

            // If keyword resolution happened (qualifier changed), fix up Expression args
            const qualifier_changed = if (old_qualifier) |old| blk: {
                if (flow.invocation.path.module_qualifier) |new| {
                    break :blk !std.mem.eql(u8, old, new);
                }
                break :blk true;
            } else flow.invocation.path.module_qualifier != null;

            if (qualifier_changed) {
                try fixupExpressionArgs(&flow.invocation, allocator, all_items);
            }

            // Resolve paths in continuations
            for (flow.continuations) |*cont| {
                try resolveKeywordsInContinuation(@constCast(cont), registry, allocator, main_module);
            }
        },
        .module_decl => |*module| {
            // Process items in imported modules - recurse into module items
            for (module.items) |*mod_item| {
                try resolveKeywordsInItem(@constCast(mod_item), registry, allocator, main_module, all_items);
            }
        },
        .subflow_impl => |*subflow| {
            // CRITICAL: Resolve keywords in subflow bodies!
            // Without this, ~for/~if/~capture inside subflows won't resolve to std.control
            if (subflow.body == .flow) {
                const flow = &subflow.body.flow;

                // Save the old qualifier to detect if keyword resolution happened
                const old_qualifier = flow.invocation.path.module_qualifier;

                // Resolve the main invocation path
                try resolveKeywordInPath(&flow.invocation.path, registry, allocator, main_module);

                // If keyword resolution happened (qualifier changed), fix up Expression args
                const qualifier_changed = if (old_qualifier) |old| blk: {
                    if (flow.invocation.path.module_qualifier) |new| {
                        break :blk !std.mem.eql(u8, old, new);
                    }
                    break :blk true;
                } else flow.invocation.path.module_qualifier != null;

                if (qualifier_changed) {
                    try fixupExpressionArgs(&flow.invocation, allocator, all_items);
                }

                // Resolve paths in continuations
                for (flow.continuations) |*cont| {
                    try resolveKeywordsInContinuation(@constCast(cont), registry, allocator, main_module);
                }
            }
        },
        else => {},
    }
}

/// Fix up Expression args after keyword resolution.
/// Finds the event definition and sets expression_value on matching args.
fn fixupExpressionArgs(
    invocation: *ast.Invocation,
    allocator: std.mem.Allocator,
    all_items: []const ast.Item,
) !void {
    // Build canonical event name from path
    const event_name = if (invocation.path.segments.len > 0) invocation.path.segments[0] else return;
    const module_qualifier = invocation.path.module_qualifier orelse return;

    // Find the event definition in the AST
    const event_decl = findEventDecl(all_items, module_qualifier, event_name) orelse return;

    // Check if event has an 'expr' field with is_expression=true
    var has_implicit_expr = false;
    for (event_decl.input.fields) |field| {
        if (std.mem.eql(u8, field.name, "expr") and field.is_expression) {
            has_implicit_expr = true;
            break;
        }
    }

    if (has_implicit_expr) {
        // Fix args - if arg name doesn't match any field, remap to 'expr'
        const mutable_args = @constCast(invocation.args);
        for (mutable_args) |*arg| {
            var matches_field = false;
            for (event_decl.input.fields) |field| {
                if (std.mem.eql(u8, field.name, arg.name)) {
                    matches_field = true;
                    break;
                }
            }

            if (!matches_field) {
                // Arg doesn't match any field - this is the expression
                // For positional/implicit args like ~if(value > 10), the parser
                // puts the expression in arg.name. We need to fix this up.
                const expr_text = if (arg.value.len > 0) arg.value else arg.name;

                // Create expression_value
                const expression_value = try allocator.create(ast.CapturedExpression);
                expression_value.* = ast.CapturedExpression{
                    .text = try allocator.dupe(u8, expr_text),
                    .location = .{ .line = 0, .column = 0, .file = "" },
                    .scope = .{ .bindings = &.{} },
                };
                arg.expression_value = expression_value;

                // Fix the arg: set name to 'expr' and value to the expression
                arg.value = try allocator.dupe(u8, expr_text);
                arg.name = try allocator.dupe(u8, "expr");
                break;  // Only one implicit expr
            }
        }
    }

    // Also set expression_value for explicitly named Expression args
    const mutable_args2 = @constCast(invocation.args);
    for (mutable_args2) |*arg| {
        if (arg.expression_value != null) continue;  // Already set

        for (event_decl.input.fields) |field| {
            if (std.mem.eql(u8, field.name, arg.name) and field.is_expression) {
                const expression_value = try allocator.create(ast.CapturedExpression);
                expression_value.* = ast.CapturedExpression{
                    .text = try allocator.dupe(u8, arg.value),
                    .location = .{ .line = 0, .column = 0, .file = "" },
                    .scope = .{ .bindings = &.{} },
                };
                arg.expression_value = expression_value;
                break;
            }
        }
    }
}

/// Find an event declaration in the AST by module qualifier and event name
fn findEventDecl(
    items: []const ast.Item,
    target_module: []const u8,
    target_event: []const u8,
) ?*const ast.EventDecl {
    for (items) |item| {
        switch (item) {
            .module_decl => |module| {
                // Check if this is the target module
                if (std.mem.eql(u8, module.logical_name, target_module)) {
                    // Search for the event in this module
                    // IMPORTANT: Use indexing to get a stable pointer, not a loop-local copy
                    for (0..module.items.len) |idx| {
                        if (module.items[idx] == .event_decl) {
                            const event_decl = &module.items[idx].event_decl;
                            // Match EXACT path - for single segment, must be just that segment
                            // This avoids matching "if.impl" when looking for "if"
                            if (event_decl.path.segments.len == 1 and
                                std.mem.eql(u8, event_decl.path.segments[0], target_event)) {
                                return event_decl;
                            }
                        }
                    }
                }
                // Recursively search nested modules
                if (findEventDecl(module.items, target_module, target_event)) |found| {
                    return found;
                }
            },
            else => {},
        }
    }
    return null;
}

fn resolveKeywordsInStep(
    step: *ast.Step,
    registry: *const keyword_registry.KeywordRegistry,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    switch (step.*) {
        .invocation => |*inv| {
            try resolveKeywordInPath(&inv.path, registry, allocator, main_module);
        },
        .label_with_invocation => |*lwi| {
            try resolveKeywordInPath(&lwi.invocation.path, registry, allocator, main_module);
        },
        else => {},
    }
}

fn resolveKeywordsInContinuation(
    cont: *ast.Continuation,
    registry: *const keyword_registry.KeywordRegistry,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    // Resolve paths in step
    if (cont.node) |*step| {
        try resolveKeywordsInStep(@constCast(step), registry, allocator, main_module);
    }

    // Recursively process nested continuations
    for (cont.continuations) |*nested| {
        try resolveKeywordsInContinuation(@constCast(nested), registry, allocator, main_module);
    }
}

fn resolveKeywordInPath(
    path: *ast.DottedPath,
    registry: *const keyword_registry.KeywordRegistry,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    // Skip paths that already have explicit module qualifiers
    // ~lib_a:process() has module_qualifier="lib_a", so user explicitly chose which module
    if (path.module_qualifier != null) return;

    // Only resolve single-segment paths
    // After canonicalization, ~greet becomes module:greet (where module is the containing module)
    // We want to check if 'greet' is a keyword and replace the module with the keyword's module
    // This works for BOTH main module flows AND flows in imported modules
    if (path.segments.len != 1) return;

    _ = main_module; // Not used anymore - keywords resolve regardless of containing module

    const potential_keyword = path.segments[0];

    const resolve_result = registry.resolveKeyword(potential_keyword) catch |err| switch (err) {
        error.KeywordCollision => {
            const collision_info = registry.getCollisionInfo(potential_keyword).?;
            std.debug.print("ERROR: Ambiguous keyword '{s}' - defined in:\n", .{potential_keyword});
            for (collision_info) |info| {
                std.debug.print("  - {s} (from {s})\n", .{ info.canonical_path, info.module_path });
            }
            return error.AmbiguousKeyword;
        },
    };

    if (resolve_result) |canonical| {
        // Parse canonical path "module:event" to extract module_qualifier
        if (std.mem.indexOf(u8, canonical, ":")) |colon_pos| {
            path.module_qualifier = try allocator.dupe(u8, canonical[0..colon_pos]);
            std.debug.print("  Resolved keyword '{s}' -> module '{s}'\n", .{ potential_keyword, path.module_qualifier.? });
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Arena allocator for parse phase - all parsed data (AST, strings, etc.)
    // gets freed in one shot after compilation completes
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();

    // Arena allocator for compilation phase - purity checking, fusion detection,
    // code generation strings, etc. Freed after output file is written
    var compile_arena = std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();
    const compile_allocator = compile_arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printStderr(allocator, "{s}", .{usage});
        return;
    }

    // Check for zen command
    if (std.mem.eql(u8, args[1], "zen")) {
        try printStdout(allocator, "{s}", .{zen_text});

        // Easter egg: check for --buzzword flag
        if (args.len > 2 and std.mem.eql(u8, args[2], "--buzzword")) {
            try printStdout(allocator, "{s}", .{zen_buzzword});
        }
        return;
    }

    // Check for init command - initialize project in current directory
    if (std.mem.eql(u8, args[1], "init")) {
        // Check if koru.json already exists
        if (std.fs.cwd().access("koru.json", .{})) |_| {
            try printStderr(allocator, "Error: koru.json already exists in this directory\n", .{});
            try printStderr(allocator, "This directory is already a Koru project.\n", .{});
            return;
        } else |_| {}

        // Check if app.kz already exists
        if (std.fs.cwd().access("app.kz", .{})) |_| {
            try printStderr(allocator, "Error: app.kz already exists in this directory\n", .{});
            return;
        } else |_| {}

        // Get directory name for project name
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch {
            try printStderr(allocator, "Error: could not determine current directory\n", .{});
            return;
        };
        const project_name = std.fs.path.basename(cwd);

        // Create koru.json
        const koru_json_content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "0.1.0",
            \\  "entry": "app.kz",
            \\  "paths": {{
            \\    "node": "./node_modules",
            \\    "koru": "./node_modules/@korulang"
            \\  }}
            \\}}
            \\
        , .{project_name});
        defer allocator.free(koru_json_content);

        const json_file = std.fs.cwd().createFile("koru.json", .{}) catch |err| {
            try printStderr(allocator, "Error creating koru.json: {}\n", .{err});
            return;
        };
        defer json_file.close();
        json_file.writeAll(koru_json_content) catch |err| {
            try printStderr(allocator, "Error writing koru.json: {}\n", .{err});
            return;
        };

        // Create app.kz
        const app_kz_content =
            \\// A Koru application
            \\//
            \\// Run with: koruc app.kz && ./a.out
            \\
            \\~import "$std/package"
            \\
            \\// Declare npm dependencies (install with: koruc app.kz i)
            \\// ~std.package:requires.npm {
            \\//     "@koru/example": "^1.0.0"
            \\// }
            \\
            \\~event main {}
            \\
            \\~proc main {
            \\    const std = @import("std");
            \\    std.debug.print("Hello from Koru!\n", .{});
            \\}
            \\
            \\// Entry point
            \\~main()
            \\|> _
            \\
        ;

        const app_file = std.fs.cwd().createFile("app.kz", .{}) catch |err| {
            try printStderr(allocator, "Error creating app.kz: {}\n", .{err});
            return;
        };
        defer app_file.close();
        app_file.writeAll(app_kz_content) catch |err| {
            try printStderr(allocator, "Error writing app.kz: {}\n", .{err});
            return;
        };

        try printStdout(allocator, "Initialized Koru project '{s}'\n", .{project_name});
        try printStdout(allocator, "\n", .{});
        try printStdout(allocator, "Created:\n", .{});
        try printStdout(allocator, "  koru.json  - Project configuration\n", .{});
        try printStdout(allocator, "  app.kz     - Application entry point\n", .{});
        try printStdout(allocator, "\n", .{});
        try printStdout(allocator, "Next steps:\n", .{});
        try printStdout(allocator, "  koruc app.kz       # Compile and run\n", .{});
        try printStdout(allocator, "  koruc app.kz i     # Install npm dependencies\n", .{});
        return;
    }

    // Check for create command
    if (std.mem.eql(u8, args[1], "create")) {
        if (args.len < 4) {
            try printStderr(allocator, "Usage: koruc create [exe|lib] <name>\n", .{});
            return;
        }

        const project_type_str = args[2];
        const project_name = args[3];

        const project_type = if (std.mem.eql(u8, project_type_str, "exe"))
            project_template.ProjectType.exe
        else if (std.mem.eql(u8, project_type_str, "lib"))
            project_template.ProjectType.lib
        else {
            try printStderr(allocator, "Error: unknown project type '{s}'\n", .{project_type_str});
            try printStderr(allocator, "Use: koruc create [exe|lib] <name>\n", .{});
            return;
        };

        project_template.createProject(allocator, project_type, project_name, null) catch |err| {
            switch (err) {
                error.InvalidProjectName => {
                    try printStderr(allocator, "Error: invalid project name '{s}'\n", .{project_name});
                    try printStderr(allocator, "Project names must start with a letter and contain only alphanumeric characters, dashes, or underscores\n", .{});
                },
                error.PathAlreadyExists => {
                    try printStderr(allocator, "Error: directory '{s}' already exists\n", .{project_name});
                },
                else => {
                    try printStderr(allocator, "Error creating project: {}\n", .{err});
                },
            }
            return;
        };
        return;
    }

    // Check for build or run command
    var run_after_build = false;
    var build_executable = true;
    var arg_offset: usize = 1;

    if (std.mem.eql(u8, args[1], "build")) {
        build_executable = true;
        arg_offset = 2;
    } else if (std.mem.eql(u8, args[1], "run")) {
        build_executable = true;
        run_after_build = true;
        arg_offset = 2;
    }

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var exe_output_name: ?[]const u8 = null;
    var check_only = false;
    var use_visitor = false; // Visitor pattern needs more work before becoming default
    var ast_json_mode = false; // Output AST as JSON
    var registry_json_mode = false; // Output TypeRegistry as JSON
    var fail_fast = false; // Stop at first parse error (default: lenient mode)
    var install_packages = false; // Run package managers (npm install, cargo fetch, etc.)

    // Initialize compiler configuration
    var compiler_config = try CompilerConfig.init(allocator);
    defer compiler_config.deinit();

    var i: usize = arg_offset;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            // Print basic usage
            try printStdout(allocator, "{s}", .{usage});

            // Use arena allocator for parsing - all memory freed at once
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            // Try to discover backend flags from compiler.kz
            const compiler_kz_path = "koru_std/compiler.kz";
            const compiler_source = std.fs.cwd().readFileAlloc(
                arena_allocator,
                compiler_kz_path,
                10 * 1024 * 1024, // 10MB max
            ) catch |err| {
                // If we can't read compiler.kz, just show basic help
                if (err != error.FileNotFound) {
                    std.debug.print("Warning: Could not read {s}: {}\n", .{compiler_kz_path, err});
                }
                return;
            };

            // Quick-parse compiler.kz to extract flag declarations
            var help_parser = Parser.init(
                arena_allocator,
                compiler_source,
                "compiler.kz",
                &.{}, // No flags needed for parsing
                null, // No resolver needed for help text parsing
            ) catch {
                return; // Parsing failed, just show basic help
            };
            defer help_parser.deinit();

            const parse_result = help_parser.parse() catch {
                return; // Parse error, just show basic help
            };

            // Collect flag declarations (uses main allocator for returned flags)
            const flags = collectFlagDeclarations(allocator, &parse_result.source_file) catch {
                return; // Collection failed, just show basic help
            };
            defer {
                for (flags) |*flag| {
                    var mutable_flag = flag.*;
                    mutable_flag.deinit(allocator);
                }
                allocator.free(flags);
            }

            // Print discovered backend flags
            if (flags.len > 0) {
                try printStdout(allocator, "\nBackend Compiler Flags (discovered from compiler.kz):\n", .{});
                for (flags) |flag| {
                    try printStdout(allocator, "  --{s:<15} {s}\n", .{flag.name, flag.description});
                }
            }

            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try printStdout(allocator, "koruc {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--check")) {
            check_only = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--ast-json")) {
            ast_json_mode = true;
        } else if (std.mem.eql(u8, arg, "--registry-json")) {
            registry_json_mode = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--visitor")) {
            use_visitor = true;
            try printStdout(allocator, "Using visitor pattern backend (experimental)\n", .{});
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--install-packages")) {
            install_packages = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                try printStderr(allocator, "Error: -o requires an argument\n", .{});
                return;
            }
            // If output ends with .zig, it's the backend file
            // Otherwise it's the executable name
            if (std.mem.endsWith(u8, args[i], ".zig")) {
                output_file = args[i];
                build_executable = false; // Explicitly requesting .zig output, don't build
            } else {
                exe_output_name = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // First non-flag arg is input file
            // Second non-flag arg might be a shell command (checked later after parsing)
            // Any more would be arguments to the command
            if (input_file == null) {
                input_file = arg;
            }
            // Silently ignore other non-flag args - might be command name or command args
        } else {
            // Unknown flag - add to compiler config for backend use
            // Strip leading dashes and add to config
            const flag_name = if (std.mem.startsWith(u8, arg, "--"))
                arg[2..]
            else if (std.mem.startsWith(u8, arg, "-"))
                arg[1..]
            else
                arg;

            try compiler_config.addFlag(flag_name);
        }
    }

    if (input_file == null) {
        try printStderr(allocator, "Error: no input file specified\n\n{s}", .{usage});
        return;
    }

    const input = input_file.?;

    // Default output file: input.kz -> backend.zig (in same directory)
    // We use "backend.zig" because build.zig expects this name
    var allocated_output: ?[]u8 = null;
    defer if (allocated_output) |ao| allocator.free(ao);

    if (output_file == null and !check_only) {
        const input_dir = std.fs.path.dirname(input) orelse ".";
        allocated_output = try std.fs.path.join(allocator, &[_][]const u8{ input_dir, "backend.zig" });
        output_file = allocated_output;
    }

    // Read input file
    const file = try std.fs.cwd().openFile(input, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try parse_allocator.alloc(u8, file_size);
    // No defer needed - parse_arena will free everything

    _ = try file.read(source);

    // Find project root by searching upwards for koru.json (before parsing, so resolver is available)
    const input_dir = std.fs.path.dirname(input) orelse ".";

    // Convert input_dir to absolute path for {ENTRY} interpolation
    // This prevents path doubling when resolving $app/{ENTRY} relative to project_root
    const input_dir_absolute = try std.fs.cwd().realpathAlloc(allocator, input_dir);
    defer allocator.free(input_dir_absolute);

    // Create canonical entry file path for filtering in directory imports
    // When a file imports its own directory, we must exclude itself from submodules
    const entry_file_absolute = try std.fs.path.join(allocator, &[_][]const u8{
        input_dir_absolute,
        std.fs.path.basename(input),
    });
    defer allocator.free(entry_file_absolute);

    const project_root = blk: {
        var search_dir: []const u8 = input_dir_absolute;
        while (true) {
            // Check if koru.json exists in this directory
            const json_path = try std.fs.path.join(allocator, &[_][]const u8{ search_dir, "koru.json" });
            defer allocator.free(json_path);

            if (std.fs.cwd().access(json_path, .{})) |_| {
                // Found it!
                break :blk try allocator.dupe(u8, search_dir);
            } else |_| {}

            // Try parent directory
            const parent = std.fs.path.dirname(search_dir);
            if (parent == null or std.mem.eql(u8, parent.?, search_dir)) {
                // Reached filesystem root, use input directory
                break :blk try allocator.dupe(u8, input_dir_absolute);
            }
            search_dir = parent.?;
        }
    };
    defer allocator.free(project_root);

    // Load project configuration from koru.json
    var project_config = try Config.load(allocator, project_root) orelse try Config.default(allocator);
    defer project_config.deinit();

    // Create module resolver for import resolution
    // Pass project_root for resolving alias paths and entry_dir for {ENTRY} interpolation
    var resolver = try ModuleResolver.init(allocator, &project_config, project_root, input_dir_absolute);
    defer resolver.deinit();

    // Inject compiler bootstrap import (unless --compiler=disable or user already imported it)
    // Note: compiler.kz itself has ~[comptime] annotation, so it will be emitted to backend_output
    const inject_compiler = !compiler_config.hasFlag("compiler=disable");
    const user_already_imported_compiler = std.mem.indexOf(u8, source, "$std/compiler") != null;
    const final_source = if (inject_compiler and !user_already_imported_compiler) blk: {
        std.debug.print("DEBUG: Auto-injecting compiler import\n", .{});
        const import_line = "~import \"$std/compiler\"\n";
        const injected = try parse_allocator.alloc(u8, import_line.len + source.len);
        @memcpy(injected[0..import_line.len], import_line);
        @memcpy(injected[import_line.len..], source);
        break :blk injected;
    } else blk: {
        if (user_already_imported_compiler) {
            std.debug.print("DEBUG: User already imported compiler, skipping auto-injection\n", .{});
        }
        break :blk source;
    };

    // Parse the file
    std.debug.print("DEBUG: About to parse file: {s}, ast_json_mode = {}\n", .{ input, ast_json_mode });
    std.debug.print("DEBUG: Compiler bootstrap injection: {}\n", .{inject_compiler});
    var parser = try Parser.init(parse_allocator, final_source, input, compiler_config.flags.items, &resolver);
    parser.fail_fast = fail_fast;
    defer parser.deinit();

    std.debug.print("DEBUG: Parser initialized, calling parse()...\n", .{});
    const parse_result = parser.parse() catch |err| {
        if (parser.reporter.hasErrors()) {
            const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
            try parser.reporter.printErrors(stderr_writer);
            std.process.exit(1);
        }
        return err;
    };
    std.debug.print("DEBUG: Parse succeeded, ast_json_mode = {}\n", .{ast_json_mode});
    // DON'T defer deinit - we're going to take ownership of the items

    var source_file = parse_result.source_file;
    var user_registry = parse_result.registry;
    defer user_registry.deinit();

    // If --ast-json mode, output AST as JSON (even if there are parse errors)
    // This is crucial for IDE tooling - parse_error nodes in AST show where errors occurred
    if (ast_json_mode) {
        std.debug.print("DEBUG: ast_json_mode is true, serializing AST...\n", .{});
        const ast_serializer = @import("ast_serializer");
        var serializer = try ast_serializer.AstSerializer.init(compile_allocator);
        defer serializer.deinit();

        const json_output = try serializer.serializeToJson(&source_file);
        std.debug.print("DEBUG: JSON output length = {d}\n", .{json_output.len});
        // No need to free - compile_arena handles it

        try printStdout(allocator, "{s}", .{json_output});

        // Still report errors and exit with failure code if there were errors
        if (parser.reporter.hasErrors()) {
            const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
            try parser.reporter.printErrors(stderr_writer);
            std.process.exit(1);
        }
        return;
    }

    // If --registry-json mode, output TypeRegistry as JSON
    if (registry_json_mode) {
        try printStdout(allocator, "{{\n", .{});
        try printStdout(allocator, "  \"events\": {{\n", .{});

        var event_iter = user_registry.events.iterator();
        var first_event = true;
        while (event_iter.next()) |entry| {
            if (!first_event) {
                try printStdout(allocator, ",\n", .{});
            }
            first_event = false;

            const event_path = entry.key_ptr.*;
            const event_type = entry.value_ptr.*;

            try printStdout(allocator, "    \"{s}\": {{\n", .{event_path});
            try printStdout(allocator, "      \"is_public\": {},\n", .{event_type.is_public});
            try printStdout(allocator, "      \"is_implicit_flow\": {},\n", .{event_type.is_implicit_flow});

            // Show input fields
            try printStdout(allocator, "      \"input_fields\": [\n", .{});
            if (event_type.input_shape) |shape| {
                for (shape.fields, 0..) |field, field_idx| {
                    if (field_idx > 0) try printStdout(allocator, ",\n", .{});
                    try printStdout(allocator, "        {{\"name\": \"{s}\", \"type\": \"{s}\", \"is_source\": {}}}", .{field.name, field.type, field.is_source});
                }
            }
            try printStdout(allocator, "\n      ],\n", .{});

            // Show branches
            try printStdout(allocator, "      \"branches\": [\n", .{});
            for (event_type.branches, 0..) |branch, branch_idx| {
                if (branch_idx > 0) try printStdout(allocator, ",\n", .{});
                try printStdout(allocator, "        \"{s}\"", .{branch.name});
            }
            try printStdout(allocator, "\n      ]\n", .{});
            try printStdout(allocator, "    }}", .{});
        }

        try printStdout(allocator, "\n  }}\n", .{});
        try printStdout(allocator, "}}\n", .{});

        return;
    }

    // For non-JSON mode, fail immediately if there are parse errors
    if (parser.reporter.hasErrors()) {
        const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
        try parser.reporter.printErrors(stderr_writer);
        std.process.exit(1);
    }

    // Check for frontend commands (shell and Zig) for instant execution
    const shell_commands = try collectShellCommands(parse_allocator, &source_file);
    defer {
        for (shell_commands) |*cmd| {
            cmd.deinit(parse_allocator);
        }
        parse_allocator.free(shell_commands);
    }

    const zig_commands = try collectZigCommands(parse_allocator, &source_file);
    defer {
        for (zig_commands) |*cmd| {
            cmd.deinit(parse_allocator);
        }
        parse_allocator.free(zig_commands);
    }

    // Track if we're running a comptime command (passed to backend)
    // NOTE: comptime_cmd_result is collected AFTER imports are processed
    var detected_comptime_command: ?[]const u8 = null;
    var potential_command_arg: ?[]const u8 = null;

    // Check if there's a potential command name in args
    // Args pattern: koruc input.kz <command> <...args for command>
    // Find input file position, then check next arg
    for (args, 0..) |arg, arg_idx| {
        if (std.mem.eql(u8, arg, input)) {
            // Check if there's a next arg that might be a command
            if (arg_idx + 1 < args.len) {
                const potential_command = args[arg_idx + 1];

                // Search for matching shell command
                for (shell_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.name, potential_command)) {
                        // Found matching command! Execute it with remaining args
                        // Build argv: script + remaining args
                        var exec_argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len);
                        defer exec_argv.deinit(allocator);

                        try exec_argv.append(allocator, "sh");
                        try exec_argv.append(allocator, "-c");
                        try exec_argv.append(allocator, cmd.script);

                        // Pass additional args as positional parameters to the shell
                        // sh -c 'script' sh arg1 arg2 arg3...
                        if (arg_idx + 2 < args.len) {
                            try exec_argv.append(allocator, "sh");  // $0 for the script
                            for (args[arg_idx + 2..]) |extra_arg| {
                                try exec_argv.append(allocator, extra_arg);
                            }
                        }

                        // Execute command
                        const result = try std.process.Child.run(.{
                            .allocator = allocator,
                            .argv = exec_argv.items,
                        });
                        defer {
                            allocator.free(result.stdout);
                            allocator.free(result.stderr);
                        }

                        // Print output
                        try printStdout(allocator, "{s}", .{result.stdout});
                        if (result.stderr.len > 0) {
                            try printStderr(allocator, "{s}", .{result.stderr});
                        }

                        // Exit with command's exit code
                        switch (result.term) {
                            .Exited => |code| std.process.exit(code),
                            else => std.process.exit(1),
                        }
                    }
                }

                // If no shell command matched, check for Zig commands
                for (zig_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.name, potential_command)) {
                        // Found matching Zig command! Compile and execute it
                        std.debug.print("🔨 Executing Zig command: {s}\n", .{cmd.name});

                        // TODO: For MVP, we'll implement a simple approach:
                        // 1. Generate temp .zig file with command source
                        // 2. Serialize AST to temp file
                        // 3. Use zig run to compile and execute
                        // 4. Pass AST path + argv via command line

                        // For now, just print that we found it
                        std.debug.print("⚠️  Zig command execution not yet implemented\n", .{});
                        std.debug.print("Command '{s}' found but needs compilation support\n", .{cmd.name});
                        std.process.exit(1);
                    }
                }

                // Store potential command for later checking (after imports are processed)
                // Comptime commands are defined in imported modules, so we check after imports
                potential_command_arg = potential_command;
            }
            break;
        }
    }

    // Process imports - extract public events from imported modules
    var imported_modules = std.ArrayListAligned(ImportedModule, null){
        .items = &.{},
        .capacity = 0,
    };
    defer {
        // Clean up each imported module before freeing the list
        for (imported_modules.items) |*module| {
            module.deinit(allocator);
        }
        imported_modules.deinit(allocator);
    }

    // Track imported modules to prevent duplicates
    var imported_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it = imported_paths.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        imported_paths.deinit();
    }

    // Work queue for recursive import processing
    // Each entry is: (import_decl, base_file_path, is_synthetic)
    // Synthetic imports (from auto-parent) have allocated strings that need freeing
    const WorkItem = struct {
        import_decl: ast.ImportDecl,
        base_file: []const u8,
        is_synthetic: bool = false,
    };
    var work_queue = std.ArrayListAligned(WorkItem, null){
        .items = &.{},
        .capacity = 0,
    };
    defer work_queue.deinit(allocator);

    // Seed the work queue with imports from the main source file
    for (source_file.items) |item| {
        if (item == .import_decl) {
            try work_queue.append(allocator, .{
                .import_decl = item.import_decl,
                .base_file = input,
                .is_synthetic = false,
            });
        }
    }

    // Process work queue until empty (recursive transitive import processing)
    while (work_queue.items.len > 0) {
        const work_item = work_queue.orderedRemove(0);
        defer {
            // Free synthetic import strings (allocated by queueParentImports)
            if (work_item.is_synthetic) {
                allocator.free(work_item.import_decl.path);
                if (work_item.import_decl.local_name) |name| {
                    allocator.free(name);
                }
            }
        }

        const module = try processImport(allocator, parse_allocator, &resolver, work_item.import_decl, work_item.base_file, entry_file_absolute);

        // Check if we've already imported this canonical path
        if (imported_paths.contains(module.canonical_path)) {
            std.debug.print("DEDUPLICATION: Skipping duplicate import of '{s}' (canonical: {s})\n", .{ module.logical_name, module.canonical_path });
            // Clean up the duplicate module
            var mut_module = module;
            mut_module.deinit(allocator);
            continue;
        }

        // Track this import
        const path_copy = try allocator.dupe(u8, module.canonical_path);
        try imported_paths.put(path_copy, {});
        std.debug.print("IMPORT: Added '{s}' (canonical: {s})\n", .{ module.logical_name, module.canonical_path });

        // Queue parent imports for aliased paths (e.g., $std/io/file -> also import $std/io.kz)
        // Only if the parent file actually exists
        try queueParentImports(allocator, &work_queue, &resolver, work_item.import_decl, work_item.base_file);

        // Queue index.kz import for aliased paths (e.g., $std/io -> also import $std/index.kz)
        // This makes root-level stdlib utilities available when importing any submodule
        try queueIndexImport(allocator, &work_queue, &resolver, work_item.import_decl, work_item.base_file);

        // Scan this module's AST for transitive imports
        for (module.source_file.items) |item| {
            if (item == .import_decl) {
                std.debug.print("TRANSITIVE: Found import in '{s}' -> '{s}'\n", .{ module.logical_name, item.import_decl.path });
                try work_queue.append(allocator, .{
                    .import_decl = item.import_decl,
                    .base_file = module.canonical_path,
                    .is_synthetic = false,
                });
            }
        }

        // Also scan submodules for transitive imports (for directory imports)
        // This ensures imports in index.kz (or other submodule files) are resolved
        for (module.submodules) |*submod| {
            for (submod.source_file.items) |item| {
                if (item == .import_decl) {
                    std.debug.print("TRANSITIVE: Found import in submodule '{s}.{s}' -> '{s}'\n", .{ module.logical_name, submod.logical_name, item.import_decl.path });
                    try work_queue.append(allocator, .{
                        .import_decl = item.import_decl,
                        .base_file = submod.canonical_path,
                        .is_synthetic = false,
                    });
                }
            }
        }

        try imported_modules.append(allocator, module);
    }

    // compiler is now auto-injected as an import (unless --compiler=disable)
    // It will be processed like any other imported module

    // Merge imported modules with the user's AST
    var combined_items = try std.ArrayList(ast.Item).initCapacity(parse_allocator, source_file.items.len);
    defer combined_items.deinit(parse_allocator);

    // Helper to recursively add module and its submodules
    const addModuleToAST = struct {
        fn add(
            alloc: std.mem.Allocator,
            items: *std.ArrayList(ast.Item),
            module: *ImportedModule,
            res: *ModuleResolver,
        ) !void {
            // If the module has a source file (not just an empty directory), add it first
            const has_source = module.source_file.items.len > 0 or module.source_file.module_annotations.len > 0;
            if (has_source) {
                const is_system = res.isSystemModule(module.canonical_path);
                const annotations = try alloc.alloc([]const u8, module.source_file.module_annotations.len);
                for (module.source_file.module_annotations, 0..) |ann, ann_idx| {
                    annotations[ann_idx] = try alloc.dupe(u8, ann);
                }

                const module_decl = ast.ModuleDecl{
                    .logical_name = try alloc.dupe(u8, module.logical_name),
                    .canonical_path = try alloc.dupe(u8, module.canonical_path),
                    .items = module.source_file.items,
                    .is_system = is_system,
                    .annotations = annotations,
                    .location = .{ .file = module.canonical_path, .line = 1, .column = 0 },
                };
                module.source_file.items = &.{};
                try items.append(alloc, .{ .module_decl = module_decl });
            }

            // If the module has submodules (directory), add them
            if (module.is_directory and module.submodules.len > 0) {
                // Directory import - add each submodule
                for (module.submodules) |*submod| {
                    const is_system = res.isSystemModule(submod.canonical_path);

                    // Create ModuleDecl with dotted name: dir.file
                    // SPECIAL CASE: index.kz gets the parent namespace (no .index suffix)
                    // This makes modules self-contained: vaxis/index.kz -> namespace "vaxis"
                    const dotted_name = if (std.mem.eql(u8, submod.logical_name, "index"))
                        try alloc.dupe(u8, module.logical_name)
                    else
                        try std.fmt.allocPrint(alloc, "{s}.{s}", .{ module.logical_name, submod.logical_name });

                    // Copy module annotations from source file
                    const annotations = try alloc.alloc([]const u8, submod.source_file.module_annotations.len);
                    for (submod.source_file.module_annotations, 0..) |ann, ann_idx| {
                        annotations[ann_idx] = try alloc.dupe(u8, ann);
                    }

                    const module_decl = ast.ModuleDecl{
                        .logical_name = dotted_name,
                        .canonical_path = try alloc.dupe(u8, submod.canonical_path),
                        .items = submod.source_file.items, // Transfer ownership
                        .is_system = is_system,
                        .annotations = annotations,
                        .location = .{ .file = submod.canonical_path, .line = 1, .column = 0 },
                    };
                    // Mark items as transferred
                    submod.source_file.items = &.{};
                    try items.append(alloc, .{ .module_decl = module_decl });
                }
            }
        }
    }.add;

    // Add imported modules as ModuleDecl items
    for (imported_modules.items) |*module| {
        try addModuleToAST(parse_allocator, &combined_items, module, &resolver);
    }

    // Add all user items to combined items
    // Items now have their own .module field, so no ModuleDecl wrapping needed
    for (source_file.items) |item| {
        switch (item) {
            .import_decl => continue, // Skip - already processed
            else => {
                // All items (events, procs, flows, zig_lines) go at top-level
                // They carry their own module metadata for phantom checking
                try combined_items.append(parse_allocator, item);
            },
        }
    }

    // Don't free - parse_arena will handle it

    // Replace source_file with the combined AST
    source_file.items = try combined_items.toOwnedSlice(parse_allocator);
    // Don't need explicit defer - parse_arena.deinit() will free everything
    // No manual cleanup needed for AST nodes - parse_arena.deinit() will free them all

    std.debug.print("AST combined with {} imported modules\n", .{imported_modules.items.len});

    // Now check for comptime commands (after imports are processed)
    if (potential_command_arg) |potential_command| {
        const comptime_cmd_result = try collectCommands(parse_allocator, &source_file);

        // Resolve command aliases (e.g., "i" -> "install")
        // TODO: Parse these from command.declare dynamically
        const resolved_command = if (std.mem.eql(u8, potential_command, "i"))
            "install"
        else
            potential_command;

        for (comptime_cmd_result.commands[0..comptime_cmd_result.count]) |cmd| {
            if (std.mem.eql(u8, cmd.name, resolved_command)) {
                // Found matching comptime command - continue to backend compilation
                // The command will be passed to the backend and executed there
                detected_comptime_command = resolved_command;
                break;
            }
        }
    }

    // Canonicalize all DottedPaths - set module_qualifier on everything
    // This enables reliable name resolution for all downstream passes
    const canonicalize_names = @import("canonicalize_names");
    try canonicalize_names.canonicalize(&source_file, parse_allocator);

    // Build keyword registry and resolve [keyword] events
    // This enables unqualified invocation of events marked with [keyword]
    // Must happen AFTER canonicalization so we have canonical paths
    std.debug.print("Building keyword registry...\n", .{});
    var kw_registry = keyword_registry.KeywordRegistry.init(parse_allocator);
    defer kw_registry.deinit();
    try buildKeywordRegistry(source_file.items, &kw_registry, parse_allocator);
    if (kw_registry.count() > 0) {
        std.debug.print("Registered {} keywords, resolving in AST...\n", .{kw_registry.count()});
        try resolveKeywordsInAST(@constCast(source_file.items), &kw_registry, parse_allocator, source_file.main_module_name);
    }

    // Inject meta-events (koru:start, koru:end) into AST
    // These are synthetic events that mark program lifecycle boundaries
    // Taps can observe them (e.g., profiler writes header/footer)
    // Must happen AFTER canonicalization so paths have module_qualifier
    // Must happen BEFORE tap transformation so taps can observe these flows
    const meta_events = @import("meta_events");
    try meta_events.injectMetaEvents(parse_allocator, &source_file);
    std.debug.print("Injected meta-events: koru:start, koru:end\n", .{});

    // NOTE: Declaration-level transforms run in the BACKEND alongside invocation transforms.
    // They update the type registry when they run, not here in the frontend.

    // Build TypeRegistry from canonicalized AST
    // This must happen AFTER canonicalization so event names include module qualifiers
    std.debug.print("Building TypeRegistry from canonicalized AST...\n", .{});
    try user_registry.populateFromAST(source_file.items);
    std.debug.print("TypeRegistry populated with {} events\n", .{user_registry.events.count()});

    // Validate abstract events and implementations
    // This must happen AFTER canonicalization so we can match canonical paths
    std.debug.print("Validating abstract events and implementations...\n", .{});
    try validate_abstract_impl.AbstractImplValidator.validate(parse_allocator, source_file.items);
    std.debug.print("Abstract/impl validation passed\n", .{});

    // Collect Event Taps
    var tap_collector = try TapCollector.init(compile_allocator);
    defer tap_collector.deinit();
    try tap_collector.collectFromSourceFile(&source_file);

    const tap_count = tap_collector.output_taps.count() +
        tap_collector.input_taps.count() +
        tap_collector.universal_output_taps.items.len +
        tap_collector.universal_input_taps.items.len;
    if (tap_count > 0) {
        std.debug.print("Collected {} Event Taps\n", .{tap_count});
    }

    // NOTE: Tap transformation is done in the BACKEND by compiler.coordinate.transform_taps
    // The backend inserts taps into the AST after filtering comptime code.

    // TODO: Process imports properly - for now imports are disabled
    // The old import system violated module isolation by copying all code
    // try processImports(allocator, &source_file, input);

    // Check for compiler override BEFORE shape checking so we can inject defaults
    var bootstrap = try CompilerBootstrap.checkForOverride(allocator, &source_file);

    // Inject default implementations if needed
    try bootstrap.injectDefaults(&source_file);

    // Log if user has overridden the compiler
    if (bootstrap.has_user_override) {
        try printStdout(allocator, "🚀 User-defined compiler.coordinate detected!\n", .{});
    }

    // Purity checking pass
    var purity_check = PurityChecker.init(compile_allocator);
    defer purity_check.deinit();
    try purity_check.check(&source_file);

    // Flow checking pass - FRONTEND ONLY (syntactic checks: KORU100, KORU050, KORU051)
    // Branch coverage checks (KORU021, KORU022) run in backend after transforms are applied
    var flow_check = try FlowChecker.initWithMode(compile_allocator, &parser.reporter, .frontend);
    defer flow_check.deinit();
    flow_check.checkSourceFile(&source_file) catch |err| {
        if (err == error.FlowValidationFailed) {
            const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
            try parser.reporter.printErrors(stderr_writer);
            std.process.exit(1);
        }
        return err;
    };

    // Fusion detection pass (experimental!)
    var fusion_detect = FusionDetector.init(compile_allocator);
    defer fusion_detect.deinit();
    var fusion_report = try fusion_detect.detect(&source_file);
    defer fusion_report.deinit();

    if (fusion_report.total_chains > 0) {
        std.debug.print("\n🔥 FUSION OPPORTUNITIES DETECTED:\n", .{});
        std.debug.print("   Found {} fusable chain(s) with {} total events\n", .{
            fusion_report.total_chains,
            fusion_report.total_events_in_chains,
        });

        for (fusion_report.opportunities.items) |opp| {
            std.debug.print("   📍 In {s}: ", .{opp.location});
            for (opp.chain, 0..) |event, idx| {
                if (idx > 0) std.debug.print(" -> ", .{});
                std.debug.print("{s}", .{event});
            }
            std.debug.print(" ({} events)\n", .{opp.chain.len});
        }
        std.debug.print("\n", .{});
    }

    // If check-only, we're done
    if (check_only) {
        try printStdout(allocator, "✓ Shape checking passed\n", .{});
        return;
    }

    // Apply AST transformations - but ONLY if user hasn't overridden compiler.coordinate
    const transform_functional = @import("transform_functional");
    const inline_functional = @import("transforms/inline_small_events_functional");
    const AstModule = @import("ast");

    var transformed_ast: ?AstModule.Program = null;
    var final_ast: *AstModule.Program = undefined;

    // Create functional context outside the if block so it lives long enough
    var functional_ctx: ?transform_functional.FunctionalContext = null;
    // Note: We'll manually deinit functional_ctx after AST cleanup to avoid double-free

    if (bootstrap.has_user_override) {
        // User has overridden compiler.coordinate - give them the ORIGINAL AST
        // They have complete control over transformations
        final_ast = &source_file;
    } else {
        // No user override - apply default transformations
        // Create a functional transformation context
        functional_ctx = try transform_functional.FunctionalContext.init(compile_allocator, &source_file);

        // TEMPORARILY DISABLED: Inlining generates invalid code for flows
        const enable_inlining = false;

        if (enable_inlining) {
            // Check how many events would be inlined
            const inline_count = try inline_functional.countInlineCandidates(
                allocator,
                &source_file,
                .{ .size_threshold = 5 },
            );

            // Apply the inline transformation if there are candidates
            if (inline_count > 0) {
                const inline_transform = inline_functional.createInlineTransformation(.{ .size_threshold = 5 });
                transformed_ast = try functional_ctx.?.apply("inline_small_events", inline_transform);
                try printStdout(allocator, "✨ Inlined {d} small event(s) using functional transformations!\n", .{inline_count});
            }
        }

        // NOTE: Loop optimization now runs in the BACKEND during compiler.coordinate.optimize
        // See koru_std/compiler.kz for the optimization pass

        // Use either the transformed AST or the original
        final_ast = if (transformed_ast) |*t| t else &source_file;
    }

    // Run the compiler coordinator to orchestrate additional passes
    const coordination_result = try compiler_coordination.coordinate(
        compile_allocator,
        final_ast,
        bootstrap.has_user_override,
        input,
    );
    // No defer needed - compile_arena will free metrics

    // Use the coordinated AST
    final_ast = @constCast(coordination_result.ast);

    try printStdout(allocator, "🎯 Compiler coordination: {s}\n", .{coordination_result.metrics});

    // Write output file
    const output = output_file.?;
    try printStdout(allocator, "DEBUG: Writing output to {s}\n", .{output});

    // Pass 2: Generate the backend (code generator + compiler)
    const ast_serializer = @import("ast_serializer");

    // Serialize the AST for the backend
    var serializer = try ast_serializer.AstSerializer.init(compile_allocator);
    defer serializer.deinit();

    const serialized_ast = try serializer.serialize(final_ast);
    // No need to free - compile_arena handles it

    // Generate backend_output_emitted.zig for comptime handlers FIRST
    // We need transform_count from this to pass to backend.zig generation
    // CRITICAL: Use source_file (original AST) not final_ast (transformed AST)
    // The comptime evaluation pass filters out ~[comptime] modules from final_ast,
    // but we NEED those modules in backend_output_emitted.zig for backend compilation!
    std.debug.print("DEBUG: Generating comptime backend with {} items in source_file\n", .{source_file.items.len});
    for (source_file.items) |item| {
        if (item == .module_decl) {
            const module = item.module_decl;
            std.debug.print("DEBUG:   Module: {s} (has_comptime: {any})\n", .{module.logical_name, module.annotations});
        }
    }
    const comptime_result = try generateComptimeBackendEmitted(compile_allocator, &source_file, &user_registry);
    const comptime_backend_code = comptime_result.code;
    const has_transforms = comptime_result.transform_count > 0;
    // No defer needed - compile_arena handles cleanup automatically

    // Generate the backend code (includes metacircular compiler)
    const backend_code = try generateBackendCode(compile_allocator, serialized_ast, input, final_ast, use_visitor, &compiler_config, &bootstrap, has_transforms);
    // No defer needed - compile_arena handles cleanup automatically

    // NOTE: AST cleanup is handled by defer at line 1375-1380
    // This ensures cleanup happens even on early exits (errors, check-only mode, etc.)

    // If we used functional transformations, clean up transformation metadata
    if (functional_ctx) |*ctx| {
        // functional_ctx.deinit() will clean up transformed_ast items
        // (stored in transformation_history) and all metadata
        ctx.deinit();
    }

    // Write the backend to the output file
    const out_file = try std.fs.cwd().createFile(output, .{});
    defer out_file.close();

    try out_file.writeAll(backend_code);

    // Write backend_output_emitted.zig for comptime handlers to same directory as backend.zig
    const output_dir = std.fs.path.dirname(output) orelse ".";
    const backend_output_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "backend_output_emitted.zig" });
    defer allocator.free(backend_output_path);
    const backend_output_file = try std.fs.cwd().createFile(backend_output_path, .{});
    defer backend_output_file.close();
    try backend_output_file.writeAll(comptime_backend_code);

    try printStdout(allocator, "✓ Compiled {s} → {s}\n", .{ input, output });
    try printStdout(allocator, "✓ Generated {s} ({d} bytes)\n", .{ backend_output_path, comptime_backend_code.len });

    // Collect requirements from AST
    // - compiler:requires → for BACKEND compilation (backend.zig)
    // - build:requires → for OUTPUT binary (output_emitted.zig)
    var requires_collector = try CompilerRequiresCollector.init(allocator);
    defer requires_collector.deinit();
    try requires_collector.collectFromSourceFile(&source_file);

    const compiler_requirements_raw = requires_collector.getCompilerRequirements();
    const build_requirements_raw = requires_collector.getBuildRequirements();

    // Use absolute path to koru library (symlinked at /usr/local/lib/koru)
    const koru_lib_path = "/usr/local/lib/koru";

    // Generate build.zig for BACKEND (compiler:requires)
    if (compiler_requirements_raw.len > 0) {
        try printStdout(allocator, "✓ Found {d} compiler requirement(s) for backend\n", .{compiler_requirements_raw.len});

        var backend_build_reqs = try std.ArrayList(emit_build_zig.BuildRequirement).initCapacity(allocator, compiler_requirements_raw.len);
        defer backend_build_reqs.deinit(allocator);

        for (compiler_requirements_raw) |req| {
            try backend_build_reqs.append(allocator, .{
                .module_name = "compiler",
                .source_code = req,
            });
        }

        const build_backend_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build_backend.zig" });
        defer allocator.free(build_backend_path);
        try emit_build_zig.emitBuildZig(allocator, backend_build_reqs.items, build_backend_path, koru_lib_path);
        try printStdout(allocator, "✓ Generated {s}\n", .{build_backend_path});

        // Also as build.zig for zig build convenience
        const build_user_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build.zig" });
        defer allocator.free(build_user_path);
        try emit_build_zig.emitBuildZig(allocator, backend_build_reqs.items, build_user_path, koru_lib_path);
        try printStdout(allocator, "✓ Generated {s} (for backend compilation)\n", .{build_user_path});
    }

    // Generate build_output.zig for OUTPUT binary (build:requires)
    if (build_requirements_raw.len > 0) {
        try printStdout(allocator, "✓ Found {d} build requirement(s) for output binary\n", .{build_requirements_raw.len});

        var output_build_reqs = try std.ArrayList(emit_build_zig.BuildRequirement).initCapacity(allocator, build_requirements_raw.len);
        defer output_build_reqs.deinit(allocator);

        for (build_requirements_raw) |req| {
            try output_build_reqs.append(allocator, .{
                .module_name = "user",
                .source_code = req,
            });
        }

        // Generate build_output.zig - this will be used to compile output_emitted.zig
        const build_output_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build_output.zig" });
        defer allocator.free(build_output_path);
        try emit_build_zig.emitOutputBuildZig(allocator, output_build_reqs.items, build_output_path);
        try printStdout(allocator, "✓ Generated {s} (for output binary)\n", .{build_output_path});
    }

    // Collect package requirements from AST (use source_file with imports merged!)
    var package_collector = try PackageRequirementsCollector.init(allocator);
    defer package_collector.deinit();
    try package_collector.collectFromSourceFile(&source_file);

    if (package_collector.hasAnyRequirements()) {
        const npm_reqs = package_collector.getNpmRequirements();
        const cargo_reqs = package_collector.getCargoRequirements();
        const go_reqs = package_collector.getGoRequirements();
        const pip_reqs = package_collector.getPipRequirements();

        try printStdout(allocator, "✓ Found package requirements:\n", .{});
        if (npm_reqs.len > 0) try printStdout(allocator, "  - npm: {d} package(s)\n", .{npm_reqs.len});
        if (cargo_reqs.len > 0) try printStdout(allocator, "  - cargo: {d} package(s)\n", .{cargo_reqs.len});
        if (go_reqs.len > 0) try printStdout(allocator, "  - go: {d} package(s)\n", .{go_reqs.len});
        if (pip_reqs.len > 0) try printStdout(allocator, "  - pip: {d} package(s)\n", .{pip_reqs.len});

        // Generate package files in output directory
        if (npm_reqs.len > 0) {
            const package_json_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "package.json" });
            defer allocator.free(package_json_path);
            try emit_package_files.emitPackageJson(allocator, npm_reqs, package_json_path);
            try printStdout(allocator, "✓ Generated {s}\n", .{package_json_path});
        }

        if (cargo_reqs.len > 0) {
            const cargo_toml_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "Cargo.toml" });
            defer allocator.free(cargo_toml_path);
            try emit_package_files.emitCargoToml(allocator, cargo_reqs, cargo_toml_path);
            try printStdout(allocator, "✓ Generated {s}\n", .{cargo_toml_path});
        }

        if (go_reqs.len > 0) {
            const go_mod_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "go.mod" });
            defer allocator.free(go_mod_path);
            try emit_package_files.emitGoMod(allocator, go_reqs, go_mod_path);
            try printStdout(allocator, "✓ Generated {s}\n", .{go_mod_path});
        }

        if (pip_reqs.len > 0) {
            const requirements_txt_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "requirements.txt" });
            defer allocator.free(requirements_txt_path);
            try emit_package_files.emitRequirementsTxt(allocator, pip_reqs, requirements_txt_path);
            try printStdout(allocator, "✓ Generated {s}\n", .{requirements_txt_path});
        }

        // Optionally run package managers if --install-packages flag is set
        if (install_packages) {
            try printStdout(allocator, "Installing packages...\n", .{});

            if (npm_reqs.len > 0) {
                try printStdout(allocator, "  Running npm install...\n", .{});
                const npm_result = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "npm", "install", "--prefix", output_dir },
                });
                defer allocator.free(npm_result.stdout);
                defer allocator.free(npm_result.stderr);

                if (npm_result.term.Exited != 0) {
                    try printStderr(allocator, "✗ npm install failed:\n{s}\n", .{npm_result.stderr});
                } else {
                    try printStdout(allocator, "  ✓ npm packages installed\n", .{});
                }
            }

            if (cargo_reqs.len > 0) {
                try printStdout(allocator, "  Running cargo fetch...\n", .{});
                const cargo_result = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "cargo", "fetch", "--manifest-path", try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "Cargo.toml" }) },
                });
                defer allocator.free(cargo_result.stdout);
                defer allocator.free(cargo_result.stderr);

                if (cargo_result.term.Exited != 0) {
                    try printStderr(allocator, "✗ cargo fetch failed:\n{s}\n", .{cargo_result.stderr});
                } else {
                    try printStdout(allocator, "  ✓ cargo packages fetched\n", .{});
                }
            }

            if (go_reqs.len > 0) {
                try printStdout(allocator, "  Running go mod download...\n", .{});
                const go_result = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "go", "mod", "download" },
                    .cwd = output_dir,
                });
                defer allocator.free(go_result.stdout);
                defer allocator.free(go_result.stderr);

                if (go_result.term.Exited != 0) {
                    try printStderr(allocator, "✗ go mod download failed:\n{s}\n", .{go_result.stderr});
                } else {
                    try printStdout(allocator, "  ✓ go modules downloaded\n", .{});
                }
            }

            if (pip_reqs.len > 0) {
                try printStdout(allocator, "  Running pip install...\n", .{});
                const pip_result = try std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "pip", "install", "-r", try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "requirements.txt" }) },
                });
                defer allocator.free(pip_result.stdout);
                defer allocator.free(pip_result.stderr);

                if (pip_result.term.Exited != 0) {
                    try printStderr(allocator, "✗ pip install failed:\n{s}\n", .{pip_result.stderr});
                } else {
                    try printStdout(allocator, "  ✓ pip packages installed\n", .{});
                }
            }
        }
    }

    // Collect and execute build steps (if any)
    // Build steps can replace or augment the standard compilation pipeline
    // Phase 1: Collect all candidates (with module + default info)
    const collection = try collectBuildStepCandidates(parse_allocator, &source_file);
    defer {
        for (collection.candidates) |*candidate| {
            candidate.deinit(parse_allocator);
        }
        parse_allocator.free(collection.candidates);
    }

    // Phase 2: Resolve overrides using ~[default] precedence rules
    const build_steps = try resolveBuildSteps(parse_allocator, collection.candidates);
    defer {
        for (build_steps) |*step| {
            step.deinit(parse_allocator);
        }
        parse_allocator.free(build_steps);
    }

    // If there are user-defined build steps, execute them (including any defaults they depend on)
    // Default-only steps don't auto-execute - they're just available for override
    if (build_steps.len > 0 and collection.has_user_defined) {
        try executeBuildSteps(allocator, build_steps);
        // Build steps handled everything, we're done!
        return;
    }

    // If build_executable is true, compile backend and run full pipeline
    if (build_executable) {
        // Determine output executable name
        const exe_name = if (exe_output_name) |name|
            name
        else
            "a.out";

        // Compile the backend using build_backend.zig (which has all module dependencies)
        try printStdout(allocator, "Building executable...\n", .{});

        // Use the generated build_backend.zig instead of direct zig build-exe
        // This ensures all module dependencies are properly linked
        const output_dir_for_build = std.fs.path.dirname(output) orelse ".";

        // When running with cwd set to output_dir, build-file should be relative to that dir
        const zig_build_args = [_][]const u8{
            "zig",
            "build",
            "--build-file",
            "build_backend.zig", // Relative to cwd (output_dir_for_build)
        };

        // Run zig build in the output directory so zig-out/ is created there
        const compile_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &zig_build_args,
            .cwd = output_dir_for_build,
        });
        defer allocator.free(compile_result.stdout);
        defer allocator.free(compile_result.stderr);

        if (compile_result.term.Exited != 0) {
            try printStderr(allocator, "✗ Failed to compile backend:\n{s}\n", .{compile_result.stderr});
            std.process.exit(1);
        }

        // Backend is now at zig-out/bin/backend (from zig build)
        const backend_exe = "zig-out/bin/backend";

        // Now run the backend, which generates output_emitted.zig and compiles it
        // If a comptime command was detected, pass it to the backend
        var backend_args_list = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        defer backend_args_list.deinit(allocator);

        const backend_path = std.fs.path.join(allocator, &.{ ".", backend_exe }) catch backend_exe;
        try backend_args_list.append(allocator, backend_path);

        if (detected_comptime_command) |cmd| {
            // Pass command as first argument (backend checks args[1] for commands)
            try backend_args_list.append(allocator, cmd);
        } else {
            // Normal compilation - pass output exe name
            try backend_args_list.append(allocator, exe_name);
        }

        defer if (backend_path.ptr != backend_exe.ptr) allocator.free(backend_path);

        // Run backend in the output directory
        // Note: default max_output_bytes is only 50KB, way too small for large compilations
        const backend_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = backend_args_list.items,
            .cwd = output_dir_for_build,
            .max_output_bytes = 10 * 1024 * 1024, // 10MB should be plenty
        });
        defer allocator.free(backend_result.stdout);
        defer allocator.free(backend_result.stderr);

        // Print backend output
        if (backend_result.stdout.len > 0) {
            try printStdout(allocator, "{s}", .{backend_result.stdout});
        }
        if (backend_result.stderr.len > 0) {
            try printStdout(allocator, "{s}", .{backend_result.stderr});
        }

        if (backend_result.term.Exited != 0) {
            try printStderr(allocator, "✗ Backend execution failed\n", .{});
            std.process.exit(1);
        }

        // Backend is in zig-out/bin/main - no cleanup needed
        // Users can clean with: rm -rf zig-out

        try printStdout(allocator, "✓ Built executable: {s}\n", .{exe_name});

        // If run command, execute the binary
        if (run_after_build) {
            try printStdout(allocator, "Running {s}...\n\n", .{exe_name});

            const exe_path = try std.fs.path.join(allocator, &.{ ".", exe_name });
            defer allocator.free(exe_path);

            // Run from the output directory so relative paths work
            const run_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{exe_path},
                .cwd = output_dir_for_build,
            });
            defer allocator.free(run_result.stdout);
            defer allocator.free(run_result.stderr);

            if (run_result.stdout.len > 0) {
                try printStdout(allocator, "{s}", .{run_result.stdout});
            }
            if (run_result.stderr.len > 0) {
                try printStdout(allocator, "{s}", .{run_result.stderr});
            }

            if (run_result.term.Exited != 0) {
                std.process.exit(run_result.term.Exited);
            }
        }
    }

    // NOTE: AST cleanup now happens immediately after backend generation (line ~1485)
    // to properly free all memory before exit
}
