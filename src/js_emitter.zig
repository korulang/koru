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

pub const JsEmitError = error{
    OutOfMemory,
    UnresolvedEvent,
    UnsupportedConstruct,
    NoJsProcBody,
};

/// Emit JS for the given program. Returns a heap-allocated string owned by the
/// caller's allocator.
pub fn emit(allocator: std.mem.Allocator, program: *const ast.Program) JsEmitError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var em = Emitter{ .allocator = allocator, .buf = &buf, .items = program.items };

    try em.write("const main_module = {\n");

    // Phase 1: emit each event decl (matched to its |js proc) as an object member.
    for (program.items) |*item| {
        if (item.* == .event_decl) {
            try em.emitEventDecl(&item.event_decl);
        }
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

    /// Find the |js proc whose path matches `event_path` (segment-equal).
    /// Mirrors the Zig emitter's proc-selection (visitor_emitter.zig:2204+) but
    /// keys on target == "js" instead of the configured default lang.
    fn findJsProc(self: *Emitter, event_path: *const ast.DottedPath) ?*const ast.ProcDecl {
        for (self.items) |*item| {
            if (item.* != .proc_decl) continue;
            const proc = &item.proc_decl;
            if (!pathsEqual(&proc.path, event_path)) continue;
            const target = proc.target orelse continue;
            if (std.mem.eql(u8, target, "js")) return proc;
        }
        return null;
    }

    fn findEventDecl(self: *Emitter, path: *const ast.DottedPath) ?*const ast.EventDecl {
        for (self.items) |*item| {
            if (item.* != .event_decl) continue;
            if (pathsEqual(&item.event_decl.path, path)) return &item.event_decl;
        }
        return null;
    }

    /// Emit one event decl as `<name>_event: { handler(input, H?) { ... } }`.
    fn emitEventDecl(self: *Emitter, event: *const ast.EventDecl) JsEmitError!void {
        const proc = self.findJsProc(&event.path) orelse {
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
        for (event.branches) |b| {
            if (b.kind == .effect) {
                event_has_effect = true;
                break;
            }
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

fn pathsEqual(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}
