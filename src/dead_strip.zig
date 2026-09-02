const std = @import("std");
const log = @import("log");
const ast = @import("ast");

/// Dead Strip Pass
///
/// Removes unreachable event declarations and proc implementations from the AST.
/// An event is "reachable" if its path appears as an invocation anywhere in the
/// program — in flows, continuation nodes, or tap references.
///
/// A transform that inlines a continuation (orisha:router, ~for) rewrites the
/// call into a string inside `inline_body` and empties the continuation tree.
/// Reachability is a fact about the SOURCE program, so this pass also walks
/// `original_ast` (the pre-transform tree) and scans `inline_body` for
/// `name_event.handler` that continuation_codegen emitted. Otherwise a live
/// callee whose only remaining reference is generated Zig is stripped, and
/// the inlined call names a member that does not exist (350_021).
///
/// Compiling a PROGRAM, the roots are its flows: Koru has full visibility, and
/// if nobody calls it, it doesn't exist in the output.
///
/// Compiling a LIBRARY, that premise inverts. The roots are what the entry
/// module EXPORTS, and "nobody here calls it" is the normal case rather than
/// evidence the thing is dead — the caller has not been written yet, and may
/// never be in this language.
///
/// `pub` already means exactly that: visible outside this module. So a library
/// needs no new marker; it needs a compilation in which "outside" exists.
/// `library_roots` switches which of the two is in force.

pub const DeadStripPass = struct {
    allocator: std.mem.Allocator,
    /// Set of event path strings that are referenced somewhere in the program
    used: std.StringHashMap(void),
    /// Count of stripped items (for diagnostics)
    stripped_count: usize = 0,
    /// When true, the entry module's `pub` items are roots and survive with no
    /// caller. Set for `koruc lib`; a program build leaves it false.
    library_roots: bool = false,

    pub fn init(allocator: std.mem.Allocator) DeadStripPass {
        return .{
            .allocator = allocator,
            .used = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *DeadStripPass) void {
        var it = self.used.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.used.deinit();
    }

    pub fn run(self: *DeadStripPass, program: *const ast.Program, original: ?*const ast.Program) !*const ast.Program {
        // Phase 1: Collect all invoked event paths
        try self.collectUsedPaths(program.items, program.main_module_name);
        // Pre-transform tree still has the AST calls a transform later inlined.
        if (original) |orig| {
            if (orig != program) try self.collectUsedPaths(orig.items, orig.main_module_name);
        }

        // A library's exports are roots. Seeding them BEFORE the walk means
        // everything they reach is reachable too — an exported entry point
        // drags its whole call graph in, which is the only reading that makes
        // a library usable rather than a shell of empty names.
        if (self.library_roots) try self.seedExportedRoots(program.items, program.main_module_name);

        // Phase 2: Filter items, removing unreferenced event_decl and proc_decl
        const new_items = try self.filterItems(program.items, null);

        // Build new program with filtered items
        const new_program = try self.allocator.create(ast.Program);
        new_program.* = program.*;
        new_program.items = new_items;

        log.debug("[DEAD-STRIP] Stripped {d} unreachable items\n", .{self.stripped_count});

        return new_program;
    }

    /// Mark every `pub` event in the entry module as used, then walk what each
    /// one reaches. Only the ENTRY module's exports count: a `pub` inside an
    /// imported library is that library's export surface, not this one's, and
    /// treating it as a root here would keep the whole of every dependency.
    fn seedExportedRoots(self: *DeadStripPass, items: []const ast.Item, entry_module: []const u8) !void {
        var roots: usize = 0;
        for (items) |item| {
            if (item != .event_decl) continue;
            const ev = item.event_decl;
            if (!ev.is_public) continue;
            // Entry-module exports only, matched BY NAME rather than by an
            // absent qualifier: the entry module carries its own name here
            // (`lib.k` → "lib"), so "no qualifier" selects nothing at all.
            const mq = ev.path.module_qualifier orelse continue;
            if (entry_module.len == 0 or !std.mem.eql(u8, mq, entry_module)) continue;
            const path = try self.pathToStringInner(&ev.path);
            defer self.allocator.free(path);
            if (!self.used.contains(path)) {
                try self.used.put(try self.allocator.dupe(u8, path), {});
                roots += 1;
            }
        }
        log.debug("[DEAD-STRIP] library mode: {d} exported root(s)\n", .{roots});
        // A root's callees are reachable through it. The collect walk keys on
        // INVOCATIONS, so a flow implementing an exported event was already
        // counted; what this adds is the export itself, which nothing invokes.
    }

    // ========================================================================
    // Phase 1: Collect all event paths that are referenced
    // ========================================================================

    fn collectUsedPaths(self: *DeadStripPass, items: []const ast.Item, main_module: []const u8) !void {
        for (items) |item| {
            switch (item) {
                .flow => |flow| {
                    try self.collectFromInvocation(flow.inv());
                    try self.collectFromContinuations(flow.body.continuations);
                    if (flow.inline_body) |ib| {
                        try self.collectFromInlineBody(ib, main_module);
                    }
                },
                .event_tap => |tap| {
                    if (tap.source) |source| try self.markPath(&source);
                    if (tap.destination) |dest| try self.markPath(&dest);
                    try self.collectFromContinuations(tap.continuations);
                },
                .module_decl => |mod| {
                    try self.collectUsedPaths(mod.items, main_module);
                },
                .immediate_impl => |impl| {
                    try self.markPath(&impl.event_path);
                },
                // @retain events are explicitly marked as used (by transforms like register)
                .event_decl => |decl| {
                    if (hasRetain(decl.annotations)) {
                        try self.markPath(&decl.path);
                    }
                },
                // proc_decl, host_line, etc. — no invocations to collect
                else => {},
            }
        }
    }

    /// continuation_codegen emits `main_module.name_event.handler(...)`. A
    /// transform that replaced the AST call with that string still needs the
    /// event to exist. Mark `name` and `main:name` so isPathUsed matches the
    /// qualified decl.
    fn collectFromInlineBody(self: *DeadStripPass, body: []const u8, main_module: []const u8) !void {
        const needle = "_event.handler";
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, body, i, needle)) |idx| {
            var start = idx;
            while (start > 0) {
                const c = body[start - 1];
                const ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                    (c >= '0' and c <= '9') or c == '_';
                if (!ident) break;
                start -= 1;
            }
            const name = body[start..idx];
            if (name.len > 0) {
                try self.markBareName(name, main_module);
            }
            i = idx + needle.len;
        }
    }

    fn markBareName(self: *DeadStripPass, name: []const u8, main_module: []const u8) !void {
        const bare = try self.allocator.dupe(u8, name);
        self.used.put(bare, {}) catch {
            self.allocator.free(bare);
        };
        if (main_module.len == 0) return;
        const qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ main_module, name });
        self.used.put(qualified, {}) catch {
            self.allocator.free(qualified);
        };
    }

    fn collectFromInvocation(self: *DeadStripPass, invocation: *const ast.Invocation) !void {
        try self.markPath(&invocation.path);
    }

    fn collectFromContinuations(self: *DeadStripPass, continuations: []const ast.Continuation) std.mem.Allocator.Error!void {
        for (continuations) |cont| {
            if (cont.node) |node| {
                try self.collectFromNode(&node);
            }
            // Recurse into nested continuations
            try self.collectFromContinuations(cont.continuations);
        }
    }

    fn collectFromNode(self: *DeadStripPass, node: *const ast.Node) std.mem.Allocator.Error!void {
        switch (node.*) {
            .invocation => |inv| {
                try self.collectFromInvocation(&inv);
            },
            .label_with_invocation => |lwi| {
                try self.collectFromInvocation(&lwi.invocation);
            },
            .conditional_block => |cb| {
                for (cb.nodes) |n| {
                    try self.collectFromNode(&n);
                }
            },
            // Transform-generated nodes: walk into NamedBranch bodies
            .conditional => |n| {
                for (n.branches) |branch| {
                    try self.collectFromContinuations(branch.body);
                }
            },
            .foreach => |n| {
                for (n.branches) |branch| {
                    try self.collectFromContinuations(branch.body);
                }
            },
            .switch_result => |n| {
                for (n.branches) |branch| {
                    try self.collectFromContinuations(branch.body);
                }
            },
            // terminal, label_apply, label_jump, branch_constructor, assignment — no event references
            else => {},
        }
    }

    fn markPath(self: *DeadStripPass, path: *const ast.DottedPath) !void {
        const key = try self.pathToStringInner(path);
        self.used.put(key, {}) catch {
            self.allocator.free(key);
        };
    }

    fn pathToString(self: *DeadStripPass, path: *const ast.DottedPath, module_logical_name: ?[]const u8) ![]const u8 {
        if (path.module_qualifier != null) return self.pathToStringInner(path);
        if (module_logical_name) |mq| {
            const bare = try self.pathToStringInner(path);
            defer self.allocator.free(bare);
            return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mq, bare });
        }
        return self.pathToStringInner(path);
    }

    fn pathToStringInner(self: *DeadStripPass, path: *const ast.DottedPath) ![]const u8 {
        var len: usize = 0;
        if (path.module_qualifier) |mq| {
            len += mq.len + 1; // "module:"
        }
        len += segmentsStringLen(path.segments);

        const buf = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(buf);
        var pos: usize = 0;

        if (path.module_qualifier) |mq| {
            @memcpy(buf[pos .. pos + mq.len], mq);
            pos += mq.len;
            buf[pos] = ':';
            pos += 1;
        }
        pos = try writeSegments(buf, pos, path.segments);

        return buf;
    }

    fn segmentsStringLen(segments: []const []const u8) usize {
        var len: usize = 0;
        for (segments, 0..) |seg, i| {
            if (i > 0) len += 1;
            len += seg.len;
        }
        return len;
    }

    fn writeSegments(buf: []u8, pos: usize, segments: []const []const u8) !usize {
        var p = pos;
        for (segments, 0..) |seg, i| {
            if (i > 0) {
                buf[p] = '.';
                p += 1;
            }
            @memcpy(buf[p .. p + seg.len], seg);
            p += seg.len;
        }
        return p;
    }

    fn segmentsToString(self: *DeadStripPass, path: *const ast.DottedPath) ![]const u8 {
        const len = segmentsStringLen(path.segments);
        const buf = try self.allocator.alloc(u8, len);
        _ = try writeSegments(buf, 0, path.segments);
        return buf;
    }

    // ========================================================================
    // Phase 2: Filter unreachable declarations
    // ========================================================================

    fn filterItems(self: *DeadStripPass, items: []const ast.Item, module_logical_name: ?[]const u8) ![]const ast.Item {
        var result = try std.ArrayList(ast.Item).initCapacity(self.allocator, items.len);

        for (items) |item| {
            switch (item) {
                .event_decl => |decl| {
                    if (try self.isPathUsed(&decl.path, module_logical_name) or hasRetain(decl.annotations)) {
                        try result.append(self.allocator, item);
                    } else {
                        const name = try self.pathToString(&decl.path, module_logical_name);
                        defer self.allocator.free(name);
                        log.debug("[DEAD-STRIP] Removing event_decl: {s}\n", .{name});
                        self.stripped_count += 1;
                    }
                },
                .proc_decl => |decl| {
                    if (try self.isPathUsed(&decl.path, module_logical_name) or hasRetain(decl.annotations)) {
                        try result.append(self.allocator, item);
                    } else {
                        const name = try self.pathToString(&decl.path, module_logical_name);
                        defer self.allocator.free(name);
                        log.debug("[DEAD-STRIP] Removing proc_decl: {s}\n", .{name});
                        self.stripped_count += 1;
                    }
                },
                .module_decl => |mod| {
                    // Recurse into modules — filter their items too
                    const filtered_items = try self.filterItems(mod.items, mod.logical_name);
                    var new_mod = mod;
                    new_mod.items = filtered_items;
                    try result.append(self.allocator, .{ .module_decl = new_mod });
                },
                // Everything else stays: flows, host_lines, taps, labels, etc.
                else => {
                    try result.append(self.allocator, item);
                },
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn isPathUsed(self: *DeadStripPass, path: *const ast.DottedPath, module_logical_name: ?[]const u8) !bool {
        const key = try self.pathToStringInner(path);
        defer self.allocator.free(key);
        if (self.used.contains(key)) return true;

        // Welded modules may parse with basename qualifiers (`breath:init`) or
        // bare segments (`init`) while invocations use the dotted logical name
        // (`koru.signal_rt.breath:init`). canonicalize_names stamps logical names
        // only when module_qualifier is null — stale basename qualifiers skip
        // that path (frag-0002). Match via the enclosing module_decl name too.
        if (module_logical_name) |mq| {
            const seg_key = try self.segmentsToString(path);
            defer self.allocator.free(seg_key);
            const qualified = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ mq, seg_key });
            defer self.allocator.free(qualified);
            if (self.used.contains(qualified)) return true;
        }
        return false;
    }

    fn hasRetain(annotations: []const []const u8) bool {
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann, "retain")) return true;
        }
        return false;
    }
};

const testProcBody = struct {
    fn call(text: []const u8) ast.Source {
        return .{
            .text = text,
            .scope = .{ .bindings = &.{} },
        };
    }
}.call;

fn freeFilteredProgram(allocator: std.mem.Allocator, program: *const ast.Program) void {
    for (program.items) |item| {
        if (item == .module_decl) {
            allocator.free(item.module_decl.items);
        }
    }
    allocator.free(program.items);
    allocator.destroy(program);
}

test "keeps welded-module events when invocation uses logical module name" {
    const allocator = std.testing.allocator;

    var pass = DeadStripPass.init(allocator);
    defer pass.deinit();

    const mq = "koru.signal_rt.breath";
    var invoke_segs = [_][]const u8{"init"};
    const invoke_path = ast.DottedPath{
        .module_qualifier = mq,
        .segments = &invoke_segs,
    };
    const invoke_node = ast.Node{ .invocation = ast.Invocation{
        .path = invoke_path,
        .args = &.{},
    } };
    const user_flow = ast.Item{ .flow = ast.Flow{
        .body = ast.rootSite(ast.Invocation{
            .path = invoke_path,
            .args = &.{},
        }, &.{}, .{ .file = "input.kz", .line = 1, .column = 0 }),
    } };
    _ = invoke_node;

    var event_segs = [_][]const u8{"init"};
    const event_decl = ast.Item{ .event_decl = ast.EventDecl{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &event_segs,
        },
        .input = .{ .fields = &.{} },
        .branches = &.{},
        .return_type = null,
        .return_phantom = null,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = &.{},
        .prose = "",
        .location = .{ .file = "breath.kz", .line = 1, .column = 0 },
        .module = "breath",
    } };

    var proc_segs = [_][]const u8{"init"};
    const proc_decl = ast.Item{ .proc_decl = ast.ProcDecl{
        .path = ast.DottedPath{
            .module_qualifier = null,
            .segments = &proc_segs,
        },
        .target = null,
        .body = testProcBody("return .{ .ok = .{} };"),
        .annotations = &.{},
        .location = .{ .file = "breath.kz", .line = 2, .column = 0 },
        .module = "breath",
    } };

    const welded_module = ast.Item{ .module_decl = ast.ModuleDecl{
        .logical_name = mq,
        .canonical_path = "/tmp/breath.kz",
        .items = &.{ event_decl, proc_decl },
        .is_system = false,
        .annotations = &.{},
        .location = .{ .file = "/tmp/breath.kz", .line = 1, .column = 0 },
    } };

    const program = ast.Program{
        .items = &.{ user_flow, welded_module },
        .module_annotations = &.{},
        .main_module_name = "input",
        .allocator = allocator,
    };

    const filtered = try pass.run(&program, null);
    defer freeFilteredProgram(allocator, filtered);

    var kept_event = false;
    var kept_proc = false;
    for (filtered.items) |item| {
        if (item == .module_decl) {
            for (item.module_decl.items) |mod_item| {
                if (mod_item == .event_decl) kept_event = true;
                if (mod_item == .proc_decl) kept_proc = true;
            }
        }
    }
    try std.testing.expect(kept_event);
    try std.testing.expect(kept_proc);
}

test "strips sibling events in welded module when only init is invoked" {
    const allocator = std.testing.allocator;

    var pass = DeadStripPass.init(allocator);
    defer pass.deinit();

    const mq = "koru.signal_rt.breath";
    var invoke_segs = [_][]const u8{"init"};
    const invoke_path = ast.DottedPath{
        .module_qualifier = mq,
        .segments = &invoke_segs,
    };
    const user_flow = ast.Item{ .flow = ast.Flow{
        .body = ast.rootSite(ast.Invocation{
            .path = invoke_path,
            .args = &.{},
        }, &.{}, .{ .file = "input.kz", .line = 1, .column = 0 }),
    } };

    var init_segs = [_][]const u8{"init"};
    const init_event = ast.Item{ .event_decl = ast.EventDecl{
        .path = ast.DottedPath{ .module_qualifier = null, .segments = &init_segs },
        .input = .{ .fields = &.{} },
        .branches = &.{},
        .return_type = null,
        .return_phantom = null,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = &.{},
        .prose = "",
        .location = .{ .file = "breath.kz", .line = 1, .column = 0 },
        .module = "breath",
    } };
    const init_proc = ast.Item{ .proc_decl = ast.ProcDecl{
        .path = ast.DottedPath{ .module_qualifier = null, .segments = &init_segs },
        .target = null,
        .body = testProcBody("return .{ .ok = .{} };"),
        .annotations = &.{},
        .location = .{ .file = "breath.kz", .line = 2, .column = 0 },
        .module = "breath",
    } };

    var tick_segs = [_][]const u8{"tick"};
    const tick_event = ast.Item{ .event_decl = ast.EventDecl{
        .path = ast.DottedPath{ .module_qualifier = null, .segments = &tick_segs },
        .input = .{ .fields = &.{} },
        .branches = &.{},
        .return_type = null,
        .return_phantom = null,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = &.{},
        .prose = "",
        .location = .{ .file = "breath.kz", .line = 10, .column = 0 },
        .module = "breath",
    } };
    const tick_proc = ast.Item{ .proc_decl = ast.ProcDecl{
        .path = ast.DottedPath{ .module_qualifier = null, .segments = &tick_segs },
        .target = null,
        .body = testProcBody("return .{ .out = .{} };"),
        .annotations = &.{},
        .location = .{ .file = "breath.kz", .line = 11, .column = 0 },
        .module = "breath",
    } };

    const welded_module = ast.Item{ .module_decl = ast.ModuleDecl{
        .logical_name = mq,
        .canonical_path = "/tmp/breath.kz",
        .items = &.{ init_event, init_proc, tick_event, tick_proc },
        .is_system = false,
        .annotations = &.{},
        .location = .{ .file = "/tmp/breath.kz", .line = 1, .column = 0 },
    } };

    const program = ast.Program{
        .items = &.{ user_flow, welded_module },
        .module_annotations = &.{},
        .main_module_name = "input",
        .allocator = allocator,
    };

    const filtered = try pass.run(&program, null);
    defer freeFilteredProgram(allocator, filtered);

    var init_kept = false;
    var tick_kept = false;
    for (filtered.items) |item| {
        if (item != .module_decl) continue;
        for (item.module_decl.items) |mod_item| {
            if (mod_item == .event_decl) {
                if (mod_item.event_decl.path.segments.len == 1 and std.mem.eql(u8, mod_item.event_decl.path.segments[0], "init")) {
                    init_kept = true;
                }
                if (mod_item.event_decl.path.segments.len == 1 and std.mem.eql(u8, mod_item.event_decl.path.segments[0], "tick")) {
                    tick_kept = true;
                }
            }
        }
    }
    try std.testing.expect(init_kept);
    try std.testing.expect(!tick_kept);
}

test "keeps welded-module events when decl carries stale basename qualifier" {
    const allocator = std.testing.allocator;

    var pass = DeadStripPass.init(allocator);
    defer pass.deinit();

    const mq = "koru.signal_rt.breath";
    var invoke_segs = [_][]const u8{"init"};
    const invoke_path = ast.DottedPath{
        .module_qualifier = mq,
        .segments = &invoke_segs,
    };
    const user_flow = ast.Item{ .flow = ast.Flow{
        .body = ast.rootSite(ast.Invocation{
            .path = invoke_path,
            .args = &.{},
        }, &.{}, .{ .file = "input.kz", .line = 1, .column = 0 }),
    } };

    // Simulate parse output before canonicalize_names upgrades null qualifiers:
    // basename module_qualifier that canonicalize would leave untouched.
    const stale_mq = "breath";
    var event_segs = [_][]const u8{"init"};
    const event_decl = ast.Item{ .event_decl = ast.EventDecl{
        .path = ast.DottedPath{
            .module_qualifier = stale_mq,
            .segments = &event_segs,
        },
        .input = .{ .fields = &.{} },
        .branches = &.{},
        .return_type = null,
        .return_phantom = null,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = &.{},
        .prose = "",
        .location = .{ .file = "breath.kz", .line = 1, .column = 0 },
        .module = "breath",
    } };

    const welded_module = ast.Item{ .module_decl = ast.ModuleDecl{
        .logical_name = mq,
        .canonical_path = "/tmp/breath.kz",
        .items = &.{event_decl},
        .is_system = false,
        .annotations = &.{},
        .location = .{ .file = "/tmp/breath.kz", .line = 1, .column = 0 },
    } };

    const program = ast.Program{
        .items = &.{ user_flow, welded_module },
        .module_annotations = &.{},
        .main_module_name = "input",
        .allocator = allocator,
    };

    const filtered = try pass.run(&program, null);
    defer freeFilteredProgram(allocator, filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.items.len);
    for (filtered.items) |item| {
        if (item == .module_decl) {
            try std.testing.expectEqual(@as(usize, 1), item.module_decl.items.len);
        }
    }
}
