const std = @import("std");
const ast = @import("ast");

/// Purity metadata produced by this compiler pass
pub const PurityMetadata = struct {
    /// Maps proc names to their purity analysis
    proc_purity: std.StringHashMap(PurityInfo),
    /// Maps event names to their purity (from annotations)
    event_purity: std.StringHashMap(bool),
    /// The call graph for reference by other passes
    call_graph: std.StringHashMap([]const []const u8),

    pub fn init(allocator: std.mem.Allocator) PurityMetadata {
        return .{
            .proc_purity = std.StringHashMap(PurityInfo).init(allocator),
            .event_purity = std.StringHashMap(bool).init(allocator),
            .call_graph = std.StringHashMap([]const []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PurityMetadata, allocator: std.mem.Allocator) void {
        var proc_iter = self.proc_purity.iterator();
        while (proc_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.proc_purity.deinit();

        var event_iter = self.event_purity.iterator();
        while (event_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.event_purity.deinit();

        var call_iter = self.call_graph.iterator();
        while (call_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |call| {
                allocator.free(call);
            }
            allocator.free(entry.value_ptr.*);
        }
        self.call_graph.deinit();
    }
};

pub const PurityInfo = struct {
    annotated_pure: bool, // Has [pure] annotation - developer assertion
    transitive_pure: bool, // All called procs/events are also pure

    /// Final purity decision: pure only if annotated [pure]
    /// Transitive purity is informational only
    pub fn isPure(self: PurityInfo) bool {
        return self.annotated_pure;
    }
};

/// Purity Analysis Compiler Pass
///
/// Simple rule: [pure] annotation = pure, otherwise = impure
///
/// We don't try to analyze host (Zig) code. If you want purity,
/// annotate with [pure]. This is a developer assertion that we trust.
///
/// This pass DOES NOT modify the AST - it produces metadata!
pub const PurityAnalyzer = struct {
    allocator: std.mem.Allocator,
    source_file: *const ast.Program,

    // Maps proc/event names to their declarations
    proc_map: std.StringHashMap(*const ast.ProcDecl),
    event_map: std.StringHashMap(*const ast.EventDecl),

    // Track what each proc calls
    call_graph: std.StringHashMap(CallInfo),

    // Track cycles to prevent infinite recursion
    visiting: std.StringHashMap(void),
    visited: std.StringHashMap(bool), // Maps to final purity result

    const CallInfo = struct {
        calls: std.ArrayList([]const u8), // List of proc/event names this proc calls
    };

    pub fn init(allocator: std.mem.Allocator, source_file: *const ast.Program) !PurityAnalyzer {
        var analyzer = PurityAnalyzer{
            .allocator = allocator,
            .source_file = source_file,
            .proc_map = std.StringHashMap(*const ast.ProcDecl).init(allocator),
            .event_map = std.StringHashMap(*const ast.EventDecl).init(allocator),
            .call_graph = std.StringHashMap(CallInfo).init(allocator),
            .visiting = std.StringHashMap(void).init(allocator),
            .visited = std.StringHashMap(bool).init(allocator),
        };

        // Build the proc and event maps
        for (source_file.items) |*item| {
            switch (item.*) {
                .proc_decl => |*proc| {
                    const name = try pathToString(allocator, proc.path);
                    try analyzer.proc_map.put(name, proc);
                },
                .event_decl => |*event| {
                    const name = try pathToString(allocator, event.path);
                    try analyzer.event_map.put(name, event);
                },
                else => {},
            }
        }

        return analyzer;
    }

    pub fn deinit(self: *PurityAnalyzer) void {
        // Free all the allocated names
        var proc_iter = self.proc_map.iterator();
        while (proc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.proc_map.deinit();

        var event_iter = self.event_map.iterator();
        while (event_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.event_map.deinit();

        var call_iter = self.call_graph.iterator();
        while (call_iter.next()) |entry| {
            entry.value_ptr.calls.deinit(self.allocator);
        }
        self.call_graph.deinit();

        self.visiting.deinit();
        self.visited.deinit();
    }

    /// Analyzes all procs for purity and returns metadata
    /// This is the main entry point for the compiler pass
    pub fn analyze(self: *PurityAnalyzer) !PurityMetadata {
        var metadata = PurityMetadata.init(self.allocator);
        errdefer metadata.deinit(self.allocator);

        // Build call graphs and analyze purity
        var proc_iter = self.proc_map.iterator();
        while (proc_iter.next()) |entry| {
            const proc_name = entry.key_ptr.*;
            const proc = entry.value_ptr.*;

            var call_info = CallInfo{
                .calls = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch unreachable,
            };

            try self.call_graph.put(proc_name, call_info);
        }

        // Analyze each proc
        proc_iter = self.proc_map.iterator();
        while (proc_iter.next()) |entry| {
            const proc_name = entry.key_ptr.*;
            const proc = entry.value_ptr.*;

            const is_annotated_pure = proc.is_pure;
            const is_transitively_pure = try self.checkTransitivePurity(proc_name);

            // Store in metadata
            const key = try self.allocator.dupe(u8, proc_name);
            try metadata.proc_purity.put(key, PurityInfo{
                .annotated_pure = is_annotated_pure,
                .transitive_pure = is_transitively_pure,
            });
        }

        return metadata;
    }

    fn extractCallsFromFlow(self: *PurityAnalyzer, flow: *const ast.Flow, call_info: *CallInfo) !void {
        // Extract the invocation
        const invocation_name = try pathToString(self.allocator, flow.invocation.path);
        defer self.allocator.free(invocation_name);
        try call_info.calls.append(self.allocator, try self.allocator.dupe(u8, invocation_name));

        // Recursively extract from continuations
        for (flow.continuations) |*cont| {
            try self.extractCallsFromContinuation(cont, call_info);
        }
    }

    fn extractCallsFromContinuation(self: *PurityAnalyzer, cont: *const ast.Continuation, call_info: *CallInfo) !void {
        // Extract from the step if present
        if (cont.node) |step| {
            switch (step) {
                .invocation => |inv| {
                    const inv_name = try pathToString(self.allocator, inv.path);
                    defer self.allocator.free(inv_name);
                    try call_info.calls.append(self.allocator, try self.allocator.dupe(u8, inv_name));
                },
                else => {}, // Skip other step types for now
            }
        }

        // Recursively handle nested continuations
        for (cont.continuations) |*nested| {
            try self.extractCallsFromContinuation(nested, call_info);
        }
    }

    fn checkTransitivePurity(self: *PurityAnalyzer, proc_name: []const u8) !bool {
        // Check if already computed
        if (self.visited.get(proc_name)) |is_pure| {
            return is_pure;
        }

        // Check for cycles - assume pure for cycles (optimistic)
        if (self.visiting.contains(proc_name)) {
            return true;
        }

        // Mark as visiting
        try self.visiting.put(proc_name, {});
        defer _ = self.visiting.remove(proc_name);

        // Get the proc
        const proc = self.proc_map.get(proc_name) orelse {
            return false; // Unknown proc, assume impure
        };

        // Check annotation - [pure] means pure
        if (proc.is_pure) {
            try self.visited.put(proc_name, true);
            return true;
        }

        // No [pure] annotation = impure
        try self.visited.put(proc_name, false);
        return false;
    }

    fn pathToString(allocator: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer buf.deinit(allocator);
        for (path.segments, 0..) |seg, i| {
            if (i > 0) try buf.append(allocator, '.');
            try buf.appendSlice(allocator, seg);
        }
        return try allocator.dupe(u8, buf.items);
    }
};
