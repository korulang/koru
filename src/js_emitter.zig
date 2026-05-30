// js_emitter.zig — minimal, pump.kz-shaped Koru → JavaScript emitter.
//
// SCOPE: this is the JS-target spike. It walks `ctx.ast` (a *const ast.Program)
// and emits runnable JavaScript for the vaxis-shaped event pump in
// `_phase1/pump.kz`. It mirrors the structure of the Zig emitter
// (visitor_emitter.zig + emitter_helpers.zig) but rewrites every output site as
// JS. It handles EXACTLY the constructs pump.kz uses:
//
//   - event decls → `<name>_event: { handler(input, H?) { ... } }`
//   - effect-bearing events take an `H` param and bind `const op = H.op;` for
//     each effect branch op; plain events take only `input`.
//   - `|js` proc bodies, spliced verbatim (opaque host code) after binding
//     input fields as `const field = input.field;`.
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
            // Skip injected meta-event flows (koru:start / koru:end). These are
            // compiler infrastructure, not user code; the spike emits only the
            // user pump. They live in the `koru` module-qualifier namespace.
            if (item.flow.invocation.path.module_qualifier) |mq| {
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

    /// Emit one event decl as `<name>_event: { handler(input, H?) { ... } }`.
    /// `scope` is the item list to resolve the `|js` proc within (the program
    /// for top-level events, the module's items for a module event).
    fn emitEventDecl(self: *Emitter, event: *const ast.EventDecl, scope: []const ast.Item) JsEmitError!void {
        const proc = self.findJsProcIn(scope, &event.path) orelse {
            // An event with no |js proc body is incoherent for the JS target.
            log.debug("[js_emitter] event '{s}' has no |js proc body\n", .{event.path.segments[event.path.segments.len - 1]});
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

        try self.writeFmt("  {s}_event: {{\n", .{name});
        if (has_effect) {
            try self.write("    handler(input, H) {\n");
            // Bind each effect-branch op as a local: `const tick = H.tick;`
            for (event.branches) |b| {
                if (b.kind != .effect) continue;
                try self.writeFmt("      const {s} = H.{s};\n", .{ b.name, b.name });
            }
        } else {
            try self.write("    handler(input) {\n");
        }

        // Bind input fields as locals: `const n = input.n;`
        for (event.input.fields) |field| {
            try self.writeFmt("      const {s} = input.{s};\n", .{ field.name, field.name });
        }

        // Splice the |js proc body verbatim (opaque host code), re-indented.
        try self.emitReindented(proc.body, "      ");
        try self.write("\n    },\n  },\n");
    }

    /// Emit the JS-implemented events of an imported module. An event is emitted
    /// only if it has a `|js` proc in this module's own scope; events with only
    /// `|zig`/`[comptime]` variants (the compiler/stdlib infrastructure) are
    /// silently skipped — they have no JS implementation, so they're simply
    /// absent on this target. Recurses into nested modules.
    fn emitModuleEventDecls(self: *Emitter, module: *const ast.ModuleDecl) JsEmitError!void {
        for (module.items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    if (self.findJsProcIn(module.items, &event.path) == null) continue;
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
        try self.emitInvocationWithContinuations(&flow.invocation, flow.continuations, "    ");
        try self.write("  },\n");
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
        const event = self.findEventDecl(&inv.path) orelse {
            log.debug("[js_emitter] flow invokes unresolved event\n", .{});
            return JsEmitError.UnresolvedEvent;
        };

        var event_has_effect = false;
        var all_effects_void = true;
        for (event.branches) |b| {
            if (b.kind == .effect) {
                event_has_effect = true;
                if (b.resume_type != null) all_effects_void = false;
            }
        }

        // VOID-EFFECT FAST PATH: when the invoked event is a producer whose
        // effect branches are ALL void (no `-> T` resume value), do NOT build a
        // `Handlers_<id>` closure tower. Instead splice the producer's |js body
        // inline, textually replacing each `<op>(<arg>)` effect call with the
        // recursively-emitted handler body in a block:
        //   `{ const <binding> = <arg>; <handler sub-flow> }`
        // This collapses an arbitrarily deep void chain into straight-line
        // nested blocks (no closures) so V8 keeps it on the fast path at any
        // depth. Resume-value effects keep the closure form below — splicing a
        // statement block where an expression value is expected would break them.
        if (event_has_effect and all_effects_void) {
            try self.emitInlineVoidProducer(event, inv, continuations, indent);
            return;
        }

        // Only allocate an id (and thus a result binding) when a terminal
        // continuation actually reads the result. Effect-only frames (the void
        // chain) don't need a `result_<id>`.
        var needs_result = false;
        for (continuations) |*cont| {
            if (cont.kind == .terminal and cont.binding != null and
                !std.mem.eql(u8, cont.binding.?, "_"))
            {
                needs_result = true;
                break;
            }
        }

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

        const ev_name = event.path.segments[event.path.segments.len - 1];
        const result_name: ?[]const u8 = if (needs_result) blk: {
            const rid = self.nextId();
            break :blk try std.fmt.allocPrint(self.allocator, "result_{d}", .{rid});
        } else null;
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

        // Drive terminal continuations: read `.branch` off the result, emit body.
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            try self.emitTerminalContinuation(cont, result_name, indent);
        }
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
        try self.emitProcBodyWithSplicedEffectCalls(proc.body, event, continuations, inner);

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
                const found = findOpCall(trimmed, pos, b.name) orelse continue;
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

        const node = cont.node orelse {
            // No body — emit an empty method.
            try self.writeFmt("{s}{s}({s}) {{}},\n", .{ indent, cont.branch, param });
            return;
        };
        switch (node) {
            .expression => |expr| {
                try self.writeFmt("{s}{s}({s}) {{ return {s}; }},\n", .{ indent, cont.branch, param, expr });
            },
            .invocation => |*inv| {
                // VOID effect handler whose body is the nested sub-flow. No
                // `return` — recurse to emit the nested dispatch.
                try self.writeFmt("{s}{s}({s}) {{\n", .{ indent, cont.branch, param });
                const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
                defer self.allocator.free(inner_indent);
                try self.emitInvocationWithContinuations(inv, cont.continuations, inner_indent);
                try self.writeFmt("{s}}},\n", .{indent});
            },
            .terminal => {
                try self.writeFmt("{s}{s}({s}) {{}},\n", .{ indent, cont.branch, param });
            },
            else => {
                log.debug("[js_emitter] effect handler body is neither expression nor invocation\n", .{});
                return JsEmitError.UnsupportedConstruct;
            },
        }
    }

    /// Emit a terminal continuation: `| done r |> BODY`.
    /// `const r = <result>.done;` then emit BODY.
    fn emitTerminalContinuation(self: *Emitter, cont: *const ast.Continuation, result_name: ?[]const u8, indent: []const u8) JsEmitError!void {
        if (cont.binding) |binding| {
            if (!std.mem.eql(u8, binding, "_")) {
                const rn = result_name orelse {
                    log.debug("[js_emitter] terminal continuation binds a result but no result binding was emitted\n", .{});
                    return JsEmitError.UnsupportedConstruct;
                };
                try self.writeFmt("{s}const {s} = {s}.{s};\n", .{ indent, binding, rn, cont.branch });
            }
        }

        const node = cont.node orelse return;
        switch (node) {
            .invocation => |*inv| {
                // A terminal body is itself a dispatch — recurse so terminal
                // bodies that fire further effects are handled uniformly.
                try self.emitInvocationWithContinuations(inv, cont.continuations, indent);
            },
            .terminal => {}, // `_` — flow ends, nothing to emit.
            else => {
                log.debug("[js_emitter] terminal continuation body is not an invocation\n", .{});
                return JsEmitError.UnsupportedConstruct;
            },
        }
    }

    /// Emit the args as a JS object literal: `{ name: value, ... }`. Arg values
    /// are opaque host expression strings (e.g. "10", "r").
    fn emitArgsObject(self: *Emitter, args: []const ast.Arg) JsEmitError!void {
        if (args.len == 0) {
            try self.write("{}");
            return;
        }
        try self.write("{ ");
        for (args, 0..) |arg, idx| {
            if (idx > 0) try self.write(", ");
            try self.writeFmt("{s}: {s}", .{ arg.name, arg.value });
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
