const std = @import("std");
const ast = @import("ast");

/// Fusion Detector - Finds chains of pure events that could be fused
///
/// This is an EXPERIMENTAL optimization pass that detects fusion opportunities:
/// - Chains of transitively pure event calls
/// - Can be fused into single optimized operations
/// - Foundation for future fusion transformation pass

pub const FusionOpportunity = struct {
    chain: [][]const u8, // Event names in the chain
    location: []const u8, // Where found (proc name)

    pub fn deinit(self: *FusionOpportunity, allocator: std.mem.Allocator) void {
        for (self.chain) |name| {
            allocator.free(name);
        }
        allocator.free(self.chain);
        allocator.free(self.location);
    }
};

pub const FusionReport = struct {
    opportunities: std.ArrayList(FusionOpportunity),
    allocator: std.mem.Allocator,
    total_chains: usize,
    total_events_in_chains: usize,

    pub fn init(allocator: std.mem.Allocator) !FusionReport {
        return .{
            .opportunities = try std.ArrayList(FusionOpportunity).initCapacity(allocator, 0),
            .allocator = allocator,
            .total_chains = 0,
            .total_events_in_chains = 0,
        };
    }

    pub fn deinit(self: *FusionReport) void {
        for (self.opportunities.items) |*opp| {
            opp.deinit(self.allocator);
        }
        self.opportunities.deinit(self.allocator);
    }
};

pub const FusionDetector = struct {
    allocator: std.mem.Allocator,
    events: std.StringHashMap(*const ast.EventDecl),

    pub fn init(allocator: std.mem.Allocator) FusionDetector {
        return .{
            .allocator = allocator,
            .events = std.StringHashMap(*const ast.EventDecl).init(allocator),
        };
    }

    pub fn deinit(self: *FusionDetector) void {
        var iter = self.events.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.events.deinit();
    }

    /// Detect fusion opportunities in the source file
    pub fn detect(self: *FusionDetector, source: *const ast.Program) !FusionReport {
        var report = try FusionReport.init(self.allocator);

        // First pass: Register all events
        for (source.items) |*item| {
            if (item.* == .event_decl) {
                const event = &item.event_decl;
                const name = try self.pathToString(event.path);
                try self.events.put(name, event);
            }
        }

        // Second pass: Look for fusion opportunities in procs
        for (source.items) |*item| {
            if (item.* == .proc_decl) {
                const proc = &item.proc_decl;

                // Analyze inline flows for fusion chains
                try self.detectInProc(proc, &report);
            }
        }

        return report;
    }

    /// Detect fusion opportunities within a proc
    fn detectInProc(self: *FusionDetector, proc: *const ast.ProcDecl, report: *FusionReport) !void {
        _ = self;
        _ = proc;
        _ = report;
        // Inline flows removed — fusion detection now only applies to top-level flows
    }

    /// Build a chain of event calls from a flow
    fn buildChain(self: *FusionDetector, flow: *const ast.Flow) ![][]const u8 {
        var chain = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);

        // Start with the invoked event
        const first_event = try self.pathToString(flow.invocation.path);
        try chain.append(self.allocator, first_event);

        // Follow continuations to build chain
        // For MVP, we just detect the starting event
        // TODO: Walk the pipeline/steps to find chained events
        // This requires understanding Step.invocation patterns

        return chain.toOwnedSlice(self.allocator);
    }

    /// Check if all events in chain are transitively pure
    fn isChainPure(self: *FusionDetector, chain: [][]const u8) !bool {
        for (chain) |event_name| {
            if (self.events.get(event_name)) |event| {
                if (!event.is_transitively_pure) {
                    return false;
                }
            } else {
                // Event not found - assume impure
                return false;
            }
        }
        return true;
    }

    /// Helper: Convert DottedPath to string
    fn pathToString(self: *FusionDetector, path: ast.DottedPath) ![]const u8 {
        if (path.segments.len == 0) return "";
        if (path.segments.len == 1) return try self.allocator.dupe(u8, path.segments[0]);

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
