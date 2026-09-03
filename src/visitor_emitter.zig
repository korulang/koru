const std = @import("std");
const log = @import("log");
const ast = @import("ast");
const emitter = @import("emitter_helpers");
const visitor_mod = @import("ast_visitor");
const tap_registry_module = @import("tap_registry");
const type_registry_module = @import("type_registry");
const annotation_parser = @import("annotation_parser");
const codegen_utils = @import("codegen_utils");
const file_types = @import("file_types");
const comptime_eval = @import("comptime_eval");

/// Variant-tag string this emitter targets — same namespace as `--lang`,
/// `proc.target`, and `file_types.hostLangOfFile`. Selects both `|zig` proc
/// bodies and `.kz` host lines.
const ZIG_TARGET = "zig";

/// Should this host_line be emitted into Zig output?
/// - Known non-zig host (`.kjs`, `.kc`, `.kgpu`) → false: their bytes are not
///   Zig and would produce invalid output (the bug 140_010 pins).
/// - `null` (synthesized `location.file == "generated"`, or pure `.k`
///   contract) → true: host-agnostic compiler infrastructure must still emit.
/// - `"zig"` → true.
/// The const name for a default-handler flow's ROOT invocation result: the
/// call-site `: bind` when present (bare-return chain heads reference it),
/// `result` otherwise (the branch-switch convention). A `_` bind is a
/// discard — `const _` is not legal Zig, so it keeps `result` and rides the
/// no-continuations discard guard.
fn defaultHandlerRootBind(inv: *const ast.Invocation) []const u8 {
    const rb = inv.return_binding orelse return "result";
    if (std.mem.eql(u8, rb, "_")) return "result";
    return rb;
}

/// A named label on a bare-return head is binding sugar for `: r`. The shape
/// checker already treats it that way — it skips tag rules for a bare-return
/// head because there are no tags to check — and 210_195 pins the lowering at a
/// top-level flow head. Returns the label's binding when a subflow head is that
/// shape, so the caller can alias it to the head result and pass the
/// continuation on as a void one.
///
/// THREE emission sites ask this question (the plain subflow impl, and the two
/// rooted default-handler paths). None of them may answer it privately: the
/// first two only ever handled the `: r` spelling, so the label spelling fell
/// through to a switch on a value carrying no tags at all, and Zig complained
/// that an enum literal is not an i64 — naming a generated file the author has
/// never opened. A fourth site will appear; it must call this, not copy it.
fn headLabelBindOnBareReturn(flow: *const ast.Flow, all_items: []const ast.Item) ?[]const u8 {
    // The `: r` spelling is already lowered by every caller.
    if (flow.inv().return_binding != null) return null;
    if (flow.body.continuations.len != 1) return null;
    const cont = &flow.body.continuations[0];
    if (cont.branch.len == 0 or cont.is_catchall) return null;
    const bind = cont.binding orelse return null;
    const decl = emitter.findEventDeclByPath(all_items, &flow.inv().path) orelse return null;
    // Bare return means one untagged outcome: a `-> T` with no branches to name.
    if (decl.return_type == null or decl.branches.len != 0) return null;
    return bind;
}

/// The continuation, restated as the void one the emitters already handle: the
/// label and its binding have been lifted onto the head, so what is left is
/// "and then run this".
fn voidifyHeadLabel(allocator: std.mem.Allocator, continuations: []const ast.Continuation) ![]ast.Continuation {
    const patched = try allocator.alloc(ast.Continuation, 1);
    patched[0] = continuations[0];
    patched[0].branch = "";
    patched[0].binding = null;
    return patched;
}

fn hostLineRoutesToZig(file: []const u8) bool {
    const host = file_types.hostLangOfFile(file) orelse return true;
    return std.mem.eql(u8, host, ZIG_TARGET);
}

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

const zigCodeMask = codegen_utils.zigCodeMask;

/// Net brace depth delta of a chunk of host code, counting only braces that
/// are code (not inside literals or comments).
fn braceDepthDelta(allocator: std.mem.Allocator, text: []const u8) !isize {
    const mask = try zigCodeMask(allocator, text);
    defer allocator.free(mask);
    var delta: isize = 0;
    for (text, mask) |c, in_code| {
        if (!in_code) continue;
        if (c == '{') delta += 1;
        if (c == '}') delta -= 1;
    }
    return delta;
}

/// Collect all module-level declared names from items in the same scope.
/// These are names that would cause Zig shadowing errors if used as local
/// bindings. Only depth-0 declarations count: a `const` local inside a host
/// `fn` body is invisible where the handler runs, and treating it as a
/// collision routes the proc body through textual rewriting for a shadow that
/// does not exist (230_016).
fn collectDeclaredNames(items: []const ast.Item, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var depth: isize = 0;
    for (items) |item| {
        switch (item) {
            .host_line => |hl| {
                if (depth == 0) {
                    if (extractDeclaredName(hl.content)) |name| {
                        try names.append(allocator, name);
                    }
                }
                depth += try braceDepthDelta(allocator, hl.content);
            },
            .inline_code => |ic| {
                if (depth == 0) {
                    if (extractDeclaredName(ic.code)) |name| {
                        try names.append(allocator, name);
                    }
                }
                depth += try braceDepthDelta(allocator, ic.code);
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

const replaceIdentifier = codegen_utils.replaceIdentifier;

/// Strip phantom type annotations from a type string
/// e.g., "*Resource<state!>" -> "*Resource", "[]const u8" -> "[]const u8"
fn stripPhantom(type_str: []const u8) []const u8 {
    if (type_str.len > 0 and type_str[type_str.len - 1] == '>') {
        var angle_depth: i32 = 0;
        var i = type_str.len - 1;
        while (i > 0) : (i -= 1) {
            if (type_str[i] == '>') {
                angle_depth += 1;
            } else if (type_str[i] == '<') {
                angle_depth -= 1;
                if (angle_depth == 0) {
                    if (i > 0) {
                        return type_str[0..i];
                    }
                    break;
                }
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
        } else if (c == '-') {
            // Kebab `-` → `_`: `-` is a legal Koru name-char but not a Zig
            // identifier char (D2: snake for the Zig target). No-op for the
            // entire snake corpus, so this cannot affect existing tests.
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
    module_runtime_flows: std.ArrayList([]const u8),  // Collected runtime flow calls from library modules
    koru_start_flow_name: ?[]const u8,  // Name of koru:start meta-event flow (if present)
    koru_end_flow_name: ?[]const u8,    // Name of koru:end meta-event flow (if present)
    /// Default variant for proc-body emission. When no explicit build:variants
    /// registration exists for an event, the proc whose `target` matches this
    /// string is the one emitted. Default `"zig"` so existing call sites in
    /// koru_std (user-space compiler code that constructs a VisitorEmitter
    /// without setting this field) keep their current behavior. Koruc's own
    /// callers assign `visitor_emitter.lang = config.lang` after init.
    /// Variant-tag namespace ("zig", "js", "gpu", ...).
    lang: []const u8 = "zig",
    /// True for `koruc lib`: emit C-ABI `export fn` wrappers for the entry
    /// module's `pub` events, so the object is callable from C and from any
    /// language that speaks it. Assigned after init, like `lang`.
    library: bool = false,

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
            .module_runtime_flows = .empty,
            .koru_start_flow_name = null,  // Will be set if koru:start flow is emitted
            .koru_end_flow_name = null,    // Will be set if koru:end flow is emitted
            // `.lang` intentionally omitted — uses the struct default `"zig"`.
            // Koruc's own callers assign `lang = config.lang` after init.
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
                    // Comptime-only is EXPLICIT: `[comptime]`/`[norun]`, or a
                    // `Program`-typed param (the metacircular compiler AST).
                    // `Expression`/`Source` params do NOT imply comptime — they
                    // are just captured strings and can lower to runtime code
                    // (e.g. `~if`/`~for` templates).
                    var has_comptime_params = annotation_parser.hasPart(event.annotations, "comptime") or
                        annotation_parser.hasPart(event.annotations, "norun");
                    if (!has_comptime_params) {
                        for (event.input.fields) |field| {
                            if (std.mem.indexOf(u8, field.type, "Program") != null) {
                                has_comptime_params = true;
                                break;
                            }
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
    fn scanForMetatypes(items: []const ast.Item, allocator: std.mem.Allocator, main_module_name: ?[]const u8) !MetatypeScanResult {
        var result = MetatypeScanResult.init(allocator);
        for (items) |item| {
            switch (item) {
                .flow => |flow| {
                    // The continuations dispatch on the flow HEAD's event — it
                    // is the source a metatype catch-all references.
                    var found = try scanContinuationsForMetatypes(flow.body.continuations, allocator, items, main_module_name, &flow.inv().path);
                    defer found.deinit();
                    try result.merge(&found);
                },
                .module_decl => |mod| {
                    var nested = try scanForMetatypes(mod.items, allocator, main_module_name);
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

    fn scanContinuationsForMetatypes(
        conts: []const ast.Continuation,
        allocator: std.mem.Allocator,
        items: []const ast.Item,
        main_module_name: ?[]const u8,
        /// The event whose arms these continuations dispatch on — the source a
        /// metatype catch-all constructor references; null when the level has
        /// no invocation (a synthesized preamble chain).
        source_path: ?*const ast.DottedPath,
    ) !MetatypeScanResult {
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
            // Check for catch-all metatype (|? Audit e |>, |? Profile p |>, etc.)
            if (cont.is_catchall) {
                if (cont.catchall_metatype) |metatype| {
                    if (std.mem.eql(u8, metatype, "Profile")) {
                        result.profile = true;
                    } else if (std.mem.eql(u8, metatype, "Transition")) {
                        result.transition = true;
                        // The catch-all's constructor references enum literals
                        // for BOTH the source event and each OPTIONAL branch it
                        // fires on (210_017) — the EventEnum/BranchEnum must
                        // contain them or `taps.Transition` cannot compile.
                        if (source_path) |sp| {
                            const canonical = emitter.buildCanonicalEventName(sp, allocator, main_module_name) catch null;
                            if (canonical) |c| {
                                defer allocator.free(c);
                                // addEvent BORROWS (the metatype_binding callers
                                // pass AST-owned names) — dupe the temporary.
                                const owned = try allocator.dupe(u8, c);
                                try result.addEvent(owned);
                            }
                            if (emitter.findEventDeclByPath(items, sp)) |ed| {
                                for (ed.branches) |b| {
                                    if (b.is_optional) try result.addBranch(b.name);
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, metatype, "Audit")) {
                        result.audit = true;
                    }
                }
            }
            // Recurse into nested continuations; a nested invocation becomes
            // the new dispatch source for its children.
            if (cont.continuations.len > 0) {
                const child_source = if (cont.node) |n|
                    (if (n == .invocation) &n.invocation.path else source_path)
                else
                    source_path;
                var found = try scanContinuationsForMetatypes(cont.continuations, allocator, items, main_module_name, child_source);
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
                    log.debug("       Flow invokes: {s}\n", .{item.flow.inv().path.segments[0]});
                }
                if (item == .parse_error) {
                    log.debug("       PARSE ERROR MESSAGE: {s}\n", .{item.parse_error.message});
                    log.debug("       Raw text: {s}\n", .{item.parse_error.raw_text});
                }
            }
        }

        // Store main_module_name for use in tap canonical event naming
        self.main_module_name = source_file.main_module_name;

        // Build the type→module registry over this program's host declarations
        // and publish it for writeFieldType's base-type home resolution. Built
        // from all_items (the final, post-transform item list) so synthesized
        // declarations like std/store's entity alias are visible.
        const homes_ptr = try self.allocator.create(type_registry_module.HostTypeHomes);
        homes_ptr.* = try type_registry_module.buildHostTypeHomes(self.allocator, self.all_items);
        emitter.host_type_homes = homes_ptr;
        // The foreign-claimed name set over the same post-transform items —
        // the linkage gate for writeFieldType's host-home routing. Keys are
        // owned dupes (unlike homes' AST slices), so teardown frees them.
        const foreign_ptr = try self.allocator.create(type_registry_module.ForeignNames);
        foreign_ptr.* = try type_registry_module.buildForeignNames(self.allocator, self.all_items);
        emitter.foreign_names = foreign_ptr;
        defer {
            emitter.host_type_homes = null;
            homes_ptr.deinit();
            self.allocator.destroy(homes_ptr);
            emitter.foreign_names = null;
            var fiter = foreign_ptr.keyIterator();
            while (fiter.next()) |key| self.allocator.free(key.*);
            foreign_ptr.deinit();
            self.allocator.destroy(foreign_ptr);
        }

        // PRE-SCAN: Determine if we're emitting ANY items from main module
        // This determines whether main module host_lines should be emitted
        self.emitting_from_main = self.scanEmittingFromMain(source_file);
        log.debug("Emitting from main module: {}\n", .{self.emitting_from_main});

        var modules = try std.ArrayList(*const ast.ModuleDecl).initCapacity(self.allocator, 0);
        defer modules.deinit(self.allocator);

        // Collect ALL modules recursively (including nested ones from imports)
        // This is important because nested modules like std.control need to be checked too
        try self.collectModulesRecursively(source_file.items, &modules);

        // Emit main_module struct start. CompilerEnv is pub only for the
        // comptime_only emission (backend_output_emitted.zig) so phantom_semantic_checker
        // and friends can see it via @hasDecl(root, ...) when they're compiled
        // as part of that addObject. See emitMainModuleStart docstring.
        try emitter.emitMainModuleStart(self.code_emitter, self.emit_mode == .comptime_only);
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
        var ast_metatypes = try scanForMetatypes(self.all_items, self.allocator, self.main_module_name);
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

        // A LIBRARY's door: one C-ABI `export fn` per entry-module `pub` event.
        // Keeping the symbol (the root rule) and being able to CALL it are two
        // different problems; this is the second, and the Zig side of what the
        // JS emitter does with named exports.
        if (self.library) try self.emitCAbiExports(source_file.items);

        // ========================================================================
        // MODULE-LEVEL INFRASTRUCTURE (taps namespace with metatypes)
        // ========================================================================
        // Taps are compiler infrastructure, not user code, so they live at module level
        // This must come AFTER Phase 1 (where getMatchingTaps populates the registry)
        // and AFTER main_module (so we can reference events/branches)

        // Emit top-level std import for meta-event taps (Profile uses std.time.nanoTimestamp)
        // We use __koru_std to avoid shadowing std imports in modules
        // In comptime mode, the backend preamble already defines __koru_std, so skip
        if ((has_profiling_transition or has_audit_transition) and self.emit_mode != .comptime_only) {
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
                        // Interpreter-owned flows (foldable, walkable, or
                        // walker-entered subflow definitions) were never
                        // emitted as comptime_flowN (see visitItem) — skip
                        // their calls too, or the numbering desyncs.
                        if (comptime_eval.flowIsInterpreterOwned(self.all_items, &flow)) {
                            continue;
                        }
                        // Check if this flow invokes a [norun] or [transform] event
                        const event_decl = self.findEventDeclInItems(self.all_items, &flow.inv().path);
                        var flow_returns_program = false;
                        if (event_decl) |decl| {
                            const is_norun = annotation_parser.hasPart(decl.annotations, "norun");
                            if (is_norun) {
                                // Only allow [comptime|norun] events that have proc handlers.
                                // Data-storage events (template:define, build:command.sh) have no proc.
                                const is_comptime_event = annotation_parser.hasPart(decl.annotations, "comptime");
                                const has_proc = self.eventHasProcHandler(&flow.inv().path);
                                if (!(is_comptime_event and has_proc)) {
                                    continue;
                                }
                                // [comptime|norun] with proc: allow — should be called from comptime_main
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

            // THE THUNK LAW table: every [comptime] event with a compiled
            // proc handler becomes callable from the Stage C interpreter.
            try self.emitComptimeThunkTable();
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
                        for (flow.inv().annotations) |ann| {
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
                        const is_meta_event = flow.inv().path.module_qualifier != null and
                            std.mem.eql(u8, flow.inv().path.module_qualifier.?, "koru") and
                            flow.inv().path.segments.len == 1 and
                            (std.mem.eql(u8, flow.inv().path.segments[0], "start") or
                             std.mem.eql(u8, flow.inv().path.segments[0], "end"));

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

                            // `[declaration]` flows (e.g. `const`) emit container-scope
                            // decls, not a callable flow function — no main() call, and
                            // no `i++` so flow numbering stays in sync with phase 1.
                            if (self.findEventDeclInItems(self.all_items, &flow.inv().path)) |decl| {
                                if (annotation_parser.hasPart(decl.annotations, "declaration")) continue;
                            }

                            // CRITICAL: Check if transform already ran (look for @pass_ran annotation)
                            var has_pass_ran = false;
                            for (flow.inv().annotations) |ann| {
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
                            const is_meta_event = flow.inv().path.module_qualifier != null and
                                std.mem.eql(u8, flow.inv().path.module_qualifier.?, "koru") and
                                flow.inv().path.segments.len == 1 and
                                (std.mem.eql(u8, flow.inv().path.segments[0], "start") or
                                 std.mem.eql(u8, flow.inv().path.segments[0], "end"));

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

                // Call runtime flows from library modules
                for (self.module_runtime_flows.items) |call| {
                    try self.code_emitter.write("    ");
                    try self.code_emitter.write(call);
                    try self.code_emitter.write("();\n");
                }

                // Call koru:end meta-event flow if it exists (fires profiler footer, etc.)
                if (self.koru_end_flow_name) |_| {
                    try self.code_emitter.write("    main_module.koru_end_flow();\n");
                }
            }

            // META-EVENT: koru:end taps now in AST via tap_transformer

            // LEAK CHECK: __koru_leak_count (the allocator spine's outstanding-
            // allocation counter — see emitMainModuleStart) must be zero at
            // exit; a leaking produced program exits 1 so the harness fails
            // the test. Zero leaks is an absolute invariant — no exemptions.
            //
            // HOW it reports is a fact about the target, not about the check,
            // and WHERE it lives is a fact about the entry point. Both now sit
            // in `koru_leak_check` (emitMainModuleStart), because a program
            // without a `main` — a unikernel calling the flows from its own
            // entry — had this check emitted and never executed. `main` is one
            // caller of it, not its home. The limitation it can and cannot
            // report is documented at that definition; read it there before
            // trusting a green run on a target with no debugger.
            try self.code_emitter.write("    koru_leak_check();\n");

            // Close regular main()
            try emitter.emitMainFunctionEnd(self.code_emitter);

            // Test discovery block - enables zig test to find tests nested in main_module
            try self.code_emitter.write("\ntest {\n    @import(\"std\").testing.refAllDeclsRecursive(@This());\n}\n");
        }
    }

    fn visitItem(self: *VisitorEmitter, item: *const ast.Item, module_annotations: []const []const u8, items_to_search: []const ast.Item) !void {
        switch (item.*) {
            .event_decl => |*event| {
                // Compiler infrastructure and phase annotations apply to all events,
                // including those with comptime parameters (ProgramAST, Source, etc.)
                if (shouldFilter(event.annotations, module_annotations, event.module, self.emit_mode)) {
                    return;
                }

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

                // Events with comptime params are implicitly comptime
                if (has_comptime_params and self.emit_mode == .runtime_only) {
                    return;
                }

                try self.emitEventDecl(event, items_to_search);
            },
            .host_line => |*line| {
                // Host_lines (imports, type defs, constants) are MODULE-LEVEL dependencies
                // Emit inside the appropriate module struct (module isolation)

                // Route by host language: skip lines whose host isn't Zig (e.g. a
                // `.kjs` companion in a contract-split stem). Synthesized lines
                // (`file == "generated"`) pass through unchanged.
                if (!hostLineRoutesToZig(line.location.file)) return;

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
                    try emitter.writeBranchName(self.code_emitter, field.name);
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
                for (flow.inv().annotations) |ann| {
                    if (std.mem.startsWith(u8, ann, "@pass_ran")) {
                        has_pass_ran = true;
                        break;
                    }
                }
                const is_transformed = flow.inline_body != null or flow.preamble_code != null or has_pass_ran;
                const event_decl = self.findEventDeclInItems(self.all_items, &flow.inv().path);
                if (event_decl) |decl| {
                    const is_norun = annotation_parser.hasPart(decl.annotations, "norun");
                    if (is_norun and !is_transformed) {
                        // [norun] events should not be emitted as runtime code.
                        // BUT [comptime|norun] events WITH proc handlers need comptime emission.
                        // Events without procs (e.g. template:define) are data-storage only.
                        const is_comptime_event = annotation_parser.hasPart(decl.annotations, "comptime");
                        const has_proc = self.eventHasProcHandler(&flow.inv().path);
                        if (!(is_comptime_event and has_proc and self.emit_mode == .comptime_only)) {
                            return;
                        }
                        // Fall through to emit as comptime_flowN
                    }
                    const is_transform = annotation_parser.hasPart(decl.annotations, "transform");
                    if (is_transform and !is_transformed) {
                        // [transform] events are handled by run_pass() - NOT emitted as comptime flows
                        // The transform handler receives invocation/program/allocator from run_pass
                        // BUT if inline_body or preamble_code is set, the transform already ran and produced code!
                        return;
                    }

                    // A transform that RAN and produced NOTHING erased itself, and
                    // must emit nothing. `is_transformed` is true here on the
                    // strength of `@pass_ran` alone — that marker says the pass
                    // visited the flow, not that it left code behind — so without
                    // it this falls through and emits a runtime call to a
                    // compile-time-only handler.
                    //
                    // Only reachable from a flow inside an IMPORTED module: in the
                    // entry file an erased flow is dropped from the item list
                    // before emission, so it never arrives here. `std/vendor:
                    // bindings` is the first transform to erase itself from inside
                    // a module, which is why the shape had never been exercised —
                    // every other module-declared transform produces a body.
                    // Pinned by 115_047.
                    // RUNTIME OUTPUT ONLY. A transform can produce its result by
                    // routes other than an inline body or a preamble, and the
                    // comptime/backend output is where those results legitimately
                    // live — orisha's static router is one, and skipping it there
                    // renamed a binding in the emitted backend and broke
                    // 350_010/350_013. "Produced no body" is not "produced
                    // nothing"; it is only sufficient to say the RUNTIME must not
                    // carry a call to a compile-time handler.
                    if (is_transform and is_transformed and
                        self.emit_mode == .runtime_only and
                        flow.inline_body == null and flow.preamble_code == null)
                    {
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
                    // Interpreter-owned flows are consumed by the Stage-C
                    // fold-comptime pass: foldable flows leave runtime-
                    // effectful residue that cannot compile as a
                    // comptime_flowN body; walkable flows and walker-entered
                    // subflow DEFINITIONS would double-run if emitted (a
                    // definition called standalone by comptime_main is the
                    // infinite-countdown failure shape).
                    // MUST stay in sync with the comptime_main call loop (Phase 2).
                    if (comptime_eval.flowIsInterpreterOwned(self.all_items, &flow)) {
                        return;
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
                const is_koru_start = flow.inv().path.module_qualifier != null and
                    std.mem.eql(u8, flow.inv().path.module_qualifier.?, "koru") and
                    flow.inv().path.segments.len == 1 and
                    std.mem.eql(u8, flow.inv().path.segments[0], "start");

                const is_koru_end = flow.inv().path.module_qualifier != null and
                    std.mem.eql(u8, flow.inv().path.module_qualifier.?, "koru") and
                    flow.inv().path.segments.len == 1 and
                    std.mem.eql(u8, flow.inv().path.segments[0], "end");

                // Detect if this comptime event returns a program (for comptime program return)
                var comptime_returns_program = false;
                var comptime_program_branch: []const u8 = "";
                if (invokes_comptime_event and self.emit_mode == .comptime_only) {
                    const ct_event_decl = self.findEventDeclInItems(self.all_items, &flow.inv().path);
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

                // `[declaration]` keyword templates (e.g. `const`) emit names into
                // the ENCLOSING scope, not a statement into a function body. Splice
                // the rendered decls directly as container members — no `flowN()`
                // wrapper, no main() call (it declares, it doesn't execute) — so
                // sibling flows resolve the names via Zig container-scope lookup.
                // Skipped here AND in the main-call loop (like impl_of flows), so
                // flow numbering stays in sync. The body carries no splice markers
                // (a declaration has no effects/continuations), so it emits verbatim.
                if (event_decl) |decl| {
                    if (annotation_parser.hasPart(decl.annotations, "declaration") and flow.inline_body != null) {
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write(flow.inline_body.?);
                        try self.code_emitter.write("\n");
                        return;
                    }
                }

                // Emit source marker for flow
                if (flow.location.line > 0) {
                    try self.code_emitter.writeIndent();
                    try self.code_emitter.write("// >>> FLOW: ");
                    try self.code_emitter.write(flow.location.file);
                    try self.code_emitter.write(":");
                    var flow_line_buf: [32]u8 = undefined;
                    const flow_line_str = try std.fmt.bufPrint(&flow_line_buf, "{}", .{flow.location.line});
                    try self.code_emitter.write(flow_line_str);
                    try self.code_emitter.write("  ~");
                    if (flow.inv().path.module_qualifier) |mq| {
                        try self.code_emitter.write(mq);
                        try self.code_emitter.write(":");
                    }
                    for (flow.inv().path.segments, 0..) |seg, idx| {
                        if (idx > 0) try self.code_emitter.write(".");
                        try writeMangledSegment(self.code_emitter, seg);
                    }
                    try self.code_emitter.write("()\n");
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
                        // Record runtime library module flows so main() can call them.
                        // Skip if this module is the main module re-emitted via a circular import:
                        // e.g., main = "input.kz", library module = "app.input" → skip to avoid duplicate calls.
                        if (self.current_module_prefix) |mod_prefix| {
                            const is_main_reimport = if (self.main_module_name) |mmn|
                                if (self.current_module_name) |cmn| blk: {
                                    const last_seg = if (std.mem.lastIndexOf(u8, cmn, ".")) |pos| cmn[pos + 1 ..] else cmn;
                                    break :blk std.mem.eql(u8, last_seg, mmn);
                                } else false
                            else false;

                            if (!is_main_reimport) {
                                var call_buf: std.ArrayList(u8) = .empty;
                                try call_buf.appendSlice(self.allocator, mod_prefix);
                                try call_buf.appendSlice(self.allocator, ".flow");
                                var flow_num_buf: [32]u8 = undefined;
                                const flow_num_str = try std.fmt.bufPrint(&flow_num_buf, "{}", .{self.flow_counter});
                                try call_buf.appendSlice(self.allocator, flow_num_str);
                                const call_str = try call_buf.toOwnedSlice(self.allocator);
                                try self.module_runtime_flows.append(self.allocator, call_str);
                            }
                        }
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
                    for (original_flow.inv().args) |arg| {
                        // Skip loop variable (handled by for-loop)
                        if (std.mem.eql(u8, arg.name, loop_ir.variable)) continue;
                        // Skip limit (handled by end_expr)
                        if (std.mem.eql(u8, arg.name, "limit")) continue;

                        // Emit variable declaration: var {name}: u64 = {value};
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("var ");
                        try emitter.writeBranchName(self.code_emitter, arg.name);
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
                    for (original_flow.body.continuations) |*cont| {
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

    /// Does this event declare the `reporter` machine parameter? Detected by
    /// NAME, the same way `ctx`/`program`/`allocator` are — a proc-transform's
    /// runtime Input is a fixed machine interface, so the event declaration is
    /// the only place the opt-in can be written.
    fn declaresReporter(event: *const ast.EventDecl) bool {
        for (event.input.fields) |f| {
            if (std.mem.eql(u8, f.name, "reporter")) return true;
        }
        return false;
    }

    /// Emit the event struct for an event implemented by a `~[transform]proc`.
    /// Input/Output are the MACHINE interface (the transform-stub ABI), not the
    /// event's user-surface declaration — the user surface is contract data for
    /// the checkers, never a runtime shape.
    fn emitTransformProcEventStruct(self: *VisitorEmitter, event: *const ast.EventDecl, tproc: *const ast.ProcDecl, all_items: []const ast.Item) !void {
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub const ");
        for (event.path.segments, 0..) |segment, idx| {
            if (idx > 0) try self.code_emitter.write("_");
            try writeMangledSegment(self.code_emitter, segment);
        }
        try self.code_emitter.write("_event = struct {\n");
        self.code_emitter.indent_level += 1;

        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub const Input = struct {\n");
        self.code_emitter.indent_level += 1;
        const machine_fields = [_][]const u8{
            "invocation: *const __koru_ast.Invocation,",
            "item: *const __koru_ast.Item,",
            "program: *const __koru_ast.Program,",
            "allocator: std.mem.Allocator,",
        };
        for (machine_fields) |field_line| {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write(field_line);
            try self.code_emitter.write("\n");
        }
        // `reporter` is the one machine parameter a proc-transform OPTS INTO:
        // the rest of this interface is fixed because every transform needs it,
        // but a diagnostic channel is only wanted by a transform that has
        // something to say. Declared on the event, exactly as a flow-implemented
        // transform declares it (220_027) — the convention here is a floor, not
        // a ceiling.
        const wants_reporter = declaresReporter(event);
        if (wants_reporter) {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("reporter: *koru_std.koru_compiler.ErrorReporter,\n");
        }
        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("};\n");

        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub const Output = union(enum) {\n");
        self.code_emitter.indent_level += 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("transformed: __koru_ast.SiteResult,\n");
        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("};\n");

        try self.emitTransformProcHandler(tproc, "handler", wants_reporter);

        // VARIANT SIBLINGS. A transform's body runs at Stage C, so `|zig` is its
        // default (emitted above as the bare `handler`) and every other tag is an
        // alternate — the same axis main.zig's dispatcher uses when it writes the
        // `handler__<variant>` branches (`comptime_default_lang`, main.zig:2047).
        //
        // Emitting them HERE is the whole point: this function is an early-return
        // override for events implemented by a `~[transform]proc`, so the general
        // variant loop further down `emitEventDecl` never runs for them. Without
        // this, the dispatcher emitted `handler.handler__js(input)` against a
        // struct that had no such member and the backend failed to compile — and
        // it did so for EVERY `[transform]proc`-shaped transform, which is most of
        // the stdlib. `print.blk|js` worked only because its procs are plain
        // `~proc`, so they miss this override and reach the general path.
        const variant_procs = try emitter.findVariantProcsByPath(self.allocator, all_items, &event.path);
        defer self.allocator.free(variant_procs);
        for (variant_procs) |vproc| {
            const target = vproc.target orelse continue;
            if (std.mem.eql(u8, target, "zig")) continue; // the default, already emitted
            const mangled = try emitter.mangleVariant(self.allocator, target);
            defer self.allocator.free(mangled);
            const handler_name = try std.fmt.allocPrint(self.allocator, "handler__{s}", .{mangled});
            defer self.allocator.free(handler_name);
            try self.emitTransformProcHandler(vproc, handler_name, wants_reporter);
        }

        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("};\n\n");
    }

    /// One handler function on a transform-proc event struct: the machine-ABI
    /// bindings, the source marker, and the proc body. Shared by the default
    /// `handler` and every `handler__<variant>` sibling so the two cannot drift.
    fn emitTransformProcHandler(
        self: *VisitorEmitter,
        tproc: *const ast.ProcDecl,
        handler_name: []const u8,
        wants_reporter: bool,
    ) !void {
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("pub fn ");
        try self.code_emitter.write(handler_name);
        try self.code_emitter.write("(__koru_event_input: Input) Output {\n");
        self.code_emitter.indent_level += 1;
        const machine_params = [_][]const u8{ "invocation", "item", "program", "allocator" };
        for (machine_params) |param| {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("const ");
            try self.code_emitter.write(param);
            try self.code_emitter.write(" = __koru_event_input.");
            try self.code_emitter.write(param);
            try self.code_emitter.write(";\n");
        }
        if (wants_reporter) {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("const reporter = __koru_event_input.reporter;\n");
        }
        for (machine_params) |param| {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &");
            try self.code_emitter.write(param);
            try self.code_emitter.write(";\n");
        }
        if (wants_reporter) {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &reporter;\n");
        }
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("_ = &__koru_event_input;\n");

        // Source marker + proc body, same shape as the general proc path.
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("// >>> PROC: ");
        for (tproc.path.segments, 0..) |seg, idx| {
            if (idx > 0) try self.code_emitter.write(".");
            try writeMangledSegment(self.code_emitter, seg);
        }
        if (tproc.target) |t| {
            try self.code_emitter.write("|");
            try self.code_emitter.write(t);
        }
        if (tproc.location.line > 0) {
            try self.code_emitter.write("  [");
            try self.code_emitter.write(tproc.location.file);
            try self.code_emitter.write(":");
            var line_buf: [32]u8 = undefined;
            const line_str = try std.fmt.bufPrint(&line_buf, "{}", .{tproc.location.line});
            try self.code_emitter.write(line_str);
            try self.code_emitter.write("]");
        }
        try self.code_emitter.write("\n");
        // `$mod.` strips to bare here: the body is emitted inside its own
        // module namespace, where module decls are in lexical scope.
        const tproc_body = try emitter.rewriteModToBare(self.allocator, tproc.body.text);
        defer self.allocator.free(tproc_body);
        try self.code_emitter.write(tproc_body);
        try self.code_emitter.write("\n");

        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("}\n");
    }

    /// Emit the body of a handler for an event `entry` that belongs to a
    /// mutual-tail-recursion `group`. Lowers the whole cycle into ONE labeled
    /// switch: shared `var` input bindings, `__koru_self_loop: switch` seeded
    /// to `entry`, whose arms are each member's inline subflow body. A
    /// tail-forward to member G inside any arm lowers (via
    /// `emitContinuationBody` under `ctx.mutual_group`) to `<reassign>;
    /// continue :__koru_self_loop .<G>;` — a direct threaded jump to G's arm,
    /// so the cross-handler recursion disappears entirely with NO dispatch
    /// state variable. The `>16-byte by-value Input` per-call cost and the
    /// stack growth are both gone; the loop constant-folds where the opaque
    /// recursive calls couldn't.
    fn emitMutualGroupHandler(
        self: *VisitorEmitter,
        entry: *const ast.EventDecl,
        group: *const emitter.MutualGroup,
        all_items: []const ast.Item,
    ) !void {
        // Debug marker naming the cycle.
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("// >>> MUTUAL-LOOP:");
        for (group.members) |m| {
            try self.code_emitter.write(" ");
            try self.code_emitter.write(m.tag);
        }
        try self.code_emitter.write("\n");

        // Shared `var` input bindings (mutated by the per-member reentries).
        for (entry.input.fields) |field| {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("var ");
            try emitter.writeBranchName(self.code_emitter, field.name);
            try self.code_emitter.write(" = __koru_event_input.");
            try emitter.writeBranchName(self.code_emitter, field.name);
            try self.code_emitter.write(";\n");
        }
        for (entry.input.fields) |field| {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &");
            try emitter.writeBranchName(self.code_emitter, field.name);
            try self.code_emitter.write(";\n");
        }
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("_ = &__koru_event_input;\n");

        // Combined loop: a LABELED SWITCH seeded to THIS handler's own event.
        // `continue :__koru_self_loop .<G>` in an arm jumps DIRECTLY to G's arm
        // — no dispatch-state variable, no re-dispatch per step. The old
        // `var __koru_fn` + `while (true) switch (__koru_fn)` form cost ~1.38x
        // on the mutual kernel (A/B on emitted Zig, 23.6→17.1ms ≈ C's 18.0).
        const entry_canon = try emitter.buildCanonicalEventName(&entry.path, self.allocator, self.main_module_name);
        defer self.allocator.free(entry_canon);
        const entry_tag = group.tagFor(entry_canon) orelse return error.MutualEntryNotInGroup;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("__koru_self_loop: switch (@as(enum { ");
        for (group.members, 0..) |m, i| {
            if (i > 0) try self.code_emitter.write(", ");
            try self.code_emitter.write(m.tag);
        }
        try self.code_emitter.write(" }, .");
        try self.code_emitter.write(entry_tag);
        try self.code_emitter.write(")) {\n");
        self.code_emitter.indent_level += 1;

        for (group.members) |m| {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write(".");
            try self.code_emitter.write(m.tag);
            try self.code_emitter.write(" => {\n");
            self.code_emitter.indent_level += 1;

            // Emit this member's inline subflow body with the group in context,
            // so its tail-forwards lower to `__koru_fn = .<G>; ...; continue`.
            // Same inline-statement dispatch the normal handler path uses; the
            // shared `var` input bindings and the loop wrapper are already open.
            var arm_ctx = emitter.EmissionContext{
                .allocator = self.allocator,
                .ast_items = all_items,
                .tap_registry = self.tap_registry,
                .type_registry = self.type_registry,
                .main_module_name = self.main_module_name,
                .is_sync = true,
                .in_handler = true,
                .mutual_group = group,
                .impl_event_decl = m.event,
                .bare_return_active = m.event.return_type != null,
            };
            var arm_counter: usize = 0;
            try emitter.emitInlineBodyNode(
                self.code_emitter,
                &arm_ctx,
                m.flow.inline_body.?,
                m.flow.body.continuations,
                &m.flow.inv().path,
                &arm_counter,
                m.flow.inv().return_binding,
            );

            self.code_emitter.indent_level -= 1;
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("},\n");
        }
        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("}\n");
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("unreachable;\n");
    }

    /// Emit a complete event declaration with Input, Output, and handler
    fn emitEventDecl(self: *VisitorEmitter, event: *const ast.EventDecl, all_items: []const ast.Item) !void {
        const eql = std.mem.eql;

        // Use scoped search by default (search within the module's own items)
        // This ensures test_lib.graphics:init finds the graphics module's implementation, not audio's
        const items_to_search = all_items;

        // TRANSFORM-PROC OVERRIDE: `~[transform]proc` on an ordinary event.
        // The event decl carries the USER surface (payload + branch contract —
        // contract branches may be raw-name classes like `*`, meaningless as a
        // Zig union). The generated handler uses the machine convention
        // instead: (invocation, item, program, allocator) → transformed:
        // SiteResult — the transform-stub ABI in run_pass()'s dispatch table.
        if (emitter.findTransformProc(items_to_search, event.path.segments)) |tproc| {
            try self.emitTransformProcEventStruct(event, tproc, items_to_search);
            return;
        }

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
                if (std.mem.startsWith(u8, field.type, "?")) {
                    try self.code_emitter.write("?[]const u8 = null");  // Optional expression, defaults to null
                } else {
                    try self.code_emitter.write("[]const u8");  // Expression captured as string literal
                }
            } else if (eql(u8, field.type, "Program")) {
                try self.code_emitter.write("*const __koru_ast.Program");
            } else {
                try emitter.writeFieldType(self.code_emitter, field, self.main_module_name);
            }
            // The default used to ride into Zig inside `field.type` — now that
            // it is split off, it has to be written back deliberately.
            if (field.default) |d| {
                try self.code_emitter.write(" = ");
                try self.code_emitter.write(d);
            }
            try self.code_emitter.write(",\n");
        }

        self.code_emitter.indent_level -= 1;
        try self.code_emitter.writeIndent();
        try self.code_emitter.write("};\n");

        // Partition branches: terminal `|` → Output union variants, effect
        // `!` → comptime handler-struct fns (effect operations). See
        // docs/EFFECT_BRANCHES.md for the lowering.
        var terminal_count: usize = 0;
        var has_effect: bool = false;
        for (event.branches) |b| {
            if (b.kind == .effect) {
                has_effect = true;
            } else {
                terminal_count += 1;
            }
        }

        // Output type — terminal branches only (bare `-> T` handled centrally)
        try self.code_emitter.writeIndent();
        if (try emitter.emitBareReturnOutput(self.code_emitter, event, self.main_module_name)) {
            // bare-return Output emitted centrally
        } else if (terminal_count == 0) {
            try self.code_emitter.write("pub const Output = void;\n");
        } else {
            try self.code_emitter.write("pub const Output = union(enum) {\n");
            self.code_emitter.indent_level += 1;

            for (event.branches) |branch| {
                if (branch.kind == .effect) continue;
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
                                if (!eql(u8, target, self.lang)) continue;
                            }
                            // Emit the proc as _default_handler (before handler function)
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("fn _default_handler(__koru_event_input: Input) Output {\n");
                            self.code_emitter.indent_level += 1;

                            // Generate implicit input bindings
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("const ");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(" = __koru_event_input.");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(";\n");
                            }
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = &");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(";\n");
                            }
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("_ = &__koru_event_input;\n");

                            // Rewrite _ = field to _ = &field (see main handler comment)
                            var default_proc_body: []const u8 = proc.body.text;
                            for (event.input.fields) |field| {
                                const discard_old = try std.fmt.allocPrint(self.allocator, "_ = {s}", .{field.name});
                                const discard_new = try std.fmt.allocPrint(self.allocator, "_ = &{s}", .{field.name});
                                default_proc_body = try replaceIdentifier(self.allocator, default_proc_body, discard_old, discard_new);
                            }

                            var indent_buf: [64]u8 = undefined;
                            var indent_pos: usize = 0;
                            var idx: usize = 0;
                            while (idx < self.code_emitter.indent_level) : (idx += 1) {
                                @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                indent_pos += 4;
                            }
                            const indent_str = indent_buf[0..indent_pos];

                            try self.code_emitter.emitReindentedText(default_proc_body, indent_str);
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
                                        try emitter.writeBranchName(self.code_emitter, field.name);
                                        try self.code_emitter.write(" = __koru_event_input.");
                                        try emitter.writeBranchName(self.code_emitter, field.name);
                                        try self.code_emitter.write(";\n");
                                    }
                                    for (event.input.fields) |field| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &");
                                        try emitter.writeBranchName(self.code_emitter, field.name);
                                        try self.code_emitter.write(";\n");
                                    }
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &__koru_event_input;\n");

                                    // A statement-shaped transform body binds NOTHING —
                                    // the discard-guard below must not name a const that
                                    // was never emitted.
                                    var head_bound_root = true;

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
                                            head_bound_root = false;
                                            const has_named_branches = blk: {
                                                for (flow.body.continuations) |cont| {
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
                                        // The root invocation may carry a call-site
                                        // `: bind` (a bare-return chain head, e.g.
                                        // coordinate's default `context-create(...):
                                        // c0 |> frontend(ctx: c0)`) — the chain
                                        // steps reference the BIND name, so it must
                                        // be the const's name. Unbound roots keep
                                        // `result` (the branch-switch convention).
                                        try self.code_emitter.write("const ");
                                        try self.code_emitter.write(defaultHandlerRootBind(flow.inv()));
                                        try self.code_emitter.write(" = ");

                                        // Emit the event call
                                        if (flow.inv().path.module_qualifier) |mq| {
                                            try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                            try self.code_emitter.write(".");
                                        }
                                        for (flow.inv().path.segments, 0..) |seg, idx| {
                                            if (idx > 0) try self.code_emitter.write("_");
                                            try writeMangledSegment(self.code_emitter, seg);
                                        }
                                        try self.code_emitter.write("_event.handler(.{");

                                        for (flow.inv().args, 0..) |arg, k| {
                                            if (k > 0) try self.code_emitter.write(", ");
                                            try self.code_emitter.write(" .");
                                            try emitter.writeBranchName(self.code_emitter, arg.name);
                                            try self.code_emitter.write(" = ");
                                            try self.code_emitter.write(arg.value);
                                        }
                                        try self.code_emitter.write(" });\n");
                                    }

                                    // A head with no continuations has no switch to
                                    // consume the root const — discard-guard it
                                    // (same hygiene as nested_result_N in arm
                                    // emission). Only when a const actually exists:
                                    // an inline-stmt head emitted raw statements and
                                    // bound no name.
                                    if (flow.body.continuations.len == 0 and head_bound_root) {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &");
                                        try self.code_emitter.write(defaultHandlerRootBind(flow.inv()));
                                        try self.code_emitter.write(";\n");
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

                                    const source_event_name = try emitter.buildCanonicalEventName(&flow.inv().path, self.allocator, self.main_module_name);
                                    const compiler_module_name = try codegen_utils.buildKoruModulePath(self.allocator, "std.compiler");
                                    defer self.allocator.free(compiler_module_name);
                                    // The other spelling of the same head bind — see
                                    // headLabelBindOnBareReturn.
                                    var compiler_rooted_conts: []const ast.Continuation = flow.body.continuations;
                                    if (headLabelBindOnBareReturn(&flow, items_to_search)) |label_bind| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const ");
                                        try self.code_emitter.write(label_bind);
                                        try self.code_emitter.write(" = ");
                                        try self.code_emitter.write(defaultHandlerRootBind(flow.inv()));
                                        try self.code_emitter.write(";\n");
                                        compiler_rooted_conts = try voidifyHeadLabel(self.allocator, flow.body.continuations);
                                    }
                                    try emitter.emitSubflowContinuationsRooted(self.code_emitter, compiler_rooted_conts, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, compiler_module_name, event.return_type != null, event, defaultHandlerRootBind(flow.inv()));

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

        // Handler function — `comptime __H: type` when the event has any
        // effect `!` branches. Inside the body we'll alias each `H.NAME`
        // back to the bare identifier so the proc body reads naturally.
        // A pure-scalar value event lowers to an `inline` public shim over a
        // scalar-param private impl: Zig `inline` + SROA collapse every
        // `.handler(.{…})` call site (emitter, store-text, user `|zig`, dynamic
        // dispatch) to a direct register-passing call, so a >16-byte Input stops
        // round-tripping through memory on every recursive call. The impl
        // reconstructs Input locally, leaving the body emission below unchanged.
        const use_scalar_shim = !has_effect and emitter.isScalarValueFields(event.input.fields);
        try self.code_emitter.writeIndent();
        if (has_effect) {
            try self.code_emitter.write("pub fn handler(__koru_event_input: Input, comptime __H: type) Output {\n");
        } else if (use_scalar_shim) {
            try self.code_emitter.write("pub inline fn handler(__koru_event_input: Input) Output {\n");
            self.code_emitter.indent_level += 1;
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("return __koru_handler_impl(");
            for (event.input.fields, 0..) |field, i| {
                if (i > 0) try self.code_emitter.write(", ");
                try self.code_emitter.write("__koru_event_input.");
                try emitter.writeBranchName(self.code_emitter, field.name);
            }
            try self.code_emitter.write(");\n");
            self.code_emitter.indent_level -= 1;
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("}\n");
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("fn __koru_handler_impl(");
            for (event.input.fields, 0..) |field, i| {
                if (i > 0) try self.code_emitter.write(", ");
                var pbuf: [24]u8 = undefined;
                try self.code_emitter.write(try std.fmt.bufPrint(&pbuf, "__koru_p_{d}: ", .{i}));
                try self.code_emitter.write(field.type);
            }
            try self.code_emitter.write(") Output {\n");
        } else {
            try self.code_emitter.write("pub fn handler(__koru_event_input: Input) Output {\n");
        }
        self.code_emitter.indent_level += 1;

        // Scalar-shim impl reconstructs Input from the scalar params so the body
        // below reads identically (SROA elides the local aggregate).
        if (use_scalar_shim) {
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("const __koru_event_input: Input = .{ ");
            for (event.input.fields, 0..) |field, i| {
                if (i > 0) try self.code_emitter.write(", ");
                try self.code_emitter.write(".");
                try emitter.writeBranchName(self.code_emitter, field.name);
                var pbuf: [24]u8 = undefined;
                try self.code_emitter.write(try std.fmt.bufPrint(&pbuf, " = __koru_p_{d}", .{i}));
            }
            try self.code_emitter.write(" };\n");
        }

        // Yielding-branch comptime aliases — must come before any user body code.
        if (has_effect) {
            for (event.branches) |*b| {
                if (b.kind != .effect) continue;
                // Optional arms → nullable-fn-ptr alias (comptime-known present/
                // absent) so presence guards fold and the omitted case never
                // forces `__H.X`. (400_146/147/148)
                if (b.is_optional) {
                    try emitter.emitOptionalArmNullableAlias(self.code_emitter, b, self.main_module_name);
                    continue;
                }
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("const ");
                try emitter.writeBranchName(self.code_emitter, b.name);
                try self.code_emitter.write(" = __H.");
                try emitter.writeBranchName(self.code_emitter, b.name);
                try self.code_emitter.write(";\n");
                try self.code_emitter.writeIndent();
                try self.code_emitter.write("_ = &");
                try emitter.writeBranchName(self.code_emitter, b.name);
                try self.code_emitter.write(";\n");
            }
        }

        // Find implementation
        var found_impl = false;
        log.debug("  [emitEventDecl] Searching for implementation of event: ", .{});
        for (event.path.segments) |seg| {
            log.debug("{s}.", .{seg});
        }
        log.debug(" in {} items\n", .{items_to_search.len});

        // MUTUAL-TAIL-RECURSION GROUP: if this event and a cycle of sibling
        // events tail-forward to each other (`is-even`↔`is-odd`), lower the
        // whole cycle into ONE combined `while (true) switch (__koru_fn) {...}`
        // dispatch loop — the mutual generalization of the self-tail-loop
        // lowering. Detection is conservative (uniform input shape, clean cycle,
        // lowerable inline subflow bodies); a miss falls through to ordinary
        // call-based emission below. Effect-bearing events keep their handler
        // signature and are left on the normal path.
        if (!has_effect) {
            if (try emitter.detectMutualGroup(event, items_to_search, self.allocator, self.main_module_name)) |group_val| {
                var group = group_val;
                defer group.deinit(self.allocator);
                try self.emitMutualGroupHandler(event, &group, items_to_search);
                found_impl = true;
            }
        }

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
                                                try emitter.writeBranchName(self.code_emitter, field.name);
                                                try self.code_emitter.write(" = __koru_event_input.");
                                                try emitter.writeBranchName(self.code_emitter, field.name);
                                                try self.code_emitter.write(";\n");
                                            }
                                            // Suppress unused variable warnings
                                            for (event.input.fields) |field| {
                                                try self.code_emitter.writeIndent();
                                                try self.code_emitter.write("_ = &");
                                                try emitter.writeBranchName(self.code_emitter, field.name);
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
                                            if (bc.is_bare_return) {
                                                try self.code_emitter.writeIndent();
                                                try self.code_emitter.write("return ");
                                                if (bc.plain_value) |pv| {
                                                    try emitter.emitValue(self.code_emitter, &value_ctx, pv);
                                                } else {
                                                    try self.code_emitter.write("undefined");
                                                }
                                                try self.code_emitter.write(";\n");
                                                found_impl = true;
                                                break;
                                            }
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
                                                    try emitter.writeBranchName(self.code_emitter, field.name);
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
                                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                                    try self.code_emitter.write(" = __koru_event_input.");
                                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                                    try self.code_emitter.write(";\n");
                                                }
                                                // Suppress unused variable warnings
                                                for (event.input.fields) |field| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("_ = &");
                                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                                    try self.code_emitter.write(";\n");
                                                }
                                                try self.code_emitter.writeIndent();
                                                try self.code_emitter.write("_ = &__koru_event_input;\n");

                                                // A statement-shaped transform body binds
                                                // NOTHING — the discard-guard below must not
                                                // name a const that was never emitted.
                                                var head_bound_root = true;

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
                                                        head_bound_root = false;
                                                        const has_named_branches = blk: {
                                                            for (flow.body.continuations) |cont| {
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
                                                    // Root `: bind` names the const (bare-return
                                                    // chain head) — see defaultHandlerRootBind.
                                                    try self.code_emitter.write("const ");
                                                    try self.code_emitter.write(defaultHandlerRootBind(flow.inv()));
                                                    try self.code_emitter.write(" = ");

                                                    // Check if this is a self-call (delegating to default)
                                                    const is_self_call = blk: {
                                                        // For cross-module impl, self-call means calling the same event
                                                        if (flow.inv().path.module_qualifier) |inv_mq| {
                                                            if (eql(u8, inv_mq, event_module) and
                                                                flow.inv().path.segments.len == event.path.segments.len)
                                                            {
                                                                var segs_match = true;
                                                                for (flow.inv().path.segments, 0..) |seg, j| {
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
                                                        if (flow.inv().path.module_qualifier) |mq| {
                                                            try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                                            try self.code_emitter.write(".");
                                                        }
                                                        for (flow.inv().path.segments, 0..) |seg, idx| {
                                                            if (idx > 0) try self.code_emitter.write("_");
                                                            try writeMangledSegment(self.code_emitter, seg);
                                                        }
                                                        try self.code_emitter.write("_event.handler(.{");
                                                    }

                                                    // Write arguments
                                                    for (flow.inv().args, 0..) |arg, k| {
                                                        if (k > 0) try self.code_emitter.write(", ");
                                                        try self.code_emitter.write(" .");
                                                        try emitter.writeBranchName(self.code_emitter, arg.name);
                                                        try self.code_emitter.write(" = ");
                                                        try self.code_emitter.write(arg.value);
                                                    }
                                                    try self.code_emitter.write(" });\n");
                                                }

                                                // A head with no continuations has no switch to
                                                // consume the root const — discard-guard it.
                                                // Only when a const actually exists: an
                                                // inline-stmt head bound no name.
                                                if (flow.body.continuations.len == 0 and head_bound_root) {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("_ = &");
                                                    try self.code_emitter.write(defaultHandlerRootBind(flow.inv()));
                                                    try self.code_emitter.write(";\n");
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

                                                // Emit source marker for subflow impl
                                                if (flow.location.line > 0) {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("// >>> SUBFLOW: ");
                                                    try self.code_emitter.write(flow.location.file);
                                                    try self.code_emitter.write(":");
                                                    var sf_line_buf: [32]u8 = undefined;
                                                    const sf_line_str = try std.fmt.bufPrint(&sf_line_buf, "{}", .{flow.location.line});
                                                    try self.code_emitter.write(sf_line_str);
                                                    try self.code_emitter.write("\n");
                                                }

                                                const source_event_name = try emitter.buildCanonicalEventName(&flow.inv().path, self.allocator, self.main_module_name);
                                                // The other spelling of the same head bind — see
                                                // headLabelBindOnBareReturn.
                                                var rooted_conts: []const ast.Continuation = flow.body.continuations;
                                                if (headLabelBindOnBareReturn(&flow, self.all_items)) |label_bind| {
                                                    try self.code_emitter.writeIndent();
                                                    try self.code_emitter.write("const ");
                                                    try self.code_emitter.write(label_bind);
                                                    try self.code_emitter.write(" = ");
                                                    try self.code_emitter.write(defaultHandlerRootBind(flow.inv()));
                                                    try self.code_emitter.write(";\n");
                                                    rooted_conts = try voidifyHeadLabel(self.allocator, flow.body.continuations);
                                                }
                                                try emitter.emitSubflowContinuationsRooted(self.code_emitter, rooted_conts, 0, indent_str, self.all_items, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "main_module", event.return_type != null, event, defaultHandlerRootBind(flow.inv()));

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
                                    // No variant registered: only use the default lang
                                    // (configured via `--lang=<name>`, defaults to "zig").
                                    if (!eql(u8, target, self.lang)) continue;
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
                                try writeMangledSegment(self.code_emitter, seg);
                            }
                            // Append source location
                            if (proc.location.line > 0) {
                                try self.code_emitter.write("  [");
                                try self.code_emitter.write(proc.location.file);
                                try self.code_emitter.write(":");
                                var proc_line_buf: [32]u8 = undefined;
                                const proc_line_str = try std.fmt.bufPrint(&proc_line_buf, "{}", .{proc.location.line});
                                try self.code_emitter.write(proc_line_str);
                                try self.code_emitter.write("]");
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
                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                    try self.code_emitter.write(" = __koru_event_input.");
                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                    try self.code_emitter.write(";\n");
                                }
                            }
                            // Suppress unused variable warnings
                            for (event.input.fields) |field| {
                                if (!nameIsShadowed(field.name, declared_names.items)) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &");
                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                    try self.code_emitter.write(";\n");
                                }
                            }

                            // Keep _ = &__koru_event_input for backwards compatibility
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("_ = &__koru_event_input;\n");

                            // `[template]` procs are rendered per-invocation and inlined
                            // at call sites (Stage C `template_processor`); this decl-site
                            // handler is never called, and its body is template text
                            // (`{% %}`, `{{ }}`), not valid host code. Emit an unreachable
                            // stub instead — the same shape the variant path uses below.
                            {
                                var is_template = false;
                                for (proc.annotations) |ann| {
                                    if (eql(u8, ann, "template")) {
                                        is_template = true;
                                        break;
                                    }
                                }
                                if (is_template) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("unreachable; // [template] proc — inlined at call sites\n");
                                    found_impl = true;
                                    break;
                                }
                            }

                            // Rewrite proc body: replace shadowed field names with __koru_event_input.field
                            var proc_body: []const u8 = proc.body.text;
                            for (event.input.fields) |field| {
                                if (nameIsShadowed(field.name, declared_names.items)) {
                                    const member = try codegen_utils.escapeZigIdentifier(self.allocator, field.name);
                                    const replacement = try std.fmt.allocPrint(self.allocator, "__koru_event_input.{s}", .{member});
                                    proc_body = try replaceIdentifier(self.allocator, proc_body, field.name, replacement);
                                } else if (codegen_utils.needsEscaping(field.name)) {
                                    // The binding above was emitted escaped (`const @"align" = …`),
                                    // so the body's bare references must be rewritten to the same
                                    // spelling — a Koru param may legally collide with a Zig
                                    // keyword or primitive, and the fix belongs to emission, not
                                    // the author's surface (230_017).
                                    const escaped = try codegen_utils.escapeZigIdentifier(self.allocator, field.name);
                                    proc_body = try replaceIdentifier(self.allocator, proc_body, field.name, escaped);
                                }
                            }

                            // Rewrite _ = field to _ = &field in proc body.
                            // The emitter generates `_ = &field;` for unused suppression,
                            // so user's `_ = field;` must also use & to avoid Zig's
                            // "pointless discard of local constant" error.
                            for (event.input.fields) |field| {
                                if (!nameIsShadowed(field.name, declared_names.items)) {
                                    // Escaped params were rewritten to `@"name"` above, so the
                                    // discard in the body now carries that spelling too.
                                    const spelling = try codegen_utils.escapeZigIdentifier(self.allocator, field.name);
                                    const discard_old = try std.fmt.allocPrint(self.allocator, "_ = {s}", .{spelling});
                                    const discard_new = try std.fmt.allocPrint(self.allocator, "_ = &{s}", .{spelling});
                                    proc_body = try replaceIdentifier(self.allocator, proc_body, discard_old, discard_new);
                                }
                            }

                            // `$mod.` strips to bare here: the body is emitted
                            // inside its own module namespace (lexical scope).
                            proc_body = try emitter.rewriteModToBare(self.allocator, proc_body);

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
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(" = __koru_event_input.");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(";\n");
                            }
                            // Suppress unused variable warnings
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = &");
                                try emitter.writeBranchName(self.code_emitter, field.name);
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
                            if (bc.is_bare_return) {
                                // `-> T` bare return: `return <value>;`, no tag.
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("return ");
                                if (bc.plain_value) |pv| {
                                    try emitter.emitValue(self.code_emitter, &value_ctx, pv);
                                } else {
                                    try self.code_emitter.write("undefined");
                                }
                                try self.code_emitter.write(";\n");
                                found_impl = true;
                                break;
                            }
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
                                    try emitter.writeBranchName(self.code_emitter, field.name);
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
                        // Variant arms are emitted as separate handler__<mangled>
                        // functions further down. The main handler only uses the
                        // unvariant arm (the default).
                        if (flow.impl_variant != null) continue;

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
                                // Emit source marker for subflow impl
                                if (flow.location.line > 0) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("// >>> SUBFLOW: ");
                                    try self.code_emitter.write(flow.location.file);
                                    try self.code_emitter.write(":");
                                    var sf_loc_buf: [32]u8 = undefined;
                                    const sf_loc_str = try std.fmt.bufPrint(&sf_loc_buf, "{}", .{flow.location.line});
                                    try self.code_emitter.write(sf_loc_str);
                                    try self.code_emitter.write("\n");
                                }
                                // Tail self-continuation detection: if this flow
                                // re-enters its own event in tail position and forwards
                                // the result unchanged, lower the handler as a `while
                                // (true)` loop over `var` input bindings (see
                                // emitter_helpers.flowContainsSelfTailForward / the
                                // per-site `emitSelfTailReentry`). Computed here so the
                                // binding kind, the loop wrapper, and the per-ctx flag
                                // below all share one decision. `pre_label` flows keep
                                // their own state-loop lowering, so we don't double-wrap.
                                var dummy_ctx = emitter.EmissionContext{
                                    .allocator = self.allocator,
                                    .main_module_name = self.main_module_name,
                                };
                                const self_loop_canonical = emitter.buildCanonicalEventName(&event.path, self.allocator, self.main_module_name) catch null;
                                defer if (self_loop_canonical) |c| self.allocator.free(c);
                                const is_self_loop = if (self_loop_canonical) |c|
                                    (flow.pre_label == null and emitter.flowContainsSelfTailForward(flow.body.continuations, c, &dummy_ctx))
                                else false;

                                // Generate implicit input bindings for consistency with procs
                                for (event.input.fields) |field| {
                                    try self.code_emitter.writeIndent();
                                    // Self-loop handlers reassign these from the tail
                                    // self-call's args, so they must be `var`.
                                    try self.code_emitter.write(if (is_self_loop) "var " else "const ");
                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                    try self.code_emitter.write(" = __koru_event_input.");
                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                    try self.code_emitter.write(";\n");
                                }
                                // Suppress unused variable warnings
                                for (event.input.fields) |field| {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("_ = &");
                                    try emitter.writeBranchName(self.code_emitter, field.name);
                                    try self.code_emitter.write(";\n");
                                }
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = &__koru_event_input;\n");

                                // Wrap the body in a labeled `while (true)` so the tail
                                // self-call lowers to `continue :label` (see
                                // `emitSelfTailReentry`). The loop only exits via the
                                // terminal branch's `return`; the `unreachable` after
                                // mirrors how `#label` loops terminate.
                                if (is_self_loop) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("__koru_self_loop: while (true) {\n");
                                    self.code_emitter.indent_level += 1;
                                }

                                // for/if/capture/~const set preamble_code to REPLACE the call (then inline
                                // their continuations, no handler). A routed transform (field:new.on-stack→
                                // new-instack) marks its invocation @preamble_then_call: emit the preamble
                                // (stack vars) here, then fall through to the NORMAL handler call below.
                                const keep_call = blk_kc: {
                                    for (flow.inv().annotations) |ann| {
                                        if (std.mem.eql(u8, ann, "@preamble_then_call")) break :blk_kc true;
                                    }
                                    break :blk_kc false;
                                };
                                if (flow.preamble_code != null and keep_call) {
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write(flow.preamble_code.?);
                                    try self.code_emitter.write("\n");
                                }

                                // Subflow-implemented effects: the impl head FIRES one of the
                                // event's own effect arms by CALLING it (`ping = pong(x)`,
                                // `query = ask(q): a => done a`, multi-arm consumed as `|`
                                // branches). Route through emitFlow with the implemented
                                // event in context — the arm-call lowers to `__H.<arm>(...)`
                                // and the resume sum drives the continuation switch.
                                if (emitter.findEffectArm(event, &flow.inv().path) != null) {
                                    var arm_fire_ctx = emitter.EmissionContext{
                                        .allocator = self.allocator,
                                        .ast_items = self.all_items,
                                        .tap_registry = self.tap_registry,
                                        .type_registry = self.type_registry,
                                        .main_module_name = self.main_module_name,
                                        .is_sync = true,
                                        .in_handler = true,
                                        .impl_event_decl = event,
                                        .bare_return_active = event.return_type != null,
                                    };
                                    try emitter.emitFlow(self.code_emitter, &arm_fire_ctx, &flow);
                                } else
                                // Check if the flow has preamble_code (from transforms like ~for, ~if, ~capture)
                                // This means the flow contains a ForeachNode/ConditionalNode/CaptureNode in continuations
                                if (flow.preamble_code != null and !keep_call) {
                                    const preamble = flow.preamble_code.?;
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
                                        .self_loop_active = is_self_loop,
                                        .self_loop_event_canonical = self_loop_canonical,
                                        .impl_event_decl = event,
                                        // Bare-return `-> T`: a produce arm inside the transformed
                                        // control flow (`if(...) | then -> x`) IS the event's return
                                        // value, so expression steps must `return x;` not discard.
                                        // Same signal as the label-fold ctx below.
                                        .bare_return_active = event.return_type != null,
                                    };

                                    // Emit continuation bodies directly - the continuations contain the control flow node
                                    var result_counter: usize = 0;
                                    for (flow.body.continuations) |*cont| {
                                        try emitter.emitContinuationBody(self.code_emitter, &emitter_ctx, cont, &result_counter);
                                    }
                                } else if (flow.inline_body) |inline_code| {
                                    // Check if continuations have named branches (need switch)
                                    const has_named_branches = blk: {
                                        for (flow.body.continuations) |cont| {
                                            if (cont.branch.len > 0) break :blk true;
                                        }
                                        break :blk false;
                                    };

                                    if (has_named_branches) {
                                      // A statement-style template head (e.g. `std/control:if` in
                                      // VALUE-return position) hands off to its named continuations
                                      // via `__koru_continue_N` markers, NOT a value-producing union.
                                      // Route it through the shared inline-body node emitter (the same
                                      // path `emitFlow` uses for top-level inline templates), which
                                      // resolves those markers into the continuation bodies. The
                                      // `const result = <body>; switch(result)` path below would leave
                                      // the markers raw and emit the `if` as statement-blocks. 320_096.
                                      const inline_stmt_marker = "//@koru:inline_stmt\n";
                                      if (std.mem.indexOf(u8, inline_code, inline_stmt_marker) != null) {
                                        var inline_ctx = emitter.EmissionContext{
                                            .allocator = self.allocator,
                                            .ast_items = self.all_items,
                                            .tap_registry = self.tap_registry,
                                            .type_registry = self.type_registry,
                                            .main_module_name = self.main_module_name,
                                            .current_source_event = null,
                                            .label_contexts = null,
                                            .is_sync = true,
                                            .in_handler = true,
                                            .self_loop_active = is_self_loop,
                                            .self_loop_event_canonical = self_loop_canonical,
                                            .impl_event_decl = event,
                                            // Bare-return `-> T`: a produce arm spliced from an
                                            // inline-stmt template (`if(...) | then -> x`) IS the
                                            // event's return value — `return x;`, not a discard.
                                            .bare_return_active = event.return_type != null,
                                        };
                                        var inline_result_counter: usize = 0;
                                        try emitter.emitInlineBodyNode(self.code_emitter, &inline_ctx, inline_code, flow.body.continuations, &flow.inv().path, &inline_result_counter, flow.inv().return_binding);
                                      } else {
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

                                        const source_event_name = try emitter.buildCanonicalEventName(&flow.inv().path, self.allocator, self.main_module_name);
                                        try emitter.emitSubflowContinuations(self.code_emitter, flow.body.continuations, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "main_module", event.return_type != null, event);
                                      }
                                    } else {
                                        // Void/pipeline continuations after an inline-transform head.
                                        // ONE route: emitInlineBodyNode — the same helper `emitFlow`
                                        // uses for a top-level inline template, and the same one the
                                        // inline_stmt_marker path above takes. It emits the rendered
                                        // head AND walks the void continuations, so every later step
                                        // of the chain is emitted; a bound value (`sub = fmt:ln(...):
                                        // l |> use l`) materialises as `const l = <labeled block>`
                                        // (020_061), and a void `branch_constructor` arm still lowers
                                        // to `return .{ ... }` through emitPipelineStep's "_" result.
                                        //
                                        // Nothing here may hand-roll a second walk over
                                        // flow.body.continuations. A local walk that lowers only the
                                        // node kinds it happens to know drops the rest in silence —
                                        // `sub = std/io:print.ln("a") |> anything()` compiles to the
                                        // head alone, runs, and exits 0. emitFlow routes every
                                        // top-level inline body through this one helper for exactly
                                        // that reason; a subflow body is the same chain and takes the
                                        // same route. 210_176.
                                        var bound_ctx = emitter.EmissionContext{
                                            .allocator = self.allocator,
                                            .ast_items = self.all_items,
                                            .tap_registry = self.tap_registry,
                                            .type_registry = self.type_registry,
                                            .main_module_name = self.main_module_name,
                                            .current_source_event = null,
                                            .label_contexts = null,
                                            .is_sync = true,
                                            .in_handler = true,
                                            .self_loop_active = is_self_loop,
                                            .self_loop_event_canonical = self_loop_canonical,
                                            .impl_event_decl = event,
                                            .bare_return_active = event.return_type != null,
                                        };
                                        var bound_result_counter: usize = 0;
                                        try emitter.emitInlineBodyNode(self.code_emitter, &bound_ctx, inline_code, flow.body.continuations, &flow.inv().path, &bound_result_counter, flow.inv().return_binding);
                                    }
                                } else if (flow.pre_label != null) {
                                    // Label fold on the subflow RHS (`~spin = #loop step(...)`):
                                    // route through emitFlow, which owns the pre_label state-loop
                                    // lowering (state vars + `label: while` + looping/terminal
                                    // branch split). in_handler makes terminal branch
                                    // constructors emit `return .{ ... }`.
                                    var label_fold_ctx = emitter.EmissionContext{
                                        .allocator = self.allocator,
                                        .ast_items = self.all_items,
                                        .tap_registry = self.tap_registry,
                                        .type_registry = self.type_registry,
                                        .main_module_name = self.main_module_name,
                                        .is_sync = true,
                                        .in_handler = true,
                                        .self_loop_active = is_self_loop,
                                        .self_loop_event_canonical = self_loop_canonical,
                                        .impl_event_decl = event,
                                        // Bare-return `-> T`: the loop-EXIT arm produces the
                                        // event's value (`| done e -> e`), so it must `return e;`
                                        // not discard. Same signal as the switch path (020_025);
                                        // this is the label-fold sibling (020_028).
                                        .bare_return_active = event.return_type != null,
                                    };
                                    try emitter.emitFlow(self.code_emitter, &label_fold_ctx, &flow);
                                } else {
                                    // Check if the invoked event has mutable branches.
                                    // items_to_search is the ENCLOSING MODULE's own items, so a
                                    // call into a SIBLING module (`orisha:serve` implemented as a
                                    // flow over `orisha/pump:run`) resolved to null here — and a
                                    // null invoked_event silently disabled both the effect-arm
                                    // partition below and the mutable check. Fall back to the
                                    // program-wide, module-qualifier-aware lookup the top-level
                                    // invocation path already uses.
                                    const invoked_event = self.findEventDeclInItems(items_to_search, &flow.inv().path) orelse
                                        emitter.findEventDeclByPath(self.all_items, &flow.inv().path);

                                    // Effect-branches phase 3b, at a SUBFLOW head. An event
                                    // with `!` branches lowers to
                                    // `handler(input, comptime __H: type)`, so its arms ride
                                    // in as a synthesized Handlers struct passed second.
                                    // emitFlow does this dance at a top-level site and
                                    // emitContinuationBody does it mid-chain; a subflow body
                                    // reached neither, so `~drive = beats(k) ! beat …` emitted
                                    // the no-effect call form and dropped the arm on the floor
                                    // (400_175). Partition here, emit the struct BEFORE the
                                    // call line, and switch over terminal arms only.
                                    var sf_effect_conts: std.ArrayList(ast.Continuation) = .empty;
                                    defer sf_effect_conts.deinit(self.allocator);
                                    var sf_terminal_conts: std.ArrayList(ast.Continuation) = .empty;
                                    defer sf_terminal_conts.deinit(self.allocator);
                                    var sf_handlers_name: ?[]const u8 = null;
                                    defer if (sf_handlers_name) |h| self.allocator.free(h);

                                    if (invoked_event) |inv_ed| {
                                        var inv_has_effect = false;
                                        for (inv_ed.branches) |b| {
                                            if (b.kind == .effect) {
                                                inv_has_effect = true;
                                                break;
                                            }
                                        }
                                        if (inv_has_effect) {
                                            for (flow.body.continuations) |c| {
                                                if (c.kind == .effect) {
                                                    try sf_effect_conts.append(self.allocator, c);
                                                } else {
                                                    try sf_terminal_conts.append(self.allocator, c);
                                                }
                                            }
                                            if (sf_effect_conts.items.len > 0) {
                                                const hname = try std.fmt.allocPrint(self.allocator, "Handlers_sf", .{});
                                                sf_handlers_name = hname;
                                                var h_ctx = emitter.EmissionContext{
                                                    .allocator = self.allocator,
                                                    .ast_items = self.all_items,
                                                    .tap_registry = self.tap_registry,
                                                    .type_registry = self.type_registry,
                                                    .main_module_name = self.main_module_name,
                                                    .is_sync = true,
                                                    .in_handler = true,
                                                    .impl_event_decl = event,
                                                };
                                                try emitter.emitHandlersStruct(self.code_emitter, &h_ctx, hname, sf_effect_conts.items, inv_ed);
                                            }
                                        }
                                    }

                                    // Generate the invocation of the inner event
                                    try self.code_emitter.writeIndent();
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
                                        // NB: this path handles a root `: bind` by
                                        // ALIASING below (`const <bind> = result;`),
                                        // unlike the default-handler paths which name
                                        // the const directly — keep `result` here.
                                        try self.code_emitter.write("const result = ");
                                    }

                                    // Check if this is a self-call (impl calling the same event to delegate to default)
                                    // This happens in override patterns like: ~mod:foo = foo(x: 42) | ok |> ...
                                    const is_self_call = blk: {
                                        if (!has_impl_override) break :blk false;
                                        if (flow.inv().path.segments.len != event.path.segments.len) break :blk false;
                                        for (flow.inv().path.segments, 0..) |seg, j| {
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
                                        if (flow.inv().path.module_qualifier) |mq| {
                                            // Use writeModulePath to properly sanitize module references
                                            // (e.g., entry module -> "main_module", "logger" -> "koru_logger")
                                            try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                            try self.code_emitter.write(".");
                                        }
                                        // Join all segments with underscores
                                        for (flow.inv().path.segments, 0..) |seg, idx| {
                                            if (idx > 0) try self.code_emitter.write("_");
                                            try writeMangledSegment(self.code_emitter, seg);
                                        }
                                        // VARIANT SELECTION AT A SUBFLOW HEAD. Only the
                                        // top-level invocation path consulted the registry, so a
                                        // `~[build(x)]std/build:variants` selection was dropped on
                                        // the floor for any call written inside a flow that
                                        // implements another event. Build the canonical key the
                                        // SAME way emitInvocationWithBinding does — module
                                        // qualifier, ':', segments joined by '.', and NO
                                        // main-module fallback, because that is the spelling
                                        // build:variants registers under. A second spelling of
                                        // this key is the bug, not a fix for it.
                                        try self.code_emitter.write("_event.");
                                        const sf_variant: ?[]const u8 = if (flow.inv().variant) |v| v else blk: {
                                            const key = emitter.buildCanonicalEventName(&flow.inv().path, self.allocator, null) catch break :blk null;
                                            defer self.allocator.free(key);
                                            break :blk emitter.getVariant(key);
                                        };
                                        try emitter.writeHandlerName(self.code_emitter, self.allocator, sf_variant);
                                        try self.code_emitter.write("(.{");
                                    }

                                    // Write arguments, mapping from input parameters
                                    // Look up event signature to get parameter names for positional args
                                    const event_canonical_name = try emitter.buildCanonicalEventName(&flow.inv().path, self.allocator, self.main_module_name);
                                    defer self.allocator.free(event_canonical_name);
                                    const event_type = self.type_registry.getEventType(event_canonical_name);
                                    var value_ctx = emitter.EmissionContext{
                                        .allocator = self.allocator,
                                        .main_module_name = self.main_module_name,
                                    };

                                    for (flow.inv().args, 0..) |arg, k| {
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
                                    // OPTIONAL PARAMETER INJECTION — the twin of
                                    // emitArgs's block on the top-level path (400_180):
                                    // an omitted `?T` parameter fills with null here
                                    // too, or the input struct literal is missing a
                                    // field entirely.
                                    if (event_type) |et| {
                                        if (et.input_shape) |shape| {
                                            var emitted_so_far = flow.inv().args.len;
                                            for (shape.fields) |field| {
                                                if (!(field.type.len > 0 and field.type[0] == '?')) continue;
                                                var already_provided = false;
                                                for (flow.inv().args) |arg| {
                                                    if (std.mem.eql(u8, arg.name, field.name)) {
                                                        already_provided = true;
                                                        break;
                                                    }
                                                }
                                                if (already_provided) continue;
                                                if (emitted_so_far > 0) try self.code_emitter.write(",");
                                                try self.code_emitter.write(" .");
                                                try self.code_emitter.write(field.name);
                                                try self.code_emitter.write(" = null");
                                                emitted_so_far += 1;
                                            }
                                        }
                                    }
                                    // NOTE: Comptime injection of program/allocator is now handled
                                    // by emitArgs in emitter_helpers.zig
                                    if (sf_handlers_name) |hname| {
                                        try self.code_emitter.write(" }, ");
                                        try self.code_emitter.write(hname);
                                        try self.code_emitter.write(");\n");
                                    } else {
                                        try self.code_emitter.write(" });\n");
                                    }

                                    // A head with no continuations has no switch to
                                    // consume `result` — discard-guard it (same hygiene
                                    // as nested_result_N in arm emission).
                                    //
                                    // Unless a transform replaced the head with its own
                                    // inline body: then no `const result` was written and
                                    // the guard names something that does not exist. It
                                    // is unreachable code after the dispatch's returns,
                                    // so Zig's only complaint is the undeclared name —
                                    // which lands AFTER a correct router and reads as if
                                    // the router were at fault.
                                    const head_was_replaced = flow.inline_body != null or flow.inv().inline_body != null;
                                    if (flow.body.continuations.len == 0 and flow.inv().return_binding == null and !head_was_replaced) {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("_ = &result;\n");
                                    }

                                    // Bare-return bind at a subflow head
                                    // (`~run-one = create(): r |> work(r)`): alias `result`
                                    // to the call-site binding so downstream steps reference
                                    // it. The head stays `result` for the continuation
                                    // machinery; the alias also marks `result` used.
                                    if (flow.inv().return_binding) |rb| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const ");
                                        try self.code_emitter.write(rb);
                                        try self.code_emitter.write(" = result;\n");
                                    }

                                    // The other spelling of the same head bind — see
                                    // headLabelBindOnBareReturn.
                                    var sf_head_label_conts: ?[]ast.Continuation = null;
                                    if (headLabelBindOnBareReturn(&flow, items_to_search)) |label_bind| {
                                        try self.code_emitter.writeIndent();
                                        try self.code_emitter.write("const ");
                                        try self.code_emitter.write(label_bind);
                                        try self.code_emitter.write(" = result;\n");
                                        sf_head_label_conts = try voidifyHeadLabel(self.allocator, flow.body.continuations);
                                    }

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
                                    const source_event_name = try emitter.buildCanonicalEventName(&flow.inv().path, self.allocator, self.main_module_name);

                                    // Terminal arms only when a Handlers struct took the
                                    // effect arms: those are already emitted as its static
                                    // fns, and a switch prong for `! beat` would name a
                                    // branch Output does not carry.
                                    const sf_switch_conts: []const ast.Continuation = if (sf_handlers_name != null)
                                        sf_terminal_conts.items
                                    else if (sf_head_label_conts) |patched|
                                        patched
                                    else
                                        flow.body.continuations;
                                    try emitter.emitSubflowContinuations(self.code_emitter, sf_switch_conts, 0, indent_str, items_to_search, self.tap_registry, self.type_registry, self.main_module_name, source_event_name, "main_module", event.return_type != null, event);
                                }
                                // Close the self-loop `while (true)` wrapper opened before the
                                // body dispatch. The body always exits via `return` (terminal
                                // branch) or `continue` (tail self-call), so the loop never
                                // falls through; `unreachable` tells Zig that, matching the
                                // `#label` loop termination shape.
                                if (is_self_loop) {
                                    self.code_emitter.indent_level -= 1;
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("}\n");
                                    try self.code_emitter.writeIndent();
                                    try self.code_emitter.write("unreachable;\n");
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

        // THE LOUD HOLE. Nothing implements this event, and an empty body here
        // would have to invent the answer — a value out of nothing, or a choice
        // between outcomes made by taking the first arm. The program is allowed
        // to be built in this state (a scaffold: the whole application written
        // as flow with its boxes still empty, run before anything fills them),
        // but reaching an empty box must be unmissable. Announce and die.
        //
        // The refusal (KORU047) still rejects this at compile time wherever it
        // can see the whole picture; this is what happens where it cannot —
        // most of all in a program carrying test blocks, which stands that
        // refusal down for everything (395_012).
        // `[abstract]` is NOT exempt. The contract that an implementation exists
        // somewhere is checked at the invocation, upstream of the passes that
        // rewrite implementations — and one of those passes can take the
        // implementation away again, which is what resolve_abstract_impl did to
        // every lone implementation until 430_057 pinned it. A guard that runs
        // before the hole can reopen does not guard the hole. This one reads the
        // program actually being emitted, so nothing downstream can outrun it.
        //
        // The exemption used to be justified by 030_016 "calling a dispatch stub
        // during comptime evaluation". It was not: that test's own implementation
        // was the one being renamed away, so it reached this guard because it
        // genuinely had no implementation left. With the pairing fixed it sets
        // found_impl and never arrives here. An abstract with a real
        // implementation behind it cannot reach this line.
        if (!found_impl and ast.stubWouldFabricate(event)) {
            const hole_name = try std.mem.join(self.allocator, ".", event.path.segments);
            defer self.allocator.free(hole_name);
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "koru: reached `{s}`, which nothing implements — this program was built with the box still empty",
                .{hole_name},
            );
            defer self.allocator.free(msg);
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &__koru_event_input;\n");
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("@panic(");
            try self.code_emitter.writeZigStringLiteral(msg);
            try self.code_emitter.write(");\n");
            // A body WAS written; suppress the fabricating placeholder below.
            found_impl = true;
        }

        if (!found_impl) {
            // Add unused parameter suppression
            // Use & to suppress regardless of whether parameter is accessed
            try self.code_emitter.writeIndent();
            try self.code_emitter.write("_ = &__koru_event_input;\n");

            // Effect branches (`!`) lower into the synthesized Handlers struct,
            // NOT Output — so the synthesized default return must use the first
            // TERMINAL branch. For an effect-only event, Output is void (handled
            // by the else). For a template-proc event (e.g. `~for`) this bare
            // handler is never actually called — invocations inline at the call
            // site — but it must still type-check against Output.
            const synth_terminal: ?ast.Branch = blk: {
                for (event.branches) |b| {
                    if (b.kind != .effect) break :blk b;
                }
                break :blk null;
            };
            if (synth_terminal) |first_branch| {

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
                                // Compare base types (strip phantom annotations like <state!>)
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
                    } else if (eql(u8, field_type, "[]const u8") or eql(u8, field_type, "string")) {
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
                        try emitter.writeBranchName(self.code_emitter, field.name);
                        try self.code_emitter.write(" = ");

                        if (can_passthrough) {
                            // Passthrough: use input value
                            try self.code_emitter.write("__koru_event_input.");
                            try emitter.writeBranchName(self.code_emitter, field.name);
                        } else if (eql(u8, field.type, "i32")) {
                            try self.code_emitter.write("0");
                        } else if (eql(u8, field.type, "[]const u8") or eql(u8, field.type, "string")) {
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

        // Emit variant handlers for every Zig-targeted variant proc. Both the bare
        // handler and handler__<variant> coexist in the backend; call sites dispatch via
        // writeHandlerName which mangles to handler__<variant> when invocation.variant is
        // set or getVariant() returns a registered default. Dead-code elimination drops
        // unused variant bodies. (Foreign-language variants like gpu/js are still gated
        // because their bodies are not Zig and would fail compilation.)
        for (items_to_search) |impl_item| {
            switch (impl_item) {
                .proc_decl => |proc| {
                    // Only emit handlers for variant procs whose target differs from
                    // the default lang. The default-lang proc was already emitted as
                    // the main handler above, so skip it here.
                    if (proc.target) |target| {
                        // WHICH TARGET COUNTS AS "THE DEFAULT" DEPENDS ON THE KIND.
                        // A transform's body executes at Stage C — inside koruc,
                        // which is Zig whatever the user asked for — so `|zig` is
                        // its default and every other tag is an alternate. That is
                        // the axis main.zig's dispatcher already uses
                        // (`comptime_default_lang`, main.zig:2047).
                        //
                        // Testing against `self.lang` here asked the wrong question
                        // for transforms: under `--lang=js` it treated a `|js`
                        // transform proc as the default and skipped emitting it,
                        // while the dispatcher had already written a
                        // `handler__js` branch — so the backend referenced a member
                        // that was never generated and failed to compile. A runtime
                        // proc still keys on self.lang, where the user's target IS
                        // the right axis.
                        const is_transform = annotation_parser.hasPart(event.annotations, "transform");
                        const default_target = if (is_transform) "zig" else self.lang;
                        if (eql(u8, target, default_target)) continue;
                        // Foreign-language targets are only safe to emit when explicitly
                        // selected via build:variants (their bodies aren't valid Zig).
                        // TODO(js-emitter): this list is correct only when self.lang == "zig".
                        // When a non-Zig backend is the default, "foreign" should mean
                        // "any variant whose body isn't valid in self.lang." Address in
                        // Move 3 once the JS emitter is real.
                        const foreign_targets = [_][]const u8{ "gpu", "js", "python", "wasm", "glsl" };
                        var is_foreign = false;
                        for (foreign_targets) |ft| {
                            if (eql(u8, target, ft)) {
                                is_foreign = true;
                                break;
                            }
                        }
                        if (is_foreign) {
                            // EXCEPTION: comptime|transform procs have Zig bodies regardless
                            // of their variant tag. The tag on a transform variant selects
                            // what TARGET LANGUAGE the transform's OUTPUT produces
                            // (`|js` = "emit JS output"), but the body itself executes at
                            // Stage C as Zig and is always valid in self.lang. Always emit
                            // these; the runtime registry check (for runtime |js / |gpu /
                            // etc. bodies that ARE foreign code) doesn't apply.
                            if (!is_transform) {
                                const module_for_variant_lookup = self.current_module_name orelse self.main_module_name;
                                const event_canonical = emitter.buildCanonicalEventName(&event.path, self.allocator, module_for_variant_lookup) catch continue;
                                defer self.allocator.free(event_canonical);
                                const is_registered = if (emitter.getVariant(event_canonical)) |rv| eql(u8, rv, target) else false;
                                if (!is_registered) continue;
                            }
                        }

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

                        // MLIR variant: the opaque body is MLIR text compiled AOT
                        // to an object and linked in. Here we emit an `extern fn`
                        // decl (resolved at link time to the symbol the MLIR
                        // func.func lowers to) plus a thin wrapper that calls it.
                        // PoC shape: symbol `koru_mlir_<event-path>`, params = input
                        // fields in order, return = first terminal branch's scalar.
                        const is_mlir_variant = eql(u8, target, "mlir");
                        var mlir_sym: []const u8 = "";
                        var mlir_call_args: []const u8 = "";
                        var mlir_ret_branch: []const u8 = "";
                        if (is_mlir_variant) {
                            var sym_buf = std.ArrayList(u8){};
                            try sym_buf.appendSlice(self.allocator, "koru_mlir_");
                            for (event.path.segments, 0..) |seg, si| {
                                if (si > 0) try sym_buf.append(self.allocator, '_');
                                // Kebab event names are canonical Koru; symbols can't carry '-'.
                                for (seg) |ch| try sym_buf.append(self.allocator, if (ch == '-') '_' else ch);
                            }
                            mlir_sym = try sym_buf.toOwnedSlice(self.allocator);

                            var params_buf = std.ArrayList(u8){};
                            var args_buf = std.ArrayList(u8){};
                            for (event.input.fields, 0..) |ifld, fi| {
                                if (fi > 0) {
                                    try params_buf.appendSlice(self.allocator, ", ");
                                    try args_buf.appendSlice(self.allocator, ", ");
                                }
                                try params_buf.appendSlice(self.allocator, ifld.name);
                                try params_buf.appendSlice(self.allocator, ": ");
                                try params_buf.appendSlice(self.allocator, ifld.type);
                                try args_buf.appendSlice(self.allocator, ifld.name);
                            }
                            mlir_call_args = try args_buf.toOwnedSlice(self.allocator);

                            var mlir_ret_type: []const u8 = "void";
                            for (event.branches) |br| {
                                if (br.kind == .terminal) {
                                    mlir_ret_branch = br.name;
                                    if (br.payload.fields.len >= 1) mlir_ret_type = br.payload.fields[0].type;
                                    break;
                                }
                            }
                            const extern_decl = try std.fmt.allocPrint(self.allocator, "extern fn {s}({s}) {s};\n", .{ mlir_sym, params_buf.items, mlir_ret_type });
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write(extern_decl);
                        }

                        // Emit variant handler. An effect-bearing event's arms are
                        // in scope by bare name inside the body, so a variant
                        // handler needs the SAME `comptime __H: type` parameter and
                        // the same aliases the bare handler binds — it is a
                        // standalone function with no inline-splice site to inherit
                        // them from. Without this an effect arm and a proc variant
                        // could not coexist at all. (370_010)
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("pub fn ");
                        try emitter.writeHandlerName(self.code_emitter, self.allocator, target);
                        if (has_effect) {
                            try self.code_emitter.write("(__koru_event_input: Input, comptime __H: type) Output {");
                        } else {
                            try self.code_emitter.write("(__koru_event_input: Input) Output {");
                        }
                        try emitter.writeVariantComment(self.code_emitter, target);
                        try self.code_emitter.write("\n");
                        self.code_emitter.indent_level += 1;

                        // Generate implicit input bindings
                        for (event.input.fields) |field| {
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("const ");
                            try emitter.writeBranchName(self.code_emitter, field.name);
                            try self.code_emitter.write(" = __koru_event_input.");
                            try emitter.writeBranchName(self.code_emitter, field.name);
                            try self.code_emitter.write(";\n");
                        }
                        // Yielding-branch aliases, identical to the bare handler's.
                        if (has_effect) {
                            for (event.branches) |*b| {
                                if (b.kind != .effect) continue;
                                if (b.is_optional) {
                                    try emitter.emitOptionalArmNullableAlias(self.code_emitter, b, self.main_module_name);
                                    continue;
                                }
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("const ");
                                try emitter.writeBranchName(self.code_emitter, b.name);
                                try self.code_emitter.write(" = __H.");
                                try emitter.writeBranchName(self.code_emitter, b.name);
                                try self.code_emitter.write(";\n");
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = &");
                                try emitter.writeBranchName(self.code_emitter, b.name);
                                try self.code_emitter.write(";\n");
                            }
                        }
                        // Suppress unused variable warnings
                        for (event.input.fields) |field| {
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("_ = &");
                            try emitter.writeBranchName(self.code_emitter, field.name);
                            try self.code_emitter.write(";\n");
                        }
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("_ = &__koru_event_input;\n");

                        // `[template]` procs are rendered per-invocation and inlined
                        // at call sites (Stage C `template_processor`); this decl-site
                        // handler is never called. Its body is template text (`{% %}`,
                        // `{{ }}`), not valid host code — and when this proc lives in
                        // the stdlib/compiler, no Stage-C pass blanks it before Stage-A
                        // emission. Emit an `unreachable` stub instead of the raw template.
                        // The kind is an ANNOTATION, never a variant tag (ruling 2026-08-16).
                        const is_template_variant = blk: {
                            for (proc.annotations) |ann| {
                                if (eql(u8, ann, "template")) break :blk true;
                            }
                            break :blk false;
                        };
                        if (is_template_variant) {
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("unreachable; // [template] proc — inlined at call sites\n");
                        } else if (is_mlir_variant) {
                            // Thin wrapper: call the AOT-linked MLIR symbol, wrap the
                            // scalar result in the terminal branch.
                            if (mlir_ret_branch.len == 0) {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("@compileError(\"MLIR variant PoC supports single terminal-branch scalar events only\");\n");
                            } else {
                                const ret_line = try std.fmt.allocPrint(self.allocator, "return .{{ .{s} = {s}({s}) }};\n", .{ mlir_ret_branch, mlir_sym, mlir_call_args });
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write(ret_line);
                            }
                        } else {
                            // `$mod.` -> bare, exactly as the bare handler and the
                            // other two variant-emission paths do. A variant body
                            // is emitted whether or not it is the SELECTED one, so
                            // skipping the rewrite here left `$mod.` verbatim in
                            // every unselected sibling — invalid Zig that fails the
                            // build on a platform whose variant was never chosen.
                            var variant_proc_body: []const u8 = try emitter.rewriteModToBare(self.allocator, proc.body.text);
                            // Rewrite _ = field to _ = &field (see main handler comment)
                            for (event.input.fields) |field| {
                                const discard_old = try std.fmt.allocPrint(self.allocator, "_ = {s}", .{field.name});
                                const discard_new = try std.fmt.allocPrint(self.allocator, "_ = &{s}", .{field.name});
                                variant_proc_body = try replaceIdentifier(self.allocator, variant_proc_body, discard_old, discard_new);
                            }

                            // Emit proc body
                            var indent_buf: [64]u8 = undefined;
                            var indent_pos: usize = 0;
                            var k: usize = 0;
                            while (k < self.code_emitter.indent_level) : (k += 1) {
                                @memcpy(indent_buf[indent_pos..indent_pos + 4], "    ");
                                indent_pos += 4;
                            }
                            const indent_str = indent_buf[0..indent_pos];
                            try self.code_emitter.emitReindentedText(variant_proc_body, indent_str);
                            try self.code_emitter.write("\n");
                        }

                        // Close variant handler
                        self.code_emitter.indent_level -= 1;
                        try self.code_emitter.writeIndent();
                        try self.code_emitter.write("}\n");
                    }
                },
                else => {},
            }
        }

        // Emit variant handlers for every subflow with impl_variant set.
        // Mirrors the proc-variant emission above but for Koru-transparent bodies.
        // Each `~event|variant = body` declaration produces a handler__<mangled>
        // function on the event struct; call sites dispatch via writeHandlerName.
        for (items_to_search) |impl_item| {
            switch (impl_item) {
                .flow => |flow| {
                    if (flow.impl_variant) |variant| {
                        if (flow.impl_of) |impl_path| {
                            if (impl_path.segments.len != event.path.segments.len) continue;
                            var matches = true;
                            for (impl_path.segments, 0..) |seg, j| {
                                if (!eql(u8, seg, event.path.segments[j])) {
                                    matches = false;
                                    break;
                                }
                            }
                            if (!matches) continue;

                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("pub fn ");
                            try emitter.writeHandlerName(self.code_emitter, self.allocator, variant);
                            try self.code_emitter.write("(__koru_event_input: Input) Output {\n");
                            self.code_emitter.indent_level += 1;

                            if (flow.location.line > 0) {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("// >>> SUBFLOW: ");
                                try self.code_emitter.write(flow.location.file);
                                try self.code_emitter.write(":");
                                var loc_buf: [32]u8 = undefined;
                                const loc_str = try std.fmt.bufPrint(&loc_buf, "{}", .{flow.location.line});
                                try self.code_emitter.write(loc_str);
                                try self.code_emitter.write("  |");
                                try self.code_emitter.write(variant);
                                try self.code_emitter.write("\n");
                            }

                            // Implicit input bindings (mirrors the main handler)
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("const ");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(" = __koru_event_input.");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(";\n");
                            }
                            for (event.input.fields) |field| {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = &");
                                try emitter.writeBranchName(self.code_emitter, field.name);
                                try self.code_emitter.write(";\n");
                            }
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("_ = &__koru_event_input;\n");

                            // Body emission. Supports the simple single-invocation
                            // shape and the transformed shape (inline_body, e.g. a
                            // comptime print as the variant body). Continuations/
                            // preamble still require factoring the main handler's
                            // body-emission into a shared helper — loud guard below.
                            if (flow.body.continuations.len == 0 and flow.preamble_code == null and flow.inline_body != null) {
                                // Transformed variant body: splice the generated
                                // host code directly, same as the main handler's
                                // transformed-flow path.
                                var vindent_buf: [64]u8 = undefined;
                                var vindent_pos: usize = 0;
                                var vidx: usize = 0;
                                while (vidx < self.code_emitter.indent_level) : (vidx += 1) {
                                    @memcpy(vindent_buf[vindent_pos..vindent_pos + 4], "    ");
                                    vindent_pos += 4;
                                }
                                try self.code_emitter.emitReindentedText(flow.inline_body.?, vindent_buf[0..vindent_pos]);
                                try self.code_emitter.write("\n");
                            } else if (flow.body.continuations.len == 0 and flow.preamble_code == null and flow.inline_body == null) {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("_ = ");
                                if (flow.inv().path.module_qualifier) |mq| {
                                    try emitter.writeModulePath(self.code_emitter, mq, self.main_module_name);
                                    try self.code_emitter.write(".");
                                }
                                for (flow.inv().path.segments, 0..) |seg, idx| {
                                    if (idx > 0) try self.code_emitter.write("_");
                                    try writeMangledSegment(self.code_emitter, seg);
                                }
                                try self.code_emitter.write("_event.handler(.{");
                                var value_ctx = emitter.EmissionContext{
                                    .allocator = self.allocator,
                                    .main_module_name = self.main_module_name,
                                };
                                for (flow.inv().args, 0..) |arg, k| {
                                    if (k > 0) try self.code_emitter.write(", ");
                                    try self.code_emitter.write(" .");
                                    try emitter.writeBranchName(self.code_emitter, arg.name);
                                    try self.code_emitter.write(" = ");
                                    try emitter.emitValue(self.code_emitter, &value_ctx, arg.value);
                                }
                                try self.code_emitter.write(" });\n");
                            } else {
                                try self.code_emitter.writeIndent();
                                try self.code_emitter.write("@compileError(\"variant subflow body has continuations/preamble — emission path not yet implemented\");\n");
                            }

                            self.code_emitter.indent_level -= 1;
                            try self.code_emitter.writeIndent();
                            try self.code_emitter.write("}\n");
                        }
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

    /// One `export fn` per entry-module `pub` event, giving the library C
    /// linkage. The wrapper unpacks C parameters into the event's input record
    /// and calls the handler, so a C caller never sees Koru's shapes.
    ///
    /// Three parameter shapes cross: SCALARS as themselves, TEXT as a pointer
    /// and a length, and a NUMERIC BUFFER as a pointer and a length. The last
    /// two are the same move — C has exactly one way to hand over a run of
    /// values it does not own — and a mutable buffer (`[]f32`) is how the
    /// callee writes back, which is the entire calling convention of every
    /// audio and signal-processing C API.
    ///
    /// Everything else is skipped LOUDLY rather than silently: an event
    /// carrying an unrepresentable parameter, or RETURNING text or a buffer
    /// (one return slot cannot carry both a pointer and a length), gets a
    /// comment in the output naming itself, so a caller who cannot find the
    /// symbol reads why instead of guessing.
    fn emitCAbiExports(self: *VisitorEmitter, items: []const ast.Item) !void {
        const entry = self.main_module_name orelse return;
        try self.code_emitter.write("\n// C ABI exports — `koruc lib`\n");
        for (items) |item| {
            if (item != .event_decl) continue;
            const ev = item.event_decl;
            if (!ev.is_public) continue;
            const mq = ev.path.module_qualifier orelse continue;
            if (!std.mem.eql(u8, mq, entry)) continue;
            if (ev.path.segments.len == 0) continue;
            const raw = ev.path.segments[ev.path.segments.len - 1];

            // Text crosses as POINTER AND LENGTH — two C parameters for one
            // Koru one. It is the only shape C has for a run of bytes it does
            // not own: a bare pointer would demand a NUL that Koru never
            // promises, and a struct-by-value would be an ABI of our own
            // invention no caller could write a header for by hand.
            //
            // A RETURN of text has no such answer — one return slot cannot
            // carry two values — so it is refused BY NAME rather than given an
            // out-parameter convention nobody agreed to.
            var unsupported: ?[]const u8 = null;
            for (ev.input.fields) |f| {
                if (!isCAbiScalar(f.type) and !isCAbiText(f.type) and asCAbiBuffer(f.type) == null) {
                    unsupported = f.type;
                }
            }
            const ret = ev.return_type orelse "void";
            if (unsupported == null and !std.mem.eql(u8, ret, "void") and !isCAbiScalar(ret)) unsupported = ret;
            if (unsupported) |t| {
                const note = try std.fmt.allocPrint(self.allocator, "// `{s}` is not exported: type `{s}` has no single C representation\n", .{ raw, t });
                defer self.allocator.free(note);
                try self.code_emitter.write(note);
                continue;
            }

            const name = try self.allocator.alloc(u8, raw.len);
            defer self.allocator.free(name);
            for (raw, 0..) |c, i| name[i] = if (c == '-') '_' else c;

            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(self.allocator);
            const w = line.writer(self.allocator);
            try w.print("export fn {s}(", .{name});
            var first = true;
            for (ev.input.fields) |f| {
                if (!first) try w.writeAll(", ");
                first = false;
                if (isCAbiText(f.type)) {
                    try w.print("{s}_ptr: [*]const u8, {s}_len: usize", .{ f.name, f.name });
                } else if (asCAbiBuffer(f.type)) |b| {
                    try w.print("{s}_ptr: [*]{s}{s}, {s}_len: usize", .{
                        f.name,
                        if (b.is_const) "const " else "",
                        b.elem,
                        f.name,
                    });
                } else {
                    try w.print("{s}: {s}", .{ f.name, f.type });
                }
            }
            try w.print(") {s} {{\n", .{ret});
            try w.writeAll(if (std.mem.eql(u8, ret, "void")) "    " else "    return ");
            try w.print("main_module.{s}_event.handler(.{{", .{name});
            for (ev.input.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                if (isCAbiText(f.type) or asCAbiBuffer(f.type) != null) {
                    try w.print(" .{s} = {s}_ptr[0..{s}_len]", .{ f.name, f.name, f.name });
                } else {
                    try w.print(" .{s} = {s}", .{ f.name, f.name });
                }
            }
            try w.writeAll(" });\n}\n");
            try self.code_emitter.write(line.items);
        }
    }

    /// Koru's surface text type. A slice, so C sees it as two values.
    fn isCAbiText(t: []const u8) bool {
        return std.mem.eql(u8, t, "string");
    }

    const CAbiBuffer = struct { elem: []const u8, is_const: bool };

    /// A run of NUMBERS crosses C exactly the way a run of bytes does: a
    /// pointer and a length. `[]const f32` becomes `[*]const f32` plus a
    /// `usize`; `[]f32` becomes `[*]f32` plus a `usize` and the callee writes
    /// through it. This is the shape every audio and signal-processing C API
    /// in existence already speaks, so it is not a convention of our own — it
    /// is the one C has.
    ///
    /// `u8` is excluded on purpose: a run of bytes is TEXT, it is spelled
    /// `string` in the surface, and `[]const u8` is refused there outright.
    /// Two spellings reaching one C shape would make the exported header
    /// ambiguous about which one a caller was looking at.
    ///
    /// A buffer RETURN is still refused, for the reason text is: one return
    /// slot cannot carry both a pointer and a length, and inventing an
    /// out-parameter convention nobody agreed to is worse than saying no.
    fn asCAbiBuffer(t: []const u8) ?CAbiBuffer {
        if (!std.mem.startsWith(u8, t, "[]")) return null;
        var rest = t[2..];
        var is_const = false;
        if (std.mem.startsWith(u8, rest, "const ")) {
            is_const = true;
            rest = rest[6..];
        }
        if (std.mem.eql(u8, rest, "u8")) return null;
        if (!isCAbiScalar(rest)) return null;
        return .{ .elem = rest, .is_const = is_const };
    }

    fn isCAbiScalar(t: []const u8) bool {
        const ok = [_][]const u8{ "i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "f64", "f32", "bool", "usize", "isize" };
        for (ok) |k| {
            if (std.mem.eql(u8, t, k)) return true;
        }
        return false;
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

        // Host lines an ANCESTOR module already emitted, as a stack pushed on
        // the way down and truncated on the way out. See `hostLineIsShadowable`.
        var ancestor_host_lines: std.ArrayList([]const u8) = .empty;
        defer ancestor_host_lines.deinit(self.allocator);

        for (root.children.items) |child| {
            try self.emitModuleNode(child, 1, module_annotations, &ancestor_host_lines);
        }
    }

    /// Whether a host line an ancestor module already emitted may be dropped
    /// from a nested module rather than emitted again.
    ///
    /// ZIG CONTAINERS DO NOT SHADOW. A declaration in a nested struct that an
    /// enclosing struct also declares is not an override — referencing the name
    /// from inside is `error: ambiguous reference`. But every Koru file writes
    /// its own `const std = @import("std")`, and a submodule is emitted INSIDE
    /// its parent's struct (`mylib.helper` → `koru_mylib.koru_helper`), so a
    /// package whose index and sibling both use the host language could not
    /// compile at all.
    ///
    /// Only a single-line `const <name> = <path>;` qualifies, where <path> is a
    /// pure navigation expression — `@import("std")`, `std.posix`,
    /// `@import("std").mem` — and nothing else. Such a line binds a name to a
    /// namespace, so a byte-identical one in an ancestor names the identical
    /// thing and letting the reference resolve outward is a no-op. Nothing else
    /// is safe to drop:
    ///   - `var` — two same-named `var`s are two distinct pieces of state, and
    ///     collapsing them would silently make the modules share storage.
    ///   - a `const` with any other initializer — a call, an operator, a literal
    ///     can all mean something different in the inner scope.
    ///   - a multi-line blob — a proc body reaches the emitter as one host line
    ///     and can legitimately repeat verbatim, so matching on it would delete
    ///     real code (measured: two identical `const cloned = …` statements in
    ///     one stdlib body, the second one dropped).
    /// Everything else still collides, loudly, which is the right outcome until
    /// the emitter mangles per-module names.
    ///
    /// The head of the path resolving differently in the inner scope is the one
    /// way this could lie, and it cannot happen here: that would require the
    /// inner module to redeclare the head itself, and a redeclaration that is
    /// NOT byte-identical is never dropped — it still collides, loudly.
    fn hostLineIsShadowable(content: []const u8) bool {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "const ")) return false;
        if (std.mem.indexOfScalar(u8, trimmed, '\n') != null) return false;
        if (!std.mem.endsWith(u8, trimmed, ";")) return false;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
        // A declared type (`const x: T = …`) means the author cared about more
        // than the alias; leave it alone.
        if (std.mem.indexOfScalar(u8, trimmed["const ".len..eq], ':') != null) return false;

        var rhs = std.mem.trim(u8, trimmed[eq + 1 .. trimmed.len - 1], " \t");
        if (std.mem.startsWith(u8, rhs, "@import(")) {
            const close = std.mem.indexOfScalar(u8, rhs, ')') orelse return false;
            rhs = rhs[close + 1 ..];
        } else {
            const head_len = identifierLen(rhs);
            if (head_len == 0) return false;
            rhs = rhs[head_len..];
        }
        // Whatever remains must be a chain of `.field` and nothing else.
        while (rhs.len > 0) {
            if (rhs[0] != '.') return false;
            const seg = identifierLen(rhs[1..]);
            if (seg == 0) return false;
            rhs = rhs[1 + seg ..];
        }
        return true;
    }

    fn identifierLen(s: []const u8) usize {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or
                (i > 0 and c >= '0' and c <= '9');
            if (!ok) break;
        }
        return i;
    }

    fn emitModuleNode(
        self: *VisitorEmitter,
        node: *ModuleNode,
        depth: usize,
        module_annotations: []const []const u8,
        ancestor_host_lines: *std.ArrayList([]const u8),
    ) !void {
        // Top-level modules (depth==1) are siblings to main_module, so no indent
        // Nested modules (depth>1) get indented
        if (depth > 1) {
            try self.writeIndent(depth - 1);
        }
        try self.code_emitter.write("pub const ");
        // Phase-controlled wrapper prefix (see codegen_utils.koruWrapperPrefix).
        // Phase 1: only depth==1 (top-level sibling to main_module) gets "koru_".
        // Escape the FULL prefixed name, not just the segment: "switch" would
        // otherwise lower to "koru_@\"switch\"", which Zig rejects because an
        // @\"...\" identifier cannot be glued to a prefix with an underscore.
        const koru_prefix = codegen_utils.koruWrapperPrefix(depth == 1);
        var full_name_buf: [256]u8 = undefined;
        const full_name = std.fmt.bufPrint(&full_name_buf, "{s}{s}", .{ koru_prefix, node.name }) catch node.name;
        if (codegen_utils.needsEscaping(full_name)) {
            try self.code_emitter.write("@\"");
            try self.code_emitter.write(full_name);
            try self.code_emitter.write("\"");
        } else {
            try self.code_emitter.write(full_name);
        }
        try self.code_emitter.write(" = struct {\n");

        // Increase indent level for module contents
        self.code_emitter.indent_level = @intCast(depth);

        // Emit module's own imports and host lines first
        // CRITICAL: If we're emitting this module at all, emit ALL its contents
        // Don't filter individual host lines - the module itself was already filtered
        // This node's own alias lines, staged here and pushed onto the ancestor
        // stack only AFTER the loop: a module may legitimately repeat a line and
        // must not suppress itself — only a STRICT ancestor suppresses.
        const ancestor_mark = ancestor_host_lines.items.len;
        var own_aliases: std.ArrayList([]const u8) = .empty;
        defer own_aliases.deinit(self.allocator);

        for (node.modules.items) |module| {
            for (module.items) |*module_item| {
                // Only emit host lines (including imports) at module level
                if (module_item.* == .host_line) {
                    const line = module_item.host_line;
                    // Route by host language: skip lines whose host isn't Zig
                    // (e.g. a `.kjs` facet of a contract-split module).
                    // Synthesized lines (`file == "generated"`) pass through.
                    if (!hostLineRoutesToZig(line.location.file)) continue;
                    // An enclosing module already declared exactly this — see
                    // hostLineIsShadowable for why re-emitting it is a Zig
                    // compile error and why dropping it is not.
                    if (hostLineIsShadowable(line.content)) {
                        var shadowed = false;
                        for (ancestor_host_lines.items) |seen| {
                            if (std.mem.eql(u8, seen, line.content)) {
                                shadowed = true;
                                break;
                            }
                        }
                        if (shadowed) continue;
                        try own_aliases.append(self.allocator, line.content);
                    }
                    // Emit ALL remaining host lines from the module without filtering
                    // If the module shouldn't be emitted, it wouldn't be in the tree at all
                    try emitter.emitHostLine(self.code_emitter, line.content);
                }
            }
        }
        try ancestor_host_lines.appendSlice(self.allocator, own_aliases.items);

        // Then emit other items (events, procs, etc)
        for (node.modules.items) |module| {
            // Track current module name and Zig prefix for variant registry lookups
            const prev_module_name = self.current_module_name;
            const prev_module_prefix = self.current_module_prefix;
            self.current_module_name = module.logical_name;
            // Build Zig path prefix: "orisha" → "koru_orisha", "std.build" → "koru_std.build"
            // Centralized via codegen_utils so Phase 2 (prefix-every-segment) flips here too.
            const prefix: ?[]const u8 = codegen_utils.buildKoruModulePath(self.allocator, module.logical_name) catch null;
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
            try self.emitModuleNode(child, depth + 1, module_annotations, ancestor_host_lines);
        }

        // Leaving this module: its own host lines stop being ancestors, so a
        // SIBLING module further along still emits its own `const std`.
        ancestor_host_lines.shrinkRetainingCapacity(ancestor_mark);

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
        // LOCAL-FIRST: scan this level's own event decls before recursing
        // into imported modules. An unqualified name that the current level
        // declares resolves locally — an imported module's same-named event
        // must not capture it just because the import appears earlier in the
        // item list (the 120_002 name-priority rule).
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
                else => {},
            }
        }
        for (items) |*item| {
            switch (item.*) {
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

    /// Check if an event has a corresponding proc handler in the AST.
    /// Events like template:define have no proc (handled by the comptime backend),
    /// while events like setup in 210_056 have a proc that needs Zig emission.
    fn eventHasProcHandler(
        self: *VisitorEmitter,
        event_path: *const ast.DottedPath,
    ) bool {
        return self.findProcInItems(self.all_items, event_path, null);
    }

    /// Scalar kinds the thunk boundary marshals this rung. Anything else
    /// keeps the event OUT of the table — the walker's "not in the thunk
    /// table" wall then names it, loudly, at the call site.
    const ThunkScalar = enum { int, float, boolean, string };

    fn thunkScalarOfType(type_text: []const u8) ?ThunkScalar {
        const t = std.mem.trim(u8, type_text, " ");
        if (std.mem.eql(u8, t, "bool")) return .boolean;
        if (std.mem.eql(u8, t, "f64") or std.mem.eql(u8, t, "f32")) return .float;
        if (std.mem.eql(u8, t, "[]const u8") or std.mem.eql(u8, t, "string")) return .string;
        const ints = [_][]const u8{ "i64", "i32", "i16", "i8", "u64", "u32", "u16", "u8", "usize", "isize" };
        for (ints) |it| {
            if (std.mem.eql(u8, t, it)) return .int;
        }
        return null;
    }

    /// True when every input field and every branch payload of `decl` fits
    /// the rung's thunk boundary: scalar params, branches carrying zero or
    /// one scalar field, no `-> T` return, no Source params.
    fn eventIsThunkable(decl: *const ast.EventDecl) bool {
        if (decl.return_type != null) return false;
        for (decl.input.fields) |field| {
            if (field.is_source or field.is_file) return false;
            if (thunkScalarOfType(field.type) == null) return false;
        }
        for (decl.branches) |branch| {
            if (branch.kind != .terminal) return false;
            if (branch.payload.fields.len > 1) return false;
            if (branch.payload.fields.len == 1 and thunkScalarOfType(branch.payload.fields[0].type) == null) return false;
        }
        return true;
    }

    /// Collect the events REACHABLE from interpreter-consumable flows: their
    /// head invocations, everything invoked in their continuation trees, and
    /// — transitively — the bodies of subflow implementations they call.
    /// The thunk table is restricted to this set on purpose: taking &handler
    /// for an event forces Zig to analyze its proc body, and an ill-typed
    /// handler nobody calls at comptime must stay lazily unanalyzed (exactly
    /// as it is for runtime emission) rather than break Stage B.
    fn collectComptimeReachableEvents(self: *VisitorEmitter, set: *std.StringHashMapUnmanaged(void)) !void {
        for (self.all_items) |*item| {
            if (item.* != .flow) continue;
            const flow = &item.flow;
            if (comptime_eval.flowIsInterpreterConsumable(self.all_items, flow) == null) continue;
            try self.collectInvokedEvents(&flow.body, set);
        }
    }

    fn collectInvokedEvents(self: *VisitorEmitter, cont: *const ast.Continuation, set: *std.StringHashMapUnmanaged(void)) !void {
        if (cont.node) |node| {
            const inv: ?*const ast.Invocation = switch (node) {
                .invocation => |*i| i,
                .label_with_invocation => |*lwi| &lwi.invocation,
                else => null,
            };
            if (inv) |i| {
                const name = i.path.segments[i.path.segments.len - 1];
                if (!set.contains(name)) {
                    set.put(self.allocator, name, {}) catch return error.OutOfMemory;
                    if (comptime_eval.findSubflowImpl(self.all_items, &i.path)) |sub| {
                        try self.collectInvokedEvents(&sub.body, set);
                    }
                }
            }
        }
        for (cont.continuations) |*child| {
            try self.collectInvokedEvents(child, set);
        }
    }

    /// THE THUNK LAW, generated (docs/comptime_core_ast_inventory.md §6a):
    /// for each main-module [comptime] event with a proc handler that is
    /// REACHABLE from an interpreter-consumable flow, emit a wrapper
    /// marshalling interpreter Values ↔ the compiled handler's Input/Output
    /// structs, plus the `koru_comptime_thunks` table the fold-comptime pass
    /// hands to the walker. Module-nested events are a later rung (the table
    /// is additive; absence only narrows what comptime code can call).
    fn emitComptimeThunkTable(self: *VisitorEmitter) !void {
        var reachable: std.StringHashMapUnmanaged(void) = .{};
        defer reachable.deinit(self.allocator);
        try self.collectComptimeReachableEvents(&reachable);
        if (reachable.count() == 0) return;

        var thunked = std.ArrayList(*const ast.EventDecl).initCapacity(self.allocator, 8) catch return error.OutOfMemory;
        defer thunked.deinit(self.allocator);
        for (self.all_items) |*item| {
            if (item.* != .event_decl) continue;
            const decl = &item.event_decl;
            if (!reachable.contains(decl.path.segments[decl.path.segments.len - 1])) continue;
            if (!annotation_parser.hasPart(decl.annotations, "comptime")) continue;
            if (!self.eventHasProcHandler(&decl.path)) continue;
            if (!eventIsThunkable(decl)) continue;
            thunked.append(self.allocator, decl) catch return error.OutOfMemory;
        }
        if (thunked.items.len == 0) return;

        try self.code_emitter.write("\n// THE THUNK LAW: comptime-callable events, compiled natively at Stage B,\n");
        try self.code_emitter.write("// dispatched by the Stage C interpreter through koru_comptime_thunks.\n");
        try self.code_emitter.write("const __koru_ce = @import(\"comptime_eval\");\n");

        for (thunked.items) |decl| {
            const name = decl.path.segments[decl.path.segments.len - 1];
            var buf = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch return error.OutOfMemory;
            defer buf.deinit(self.allocator);
            const w = buf.writer(self.allocator);

            w.print("fn __koru_thunk_{s}(__alloc: @import(\"std\").mem.Allocator, __args: []const __koru_ce.ArgValue) __koru_ce.EvalError!__koru_ce.ThunkResult {{\n", .{name}) catch return error.OutOfMemory;
            w.writeAll("    _ = __alloc;\n") catch return error.OutOfMemory;
            if (decl.input.fields.len == 0) {
                w.writeAll("    if (__args.len != 0) return error.UnknownField;\n") catch return error.OutOfMemory;
                w.print("    const __input: main_module.{s}_event.Input = .{{}};\n", .{name}) catch return error.OutOfMemory;
            } else {
                w.print("    var __input: main_module.{s}_event.Input = undefined;\n", .{name}) catch return error.OutOfMemory;
                w.writeAll("    var __bound: usize = 0;\n") catch return error.OutOfMemory;
                w.writeAll("    for (__args) |__a| {\n") catch return error.OutOfMemory;
                for (decl.input.fields) |field| {
                    const kind = thunkScalarOfType(field.type).?;
                    w.print("        if (@import(\"std\").mem.eql(u8, __a.name, \"{s}\")) {{\n", .{field.name}) catch return error.OutOfMemory;
                    switch (kind) {
                        .int => w.print("            __input.{s} = switch (__a.value) {{ .int => |__v| @intCast(__v), else => return error.TypeMismatch }};\n", .{field.name}) catch return error.OutOfMemory,
                        .float => w.print("            __input.{s} = switch (__a.value) {{ .float => |__v| @floatCast(__v), .int => |__v| @floatFromInt(__v), else => return error.TypeMismatch }};\n", .{field.name}) catch return error.OutOfMemory,
                        .boolean => w.print("            __input.{s} = switch (__a.value) {{ .boolean => |__v| __v, else => return error.TypeMismatch }};\n", .{field.name}) catch return error.OutOfMemory,
                        .string => w.print("            __input.{s} = switch (__a.value) {{ .string => |__v| __v, else => return error.TypeMismatch }};\n", .{field.name}) catch return error.OutOfMemory,
                    }
                    w.writeAll("            __bound += 1;\n            continue;\n        }\n") catch return error.OutOfMemory;
                }
                w.writeAll("        return error.UnknownField;\n    }\n") catch return error.OutOfMemory;
                w.print("    if (__bound != {d}) return error.UnknownField;\n", .{decl.input.fields.len}) catch return error.OutOfMemory;
            }

            if (decl.branches.len == 0) {
                // Void handler: side effects only (comptime print, IO).
                w.print("    main_module.{s}_event.handler(__input);\n", .{name}) catch return error.OutOfMemory;
                w.writeAll("    return .{};\n") catch return error.OutOfMemory;
            } else {
                w.print("    const __out = main_module.{s}_event.handler(__input);\n", .{name}) catch return error.OutOfMemory;
                w.writeAll("    switch (__out) {\n") catch return error.OutOfMemory;
                for (decl.branches) |branch| {
                    if (branch.payload.fields.len == 0) {
                        w.print("        .{s} => return .{{ .branch = \"{s}\", .payload = null }},\n", .{ branch.name, branch.name }) catch return error.OutOfMemory;
                    } else {
                        const kind = thunkScalarOfType(branch.payload.fields[0].type).?;
                        const ctor = switch (kind) {
                            .int => ".{ .int = @intCast(__v) }",
                            .float => ".{ .float = @floatCast(__v) }",
                            .boolean => ".{ .boolean = __v }",
                            .string => ".{ .string = __v }",
                        };
                        w.print("        .{s} => |__v| return .{{ .branch = \"{s}\", .payload = {s} }},\n", .{ branch.name, branch.name, ctor }) catch return error.OutOfMemory;
                    }
                }
                w.writeAll("    }\n") catch return error.OutOfMemory;
            }
            w.writeAll("}\n") catch return error.OutOfMemory;
            try self.code_emitter.write(buf.items);
        }

        try self.code_emitter.write("pub const koru_comptime_thunks = [_]__koru_ce.Thunk{\n");
        for (thunked.items) |decl| {
            const name = decl.path.segments[decl.path.segments.len - 1];
            var line = std.ArrayList(u8).initCapacity(self.allocator, 128) catch return error.OutOfMemory;
            defer line.deinit(self.allocator);
            line.writer(self.allocator).print("    .{{ .event_name = \"{s}\", .call = &__koru_thunk_{s} }},\n", .{ name, name }) catch return error.OutOfMemory;
            try self.code_emitter.write(line.items);
        }
        try self.code_emitter.write("};\n");
    }

    fn findProcInItems(
        self: *VisitorEmitter,
        items: []const ast.Item,
        event_path: *const ast.DottedPath,
        current_module: ?[]const u8,
    ) bool {
        for (items) |item| {
            switch (item) {
                .proc_decl => |proc| {
                    if (self.pathsEqualWithModule(&proc.path, event_path, current_module)) {
                        return true;
                    }
                },
                .module_decl => |module| {
                    if (self.findProcInItems(module.items, event_path, module.logical_name)) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
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

        if (flow.inv().path.module_qualifier) |mq| {
            @memcpy(event_name_buf[pos..pos + mq.len], mq);
            pos += mq.len;
            event_name_buf[pos] = ':';
            pos += 1;
        }

        for (flow.inv().path.segments, 0..) |seg, i| {
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
        const event_decl = self.findEventDeclInItems(self.all_items, &flow.inv().path);
        log.debug("  AST event lookup result for '{s}': {}\n", .{event_name, event_decl != null});

        if (event_decl) |decl| {
            // Found event in current AST - check its parameters and annotations directly
            log.debug("  Found event '{s}' in AST, module: '{s}'\n", .{event_name, decl.module});
            log.debug("  Event path segments:", .{});
            for (decl.path.segments) |seg| {
                log.debug(" {s}", .{seg});
            }
            log.debug("\n", .{});

            // A `Program`-typed param (metacircular compiler AST) is genuinely
            // comptime. `Expression`/`Source` are NOT — they are captured
            // strings that can lower to runtime code, so comptime-ness for them
            // is decided by the explicit annotation below.
            for (decl.input.fields) |field| {
                if (std.mem.indexOf(u8, field.type, "Program") != null) {
                    log.debug("  Event has Program (comptime) parameter: {s}\n", .{field.name});
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
                // A `[template]` proc is the one comptime event whose body is
                // NOT produced here: it is rendered per-invocation by the
                // backend's per-call pass. A comptime_flowN would be emitted
                // from the UNRENDERED AST and executed at Stage-C comptime —
                // reaching the decl-site unreachable stub. Such a flow belongs
                // in the RUNTIME emission, where the render already spliced
                // its body. (340_013; ruling 2026-08-16.)
                if (self.eventHasTemplateProc(&decl.path)) {
                    log.debug("  Returning FALSE - event is a [template] proc\n", .{});
                    return false;
                }
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


    /// Does any proc implementing `event_path` carry the `[template]` annotation?
    /// Event-level comptime classification consults proc shape (the same way
    /// `findTransformProc` keys on proc annotations): a template proc renders
    /// per-invocation at the backend, so its flows are runtime-emitted.
    fn eventHasTemplateProc(self: *VisitorEmitter, event_path: *const ast.DottedPath) bool {
        for (self.all_items) |*item| {
            switch (item.*) {
                .proc_decl => |*pd| {
                    if (pd.path.segments.len != event_path.segments.len) continue;
                    var same = true;
                    for (pd.path.segments, event_path.segments) |a, b| {
                        if (!std.mem.eql(u8, a, b)) {
                            same = false;
                            break;
                        }
                    }
                    if (!same) continue;
                    for (pd.annotations) |ann| {
                        if (std.mem.eql(u8, ann, "template")) return true;
                    }
                },
                .module_decl => |*md| {
                    for (md.items) |*mod_item| {
                        if (mod_item.* != .proc_decl) continue;
                        const pd = &mod_item.proc_decl;
                        if (pd.path.segments.len != event_path.segments.len) continue;
                        var same = true;
                        for (pd.path.segments, event_path.segments) |a, b| {
                            if (!std.mem.eql(u8, a, b)) {
                                same = false;
                                break;
                            }
                        }
                        if (same) {
                            for (pd.annotations) |ann| {
                                if (std.mem.eql(u8, ann, "template")) return true;
                            }
                        }
                    }
                },
                else => {},
            }
        }
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
