// Continuation Code Generation Helpers
//
// This module provides reusable functions for generating Zig code from
// AST continuation structures. Intended for use by comptime transforms
// that need to inline continuation handling (e.g., ~for).
//
// Design: String-based code generation that doesn't depend on CodeEmitter state.

const std = @import("std");
const ast = @import("ast");
const codegen_utils = @import("codegen_utils");

/// Generate indentation string for the given level
fn indent(allocator: std.mem.Allocator, level: usize) ![]const u8 {
    const spaces = try allocator.alloc(u8, level * 4);
    @memset(spaces, ' ');
    return spaces;
}

/// `.name = value` for each field, comma-separated — expression_str wins
/// over type for the value, and names go through the branch-name escaper.
/// The branch-constructor and assignment emits spell this list identically.
fn appendNamedFieldList(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, fields: []const ast.Field) !void {
    for (fields, 0..) |field, field_idx| {
        if (field_idx > 0) {
            try buf.appendSlice(allocator, ",");
        }
        try buf.appendSlice(allocator, " .");
        try codegen_utils.appendBranchName(buf, allocator, field.name);
        try buf.appendSlice(allocator, " = ");
        const value = if (field.expression_str) |expr| expr else field.type;
        try buf.appendSlice(allocator, value);
    }
}

/// Emit every continuation in `conts` at `indent_level` into `buf` — the
/// foreach `each`/`done` bodies and the conditional `then`/`else` bodies
/// all generate-then-append identically.
fn appendContinuationBodies(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    conts: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
    program_items: ?[]const ast.Item,
) !void {
    for (conts) |*cont| {
        const code = try generateContinuationChainWithPrefix(
            allocator,
            cont,
            main_module_name,
            result_counter,
            indent_level,
            var_prefix,
            program_items,
        );
        defer allocator.free(code);
        try buf.appendSlice(allocator, code);
    }
}


/// Build event path string: module.event_name_event
/// If module matches main_module_name, uses "main_module." prefix
fn buildEventPath(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    main_module_name: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;

    // Determine module prefix - matches writeModulePath in emitter_helpers.zig
    if (invocation.path.module_qualifier) |mq| {
        if (std.mem.eql(u8, mq, main_module_name)) {
            // Same module as main - use main_module.
            try buf.appendSlice(allocator, "main_module.");
        } else {
            const prefix = try codegen_utils.buildKoruModulePath(allocator, mq);
            defer allocator.free(prefix);
            try buf.appendSlice(allocator, prefix);
            try buf.append(allocator, '.');
        }
    } else {
        // No qualifier - use main_module
        try buf.appendSlice(allocator, "main_module.");
    }

    // Event name with segments joined by underscore. Kebab segments
    // (`parse-setup`, `read-file`) mangle to the same spelling the event
    // struct was emitted under (`parse_setup_event`). A hyphen in the
    // path is subtraction in Zig (350_024).
    for (invocation.path.segments, 0..) |seg, i| {
        if (i > 0) try buf.append(allocator, '_');
        try codegen_utils.appendMangled(&buf, allocator, seg);
    }

    // Add _event suffix
    try buf.appendSlice(allocator, "_event");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate a handler call: _ = module.event_event.handler(.{ .arg = val, ... });
/// Returns owned string - caller must free.
pub fn generateHandlerCall(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    main_module_name: []const u8,
    indent_level: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;

    // Indentation
    const ind = try indent(allocator, indent_level);
    defer allocator.free(ind);
    try buf.appendSlice(allocator, ind);

    // _ = module.event_event.handler(.{
    try buf.appendSlice(allocator, "_ = ");

    const event_path = try buildEventPath(allocator, invocation, main_module_name);
    defer allocator.free(event_path);
    try buf.appendSlice(allocator, event_path);

    try buf.appendSlice(allocator, ".handler(.{");

    // Args
    for (invocation.args, 0..) |arg, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, " .");
        try codegen_utils.appendBranchName(&buf, allocator, arg.name);
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, arg.value);
    }

    try buf.appendSlice(allocator, " });\n");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate a handler call that captures the result in a variable
/// Returns: const result_N = module.event_event.handler(.{ ... });
pub fn generateHandlerCallWithResult(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    main_module_name: []const u8,
    result_var: []const u8,
    indent_level: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;

    // Indentation
    const ind = try indent(allocator, indent_level);
    defer allocator.free(ind);
    try buf.appendSlice(allocator, ind);

    // const result_N = module.event_event.handler(.{
    try buf.appendSlice(allocator, "const ");
    try buf.appendSlice(allocator, result_var);
    try buf.appendSlice(allocator, " = ");

    const event_path = try buildEventPath(allocator, invocation, main_module_name);
    defer allocator.free(event_path);
    try buf.appendSlice(allocator, event_path);

    try buf.appendSlice(allocator, ".handler(.{");

    // Args
    for (invocation.args, 0..) |arg, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, " .");
        try codegen_utils.appendBranchName(&buf, allocator, arg.name);
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, arg.value);
    }

    try buf.appendSlice(allocator, " });\n");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Error type for codegen operations
pub const CodegenError = std.mem.Allocator.Error || error{FormatError};

/// The placeholder an inline body writes where its own block label goes. Its
/// presence is what makes the body an EXPRESSION rather than a STATEMENT.
const INLINE_LABEL_PLACEHOLDER = "__KORU_INLINE__";

/// Whether an inline body hands a value back through its block label.
///
/// A transform that sets `inline_body` may produce either kind of code. A body
/// that computes something writes `break :__KORU_INLINE__ <value>` and must be
/// wrapped as `const result_N = __koru_inline_N: { … }`. A body that merely DOES
/// something — a print arm in a router's pattern dispatch, say — writes a plain
/// call and never mentions the placeholder.
///
/// Emitting the labelled form for the second kind produced
/// `const result_0 = __koru_inline_1: (struct { … }).__kw("…", .{});;`, which
/// Zig rejects: a label may prefix a block or a loop, never a call expression.
/// So an effect arm inside a pattern-branch router could not compile at all,
/// and the emitted line even carried the two semicolons that give it away.
fn inlineBodyYieldsValue(body: []const u8) bool {
    return std.mem.indexOf(u8, body, INLINE_LABEL_PLACEHOLDER) != null;
}

/// A continuation with a non-empty branch name is a tagged-union arm (`| line l`).
/// Empty branch names are the rest of a `|>` chain, including a `: bind` on a
/// bare return — those are values, not tags.
fn continuationsAreTaggedUnion(nested: []const ast.Continuation) bool {
    for (nested) |c| {
        if (c.branch.len > 0) return true;
    }
    return false;
}

/// Call-site `: bind` on a bare produce, or null when the result is discarded.
fn invocationBindName(inv: *const ast.Invocation) ?[]const u8 {
    const rb = inv.return_binding orelse return null;
    if (std.mem.eql(u8, rb, "_")) return null;
    return rb;
}

/// Switching is for tagged-union results. A `: bind` names a bare produce, and
/// empty-branch nested continuations are the rest of the `|>` chain. Switching
/// on either emits `switch (x) { . =>` — not Zig. Twin of the visitor_emitter
/// path 350_015 pins; this is the copy orisha:router (and every transform that
/// inlines a continuation) uses.
fn shouldSwitchOnResult(inv: *const ast.Invocation, nested: []const ast.Continuation) bool {
    if (invocationBindName(inv) != null) return false;
    return continuationsAreTaggedUnion(nested);
}

fn escapedIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, name.len + 4) catch unreachable;
    try codegen_utils.appendBranchName(&buf, allocator, name);
    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Lower nested `|>` chain steps in order, without a switch on this result.
/// `mark_body_allocated` rides into a bare-return produce record: when the
/// arm RETURNS an allocated inline buffer inside a Response-shaped record
/// (`}: f -> { body: f, ... }`), the record must claim `.body_allocated =
/// true` so the caller discharges it after use instead of leaking (350_023).
fn generateSequentialNested(
    allocator: std.mem.Allocator,
    nested: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
    mark_body_allocated: bool,
    program_items: ?[]const ast.Item,
) CodegenError![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;
    for (nested) |*cont| {
        const pipeline = if (cont.node) |node| &[_]ast.Node{node} else &[_]ast.Node{};
        const code = try generatePipelineCode(
            allocator,
            pipeline,
            cont.continuations,
            main_module_name,
            result_counter,
            indent_level,
            var_prefix,
            false,
            mark_body_allocated,
            program_items,
        );
        defer allocator.free(code);
        try buf.appendSlice(allocator, code);
    }
    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// The two marker families a `[template]` proc's rendered body can carry
/// (`{{ continuations["X"].continue }}` / `{{ h.inlined_link[scope] }}(arg)`).
/// emitter_helpers.emitInlineCodeResolvingSplices resolves them when it writes
/// inline code; the continuation-string path (orisha:router's per-branch
/// bodies, everything generated through generatePipelineCode) emitted them
/// verbatim — a raw `__koru_continue_0` in output_emitted.zig for any
/// `if`/`cond`/`for` inside a route arm. This is the same resolver contract,
/// producing strings instead of emitter writes: unresolvable markers pass
/// through verbatim so they still fail loudly at the Zig compile.
const CODEGEN_CONTINUE_PREFIX = "__koru_continue_";
const CODEGEN_INLINE_PREFIX = "__koru_inline_";

/// Texts of the splice producers whose frames are still on the codegen stack —
/// the string path's twin of emitter_helpers' `splice_frame_codes`. A binding
/// introduced deeper inside a spliced body shares a Zig frame with every
/// enclosing producer's raw-|zig locals, not only its immediate producer's
/// (605_001). Depth-capped: nesting past the cap panics rather than
/// silently checking fewer frames.
var splice_frame_codes: [64][]const u8 = undefined;
var splice_frame_depth: usize = 0;

/// Token-boundary replace of `from` with `to` — for renaming a spliced
/// effect binding that would shadow a producer-scope local.
fn replaceIdent(allocator: std.mem.Allocator, body: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, body.len + 32) catch unreachable;
    var i: usize = 0;
    var q: u8 = 0;
    while (i < body.len) {
        const c = body[i];
        if (q != 0) {
            try buf.append(allocator, c);
            i += 1;
            if (c == '\\' and i < body.len) {
                try buf.append(allocator, body[i]);
                i += 1;
            } else if (c == q) {
                q = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            q = c;
            try buf.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
            while (i < body.len and body[i] != '\n') : (i += 1) try buf.append(allocator, body[i]);
            continue;
        }
        if (std.mem.startsWith(u8, body[i..], from)) {
            const before_ok = i == 0 or !(std.ascii.isAlphanumeric(body[i - 1]) or body[i - 1] == '_' or body[i - 1] == '.');
            const after = i + from.len;
            const after_ok = after >= body.len or !(std.ascii.isAlphanumeric(body[after]) or body[after] == '_');
            if (before_ok and after_ok) {
                try buf.appendSlice(allocator, to);
                i = after;
                continue;
            }
        }
        try buf.append(allocator, c);
        i += 1;
    }
    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// `const <local> = <prefix>.<path>; _ = &<local>;` per bound name — the
/// string-side port of emitDestructureConsts for the `! each {a, b}` shape.
fn appendDestructureConsts(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fields: []const ast.DestructureField,
    prefix: []const u8,
) !void {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "_")) continue;
        try buf.appendSlice(allocator, "const ");
        try codegen_utils.appendBranchName(buf, allocator, f.name);
        if (f.type_text) |t| {
            try buf.appendSlice(allocator, ": ");
            try buf.appendSlice(allocator, t);
        }
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, prefix);
        try buf.appendSlice(allocator, ".");
        try buf.appendSlice(allocator, f.path);
        try buf.appendSlice(allocator, "; _ = &");
        try codegen_utils.appendBranchName(buf, allocator, f.name);
        try buf.appendSlice(allocator, "; ");
    }
}

/// Resolve the continuation markers inside a transform's rendered
/// inline_body against this step's own continuations (`nested`):
///
///   - `__koru_continue_[bare_]<idx>`   — `{ [if (<guard>)] { <nested[idx]> } }`
///   - `__koru_inline_[scoped_]<idx>(<arg>)` — `{ const <bind> = <arg>;
///     [if (<guard>)] { <nested[idx]> } }`, with the same pun / shadow-rename
///     / destructure rules the emitter applies.
///
/// The spliced arm is generated recursively through
/// generateContinuationChainWithPrefix under a `{prefix}c<idx>_` /
/// `{prefix}e<idx>_` namespace, matching the emitter's result-prefix nesting.
/// Sets `resolved_any` when at least one marker was consumed — the caller
/// uses that to know the template's own dispatch claimed the arms and the
/// generic post-emit continuation walk must not re-emit them.
fn resolveInlineMarkers(
    allocator: std.mem.Allocator,
    code: []const u8,
    nested: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
    program_items: ?[]const ast.Item,
    resolved_any: *bool,
) CodegenError![]const u8 {
    // Everything spliced below shares this producer's Zig frame — record the
    // text so nested bindings rename against its locals/captures too.
    if (splice_frame_depth == splice_frame_codes.len)
        @panic("continuation_codegen: inline splices nested deeper than 64 frames — raise splice_frame_codes' cap; splice hygiene cannot be checked past it");
    splice_frame_codes[splice_frame_depth] = code;
    splice_frame_depth += 1;
    defer splice_frame_depth -= 1;
    var buf = std.ArrayList(u8).initCapacity(allocator, code.len + 128) catch unreachable;
    var pos: usize = 0;
    while (true) {
        const splice_at = std.mem.indexOfPos(u8, code, pos, CODEGEN_INLINE_PREFIX);
        const continue_at = std.mem.indexOfPos(u8, code, pos, CODEGEN_CONTINUE_PREFIX);
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
            break;
        }
        try buf.appendSlice(allocator, code[pos..m]);

        if (is_continue) {
            var i = m + CODEGEN_CONTINUE_PREFIX.len;
            const unguarded = std.mem.startsWith(u8, code[i..], "bare_");
            if (unguarded) i += "bare_".len;
            const idx = codegen_utils.scanDecimalIndex(code, &i) orelse nested.len;
            if (idx < nested.len) {
                resolved_any.* = true;
                const cont = &nested[idx];
                try buf.appendSlice(allocator, "{ ");
                const guarded = cont.condition != null and !unguarded;
                if (guarded) {
                    const cond_out = (codegen_utils.rewriteZigExpr(allocator, cont.condition.?) catch null) orelse cont.condition.?;
                    try buf.appendSlice(allocator, "if (");
                    try buf.appendSlice(allocator, cond_out);
                    try buf.appendSlice(allocator, ") { ");
                }
                const nested_prefix = try std.fmt.allocPrint(allocator, "{s}c{d}_", .{ var_prefix, idx });
                defer allocator.free(nested_prefix);
                const chain = try generateContinuationChainWithPrefix(allocator, cont, main_module_name, result_counter, indent_level, nested_prefix, program_items);
                defer allocator.free(chain);
                try buf.appendSlice(allocator, chain);
                if (guarded) try buf.appendSlice(allocator, " }");
                try buf.appendSlice(allocator, " }");
            } else {
                try buf.appendSlice(allocator, code[m..i]); // unresolvable; loud
            }
            pos = i;
            continue;
        }

        // EFFECT CALL — `__koru_inline_[scoped_]<idx>(<arg>)`
        var i = m + CODEGEN_INLINE_PREFIX.len;
        if (std.mem.startsWith(u8, code[i..], "scoped_")) i += "scoped_".len;
        const maybe_idx = codegen_utils.scanDecimalIndex(code, &i);
        var arg: []const u8 = "";
        if (maybe_idx != null and i < code.len and code[i] == '(') {
            const arg_start = i + 1;
            var depth: usize = 1;
            var j = arg_start;
            var q: u8 = 0;
            while (j < code.len and depth > 0) : (j += 1) {
                const ch = code[j];
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
            arg = std.mem.trim(u8, code[arg_start .. j - 1], " \t");
            i = j;
            // The marker resolves to a block statement, so swallow a trailing
            // `;` the template wrote in call-statement shape.
            if (i < code.len and code[i] == ';') i += 1;
        }
        const idx = maybe_idx orelse nested.len;
        if (idx < nested.len) {
            resolved_any.* = true;
            const cont = &nested[idx];
            const binding = cont.binding orelse "_";
            // Cross-boundary splice hygiene (emitter's 400_151): if the
            // consumer binding names a token that already occurs in the
            // producer's inline text, `const <binding>` would shadow it.
            var uniq_buf: [64]u8 = undefined;
            var bind_to: []const u8 = binding;
            const is_pun = arg.len != 0 and std.mem.eql(u8, arg, binding);
            // The binding lands inside every enclosing splice frame still on
            // the stack — a name that occurs as a token in ANY of them would
            // be shadowed, not just one in the immediate producer's text.
            const producer_shadow = codegen_utils.containsToken(code, binding) or blk: {
                for (splice_frame_codes[0..splice_frame_depth]) |frame| {
                    if (codegen_utils.containsToken(frame, binding)) break :blk true;
                }
                break :blk false;
            };
            if (!std.mem.eql(u8, binding, "_") and cont.destructure.len == 0 and arg.len != 0 and !is_pun and producer_shadow) {
                bind_to = std.fmt.bufPrint(&uniq_buf, "__koru_bind_{d}_{d}", .{ cont.location.line, cont.location.column }) catch binding;
            }
            try buf.appendSlice(allocator, "{ ");
            if (arg.len == 0) {
                // Void-payload effect: nothing to bind, nothing to discard.
            } else if (cont.destructure.len > 0) {
                var dst_buf: [64]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "__koru_dst_{d}_{d}", .{ cont.location.line, cont.location.column }) catch "__koru_dst";
                try buf.appendSlice(allocator, "const ");
                try buf.appendSlice(allocator, dst);
                try buf.appendSlice(allocator, " = ");
                try buf.appendSlice(allocator, arg);
                try buf.appendSlice(allocator, "; _ = &");
                try buf.appendSlice(allocator, dst);
                try buf.appendSlice(allocator, "; ");
                try appendDestructureConsts(&buf, allocator, cont.destructure, dst);
            } else if (std.mem.eql(u8, binding, "_")) {
                try buf.appendSlice(allocator, "_ = ");
                try buf.appendSlice(allocator, arg);
                try buf.appendSlice(allocator, "; ");
            } else if (is_pun) {
                // The splice arg IS the binding — use it as-is.
            } else {
                try buf.appendSlice(allocator, "const ");
                try codegen_utils.appendBranchName(&buf, allocator, bind_to);
                try buf.appendSlice(allocator, " = ");
                try buf.appendSlice(allocator, arg);
                try buf.appendSlice(allocator, "; _ = &");
                try codegen_utils.appendBranchName(&buf, allocator, bind_to);
                try buf.appendSlice(allocator, "; ");
            }
            var nested_prefix = var_prefix;
            const np = std.fmt.allocPrint(allocator, "{s}e{d}_", .{ var_prefix, idx }) catch null;
            if (np) |p| nested_prefix = p;
            var chain = try generateContinuationChainWithPrefix(allocator, cont, main_module_name, result_counter, indent_level, nested_prefix, program_items);
            defer allocator.free(chain);
            var cond_out: []const u8 = "";
            const guarded = cont.condition != null;
            if (guarded) {
                cond_out = (codegen_utils.rewriteZigExpr(allocator, cont.condition.?) catch null) orelse cont.condition.?;
            }
            if (!std.mem.eql(u8, bind_to, binding)) {
                chain = replaceIdent(allocator, chain, binding, bind_to) catch chain;
                if (guarded) cond_out = replaceIdent(allocator, cond_out, binding, bind_to) catch cond_out;
            }
            if (guarded) {
                try buf.appendSlice(allocator, "if (");
                try buf.appendSlice(allocator, cond_out);
                try buf.appendSlice(allocator, ") { ");
            }
            try buf.appendSlice(allocator, chain);
            if (guarded) try buf.appendSlice(allocator, " }");
            try buf.appendSlice(allocator, " }");
        } else {
            try buf.appendSlice(allocator, code[m..i]); // unresolvable; loud
        }
        pos = i;
    }
    try buf.appendSlice(allocator, code[pos..]);
    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate code for a single continuation's pipeline (the steps after |>)
/// This handles invoking events and recursively processing nested continuations.
fn generatePipelineCode(
    allocator: std.mem.Allocator,
    pipeline: []const ast.Step,
    nested: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
    is_root: bool,
    mark_body_allocated: bool,
    program_items: ?[]const ast.Item,
) CodegenError![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;

    for (pipeline) |step| {
        switch (step) {
            .invocation => |inv| {
                if (inv.inline_body) |ib_raw| {
                    // Resolve any continuation markers the template left in
                    // the body against this step's own arms. The emitter path
                    // does this at write time; this path builds strings, so
                    // the resolution happens here — without it the raw
                    // `__koru_continue_0` reaches output_emitted.zig.
                    var markers_resolved = false;
                    const ib = try resolveInlineMarkers(
                        allocator,
                        ib_raw,
                        nested,
                        main_module_name,
                        result_counter,
                        indent_level,
                        var_prefix,
                        program_items,
                        &markers_resolved,
                    );
                    defer allocator.free(ib);

                    // A body that never breaks with a value is a STATEMENT: emit
                    // it as one. No label, no result variable, and nothing for a
                    // continuation switch to switch on. See inlineBodyYieldsValue.
                    if (!inlineBodyYieldsValue(ib_raw)) {
                        const ind_stmt = try indent(allocator, indent_level);
                        defer allocator.free(ind_stmt);
                        try buf.appendSlice(allocator, ind_stmt);
                        try buf.appendSlice(allocator, ib);
                        try buf.appendSlice(allocator, "\n");
                        continue;
                    }

                    // Transform set inline_body — emit inline code instead of handler call.
                    // A `: bind` names this const so the rest of the chain can read it.
                    const result_var = if (invocationBindName(&inv)) |rb|
                        try escapedIdent(allocator, rb)
                    else
                        try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                    defer allocator.free(result_var);
                    result_counter.* += 1;

                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);

                    // Emit: const result_N = label: { <inline code with label replaced> };
                    const label = try std.fmt.allocPrint(allocator, "__koru_inline_{d}", .{result_counter.*});
                    defer allocator.free(label);

                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "const ");
                    try buf.appendSlice(allocator, result_var);
                    try buf.appendSlice(allocator, " = ");
                    try buf.appendSlice(allocator, label);
                    try buf.appendSlice(allocator, ": ");

                    // Replace __KORU_INLINE__ placeholder with actual label
                    const placeholder = "__KORU_INLINE__";
                    var pos: usize = 0;
                    while (pos < ib.len) {
                        if (pos + placeholder.len <= ib.len and std.mem.eql(u8, ib[pos .. pos + placeholder.len], placeholder)) {
                            try buf.appendSlice(allocator, label);
                            pos += placeholder.len;
                        } else {
                            try buf.append(allocator, ib[pos]);
                            pos += 1;
                        }
                    }
                    try buf.appendSlice(allocator, ";\n");

                    // Marker-referenced arms were spliced into the body by the
                    // template's own dispatch — do not walk them again here.
                    if (nested.len > 0 and !markers_resolved) {
                        if (shouldSwitchOnResult(&inv, nested)) {
                            const switch_code = try generateBranchSwitch(
                                allocator,
                                result_var,
                                nested,
                                main_module_name,
                                result_counter,
                                indent_level,
                                var_prefix,
                                inlineBodyAllocates(ib_raw),
                                program_items,
                            );
                            defer allocator.free(switch_code);
                            try buf.appendSlice(allocator, switch_code);
                        } else {
                            if (invocationBindName(&inv) == null) {
                                try buf.appendSlice(allocator, ind);
                                try buf.appendSlice(allocator, "_ = &");
                                try buf.appendSlice(allocator, result_var);
                                try buf.appendSlice(allocator, ";\n");
                            }
                            // A bare-return produce that RETURNS the allocated
                            // buffer in a Response-shaped record (`}: f ->
                            // { body: f, ... }`) must claim body_allocated on
                            // the record: the buffer rides out to the caller,
                            // which discharges it after use (orisha
                            // release-body). Freeing here would be
                            // use-after-free; not marking leaks (350_023).
                            const mark_response = if (invocationBindName(&inv)) |bind_name|
                                inlineBodyAllocates(ib_raw) and chainReturnsBodyBinding(nested, bind_name)
                            else
                                false;
                            const seq = try generateSequentialNested(
                                allocator,
                                nested,
                                main_module_name,
                                result_counter,
                                indent_level,
                                var_prefix,
                                mark_response,
                                program_items,
                            );
                            defer allocator.free(seq);
                            try buf.appendSlice(allocator, seq);

                            // An inlined fmt.blk result is `allocated!`. The
                            // auto-discharge pass inserts `free` at the
                            // terminator for flows it can still see; a
                            // ROUTER-inlined arm is lowered to Zig before the
                            // pass runs, so there the codegen falls back.
                            // Only free when the pass did NOT already discharge
                            // (that would double-free) and the arm does not
                            // RETURN the buffer (the Response holds it).
                            if (inlineBodyAllocates(ib)) {
                                if (invocationBindName(&inv)) |bind_name| {
                                    if (!std.mem.eql(u8, bind_name, "_") and
                                        std.mem.indexOf(u8, seq, "return ") == null and
                                        std.mem.indexOf(u8, seq, "free_event") == null)
                                    {
                                        const ind_free = try indent(allocator, indent_level);
                                        defer allocator.free(ind_free);
                                        try buf.appendSlice(allocator, ind_free);
                                        try buf.appendSlice(allocator, "koru_allocator().free(");
                                        try buf.appendSlice(allocator, bind_name);
                                        try buf.appendSlice(allocator, ");\n");
                                    }
                                }
                            }
                        }
                    }
                } else if (nested.len > 0) {
                    // Nested continuations: either tagged-union arms (switch)
                    // or the rest of a `|>` chain after a bare produce (`: bind`).
                    const bind = invocationBindName(&inv);
                    if (shouldSwitchOnResult(&inv, nested)) {
                        const result_var = try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                        defer allocator.free(result_var);
                        result_counter.* += 1;

                        const call_code = try generateHandlerCallWithResult(
                            allocator,
                            &inv,
                            main_module_name,
                            result_var,
                            indent_level,
                        );
                        defer allocator.free(call_code);
                        try buf.appendSlice(allocator, call_code);

                        const switch_code = try generateBranchSwitch(
                            allocator,
                            result_var,
                            nested,
                            main_module_name,
                            result_counter,
                            indent_level,
                            var_prefix,
                            false,
                            program_items,
                        );
                        defer allocator.free(switch_code);
                        try buf.appendSlice(allocator, switch_code);
                    } else if (bind) |rb| {
                        const result_var = try escapedIdent(allocator, rb);
                        defer allocator.free(result_var);
                        const call_code = try generateHandlerCallWithResult(
                            allocator,
                            &inv,
                            main_module_name,
                            result_var,
                            indent_level,
                        );
                        defer allocator.free(call_code);
                        try buf.appendSlice(allocator, call_code);

                        // Same contract as the inline-body twin above: a
                        // `-> T<allocated!>` tor's buffer bound here and
                        // RETURNED in a Response-shaped record must claim
                        // body_allocated on it (orisha release-body).
                        const mark_response = invocationReturnsAllocated(program_items, &inv) and
                            chainReturnsBodyBinding(nested, rb);
                        const seq = try generateSequentialNested(
                            allocator,
                            nested,
                            main_module_name,
                            result_counter,
                            indent_level,
                            var_prefix,
                            mark_response,
                            program_items,
                        );
                        defer allocator.free(seq);
                        try buf.appendSlice(allocator, seq);
                    } else {
                        const call_code = try generateHandlerCall(
                            allocator,
                            &inv,
                            main_module_name,
                            indent_level,
                        );
                        defer allocator.free(call_code);
                        try buf.appendSlice(allocator, call_code);

                        const seq = try generateSequentialNested(
                            allocator,
                            nested,
                            main_module_name,
                            result_counter,
                            indent_level,
                            var_prefix,
                            false,
                            program_items,
                        );
                        defer allocator.free(seq);
                        try buf.appendSlice(allocator, seq);
                    }
                } else if (is_root and nested.len == 0) {
                    // Bare produce: a root leaf invocation IS the produced value.
                    // `-> craft(req)` must RETURN the handler's response, not
                    // silently drop it; the generic call path saw every chained
                    // tor as a side effect (`_ =`) and the response vanished.
                    const result_var = if (invocationBindName(&inv)) |rb|
                        try escapedIdent(allocator, rb)
                    else
                        try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                    defer allocator.free(result_var);
                    result_counter.* += 1;
                    const call_code = try generateHandlerCallWithResult(
                        allocator,
                        &inv,
                        main_module_name,
                        result_var,
                        indent_level,
                    );
                    defer allocator.free(call_code);
                    try buf.appendSlice(allocator, call_code);
                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "return ");
                    try buf.appendSlice(allocator, result_var);
                    try buf.appendSlice(allocator, ";\n");
                } else {
                    // Simple invocation - ignore result
                    const call_code = try generateHandlerCall(
                        allocator,
                        &inv,
                        main_module_name,
                        indent_level,
                    );
                    defer allocator.free(call_code);
                    try buf.appendSlice(allocator, call_code);
                }
            },
            .terminal => {
                // Terminal step - nothing to generate
            },
            .branch_constructor => |bc| {
                // Output: `return .{ .branch = .{ .f = v, … } };`
                //
                // UNLESS THERE IS NO BRANCH. A tor with a bare return has no
                // branch to name, so the produced record IS the return value.
                // Wrapping it anyway wrote `return .{ . = .{ } };` — a field
                // access with an empty name, and every field dropped, because
                // the payload arrived as a plain value this path never read.
                //
                // It reached every arm of every router built on orisha, whose
                // `handler` became bare-return when a single named outcome
                // stopped being expressible. Twin of the same fix in
                // emitter_helpers.emitProducedConstructor; this is the copy the
                // transform-driven path uses.
                const bare = bc.branch_name.len == 0;
                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "return ");

                if (!bare) {
                    try buf.appendSlice(allocator, ".{ .");
                    try codegen_utils.appendBranchName(&buf, allocator, bc.branch_name);
                    try buf.appendSlice(allocator, " = ");
                }

                if (bc.plain_value) |pv| {
                    // A bare produce carries its whole value here, in Koru
                    // spelling — `{ status: 200, … }` — so it needs lowering,
                    // not pasting.
                    const trimmed_pv = std.mem.trim(u8, pv, " \t");
                    if (trimmed_pv.len > 0 and trimmed_pv[0] == '{') {
                        const lowered = codegen_utils.koruStructToZig(allocator, trimmed_pv) catch trimmed_pv;
                        if (mark_body_allocated) {
                            if (std.mem.lastIndexOfScalar(u8, lowered, '}')) |close| {
                                try buf.appendSlice(allocator, lowered[0..close]);
                                try buf.appendSlice(allocator, ", .body_allocated = true ");
                                try buf.appendSlice(allocator, lowered[close..]);
                            } else {
                                try buf.appendSlice(allocator, lowered);
                            }
                        } else {
                            try buf.appendSlice(allocator, lowered);
                        }
                    } else {
                        try buf.appendSlice(allocator, trimmed_pv);
                    }
                } else {
                    try buf.appendSlice(allocator, ".{");
                    try appendNamedFieldList(&buf, allocator, bc.fields);
                    if (mark_body_allocated) {
                        try buf.appendSlice(allocator, ", .body_allocated = true");
                    }
                    try buf.appendSlice(allocator, " }");
                }

                if (!bare) try buf.appendSlice(allocator, " }");
                try buf.appendSlice(allocator, ";\n");
            },
            .inline_code => |code| {
                // Same distinction as the invocation path above: only a body
                // that breaks with a value may be wrapped in a labelled block.
                if (nested.len > 0 and inlineBodyYieldsValue(code)) {
                    // Inline code produces a result value — wrap in labeled block,
                    // assign to result variable, and generate switch on nested continuations.
                    // Convention: inline code uses break :__KORU_INLINE__ to produce its result.
                    const result_var = try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                    defer allocator.free(result_var);
                    result_counter.* += 1;

                    // Generate unique label
                    const label = try std.fmt.allocPrint(allocator, "__koru_inline_{d}", .{result_counter.*});
                    defer allocator.free(label);

                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);

                    // const result_N = __koru_inline_N: { <code with label replaced> };
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "const ");
                    try buf.appendSlice(allocator, result_var);
                    try buf.appendSlice(allocator, " = ");
                    try buf.appendSlice(allocator, label);
                    try buf.appendSlice(allocator, ": ");

                    // Replace __KORU_INLINE__ placeholder with actual label in the inline code
                    var pos: usize = 0;
                    while (pos < code.len) {
                        if (pos + 15 <= code.len and std.mem.eql(u8, code[pos..pos + 15], "__KORU_INLINE__")) {
                            try buf.appendSlice(allocator, label);
                            pos += 15;
                        } else {
                            try buf.append(allocator, code[pos]);
                            pos += 1;
                        }
                    }
                    try buf.appendSlice(allocator, ";\n");

                    if (continuationsAreTaggedUnion(nested)) {
                        const switch_code = try generateBranchSwitch(
                            allocator,
                            result_var,
                            nested,
                            main_module_name,
                            result_counter,
                            indent_level,
                            var_prefix,
                            false,
                            program_items,
                        );
                        defer allocator.free(switch_code);
                        try buf.appendSlice(allocator, switch_code);
                    } else {
                        try buf.appendSlice(allocator, ind);
                        try buf.appendSlice(allocator, "_ = &");
                        try buf.appendSlice(allocator, result_var);
                        try buf.appendSlice(allocator, ";\n");
                        const seq = try generateSequentialNested(
                            allocator,
                            nested,
                            main_module_name,
                            result_counter,
                            indent_level,
                            var_prefix,
                            false,
                            program_items,
                        );
                        defer allocator.free(seq);
                        try buf.appendSlice(allocator, seq);
                    }
                } else {
                    // Simple inline code — no result needed
                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, code);
                    try buf.appendSlice(allocator, "\n");
                }
            },
            .assignment => |asgn| {
                // Emit assignment: target = .{ .field1 = expr1, .field2 = expr2 };
                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, asgn.target);
                try buf.appendSlice(allocator, " = .{");
                try appendNamedFieldList(&buf, allocator, asgn.fields);
                try buf.appendSlice(allocator, " };\n");
            },
            .foreach => |fe| {
                // Emit for loop with body
                const each_binding = ast.NamedBranch.getBinding(fe.branches, "each") orelse "_";
                const each_body = ast.NamedBranch.getBody(fe.branches, "each");
                const done_body = ast.NamedBranch.getBody(fe.branches, "done");

                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "for (");
                try buf.appendSlice(allocator, fe.iterable);
                try buf.appendSlice(allocator, ") |");
                try buf.appendSlice(allocator, each_binding);
                try buf.appendSlice(allocator, "| {\n");

                // Emit body continuations
                try appendContinuationBodies(&buf, allocator, each_body, main_module_name, result_counter, indent_level + 1, var_prefix, program_items);

                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "}\n");

                // Emit done_body after the loop
                try appendContinuationBodies(&buf, allocator, done_body, main_module_name, result_counter, indent_level, var_prefix, program_items);
            },
            .conditional => |cond| {
                // Emit if/else with bodies
                const then_body = ast.NamedBranch.getBody(cond.branches, "then");
                const else_body = ast.NamedBranch.getBody(cond.branches, "else");

                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "if (");
                // The Zig spelling of the operators this host does not share:
                // this module generates Zig only (header prose above), so the
                // rewrites (`%` → @rem, literal-grounded string `==` → mem.eql)
                // apply here too.
                const cond_out = (codegen_utils.rewriteZigExpr(allocator, cond.condition) catch null) orelse cond.condition;
                try buf.appendSlice(allocator, cond_out);
                try buf.appendSlice(allocator, ") {\n");

                // Emit then_body
                try appendContinuationBodies(&buf, allocator, then_body, main_module_name, result_counter, indent_level + 1, var_prefix, program_items);

                if (else_body.len > 0) {
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "} else {\n");
                    try appendContinuationBodies(&buf, allocator, else_body, main_module_name, result_counter, indent_level + 1, var_prefix, program_items);
                }

                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "}\n");
            },
            else => {
                // Other step types - skip for now
            },
        }
    }

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// True when a nested chain's single continuation is a bare-return PRODUCE
/// that returns a record whose `body:` field is exactly `binding` — the arm
/// hands an allocated inline buffer (a fmt.blk `allocPrint`) to its caller
/// inside a Response-shaped record instead of freeing it here. The record is
/// then marked `.body_allocated = true` so the caller discharges it
/// (orisha release-body); leaving the default false leaks the buffer, and
/// freeing in the arm is use-after-free. Pinned by 350_023.
fn chainReturnsBodyBinding(nested: []const ast.Continuation, binding: []const u8) bool {
    if (nested.len != 1) return false;
    const cont = &nested[0];
    const bc = switch (cont.node orelse return false) {
        .branch_constructor => |bc| bc,
        else => return false,
    };
    if (!bc.is_bare_return) return false;
    const pv = bc.plain_value orelse return false;
    const value = std.mem.trim(u8, pv, " \t");
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return false;

    // Walk the record's top-level fields (brace depth 0 between the outer
    // braces), quote-aware — a `body:` nested inside a sub-record or string
    // must not count.
    var depth: i32 = 0;
    var in_string = false;
    var field_start: usize = 1;
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c == '"' and (i == 0 or value[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '{' or c == '(' or c == '[') depth += 1;
        if (c == '}' or c == ')' or c == ']') depth -= 1;
        if (c == ',' and depth == 0) {
            if (fieldHasBodyValue(value[field_start..i], binding)) return true;
            field_start = i + 1;
        }
    }
    if (field_start < value.len - 1) {
        return fieldHasBodyValue(value[field_start .. value.len - 1], binding);
    }
    return false;
}

/// True when a single record field (`body: f`) names `binding` as its value.
fn fieldHasBodyValue(field: []const u8, binding: []const u8) bool {
    const trimmed = std.mem.trim(u8, field, " \t");
    if (trimmed.len == 0) return false;
    var depth: i32 = 0;
    var in_string = false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (c == '"' and (i == 0 or trimmed[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '{' or c == '(' or c == '[') depth += 1;
        if (c == '}' or c == ')' or c == ']') depth -= 1;
        if (c == ':' and depth == 0) {
            const key = std.mem.trim(u8, trimmed[0..i], " \t");
            if (!std.mem.eql(u8, key, "body")) return false;
            const val = std.mem.trim(u8, trimmed[i + 1 ..], " \t");
            return std.mem.eql(u8, val, binding);
        }
    }
    return false;
}

/// True when the invoked tor's decl declares an `allocated` return
/// (`-> string<std.io:allocated!>`). Codegen-side twin
/// of `inlineBodyAllocates` for REAL tor calls: a bound `allocated!` result
/// that a Response-shaped produce returns must claim `body_allocated`, since
/// router-inlined arms are lowered to Zig before auto-discharge can see them.
fn invocationReturnsAllocated(items: ?[]const ast.Item, inv: *const ast.Invocation) bool {
    const decl = findEventDeclLocal(items orelse return false, &inv.path) orelse return false;
    const ph = decl.return_phantom orelse return false;
    var label = std.mem.trim(u8, ph, " \t");
    label = std.mem.trimRight(u8, label, "!?");
    if (std.mem.lastIndexOfScalar(u8, label, ':')) |c| label = label[c + 1 ..];
    return std.mem.eql(u8, label, "allocated");
}

/// Module-qualified path walk over program items — local twin of
/// emitter_helpers.findEventDeclByPath (kept here so this module stays
/// leaf-deps only: ast + codegen_utils).
fn findEventDeclLocal(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
    if (path.module_qualifier) |mq| {
        for (items) |*item| {
            if (item.* == .module_decl and std.mem.eql(u8, item.module_decl.logical_name, mq)) {
                return findEventDeclBySegments(item.module_decl.items, path.segments);
            }
        }
        return findEventDeclBySegments(items, path.segments);
    }
    for (items) |*item| {
        switch (item.*) {
            .module_decl => |*module| {
                if (findEventDeclLocal(module.items, path)) |found| return found;
            },
            .event_decl => |*ed| {
                if (segmentsMatch(ed.path.segments, path.segments)) return ed;
            },
            else => {},
        }
    }
    return null;
}

fn findEventDeclBySegments(items: []const ast.Item, segments: []const []const u8) ?*const ast.EventDecl {
    for (items) |*item| {
        if (item.* == .event_decl and segmentsMatch(item.event_decl.path.segments, segments)) {
            return &item.event_decl;
        }
    }
    return null;
}

fn segmentsMatch(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Whether an inline body allocated a buffer the caller binds. fmt.blk's
/// transform writes `allocPrint` against `__fmt_alloc`. Auto-discharge runs
/// after inlining transforms have already lowered nested sites to Zig, so
/// this path discharges that buffer the inserter will never see (350_022,
/// twin of 620_007's `| formatted f` free on the visitor_emitter path).
fn inlineBodyAllocates(ib: []const u8) bool {
    return std.mem.indexOf(u8, ib, "allocPrint") != null and
        std.mem.indexOf(u8, ib, "__fmt_alloc") != null;
}

fn generateBranchSwitch(
    allocator: std.mem.Allocator,
    result_var: []const u8,
    continuations: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
    discharge_allocated: bool,
    program_items: ?[]const ast.Item,
) CodegenError![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;

    const ind = try indent(allocator, indent_level);
    defer allocator.free(ind);

    // switch (result_var) {
    try buf.appendSlice(allocator, ind);
    try buf.appendSlice(allocator, "switch (");
    try buf.appendSlice(allocator, result_var);
    try buf.appendSlice(allocator, ") {\n");

    for (continuations) |cont| {
        const ind2 = try indent(allocator, indent_level + 1);
        defer allocator.free(ind2);

        // .branch_name => |binding| {
        try buf.appendSlice(allocator, ind2);
        try buf.append(allocator, '.');

        // Escape branch name if it's a keyword
        try codegen_utils.appendBranchName(&buf, allocator, cont.branch);

        try buf.appendSlice(allocator, " => ");

        if (cont.binding) |binding| {
            // Discard bindings ("_") should not generate a capture to avoid unused variable errors
            if (std.mem.eql(u8, binding, "_")) {
                try buf.appendSlice(allocator, "{\n");
            } else {
                // The capture name is `binding` + "_" + level. When the binding
                // starts u/i/f + digit (u0, u2, i32, f16), that spelling lexes
                // as a Zig numeric primitive (u0_4 -> "u04" leading-zero error;
                // u2_8 -> u28) — escape the whole capture identifier.
                const cap_esc = binding.len > 1 and std.ascii.isDigit(binding[1]) and
                    (binding[0] == 'u' or binding[0] == 'i' or binding[0] == 'f');
                try buf.append(allocator, '|');
                if (cap_esc) try buf.appendSlice(allocator, "@\"");
                try buf.appendSlice(allocator, binding);
                // Suffix with indent level to avoid shadowing in nested switches
                try buf.append(allocator, '_');
                var level_buf: [16]u8 = undefined;
                const level_str = std.fmt.bufPrint(&level_buf, "{d}", .{indent_level}) catch unreachable;
                try buf.appendSlice(allocator, level_str);
                if (cap_esc) try buf.append(allocator, '"');
                try buf.appendSlice(allocator, "| {\n");

                // Alias original binding name for inline code that references source-level names.
                // E.g., `| result r |>` becomes `|r_2| { const r = r_2; _ = &r; ... }`
                // This lets inline code use `r.field` while the switch binding is `r_2`.
                const ind3 = try indent(allocator, indent_level + 2);
                defer allocator.free(ind3);
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, "const ");
                try codegen_utils.appendEscapedIdentifier(&buf, allocator, binding);
                try buf.appendSlice(allocator, " = ");
                if (cap_esc) try buf.appendSlice(allocator, "@\"");
                try buf.appendSlice(allocator, binding);
                try buf.append(allocator, '_');
                try buf.appendSlice(allocator, level_str);
                if (cap_esc) try buf.append(allocator, '"');
                try buf.appendSlice(allocator, ";\n");
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, "_ = &");
                try codegen_utils.appendEscapedIdentifier(&buf, allocator, binding);
                try buf.appendSlice(allocator, ";\n");
            }
        } else {
            try buf.appendSlice(allocator, "{\n");
        }

        // Generate code for this branch's step and nested continuations
        // Convert single step to array for compatibility with generatePipelineCode
        const pipeline = if (cont.node) |step| &[_]ast.Step{step} else &[_]ast.Step{};
        var pipeline_code = try generatePipelineCode(
            allocator,
            pipeline,
            cont.continuations,
            main_module_name,
            result_counter,
            indent_level + 2,
            var_prefix,
            false,
            discharge_allocated,
            program_items,
        );
        defer allocator.free(pipeline_code);
        // A binding spelled like a Zig primitive/keyword escapes at the alias
        // above, but bare references inside arg/inline text still spell the
        // source name — and `u2` resolves to the primitive, not the local.
        // Rewrite token-boundary occurrences to the escaped form.
        if (cont.binding) |binding| {
            if (!std.mem.eql(u8, binding, "_")) {
                const escaped = try codegen_utils.escapeZigIdentifier(allocator, binding);
                defer if (!std.mem.eql(u8, escaped, binding)) allocator.free(escaped);
                if (!std.mem.eql(u8, escaped, binding)) {
                    const rewritten = try replaceIdent(allocator, pipeline_code, binding, escaped);
                    allocator.free(pipeline_code);
                    pipeline_code = rewritten;
                }
            }
        }
        try buf.appendSlice(allocator, pipeline_code);

        // An inlined fmt.blk result is `allocated!`. Auto-discharge cannot
        // insert the free: the router has already lowered this arm to Zig.
        // Do not free when the arm `return`s the slice (the Response holds
        // it; freeing here is use-after-free). 350_022 prints, then frees.
        if (discharge_allocated) {
            if (cont.binding) |binding| {
                if (!std.mem.eql(u8, binding, "_") and
                    std.mem.indexOf(u8, pipeline_code, "return ") == null)
                {
                    const ind3 = try indent(allocator, indent_level + 2);
                    defer allocator.free(ind3);
                    try buf.appendSlice(allocator, ind3);
                    try buf.appendSlice(allocator, "koru_allocator().free(");
                    try codegen_utils.appendEscapedIdentifier(&buf, allocator, binding);
                    try buf.appendSlice(allocator, ");\n");
                }
            }
        }

        // Close branch
        try buf.appendSlice(allocator, ind2);
        try buf.appendSlice(allocator, "},\n");
    }

    // Close switch
    try buf.appendSlice(allocator, ind);
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate code for a full continuation chain starting from a single continuation.
/// This is the main entry point for ~for and other transforms.
///
/// Example input: | each item |> step1(x: item) | result r |> step2(y: r.y)
/// Example output:
///   const result_0 = step1_event.handler(.{ .x = item });
///   switch (result_0) {
///       .result => |r| {
///           _ = step2_event.handler(.{ .y = r.y });
///       },
///   }
///
/// var_prefix: Prefix for generated variable names (default "result_").
///             Use unique prefixes like "fe_" or "fd_" to avoid shadowing.
pub fn generateContinuationChain(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
) CodegenError![]const u8 {
    return generateContinuationChainWithPrefix(
        allocator,
        continuation,
        main_module_name,
        result_counter,
        indent_level,
        "result_", // Default prefix for backward compatibility
        null,
    );
}

/// Same as `generateContinuationChain` but carries the program's item list so
/// codegen can resolve invoked decls — currently the `body_allocated` mark
/// reads an invoked tor's `return_phantom` (allocated! returns escaping into
/// Response-shaped produces). Callers without the program in scope keep the
/// 5-arg entry; they get no decl-keyed marking.
pub fn generateContinuationChainWithItems(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    program_items: ?[]const ast.Item,
) CodegenError![]const u8 {
    return generateContinuationChainWithPrefix(
        allocator,
        continuation,
        main_module_name,
        result_counter,
        indent_level,
        "result_",
        program_items,
    );
}

/// Generate code for a continuation chain with a custom variable prefix.
/// Use this when you need to avoid variable shadowing in generated code.
pub fn generateContinuationChainWithPrefix(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
    program_items: ?[]const ast.Item,
) CodegenError![]const u8 {
    // Convert single step to array for compatibility with generatePipelineCode
    const pipeline = if (continuation.node) |node| &[_]ast.Node{node} else &[_]ast.Node{};
    return generatePipelineCode(
        allocator,
        pipeline,
        continuation.continuations,
        main_module_name,
        result_counter,
        indent_level,
        var_prefix,
        true, // root: the continuation's own node is a bare produce when leaf
        false,
        program_items,
    );
}
