const std = @import("std");

pub const ErrorCode = enum(u16) {
    // Construct errors
    KORU001, // Unknown construct after ~
    KORU002, // Module not found (import resolution failed)
    KORU003, // Inline flow in proc body (feature disabled)
    KORU010, // Stray continuation (| without context)

    // Branch errors
    KORU021, // Unknown branch in continuation
    KORU022, // Missing required branch
    KORU023, // Yielding `!` branches must precede terminal `|` branches
    KORU024, // Redundant outer parens around `when` condition
    KORU025, // Branch kind mismatch (e.g. `!` decl handled by `|` cont, or vice versa)
    KORU026, // Pay-for-nothing residual arm (`|* |> _` or `|* Metatype _ |> _`)
    KORU027, // Incoherent obligation marker on an effect branch (0-to-N firing): payload discharge or resume issue
    KORU028, // Duplicate unguarded handler for a terminal `|` branch (runs at most once)
    KORU029, // Prototype module (~[prototype]) rejected in a --release build (the production gate)

    // Shape errors
    KORU030, // Shape mismatch
    KORU031, // Payload type mismatch — point-free choke claims a branch whose payload shape disagrees across stages (220_025)
    KORU032, // Cannot auto-discharge outer-scope resource inside loop
    KORU033, // Invalid phantom annotation (e.g., obligation issuance on input)
    KORU034, // '_' in a Koru name — use '-' (kebab); '_' is reserved for digit separators
    KORU035, // '.' used as a namespace separator — use '/' ('.' is member access after ':')
    KORU036, // Binding-position destructure names a field the branch payload does not have
    KORU037, // No-op `_` body on an OPTIONAL effect branch (pure noise; a promote-to-required silent-swallow hazard)
    KORU038, // Whole result-struct punned into a scalar field (e.g. an fmt result `text` into a `text: string` param) — reach the field (`text.text`)
    KORU039, // No-op `_` body on an effect branch that has a real sibling handler — a discard on a per-fire filter discards nothing
    SHAPE001, // Inconsistent branch shapes in subflow
    SHAPE002, // Duplicate branch handler at same level (indentation error)

    // Name resolution errors
    KORU040, // Unknown event/proc/subflow
    KORU041, // Unknown label
    KORU042, // Duplicate label
    KORU043, // Label shape mismatch
    KORU044, // Private event access from another module
    KORU045, // Label requires parameters (pre-invocation label)
    KORU046, // Label does not accept parameters (post-invocation label)
    KORU047, // Event invoked but has no implementation (emitter would silently stub zero-defaults/undefined)

    // Proc errors
    KORU050, // Proc without matching event
    KORU051, // Proc returns unknown branch
    KORU052, // Proc payload mismatch
    KORU053, // Unguarded arm is not last in an exclusive group - the arms after it are unreachable
    KORU054, // No-op `_` body on an OPTIONAL terminal branch - omit the arm instead (400_197)

    // Subflow errors
    KORU060, // Subflow arity mismatch
    KORU061, // Subflow recursion detected

    // First-class event errors
    KORU070, // Cannot determine shape at compile time

    // Argument errors
    KORU080, // Missing required field
    KORU081, // Unknown field
    KORU083, // [!] annotation on multi-branch event (must be single-outcome)

    // Pipeline errors
    KORU090, // Unhandled split in pipeline
    KORU091, // Invalid use of 'p' symbol
    KORU092, // Point-free thread has no home — the next step is still incomplete and none of its unfilled parameters accepts the `-> T` the previous stage produced (210_176)
    KORU093, // Point-free thread cannot elect — several unfilled parameters of the next step accept its type; write one of them (210_176)
    KORU094, // A flow's chain does not produce its declared `-> T` — the last step returns a different type, or returns nothing at all (210_184)
    KORU095, // A `-> string` bare return projects a parameter's memory (`s.data`) — the borrow outlives nothing trackable; borrows flow down, never up (610_007, ruled 2026-09-05)

    // Parser errors
    PARSE001, // Unexpected end of file
    PARSE002, // Invalid indentation
    PARSE003, // Malformed construct
    PARSE004, // Unbalanced braces
    PARSE005, // Redundant explicit label where punning would produce the same name
    PARSE006, // Bare argument does not name a parameter — explicit `name: value` label required
    PARSE007, // Invalid annotation separator — annotations delimit on `|`, not `,`
    PARSE008, // `~` after a closing `]` — the annotation block's `[` already entered Koru; write the declaration directly after `]`
    PARSE009, // A call binds the same name twice — one value is silently dropped downstream
    PARSE010, // A field list binds the same name twice — tor input shapes, branch payloads, branch constructors, record types: the dup reaches Zig as a doubled struct field
    PARSE011, // `= <expr>` on a branch payload field — the emitted union drops it; defaults only apply to tor input fields
    PARSE012, // `@`-prefixed annotation in surface syntax — compiler marks are pass-produced, never parsed

    // Type inference errors
    TYPE001, // Branch not found in expected union
    TYPE002, // Branch constructor where union not expected
    TYPE003, // Field type mismatch
    TYPE004, // Missing required field
    TYPE005, // Unexpected field in branch constructor

    // Binding errors
    KORU100, // Unused binding
    KORU101, // Binding on a payload-less branch (nothing to bind or discard)
    KORU102, // `=>` (branch construction) used where the event produces a single payload (`-> T`) — use `->`
    KORU103, // `|>` (chain) used to introduce a bare value — `|>` chains steps; produce a value with `->`
    KORU104, // Call inside an expression — calls are not expressions; use tor chaining (bind the result first)
    KORU105, // Nested branches under a bodiless `|` branch — nothing picks a branch there; branches continue from an invocation
    KORU106, // A bind shadows one already in scope on the same path — Koru has no shadowing, and the pun machinery depends on it (210_173)
    KORU107, // `&name` borrows an immutable binding into a mutable `*T` parameter — the binding emits `const`, so `&` produces `*const` and never reaches the slot; annotate the bind `[mutable]` to lend it
    KORU108, // A name bound somewhere in the flow is referenced on a path that doesn't bind it — arm bindings end with their arm, `: name` binds scope downstream (400_213, 400_214)

    // Variant errors
    KORU110, // Event call site has only bare ~proc declarations (no variant tag)
    KORU111, // Contract/implementation file split violated (public events live in .k only)
    KORU112, // Effect-branch proc body reaches its own module by a bare name — the body splices into the CONSUMER's frame, where module scope is gone; use `$mod.` (400_155 holds the contract, 400_157 the wall)
    KORU115, // Bare host (Zig) type reference across a module boundary — a host type is bare only inside its declaring module; spell it qualified (`*mod:Type`) (220_031, ruled 2026-09-06)
    KORU116, // Phantom qualifier restates the base type's module — bare `<state>` already scopes there; drop the qualifier (330_112)
    KORU117, // Qualified host (Zig) type reference does not resolve — the named module does not declare the type; a qualified host ref must name the declaring module (`*mod:Type`) (220_037)

    // Abstract / implementation errors
    KORU113, // Two implementations claim the same abstract tor — the pairing is one-to-one, so the second is never reachable
    KORU114, // An implementation targets a tor that is not declared `~[abstract]` (or does not exist at all)

    // Template / metaprogramming errors
    KORU120, // Template-asserted contract violation (`{% comp error %}` reached)
    KORU121, // Per-call template construct has no variant for the build target
    KORU122, // Transform invocation requests a |variant the transform doesn't declare — never silently falls back
    KORU123, // Kernel |mlir generation restriction — the walking skeleton rejects shapes it can't generate yet
    KORU124, // Transform invoked in continuation position via the whole-program escape — the real nested invocation is never rewritten (frontier: 210_024_source_scope_capture)
    KORU125, // `{% if %}` / `{% unless %}` condition outside the engine's grammar — an unparseable condition is never silently false
    KORU126, // `--lang=<tag>` names no emitter and no proc variant the program declares — a tag that selects nothing compiles nothing
    KORU127, // A kernel scope admits exactly one `std/kernel:step` — a second step invocation would silently replace the earlier range (emitted by koru_std/kernel.kz)

    // Presence errors (optional effect arms — `if(arm)` / `when arm`)
    KORU130, // Value-resuming optional arm fired without a dominating presence test
    KORU131, // Presence test on a required arm (always installed — the test is meaningless)

    // Scoped vocabulary (`[with]`) errors
    KORU140, // Bare name resolves against more than one opened `[with]` vocabulary — ambiguous, qualify the call explicitly to pick one. Emitted by the metacircular resolve-with-scopes pass (koru_std/compiler.with.kz), so the .zig-only registry emit-scan can't see it — reserved in scripts/registry_reserved.txt.
    KORU141, // Tap declared in a ~[comptime] module — the comptime pipeline does not expand transforms, so the tap-flow would leak into generated backend code as a bare invocation
    KORU142, // A `[with(...)]` argument names a module the file never imported — the annotation abbreviates a declared dependency, it does not create one. Emitted by the metacircular resolve-with-scopes pass (koru_std/compiler.with.kz) — reserved in scripts/registry_reserved.txt.

    // Annotation-entry vocabulary errors (the import gate is the first consumer; the item gate is the second)
    KORU150, // Conditional-gate entry the gate cannot evaluate — an entry deciding AST membership must evaluate; silence is never an option

    // Store declaration errors (std/store's comptime transforms)
    KORU160, // A store's owned column cannot be drained as declared — no discharger for its held state, or several with no `! discharge` arm to pick. Emitted by koru_std/store.kz, so the .zig-only registry emit-scan can't see it — reserved in scripts/registry_reserved.txt.
    KORU161, // A std/store declaration or call site is malformed — the store transforms' refusals (wrong arity, missing name, unknown branch, a column type the store cannot address). One code for the class; the message names the specific fault. Emitted by koru_std/store.kz — reserved in scripts/registry_reserved.txt.
    KORU162, // A std/regex declaration or call site is malformed — the regex transforms' refusals (missing input, uncompilable pattern, a destructure naming no named group). One code for the class; the message names the fault. Emitted by koru_std/regex.kz — reserved in scripts/registry_reserved.txt.
    KORU163, // A std/parser grammar or parse call site is malformed — the parser transforms' refusals (missing name, a rule that is not an effect arm, an unknown grammar or rule, left recursion). One code for the class; the message names the fault. Emitted by koru_std/parser.kz — reserved in scripts/registry_reserved.txt.
    KORU164, // A std/control:capture call site is malformed — the capture transform's refusals (missing seed block, missing `! as <cell>` arm, an unparseable seed). One code for the class; the message names the fault. Emitted by koru_std/control.kz — reserved in scripts/registry_reserved.txt.
    KORU165, // A std/trellis:enforce / :check call site is malformed — missing trellis name, or a trellis that is not defined. One code for the class; the message names the fault. Emitted by koru_std/trellis.kz — reserved in scripts/registry_reserved.txt.
    KORU166, // A std/constructor call site is malformed — missing name, or a missing `! construct` traversal branch. One code for the class; the message names the fault. Emitted by koru_std/constructor.kz — reserved in scripts/registry_reserved.txt.
    KORU167, // A std/switch:char call site is malformed — missing value argument, an empty branch pattern, or an inverted range. One code for the class; the message names the fault. Emitted by koru_std/switch.kz — reserved in scripts/registry_reserved.txt.
    KORU168, // A std/io interpolation is malformed — `{{ x }}` containing a function call (calls are not expressions), or missing its format specifier (:d/:s/:f/:any). One code for the class; the message names the placeholder. Emitted by koru_std/io.kz — reserved in scripts/registry_reserved.txt.
    KORU169, // A std/field call site is malformed — `new.on-stack` without (bits), or `mark-multiples` without (f, from, stride, limit). Emitted by koru_std/field.kz — reserved in scripts/registry_reserved.txt.
    KORU170, // A std/kernel call site is malformed — a kernel subtree the walking skeleton rejects, a missing `| computed |>` branch (without it kernel results are trapped in the kernel scope), or a standalone `self`/`pairwise` written OUTSIDE any `std/kernel:init` subtree, where there is no kernel view for it to operate on. Emitted by koru_std/kernel.kz — reserved in scripts/registry_reserved.txt.
    KORU171, // A std/vendor:bindings declaration is malformed, or does not match the tree it pins — unpinned source, a missing vendor.lock entry, an unreadable vendored tree, a file that drifted from its recorded hash, a line that is not `module: ./path`, or a module that already resolves somewhere else. One code for the class; the message names the binding and the file. Emitted by koru_std/vendor.kz for the tree faults, and by src/parser.zig for the declaration faults, because the same block also redirects the import and so must act before the imports it governs are resolved.
    KORU172, // A std/compiler:paths declaration is malformed — a line that is not `alias: path`, an alias that is not a usable import alias, the reserved alias `main`, or a `{{ flag:name }}` whose flag was not supplied. One code for the class; the message names the fault. Emitted by src/parser.zig at parse time, because the declaration must act before the imports it governs are resolved.
    KORU173, // A std/types.proto declaration or a derived-container call site is malformed — a duplicate proto name (two registrants), an unusable entry name, an unsupported field type, an unresolvable element reference, or a container op whose handle is not bound by std/list:new in the same flow. One code for the class; the message names the fault. Emitted by koru_std/types.kz and koru_std/list.kz — registered in the transform-refusal family (all refusals land as comptime @compileError nodes).
    KORU174, // The compile memory budget fired — the backend's compilation exceeded --compile-mem-mb / KORU_COMPILE_MEM_MB (default 4096 MB) and the compiler REFUSED instead of ballooning until the OS SIGKILLed it. Nothing was miscompiled and nothing ran; the message names the budget and the escape hatch. Emitted by the generated backend's BudgetAllocator (src/main.zig template), which wraps the compile arena and every pass allocator.
    KORU175, // A destructure entry annotation reaches no implementing consumer — a destructure entry is a request (`ast.DestructureField.annotations`), honored or refused by the consumer that reads it, never silently ignored. The generic emit path implements none; std/store's query arm owns `[row]`/`[ordinal]`/`[id]`.
    KORU176, // A std/declarations:const call site is malformed — the `const { … }` field list refused by the shared field-list rules (a nameless entry, `name:` with no value, a fused line that dropped its comma, a name bound twice). One code for the class; the message names the fault. Emitted by src/template_processor.zig at template render — const is a [template] proc, so its refusal surfaces through the render path rather than a transform's ast.refusal.
    KORU177, // A call-site `|variant` names no declared proc target — the emitter would write a handler__<variant> call that resolves to nothing and surface it as a Zig backend 'no member' error. Emitted by src/flow_checker.zig (370_015).
    KORU178, // A std/json:parse call site is malformed — missing input, a branch outside ok/malformed, an empty or untypeable schema, an unsupported field type, or a destructure annotation a parse does not implement. One code for the class; the message names the fault. Emitted by koru_std/json.parse.kz — reserved in scripts/registry_reserved.txt.
    KORU179, // A std/panic:catch declaration is malformed — a missing site pattern, a non-`!` arm, no `!` arms, a pattern that grafts nothing, two catches claiming one site+branch, or an absorb arm grafted into a producing flow that ends without a verdict. One code for the class; the message names the fault. Emitted by koru_std/panic.kz — reserved in scripts/registry_reserved.txt.
    KORU180, // A std/fmt call site is malformed — a fmt.blk or ln site with no `: name` bind. The `| formatted` / `| line` branch spelling was removed from the grammar, so an unbound result has no consumer and would reach Zig codegen as a dead tagged union (the 620_020 raw-Zig-leak class). Emitted by koru_std/fmt.kz and koru_std/fmt.lnzig.kz — reserved in scripts/registry_reserved.txt.
    KORU181, // An unspaced `-` joined identifiers into one kebab name that binds nothing, while every `-`-segment resolves — the author almost surely wrote subtraction. Emitted by src/flow_checker.zig.
    KORU182, // A `-`-joined member name (`p.x-c`) names no field of the receiver's statically-known record, while the first `-`-segment IS a field and the rest resolve as names — the author almost surely wrote subtraction. Emitted by src/flow_checker.zig.
    KORU183, // A std/cli call site or declaration is malformed — a `| arm` that is neither a command nor `usage`/`help`, a destructure field that is neither a declared flag nor a positional, an unsupported positional/flag type, or a nested `std/cli()` site (the dispatch is a top-level item). One code for the class; the message names the fault. Emitted by koru_std/cli.kz — reserved in scripts/registry_reserved.txt.
    KORU184, // A std/tree declaration or call site is malformed — a non-identifier node name, a field that is neither `name: Type` nor `name: ?Type`, a field type that is neither payload material nor a node-registered edge, a mint missing a required field or spelling an undeclared one, a null on a required edge, or a dispose whose binding's node type can't be resolved. One code for the class; the message names the fault. Emitted by koru_std/tree.kz — reserved in scripts/registry_reserved.txt.

    // Module structure errors
    KORU200, // Ambiguous module structure (both foo.kz and foo/ exist)
    KORU201, // part 'X' has no file — the declaration named a sibling group that does not exist (fail loud, never a silent miss)
    KORU202, // Duplicate top-level tor declaration — a module declares each tor once within one file and across the part boundary; facet-boundary repeats are KORU111's call (140_024, 210_262)
    KORU203, // Invalid part tag ('.' / '/' / whitespace — tags are single kebab names) or the tag names a directory (module namespace collision, 140_026)
    KORU204, // part declared inside a part file — parts are flat; promote to a directory module when a part outgrows its file (140_028)
    KORU205, // std/refine refusal — malformed field line, non-int bound, or a meet that lands empty (671_*)
    KORU206, // A `#L` fold where every terminal arm re-dispatches `@L` can never exit — statically infinite (an external fuzzer watched `| done` re-fire 14.5M times; the corpus exit is `->` produce or a `|>` continuation)
    KORU207, // --deep-check witness: output_emitted.zig does not parse as Zig (emitted text is not the verdict; emitted *valid* text is). Printed by the validate-emitted tor in koru_std/compiler.materialize.kz (510_126). Formerly the flow_checker `!` arm param refusal — that site retired when Handlers_* fns learned to capture (400_208).
    KORU208, // `mod/path:default(...)` spelled explicitly — the default door is invoked by the bare module path `mod/path(...)`; the `:default` segment is compiler-manufactured, never source. Emitted by src/import_pipeline.zig.
    KORU209, // `dir:` relocates the emitted artifact while the program declares build:requires — generated build_output.zig stages output_emitted.zig in cwd. Printed by the host-build-zig tor in koru_std/compiler.materialize.kz.
    KORU210, // A std/build:app declaration is malformed — the Source block did not parse as `name: "…", id: "…"` plus optional `version: "…"`, `icon: "…"`, or carried a key the collector does not know. An identity is whole or refused; never defaulted. Emitted by src/compiler_requires.zig at requirement collection.
    KORU211, // A `#label` anchors a call that never exists at runtime — a keyword/comptime/transform invocation is consumed at compile time, so the anchor emits no `label:` block, every `@label` jump dangles into Zig as `continue :label` against a missing label, and the jump's args get declared with AST-level types (Expression) that do not exist at runtime. A label may only anchor a runtime tor invocation. Emitted by src/flow_checker.zig (040_CONTROL_FLOW/249).
};

pub const SourceLocation = struct {
    line: usize,
    column: usize,
    file: []const u8,
};

pub const ParseError = struct {
    code: ErrorCode,
    message: []const u8,
    location: SourceLocation,
    hint: ?[]const u8,
    /// How many characters the caret should span. Default 1 (point at the
    /// single column). Use larger values to highlight a multi-char token like
    /// `|>` (span = 2). The caret block prints `^` repeated span_length times.
    span_length: usize = 1,
    /// True when this error originates inside the auto-injected compiler
    /// bootstrap prelude — content the user did not write. Renderers should
    /// preview from the bootstrap source slice rather than the user source so
    /// the user sees the line they're actually being told about.
    is_bootstrap: bool = false,
    /// 1-based line within the bootstrap prelude. Only meaningful when
    /// `is_bootstrap` is true.
    bootstrap_line: usize = 0,

    pub fn format(
        self: ParseError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("error[{s}]: {s}\n", .{ @tagName(self.code), self.message });
        try writer.print("  --> {s}:{}:{}\n", .{ self.location.file, self.location.line, self.location.column });

        if (self.hint) |hint| {
            try writer.print("  hint: {s}\n", .{hint});
        }
    }
};

/// Process-global "the reporter rendered at least one diagnostic" flag. The
/// generated backend's `emit()` reads this before printing the
/// `❌ Compiler coordination error:` line: a failure whose pass already
/// delivered located diagnostics gets its quiet `exit(1)`, and the echo is
/// reserved for failures that never spoke (user coordinator overrides,
/// diagnostic-free internal errors). One compilation per backend process, so
/// a plain global is the whole mechanism.
pub var diagnostics_were_printed = false;

/// Process-global diagnostic sinks — the diagnostics bus. The generated
/// backend collects `std/compiler(diagnostic)` joins from the seed AST and
/// registers each `!` arm's consumer here; every `addError*` variant then
/// dispatches the stored ParseError to all of them, synchronously, at append
/// time. Reporters are per-file but a compile is one process, so a plain
/// global is the whole mechanism — same shape as `diagnostics_were_printed`
/// above. Empty by default: a binary that never registers pays one slice
/// bounds-check per error and nothing else.
pub const DiagSink = struct {
    ctx: *anyopaque,
    /// Called once per stored diagnostic inside `addError*`. A sink must not
    /// report back through the reporter — re-entrant dispatch is dropped by
    /// `in_diag_dispatch`, not relayed.
    emit: *const fn (ctx: *anyopaque, err: *const ParseError) void,
    /// Called once at pipeline end — the batched-write side of a `flush:
    /// false` config (COMMIT of an open transaction, close of a handle). A
    /// sink with nothing to tear down leaves it null.
    finish: ?*const fn (ctx: *anyopaque) void = null,
};

var diag_sinks: std.ArrayList(DiagSink) = .empty;
var in_diag_dispatch = false;

/// Register a diagnostic consumer for the rest of the process. The backend
/// calls this once per collected join arm, before the pipeline runs.
/// Single-threaded by the same argument as `diagnostics_were_printed`.
pub fn registerDiagSink(allocator: std.mem.Allocator, sink: DiagSink) !void {
    try diag_sinks.append(allocator, sink);
}

/// Pipeline-end drain: let sinks commit/close whatever `emit` batched. The
/// emitted backend defers this right after sink registration so every return
/// path out of `main` flushes what was buffered.
pub fn finishDiagSinks() void {
    for (diag_sinks.items) |sink| {
        if (sink.finish) |f| f(sink.ctx);
    }
}

fn dispatchDiag(err: *const ParseError) void {
    if (in_diag_dispatch) return;
    in_diag_dispatch = true;
    defer in_diag_dispatch = false;
    for (diag_sinks.items) |sink| {
        sink.emit(sink.ctx, err);
    }
}

pub const ErrorReporter = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ParseError),
    /// Source lines for the user-facing preview block. After setUserSource,
    /// these are the user's original lines (no injected prelude). Indexed by
    /// user-coordinate `line - 1`.
    source_lines: [][]const u8,
    /// Source lines for the auto-injected bootstrap prelude. Populated by
    /// setUserSource. Used to render previews for errors that originate inside
    /// the prelude (the user didn't write those lines, but we still need to
    /// show what was rejected).
    bootstrap_source_lines: ?[][]const u8 = null,
    file_name: []const u8,
    /// Number of injected lines prepended to the parsed source before parsing
    /// (e.g. the `~import std/compiler` bootstrap line). The parser sees
    /// line numbers in INJECTED coordinates; we translate to user coordinates
    /// (subtract this count) when storing errors so user output is correct.
    /// 0 means no injection — translation is a no-op.
    injection_line_count: usize = 0,
    /// Render watermark. `printErrors` emits only errors at or past this index,
    /// then advances it to `errors.items.len` — each diagnostic prints exactly
    /// once. The compilation's reporter is shared across passes, and a pass
    /// gate that prints for itself (auto_discharge_inserter's hasErrors
    /// bail-outs) is re-rendered by the pipeline's failure catch
    /// (compiler.kz) — without the watermark every diagnostic on those paths
    /// landed twice (KORU080 doubled on a `window.open` missing its inputs,
    /// 2026-09-12).
    printed_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, file_name: []const u8, source: []const u8) !ErrorReporter {
        var lines = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        var iter = std.mem.splitScalar(u8, source, '\n');
        while (iter.next()) |line| {
            try lines.append(allocator, line);
        }

        return ErrorReporter{
            .allocator = allocator,
            .errors = try std.ArrayList(ParseError).initCapacity(allocator, 8),
            .source_lines = try lines.toOwnedSlice(allocator),
            .file_name = file_name,
        };
    }

    /// Reconfigure the reporter to render previews from `user_source` (the
    /// original file content, without any injected prelude) and translate
    /// stored line numbers back to user coordinates by subtracting
    /// `injection_line_count`. The current `source_lines` is preserved as
    /// `bootstrap_source_lines` so previews for errors that originate inside
    /// the prelude can still show what the parser rejected. Call this after
    /// Parser.init when the caller prepended lines to the parsed source.
    pub fn setUserSource(self: *ErrorReporter, user_source: []const u8, injection_line_count: usize) !void {
        var lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        var iter = std.mem.splitScalar(u8, user_source, '\n');
        while (iter.next()) |line| {
            try lines.append(self.allocator, line);
        }
        // Preserve the previously-built (full=injected) source_lines as the
        // bootstrap preview slice. The user_source slice gets a fresh split.
        self.bootstrap_source_lines = self.source_lines;
        self.source_lines = try lines.toOwnedSlice(self.allocator);
        self.injection_line_count = injection_line_count;
    }

    pub fn deinit(self: *ErrorReporter) void {
        for (self.errors.items) |*err| {
            self.allocator.free(err.message);
            if (err.hint) |hint| {
                self.allocator.free(hint);
            }
        }
        self.errors.deinit(self.allocator);
        self.allocator.free(self.source_lines);
        if (self.bootstrap_source_lines) |bsl| self.allocator.free(bsl);
    }

    const LineClass = struct {
        /// Line number to render in the error output. For bootstrap errors,
        /// this is 0 — the user sees `:0` to signal "before your file starts".
        line: usize,
        is_bootstrap: bool,
        /// 1-based bootstrap line for preview lookup. Only set when
        /// `is_bootstrap` is true.
        bootstrap_line: usize,
    };

    /// Classify an injected-coordinate line number. Lines in (0, injection_line_count]
    /// originate inside the auto-injected prelude (the user didn't write them);
    /// lines beyond that translate down to user coordinates.
    fn classifyLine(self: *ErrorReporter, line: usize) LineClass {
        if (line == 0) return .{ .line = 0, .is_bootstrap = false, .bootstrap_line = 0 };
        if (line <= self.injection_line_count) {
            return .{ .line = 0, .is_bootstrap = true, .bootstrap_line = line };
        }
        return .{ .line = line - self.injection_line_count, .is_bootstrap = false, .bootstrap_line = 0 };
    }

    /// Translate a parser-coordinate line into the user coordinate the renderer
    /// shows. A diagnostic that NAMES a second line inside its message text
    /// (e.g. "already bound at line N") must call this — the location it is
    /// reported AT goes through `classifyLine`, and an untranslated line in the
    /// prose would disagree with the caret by exactly the prelude's height.
    /// Returns 0 for a line inside the auto-injected bootstrap prelude.
    pub fn userLine(self: *ErrorReporter, line: usize) usize {
        return self.classifyLine(line).line;
    }

    /// `userLine` for a full SourceLocation, applying the SAME file guard
    /// `addErrorAtLocation` applies: a location in another file is already in
    /// that file's own user coordinates and must not be shifted. Use this for
    /// the SECOND position a multi-site diagnostic names in its prose, so the
    /// number the user reads and the caret they see are translated identically.
    pub fn userLineIn(self: *ErrorReporter, location: SourceLocation) usize {
        if (!std.mem.eql(u8, location.file, self.file_name)) return location.line;
        return self.classifyLine(location.line).line;
    }

    pub fn addError(self: *ErrorReporter, code: ErrorCode, line: usize, column: usize, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const cls = self.classifyLine(line);

        // Deduplicate: don't add if exact same error already exists
        for (self.errors.items) |existing| {
            if (existing.code == code and
                existing.location.line == cls.line and
                existing.location.column == column and
                existing.is_bootstrap == cls.is_bootstrap and
                existing.bootstrap_line == cls.bootstrap_line and
                std.mem.eql(u8, existing.message, message))
            {
                self.allocator.free(message);
                return;
            }
        }

        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = cls.line,
                .column = column,
                .file = self.file_name,
            },
            .hint = null,
            .is_bootstrap = cls.is_bootstrap,
            .bootstrap_line = cls.bootstrap_line,
        });
        dispatchDiag(&self.errors.items[self.errors.items.len - 1]);
    }

    /// Like addError, but uses the full SourceLocation (including file) from the caller
    /// instead of the reporter's file_name. Use this when errors can originate from
    /// multiple files (e.g. shape_checker validating flows with per-flow locations).
    /// Line translation only applies when the location's file matches our file_name —
    /// errors from imported files are already in their own user coordinates.
    pub fn addErrorAtLocation(self: *ErrorReporter, code: ErrorCode, location: SourceLocation, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        var loc = location;
        var is_bootstrap = false;
        var bootstrap_line: usize = 0;
        if (std.mem.eql(u8, loc.file, self.file_name)) {
            const cls = self.classifyLine(loc.line);
            loc.line = cls.line;
            is_bootstrap = cls.is_bootstrap;
            bootstrap_line = cls.bootstrap_line;
        }
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = loc,
            .hint = null,
            .is_bootstrap = is_bootstrap,
            .bootstrap_line = bootstrap_line,
        });
        dispatchDiag(&self.errors.items[self.errors.items.len - 1]);
    }

    /// Like addErrorAtLocation, but with a teaching hint. Use when errors can
    /// originate from multiple files AND the fix deserves guidance.
    pub fn addErrorAtLocationWithHint(self: *ErrorReporter, code: ErrorCode, location: SourceLocation, comptime fmt: []const u8, args: anytype, comptime hint_fmt: []const u8, hint_args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const hint = try std.fmt.allocPrint(self.allocator, hint_fmt, hint_args);
        var loc = location;
        var is_bootstrap = false;
        var bootstrap_line: usize = 0;
        if (std.mem.eql(u8, loc.file, self.file_name)) {
            const cls = self.classifyLine(loc.line);
            loc.line = cls.line;
            is_bootstrap = cls.is_bootstrap;
            bootstrap_line = cls.bootstrap_line;
        }
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = loc,
            .hint = hint,
            .is_bootstrap = is_bootstrap,
            .bootstrap_line = bootstrap_line,
        });
        dispatchDiag(&self.errors.items[self.errors.items.len - 1]);
    }

    pub fn addErrorWithHint(self: *ErrorReporter, code: ErrorCode, line: usize, column: usize, comptime fmt: []const u8, args: anytype, comptime hint_fmt: []const u8, hint_args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const hint = try std.fmt.allocPrint(self.allocator, hint_fmt, hint_args);
        const cls = self.classifyLine(line);
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = cls.line,
                .column = column,
                .file = self.file_name,
            },
            .hint = hint,
            .is_bootstrap = cls.is_bootstrap,
            .bootstrap_line = cls.bootstrap_line,
        });
        dispatchDiag(&self.errors.items[self.errors.items.len - 1]);
    }

    /// Like addErrorWithHint, but lets the caller declare how many characters
    /// the caret should span (e.g. 2 for `|>`). Use when the error is about a
    /// specific multi-char token and pointing at one column would understate
    /// the offending span.
    pub fn addErrorWithHintAndSpan(
        self: *ErrorReporter,
        code: ErrorCode,
        line: usize,
        column: usize,
        span_length: usize,
        comptime fmt: []const u8,
        args: anytype,
        comptime hint_fmt: []const u8,
        hint_args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const hint = try std.fmt.allocPrint(self.allocator, hint_fmt, hint_args);
        const cls = self.classifyLine(line);
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = cls.line,
                .column = column,
                .file = self.file_name,
            },
            .hint = hint,
            .span_length = span_length,
            .is_bootstrap = cls.is_bootstrap,
            .bootstrap_line = cls.bootstrap_line,
        });
        dispatchDiag(&self.errors.items[self.errors.items.len - 1]);
    }

    /// Renders only the errors not already emitted by an earlier call — see
    /// `printed_count`. Errors that arrive after a render still surface on the
    /// next one.
    pub fn printErrors(self: *ErrorReporter, writer: anytype) !void {
        for (self.errors.items[self.printed_count..]) |err| {
            try writer.print("error[{s}]: {s}\n", .{ @tagName(err.code), err.message });
            try writer.print("  --> {s}:{}:{}\n", .{ err.location.file, err.location.line, err.location.column });

            // Pick the right source slice for the preview block. Bootstrap
            // errors render from the auto-injected prelude so the user sees
            // the line they're being told about, even though they didn't
            // write it. Other errors render from the user source.
            const preview: ?struct { line: []const u8, line_no: usize } = blk: {
                if (err.is_bootstrap) {
                    if (self.bootstrap_source_lines) |bsl| {
                        if (err.bootstrap_line > 0 and err.bootstrap_line <= bsl.len) {
                            break :blk .{ .line = bsl[err.bootstrap_line - 1], .line_no = err.location.line };
                        }
                    }
                    break :blk null;
                }
                if (err.location.line > 0 and err.location.line <= self.source_lines.len) {
                    break :blk .{ .line = self.source_lines[err.location.line - 1], .line_no = err.location.line };
                }
                break :blk null;
            };

            if (preview) |p| {
                try writer.print("    |\n", .{}); // Match line number width
                try writer.print("{d: >3} | {s}\n", .{ p.line_no, p.line });
                try writer.print("    | ", .{}); // 4 spaces + " | " = 6 chars to match line prefix

                // Print caret pointing to error location
                // Column is 1-based, so we need column-1 spaces to point at column N
                if (err.location.column > 0) {
                    for (0..err.location.column - 1) |_| {
                        try writer.writeAll(" ");
                    }
                }
                const span = if (err.span_length == 0) 1 else err.span_length;
                for (0..span) |_| {
                    try writer.writeAll("^");
                }
                try writer.writeAll("\n");
            }

            // Print hint if present
            if (err.hint) |hint| {
                try writer.print("  hint: {s}\n", .{hint});
            }

            try writer.writeAll("\n");
        }
        if (self.errors.items.len > 0) diagnostics_were_printed = true;
        self.printed_count = self.errors.items.len;
    }

    pub fn hasErrors(self: *ErrorReporter) bool {
        return self.errors.items.len > 0;
    }
};

// Helper functions for common error messages

pub fn moduleNotFound(reporter: *ErrorReporter, line: usize, column: usize, import_path: []const u8) !void {
    try reporter.addErrorWithHint(
        .KORU002,
        line,
        column,
        "module not found: '{s}'",
        .{import_path},
        "check the import path, the aliases declared by std/compiler:paths, and KORU_STDLIB/KORU_PATH environment variables",
        .{},
    );
}

pub fn inlineFlowInProc(reporter: *ErrorReporter, line: usize, column: usize, snippet: []const u8) !void {
    try reporter.addErrorWithHint(
        .KORU003,
        line,
        column,
        "inline flows are not supported inside `~proc` bodies: {s}",
        .{snippet},
        "lift this into a top-level subflow (e.g. `~my_event = call(args) | branch x |> done {{}}`) or invoke the event from outside the proc body",
        .{},
    );
}

pub fn branchKindMismatch(
    reporter: *ErrorReporter,
    location: SourceLocation,
    branch_name: []const u8,
    decl_kind: enum { effect, terminal },
    cont_kind: enum { effect, terminal },
) !void {
    const decl_glyph: []const u8 = if (decl_kind == .effect) "!" else "|";
    const cont_glyph: []const u8 = if (cont_kind == .effect) "!" else "|";
    const decl_label: []const u8 = if (decl_kind == .effect) "effect" else "terminal";
    const cont_label: []const u8 = if (cont_kind == .effect) "effect" else "terminal";
    const message = try std.fmt.allocPrint(reporter.allocator, "branch '{s}' is declared as {s} `{s}` but the handler uses {s} `{s}`", .{ branch_name, decl_label, decl_glyph, cont_label, cont_glyph });
    const hint = try std.fmt.allocPrint(reporter.allocator, "match the handler glyph to the declaration: write `{s} {s} ... |> ...` to handle this branch", .{ decl_glyph, branch_name });
    try reporter.errors.append(reporter.allocator, .{
        .code = .KORU025,
        .message = message,
        .location = location,
        .hint = hint,
    });
}

pub fn redundantWhenParens(
    reporter: *ErrorReporter,
    line: usize,
    column: usize,
    condition: []const u8,
) !void {
    // Strip the outer parens for the hint preview.
    const stripped = if (condition.len >= 2 and condition[0] == '(' and condition[condition.len - 1] == ')')
        std.mem.trim(u8, condition[1 .. condition.len - 1], " \t")
    else
        condition;
    try reporter.addErrorWithHint(
        .KORU024,
        line,
        column,
        "redundant outer parens around `when` condition '{s}'",
        .{condition},
        "`when` already delimits the expression — drop the outer parens. Write `when {s}` instead. Inner parens for sub-expression grouping (e.g. `when foo == (a + b)`) remain legal.",
        .{stripped},
    );
}

pub fn terminalBeforeEffect(
    reporter: *ErrorReporter,
    line: usize,
    column: usize,
    branch_name: []const u8,
    context: enum { decl, dispatch },
) !void {
    const context_label: []const u8 = switch (context) {
        .decl => "branch",
        .dispatch => "handler",
    };
    const context_plural: []const u8 = switch (context) {
        .decl => "branches",
        .dispatch => "handlers",
    };
    try reporter.addErrorWithHint(
        .KORU023,
        line,
        column,
        "effect `!` {s} '{s}' appears after a terminal `|` {s}",
        .{ context_label, branch_name, context_label },
        "move `! {s}` above any `|` {s} — effect branches always come first (source order = temporal order: effects during run, then how it ends)",
        .{ branch_name, context_plural },
    );
}

/// Number agreement for a candidate list. One candidate is an instruction —
/// `Call: tx.exec` — while several are a choice set — `Call one of: a, b`.
/// Splice this between the verb and the colon (`"Call{s}: {s}"`) so a list of
/// one never reads as a choice among many.
pub fn oneOfInfix(count: usize) []const u8 {
    return if (count == 1) "" else " one of";
}

/// Write the candidates comma-separated into `out` and RETURN how many were
/// written, so a refusal's number agreement and the list it prints come from one
/// walk and cannot disagree.
///
/// GROWS, never truncates. It replaced eleven hand-rolled copies that each wrote
/// into a fixed `[512]u8`/`[1024]u8` buffer with the write error swallowed —
/// `catch {}` turned a full buffer into a PREFIX of the candidate set that read
/// as the whole set, so a refusal could name three of twenty disposers and look
/// complete. That is the fixed-buffer-ceiling class `FileSink` above records for
/// `printErrors`; it survived in the buffers that BUILD the message.
///
/// `keep`, when given, decides membership from `ctx` — the one caller that needs
/// it excludes the refusing flow's own event, which is recursion rather than a
/// discharge, and must exclude it by IDENTITY rather than by the tail rendered
/// here.
pub fn writeCandidateNames(
    comptime T: type,
    comptime nameOf: fn (T) []const u8,
    comptime keep: ?fn (T, []const u8) bool,
    ctx: []const u8,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    items: []const T,
) !usize {
    var written: usize = 0;
    for (items) |item| {
        if (keep) |k| {
            if (!k(item, ctx)) continue;
        }
        if (written > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, nameOf(item));
        written += 1;
    }
    return written;
}

/// The canonical sink for `printErrors`.
///
/// It exists because `printErrors` takes `anytype`, and an `anytype` with no
/// shipped implementation is an invitation: four call sites hand-rolled this
/// struct, three of them were wrong, and they were wrong in TWO different ways —
/// a fixed-buffer ceiling that killed the compiler mid-diagnostic, and a
/// positional writer that silently overwrote everything but the last message.
/// None could be tested, because each was a local struct inside the function
/// that used it. One sink, one test, one place left to be wrong.
///
/// STREAMING, never positional. `File.writer` tracks an offset, and since a
/// fresh writer is built per call, positional writes restart at 0 and clobber
/// the previous message whenever stderr is a seekable file — exactly how the
/// harness captures it, and never how a terminal behaves. The buffer is a
/// window rather than a ceiling: a long diagnostic costs extra writes, never a
/// failure.
pub const FileSink = struct {
    file: std.fs.File,

    pub fn stderr() FileSink {
        return .{ .file = std.fs.File.stderr() };
    }

    pub fn print(self: FileSink, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        var w = self.file.writerStreaming(&buf);
        try w.interface.print(fmt, args);
        try w.interface.flush();
    }

    pub fn writeAll(self: FileSink, bytes: []const u8) !void {
        try self.file.writeAll(bytes);
    }
};

test "FileSink survives a diagnostic longer than its buffer, written to a FILE" {
    // A FILE, not a pipe and not a terminal: positional writes degrade to
    // appends on a terminal, so a terminal probe certifies a broken sink.
    // Belief: frag-a-probe-must-match-how-the-artifact-is-consumed.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const filler = "0123456789" ** 600; // 6000 bytes — well past the 4096 window
    const between = "----between----\n";

    {
        const f = try tmp.dir.createFile("sink.txt", .{});
        defer f.close();
        const sink = FileSink{ .file = f };
        // THREE separate print() calls: the sink builds a fresh writer per
        // call, which is the precise shape that made positional writes clobber
        // one another. One call would pass even with the bug.
        try sink.print("AAAA{s}AAAA\n", .{filler});
        try sink.writeAll(between);
        try sink.print("BBBB{s}BBBB\n", .{filler});
        try sink.print("CCCC{s}CCCC\n", .{filler});
    }

    const content = try tmp.dir.readFileAlloc(std.testing.allocator, "sink.txt", 1 << 20);
    defer std.testing.allocator.free(content);

    // Exact length catches BOTH historical failures at once: a ceiling writes
    // nothing (or dies), and an overwrite leaves only the final message.
    const one_message = 4 + filler.len + 4 + 1;
    try std.testing.expectEqual(one_message * 3 + between.len, content.len);

    // ...and order, so a sink that emits every byte in the wrong sequence fails.
    const a = std.mem.indexOf(u8, content, "AAAA").?;
    const b = std.mem.indexOf(u8, content, between).?;
    const c = std.mem.indexOf(u8, content, "BBBB").?;
    const d = std.mem.indexOf(u8, content, "CCCC").?;
    try std.testing.expect(a < b and b < c and c < d);
}

/// Test sink: `printErrors` takes `anytype`, so the pin needs a writer with
/// `print`/`writeAll` that lands in a countable buffer rather than a FILE.
const ListSink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn print(self: ListSink, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.list.appendSlice(self.allocator, s);
    }

    pub fn writeAll(self: ListSink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

test "printErrors renders each diagnostic once across repeated calls" {
    // The compilation's reporter is shared across passes: a pass gate that
    // self-prints on failure (auto_discharge_inserter's hasErrors bail-outs)
    // is re-rendered by the pipeline's failure catch in compiler.kz. Without
    // the watermark every diagnostic on those paths landed twice — KORU080
    // doubled on `window.open` missing its inputs (2026-09-12).
    var reporter = try ErrorReporter.init(std.testing.allocator, "input.k", "a\nb\n");
    defer reporter.deinit();

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer buf.deinit(std.testing.allocator);
    const sink = ListSink{ .list = &buf, .allocator = std.testing.allocator };

    try reporter.addError(.KORU080, 1, 1, "first message", .{});
    try reporter.addError(.KORU080, 2, 1, "second message", .{});
    try reporter.printErrors(sink);
    const after_first = buf.items.len;
    try std.testing.expect(after_first > 0);

    // The driver's catch re-render must emit nothing new.
    try reporter.printErrors(sink);
    try std.testing.expectEqual(after_first, buf.items.len);

    // Errors arriving after a render still surface on the next one.
    try reporter.addError(.KORU080, 2, 5, "third message", .{});
    try reporter.printErrors(sink);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf.items, "first message"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf.items, "second message"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf.items, "third message"));
}

/// Test-only twins of what callers pass: `writeCandidateNames` takes a plain fn,
/// and these tests already hold rendered names.
fn testIdentityName(name: []const u8) []const u8 {
    return name;
}

fn testNameIsNotContext(name: []const u8, ctx: []const u8) bool {
    return !std.mem.eql(u8, name, ctx);
}

test "candidate names render whole past the buffer ceiling they replaced" {
    // The eleven sites this writer replaced each wrote into a fixed
    // `[512]u8`/`[1024]u8` buffer with the write error swallowed, so a longer
    // candidate set printed a PREFIX that read as the whole set. Sixty 20-byte
    // names join to 1318 bytes — past both ceilings — so no fixed buffer can
    // pass this test at any size, which is the point: the list grows with the
    // candidate set instead of the candidate set being clipped to the list.
    const name = "mod:long_disposer_x";
    var names: [60][]const u8 = undefined;
    for (&names) |*n| n.* = name;

    var out = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer out.deinit(std.testing.allocator);
    const written = try writeCandidateNames([]const u8, testIdentityName, null, "", std.testing.allocator, &out, &names);

    try std.testing.expectEqual(names.len, written);
    // Length is exact, not merely large: every name once, one separator between
    // neighbours — a dropped name and a doubled separator cannot both hide.
    try std.testing.expectEqual(60 * name.len + 59 * 2, out.items.len);
    try std.testing.expectEqual(@as(usize, 60), std.mem.count(u8, out.items, name));
}

test "candidate writer counts what it wrote, not what it was handed" {
    // The refusal's number agreement reads this count, so it has to describe the
    // printed list. The one caller with an exclusion (the refusing flow's own
    // event, which is recursion rather than a discharge) hands over three items
    // and must get "one of" language for two.
    const items = [_][]const u8{ "input:drop", "solo", "std.string:free" };

    var out = try std.ArrayList(u8).initCapacity(std.testing.allocator, 0);
    defer out.deinit(std.testing.allocator);
    const written = try writeCandidateNames([]const u8, testIdentityName, testNameIsNotContext, "solo", std.testing.allocator, &out, &items);

    try std.testing.expectEqual(@as(usize, 2), written);
    try std.testing.expectEqualStrings("input:drop, std.string:free", out.items);
}
