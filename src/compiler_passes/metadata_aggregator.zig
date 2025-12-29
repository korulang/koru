const std = @import("std");
const ast = @import("ast");

// Import the actual analyzer modules
const purity_analyzer = @import("purity_analyzer");
const effect_analyzer = @import("effect_analyzer");

// Use their exported types  
const PurityMetadata = purity_analyzer.PurityMetadata;
const EffectMetadata = effect_analyzer.EffectMetadata;

/// Centralized metadata aggregator for all compiler passes
/// Allows queries like "tell me everything about this node"
pub const MetadataAggregator = struct {
    allocator: std.mem.Allocator,
    
    // Metadata from different passes
    purity: ?*const PurityMetadata = null,
    effects: ?*const EffectMetadata = null,
    // Future: types, resources, dataflow, etc.
    
    // Aggregated views
    node_metadata: std.StringHashMap(NodeMetadata),
    
    pub fn init(allocator: std.mem.Allocator) MetadataAggregator {
        return .{
            .allocator = allocator,
            .node_metadata = std.StringHashMap(NodeMetadata).init(allocator),
        };
    }
    
    pub fn deinit(self: *MetadataAggregator) void {
        var iter = self.node_metadata.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.node_metadata.deinit();
    }
    
    /// Add purity metadata from purity analysis pass
    pub fn addPurityMetadata(self: *MetadataAggregator, purity: *const PurityMetadata) !void {
        self.purity = purity;
        try self.aggregatePurity();
    }
    
    /// Add effect metadata from effect analysis pass
    pub fn addEffectMetadata(self: *MetadataAggregator, effects: *const EffectMetadata) !void {
        self.effects = effects;
        try self.aggregateEffects();
    }
    
    /// Get all metadata about a specific node by name
    pub fn getNodeMetadata(self: *MetadataAggregator, name: []const u8) ?*NodeMetadata {
        return self.node_metadata.getPtr(name);
    }
    
    /// Query: Is this node pure?
    pub fn isPure(self: *MetadataAggregator, name: []const u8) bool {
        if (self.getNodeMetadata(name)) |meta| {
            return meta.is_pure;
        }
        return false;
    }
    
    /// Query: What effects does this node have?
    pub fn getEffects(self: *MetadataAggregator, name: []const u8) ?[]const Effect {
        if (self.getNodeMetadata(name)) |meta| {
            return meta.effects.items;
        }
        return null;
    }
    
    /// Query: Can this node be compiled to a specific backend?
    pub fn canCompileToBackend(self: *MetadataAggregator, name: []const u8, backend: Backend) bool {
        if (self.getNodeMetadata(name)) |meta| {
            return meta.compatible_backends.contains(backend);
        }
        return false;
    }
    
    /// Generate a report of all metadata
    pub fn generateReport(self: *MetadataAggregator, writer: anytype) !void {
        try writer.print("=== METADATA AGGREGATION REPORT ===\n\n", .{});
        
        var sorted_names = std.ArrayList([]const u8).init(self.allocator);
        defer sorted_names.deinit();
        
        var iter = self.node_metadata.iterator();
        while (iter.next()) |entry| {
            try sorted_names.append(entry.key_ptr.*);
        }
        
        // Sort for consistent output
        std.mem.sort([]const u8, sorted_names.items, {}, stringLessThan);
        
        for (sorted_names.items) |name| {
            const meta = self.node_metadata.get(name).?;
            try writer.print("{s}:\n", .{name});
            try writer.print("  Type: {s}\n", .{@tagName(meta.node_type)});
            try writer.print("  Pure: {}\n", .{meta.is_pure});
            
            if (meta.effects.items.len > 0) {
                try writer.print("  Effects: ", .{});
                for (meta.effects.items, 0..) |effect, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{@tagName(effect)});
                }
                try writer.print("\n", .{});
            }
            
            if (meta.annotations.items.len > 0) {
                try writer.print("  Annotations: ", .{});
                for (meta.annotations.items, 0..) |ann, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{ann});
                }
                try writer.print("\n", .{});
            }
            
            try writer.print("  Compatible backends: ", .{});
            inline for (std.meta.fields(Backend)) |field| {
                const backend = @field(Backend, field.name);
                if (meta.compatible_backends.contains(backend)) {
                    try writer.print("{s} ", .{field.name});
                }
            }
            try writer.print("\n\n", .{});
        }
    }
    
    fn aggregatePurity(self: *MetadataAggregator) !void {
        const purity = self.purity orelse return;
        
        // Aggregate proc purity
        var proc_iter = purity.proc_purity.iterator();
        while (proc_iter.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key_ptr.*);
            const info = entry.value_ptr.*;
            
            var meta = self.node_metadata.get(name) orelse NodeMetadata.init(self.allocator);
            meta.node_type = .proc;
            meta.is_pure = info.isPure();
            meta.purity_level = if (info.syntactic_pure) .syntactic 
                               else if (info.annotated_pure) .annotated
                               else .impure;
            
            try self.node_metadata.put(name, meta);
        }
        
        // Aggregate event purity
        var event_iter = purity.event_purity.iterator();
        while (event_iter.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key_ptr.*);
            const is_pure = entry.value_ptr.*;
            
            var meta = self.node_metadata.get(name) orelse NodeMetadata.init(self.allocator);
            meta.node_type = .event;
            meta.is_pure = is_pure;
            meta.purity_level = if (is_pure) .annotated else .impure;
            
            try self.node_metadata.put(name, meta);
        }
    }
    
    fn aggregateEffects(self: *MetadataAggregator) !void {
        const effects = self.effects orelse return;
        
        // Aggregate proc effects
        var proc_iter = effects.proc_effects.iterator();
        while (proc_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const effect_set = entry.value_ptr.*;
            
            var meta = self.node_metadata.getPtr(name) orelse {
                const new_name = try self.allocator.dupe(u8, name);
                try self.node_metadata.put(new_name, NodeMetadata.init(self.allocator));
                self.node_metadata.getPtr(new_name).?;
            };
            
            // Convert effect set to list
            inline for (std.meta.fields(Effect)) |field| {
                const effect = @field(Effect, field.name);
                if (effect_set.has(effect)) {
                    try meta.effects.append(effect);
                }
            }
            
            // Update backend compatibility based on effects
            meta.updateBackendCompatibility();
        }
        
        // Aggregate event effects
        var event_iter = effects.event_effects.iterator();
        while (event_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const effect_set = entry.value_ptr.*;
            
            var meta = self.node_metadata.getPtr(name) orelse {
                const new_name = try self.allocator.dupe(u8, name);
                try self.node_metadata.put(new_name, NodeMetadata.init(self.allocator));
                self.node_metadata.getPtr(new_name).?;
            };
            
            inline for (std.meta.fields(Effect)) |field| {
                const effect = @field(Effect, field.name);
                if (effect_set.has(effect)) {
                    try meta.effects.append(effect);
                }
            }
            
            meta.updateBackendCompatibility();
        }
    }
    
    fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

/// Aggregated metadata for a single node
pub const NodeMetadata = struct {
    node_type: NodeType = .unknown,
    is_pure: bool = false,
    purity_level: PurityLevel = .unknown,
    effects: std.ArrayList(Effect),
    annotations: std.ArrayList([]const u8),
    compatible_backends: std.EnumSet(Backend),
    // Future: type info, resource usage, etc.
    
    pub fn init(allocator: std.mem.Allocator) NodeMetadata {
        return .{
            .effects = std.ArrayList(Effect).init(allocator),
            .annotations = std.ArrayList([]const u8).init(allocator),
            .compatible_backends = std.EnumSet(Backend).initFull(),
        };
    }
    
    pub fn deinit(self: *NodeMetadata, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.effects.deinit();
        self.annotations.deinit();
    }
    
    pub fn updateBackendCompatibility(self: *NodeMetadata) void {
        // Start with all backends
        self.compatible_backends = std.EnumSet(Backend).initFull();
        
        // Remove backends based on effects
        for (self.effects.items) |effect| {
            switch (effect) {
                .io => {
                    self.compatible_backends.remove(.browser);
                    self.compatible_backends.remove(.wasm_browser);
                },
                .network => {
                    // Network is OK in browser but may need special handling
                },
                .memory => {
                    // Memory management may limit some backends
                },
                .console => {
                    // Console is available everywhere but implemented differently
                },
                .process => {
                    self.compatible_backends.remove(.browser);
                    self.compatible_backends.remove(.wasm_browser);
                    self.compatible_backends.remove(.wasm_standalone);
                },
                .time => {
                    // Time is available everywhere but with different precision
                },
                .random => {
                    // Random is available everywhere
                },
                .unsafe => {
                    self.compatible_backends.remove(.browser);
                    self.compatible_backends.remove(.wasm_browser);
                    self.compatible_backends.remove(.wasm_standalone);
                },
                .extern_c => {
                    self.compatible_backends.remove(.browser);
                    self.compatible_backends.remove(.wasm_browser);
                    self.compatible_backends.remove(.js);
                    self.compatible_backends.remove(.wasm_standalone);
                },
            }
        }
    }
};

pub const NodeType = enum {
    unknown,
    event,
    proc,
    flow,
    tap,
    shape,
};

pub const PurityLevel = enum {
    unknown,
    syntactic,  // Syntactically pure (only flows)
    annotated,  // Annotated as pure
    verified,   // Verified through analysis
    impure,     // Known to be impure
};

pub const Backend = enum {
    zig,
    js,
    wasm_standalone,
    wasm_browser,
    browser,
    python,
    native,
};

// Re-export effect from effect analyzer
pub const Effect = effect_analyzer.Effect;