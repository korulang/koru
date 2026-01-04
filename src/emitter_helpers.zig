// Helper functions extracted from emitter.zig
const DEBUG = false;  // Set to true for verbose logging
// This file contains ONLY the helpers needed by visitor_emitter.zig
// The old procedural orchestrators remain in emitter.zig as reference only

const std = @import("std");
const ast = @import("ast");
const tap_registry_module = @import("tap_registry");
const type_registry_module = @import("type_registry");
const purity_helpers = @import("compiler_passes/purity_helpers");
const compiler_config = @import("compiler_config");

/// Controls which modules/taps to emit based on annotations
/// Duplicated from visitor_emitter.zig to avoid circular dependency
pub const EmitMode = enum {
    all,            // Emit everything (no filtering based on comptime/runtime)
    comptime_only,  // Emit only modules with [comptime] annotation
    runtime_only,   // Emit only modules WITHOUT [comptime] annotation (default)
};

/// Check if an item should be filtered out based on emit mode and annotations
/// Duplicated from visitor_emitter.zig to avoid circular dependency
pub fn shouldFilter(item_annotations: []const []const u8, module_annotations: []const []const u8, module_path: []const u8, mode: EmitMode) bool {
    _ = module_path; // No longer needed for compiler_bootstrap special case

    // Explicit override semantics: if item has ANY annotations, use ONLY those; otherwise inherit from module
    // This means: annotated constructs don't inherit module annotations, only unannotated ones do
    const annotations_to_check = if (item_annotations.len > 0)
        item_annotations
    else
        module_annotations;

    const has_comptime = purity_helpers.hasAnnotation(annotations_to_check, "comptime");
    const has_runtime = purity_helpers.hasAnnotation(annotations_to_check, "runtime");

    // Filter based on emit mode and phase annotations
    switch (mode) {
        .all => {
            // Emit everything (except compiler infrastructure already filtered above)
            return false;
        },
        .comptime_only => {
            // Emit if has [comptime] annotation (with or without [runtime])
            // Filter OUT modules without [comptime]
            return !has_comptime;
        },
        .runtime_only => {
            // Emit if has [runtime] OR no phase annotations (default runtime)
            // Filter OUT if ONLY [comptime] (not both, not neither)
            return has_comptime and !has_runtime;
        },
    }
}

/// Emission context - tracks state during code generation
/// Context for a labeled loop - tracks handler and result variable for label jumps
pub const LabelContext = struct {
    handler_invocation: *const ast.Invocation,
    result_var: []const u8,
};

pub const EmissionContext = struct {
    allocator: std.mem.Allocator,
    indent_level: usize = 0,
    flow_counter: usize = 0,
    in_handler: bool = false,
    input_var: ?[]const u8 = null, // "e" for handlers, null for top-level
    input_fields: ?[]const ast.Field = null,
    ast_items: ?[]const ast.Item = null, // Full AST for module resolution
    depth: usize = 0, // Recursion depth for continuation nesting
    flow_pre_label: ?[]const u8 = null, // Label to break for flow termination
    current_label: ?[]const u8 = null, // Current label for continuation-level breaks
    is_sync: bool = false, // true for synchronous inline flows (no try/!)
    tap_registry: ?*tap_registry_module.TapRegistry = null, // Event tap registry for inline emission (mutable for tracking references)
    current_source_event: ?[]const u8 = null, // Canonical name of current source event for tap matching
    current_branch: ?[]const u8 = null, // Current branch name for tap matching
    label_handler_invocation: ?*const ast.Invocation = null, // Invocation for current label's handler (for re-calling in label_jump)
    label_result_var: ?[]const u8 = null, // Result variable name for current label (for updating in label_jump)
    label_contexts: ?*std.StringHashMap(LabelContext) = null, // Map of label names to their contexts (for cross-level jumps)
    main_module_name: ?[]const u8 = null, // Main module name for qualifying unqualified events
    emit_mode: ?EmitMode = null, // Emission mode for filtering taps by phase annotations
    module_annotations: ?[]const []const u8 = null, // Module-level annotations for tap filtering
    skip_tap_inserted_steps: bool = false, // Skip steps inserted by tap transformation (for opaque modules)
    capture_counter: usize = 0, // Counter for unique capture type names (nested captures)
    for_counter: usize = 0, // Counter for unique for loop binding names (nested loops)
    result_prefix: []const u8 = "result_", // Prefix for result variable names (changes to "loop_result_" inside loops)
};

/// CodeEmitter - manages buffer and formatting
/// Ported from compiler_visitor.kz with improvements
pub const CodeEmitter = struct {
    buffer: []u8,
    pos: usize,
    indent_level: u32,
    indent_size: u32 = 4,

    pub fn init(buffer: []u8) CodeEmitter {
        return .{
            .buffer = buffer,
            .pos = 0,
            .indent_level = 0,
        };
    }

    /// Low-level write - no formatting
    pub fn write(self: *CodeEmitter, text: []const u8) !void {
        if (self.pos + text.len >= self.buffer.len) {
            return error.BufferOverflow;
        }
        @memcpy(self.buffer[self.pos .. self.pos + text.len], text);
        self.pos += text.len;
    }

    /// Write with newline
    pub fn writeLine(self: *CodeEmitter, text: []const u8) !void {
        try self.writeIndent();
        try self.write(text);
        try self.write("\n");
    }

    /// Write current indentation
    pub fn writeIndent(self: *CodeEmitter) !void {
        const spaces = self.indent_level * self.indent_size;
        var i: u32 = 0;
        while (i < spaces) : (i += 1) {
            try self.write(" ");
        }
    }

    /// Increase indentation
    pub fn indent(self: *CodeEmitter) void {
        self.indent_level += 1;
    }

    /// Decrease indentation
    pub fn dedent(self: *CodeEmitter) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    /// High-level: emit struct declaration
    pub fn emitStructStart(self: *CodeEmitter, name: []const u8, is_pub: bool) !void {
        try self.writeIndent();
        if (is_pub) {
            try self.write("pub ");
        }
        try self.write("const ");
        try self.write(name);
        try self.write(" = struct {\n");
        self.indent();
    }

    /// High-level: emit struct end
    pub fn emitStructEnd(self: *CodeEmitter) !void {
        self.dedent();
        try self.writeLine("};");
    }

    /// High-level: emit comment
    pub fn emitComment(self: *CodeEmitter, comment: []const u8) !void {
        try self.writeIndent();
        try self.write("// ");
        try self.write(comment);
        try self.write("\n");
    }

    /// High-level: emit import
    pub fn emitImport(self: *CodeEmitter, name: []const u8, path: []const u8) !void {
        try self.writeIndent();
        try self.write("const ");
        try self.write(name);
        try self.write(" = @import(\"");
        try self.write(path);
        try self.write("\");\n");
    }

    /// Get current buffer content
    pub fn getOutput(self: *CodeEmitter) []const u8 {
        return self.buffer[0..self.pos];
    }

    /// Check if a word is a Zig reserved keyword that needs escaping in field access
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

    /// Write a line of text with Zig keyword escaping for field access (.keyword -> .@"keyword")
    fn writeLineWithKeywordEscaping(self: *CodeEmitter, line: []const u8) !void {
        var pos: usize = 0;
        while (pos < line.len) {
            // Look for field access pattern: .identifier
            if (line[pos] == '.' and pos + 1 < line.len) {
                const after_dot = pos + 1;

                // Skip if already escaped (.@")
                if (after_dot < line.len and line[after_dot] == '@') {
                    try self.write(line[pos .. pos + 1]);
                    pos += 1;
                    continue;
                }

                // Check if next char starts an identifier
                if (CodeEmitter.isIdentifierStart(line[after_dot])) {
                    // Find end of identifier
                    var end = after_dot;
                    while (end < line.len and CodeEmitter.isIdentifierChar(line[end])) {
                        end += 1;
                    }

                    const identifier = line[after_dot..end];

                    // If it's a keyword, escape it
                    if (CodeEmitter.isZigKeyword(identifier)) {
                        try self.write(".@\"");
                        try self.write(identifier);
                        try self.write("\"");
                        pos = end;
                        continue;
                    }
                }
            }

            // Write character as-is
            try self.write(line[pos .. pos + 1]);
            pos += 1;
        }
    }

    /// Check if character can start an identifier
    fn isIdentifierStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    /// Check if character can be in an identifier
    fn isIdentifierChar(c: u8) bool {
        return isIdentifierStart(c) or (c >= '0' and c <= '9');
    }

    /// Emit text with additional indentation and keyword escaping added to each line
    /// Used for emitting proc bodies that need to be reindented and have Zig keywords escaped
    pub fn emitReindentedText(self: *CodeEmitter, text: []const u8, additional_indent: []const u8) !void {
        var i: usize = 0;

        while (i < text.len) {
            // Find the end of the current line
            var line_end = i;
            while (line_end < text.len and text[line_end] != '\n') {
                line_end += 1;
            }

            // Write additional indentation if the line is not empty
            if (line_end > i) {
                // Check if line has content (not just whitespace)
                var has_content = false;
                var j = i;
                while (j < line_end) : (j += 1) {
                    if (text[j] != ' ' and text[j] != '\t') {
                        has_content = true;
                        break;
                    }
                }

                if (has_content) {
                    try self.write(additional_indent);
                }

                // Write the line with keyword escaping
                const line = text[i..line_end];
                try self.writeLineWithKeywordEscaping(line);
            }

            // Write newline
            try self.write("\n");

            // Move to next line (skip the \n we just found)
            i = line_end;
            if (i < text.len and text[i] == '\n') {
                i += 1;
            }
        }
    }
};

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================
// These are extracted from emitter.zig for use by visitor_emitter.zig
// The old procedural orchestrators remain in emitter.zig as reference only

/// Helper: Check if a Zig keyword (used by writeBranchName)
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

/// Helper: Write branch name (escaped if needed)
pub fn writeBranchName(emitter: *CodeEmitter, name: []const u8) !void {
    // Check if branch name needs escaping
    const needs_escape = for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break true;
    } else false;

    if (needs_escape or isZigKeyword(name)) {
        try emitter.write("@\"");
        try emitter.write(name);
        try emitter.write("\"");
    } else {
        try emitter.write(name);
    }
}

/// Resolve a module alias to its actual module path
/// For example, "build" (from ~import "$std/build") -> "std.build"
fn resolveModuleAlias(alias: []const u8, items: []const ast.Item) ?[]const u8 {
    for (items) |item| {
        switch (item) {
            .import_decl => |import| {
                // Check if this import matches the alias
                // The local_name might be explicit, or inferred from the path
                const import_alias = if (import.local_name) |name|
                    name
                else blk: {
                    // Infer alias from path (e.g., "$std/build" -> "build")
                    if (std.mem.lastIndexOfScalar(u8, import.path, '/')) |last_slash| {
                        break :blk import.path[last_slash + 1..];
                    } else {
                        break :blk import.path;
                    }
                };

                if (std.mem.eql(u8, import_alias, alias)) {
                    // Found the import! Convert path to module path
                    // "$std/build" -> "std/build" (strip $, writeModulePath will convert / to .)
                    if (std.mem.startsWith(u8, import.path, "$")) {
                        // Strip $ and return - writeModulePath will handle / -> . conversion
                        return import.path[1..];
                    }
                    return import.path;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Write a module path with koru_ prefix for sibling module references
/// Converts "std.io" -> "koru_std.io" (only first segment gets prefix)
/// Also handles "$std/build" format by converting / to .
/// Entry module (tracked via main_module_name) becomes "main_module"
pub fn writeModulePath(emitter: *CodeEmitter, module_path: []const u8, main_module_name: ?[]const u8) !void {
    // Special case: entry module qualifier becomes "main_module"
    // This handles both legacy "main" and filename-based entry modules (e.g., "input")
    if (main_module_name) |mmn| {
        if (std.mem.eql(u8, module_path, mmn)) {
            try emitter.write("main_module");
            return;
        }
    }

    // DEPRECATED: Legacy "main" fallback for backwards compatibility
    if (std.mem.eql(u8, module_path, "main")) {
        try emitter.write("main_module");
        return;
    }

    // Handle paths with / separator (from imports like "$std/build")
    if (std.mem.indexOfScalar(u8, module_path, '/')) |_| {
        // Convert std/build -> std.build, then process
        var first = true;
        var splitter = std.mem.splitScalar(u8, module_path, '/');
        while (splitter.next()) |segment| {
            if (!first) {
                try emitter.write(".");
            } else {
                try emitter.write("koru_");
            }
            try emitter.write(segment);
            first = false;
        }
        return;
    }

    // Handle normal dotted paths (logical names like "logger" or "std.io")
    var splitter = std.mem.splitScalar(u8, module_path, '.');
    var first = true;
    while (splitter.next()) |segment| {
        if (!first) {
            try emitter.write(".");
        } else {
            // Only prefix the FIRST segment (top-level sibling module)
            try emitter.write("koru_");
        }
        try emitter.write(segment);
        first = false;
    }
}

/// Helper: Write field type with proper module path handling
pub fn writeFieldType(emitter: *CodeEmitter, field: ast.Field, main_module_name: ?[]const u8) !void {
    if (field.module_path) |module_path| {
        // Cross-module type reference: module.path:Type -> koru_module.path.Type
        try writeModulePath(emitter, module_path, main_module_name);
        try emitter.write(".");
        try emitter.write(field.type);
    } else {
        // Regular type - apply prefixes for known AST/Std types to avoid shadowing
        // We use string replacement to handle pointers (*const Program) and slices ([]Item)
        const type_name = field.type;
        
        // Allocator -> __koru_std.mem.Allocator
        const needle_alloc = "Allocator";
        if (std.mem.indexOf(u8, type_name, needle_alloc) != null) {
            // Check if it's explicitly std.mem.Allocator, ignore if so
            if (std.mem.indexOf(u8, type_name, "std.mem.Allocator") == null and 
                std.mem.indexOf(u8, type_name, "__koru_std") == null) 
            {
                 const replacement = "__koru_std.mem.Allocator";
                 var buf: [256]u8 = undefined;
                 const count = std.mem.replace(u8, type_name, needle_alloc, replacement, &buf);
                 const final_len = type_name.len + count * (replacement.len - needle_alloc.len);
                 try emitter.write(buf[0..final_len]);
                 return;
            }
        }
        
        // AST Types -> __koru_ast.Type
        const ast_types = [_][]const u8{ "Program", "Item", "Source", "Invocation", "ASTNode", "EventDecl", "ProcDecl", "Flow", "Branch", "Continuation" };
        inline for (ast_types) |ast_type| {
             if (std.mem.indexOf(u8, type_name, ast_type) != null) {
                 // Avoid double prefixing
                 if (std.mem.indexOf(u8, type_name, "ast.") == null and 
                     std.mem.indexOf(u8, type_name, "__koru_ast") == null)
                 {
                     const prefixed = "__koru_ast." ++ ast_type;
                     var buf: [256]u8 = undefined;
                     const count = std.mem.replace(u8, type_name, ast_type, prefixed, &buf);
                     const final_len = type_name.len + count * (prefixed.len - ast_type.len);
                     try emitter.write(buf[0..final_len]);
                     return;
                 }
             }
        }
        
        // Fallback
        try emitter.write(type_name);
    }
}

/// Convert canonical event name to enum tag
/// Example: "std.compiler:compiler.context.create" -> "compiler_context_create"
/// Example: "main:http.request" -> "http_request"
pub fn canonicalNameToEnumTag(emitter: *CodeEmitter, canonical_name: []const u8) !void {
    // Find the colon that separates module qualifier from event name
    const colon_pos = std.mem.indexOf(u8, canonical_name, ":");

    // Get the event name part (after the colon, or whole string if no colon)
    const event_name = if (colon_pos) |pos| canonical_name[pos + 1 ..] else canonical_name;

    // Replace dots with underscores
    for (event_name) |c| {
        if (c == '.') {
            try emitter.write("_");
        } else {
            try emitter.write(&[_]u8{c});
        }
    }
}

/// Emit a host line
pub fn emitHostLine(emitter: *CodeEmitter, content: []const u8) !void {
    try emitter.writeIndent();
    try emitter.write(content);
    try emitter.write("\n");
}

/// Emit main_module struct start
pub fn emitMainModuleStart(emitter: *CodeEmitter) !void {
    // Import CompilerEnv from root (backend.zig) so procs can check compiler flags
    try emitter.write("// Access compiler flags from backend.zig via root import\n");
    try emitter.write("const CompilerEnv = @import(\"root\").CompilerEnv;\n\n");
    try emitter.write("pub const main_module = struct {\n");
}

/// Emit main_module struct end
pub fn emitMainModuleEnd(emitter: *CodeEmitter) !void {
    try emitter.write("};\n\n");
}

/// Emit main function start
pub fn emitMainFunctionStart(emitter: *CodeEmitter) !void {
    try emitter.write("pub fn main() void {\n");
}

/// Emit main function end
pub fn emitMainFunctionEnd(emitter: *CodeEmitter) !void {
    try emitter.write("}\n");
}

/// Emit a flow call in main (e.g., "    main_module.flow0();\n")
pub fn emitFlowCallInMain(emitter: *CodeEmitter, flow_num: usize) !void {
    try emitter.write("    main_module.flow");

    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{}", .{flow_num}) catch "ERROR";
    try emitter.write(num_str);
    try emitter.write("();\n");
}

/// Emit TapRegistry placeholder struct (inside main_module)
pub fn emitTapRegistryPlaceholder(emitter: *CodeEmitter) !void {
    try emitter.write("\n    // Event Tap Registry (placeholder)\n");
    try emitter.write("    const TapRegistry = struct {\n");
    try emitter.write("        pub fn invokeInputTaps(event_name: []const u8, input: anytype) void {\n");
    try emitter.write("            // TODO: Implement tap lookup and invocation\n");
    try emitter.write("            _ = event_name;\n");
    try emitter.write("            _ = input;\n");
    try emitter.write("        }\n");
    try emitter.write("        pub fn invokeOutputTaps(event_name: []const u8, output: anytype) void {\n");
    try emitter.write("            // TODO: Implement tap lookup and invocation\n");
    try emitter.write("            _ = event_name;\n");
    try emitter.write("            _ = output;\n");
    try emitter.write("        }\n");
    try emitter.write("    };\n");
}

/// Emit taps namespace with selective enums for events/branches
/// Now includes metatypes (Transition/Profile/Audit) INSIDE the namespace
pub fn emitTapsNamespace(
    emitter: *CodeEmitter,
    tap_registry: *const tap_registry_module.TapRegistry,
    has_base_transition: bool,
    has_profiling_transition: bool,
    has_audit_transition: bool,
) !void {
    // Get the referenced events and branches from tap registry
    const events = try tap_registry.getReferencedEvents();
    defer tap_registry.allocator.free(events);
    const branches = try tap_registry.getReferencedBranches();
    defer tap_registry.allocator.free(branches);

    // Only emit if there are taps OR metatypes needed
    const has_metatypes = has_base_transition or has_profiling_transition or has_audit_transition;
    if (events.len == 0 and branches.len == 0 and !has_metatypes) {
        return;
    }

    try emitter.writeLine("// Taps namespace - compiler infrastructure for event observation");
    try emitter.writeLine("const taps = struct {");
    emitter.indent();

    // Emit EventEnum
    if (events.len > 0) {
        try emitter.writeLine("const EventEnum = enum(u32) {");
        emitter.indent();
        for (events, 0..) |event, idx| {
            try emitter.writeIndent();
            // Mangle event name for enum field (replace dots with underscores)
            var mangled_buf: [256]u8 = undefined;
            var mangled_len: usize = 0;
            for (event) |c| {
                mangled_buf[mangled_len] = if (c == '.' or c == ':') '_' else c;
                mangled_len += 1;
            }
            try emitter.write(mangled_buf[0..mangled_len]);
            try emitter.write(" = ");
            var num_buf: [32]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{idx});
            try emitter.write(num_str);
            try emitter.write(",\n");
        }
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    // Emit BranchEnum
    // Track if we have any empty branches (void events) - we'll add __void sentinel
    var has_void_branch = false;
    for (branches) |branch| {
        if (branch.len == 0) {
            has_void_branch = true;
            break;
        }
    }

    if (branches.len > 0) {
        try emitter.writeLine("const BranchEnum = enum(u32) {");
        emitter.indent();
        var idx: usize = 0;

        // If we have void branches, add sentinel first
        if (has_void_branch) {
            try emitter.writeLine("__void = 0,  // sentinel for void event completion");
            idx = 1;
        }

        for (branches) |branch| {
            // Skip empty branches (already handled as __void sentinel)
            if (branch.len == 0) continue;

            try emitter.writeIndent();
            // Escape branch name if needed (same as writeBranchName but for enum field)
            const needs_escape = for (branch) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') break true;
            } else false;

            if (needs_escape or isZigKeyword(branch)) {
                try emitter.write("@\"");
                try emitter.write(branch);
                try emitter.write("\"");
            } else {
                try emitter.write(branch);
            }
            try emitter.write(" = ");
            var num_buf: [32]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{idx});
            try emitter.write(num_str);
            try emitter.write(",\n");
            idx += 1;
        }
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    // Emit helper functions for enum-to-string conversion
    if (events.len > 0) {
        try emitter.writeLine("/// Convert EventEnum to string name");
        try emitter.writeLine("pub fn eventToString(e: EventEnum) []const u8 {");
        emitter.indent();
        try emitter.writeLine("return @tagName(e);");
        emitter.dedent();
        try emitter.writeLine("}");
        try emitter.write("\n");
    }

    if (branches.len > 0) {
        try emitter.writeLine("/// Convert BranchEnum to string name");
        try emitter.writeLine("pub fn branchToString(b: BranchEnum) []const u8 {");
        emitter.indent();
        try emitter.writeLine("return @tagName(b);");
        emitter.dedent();
        try emitter.writeLine("}");
        try emitter.write("\n");
    }

    // Emit metatypes INSIDE taps namespace (they belong to tap infrastructure)
    if (has_base_transition) {
        try emitter.writeLine("// Transition meta-type - lightweight enum-based (12 bytes)");
        try emitter.writeLine("// For high-frequency observability with minimal overhead");
        try emitter.writeLine("pub const Transition = struct {");
        emitter.indent();
        try emitter.writeLine("source: EventEnum,        // u32 enum");
        try emitter.writeLine("destination: ?EventEnum,  // u32 enum (null for terminal)");
        try emitter.writeLine("branch: BranchEnum,       // u32 enum");
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    if (has_profiling_transition) {
        try emitter.writeLine("// Profile meta-type - string-based with timing (32+ bytes)");
        try emitter.writeLine("// For performance profiling and timeline reconstruction");
        try emitter.writeLine("pub const Profile = struct {");
        emitter.indent();
        try emitter.writeLine("source: []const u8,           // interned string");
        try emitter.writeLine("destination: ?[]const u8,     // interned string (null for terminal)");
        try emitter.writeLine("branch: []const u8,           // interned string");
        try emitter.writeLine("timestamp_ns: i128,           // nanoseconds since epoch (runtime capture)");
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    if (has_audit_transition) {
        try emitter.writeLine("// Audit meta-type - full forensics (variable size)");
        try emitter.writeLine("// For compliance, debugging, and detailed analysis");
        try emitter.writeLine("pub const Audit = struct {");
        emitter.indent();
        try emitter.writeLine("source: []const u8,           // interned string");
        try emitter.writeLine("destination: ?[]const u8,     // interned string (null for terminal)");
        try emitter.writeLine("branch: []const u8,           // interned string");
        try emitter.writeLine("timestamp_ns: u64,            // when this transition occurred");
        try emitter.writeLine("payload: ?[]const u8,         // serialized continuation payload");
        try emitter.writeLine("// TODO: Add stack trace, thread ID, other forensic data");
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    emitter.dedent();
    try emitter.writeLine("};");
    try emitter.write("\n");
}

/// Emit an event enum value (mangles canonical name: dots/colons → underscores)
/// Example: "module:event.sub" → "module_event_sub"
fn emitEventEnumValue(emitter: *CodeEmitter, canonical: []const u8) !void {
    // Extract event name from canonical (strip module qualifier if present)
    const event_name = blk: {
        if (std.mem.indexOfScalar(u8, canonical, ':')) |colon_idx| {
            break :blk canonical[colon_idx + 1 ..];
        }
        break :blk canonical;
    };

    // Mangle event name for enum field (replace dots and colons with underscores)
    for (event_name) |c| {
        if (c == '.' or c == ':') {
            try emitter.write("_");
        } else {
            var buf: [1]u8 = .{c};
            try emitter.write(&buf);
        }
    }
}

/// Emit a branch enum value (handles escaping if needed)
/// Example: "done" → "done", "error-code" → "@\"error-code\""
fn emitBranchEnumValue(emitter: *CodeEmitter, branch: []const u8) !void {
    // Check if branch name needs escaping
    const needs_escape = for (branch) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break true;
    } else false;

    if (needs_escape or isZigKeyword(branch)) {
        try emitter.write("@\"");
        try emitter.write(branch);
        try emitter.write("\"");
    } else {
        try emitter.write(branch);
    }
}

/// Emit Transition types for event taps
/// Three tiers: Transition (12 bytes, enum-based) -> Profile (32+ bytes, string-based) -> Audit (variable, full forensics)
pub fn emitTransitionTypes(
    emitter: *CodeEmitter,
    has_base: bool,
    has_profiling: bool,
    has_audit: bool,
) !void {
    if (has_base) {
        try emitter.writeLine("// Transition meta-type - lightweight enum-based (12 bytes)");
        try emitter.writeLine("// For high-frequency observability with minimal overhead");
        try emitter.writeLine("const Transition = struct {");
        emitter.indent();
        try emitter.writeLine("source: taps.EventEnum,        // u32 enum");
        try emitter.writeLine("destination: ?taps.EventEnum,  // u32 enum (null for terminal)");
        try emitter.writeLine("branch: taps.BranchEnum,       // u32 enum");
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    if (has_profiling) {
        try emitter.writeLine("// Profile meta-type - string-based with timing (32+ bytes)");
        try emitter.writeLine("// For performance profiling and timeline reconstruction");
        try emitter.writeLine("const Profile = struct {");
        emitter.indent();
        try emitter.writeLine("source: []const u8,           // interned string");
        try emitter.writeLine("destination: ?[]const u8,     // interned string (null for terminal)");
        try emitter.writeLine("branch: []const u8,           // interned string");
        try emitter.writeLine("timestamp_ns: i128,           // nanoseconds since epoch (runtime capture)");
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }

    if (has_audit) {
        try emitter.writeLine("// Audit meta-type - full forensics (variable size)");
        try emitter.writeLine("// For compliance, debugging, and detailed analysis");
        try emitter.writeLine("const Audit = struct {");
        emitter.indent();
        try emitter.writeLine("source: []const u8,           // interned string");
        try emitter.writeLine("destination: ?[]const u8,     // interned string (null for terminal)");
        try emitter.writeLine("branch: []const u8,           // interned string");
        try emitter.writeLine("timestamp_ns: u64,            // when this transition occurred");
        try emitter.writeLine("payload: ?[]const u8,         // serialized continuation payload");
        try emitter.writeLine("// TODO: Add stack trace, thread ID, other forensic data");
        emitter.dedent();
        try emitter.writeLine("};");
        try emitter.write("\n");
    }
}

// ============================================================================
// VALUE ANALYSIS HELPERS
// ============================================================================

fn isEscaped(value: []const u8, index: usize) bool {
    var count: usize = 0;
    var pos = index;
    while (pos > 0 and value[pos - 1] == '\\') {
        count += 1;
        pos -= 1;
    }
    return count % 2 == 1;
}

fn isIdentStartChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStartChar(c) or (c >= '0' and c <= '9');
}

fn identifierMatchesInputField(ident: []const u8, input_fields: []const ast.Field) bool {
    for (input_fields) |field| {
        if (std.mem.eql(u8, field.name, ident)) {
            return true;
        }
    }
    return false;
}

fn isInputFieldReference(
    value: []const u8,
    start: usize,
    end: usize,
    input_fields: []const ast.Field,
) bool {
    const ident = value[start..end];

    if (!identifierMatchesInputField(ident, input_fields)) {
        return false;
    }

    if (start > 0) {
        const prev = value[start - 1];
        if (prev == '.' or isIdentChar(prev) or prev == '@') {
            return false;
        }
    }

    if (end < value.len) {
        const next = value[end];
        if (isIdentChar(next)) {
            return false;
        }
    }

    return true;
}

/// Check if a value expression references any input field
pub fn valueReferencesInputField(value: []const u8, input_fields: []const ast.Field) bool {
    if (input_fields.len == 0) {
        return false;
    }

    var i: usize = 0;
    var in_string = false;
    var in_char = false;

    while (i < value.len) {
        const c = value[i];

        if (!in_char and c == '"' and !isEscaped(value, i)) {
            in_string = !in_string;
            i += 1;
            continue;
        }

        if (!in_string and c == '\'' and !isEscaped(value, i)) {
            in_char = !in_char;
            i += 1;
            continue;
        }

        if (!in_string and !in_char and isIdentStartChar(c)) {
            var j = i + 1;
            while (j < value.len and isIdentChar(value[j])) {
                j += 1;
            }

            if (isInputFieldReference(value, i, j, input_fields)) {
                return true;
            }

            i = j;
            continue;
        }

        i += 1;
    }

    return false;
}

// ============================================================================
// SUBFLOW CONTINUATION EMISSION
// ============================================================================

pub fn emitSubflowContinuations(
    emitter: *CodeEmitter,
    continuations: []const ast.Continuation,
    start_idx: usize,
    indent: []const u8,
    all_items: []const ast.Item,
    tap_registry: ?*tap_registry_module.TapRegistry,
    type_registry: *type_registry_module.TypeRegistry,
    main_module_name: ?[]const u8,
    source_event_name: ?[]const u8,
) !void {
    try emitSubflowContinuationsWithDepth(emitter, continuations, start_idx, indent, all_items, 0, tap_registry, type_registry, main_module_name, source_event_name);
}

/// Helper to check if any continuation in a list has a label
fn continuationsHaveLabels(continuations: []const ast.Continuation) bool {
    for (continuations) |cont| {
        // Check for leading label_with_invocation, allowing tap-inserted prefixes
        var label_found = false;
        if (cont.node) |*step| {
            if (step.* == .label_with_invocation) {
                label_found = true;
            }
            if (!isTapInsertedStep(step)) {
                if (label_found) return true;
            }
        }
        if (label_found) {
            return true;
        }
        // Recursively check nested continuations
        if (continuationsHaveLabels(cont.continuations)) {
            return true;
        }
    }
    return false;
}

/// Helper to check if taps might fire for these continuations
/// If taps are possible, we need to use normal continuation emission (not return switch)
/// because emitContinuationBody/emitContinuationList handle tap emission
fn continuationsMightHaveTaps(
    continuations: []const ast.Continuation,
    tap_registry: ?*tap_registry_module.TapRegistry,
    source_event_name: ?[]const u8,
) bool {
    _ = continuations; // Reserved for future optimization to check specific branches

    // If no tap registry or source event, taps can't fire
    if (tap_registry == null or source_event_name == null) {
        return false;
    }

    // If we have tap infrastructure, taps MIGHT fire for any branch
    // We can't easily check without allocating, so conservatively return true
    // The normal switch path handles taps correctly via emitContinuationBody
    return true;
}

/// Helper to check if a binding variable is used in nested continuations
/// This is CRITICAL for deeply nested subflows where outer bindings must stay in scope
fn bindingIsUsedInContinuations(binding_name: []const u8, continuations: []const ast.Continuation) bool {
    for (continuations) |cont| {
        // Check the step
        if (cont.node) |step| {
            switch (step) {
                .invocation => |inv| {
                    // Check if any arg references this binding (e.g., "s.sun" references "s")
                    for (inv.args) |arg| {
                        if (valueReferencesBinding(arg.value, binding_name)) {
                            return true;
                        }
                    }
                },
                .label_with_invocation => |lwi| {
                    for (lwi.invocation.args) |arg| {
                        if (valueReferencesBinding(arg.value, binding_name)) {
                            return true;
                        }
                    }
                },
                .branch_constructor => |bc| {
                    for (bc.fields) |field| {
                        const value = if (field.expression_str) |expr| expr else field.type;
                        if (valueReferencesBinding(value, binding_name)) {
                            return true;
                        }
                    }
                },
                else => {},
            }
        }
        // Recursively check nested continuations
        if (bindingIsUsedInContinuations(binding_name, cont.continuations)) {
            return true;
        }
    }
    return false;
}

/// Check if a string contains a specific identifier (whole-word match)
fn containsIdentifier(text: []const u8, ident: []const u8) bool {
    var idx: usize = 0;
    while (idx < text.len) {
        const remaining = text[idx..];
        const pos_opt = std.mem.indexOf(u8, remaining, ident) orelse return false;
        const start = idx + pos_opt;
        const end = start + ident.len;

        // Check if this is a whole identifier (not part of another identifier)
        const valid_start = start == 0 or !isIdentifierChar(text[start - 1]);
        const valid_end = end >= text.len or !isIdentifierChar(text[end]);

        if (valid_start and valid_end) {
            return true;
        }

        idx = end;
    }
    return false;
}

/// Check if a value expression references a specific binding variable
/// Examples: "s.sun" references "s", "outer.i + 1" references "outer"
fn valueReferencesBinding(value: []const u8, binding_name: []const u8) bool {
    // Look for the binding name as a whole identifier
    if (!containsIdentifier(value, binding_name)) return false;

    // Special case: if it's found, check if it's used as a base for field access or directly
    // This is a bit more specific than containsIdentifier but often used for bindings
    var idx: usize = 0;
    while (idx < value.len) {
        const remaining = value[idx..];
        const pos_opt = std.mem.indexOf(u8, remaining, binding_name) orelse return false;
        const start = idx + pos_opt;
        const end = start + binding_name.len;

        const valid_start = start == 0 or !isIdentifierChar(value[start - 1]);
        const valid_end = end >= value.len or !isIdentifierChar(value[end]);

        if (valid_start and valid_end) {
            // Check if it's followed by a dot (field access) or used in an expression
            if (end < value.len and value[end] == '.') {
                return true; // Field access
            }
            if (end < value.len) {
                const next_char = value[end];
                if (next_char == ' ' or next_char == '+' or next_char == '-' or next_char == ')' or next_char == ',' or next_char == '*' or next_char == '/' or next_char == '%') {
                    return true;
                }
            }
            if (end == value.len) {
                return true;
            }
        }
        idx = end;
    }
    return false;
}

fn isIdentifierChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
           (c >= 'A' and c <= 'Z') or
           (c >= '0' and c <= '9') or
           c == '_';
}

// Branch group for when-clause emission
const BranchGroup = struct {
    branch_name: []const u8,
    continuations: []*const ast.Continuation,
};

// Group continuations by branch name for when-clause emission
// Returns array of unique branches with their continuations
fn groupContinuationsByBranch(
    allocator: std.mem.Allocator,
    continuations: []const ast.Continuation,
) ![]BranchGroup {
    // Use StringHashMap to group by branch name
    var branch_map = std.StringHashMap(std.ArrayList(*const ast.Continuation)).init(allocator);
    defer branch_map.deinit();  // Only deinit the map, not the ArrayList values (ownership transferred)

    // Group continuations by branch
    for (continuations) |*cont| {
        const entry = try branch_map.getOrPut(cont.branch);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(*const ast.Continuation){ .items = &.{}, .capacity = 0 };
        }
        try entry.value_ptr.append(allocator, cont);
    }

    // Convert to array of BranchGroup
    var groups = std.ArrayList(BranchGroup){ .items = &.{}, .capacity = 0 };
    var it = branch_map.iterator();
    while (it.next()) |entry| {
        // Transfer ownership of the ArrayList's items to BranchGroup
        // We must NOT call deinit() on the ArrayList because BranchGroup now owns the slice
        try groups.append(allocator, BranchGroup{
            .branch_name = entry.key_ptr.*,
            .continuations = entry.value_ptr.items,
        });
    }

    return try groups.toOwnedSlice(allocator);
}

fn emitSubflowContinuationsWithDepth(
    emitter: *CodeEmitter,
    continuations: []const ast.Continuation,
    start_idx: usize,
    indent: []const u8,
    all_items: []const ast.Item,
    depth: usize,
    tap_registry: ?*tap_registry_module.TapRegistry,
    type_registry: *type_registry_module.TypeRegistry,
    main_module_name: ?[]const u8,
    source_event_name: ?[]const u8,
) !void {
    if (start_idx >= continuations.len) return;

    // CRITICAL FIX: Check if any continuation has labels
    // If yes, we CANNOT use "return switch" - must use normal continuation emission
    // because labels create loops that must stay within the function
    // TODO: Also check for taps, but need to implement tap emission in return switch path
    // (redirecting to normal switch breaks module qualification for compiler infrastructure)
    if (continuationsHaveLabels(continuations[start_idx..])) {
        // TODO: Add tap support - currently disabled to avoid breaking all tests
        // if (continuationsMightHaveTaps(continuations[start_idx..], tap_registry, source_event_name)) {
        // Use normal continuation emission which handles labels via emitContinuationBody
        var ctx = EmissionContext{
            .allocator = std.heap.page_allocator, // temp allocator for result vars
            .indent_level = 0,  // Will use emitter's indent
            .ast_items = all_items,
            .is_sync = true,
            .tap_registry = tap_registry,  // Pass through tap registry for inline taps!
            .main_module_name = main_module_name,  // Pass through for canonical event naming
            .current_source_event = source_event_name,  // Set source event for inline tap emission!
        };
        var result_counter: usize = depth;
        const result_var = if (depth == 0) "result" else blk: {
            var buf: [32]u8 = undefined;
            break :blk try std.fmt.bufPrint(&buf, "nested_result_{d}", .{depth - 1});
        };

        // Group continuations by branch name to handle when-clauses
        const normal_branch_groups = try groupContinuationsByBranch(
            std.heap.page_allocator,
            continuations[start_idx..]
        );
        defer {
            for (normal_branch_groups) |group| {
                std.heap.page_allocator.free(group.continuations);
            }
            std.heap.page_allocator.free(normal_branch_groups);
        }

        // Emit normal switch statement (NOT return switch)
        try emitter.write(indent);
        try emitter.write("switch (");
        try emitter.write(result_var);
        try emitter.write(") {\n");

        // Emit each branch group
        for (normal_branch_groups) |group| {
            if (group.continuations.len == 1) {
                // Single continuation - emit as normal
                const cont = group.continuations[0];

                const binding_name = cont.binding orelse cont.branch;

                try emitter.write(indent);
                try emitter.write("    .");
                try writeBranchName(emitter, cont.branch);
                try emitter.write(" => ");

                            // Check if we need binding - check the step
                            var needs_binding = false;
                            if (cont.node) |step| {
                                switch (step) {
                                    .invocation => |inv| {
                                        for (inv.args) |arg| {
                                            if (std.mem.indexOf(u8, arg.value, ".") != null) {
                                                needs_binding = true;
                                                break;
                                            }
                                        }
                                    },
                                    .label_with_invocation => |lwi| {
                                        for (lwi.invocation.args) |arg| {
                                            if (std.mem.indexOf(u8, arg.value, ".") != null) {
                                                needs_binding = true;
                                                break;
                                            }
                                        }
                                    },
                                    .branch_constructor => |bc| {
                                        for (bc.fields) |field| {
                                            const value = if (field.expression_str) |expr| expr else field.type;
                                            if (std.mem.indexOf(u8, value, ".") != null) {
                                                needs_binding = true;
                                                break;
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                
                            if (needs_binding) {
                                try emitter.write("|");
                                try writeBranchName(emitter, binding_name);
                                try emitter.write("| ");
                            }
                
                            try emitter.write("{\n");
                
                            // Use emitContinuationBody which handles labels!
                            var deeper_indent_buf: [128]u8 = undefined;
                            @memcpy(deeper_indent_buf[0..indent.len], indent);
                            const extra = "        ";
                            @memcpy(deeper_indent_buf[indent.len .. indent.len + extra.len], extra);
                
                            const old_indent = emitter.indent_level;
                            emitter.indent_level = 0;  // Reset to use manual indenting
                
                            try emitContinuationBody(emitter, &ctx, cont, &result_counter);
                
                            emitter.indent_level = old_indent;

                            try emitter.write(indent);
                            try emitter.write("    },\n");
            } else {
                // Multiple continuations for same branch - emit if/else chain for when-clauses

                // First continuation in group - get binding name
                const first_cont = group.continuations[0];
                const binding_name = first_cont.binding orelse first_cont.branch;

                // Check if ANY continuation in this group needs the binding
                var needs_binding = false;
                for (group.continuations) |cont_ptr| {
                    const cont = cont_ptr.*;
                    if (cont.node) |step| {
                        switch (step) {
                            .invocation => |inv| {
                                for (inv.args) |arg| {
                                    if (std.mem.indexOf(u8, arg.value, ".") != null) {
                                        needs_binding = true;
                                        break;
                                    }
                                }
                            },
                            .branch_constructor => |bc| {
                                for (bc.fields) |field| {
                                    const value = if (field.expression_str) |expr| expr else field.type;
                                    if (std.mem.indexOf(u8, value, ".") != null) {
                                        needs_binding = true;
                                        break;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (needs_binding) break;
                }

                // Write the branch case
                try emitter.write(indent);
                try emitter.write("    .");
                try writeBranchName(emitter, group.branch_name);
                try emitter.write(" => ");

                // Add binding if needed
                if (needs_binding) {
                    try emitter.write("|");
                    try writeBranchName(emitter, binding_name);
                    try emitter.write("| ");
                }

                try emitter.write("{\n");

                // Emit if/else chain for when-clauses
                for (group.continuations, 0..) |cont_ptr, idx| {
                    try emitter.write(indent);
                    try emitter.write("        ");

                    if (cont_ptr.condition) |condition| {
                        // When-clause - emit if or else if
                        if (idx == 0) {
                            try emitter.write("if ");
                        } else {
                            try emitter.write("else if ");
                        }
                        try emitter.write(condition);
                        try emitter.write(" {\n");
                    } else {
                        // No when-clause - this is the else case
                        try emitter.write("else {\n");
                    }

                    // Emit continuation body
                    var deeper_indent_buf: [128]u8 = undefined;
                    @memcpy(deeper_indent_buf[0..indent.len], indent);
                    const extra = "            ";
                    @memcpy(deeper_indent_buf[indent.len .. indent.len + extra.len], extra);

                    const old_indent = emitter.indent_level;
                    emitter.indent_level = 0;  // Reset to use manual indenting

                    try emitContinuationBody(emitter, &ctx, cont_ptr, &result_counter);

                    emitter.indent_level = old_indent;

                    try emitter.write(indent);
                    try emitter.write("        }\n");
                }

                try emitter.write(indent);
                try emitter.write("    },\n");
            }
        }

        try emitter.write(indent);
        try emitter.write("}\n");
        return;
    }

    // Group continuations by branch name to handle when-clauses
    const branch_groups = try groupContinuationsByBranch(
        std.heap.page_allocator,
        continuations[start_idx..]
    );
    defer {
        for (branch_groups) |group| {
            std.heap.page_allocator.free(group.continuations);
        }
        std.heap.page_allocator.free(branch_groups);
    }

    // Start the switch statement ONCE for all sibling continuations
    try emitter.write(indent);
    try emitter.write("return switch (");
    if (depth == 0) {
        try emitter.write("result");
    } else {
        var buf: [32]u8 = undefined;
        const depth_str = try std.fmt.bufPrint(&buf, "nested_result_{d}", .{depth - 1});
        try emitter.write(depth_str);
    }
    try emitter.write(") {\n");

    // Emit ALL branch groups at this level
    for (branch_groups) |group| {
        // Handle single vs multiple continuations for this branch
        if (group.continuations.len == 1) {
            // Single continuation - emit as normal
            const cont = group.continuations[0].*;

            // Write the branch case
            try emitter.write(indent);
            try emitter.write("    .");
            try writeBranchName(emitter, cont.branch);
            try emitter.write(" => ");

            // Handle binding - if explicit binding exists, use it; otherwise use branch name
            const actual_binding = cont.binding orelse cont.branch;

            // CRITICAL FIX: Check if binding is used in CURRENT pipeline OR nested continuations!
            // This is essential for deeply nested subflows where outer bindings must stay in scope
            var needs_binding = false;

            // Check the step (not just first step)
            // This is critical when taps are inserted - tap might be at step with no args,
            // but the step (branch constructor) might use the binding
            if (cont.node) |step| {
                switch (step) {
                    .invocation => |inv| {
                        // Check if any arg references the branch payload
                        for (inv.args) |arg| {
                            if (std.mem.indexOf(u8, arg.value, ".") != null) {
                                needs_binding = true;
                                break;
                            }
                        }
                    },
                    .branch_constructor => |bc| {
                        // Check if any field references the branch payload
                        for (bc.fields) |field| {
                            const value = if (field.expression_str) |expr| expr else field.type;
                            if (std.mem.indexOf(u8, value, ".") != null) {
                                needs_binding = true;
                                break;
                            }
                        }
                    },
                    else => {},
                }
            }

            // CRITICAL: Also check if binding is used in nested continuations!
            // Example: | created s |> ... nested ... |> assemble(sun: s.sun, ...)
            //          The binding 's' is used deep in nested continuations!
            if (!needs_binding and cont.continuations.len > 0) {
                needs_binding = bindingIsUsedInContinuations(actual_binding, cont.continuations);
            }

            if (needs_binding) {
                try emitter.write("|");
                try writeBranchName(emitter, actual_binding);
                try emitter.write("| ");
            }

            // Check what's in the step - check for invocations
            // (metatype_binding might be first, so can't just check step directly)
            var has_invocation = false;
            if (cont.node) |step| {
                if (step == .invocation) {
                    has_invocation = true;
                }
            }

            if (has_invocation) {
                // Step contains invocation - emit the step
                // This handles taps inserted by AST transformation (tap + branch constructor)
                try emitter.write("{\n");

                    // Track the index of the last invocation result for nested continuation switching
                    var last_result_idx: usize = depth;

                    // Emit the step
                    if (cont.node) |step| {
                        const step_idx: usize = 0;
                        switch (step) {
                            .invocation => |inv| {
                                // Track this as the last result index
                                last_result_idx = depth + step_idx;
                                // Emit invocation step (could be a tap or regular invocation)
                                try emitter.write(indent);
                                var buf: [64]u8 = undefined;
                                const var_name = try std.fmt.bufPrint(&buf, "        const nested_result_{d} = ", .{depth + step_idx});
                                try emitter.write(var_name);
            
                                // Emit module qualifier if present
                                if (inv.path.module_qualifier) |mq| {
                                    try writeModulePath(emitter, mq, main_module_name);
                                    try emitter.write(".");
                                }
                                // Join all segments with underscores
                                for (inv.path.segments, 0..) |seg, i| {
                                    if (i > 0) try emitter.write("_");
                                    try emitter.write(seg);
                                }
                                try emitter.write("_event.handler(.{");
                                for (inv.args, 0..) |arg, idx| {
                                    if (idx > 0) try emitter.write(", ");
                                    try emitter.write(" .");
                                    try emitter.write(arg.name);
                                    try emitter.write(" = ");
                                    try emitter.write(arg.value);
                                }
                                try emitter.write(" });\n");
            
                                // Suppress unused variable warning (result might not be used, e.g., for taps)
                                try emitter.write(indent);
                                const suppress_unused = try std.fmt.bufPrint(&buf, "        _ = &nested_result_{d};\n", .{depth + step_idx});
                                try emitter.write(suppress_unused);
                            },
                            .metatype_binding => |mb| {
                                // Emit metatype construction (Profile/Transition/Audit)
                                // Transition uses enum literals (fast), Profile uses strings (heavier with timing)
                                try emitter.write(indent);
                                try emitter.write("        const ");
                                try emitter.write(mb.binding);
                                try emitter.write(" = taps.");
                                try emitter.write(mb.metatype);
                                try emitter.write("{\n");
            
                                const is_transition = std.mem.eql(u8, mb.metatype, "Transition");
            
                                // .source field - enum literal for Transition, string for Profile
                                try emitter.write(indent);
                                if (is_transition) {
                                    // Transition: .source = .compiler_context_create (enum literal)
                                    try emitter.write("            .source = .");
                                    try canonicalNameToEnumTag(emitter, mb.source_event);
                                    try emitter.write(",\n");
                                } else {
                                    // Profile/Audit: .source = "main:http.request" (string literal)
                                    try emitter.write("            .source = \"");
                                    try emitter.write(mb.source_event);
                                    try emitter.write("\",\n");
                                }
            
                                // .destination field (null for terminal)
                                try emitter.write(indent);
                                if (mb.dest_event) |dest| {
                                    if (is_transition) {
                                        // Transition: .destination = .compiler_coordinate_frontend (enum literal)
                                        try emitter.write("            .destination = .");
                                        try canonicalNameToEnumTag(emitter, dest);
                                        try emitter.write(",\n");
                                    } else {
                                        // Profile/Audit: .destination = "main:http.response" (string literal)
                                        try emitter.write("            .destination = \"");
                                        try emitter.write(dest);
                                        try emitter.write("\",\n");
                                    }
                                } else {
                                    try emitter.write("            .destination = null,\n");
                                }
            
                                // .branch field - enum literal for Transition, string for Profile
                                try emitter.write(indent);
                                if (is_transition) {
                                    // Transition: .branch = .created (enum literal)
                                    // Use __void for empty branches (void event completion)
                                    try emitter.write("            .branch = .");
                                    if (mb.branch.len == 0) {
                                        try emitter.write("__void");
                                    } else {
                                        try emitter.write(mb.branch);
                                    }
                                    try emitter.write(",\n");
                                } else {
                                    // Profile/Audit: .branch = "done" (string literal)
                                    try emitter.write("            .branch = \"");
                                    if (mb.branch.len == 0) {
                                        try emitter.write("__void");
                                    } else {
                                        try emitter.write(mb.branch);
                                    }
                                    try emitter.write("\",\n");
                                }
            
                                // .timestamp_ns field - ONLY for Profile/Audit (not Transition)
                                if (!is_transition) {
                                    try emitter.write(indent);
                                    try emitter.write("            .timestamp_ns = __koru_std.time.nanoTimestamp(),\n");
                                }
            
                                try emitter.write(indent);
                                try emitter.write("        };\n");
                            },
                            .branch_constructor => |bc| {
                                // Branch constructor - emit return statement
                                try emitter.write(indent);
                                try emitter.write("        return .{ .");
                                try writeBranchName(emitter, bc.branch_name);
                                try emitter.write(" = .{");
                                for (bc.fields, 0..) |field, idx| {
                                    if (idx > 0) try emitter.write(", ");
                                    try emitter.write(" .");
                                    try emitter.write(field.name);
                                    try emitter.write(" = ");
                                    if (field.expression_str) |expr| {
                                        try emitter.write(expr);
                                    } else {
                                        try emitter.write(field.type);
                                    }
                                }
                                try emitter.write(" } };\n");
                            },
                            else => {
                                // Other step types - not expected in return switch optimization path
                                // If we encounter them, this indicates AST structure we don't handle yet
                            },
                        }
                    }
            
                    // After emitting the step, recurse into nested continuations if present
                    // This must be OUTSIDE the step check so it runs regardless of what the step type was
                    // Use last_result_idx + 1 as the depth for nested continuations (not depth + 1)
                    // because metatype_binding steps don't create result variables
                    if (cont.continuations.len > 0) {
                        var deeper_indent_buf: [128]u8 = undefined;
                        @memcpy(deeper_indent_buf[0..indent.len], indent);
                        const extra = "        ";
                        @memcpy(deeper_indent_buf[indent.len .. indent.len + extra.len], extra);
                        const deeper_indent = deeper_indent_buf[0 .. indent.len + extra.len];
                        try emitSubflowContinuationsWithDepth(emitter, cont.continuations, 0, deeper_indent, all_items, last_result_idx + 1, tap_registry, type_registry, main_module_name, source_event_name);
                    }
            
                    try emitter.write(indent);
                    try emitter.write("    },\n");
                } else {
                    // Terminal case - branch constructor
                    // Taps are now in the AST via tap_transformer, so just emit inline
                    if (cont.node) |step| {
                        switch (step) {
                            .branch_constructor => |bc2| {
                                try emitter.write(".{ .");
                                try writeBranchName(emitter, bc2.branch_name);
                                try emitter.write(" = .{");
                                for (bc2.fields, 0..) |field2, idx| {
                                    if (idx > 0) try emitter.write(", ");
                                    try emitter.write(" .");
                                    try emitter.write(field2.name);
                                    try emitter.write(" = ");
                                    if (field2.expression_str) |expr| {
                                        try emitter.write(expr);
                                    } else {
                                        try emitter.write(field2.type);
                                    }
                                }
                                try emitter.write(" } }");
                            },
                            else => {},
                        }
                    } else {
                        try emitter.write("{}");
                    }
                    try emitter.write(",\n");
    }  // End of if (has_invocation)
        } else {
            // Multiple continuations for same branch - emit if/else chain for when-clauses

            // First continuation in group - get binding name
            const first_cont = group.continuations[0].*;
            const actual_binding = first_cont.binding orelse first_cont.branch;

            // Check if ANY continuation in this group needs the binding
            var needs_binding = false;
            for (group.continuations) |cont_ptr| {
                const cont = cont_ptr.*;
                if (cont.node) |step| {
                    switch (step) {
                        .invocation => |inv| {
                            for (inv.args) |arg| {
                                if (std.mem.indexOf(u8, arg.value, ".") != null) {
                                    needs_binding = true;
                                    break;
                                }
                            }
                        },
                        .branch_constructor => |bc| {
                            for (bc.fields) |field| {
                                const value = if (field.expression_str) |expr| expr else field.type;
                                if (std.mem.indexOf(u8, value, ".") != null) {
                                    needs_binding = true;
                                    break;
                                }
                            }
                        },
                        else => {},
                    }
                }
                if (!needs_binding and cont.continuations.len > 0) {
                    needs_binding = bindingIsUsedInContinuations(actual_binding, cont.continuations);
                }
                if (needs_binding) break;
            }

            // Write the branch case
            try emitter.write(indent);
            try emitter.write("    .");
            try writeBranchName(emitter, group.branch_name);
            try emitter.write(" => ");

            // Add binding if needed
            if (needs_binding) {
                try emitter.write("|");
                try writeBranchName(emitter, actual_binding);
                try emitter.write("| ");
            }

            // Emit if/else chain for when-clauses
            // Each continuation becomes a condition branch
            for (group.continuations, 0..) |cont_ptr, idx| {
                const cont = cont_ptr.*;

                if (idx > 0) {
                    try emitter.write("\n");
                    try emitter.write(indent);
                    try emitter.write("    ");
                }

                if (cont.condition) |condition| {
                    // When-clause - emit if or else if
                    if (idx == 0) {
                        try emitter.write("if ");
                    } else {
                        try emitter.write("else if ");
                    }
                    try emitter.write(condition);
                    try emitter.write(" ");
                } else {
                    // No when-clause - this is the else case
                    try emitter.write("else ");
                }

                // Emit the result for this continuation
                // For simplicity, handle only terminal case (branch constructor)
                // The flow_checker already validated that when-clauses don't have complex pipelines
                if (cont.node) |step| {
                    switch (step) {
                        .branch_constructor => |bc| {
                            try emitter.write(".{ .");
                            try writeBranchName(emitter, bc.branch_name);
                            try emitter.write(" = .{");
                            for (bc.fields, 0..) |field, field_idx| {
                                if (field_idx > 0) try emitter.write(", ");
                                try emitter.write(" .");
                                try emitter.write(field.name);
                                try emitter.write(" = ");
                                if (field.expression_str) |expr| {
                                    try emitter.write(expr);
                                } else {
                                    try emitter.write(field.type);
                                }
                            }
                            try emitter.write(" } }");
                        },
                        else => {
                            // Fallback for other step types
                            try emitter.write("{}");
                        },
                    }
                } else {
                    try emitter.write("{}");
                }
            }

            try emitter.write(",\n");
        }  // End of if (single vs multiple continuations)
    }  // End of for loop over all branch groups

    // Close the switch
    try emitter.write(indent);
    try emitter.write("};\n");
}

// ============================================================================
// MODULE/EVENT LOOKUP HELPERS
// ============================================================================

/// Find which module an event is defined in
/// Returns the module logical_name, or null if event is in main module
/// Find if an event exists in the LOCAL (main) module
/// This searches ONLY top-level event declarations, NOT imported modules
/// Used to prioritize local events over imported ones for unqualified invocations
pub fn findLocalEvent(event_path: []const []const u8, items: []const ast.Item) bool {
    for (items) |item| {
        if (item == .event_decl) {
            const event = item.event_decl;
            // Compare paths
            if (event.path.segments.len == event_path.len) {
                var matches = true;
                for (event.path.segments, 0..) |segment, i| {
                    if (!std.mem.eql(u8, segment, event_path[i])) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    return true;
                }
            }
        }
    }
    return false;
}

pub fn findEventModule(event_path: []const []const u8, items: []const ast.Item) ?[]const u8 {
    // Search in submodules first
    for (items) |item| {
        if (item == .module_decl) {
            const module = item.module_decl;
            // Check if event is in this module
            for (module.items) |module_item| {
                if (module_item == .event_decl) {
                    const event = module_item.event_decl;
                    // Compare paths
                    if (event.path.segments.len == event_path.len) {
                        var matches = true;
                        for (event.path.segments, 0..) |segment, i| {
                            if (!std.mem.eql(u8, segment, event_path[i])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            return module.logical_name;
                        }
                    }
                }
            }
            // Recursively search nested modules
            if (findEventModule(event_path, module.items)) |found| {
                return found;
            }
        }
    }
    return null;
}

/// Find an event declaration by its path
/// Handles both local events (no module_qualifier) and imported module events (with module_qualifier)
fn findEventDeclByPath(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
    // If path has a module_qualifier (e.g., "vaxis" in "vaxis:poll"),
    // we need to find the matching module first
    if (path.module_qualifier) |module_qual| {
        for (items) |*item| {
            switch (item.*) {
                .module_decl => |*module| {
                    // Check if this module matches the qualifier
                    if (std.mem.eql(u8, module.logical_name, module_qual)) {
                        // Found the module - now search for the event inside it
                        return findEventDeclByPathInModule(module.items, path.segments);
                    }
                },
                else => {},
            }
        }
        // If no module_decl matches, the module_qualifier might refer to the main module
        // which is the source_file itself (not a module_decl). Fall back to searching
        // top-level items for the event.
        return findEventDeclByPathInModule(items, path.segments);
    }

    // No module qualifier - search for local events
    for (items) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                // Compare paths
                if (event.path.segments.len == path.segments.len) {
                    var matches = true;
                    for (event.path.segments, 0..) |segment, i| {
                        if (!std.mem.eql(u8, segment, path.segments[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        return event;
                    }
                }
            },
            .module_decl => |*module| {
                if (findEventDeclByPath(module.items, path)) |found| {
                    return found;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Helper: Find event by segments within a specific module's items
fn findEventDeclByPathInModule(items: []const ast.Item, segments: []const []const u8) ?*const ast.EventDecl {
    for (items) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                if (event.path.segments.len == segments.len) {
                    var matches = true;
                    for (event.path.segments, 0..) |segment, i| {
                        if (!std.mem.eql(u8, segment, segments[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        return event;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// Find an event declaration by canonical name (e.g., "main:http.request")
fn findEventByName(items: []const ast.Item, canonical_name: []const u8, allocator: std.mem.Allocator, main_module_name: ?[]const u8) ?*const ast.EventDecl {
    for (items) |*item| {
        switch (item.*) {
            .event_decl => |*event| {
                // Build canonical name from path
                const canonical = buildCanonicalEventName(&event.path, allocator, main_module_name) catch continue;
                defer allocator.free(canonical);

                if (std.mem.eql(u8, canonical, canonical_name)) {
                    return event;
                }
            },
            .module_decl => |*module| {
                if (findEventByName(module.items, canonical_name, allocator, main_module_name)) |found| {
                    return found;
                }
            },
            else => {},
        }
    }
    return null;
}

// ============================================================================
// EVENT TAP EMISSION
// ============================================================================

/// Emit all tap functions recursively (including from modules)
pub fn emitAllTaps(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    items: []const ast.Item,
    tap_counter: *usize,
) !void {
    for (items) |item| {
        switch (item) {
            .event_tap => |*tap| {
                try emitTapFunction(emitter, ctx, tap, tap_counter.*);
                tap_counter.* += 1;
            },
            .module_decl => |module| {
                try emitAllTaps(emitter, ctx, module.items, tap_counter);
            },
            else => {},
        }
    }
}

/// Emit a single tap function
pub fn emitTapFunction(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    tap: *const ast.EventTap,
    tap_number: usize,
) !void {
    // TODO: Full implementation needs emitStep and dependencies
    // For now, emit a minimal stub
    _ = ctx;
    _ = tap;

    try emitter.writeIndent();
    try emitter.write("inline fn __tap");
    var num_buf: [32]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{}", .{tap_number});
    try emitter.write(num_str);
    try emitter.write("(_: anytype) void {}\n");
}

// ============================================================================
// FLOW EMISSION
// ============================================================================

/// Build canonical event name from DottedPath (e.g., "module:event.path")
pub fn buildCanonicalEventName(path: *const ast.DottedPath, allocator: std.mem.Allocator, main_module_name: ?[]const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer result.deinit(allocator);

    // Add module qualifier
    if (path.module_qualifier) |mq| {
        // Path is explicitly qualified - use it
        try result.appendSlice(allocator, mq);
        try result.append(allocator, ':');
    } else if (main_module_name) |mmn| {
        // Path is unqualified - qualify with entry module name (e.g., "input", not hardcoded "main")
        try result.appendSlice(allocator, mmn);
        try result.append(allocator, ':');
    }

    // Add segments joined by dots
    for (path.segments, 0..) |seg, i| {
        if (i > 0) try result.append(allocator, '.');
        try result.appendSlice(allocator, seg);
    }

    return try result.toOwnedSlice(allocator);
}

/// Emit a flow (invocation with continuations)
pub fn emitFlow(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    flow: *const ast.Flow,
) !void {
    // Preamble code: emitted BEFORE continuations, SKIPS the invocation
    // Used by ~const to emit declaration while preserving AST structure for analysis
    // After the preamble, we emit continuation bodies directly (no handler call)
    if (flow.preamble_code) |preamble| {
        try emitter.write(preamble);
        try emitter.write("\n");

        // Now emit continuation bodies directly - no switch, no handler call
        // The preamble already set up the binding (e.g., `const cfg = ...;`)
        // Each continuation's node is the code that should run
        var result_counter: usize = 0;
        for (flow.continuations) |*cont| {
            try emitContinuationBody(emitter, ctx, cont, &result_counter);
        }
        return;  // Done - don't emit the invocation
    }

    // Zero-overhead control flow: if inline_body is set, emit it directly
    // This enables ~if, ~for to emit literal Zig control flow instead of handler calls
    if (flow.inline_body) |inline_code| {
        try emitter.write(inline_code);
        return;
    }

    var result_counter: usize = 0;

    // Initialize label contexts map for this flow
    var label_contexts = std.StringHashMap(LabelContext).init(ctx.allocator);
    defer {
        // Free all duplicated result_var strings before deinit
        var it = label_contexts.valueIterator();
        while (it.next()) |label_ctx| {
            ctx.allocator.free(label_ctx.result_var);
        }
        label_contexts.deinit();
    }
    ctx.label_contexts = &label_contexts;
    defer ctx.label_contexts = null;

    // Set current source event for tap matching
    const source_event = try buildCanonicalEventName(&flow.invocation.path, ctx.allocator, ctx.main_module_name);
    defer ctx.allocator.free(source_event);
    ctx.current_source_event = source_event;

    // Check if this flow has a pre_label - if so, emit state variables and wrap in a while loop
    if (flow.pre_label) |label| {
        // Look up event definition to get parameter types
        const event_decl = if (ctx.ast_items) |items|
            findEventDeclByPath(items, &flow.invocation.path)
        else
            null;

        // Determine if label will be mutated by checking for .label_jump
        const label_is_mutable = labelWillBeMutated(label, flow.continuations);

        // CRITICAL: If mutable, we MUST have type annotations (Zig forbids var with comptime_int)
        if (label_is_mutable and event_decl == null) {
            std.debug.panic("COMPILER BUG: Cannot find event declaration for loop variable '{s}' when emitting mutable label '{s}'. Event lookup failed for invocation path with {} segments.", .{
                if (flow.invocation.args.len > 0) flow.invocation.args[0].name else "(no args)",
                label,
                flow.invocation.path.segments.len,
            });
        }

        // Emit state variables for loop parameters with type annotations
        for (flow.invocation.args) |arg| {
            try emitter.writeIndent();
            // Use var if label will be mutated by label_jump, const otherwise
            if (label_is_mutable) {
                try emitter.write("var ");
            } else {
                try emitter.write("const ");
            }
            try emitter.write(label);
            try emitter.write("_");
            try emitter.write(arg.name);

            // Add type annotation if we found the event
            if (event_decl) |event| {
                // Find the matching field in the event's input
                var found_field = false;
                for (event.input.fields) |field| {
                    if (std.mem.eql(u8, field.name, arg.name)) {
                        try emitter.write(": ");
                        if (field.is_file or field.is_embed_file) {
                            try emitter.write("[]const u8");
                        } else if (field.is_source) {
                            try emitter.write("[]const u8");
                        } else {
                            try writeFieldType(emitter, field, ctx.main_module_name);
                        }
                        found_field = true;
                        break;
                    }
                }

                // CRITICAL: If mutable and field not found, this is a compiler bug
                if (label_is_mutable and !found_field) {
                    std.debug.panic("COMPILER BUG: Cannot find field '{s}' in event declaration when emitting mutable label '{s}'", .{ arg.name, label });
                }
            }

            try emitter.write(" = ");
            try emitter.write(arg.value);
            try emitter.write(";\n");
        }

        // NOTE: We'll emit the while loop header AFTER we determine the result variable name
        // (see below where we actually emit the loop)
    }

    // If there are no continuations, discard the result
    if (flow.continuations.len > 0) {
        // Check if this is a void event (empty branch) - if so, discard result
        const is_void_event = flow.continuations.len == 1 and
                              std.mem.eql(u8, flow.continuations[0].branch, "");

        const first_result = if (is_void_event)
            "_"  // Discard void result
        else
            try std.fmt.allocPrint(ctx.allocator, "result_{}", .{result_counter});

        defer if (!is_void_event) ctx.allocator.free(first_result);

        // If we have a pre_label, emit first invocation BEFORE the while loop
        if (flow.pre_label) |label| {
            // Analyze which branches loop back to this label
            const looping_branches = try findLoopingBranches(label, flow.continuations, ctx.allocator);
            defer ctx.allocator.free(looping_branches);

            // Emit FIRST invocation before the loop (to get initial result)
            try emitter.writeIndent();
            try emitter.write("var ");  // var, not const - we'll update it in the loop!
            try emitter.write(first_result);
            try emitter.write(" = ");
            if (!ctx.is_sync) {
                try emitter.write("try ");
            }
            try emitInvocationTarget(emitter, ctx, &flow.invocation.path);
            try emitter.write(".handler(.{ ");
            // Use state variables for initial call
            for (flow.invocation.args, 0..) |arg, idx| {
                if (idx > 0) {
                    try emitter.write(", ");
                }
                try emitter.write(".");
                try emitter.write(arg.name);
                try emitter.write(" = ");
                try emitter.write(label);
                try emitter.write("_");
                try emitter.write(arg.name);
            }
            try emitter.write(" });\n");

            // Register this label in the context map (for cross-level jumps)
            if (ctx.label_contexts) |label_map| {
                // Need to duplicate the result string since first_result will be freed
                const result_copy = try ctx.allocator.dupe(u8, first_result);
                try label_map.put(label, .{
                    .handler_invocation = &flow.invocation,
                    .result_var = result_copy,
                });
            }

            // NOW emit the while loop with explicit condition based on looping branches
            try emitter.writeIndent();

            // ALWAYS emit the Zig label (needed for continue :label statements)
            try emitter.write(label);
            try emitter.write(": ");

            try emitter.write("while (");

            // Emit explicit loop condition
            if (looping_branches.len == 0) {
                // No branches loop - fallback to while(true)
                try emitter.write("true");
            } else if (looping_branches.len == 1) {
                // Single branch loops - emit: while (result == .branch)
                try emitter.write(first_result);
                try emitter.write(" == .");
                try writeBranchName(emitter, looping_branches[0]);
            } else {
                // Multiple branches loop - emit: while ((result == .branch1) or (result == .branch2))
                for (looping_branches, 0..) |branch, idx| {
                    if (idx > 0) {
                        try emitter.write(" or ");
                    }
                    try emitter.write("(");
                    try emitter.write(first_result);
                    try emitter.write(" == .");
                    try writeBranchName(emitter, branch);
                    try emitter.write(")");
                }
            }

            try emitter.write(") {\n");
            emitter.indent();

            // Store label context so label_jump can re-call the handler
            ctx.label_handler_invocation = &flow.invocation;
            ctx.label_result_var = first_result;
        } else {
            try emitInvocation(emitter, ctx, &flow.invocation, first_result);
        }

        result_counter += 1;

        // If we have a pre_label, we need to split continuations into looping and non-looping
        if (flow.pre_label) |label| {
            const looping_branches = try findLoopingBranches(label, flow.continuations, ctx.allocator);
            defer ctx.allocator.free(looping_branches);

            // If NO branches loop, the label is unused - just emit all continuations normally
            if (looping_branches.len == 0) {
                // Clear the label context since we won't use it
                ctx.label_handler_invocation = null;
                ctx.label_result_var = null;

                // Emit all continuations as a regular switch (no loop)
                try emitContinuationList(emitter, ctx, flow.continuations, first_result, &result_counter, false);
            } else {
                // ONLY emit looping branches inside the while loop
                // Build list of looping continuations
                var looping_conts = try std.ArrayList(ast.Continuation).initCapacity(ctx.allocator, looping_branches.len);
                defer looping_conts.deinit(ctx.allocator);

                for (flow.continuations) |cont| {
                    // Check if this continuation is in the looping branches list
                    for (looping_branches) |loop_branch| {
                        if (std.mem.eql(u8, cont.branch, loop_branch)) {
                            try looping_conts.append(ctx.allocator, cont);
                            break;
                        }
                    }
                }

                // Emit switch with only looping branches
                // Looping switches don't need else (they're inside the while condition)
                if (looping_conts.items.len > 0) {
                    try emitContinuationList(emitter, ctx, looping_conts.items, first_result, &result_counter, false);
                }

            // Clear label context after looping continuations
            ctx.label_handler_invocation = null;
            ctx.label_result_var = null;

            // Close the while loop
            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");

            // NOW emit switch for NON-LOOPING branches (after the while)
            if (looping_branches.len < flow.continuations.len) {
                // Build list of non-looping continuations
                var non_looping_conts = try std.ArrayList(ast.Continuation).initCapacity(ctx.allocator, flow.continuations.len - looping_branches.len);
                defer non_looping_conts.deinit(ctx.allocator);

                for (flow.continuations) |cont| {
                    // Check if this continuation is NOT in the looping branches list
                    var is_looping = false;
                    for (looping_branches) |loop_branch| {
                        if (std.mem.eql(u8, cont.branch, loop_branch)) {
                            is_looping = true;
                            break;
                        }
                    }

                    if (!is_looping) {
                        try non_looping_conts.append(ctx.allocator, cont);
                    }
                }

                // Emit switch with only non-looping branches
                // NOTE: After the while loop guard, looping branches are IMPOSSIBLE.
                // Zig 0.15+ knows this and considers the switch exhaustive, so we must NOT
                // emit else => unreachable (it would be "unreachable else prong; all cases handled")
                if (non_looping_conts.items.len > 0) {
                    try emitContinuationList(emitter, ctx, non_looping_conts.items, first_result, &result_counter, false);
                }
            }
            }
        } else {
            // No pre_label - emit all continuations normally
            try emitContinuationList(emitter, ctx, flow.continuations, first_result, &result_counter, false);
        }
    } else {
        try emitInvocation(emitter, ctx, &flow.invocation, "_");
    }
}

/// Check if an event has any branches with [mutable] annotation
fn eventHasMutableBranches(ctx: *EmissionContext, event_path: *const ast.DottedPath) bool {
    if (ctx.ast_items == null) return false;

    const items = ctx.ast_items.?;
    const event_decl = findEventDeclByPath(items, event_path) orelse return false;

    // Check if any branch has [mutable] annotation
    for (event_decl.branches) |branch| {
        for (branch.annotations) |ann| {
            if (std.mem.eql(u8, ann, "mutable")) {
                return true;
            }
        }
    }

    return false;
}

/// Check if a specific branch of an event has [mutable] annotation
fn branchHasMutableAnnotation(ctx: *EmissionContext, event_name: []const u8, branch_name: []const u8) bool {
    if (ctx.ast_items == null) return false;

    const items = ctx.ast_items.?;

    // Find the event declaration by canonical name
    for (items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;
            // Build canonical name from path
            const canonical = buildCanonicalEventName(&event_decl.path, ctx.allocator, ctx.main_module_name) catch return false;
            defer ctx.allocator.free(canonical);

            if (std.mem.eql(u8, canonical, event_name)) {
                // Found the event, now check if the specific branch has [mutable]
                for (event_decl.branches) |branch| {
                    if (std.mem.eql(u8, branch.name, branch_name)) {
                        for (branch.annotations) |ann| {
                            if (std.mem.eql(u8, ann, "mutable")) {
                                return true;
                            }
                        }
                        return false;
                    }
                }
            }
        }
    }

    return false;
}

/// Check if a continuation's binding has [mutable] annotation (from binding site: | result r[mutable] |>)
fn bindingHasMutableAnnotation(cont: *const ast.Continuation) bool {
    for (cont.binding_annotations) |ann| {
        if (std.mem.eql(u8, ann, "mutable")) {
            return true;
        }
    }
    return false;
}

/// Check if a specific branch of an event has payload fields (non-empty payload)
/// Returns true if branch has fields, false if empty payload or branch not found
fn branchHasPayloadFields(ctx: *EmissionContext, event_name: []const u8, branch_name: []const u8) bool {
    if (ctx.ast_items == null) return true; // Conservative: assume has fields if we can't check

    const items = ctx.ast_items.?;

    // Find the event declaration by canonical name
    for (items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;
            // Build canonical name from path
            const canonical = buildCanonicalEventName(&event_decl.path, ctx.allocator, ctx.main_module_name) catch return true;
            defer ctx.allocator.free(canonical);

            if (std.mem.eql(u8, canonical, event_name)) {
                // Found the event, now check if the specific branch has payload fields
                for (event_decl.branches) |branch| {
                    if (std.mem.eql(u8, branch.name, branch_name)) {
                        return branch.payload.fields.len > 0;
                    }
                }
            }
        }
    }

    return true; // Conservative: assume has fields if branch not found
}

/// Emit an invocation (const result = event.handler(...))
fn emitInvocation(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    invocation: *const ast.Invocation,
    result_var: []const u8,
) !void {
    try emitter.writeIndent();
    // Don't use 'const' if result_var is "_" (discard)
    // Note: Labeled invocations (which need 'var') don't use this function - they emit manually
    if (!std.mem.eql(u8, result_var, "_")) {
        try emitter.write("const ");
    }
    try emitter.write(result_var);
    try emitter.write(" = ");
    // Only emit 'try' for async calls (is_sync = false means async)
    if (!ctx.is_sync) {
        try emitter.write("try ");
    }
    try emitInvocationTarget(emitter, ctx, &invocation.path);
    try emitter.write(".handler(.{ ");
    try emitArgs(emitter, ctx, invocation.args, &invocation.path);
    try emitter.write(" });\n");
}

/// Emit the target of an invocation (e.g., "koru_std.io.print_event" or "main_module.hello_event")
fn emitInvocationTarget(emitter: *CodeEmitter, ctx: *EmissionContext, path: *const ast.DottedPath) !void {
    // CRITICAL: Check if we're at module level (not in a handler)
    // This happens when emitting meta-event taps from main()
    const at_module_level = !ctx.in_handler and ctx.input_var == null;

    // Use explicit module_qualifier if present
    if (path.module_qualifier) |mq| {
        // Try to resolve the alias to the actual module path
        const resolved_path = if (ctx.ast_items) |items|
            resolveModuleAlias(mq, items) orelse mq
        else
            mq;
        try writeModulePath(emitter, resolved_path, ctx.main_module_name);
        try emitter.write(".");
    } else if (ctx.ast_items) |items| {
        // CRITICAL: Check LOCAL events FIRST before checking imported modules
        // This ensures unqualified names resolve to local events when they exist
        const is_local = findLocalEvent(path.segments, items);

        if (is_local) {
            // Event exists locally - always use main_module
            try emitter.write("main_module.");
        } else if (findEventModule(path.segments, items)) |module_name| {
            // Not found locally, check imported modules
            try writeModulePath(emitter, module_name, ctx.main_module_name);
            try emitter.write(".");
        } else if (at_module_level) {
            // At module level (main()) and not found anywhere
            // Assume main_module (unless it's a compiler event)
            const is_compiler_event = path.segments.len > 0 and std.mem.eql(u8, path.segments[0], "compiler");
            if (!is_compiler_event) {
                try emitter.write("main_module.");
            }
        }
    } else if (at_module_level) {
        // At module level but no ast_items to search
        // Assume main_module (unless compiler event)
        const is_compiler_event = path.segments.len > 0 and std.mem.eql(u8, path.segments[0], "compiler");
        if (!is_compiler_event) {
            try emitter.write("main_module.");
        }
    }

    if (path.segments.len == 0) return;

    // Join all segments with underscores
    for (path.segments, 0..) |segment, idx| {
        if (idx > 0) {
            try emitter.write("_");
        }
        try emitter.write(segment);
    }
    // Don't add _event suffix for compiler.* events (they're hardcoded in main.zig)
    const is_compiler_event = path.segments.len > 0 and std.mem.eql(u8, path.segments[0], "compiler");
    if (!is_compiler_event) {
        try emitter.write("_event");
    }
}

/// Emit a string with proper escaping for Zig string literals
fn emitEscapedString(emitter: *CodeEmitter, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '"' => try emitter.write("\\\""),
            '\\' => try emitter.write("\\\\"),
            '\n' => try emitter.write("\\n"),
            '\r' => try emitter.write("\\r"),
            '\t' => try emitter.write("\\t"),
            else => {
                const buf = [_]u8{c};
                try emitter.write(&buf);
            },
        }
    }
}

/// Emit arguments for an invocation
fn emitArgs(emitter: *CodeEmitter, ctx: *EmissionContext, args: []const ast.Arg, invocation_path: *const ast.DottedPath) !void {
    // Look up the event declaration to check for is_source fields
    const event_decl = if (ctx.ast_items) |items|
        findEventDeclByPath(items, invocation_path)
    else
        null;

    for (args, 0..) |arg, idx| {
        if (idx > 0) {
            try emitter.write(", ");
        }
        try emitter.write(".");
        try emitter.write(arg.name);
        try emitter.write(" = ");

        // Check if this argument should be emitted as a source or expression string literal
        var is_source_arg = false;
        var is_expression_arg = false;
        if (event_decl) |event| {
            for (event.input.fields) |field| {
                if (std.mem.eql(u8, field.name, arg.name)) {
                    if (field.is_source) {
                        is_source_arg = true;
                        break;
                    }
                    if (field.is_expression) {
                        is_expression_arg = true;
                        break;
                    }
                }
            }
        }

        if (is_expression_arg) {
            // CRITICAL: Expression parameters are comptime-only
            const is_comptime_emission = if (ctx.emit_mode) |mode| mode == .comptime_only else false;

            if (!is_comptime_emission) {
                // Build event name for error message
                var event_name_buf: [256]u8 = undefined;
                var event_name_len: usize = 0;

                if (invocation_path.module_qualifier) |mq| {
                    @memcpy(event_name_buf[event_name_len..event_name_len + mq.len], mq);
                    event_name_len += mq.len;
                    event_name_buf[event_name_len] = ':';
                    event_name_len += 1;
                }

                for (invocation_path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        event_name_buf[event_name_len] = '.';
                        event_name_len += 1;
                    }
                    @memcpy(event_name_buf[event_name_len..event_name_len + seg.len], seg);
                    event_name_len += seg.len;
                }

                const event_name = event_name_buf[0..event_name_len];

                if (DEBUG) std.debug.print("\n", .{});
                if (DEBUG) std.debug.print("ERROR: Comptime event '{s}' with Expression parameter reached runtime emission\n", .{event_name});
                if (DEBUG) std.debug.print("Expression parameter: {s}\n", .{arg.name});
                if (DEBUG) std.debug.print("\n", .{});

                return error.ComptimeEventNotTransformed;
            }

            // In comptime_only mode: emit the expression value as a string literal
            try emitter.write("\"");
            for (arg.value) |c| {
                switch (c) {
                    '"' => try emitter.write("\\\""),
                    '\\' => try emitter.write("\\\\"),
                    '\n' => try emitter.write("\\n"),
                    '\r' => try emitter.write("\\r"),
                    '\t' => try emitter.write("\\t"),
                    else => {
                        const buf = [_]u8{c};
                        try emitter.write(&buf);
                    },
                }
            }
            try emitter.write("\"");
        } else if (is_source_arg) {
            // CRITICAL: Only error if we're NOT in comptime_only mode
            // In comptime_only mode, we're emitting to backend_output_emitted.zig which SHOULD contain Source parameters
            // The error only applies to runtime emission (when the transform didn't run)
            const is_comptime_emission = if (ctx.emit_mode) |mode| mode == .comptime_only else false;

            if (!is_comptime_emission) {
                // USER ERROR: Source parameter reached runtime emission
                // This means the comptime handler didn't transform this invocation during evaluate_comptime

                // Build event name for error message
                var event_name_buf: [256]u8 = undefined;
                var event_name_len: usize = 0;

                if (invocation_path.module_qualifier) |mq| {
                    @memcpy(event_name_buf[event_name_len..event_name_len + mq.len], mq);
                    event_name_len += mq.len;
                    event_name_buf[event_name_len] = ':';
                    event_name_len += 1;
                }

                for (invocation_path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        event_name_buf[event_name_len] = '.';
                        event_name_len += 1;
                    }
                    @memcpy(event_name_buf[event_name_len..event_name_len + seg.len], seg);
                    event_name_len += seg.len;
                }

                const event_name = event_name_buf[0..event_name_len];

                // Print helpful error message to stderr
                if (DEBUG) std.debug.print("\n", .{});
                if (DEBUG) std.debug.print("ERROR: Comptime event '{s}' with Source parameter reached runtime emission\n", .{event_name});
                if (DEBUG) std.debug.print("\n", .{});
                if (DEBUG) std.debug.print("This means the comptime handler didn't transform this invocation into runtime code.\n", .{});
                if (DEBUG) std.debug.print("\n", .{});
                if (DEBUG) std.debug.print("Check your ~proc {s} implementation:\n", .{event_name});
                if (DEBUG) std.debug.print("  - It should execute during the evaluate_comptime pass\n", .{});
                if (DEBUG) std.debug.print("  - It should generate runtime code to replace this invocation\n", .{});
                if (DEBUG) std.debug.print("  - The generated code should NOT contain Source parameters\n", .{});
                if (DEBUG) std.debug.print("\n", .{});
                if (DEBUG) std.debug.print("Source parameter: {s}\n", .{arg.name});
                if (DEBUG) std.debug.print("\n", .{});

                return error.ComptimeEventNotTransformed;
            }

            // In comptime_only mode: emit the source argument normally
            // This will be a Source struct with .text, .scope.bindings, etc.
            try emitValue(emitter, ctx, arg.value);
        } else {
            try emitValue(emitter, ctx, arg.value);
        }
    }
}

/// Emit a value expression (may reference input fields)
fn emitValue(emitter: *CodeEmitter, ctx: *EmissionContext, value: []const u8) !void {
    // If we have an input_var and input_fields, replace input field references
    if (ctx.input_var) |input_var| {
        if (ctx.input_fields) |fields| {
            // Parse the expression and replace field references with input_var.field
            try emitValueWithInputPrefixing(emitter, value, input_var, fields);
            return;
        }
    }

    // Otherwise write value as-is
    try emitter.write(value);
}

/// Emit a value expression with binding substitution (for tap pipeline emission)
fn emitValueWithBindingSubstitution(
    emitter: *CodeEmitter,
    value: []const u8,
    substitution: ?BindingSubstitution,
) !void {
    if (substitution == null) {
        // No substitution needed
        try emitter.write(value);
        return;
    }

    const sub = substitution.?;
    var i: usize = 0;
    var in_string = false;
    var in_char = false;

    while (i < value.len) {
        const c = value[i];

        // Track string literals
        if (!in_char and c == '"' and !isEscaped(value, i)) {
            in_string = !in_string;
            try emitter.write(value[i..i+1]);
            i += 1;
            continue;
        }

        // Track char literals
        if (!in_string and c == '\'' and !isEscaped(value, i)) {
            in_char = !in_char;
            try emitter.write(value[i..i+1]);
            i += 1;
            continue;
        }

        // If we're in a string or char literal, just emit as-is
        if (in_string or in_char) {
            try emitter.write(value[i..i+1]);
            i += 1;
            continue;
        }

        // Check for identifiers
        if (isIdentStartChar(c)) {
            // Find the end of the identifier
            var j = i + 1;
            while (j < value.len and isIdentChar(value[j])) {
                j += 1;
            }

            const identifier = value[i..j];

            // Check if this matches the binding we want to substitute
            if (std.mem.eql(u8, identifier, sub.from)) {
                // Check word boundaries
                const before_ok = i == 0 or (!isIdentChar(value[i-1]) and value[i-1] != '@');
                const after_ok = j >= value.len or !isIdentChar(value[j]);

                if (before_ok and after_ok) {
                    // Substitute
                    try emitter.write(sub.to);
                    i = j;
                    continue;
                }
            }

            // Not a match, emit as-is
            try emitter.write(identifier);
            i = j;
            continue;
        }

        // Not an identifier, just emit the character
        try emitter.write(value[i..i+1]);
        i += 1;
    }
}

/// Emit a value expression, replacing input field references with input_var.field
fn emitValueWithInputPrefixing(
    emitter: *CodeEmitter,
    value: []const u8,
    input_var: []const u8,
    input_fields: []const ast.Field,
) !void {
    var i: usize = 0;
    var in_string = false;
    var in_char = false;

    while (i < value.len) {
        const c = value[i];

        // Track string literals
        if (!in_char and c == '"' and !isEscaped(value, i)) {
            in_string = !in_string;
            try emitter.write(value[i..i+1]);
            i += 1;
            continue;
        }

        // Track char literals
        if (!in_string and c == '\'' and !isEscaped(value, i)) {
            in_char = !in_char;
            try emitter.write(value[i..i+1]);
            i += 1;
            continue;
        }

        // If we're in a string or char literal, just emit as-is
        if (in_string or in_char) {
            try emitter.write(value[i..i+1]);
            i += 1;
            continue;
        }

        // Check for identifiers
        if (isIdentStartChar(c)) {
            // Find the end of the identifier
            var j = i + 1;
            while (j < value.len and isIdentChar(value[j])) {
                j += 1;
            }

            // Check if this identifier is an input field reference
            if (isInputFieldReference(value, i, j, input_fields)) {
                // Emit as input_var.field
                try emitter.write(input_var);
                try emitter.write(".");
                try emitter.write(value[i..j]);
            } else {
                // Not a field reference, emit as-is
                try emitter.write(value[i..j]);
            }

            i = j;
            continue;
        }

        // Not an identifier, just emit the character
        try emitter.write(value[i..i+1]);
        i += 1;
    }
}

// ============================================================================
// EXPRESSION EMISSION (for when clauses)
// ============================================================================

/// Binding substitution type for tap emission
const BindingSubstitution = struct {
    from: []const u8,
    to: []const u8,
};

/// Emit an AST expression as Zig code with optional binding substitution
fn emitExpression(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    expr: *const ast.Expression,
    binding_substitution: ?BindingSubstitution,
) anyerror!void {
    switch (expr.node) {
        .identifier => |ident| {
            // Check if we need to substitute this identifier
            if (binding_substitution) |sub| {
                if (std.mem.eql(u8, ident, sub.from)) {
                    try emitter.write(sub.to);
                    return;
                }
            }
            try emitter.write(ident);
        },
        .field_access => |fa| {
            try emitExpression(emitter, ctx, fa.object, binding_substitution);
            try emitter.write(".");
            try emitter.write(fa.field);
        },
        .binary => |bin| {
            try emitter.write("(");
            try emitExpression(emitter, ctx, bin.left, binding_substitution);
            try emitter.write(" ");
            try emitBinaryOperator(emitter, bin.op);
            try emitter.write(" ");
            try emitExpression(emitter, ctx, bin.right, binding_substitution);
            try emitter.write(")");
        },
        .unary => |un| {
            try emitUnaryOperator(emitter, un.op);
            try emitter.write("(");
            try emitExpression(emitter, ctx, un.operand, binding_substitution);
            try emitter.write(")");
        },
        .literal => |lit| {
            switch (lit) {
                .number => |n| try emitter.write(n),
                .string => |s| {
                    try emitter.write("\"");
                    try emitter.write(s);
                    try emitter.write("\"");
                },
                .boolean => |b| {
                    if (b) {
                        try emitter.write("true");
                    } else {
                        try emitter.write("false");
                    }
                },
            }
        },
        .grouped => |g| {
            try emitter.write("(");
            try emitExpression(emitter, ctx, g, binding_substitution);
            try emitter.write(")");
        },
    }
}

/// Emit a binary operator
fn emitBinaryOperator(emitter: *CodeEmitter, op: ast.BinaryOperator) !void {
    switch (op) {
        .add => try emitter.write("+"),
        .subtract => try emitter.write("-"),
        .multiply => try emitter.write("*"),
        .divide => try emitter.write("/"),
        .modulo => try emitter.write("%"),
        .equal => try emitter.write("=="),
        .not_equal => try emitter.write("!="),
        .less => try emitter.write("<"),
        .less_equal => try emitter.write("<="),
        .greater => try emitter.write(">"),
        .greater_equal => try emitter.write(">="),
        .and_op => try emitter.write("and"),
        .or_op => try emitter.write("or"),
        .string_concat => try emitter.write("++"),
    }
}

/// Emit a unary operator
fn emitUnaryOperator(emitter: *CodeEmitter, op: ast.UnaryOperator) !void {
    switch (op) {
        .not => try emitter.write("!"),
        .negate => try emitter.write("-"),
    }
}

/// Emit a list of continuations as a switch statement
fn emitContinuationList(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    continuations: []const ast.Continuation,
    prev_result: []const u8,
    result_counter: *usize,
    is_partial_switch: bool,
) anyerror!void {
    if (continuations.len == 0) {
        return;
    }

    // Check if this is a void event continuation (empty branch name)
    // For void events, we don't emit a switch - just execute the pipeline directly
    const is_void_continuation = continuations.len == 1 and
                                  std.mem.eql(u8, continuations[0].branch, "");

    if (is_void_continuation) {
        // Void event - execute pipeline directly without switch
        try emitContinuationBody(emitter, ctx, &continuations[0], result_counter);
        return;
    }

    // If only ONE branch, we can access the payload directly without a switch!
    // This is the KEY to making explicit while conditions work with Version 11's pattern
    if (continuations.len == 1) {
        const cont = &continuations[0];

        // Use explicit binding if provided, otherwise generate unique name to avoid collisions
        // (multiple events may have same branch name like ".done")
        // Special case: if binding is "_" (discard), treat as no binding
        const binding_name = blk: {
            if (cont.binding) |b| {
                if (!std.mem.eql(u8, b, "_")) {
                    break :blk b;
                }
            }
            // No binding or "_" - generate unique binding: prev_result + "_" + branch
            const unique = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{prev_result, cont.branch});
            break :blk unique;
        };

        // Track if we need to free the binding name (if we generated it)
        const should_free_binding = if (cont.binding) |b| std.mem.eql(u8, b, "_") else true;
        defer if (should_free_binding) ctx.allocator.free(binding_name);

        // Check if binding is actually used in continuation body
        const binding_used = binding_name.len > 0 and continuationUsesBinding(cont, binding_name);

        // Check if binding has [mutable] annotation (from binding site, e.g., | result r[mutable] |>)
        const needs_mutable = bindingHasMutableAnnotation(cont);

        // ALWAYS create binding - tap args might reference it even if original pipeline doesn't
        // Emit: var/const binding = result.branch;
        try emitter.writeIndent();
        if (needs_mutable) {
            try emitter.write("var ");
        } else {
            try emitter.write("const ");
        }
        try writeBranchName(emitter, binding_name);
        try emitter.write(" = ");
        try emitter.write(prev_result);
        try emitter.write(".");
        try writeBranchName(emitter, cont.branch);
        try emitter.write(";\n");

        // Suppress unused variable warning if binding is not referenced
        if (!binding_used) {
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try writeBranchName(emitter, binding_name);
            try emitter.write(";\n");
        }

        // Check if continuation has a when-clause condition
        // (e.g., from tap: ~tap(foo -> *) | branch b when b.flag |> handler())
        if (cont.condition) |condition| {
            // Wrap in if statement
            try emitter.writeIndent();
            try emitter.write("if (");
            if (cont.condition_expr) |expr| {
                try emitExpression(emitter, ctx, expr, null);
            } else {
                try emitter.write(condition);
            }
            try emitter.write(") {\n");
            emitter.indent();
            try emitContinuationBody(emitter, ctx, cont, result_counter);
            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");
        } else {
            // No when-clause - execute continuation body directly
            try emitContinuationBody(emitter, ctx, cont, result_counter);
        }
        return;
    }

    // Group continuations by branch name to handle when-clauses
    const continuation_branch_groups = try groupContinuationsByBranch(
        ctx.allocator,
        continuations
    );
    defer {
        for (continuation_branch_groups) |group| {
            ctx.allocator.free(group.continuations);
        }
        ctx.allocator.free(continuation_branch_groups);
    }

    // Check for |? catch-all continuation
    var catchall_cont: ?*const ast.Continuation = null;
    for (continuations) |*cont| {
        if (cont.is_catchall) {
            catchall_cont = cont;
            break;
        }
    }

    // Multiple branches - emit switch statement to extract union payloads
    try emitter.writeIndent();
    try emitter.write("switch (");
    try emitter.write(prev_result);
    try emitter.write(") {\n");
    emitter.indent();

    for (continuation_branch_groups) |group| {
        // Skip catch-all (it has branch = "?" and will be handled separately)
        if (std.mem.eql(u8, group.branch_name, "?")) continue;

        if (group.continuations.len == 1) {
            // Single continuation - emit as normal
            try emitContinuationCase(emitter, ctx, group.continuations[0], result_counter);
        } else {
            // Multiple continuations for same branch - emit case with if/else chain
            try emitWhenClauseCase(emitter, ctx, group, result_counter);
        }
    }

    // If there's a catch-all, emit cases for unhandled optional branches
    if (catchall_cont) |catchall| {
        // Find which branches are explicitly handled
        var handled_branches = std.StringHashMap(void).init(ctx.allocator);
        defer handled_branches.deinit();

        for (continuation_branch_groups) |group| {
            if (std.mem.eql(u8, group.branch_name, "?")) continue; // Skip catch-all itself
            try handled_branches.put(group.branch_name, {});
        }

        // Find the event definition to get optional branches
        if (ctx.current_source_event) |source_event| {
            // Look up event in AST
            if (ctx.ast_items) |items| {
                const event_decl = findEventByName(items, source_event, ctx.allocator, ctx.main_module_name);
                if (event_decl) |event| {
                    // Emit cases for unhandled optional branches
                    for (event.branches) |branch| {
                        if (!branch.is_optional) continue; // Only optional branches
                        if (handled_branches.contains(branch.name)) continue; // Already handled

                        // Emit switch case for this unhandled optional branch
                        try emitter.writeIndent();
                        try emitter.write(".");
                        try writeBranchName(emitter, branch.name);
                        try emitter.write(" => |_| {\n"); // Discard payload for now
                        emitter.indent();

                        // Execute catch-all pipeline
                        try emitContinuationBody(emitter, ctx, catchall, result_counter);

                        emitter.dedent();
                        try emitter.writeIndent();
                        try emitter.write("},\n");
                    }
                }
            }
        }
    }

    // If this is a partial switch (not all branches), add else => unreachable
    if (is_partial_switch) {
        try emitter.writeIndent();
        try emitter.write("else => unreachable,\n");
    }

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write("}\n");
}

/// Emit continuations with explicit unreachable cases for specific branches
/// Used when a while loop guards certain branches - we can't use `else => unreachable`
/// because Zig might determine all cases are handled via control flow analysis,
/// but we also can't omit the guarded branches because Zig's exhaustiveness check
/// doesn't always track the while condition.
fn emitContinuationListWithUnreachableBranches(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    continuations: []const ast.Continuation,
    prev_result: []const u8,
    result_counter: *usize,
    unreachable_branches: []const []const u8,
) anyerror!void {
    if (continuations.len == 0 and unreachable_branches.len == 0) {
        return;
    }

    try emitter.writeIndent();
    try emitter.write("switch (");
    try emitter.write(prev_result);
    try emitter.write(") {\n");
    emitter.indent();

    // Emit actual continuation cases
    for (continuations) |*cont| {
        try emitContinuationCase(emitter, ctx, cont, result_counter);
    }

    // Emit explicit unreachable cases for guarded branches
    for (unreachable_branches) |branch| {
        try emitter.writeIndent();
        try emitter.write(".");
        // Handle reserved Zig keywords
        if (CodeEmitter.isZigKeyword(branch)) {
            try emitter.write("@\"");
            try emitter.write(branch);
            try emitter.write("\"");
        } else {
            try emitter.write(branch);
        }
        try emitter.write(" => unreachable,\n");
    }

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write("}\n");
}

/// Emit a single continuation case (.branch => |binding| { ... })
fn emitContinuationCase(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
    result_counter: *usize,
) !void {
    const binding_name = cont.binding orelse cont.branch;

    // Query matching taps BEFORE deciding on binding to check if taps need it
    var matching_taps: []const tap_registry_module.TapEntry = &[_]tap_registry_module.TapEntry{};
    var destination: ?[]const u8 = null;
    var taps_use_binding = false;

    if (ctx.tap_registry) |registry| {
        if (ctx.current_source_event) |source| {
            // Find destination event from continuation step (if any)
            if (cont.node) |step| {
                if (step == .invocation) {
                    destination = try buildCanonicalEventName(&step.invocation.path, ctx.allocator, ctx.main_module_name);
                }
            }

            // Query registry for matching taps
            matching_taps = try registry.getMatchingTaps(source, cont.branch, destination);

            // Check if any tap has a binding (meaning it needs the continuation payload)
            // Metatype taps don't need the continuation payload (they synthesize metadata)
            for (matching_taps) |tap| {
                // Check if this tap uses a metatype branch
                const is_metatype_tap = std.mem.eql(u8, tap.branch, "Transition") or
                                       std.mem.eql(u8, tap.branch, "Profile") or
                                       std.mem.eql(u8, tap.branch, "Audit");

                // Metatype taps don't use the continuation payload
                if (is_metatype_tap) continue;

                if (tap.tap_binding) |tap_bind| {
                    // Tap has a binding, check if its step references it
                    if (tap.step) |step| {
                        switch (step) {
                            .invocation => |inv| {
                                for (inv.args) |arg| {
                                    if (containsIdentifier(arg.value, tap_bind)) {
                                        taps_use_binding = true;
                                        break;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    if (taps_use_binding) break;
                }
            }
        }
    }
    defer if (destination) |dest| ctx.allocator.free(dest);
    defer if (matching_taps.len > 0) ctx.allocator.free(matching_taps);

    try emitter.writeIndent();
    try emitter.write(".");
    try writeBranchName(emitter, cont.branch);

    // Check if binding is actually used in continuation body OR by taps
    const binding_used = binding_name.len > 0 and (continuationUsesBinding(cont, binding_name) or taps_use_binding);

    // Check if binding has [mutable] annotation (from binding site: | result r[mutable] |>)
    const needs_mutable_capture = bindingHasMutableAnnotation(cont);

    // Check if branch has payload fields - empty payloads shouldn't be captured
    const has_payload_fields = if (ctx.current_source_event) |event_name|
        branchHasPayloadFields(ctx, event_name, cont.branch)
    else
        true; // Conservative: assume has fields if we can't check

    // Only emit capture syntax if the branch has payload fields
    if (has_payload_fields) {
        // Emit capture syntax: |*name| for mutable, |name| for const
        if (needs_mutable_capture and binding_used) {
            try emitter.write(" => |*");
        } else {
            try emitter.write(" => |");
        }

        if (binding_name.len == 0 or !binding_used) {
            try emitter.write("_");
        } else {
            try writeBranchName(emitter, binding_name);
        }
        try emitter.write("| {\n");
    } else {
        // Empty payload - no capture needed
        try emitter.write(" => {\n");
    }
    emitter.indent();

    // Set current branch for tap matching (used by label_jump steps)
    const saved_branch = ctx.current_branch;
    ctx.current_branch = cont.branch;
    defer ctx.current_branch = saved_branch;

    // Taps are now in the AST via tap_transformer
    try emitContinuationBody(emitter, ctx, cont, result_counter);

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write("},\n");
}

/// Emit a switch case with when-clause if/else chain for multiple continuations
fn emitWhenClauseCase(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    group: BranchGroup,
    result_counter: *usize,
) !void {
    const first_cont = group.continuations[0];
    const binding_name = first_cont.binding orelse first_cont.branch;

    // Check if any continuation in the group wants mutable binding
    var needs_mutable = false;
    for (group.continuations) |cont| {
        if (bindingHasMutableAnnotation(cont)) {
            needs_mutable = true;
            break;
        }
    }

    // Emit the branch case
    try emitter.writeIndent();
    try emitter.write(".");
    try writeBranchName(emitter, group.branch_name);
    if (needs_mutable) {
        try emitter.write(" => |*");
    } else {
        try emitter.write(" => |");
    }
    try writeBranchName(emitter, binding_name);
    try emitter.write("| {\n");
    emitter.indent();

    // Emit if/else chain for when-clauses
    for (group.continuations, 0..) |cont, idx| {
        try emitter.writeIndent();

        if (cont.condition) |condition| {
            // When-clause - emit if or else if
            if (idx == 0) {
                try emitter.write("if ");
            } else {
                try emitter.write("else if ");
            }
            try emitter.write(condition);
            try emitter.write(" {\n");
        } else {
            // No when-clause - this is the else case
            try emitter.write("else {\n");
        }

        emitter.indent();

        // Set current branch for tap matching
        const saved_branch = ctx.current_branch;
        ctx.current_branch = cont.branch;
        defer ctx.current_branch = saved_branch;

        // Emit continuation body
        try emitContinuationBody(emitter, ctx, cont, result_counter);

        emitter.dedent();
        try emitter.writeIndent();
        try emitter.write("}\n");
    }

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write("},\n");
}

/// Check if a label will be mutated by any .label_jump in the continuation tree
/// Returns true if any .label_jump with matching label exists (meaning var is needed)
/// Returns false if only .label_apply exists (meaning const can be used)
fn labelWillBeMutated(label: []const u8, continuations: []const ast.Continuation) bool {
    for (continuations) |cont| {
        // Check step for label_jump
        if (cont.node) |step| {
            if (step == .label_jump) {
                if (std.mem.eql(u8, step.label_jump.label, label)) {
                    // Found a label_jump that mutates this label's state
                    return true;
                }
            }
        }

        // Recursively check nested continuations
        if (labelWillBeMutated(label, cont.continuations)) {
            return true;
        }
    }

    return false;
}

/// Find which branches loop back to a given label
/// Returns a list of branch names that contain @label jumps to this label
/// This is used to emit explicit while conditions like: while (result == .branch1 || result == .branch2)
/// Find which branches loop back to a given label
/// Returns a list of branch names that contain @label jumps to this label
fn findLoopingBranches(
    label: []const u8,
    continuations: []const ast.Continuation,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    var looping_branches = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer looping_branches.deinit(allocator);

    for (continuations) |cont| {
        // Check if this continuation's step contains a jump to our label
        var has_label_jump = false;
        if (cont.node) |step| {
            if (step == .label_jump) {
                if (std.mem.eql(u8, step.label_jump.label, label)) {
                    has_label_jump = true;
                }
            } else if (step == .label_apply) {
                if (std.mem.eql(u8, step.label_apply, label)) {
                    has_label_jump = true;
                }
            }
        }

        // If this branch jumps to the label, add it to the list
        if (has_label_jump) {
            try looping_branches.append(allocator, cont.branch);
        }

        // Also check nested continuations recursively
        const nested_looping = try findLoopingBranches(label, cont.continuations, allocator);
        defer allocator.free(nested_looping);

        // If nested branches loop, this branch effectively loops too
        if (nested_looping.len > 0) {
            // Only add if not already in the list
            var already_added = false;
            for (looping_branches.items) |existing| {
                if (std.mem.eql(u8, existing, cont.branch)) {
                    already_added = true;
                    break;
                }
            }
            if (!already_added) {
                try looping_branches.append(allocator, cont.branch);
            }
        }
    }

    return looping_branches.toOwnedSlice(allocator);
}

/// Emit the body of a continuation (pipeline + nested continuations)
fn isTapInsertedStep(step: *const ast.Step) bool {
    return switch (step.*) {
        .invocation => |inv| inv.inserted_by_tap,
        .metatype_binding => |mb| mb.inserted_by_tap,
        .conditional_block => |cb| cb.inserted_by_tap,
        else => false,
    };
}

fn emitPipelineStep(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
    step: *const ast.Step,
    _: usize,  // absolute_idx - not used with single step design
    result_counter: *usize,
) !void {
    // Note: With single step design, is_last_step and next_is_terminal are always true/false
    // These constants existed for the old multi-step pipeline

    const needs_result = cont.continuations.len > 0;

    const current_result = if (needs_result)
        try std.fmt.allocPrint(ctx.allocator, "{s}{}", .{ ctx.result_prefix, result_counter.* })
    else
        "_";
    defer if (needs_result) ctx.allocator.free(current_result);

    try emitStep(emitter, ctx, step, current_result);

    // Void steps don't produce a result variable:
    // - assignment: just assigns to a mutable binding
    // - inline_code: just emits verbatim code (e.g., print.ln transform)
    const is_void_step = step.* == .assignment or step.* == .inline_code;

    if (needs_result and !std.mem.eql(u8, current_result, "_") and
        step.* != .conditional_block and step.* != .metatype_binding and !is_void_step)
    {
        try emitter.writeIndent();
        try emitter.write("_ = &");
        try emitter.write(current_result);
        try emitter.write(";\n");
    }

    if (needs_result and step.* != .conditional_block and step.* != .metatype_binding and !is_void_step) {
        result_counter.* += 1;
    }
}

pub fn emitContinuationBody(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
    result_counter: *usize,
) !void {
    // Check if step is label_with_invocation
    const has_label_with_inv = if (cont.node) |step| step == .label_with_invocation else false;

    if (has_label_with_inv) {
        const lwi = cont.node.?.label_with_invocation;

        // Look up event definition to get parameter types
        const event_decl = if (ctx.ast_items) |items|
            findEventDeclByPath(items, &lwi.invocation.path)
        else
            null;

        // Determine if label will be mutated by checking for .label_jump
        const label_is_mutable = labelWillBeMutated(lwi.label, cont.continuations);

        // CRITICAL: If mutable, we MUST have type annotations (Zig forbids var with comptime_int)
        if (label_is_mutable and event_decl == null) {
            std.debug.panic("COMPILER BUG: Cannot find event declaration for loop variable when emitting mutable label '{s}'. Event lookup failed for invocation with path segments={}", .{
                lwi.label,
                lwi.invocation.path.segments.len,
            });
        }

        // Emit state variables for loop parameters with type annotations
        for (lwi.invocation.args) |arg| {
            try emitter.writeIndent();
            // Use var if label will be mutated by label_jump, const otherwise
            if (label_is_mutable) {
                try emitter.write("var ");
            } else {
                try emitter.write("const ");
            }
            try emitter.write(lwi.label);
            try emitter.write("_");
            try emitter.write(arg.name);

            // Add type annotation if we found the event
            if (event_decl) |event| {
                // Find the matching field in the event's input
                var found_field = false;
                for (event.input.fields) |field| {
                    if (std.mem.eql(u8, field.name, arg.name)) {
                        try emitter.write(": ");
                        if (field.is_file or field.is_embed_file) {
                            try emitter.write("[]const u8");
                        } else if (field.is_source) {
                            try emitter.write("[]const u8");
                        } else {
                            try writeFieldType(emitter, field, ctx.main_module_name);
                        }
                        found_field = true;
                        break;
                    }
                }

                if (!found_field) {
                    std.debug.panic("COMPILER BUG: Field '{s}' not found in event after checking {} fields!", .{arg.name, event.input.fields.len});
                }
            }

            try emitter.write(" = ");
            try emitter.write(arg.value);
            try emitter.write(";\n");
        }

        // Emit the FIRST invocation BEFORE the loop (to get initial result)
        const result_var = try std.fmt.allocPrint(ctx.allocator, "result_{}", .{result_counter.*});
        defer ctx.allocator.free(result_var);

        try emitter.writeIndent();
        try emitter.write("var ");  // var, not const - we'll update it in the loop!
        try emitter.write(result_var);
        try emitter.write(" = ");
        if (!ctx.is_sync) {
            try emitter.write("try ");
        }
        try emitInvocationTarget(emitter, ctx, &lwi.invocation.path);
        try emitter.write(".handler(.{ ");
        // Use state variables for initial call
        for (lwi.invocation.args, 0..) |arg, idx| {
            if (idx > 0) {
                try emitter.write(", ");
            }
            try emitter.write(".");
            try emitter.write(arg.name);
            try emitter.write(" = ");
            try emitter.write(lwi.label);
            try emitter.write("_");
            try emitter.write(arg.name);
        }
        try emitter.write(" });\n");
        result_counter.* += 1;

        // Register this label in the context map (for cross-level jumps)
        if (ctx.label_contexts) |label_map| {
            // Need to duplicate the result string since result_var will be freed
            const result_copy = try ctx.allocator.dupe(u8, result_var);
            try label_map.put(lwi.label, .{
                .handler_invocation = &lwi.invocation,
                .result_var = result_copy,
            });
        }

        // Find which branches loop back to this label for explicit condition
        const looping_branches = try findLoopingBranches(lwi.label, cont.continuations, ctx.allocator);
        defer ctx.allocator.free(looping_branches);

        // NOW emit the while loop with explicit condition based on looping branches
        try emitter.writeIndent();

        // ALWAYS emit the Zig label (needed for continue :label statements)
        try emitter.write(lwi.label);
        try emitter.write(": ");

        try emitter.write("while (");

        // Emit explicit loop condition
        if (looping_branches.len == 0) {
            // No branches loop - fallback to while(true)
            try emitter.write("true");
        } else if (looping_branches.len == 1) {
            // Single branch loops - emit: while (result == .branch)
            try emitter.write(result_var);
            try emitter.write(" == .");
            try writeBranchName(emitter, looping_branches[0]);
        } else {
            // Multiple branches loop - emit: while ((result == .branch1) or (result == .branch2))
            for (looping_branches, 0..) |branch, idx| {
                if (idx > 0) {
                    try emitter.write(" or ");
                }
                try emitter.write("(");
                try emitter.write(result_var);
                try emitter.write(" == .");
                try writeBranchName(emitter, branch);
                try emitter.write(")");
            }
        }

        try emitter.write(") {\n");
        emitter.indent();

        // Store label context so label_jump can re-call the handler
        ctx.label_handler_invocation = &lwi.invocation;
        ctx.label_result_var = result_var;

        // Emit nested continuations (the switch statement)
        if (cont.continuations.len > 0) {
            // Update current_source_event for tap matching in nested continuations
            const saved_source = ctx.current_source_event;
            const new_source = try buildCanonicalEventName(&lwi.invocation.path, ctx.allocator, ctx.main_module_name);
            ctx.current_source_event = new_source;
            defer {
                if (ctx.current_source_event) |src| {
                    ctx.allocator.free(src);
                }
                ctx.current_source_event = saved_source;
            }

            // ONLY emit looping branches inside the while loop
            if (looping_branches.len > 0) {
                // Build list of looping continuations
                var looping_conts = try std.ArrayList(ast.Continuation).initCapacity(ctx.allocator, looping_branches.len);
                defer looping_conts.deinit(ctx.allocator);

                for (cont.continuations) |nested_cont| {
                    // Check if this continuation is in the looping branches list
                    for (looping_branches) |loop_branch| {
                        if (std.mem.eql(u8, nested_cont.branch, loop_branch)) {
                            try looping_conts.append(ctx.allocator, nested_cont);
                            break;
                        }
                    }
                }

                // Emit switch with only looping branches
                // NOTE: The while loop condition already guarantees only looping branch values are possible.
                // Zig 0.15+ considers the switch exhaustive for those values, so we must NOT emit
                // else => unreachable (it would be "unreachable else prong; all cases handled")
                if (looping_conts.items.len > 0) {
                    try emitContinuationList(emitter, ctx, looping_conts.items, result_var, result_counter, false);
                }
            }
        }

        // Clear label context after continuations
        ctx.label_handler_invocation = null;
        ctx.label_result_var = null;

        // Close the while loop
        emitter.dedent();
        try emitter.writeIndent();
        try emitter.write("}\n");

        // NOW emit switch for NON-LOOPING branches (after the while)
        const has_non_looping_branches = cont.continuations.len > 0 and looping_branches.len < cont.continuations.len;
        if (has_non_looping_branches) {
            // Build list of non-looping continuations
            var non_looping_conts = try std.ArrayList(ast.Continuation).initCapacity(ctx.allocator, cont.continuations.len - looping_branches.len);
            defer non_looping_conts.deinit(ctx.allocator);

            for (cont.continuations) |nested_cont| {
                // Check if this continuation is NOT in the looping branches list
                var is_looping = false;
                for (looping_branches) |loop_branch| {
                    if (std.mem.eql(u8, nested_cont.branch, loop_branch)) {
                        is_looping = true;
                        break;
                    }
                }

                if (!is_looping) {
                    try non_looping_conts.append(ctx.allocator, nested_cont);
                }
            }

            // Emit switch with only non-looping branches
            // NOTE: After the while loop guard, looping branches are IMPOSSIBLE at runtime.
            // However, Zig's exhaustiveness checker doesn't track this via control flow.
            // We must emit explicit `.branch => unreachable` for each looping branch
            // instead of `else => unreachable` (which Zig 0.15 rejects when it CAN track exhaustiveness).
            if (non_looping_conts.items.len > 0) {
                // Need to restore source event context for the non-looping switch
                const saved_source_2 = ctx.current_source_event;
                const new_source_2 = try buildCanonicalEventName(&lwi.invocation.path, ctx.allocator, ctx.main_module_name);
                ctx.current_source_event = new_source_2;
                defer {
                    if (ctx.current_source_event) |src| {
                        ctx.allocator.free(src);
                    }
                    ctx.current_source_event = saved_source_2;
                }

                // Pass the looping branches so we can emit explicit unreachable cases for them
                try emitContinuationListWithUnreachableBranches(emitter, ctx, non_looping_conts.items, result_var, result_counter, looping_branches);
            }
        } else if (cont.continuations.len > 0 and looping_branches.len == cont.continuations.len) {
            // ALL branches are looping - the while loop only exits via return statements
            // Tell Zig this code path is unreachable
            try emitter.writeIndent();
            try emitter.write("unreachable;\n");
        }

        // Label case is done - no remaining steps to process
    } else {
        // Normal case - no label_with_invocation
        // Check if this is a void step (like assignment or inline_code) that doesn't produce a result
        const is_void_step = if (cont.node) |step| (step == .assignment or step == .inline_code) else false;

        if (cont.node) |*step| {
            try emitPipelineStep(emitter, ctx, cont, step, 0, result_counter);
        }

        // Emit nested continuations
        if (cont.continuations.len > 0) {
            if (is_void_step) {
                // Void step (like assignment) - emit continuations directly as void chain
                // Each continuation should be emitted without needing a result to switch on
                for (cont.continuations) |*nested_cont| {
                    try emitContinuationBody(emitter, ctx, nested_cont, result_counter);
                }
            } else {
                // Normal case - use the last result for continuation switching
                if (result_counter.* == 0) {
                    return;
                }

                const last_result = try std.fmt.allocPrint(
                    ctx.allocator,
                    "{s}{}",
                    .{ ctx.result_prefix, result_counter.* - 1 },
                );
                defer ctx.allocator.free(last_result);

                // Find the invocation in the step to update current_source_event
                // This ensures taps on nested invocations match correctly
                var last_invocation: ?*const ast.Invocation = null;
                if (cont.node) |step| {
                    if (step == .invocation) {
                        last_invocation = &step.invocation;
                    }
                }

                // If we found an invocation, temporarily update current_source_event
                const saved_source = ctx.current_source_event;
                if (last_invocation) |inv| {
                    const new_source = try buildCanonicalEventName(&inv.path, ctx.allocator, ctx.main_module_name);
                    ctx.current_source_event = new_source;
                    defer {
                        if (ctx.current_source_event) |src| {
                            ctx.allocator.free(src);
                        }
                        ctx.current_source_event = saved_source;
                    }

                    try emitContinuationList(emitter, ctx, cont.continuations, last_result, result_counter, false);
                } else {
                    // No invocation in step, keep current source
                    try emitContinuationList(emitter, ctx, cont.continuations, last_result, result_counter, false);
                }
            }
        }
    }
}

/// Emit a single step in a pipeline
fn emitStep(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    step: *const ast.Step,
    result_var: []const u8,
) !void {
    // Check if this step is from an opaque tap - if so, skip nested tap-inserted steps
    const is_from_opaque_tap = switch (step.*) {
        .invocation => |inv| inv.from_opaque_tap,
        .metatype_binding => |mb| mb.from_opaque_tap,
        .conditional_block => |cb| cb.from_opaque_tap,
        else => false,
    };

    // Skip tap-inserted steps if we're inside an opaque tap (prevents infinite recursion)
    if (ctx.skip_tap_inserted_steps) {
        const is_tap_inserted = switch (step.*) {
            .invocation => |inv| inv.inserted_by_tap,
            .metatype_binding => |mb| mb.inserted_by_tap,
            .conditional_block => |cb| cb.inserted_by_tap,
            else => false,
        };
        if (is_tap_inserted) {
            return; // Skip this step entirely
        }
    }

    // Set skip flag for the duration of this step's emission if it's from an opaque tap
    const old_skip_tap_inserted_steps = ctx.skip_tap_inserted_steps;
    if (is_from_opaque_tap) {
        ctx.skip_tap_inserted_steps = true;
    }
    defer ctx.skip_tap_inserted_steps = old_skip_tap_inserted_steps;

    switch (step.*) {
        .invocation => |*inv| {
            try emitInvocation(emitter, ctx, inv, result_var);
        },
        .branch_constructor => |*bc| {
            try emitter.writeIndent();
            // If result_var is "_", this is a terminal branch constructor - emit as return
            const is_terminal = std.mem.eql(u8, result_var, "_");
            if (is_terminal) {
                try emitter.write("return ");
            }
            try emitBranchConstructor(emitter, ctx, bc, is_terminal);
            try emitter.write(";\n");
        },
        .terminal => {
            // Terminal steps don't create variables
        },
        .conditional_block => |*cb| {
            // Emit if (condition) { steps }
            try emitter.writeIndent();
            try emitter.write("if (");

            // Emit condition (either string or expression)
            if (cb.condition_expr) |expr| {
                try emitExpression(emitter, ctx, expr, null);
            } else if (cb.condition) |cond| {
                try emitter.write(cond);
            }

            try emitter.write(") {\n");
            emitter.indent();

            // Emit all steps inside the conditional block
            var step_idx: usize = 0;
            for (cb.nodes) |inner_step| {
                // Skip result variable for terminal steps (they don't create variables)
                const needs_result = inner_step != .terminal;

                const inner_result_var = if (needs_result) blk: {
                    // Generate result variable for non-terminal steps
                    var result_buf: [64]u8 = undefined;
                    break :blk try std.fmt.bufPrint(&result_buf, "cond_result_{d}", .{step_idx});
                } else "_";

                try emitStep(emitter, ctx, &inner_step, inner_result_var);

                // Suppress unused variable warning (tap results inside conditionals might not be used)
                // But only for steps that actually create variables
                if (needs_result and !std.mem.eql(u8, inner_result_var, "_")) {
                    try emitter.writeIndent();
                    try emitter.write("_ = &");
                    try emitter.write(inner_result_var);
                    try emitter.write(";\n");
                }

                if (needs_result) {
                    step_idx += 1;
                }
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");
        },
        .metatype_binding => |*mb| {
            // Emit metatype construction (Profile/Transition/Audit)
            // Transition uses enum literals (fast), Profile uses strings (heavier with timing)
            try emitter.writeIndent();
            try emitter.write("const ");
            try emitter.write(mb.binding);
            try emitter.write(" = taps.");
            try emitter.write(mb.metatype);
            try emitter.write("{\n");
            emitter.indent();

            const is_transition = std.mem.eql(u8, mb.metatype, "Transition");

            // .source field - enum literal for Transition, string for Profile
            try emitter.writeIndent();
            if (is_transition) {
                // Transition: .source = .compiler_context_create (enum literal)
                try emitter.write(".source = .");
                try canonicalNameToEnumTag(emitter, mb.source_event);
                try emitter.write(",\n");
            } else {
                // Profile/Audit: .source = "main:http.request" (string literal)
                try emitter.write(".source = \"");
                try emitter.write(mb.source_event);
                try emitter.write("\",\n");
            }

            // .destination field (null for terminal)
            try emitter.writeIndent();
            if (mb.dest_event) |dest| {
                if (is_transition) {
                    // Transition: .destination = .compiler_coordinate_frontend (enum literal)
                    try emitter.write(".destination = .");
                    try canonicalNameToEnumTag(emitter, dest);
                    try emitter.write(",\n");
                } else {
                    // Profile/Audit: .destination = "main:http.response" (string literal)
                    try emitter.write(".destination = \"");
                    try emitter.write(dest);
                    try emitter.write("\",\n");
                }
            } else {
                try emitter.write(".destination = null,\n");
            }

            // .branch field - enum literal for Transition, string for Profile
            // Use __void for empty branches (void event completion)
            try emitter.writeIndent();
            if (is_transition) {
                // Transition: .branch = .created (enum literal)
                try emitter.write(".branch = .");
                if (mb.branch.len == 0) {
                    try emitter.write("__void");
                } else {
                    try emitter.write(mb.branch);
                }
                try emitter.write(",\n");
            } else {
                // Profile/Audit: .branch = "done" (string literal)
                try emitter.write(".branch = \"");
                if (mb.branch.len == 0) {
                    try emitter.write("__void");
                } else {
                    try emitter.write(mb.branch);
                }
                try emitter.write("\",\n");
            }

            // .timestamp_ns field - ONLY for Profile/Audit (not Transition)
            if (!is_transition) {
                try emitter.writeIndent();
                try emitter.write(".timestamp_ns = __koru_std.time.nanoTimestamp(),\n");
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("};\n");
        },
        .deref => |*deref| {
            try emitter.writeIndent();
            try emitter.write("var ");
            try emitter.write(result_var);
            try emitter.write(" = ");
            try emitter.write(deref.target);
            if (deref.args) |args| {
                try emitter.write("(.{ ");
                // For deref, we don't have a static path to look up the event
                // Create a dummy empty path - emitArgs will skip is_source check if event_decl is null
                const empty_path = ast.DottedPath{ .module_qualifier = null, .segments = &[_][]const u8{} };
                try emitArgs(emitter, ctx, args, &empty_path);
                try emitter.write(" })");
            }
            try emitter.write(";\n");
        },
        .label_with_invocation => |*lwi| {
            // Emit label and invocation
            try emitter.writeIndent();
            try emitter.write(lwi.label);
            try emitter.write(": const ");
            try emitter.write(result_var);
            try emitter.write(" = ");
            try emitInvocationTarget(emitter, ctx, &lwi.invocation.path);
            try emitter.write(".handler(.{ ");
            try emitArgs(emitter, ctx, lwi.invocation.args, &lwi.invocation.path);
            try emitter.write(" });\n");
        },
        .label_apply => |label_name| {
            // Simple label jump without arguments (e.g., @label)
            // Look up the target label's context (same as label_jump, but no args to update)
            var target_ctx: ?LabelContext = null;
            if (ctx.label_contexts) |label_map| {
                target_ctx = label_map.get(label_name);
            }

            // If not in map, try current label context (for same-level or subflow labels)
            if (target_ctx == null) {
                if (ctx.label_handler_invocation != null and ctx.label_result_var != null) {
                    target_ctx = .{
                        .handler_invocation = ctx.label_handler_invocation.?,
                        .result_var = ctx.label_result_var.?,
                    };
                }
            }

            // If we have a target context (from map OR current), call the handler
            if (target_ctx) |tctx| {
                // Call the TARGET label's handler using label's state variables
                try emitter.writeIndent();
                try emitter.write(tctx.result_var);
                try emitter.write(" = ");
                if (!ctx.is_sync) {
                    try emitter.write("try ");
                }
                try emitInvocationTarget(emitter, ctx, &tctx.handler_invocation.path);
                try emitter.write(".handler(.{ ");
                // Pass state variables: label_name + "_" + arg_name
                for (tctx.handler_invocation.args, 0..) |arg, idx| {
                    if (idx > 0) {
                        try emitter.write(", ");
                    }
                    try emitter.write(".");
                    try emitter.write(arg.name);
                    try emitter.write(" = ");
                    try emitter.write(label_name);
                    try emitter.write("_");
                    try emitter.write(arg.name);
                }
                try emitter.write(" });\n");
            }

            // ALWAYS emit continue :label
            try emitter.writeIndent();
            try emitter.write("continue :");
            try emitter.write(label_name);
            try emitter.write(";\n");
        },
        .label_jump => |*lj| {
            // Update state variables for the next iteration
            for (lj.args) |arg| {
                try emitter.writeIndent();
                try emitter.write(lj.label);
                try emitter.write("_");
                try emitter.write(arg.name);
                try emitter.write(" = ");
                try emitValue(emitter, ctx, arg.value);
                try emitter.write(";\n");
            }

            // Look up the target label's context
            // First try the map (for cross-level jumps within a flow)
            var target_ctx: ?LabelContext = null;
            if (ctx.label_contexts) |label_map| {
                target_ctx = label_map.get(lj.label);
            }

            // If not in map, try current label context (for same-level or subflow labels)
            if (target_ctx == null) {
                if (ctx.label_handler_invocation != null and ctx.label_result_var != null) {
                    target_ctx = .{
                        .handler_invocation = ctx.label_handler_invocation.?,
                        .result_var = ctx.label_result_var.?,
                    };
                }
            }

            // If we have a target context (from map OR current), call the handler
            if (target_ctx) |tctx| {
                // Call the TARGET label's handler with updated state variables
                try emitter.writeIndent();
                try emitter.write(tctx.result_var);
                try emitter.write(" = ");
                if (!ctx.is_sync) {
                    try emitter.write("try ");
                }
                try emitInvocationTarget(emitter, ctx, &tctx.handler_invocation.path);
                try emitter.write(".handler(.{ ");
                for (lj.args, 0..) |arg, idx| {
                    if (idx > 0) {
                        try emitter.write(", ");
                    }
                    try emitter.write(".");
                    try emitter.write(arg.name);
                    try emitter.write(" = ");
                    try emitter.write(lj.label);
                    try emitter.write("_");
                    try emitter.write(arg.name);
                }
                try emitter.write(" });\n");
            }

            // ALWAYS emit continue :label (works for same-level and cross-level jumps)
            try emitter.writeIndent();
            try emitter.write("continue :");
            try emitter.write(lj.label);
            try emitter.write(";\n");
        },
        .inline_code => |code| {
            // Emit verbatim Zig code (from transforms like ~if, ~for)
            try emitter.writeIndent();
            try emitter.write(code);
            try emitter.write("\n");
        },
        .foreach => |fe| {
            // Emit for loop with proper AST body
            const raw_binding = ast.NamedBranch.getBinding(fe.branches, "each") orelse "_";
            const each_body = ast.NamedBranch.getBody(fe.branches, "each");
            const done_body = ast.NamedBranch.getBody(fe.branches, "done");

            // Generate unique binding for default names to avoid shadowing in nested loops
            var binding_buf: [64]u8 = undefined;
            const each_binding = if (std.mem.eql(u8, raw_binding, "_")) blk: {
                const for_id = ctx.for_counter;
                ctx.for_counter += 1;
                break :blk std.fmt.bufPrint(&binding_buf, "__for_item_{d}", .{for_id}) catch raw_binding;
            } else raw_binding;

            try emitter.writeIndent();
            try emitter.write("for (");
            try emitter.write(fe.iterable);
            try emitter.write(") |");
            try emitter.write(each_binding);
            try emitter.write("| {\n");
            emitter.indent();

            // Suppress unused capture warning (binding might not be used in body)
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try emitter.write(each_binding);
            try emitter.write(";\n");

            // Emit body continuations
            // Process each continuation: emit its node, then handle nested continuations
            var step_idx: usize = 0;

            // Set result prefix to "loop_result_" for nested continuations inside the loop
            const saved_prefix = ctx.result_prefix;
            ctx.result_prefix = "loop_result_";
            defer ctx.result_prefix = saved_prefix;

            for (each_body) |*cont| {
                if (cont.node) |node| {
                    var result_buf: [64]u8 = undefined;
                    const inner_result = std.fmt.bufPrint(&result_buf, "loop_result_{d}", .{step_idx}) catch "_";
                    try emitStep(emitter, ctx, &node, inner_result);
                    // Suppress unused result
                    if (node == .invocation) {
                        try emitter.writeIndent();
                        try emitter.write("_ = &");
                        try emitter.write(inner_result);
                        try emitter.write(";\n");
                    }
                    step_idx += 1;

                    // Handle nested continuations (e.g., | result r |> ...)
                    if (cont.continuations.len > 0) {
                        try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false);
                    }
                }
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");

            // Emit done_body after the loop
            for (done_body) |*cont| {
                if (cont.node) |node| {
                    // If in_handler and the node is a branch_constructor, use "_" to trigger return
                    // This handles subflow handlers like: ~my_event = for(...) | done |> result { ... }
                    const is_return_node = ctx.in_handler and node == .branch_constructor;
                    var result_buf: [64]u8 = undefined;
                    const inner_result = if (is_return_node) "_" else std.fmt.bufPrint(&result_buf, "done_result_{d}", .{step_idx}) catch "_";
                    try emitStep(emitter, ctx, &node, inner_result);
                    if (node == .invocation) {
                        try emitter.writeIndent();
                        try emitter.write("_ = &");
                        try emitter.write(inner_result);
                        try emitter.write(";\n");
                    }
                    step_idx += 1;

                    if (cont.continuations.len > 0) {
                        try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false);
                    }
                }
            }
        },
        .conditional => |cond| {
            // Emit if/else with proper AST bodies
            const then_body = ast.NamedBranch.getBody(cond.branches, "then");
            const else_body = ast.NamedBranch.getBody(cond.branches, "else");

            try emitter.writeIndent();
            try emitter.write("if (");
            try emitter.write(cond.condition);
            try emitter.write(") {\n");
            emitter.indent();

            // Emit then_body continuations
            // Save and update result_prefix to avoid shadowing outer scope variables
            const saved_prefix = ctx.result_prefix;
            ctx.result_prefix = "then_result_";
            defer ctx.result_prefix = saved_prefix;

            var step_idx: usize = 0;
            for (then_body) |*cont| {
                if (cont.node) |node| {
                    var result_buf: [64]u8 = undefined;
                    const inner_result = std.fmt.bufPrint(&result_buf, "then_result_{d}", .{step_idx}) catch "_";
                    try emitStep(emitter, ctx, &node, inner_result);
                    if (node == .invocation) {
                        try emitter.writeIndent();
                        try emitter.write("_ = &");
                        try emitter.write(inner_result);
                        try emitter.write(";\n");
                    }
                    step_idx += 1;

                    if (cont.continuations.len > 0) {
                        try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false);
                    }
                }
            }

            emitter.dedent();
            try emitter.writeIndent();

            if (else_body.len > 0) {
                try emitter.write("} else {\n");
                emitter.indent();

                // Update prefix for else branch
                ctx.result_prefix = "else_result_";

                step_idx = 0;
                for (else_body) |*cont| {
                    if (cont.node) |node| {
                        var result_buf: [64]u8 = undefined;
                        const inner_result = std.fmt.bufPrint(&result_buf, "else_result_{d}", .{step_idx}) catch "_";
                        try emitStep(emitter, ctx, &node, inner_result);
                        if (node == .invocation) {
                            try emitter.writeIndent();
                            try emitter.write("_ = &");
                            try emitter.write(inner_result);
                            try emitter.write(";\n");
                        }
                        step_idx += 1;

                        if (cont.continuations.len > 0) {
                            try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false);
                        }
                    }
                }

                emitter.dedent();
                try emitter.writeIndent();
            }

            try emitter.write("}\n");
        },
        .capture => |cap| {
            // Emit capture with comptime type transformation
            const as_binding = ast.NamedBranch.getBinding(cap.branches, "as") orelse "__capture";
            const as_body = ast.NamedBranch.getBody(cap.branches, "as");
            const captured_binding = ast.NamedBranch.getBinding(cap.branches, "captured");
            const captured_body = ast.NamedBranch.getBody(cap.branches, "captured");

            // Detect existing struct mode: init_expr doesn't start with ".{"
            const trimmed_init = std.mem.trim(u8, cap.init_expr, " \t\n\r");
            const is_existing_struct = !std.mem.startsWith(u8, trimmed_init, ".{");

            if (is_existing_struct) {
                // Existing struct mode: just bind to the variable, let Zig infer type
                try emitter.writeIndent();
                try emitter.write("var ");
                try emitter.write(as_binding);
                try emitter.write(" = ");
                try emitter.write(cap.init_expr);
                try emitter.write(";\n");
            } else {
                // Struct literal mode: generate comptime type transformation
                // Use counter to create unique TYPE name (avoids type collision in nested captures)
                // Variable bindings must be unique - user must provide explicit names for nested captures
                const capture_id = ctx.capture_counter;
                ctx.capture_counter += 1;
                const type_name_buf = std.fmt.allocPrint(ctx.allocator, "__CaptureT_{s}_{d}", .{ as_binding, capture_id }) catch "__CaptureT";
                defer ctx.allocator.free(type_name_buf);

                // First, generate the runtime struct type using comptime metaprogramming
                try emitter.writeIndent();
                try emitter.write("const ");
                try emitter.write(type_name_buf);
                try emitter.write(" = comptime blk: {\n");
                emitter.indent();
                try emitter.writeIndent();
                try emitter.write("const info = @typeInfo(@TypeOf(");
                try emitter.write(cap.init_expr);  // Already in Zig syntax: .{ .field = value }
                try emitter.write("));\n");
                try emitter.writeIndent();
                try emitter.write("var fields: [info.@\"struct\".fields.len]@import(\"std\").builtin.Type.StructField = undefined;\n");
                try emitter.writeIndent();
                try emitter.write("for (info.@\"struct\".fields, 0..) |f, i| {\n");
                emitter.indent();
                try emitter.writeIndent();
                try emitter.write("fields[i] = .{\n");
                emitter.indent();
                try emitter.writeIndent();
                try emitter.write(".name = f.name,\n");
                try emitter.writeIndent();
                try emitter.write(".type = f.type,\n");
                try emitter.writeIndent();
                try emitter.write(".default_value_ptr = null,\n");
                try emitter.writeIndent();
                try emitter.write(".is_comptime = false,\n");
                try emitter.writeIndent();
                try emitter.write(".alignment = f.alignment,\n");
                emitter.dedent();
                try emitter.writeIndent();
                try emitter.write("};\n");
                emitter.dedent();
                try emitter.writeIndent();
                try emitter.write("}\n");
                try emitter.writeIndent();
                try emitter.write("break :blk @Type(.{ .@\"struct\" = .{\n");
                emitter.indent();
                try emitter.writeIndent();
                try emitter.write(".layout = .auto,\n");
                try emitter.writeIndent();
                try emitter.write(".fields = &fields,\n");
                try emitter.writeIndent();
                try emitter.write(".decls = &.{},\n");
                try emitter.writeIndent();
                try emitter.write(".is_tuple = false,\n");
                emitter.dedent();
                try emitter.writeIndent();
                try emitter.write("}});\n");
                emitter.dedent();
                try emitter.writeIndent();
                try emitter.write("};\n");

                // Initialize the capture variable with explicit type
                try emitter.writeIndent();
                try emitter.write("var ");
                try emitter.write(as_binding);
                try emitter.write(": ");
                try emitter.write(type_name_buf);
                try emitter.write(" = ");
                try emitter.write(cap.init_expr);  // Already in Zig syntax: .{ .field = value }
                try emitter.write(";\n");
            }

            // Suppress unused warning
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try emitter.write(as_binding);
            try emitter.write(";\n");

            // Emit as_body continuations
            var step_idx: usize = 0;
            for (as_body) |*cont| {
                if (cont.node) |node| {
                    var result_buf: [64]u8 = undefined;
                    const inner_result = std.fmt.bufPrint(&result_buf, "as_result_{d}", .{step_idx}) catch "_";
                    try emitStep(emitter, ctx, &node, inner_result);
                    if (node == .invocation) {
                        try emitter.writeIndent();
                        try emitter.write("_ = &");
                        try emitter.write(inner_result);
                        try emitter.write(";\n");
                    }
                    step_idx += 1;

                    if (cont.continuations.len > 0) {
                        try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false);
                    }
                }
            }

            // Bind final value and emit captured_body
            if (captured_binding) |captured_bind| {
                try emitter.writeIndent();
                try emitter.write("const ");
                try emitter.write(captured_bind);
                try emitter.write(" = ");
                try emitter.write(as_binding);
                try emitter.write(";\n");

                // Suppress unused warning
                try emitter.writeIndent();
                try emitter.write("_ = &");
                try emitter.write(captured_bind);
                try emitter.write(";\n");
            }

            // Emit captured_body continuations
            for (captured_body) |*cont| {
                if (cont.node) |node| {
                    // If in_handler and the node is a branch_constructor, use "_" to trigger return
                    // This handles subflow handlers like: ~my_event = capture(...) | captured |> result { ... }
                    const is_return_node = ctx.in_handler and node == .branch_constructor;
                    var result_buf: [64]u8 = undefined;
                    const inner_result = if (is_return_node) "_" else std.fmt.bufPrint(&result_buf, "done_result_{d}", .{step_idx}) catch "_";
                    try emitStep(emitter, ctx, &node, inner_result);
                    if (node == .invocation) {
                        try emitter.writeIndent();
                        try emitter.write("_ = &");
                        try emitter.write(inner_result);
                        try emitter.write(";\n");
                    }
                    step_idx += 1;

                    if (cont.continuations.len > 0) {
                        try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false);
                    }
                }
            }
        },
        .assignment => |asgn| {
            // Emit direct field assignments: target.field = expr;
            // This handles both scalar fields (target.sum = expr) and
            // indexed fields (target.arr[i] = expr) - Zig parses arr[i] correctly
            for (asgn.fields) |field| {
                try emitter.writeIndent();
                try emitter.write(asgn.target);
                try emitter.write(".");
                try emitter.write(field.name); // Can be "sum" or "arr[i]"
                try emitter.write(" = ");
                if (field.expression_str) |expr| {
                    try emitter.write(expr);
                } else {
                    try emitter.write(field.type);
                }
                try emitter.write(";\n");
            }
        },
    }
}

/// Emit a single step in a pipeline with binding substitution (for tap pipeline emission)
fn emitStepWithBindingSubstitution(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    step: *const ast.Step,
    result_var: []const u8,
    substitution: ?BindingSubstitution,
) !void {
    switch (step.*) {
        .invocation => |*inv| {
            // Emit invocation with binding substitution in arguments
            try emitter.writeIndent();
            if (!std.mem.eql(u8, result_var, "_")) {
                try emitter.write("const ");
            }
            try emitter.write(result_var);
            try emitter.write(" = ");
            if (!ctx.is_sync) {
                try emitter.write("try ");
            }
            try emitInvocationTarget(emitter, ctx, &inv.path);
            try emitter.write(".handler(.{ ");
            // Emit args with binding substitution
            for (inv.args, 0..) |arg, idx| {
                if (idx > 0) {
                    try emitter.write(", ");
                }
                try emitter.write(".");
                try emitter.write(arg.name);
                try emitter.write(" = ");
                try emitValueWithBindingSubstitution(emitter, arg.value, substitution);
            }
            try emitter.write(" });\n");
        },
        .branch_constructor => |*bc| {
            try emitter.writeIndent();
            const is_terminal = std.mem.eql(u8, result_var, "_");
            if (is_terminal) {
                try emitter.write("return ");
            }
            // Emit branch constructor with binding substitution
            try emitter.write(".{ .");
            try writeBranchName(emitter, bc.branch_name);
            try emitter.write(" = .{");
            for (bc.fields, 0..) |field, idx| {
                if (idx > 0) {
                    try emitter.write(", ");
                }
                try emitter.write(" .");
                try emitter.write(field.name);
                try emitter.write(" = ");
                const value = if (field.expression_str) |expr| expr else field.type;
                try emitValueWithBindingSubstitution(emitter, value, substitution);
            }
            try emitter.write(" } }");
            try emitter.write(";\n");
        },
        .terminal => {
            // Terminal steps don't create variables
        },
        .conditional_block => |*cb| {
            // Emit if (condition) { steps } with binding substitution
            try emitter.writeIndent();
            try emitter.write("if (");

            // Emit condition with binding substitution
            if (cb.condition_expr) |expr| {
                try emitExpression(emitter, ctx, expr, substitution);
            } else if (cb.condition) |cond| {
                try emitValueWithBindingSubstitution(emitter, cond, substitution);
            }

            try emitter.write(") {\n");
            emitter.indent();

            // Emit all steps inside the conditional block
            var step_idx: usize = 0;
            for (cb.nodes) |inner_step| {
                // Generate result variable for each step
                var result_buf: [64]u8 = undefined;
                const inner_result_var = try std.fmt.bufPrint(&result_buf, "cond_result_{d}", .{step_idx});
                try emitStepWithBindingSubstitution(emitter, ctx, &inner_step, inner_result_var, substitution);
                step_idx += 1;
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");
        },
        .deref => |*deref| {
            try emitter.writeIndent();
            try emitter.write("var ");
            try emitter.write(result_var);
            try emitter.write(" = ");
            // Note: deref.target could potentially reference the binding
            try emitValueWithBindingSubstitution(emitter, deref.target, substitution);
            if (deref.args) |args| {
                try emitter.write("(.{ ");
                for (args, 0..) |arg, idx| {
                    if (idx > 0) {
                        try emitter.write(", ");
                    }
                    try emitter.write(".");
                    try emitter.write(arg.name);
                    try emitter.write(" = ");
                    try emitValueWithBindingSubstitution(emitter, arg.value, substitution);
                }
                try emitter.write(" })");
            }
            try emitter.write(";\n");
        },
        .label_with_invocation => |*lwi| {
            // Emit label and invocation with binding substitution
            try emitter.writeIndent();
            try emitter.write(lwi.label);
            try emitter.write(": const ");
            try emitter.write(result_var);
            try emitter.write(" = ");
            try emitInvocationTarget(emitter, ctx, &lwi.invocation.path);
            try emitter.write(".handler(.{ ");
            for (lwi.invocation.args, 0..) |arg, idx| {
                if (idx > 0) {
                    try emitter.write(", ");
                }
                try emitter.write(".");
                try emitter.write(arg.name);
                try emitter.write(" = ");
                try emitValueWithBindingSubstitution(emitter, arg.value, substitution);
            }
            try emitter.write(" });\n");
        },
        .label_apply => |label_name| {
            // Simple label jump without arguments (e.g., @label)
            // Look up the target label's context
            var target_ctx: ?LabelContext = null;
            if (ctx.label_contexts) |label_map| {
                target_ctx = label_map.get(label_name);
            }

            // If not in map, try current label context (for same-level or subflow labels)
            if (target_ctx == null) {
                if (ctx.label_handler_invocation != null and ctx.label_result_var != null) {
                    target_ctx = .{
                        .handler_invocation = ctx.label_handler_invocation.?,
                        .result_var = ctx.label_result_var.?,
                    };
                }
            }

            // If we have a target context (from map OR current), call the handler
            if (target_ctx) |tctx| {
                // Call the TARGET label's handler using label's state variables
                try emitter.writeIndent();
                try emitter.write(tctx.result_var);
                try emitter.write(" = ");
                if (!ctx.is_sync) {
                    try emitter.write("try ");
                }
                try emitInvocationTarget(emitter, ctx, &tctx.handler_invocation.path);
                try emitter.write(".handler(.{ ");
                // Pass state variables: label_name + "_" + arg_name (with binding substitution)
                for (tctx.handler_invocation.args, 0..) |arg, idx| {
                    if (idx > 0) {
                        try emitter.write(", ");
                    }
                    try emitter.write(".");
                    try emitter.write(arg.name);
                    try emitter.write(" = ");
                    // Build state variable name and apply substitution if needed
                    const state_var = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{label_name, arg.name});
                    defer ctx.allocator.free(state_var);
                    try emitValueWithBindingSubstitution(emitter, state_var, substitution);
                }
                try emitter.write(" });\n");
            }

            // ALWAYS emit continue :label
            try emitter.writeIndent();
            try emitter.write("continue :");
            try emitter.write(label_name);
            try emitter.write(";\n");
        },
        .label_jump => |*lj| {
            // Update state variables before continuing to loop
            for (lj.args) |arg| {
                try emitter.writeIndent();
                try emitter.write(lj.label);
                try emitter.write("_");
                try emitter.write(arg.name);
                try emitter.write(" = ");
                try emitValueWithBindingSubstitution(emitter, arg.value, substitution);
                try emitter.write(";\n");
            }
            // Continue to the labeled loop
            try emitter.writeIndent();
            try emitter.write("continue :");
            try emitter.write(lj.label);
            try emitter.write(";\n");
        },
        .inline_code => |code| {
            try emitter.writeIndent();
            try emitter.write(code);
            try emitter.write("\n");
        },
        .foreach => |fe| {
            // Emit for loop - binding substitution not applied inside loop body for now
            const raw_binding = ast.NamedBranch.getBinding(fe.branches, "each") orelse "_";
            const each_body = ast.NamedBranch.getBody(fe.branches, "each");
            const done_body = ast.NamedBranch.getBody(fe.branches, "done");

            // Generate unique binding for default names to avoid shadowing in nested loops
            var binding_buf: [64]u8 = undefined;
            const each_binding = if (std.mem.eql(u8, raw_binding, "_")) blk: {
                const for_id = ctx.for_counter;
                ctx.for_counter += 1;
                break :blk std.fmt.bufPrint(&binding_buf, "__for_item_{d}", .{for_id}) catch raw_binding;
            } else raw_binding;

            try emitter.writeIndent();
            try emitter.write("for (");
            try emitValueWithBindingSubstitution(emitter, fe.iterable, substitution);
            try emitter.write(") |");
            try emitter.write(each_binding);
            try emitter.write("| {\n");
            emitter.indent();

            // Suppress unused capture warning
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try emitter.write(each_binding);
            try emitter.write(";\n");

            for (each_body) |*cont| {
                if (cont.node) |node| {
                    try emitStepWithBindingSubstitution(emitter, ctx, &node, "_", substitution);
                }
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");

            for (done_body) |*cont| {
                if (cont.node) |node| {
                    try emitStepWithBindingSubstitution(emitter, ctx, &node, "_", substitution);
                }
            }
        },
        .conditional => |cond| {
            // Emit if/else with binding substitution
            const then_body = ast.NamedBranch.getBody(cond.branches, "then");
            const else_body = ast.NamedBranch.getBody(cond.branches, "else");

            try emitter.writeIndent();
            try emitter.write("if (");
            try emitValueWithBindingSubstitution(emitter, cond.condition, substitution);
            try emitter.write(") {\n");
            emitter.indent();

            for (then_body) |*cont| {
                if (cont.node) |node| {
                    try emitStepWithBindingSubstitution(emitter, ctx, &node, "_", substitution);
                }
            }

            emitter.dedent();
            try emitter.writeIndent();

            if (else_body.len > 0) {
                try emitter.write("} else {\n");
                emitter.indent();

                for (else_body) |*cont| {
                    if (cont.node) |node| {
                        try emitStepWithBindingSubstitution(emitter, ctx, &node, "_", substitution);
                    }
                }

                emitter.dedent();
                try emitter.writeIndent();
            }

            try emitter.write("}\n");
        },
    }
}

/// Emit a branch constructor (.branch = .{ fields })
fn emitBranchConstructor(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    is_terminal: bool,
) !void {
    _ = is_terminal; // Terminal status doesn't affect branch constructor syntax
    try emitter.write(".{ .");
    try writeBranchName(emitter, bc.branch_name);
    try emitter.write(" = ");

    // Check for plain value (non-struct branch)
    if (bc.plain_value) |pv| {
        try emitValue(emitter, ctx, pv);
    } else {
        // Struct value
        try emitter.write(".{");
        for (bc.fields, 0..) |field, idx| {
            if (idx > 0) {
                try emitter.write(", ");
            }
            try emitter.write(" .");
            try emitter.write(field.name);
            try emitter.write(" = ");
            const value = if (field.expression_str) |expr| expr else field.type;
            try emitValue(emitter, ctx, value);
        }
        try emitter.write(" }");
    }
    try emitter.write(" }");
}

/// Check if a continuation uses a binding variable in its body
fn continuationUsesBinding(cont: *const ast.Continuation, binding: []const u8) bool {
    // Check condition
    if (cont.condition) |cond| {
        if (containsIdentifier(cond, binding)) {
            return true;
        }
    }

    // Check the step
    if (cont.node) |step| {
        switch (step) {
            .invocation => |inv| {
                for (inv.args) |arg| {
                    if (containsIdentifier(arg.value, binding)) {
                        return true;
                    }
                }
            },
            .branch_constructor => |bc| {
                // Check plain value first
                if (bc.plain_value) |pv| {
                    if (containsIdentifier(pv, binding)) {
                        return true;
                    }
                }
                for (bc.fields) |field| {
                    const value = if (field.expression_str) |expr| expr else field.type;
                    if (containsIdentifier(value, binding)) {
                        return true;
                    }
                }
            },
            .deref => |deref| {
                if (containsIdentifier(deref.target, binding)) {
                    return true;
                }
                if (deref.args) |args| {
                    for (args) |arg| {
                        if (containsIdentifier(arg.value, binding)) {
                            return true;
                        }
                    }
                }
            },
            .label_with_invocation => |lwi| {
                for (lwi.invocation.args) |arg| {
                    if (containsIdentifier(arg.value, binding)) {
                        return true;
                    }
                }
            },
            .label_jump => |lj| {
                for (lj.args) |arg| {
                    if (containsIdentifier(arg.value, binding)) {
                        return true;
                    }
                }
            },
            .inline_code => |ic| {
                // Check if inline code references the binding (e.g., print.ln transform generating "err.@\"error\"")
                if (containsIdentifier(ic, binding)) {
                    return true;
                }
            },
            .foreach => |fe| {
                // Check if foreach uses the binding in its iterable expression
                if (containsIdentifier(fe.iterable, binding)) {
                    return true;
                }
                // Check all branches recursively
                for (fe.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        if (continuationUsesBinding(body_cont, binding)) {
                            return true;
                        }
                    }
                }
            },
            .conditional => |cond| {
                // Check if conditional uses the binding in its condition expression
                if (containsIdentifier(cond.condition, binding)) {
                    return true;
                }
                // Check all branches recursively
                for (cond.branches) |*branch| {
                    for (branch.body) |*body_cont| {
                        if (continuationUsesBinding(body_cont, binding)) {
                            return true;
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Check nested continuations recursively
    for (cont.continuations) |nested| {
        if (continuationUsesBinding(&nested, binding)) {
            return true;
        }
    }

    return false;
}
