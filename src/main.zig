const std = @import("std");
const log = @import("log");
const Parser = @import("parser").Parser;
const errors = @import("errors");
const ErrorReporter = errors.ErrorReporter;
const shape_checker = @import("shape_checker");
const ShapeChecker = shape_checker.ShapeChecker;
const purity_checker = @import("purity_checker.zig");
const PurityChecker = purity_checker.PurityChecker;
const compiler_feature_flags = @import("compiler_config");
// Old Emitter no longer needed - using ComptimeEmitter
const ast = @import("ast");
const TypeRegistry = @import("type_registry").TypeRegistry;
const validate_abstract_impl = @import("validate_abstract_impl");
// CompilerBootstrap removed - using abstract/impl mechanism instead
// compiler_coordination.zig removed - all passes run in backend via compiler.kz
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
const codegen_utils = @import("codegen_utils");
const emitter_helpers = @import("emitter_helpers");
const ccp = @import("ccp.zig");

const version = "0.1.3";

/// Write a branch name, escaping Zig keywords with @"..."
fn writeBranchName(writer: anytype, name: []const u8) !void {
    if (codegen_utils.needsEscaping(name)) {
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
fn generateBackendCode(allocator: std.mem.Allocator, serialized_ast: []const u8, input_file: []const u8, source_file: *ast.Program, use_visitor: bool, config: *const CompilerConfig, has_transforms: bool) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, serialized_ast.len + 2048);
    const writer = buffer.writer(allocator);

    // Write header
    try writer.print("// Koru Backend (Pass 2) for: {s}\n", .{input_file});
    try writer.writeAll("// This file IS the compiler backend - it generates final code at compile-time\n\n");

    // Include the serialized AST
    try writer.writeAll(serialized_ast);
    try writer.writeAll("\n\n");

    // Import emitter_helpers at top level so build:config can be queried during compilation
    try writer.writeAll("const emitter_helpers = @import(\"emitter_helpers\");\n");
    // Standard library import — namespaced to avoid shadowing struct-scoped 'std' in modules
    try writer.writeAll("const __koru_std = @import(\"std\");\n\n");

    // Generate CompilerEnv - makes compilation context available at backend comptime
    // Made pub so backend_output_emitted.zig can access it via @import("root")
    try writer.writeAll("/// Compiler Environment - Query compilation context at backend comptime\n");
    try writer.writeAll("pub const CompilerEnv = struct {\n");

    // Generate the flags array for runtime access
    try writer.writeAll("    /// All compiler flags (for runtime checking)\n");
    try writer.writeAll("    pub const flags = &[_][]const u8{\n");
    for (config.flags.items) |flag| {
        try writer.print("        \"{s}\",\n", .{flag});
    }
    try writer.writeAll("    };\n\n");

    try writer.writeAll("    /// Check if a compiler flag is set (comptime)\n");
    try writer.writeAll("    pub fn hasFlag(comptime name: []const u8) bool {\n");

    // Generate comptime switch for all flags
    if (config.flags.items.len == 0) {
        try writer.writeAll("        _ = name;\n");
        try writer.writeAll("        return false;\n");
    } else {
        try writer.writeAll("        inline for (flags) |flag| {\n");
        try writer.writeAll("            if (__koru_std.mem.eql(u8, name, flag)) return true;\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("        return false;\n");
    }
    try writer.writeAll("    }\n\n");

    // Generate runtime flag checker
    try writer.writeAll("    /// Check if a compiler flag is set (runtime)\n");
    try writer.writeAll("    pub fn hasFlagRuntime(name: []const u8) bool {\n");
    try writer.writeAll("        for (flags) |flag| {\n");
    try writer.writeAll("            if (__koru_std.mem.eql(u8, name, flag)) return true;\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("        return false;\n");
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
                try writer.print("        if (__koru_std.mem.eql(u8, key, \"{s}\")) return \"{s}\";\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            } else {
                try writer.print("        if (__koru_std.mem.eql(u8, key, \"{s}\")) return \"{s}\";\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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

        // Import libraries used by multiple compiler procs
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
        // Comptime flows (flows invoking events with Source/Program params)
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
        // NOTE: Events with Source/Program parameters are [comptime|transform] events
        // Flows invoking them should be transformed at runtime, NOT executed as comptime thunks
        // For now, we SKIP these from comptime thunk generation (user guidance: postpone top-level comptime flows)
        var comptime_event_names = try std.ArrayList([]const u8).initCapacity(allocator, 16);
        defer comptime_event_names.deinit(allocator);

        // Step 2: Find comptime flows
        // NOTE: Transform events ([comptime|transform]) are handled entirely by
        // the transform pass runner at Zig comptime — they don't need thunks.
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

                for (comptime_event_names.items) |comptime_name| {
                    if (std.mem.eql(u8, inv_name, comptime_name)) {
                        log.debug("  [MATCH] Flow '{s}' (idx={}) matches comptime event '{s}'\n", .{ inv_name, idx, comptime_name });
                        try comptime_flows.append(allocator, .{
                            .ast_index = idx,
                            .flow = flow,
                        });
                        log.debug("    → Appended to comptime_flows, now {} items\n", .{comptime_flows.items.len});
                        break;
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

                        for (comptime_event_names.items) |comptime_name| {
                            if (std.mem.eql(u8, inv_name, comptime_name)) {
                                log.debug("  [MATCH-MODULE] Flow '{s}' in module matches comptime event '{s}'\n", .{ inv_name, comptime_name });
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

        // Debug: Print detected comptime flows
        if (comptime_flows.items.len > 0) {
            log.debug("\n=== COMPTIME FLOW DETECTION ===\n", .{});
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
                log.debug("  Detected comptime flow: {s} (ast_index={})\n", .{ inv_name, flow_info.ast_index });
            }
            log.debug("===============================\n\n", .{});
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
                const has_void_continuation = flow.continuations.len == 1 and flow.continuations[0].branch.len == 0;
                if (has_void_continuation) {
                    const cont = flow.continuations[0];
                    try writer.writeAll("        _ = &__thunk_result;\n");
                    if (cont.node) |step| {
                        try writer.writeAll("        ");
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
                                    // Always quote nested invocation args in comptime thunks.
                                    // These are AST data, not runtime expressions.
                                    const text_to_quote = if (arg.source_value) |sv| sv.text else arg.value;
                                    try writer.writeAll("\"");
                                    for (text_to_quote) |c| {
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
                            },
                            .terminal => {},
                            else => {
                                try writer.writeAll("// TODO: Handle step type\n");
                            },
                        }
                    }
                } else {
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
                        // Skip for "_" since that's a discard and can't be referenced
                        if (cont.binding) |binding| {
                            if (!std.mem.eql(u8, binding, "_")) {
                                try writer.writeAll("                _ = &");
                                try writer.writeAll(binding);
                                try writer.writeAll(";\n");
                            }
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
                                        // Always quote nested invocation args in comptime thunks.
                                        // These are AST data, not runtime expressions.
                                        const text_to_quote = if (arg.source_value) |sv| sv.text else arg.value;
                                        try writer.writeAll("\"");
                                        for (text_to_quote) |c| {
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
                }
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
            log.err("\n✗✗✗ FATAL: Compiler module not found in source_file.items ✗✗✗\n", .{});
            log.err("Backend generation requires the compiler module to be imported.\n", .{});
            log.err("This should have been auto-injected during parsing.\n", .{});
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
        // The compiler pipeline is now fully flow-based in koru_std/compiler.kz
        // The coordinate event (abstract) handles both default and user-overridden pipelines
        // via cross-module subflow overrides - no special detection needed!
        // ============================================================================

        // Add runtime emitter that calls the coordinate event from backend_output_emitted.zig
        try writer.writeAll(
            \\// Runtime emitter - calls the coordinate event from compiler.kz
            \\// The visitor emitter handles abstract/impl resolution automatically
            \\const RuntimeEmitter = struct {
            \\    pub fn emit(allocator: __koru_std.mem.Allocator, source_ast: *const Program) ![]const u8 {
            \\
        );

        // Call the coordinate event - abstract/impl mechanism handles user overrides
        try writer.writeAll("        // Call coordinate event (uses cross-module override if provided, otherwise default)\n");
        try writer.writeAll("        const result = backend_output.koru_");
        try writer.writeAll(compiler_module);
        try writer.writeAll(".coordinate_event.handler(.{ .program_ast = source_ast, .allocator = allocator });\n\n");

        try writer.writeAll(
            \\        // Handle both success and error branches
            \\        switch (result) {
            \\            .coordinated => |r| {
            \\                __koru_std.debug.print("🎯 Compiler coordination: {s}\n", .{r.metrics});
            \\                return r.code;
            \\            },
            \\            .@"error" => |e| {
            \\                __koru_std.debug.print("❌ Compiler coordination error: {s}\n", .{e.message});
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
            \\fn dumpAST(program_ast: *const Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
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

        // Backend main() function - now calls emit at runtime
        try writer.writeAll("// === KORU BACKEND CODE GENERATOR ===\n");
        try writer.writeAll("// This outputs the final Zig code generated by compiler.emit.zig\n\n");

        // Backend entry point - compiles the generated code
        try writer.writeAll(
            \\pub fn main() !void {
            \\    var gpa = __koru_std.heap.GeneralPurposeAllocator(.{}){};
            \\    defer {
            \\        const leak_status = gpa.deinit();
            \\        if (leak_status == .leak) {
            \\            __koru_std.debug.print("Memory leak detected\n", .{});
            \\        }
            \\    }
            \\    const allocator = gpa.allocator();
            \\
            \\    // Arena allocator for compilation phase - all compiler passes, code generation, etc.
            \\    var compile_arena = __koru_std.heap.ArenaAllocator.init(allocator);
            \\    defer compile_arena.deinit();
            \\    const compile_allocator = compile_arena.allocator();
            \\
            \\    // Get the output filename from argv (passed from koruc)
            \\    const args = try __koru_std.process.argsAlloc(allocator);
            \\    defer __koru_std.process.argsFree(allocator, args);
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
                \\
            );

            // Generate command checks
            // Commands call MODULE.EVENT_event.handler(.{ .program = ..., .allocator = ..., .argv = ... })
            for (cmd_result.commands[0..cmd_result.count]) |cmd| {
                var buf: [1024]u8 = undefined;
                if (cmd.module_path) |mod_path| {
                    // Convert module path to emitted Zig namespace
                    // All module paths are prefixed with koru_ in emitted code:
                    //   std.build → koru_std.build
                    //   koru.docker → koru_koru.docker
                    //   orisha → koru_orisha
                    var zig_mod_path: [256]u8 = undefined;
                    const zig_mod = try std.fmt.bufPrint(&zig_mod_path, "backend_output.koru_{s}", .{mod_path});

                    const line = try std.fmt.bufPrint(&buf,
                        \\        if (__koru_std.mem.eql(u8, args[1], "{s}")) {{
                        \\            __koru_std.debug.print("🔧 Running command: {s}\n", .{{}});
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
                        \\        if (__koru_std.mem.eql(u8, args[1], "{s}")) {{
                        \\            __koru_std.debug.print("🔧 Running command: {s}\n", .{{}});
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
            \\    const output_exe = if (args.len > 1 and !__koru_std.mem.endsWith(u8, args[1], ".kz")) args[1] else "a.out";
            \\
            \\    // Apply compiler passes
            \\    // Each pass takes PROGRAM_AST pointer and current AST pointer
            \\    // Returns same pointer if no changes, or new heap-allocated AST if optimized
            \\    var current_ast: *const Program = &PROGRAM_AST;
            \\
            \\    // DUMP POINT 1: Original AST at backend entry
            \\    dumpAST(&PROGRAM_AST, "1-backend-start", compile_allocator);
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
            \\    __koru_std.debug.print("\n[MAIN DEBUG] Before file write:\n", .{});
            \\    __koru_std.debug.print("[MAIN DEBUG]   generated_code.len = {d}\n", .{generated_code.len});
            \\    __koru_std.debug.print("[MAIN DEBUG]   generated_code.ptr = {*}\n", .{generated_code.ptr});
            \\    __koru_std.debug.print("[MAIN DEBUG]   emitted_file = {s}\n", .{emitted_file});
            \\    __koru_std.debug.print("[MAIN DEBUG]   emitted_file.ptr = {*}\n", .{emitted_file.ptr});
            \\    __koru_std.debug.print("[MAIN DEBUG]   First 50 bytes: ", .{});
            \\    for (generated_code[0..@min(50, generated_code.len)]) |byte| {
            \\        if (byte >= 32 and byte < 127) {
            \\            __koru_std.debug.print("{c}", .{byte});
            \\        } else {
            \\            __koru_std.debug.print("[{d}]", .{byte});
            \\        }
            \\    }
            \\    __koru_std.debug.print("\n\n", .{});
            \\
            \\    // Write the generated code to a file
            \\    const file = try __koru_std.fs.cwd().createFile(emitted_file, .{});
            \\    defer file.close();
            \\    try file.writeAll(generated_code);
            \\
            \\    // Report what we generated
            \\    const stdout = __koru_std.fs.File.stdout();
            \\    var buf: [512]u8 = undefined;
            \\    const msg = try __koru_std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, generated_code.len});
            \\    try stdout.writeAll(msg);
            \\
            \\    // Now compile the emitted code
            \\    // Check for cross-compilation target from build:config
            \\    const build_target = emitter_helpers.getBuildConfig("target");
            \\
            \\    // First check if build_output.zig exists (has user build requirements)
            \\    const has_build_output = blk: {
            \\        __koru_std.fs.cwd().access("build_output.zig", .{}) catch break :blk false;
            \\        break :blk true;
            \\    };
            \\
            \\    if (has_build_output) {
            \\        // Use zig build with build_output.zig (includes user dependencies)
            \\        var bo_argv: [5][]const u8 = undefined;
            \\        bo_argv[0] = "zig";
            \\        bo_argv[1] = "build";
            \\        bo_argv[2] = "--build-file";
            \\        bo_argv[3] = "build_output.zig";
            \\        var bo_argc: usize = 4;
            \\        var dt_buf: [128]u8 = undefined;
            \\        if (build_target) |t| {
            \\            bo_argv[4] = __koru_std.fmt.bufPrint(&dt_buf, "-Dtarget={s}", .{t}) catch "-Dtarget=native";
            \\            bo_argc = 5;
            \\        }
            \\        const result = __koru_std.process.Child.run(.{
            \\            .allocator = allocator,
            \\            .argv = bo_argv[0..bo_argc],
            \\        }) catch |err| {
            \\            const stderr = __koru_std.fs.File.stderr();
            \\            var err_buf: [512]u8 = undefined;
            \\            const err_msg = try __koru_std.fmt.bufPrint(&err_buf, "✗ Failed to spawn zig compiler: {}\n", .{err});
            \\            try stderr.writeAll(err_msg);
            \\            __koru_std.process.exit(1);
            \\        };
            \\        defer allocator.free(result.stdout);
            \\        defer allocator.free(result.stderr);
            \\
            \\        const stdout2 = __koru_std.fs.File.stdout();
            \\        var buf2: [512]u8 = undefined;
            \\        if (result.term.Exited == 0) {
            \\            // Copy from zig-out/bin/output to the requested output name
            \\            __koru_std.fs.cwd().copyFile("zig-out/bin/output", __koru_std.fs.cwd(), output_exe, .{}) catch |copy_err| {
            \\                const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Failed to copy output: {}\n", .{copy_err});
            \\                try __koru_std.fs.File.stderr().writeAll(msg2);
            \\                __koru_std.process.exit(1);
            \\            };
            \\            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✓ Compiled to {s}\n", .{output_exe});
            \\            try stdout2.writeAll(msg2);
            \\        } else {
            \\            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
            \\            try stdout2.writeAll(msg2);
            \\            if (result.stderr.len > 0) {
            \\                var err_buf2: [65536]u8 = undefined;
            \\                const err_msg2 = try __koru_std.fmt.bufPrint(&err_buf2, "Error: {s}\n", .{result.stderr});
            \\                try __koru_std.fs.File.stderr().writeAll(err_msg2);
            \\            }
            \\            __koru_std.process.exit(1);
            \\        }
            \\    } else {
            \\        // Fall back to direct zig build-exe (no user dependencies)
            \\        var emit_path_buf: [256]u8 = undefined;
            \\        const emit_path = try __koru_std.fmt.bufPrint(&emit_path_buf, "-femit-bin={s}", .{output_exe});
            \\        const debug = CompilerEnv.hasFlag("debug");
            \\        var exe_argv: [14][]const u8 = undefined;
            \\        var exe_argc: usize = 0;
            \\        exe_argv[exe_argc] = "zig"; exe_argc += 1;
            \\        exe_argv[exe_argc] = "build-exe"; exe_argc += 1;
            \\        exe_argv[exe_argc] = emitted_file; exe_argc += 1;
            \\        if (build_target) |t| {
            \\            exe_argv[exe_argc] = "-target"; exe_argc += 1;
            \\            exe_argv[exe_argc] = t; exe_argc += 1;
            \\        }
            \\        exe_argv[exe_argc] = "-O"; exe_argc += 1;
            \\        if (debug) {
            \\            exe_argv[exe_argc] = "ReleaseFast"; exe_argc += 1;
            \\        } else {
            \\            exe_argv[exe_argc] = "ReleaseSmall"; exe_argc += 1;
            \\            exe_argv[exe_argc] = "-fstrip"; exe_argc += 1;
            \\            exe_argv[exe_argc] = "-fno-unwind-tables"; exe_argc += 1;
            \\            exe_argv[exe_argc] = "-z"; exe_argc += 1;
            \\            exe_argv[exe_argc] = "norelro"; exe_argc += 1;
            \\        }
            \\        exe_argv[exe_argc] = emit_path; exe_argc += 1;
            \\        const result = __koru_std.process.Child.run(.{
            \\            .allocator = allocator,
            \\            .argv = exe_argv[0..exe_argc],
            \\        }) catch |err| {
            \\            const stderr = __koru_std.fs.File.stderr();
            \\            var err_buf: [512]u8 = undefined;
            \\            const err_msg = try __koru_std.fmt.bufPrint(&err_buf, "✗ Failed to spawn zig compiler: {}\n", .{err});
            \\            try stderr.writeAll(err_msg);
            \\            __koru_std.process.exit(1);
            \\        };
            \\        defer allocator.free(result.stdout);
            \\        defer allocator.free(result.stderr);
            \\
            \\        const stdout2 = __koru_std.fs.File.stdout();
            \\        var buf2: [512]u8 = undefined;
            \\        if (result.term.Exited == 0) {
            \\            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✓ Compiled to {s}\n", .{output_exe});
            \\            try stdout2.writeAll(msg2);
            \\        } else {
            \\            const msg2 = try __koru_std.fmt.bufPrint(&buf2, "✗ Compilation failed\n", .{});
            \\            try stdout2.writeAll(msg2);
            \\            if (result.stderr.len > 0) {
            \\                var err_buf2: [65536]u8 = undefined;
            \\                const err_msg2 = try __koru_std.fmt.bufPrint(&err_buf2, "Error: {s}\n", .{result.stderr});
            \\                try __koru_std.fs.File.stderr().writeAll(err_msg2);
            \\            }
            \\            __koru_std.process.exit(1);
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
    // Note: emitter_helpers already imported at top-level
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
    try code_emitter.write("const __koru_ast = @import(\"ast\");\n");
    try code_emitter.write("const log = @import(\"log\");\n\n");

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
    log.debug("DEBUG: Running AST transformation in generateComptimeBackendEmitted\n", .{});
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
    stub_name: []const u8, // e.g., "control_if" - unique name for call_handler_X function
    match_name: []const u8, // e.g., "if" - event name with dots for matching
    event_name: []const u8, // e.g., "if" - original event name for handler struct lookup
    module_path: ?[]const u8, // e.g., "koru_std.control" for stdlib, null for main_module
    has_source: bool, // Event accepts source: Source[T] parameter
    has_expression: bool, // Event accepts expr: Expression parameter
    expression_field_name: ?[]const u8 = null, // Actual field name for Expression parameter
    has_invocation: bool, // Event accepts invocation: *const Invocation parameter
    has_event_decl: bool, // Event accepts event_decl: *const EventDecl parameter
    has_item: bool, // Event accepts item: *const Item parameter
    has_program_ast: bool, // Event accepts program: *const Program parameter
    has_allocator: bool, // Event accepts allocator: std.mem.Allocator parameter
    has_event_name_field: bool, // Event accepts event_name: []const u8 parameter (for glob patterns)
    returns_program: bool, // Event returns transformed{ program: *const Program }
    has_failed: bool, // Event has failed{ error: []const u8 } branch
    has_compile_error: bool, // Event has compile_error{ message: []const u8 } branch
};

/// CommandInfo stores CLI command metadata for [comptime|command] events
/// Commands run instead of normal compilation when invoked via `koruc file.kz <command>`
const CommandInfo = struct {
    name: []const u8, // e.g., "install" - command name for CLI
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
                var expression_field_name: ?[]const u8 = null;
                var has_invocation = false;
                var has_program_ast = false;
                var has_allocator = false;

                for (event_decl.input.fields) |field| {
                    if (field.is_source) {
                        has_source = true;
                    } else if (field.is_expression) {
                        has_expression = true;
                        expression_field_name = field.name;
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
                var has_compile_error = false;
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
                    } else if (std.mem.eql(u8, branch.name, "compile_error")) {
                        has_compile_error = true;
                    }
                }

                transform_events[transform_count] = .{
                    .stub_name = stub_name,
                    .match_name = match_name,
                    .event_name = stub_name, // For top-level, stub_name = event_name
                    .module_path = null, // Top-level events are in main_module
                    .has_source = has_source,
                    .has_expression = has_expression,
                    .expression_field_name = expression_field_name,
                    .has_invocation = has_invocation,
                    .has_event_decl = false,
                    .has_item = false,
                    .has_program_ast = has_program_ast,
                    .has_allocator = has_allocator,
                    .has_event_name_field = false,
                    .has_compile_error = has_compile_error,
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
                            const rest = module.logical_name[4..]; // Skip "std."
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
                        var expression_field_name: ?[]const u8 = null;
                        var has_invocation = false;
                        var has_program_ast = false;
                        var has_allocator = false;

                        for (event_decl.input.fields) |field| {
                            if (field.is_source) {
                                has_source = true;
                            } else if (field.is_expression) {
                                has_expression = true;
                                expression_field_name = field.name;
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
                        var has_compile_error = false;
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
                            } else if (std.mem.eql(u8, branch.name, "compile_error")) {
                                has_compile_error = true;
                            }
                        }

                        // Dupe event_name since it's freed after this scope
                        const event_name_duped = try allocator.dupe(u8, event_name);

                        transform_events[transform_count] = .{
                            .stub_name = stub_name,
                            .match_name = match_name,
                            .event_name = event_name_duped,
                            .module_path = module_path, // Transform is in imported module
                            .has_source = has_source,
                            .has_expression = has_expression,
                            .expression_field_name = expression_field_name,
                            .has_invocation = has_invocation,
                            .has_event_decl = false,
                            .has_item = false,
                            .has_program_ast = has_program_ast,
                            .has_allocator = has_allocator,
                            .has_event_name_field = false,
                            .has_compile_error = has_compile_error,
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
            try writer.print("fn call_transform_{s}(invocation: *const Invocation, containing_item: *const Item, ast: *const Program, allocator: __koru_std.mem.Allocator) !struct {{ item: Item, program: *const Program }} {{\n", .{event.stub_name});
        } else {
            try writer.print("fn call_transform_{s}(invocation: *const Invocation, containing_item: *const Item, ast: *const Program, allocator: __koru_std.mem.Allocator) !Item {{\n", .{event.stub_name});
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
        try writer.writeAll("pub fn process_all_transforms(ast: *const Program, allocator: __koru_std.mem.Allocator) !*Program {\n");
        try writer.writeAll("    // Import joinPath helper from backend\n");
        try writer.writeAll("    const joinPath = @import(\"backend_output_emitted\").koru_std.compiler.joinPath;\n");
        try writer.writeAll("    \n");
        try writer.writeAll("    // Track current AST state (transforms may return modified AST)\n");
        try writer.writeAll("    var current_ast = ast;\n");
        try writer.writeAll("    var items_list = __koru_std.ArrayList(Item){};\n");
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
                try writer.print("            if (__koru_std.mem.eql(u8, inv_path, \"{s}\")) {{\n", .{event.match_name});
            } else {
                try writer.print("            }} else if (__koru_std.mem.eql(u8, inv_path, \"{s}\")) {{\n", .{event.match_name});
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
            var expression_field_name_param: ?[]const u8 = null;
            var has_invocation_param = false;
            var has_item_param = false;
            var has_event_decl_param = false;

            for (event_decl.input.fields) |field| {
                if (field.is_source) {
                    has_source_param = true;
                } else if (field.is_expression) {
                    has_expression_param = true;
                    expression_field_name_param = field.name;
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
                    log.err("\nERROR: Event '{s}' consumes *const {s} but won't be emitted to backend\n", .{ event_name, if (has_event_decl_param) "EventDecl" else "Invocation" });
                    log.err("\n", .{});
                    log.err("AST-consuming handlers must be available at compile-time. Add [comptime]:\n", .{});
                    log.err("  ~[comptime] event {s} {{ ... }}\n", .{event_name});
                    log.err("\n", .{});
                    _ = handler_type;
                    return error.TransformMissingComptimeAnnotation;
                }
            }

            // Emit handlers for events that consume AST types
            const should_generate_handler = consumes_ast_types;

            if (should_generate_handler and transform_count < 16) {
                const stub_name = try joinPathSegments(allocator, event_decl.path.segments);
                const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                // Detect additional parameters by NAME (program, allocator, event_name)
                // Note: invocation/event_decl/item already detected by TYPE above
                var has_program_ast = false;
                var has_allocator = false;
                var has_event_name_field = false;

                for (event_decl.input.fields) |field| {
                    if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
                        has_program_ast = true;
                    } else if (std.mem.eql(u8, field.name, "allocator")) {
                        has_allocator = true;
                    } else if (std.mem.eql(u8, field.name, "event_name")) {
                        has_event_name_field = true;
                    }
                }

                // Detect what this event returns (check branches)
                var returns_program = false;
                var has_failed = false;
                var has_compile_error = false;
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
                    } else if (std.mem.eql(u8, branch.name, "compile_error")) {
                        has_compile_error = true;
                    }
                }

                transform_events[transform_count] = .{
                    .stub_name = stub_name,
                    .match_name = match_name,
                    .event_name = stub_name, // For top-level, stub_name = event_name
                    .module_path = null, // Top-level events are in main_module
                    .has_source = has_source_param,
                    .has_expression = has_expression_param,
                    .expression_field_name = expression_field_name_param,
                    .has_invocation = has_invocation_param,
                    .has_event_decl = has_event_decl_param,
                    .has_item = has_item_param,
                    .has_program_ast = has_program_ast,
                    .has_allocator = has_allocator,
                    .has_event_name_field = has_event_name_field,
                    .has_compile_error = has_compile_error,
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
                    var expression_field_name_param: ?[]const u8 = null;
                    var has_invocation_param = false;
                    var has_item_param = false;
                    var has_event_decl_param = false;

                    for (event_decl.input.fields) |field| {
                        if (field.is_source) {
                            has_source_param = true;
                        } else if (field.is_expression) {
                            has_expression_param = true;
                            expression_field_name_param = field.name;
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
                            module_name = rest; // e.g., "control" or "compiler_requirements"
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

                        // Detect additional parameters by NAME (program, allocator, event_name)
                        // Note: invocation/event_decl/item already detected by TYPE above
                        var has_program_ast = false;
                        var has_allocator = false;
                        var has_event_name_field = false;

                        for (event_decl.input.fields) |field| {
                            if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
                                has_program_ast = true;
                            } else if (std.mem.eql(u8, field.name, "allocator")) {
                                has_allocator = true;
                            } else if (std.mem.eql(u8, field.name, "event_name")) {
                                has_event_name_field = true;
                            }
                        }

                        // Detect return type
                        var returns_program = false;
                        var has_failed = false;
                        var has_compile_error = false;
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
                            } else if (std.mem.eql(u8, branch.name, "compile_error")) {
                                has_compile_error = true;
                            }
                        }

                        transform_events[transform_count] = .{
                            .stub_name = stub_name,
                            .match_name = match_name,
                            .event_name = event_name, // Original event name for handler lookup
                            .module_path = module_path,
                            .has_source = has_source_param,
                            .has_expression = has_expression_param,
                            .expression_field_name = expression_field_name_param,
                            .has_invocation = has_invocation_param,
                            .has_event_decl = has_event_decl_param,
                            .has_item = has_item_param,
                            .has_program_ast = has_program_ast,
                            .has_allocator = has_allocator,
                            .has_event_name_field = has_event_name_field,
                            .has_compile_error = has_compile_error,
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
            try code_emitter.write("        log.debug(\"ERROR: Derive handler called with non-event_decl node\\n\", .{});\n");
            try code_emitter.write("        @panic(\"derive: expected event_decl node\");\n");
            try code_emitter.write("    };\n");
        } else if (event.has_invocation or event.has_item) {
            // Transform handler: node is always an invocation for invocation-based transforms
            try code_emitter.write("    const invocation = node.invocation;\n");

            // If handler needs item, find it using ASTNode helper
            if (event.has_item) {
                try code_emitter.write("    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {\n");
                try code_emitter.write("        log.debug(\"ERROR: Could not find containing item for invocation\\n\", .{});\n");
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
            const debug_derive = try std.fmt.bufPrint(&buf, "    log.debug(\"[DERIVE] {s}: processing event declaration\\n\", .{{}});\n", .{event.stub_name});
            try code_emitter.write(debug_derive);
        } else if (event.has_invocation or event.has_item) {
            const debug_count = try std.fmt.bufPrint(&buf, "    log.debug(\"[TRANSFORM] {s}: {{d}} args\\n\", .{{invocation.args.len}});\n", .{event.stub_name});
            try code_emitter.write(debug_count);
            try code_emitter.write("    for (invocation.args, 0..) |arg, i| {\n");
            try code_emitter.write("        log.debug(\"  Arg[{d}]: name='{s}' has_source={} has_expr={}\\n\", .{i, arg.name, arg.source_value != null, arg.expression_value != null});\n");
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
                    try code_emitter.write("            log.debug(\"Derive failed: {s}\\n\", .{f.@\"error\"});\n");
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
                try code_emitter.write("            .");
                try code_emitter.write(event.expression_field_name orelse "expr");
                try code_emitter.write(" = expr_text,\n");
            } else if (event.has_source) {
                try code_emitter.write("    if (source_opt) |source| {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .source = source,\n");
            } else if (event.has_expression) {
                try code_emitter.write("    if (expr_opt) |expr_text| {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .");
                try code_emitter.write(event.expression_field_name orelse "expr");
                try code_emitter.write(" = expr_text,\n");
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
            if (event.has_event_name_field) {
                // Build event_name from invocation path segments (e.g., "log.warning" from log.* match)
                try code_emitter.write("            .event_name = blk: {\n");
                try code_emitter.write("                var name_buf: [256]u8 = undefined;\n");
                try code_emitter.write("                var name_len: usize = 0;\n");
                try code_emitter.write("                for (invocation.path.segments, 0..) |seg, i| {\n");
                try code_emitter.write("                    if (i > 0) {\n");
                try code_emitter.write("                        name_buf[name_len] = '.';\n");
                try code_emitter.write("                        name_len += 1;\n");
                try code_emitter.write("                    }\n");
                try code_emitter.write("                    @memcpy(name_buf[name_len..name_len + seg.len], seg);\n");
                try code_emitter.write("                    name_len += seg.len;\n");
                try code_emitter.write("                }\n");
                try code_emitter.write("                break :blk name_buf[0..name_len];\n");
                try code_emitter.write("            },\n");
            }

            // Call handler and handle result
            try code_emitter.write("        };\n");
            if (event.returns_program) {
                try code_emitter.write("        const result = handler.handler(input);\n");
                try code_emitter.write("        return switch (result) {\n");
                try code_emitter.write("            .transformed => |t| t.program,\n");
                if (event.has_failed) {
                    try code_emitter.write("            .failed => |f| {\n");
                    try code_emitter.write("                log.debug(\"Transform failed: {s}\\n\", .{f.@\"error\"});\n");
                    try code_emitter.write("                return error.TransformFailed;\n");
                    try code_emitter.write("            },\n");
                }
                if (event.has_compile_error) {
                    try code_emitter.write("            .compile_error => |ce| {\n");
                    try code_emitter.write("                log.debug(\"Compile error: {s}\\n\", .{ce.message});\n");
                    try code_emitter.write("                return error.CompileError;\n");
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
/// Escapes glob characters: * -> _star_
fn joinPathSegments(allocator: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    if (segments.len == 0) return try allocator.dupe(u8, "unknown");

    // Calculate total length, accounting for * -> _star_ expansion
    var total_len: usize = 0;
    for (segments, 0..) |seg, i| {
        if (i > 0) total_len += 1; // underscore separator
        for (seg) |c| {
            if (c == '*') {
                total_len += 5; // "_star_" minus the "*" = 5 extra chars
            }
        }
        total_len += seg.len;
    }

    // Build result with escaping
    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (segments, 0..) |seg, i| {
        if (i > 0) {
            result[pos] = '_';
            pos += 1;
        }
        for (seg) |c| {
            if (c == '*') {
                @memcpy(result[pos..][0..6], "_star_");
                pos += 6;
            } else {
                result[pos] = c;
                pos += 1;
            }
        }
    }

    return result[0..pos];
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

    @memcpy(result[pos .. pos + segments[0].len], segments[0]);
    pos += segments[0].len;

    for (segments[1..]) |seg| {
        result[pos] = '.';
        pos += 1;
        @memcpy(result[pos .. pos + seg.len], seg);
        pos += seg.len;
    }

    return result;
}

/// Match a pattern against a value using glob semantics
/// Patterns can use * for wildcards (e.g., log.* matches log.info)

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
        try writer.writeAll("const compiler_config = @import(\"compiler_config\");\n");
        try writer.writeAll("const type_registry_module = @import(\"type_registry\");\n\n");

        try writer.writeAll("const emit_zig_handler = struct {\n");
        try writer.writeAll("    pub const Input = struct { ast: *const Program, allocator: __koru_std.mem.Allocator };\n");
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
            \\        // Taps are already inserted by the transform pipeline
            \\        const ast_to_emit = __koru_event_input.ast;
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
        \\const coordinate_handler = struct {
        \\    pub const Input = struct { ast: *const Program, allocator: __koru_std.mem.Allocator };
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
        \\        const ccp_result = try inject_ccp.handler(.{ .ast = __koru_event_input.ast, .allocator = allocator });
        \\
        \\        const result = try emit_zig.handler(.{ .ast = ccp_result.instrumented.ast, .allocator = allocator });
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
        \\    var gpa = __koru_std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer {
        \\        const leak_status = gpa.deinit();
        \\        if (leak_status == .leak) {
        \\            __koru_std.debug.print("Memory leak detected\n", .{});
        \\        }
        \\    }
        \\    const allocator = gpa.allocator();
        \\
        \\    // Arena allocator for compilation phase
        \\    var compile_arena = __koru_std.heap.ArenaAllocator.init(allocator);
        \\    defer compile_arena.deinit();
        \\    const compile_allocator = compile_arena.allocator();
        \\
        \\    const args = try __koru_std.process.argsAlloc(allocator);
        \\    defer __koru_std.process.argsFree(allocator, args);
        \\
        \\    const emitted_file = "output_emitted.zig";
        \\    // NOTE: args[1] is the output exe name when called from frontend,
        \\    // but when running backend directly, args[1] might be the input .kz file.
        \\    // Detect this case and default to "a.out" instead of overwriting the source!
        \\    const output_exe = if (args.len > 1 and !__koru_std.mem.endsWith(u8, args[1], ".kz")) args[1] else "a.out";
        \\
        \\    var actual_len: usize = generated_code.len;
        \\    while (actual_len > 0 and generated_code[actual_len - 1] == 0) {
        \\        actual_len -= 1;
        \\    }
        \\    const trimmed_code = generated_code[0..actual_len];
        \\
        \\    const file = try __koru_std.fs.cwd().createFile(emitted_file, .{});
        \\    defer file.close();
        \\    try file.writeAll(trimmed_code);
        \\
        \\    const stdout = __koru_std.fs.File.stdout();
        \\    var buf: [512]u8 = undefined;
        \\    const msg = try __koru_std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, actual_len});
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

/// Built-in deps command - runs in frontend, no compilation needed
fn runBuiltinDeps(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const min_zig_version = .{ .major = 0, .minor = 15, .patch = 0 };

    // Check for "install" subcommand
    var do_install = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "install")) {
            do_install = true;
        }
    }

    std.debug.print("\nDependencies:\n\n", .{});

    // Check Zig installation
    const zig_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig", "version" },
    }) catch {
        std.debug.print("  zig \x1b[31m✗\x1b[0m not installed\n", .{});
        if (do_install) {
            std.debug.print("\n", .{});
            try installZig(allocator);
        } else {
            std.debug.print("\nRun `koruc deps install` to install.\n", .{});
        }
        return;
    };
    defer allocator.free(zig_result.stdout);
    defer allocator.free(zig_result.stderr);

    // Parse version from output (e.g., "0.15.1\n")
    const version_str = std.mem.trim(u8, zig_result.stdout, " \t\n\r");
    const parsed = parseVersion(version_str);

    if (parsed) |ver| {
        const version_ok = ver.major > min_zig_version.major or
            (ver.major == min_zig_version.major and ver.minor > min_zig_version.minor) or
            (ver.major == min_zig_version.major and ver.minor == min_zig_version.minor and ver.patch >= min_zig_version.patch);

        if (version_ok) {
            std.debug.print("  zig \x1b[32m✓\x1b[0m {s}\n", .{version_str});
        } else {
            std.debug.print("  zig \x1b[33m⚠\x1b[0m {s} (need {d}.{d}+)\n", .{
                version_str,
                min_zig_version.major,
                min_zig_version.minor,
            });
            if (do_install) {
                std.debug.print("\n", .{});
                try installZig(allocator);
            } else {
                std.debug.print("\nRun `koruc deps install` to upgrade.\n", .{});
            }
            return;
        }
    } else {
        std.debug.print("  zig \x1b[33m?\x1b[0m {s}\n", .{version_str});
    }

    std.debug.print("\n\x1b[32mReady!\x1b[0m\n", .{});
}

fn parseVersion(s: []const u8) ?struct { major: u32, minor: u32, patch: u32 } {
    var i: usize = 0;
    // Skip non-digit prefix
    while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i >= s.len) return null;

    const start = i;
    var dots: [2]usize = .{ 0, 0 };
    var dot_count: usize = 0;

    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {
        if (s[i] == '.' and dot_count < 2) {
            dots[dot_count] = i;
            dot_count += 1;
        }
    }

    if (dot_count < 1) return null;

    const major = std.fmt.parseInt(u32, s[start..dots[0]], 10) catch return null;
    const minor_end = if (dot_count >= 2) dots[1] else i;
    const minor = std.fmt.parseInt(u32, s[dots[0] + 1 .. minor_end], 10) catch return null;
    const patch = if (dot_count >= 2)
        std.fmt.parseInt(u32, s[dots[1] + 1 .. i], 10) catch 0
    else
        0;

    return .{ .major = major, .minor = minor, .patch = patch };
}

fn installZig(allocator: std.mem.Allocator) !void {
    const builtin = @import("builtin");

    // On macOS, try brew first (it works well)
    if (builtin.os.tag == .macos) {
        const check_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", "brew --version" },
        }) catch {
            std.debug.print("  brew not found, trying direct download...\n", .{});
            return installZigDirect(allocator);
        };
        defer allocator.free(check_result.stdout);
        defer allocator.free(check_result.stderr);

        if (check_result.term.Exited == 0) {
            std.debug.print("  Detected brew, running: brew install zig\n", .{});
            const install_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "sh", "-c", "brew install zig" },
            }) catch |err| {
                std.debug.print("  \x1b[31m✗\x1b[0m brew install failed: {s}, trying direct download...\n", .{@errorName(err)});
                return installZigDirect(allocator);
            };
            defer allocator.free(install_result.stdout);
            defer allocator.free(install_result.stderr);

            if (install_result.term.Exited == 0) {
                std.debug.print("  \x1b[32m✓\x1b[0m Zig installed successfully!\n", .{});
                return;
            }
        }
        return installZigDirect(allocator);
    }

    // On Linux, try pacman first (Arch has Zig), then fall back to direct download
    if (builtin.os.tag == .linux) {
        const check_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", "pacman --version" },
        }) catch {
            return installZigDirect(allocator);
        };
        defer allocator.free(check_result.stdout);
        defer allocator.free(check_result.stderr);

        if (check_result.term.Exited == 0) {
            std.debug.print("  Detected pacman, running: sudo pacman -S zig\n", .{});
            const install_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "sh", "-c", "sudo pacman -S --noconfirm zig" },
            }) catch |err| {
                std.debug.print("  \x1b[31m✗\x1b[0m pacman install failed: {s}, trying direct download...\n", .{@errorName(err)});
                return installZigDirect(allocator);
            };
            defer allocator.free(install_result.stdout);
            defer allocator.free(install_result.stderr);

            if (install_result.term.Exited == 0) {
                std.debug.print("  \x1b[32m✓\x1b[0m Zig installed successfully!\n", .{});
                return;
            }
        }
        return installZigDirect(allocator);
    }

    // Windows or other - direct download
    return installZigDirect(allocator);
}

fn printManualInstallHelp() void {
    std.debug.print("\n", .{});
    std.debug.print("  We tried! But you can install Zig yourself:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    Download:  https://ziglang.org/download/\n", .{});
    std.debug.print("    macOS:     brew install zig\n", .{});
    std.debug.print("    Arch:      pacman -S zig\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Koru needs Zig 0.15 or later.\n", .{});
}

fn installZigDirect(allocator: std.mem.Allocator) !void {
    const builtin = @import("builtin");

    // Determine OS and arch for download URL
    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => {
            std.debug.print("  \x1b[31m✗\x1b[0m Unsupported OS for direct download\n", .{});
            printManualInstallHelp();
            return;
        },
    };

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => {
            std.debug.print("  \x1b[31m✗\x1b[0m Unsupported architecture for direct download\n", .{});
            printManualInstallHelp();
            return;
        },
    };

    const ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";
    const zig_version = "0.15.1";

    // Build download URL (format: zig-{arch}-{os}-{version}.tar.xz)
    const url = std.fmt.allocPrint(allocator,
        "https://ziglang.org/download/{s}/zig-{s}-{s}-{s}.{s}",
        .{ zig_version, arch_str, os_str, zig_version, ext }
    ) catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Failed to build download URL\n", .{});
        return;
    };
    defer allocator.free(url);

    // Get home directory
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Could not determine home directory\n", .{});
        return;
    };
    defer allocator.free(home);

    const install_dir = std.fmt.allocPrint(allocator, "{s}/.koru", .{home}) catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Failed to build install path\n", .{});
        return;
    };
    defer allocator.free(install_dir);

    const zig_dir = std.fmt.allocPrint(allocator, "zig-{s}-{s}-{s}", .{arch_str, os_str, zig_version}) catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Failed to build zig dir name\n", .{});
        return;
    };
    defer allocator.free(zig_dir);

    std.debug.print("  Downloading Zig {s} from ziglang.org...\n", .{zig_version});

    // Create install directory
    const mkdir_cmd = std.fmt.allocPrint(allocator, "mkdir -p {s}", .{install_dir}) catch return;
    defer allocator.free(mkdir_cmd);

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", mkdir_cmd },
    }) catch {};

    // Download and extract
    const download_cmd = if (builtin.os.tag == .windows)
        std.fmt.allocPrint(allocator,
            "cd {s} && curl -LSso zig.zip {s} && unzip -o zig.zip && del zig.zip",
            .{ install_dir, url }
        ) catch return
    else
        std.fmt.allocPrint(allocator,
            "cd {s} && curl -LSs {s} | tar -xJ",
            .{ install_dir, url }
        ) catch return;
    defer allocator.free(download_cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", download_cmd },
    }) catch |err| {
        std.debug.print("  \x1b[31m✗\x1b[0m Download failed: {s}\n", .{@errorName(err)});
        printManualInstallHelp();
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("  \x1b[31m✗\x1b[0m Download/extract failed\n", .{});
        if (result.stderr.len > 0) {
            std.debug.print("  {s}\n", .{result.stderr});
        }
        printManualInstallHelp();
        return;
    }

    const zig_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{install_dir, zig_dir}) catch return;
    defer allocator.free(zig_path);

    std.debug.print("  \x1b[32m✓\x1b[0m Installed to {s}\n", .{zig_path});
    std.debug.print("\n  Add to PATH: export PATH=\"{s}:$PATH\"\n", .{zig_path});
}

// Print parse_error nodes from AST when the reporter doesn't have them.
// Defense-in-depth: lenient parser may create parse_error AST nodes without
// adding to the reporter (e.g. extractProcBody returns error.ParseError
// without calling addError). This ensures those errors are still surfaced.
fn printAstParseErrors(source_file: *const ast.Program, writer: anytype) !void {
    for (source_file.items) |*item| {
        if (item.* == .parse_error) {
            const pe = item.parse_error;
            try writer.print("error[{s}]: {s}\n", .{ @tagName(pe.error_code), pe.message });
            try writer.print("  --> {s}:{}:{}\n", .{ pe.location.file, pe.location.line, pe.location.column });
            if (pe.hint) |hint| {
                try writer.print("  hint: {s}\n", .{hint});
            }
            try writer.writeAll("\n");
        }
    }
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
            without_ext[pos + 1 ..]
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
    const subpath = import_path[slash_pos + 1 ..]; // e.g., "io/file"

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

    log.debug("AUTO-IMPORT: Queueing parent '{s}' (namespace: {s})\n", .{ parent_path_owned, parent_local_name });

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
/// Only queues the index if index.kz actually exists AND is not the entry file itself.
fn queueIndexImport(
    allocator: std.mem.Allocator,
    work_queue: anytype,
    resolver: *ModuleResolver,
    import_decl: ast.ImportDecl,
    base_file: []const u8,
    entry_file: []const u8,
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

    // CRITICAL: Don't queue if the resolved file is the entry file itself!
    // This prevents the main file from being imported as a module when it
    // imports something from its own namespace (e.g., $orisha/router from src/index.kz)
    if (std.mem.eql(u8, resolved.file_path.?, entry_file)) {
        log.debug("AUTO-IMPORT: Skipping index '{s}' (same as entry file)\n", .{resolved.file_path.?});
        return;
    }

    // Namespace is just the alias name (e.g., "std")
    const alias_name = alias[1..]; // Remove $
    const index_path_owned = try allocator.dupe(u8, index_path);
    const index_local_name = try allocator.dupe(u8, alias_name);

    log.debug("AUTO-IMPORT: Queueing index '{s}' (namespace: {s})\n", .{ index_path_owned, index_local_name });

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

    log.debug("processImport: has_file={}, has_dir={}\n", .{ has_file, has_dir });

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
                    log.debug("SUBMODULE: Skipping entry file '{s}' (already main_module)\n", .{file_path});
                    continue;
                }

                // Skip index.kz - it represents the directory itself, not a submodule
                // The directory's source_file is populated from index.kz separately
                if (std.mem.eql(u8, std.fs.path.basename(file_path), "index.kz")) {
                    log.debug("SUBMODULE: Skipping index.kz '{s}' (loaded as directory source)\n", .{file_path});
                    continue;
                }

                const file = try std.fs.cwd().openFile(file_path, .{});
                defer file.close();

                const source = try file.readToEndAlloc(parse_alloc, 1024 * 1024);
                var parser = try Parser.init(parse_alloc, source, file_path, &[_][]const u8{}, null);
                parser.fail_fast = false; // Don't validate event refs during import - allows transitive imports with circular deps
                defer parser.deinit();

                const parse_result = try parser.parse();

                // Abort on parse errors in imported files
                if (parser.reporter.hasErrors() or parse_result.source_file.hasParseErrors()) {
                    const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
                    try parser.reporter.printErrors(stderr_writer);
                    if (!parser.reporter.hasErrors()) {
                        try printAstParseErrors(&parse_result.source_file, stderr_writer);
                    }
                    std.process.exit(1);
                }

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
            parser.fail_fast = false; // Don't validate event refs during import - allows transitive imports with circular deps
            defer parser.deinit();

            const parse_result = try parser.parse();

            // Abort on parse errors in imported files
            if (parser.reporter.hasErrors() or parse_result.source_file.hasParseErrors()) {
                const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
                try parser.reporter.printErrors(stderr_writer);
                if (!parser.reporter.hasErrors()) {
                    try printAstParseErrors(&parse_result.source_file, stderr_writer);
                }
                std.process.exit(1);
            }

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
        log.err("\n", .{});
        log.err("error[KORU200]: Ambiguous module structure\n", .{});
        log.err("  --> {s}\n", .{import_decl.path});
        log.err("  |\n", .{});
        log.err("  | Found both '{s}.kz' and '{s}/' directory\n", .{ module_name, module_name });
        log.err("  | \n", .{});
        log.err("  | Modules must be self-contained. Choose one:\n", .{});
        log.err("  |   - Single file: {s}.kz\n", .{module_name});
        log.err("  |   - Directory:   {s}/index.kz (with submodules)\n", .{module_name});
        log.err("  |\n", .{});
        log.err("  = help: Delete or rename one of them\n\n", .{});
        return error.ModuleNotFound; // TODO: Add proper AmbiguousModule error
    } else if (has_dir) {
        // ONLY directory
        log.debug("  Importing directory only: {s}\n", .{import_decl.path});

        const submodules = try loadSubmodules(allocator, parse_allocator, resolver, resolved.dir_path.?, entry_file);

        // FIX: Load index.kz content for the directory's source_file
        // Previously this was empty, causing flow arguments (like Source blocks) to be lost
        const index_path = try std.fs.path.join(allocator, &.{ resolved.dir_path.?, "index.kz" });
        defer allocator.free(index_path);

        // Check if index.kz exists and load it
        const index_file = std.fs.cwd().openFile(index_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                // No index.kz - use empty source_file (original behavior)
                log.debug("  No index.kz found in directory\n", .{});
                return ImportedModule{
                    .logical_name = module_name,
                    .canonical_path = try allocator.dupe(u8, resolved.dir_path.?),
                    .public_events = &.{},
                    .source_file = .{ .items = &.{}, .module_annotations = &.{}, .main_module_name = try parse_allocator.dupe(u8, module_name), .allocator = parse_allocator },
                    .is_directory = true,
                    .submodules = submodules,
                };
            }
            return err;
        };
        index_file.close();

        // index.kz exists - parse it and use its content
        log.debug("  Loading index.kz from directory: {s}\n", .{index_path});
        const index_data = try loadFile(allocator, parse_allocator, index_path);

        return ImportedModule{
            .logical_name = module_name,
            .canonical_path = try allocator.dupe(u8, resolved.dir_path.?),
            .public_events = index_data.public_events,
            .source_file = index_data.source_file,
            .is_directory = true,
            .submodules = submodules,
        };
    } else {
        // ONLY file
        log.debug("  Importing file only: {s}\n", .{import_decl.path});

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
        const after_name = json_text[name_start + 6 ..]; // Skip "name"
        if (std.mem.indexOf(u8, after_name, "\"")) |open_quote| {
            const value_start = after_name[open_quote + 1 ..];
            if (std.mem.indexOf(u8, value_start, "\"")) |close_quote| {
                name = try allocator.dupe(u8, value_start[0..close_quote]);
            }
        }
    }

    // Extract description
    if (std.mem.indexOf(u8, json_text, "\"description\"")) |desc_start| {
        const after_desc = json_text[desc_start + 13 ..]; // Skip "description"
        if (std.mem.indexOf(u8, after_desc, "\"")) |open_quote| {
            const value_start = after_desc[open_quote + 1 ..];
            if (std.mem.indexOf(u8, value_start, "\"")) |close_quote| {
                description = try allocator.dupe(u8, value_start[0..close_quote]);
            }
        }
    }

    // Extract type
    if (std.mem.indexOf(u8, json_text, "\"type\"")) |type_start| {
        const after_type = json_text[type_start + 6 ..]; // Skip "type"
        if (std.mem.indexOf(u8, after_type, "\"")) |open_quote| {
            const value_start = after_type[open_quote + 1 ..];
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

/// Collect all compiler.flag.declare invocations from AST
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
            // Check if this is compiler.flag.declare
            if (flow.invocation.path.segments.len == 2 and
                std.mem.eql(u8, flow.invocation.path.segments[0], "flag") and
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
    description: []const u8,

    fn deinit(self: *ShellCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
        if (self.description.len > 0) {
            allocator.free(self.description);
        }
    }
};

const ZigCommand = struct {
    name: []const u8,
    source: []const u8, // Zig source code with execute() function

    fn deinit(self: *ZigCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
    }
};

const KoruCommand = struct {
    name: []const u8,
    description: []const u8,
    flow: *const ast.Flow, // The flow continuation (| execute ctx |> ...)

    fn deinit(self: *KoruCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description.len > 0) {
            allocator.free(self.description);
        }
        // flow is part of AST, not separately allocated
    }
};

/// Emit a Koru AST Node as Zig code for command execution
/// This is a simplified emitter for build:command flows (MVP)
fn emitNodeAsZig(allocator: std.mem.Allocator, zig_source: *std.ArrayList(u8), node: ast.Node, indent: []const u8) !void {
    switch (node) {
        .invocation => |inv| {
            // Check for std.io:println - emit as log.debug
            const is_std_io = inv.path.module_qualifier != null and
                std.mem.eql(u8, inv.path.module_qualifier.?, "std.io");
            const is_println = inv.path.segments.len == 1 and
                std.mem.eql(u8, inv.path.segments[0], "println");

            if (is_std_io and is_println) {
                try zig_source.appendSlice(allocator, indent);
                try zig_source.appendSlice(allocator, "log.debug(");

                // Get the message argument
                if (inv.args.len > 0) {
                    const msg = inv.args[0].value;
                    // Check if it's already a string literal (starts with ")
                    if (msg.len > 0 and msg[0] == '"') {
                        try zig_source.appendSlice(allocator, msg);
                    } else {
                        // Wrap in quotes
                        try zig_source.append(allocator, '"');
                        try zig_source.appendSlice(allocator, msg);
                        try zig_source.append(allocator, '"');
                    }
                } else {
                    try zig_source.appendSlice(allocator, "\"\"");
                }

                try zig_source.appendSlice(allocator, " ++ \"\\n\", .{});\n");
                return;
            }

            // Unknown invocation - emit as comment with debug info
            try zig_source.appendSlice(allocator, indent);
            try zig_source.appendSlice(allocator, "// TODO: emit invocation ");
            if (inv.path.module_qualifier) |mq| {
                try zig_source.appendSlice(allocator, mq);
                try zig_source.append(allocator, ':');
            }
            for (inv.path.segments, 0..) |seg, i| {
                if (i > 0) try zig_source.append(allocator, '.');
                try zig_source.appendSlice(allocator, seg);
            }
            try zig_source.append(allocator, '\n');
        },
        .branch_constructor => |bc| {
            try zig_source.appendSlice(allocator, indent);
            try zig_source.appendSlice(allocator, "// branch constructor: ");
            try zig_source.appendSlice(allocator, bc.branch_name);
            try zig_source.append(allocator, '\n');
        },
        .terminal => {
            // Do nothing - flow terminates
        },
        else => {
            try zig_source.appendSlice(allocator, indent);
            try zig_source.appendSlice(allocator, "// TODO: emit node type\n");
        },
    }
}

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
                    // Extract name, source, and description parameters
                    var name: ?[]const u8 = null;
                    var script: ?[]const u8 = null;
                    var description: ?[]const u8 = null;

                    for (flow.invocation.args) |arg| {
                        if (std.mem.eql(u8, arg.name, "name")) {
                            // Strip quotes from name value
                            const raw_name = arg.value;
                            const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                                raw_name[1 .. raw_name.len - 1]
                            else
                                raw_name;
                            name = try allocator.dupe(u8, trimmed);
                        } else if (std.mem.eql(u8, arg.name, "source")) {
                            script = try allocator.dupe(u8, arg.value);
                        } else if (std.mem.eql(u8, arg.name, "description")) {
                            // Strip quotes from description value
                            const raw_desc = arg.value;
                            const trimmed = if (raw_desc.len >= 2 and raw_desc[0] == '"' and raw_desc[raw_desc.len - 1] == '"')
                                raw_desc[1 .. raw_desc.len - 1]
                            else
                                raw_desc;
                            description = try allocator.dupe(u8, trimmed);
                        }
                    }

                    if (name != null and script != null) {
                        try commands.append(allocator, ShellCommand{
                            .name = name.?,
                            .script = script.?,
                            .description = description orelse "",
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
                            var description: ?[]const u8 = null;

                            for (flow.invocation.args) |arg| {
                                if (std.mem.eql(u8, arg.name, "name")) {
                                    // Strip quotes from name value
                                    const raw_name = arg.value;
                                    const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                                        raw_name[1 .. raw_name.len - 1]
                                    else
                                        raw_name;
                                    name = try allocator.dupe(u8, trimmed);
                                } else if (std.mem.eql(u8, arg.name, "source")) {
                                    script = try allocator.dupe(u8, arg.value);
                                } else if (std.mem.eql(u8, arg.name, "description")) {
                                    // Strip quotes from description value
                                    const raw_desc = arg.value;
                                    const trimmed = if (raw_desc.len >= 2 and raw_desc[0] == '"' and raw_desc[raw_desc.len - 1] == '"')
                                        raw_desc[1 .. raw_desc.len - 1]
                                    else
                                        raw_desc;
                                    description = try allocator.dupe(u8, trimmed);
                                }
                            }

                            if (name != null and script != null) {
                                try commands.append(allocator, ShellCommand{
                                    .name = name.?,
                                    .script = script.?,
                                    .description = description orelse "",
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
                            const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                                raw_name[1 .. raw_name.len - 1]
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
                                    const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                                        raw_name[1 .. raw_name.len - 1]
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

/// Collect all build:command invocations (native Koru commands) from AST
fn collectKoruCommands(allocator: std.mem.Allocator, program: *const ast.Program) ![]KoruCommand {
    var commands = try std.ArrayList(KoruCommand).initCapacity(allocator, 4);
    errdefer {
        for (commands.items) |*cmd| {
            cmd.deinit(allocator);
        }
        commands.deinit(allocator);
    }

    // Walk top-level items (use index to get stable pointer)
    for (program.items, 0..) |item, item_idx| {
        if (item == .flow) {
            // Get pointer to the actual item in the slice, not a copy
            const flow = &program.items[item_idx].flow;
            // Check if this is std.build:command (not command.sh or command.zig)
            if (flow.invocation.path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "std.build") and
                    flow.invocation.path.segments.len == 1 and
                    std.mem.eql(u8, flow.invocation.path.segments[0], "command"))
                {
                    // Extract name and description parameters
                    var name: ?[]const u8 = null;
                    var description: ?[]const u8 = null;

                    for (flow.invocation.args) |arg| {
                        if (std.mem.eql(u8, arg.name, "name")) {
                            const raw = arg.value;
                            const trimmed = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                                raw[1 .. raw.len - 1]
                            else
                                raw;
                            name = try allocator.dupe(u8, trimmed);
                        } else if (std.mem.eql(u8, arg.name, "description")) {
                            const raw = arg.value;
                            const trimmed = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                                raw[1 .. raw.len - 1]
                            else
                                raw;
                            description = try allocator.dupe(u8, trimmed);
                        }
                    }

                    // Must have name and at least one continuation (the execute branch)
                    if (name != null and flow.continuations.len > 0) {
                        try commands.append(allocator, KoruCommand{
                            .name = name.?,
                            .description = description orelse "",
                            .flow = flow,
                        });
                    }
                }
            }
        } else if (item == .module_decl) {
            // Also check imported modules - get stable pointer via index
            const module = &program.items[item_idx].module_decl;
            for (module.items, 0..) |mod_item, mod_item_idx| {
                if (mod_item == .flow) {
                    const flow = &module.items[mod_item_idx].flow;
                    if (flow.invocation.path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, "std.build") and
                            flow.invocation.path.segments.len == 1 and
                            std.mem.eql(u8, flow.invocation.path.segments[0], "command"))
                        {
                            var name: ?[]const u8 = null;
                            var description: ?[]const u8 = null;

                            for (flow.invocation.args) |arg| {
                                if (std.mem.eql(u8, arg.name, "name")) {
                                    const raw = arg.value;
                                    const trimmed = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                                        raw[1 .. raw.len - 1]
                                    else
                                        raw;
                                    name = try allocator.dupe(u8, trimmed);
                                } else if (std.mem.eql(u8, arg.name, "description")) {
                                    const raw = arg.value;
                                    const trimmed = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                                        raw[1 .. raw.len - 1]
                                    else
                                        raw;
                                    description = try allocator.dupe(u8, trimmed);
                                }
                            }

                            if (name != null and flow.continuations.len > 0) {
                                try commands.append(allocator, KoruCommand{
                                    .name = name.?,
                                    .description = description orelse "",
                                    .flow = flow,
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
    module: []const u8, // Which module defined this (e.g., "main", "std.build")
    is_default: bool, // Has ~[default] annotation

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
    has_user_defined: bool, // true if ANY non-default step was found
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

    var has_user_defined = false; // Track if we find any non-default steps

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
                            const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                                raw_name[1 .. raw_name.len - 1]
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
                            has_user_defined = true; // Found a user-defined step
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
                                    const trimmed = if (raw_name.len >= 2 and raw_name[0] == '"' and raw_name[raw_name.len - 1] == '"')
                                        raw_name[1 .. raw_name.len - 1]
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
                                    has_user_defined = true; // Found a user-defined step
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

    log.debug("\n📦 Collecting build steps...\n", .{});

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
                log.debug("\n❌ Compilation Error: Multiple default implementations for '{s}'\n", .{name});
                for (defaults.items) |d| {
                    log.debug("  → {s}:step (line ?) [default]\n", .{d.module});
                }
                log.debug("\nOnly one default implementation per name is allowed.\n", .{});
                log.debug("This is a standard library bug.\n", .{});
                return error.MultipleDefaults;
            }

            // Error case: Multiple non-defaults
            if (non_defaults.items.len > 1) {
                log.debug("\n❌ Compilation Error: Ambiguous step definition for '{s}'\n", .{name});
                for (non_defaults.items) |nd| {
                    log.debug("  → {s}:step (line ?)\n", .{nd.module});
                }
                log.debug("\nMultiple non-default implementations found.\n", .{});
                log.debug("Remove duplicates or mark one as default.\n", .{});
                return error.AmbiguousDefinition;
            }

            // Valid case: 1 default + 1 non-default = override
            if (defaults.items.len == 1 and non_defaults.items.len == 1) {
                log.debug("  ✓ {s}: {s} (default) overridden by {s}\n", .{ name, defaults.items[0].module, non_defaults.items[0].module });
                break :blk non_defaults.items[0];
            }

            // Valid case: Only non-default
            if (non_defaults.items.len == 1) {
                log.debug("  ✓ {s}: {s}\n", .{ name, non_defaults.items[0].module });
                break :blk non_defaults.items[0];
            }

            // Valid case: Only default
            if (defaults.items.len == 1) {
                log.debug("  ✓ {s}: {s} (default)\n", .{ name, defaults.items[0].module });
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
                log.debug("Error: Step '{s}' depends on unknown step '{s}'\n", .{ step.name, dep_name });
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
        log.debug("Error: Circular dependency detected in build steps!\n", .{});
        log.debug("Processed {d} of {d} steps.\n", .{ result.items.len, n });

        // Find which steps are part of the cycle
        log.debug("Steps involved in cycle:\n", .{});
        for (in_degree, 0..) |degree, i| {
            if (degree > 0) {
                log.debug("  - {s} (waiting on {d} dependencies)\n", .{ steps[i].name, degree });
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

    log.debug("\n🔨 Executing {d} build step(s)...\n", .{needed.count()});

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
        log.debug("\n📦 Step: {s}\n", .{step.name});
        if (step.dependencies.len > 0) {
            log.debug("  Dependencies: ", .{});
            for (step.dependencies, 0..) |dep, i| {
                if (i > 0) log.debug(", ", .{});
                log.debug("{s}", .{dep});
            }
            log.debug("\n", .{});
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
                    log.debug("✗ Step '{s}' failed with exit code {d}\n", .{ step.name, code });
                    return error.BuildStepFailed;
                }
                log.debug("✓ Step '{s}' completed successfully\n", .{step.name});
            },
            else => {
                log.debug("✗ Step '{s}' terminated abnormally\n", .{step.name});
                return error.BuildStepFailed;
            },
        }
    }

    log.debug("\n✅ All build steps completed successfully!\n\n", .{});
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
                    log.debug("  Registered keyword '{s}' -> '{s}'\n", .{ keyword_name, canonical_path });
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
        // impl flows are now .flow items with impl_of set — handled by the .flow case above
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
                break; // Only one implicit expr
            }
        }
    }

    // Also set expression_value for explicitly named Expression args
    const mutable_args2 = @constCast(invocation.args);
    for (mutable_args2) |*arg| {
        if (arg.expression_value != null) continue; // Already set

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
                                std.mem.eql(u8, event_decl.path.segments[0], target_event))
                            {
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
    // Only resolve single-segment paths
    if (path.segments.len != 1) return;

    // Check if path has an explicit user-provided qualifier vs canonicalization-assigned one
    // After canonicalization, unqualified paths get main_module as their qualifier
    // Paths like ~lib_a:process have a different qualifier (set by parser, not canonicalization)
    if (path.module_qualifier) |qualifier| {
        // If qualifier is NOT the main module, user explicitly chose a module - skip keyword resolution
        // This prevents ~lib_a:process from triggering keyword collision when 'process' is ambiguous
        if (!std.mem.eql(u8, qualifier, main_module)) {
            return;
        }
    }

    const potential_keyword = path.segments[0];

    const resolve_result = registry.resolveKeyword(potential_keyword) catch |err| switch (err) {
        error.KeywordCollision => {
            const collision_info = registry.getCollisionInfo(potential_keyword).?;
            log.err("ERROR: Ambiguous keyword '{s}' - defined in:\n", .{potential_keyword});
            for (collision_info) |info| {
                log.err("  - {s} (from {s})\n", .{ info.canonical_path, info.module_path });
            }
            return error.AmbiguousKeyword;
        },
    };

    if (resolve_result) |canonical| {
        // Parse canonical path "module:event" to extract module_qualifier
        if (std.mem.indexOf(u8, canonical, ":")) |colon_pos| {
            path.module_qualifier = try allocator.dupe(u8, canonical[0..colon_pos]);
            log.debug("  Resolved keyword '{s}' -> module '{s}'\n", .{ potential_keyword, path.module_qualifier.? });
        }
    }
}

fn populateInvocationSourceModules(
    items: []ast.Item,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    try populateInvocationSourceInItems(items, allocator, main_module);
}

fn populateInvocationSourceInItems(
    items: []ast.Item,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                try populateInvocationSourceInFlow(flow, allocator, flow.module);
            },
            .proc_decl => {},
            .event_tap => |*tap| {
                for (tap.continuations) |*cont| {
                    try populateInvocationSourceInContinuation(@constCast(cont), allocator, tap.module);
                }
            },
            .label_decl => |*label| {
                for (label.continuations) |*cont| {
                    try populateInvocationSourceInContinuation(@constCast(cont), allocator, module_name);
                }
            },
            // impl flows are now .flow items — handled by the .flow case in the caller
            .module_decl => |*module| {
                try populateInvocationSourceInItems(@constCast(module.items), allocator, module.logical_name);
            },
            else => {},
        }
    }
}

fn populateInvocationSourceInFlow(
    flow: *ast.Flow,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    try setInvocationSourceModule(&flow.invocation, allocator, module_name);
    for (flow.continuations) |*cont| {
        try populateInvocationSourceInContinuation(@constCast(cont), allocator, module_name);
    }
}

fn populateInvocationSourceInContinuation(
    cont: *ast.Continuation,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) std.mem.Allocator.Error!void {
    if (cont.node) |*node| {
        try populateInvocationSourceInNode(@constCast(node), allocator, module_name);
    }
    for (cont.continuations) |*nested| {
        try populateInvocationSourceInContinuation(@constCast(nested), allocator, module_name);
    }
}

fn populateInvocationSourceInNode(
    node: *ast.Node,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) std.mem.Allocator.Error!void {
    switch (node.*) {
        .invocation => |*inv| {
            try setInvocationSourceModule(inv, allocator, module_name);
        },
        .label_with_invocation => |*lwi| {
            try setInvocationSourceModule(&lwi.invocation, allocator, module_name);
        },
        .conditional_block => |*cb| {
            for (cb.nodes) |*child| {
                try populateInvocationSourceInNode(@constCast(child), allocator, module_name);
            }
        },
        .foreach => |*fe| {
            for (fe.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        .conditional => |*cond| {
            for (cond.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        .capture => |*cap| {
            for (cap.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        .switch_result => |*sr| {
            for (sr.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        else => {},
    }
}

fn setInvocationSourceModule(
    invocation: *ast.Invocation,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    if (invocation.source_module.len == 0) {
        invocation.source_module = try allocator.dupe(u8, module_name);
    }
}

fn enforceInvocationVisibility(
    items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    try enforceInvocationVisibilityInItems(items, items, reporter, allocator, main_module);
}

fn enforceInvocationVisibilityInItems(
    items: []const ast.Item,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    for (items) |item| {
        switch (item) {
            .flow => |flow| {
                try enforceInvocationVisibilityInFlow(&flow, all_items, reporter, allocator, flow.module);
            },
            .proc_decl => {},
            .event_tap => |tap| {
                for (tap.continuations) |cont| {
                    try enforceInvocationVisibilityInContinuation(&cont, all_items, reporter, allocator, tap.module);
                }
            },
            .label_decl => |label| {
                for (label.continuations) |cont| {
                    try enforceInvocationVisibilityInContinuation(&cont, all_items, reporter, allocator, module_name);
                }
            },
            // impl flows are now .flow items — handled by the .flow case in the caller
            .module_decl => |module| {
                try enforceInvocationVisibilityInItems(module.items, all_items, reporter, allocator, module.logical_name);
            },
            else => {},
        }
    }
}

fn enforceInvocationVisibilityInFlow(
    flow: *const ast.Flow,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    try checkInvocationVisibility(&flow.invocation, all_items, reporter, allocator, module_name, flow.location);
    for (flow.continuations) |cont| {
        try enforceInvocationVisibilityInContinuation(&cont, all_items, reporter, allocator, module_name);
    }
}

fn enforceInvocationVisibilityInContinuation(
    cont: *const ast.Continuation,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) std.mem.Allocator.Error!void {
    if (cont.node) |node| {
        try enforceInvocationVisibilityInNode(&node, all_items, reporter, allocator, module_name, cont.location);
    }
    for (cont.continuations) |nested| {
        try enforceInvocationVisibilityInContinuation(&nested, all_items, reporter, allocator, module_name);
    }
}

fn enforceInvocationVisibilityInNode(
    node: *const ast.Node,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
    location: errors.SourceLocation,
) std.mem.Allocator.Error!void {
    switch (node.*) {
        .invocation => |*inv| {
            try checkInvocationVisibility(inv, all_items, reporter, allocator, module_name, location);
        },
        .label_with_invocation => |*lwi| {
            try checkInvocationVisibility(&lwi.invocation, all_items, reporter, allocator, module_name, location);
        },
        .conditional_block => |cb| {
            for (cb.nodes) |node_child| {
                try enforceInvocationVisibilityInNode(&node_child, all_items, reporter, allocator, module_name, location);
            }
        },
        .foreach => |fe| {
            for (fe.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        .conditional => |cond| {
            for (cond.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        .capture => |cap| {
            for (cap.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        .switch_result => |sr| {
            for (sr.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        else => {},
    }
}

fn checkInvocationVisibility(
    invocation: *const ast.Invocation,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
    location: errors.SourceLocation,
) !void {
    const event_decl = emitter_helpers.findEventDeclByPath(all_items, &invocation.path) orelse return;
    const source_module = if (invocation.source_module.len > 0)
        invocation.source_module
    else
        module_name;

    if (std.mem.eql(u8, source_module, event_decl.module) or event_decl.is_public) {
        return;
    }

    // Build path display string: "module:segment" (just first segment for simplicity)
    const segment = if (invocation.path.segments.len > 0) invocation.path.segments[0] else "unknown";
    const event_display = if (invocation.path.module_qualifier) |mq|
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ mq, segment })
    else
        try std.fmt.allocPrint(allocator, "{s}", .{segment});
    defer allocator.free(event_display);

    try reporter.addErrorWithHint(
        .KORU044,
        location.line,
        location.column,
        "cannot access private event '{s}' from module '{s}'",
        .{ event_display, source_module },
        "mark the event as public with ~pub event",
        .{},
    );
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            log.debug("Memory leak detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Arena allocator for parse phase - all parsed data (AST, strings, etc.)
    // gets freed in one shot after compilation completes
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();

    // Arena allocator for compilation phase - purity checking,
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
    var ccp_mode = false; // CCP daemon mode for Studio integration
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
                    log.debug("Warning: Could not read {s}: {}\n", .{ compiler_kz_path, err });
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
                    try printStdout(allocator, "  --{s:<15} {s}\n", .{ flag.name, flag.description });
                }
            }

            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try printStdout(allocator, "koruc {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--check")) {
            check_only = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--ccp")) {
            ccp_mode = true;
            try compiler_config.addFlag("ccp");
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
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            try compiler_config.addFlag("verbose");
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

    // Initialize logging level from CLI flags
    log.init(compiler_config.hasFlag("verbose"), compiler_config.hasFlag("debug"));

    // CCP daemon mode - enter interactive command loop (only when no input file)
    if (ccp_mode and input_file == null) {
        try ccp.ccpMain(allocator);
        return;
    }

    // Handle built-in frontend commands that don't require compilation
    if (input_file) |maybe_cmd| {
        if (std.mem.eql(u8, maybe_cmd, "deps")) {
            // deps runs directly in frontend - no compilation needed
            try runBuiltinDeps(allocator, args);
            return;
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
    _ = try file.read(source);
    // No defer needed - parse_arena will free everything

    // Find project root by searching upwards for koru.json (before parsing, so resolver is available)
    const input_dir = std.fs.path.dirname(input) orelse ".";

    // Convert input_dir to absolute path for {{ ENTRY }} interpolation
    // This prevents path doubling when resolving $app/{{ ENTRY }} relative to project_root
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
    // Pass project_root for resolving alias paths and entry_dir for {{ ENTRY }} interpolation
    var resolver = try ModuleResolver.init(allocator, &project_config, project_root, input_dir_absolute);
    defer resolver.deinit();

    // Inject compiler bootstrap import (unless --compiler=disable or user already imported it)
    // Note: compiler.kz itself has ~[comptime] annotation, so it will be emitted to backend_output
    const inject_compiler = !compiler_config.hasFlag("compiler=disable");
    const user_already_imported_compiler = std.mem.indexOf(u8, source, "$std/compiler") != null;
    const final_source = if (inject_compiler and !user_already_imported_compiler) blk: {
        log.debug("DEBUG: Auto-injecting compiler import\n", .{});
        const import_line = "~import \"$std/compiler\"\n";
        const injected = try parse_allocator.alloc(u8, import_line.len + source.len);
        @memcpy(injected[0..import_line.len], import_line);
        @memcpy(injected[import_line.len..], source);
        break :blk injected;
    } else blk: {
        if (user_already_imported_compiler) {
            log.debug("DEBUG: User already imported compiler, skipping auto-injection\n", .{});
        }
        break :blk source;
    };

    // Parse the file
    log.debug("DEBUG: About to parse file: {s}, ast_json_mode = {}\n", .{ input, ast_json_mode });
    log.debug("DEBUG: Compiler bootstrap injection: {}\n", .{inject_compiler});
    var parser = try Parser.init(parse_allocator, final_source, input, compiler_config.flags.items, &resolver);
    parser.fail_fast = fail_fast;
    defer parser.deinit();

    log.debug("DEBUG: Parser initialized, calling parse()...\n", .{});
    const parse_result = parser.parse() catch |err| {
        if (parser.reporter.hasErrors()) {
            const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
            try parser.reporter.printErrors(stderr_writer);
            std.process.exit(1);
        }
        return err;
    };
    log.debug("DEBUG: Parse succeeded, ast_json_mode = {}\n", .{ast_json_mode});
    // DON'T defer deinit - we're going to take ownership of the items

    var source_file = parse_result.source_file;
    var user_registry = parse_result.registry;
    defer user_registry.deinit();

    // If --ast-json mode, output AST as JSON (even if there are parse errors)
    // This is crucial for IDE tooling - parse_error nodes in AST show where errors occurred
    if (ast_json_mode) {
        log.debug("DEBUG: ast_json_mode is true, serializing AST...\n", .{});
        const ast_serializer = @import("ast_serializer");
        var serializer = try ast_serializer.AstSerializer.init(compile_allocator);
        defer serializer.deinit();

        const json_output = try serializer.serializeToJson(&source_file);
        log.debug("DEBUG: JSON output length = {d}\n", .{json_output.len});
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
                    try printStdout(allocator, "        {{\"name\": \"{s}\", \"type\": \"{s}\", \"is_source\": {}}}", .{ field.name, field.type, field.is_source });
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
    // Defense-in-depth: check BOTH reporter errors AND parse_error AST nodes.
    // Lenient parser may create parse_error nodes without adding to reporter.
    if (parser.reporter.hasErrors() or source_file.hasParseErrors()) {
        const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
        try parser.reporter.printErrors(stderr_writer);
        if (!parser.reporter.hasErrors()) {
            // Reporter is empty but AST has parse_error nodes — print them
            try printAstParseErrors(&source_file, stderr_writer);
        }
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

    const koru_commands = try collectKoruCommands(parse_allocator, &source_file);
    defer {
        for (koru_commands) |*cmd| {
            cmd.deinit(parse_allocator);
        }
        parse_allocator.free(koru_commands);
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

                // Handle "help" command - list all available commands
                if (std.mem.eql(u8, potential_command, "help")) {
                    if (shell_commands.len == 0 and zig_commands.len == 0 and koru_commands.len == 0) {
                        try printStdout(allocator, "No commands defined in {s}\n", .{input});
                        std.process.exit(0);
                    }

                    try printStdout(allocator, "\nAvailable commands:\n", .{});

                    // Calculate max command name length for alignment
                    var max_name_len: usize = 0;
                    for (shell_commands) |cmd| {
                        if (cmd.name.len > max_name_len) max_name_len = cmd.name.len;
                    }
                    for (zig_commands) |cmd| {
                        if (cmd.name.len > max_name_len) max_name_len = cmd.name.len;
                    }
                    for (koru_commands) |cmd| {
                        if (cmd.name.len > max_name_len) max_name_len = cmd.name.len;
                    }

                    // Print shell commands
                    for (shell_commands) |cmd| {
                        const padding = max_name_len - cmd.name.len + 2;
                        try printStdout(allocator, "  {s}", .{cmd.name});
                        var pad_idx: usize = 0;
                        while (pad_idx < padding) : (pad_idx += 1) {
                            try printStdout(allocator, " ", .{});
                        }
                        if (cmd.description.len > 0) {
                            try printStdout(allocator, "{s}\n", .{cmd.description});
                        } else {
                            try printStdout(allocator, "(no description)\n", .{});
                        }
                    }

                    // Print zig commands
                    for (zig_commands) |cmd| {
                        const padding = max_name_len - cmd.name.len + 2;
                        try printStdout(allocator, "  {s}", .{cmd.name});
                        var pad_idx: usize = 0;
                        while (pad_idx < padding) : (pad_idx += 1) {
                            try printStdout(allocator, " ", .{});
                        }
                        try printStdout(allocator, "(zig command)\n", .{});
                    }

                    // Print koru commands
                    for (koru_commands) |cmd| {
                        const padding = max_name_len - cmd.name.len + 2;
                        try printStdout(allocator, "  {s}", .{cmd.name});
                        var pad_idx: usize = 0;
                        while (pad_idx < padding) : (pad_idx += 1) {
                            try printStdout(allocator, " ", .{});
                        }
                        if (cmd.description.len > 0) {
                            try printStdout(allocator, "{s}\n", .{cmd.description});
                        } else {
                            try printStdout(allocator, "(koru command)\n", .{});
                        }
                    }

                    try printStdout(allocator, "\nUsage: koruc {s} <command>\n", .{input});
                    std.process.exit(0);
                }

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
                            try exec_argv.append(allocator, "sh"); // $0 for the script
                            for (args[arg_idx + 2 ..]) |extra_arg| {
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
                        log.debug("🔨 Executing Zig command: {s}\n", .{cmd.name});

                        // TODO: For MVP, we'll implement a simple approach:
                        // 1. Generate temp .zig file with command source
                        // 2. Serialize AST to temp file
                        // 3. Use zig run to compile and execute
                        // 4. Pass AST path + argv via command line

                        // For now, just print that we found it
                        log.debug("⚠️  Zig command execution not yet implemented\n", .{});
                        log.debug("Command '{s}' found but needs compilation support\n", .{cmd.name});
                        std.process.exit(1);
                    }
                }

                // If no zig command matched, check for Koru commands
                for (koru_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.name, potential_command)) {
                        // Found matching Koru command! Emit and execute it
                        log.debug("🌿 Executing Koru command: {s}\n", .{cmd.name});

                        // Find the execute continuation
                        var execute_cont: ?*const ast.Continuation = null;
                        for (cmd.flow.continuations) |*cont| {
                            if (std.mem.eql(u8, cont.branch, "execute")) {
                                execute_cont = cont;
                                break;
                            }
                        }

                        if (execute_cont == null) {
                            log.debug("Error: No 'execute' branch found in command\n", .{});
                            std.process.exit(1);
                        }

                        // For MVP: emit a simple Zig file with the command body
                        // The continuation.node contains the flow body
                        const tmp_path = "/tmp/koru_cmd.zig";

                        // Create the Zig source
                        var zig_source = try std.ArrayList(u8).initCapacity(allocator, 1024);
                        defer zig_source.deinit(allocator);

                        // Write header
                        try zig_source.appendSlice(allocator, "const std = @import(\"std\");\n\n");
                        try zig_source.appendSlice(allocator, "pub fn main() void {\n");

                        // Emit the continuation body
                        const cont = execute_cont.?;
                        if (cont.node) |node| {
                            try emitNodeAsZig(allocator, &zig_source, node, "    ");
                        } else {
                            // Empty body - just emit a comment
                            try zig_source.appendSlice(allocator, "    // (empty command body)\n");
                        }

                        try zig_source.appendSlice(allocator, "}\n");

                        // Write to temp file
                        const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch |err| {
                            log.debug("Error creating temp file: {}\n", .{err});
                            std.process.exit(1);
                        };
                        defer tmp_file.close();
                        tmp_file.writeAll(zig_source.items) catch |err| {
                            log.debug("Error writing temp file: {}\n", .{err});
                            std.process.exit(1);
                        };

                        // Execute with zig run
                        var exec_argv = [_][]const u8{ "zig", "run", tmp_path };
                        const result = std.process.Child.run(.{
                            .allocator = allocator,
                            .argv = &exec_argv,
                        }) catch |err| {
                            log.debug("Error running command: {}\n", .{err});
                            std.process.exit(1);
                        };
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

                        // Exit with command's exit code
                        switch (result.term) {
                            .Exited => |code| std.process.exit(code),
                            else => std.process.exit(1),
                        }
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
            log.debug("DEDUPLICATION: Skipping duplicate import of '{s}' (canonical: {s})\n", .{ module.logical_name, module.canonical_path });
            // Clean up the duplicate module
            var mut_module = module;
            mut_module.deinit(allocator);
            continue;
        }

        // Track this import
        const path_copy = try allocator.dupe(u8, module.canonical_path);
        try imported_paths.put(path_copy, {});
        log.debug("IMPORT: Added '{s}' (canonical: {s})\n", .{ module.logical_name, module.canonical_path });

        // Queue parent imports for aliased paths (e.g., $std/io/file -> also import $std/io.kz)
        // Only if the parent file actually exists
        try queueParentImports(allocator, &work_queue, &resolver, work_item.import_decl, work_item.base_file);

        // Queue index.kz import for aliased paths (e.g., $std/io -> also import $std/index.kz)
        // This makes root-level stdlib utilities available when importing any submodule
        try queueIndexImport(allocator, &work_queue, &resolver, work_item.import_decl, work_item.base_file, entry_file_absolute);

        // Scan this module's AST for transitive imports
        for (module.source_file.items) |item| {
            if (item == .import_decl) {
                log.debug("TRANSITIVE: Found import in '{s}' -> '{s}'\n", .{ module.logical_name, item.import_decl.path });
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
                    log.debug("TRANSITIVE: Found import in submodule '{s}.{s}' -> '{s}'\n", .{ module.logical_name, submod.logical_name, item.import_decl.path });
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

    log.debug("AST combined with {} imported modules\n", .{imported_modules.items.len});

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
    // Must happen AFTER canonicalization so we have canonical paths for registration
    log.debug("Building keyword registry...\n", .{});
    var kw_registry = keyword_registry.KeywordRegistry.init(parse_allocator);
    defer kw_registry.deinit();
    try buildKeywordRegistry(source_file.items, &kw_registry, parse_allocator);
    if (kw_registry.count() > 0) {
        log.debug("Registered {} keywords, resolving in AST...\n", .{kw_registry.count()});
        try resolveKeywordsInAST(@constCast(source_file.items), &kw_registry, parse_allocator, source_file.main_module_name);
    }

    // Inject meta-events (koru:start, koru:end) into AST
    // These are synthetic events that mark program lifecycle boundaries
    // Taps can observe them (e.g., profiler writes header/footer)
    // Must happen AFTER canonicalization so paths have module_qualifier
    // Must happen BEFORE tap transformation so taps can observe these flows
    const meta_events = @import("meta_events");
    try meta_events.injectMetaEvents(parse_allocator, &source_file);
    log.debug("Injected meta-events: koru:start, koru:end\n", .{});

    // Populate invocation.source_module for visibility enforcement
    try populateInvocationSourceModules(@constCast(source_file.items), parse_allocator, source_file.main_module_name);
    try enforceInvocationVisibility(source_file.items, &parser.reporter, parse_allocator, source_file.main_module_name);
    if (parser.reporter.hasErrors()) {
        const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
        try parser.reporter.printErrors(stderr_writer);
        std.process.exit(1);
    }

    // NOTE: Declaration-level transforms run in the BACKEND alongside invocation transforms.
    // They update the type registry when they run, not here in the frontend.

    // Build TypeRegistry from canonicalized AST
    // This must happen AFTER canonicalization so event names include module qualifiers
    log.debug("Building TypeRegistry from canonicalized AST...\n", .{});
    try user_registry.populateFromAST(source_file.items);
    log.debug("TypeRegistry populated with {} events\n", .{user_registry.events.count()});

    // Attach TypeRegistry to Program for transform access
    // Transforms can clone this for supplemental parsing
    source_file.type_registry = &user_registry;

    // Validate abstract events and implementations
    // This must happen AFTER canonicalization so we can match canonical paths
    log.debug("Validating abstract events and implementations...\n", .{});
    try validate_abstract_impl.AbstractImplValidator.validate(parse_allocator, source_file.items);
    log.debug("Abstract/impl validation passed\n", .{});

    // Resolve abstract/impl: rename defaults to .default when overrides exist
    const resolve_abstract_impl = @import("resolve_abstract_impl");
    try resolve_abstract_impl.resolve(&source_file, parse_allocator);
    try resolve_abstract_impl.createDefaultEventDecls(&source_file, parse_allocator);
    log.debug("Abstract/impl resolution complete\n", .{});

    // Collect Event Taps
    var tap_collector = try TapCollector.init(compile_allocator);
    defer tap_collector.deinit();
    try tap_collector.collectFromSourceFile(&source_file);

    const tap_count = tap_collector.output_taps.count() +
        tap_collector.input_taps.count() +
        tap_collector.universal_output_taps.items.len +
        tap_collector.universal_input_taps.items.len;
    if (tap_count > 0) {
        log.debug("Collected {} Event Taps\n", .{tap_count});
    }

    // NOTE: Tap transformation is done in the BACKEND by compiler.coordinate.transform_taps
    // The backend inserts taps into the AST after filtering comptime code.

    // TODO: Process imports properly - for now imports are disabled
    // The old import system violated module isolation by copying all code
    // try processImports(allocator, &source_file, input);

    // NOTE: Compiler override detection removed - the abstract/impl mechanism in
    // koru_std/compiler.kz handles this automatically via abstract events and cross-module overrides

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

    // If check-only, we're done
    if (check_only) {
        try printStdout(allocator, "✓ Shape checking passed\n", .{});
        return;
    }

    // NOTE: All compilation passes now run in the backend via koru_std/compiler.kz
    // The frontend just parses and validates, then hands off to the backend pipeline.
    const final_ast: *ast.Program = &source_file;

    // Write output file
    const output = output_file.?;
    log.debug("DEBUG: Writing output to {s}\n", .{output});

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
    log.debug("DEBUG: Generating comptime backend with {} items in source_file\n", .{source_file.items.len});
    for (source_file.items) |item| {
        if (item == .module_decl) {
            const module = item.module_decl;
            log.debug("DEBUG:   Module: {s} (has_comptime: {any})\n", .{ module.logical_name, module.annotations });
        }
    }
    const comptime_result = try generateComptimeBackendEmitted(compile_allocator, &source_file, &user_registry);
    const comptime_backend_code = comptime_result.code;
    const has_transforms = comptime_result.transform_count > 0;
    // No defer needed - compile_arena handles cleanup automatically

    // Generate the backend code (includes metacircular compiler)
    const backend_code = try generateBackendCode(compile_allocator, serialized_ast, input, final_ast, use_visitor, &compiler_config, has_transforms);
    // No defer needed - compile_arena handles cleanup automatically

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

    // Use koru_home from resolver (computed from executable path)
    const koru_lib_path = resolver.koru_home;

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
        try emit_build_zig.emitOutputBuildZig(allocator, output_build_reqs.items, build_output_path, koru_lib_path);
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
        const zig_reqs = package_collector.getZigRequirements();

        try printStdout(allocator, "✓ Found package requirements:\n", .{});
        if (npm_reqs.len > 0) try printStdout(allocator, "  - npm: {d} package(s)\n", .{npm_reqs.len});
        if (cargo_reqs.len > 0) try printStdout(allocator, "  - cargo: {d} package(s)\n", .{cargo_reqs.len});
        if (go_reqs.len > 0) try printStdout(allocator, "  - go: {d} package(s)\n", .{go_reqs.len});
        if (pip_reqs.len > 0) try printStdout(allocator, "  - pip: {d} package(s)\n", .{pip_reqs.len});
        if (zig_reqs.len > 0) try printStdout(allocator, "  - zig: {d} package(s)\n", .{zig_reqs.len});

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

        if (zig_reqs.len > 0) {
            const zon_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build.zig.zon" });
            defer allocator.free(zon_path);
            const project_name = std.fs.path.basename(output_dir);
            try emit_package_files.emitBuildZigZon(allocator, zig_reqs, zon_path, project_name);

            // Zig 0.15 requires a valid .fingerprint in build.zig.zon.
            // Run a probe build to extract the correct fingerprint from zig's error message,
            // then patch the zon file with it.
            const probe_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "zig", "build", "--build-file", "build_backend.zig" },
                .cwd = output_dir,
            });
            defer allocator.free(probe_result.stdout);
            defer allocator.free(probe_result.stderr);

            // Look for "use this value: 0x..." in stderr (Zig 0.15 fingerprint error)
            if (std.mem.indexOf(u8, probe_result.stderr, "use this value: 0x")) |idx| {
                const hex_start = idx + "use this value: ".len;
                // Find end of hex value (next non-hex char)
                var hex_end = hex_start + 2; // skip "0x"
                while (hex_end < probe_result.stderr.len and
                    (std.ascii.isHex(probe_result.stderr[hex_end]) or probe_result.stderr[hex_end] == 'x')) : (hex_end += 1)
                {}
                const fingerprint_str = probe_result.stderr[hex_start..hex_end];

                // Read the zon, replace the placeholder fingerprint, write it back
                const zon_file = try std.fs.cwd().openFile(zon_path, .{});
                const zon_content = try zon_file.readToEndAlloc(allocator, 64 * 1024);
                zon_file.close();
                defer allocator.free(zon_content);

                if (std.mem.indexOf(u8, zon_content, "0xDEAD")) |placeholder_pos| {
                    var patched = try std.ArrayList(u8).initCapacity(allocator, zon_content.len + 20);
                    defer patched.deinit(allocator);
                    const w = patched.writer(allocator);
                    try w.writeAll(zon_content[0..placeholder_pos]);
                    try w.writeAll(fingerprint_str);
                    try w.writeAll(zon_content[placeholder_pos + "0xDEAD".len ..]);

                    const zon_out = try std.fs.cwd().createFile(zon_path, .{});
                    defer zon_out.close();
                    try zon_out.writeAll(patched.items);
                }
            }

            try printStdout(allocator, "✓ Generated {s}\n", .{zon_path});
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
        // Use ChildProcess directly to allow stdin inheritance for interactive features like --inter
        var child = std.process.Child.init(backend_args_list.items, allocator);
        child.cwd = output_dir_for_build;
        child.stdin_behavior = .Inherit;  // Allow interactive stdin for --inter REPL
        child.stdout_behavior = .Inherit; // Stream output directly
        child.stderr_behavior = .Inherit; // Stream errors directly

        try child.spawn();
        const term = try child.wait();

        if (term.Exited != 0) {
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
