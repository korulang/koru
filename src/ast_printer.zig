//! Canonical printer: post-parse AST → canonical Koru source.
//!
//! Prints the tree exactly as `parser.parse()` returns it — BEFORE companion
//! merging, module resolution, or any transform pass. The contract is the
//! round-trip pair the corpus harness enforces:
//!
//!   parse(print(parse(src)))  tree-equal  to  parse(src)   (under --ast-canon)
//!   print(parse(print(...)))  byte-equal  to  print(...)
//!
//! Canonical form v1 = the corpus-dominant current form: inline chains,
//! 4-space indent, punned-where-possible. Every spelling emitted here is
//! grounded in a passing regression test; the round-trip harness enforces
//! that mechanically (an invented spelling cannot survive print→parse→print).
//!
//! Constructs whose spelling has NOT been grounded yet are hard errors that
//! name the construct — the corpus run turns those errors into a worklist,
//! and each entry is closed by reading the failing test, never by guessing.
//!
//! Only the variants the parser actually constructs are printable. Everything
//! else (IR nodes, transform-produced nodes) is a hard error: those trees are
//! not source-level programs and have no canonical spelling.

const std = @import("std");
const ast = @import("ast");

pub const PrintError = error{
    OutOfMemory,
    /// The tree contains a node the parser never produces (IR/transform
    /// output) or a construct whose canonical spelling is not grounded yet.
    /// stderr names the construct.
    UnprintableNode,
};

pub fn printProgram(allocator: std.mem.Allocator, program: *const ast.Program) PrintError![]u8 {
    var p = Printer{ .allocator = allocator };
    errdefer p.buf.deinit(allocator);

    // Module-level annotations: a bare `~[comptime]` line at the top (210_010).
    // The tree holds them as a program-level list, order-free wrt items.
    if (program.module_annotations.len != 0) {
        try p.write("~[");
        for (program.module_annotations, 0..) |ann, i| {
            if (i > 0) try p.write("|");
            try p.write(ann);
        }
        try p.write("]\n\n");
    }

    var prev: ?*const ast.Item = null;
    for (program.items) |*item| {
        if (wantsBlankBefore(prev, item)) try p.write("\n");
        try p.printItem(item);
        prev = item;
    }
    return p.buf.toOwnedSlice(allocator);
}

/// Blank-line policy (canonical): one blank line between top-level items,
/// except (a) host_line → host_line (code/comment blocks stay contiguous)
/// and (b) after a comment host_line (a comment attaches to what follows).
/// Blank source lines are not in the tree, so this is pure layout policy —
/// any deterministic rule round-trips; this one keeps prints readable.
fn wantsBlankBefore(prev: ?*const ast.Item, cur: *const ast.Item) bool {
    const p = prev orelse return false;
    const prev_is_host = p.* == .host_line;
    const cur_is_host = cur.* == .host_line;
    if (prev_is_host and cur_is_host) return false;
    if (prev_is_host and isCommentLine(p.host_line.content)) return false;
    return true;
}

fn isCommentLine(content: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, content, " \t");
    return std.mem.startsWith(u8, trimmed, "//");
}

const Printer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .{},

    fn write(self: *Printer, s: []const u8) PrintError!void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn print(self: *Printer, comptime fmt: []const u8, args: anytype) PrintError!void {
        try self.buf.print(self.allocator, fmt, args);
    }

    fn unprintable(self: *Printer, what: []const u8) PrintError {
        _ = self;
        std.debug.print("ast_printer: unprintable: {s}\n", .{what});
        return PrintError.UnprintableNode;
    }

    fn writeIndent(self: *Printer, depth: usize) PrintError!void {
        var i: usize = 0;
        while (i < depth) : (i += 1) try self.write("    ");
    }

    // ── paths ────────────────────────────────────────────────────────────

    /// Module qualifiers are stored dot-separated ("std.io") but spelled
    /// slash-separated in source ("std/io:"). Segments join with '.'.
    fn writePath(self: *Printer, path: *const ast.DottedPath) PrintError!void {
        if (path.module_qualifier) |q| {
            for (q) |c| try self.buf.append(self.allocator, if (c == '.') '/' else c);
            try self.write(":");
        }
        for (path.segments, 0..) |seg, i| {
            if (i > 0) try self.write(".");
            try self.write(seg);
        }
    }

    // ── items ────────────────────────────────────────────────────────────

    fn printItem(self: *Printer, item: *const ast.Item) PrintError!void {
        switch (item.*) {
            .host_line => |h| {
                try self.write(h.content);
                try self.write("\n");
            },
            .import_decl => |imp| try self.printImport(&imp),
            .event_decl => |ev| try self.printEventDecl(&ev),
            .proc_decl => |pr| try self.printProcDecl(&pr),
            .immediate_impl => |imm| try self.printImmediateImpl(&imm),
            .flow => |fl| try self.printFlow(&fl),
            .label_decl => return self.unprintable("label_decl (spelling not grounded)"),
            .parse_error => return self.unprintable("parse_error (broken tree has no canonical form)"),
            .module_decl => return self.unprintable("module_decl (post-merge tree, not post-parse)"),
            .event_tap => return self.unprintable("event_tap (transform-produced)"),
            .host_type_decl => return self.unprintable("host_type_decl (no parser constructor)"),
            .native_loop => return self.unprintable("native_loop (IR)"),
            .fused_event => return self.unprintable("fused_event (IR)"),
            .inlined_event => return self.unprintable("inlined_event (IR)"),
            .inline_code => return self.unprintable("inline_code (IR)"),
        }
    }

    fn printImport(self: *Printer, imp: *const ast.ImportDecl) PrintError!void {
        // The parser derives local_name from the path (slashes → dots) when no
        // alias is written; only a divergent local_name is a real alias.
        if (imp.local_name) |ln| {
            if (!aliasIsDerived(ln, imp.path))
                return self.unprintable("import alias (spelling not grounded)");
        }
        try self.print("~import {s}\n", .{imp.path});
    }

    fn aliasIsDerived(local: []const u8, path: []const u8) bool {
        // Derivation: strip an explicit koru extension (`~import std/io.kz`
        // ≡ `~import std/io`, 406_import_explicit_extension), then '/' → '.'.
        var base = path;
        inline for (.{ ".kz", ".kjs", ".k" }) |ext| {
            if (std.mem.endsWith(u8, base, ext)) {
                base = base[0 .. base.len - ext.len];
                break;
            }
        }
        if (local.len != base.len) return false;
        for (local, base) |l, p| {
            if (l != p and !(l == '.' and p == '/')) return false;
        }
        return true;
    }

    // ── event declarations ───────────────────────────────────────────────

    fn printEventDecl(self: *Printer, ev: *const ast.EventDecl) PrintError!void {
        try self.write("~");
        if (ev.annotations.len > 0) {
            try self.write("[");
            for (ev.annotations, 0..) |ann, i| {
                if (i > 0) try self.write("|");
                try self.write(ann);
            }
            try self.write("] ");
        }
        if (ev.is_public) try self.write("pub ");
        try self.write("event ");
        try self.writePath(&ev.path);
        try self.write(" ");
        try self.printShape(&ev.input);
        if (ev.return_type) |rt| {
            try self.print(" -> {s}", .{rt});
            if (ev.return_phantom) |rp| try self.print("<{s}>", .{rp});
        }
        try self.write("\n");
        for (ev.branches) |*br| try self.printBranchDecl(br);
    }

    fn printShape(self: *Printer, shape: *const ast.Shape) PrintError!void {
        if (shape.is_wildcard) return self.unprintable("wildcard input shape (spelling not grounded)");
        if (shape.fields.len == 0) {
            try self.write("{}");
            return;
        }
        try self.write("{ ");
        for (shape.fields, 0..) |*f, i| {
            if (i > 0) try self.write(", ");
            try self.printField(f);
        }
        try self.write(" }");
    }

    fn printField(self: *Printer, f: *const ast.Field) PrintError!void {
        if (f.expression_str != null or f.expression != null)
            return self.unprintable("shape field with expression value");
        try self.print("{s}: ", .{f.name});
        try self.printFieldType(f);
    }

    fn printFieldType(self: *Printer, f: *const ast.Field) PrintError!void {
        if (f.module_path) |mp| {
            // Cross-module type ref: `lib.user:User` is spelled `lib/user:User`.
            for (mp) |c| try self.buf.append(self.allocator, if (c == '.') '/' else c);
            try self.write(":");
        }
        try self.write(f.type);
        if (f.phantom) |ph| try self.print("<{s}>", .{ph});
    }

    /// A payload of exactly one field named `__type_ref` is the parse of a
    /// bare-type branch payload (`| greeting []const u8`).
    fn bareTypeRef(payload: *const ast.Shape) ?*const ast.Field {
        if (payload.fields.len != 1) return null;
        const f = &payload.fields[0];
        if (!std.mem.eql(u8, f.name, "__type_ref")) return null;
        return f;
    }

    fn printBranchDecl(self: *Printer, br: *const ast.Branch) PrintError!void {
        try self.write(switch (br.kind) {
            .terminal => "| ",
            .effect => "! ",
        });
        if (br.is_panic) {
            try self.write("?!");
        } else if (br.is_optional) {
            try self.write("?");
        }
        try self.write(br.name);

        if (br.payload.is_wildcard) {
            try self.write(" *");
        } else if (bareTypeRef(&br.payload)) |f| {
            try self.write(" ");
            try self.printFieldType(f);
        } else if (br.payload.fields.len > 0) {
            try self.write(" ");
            try self.printShape(&br.payload);
        }

        if (br.resume_type) |rt| {
            try self.print(" -> {s}", .{rt});
            if (br.resume_phantom) |rp| try self.print("<{s}>", .{rp});
        } else if (br.resume_phantom != null) {
            return self.unprintable("resume_phantom without resume_type");
        }
        // Multi-arm resume sum: canonical is the single-line form
        // `! ask i32 | halved i32 | timeout` — 210_092/093 pin that the
        // indented spelling parses to the same AST.
        if (br.resume_arms) |arms| {
            for (arms) |*arm| {
                try self.print(" | {s}", .{arm.name});
                if (arm.type) |t| try self.print(" {s}", .{t});
                if (arm.phantom) |ph| try self.print("<{s}>", .{ph});
            }
        }

        // Branch annotations append directly, no space: `| initialized [5]Body[mutable]`.
        for (br.annotations) |ann| try self.print("[{s}]", .{ann});
        try self.write("\n");
    }

    // ── proc declarations ────────────────────────────────────────────────

    fn printProcDecl(self: *Printer, pr: *const ast.ProcDecl) PrintError!void {
        try self.write("~");
        if (pr.annotations.len > 0) {
            try self.write("[");
            for (pr.annotations, 0..) |ann, i| {
                if (i > 0) try self.write("|");
                try self.write(ann);
            }
            try self.write("] ");
        }
        if (pr.is_public) try self.write("pub ");
        try self.write("proc ");
        try self.writePath(&pr.path);
        if (pr.target) |t| try self.print("|{s}", .{t});
        // Proc bodies are opaque Source text, stored verbatim between the
        // braces minus the final newline. Echo the bytes back exactly.
        try self.write(" {");
        try self.write(pr.body.text);
        try self.write("\n}\n");
    }

    // ── immediate impls ──────────────────────────────────────────────────

    fn printImmediateImpl(self: *Printer, imm: *const ast.ImmediateImpl) PrintError!void {
        if (imm.annotations.len > 0)
            return self.unprintable("immediate_impl annotations (spelling not grounded)");
        try self.write("~");
        try self.writePath(&imm.event_path);
        try self.printCtor(&imm.value);
        try self.write("\n");
    }

    /// A branch constructor, WITH its leading joiner: ` => name ...` for the
    /// tagged form, ` -> expr` for the bare-return form.
    fn printCtor(self: *Printer, ctor: *const ast.BranchConstructor) PrintError!void {
        if (ctor.is_bare_return) {
            const pv = ctor.plain_value orelse return self.unprintable("bare-return ctor without plain_value");
            try self.print(" -> {s}", .{pv});
            return;
        }
        try self.print(" => {s}", .{ctor.branch_name});
        if (ctor.plain_value) |pv| {
            try self.print(" {s}", .{pv});
            return;
        }
        // A payloadless construct is spelled by its name alone — the braced
        // relic `=> done {}` is rejected at parse time (210_138), so an
        // empty-fields ctor has exactly one spelling.
        if (ctor.fields.len == 0) return;
        if (ctor.fields.len > 0) {
            try self.write(" { ");
            for (ctor.fields, 0..) |*f, i| {
                if (i > 0) try self.write(", ");
                const expr = f.expression_str orelse
                    return self.unprintable("ctor field without expression_str");
                // Ctor fields pun like call args: name derived from the value's
                // trailing '.'-segment (or the whole text), and PARSE005 rejects
                // the explicit spelling (`ctx: f.ctx` → write `f.ctx`).
                const punned = if (std.mem.lastIndexOfScalar(u8, expr, '.')) |dot|
                    expr[dot + 1 ..]
                else
                    expr;
                if (std.mem.eql(u8, f.name, expr) or std.mem.eql(u8, f.name, punned)) {
                    try self.write(expr);
                } else {
                    try self.print("{s}: {s}", .{ f.name, expr });
                }
            }
            try self.write(" }");
        }
    }

    // ── flows ────────────────────────────────────────────────────────────

    fn printFlow(self: *Printer, fl: *const ast.Flow) PrintError!void {
        if (fl.inline_body != null) return self.unprintable("flow inline_body (transform-produced)");
        if (fl.preamble_code != null) return self.unprintable("flow preamble_code (transform-produced)");
        // super_shape is derived during parse for inline flows; reparse of the
        // printed source recomputes it — nothing to print.

        try self.write("~");
        // Flow annotations: `~[comptime] validateConventions()` (210_030).
        if (fl.annotations.len > 0) {
            try self.write("[");
            for (fl.annotations, 0..) |ann, i| {
                if (i > 0) try self.write("|");
                try self.write(ann);
            }
            try self.write("] ");
        }
        if (fl.impl_of) |*impl_path| {
            // Subflow implementation: `~run = step() ...` / `~greet|en = ...`.
            try self.writePath(impl_path);
            if (fl.impl_variant) |v| try self.print("|{s}", .{v});
            try self.write(" = ");
        } else if (fl.impl_variant != null) {
            return self.unprintable("impl_variant without impl_of");
        }
        if (fl.pre_label) |label| {
            // `~#loop count(current: 1, target: 5)`
            try self.print("#{s} ", .{label});
        }

        const root = &fl.body;
        const node = &(root.node orelse return self.unprintable("flow root without node"));
        if (node.* != .invocation) return self.unprintable("flow root node is not an invocation");
        // Root branch children sit at column 0 (208-style) — UNLESS the root
        // line carries a multi-line source block, whose closing brace must
        // land on the column of the continuation lines that follow (390_023:
        // close col 4, `| kernel k` col 4). Then the children shift one step.
        const kids = hasBranchChildren(root.continuations);
        const child_depth: usize = if (kids and lineCarriesMultilineBlock(node, root.continuations)) 1 else 0;
        try self.printInvocation(&node.invocation, if (kids) child_depth else 0);
        try self.printChildren(root.continuations, child_depth);
        try self.write("\n");
    }

    /// Render a continuation list: leading chain continuations extend the
    /// current line inline (` |> …` / ` => …` / ` -> …`); branch continuations
    /// each start a new line at `depth`. A chain APPEARING AFTER a branch has
    /// no source spelling — hard error (canon hazard if the corpus hits it).
    fn printChildren(self: *Printer, conts: []const ast.Continuation, depth: usize) PrintError!void {
        var seen_branch = false;
        for (conts) |*c| {
            const is_chain = c.branch.len == 0 and !c.is_catchall;
            if (is_chain) {
                if (seen_branch) return self.unprintable("chain continuation after branch continuation");
                try self.printChainCont(c, depth);
            } else {
                seen_branch = true;
                try self.printBranchCont(c, depth);
            }
        }
    }

    fn printChainCont(self: *Printer, c: *const ast.Continuation, depth: usize) PrintError!void {
        try self.printContHeaderChecks(c);
        try self.printNodeJoined(c, depth);
    }

    fn printBranchCont(self: *Printer, c: *const ast.Continuation, depth: usize) PrintError!void {
        try self.write("\n");
        try self.writeIndent(depth);
        try self.write(switch (c.kind) {
            .terminal => "|",
            .effect => "!",
        });
        if (c.is_catchall) {
            // Catch-alls store "?" as their branch name — the glyph, not a
            // real name. `|? Transition t |> …` / `|? b |> …`.
            try self.write("?");
            if (c.catchall_metatype) |mt| try self.print(" {s}", .{mt});
        } else if (c.branch.len > 0) {
            try self.write(" ");
            try self.writeBranchName(c.branch);
        }
        if (c.binding) |b| {
            try self.print(" {s}", .{b});
            for (c.binding_annotations) |ann| try self.print("[{s}]", .{ann});
        } else if (c.binding_annotations.len > 0) {
            return self.unprintable("binding annotations without binding");
        }
        if (c.destructure.len > 0) {
            try self.write(" ");
            try self.printDestructure(c.destructure);
        }
        if (c.condition) |cond| try self.print(" when {s}", .{cond});
        try self.printNodeJoined(c, depth + 1);
    }

    fn hasBranchChildren(conts: []const ast.Continuation) bool {
        for (conts) |*c| {
            if (c.branch.len > 0 or c.is_catchall) return true;
            if (hasBranchChildren(c.continuations)) return true;
        }
        return false;
    }

    fn hasMultilineSourceArg(inv: *const ast.Invocation) bool {
        for (inv.args) |*a| {
            if (a.source_value) |sv| {
                if (std.mem.indexOfScalar(u8, sv.text, '\n') != null) return true;
            }
        }
        return false;
    }

    /// Whether the physical line opened by `node` (including every inline
    /// chain continuation that extends it) carries a multi-line source block.
    /// The root line's block can sit mid-chain (390_023:
    /// `~get-count(): _ |> std/kernel:init(Body) {`).
    fn lineCarriesMultilineBlock(node: *const ast.Node, conts: []const ast.Continuation) bool {
        switch (node.*) {
            .invocation => |*inv| if (hasMultilineSourceArg(inv)) return true,
            .label_with_invocation => |*lwi| if (hasMultilineSourceArg(&lwi.invocation)) return true,
            else => {},
        }
        for (conts) |*c| {
            if (c.branch.len == 0 and !c.is_catchall) {
                if (c.node) |*n| {
                    if (lineCarriesMultilineBlock(n, c.continuations)) return true;
                }
            }
        }
        return false;
    }

    /// Branch heads that aren't plain identifiers carry a delimiter in
    /// source: bracket patterns print raw (`! [GET /] |>`, glob routing),
    /// anything else non-identifier is backtick-quoted (regex heads:
    /// `` | `(?<r>[0-9]+) (?<c>[0-9]+)` { … } |> ``, 810_251).
    fn writeBranchName(self: *Printer, name: []const u8) PrintError!void {
        var plain = true;
        for (name) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) {
                plain = false;
                break;
            }
        }
        if (plain or (name.len >= 2 and name[0] == '[' and name[name.len - 1] == ']')) {
            try self.write(name);
        } else {
            try self.print("`{s}`", .{name});
        }
    }

    fn printContHeaderChecks(self: *Printer, c: *const ast.Continuation) PrintError!void {
        if (c.binding != null or c.destructure.len > 0 or c.condition != null)
            return self.unprintable("chain continuation with binding/destructure/condition");
    }

    fn printDestructure(self: *Printer, fields: []const ast.DestructureField) PrintError!void {
        try self.write("{ ");
        for (fields, 0..) |*f, i| {
            if (i > 0) try self.write(", ");
            try self.write(f.name);
            if (f.type_text) |t| try self.print(": {s}", .{t});
            if (f.sub.len > 0) {
                if (f.type_text != null) return self.unprintable("destructure field with both type and sub");
                try self.write(": ");
                try self.printDestructure(f.sub);
            }
        }
        try self.write(" }");
    }

    /// Write a continuation's node with its joiner, then its children.
    /// Branch children of this node indent one level deeper than the line
    /// that carries it (`depth` is that level already, passed by the caller).
    fn printNodeJoined(self: *Printer, c: *const ast.Continuation, depth: usize) PrintError!void {
        const node = &(c.node orelse {
            // A branch with no node is `| name |> _`? No — the corpus spells
            // empty handlers with an explicit terminal node. Null node has no
            // grounded spelling.
            return self.unprintable("continuation without node");
        });
        // Multi-line source blocks close on the column of the next line the
        // flow expects: the branch children's column when there are any
        // (390_023), else this line's own column (210_086 — a sibling
        // handler follows at the same depth).
        const line_depth = if (depth == 0) 0 else depth - 1;
        const close_depth = if (hasBranchChildren(c.continuations)) depth else line_depth;
        switch (node.*) {
            .invocation => |*inv| {
                try self.write(" |> ");
                try self.printInvocation(inv, close_depth);
            },
            .label_with_invocation => |*lwi| {
                try self.write(" |> ");
                if (!lwi.is_declaration)
                    return self.unprintable("label_with_invocation jump form (spelling not grounded)");
                try self.print("#{s} ", .{lwi.label});
                try self.printInvocation(&lwi.invocation, close_depth);
            },
            .label_jump => |*lj| {
                try self.write(" |> ");
                try self.print("@{s}(", .{lj.label});
                try self.printArgs(lj.args);
                try self.write(")");
            },
            .label_apply => |label| try self.print(" |> @{s}", .{label}),
            .terminal => try self.write(" |> _"),
            .branch_constructor => |*ctor| try self.printCtor(ctor),
            // Bare expressions PRODUCE a value; the glyph is `->` (KORU103
            // guides exactly this: "`|>` chains a step; it cannot introduce
            // the value … — produce a value with `->`").
            .expression => |text| try self.print(" -> {s}", .{text}),
            .conditional_block => return self.unprintable("conditional_block (transform-produced)"),
            .metatype_binding => return self.unprintable("metatype_binding (transform-produced)"),
            .inline_code => return self.unprintable("inline_code node (transform-produced)"),
            .foreach => return self.unprintable("foreach (transform-produced)"),
            .conditional => return self.unprintable("conditional (transform-produced)"),
            .switch_result => return self.unprintable("switch_result (transform-produced)"),
            .assignment => return self.unprintable("assignment (transform-produced)"),
        }
        try self.printChildren(c.continuations, depth);
    }

    // ── invocations & args ───────────────────────────────────────────────

    /// `close_depth`: indentation step for a multi-line source block's
    /// closing brace (content sits one step deeper). See printSourceBlock.
    fn printInvocation(self: *Printer, inv: *const ast.Invocation, close_depth: usize) PrintError!void {
        if (inv.inline_body != null) return self.unprintable("invocation inline_body (transform-produced)");
        if (inv.preamble_code != null) return self.unprintable("invocation preamble_code (transform-produced)");
        if (inv.inserted_by_tap) return self.unprintable("tap-inserted invocation (transform-produced)");
        if (inv.annotations.len > 0) return self.unprintable("invocation annotations (transform-produced)");

        try self.writePath(&inv.path);
        if (inv.variant != null) return self.unprintable("call-site variant (spelling not grounded)");

        // A trailing Source arg is the brace-block call form: bare
        // `print.blk { … }` when it is the only arg, or parens-then-block
        // `~struct(Option<T>) { value: ?T = null }` (030_110) otherwise.
        var source_arg: ?*const ast.Source = null;
        var plain_count: usize = 0;
        for (inv.args, 0..) |*a, i| {
            if (a.source_value) |sv| {
                if (i != inv.args.len - 1)
                    return self.unprintable("source arg not in trailing position");
                source_arg = sv;
            } else {
                plain_count += 1;
            }
        }
        if (plain_count > 0 or source_arg == null) {
            try self.write("(");
            var first = true;
            for (inv.args) |*a| {
                if (a.source_value != null) continue;
                if (!first) try self.write(", ");
                first = false;
                try self.printArg(a);
            }
            try self.write(")");
        }
        if (source_arg) |sv| try self.printSourceBlock(sv, close_depth);

        if (inv.return_destructure.len > 0) {
            // Bind-position destructure prints as `: { ... }`, not the synthetic
            // temp the parser bound it to (return_binding is `__ret_destr_N`).
            try self.write(": ");
            try self.printDestructure(inv.return_destructure);
        } else if (inv.return_binding) |rb| {
            try self.print(": {s}", .{rb});
            for (inv.return_binding_annotations) |ann| try self.print("[{s}]", .{ann});
        } else if (inv.return_binding_annotations.len > 0) {
            return self.unprintable("return_binding annotations without return_binding");
        }
    }

    /// Block-call Source text is stored dedented. Single-line text prints as
    /// inline braces (`capture { s: 0[i64] }`, 310_090). Multi-line text
    /// prints with the closing brace at `close_depth` — the column of the
    /// next line the flow expects (210_086: sibling handler col 0 → close 0;
    /// 390_023: children col 4 → close 4) — and content one step deeper.
    /// Chains continue inline after `}` (390_090: `} |> std/kernel:self {`).
    fn printSourceBlock(self: *Printer, src: *const ast.Source, close_depth: usize) PrintError!void {
        if (src.phantom_type != null) return self.unprintable("source block phantom type (spelling not grounded)");
        if (src.text.len == 0) {
            try self.write(" {}");
            return;
        }
        // One-line content renders as inline braces (`capture { n: 0[i64] }`)
        // — safe in every position since the gatherer became brace-aware
        // (netBraces, pinned by 210_139; this printer used to carry per-line
        // state to dodge the misattachment).
        if (std.mem.indexOfScalar(u8, src.text, '\n') == null) {
            try self.print(" {{ {s} }}", .{src.text});
            return;
        }
        // A trailing '\n' in the stored text must NOT become an extra blank
        // line (const-style blocks keep their final newline, 010_005).
        try self.write(" {\n");
        var it = std.mem.splitScalar(u8, src.text, '\n');
        while (it.next()) |line| {
            if (line.len == 0 and it.peek() == null) break;
            if (line.len > 0) try self.writeIndent(close_depth + 1);
            try self.write(line);
            try self.write("\n");
        }
        try self.writeIndent(close_depth);
        try self.write("}");
    }

    fn printArgs(self: *Printer, args: []const ast.Arg) PrintError!void {
        for (args, 0..) |*a, i| {
            if (i > 0) try self.write(", ");
            try self.printArg(a);
        }
    }

    fn printArg(self: *Printer, a: *const ast.Arg) PrintError!void {
        if (a.source_value != null)
            return self.unprintable("source arg in multi-arg call (spelling not grounded)");
        if (a.expression_value) |ev| {
            // Expression params capture verbatim; the arg's `name` is the
            // param name. Canonical form is ALWAYS named: positional works
            // for most texts but mis-parses when the expression starts with
            // '{' (020_010), and named capture is verified equivalent.
            try self.print("{s}: {s}", .{ a.name, ev.text });
            return;
        }
        // Punned args are canonical-POSITIONAL: the parser derives the name
        // from the value (segment after the last '.', else the whole text —
        // lexer.isRedundantExplicitLabel), and PARSE005 rejects the explicit
        // spelling of a name the value already puns to.
        const punned_name = if (std.mem.lastIndexOfScalar(u8, a.value, '.')) |dot|
            a.value[dot + 1 ..]
        else
            a.value;
        if (std.mem.eql(u8, a.name, a.value) or std.mem.eql(u8, punned_name, a.name)) {
            try self.write(a.value);
        } else {
            try self.print("{s}: {s}", .{ a.name, a.value });
        }
        if (a.phantom_type) |ph| try self.print("<{s}>", .{ph});
    }
};

// ── tests ───────────────────────────────────────────────────────────────────

/// The round-trip contract, in-miniature: parse → print → parse must be
/// tree-equal (canon JSON bytes), print → parse → print must be byte-equal.
/// The corpus-wide version lives in scripts/roundtrip_harness.sh.
fn expectRoundTrip(source: []const u8) !void {
    const Parser = @import("parser").Parser;
    const ast_json = @import("ast_json");
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parser1 = try Parser.init(a, source, "test.kz", &[_][]const u8{}, null);
    var result1 = try parser1.parse();
    const canon1 = try ast_json.serializeCanon(a, &result1.source_file);
    const print1 = try printProgram(a, &result1.source_file);

    var parser2 = try Parser.init(a, print1, "test.kz", &[_][]const u8{}, null);
    var result2 = try parser2.parse();
    const canon2 = try ast_json.serializeCanon(a, &result2.source_file);
    const print2 = try printProgram(a, &result2.source_file);

    try std.testing.expectEqualStrings(canon1, canon2);
    try std.testing.expectEqualStrings(print1, print2);
}

test "round-trip: event + proc + flow with branches" {
    try expectRoundTrip(
        \\const std = @import("std");
        \\
        \\~event check { value: i32 }
        \\| positive i32
        \\| zero
        \\| negative i32
        \\
        \\~proc check|zig {
        \\    if (value > 0) return .{ .positive = value };
        \\    if (value < 0) return .{ .negative = value };
        \\    return .{ .zero = .{} };
        \\}
        \\
        \\~check(value: 42)
        \\| positive p |> check(value: p)
        \\| zero |> _
        \\| negative n |> check(n)
    );
}

test "round-trip: subflow impl, immediate impl, bare-return" {
    try expectRoundTrip(
        \\~event greet { name: string } -> string
        \\
        \\~greet -> "Hello, " ++ name ++ "!"
        \\
        \\~pub event double { a: i32 } -> i32
        \\
        \\~double -> a * 2
        \\
        \\~pub event step {}
        \\| return
        \\| continue
        \\
        \\~step => continue
        \\
        \\~event run {}
        \\| stopped
        \\| iterated
        \\
        \\~run = step()
        \\| return => stopped
        \\| continue => iterated
    );
}

test "round-trip: effect branches, labels, nesting" {
    try expectRoundTrip(
        \\const std = @import("std");
        \\
        \\~pub event ping { msg: string }
        \\! pong string
        \\
        \\~proc ping|zig {
        \\    pong(msg);
        \\}
        \\
        \\~event count { current: i32, target: i32 }
        \\| more i32
        \\| done i32
        \\
        \\~proc count|zig {
        \\    if (current < target) return .{ .more = current + 1 };
        \\    return .{ .done = current };
        \\}
        \\
        \\~#loop count(current: 1, target: 5)
        \\| more m |> @loop(current: m, target: 5)
        \\| done d |> _
    );
}

