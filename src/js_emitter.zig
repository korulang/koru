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

    /// Emit a top-level flow as `flowN()`. Partitions continuations into effect
    /// (`!`) and terminal (`|`), mirroring emitter_helpers.zig:emitFlow.
    fn emitFlow(self: *Emitter, flow: *const ast.Flow, flow_num: usize) JsEmitError!void {
        const event = self.findEventDecl(&flow.invocation.path) orelse {
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

        try self.writeFmt("  flow{d}() {{\n", .{flow_num});

        // Build Handlers_N from the effect continuations.
        const handlers_name = try std.fmt.allocPrint(self.allocator, "Handlers_{d}", .{flow_num});
        defer self.allocator.free(handlers_name);

        if (event_has_effect) {
            try self.writeFmt("    const {s} = {{ ", .{handlers_name});
            var first = true;
            for (flow.continuations) |*cont| {
                if (cont.kind != .effect) continue;
                if (!first) try self.write(", ");
                first = false;
                try self.emitEffectHandlerMethod(cont);
            }
            try self.write(" };\n");
        }

        // Emit the invocation: const result_N = main_module.<ev>_event.handler({args}, Handlers_N?);
        const ev_name = event.path.segments[event.path.segments.len - 1];
        try self.writeFmt("    const result_{d} = main_module.{s}_event.handler(", .{ flow_num, ev_name });
        try self.emitArgsObject(flow.invocation.args);
        if (event_has_effect) {
            try self.writeFmt(", {s}", .{handlers_name});
        }
        try self.write(");\n");

        // Drive terminal continuations: read `.branch` off the result, emit body.
        for (flow.continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            try self.emitTerminalContinuation(cont, flow_num);
        }

        try self.write("  },\n");
    }

    /// Emit one effect-handler method inside the Handlers_N object literal.
    /// `! tick t |> EXPR` → `tick(t) { return EXPR; }`. The body is a bare
    /// expression (resume value), so it lowers to `return <expr>;`.
    fn emitEffectHandlerMethod(self: *Emitter, cont: *const ast.Continuation) JsEmitError!void {
        const param = cont.binding orelse "_";
        try self.writeFmt("{s}({s}) {{ ", .{ cont.branch, param });

        const node = cont.node orelse {
            // No body — emit an empty method. (pump.kz always has a body.)
            try self.write("}");
            return;
        };
        switch (node) {
            .expression => |expr| {
                try self.writeFmt("return {s}; }}", .{expr});
            },
            else => {
                log.debug("[js_emitter] effect handler body is not a bare expression\n", .{});
                return JsEmitError.UnsupportedConstruct;
            },
        }
    }

    /// Emit a terminal continuation: `| done r |> BODY`.
    /// `const r = result_N.done;` then emit BODY.
    fn emitTerminalContinuation(self: *Emitter, cont: *const ast.Continuation, flow_num: usize) JsEmitError!void {
        if (cont.binding) |binding| {
            if (!std.mem.eql(u8, binding, "_")) {
                try self.writeFmt("    const {s} = result_{d}.{s};\n", .{ binding, flow_num, cont.branch });
            }
        }

        const node = cont.node orelse return;
        switch (node) {
            .invocation => |*inv| {
                try self.write("    ");
                try self.emitInvocationCall(inv);
                try self.write(";\n");
            },
            .terminal => {}, // `_` — flow ends, nothing to emit.
            else => {
                log.debug("[js_emitter] terminal continuation body is not an invocation\n", .{});
                return JsEmitError.UnsupportedConstruct;
            },
        }
    }

    /// Emit a call to an event from a terminal body:
    /// `main_module.<ev>_event.handler({args}, Handlers?)`.
    /// pump.kz's terminal calls a PLAIN event (report) → no Handlers arg.
    fn emitInvocationCall(self: *Emitter, inv: *const ast.Invocation) JsEmitError!void {
        const event = self.findEventDecl(&inv.path) orelse {
            log.debug("[js_emitter] terminal body invokes unresolved event\n", .{});
            return JsEmitError.UnresolvedEvent;
        };
        const ev_name = event.path.segments[event.path.segments.len - 1];
        try self.writeFmt("main_module.{s}_event.handler(", .{ev_name});
        try self.emitArgsObject(inv.args);
        try self.write(")");
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
