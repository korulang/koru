const std = @import("std");
const ast = @import("ast");

/// Purity Checker - Analyzes and propagates purity information through the AST
///
/// This implements a 4-phase analysis pass:
/// Phase 1: Mark local purity (based on annotations and patterns)
/// Phase 2: Build call graph (track which events are called by each proc/flow)
/// Phase 3: Propagate transitive purity (iterate until fixed point)
/// Phase 4: Compute event purity (from proc implementations)
///
/// See tests/regression/1000_PURITY/PURITY-TRACKING.md for full specification

/// Call graph entry - tracks what events a proc/flow calls
const CallInfo = struct {
    calls: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !CallInfo {
        return .{
            .calls = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .allocator = allocator,
        };
    }

    fn deinit(self: *CallInfo) void {
        for (self.calls.items) |call| {
            self.allocator.free(call);
        }
        self.calls.deinit(self.allocator);
    }
};

pub const PurityChecker = struct {
    allocator: std.mem.Allocator,
    // Maps proc/event names to list of events they call
    call_graph: std.StringHashMap(CallInfo),
    // Maps event names to their EventDecl
    events: std.StringHashMap(*const ast.EventDecl),

    pub fn init(allocator: std.mem.Allocator) PurityChecker {
        return .{
            .allocator = allocator,
            .call_graph = std.StringHashMap(CallInfo).init(allocator),
            .events = std.StringHashMap(*const ast.EventDecl).init(allocator),
        };
    }

    pub fn deinit(self: *PurityChecker) void {
        var iter = self.call_graph.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.call_graph.deinit();

        var event_iter = self.events.iterator();
        while (event_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.events.deinit();
    }

    /// Main entry point - analyze purity for entire source file
    pub fn check(self: *PurityChecker, source: *ast.Program) !void {
        // Phase 1: Mark local purity (already done in parser for procs, flows have defaults)
        // Procs: is_pure = true if has ~[pure] annotation (handled in parser)
        // Flows: is_pure = true always (set in AST defaults)
        // Events: is_pure = false (default, will be computed in Phase 4)

        // Phase 2: Build call graph
        try self.buildCallGraph(source);

        // Phase 3: Propagate transitive purity
        try self.propagateTransitivePurity(source);

        // Phase 4: Compute event purity
        try self.computeEventPurity(source);
    }

    /// Phase 2: Build call graph - walk AST and track event invocations
    fn buildCallGraph(self: *PurityChecker, source: *ast.Program) !void {
        // First pass: register all events (including in modules)
        try self.registerEventsRecursive(source.items);

        // Second pass: build call graph for procs (including in modules)
        try self.buildCallGraphRecursive(source.items);
    }

    /// Helper: Register all events recursively, including in modules
    fn registerEventsRecursive(self: *PurityChecker, items: []const ast.Item) !void {
        for (items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    const name = try self.pathToString(event.path);
                    try self.events.put(name, event);
                },
                .module_decl => |*module| {
                    try self.registerEventsRecursive(module.items);
                },
                else => {},
            }
        }
    }

    /// Helper: Build call graph recursively, including in modules
    fn buildCallGraphRecursive(self: *PurityChecker, items: []const ast.Item) !void {
        for (items) |*item| {
            switch (item.*) {
                .proc_decl => |*proc| {
                    const proc_name = try self.pathToString(proc.path);

                    var call_info = try CallInfo.init(self.allocator);

                    // Walk inline flows to find event invocations
                    for (proc.inline_flows) |*flow| {
                        const invoked_event = try self.pathToString(flow.invocation.path);
                        try call_info.calls.append(self.allocator, try self.allocator.dupe(u8, invoked_event));
                    }

                    try self.call_graph.put(proc_name, call_info);
                },
                .module_decl => |*module| {
                    try self.buildCallGraphRecursive(module.items);
                },
                else => {},
            }
        }
    }

    /// Helper: Recursively collect all event invocations from a flow
    fn collectFlowInvocations(self: *PurityChecker, flow: *const ast.Flow, invocations: *std.ArrayList([]const u8)) !void {
        // Add the first invocation
        const first_event = try self.pathToString(flow.invocation.path);
        try invocations.append(self.allocator, first_event);

        // Recursively walk all continuations
        for (flow.continuations) |*cont| {
            try self.collectContinuationInvocations(cont, invocations);
        }
    }

    /// Helper: Recursively collect invocations from a continuation
    fn collectContinuationInvocations(self: *PurityChecker, cont: *const ast.Continuation, invocations: *std.ArrayList([]const u8)) !void {
        // Check step if present
        if (cont.node) |*step| {
            if (step.* == .invocation) {
                const event_name = try self.pathToString(step.invocation.path);
                try invocations.append(self.allocator, event_name);
            } else if (step.* == .label_with_invocation) {
                const event_name = try self.pathToString(step.label_with_invocation.invocation.path);
                try invocations.append(self.allocator, event_name);
            }
        }

        // Recursively process nested continuations
        for (cont.continuations) |*nested_cont| {
            try self.collectContinuationInvocations(nested_cont, invocations);
        }
    }

    /// Phase 3: Propagate transitive purity via fixed-point iteration
    fn propagateTransitivePurity(self: *PurityChecker, source: *ast.Program) !void {
        var changed = true;

        while (changed) {
            changed = false;

            // Update event purity from procs each iteration
            try self.updateEventPurityFromProcs(source);

            // Check each proc and flow
            for (source.items) |*item| {
                if (item.* == .proc_decl) {
                    const proc = &item.proc_decl;

                    // Skip if already transitively pure
                    if (proc.is_transitively_pure) continue;

                    // Can only be transitively pure if locally pure
                    if (!proc.is_pure) continue;

                    // Check if all called events are transitively pure
                    const proc_name = try self.pathToString(proc.path);
                    if (self.call_graph.get(proc_name)) |call_info| {
                        var all_calls_pure = true;

                        for (call_info.calls.items) |called_event_name| {
                            // Find the called event
                            if (self.events.get(called_event_name)) |called_event| {
                                if (!called_event.is_transitively_pure) {
                                    all_calls_pure = false;
                                    break;
                                }
                            }
                        }

                        // If calls nothing OR all calls are pure, mark as transitively pure
                        if (call_info.calls.items.len == 0 or all_calls_pure) {
                            var mutable_proc = @constCast(proc);
                            mutable_proc.is_transitively_pure = true;
                            changed = true;
                        }
                    } else {
                        // No calls found - mark as transitively pure
                        var mutable_proc = @constCast(proc);
                        mutable_proc.is_transitively_pure = true;
                        changed = true;
                    }
                } else if (item.* == .flow) {
                    const flow = &item.flow;

                    // Skip if already transitively pure
                    if (flow.is_transitively_pure) continue;

                    // Flows are always locally pure (is_pure = true by default)
                    // Check if ALL invoked events are transitively pure
                    var invocations = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
                    defer {
                        for (invocations.items) |inv| {
                            self.allocator.free(inv);
                        }
                        invocations.deinit(self.allocator);
                    }

                    try self.collectFlowInvocations(flow, &invocations);

                    // Check if all invoked events are transitively pure
                    var all_pure = true;
                    for (invocations.items) |event_name| {
                        if (self.events.get(event_name)) |event| {
                            if (!event.is_transitively_pure) {
                                all_pure = false;
                                break;
                            }
                        } else {
                            // Event not found - assume impure
                            all_pure = false;
                            break;
                        }
                    }

                    if (all_pure) {
                        var mutable_flow = @constCast(flow);
                        mutable_flow.is_transitively_pure = true;
                        changed = true;
                    }
                }
            }
        }
    }

    /// Helper: Update event purity from proc implementations (used in fixed-point loop)
    fn updateEventPurityFromProcs(self: *PurityChecker, source: *ast.Program) !void {
        // For each event, find all its procs and aggregate purity
        var event_iter = self.events.iterator();

        while (event_iter.next()) |entry| {
            const event = entry.value_ptr.*;
            const event_name = entry.key_ptr.*;

            var all_procs_pure = true;
            var all_procs_trans_pure = true;
            var found_any_proc = false;

            // Find all procs for this event (including in modules)
            try self.findProcsForEvent(source.items, event_name, &all_procs_pure, &all_procs_trans_pure, &found_any_proc);

            // Set event purity based on proc implementations
            if (found_any_proc) {
                // Cast away const to mutate (safe because source is mutable)
                var mutable_event = @constCast(event);
                mutable_event.is_pure = all_procs_pure;
                mutable_event.is_transitively_pure = all_procs_trans_pure;
            }
        }
    }

    /// Helper: Find all procs for an event, recursively including modules
    fn findProcsForEvent(
        self: *PurityChecker,
        items: []const ast.Item,
        event_name: []const u8,
        all_procs_pure: *bool,
        all_procs_trans_pure: *bool,
        found_any_proc: *bool,
    ) !void {
        for (items) |*item| {
            switch (item.*) {
                .proc_decl => |*proc| {
                    const proc_name = try self.pathToString(proc.path);

                    if (std.mem.eql(u8, proc_name, event_name)) {
                        found_any_proc.* = true;

                        if (!proc.is_pure) {
                            all_procs_pure.* = false;
                        }
                        if (!proc.is_transitively_pure) {
                            all_procs_trans_pure.* = false;
                        }
                    }
                },
                .module_decl => |*module| {
                    try self.findProcsForEvent(module.items, event_name, all_procs_pure, all_procs_trans_pure, found_any_proc);
                },
                else => {},
            }
        }
    }

    /// Phase 4: Compute event purity from all proc implementations
    fn computeEventPurity(self: *PurityChecker, source: *ast.Program) !void {
        // Just call the helper (Phase 4 is now redundant, but kept for API)
        try self.updateEventPurityFromProcs(source);
    }

    /// Helper: Convert DottedPath to string (e.g., "foo.bar.baz")
    fn pathToString(self: *PurityChecker, path: ast.DottedPath) ![]const u8 {
        if (path.segments.len == 0) return "";
        if (path.segments.len == 1) return try self.allocator.dupe(u8, path.segments[0]);

        // Calculate total length
        var total_len: usize = 0;
        for (path.segments) |seg| {
            total_len += seg.len;
        }
        total_len += path.segments.len - 1; // dots

        var result = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (path.segments, 0..) |seg, i| {
            @memcpy(result[pos..][0..seg.len], seg);
            pos += seg.len;
            if (i < path.segments.len - 1) {
                result[pos] = '.';
                pos += 1;
            }
        }

        return result;
    }
};
