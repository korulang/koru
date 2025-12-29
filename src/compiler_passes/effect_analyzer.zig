const std = @import("std");
const ast = @import("ast");
const purity_helpers = @import("purity_helpers.zig");

/// Effect types that can be tracked
pub const Effect = enum {
    io,       // File system operations
    network,  // Network operations
    memory,   // Heap allocations
    console,  // Console I/O
    process,  // Process spawning
    time,     // Time/clock access
    random,   // Random number generation
    unsafe,   // Unsafe pointer operations
    extern_c, // Foreign function calls
    
    pub fn fromString(s: []const u8) ?Effect {
        if (std.mem.eql(u8, s, "io")) return .io;
        if (std.mem.eql(u8, s, "network")) return .network;
        if (std.mem.eql(u8, s, "memory")) return .memory;
        if (std.mem.eql(u8, s, "console")) return .console;
        if (std.mem.eql(u8, s, "process")) return .process;
        if (std.mem.eql(u8, s, "time")) return .time;
        if (std.mem.eql(u8, s, "random")) return .random;
        if (std.mem.eql(u8, s, "unsafe")) return .unsafe;
        if (std.mem.eql(u8, s, "extern_c")) return .extern_c;
        return null;
    }
};

/// Metadata produced by the effect analysis pass
pub const EffectMetadata = struct {
    /// Maps proc/event names to their effects
    proc_effects: std.StringHashMap(EffectSet),
    event_effects: std.StringHashMap(EffectSet),
    /// Whether effects have been verified vs just declared
    verified: std.StringHashMap(bool),
    
    pub fn init(allocator: std.mem.Allocator) EffectMetadata {
        return .{
            .proc_effects = std.StringHashMap(EffectSet).init(allocator),
            .event_effects = std.StringHashMap(EffectSet).init(allocator),
            .verified = std.StringHashMap(bool).init(allocator),
        };
    }
    
    pub fn deinit(self: *EffectMetadata, allocator: std.mem.Allocator) void {
        var proc_iter = self.proc_effects.iterator();
        while (proc_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.proc_effects.deinit();
        
        var event_iter = self.event_effects.iterator();
        while (event_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.event_effects.deinit();
        
        var verified_iter = self.verified.iterator();
        while (verified_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.verified.deinit();
    }
};

pub const EffectSet = struct {
    effects: std.EnumSet(Effect),
    
    pub fn init() EffectSet {
        return .{ .effects = std.EnumSet(Effect).initEmpty() };
    }
    
    pub fn deinit(self: *EffectSet) void {
        _ = self; // Nothing to free for EnumSet
    }
    
    pub fn add(self: *EffectSet, effect: Effect) void {
        self.effects.insert(effect);
    }
    
    pub fn has(self: EffectSet, effect: Effect) bool {
        return self.effects.contains(effect);
    }
    
    pub fn isEmpty(self: EffectSet) bool {
        return self.effects.count() == 0;
    }
    
    pub fn merge(self: *EffectSet, other: EffectSet) void {
        self.effects = self.effects.unionWith(other.effects);
    }
};

/// Effect Analysis Compiler Pass
/// Tracks what effects each proc/event has based on:
/// 1. Annotations like [effects(io|network)]
/// 2. Analysis of called functions (future work)
/// 3. Transitive propagation through call graph
pub const EffectAnalyzer = struct {
    allocator: std.mem.Allocator,
    source_file: *ast.Program,
    purity_metadata: ?*const PurityMetadata, // Optional purity data from previous pass
    
    pub fn init(
        allocator: std.mem.Allocator,
        source_file: *ast.Program,
        purity_metadata: ?*const PurityMetadata,
    ) EffectAnalyzer {
        return .{
            .allocator = allocator,
            .source_file = source_file,
            .purity_metadata = purity_metadata,
        };
    }
    
    /// Main entry point - analyzes effects and returns metadata
    pub fn analyze(self: *EffectAnalyzer) !EffectMetadata {
        var metadata = EffectMetadata.init(self.allocator);
        errdefer metadata.deinit(self.allocator);
        
        std.debug.print("\n=== EFFECT ANALYSIS PASS ===\n", .{});
        
        // Process all procs and events
        for (self.source_file.items) |*item| {
            switch (item.*) {
                .proc_decl => |*proc| {
                    const effects = try self.analyzeProcEffects(proc);
                    const name = try purity_helpers.pathToString(self.allocator, proc.path);
                    try metadata.proc_effects.put(name, effects);
                    
                    // If it's pure (from purity pass), it should have no effects
                    if (self.purity_metadata) |purity| {
                        if (purity.proc_purity.get(name)) |purity_info| {
                            if (purity_info.isPure() and !effects.isEmpty()) {
                                std.debug.print("WARNING: Proc '{s}' marked pure but has effects!\n", .{name});
                            }
                        }
                    }
                },
                .event_decl => |*event| {
                    const effects = try self.analyzeEventEffects(event);
                    const name = try purity_helpers.pathToString(self.allocator, event.path);
                    try metadata.event_effects.put(name, effects);
                },
                else => {},
            }
        }
        
        return metadata;
    }
    
    fn analyzeProcEffects(self: *EffectAnalyzer, proc: *const ast.ProcDecl) !EffectSet {
        var effects = EffectSet.init();
        
        // Parse effects from annotations
        for (proc.annotations) |ann| {
            // Look for effects(...) annotation
            if (std.mem.startsWith(u8, ann, "effects(") and std.mem.endsWith(u8, ann, ")")) {
                const effects_str = ann[8..ann.len - 1]; // Extract content between effects()
                var iter = std.mem.splitScalar(u8, effects_str, '|');
                while (iter.next()) |effect_str| {
                    const trimmed = std.mem.trim(u8, effect_str, " \t");
                    if (Effect.fromString(trimmed)) |effect| {
                        effects.add(effect);
                    }
                }
            }
            
            // extern_c implies extern_c effect
            if (std.mem.eql(u8, ann, "extern_c")) {
                effects.add(.extern_c);
            }
        }
        
        // TODO: Analyze body for actual effects (stdlib calls, etc.)
        // For now, just trust annotations
        
        const name = try purity_helpers.pathToString(self.allocator, proc.path);
        defer self.allocator.free(name);
        
        if (!effects.isEmpty()) {
            std.debug.print("Proc '{s}' has effects: ", .{name});
            inline for (std.meta.fields(Effect)) |field| {
                const effect = @field(Effect, field.name);
                if (effects.has(effect)) {
                    std.debug.print("{s} ", .{field.name});
                }
            }
            std.debug.print("\n", .{});
        }
        
        return effects;
    }
    
    fn analyzeEventEffects(self: *EffectAnalyzer, event: *const ast.EventDecl) !EffectSet {
        _ = self;
        var effects = EffectSet.init();
        
        // Parse effects from annotations (same as procs)
        for (event.annotations) |ann| {
            if (std.mem.startsWith(u8, ann, "effects(") and std.mem.endsWith(u8, ann, ")")) {
                const effects_str = ann[8..ann.len - 1];
                var iter = std.mem.splitScalar(u8, effects_str, '|');
                while (iter.next()) |effect_str| {
                    const trimmed = std.mem.trim(u8, effect_str, " \t");
                    if (Effect.fromString(trimmed)) |effect| {
                        effects.add(effect);
                    }
                }
            }
            
            if (std.mem.eql(u8, ann, "extern_c")) {
                effects.add(.extern_c);
            }
        }
        
        return effects;
    }
};

// PurityMetadata type definition (duplicated to avoid circular import)
pub const PurityMetadata = struct {
    proc_purity: std.StringHashMap(PurityInfo),
    event_purity: std.StringHashMap(bool),
    call_graph: std.StringHashMap([]const []const u8),
    
    pub fn deinit(self: *const PurityMetadata, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Const version for read-only access - actual deallocation handled by owner
    }
};

pub const PurityInfo = struct {
    syntactic_pure: bool,
    annotated_pure: bool,
    
    pub fn isPure(self: PurityInfo) bool {
        return self.syntactic_pure or self.annotated_pure;
    }
};