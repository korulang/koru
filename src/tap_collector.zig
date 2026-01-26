const std = @import("std");
const log = @import("log");
const ast = @import("ast");

/// The TapCollector gathers all Event Taps during compilation
/// and builds a registry mapping events to their observers.
/// This enables the compiler to inject tap code at transition points.
pub const TapCollector = struct {
    allocator: std.mem.Allocator,
    
    // Maps event paths to lists of taps that observe them
    output_taps: std.StringHashMap(TapList),   // Taps observing event outputs
    input_taps: std.StringHashMap(TapList),    // Taps observing event inputs
    universal_output_taps: TapList,            // * -> * output taps
    universal_input_taps: TapList,             // * -> * input taps
    
    // Track all events for wildcard resolution
    all_events: std.StringHashMap(void),
    
    // Namespace tracking for imports
    imports: std.StringHashMap(ImportInfo),
    
    const TapList = std.ArrayList(*const ast.EventTap);
    
    const ImportInfo = struct {
        path: []const u8,
        namespace: []const u8,
    };
    
    pub fn init(allocator: std.mem.Allocator) !TapCollector {
        return TapCollector{
            .allocator = allocator,
            .output_taps = std.StringHashMap(TapList).init(allocator),
            .input_taps = std.StringHashMap(TapList).init(allocator),
            .universal_output_taps = try TapList.initCapacity(allocator, 0),
            .universal_input_taps = try TapList.initCapacity(allocator, 0),
            .all_events = std.StringHashMap(void).init(allocator),
            .imports = std.StringHashMap(ImportInfo).init(allocator),
        };
    }
    
    pub fn deinit(self: *TapCollector) void {
        // Clean up tap lists
        var output_iter = self.output_taps.iterator();
        while (output_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.output_taps.deinit();
        
        var input_iter = self.input_taps.iterator();
        while (input_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.input_taps.deinit();
        
        self.universal_output_taps.deinit(self.allocator);
        self.universal_input_taps.deinit(self.allocator);
        
        // Clean up events
        var events_iter = self.all_events.iterator();
        while (events_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.all_events.deinit();
        
        // Clean up imports
        var imports_iter = self.imports.iterator();
        while (imports_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.namespace);
        }
        self.imports.deinit();
    }
    
    /// Process a source file and collect all taps
    pub fn collectFromSourceFile(self: *TapCollector, source_file: *const ast.Program) !void {
        // First pass: collect imports and events (from main file AND imported modules)
        for (source_file.items) |*item| {
            switch (item.*) {
                .import_decl => |*import| {
                    try self.registerImport(import);
                },
                .event_decl => |*event| {
                    try self.registerEvent(event);
                },
                .module_decl => |*module| {
                    // Collect events from imported modules
                    for (module.items) |*mod_item| {
                        switch (mod_item.*) {
                            .event_decl => |*event| {
                                try self.registerEvent(event);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Second pass: collect taps (from main file AND imported modules)
        for (source_file.items) |*item| {
            switch (item.*) {
                .event_tap => |*tap| {
                    try self.registerTap(tap);
                },
                .module_decl => |*module| {
                    // Collect taps from imported modules - THIS IS THE FIX!
                    for (module.items) |*mod_item| {
                        switch (mod_item.*) {
                            .event_tap => |*tap| {
                                try self.registerTap(tap);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }
    
    fn registerImport(self: *TapCollector, import: *const ast.ImportDecl) !void {
        // Extract namespace from import
        const namespace = if (import.local_name) |name|
            try self.allocator.dupe(u8, name)
        else blk: {
            // Extract from path (e.g., "std/math.kz" -> "math")
            const path = import.path;
            const last_slash = std.mem.lastIndexOf(u8, path, "/");
            const start = if (last_slash) |idx| idx + 1 else 0;
            const dot_idx = std.mem.lastIndexOf(u8, path[start..], ".");
            const end = if (dot_idx) |idx| start + idx else path.len;
            break :blk try self.allocator.dupe(u8, path[start..end]);
        };
        
        const key = try self.allocator.dupe(u8, import.path);
        try self.imports.put(key, ImportInfo{
            .path = import.path,
            .namespace = namespace,
        });
    }
    
    fn registerEvent(self: *TapCollector, event: *const ast.EventDecl) !void {
        const path_str = try self.pathToString(event.path);
        try self.all_events.put(path_str, {});
    }
    
    fn registerTap(self: *TapCollector, tap: *const ast.EventTap) !void {
        // Handle universal taps (* -> *)
        if (tap.source == null and tap.destination == null) {
            if (tap.is_input_tap) {
                try self.universal_input_taps.append(self.allocator, tap);
            } else {
                try self.universal_output_taps.append(self.allocator, tap);
            }
            return;
        }
        
        // Handle wildcard source (* -> specific)
        if (tap.source == null and tap.destination != null) {
            const dest_path = try self.pathToString(tap.destination.?);
            if (tap.is_input_tap) {
                try self.addTapToEvent(&self.input_taps, dest_path, tap);
            } else {
                // Wildcard source for output tap doesn't make sense
                // Output taps observe the OUTPUT of source going TO destination
                // So we need a specific source
                log.debug("Warning: Output tap with wildcard source is unusual\n", .{});
            }
            return;
        }
        
        // Handle wildcard destination (specific -> *)
        if (tap.source != null and tap.destination == null) {
            const src_path = try self.pathToString(tap.source.?);
            if (!tap.is_input_tap) {
                // This is the common case: observe all outputs from an event
                try self.addTapToEvent(&self.output_taps, src_path, tap);
            } else {
                // Input tap with wildcard destination doesn't make sense
                log.debug("Warning: Input tap with wildcard destination is unusual\n", .{});
            }
            return;
        }
        
        // Handle specific source and destination
        if (tap.source != null and tap.destination != null) {
            if (tap.is_input_tap) {
                // Input tap: observes inputs TO destination event
                const dest_path = try self.pathToString(tap.destination.?);
                try self.addTapToEvent(&self.input_taps, dest_path, tap);
            } else {
                // Output tap: observes outputs FROM source event
                const src_path = try self.pathToString(tap.source.?);
                try self.addTapToEvent(&self.output_taps, src_path, tap);
            }
        }
    }
    
    fn addTapToEvent(
        self: *TapCollector,
        map: *std.StringHashMap(TapList),
        event_path: []const u8,
        tap: *const ast.EventTap,
    ) !void {
        const result = try map.getOrPut(event_path);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, event_path);
            result.value_ptr.* = try TapList.initCapacity(self.allocator, 1);
        }
        try result.value_ptr.append(self.allocator, tap);
    }
    
    fn pathToString(self: *TapCollector, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        defer buf.deinit(self.allocator);

        // Include module qualifier with colon separator (matches canonical event names)
        // e.g., "main:compute" instead of just "compute"
        if (path.module_qualifier) |mq| {
            try buf.appendSlice(self.allocator, mq);
            try buf.append(self.allocator, ':');
        }

        // Add event path segments with dot separators
        for (path.segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }

        return try buf.toOwnedSlice(self.allocator);
    }
    
    /// Get all taps that observe a specific event's output
    pub fn getOutputTaps(self: *TapCollector, event_path: []const u8) []const *const ast.EventTap {
        // TODO: Also include universal taps
        if (self.output_taps.get(event_path)) |list| {
            return list.items;
        }
        return &.{};
    }
    
    /// Get all taps that observe a specific event's input
    pub fn getInputTaps(self: *TapCollector, event_path: []const u8) []const *const ast.EventTap {
        // TODO: Also include universal taps
        if (self.input_taps.get(event_path)) |list| {
            return list.items;
        }
        return &.{};
    }
    
    /// Get all universal output taps
    pub fn getUniversalOutputTaps(self: *TapCollector) []const *const ast.EventTap {
        return self.universal_output_taps.items;
    }
    
    /// Get all universal input taps
    pub fn getUniversalInputTaps(self: *TapCollector) []const *const ast.EventTap {
        return self.universal_input_taps.items;
    }
    
    /// Resolve a potentially namespaced event path
    fn resolveNamespacedPath(self: *TapCollector, path: []const u8) ![]const u8 {
        // Check if path contains a namespace prefix
        if (std.mem.indexOf(u8, path, ".")) |dot_idx| {
            const namespace = path[0..dot_idx];
            
            // Check if this matches an import namespace
            var iter = self.imports.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.namespace, namespace)) {
                    // This is a namespaced reference
                    // For now, just return the full path
                    // TODO: Properly resolve cross-module references
                    return try self.allocator.dupe(u8, path);
                }
            }
        }
        
        // Not namespaced, return as-is
        return try self.allocator.dupe(u8, path);
    }
};

// Tests
test "tap collector registers universal taps" {
    const allocator = std.testing.allocator;
    
    var collector = try TapCollector.init(allocator);
    defer collector.deinit();
    
    // Create a universal output tap (* -> *)
    const tap = try allocator.create(ast.EventTap);
    defer allocator.destroy(tap);
    tap.* = ast.EventTap{
        .source = null,
        .destination = null,
        .continuations = &.{},
        .is_input_tap = false,
    };
    
    try collector.registerTap(tap);
    
    // Should be in universal output taps
    try std.testing.expectEqual(@as(usize, 1), collector.universal_output_taps.items.len);
    try std.testing.expectEqual(tap, collector.universal_output_taps.items[0]);
}

test "tap collector registers specific event taps" {
    const allocator = std.testing.allocator;
    
    var collector = try TapCollector.init(allocator);
    defer collector.deinit();
    
    // Create a specific output tap (file.read -> *)
    var source_segments = try allocator.alloc([]const u8, 2);
    defer allocator.free(source_segments);
    source_segments[0] = try allocator.dupe(u8, "file");
    defer allocator.free(source_segments[0]);
    source_segments[1] = try allocator.dupe(u8, "read");
    defer allocator.free(source_segments[1]);
    
    const tap = try allocator.create(ast.EventTap);
    defer allocator.destroy(tap);
    tap.* = ast.EventTap{
        .source = ast.DottedPath{ .segments = source_segments },
        .destination = null,
        .continuations = &.{},
        .is_input_tap = false,
    };
    
    try collector.registerTap(tap);
    
    // Should be registered under "file.read"
    const taps = collector.getOutputTaps("file.read");
    try std.testing.expectEqual(@as(usize, 1), taps.len);
    try std.testing.expectEqual(tap, taps[0]);
}

test "tap collector handles input taps" {
    const allocator = std.testing.allocator;
    
    var collector = try TapCollector.init(allocator);
    defer collector.deinit();
    
    // Create an input tap (* -> auth.validate)
    var dest_segments = try allocator.alloc([]const u8, 2);
    defer allocator.free(dest_segments);
    dest_segments[0] = try allocator.dupe(u8, "auth");
    defer allocator.free(dest_segments[0]);
    dest_segments[1] = try allocator.dupe(u8, "validate");
    defer allocator.free(dest_segments[1]);
    
    const tap = try allocator.create(ast.EventTap);
    defer allocator.destroy(tap);
    tap.* = ast.EventTap{
        .source = null,
        .destination = ast.DottedPath{ .segments = dest_segments },
        .continuations = &.{},
        .is_input_tap = true,
    };
    
    try collector.registerTap(tap);
    
    // Should be registered as input tap for "auth.validate"
    const taps = collector.getInputTaps("auth.validate");
    try std.testing.expectEqual(@as(usize, 1), taps.len);
    try std.testing.expectEqual(tap, taps[0]);
}