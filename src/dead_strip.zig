const std = @import("std");
const ast = @import("ast");

/// Dead Strip Pass
///
/// Removes unreachable event declarations and proc implementations from the AST.
/// An event is "reachable" if its path appears as an invocation anywhere in the
/// program — in flows, continuation nodes, or tap references.
///
/// Koru compiles to a single binary with full program visibility. There is no
/// separate compilation, no dynamic linking, no C ABI to honor. If nobody calls
/// it, it doesn't exist in the output.

pub const DeadStripPass = struct {
    allocator: std.mem.Allocator,
    /// Set of event path strings that are referenced somewhere in the program
    used: std.StringHashMap(void),
    /// Count of stripped items (for diagnostics)
    stripped_count: usize = 0,

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

    pub fn run(self: *DeadStripPass, program: *const ast.Program) !*const ast.Program {
        // Phase 1: Collect all invoked event paths
        try self.collectUsedPaths(program.items);

        // Phase 2: Filter items, removing unreferenced event_decl and proc_decl
        const new_items = try self.filterItems(program.items);

        // Build new program with filtered items
        const new_program = try self.allocator.create(ast.Program);
        new_program.* = program.*;
        new_program.items = new_items;

        std.debug.print("[DEAD-STRIP] Stripped {d} unreachable items\n", .{self.stripped_count});

        return new_program;
    }

    // ========================================================================
    // Phase 1: Collect all event paths that are referenced
    // ========================================================================

    fn collectUsedPaths(self: *DeadStripPass, items: []const ast.Item) !void {
        for (items) |item| {
            switch (item) {
                .flow => |flow| {
                    try self.collectFromInvocation(&flow.invocation);
                    try self.collectFromContinuations(flow.continuations);
                },
                .event_tap => |tap| {
                    if (tap.source) |source| try self.markPath(&source);
                    if (tap.destination) |dest| try self.markPath(&dest);
                    try self.collectFromContinuations(tap.continuations);
                },
                .module_decl => |mod| {
                    try self.collectUsedPaths(mod.items);
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
            .capture => |n| {
                for (n.branches) |branch| {
                    try self.collectFromContinuations(branch.body);
                }
            },
            .switch_result => |n| {
                for (n.branches) |branch| {
                    try self.collectFromContinuations(branch.body);
                }
            },
            .deref => |d| {
                // A deref might reference an event indirectly — mark the target
                // as used to be safe
                const key = try self.allocator.dupe(u8, d.target);
                self.used.put(key, {}) catch {
                    self.allocator.free(key);
                };
            },
            // terminal, label_apply, label_jump, branch_constructor, assignment — no event references
            else => {},
        }
    }

    fn markPath(self: *DeadStripPass, path: *const ast.DottedPath) !void {
        const key = try self.pathToString(path);
        self.used.put(key, {}) catch {
            self.allocator.free(key);
        };
    }

    fn pathToString(self: *DeadStripPass, path: *const ast.DottedPath) ![]const u8 {
        var len: usize = 0;
        if (path.module_qualifier) |mq| {
            len += mq.len + 1; // "module:"
        }
        for (path.segments, 0..) |seg, i| {
            if (i > 0) len += 1; // "."
            len += seg.len;
        }

        const buf = try self.allocator.alloc(u8, len);
        var pos: usize = 0;

        if (path.module_qualifier) |mq| {
            @memcpy(buf[pos .. pos + mq.len], mq);
            pos += mq.len;
            buf[pos] = ':';
            pos += 1;
        }
        for (path.segments, 0..) |seg, i| {
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
            @memcpy(buf[pos .. pos + seg.len], seg);
            pos += seg.len;
        }

        return buf;
    }

    // ========================================================================
    // Phase 2: Filter unreachable declarations
    // ========================================================================

    fn filterItems(self: *DeadStripPass, items: []const ast.Item) ![]const ast.Item {
        var result = try std.ArrayList(ast.Item).initCapacity(self.allocator, items.len);

        for (items) |item| {
            switch (item) {
                .event_decl => |decl| {
                    if (try self.isPathUsed(&decl.path) or hasRetain(decl.annotations)) {
                        try result.append(self.allocator, item);
                    } else {
                        const name = try self.pathToString(&decl.path);
                        defer self.allocator.free(name);
                        std.debug.print("[DEAD-STRIP] Removing event_decl: {s}\n", .{name});
                        self.stripped_count += 1;
                    }
                },
                .proc_decl => |decl| {
                    if (try self.isPathUsed(&decl.path) or hasRetain(decl.annotations)) {
                        try result.append(self.allocator, item);
                    } else {
                        const name = try self.pathToString(&decl.path);
                        defer self.allocator.free(name);
                        std.debug.print("[DEAD-STRIP] Removing proc_decl: {s}\n", .{name});
                        self.stripped_count += 1;
                    }
                },
                .module_decl => |mod| {
                    // Recurse into modules — filter their items too
                    const filtered_items = try self.filterItems(mod.items);
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

    fn isPathUsed(self: *DeadStripPass, path: *const ast.DottedPath) !bool {
        const key = try self.pathToString(path);
        defer self.allocator.free(key);
        return self.used.contains(key);
    }

    fn hasRetain(annotations: []const []const u8) bool {
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann, "retain")) return true;
        }
        return false;
    }
};
