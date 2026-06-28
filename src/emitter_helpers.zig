// Helper functions extracted from emitter.zig
const log = @import("log");
// This file contains ONLY the helpers needed by visitor_emitter.zig
// The old procedural orchestrators remain in emitter.zig as reference only

const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const tap_registry_module = @import("tap_registry");
const type_registry_module = @import("type_registry");
const purity_helpers = @import("compiler_passes/purity_helpers");
const compiler_config = @import("compiler_config");
const codegen_utils = @import("codegen_utils");
const annotation_parser = @import("annotation_parser");

/// Find a `~[transform]proc` implementing the event at `segments` among `items`.
/// A transform IS a proc on an ordinary event: the event declares the USER
/// surface (payload + branch contract), the proc carries the `[transform]`
/// annotation and follows the machine convention
/// (invocation, item, program, allocator) → transformed: SiteResult.
pub fn findTransformProc(items: []const ast.Item, segments: []const []const u8) ?*const ast.ProcDecl {
    for (items) |*it| {
        if (it.* != .proc_decl) continue;
        const proc = &it.proc_decl;
        if (!annotation_parser.hasPart(proc.annotations, "transform")) continue;
        if (proc.path.segments.len != segments.len) continue;
        var equal = true;
        for (proc.path.segments, segments) |a, b| {
            if (!std.mem.eql(u8, a, b)) {
                equal = false;
                break;
            }
        }
        if (equal) return proc;
    }
    return null;
}

// ============================================================================
// VARIANT REGISTRY - Core language feature for proc variant selection
// ============================================================================
// This registry maps canonical event names to their selected variant.
// It's populated by userland code (e.g., build:variants) and read by the emitter.
// The emitter checks this when generating handler calls for invocations
// that don't have an explicit |variant suffix.

pub const VariantMapping = struct {
    event_name: []const u8,
    variant_name: []const u8,
};

/// Global variant registry - populated at comptime, read by emitter
pub var variant_mappings: [64]VariantMapping = undefined;
pub var variant_count: usize = 0;

/// Register a variant mapping (called by build:variants or other mechanisms)
pub fn registerVariant(event_name: []const u8, variant_name: []const u8) bool {
    if (variant_count >= variant_mappings.len) {
        return false; // Registry full
    }
    variant_mappings[variant_count] = .{
        .event_name = event_name,
        .variant_name = variant_name,
    };
    variant_count += 1;
    return true;
}

/// Look up the default variant for an event by canonical name
/// Returns null if no variant is registered (use default handler)
pub fn getVariant(event_name: []const u8) ?[]const u8 {
    for (variant_mappings[0..variant_count]) |mapping| {
        if (std.mem.eql(u8, mapping.event_name, event_name)) {
            return mapping.variant_name;
        }
    }
    return null;
}

// ============================================================================
// BUILD CONFIG REGISTRY - Key-value build configuration
// ============================================================================
// Populated by build:config, read by the backend when invoking zig build.
// Currently supports "target" for cross-compilation, but the mechanism is
// general: any key-value pair can be registered and queried.

pub const BuildConfigEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Global build config registry - populated at comptime, read by build step
pub var build_configs: [64]BuildConfigEntry = undefined;
pub var build_config_count: usize = 0;

/// Register a build config value (called by build:config)
pub fn registerBuildConfig(key: []const u8, value: []const u8) bool {
    if (build_config_count >= build_configs.len) {
        return false; // Registry full
    }
    // Overwrite if key already exists
    for (build_configs[0..build_config_count]) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.value = value;
            return true;
        }
    }
    build_configs[build_config_count] = .{
        .key = key,
        .value = value,
    };
    build_config_count += 1;
    return true;
}

/// Look up a build config value by key
pub fn getBuildConfig(key: []const u8) ?[]const u8 {
    for (build_configs[0..build_config_count]) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
    }
    return null;
}

/// Controls which modules/taps to emit based on annotations
/// Duplicated from visitor_emitter.zig to avoid circular dependency
pub const EmitMode = enum {
    all, // Emit everything (no filtering based on comptime/runtime)
    comptime_only, // Emit only modules with [comptime] annotation
    runtime_only, // Emit only modules WITHOUT [comptime] annotation (default)
};

/// Check if an item should be filtered out based on emit mode and annotations
/// Duplicated from visitor_emitter.zig to avoid circular dependency
pub fn shouldFilter(item_annotations: []const []const u8, module_annotations: []const []const u8, module_path: []const u8, mode: EmitMode) bool {
    // Compiler infrastructure is never emitted into user output
    if (purity_helpers.hasAnnotation(item_annotations, "compiler")) {
        return true;
    }
    if (std.mem.eql(u8, module_path, "compiler_bootstrap")) {
        return true;
    }

    // Phase annotation semantics:
    // - Module-level [comptime] makes ALL items in the module comptime by default
    // - Module-level [runtime] makes ALL items in the module available at runtime
    // - Item-level annotations override module-level annotations
    // - [comptime|runtime] means available in both phases
    // This allows modules like testing.kz to be marked [comptime] while still having
    // specific items marked [runtime] if needed.
    const has_module_comptime = purity_helpers.hasAnnotation(module_annotations, "comptime");
    const has_module_runtime = purity_helpers.hasAnnotation(module_annotations, "runtime");
    const has_item_comptime = purity_helpers.hasAnnotation(item_annotations, "comptime");
    const has_item_runtime = purity_helpers.hasAnnotation(item_annotations, "runtime");

    // Item is comptime if either the module or item has [comptime] annotation
    // UNLESS the item or module explicitly has [runtime] (which allows runtime emission)
    const is_comptime = has_module_comptime or has_item_comptime;
    const is_runtime = has_item_runtime or has_module_runtime;

    // Filter based on emit mode and phase annotations
    switch (mode) {
        .all => {
            // Emit everything (except compiler infrastructure already filtered above)
            return false;
        },
        .comptime_only => {
            // Emit if comptime (possibly combined with runtime)
            // Filter OUT items that are not comptime
            return !is_comptime and !has_item_comptime;
        },
        .runtime_only => {
            // Emit if runtime OR no phase annotations (default runtime)
            // Filter OUT if comptime-only (not also marked runtime)
            return is_comptime and !is_runtime;
        },
    }
}

/// Emission context - tracks state during code generation
/// Context for a labeled loop - tracks handler and result variable for label jumps
pub const LabelContext = struct {
    handler_invocation: *const ast.Invocation,
    result_var: []const u8,
    // Effect-branches phase 3b: the Handlers struct synthesized for the
    // labeled invocation, if the target event declares `!` branches. Used
    // by `@label(...)` re-entry emission to pass the comptime 2nd arg so
    // the call still matches the proc's handler signature.
    handlers_name: ?[]const u8 = null,
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
    type_registry: ?*type_registry_module.TypeRegistry = null, // Type registry for array literal type hints
    current_source_event: ?[]const u8 = null, // Canonical name of current source event for tap matching
    current_branch: ?[]const u8 = null, // Current branch name for tap matching
    label_handler_invocation: ?*const ast.Invocation = null, // Invocation for current label's handler (for re-calling in label_jump)
    label_result_var: ?[]const u8 = null, // Result variable name for current label (for updating in label_jump)
    label_contexts: ?*std.StringHashMap(LabelContext) = null, // Map of label names to their contexts (for cross-level jumps)
    main_module_name: ?[]const u8 = null, // Main module name for qualifying unqualified events
    module_prefix: []const u8 = "main_module", // Prefix for local event references (e.g., "main_module" or "test_0_module")
    emit_mode: ?EmitMode = null, // Emission mode for filtering taps by phase annotations
    module_annotations: ?[]const []const u8 = null, // Module-level annotations for tap filtering
    skip_tap_inserted_steps: bool = false, // Skip steps inserted by tap transformation (for opaque modules)
    capture_counter: usize = 0, // Counter for unique capture type names (nested captures)
    for_counter: usize = 0, // Counter for unique for loop binding names (nested loops)
    inline_label_counter: usize = 0, // Counter for unique __KORU_INLINE__ label substitution at depth
    result_prefix: []const u8 = "result_", // Prefix for result variable names (changes to "loop_result_" inside loops)
    // InvocationMeta support - set when emitting a flow
    current_flow_annotations: ?[]const []const u8 = null, // Flow annotations like ["release", "debug"]
    current_flow_location: ?errors.SourceLocation = null, // Location of the flow invocation
    // Comptime program return: use this binding instead of "_" for zero-continuation flows
    comptime_result_binding: ?[]const u8 = null,
    // Effect-branches phase 3b: if set, emitInvocation appends `, NAME` as 2nd handler arg.
    // Set by emitFlow when the target event has effect (`!`) branches and a Handlers
    // struct has been synthesized locally. Cleared after the invocation.
    pending_handlers_name: ?[]const u8 = null,
    // ── Tail self-continuation loop lowering ─────────────────────────────────
    // When a flow that implements event E re-enters E in tail position and
    // forwards the result unchanged (e.g. `|> run(...) | done res => done res`),
    // the handler is emitted as a `while (true)` loop over `var` input bindings
    // instead of a stack-growing self-call carrying a by-value `Input` payload.
    // See `emitSelfTailReentry` / `flowContainsSelfTailForward`. Set by
    // `emitEventDeclForModule` around the flow body emission; the per-site
    // reassign+continue is emitted in `emitContinuationBody`.
    self_loop_active: bool = false,
    self_loop_label: []const u8 = "__koru_self_loop",
    self_loop_event_canonical: ?[]const u8 = null,
};

/// CodeEmitter - manages buffer and formatting
/// Ported from compiler_visitor.kz with improvements
pub const CodeEmitter = struct {
    buffer: []u8,
    pos: usize,
    indent_level: u32,
    indent_size: u32 = 4,
    /// When set, the buffer GROWS on demand instead of failing with
    /// BufferOverflow. Generated code has no natural size ceiling (a large
    /// regex DFA alone can pass 256KB — pinned by 640_004), so emission
    /// call sites should use initGrowable; fixed init remains for callers
    /// with genuinely bounded output (unit tests with stack buffers).
    allocator: ?std.mem.Allocator = null,

    pub fn init(buffer: []u8) CodeEmitter {
        return .{
            .buffer = buffer,
            .pos = 0,
            .indent_level = 0,
        };
    }

    pub fn initGrowable(allocator: std.mem.Allocator, initial_size: usize) !CodeEmitter {
        return .{
            .buffer = try allocator.alloc(u8, initial_size),
            .pos = 0,
            .indent_level = 0,
            .allocator = allocator,
        };
    }

    /// Low-level write - no formatting
    pub fn write(self: *CodeEmitter, text: []const u8) !void {
        if (self.pos + text.len >= self.buffer.len) {
            const a = self.allocator orelse return error.BufferOverflow;
            var new_len = if (self.buffer.len > 0) self.buffer.len * 2 else 4096;
            while (self.pos + text.len >= new_len) new_len *= 2;
            const new_buf = try a.alloc(u8, new_len);
            @memcpy(new_buf[0..self.pos], self.buffer[0..self.pos]);
            a.free(self.buffer);
            self.buffer = new_buf;
        }
        @memcpy(self.buffer[self.pos .. self.pos + text.len], text);
        self.pos += text.len;
    }

    /// Emit `text` as a quoted Zig string literal (`"..."`), escaping `\`, `"`,
    /// and control chars. Use this whenever a user-supplied string (annotation
    /// content, error message, etc.) must round-trip through generated Zig.
    pub fn writeZigStringLiteral(self: *CodeEmitter, text: []const u8) !void {
        try self.write("\"");
        for (text) |c| {
            switch (c) {
                '\\' => try self.write("\\\\"),
                '"' => try self.write("\\\""),
                '\n' => try self.write("\\n"),
                '\r' => try self.write("\\r"),
                '\t' => try self.write("\\t"),
                else => try self.write(&[_]u8{c}),
            }
        }
        try self.write("\"");
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
        return codegen_utils.needsEscaping(word);
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

// Redundant isZigKeyword removed (use codegen_utils.needsEscaping)

/// Helper: Write branch name (escaped if needed)
pub fn writeBranchName(emitter: *CodeEmitter, name: []const u8) !void {
    // Kebab → snake mangle on emit: `-` is a legal Koru name-char but not a Zig
    // identifier char. The mangled result is always a valid identifier, so it
    // never needs `@"..."` escaping. No-op for snake names (the entire pre-kebab
    // corpus), so this cannot affect existing tests.
    for (name) |c| {
        if (c == '-') {
            try writeMangledSeg(emitter, name);
            return;
        }
    }
    if (codegen_utils.needsEscaping(name)) {
        try emitter.write("@\"");
        try emitter.write(name);
        try emitter.write("\"");
    } else {
        try emitter.write(name);
    }
}

/// Write a name as a Zig identifier, mangling kebab `-` → `_` (D2: snake for the
/// Zig target). Used both for standalone names (via writeBranchName) and for
/// path segments joined into event/proc identifiers. No-op for snake input.
pub fn writeMangledSeg(emitter: *CodeEmitter, seg: []const u8) !void {
    for (seg) |c| {
        try emitter.write(&[_]u8{if (c == '-') '_' else c});
    }
}

/// Resolve a module alias to its actual module path
/// For example, "build" (from ~import std/build) -> "std.build"
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
                        break :blk import.path[last_slash + 1 ..];
                    } else {
                        break :blk import.path;
                    }
                };

                if (std.mem.eql(u8, import_alias, alias)) {
                    // Found the import! Convert path to module path
                    // "std/build" -> "std/build" (writeModulePath will convert / to .)
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
            if (!first) try emitter.write(".");
            const prefix = codegen_utils.koruWrapperPrefix(first);
            // Escape the full prefixed segment so keyword segments lower correctly
            // (e.g. "switch" -> "koru_switch", not "koru_@\"switch\"").
            try writePrefixedSegment(emitter, prefix, segment);
            first = false;
        }
        return;
    }

    // Handle normal dotted paths (logical names like "logger" or "std.io")
    var splitter = std.mem.splitScalar(u8, module_path, '.');
    var first = true;
    while (splitter.next()) |segment| {
        if (!first) try emitter.write(".");
        const prefix = codegen_utils.koruWrapperPrefix(first);
        // Escape the full prefixed segment so keyword segments lower correctly
        // (e.g. "switch" -> "koru_switch", not "koru_@\"switch\"").
        try writePrefixedSegment(emitter, prefix, segment);
        first = false;
    }
}

/// Write an identifier segment, escaping if needed for Zig
fn writeEscapedSegment(emitter: *CodeEmitter, name: []const u8) !void {
    if (codegen_utils.needsEscaping(name)) {
        try emitter.write("@\"");
        try emitter.write(name);
        try emitter.write("\"");
    } else {
        try emitter.write(name);
    }
}

/// Write a module-path segment with its "koru_" prefix, escaping the FULL
/// prefixed identifier if necessary. Escaping only the segment produces invalid
/// Zig for keyword segments (e.g. "switch" -> "koru_@\"switch\""), so we build
/// "koru_switch" and only escape if the combined name still needs it.
fn writePrefixedSegment(emitter: *CodeEmitter, prefix: []const u8, segment: []const u8) !void {
    var buf: [256]u8 = undefined;
    const full_name = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, segment }) catch segment;
    if (codegen_utils.needsEscaping(full_name)) {
        try emitter.write("@\"");
        try emitter.write(full_name);
        try emitter.write("\"");
    } else {
        try emitter.write(full_name);
    }
}

/// Mangle a variant name into a valid Zig identifier suffix.
/// Alphanumeric and underscore pass through; everything else becomes _XX_ (hex code).
/// Example: "zig(optimized)" -> "zig_28_optimized_29_"
pub fn mangleVariant(allocator: std.mem.Allocator, variant: []const u8) ![]const u8 {
    // Count how much space we need
    var len: usize = 0;
    for (variant) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            len += 1;
        } else {
            len += 4; // _XX_
        }
    }

    var result = try allocator.alloc(u8, len);
    var pos: usize = 0;

    for (variant) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            result[pos] = c;
            pos += 1;
        } else {
            // Encode as _XX_
            result[pos] = '_';
            pos += 1;
            const hex = "0123456789abcdef";
            result[pos] = hex[c >> 4];
            pos += 1;
            result[pos] = hex[c & 0x0f];
            pos += 1;
            result[pos] = '_';
            pos += 1;
        }
    }

    return result;
}

/// Write a handler name with optional variant suffix.
/// If variant is null, writes "handler". Otherwise writes "handler__<mangled_variant>".
pub fn writeHandlerName(emitter: *CodeEmitter, allocator: std.mem.Allocator, variant: ?[]const u8) !void {
    try emitter.write("handler");
    if (variant) |v| {
        try emitter.write("__");
        const mangled = try mangleVariant(allocator, v);
        defer allocator.free(mangled);
        try emitter.write(mangled);
    }
}

/// Write a variant comment for readability.
/// Example: " // |zig(optimized)"
pub fn writeVariantComment(emitter: *CodeEmitter, variant: ?[]const u8) !void {
    if (variant) |v| {
        try emitter.write(" // |");
        try emitter.write(v);
    }
}

/// Helper: Write field type with proper module path handling
pub fn writeFieldType(emitter: *CodeEmitter, field: ast.Field, main_module_name: ?[]const u8) !void {
    // A bare foreign type carrying a module-qualified phantom (e.g.
    // `*Field<std/field:field>`) has no module_path on the TYPE itself, but the
    // phantom names the module the type lives in — the state belongs to that
    // type. Fall back to the phantom's module so the type emits qualified
    // (`*koru_std.koru_field.Field`). Only triggers for explicitly-qualified
    // phantoms (a same-module phantom like `field!` has no `:`), so local
    // std-module events are unaffected.
    const effective_module_path: ?[]const u8 = field.module_path orelse blk: {
        const ph = field.phantom orelse break :blk null;
        const colon = std.mem.indexOfScalar(u8, ph, ':') orelse break :blk null;
        break :blk ph[0..colon];
    };
    if (effective_module_path) |module_path| {
        // Cross-module type reference: module.path:Type -> prefix + koru_module.path.Type
        // Extract any type prefix (?*, *, [], []const) from the type name
        var type_name = field.type;
        var type_prefix: []const u8 = "";

        const prefixes = [_][]const u8{ "[]const ", "?*const ", "*const ", "[]", "?*", "?", "*" };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, type_name, prefix)) {
                type_prefix = prefix;
                type_name = type_name[prefix.len..];
                break;
            }
        }

        // Write: prefix + module_path + . + base_type
        if (type_prefix.len > 0) {
            try emitter.write(type_prefix);
        }
        try writeModulePath(emitter, module_path, main_module_name);
        try emitter.write(".");
        try emitter.write(type_name);
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
/// Convert canonical event name to enum tag format
/// Must match the format used in EventEnum generation (emitTapsNamespace)
/// Example: "std.compiler:compiler.context.create" -> "std_compiler_compiler_context_create"
/// Example: "input:target" -> "input_target"
pub fn canonicalNameToEnumTag(emitter: *CodeEmitter, canonical_name: []const u8) !void {
    // Mangle the full canonical name (replace dots and colons with underscores)
    // This must match the mangling in emitTapsNamespace EventEnum generation
    for (canonical_name) |c| {
        if (c == '.' or c == ':') {
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
///
/// `pub_compiler_env` controls visibility of the CompilerEnv re-export:
///   - true  → backend_output_emitted.zig (comptime_only). pub is required so
///             src/ code compiled into the addObject (phantom_semantic_checker,
///             etc.) can see CompilerEnv via `@hasDecl(root, ...)` — that
///             builtin only crosses file boundaries through pub decls.
///   - false → output_emitted.zig (runtime_only / user output). pub here would
///             make `std.testing.refAllDeclsRecursive` (used by zig test
///             autorun) eagerly resolve `@import("compiler_env")`, which has
///             no module wired in the user's standalone build → compile error.
///             Non-pub keeps the decl invisible to refAllDeclsRecursive.
pub fn emitMainModuleStart(emitter: *CodeEmitter, pub_compiler_env: bool) !void {
    try emitter.write("// Access compiler flags via the per-user compiler_env module\n");
    if (pub_compiler_env) {
        try emitter.write("pub const CompilerEnv = @import(\"compiler_env\").CompilerEnv;\n\n");
    } else {
        try emitter.write("const CompilerEnv = @import(\"compiler_env\").CompilerEnv;\n\n");
    }
    // KORU ALLOCATOR SPINE — the one allocator stdlib runtime procs use,
    // backed by a leak-reporting GPA. Emitted into BOTH outputs so proc
    // bodies (pasted into both) always resolve; only the RUNTIME main()
    // performs the deinit leak check and fails the process (exit 1) on
    // leaks. This is a METER, not a mop: no arenas, no auto-free — real
    // leaks in proc bodies must surface, loudly.
    // `.safety = true` UNCONDITIONALLY: Stage D builds release binaries
    // (ReleaseSmall/ReleaseFast), where DebugAllocator's tracking defaults
    // OFF and deinit() lies `.ok` over real leaks. Every produced Koru
    // binary leak-checks itself at exit, in every build mode — that IS the
    // resource-safety claim.
    try emitter.write("var __koru_gpa = @import(\"std\").heap.GeneralPurposeAllocator(.{ .safety = true }){};\n");
    try emitter.write("pub fn koru_allocator() @import(\"std\").mem.Allocator {\n");
    try emitter.write("    return __koru_gpa.allocator();\n");
    try emitter.write("}\n\n");
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
/// Events/branches can come from tap_registry (old style) OR AST metatype_binding (new ~tap() style)
pub fn emitTapsNamespace(
    emitter: *CodeEmitter,
    tap_registry: *const tap_registry_module.TapRegistry,
    has_base_transition: bool,
    has_profiling_transition: bool,
    has_audit_transition: bool,
    ast_events: []const []const u8,
    ast_branches: []const []const u8,
) !void {
    // Get the referenced events and branches from tap registry
    const registry_events = try tap_registry.getReferencedEvents();
    defer tap_registry.allocator.free(registry_events);
    const registry_branches = try tap_registry.getReferencedBranches();
    defer tap_registry.allocator.free(registry_branches);

    // Merge registry events with AST events (deduplicated)
    // Use Managed variant for simpler API (stores allocator internally)
    const allocator = tap_registry.allocator;
    var all_events = std.array_list.Managed([]const u8).init(allocator);
    defer all_events.deinit();
    for (registry_events) |e| {
        var found = false;
        for (all_events.items) |existing| {
            if (std.mem.eql(u8, existing, e)) {
                found = true;
                break;
            }
        }
        if (!found) try all_events.append(e);
    }
    for (ast_events) |e| {
        var found = false;
        for (all_events.items) |existing| {
            if (std.mem.eql(u8, existing, e)) {
                found = true;
                break;
            }
        }
        if (!found) try all_events.append(e);
    }
    const events = all_events.items;

    // Merge registry branches with AST branches (deduplicated)
    var all_branches = std.array_list.Managed([]const u8).init(allocator);
    defer all_branches.deinit();
    for (registry_branches) |b| {
        var found = false;
        for (all_branches.items) |existing| {
            if (std.mem.eql(u8, existing, b)) {
                found = true;
                break;
            }
        }
        if (!found) try all_branches.append(b);
    }
    for (ast_branches) |b| {
        var found = false;
        for (all_branches.items) |existing| {
            if (std.mem.eql(u8, existing, b)) {
                found = true;
                break;
            }
        }
        if (!found) try all_branches.append(b);
    }
    const branches = all_branches.items;

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
            if (codegen_utils.needsEscaping(branch)) {
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
        try emitter.writeLine("timestamp_ns: i128,           // nanoseconds since epoch (runtime capture)");
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
    if (codegen_utils.needsEscaping(branch)) {
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

/// Extract element type from a slice type string
/// Examples:
///   "[]const i32" -> "i32"
///   "[]i32" -> "i32"
///   "[]*Handle" -> "*Handle"
///   "[]const threading:WorkerHandle" -> "threading:WorkerHandle"
pub fn extractSliceElementType(slice_type: []const u8) ?[]const u8 {
    // Must start with []
    if (slice_type.len < 2 or slice_type[0] != '[' or slice_type[1] != ']') {
        return null;
    }

    var rest = slice_type[2..];

    // Skip "const " if present
    if (std.mem.startsWith(u8, rest, "const ")) {
        rest = rest[6..];
    }

    // Return the element type
    if (rest.len > 0) {
        return rest;
    }

    return null;
}

const SliceTypeInfo = struct {
    element_type: []const u8,
    is_const: bool,
    is_optional: bool,
};

fn parseSliceType(slice_type: []const u8) ?SliceTypeInfo {
    var rest = std.mem.trim(u8, slice_type, " \t");
    var is_optional = false;

    if (rest.len > 0 and rest[0] == '?') {
        is_optional = true;
        rest = rest[1..];
    }

    if (!std.mem.startsWith(u8, rest, "[]")) {
        return null;
    }

    rest = rest[2..];
    var is_const = false;
    if (std.mem.startsWith(u8, rest, "const ")) {
        is_const = true;
        rest = rest[6..];
    }

    if (rest.len == 0) {
        return null;
    }

    return SliceTypeInfo{
        .element_type = rest,
        .is_const = is_const,
        .is_optional = is_optional,
    };
}

/// Check if a value looks like a Koru struct literal: { field: value, ... }
/// Must be single-line (not a Source block) and contain field: value patterns
fn isKoruStructLiteral(value: []const u8) bool {
    if (value.len < 2) return false;
    if (value[0] != '{' or value[value.len - 1] != '}') return false;

    // Check for field: value pattern (has colon with identifier before it)
    const inner = value[1 .. value.len - 1];
    var i: usize = 0;
    var found_field_pattern = false;

    while (i < inner.len) {
        // Skip whitespace
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) {
            i += 1;
        }
        if (i >= inner.len) break;

        // Look for identifier followed by colon
        if (isIdentStartChar(inner[i])) {
            var j = i + 1;
            while (j < inner.len and isIdentChar(inner[j])) {
                j += 1;
            }
            // Skip whitespace after identifier
            while (j < inner.len and (inner[j] == ' ' or inner[j] == '\t')) {
                j += 1;
            }
            // Check for colon
            if (j < inner.len and inner[j] == ':') {
                found_field_pattern = true;
                break;
            }
        }
        i += 1;
    }

    return found_field_pattern;
}

/// Emit a Koru struct literal as Zig: { field: value } -> .{ .field = value }
fn emitStructLiteral(emitter: *CodeEmitter, ctx: *EmissionContext, value: []const u8) EmitError!void {
    const inner = value[1 .. value.len - 1]; // Strip { and }

    try emitter.write(".{");

    var i: usize = 0;
    var first_field = true;

    while (i < inner.len) {
        // Skip whitespace
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) {
            i += 1;
        }
        if (i >= inner.len) break;

        // Look for field name
        if (isIdentStartChar(inner[i])) {
            const field_start = i;
            while (i < inner.len and isIdentChar(inner[i])) {
                i += 1;
            }
            const field_name = inner[field_start..i];

            // Skip whitespace
            while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) {
                i += 1;
            }

            // Expect colon
            if (i < inner.len and inner[i] == ':') {
                i += 1; // skip colon

                // Skip whitespace after colon
                while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) {
                    i += 1;
                }

                // Find end of value (comma or end of struct)
                const value_start = i;
                var paren_depth: usize = 0;
                var brace_depth: usize = 0;
                var bracket_depth: usize = 0;
                var in_string = false;

                while (i < inner.len) {
                    const c = inner[i];
                    if (!in_string) {
                        if (c == '"') in_string = true else if (c == '(') paren_depth += 1 else if (c == ')' and paren_depth > 0) paren_depth -= 1 else if (c == '{') brace_depth += 1 else if (c == '}' and brace_depth > 0) brace_depth -= 1 else if (c == '[') bracket_depth += 1 else if (c == ']' and bracket_depth > 0) bracket_depth -= 1 else if (c == ',' and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                            break;
                        }
                    } else {
                        if (c == '"' and (i == 0 or inner[i - 1] != '\\')) in_string = false;
                    }
                    i += 1;
                }

                // Trim trailing whitespace from value
                var value_end = i;
                while (value_end > value_start and (inner[value_end - 1] == ' ' or inner[value_end - 1] == '\t')) {
                    value_end -= 1;
                }

                const field_value = inner[value_start..value_end];

                // Emit .field = value
                if (!first_field) {
                    try emitter.write(",");
                }
                try emitter.write(" .");
                try emitter.write(field_name);
                try emitter.write(" = ");

                // Recursively handle nested struct/array literals
                if (field_value.len >= 2 and field_value[0] == '[' and field_value[field_value.len - 1] == ']') {
                    return error.ArrayLiteralMissingType;
                } else if (isKoruStructLiteral(field_value)) {
                    // Nested struct literal
                    try emitStructLiteral(emitter, ctx, field_value);
                } else {
                    try emitValue(emitter, ctx, field_value);
                }

                first_field = false;

                // Skip comma if present
                if (i < inner.len and inner[i] == ',') {
                    i += 1;
                }
            }
        } else {
            i += 1;
        }
    }

    try emitter.write(" }");
}

/// Emit array contents, transforming any nested struct literals
/// Input: "{ x: 1, y: 2 }, { x: 3, y: 4 }" (comma-separated elements)
/// Output: ".{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }"
pub fn emitArrayContents(emitter: *CodeEmitter, ctx: *EmissionContext, contents: []const u8) EmitError!void {
    var i: usize = 0;
    var first_element = true;

    while (i < contents.len) {
        // Skip whitespace
        while (i < contents.len and (contents[i] == ' ' or contents[i] == '\t')) {
            i += 1;
        }
        if (i >= contents.len) break;

        // Find end of this element (next comma at depth 0)
        const elem_start = i;
        var paren_depth: usize = 0;
        var brace_depth: usize = 0;
        var bracket_depth: usize = 0;
        var in_string = false;

        while (i < contents.len) {
            const c = contents[i];
            if (!in_string) {
                if (c == '"') in_string = true else if (c == '(') paren_depth += 1 else if (c == ')' and paren_depth > 0) paren_depth -= 1 else if (c == '{') brace_depth += 1 else if (c == '}' and brace_depth > 0) brace_depth -= 1 else if (c == '[') bracket_depth += 1 else if (c == ']' and bracket_depth > 0) bracket_depth -= 1 else if (c == ',' and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                    break;
                }
            } else {
                if (c == '"' and (i == 0 or contents[i - 1] != '\\')) in_string = false;
            }
            i += 1;
        }

        // Trim the element
        var elem_end = i;
        while (elem_end > elem_start and (contents[elem_end - 1] == ' ' or contents[elem_end - 1] == '\t')) {
            elem_end -= 1;
        }

        const element = contents[elem_start..elem_end];

        if (element.len > 0) {
            if (!first_element) {
                try emitter.write(", ");
            }

            // Check if this element is a struct literal
            if (isKoruStructLiteral(element)) {
                try emitStructLiteral(emitter, ctx, element);
            } else if (element.len >= 2 and element[0] == '[' and element[element.len - 1] == ']') {
                return error.ArrayLiteralMissingType;
            } else {
                try emitValue(emitter, ctx, element);
            }

            first_element = false;
        }

        // Skip comma
        if (i < contents.len and contents[i] == ',') {
            i += 1;
        }
    }
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
    module_prefix: []const u8,
) !void {
    try emitSubflowContinuationsWithDepth(emitter, continuations, start_idx, indent, all_items, 0, tap_registry, type_registry, main_module_name, source_event_name, module_prefix);
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

/// Detect continuation subtrees the `return switch` optimization CANNOT emit.
/// The return-switch fast path (emitSubflowContinuationsWithDepth) only knows
/// how to lower `.invocation`, `.metatype_binding`, `.branch_constructor`, and
/// `.terminal` arm bodies — every other node type falls through to an empty
/// `else => {}` and emits nothing. The canonical case is a capture-fold grafted
/// at a nested site: the transform runner replaces the holding continuation's
/// invocation with an `.inline_code` node (the `var <cell>` preamble) whose
/// children are a synthesized `''` void-chain (`is_transformed_subtree = true`).
/// At top level (a transform's own flow) this emits fine via `emitFlow`'s
/// void-step path; nested under a continuation branch the return-switch path
/// silently drops the whole body (e.g. `.len => |n| ,`). When this fires, bail
/// to the normal `emitContinuationBody` path, whose `is_void_step` branch
/// (inline_code/foreach/assignment/...) emits the preamble + void-chain
/// directly. This can only flip RED->GREEN: any such arm today yields broken
/// Zig (empty switch arm), so no green test reaches here.
fn continuationsHaveReturnSwitchUnemittable(continuations: []const ast.Continuation) bool {
    for (continuations) |cont| {
        if (cont.is_transformed_subtree) return true;
        if (cont.node) |step| {
            switch (step) {
                // An invocation carrying a rendered template body (`inline_body`,
                // e.g. `~if`/`~for` lowered by the template processor) is NOT
                // lowerable by the return-switch fast path: that path emits the
                // raw `_event.handler(...)` call for the un-inlined event and
                // drops the template body — yielding a call to a nonexistent
                // `koru_<module>.<ev>_event` (the `if` template has no runtime
                // event). Bail to the normal `emitContinuationBody` path, whose
                // line ~7287 routes `inline_body` through `emitInlineBodyNode`
                // (the SAME helper top-level flows use). The plain (no-inline_body)
                // invocation stays on the fast path.
                .invocation => |inv| if (inv.inline_body != null) return true,
                // The other node kinds the return-switch path lowers directly.
                .metatype_binding, .branch_constructor, .terminal => {},
                // label_* already force the normal path via continuationsHaveLabels;
                // listed for completeness (bailing is still correct).
                .label_with_invocation, .label_jump, .label_apply => {},
                // Everything else (inline_code, foreach, conditional, assignment,
                // switch_result, conditional_block, expression, deref) is dropped.
                else => return true,
            }
        }
        if (continuationsHaveReturnSwitchUnemittable(cont.continuations)) return true;
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
                    // Transform-grafted generated code on the invocation
                    // (Invocation.inline_body) — scan it like inline code.
                    if (inv.inline_body) |ib| {
                        if (valueReferencesBinding(ib, binding_name)) {
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
                    // Check plain value first (identity branch constructor)
                    if (bc.plain_value) |pv| {
                        if (valueReferencesBinding(pv, binding_name)) {
                            return true;
                        }
                    }
                    for (bc.fields) |field| {
                        const value = if (field.expression_str) |expr| expr else field.type;
                        if (valueReferencesBinding(value, binding_name)) {
                            return true;
                        }
                    }
                },
                .assignment => |asgn| {
                    for (asgn.fields) |field| {
                        if (field.expression_str) |expr| {
                            if (valueReferencesBinding(expr, binding_name)) {
                                return true;
                            }
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

/// Check if a string contains a specific identifier (whole-word match),
/// skipping string literal contents to avoid false positives.
fn containsIdentifier(text: []const u8, ident: []const u8) bool {
    var idx: usize = 0;
    while (idx < text.len) {
        // Skip over string literals to avoid matching identifiers inside them
        if (text[idx] == '"') {
            idx += 1;
            while (idx < text.len) {
                if (text[idx] == '\\') {
                    idx += 2; // skip escape sequence
                } else if (text[idx] == '"') {
                    idx += 1;
                    break;
                } else {
                    idx += 1;
                }
            }
            continue;
        }

        // Check if ident starts at this position (character-by-character to
        // respect the string-skipping above — indexOf would scan past literals)
        if (idx + ident.len <= text.len and std.mem.eql(u8, text[idx .. idx + ident.len], ident)) {
            const valid_start = idx == 0 or !isIdentifierChar(text[idx - 1]);
            const valid_end = idx + ident.len >= text.len or !isIdentifierChar(text[idx + ident.len]);
            if (valid_start and valid_end) {
                return true;
            }
        }

        idx += 1;
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
                if (next_char == ' ' or next_char == '+' or next_char == '-' or next_char == ')' or next_char == ',' or next_char == '*' or next_char == '/' or next_char == '%' or next_char == '[') {
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

fn isSimpleIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (!((c0 >= 'a' and c0 <= 'z') or (c0 >= 'A' and c0 <= 'Z') or c0 == '_')) return false;
    for (s[1..]) |c| {
        if (!isIdentifierChar(c)) return false;
    }
    return true;
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
    defer branch_map.deinit(); // Only deinit the map, not the ArrayList values (ownership transferred)

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
    module_prefix: []const u8,
) !void {
    if (start_idx >= continuations.len) return;

    const remaining_conts = continuations[start_idx..];

    // VOID EVENT FIX: Check if this is a void event continuation (empty branch name)
    // For void events, we don't emit a switch - just execute the step directly
    const is_void_continuation = remaining_conts.len == 1 and
        std.mem.eql(u8, remaining_conts[0].branch, "");

    if (is_void_continuation) {
        // Void event - emit step directly without switch
        const cont = &remaining_conts[0];

        // A labeled-loop step as the void-chain step — e.g. a bare-return head
        // bind feeding a fold: `make(): h0 |> #loop step(h: h0) | again v |>
        // @loop(h: v) | stop r => ...`. The simple step switch below only lowers
        // `.invocation`/`.branch_constructor`; a `.label_with_invocation` falls
        // into its `else` and the whole loop is dropped (empty `.again => ,` arm,
        // undefined `nested_result_*`). Route it through emitContinuationBody —
        // the SAME helper the named-branch path uses (line ~2149) — which emits
        // the loop state vars, the `while` with its back-edge arms, and the
        // terminal-after-loop switch. emitContinuationBody consumes cont's nested
        // continuations (the `@loop`/terminal arms), so we must NOT recurse below.
        if (cont.node) |label_step| {
            if (label_step == .label_with_invocation) {
                // The head's `result` was aliased to the bind (`const <bind> =
                // result;`) at the call site; it is otherwise unused here, so
                // discard it (parent var is `result` at depth 0, else
                // `nested_result_{depth-1}`).
                try emitter.write(indent);
                if (depth == 0) {
                    try emitter.write("_ = &result;\n");
                } else {
                    var buf: [48]u8 = undefined;
                    const discard = try std.fmt.bufPrint(&buf, "_ = &nested_result_{d};\n", .{depth - 1});
                    try emitter.write(discard);
                }

                var ctx = EmissionContext{
                    .allocator = std.heap.page_allocator,
                    .indent_level = 0,
                    .ast_items = all_items,
                    .is_sync = true,
                    .tap_registry = tap_registry,
                    .type_registry = type_registry,
                    .main_module_name = main_module_name,
                    .current_source_event = source_event_name,
                };
                var label_contexts = std.StringHashMap(LabelContext).init(ctx.allocator);
                ctx.label_contexts = &label_contexts;
                defer {
                    var it = label_contexts.valueIterator();
                    while (it.next()) |label_ctx| {
                        ctx.allocator.free(label_ctx.result_var);
                    }
                    label_contexts.deinit();
                }
                var label_counter: usize = depth;
                const old_indent = emitter.indent_level;
                emitter.indent_level = 0;
                try emitContinuationBody(emitter, &ctx, cont, &label_counter);
                emitter.indent_level = old_indent;
                return;
            }
        }

        // If the next continuation needs to switch on a result (has a non-empty
        // branch), we must KEEP this step's return value instead of discarding
        // it — otherwise the downstream switch falls back to a stale `result`
        // (e.g. the head's void return). Assigning to `nested_result_{depth}`
        // lines up with the result_var formula used by the switch path
        // (`nested_result_{depth - 1}` at depth+1).
        const next_needs_switch = cont.continuations.len > 0 and
            !std.mem.eql(u8, cont.continuations[0].branch, "");

        // A bare-return mid-chain bind (`mk(): v |>`) binds THIS step's result to
        // `v`; the parent's result is then unused (the step is a fresh call), so it
        // needs the same discard as the switch case below.
        const step_has_return_binding = if (cont.node) |s|
            (s == .invocation and s.invocation.return_binding != null)
        else
            false;

        // When we override the parent's result variable, discard it so Zig
        // doesn't flag it as an unused local constant. Parent variable is
        // `result` at depth 0, `nested_result_{depth-1}` otherwise.
        if (next_needs_switch or step_has_return_binding) {
            try emitter.write(indent);
            if (depth == 0) {
                try emitter.write("_ = &result;\n");
            } else {
                var buf: [48]u8 = undefined;
                const discard = try std.fmt.bufPrint(&buf, "_ = &nested_result_{d};\n", .{depth - 1});
                try emitter.write(discard);
            }
        }

        // Emit the step if present
        if (cont.node) |step| {
            switch (step) {
                .invocation => |inv| {
                    try emitter.write(indent);
                    if (inv.return_binding) |rb| {
                        // Bare-return mid-chain bind (`mk(): v |> consume(v)`): bind
                        // the produced value so downstream steps can reference it,
                        // instead of discarding the result with `_ =`.
                        try emitter.write("const ");
                        try writeBranchName(emitter, rb);
                        try emitter.write(" = ");
                    } else if (next_needs_switch) {
                        var buf: [32]u8 = undefined;
                        const decl = try std.fmt.bufPrint(&buf, "const nested_result_{d} = ", .{depth});
                        try emitter.write(decl);
                    } else {
                        try emitter.write("_ = ");
                    }

                    // Emit module qualifier if present
                    if (inv.path.module_qualifier) |mq| {
                        try writeModulePath(emitter, mq, main_module_name);
                        try emitter.write(".");
                    } else {
                        try emitter.write(module_prefix);
                        try emitter.write(".");
                    }

                    // Join all segments with underscores to get event name
                    for (inv.path.segments, 0..) |seg, i| {
                        if (i > 0) try emitter.write("_");
                        try writeMangledSeg(emitter, seg);
                    }
                    try emitter.write("_event.handler(.{ ");
                    for (inv.args, 0..) |arg, i| {
                        if (i > 0) try emitter.write(", ");
                        try emitter.write(".");
                        try writeBranchName(emitter, arg.name);
                        try emitter.write(" = ");
                        try emitter.write(arg.value);
                    }
                    try emitter.write(" });\n");
                },
                .branch_constructor => |bc| {
                    // Terminal - emit return
                    try emitter.write(indent);
                    try emitter.write("return .{ .");
                    try writeBranchName(emitter, bc.branch_name);
                    try emitter.write(" = ");
                    // Check for plain value (identity branch constructor)
                    if (bc.plain_value) |pv| {
                        try emitter.write(pv);
                    } else {
                        try emitter.write(".{");
                        for (bc.fields, 0..) |field, i| {
                            if (i > 0) try emitter.write(", ");
                            try emitter.write(" .");
                            try emitter.write(field.name);
                            try emitter.write(" = ");
                            if (field.expression_str) |expr| {
                                try emitter.write(expr);
                            } else {
                                try emitter.write(field.type);
                            }
                        }
                        try emitter.write(" }");
                    }
                    try emitter.write(" };\n");
                },
                else => {},
            }
        }

        // Recurse for nested continuations. Bump depth only when we assigned a
        // result above, so the recursive switch picks up our `nested_result_{depth}`
        // via its own `nested_result_{(depth+1) - 1}` lookup.
        if (cont.continuations.len > 0) {
            try emitSubflowContinuationsWithDepth(
                emitter,
                cont.continuations,
                0,
                indent,
                all_items,
                if (next_needs_switch) depth + 1 else depth,
                tap_registry,
                type_registry,
                main_module_name,
                source_event_name,
                module_prefix,
            );
        }
        return;
    }

    // CRITICAL FIX: Check if any continuation has labels, or carries a node the
    // return-switch fast path can't lower (a grafted capture subtree's
    // `.inline_code` preamble + void-chain, or any foreach/conditional/
    // assignment/etc. arm body). If yes, we CANNOT use "return switch" — must
    // use normal continuation emission: labels create loops that must stay
    // within the function, and void/control-flow step bodies are only lowered
    // by emitContinuationBody's `is_void_step` branch (the return-switch path
    // drops them, emitting empty switch arms).
    // TODO: Also check for taps, but need to implement tap emission in return switch path
    // (redirecting to normal switch breaks module qualification for compiler infrastructure)
    if (continuationsHaveLabels(continuations[start_idx..]) or
        continuationsHaveReturnSwitchUnemittable(continuations[start_idx..]))
    {
        // TODO: Add tap support - currently disabled to avoid breaking all tests
        // if (continuationsMightHaveTaps(continuations[start_idx..], tap_registry, source_event_name)) {
        // Use normal continuation emission which handles labels via emitContinuationBody
        var ctx = EmissionContext{
            .allocator = std.heap.page_allocator, // temp allocator for result vars
            .indent_level = 0, // Will use emitter's indent
            .ast_items = all_items,
            .is_sync = true,
            .tap_registry = tap_registry, // Pass through tap registry for inline taps!
            .type_registry = type_registry,
            .main_module_name = main_module_name, // Pass through for canonical event naming
            .current_source_event = source_event_name, // Set source event for inline tap emission!
        };
        // A label-fold emitted through this subflow path (visitor emitter) still
        // runs `emitContinuationBody`'s `label_with_invocation` arm, which
        // registers each `#label` in `ctx.label_contexts` so a cross-level
        // `@label` jump (e.g. an outer loop fired from inside an inner fold) can
        // resolve its target handler/result-var and re-invoke it. Without this
        // map the registration is skipped (guard is `if (ctx.label_contexts)`),
        // the jump finds neither map entry nor current slot, and the outer loop's
        // result var is never reassigned -> Zig "never mutated" + infinite loop.
        // (emitFlow initializes the same map for the top-level flow path; this
        // is the equivalent for the subflow/visitor path.)
        var label_contexts = std.StringHashMap(LabelContext).init(ctx.allocator);
        ctx.label_contexts = &label_contexts;
        defer {
            var it = label_contexts.valueIterator();
            while (it.next()) |label_ctx| {
                ctx.allocator.free(label_ctx.result_var);
            }
            label_contexts.deinit();
        }
        var result_counter: usize = depth;
        const result_var = if (depth == 0) "result" else blk: {
            var buf: [32]u8 = undefined;
            break :blk try std.fmt.bufPrint(&buf, "nested_result_{d}", .{depth - 1});
        };

        // Group continuations by branch name to handle when-clauses
        const normal_branch_groups = try groupContinuationsByBranch(std.heap.page_allocator, continuations[start_idx..]);
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

                // Emit source marker for subflow branch
                if (cont.location.line > 0) {
                    try emitter.write(indent);
                    try emitter.write("    // >>> BRANCH: ");
                    try emitter.write(cont.location.file);
                    try emitter.write(":");
                    var sf_branch_line_buf: [32]u8 = undefined;
                    const sf_branch_line_str = try std.fmt.bufPrint(&sf_branch_line_buf, "{}", .{cont.location.line});
                    try emitter.write(sf_branch_line_str);
                    try emitter.write("  | ");
                    try emitter.write(cont.branch);
                    if (cont.binding) |b| {
                        try emitter.write(" ");
                        try emitter.write(b);
                    }
                    try emitter.write(" |>\n");
                }
                try emitter.write(indent);
                try emitter.write("    .");
                try writeBranchName(emitter, cont.branch);
                try emitter.write(" => ");

                // Check if THIS binding is actually referenced in the step
                // CRITICAL: Only set needs_binding if binding_name is used, not just any "."
                var needs_binding = false;
                if (cont.node) |step| {
                    switch (step) {
                        .invocation => |inv| {
                            for (inv.args) |arg| {
                                if (valueReferencesBinding(arg.value, binding_name)) {
                                    needs_binding = true;
                                    break;
                                }
                            }
                        },
                        .label_with_invocation => |lwi| {
                            for (lwi.invocation.args) |arg| {
                                if (valueReferencesBinding(arg.value, binding_name)) {
                                    needs_binding = true;
                                    break;
                                }
                            }
                        },
                        .branch_constructor => |bc| {
                            // Check plain value first (identity branch constructor)
                            if (bc.plain_value) |pv| {
                                if (valueReferencesBinding(pv, binding_name)) {
                                    needs_binding = true;
                                }
                            }
                            if (!needs_binding) {
                                for (bc.fields) |field| {
                                    const value = if (field.expression_str) |expr| expr else field.type;
                                    if (valueReferencesBinding(value, binding_name)) {
                                        needs_binding = true;
                                        break;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
                // Also check nested continuations for binding usage
                if (!needs_binding) {
                    needs_binding = bindingIsUsedInContinuations(binding_name, cont.continuations);
                }

                // Check if branch has payload fields - empty payloads shouldn't be captured
                const has_payload_fields = if (source_event_name) |event_name|
                    branchHasPayloadFieldsFromItems(all_items, event_name, cont.branch, main_module_name)
                else
                    true;

                if (has_payload_fields) {
                    try emitter.write("|");
                    try writeBranchName(emitter, binding_name);
                    try emitter.write("| ");
                }

                try emitter.write("{\n");

                // Suppress unused binding warning — safe even if binding IS used
                if (has_payload_fields) {
                    try emitter.write(indent);
                    try emitter.write("    _ = &");
                    try emitter.write(binding_name);
                    try emitter.write(";\n");
                }

                // Use emitContinuationBody which handles labels!
                var deeper_indent_buf: [128]u8 = undefined;
                @memcpy(deeper_indent_buf[0..indent.len], indent);
                const extra = "        ";
                @memcpy(deeper_indent_buf[indent.len .. indent.len + extra.len], extra);

                const old_indent = emitter.indent_level;
                emitter.indent_level = 0; // Reset to use manual indenting

                try emitContinuationBody(emitter, &ctx, cont, &result_counter);

                emitter.indent_level = old_indent;

                try emitter.write(indent);
                try emitter.write("    },\n");
            } else {
                // Multiple continuations for same branch - emit if/else chain for when-clauses

                // First continuation in group - get binding name
                const first_cont = group.continuations[0];
                const binding_name = first_cont.binding orelse first_cont.branch;

                // Check if ANY continuation in this group actually uses THIS binding
                // CRITICAL: Only set needs_binding if binding_name is referenced
                var needs_binding = false;
                for (group.continuations) |cont_ptr| {
                    const cont = cont_ptr.*;
                    if (cont.node) |step| {
                        switch (step) {
                            .invocation => |inv| {
                                for (inv.args) |arg| {
                                    if (valueReferencesBinding(arg.value, binding_name)) {
                                        needs_binding = true;
                                        break;
                                    }
                                }
                            },
                            .branch_constructor => |bc| {
                                // Check plain value first (identity branch constructor)
                                if (bc.plain_value) |pv| {
                                    if (valueReferencesBinding(pv, binding_name)) {
                                        needs_binding = true;
                                    }
                                }
                                if (!needs_binding) {
                                    for (bc.fields) |field| {
                                        const value = if (field.expression_str) |expr| expr else field.type;
                                        if (valueReferencesBinding(value, binding_name)) {
                                            needs_binding = true;
                                            break;
                                        }
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                    // Also check nested continuations
                    if (!needs_binding) {
                        needs_binding = bindingIsUsedInContinuations(binding_name, cont.continuations);
                    }
                    if (needs_binding) break;
                }

                // Write the branch case
                try emitter.write(indent);
                try emitter.write("    .");
                try writeBranchName(emitter, group.branch_name);
                try emitter.write(" => ");

                // Check if branch has payload fields - empty payloads shouldn't be captured
                const has_payload_fields = if (source_event_name) |event_name|
                    branchHasPayloadFieldsFromItems(all_items, event_name, group.branch_name, main_module_name)
                else
                    true;

                // Add binding if needed
                if (has_payload_fields) {
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
                            try emitter.write("if (");
                        } else {
                            try emitter.write("else if (");
                        }
                        try emitter.write(condition);
                        try emitter.write(") {\n");
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
                    emitter.indent_level = 0; // Reset to use manual indenting

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
    const branch_groups = try groupContinuationsByBranch(std.heap.page_allocator, continuations[start_idx..]);
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

            // CRITICAL FIX: Check if THIS binding is actually referenced
            // Only capture if actual_binding is used, not just any "."
            var needs_binding = false;

            // Check the step - but only if it references THIS binding
            if (cont.node) |step| {
                switch (step) {
                    .invocation => |inv| {
                        for (inv.args) |arg| {
                            if (valueReferencesBinding(arg.value, actual_binding)) {
                                needs_binding = true;
                                break;
                            }
                        }
                    },
                    .branch_constructor => |bc| {
                        // Check plain value first (identity branch constructor)
                        if (bc.plain_value) |pv| {
                            if (valueReferencesBinding(pv, actual_binding)) {
                                needs_binding = true;
                            }
                        }
                        if (!needs_binding) {
                            for (bc.fields) |field| {
                                const value = if (field.expression_str) |expr| expr else field.type;
                                if (valueReferencesBinding(value, actual_binding)) {
                                    needs_binding = true;
                                    break;
                                }
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

            // Check if branch has payload fields - empty payloads shouldn't be captured
            const has_payload_fields = if (source_event_name) |event_name|
                branchHasPayloadFieldsFromItems(all_items, event_name, cont.branch, main_module_name)
            else
                true;

            // Check what's in the step - check for invocations
            // (metatype_binding might be first, so can't just check step directly)
            var has_invocation = false;
            if (cont.node) |step| {
                if (step == .invocation) {
                    has_invocation = true;
                }
            }

            // Block path (has_invocation): capture binding when needed, suppress unused
            // Expression path (terminal): only capture if actually needed (can't suppress in expression)
            if (has_invocation) {
                // Step contains invocation - emit the step
                // This handles taps inserted by AST transformation (tap + branch constructor)
                if (needs_binding and has_payload_fields) {
                    try emitter.write("|");
                    try writeBranchName(emitter, actual_binding);
                    try emitter.write("| ");
                }
                try emitter.write("{\n");

                // Suppress unused binding warning — safe even if binding IS used
                if (needs_binding and has_payload_fields) {
                    try emitter.write(indent);
                    try emitter.write("        _ = &");
                    try writeBranchName(emitter, actual_binding);
                    try emitter.write(";\n");
                }

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
                                try writeMangledSeg(emitter, seg);
                            }
                            try emitter.write("_event.handler(.{");

                            // Look up event signature for positional arg name resolution
                            var event_name_buf: [256]u8 = undefined;
                            var event_name_pos: usize = 0;
                            // Build canonical event name: module:segment.segment
                            if (inv.path.module_qualifier) |mq| {
                                @memcpy(event_name_buf[event_name_pos .. event_name_pos + mq.len], mq);
                                event_name_pos += mq.len;
                                event_name_buf[event_name_pos] = ':';
                                event_name_pos += 1;
                            } else if (main_module_name) |mmn| {
                                @memcpy(event_name_buf[event_name_pos .. event_name_pos + mmn.len], mmn);
                                event_name_pos += mmn.len;
                                event_name_buf[event_name_pos] = ':';
                                event_name_pos += 1;
                            }
                            for (inv.path.segments, 0..) |seg, seg_i| {
                                if (seg_i > 0) {
                                    event_name_buf[event_name_pos] = '.';
                                    event_name_pos += 1;
                                }
                                @memcpy(event_name_buf[event_name_pos .. event_name_pos + seg.len], seg);
                                event_name_pos += seg.len;
                            }
                            const event_canonical = event_name_buf[0..event_name_pos];
                            const event_type = type_registry.getEventType(event_canonical);
                            var value_ctx = EmissionContext{
                                .allocator = std.heap.page_allocator,
                                .main_module_name = main_module_name,
                            };

                            for (inv.args, 0..) |arg, idx| {
                                if (idx > 0) try emitter.write(", ");
                                try emitter.write(" .");

                                // Check if this is a positional arg (name == value indicates synthesized name)
                                // If so, use the parameter name from the event signature
                                const param_name = if (std.mem.eql(u8, arg.name, arg.value)) blk: {
                                    // Positional arg - get name from event signature
                                    if (event_type) |et| {
                                        if (et.input_shape) |shape| {
                                            if (idx < shape.fields.len) {
                                                break :blk shape.fields[idx].name;
                                            }
                                        }
                                    }
                                    // Fallback: use arg.name (might produce invalid Zig)
                                    break :blk arg.name;
                                } else arg.name;

                                try writeBranchName(emitter, param_name);
                                try emitter.write(" = ");

                                // Check for Koru array literal syntax: [a, b, c]
                                if (arg.value.len >= 2 and arg.value[0] == '[' and arg.value[arg.value.len - 1] == ']') {
                                    const field = blk: {
                                        if (event_type) |et| {
                                            if (et.input_shape) |shape| {
                                                for (shape.fields) |*field| {
                                                    if (std.mem.eql(u8, field.name, param_name)) {
                                                        break :blk field;
                                                    }
                                                }
                                            }
                                        }
                                        break :blk null;
                                    };
                                    if (field) |field_info| {
                                        try emitArrayLiteralForField(emitter, &value_ctx, field_info, arg.value);
                                    } else {
                                        return error.ArrayLiteralMissingType;
                                    }
                                } else {
                                    try emitter.write(arg.value);
                                }
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
                            // Scope block uses the AST-provided binding (already made unique by tap transform).
                            try emitter.write(indent);
                            try emitter.write("        {\n");
                            try emitter.write(indent);
                            try emitter.write("            const ");
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
                                    // Escape keywords (e.g., .@"error" for error branch)
                                    if (codegen_utils.needsEscaping(mb.branch)) {
                                        try emitter.write("@\"");
                                        try emitter.write(mb.branch);
                                        try emitter.write("\"");
                                    } else {
                                        try emitter.write(mb.branch);
                                    }
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

                                // .payload field - ONLY for Audit
                                const is_audit = std.mem.eql(u8, mb.metatype, "Audit");
                                if (is_audit) {
                                    try emitter.write(indent);
                                    try emitter.write("            .payload = null,  // TODO: Serialize continuation payload\n");
                                }
                            }

                            try emitter.write(indent);
                            try emitter.write("        };\n");

                            // Emit continuations inside the scope block
                            if (cont.continuations.len > 0) {
                                var deeper_indent_buf: [128]u8 = undefined;
                                @memcpy(deeper_indent_buf[0..indent.len], indent);
                                const extra = "            ";
                                @memcpy(deeper_indent_buf[indent.len .. indent.len + extra.len], extra);
                                const deeper_indent = deeper_indent_buf[0 .. indent.len + extra.len];
                                try emitSubflowContinuationsWithDepth(emitter, cont.continuations, 0, deeper_indent, all_items, last_result_idx + 1, tap_registry, type_registry, main_module_name, source_event_name, module_prefix);
                            }

                            try emitter.write(indent);
                            try emitter.write("        }\n"); // Close scope block
                        },
                        .branch_constructor => |bc| {
                            // Branch constructor - emit return statement
                            try emitter.write(indent);
                            try emitter.write("        return .{ .");
                            try writeBranchName(emitter, bc.branch_name);
                            try emitter.write(" = ");
                            // Check for plain value (identity branch constructor)
                            if (bc.plain_value) |pv| {
                                try emitter.write(pv);
                            } else {
                                try emitter.write(".{");
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
                                try emitter.write(" }");
                            }
                            try emitter.write(" };\n");
                        },
                        else => {
                            // Other step types - not expected in return switch optimization path
                            // If we encounter them, this indicates AST structure we don't handle yet
                        },
                    }
                }

                // After emitting the step, recurse into nested continuations if present
                // Exception: metatype_binding handles its own continuation recursion inside its scope block
                // This must be OUTSIDE the step check so it runs regardless of what the step type was
                // Use last_result_idx + 1 as the depth for nested continuations (not depth + 1)
                // because metatype_binding steps don't create result variables
                const is_metatype_binding = if (cont.node) |step| step == .metatype_binding else false;
                if (cont.continuations.len > 0 and !is_metatype_binding) {
                    var deeper_indent_buf: [128]u8 = undefined;
                    @memcpy(deeper_indent_buf[0..indent.len], indent);
                    const extra = "        ";
                    @memcpy(deeper_indent_buf[indent.len .. indent.len + extra.len], extra);
                    const deeper_indent = deeper_indent_buf[0 .. indent.len + extra.len];
                    try emitSubflowContinuationsWithDepth(emitter, cont.continuations, 0, deeper_indent, all_items, last_result_idx + 1, tap_registry, type_registry, main_module_name, source_event_name, module_prefix);
                }

                try emitter.write(indent);
                try emitter.write("    },\n");
            } else {
                // Terminal case - branch constructor (expression path, no block)
                // Only capture binding if actually used — can't suppress unused in expression
                if (needs_binding and has_payload_fields) {
                    try emitter.write("|");
                    try writeBranchName(emitter, actual_binding);
                    try emitter.write("| ");
                }
                // Taps are now in the AST via tap_transformer, so just emit inline
                if (cont.node) |step| {
                    switch (step) {
                        .branch_constructor => |bc2| {
                            try emitter.write(".{ .");
                            try writeBranchName(emitter, bc2.branch_name);
                            try emitter.write(" = ");
                            // Check for plain value (identity branch constructor)
                            if (bc2.plain_value) |pv| {
                                try emitter.write(pv);
                            } else {
                                try emitter.write(".{");
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
                                try emitter.write(" }");
                            }
                            try emitter.write(" }");
                        },
                        else => {},
                    }
                } else {
                    try emitter.write("{}");
                }
                try emitter.write(",\n");
            } // End of if (has_invocation)
        } else {
            // Multiple continuations for same branch - emit if/else chain for when-clauses

            // First continuation in group - get binding name
            const first_cont = group.continuations[0].*;
            const actual_binding = first_cont.binding orelse first_cont.branch;

            // Check if ANY continuation in this group actually uses THIS binding
            var needs_binding = false;
            for (group.continuations) |cont_ptr| {
                const cont = cont_ptr.*;
                if (cont.node) |step| {
                    switch (step) {
                        .invocation => |inv| {
                            for (inv.args) |arg| {
                                if (valueReferencesBinding(arg.value, actual_binding)) {
                                    needs_binding = true;
                                    break;
                                }
                            }
                        },
                        .branch_constructor => |bc| {
                            // Check plain value first (identity branch constructor)
                            if (bc.plain_value) |pv| {
                                if (valueReferencesBinding(pv, actual_binding)) {
                                    needs_binding = true;
                                }
                            }
                            if (!needs_binding) {
                                for (bc.fields) |field| {
                                    const value = if (field.expression_str) |expr| expr else field.type;
                                    if (valueReferencesBinding(value, actual_binding)) {
                                        needs_binding = true;
                                        break;
                                    }
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

            // Check if branch has payload fields - empty payloads shouldn't be captured
            const has_payload_fields = if (source_event_name) |event_name|
                branchHasPayloadFieldsFromItems(all_items, event_name, group.branch_name, main_module_name)
            else
                true;

            if (needs_binding and has_payload_fields) {
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
                        try emitter.write("if (");
                    } else {
                        try emitter.write("else if (");
                    }
                    try emitter.write(condition);
                    try emitter.write(") ");
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
                            try emitter.write(" = ");
                            // Check for plain value (identity branch constructor)
                            if (bc.plain_value) |pv| {
                                try emitter.write(pv);
                            } else {
                                try emitter.write(".{");
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
                                try emitter.write(" }");
                            }
                            try emitter.write(" }");
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
        } // End of if (single vs multiple continuations)
    } // End of for loop over all branch groups

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
pub fn findEventDeclByPath(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
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

/// Find a proc declaration by its path
/// Used for checking purity of event implementations
pub fn findProcDeclByPath(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.ProcDecl {
    // Handle module qualifier
    if (path.module_qualifier) |module_qual| {
        for (items) |*item| {
            switch (item.*) {
                .module_decl => |*module| {
                    if (std.mem.eql(u8, module.logical_name, module_qual)) {
                        return findProcDeclByPathInModule(module.items, path.segments);
                    }
                },
                else => {},
            }
        }
        return findProcDeclByPathInModule(items, path.segments);
    }

    // No module qualifier - search for local procs
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*proc| {
                if (proc.path.segments.len == path.segments.len) {
                    var matches = true;
                    for (proc.path.segments, 0..) |segment, i| {
                        if (!std.mem.eql(u8, segment, path.segments[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        return proc;
                    }
                }
            },
            .module_decl => |*module| {
                if (findProcDeclByPath(module.items, path)) |found| {
                    return found;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Helper: Find proc by segments within a specific module's items
fn findProcDeclByPathInModule(items: []const ast.Item, segments: []const []const u8) ?*const ast.ProcDecl {
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*proc| {
                if (proc.path.segments.len == segments.len) {
                    var matches = true;
                    for (proc.path.segments, 0..) |segment, i| {
                        if (!std.mem.eql(u8, segment, segments[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        return proc;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// Find all variant proc_decls (proc.target != null) whose path matches the given path.
/// Caller owns the returned slice. Used by event-handler emission to generate
/// handler__<variant> functions alongside the bare handler.
pub fn findVariantProcsByPath(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    path: *const ast.DottedPath,
) ![]*const ast.ProcDecl {
    var found = std.ArrayList(*const ast.ProcDecl){};
    errdefer found.deinit(allocator);

    if (path.module_qualifier) |module_qual| {
        for (items) |*item| {
            if (item.* == .module_decl) {
                if (std.mem.eql(u8, item.module_decl.logical_name, module_qual)) {
                    try collectVariantProcsInModule(allocator, &found, item.module_decl.items, path.segments);
                    return try found.toOwnedSlice(allocator);
                }
            }
        }
        try collectVariantProcsInModule(allocator, &found, items, path.segments);
        return try found.toOwnedSlice(allocator);
    }

    try collectVariantProcsRecursive(allocator, &found, items, path.segments);
    return try found.toOwnedSlice(allocator);
}

fn collectVariantProcsInModule(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(*const ast.ProcDecl),
    items: []const ast.Item,
    segments: []const []const u8,
) !void {
    for (items) |*item| {
        if (item.* == .proc_decl) {
            const proc = &item.proc_decl;
            if (proc.target == null) continue;
            if (proc.path.segments.len != segments.len) continue;
            var matches = true;
            for (proc.path.segments, 0..) |segment, i| {
                if (!std.mem.eql(u8, segment, segments[i])) {
                    matches = false;
                    break;
                }
            }
            if (matches) try out.append(allocator, proc);
        }
    }
}

fn collectVariantProcsRecursive(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(*const ast.ProcDecl),
    items: []const ast.Item,
    segments: []const []const u8,
) !void {
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*proc| {
                if (proc.target == null) continue;
                if (proc.path.segments.len != segments.len) continue;
                var matches = true;
                for (proc.path.segments, 0..) |segment, i| {
                    if (!std.mem.eql(u8, segment, segments[i])) {
                        matches = false;
                        break;
                    }
                }
                if (matches) try out.append(allocator, proc);
            },
            .module_decl => |*module| {
                try collectVariantProcsRecursive(allocator, out, module.items, segments);
            },
            else => {},
        }
    }
}

/// Tagged union for the two kinds of impl items that can be found by path:
/// - An ImmediateImpl (constant/mock value)
/// - A Flow with impl_of set (flow-based implementation)
pub const FoundImpl = union(enum) {
    immediate_impl: *const ast.ImmediateImpl,
    flow: *const ast.Flow,
};

/// Find an implementation (ImmediateImpl or Flow with impl_of) by its event path.
/// Returns a FoundImpl tagged union if found.
/// NOTE: User-defined overrides at top level take precedence over module-internal implementations
pub fn findImplByPath(items: []const ast.Item, path: *const ast.DottedPath) ?FoundImpl {
    if (log.level == .debug) {
        log.debug("[findImplByPath] Looking for path: module_qual={s}, segments.len={d}\n", .{
            if (path.module_qualifier) |m| m else "(null)",
            path.segments.len,
        });
        for (path.segments) |seg| {
            log.debug("[findImplByPath]   segment: {s}\n", .{seg});
        }
    }

    // Handle module qualifier
    if (path.module_qualifier) |module_qual| {
        // Look inside module_decls for the implementation
        for (items) |*item| {
            switch (item.*) {
                .module_decl => |*module| {
                    if (std.mem.eql(u8, module.logical_name, module_qual)) {
                        log.debug("[findImplByPath] Looking in module '{s}'\n", .{module.logical_name});
                        return findImplByPathInModule(module.items, path.segments);
                    }
                },
                else => {},
            }
        }
        return findImplByPathInModule(items, path.segments);
    }

    // No module qualifier - search for local impls
    for (items) |*item| {
        switch (item.*) {
            .immediate_impl => |*ii| {
                if (ii.event_path.segments.len == path.segments.len) {
                    var matches = true;
                    for (ii.event_path.segments, 0..) |segment, i| {
                        if (!std.mem.eql(u8, segment, path.segments[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        return .{ .immediate_impl = ii };
                    }
                }
            },
            .flow => |*flow| {
                if (flow.impl_of) |impl_path| {
                    if (impl_path.segments.len == path.segments.len) {
                        var matches = true;
                        for (impl_path.segments, 0..) |segment, i| {
                            if (!std.mem.eql(u8, segment, path.segments[i])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            return .{ .flow = flow };
                        }
                    }
                }
            },
            .module_decl => |*module| {
                if (findImplByPath(module.items, path)) |found| {
                    return found;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Helper: Find impl by segments within a specific module's items
fn findImplByPathInModule(items: []const ast.Item, segments: []const []const u8) ?FoundImpl {
    for (items) |*item| {
        switch (item.*) {
            .immediate_impl => |*ii| {
                if (ii.event_path.segments.len == segments.len) {
                    var matches = true;
                    for (ii.event_path.segments, 0..) |segment, i| {
                        if (!std.mem.eql(u8, segment, segments[i])) {
                            matches = false;
                            break;
                        }
                    }
                    if (matches) {
                        return .{ .immediate_impl = ii };
                    }
                }
            },
            .flow => |*flow| {
                if (flow.impl_of) |impl_path| {
                    if (impl_path.segments.len == segments.len) {
                        var matches = true;
                        for (impl_path.segments, 0..) |segment, i| {
                            if (!std.mem.eql(u8, segment, segments[i])) {
                                matches = false;
                                break;
                            }
                        }
                        if (matches) {
                            return .{ .flow = flow };
                        }
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
/// The rendered form of `{{ h.inlined_link }}` is `__koru_inline_<idx>(arg)`,
/// where `<idx>` is the continuation's position in the node's continuation list.
const INLINE_SPLICE_PREFIX = "__koru_inline_";
const INLINE_CONTINUE_PREFIX = "__koru_continue_";

/// Write `inline_code` verbatim, resolving two kinds of template marker into the
/// invoking flow's continuation bodies — the effect/continuation symmetry, lowered:
///
///   - `__koru_inline_<idx>(arg)` (from `{{ h.inlined_link }}(arg)`) — an EFFECT
///     CALL: splice the handler body IN-SCOPE with the arg bound to its binding,
///     `{ const <binding> = <arg>; [if (<guard>)] { <body> } }`. Fires during.
///   - `__koru_continue_<idx>` (from `{{ continuations["X"].continue }}`) — a
///     CONTINUATION hand-off (continuation-passing): inlined, that collapses to
///     running the consumer's `| X |>` body at the hand-off point,
///     `{ [if (<guard>)] { <body> } }`. No arg — a no-payload terminal. Fires once.
///     (The Zig lowering of this is a `return`, but the surface name is `.continue`.)
///
/// Both index the same `continuations` slice the markers were minted against, so
/// they round-trip deterministically. An omitted optional terminal never minted a
/// marker, so its absence simply emits nothing. Markers resolve in source order.
/// Emit the consts for a shape-destructure binding: one
/// `const <name>[: <type>] = <prefix>.<name>;` per named leaf, recursing into
/// nested sub-shapes with longer access paths. `_` fields are skipped (the
/// payload field simply isn't bound). Interiors may be host types — the
/// emitter only writes access paths; Zig validates them at the next stage.
pub fn emitDestructureConsts(
    emitter: *CodeEmitter,
    fields: []const ast.DestructureField,
    prefix: []const u8,
) anyerror!void {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "_")) continue;
        if (f.sub.len > 0) {
            var path_buf: [256]u8 = undefined;
            const sub_prefix = std.fmt.bufPrint(&path_buf, "{s}.{s}", .{ prefix, f.name }) catch {
                @panic("destructure path too long");
            };
            try emitDestructureConsts(emitter, f.sub, sub_prefix);
            continue;
        }
        try emitter.write("const ");
        try writeBranchName(emitter, f.name);
        if (f.type_text) |t| {
            try emitter.write(": ");
            try emitter.write(t);
        }
        try emitter.write(" = ");
        try emitter.write(prefix);
        try emitter.write(".");
        try writeBranchName(emitter, f.name);
        try emitter.write("; _ = &");
        try writeBranchName(emitter, f.name);
        try emitter.write("; ");
    }
}

fn emitInlineCodeResolvingSplices(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inline_code: []const u8,
    continuations: []const ast.Continuation,
) anyerror!void {
    var pos: usize = 0;
    while (true) {
        // Find the earliest remaining marker of either kind.
        const splice_at = std.mem.indexOfPos(u8, inline_code, pos, INLINE_SPLICE_PREFIX);
        const continue_at = std.mem.indexOfPos(u8, inline_code, pos, INLINE_CONTINUE_PREFIX);
        var m: usize = undefined;
        var is_continue: bool = undefined;
        if (splice_at) |s| {
            if (continue_at) |r| {
                is_continue = r < s;
                m = if (is_continue) r else s;
            } else {
                is_continue = false;
                m = s;
            }
        } else if (continue_at) |r| {
            is_continue = true;
            m = r;
        } else {
            break; // no more markers
        }

        try emitter.write(inline_code[pos..m]);

        if (is_continue) {
            // CONTINUATION hand-off — run the terminal body once, here.
            var i = m + INLINE_CONTINUE_PREFIX.len;
            var idx: usize = 0;
            var saw_digit = false;
            while (i < inline_code.len and inline_code[i] >= '0' and inline_code[i] <= '9') : (i += 1) {
                idx = idx * 10 + (inline_code[i] - '0');
                saw_digit = true;
            }
            if (saw_digit and idx < continuations.len) {
                const cont = &continuations[idx];
                try emitter.write("{ ");
                const guarded = cont.condition != null;
                if (guarded) {
                    try emitter.write("if (");
                    try emitter.write(cont.condition.?);
                    try emitter.write(") { ");
                }
                // Give the spliced body a unique `result_N` namespace, so a
                // branched event inside it (e.g. an `if`-arm's `commit`, or a
                // `for`-`done`'s nested call) doesn't shadow the enclosing scope's
                // `result_0`. Mirrors the per-branch prefix swap used for loop
                // branches (search `branch_prefix`). `prefix_buf` lives for the
                // emit below; restored after.
                const saved_prefix = ctx.result_prefix;
                var prefix_buf: [64]u8 = undefined;
                ctx.result_prefix = std.fmt.bufPrint(&prefix_buf, "result_c{d}_", .{idx}) catch "result_";
                defer ctx.result_prefix = saved_prefix;
                var c: usize = 0;
                try emitContinuationBody(emitter, ctx, cont, &c);
                if (guarded) try emitter.write(" }");
                try emitter.write(" }");
            } else {
                try emitter.write(inline_code[m..i]); // unresolvable; loud
            }
            pos = i;
            continue;
        }

        // EFFECT CALL — splice the handler body in-scope with the arg bound.
        // Parse `<idx>` after the prefix. An optional `scoped_` infix
        // (`__koru_inline_scoped_<idx>`, from `{{ h.inlined_link[scope] }}`)
        // carries no emission meaning here — scope is consumed by auto_discharge
        // via the `@scope` annotation already stamped on the continuation — so
        // splice the body identically; just skip past the infix to the digits.
        var i = m + INLINE_SPLICE_PREFIX.len;
        const SCOPED_INFIX = "scoped_";
        if (std.mem.startsWith(u8, inline_code[i..], SCOPED_INFIX)) i += SCOPED_INFIX.len;
        var idx: usize = 0;
        var saw_digit = false;
        while (i < inline_code.len and inline_code[i] >= '0' and inline_code[i] <= '9') : (i += 1) {
            idx = idx * 10 + (inline_code[i] - '0');
            saw_digit = true;
        }

        // Read the `(arg)` immediately following (balanced parens).
        var arg: []const u8 = "";
        if (saw_digit and i < inline_code.len and inline_code[i] == '(') {
            const arg_start = i + 1;
            var depth: usize = 1;
            var j = arg_start;
            var q: u8 = 0; // quote state: parens in literals are text (210_122 family)
            while (j < inline_code.len and depth > 0) : (j += 1) {
                const ch = inline_code[j];
                if (q != 0) {
                    if (ch == '\\') {
                        j += 1;
                    } else if (ch == q) {
                        q = 0;
                    }
                    continue;
                }
                if (ch == '"' or ch == '\'') {
                    q = ch;
                } else if (ch == '(') {
                    depth += 1;
                } else if (ch == ')') {
                    depth -= 1;
                }
            }
            arg = std.mem.trim(u8, inline_code[arg_start .. j - 1], " \t");
            i = j; // past the closing ')'
            // The marker resolves to a block statement (`{ … }`), so swallow a
            // trailing `;` the template wrote in call-statement shape
            // (`{{ h.inlined_link }}(arg);`) — otherwise `{ … };` is a dangling
            // empty statement Zig rejects.
            if (i < inline_code.len and inline_code[i] == ';') i += 1;
        }

        if (saw_digit and idx < continuations.len) {
            const cont = &continuations[idx];
            const binding = cont.binding orelse "_";
            try emitter.write("{ ");
            if (arg.len == 0) {
                // Void-payload effect (`pong()`): nothing to bind, nothing
                // to discard — just the body.
            } else if (cont.destructure.len > 0) {
                // Shape-destructure: bind the arg once, then per-field consts.
                // SITE-UNIQUE temp name (location-suffixed, same lesson as the
                // regex transform's __koru_match_in / __koru_sp): a match nested
                // inside another match's branch inlines into the SAME frame here,
                // so a fixed `__koru_dst` shadows the outer one and Zig rejects it
                // (surfaced by AoC day16: `Sue …` match → per-piece match).
                var dst_buf: [64]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "__koru_dst_{d}_{d}", .{ cont.location.line, cont.location.column }) catch "__koru_dst";
                try emitter.write("const ");
                try emitter.write(dst);
                try emitter.write(" = ");
                try emitter.write(arg);
                try emitter.write("; _ = &");
                try emitter.write(dst);
                try emitter.write("; ");
                try emitDestructureConsts(emitter, cont.destructure, dst);
            } else if (std.mem.eql(u8, binding, "_")) {
                try emitter.write("_ = ");
                try emitter.write(arg);
                try emitter.write("; ");
            } else if (std.mem.eql(u8, std.mem.trim(u8, arg, " \t"), binding)) {
                // The splice arg IS the binding (an inline-lowered proc local
                // sharing the name): rebinding would self-shadow — use as-is.
            } else {
                try emitter.write("const ");
                try writeBranchName(emitter, binding);
                try emitter.write(" = ");
                try emitter.write(arg);
                try emitter.write("; _ = &");
                try writeBranchName(emitter, binding);
                try emitter.write("; ");
            }
            const guarded = cont.condition != null;
            if (guarded) {
                try emitter.write("if (");
                try emitter.write(cont.condition.?);
                try emitter.write(") { ");
            }
            // Give the spliced effect body a unique `result_N` namespace, so a
            // branched event inside it (e.g. `! each _ |> step() |> get()`)
            // doesn't shadow the enclosing scope's `result_0`. The splice lands
            // inside a nested Zig block but at the SAME function scope, where Zig
            // forbids shadowing — so the inner calls must not reuse the outer
            // prefix. Mirrors the CONTINUE-marker path above; the distinct `e`
            // tag keeps effect splices and continue hand-offs from colliding
            // when both appear in one template (a `for` with `! each` + `| done`).
            const saved_prefix = ctx.result_prefix;
            var prefix_buf: [128]u8 = undefined;
            // NEST the namespace inside the enclosing prefix instead of replacing
            // it: a nested effect splice (e.g. `for` inside `for`) must get a
            // prefix distinct from its parent's. Replacing collapses both to
            // `result_e0_` → both emit `result_e0_0` at the same Zig function
            // scope → "shadows local constant". Appending gives `result_e0_`
            // (outer) vs `result_e0_e0_` (inner).
            ctx.result_prefix = std.fmt.bufPrint(&prefix_buf, "{s}e{d}_", .{ saved_prefix, idx }) catch saved_prefix;
            defer ctx.result_prefix = saved_prefix;
            var c: usize = 0;
            try emitContinuationBody(emitter, ctx, cont, &c);
            if (guarded) try emitter.write(" }");
            try emitter.write(" }");
        } else {
            // Unresolvable marker — emit verbatim so it fails loudly at Zig
            // compile rather than silently miscompiling.
            try emitter.write(inline_code[m..i]);
        }
        pos = i;
    }
    try emitter.write(inline_code[pos..]);
}

/// Write inline transform code, substituting the `__KORU_INLINE__` label
/// placeholder (used by value-producing inline bodies like fmt:ln's
/// `break :__KORU_INLINE__ value` block) with a unique label and prefixing
/// the block with that label. Mirrors the substitution visitor_emitter does
/// for top-level flows, so value-shaped inline bodies work at every depth.
fn writeInlineCodeWithLabel(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inline_code: []const u8,
) !void {
    const placeholder = "__KORU_INLINE__";
    if (std.mem.indexOf(u8, inline_code, placeholder) == null) {
        try emitter.write(inline_code);
        return;
    }

    var label_buf: [48]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "__koru_inline_{d}__", .{ctx.inline_label_counter}) catch unreachable;
    ctx.inline_label_counter += 1;

    try emitter.write(label);
    try emitter.write(": ");
    var scan: usize = 0;
    while (scan < inline_code.len) {
        if (scan + placeholder.len <= inline_code.len and
            std.mem.eql(u8, inline_code[scan .. scan + placeholder.len], placeholder))
        {
            try emitter.write(label);
            scan += placeholder.len;
        } else {
            try emitter.write(inline_code[scan .. scan + 1]);
            scan += 1;
        }
    }
}

/// Emit a node whose template transform produced `inline_body` (zero-overhead
/// control flow: `~if`, `~for`, …). Shared by `emitFlow` (top-level) and
/// `emitContinuationBody` (nested), so the inline-template lowering works
/// identically at every depth — there is no "only top-level" path. Covers:
///   - statement / void-continuation inline emission (incl. the `! each`
///     effect-branch Handlers bridge), and
///   - the `[expand]` `switch (__expand_result)` form.
/// `continuations` are the node's branch continuations; `path` is the invoked
/// event's path (for effect-branch lookup).
pub fn emitInlineBodyNode(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inline_code_raw: []const u8,
    continuations: []const ast.Continuation,
    path: *const ast.DottedPath,
    result_counter: *usize,
) anyerror!void {
    const inline_stmt_marker = "//@koru:inline_stmt\n";
    var inline_code = inline_code_raw;
    var is_inline_stmt = false;
    if (std.mem.indexOf(u8, inline_code, inline_stmt_marker)) |marker_idx| {
        is_inline_stmt = true;
        inline_code = inline_code[marker_idx + inline_stmt_marker.len ..];
    }

    const trimmed_inline = std.mem.trimRight(u8, inline_code, " \t\r\n");
    // Check if inline code is already a statement (ends with ;) or is comment-only (no ; needed)
    const is_comment_only = blk: {
        const trimmed_left = std.mem.trimLeft(u8, trimmed_inline, " \t");
        break :blk trimmed_left.len == 0 or
            (trimmed_left.len >= 2 and std.mem.eql(u8, trimmed_left[0..2], "//"));
    };
    const inline_is_statement = is_comment_only or is_inline_stmt or
        (trimmed_inline.len > 0 and trimmed_inline[trimmed_inline.len - 1] == ';');
    const only_void_continuations = blk: {
        if (continuations.len == 0) break :blk true;
        for (continuations) |cont| {
            if (cont.branch.len != 0) break :blk false;
        }
        break :blk true;
    };

    if (inline_is_statement or only_void_continuations) {
        // Effect-branch template pump: when the invoked event declares `!`
        // effect branches, the template body (inline_code) references the
        // effect symbols by name — e.g. a `|template|zig` `for` loop body
        // that calls `each(item)`. Unlike a plain `|zig` proc (whose body
        // lives inside the event handler, where `const each = __H.each`
        // aliases resolve), a template body is substituted directly into
        // this function, so the effect symbols are undeclared here.
        //
        // Bridge them: (1) synthesize the Handlers_0 struct from the effect
        // continuations, (2) alias every declared effect branch to a local
        // `const NAME = Handlers_0.NAME;` so the template body's calls
        // resolve, and (3) emit ONLY terminal continuations as loose
        // bodies afterward — the effect bodies now live inside Handlers_0,
        // not as orphaned statements. See docs/EFFECT_BRANCHES.md and
        // 400_071 (the plain-`|zig` analogue) for the target shape.
        const inline_event_decl = if (ctx.ast_items) |items|
            findEventDeclByPath(items, path)
        else
            null;

        var inline_has_effect = false;
        if (inline_event_decl) |ed| {
            for (ed.branches) |b| {
                if (b.kind == .effect) {
                    inline_has_effect = true;
                    break;
                }
            }
        }

        if (inline_has_effect) {
            const ed = inline_event_decl.?;

            // Partition continuations into effect (`!`) and terminal (`|`).
            var inline_effect_conts: std.ArrayList(ast.Continuation) = .empty;
            defer inline_effect_conts.deinit(ctx.allocator);
            var inline_terminal_conts: std.ArrayList(ast.Continuation) = .empty;
            defer inline_terminal_conts.deinit(ctx.allocator);
            for (continuations) |cont| {
                if (cont.kind == .effect) {
                    try inline_effect_conts.append(ctx.allocator, cont);
                } else {
                    try inline_terminal_conts.append(ctx.allocator, cont);
                }
            }

            // Uniquify the `for`-template loop capture. The `~for` template
            // (koru_std/control.kz) renders a hardcoded `for (..) |__koru_item|`
            // capture and passes `__koru_item` as the splice arg. When one `for`
            // splices another (`for(..) ! each i |> for(..) ! each j |> …`), both
            // instances land in the SAME Zig function with the same capture name,
            // and Zig rejects `capture '__koru_item' shadows capture from outer
            // scope`. Give each template instance a unique capture by rewriting
            // the bare `__koru_item` token to `__koru_item_<for_id>` throughout
            // this rendered body (both the `|capture|` site and the splice arg).
            // Mirrors the `__for_item_<id>` uniquification on the legacy foreach
            // path. We rewrite a private copy; the original AST string is left
            // untouched.
            const KORU_ITEM = "__koru_item";
            var inline_code_owned: ?[]u8 = null;
            defer if (inline_code_owned) |owned| ctx.allocator.free(owned);
            if (std.mem.indexOf(u8, inline_code, KORU_ITEM) != null) {
                const for_id = ctx.for_counter;
                ctx.for_counter += 1;
                var unique_buf: [64]u8 = undefined;
                const unique_item = std.fmt.bufPrint(&unique_buf, "__koru_item_{d}", .{for_id}) catch KORU_ITEM;
                const rewritten = try std.mem.replaceOwned(u8, ctx.allocator, inline_code, KORU_ITEM, unique_item);
                inline_code_owned = rewritten;
                inline_code = rewritten;
            }

            // SPLICE path: a template can request a handler body be inlined
            // IN-SCOPE (rather than called through an isolated Handlers fn) via
            // the `{{ h.inlined_link }}(arg)` symbol, which renders to a
            // `__koru_inline_<idx>(arg)` marker. This is how `~for` keeps the
            // loop body in the enclosing scope — so it can reference outer
            // bindings (`! each i |> process(value: p.items[i])`, `p` from an
            // outer `| result p`). A Handlers-struct fn can't close over those
            // locals; a spliced body can. No special-casing — any template, any
            // branch, any placement; the symbol drives it.
            if (std.mem.indexOf(u8, inline_code, INLINE_SPLICE_PREFIX) != null) {
                try emitter.writeIndent();
                try emitInlineCodeResolvingSplices(emitter, ctx, inline_code, continuations);
                try emitter.write("\n");

                // Terminal continuations are NOT appended here. A template hands
                // off to its terminal via `{{ continuations["X"].continue }}`, which
                // the resolver above lowers into the consumer dispatch. An
                // effect-bearing template with no `.continue` simply emits no
                // terminal body (e.g. a `for` with no `| done`).
                _ = &inline_terminal_conts;
                return;
            }

            // (1) Synthesize the Handlers struct from effect continuations.
            const hname = "Handlers_0";
            try emitHandlersStruct(emitter, ctx, hname, inline_effect_conts.items, ed);

            // (2) Alias every declared effect branch into local scope so the
            //     template body's bare `NAME(...)` calls resolve. Mirrors the
            //     handler-side aliasing (`const NAME = __H.NAME;`).
            for (ed.branches) |b| {
                if (b.kind != .effect) continue;
                try emitter.writeIndent();
                try emitter.write("const ");
                try writeBranchName(emitter, b.name);
                try emitter.write(" = ");
                try emitter.write(hname);
                try emitter.write(".");
                try writeBranchName(emitter, b.name);
                try emitter.write(";\n");
                try emitter.writeIndent();
                try emitter.write("_ = &");
                try writeBranchName(emitter, b.name);
                try emitter.write(";\n");
            }

            // Emit the template body (the producer pump). Route through the
            // marker resolver so any `__koru_continue_<idx>` from the template's
            // `{{ continuations["X"].continue }}` lowers to the consumer's terminal
            // body. (Effect calls here go through the aliased Handlers fns above,
            // not `__koru_inline_` splices, so only continue-markers resolve.)
            try emitter.writeIndent();
            try emitInlineCodeResolvingSplices(emitter, ctx, inline_code, continuations);
            if (!inline_is_statement) {
                try emitter.write(";");
            }
            try emitter.write("\n");

            // Terminal continuations are not appended — the template hands off to
            // them via the resolved `__koru_continue_<idx>` markers above.
            _ = &inline_terminal_conts;
            return;
        }

        // No-effect inline template (e.g. `~if`): route through the marker
        // resolver so the template's `{{ continuations["X"].return }}` markers
        // (`__koru_return_<idx>`) lower into the matching arm. Only VOID-chain
        // continuations are appended after (the flow continues); terminal
        // (named) continuations are RETURNED by the template, not appended.
        try emitter.writeIndent();
        try emitInlineCodeResolvingSplices(emitter, ctx, inline_code, continuations);
        if (!inline_is_statement) {
            try emitter.write(";");
        }
        try emitter.write("\n");

        // Void-chain continuations share the CALLER's result counter — at
        // depth the chain continues in the same Zig scope, and a reset here
        // re-issues result_N names that shadow the enclosing scope's.
        for (continuations) |*cont| {
            if (cont.branch.len != 0) continue; // terminal — returned, not appended
            try emitContinuationBody(emitter, ctx, cont, result_counter);
        }
        return;
    }

    // Flow also has continuations - generate a switch statement. Used by
    // [expand] events with branches: template provides the expression,
    // continuations provide the switch arms.
    if (continuations.len > 0) {
        // Emit: const __expand_result = <inline_code>;
        try emitter.writeIndent();
        try emitter.write("const __expand_result = ");
        try writeInlineCodeWithLabel(emitter, ctx, inline_code);
        try emitter.write(";\n");

        // Emit: switch (__expand_result) { ... }
        try emitter.writeIndent();
        try emitter.write("switch (__expand_result) {\n");
        emitter.indent();

        // Emit each continuation as a switch arm
        var step_idx: usize = 0;
        for (continuations) |*cont| {
            try emitter.writeIndent();
            try emitter.write(".");
            try writeBranchName(emitter, cont.branch);
            try emitter.write(" => ");

            if (cont.binding) |binding| {
                // Check if binding starts with "_" (discard pattern)
                // If so, use |_| to avoid unused variable warnings
                if (binding.len > 0 and binding[0] == '_') {
                    try emitter.write("|_| ");
                } else {
                    try emitter.write("|");
                    try emitter.write(binding);
                    try emitter.write("| ");
                }
            }

            try emitter.write("{\n");
            emitter.indent();

            // Emit the continuation body
            try emitContinuationBody(emitter, ctx, cont, &step_idx);

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("},\n");
        }

        emitter.dedent();
        try emitter.writeIndent();
        try emitter.write("}\n");
        return;
    }
}

pub fn emitFlow(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    flow: *const ast.Flow,
) !void {
    // Set flow metadata for InvocationMeta injection
    // Save previous values to restore after (for nested flows)
    const prev_flow_annotations = ctx.current_flow_annotations;
    const prev_flow_location = ctx.current_flow_location;
    ctx.current_flow_annotations = if (flow.annotations.len > 0) flow.annotations else null;
    ctx.current_flow_location = flow.location;
    defer {
        ctx.current_flow_annotations = prev_flow_annotations;
        ctx.current_flow_location = prev_flow_location;
    }

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
        for (flow.body.continuations) |*cont| {
            try emitContinuationBody(emitter, ctx, cont, &result_counter);
        }
        return; // Done - don't emit the invocation
    }

    // Zero-overhead control flow: if a template transform set inline_body, emit
    // it (and any continuations) via the shared node emitter — the same path a
    // nested inline node takes, so this works at every depth, not just top-level.
    if (flow.inline_body) |inline_code_raw| {
        var inline_result_counter: usize = 0;
        try emitInlineBodyNode(emitter, ctx, inline_code_raw, flow.body.continuations, &flow.inv().path, &inline_result_counter);
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
    const source_event = try buildCanonicalEventName(&flow.inv().path, ctx.allocator, ctx.main_module_name);
    defer ctx.allocator.free(source_event);
    ctx.current_source_event = source_event;

    // Check if this flow has a pre_label - if so, emit state variables and wrap in a while loop
    if (flow.pre_label) |label| {
        // Look up event definition to get parameter types
        const event_decl = if (ctx.ast_items) |items|
            findEventDeclByPath(items, &flow.inv().path)
        else
            null;

        // Determine if label will be mutated by checking for .label_jump
        const label_is_mutable = labelWillBeMutated(label, flow.body.continuations);

        // CRITICAL: If mutable, we MUST have type annotations (Zig forbids var with comptime_int)
        if (label_is_mutable and event_decl == null) {
            std.debug.panic("COMPILER BUG: Cannot find event declaration for loop variable '{s}' when emitting mutable label '{s}'. Event lookup failed for invocation path with {} segments.", .{
                if (flow.inv().args.len > 0) flow.inv().args[0].name else "(no args)",
                label,
                flow.inv().path.segments.len,
            });
        }

        // Emit state variables for loop parameters with type annotations
        for (flow.inv().args) |arg| {
            try emitter.writeIndent();
            // Use var if label will be mutated by label_jump, const otherwise
            if (label_is_mutable) {
                try emitter.write("var ");
            } else {
                try emitter.write("const ");
            }
            try emitter.write(label);
            try emitter.write("_");
            try writeBranchName(emitter, arg.name);

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

    // Effect-branches phase 3b: partition continuations into terminal (`|`) and
    // effect (`!`). Yielding conts lower to fns inside a synthesized Handlers
    // struct passed as the 2nd arg to .handler(); terminal conts continue to
    // drive the post-call switch/extract logic. See docs/EFFECT_BRANCHES.md.
    //
    // The driver is "event has effect-branch decls," NOT "consumer has effect
    // conts" — because the proc-side handler signature carries the comptime
    // arg whenever the event declares ANY effect branch, even when every one
    // is OPTIONAL and the consumer omits all of them. In that case Handlers
    // is still synthesized; the no-op pass in emitHandlersStruct fills it.
    const event_decl_for_partition = if (ctx.ast_items) |items|
        findEventDeclByPath(items, &flow.inv().path)
    else
        null;

    var event_has_effect_branch = false;
    if (event_decl_for_partition) |ed| {
        for (ed.branches) |b| {
            if (b.kind == .effect) {
                event_has_effect_branch = true;
                break;
            }
        }
    }

    var terminal_conts_buf: std.ArrayList(ast.Continuation) = .empty;
    defer terminal_conts_buf.deinit(ctx.allocator);
    var effect_conts_buf: std.ArrayList(ast.Continuation) = .empty;
    defer effect_conts_buf.deinit(ctx.allocator);

    if (event_has_effect_branch) {
        for (flow.body.continuations) |cont| {
            if (cont.kind == .effect) {
                try effect_conts_buf.append(ctx.allocator, cont);
            } else {
                try terminal_conts_buf.append(ctx.allocator, cont);
            }
        }
    }

    const conts: []const ast.Continuation = if (event_has_effect_branch)
        terminal_conts_buf.items
    else
        flow.body.continuations;

    // Inline lowering: eligible effectful invocations splice the proc body
    // at this site (one frame, no Handlers struct). See EFFECT INLINING.
    const inline_elig = if (event_has_effect_branch and flow.pre_label == null)
        inlineEffectfulEligibility(ctx, flow.inv(), flow.body.continuations)
    else
        null;

    var handlers_name_owned: ?[]const u8 = null;
    defer if (handlers_name_owned) |h| ctx.allocator.free(h);
    if (event_has_effect_branch and inline_elig == null) {
        if (event_decl_for_partition) |ed| {
            const hname = try std.fmt.allocPrint(ctx.allocator, "Handlers_{d}", .{result_counter});
            handlers_name_owned = hname;
            try emitHandlersStruct(emitter, ctx, hname, effect_conts_buf.items, ed);
            ctx.pending_handlers_name = hname;
        }
    }
    defer ctx.pending_handlers_name = null;

    // If there are no continuations, discard the result
    if (conts.len > 0) {
        // Check if this is a void event (empty branch) - if so, discard result
        const is_void_event = conts.len == 1 and
            std.mem.eql(u8, conts[0].branch, "");

        const first_result = if (is_void_event)
            "_" // Discard void result
        else
            try std.fmt.allocPrint(ctx.allocator, "result_{}", .{result_counter});

        defer if (!is_void_event) ctx.allocator.free(first_result);

        // If we have a pre_label, emit first invocation BEFORE the while loop
        if (flow.pre_label) |label| {
            // Analyze which branches loop back to this label
            const looping_branches = try findLoopingBranches(label, conts, ctx.allocator);
            defer ctx.allocator.free(looping_branches);

            // Emit FIRST invocation before the loop (to get initial result)
            try emitter.writeIndent();
            try emitter.write("var "); // var, not const - we'll update it in the loop!
            try emitter.write(first_result);
            try emitter.write(" = ");
            if (!ctx.is_sync) {
                try emitter.write("try ");
            }
            try emitInvocationTarget(emitter, ctx, &flow.inv().path);
            try emitter.write(".handler(.{ ");
            // Use state variables for initial call
            for (flow.inv().args, 0..) |arg, idx| {
                if (idx > 0) {
                    try emitter.write(", ");
                }
                try emitter.write(".");
                try writeBranchName(emitter, arg.name);
                try emitter.write(" = ");
                try emitter.write(label);
                try emitter.write("_");
                try writeBranchName(emitter, arg.name);
            }
            try emitter.write(" }");
            // Effect-branches phase 3b: pass synthesized Handlers struct as 2nd arg.
            if (ctx.pending_handlers_name) |hname| {
                try emitter.write(", ");
                try emitter.write(hname);
            }
            try emitter.write(");\n");

            // Register this label in the context map (for cross-level jumps)
            if (ctx.label_contexts) |label_map| {
                // Need to duplicate the result string since first_result will be freed
                const result_copy = try ctx.allocator.dupe(u8, first_result);
                try label_map.put(label, .{
                    .handler_invocation = flow.inv(),
                    .result_var = result_copy,
                    .handlers_name = ctx.pending_handlers_name,
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
            ctx.label_handler_invocation = flow.inv();
            ctx.label_result_var = first_result;
        } else {
            if (inline_elig) |elig| {
                try emitInlineEffectfulCall(emitter, ctx, flow.inv(), flow.body.continuations, elig, first_result, result_counter);
            } else {
                try emitInvocation(emitter, ctx, flow.inv(), first_result);
                // A bare-return head bind (`~e(...): name |> ...`) creates `name`
                // at the head, outside the continuation machinery that suppresses
                // unused branch binds. If no downstream continuation references
                // `name`, emit the suppressor (mirrors the branch-bind path).
                // containsIdentifier excludes string-literal matches, so `name`
                // appearing only inside a literal like "no name given" is unused.
                if (flow.inv().return_binding) |rb| {
                    if (!std.mem.eql(u8, rb, "_")) {
                        var rb_used = false;
                        for (conts) |*c| {
                            if (continuationUsesBinding(c, rb)) {
                                rb_used = true;
                                break;
                            }
                        }
                        if (!rb_used) {
                            try emitter.writeIndent();
                            try emitter.write("_ = &");
                            try writeBranchName(emitter, rb);
                            try emitter.write(";\n");
                        }
                    }
                }
            }
        }

        result_counter += 1;

        // If we have a pre_label, we need to split continuations into looping and non-looping
        if (flow.pre_label) |label| {
            const looping_branches = try findLoopingBranches(label, conts, ctx.allocator);
            defer ctx.allocator.free(looping_branches);

            // If NO branches loop, the label is unused - just emit all continuations normally
            if (looping_branches.len == 0) {
                // Clear the label context since we won't use it
                ctx.label_handler_invocation = null;
                ctx.label_result_var = null;

                // Emit all continuations as a regular switch (no loop)
                try emitContinuationList(emitter, ctx, conts, first_result, &result_counter, false);
            } else {
                // ONLY emit looping branches inside the while loop
                // Build list of looping continuations
                var looping_conts = try std.ArrayList(ast.Continuation).initCapacity(ctx.allocator, looping_branches.len);
                defer looping_conts.deinit(ctx.allocator);

                for (conts) |cont| {
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
                if (looping_branches.len < conts.len) {
                    // Build list of non-looping continuations
                    var non_looping_conts = try std.ArrayList(ast.Continuation).initCapacity(ctx.allocator, conts.len - looping_branches.len);
                    defer non_looping_conts.deinit(ctx.allocator);

                    for (conts) |cont| {
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
            try emitContinuationList(emitter, ctx, conts, first_result, &result_counter, false);
        }
    } else {
        // Zero continuations — use comptime_result_binding if set (for program return)
        const binding = if (ctx.comptime_result_binding) |b| b else "_";
        if (inline_elig != null and ctx.comptime_result_binding == null) {
            try emitInlineEffectfulCall(emitter, ctx, flow.inv(), flow.body.continuations, inline_elig.?, null, 0);
        } else {
            try emitInvocation(emitter, ctx, flow.inv(), binding);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// EFFECT INLINING (cut 1) — effectful runtime events compile to completely
// inlinable, monomorphized code (Lars-ratified 2026-06-12). The proc body
// is spliced AT THE INVOCATION SITE inside a labeled block: effect calls
// become `__koru_inline_<idx>(arg)` markers (resolved by the same splice
// resolver templates and match use — handler bodies land IN FLOW SCOPE,
// where cells and bindings are ordinary locals), and proc-exit `return`s
// become labeled breaks feeding the ordinary terminal switch. One frame.
// No Handlers struct, no namespace boundary, no side channels.
//
// Cut-1 boundaries (ineligible shapes keep the legacy call path; each is a
// FRONTIERS follow-up): mock/subflow impls (no zig proc — 395_009), resume-
// typed effects, multiple/guard-grouped handlers per effect branch, variant
// invocations, label loops, return-less procs on terminal-bearing events.
// Inlined proc bodies must be SCOPE-PORTABLE: params, effect names, `std.`
// (rewritten to `@import("std").`), and file-scope spine fns only — a
// nested `fn` in the body is rejected (no token rewriting inside it would
// be sound). Recursion of effectful events is structurally impossible to
// inline and is NOT supported, by ruling.
// ═══════════════════════════════════════════════════════════════════════

fn lowerIdent(buf: []u8, name: []const u8) []const u8 {
    for (name, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return buf[0..name.len];
}

fn findDefaultZigProc(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.ProcDecl {
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*proc| {
                if (procPathMatches(proc, path) and procIsZig(proc)) return proc;
            },
            .module_decl => |*m| {
                for (m.items) |*mi| {
                    if (mi.* != .proc_decl) continue;
                    const proc = &mi.proc_decl;
                    if (procPathMatches(proc, path) and procIsZig(proc)) return proc;
                }
            },
            else => {},
        }
    }
    return null;
}

fn procPathMatches(proc: *const ast.ProcDecl, path: *const ast.DottedPath) bool {
    if (proc.path.segments.len != path.segments.len) return false;
    for (proc.path.segments, path.segments) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn procIsZig(proc: *const ast.ProcDecl) bool {
    const t = proc.target orelse return false;
    return std.mem.eql(u8, t, "zig");
}

const InlineEligibility = struct {
    event_decl: *const ast.EventDecl,
    proc: *const ast.ProcDecl,
};

/// Decide whether this flow's invocation takes the inline lowering.
/// Returning null means: legacy call path, exactly today's behavior.
fn inlineEffectfulEligibility(ctx: *EmissionContext, inv: *const ast.Invocation, conts: []const ast.Continuation) ?InlineEligibility {
    const items = ctx.ast_items orelse return null;
    if (inv.variant != null) return null;
    const event_decl = findEventDeclByPath(items, &inv.path) orelse return null;

    var has_effect = false;
    var has_terminal_branch = false;
    for (event_decl.branches) |b| {
        if (b.kind == .effect) {
            has_effect = true;
            if (b.resume_type != null) return null;
        } else {
            has_terminal_branch = true;
        }
    }
    if (!has_effect) return null;

    // At most one handler per effect branch (guard groups keep the call path).
    for (conts) |*c| {
        if (c.kind != .effect) continue;
        var n: usize = 0;
        for (conts) |*c2| {
            if (c2.kind == .effect and std.mem.eql(u8, c2.branch, c.branch)) n += 1;
        }
        if (n > 1) return null;
    }

    const proc = findDefaultZigProc(items, &event_decl.path) orelse return null;

    // A nested fn makes token rewriting unsound; a terminal-bearing event
    // whose proc never `return`s relies on the legacy glue's synthesized
    // tail. Both keep the call path.
    if (containsToken(proc.body.text, "fn")) return null;
    if (has_terminal_branch and !containsToken(proc.body.text, "return")) return null;

    return .{ .event_decl = event_decl, .proc = proc };
}

/// Word-boundary token scan, quote- and comment-aware.
fn containsToken(body: []const u8, token: []const u8) bool {
    var i: usize = 0;
    var q: u8 = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (q != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == q) {
                q = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            q = c;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], token)) {
            const before_ok = i == 0 or !(std.ascii.isAlphanumeric(body[i - 1]) or body[i - 1] == '_' or body[i - 1] == '.');
            const after = i + token.len;
            const after_ok = after >= body.len or !(std.ascii.isAlphanumeric(body[after]) or body[after] == '_');
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

/// Rewrite a proc body for inline splicing: effect calls → splice markers
/// (or evaluate-and-discard for unhandled optional effects), depth-any
/// `return` → labeled break, `std.` → `@import("std").` (inlined bodies
/// lose their module scope). Quote- and comment-aware throughout.
const RewrittenProcBody = struct { text: []u8, has_break: bool };

fn rewriteEffectfulProcBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    event_decl: *const ast.EventDecl,
    conts: []const ast.Continuation,
    break_label: []const u8,
) !RewrittenProcBody {
    var out = try std.ArrayList(u8).initCapacity(allocator, body.len + 256);
    errdefer out.deinit(allocator);

    // Effect branch → handled continuation index (or null = unhandled optional).
    const EffectSite = struct { lowered: []const u8, cont_idx: ?usize };
    var sites_buf: [32]EffectSite = undefined;
    var name_bufs: [32][128]u8 = undefined;
    var n_sites: usize = 0;
    for (event_decl.branches) |*b| {
        if (b.kind != .effect) continue;
        const lowered = lowerIdent(&name_bufs[n_sites], b.name);
        var idx: ?usize = null;
        for (conts, 0..) |*c, ci| {
            if (c.kind == .effect and std.mem.eql(u8, c.branch, b.name)) {
                idx = ci;
                break;
            }
        }
        sites_buf[n_sites] = .{ .lowered = lowered, .cont_idx = idx };
        n_sites += 1;
    }
    const sites = sites_buf[0..n_sites];

    // Strip standalone param discards (`_ = p;` / `_ = &p;`, line-shaped):
    // they satisfied the legacy wrapper's unused-param rule; the inline
    // prologue already discards, and Zig rejects pointless re-discards.
    var stripped = try std.ArrayList(u8).initCapacity(allocator, body.len);
    defer stripped.deinit(allocator);
    {
        var lines = std.mem.splitScalar(u8, body, '\n');
        var first_line = true;
        while (lines.next()) |ln| {
            const t = std.mem.trim(u8, ln, " \t\r");
            var is_param_discard = false;
            if (std.mem.startsWith(u8, t, "_ = ")) {
                var rest = t["_ = ".len..];
                if (rest.len > 0 and rest[0] == '&') rest = rest[1..];
                for (event_decl.input.fields) |*f| {
                    var fb: [128]u8 = undefined;
                    const fname = lowerIdent(&fb, f.name);
                    if (rest.len == fname.len + 1 and std.mem.startsWith(u8, rest, fname) and rest[fname.len] == ';') {
                        is_param_discard = true;
                        break;
                    }
                }
            }
            if (is_param_discard) continue;
            if (!first_line) try stripped.append(allocator, '\n');
            try stripped.appendSlice(allocator, ln);
            first_line = false;
        }
    }
    const clean_body = stripped.items;

    var has_break = false;
    var i: usize = 0;
    var q: u8 = 0;
    while (i < clean_body.len) {
        const c = clean_body[i];
        if (q != 0) {
            try out.append(allocator, c);
            if (c == '\\') {
                if (i + 1 < clean_body.len) try out.append(allocator, clean_body[i + 1]);
                i += 2;
                continue;
            }
            if (c == q) q = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            q = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < clean_body.len and clean_body[i + 1] == '/') {
            while (i < clean_body.len and clean_body[i] != '\n') : (i += 1) try out.append(allocator, clean_body[i]);
            continue;
        }

        const boundary_before = i == 0 or !(std.ascii.isAlphanumeric(clean_body[i - 1]) or clean_body[i - 1] == '_' or clean_body[i - 1] == '.');
        if (boundary_before) {
            // `return` → labeled break (any depth: every return is a proc exit).
            if (std.mem.startsWith(u8, clean_body[i..], "return")) {
                const after = i + "return".len;
                if (after >= clean_body.len or !(std.ascii.isAlphanumeric(clean_body[after]) or clean_body[after] == '_')) {
                    try out.appendSlice(allocator, "break :");
                    try out.appendSlice(allocator, break_label);
                    has_break = true;
                    i = after;
                    continue;
                }
            }
            // `std.` → `@import("std").` (module scope does not travel).
            if (std.mem.startsWith(u8, clean_body[i..], "std.")) {
                try out.appendSlice(allocator, "@import(\"std\").");
                i += "std.".len;
                continue;
            }
            // Effect calls → splice markers / evaluate-and-discard.
            var matched = false;
            for (sites) |site| {
                if (!std.mem.startsWith(u8, clean_body[i..], site.lowered)) continue;
                var j = i + site.lowered.len;
                while (j < clean_body.len and (clean_body[j] == ' ' or clean_body[j] == '\t')) j += 1;
                if (j >= clean_body.len or clean_body[j] != '(') continue;
                if (site.cont_idx) |ci| {
                    try out.appendSlice(allocator, INLINE_SPLICE_PREFIX);
                    var nb: [16]u8 = undefined;
                    try out.appendSlice(allocator, std.fmt.bufPrint(&nb, "{d}", .{ci}) catch unreachable);
                } else {
                    // Unhandled optional effect: evaluate the payload, drop it.
                    try out.appendSlice(allocator, "_ = ");
                }
                i = j; // resume at '(' — the resolver (or Zig) reads the args
                matched = true;
                break;
            }
            if (matched) continue;
        }

        try out.append(allocator, c);
        i += 1;
    }

    return .{ .text = try out.toOwnedSlice(allocator), .has_break = has_break };
}

/// Emit the inline lowering at the invocation site. `result_name` is null
/// for the zero-terminal (statement) shape.
fn emitInlineEffectfulCall(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inv: *const ast.Invocation,
    conts: []const ast.Continuation,
    elig: InlineEligibility,
    result_name: ?[]const u8,
    uniq: usize,
) anyerror!void {
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "__koru_proc_{d}", .{uniq}) catch "__koru_proc";

    const rewritten = try rewriteEffectfulProcBody(ctx.allocator, elig.proc.body.text, elig.event_decl, conts, label);
    defer ctx.allocator.free(rewritten.text);

    // A label is only legal if something breaks to it; a statement block
    // takes no trailing semicolon. (The const form always has breaks —
    // eligibility requires a `return` when terminals exist.)
    const typed_discard = result_name == null and rewritten.has_break;
    var disc_buf: [64]u8 = undefined;
    const disc_name = std.fmt.bufPrint(&disc_buf, "__koru_eff_disc_{d}", .{uniq}) catch "__koru_eff_disc";
    const labeled = result_name != null or rewritten.has_break;
    try emitter.writeIndent();
    if (result_name) |rn| {
        try emitter.write("const ");
        try emitter.write(rn);
        try emitter.write(": ");
        try emitInvocationTarget(emitter, ctx, &inv.path);
        try emitter.write(".Output = ");
    } else if (typed_discard) {
        // A value-breaking block with no consumer still needs a typed const
        // so anonymous break literals have a result type; discard after.
        try emitter.write("const ");
        try emitter.write(disc_name);
        try emitter.write(": ");
        try emitInvocationTarget(emitter, ctx, &inv.path);
        try emitter.write(".Output = ");
    }
    if (labeled) {
        try emitter.write(label);
        try emitter.write(": {\n");
    } else {
        try emitter.write("{\n");
    }
    emitter.indent();

    // Bind event params from the invocation's argument expressions. A
    // punned arg (`read-lines(path)` where the value IS the param name)
    // already has the right name in scope — rebinding would self-shadow.
    for (inv.args) |arg| {
        var pun_buf: [128]u8 = undefined;
        const lowered_name = lowerIdent(&pun_buf, arg.name);
        if (std.mem.eql(u8, std.mem.trim(u8, arg.value, " \t"), lowered_name)) continue;
        try emitter.writeIndent();
        try emitter.write("const ");
        try writeBranchName(emitter, arg.name);
        try emitter.write(" = (");
        try emitter.write(arg.value);
        try emitter.write("); _ = &");
        try writeBranchName(emitter, arg.name);
        try emitter.write(";\n");
    }

    try emitter.writeIndent();
    try emitInlineCodeResolvingSplices(emitter, ctx, rewritten.text, conts);
    try emitter.write("\n");

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write(if (result_name != null or typed_discard) "};\n" else "}\n");
    if (typed_discard) {
        try emitter.writeIndent();
        try emitter.write("_ = ");
        try emitter.write(disc_name);
        try emitter.write(";\n");
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

    // Use the standalone function which handles module recursion
    return branchHasPayloadFieldsFromItems(items, event_name, branch_name, ctx.main_module_name);
}

/// Check if a branch has payload fields (standalone version for subflow emission)
/// This variant takes items directly instead of EmissionContext, for use in
/// emitSubflowContinuationsWithDepth which doesn't have a full context.
/// event_name is in canonical form "module:event.path" (e.g., "app.test_lib.ops:try_op")
fn branchHasPayloadFieldsFromItems(
    items: []const ast.Item,
    event_name: []const u8,
    branch_name: []const u8,
    main_module_name: ?[]const u8,
) bool {
    _ = main_module_name; // Not needed for path-based lookup

    // Parse the event name to extract event segments (part after colon)
    // Format: "module.path:event.name" or just "event.name"
    var event_segments_str: []const u8 = event_name;

    if (std.mem.indexOf(u8, event_name, ":")) |colon_pos| {
        event_segments_str = event_name[colon_pos + 1 ..];
    }

    // Split event segments by dots
    var segments_buf: [16][]const u8 = undefined;
    var segment_count: usize = 0;
    var iter = std.mem.splitScalar(u8, event_segments_str, '.');
    while (iter.next()) |seg| {
        if (segment_count < segments_buf.len) {
            segments_buf[segment_count] = seg;
            segment_count += 1;
        }
    }
    const event_segments = segments_buf[0..segment_count];

    // Search all items recursively for an event with matching segments
    // This is a conservative search that finds the event regardless of module nesting
    return branchHasPayloadFieldsSearchAll(items, event_segments, branch_name);
}

/// Search all items (and nested modules) for an event by segments
fn branchHasPayloadFieldsSearchAll(
    items: []const ast.Item,
    event_segments: []const []const u8,
    branch_name: []const u8,
) bool {
    for (items) |item| {
        if (item == .event_decl) {
            const event = item.event_decl;
            // Check if segments match
            if (event.path.segments.len == event_segments.len) {
                var matches = true;
                for (event.path.segments, 0..) |seg, i| {
                    if (!std.mem.eql(u8, seg, event_segments[i])) {
                        matches = false;
                        break;
                    }
                }
                if (matches) {
                    // Found the event - check if branch has payload
                    for (event.branches) |branch| {
                        if (std.mem.eql(u8, branch.name, branch_name)) {
                            return branch.payload.fields.len > 0;
                        }
                    }
                }
            }
        } else if (item == .module_decl) {
            // Recurse into modules
            const result = branchHasPayloadFieldsSearchAll(item.module_decl.items, event_segments, branch_name);
            if (!result) return false; // Found with empty payload
        }
    }
    return true; // Conservative: assume has fields if not found
}

/// Effect-branches phase 3b: synthesize the local Handlers struct that carries
/// the consumer's `!` branch bodies as static fns. See docs/EFFECT_BRANCHES.md.
///
/// Emits:
///   const HANDLERS = struct {
///       fn BRANCH(BINDING: PAYLOAD) RESUME { <cont body> }
///       ...
///   };
fn emitHandlersStruct(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    handlers_name: []const u8,
    effect_conts: []const ast.Continuation,
    event_decl: *const ast.EventDecl,
) anyerror!void {
    try emitter.writeIndent();
    try emitter.write("const ");
    try emitter.write(handlers_name);
    try emitter.write(" = struct {\n");
    emitter.indent();

    // Track which effect branches the consumer explicitly handled (by name)
    // so we can synthesize no-op fns for unhandled OPTIONAL effect branches.
    // The proc body references `__H.NAME` for every declared effect branch;
    // without a no-op fallback for unhandled optionals, Zig errors at compile.
    var handled = std.StringHashMap(void).init(ctx.allocator);
    defer handled.deinit();

    // Group continuations by branch name. Two sibling handlers for the same
    // `!` branch name (e.g., `! tick i when i > 0 |> a` + `! tick _ |> b`)
    // must collapse into ONE synthesized fn whose body chains the guards:
    // `if (g1) { body1; return; } if (g2) { body2; return; } unguarded_body`.
    // Without this, the struct would have two `fn tick` declarations and Zig
    // rejects with "duplicate struct member name".
    //
    // Source order is preserved within each group — first matching guard
    // wins, and an unguarded handler (if present) is the fallback after
    // all guards.
    var group_order: std.ArrayList([]const u8) = .empty;
    defer group_order.deinit(ctx.allocator);

    var groups: std.StringArrayHashMap(std.ArrayList(*const ast.Continuation)) =
        std.StringArrayHashMap(std.ArrayList(*const ast.Continuation)).init(ctx.allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(ctx.allocator);
        }
        groups.deinit();
    }

    for (effect_conts) |*cont| {
        // Skip catch-all `!?` conts — they don't match any specific decl branch.
        // (The catch-all body is currently not woven into per-branch dispatch;
        // pay-for-nothing rejection in the parser will eliminate the bare-discard
        // shape entirely, and metatype-bound forms are a separate work item.)
        if (cont.is_catchall) continue;

        // Validate the branch exists in the event decl; defensively skip
        // unknowns (shape_checker is responsible for surfacing those).
        const exists = for (event_decl.branches) |*b| {
            if (std.mem.eql(u8, b.name, cont.branch)) break true;
        } else false;
        if (!exists) continue;

        const gop = try groups.getOrPut(cont.branch);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
            try group_order.append(ctx.allocator, cont.branch);
        }
        try gop.value_ptr.append(ctx.allocator, cont);
    }

    // Emit one fn per branch-name group.
    for (group_order.items) |branch_name| {
        const group = groups.get(branch_name).?;
        if (group.items.len == 0) continue;

        // Find the branch decl (we already validated existence above).
        const branch: *const ast.Branch = blk: {
            for (event_decl.branches) |*b| {
                if (std.mem.eql(u8, b.name, branch_name)) break :blk b;
            }
            unreachable;
        };

        try handled.put(branch.name, {});

        // Pick a parameter name. If all conts in the group share a binding
        // (common case) and that binding isn't `_`, use it directly so the
        // body code can reference it unchanged. Otherwise fall back to the
        // branch name as a stable shared parameter, and conts whose binding
        // differs will alias it.
        const shared_param_name: []const u8 = blk: {
            const first = group.items[0];
            const first_binding = if (first.binding) |b| b else branch.name;

            // Check if all conts share the same binding (and it's not `_`).
            var all_same = !std.mem.eql(u8, first_binding, "_");
            if (all_same) {
                for (group.items[1..]) |cont| {
                    const b = if (cont.binding) |bb| bb else branch.name;
                    if (!std.mem.eql(u8, b, first_binding)) {
                        all_same = false;
                        break;
                    }
                }
            }

            // When bindings differ (or any cont uses `_`), or when the
            // shared binding equals the branch name (which would shadow the
            // synthesized `fn <branch_name>` declaration in Zig), fall back
            // to a stable internal name. Conts whose binding differs from
            // this will alias it inside the body.
            const candidate = if (all_same) first_binding else "__koru_h_arg";
            break :blk if (std.mem.eql(u8, candidate, branch.name))
                "__koru_h_arg"
            else
                candidate;
        };

        // Void-payload effects (zero-field branch) emit a no-arg handler so the
        // producer-side `name()` call matches. A `void` param would require the
        // call site to pass `{}` and bloats the signature for no information.
        // A wildcard payload (`! each *`) has zero fields but IS bindable — it
        // takes an `anytype` param so Zig infers the element type at the call.
        const is_void_payload = branch.payload.fields.len == 0 and !branch.payload.is_wildcard;

        try emitter.writeIndent();
        try emitter.write("fn ");
        try writeBranchName(emitter, branch.name);
        try emitter.write("(");

        if (!is_void_payload) {
            try writeBranchName(emitter, shared_param_name);
            try emitter.write(": ");

            // Wildcard payload `! each *` — defer the element type to Zig's
            // type inference: emit `anytype` (valid in parameter position).
            if (branch.payload.is_wildcard) {
                try emitter.write("anytype");
            }
            // Identity payload (single field named "__type_ref") — emit type directly.
            // Multi-field struct payload — emit anon struct literal type.
            else if (branch.payload.fields.len == 1 and std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref")) {
                try writeFieldType(emitter, branch.payload.fields[0], ctx.main_module_name);
            } else {
                try emitter.write("struct { ");
                for (branch.payload.fields, 0..) |field, fi| {
                    if (fi > 0) try emitter.write(", ");
                    try writeBranchName(emitter, field.name);
                    try emitter.write(": ");
                    try writeFieldType(emitter, field, ctx.main_module_name);
                }
                try emitter.write(" }");
            }
        }

        try emitter.write(") ");
        if (branch.resume_type) |rt| {
            try emitter.write(rt);
        } else {
            try emitter.write("void");
        }
        try emitter.write(" {\n");
        emitter.indent();

        // Suppress unused-param warning unconditionally on the shared param.
        if (!is_void_payload) {
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try writeBranchName(emitter, shared_param_name);
            try emitter.write(";\n");
        }

        // Emit each cont in source order. Each cont gets its own block scope
        // so binding aliases (e.g., `const i = __koru_h_arg`) are visible to
        // the guard expression. Guarded conts wrap their body in
        // `if (cond) { ... return; }`. The first unguarded cont is the
        // fallback — its body runs unconditionally, and subsequent conts are
        // unreachable and skipped.
        for (group.items) |cont| {
            const guarded = cont.condition != null;

            try emitter.writeIndent();
            try emitter.write("{\n");
            emitter.indent();

            // Alias the cont's binding to the shared param ONLY when the
            // user wrote an actual binding name (not `_`, not omitted).
            // Omitting the binding means "no name to reference"; aliasing
            // to `branch.name` would shadow the synthesized fn declaration.
            const has_named_binding = if (cont.binding) |b|
                !std.mem.eql(u8, b, "_") and !std.mem.eql(u8, b, shared_param_name)
            else
                false;
            const cont_binding: []const u8 = if (cont.binding) |b| b else branch.name;
            if (cont.destructure.len > 0) {
                // Shape-destructure: per-field consts off the shared param.
                try emitter.writeIndent();
                try emitDestructureConsts(emitter, cont.destructure, shared_param_name);
                try emitter.write("\n");
            } else if (has_named_binding) {
                try emitter.writeIndent();
                try emitter.write("const ");
                try writeBranchName(emitter, cont_binding);
                try emitter.write(" = ");
                try writeBranchName(emitter, shared_param_name);
                try emitter.write(";\n");
                try emitter.writeIndent();
                try emitter.write("_ = &");
                try writeBranchName(emitter, cont_binding);
                try emitter.write(";\n");
            }

            if (guarded) {
                try emitter.writeIndent();
                try emitter.write("if (");
                try emitter.write(cont.condition.?);
                try emitter.write(") {\n");
                emitter.indent();
            }

            // Body emission: prefer the bare-expression resume-value form
            // when the branch declares a resume type and the body is a
            // single expression (see `project_effect_resume_value_syntax`).
            var resume_expr_owned: ?[]const u8 = null;
            defer if (resume_expr_owned) |s| ctx.allocator.free(s);

            const resume_expr: ?[]const u8 = blk: {
                if (branch.resume_type == null) break :blk null;
                if (cont.continuations.len != 0) break :blk null;
                const node = cont.node orelse break :blk null;
                switch (node) {
                    .expression => |code| break :blk code,
                    .branch_constructor => |bc| {
                        if (bc.fields.len != 0) break :blk null;
                        if (bc.plain_value) |pv| {
                            resume_expr_owned = try std.fmt.allocPrint(
                                ctx.allocator,
                                "{s} {s}",
                                .{ bc.branch_name, pv },
                            );
                            break :blk resume_expr_owned.?;
                        }
                        break :blk bc.branch_name;
                    },
                    else => break :blk null,
                }
            };

            // `->` produce-is-the-call sugar: the resume value is an event
            // call (`! step p -> mix(x: p)`). Emit the invocation bound to a
            // temp, then return it as the resume value.
            const resume_inv: ?*const ast.Invocation = blk: {
                if (branch.resume_type == null) break :blk null;
                if (cont.continuations.len != 0) break :blk null;
                if (cont.node == null) break :blk null;
                if (cont.node.? != .invocation) break :blk null;
                break :blk &cont.node.?.invocation;
            };

            if (resume_inv) |inv| {
                try emitInvocation(emitter, ctx, inv, "__koru_resume");
                try emitter.writeIndent();
                try emitter.write("return __koru_resume;\n");
            } else if (resume_expr) |expr| {
                try emitter.writeIndent();
                try emitter.write("return ");
                try emitter.write(expr);
                try emitter.write(";\n");
            } else {
                var result_counter: usize = 0;
                try emitContinuationBody(emitter, ctx, cont, &result_counter);

                // For guarded void-return conts, emit an explicit `return;`
                // so subsequent guards in the chain don't fire after a match.
                // (Resume-typed conts already returned via the `return EXPR`
                // path above.)
                if (guarded and branch.resume_type == null) {
                    try emitter.writeIndent();
                    try emitter.write("return;\n");
                }
            }

            if (guarded) {
                // Close the `if (cond) {` block.
                emitter.dedent();
                try emitter.writeIndent();
                try emitter.write("}\n");
            }

            // Close the per-cont scope block.
            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");

            // Unguarded cont = fallback. Anything after it is unreachable;
            // stop emitting siblings for this branch.
            if (!guarded) break;
        }

        emitter.dedent();
        try emitter.writeIndent();
        try emitter.write("}\n");
    }

    // Synthesize no-op fns for unhandled OPTIONAL effect branches. The proc
    // body references `__H.NAME` unconditionally for every declared effect
    // branch; optional ones the consumer omits lower to no-op calls per the
    // doc spec ("handler simply isn't installed in the comptime struct, call
    // lowers to nothing" — we install a no-op so the comptime alias resolves).
    for (event_decl.branches) |branch| {
        if (branch.kind != .effect) continue;
        if (!branch.is_optional) continue;
        if (handled.contains(branch.name)) continue;

        // Void-payload effects emit a no-arg no-op so the producer's `name()`
        // call resolves; a `void` param would require `name({})` at the producer.
        const is_void_payload = branch.payload.fields.len == 0;

        try emitter.writeIndent();
        try emitter.write("fn ");
        try writeBranchName(emitter, branch.name);
        try emitter.write("(");
        if (!is_void_payload) {
            try emitter.write("_: ");
            if (branch.payload.fields.len == 1 and std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref")) {
                try writeFieldType(emitter, branch.payload.fields[0], ctx.main_module_name);
            } else {
                try emitter.write("struct { ");
                for (branch.payload.fields, 0..) |field, fi| {
                    if (fi > 0) try emitter.write(", ");
                    try writeBranchName(emitter, field.name);
                    try emitter.write(": ");
                    try writeFieldType(emitter, field, ctx.main_module_name);
                }
                try emitter.write(" }");
            }
        }
        try emitter.write(") ");
        if (branch.resume_type) |rt| {
            try emitter.write(rt);
        } else {
            try emitter.write("void");
        }
        try emitter.write(" {}\n");
    }

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write("};\n");
}

/// Emit an invocation (const result = event.handler(...))
/// If an ImmediateImpl exists for this path, inline the value instead
fn emitInvocation(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    invocation: *const ast.Invocation,
    result_var: []const u8,
) !void {
    // Handle special test assertions that should be inlined
    if (invocation.path.segments.len == 2) {
        const first = invocation.path.segments[0];
        const second = invocation.path.segments[1];
        if (std.mem.eql(u8, first, "assert")) {
            if (std.mem.eql(u8, second, "ok")) {
                // assert.ok() - pass-through checkpoint, emit nothing
                // Assign void to suppress unused variable warning if needed
                if (!std.mem.eql(u8, result_var, "_")) {
                    try emitter.writeIndent();
                    try emitter.write("_ = ");
                    try emitter.write(result_var);
                    try emitter.write(";\n");
                }
                return;
            }
            if (std.mem.eql(u8, second, "fail")) {
                // assert.fail() - unconditional failure
                try emitter.writeIndent();
                try emitter.write("return error.TestUnexpectedResult;\n");
                return;
            }
        }
    }

    // Check for ImmediateImpl (mock/constant value)
    // If found, inline the value instead of calling the handler
    if (ctx.ast_items) |items| {
        const found_immediate: ?*const ast.ImmediateImpl = blk: {
            if (findImplByPath(items, &invocation.path)) |found| {
                switch (found) {
                    .immediate_impl => |ii| break :blk ii,
                    .flow => break :blk null,
                }
            }
            break :blk null;
        };
        if (found_immediate) |immediate_impl| {
            const event_decl = findEventDeclByPath(items, &invocation.path);
            const immediate_bc = &immediate_impl.value;
            // Emit: const result: EventType.Output = blk: {
            //     const n = 5;  // bind input args
            //     break :blk .{ .branch = value };
            // };
            // Use a labeled block to scope the input bindings and avoid redeclaration.
            // `-> T` bare return: bind to the call-site `-> name` (return_binding),
            // type is the bare return_type (not `.Output`), and the block yields the
            // value directly (no tagged union) — see the `break :blk` below.
            const bare_return = immediate_bc.is_bare_return;
            const bind_name = if (bare_return)
                (invocation.return_binding orelse result_var)
            else
                result_var;
            try emitter.writeIndent();
            if (!std.mem.eql(u8, bind_name, "_")) {
                try emitter.write("const ");
            }
            try emitter.write(bind_name);
            try emitter.write(": ");
            if (bare_return and event_decl != null and event_decl.?.return_type != null) {
                try emitter.write(event_decl.?.return_type.?);
            } else {
                try emitInvocationTarget(emitter, ctx, &invocation.path);
                try emitter.write(".Output");
            }
            try emitter.write(" = blk: {\n");

            emitter.indent_level += 1;

            // Bind input arguments so they're available in the expression
            // e.g., for ~double(n: 5) with ~double = result { n * 2 }
            // we need: const n = 5;
            // Skip if:
            //   - pass-through: param name equals a simple identifier value already in scope
            //     (echo(v: v), echo(v)) — rebinding inside the blk shadows continuation bindings
            //   - arg.name is not referenced in the immediate expression (avoid shadowing outer scope)
            for (invocation.args, 0..) |arg, arg_idx| {
                // Resolve actual parameter name for positional args
                // e.g., ~greet("World") where arg.name == arg.value == "\"World\""
                // but event signature has { name: []const u8 } -> use "name"
                const param_name = if (std.mem.eql(u8, arg.name, arg.value)) blk_name: {
                    // Positional arg - look up name from event signature
                    if (event_decl) |ev| {
                        if (arg_idx < ev.input.fields.len) {
                            break :blk_name ev.input.fields[arg_idx].name;
                        }
                    }
                    // No event decl or out of bounds - skip this arg (can't resolve)
                    continue;
                } else arg.name;

                // Pass-through from an outer binding — use the in-scope name directly.
                const trimmed_value = std.mem.trim(u8, arg.value, " \t");
                if (isSimpleIdentifier(trimmed_value) and std.mem.eql(u8, param_name, trimmed_value)) {
                    continue;
                }

                // Check if this parameter is actually used in the immediate expression
                // If not, skip it to avoid shadowing outer scope variables
                const expr_to_check = if (immediate_bc.plain_value) |pv| pv else blk2: {
                    // Check all field expressions
                    var is_used = false;
                    for (immediate_bc.fields) |field| {
                        const field_val = if (field.expression_str) |e| e else field.type;
                        if (containsIdentifier(field_val, param_name)) {
                            is_used = true;
                            break;
                        }
                    }
                    if (!is_used) continue;
                    break :blk2 "";
                };
                if (expr_to_check.len > 0 and !containsIdentifier(expr_to_check, param_name)) {
                    continue;
                }
                try emitter.writeIndent();
                try emitter.write("const ");
                try writeBranchName(emitter, param_name);
                try emitter.write(" = ");
                try emitValue(emitter, ctx, arg.value);
                try emitter.write(";\n");
                // Suppress unused variable warning (for mocks that return constants)
                try emitter.writeIndent();
                try emitter.write("_ = &");
                try writeBranchName(emitter, param_name);
                try emitter.write(";\n");
            }

            // Emit the break with the branch constructor (or the bare value).
            try emitter.writeIndent();
            try emitter.write("break :blk ");
            if (bare_return) {
                // `-> T`: yield the expression directly, no `.{ .name = ... }` wrap.
                if (immediate_bc.plain_value) |pv| {
                    try emitValue(emitter, ctx, pv);
                } else {
                    try emitter.write("undefined");
                }
            } else if (event_decl) |event| {
                try emitBranchConstructorWithEvent(emitter, ctx, &immediate_impl.value, event);
            } else if (ctx.type_registry) |type_registry| {
                var resolved_event_type: ?type_registry_module.EventType = null;

                const canonical = try buildCanonicalEventName(&immediate_impl.event_path, ctx.allocator, ctx.main_module_name);
                defer ctx.allocator.free(canonical);
                if (type_registry.getEventType(canonical)) |event_type| {
                    resolved_event_type = event_type;
                }

                if (resolved_event_type == null) {
                    const fallback_canonical = try buildCanonicalEventName(&invocation.path, ctx.allocator, ctx.main_module_name);
                    defer ctx.allocator.free(fallback_canonical);
                    if (type_registry.getEventType(fallback_canonical)) |event_type| {
                        resolved_event_type = event_type;
                    }
                }

                if (resolved_event_type == null) {
                    if (invocation.path.module_qualifier) |mq| {
                        if (resolveModuleAlias(mq, items)) |resolved| {
                            var temp_path = ast.DottedPath{
                                .module_qualifier = resolved,
                                .segments = invocation.path.segments,
                            };
                            const alt_canonical = try buildCanonicalEventName(&temp_path, ctx.allocator, ctx.main_module_name);
                            defer ctx.allocator.free(alt_canonical);
                            if (type_registry.getEventType(alt_canonical)) |event_type| {
                                resolved_event_type = event_type;
                            }
                        }
                    }
                }

                if (resolved_event_type == null) {
                    var match_count: usize = 0;
                    var import_iter = type_registry.imports.iterator();
                    while (import_iter.next()) |entry| {
                        const module_path = entry.value_ptr.*;
                        var temp_path = ast.DottedPath{
                            .module_qualifier = module_path,
                            .segments = invocation.path.segments,
                        };
                        const import_canonical = try buildCanonicalEventName(&temp_path, ctx.allocator, ctx.main_module_name);
                        defer ctx.allocator.free(import_canonical);
                        if (type_registry.getEventType(import_canonical)) |event_type| {
                            match_count += 1;
                            resolved_event_type = event_type;
                            if (match_count > 1) {
                                resolved_event_type = null;
                                break;
                            }
                        }
                    }
                }

                if (resolved_event_type == null) {
                    var match_count: usize = 0;
                    var event_iter = type_registry.events.iterator();
                    while (event_iter.next()) |entry| {
                        const event_name = entry.key_ptr.*;
                        const colon_idx = std.mem.indexOfScalar(u8, event_name, ':') orelse continue;
                        const path_part = event_name[colon_idx + 1 ..];

                        var seg_iter = std.mem.splitScalar(u8, path_part, '.');
                        var seg_index: usize = 0;
                        var matches = true;
                        while (seg_iter.next()) |seg| {
                            if (seg_index >= invocation.path.segments.len or !std.mem.eql(u8, seg, invocation.path.segments[seg_index])) {
                                matches = false;
                                break;
                            }
                            seg_index += 1;
                        }
                        if (!matches or seg_index != invocation.path.segments.len) continue;

                        match_count += 1;
                        resolved_event_type = entry.value_ptr.*;
                        if (match_count > 1) {
                            resolved_event_type = null;
                            break;
                        }
                    }
                }

                if (resolved_event_type) |event_type| {
                    try emitBranchConstructorWithEventType(emitter, ctx, &immediate_impl.value, event_type);
                } else {
                    try emitBranchConstructor(emitter, ctx, &immediate_impl.value, true);
                }
            } else {
                try emitBranchConstructor(emitter, ctx, &immediate_impl.value, true);
            }
            try emitter.write(";\n");

            emitter.indent_level -= 1;
            try emitter.writeIndent();
            try emitter.write("};\n");
            return;
        }
    }

    try emitter.writeIndent();
    // Don't use 'const' if result_var is "_" (discard)
    // Note: Labeled invocations (which need 'var') don't use this function - they emit manually
    // A `-> T` bare-return call binds its result to the call-site `: name`
    // (return_binding), so the following pipeline can reference it.
    const bound_var = invocation.return_binding orelse result_var;
    const bound_mutable = blk: {
        for (invocation.return_binding_annotations) |ann| {
            if (std.mem.eql(u8, ann, "mutable")) break :blk true;
        }
        break :blk false;
    };
    if (!std.mem.eql(u8, bound_var, "_")) {
        try emitter.write(if (bound_mutable) "var " else "const ");
    }
    try emitter.write(bound_var);
    try emitter.write(" = ");
    // Only emit 'try' for async calls (is_sync = false means async)
    if (!ctx.is_sync) {
        try emitter.write("try ");
    }
    try emitInvocationTarget(emitter, ctx, &invocation.path);
    try emitter.write(".");

    // Determine which variant to use:
    // 1. If explicit variant on invocation, use that
    // 2. Else check the variant registry for a default
    // 3. Else use the default handler
    var effective_variant: ?[]const u8 = invocation.variant;

    if (effective_variant == null) {
        // Build canonical name from path: "module:event.path"
        // e.g., "std.io:print.ln" or "input:compute"
        var canonical_buf: [256]u8 = undefined;
        var canonical_len: usize = 0;

        if (invocation.path.module_qualifier) |mq| {
            @memcpy(canonical_buf[canonical_len .. canonical_len + mq.len], mq);
            canonical_len += mq.len;
            canonical_buf[canonical_len] = ':';
            canonical_len += 1;
        }

        for (invocation.path.segments, 0..) |segment, i| {
            if (i > 0) {
                canonical_buf[canonical_len] = '.';
                canonical_len += 1;
            }
            @memcpy(canonical_buf[canonical_len .. canonical_len + segment.len], segment);
            canonical_len += segment.len;
        }

        // Check variant registry (populated by build:variants at comptime)
        effective_variant = getVariant(canonical_buf[0..canonical_len]);
    }

    try writeHandlerName(emitter, ctx.allocator, effective_variant);
    try emitter.write("(.{ ");
    try emitArgs(emitter, ctx, invocation.args, &invocation.path);
    try emitter.write(" }");
    // Effect-branches phase 3b: pass the synthesized Handlers struct as 2nd arg
    // ONLY when the target event actually declares effect (`!`) branches. A plain
    // event's handler is `handler(input)` (1 arg); without this guard a plain event
    // called from within a handler-bearing flow (e.g. `| done r |> report(...)`, or
    // the vaxis `! key _ |> quit()` shape) gets a spurious 2nd arg and the Zig
    // backend rejects it: "expected 1 argument(s), found 2". See test 400_109.
    if (ctx.pending_handlers_name) |hname| {
        const target_has_effect = blk: {
            const items = ctx.ast_items orelse break :blk false;
            const ed = findEventDeclByPath(items, &invocation.path) orelse break :blk false;
            for (ed.branches) |b| {
                if (b.kind == .effect) break :blk true;
            }
            break :blk false;
        };
        if (target_has_effect) {
            try emitter.write(", ");
            try emitter.write(hname);
        }
    }
    try emitter.write(");");
    try writeVariantComment(emitter, effective_variant);
    try emitter.write("\n");
}

/// Emit the target of an invocation (e.g., "koru_std.io.print_event" or "main_module.hello_event")
fn emitInvocationTarget(emitter: *CodeEmitter, ctx: *EmissionContext, path: *const ast.DottedPath) !void {
    // CRITICAL: Check if we're at module level (not in a handler)
    // This happens when emitting meta-event taps from main()
    const at_module_level = !ctx.in_handler and ctx.input_var == null;

    // Use explicit module_qualifier if present
    if (path.module_qualifier) |mq| {
        // CRITICAL: If module_qualifier equals the main module name, treat as local
        // This ensures test modules reference their own versions of events
        if (ctx.main_module_name) |mmn| {
            if (std.mem.eql(u8, mq, mmn)) {
                // This is a local event from the main module - use module_prefix
                try emitter.write(ctx.module_prefix);
                try emitter.write(".");
            } else {
                // Try to resolve the alias to the actual module path
                const resolved_path = if (ctx.ast_items) |items|
                    resolveModuleAlias(mq, items) orelse mq
                else
                    mq;
                try writeModulePath(emitter, resolved_path, ctx.main_module_name);
                try emitter.write(".");
            }
        } else {
            // No main_module_name set - use the original path
            const resolved_path = if (ctx.ast_items) |items|
                resolveModuleAlias(mq, items) orelse mq
            else
                mq;
            try writeModulePath(emitter, resolved_path, ctx.main_module_name);
            try emitter.write(".");
        }
    } else if (ctx.ast_items) |items| {
        // CRITICAL: Check LOCAL events FIRST before checking imported modules
        // This ensures unqualified names resolve to local events when they exist
        const is_local = findLocalEvent(path.segments, items);

        if (is_local) {
            // Event exists locally - use module prefix (main_module or test_N_module)
            try emitter.write(ctx.module_prefix);
            try emitter.write(".");
        } else if (findEventModule(path.segments, items)) |module_name| {
            // Not found locally, check imported modules
            try writeModulePath(emitter, module_name, ctx.main_module_name);
            try emitter.write(".");
        } else if (at_module_level) {
            // At module level (main()) and not found anywhere
            // Assume module prefix (unless it's a compiler event)
            const is_compiler_event = path.segments.len > 0 and std.mem.eql(u8, path.segments[0], "compiler");
            if (!is_compiler_event) {
                try emitter.write(ctx.module_prefix);
                try emitter.write(".");
            }
        }
    } else if (at_module_level) {
        // At module level but no ast_items to search
        // Assume module prefix (unless compiler event)
        const is_compiler_event = path.segments.len > 0 and std.mem.eql(u8, path.segments[0], "compiler");
        if (!is_compiler_event) {
            try emitter.write(ctx.module_prefix);
            try emitter.write(".");
        }
    }

    if (path.segments.len == 0) return;

    // Join all segments with underscores
    for (path.segments, 0..) |segment, idx| {
        if (idx > 0) {
            try emitter.write("_");
        }
        try writeMangledSeg(emitter, segment);
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

        // Check if this is a positional arg (name == value indicates synthesized name)
        // If so, use the parameter name from the event signature
        const param_name = if (std.mem.eql(u8, arg.name, arg.value)) blk: {
            // Positional arg - get name from event signature
            if (event_decl) |event| {
                if (idx < event.input.fields.len) {
                    break :blk event.input.fields[idx].name;
                }
            }
            // Fallback: use arg.name (might produce invalid Zig)
            break :blk arg.name;
        } else arg.name;

        try writeBranchName(emitter, param_name);
        try emitter.write(" = ");

        // Check if this argument should be emitted as a source, expression, or invocation_meta
        var is_source_arg = false;
        var is_expression_arg = false;
        var is_invocation_meta_arg = false;
        if (event_decl) |event| {
            for (event.input.fields) |field| {
                if (std.mem.eql(u8, field.name, param_name)) {
                    if (field.is_source) {
                        is_source_arg = true;
                        break;
                    }
                    if (field.is_expression) {
                        is_expression_arg = true;
                        break;
                    }
                    if (field.is_invocation_meta) {
                        is_invocation_meta_arg = true;
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
                    @memcpy(event_name_buf[event_name_len .. event_name_len + mq.len], mq);
                    event_name_len += mq.len;
                    event_name_buf[event_name_len] = ':';
                    event_name_len += 1;
                }

                for (invocation_path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        event_name_buf[event_name_len] = '.';
                        event_name_len += 1;
                    }
                    @memcpy(event_name_buf[event_name_len .. event_name_len + seg.len], seg);
                    event_name_len += seg.len;
                }

                const event_name = event_name_buf[0..event_name_len];

                log.debug("\n", .{});
                log.debug("ERROR: Comptime event '{s}' with Expression parameter reached runtime emission\n", .{event_name});
                log.debug("Expression parameter: {s}\n", .{arg.name});
                log.debug("\n", .{});

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
                    @memcpy(event_name_buf[event_name_len .. event_name_len + mq.len], mq);
                    event_name_len += mq.len;
                    event_name_buf[event_name_len] = ':';
                    event_name_len += 1;
                }

                for (invocation_path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        event_name_buf[event_name_len] = '.';
                        event_name_len += 1;
                    }
                    @memcpy(event_name_buf[event_name_len .. event_name_len + seg.len], seg);
                    event_name_len += seg.len;
                }

                const event_name = event_name_buf[0..event_name_len];

                // Print helpful error message to stderr
                log.debug("\n", .{});
                log.debug("ERROR: Comptime event '{s}' with Source parameter reached runtime emission\n", .{event_name});
                log.debug("\n", .{});
                log.debug("This means the comptime handler didn't transform this invocation into runtime code.\n", .{});
                log.debug("\n", .{});
                log.debug("Check your ~proc {s} implementation:\n", .{event_name});
                log.debug("  - It should execute during the evaluate_comptime pass\n", .{});
                log.debug("  - It should generate runtime code to replace this invocation\n", .{});
                log.debug("  - The generated code should NOT contain Source parameters\n", .{});
                log.debug("\n", .{});
                log.debug("Source parameter: {s}\n", .{arg.name});
                log.debug("\n", .{});

                return error.ComptimeEventNotTransformed;
            }

            // In comptime_only mode: emit the Source value
            // The AST already has the properly serialized Source in arg.source_value
            // We emit a reference to it (the AST is available as PROGRAM_AST)
            // For now, construct inline - the text is in arg.value
            try emitter.write("__koru_ast.Source{ .text = \n");
            emitter.indent();
            try emitter.writeIndent();
            // Use Zig multiline string syntax - split on newlines manually
            var line_start: usize = 0;
            for (arg.value, 0..) |c, i| {
                if (c == '\n') {
                    try emitter.write("\\\\");
                    try emitter.write(arg.value[line_start..i]);
                    try emitter.write("\n");
                    try emitter.writeIndent();
                    line_start = i + 1;
                }
            }
            // Handle last line (no trailing newline)
            if (line_start < arg.value.len) {
                try emitter.write("\\\\");
                try emitter.write(arg.value[line_start..]);
                try emitter.write("\n");
                try emitter.writeIndent();
            }
            emitter.dedent();
            try emitter.write(", .scope = .{ .bindings = &.{} }, .phantom_type = null }");
        } else if (is_invocation_meta_arg) {
            // InvocationMeta: synthesize from context (NOT from arg.value)
            // This provides call site metadata for comptime introspection
            const is_comptime_emission = if (ctx.emit_mode) |mode| mode == .comptime_only else false;

            if (!is_comptime_emission) {
                // InvocationMeta is comptime-only
                return error.ComptimeEventNotTransformed;
            }

            // Build the full path string
            try emitter.write("__koru_ast.InvocationMeta{\n");
            emitter.indent();

            // .path - full path like "std.build:variants"
            try emitter.writeIndent();
            try emitter.write(".path = \"");
            if (invocation_path.module_qualifier) |mq| {
                try emitter.write(mq);
                try emitter.write(":");
            }
            for (invocation_path.segments, 0..) |seg, i| {
                if (i > 0) try emitter.write(".");
                try writeMangledSeg(emitter, seg);
            }
            try emitter.write("\",\n");

            // .module - module qualifier or null
            try emitter.writeIndent();
            try emitter.write(".module = ");
            if (invocation_path.module_qualifier) |mq| {
                try emitter.write("\"");
                try emitter.write(mq);
                try emitter.write("\"");
            } else {
                try emitter.write("null");
            }
            try emitter.write(",\n");

            // .event_name - just the event name (last segment)
            try emitter.writeIndent();
            try emitter.write(".event_name = \"");
            if (invocation_path.segments.len > 0) {
                try emitter.write(invocation_path.segments[invocation_path.segments.len - 1]);
            }
            try emitter.write("\",\n");

            // .annotations - from the flow
            try emitter.writeIndent();
            try emitter.write(".annotations = ");
            if (ctx.current_flow_annotations) |anns| {
                try emitter.write("&[_][]const u8{");
                for (anns, 0..) |ann, i| {
                    if (i > 0) try emitter.write(", ");
                    try emitter.writeZigStringLiteral(ann);
                }
                try emitter.write("}");
            } else {
                try emitter.write("&[_][]const u8{}");
            }
            try emitter.write(",\n");

            // .location - from the flow
            try emitter.writeIndent();
            try emitter.write(".location = ");
            if (ctx.current_flow_location) |loc| {
                try emitter.write(".{ .file = \"");
                try emitter.write(loc.file);
                try emitter.write("\", .line = ");
                var line_buf: [16]u8 = undefined;
                const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{loc.line}) catch "0";
                try emitter.write(line_str);
                try emitter.write(", .column = ");
                var col_buf: [16]u8 = undefined;
                const col_str = std.fmt.bufPrint(&col_buf, "{d}", .{loc.column}) catch "0";
                try emitter.write(col_str);
                try emitter.write(" }");
            } else {
                try emitter.write(".{ .file = \"unknown\", .line = 0, .column = 0 }");
            }
            try emitter.write(",\n");

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}");
        } else {
            // Check for Koru array literal syntax: [a, b, c]
            if (arg.value.len >= 2 and arg.value[0] == '[' and arg.value[arg.value.len - 1] == ']') {
                const field = blk: {
                    if (event_decl) |event| {
                        for (event.input.fields) |*field| {
                            if (std.mem.eql(u8, field.name, param_name)) {
                                break :blk field;
                            }
                        }
                    }
                    break :blk null;
                };
                if (field) |field_info| {
                    try emitArrayLiteralForField(emitter, ctx, field_info, arg.value);
                } else {
                    return error.ArrayLiteralMissingType;
                }
            } else if (isKoruStructLiteral(arg.value)) {
                // Koru struct literal: { field: value, field2: value }
                // Transform to Zig: .{ .field = value, .field2 = value }
                try emitStructLiteral(emitter, ctx, arg.value);
            } else {
                try emitValue(emitter, ctx, arg.value);
            }
        }
    }

    // OPTIONAL PARAMETER INJECTION: Emit null for optional parameters not provided
    // This handles cases like `allocator: ?std.mem.Allocator` where user doesn't pass a value
    if (event_decl) |event| {
        var optional_injected: usize = 0;
        for (event.input.fields) |field| {
            // Check if this field has an optional type (starts with ?)
            const is_optional = field.type.len > 0 and field.type[0] == '?';
            if (!is_optional) continue;

            // Check if this field was already explicitly provided
            var already_provided = false;
            for (args) |arg| {
                if (std.mem.eql(u8, arg.name, field.name)) {
                    already_provided = true;
                    break;
                }
            }

            if (!already_provided) {
                if (args.len > 0 or optional_injected > 0) try emitter.write(", ");
                try emitter.write(".");
                try emitter.write(field.name);
                try emitter.write(" = null");
                optional_injected += 1;
            }
        }
    }

    // COMPTIME INJECTION: If in comptime_only mode, inject program and allocator
    // if the event declares those parameters and they weren't explicitly provided
    const is_comptime_emission = if (ctx.emit_mode) |mode| mode == .comptime_only else false;
    if (is_comptime_emission) {
        if (event_decl) |event| {
            var injected_count: usize = 0;
            for (event.input.fields) |field| {
                // Check for Program parameter (not already provided)
                if (std.mem.eql(u8, field.name, "program")) {
                    // Check if program was already explicitly provided
                    var already_provided = false;
                    for (args) |arg| {
                        if (std.mem.eql(u8, arg.name, "program")) {
                            already_provided = true;
                            break;
                        }
                    }
                    if (!already_provided) {
                        if (args.len > 0 or injected_count > 0) try emitter.write(", ");
                        try emitter.write(".program = program");
                        injected_count += 1;
                    }
                }
                // Check for allocator parameter (not already provided)
                if (std.mem.eql(u8, field.name, "allocator")) {
                    // Check if allocator was already explicitly provided
                    var already_provided = false;
                    for (args) |arg| {
                        if (std.mem.eql(u8, arg.name, "allocator")) {
                            already_provided = true;
                            break;
                        }
                    }
                    if (!already_provided) {
                        if (args.len > 0 or injected_count > 0) try emitter.write(", ");
                        try emitter.write(".allocator = allocator");
                        injected_count += 1;
                    }
                }
                // Check for InvocationMeta parameter (not already provided)
                if (field.is_invocation_meta) {
                    var already_provided = false;
                    for (args) |arg| {
                        if (std.mem.eql(u8, arg.name, field.name)) {
                            already_provided = true;
                            break;
                        }
                    }
                    if (!already_provided) {
                        if (args.len > 0 or injected_count > 0) try emitter.write(", ");
                        try emitter.write(".");
                        try emitter.write(field.name);
                        try emitter.write(" = __koru_ast.InvocationMeta{\n");
                        emitter.indent();

                        // .path
                        try emitter.writeIndent();
                        try emitter.write(".path = \"");
                        if (invocation_path.module_qualifier) |mq| {
                            try emitter.write(mq);
                            try emitter.write(":");
                        }
                        for (invocation_path.segments, 0..) |seg, i| {
                            if (i > 0) try emitter.write(".");
                            try writeMangledSeg(emitter, seg);
                        }
                        try emitter.write("\",\n");

                        // .module
                        try emitter.writeIndent();
                        try emitter.write(".module = ");
                        if (invocation_path.module_qualifier) |mq| {
                            try emitter.write("\"");
                            try emitter.write(mq);
                            try emitter.write("\"");
                        } else {
                            try emitter.write("null");
                        }
                        try emitter.write(",\n");

                        // .event_name
                        try emitter.writeIndent();
                        try emitter.write(".event_name = \"");
                        if (invocation_path.segments.len > 0) {
                            try emitter.write(invocation_path.segments[invocation_path.segments.len - 1]);
                        }
                        try emitter.write("\",\n");

                        // .annotations
                        try emitter.writeIndent();
                        try emitter.write(".annotations = ");
                        if (ctx.current_flow_annotations) |anns| {
                            try emitter.write("&[_][]const u8{");
                            for (anns, 0..) |ann, i| {
                                if (i > 0) try emitter.write(", ");
                                try emitter.writeZigStringLiteral(ann);
                            }
                            try emitter.write("}");
                        } else {
                            try emitter.write("&[_][]const u8{}");
                        }
                        try emitter.write(",\n");

                        // .location
                        try emitter.writeIndent();
                        try emitter.write(".location = ");
                        if (ctx.current_flow_location) |loc| {
                            try emitter.write(".{ .file = \"");
                            try emitter.write(loc.file);
                            try emitter.write("\", .line = ");
                            var line_buf: [16]u8 = undefined;
                            const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{loc.line}) catch "0";
                            try emitter.write(line_str);
                            try emitter.write(", .column = ");
                            var col_buf: [16]u8 = undefined;
                            const col_str = std.fmt.bufPrint(&col_buf, "{d}", .{loc.column}) catch "0";
                            try emitter.write(col_str);
                            try emitter.write(" }");
                        } else {
                            try emitter.write(".{ .file = \"unknown\", .line = 0, .column = 0 }");
                        }
                        try emitter.write(",\n");

                        emitter.dedent();
                        try emitter.writeIndent();
                        try emitter.write("}");
                        injected_count += 1;
                    }
                }
            }
        }
    }
}

const EmitError = error{
    BufferOverflow,
    ArrayLiteralMissingType,
    ArrayLiteralInvalidTarget,
    OutOfMemory, // growable CodeEmitter buffers allocate on demand
};

/// Emit a value expression (may reference input fields)
pub fn emitValue(emitter: *CodeEmitter, ctx: *EmissionContext, value: []const u8) EmitError!void {
    const trimmed = std.mem.trim(u8, value, " \t");

    // Koru array literal: [a, b, c]
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        return error.ArrayLiteralMissingType;
    }

    // Koru struct literal: { field: value } -> .{ .field = value }
    if (isKoruStructLiteral(trimmed)) {
        try emitStructLiteral(emitter, ctx, trimmed);
        return;
    }

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
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        return error.ArrayLiteralMissingType;
    }

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
            try emitter.write(value[i .. i + 1]);
            i += 1;
            continue;
        }

        // Track char literals
        if (!in_string and c == '\'' and !isEscaped(value, i)) {
            in_char = !in_char;
            try emitter.write(value[i .. i + 1]);
            i += 1;
            continue;
        }

        // If we're in a string or char literal, just emit as-is
        if (in_string or in_char) {
            try emitter.write(value[i .. i + 1]);
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
                const before_ok = i == 0 or (!isIdentChar(value[i - 1]) and value[i - 1] != '@');
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
        try emitter.write(value[i .. i + 1]);
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
            try emitter.write(value[i .. i + 1]);
            i += 1;
            continue;
        }

        // Track char literals
        if (!in_string and c == '\'' and !isEscaped(value, i)) {
            in_char = !in_char;
            try emitter.write(value[i .. i + 1]);
            i += 1;
            continue;
        }

        // If we're in a string or char literal, just emit as-is
        if (in_string or in_char) {
            try emitter.write(value[i .. i + 1]);
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
        try emitter.write(value[i .. i + 1]);
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
        .builtin_call => |bc| {
            try emitter.write("@");
            try emitter.write(bc.name);
            try emitter.write("(");
            for (bc.args, 0..) |arg, i| {
                if (i > 0) try emitter.write(", ");
                try emitExpression(emitter, ctx, arg, binding_substitution);
            }
            try emitter.write(")");
        },
        .array_index => |ai| {
            try emitExpression(emitter, ctx, ai.object, binding_substitution);
            try emitter.write("[");
            try emitExpression(emitter, ctx, ai.index, binding_substitution);
            try emitter.write("]");
        },
        .conditional => |c| {
            try emitter.write("if (");
            try emitExpression(emitter, ctx, c.condition, binding_substitution);
            try emitter.write(") ");
            try emitExpression(emitter, ctx, c.then_expr, binding_substitution);
            try emitter.write(" else ");
            try emitExpression(emitter, ctx, c.else_expr, binding_substitution);
        },
        .function_call => |fc| {
            try emitExpression(emitter, ctx, fc.callee, binding_substitution);
            try emitter.write("(");
            for (fc.args, 0..) |arg, i| {
                if (i > 0) try emitter.write(", ");
                try emitExpression(emitter, ctx, arg, binding_substitution);
            }
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
    continuations_in: []const ast.Continuation,
    prev_result: []const u8,
    result_counter: *usize,
    is_partial_switch: bool,
) anyerror!void {
    // Effect (`!`) continuations are handler CALLS that fire DURING a proc run;
    // they are NOT terminals and have no tag in the event's Output union (which
    // holds terminals only). The inline path partitions them out before emitting
    // the terminal switch (see emitFlow, ~line 3587). A NON-inlined effectful
    // invocation — e.g. a mocked event whose impl substitutes a plain Output
    // value — bypasses that partition and hands us the full continuation list. If
    // we emit a switch arm per continuation we produce `.<effect> => |_| {}`
    // against a union with no such field, and Zig rejects it (395_009). A
    // result-dispatch switch is over terminals, so drop effect continuations here.
    var filtered_conts: ?std.ArrayList(ast.Continuation) = null;
    defer if (filtered_conts) |*f| f.deinit(ctx.allocator);
    const continuations = blk: {
        var has_effect = false;
        for (continuations_in) |cont| {
            if (cont.kind == .effect) {
                has_effect = true;
                break;
            }
        }
        if (!has_effect) break :blk continuations_in;
        var list: std.ArrayList(ast.Continuation) = .empty;
        for (continuations_in) |cont| {
            if (cont.kind != .effect) try list.append(ctx.allocator, cont);
        }
        filtered_conts = list;
        break :blk list.items;
    };

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

        // Special case: |? catch-all as the sole continuation (all branches optional).
        // There is no "?" field on the union — every result IS an optional branch, so
        // the body always fires unconditionally.  Discard the result and execute directly.
        if (cont.is_catchall and std.mem.eql(u8, cont.branch, "?") and cont.catchall_metatype == null) {
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try emitter.write(prev_result);
            try emitter.write(";\n");
            try emitContinuationBody(emitter, ctx, cont, result_counter);
            return;
        }

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
            const unique = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{ prev_result, cont.branch });
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

        // Shape-destructure: per-field consts off the payload binding.
        if (cont.destructure.len > 0) {
            try emitter.writeIndent();
            try emitDestructureConsts(emitter, cont.destructure, binding_name);
            try emitter.write("\n");
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
    const continuation_branch_groups = try groupContinuationsByBranch(ctx.allocator, continuations);
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
                    // Check if catch-all has metatype binding (|? Audit e |>)
                    const has_metatype_binding = catchall.catchall_metatype != null and
                        catchall.binding != null and
                        !std.mem.eql(u8, catchall.binding.?, "_");

                    // Emit cases for unhandled optional branches
                    for (event.branches) |branch| {
                        if (!branch.is_optional) continue; // Only optional branches
                        if (handled_branches.contains(branch.name)) continue; // Already handled

                        // Emit switch case for this unhandled optional branch
                        try emitter.writeIndent();
                        try emitter.write(".");
                        try writeBranchName(emitter, branch.name);

                        if (has_metatype_binding) {
                            // Capture payload (unused for now), construct metatype
                            try emitter.write(" => |_| {\n");
                            emitter.indent();

                            // Construct the metatype object with .branch set
                            try emitter.writeIndent();
                            try emitter.write("const ");
                            try emitter.write(catchall.binding.?);
                            try emitter.write(" = taps.");
                            try emitter.write(catchall.catchall_metatype.?);
                            try emitter.write("{\n");
                            emitter.indent();

                            // .source = event name
                            try emitter.writeIndent();
                            try emitter.write(".source = \"");
                            try emitter.write(source_event);
                            try emitter.write("\",\n");

                            // .destination = null (terminal)
                            try emitter.writeIndent();
                            try emitter.write(".destination = null,\n");

                            // .branch = branch name
                            try emitter.writeIndent();
                            try emitter.write(".branch = \"");
                            try emitter.write(branch.name);
                            try emitter.write("\",\n");

                            // .timestamp_ns (Profile/Audit only)
                            const is_transition = std.mem.eql(u8, catchall.catchall_metatype.?, "Transition");
                            if (!is_transition) {
                                try emitter.writeIndent();
                                try emitter.write(".timestamp_ns = __koru_std.time.nanoTimestamp(),\n");

                                // .payload (Audit only)
                                const is_audit = std.mem.eql(u8, catchall.catchall_metatype.?, "Audit");
                                if (is_audit) {
                                    try emitter.writeIndent();
                                    try emitter.write(".payload = null,\n");
                                }
                            }

                            emitter.dedent();
                            try emitter.writeIndent();
                            try emitter.write("};\n");

                            // Execute catch-all pipeline (can now reference binding)
                            try emitContinuationBody(emitter, ctx, catchall, result_counter);

                            emitter.dedent();
                            try emitter.writeIndent();
                            try emitter.write("},\n");
                        } else {
                            // No metatype binding — discard payload
                            try emitter.write(" => |_| {\n");
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
    noop_branches: []const []const u8,
) anyerror!void {
    if (continuations.len == 0 and unreachable_branches.len == 0 and noop_branches.len == 0) {
        return;
    }

    try emitter.writeIndent();
    try emitter.write("switch (");
    try emitter.write(prev_result);
    try emitter.write(") {\n");
    emitter.indent();

    // Group continuations by branch name (for when-clause merging)
    const branch_groups = try groupContinuationsByBranch(std.heap.page_allocator, continuations);
    defer {
        for (branch_groups) |group| {
            std.heap.page_allocator.free(group.continuations);
        }
        std.heap.page_allocator.free(branch_groups);
    }

    // Emit continuation cases, grouped by branch
    for (branch_groups) |group| {
        if (group.continuations.len == 1) {
            // Single continuation - emit directly
            try emitContinuationCase(emitter, ctx, group.continuations[0], result_counter);
        } else {
            // Multiple when-clauses for same branch - emit as if/else chain in one switch arm
            const first_cont = group.continuations[0];
            const binding_name = first_cont.binding orelse first_cont.branch;

            try emitter.writeIndent();
            try emitter.write(".");
            try writeBranchName(emitter, group.branch_name);
            try emitter.write(" => |");
            try writeBranchName(emitter, binding_name);
            try emitter.write("| {\n");
            emitter.indent();

            // Emit if/else chain for when-clauses
            for (group.continuations, 0..) |cont_ptr, idx| {
                try emitter.writeIndent();
                if (cont_ptr.condition) |condition| {
                    if (idx == 0) {
                        try emitter.write("if (");
                    } else {
                        try emitter.write("else if (");
                    }
                    try emitter.write(condition);
                    try emitter.write(") {\n");
                } else {
                    if (idx > 0) {
                        try emitter.write("else {\n");
                    }
                }

                emitter.indent();
                try emitContinuationBody(emitter, ctx, cont_ptr, result_counter);
                emitter.dedent();

                try emitter.writeIndent();
                try emitter.write("}\n");
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("},\n");
        }
    }

    // Emit explicit unreachable cases for guarded branches
    for (unreachable_branches) |branch| {
        try emitter.writeIndent();
        try emitter.write(".");
        try writeBranchName(emitter, branch);
        try emitter.write(" => unreachable,\n");
    }

    // Emit no-op cases for branches that can break out of the loop
    // (looping branches with terminal when-clause sub-paths)
    for (noop_branches) |branch| {
        try emitter.writeIndent();
        try emitter.write(".");
        if (CodeEmitter.isZigKeyword(branch)) {
            try emitter.write("@\"");
            try emitter.write(branch);
            try emitter.write("\"");
        } else {
            try emitter.write(branch);
        }
        try emitter.write(" => {},\n");
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

    // Emit source marker for branch
    if (cont.location.line > 0) {
        try emitter.writeIndent();
        try emitter.write("// >>> BRANCH: ");
        try emitter.write(cont.location.file);
        try emitter.write(":");
        var branch_line_buf: [32]u8 = undefined;
        const branch_line_str = try std.fmt.bufPrint(&branch_line_buf, "{}", .{cont.location.line});
        try emitter.write(branch_line_str);
        try emitter.write("  | ");
        try emitter.write(cont.branch);
        if (cont.binding) |b| {
            try emitter.write(" ");
            try emitter.write(b);
        }
        try emitter.write(" |>\n");
    }
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
        false; // Can't verify — omit capture to avoid shadowing

    // Only emit capture syntax if the branch has payload fields
    if (has_payload_fields) {
        // Emit capture syntax: |*name| for mutable, |name| for const
        if (needs_mutable_capture and binding_used) {
            try emitter.write(" => |*");
        } else {
            try emitter.write(" => |");
        }

        if (cont.destructure.len > 0) {
            // Shape-destructure: capture the payload under a temp, then
            // per-field consts at the top of the case block.
            try emitter.write("__koru_dst");
        } else if (binding_name.len == 0 or !binding_used) {
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

    if (cont.destructure.len > 0 and has_payload_fields) {
        try emitter.writeIndent();
        try emitDestructureConsts(emitter, cont.destructure, "__koru_dst");
        try emitter.write("\n");
    }

    // Set current branch for tap matching (used by label_jump steps)
    const saved_branch = ctx.current_branch;
    ctx.current_branch = cont.branch;
    defer ctx.current_branch = saved_branch;

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
        try emitter.write("} else {\n");
        // When condition is false, skip the tap step but still execute
        // the nested continuations (which contain the spliced original flow)
        emitter.indent();
        for (cont.continuations) |*nested| {
            try emitContinuationBody(emitter, ctx, nested, result_counter);
        }
        emitter.dedent();
        try emitter.writeIndent();
        try emitter.write("}\n");
    } else {
        // No when-clause - execute continuation body directly
        try emitContinuationBody(emitter, ctx, cont, result_counter);
    }

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
    const binding_name = if (first_cont.destructure.len > 0) "__koru_dst" else first_cont.binding orelse first_cont.branch;

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

    if (first_cont.destructure.len > 0) {
        // Shape-destructure: per-field consts before the guard chain so
        // when-conditions can reference destructured names.
        try emitter.writeIndent();
        try emitDestructureConsts(emitter, first_cont.destructure, "__koru_dst");
        try emitter.write("\n");
    }

    // Emit if/else chain for when-clauses
    for (group.continuations, 0..) |cont, idx| {
        try emitter.writeIndent();

        if (cont.condition) |condition| {
            // When-clause - emit if or else if
            if (idx == 0) {
                try emitter.write("if (");
            } else {
                try emitter.write("else if (");
            }
            try emitter.write(condition);
            try emitter.write(") {\n");
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

/// Check if a continuation (or its nested sub-tree) loops back to a label
fn continuationLoopsToLabel(cont: ast.Continuation, label: []const u8) bool {
    if (cont.node) |step| {
        if (step == .label_jump) {
            if (std.mem.eql(u8, step.label_jump.label, label)) return true;
        } else if (step == .label_apply) {
            if (std.mem.eql(u8, step.label_apply, label)) return true;
        }
    }
    for (cont.continuations) |nested| {
        if (continuationLoopsToLabel(nested, label)) return true;
    }
    return false;
}

/// Check if a looping branch also has when-clause paths that break out of the loop.
/// Returns true if the branch has at least one continuation that doesn't loop back.
fn branchHasBreakPath(
    branch_name: []const u8,
    label: []const u8,
    all_continuations: []const ast.Continuation,
) bool {
    for (all_continuations) |cont| {
        if (!std.mem.eql(u8, cont.branch, branch_name)) continue;
        if (!continuationLoopsToLabel(cont, label)) return true;
    }
    return false;
}

/// Check if any continuation (recursively) contains a terminal step
/// This is used to detect when taps wrap terminal branches with void continuations,
/// which can break out of loops even though the top-level branch looks like it loops.
fn hasNestedTerminalInContinuations(continuations: []const ast.Continuation) bool {
    for (continuations) |cont| {
        // Check if this continuation's node is a terminal
        if (cont.node) |step| {
            if (step == .terminal) {
                return true;
            }
        }

        // Check if this is a void continuation with no node and no nested continuations
        // (another form of terminal)
        if (cont.node == null and cont.continuations.len == 0) {
            return true;
        }

        // Recursively check nested continuations
        if (hasNestedTerminalInContinuations(cont.continuations)) {
            return true;
        }
    }
    return false;
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
    _: usize, // absolute_idx - not used with single step design
    result_counter: *usize,
) !void {
    // Note: With single step design, is_last_step and next_is_terminal are always true/false
    // These constants existed for the old multi-step pipeline

    const needs_result = cont.continuations.len > 0;

    // A `-> T` bare-return step binds its result to the call-site `: name`
    // (return_binding). Use that as the step's result variable so the call, the
    // unused-suppression, and the following pipeline all reference one name.
    var alloc_result: ?[]const u8 = null;
    const current_result = if (!needs_result)
        "_"
    else if (step.* == .invocation and step.invocation.return_binding != null)
        step.invocation.return_binding.?
    else blk: {
        alloc_result = try std.fmt.allocPrint(ctx.allocator, "{s}{}", .{ ctx.result_prefix, result_counter.* });
        break :blk alloc_result.?;
    };
    defer if (alloc_result) |r| ctx.allocator.free(r);

    try emitStep(emitter, ctx, step, current_result);

    // Void steps don't produce a result variable:
    // - assignment: just assigns to a mutable binding
    // - inline_code: just emits verbatim code (e.g., print.ln transform)
    // - foreach: control flow with no value
    // - switch_result: self-contained switch with inline code (e.g., query transform)
    const is_void_step = step.* == .assignment or step.* == .inline_code or step.* == .foreach or step.* == .switch_result;

    // label_jump and label_apply emit 'continue :label;' which is terminal.
    // No code should follow — skip the result variable suppression.
    if (step.* == .label_jump or step.* == .label_apply) return;

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
    // Zero-overhead control flow at depth: if a template transform set
    // inline_body on this continuation's invocation node (e.g. a nested `~for`
    // in a pipeline — `| result r |> for(0..r) ! each … | done …`), emit it via
    // the shared node emitter — the SAME path top-level flows take. The
    // continuation's children are the node's branch continuations. This is the
    // de-duplication that makes inline templates work at every depth, not just
    // top-level: one helper, both call sites.
    if (cont.node) |node| {
        if (node == .invocation) {
            if (node.invocation.inline_body) |inline_code_raw| {
                try emitInlineBodyNode(emitter, ctx, inline_code_raw, cont.continuations, &cont.node.?.invocation.path, result_counter);
                return;
            }
        }
    }

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
            try writeBranchName(emitter, arg.name);

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
                    std.debug.panic("COMPILER BUG: Field '{s}' not found in event after checking {} fields!", .{ arg.name, event.input.fields.len });
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
        try emitter.write("var "); // var, not const - we'll update it in the loop!
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
            try writeBranchName(emitter, arg.name);
            try emitter.write(" = ");
            try emitter.write(lwi.label);
            try emitter.write("_");
            try writeBranchName(emitter, arg.name);
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
                // Nested labeled-loop on effect-bearing event isn't wired
                // here yet — separate from the top-level pre_label case.
                .handlers_name = null,
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

        // Track current loop label for break statements in terminal branches
        const saved_label = ctx.current_label;
        ctx.current_label = lwi.label;
        defer ctx.current_label = saved_label;

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
                // NOTE: Zig doesn't track exhaustiveness via while loop condition control flow.
                // The switch still needs to handle ALL enum variants.
                // We must mark non-looping branches as unreachable explicitly.
                if (looping_conts.items.len > 0) {
                    // Build list of non-looping branch names
                    var non_looping_branch_names = try std.ArrayList([]const u8).initCapacity(ctx.allocator, cont.continuations.len);
                    defer non_looping_branch_names.deinit(ctx.allocator);

                    for (cont.continuations) |nested_cont| {
                        var is_looping = false;
                        for (looping_branches) |loop_branch| {
                            if (std.mem.eql(u8, nested_cont.branch, loop_branch)) {
                                is_looping = true;
                                break;
                            }
                        }
                        if (!is_looping) {
                            try non_looping_branch_names.append(ctx.allocator, nested_cont.branch);
                        }
                    }

                    // Emit with non-looping branches marked as unreachable
                    try emitContinuationListWithUnreachableBranches(emitter, ctx, looping_conts.items, result_var, result_counter, non_looping_branch_names.items, &.{});
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

        // CRITICAL: Clear current_label AFTER closing the loop!
        // Non-looping branches are emitted OUTSIDE the loop, so they can't use break :label
        ctx.current_label = null;

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

                // Split looping branches: purely-looping → unreachable, has-break-path → noop
                var purely_looping = try std.ArrayList([]const u8).initCapacity(ctx.allocator, looping_branches.len);
                defer purely_looping.deinit(ctx.allocator);
                var break_path = try std.ArrayList([]const u8).initCapacity(ctx.allocator, looping_branches.len);
                defer break_path.deinit(ctx.allocator);

                for (looping_branches) |branch| {
                    if (branchHasBreakPath(branch, lwi.label, cont.continuations)) {
                        try break_path.append(ctx.allocator, branch);
                    } else {
                        try purely_looping.append(ctx.allocator, branch);
                    }
                }

                try emitContinuationListWithUnreachableBranches(emitter, ctx, non_looping_conts.items, result_var, result_counter, purely_looping.items, break_path.items);
            }
        } else if (cont.continuations.len > 0 and looping_branches.len == cont.continuations.len) {
            // ALL top-level branches are looping - but check for nested terminals
            // (e.g., from taps that wrap terminal branches with void continuations)
            const has_nested_terminal = hasNestedTerminalInContinuations(cont.continuations);
            if (!has_nested_terminal) {
                // No nested terminals - the while loop only exits via return statements
                // Tell Zig this code path is unreachable
                try emitter.writeIndent();
                try emitter.write("unreachable;\n");
            }
            // If there ARE nested terminals, the loop can break normally - no unreachable
        }

        // Label case is done - no remaining steps to process
    } else {
        // Normal case - no label_with_invocation

        // Tail self-continuation reentry: when this flow is being emitted as a
        // self-loop (ctx.self_loop_active) and THIS continuation is the tail
        // self-call of the handler's own event with identity-forwarding
        // children, replace the self-call with state-var reassignment +
        // `continue :label`. Skip the invocation, its result suppression, and
        // the forwarding continuation — they would either reference an
        // undeclared result var or be unreachable after the `continue`.
        if (ctx.self_loop_active) {
            if (ctx.self_loop_event_canonical) |canonical| {
                if (continuationIsSelfTailForwarder(cont, canonical, ctx)) {
                    try emitSelfTailReentry(emitter, ctx, cont);
                    return;
                }
            }
        }

        const is_metatype_binding = if (cont.node) |step| step == .metatype_binding else false;
        if (is_metatype_binding) {
            // Scope metatype bindings so identical names don't collide across observers.
            try emitter.writeIndent();
            try emitter.write("{\n");
            emitter.indent();

            if (cont.node) |*step| {
                try emitPipelineStep(emitter, ctx, cont, step, 0, result_counter);
            }

            if (cont.continuations.len > 0) {
                for (cont.continuations) |*nested_cont| {
                    try emitContinuationBody(emitter, ctx, nested_cont, result_counter);
                }
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");
            return;
        }

        // Check if this is a void step that doesn't produce a result
        // metatype_binding creates a Profile/Transition struct but doesn't produce a switchable result
        const is_void_step = if (cont.node) |step|
            (step == .assignment or step == .inline_code or step == .foreach or step == .metatype_binding)
        else
            false;

        // Effect branches phase 3b — chained invocation path.
        // When the step is an invocation targeting an event that declares `!`
        // branches, mirror emitFlow's top-level dance: partition this
        // continuation's children into effect (folded into Handlers struct)
        // and terminal (post-call switch arms), synthesize the Handlers
        // struct, and install pending_handlers_name so emitInvocation appends
        // the comptime 2nd arg. Restore after the invocation so downstream
        // emissions don't inherit this Handlers ref.
        const prev_pending_handlers = ctx.pending_handlers_name;
        var nested_handlers_name_owned: ?[]const u8 = null;
        defer if (nested_handlers_name_owned) |h| ctx.allocator.free(h);

        var nested_terminal_buf: std.ArrayList(ast.Continuation) = .empty;
        defer nested_terminal_buf.deinit(ctx.allocator);
        var nested_effect_buf: std.ArrayList(ast.Continuation) = .empty;
        defer nested_effect_buf.deinit(ctx.allocator);

        var nested_event_has_effect = false;
        var nested_inline_elig: ?InlineEligibility = null;
        if (cont.node) |maybe_step| {
            if (maybe_step == .invocation) {
                const event_decl_nested = if (ctx.ast_items) |items|
                    findEventDeclByPath(items, &maybe_step.invocation.path)
                else
                    null;
                if (event_decl_nested) |ed| {
                    for (ed.branches) |b| {
                        if (b.kind == .effect) {
                            nested_event_has_effect = true;
                            break;
                        }
                    }
                    if (nested_event_has_effect) {
                        for (cont.continuations) |c| {
                            if (c.kind == .effect) {
                                try nested_effect_buf.append(ctx.allocator, c);
                            } else {
                                try nested_terminal_buf.append(ctx.allocator, c);
                            }
                        }
                        nested_inline_elig = inlineEffectfulEligibility(ctx, &maybe_step.invocation, cont.continuations);
                        if (nested_inline_elig == null) {
                            const hname = try std.fmt.allocPrint(ctx.allocator, "Handlers_{d}", .{result_counter.*});
                            nested_handlers_name_owned = hname;
                            try emitHandlersStruct(emitter, ctx, hname, nested_effect_buf.items, ed);
                            ctx.pending_handlers_name = hname;
                        }
                    }
                }
            }
        }

        const effective_continuations: []const ast.Continuation = if (nested_event_has_effect)
            nested_terminal_buf.items
        else
            cont.continuations;

        if (cont.node) |*step| {
            if (nested_event_has_effect) {
                // Inline the pipeline-step emission so needs_result is computed
                // from terminal-only continuations (cont.continuations still
                // contains the effect conts that are now folded into Handlers).
                const needs_result = effective_continuations.len > 0;
                const current_result = if (needs_result)
                    try std.fmt.allocPrint(ctx.allocator, "{s}{}", .{ ctx.result_prefix, result_counter.* })
                else
                    "_";
                defer if (needs_result) ctx.allocator.free(current_result);

                if (nested_inline_elig) |elig| {
                    try emitInlineEffectfulCall(
                        emitter,
                        ctx,
                        &step.invocation,
                        cont.continuations,
                        elig,
                        if (needs_result) current_result else null,
                        result_counter.*,
                    );
                } else {
                    try emitStep(emitter, ctx, step, current_result);
                }

                if (needs_result and !std.mem.eql(u8, current_result, "_")) {
                    try emitter.writeIndent();
                    try emitter.write("_ = &");
                    try emitter.write(current_result);
                    try emitter.write(";\n");
                }
                if (needs_result) {
                    result_counter.* += 1;
                }
            } else {
                try emitPipelineStep(emitter, ctx, cont, step, 0, result_counter);

                // label_jump and label_apply emit 'continue :label;' which is terminal.
                // No code should follow — return immediately to avoid unreachable dead code.
                if (step.* == .label_jump or step.* == .label_apply) return;
            }
        }

        // Pop the Handlers scope before processing nested continuations so
        // chained terminal-arm emissions don't accidentally pick up our hname.
        if (nested_event_has_effect) {
            ctx.pending_handlers_name = prev_pending_handlers;
        }

        // Emit nested continuations
        if (effective_continuations.len > 0) {
            if (is_void_step) {
                // Void step (like assignment) - emit continuations directly as void chain
                // Each continuation should be emitted without needing a result to switch on
                for (effective_continuations) |*nested_cont| {
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

                    try emitContinuationList(emitter, ctx, effective_continuations, last_result, result_counter, false);
                } else {
                    // No invocation in step, keep current source
                    try emitContinuationList(emitter, ctx, effective_continuations, last_result, result_counter, false);
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
            // Terminal steps inside loops should break out of the loop
            // This handles taps on terminal branches (e.g., | quit |> on_quit() | "" |> _)
            if (ctx.current_label) |label| {
                try emitter.writeIndent();
                try emitter.write("break :");
                try emitter.write(label);
                try emitter.write(";\n");
            }
            // Outside of loops, terminal steps don't need to emit anything
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
            // Wrap in scope block with fixed synthesized name so multiple bindings don't collide
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
                    // Escape keywords (e.g., .@"error" for error branch)
                    if (codegen_utils.needsEscaping(mb.branch)) {
                        try emitter.write("@\"");
                        try emitter.write(mb.branch);
                        try emitter.write("\"");
                    } else {
                        try emitter.write(mb.branch);
                    }
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

                // .payload field - ONLY for Audit
                const is_audit = std.mem.eql(u8, mb.metatype, "Audit");
                if (is_audit) {
                    try emitter.writeIndent();
                    try emitter.write(".payload = null,  // TODO: Serialize continuation payload\n");
                }
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("};\n");

            // Suppress unused constant warning (binding may be discarded with _)
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try emitter.write(mb.binding);
            try emitter.write(";\n");
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
                        .handlers_name = null,
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
                    try writeBranchName(emitter, arg.name);
                    try emitter.write(" = ");
                    try emitter.write(label_name);
                    try emitter.write("_");
                    try writeBranchName(emitter, arg.name);
                }
                try emitter.write(" }");
                // Effect-branches phase 3b: re-entry preserves Handlers arg.
                if (tctx.handlers_name) |hname| {
                    try emitter.write(", ");
                    try emitter.write(hname);
                }
                try emitter.write(");\n");
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
                try writeBranchName(emitter, arg.name);
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
                        .handlers_name = null,
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
                    try writeBranchName(emitter, arg.name);
                    try emitter.write(" = ");
                    try emitter.write(lj.label);
                    try emitter.write("_");
                    try writeBranchName(emitter, arg.name);
                }
                try emitter.write(" }");
                // Effect-branches phase 3b: if the labeled target carries a
                // synthesized Handlers struct (event declares `!` branches),
                // the re-entry call must pass the same comptime 2nd arg.
                if (tctx.handlers_name) |hname| {
                    try emitter.write(", ");
                    try emitter.write(hname);
                }
                try emitter.write(");\n");
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
        .expression => |code| {
            // A Zig expression at body position. In a generic context we
            // discard the value to keep emission well-formed. The
            // effect-branch-handler context overrides this in
            // emitHandlersStruct, where the expression becomes the
            // `return EXPR;` of the synthesized resume fn.
            try emitter.writeIndent();
            try emitter.write("_ = ");
            try emitter.write(code);
            try emitter.write(";\n");
        },
        .foreach => |fe| {
            // Emit for loop with proper AST body
            // Iterate over branches to find loop body (has @scope) vs post-loop branches
            var loop_branch: ?*const ast.NamedBranch = null;
            var post_loop_branches = std.ArrayListUnmanaged(*const ast.NamedBranch){};
            defer post_loop_branches.deinit(ctx.allocator);

            for (fe.branches) |*branch| {
                // Branch with @scope annotation is the loop body (runs N times)
                const has_scope = for (branch.annotations) |ann| {
                    if (std.mem.eql(u8, ann, "@scope")) break true;
                } else false;

                if (has_scope) {
                    loop_branch = branch;
                } else {
                    try post_loop_branches.append(ctx.allocator, branch);
                }
            }

            // Get loop binding (default to "_" if no loop branch)
            const raw_binding = if (loop_branch) |lb| lb.binding orelse "_" else "_";

            // Capture unique for_id for BOTH loop binding and result prefix (avoids shadowing in nested loops)
            const for_id = ctx.for_counter;
            ctx.for_counter += 1;

            // Generate unique binding for default names to avoid shadowing in nested loops
            var binding_buf: [64]u8 = undefined;
            const loop_binding = if (std.mem.eql(u8, raw_binding, "_")) blk: {
                break :blk std.fmt.bufPrint(&binding_buf, "__for_item_{d}", .{for_id}) catch raw_binding;
            } else raw_binding;

            try emitter.writeIndent();
            try emitter.write("for (");
            try emitter.write(fe.iterable);
            try emitter.write(") |");
            try emitter.write(loop_binding);
            try emitter.write("| {\n");
            emitter.indent();

            // Suppress unused capture warning (binding might not be used in body)
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try emitter.write(loop_binding);
            try emitter.write(";\n");

            // Emit loop body continuations
            var step_idx: usize = 0;

            if (loop_branch) |lb| {
                // Set result prefix based on branch name AND for_id for nested continuations
                // The for_id ensures nested loops don't shadow outer loop's result variables
                var prefix_buf: [64]u8 = undefined;
                const branch_prefix = std.fmt.bufPrint(&prefix_buf, "{s}{d}_result_", .{ lb.name, for_id }) catch "loop_result_";

                const saved_prefix = ctx.result_prefix;
                ctx.result_prefix = branch_prefix;
                defer ctx.result_prefix = saved_prefix;

                for (lb.body) |*cont| {
                    if (cont.node) |node| {
                        var result_buf: [64]u8 = undefined;
                        const inner_result = std.fmt.bufPrint(&result_buf, "{s}{d}", .{ branch_prefix, step_idx }) catch "_";
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
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");

            // Emit post-loop branches (e.g., done)
            for (post_loop_branches.items) |branch| {
                // Set result prefix based on branch name
                var prefix_buf: [64]u8 = undefined;
                const branch_prefix = std.fmt.bufPrint(&prefix_buf, "{s}_result_", .{branch.name}) catch "post_result_";

                const saved_prefix = ctx.result_prefix;
                ctx.result_prefix = branch_prefix;
                defer ctx.result_prefix = saved_prefix;

                for (branch.body) |*cont| {
                    if (cont.node) |node| {
                        // If in_handler and the node is a branch_constructor, use "_" to trigger return
                        const is_return_node = ctx.in_handler and node == .branch_constructor;
                        var result_buf: [64]u8 = undefined;
                        const inner_result = if (is_return_node) "_" else std.fmt.bufPrint(&result_buf, "{s}{d}", .{ branch_prefix, step_idx }) catch "_";
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
        .switch_result => |sr| {
            // Emit switch on union result type (e.g., from query transform)
            // Expression is inline code block that produces the union value
            // Branches contain continuations for each variant (row, empty, err, etc.)

            // First, emit the expression that produces the union value
            try emitter.writeIndent();
            try emitter.write("const __switch_result = ");
            try emitter.write(sr.expression);
            try emitter.write(";\n");

            // Then emit the switch
            try emitter.writeIndent();
            try emitter.write("switch (__switch_result) {\n");
            emitter.indent();

            // Emit each branch
            for (sr.branches) |*branch| {
                try emitter.writeIndent();
                try emitter.write(".");
                try emitter.write(branch.name);
                if (branch.binding) |binding| {
                    try emitter.write(" => |");
                    try emitter.write(binding);
                    try emitter.write("| {\n");
                } else {
                    try emitter.write(" => {\n");
                }
                emitter.indent();

                // Emit branch body continuations
                var step_idx: usize = 0;
                for (branch.body) |*cont| {
                    if (cont.node) |node| {
                        var result_buf: [64]u8 = undefined;
                        const branch_prefix = std.fmt.bufPrint(&result_buf, "{s}_result_", .{branch.name}) catch "br_";
                        const saved_prefix = ctx.result_prefix;
                        ctx.result_prefix = branch_prefix;
                        defer ctx.result_prefix = saved_prefix;

                        var inner_result_buf: [64]u8 = undefined;
                        const inner_result = std.fmt.bufPrint(&inner_result_buf, "{s}{d}", .{ branch_prefix, step_idx }) catch "_";
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
                try emitter.write("},\n");
            }

            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");
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
                try writeBranchName(emitter, arg.name);
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
            // Terminal steps inside loops should break out of the loop
            // This handles taps on terminal branches (e.g., | quit |> on_quit() | "" |> _)
            if (ctx.current_label) |label| {
                try emitter.writeIndent();
                try emitter.write("break :");
                try emitter.write(label);
                try emitter.write(";\n");
            }
            // Outside of loops, terminal steps don't need to emit anything
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
                    try writeBranchName(emitter, arg.name);
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
                try writeBranchName(emitter, arg.name);
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
                        .handlers_name = null,
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
                    try writeBranchName(emitter, arg.name);
                    try emitter.write(" = ");
                    // Build state variable name and apply substitution if needed
                    const state_var = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{ label_name, arg.name });
                    defer ctx.allocator.free(state_var);
                    try emitValueWithBindingSubstitution(emitter, state_var, substitution);
                }
                try emitter.write(" }");
                // Effect-branches phase 3b: re-entry preserves Handlers arg.
                if (tctx.handlers_name) |hname| {
                    try emitter.write(", ");
                    try emitter.write(hname);
                }
                try emitter.write(");\n");
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
                try writeBranchName(emitter, arg.name);
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

fn findBranchFieldForEvent(
    event: *const ast.EventDecl,
    branch_name: []const u8,
    field_name: ?[]const u8,
) ?*const ast.Field {
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

fn findBranchFieldForEventType(
    event_type: type_registry_module.EventType,
    branch_name: []const u8,
    field_name: ?[]const u8,
) ?*const ast.Field {
    for (event_type.branches) |branch| {
        if (!std.mem.eql(u8, branch.name, branch_name)) continue;
        const payload = branch.payload orelse return null;
        if (field_name) |name| {
            for (payload.fields) |*field| {
                if (std.mem.eql(u8, field.name, name)) return field;
            }
        } else if (payload.fields.len > 0) {
            return &payload.fields[0];
        }
        return null;
    }
    return null;
}

fn writeQualifiedType(
    emitter: *CodeEmitter,
    module_path: []const u8,
    main_module_name: ?[]const u8,
    type_name: []const u8,
) !void {
    var remaining = type_name;
    var prefix: []const u8 = "";
    const prefixes = [_][]const u8{
        "[]const ",
        "[]",
        "?*const ",
        "?*",
        "*const ",
        "*",
        "?",
    };
    for (prefixes) |candidate| {
        if (std.mem.startsWith(u8, remaining, candidate)) {
            prefix = candidate;
            remaining = remaining[candidate.len..];
            break;
        }
    }

    if (prefix.len > 0) {
        try emitter.write(prefix);
    }
    try writeModulePath(emitter, module_path, main_module_name);
    try emitter.write(".");
    try emitter.write(remaining);
}

pub fn emitArrayLiteralForField(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    field: *const ast.Field,
    value: []const u8,
) EmitError!void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.ArrayLiteralMissingType;
    }

    const contents = trimmed[1 .. trimmed.len - 1];
    const slice_info = parseSliceType(field.type) orelse {
        return error.ArrayLiteralInvalidTarget;
    };

    if (slice_info.is_const) {
        try emitter.write("&[_]");
    } else {
        try emitter.write("@constCast(&[_]");
    }

    if (field.module_path) |module_path| {
        try writeQualifiedType(emitter, module_path, ctx.main_module_name, slice_info.element_type);
    } else {
        try emitter.write(slice_info.element_type);
    }
    try emitter.write("{ ");
    try emitArrayContents(emitter, ctx, contents);
    if (slice_info.is_const) {
        try emitter.write(" }");
    } else {
        try emitter.write(" })");
    }
}

/// Central bare-return Output emission. If the event has a `-> T` return, emits
/// `pub const Output = T;` (no tagged union — the value type itself) and returns
/// true so the caller skips its void/union logic. Returns false for ordinary
/// (branch-based) events, leaving the caller's existing Output emission intact.
/// Every `Output = ...` site routes through this so the bare-return case is
/// handled in exactly one place.
pub fn emitBareReturnOutput(emitter: *CodeEmitter, event: *const ast.EventDecl) !bool {
    if (event.return_type) |rt| {
        try emitter.write("pub const Output = ");
        try emitter.write(rt);
        try emitter.write(";\n");
        return true;
    }
    return false;
}

fn emitBranchConstructorWithEventType(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    event_type: type_registry_module.EventType,
) EmitError!void {
    if (bc.is_bare_return) {
        if (bc.plain_value) |pv| {
            try emitValue(emitter, ctx, pv);
        } else {
            try emitter.write("undefined");
        }
        return;
    }
    try emitter.write(".{ .");
    try writeBranchName(emitter, bc.branch_name);
    try emitter.write(" = ");

    if (bc.plain_value) |pv| {
        const trimmed = std.mem.trim(u8, pv, " \t");
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (findBranchFieldForEventType(event_type, bc.branch_name, null)) |field| {
                try emitArrayLiteralForField(emitter, ctx, field, pv);
            } else {
                try emitValue(emitter, ctx, pv);
            }
        } else {
            try emitValue(emitter, ctx, pv);
        }
    } else {
        try emitter.write(".{");
        for (bc.fields, 0..) |field, idx| {
            if (idx > 0) {
                try emitter.write(", ");
            }
            try emitter.write(" .");
            try emitter.write(field.name);
            try emitter.write(" = ");
            const value = if (field.expression_str) |expr| expr else field.type;
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                if (findBranchFieldForEventType(event_type, bc.branch_name, field.name)) |branch_field| {
                    try emitArrayLiteralForField(emitter, ctx, branch_field, value);
                } else {
                    try emitValue(emitter, ctx, value);
                }
            } else {
                try emitValue(emitter, ctx, value);
            }
        }
        try emitter.write(" }");
    }
    try emitter.write(" }");
}

fn emitBranchConstructorWithEvent(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    event: *const ast.EventDecl,
) EmitError!void {
    if (bc.is_bare_return) {
        if (bc.plain_value) |pv| {
            try emitValue(emitter, ctx, pv);
        } else {
            try emitter.write("undefined");
        }
        return;
    }
    try emitter.write(".{ .");
    try writeBranchName(emitter, bc.branch_name);
    try emitter.write(" = ");

    if (bc.plain_value) |pv| {
        const trimmed = std.mem.trim(u8, pv, " \t");
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            if (findBranchFieldForEvent(event, bc.branch_name, null)) |field| {
                try emitArrayLiteralForField(emitter, ctx, field, pv);
            } else {
                try emitValue(emitter, ctx, pv);
            }
        } else {
            try emitValue(emitter, ctx, pv);
        }
    } else {
        try emitter.write(".{");
        for (bc.fields, 0..) |field, idx| {
            if (idx > 0) {
                try emitter.write(", ");
            }
            try emitter.write(" .");
            try emitter.write(field.name);
            try emitter.write(" = ");
            const value = if (field.expression_str) |expr| expr else field.type;
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                if (findBranchFieldForEvent(event, bc.branch_name, field.name)) |branch_field| {
                    try emitArrayLiteralForField(emitter, ctx, branch_field, value);
                } else {
                    try emitValue(emitter, ctx, value);
                }
            } else {
                try emitValue(emitter, ctx, value);
            }
        }
        try emitter.write(" }");
    }
    try emitter.write(" }");
}

/// Emit a branch constructor (.branch = .{ fields })
pub fn emitBranchConstructor(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    is_terminal: bool,
) !void {
    _ = is_terminal; // Terminal status doesn't affect branch constructor syntax
    if (bc.is_bare_return) {
        // `-> T` bare return: yield the value directly, no `.{ .name = ... }` wrap.
        if (bc.plain_value) |pv| {
            try emitValue(emitter, ctx, pv);
        } else {
            try emitter.write("undefined");
        }
        return;
    }
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
                // A transform may have grafted generated code onto the
                // invocation (Invocation.inline_body — same encoding as a
                // raw .inline_code node). Scan it like inline code.
                if (inv.inline_body) |ib| {
                    if (containsIdentifier(ib, binding)) {
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
            .assignment => |asgn| {
                // Check all field expressions for binding reference
                for (asgn.fields) |field| {
                    if (field.expression_str) |expr| {
                        if (containsIdentifier(expr, binding)) {
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

// ============================================================================
// MODULE SUBSET EMISSION
// Emit a subset of AST items as a standalone module struct
// Used for test modules with mocked implementations
// ============================================================================

/// Emit a subset of AST items as a module struct, returning the generated code
/// This is used for emitting test-specific modules with mocked implementations
pub fn emitModuleSubset(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    module_name: []const u8,
    type_registry: ?*type_registry_module.TypeRegistry,
    original_main_module_name: ?[]const u8,
) ![]const u8 {
    // Allocate a buffer for the emitted code (64KB should be plenty for a test module)
    const BUFFER_SIZE = 64 * 1024;
    const buffer = try allocator.alloc(u8, BUFFER_SIZE);
    errdefer allocator.free(buffer);

    var code_emitter = CodeEmitter.init(buffer);

    // Create emission context with the test module prefix
    // main_module_name is set to the ORIGINAL main module so that event references
    // from the original code are recognized and redirected to the test module
    var ctx = EmissionContext{
        .allocator = allocator,
        .indent_level = 0,
        .ast_items = items,
        .module_prefix = module_name,
        .main_module_name = original_main_module_name,
        .is_sync = true,
        .type_registry = type_registry,
    };

    // Emit module struct header
    try code_emitter.write("const ");
    try code_emitter.write(module_name);
    try code_emitter.write(" = struct {\n");
    code_emitter.indent_level = 1;
    ctx.indent_level = 1;

    var emitted_events = std.StringHashMap(void).init(allocator);
    defer emitted_events.deinit();

    // First pass: emit all event declarations
    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                const canonical = try buildCanonicalEventName(&event.path, allocator, original_main_module_name);
                defer allocator.free(canonical);
                try emitted_events.put(canonical, {});
                try emitEventDeclForModule(&code_emitter, &ctx, &event, items);
            },
            else => {},
        }
    }

    // Second pass: emit mocked event decls that are missing from the subset
    // These are ImmediateImpl items (constant/mock values) whose events aren't declared locally.
    if (type_registry) |registry| {
        for (items) |item| {
            if (item != .immediate_impl) continue;
            const ii = item.immediate_impl;
            if (findEventDeclByPath(items, &ii.event_path) != null) continue;

            const canonical = try buildCanonicalEventName(&ii.event_path, allocator, original_main_module_name);
            defer allocator.free(canonical);
            if (emitted_events.contains(canonical)) continue;

            if (registry.getEventType(canonical)) |event_type| {
                try emitted_events.put(canonical, {});
                try emitEventDeclForModuleFromType(&code_emitter, &ctx, &ii.event_path, event_type, &ii);
            }
        }
    }

    // Close module struct
    code_emitter.indent_level = 0;
    try code_emitter.write("};\n");

    // Get the output and dupe it to owned memory
    const output = code_emitter.getOutput();
    const result = try allocator.dupe(u8, output);

    // Free the buffer since we duped the result
    allocator.free(buffer);

    return result;
}

fn emitEventDeclForModuleFromType(
    code_emitter: *CodeEmitter,
    ctx: *EmissionContext,
    event_path: *const ast.DottedPath,
    event_type: type_registry_module.EventType,
    immediate_impl: *const ast.ImmediateImpl,
) !void {
    // Event struct header: pub const foo_event = struct {
    try code_emitter.writeIndent();
    try code_emitter.write("pub const ");
    for (event_path.segments, 0..) |segment, idx| {
        if (idx > 0) try code_emitter.write("_");
        try writeMangledSeg(code_emitter, segment);
    }
    try code_emitter.write("_event = struct {\n");
    code_emitter.indent_level += 1;

    // Input struct
    try code_emitter.writeIndent();
    try code_emitter.write("pub const Input = struct {\n");
    code_emitter.indent_level += 1;
    if (event_type.input_shape) |shape| {
        for (shape.fields) |field| {
            try code_emitter.writeIndent();
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(": ");
            try writeFieldType(code_emitter, field, ctx.main_module_name);
            try code_emitter.write(",\n");
        }
    }
    code_emitter.indent_level -= 1;
    try code_emitter.writeIndent();
    try code_emitter.write("};\n");

    // Output union (bare `-> T` return takes the value type directly)
    try code_emitter.writeIndent();
    if (event_type.return_type) |rt| {
        try code_emitter.write("pub const Output = ");
        try code_emitter.write(rt);
        try code_emitter.write(";\n");
    } else if (event_type.branches.len == 0) {
        try code_emitter.write("pub const Output = void;\n");
    } else {
        try code_emitter.write("pub const Output = union(enum) {\n");
        code_emitter.indent_level += 1;
        for (event_type.branches) |branch| {
            try code_emitter.writeIndent();
            try writeBranchName(code_emitter, branch.name);

            if (branch.payload) |payload| {
                if (payload.fields.len == 1 and std.mem.eql(u8, payload.fields[0].name, "__type_ref")) {
                    try code_emitter.write(": ");
                    try writeFieldType(code_emitter, payload.fields[0], ctx.main_module_name);
                    try code_emitter.write(",\n");
                } else {
                    try code_emitter.write(": struct {\n");
                    code_emitter.indent_level += 1;
                    for (payload.fields) |field| {
                        try code_emitter.writeIndent();
                        try writeBranchName(code_emitter, field.name);
                        try code_emitter.write(": ");
                        try writeFieldType(code_emitter, field, ctx.main_module_name);
                        try code_emitter.write(",\n");
                    }
                    code_emitter.indent_level -= 1;
                    try code_emitter.writeIndent();
                    try code_emitter.write("},\n");
                }
            } else {
                try code_emitter.write(": struct {},\n");
            }
        }
        code_emitter.indent_level -= 1;
        try code_emitter.writeIndent();
        try code_emitter.write("};\n");
    }

    // Handler function
    try code_emitter.writeIndent();
    try code_emitter.write("pub fn handler(__koru_event_input: Input) Output {\n");
    code_emitter.indent_level += 1;

    if (event_type.input_shape) |shape| {
        for (shape.fields) |field| {
            try code_emitter.writeIndent();
            try code_emitter.write("const ");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(" = __koru_event_input.");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(";\n");
        }
        for (shape.fields) |field| {
            try code_emitter.writeIndent();
            try code_emitter.write("_ = &");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(";\n");
        }
    }
    try code_emitter.writeIndent();
    try code_emitter.write("_ = &__koru_event_input;\n");

    // ImmediateImpl always has a value (BranchConstructor) - emit it directly
    {
        try code_emitter.writeIndent();
        try code_emitter.write("return ");
        try emitBranchConstructorWithEventType(code_emitter, ctx, &immediate_impl.value, event_type);
        try code_emitter.write(";\n");
    }

    code_emitter.indent_level -= 1;
    try code_emitter.writeIndent();
    try code_emitter.write("}\n");

    code_emitter.indent_level -= 1;
    try code_emitter.writeIndent();
    try code_emitter.write("};\n\n");
}

// ═══════════════════════════════════════════════════════════════════════
// Tail self-continuation loop lowering
// ═══════════════════════════════════════════════════════════════════════
// A flow that implements event E and re-enters E in tail position while
// forwarding the result unchanged is semantically a loop. Lowering it as a
// self-call reconstructs a by-value `Input` literal every iteration, which on
// ARM64 passes the >16-byte aggregate through memory and blocks LLVM's
// tail-call optimization (measured: ~2.6x slower than Rust on the register
// machine). Lowering it as a `while (true)` loop over `var` input bindings
// removes the aggregate materialization entirely and lets the terminal branch
// `return` fall out of the loop. See brief `glm_tail_loop_brief.md` §3.
//
// Detection is conservative and lives in two places that MUST agree:
//   * `flowContainsSelfTailForward` — decides whether to set up the loop
//     (var bindings + `while (true)` wrapper) in `emitEventDeclForModule`.
//   * `continuationIsSelfTailForwarder` — decides at the call site whether to
//     emit reassign+`continue` instead of the self-call. Both use the same
//     `identityForwardsResult` predicate, so a miss degrades to the original
//     call (correct, just unoptimized) rather than a miscompile.

/// True if a branch_constructor continuation forwards its bound payload to the
/// same branch unchanged. Covers `| B v => B v` (plain_value == binding) and the
/// field-wise identity `| B v => B { x: v.x, y: v.y }`. A transform or a
/// payload-mutating arm is NOT a forwarder and disqualifies the loop lowering.
fn identityForwardsResult(cont: *const ast.Continuation) bool {
    if (cont.node == null) return false;
    if (cont.node.? != .branch_constructor) return false;
    const bc = cont.node.?.branch_constructor;
    if (!std.mem.eql(u8, bc.branch_name, cont.branch)) return false;
    const binding = cont.binding orelse return false;

    // `| B v => B v` — single plain value passthrough.
    if (bc.plain_value) |pv| {
        const trimmed = std.mem.trim(u8, pv, " \t");
        return std.mem.eql(u8, trimmed, binding);
    }

    // `| B v => B { x: v.x, y: v.y, ... }` — field-wise identity. Every field
    // must read `<binding>.<field_name>` (no transforms, no reordering).
    if (bc.fields.len == 0) return false;
    for (bc.fields) |field| {
        const expr = field.expression_str orelse return false;
        const trimmed = std.mem.trim(u8, expr, " \t");
        var buf: [128]u8 = undefined;
        const expected = std.fmt.bufPrint(&buf, "{s}.{s}", .{ binding, field.name }) catch return false;
        if (!std.mem.eql(u8, trimmed, expected)) return false;
    }
    return true;
}

/// True if `cont` is a tail self-continuation of `event_canonical`: its node is
/// an invocation of that event, and every child continuation forwards the
/// result branch unchanged (so the self-call's result IS this invocation's
/// result — the precondition for a sound loop rewrite).
fn continuationIsSelfTailForwarder(
    cont: *const ast.Continuation,
    event_canonical: []const u8,
    ctx: *EmissionContext,
) bool {
    if (cont.node == null) return false;
    if (cont.node.? != .invocation) return false;
    const inv = cont.node.?.invocation;
    const inv_canonical = buildCanonicalEventName(&inv.path, ctx.allocator, ctx.main_module_name) catch return false;
    defer ctx.allocator.free(inv_canonical);
    if (!std.mem.eql(u8, inv_canonical, event_canonical)) return false;
    if (cont.continuations.len == 0) return false;
    for (cont.continuations) |*child| {
        if (!identityForwardsResult(child)) return false;
    }
    return true;
}

/// Recursive walker: does any tail position in this continuation tree contain a
/// self-tail-forwarder of `event_canonical`? Used at setup time to decide
/// whether to wrap the handler body in a loop.
pub fn flowContainsSelfTailForward(
    conts: []const ast.Continuation,
    event_canonical: []const u8,
    ctx: *EmissionContext,
) bool {
    for (conts) |*cont| {
        if (continuationIsSelfTailForwarder(cont, event_canonical, ctx)) return true;
        if (cont.continuations.len > 0) {
            if (flowContainsSelfTailForward(cont.continuations, event_canonical, ctx)) return true;
        }
    }
    return false;
}

/// Emit the reassign+continue that replaces a tail self-call site. Each input
/// field is reassigned from the corresponding invocation arg (pass-through args
/// where `value == name` are skipped — they're already correct and emitting
/// `x = x` would just copy the array for nothing). Then `continue :label`
/// re-enters the loop top.
fn emitSelfTailReentry(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
) !void {
    const inv = cont.node.?.invocation;
    for (inv.args) |arg| {
        const trimmed = std.mem.trim(u8, arg.value, " \t");
        // Skip no-op pass-throughs (`ops: ops` → `ops = ops`). Avoids a
        // pointless array copy and keeps the emitted loop clean.
        if (std.mem.eql(u8, trimmed, arg.name)) continue;
        try emitter.writeIndent();
        try writeBranchName(emitter, arg.name);
        try emitter.write(" = ");
        try emitValue(emitter, ctx, arg.value);
        try emitter.write(";\n");
    }
    try emitter.writeIndent();
    try emitter.write("continue :");
    try emitter.write(ctx.self_loop_label);
    try emitter.write(";\n");
}

/// Emit a single event declaration for a module subset
fn emitEventDeclForModule(
    code_emitter: *CodeEmitter,
    ctx: *EmissionContext,
    event: *const ast.EventDecl,
    all_items: []const ast.Item,
) !void {
    // Event struct header: pub const foo_event = struct {
    try code_emitter.writeIndent();
    try code_emitter.write("pub const ");
    for (event.path.segments, 0..) |segment, idx| {
        if (idx > 0) try code_emitter.write("_");
        try writeMangledSeg(code_emitter, segment);
    }
    try code_emitter.write("_event = struct {\n");
    code_emitter.indent_level += 1;

    // Input struct
    try code_emitter.writeIndent();
    try code_emitter.write("pub const Input = struct {\n");
    code_emitter.indent_level += 1;
    for (event.input.fields) |field| {
        try code_emitter.writeIndent();
        try writeBranchName(code_emitter, field.name);
        try code_emitter.write(": ");
        try writeFieldType(code_emitter, field, ctx.main_module_name);
        try code_emitter.write(",\n");
    }
    code_emitter.indent_level -= 1;
    try code_emitter.writeIndent();
    try code_emitter.write("};\n");

    // Partition branches by kind: terminal `|` become Output union variants,
    // effect `!` become comptime handler-struct functions (effect operations).
    var terminal_count: usize = 0;
    var has_effect: bool = false;
    for (event.branches) |b| {
        if (b.kind == .effect) {
            has_effect = true;
        } else {
            terminal_count += 1;
        }
    }

    // Output union — terminal branches only (bare `-> T` handled centrally)
    try code_emitter.writeIndent();
    if (try emitBareReturnOutput(code_emitter, event)) {
        // bare-return Output emitted centrally
    } else if (terminal_count == 0) {
        try code_emitter.write("pub const Output = void;\n");
    } else {
        try code_emitter.write("pub const Output = union(enum) {\n");
        code_emitter.indent_level += 1;
        for (event.branches) |branch| {
            if (branch.kind == .effect) continue;
            try code_emitter.writeIndent();
            try writeBranchName(code_emitter, branch.name);

            if (branch.payload.fields.len == 1 and std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref")) {
                try code_emitter.write(": ");
                try writeFieldType(code_emitter, branch.payload.fields[0], ctx.main_module_name);
                try code_emitter.write(",\n");
            } else {
                try code_emitter.write(": struct {\n");
                code_emitter.indent_level += 1;
                for (branch.payload.fields) |field| {
                    try code_emitter.writeIndent();
                    try writeBranchName(code_emitter, field.name);
                    try code_emitter.write(": ");
                    try writeFieldType(code_emitter, field, ctx.main_module_name);
                    try code_emitter.write(",\n");
                }
                code_emitter.indent_level -= 1;
                try code_emitter.writeIndent();
                try code_emitter.write("},\n");
            }
        }
        code_emitter.indent_level -= 1;
        try code_emitter.writeIndent();
        try code_emitter.write("};\n");
    }

    // Handler function — takes `comptime __H: type` when the event yields.
    try code_emitter.writeIndent();
    if (has_effect) {
        try code_emitter.write("pub fn handler(__koru_event_input: Input, comptime __H: type) Output {\n");
    } else {
        try code_emitter.write("pub fn handler(__koru_event_input: Input) Output {\n");
    }
    code_emitter.indent_level += 1;

    // Tail self-continuation detection: if this event's flow impl re-enters
    // its own event in tail position and forwards the result unchanged, lower
    // the handler as a `while (true)` loop over `var` input bindings instead of
    // a stack-growing self-call (see `glm_tail_loop_brief.md`). The canonical
    // name is reused as the self-call target to compare against at the emit
    // site, so the setup-time and emit-time predicates share one source of
    // truth.
    const self_loop_canonical = buildCanonicalEventName(&event.path, ctx.allocator, ctx.main_module_name) catch null;
    defer if (self_loop_canonical) |c| ctx.allocator.free(c);
    var is_self_loop: bool = false;
    if (self_loop_canonical) |canonical| {
        if (findImplByPath(all_items, &event.path)) |found| {
            switch (found) {
                .flow => |flow| {
                    is_self_loop = flowContainsSelfTailForward(flow.body.continuations, canonical, ctx);
                },
                else => {},
            }
        }
    }

    // Emit input field bindings
    for (event.input.fields) |field| {
        try code_emitter.writeIndent();
        // Self-loop handlers reassign these from the tail self-call's args, so
        // they must be `var`. Every other handler treats them as immutable.
        try code_emitter.write(if (is_self_loop) "var " else "const ");
        try writeBranchName(code_emitter, field.name);
        try code_emitter.write(" = __koru_event_input.");
        try writeBranchName(code_emitter, field.name);
        try code_emitter.write(";\n");
    }

    // Yielding-branch aliases — `const X = __H.X;` so the body can call X(...)
    // directly without qualifying through __H. Zero runtime cost (comptime).
    if (has_effect) {
        for (event.branches) |b| {
            if (b.kind != .effect) continue;
            try code_emitter.writeIndent();
            try code_emitter.write("const ");
            try writeBranchName(code_emitter, b.name);
            try code_emitter.write(" = __H.");
            try writeBranchName(code_emitter, b.name);
            try code_emitter.write(";\n");
            try code_emitter.writeIndent();
            try code_emitter.write("_ = &");
            try writeBranchName(code_emitter, b.name);
            try code_emitter.write(";\n");
        }
    }

    // Suppress unused variable warnings
    for (event.input.fields) |field| {
        try code_emitter.writeIndent();
        try code_emitter.write("_ = &");
        try writeBranchName(code_emitter, field.name);
        try code_emitter.write(";\n");
    }
    try code_emitter.writeIndent();
    try code_emitter.write("_ = &__koru_event_input;\n");

    // Find and emit implementation (ImmediateImpl, Flow with impl_of, or proc_decl)
    // Use findImplByPath which correctly handles module_qualifier differences
    var found_impl = false;

    // First check for impl items (immediate mock or flow body)
    if (findImplByPath(all_items, &event.path)) |found| {
        switch (found) {
            .immediate_impl => |ii| {
                const bc = &ii.value;
                // Mock with immediate value - emit return statement
                if (log.level == .debug) {
                    log.debug("[DEBUG emitEventDeclForModule] Found immediate mock for event, branch={s}, fields.len={d}\n", .{ bc.branch_name, bc.fields.len });
                    for (bc.fields, 0..) |field, i| {
                        log.debug("[DEBUG emitEventDeclForModule]   field[{d}]: name={s}, expr_str={s}\n", .{ i, field.name, if (field.expression_str) |e| e else "(null)" });
                    }
                }
                try code_emitter.writeIndent();
                try code_emitter.write("return ");
                try emitBranchConstructorWithEvent(code_emitter, ctx, bc, event);
                try code_emitter.write(";\n");
            },
            .flow => |flow| {
                // Full flow impl - emit the flow body. For a tail
                // self-continuation, wrap it in a labeled `while (true)` and
                // arm the per-site reentry emission (see `emitSelfTailReentry`).
                // The loop only exits via the terminal branch's `return`; the
                // `unreachable` after it tells Zig the function can't fall off
                // the end, matching how `#label` loops terminate.
                if (is_self_loop) {
                    if (self_loop_canonical) |canonical| {
                        try code_emitter.writeIndent();
                        try code_emitter.write(ctx.self_loop_label);
                        try code_emitter.write(": while (true) {\n");
                        code_emitter.indent_level += 1;
                        const saved_active = ctx.self_loop_active;
                        const saved_canonical = ctx.self_loop_event_canonical;
                        ctx.self_loop_active = true;
                        ctx.self_loop_event_canonical = canonical;
                        defer {
                            ctx.self_loop_active = saved_active;
                            ctx.self_loop_event_canonical = saved_canonical;
                        }
                        try emitFlow(code_emitter, ctx, flow);
                        code_emitter.indent_level -= 1;
                        try code_emitter.writeIndent();
                        try code_emitter.write("}\n");
                        try code_emitter.writeIndent();
                        try code_emitter.write("unreachable;\n");
                    } else {
                        try emitFlow(code_emitter, ctx, flow);
                    }
                } else {
                    try emitFlow(code_emitter, ctx, flow);
                }
            },
        }
        found_impl = true;
    }

    // Then check for proc_decl (Zig inline implementation)
    if (!found_impl) {
        if (findProcDeclByPath(all_items, &event.path)) |proc| {
            if (proc.body.text.len > 0) {
                try code_emitter.writeIndent();
                try code_emitter.write(proc.body.text);
                try code_emitter.write("\n");
            }
            found_impl = true;
        }
    }

    // If no implementation found, emit a placeholder return
    if (!found_impl) {
        if (log.level == .debug) {
            log.debug("[DEBUG emitEventDeclForModule] No impl found for event path: ", .{});
            for (event.path.segments) |seg| {
                log.debug("{s}.", .{seg});
            }
            log.debug("\n", .{});
        }
        try code_emitter.writeIndent();
        if (event.branches.len > 0) {
            // Return first branch with undefined values for all fields
            const first_branch = &event.branches[0];
            const is_identity = first_branch.payload.fields.len == 1 and
                std.mem.eql(u8, first_branch.payload.fields[0].name, "__type_ref");
            try code_emitter.write("return .{ .");
            try writeBranchName(code_emitter, first_branch.name);
            if (is_identity) {
                // Identity branch: emit value directly (no struct wrapper)
                try code_emitter.write(" = undefined };\n");
            } else {
                try code_emitter.write(" = .{");
                for (first_branch.payload.fields, 0..) |field, i| {
                    if (i > 0) {
                        try code_emitter.write(",");
                    }
                    try code_emitter.write(" .");
                    try writeBranchName(code_emitter, field.name);
                    try code_emitter.write(" = undefined");
                }
                if (first_branch.payload.fields.len > 0) {
                    try code_emitter.write(",");
                }
                try code_emitter.write("} };\n");
            }
        } else {
            try code_emitter.write("return;\n");
        }
    }

    code_emitter.indent_level -= 1;
    try code_emitter.writeIndent();
    try code_emitter.write("}\n");

    // Variant handlers: emit pub fn handler__<variant>(...) for each ~proc <event>|<variant>.
    // Both bodies coexist in the binary; call sites dispatch via writeHandlerName which
    // mangles to handler__<variant> when invocation.variant is set or getVariant() returns
    // a registered default. Dead-code elimination drops unused variant bodies.
    const variant_procs = try findVariantProcsByPath(ctx.allocator, all_items, &event.path);
    defer ctx.allocator.free(variant_procs);
    for (variant_procs) |variant_proc| {
        const variant_name = variant_proc.target orelse continue;
        const mangled = try mangleVariant(ctx.allocator, variant_name);
        defer ctx.allocator.free(mangled);

        try code_emitter.writeIndent();
        try code_emitter.write("pub fn handler__");
        try code_emitter.write(mangled);
        try code_emitter.write("(__koru_event_input: Input) Output {\n");
        code_emitter.indent_level += 1;

        for (event.input.fields) |field| {
            try code_emitter.writeIndent();
            try code_emitter.write("const ");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(" = __koru_event_input.");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(";\n");
        }
        for (event.input.fields) |field| {
            try code_emitter.writeIndent();
            try code_emitter.write("_ = &");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(";\n");
        }
        try code_emitter.writeIndent();
        try code_emitter.write("_ = &__koru_event_input;\n");

        if (variant_proc.body.text.len > 0) {
            try code_emitter.writeIndent();
            try code_emitter.write(variant_proc.body.text);
            try code_emitter.write("\n");
        }

        code_emitter.indent_level -= 1;
        try code_emitter.writeIndent();
        try code_emitter.write("}\n");
    }

    // Close event struct
    code_emitter.indent_level -= 1;
    try code_emitter.writeIndent();
    try code_emitter.write("};\n");
}

/// Compare two DottedPaths for equality
fn pathsEqual(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
    // Compare module qualifiers
    if (a.module_qualifier != null and b.module_qualifier != null) {
        if (!std.mem.eql(u8, a.module_qualifier.?, b.module_qualifier.?)) return false;
    } else if (a.module_qualifier != null or b.module_qualifier != null) {
        return false;
    }

    // Compare segments
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |seg_a, seg_b| {
        if (!std.mem.eql(u8, seg_a, seg_b)) return false;
    }
    return true;
}
