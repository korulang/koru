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
    for (program.items) |*item| {
        if (item.* != .host_line) continue;
        const host = file_types.hostLangOfFile(item.host_line.location.file) orelse continue;
        if (!std.mem.eql(u8, host, JS_TARGET)) continue;
        try em.write(item.host_line.content);
        try em.write("\n");
    }

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
        try em.write(std.mem.trim(u8, body, " \t\r\n"));
        try em.write("\n");
    }

    try em.write("const main_module = {\n");

    // Phase 1: emit each event decl (matched to its |js proc) as an object member.
    for (program.items) |*item| {
        if (item.* == .event_decl) {
            try em.emitEventDecl(&item.event_decl, program.items);
        }
    }

    // Phase 1b: emit event decls living in IMPORTED MODULES (e.g. `std.io`,
    // a `$app/contract` companion). A module's event is emitted iff it has a
    // `|js` proc in that same module — which naturally filters out compiler /
    // stdlib infrastructure modules (their procs are `|zig`/`[comptime]`, never
    // `|js`). The proc is resolved within the module's own scope so a same-named
    // proc in a sibling module can't be picked up by mistake.
    for (program.items) |*item| {
        if (item.* != .module_decl) continue;
        try em.emitModuleEventDecls(&item.module_decl);
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
            if (std.mem.eql(u8, target, JS_TARGET)) return proc;
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
            log.debug("[js_emitter] event '{s}' has no |js proc, immediate, or subflow body\n", .{event.path.segments[event.path.segments.len - 1]});
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
        for (event.input.fields) |field| {
            if (field.default) |dflt| {
                try self.writeFmt("      const {s} = {s}.{s} ?? ", .{ field.name, INPUT_PARAM, field.name });
                try self.writeJsExpr(dflt);
                try self.write(";\n");
            } else {
                try self.writeFmt("      const {s} = {s}.{s};\n", .{ field.name, INPUT_PARAM, field.name });
            }
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
                try self.writeJsExpr(pv);
            } else {
                try self.write("undefined");
            }
            try self.write(";\n");
            return;
        }

        try self.writeFmt("{s}return {{ tag: \"{s}\"", .{ indent, bc.branch_name });
        if (bc.plain_value) |pv| {
            try self.writeFmt(", {s}: ", .{bc.branch_name});
            try self.writeJsExpr(pv);
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

        if (flow.inline_body) |raw| {
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripInlineStmtMarker(raw), flow.body.continuations, indent, &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(flow.body.continuations, consumed, indent);
            return;
        }
        try self.emitInvocationWithContinuations(flow.inv(), flow.body.continuations, indent);
    }

    /// Write a KORU expression as JavaScript. Two rewrites, both mechanical:
    ///
    ///  - `++` → `+`. Koru spells string concatenation Zig's way, which the Zig
    ///    target passes straight through. In JavaScript `++` is the increment
    ///    operator, so an unlowered `a ++ b` is a SYNTAX error, not a wrong answer.
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
    fn writeLowered(self: *Emitter, text: []const u8, mode: LowerMode) JsEmitError!void {
        var i: usize = 0;
        var quote: ?u8 = null;
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
            if (c == '@') {
                if (try self.writeHostBuiltin(text, i)) |after| {
                    i = after;
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

        log.debug("[js_emitter] host builtin '@{s}' has no JS lowering\n", .{name});
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

    /// Emit the JS-implementable events of an imported module, resolving each
    /// body the same four ways `emitEventDecl` accepts and gating on whether that
    /// body bottoms out in JavaScript. Events whose implementation reaches a
    /// `|zig`/`[comptime]` leaf — the compiler and stdlib infrastructure — are
    /// absent on this target rather than emitted as handlers that cannot run.
    /// Recurses into nested modules.
    fn emitModuleEventDecls(self: *Emitter, module: *const ast.ModuleDecl) JsEmitError!void {
        for (module.items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    const site = DeclSite{ .decl = event, .scope = module.items };
                    if (!self.eventIsJsImplementable(site, IMPL_WALK_DEPTH)) continue;
                    try self.emitEventDecl(event, module.items);
                },
                .module_decl => |*nested| try self.emitModuleEventDecls(nested),
                else => {},
            }
        }
    }

    /// Emit a top-level flow as `flowN()`. The dispatch body is produced by the
    /// recursive `emitInvocationWithContinuations` helper, which handles both the
    /// shallow (single resume-value handler) and deep (nested void-effect chain)
    /// shapes uniformly.
    fn emitFlow(self: *Emitter, flow: *const ast.Flow, flow_num: usize) JsEmitError!void {
        try self.writeFmt("  flow{d}() {{\n", .{flow_num});
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
        } else {
            try self.emitInvocationWithContinuations(flow.inv(), flow.body.continuations, "    ");
        }
        try self.write("  },\n");
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
                var idx: usize = 0;
                var saw_digit = false;
                while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') : (i += 1) {
                    idx = idx * 10 + (trimmed[i] - '0');
                    saw_digit = true;
                }
                if (!saw_digit) {
                    // Malformed marker — fail loudly rather than leak it into JS.
                    log.debug("[js_emitter] malformed __koru_continue marker\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                }
                if (idx >= continuations.len) {
                    log.debug("[js_emitter] __koru_continue_{d} has no matching continuation (have {d})\n", .{ idx, continuations.len });
                    return JsEmitError.UnsupportedConstruct;
                }
                if (consumed) |c| {
                    if (idx < 64) c.* |= @as(u64, 1) << @intCast(idx);
                }
                const cont = &continuations[idx];
                const guarded = cont.condition != null;
                try self.write("{ ");
                if (guarded) {
                    try self.writeFmt("if ({s}) {{ ", .{cont.condition.?});
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
                log.debug("[js_emitter] malformed __koru_inline marker\n", .{});
                return JsEmitError.UnsupportedConstruct;
            }
            if (idx >= continuations.len) {
                log.debug("[js_emitter] __koru_inline_{d} has no matching continuation (have {d})\n", .{ idx, continuations.len });
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
                try self.writeFmt("if ({s}) {{ ", .{cont.condition.?});
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
                log.debug("[js_emitter] inline continuation body is not an invocation, produce, or expression\n", .{});
                return JsEmitError.UnsupportedConstruct;
            },
        }
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
            log.debug("[js_emitter] flow invokes unresolved event\n", .{});
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
        if (event_has_effect and all_effects_void and self.findJsProcIn(self.items, &event.path) != null) {
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
        if (inv.return_binding != null) needs_result = true;

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
            for (continuations) |*cont| {
                if (cont.kind != .effect) continue;
                try self.emitEffectHandlerMethod(cont, inner_indent);
            }
            try self.writeFmt("{s}}};\n", .{indent});
        }

        var ev_name_buf: [256]u8 = undefined;
        const ev_name = lowerIdentBuf(&ev_name_buf, event.path.segments[event.path.segments.len - 1]);
        // The call-site bind, when present, IS the result's name — the following
        // pipeline spells it, so a synthetic `result_<id>` would leave it unbound.
        const result_name: ?[]const u8 = if (!needs_result) null else if (inv.return_binding) |rb|
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
        if (inv.return_binding != null) needs_result = true;
        // A void arm hands back nothing, so there is no value to name however
        // many arms the site writes.
        if (!has_resume) needs_result = false;

        const result_name: ?[]const u8 = if (!needs_result) null else if (inv.return_binding) |rb|
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
                log.debug("[js_emitter] plain-event inline '{s}' missing arg for field '{s}'\n", .{ event.path.segments[event.path.segments.len - 1], field.name });
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
            log.debug("[js_emitter] void producer '{s}' has no |js proc body\n", .{event.path.segments[event.path.segments.len - 1]});
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
                log.debug("[js_emitter] void producer '{s}' missing arg for field '{s}'\n", .{ event.path.segments[event.path.segments.len - 1], field.name });
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
                    const cont = continuationForBranch(continuations, b.name) orelse {
                        log.debug("[js_emitter] void effect op '{s}' has no matching continuation\n", .{b.name});
                        return JsEmitError.UnsupportedConstruct;
                    };
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

            // Splice the handler body in-scope:
            //   { const <binding> = <arg>; <handler sub-flow> }
            const cont = best_op_branch.?;
            try self.write("\n");
            try self.writeFmt("{s}{{\n", .{indent});
            const block_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
            defer self.allocator.free(block_indent);

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

            // Recurse: emit the handler's sub-flow. The continuation's node is
            // the next invocation; its own continuations drive the next level.
            const node = cont.node orelse {
                log.debug("[js_emitter] void effect handler '{s}' has no body\n", .{cont.branch});
                return JsEmitError.UnsupportedConstruct;
            };
            switch (node) {
                .invocation => |*sub_inv| {
                    try self.emitInvocationWithContinuations(sub_inv, cont.continuations, block_indent);
                },
                .terminal => {}, // `_` — nothing further.
                else => {
                    log.debug("[js_emitter] void effect handler body is not an invocation\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                },
            }

            try self.writeFmt("{s}}}\n", .{indent});
            pos = best_after;
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

    /// Emit one effect-handler method inside a `Handlers_<id>` object literal.
    /// Body shape depends on the continuation's node:
    ///   - `.expression` (resume value, e.g. `! tick t |> t.acc + t.i`) →
    ///     `tick(t) { return <expr>; }`.
    ///   - `.invocation` (void effect whose body invokes the next event, e.g.
    ///     `! v _ |> mid(...)`) → recurse into the sub-flow, building this
    ///     handler's nested `Handlers_<id>` from the continuation's own
    ///     continuations.
    ///   - null / `.terminal` → empty body.
    fn emitEffectHandlerMethod(self: *Emitter, cont: *const ast.Continuation, indent: []const u8) JsEmitError!void {
        const param = cont.binding orelse "_";
        // Method KEY is a JS identifier (`H.<name>` after the alias) — lower.
        var method_buf: [256]u8 = undefined;
        const method_ident = lowerIdentBuf(&method_buf, cont.branch);

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
            .invocation => |*inv| {
                // VOID effect handler whose body is the nested sub-flow. No
                // `return` — recurse to emit the nested dispatch.
                try self.writeFmt("{s}{s}({s}) {{\n", .{ indent, method_ident, param });
                const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
                defer self.allocator.free(inner_indent);
                try self.emitInvocationWithContinuations(inv, cont.continuations, inner_indent);
                try self.writeFmt("{s}}},\n", .{indent});
            },
            // A RESUME-ARM produce (`! ask n => halved n - 10`): a multi-arm
            // resume sum is consumed as `|` branches at the firing site, so the
            // handler hands back the tagged arm the producer then dispatches on.
            .branch_constructor => |*bc| {
                try self.writeFmt("{s}{s}({s}) {{\n", .{ indent, method_ident, param });
                const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
                defer self.allocator.free(inner_indent);
                try self.emitBranchConstructorReturn(bc, inner_indent);
                try self.writeFmt("{s}}},\n", .{indent});
            },
            .terminal => {
                try self.writeFmt("{s}{s}({s}) {{}},\n", .{ indent, method_ident, param });
            },
            else => {
                log.debug("[js_emitter] effect handler body is not an expression, invocation, or produce\n", .{});
                return JsEmitError.UnsupportedConstruct;
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
                    log.debug("[js_emitter] guarded terminal chain needs a result value but none was emitted\n", .{});
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
                log.debug("[js_emitter] terminal dispatch needs a result value but none was emitted\n", .{});
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
                    log.debug("[js_emitter] terminal continuation binds a result but no result binding was emitted\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                };
                // A BARE-RETURN event (`-> T`) has no tag and no branch, so the
                // result IS the payload; a named branch reads its own field off
                // the tagged object. Same split the Zig emitter makes between
                // `enclosing_bare_return` and `result.<branch>`.
                if (bare_return or cont.branch.len == 0) {
                    try self.writeFmt("{s}const {s} = {s};\n", .{ body_indent, binding, rn });
                } else {
                    try self.writeFmt("{s}const {s} = {s}.{s};\n", .{ body_indent, binding, rn, cont.branch });
                }
            }
        }

        // A shape-destructure at the binding position (`| found { name, age }`)
        // binds each payload field BY NAME. Mutually exclusive with `binding`.
        if (cont.destructure.len > 0) {
            const rn = result_name orelse {
                log.debug("[js_emitter] terminal continuation destructures a payload but no result binding was emitted\n", .{});
                return JsEmitError.UnsupportedConstruct;
            };
            const base = if (bare_return or cont.branch.len == 0)
                try self.allocator.dupe(u8, rn)
            else
                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ rn, cont.branch });
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
                    log.debug("[js_emitter] terminal continuation body is not an invocation, produce, or expression\n", .{});
                    return JsEmitError.UnsupportedConstruct;
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
            try self.writeFmt("{s}const {s} = {s}.{s};\n", .{ indent, field.name, base, field.name });
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
            try self.writeFmt("{s}: ", .{arg.name});
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
