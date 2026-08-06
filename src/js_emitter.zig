// js_emitter.zig — minimal, pump.kz-shaped Koru → JavaScript emitter.
//
// SCOPE: this is the JS-target spike. It walks `ctx.ast` (a *const ast.Program)
// and emits runnable JavaScript for the vaxis-shaped event pump in
// `_phase1/pump.kz`. It mirrors the structure of the Zig emitter
// (visitor_emitter.zig + emitter_helpers.zig) but rewrites every output site as
// JS. It handles EXACTLY the constructs pump.kz uses:
//
//   - event decls → `<name>_event: { handler(__koru_input, H?) { ... } }`
//   - effect-bearing events take an `H` param and bind `const op = H.op;` for
//     each effect branch op; plain events take only the payload.
//   - `|js` proc bodies, spliced verbatim (opaque host code) after binding
//     input fields as `const field = __koru_input.field;`.
//   - top-level flows → `flowN()` methods: synthesize a `Handlers_N` struct from
//     the `!`-effect continuations, call the event handler, then drive terminal
//     `|`-continuations (read `.branch` off the result, emit the body).
//
// It is deliberately NARROW. Taps, modules, comptime, meta-events, koru_ wrappers
// are skipped entirely. Anything irrelevant to pump.kz is omitted. Emission is
// AST-derived (event names, fields, proc bodies come from ctx.ast), NOT a
// hardcoded output string. Generality is a later phase.
//
// FAIL LOUD: when the emitter hits a construct it does not model (e.g. an
// invocation it can't resolve to an event decl), it returns an error rather than
// silently emitting wrong code.

const std = @import("std");
const ast = @import("ast");
const log = @import("log");
const file_types = @import("file_types");
const annotation_parser = @import("annotation_parser");
/// The ONE Koru struct-literal projector, shared with the parser, the Zig emitter
/// and the template engine. Reading a `{ … }` literal with a second brace-splitter
/// is how two hosts' answers drift.
const struct_literal = @import("struct_literal");

pub const JsEmitError = error{
    OutOfMemory,
    UnresolvedEvent,
    UnsupportedConstruct,
    NoJsProcBody,
};

/// The variant-tag string this emitter targets. It is the SAME namespace as
/// `--lang` / `proc.target` / `file_types.hostLangOfFile`, so it selects both
/// a `|js` proc body and a `.kjs` host line. One vocabulary, two surfaces.
const JS_TARGET = "js";

/// The handler's payload parameter. RESERVED, not `input`: an event may declare a
/// field literally named `input` (`sanitize { input: string }`, 330_068), and
/// `handler(input) { const input = input.input; }` is a redeclaration JavaScript
/// refuses outright. Every field is bound as a local off this parameter, so host
/// code never spells it — the same reason the Zig emitter reserves
/// `__koru_event_input`.
const INPUT_PARAM = "__koru_input";

/// Emit JS for the given program. Returns a heap-allocated string owned by the
/// caller's allocator.
pub fn emit(allocator: std.mem.Allocator, program: *const ast.Program) JsEmitError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var em = Emitter{ .allocator = allocator, .buf = &buf, .items = program.items, .main_module_name = program.main_module_name };

    // Prelude: Koru's slice-length surface, `.len`.
    //
    // A declarative Koru body is host-agnostic and is emitted VERBATIM — so
    // `~len -> s.data.len` (koru_std/string.kz) and `{{ r.len:d }}`
    // (240_020_args_basic) reach the JavaScript output still spelled `.len`,
    // while JS spells it `.length`. Translating the access instead would be a
    // guess: `.len` is also a legal field name on a user record, and the
    // emitter cannot tell the two apart.
    //
    // So the length surface is put on the VALUES, as a non-enumerable getter
    // that an own `len` property shadows. `[]const u8` is a js string and
    // `[]T` is a js array (the whole point of not modelling a slice as
    // `{ptr,len}`), so those are the two prototypes that owe it. Without this
    // the read is not an error — it is `undefined`, printed as the answer.
    try em.write(
        \\const __koru_len = { get() { return this.length; }, configurable: true };
        \\Object.defineProperty(String.prototype, "len", __koru_len);
        \\Object.defineProperty(Array.prototype, "len", __koru_len);
        \\
    );

    // Phase 0: emit host lines whose host language is JS, verbatim, at the TOP
    // of the output (before main_module). This carries module-level JS state
    // (`const`/`let` declarations) that the flows and proc bodies reference.
    //
    // Routing is by HOST LANGUAGE, not by a hardcoded extension: a host line
    // and a |js proc body are both host bytes, so we select them the same way
    // the proc selector does (`proc.target == "js"`). `hostLangOfFile` resolves
    // the line's source file to the same variant-tag namespace, so a `.kz`
    // file's Zig host line resolves to "zig" and is skipped (it would be
    // invalid JS), while a `.kjs` line resolves to "js" and passes through.
    // Synthesized lines (`location.file == "generated"`) resolve to null and
    // are skipped — they're host-agnostic compiler infrastructure the JS
    // target doesn't need.
    //
    // IMPORTED modules count. An import lands as a `module_decl` whose items
    // hold the merged facets, so a top-level-only scan saw the ENTRY's `.kjs`
    // host lines and none of `koru_std/*.kjs`'s — state a stdlib facet declares
    // would silently vanish and its procs would read `undefined` three frames
    // away. Descend, exactly as `emitModuleEventDecls` does for events.
    try emitJsHostLines(&em, program.items);

    // Phase 0.5: module-scope `[declaration]` flows (Koru-native `const {}`).
    // A declaration introduces names into the ENCLOSING scope, not a statement
    // into a function body. JS's shared scope is the module top level — an object
    // literal can't hold bare `const` statements — so splice the rendered decls
    // here, above `const main_module`, where every flow and proc body sees them
    // via closure. Mirrors the Zig emitter splicing them into the main_module
    // struct (visitor_emitter.zig:1170). The flow is NOT emitted as a flowN()
    // method and NOT invoked (it declares, it doesn't execute) — Phase 2 skips it
    // via the same isDeclarationFlow check, so flow numbering stays in sync.
    for (program.items) |*item| {
        if (item.* != .flow) continue;
        if (!em.isDeclarationFlow(&item.flow)) continue;
        const body = stripInlineStmtMarker(item.flow.inline_body.?);
        // Through the host-text lowering, like every other spliced fragment. This
        // was the one splice site that wrote raw, so a value the `const` template
        // rendered as a Zig cast (`const threshold = @as(i32, 5);`) reached the JS
        // file with the `@` intact — a syntax error at `node`, three passes away
        // from the site that wrote it.
        try em.writeHostText(std.mem.trim(u8, body, " \t\r\n"));
        try em.write("\n");
    }

    // Phase 0.6: TOP-LEVEL `.inline_code` — host declarations a comptime
    // transform appended beside the site it rewrote (`std/regex:match` appends
    // its compiled matcher functions this way; the Zig emitter emits them from
    // visitor_emitter.zig:1517).
    //
    // The JS emitter handled `.inline_code` only as a flow PREAMBLE, so a
    // transform's appended declarations were dropped in silence and the dispatch
    // it also emitted called functions that were never defined — a ReferenceError
    // at run time, with nothing wrong at the call site to look at.
    //
    // Emitted here, at module scope above `main_module`, because these are
    // DECLARATIONS shared by every flow that uses them, exactly like Phase 0.5's
    // `const {}` decls. Written raw rather than through the host-text lowering:
    // this text was produced by a `|js` transform and is already JavaScript.
    try emitTopLevelInlineCode(&em, program.items);

    try em.write("const main_module = {\n");

    // Which module events the emitted program actually REACHES. Computed before
    // anything is written, because Phase 1b needs it to tell an event nobody
    // wants (skip in silence) from one a call site is about to dispatch to
    // (must account for itself). See collectReachedEvents.
    var reached = ReachedEvents.init(allocator);
    defer reached.deinit();
    try em.collectReachedEvents(&reached);

    // Every `<name>_event` key written into main_module so far. JS object keys
    // are a FLAT namespace while Koru event paths are not, so two modules'
    // same-named events lower to one key and the later write silently wins.
    // Phase 1b consults this before writing a refusal stub: a stub must never
    // be the thing that clobbers a working handler.
    var emitted_keys = EmittedKeys.init(allocator);
    defer {
        var it = emitted_keys.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        emitted_keys.deinit();
    }

    // Phase 1: emit each top-level event decl as an object member.
    for (program.items) |*item| {
        if (item.* == .event_decl) {
            try em.emitEventDecl(&item.event_decl, program.items);
            try em.claimEventKey(&emitted_keys, &item.event_decl);
        }
    }

    // Phase 1b: emit event decls living in IMPORTED MODULES (e.g. `std.io`, a
    // `$app/contract` companion). Gated on transitive JS-implementability, with
    // a self-naming refusal for anything reached but unlowerable.
    for (program.items) |*item| {
        if (item.* != .module_decl) continue;
        try em.emitModuleEventDecls(&item.module_decl, &reached, &emitted_keys);
    }

    // Phase 2: emit each top-level flow as a flowN() method.
    var flow_num: usize = 0;
    for (program.items) |*item| {
        if (item.* == .flow) {
            // Subflow implementations (impl_of != null) are handled inside the
            // abstract event handler, not as standalone flows. pump.kz has none,
            // but mirror the Zig walk's skip for correctness.
            if (item.flow.impl_of != null) continue;
            // `[declaration]` flows (Koru-native `const {}`) were spliced at
            // module scope in Phase 0.5 — never emit them as a flowN() method or
            // invoke them (they declare, they don't execute).
            if (em.isDeclarationFlow(&item.flow)) continue;
            // Skip injected meta-event flows (koru:start / koru:end). These are
            // compiler infrastructure, not user code; the spike emits only the
            // user pump. They live in the `koru` module-qualifier namespace.
            if (item.flow.inv().path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "koru")) continue;
            }
            try em.emitFlow(&item.flow, flow_num);
            flow_num += 1;
        }
    }

    try em.write("};\n");

    // Invoke every emitted flow at the end (mirrors the Zig emitter's main()).
    for (0..flow_num) |i| {
        try em.writeFmt("main_module.flow{d}();\n", .{i});
    }

    return buf.toOwnedSlice(allocator);
}

/// Phase 0's walker: every `.kjs`-sourced host line in `items`, in order,
/// descending through `module_decl` so an imported facet's module-level JS
/// state reaches the output alongside the entry file's.
fn emitJsHostLines(em: *Emitter, items: []const ast.Item) JsEmitError!void {
    for (items) |*item| {
        switch (item.*) {
            .host_line => |*line| {
                const host = file_types.hostLangOfFile(line.location.file) orelse continue;
                if (!std.mem.eql(u8, host, JS_TARGET)) continue;
                try em.write(line.content);
                try em.write("\n");
            },
            .module_decl => |*m| try emitJsHostLines(em, m.items),
            else => {},
        }
    }
}

/// Every top-level `.inline_code` item, descending through `module_decl` so a
/// transform that rewrote a site inside an imported module gets its appended
/// declarations out too (`115_003_regex_scan_in_module` is exactly that shape).
/// Flow bodies are NOT walked: an `.inline_code` inside one is a preamble and is
/// emitted at its own site.
fn emitTopLevelInlineCode(em: *Emitter, items: []const ast.Item) JsEmitError!void {
    for (items) |*item| {
        switch (item.*) {
            .inline_code => |*ic| {
                try em.write(ic.code);
                try em.write("\n");
            },
            .module_decl => |*m| try emitTopLevelInlineCode(em, m.items),
            else => {},
        }
    }
}

/// Event decls the emitted program reaches, by POINTER identity — two modules may
/// declare the same path, and only the pointer distinguishes them.
const ReachedEvents = std.AutoHashMap(*const ast.EventDecl, void);

/// The `<name>_event` keys already written into `main_module`. JS object keys are
/// one flat namespace; Koru event paths are not.
const EmittedKeys = std.StringHashMap(void);

const Emitter = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    items: []const ast.Item,
    /// The program's main module name. Used by the module-aware path matcher to
    /// resolve a qualified call (`std.io:println`) that targets the main module.
    main_module_name: []const u8 = "",
    /// Monotonic counter for unique `Handlers_<id>` / `result_<id>` names so
    /// nested dispatch frames never collide.
    id_counter: usize = 0,
    /// The event whose SUBFLOW impl body is currently being emitted, or null
    /// outside one. A call to one of that event's own effect arms is a FIRING,
    /// not an event invocation, and only this context can tell them apart —
    /// the twin of EmissionContext.impl_event_decl (emitter_helpers.zig:6902).
    impl_event: ?*const ast.EventDecl = null,
    /// The `#label` fold currently being emitted, or null outside one. A `@label(…)`
    /// jump re-seeds the fold's state variables and re-runs its head, and only the
    /// frame that opened the loop knows their names — the twin of
    /// EmissionContext.label_handler_invocation / .label_result_var
    /// (emitter_helpers.zig:5203).
    ///
    /// A POINTER into the emitting stack, not a value: folds nest, and a jump
    /// names a label rather than a depth. Each `emitLabelFoldAt` links its frame
    /// to the one it is nested inside, so resolving `@outer(…)` from an inner fold
    /// is a walk out through the chain. That chain IS the label map the Zig
    /// emitter keeps explicitly (emitter_helpers.zig:5157); here the emitting
    /// recursion already has the right shape, so it costs no allocation.
    label_frame: ?*const LabelFrame = null,

    const LabelFrame = struct {
        label: []const u8,
        /// The `let result_<id>` the fold reassigns on every turn.
        result_name: []const u8,
        /// The head invocation to re-run. Its arg NAMES are the fold's parameters.
        inv: *const ast.Invocation,
        /// The fold this one sits inside, or null at the outermost.
        outer: ?*const LabelFrame = null,
    };

    fn nextId(self: *Emitter) usize {
        const id = self.id_counter;
        self.id_counter += 1;
        return id;
    }

    fn write(self: *Emitter, text: []const u8) JsEmitError!void {
        try self.buf.appendSlice(self.allocator, text);
    }

    fn writeFmt(self: *Emitter, comptime fmt: []const u8, args: anytype) JsEmitError!void {
        try self.buf.print(self.allocator, fmt, args);
    }

    /// Identifier formation boundary: names are kebab-canonical in the
    /// pipeline; a dash lowers to underscore only while writing a JS
    /// identifier. Mirrors emitter_helpers.writeBranchName for the Zig target.
    fn writeIdent(self: *Emitter, name: []const u8) JsEmitError!void {
        for (name) |c| {
            try self.buf.append(self.allocator, if (c == '-') '_' else c);
        }
    }
    /// Read a property whose KEY is written raw. A BRANCH name is kebab-canonical
    /// and stays that way on both the tag and the payload key
    /// (`emitBranchConstructorReturn`, so producer and reader cannot drift) — but
    /// `result.next-outer` parses as `result.next - outer`, a subtraction against
    /// an undeclared name. Bracket notation is the only spelling that reads a key
    /// JS cannot say as an identifier, so the dot form is used exactly when it is
    /// legal.
    fn writeMember(self: *Emitter, base: []const u8, key: []const u8) JsEmitError!void {
        try self.write(base);
        if (isJsIdentifier(key)) {
            try self.write(".");
            try self.write(key);
            return;
        }
        try self.write("[\"");
        try self.write(key);
        try self.write("\"]");
    }

    /// Buffer variant of the same boundary, for sites that need the lowered
    /// identifier as a string (format args, host-text searches — host JS can
    /// only ever spell the lowered form).
    fn lowerIdentBuf(buf: []u8, name: []const u8) []const u8 {
        @memcpy(buf[0..name.len], name);
        for (buf[0..name.len]) |*c| {
            if (c.* == '-') c.* = '_';
        }
        return buf[0..name.len];
    }

    /// Find the |js proc for `event_path` WITHIN a given item scope (segment-
    /// equal). Scope matters: a module's event resolves to the proc in that same
    /// module, never a same-named proc in a sibling module. Mirrors the Zig
    /// emitter's proc-selection but keys on target == "js".
    fn findJsProcIn(self: *Emitter, scope: []const ast.Item, event_path: *const ast.DottedPath) ?*const ast.ProcDecl {
        _ = self;
        for (scope) |*item| {
            if (item.* != .proc_decl) continue;
            const proc = &item.proc_decl;
            if (proc.path.segments.len != event_path.segments.len) continue;
            var match = true;
            for (proc.path.segments, event_path.segments) |sa, sb| {
                if (!std.mem.eql(u8, sa, sb)) {
                    match = false;
                    break;
                }
            }
            if (!match) continue;
            const target = proc.target orelse continue;
            if (!std.mem.eql(u8, target, JS_TARGET)) continue;
            // A `|js` TAG MEANS TWO DIFFERENT THINGS, and this is the seam where
            // confusing them produces Zig source inside emitted JavaScript.
            //
            // On a runtime proc, `|js` says "this body IS JavaScript, splice it".
            // On a [transform] proc it says "this variant EMITS JavaScript" — the
            // body is Zig, it runs inside the compiler at Stage C, and it has no
            // runtime existence at all. Splicing it emitted `const ast =
            // @import("ast");` into the output and node refused the file.
            //
            // A transform therefore has no `|js` runtime body by construction, so
            // this returns null and the caller keeps the ordinary
            // no-JS-implementation refusal — which is the honest answer for a
            // compile-time construct that is already gone by runtime.
            if (annotation_parser.hasPart(proc.annotations, "transform")) continue;
            return proc;
        }
        return null;
    }

    /// Resolve an invocation path to its event decl, descending into imported
    /// modules. A flow's call site is often module-qualified (`std.io:println`)
    /// while the declaration inside the module is unqualified — the match is
    /// reconciled by `pathsEqualWithModule` against the module's logical_name.
    /// Mirrors visitor_emitter.zig:findEventDeclInItemsWithModule.
    fn findEventDecl(self: *Emitter, path: *const ast.DottedPath) ?*const ast.EventDecl {
        return self.findEventDeclIn(self.items, path, null);
    }

    /// A `[declaration]` flow (Koru-native `const {}`) introduces names into the
    /// enclosing scope rather than executing. Detected via the flow's resolved
    /// event-decl annotation — mirrors visitor_emitter.zig's `declaration`
    /// handling. Such flows are hoisted to module scope (Phase 0.5) instead of
    /// being emitted/invoked as flowN() methods.
    fn isDeclarationFlow(self: *Emitter, flow: *const ast.Flow) bool {
        if (flow.inline_body == null) return false;
        const decl = self.findEventDecl(&flow.inv().path) orelse return false;
        return annotation_parser.hasPart(decl.annotations, "declaration");
    }
    fn findEventDeclIn(self: *Emitter, scope: []const ast.Item, path: *const ast.DottedPath, current_module: ?[]const u8) ?*const ast.EventDecl {
        for (scope) |*item| {
            switch (item.*) {
                .event_decl => |*e| {
                    if (pathsEqualWithModule(&e.path, path, current_module, self.main_module_name)) return e;
                },
                .module_decl => |*m| {
                    if (self.findEventDeclIn(m.items, path, m.logical_name)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }

    /// How an event's behaviour is supplied. Koru has FOUR spellings for it and
    /// the Zig emitter honours all four off the same item list — a `|js`/`|zig`
    /// proc (visitor_emitter.zig:2682), an immediate/arrow impl (:2817), a subflow
    /// flow whose `impl_of` names the event (:2918), and a `|template|` proc whose
    /// body has already been spliced into every call site (:3730). The JS target
    /// reads the same four; treating "no proc" as "no body" mistook one spelling
    /// for the whole grammar.
    const EventImpl = union(enum) {
        /// `~proc name|js { … }` — opaque host JavaScript, spliced verbatim.
        proc: *const ast.ProcDecl,
        /// `~proc name|template|js { … }` — a PER-CALL template. template_processor
        /// already rendered it into every call site, so the decl-site handler is
        /// dead and its body is template text, not JavaScript.
        template_stub: *const ast.ProcDecl,
        /// `name -> expr` (bare return) or `name => branch { … }` (constructor).
        immediate: *const ast.ImmediateImpl,
        /// `name = other(…) | b => outcome` — a flow implementing this event.
        subflow: *const ast.Flow,
    };

    /// Resolve an event's implementation WITHIN a given item scope, in this order:
    /// `|js` proc first (a target-specific host body wins over the portable one),
    /// then an immediate/arrow impl, then a subflow, and LAST a `|template|` proc.
    ///
    /// Template is last on purpose: it is not a body, it is the absence of one at
    /// the decl site. Any real implementation standing beside it must win, so the
    /// stub is only ever reached when nothing else supplies behaviour.
    ///
    /// Only when all four are absent does the event genuinely have no body here.
    fn findImplIn(self: *Emitter, scope: []const ast.Item, event_path: *const ast.DottedPath) ?EventImpl {
        if (self.findJsProcIn(scope, event_path)) |proc| return .{ .proc = proc };

        for (scope) |*item| {
            if (item.* != .immediate_impl) continue;
            if (pathsEqual(&item.immediate_impl.event_path, event_path)) {
                return .{ .immediate = &item.immediate_impl };
            }
        }

        for (scope) |*item| {
            if (item.* != .flow) continue;
            const flow = &item.flow;
            const impl_of = flow.impl_of orelse continue;
            // A `|variant` arm is a call-site SELECTION, not the default body.
            // The Zig emitter skips it at this same spot (visitor_emitter.zig:2924).
            if (flow.impl_variant != null) continue;
            if (pathsEqual(&impl_of, event_path)) return .{ .subflow = flow };
        }

        for (scope) |*item| {
            if (item.* != .proc_decl) continue;
            const proc = &item.proc_decl;
            if (!pathsEqual(&proc.path, event_path)) continue;
            const target = proc.target orelse continue;
            if (templateProcTargetsJs(target)) return .{ .template_stub = proc };
        }

        return null;
    }

    /// Emit one event decl as `<name>_event: { handler(input, H?) { ... } }`.
    /// `scope` is the item list to resolve the implementation within (the program
    /// for top-level events, the module's items for a module event).
    fn emitEventDecl(self: *Emitter, event: *const ast.EventDecl, scope: []const ast.Item) JsEmitError!void {
        const impl = self.findImplIn(scope, &event.path) orelse {
            // No proc, no arrow, no subflow — the event has no body on any target.
            log.err("[js_emitter] event '{s}' has no |js proc, immediate, or subflow body\n", .{event.path.segments[event.path.segments.len - 1]});
            return JsEmitError.NoJsProcBody;
        };

        const name = event.path.segments[event.path.segments.len - 1];

        var has_effect = false;
        for (event.branches) |b| {
            if (b.kind == .effect) {
                has_effect = true;
                break;
            }
        }

        var name_buf: [256]u8 = undefined;
        try self.writeFmt("  {s}_event: {{\n", .{lowerIdentBuf(&name_buf, name)});
        if (has_effect) {
            try self.writeFmt("    handler({s}, H) {{\n", .{INPUT_PARAM});
            // Bind each effect-branch op as a local: `const tick = H.tick;`
            for (event.branches) |b| {
                if (b.kind != .effect) continue;
                try self.write("      const ");
                try self.writeIdent(b.name);
                try self.write(" = H.");
                try self.writeIdent(b.name);
                try self.write(";\n");
            }
        } else {
            try self.writeFmt("    handler({s}) {{\n", .{INPUT_PARAM});
        }

        // Bind input fields as locals: `const n = __koru_input.n;`. Every impl kind
        // reads its inputs by bare name, so this precedes all four bodies —
        // the same reason the Zig emitter re-emits the bindings per arm.
        //
        // A field with a DEFAULT (`{ a: i32, b: i32 = 5 }`) applies it here, at the
        // declaration, not at each call site: the default belongs to the event, and
        // one place cannot disagree with itself. Zig gets this free from a struct
        // field default; JS has no such thing, so the handler supplies it.
        // Both sides lower: a kebab field (`outer-val`) is not a JS identifier, and
        // the call site writes the same lowered key (`emitArgsObject`), so producer
        // and reader agree on `outer_val` — which is also what a `|js` proc body
        // can spell.
        for (event.input.fields) |field| {
            try self.write("      const ");
            try self.writeIdent(field.name);
            try self.writeFmt(" = {s}.", .{INPUT_PARAM});
            try self.writeIdent(field.name);
            if (field.default) |dflt| {
                try self.write(" ?? ");
                try self.writeJsExpr(dflt);
            }
            try self.write(";\n");
        }

        switch (impl) {
            // Opaque host code — splice verbatim, re-indented.
            .proc => |proc| {
                try self.emitReindented(proc.body.text, "      ");
                try self.write("\n");
            },
            // A per-call `|template|` proc was rendered into every call site by
            // template_processor before the emitter ran, so the decl-site handler
            // is dead code and its body is template text. Emit a stub that NAMES
            // itself: reaching it means a call site was missed, and a stub that
            // throws says so, where a silent skip would surface three frames away
            // as `.handler` on `undefined`. Zig writes `unreachable` here
            // (visitor_emitter.zig:3730).
            .template_stub => try self.writeFmt(
                "      throw new Error(\"{s}: |template| proc is inlined at call sites and must never be called\");\n",
                .{name},
            ),
            .immediate => |ii| try self.emitBranchConstructorReturn(&ii.value, "      "),
            .subflow => |flow| try self.emitSubflowImplBody(event, flow, "      "),
        }
        try self.write("    },\n  },\n");
    }

    /// Emit `return <value>;` for a BranchConstructor — the shared shape behind
    /// an immediate impl (`greet -> "hi"`, `step => continue`) and a subflow arm
    /// that produces an outcome (`| break => stopped`). Mirrors
    /// visitor_emitter.zig:2861-2912 retargeted:
    ///
    ///   `-> expr`          → `return <expr>;`                     (no tag)
    ///   `=> b`             → `return { tag: "b" };`
    ///   `=> b v`           → `return { tag: "b", b: v };`
    ///   `=> b { f: v, … }` → `return { tag: "b", b: { f: v, … } };`
    ///
    /// The tagged shape is exactly what the consuming side already reads
    /// (`result.tag` / `result.<branch>` in emitTerminalContinuation) and what a
    /// hand-written `|js` proc returns (pinned by 140_013). Branch names are
    /// written RAW on both key and tag so producer and reader cannot drift.
    fn emitBranchConstructorReturn(self: *Emitter, bc: *const ast.BranchConstructor, indent: []const u8) JsEmitError!void {
        if (bc.is_bare_return) {
            try self.writeFmt("{s}return ", .{indent});
            if (bc.plain_value) |pv| {
                try self.writeProduceValue(pv);
            } else {
                try self.write("undefined");
            }
            try self.write(";\n");
            return;
        }

        try self.writeFmt("{s}return {{ tag: \"{s}\"", .{ indent, bc.branch_name });
        if (bc.plain_value) |pv| {
            try self.writeFmt(", {s}: ", .{bc.branch_name});
            try self.writeProduceValue(pv);
        } else if (bc.fields.len > 0) {
            try self.writeFmt(", {s}: {{ ", .{bc.branch_name});
            for (bc.fields, 0..) |field, k| {
                if (k > 0) try self.write(", ");
                try self.writeFmt("{s}: ", .{field.name});
                // A field carries either a written expression or, in the
                // punned/positional form, the value in the `type` slot — the
                // same either/or the Zig emitter reads at :2898.
                try self.writeJsExpr(if (field.expression_str) |e| e else field.type);
            }
            try self.write(" }");
        }
        try self.write(" };\n");
    }

    /// A produce value is either an expression or a Koru STRUCT LITERAL written in
    /// braces (`-> { final.sum, final.max }` satisfying `-> { sum: i32, max: i32 }`).
    /// The braced form is re-emitted as a JS object literal under the pun law — a
    /// bare path names the field by its last segment.
    ///
    /// Without this the braces passed through verbatim, so a punned literal reached
    /// `node` as `return { final.sum, final.max };` — not a diagnostic, not a wrong
    /// answer, a SYNTAX error, from the one emitter whose stated contract is to
    /// refuse rather than emit code it does not model. A literal that already spells
    /// its names (`-> { a: 1 }`) parses to the same text it started as, which is why
    /// this was invisible until a pun turned up.
    ///
    /// WHICH braced values are records is decided by `struct_literal`'s predicates
    /// — the same pair `parser.zig:7009` reads to classify a produce and
    /// `emitter_helpers.emitValue:7965` reads to emit one for Zig. Everything else
    /// in braces is PLAIN-VALUE BRACES: `{ r }`, `{ a + b }` — punctuation around
    /// an expression, unwrapped, never an object.
    ///
    /// Deciding that here instead, off `parseFields`' own singleton-pun rule, was
    /// a second definition of the same law, and it drifted: `-> { r }` on a
    /// `-> i32` tor emitted `{ r: r }` against Zig's `r`, so 100_085 ran and
    /// printed `[object Object]`. A wrong answer, not a crash.
    ///
    /// A value that is not braced at all — an arithmetic expression, a string, a
    /// call — passes through as before.
    fn writeProduceValue(self: *Emitter, value: []const u8) JsEmitError!void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
            return self.writeJsExpr(value);
        }
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        if (inner.len > 0 and struct_literal.isBracedPlainExpression(trimmed)) {
            return self.writeJsExpr(inner);
        }
        const fields = struct_literal.parseFields(self.allocator, trimmed) catch
            return self.writeJsExpr(value);
        if (fields.len == 0) return self.writeJsExpr(value);
        try self.write("{ ");
        for (fields, 0..) |f, i| {
            if (i > 0) try self.write(", ");
            try self.writeIdent(f.name);
            try self.write(": ");
            try self.writeJsExpr(f.value);
        }
        try self.write(" }");
    }

    /// Emit the body of a SUBFLOW implementation — a flow whose `impl_of` names
    /// the event being emitted (`run = step() | continue => iterated`). The body
    /// IS an ordinary dispatch, so it reuses the same recursive emitter the
    /// top-level flows use; the only difference is that it sits inside a handler
    /// function, which is what turns a branch-constructor arm into a `return`.
    ///
    /// `event` is published on the emitter for the duration: inside its own impl,
    /// the event's effect arms are CALLABLE, and firing one is not an invocation.
    fn emitSubflowImplBody(self: *Emitter, event: *const ast.EventDecl, flow: *const ast.Flow, indent: []const u8) JsEmitError!void {
        const saved = self.impl_event;
        self.impl_event = event;
        defer self.impl_event = saved;

        // A subflow impl is a flow, so a dissolving transform can hang a preamble
        // on it exactly as it does at top level — `compute-stats = capture { … }`
        // (320_028) is the same `~capture` with the same cell, just implementing an
        // event instead of running standalone. Reading the preamble only in
        // `emitFlow` would have made the construct work at one depth and silently
        // emit a `capture_event.handler(…)` call at the other.
        if (flow.preamble_code != null and !preambleThenCall(flow.inv())) {
            try self.emitPreamble(flow.preamble_code, indent);
            try self.emitPreambleContinuations(flow.body.continuations, indent);
            return;
        }
        try self.emitPreamble(flow.preamble_code, indent);

        if (flow.inline_body) |raw| {
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripInlineStmtMarker(raw), flow.body.continuations, indent, &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(flow.body.continuations, consumed, indent);
            return;
        }
        // `run = #L step(…) | more s |> @L(…) | done e -> e` — a fold implementing
        // an event. Same construct as a top-level fold; the exit arm's `-> e` just
        // lands on the enclosing handler's `return` (020_028).
        if (flow.pre_label) |label| {
            try self.emitLabelFold(flow, label, indent);
            return;
        }
        try self.emitInvocationWithContinuations(flow.inv(), flow.body.continuations, indent);
    }

    /// Write a KORU expression as JavaScript. Three rewrites, all mechanical:
    ///
    ///  - `++` → `+`. Koru spells string concatenation Zig's way, which the Zig
    ///    target passes straight through. In JavaScript `++` is the increment
    ///    operator, so an unlowered `a ++ b` is a SYNTAX error, not a wrong answer.
    ///  - `and` / `or` → `&&` / `||` (see `writeLowered`).
    ///  - Zig host builtins → their JS twins (see `writeHostBuiltin`).
    ///
    /// Everything else passes through verbatim, exactly as
    /// emitter_helpers.emitValue passes a value through for Zig.
    fn writeJsExpr(self: *Emitter, expr: []const u8) JsEmitError!void {
        try self.writeLowered(expr, .koru_expr);
    }

    /// Write HOST text (a rendered template body) with only the host-builtin
    /// rewrite applied. `++` is left alone: this text is JavaScript already, so a
    /// `++` in it is a genuine increment, not a Koru concatenation.
    fn writeHostText(self: *Emitter, text: []const u8) JsEmitError!void {
        try self.writeLowered(text, .host_text);
    }

    const LowerMode = enum { koru_expr, host_text };

    /// The shared scanner behind `writeJsExpr` / `writeHostText`. Walks the text
    /// once, leaving string and char literals untouched, and rewrites the
    /// constructs JavaScript cannot parse.
    ///
    /// `and` / `or` are rewritten in BOTH modes, not just `.koru_expr`. A `when`
    /// guard and an `~if(…)` condition are the same Koru-authored boolean text,
    /// but they reach the emitter through different doors: the guard arrives as
    /// `cont.condition`, while the condition is baked into the template's rendered
    /// body by template_processor and arrives as host text. Lowering only one door
    /// would leave the other emitting `a and b`, which is a JS syntax error. The
    /// rewrite is word-boundary anchored, so `android` and `.or_else` are untouched.
    fn writeLowered(self: *Emitter, text: []const u8, mode: LowerMode) JsEmitError!void {
        var i: usize = 0;
        var quote: ?u8 = null;
        // One entry per open `{` we are inside, saying whether its closer must be
        // written as `]`. A Zig ARRAY literal opens with a brace and closes with
        // one; JavaScript's opens and closes with brackets, so the decision made
        // at the opener has to survive to the matching closer.
        var brace_is_bracket: [64]bool = undefined;
        var brace_depth: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (quote) |q| {
                if (c == '\\' and i + 1 < text.len) {
                    try self.buf.appendSlice(self.allocator, text[i .. i + 2]);
                    i += 2;
                    continue;
                }
                if (c == q) quote = null;
                try self.buf.append(self.allocator, c);
                i += 1;
                continue;
            }
            if (c == '"' or c == '\'' or c == '`') {
                quote = c;
                try self.buf.append(self.allocator, c);
                i += 1;
                continue;
            }
            if (mode == .koru_expr and c == '+' and i + 1 < text.len and text[i + 1] == '+') {
                try self.write("+");
                i += 2;
                continue;
            }
            if ((c == 'a' or c == 'o') and (i == 0 or (!isIdentChar(text[i - 1]) and text[i - 1] != '.'))) {
                const word: ?[]const u8 = if (std.mem.startsWith(u8, text[i..], "and"))
                    "&&"
                else if (std.mem.startsWith(u8, text[i..], "or"))
                    "||"
                else
                    null;
                if (word) |js_op| {
                    const len: usize = if (js_op[0] == '&') 3 else 2;
                    if (i + len >= text.len or !isIdentChar(text[i + len])) {
                        try self.write(js_op);
                        i += len;
                        continue;
                    }
                }
            }
            if (c == '@') {
                if (try self.writeHostBuiltin(text, i)) |after| {
                    i = after;
                    continue;
                }
            }
            // ZIG-SHAPED EXPRESSION TEXT, lowered in BOTH modes — unlike `++` and
            // `and`/`or`, which are real JavaScript and must stay `.koru_expr`-only.
            // Neither shape below has ANY valid JavaScript reading, so neither can
            // misfire on genuine host text. It has to be both modes: a `~for(&items)`
            // argument reaches the emitter as `.koru_expr`, but the SAME text also
            // arrives baked into the `for|template|js` body as rendered host text.
            //
            // Zig ADDRESS-OF in prefix position. A JS array or object IS a
            // reference, so taking its address is the identity. An INFIX `&` is
            // bitwise-and in both languages and is left alone — position is the
            // whole discriminator.
            {
                if (c == '&' and isPrefixPosition(text, i)) {
                    i += 1;
                    continue;
                }
                // Zig ARRAY literal: `[_]i32{1, 2, 3}`, `[3]i32{0, 0, 0}`,
                // `[2][2]i32{ … }`. The type prefix has no JS counterpart and the
                // braces become brackets.
                if (c == '[') {
                    if (zigArrayLiteralOpen(text, i)) |after_brace| {
                        if (brace_depth < brace_is_bracket.len) {
                            brace_is_bracket[brace_depth] = true;
                            brace_depth += 1;
                            try self.write("[");
                            i = after_brace;
                            continue;
                        }
                    }
                }
                // Anonymous POSITIONAL tuple: `.{ 0, 0 }`, a row of the 2-D literal
                // above. Only the positional form — `.{ .ok = v }` is a BRANCH
                // constructor whose JS shape is `{ tag: "ok", ok: v }`, and quietly
                // lowering it to a plain object would produce a wrong answer rather
                // than a syntax error. That one stays refused.
                if (c == '.' and i + 1 < text.len and text[i + 1] == '{' and isPositionalTuple(text, i + 1)) {
                    if (brace_depth < brace_is_bracket.len) {
                        brace_is_bracket[brace_depth] = true;
                        brace_depth += 1;
                        try self.write("[");
                        i += 2;
                        continue;
                    }
                }
                if (c == '{' and brace_depth < brace_is_bracket.len) {
                    brace_is_bracket[brace_depth] = false;
                    brace_depth += 1;
                }
                if (c == '}' and brace_depth > 0) {
                    brace_depth -= 1;
                    try self.write(if (brace_is_bracket[brace_depth]) "]" else "}");
                    i += 1;
                    continue;
                }
            }
            try self.buf.append(self.allocator, c);
            i += 1;
        }
    }

    /// Lower a Zig HOST builtin call starting at `text[at] == '@'` to its
    /// JavaScript equivalent, returning the index just past it. Returns null when
    /// what follows `@` is not a builtin CALL at all (no name, no open paren), so
    /// the caller emits the character verbatim.
    ///
    /// WHY this exists: Koru `.k` body expressions currently reach the backend as
    /// raw HOST text — that is the gap 010_063 pins as red ("give .k
    /// body-expressions a parse-and-lower layer"). Until that layer exists the
    /// integer arithmetic a `.k` author writes is Zig, so a JS target either
    /// translates these builtins or emits text no JavaScript engine can parse.
    /// The mapping is mechanical and semantics-preserving:
    ///
    ///   @as(T, x) @intCast(x) @truncate(x) @floatFromInt(x) @enumFromInt(x)
    ///   @intFromEnum(x) @bitCast(x)                → the value, unchanged
    ///   @intFromFloat(x)                           → Math.trunc(x)
    ///   @divTrunc(a, b)                            → Math.trunc((a) / (b))
    ///   @divFloor(a, b)                            → Math.floor((a) / (b))
    ///   @divExact(a, b)                            → ((a) / (b))
    ///   @rem(a, b)                                 → ((a) % (b))          truncated, C's %
    ///   @mod(a, b)                                 → (((a) % (b) + (b)) % (b))  euclidean
    ///   @min @max @abs @sqrt                       → Math.min max abs sqrt
    ///
    /// An `@`-builtin this does not model is refused rather than passed through:
    /// `@` is not an expression character in JavaScript, so emitting it produces
    /// a syntax error at `node` instead of a diagnostic here.
    fn writeHostBuiltin(self: *Emitter, text: []const u8, at: usize) JsEmitError!?usize {
        var p = at + 1;
        while (p < text.len and isIdentChar(text[p])) p += 1;
        const name = text[at + 1 .. p];
        if (name.len == 0) return null;
        if (p >= text.len or text[p] != '(') return null;

        // Balanced-paren scan for the argument list, then split it at TOP-LEVEL
        // commas only — `@as(i64, @intCast(i))` nests.
        const args_start = p + 1;
        var depth: usize = 1;
        var j = args_start;
        var split: ?usize = null;
        while (j < text.len and depth > 0) : (j += 1) {
            switch (text[j]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                ',' => if (depth == 1 and split == null) {
                    split = j;
                },
                else => {},
            }
        }
        if (depth != 0) return null; // unbalanced — not a call we can read
        const args_end = j - 1; // index of the closing ')'
        const first = std.mem.trim(u8, text[args_start .. split orelse args_end], " \t");
        const second = if (split) |s| std.mem.trim(u8, text[s + 1 .. args_end], " \t") else "";

        const eql = std.mem.eql;
        // Representation casts: JavaScript has ONE number type, so the cast is
        // the value. `@as`/`@enumFromInt` carry the type first, the value second.
        if (eql(u8, name, "as") or eql(u8, name, "enumFromInt") or eql(u8, name, "bitCast")) {
            try self.write("(");
            try self.writeLowered(if (split != null) second else first, .koru_expr);
            try self.write(")");
            return j;
        }
        if (eql(u8, name, "intCast") or eql(u8, name, "truncate") or
            eql(u8, name, "floatFromInt") or eql(u8, name, "intFromEnum") or
            eql(u8, name, "floatCast"))
        {
            try self.write("(");
            try self.writeLowered(first, .koru_expr);
            try self.write(")");
            return j;
        }
        if (eql(u8, name, "intFromFloat")) {
            try self.write("Math.trunc(");
            try self.writeLowered(first, .koru_expr);
            try self.write(")");
            return j;
        }
        if (eql(u8, name, "divTrunc") or eql(u8, name, "divFloor") or eql(u8, name, "divExact")) {
            try self.write(if (eql(u8, name, "divTrunc")) "Math.trunc((" else if (eql(u8, name, "divFloor")) "Math.floor((" else "((");
            try self.writeLowered(first, .koru_expr);
            try self.write(") / (");
            try self.writeLowered(second, .koru_expr);
            try self.write("))");
            return j;
        }
        if (eql(u8, name, "rem")) {
            try self.write("((");
            try self.writeLowered(first, .koru_expr);
            try self.write(") % (");
            try self.writeLowered(second, .koru_expr);
            try self.write("))");
            return j;
        }
        if (eql(u8, name, "mod")) {
            // Euclidean: Zig's @mod is non-negative for a positive divisor,
            // JavaScript's `%` keeps the dividend's sign.
            try self.write("((((");
            try self.writeLowered(first, .koru_expr);
            try self.write(") % (");
            try self.writeLowered(second, .koru_expr);
            try self.write(")) + (");
            try self.writeLowered(second, .koru_expr);
            try self.write(")) % (");
            try self.writeLowered(second, .koru_expr);
            try self.write("))");
            return j;
        }
        if (eql(u8, name, "min") or eql(u8, name, "max") or eql(u8, name, "abs") or eql(u8, name, "sqrt")) {
            try self.writeFmt("Math.{s}(", .{name});
            try self.writeLowered(first, .koru_expr);
            if (split != null) {
                try self.write(", ");
                try self.writeLowered(second, .koru_expr);
            }
            try self.write(")");
            return j;
        }

        log.err("[js_emitter] host builtin '@{s}' has no JS lowering\n", .{name});
        return JsEmitError.UnsupportedConstruct;
    }

    /// Where an event declaration was found, paired with the item list its
    /// implementation must be resolved against. The scope is half the answer: a
    /// module's event resolves to the proc in that same module, never to a
    /// same-named proc in a sibling, so a decl pointer alone cannot be followed.
    const DeclSite = struct {
        decl: *const ast.EventDecl,
        scope: []const ast.Item,
    };

    /// Bound for the implementability walk. The event graph is genuinely cyclic —
    /// `std.optimizer:optimize` invokes `optimize` — so the walk needs a stop, and
    /// a depth cap is the cheap one: it needs no allocation and no visited set,
    /// and a chain deeper than this is not something the JS target emits today.
    /// Hitting the cap answers "not implementable", which is the safe direction.
    const IMPL_WALK_DEPTH: u8 = 32;

    /// Resolve an event path to its declaration AND the scope that declaration
    /// lives in. Same descent and same module reconciliation as `findEventDeclIn`;
    /// the difference is that this one keeps the scope, which is what makes the
    /// implementability walk possible.
    fn findDeclSiteIn(self: *Emitter, scope: []const ast.Item, path: *const ast.DottedPath, current_module: ?[]const u8) ?DeclSite {
        for (scope) |*item| {
            switch (item.*) {
                .event_decl => |*e| {
                    if (pathsEqualWithModule(&e.path, path, current_module, self.main_module_name)) {
                        return .{ .decl = e, .scope = scope };
                    }
                },
                .module_decl => |*m| {
                    if (self.findDeclSiteIn(m.items, path, m.logical_name)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }

    /// Is this event's behaviour reachable ON THE JS TARGET — not "does it have a
    /// body here" but "does every leaf its body reaches have a JS body".
    ///
    /// This is the predicate the module gate always wanted. `findImplIn` answers
    /// the LOCAL question, and answering only that is what made widening the gate
    /// look bad: every subflow-implemented pass of `std.compiler` — `elaborate`,
    /// `analysis`, `emission`, `optimize` — resolves locally, then emits a handler
    /// calling eighteen handlers that were never emitted. Dead code that reads
    /// `undefined` if anything ever calls it, and worse than dead: measured
    /// 2026-08-06, `115_024_capture_in_module` PANICKED the whole compile on an
    /// UnsupportedConstruct reached only from inside one of those dead bodies.
    ///
    /// A `|js` proc answers the transitive question in one hop, which is exactly
    /// why the old one-hop gate worked at all. This walk answers it for the other
    /// three spellings too, so a module event implemented in pure Koru is emitted
    /// when its callees bottom out in JS and skipped when they bottom out in Zig.
    fn eventIsJsImplementable(self: *Emitter, site: DeclSite, depth: u8) bool {
        if (depth == 0) return false;
        const impl = self.findImplIn(site.scope, &site.decl.path) orelse return false;
        return switch (impl) {
            // Host JS, and a `|template|` stub that throws — both are leaves.
            .proc, .template_stub => true,
            // An arrow impl is an expression over its own inputs. No callees.
            .immediate => true,
            .subflow => |flow| self.subflowIsJsImplementable(site.decl, flow, depth - 1),
        };
    }

    /// A subflow body is implementable when every invocation it performs is.
    /// A body already rendered to host JS by a comptime transform is a leaf —
    /// there is nothing left to resolve, which is how `std/io:print.ln` inside an
    /// imported module (115_001) comes out implementable.
    fn subflowIsJsImplementable(self: *Emitter, event: *const ast.EventDecl, flow: *const ast.Flow, depth: u8) bool {
        if (flow.inline_body != null) return true;
        if (!self.invocationIsJsImplementable(event, flow.inv(), depth)) return false;
        return self.continuationsAreJsImplementable(event, flow.body.continuations, depth);
    }

    fn continuationsAreJsImplementable(self: *Emitter, event: *const ast.EventDecl, conts: []const ast.Continuation, depth: u8) bool {
        for (conts) |*cont| {
            if (cont.node) |*node| {
                switch (node.*) {
                    .invocation => |*inv| {
                        if (!self.invocationIsJsImplementable(event, inv, depth)) return false;
                    },
                    .label_with_invocation => |*lwi| {
                        if (!self.invocationIsJsImplementable(event, &lwi.invocation, depth)) return false;
                    },
                    // `_` and an inline branch constructor call nothing.
                    .terminal, .branch_constructor => {},
                    // Any other node kind: refuse to vouch. Emitting a body the
                    // walk cannot account for is how a DEAD handler panics a live
                    // compile, and the cost of being wrong in this direction is
                    // only that a module event stays absent — the same place the
                    // narrow gate left it.
                    else => return false,
                }
            }
            if (!self.continuationsAreJsImplementable(event, cont.continuations, depth)) return false;
        }
        return true;
    }

    fn invocationIsJsImplementable(self: *Emitter, impl_event: *const ast.EventDecl, inv: *const ast.Invocation, depth: u8) bool {
        // Already lowered to host JS at the call site by a comptime transform.
        if (inv.inline_body != null) return true;
        // Firing one of the enclosing event's OWN effect arms hands control back
        // to whoever installed the arm; it is not a callee to resolve. Same check,
        // same order, as emitInvocationWithContinuations.
        if (findEffectArm(impl_event, &inv.path) != null) return true;
        const site = self.findDeclSiteIn(self.items, &inv.path, null) orelse return false;
        return self.eventIsJsImplementable(site, depth);
    }

    /// Record `event`'s lowered JS key as taken. Cheap by design: keys are
    /// duped so the set outlives the stack buffer the lowering wrote into.
    fn claimEventKey(self: *Emitter, keys: *EmittedKeys, event: *const ast.EventDecl) JsEmitError!void {
        var buf: [256]u8 = undefined;
        const name = event.path.segments[event.path.segments.len - 1];
        if (name.len > buf.len) return;
        const key = lowerIdentBuf(&buf, name);
        if (keys.contains(key)) return;
        try keys.put(try self.allocator.dupe(u8, key), {});
    }

    /// Emit the events of an imported module. Three outcomes, and the third is
    /// the point:
    ///
    ///  - implementable → an ordinary handler, body resolved the same four ways
    ///    `emitEventDecl` accepts.
    ///  - not implementable, not reached → absent, in silence. This is most of
    ///    the stdlib: `std.compiler` alone declares twenty passes no JS program
    ///    ever calls, and emitting them is pure weight (measured 2026-08-06:
    ///    204 bytes of hello-world became 4790).
    ///  - not implementable but REACHED → a handler that throws, naming itself.
    ///
    /// The third case is why this function takes a reached set. Skipping a
    /// reached event is the silent failure this whole path used to have: the call
    /// site emits `main_module.push_event.handler(...)`, `push_event` is absent,
    /// and node says `TypeError: Cannot read properties of undefined (reading
    /// 'handler')` — a message that names neither the event, nor the module, nor
    /// the reason. A throwing handler is present, so the error arrives AT the
    /// call frame and says which event and why. Same trick, same file, as the
    /// `|template|` stub in emitEventDecl.
    ///
    /// A refusal must never CLOBBER: `<name>_event` is a flat JS key while Koru
    /// event paths are not, so a stub for `app.lib.ring:push` would overwrite a
    /// working top-level `push` handler written in Phase 1. `emitted_keys` is
    /// consulted for exactly that, and a taken key means stay absent — the old
    /// behaviour, which is wrong but is not a regression.
    fn emitModuleEventDecls(
        self: *Emitter,
        module: *const ast.ModuleDecl,
        reached: *const ReachedEvents,
        emitted_keys: *EmittedKeys,
    ) JsEmitError!void {
        for (module.items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    const site = DeclSite{ .decl = event, .scope = module.items };
                    if (self.eventIsJsImplementable(site, IMPL_WALK_DEPTH)) {
                        try self.emitEventDecl(event, module.items);
                        try self.claimEventKey(emitted_keys, event);
                        continue;
                    }
                    if (!reached.contains(event)) continue;
                    var name_buf: [256]u8 = undefined;
                    const name = event.path.segments[event.path.segments.len - 1];
                    if (name.len > name_buf.len) continue;
                    const key = lowerIdentBuf(&name_buf, name);
                    if (emitted_keys.contains(key)) continue;
                    try self.emitUnlowerableEventRefusal(event, module);
                    try self.claimEventKey(emitted_keys, event);
                },
                .module_decl => |*nested| try self.emitModuleEventDecls(nested, reached, emitted_keys),
                else => {},
            }
        }
    }

    /// A handler for an event this target cannot lower, whose whole body is the
    /// diagnostic. It replaces `undefined.handler` with a sentence that names the
    /// event, its module, and the reason — at the frame that wanted it.
    fn emitUnlowerableEventRefusal(self: *Emitter, event: *const ast.EventDecl, module: *const ast.ModuleDecl) JsEmitError!void {
        var name_buf: [256]u8 = undefined;
        const name = event.path.segments[event.path.segments.len - 1];
        try self.writeFmt("  {s}_event: {{\n", .{lowerIdentBuf(&name_buf, name)});
        try self.write("    handler() {\n");
        try self.writeFmt(
            "      throw new Error(\"{s}:{s} has no JavaScript implementation — its body resolves only to a non-JS target (|zig / [comptime]), directly or through a callee\");\n",
            .{ module.logical_name, name },
        );
        try self.write("    },\n  },\n");
    }

    /// The event decls the emitted program actually reaches, by pointer identity.
    /// Seeded from the flows Phase 2 will emit — the same filter, so the two
    /// cannot disagree about what runs — then closed transitively through each
    /// reached event's own implementation.
    fn collectReachedEvents(self: *Emitter, reached: *ReachedEvents) JsEmitError!void {
        for (self.items) |*item| {
            if (item.* != .flow) continue;
            const flow = &item.flow;
            if (flow.impl_of != null) continue;
            if (self.isDeclarationFlow(flow)) continue;
            if (flow.inv().path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "koru")) continue;
            }
            try self.reachFlow(null, flow, reached, IMPL_WALK_DEPTH);
        }
    }

    fn reachFlow(self: *Emitter, impl_event: ?*const ast.EventDecl, flow: *const ast.Flow, reached: *ReachedEvents, depth: u8) JsEmitError!void {
        if (depth == 0) return;
        try self.reachInvocation(impl_event, flow.inv(), reached, depth);
        try self.reachContinuations(impl_event, flow.body.continuations, reached, depth);
    }

    fn reachContinuations(self: *Emitter, impl_event: ?*const ast.EventDecl, conts: []const ast.Continuation, reached: *ReachedEvents, depth: u8) JsEmitError!void {
        if (depth == 0) return;
        for (conts) |*cont| {
            if (cont.node) |*node| switch (node.*) {
                .invocation => |*inv| try self.reachInvocation(impl_event, inv, reached, depth),
                .label_with_invocation => |*lwi| try self.reachInvocation(impl_event, &lwi.invocation, reached, depth),
                else => {},
            };
            try self.reachContinuations(impl_event, cont.continuations, reached, depth);
        }
    }

    fn reachInvocation(self: *Emitter, impl_event: ?*const ast.EventDecl, inv: *const ast.Invocation, reached: *ReachedEvents, depth: u8) JsEmitError!void {
        if (depth == 0) return;
        // An arm fire is a callback into the caller, not a callee. Same check and
        // same order as emitInvocationWithContinuations.
        if (impl_event) |ie| {
            if (findEffectArm(ie, &inv.path) != null) return;
        }
        // A call site a comptime transform already rendered to host JS is spliced,
        // not dispatched — `main_module.<ev>_event.handler(...)` is never written,
        // so the callee is NOT reached. Checked before the set is touched: marking
        // it would mint a refusal stub for an event nothing can call (measured:
        // `std.io:impl`, the `print.blk` impl stub, in 400_179).
        if (inv.inline_body != null) return;
        const site = self.findDeclSiteIn(self.items, &inv.path, null) orelse return;
        // Already reached: its subtree is accounted for, and the graph is cyclic.
        if ((try reached.getOrPut(site.decl)).found_existing) return;
        // An event's own implementation is emitted with it, so whatever that body
        // calls is reached too.
        const impl = self.findImplIn(site.scope, &site.decl.path) orelse return;
        switch (impl) {
            .subflow => |flow| {
                if (flow.inline_body != null) return;
                try self.reachFlow(site.decl, flow, reached, depth - 1);
            },
            else => {},
        }
    }

    /// Emit a top-level flow as `flowN()`. The dispatch body is produced by the
    /// recursive `emitInvocationWithContinuations` helper, which handles both the
    /// shallow (single resume-value handler) and deep (nested void-effect chain)
    /// shapes uniformly.
    fn emitFlow(self: *Emitter, flow: *const ast.Flow, flow_num: usize) JsEmitError!void {
        try self.writeFmt("  flow{d}() {{\n", .{flow_num});
        // PREAMBLE REPLACES THE CALL. A dissolving transform (`~capture`, `~const`,
        // `~for`, `~if`) leaves the invocation standing as a spent marker and hangs
        // the real declaration on `preamble_code`; emitting the handler call as well
        // would call a comptime event that has no runtime body. `@preamble_then_call`
        // is the one invocation that wants both. Same rule, same annotation, as
        // emitter_helpers.zig:4911 — a second reading of it would be a second
        // definition of when a transform's preamble stands in for its call.
        if (flow.preamble_code != null and !preambleThenCall(flow.inv())) {
            try self.emitPreamble(flow.preamble_code, "    ");
            try self.emitPreambleContinuations(flow.body.continuations, "    ");
            try self.write("  },\n");
            return;
        }
        try self.emitPreamble(flow.preamble_code, "    ");
        // If a comptime|transform pass (e.g. std.io:print.blk|js) already produced
        // inline output for this flow, splice it directly — the invocation path
        // has been rewritten to an impl-stub (`print.blk.impl`) that the JS
        // emitter doesn't need to resolve. Matches the Zig emitter's behavior
        // at visitor_emitter.zig:1804+ and :2522+.
        if (flow.inline_body) |inline_body_raw| {
            const stripped = stripInlineStmtMarker(inline_body_raw);
            // The rendered template (e.g. `~if`) carries `__koru_continue_N`
            // markers where a terminal continuation's body must be spliced in.
            // Resolve them against `flow.body.continuations` — the JS mirror of the
            // Zig emitter's emitInlineCodeResolvingSplices (emitter_helpers.zig
            // :3186). Lines with no marker are emitted verbatim, so non-template
            // inline bodies (comptime |js transforms) lower exactly as before.
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripped, flow.body.continuations, "    ", &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(flow.body.continuations, consumed, "    ");
        } else if (flow.pre_label) |label| {
            try self.emitLabelFold(flow, label, "    ");
        } else {
            try self.emitInvocationWithContinuations(flow.inv(), flow.body.continuations, "    ");
        }
        try self.write("  },\n");
    }

    /// LABEL FOLD — `run = #L step(n: start, acc: 0) | more s |> @L(s.n, s.acc)
    ///                                               | done e  -> e`
    ///
    /// `#L` anchors a FIXPOINT. The head runs once; every arm that jumps back to
    /// `L` re-seeds the head's parameters and runs it again; the first arm that
    /// does NOT jump wins and runs after the loop. The loop's whole state is one
    /// `let <label>_<param>` per head argument — exactly the head's parameter list,
    /// which is why the jump can be spelled as N assignments plus one re-call.
    ///
    ///     let L_n = start;  let L_acc = 0;
    ///     let result_0 = main_module.step_event.handler({ n: L_n, acc: L_acc });
    ///     while (result_0.tag === "more") { … re-seed … re-call … }
    ///     { const e = result_0.done; return e; }
    ///
    /// A `while` is right and a `for` is wrong here, and CLAUDE.md's loop rule
    /// names this exact exception: the trip count of a fixpoint is not knowable up
    /// front, so there is no range to hand the optimizer.
    ///
    /// TWO PLACES THIS IS CLEANER THAN THE ZIG REFERENCE (emitter_helpers.zig
    /// :5121), both because the JS target has nothing to preserve: no `continue
    /// :label` as the loop body's last statement — falling off the end of a `while`
    /// body already does that — and no type annotations on the state variables,
    /// which Zig needs only because a mutable `var` may not hold a comptime_int.
    fn emitLabelFold(
        self: *Emitter,
        flow: *const ast.Flow,
        label: []const u8,
        indent: []const u8,
    ) JsEmitError!void {
        try self.emitLabelFoldAt(flow.inv(), flow.body.continuations, label, indent);
    }

    /// The fold itself, taking its head invocation and arms DIRECTLY rather than
    /// through a flow. `#loop` is not only a flow head: `~start() |> #loop
    /// counter(n: 1) | next v |> @loop(n: v)` anchors the same fixpoint one step
    /// in, and reading it off `flow.pre_label` made the construct work in one
    /// position and refuse in the other. The fold does not care what preceded it.
    fn emitLabelFoldAt(
        self: *Emitter,
        inv: *const ast.Invocation,
        conts: []const ast.Continuation,
        label: []const u8,
        indent: []const u8,
    ) JsEmitError!void {
        const event = self.findEventDecl(&inv.path) orelse {
            log.err("[js_emitter] #{s} fold head invokes an unresolved event\n", .{label});
            return JsEmitError.UnresolvedEvent;
        };

        var terminal_branches: usize = 0;
        for (event.branches) |b| {
            if (b.kind == .effect) {
                // An effect-bearing fold head would need its `Handlers_<id>` rebuilt
                // and re-passed on every turn (emitter_helpers.zig:5150 does exactly
                // that). Nothing in the corpus writes one, so refuse by name rather
                // than emit a shape no test has ever run.
                log.err("[js_emitter] #{s} fold head '{s}' declares effect branches, which this target does not model\n", .{ label, event.path.segments[event.path.segments.len - 1] });
                return JsEmitError.UnsupportedConstruct;
            }
            terminal_branches += 1;
        }
        const bare_return = terminal_branches == 0 and event.return_type != null;

        // One state variable per head parameter, seeded from the head's own args.
        for (inv.args) |arg| {
            try self.writeFmt("{s}let {s}_", .{ indent, label });
            try self.writeIdent(arg.name);
            try self.write(" = ");
            try self.writeJsExpr(arg.value);
            try self.write(";\n");
        }

        var ev_name_buf: [256]u8 = undefined;
        const ev_name = lowerIdentBuf(&ev_name_buf, event.path.segments[event.path.segments.len - 1]);
        const result_name = try std.fmt.allocPrint(self.allocator, "result_{d}", .{self.nextId()});
        defer self.allocator.free(result_name);

        // `let`, not `const`: the loop reassigns it every turn.
        try self.writeFmt("{s}let {s} = main_module.{s}_event.handler(", .{ indent, result_name, ev_name });
        try self.emitLabelStateArgs(inv.args, label);
        try self.write(");\n");

        var looping: usize = 0;
        var exiting: usize = 0;
        for (conts) |*cont| {
            if (cont.kind != .terminal) continue;
            if (contLoopsTo(cont, label)) looping += 1 else exiting += 1;
        }

        const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(inner);

        if (looping > 0) {
            // The `while` carries a JS LABEL, and the label is the fold's own name.
            // A same-level jump could fall off the end of the body instead, but a
            // CROSS-LEVEL one cannot: `@outer(…)` fired from inside an inner fold
            // has to leave the inner loop, and `continue outer;` is the only thing
            // that says so. Labelling every fold keeps one spelling for both, and
            // JS labels live in their own namespace, so `loop:` cannot collide with
            // the `loop_n` state variables beside it.
            try self.writeFmt("{s}", .{indent});
            try self.writeIdent(label);
            try self.write(": while (");
            var written: usize = 0;
            for (conts) |*cont| {
                if (cont.kind != .terminal or !contLoopsTo(cont, label)) continue;
                if (written > 0) try self.write(" || ");
                try self.writeFmt("{s}.tag === \"{s}\"", .{ result_name, cont.branch });
                written += 1;
            }
            try self.write(") {\n");

            const saved = self.label_frame;
            const frame = LabelFrame{
                .label = label,
                .result_name = result_name,
                .inv = inv,
                .outer = saved,
            };
            self.label_frame = &frame;
            defer self.label_frame = saved;

            // Inside the loop the condition has already selected the arm when there
            // is only one, so it is emitted unguarded; with two or more, each still
            // needs its own tag test.
            for (conts) |*cont| {
                if (cont.kind != .terminal or !contLoopsTo(cont, label)) continue;
                try self.emitTerminalContinuation(cont, result_name, inner, looping >= 2, bare_return, null);
            }
            try self.writeFmt("{s}}}\n", .{indent});
        }

        // The exit arms run AFTER the loop, where every looping tag is impossible.
        for (conts) |*cont| {
            if (cont.kind != .terminal or contLoopsTo(cont, label)) continue;
            try self.emitTerminalContinuation(cont, result_name, indent, exiting >= 2, bare_return, null);
        }
    }

    /// `{ <param>: <label>_<param>, … }` — the fold's head args, read out of the
    /// state variables. Written at the seed call and again at every jump, so the
    /// two cannot disagree about which names the head takes.
    fn emitLabelStateArgs(self: *Emitter, args: []const ast.Arg, label: []const u8) JsEmitError!void {
        try self.write("{ ");
        for (args, 0..) |arg, i| {
            if (i > 0) try self.write(", ");
            try self.writeIdent(arg.name);
            try self.writeFmt(": {s}_", .{label});
            try self.writeIdent(arg.name);
        }
        try self.write(" }");
    }

    /// Emit a `@label(…)` jump: re-seed the target fold's state variables from the
    /// jump's arguments, re-run its head into its result variable, then
    /// `continue <label>`.
    ///
    /// The target is found by walking OUT through the enclosing folds, so an inner
    /// fold may jump to an outer label. That is the whole reason the `continue` is
    /// written rather than falling off the end of the body: a cross-level jump has
    /// to leave the inner loop, and only a labelled continue does. It is also what
    /// makes two looping arms safe — the turn ends at the jump instead of running
    /// the next arm's test against a result the jump just replaced.
    fn emitLabelJump(self: *Emitter, label: []const u8, args: []const ast.Arg, indent: []const u8) JsEmitError!void {
        var walk = self.label_frame;
        const frame = while (walk) |f| : (walk = f.outer) {
            if (std.mem.eql(u8, f.label, label)) break f;
        } else {
            if (self.label_frame) |inner| {
                log.err("[js_emitter] @{s}(…) names no enclosing fold; innermost is #{s}\n", .{ label, inner.label });
            } else {
                log.err("[js_emitter] @{s}(…) jump outside any #{s} fold\n", .{ label, label });
            }
            return JsEmitError.UnsupportedConstruct;
        };
        for (args) |arg| {
            try self.writeFmt("{s}{s}_", .{ indent, label });
            try self.writeIdent(arg.name);
            try self.write(" = ");
            try self.writeJsExpr(arg.value);
            try self.write(";\n");
        }
        var ev_name_buf: [256]u8 = undefined;
        const seg = frame.inv.path.segments;
        const ev_name = lowerIdentBuf(&ev_name_buf, seg[seg.len - 1]);
        try self.writeFmt("{s}{s} = main_module.{s}_event.handler(", .{ indent, frame.result_name, ev_name });
        try self.emitLabelStateArgs(frame.inv.args, label);
        try self.write(");\n");
        try self.writeFmt("{s}continue ", .{indent});
        try self.writeIdent(frame.label);
        try self.write(";\n");
    }

    /// Emit a rendered template body (e.g. `~if`'s `if (cond) { … } else { … }`
    /// or `~for`'s `for (const x of …) { … }`), resolving the two splice-marker
    /// kinds the template_processor mints:
    ///
    ///   - `__koru_continue_N`            — a terminal continuation hand-off
    ///                                      (`| done`, `| then`, `| else`).
    ///   - `__koru_inline[_scoped]_N(arg)` — an EFFECT-handler splice (`! each`):
    ///                                      bind `arg` to the handler's parameter
    ///                                      and run the handler body in a block.
    ///
    /// We scan by marker POSITION (not line), mirroring the Zig reference
    /// emitter_helpers.zig:3186 `emitInlineCodeResolvingSplices`: find the
    /// earliest remaining marker of either kind, emit the verbatim text before it
    /// (preserving the template's own `if`/`for` scaffolding), resolve it, repeat.
    /// Text with no markers passes through unchanged, so non-template inline
    /// bodies (comptime `|js` transforms) lower exactly as before.
    ///
    /// `consumed`, when given, receives a bit per continuation index the body
    /// actually resolved. An arm the body never names is NOT dead — see
    /// `emitUnconsumedContinuations`.
    fn emitInlineBodyResolvingContinuations(
        self: *Emitter,
        body: []const u8,
        continuations: []const ast.Continuation,
        indent: []const u8,
        consumed: ?*u64,
    ) JsEmitError!void {
        // The mask is one bit per arm. Past 64 arms it cannot speak, so it claims
        // everything — the old behaviour, which drops rather than duplicates.
        if (consumed) |c| {
            if (continuations.len > 64) c.* = ~@as(u64, 0);
        }
        const body_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(body_indent);

        const SPLICE_PREFIX = "__koru_inline_";
        const CONTINUE_PREFIX = "__koru_continue_";
        const SCOPED_INFIX = "scoped_";
        // `{{ arm.continue[unguarded] }}` mints `__koru_continue_bare_N`: the same
        // hand-off with the arm's `when` guard LEFT OFF, because the template has
        // already placed it. `cond`'s `if / else if` cascade is the only consumer
        // (control.kz `~proc cond|template|js`); re-testing the guard inside the arm
        // the cascade already selected would evaluate it twice, and the second read
        // would see the arm's own binding rather than the hoisted `{{ binds }}` one.
        // Third marker kind of the Zig reference (emitter_helpers.zig:4252).
        const BARE_INFIX = "bare_";

        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        var pos: usize = 0;
        while (true) {
            const splice_at = std.mem.indexOfPos(u8, trimmed, pos, SPLICE_PREFIX);
            const continue_at = std.mem.indexOfPos(u8, trimmed, pos, CONTINUE_PREFIX);
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

            // The scaffolding between markers is rendered HOST text, but it
            // carries the Koru condition / bound expressions the author wrote —
            // and those are raw Zig (`if (@rem(n, 2) == 0)`). Lower the builtins;
            // leave everything else, `++` included, exactly as the template wrote it.
            try self.writeHostText(trimmed[pos..m]);

            if (is_continue) {
                // CONTINUATION hand-off — splice the terminal body once, here,
                // wrapped in a block so any `const` it introduces is scoped.
                var i = m + CONTINUE_PREFIX.len;
                const is_bare = std.mem.startsWith(u8, trimmed[i..], BARE_INFIX);
                if (is_bare) i += BARE_INFIX.len;
                var idx: usize = 0;
                var saw_digit = false;
                while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') : (i += 1) {
                    idx = idx * 10 + (trimmed[i] - '0');
                    saw_digit = true;
                }
                if (!saw_digit) {
                    // Malformed marker — fail loudly rather than leak it into JS.
                    log.err("[js_emitter] malformed __koru_continue marker\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                }
                if (idx >= continuations.len) {
                    log.err("[js_emitter] __koru_continue_{d} has no matching continuation (have {d})\n", .{ idx, continuations.len });
                    return JsEmitError.UnsupportedConstruct;
                }
                if (consumed) |c| {
                    if (idx < 64) c.* |= @as(u64, 1) << @intCast(idx);
                }
                const cont = &continuations[idx];
                const guarded = !is_bare and cont.condition != null;
                try self.write("{ ");
                if (guarded) {
                    try self.write("if (");
                    try self.writeJsExpr(cont.condition.?);
                    try self.write(") { ");
                }
                try self.emitInlineContinuationBody(cont, body_indent);
                if (guarded) try self.write(" }");
                try self.write(" }");
                pos = i;
                continue;
            }

            // EFFECT splice — `__koru_inline[_scoped]_N(arg)`: bind `arg` to the
            // handler's parameter, then run the handler body in a block. The
            // optional `scoped_` infix carries no JS-emission meaning (scope is an
            // obligation-checker concept, already stamped on the continuation), so
            // skip past it to the digits — same as the Zig reference.
            var i = m + SPLICE_PREFIX.len;
            if (std.mem.startsWith(u8, trimmed[i..], SCOPED_INFIX)) i += SCOPED_INFIX.len;
            var idx: usize = 0;
            var saw_digit = false;
            while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') : (i += 1) {
                idx = idx * 10 + (trimmed[i] - '0');
                saw_digit = true;
            }

            // Read the `(arg)` immediately following (balanced parens).
            var arg: []const u8 = "";
            if (saw_digit and i < trimmed.len and trimmed[i] == '(') {
                const arg_start = i + 1;
                var depth: usize = 1;
                var j = arg_start;
                while (j < trimmed.len and depth > 0) : (j += 1) {
                    if (trimmed[j] == '(') {
                        depth += 1;
                    } else if (trimmed[j] == ')') {
                        depth -= 1;
                    }
                }
                arg = std.mem.trim(u8, trimmed[arg_start .. j - 1], " \t");
                i = j; // past the closing ')'
                // The marker resolves to a block statement; swallow a trailing `;`
                // the template wrote in call-statement shape (`marker(arg);`).
                if (i < trimmed.len and trimmed[i] == ';') i += 1;
            }

            if (!saw_digit) {
                log.err("[js_emitter] malformed __koru_inline marker\n", .{});
                return JsEmitError.UnsupportedConstruct;
            }
            if (idx >= continuations.len) {
                log.err("[js_emitter] __koru_inline_{d} has no matching continuation (have {d})\n", .{ idx, continuations.len });
                return JsEmitError.UnsupportedConstruct;
            }
            if (consumed) |c| {
                if (idx < 64) c.* |= @as(u64, 1) << @intCast(idx);
            }
            const cont = &continuations[idx];
            const binding = cont.binding orelse "_";
            try self.write("{ ");
            if (!std.mem.eql(u8, binding, "_")) {
                try self.writeFmt("const {s} = {s}; ", .{ binding, arg });
            }
            const guarded = cont.condition != null;
            if (guarded) {
                try self.write("if (");
                try self.writeJsExpr(cont.condition.?);
                try self.write(") { ");
            }
            try self.emitInlineContinuationBody(cont, body_indent);
            if (guarded) try self.write(" }");
            try self.write(" }");
            pos = i;
        }
        try self.writeHostText(trimmed[pos..]);
    }

    /// Emit the continuations of an inline body that resolved NO splice marker.
    ///
    /// The two kinds of inline body pull apart cleanly on this one test. A TEMPLATE
    /// body (`~if`, `~for`) names its arms with `__koru_continue_N` /
    /// `__koru_inline_N`; it is a dispatcher, it knows its own arms, and an arm it
    /// did not name it meant not to run. A RENDERED-STATEMENT body names nothing:
    /// `std/io:print.ln` becomes a bare `process.stdout.write(…)`, and everything
    /// hung off that call — a `-> r` produce arm the tap transformer pushed down a
    /// level, an auto-discharge `unlock(…)` the obligation pass appended — has no
    /// marker to arrive through. Splicing the statement and stopping there DROPPED
    /// those silently, which is a wrong answer rather than an error.
    ///
    /// So: drain only when the body consumed nothing. A body that resolved even one
    /// marker is a dispatcher and is trusted with the rest — draining its leftovers
    /// too would run arms it deliberately skipped (measured: a nested `~for` inside
    /// a subflow impl, 115_009/115_011).
    ///
    /// The drained arms run AFTER the spliced statement, in source order. A rendered
    /// statement produces no tagged value, so they are unguarded and bind nothing.
    fn emitUnconsumedContinuations(
        self: *Emitter,
        continuations: []const ast.Continuation,
        consumed: u64,
        indent: []const u8,
    ) JsEmitError!void {
        if (consumed != 0) return;
        for (continuations) |*cont| {
            // An EFFECT arm with no marker was never installed by the body; there
            // is nothing to fire it, so running it here would invent a firing.
            if (cont.kind != .terminal) continue;
            try self.emitTerminalContinuation(cont, null, indent, false, false, null);
        }
    }

    /// Emit a flow's `preamble_code` — host DECLARATION text a comptime transform
    /// hung on the flow to run AHEAD of its dispatch. `~capture` is the one this
    /// target exercises: `let <cell> = { … };`, the accumulator every `.assignment`
    /// in the body writes into and every `| captured` read binds.
    ///
    /// The text is authored in the BUILD language by the transform itself
    /// (control.kz reads `CompilerEnv.lang`), so there is nothing to translate
    /// here — it goes through `writeHostText` for the same reason every other host
    /// fragment does: the VALUES inside it are the user's own expressions and may
    /// still spell a Zig builtin (`@as(i32, 0)`, written by hand in 320_027).
    fn emitPreamble(self: *Emitter, preamble: ?[]const u8, indent: []const u8) JsEmitError!void {
        const text = preamble orelse return;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |line| {
            const line_trimmed = std.mem.trim(u8, line, " \t\r");
            if (line_trimmed.len == 0) continue;
            try self.write(indent);
            try self.writeHostText(line_trimmed);
            try self.write("\n");
        }
    }

    /// Emit the continuations of a flow whose `preamble_code` REPLACED its
    /// invocation. `~capture` (and `~const`/`~for`/`~if`) dissolve into a preamble
    /// plus a chain of bodies; there is no handler call, so there is no result
    /// value, no `.tag` to dispatch on, and no payload for an arm to bind. Each
    /// continuation is therefore emitted BODY-ONLY, in source order — the same
    /// helper a template marker uses for the same reason, and the twin of the Zig
    /// reference's `emitContinuationBody` loop (emitter_helpers.zig:4922).
    fn emitPreambleContinuations(
        self: *Emitter,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        for (continuations) |*cont| {
            try self.emitInlineContinuationBody(cont, indent);
        }
    }

    /// True when the invocation asks for its preamble AND its handler call — the
    /// `field:new.on-stack` routing (koru_std/field.kz:308), whose preamble
    /// declares caller-frame storage the call then takes a pointer into. Every
    /// other preamble REPLACES the call. Same annotation, same meaning, as
    /// emitter_helpers.zig:4911.
    fn preambleThenCall(inv: *const ast.Invocation) bool {
        for (inv.annotations) |ann| {
            if (std.mem.eql(u8, ann, "@preamble_then_call")) return true;
        }
        return false;
    }

    /// Emit a node that is a STATEMENT rather than a dispatch — it produces no
    /// value, so nothing downstream can bind it and there is no tag to switch on.
    /// The Zig reference names the same set (`is_void_step`,
    /// emitter_helpers.zig:9212) and both members come from the `~capture`
    /// dissolution:
    ///
    ///   `.assignment` — a `captured { … }` write into the cell.
    ///   `.inline_code` — host declaration text: the `| captured r` after-read
    ///                    (`const r = <cell>;`), or a NESTED capture's whole cell
    ///                    preamble, which arrives as a node instead of on the flow.
    ///   `.metatype_binding` — a `~tap` arm's observation record, grafted onto the
    ///                    tapped invocation by the tap transformer.
    ///
    /// Returns false for anything else, so each caller's node switch keeps its own
    /// loud refusal for the constructs this target genuinely does not model.
    ///
    /// A statement node's `cont.continuations` are its SEQUEL, not its arms: the
    /// after-read declares `r` and its child prints it. They are driven here, at
    /// the same indent, unguarded and binding nothing — there is no result value
    /// for them to read.
    fn emitVoidStatementNode(
        self: *Emitter,
        node: ast.Node,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!bool {
        switch (node) {
            .assignment => |asgn| try self.emitAssignment(&asgn, indent),
            .inline_code => |text| try self.emitPreamble(text, indent),
            // A `@L(…)` jump ENDS its arm: it re-seeds the fold and the `while`
            // header decides what happens next. The Zig lowering makes that literal
            // with a trailing `continue :L`, which is why anything hung off a jump
            // is unreachable there; here it would merely RUN, so the sequel below
            // is deliberately not driven.
            .label_jump => |lj| {
                try self.emitLabelJump(lj.label, lj.args, indent);
                return true;
            },
            .label_apply => |l| {
                try self.emitLabelJump(l, &.{}, indent);
                return true;
            },
            // `#loop counter(n: 1)` sitting mid-chain — the fold ANCHOR in
            // continuation position rather than at the flow head. It owns its own
            // arms (`| next v |> @loop(n: v)`), which is why the sequel below is
            // not driven: `emitLabelFoldAt` consumes `continuations` itself.
            //
            // A `@loop(…)` JUMP also parses to this node with `is_declaration`
            // false, and it is NOT the same thing. Refuse it by name rather than
            // fold on it — a jump reaching here means it escaped its `#loop`, and
            // treating it as an anchor would emit a plausible second loop instead
            // of saying so.
            .label_with_invocation => |*lwi| {
                if (!lwi.is_declaration) {
                    log.err("[js_emitter] @{s}(…) reached as a fold ANCHOR; a jump must sit inside its own #{s}\n", .{ lwi.label, lwi.label });
                    return false;
                }
                try self.emitLabelFoldAt(&lwi.invocation, continuations, lwi.label, indent);
                return true;
            },
            // A `~tap(hello -> *) | Profile p |> log(msg: p.source)` arm. The tap
            // transformer grafts a metatype_binding step onto the tapped
            // invocation; it constructs the OBSERVATION RECORD the arm's body
            // reads, produces no dispatchable value, and its continuations run
            // inside the record's scope. Two observers on one event bind the same
            // name, so the block is what keeps them apart — the same reason the
            // Zig reference opens one (emitter_helpers.zig:3351).
            //
            // Zig spells Transition's `source`/`branch` as generated enum literals
            // and Profile/Audit's as strings. JavaScript has no enums, so all three
            // are strings here — the representation the emitter already gives a
            // branch tag (`result.tag === "found"`). One vocabulary, not two.
            .metatype_binding => |mb| {
                try self.writeFmt("{s}{{\n", .{indent});
                const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
                defer self.allocator.free(inner);
                try self.writeFmt("{s}const {s} = {{ source: \"{s}\", destination: ", .{ inner, mb.binding, mb.source_event });
                if (mb.dest_event) |dest| {
                    try self.writeFmt("\"{s}\"", .{dest});
                } else {
                    try self.write("null");
                }
                // A void event's completion carries no branch name. The Zig
                // reference spells that `__void` (emitter_helpers.zig:3400) and the
                // JS record must agree, or an arm reading `.branch` sees a different
                // string on each target.
                try self.writeFmt(", branch: \"{s}\"", .{if (mb.branch.len == 0) "__void" else mb.branch});
                // Transition is the cheap metatype: transition metadata only, no
                // clock read. Profile adds the timestamp, Audit adds the payload
                // slot — the same three shapes, field for field, as the Zig taps
                // namespace (emitter_helpers.zig:3424).
                if (!std.mem.eql(u8, mb.metatype, "Transition")) {
                    try self.write(", timestamp_ns: Number(process.hrtime.bigint())");
                    if (std.mem.eql(u8, mb.metatype, "Audit")) try self.write(", payload: null");
                }
                try self.write(" };\n");
                try self.emitPreambleContinuations(continuations, inner);
                try self.writeFmt("{s}}}\n", .{indent});
                return true;
            },
            else => return false,
        }
        try self.emitPreambleContinuations(continuations, indent);
        return true;
    }

    /// Emit a `captured { … }` write as field stores into the cell.
    ///
    /// SNAPSHOT SEMANTICS (ruled 2026-07-02, pinned 320_102): every field
    /// expression reads the INCOMING cell state, then all stores land — so the
    /// meaning of a `captured { }` literal cannot depend on its field order. With
    /// two or more fields the right-hand sides hoist into block-scoped temps
    /// before any store; a lone field cannot observe itself, so it stores
    /// directly. Same decision, same reasoning, same output shape as the Zig
    /// reference (emitter_helpers.zig:10432) — only the `let`/`const` spelling
    /// differs.
    ///
    /// Temps are index-named inside their own block: a field NAME can be an
    /// element write (`arr[i]`), which is not an identifier, and the block keeps
    /// two assignment nodes at the same depth from colliding.
    fn emitAssignment(self: *Emitter, asgn: anytype, indent: []const u8) JsEmitError!void {
        if (asgn.fields.len > 1) {
            try self.writeFmt("{s}{{\n", .{indent});
            const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
            defer self.allocator.free(inner);
            for (asgn.fields, 0..) |field, i| {
                try self.writeFmt("{s}const __koru_asgn_{d} = ", .{ inner, i });
                try self.writeJsExpr(if (field.expression_str) |e| e else field.type);
                try self.write(";\n");
            }
            for (asgn.fields, 0..) |field, i| {
                try self.writeFmt("{s}{s}.{s} = __koru_asgn_{d};\n", .{ inner, asgn.target, field.name, i });
            }
            try self.writeFmt("{s}}}\n", .{indent});
            return;
        }
        for (asgn.fields) |field| {
            try self.writeFmt("{s}{s}.{s} = ", .{ indent, asgn.target, field.name });
            try self.writeJsExpr(if (field.expression_str) |e| e else field.type);
            try self.write(";\n");
        }
    }

    /// Emit the body of a terminal continuation spliced inline by a template
    /// marker. Unlike `emitTerminalContinuation`, there is NO tag-dispatch guard
    /// and NO `const binding = result.branch;` — the template's own conditional
    /// (e.g. `if (cond)`) does the branching, and a template continuation has no
    /// result value to read a payload from. We emit only the body itself.
    fn emitInlineContinuationBody(self: *Emitter, cont: *const ast.Continuation, indent: []const u8) JsEmitError!void {
        const node = cont.node orelse return; // empty branch (`| else |> _`) — nothing to emit
        switch (node) {
            .invocation => |*inv| {
                try self.emitInvocationWithContinuations(inv, cont.continuations, indent);
            },
            .terminal => {}, // `_` — the arm does nothing.
            // A PRODUCE arm under a template head (`config = if(strict) | then ->
            // { a: 1 }`): the arm satisfies the ENCLOSING event's output, so it
            // returns. Same node, same lowering as the non-template arm — the
            // template only decides WHICH arm runs.
            .branch_constructor => |*bc| try self.emitBranchConstructorReturn(bc, indent),
            .expression => |expr| {
                try self.writeFmt("{s}return ", .{indent});
                try self.writeJsExpr(expr);
                try self.write(";\n");
            },
            else => {
                if (try self.emitVoidStatementNode(node, cont.continuations, indent)) return;
                log.err("[js_emitter] inline continuation body is a {s}, which this target does not model\n", .{@tagName(node)});
                return JsEmitError.UnsupportedConstruct;
            },
        }
    }

    /// The call-site `: name` bind, or null when there is nothing to NAME.
    ///
    /// `_` is a discard, not an identifier. Zig spells it `_ = expr;` and may
    /// repeat that in one scope; JS has no such form, so `const _ = …` twice in
    /// a flow is a hard `SyntaxError: Identifier '_' has already been declared`.
    /// Every other binding site in this emitter already knows that — the
    /// terminal-continuation bind skips `_`, the inline splice skips it, the
    /// auto-discharge splice renames it `_auto_<id>`. The call-site bind is the
    /// one that did not, which is why a chain of discarded discharges
    /// (`dispose(x: s.h): _ |> dispose(x: s.g): _`) emitted uncompilable JS.
    fn namedReturnBinding(inv: *const ast.Invocation) ?[]const u8 {
        const rb = inv.return_binding orelse return null;
        if (std.mem.eql(u8, rb, "_")) return null;
        return rb;
    }

    /// Recursively emit a dispatch: resolve `inv`'s event, build a `Handlers_<id>`
    /// from the EFFECT continuations (each an effect-handler method), call the
    /// event handler (passing `Handlers_<id>` iff the event has effect branches),
    /// then drive the TERMINAL continuations. Each effect-handler method whose
    /// body is itself an invocation recurses through this same function, so an
    /// arbitrarily deep void-effect chain lowers to nested `Handlers_<id>`
    /// objects. `indent` is the leading whitespace for statements at this depth.
    fn emitInvocationWithContinuations(
        self: *Emitter,
        inv: *const ast.Invocation,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        // TRANSFORM-PRODUCED INLINE BODY: a comptime|transform (`std.io:print`,
        // `print.ln`, `eprint`, …) reroutes its invocation to a `.impl` stub and
        // stores the target-lowered code on `inv.inline_body`. A top-level flow
        // splices this in emitFlow; a NESTED invocation (an `~if`/`~for` branch
        // body, an effect-handler body) recurses here, so we must splice it too —
        // otherwise we emit `main_module.impl_event.handler(...)` against a stub
        // that doesn't exist. Mirrors the Zig emitter routing `inv.inline_body`
        // through emitInlineBodyNode (emitter_helpers.zig ~7287), the same helper
        // top-level flows use.
        if (inv.inline_body) |inline_body_raw| {
            const stripped = stripInlineStmtMarker(inline_body_raw);
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripped, continuations, indent, &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(continuations, consumed, indent);
            return;
        }
        // SUBFLOW-IMPLEMENTED EFFECT FIRE. Inside the impl of an effect-bearing
        // event, a call to one of THAT event's own effect arms is the FIRING, not
        // an event invocation — `each(i)` hands `i` to whoever installed `each`.
        // Checked before event resolution because an arm name is not an event and
        // never resolves to one. Twin of emitter_helpers.zig:6902.
        if (self.impl_event) |impl_ev| {
            if (findEffectArm(impl_ev, &inv.path)) |arm| {
                try self.emitEffectArmFire(arm, inv, continuations, indent);
                return;
            }
        }

        const event = self.findEventDecl(&inv.path) orelse {
            log.err("[js_emitter] flow invokes unresolved event\n", .{});
            return JsEmitError.UnresolvedEvent;
        };

        var event_has_effect = false;
        var all_effects_void = true;
        var terminal_branches: usize = 0;
        for (event.branches) |b| {
            if (b.kind == .effect) {
                event_has_effect = true;
                if (b.resume_type != null) all_effects_void = false;
            } else {
                terminal_branches += 1;
            }
        }
        // A BARE-RETURN event (`-> T` with no `|` arms) hands back the value
        // itself: no `.tag`, no per-branch field. A call site may still write an
        // arm (`| value v -> v` — `value` is the implicit name of the one
        // outcome), and that arm binds the WHOLE result.
        const callee_bare_return = terminal_branches == 0 and event.return_type != null;

        // VOID-EFFECT FAST PATH: when the invoked event is a producer whose
        // effect branches are ALL void (no `-> T` resume value) AND its body is a
        // `|js` proc, do NOT build a `Handlers_<id>` closure tower. Instead splice
        // the proc body inline, textually replacing each `<op>(<arg>)` effect call
        // with the recursively-emitted handler body in a block:
        //   `{ const <binding> = <arg>; <handler sub-flow> }`
        // This collapses an arbitrarily deep void chain into straight-line nested
        // blocks (no closures) so V8 keeps it on the fast path at any depth.
        // Resume-value effects keep the closure form below — splicing a statement
        // block where an expression value is expected would break them.
        //
        // The splice is TEXTUAL, so it needs host text to splice into: a producer
        // implemented by a subflow has no proc body, and its firing sites are AST
        // nodes the closure path already lowers correctly. Gate on the proc rather
        // than discovering its absence one frame deeper.
        //
        // The splice inlines the proc body INCLUDING its `return .{ .done = … }`,
        // and that `return` exits the ENCLOSING flow function — so terminal arms,
        // emitted nowhere, simply vanish. `sink { ! ?pulse i64 | done | err }`
        // printed its three pulses and then silently dropped `done`: correct
        // output followed by a missing line, the hardest kind of divergence to
        // read. The closure path below already handles the mixed shape —
        // Handlers_<id> for the effect arms, a real handler call, then a `.tag`
        // dispatch — so route there and keep the splice for what it was built
        // for: pure void producers (140_011, the pipe_dN depth benchmarks).
        //
        // TWO PREDICATES, deliberately, and they were found independently: W3 and
        // W2 gated on the event DECLARING no terminal branch, W4 on no terminal
        // continuation having a BODY. The first implies the second, so the
        // conjunction is the first — but both are written out because they are
        // different questions (what the event promises vs what this call site
        // does with it) and a later relaxation of one must not silently take the
        // other with it. This guard's failure mode is a dropped line and exit 0;
        // it earns the belt and the braces.
        var terminal_has_body = false;
        for (continuations) |*c| {
            if (c.kind != .terminal) continue;
            const n = c.node orelse continue;
            if (n != .terminal) terminal_has_body = true;
        }
        if (event_has_effect and all_effects_void and terminal_branches == 0 and !terminal_has_body and
            self.findJsProcIn(self.items, &event.path) != null)
        {
            try self.emitInlineVoidProducer(event, inv, continuations, indent);
            return;
        }

        // PLAIN-EVENT INLINE FAST PATH: when the invoked event has NO effect
        // branches AND no continuations to drive AND a `|js` proc body without
        // `return`, splice the body inline at the call site with args bound as
        // locals. Saves the `main_module.<ev>_event.handler({...args})` lookup
        // and the per-call arg-object allocation — same shape as
        // emitInlineVoidProducer's input-field binding, applied to handlers.
        //
        // Conservative on `return`: a body with early-exit semantics can't be
        // inlined as a plain block (there's no enclosing function to return
        // from). Plain-event handlers in the void/side-effecting style 140_011
        // exercises don't return; if they do, fall through to the handler-call
        // path which preserves return semantics.
        if (!event_has_effect and continuations.len == 0 and inv.return_binding == null) {
            if (self.findJsProcIn(self.items, &event.path)) |proc| {
                if (std.mem.indexOf(u8, proc.body.text, "return ") == null and
                    std.mem.indexOf(u8, proc.body.text, "return;") == null and
                    std.mem.indexOf(u8, proc.body.text, "return\n") == null and
                    std.mem.indexOf(u8, proc.body.text, "return}") == null)
                {
                    try self.emitInlinePlainHandler(event, proc, inv, indent);
                    return;
                }
            }
        }

        // Only allocate an id (and thus a result binding) when a terminal
        // continuation actually reads the result. Effect-only frames (the void
        // chain) don't need a `result_<id>`.
        var needs_result = false;
        var terminal_count: usize = 0;
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            terminal_count += 1;
            if (cont.binding != null and !std.mem.eql(u8, cont.binding.?, "_")) {
                needs_result = true;
            }
            // A destructure reads the payload just as a binding does, field by
            // field (`| found { name, age }`).
            if (cont.destructure.len > 0) needs_result = true;
        }
        // With 2+ terminal branches we must dispatch on the returned `.tag`,
        // which requires the result value even when no branch binds a payload.
        // A bare return carries no tag, and by construction has exactly one
        // outcome, so it never dispatches.
        if (terminal_count >= 2 and !callee_bare_return) needs_result = true;
        // A call-site `: name` bind (`double(a: 21): d |> …`) NAMES the produced
        // value and the continuations after it reference that name, so the result
        // must be materialised even when no branch arm binds a payload. Mirrors
        // the Zig emitter's `inv.return_binding orelse result_var`
        // (emitter_helpers.zig:7290).
        if (namedReturnBinding(inv) != null) needs_result = true;

        // Build Handlers_<id> from the effect continuations. The id is monotonic
        // so nested frames get distinct names.
        var handlers_name: ?[]const u8 = null;
        defer if (handlers_name) |hn| self.allocator.free(hn);

        if (event_has_effect) {
            const hid = self.nextId();
            handlers_name = try std.fmt.allocPrint(self.allocator, "Handlers_{d}", .{hid});
            // The Handlers object opens here; its method bodies are emitted at a
            // deeper indent, then it closes before the handler call below.
            try self.writeFmt("{s}const {s} = {{\n", .{ indent, handlers_name.? });
            const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
            defer self.allocator.free(inner_indent);
            // ONE method per ARM, not per continuation. Two `! pair` handlers
            // that differ only by a `when` guard are two continuations naming
            // the same fire; emitting a method each would put duplicate keys in
            // this object literal and silently keep only the last.
            for (continuations, 0..) |*cont, ci| {
                if (cont.kind != .effect) continue;
                var already = false;
                for (continuations[0..ci]) |*prev| {
                    if (prev.kind == .effect and std.mem.eql(u8, prev.branch, cont.branch)) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                try self.emitEffectHandlerMethod(continuations, cont.branch, inner_indent);
            }
            // OMITTED OPTIONAL ARM → a producer-side no-op (Option B, ruled
            // 2026-07-19, pinned by 400_168/400_170). A yielding arm is invoked by
            // DIRECT CALL from the proc body, so leaving it off the Handlers object
            // makes the alias `const warn = H.warn;` undefined and the fire throws
            // `warn is not a function` at runtime — a silent no-op turned into a
            // crash. Install an empty method instead; V8 inlines it away.
            //
            // A RESUMING arm (`-> T`) is deliberately NOT filled in: 400_148 gives
            // the proc the presence truth as a nullable callable and lets it choose
            // its own fallback (`if (ask) …`), which an empty method returning
            // undefined would silently defeat.
            for (event.branches) |*b| {
                if (b.kind != .effect) continue;
                if (b.resume_type != null or b.resume_arms != null) continue;
                if (continuationForBranch(continuations, b.name) != null) continue;
                var noop_buf: [256]u8 = undefined;
                try self.writeFmt("{s}{s}(_) {{}},\n", .{ inner_indent, lowerIdentBuf(&noop_buf, b.name) });
            }
            try self.writeFmt("{s}}};\n", .{indent});
        }

        var ev_name_buf: [256]u8 = undefined;
        const ev_name = lowerIdentBuf(&ev_name_buf, event.path.segments[event.path.segments.len - 1]);
        // The call-site bind, when present, IS the result's name — the following
        // pipeline spells it, so a synthetic `result_<id>` would leave it unbound.
        const result_name: ?[]const u8 = if (!needs_result) null else if (namedReturnBinding(inv)) |rb|
            try self.allocator.dupe(u8, rb)
        else blk: {
            const rid = self.nextId();
            break :blk try std.fmt.allocPrint(self.allocator, "result_{d}", .{rid});
        };
        defer if (result_name) |rn| self.allocator.free(rn);

        if (result_name) |rn| {
            try self.writeFmt("{s}const {s} = main_module.{s}_event.handler(", .{ indent, rn, ev_name });
        } else {
            try self.writeFmt("{s}main_module.{s}_event.handler(", .{ indent, ev_name });
        }
        try self.emitArgsObject(inv.args);
        if (event_has_effect) {
            try self.writeFmt(", {s}", .{handlers_name.?});
        }
        try self.write(");\n");

        // A BIND-POSITION destructure (`~locate(): { pos: { x, y }, label } |> …`).
        // The parser binds the whole result to a synthetic `__ret_destr_N` and
        // parks the shape on `inv.return_destructure`; the pipeline downstream
        // spells the FIELD names, so without these consts every one of them is
        // an unbound identifier. Zig twin: emitter_helpers.zig:7372.
        if (inv.return_destructure.len > 0) {
            if (result_name) |rn| {
                try self.emitDestructureBindings(inv.return_destructure, rn, indent);
            }
        }

        // Drive terminal continuations. With 2+ branches we dispatch on the
        // returned `.tag`; a lone branch always fires, so no guard is needed.
        const needs_dispatch = terminal_count >= 2 and !callee_bare_return;
        try self.emitTerminalContinuations(continuations, result_name, indent, needs_dispatch, callee_bare_return);
    }

    /// Emit a FIRE of one of the enclosing event's own effect arms. The Zig
    /// emitter routes this through the comptime `__H` handlers param
    /// (emitter_helpers.zig:6876 `writeArmFireCallExpr`); the JS handler has
    /// already aliased every arm to a local (`const each = H.each;`), so the fire
    /// is a plain call on that alias.
    ///
    /// A VOID arm produces nothing — bare statement. A RESUMING arm produces the
    /// resume value, bound to the call-site `:` name or, for a multi-arm resume
    /// sum, dispatched on `.tag` through the ordinary terminal-continuation path.
    fn emitEffectArmFire(
        self: *Emitter,
        arm: *const ast.Branch,
        inv: *const ast.Invocation,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        const has_resume = arm.resume_type != null or arm.resume_arms != null;

        var terminal_count: usize = 0;
        var needs_result = false;
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            terminal_count += 1;
            if (cont.binding != null and !std.mem.eql(u8, cont.binding.?, "_")) needs_result = true;
        }
        if (terminal_count >= 2) needs_result = true;
        if (namedReturnBinding(inv) != null) needs_result = true;
        // A void arm hands back nothing, so there is no value to name however
        // many arms the site writes.
        if (!has_resume) needs_result = false;

        const result_name: ?[]const u8 = if (!needs_result) null else if (namedReturnBinding(inv)) |rb|
            try self.allocator.dupe(u8, rb)
        else blk: {
            const rid = self.nextId();
            break :blk try std.fmt.allocPrint(self.allocator, "result_{d}", .{rid});
        };
        defer if (result_name) |rn| self.allocator.free(rn);

        try self.write(indent);
        // An OPTIONAL void arm may simply not be installed. Zig folds the fire
        // away with `@hasDecl(__H, …)`; the JS twin of "not installed" is an
        // absent method, so the alias is undefined and the guard reads it.
        if (arm.is_optional and !has_resume) {
            try self.write("if (");
            try self.writeIdent(arm.name);
            try self.write(") ");
        }
        if (result_name) |rn| try self.writeFmt("const {s} = ", .{rn});
        try self.writeIdent(arm.name);
        try self.write("(");
        try self.emitArmFirePayload(arm, inv);
        try self.write(");\n");

        // A single `-> T` resume hands back the value untagged; only a multi-arm
        // resume sum (`! ask i64 | halved i64 | timeout`) carries a `.tag`.
        const plain_resume = arm.resume_type != null and arm.resume_arms == null;
        const needs_dispatch = terminal_count >= 2 and !plain_resume;
        try self.emitTerminalContinuations(continuations, result_name, indent, needs_dispatch, plain_resume);
    }

    /// The payload passed to an arm fire. Mirrors emitter_helpers.zig:6848
    /// `writeArmFirePayload` shape-for-shape, in JS spelling:
    ///   payloadless arm → nothing (`ask()`)
    ///   identity / wildcard payload → the single arg's value (`each(i * i)`)
    ///   named-field payload → an object literal (`ask({ a: 1, b: 2 })`)
    fn emitArmFirePayload(self: *Emitter, arm: *const ast.Branch, inv: *const ast.Invocation) JsEmitError!void {
        if (arm.payload.fields.len == 0 and !arm.payload.is_wildcard) return;

        const is_identity = arm.payload.fields.len == 1 and
            std.mem.eql(u8, arm.payload.fields[0].name, "__type_ref");
        if (is_identity or arm.payload.is_wildcard) {
            if (inv.args.len > 0) try self.writeJsExpr(inv.args[0].value);
            return;
        }

        try self.write("{ ");
        for (inv.args, 0..) |arg, i| {
            if (i > 0) try self.write(", ");
            try self.writeFmt("{s}: ", .{arg.name});
            try self.writeJsExpr(arg.value);
        }
        try self.write(" }");
    }

    /// PLAIN-EVENT INLINE. The invoked `event` has no effect branches and the
    /// caller doesn't need a return value (no continuations to drive). Splice
    /// the `|js` proc body inline at the call site, binding each event field
    /// to its arg expression as a local. Saves the per-call
    /// `main_module.<ev>_event.handler({...})` object-lookup and arg-object
    /// allocation that the closure-path would emit.
    ///
    /// The collision-skip on `const <field> = <arg>` matches the dispatch-block
    /// pattern (140_012-style): when the arg expression IS the field name as a
    /// bare identifier, the outer scope's binding is already in scope.
    fn emitInlinePlainHandler(
        self: *Emitter,
        event: *const ast.EventDecl,
        proc: *const ast.ProcDecl,
        inv: *const ast.Invocation,
        indent: []const u8,
    ) JsEmitError!void {
        try self.writeFmt("{s}{{\n", .{indent});
        const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(inner);

        for (event.input.fields) |field| {
            const arg_val = argValueByName(inv.args, field.name) orelse {
                log.err("[js_emitter] plain-event inline '{s}' missing arg for field '{s}'\n", .{ event.path.segments[event.path.segments.len - 1], field.name });
                return JsEmitError.UnsupportedConstruct;
            };
            // Skip self-referential `const x = x;` — outer is already in scope.
            if (std.mem.eql(u8, field.name, arg_val)) continue;
            try self.writeFmt("{s}const {s} = {s};\n", .{ inner, field.name, arg_val });
        }

        try self.emitReindented(proc.body.text, inner);
        try self.write("\n");
        try self.writeFmt("{s}}}\n", .{indent});
    }

    /// VOID-EFFECT INLINE SPLICE. The invoked `event` is a producer whose effect
    /// branches are all void. Emit its `|js` proc body inline, with each effect
    /// call `<op>(<arg>)` textually replaced by the spliced handler body:
    ///   `{ const <binding> = <arg>; <recursively-emitted handler sub-flow> }`.
    ///
    /// `inv` supplies the producer's input fields (bound as `const f = <val>;`
    /// locals, exactly as the closure path does inside the handler). The effect
    /// op name is the event's effect-branch name (`branch.name`, e.g. "item"/"v").
    /// The handler sub-flow is the matching effect continuation's body — itself
    /// an invocation-with-continuations, so we recurse into
    /// `emitInvocationWithContinuations`, which takes THIS same void path again
    /// for the next void producer, or the closure/direct path at a plain event.
    ///
    /// Mirrors emitter_helpers.zig:3186 `emitInlineCodeResolvingSplices` (the Zig
    /// emitter's in-scope handler splice) — same `{ const <binding> = <arg>; { <body> } }`
    /// shape, which is valid JS too.
    fn emitInlineVoidProducer(
        self: *Emitter,
        event: *const ast.EventDecl,
        inv: *const ast.Invocation,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        const proc = self.findJsProcIn(self.items, &event.path) orelse {
            log.err("[js_emitter] void producer '{s}' has no |js proc body\n", .{event.path.segments[event.path.segments.len - 1]});
            return JsEmitError.NoJsProcBody;
        };

        // Evaluate each arg into a uniquely-named temp in the ENCLOSING scope,
        // BEFORE opening the producer block. This is what makes a bare-identifier
        // arg (`outer(n)` → field `n`, value `n`) correct: `const __arg_K = n;`
        // reads the outer `n`, and the in-block `const n = __arg_K;` binds the
        // field without a TDZ self-reference (`const n = n;` would throw). It
        // also matches the closure path, where the arg object was evaluated in
        // the caller scope before the handler bound `input.n`.
        const ArgTemp = struct { field: []const u8, temp: []const u8 };
        var temps = std.ArrayList(ArgTemp).empty;
        defer {
            for (temps.items) |t| self.allocator.free(t.temp);
            temps.deinit(self.allocator);
        }
        for (event.input.fields) |field| {
            const arg_val = argValueByName(inv.args, field.name) orelse {
                log.err("[js_emitter] void producer '{s}' missing arg for field '{s}'\n", .{ event.path.segments[event.path.segments.len - 1], field.name });
                return JsEmitError.UnsupportedConstruct;
            };
            const tid = self.nextId();
            const temp = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{tid});
            try temps.append(self.allocator, .{ .field = field.name, .temp = temp });
            try self.writeFmt("{s}const {s} = {s};\n", .{ indent, temp, arg_val });
        }

        // Open a block so the producer's input-field locals don't leak into the
        // enclosing scope (`const m = <temp>;` etc.).
        try self.writeFmt("{s}{{\n", .{indent});
        const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(inner);

        for (temps.items) |t| {
            try self.writeFmt("{s}const {s} = {s};\n", .{ inner, t.field, t.temp });
        }

        // Splice the proc body, replacing each `<op>(<arg>)` effect call with the
        // recursively-emitted handler body. We iterate the body once, handling
        // ALL of the producer's void effect ops (pump.kz-shaped producers have a
        // single effect op, but the loop generalizes cleanly).
        try self.emitProcBodyWithSplicedEffectCalls(proc.body.text, event, continuations, inner);

        try self.writeFmt("{s}}}\n", .{indent});
    }

    /// Scan `body` (opaque |js host code) for each effect op call `<op>(<arg>)`
    /// and replace it (plus a trailing `;`) with the spliced handler block. Text
    /// outside the matched calls is emitted verbatim (re-indented per line).
    ///
    /// The op names come from `event`'s effect branches; for each we find the
    /// matching effect continuation in `continuations` (by `cont.branch == op`)
    /// to source the handler binding + body. Balanced-paren arg parse mirrors
    /// emitter_helpers.zig:3271-3291.
    fn emitProcBodyWithSplicedEffectCalls(
        self: *Emitter,
        body: []const u8,
        event: *const ast.EventDecl,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");

        var pos: usize = 0;
        while (pos < trimmed.len) {
            // Find the earliest effect-op call at-or-after `pos`. We search for
            // each op name followed (after optional spaces) by `(`, taking the
            // leftmost match. Op names are assumed to appear only as the effect
            // call in these controlled procs (fine for the spike).
            var best_call_start: ?usize = null;
            var best_op_branch: ?*const ast.Continuation = null;
            var best_arg: []const u8 = "";
            var best_after: usize = 0;

            for (event.branches) |*b| {
                if (b.kind != .effect) continue;
                // Host text spells the lowered identifier — search that form.
                var op_ident_buf: [256]u8 = undefined;
                const op_ident = lowerIdentBuf(&op_ident_buf, b.name);
                const found = findOpCall(trimmed, pos, op_ident) orelse continue;
                if (best_call_start == null or found.call_start < best_call_start.?) {
                    // An OMITTED OPTIONAL arm is not an error — Option B (ruled
                    // 2026-07-19, pinned by 400_170) says the fire is a
                    // producer-side no-op, so the inline rewriter DROPS the call.
                    // A required arm with no handler is a different animal and
                    // still refuses loudly.
                    const cont = continuationForBranch(continuations, b.name);
                    if (cont == null and !b.is_optional) {
                        log.err("[js_emitter] void effect op '{s}' has no matching continuation\n", .{b.name});
                        return JsEmitError.UnsupportedConstruct;
                    }
                    best_call_start = found.call_start;
                    best_after = found.after;
                    best_arg = found.arg;
                    best_op_branch = cont;
                }
            }

            const call_start = best_call_start orelse {
                // No more effect calls — emit the remaining body verbatim.
                try self.emitReindentedSlice(trimmed[pos..], indent);
                break;
            };

            // Emit body text before the call verbatim (re-indented).
            try self.emitReindentedSlice(trimmed[pos..call_start], indent);

            // Omitted optional arm: the call and its trailing `;` are simply gone.
            const cont = best_op_branch orelse {
                pos = best_after;
                continue;
            };

            // Splice the handler body in-scope:
            //   { const <binding> = <arg>; <handler sub-flow> }

            try self.write("\n");
            try self.writeFmt("{s}{{\n", .{indent});
            const block_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
            defer self.allocator.free(block_indent);

            // How many arms handle THIS fire, and does any of them select?
            // `! pair { a, b } when a > 2` and its unguarded sibling are two
            // continuations on one branch: the fire has to try them in order.
            var arm_count: usize = 0;
            var any_selective = false;
            for (continuations) |*c| {
                if (c.kind != .effect or !std.mem.eql(u8, c.branch, cont.branch)) continue;
                arm_count += 1;
                if (c.condition != null or c.destructure.len > 0) any_selective = true;
            }

            if (arm_count == 1 and !any_selective) {
                const binding = cont.binding orelse "_";
                if (std.mem.eql(u8, binding, "_")) {
                    // Throwaway binding — give it a unique name so nested splices at
                    // the same depth never collide (`_auto_<id>`), matching the
                    // closure path's `_auto_N` naming.
                    const tid = self.nextId();
                    try self.writeFmt("{s}const _auto_{d} = {s};\n", .{ block_indent, tid, best_arg });
                } else if (std.mem.eql(u8, binding, best_arg)) {
                    // Bare-identifier-collision case: the proc body has a local with
                    // the same name as the dispatch binding and passes it directly
                    // (`const c = ...; key(c)` paired with `! key c |> ...`). Emitting
                    // `const c = c;` self-references the inner const before init →
                    // ReferenceError (TDZ). The outer `c` is already in scope and IS
                    // the value the handler needs, so skip the redundant rebind.
                    // Pinned by 140_012_js_dispatch_binding_shadow.
                } else {
                    try self.writeFmt("{s}const {s} = {s};\n", .{ block_indent, binding, best_arg });
                }
                try self.emitSplicedArmBody(cont, block_indent);
            } else {
                // The fired payload is read by several arms, so it is named once
                // and each arm opens its own scope to bind off it — two arms may
                // both spell `a`. FIRST MATCH WINS, and a guard reads names its
                // own arm binds, so the test cannot be hoisted above them. This
                // is inside the PRODUCER's body, so a matched arm cannot `return`
                // its way out; the sentinel is the terminal side's `__matched_N`
                // by another name.
                const fid = self.nextId();
                const fire = try std.fmt.allocPrint(self.allocator, "__fire_{d}", .{fid});
                defer self.allocator.free(fire);
                try self.writeFmt("{s}const {s} = {s};\n", .{ block_indent, fire, best_arg });
                const sentinel = arm_count > 1;
                if (sentinel) try self.writeFmt("{s}let __fired_{d} = false;\n", .{ block_indent, fid });

                const arm_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{block_indent});
                defer self.allocator.free(arm_indent);
                const body_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{arm_indent});
                defer self.allocator.free(body_indent);

                for (continuations) |*arm| {
                    if (arm.kind != .effect or !std.mem.eql(u8, arm.branch, cont.branch)) continue;
                    try self.writeFmt("{s}{{\n", .{block_indent});
                    if (arm.destructure.len > 0) {
                        try self.emitDestructureBindings(arm.destructure, fire, arm_indent);
                    } else if (arm.binding) |b| {
                        if (!std.mem.eql(u8, b, "_")) {
                            try self.writeFmt("{s}const {s} = {s};\n", .{ arm_indent, b, fire });
                        }
                    }
                    if (sentinel or arm.condition != null) {
                        try self.writeFmt("{s}if (", .{arm_indent});
                        if (sentinel) try self.writeFmt("!__fired_{d}", .{fid});
                        if (arm.condition) |condition| {
                            if (sentinel) try self.write(" && ");
                            try self.writeJsExpr(condition);
                        }
                        try self.write(") {\n");
                        if (sentinel) try self.writeFmt("{s}__fired_{d} = true;\n", .{ body_indent, fid });
                        try self.emitSplicedArmBody(arm, body_indent);
                        try self.writeFmt("{s}}}\n", .{arm_indent});
                    } else {
                        try self.emitSplicedArmBody(arm, arm_indent);
                    }
                    try self.writeFmt("{s}}}\n", .{block_indent});
                }
            }

            try self.writeFmt("{s}}}\n", .{indent});
            pos = best_after;
        }
    }

    /// The body of ONE arm of a spliced effect fire, with its payload already
    /// named. The continuation's node is the next invocation; its own
    /// continuations drive the next level.
    fn emitSplicedArmBody(
        self: *Emitter,
        cont: *const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        const node = cont.node orelse {
            log.err("[js_emitter] void effect handler '{s}' has no body\n", .{cont.branch});
            return JsEmitError.UnsupportedConstruct;
        };
        switch (node) {
            .invocation => |*sub_inv| {
                try self.emitInvocationWithContinuations(sub_inv, cont.continuations, indent);
            },
            .terminal => {}, // `_` — nothing further.
            else => {
                log.err("[js_emitter] void effect handler body is not an invocation\n", .{});
                return JsEmitError.UnsupportedConstruct;
            },
        }

    }

    /// Re-indent a slice of opaque body text to `indent`, one line at a time.
    /// Unlike `emitReindented`, this does NOT trim the whole slice (callers pass
    /// pre-trimmed fragments) and writes a trailing newline structure suitable
    /// for splicing mid-body. Blank lines are skipped.
    fn emitReindentedSlice(self: *Emitter, text: []const u8, indent: []const u8) JsEmitError!void {
        var it = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (it.next()) |line| {
            const line_trimmed = std.mem.trim(u8, line, " \t\r");
            if (line_trimmed.len == 0) continue;
            if (!first) try self.write("\n");
            first = false;
            try self.write(indent);
            try self.write(line_trimmed);
        }
    }

    /// Emit ONE effect-handler method — the method for `branch` — gathering
    /// every continuation in `all` that handles that arm.
    ///
    /// SIMPLE SHAPE (one continuation, no `when` guard, no destructure): the
    /// payload binds straight to the method parameter and the body is emitted
    /// bare. Body shape follows the continuation's node:
    ///   - `.expression` (resume value, e.g. `! tick t |> t.acc + t.i`) →
    ///     `tick(t) { return <expr>; }`.
    ///   - `.invocation` (void effect whose body invokes the next event, e.g.
    ///     `! v _ |> mid(...)`) → recurse into the sub-flow, building this
    ///     handler's nested `Handlers_<id>` from the continuation's own
    ///     continuations.
    ///   - null / `.terminal` → empty body.
    ///
    /// CHAIN SHAPE (2+ continuations, or a guard, or a destructure): the arms
    /// stop being one body. The payload binds to a synthetic parameter and each
    /// arm becomes a scoped block that names what it needs off it — `binding`,
    /// or the per-field consts of a `! pair { a, b }` destructure — then tests
    /// its own guard. A guard reads names the arm itself binds, so it cannot be
    /// hoisted above them; FIRST MATCH WINS, so a matching arm returns rather
    /// than falling into its siblings. Same rule the terminal side follows with
    /// its `__matched_N` sentinel, expressed here as early return because a
    /// handler method is a function and can simply leave.
    fn emitEffectHandlerMethod(
        self: *Emitter,
        all: []const ast.Continuation,
        branch: []const u8,
        indent: []const u8,
    ) JsEmitError!void {
        // Method KEY is a JS identifier (`H.<name>` after the alias) — lower.
        var method_buf: [256]u8 = undefined;
        const method_ident = lowerIdentBuf(&method_buf, branch);

        var arm_count: usize = 0;
        var first_arm: ?*const ast.Continuation = null;
        for (all) |*c| {
            if (c.kind != .effect or !std.mem.eql(u8, c.branch, branch)) continue;
            arm_count += 1;
            if (first_arm == null) first_arm = c;
        }
        const cont = first_arm orelse return;

        if (arm_count == 1 and cont.condition == null and cont.destructure.len == 0) {
            try self.emitEffectHandlerSimple(cont, method_ident, indent);
            return;
        }

        const param = try std.fmt.allocPrint(self.allocator, "__arm_{d}", .{self.nextId()});
        defer self.allocator.free(param);
        try self.writeFmt("{s}{s}({s}) {{\n", .{ indent, method_ident, param });
        const arm_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(arm_indent);
        const body_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{arm_indent});
        defer self.allocator.free(body_indent);

        for (all) |*arm| {
            if (arm.kind != .effect or !std.mem.eql(u8, arm.branch, branch)) continue;

            // A block per arm, so two arms may both name `a` off the same fire.
            try self.writeFmt("{s}{{\n", .{arm_indent});
            if (arm.destructure.len > 0) {
                try self.emitDestructureBindings(arm.destructure, param, body_indent);
            } else if (arm.binding) |b| {
                if (!std.mem.eql(u8, b, "_")) {
                    try self.writeFmt("{s}const {s} = {s};\n", .{ body_indent, b, param });
                }
            }

            const guard_indent = if (arm.condition != null) body_indent else arm_indent;
            if (arm.condition) |condition| {
                try self.writeFmt("{s}if (", .{body_indent});
                try self.writeJsExpr(condition);
                try self.write(") {\n");
            }
            const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{guard_indent});
            defer self.allocator.free(inner_indent);

            try self.emitEffectArmBody(arm, inner_indent);
            try self.writeFmt("{s}return;\n", .{inner_indent});

            if (arm.condition != null) try self.writeFmt("{s}}}\n", .{body_indent});
            try self.writeFmt("{s}}}\n", .{arm_indent});
        }
        try self.writeFmt("{s}}},\n", .{indent});
    }

    /// The one-continuation, unguarded, undestructured effect handler: payload
    /// straight onto the parameter, body emitted bare.
    fn emitEffectHandlerSimple(
        self: *Emitter,
        cont: *const ast.Continuation,
        method_ident: []const u8,
        indent: []const u8,
    ) JsEmitError!void {
        const param = cont.binding orelse "_";
        const node = cont.node orelse {
            // No body — emit an empty method.
            try self.writeFmt("{s}{s}({s}) {{}},\n", .{ indent, method_ident, param });
            return;
        };
        switch (node) {
            .expression => |expr| {
                try self.writeFmt("{s}{s}({s}) {{ return ", .{ indent, method_ident, param });
                try self.writeJsExpr(expr);
                try self.write("; },\n");
            },
            .terminal => {
                try self.writeFmt("{s}{s}({s}) {{}},\n", .{ indent, method_ident, param });
            },
            else => {
                try self.writeFmt("{s}{s}({s}) {{\n", .{ indent, method_ident, param });
                const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
                defer self.allocator.free(inner_indent);
                try self.emitEffectArmBody(cont, inner_indent);
                try self.writeFmt("{s}}},\n", .{indent});
            },
        }
    }

    /// The BODY of one effect arm, with the payload already named. Shared by the
    /// simple and chained shapes so an arm lowers the same way either side of
    /// the guard question.
    fn emitEffectArmBody(
        self: *Emitter,
        cont: *const ast.Continuation,
        indent: []const u8,
    ) JsEmitError!void {
        const node = cont.node orelse return;
        switch (node) {
            .terminal => {},
            .expression => |expr| {
                try self.writeFmt("{s}return ", .{indent});
                try self.writeJsExpr(expr);
                try self.write(";\n");
            },
            // VOID effect handler whose body is the nested sub-flow. No
            // `return` — recurse to emit the nested dispatch.
            .invocation => |*inv| {
                try self.emitInvocationWithContinuations(inv, cont.continuations, indent);
            },
            // A RESUME-ARM produce (`! ask n => halved n - 10`): a multi-arm
            // resume sum is consumed as `|` branches at the firing site, so the
            // handler hands back the tagged arm the producer then dispatches on.
            .branch_constructor => |*bc| {
                try self.emitBranchConstructorReturn(bc, indent);
            },
            else => {
                // A STATEMENT body (`! each _ |> captured { … }` — a capture write
                // as the loop's whole handler, 832/833). It produces nothing, so
                // the method wraps it and returns nothing.
                if (!try self.emitVoidStatementNode(node, cont.continuations, indent)) {
                    log.err("[js_emitter] effect handler body is a {s}, which this target does not model\n", .{@tagName(node)});
                    return JsEmitError.UnsupportedConstruct;
                }
            },
        }
    }

    /// Drive the TERMINAL continuations of one dispatch.
    ///
    /// PLAIN shape (no `when` guard, no `|?` catchall): one independent
    /// `if (r.tag === …)` per arm. The tags are mutually exclusive, so order
    /// cannot matter and nothing needs to know an earlier arm already fired.
    ///
    /// GUARDED / CATCHALL shape: the arms stop being mutually exclusive. Two arms
    /// may share a tag and differ only by their `when` guard, and a `|?` catchall
    /// matches whatever no earlier arm did. FIRST MATCH WINS — and a guard reads
    /// names the arm itself binds, so its test cannot be hoisted above the
    /// binding. That is a matched-sentinel chain:
    ///
    ///     let __matched_0 = false;
    ///     if (!__matched_0 && r.tag === "found") { const age = r.found.age;
    ///         if (age > 40) { __matched_0 = true; … } }
    ///     if (!__matched_0 && r.tag === "found") { const age = r.found.age;
    ///         __matched_0 = true; … }
    ///     if (!__matched_0) { __matched_0 = true; … }     // `|?` catchall
    ///
    /// The plain shape is kept as-is rather than folded into the sentinel form:
    /// it is what every already-green dispatch emits, and it owes nothing to the
    /// guarded case.
    fn emitTerminalContinuations(
        self: *Emitter,
        continuations: []const ast.Continuation,
        result_name: ?[]const u8,
        indent: []const u8,
        dispatch: bool,
        bare_return: bool,
    ) JsEmitError!void {
        var needs_chain = false;
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            if (cont.condition != null or cont.is_catchall) needs_chain = true;
        }

        var matched: ?[]const u8 = null;
        defer if (matched) |m| self.allocator.free(m);
        if (needs_chain) {
            matched = try std.fmt.allocPrint(self.allocator, "__matched_{d}", .{self.nextId()});
            try self.writeFmt("{s}let {s} = false;\n", .{ indent, matched.? });
        }

        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            try self.emitTerminalContinuation(cont, result_name, indent, dispatch, bare_return, matched);
        }
    }

    /// Emit a terminal continuation: `| done r |> BODY`.
    /// `const r = <result>.done;` then emit BODY.
    ///
    /// `bare_return` says the producer hands back the value ITSELF — no `.tag`,
    /// no per-branch field — so any arm here binds the whole result whatever it
    /// calls itself (`| value v`, the implicit one-outcome name).
    ///
    /// `matched` names the sentinel of a guarded chain, or is null in the plain
    /// shape. See `emitTerminalContinuations` for why the two shapes differ.
    fn emitTerminalContinuation(
        self: *Emitter,
        cont: *const ast.Continuation,
        result_name: ?[]const u8,
        indent: []const u8,
        dispatch: bool,
        bare_return: bool,
        matched: ?[]const u8,
    ) JsEmitError!void {
        // Owned indent strings for the (at most two) nesting levels this arm opens.
        var indents: [2][]u8 = undefined;
        var indent_count: usize = 0;
        defer for (indents[0..indent_count]) |s| self.allocator.free(s);
        var body_indent = indent;
        var open_braces: usize = 0;

        const deeper = struct {
            fn f(em: *Emitter, base: []const u8) JsEmitError![]u8 {
                return std.fmt.allocPrint(em.allocator, "{s}  ", .{base});
            }
        }.f;

        if (matched) |mv| {
            // Chain gate: nothing matched yet, and — unless this is the catchall,
            // which matches whatever is left — the tag is ours.
            try self.writeFmt("{s}if (!{s}", .{ indent, mv });
            if (dispatch and !cont.is_catchall and cont.branch.len > 0) {
                const rn = result_name orelse {
                    log.err("[js_emitter] guarded terminal chain needs a result value but none was emitted\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                };
                try self.writeFmt(" && {s}.tag === \"{s}\"", .{ rn, cont.branch });
            }
            try self.write(") {\n");
            indents[indent_count] = try deeper(self, indent);
            body_indent = indents[indent_count];
            indent_count += 1;
            open_braces += 1;
        } else if (dispatch) {
            // With 2+ mutually-exclusive branches, guard the body on the returned
            // tag so only the branch the event actually produced runs. A lone
            // branch always fires and is emitted unguarded.
            const rn = result_name orelse {
                log.err("[js_emitter] terminal dispatch needs a result value but none was emitted\n", .{});
                return JsEmitError.UnsupportedConstruct;
            };
            try self.writeFmt("{s}if ({s}.tag === \"{s}\") {{\n", .{ indent, rn, cont.branch });
            indents[indent_count] = try deeper(self, indent);
            body_indent = indents[indent_count];
            indent_count += 1;
            open_braces += 1;
        }

        if (cont.binding) |binding| {
            if (!std.mem.eql(u8, binding, "_")) {
                const rn = result_name orelse {
                    log.err("[js_emitter] terminal continuation binds a result but no result binding was emitted\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                };
                // A BARE-RETURN event (`-> T`) has no tag and no branch, so the
                // result IS the payload; a named branch reads its own field off
                // the tagged object. Same split the Zig emitter makes between
                // `enclosing_bare_return` and `result.<branch>`.
                if (bare_return or cont.branch.len == 0) {
                    try self.writeFmt("{s}const ", .{body_indent});
                    try self.writeIdent(binding);
                    try self.writeFmt(" = {s};\n", .{rn});
                } else {
                    try self.writeFmt("{s}const ", .{body_indent});
                    try self.writeIdent(binding);
                    try self.write(" = ");
                    try self.writeMember(rn, cont.branch);
                    try self.write(";\n");
                }
            }
        }

        // A shape-destructure at the binding position (`| found { name, age }`)
        // binds each payload field BY NAME. Mutually exclusive with `binding`.
        if (cont.destructure.len > 0) {
            const rn = result_name orelse {
                log.err("[js_emitter] terminal continuation destructures a payload but no result binding was emitted\n", .{});
                return JsEmitError.UnsupportedConstruct;
            };
            const base = if (bare_return or cont.branch.len == 0)
                try self.allocator.dupe(u8, rn)
            else if (isJsIdentifier(cont.branch))
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ rn, cont.branch })
            else
                try std.fmt.allocPrint(self.allocator, "{s}[\"{s}\"]", .{ rn, cont.branch });
            defer self.allocator.free(base);
            try self.emitDestructureBindings(cont.destructure, base, body_indent);
        }

        // The `when` guard runs AFTER the bindings — it reads them.
        if (cont.condition) |condition| {
            try self.writeFmt("{s}if (", .{body_indent});
            try self.writeJsExpr(condition);
            try self.write(") {\n");
            indents[indent_count] = try deeper(self, body_indent);
            body_indent = indents[indent_count];
            indent_count += 1;
            open_braces += 1;
        }

        // Claim the match before the body: the body may `return`.
        if (matched) |mv| try self.writeFmt("{s}{s} = true;\n", .{ body_indent, mv });

        if (cont.node) |node| {
            switch (node) {
                .invocation => |*inv| {
                    // A terminal body is itself a dispatch — recurse so terminal
                    // bodies that fire further effects are handled uniformly.
                    try self.emitInvocationWithContinuations(inv, cont.continuations, body_indent);
                },
                .terminal => {}, // `_` — flow ends, nothing to emit.
                // A PRODUCE arm (`| break => stopped`). Inside a subflow impl's
                // handler this is the event's outcome, so it returns; the same
                // node at top level ends the flow, which `return` also does.
                .branch_constructor => |*bc| try self.emitBranchConstructorReturn(bc, body_indent),
                // A bare expression arm (`| ok o |> o * 2`) produces a value the
                // enclosing handler returns.
                .expression => |expr| {
                    try self.writeFmt("{s}return ", .{body_indent});
                    try self.writeJsExpr(expr);
                    try self.write(";\n");
                },
                else => {
                    if (!try self.emitVoidStatementNode(node, cont.continuations, body_indent)) {
                        log.err("[js_emitter] terminal continuation body is a {s}, which this target does not model\n", .{@tagName(node)});
                        return JsEmitError.UnsupportedConstruct;
                    }
                },
            }
        }

        // Close in reverse. Level 1's brace was opened at `indent`; level 2's at
        // level 1's body indent, i.e. `indents[0]`.
        var to_close = open_braces;
        while (to_close > 0) : (to_close -= 1) {
            const close_at = if (to_close == 1) indent else indents[to_close - 2];
            try self.writeFmt("{s}}}\n", .{close_at});
        }
    }

    /// Bind a shape-destructure's fields off `base`, recursing into nested
    /// destructures (`| found { name, addr: { city } }`) by lengthening the access
    /// path. A `_` slot is a discard and binds nothing.
    fn emitDestructureBindings(
        self: *Emitter,
        fields: []const ast.DestructureField,
        base: []const u8,
        indent: []const u8,
    ) JsEmitError!void {
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, "_")) continue;
            if (field.sub.len > 0) {
                const path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ base, field.name });
                defer self.allocator.free(path);
                try self.emitDestructureBindings(field.sub, path, indent);
                continue;
            }
            try self.writeFmt("{s}const ", .{indent});
            try self.writeIdent(field.name);
            try self.write(" = ");
            try self.writeMember(base, field.name);
            try self.write(";\n");
        }
    }

    /// Emit the args as a JS object literal: `{ name: value, ... }`. Arg values
    /// are Koru expression strings (e.g. "10", "r", `a ++ b`), so they go through
    /// the same `++`-to-`+` lowering as any other Koru expression.
    fn emitArgsObject(self: *Emitter, args: []const ast.Arg) JsEmitError!void {
        if (args.len == 0) {
            try self.write("{}");
            return;
        }
        try self.write("{ ");
        for (args, 0..) |arg, idx| {
            if (idx > 0) try self.write(", ");
            // The key is a PARAMETER name — an identifier, so it lowers. The
            // handler destructures it back out under the same lowering, which is
            // what keeps `outer-val` spelled `outer_val` on both sides of the call.
            try self.writeIdent(arg.name);
            try self.write(": ");
            try self.writeJsExpr(arg.value);
        }
        try self.write(" }");
    }

    /// Re-indent a multi-line opaque body to `indent`, trimming leading blank
    /// lines and trailing whitespace. Mirrors CodeEmitter.emitReindentedText's
    /// intent without depending on the Zig emitter's indent-level machinery.
    fn emitReindented(self: *Emitter, body: []const u8, indent: []const u8) JsEmitError!void {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try self.write("\n");
            first = false;
            const line_trimmed = std.mem.trimRight(u8, line, " \t\r");
            // Strip common leading whitespace per-line, then re-indent.
            const content = std.mem.trimLeft(u8, line_trimmed, " \t");
            if (content.len == 0) continue;
            try self.write(indent);
            try self.write(content);
        }
    }
};

/// Does this proc target string name a `|template|` proc that applies to the JS
/// build? The first `|`-segment names the mechanism (`template`, or
/// `template(<arg>)`); a later segment, when present, names the HOST. So:
///
///   `template`         → target-agnostic, applies everywhere
///   `template|js`      → ours
///   `template|zig`     → the other target's; NOT ours, so a JS build with only
///                        this variant still has no body and says so
///
/// The mechanism-name test mirrors visitor_emitter.zig:3730.
fn templateProcTargetsJs(target: []const u8) bool {
    var it = std.mem.splitScalar(u8, target, '|');
    const mechanism = it.next() orelse return false;
    if (!std.mem.eql(u8, mechanism, "template") and
        !std.mem.startsWith(u8, mechanism, "template(")) return false;

    var saw_host = false;
    while (it.next()) |seg| {
        saw_host = true;
        if (std.mem.eql(u8, seg, JS_TARGET)) return true;
    }
    return !saw_host;
}

/// Strip the leading `//@koru:inline_stmt\n` marker that template_processor
/// prepends to indicate a statement-shaped (rather than expression-shaped)
/// rendered body. For host-language splicing the marker isn't needed.
fn stripInlineStmtMarker(text: []const u8) []const u8 {
    const marker = "//@koru:inline_stmt\n";
    if (std.mem.startsWith(u8, text, marker)) return text[marker.len..];
    return text;
}

/// Is `path` a bare reference to one of `event`'s own EFFECT arms? A single
/// unqualified segment matching an `!` branch is a FIRE, not an invocation.
///
/// The Zig target's copy is `emitter_helpers.findEffectArm` (:6782) and this is
/// deliberately a second one: `emitter_helpers` is the Zig CodeEmitter's module
/// (type_registry, tap_registry, struct_literal, compiler_config), and importing
/// it here to reach a six-line AST predicate would put the whole Zig backend in
/// the JS emitter's module graph. The predicate is the branch-kind rule itself,
/// which lives in ast.Branch — if that rule ever changes, both read it.
fn findEffectArm(event: *const ast.EventDecl, path: *const ast.DottedPath) ?*const ast.Branch {
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

/// Look up an invocation arg's value string by field name.
fn argValueByName(args: []const ast.Arg, name: []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.eql(u8, arg.name, name)) return arg.value;
    }
    return null;
}

/// Find the effect continuation whose branch name matches `op`.
fn continuationForBranch(continuations: []const ast.Continuation, op: []const u8) ?*const ast.Continuation {
    for (continuations) |*cont| {
        if (cont.kind == .effect and std.mem.eql(u8, cont.branch, op)) return cont;
    }
    return null;
}

/// Does this arm (or anything nested under it) jump back to `label`? That is what
/// separates a fold's LOOPING arms — which belong inside the `while` and in its
/// condition — from its EXIT arms, which run after it. Recursive because the jump
/// may sit under a nested dispatch (`| more s |> check(s) | ok |> @L(…)`).
/// Predicate twin of emitter_helpers.findLoopingBranches (:9062), which allocates
/// the branch-name list it only ever asks membership questions of.
fn contLoopsTo(cont: *const ast.Continuation, label: []const u8) bool {
    if (cont.node) |node| switch (node) {
        .label_jump => |lj| if (std.mem.eql(u8, lj.label, label)) return true,
        .label_apply => |l| if (std.mem.eql(u8, l, label)) return true,
        else => {},
    };
    for (cont.continuations) |*nested| {
        if (contLoopsTo(nested, label)) return true;
    }
    return false;
}

const OpCallMatch = struct {
    call_start: usize, // index of the op name's first char
    after: usize, // index just past the call (and a swallowed trailing `;`)
    arg: []const u8, // the balanced-paren arg, trimmed
};

/// Find the first occurrence at-or-after `from` of `<op>(<balanced arg>)` in
/// `body`, where the `op` is an identifier-boundary match (so `vee` doesn't
/// match op `v`). Returns the span and the trimmed arg, swallowing a trailing
/// `;`. Mirrors the balanced-paren parse in emitter_helpers.zig:3273-3291.
fn findOpCall(body: []const u8, from: usize, op: []const u8) ?OpCallMatch {
    var search: usize = from;
    while (std.mem.indexOfPos(u8, body, search, op)) |idx| {
        const end = idx + op.len;
        // Identifier-boundary check: the char before and after the op must not
        // be part of an identifier, so `v` doesn't match inside `valve`.
        const before_ok = idx == 0 or !isIdentChar(body[idx - 1]);
        if (!before_ok) {
            search = idx + 1;
            continue;
        }
        // Skip optional whitespace between the op name and `(`.
        var p = end;
        while (p < body.len and (body[p] == ' ' or body[p] == '\t')) : (p += 1) {}
        if (p >= body.len or body[p] != '(') {
            search = idx + 1;
            continue;
        }
        // Balanced-paren arg parse.
        const arg_start = p + 1;
        var depth: usize = 1;
        var j = arg_start;
        while (j < body.len and depth > 0) : (j += 1) {
            if (body[j] == '(') {
                depth += 1;
            } else if (body[j] == ')') {
                depth -= 1;
            }
        }
        const arg = std.mem.trim(u8, body[arg_start .. j - 1], " \t");
        var after = j; // past the closing ')'
        // Swallow a trailing `;` — the splice is a block statement.
        if (after < body.len and body[after] == ';') after += 1;
        return .{ .call_start = idx, .after = after, .arg = arg };
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}
/// Can `name` be written after a `.`? Letters, digits, `_` and `$`, not starting
/// with a digit. A reserved word IS legal as a property name in ES5+, so
/// `result.default` needs no special case — only a name JS cannot spell at all,
/// which in this pipeline means a kebab branch or field name, needs brackets.
fn isJsIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |c| {
        if (!(isIdentChar(c) or c == '$')) return false;
    }
    return true;
}

/// Is `text[at]` (a `&`) in PREFIX position — Zig address-of — rather than infix
/// bitwise-and? Prefix means nothing that could END an operand precedes it: start
/// of text, an opener, a comma, or an operator. `a & b` is infix and means the
/// same thing in both languages; `&items` is an address JS does not have.
///
/// The one case a character test alone gets wrong is a preceding KEYWORD. In
/// `for (const x of &items)` the char before is `f`, which looks exactly like the
/// end of an identifier — but `of` cannot END an operand, it demands one. That is
/// not a corner: it is the shape the `for|template|js` body renders for every
/// `~for(&xs)` in the corpus. So the scan reads back a whole WORD and asks what
/// the word is, not what its last letter is.
fn isPrefixPosition(text: []const u8, at: usize) bool {
    var j = at;
    while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t')) j -= 1;
    if (j == 0) return true;
    const p = text[j - 1];
    if (!(isIdentChar(p) or p == ')' or p == ']' or p == '}' or p == '"' or p == '\'')) return true;
    if (!isIdentChar(p)) return false;
    var w = j;
    while (w > 0 and isIdentChar(text[w - 1])) w -= 1;
    const operand_expecting = [_][]const u8{
        "of",   "in",    "return", "typeof", "case",  "new",
        "delete", "void", "yield",  "await",  "instanceof",
    };
    for (operand_expecting) |kw| {
        if (std.mem.eql(u8, text[w..j], kw)) return true;
    }
    return false;
}

/// At `text[at] == '['`, is this the opening of a Zig ARRAY LITERAL type prefix
/// (`[_]i32{`, `[3]i32{`, `[2][2]i32{`, `[_]const u8{`)? Returns the index just
/// past the `{` when so. An ordinary INDEX (`arr[i]`) has no brace after the
/// type slot and returns null, as does a plain slice type with no literal body.
fn zigArrayLiteralOpen(text: []const u8, at: usize) ?usize {
    var j = at;
    // One or more `[…]` dimension groups.
    var dims: usize = 0;
    while (j < text.len and text[j] == '[') {
        const close = std.mem.indexOfScalarPos(u8, text, j, ']') orelse return null;
        // A dimension is `_` or a constant expression; a `[` inside it means this
        // is not the simple literal shape this lowering models.
        if (std.mem.indexOfScalarPos(u8, text[0..close], j + 1, '[') != null) return null;
        j = close + 1;
        dims += 1;
    }
    if (dims == 0) return null;
    // The element type: identifier chars, `.`, and any `const`/`*` qualifiers.
    while (j < text.len and (isIdentChar(text[j]) or text[j] == '.' or text[j] == '*' or text[j] == ' ')) j += 1;
    if (j >= text.len or text[j] != '{') return null;
    return j + 1;
}

/// At `text[at] == '{'` opening a `.{ … }`, are its top-level entries POSITIONAL
/// (`.{ 0, 0 }` — a tuple, i.e. a JS array) rather than NAMED (`.{ .ok = v }` — a
/// branch constructor or struct, whose JS shape this lowering deliberately does
/// not guess)? An empty `.{}` counts as positional: it is the void payload.
fn isPositionalTuple(text: []const u8, at: usize) bool {
    var j = at + 1;
    var depth: usize = 0;
    while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '(', '[', '{' => depth += 1,
            ')', ']' => depth -= 1,
            '}' => {
                if (depth == 0) return true;
                depth -= 1;
            },
            // A top-level `.name` is the named form. `.{` nested inside is a row
            // of its own and is decided when the scan reaches it.
            '.' => if (depth == 0 and j + 1 < text.len and isIdentChar(text[j + 1])) return false,
            else => {},
        }
    }
    return true;
}

fn pathsEqual(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

/// `long` ends with `short` on a `.`/`:` boundary — so `std.io` matches `io`.
/// Mirrors visitor_emitter.zig:qualifierSuffixMatch.
fn qualifierSuffixMatch(long: []const u8, short: []const u8) bool {
    if (long.len <= short.len) return false;
    if (!std.mem.endsWith(u8, long, short)) return false;
    const sep = long[long.len - short.len - 1];
    return sep == '.' or sep == ':';
}

/// Two module qualifiers refer to the same module if equal, or one is a dotted
/// suffix of the other (`std.io` ≡ `io`). Mirrors visitor_emitter.zig.
fn moduleQualifiersMatch(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return qualifierSuffixMatch(a, b) or qualifierSuffixMatch(b, a);
}

/// Module-aware path equality. `decl_path` is a declaration's path (usually
/// unqualified, sitting inside the module named `current_module`); `inv_path`
/// is a call site's path (often module-qualified). When exactly one side is
/// qualified, the qualifier must match the effective module context
/// (`current_module`, or `main_module` at top level). Mirrors
/// visitor_emitter.zig:pathsEqualWithModule.
fn pathsEqualWithModule(
    decl_path: *const ast.DottedPath,
    inv_path: *const ast.DottedPath,
    current_module: ?[]const u8,
    main_module: []const u8,
) bool {
    const a_mod = decl_path.module_qualifier;
    const b_mod = inv_path.module_qualifier;
    if (a_mod != null and b_mod != null) {
        if (!moduleQualifiersMatch(a_mod.?, b_mod.?)) return false;
    } else if ((a_mod != null) != (b_mod != null)) {
        const qual = if (a_mod != null) a_mod.? else b_mod.?;
        const effective = current_module orelse main_module;
        if (effective.len == 0) return false;
        if (!moduleQualifiersMatch(effective, qual)) return false;
    }
    if (decl_path.segments.len != inv_path.segments.len) return false;
    for (decl_path.segments, inv_path.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

