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
const struct_literal = @import("struct_literal");
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

/// The type→module registry over THIS program's host declarations
/// (type_registry.buildHostTypeHomes) — attached by VisitorEmitter.emit before
/// emission starts. writeFieldType consults it to resolve a bare base type's
/// home from actual declarations (phantom-carrying or not). File-scope like
/// the registries above so every emission path — sub-emitters, test-module
/// subsets — resolves against the same program-wide truth. One program per
/// compiler process.
pub var host_type_homes: ?*const type_registry_module.HostTypeHomes = null;

/// The set-valued counterpart (type_registry.buildHostTypeDeclSites) —
/// attached by VisitorEmitter.emit next to host_type_homes. Module-local-first
/// resolution must ask "does the WRITING module declare this name itself?",
/// which the first-wins map cannot answer on a two-provider collision.
pub var host_type_decl_sites: ?*const type_registry_module.HostTypeDeclSites = null;

/// The module whose code is being emitted right now (a module_decl's
/// logical_name, dotted canon; null = the program's top level). Set around
/// module emission by VisitorEmitter. A KORU115-legal bare host type — the
/// writer declares the name — emits against THIS module's own declaration,
/// never through the first-wins homes map (a consumer's import order must not
/// rewrite a bystander module's own signatures; ruled 2026-09-06,
/// frag-bare-host-type-is-module-local-cross-module-is-qualified).
pub var current_writer_module: ?[]const u8 = null;

/// Module-local bare: does the module being emitted right now declare `base`
/// itself? Set-valued (HostTypeDeclSites), so on a two-provider collision the
/// writer's own declaration still answers yes. Unattached registry → false,
/// which keeps the first-wins homes fallback in charge (unit tests, paths the
/// visitor never armed).
fn writerDeclaresType(base: []const u8) bool {
    const sites = host_type_decl_sites orelse return false;
    const writer = current_writer_module orelse "";
    const decls = sites.get(base) orelse return false;
    for (decls.items) |home| {
        if (type_registry_module.moduleNamesMatch(home, writer)) return true;
    }
    return false;
}

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

/// One member of a mutual-tail-recursion group: the event's canonical name and
/// the Zig enum tag (mangled event path) used as the combined labeled switch's
/// case for this member.
pub const MutualMember = struct {
    canonical: []const u8,
    tag: []const u8,
    event: *const ast.EventDecl,
    flow: *const ast.Flow,
};

/// A cycle of events that tail-forward to each other (`is-even`↔`is-odd`). The
/// whole cycle lowers into ONE labeled switch per member handler
/// (`__koru_self_loop: switch (…entry…) {…}`, arms jumping via
/// `continue :label .<G>`) — the mutual generalization of the self-tail-loop
/// lowering (see `detectMutualGroup` / `emitMutualTailReentry`). Owns its
/// member strings; call `deinit` after the handler is emitted.
pub const MutualGroup = struct {
    members: []MutualMember,

    pub fn tagFor(self: *const MutualGroup, canonical: []const u8) ?[]const u8 {
        for (self.members) |m| {
            if (std.mem.eql(u8, m.canonical, canonical)) return m.tag;
        }
        return null;
    }

    pub fn contains(self: *const MutualGroup, canonical: []const u8) bool {
        return self.tagFor(canonical) != null;
    }

    pub fn deinit(self: *MutualGroup, allocator: std.mem.Allocator) void {
        for (self.members) |m| {
            allocator.free(m.canonical);
            allocator.free(m.tag);
        }
        allocator.free(self.members);
    }
};

/// Emission context - tracks state during code generation
pub const EmissionContext = struct {
    allocator: std.mem.Allocator,
    indent_level: usize = 0,
    flow_counter: usize = 0,
    in_handler: bool = false,
    input_var: ?[]const u8 = null, // "e" for handlers, null for top-level
    input_fields: ?[]const ast.Field = null,
    ast_items: ?[]const ast.Item = null, // Full AST for module resolution
    // Full program item list, used as a fallback when `ast_items` is the
    // module-scoped slice (the subflow-continuation path threads
    // `module.items` for deliberate shadowing, which cannot see cross-module
    // targets like `koru/pcre2:find.all` — 400_198).
    program_items: ?[]const ast.Item = null,
    depth: usize = 0, // Recursion depth for continuation nesting
    flow_pre_label: ?[]const u8 = null, // Label to break for flow termination
    current_label: ?[]const u8 = null, // Current label for continuation-level breaks
    is_sync: bool = false, // true for synchronous inline flows (no try/!)
    tap_registry: ?*tap_registry_module.TapRegistry = null, // Event tap registry for inline emission (mutable for tracking references)
    type_registry: ?*type_registry_module.TypeRegistry = null, // Type registry for array literal type hints
    current_source_event: ?[]const u8 = null, // Canonical name of current source event for tap matching
    current_branch: ?[]const u8 = null, // Current branch name for tap matching
    main_module_name: ?[]const u8 = null, // Main module name for qualifying unqualified events
    module_prefix: []const u8 = "main_module", // Prefix for local event references (e.g., "main_module" or "test_0_module")
    emit_mode: ?EmitMode = null, // Emission mode for filtering taps by phase annotations
    module_annotations: ?[]const []const u8 = null, // Module-level annotations for tap filtering
    skip_tap_inserted_steps: bool = false, // Skip steps inserted by tap transformation (for opaque modules)
    capture_counter: usize = 0, // Counter for unique capture type names (nested captures)
    for_counter: usize = 0, // Counter for unique for loop binding names (nested loops)
    inline_label_counter: usize = 0, // Counter for unique __KORU_INLINE__ label substitution at depth
    proc_label_counter: usize = 0, // Counter for unique __koru_proc_/__koru_eff_disc_ labels (nested inline effectful calls)
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
    // Fork/join: `[parallel]`-marked invocation calls emit as spawned tasks
    // writing slots instead of `const <bind> = handler(...)`. Each spawn
    // records its thread var here; the join emits before the next step that
    // could read the binding (any non-parallel step drains the list).
    pending_parallel: std.ArrayList([]const u8) = .empty,
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
    // ── Mutual-tail-recursion group lowering ─────────────────────────────────
    // When set, the handler body is being emitted inside a combined LABELED
    // SWITCH (`__koru_self_loop: switch (…entry…) {...}`) that covers a whole
    // cycle of events tail-forwarding to each other. A tail continuation that
    // forwards to any member G lowers to `<reassign args>;
    // continue :__koru_self_loop .<G>;` — a direct jump to G's arm — instead
    // of a cross-handler call. See `detectMutualGroup` / `emitMutualTailReentry`.
    // The degenerate 1-cycle (an event forwarding to itself) stays on the
    // `self_loop_*` path.
    mutual_group: ?*const MutualGroup = null,
    // Set when emitting the body of a handler whose event has a bare `-> T`
    // return. A `.expression` produce step (`| big b -> b * 100`) in this
    // context IS the event's return value, so it lowers to `return EXPR;`
    // instead of the generic `_ = EXPR;` discard. (The flat/proc bare-return
    // impls already emit `return` via their own paths; this covers the
    // continuation-HANDLER produce — see 020_025.)
    bare_return_active: bool = false,
    // ── Subflow-implemented effects (400_130-137) ────────────────────────────
    // Set while emitting the body of an impl subflow of an effect-bearing
    // event. Calls to that event's own effect arms — `ping = pong(x)` at the
    // head, `|> each(i)` in a chain — lower to `__H.<arm>(...)`, the
    // consumer's handler-struct fn (the same comptime dispatch a `|zig` proc
    // body reaches through the `const each = __H.each;` aliases). Qualified
    // through `__H` so a Handlers struct synthesized INSIDE this handler
    // (e.g. for a nested `for(..)`) can never shadow the arm name.
    impl_event_decl: ?*const ast.EventDecl = null,
    // Set while emitting a flow-bodied effect event's impl INLINE-spliced into
    // a consumer (renderEffectfulFlowBody) — mirrors `impl_event_decl`'s
    // subflow-implemented-effects role, but for the inline-splice lowering
    // (`emitInlineEffectfulCall`/`InlineEligibility.flow`) rather than the
    // standalone-Handlers-struct-fn path. When set, `emitInvocation`'s
    // impl-fire branch (own-arm calls) emits `__koru_inline_<idx>(payload)`
    // splice markers against THIS slice instead of `__H.<arm>(payload)` calls.
    inline_fire_conts: ?[]const ast.Continuation = null,
    // Resume arms of the arm-fire whose sum is being consumed as `|` branches
    // (`request = ask(payload) | halved v => ... | timeout => ...`). The
    // continuation-switch machinery answers payload questions from this when
    // the branch set isn't an event's (the head is an arm, not an event).
    current_resume_arms: ?[]const ast.ResumeArm = null,
    // Cross-boundary splice hygiene: when a consumer branch binding is
    // site-unique-renamed because it would shadow a producer local in the
    // shared inline-splice frame (400_151), this carries {from: original,
    // to: unique} so the binding's uses in the spliced body rewrite too.
    // Set only around the affected continuation body; honored by emitExpression.
    // A stack, not a slot: a rename deeper in the nest must not mask an
    // enclosing one — references to the outer renamed binding that fell
    // through to the raw name read a producer's live local (silent miscompile).
    splice_binding_renames: std.ArrayList(BindingSubstitution) = .empty,
    // Texts of the splice producers whose frames are still on the emit stack.
    // A binding introduced deeper inside a spliced body shares a Zig frame
    // with every enclosing producer's raw-|zig locals, not only its immediate
    // producer's — the 400_151 rename must consult all of them (605_001:
    // climb's `for (0..w + n) |i|` vs an `! each i` inside the `! pass` body).
    splice_frame_codes: std.ArrayList([]const u8) = .empty,
    // Inline-frame arg bindings currently in scope, pushed by
    // emitInlineEffectfulCall around its spliced body. A nested inlined event
    // that binds the same name to the SAME value expression reuses the
    // enclosing `const` instead of re-binding — two `const n = (3)` frames in
    // nested scopes are a Zig shadowing error (230_015).
    inline_arg_bindings: std.ArrayList(InlineArgBinding) = .empty,
    // Payload-capture names (`for (…) |i|`) declared by enclosing spliced
    // bodies. A nested spliced body declaring the same capture is a Zig
    // "capture shadows capture" error, so uniquifyForCapture renames the
    // inner one — collision-driven, so unnested emission keeps the author's
    // spelling (230_015).
    active_capture_names: std.ArrayList([]const u8) = .empty,
    // User names bound as `const`s at the current Zig function scope (chain
    // return bindings — `get-count(n: 3): v`). An inline frame binding a
    // callee param of the same name would shadow them (400_151), so the frame
    // consults this list and site-unique-renames on collision. Owned dupes;
    // emitFlow save/restores the length around each flow.
    zig_scope_bindings: std.ArrayList([]const u8) = .empty,
    // The event whose body is being emitted, when that body is a FLOW implementing
    // it. A `->` produce naming one of this event's own branches lowers to a
    // tagged return; see `emitBranchProduce`. Kept separate from
    // `impl_event_decl`, which additionally redirects own-arm effect calls.
    produce_event: ?*const ast.EventDecl = null,
};

pub const InlineArgBinding = struct {
    name: []const u8,
    value: []const u8,
    // The name the binding was actually emitted under — differs from `name`
    // when a collision forced a site-unique rename (400_151).
    spelled: []const u8,
    // Whether body references of `name` rewrite to `spelled`. True for a
    // rename or a keyword/primitive escape; false for the kebab mangle, whose
    // textual form (`a-b`) is subtraction in Zig and must not be rewritten.
    rewrites_body: bool,
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

    /// Module-level deferred-declaration channel: emission sites nested
    /// inside a flow fn can route synthesized decls (the captured-binding
    /// `__HandlersCaps_*` factories for effect-arm Handlers structs) here.
    /// The owner flushes it inside `main_module` before the struct closes —
    /// decl order in Zig is lazy, so position in the stream is irrelevant.
    /// Member fns of a module-level struct see only module scope, which is
    /// exactly why these decls must not emit in-function: their bodies'
    /// `const x = __koru_cap_x` aliases would shadow the enclosing fn's
    /// locals and Zig refuses.
    deferred: ?*CodeEmitter = null,

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

    /// Write a line of text with Zig keyword escaping for field access (.keyword -> .@"keyword").
    ///
    /// String-literal content is OPAQUE to escaping: a multiline-string line
    /// (leading `\\`) is written verbatim, and `"..."` / `'...'` spans on
    /// ordinary lines are never rewritten. Proc bodies carry foreign text in
    /// string literals — MLIR (`scf.for`), GLSL, user-facing messages — and
    /// escaping inside them corrupts that text byte-for-byte (the 390_100
    /// `scf.@"for"` corruption that pinned this).
    fn writeLineWithKeywordEscaping(self: *CodeEmitter, line: []const u8) !void {
        // Zig multiline string literal line: everything after `\\` is string
        // content, and `\\` can only be preceded by whitespace on its line.
        const stripped = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, stripped, "\\\\")) {
            try self.write(line);
            return;
        }

        var pos: usize = 0;
        var in_string = false; // inside "..."
        var in_char = false; // inside '...'
        var backslash_escaped = false; // previous char was '\' inside a literal
        while (pos < line.len) {
            const c = line[pos];

            // Inside a string/char literal: copy verbatim, only track the exit.
            if (in_string or in_char) {
                try self.write(line[pos .. pos + 1]);
                if (backslash_escaped) {
                    backslash_escaped = false;
                } else if (c == '\\') {
                    backslash_escaped = true;
                } else if (in_string and c == '"') {
                    in_string = false;
                } else if (in_char and c == '\'') {
                    in_char = false;
                }
                pos += 1;
                continue;
            }
            if (c == '"') {
                in_string = true;
                try self.write(line[pos .. pos + 1]);
                pos += 1;
                continue;
            }
            if (c == '\'') {
                in_char = true;
                try self.write(line[pos .. pos + 1]);
                pos += 1;
                continue;
            }

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

/// Write a field REFERENCE — the name position of `target.field` or
/// `target.field[i]`. The identifier head carries the canonical spelling
/// (writeBranchName); a trailing index suffix is host syntax and passes
/// verbatim, so `arr[i]` and `pos-tempo[i]` both emit correctly.
fn writeFieldRefName(emitter: *CodeEmitter, name: []const u8) !void {
    const head_end = std.mem.indexOfScalar(u8, name, '[') orelse name.len;
    try writeBranchName(emitter, name[0..head_end]);
    try emitter.write(name[head_end..]);
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
                    // Infer alias from path (e.g., "std/build" -> "build")
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
/// Also handles "std/build" format by converting / to .
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

    // Handle paths with / separator (from imports like "std/build")
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

/// True when a Zig type string names a pass-by-value scalar (ints/floats/bool).
/// Pointers, slices, optionals and named aggregates are not scalars.
fn isScalarZigType(t: []const u8) bool {
    if (std.mem.eql(u8, t, "bool") or std.mem.eql(u8, t, "isize") or std.mem.eql(u8, t, "usize")) return true;
    if (std.mem.eql(u8, t, "f16") or std.mem.eql(u8, t, "f32") or std.mem.eql(u8, t, "f64") or std.mem.eql(u8, t, "f128")) return true;
    if (t.len >= 2 and (t[0] == 'i' or t[0] == 'u')) {
        for (t[1..]) |c| if (c < '0' or c > '9') return false;
        return true; // iN / uN
    }
    return false;
}

/// A "scalar value event" has an Input made purely of pass-by-value scalar
/// fields — no Source/Expression/File/InvocationMeta, no phantom, no
/// cross-module type. Its handler can take scalar params (register ABI) through
/// an `inline` forwarding shim instead of a by-pointer Input struct, so
/// multi-field (>16-byte Input) recursive events stop marshalling args through
/// memory on every call. See emitEventDecl's shim emission. Effect-bearing
/// events (`comptime __H`) are excluded by the caller.
pub fn isScalarValueFields(fields: []const ast.Field) bool {
    if (fields.len == 0) return false;
    for (fields) |field| {
        if (field.is_source or field.is_file or field.is_embed_file or
            field.is_expression or field.is_invocation_meta) return false;
        if (field.phantom != null) return false;
        if (field.module_path != null) return false;
        if (!isScalarZigType(field.type)) return false;
    }
    return true;
}

/// Resolve whether a bare base type (pointer/slice prefixes stripped) lives in
/// the phantom's module, by looking its declaration up in the host_type_homes
/// registry. Three outcomes:
///   - declared in the phantom's module (`Field` under module_decl std.field,
///     phantom `std/field:...`) → qualify to that module.
///   - declared anywhere else the registry can see — the program's own top
///     level (`[entity(store)]`'s `pub const Store` alias, 690_037) or another
///     module → the type is NOT the phantom module's; leave unqualified.
///   - not visible at all → the phantom names the only candidate home; qualify.
/// Leading type modifiers, ordered longest-first so `[]const ` and `?*const `
/// win over their `[]`/`?`/`*` components.
const type_prefixes = [_][]const u8{ "[]const ", "?*const ", "*const ", "[]", "?*", "?", "*" };

/// Split a type spelling into its first leading modifier and the rest.
fn splitTypePrefix(type_name: []const u8) struct { prefix: []const u8, base: []const u8 } {
    for (type_prefixes) |prefix| {
        if (std.mem.startsWith(u8, type_name, prefix)) {
            return .{ .prefix = prefix, .base = type_name[prefix.len..] };
        }
    }
    return .{ .prefix = "", .base = type_name };
}

/// The name with every leading modifier stripped (`?*const []Foo` → `Foo`).
fn stripTypePrefixes(type_name: []const u8) []const u8 {
    var base = type_name;
    while (true) {
        const split = splitTypePrefix(base);
        if (split.prefix.len == 0) return base;
        base = split.base;
    }
}

fn phantomModuleIsTypeHome(type_name: []const u8, phantom_mod: []const u8) bool {
    const base = splitTypePrefix(type_name).base;
    const homes = host_type_homes orelse return true;
    const home = homes.get(base) orelse return true;
    return type_registry_module.moduleNamesMatch(home, phantom_mod);
}

/// Does `mod` actually DECLARE this type? The strict inverse of
/// phantomModuleIsTypeHome, which answers "no evidence against" (and so returns
/// true for `i64`, which no module declares). Qualifying needs evidence FOR:
/// a registered host type whose home is this module. Used when a payload type
/// written bare has to be resolved to the module that declared it.
fn moduleDeclaresType(type_name: []const u8, mod: []const u8) bool {
    const base = splitTypePrefix(type_name).base;
    const homes = host_type_homes orelse return false;
    const home = homes.get(base) orelse return false;
    return type_registry_module.moduleNamesMatch(home, mod);
}

/// Emit a `{`-record type text as a Zig anon struct, each field type
/// lowered through writeBareReturnType. parseShape refuses a malformed
/// `{`-type at PARSE003 before emission, so a parseFields failure here is
/// a broken parser contract — `panic_msg` names the caller's context.
fn emitRecordShapeStruct(
    emitter: *CodeEmitter,
    trimmed: []const u8,
    main_module_name: ?[]const u8,
    declaring_module: ?[]const u8,
    panic_msg: []const u8,
) anyerror!void {
    const a = emitter.allocator orelse std.heap.page_allocator;
    if (struct_literal.parseFields(a, trimmed)) |fields| {
        try emitter.write("struct { ");
        for (fields, 0..) |f, i| {
            if (i > 0) try emitter.write(", ");
            try writeBranchName(emitter, f.name);
            try emitter.write(": ");
            try writeBareReturnType(emitter, f.value, main_module_name, declaring_module);
        }
        try emitter.write(" }");
    } else |err| {
        if (err == error.OutOfMemory) return err;
        @panic(panic_msg);
    }
}

/// Helper: Write field type with proper module path handling
pub fn writeFieldType(emitter: *CodeEmitter, field: ast.Field, main_module_name: ?[]const u8) !void {
    // An inline record field type (`user: { x: i64 }`) shares the
    // record-return shape's syntax; emit it as a Zig anon struct with each
    // inner field type lowered through writeBareReturnType — the same
    // lowering `-> { user: { x: i64 } }` already gets, so nested records,
    // `string`, and phantoms lower identically. Pasting the brace text
    // verbatim reached Zig as `@"koru_{ x"` garbage.
    {
        const trimmed = std.mem.trim(u8, field.type, " \t");
        if (trimmed.len > 0 and trimmed[0] == '{') {
            try emitRecordShapeStruct(emitter, trimmed, main_module_name, null, "koru: inline record field type passed parseShape but failed parseFields");
            return;
        }
    }

    // `string` is the canonical surface text type. The AST carries it verbatim
    // so the printer / round-trip stay surface-faithful; it is lowered to the
    // Zig slice `[]const u8` HERE, at the emission boundary, and nowhere
    // earlier. (A JS backend lowers the same surface type to `String`.)
    if (std.mem.eql(u8, field.type, "string")) {
        try emitter.write("[]const u8");
        return;
    } else if (std.mem.eql(u8, field.type, "?string")) {
        // The optional wrapper goes through the same lowering door — a
        // `?string` param must not leak `string` into Zig (400_181, found
        // by ai's `system: ?string`).
        try emitter.write("?[]const u8");
        return;
    } else if (std.mem.startsWith(u8, field.type, "string ") or std.mem.startsWith(u8, field.type, "string=")) {
        // `string = "default"` (field default) -> `[]const u8 = "default"`
        try emitter.write("[]const u8");
        try emitter.write(field.type[6..]);
        return;
    }

    // Nested spellings of the canonical text type (`[]string`, `?[]string`,
    // `[]const string`) lower at the element, mirroring lowerZigType: once the
    // raw byte slice is banned from the surface (510_108), a slice of text can
    // only be spelled with `string` as the element. Every slice level emits
    // const — text is immutable, and the host command ABI hands `argv` over as
    // `[]const []const u8`. A prefixed type whose base is anything else falls
    // through to the module-qualified path below, which re-strips the prefix.
    {
        var i: usize = 0;
        var slices: usize = 0;
        while (true) {
            if (std.mem.startsWith(u8, field.type[i..], "?")) {
                i += 1;
            } else if (std.mem.startsWith(u8, field.type[i..], "[]")) {
                i += 2;
                slices += 1;
                if (std.mem.startsWith(u8, field.type[i..], "const ")) i += 6;
            } else break;
        }
        const rest = field.type[i..];
        const is_bare_string = i > 0 and (std.mem.eql(u8, rest, "string") or
            std.mem.startsWith(u8, rest, "string ") or std.mem.startsWith(u8, rest, "string="));
        if (is_bare_string) {
            var r: usize = 0;
            while (r < i) {
                if (std.mem.startsWith(u8, field.type[r..], "[]")) {
                    try emitter.write("[]const ");
                    r += 2;
                    if (std.mem.startsWith(u8, field.type[r..], "const ")) r += 6;
                } else {
                    try emitter.write(field.type[r .. r + 1]);
                    r += 1;
                }
            }
            try emitter.write("[]const u8");
            try emitter.write(rest["string".len..]);
            return;
        }
    }

    // A bare foreign type carrying a module-qualified phantom (e.g.
    // `*Field<std/field:field>`) has no module_path on the TYPE itself. Its
    // home is resolved from actual declarations via the host_type_homes
    // registry: qualify to the phantom's module only when that module really
    // declares the base type (`*koru_std.koru_field.Field`). A type declared
    // elsewhere — the program's own top level (entity aliases like `Store`,
    // 690_037) or another module — stays unqualified / uses its own
    // module_path: base-type ≠ phantom-state orthogonality.
    const effective_module_path: ?[]const u8 = field.module_path orelse blk: {
        const ph = field.phantom orelse break :blk null;
        const colon = std.mem.indexOfScalar(u8, ph, ':') orelse break :blk null;
        const phantom_mod = ph[0..colon];
        if (phantom_mod.len == 0) break :blk null;
        if (!phantomModuleIsTypeHome(field.type, phantom_mod)) break :blk null;
        break :blk phantom_mod;
    };
    if (effective_module_path) |module_path| {
        // Cross-module type reference: module.path:Type -> prefix + koru_module.path.Type
        // Extract any type prefix (?*, *, [], []const) from the type name
        var type_name = field.type;
        var type_prefix: []const u8 = "";

        const split = splitTypePrefix(type_name);
        type_prefix = split.prefix;
        type_name = split.base;

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

        // HOST HOME: a bare base type some module's host code declares routes
        // to that home — `*Token` (declared in app/holder) →
        // `*koru_app.koru_holder.Token`. Unknown stays unknown (the backend
        // owns it). A top-level ("") home resolves bare and falls through
        // too.
        // MODULE-LOCAL FIRST (ruled 2026-09-06): a bare spelling is legal only
        // inside the module that declares it (KORU115), so when the WRITING
        // module declares the name its own declaration names the emitted home —
        // resolved against the SET of declaring modules, never the first-wins
        // winner. The homes map's first-declaration-wins rule lost its legal
        // customer for bare types with the 220_031 refusal; it stays here as a
        // best-effort aid for positions the scope checker does not see (e.g.
        // proc payloads) and for registries a test armed without decl sites.
        {
            const base = stripTypePrefixes(type_name);
            var base_ok = base.len > 0;
            for (base) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                    base_ok = false;
                    break;
                }
            }
            if (base_ok) {
                if (writerDeclaresType(base)) {
                    if (current_writer_module) |writer| {
                        if (writer.len > 0) {
                            try emitter.write(type_name[0 .. type_name.len - base.len]);
                            try writeModulePath(emitter, writer, main_module_name);
                            try emitter.write(".");
                            try emitter.write(base);
                            return;
                        }
                    }
                    // Top-level writer: its declarations live in file scope —
                    // stay bare, exactly as a first-wins "" home did.
                } else if (host_type_homes) |homes| {
                    if (homes.get(base)) |home| {
                        if (home.len > 0) {
                            try emitter.write(type_name[0 .. type_name.len - base.len]);
                            try writeModulePath(emitter, home, main_module_name);
                            try emitter.write(".");
                            try emitter.write(base);
                            return;
                        }
                    }
                }
            }
        }

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
        const ast_types = [_][]const u8{ "Program", "Item", "Source", "InvocationMeta", "Invocation", "ASTNode", "EventDecl", "ProcDecl", "Flow", "Branch", "Continuation" };
        inline for (ast_types) |ast_type| {
            // FINAL-SEGMENT-AWARE: the AST type must be the LAST identifier
            // segment of the type name — the whole bare name, the word after a
            // pointer prefix (`*const Source`), or a qualified segment
            // (`ast.Flow`). A naive substring match corrupted user type names
            // that merely CONTAIN an AST word — `DefinedFlows` contains "Flow"
            // and became `Defined__koru_ast.Flows` in every emitted signature.
            var seg_start: usize = 0;
            for (type_name, 0..) |c, i| {
                if (c == '.' or c == ':' or c == '*' or c == ' ' or c == '&' or c == '?') seg_start = i + 1;
            }
            const last_seg = type_name[seg_start..];
            if (std.mem.eql(u8, last_seg, ast_type)) {
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
        try writeTypeNameQuoted(emitter, type_name);
    }
}

/// Write a type name, quoting it ONLY if it carries a stamped identity (`#`).
/// The `#` is valid in Koru (the monomorphized-identity marker) but forbidden
/// in Zig type position, so a bare `box#i64` is a syntax error there — it must
/// emit as the quoted `@"box#i64"`. Everything else — plain names, module paths
/// (`std.mem.Allocator`), and Zig type syntax (`[]const u8`, `?T`, `*T`) —
/// contains no `#` and passes through verbatim; quoting them would corrupt
/// valid references. Prefixes pass through so `[]box#i64` lowers to
/// `[]@"box#i64"`, never a mis-quote of the whole (registry rung 1).
fn writeTypeNameQuoted(emitter: *CodeEmitter, name: []const u8) !void {
    if (std.mem.indexOfScalar(u8, name, '#') == null) {
        try emitter.write(name);
        return;
    }
    var base = name;
    var prefix: []const u8 = "";
    const prefixes = [_][]const u8{ "[]const ", "[]", "?*const ", "?*", "*const ", "*", "?" };
    for (prefixes) |c| {
        if (std.mem.startsWith(u8, base, c)) {
            prefix = c;
            base = base[c.len..];
            break;
        }
    }
    const a = emitter.allocator orelse std.heap.page_allocator;
    const quoted = std.fmt.allocPrint(a, "{s}@\"{s}\"", .{ prefix, base }) catch name;
    try emitter.write(quoted);
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
pub fn emitMainModuleStart(emitter: *CodeEmitter, pub_compiler_env: bool, needs_flat_lane_stack: bool) !void {
    try emitter.write("// Access compiler flags via the per-user compiler_env module\n");
    if (pub_compiler_env) {
        try emitter.write("pub const CompilerEnv = @import(\"compiler_env\").CompilerEnv;\n\n");
    } else {
        try emitter.write("const CompilerEnv = @import(\"compiler_env\").CompilerEnv;\n\n");
        // User binaries keep the full traced panic in Debug; every optimized
        // build gets the minimal handler. Zig's default panic pulls the
        // self-hosted DWARF unwinder (std.debug.SelfInfo + std.debug.Dwarf)
        // into the binary — measured 2026-09-14 on games/asteroids: 137KB of
        // __text, 235KB binary → 74KB with simple_panic. The panic message
        // still prints to stderr; only the stack trace is gone, and optimized
        // builds have no debug info for it to print anyway.
        try emitter.write("pub const panic = if (@import(\"builtin\").mode == .Debug)\n");
        try emitter.write("    @import(\"std\").debug.FullPanic(@import(\"std\").debug.defaultPanic)\n");
        try emitter.write("else\n");
        try emitter.write("    @import(\"std\").debug.simple_panic;\n\n");
        // Runtime emission: `Source`-typed fields lower to `__koru_ast.Source`
        // in Input structs and call-site literals. The comptime-mode file
        // already declares this alias (main.zig emits it into
        // backend_output_emitted.zig); declaring it twice is a redecl.
        try emitter.write("const __koru_ast = @import(\"ast\");\n\n");
    }
    // KORU ALLOCATOR SPINE — the one allocator stdlib runtime procs use.
    // Emitted into BOTH outputs so proc bodies (pasted into both) always
    // resolve; only the RUNTIME main() performs the leak check and fails
    // the process (exit 1) on leaks. This is a METER, not a mop: no
    // arenas, no auto-free — real leaks in proc bodies must surface,
    // loudly, in every build mode — that IS the resource-safety claim.
    //
    // Backed by std.heap.c_allocator (real libc malloc/free), NOT
    // DebugAllocator/GeneralPurposeAllocator. MEASURED 2026-06-30 on the
    // prime-sieve drag-race faithful entry (DO droplet, x86_64 Linux):
    // DebugAllocator unconditionally munmaps a bucket's backing page the
    // instant its last live slot is freed (debug_allocator.zig's
    // `free()`: `if (bucket.freed_count == bucket.allocated_count) ...
    // backing_allocator.rawFree(page, ...)`) — every allocate-then-free
    // cycle is a fresh mmap, regardless of size or the configurable
    // `page_size`. Isolated probe: ~120K alloc/free/3s, ~2M page-faults,
    // 80% sys time. Same probe on c_allocator: ~72M alloc/free/3s, 56
    // page-faults total, 0% sys time. DebugAllocator is a debug/bug-hunting
    // tool (return-to-OS-on-empty makes use-after-free reliably segfault),
    // not a throughput allocator — no amount of its own config tuning
    // closes this gap. `__koru_leak_count` is OUR replacement for
    // DebugAllocator's leak tracking: a plain outstanding-allocation
    // counter, checked at exit. What this trades away: DebugAllocator's
    // double-free/invalid-free detection at the allocator layer — Koru's
    // primary defense there is already the phantom obligation system
    // (double-free is a COMPILE-TIME error for well-typed programs), so
    // this is a backstop loss, not a loss of the language's actual
    // safety guarantee.
    // WHICH allocator sits behind that spine is a fact about the TARGET, and
    // the compiler does not know the target — `std/build:config { target }` is
    // read by `zig build`, downstream of here. So the produced program chooses
    // at comptime instead of being told.
    //
    // `c_allocator` cannot even be NAMED on a target without a libc: bare wasm
    // and a freestanding board have no malloc to bind to, so emitting it
    // unconditionally made every such target a compile error in code the user
    // never wrote. `page_allocator` already resolves to Zig's WasmAllocator on
    // a wasm arch (std/heap.zig:349), which is why one fallback covers both.
    //
    // ...covers both WASM targets. It does NOT cover a bare board, and that was
    // measured rather than reasoned: `page_allocator` on `x86_64-freestanding`
    // is its own compile error — "freestanding/other page_size_max must provided
    // with std.options.page_size_max" (std/heap.zig:57), reached through
    // PageAllocator.map. Swapping one refusal for another is not a fallback, so
    // a freestanding target that is not wasm gets a THIRD backing.
    //
    // That third backing is the memory twin of how `std/io` prints there. The
    // printing spine does not port Zig's writer to a machine with no OS; it
    // declares ISO C `fputs` and lets the LINKER resolve it inside the image
    // (koru_std/io.kz:345). Memory takes the identical road: `posix_memalign`
    // and `free` are declared extern and resolved the same way. Measured on the
    // Unikraft 0.21.0 image built by examples/unikraft-net — `nm -g` over its
    // objects shows `T malloc`, `T free`, `T calloc`, `T realloc`,
    // `T posix_memalign`, `T memalign`. The symbols were always there; only an
    // abstraction over them was missing, which is the same sentence the network
    // lift ended up writing.
    //
    // `posix_memalign` and not `malloc`, because the spine's vtable is handed an
    // alignment and `malloc` cannot honour an over-aligned request. The `@max`
    // against `@sizeOf(usize)` is POSIX's own precondition on the argument
    // (alignment must be a power of two AND a multiple of `sizeof(void *)`);
    // Zig's `Alignment` already guarantees the first half.
    //
    // `resize` returns false and `remap` returns null rather than reaching for
    // `realloc`. This is a REFUSAL, not an omission: C's `realloc` makes no
    // promise about preserving alignment, so an over-aligned block could come
    // back merely `malloc`-aligned with nothing reporting it. Declining both
    // makes Zig's allocator interface fall back to alloc-copy-free, which is
    // slower and correct. A `realloc` path that silently drops an alignment
    // guarantee is exactly the shape this file spent four bugs on.
    try emitter.write("const __koru_bare = struct {\n");
    try emitter.write("    extern fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) c_int;\n");
    try emitter.write("    extern fn free(ptr: ?*anyopaque) void;\n");
    try emitter.write("    fn bareAlloc(_: *anyopaque, len: usize, alignment: @import(\"std\").mem.Alignment, _: usize) ?[*]u8 {\n");
    try emitter.write("        var p: ?*anyopaque = null;\n");
    try emitter.write("        const a = @max(alignment.toByteUnits(), @sizeOf(usize));\n");
    try emitter.write("        if (posix_memalign(&p, a, len) != 0) return null;\n");
    try emitter.write("        return @ptrCast(p);\n");
    try emitter.write("    }\n");
    try emitter.write("    fn bareResize(_: *anyopaque, _: []u8, _: @import(\"std\").mem.Alignment, _: usize, _: usize) bool { return false; }\n");
    try emitter.write("    fn bareRemap(_: *anyopaque, _: []u8, _: @import(\"std\").mem.Alignment, _: usize, _: usize) ?[*]u8 { return null; }\n");
    try emitter.write("    fn bareFree(_: *anyopaque, memory: []u8, _: @import(\"std\").mem.Alignment, _: usize) void { free(@ptrCast(memory.ptr)); }\n");
    try emitter.write("    const vtable = @import(\"std\").mem.Allocator.VTable{ .alloc = bareAlloc, .resize = bareResize, .remap = bareRemap, .free = bareFree };\n");
    try emitter.write("    const allocator = @import(\"std\").mem.Allocator{ .ptr = undefined, .vtable = &vtable };\n");
    try emitter.write("};\n");
    try emitter.write("const __koru_backing = if (@import(\"builtin\").link_libc) @import(\"std\").heap.c_allocator else if (@import(\"builtin\").os.tag == .freestanding and !@import(\"builtin\").cpu.arch.isWasm()) __koru_bare.allocator else @import(\"std\").heap.page_allocator;\n");
    try emitter.write("var __koru_leak_count: @import(\"std\").atomic.Value(usize) = .init(0);\n");
    // Fork/join pool: [parallel]-marked calls queue as WaitGroup tasks on a
    // lazily-initialized worker pool (µs-cost queued work, never an OS
    // thread per call — kernel.kz's __koru_pool_ensure pattern, mutex-gated
    // because a spawned worker can itself reach a marked call). The live
    // task count is a best-effort bound: over the cap the call runs inline —
    // work is owed, only width is lost, and correctness never rides on it.
    try emitter.write("var __koru_par_tasks: @import(\"std\").atomic.Value(usize) = .init(0);\n");
    try emitter.write("const __koru_par_CAP: usize = 128;\n");
    // The REAL bound is fork-depth, not live count: a marked call forks only
    // while the fork-tree is shallow, so ~2^DEPTH_CAP coarse tasks exist for
    // an entire run — queue churn (task-count caps let finished tasks free
    // budget, so millions of spawnWg ops roll through) can't happen. This is
    // the frag's cutoff ruling landed as semantics, not a tuning knob.
    try emitter.write("threadlocal var __koru_par_depth: usize = 0;\n");
    try emitter.write("const __koru_par_DEPTH_CAP: usize = 7;\n");
    try emitter.write("var __koru_par_pool: @import(\"std\").Thread.Pool = undefined;\n");
    try emitter.write("var __koru_par_pool_ready: bool = false;\n");
    try emitter.write("var __koru_par_pool_mtx: @import(\"std\").Thread.Mutex = .{};\n");
    try emitter.write("fn __koru_par_pool_ensure() *@import(\"std\").Thread.Pool {\n");
    try emitter.write("    __koru_par_pool_mtx.lock();\n    defer __koru_par_pool_mtx.unlock();\n");
    try emitter.write("    if (!__koru_par_pool_ready) {\n");
    try emitter.write("        @import(\"std\").Thread.Pool.init(&__koru_par_pool, .{ .allocator = @import(\"std\").heap.smp_allocator }) catch @panic(\"koru: thread pool init failed\");\n");
    try emitter.write("        __koru_par_pool_ready = true;\n    }\n");
    try emitter.write("    return &__koru_par_pool;\n}\n");
    try emitter.write("fn __koru_alloc(ctx: *anyopaque, len: usize, alignment: @import(\"std\").mem.Alignment, ret_addr: usize) ?[*]u8 {\n");
    try emitter.write("    _ = ctx;\n");
    try emitter.write("    const r = __koru_backing.rawAlloc(len, alignment, ret_addr);\n");
    try emitter.write("    if (comptime @import(\"builtin\").mode == .Debug) {\n");
    try emitter.write("        if (r != null) _ = __koru_leak_count.fetchAdd(1, .monotonic);\n");
    try emitter.write("    }\n");
    try emitter.write("    return r;\n");
    try emitter.write("}\n");
    try emitter.write("fn __koru_resize(ctx: *anyopaque, memory: []u8, alignment: @import(\"std\").mem.Alignment, new_len: usize, ret_addr: usize) bool {\n");
    try emitter.write("    _ = ctx;\n");
    try emitter.write("    return __koru_backing.rawResize(memory, alignment, new_len, ret_addr);\n");
    try emitter.write("}\n");
    try emitter.write("fn __koru_remap(ctx: *anyopaque, memory: []u8, alignment: @import(\"std\").mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {\n");
    try emitter.write("    _ = ctx;\n");
    try emitter.write("    return __koru_backing.rawRemap(memory, alignment, new_len, ret_addr);\n");
    try emitter.write("}\n");
    try emitter.write("fn __koru_free(ctx: *anyopaque, memory: []u8, alignment: @import(\"std\").mem.Alignment, ret_addr: usize) void {\n");
    try emitter.write("    _ = ctx;\n");
    try emitter.write("    __koru_backing.rawFree(memory, alignment, ret_addr);\n");
    try emitter.write("    if (comptime @import(\"builtin\").mode == .Debug) {\n");
    try emitter.write("        _ = __koru_leak_count.fetchSub(1, .monotonic);\n");
    try emitter.write("    }\n");
    try emitter.write("}\n");
    try emitter.write("const __koru_vtable = @import(\"std\").mem.Allocator.VTable{ .alloc = __koru_alloc, .resize = __koru_resize, .remap = __koru_remap, .free = __koru_free };\n");
    try emitter.write("pub fn koru_allocator() @import(\"std\").mem.Allocator {\n");
    try emitter.write("    return .{ .ptr = undefined, .vtable = &__koru_vtable };\n");
    try emitter.write("}\n\n");
    // `@intCast` in an optimized build emits `llvm.assume(result >= min)` —
    // an operand-fits hint — at the cast SITE, which lands inside the loop
    // body. LLVM's loop vectorizer treats the assume as an opaque call and
    // declines the loop: measured 5.9ms scalar vs 1.5ms vectorized for the
    // same runtime-bound fold (2026-09, koru-benchmarks iteration-models).
    // A same-width signedness flip carries identical bits through `@bitCast`
    // and no assume; checked modes keep the real fit-check panic, and any
    // width change still needs the true `@intCast`.
    try emitter.write("pub inline fn __koru_intcast(comptime T: type, x: anytype) T {\n");
    try emitter.write("    if (comptime (@import(\"builtin\").mode == .Debug or @import(\"builtin\").mode == .ReleaseSafe))\n");
    try emitter.write("        return @as(T, @intCast(x));\n");
    try emitter.write("    const dst = @typeInfo(T);\n");
    try emitter.write("    const src = @typeInfo(@TypeOf(x));\n");
    try emitter.write("    if (comptime (dst == .int and src == .int and dst.int.bits == src.int.bits and dst.int.signedness != src.int.signedness))\n");
    try emitter.write("        return @as(T, @bitCast(x));\n");
    try emitter.write("    return @as(T, @intCast(x));\n");
    try emitter.write("}\n\n");

    // `{{ v:d:N }}` — Koru owns the `d:<digits>` width semantic (ruled
    // 2026-10-24, pinned by 620_005): space-pad left to N columns, sign
    // only when negative — C's `%Nd`, the shape every external oracle
    // (CLBG, PLB nsieve) expects. Zig 0.15's `{d:N}` prints an explicit
    // '+' on positive signed integers, so the `ln`/`blk` transforms wrap
    // the arg as `__koru_pad_i(N, <arg>)` under `{f}` and the padding is
    // decided here, once, in Koru-owned code — not by whichever host the
    // emission target happens to be.
    try emitter.write("fn __KoruPadI(comptime T: type) type {\n");
    try emitter.write("    const V = switch (@typeInfo(T)) { .comptime_int => i64, .comptime_float => f64, else => T };\n");
    try emitter.write("    return struct {\n");
    try emitter.write("        v: V,\n");
    try emitter.write("        width: usize,\n");
    try emitter.write("        pub fn format(self: @This(), w: *@import(\"std\").Io.Writer) @import(\"std\").Io.Writer.Error!void {\n");
    try emitter.write("            const rendered = @import(\"std\").fmt.count(\"{d}\", .{self.v});\n");
    try emitter.write("            const pad = self.width -| rendered;\n");
    try emitter.write("            for (0..pad) |_| try w.writeByte(' ');\n");
    try emitter.write("            try w.print(\"{d}\", .{self.v});\n");
    try emitter.write("        }\n");
    try emitter.write("    };\n");
    try emitter.write("}\n");
    try emitter.write("pub fn __koru_pad_i(width: usize, value: anytype) __KoruPadI(@TypeOf(value)) {\n");
    try emitter.write("    return .{ .v = value, .width = width };\n");
    try emitter.write("}\n\n");

    // THE LEAK CHECK IS A FUNCTION BECAUSE NOT EVERY PROGRAM HAS A `main`.
    //
    // It used to be written inline at the end of the emitted `main`, which is
    // correct for every target that runs one — and silently absent on the target
    // that most needs it. A unikernel supplies its own entry and calls the flows
    // directly (examples/unikraft-net/wrapper.zig), so `main` is dead code there:
    // the check shipped inside every image and never once executed. Zig does not
    // even analyze it, which is the same lazy-analysis blind spot that hid the
    // allocator itself (pinned by 310_122).
    //
    // As a `pub fn` the entry point decides when the run is over, which is the
    // only entity that knows. `main` calls it at exit; a unikernel wrapper calls
    // it when its loop ends; a server may call it per request.
    //
    // ⚠ WHAT THIS REPORTS, AND WHAT IT CANNOT — read before trusting it.
    // It names WHEN, never WHAT. The count is over raw allocations, which carry
    // no type and no owner, so a violation says "something outstanding at this
    // moment" and can name neither the site nor the value. That is a real limit,
    // not a rung: the substrate has nothing to name with.
    //
    // The proofs that DO name things live a level up, where values have owners —
    // an obligation is settled at compile time, and a store with a column it
    // cannot discharge is REFUSED at its declaration rather than counted at the
    // end (690_057/058). This counter is an independent audit OF those proofs,
    // not a substitute for them, and its whole value is being derived from a
    // different mechanism than the thing it checks.
    //
    // ⚠ ZERO IS ONLY UNAMBIGUOUS AT END OF RUN. Do not read this as an
    // assert-zero at an arbitrary boundary: a flow that hands a value onward is
    // *correct* with a nonzero count — 690_057 inserts two transactions into a
    // program-lifetime store, and every allocation is still outstanding when
    // that flow ends. Exit is unambiguous precisely because it is the moment
    // everything must already be gone.
    // ⚠ ON BARE METAL IT MUST SPEAK BEFORE IT HALTS, and that was MEASURED, not
    // reasoned. `@panic` on a freestanding target does not print — Zig's default
    // handler traps, the CPU faults, and Unikraft's handler prints its own crash
    // banner and a register dump. Booted a deliberately-leaking image: it halted
    // in the right place (immediately after the program's own last line) and
    // said NOTHING about a leak. A halt indistinguishable from any other halt is
    // not a report, and on a target with no debugger the report is all there is.
    //
    // So the non-wasm freestanding path writes through the SAME seam printing
    // uses — ISO C `fputs` resolved from the image (koru_std/io.kz:345 takes the
    // identical road) — and only then traps. wasm keeps `@panic`: it has no
    // `fputs` to bind to, and a wasm host surfaces a trap to the embedder rather
    // than to a console, so the message has somewhere else to arrive.
    try emitter.write("pub fn koru_leak_check() void {\n");
    try emitter.write("    if (comptime @import(\"builtin\").mode != .Debug) return;\n");
    try emitter.write("    if (__koru_leak_count.load(.acquire) == 0) return;\n");
    try emitter.write("    if (comptime @import(\"builtin\").target.os.tag == .freestanding) {\n");
    try emitter.write("        if (comptime @import(\"builtin\").cpu.arch == .wasm32 or @import(\"builtin\").cpu.arch == .wasm64) {\n");
    try emitter.write("            @panic(\"KORU LEAK CHECK FAILED: the produced program leaked\");\n");
    try emitter.write("        } else {\n");
    try emitter.write("            const __klc = struct { extern var stdout: ?*anyopaque; extern fn fputs(__s: [*:0]const u8, __st: ?*anyopaque) c_int; };\n");
    try emitter.write("            var __lb: [128]u8 = undefined;\n");
    try emitter.write("            const __lm = \"KORU LEAK CHECK FAILED: allocations still outstanding at end of run: \";\n");
    try emitter.write("            @memcpy(__lb[0..__lm.len], __lm);\n");
    try emitter.write("            var __ln: usize = __lm.len;\n");
    try emitter.write("            var __lv = __koru_leak_count.load(.acquire);\n");
    try emitter.write("            var __ld: [20]u8 = undefined;\n");
    try emitter.write("            var __lk: usize = 0;\n");
    try emitter.write("            while (__lv > 0) : (__lk += 1) { __ld[__lk] = @intCast('0' + __lv % 10); __lv /= 10; }\n");
    try emitter.write("            for (0..__lk) |__li| { __lb[__ln] = __ld[__lk - 1 - __li]; __ln += 1; }\n");
    try emitter.write("            __lb[__ln] = '\\n'; __ln += 1; __lb[__ln] = 0;\n");
    try emitter.write("            _ = __klc.fputs(@as([*:0]const u8, @ptrCast(&__lb)), __klc.stdout);\n");
    try emitter.write("            @trap();\n");
    try emitter.write("        }\n");
    try emitter.write("    } else {\n");
    try emitter.write("        @import(\"std\").debug.print(\"KORU LEAK CHECK FAILED: the produced program leaked (trace above)\\n\", .{});\n");
    try emitter.write("        @import(\"std\").process.exit(1);\n");
    try emitter.write("    }\n");
    try emitter.write("}\n\n");

    // Flat-continuation lane stack — file scope so every flat-emitted handler
    // in the file shares it (a flat handler calling another stays consistent,
    // and each handler restores the pointer it entered with). Emitted only
    // when the module holds a flat-eligible impl — 32MB nobody else should
    // pay for. The stack is lazily mapped with a PROT_NONE tail page, so
    // overflow faults on the guard exactly the way a native stack overflow
    // does — no per-push bounds check in the hot path (measured: a software
    // check costs ~25% on tak).
    if (needs_flat_lane_stack) {
        try emitter.write("// Flat-continuation lanes: uniform [fid][live…] lanes,\n");
        try emitter.write("// guard-paged. See emitFlatHandlerBody/emitFlatSegments.\n");
        try emitter.write("var __koru_cstk: []u64 = &.{};\n");
        try emitter.write("var __koru_csp: usize = 0;\n");
        try emitter.write("fn __koru_flat_init() void {\n");
        try emitter.write("    const __lanes = 1 << 22;\n");
        try emitter.write("    const __page = @import(\"std\").heap.pageSize();\n");
        try emitter.write("    const __mem = @import(\"std\").heap.page_allocator.alignedAlloc(u64, .fromByteUnits(__page), __lanes + __page / @sizeOf(u64)) catch @panic(\"koru: flat continuation stack alloc failed\");\n");
        try emitter.write("    @import(\"std\").posix.mprotect(@alignCast(@import(\"std\").mem.sliceAsBytes(__mem[__lanes..])), @import(\"std\").posix.PROT.NONE) catch @panic(\"koru: flat continuation stack guard failed\");\n");
        try emitter.write("    __koru_cstk = __mem[0..__lanes];\n");
        try emitter.write("}\n\n");
    }

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

/// Append each name not already in `list` — set-build via linear scan.
fn appendUniqueStrings(list: *std.array_list.Managed([]const u8), names: []const []const u8) !void {
    for (names) |name| {
        var found = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                found = true;
                break;
            }
        }
        if (!found) try list.append(name);
    }
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
    try appendUniqueStrings(&all_events, registry_events);
    try appendUniqueStrings(&all_events, ast_events);
    const events = all_events.items;

    // Merge registry branches with AST branches (deduplicated)
    var all_branches = std.array_list.Managed([]const u8).init(allocator);
    defer all_branches.deinit();
    try appendUniqueStrings(&all_branches, registry_branches);
    try appendUniqueStrings(&all_branches, ast_branches);
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

/// Emit `<prefix>.<EnumTag>,` for transitions (enum literal) or
/// `<prefix>"<value>",` otherwise (string literal) — the metatype fork
/// that decides whether a field names a compile-time enum or data.
fn emitEnumOrStringField(
    emitter: *CodeEmitter,
    prefix: []const u8,
    enum_fn: fn (*CodeEmitter, []const u8) anyerror!void,
    value: []const u8,
    is_transition: bool,
) !void {
    try emitter.write(prefix);
    if (is_transition) {
        try emitter.write(".");
        try enum_fn(emitter, value);
        try emitter.write(",\n");
    } else {
        try emitter.write("\"");
        try emitter.write(value);
        try emitter.write("\",\n");
    }
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

/// `.branch` metatype field — enum literal for Transition, string literal
/// for Profile/Audit; an empty branch spells `__void` (void event completion).
fn emitMetatypeBranchField(emitter: *CodeEmitter, is_transition: bool, branch: []const u8) !void {
    if (is_transition) {
        try emitter.write(".branch = .");
        if (branch.len == 0) {
            try emitter.write("__void");
        } else {
            try emitBranchEnumValue(emitter, branch);
        }
        try emitter.write(",\n");
    } else {
        try emitter.write(".branch = \"");
        try emitter.write(if (branch.len == 0) "__void" else branch);
        try emitter.write("\",\n");
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

/// Advance `i` to the next `,` at depth 0 (or to end) — parens, braces,
/// brackets, and double-quoted strings all nest.
fn scanPastTopLevelComma(text: []const u8, i: *usize) void {
    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
    var in_string = false;
    while (i.* < text.len) {
        const c = text[i.*];
        if (!in_string) {
            if (c == '"') in_string = true else if (c == '(') paren_depth += 1 else if (c == ')' and paren_depth > 0) paren_depth -= 1 else if (c == '{') brace_depth += 1 else if (c == '}' and brace_depth > 0) brace_depth -= 1 else if (c == '[') bracket_depth += 1 else if (c == ']' and bracket_depth > 0) bracket_depth -= 1 else if (c == ',' and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                break;
            }
        } else {
            if (c == '"' and (i.* == 0 or text[i.* - 1] != '\\')) in_string = false;
        }
        i.* += 1;
    }
}

/// Index of the first trailing space/tab before `end`, clamped to `start`.
fn trimRightBlank(text: []const u8, start: usize, end: usize) usize {
    var e = end;
    while (e > start and (text[e - 1] == ' ' or text[e - 1] == '\t')) {
        e -= 1;
    }
    return e;
}

/// `indent` + `extra` — nested continuation emission hands each level a
/// longer whitespace run. Growable emitters allocate the run (nested
/// continuation depth has no natural ceiling — a synthesized seed chain
/// is one level per element); fixed-buffer emitters keep the stack path
/// and fail loudly rather than overrunning.
fn indentDeeper(emitter: *CodeEmitter, buf: *[128]u8, indent: []const u8, extra: []const u8) ![]const u8 {
    const total = indent.len + extra.len;
    if (emitter.allocator) |a| {
        const out = try a.alloc(u8, total);
        @memcpy(out[0..indent.len], indent);
        @memcpy(out[indent.len..], extra);
        return out;
    }
    if (total > buf.len) return error.IndentOverflow;
    @memcpy(buf[0..indent.len], indent);
    @memcpy(buf[indent.len..], extra);
    return buf[0..total];
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
// Record-classification predicates now live in struct_literal.zig — the single
// source of truth shared with the parser (which classifies `-> { ... }` produce
// bodies) and every emitter. Aliased so existing call sites read unchanged.
const isKoruStructLiteral = struct_literal.isKoruStructLiteral;
const isFieldPunningLiteral = struct_literal.isFieldPunningLiteral;
const isBracedPlainExpression = struct_literal.isBracedPlainExpression;

/// Emit `{ p.x, p.y }` as `.{ .x = p.x, .y = p.y }`.
fn emitFieldPunningLiteral(emitter: *CodeEmitter, ctx: *EmissionContext, value: []const u8) EmitError!void {
    const inner = value[1 .. value.len - 1];
    try emitter.write(".{");

    var i: usize = 0;
    var first_field = true;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == ',')) {
            i += 1;
        }
        if (i >= inner.len) break;

        const field_start = i;
        var depth: i32 = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            switch (c) {
                '{', '(', '[' => depth += 1,
                '}', ')', ']' => depth -= 1,
                ',' => if (depth == 0) break,
                else => {},
            }
        }
        const field_expr = std.mem.trim(u8, inner[field_start..i], " \t");
        if (field_expr.len == 0) continue;

        const field_name = if (std.mem.lastIndexOf(u8, field_expr, ".")) |dot_idx|
            field_expr[dot_idx + 1 ..]
        else
            field_expr;

        if (!first_field) try emitter.write(", ");
        try emitter.write(" .");
        try writeBranchName(emitter, field_name);
        try emitter.write(" = ");
        try emitValue(emitter, ctx, field_expr);
        first_field = false;
    }

    try emitter.write(" }");
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
            while (i < inner.len and (isIdentChar(inner[i]) or
                (inner[i] == '-' and i + 1 < inner.len and isIdentChar(inner[i + 1]))))
            {
                // Kebab-greedy: an infix `-` joins a Koru name; the write below
                // carries the canonical spelling.
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
                scanPastTopLevelComma(inner, &i);
                const field_value = inner[value_start..trimRightBlank(inner, value_start, i)];

                // Emit .field = value
                if (!first_field) {
                    try emitter.write(",");
                }
                try emitter.write(" .");
                try writeBranchName(emitter, field_name);
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
            } else {
                // Bare entry — a PUN (`{ p.x, p.y }` inside a literal that also
                // carries named fields; all-pun literals route through
                // emitFieldPunningLiteral). Name = last dot segment, value = the
                // whole entry (pun law, struct_literal.zig). 810_122: the mixed
                // `{ a.sum, a.next, isred: 0 }` used to drop both puns and emit
                // only `.{ .isred = 0 }`.
                const entry_start = field_start;
                var depth_p: usize = 0;
                var depth_b: usize = 0;
                var depth_br: usize = 0;
                var in_str = false;
                var entry_end = i;
                while (entry_end < inner.len) {
                    const c = inner[entry_end];
                    if (!in_str) {
                        if (c == '"') in_str = true else if (c == '(') depth_p += 1 else if (c == ')' and depth_p > 0) depth_p -= 1 else if (c == '{') depth_b += 1 else if (c == '}' and depth_b > 0) depth_b -= 1 else if (c == '[') depth_br += 1 else if (c == ']' and depth_br > 0) depth_br -= 1 else if (c == ',' and depth_p == 0 and depth_b == 0 and depth_br == 0) break;
                    } else {
                        if (c == '"' and (entry_end == 0 or inner[entry_end - 1] != '\\')) in_str = false;
                    }
                    entry_end += 1;
                }
                const pun_value = std.mem.trim(u8, inner[entry_start..entry_end], " \t");
                var last_dot: usize = 0;
                var has_dot = false;
                for (pun_value, 0..) |ch, idx| {
                    if (ch == '.') {
                        last_dot = idx;
                        has_dot = true;
                    }
                }
                const pun_name = if (has_dot) pun_value[last_dot + 1 ..] else pun_value;
                if (!first_field) {
                    try emitter.write(",");
                }
                try emitter.write(" .");
                try writeBranchName(emitter, pun_name);
                try emitter.write(" = ");
                try emitValue(emitter, ctx, pun_value);
                first_field = false;
                i = entry_end;
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
        scanPastTopLevelComma(contents, &i);
        const element = contents[elem_start..trimRightBlank(contents, elem_start, i)];

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
    // True when the enclosing handler's event has a bare `-> T` return; makes
    // `.expression` produce arms lower to `return EXPR;` (see EmissionContext).
    enclosing_bare_return: bool,
    enclosing_event: ?*const ast.EventDecl,
    // Non-null when the enclosing handler emits `__koru_self_loop` — see
    // the param on emitSubflowContinuationsWithDepth.
    self_loop_canonical: ?[]const u8,
    // The chain head's `: bind` when the caller emitted the head const under
    // that name — it is in scope for every continuation here, so
    // escapeBoundNames must see it even though it lives on `flow.inv()`,
    // outside this slice.
    head_binding: ?[]const u8,
    // The full program item list — `all_items` is the enclosing module's
    // items slice, which leaves cross-module targets invisible to decl
    // lookups on this path (400_198).
    program_items: []const ast.Item,
) !void {
    const refs_alloc = emitter.allocator orelse std.heap.page_allocator;
    var subtree_refs: SubtreeRefSets = .empty;
    defer freeSubtreeRefSets(refs_alloc, &subtree_refs);
    try buildSubtreeRefSets(refs_alloc, continuations, &subtree_refs);
    try emitSubflowContinuationsWithDepth(emitter, continuations, start_idx, indent, all_items, program_items, 0, tap_registry, type_registry, main_module_name, source_event_name, module_prefix, enclosing_bare_return, enclosing_event, null, self_loop_canonical, head_binding, null, &subtree_refs);
}

/// Same as emitSubflowContinuations, but names the ROOT result const the
/// caller emitted. A chain head with a call-site `: bind` names its const
/// after the bind (coordinate's default `context-create(...): c0 |> ...`),
/// so the depth-0 discard hygiene must reference that name — the bare
/// `result` convention would reference a const that no longer exists.
pub fn emitSubflowContinuationsRooted(
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
    enclosing_bare_return: bool,
    enclosing_event: ?*const ast.EventDecl,
    root_result_name: ?[]const u8,
    self_loop_canonical: ?[]const u8,
    // The full program item list — see emitSubflowContinuations.
    program_items: []const ast.Item,
) !void {
    // The root result name doubles as the head binding for scope collection
    // — both name the same caller-emitted const.
    const refs_alloc = emitter.allocator orelse std.heap.page_allocator;
    var subtree_refs: SubtreeRefSets = .empty;
    defer freeSubtreeRefSets(refs_alloc, &subtree_refs);
    try buildSubtreeRefSets(refs_alloc, continuations, &subtree_refs);
    try emitSubflowContinuationsWithDepth(emitter, continuations, start_idx, indent, all_items, program_items, 0, tap_registry, type_registry, main_module_name, source_event_name, module_prefix, enclosing_bare_return, enclosing_event, root_result_name, self_loop_canonical, null, null, &subtree_refs);
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

/// Does a continuation's step node reference this binding — invocation args
/// (and grafted inline_body), label_with_invocation args, branch-constructor
/// plain value and fields, assignment fields. The direct-step check shared by
/// bindingIsUsedInContinuations and the group-level needs_binding scans.
fn stepReferencesBinding(step: ast.Node, binding_name: []const u8) bool {
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
    return false;
}

/// For every continuation node, the set of names referenced anywhere in its
/// subtree. This used to be answered by rescanning the whole subtree per
/// (binding, continuation-group) pair — and emitSubflowContinuationsWithDepth
/// asks it once per group at every nesting level, so each nested arm's
/// values were re-tokenized once per ancestor group. On a preorder arm over
/// a deep spec tree that compounds to minutes. Building the sets bottom-up
/// once per emitSubflowContinuations entry makes every needs_binding check a
/// lookup: O(subtree) once, not O(groups x subtree).
const SubtreeRefSets = std.AutoHashMapUnmanaged(*const ast.Continuation, *std.StringHashMap(void));

/// Enumerate whole identifiers in `value` outside string literals (the
/// containsIdentifier gate), filter each through valueReferencesBinding so
/// the accepted set is byte-identical to per-name probing, and union the
/// survivors into `set`.
fn collectValueNameRefs(
    allocator: std.mem.Allocator,
    value: []const u8,
    set: *std.StringHashMap(void),
) !void {
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var idx: usize = 0;
    while (idx < value.len) {
        // Skip string literal contents, same as containsIdentifier.
        if (value[idx] == '"') {
            idx += 1;
            while (idx < value.len) {
                if (value[idx] == '\\') {
                    idx += 2;
                } else if (value[idx] == '"') {
                    idx += 1;
                    break;
                } else {
                    idx += 1;
                }
            }
            continue;
        }
        if (isIdentifierChar(value[idx]) and (idx == 0 or !isIdentifierChar(value[idx - 1]))) {
            const start = idx;
            while (idx < value.len and isIdentifierChar(value[idx])) idx += 1;
            const tok = value[start..idx];
            if (!seen.contains(tok)) {
                try seen.put(tok, {});
                if (valueReferencesBinding(value, tok)) {
                    try set.put(tok, {});
                }
            }
        } else {
            idx += 1;
        }
    }
}

/// The set-collecting twin of stepReferencesBinding: same node kinds, same
/// value fields.
fn collectStepNameRefs(
    allocator: std.mem.Allocator,
    step: ast.Node,
    set: *std.StringHashMap(void),
) !void {
    switch (step) {
        .invocation => |inv| {
            for (inv.args) |arg| {
                try collectValueNameRefs(allocator, arg.value, set);
            }
            if (inv.inline_body) |ib| {
                try collectValueNameRefs(allocator, ib, set);
            }
        },
        .label_with_invocation => |lwi| {
            for (lwi.invocation.args) |arg| {
                try collectValueNameRefs(allocator, arg.value, set);
            }
        },
        .branch_constructor => |bc| {
            if (bc.plain_value) |pv| {
                try collectValueNameRefs(allocator, pv, set);
            }
            for (bc.fields) |field| {
                try collectValueNameRefs(allocator, if (field.expression_str) |expr| expr else field.type, set);
            }
        },
        .assignment => |asgn| {
            for (asgn.fields) |field| {
                if (field.expression_str) |expr| {
                    try collectValueNameRefs(allocator, expr, set);
                }
            }
        },
        else => {},
    }
}

/// Post-order pass: set(cont) = step's own refs + union of children's sets.
/// Every descendant of `conts` ends up mapped, so queries inside nested
/// emitSubflowContinuationsWithDepth recursion stay O(#siblings).
fn buildSubtreeRefSets(
    allocator: std.mem.Allocator,
    conts: []const ast.Continuation,
    map: *SubtreeRefSets,
) !void {
    for (conts) |*cont| {
        if (map.contains(cont)) continue;
        try buildSubtreeRefSets(allocator, cont.continuations, map);
        const set = try allocator.create(std.StringHashMap(void));
        set.* = std.StringHashMap(void).init(allocator);
        if (cont.node) |step| {
            try collectStepNameRefs(allocator, step, set);
        }
        for (cont.continuations) |*child| {
            if (map.get(child)) |child_set| {
                var kit = child_set.keyIterator();
                while (kit.next()) |k| try set.put(k.*, {});
            }
        }
        try map.put(allocator, cont, set);
    }
}

fn freeSubtreeRefSets(allocator: std.mem.Allocator, map: *SubtreeRefSets) void {
    var vit = map.valueIterator();
    while (vit.next()) |set_ptr| {
        set_ptr.*.deinit();
        allocator.destroy(set_ptr.*);
    }
    map.deinit(allocator);
}

/// bindingIsUsedInContinuations against the precomputed sets — same answer,
/// no rescan.
fn subtreeReferencesName(ref_sets: *const SubtreeRefSets, conts: []const ast.Continuation, name: []const u8) bool {
    for (conts) |*cont| {
        if (ref_sets.get(cont)) |set| {
            if (set.contains(name)) return true;
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

/// Build a plain-return expression with event-parameter identifiers replaced by
/// call-site argument text (read(s: i.name) → `i.name.data`). The result is
/// fed through emitValue so field-punning/struct-literal lowering still runs.
fn substituteParamNamesInPlainValue(
    allocator: std.mem.Allocator,
    plain_value: []const u8,
    param_names: []const []const u8,
    arg_values: []const []const u8,
) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, plain_value.len);
    errdefer out.deinit(allocator);
    var idx: usize = 0;
    while (idx < plain_value.len) {
        if (plain_value[idx] == '"') {
            try out.append(allocator, plain_value[idx]);
            idx += 1;
            while (idx < plain_value.len) {
                if (plain_value[idx] == '\\') {
                    try out.append(allocator, plain_value[idx]);
                    idx += 1;
                    if (idx < plain_value.len) {
                        try out.append(allocator, plain_value[idx]);
                        idx += 1;
                    }
                } else if (plain_value[idx] == '"') {
                    try out.append(allocator, plain_value[idx]);
                    idx += 1;
                    break;
                } else {
                    try out.append(allocator, plain_value[idx]);
                    idx += 1;
                }
            }
            continue;
        }

        var replaced = false;
        for (param_names, arg_values) |param, arg_val| {
            if (idx + param.len <= plain_value.len and
                std.mem.eql(u8, plain_value[idx .. idx + param.len], param))
            {
                // A `.`-led segment is a member NAME (`r.x`'s `x`), bound to
                // the object it hangs off — never a reference to the param.
                const valid_start = idx == 0 or
                    (!isIdentifierChar(plain_value[idx - 1]) and plain_value[idx - 1] != '.');
                const valid_end = idx + param.len >= plain_value.len or
                    !isIdentifierChar(plain_value[idx + param.len]);
                if (valid_start and valid_end) {
                    // Punned field position — `{ x, y }` — the identifier is
                    // the field name AND the value. Substituting only the text
                    // hands the VALUE to the pun lowering as the field name
                    // (`.{ .10 = 10 }` — 210_025). Expand the pun here so the
                    // name survives the substitution: `x` → `x: <arg>`.
                    const prev_ns: u8 = blk: {
                        var j = out.items.len;
                        while (j > 0) : (j -= 1) {
                            const c = out.items[j - 1];
                            if (c != ' ' and c != '\t' and c != '\n') break :blk c;
                        }
                        break :blk 0;
                    };
                    const next_ns: u8 = blk: {
                        var j = idx + param.len;
                        while (j < plain_value.len) : (j += 1) {
                            const c = plain_value[j];
                            if (c != ' ' and c != '\t' and c != '\n') break :blk c;
                        }
                        break :blk 0;
                    };
                    // A `:`-led identifier is a LABEL — the record field's or
                    // arg's own name (`{ x: <expr> }`, `f(x: <expr>)`), spelled
                    // by the subflow's produce/arg vocabulary, not a reference
                    // to the param. Substituting the call-site text here rewrites
                    // the field's NAME (`{ r.x: r.x + 1 }` → the pun lowerer reads
                    // `r.x:` as a pun and emits `.@"x + 1" = r.x: r.x + 1` —
                    // 230_032). Paste the label through untouched.
                    if (next_ns == ':') {
                        try out.appendSlice(allocator, param);
                        idx += param.len;
                        replaced = true;
                        break;
                    }
                    if ((prev_ns == '{' or prev_ns == ',') and (next_ns == ',' or next_ns == '}')) {
                        try out.appendSlice(allocator, param);
                        try out.appendSlice(allocator, ": ");
                    }
                    try out.appendSlice(allocator, arg_val);
                    idx += param.len;
                    replaced = true;
                    break;
                }
            }
        }
        if (replaced) continue;

        try out.append(allocator, plain_value[idx]);
        idx += 1;
    }
    return try out.toOwnedSlice(allocator);
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

/// Expand a subflow `|*` residual into switch arms for each unhandled optional
/// branch of `source_event_name`. Top-level `emitContinuationList` already does
/// this; without it here, event bodies emit a literal `.@"*"` arm (355_011).
fn emitSubflowCatchallOptionalArms(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    indent: []const u8,
    catchall: *const ast.Continuation,
    branch_groups: []const BranchGroup,
    source_event_name: ?[]const u8,
    all_items: []const ast.Item,
    main_module_name: ?[]const u8,
    result_counter: *usize,
) !void {
    var handled_branches = std.StringHashMap(void).init(ctx.allocator);
    defer handled_branches.deinit();
    for (branch_groups) |group| {
        if (std.mem.eql(u8, group.branch_name, "*")) continue;
        try handled_branches.put(group.branch_name, {});
    }

    const source_event = source_event_name orelse return;
    const event_decl = findEventByName(all_items, source_event, ctx.allocator, main_module_name) orelse return;

    for (event_decl.branches) |branch| {
        if (!branch.is_optional) continue;
        if (handled_branches.contains(branch.name)) continue;

        try emitter.write(indent);
        try emitter.write("    .");
        try writeBranchName(emitter, branch.name);
        try emitter.write(" => |_| {\n");

        const old_indent = emitter.indent_level;
        emitter.indent_level = 0;
        try emitContinuationBody(emitter, ctx, catchall, result_counter);
        emitter.indent_level = old_indent;

        try emitter.write(indent);
        try emitter.write("    },\n");
    }
}

/// The target event's input fields, resolved the way the subflow arg writer
/// resolves them: module-scoped AST first, then the global type registry for
/// cross-module targets (all_items may be module-scoped here). Null when
/// neither route knows the event.
fn resolveTargetInputFields(
    all_items: []const ast.Item,
    inv: *const ast.Invocation,
    type_registry: *type_registry_module.TypeRegistry,
    main_module_name: ?[]const u8,
) ?[]const ast.Field {
    if (findEventDeclByPath(all_items, &inv.path)) |target_decl| return target_decl.input.fields;
    // Registry fallback keys MUST come from buildCanonicalEventName — a
    // hand-rolled join misses its normalizations and silently resolves
    // nothing (the first spelling of this fn did exactly that, and the
    // injection quietly skipped: kopium's `multi.new()` in a `| row` arm).
    const key = buildCanonicalEventName(&inv.path, std.heap.page_allocator, main_module_name) catch return null;
    defer std.heap.page_allocator.free(key);
    if (type_registry.getEventType(key)) |et| {
        if (et.input_shape) |shape| return shape.fields;
    }
    return null;
}

/// True when `name` is already bound at the call site — every inject path
/// (optional-null sweep, program/allocator/InvocationMeta) scans this before
/// deciding to emit a default.
fn argProvided(args: []const ast.Arg, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg.name, name)) return true;
    }
    return false;
}

/// `_ = &name;` — discard a step result the pipeline doesn't read, emitted
/// identically after every bare-invocation step in loop/branch bodies.
fn emitDiscardedResultRef(emitter: *CodeEmitter, result_name: []const u8) !void {
    try emitter.writeIndent();
    try emitter.write("_ = &");
    try writeBranchName(emitter, result_name);
    try emitter.write(";\n");
}

/// Emit `: <type>` for the arg's matching input field — file/source fields
/// spell `[]const u8`, everything else goes through writeFieldType.
/// Returns whether the field was found (callers panic differently).
fn writeArgFieldTypeAnnotation(emitter: *CodeEmitter, event: *const ast.EventDecl, arg_name: []const u8, main_module_name: ?[]const u8) !bool {
    for (event.input.fields) |field| {
        if (std.mem.eql(u8, field.name, arg_name)) {
            try emitter.write(": ");
            if (field.is_file or field.is_embed_file) {
                try emitter.write("[]const u8");
            } else if (field.is_source) {
                try emitter.write("[]const u8");
            } else {
                try writeFieldType(emitter, field, main_module_name);
            }
            return true;
        }
    }
    return false;
}

/// Emit `, .name = null` for every `?T` input field the call site omitted —
/// an optional parameter's default IS null, and the target's input struct
/// would be missing the field entirely (400_180).
fn emitMissingOptionalArgs(emitter: *CodeEmitter, fields: []const ast.Field, args: []const ast.Arg) !void {
    var needs_sep = args.len > 0;
    for (fields) |field| {
        if (!(field.type.len > 0 and field.type[0] == '?')) continue;
        if (argProvided(args, field.name)) continue;
        if (needs_sep) try emitter.write(", ");
        try emitter.write(".");
        try writeBranchName(emitter, field.name);
        try emitter.write(" = null");
        needs_sep = true;
    }
}

/// Collect every name a continuation tree binds — `: bind` return bindings and
/// `| x` payload bindings — into `out`. The subflow-continuations path keeps
/// no EmissionContext, so the set escapeBoundNames rewrites against has to be
/// gathered from the AST. Over-collects deliberately: a name bound in a later
/// sibling subtree cannot be referenced by earlier text, so including it
/// costs nothing.
fn collectBoundNames(allocator: std.mem.Allocator, continuations: []const ast.Continuation, out: *std.ArrayList([]const u8)) !void {
    for (continuations) |*cont| {
        if (cont.binding) |b| {
            try out.append(allocator, b);
        }
        if (cont.node) |node| {
            if (node == .invocation) {
                if (node.invocation.return_binding) |rb| {
                    try out.append(allocator, rb);
                }
            }
        }
        try collectBoundNames(allocator, cont.continuations, out);
    }
}

/// `_ = &<parent-result>;` for a void `|>` step: the parent step's result
/// const is in scope but unconsumed, so it must be discarded or Zig rejects
/// the emit. Named by caller override, `result` at depth 0, else
/// `nested_result_{depth-1}`.
fn emitParentResultDiscard(
    emitter: *CodeEmitter,
    indent: []const u8,
    parent_result_name: ?[]const u8,
    depth: usize,
) !void {
    try emitter.write(indent);
    if (parent_result_name) |prn| {
        // A `: _` discard bound no const — nothing to re-discard. `_ = &_;`
        // would be an illegal identifier reference, not a discard.
        if (std.mem.eql(u8, prn, "_")) return;
        try emitter.write("_ = &");
        try writeBranchName(emitter, prn);
        try emitter.write(";\n");
    } else if (depth == 0) {
        try emitter.write("_ = &result;\n");
    } else {
        var buf: [48]u8 = undefined;
        const discard = try std.fmt.bufPrint(&buf, "_ = &nested_result_{d};\n", .{depth - 1});
        try emitter.write(discard);
    }
}

/// A fresh EmissionContext for a detached continuation-body emit — the
/// ambient plumbing shared by emitSubflowContinuationsWithDepth's bail
/// paths and emitVoidStepViaContinuationBody.
fn detachedEmissionContext(
    all_items: []const ast.Item,
    program_items: []const ast.Item,
    tap_registry: ?*tap_registry_module.TapRegistry,
    type_registry: *type_registry_module.TypeRegistry,
    main_module_name: ?[]const u8,
    source_event_name: ?[]const u8,
    enclosing_bare_return: bool,
    enclosing_event: ?*const ast.EventDecl,
    self_loop_canonical: ?[]const u8,
) EmissionContext {
    return .{
        .allocator = std.heap.page_allocator, // temp allocator for result vars
        .indent_level = 0, // Will use emitter's indent
        .ast_items = all_items,
        .program_items = program_items,
        .is_sync = true,
        .tap_registry = tap_registry,
        .type_registry = type_registry,
        .main_module_name = main_module_name,
        .current_source_event = source_event_name,
        .bare_return_active = enclosing_bare_return,
        .produce_event = enclosing_event,
        // An enclosing `__koru_self_loop` survives this bail: arm bodies
        // re-enter emitContinuationBody, whose self-tail checkpoint reads
        // these flags to emit reassign+`continue` instead of a nested
        // handler() call (which would leave the label unused — 320_150).
        .self_loop_active = self_loop_canonical != null,
        .self_loop_event_canonical = self_loop_canonical,
    };
}

/// Route a void-chain step through emitContinuationBody when the simple
/// step-switch can't lower it (`.label_with_invocation`, an `inline_body`
/// invocation, …). Shared tail of the bail sites: discard the parent result,
/// build a fresh sync ctx carrying this scope's bindings and label contexts,
/// run the body emitter at indent 0.
fn emitVoidStepViaContinuationBody(
    emitter: *CodeEmitter,
    cont: *const ast.Continuation,
    indent: []const u8,
    all_items: []const ast.Item,
    program_items: []const ast.Item,
    depth: usize,
    tap_registry: ?*tap_registry_module.TapRegistry,
    type_registry: *type_registry_module.TypeRegistry,
    main_module_name: ?[]const u8,
    source_event_name: ?[]const u8,
    enclosing_bare_return: bool,
    enclosing_event: ?*const ast.EventDecl,
    self_loop_canonical: ?[]const u8,
    local_bindings: *const std.ArrayList([]const u8),
    parent_result_name: ?[]const u8,
) !void {
    try emitParentResultDiscard(emitter, indent, parent_result_name, depth);
    var ctx = detachedEmissionContext(
        all_items,
        program_items,
        tap_registry,
        type_registry,
        main_module_name,
        source_event_name,
        enclosing_bare_return,
        enclosing_event,
        self_loop_canonical,
    );
    ctx.zig_scope_bindings.items = local_bindings.items;
    var label_counter: usize = depth;
    const old_indent = emitter.indent_level;
    emitter.indent_level = 0;
    try emitContinuationBody(emitter, &ctx, cont, &label_counter);
    emitter.indent_level = old_indent;
}

fn emitSubflowContinuationsWithDepth(
    emitter: *CodeEmitter,
    continuations: []const ast.Continuation,
    start_idx: usize,
    indent: []const u8,
    all_items: []const ast.Item,
    // The full program item list — `all_items` is the enclosing module's
    // items slice (deliberate shadowing), which leaves cross-module targets
    // invisible to decl lookups on this path (400_198).
    program_items: []const ast.Item,
    depth: usize,
    tap_registry: ?*tap_registry_module.TapRegistry,
    type_registry: *type_registry_module.TypeRegistry,
    main_module_name: ?[]const u8,
    source_event_name: ?[]const u8,
    module_prefix: []const u8,
    enclosing_bare_return: bool,
    enclosing_event: ?*const ast.EventDecl,
    // Actual name of the parent step's result when it deviates from the
    // `result`/`nested_result_{depth-1}` formula — a `: bind` names the parent
    // const after the bind, and every formula-derived discard here would
    // otherwise reference a nonexistent variable.
    parent_result_name: ?[]const u8,
    // Canonical event name when the enclosing handler was lowered to
    // `__koru_self_loop: while (true)` (same signal EmissionContext
    // carries as self_loop_active/self_loop_event_canonical — this path
    // has no ctx, so it arrives as a param). A call-result arm whose body
    // is a tail self-call must emit reassign+`continue`, not a nested
    // `handler()` call — the call would leave the loop label unreferenced
    // and Zig rejects the emit (320_150).
    self_loop_canonical: ?[]const u8,
    // The chain head's `: bind`, when one exists and lives outside the
    // continuations slice (on the flow's head invocation). Same reason as
    // ancestor_bindings — the name is in scope here but unreachable by
    // collectBoundNames.
    head_binding: ?[]const u8,
    // Names bound by ancestor continuations — appended to, never popped. This
    // path keeps no EmissionContext, so the in-scope set escapeBoundNames
    // needs is collected from the AST instead of read off ctx.
    ancestor_bindings: ?*const std.ArrayList([]const u8),
    // Per-node referenced-name sets covering this chain's whole subtree —
    // built once at the emitSubflowContinuations entry, so needs_binding
    // checks are lookups instead of subtree rescans.
    subtree_refs: *const SubtreeRefSets,
) !void {
    if (start_idx >= continuations.len) return;

    // A `: _` discard is not a name — callers can propagate `return_binding`
    // verbatim, and "_" here would mint `_ = &_;`, which is not legal Zig.
    const parent_result_name_norm = if (parent_result_name) |p|
        (if (std.mem.eql(u8, p, "_")) null else p)
    else
        null;
    const head_binding_norm = if (head_binding) |h|
        (if (std.mem.eql(u8, h, "_")) null else h)
    else
        null;

    const bindings_alloc = emitter.allocator orelse std.heap.page_allocator;
    var local_bindings: std.ArrayList([]const u8) = .empty;
    defer local_bindings.deinit(bindings_alloc);
    if (ancestor_bindings) |ab| {
        try local_bindings.appendSlice(bindings_alloc, ab.items);
    }
    try collectBoundNames(bindings_alloc, continuations, &local_bindings);
    if (parent_result_name_norm) |prn| {
        try local_bindings.append(bindings_alloc, prn);
    }
    if (head_binding_norm) |hb| {
        try local_bindings.append(bindings_alloc, hb);
    }
    var local_ctx = EmissionContext{
        .allocator = bindings_alloc,
        .main_module_name = main_module_name,
        .type_registry = type_registry,
    };
    // Share the slice only: an append on this list would have to realloc into
    // a buffer local_bindings no longer owns. Nothing downstream appends —
    // emitInvocation's binding registration rides the real ctx, not this one.
    local_ctx.zig_scope_bindings.items = local_bindings.items;

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
                try emitVoidStepViaContinuationBody(emitter, cont, indent, all_items, program_items, depth, tap_registry, type_registry, main_module_name, source_event_name, enclosing_bare_return, enclosing_event, self_loop_canonical, &local_bindings, parent_result_name_norm);
                return;
            }
        }

        // A void step whose invocation carries a rendered template body
        // (`inline_body`, e.g. a comptime `print`) — or any node the simple
        // step-switch below can't lower — must go through emitContinuationBody,
        // whose line ~8594 routes `inline_body` through `emitInlineBodyNode` (the
        // SAME helper the return-switch path bails to at ~2450). The simple-step
        // path below emits a raw `_event.handler(...)` call and DROPS the template
        // body — this is the `read: text |> print` residue inside a synthesized
        // query/watch handler body (690_060): the print was transformed and the
        // `__kw` interpolation attached, but the void-chain emitter never emitted it.
        if (continuationsHaveReturnSwitchUnemittable(remaining_conts)) {
            try emitVoidStepViaContinuationBody(emitter, cont, indent, all_items, program_items, depth, tap_registry, type_registry, main_module_name, source_event_name, enclosing_bare_return, enclosing_event, self_loop_canonical, &local_bindings, parent_result_name_norm);
            return;
        }

        // An invocation step targeting a tor with `!` effect branches —
        // e.g. `| ok acc |> take(): buf |> find.all(...) ! match m … | done …`
        // — cannot lower here. The simple step-switch below has no Handlers
        // synthesis or inline splice: with `!` arms it emits
        // `handler(input, struct {})` and drops the effect arm into the result
        // switch, where the tor's Output union has no such tag; with no `!`
        // arms it emits a 1-arg `handler(input)` against a 2-arg signature
        // (400_198). emitContinuationBody partitions the effect conts into the
        // synthesized Handlers struct / inline splice and leaves the terminal
        // conts for the result switch — the same treatment emitFlow gives the
        // head invocation.
        if (cont.node) |effect_step| {
            if (effect_step == .invocation) {
                const target_declares_effect = blk: {
                    for (cont.continuations) |c| {
                        if (c.kind == .effect) break :blk true;
                    }
                    if (findEventDeclByPath(all_items, &effect_step.invocation.path)) |td| {
                        for (td.branches) |*b| {
                            if (b.kind == .effect) break :blk true;
                        }
                        break :blk false;
                    }
                    // Module-scoped `all_items` can't see cross-module
                    // targets — the type registry (program-wide) answers the
                    // same question.
                    const key = buildCanonicalEventName(&effect_step.invocation.path, std.heap.page_allocator, main_module_name) catch break :blk false;
                    defer std.heap.page_allocator.free(key);
                    if (type_registry.getEventType(key)) |et| break :blk et.has_effect_branches;
                    break :blk false;
                };
                if (target_declares_effect) {
                    try emitVoidStepViaContinuationBody(emitter, cont, indent, all_items, program_items, depth, tap_registry, type_registry, main_module_name, source_event_name, enclosing_bare_return, enclosing_event, self_loop_canonical, &local_bindings, parent_result_name_norm);
                    return;
                }
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

        // Discard the parent step's result const before emitting THIS step. The
        // parent is `result` at depth 0, `nested_result_{depth-1}` otherwise (or
        // `parent_result_name` when the parent was a `: bind`). A void `|>` step
        // is a fresh call that never consumes the parent's value, so the parent
        // const is left dangling unless discarded here — a terminal void tail
        // (neither switch-assigned nor bind-named) hit exactly this gap and left
        // the head's `const result` unused (690_029: a two-write `removed`
        // interceptor `alive - 1 |> kills + 1` → Zig "unused local constant").
        // Fire in all three sub-cases below (switch-assign / bind-rename / plain
        // void): the name selection always targets an in-scope const — both
        // depth-0 callers of emitSubflowContinuations emit `const result` first
        // (top-level chains use emitFlow and never reach here), and depth only
        // increments via `next_needs_switch`, which emits `const nested_result_
        // {depth}` — so it can never name a nonexistent variable. `_ = &x;` is
        // idempotent, so re-discarding a parent a later step also uses is safe.
        try emitParentResultDiscard(emitter, indent, parent_result_name_norm, depth);

        // Emit the step if present
        if (cont.node) |step| {
            switch (step) {
                .invocation => |inv| {
                    try emitter.write(indent);
                    if (inv.return_binding) |rb| {
                        // Bare-return mid-chain bind (`mk(): v |> consume(v)`): bind
                        // the produced value so downstream steps can reference it,
                        // instead of discarding the result with `_ =`. A `: _`
                        // capture IS that discard — `const _ = ` is not legal Zig.
                        if (std.mem.eql(u8, rb, "_")) {
                            try emitter.write("_ = ");
                        } else {
                            try emitter.write("const ");
                            try writeBranchName(emitter, rb);
                            try emitter.write(" = ");
                        }
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
                        // A Koru array literal `[a, b]` needs its element type from
                        // the target event's field to become `&[_]T{ a, b }` — raw
                        // passthrough is a Zig syntax error. all_items may be
                        // module-scoped here, so cross-module targets resolve via
                        // the (global) type registry's canonical key.
                        const av = std.mem.trim(u8, arg.value, " \t");
                        if (av.len >= 2 and av[0] == '[' and av[av.len - 1] == ']') {
                            const field: *const ast.Field = blk: {
                                if (findEventDeclByPath(all_items, &inv.path)) |target_decl| {
                                    for (target_decl.input.fields) |*f| {
                                        if (std.mem.eql(u8, f.name, arg.name)) break :blk f;
                                    }
                                }
                                var name_buf: [512]u8 = undefined;
                                var pos: usize = 0;
                                if (inv.path.module_qualifier) |mq| {
                                    @memcpy(name_buf[pos .. pos + mq.len], mq);
                                    pos += mq.len;
                                    name_buf[pos] = ':';
                                    pos += 1;
                                } else if (main_module_name) |mmn| {
                                    @memcpy(name_buf[pos .. pos + mmn.len], mmn);
                                    pos += mmn.len;
                                    name_buf[pos] = ':';
                                    pos += 1;
                                }
                                pos = inv.path.writeSegments(&name_buf, pos);
                                if (type_registry.getEventType(name_buf[0..pos])) |et| {
                                    if (et.input_shape) |shape| {
                                        for (shape.fields) |*f| {
                                            if (std.mem.eql(u8, f.name, arg.name)) break :blk f;
                                        }
                                    }
                                }
                                return error.ArrayLiteralMissingType;
                            };
                            var lit_ctx = EmissionContext{
                                .allocator = std.heap.page_allocator,
                                .main_module_name = main_module_name,
                                .type_registry = type_registry,
                            };
                            lit_ctx.zig_scope_bindings.items = local_bindings.items;
                            try emitArrayLiteralForField(emitter, &lit_ctx, field, av);
                        } else {
                            try emitter.write(lowerExprZig(emitter, &local_ctx, arg.value));
                        }
                    }
                    // OPTIONAL PARAMETER INJECTION — the twin of emitArgs's
                    // block on the top-level path (400_180): an omitted `?T`
                    // parameter fills with null here too, or the target's
                    // input struct is missing a field entirely.
                    if (resolveTargetInputFields(all_items, &inv, type_registry, main_module_name)) |target_fields| {
                        try emitMissingOptionalArgs(emitter, target_fields, inv.args);
                    }
                    // An effect-carrying target's handler takes `(Input,
                    // comptime __H)` — pass the empty Handlers type when this
                    // raw-call site installs no arms (optional arms fold to
                    // noops; a mandatory arm was refused upstream, KORU022).
                    const target_takes_handlers = blk: {
                        if (findEventDeclByPath(all_items, &inv.path)) |td| {
                            for (td.branches) |*b| {
                                if (b.kind == .effect) break :blk true;
                            }
                            break :blk false;
                        }
                        const key = buildCanonicalEventName(&inv.path, std.heap.page_allocator, main_module_name) catch break :blk false;
                        defer std.heap.page_allocator.free(key);
                        if (type_registry.getEventType(key)) |et| break :blk et.has_effect_branches;
                        break :blk false;
                    };
                    if (target_takes_handlers) {
                        try emitter.write(" }, struct {});\n");
                    } else {
                        try emitter.write(" });\n");
                    }
                },
                .branch_constructor => |bc| {
                    // Terminal - emit return
                    try emitter.write(indent);
                    if (bc.is_bare_return) {
                        // Bare-return produce arm (`head(): v -> expr`): return the
                        // value directly with no tag — the twin of the flat
                        // `~e -> expr` impl. branch_name is empty here, so the
                        // tagged form below would emit malformed `return .{ . = v }`.
                        // Route through emitValue so a Koru record literal
                        // `{ f: v }` lowers to `.{ .f = v }` instead of raw Zig.
                        try emitter.write("return ");
                        if (bc.plain_value) |pv| {
                            var val_ctx = EmissionContext{
                                .allocator = std.heap.page_allocator,
                                .main_module_name = main_module_name,
                                .type_registry = type_registry,
                            };
                            val_ctx.zig_scope_bindings.items = local_bindings.items;
                            try emitBareReturnProduce(emitter, &val_ctx, pv, if (enclosing_event) |ee| ee.return_type else null);
                        } else {
                            try emitter.write("undefined");
                        }
                        try emitter.write(";\n");
                    } else {
                        try emitter.write("return ");
                        try emitBranchConstructor(emitter, &local_ctx, &bc, true);
                        try emitter.write(";\n");
                    }
                },
                else => {},
            }
        }

        // Recurse for nested continuations. Bump depth only when we assigned a
        // result above, so the recursive switch picks up our `nested_result_{depth}`
        // via its own `nested_result_{(depth+1) - 1}` lookup.
        if (cont.continuations.len > 0) {
            const step_bind: ?[]const u8 = if (cont.node) |st|
                (if (st == .invocation) st.invocation.return_binding else null)
            else
                null;
            // The child's switch scrutinee is THIS step's fresh
            // `nested_result_{depth}`, so its payload checks must name this
            // step's event — not the chain head's, which drops `|bind|`
            // captures whenever a nested union shares an arm name with a
            // payload-free arm on an ancestor result.
            const child_source_event: ?[]const u8 = blk: {
                if (!next_needs_switch) break :blk null;
                if (cont.node) |st| {
                    if (st == .invocation) break :blk buildCanonicalEventName(&st.invocation.path, bindings_alloc, main_module_name) catch null;
                }
                break :blk null;
            };
            defer if (child_source_event) |cse| bindings_alloc.free(cse);
            try emitSubflowContinuationsWithDepth(
                emitter,
                cont.continuations,
                0,
                indent,
                all_items,
                program_items,
                if (next_needs_switch) depth + 1 else depth,
                tap_registry,
                type_registry,
                main_module_name,
                child_source_event orelse source_event_name,
                module_prefix,
                enclosing_bare_return,
                enclosing_event,
                // A bind-named step is the new parent; a switch-assigned step
                // follows the formula (pass null); otherwise the parent is
                // unchanged at this level.
                step_bind orelse (if (next_needs_switch) null else parent_result_name_norm),
                self_loop_canonical,
                null,
                &local_bindings,
                subtree_refs,
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
        var ctx = detachedEmissionContext(
            all_items,
            program_items,
            tap_registry,
            type_registry,
            main_module_name,
            source_event_name,
            enclosing_bare_return,
            enclosing_event,
            self_loop_canonical,
        );
        ctx.zig_scope_bindings.items = local_bindings.items;
        var result_counter: usize = depth;
        const result_var = if (depth == 0) "result" else blk: {
            var buf: [32]u8 = undefined;
            break :blk try std.fmt.bufPrint(&buf, "nested_result_{d}", .{depth - 1});
        };

        // Sole `|*` (all optional): no "*" union field — discard and run body.
        if (remaining_conts.len == 1 and
            remaining_conts[0].is_catchall and
            std.mem.eql(u8, remaining_conts[0].branch, "*") and
            remaining_conts[0].catchall_metatype == null)
        {
            try emitter.write(indent);
            try emitter.write("_ = &");
            try writeBranchName(emitter, result_var);
            try emitter.write(";\n");
            const old_indent = emitter.indent_level;
            emitter.indent_level = 0;
            try emitContinuationBody(emitter, &ctx, &remaining_conts[0], &result_counter);
            emitter.indent_level = old_indent;
            return;
        }

        // Group continuations by branch name to handle when-clauses
        const normal_branch_groups = try groupContinuationsByBranch(std.heap.page_allocator, continuations[start_idx..]);
        defer {
            for (normal_branch_groups) |group| {
                std.heap.page_allocator.free(group.continuations);
            }
            std.heap.page_allocator.free(normal_branch_groups);
        }

        var catchall_cont: ?*const ast.Continuation = null;
        for (remaining_conts) |*cont| {
            if (cont.is_catchall) {
                catchall_cont = cont;
                break;
            }
        }

        // Emit normal switch statement (NOT return switch)
        try emitter.write(indent);
        try emitter.write("switch (");
        try emitter.write(result_var);
        try emitter.write(") {\n");

        // Emit each branch group
        for (normal_branch_groups) |group| {
            // `|*` expands below — never emit a literal "*" arm
            if (std.mem.eql(u8, group.branch_name, "*")) continue;

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
                    needs_binding = subtreeReferencesName(subtree_refs, cont.continuations, binding_name);
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
                    try writeBranchName(emitter, binding_name);
                    try emitter.write(";\n");
                }

                // Use emitContinuationBody which handles labels!
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
                        needs_binding = stepReferencesBinding(step, binding_name);
                    }
                    // Also check nested continuations
                    if (!needs_binding) {
                        needs_binding = subtreeReferencesName(subtree_refs, cont.continuations, binding_name);
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
                        try emitter.write(lowerExprZig(emitter, &local_ctx, condition));
                        try emitter.write(") {\n");
                    } else {
                        // No when-clause - this is the else case
                        try emitter.write("else {\n");
                    }

                    // Emit continuation body
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

        if (catchall_cont) |catchall| {
            try emitSubflowCatchallOptionalArms(
                emitter,
                &ctx,
                indent,
                catchall,
                normal_branch_groups,
                source_event_name,
                all_items,
                main_module_name,
                &result_counter,
            );
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

    // Sole `|*` on the return-switch path
    if (remaining_conts.len == 1 and
        remaining_conts[0].is_catchall and
        std.mem.eql(u8, remaining_conts[0].branch, "*") and
        remaining_conts[0].catchall_metatype == null)
    {
        const result_var = if (depth == 0) "result" else blk: {
            var buf: [32]u8 = undefined;
            break :blk try std.fmt.bufPrint(&buf, "nested_result_{d}", .{depth - 1});
        };
        try emitter.write(indent);
        try emitter.write("_ = &");
        try writeBranchName(emitter, result_var);
        try emitter.write(";\n");
        var ctx_sole = detachedEmissionContext(
            all_items,
            program_items,
            tap_registry,
            type_registry,
            main_module_name,
            source_event_name,
            enclosing_bare_return,
            enclosing_event,
            self_loop_canonical,
        );
        ctx_sole.zig_scope_bindings.items = local_bindings.items;
        var result_counter_sole: usize = depth;
        try emitContinuationBody(emitter, &ctx_sole, &remaining_conts[0], &result_counter_sole);
        return;
    }

    var catchall_cont_ret: ?*const ast.Continuation = null;
    for (remaining_conts) |*cont| {
        if (cont.is_catchall) {
            catchall_cont_ret = cont;
            break;
        }
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
        if (std.mem.eql(u8, group.branch_name, "*")) continue;

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
                needs_binding = stepReferencesBinding(step, actual_binding);
            }

            // CRITICAL: Also check if binding is used in nested continuations!
            // Example: | created s |> ... nested ... |> assemble(sun: s.sun, ...)
            //          The binding 's' is used deep in nested continuations!
            if (!needs_binding and cont.continuations.len > 0) {
                needs_binding = subtreeReferencesName(subtree_refs, cont.continuations, actual_binding);
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

                // An arm whose step invokes a `!`-carrying event and arms one
                // of those effects — `| go |> source() ! data d |> …` — cannot
                // take the raw call+switch below: the call goes out as
                // `handler(input, struct {})` and the `!` arm lands in the
                // result switch on a variant the event's Output does not
                // carry. emitContinuationBody partitions the effect arms into
                // the synthesized Handlers struct and leaves terminal arms for
                // the result switch — the same treatment the void-chain check
                // gives a `!`-armed non-head step (400_198) and emitFlow gives
                // the head invocation (400_175).
                var step_effect_routed = false;
                if (cont.node) |arm_step| {
                    if (arm_step == .invocation) {
                        for (cont.continuations) |c| {
                            if (c.kind == .effect) {
                                try emitVoidStepViaContinuationBody(emitter, &cont, indent, all_items, program_items, depth, tap_registry, type_registry, main_module_name, source_event_name, enclosing_bare_return, enclosing_event, self_loop_canonical, &local_bindings, parent_result_name_norm);
                                step_effect_routed = true;
                                break;
                            }
                        }
                    }
                }

                // Self-tail reentry inside a call-result arm: `| boom f |>
                // self(args)` whose children forward the result. Detection
                // (flowContainsSelfTailForward) counts this site and the
                // caller wrapped the handler in `__koru_self_loop: while
                // (true)`; a plain nested `handler()` call here would leave
                // the label unreferenced and Zig rejects the emit (320_150).
                // Same lowering emitContinuationBody's checkpoint performs —
                // reassign the `var` inputs and `continue` the loop.
                var self_reentry_emitted = false;
                if (self_loop_canonical) |canonical| {
                    var reentry_ctx = EmissionContext{
                        .allocator = std.heap.page_allocator,
                        .main_module_name = main_module_name,
                    };
                    if (continuationIsSelfTailForwarder(&cont, canonical, &reentry_ctx)) {
                        // emitTailReargs indents via emitter.indent_level;
                        // align it with the arm-body depth this function
                        // writes through the `indent` param.
                        const saved_indent_level = emitter.indent_level;
                        emitter.indent_level = @intCast(indent.len / emitter.indent_size + 2);
                        defer emitter.indent_level = saved_indent_level;
                        try emitSelfTailReentry(emitter, &reentry_ctx, &cont);
                        self_reentry_emitted = true;
                    }
                }

                if (!self_reentry_emitted and !step_effect_routed) {
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
                            if (inv.return_binding) |rb| {
                                // Bare-return bind on the arm's step (`| tag b |> f(): v |> ...`):
                                // downstream chain steps reference `v`, so the result
                                // must be declared under the bind name, not nested_result_N.
                                // A `: _` capture IS the discard — `const _ = ` is not legal Zig.
                                if (std.mem.eql(u8, rb, "_")) {
                                    try emitter.write("        _ = ");
                                } else {
                                    try emitter.write("        const ");
                                    try writeBranchName(emitter, rb);
                                    try emitter.write(" = ");
                                }
                            } else {
                                const var_name = try std.fmt.bufPrint(&buf, "        const nested_result_{d} = ", .{depth + step_idx});
                                try emitter.write(var_name);
                            }

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
                            event_name_pos = inv.path.writeSegments(&event_name_buf, event_name_pos);
                            const event_canonical = event_name_buf[0..event_name_pos];
                            const event_type = type_registry.getEventType(event_canonical);
                            var value_ctx = EmissionContext{
                                .allocator = std.heap.page_allocator,
                                .main_module_name = main_module_name,
                            };
                            value_ctx.zig_scope_bindings.items = local_bindings.items;

                            for (inv.args, 0..) |arg, idx| {
                                if (idx > 0) try emitter.write(", ");
                                try emitter.write(" .");

                                // Resolve the parameter this arg binds: a bare pun names
                                // its field even when appended late; index is the fallback
                                // for a name that is no field (ast.resolveArgParamName).
                                const param_name = blk: {
                                    if (event_type) |et| {
                                        if (et.input_shape) |shape| {
                                            break :blk ast.resolveArgParamName(arg, idx, shape.fields);
                                        }
                                    }
                                    // Fallback: use arg.name (might produce invalid Zig)
                                    break :blk arg.name;
                                };

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
                                    try emitter.write(lowerExprZig(emitter, &local_ctx, arg.value));
                                }
                            }
                            // OPTIONAL PARAMETER INJECTION — the third copy of
                            // emitArgs's rule (400_180): omitted `?T` params
                            // fill with null on the arm-step path too.
                            if (event_type) |et| {
                                if (et.input_shape) |shape| {
                                    try emitMissingOptionalArgs(emitter, shape.fields, inv.args);
                                }
                            }
                            // An effect-carrying target's handler takes
                            // `(Input, comptime __H)`. This raw-call path
                            // installs no effect arms, so an empty struct is
                            // the honest __H: optional arms fold to noops and
                            // a mandatory arm was already refused upstream
                            // (KORU022) before emission.
                            const target_takes_handlers = blk: {
                                if (findEventDeclByPath(all_items, &inv.path)) |td| {
                                    for (td.branches) |*b| {
                                        if (b.kind == .effect) break :blk true;
                                    }
                                    break :blk false;
                                }
                                if (event_type) |et| break :blk et.has_effect_branches;
                                break :blk false;
                            };
                            if (target_takes_handlers) {
                                try emitter.write(" }, struct {});\n");
                            } else {
                                try emitter.write(" });\n");
                            }

                            // Suppress unused variable warning (result might not be used, e.g., for taps)
                            try emitter.write(indent);
                            if (inv.return_binding) |rb| {
                                // `: _` already discarded the call result inline
                                // — there is no const to mark used.
                                if (!std.mem.eql(u8, rb, "_")) {
                                    try emitter.write("        _ = &");
                                    try writeBranchName(emitter, rb);
                                    try emitter.write(";\n");
                                }
                            } else {
                                const suppress_unused = try std.fmt.bufPrint(&buf, "        _ = &nested_result_{d};\n", .{depth + step_idx});
                                try emitter.write(suppress_unused);
                            }
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
                            // Transition: .source = .compiler_context_create (enum literal)
                            // Profile/Audit: .source = "main:http.request" (string literal)
                            try emitEnumOrStringField(emitter, "            .source = ", canonicalNameToEnumTag, mb.source_event, is_transition);

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
                            try emitter.write("            ");
                            try emitMetatypeBranchField(emitter, is_transition, mb.branch);

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
                                const deeper_indent = try indentDeeper(emitter, &deeper_indent_buf, indent, "            ");
                                try emitSubflowContinuationsWithDepth(emitter, cont.continuations, 0, deeper_indent, all_items, program_items, last_result_idx + 1, tap_registry, type_registry, main_module_name, source_event_name, module_prefix, enclosing_bare_return, enclosing_event, if (cont.node) |st| (if (st == .invocation) st.invocation.return_binding else null) else null, self_loop_canonical, null, &local_bindings, subtree_refs);
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
                                try emitter.write(lowerExprZig(emitter, &local_ctx, pv));
                            } else {
                                try emitter.write(".{");
                                for (bc.fields, 0..) |field, idx| {
                                    if (idx > 0) try emitter.write(", ");
                                    try emitter.write(" .");
                                    try writeBranchName(emitter, field.name);
                                    try emitter.write(" = ");
                                    if (field.expression_str) |expr| {
                                        try emitter.write(lowerExprZig(emitter, &local_ctx, expr));
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
                    const deeper_indent = try indentDeeper(emitter, &deeper_indent_buf, indent, "        ");
                    // The nested chain switches on THIS step's
                    // `nested_result_{last_result_idx}` — payload checks below
                    // name this step's event, not the chain head's (a shared
                    // arm name across nested unions dropped the `|bind|`
                    // capture: armprobe's `u2.same g` keyed against `u1.same`).
                    const child_source_event: ?[]const u8 = blk: {
                        if (cont.node) |st| {
                            if (st == .invocation) break :blk buildCanonicalEventName(&st.invocation.path, bindings_alloc, main_module_name) catch null;
                        }
                        break :blk null;
                    };
                    defer if (child_source_event) |cse| bindings_alloc.free(cse);
                    try emitSubflowContinuationsWithDepth(emitter, cont.continuations, 0, deeper_indent, all_items, program_items, last_result_idx + 1, tap_registry, type_registry, main_module_name, child_source_event orelse source_event_name, module_prefix, enclosing_bare_return, enclosing_event, if (cont.node) |st| (if (st == .invocation) st.invocation.return_binding else null) else null, self_loop_canonical, null, &local_bindings, subtree_refs);
                }
                } // if (!self_reentry_emitted)

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
                            try emitProducedConstructor(emitter, main_module_name, &bc2);
                        },
                        // A terminal (or any node this expression path can't
                        // lower) must still be a Zig expression — an empty
                        // block, never NOTHING (`.mode => ,` is a parse error).
                        else => try emitter.write("{}"),
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
                    needs_binding = stepReferencesBinding(step, actual_binding);
                }
                if (!needs_binding and cont.continuations.len > 0) {
                    needs_binding = subtreeReferencesName(subtree_refs, cont.continuations, actual_binding);
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
                    // Presence rewrite: a bare optional-arm name in guard position
                    // is a comptime `@hasDecl(__H, ...)` presence test, not a value
                    // guard (400_146/147/150).
                    const cond_out: []const u8 = blk: {
                        const alloc = emitter.allocator orelse break :blk condition;
                        const sen = source_event_name orelse break :blk condition;
                        const ev = findEventByName(all_items, sen, alloc, main_module_name) orelse break :blk condition;
                        // Consumer-side when-guards: still on the Handlers-fn
                        // path (`__H` in scope). Inline-splice presence resolves
                        // at the impl-body sites that pass `ctx.inline_fire_conts`.
                        break :blk (try presenceConditionRewrite(alloc, condition, ev, null)) orelse condition;
                    };
                    try emitter.write(lowerExprZig(emitter, &local_ctx, cond_out));
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
                            try emitBranchConstructor(emitter, &local_ctx, &bc, true);
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

    if (catchall_cont_ret) |catchall| {
        var ctx_ca = detachedEmissionContext(
            all_items,
            program_items,
            tap_registry,
            type_registry,
            main_module_name,
            source_event_name,
            enclosing_bare_return,
            enclosing_event,
            self_loop_canonical,
        );
        ctx_ca.zig_scope_bindings.items = local_bindings.items;
        var result_counter_ca: usize = depth;
        try emitSubflowCatchallOptionalArms(
            emitter,
            &ctx_ca,
            indent,
            catchall,
            branch_groups,
            source_event_name,
            all_items,
            main_module_name,
            &result_counter_ca,
        );
    }

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

/// Path-segment equality for decl lookup (segments are strings, so
/// std.mem.eql alone doesn't compare them).
fn segmentsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |segment, i| {
        if (!std.mem.eql(u8, segment, b[i])) return false;
    }
    return true;
}

/// The find*DeclByPath walk, generic over the Item tag: a qualified path
/// resolves inside the named module_decl first (falling back to top-level
/// items, since the qualifier may name the main module — a source_file, not
/// a module_decl); an unqualified path searches local items and recurses
/// into module_decls.
fn findDeclByPath(
    comptime tag: std.meta.Tag(ast.Item),
    comptime T: type,
    items: []const ast.Item,
    path: *const ast.DottedPath,
) ?*const T {
    if (path.module_qualifier) |module_qual| {
        for (items) |*item| {
            if (item.* == .module_decl and std.mem.eql(u8, item.module_decl.logical_name, module_qual)) {
                return findDeclBySegments(tag, T, item.module_decl.items, path.segments);
            }
        }
        return findDeclBySegments(tag, T, items, path.segments);
    }

    for (items) |*item| {
        switch (item.*) {
            .module_decl => |*module| {
                if (findDeclByPath(tag, T, module.items, path)) |found| {
                    return found;
                }
            },
            else => {
                if (item.* == tag) {
                    const decl: *const T = &@field(item.*, @tagName(tag));
                    if (segmentsEqual(decl.path.segments, path.segments)) {
                        return decl;
                    }
                }
            },
        }
    }
    return null;
}

/// Find a decl by segments within one item list — the flat scan behind the
/// qualified-path arm of findDeclByPath.
fn findDeclBySegments(
    comptime tag: std.meta.Tag(ast.Item),
    comptime T: type,
    items: []const ast.Item,
    segments: []const []const u8,
) ?*const T {
    for (items) |*item| {
        if (item.* == tag) {
            const decl: *const T = &@field(item.*, @tagName(tag));
            if (segmentsEqual(decl.path.segments, segments)) {
                return decl;
            }
        }
    }
    return null;
}

/// Find an event declaration by its path
/// Handles both local events (no module_qualifier) and imported module events (with module_qualifier)
pub fn findEventDeclByPath(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
    return findDeclByPath(.event_decl, ast.EventDecl, items, path);
}

/// Decl lookup with the module-scope → program-scope fallback. The emitting
/// scope's items win when both contain the name (deliberate shadowing), but
/// the subflow-continuation path threads `module.items`, which cannot see a
/// cross-module target like `koru/pcre2:find.all` (400_198).
fn findEventDeclForEmission(ctx: *const EmissionContext, path: *const ast.DottedPath) ?*const ast.EventDecl {
    if (ctx.ast_items) |items| {
        if (findEventDeclByPath(items, path)) |ed| return ed;
    }
    if (ctx.program_items) |items| {
        return findEventDeclByPath(items, path);
    }
    return null;
}

/// The bindings visible at a nested transform site. `site` is a pointer into
/// the REAL program — a transform reaches it via `item.flow.site_of` (the
/// runner's siteView sets it for nested sites; it is null at flow roots,
/// where there is no enclosing scope).
///
/// Walks the containing flow's continuation tree down to `site`, collecting
/// every binding the path introduces — `| branch name` payload binds,
/// `! name` effect binds, `: name` return binds on invocation nodes, and
/// destructures — each resolved against the declaring event's branch payload
/// or return type. An impl flow's event input fields are in scope for the
/// whole body. `.type` carries the phantom in source spelling
/// (`*Connection<opened!>`), `.value_ref` the name as code sees it.
/// This is the nested-correct twin of `resolveBindingType` (which searches
/// the real program for a view-copied invocation and only scans flow-top
/// continuations — both blind at a nested site).
pub fn scopeAtSite(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    site: *const ast.Continuation,
) ![]ast.ScopeBinding {
    const flow = findFlowHoldingCont(items, site) orelse return &.{};
    var out = std.ArrayList(ast.ScopeBinding){};

    // An impl flow's event input fields are in scope for the whole body.
    if (flow.impl_of) |impl_path| {
        var p = impl_path;
        if (findEventDeclByPath(items, &p)) |decl| {
            for (decl.input.fields) |f| {
                try out.append(allocator, .{
                    .name = f.name,
                    .type = try scopedTypeText(allocator, f.type, f.phantom),
                    .value_ref = f.name,
                });
            }
        }
    }

    _ = try scopeWalkCont(allocator, items, &flow.body, null, site, &out);
    return try out.toOwnedSlice(allocator);
}

/// Join a phantom-stripped type with its state: "opened!" → "*Connection<opened!>".
fn scopedTypeText(allocator: std.mem.Allocator, base: []const u8, phantom: ?[]const u8) ![]const u8 {
    const ph = phantom orelse return base;
    return std.fmt.allocPrint(allocator, "{s}<{s}>", .{ base, ph });
}

fn findFlowHoldingCont(items: []const ast.Item, site: *const ast.Continuation) ?*const ast.Flow {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                if (&f.body == site or contTreeHolds(f.body.continuations, site)) return f;
            },
            .module_decl => |*m| {
                if (findFlowHoldingCont(m.items, site)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

/// First-true scan over the arm bodies nested inside `node` — every
/// conditional, foreach, and switch_result arm, plus the conditionals
/// inside a conditional_block. `check` sees each arm's continuation slice.
fn anyNestedArmBody(
    node: ast.Node,
    ctx: anytype,
    comptime check: fn ([]const ast.Continuation, @TypeOf(ctx)) bool,
) bool {
    switch (node) {
        .conditional => |n| {
            for (n.branches) |*b| {
                if (check(b.body, ctx)) return true;
            }
        },
        .foreach => |n| {
            for (n.branches) |*b| {
                if (check(b.body, ctx)) return true;
            }
        },
        .switch_result => |n| {
            for (n.branches) |*b| {
                if (check(b.body, ctx)) return true;
            }
        },
        .conditional_block => |cb| {
            for (cb.nodes) |*n| {
                if (n.* == .conditional) {
                    for (n.conditional.branches) |*b| {
                        if (check(b.body, ctx)) return true;
                    }
                }
            }
        },
        else => {},
    }
    return false;
}

fn contTreeHolds(conts: []const ast.Continuation, site: *const ast.Continuation) bool {
    for (conts) |*cont| {
        if (cont == site) return true;
        if (contTreeHolds(cont.continuations, site)) return true;
        if (cont.node) |*node| {
            if (anyNestedArmBody(node.*, site, contTreeHolds)) return true;
        }
    }
    return false;
}

/// One continuation's scope contribution, then descent toward `site`.
/// `parent_inv` is the invocation whose branch set contains `cont` — a
/// `| branch name`/`! branch name` binding resolves against that event's
/// declaration. The site's OWN binding is in scope at the site (the `| db d`
/// of `| db d |> libs/sqlite3 { }` binds `d` before the node runs); a
/// SIBLING's binding is not — only path conts contribute.
fn scopeWalkCont(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    cont: *const ast.Continuation,
    parent_inv: ?*const ast.Invocation,
    site: *const ast.Continuation,
    out: *std.ArrayList(ast.ScopeBinding),
) anyerror!bool {
    const is_site = cont == site;
    if (!is_site and !contHoldsTarget(cont, site)) return false;

    // On the path (or the site itself): this cont's bindings are in scope.
    if (cont.binding) |name| {
        const t = try branchPayloadType(allocator, items, parent_inv, cont.branch);
        try out.append(allocator, .{ .name = name, .type = t, .value_ref = name });
    }
    try appendScopeDestructure(allocator, cont.destructure, out);
    if (is_site) return true;

    var child_inv: ?*const ast.Invocation = parent_inv;
    if (cont.node) |*node| {
        switch (node.*) {
            .invocation => |*inv| {
                // `: name` binds the return for everything after the call.
                if (inv.return_binding) |name| {
                    const t = try returnTypeOf(allocator, items, inv);
                    try out.append(allocator, .{ .name = name, .type = t, .value_ref = name });
                }
                try appendScopeDestructure(allocator, inv.return_destructure, out);
                child_inv = inv;
            },
            .label_with_invocation => |*lwi| child_inv = &lwi.invocation,
            else => {},
        }
    }

    if (try scopeWalkConts(allocator, items, cont.continuations, child_inv, site, out)) return true;

    if (cont.node) |*node| {
        var ctx: ScopeArmCtx = .{
            .allocator = allocator,
            .items = items,
            .parent_inv = parent_inv,
            .site = site,
            .out = out,
        };
        if (anyNestedArmBody(node.*, &ctx, armBodyScopeWalks)) {
            if (ctx.err) |e| return e;
            return true;
        }
    }
    return false;
}

/// Append a destructure's bound names to the scope. Paths are flat —
/// every entry binds exactly its local name (`{ pos.x }` binds `x`).
fn appendScopeDestructure(
    allocator: std.mem.Allocator,
    fields: []const ast.DestructureField,
    out: *std.ArrayList(ast.ScopeBinding),
) !void {
    for (fields) |*df| {
        // The bound name's declared type: `x: T` carries T on type_text
        // (sigil-shaped RHS) or on path (ident-shaped RHS — `service:
        // string` can't be told from a rename at parse, so the consumer
        // reads the spec). A rename `x: p` puts p here too — the old
        // annotation reading — and resolves (or fails) as a type name.
        const spec: []const u8 = df.type_text orelse (if (!std.mem.eql(u8, df.path, df.name)) df.path else "");
        try out.append(allocator, .{ .name = df.name, .type = spec, .value_ref = df.name });
        if (df.sub.len > 0) try appendScopeDestructure(allocator, df.sub, out);
    }
}

const ScopeArmCtx = struct {
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    parent_inv: ?*const ast.Invocation,
    site: *const ast.Continuation,
    out: *std.ArrayList(ast.ScopeBinding),
    err: ?anyerror = null,
};

/// scopeWalkConts over one arm body, stashing any error so the
/// anyNestedArmBody walk can carry it out of a bool-shaped check.
fn armBodyScopeWalks(body: []const ast.Continuation, ctx: *ScopeArmCtx) bool {
    return scopeWalkConts(ctx.allocator, ctx.items, body, ctx.parent_inv, ctx.site, ctx.out) catch |e| {
        ctx.err = e;
        return true;
    };
}

fn contHoldsTarget(cont: *const ast.Continuation, site: *const ast.Continuation) bool {
    if (cont == site) return true;
    if (contTreeHolds(cont.continuations, site)) return true;
    if (cont.node) |*node| {
        if (anyNestedArmBody(node.*, site, contTreeHolds)) return true;
    }
    return false;
}

fn scopeWalkConts(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    conts: []const ast.Continuation,
    parent_inv: ?*const ast.Invocation,
    site: *const ast.Continuation,
    out: *std.ArrayList(ast.ScopeBinding),
) anyerror!bool {
    for (conts) |*cont| {
        if (try scopeWalkCont(allocator, items, cont, parent_inv, site, out)) return true;
    }
    return false;
}

/// A `| branch name`/`! branch name` bind takes the named branch's payload
/// type in the parent invocation's event decl. Single-field shapes report
/// the scalar type with its phantom (`*Connection<opened!>`); record
/// payloads report "" (no scalar type to give).
fn branchPayloadType(allocator: std.mem.Allocator, items: []const ast.Item, parent_inv: ?*const ast.Invocation, branch_name: []const u8) ![]const u8 {
    const inv = parent_inv orelse return "";
    const decl = findEventDeclByPath(items, &inv.path) orelse return "";
    for (decl.branches) |*b| {
        if (!std.mem.eql(u8, b.name, branch_name)) continue;
        if (b.payload.fields.len == 1) {
            return scopedTypeText(allocator, b.payload.fields[0].type, b.payload.fields[0].phantom);
        }
        return "";
    }
    return "";
}

fn returnTypeOf(allocator: std.mem.Allocator, items: []const ast.Item, inv: *const ast.Invocation) ![]const u8 {
    const decl = findEventDeclByPath(items, &inv.path) orelse return "";
    return scopedTypeText(allocator, decl.return_type orelse "", decl.return_phantom);
}

/// Is `name` bound, at this site, by a take's `| item` arm — the taken row
/// VALUE, not a handle? A dotted index `store[name.field]` on such a name is a
/// struct read (the stored handle itself), never the self-FK hop
/// `field[resolve(name)]` — `name` is not a handle (690_339).
///
/// Nested transform dispatch hands a site-view flow whose `site_of` is the
/// REAL holding continuation; the `| item` ancestor lives in the real program
/// the view detached from — so the search runs over `items` for that
/// continuation pointer. A top-level dispatch has no `site_of`: the target
/// invocation sits in `flow.body` directly and the holding continuation is
/// found there.
pub fn takeItemBoundAtSite(
    items: []const ast.Item,
    flow: *const ast.Flow,
    target: *const ast.Invocation,
    name: []const u8,
) bool {
    const site: *const ast.Continuation = flow.site_of orelse
        (siteContOf(&flow.body, target) orelse return false);
    const real = findFlowHoldingCont(items, site) orelse return false;
    var hit = false;
    _ = takeItemPath(&real.body, false, site, name, &hit);
    return hit;
}

/// The continuation whose node IS `target`, or null.
fn siteContOf(cont: *const ast.Continuation, target: *const ast.Invocation) ?*const ast.Continuation {
    if (cont.node) |*n| {
        if (n.* == .invocation and &n.invocation == target) return cont;
    }
    for (cont.continuations) |*c| {
        if (siteContOf(c, target)) |found| return found;
    }
    if (cont.node) |*n| {
        var ctx: SiteContCtx = .{ .target = target };
        _ = anyNestedArmBody(n.*, &ctx, armBodySiteCont);
        return ctx.found;
    }
    return null;
}

const SiteContCtx = struct {
    target: *const ast.Invocation,
    found: ?*const ast.Continuation = null,
};

/// siteContOf over one arm body, carrying the found pointer out through
/// the ctx so the result survives the bool-shaped check.
fn armBodySiteCont(body: []const ast.Continuation, ctx: *SiteContCtx) bool {
    for (body) |*c| {
        if (siteContOf(c, ctx.target)) |found| {
            ctx.found = found;
            return true;
        }
    }
    return false;
}

fn takeInvNode(node: ?ast.Node) bool {
    const n = node orelse return false;
    if (n != .invocation) return false;
    const inv = &n.invocation;
    if (inv.path.segments.len != 1) return false;
    const seg = inv.path.segments[0];
    if (std.mem.startsWith(u8, seg, "__store_take_")) return true;
    return std.mem.eql(u8, seg, "take");
}

/// Returns true when `site` sits inside `cont`'s subtree, marking `hit` when a
/// `| item` arm of a take call on that path binds `name`. `under_take` is the
/// parent continuation's node being a take invocation — the discriminator
/// between a row-value `| item` and any other event's scalar `| item`.
fn takeItemPath(cont: *const ast.Continuation, under_take: bool, site: *const ast.Continuation, name: []const u8, hit: *bool) bool {
    if (cont != site and !contHoldsTarget(cont, site)) return false;
    if (under_take and std.mem.eql(u8, std.mem.trim(u8, cont.branch, " "), "item")) {
        if (cont.binding) |b| {
            if (std.mem.eql(u8, b, name)) hit.* = true;
        }
    }
    if (cont == site) return true;
    const mine_is_take = takeInvNode(cont.node);
    for (cont.continuations) |*c| {
        if (takeItemPath(c, mine_is_take, site, name, hit)) return true;
    }
    if (cont.node) |*n| {
        const ctx: TakePathCtx = .{ .site = site, .name = name, .hit = hit };
        if (anyNestedArmBody(n.*, ctx, armBodyTakePath)) return true;
    }
    return false;
}

const TakePathCtx = struct {
    site: *const ast.Continuation,
    name: []const u8,
    hit: *bool,
};

/// takeItemPath over one arm body — nested arm bodies never count as
/// "under take" (the take's own arms are `cont.continuations`, not a
/// nested node's), matching the previous in-line descent.
fn armBodyTakePath(body: []const ast.Continuation, ctx: TakePathCtx) bool {
    for (body) |*c| {
        if (takeItemPath(c, false, ctx.site, ctx.name, ctx.hit)) return true;
    }
    return false;
}

/// The `__store_*` decl scan — an event_decl named `name` anywhere in the
/// item tree (module decls included).
fn findEventDeclIn(items: []const ast.Item, name: []const u8) ?*const ast.EventDecl {
    for (items) |*it| {
        switch (it.*) {
            .event_decl => |*ed| {
                if (ed.path.segments.len == 1 and std.mem.eql(u8, ed.path.segments[0], name)) return ed;
            },
            .module_decl => |*m| {
                if (findEventDeclIn(m.items, name)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

const StoreNewHit = struct { flow: *const ast.Flow, home: []const u8 };

/// The raw `std/store:new(<store>)` flow — still present while the target's
/// transform has not run (transforms fire in declaration order, and a guard
/// store may be declared before the store it guards).
fn storeNewFlowIn(items: []const ast.Item, store: []const u8, enclosing: ?[]const u8) ?StoreNewHit {
    for (items) |*it| {
        switch (it.*) {
            .flow => |*f| {
                const inv = f.inv();
                if (inv.path.segments.len != 1 or !std.mem.eql(u8, inv.path.segments[0], "new")) continue;
                const mq = inv.path.module_qualifier orelse continue;
                if (!std.mem.eql(u8, mq, "std.store")) continue;
                for (inv.args) |a| {
                    if (!std.mem.eql(u8, a.name, "expr")) continue;
                    var v = a.value;
                    if (v.len >= 2 and v[0] == '"') v = v[1 .. v.len - 1];
                    if (std.mem.eql(u8, v, store)) return .{ .flow = f, .home = enclosing orelse f.module };
                }
            },
            .module_decl => |*m| {
                if (storeNewFlowIn(m.items, store, m.logical_name)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

/// Whether `__store_announce_<store>` takes a `row` input — true for plural
/// stores. A guarded watch on store T becomes a foreign guard on the GUARD
/// store: every write to the guarded field must re-fire T's watch through
/// `__store_announce_<T>`. The decl answers directly when the target is
/// already coordinated; otherwise the `new` flow's `capacity` arg does.
pub fn storeAnnounceRowed(alloc: std.mem.Allocator, program: *const ast.Program, store: []const u8) bool {
    const want = std.fmt.allocPrint(alloc, "__store_announce_{s}", .{store}) catch unreachable;
    if (findEventDeclIn(program.items, want)) |ed| {
        for (ed.input.fields) |fld| {
            if (std.mem.eql(u8, fld.name, "row")) return true;
        }
        return false;
    }
    if (storeNewFlowIn(program.items, store, null)) |hit| {
        for (hit.flow.inv().args) |a| {
            if (std.mem.eql(u8, a.name, "capacity")) {
                const cap = std.fmt.parseInt(i64, a.value, 10) catch 1;
                return cap > 1;
            }
        }
    }
    return false;
}

/// The module the store's synthesized decls are emitted into — the cell and
/// the announce event both live in the TARGET's namespace, which is not the
/// guard store's when the two are declared in different modules.
fn storeDeclHome(alloc: std.mem.Allocator, program: *const ast.Program, store: []const u8) ?[]const u8 {
    const want = std.fmt.allocPrint(alloc, "__store_apply_{s}", .{store}) catch unreachable;
    if (findEventDeclIn(program.items, want)) |ed| return ed.path.module_qualifier;
    if (storeNewFlowIn(program.items, store, null)) |hit| return hit.home;
    return null;
}

/// The foreign-guard re-announce step for one (target store, target field)
/// pair. A singleton target takes the direct `__store_announce_<T>(field: N)`
/// call (690_013). A plural target's announce is `(row, field)` and the
/// foreign write carries no row of T, so the step calls
/// `__store_announce_each_<T>(field: N)` — the per-store sweep event the
/// caller synthesizes for each entry recorded in `plural_targets`.
pub fn storeForeignGuardStep(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    home_ns: []const u8,
    location: errors.SourceLocation,
    target_store: []const u8,
    target_field_idx: usize,
    plural_targets: *std.ArrayList([]const u8),
) ast.Continuation {
    const rowed = storeAnnounceRowed(alloc, program, target_store);
    const t_announce = if (rowed)
        std.fmt.allocPrint(alloc, "__store_announce_each_{s}", .{target_store}) catch unreachable
    else
        std.fmt.allocPrint(alloc, "__store_announce_{s}", .{target_store}) catch unreachable;
    if (rowed) {
        var seen = false;
        for (plural_targets.items) |t| {
            if (std.mem.eql(u8, t, target_store)) seen = true;
        }
        if (!seen) plural_targets.append(alloc, alloc.dupe(u8, target_store) catch unreachable) catch unreachable;
    }
    const segs = alloc.alloc([]const u8, 1) catch unreachable;
    segs[0] = t_announce;
    const args = alloc.alloc(ast.Arg, 1) catch unreachable;
    args[0] = ast.Arg{
        .name = alloc.dupe(u8, "field") catch unreachable,
        .value = std.fmt.allocPrint(alloc, "{d}", .{target_field_idx}) catch unreachable,
    };
    return ast.Continuation{
        .branch = alloc.dupe(u8, "") catch unreachable,
        .binding = null,
        .kind = .terminal,
        .condition = null,
        .node = .{ .invocation = ast.Invocation{
            .path = .{ .module_qualifier = alloc.dupe(u8, home_ns) catch unreachable, .segments = segs },
            .args = args,
        } },
        .indent = 1,
        .continuations = &[_]ast.Continuation{},
        .is_transformed_subtree = true,
        .location = location,
    };
}

/// The `__store_announce_each_<T>` pair for one plural target: an event
/// taking `(field)` whose impl loops the live rows calling the target's
/// `(row, field)` announce — a foreign-guard write has no single row of T to
/// name. Returns null when the decl already exists (two guard stores can
/// share a target; the pair is emitted once).
pub fn storeAnnounceEachItems(
    alloc: std.mem.Allocator,
    program: *const ast.Program,
    home_ns: []const u8,
    module: []const u8,
    location: errors.SourceLocation,
    main_module_name: []const u8,
    proc_target: []const u8,
    target_store: []const u8,
) ?[2]ast.Item {
    const each_name = std.fmt.allocPrint(alloc, "__store_announce_each_{s}", .{target_store}) catch unreachable;
    if (findEventDeclIn(program.items, each_name) != null) return null;

    const t_home = storeDeclHome(alloc, program, target_store) orelse home_ns;
    const zigq = if (t_home.len == 0 or std.mem.eql(u8, t_home, main_module_name))
        alloc.dupe(u8, "main_module.") catch unreachable
    else
        std.fmt.allocPrint(alloc, "{s}.", .{codegen_utils.buildKoruModulePath(alloc, t_home) catch unreachable}) catch unreachable;
    const body = if (std.mem.eql(u8, proc_target, "js"))
        std.fmt.allocPrint(alloc,
            \\for (let __koru_r = 0; __koru_r < __koru_store_{s}.len; __koru_r++) {{
            \\  main_module.__store_announce_{s}_event.handler({{ row: __koru_r, field: field }});
            \\}}
            \\return;
        , .{ target_store, target_store }) catch unreachable
    else if (std.mem.eql(u8, proc_target, "cs")) blk: {
        // cs spells the qualifier like store.kz's storeEventQualifier:
        // `main_module.` for the entry module, `main_module.<folded-home>_`
        // folded into the basename otherwise. The arg record is the typed
        // `Input` struct, and the cell's `len` field reads bare (the
        // `.len`→`.Length` lowering exempts `__koru_store_*` receivers).
        const csq = if (t_home.len == 0 or std.mem.eql(u8, t_home, main_module_name))
            alloc.dupe(u8, "main_module.") catch unreachable
        else csq_blk: {
            const folded = alloc.dupe(u8, t_home) catch unreachable;
            for (folded) |*c| {
                if (c.* == '/' or c.* == '.' or c.* == '-') c.* = '_';
            }
            break :csq_blk std.fmt.allocPrint(alloc, "main_module.{s}_", .{folded}) catch unreachable;
        };
        break :blk std.fmt.allocPrint(alloc,
            \\for (long __koru_r = 0; __koru_r < __koru_store_{s}.len; __koru_r++) {{
            \\    {s}__store_announce_{s}_event.handler(new {s}__store_announce_{s}_event.Input {{ row = __koru_r, field = field }});
            \\}}
        , .{ target_store, csq, target_store, csq, target_store }) catch unreachable;
    } else
        std.fmt.allocPrint(alloc,
            \\for (0..{s}__koru_store_{s}.len) |__koru_r| {{
            \\    {s}__store_announce_{s}_event.handler(.{{ .row = __koru_r, .field = field }});
            \\}}
            \\return;
        , .{ zigq, target_store, zigq, target_store }) catch unreachable;

    const segs = alloc.alloc([]const u8, 1) catch unreachable;
    segs[0] = each_name;
    const path = ast.DottedPath{ .module_qualifier = alloc.dupe(u8, home_ns) catch unreachable, .segments = segs };
    const in_fields = alloc.alloc(ast.Field, 1) catch unreachable;
    in_fields[0] = ast.Field{ .name = alloc.dupe(u8, "field") catch unreachable, .type = alloc.dupe(u8, "i64") catch unreachable };
    const ev = ast.Item{ .event_decl = ast.EventDecl{
        .path = path,
        .input = ast.Shape{ .fields = in_fields },
        .branches = &[_]ast.Branch{},
        .is_public = false,
        .is_implicit_flow = false,
        .annotations = &[_][]const u8{},
        .location = location,
        .module = alloc.dupe(u8, module) catch unreachable,
    } };
    const pd = ast.Item{ .proc_decl = ast.ProcDecl{
        .path = path,
        .body = ast.Source{ .text = body, .location = location, .scope = .{ .bindings = &[_]ast.ScopeBinding{} } },
        .annotations = &[_][]const u8{},
        .target = alloc.dupe(u8, proc_target) catch unreachable,
        .location = location,
        .module = alloc.dupe(u8, module) catch unreachable,
    } };
    return .{ ev, pd };
}

/// Find a proc declaration by its path
/// Used for checking purity of event implementations
pub fn findProcDeclByPath(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.ProcDecl {
    return findDeclByPath(.proc_decl, ast.ProcDecl, items, path);
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
///   - `__koru_continue_bare_<idx>` (from `{{ …continue[unguarded] }}`) — the same
///     hand-off with the guard left off, `{ <body> }`, for a template that has
///     already placed the guard itself (`cond`'s `if / else if` cascade).
///
/// Both index the same `continuations` slice the markers were minted against, so
/// they round-trip deterministically. An omitted optional terminal never minted a
/// marker, so its absence simply emits nothing. Markers resolve in source order.
/// Emit the consts for a shape-destructure binding: one
/// `const <local> = <prefix>.<path>;` per bound name. `_` fields are skipped
/// (the payload field simply isn't bound). Interiors may be host types — the
/// emitter only writes access paths; Zig validates them at the next stage.
pub fn emitDestructureConsts(
    emitter: *CodeEmitter,
    fields: []const ast.DestructureField,
    prefix: []const u8,
) anyerror!void {
    // Flat paths (ruled 2026-10-24): each entry mints `const <local> =
    // <prefix>.<path>` — `pos.x` descends inline, no recursion needed.
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "_")) continue;
        try emitter.write("const ");
        try writeBranchName(emitter, f.name);
        if (f.type_text) |t| {
            try emitter.write(": ");
            try emitter.write(lowerZigType(t));
        }
        try emitter.write(" = ");
        try emitter.write(prefix);
        try emitter.write(".");
        try emitter.write(f.path);
        try emitter.write("; _ = &");
        try writeBranchName(emitter, f.name);
        try emitter.write("; ");
        // Named-group nested fields (`addr: { city }`) bind their leaves too —
        // `city` comes off `prefix.addr` the same as it did under sub-descent.
        if (f.sub.len > 0) {
            var pb: [256]u8 = undefined;
            const np = std.fmt.bufPrint(&pb, "{s}.{s}", .{ prefix, f.path }) catch @panic("destructure path too long");
            try emitDestructureConsts(emitter, f.sub, np);
        }
    }
}

fn emitInlineCodeResolvingSplices(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inline_code: []const u8,
    continuations: []const ast.Continuation,
) anyerror!void {
    // Everything spliced below shares this producer's Zig frame — record the
    // text so nested bindings rename against its locals/captures too, not
    // only against their own immediate producer.
    try ctx.splice_frame_codes.append(ctx.allocator, inline_code);
    defer _ = ctx.splice_frame_codes.pop();
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
            // `bare_` infix (from `{{ arm.continue[unguarded] }}`): hand off the
            // body WITHOUT wrapping it in the arm's `when` guard, because the
            // template put that guard somewhere this splice cannot see — `cond`
            // puts it in an `if / else if` cascade's condition position.
            const unguarded = std.mem.startsWith(u8, inline_code[i..], "bare_");
            if (unguarded) i += "bare_".len;
            const idx = codegen_utils.scanDecimalIndex(inline_code, &i) orelse continuations.len; // out of range → loud verbatim below
            if (idx < continuations.len) {
                const cont = &continuations[idx];
                try emitter.write("{ ");
                // Optional `(arg)` after the marker: `__koru_continue_<idx>(expr)`
                // — a PAYLOAD terminal. The template writes the arg adjacent to
                // the marker (`{{ continuations["done"].continue }}(count)`);
                // `zip`'s `| done n` is the first consumer, delivering the pair
                // count. Bound BEFORE the guard so a `when` can reference it —
                // the same ordering the effect-splice path uses.
                var arg: []const u8 = "";
                if (i < inline_code.len and inline_code[i] == '(') {
                    const arg_start = i + 1;
                    var depth: usize = 1;
                    var j = arg_start;
                    var q: u8 = 0; // parens in string/char literals are text
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
                    // Swallow a trailing `;` — the marker resolves to a block,
                    // matching the effect-splice convention.
                    if (i < inline_code.len and inline_code[i] == ';') i += 1;
                }
                if (arg.len > 0) {
                    if (cont.destructure.len > 0) {
                        var dst_buf: [64]u8 = undefined;
                        const dst = if (cont.binding != null and cont.binding.?.len > 0 and !std.mem.eql(u8, cont.binding.?, "_"))
                            cont.binding.?
                        else
                            std.fmt.bufPrint(&dst_buf, "__koru_dst_{d}_{d}", .{ cont.location.line, cont.location.column }) catch "__koru_dst";
                        try emitter.write("const ");
                        try emitter.write(dst);
                        try emitter.write(" = ");
                        try emitter.write(arg);
                        try emitter.write("; _ = &");
                        try writeBranchName(emitter, dst);
                        try emitter.write("; ");
                        try emitDestructureConsts(emitter, cont.destructure, dst);
                    } else if (cont.binding != null and cont.binding.?.len > 0 and !std.mem.eql(u8, cont.binding.?, "_")) {
                        try emitter.write("const ");
                        try writeBranchName(emitter, cont.binding.?);
                        try emitter.write(" = ");
                        try emitter.write(arg);
                        try emitter.write("; _ = &");
                        try writeBranchName(emitter, cont.binding.?);
                        try emitter.write("; ");
                    } else {
                        try emitter.write("_ = ");
                        try emitter.write(arg);
                        try emitter.write("; ");
                    }
                }
                const guarded = cont.condition != null and !unguarded;
                if (guarded) {
                    // Presence rewrite (400_147): a bare optional-arm name as a
                    // `when` guard is a comptime `@hasDecl(__H, ...)` presence
                    // test — the guard text is written HERE (not baked by the
                    // template), so this is the guard's rewrite site.
                    const cond_out: []const u8 = blk: {
                        const alloc = emitter.allocator orelse break :blk cont.condition.?;
                        const ev = ctx.impl_event_decl orelse break :blk cont.condition.?;
                        break :blk (try presenceConditionRewrite(alloc, cont.condition.?, ev, ctx.inline_fire_conts)) orelse cont.condition.?;
                    };
                    try emitter.write("if (");
                    try emitter.write(lowerExprZig(emitter, ctx, cond_out));
                    try emitter.write(") { ");
                }
                // Give the spliced body a unique `result_N` namespace, so a
                // branched event inside it (e.g. an `if`-arm's `commit`, or a
                // `for`-`done`'s nested call) doesn't shadow the enclosing scope's
                // `result_0`. Mirrors the per-branch prefix swap used for loop
                // branches (search `branch_prefix`). NEST under the enclosing
                // prefix (like the effect splice below): a cascade arm nested
                // inside another cascade arm's body must not reuse `result_c{idx}_`
                // while the enclosing arm's same-named constant is still alive
                // (810_122_day12_part2). `prefix_buf` lives for the emit below;
                // restored after.
                const saved_prefix = ctx.result_prefix;
                var prefix_buf: [128]u8 = undefined;
                ctx.result_prefix = std.fmt.bufPrint(&prefix_buf, "{s}c{d}_", .{ saved_prefix, idx }) catch saved_prefix;
                defer ctx.result_prefix = saved_prefix;
                // The spliced body lands inside the construct's braces — a
                // `.terminal` in it ends the nested chain, not the enclosing
                // label loop; only an arm-top-level terminal may lower to
                // `break :label` (320_171).
                const saved_label = ctx.current_label;
                ctx.current_label = null;
                defer ctx.current_label = saved_label;
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
        const maybe_idx = codegen_utils.scanDecimalIndex(inline_code, &i);

        // Read the `(arg)` immediately following (balanced parens).
        var arg: []const u8 = "";
        if (maybe_idx != null and i < inline_code.len and inline_code[i] == '(') {
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

        const idx = maybe_idx orelse continuations.len; // out of range → verbatim fallback below
        if (idx < continuations.len) {
            const cont = &continuations[idx];
            const binding = cont.binding orelse "_";
            // Cross-boundary splice hygiene (400_151): the spliced body shares
            // one frame with the producer's raw-|zig locals/captures. If the
            // consumer binding's name also occurs as a token in that producer
            // body, `const <binding>` would shadow it (e.g. vaxis's loop `|k|`
            // vs a consumer's `! key k`). Rename the binding uniquely and rewrite
            // its uses in the guard + body. `uniq_buf` outlives both below.
            var uniq_buf: [64]u8 = undefined;
            var bind_rename: ?BindingSubstitution = null;
            const is_pun = arg.len != 0 and std.mem.eql(u8, std.mem.trim(u8, arg, " \t"), binding);
            // The binding lands inside every enclosing splice frame still on
            // the stack — a name that occurs as a token in ANY of them would
            // be shadowed by `const <binding>`, not just one in the immediate
            // producer's text.
            const producer_shadow = codegen_utils.containsToken(inline_code, binding) or blk: {
                for (ctx.splice_frame_codes.items) |frame| {
                    if (codegen_utils.containsToken(frame, binding)) break :blk true;
                }
                break :blk false;
            };
            if (!std.mem.eql(u8, binding, "_") and cont.destructure.len == 0 and arg.len != 0 and !is_pun and producer_shadow) {
                const uniq = std.fmt.bufPrint(&uniq_buf, "__koru_bind_{d}_{d}", .{ cont.location.line, cont.location.column }) catch binding;
                bind_rename = .{ .from = binding, .to = uniq };
            }
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
                // A named group (`| ok e:{ k }`) makes the whole-bind name the
                // prefix — `const e = arg; const k = e.k;` — plain `const`s.
                const dst = if (binding.len > 0 and !std.mem.eql(u8, binding, "_"))
                    binding
                else
                    std.fmt.bufPrint(&dst_buf, "__koru_dst_{d}_{d}", .{ cont.location.line, cont.location.column }) catch "__koru_dst";
                try emitter.write("const ");
                try emitter.write(dst);
                try emitter.write(" = ");
                try emitter.write(arg);
                try emitter.write("; _ = &");
                try writeBranchName(emitter, dst);
                try emitter.write("; ");
                try emitDestructureConsts(emitter, cont.destructure, dst);
            } else if (std.mem.eql(u8, binding, "_")) {
                try emitter.write("_ = ");
                try emitter.write(arg);
                try emitter.write("; ");
            } else if (std.mem.eql(u8, std.mem.trim(u8, arg, " \t"), binding)) {
                // The splice arg IS the binding (an inline-lowered proc local
                // sharing the name): rebinding would self-shadow — use as-is.
            } else if (bind_rename) |br| {
                // Site-unique rename to avoid shadowing a producer local.
                try emitter.write("const ");
                try emitter.write(br.to);
                try emitter.write(" = ");
                try emitter.write(arg);
                try emitter.write("; _ = &");
                try writeBranchName(emitter, br.to);
                try emitter.write("; ");
            } else {
                try emitter.write("const ");
                try writeBranchName(emitter, binding);
                try emitter.write(" = ");
                try emitter.write(arg);
                try emitter.write("; _ = &");
                try writeBranchName(emitter, binding);
                try emitter.write("; ");
            }
            // `! else` — exclusive dispatch continuing the contiguous
            // each/else effect run above. An else arm fires iff no earlier
            // arm's guard passed AND its own does — the else-if chain
            // telescoped: every earlier raw guard negated, own appended.
            // (An arm "fires" iff body runs — pre `when` and post-produce
            // `when` both gate it, so both join the negated guard. An
            // unguarded earlier arm contributes `!(true)` — a dead else,
            // matching `else` after an unconditional `if`.) Earlier guards
            // are rebound to THIS arm's binding name — every arm declares
            // its own, but the payload is the same element. A `! else`
            // with no `! each` head compiles to a compileError, not a guess.
            var cond_text: ?[]const u8 = cont.condition;
            var cond_owned: ?[]u8 = null;
            defer if (cond_owned) |o| ctx.allocator.free(o);
            if (cont.kind == .effect and std.mem.eql(u8, cont.branch, "else")) {
                var g: usize = idx;
                while (g > 0) {
                    const prev = &continuations[g - 1];
                    if (prev.kind != .effect) break;
                    if (!std.mem.eql(u8, prev.branch, "each") and !std.mem.eql(u8, prev.branch, "else")) break;
                    g -= 1;
                }
                var buf = try std.ArrayList(u8).initCapacity(ctx.allocator, 128);
                if (g < idx and std.mem.eql(u8, continuations[g].branch, "each")) {
                    for (continuations[g..idx]) |*prev| {
                        var prev_full: []const u8 = "true";
                        var pg_owned: ?[]u8 = null;
                        defer if (pg_owned) |o| ctx.allocator.free(o);
                        if (prev.condition != null and prev.post_condition != null) {
                            prev_full = try std.fmt.allocPrint(ctx.allocator, "({s}) and ({s})", .{ prev.condition.?, prev.post_condition.? });
                            pg_owned = @constCast(prev_full);
                        } else if (prev.condition orelse prev.post_condition) |single| {
                            prev_full = single;
                        }
                        if (prev.binding != null and cont.binding != null and
                            !std.mem.eql(u8, prev.binding.?, cont.binding.?))
                        {
                            const rw = try codegen_utils.replaceIdentifier(ctx.allocator, prev_full, prev.binding.?, cont.binding.?);
                            if (pg_owned) |o| ctx.allocator.free(o);
                            pg_owned = @constCast(rw);
                            prev_full = pg_owned.?;
                        }
                        try buf.appendSlice(ctx.allocator, "!(");
                        try buf.appendSlice(ctx.allocator, prev_full);
                        try buf.appendSlice(ctx.allocator, ") and ");
                    }
                    if (cont.condition) |own| {
                        try buf.appendSlice(ctx.allocator, "(");
                        try buf.appendSlice(ctx.allocator, own);
                        try buf.appendSlice(ctx.allocator, ")");
                    } else {
                        buf.shrinkRetainingCapacity(buf.items.len - " and ".len);
                    }
                    cond_owned = try buf.toOwnedSlice(ctx.allocator);
                    cond_text = cond_owned.?;
                } else {
                    buf.deinit(ctx.allocator);
                    cond_owned = try ctx.allocator.dupe(u8, "@compileError(\"`! else` has no `! each` group — an else arm continues a contiguous each/else run, it cannot open one.\")");
                    cond_text = cond_owned.?;
                }
            }
            const guarded = cond_text != null;
            if (guarded) {
                // Presence rewrite (400_147): `! each i when <optional arm>`
                // — the guard is written here at splice time, so a bare
                // optional-arm name becomes the comptime @hasDecl test.
                const cond_out: []const u8 = blk: {
                    const alloc = emitter.allocator orelse break :blk cond_text.?;
                    const ev = ctx.impl_event_decl orelse break :blk cond_text.?;
                    break :blk (try presenceConditionRewrite(alloc, cond_text.?, ev, ctx.inline_fire_conts)) orelse cond_text.?;
                };
                try emitter.write("if (");
                if (bind_rename) |br| {
                    try emitValueWithBindingSubstitution(emitter, ctx, lowerExprZig(emitter, ctx, cond_out), br);
                } else {
                    try emitter.write(lowerExprZig(emitter, ctx, cond_out));
                }
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
            const rename_depth = ctx.splice_binding_renames.items.len;
            defer ctx.splice_binding_renames.shrinkRetainingCapacity(rename_depth);
            if (bind_rename) |br| try ctx.splice_binding_renames.append(ctx.allocator, br);
            // The spliced body lands inside the construct's braces — a
            // `.terminal` in it ends the nested chain, not the enclosing
            // label loop; only an arm-top-level terminal may lower to
            // `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;
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
pub fn writeInlineCodeWithLabel(
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

/// Emit the construct's join: anonymous continuations ride no template marker
/// (`{{ continuations["X"].continue }}` resolves by branch name — an unnamed
/// tail has no name to be resolved by), so every path that hands named arms to
/// markers must still emit this tail itself, in order, after the construct
/// (400_205: `! each`'s join was silently dropped, and an obligation written
/// onto it leaked undiagnosed).
fn emitAnonymousContinuations(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    continuations: []const ast.Continuation,
    result_counter: *usize,
) !void {
    for (continuations) |*cont| {
        if (cont.branch.len != 0) continue;
        try emitContinuationBody(emitter, ctx, cont, result_counter);
    }
}

/// Emit a node whose template transform produced `inline_body` (zero-overhead
/// control flow: `~if`, `~for`, …). Shared by `emitFlow` (top-level) and
/// `emitContinuationBody` (nested), so the inline-template lowering works
/// identically at every depth — there is no "only top-level" path. Covers:
///   - statement / void-continuation inline emission (incl. the `! each`
///     effect-branch Handlers bridge), and
///   - the `[expand]` `switch (__expand_result_N)` form.
/// `continuations` are the node's branch continuations; `path` is the invoked
/// event's path (for effect-branch lookup).
pub fn emitInlineBodyNode(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inline_code_raw: []const u8,
    continuations: []const ast.Continuation,
    path: *const ast.DottedPath,
    result_counter: *usize,
    // The site's `: bind` name, if any. An inline-transform site consumed by a
    // bare-return bind (`std/fmt:ln(...): l |> use l`) must materialise the
    // break value as `const l = <labeled block>;` so the VOID continuations that
    // follow can reference it — without a binding the block dumps as a bare
    // statement and the break/label leak (620_002). Null for branch consumption
    // (`| line l`), which the switch path below handles.
    return_binding: ?[]const u8,
) anyerror!void {
    const inline_stmt_marker = "//@koru:inline_stmt\n";
    var inline_code = inline_code_raw;
    var is_inline_stmt = false;
    if (std.mem.indexOf(u8, inline_code, inline_stmt_marker)) |marker_idx| {
        is_inline_stmt = true;
        inline_code = inline_code[marker_idx + inline_stmt_marker.len ..];
    }

    // Give this rendered body its own `for` capture BEFORE any branch below
    // decides how to emit it. It used to be done inside the effect-branch
    // branch alone, so which of the three exits a body took decided whether it
    // was safe — and the exit is chosen by inline eligibility, not by the
    // source. The same nested-`for` program was therefore safe from the entry
    // file and a Zig shadowing error from inside a module (115_004 against its
    // green original 2106). Uniquifying at the entry makes the property belong
    // to the BODY, which is where it always belonged.
    var inline_code_uniq: ?[]u8 = null;
    defer if (inline_code_uniq) |owned| ctx.allocator.free(owned);
    if (try uniquifyForCapture(ctx, inline_code)) |uniq| {
        inline_code_uniq = uniq;
        inline_code = uniq;
    }
    const pushed_captures = try pushBodyCaptures(ctx, inline_code);
    defer popBodyCaptures(ctx, pushed_captures);

    // Cross-boundary splice hygiene, text half (400_169): when the consumer
    // binding was site-unique-renamed against a producer local, AST-borne
    // references rewrite in emitExpression — but a transform-rendered body
    // (print.ln's `__kw(…, .{k})`) carries its references as TEXT, already
    // rendered before the rename existed. Rewrite them here, or the spliced
    // body silently reads the producer's live local instead of the payload.
    {
        var ri = ctx.splice_binding_renames.items.len;
        while (ri > 0) {
            ri -= 1;
            const br = ctx.splice_binding_renames.items[ri];
            if (std.mem.indexOf(u8, inline_code, br.from) != null) {
                const rewritten_text = try codegen_utils.replaceIdentifier(ctx.allocator, inline_code, br.from, br.to);
                if (inline_code_uniq) |owned| ctx.allocator.free(owned);
                inline_code_uniq = @constCast(rewritten_text);
                inline_code = inline_code_uniq.?;
            }
        }
    }

    // Bound-name spelling on the rendered body (same disease as the splice
    // rename above, different cause): a `{{ expr }}` hole baked by the
    // template processor carries the author's raw spelling of an in-scope
    // binding — `if (i1 == i1)` renders `i1` where the decl wrote `@"i1"`.
    {
        const escaped = try escapeBoundNames(ctx, inline_code);
        if (escaped.ptr != inline_code.ptr) {
            if (inline_code_uniq) |owned| ctx.allocator.free(owned);
            inline_code_uniq = @constCast(escaped);
            inline_code = inline_code_uniq.?;
        }
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
        // effect symbols by name — e.g. a `~[template]proc for|zig` loop body
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
                // A transform-consumed subtree's arms are the transform's DATA
                // (std/parser grammar rules), not live handlers — synthesizing
                // Handlers fns or loose bodies from them emits orphaned code.
                if (cont.is_transformed_subtree) continue;
                if (cont.kind == .effect) {
                    try inline_effect_conts.append(ctx.allocator, cont);
                } else {
                    try inline_terminal_conts.append(ctx.allocator, cont);
                }
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
                try emitAnonymousContinuations(emitter, ctx, continuations, result_counter);
                _ = &inline_terminal_conts;
                return;
            }

            // (1) Synthesize the Handlers struct from effect continuations.
            //     Skip entirely when nothing will reference it: no live effect
            //     conts (all transform-consumed data) AND no bare `name(` call
            //     in the body. An empty struct with a `const row = H.row` alias
            //     is a dangling member access, and an unused local — e.g. an
            //     unhandled optional `! ?row` at a marker-driven site.
            var body_calls_effect = false;
            for (ed.branches) |b| {
                if (b.kind != .effect or std.mem.eql(u8, b.name, "*")) continue;
                // A bare `name(` call only needs a Handlers member when a
                // LIVE arm supplies one — transform-consumed arms resolve
                // through the graft, not `Handlers_N.name`, so calls to
                // consumed-only branch names must not force the struct
                // (690_342: the bulk insert consumed `! each`; the textual
                // `each(` resolves through the graft, and a memberless
                // `const Handlers_0 = struct {}` is just an unused local).
                var has_live_arm = false;
                for (inline_effect_conts.items) |lc| {
                    if (std.mem.eql(u8, lc.branch, b.name)) {
                        has_live_arm = true;
                        break;
                    }
                }
                if (!has_live_arm) continue;
                if (callsBranchByName(inline_code, b.name)) {
                    body_calls_effect = true;
                    break;
                }
            }
            if (inline_effect_conts.items.len == 0 and !body_calls_effect) {
                try emitter.writeIndent();
                try emitInlineCodeResolvingSplices(emitter, ctx, inline_code, continuations);
                if (!inline_is_statement) {
                    try emitter.write(";");
                }
                try emitter.write("\n");
                // Same join rule as the SPLICE path above (400_205).
                try emitAnonymousContinuations(emitter, ctx, continuations, result_counter);
                return;
            }
            // Site-unique name: nested or sibling inline-effect sites each
            // synthesize a struct in the same Zig scope — a fixed `Handlers_0`
            // shadows the outer one and Zig rejects the redeclaration.
            const hname = try std.fmt.allocPrint(ctx.allocator, "Handlers_{d}", .{ctx.capture_counter})
            ; ctx.capture_counter += 1;
            defer ctx.allocator.free(hname);
            result_counter.* += 1;
            try emitHandlersStruct(emitter, ctx, hname, inline_effect_conts.items, ed);

            // (2) Alias every PROVIDED effect branch into local scope so the
            //     template body's bare `NAME(...)` calls resolve. Mirrors the
            //     handler-side aliasing (`const NAME = __H.NAME;`). Only
            //     branches with a handler member get an alias — the struct has
            //     no member for an unhandled optional effect, so the alias
            //     would dangle. (A `name(` call into an unhandled optional
            //     branch still has no member — a no-op stub is a separate seam.)
            //     A wildcard decl branch (`! \`*\` *` — regex scan, std/parser
            //     grammar) is a PATTERN, not a name: nothing can alias it.
            for (ed.branches) |b| {
                if (b.kind != .effect) continue;
                if (std.mem.eql(u8, b.name, "*")) continue;
                const has_member = for (inline_effect_conts.items) |c| {
                    if (std.mem.eql(u8, c.branch, b.name)) break true;
                } else false;
                if (!has_member) continue;
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
            // them via the resolved `__koru_continue_<idx>` markers above. The
            // anonymous join tail rides no marker either — it emits here (400_205).
            try emitAnonymousContinuations(emitter, ctx, continuations, result_counter);
            _ = &inline_terminal_conts;
            return;
        }

        // Bare-return bind of an inline-transform site (`ln(...): l |> use l`):
        // materialise the break value as `const l = <labeled block>;` so the
        // void continuations that follow can reference it. Without this the block
        // dumps as a bare statement and both the `break :__KORU_INLINE__` label
        // and the bind name leak (620_002). Branch consumption (`| line l`) never
        // reaches here — it takes the switch path below.
        if (return_binding) |rb| {
            try emitter.writeIndent();
            try emitter.write("const ");
            try writeBranchName(emitter, rb);
            try emitter.write(" = ");
            try writeInlineCodeWithLabel(emitter, ctx, inline_code);
            try emitter.write(";\n");
            try emitAnonymousContinuations(emitter, ctx, continuations, result_counter);
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
        try emitAnonymousContinuations(emitter, ctx, continuations, result_counter);
        return;
    }

    // Flow also has continuations - generate a switch statement. Used by
    // [expand] events with branches: template provides the expression,
    // continuations provide the switch arms.
    if (continuations.len > 0) {
        // The expand result constant is minted from the shared counter, NOT a
        // fixed name: two chained [expand] splices (fmt:ln |> fmt:ln) nest
        // their switches in the same Zig function, and a fixed `__expand_result`
        // shadows across them. Pinned by 620_004_fmt_ln_chained_expand_collision.
        const expand_var = try std.fmt.allocPrint(ctx.allocator, "__expand_result_{d}", .{result_counter.*});
        defer ctx.allocator.free(expand_var);
        result_counter.* += 1;

        // Emit: const __expand_result_N = <inline_code>;
        try emitter.writeIndent();
        try emitter.write("const ");
        try emitter.write(expand_var);
        try emitter.write(" = ");
        try writeInlineCodeWithLabel(emitter, ctx, inline_code);
        try emitter.write(";\n");

        // Emit: switch (__expand_result_N) { ... }
        try emitter.writeIndent();
        try emitter.write("switch (");
        try emitter.write(expand_var);
        try emitter.write(") {\n");
        emitter.indent();

        // Emit each continuation as a switch arm. The arms share the CALLER's
        // result counter: an [expand] splice (e.g. std/fmt:ln mid-chain) emits
        // its arms in the same Zig function scope as the enclosing flow, so a
        // fresh 0-based counter here re-issues result_N names that shadow the
        // enclosing scope's (`local constant 'result_0' shadows local constant
        // from outer scope`). Pinned by 620_003_fmt_ln_mid_chain_result_collision.
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
            try emitContinuationBody(emitter, ctx, cont, result_counter);

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
    const prev_scope_bindings_len = ctx.zig_scope_bindings.items.len;
    defer {
        ctx.current_flow_annotations = prev_flow_annotations;
        ctx.current_flow_location = prev_flow_location;
        while (ctx.zig_scope_bindings.items.len > prev_scope_bindings_len) {
            const name = ctx.zig_scope_bindings.pop() orelse break;
            ctx.allocator.free(name);
        }
    }

    // Preamble code: emitted BEFORE continuations. ~const/~for/~if/~capture set it
    // to REPLACE the invocation (emit continuations directly, no handler call). A
    // routed transform (field:new.on-stack→new-instack) marks its invocation
    // @preamble_then_call: emit the preamble (caller-frame stack vars), then FALL
    // THROUGH to the normal invocation+continuation emission so the handler call
    // (and the field binding) still happen.
    if (flow.preamble_code) |preamble| {
        var keep_call = false;
        for (flow.inv().marks) |mark| {
            if (std.mem.eql(u8, mark, "@preamble_then_call")) {
                keep_call = true;
                break;
            }
        }
        try emitter.write(preamble);
        try emitter.write("\n");

        if (!keep_call) {
            // Now emit continuation bodies directly - no switch, no handler call
            // The preamble already set up the binding (e.g., `const cfg = ...;`)
            // Each continuation's node is the code that should run
            var result_counter: usize = 0;
            for (flow.body.continuations) |*cont| {
                try emitContinuationBody(emitter, ctx, cont, &result_counter);
            }
            return; // Done - don't emit the invocation
        }
        // else: fall through — emit the normal handler call + continuations below
    }

    // Zero-overhead control flow: if a template transform set inline_body, emit
    // it (and any continuations) via the shared node emitter — the same path a
    // nested inline node takes, so this works at every depth, not just top-level.
    //
    // The rendered body can live on the head INVOCATION, not the flow: a nested
    // `~for` under a `! query` arm is rendered by renderNestedTemplates onto
    // `node.invocation.inline_body`, and the store transform then moves that
    // node into the synthesized sweepbody flow's head — `flow.inline_body`
    // stays null while `flow.inv().inline_body` carries the render. Emitting the
    // head as a raw `_event.handler(...)` drops the loop AND writes the range
    // literal verbatim into the struct init (`.{ .expr = 0..9 }` — invalid Zig).
    // The JS lane honors this through emitInvocationWithContinuations
    // (js_emitter.zig `inv.inline_body` check); this is the Zig twin.
    const head_inline_body = flow.inline_body orelse flow.inv().inline_body;
    if (head_inline_body) |inline_code_raw| {
        var inline_result_counter: usize = 0;
        try emitInlineBodyNode(emitter, ctx, inline_code_raw, flow.body.continuations, &flow.inv().path, &inline_result_counter, flow.inv().return_binding);
        return;
    }

    var result_counter: usize = 0;

    // Set current source event for tap matching
    const source_event = try buildCanonicalEventName(&flow.inv().path, ctx.allocator, ctx.main_module_name);
    defer ctx.allocator.free(source_event);
    ctx.current_source_event = source_event;

    // Check if this flow has a pre_label - if so, emit state variables and wrap in a while loop
    if (flow.pre_label) |label| {
        // Look up event definition to get parameter types
        const event_decl = findEventDeclForEmission(ctx, &flow.inv().path);

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
            // var only where a jump actually re-seeds this field — an
            // under-filled jump leaves the rest carried over, and `var` on a
            // never-assigned local is a backend error.
            if (labelFieldWillBeMutated(label, arg.name, flow.body.continuations)) {
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
                const found_field = try writeArgFieldTypeAnnotation(emitter, event, arg.name, ctx.main_module_name);

                // CRITICAL: If mutable and field not found, this is a compiler bug
                if (label_is_mutable and !found_field) {
                    std.debug.panic("COMPILER BUG: Cannot find field '{s}' in event declaration when emitting mutable label '{s}'", .{ arg.name, label });
                }
            }

            try emitter.write(" = ");
            try emitter.write(lowerExprZig(emitter, ctx, arg.value));
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
    const event_decl_for_partition = findEventDeclForEmission(ctx, &flow.inv().path);

    // Subflow-implemented effects: when the head fires one of the implemented
    // event's own arms, its multi-arm resume sum is consumed as `|` branches
    // right here at the firing site (`request = ask(payload) | halved v => …`).
    // Expose the declared arms so the continuation switch can answer payload
    // questions from the resume sum (the head is an arm, not an event).
    const head_arm: ?*const ast.Branch = if (ctx.impl_event_decl) |impl_ev|
        findEffectArm(impl_ev, &flow.inv().path)
    else
        null;
    const saved_resume_arms = ctx.current_resume_arms;
    if (head_arm) |arm| ctx.current_resume_arms = arm.resume_arms;
    defer ctx.current_resume_arms = saved_resume_arms;

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
            // result_counter is flow-local — reused across flows — but
            // Handlers_N names land in main_module at module scope, so two
            // pump sites in different flows collide (koice: host.run's
            // hotkey arm vs a nested frames arm both emitted
            // __HandlersCaps_4). capture_counter is the module-unique
            // counter, same role as capture type names.
            const hname = try std.fmt.allocPrint(ctx.allocator, "Handlers_{d}", .{ctx.capture_counter});
            ctx.capture_counter += 1;
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

        // If we have a pre_label, the invocation is the loop's head: the state
        // vars emitted above feed an in-loop `const` call each turn, and the
        // continuation switch over ALL arms decides `continue :label` vs
        // fall-through to `break :label`.
        if (flow.pre_label) |label| {
            try emitter.writeIndent();
            try emitter.write(label);
            try emitter.write(": while (true) {\n");
            emitter.indent();

            try emitter.writeIndent();
            try emitter.write("const ");
            try emitter.write(first_result);
            try emitter.write(" = ");
            if (!ctx.is_sync) {
                try emitter.write("try ");
            }
            try emitInvocationTarget(emitter, ctx, &flow.inv().path);
            try emitter.write(".handler(.{ ");
            // Use state variables for the call
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
        } else {
            if (inline_elig) |elig| {
                try emitInlineEffectfulCall(emitter, ctx, flow.inv(), flow.body.continuations, elig, first_result);
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

        // If we have a pre_label, ONE exhaustive switch over ALL continuations
        // runs inside the loop: looping arms end in `continue :label`, every
        // other path falls through to `break :label` — uniform for 0, 1, or
        // many looping branches.
        if (flow.pre_label) |label| {
            // suppress_tag_guard=false: with the while-guard gone, a sparse
            // single arm needs its `if (result == .b)` tag test to preserve the
            // old loop-exit semantics on unhandled branches.
            try emitContinuationList(emitter, ctx, conts, first_result, &result_counter, false, &flow.inv().path, false);

            try emitter.writeIndent();
            try emitter.write("break :");
            try emitter.write(label);
            try emitter.write(";\n");
            emitter.dedent();
            try emitter.writeIndent();
            try emitter.write("}\n");
            try emitFoldFallthroughGuard(emitter, ctx);
        } else {
            // No pre_label - emit all continuations normally.
            // A head step that declares NO terminal branches (a branchless
            // statement template like `std/io:print.ln`) assigns no switchable
            // result — `first_result` was emitted as a discard. Its terminal
            // continuations (`=> ok`, the CALLER's re-raise constructing this
            // flow's branches) are straight-line returns, not tag reads:
            // emit each via the void-chain body path, which lowers a
            // branch_constructor terminal to `return .ok;`. Dispatching them
            // through emitContinuationList would tag-read `result_N.ok` on a
            // result that was never assigned and the handler falls off the end
            // (220_030_void_rereturn_inline_transform).
            var head_step_branchless = false;
            if (event_decl_for_partition) |ed| {
                var n: usize = 0;
                for (ed.branches) |b| {
                    if (b.kind == .terminal) n += 1;
                }
                // A branchless statement TEMPLATE (e.g. print.ln — annotated
                // `[comptime|transform]`, lowers to a verbatim statement, not a
                // value) assigns no switchable result, so a terminal
                // continuation on its step is the CALLER's straight-line
                // `=> branch` return — not a tag-read dispatch. A `-> T`
                // bare-return event (double) has no terminal branches but
                // DOES produce a bindable value (`: d`), so it keeps the
                // normal dispatch path. Only transform-marked branchless
                // events take the direct-return route (220_030).
                var is_transform_template = false;
                for (ed.annotations) |ann| {
                    if (std.mem.eql(u8, ann, "transform")) {
                        is_transform_template = true;
                        break;
                    }
                }
                head_step_branchless = n == 0 and is_transform_template;
            }
            if (head_step_branchless) {
                for (conts) |*c| {
                    if (c.branch.len != 0) {
                        try emitContinuationBody(emitter, ctx, c, &result_counter);
                    }
                }
            } else {
                try emitContinuationList(emitter, ctx, conts, first_result, &result_counter, false, &flow.inv().path, true);
            }
        }
    } else {
        // Zero continuations — use comptime_result_binding if set (for program return)
        const binding = if (ctx.comptime_result_binding) |b| b else "_";
        if (inline_elig != null and ctx.comptime_result_binding == null) {
            try emitInlineEffectfulCall(emitter, ctx, flow.inv(), flow.body.continuations, inline_elig.?, null);
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

/// The items list that directly contains `decl` — a module_decl's items when
/// the event is module-nested, else `items` itself. Module-nested decls carry
/// unqualified paths (`["drain"]` inside both `std.node` and `std.fleet`), so
/// a bare-segment scan across all items first-matches by ITEM ORDER, not by
/// the module the resolved event actually lives in — `std/node:drain`'s proc
/// spliced into a `std/fleet:drain` call once a `std/node:drain` call pulled
/// it into the retained set (470_015). Scoping to the decl's own module
/// restores the qualifier its path never carried.
fn itemsOfDecl(items: []const ast.Item, decl: *const ast.EventDecl) []const ast.Item {
    for (items) |*item| {
        switch (item.*) {
            .module_decl => |*m| {
                for (m.items) |*mi| {
                    if (mi.* == .event_decl and &mi.event_decl == decl) return m.items;
                }
            },
            .event_decl => |*ed| {
                if (ed == decl) return items;
            },
            else => {},
        }
    }
    return items;
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
    proc: ?*const ast.ProcDecl,
    flow: ?*const ast.Flow,
};

/// Whether `build:variants` selected a variant for this invocation AND a
/// `~proc <event>|<variant>` exists to satisfy it.
///
/// The canonical key is built exactly as the call path builds it (see
/// `getVariant` in emitInvocationWithBinding) — `module:seg.seg`. Two spellings
/// of one key would put the two paths back out of step, which is the whole
/// defect this answers.
fn registeredVariantProcExists(
    items: []const ast.Item,
    event_decl: *const ast.EventDecl,
    path: *const ast.DottedPath,
) bool {
    var canonical_buf: [256]u8 = undefined;
    var canonical_len: usize = 0;

    if (path.module_qualifier) |mq| {
        if (canonical_len + mq.len + 1 > canonical_buf.len) return false;
        @memcpy(canonical_buf[canonical_len .. canonical_len + mq.len], mq);
        canonical_len += mq.len;
        canonical_buf[canonical_len] = ':';
        canonical_len += 1;
    }
    for (path.segments, 0..) |segment, i| {
        if (i > 0) {
            if (canonical_len + 1 > canonical_buf.len) return false;
            canonical_buf[canonical_len] = '.';
            canonical_len += 1;
        }
        if (canonical_len + segment.len > canonical_buf.len) return false;
        @memcpy(canonical_buf[canonical_len .. canonical_len + segment.len], segment);
        canonical_len += segment.len;
    }

    const selected = getVariant(canonical_buf[0..canonical_len]) orelse return false;

    const variant_procs = findVariantProcsByPath(std.heap.page_allocator, items, &event_decl.path) catch return false;
    defer std.heap.page_allocator.free(variant_procs);
    for (variant_procs) |vp| {
        const target = vp.target orelse continue;
        if (std.mem.eql(u8, target, selected)) return true;
    }
    return false;
}

/// Decide whether this flow's invocation takes the inline lowering.
/// Returning null means: legacy call path, exactly today's behavior.
fn inlineEffectfulEligibility(ctx: *EmissionContext, inv: *const ast.Invocation, conts: []const ast.Continuation) ?InlineEligibility {
    const event_decl = findEventDeclForEmission(ctx, &inv.path) orelse return null;
    // Every lookup below must search the list that actually contains the
    // decl — module-scoped `ast_items` does not see cross-module targets
    // (400_198).
    const items: []const ast.Item = if (ctx.ast_items) |ai|
        (if (findEventDeclByPath(ai, &inv.path) != null) ai else (ctx.program_items orelse ai))
    else
        (ctx.program_items orelse return null);
    if (inv.variant != null) return null;

    var has_effect = false;
    var has_terminal_branch = false;
    for (event_decl.branches) |b| {
        if (b.kind == .effect) {
            has_effect = true;
            // A resuming effect (single `-> T` or multi-arm sum) needs the
            // handler-call path — inline splicing cannot express a resume value.
            if (b.resume_type != null) return null;
            if (b.resume_arms != null) return null;
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

    // A REGISTERED VARIANT MUST NOT BE SPLICED AWAY. The inline lowering pastes
    // `findDefaultZigProc`'s body straight into the caller — it has no way to
    // say "but a different body was selected". So an effect-bearing event with
    // `~proc run|zig` and `~proc run|unikraft`, with `unikraft` registered
    // through `std/build:variants`, silently emitted the `|zig` body at the call
    // site and never called the selected one. Not a wrong-code-shape bug: the
    // WRONG PLATFORM'S LOOP ran, and on a target where the default body cannot
    // even compile it surfaced as a libc error naming a call the program does
    // not make. (`inv.variant != null` above already handles the explicit
    // call-site spelling; this is the registry's.)
    //
    // These take the handler-call path, which mangles to `handler__<variant>`
    // and threads the effect arms into it. Only when the selected variant's proc
    // actually exists — otherwise nothing changes and the existing behaviour,
    // right or wrong, is preserved rather than traded for a missing symbol.
    if (registeredVariantProcExists(items, event_decl, &inv.path)) return null;

    // The impl lives beside its event — module-nested decls carry unqualified
    // paths, so the scan must be scoped to the event's own module_decl or a
    // same-named proc from ANY module wins by item order (470_015).
    const event_items = itemsOfDecl(items, event_decl);

    if (findDefaultZigProc(event_items, &event_decl.path)) |proc| {
        // A nested fn makes token rewriting unsound; a terminal-bearing event
        // whose proc never `return`s relies on the legacy glue's synthesized
        // tail. Both keep the call path.
        if (codegen_utils.containsToken(proc.body.text, "fn")) return null;
        if (has_terminal_branch and !codegen_utils.containsToken(proc.body.text, "return")) return null;

        // Inline splicing lowers an effect arm only in DIRECT-CALL form
        // (`ready(...)` → splice, or evaluate-and-discard when unhandled). A body
        // that references an arm as a VALUE — `if (ready) |f| f()`, or a
        // required arm stored for later fire (`frame_cb = frame` — metal's
        // `frames` registers the `! frame` handler for the live-resize redraw
        // path) — has no such local in the spliced frame, so the reference
        // leaks a raw Zig `undeclared identifier`. Those bodies keep the
        // handler-call path, which emits the alias prelude
        // (`emitOptionalArmNullableAlias` for `! ?`; `const NAME = __H.NAME`
        // for required arms — a real fn value either way).
        // (400_168; the koru-libs vaxis `run` wrapper, guarded-only consumer.)
        if (procRefsAnyArmAsValue(proc.body.text, event_decl)) return null;

        return .{ .event_decl = event_decl, .proc = proc, .flow = null };
    }

    // No `~proc|zig` impl — a pure-Koru flow-bodied (subflow-implemented)
    // event is eligible too: same in-flow-scope splice, just rendered from
    // the flow's continuations instead of a raw Zig proc body.
    //
    // Optional effect arms are fine here: `renderEffectfulFlowBody` arms
    // `ctx.inline_fire_conts`, so presence guards rewrite to comptime
    // `true`/`false` from the caller's installed continuations (not
    // `@hasDecl(__H, ...)`), template-baked `@hasDecl` is rewritten the
    // same way, and unhandled optional fires no-op at the impl-fire site.
    // Pins: 833 (fold × optional arm), 400_145/154 (omitted optional).

    const found = findImplByPath(event_items, &event_decl.path) orelse return null;
    switch (found) {
        .flow => |flow| return .{ .event_decl = event_decl, .proc = null, .flow = flow },
        else => return null,
    }
}

/// True if the proc body references any OPTIONAL effect arm as a VALUE rather
/// than a direct call — e.g. `if (ready) |f| f()` (the handler-path nullable
/// contract) instead of `ready(...)`. The inline splice lowers only direct
/// calls, so a value reference has no local in the spliced frame and leaks a
/// raw `undeclared identifier`. Names are matched in their emitted (Zig-
/// sanitized: `-` → `_`) form, since that is how the body spells them. (400_168)
fn procRefsAnyArmAsValue(body: []const u8, event_decl: *const ast.EventDecl) bool {
    for (event_decl.branches) |b| {
        if (b.kind != .effect) continue;
        if (std.mem.eql(u8, b.name, "*")) continue;
        var name_buf: [128]u8 = undefined;
        if (b.name.len > name_buf.len) continue;
        for (b.name, 0..) |ch, i| name_buf[i] = if (ch == '-') '_' else ch;
        const name = name_buf[0..b.name.len];
        if (identUsedAsNonCall(body, name)) return true;
    }
    return false;
}

/// Quote- and comment-aware scan: true if `name` appears as a word-boundary
/// token whose next non-whitespace character is NOT `(` — i.e. used as a value,
/// not called.
fn identUsedAsNonCall(body: []const u8, name: []const u8) bool {
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
        if (std.mem.startsWith(u8, body[i..], name)) {
            const before_ok = i == 0 or !(std.ascii.isAlphanumeric(body[i - 1]) or body[i - 1] == '_' or body[i - 1] == '.');
            const after = i + name.len;
            const after_ok = after >= body.len or !(std.ascii.isAlphanumeric(body[after]) or body[after] == '_');
            if (before_ok and after_ok) {
                // Peek past whitespace for a call `(`.
                var j = after;
                while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) j += 1;
                if (j >= body.len or body[j] != '(') return true;
            }
        }
    }
    return false;
}

/// True when `body` calls `name(` — the identifier on identifier boundary
/// (so `__row(` doesn't match `row(`; dotted `x.row(` doesn't match `row(` —
/// a field call is not the branch alias), optional whitespace, then `(`.
/// Skips string/char literals and line comments like containsToken does.
fn callsBranchByName(body: []const u8, name: []const u8) bool {
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
        if (std.mem.startsWith(u8, body[i..], name)) {
            const before_ok = i == 0 or !(std.ascii.isAlphanumeric(body[i - 1]) or body[i - 1] == '_' or body[i - 1] == '.');
            var j = i + name.len;
            while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n')) j += 1;
            if (before_ok and j < body.len and body[j] == '(') return true;
        }
    }
    return false;
}

/// Rewrite a proc body for inline splicing: effect calls → splice markers
/// (or evaluate-and-discard for unhandled optional effects), depth-any
/// `return` → labeled break, `std.` → `@import("std").` (inlined bodies
/// lose their module scope), `$mod.` → the declaring module's emitted
/// namespace (`mod_prefix`, e.g. `koru_libs.koru_raylib.`) — the sanctioned
/// spelling for a proc body reaching its OWN module scope, valid under every
/// lowering. Quote- and comment-aware throughout.
const RewrittenProcBody = struct { text: []u8, has_break: bool };

fn rewriteEffectfulProcBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    event_decl: *const ast.EventDecl,
    conts: []const ast.Continuation,
    break_label: []const u8,
    mod_prefix: []const u8,
    site_suffix: []const u8,
) !RewrittenProcBody {
    var scan = ProcBodyScan{ .out = try std.ArrayList(u8).initCapacity(allocator, body.len + 256) };
    errdefer scan.out.deinit(allocator);

    // Effect branch → handled continuation index (or null = unhandled optional).
    const EffectSite = struct { lowered: []const u8, cont_idx: ?usize };
    const sites_buf = try allocator.alloc(EffectSite, event_decl.branches.len);
    defer allocator.free(sites_buf);
    const name_bufs = try allocator.alloc([128]u8, event_decl.branches.len);
    defer allocator.free(name_bufs);
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
                    if (rest.len > fname.len and std.mem.startsWith(u8, rest, fname) and rest[fname.len] == ';') {
                        // Allow a trailing line comment after the `;` (e.g.
                        // `_ = title;  // not yet threaded`) — still a standalone
                        // redundant param discard; don't strip if real code follows.
                        const after = std.mem.trim(u8, rest[fname.len + 1 ..], " \t\r");
                        if (after.len == 0 or std.mem.startsWith(u8, after, "//")) {
                            is_param_discard = true;
                            break;
                        }
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

    while (scan.i < clean_body.len) {
        const c = clean_body[scan.i];
        switch (try procBodyScanStep(&scan, allocator, clean_body, .{ .break_label = break_label, .mod_prefix = mod_prefix })) {
            .consumed => continue,
            .copy => {
                try scan.out.append(allocator, c);
                scan.i += 1;
                continue;
            },
            .at_boundary => {},
        }
        const i = scan.i;
        // `__x` → `__x_<site>`: proc-body internals get a per-splice
        // suffix. The body lands in the caller's frame, where locals
        // from other inlined bodies (and emitter helpers like print's
        // `__kw`/`__f`) collide by natural name — nested `packets`
        // inside `ticks` hit "shadows local" on `__i` (koru-libs
        // asteroids-net). `__` is the author's internal namespace:
        // Koru bindings can't spell it and `.`-access is boundary-
        // excluded, so a uniform token rename is safe. `__koru_*` is
        // the emitter's own namespace (markers, scaffolding) — leave it.
        if (std.mem.startsWith(u8, clean_body[i..], "__") and
            i + 2 < clean_body.len and
            (std.ascii.isAlphabetic(clean_body[i + 2]) or clean_body[i + 2] == '_') and
            !std.mem.startsWith(u8, clean_body[i..], "__koru"))
        {
            var j = i + 2;
            while (j < clean_body.len and
                (std.ascii.isAlphanumeric(clean_body[j]) or clean_body[j] == '_')) j += 1;
            try scan.out.appendSlice(allocator, clean_body[i..j]);
            try scan.out.appendSlice(allocator, site_suffix);
            scan.i = j;
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
                try scan.out.appendSlice(allocator, INLINE_SPLICE_PREFIX);
                var nb: [16]u8 = undefined;
                try scan.out.appendSlice(allocator, std.fmt.bufPrint(&nb, "{d}", .{ci}) catch unreachable);
                scan.i = j; // resume at '(' — the resolver reads the args
            } else {
                // Unhandled optional effect: the fire folds away and the
                // payload is NEVER evaluated (the 400_145 ruling). `@TypeOf`
                // is the spelling: it marks the payload identifiers used
                // without evaluating them — where the old `_ = (payload)`
                // both evaluated it AND tripped Zig's pointless-discard on
                // a payload also used elsewhere (400_178). A VOID arm
                // (`focus_in()`) has no payload, and `@TypeOf()` is invalid
                // Zig — discard a void block instead and consume the `()`.
                var k = j + 1; // past '('
                while (k < clean_body.len and (clean_body[k] == ' ' or clean_body[k] == '\t' or clean_body[k] == '\n' or clean_body[k] == '\r')) k += 1;
                if (k < clean_body.len and clean_body[k] == ')') {
                    try scan.out.appendSlice(allocator, "_ = {}");
                    scan.i = k + 1; // resume past ')'
                } else {
                    try scan.out.appendSlice(allocator, "_ = @TypeOf");
                    scan.i = j; // resume at '(' — Zig reads the args
                }
            }
            matched = true;
            break;
        }
        if (matched) continue;

        try scan.out.append(allocator, c);
        scan.i += 1;
    }

    return .{ .text = try scan.out.toOwnedSlice(allocator), .has_break = scan.has_break };
}

/// Which boundary rewrites a proc-body scan applies: a non-null
/// `break_label` turns `return` into `break :<label>`; `rewrite_std` maps
/// `std.` → `@import("std").`; `mod_prefix` maps `$mod.` → the prefix
/// (null strips it bare).
const ProcScanRules = struct {
    break_label: ?[]const u8 = null,
    rewrite_std: bool = true,
    mod_prefix: ?[]const u8 = null,
};

/// One position of the proc-body rewrite scan: quote state, `//` comments,
/// and the boundary calc (a preceding '.' blocks the rewrite — UNLESS it is
/// the second dot of the range operator, `[0..$mod.len]`, 400_179).
/// `.at_boundary` tells the caller its own boundary rules may still fire at
/// this position.
const ProcScanStep = enum { consumed, at_boundary, copy };

const ProcBodyScan = struct {
    out: std.ArrayList(u8),
    i: usize = 0,
    q: u8 = 0,
    has_break: bool = false,
};

fn procBodyScanStep(
    scan: *ProcBodyScan,
    allocator: std.mem.Allocator,
    body: []const u8,
    rules: ProcScanRules,
) !ProcScanStep {
    const c = body[scan.i];
    if (scan.q != 0) {
        try scan.out.append(allocator, c);
        if (c == '\\') {
            if (scan.i + 1 < body.len) try scan.out.append(allocator, body[scan.i + 1]);
            scan.i += 2;
            return .consumed;
        }
        if (c == scan.q) scan.q = 0;
        scan.i += 1;
        return .consumed;
    }
    if (c == '"' or c == '\'') {
        scan.q = c;
        try scan.out.append(allocator, c);
        scan.i += 1;
        return .consumed;
    }
    if (c == '/' and scan.i + 1 < body.len and body[scan.i + 1] == '/') {
        while (scan.i < body.len and body[scan.i] != '\n') : (scan.i += 1) try scan.out.append(allocator, body[scan.i]);
        return .consumed;
    }

    // A preceding '.' blocks the rewrite (member chains: `x.std.`) — UNLESS
    // it is the second dot of the range operator (`[0..$mod.len]`, 400_179),
    // which is a boundary, not member access.
    const i = scan.i;
    const after_range_op = i >= 2 and body[i - 1] == '.' and body[i - 2] == '.';
    const boundary_before = i == 0 or after_range_op or !(std.ascii.isAlphanumeric(body[i - 1]) or body[i - 1] == '_' or body[i - 1] == '.');
    if (boundary_before) {
        // `return` → labeled break (any depth: every return is a proc exit).
        if (rules.break_label) |label| {
            if (std.mem.startsWith(u8, body[i..], "return")) {
                const after = i + "return".len;
                if (after >= body.len or !(std.ascii.isAlphanumeric(body[after]) or body[after] == '_')) {
                    try scan.out.appendSlice(allocator, "break :");
                    try scan.out.appendSlice(allocator, label);
                    scan.has_break = true;
                    scan.i = after;
                    return .consumed;
                }
            }
        }
        // `std.` → `@import("std").` (module scope does not travel).
        if (rules.rewrite_std and std.mem.startsWith(u8, body[i..], "std.")) {
            try scan.out.appendSlice(allocator, "@import(\"std\").");
            scan.i += "std.".len;
            return .consumed;
        }
        // `$mod.` → declaring module's namespace (module scope, spelled);
        // null prefix = the Handlers-fn path, where `$mod.` strips bare.
        if (std.mem.startsWith(u8, body[i..], "$mod.")) {
            if (rules.mod_prefix) |prefix| try scan.out.appendSlice(allocator, prefix);
            scan.i += "$mod.".len;
            return .consumed;
        }
        return .at_boundary;
    }
    return .copy;
}

/// Depth-any `return` → labeled break, `std.` → `@import("std").` — the
/// tail half of `rewriteEffectfulProcBody`'s scan (effect-call splicing
/// stripped out), factored out so `renderEffectfulFlowBody` can apply the
/// identical rewrite to AST-emitted Zig text instead of raw proc source.
/// Quote- and comment-aware; leaves `__koru_inline_*` splice markers alone
/// (they contain no `return`/`std.` tokens).
fn rewriteReturnsAndStd(
    allocator: std.mem.Allocator,
    body: []const u8,
    break_label: []const u8,
    mod_prefix: []const u8,
) !RewrittenProcBody {
    var scan = ProcBodyScan{ .out = try std.ArrayList(u8).initCapacity(allocator, body.len + 256) };
    errdefer scan.out.deinit(allocator);

    while (scan.i < body.len) {
        const c = body[scan.i];
        if (try procBodyScanStep(&scan, allocator, body, .{ .break_label = break_label, .mod_prefix = mod_prefix }) == .consumed) continue;
        try scan.out.append(allocator, c);
        scan.i += 1;
    }

    return .{ .text = try scan.out.toOwnedSlice(allocator), .has_break = scan.has_break };
}

/// Render a flow-bodied (subflow-implemented) effect event's impl body,
/// splice-ready — the flow-backed counterpart to `rewriteEffectfulProcBody`
/// for events with no `~proc|zig` impl (a pure-Koru generator body). Emits
/// the flow through the ordinary AST-driven `emitFlow`, with
/// `ctx.impl_event_decl`/`ctx.inline_fire_conts` armed so the flow's own
/// arm-fires (`emitInvocation`'s impl-fire branch) resolve to
/// `__koru_inline_<idx>(...)` splice markers against the CALLER's `conts`
/// instead of `__H.<arm>(...)` calls. `emitFlow` does not emit the event's
/// input-field binds or `__H` arm aliases — those are the caller's job in
/// the legacy standalone-function path (`emitEventDeclForModule`) — so this
/// text is exactly the body, matching what `rewriteEffectfulProcBody`
/// produces for a raw `~proc|zig` body. The resulting text still carries
/// ordinary `return`s wherever the flow's own terminal branch completes
/// (identical to how a proc body would `return`), so it gets the same
/// `return` → `break :<break_label>` / `std.` → `@import("std").` rewrite.
fn renderEffectfulFlowBody(
    ctx: *EmissionContext,
    event_decl: *const ast.EventDecl,
    flow: *const ast.Flow,
    conts: []const ast.Continuation,
    break_label: []const u8,
    mod_prefix: []const u8,
) !RewrittenProcBody {
    var sub = try CodeEmitter.initGrowable(ctx.allocator, 2048);
    defer if (sub.allocator) |a| a.free(sub.buffer);

    const saved_impl_event = ctx.impl_event_decl;
    const saved_inline_fire_conts = ctx.inline_fire_conts;
    ctx.impl_event_decl = event_decl;
    ctx.inline_fire_conts = conts;
    defer {
        ctx.impl_event_decl = saved_impl_event;
        ctx.inline_fire_conts = saved_inline_fire_conts;
    }

    try emitFlow(&sub, ctx, flow);

    // Template-baked presence (`~if(arm)` → `@hasDecl(__H, "arm")` in
    // template_processor) still names `__H`, which the inline splice has
    // no. Rewrite those to comptime true/false from the caller's conts —
    // same resolution as `presenceConditionRewrite` for AST `if`/`when`.
    const with_presence = try rewriteInlineHasDeclPresence(
        ctx.allocator,
        sub.buffer[0..sub.pos],
        conts,
    );
    defer ctx.allocator.free(with_presence);

    return try rewriteReturnsAndStd(ctx.allocator, with_presence, break_label, mod_prefix);
}

/// `$mod.` → bare, for proc bodies emitted INSIDE their module namespace
/// (the standalone Handlers-fn path): there the module's decls are in lexical
/// scope, so the sanctioned `$mod.` spelling strips to nothing. Keeps the one
/// spelling valid under both lowerings. Quote- and comment-aware, boundary-
/// checked like the splice-path rewrites.
pub fn rewriteModToBare(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var scan = ProcBodyScan{ .out = try std.ArrayList(u8).initCapacity(allocator, body.len) };
    errdefer scan.out.deinit(allocator);
    while (scan.i < body.len) {
        const c = body[scan.i];
        if (try procBodyScanStep(&scan, allocator, body, .{ .rewrite_std = false }) == .consumed) continue;
        try scan.out.append(allocator, c);
        scan.i += 1;
    }
    return try scan.out.toOwnedSlice(allocator);
}

/// Replace template-baked `@hasDecl(__H, "<arm>")` with `true`/`false` from
/// the caller's installed effect continuations. The `~if` template resolves
/// presence at render time (upstream of every emitter site) into a `__H`
/// lookup that is only sound on the Handlers-fn path; the inline splice
/// rewrites those lookups per call site (400_154 × 833).
fn rewriteInlineHasDeclPresence(
    allocator: std.mem.Allocator,
    body: []const u8,
    fire_conts: []const ast.Continuation,
) ![]u8 {
    const needle = "@hasDecl(__H, \"";
    var out = try std.ArrayList(u8).initCapacity(allocator, body.len);
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos < body.len) {
        if (std.mem.indexOfPos(u8, body, pos, needle)) |at| {
            try out.appendSlice(allocator, body[pos..at]);
            var i = at + needle.len;
            const name_start = i;
            while (i < body.len and body[i] != '"') : (i += 1) {}
            if (i >= body.len or i + 1 >= body.len or body[i + 1] != ')') {
                // Malformed — emit verbatim from the match and stop scanning.
                try out.appendSlice(allocator, body[at..]);
                break;
            }
            const arm_name = body[name_start..i];
            var present = false;
            for (fire_conts) |*c| {
                if (c.kind == .effect and std.mem.eql(u8, c.branch, arm_name)) {
                    present = true;
                    break;
                }
            }
            try out.appendSlice(allocator, if (present) "true" else "false");
            pos = i + 2; // past `" )`
            continue;
        }
        try out.appendSlice(allocator, body[pos..]);
        break;
    }
    return try out.toOwnedSlice(allocator);
}

/// Give this rendered template body its own `for` loop capture, or null when it
/// carries none. Returns an OWNED copy; the caller frees it.
///
/// The `~for` template (koru_std/control.kz) renders a hardcoded
/// `for (..) |__koru_item|` and passes `__koru_item` as the splice arg, so two
/// instances in one Zig function collide: `capture '__koru_item' shadows
/// capture from outer scope`.
///
/// TWO emit paths render a template body into the enclosing scope — the
/// site-local inline splice and the effect-INLINING splice below — and only the
/// first did this. Which path a nested `for` takes is decided by inline
/// eligibility, not by the source, so the SAME program compiled from the entry
/// file and from an imported module took different paths and only one of them
/// was safe (115_004 against its green original 2106). One implementation, two
/// call sites, so the next path to render a template inherits the fix rather
/// than the bug.
/// std.mem.replaceOwned, but a hit only counts when the character AFTER the
/// needle is not an identifier char — `__koru_item` matches, `__koru_item4`
/// does not. Used where a rewrite must touch only the raw template spelling
/// and leave already-unique names alone.
fn replaceOwnedWordBoundary(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const T,
    needle: []const T,
    replacement: []const T,
) ![]T {
    var out = std.ArrayList(T).empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (std.mem.indexOfPos(T, input, pos, needle)) |hit| {
        const tail = hit + needle.len;
        if (tail < input.len and isIdentChar(input[tail])) {
            try out.appendSlice(allocator, input[pos..tail]);
            pos = tail;
            continue;
        }
        try out.appendSlice(allocator, input[pos..hit]);
        try out.appendSlice(allocator, replacement);
        pos = tail;
    }
    try out.appendSlice(allocator, input[pos..]);
    return out.toOwnedSlice(allocator);
}

fn uniquifyForCapture(ctx: *EmissionContext, code: []const u8) !?[]u8 {
    const KORU_ITEM = "__koru_item";
    var current: ?[]u8 = null;

    // Bare `__koru_item` only — a name the template already made site-unique
    // (`__koru_item{{ __site }}` → `__koru_item4`) must NOT be rewritten again,
    // or the pass would mint `__koru_item_04`. The boundary check is the same
    // token rule the compiler applies: an identifier char adjacent means the
    // name is already someone's, not the raw template spelling.
    var scan: usize = 0;
    var bare_found = false;
    while (std.mem.indexOfPos(u8, code, scan, KORU_ITEM)) |hit| {
        const tail = hit + KORU_ITEM.len;
        const bare = tail >= code.len or !isIdentChar(code[tail]);
        if (bare) {
            bare_found = true;
            break;
        }
        scan = tail;
    }
    if (bare_found) {
        const for_id = ctx.for_counter;
        ctx.for_counter += 1;
        var unique_buf: [64]u8 = undefined;
        const unique_item = std.fmt.bufPrint(&unique_buf, "__koru_item_{d}", .{for_id}) catch KORU_ITEM;
        current = try replaceOwnedWordBoundary(u8, ctx.allocator, code, KORU_ITEM, unique_item);
    }

    // USER-authored captures collide the same way the template's does: two
    // nested inlined frames of the same proc body each declare `|i|`, and Zig
    // rejects the inner as "capture shadows capture from outer scope"
    // (230_015). Collision-driven: only a capture name an enclosing spliced
    // body already declares is renamed, so everything unnested keeps the
    // author's spelling.
    const scan_src: []const u8 = current orelse code;
    var declared: std.ArrayList([]const u8) = .empty;
    defer declared.deinit(ctx.allocator);
    try codegen_utils.collectZigCaptureNames(ctx.allocator, scan_src, &declared);
    // The collected names are slices into scan_src, which a rename below may
    // free — own them for the loop's lifetime.
    for (declared.items) |*n| n.* = try ctx.allocator.dupe(u8, n.*);
    defer for (declared.items) |n| ctx.allocator.free(n);
    for (declared.items) |name| {
        var colliding = false;
        for (ctx.active_capture_names.items) |active| {
            if (std.mem.eql(u8, name, active)) {
                colliding = true;
                break;
            }
        }
        if (!colliding) continue;
        const for_id = ctx.for_counter;
        ctx.for_counter += 1;
        var rename_buf: [96]u8 = undefined;
        const renamed = std.fmt.bufPrint(&rename_buf, "{s}_{d}", .{ name, for_id }) catch continue;
        const rewritten = try codegen_utils.replaceIdentifier(ctx.allocator, current orelse code, name, renamed);
        if (current) |owned| ctx.allocator.free(owned);
        current = @constCast(rewritten);
    }

    return current;
}

/// Register a spliced body's payload-capture names as active for the frames
/// nested inside it (see EmissionContext.active_capture_names). Returns how
/// many were pushed; the caller pops the same count at scope exit.
fn pushBodyCaptures(ctx: *EmissionContext, body: []const u8) !usize {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.allocator);
    try codegen_utils.collectZigCaptureNames(ctx.allocator, body, &names);
    var pushed: usize = 0;
    for (names.items) |name| {
        try ctx.active_capture_names.append(ctx.allocator, try ctx.allocator.dupe(u8, name));
        pushed += 1;
    }
    return pushed;
}

fn popBodyCaptures(ctx: *EmissionContext, pushed: usize) void {
    var i: usize = 0;
    while (i < pushed) : (i += 1) {
        const name = ctx.active_capture_names.pop() orelse break;
        ctx.allocator.free(name);
    }
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
) anyerror!void {
    // The label must be unique across NESTED inline splices too: the inner
    // call is emitted while the outer's body renders, so a per-step counter
    // (result_counter) hands the same number to both — `split` nested inside
    // `split`'s own piece arm redefined `__koru_proc_0` (690_191). A
    // monotonic per-call counter on the context has no such nesting collision.
    const proc_uniq = ctx.proc_label_counter;
    ctx.proc_label_counter += 1;
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "__koru_proc_{d}", .{proc_uniq}) catch "__koru_proc";
    // Per-splice suffix for the body's `__`-locals (hygiene — see the
    // `__x` → `__x_<site>` rule in rewriteEffectfulProcBody).
    var suffix_buf: [24]u8 = undefined;
    const site_suffix = std.fmt.bufPrint(&suffix_buf, "_s{d}", .{proc_uniq}) catch "_s";

    // The `$mod.` rewrite target: the declaring module's emitted namespace,
    // resolved from the invocation path exactly as the call target would be.
    const mod_prefix = try renderSelfPrefix(ctx, &inv.path);
    defer ctx.allocator.free(mod_prefix);

    const rewritten = if (elig.proc) |p| blk: {
        // Proc-authored presence probes (`@hasDecl(__H, "<arm>")` — the
        // vaxis:run tick gate, curl's `! ?chunk` drain) name `__H`, which
        // the inline splice has no. Resolve them to comptime true/false
        // from the caller's conts before the arm-call rewrite, exactly as
        // renderEffectfulFlowBody does for template-baked probes
        // (400_177/178 × 400_154 × 833).
        const presence_resolved = try rewriteInlineHasDeclPresence(ctx.allocator, p.body.text, conts);
        defer ctx.allocator.free(presence_resolved);
        break :blk try rewriteEffectfulProcBody(ctx.allocator, presence_resolved, elig.event_decl, conts, label, mod_prefix, site_suffix);
    } else try renderEffectfulFlowBody(ctx, elig.event_decl, elig.flow.?, conts, label, mod_prefix);
    defer ctx.allocator.free(rewritten.text);

    // This path renders a template body into the ENCLOSING scope too, so it
    // needs its own `for` capture for the same reason the site-local splice
    // does — see `uniquifyForCapture`.
    var spliced_text: []const u8 = rewritten.text;
    var spliced_owned: ?[]u8 = null;
    defer if (spliced_owned) |owned| ctx.allocator.free(owned);
    if (try uniquifyForCapture(ctx, rewritten.text)) |uniq| {
        spliced_owned = uniq;
        spliced_text = uniq;
    }
    const pushed_captures = try pushBodyCaptures(ctx, spliced_text);
    defer popBodyCaptures(ctx, pushed_captures);

    // A label is only legal if something breaks to it; a statement block
    // takes no trailing semicolon. (The const form always has breaks —
    // eligibility requires a `return` when terminals exist.)
    const typed_discard = result_name == null and rewritten.has_break;
    // A `: _` capture on the spliced call is a discard, not a binding —
    // `const _: T =` is not legal Zig. It still needs the typed const so
    // anonymous break literals have a result type; discarded after the block.
    const bind_is_discard = if (inv.return_binding) |rb| std.mem.eql(u8, rb, "_") else false;
    const uses_disc_name = typed_discard or (result_name != null and bind_is_discard);
    var disc_buf: [64]u8 = undefined;
    const disc_name = std.fmt.bufPrint(&disc_buf, "__koru_eff_disc_{d}", .{proc_uniq}) catch "__koru_eff_disc";
    const labeled = result_name != null or rewritten.has_break;
    try emitter.writeIndent();
    if (result_name != null and !bind_is_discard) {
        const rn = result_name.?;
        // A `-> T` bare-return call binds its result to the call-site `: name`
        // (return_binding) — the same rule `emitInvocation` follows on the
        // handler-call path. The splice must not drop it, or the author's own
        // name reaches Zig as an undeclared identifier (210_189).
        try emitter.write("const ");
        try writeBranchName(emitter, inv.return_binding orelse rn);
        try emitter.write(": ");
        try emitInvocationTarget(emitter, ctx, &inv.path);
        try emitter.write(".Output = ");
    } else if (uses_disc_name) {
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
    var pushed_arg_bindings: usize = 0;
    defer {
        var popped: usize = 0;
        while (popped < pushed_arg_bindings) : (popped += 1) {
            const b = ctx.inline_arg_bindings.pop() orelse break;
            ctx.allocator.free(b.spelled);
        }
    }
    for (inv.args) |arg| {
        var pun_buf: [128]u8 = undefined;
        const lowered_name = lowerIdent(&pun_buf, arg.name);
        const trimmed_value = std.mem.trim(u8, arg.value, " \t");
        if (std.mem.eql(u8, trimmed_value, lowered_name)) continue;

        // A nested inlined event re-binding the same name to the same value
        // expression reuses the enclosing frame's `const` — re-binding in the
        // nested scope is a Zig shadowing error (230_015). The reused frame's
        // SPELLING carries over, so a renamed outer binding still resolves.
        var spelled: ?[]const u8 = null;
        var rewrites_body = false;
        for (ctx.inline_arg_bindings.items) |b| {
            if (std.mem.eql(u8, b.name, arg.name) and
                std.mem.eql(u8, b.value, trimmed_value))
            {
                spelled = b.spelled;
                rewrites_body = b.rewrites_body;
                break;
            }
        }

        if (spelled == null) {
            // The callee's own param name collides with a name already bound
            // in this Zig function scope — a chain return binding (`: v` —
            // 400_151) or an enclosing inline frame's different-valued arg.
            // Neither author can see the other across the boundary, so the
            // frame's binding site-unique-renames and the body follows.
            const collides = blk: {
                for (ctx.zig_scope_bindings.items) |n| {
                    if (std.mem.eql(u8, n, arg.name)) break :blk true;
                }
                for (ctx.inline_arg_bindings.items) |b| {
                    if (std.mem.eql(u8, b.name, arg.name)) break :blk true;
                }
                break :blk false;
            };
            // Spelling mirrors writeBranchName: kebab mangles, a Zig
            // keyword/primitive escapes (and the body references follow).
            const owned_spelling: []const u8 = blk: {
                if (collides) {
                    break :blk try std.fmt.allocPrint(ctx.allocator, "__koru_arg_{s}_{d}", .{ lowered_name, proc_uniq });
                }
                if (std.mem.indexOfScalar(u8, arg.name, '-') != null) {
                    const mangled = try ctx.allocator.dupe(u8, arg.name);
                    for (mangled) |*c| {
                        if (c.* == '-') c.* = '_';
                    }
                    break :blk mangled;
                }
                if (codegen_utils.needsEscaping(arg.name)) {
                    break :blk try std.fmt.allocPrint(ctx.allocator, "@\"{s}\"", .{arg.name});
                }
                break :blk try ctx.allocator.dupe(u8, arg.name);
            };

            try emitter.writeIndent();
            try emitter.write("const ");
            try emitter.write(owned_spelling);
            try emitter.write(" = (");
            try emitter.write(lowerExprZig(emitter, ctx, arg.value));
            try emitter.write("); _ = &");
            try writeBranchName(emitter, owned_spelling);
            try emitter.write(";\n");
            rewrites_body = collides or
                (std.mem.indexOfScalar(u8, arg.name, '-') == null and codegen_utils.needsEscaping(arg.name));
            try ctx.inline_arg_bindings.append(ctx.allocator, .{
                .name = arg.name,
                .value = trimmed_value,
                .spelled = owned_spelling,
                .rewrites_body = rewrites_body,
            });
            pushed_arg_bindings += 1;
            spelled = owned_spelling;
        }

        // Body references follow the binding's spelling. The kebab mangle is
        // deliberately excluded: its textual form (`a-b`) is subtraction in
        // Zig, so a rewrite could land on arithmetic.
        if (rewrites_body) {
            const rewritten_body = try codegen_utils.replaceIdentifier(ctx.allocator, spliced_text, arg.name, spelled.?);
            if (spliced_owned) |owned| ctx.allocator.free(owned);
            spliced_owned = @constCast(rewritten_body);
            spliced_text = spliced_owned.?;
        }
    }

    // OPTIONAL PARAMETER INJECTION, splice flavor (400_182): an omitted
    // `?T` param binds to a typed null so the spliced body's references
    // resolve — the fourth home of the one rule (see 400_180).
    for (elig.event_decl.input.fields) |field| {
        if (!(field.type.len > 0 and field.type[0] == '?')) continue;
        var provided = false;
        for (inv.args) |arg| {
            if (std.mem.eql(u8, arg.name, field.name)) {
                provided = true;
                break;
            }
        }
        if (provided) continue;
        try emitter.writeIndent();
        try emitter.write("const ");
        try writeBranchName(emitter, field.name);
        try emitter.write(": ");
        try emitter.write(lowerZigType(field.type));
        try emitter.write(" = null; _ = &");
        try writeBranchName(emitter, field.name);
        try emitter.write(";\n");
    }

    try emitter.writeIndent();
    try emitInlineCodeResolvingSplices(emitter, ctx, spliced_text, conts);
    try emitter.write("\n");

    emitter.dedent();
    try emitter.writeIndent();
    try emitter.write(if (result_name != null or uses_disc_name) "};\n" else "}\n");
    if (uses_disc_name) {
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
                            // `| tag *` is a wildcard payload — fields are empty
                            // but the payload EXISTS (anytype). Every other site
                            // counts it (7803/8234/10506); counting only fields
                            // here suppressed the `|b|` capture and left arm
                            // bodies referencing an unbound name.
                            return branch.payload.fields.len > 0 or branch.payload.is_wildcard;
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

/// Write an effect branch's resume type: the single `-> T` type, the
/// `union(enum)` synthesized from its multi-arm resume sum, or `void`.
/// The union is emitted inline in the handler fn signature — the proc binds
/// the result (`const r = ask(payload)`) and switches on it, so the single
/// definition site is the only spelling the program needs.
/// Lower the canonical surface text type `string` to its Zig slice `[]const u8`.
/// The AST carries `string` verbatim (printer/round-trip stay faithful); every
/// site that writes a bare payload/return/resume/arm type to Zig routes through
/// here so `string` never leaks into generated code. Other types pass through.
///
/// NESTED spellings lower at the element too (`[]string` → `[]const []const u8`,
/// `?[]string`, `[]const string`): once the raw byte slice is banned from the
/// surface (510_108), a slice of text can only be spelled with `string` as the
/// element, so the lowering door must open at every depth. Every slice level
/// emits const — text is immutable, and the host command ABI hands `argv` over
/// as `[]const []const u8`. The prefix rewrites into a call-local buffer;
/// CONTRACT: callers must consume the result before the next call — all
/// current sites write it immediately.
threadlocal var lower_zig_type_buf: [256]u8 = undefined;
pub fn lowerZigType(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "string")) return "[]const u8";
    // `?string` lowers through the same door — an optional param spelled
    // with the canonical text type must not leak `?string` into Zig
    // ('use of undeclared identifier', 400_181, found by ai's
    // `system: ?string`).
    if (std.mem.eql(u8, t, "?string")) return "?[]const u8";
    var i: usize = 0;
    while (true) {
        if (std.mem.startsWith(u8, t[i..], "?")) {
            i += 1;
        } else if (std.mem.startsWith(u8, t[i..], "[]")) {
            i += 2;
            if (std.mem.startsWith(u8, t[i..], "const ")) i += 6;
        } else break;
    }
    if (i > 0 and std.mem.eql(u8, t[i..], "string")) {
        var w: usize = 0;
        var r: usize = 0;
        while (r < i) {
            if (std.mem.startsWith(u8, t[r..], "[]")) {
                @memcpy(lower_zig_type_buf[w..][0.."[]const ".len], "[]const ");
                w += "[]const ".len;
                r += 2;
                if (std.mem.startsWith(u8, t[r..], "const ")) r += 6;
            } else {
                lower_zig_type_buf[w] = t[r];
                w += 1;
                r += 1;
            }
        }
        @memcpy(lower_zig_type_buf[w..][0.."[]const u8".len], "[]const u8");
        return lower_zig_type_buf[0 .. w + "[]const u8".len];
    }
    return t;
}

fn writeEffectResumeType(emitter: *CodeEmitter, branch: *const ast.Branch) !void {
    if (branch.resume_arms) |arms| {
        try emitter.write(if (arms.len <= 256) "union(enum(u8)) { " else "union(enum) { ");
        for (arms, 0..) |*arm, i| {
            if (i > 0) try emitter.write(", ");
            try writeBranchName(emitter, arm.name);
            try emitter.write(": ");
            const arm_type = arm.type orelse "void";
            // A record arm (`| result { halved: i32, ... }`) carries its shape
            // as a brace string; Zig spells that type `struct { ... }`.
            if (arm_type.len > 0 and arm_type[0] == '{') try emitter.write("struct ");
            try emitter.write(lowerZigType(arm_type));
        }
        try emitter.write(" }");
    } else if (branch.resume_type) |rt| {
        // An anonymous record resume (`! ask -> { a: i64, b: i64 }`) carries its
        // shape as a brace string; Zig spells that type `struct { ... }`. Mirrors
        // the record-arm case above and the payload-field lowering.
        if (rt.len > 0 and rt[0] == '{') try emitter.write("struct ");
        try emitter.write(lowerZigType(rt));
    } else {
        try emitter.write("void");
    }
}

/// Write the single-parameter payload TYPE of an effect arm's callback — the
/// text between `fn (` and `)`. Empty for a void-payload arm; the bare type for
/// a single `__type_ref`; a `struct { ... }` otherwise.
fn writeArmPayloadParamType(emitter: *CodeEmitter, branch: *const ast.Branch, main_module_name: ?[]const u8) !void {
    if (branch.payload.fields.len == 0) return;
    if (branch.payload.fields.len == 1 and std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref")) {
        try writeFieldType(emitter, branch.payload.fields[0], main_module_name);
    } else {
        try emitter.write("struct { ");
        for (branch.payload.fields, 0..) |field, fi| {
            if (fi > 0) try emitter.write(", ");
            try writeBranchName(emitter, field.name);
            try emitter.write(": ");
            try writeFieldType(emitter, field, main_module_name);
        }
        try emitter.write(" }");
    }
}

/// Emit the presence-aware alias for an OPTIONAL effect arm inside a handler
/// body. The form depends on whether the arm RESUMES a value:
///
///   RESUMING (`-> T`) — a nullable fn pointer; the body must own the absent
///   case, because absence has no value to fabricate:
///     const ask: ?*const fn (i64) i64 = if (@hasDecl(__H, "ask")) &__H.ask else null;
///     // body: `if (ask) |f| return f(q); return <fallback>;`   (400_148)
///
///   YIELDING (void) — an always-CALLABLE alias; present is the real handler,
///   absent is a producer-side no-op with the same payload and void return:
///     const ready = if (@hasDecl(__H, "ready")) __H.ready else struct { fn __koru_noop() void {} }.__koru_noop;
///     // body: `ready();`  — the omitted case optimizes away.
///   The no-op is NOT installed in __H, so `@hasDecl` presence truth for
///   `if(arm)`/`when arm` is untouched — the safe half of the removed-stub idea
///   (contrast the old consumer-side no-op that poisoned presence). This is the
///   canonical yielding-arm contract; a yielding-optional and a required arm now
///   share the same callable form, only resuming-optional is nullable.
///
/// The `@hasDecl` key mirrors the handler-struct field name (`writeBranchName`);
/// simple ASCII arm names in the corpus (`ask`/`note`/`ready`) equal `b.name`.
pub fn emitOptionalArmNullableAlias(emitter: *CodeEmitter, branch: *const ast.Branch, main_module_name: ?[]const u8) !void {
    const is_resuming = branch.resume_type != null or branch.resume_arms != null;
    try emitter.writeIndent();
    if (is_resuming) {
        try emitter.write("const ");
        try writeBranchName(emitter, branch.name);
        try emitter.write(": ?*const fn (");
        try writeArmPayloadParamType(emitter, branch, main_module_name);
        try emitter.write(") ");
        try writeEffectResumeType(emitter, branch);
        try emitter.write(" = if (@hasDecl(__H, \"");
        try writeMangledSeg(emitter, branch.name);
        try emitter.write("\")) &__H.");
        try writeBranchName(emitter, branch.name);
        try emitter.write(" else null;\n");
    } else {
        // Yielding: always-callable, absent -> producer-side no-op.
        try emitter.write("const ");
        try writeBranchName(emitter, branch.name);
        try emitter.write(" = if (@hasDecl(__H, \"");
        try writeMangledSeg(emitter, branch.name);
        try emitter.write("\")) __H.");
        try writeBranchName(emitter, branch.name);
        try emitter.write(" else struct { fn __koru_noop(");
        if (branch.payload.fields.len != 0) {
            try emitter.write("_: ");
            try writeArmPayloadParamType(emitter, branch, main_module_name);
        }
        try emitter.write(") void {} }.__koru_noop;\n");
    }
    try emitter.writeIndent();
    try emitter.write("_ = &");
    try writeBranchName(emitter, branch.name);
    try emitter.write(";\n");
}

/// Yielding-branch comptime aliases — `const X = __H.X` plus a discard.
/// Optional arms get a nullable-fn-ptr alias (comptime-known present/
/// absent) so presence guards fold and the omitted case never forces
/// `__H.X`. (400_146/147/148)
pub fn emitYieldingBranchAliases(
    emitter: *CodeEmitter,
    event: *const ast.EventDecl,
    has_effect: bool,
    main_module_name: ?[]const u8,
) !void {
    if (!has_effect) return;
    for (event.branches) |*b| {
        if (b.kind != .effect) continue;
        if (b.is_optional) {
            try emitOptionalArmNullableAlias(emitter, b, main_module_name);
            continue;
        }
        try emitter.writeIndent();
        try emitter.write("const ");
        try writeBranchName(emitter, b.name);
        try emitter.write(" = __H.");
        try writeBranchName(emitter, b.name);
        try emitter.write(";\n");
        try emitter.writeIndent();
        try emitter.write("_ = &");
        try writeBranchName(emitter, b.name);
        try emitter.write(";\n");
    }
}

/// Effect-branches phase 3b: synthesize the local Handlers struct that carries
/// the consumer's `!` branch bodies as static fns. See docs/EFFECT_BRANCHES.md.
///
/// Emits:
///   const HANDLERS = struct {
///       fn BRANCH(BINDING: PAYLOAD) RESUME { <cont body> }
///       ...
///   };
// Arm-scope collection — the ref/bind walk for effect-arm capture
// analysis. Extracted from flow_checker.zig (where it served KORU207's
// impl-head refusal) so emitHandlersStruct can compute which enclosing
// bindings an arm subtree references but does not itself bind — the
// capture list for the `__HandlersCaps_*` container vars.

const ArmScope = struct {
    binds: std.StringHashMap(void),
    refs: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) ArmScope {
        return .{
            .binds = std.StringHashMap(void).init(allocator),
            .refs = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *ArmScope) void {
        self.binds.deinit();
        self.refs.deinit();
    }
};

fn collectArmScope(cont: *const ast.Continuation, scope: *ArmScope, allocator: std.mem.Allocator) anyerror!void {
    if (cont.is_transformed_subtree) return;
    if (cont.binding) |b| try scope.binds.put(b, {});
    for (cont.destructure) |f| try scope.binds.put(f.name, {});
    if (cont.condition) |c| try scanArmRefs(c, &scope.refs);
    if (cont.condition_expr) |e| try collectExprRefs(e, &scope.refs, allocator);
    if (cont.node) |*n| try collectArmNodeScope(n, scope, allocator);
    for (cont.continuations) |*child| try collectArmScope(child, scope, allocator);
}

fn collectArmNamedBranch(nb: *const ast.NamedBranch, scope: *ArmScope, allocator: std.mem.Allocator) anyerror!void {
    if (nb.binding) |b| try scope.binds.put(b, {});
    for (nb.body) |*cont| try collectArmScope(cont, scope, allocator);
}

fn collectArmNodeScope(n: *const ast.Node, scope: *ArmScope, allocator: std.mem.Allocator) anyerror!void {
    switch (n.*) {
        .invocation => |*inv| {
            for (inv.args) |*arg| try scanArmRefs(arg.value, &scope.refs);
            if (inv.return_binding) |rb| try scope.binds.put(rb, {});
            for (inv.return_destructure) |f| try scope.binds.put(f.name, {});
        },
        .label_with_invocation => |*lwi| {
            for (lwi.invocation.args) |*arg| try scanArmRefs(arg.value, &scope.refs);
        },
        .label_jump => |*lj| {
            for (lj.args) |*arg| try scanArmRefs(arg.value, &scope.refs);
        },
        .branch_constructor => |*bc| {
            if (bc.plain_value) |pv| try scanArmRefs(pv, &scope.refs);
            for (bc.fields) |f| try collectArmFieldRefs(f, scope, allocator);
        },
        .conditional_block => |*cb| {
            if (cb.condition) |c| try scanArmRefs(c, &scope.refs);
            if (cb.condition_expr) |e| try collectExprRefs(e, &scope.refs, allocator);
            for (cb.nodes) |*nn| try collectArmNodeScope(nn, scope, allocator);
        },
        .conditional => |*cd| {
            try scanArmRefs(cd.condition, &scope.refs);
            if (cd.condition_expr) |e| try collectExprRefs(e, &scope.refs, allocator);
            for (cd.branches) |*nb| try collectArmNamedBranch(nb, scope, allocator);
        },
        .foreach => |*fe| {
            try scanArmRefs(fe.iterable, &scope.refs);
            for (fe.branches) |*nb| try collectArmNamedBranch(nb, scope, allocator);
        },
        .switch_result => |*sr| {
            try scanArmRefs(sr.expression, &scope.refs);
            for (sr.branches) |*nb| try collectArmNamedBranch(nb, scope, allocator);
        },
        .assignment => |*asgn| {
            try scope.binds.put(asgn.target, {});
            for (asgn.fields) |f| try collectArmFieldRefs(f, scope, allocator);
        },
        .metatype_binding => |*mb| try scope.binds.put(mb.binding, {}),
        .expression => |code| try scanArmRefs(code, &scope.refs),
        else => {},
    }
}

fn collectArmFieldRefs(f: ast.Field, scope: *ArmScope, allocator: std.mem.Allocator) anyerror!void {
    if (f.expression_str) |s| try scanArmRefs(s, &scope.refs);
    if (f.expression) |e| try collectExprRefs(e, &scope.refs, allocator);
    if (f.default) |d| try scanArmRefs(d, &scope.refs);
}

/// Expression-tree walk: `.identifier` leaves are references. A
/// field_access's `field` is a name, not an Expression, so `v.tag`
/// counts only `v`.
fn collectExprRefs(e: *const ast.Expression, refs: *std.StringHashMap(void), allocator: std.mem.Allocator) anyerror!void {
    switch (e.node) {
        .identifier => |id| try refs.put(id, {}),
        .binary => |*b| {
            try collectExprRefs(b.left, refs, allocator);
            try collectExprRefs(b.right, refs, allocator);
        },
        .unary => |*u| try collectExprRefs(u.operand, refs, allocator),
        .field_access => |*fa| try collectExprRefs(fa.object, refs, allocator),
        .grouped => |g| try collectExprRefs(g, refs, allocator),
        .builtin_call => |*bc| for (bc.args) |a| try collectExprRefs(a, refs, allocator),
        .array_index => |*ai| {
            try collectExprRefs(ai.object, refs, allocator);
            try collectExprRefs(ai.index, refs, allocator);
        },
        .conditional => |*c| {
            try collectExprRefs(c.condition, refs, allocator);
            try collectExprRefs(c.then_expr, refs, allocator);
            try collectExprRefs(c.else_expr, refs, allocator);
        },
        .function_call => |*fc| for (fc.args) |a| try collectExprRefs(a, refs, allocator),
        .literal => {},
    }
}

/// Raw-text identifier scan for the places the AST keeps unparsed
/// text (arg values, when-strings, `->` produce tails). Skips string
/// literals except `{{ }}` interpolation holes, field names after
/// `.`, label keys before `:`, and `@`/`~`-prefixed builtin names.
fn scanArmRefs(text: []const u8, refs: *std.StringHashMap(void)) anyerror!void {
    var i: usize = 0;
    var in_string = false;
    var in_hole = false;
    while (i < text.len) {
        const ch = text[i];
        if (in_string) {
            if (ch == '\\') {
                i += 2;
                continue;
            }
            if (ch == '{') {
                if (i + 1 < text.len and text[i + 1] == '{') {
                    in_hole = true;
                    in_string = false;
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }
            if (ch == '"') in_string = false;
            i += 1;
            continue;
        }
        if (in_hole) {
            if (ch == '}') {
                if (i + 1 < text.len and text[i + 1] == '}') {
                    in_hole = false;
                    in_string = true;
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }
            // `:` inside a hole ends the expression part — the rest
            // is a format spec, not a reference.
            if (ch == ':') {
                while (i < text.len and !(text[i] == '}' and i + 1 < text.len and text[i + 1] == '}')) i += 1;
                continue;
            }
        } else if (ch == '"') {
            in_string = true;
            i += 1;
            continue;
        } else if (ch == '\'') {
            // Char/symbol literal — skip to the closing quote.
            i += 1;
            while (i < text.len and text[i] != '\'') {
                if (text[i] == '\\') i += 1;
                i += 1;
            }
            i += 1;
            continue;
        }
        if (!isArmIdentStart(ch)) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and ast.isKebabIdentChar(text[i])) i += 1;
        const tok = text[start..i];
        // `@`/`~`-prefixed builtin names are not user bindings.
        if (start > 0 and (text[start - 1] == '@' or text[start - 1] == '~')) continue;
        // Field position — `v.tag` references `v`, not `tag`. `..`
        // is a range, not field access: the dot is preceded by a dot.
        if (start > 0 and text[start - 1] == '.' and (start < 2 or text[start - 2] != '.')) continue;
        // Outside a hole an ident immediately followed by `:` is a
        // key/label (`{ name: value }`), not a reference.
        if (!in_hole and i < text.len and text[i] == ':') continue;
        // `{{ flag:name }}` is an interpolation directive, not a read.
        if (in_hole and std.mem.eql(u8, tok, "flag")) continue;
        try refs.put(tok, {});
    }
}

fn isArmIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}


/// Capture sets for a `Handlers_*` struct's member fns. Zig's no-shadow
/// rule reaches through fn boundaries into enclosing decls AND enclosing
/// fn bodies alike, so a context-free arm fn cannot alias an enclosing
/// binding under its own name at ANY nesting depth inside a flow fn — the
/// only scope where `const h` collides with nothing is module level.
/// Captures therefore ride a module-level generic factory:
///
///   pub const __HandlersCaps_3 = struct {
///       pub fn Caps(comptime T_h: type, comptime T_w: type) type {
///           return struct {
///               var __koru_cap_h: T_h = undefined;
///               var __koru_cap_w: T_w = undefined;
///               fn frame(f: *Frame) void { const h = __koru_cap_h; ... }
///           };
///       }
///   };
///   const Handlers_3 = main_module.__HandlersCaps_3.Caps(@TypeOf(h), @TypeOf(w));
///   Handlers_3.__koru_cap_h = h;
///   Handlers_3.__koru_cap_w = w;
///
/// `@TypeOf` evaluates at the CALL SITE where the bindings are live, so no
/// Koru-side type resolution is needed. Member `var` decls are visible to
/// member fns unqualified — `const h = __koru_cap_h` inside `fn frame`
/// rebinds the source spelling, so arm bodies emit unchanged.
const HandlerCaptures = struct {
    /// Ordered union of every name any arm captures — drives the factory's
    /// comptime params, container `var` decls, and call-site assignments.
    names: std.ArrayList([]const u8) = .empty,
    /// Per-cont capture list — drives each cont block's `const` prelude.
    per_cont: std.AutoHashMap(*const ast.Continuation, []const []const u8),

    fn deinit(self: *HandlerCaptures, allocator: std.mem.Allocator) void {
        var it = self.per_cont.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        self.per_cont.deinit();
        self.names.deinit(allocator);
    }
};

/// A name is capture-eligible when it resolves to a binding live at the
/// call site — `zig_scope_bindings` carries exactly that set — or to an
/// implemented tor's input field (the `Handlers_sf` impl-head case, where
/// the params are consts in the enclosing handler fn). `_`, `__`-internal
/// names, and names matching an event branch (which would shadow the
/// member fn of the same name) are never captured.
fn isCaptureEligible(ctx: *EmissionContext, name: []const u8, event_decl: *const ast.EventDecl) bool {
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return false;
    if (std.mem.startsWith(u8, name, "__")) return false;
    for (event_decl.branches) |*b| {
        if (std.mem.eql(u8, b.name, name)) return false;
    }
    for (ctx.zig_scope_bindings.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    if (ctx.impl_event_decl) |d| {
        for (d.input.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
        }
    }
    return false;
}

/// The shared payload parameter spelling for a multi-cont branch group:
/// the common binding when every cont agrees (and isn't `_`), else a
/// stable internal name conts alias to. `branch.name` itself is never
/// picked — it would shadow the synthesized `fn <branch>` member.
fn pickSharedParam(group: []const *const ast.Continuation, branch: *const ast.Branch) []const u8 {
    const first_binding = if (group[0].binding) |b| b else branch.name;
    var all_same = !std.mem.eql(u8, first_binding, "_");
    if (all_same) {
        for (group[1..]) |cont| {
            const b = if (cont.binding) |bb| bb else branch.name;
            if (!std.mem.eql(u8, b, first_binding)) {
                all_same = false;
                break;
            }
        }
    }
    const candidate = if (all_same) first_binding else "__koru_h_arg";
    return if (std.mem.eql(u8, candidate, branch.name)) "__koru_h_arg" else candidate;
}

/// The capture set is what an arm EMITS that names a binding live at the
/// call site — computed by emitting each cont's block into a throwaway
/// buffer and scanning the resulting text. An AST walk cannot see these
/// refs: transform grafts (`is_transformed_subtree`) consume the user
/// bodies into generated units, and only the emitted call args still
/// spell the ambient names (`__store_sweepbody_*(.{ .w = w, .h = h, … })`
/// inside a `frames` arm — invisible to collectArmScope; spec_sel caught
/// `h` through a surface-level `layout(cl: h)` but dropped `w` entirely).
///
/// Deferred decls route to a scratch emitter and are dropped — the real
/// emission below re-runs emitArmContBlock with the final captures, so
/// every decl lands through `emitter.deferred` exactly once.
fn collectEmittedCaptures(
    ctx: *EmissionContext,
    emitter: *CodeEmitter,
    groups: *std.StringArrayHashMap(std.ArrayList(*const ast.Continuation)),
    group_order: []const []const u8,
    event_decl: *const ast.EventDecl,
    handlers_name: []const u8,
) !HandlerCaptures {
    var caps: HandlerCaptures = .{
        .per_cont = std.AutoHashMap(*const ast.Continuation, []const []const u8).init(ctx.allocator),
    };
    errdefer caps.deinit(ctx.allocator);
    var seen = std.StringHashMap(void).init(ctx.allocator);
    defer seen.deinit();
    var scan_deferred = try CodeEmitter.initGrowable(ctx.allocator, 16 * 1024);
    defer ctx.allocator.free(scan_deferred.buffer);

    for (group_order) |branch_name| {
        const group = groups.get(branch_name).?;
        const branch: *const ast.Branch = for (event_decl.branches) |*b| {
            if (std.mem.eql(u8, b.name, branch_name)) break b;
        } else continue;

        // Mirror the real pass exactly — same param spelling, same scope
        // push — so a nested Handlers site inside a body scans under the
        // eligibility it will see when emitted for real.
        const shared_param_name = pickSharedParam(group.items, branch);
        const is_void_payload = branch.payload.fields.len == 0 and !branch.payload.is_wildcard;
        const prev_scope_len = ctx.zig_scope_bindings.items.len;
        defer while (ctx.zig_scope_bindings.items.len > prev_scope_len) {
            const popped = ctx.zig_scope_bindings.pop() orelse break;
            ctx.allocator.free(popped);
        };
        if (!is_void_payload) {
            try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, shared_param_name));
        }

        var any_guarded = false;
        for (group.items) |gc| {
            if (gc.condition != null) {
                any_guarded = true;
                break;
            }
        }
        const multicast = !any_guarded and branch.resume_type == null and branch.resume_arms == null;

        for (group.items) |cont| {
            const guarded = cont.condition != null;
            var body_buf = try CodeEmitter.initGrowable(ctx.allocator, 8 * 1024);
            defer ctx.allocator.free(body_buf.buffer);
            if (emitter.deferred != null) body_buf.deferred = &scan_deferred;
            try emitArmContBlock(&body_buf, ctx, cont, branch, shared_param_name, handlers_name);

            var refs = std.StringHashMap(void).init(ctx.allocator);
            defer refs.deinit();
            try scanArmRefs(body_buf.buffer[0..body_buf.pos], &refs);

            // The cont's own bound names come from the AST: an arm that
            // rebinds an outer name emits `const w = …` itself, and a
            // `const w = __koru_cap_w` prelude would collide with it.
            var scope = ArmScope.init(ctx.allocator);
            defer scope.deinit();
            try collectArmScope(cont, &scope, ctx.allocator);

            var list: std.ArrayList([]const u8) = .empty;
            var it = refs.keyIterator();
            while (it.next()) |name| {
                const n = name.*;
                if (scope.binds.contains(n)) continue;
                if (std.mem.eql(u8, n, shared_param_name)) continue;
                if (!isCaptureEligible(ctx, n, event_decl)) continue;
                // `n` slices into body_buf — dupe before the buffer frees.
                const owned = try ctx.allocator.dupe(u8, n);
                try list.append(ctx.allocator, owned);
                if (!seen.contains(n)) {
                    try seen.put(owned, {});
                    try caps.names.append(ctx.allocator, owned);
                }
            }
            if (list.items.len > 0) {
                try caps.per_cont.put(cont, try list.toOwnedSlice(ctx.allocator));
            } else {
                list.deinit(ctx.allocator);
            }
            if (!guarded and !multicast) break;
        }
    }
    return caps;
}

/// Everything inside one cont's `{ }` block after the capture prelude:
/// payload aliases, the `if (guard)` wrapper, the resume dispatch, and
/// the arm body itself. Emitted twice per cont — once into a throwaway
/// buffer by collectEmittedCaptures (the text is the capture oracle:
/// transform grafts reference ambient names the AST no longer spells),
/// once into the real output — so one definition keeps the scan and the
/// shipped code identical by construction.
fn emitArmContBlock(
    out: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
    branch: *const ast.Branch,
    shared_param_name: []const u8,
    handlers_name: []const u8,
) anyerror!void {
    const guarded = cont.condition != null;

    // Alias the cont's binding to the shared param ONLY when the
    // user wrote an actual binding name (not `_`, not omitted).
    // Omitting the binding means "no name to reference"; aliasing
    // to `branch.name` would shadow the synthesized fn declaration.
    const has_named_binding = if (cont.binding) |b|
        !std.mem.eql(u8, b, "_") and !std.mem.eql(u8, b, shared_param_name)
    else
        false;
    const cont_binding: []const u8 = if (cont.binding) |b| b else branch.name;
    // Produce stage `! each i { f, g: e }` — `const g = <expr>` for named
    // exprs, `const f = i.f` for puns (the element's fields), `const i = i`
    // for the element itself.
    if (cont.produce.len > 0) {
        for (cont.produce) |pf| {
            if (std.mem.eql(u8, pf.name, "_")) continue;
            try out.writeIndent();
            try out.write("const ");
            try writeBranchName(out, pf.name);
            try out.write(" = ");
            if (pf.type_text) |t| {
                try out.write(lowerExprZig(out, ctx, t));
            } else if (std.mem.eql(u8, pf.name, cont_binding)) {
                try out.write(shared_param_name);
            } else {
                try out.write(shared_param_name);
                try out.write(".");
                try out.write(pf.name);
            }
            try out.write("; _ = &");
            try writeBranchName(out, pf.name);
            try out.write(";\n");
        }
    }
    if (cont.destructure.len > 0) {
        // Shape-destructure: per-field consts off the shared param.
        try out.writeIndent();
        try emitDestructureConsts(out, cont.destructure, shared_param_name);
        try out.write("\n");
    } else if (has_named_binding) {
        try out.writeIndent();
        try out.write("const ");
        try writeBranchName(out, cont_binding);
        try out.write(" = ");
        try writeBranchName(out, shared_param_name);
        try out.write(";\n");
        try out.writeIndent();
        try out.write("_ = &");
        try writeBranchName(out, cont_binding);
        try out.write(";\n");
    }

    if (guarded) {
        try out.writeIndent();
        try out.write("if (");
        try out.write(lowerExprZig(out, ctx, cont.condition.?));
        try out.write(") {\n");
        out.indent();
    }

    // Body emission: prefer the bare-expression resume-value form
    // when the branch declares a resume type and the body is a
    // single expression (see `project_effect_resume_value_syntax`).
    var resume_expr_owned: ?[]const u8 = null;
    defer if (resume_expr_owned) |s| ctx.allocator.free(s);

    const resume_expr: ?[]const u8 = blk: {
        // Multi-arm resume sum: `=> halved n / 2` constructs the chosen
        // arm as a variant of the synthesized resume union; a payload-less
        // arm (`=> timeout`) is its bare tag.
        if (branch.resume_arms != null) {
            if (cont.continuations.len != 0) break :blk null;
            const node = cont.node orelse break :blk null;
            if (node != .branch_constructor) break :blk null;
            const bc = node.branch_constructor;
            var arm_buf: [128]u8 = undefined;
            const lowered_arm = lowerIdent(&arm_buf, bc.branch_name);
            if (bc.fields.len != 0) {
                // Record arm: `=> result { halved: X, quadrupled: Y }`
                // constructs the variant's struct payload.
                var built = try std.ArrayList(u8).initCapacity(ctx.allocator, 64);
                errdefer built.deinit(ctx.allocator);
                const w = built.writer(ctx.allocator);
                try w.print(".{{ .{s} = .{{", .{lowered_arm});
                for (bc.fields, 0..) |field, fi| {
                    if (fi > 0) try w.writeAll(",");
                    var fld_buf: [128]u8 = undefined;
                    try w.print(" .{s} = ({s})", .{
                        lowerIdent(&fld_buf, field.name),
                        lowerExprZig(out, ctx, field.expression_str orelse field.type),
                    });
                }
                try w.writeAll(" } }");
                resume_expr_owned = try built.toOwnedSlice(ctx.allocator);
            } else if (bc.plain_value) |pv| {
                resume_expr_owned = try std.fmt.allocPrint(
                    ctx.allocator,
                    ".{{ .{s} = ({s}) }}",
                    .{ lowered_arm, lowerExprZig(out, ctx, pv) },
                );
            } else {
                resume_expr_owned = try std.fmt.allocPrint(
                    ctx.allocator,
                    ".{s}",
                    .{lowered_arm},
                );
            }
            break :blk resume_expr_owned.?;
        }
        if (branch.resume_type == null) break :blk null;
        if (cont.continuations.len != 0) break :blk null;
        const node = cont.node orelse break :blk null;
        switch (node) {
            .expression => |code| break :blk lowerExprZig(out, ctx, code),
            .branch_constructor => |bc| {
                if (bc.fields.len != 0) break :blk null;
                if (bc.plain_value) |pv| {
                    // A record resume value (`! ask -> { a: 10, b: 20 }`)
                    // is a Koru struct literal; lower it to Zig
                    // `.{ .a = 10, .b = 20 }`. A scalar value (`-> 50`)
                    // passes through with its (empty, for bare-return)
                    // branch_name prefix.
                    const trimmed_pv = std.mem.trim(u8, pv, " \t");
                    if (isKoruStructLiteral(trimmed_pv)) {
                        var scratch = try CodeEmitter.initGrowable(ctx.allocator, 128);
                        defer ctx.allocator.free(scratch.buffer);
                        try emitStructLiteral(&scratch, ctx, trimmed_pv);
                        resume_expr_owned = try ctx.allocator.dupe(u8, scratch.buffer[0..scratch.pos]);
                    } else {
                        resume_expr_owned = try std.fmt.allocPrint(
                            ctx.allocator,
                            "{s} {s}",
                            .{ bc.branch_name, lowerExprZig(out, ctx, pv) },
                        );
                    }
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
        try emitInvocation(out, ctx, inv, "__koru_resume");
        try out.writeIndent();
        try out.write("return __koru_resume;\n");
    } else if (resume_expr) |expr| {
        try out.writeIndent();
        try out.write("return ");
        if (!try writeRepackedRecordProduce(out, expr, branch.resume_type)) {
            try out.write(expr);
        }
        try out.write(";\n");
    } else {
        // Arm bodies land as `fn`s inside this Handlers_N container —
        // itself nested in the enclosing flow fn's body — and Zig's
        // no-shadow rule reaches across that boundary: a fresh
        // `result_0` here collides with the head call's `result_0`
        // (230_007, drift.k's `stored` in a `frames` arm). NEST the
        // namespace under the enclosing prefix like the `c`/`e` tags
        // above instead of seeding the counter — emitContinuationBody
        // reads `counter == 0`/`counter-1` as sentinels, so a nonzero
        // seed would name a stale enclosing-scope variable.
        const saved_prefix = ctx.result_prefix;
        var prefix_buf: [128]u8 = undefined;
        ctx.result_prefix = std.fmt.bufPrint(&prefix_buf, "{s}{s}_", .{ saved_prefix, handlers_name }) catch saved_prefix;
        defer ctx.result_prefix = saved_prefix;
        var result_counter: usize = 0;
        try emitContinuationBody(out, ctx, cont, &result_counter);

        // For guarded void-return conts, emit an explicit `return;`
        // so subsequent guards in the chain don't fire after a match.
        // (Resume-typed conts already returned via the `return EXPR`
        // path above.)
        if (guarded and branch.resume_type == null) {
            try out.writeIndent();
            try out.write("return;\n");
        }
    }

    if (guarded) {
        // Close the `if (cond) {` block.
        out.dedent();
        try out.writeIndent();
        try out.write("}\n");
    }
}

pub fn emitHandlersStruct(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    handlers_name: []const u8,
    effect_conts: []const ast.Continuation,
    event_decl: *const ast.EventDecl,
) anyerror!void {
    // Group continuations by branch name. Two sibling handlers for the same
    // `!` branch name collapse into ONE synthesized fn:
    //   - when-guards present → exclusive chain
    //     (`if (g1) { body1; return; } … unguarded_fallback`); first match wins.
    //   - ALL unguarded, void (non-resuming) effect → MULTICAST: every body
    //     runs in source order (400_173 / branch_checker: effect links compose).
    // Without collapsing, the struct would have two `fn tick` declarations and
    // Zig rejects with "duplicate struct member name".
    //
    // Source order is preserved within each group.
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
        // Skip residual `!*` conts — they don't match any specific decl branch.
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

    // Captured bindings: names an arm's emitted code references but does
    // not itself bind, intersected with bindings live at this call site —
    // collected by emit-scanning, since transform grafts leave no AST to
    // walk. When any exist, the member fns must emit at MODULE level (an
    // in-function `const h = ...` prelude collides with the flow fn's own
    // `h` under Zig's no-shadow rule), so the struct becomes the return
    // type of a generic `__HandlersCaps_*` factory routed to
    // `emitter.deferred`; the call site below instantiates it and assigns
    // each container var.
    var captures = try collectEmittedCaptures(ctx, emitter, &groups, group_order.items, event_decl, handlers_name);
    defer captures.deinit(ctx.allocator);
    const use_caps = captures.names.items.len > 0 and emitter.deferred != null;
    var fac_buf: CodeEmitter = undefined;
    const out: *CodeEmitter = if (use_caps) blk: {
        fac_buf = try CodeEmitter.initGrowable(ctx.allocator, 64 * 1024);
        fac_buf.deferred = emitter.deferred;
        fac_buf.indent_level = 1; // flushes inside main_module's body
        break :blk &fac_buf;
    } else emitter;
    defer if (use_caps) ctx.allocator.free(fac_buf.buffer);

    const caps_suffix = if (std.mem.startsWith(u8, handlers_name, "Handlers_"))
        handlers_name["Handlers_".len..]
    else
        handlers_name;

    if (use_caps) {
        try out.writeIndent();
        try out.write("pub const __HandlersCaps_");
        try out.write(caps_suffix);
        try out.write(" = struct {\n");
        out.indent();
        try out.writeIndent();
        try out.write("pub fn Caps(");
        for (captures.names.items, 0..) |name, i| {
            if (i > 0) try out.write(", ");
            try out.write("comptime T_");
            try writeMangledSeg(out, name);
            try out.write(": type");
        }
        try out.write(") type {\n");
        out.indent();
        try out.writeIndent();
        try out.write("return struct {\n");
        out.indent();
        for (captures.names.items) |name| {
            try out.writeIndent();
            try out.write("var __koru_cap_");
            try writeMangledSeg(out, name);
            try out.write(": T_");
            try writeMangledSeg(out, name);
            try out.write(" = undefined;\n");
        }
    } else {
        try out.writeIndent();
        try out.write("const ");
        try out.write(handlers_name);
        try out.write(" = struct {\n");
        out.indent();
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

        // Pick a parameter name. If all conts in the group share a binding
        // (common case) and that binding isn't `_`, use it directly so the
        // body code can reference it unchanged. Otherwise fall back to a
        // stable internal name, and conts whose binding differs alias it.
        // The scan pass above computed captures under the SAME spelling —
        // both passes must agree or the prelude binds a different name.
        const shared_param_name = pickSharedParam(group.items, branch);

        // Void-payload effects (zero-field branch) emit a no-arg handler so the
        // producer-side `name()` call matches. A `void` param would require the
        // call site to pass `{}` and bloats the signature for no information.
        // A wildcard payload (`! each *`) has zero fields but IS bindable — it
        // takes an `anytype` param so Zig infers the element type at the call.
        const is_void_payload = branch.payload.fields.len == 0 and !branch.payload.is_wildcard;

        try out.writeIndent();
        try out.write("fn ");
        try writeBranchName(out, branch.name);
        try out.write("(");

        if (!is_void_payload) {
            try writeBranchName(out, shared_param_name);
            try out.write(": ");

            // Wildcard payload `! each *` — defer the element type to Zig's
            // type inference: emit `anytype` (valid in parameter position).
            if (branch.payload.is_wildcard) {
                try out.write("anytype");
            }
            // Identity payload (single field named "__type_ref") — emit type directly.
            // Multi-field struct payload — emit anon struct literal type.
            else if (branch.payload.fields.len == 1 and std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref")) {
                // This struct is emitted in the CONSUMER's scope, which is a
                // different module from the event whenever the event was
                // imported. A payload written bare (`! tick *Beat`) carries no
                // module_path, so it would land as `*Beat` — undeclared there.
                // Its home is the module that DECLARES the event: that is where
                // the author wrote the name and the only scope it resolved in.
                //
                // Latent until now because the other Handlers sites usually
                // inline the effectful call instead of synthesizing a struct;
                // the subflow site cannot, so it reached this first.
                // The event's own path qualifier is the LOGICAL module
                // (`app/lib/pulse`), which is what writeFieldType expands into
                // a host path. `event_decl.module` is the short name and
                // expands to a namespace that does not exist.
                var payload_field = branch.payload.fields[0];
                if (payload_field.module_path == null) {
                    if (event_decl.path.module_qualifier) |mq| {
                        // Only when that module genuinely declares the type —
                        // `! beat i64` must stay `i64`, not become
                        // `koru_vaxis.i64`.
                        if (mq.len > 0 and moduleDeclaresType(payload_field.type, mq)) {
                            payload_field.module_path = mq;
                        }
                    }
                }
                try writeFieldType(out, payload_field, ctx.main_module_name);
            } else {
                try out.write("struct { ");
                for (branch.payload.fields, 0..) |field, fi| {
                    if (fi > 0) try out.write(", ");
                    try writeBranchName(out, field.name);
                    try out.write(": ");
                    try writeFieldType(out, field, ctx.main_module_name);
                }
                try out.write(" }");
            }
        }

        try out.write(") ");
        try writeEffectResumeType(out, branch);
        try out.write(" {\n");
        out.indent();

        // The shared param is a live name inside this member fn — register
        // it so nested `Handlers_*` sites can carry it as a capture (their
        // factories assign at the call site where the param is in scope).
        // Only real params register — a void payload emits no param.
        const prev_fn_scope_len = ctx.zig_scope_bindings.items.len;
        defer while (ctx.zig_scope_bindings.items.len > prev_fn_scope_len) {
            const popped = ctx.zig_scope_bindings.pop() orelse break;
            ctx.allocator.free(popped);
        };
        if (!is_void_payload) {
            try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, shared_param_name));
        }

        // Suppress unused-param warning unconditionally on the shared param.
        if (!is_void_payload) {
            try out.writeIndent();
            try out.write("_ = &");
            try writeBranchName(out, shared_param_name);
            try out.write(";\n");
        }

        // Emit each cont in source order. Each cont gets its own block scope
        // so binding aliases (e.g., `const i = __koru_h_arg`) are visible to
        // the guard expression. Guarded conts wrap their body in
        // `if (cond) { ... return; }`.
        // Exclusive (any when): first unguarded is fallback — stop after it.
        // Multicast (all unguarded, void resume): every body runs (400_173).
        var any_guarded = false;
        for (group.items) |gc| {
            if (gc.condition != null) {
                any_guarded = true;
                break;
            }
        }
        const multicast = !any_guarded and branch.resume_type == null and branch.resume_arms == null;

        for (group.items) |cont| {
            const guarded = cont.condition != null;

            try out.writeIndent();
            try out.write("{\n");
            out.indent();

            // Captured-binding prelude: rebind each enclosing name this cont
            // references to its container `var` under the source spelling,
            // so the body below emits unchanged. Per-cont rather than per-fn:
            // a sibling cont in the same group may bind the same name itself.
            // A name equal to the shared param stays the param (today's
            // semantics — the param wins the name inside the fn).
            if (use_caps) {
                if (captures.per_cont.get(cont)) |cap_names| {
                    for (cap_names) |name| {
                        if (std.mem.eql(u8, name, shared_param_name)) continue;
                        try out.writeIndent();
                        try out.write("const ");
                        try writeBranchName(out, name);
                        try out.write(" = __koru_cap_");
                        try writeMangledSeg(out, name);
                        try out.write(";\n");
                        try out.writeIndent();
                        try out.write("_ = &");
                        try writeBranchName(out, name);
                        try out.write(";\n");
                    }
                }
            }

            try emitArmContBlock(out, ctx, cont, branch, shared_param_name, handlers_name);

            // Close the per-cont scope block.
            out.dedent();
            try out.writeIndent();
            try out.write("}\n");

            // Exclusive fallback: stop after first unguarded. Multicast keeps
            // going so every unguarded void-effect body runs.
            if (!guarded and !multicast) break;
        }

        out.dedent();
        try out.writeIndent();
        try out.write("}\n");
    }

    // NO synthesized no-ops for unhandled OPTIONAL effect branches — the
    // handlers struct carries ONLY what the consumer actually installed, so
    // `@hasDecl(__H, ...)` IS the presence truth (400_146/147/154 — a
    // synthesized stand-in is indistinguishable from a real install and made
    // presence lie for omitting consumers). The 210_076 contract ("unhandled
    // optional fires are no-ops") is honored at the FIRE site instead: a void
    // optional fire emits under a comptime `@hasDecl` guard that folds to
    // nothing when the handler is absent — same zero cost the inlined no-op
    // had. Value-resuming optional fires need no stand-in either: they are
    // only reachable under a presence guard (unguarded = the KORU130 wall),
    // whose false case is comptime-pruned.

    out.dedent();
    try out.writeIndent();
    try out.write("};\n"); // closes `const X = struct` or `return struct {`

    if (use_caps) {
        // Close `pub fn Caps` and `pub const __HandlersCaps_N`, hand the
        // complete factory text to the module-level decl collector, then
        // emit the call-site instantiation where the captured names are
        // live: `const Handlers_N = main_module.__HandlersCaps_N.Caps(
        // @TypeOf(x), …)` + one container-var assignment per capture.
        out.dedent();
        try out.writeIndent();
        try out.write("}\n");
        out.dedent();
        try out.writeIndent();
        try out.write("};\n");
        try emitter.deferred.?.write(fac_buf.buffer[0..fac_buf.pos]);

        try emitter.writeIndent();
        try emitter.write("const ");
        try emitter.write(handlers_name);
        try emitter.write(" = main_module.__HandlersCaps_");
        try emitter.write(caps_suffix);
        try emitter.write(".Caps(");
        for (captures.names.items, 0..) |name, i| {
            if (i > 0) try emitter.write(", ");
            try emitter.write("@TypeOf(");
            try writeBranchName(emitter, name);
            try emitter.write(")");
        }
        try emitter.write(");\n");
        for (captures.names.items) |name| {
            try emitter.writeIndent();
            try emitter.write(handlers_name);
            try emitter.write(".__koru_cap_");
            try writeMangledSeg(emitter, name);
            try emitter.write(" = ");
            try writeBranchName(emitter, name);
            try emitter.write(";\n");
        }
    }
}

/// Subflow-implemented effects: if `path` names an effect arm of `event`
/// (single segment, module qualifier absent or matching the event's own),
/// return that arm. Used with EmissionContext.impl_event_decl so arm names
/// only ever resolve inside the declaring event's own implementation.
pub fn findEffectArm(event: *const ast.EventDecl, path: *const ast.DottedPath) ?*const ast.Branch {
    if (path.segments.len != 1) return null;
    if (path.module_qualifier) |mq| {
        if (event.path.module_qualifier) |emq| {
            if (!std.mem.eql(u8, mq, emq)) return null;
        }
    }
    for (event.branches) |*b| {
        if (b.kind == .effect and std.mem.eql(u8, b.name, path.segments[0])) return b;
    }
    return null;
}

/// Presence-expression rewrite for an `if`/`when` CONDITION string. A bare
/// effect-arm name in guard position is a presence test — "did the consumer
/// install this arm" (ruled 2026-07-03):
///   - optional arm, legacy Handlers-fn path → `@hasDecl(__H, "<arm>")`
///     (400_146/147). `__H` is the comptime handlers param.
///   - optional arm, inline-splice path → `true` / `false` from the CALLER's
///     continuations (`inline_fire_conts`). The inline splice has no `__H` in
///     scope; presence is codegen-time knowledge of what was installed (833).
///   - required arm → `@compileError(...)` wall: a required arm is always
///     installed, so testing for it is a meaningless always-true. (400_150)
/// Returns null when `cond` is not a bare arm name — emit it verbatim.
/// A non-null result is owned by `allocator`.
fn presenceConditionRewrite(
    allocator: std.mem.Allocator,
    cond: []const u8,
    event: *const ast.EventDecl,
    inline_fire_conts: ?[]const ast.Continuation,
) !?[]const u8 {
    const trimmed = std.mem.trim(u8, cond, " \t");
    for (event.branches) |*b| {
        if (b.kind != .effect) continue;
        if (!std.mem.eql(u8, trimmed, b.name)) continue;
        if (b.is_optional) {
            // Inline splice: resolve presence from the caller's installed
            // continuations — no `__H` exists in that scope.
            if (inline_fire_conts) |fire_conts| {
                for (fire_conts) |*c| {
                    if (c.kind == .effect and std.mem.eql(u8, c.branch, b.name)) {
                        return try allocator.dupe(u8, "true");
                    }
                }
                return try allocator.dupe(u8, "false");
            }
            // Legacy Handlers-fn path: comptime `@hasDecl` against `__H`.
            // `if (opt)` is NOT a bool in Zig (it needs a capture), so the
            // condition becomes a real comptime bool → Zig analyzes only the
            // taken branch. (Nullable-ptr alias serves the proc side.)
            const mname = try allocator.dupe(u8, b.name);
            defer allocator.free(mname);
            for (mname) |*c| {
                if (c.* == '-') c.* = '_';
            }
            return try std.fmt.allocPrint(allocator, "@hasDecl(__H, \"{s}\")", .{mname});
        }
        return try std.fmt.allocPrint(
            allocator,
            "@compileError(\"presence test on '{s}' — a required arm is always installed, so testing for it is meaningless\")",
            .{b.name},
        );
    }
    return null;
}

/// THE ZIG TARGET'S DOOR ONTO THE OPERATOR REWRITE — the `.zig` arm's
/// `codegen_utils.rewriteZigExpr`, called directly so an expression with
/// nothing to rewrite costs no allocation; the twin of
/// `js_emitter.writeJsExpr` (same seam, other target). Every KORU EXPRESSION
/// this emitter writes goes through here: a `when` guard, an `if` condition, a
/// body or field value. What it changes is the two operators Zig does not
/// spell Koru's way — `%` (Zig's is unsigned-only) and a literal-grounded
/// string `==` / `!=` (Koru's is value equality); see the operator-spelling
/// section in codegen_utils for the boundary.
///
/// It is an IDENTITY, not a fallback: the rewrite touches only text it read
/// whole as one expression and has something to change in, so already-Zig host
/// text, statements, bit operators and struct literals come back byte-identical
/// (`@sqrt(x)` stays `@sqrt(x)` — Zig names it too). Identity also when this
/// emitter has no allocator to build new text with; a rewritten result is
/// borrowed from that allocator, which is the compile arena.
fn lowerExprZig(emitter: *CodeEmitter, ctx: *EmissionContext, text: []const u8) []const u8 {
    const alloc = emitter.allocator orelse return text;
    const lowered = (codegen_utils.rewriteZigExpr(alloc, text) catch null) orelse text;
    // Bound-name spelling AFTER the expr rewrite: `@"i1"` would not survive
    // the rewriter's operand parser, but the rewriter's output block
    // (`__koru_l = i1`) rewrites to `@"i1"` cleanly by identifier match.
    return escapeBoundNames(ctx, lowered) catch lowered;
}

/// Rewrite in-scope flow-binding names whose emitted Zig spelling differs
/// from the author's text. A `: i1` chain bind declares `@"i1"` and a
/// `pos-tempo` bind declares `pos_tempo` — every decl site spells through
/// writeBranchName — but user text spliced while the binding lives (arg
/// values, when-guards, template-rendered bodies) carried the raw name: `i1`
/// resolves as the primitive and `pos-tempo` parses as subtraction. The decl
/// spelling is `codegen_utils.appendBranchName`; this applies the same rule
/// to references. Names are longest-first so `a-b` cannot eat the `b` of a
/// bound `a-b-c`. References already inside `@"…"` are string-masked by
/// replaceIdentifier and cannot double-escape.
fn escapeBoundNames(ctx: *const EmissionContext, text: []const u8) ![]const u8 {
    var out = text;
    var names_buf: [128][]const u8 = undefined;
    var names_len: usize = 0;
    // The impl tor's input fields destructure to mangled consts (`x_y`)
    // without ever entering zig_scope_bindings — every handler ctx carries
    // the decl, so source its field names here. `x-y` in an impl body
    // reference otherwise passes through verbatim and Zig reads subtraction.
    if (ctx.impl_event_decl) |impl_ev| {
        for (impl_ev.input.fields) |field| {
            if (!codegen_utils.hasKebab(field.name) and !codegen_utils.needsEscaping(field.name)) continue;
            if (names_len == names_buf.len) break;
            if (std.mem.indexOf(u8, out, field.name) == null) continue;
            var dup = false;
            for (names_buf[0..names_len]) |seen| {
                if (std.mem.eql(u8, seen, field.name)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            names_buf[names_len] = field.name;
            names_len += 1;
        }
    }
    for (ctx.zig_scope_bindings.items) |name| {
        if (!codegen_utils.hasKebab(name) and !codegen_utils.needsEscaping(name)) continue;
        if (names_len == names_buf.len) break;
        var dup = false;
        for (names_buf[0..names_len]) |seen| {
            if (std.mem.eql(u8, seen, name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (std.mem.indexOf(u8, out, name) == null) continue;
        names_buf[names_len] = name;
        names_len += 1;
    }
    std.mem.sort([]const u8, names_buf[0..names_len], {}, struct {
        fn longer(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.longer);
    for (names_buf[0..names_len]) |name| {
        var spelled: std.ArrayList(u8) = .empty;
        defer spelled.deinit(ctx.allocator);
        try codegen_utils.appendBranchName(&spelled, ctx.allocator, name);
        const rewritten = try codegen_utils.replaceIdentifier(ctx.allocator, out, name, spelled.items);
        if (out.ptr != text.ptr) ctx.allocator.free(@constCast(out));
        out = rewritten;
    }
    return out;
}

/// Write an arm-fire's payload argument list — the POSITIONAL shape shared
/// by both the `__H.<arm>(<payload>)` handler call and the
/// `__koru_inline_<idx>(<payload>)` splice marker: identity payload → the
/// bare value, multi-field → one anon struct literal, void → no args. Must
/// mirror `emitHandlersStruct`'s signature emission.
fn writeArmFirePayload(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    invocation: *const ast.Invocation,
    arm: *const ast.Branch,
) !void {
    const is_identity = arm.payload.fields.len == 1 and
        std.mem.eql(u8, arm.payload.fields[0].name, "__type_ref");
    if (arm.payload.fields.len == 0 and !arm.payload.is_wildcard) {
        // Payloadless arm — bare `ask()`.
    } else if (is_identity or arm.payload.is_wildcard) {
        if (invocation.args.len > 0) {
            try emitValue(emitter, ctx, invocation.args[0].value);
        }
    } else {
        try emitter.write(".{ ");
        for (invocation.args, 0..) |arg, i| {
            if (i > 0) try emitter.write(", ");
            try emitter.write(".");
            try writeBranchName(emitter, arg.name);
            try emitter.write(" = ");
            try emitValue(emitter, ctx, arg.value);
        }
        try emitter.write(" }");
    }
}

/// Write the call expression for an arm-fire: `__H.<arm>(<payload>)`.
fn writeArmFireCallExpr(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    invocation: *const ast.Invocation,
    arm: *const ast.Branch,
) !void {
    try emitter.write("__H.");
    try writeBranchName(emitter, arm.name);
    try emitter.write("(");
    try writeArmFirePayload(emitter, ctx, invocation, arm);
    try emitter.write(")");
}

/// Emit an invocation (const result = event.handler(...))
/// If an ImmediateImpl exists for this path, inline the value instead
fn emitInvocation(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    invocation: *const ast.Invocation,
    result_var: []const u8,
) !void {
    // Fork/join drains before any unmarked call — a pending spawn's slot is
    // only safe to read once joined, and every subsequent step is a reader.
    const is_parallel_inv = blk: {
        for (invocation.annotations) |ann| {
            if (std.mem.eql(u8, ann, "parallel")) break :blk true;
        }
        break :blk false;
    };
    if (!is_parallel_inv) try drainParallelJoins(emitter, ctx);
    // Subflow-implemented effects: inside the declaring event's impl, a call
    // to one of its own effect arms IS the firing — lower it to the
    // consumer's handler-struct fn via the comptime `__H` param, never to an
    // event handler call. A resuming arm binds its value to the call-site
    // `:` name (or the pipeline's result var); a void arm is a bare call.
    if (ctx.impl_event_decl) |impl_ev| {
        if (findEffectArm(impl_ev, &invocation.path)) |arm| {
            // Inline-splice lowering (renderEffectfulFlowBody): this fire is
            // being rendered INSIDE the flow-bodied impl's own inline splice,
            // so it must resolve to a `__koru_inline_<idx>(payload)` marker
            // against the CALLER's continuations (`ctx.inline_fire_conts`),
            // exactly like the marker `rewriteEffectfulProcBody` writes for a
            // raw `~proc|zig` body's effect calls — never the standalone
            // `__H.<arm>(...)` handler call the legacy path below takes.
            // Eligibility already excludes resuming arms (no resume-binding
            // shape here). Optional arms: absent → no-op / evaluate-and-drop;
            // presence guards in the impl body resolve via
            // `presenceConditionRewrite(..., inline_fire_conts)` to
            // comptime true/false (833).
            if (ctx.inline_fire_conts) |fire_conts| {
                var cont_idx: ?usize = null;
                for (fire_conts, 0..) |*c, ci| {
                    if (c.kind == .effect and std.mem.eql(u8, c.branch, arm.name)) {
                        cont_idx = ci;
                        break;
                    }
                }
                if (cont_idx == null) {
                    // Unhandled optional: comptime-absent — pure no-op.
                    // Mirrors `if (@hasDecl(__H, ...))` folding the fire away
                    // on the legacy path (payload not evaluated either).
                    // Evaluate-and-drop would re-discard for-loop bindings
                    // (`_ = &i; _ = i`) and leak a Zig error (400_145).
                    return;
                }
                try emitter.writeIndent();
                try emitter.write(INLINE_SPLICE_PREFIX);
                var nb: [16]u8 = undefined;
                try emitter.write(std.fmt.bufPrint(&nb, "{d}", .{cont_idx.?}) catch unreachable);
                try emitter.write("(");
                try writeArmFirePayload(emitter, ctx, invocation, arm);
                try emitter.write(")");
                try emitter.write(";\n");
                return;
            }

            const has_resume = arm.resume_type != null or arm.resume_arms != null;
            try emitter.writeIndent();
            if (has_resume) {
                const bound_var = invocation.return_binding orelse result_var;
                if (std.mem.eql(u8, bound_var, "_")) {
                    try emitter.write("_ = ");
                } else {
                    try emitter.write("const ");
                    try emitter.write(bound_var);
                    try emitter.write(" = ");
                }
            } else if (arm.is_optional) {
                // Void OPTIONAL fire: no handler may be installed, and the
                // handlers struct carries no synthesized stand-in (presence
                // truth, 400_154). The 210_076 no-op contract lives HERE — a
                // comptime guard that folds the call away when absent.
                try emitter.write("if (@hasDecl(__H, \"");
                try writeMangledSeg(emitter, arm.name);
                try emitter.write("\")) ");
            }
            try writeArmFireCallExpr(emitter, ctx, invocation, arm);
            try emitter.write(";\n");
            return;
        }
    }

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
            // Cross-module immediate impl: inlining the call body below would
            // splice the declaring module's bare names into the caller's
            // emitted scope. A `const {}` in an imported module (e.g.
            // `sim:thrust-dx` referencing `SHIP_THRUST`) resolves ONLY inside
            // that module's emitted struct, never in the caller's flow — the
            // inlined body dies with `use of undeclared identifier`. Same-module
            // calls (unqualified, or qualified to the main module) keep the
            // inline splice: the consts land in the same emitted container.
            const cross_module_call: bool = blk: {
                const mq = invocation.path.module_qualifier orelse break :blk false;
                if (ctx.main_module_name) |mmn| {
                    if (std.mem.eql(u8, mq, mmn)) break :blk false;
                } else break :blk false;
                break :blk true;
            };
            if (cross_module_call) {
                // Fall through to the handler-call path below — the target
                // module's emitted handler resolves its consts in-scope
                // (emitted `koru_sim` struct holds both the `const {}` block
                // and the per-event __koru_handler_impl).
            } else {
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
                const named_bind = if (bare_return)
                    (invocation.return_binding orelse result_var)
                else
                    result_var;
                // A `: _` discard still needs the typed labeled block (the break's
                // anonymous literal has no result type without it), but Zig has no
                // `_: T = …` form — bind a scoped const and discard it after.
                const bind_discarded = std.mem.eql(u8, named_bind, "_");
                var imm_disc_buf: [48]u8 = undefined;
                const bind_name = if (bind_discarded) blk: {
                    const n = std.fmt.bufPrint(&imm_disc_buf, "__koru_imm_disc_{d}", .{ctx.proc_label_counter}) catch "__koru_imm_disc";
                    ctx.proc_label_counter += 1;
                    break :blk n;
                } else named_bind;
                try emitter.writeIndent();
                try emitter.write("const ");
                try emitter.write(bind_name);
                try emitter.write(": ");
                if (bare_return and event_decl != null and event_decl.?.return_type != null) {
                    const decl_mod: ?[]const u8 = blk: {
                        if (invocation.path.module_qualifier) |mq| break :blk mq;
                        if (event_decl.?.module.len > 0) break :blk event_decl.?.module;
                        break :blk null;
                    };
                    // Re-attach the parser-lifted return phantom so a module-
                    // qualified one (`-> *List_i64<std/list:list!>`) qualifies the
                    // base to its home module here too — same resolution as the
                    // handler Output (660_027). Without it the annotation emits
                    // via declaring_module and names a type this scope never
                    // declared (`*main_module.List_i64`).
                    var rt_out = event_decl.?.return_type.?;
                    var rejoined: ?[]const u8 = null;
                    if (event_decl.?.return_phantom) |rp| {
                        if (emitter.allocator) |a| {
                            rejoined = std.fmt.allocPrint(a, "{s}<{s}>", .{ event_decl.?.return_type.?, rp }) catch null;
                            if (rejoined) |b| rt_out = b;
                        }
                    }
                    try writeBareReturnType(emitter, rt_out, ctx.main_module_name, decl_mod);
                } else {
                    try emitInvocationTarget(emitter, ctx, &invocation.path);
                    try emitter.write(".Output");
                }
                try emitter.write(" = blk: {\n");

                emitter.indent_level += 1;

                const max_param_aliases = 8;
                var alias_params: [max_param_aliases][]const u8 = undefined;
                var alias_values: [max_param_aliases][]const u8 = undefined;
                var alias_count: usize = 0;

                // Bind input arguments so they're available in the expression
                // e.g., for ~double(n: 5) with ~double = result { n * 2 }
                // we need: const n = 5;
                // Skip if:
                //   - pass-through: param name equals a simple identifier value already in scope
                //     (echo(v: v), echo(v)) — rebinding inside the blk shadows continuation bindings
                //   - bare-return alias: param maps to the call-site argument — substitute
                //     in the plain value instead of rebinding (read(s: i.name) → i.name.data)
                //   - arg.name is not referenced in the immediate expression (avoid shadowing outer scope)
                for (invocation.args, 0..) |arg, arg_idx| {
                    // Resolve actual parameter name for positional args
                    // e.g., ~greet("World") where arg.name == arg.value == "\"World\""
                    // but event signature has { name: []const u8 } -> use "name"
                    const param_name = if (!arg.had_explicit_label and std.mem.eql(u8, arg.name, arg.value)) blk_name: {
                        // Bare pun: name-bind when it names a field (desugars append
                        // pun fills late, so index resolution would misbind); index
                        // is the fallback for a name that is no field.
                        if (event_decl) |ev| {
                            if (ast.resolveArgFieldIndex(arg, arg_idx, ev.input.fields)) |fi| {
                                break :blk_name ev.input.fields[fi].name;
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

                    if (bare_return) {
                        if (immediate_bc.plain_value) |pv| {
                            if (containsIdentifier(pv, param_name)) {
                                if (alias_count < max_param_aliases) {
                                    alias_params[alias_count] = param_name;
                                    alias_values[alias_count] = trimmed_value;
                                    alias_count += 1;
                                }
                                continue;
                            }
                        }
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

                // DEFAULT INJECTION. The struct-literal paths get defaults for free
                // — the generated `Input` struct carries `= <default>` and Zig
                // applies it. An INLINED call has no Input struct: it binds each
                // parameter from the call site's own args, so a parameter the
                // author omitted simply never comes into scope and the default
                // vanishes (400_185, green twin 400_186 on the proc path).
                //
                // Presence is read off `invocation.args`, not off what the loop
                // above emitted: a pass-through or aliased argument is supplied and
                // deliberately NOT rebound.
                if (event_decl) |ev| {
                    for (ev.input.fields) |field| {
                        const dflt = field.default orelse continue;
                        var supplied = false;
                        for (invocation.args, 0..) |arg, i| {
                            const resolved = ast.resolveArgParamName(arg, i, ev.input.fields);
                            if (std.mem.eql(u8, resolved, field.name)) {
                                supplied = true;
                                break;
                            }
                        }
                        if (supplied) continue;
                        try emitter.writeIndent();
                        try emitter.write("const ");
                        try writeBranchName(emitter, field.name);
                        try emitter.write(" = ");
                        try emitter.write(dflt);
                        try emitter.write(";\n");
                        try emitter.writeIndent();
                        try emitter.write("_ = &");
                        try writeBranchName(emitter, field.name);
                        try emitter.write(";\n");
                    }
                }

                // Emit the break with the branch constructor (or the bare value).
                try emitter.writeIndent();
                try emitter.write("break :blk ");
                if (bare_return) {
                    // `-> T`: yield the expression directly, no `.{ .name = ... }` wrap.
                    if (immediate_bc.plain_value) |pv| {
                        if (alias_count > 0) {
                            const a = emitter.allocator orelse std.heap.page_allocator;
                            const substituted = try substituteParamNamesInPlainValue(
                                a,
                                pv,
                                alias_params[0..alias_count],
                                alias_values[0..alias_count],
                            );
                            defer a.free(substituted);
                            try emitValue(emitter, ctx, substituted);
                        } else {
                            try emitValue(emitter, ctx, pv);
                        }
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
                if (bind_discarded) {
                    try emitter.writeIndent();
                    try emitter.write("_ = ");
                    try emitter.write(bind_name);
                    try emitter.write(";\n");
                }
                return;
            }
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
    // Fork/join: a [parallel]-marked call lowers to slot + spawn instead of
    // `const <bind> = handler(...)`. The worker fn runs `handler` on a
    // thread writing the slot; the join drains at the first step that could
    // read the binding. Serial fallbacks where the call shape can't fork:
    // pending effect-handlers (the Handlers 2nd arg can't cross a thread),
    // explicit variants, `try`/async emission, and destructured binds
    // (their consts would read the slot pre-join).
    const forkable = is_parallel_inv and
        ctx.pending_handlers_name == null and
        invocation.variant == null and
        ctx.is_sync and
        invocation.return_destructure.len == 0;
    if (forkable) {
        const slot = if (std.mem.eql(u8, bound_var, "_"))
            try std.fmt.allocPrint(ctx.allocator, "__koru_par_s{d}", .{ctx.pending_parallel.items.len})
        else
            bound_var;
        try emitter.writeIndent();
        try emitter.write("var ");
        try writeBranchName(emitter, slot);
        try emitter.write(": ");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".Output = undefined;\n");
        try emitter.writeIndent();
        try emitter.write("const __koru_par_in_");
        try writeBranchName(emitter, slot);
        try emitter.write(": ");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".Input = .{ ");
        try emitArgs(emitter, ctx, invocation.args, &invocation.path);
        try emitter.write(" };\nconst __koru_par_w_");
        try writeBranchName(emitter, slot);
        try emitter.write(" = struct {\n    fn run(__in: ");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".Input, __out: *");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".Output) void {\n        __out.* = ");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".handler(__in);\n    }\n    fn runTask(__in: ");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".Input, __out: *");
        try emitInvocationTarget(emitter, ctx, &invocation.path);
        try emitter.write(".Output) void {\n        __koru_par_depth += 1;\n        defer __koru_par_depth -= 1;\n        run(__in, __out);\n        _ = __koru_par_tasks.fetchSub(1, .monotonic);\n    }\n};\n");
        try emitter.write("var __koru_par_wg_");
        try writeBranchName(emitter, slot);
        try emitter.write(": @import(\"std\").Thread.WaitGroup = .{};\n");
        try emitter.write("if (__koru_par_depth < __koru_par_DEPTH_CAP and __koru_par_tasks.load(.monotonic) < __koru_par_CAP) {\n    _ = __koru_par_tasks.fetchAdd(1, .monotonic);\n    __koru_par_pool_ensure().spawnWg(&__koru_par_wg_");
        try writeBranchName(emitter, slot);
        try emitter.write(", __koru_par_w_");
        try writeBranchName(emitter, slot);
        try emitter.write(".runTask, .{ __koru_par_in_");
        try writeBranchName(emitter, slot);
        try emitter.write(", &");
        try writeBranchName(emitter, slot);
        try emitter.write(" });\n} else __koru_par_w_");
        try writeBranchName(emitter, slot);
        try emitter.write(".run(__koru_par_in_");
        try writeBranchName(emitter, slot);
        try emitter.write(", &");
        try writeBranchName(emitter, slot);
        try emitter.write(");\n");
        const tvar = try std.fmt.allocPrint(ctx.allocator, "__koru_par_wg_{s}", .{slot});
        try ctx.pending_parallel.append(ctx.allocator, tvar);
        if (!std.mem.eql(u8, bound_var, "_")) {
            try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, bound_var));
        }
        return;
    }
    if (!std.mem.eql(u8, bound_var, "_")) {
        try emitter.write(if (bound_mutable) "var " else "const ");
        // Record the name for the current Zig function scope: an inline frame
        // downstream in the same chain must not re-bind it (400_151).
        try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, bound_var));
    }
    // A call-site binding may legally collide with a Zig keyword or primitive
    // (`: u1` — 230_018); writeBranchName escapes it to `@"u1"`.
    try writeBranchName(emitter, bound_var);
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

    // A `[norun]` event's call site is declaration data — `|variant` there is
    // metadata a collector reads off the AST (stack's `service(db)|dev`), not
    // proc dispatch. Emit `handler__<variant>` only when a variant proc was
    // actually declared; otherwise the event struct has no such member and the
    // base handler is the only honest target.
    if (effective_variant) |v| {
        if (findEventDeclForEmission(ctx, &invocation.path)) |ed| {
            var is_norun = false;
            for (ed.annotations) |ann| {
                if (std.mem.eql(u8, ann, "norun")) {
                    is_norun = true;
                    break;
                }
            }
            if (is_norun) {
                var has_variant_impl = false;
                const item_lists = [2]?[]const ast.Item{ ctx.ast_items, ctx.program_items };
                for (item_lists) |maybe_items| {
                    if (maybe_items) |items| {
                        if (findVariantProcsByPath(ctx.allocator, items, &invocation.path)) |vprocs| {
                            defer ctx.allocator.free(vprocs);
                            for (vprocs) |vp| {
                                if (vp.target) |t| {
                                    if (std.mem.eql(u8, t, v)) {
                                        has_variant_impl = true;
                                        break;
                                    }
                                }
                            }
                        } else |_| {}
                        if (has_variant_impl) break;
                    }
                }
                if (!has_variant_impl) effective_variant = null;
            }
        }
    }

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

        canonical_len = invocation.path.writeSegments(&canonical_buf, canonical_len);

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
            const ed = findEventDeclForEmission(ctx, &invocation.path) orelse break :blk false;
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
    // Bind-position shape-destructure: `~f(): { pos: { x }, label } |> ...` binds
    // the return to the temp above (bound_var), then emits per-field consts so the
    // following pipeline references x/label directly. The bind-site twin of the
    // branch-payload destructure lowering.
    if (invocation.return_destructure.len > 0) {
        try emitter.writeIndent();
        try emitDestructureConsts(emitter, invocation.return_destructure, bound_var);
        try emitter.write("\n");
    }
}

/// Emit the target of an invocation (e.g., "koru_std.io.print_event" or "main_module.hello_event")
/// Write ONLY the module-namespace prefix (with trailing `.`) an invocation
/// target resolves to — factored from `emitInvocationTarget` so the inline
/// splice can render the same prefix as a string for the `$mod.` rewrite.
fn emitInvocationModulePrefix(emitter: *CodeEmitter, ctx: *EmissionContext, path: *const ast.DottedPath) !void {
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
}

/// Render the module-namespace prefix for `path` (e.g. `koru_libs.koru_raylib.`)
/// into an allocated string — the `$mod.` rewrite target for spliced bodies.
fn renderSelfPrefix(ctx: *EmissionContext, path: *const ast.DottedPath) ![]u8 {
    var sub = try CodeEmitter.initGrowable(ctx.allocator, 64);
    defer if (sub.allocator) |a| a.free(sub.buffer);
    try emitInvocationModulePrefix(&sub, ctx, path);
    return try ctx.allocator.dupe(u8, sub.buffer[0..sub.pos]);
}

fn emitInvocationTarget(emitter: *CodeEmitter, ctx: *EmissionContext, path: *const ast.DottedPath) !void {
    try emitInvocationModulePrefix(emitter, ctx, path);

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

/// Emit a `__koru_ast.InvocationMeta` field block — `.path`, `.module`,
/// `.event_name`, `.annotations`, `.location` — plus the closing `}`.
/// The caller emits the `…InvocationMeta{\n` head and indent.
fn emitInvocationMetaFields(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    invocation_path: *const ast.DottedPath,
) !void {
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

    // .event_name - just the tor name (last segment)
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
}

/// Emit a Source argument value as the `__koru_ast.Source{...}` literal the
/// callee's input field declares. `arg.source_value`/`arg.value` carry the
/// captured text; the text lands as Zig `\\` multiline lines — an empty
/// Source emits `""` rather than leaving `.text =` dangling.
/// Every call-site emitter (emitArgs, subflow heads, string codegen) routes
/// through this one so Source never splices raw Koru text into Zig.
pub fn emitSourceValue(emitter: *CodeEmitter, arg: *const ast.Arg) !void {
    try emitter.write("__koru_ast.Source{ .text = \n");
    emitter.indent();
    try emitter.writeIndent();
    // Use Zig multiline string syntax - split on newlines manually.
    var line_start: usize = 0;
    if (arg.value.len == 0) {
        try emitter.write("\"\"\n");
        try emitter.writeIndent();
    }
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

        // Resolve the parameter this arg binds: a bare pun names its field even
        // when appended late; index is the fallback for a name that is no field.
        const param_name = blk: {
            if (event_decl) |event| {
                break :blk ast.resolveArgParamName(arg, idx, event.input.fields);
            }
            // Fallback: use arg.name (might produce invalid Zig)
            break :blk arg.name;
        };

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
        // The decl lookup misses for callees that are not plain event decls
        // — transforms like capture/captured take Source params but resolve
        // through a different table. The parser already marked the arg:
        // `source_value` is set only for Source-typed args (expression_value
        // rides on ordinary args too), so trust it here — the emission is the
        // typed literal, never the raw text spliced into the struct field.
        if (!is_source_arg and !is_expression_arg and !is_invocation_meta_arg and
            arg.source_value != null)
        {
            is_source_arg = true;
        }

        if (is_expression_arg) {
            // An Expression parameter carries the captured expression TEXT —
            // the same `arg.value` string literal serves both emission modes:
            // comptime handlers consume it during evaluate_comptime, and a
            // runtime-position call transports the text to the callee
            // (parser.zig: "an Expression is just another way to pass a
            // string").
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
            // A Source param carries captured text — the callee receives the
            // Source struct with `.text` set to what the call site wrote.
            // Emit the same literal in both modes: comptime handlers consume
            // it during evaluate_comptime; a runtime-position call to an
            // unannotated tor transports the text. `[comptime]` callees never
            // reach here — flowInvokesComptimeEvent routes their flows to
            // comptime emission; a slipped call fails at backend compile on
            // the missing decl rather than panicking here.
            try emitSourceValue(emitter, &arg);
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
            try emitInvocationMetaFields(emitter, ctx, invocation_path);
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
        try emitMissingOptionalArgs(emitter, event.input.fields, args);
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
                    if (!argProvided(args, "program")) {
                        if (args.len > 0 or injected_count > 0) try emitter.write(", ");
                        try emitter.write(".program = program");
                        injected_count += 1;
                    }
                }
                // Check for allocator parameter (not already provided)
                if (std.mem.eql(u8, field.name, "allocator")) {
                    if (!argProvided(args, "allocator")) {
                        if (args.len > 0 or injected_count > 0) try emitter.write(", ");
                        try emitter.write(".allocator = allocator");
                        injected_count += 1;
                    }
                }
                // Check for InvocationMeta parameter (not already provided)
                if (field.is_invocation_meta) {
                    if (!argProvided(args, field.name)) {
                        if (args.len > 0 or injected_count > 0) try emitter.write(", ");
                        try emitter.write(".");
                        try writeBranchName(emitter, field.name);
                        try emitter.write(" = __koru_ast.InvocationMeta{\n");
                        emitter.indent();
                        try emitInvocationMetaFields(emitter, ctx, invocation_path);
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
    FlatShapeUnsupported, // flat-emission walk hit a node the eligibility gate should have refused
    NoSpaceLeft, // fixed-size fmt buffers (reentry temps, lane indices)
    OutOfMemory, // growable CodeEmitter buffers allocate on demand
};

/// Emit a value expression (may reference input fields).
///
/// A Koru EXPRESSION, so it goes through `lowerExprZig` — the body of `-> n % 2`
/// and every field RHS arrives here as raw text, and this is the Zig target's
/// only chance to spell it.
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

    // Field punning: { p.x, p.y } -> .{ .x = p.x, .y = p.y }
    if (isFieldPunningLiteral(trimmed)) {
        try emitFieldPunningLiteral(emitter, ctx, trimmed);
        return;
    }

    // Plain-value braces: { a + b } -> a + b
    if (isBracedPlainExpression(trimmed)) {
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
        try emitValue(emitter, ctx, inner);
        return;
    }

    // If we have an input_var and input_fields, replace input field references
    if (ctx.input_var) |input_var| {
        if (ctx.input_fields) |fields| {
            // Parse the expression and replace field references with input_var.field
            try emitValueWithInputPrefixing(emitter, ctx, value, input_var, fields);
            return;
        }
    }

    // Otherwise write value as-is — spelled for this target
    try emitter.write(lowerExprZig(emitter, ctx, value));
}

/// Emit a value expression with binding substitution (for tap pipeline emission).
/// Lowered FIRST, then spliced: the substitute walks the text it is given, and a
/// `%` it cannot see is one the emitter cannot spell.
fn emitValueWithBindingSubstitution(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    value: []const u8,
    substitution: ?BindingSubstitution,
) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        return error.ArrayLiteralMissingType;
    }

    // Spell it for this target BEFORE splicing: the walk below is a text scan,
    // so an unlowered `%` would be carried into the output verbatim.
    const lowered = lowerExprZig(emitter, ctx, value);

    if (substitution == null) {
        // No substitution needed
        try emitter.write(lowered);
        return;
    }

    const sub = substitution.?;
    var i: usize = 0;
    var in_string = false;
    var in_char = false;

    while (i < lowered.len) {
        const c = lowered[i];

        // Track string literals
        if (!in_char and c == '"' and !isEscaped(lowered, i)) {
            in_string = !in_string;
            try emitter.write(lowered[i .. i + 1]);
            i += 1;
            continue;
        }

        // Track char literals
        if (!in_string and c == '\'' and !isEscaped(lowered, i)) {
            in_char = !in_char;
            try emitter.write(lowered[i .. i + 1]);
            i += 1;
            continue;
        }

        // If we're in a string or char literal, just emit as-is
        if (in_string or in_char) {
            try emitter.write(lowered[i .. i + 1]);
            i += 1;
            continue;
        }

        // Check for identifiers
        if (isIdentStartChar(c)) {
            // Find the end of the identifier
            var j = i + 1;
            while (j < lowered.len and isIdentChar(lowered[j])) {
                j += 1;
            }

            const identifier = lowered[i..j];

            // Check if this matches the binding we want to substitute
            if (std.mem.eql(u8, identifier, sub.from)) {
                // Check word boundaries
                const before_ok = i == 0 or (!isIdentChar(lowered[i - 1]) and lowered[i - 1] != '@');
                const after_ok = j >= lowered.len or !isIdentChar(lowered[j]);

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
        try emitter.write(lowered[i .. i + 1]);
        i += 1;
    }
}

/// Emit a value expression, replacing input field references with input_var.field
fn emitValueWithInputPrefixing(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    value: []const u8,
    input_var: []const u8,
    input_fields: []const ast.Field,
) !void {
    // Spell it for this target before rewriting field references: the walk below
    // is a text scan, so an unlowered `%` would be carried out verbatim.
    const lowered = lowerExprZig(emitter, ctx, value);
    var i: usize = 0;
    var in_string = false;
    var in_char = false;

    while (i < lowered.len) {
        const c = lowered[i];

        // Track string literals
        if (!in_char and c == '"' and !isEscaped(lowered, i)) {
            in_string = !in_string;
            try emitter.write(lowered[i .. i + 1]);
            i += 1;
            continue;
        }

        // Track char literals
        if (!in_string and c == '\'' and !isEscaped(lowered, i)) {
            in_char = !in_char;
            try emitter.write(lowered[i .. i + 1]);
            i += 1;
            continue;
        }

        // If we're in a string or char literal, just emit as-is
        if (in_string or in_char) {
            try emitter.write(lowered[i .. i + 1]);
            i += 1;
            continue;
        }

        // Check for identifiers
        if (isIdentStartChar(c)) {
            // Find the end of the identifier — kebab-greedy: an infix `-`
            // joins one Koru name (`pos-tempo`), never splits it.
            var j = i + 1;
            while (j < lowered.len and (isIdentChar(lowered[j]) or
                (lowered[j] == '-' and j + 1 < lowered.len and isIdentChar(lowered[j + 1]))))
            {
                j += 1;
            }

            // Check if this identifier is an input field reference
            if (isInputFieldReference(lowered, i, j, input_fields)) {
                // Emit as input_var.field
                try emitter.write(input_var);
                try emitter.write(".");
                try writeBranchName(emitter, lowered[i..j]);
            } else {
                // Not a field reference, emit as-is
                try emitter.write(lowered[i..j]);
            }

            i = j;
            continue;
        }

        // Not an identifier, just emit the character
        try emitter.write(lowered[i .. i + 1]);
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
            // Cross-boundary splice hygiene: a renamed consumer binding.
            // Innermost rename first — enclosing renames stay live alongside it.
            {
                var ri = ctx.splice_binding_renames.items.len;
                while (ri > 0) {
                    ri -= 1;
                    const sub = ctx.splice_binding_renames.items[ri];
                    if (std.mem.eql(u8, ident, sub.from)) {
                        try emitter.write(sub.to);
                        return;
                    }
                }
            }
            try writeBranchName(emitter, ident);
        },
        .field_access => |fa| {
            try emitExpression(emitter, ctx, fa.object, binding_substitution);
            try emitter.write(".");
            try writeBranchName(emitter, fa.field);
        },
        .binary => |bin| {
            // `%` is not a token in this host: Zig's `%` is UNSIGNED-only
            // ("signed integers and floats must use @rem or @mod") and Koru's is
            // C's truncated remainder — what `comptime_eval.zig` folds it with
            // and what the JS target's `%` means. `@rem` is that same operator
            // at every operand type, so it emits as a call. codegen_utils's
            // rewriteZigExpr is the twin of this arm for condition TEXT; this
            // one is reached when the same condition arrived as a parsed
            // expression (`Continuation.condition_expr`).
            if (bin.op == .modulo) {
                try emitter.write("@rem(");
                try emitExpression(emitter, ctx, bin.left, binding_substitution);
                try emitter.write(", ");
                try emitExpression(emitter, ctx, bin.right, binding_substitution);
                try emitter.write(")");
            } else {
                try emitter.write("(");
                try emitExpression(emitter, ctx, bin.left, binding_substitution);
                try emitter.write(" ");
                try emitBinaryOperator(emitter, bin.op);
                try emitter.write(" ");
                try emitExpression(emitter, ctx, bin.right, binding_substitution);
                try emitter.write(")");
            }
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
            // `@as(T, @intCast(x))` routes through `__koru_intcast` — the
            // cast's `llvm.assume` lands in-loop and declines vectorization
            // (see emitMainModuleStart). Twin of rewriteZigExpr's text path.
            if (std.mem.eql(u8, bc.name, "as") and bc.args.len == 2 and
                bc.args[1].node == .builtin_call and
                std.mem.eql(u8, bc.args[1].node.builtin_call.name, "intCast") and
                bc.args[1].node.builtin_call.args.len == 1)
            {
                try emitter.write("__koru_intcast(");
                try emitExpression(emitter, ctx, bc.args[0], binding_substitution);
                try emitter.write(", ");
                try emitExpression(emitter, ctx, bc.args[1].node.builtin_call.args[0], binding_substitution);
                try emitter.write(")");
            } else {
                try emitter.write("@");
                try emitter.write(bc.name);
                try emitter.write("(");
                for (bc.args, 0..) |arg, i| {
                    if (i > 0) try emitter.write(", ");
                    try emitExpression(emitter, ctx, arg, binding_substitution);
                }
                try emitter.write(")");
            }
        },
        .array_index => |ai| {
            try emitExpression(emitter, ctx, ai.object, binding_substitution);
            try emitter.write("[");
            // Index position coerces to usize — the same-width sign flip
            // bitcasts through `__koru_intcast` instead of emitting
            // @intCast's in-loop assume.
            if (ai.index.node == .builtin_call and
                std.mem.eql(u8, ai.index.node.builtin_call.name, "intCast") and
                ai.index.node.builtin_call.args.len == 1)
            {
                try emitter.write("__koru_intcast(usize, ");
                try emitExpression(emitter, ctx, ai.index.node.builtin_call.args[0], binding_substitution);
                try emitter.write(")");
            } else {
                try emitExpression(emitter, ctx, ai.index, binding_substitution);
            }
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

/// Emit the INFIX TOKEN for a binary operator.
///
/// `%` is deliberately not one: no token in Zig spells Koru's truncated
/// remainder for a signed operand, so `emitExpression` emits it as the `@rem`
/// call before reaching here. Routing it back here would emit a `%` Zig refuses
/// at Stage D, so the prong is a LOUD stop rather than a silent spelling.
fn emitBinaryOperator(emitter: *CodeEmitter, op: ast.BinaryOperator) !void {
    switch (op) {
        .add => try emitter.write("+"),
        .subtract => try emitter.write("-"),
        .multiply => try emitter.write("*"),
        .divide => try emitter.write("/"),
        .modulo => unreachable, // `%` emits as `@rem(…)` — see emitExpression
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
    callee_path: ?*const ast.DottedPath,
    /// True when the sparse-dispatch tag guard below must NOT fire — plain
    /// FLOW-HEAD dispatch (non-label emitFlow sites pass true): heads have
    /// always emitted the unguarded union read, and the test framework's
    /// unexpected-branch wall is BUILT on the panic that read produces — a
    /// mock returning an unhandled branch must fail the test, not no-op
    /// (395_010). Guarding a head converts that failure into silence.
    ///
    /// Nested chain sites pass false and keep the guard: sparse dispatch there
    /// is a normal program shape and the unguarded read is a runtime panic on
    /// the common path (690_085/095). Label-loop sites (flow-head pre_label
    /// and mid-chain folds) also pass false — inside `label: while (true)`
    /// there is no loop-condition discrimination left, so a sparse single arm
    /// needs its `if (result == .b)` test to exit the loop on other branches.
    suppress_tag_guard: bool,
) anyerror!void {
    const callee_bare_return = blk: {
        if (callee_path) |path| {
            if (ctx.ast_items) |items| {
                if (findEventDeclByPath(items, path)) |decl| {
                    break :blk decl.return_type != null;
                }
            }
        }
        break :blk false;
    };
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

    // How many TERMINALS the callee declares. One handled continuation means
    // "that branch is certainly active" only when the callee has nowhere else to
    // go; if it declares several and the author named one, the other outcomes
    // are still reachable and the payload must be read behind a tag test.
    //
    // Sparse dispatch became ordinary when `| row` went optional (690_085): an
    // insert declares `| row` and `| full`, and handling only `| full` is now a
    // normal thing to write. Reading `.full` unconditionally then panics on the
    // common path — `access of union field 'full' while field 'row' is active` —
    // which a compile cannot see and only a run finds (690_095).
    const callee_terminals = blk: {
        if (callee_path) |path| {
            if (ctx.ast_items) |items| {
                if (findEventDeclByPath(items, path)) |decl| {
                    var n: usize = 0;
                    for (decl.branches) |b| {
                        if (b.kind == .terminal) n += 1;
                    }
                    break :blk n;
                }
            }
        }
        break :blk 0; // unknown — keep the established shape
    };

    // If only ONE branch, we can access the payload directly without a switch!
    // This is the KEY to making explicit while conditions work with Version 11's pattern
    if (continuations.len == 1) {
        const cont = &continuations[0];

        // An unhandled sibling outcome is a NO-OP at a dispatch site (690_085),
        // so the guard needs no `else`.
        const needs_tag_guard = !callee_bare_return and
            !suppress_tag_guard and
            callee_terminals > 1 and
            !cont.is_catchall and
            cont.branch.len > 0;
        if (needs_tag_guard) {
            try emitter.writeIndent();
            try emitter.write("if (");
            try emitter.write(prev_result);
            try emitter.write(" == .");
            try writeBranchName(emitter, cont.branch);
            try emitter.write(") {\n");
            emitter.indent();
        }
        defer if (needs_tag_guard) {
            emitter.dedent();
            emitter.writeIndent() catch {};
            emitter.write("}\n") catch {};
        };

        // Special case: |? catch-all as the sole continuation (all branches optional).
        // There is no "*" field on the union — every result IS an optional branch, so
        // the body always fires unconditionally.  Discard the result and execute directly.
        if (cont.is_catchall and std.mem.eql(u8, cont.branch, "*") and cont.catchall_metatype == null) {
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try writeBranchName(emitter, prev_result);
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
        if (!callee_bare_return) {
            try emitter.write(".");
            try writeBranchName(emitter, cont.branch);
        }
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
                try emitter.write(lowerExprZig(emitter, ctx, condition));
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

    // Check for |* residual continuation
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
        // Skip residual (it has branch = "*" and will be handled separately)
        if (std.mem.eql(u8, group.branch_name, "*")) continue;
        // Anonymous continuations are the step's JOIN — they ride no union tag
        // and emit once after the switch, same as the inline path's
        // emitAnonymousContinuations (400_193/400_205 for keyword tors; the
        // rule is general).
        if (group.branch_name.len == 0) continue;

        if (group.continuations.len == 1) {
            // Single continuation - emit as normal
            try emitContinuationCase(emitter, ctx, group.continuations[0], result_counter);
        } else {
            // Multiple continuations for same branch - emit case with if/else chain
            try emitWhenClauseCase(emitter, ctx, group, result_counter);
        }
    }

    // Omitted OPTIONAL branches get a silent no-op arm on every bare,
    // exhaustive switch (flow heads AND pipeline steps both emit one). The
    // optional contract is "may be handled" — the union still contains the
    // optional variants, so a switch with no `else` must complete them
    // (`?partial` on bridge:run was the defeat that surfaced this: every
    // consumer without a `| partial` arm failed exhaustiveness). A catch-all
    // already covers the same ground below; a partial switch adds its own
    // `else => unreachable` and needs neither.
    if (catchall_cont == null and !is_partial_switch) {
        if (ctx.current_source_event) |source_event| {
            if (ctx.ast_items) |items| {
                const event_decl = findEventByName(items, source_event, ctx.allocator, ctx.main_module_name);
                if (event_decl) |event| {
                    var handled_branches = std.StringHashMap(void).init(ctx.allocator);
                    defer handled_branches.deinit();
                    for (continuation_branch_groups) |group| {
                        if (std.mem.eql(u8, group.branch_name, "*")) continue;
                        try handled_branches.put(group.branch_name, {});
                    }
                    for (event.branches) |branch| {
                        if (!branch.is_optional) continue;
                        if (branch.kind != .terminal) continue; // effects are handler calls, not union tags
                        if (handled_branches.contains(branch.name)) continue;
                        try emitter.writeIndent();
                        try emitter.write(".");
                        try writeBranchName(emitter, branch.name);
                        try emitter.write(" => {},\n");
                    }
                }
            }
        }
    }

    // If there's a catch-all, emit cases for unhandled optional branches
    if (catchall_cont) |catchall| {
        // Find which branches are explicitly handled
        var handled_branches = std.StringHashMap(void).init(ctx.allocator);
        defer handled_branches.deinit();

        for (continuation_branch_groups) |group| {
            if (std.mem.eql(u8, group.branch_name, "*")) continue; // Skip the residual arm itself
            try handled_branches.put(group.branch_name, {});
        }

        // Find the event definition to get optional branches
        if (ctx.current_source_event) |source_event| {
            // Look up event in AST
            if (ctx.ast_items) |items| {
                const event_decl = findEventByName(items, source_event, ctx.allocator, ctx.main_module_name);
                if (event_decl) |event| {
                    // Check if residual arm has metatype binding (|* Audit e |>)
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

                            const is_transition = std.mem.eql(u8, catchall.catchall_metatype.?, "Transition");

                            // .source — enum literal for Transition (taps.EventEnum),
                            // string for Profile/Audit (their structs are string-based,
                            // see emitTapsNamespace).
                            try emitter.writeIndent();
                            if (is_transition) {
                                try emitter.write(".source = .");
                                try canonicalNameToEnumTag(emitter, source_event);
                                try emitter.write(",\n");
                            } else {
                                try emitter.write(".source = \"");
                                try emitter.write(source_event);
                                try emitter.write("\",\n");
                            }

                            // .destination = null (terminal)
                            try emitter.writeIndent();
                            try emitter.write(".destination = null,\n");

                            // .branch — enum literal for Transition, string otherwise
                            try emitter.writeIndent();
                            try emitEnumOrStringField(emitter, ".branch = ", emitBranchEnumValue, branch.name, is_transition);

                            // .timestamp_ns (Profile/Audit only)
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

                            // The synthesized binding is minted for the
                            // constructor even when the body discards it —
                            // suppress the unused-constant (mirrors the
                            // metatype_binding step path).
                            try emitter.writeIndent();
                            try emitter.write("_ = &");
                            try writeBranchName(emitter, catchall.binding.?);
                            try emitter.write(";\n");

                            // Execute residual pipeline (can now reference binding)
                            try emitContinuationBody(emitter, ctx, catchall, result_counter);

                            emitter.dedent();
                            try emitter.writeIndent();
                            try emitter.write("},\n");
                        } else {
                            // No metatype binding — discard payload
                            try emitter.write(" => |_| {\n");
                            emitter.indent();

                            // Execute residual pipeline
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

    // The join tail: anonymous continuations run once after the dispatch,
    // in source order, after whichever arm fired.
    for (continuations) |*cont| {
        if (cont.is_catchall or cont.branch.len != 0) continue;
        try emitContinuationBody(emitter, ctx, cont, result_counter);
    }
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
    var has_payload_fields = if (ctx.current_source_event) |event_name|
        branchHasPayloadFields(ctx, event_name, cont.branch)
    else
        false; // Can't verify — omit capture to avoid shadowing

    // Resume-arm switch at an arm-fire site (subflow-implemented effects):
    // the cases are arms of the fired effect's resume sum, not branches of
    // an event, so payload presence comes from the arm declaration.
    if (!has_payload_fields) {
        if (ctx.current_resume_arms) |arms| {
            for (arms) |*ra| {
                if (std.mem.eql(u8, ra.name, cont.branch)) {
                    has_payload_fields = ra.type != null;
                    break;
                }
            }
        }
    }

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
            // per-field consts at the top of the case block. A named group
            // (`| ok e:{ k }`) captures under the group name instead.
            if (cont.binding != null and !std.mem.eql(u8, cont.binding.?, "_")) {
                try writeBranchName(emitter, cont.binding.?);
            } else {
                try emitter.write("__koru_dst");
            }
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
        const dst = if (cont.binding != null and !std.mem.eql(u8, cont.binding.?, "_")) cont.binding.? else "__koru_dst";
        try emitDestructureConsts(emitter, cont.destructure, dst);
        try emitter.write("\n");
    }
    // Produce stage `! each i { f, g: e }` — emit `const f = i.f` for a pun,
    // `const g = <expr>` for a named expr (`{ i }` pun emits `const i = i`).
    if (cont.produce.len > 0 and cont.binding != null) {
        for (cont.produce) |pf| {
            if (std.mem.eql(u8, pf.name, "_")) continue;
            try emitter.writeIndent();
            try emitter.write("const ");
            try writeBranchName(emitter, pf.name);
            try emitter.write(" = ");
            if (pf.type_text) |t| {
                try emitter.write(lowerExprZig(emitter, ctx, t));
            } else if (std.mem.eql(u8, pf.name, cont.binding.?)) {
                try emitter.write(cont.binding.?);
            } else {
                try emitter.write(cont.binding.?);
                try emitter.write(".");
                try emitter.write(pf.name);
            }
            try emitter.write("; _ = &");
            try writeBranchName(emitter, pf.name);
            try emitter.write(";");
        }
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
            try emitter.write(lowerExprZig(emitter, ctx, condition));
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
    const binding_name = if (first_cont.destructure.len > 0) (first_cont.binding orelse "__koru_dst") else first_cont.binding orelse first_cont.branch;

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
            try emitter.write(lowerExprZig(emitter, ctx, condition));
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

/// Per-field variant of labelWillBeMutated: does ANY @label jump to `label`
/// re-seed `field_name`? A jump's args name the fields it updates; fields it
/// omits carry over, so their state var can stay `const` — `var` on a
/// never-assigned local is a backend error ("local variable is never
/// mutated"). Same traversal as labelWillBeMutated: step nodes plus nested
/// continuation bodies.
fn labelFieldWillBeMutated(label: []const u8, field_name: []const u8, continuations: []const ast.Continuation) bool {
    for (continuations) |cont| {
        if (cont.node) |step| {
            if (step == .label_jump) {
                const lj = step.label_jump;
                if (std.mem.eql(u8, lj.label, label)) {
                    for (lj.args) |arg| {
                        if (std.mem.eql(u8, arg.name, field_name)) {
                            return true;
                        }
                    }
                }
            }
        }

        if (labelFieldWillBeMutated(label, field_name, cont.continuations)) {
            return true;
        }
    }

    return false;
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
        try writeBranchName(emitter, current_result);
        try emitter.write(";\n");
    }

    if (needs_result and step.* != .conditional_block and step.* != .metatype_binding and !is_void_step) {
        result_counter.* += 1;
    }
}

/// A `->` produce whose expression NAMES one of the implemented event's own
/// branches: `~drive = source(n) | done d -> finished d`, where `drive` declares
/// `| finished string`. The bare-return twin of this (`-> expr` on a `-> T`
/// event) is handled by `bare_return_active`; an event with NAMED branches had
/// no counterpart, so the produce fell through to `_ = finished d;` — invalid
/// Zig, and the reason a flow could only ever implement a bare-return event.
///
/// Returns true when it emitted the tagged return, false to fall through.
/// Emit what an arm PRODUCES, as a Zig expression.
///
/// A branch constructor with a name wraps its payload in that branch:
/// `-> finished d` becomes `.{ .finished = d }`. **A constructor with NO name is
/// the whole value**, because the tor it implements has a bare return and there
/// is no branch to name — `-> { label: "high", code: 1 }` is that record and
/// nothing more.
///
/// Emitting the named form regardless produced `.{ . = { label: "high" } }`:
/// a field access with an empty name, AND the Koru record pasted through
/// untranslated because the wrapper had swallowed the one path that lowers it.
/// Two errors on one line, from one missing question. It reached every arm of
/// every router in orisha, whose `handler` is bare-return.
///
/// Mirror of `emitBranchProduce` (350_017), which fixed the same blind spot from
/// the other side: there a NAMED produce was lowered as if it were bare.
fn emitProducedConstructor(
    emitter: *CodeEmitter,
    main_module_name: ?[]const u8,
    bc: *const ast.BranchConstructor,
) EmitError!void {
    var ctx = EmissionContext{
        .allocator = emitter.allocator orelse std.heap.page_allocator,
        .main_module_name = main_module_name,
    };
    // No name at all: the arm produced straight into a bare-return tor, so the
    // record IS the value. Wrapping it would name a field the Output type does
    // not have.
    const bare = bc.branch_name.len == 0;

    if (!bare) {
        try emitter.write(".{ .");
        try writeBranchName(emitter, bc.branch_name);
        try emitter.write(" = ");
    }

    if (bc.plain_value) |pv| {
        // `emitValue` is what turns a Koru record into a Zig one; the old code
        // wrote `pv` verbatim, which only ever worked because a NAMED branch's
        // payload happens to be a bare expression.
        try emitValue(emitter, &ctx, pv);
    } else {
        try emitter.write(".{");
        for (bc.fields, 0..) |field, idx| {
            if (idx > 0) try emitter.write(", ");
            try emitter.write(" .");
            try writeBranchName(emitter, field.name);
            try emitter.write(" = ");
            if (field.expression_str) |expr| {
                try emitValue(emitter, &ctx, expr);
            } else {
                try emitter.write(field.type);
            }
        }
        try emitter.write(" }");
    }

    if (!bare) try emitter.write(" }");
}

fn emitBranchProduce(emitter: *CodeEmitter, ctx: *EmissionContext, code: []const u8) !bool {
    const decl = ctx.produce_event orelse ctx.impl_event_decl orelse return false;
    if (decl.branches.len == 0) return false;

    const trimmed = std.mem.trim(u8, code, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "_")) return false;

    // First token is the candidate branch name; the rest is its payload.
    var split: usize = 0;
    while (split < trimmed.len and trimmed[split] != ' ' and trimmed[split] != '\t') : (split += 1) {}
    const head = trimmed[0..split];
    const payload = std.mem.trim(u8, trimmed[split..], " \t");

    const branch = for (decl.branches) |*b| {
        if (b.kind != .terminal) continue;
        if (std.mem.eql(u8, b.name, head)) break b;
    } else return false;

    // An empty-payload branch takes no value: `-> stopped` → `return .stopped;`.
    if (branch.payload.fields.len == 0 and !branch.payload.is_wildcard) {
        if (payload.len != 0) return false; // shape mismatch — let the checker speak
        try emitter.write("return .");
        try writeBranchName(emitter, branch.name);
        try emitter.write(";\n");
        return true;
    }

    if (payload.len == 0) return false;

    try emitter.write("return .{ .");
    try writeBranchName(emitter, branch.name);
    try emitter.write(" = ");
    try emitter.write(payload);
    try emitter.write(" };\n");
    return true;
}

/// A `label: while (true)` fold inside a handler whose Output is non-void must
/// produce on every path — looping arms `continue`, exiting arms `return` a
/// value inside the switch. A path that reaches `break :label` (a `_`
/// continuation, an arm end with no produce — "can't happen" spelled `|> _`)
/// owes a value it never made. Falling off the end of a non-void fn is invalid
/// Zig; `unreachable` is UB under the ReleaseFast output build, so the guard
/// panics loudly in every optimize mode. Void contexts skip it — there
/// `break :label` is a legitimate fold exit into whatever follows the loop.
fn emitFoldFallthroughGuard(emitter: *CodeEmitter, ctx: *EmissionContext) !void {
    const decl = ctx.produce_event orelse ctx.impl_event_decl orelse return;
    var nonvoid = decl.return_type != null;
    if (!nonvoid) {
        for (decl.branches) |b| {
            if (b.kind == .terminal) {
                nonvoid = true;
                break;
            }
        }
    }
    if (!nonvoid) return;
    const name = if (decl.path.segments.len > 0) decl.path.segments[decl.path.segments.len - 1] else "?";
    const msg = try std.fmt.allocPrint(
        ctx.allocator,
        "@panic(\"koru: a #label fold arm in '{s}' exited the loop without a continue or a `->` produce — the handler owes a value it never made\");\n",
        .{name},
    );
    try emitter.writeIndent();
    try emitter.write(msg);
}

/// Append a shape-destructure pattern's leaf names to zig_scope_bindings —
/// `emitDestructureConsts` mints them as `const`s at the same site.
fn registerDestructureScopeNames(ctx: *EmissionContext, fields: []const ast.DestructureField) !void {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "_") or std.mem.startsWith(u8, f.name, "__")) continue;
        try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, f.name));
    }
}

pub fn emitContinuationBody(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
    result_counter: *usize,
) !void {
    // Register this continuation's bound names for the duration of its body
    // emission: the `| branch name` payload a switch prong emits below
    // (`.cl => |h|`), plus shape-destructure leaves. Effect-arm capture
    // analysis (isCaptureEligible) reads the set back to decide which refs
    // an enclosing fn can carry; the names are live for the whole subtree
    // and dead on return.
    const prev_scope_bindings_len = ctx.zig_scope_bindings.items.len;
    defer while (ctx.zig_scope_bindings.items.len > prev_scope_bindings_len) {
        const popped = ctx.zig_scope_bindings.pop() orelse break;
        ctx.allocator.free(popped);
    };
    if (cont.binding) |b| {
        if (!std.mem.eql(u8, b, "_") and !std.mem.startsWith(u8, b, "__")) {
            try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, b));
        }
    }
    try registerDestructureScopeNames(ctx, cont.destructure);
    // Produce stage `! each i { f, g: expr }` — one `const` per field: a
    // `name: expr` lowers the expr in the pre-stage scope, a bare `name`
    // pun binds the element's field (`const f = i.f`). A pun on the bound
    // element itself (`{ i }` where `i` is the binding) is a carry-through
    // — the name is already bound, so nothing emits. A produced name that
    // collides with a live binding (`{ i: i + 1 }` rebind) mints a
    // site-unique const and renames its downstream reads via
    // splice_binding_renames — the same mechanism the splice uses for
    // producer/consumer collisions; the RHS text is emitted before the
    // rename registers, so it still reads the pre-stage scope.
    const produce_rename_depth = ctx.splice_binding_renames.items.len;
    defer ctx.splice_binding_renames.shrinkRetainingCapacity(produce_rename_depth);
    for (cont.produce) |pf| {
        if (std.mem.eql(u8, pf.name, "_")) continue;
        if (pf.type_text == null) {
            if (cont.binding) |b| {
                if (std.mem.eql(u8, pf.name, b)) continue;
            }
        }
        var collides = false;
        if (cont.binding) |b| collides = std.mem.eql(u8, pf.name, b);
        if (!collides) {
            for (ctx.zig_scope_bindings.items) |sb| {
                if (std.mem.eql(u8, pf.name, sb)) {
                    collides = true;
                    break;
                }
            }
        }
        const emitted_name: []const u8 = if (collides) blk: {
            const uniq = try std.fmt.allocPrint(ctx.allocator, "__koru_prod_{s}_{d}_{d}", .{ pf.name, cont.location.line, cont.location.column });
            try ctx.splice_binding_renames.append(ctx.allocator, .{ .from = pf.name, .to = uniq });
            break :blk uniq;
        } else pf.name;
        try emitter.writeIndent();
        try emitter.write("const ");
        try writeBranchName(emitter, emitted_name);
        try emitter.write(" = ");
        if (pf.type_text) |t| {
            try emitter.write(lowerExprZig(emitter, ctx, t));
        } else if (cont.binding) |b| {
            try emitter.write(b);
            try emitter.write(".");
            try emitter.write(pf.name);
        }
        try emitter.write("; _ = &");
        try writeBranchName(emitter, emitted_name);
        try emitter.write(";\n");
    }

    // Post-produce `when` (`! each i { f } when f > 0`) — a guard in the
    // PRODUCED scope, emitted after the consts and wrapping the arm body.
    // (The pre-stage `when`, cont.condition, was already emitted by the
    // splice before this body.) Produce-renamed names are rewritten so a
    // rebind reads the new value (`{ i: i+1 } when i > 2` sees new `i`).
    if (cont.post_condition) |pc| {
        var cond_text: []const u8 = lowerExprZig(emitter, ctx, pc);
        var cond_owned: ?[]u8 = null;
        defer if (cond_owned) |o| ctx.allocator.free(o);
        for (ctx.splice_binding_renames.items) |br| {
            const rw = try codegen_utils.replaceIdentifier(ctx.allocator, cond_text, br.from, br.to);
            if (cond_owned) |o| ctx.allocator.free(o);
            cond_owned = @constCast(rw);
            cond_text = cond_owned.?;
        }
        try emitter.write("if (");
        try emitter.write(cond_text);
        try emitter.write(") { ");
    }
    defer if (cont.post_condition != null) emitter.write("} ") catch {};

    // Zero-overhead control flow at depth: if a template transform set
    // inline_body on this continuation's invocation node (e.g. a nested `~for`
    // in a pipeline — `| result r |> for(0..r) ! each … | done …`), emit it via
    // the shared node emitter — the SAME path top-level flows take. The
    // continuation's children are the node's branch continuations. This is the
    // de-duplication that makes inline templates work at every depth, not just
    // top-level: one helper, both call sites.
    // Escape-driven stack alloc: a nested invocation carrying preamble_code
    // (field:new.on-stack→new-instack via @preamble_then_call) emits its caller-frame
    // stack vars HERE, then falls through to the normal handler call + branch match
    // below — so the vars are in scope for the call and the downstream continuations.
    if (cont.node) |node| {
        if (node == .invocation) {
            if (node.invocation.preamble_code) |preamble| {
                try emitter.writeIndent();
                try emitter.write(preamble);
                try emitter.write("\n");
            }
        }
    }

    if (cont.node) |node| {
        if (node == .invocation) {
            if (node.invocation.inline_body) |inline_code_raw| {
                try emitInlineBodyNode(emitter, ctx, inline_code_raw, cont.continuations, &cont.node.?.invocation.path, result_counter, cont.node.?.invocation.return_binding);

                // A statement-template event (e.g. `std/io:print.ln`) declares
                // NO branches of its own, so a terminal continuation on its
                // step is NOT the template's to hand off — it is the CALLER's
                // `=> branch` re-raise, constructing THIS flow's declared
                // branch. `emitInlineBodyNode`'s "terminal — returned, not
                // appended" rule assumes a branch-bearing template (which
                // emits its own `__koru_return_<idx>` / `.continue` markers);
                // a branchless statement template has no such marker, and the
                // terminal would be silently dropped — the handler falls off
                // the end without returning (220_030). Emit those terminals
                // now, void-chain style: each lowers to its `return .branch;`.
                var step_declares_branches = false;
                if (ctx.ast_items) |items| {
                    if (findEventDeclByPath(items, &node.invocation.path) != null) {
                        step_declares_branches = true;
                    }
                }
                if (!step_declares_branches) {
                    // Narrow: ONLY the single-continuation `=> ok` RE-RAISE
                    // (`step = print.ln(...) => ok`). Multi-continuation
                    // pipelines (`field:new |> for ... | done |> set(...)`)
                    // have real nested work — emitInlineBodyNode already
                    // hands THEIR terminals off via template `.continue`
                    // markers; re-emitting them here for every branchless
                    // inline step hoists `| done |> set(...)` out of the
                    // effect loop and breaks loop-scoped bindings
                    // (115_004/029: the sieve's `k` outside the loop).
                    if (cont.continuations.len == 1) {
                        var only_reraise = false;
                        const only = cont.continuations[0];
                        if (only.branch.len != 0) {
                            if (only.node) |nd| {
                                if (nd == .branch_constructor) {
                                    const bc = &nd.branch_constructor;
                                    only_reraise = std.mem.eql(u8, bc.branch_name, only.branch);
                                }
                            }
                        }
                        if (only_reraise) {
                            try emitContinuationBody(emitter, ctx, &only, result_counter);
                        }
                    }
                }
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
            // var only where a jump actually re-seeds this field — an
            // under-filled jump leaves the rest carried over, and `var` on a
            // never-assigned local is a backend error.
            if (labelFieldWillBeMutated(lwi.label, arg.name, cont.continuations)) {
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
                const found_field = try writeArgFieldTypeAnnotation(emitter, event, arg.name, ctx.main_module_name);

                if (!found_field) {
                    std.debug.panic("COMPILER BUG: Field '{s}' not found in event after checking {} fields!", .{ arg.name, event.input.fields.len });
                }
            }

            try emitter.write(" = ");
            try emitter.write(lowerExprZig(emitter, ctx, arg.value));
            try emitter.write(";\n");
        }

        // Effect-branches phase 3b (nested fold): an event carrying `!` arms
        // compiles to `handler(Input, comptime __H)` — the 2nd arg holds the
        // synthesized Handlers struct that carries the effect-arm bodies. The
        // fold's SEED call and every back-edge re-invocation must pass it, or
        // the arity mismatch surfaces as a raw Zig error naming a `__H` the
        // author never wrote. Mirror emitFlow's pre_label partition: split the
        // fold's children into effect arms (folded into Handlers) and terminal
        // arms (which drive the loop switches); effect arms are NOT union
        // members and must never appear as switch arms. Pinned by 210_170 —
        // a fold with a prefix (`seed(): n0 |> #loop step(n: n0)`, the blocking
        // `await` shape) hit exactly this gap.
        const prev_pending_handlers = ctx.pending_handlers_name;
        defer ctx.pending_handlers_name = prev_pending_handlers;
        var fold_handlers_name_owned: ?[]const u8 = null;
        defer if (fold_handlers_name_owned) |h| ctx.allocator.free(h);

        var fold_terminal_buf: std.ArrayList(ast.Continuation) = .empty;
        defer fold_terminal_buf.deinit(ctx.allocator);
        var fold_effect_buf: std.ArrayList(ast.Continuation) = .empty;
        defer fold_effect_buf.deinit(ctx.allocator);

        var fold_event_has_effect = false;
        if (event_decl) |ed| {
            for (ed.branches) |b| {
                if (b.kind == .effect) {
                    fold_event_has_effect = true;
                    break;
                }
            }
        }
        if (fold_event_has_effect) {
            for (cont.continuations) |c| {
                if (c.kind == .effect) {
                    try fold_effect_buf.append(ctx.allocator, c);
                } else {
                    try fold_terminal_buf.append(ctx.allocator, c);
                }
            }
            // An effect event with a resume value is never inline-eligible (the
            // inline splice cannot express a resume value), so the Handlers path
            // is the only one — the same net as emitFlow's `inline_elig == null`
            // branch. The struct must be declared BEFORE the seed call below.
            const hname = try std.fmt.allocPrint(ctx.allocator, "Handlers_{d}", .{ctx.capture_counter})
            ; ctx.capture_counter += 1;
            fold_handlers_name_owned = hname;
            try emitHandlersStruct(emitter, ctx, hname, fold_effect_buf.items, event_decl.?);
            ctx.pending_handlers_name = hname;
        }
        const fold_conts: []const ast.Continuation = if (fold_event_has_effect) fold_terminal_buf.items else cont.continuations;

        // The fold's invocation is the loop's head: state vars feed an
        // in-loop `const` call each turn, and ONE exhaustive switch over ALL
        // continuations decides `continue :label` vs fall-through to
        // `break :label` — uniform for 0, 1, or many looping branches.
        const result_var = try std.fmt.allocPrint(ctx.allocator, "result_{}", .{result_counter.*});
        defer ctx.allocator.free(result_var);

        try emitter.writeIndent();
        try emitter.write(lwi.label);
        try emitter.write(": while (true) {\n");
        emitter.indent();

        try emitter.writeIndent();
        try emitter.write("const ");
        try emitter.write(result_var);
        try emitter.write(" = ");
        if (!ctx.is_sync) {
            try emitter.write("try ");
        }
        try emitInvocationTarget(emitter, ctx, &lwi.invocation.path);
        try emitter.write(".handler(.{ ");
        // Use state variables for the call
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
        try emitter.write(" }");
        // Effect-branches phase 3b: the fold target carries `!` arms, so the
        // in-loop call takes the synthesized Handlers struct as its 2nd arg.
        if (ctx.pending_handlers_name) |hname| {
            const target_has_effect = blk: {
                const ed = findEventDeclForEmission(ctx, &lwi.invocation.path) orelse break :blk false;
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
        try emitter.write(");\n");
        result_counter.* += 1;

        // Track current loop label for the whole switch — every arm is inside
        // the loop now, so `.terminal` -> `break :label` is correct for each.
        const saved_label = ctx.current_label;
        ctx.current_label = lwi.label;
        defer ctx.current_label = saved_label;

        // Emit nested continuations (the switch statement)
        if (fold_conts.len > 0) {
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

            try emitContinuationList(emitter, ctx, fold_conts, result_var, result_counter, false, &lwi.invocation.path, false);
        }

        try emitter.writeIndent();
        try emitter.write("break :");
        try emitter.write(lwi.label);
        try emitter.write(";\n");
        emitter.dedent();
        try emitter.writeIndent();
        try emitter.write("}\n");
        try emitFoldFallthroughGuard(emitter, ctx);

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

        // Mutual-group reentry: a tail-forward to any group member G lowers to
        // `__koru_fn = .<G>; <reassign>; continue` inside the combined dispatch
        // loop (see `detectMutualGroup` / `emitMutualTailReentry`).
        if (ctx.mutual_group) |group| {
            if (isTailForwarder(cont)) {
                const inv = cont.node.?.invocation;
                if (buildCanonicalEventName(&inv.path, ctx.allocator, ctx.main_module_name) catch null) |target| {
                    defer ctx.allocator.free(target);
                    if (group.tagFor(target)) |tag| {
                        try emitMutualTailReentry(emitter, ctx, cont, tag);
                        return;
                    }
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
                // Module-scope first, program-scope fallback — this path is
                // reached through detached contexts whose ast_items is the
                // emitting module's own slice (400_198).
                const event_decl_nested = findEventDeclForEmission(ctx, &maybe_step.invocation.path);
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
                            const hname = try std.fmt.allocPrint(ctx.allocator, "Handlers_{d}", .{ctx.capture_counter})
            ; ctx.capture_counter += 1;
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
                // Same rule as emitPipelineStep: a `-> T` step's result lives
                // under the call-site `: name` (return_binding), so the call
                // and its suppression reference ONE name.
                var alloc_result: ?[]const u8 = null;
                const current_result = if (!needs_result)
                    "_"
                else if (step.invocation.return_binding) |rb|
                    rb
                else blk2: {
                    alloc_result = try std.fmt.allocPrint(ctx.allocator, "{s}{}", .{ ctx.result_prefix, result_counter.* });
                    break :blk2 alloc_result.?;
                };
                defer if (alloc_result) |r| ctx.allocator.free(r);

                if (nested_inline_elig) |elig| {
                    try emitInlineEffectfulCall(
                        emitter,
                        ctx,
                        &step.invocation,
                        cont.continuations,
                        elig,
                        if (needs_result) current_result else null,
                    );
                } else {
                    try emitStep(emitter, ctx, step, current_result);
                }

                if (needs_result and !std.mem.eql(u8, current_result, "_")) {
                    try emitter.writeIndent();
                    try emitter.write("_ = &");
                    try writeBranchName(emitter, current_result);
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

                    try emitContinuationList(emitter, ctx, effective_continuations, last_result, result_counter, false, &inv.path, false);
                } else {
                    // No invocation in step, keep current source
                    try emitContinuationList(emitter, ctx, effective_continuations, last_result, result_counter, false, null, false);
                }
            }
        }
    }
}

/// Emit a single step in a pipeline
/// Fork/join: join every spawned task recorded on ctx — emitted before any
/// step that isn't itself a `[parallel]` invocation, so a spawned binding's
/// first reader (the produce, an unmarked call, a branch) sees the joined
/// value, never mid-flight.
fn drainParallelJoins(emitter: *CodeEmitter, ctx: *EmissionContext) !void {
    // waitAndWork, not wait: a pool worker that blocks on its join would
    // hold queued tasks nobody runs (all workers waiting = deadlock on a
    // recursive fork tree). Cooperative waiting lets the waiter drain the
    // queue itself — the standard fork/join requirement.
    for (ctx.pending_parallel.items) |wgvar| {
        try emitter.writeIndent();
        try emitter.write("if (__koru_par_pool_ready) __koru_par_pool.waitAndWork(&");
        try emitter.write(wgvar);
        try emitter.write(");\n");
    }
    ctx.pending_parallel.clearRetainingCapacity();
}

fn emitStep(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    step: *const ast.Step,
    result_var: []const u8,
) !void {
    // Fork/join: a pending spawn drains before any step that isn't itself a
    // marked invocation — marked steps keep the window open so sibling
    // binds overlap.
    const keep_open = step.* == .invocation and blk: {
        for (step.invocation.annotations) |ann| {
            if (std.mem.eql(u8, ann, "parallel")) break :blk true;
        }
        break :blk false;
    };
    if (!keep_open) try drainParallelJoins(emitter, ctx);
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
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

            // Emit if (condition) { steps }
            try emitter.writeIndent();
            try emitter.write("if (");

            // Emit condition (either string or expression)
            if (cb.condition_expr) |expr| {
                try emitExpression(emitter, ctx, expr, null);
            } else if (cb.condition) |cond| {
                const cond_out: []const u8 = blk: {
                    const alloc = emitter.allocator orelse break :blk cond;
                    const ev = ctx.impl_event_decl orelse break :blk cond;
                    break :blk (try presenceConditionRewrite(alloc, cond, ev, ctx.inline_fire_conts)) orelse cond;
                };
                try emitter.write(lowerExprZig(emitter, ctx, cond_out));
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
                    try writeBranchName(emitter, inner_result_var);
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
            try emitEnumOrStringField(emitter, ".source = ", canonicalNameToEnumTag, mb.source_event, is_transition);

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
            try emitter.writeIndent();
            try emitMetatypeBranchField(emitter, is_transition, mb.branch);

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
            try writeBranchName(emitter, mb.binding);
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
            // Simple label jump without arguments (e.g., @label) — the loop's
            // in-head call re-runs the handler from current state vars.
            try emitter.writeIndent();
            try emitter.write("continue :");
            try emitter.write(label_name);
            try emitter.write(";\n");
        },
        .label_jump => |*lj| {
            // Update state variables for the next iteration — the loop's
            // in-head call re-runs the handler from them.
            for (lj.args) |arg| {
                try emitter.writeIndent();
                try emitter.write(lj.label);
                try emitter.write("_");
                try writeBranchName(emitter, arg.name);
                try emitter.write(" = ");
                try emitValue(emitter, ctx, arg.value);
                try emitter.write(";\n");
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
        .expression => |code_raw| {
            // A Zig expression at body position. In a bare-return handler the
            // `->` produce IS the event's return value, so it lowers to
            // `return EXPR;` (020_025: `| big b -> b * 100`). A bare `_`
            // discard is never a produce, so it stays a discard even there.
            // In a generic context we discard the value to keep emission
            // well-formed. (The effect-branch-handler context has its own
            // override in emitHandlersStruct, where the expression becomes the
            // `return EXPR;` of the synthesized resume fn.)
            //
            // Spell it for this target first: this node IS a `->` body, and a
            // `->` body is raw Koru expression text.
            const code = lowerExprZig(emitter, ctx, code_raw);
            try emitter.writeIndent();
            if (ctx.bare_return_active and !std.mem.eql(u8, std.mem.trim(u8, code, " \t"), "_")) {
                try emitter.write("return ");
                if (!try writeRepackedRecordProduce(emitter, code, produceReturnType(ctx, null))) {
                    try emitter.write(code);
                }
                try emitter.write(";\n");
            } else if (try emitBranchProduce(emitter, ctx, code)) {
                // Handled: the produce named one of the implemented event's own
                // branches, so it lowered to a tagged return rather than a
                // discard. See emitBranchProduce.
            } else {
                try emitter.write("_ = ");
                try emitter.write(code);
                try emitter.write(";\n");
            }
        },
        .foreach => |fe| {
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

            // Emit for loop with proper AST body
            // Iterate over branches to find loop body (has @scope) vs post-loop branches
            var loop_branch: ?*const ast.NamedBranch = null;
            var post_loop_branches = std.ArrayListUnmanaged(*const ast.NamedBranch){};
            defer post_loop_branches.deinit(ctx.allocator);

            for (fe.branches) |*branch| {
                // Branch with @scope mark is the loop body (runs N times)
                const has_scope = for (branch.marks) |mark| {
                    if (std.mem.eql(u8, mark, "@scope")) break true;
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
            try writeBranchName(emitter, loop_binding);
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
                            try emitDiscardedResultRef(emitter, inner_result);
                        }
                        step_idx += 1;

                        // Handle nested continuations (e.g., | result r |> ...)
                        if (cont.continuations.len > 0) {
                            try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false, &node.invocation.path, false);
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
                            try emitDiscardedResultRef(emitter, inner_result);
                        }
                        step_idx += 1;

                        if (cont.continuations.len > 0) {
                            try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false, &node.invocation.path, false);
                        }
                    }
                }
            }
        },
        .conditional => |cond| {
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

            // Emit if/else with proper AST bodies
            const then_body = ast.NamedBranch.getBody(cond.branches, "then");
            const else_body = ast.NamedBranch.getBody(cond.branches, "else");

            try emitter.writeIndent();
            try emitter.write("if (");
            // Presence rewrite: a bare optional-arm name in the condition is a
            // comptime `@hasDecl(__H, ...)` presence test (400_146); on a required
            // arm it is the 400_150 wall. Resolved against the impl event.
            {
                const cond_out: []const u8 = blk: {
                    const alloc = emitter.allocator orelse break :blk cond.condition;
                    const ev = ctx.impl_event_decl orelse break :blk cond.condition;
                    break :blk (try presenceConditionRewrite(alloc, cond.condition, ev, ctx.inline_fire_conts)) orelse cond.condition;
                };
                try emitter.write(lowerExprZig(emitter, ctx, cond_out));
            }
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
                        try emitDiscardedResultRef(emitter, inner_result);
                    }
                    step_idx += 1;

                    if (cont.continuations.len > 0) {
                        try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false, if (node == .invocation) &node.invocation.path else null, false);
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
                            try emitDiscardedResultRef(emitter, inner_result);
                        }
                        step_idx += 1;

                        if (cont.continuations.len > 0) {
                            try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false, &node.invocation.path, false);
                        }
                    }
                }

                emitter.dedent();
                try emitter.writeIndent();
            }

            try emitter.write("}\n");
        },
        .switch_result => |sr| {
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

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
                            try emitDiscardedResultRef(emitter, inner_result);
                        }
                        step_idx += 1;

                        if (cont.continuations.len > 0) {
                            try emitContinuationList(emitter, ctx, cont.continuations, inner_result, &step_idx, false, &node.invocation.path, false);
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
            // SNAPSHOT SEMANTICS (ruled 2026-07-02, pinned 320_102): every
            // field expression reads the INCOMING accumulator state, then all
            // stores land — simultaneous assignment, so the meaning of a
            // `captured { }` literal cannot depend on its field order. All RHS
            // hoist into block-scoped temps before any store: the same loads
            // and stores as the sequential form, reordered; LLVM register-
            // allocates the temps — no copies, no extra work. Temps are
            // index-named (field names can be `arr[i]`) and the block scope
            // keeps repeated assignment nodes from colliding.
            // (continuation_codegen's whole-struct-literal form is snapshot
            // by construction; this partial-update form must match it.)
            if (asgn.fields.len > 1) {
                try emitter.writeIndent();
                try emitter.write("{\n");
                emitter.indent_level += 1;
                for (asgn.fields, 0..) |field, i| {
                    var name_buf: [32]u8 = undefined;
                    const tmp = try std.fmt.bufPrint(&name_buf, "__koru_asgn_{d}", .{i});
                    try emitter.writeIndent();
                    try emitter.write("const ");
                    try emitter.write(tmp);
                    try emitter.write(" = ");
                    if (field.expression_str) |expr| {
                        try emitter.write(lowerExprZig(emitter, ctx, expr));
                    } else {
                        try emitter.write(field.type);
                    }
                    try emitter.write(";\n");
                }
                for (asgn.fields, 0..) |field, i| {
                    var name_buf: [32]u8 = undefined;
                    const tmp = try std.fmt.bufPrint(&name_buf, "__koru_asgn_{d}", .{i});
                    try emitter.writeIndent();
                    try emitter.write(asgn.target);
                    try emitter.write(".");
                    try writeFieldRefName(emitter, field.name); // Can be "sum" or "arr[i]"
                    try emitter.write(" = ");
                    try emitter.write(tmp);
                    try emitter.write(";\n");
                }
                emitter.indent_level -= 1;
                try emitter.writeIndent();
                try emitter.write("}\n");
            } else for (asgn.fields) |field| {
                try emitter.writeIndent();
                try emitter.write(asgn.target);
                try emitter.write(".");
                try writeFieldRefName(emitter, field.name); // Can be "sum" or "arr[i]"
                try emitter.write(" = ");
                if (field.expression_str) |expr| {
                    try emitter.write(lowerExprZig(emitter, ctx, expr));
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
                try emitValueWithBindingSubstitution(emitter, ctx, arg.value, substitution);
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
                try writeBranchName(emitter, field.name);
                try emitter.write(" = ");
                const value = if (field.expression_str) |expr| expr else field.type;
                try emitValueWithBindingSubstitution(emitter, ctx, value, substitution);
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
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

            // Emit if (condition) { steps } with binding substitution
            try emitter.writeIndent();
            try emitter.write("if (");

            // Emit condition with binding substitution
            if (cb.condition_expr) |expr| {
                try emitExpression(emitter, ctx, expr, substitution);
            } else if (cb.condition) |cond| {
                try emitValueWithBindingSubstitution(emitter, ctx, lowerExprZig(emitter, ctx, cond), substitution);
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
                try emitValueWithBindingSubstitution(emitter, ctx, arg.value, substitution);
            }
            try emitter.write(" });\n");
        },
        .label_apply => |label_name| {
            // Simple label jump without arguments (e.g., @label) — the loop's
            // in-head call re-runs the handler from current state vars.
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
                try emitValueWithBindingSubstitution(emitter, ctx, arg.value, substitution);
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
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

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
            try emitValueWithBindingSubstitution(emitter, ctx, fe.iterable, substitution);
            try emitter.write(") |");
            try emitter.write(each_binding);
            try emitter.write("| {\n");
            emitter.indent();

            // Suppress unused capture warning
            try emitter.writeIndent();
            try emitter.write("_ = &");
            try writeBranchName(emitter, each_binding);
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
            // A `.terminal` inside a spliced sub-construct ends the nested
            // chain, not the enclosing label loop — only an arm-top-level
            // terminal may lower to `break :label` (320_171).
            const saved_label = ctx.current_label;
            ctx.current_label = null;
            defer ctx.current_label = saved_label;

            // Emit if/else with binding substitution
            const then_body = ast.NamedBranch.getBody(cond.branches, "then");
            const else_body = ast.NamedBranch.getBody(cond.branches, "else");

            try emitter.writeIndent();
            try emitter.write("if (");
            try emitValueWithBindingSubstitution(emitter, ctx, lowerExprZig(emitter, ctx, cond.condition), substitution);
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
pub fn emitBareReturnOutput(emitter: *CodeEmitter, event: *const ast.EventDecl, main_module_name: ?[]const u8) !bool {
    if (event.return_type) |rt| {
        // The parser lifts the return type's trailing `<phantom>` into the
        // separate `return_phantom` field, so writeBareReturnType never sees it
        // inline. Re-attach it here: a module-qualified phantom
        // (`-> *List_i64<std/list:list!>`) names the base type's home module,
        // which the bare-return path resolves for Output qualification
        // (660_027 — otherwise Output emits the undeclared bare base).
        var rt_out = rt;
        var rejoined: ?[]const u8 = null;
        if (event.return_phantom) |rp| {
            if (emitter.allocator) |a| {
                rejoined = std.fmt.allocPrint(a, "{s}<{s}>", .{ rt, rp }) catch null;
                if (rejoined) |b| rt_out = b;
            }
        }
        try emitter.write("pub const Output = ");
        try writeBareReturnType(emitter, rt_out, main_module_name, null);
        try emitter.write(";\n");
        return true;
    }
    return false;
}

fn isModuleLocalBareTypeBase(name: []const u8) bool {
    if (name.len == 0) return false;
    const scalars = [_][]const u8{
        "anytype", "bool",  "f16",   "f32",      "f64",    "f128", "i8",  "i16", "i32",
        "i64",     "i128",  "isize", "noreturn", "string", "u8",   "u16", "u32", "u64",
        "u128",    "usize", "void",
    };
    for (scalars) |scalar| {
        if (std.mem.eql(u8, name, scalar)) return false;
    }
    for (name, 0..) |ch, i| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) return false;
        if (i == 0 and !(ch >= 'A' and ch <= 'Z') and !(ch >= 'a' and ch <= 'z') and ch != '_') {
            return false;
        }
    }
    return true;
}

/// Write a bare-return `-> T` type as a Zig type. A record literal `{ f: T }`
/// shares Koru/Zig field syntax and only needs the Zig anon-struct keyword in
/// front: `struct { f: T }`. Scalars and slices pass through unchanged. Every
/// site that lowers a `return_type` to a Zig type routes through here.
/// `declaring_module` — when set (immediate-impl inline at an external call
/// site), unqualified module-local bases like `*String` lower to a qualified
/// Zig path (`*koru_std.koru_string.String`). Omitted when emitting handler
/// Output inside the declaring module's own struct.
pub fn writeBareReturnType(
    emitter: *CodeEmitter,
    rt: []const u8,
    main_module_name: ?[]const u8,
    declaring_module: ?[]const u8,
) !void {
    // A record-field value carries its phantom inline (`*Handle<owned!>`) because
    // the brace splitter is text-only, unlike an event-payload field whose parser
    // lifts the phantom into `field.phantom`. Koru surface types never use `<>`
    // for anything but a phantom (no language generics), so strip a `<...>` group
    // here — it is a compile-time-only annotation, absent from the Zig type. The
    // whole-value obligation is enforced separately (auto_discharge_inserter).
    // The stripped group's INNER text is kept: a module-qualified phantom on a
    // bare-return type names the base type's home module (resolved below), the
    // same resolution an event-payload field gets from its lifted `field.phantom`.
    var phantom_inner: ?[]const u8 = null;
    const phantom_stripped: []const u8 = if (std.mem.indexOfScalar(u8, rt, '<')) |lt| blk: {
        var depth: usize = 0;
        var end: ?usize = null;
        for (rt[lt..], lt..) |c, i| {
            if (c == '<') depth += 1 else if (c == '>') {
                depth -= 1;
                if (depth == 0) {
                    end = i;
                    break;
                }
            }
        }
        if (end) |e| {
            phantom_inner = rt[lt + 1 .. e];
            const a = emitter.allocator orelse std.heap.page_allocator;
            const joined = std.fmt.allocPrint(a, "{s}{s}", .{ rt[0..lt], rt[e + 1 ..] }) catch break :blk rt;
            break :blk joined;
        }
        break :blk rt;
    } else rt;
    const trimmed = std.mem.trim(u8, phantom_stripped, " \t");
    if (trimmed.len > 0 and trimmed[0] == '{') {
        // Record return shape `{ name: T, ... }`: emit a Zig struct with each
        // field type LOWERED (string → []const u8, module-qual → mangled path),
        // not pasted verbatim. Reuses the shared struct-literal splitter and
        // recurses, so nested records and qualified field types lower too.
        try emitRecordShapeStruct(emitter, trimmed, main_module_name, declaring_module, "koru: record return type passed the parser but failed parseFields");
        return;
    }

    // The canonical text type lowers through lowerZigType — bare `string` and
    // nested spellings alike (`[]string` → `[]const []const u8`, `?[]string`,
    // `[]const string`): the surface ban on raw byte slices (510_108) makes
    // `[]string` the only spelling a slice of text can have, and
    // `pub const Output = []string;` is a Zig syntax error
    // ('use of undeclared identifier string').
    const lowered = lowerZigType(trimmed);
    if (!std.mem.eql(u8, lowered, trimmed)) {
        try emitter.write(lowered);
        return;
    }
    // Compiler-provided AST types used as a BARE return live in the ast module,
    // aliased `__koru_ast` in the emitted backend (e.g. `ExplainReport` — the
    // explain-command ABI; `SiteResult` — the transform ABI). Param positions
    // qualify these via writeFieldType's ast_types list; the bare-return path
    // needs the same courtesy, or the reference is undeclared. Exact-match (not
    // substring) so a user type merely CONTAINING one of these names is untouched.
    const ast_return_types = [_][]const u8{
        "ExplainReport", "SiteResult", "Program",  "Item", "Source",
        "Invocation",    "EventDecl",  "ProcDecl", "Flow", "Branch",
        "Continuation",  "ASTNode",
    };
    for (ast_return_types) |t| {
        if (std.mem.eql(u8, trimmed, t)) {
            try emitter.write("__koru_ast.");
            try emitter.write(t);
            return;
        }
    }
    // Module-qualified scalar `mod/path:Type` must lower to the mangled Zig
    // module path (`koru_std.koru_compiler.CompilerContext`) — raw passthrough
    // of the `:` is a Zig syntax error. Pointer/slice prefixes sit in front of
    // the qualifier, so strip them first (mirrors writeQualifiedType).
    var remaining = trimmed;
    var prefix: []const u8 = "";
    const prefixes = [_][]const u8{ "[]const ", "[]", "?*const ", "?*", "*const ", "*", "?" };
    for (prefixes) |candidate| {
        if (std.mem.startsWith(u8, remaining, candidate)) {
            prefix = candidate;
            remaining = remaining[candidate.len..];
            break;
        }
    }
    // A bare base with an INLINE module-qualified phantom (`*List_i64<std/list:list!>`)
    // names its home module the same way an event-payload field's lifted phantom
    // does (writeFieldType → effective_module_path): qualify the base to the
    // phantom's module when the registry has evidence that module declares it.
    // Without this the emitted Output references the bare base name, undeclared
    // outside the home module (660_027: `pub const Output = *List_i64;`).
    // Takes PRECEDENCE over the declaring_module fallback below: an explicit
    // qualifier on the type beats whichever module happens to be writing it.
    if (phantom_inner) |pi| {
        if (std.mem.indexOfScalar(u8, pi, ':')) |pcolon| {
            const pmod = pi[0..pcolon];
            const pmod_ident = pmod.len > 0 and blk: {
                for (pmod) |ch| {
                    const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                        (ch >= '0' and ch <= '9') or ch == '/' or ch == '-' or ch == '_' or ch == '.';
                    if (!ok) break :blk false;
                }
                break :blk true;
            };
            if (pmod_ident and isModuleLocalBareTypeBase(remaining) and moduleDeclaresType(remaining, pmod)) {
                try emitter.write(prefix);
                try writeModulePath(emitter, pmod, main_module_name);
                try emitter.write(".");
                try emitter.write(remaining);
                return;
            }
        }
    }
    if (declaring_module) |mod_path| {
        if (isModuleLocalBareTypeBase(remaining)) {
            try writeQualifiedType(emitter, mod_path, main_module_name, trimmed);
            return;
        }
    }
    if (std.mem.indexOfScalar(u8, remaining, ':')) |colon| {
        // Only an identifier-shaped segment before the `:` is a module
        // qualifier. A sentinel slice (`[][:0]u8` → remaining `[:0]u8`) also
        // carries a colon — that is Zig type syntax, not a qualifier, and
        // must pass through verbatim.
        const qual = remaining[0..colon];
        const is_module_qual = qual.len > 0 and blk: {
            for (qual) |ch| {
                const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                    (ch >= '0' and ch <= '9') or ch == '/' or ch == '-' or ch == '_' or ch == '.';
                if (!ok) break :blk false;
            }
            break :blk true;
        };
        if (is_module_qual) {
            try emitter.write(prefix);
            try writeModulePath(emitter, qual, main_module_name);
            try emitter.write(".");
            try emitter.write(remaining[colon + 1 ..]);
            return;
        }
    }
    // Same host-home routing writeFieldType uses for payload fields — with the
    // same MODULE-LOCAL FIRST order: when the module being emitted declares the
    // bare base itself (KORU115-legal), its own declaration names the emitted
    // home; the first-wins homes map stays only as the fallback for positions
    // the scope checker does not see.
    if (isModuleLocalBareTypeBase(remaining)) {
        if (writerDeclaresType(remaining)) {
            if (current_writer_module) |writer| {
                if (writer.len > 0) {
                    try emitter.write(prefix);
                    try writeModulePath(emitter, writer, main_module_name);
                    try emitter.write(".");
                    try emitter.write(remaining);
                    return;
                }
            }
            // Top-level writer: file-scope declarations stay bare, as a
            // first-wins "" home did.
        } else if (host_type_homes) |homes| {
            if (homes.get(remaining)) |home| {
                if (home.len > 0) {
                    try emitter.write(prefix);
                    try writeModulePath(emitter, home, main_module_name);
                    try emitter.write(".");
                    try emitter.write(remaining);
                    return;
                }
            }
        }
    }
    // Emit the PHANTOM-STRIPPED, trimmed form — not the original `rt`. A record
    // field recursion arrives here with a per-field value like `*Handle<owned!>`;
    // writing the raw `rt` would leak the compile-time-only `<owned!>` phantom
    // into the generated Zig (a syntax error), which the top-level single strip
    // only masks for a record's FIRST phantom-bearing field (challenge 007:
    // multi-obligation records `{ h!, g! }`).
    try writeTypeNameQuoted(emitter, trimmed);
}

/// `pv` is an identifier path (`r`, `outer.inner`)? The bare-return record
/// repack applies only to these — a call or computed expression in the
/// produce slot would be evaluated once per field if repacked, duplicating
/// side effects.
fn isIdentPath(s: []const u8) bool {
    if (s.len == 0) return false;
    var need_start = true;
    for (s) |c| {
        if (c == '.') {
            if (need_start) return false;
            need_start = true;
            continue;
        }
        const alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        const digit = c >= '0' and c <= '9';
        if (need_start and !alpha) return false;
        if (!alpha and !digit) return false;
        need_start = false;
    }
    return !need_start;
}

/// Emit `.{ .f = <pv>.f, ... }` — the fieldwise repack of a non-literal
/// record produce into the enclosing tor's declared `-> {record}` Output —
/// when `return_type` is a record shape and `pv` is a bare identifier path.
/// Returns true when it wrote the repack, false when the produce does not
/// qualify (scalar return, literal produce, computed expression) — callers
/// then lower `pv` through emitValue as before.
///
/// Why the repack exists: a produce `-> r` yields r's OWN anonymous struct
/// type (`__koru_handler_impl__struct_N`), while the fn's result type is the
/// tor's `Output` — two `struct { f: T }` declarations are distinct types
/// in Zig even when identical in shape, so `return r;` refuses with
/// "expected type 'X.Output', found 'Y.struct_N'" (the producing-`if`
/// frontier 800_010 surfaced). The literal produce `-> { a, b }` never hit
/// this — the `.{ }` literal coerces at the result location.
fn writeRepackedRecordProduce(
    emitter: *CodeEmitter,
    pv: []const u8,
    return_type: ?[]const u8,
) !bool {
    const rt_raw = return_type orelse return false;
    const rt = std.mem.trim(u8, rt_raw, " \t");
    if (rt.len == 0 or rt[0] != '{') return false;
    const pv_t = std.mem.trim(u8, pv, " \t");
    if (!isIdentPath(pv_t) or std.mem.eql(u8, pv_t, "_")) return false;
    const a = emitter.allocator orelse std.heap.page_allocator;
    const fields = struct_literal.parseFields(a, rt) catch return false;
    if (fields.len == 0) return false;
    try emitter.write(".{");
    for (fields, 0..) |f, i| {
        if (i > 0) try emitter.write(",");
        try emitter.write(" .");
        try writeBranchName(emitter, f.name);
        try emitter.write(" = ");
        try emitter.write(pv_t);
        try emitter.write(".");
        try writeBranchName(emitter, f.name);
    }
    try emitter.write(" }");
    return true;
}

/// The record return type a bare `-> expr` produce must land in: explicit
/// override first (call sites holding the EventDecl/EventType in hand), else
/// the armed produce context.
fn produceReturnType(ctx: *EmissionContext, override: ?[]const u8) ?[]const u8 {
    if (override) |t| return t;
    const decl = ctx.produce_event orelse ctx.impl_event_decl orelse return null;
    return decl.return_type;
}

/// Emit a `-> <expr>` produce: repack into the declared record shape when it
/// applies, else lower the expression through emitValue.
pub fn emitBareReturnProduce(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    pv: []const u8,
    return_type: ?[]const u8,
) !void {
    if (try writeRepackedRecordProduce(emitter, pv, produceReturnType(ctx, return_type))) return;
    try emitValue(emitter, ctx, pv);
}

/// Emit `.{ .<branch> = <payload> }` (or the bare `-> T` value) for a
/// branch constructor, resolving `[...]` literals against the branch's
/// declared field types via `find_field(target, branch_name, field_name)`.
/// `target` is whatever the lookup needs — an `EventType` for registry
/// sites or an `EventDecl` where the decl is in hand.
/// `bare_return_type` is the declared `-> T` the produce lands in — the
/// tor's return_type from whichever form the caller holds.
fn emitBranchConstructorWithLookup(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    target: anytype,
    comptime find_field: anytype,
    bare_return_type: ?[]const u8,
) EmitError!void {
    if (bc.is_bare_return) {
        if (bc.plain_value) |pv| {
            try emitBareReturnProduce(emitter, ctx, pv, bare_return_type);
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
            if (find_field(target, bc.branch_name, null)) |field| {
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
            try writeBranchName(emitter, field.name);
            try emitter.write(" = ");
            const value = if (field.expression_str) |expr| expr else field.type;
            const trimmed = std.mem.trim(u8, value, " \t");
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                if (find_field(target, bc.branch_name, field.name)) |branch_field| {
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

fn emitBranchConstructorWithEventType(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    event_type: type_registry_module.EventType,
) EmitError!void {
    return emitBranchConstructorWithLookup(emitter, ctx, bc, event_type, findBranchFieldForEventType, event_type.return_type);
}

fn emitBranchConstructorWithEvent(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    bc: *const ast.BranchConstructor,
    event: *const ast.EventDecl,
) EmitError!void {
    return emitBranchConstructorWithLookup(emitter, ctx, bc, event, findBranchFieldForEvent, event.return_type);
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
            try emitBareReturnProduce(emitter, ctx, pv, null);
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
            try writeBranchName(emitter, field.name);
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
            .expression => |expr| {
                // A bare return in CONTINUATION position (`| done r -> r`) is an
                // `.expression`, not a `.branch_constructor` — the latter is the
                // implementation-side spelling (`~tor f -> expr`). Without this
                // case the arm's own payload reads as unused, the capture is
                // emitted as `_`, and the body then references the name that was
                // just discarded (210_166). The flow checker's twin,
                // `nodeUsesBinding`, has always had this case.
                if (containsIdentifier(expr, binding)) {
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

/// Registry-harvested event shapes carry bare type names legal only inside
/// the event's declaring module (KORU115), but the descriptor emits into a
/// test module where those names are undeclared — so default a bare base to
/// the event's own module (`*Judge` under `koru/odds:feels` ->
/// `*koru_koru.koru_odds.Judge`). An explicit field.module_path or a
/// phantom-derived home still wins (base-type vs phantom-state orthogonality);
/// scalars, `string`, and already-qualified bases pass through unchanged.
fn writeEventShapeFieldType(
    code_emitter: *CodeEmitter,
    field: ast.Field,
    main_module_name: ?[]const u8,
    event_module: ?[]const u8,
) !void {
    if (event_module != null and field.module_path == null) {
        var phantom_home: ?[]const u8 = null;
        if (field.phantom) |ph| {
            if (std.mem.indexOfScalar(u8, ph, ':')) |colon| {
                const pmod = ph[0..colon];
                if (pmod.len > 0 and phantomModuleIsTypeHome(field.type, pmod)) {
                    phantom_home = pmod;
                }
            }
        }
        if (phantom_home == null) {
            if (isModuleLocalBareTypeBase(stripTypePrefixes(field.type))) {
                var patched = field;
                patched.module_path = event_module;
                try writeFieldType(code_emitter, patched, main_module_name);
                return;
            }
        }
    }
    try writeFieldType(code_emitter, field, main_module_name);
}

fn emitEventDeclForModuleFromType(
    code_emitter: *CodeEmitter,
    ctx: *EmissionContext,
    event_path: *const ast.DottedPath,
    event_type: type_registry_module.EventType,
    immediate_impl: *const ast.ImmediateImpl,
) !void {
    const event_module = event_path.module_qualifier;
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
            try writeEventShapeFieldType(code_emitter, field, ctx.main_module_name, event_module);
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
        try writeBareReturnType(code_emitter, rt, ctx.main_module_name, event_module);
        try code_emitter.write(";\n");
    } else if (event_type.branches.len == 0) {
        try code_emitter.write("pub const Output = void;\n");
    } else {
        try code_emitter.write(if (event_type.branches.len <= 256) "pub const Output = union(enum(u8)) {\n" else "pub const Output = union(enum) {\n");
        code_emitter.indent_level += 1;
        for (event_type.branches) |branch| {
            try code_emitter.writeIndent();
            try writeBranchName(code_emitter, branch.name);

            if (branch.payload) |payload| {
                if (payload.fields.len == 1 and std.mem.eql(u8, payload.fields[0].name, "__type_ref")) {
                    try code_emitter.write(": ");
                    try writeEventShapeFieldType(code_emitter, payload.fields[0], ctx.main_module_name, event_module);
                    try code_emitter.write(",\n");
                } else {
                    try code_emitter.write(": struct {\n");
                    code_emitter.indent_level += 1;
                    for (payload.fields) |field| {
                        try code_emitter.writeIndent();
                        try writeBranchName(code_emitter, field.name);
                        try code_emitter.write(": ");
                        try writeEventShapeFieldType(code_emitter, field, ctx.main_module_name, event_module);
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
    try code_emitter.write("pub fn handler(__koru_event_input: @This().Input) @This().Output {\n");
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

    // ImmediateImpl always has a value (BranchConstructor) - emit it directly.
    // Register the field names so escapeBoundNames rewrites kebab/keyword
    // references (`x-y` → `x_y`); there is no EventDecl here for the ctx to
    // carry, so the names go through zig_scope_bindings instead.
    {
        const prev_scope_len = ctx.zig_scope_bindings.items.len;
        defer while (ctx.zig_scope_bindings.items.len > prev_scope_len) {
            const popped = ctx.zig_scope_bindings.pop() orelse break;
            ctx.allocator.free(popped);
        };
        if (event_type.input_shape) |shape| {
            for (shape.fields) |field| {
                if (!codegen_utils.hasKebab(field.name) and !codegen_utils.needsEscaping(field.name)) continue;
                try ctx.zig_scope_bindings.append(ctx.allocator, try ctx.allocator.dupe(u8, field.name));
            }
        }
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

/// True if a child continuation bare-return-produces the parent invocation's
/// `: bind` unchanged — `f(...): v -> v` — the single-return-form twin of the
/// `| B v => B v` passthrough. The binding lives on the INVOCATION
/// (return_binding), not on the child, so this can't ride on
/// `identityForwardsResult`'s cont.binding check.
fn bareReturnForwardsBinding(cont: *const ast.Continuation, return_binding: ?[]const u8) bool {
    const rb = return_binding orelse return false;
    if (cont.node == null) return false;
    if (cont.node.? != .branch_constructor) return false;
    const bc = cont.node.?.branch_constructor;
    if (!bc.is_bare_return) return false;
    const pv = bc.plain_value orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, pv, " \t"), rb);
}

/// True if `cont` is a tail-forwarder: its node is an event invocation and every
/// child continuation forwards the result branch unchanged (so the call's result
/// IS this invocation's result) — either the tagged `| B v => B v` passthrough
/// or the bare-return `: v -> v` produce. The invocation TARGET is not
/// constrained here — this is the shared shape check behind both the self-loop
/// (target == the event itself) and the mutual-group (target == any group
/// member) lowerings.
fn isTailForwarder(cont: *const ast.Continuation) bool {
    if (cont.node == null) return false;
    if (cont.node.? != .invocation) return false;
    if (cont.continuations.len == 0) return false;
    const rb = cont.node.?.invocation.return_binding;
    for (cont.continuations) |*child| {
        if (!identityForwardsResult(child) and !bareReturnForwardsBinding(child, rb)) return false;
    }
    return true;
}

/// True if `cont` is a tail self-continuation of `event_canonical`: a
/// tail-forwarder whose invocation targets that same event (the precondition for
/// a sound self-loop rewrite).
fn continuationIsSelfTailForwarder(
    cont: *const ast.Continuation,
    event_canonical: []const u8,
    ctx: *EmissionContext,
) bool {
    if (!isTailForwarder(cont)) return false;
    const inv = cont.node.?.invocation;
    const inv_canonical = buildCanonicalEventName(&inv.path, ctx.allocator, ctx.main_module_name) catch return false;
    defer ctx.allocator.free(inv_canonical);
    return std.mem.eql(u8, inv_canonical, event_canonical);
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

/// Emit the input-field reassignments for a tail-call reentry. Each input field
/// is reassigned from the corresponding invocation arg (pass-through args where
/// `value == name` are skipped — they're already correct and emitting `x = x`
/// would just copy the array for nothing). Shared by the self-loop and
/// mutual-group reentries; the caller emits the `continue` (and, for mutual, the
/// `__koru_fn = .<target>;` dispatch-state update) around it.
fn emitTailReargs(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    inv: *const ast.Invocation,
) !void {
    // SNAPSHOT / SIMULTANEOUS ASSIGNMENT (same defect + fix as captured{},
    // ruled 2026-07-02, pinned 320_102 & 320_121): a tail reentry reassigns the
    // loop's `var` bindings. Emitted sequentially, a later arg's RHS reads an
    // EARLIER binding that was already stored — e.g. gcd's `a = b; b = @mod(a, b);`
    // reads the new `a`, and nestedloop's `k = k - 1; acc = ... k` reads the
    // decremented `k`. Silent wrong answers. Stage every reassigned RHS into a
    // block-scoped temp against the INCOMING state, then store — LLVM register-
    // allocates the temps (no copies). No-op pass-throughs (`x: x`) need neither
    // store nor staging. SHARED by the self-loop AND mutual-group reentries, so
    // the simultaneous fix covers the mutual multi-arg path too.
    var n_reassign: usize = 0;
    for (inv.args) |arg| {
        const trimmed = std.mem.trim(u8, arg.value, " \t");
        if (std.mem.eql(u8, trimmed, arg.name)) continue;
        n_reassign += 1;
    }
    if (n_reassign > 1) {
        try emitter.writeIndent();
        try emitter.write("{\n");
        emitter.indent_level += 1;
        var i: usize = 0;
        for (inv.args) |arg| {
            const trimmed = std.mem.trim(u8, arg.value, " \t");
            if (std.mem.eql(u8, trimmed, arg.name)) continue;
            var name_buf: [40]u8 = undefined;
            const tmp = try std.fmt.bufPrint(&name_buf, "__koru_reentry_{d}", .{i});
            try emitter.writeIndent();
            try emitter.write("const ");
            try emitter.write(tmp);
            try emitter.write(" = ");
            try emitValue(emitter, ctx, arg.value);
            try emitter.write(";\n");
            i += 1;
        }
        i = 0;
        for (inv.args) |arg| {
            const trimmed = std.mem.trim(u8, arg.value, " \t");
            if (std.mem.eql(u8, trimmed, arg.name)) continue;
            var name_buf: [40]u8 = undefined;
            const tmp = try std.fmt.bufPrint(&name_buf, "__koru_reentry_{d}", .{i});
            try emitter.writeIndent();
            try writeBranchName(emitter, arg.name);
            try emitter.write(" = ");
            try emitter.write(tmp);
            try emitter.write(";\n");
            i += 1;
        }
        emitter.indent_level -= 1;
        try emitter.writeIndent();
        try emitter.write("}\n");
    } else {
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
    }
}

/// Emit the reassign+continue that replaces a tail self-call site, then
/// `continue :label` re-enters the loop top.
fn emitSelfTailReentry(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
) !void {
    try emitTailReargs(emitter, ctx, &cont.node.?.invocation);
    try emitter.writeIndent();
    try emitter.write("continue :");
    try emitter.write(ctx.self_loop_label);
    try emitter.write(";\n");
}

/// Emit the reassign + continue that replaces a mutual tail-forward to another
/// group member G: `<reassign args>; continue :label .<G>;`. The combined loop
/// is a LABELED SWITCH, so the continue operand jumps directly to G's arm —
/// no dispatch-state variable, no per-step re-dispatch (that state-var form
/// benched 1.38x slower on the mutual kernel).
fn emitMutualTailReentry(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    cont: *const ast.Continuation,
    tag: []const u8,
) !void {
    try emitTailReargs(emitter, ctx, &cont.node.?.invocation);
    try emitter.writeIndent();
    try emitter.write("continue :");
    try emitter.write(ctx.self_loop_label);
    try emitter.write(" .");
    try emitter.write(tag);
    try emitter.write(";\n");
}

/// True if all of `a`'s and `b`'s input fields match by name and type (order
/// included). The mutual-group loop declares ONE set of `var` input bindings
/// shared by every member arm, so members must have identical input shape.
fn inputShapesMatch(a: *const ast.EventDecl, b: *const ast.EventDecl) bool {
    if (a.input.fields.len != b.input.fields.len) return false;
    for (a.input.fields, b.input.fields) |fa, fb| {
        if (!std.mem.eql(u8, fa.name, fb.name)) return false;
        if (!std.mem.eql(u8, fa.type, fb.type)) return false;
    }
    return true;
}

// ═══════════════════════════════════════════════════════════════════════════
// FLAT CONTINUATION EMISSION — explicit-lane chained recursion.
//
// A non-tail self-call `f(args): r` whose resumption eventually re-enters the
// same event in tail position (ackermann/hanoi/tak) pays a native stack frame
// per live level — ~8 memory ops and a link-register round trip each. When
// every non-tail self-call in the flow chains that way, the whole handler
// lowers to a flat `while (true)` over `var` inputs: a call stores a
// continuation frame (the scalars its resumption reads, plus a tag) on
// `__koru_cstk`, reargs, and continues the loop; a produce stores the result
// and runs a deliver switch that pops frames and resumes continuations. Same
// mechanism as the self-tail reentry, extended to non-tail calls: the
// continuation is data, not a return address. Measured on the flat-cont spike:
// ackermann ~5x, tak ~12x, hanoi ~1.35x vs native-stack emission.
//
// Combining recursion (fib's `-> a + b`) does NOT qualify — its resumptions
// never re-enter, the native stack already wins there, and an indirect
// dispatch on every leaf return loses to the hardware return-address
// predictor. Shapes the predicate does not fully cover keep the existing
// structured emission: ineligible is a miss, never a misemit.
//
// Frame layout is variable-width, tag on top: [live_0 .. live_{L-1}][tag].
// The deliver loop pops the tag at csp-1; each arm statically knows its own
// L, reads its live words from csp-L, then consumes the whole frame before
// resumption code may push the next one — the lane-consumption rule the
// flat-cont spike pinned (a resumption that leaves its lane live is popped
// again forever).
// ═══════════════════════════════════════════════════════════════════════════

/// One registered continuation site: the resumption to run when the deliver
/// switch pops this tag. `scope` is the bind names in scope at registration
/// (ancestors only — the site's own rb arrives via `__koru_res`, not the lane).
const FlatResumption = struct {
    children: []const ast.Continuation,
    return_binding: ?[]const u8,
    live: []const []const u8,
    scope: []const []const u8,
};

const FlatEmitState = struct {
    resumptions: std.ArrayList(FlatResumption) = .empty,
    self_canonical: []const u8,
    fields: []const ast.Field,
    return_type: []const u8,
    n_regs: usize,
    /// Uniform lane width in u64 words: 1 fid + the widest live set. Every
    /// lane occupies the same span so `sp` walks a fixed stride — measured
    /// ~25% faster than variable-width frames (LLVM folds the push chain into
    /// counted stores instead of per-site pointer arithmetic).
    lane_words: usize = 0,
    /// Next resumption the emit walk consumes — sites are pre-registered in
    /// worklist order by flatRegisterSites so lane_words is known up front.
    next_site: usize = 0,
};

/// Lane-scalar types: values of these types travel through `__koru_cstk` as
/// bitcast u64 words.
fn flatScalarType(ty: []const u8) bool {
    const scalars = [_][]const u8{ "i64", "u64", "isize", "usize" };
    for (scalars) |s| {
        if (std.mem.eql(u8, ty, s)) return true;
    }
    return false;
}

/// True if `field` can ride a continuation lane: a plain machine-word scalar
/// with no capture semantics attached.
fn flatFieldLaneable(field: ast.Field) bool {
    if (field.is_source or field.is_file or field.is_embed_file or
        field.is_expression or field.is_invocation_meta) return false;
    if (field.phantom != null or field.module_path != null) return false;
    return flatScalarType(field.type);
}

/// `if`-template invocation: a one-arg call to an event literally named `if`
/// whose invocation carried a rendered Zig template — the only non-self
/// invocation the flat walk lowers.
fn flatIsIfInvocation(inv: *const ast.Invocation) bool {
    if (inv.path.segments.len == 0 or inv.args.len != 1) return false;
    return std.mem.eql(u8, inv.path.segments[inv.path.segments.len - 1], "if");
}

fn flatTargetsSelf(inv: *const ast.Invocation, self_canonical: []const u8, ctx: *EmissionContext) bool {
    const canonical = buildCanonicalEventName(&inv.path, ctx.allocator, ctx.main_module_name) catch return false;
    defer ctx.allocator.free(canonical);
    return std.mem.eql(u8, canonical, self_canonical);
}

/// Does this continuation subtree hold a tail self-forward anywhere? The
/// chained-shape test applied to a non-tail self-call's resumption.
fn flatContsContainSelfTailForward(conts: []const ast.Continuation, self_canonical: []const u8, ctx: *EmissionContext) bool {
    for (conts) |*cont| {
        if (continuationIsSelfTailForwarder(cont, self_canonical, ctx)) return true;
        if (flatContsContainSelfTailForward(cont.continuations, self_canonical, ctx)) return true;
    }
    return false;
}

fn flatIsIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Word-boundary name scan over raw Koru expression text — the read test for
/// live-value computation. Over-inclusion is safe (a stored word is simply
/// restored); under-inclusion is the bug this guards against.
fn flatTextMentionsName(text: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |p| {
        const left_ok = p == 0 or !flatIsIdentChar(text[p - 1]);
        const right = p + name.len;
        const right_ok = right >= text.len or !flatIsIdentChar(text[right]);
        if (left_ok and right_ok) return true;
        pos = p + 1;
    }
    return false;
}

/// Any text slot in this continuation subtree (call args, produce bodies,
/// branch-payload expressions) that can read a local name.
fn flatContsMentionName(conts: []const ast.Continuation, name: []const u8) bool {
    for (conts) |*cont| {
        if (cont.node) |*node| {
            switch (node.*) {
                .invocation => |*inv| {
                    for (inv.args) |arg| {
                        if (flatTextMentionsName(arg.value, name)) return true;
                    }
                },
                .expression => |code| {
                    if (flatTextMentionsName(code, name)) return true;
                },
                .branch_constructor => |*bc| {
                    if (bc.plain_value) |pv| {
                        if (flatTextMentionsName(pv, name)) return true;
                    }
                    for (bc.fields) |f| {
                        if (f.expression_str) |es| {
                            if (flatTextMentionsName(es, name)) return true;
                        }
                        if (flatTextMentionsName(f.type, name)) return true;
                    }
                },
                else => {},
            }
        }
        if (flatContsMentionName(cont.continuations, name)) return true;
    }
    return false;
}

/// Names the segment emission reserves: the lane pointer (`sp`, `lw`), the
/// register params (`r0`, `r1`, …), and the `__koru_` internal prefix. A field
/// or bind carrying one would shadow the segment machinery it sits inside.
fn flatNameReserved(name: []const u8) bool {
    if (std.mem.eql(u8, name, "sp") or std.mem.eql(u8, name, "lw")) return true;
    if (std.mem.startsWith(u8, name, "__koru_")) return true;
    if (name.len >= 2 and name[0] == 'r') {
        var all_digits = true;
        for (name[1..]) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return true;
    }
    return false;
}

/// Collect every call-site result binding in the subtree (deduped, `_`
/// skipped). Returns false when a bind name collides with an input field or
/// a reserved segment name — a shadow the emission cannot represent.
fn flatCollectBinds(
    conts: []const ast.Continuation,
    fields: []const ast.Field,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !bool {
    for (conts) |*cont| {
        if (cont.node) |*node| {
            if (node.* == .invocation) {
                if (node.invocation.return_binding) |rb| {
                    if (!std.mem.eql(u8, rb, "_")) {
                        if (flatNameReserved(rb)) return false;
                        for (fields) |f| {
                            if (std.mem.eql(u8, f.name, rb)) return false;
                        }
                        var dup = false;
                        for (out.items) |n| {
                            if (std.mem.eql(u8, n, rb)) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) try out.append(allocator, rb);
                    }
                }
            }
        }
        if (!try flatCollectBinds(cont.continuations, fields, out, allocator)) return false;
    }
    return true;
}

/// The conservative shape gate. Every node in the subtree must be one the
/// flat walk lowers: a terminal produce, a bare `-> T` branch constructor, a
/// self-call (tail-forwarder or chained non-tail), or an `if` template whose
/// arms are `then`/`else` only. Every non-tail self-call must be CHAINED —
/// its resumption contains a tail self-forward — which is what keeps
//  combining shapes (fib, coins, pascal) on the native path.
fn flatContsEligible(
    conts: []const ast.Continuation,
    self_canonical: []const u8,
    ctx: *EmissionContext,
    any_chained: *bool,
) bool {
    for (conts) |*cont| {
        if (cont.binding != null or cont.destructure.len != 0 or
            cont.is_catchall or cont.condition != null or
            cont.condition_expr != null or cont.is_transformed_subtree) return false;
        const node = cont.node orelse {
            if (!flatContsEligible(cont.continuations, self_canonical, ctx, any_chained)) return false;
            continue;
        };
        switch (node) {
            .expression => |code| {
                if (cont.continuations.len != 0) return false;
                if (std.mem.eql(u8, std.mem.trim(u8, code, " \t"), "_")) return false;
            },
            .branch_constructor => |bc| {
                if (!bc.is_bare_return or bc.plain_value == null) return false;
                if (cont.continuations.len != 0) return false;
            },
            .invocation => |*inv| {
                if (inv.return_destructure.len != 0) return false;
                if (flatTargetsSelf(inv, self_canonical, ctx)) {
                    if (isTailForwarder(cont)) {
                        // Reentry replaces the whole cont — its identity
                        // forwarder children are never walked.
                        continue;
                    }
                    if (!flatContsContainSelfTailForward(cont.continuations, self_canonical, ctx)) return false;
                    any_chained.* = true;
                    if (!flatContsEligible(cont.continuations, self_canonical, ctx, any_chained)) return false;
                } else if (flatIsIfInvocation(inv) and inv.inline_body != null) {
                    if (inv.return_binding != null) return false;
                    for (cont.continuations) |*arm| {
                        if (!std.mem.eql(u8, arm.branch, "then") and !std.mem.eql(u8, arm.branch, "else")) return false;
                    }
                    if (!flatContsEligible(cont.continuations, self_canonical, ctx, any_chained)) return false;
                } else return false;
            },
            else => return false,
        }
    }
    return true;
}

/// Is this impl flow a flat-emission candidate? An `if`-headed single-return
/// flow over lane-scalar inputs where every non-tail self-call is chained and
/// at least one exists — the shape where an explicit lane beats the native
/// stack by a measured multiple.
pub fn flowIsFlatEligible(
    event: *const ast.EventDecl,
    flow: *const ast.Flow,
    self_canonical: []const u8,
    ctx: *EmissionContext,
) bool {
    if (flow.preamble_code != null or flow.pre_label != null) return false;
    const head = flow.inv();
    if (findEffectArm(event, &head.path) != null) return false;
    if (!flatIsIfInvocation(head)) return false;
    if ((flow.inline_body orelse head.inline_body) == null) return false;
    if (head.return_binding != null or head.return_destructure.len != 0) return false;
    if (event.input.fields.len == 0) return false;
    const rt = event.return_type orelse return false;
    if (!flatScalarType(rt)) return false;
    for (event.input.fields) |f| {
        if (!flatFieldLaneable(f)) return false;
        if (flatNameReserved(f.name)) return false;
    }
    var binds: std.ArrayList([]const u8) = .empty;
    defer binds.deinit(ctx.allocator);
    if (!(flatCollectBinds(flow.body.continuations, event.input.fields, &binds, ctx.allocator) catch return false)) return false;
    for (flow.body.continuations) |*cont| {
        if (!std.mem.eql(u8, cont.branch, "then") and !std.mem.eql(u8, cont.branch, "else")) return false;
    }
    var any_chained = false;
    if (!flatContsEligible(flow.body.continuations, self_canonical, ctx, &any_chained)) return false;
    return any_chained;
}

/// File-scope scan for the lane-stack decls: does any impl flow in this
/// module qualify for flat emission?
pub fn moduleNeedsFlatLaneStack(items: []const ast.Item, allocator: std.mem.Allocator, main_module_name: ?[]const u8) bool {
    var ctx = EmissionContext{
        .allocator = allocator,
        .main_module_name = main_module_name,
    };
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                const impl_path = flow.impl_of orelse continue;
                if (flow.impl_variant != null) continue;
                const event = findEventDeclByPath(items, &impl_path) orelse continue;
                const canonical = buildCanonicalEventName(&event.path, allocator, main_module_name) catch continue;
                defer allocator.free(canonical);
                if (flowIsFlatEligible(event, flow, canonical, &ctx)) return true;
            },
            else => continue,
        }
    }
    return false;
}

/// The lane type for a live name: an input field's own type, or the event's
/// bare-return type for a call-result bind.
fn flatLaneType(fx: *const FlatEmitState, name: []const u8) []const u8 {
    for (fx.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    return fx.return_type;
}

/// The scalars a chained call site must save: fields and in-scope binds the
/// resumption's subtree mentions, minus the site's own result binding (that
/// value arrives through r0, not the lane).
fn flatComputeLive(
    fx: *const FlatEmitState,
    inv: *const ast.Invocation,
    resumption_conts: []const ast.Continuation,
    scope: []const []const u8,
    allocator: std.mem.Allocator,
) EmitError![][]const u8 {
    var live: std.ArrayList([]const u8) = .empty;
    for (fx.fields) |f| {
        if (inv.return_binding) |rb| {
            if (std.mem.eql(u8, f.name, rb)) continue;
        }
        if (flatContsMentionName(resumption_conts, f.name)) try live.append(allocator, f.name);
    }
    for (scope) |b| {
        if (inv.return_binding) |rb| {
            if (std.mem.eql(u8, b, rb)) continue;
        }
        var dup = false;
        for (live.items) |n| {
            if (std.mem.eql(u8, n, b)) {
                dup = true;
                break;
            }
        }
        if (!dup and flatContsMentionName(resumption_conts, b)) try live.append(allocator, b);
    }
    return live.toOwnedSlice(allocator);
}

/// Register one chained call site's resumption and record the scope its
/// segment body runs under (the site's own bind joins the inherited scope —
/// it arrives through r0 inside the segment).
fn flatRegisterSite(
    fx: *FlatEmitState,
    ctx: *EmissionContext,
    inv: *const ast.Invocation,
    conts: []const ast.Continuation,
    scope: []const []const u8,
) EmitError!void {
    try fx.resumptions.append(ctx.allocator, .{
        .children = conts,
        .return_binding = inv.return_binding,
        .live = try flatComputeLive(fx, inv, conts, scope, ctx.allocator),
        .scope = try ctx.allocator.dupe([]const u8, scope),
    });
}

/// Site-collection walk, mirroring emitFlatSegConts node-for-node in the same
/// order the emit walk consumes tags: non-node continuations recurse in order,
/// `if` invocations walk then-arms before else-arms, tail self-forwarders are
/// skipped (their children never run), and a chained non-tail self-call
/// registers itself — its resumption is a separate segment body reached by
/// flatRegisterSites' worklist, not this walk. Running this before any
/// emission populates `fx.resumptions`, which fixes the uniform lane width
/// ahead of the eval segment.
fn flatWalkSites(
    fx: *FlatEmitState,
    ctx: *EmissionContext,
    conts: []const ast.Continuation,
    scope: []const []const u8,
) EmitError!void {
    for (conts) |*cont| {
        const node = cont.node orelse {
            try flatWalkSites(fx, ctx, cont.continuations, scope);
            continue;
        };
        switch (node) {
            .invocation => |*inv| {
                if (flatTargetsSelf(inv, fx.self_canonical, ctx)) {
                    if (isTailForwarder(cont)) continue;
                    // The resumption is a separate segment body — its sites are
                    // reached by flatRegisterSites' worklist, not this walk.
                    try flatRegisterSite(fx, ctx, inv, cont.continuations, scope);
                } else if (flatIsIfInvocation(inv) and inv.inline_body != null) {
                    for (cont.continuations, 0..) |*arm, i| {
                        if (std.mem.eql(u8, arm.branch, "then")) try flatWalkSites(fx, ctx, cont.continuations[i .. i + 1], scope);
                    }
                    for (cont.continuations, 0..) |*arm, i| {
                        if (std.mem.eql(u8, arm.branch, "else")) try flatWalkSites(fx, ctx, cont.continuations[i .. i + 1], scope);
                    }
                }
            },
            else => {},
        }
    }
}

/// Populate `fx.resumptions` in emit order — a worklist over segment bodies,
/// the eval flow first — then fix `fx.lane_words` from the widest live set.
fn flatRegisterSites(
    fx: *FlatEmitState,
    ctx: *EmissionContext,
    flow: *const ast.Flow,
) EmitError!void {
    try flatWalkSites(fx, ctx, flow.body.continuations, &.{});
    var i: usize = 0;
    while (i < fx.resumptions.items.len) : (i += 1) {
        const site = fx.resumptions.items[i];
        var child_scope: std.ArrayList([]const u8) = .empty;
        defer child_scope.deinit(ctx.allocator);
        try child_scope.appendSlice(ctx.allocator, site.scope);
        if (site.return_binding) |rb| {
            if (!std.mem.eql(u8, rb, "_")) try child_scope.append(ctx.allocator, rb);
        }
        try flatWalkSites(fx, ctx, site.children, child_scope.items);
    }
    var max_live: usize = 0;
    for (fx.resumptions.items) |site| {
        if (site.live.len > max_live) max_live = site.live.len;
    }
    fx.lane_words = max_live + 1;
}

/// An `if (cond) { then-arms } else { else-arms }` block over the flat segment
/// walk — used for the flow head and for nested `if` invocations alike.
/// `sp_expr` is the current lane-stack position — always the first free lane
/// base, in the eval segment and inside a consumed resumption's lane alike.
/// Returns true when the emitted block can fall through to the next statement
/// — only an `if` without an `else` (or one whose arms can) leaves the path
/// open; every terminal node ends in a segment tailcall.
fn emitFlatSegIf(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    fx: *FlatEmitState,
    inv: *const ast.Invocation,
    arm_conts: []const ast.Continuation,
    sp_expr: []const u8,
    sp_grows: bool,
) EmitError!bool {
    var can_fall = false;
    try emitter.writeIndent();
    try emitter.write("if (");
    try emitValue(emitter, ctx, inv.args[0].value);
    try emitter.write(") {\n");
    emitter.indent_level += 1;
    var then_emitted = false;
    for (arm_conts, 0..) |*arm, i| {
        if (!std.mem.eql(u8, arm.branch, "then")) continue;
        then_emitted = true;
        can_fall = try emitFlatSegConts(emitter, ctx, fx, arm_conts[i .. i + 1], sp_expr, sp_grows);
    }
    emitter.indent_level -= 1;
    var has_else = false;
    for (arm_conts) |*arm| {
        if (std.mem.eql(u8, arm.branch, "else")) {
            has_else = true;
            break;
        }
    }
    try emitter.writeIndent();
    if (!has_else) {
        try emitter.write("}\n");
        return true;
    }
    try emitter.write("} else {\n");
    emitter.indent_level += 1;
    var else_emitted = false;
    for (arm_conts, 0..) |*arm, i| {
        if (!std.mem.eql(u8, arm.branch, "else")) continue;
        else_emitted = true;
        can_fall = can_fall or try emitFlatSegConts(emitter, ctx, fx, arm_conts[i .. i + 1], sp_expr, sp_grows);
    }
    emitter.indent_level -= 1;
    try emitter.writeIndent();
    try emitter.write("}\n");
    return can_fall or !then_emitted or !else_emitted;
}

/// Emit the `.{ sp_expr, w0, w1, ... }` argument tuple for a self-call segment
/// tailcall: one u64 register per input field, filled from the invocation's
/// matching arg (named, positional fallback) or the field's own current value
/// when the call doesn't pass it. The tuple evaluates every RHS before the
/// call — no simultaneous-assignment staging needed.
fn emitFlatSegCallArgs(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    fx: *FlatEmitState,
    inv: *const ast.Invocation,
    sp_expr: []const u8,
) EmitError!void {
    try emitter.write(".{ ");
    try emitter.write(sp_expr);
    for (fx.fields, 0..) |field, i| {
        try emitter.write(", @as(u64, @bitCast(@as(");
        try emitter.write(field.type);
        try emitter.write(", ");
        var value: ?[]const u8 = null;
        for (inv.args, 0..) |arg, ai| {
            if (arg.name.len == 0) {
                if (ai == i) value = arg.value;
            } else if (std.mem.eql(u8, arg.name, field.name)) {
                value = arg.value;
            }
        }
        if (value) |v| {
            try emitValue(emitter, ctx, v);
        } else {
            try writeBranchName(emitter, field.name);
        }
        try emitter.write(")))");
    }
    try emitter.write(" }");
}

/// Emit a produce's deliver: pop the top lane and tailcall its fid with the
/// result in r0. `sp` is the first free lane base, so the top lane sits at
/// `sp - lane_words` with its fid at index 0.
fn emitFlatSegDeliver(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    fx: *FlatEmitState,
    sp_expr: []const u8,
    value: []const u8,
    value_is_raw_zig: bool,
) EmitError!void {
    var nbuf: [64]u8 = undefined;
    const f = try std.fmt.bufPrint(&nbuf, "({s} - {d})", .{ sp_expr, fx.lane_words });
    try emitter.writeIndent();
    try emitter.write("return @call(.always_tail, @as(__koru_seg_ty, @ptrFromInt(");
    try emitter.write(f);
    try emitter.write("[0])), .{ ");
    try emitter.write(f);
    try emitter.write(", @as(u64, @bitCast(@as(");
    try emitter.write(fx.return_type);
    try emitter.write(", ");
    if (value_is_raw_zig) {
        try emitter.write(value);
    } else {
        try emitValue(emitter, ctx, value);
    }
    try emitter.write(")))");
    var z: usize = 1;
    while (z < fx.n_regs) : (z += 1) try emitter.write(", 0");
    try emitter.write(" });\n");
}

/// The flat segment walk. Mirrors the structured continuation dispatch over
/// the same AST, but every terminal lowers to a segment tailcall: a chained
/// non-tail self-call fills the current `[fid][live…]` lane and tailcalls the
/// eval segment, a tail self-call tailcalls eval directly (args as a pure
/// tuple — no staging), and a produce pops the top lane's fid and tailcalls
/// it with the result in r0. Anything outside the eligible set fails loud.
///
/// `sp_grows` marks whether `sp_expr` is the stack's high-water mark — true
/// only in the eval segment. A resumption's `sp` is its own just-popped lane,
/// so its pushes rewrite memory that was provably in bounds a moment ago and
/// skip the overflow check (measured: the check costs ~25% on tak).
/// Returns true when the last emitted statement can fall through — only a
/// trailing `if` without an `else` leaves a live path; every other terminal
/// is a segment tailcall.
fn emitFlatSegConts(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    fx: *FlatEmitState,
    conts: []const ast.Continuation,
    sp_expr: []const u8,
    sp_grows: bool,
) EmitError!bool {
    var nbuf: [96]u8 = undefined;
    var sbuf: [64]u8 = undefined;
    var can_fall = true;
    for (conts) |*cont| {
        const node = cont.node orelse {
            can_fall = try emitFlatSegConts(emitter, ctx, fx, cont.continuations, sp_expr, sp_grows);
            continue;
        };
        can_fall = false;
        switch (node) {
            .expression => |code_raw| {
                const code = lowerExprZig(emitter, ctx, code_raw);
                try emitFlatSegDeliver(emitter, ctx, fx, sp_expr, code, true);
            },
            .branch_constructor => |*bc| {
                if (!bc.is_bare_return or bc.plain_value == null) return error.FlatShapeUnsupported;
                try emitFlatSegDeliver(emitter, ctx, fx, sp_expr, bc.plain_value.?, false);
            },
            .invocation => {
                const inv = &cont.node.?.invocation;
                if (flatTargetsSelf(inv, fx.self_canonical, ctx)) {
                    if (isTailForwarder(cont)) {
                        try emitter.writeIndent();
                        try emitter.write("return @call(.always_tail, __koru_seg_eval, ");
                        try emitFlatSegCallArgs(emitter, ctx, fx, inv, sp_expr);
                        try emitter.write(");\n");
                    } else {
                        // Chained non-tail self-call: fill the free lane with
                        // the resumption segment's fid and the scalars that
                        // resumption reads, then tailcall eval with the call's
                        // arguments. The site's own bind arrives via r0, never
                        // the lane.
                        const tag = fx.next_site;
                        fx.next_site += 1;
                        const site = fx.resumptions.items[tag];
                        if (sp_grows) {
                            // Overflow faults on the guard page — this Debug-
                            // only check just gives it a diagnostic. Comptime-
                            // stripped in ReleaseFast, where the check cost
                            // ~25% on tak.
                            try emitter.writeIndent();
                            try emitter.write("if (comptime @import(\"builtin\").mode == .Debug) {\n");
                            emitter.indent_level += 1;
                            try emitter.writeIndent();
                            try emitter.write("if (@intFromPtr(");
                            try emitter.write(sp_expr);
                            try emitter.write(") >= @intFromPtr(__koru_cstk.ptr + (__koru_cstk.len - __koru_lane_w + 1))) @panic(\"koru: flat continuation stack overflow\");\n");
                            emitter.indent_level -= 1;
                            try emitter.writeIndent();
                            try emitter.write("}\n");
                        }
                        try emitter.writeIndent();
                        try emitter.write(sp_expr);
                        try emitter.write(try std.fmt.bufPrint(&nbuf, "[0] = @intFromPtr(&__koru_seg_k{d});\n", .{tag}));
                        for (site.live, 0..) |name, j| {
                            try emitter.writeIndent();
                            try emitter.write(sp_expr);
                            try emitter.write(try std.fmt.bufPrint(&nbuf, "[{d}] = @as(u64, @bitCast(@as(", .{j + 1}));
                            try emitter.write(flatLaneType(fx, name));
                            try emitter.write(", ");
                            try writeBranchName(emitter, name);
                            try emitter.write(")));\n");
                        }
                        try emitter.writeIndent();
                        try emitter.write("return @call(.always_tail, __koru_seg_eval, ");
                        try emitFlatSegCallArgs(emitter, ctx, fx, inv, try std.fmt.bufPrint(&sbuf, "{s} + {d}", .{ sp_expr, fx.lane_words }));
                        try emitter.write(");\n");
                    }
                } else if (flatIsIfInvocation(inv) and inv.inline_body != null) {
                    can_fall = try emitFlatSegIf(emitter, ctx, fx, inv, cont.continuations, sp_expr, sp_grows);
                } else return error.FlatShapeUnsupported;
            },
            else => return error.FlatShapeUnsupported,
        }
    }
    return can_fall;
}

/// Emit the continuation segments for a flat-eligible event as members of its
/// struct — called BEFORE the handler decl so the handler can name them. A
/// uniform `(sp, r0…rN) u64` signature lets `@call(.always_tail)` chain every
/// segment with zero frames; r0 doubles as the result register on delivery.
///
/// Every lane is `__koru_lane_w` u64 words: `[fid][live…]`, fid first, so the
/// pop is `sp - __koru_lane_w` and a resumption's own consumed lane is the
/// free slot it rewrites. `sp` is always the first free lane base.
///
/// ```zig
/// const __koru_lane_w = 5;
/// const __koru_seg_ty = *const fn (sp: [*]u64, r0: u64, …) u64;
/// fn __koru_seg_done(sp: [*]u64, r0: u64, …) u64 { return r0; }
/// fn __koru_seg_eval(sp: [*]u64, r0: u64, …) u64 { <flat body> }
/// fn __koru_seg_k0(sp: [*]u64, r0: u64, …) u64 { <resumption 0> }
/// ```
pub fn emitFlatSegments(
    emitter: *CodeEmitter,
    ctx: *EmissionContext,
    event: *const ast.EventDecl,
    flow: *const ast.Flow,
    self_canonical: []const u8,
) EmitError!void {
    var fx = FlatEmitState{
        .self_canonical = self_canonical,
        .fields = event.input.fields,
        .return_type = event.return_type.?,
        .n_regs = @max(event.input.fields.len, 1),
    };
    defer {
        for (fx.resumptions.items) |site| {
            ctx.allocator.free(site.live);
            ctx.allocator.free(site.scope);
        }
        fx.resumptions.deinit(ctx.allocator);
    }

    // Registration must complete before any emission: eval's pushes need
    // `lane_words`, which depends on sites the resumption bodies register.
    try flatRegisterSites(&fx, ctx, flow);

    var nbuf: [96]u8 = undefined;

    try emitter.writeIndent();
    try emitter.write(try std.fmt.bufPrint(&nbuf, "const __koru_lane_w = {d};\n", .{fx.lane_words}));
    try emitter.writeIndent();
    try emitter.write("const __koru_seg_ty = *const fn (sp: [*]u64");
    for (0..fx.n_regs) |r| {
        try emitter.write(try std.fmt.bufPrint(&nbuf, ", r{d}: u64", .{r}));
    }
    try emitter.write(") u64;\n");

    // Bottom-of-stack resumption: the handler pushes its fid as a sentinel, so
    // the last produce's deliver tailcall lands here and returns the result.
    try emitter.writeIndent();
    try emitter.write("fn __koru_seg_done(sp: [*]u64");
    for (0..fx.n_regs) |r| {
        try emitter.write(try std.fmt.bufPrint(&nbuf, ", r{d}: u64", .{r}));
    }
    try emitter.write(") u64 {\n");
    emitter.indent_level += 1;
    try emitter.writeIndent();
    try emitter.write("_ = sp;\n");
    var dr: usize = 1;
    while (dr < fx.n_regs) : (dr += 1) {
        try emitter.writeIndent();
        try emitter.write(try std.fmt.bufPrint(&nbuf, "_ = r{d};\n", .{dr}));
    }
    try emitter.writeIndent();
    try emitter.write("return r0;\n");
    emitter.indent_level -= 1;
    try emitter.writeIndent();
    try emitter.write("}\n");

    // Eval segment: the flow body itself, args arriving in the registers.
    try emitter.writeIndent();
    try emitter.write("fn __koru_seg_eval(sp: [*]u64");
    for (0..fx.n_regs) |r| {
        try emitter.write(try std.fmt.bufPrint(&nbuf, ", r{d}: u64", .{r}));
    }
    try emitter.write(") u64 {\n");
    emitter.indent_level += 1;
    for (fx.fields, 0..) |field, i| {
        try emitter.writeIndent();
        try emitter.write("const ");
        try writeBranchName(emitter, field.name);
        try emitter.write(" = @as(");
        try emitter.write(field.type);
        try emitter.write(try std.fmt.bufPrint(&nbuf, ", @bitCast(r{d}));\n", .{i}));
        if (!flatContsMentionName(flow.body.continuations, field.name)) {
            try emitter.writeIndent();
            try emitter.write("_ = ");
            try writeBranchName(emitter, field.name);
            try emitter.write(";\n");
        }
    }
    const eval_fall = try emitFlatSegIf(emitter, ctx, &fx, flow.inv(), flow.body.continuations, "sp", true);
    if (eval_fall) {
        try emitter.writeIndent();
        // An `if` without an `else` leaves a live fall-through — same dead end
        // the structured path marks unreachable.
        try emitter.write("unreachable;\n");
    }
    emitter.indent_level -= 1;
    try emitter.writeIndent();
    try emitter.write("}\n");

    // Resumption segments — emitted in registration order (the emit walk's
    // `next_site` consumes tags in the same order flatRegisterSites assigned
    // them). On entry `sp` is this segment's own lane — already popped, so
    // free — and r0 holds the produced result.
    var i: usize = 0;
    while (i < fx.resumptions.items.len) : (i += 1) {
        const site = fx.resumptions.items[i];
        try emitter.writeIndent();
        try emitter.write(try std.fmt.bufPrint(&nbuf, "fn __koru_seg_k{d}(sp: [*]u64", .{i}));
        for (0..fx.n_regs) |r| {
            try emitter.write(try std.fmt.bufPrint(&nbuf, ", r{d}: u64", .{r}));
        }
        try emitter.write(") u64 {\n");
        emitter.indent_level += 1;
        // Unused params are a Zig error; r0 is used only when a real binding
        // takes the result, r1.. never are.
        const rb_bound = if (site.return_binding) |rb| !std.mem.eql(u8, rb, "_") else false;
        if (!rb_bound) {
            try emitter.writeIndent();
            try emitter.write("_ = r0;\n");
        }
        var dr2: usize = 1;
        while (dr2 < fx.n_regs) : (dr2 += 1) {
            try emitter.writeIndent();
            try emitter.write(try std.fmt.bufPrint(&nbuf, "_ = r{d};\n", .{dr2}));
        }
        if (site.return_binding) |rb| {
            if (!std.mem.eql(u8, rb, "_")) {
                try emitter.writeIndent();
                try emitter.write("const ");
                try writeBranchName(emitter, rb);
                try emitter.write(" = @as(");
                try emitter.write(fx.return_type);
                try emitter.write(", @bitCast(r0));\n");
                if (!flatContsMentionName(site.children, rb)) {
                    try emitter.writeIndent();
                    try emitter.write("_ = ");
                    try writeBranchName(emitter, rb);
                    try emitter.write(";\n");
                }
            }
        }
        var ibuf: [64]u8 = undefined;
        for (site.live, 0..) |name, j| {
            try emitter.writeIndent();
            try emitter.write("const ");
            try writeBranchName(emitter, name);
            try emitter.write(" = @as(");
            try emitter.write(flatLaneType(&fx, name));
            try emitter.write(try std.fmt.bufPrint(&ibuf, ", @bitCast(sp[{d}]));\n", .{j + 1}));
            if (!flatContsMentionName(site.children, name)) {
                try emitter.writeIndent();
                try emitter.write("_ = ");
                try writeBranchName(emitter, name);
                try emitter.write(";\n");
            }
        }
        const seg_fall = try emitFlatSegConts(emitter, ctx, &fx, site.children, "sp", false);
        if (seg_fall) {
            try emitter.writeIndent();
            try emitter.write("unreachable;\n");
        }
        emitter.indent_level -= 1;
        try emitter.writeIndent();
        try emitter.write("}\n");
    }
}

/// Emit the flat handler body: push the `__koru_seg_done` sentinel on the lane
/// stack and call the eval segment. The whole recursion runs as segment
/// tailcalls; the last produce's deliver lands on the sentinel, which returns
/// the u64 result straight back through this call.
pub fn emitFlatHandlerBody(
    emitter: *CodeEmitter,
    event: *const ast.EventDecl,
) EmitError!void {
    try emitter.writeIndent();
    try emitter.write("if (__koru_cstk.len == 0) __koru_flat_init();\n");
    try emitter.writeIndent();
    try emitter.write("const __koru_base = __koru_csp;\n");
    try emitter.writeIndent();
    try emitter.write("__koru_cstk[__koru_base] = @intFromPtr(&__koru_seg_done);\n");
    try emitter.writeIndent();
    try emitter.write("defer __koru_csp = __koru_base;\n");
    try emitter.writeIndent();
    try emitter.write("return @as(@This().Output, @bitCast(__koru_seg_eval(__koru_cstk[__koru_base + __koru_lane_w ..].ptr");
    for (event.input.fields) |field| {
        try emitter.write(", @as(u64, @bitCast(__koru_event_input.");
        try writeBranchName(emitter, field.name);
        try emitter.write("))");
    }
    try emitter.write(")));\n");
}

/// Find the flow that implements `event` (the same match the impl-search loop
/// performs: `.flow` item, `impl_of` path equal to the event's, no variant) —
/// a `*const` into `items`, stable for deferred emission.
pub fn findFlatImplFlow(items: []const ast.Item, event: *const ast.EventDecl) ?*const ast.Flow {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                if (flow.impl_variant != null) continue;
                const impl_path = flow.impl_of orelse continue;
                if (impl_path.segments.len != event.path.segments.len) continue;
                var matches = true;
                for (impl_path.segments, 0..) |seg, j| {
                    if (!std.mem.eql(u8, seg, event.path.segments[j])) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return flow;
            },
            else => continue,
        }
    }
    return null;
}

/// Build the Zig enum tag for an event: its path segments joined by `_`, kebab
/// `-` mangled to `_` (matching the event struct's `<name>_event` prefix). Owned
/// by the caller.
fn mangledEventTag(event: *const ast.EventDecl, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (event.path.segments, 0..) |seg, i| {
        if (i > 0) try buf.append(allocator, '_');
        for (seg) |c| try buf.append(allocator, if (c == '-') '_' else c);
    }
    return try buf.toOwnedSlice(allocator);
}

/// True if `flow` is a mutual-group-lowerable subflow impl: a plain `if`-style
/// inline-statement body with named value-return continuations (the shape
/// `emitMutualGroupHandler` re-emits per arm). Preamble/label/effect-arm/
/// non-inline shapes are rejected — the group falls back to call-based emission.
fn isLowerableMutualMember(event: *const ast.EventDecl, flow: *const ast.Flow) bool {
    if (flow.preamble_code != null) return false;
    if (flow.pre_label != null) return false;
    if (findEffectArm(event, &flow.inv().path) != null) return false;
    const inline_code = flow.inline_body orelse return false;
    if (std.mem.indexOf(u8, inline_code, "//@koru:inline_stmt\n") == null) return false;
    for (flow.body.continuations) |c| {
        if (c.branch.len > 0) return true;
    }
    return false;
}

/// Walk a continuation tree, appending the invocation path of every
/// tail-forwarder found (a forwarder's identity children are not recursed into —
/// they carry no further calls).
fn collectTailForwardPaths(
    conts: []const ast.Continuation,
    out: *std.ArrayList(*const ast.DottedPath),
    allocator: std.mem.Allocator,
) !void {
    for (conts) |*cont| {
        if (isTailForwarder(cont)) {
            try out.append(allocator, &cont.node.?.invocation.path);
            continue;
        }
        if (cont.continuations.len > 0) {
            try collectTailForwardPaths(cont.continuations, out, allocator);
        }
    }
}

/// Detect the mutual-tail-recursion group containing `start_event`: the closure
/// of events reachable from it via tail-forwards, provided that closure is a
/// clean cycle back to `start_event`, every member shares its input shape, and
/// every member's impl is a lowerable inline subflow. Returns null (→ fall back
/// to ordinary call-based emission) on any deviation — a miss is slow, never
/// wrong. The degenerate 1-cycle (pure self-recursion) is intentionally rejected
/// here so it stays on the existing `flowContainsSelfTailForward` path.
pub fn detectMutualGroup(
    start_event: *const ast.EventDecl,
    all_items: []const ast.Item,
    allocator: std.mem.Allocator,
    main_module_name: ?[]const u8,
) !?MutualGroup {
    const MemberRec = struct {
        canon: []const u8,
        event: *const ast.EventDecl,
        flow: *const ast.Flow,
    };
    var members: std.ArrayList(MemberRec) = .empty;
    var success = false;
    defer {
        if (!success) {
            for (members.items) |m| allocator.free(m.canon);
        }
        members.deinit(allocator);
    }

    // addMember: append (canon, event, flow) if the event isn't already present
    // and its impl is a lowerable subflow. Returns false to abort the whole
    // group (non-flow impl, missing impl, or unlowerable shape).
    const addMember = struct {
        fn call(
            list: *std.ArrayList(MemberRec),
            alloc: std.mem.Allocator,
            mmn: ?[]const u8,
            items: []const ast.Item,
            evt: *const ast.EventDecl,
        ) !bool {
            const canon = try buildCanonicalEventName(&evt.path, alloc, mmn);
            for (list.items) |m| {
                if (std.mem.eql(u8, m.canon, canon)) {
                    alloc.free(canon);
                    return true; // already a member
                }
            }
            const impl = findImplByPath(items, &evt.path) orelse {
                alloc.free(canon);
                return false;
            };
            if (impl != .flow or !isLowerableMutualMember(evt, impl.flow)) {
                alloc.free(canon);
                return false;
            }
            try list.append(alloc, .{ .canon = canon, .event = evt, .flow = impl.flow });
            return true;
        }
    }.call;

    if (!try addMember(&members, allocator, main_module_name, all_items, start_event)) return null;
    const start_canon = members.items[0].canon;
    var forwards_to_start = false;

    var qi: usize = 0;
    while (qi < members.items.len) : (qi += 1) {
        const flow = members.items[qi].flow;
        var targets: std.ArrayList(*const ast.DottedPath) = .empty;
        defer targets.deinit(allocator);
        try collectTailForwardPaths(flow.body.continuations, &targets, allocator);
        for (targets.items) |tpath| {
            const target_canon = try buildCanonicalEventName(tpath, allocator, main_module_name);
            defer allocator.free(target_canon);
            if (std.mem.eql(u8, target_canon, start_canon)) forwards_to_start = true;
            const target_event = findEventDeclByPath(all_items, tpath) orelse return null;
            if (!try addMember(&members, allocator, main_module_name, all_items, target_event)) return null;
        }
    }

    // Validity gates: a genuine multi-member cycle back to the start, uniform
    // input shape across members.
    if (members.items.len < 2) return null;
    if (!forwards_to_start) return null;
    for (members.items[1..]) |m| {
        if (!inputShapesMatch(start_event, m.event)) return null;
    }

    // Build the tags first (the only remaining fallible allocations). Kept in a
    // separate array with its own errdefer so it never overlaps the outer defer
    // that owns the member canons — assembling `out_members` below is then
    // allocation-free, so canon ownership transfers without a double-free window.
    const tags = try allocator.alloc([]u8, members.items.len);
    var tag_built: usize = 0;
    errdefer {
        for (tags[0..tag_built]) |t| allocator.free(t);
        allocator.free(tags);
    }
    for (members.items, 0..) |rec, i| {
        tags[i] = try mangledEventTag(rec.event, allocator);
        tag_built += 1;
    }

    const out_members = try allocator.alloc(MutualMember, members.items.len);
    // Past this point nothing can fail: transfer canon + tag ownership.
    for (members.items, 0..) |rec, i| {
        out_members[i] = .{ .canonical = rec.canon, .tag = tags[i], .event = rec.event, .flow = rec.flow };
    }
    allocator.free(tags); // slice only; the strings are now owned by out_members
    success = true; // canon + tag ownership now held by out_members
    return MutualGroup{ .members = out_members };
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
        if (field.default) |d| {
            try code_emitter.write(" = ");
            try code_emitter.write(d);
        }
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
    if (try emitBareReturnOutput(code_emitter, event, ctx.main_module_name)) {
        // bare-return Output emitted centrally
    } else if (terminal_count == 0) {
        try code_emitter.write("pub const Output = void;\n");
    } else {
        try code_emitter.write(if (terminal_count <= 256) "pub const Output = union(enum(u8)) {\n" else "pub const Output = union(enum) {\n");
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
    // Pure-scalar value events lower as an `inline` shim over a scalar-param
    // impl (register ABI; see isScalarValueFields / emitEventDecl).
    const use_scalar_shim = !has_effect and isScalarValueFields(event.input.fields);
    try code_emitter.writeIndent();
    if (has_effect) {
        try code_emitter.write("pub fn handler(__koru_event_input: @This().Input, comptime __H: type) @This().Output {\n");
    } else if (use_scalar_shim) {
        try code_emitter.write("pub inline fn handler(__koru_event_input: @This().Input) @This().Output {\n");
        code_emitter.indent_level += 1;
        try code_emitter.writeIndent();
        try code_emitter.write("return __koru_handler_impl(");
        for (event.input.fields, 0..) |field, i| {
            if (i > 0) try code_emitter.write(", ");
            try code_emitter.write("__koru_event_input.");
            try writeBranchName(code_emitter, field.name);
        }
        try code_emitter.write(");\n");
        code_emitter.indent_level -= 1;
        try code_emitter.writeIndent();
        try code_emitter.write("}\n");
        try code_emitter.writeIndent();
        try code_emitter.write("fn __koru_handler_impl(");
        for (event.input.fields, 0..) |field, i| {
            if (i > 0) try code_emitter.write(", ");
            var pbuf: [24]u8 = undefined;
            try code_emitter.write(try std.fmt.bufPrint(&pbuf, "__koru_p_{d}: ", .{i}));
            try code_emitter.write(field.type);
        }
        try code_emitter.write(") @This().Output {\n");
    } else {
        try code_emitter.write("pub fn handler(__koru_event_input: @This().Input) @This().Output {\n");
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

    // Scalar-shim impl reconstructs Input from the scalar params so the field
    // bindings below (and any body reference to __koru_event_input) read
    // identically; SROA elides the local aggregate.
    if (use_scalar_shim) {
        try code_emitter.writeIndent();
        try code_emitter.write("const __koru_event_input: @This().Input = .{ ");
        for (event.input.fields, 0..) |field, i| {
            if (i > 0) try code_emitter.write(", ");
            try code_emitter.write(".");
            try writeBranchName(code_emitter, field.name);
            var pbuf: [24]u8 = undefined;
            try code_emitter.write(try std.fmt.bufPrint(&pbuf, " = __koru_p_{d}", .{i}));
        }
        try code_emitter.write(" };\n");
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
    try emitYieldingBranchAliases(code_emitter, event, has_effect, ctx.main_module_name);

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
    // Scope to the event's own module_decl — module-nested decls carry
    // unqualified paths, so an all_items scan first-matches a same-named impl
    // from any module by item order (470_015).
    var found_impl = false;
    const event_items = itemsOfDecl(all_items, event);

    // First check for impl items (immediate mock or flow body)
    if (findImplByPath(event_items, &event.path)) |found| {
        // The impl body references input fields by their Koru names while the
        // destructure above emits the Zig spelling (`x_y`). Carrying the decl
        // on the ctx lets escapeBoundNames rewrite those references; without
        // it `x-y` passes through verbatim and Zig reads subtraction.
        const saved_impl_event_for_scope = ctx.impl_event_decl;
        ctx.impl_event_decl = event;
        defer ctx.impl_event_decl = saved_impl_event_for_scope;
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
                // Subflow-implemented effects: inside this impl body, the
                // event's own effect arms are callable — expose the event so
                // arm-calls lower to `__H.<arm>(...)`.
                const saved_impl_event = ctx.impl_event_decl;
                if (has_effect) ctx.impl_event_decl = event;
                defer ctx.impl_event_decl = saved_impl_event;
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
        if (findProcDeclByPath(event_items, &event.path)) |proc| {
            if (proc.body.text.len > 0) {
                const body = try rewriteModToBare(ctx.allocator, proc.body.text);
                defer ctx.allocator.free(body);
                try code_emitter.writeIndent();
                try code_emitter.write(body);
                try code_emitter.write("\n");
            }
            found_impl = true;
        }
    }

    // THE LOUD HOLE. Nothing implements this event, and the placeholder below
    // would have to invent its answer. Building the program is allowed — that
    // is what makes a scaffold runnable, an application written as flow with
    // its boxes still empty — but reaching an empty box may not be quiet.
    // Twin of the same guard in visitor_emitter; both read one predicate.
    //
    // `[abstract]` is NOT exempt. The contract that an implementation exists
    // somewhere is checked by KORU047 at the invocation, before the passes that
    // rewrite implementations run — and a pass downstream of that check can take
    // the implementation away again (resolve_abstract_impl did exactly that to a
    // lone implementation until 430_057 pinned it). A guard that runs before the
    // hole can reopen is not guarding the hole. This one reads the program that
    // is actually being emitted, so it is the one that cannot be outrun.
    // Reaching here means nothing implements the event NOW, whatever was true
    // upstream; an abstract dispatch stub with a real implementation behind it
    // sets found_impl and never arrives.
    if (!found_impl and ast.stubWouldFabricate(event)) {
        const hole_name = try std.mem.join(ctx.allocator, ".", event.path.segments);
        defer ctx.allocator.free(hole_name);
        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "koru: reached `{s}`, which nothing implements — this program was built with the box still empty",
            .{hole_name},
        );
        defer ctx.allocator.free(msg);
        try code_emitter.writeIndent();
        try code_emitter.write("@panic(");
        try code_emitter.writeZigStringLiteral(msg);
        try code_emitter.write(");\n");
        // A body WAS written; suppress the fabricating placeholder below.
        found_impl = true;
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
        // A variant handler must carry the SAME signature as the bare handler:
        // an effect-bearing event's body calls its `!` arms by bare name, and a
        // standalone variant function has no inline-splice site to inherit them
        // from. Without `comptime __H: type` the arm is an undeclared identifier
        // in every variant body. (370_010)
        if (has_effect) {
            try code_emitter.write("(__koru_event_input: @This().Input, comptime __H: type) @This().Output {\n");
        } else {
            try code_emitter.write("(__koru_event_input: @This().Input) @This().Output {\n");
        }
        code_emitter.indent_level += 1;

        for (event.input.fields) |field| {
            try code_emitter.writeIndent();
            try code_emitter.write("const ");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(" = __koru_event_input.");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(";\n");
        }

        // Same yielding-branch aliases the bare handler binds, so `tick(...)`
        // resolves identically in a variant body.
        try emitYieldingBranchAliases(code_emitter, event, has_effect, ctx.main_module_name);

        for (event.input.fields) |field| {
            try code_emitter.writeIndent();
            try code_emitter.write("_ = &");
            try writeBranchName(code_emitter, field.name);
            try code_emitter.write(";\n");
        }
        try code_emitter.writeIndent();
        try code_emitter.write("_ = &__koru_event_input;\n");

        if (variant_proc.body.text.len > 0) {
            const vbody = try rewriteModToBare(ctx.allocator, variant_proc.body.text);
            defer ctx.allocator.free(vbody);
            try code_emitter.writeIndent();
            try code_emitter.write(vbody);
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

// ── Shared text/AST helpers, lifted from the store parts ─────────────
// The `~part` files of `std/store` (and `std/grid`) each carried these
// verbatim inside private `H` structs — folded here on the 2026-10-13
// deslop census. Parts alias them (`const stripQuotes =
// @import("emitter_helpers").stripQuotes;`) so call sites stay put.

/// Kebab-inclusive identifier char — Koru names carry '-'. NOT the
/// Zig-spelling `isIdentChar` above; store field/column names are kebab.
pub fn isKebabIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

/// Strip one pair of surrounding double quotes when present.
pub fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"') return s[1 .. s.len - 1];
    return s;
}

/// One-segment dotted path `module:name` — was `mkPathH`/`mkPathH2`.
pub fn mkPathH(alloc: std.mem.Allocator, module: []const u8, name: []const u8) ast.DottedPath {
    const segs = alloc.alloc([]const u8, 1) catch unreachable;
    segs[0] = alloc.dupe(u8, name) catch unreachable;
    return ast.DottedPath{ .module_qualifier = alloc.dupe(u8, module) catch unreachable, .segments = segs };
}

/// `mod:!state` → `mod:state` — strip a consuming borrow's `!` to the
/// bare borrow, for views that must read without owning.
pub fn bareBorrow(alloc: std.mem.Allocator, ph: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, ph, ':') orelse return alloc.dupe(u8, ph) catch unreachable;
    if (colon + 1 < ph.len and ph[colon + 1] == '!') {
        const out = alloc.alloc(u8, ph.len - 1) catch unreachable;
        @memcpy(out[0 .. colon + 1], ph[0 .. colon + 1]);
        @memcpy(out[colon + 1 ..], ph[colon + 2 ..]);
        return out;
    }
    return alloc.dupe(u8, ph) catch unreachable;
}

// ============================================================================
// MATERIALIZATION HELPERS — used by the in-pipeline host-build steps
// (std/compiler:host-build-*). They were born as generated text inside the
// backend driver's main(); they live here so backend_output_emitted handlers
// can reach them — the dependency edge is backend → backend_output, never the
// reverse.
// ============================================================================

/// The output executable name as the backend sees it: argv[1] when it isn't a
/// Koru source path (hand-run backend passes the input file there), else
/// "a.out". Was the generated driver's inline `output_exe` detection.
pub fn outputExeName(allocator: std.mem.Allocator) []const u8 {
    const args = std.process.argsAlloc(allocator) catch return "a.out";
    // Not freed — the name is read for the rest of the compile.
    if (args.len > 1 and
        !std.mem.endsWith(u8, args[1], ".kgpu") and
        !std.mem.endsWith(u8, args[1], ".kjs") and
        !std.mem.endsWith(u8, args[1], ".kz") and
        !std.mem.endsWith(u8, args[1], ".kc") and
        !std.mem.endsWith(u8, args[1], ".k")) return args[1];
    return "a.out";
}

/// The zig binary every toolchain spawn must use: `KORU_ZIG` when set and
/// non-empty, else PATH's `zig`. One resolver for koruc's own spawns
/// (backend build, version probes) AND the backend's (build-exe, zig env,
/// zig fetch) — the two processes must agree, or the zig-lib overlay
/// byte-verified against one version gets applied to another's std.
/// posix.getenv, not getEnvVarOwned: zero-alloc — an owned read leaks past
/// the GPA's exit report on every KORU_ZIG compile.
pub fn zigExe() []const u8 {
    const v = std.posix.getenv("KORU_ZIG") orelse return "zig";
    return if (v.len == 0) "zig" else v;
}

/// The --zig-lib-dir overlay: koru's optimized-but-byte-identical
/// std/json/Stringify.zig for every @import("std") the emitted program makes.
/// null → stock std; identical output, slower. Moved verbatim from the
/// generated backend driver's __koruEnsureZigLibOverlay; `koru_home` arrives
/// as a parameter so this module stays free of a compiler_env edge.
pub fn ensureZigLibOverlay(allocator: std.mem.Allocator, koru_home: []const u8, out: []u8) ?[]const u8 {
    const env_res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ zigExe(), "env" },
        .max_output_bytes = 64 * 1024,
    }) catch return null;
    defer allocator.free(env_res.stdout);
    defer allocator.free(env_res.stderr);
    const lib_key = ".lib_dir = \"";
    const lib_at = std.mem.indexOf(u8, env_res.stdout, lib_key) orelse return null;
    const lib_rest = env_res.stdout[lib_at + lib_key.len ..];
    const lib_end = std.mem.indexOfScalar(u8, lib_rest, '"') orelse return null;
    const real_lib = lib_rest[0..lib_end];

    // The patch is verified byte-identical against 0.15.2's
    // std.json.Stringify only. On any other zig version the
    // overlay could fail to compile — refuse it and keep stock
    // std rather than break every emitted-program build.
    const ver_key = ".version = \"";
    const ver_at = std.mem.indexOf(u8, env_res.stdout, ver_key) orelse return null;
    const ver_rest = env_res.stdout[ver_at + ver_key.len ..];
    const ver_end = std.mem.indexOfScalar(u8, ver_rest, '"') orelse return null;
    if (!std.mem.eql(u8, ver_rest[0..ver_end], "0.15.2")) return null;

    const overlay_rel = ".zig-cache/koru_lib_overlay";
    const overlay_tmp = ".zig-cache/koru_lib_overlay.tmp";
    const marker_rel = ".zig-cache/koru_lib_overlay/.koru_src";

    // A ready overlay built against this same lib dir is reused as-is.
    if (std.fs.cwd().readFileAlloc(allocator, marker_rel, 4096) catch null) |marker| {
        defer allocator.free(marker);
        if (std.mem.eql(u8, marker, real_lib))
            return std.fs.cwd().realpath(overlay_rel, out) catch null;
    }

    const patch_path = std.fmt.allocPrint(allocator, "{s}/src/zig_std_patch/Stringify.zig", .{koru_home}) catch return null;
    defer allocator.free(patch_path);
    const patch_src = std.fs.cwd().readFileAlloc(allocator, patch_path, 1 << 20) catch return null;
    defer allocator.free(patch_src);

    std.fs.cwd().deleteTree(overlay_tmp) catch {};
    std.fs.cwd().makePath(overlay_tmp) catch return null;
    defer std.fs.cwd().deleteTree(overlay_tmp) catch {};

    // Mirror every top-level lib entry; std/ is expanded one level
    // deeper so std/json can be swapped piecewise below.
    var lib_dir = std.fs.cwd().openDir(real_lib, .{ .iterate = true }) catch return null;
    defer lib_dir.close();
    var lib_it = lib_dir.iterate();
    while (lib_it.next() catch return null) |ent| {
        if (std.mem.eql(u8, ent.name, "std")) continue;
        const target = std.fmt.allocPrint(allocator, "{s}/{s}", .{ real_lib, ent.name }) catch return null;
        defer allocator.free(target);
        const link = std.fmt.allocPrint(allocator, "{s}/{s}", .{ overlay_tmp, ent.name }) catch return null;
        defer allocator.free(link);
        std.fs.cwd().symLink(target, link, .{}) catch return null;
    }

    const std_target = std.fmt.allocPrint(allocator, "{s}/std", .{real_lib}) catch return null;
    defer allocator.free(std_target);
    std.fs.cwd().makePath(overlay_tmp ++ "/std") catch return null;
    var std_dir = std.fs.cwd().openDir(std_target, .{ .iterate = true }) catch return null;
    defer std_dir.close();
    var std_it = std_dir.iterate();
    while (std_it.next() catch return null) |ent| {
        if (std.mem.eql(u8, ent.name, "json")) continue;
        const target = std.fmt.allocPrint(allocator, "{s}/std/{s}", .{ real_lib, ent.name }) catch return null;
        defer allocator.free(target);
        const link = std.fmt.allocPrint(allocator, "{s}/std/{s}", .{ overlay_tmp, ent.name }) catch return null;
        defer allocator.free(link);
        std.fs.cwd().symLink(target, link, .{}) catch return null;
    }

    const json_target = std.fmt.allocPrint(allocator, "{s}/json", .{std_target}) catch return null;
    defer allocator.free(json_target);
    std.fs.cwd().makePath(overlay_tmp ++ "/std/json") catch return null;
    var json_dir = std.fs.cwd().openDir(json_target, .{ .iterate = true }) catch return null;
    defer json_dir.close();
    var json_it = json_dir.iterate();
    while (json_it.next() catch return null) |ent| {
        if (std.mem.eql(u8, ent.name, "Stringify.zig")) continue;
        const target = std.fmt.allocPrint(allocator, "{s}/{s}", .{ json_target, ent.name }) catch return null;
        defer allocator.free(target);
        const link = std.fmt.allocPrint(allocator, "{s}/std/json/{s}", .{ overlay_tmp, ent.name }) catch return null;
        defer allocator.free(link);
        std.fs.cwd().symLink(target, link, .{}) catch return null;
    }

    std.fs.cwd().writeFile(.{ .sub_path = overlay_tmp ++ "/std/json/Stringify.zig", .data = patch_src }) catch return null;
    std.fs.cwd().writeFile(.{ .sub_path = overlay_tmp ++ "/.koru_src", .data = real_lib }) catch return null;

    // Publish atomically-ish: build under .tmp, then swap in. A
    // stale overlay is deleted first (rename onto a non-empty
    // dir fails on some platforms).
    std.fs.cwd().deleteTree(overlay_rel) catch {};
    std.fs.cwd().rename(overlay_tmp, overlay_rel) catch return null;
    return std.fs.cwd().realpath(overlay_rel, out) catch null;
}
