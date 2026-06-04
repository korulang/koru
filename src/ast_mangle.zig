//! Parse-time name normalization: kebab-case Koru NAMES -> snake_case.
//!
//! Koru source uses kebab-case for symbols (`| my-branch b |>`, `delete { dir-name: ... }`,
//! `std/io:print.ln`). Internally we normalize every Koru NAME to snake_case so that:
//!
//!   - The host (Zig) proc body, which references fields by their snake form, lines up.
//!   - A single normalization point at the parse boundary means EVERY downstream
//!     consumer (serializer, checkers, optimizer, emitters) sees snake and needs
//!     zero kebab-awareness. This is what kills the metacircular cascade: by the
//!     time anything emits — including the shared backend_output_emitted.zig — names
//!     are already snake, so a missed emission site can't re-introduce kebab.
//!
//! Snake PRESERVES word boundaries (the `_`), so a later JS-emitter pass can convert
//! `my_branch` -> `myBranch` losslessly. Normalizing to snake here does NOT foreclose
//! per-target camelCase; it just makes snake the universal internal form.
//!
//! SCOPE — what is a "Koru name" (mangled) vs an opaque host string (left verbatim):
//!   Mangled:  event/proc/path segments, branch names, field/arg KEYS, bindings, labels.
//!   Verbatim: Arg.value, Field.type/phantom/expression_str, Branch.resume_type,
//!             proc bodies, inline_body/inline_code, Node.expression, condition strings,
//!             iterables — all host (Zig/JS) expressions forwarded unchanged.
//!
//! REGISTRY NOTE: path segments are ALSO mangled at construction in
//! `lexer.parseDottedPath`/`parseQualifiedPath`, because `registry` keys (path_str)
//! are derived from segments DURING parse, before this walk runs. This walk re-touches
//! paths idempotently (snake has no `-`) and is the comprehensive net for everything
//! reached via decl pointers (branches, fields) which are NOT registry keys.

const std = @import("std");
const ast = @import("ast");

/// In-place `-` -> `_`. Safe: every name field is `allocator.dupe`'d (mutable
/// `[]u8` underneath), length-preserving, and idempotent on already-snake names.
fn mangle(name: []const u8) void {
    const bytes = @constCast(name);
    for (bytes) |*c| {
        if (c.* == '-') c.* = '_';
    }
}

fn mangleOpt(name: ?[]const u8) void {
    if (name) |n| mangle(n);
}

pub fn normalizeProgram(items: []ast.Item) void {
    for (items) |*item| normalizeItem(item);
}

fn normalizeItem(item: *ast.Item) void {
    switch (item.*) {
        .module_decl => |*m| normalizeProgram(@constCast(m.items)),
        .event_decl => |*e| normalizeEventDecl(e),
        .proc_decl => |*p| normalizeProcDecl(p),
        .flow => |*f| normalizeFlow(f),
        .event_tap => |*t| normalizeEventTap(t),
        .label_decl => |*l| {
            mangle(l.name);
            normalizeContinuations(@constCast(l.continuations));
        },
        .immediate_impl => |*ii| {
            normalizeDottedPath(&ii.event_path);
            normalizeBranchConstructor(&ii.value);
        },
        // Opaque / non-Koru-name items: nothing to normalize.
        .import_decl => {}, // import paths are slash-form, not kebab symbols
        .host_line => {}, // opaque host code
        .host_type_decl => {}, // host (Zig) type name
        .parse_error => {},
        // IR nodes are optimizer output — they do not exist at the parse boundary
        // where this walk runs. Handled as no-ops to keep the switch exhaustive.
        .native_loop => {},
        .fused_event => {},
        .inlined_event => {},
        .inline_code => {},
    }
}

fn normalizeEventDecl(e: *ast.EventDecl) void {
    normalizeDottedPath(&e.path);
    normalizeShape(@constCast(&e.input));
    for (@constCast(e.branches)) |*b| normalizeBranch(b);
}

fn normalizeProcDecl(p: *ast.ProcDecl) void {
    normalizeDottedPath(&p.path);
    // Body is opaque host code — left verbatim. Only the extracted inline flows
    // (parsed as Koru) are normalized.
    for (@constCast(p.inline_flows)) |*f| normalizeFlow(f);
}

fn normalizeEventTap(t: *ast.EventTap) void {
    if (t.source) |*s| normalizeDottedPath(s);
    if (t.destination) |*d| normalizeDottedPath(d);
    normalizeContinuations(@constCast(t.continuations));
}

fn normalizeFlow(f: *ast.Flow) void {
    normalizeInvocation(&f.invocation);
    normalizeContinuations(@constCast(f.continuations));
    mangleOpt(f.pre_label);
    mangleOpt(f.post_label);
    if (f.impl_of) |*io| normalizeDottedPath(io);
    // impl_variant is a variant selector (target tag), not a symbol — leave it.
    if (f.super_shape) |*ss| {
        for (@constCast(ss.branches)) |*bv| {
            mangle(bv.name);
            normalizeShape(&bv.payload);
            for (@constCast(bv.sources)) |*src| normalizeDottedPath(src);
        }
    }
}

fn normalizeInvocation(inv: *ast.Invocation) void {
    normalizeDottedPath(&inv.path);
    for (@constCast(inv.args)) |*a| normalizeArg(a);
    // variant / inline_body are not Koru symbols.
}

fn normalizeArg(a: *ast.Arg) void {
    mangle(a.name); // arg KEY is a Koru name
    // a.value and the expression payloads are opaque host expressions — verbatim.
}

fn normalizeContinuations(conts: []ast.Continuation) void {
    for (conts) |*c| normalizeContinuation(c);
}

fn normalizeContinuation(c: *ast.Continuation) void {
    mangle(c.branch);
    mangleOpt(c.binding);
    // condition / catchall_metatype are host expr / metatype name — verbatim.
    if (c.node) |*n| normalizeNode(n);
    normalizeContinuations(@constCast(c.continuations));
}

fn normalizeNamedBranch(nb: *ast.NamedBranch) void {
    mangle(nb.name);
    mangleOpt(nb.binding);
    normalizeContinuations(@constCast(nb.body));
}

fn normalizeNode(n: *ast.Node) void {
    switch (n.*) {
        .invocation => |*i| normalizeInvocation(i),
        .label_apply => |l| mangle(l),
        .label_with_invocation => |*lwi| {
            mangle(lwi.label);
            normalizeInvocation(&lwi.invocation);
        },
        .label_jump => |*lj| {
            mangle(lj.label);
            for (@constCast(lj.args)) |*a| normalizeArg(a);
        },
        .terminal => {},
        .deref => |*d| {
            mangle(d.target); // binding / branch name to deref
            if (d.args) |args| for (@constCast(args)) |*a| normalizeArg(a);
        },
        .branch_constructor => |*bc| normalizeBranchConstructor(bc),
        .conditional_block => |*cb| {
            // condition is a host expression — verbatim.
            for (@constCast(cb.nodes)) |*node| normalizeNode(node);
        },
        .metatype_binding => |*mb| {
            // metatype + event names are canonical (tap-synthesized, post-parse);
            // only the binding/branch identifiers are plain Koru names.
            mangle(mb.binding);
            mangle(mb.branch);
        },
        .inline_code => {}, // verbatim host code
        .expression => {}, // verbatim host expression
        .foreach => |*fe| {
            // iterable / element_type are host expressions/types — verbatim.
            for (@constCast(fe.branches)) |*b| normalizeNamedBranch(b);
        },
        .conditional => |*cond| {
            // condition is a host expression — verbatim.
            for (@constCast(cond.branches)) |*b| normalizeNamedBranch(b);
        },
        .switch_result => |*sr| {
            // expression is host code — verbatim.
            for (@constCast(sr.branches)) |*b| normalizeNamedBranch(b);
        },
        .assignment => |*asgn| {
            mangle(asgn.target); // capture binding
            for (@constCast(asgn.fields)) |*field| normalizeField(field);
        },
    }
}

fn normalizeBranch(b: *ast.Branch) void {
    mangle(b.name);
    normalizeShape(&b.payload);
    // resume_type / resume_phantom are host type strings — verbatim.
}

fn normalizeBranchConstructor(bc: *ast.BranchConstructor) void {
    mangle(bc.branch_name);
    for (@constCast(bc.fields)) |*field| normalizeField(field);
    // plain_value is a host expression — verbatim.
}

fn normalizeShape(s: *ast.Shape) void {
    for (@constCast(s.fields)) |*field| normalizeField(field);
}

fn normalizeField(field: *ast.Field) void {
    mangle(field.name); // field KEY is a Koru name
    // type / phantom / module_path / expression_str are host strings — verbatim.
}

fn normalizeDottedPath(path: *ast.DottedPath) void {
    // module_qualifier is slash/snake in practice (no kebab modules); idempotent here.
    mangleOpt(path.module_qualifier);
    for (@constCast(path.segments)) |seg| mangle(seg);
}
