// Transform Collector for Two-Layer AST Transformation System
// This module collects and manages AST transformations from multiple comptime procs

const std = @import("std");
const ast = @import("ast");

/// Collects AST transformations from multiple sources
pub const TransformCollector = struct {
    allocator: std.mem.Allocator,
    transforms: std.ArrayList(Transform),
    
    const Transform = struct {
        source: []const u8,  // Name/path of the transform source
        priority: i32,       // Priority for ordering (higher = later)
        new_ast: ?ast.Program,  // The transformed AST (null = no change)
        metadata: TransformMetadata,
    };
    
    const TransformMetadata = struct {
        items_added: usize = 0,
        items_removed: usize = 0,
        items_modified: usize = 0,
        timestamp: i64 = 0,
    };
    
    pub fn init(allocator: std.mem.Allocator) TransformCollector {
        return .{
            .allocator = allocator,
            .transforms = std.ArrayList(Transform).init(allocator),
        };
    }
    
    pub fn deinit(self: *TransformCollector) void {
        for (self.transforms.items) |*transform| {
            if (transform.new_ast) |*transformed_ast| {
                transformed_ast.deinit();
            }
            self.allocator.free(transform.source);
        }
        self.transforms.deinit();
    }
    
    /// Register a transformation from a comptime proc
    pub fn register(
        self: *TransformCollector,
        source: []const u8,
        priority: i32,
        new_ast: ?ast.Program,
    ) !void {
        const metadata = if (new_ast) |transformed| blk: {
            // Calculate basic metadata about the transformation
            // In a real implementation, we'd compare against the original
            break :blk TransformMetadata{
                .items_added = 0,  // TODO: Calculate actual changes
                .items_removed = 0,
                .items_modified = transformed.items.len,
                .timestamp = std.time.timestamp(),
            };
        } else TransformMetadata{};
        
        try self.transforms.append(.{
            .source = try self.allocator.dupe(u8, source),
            .priority = priority,
            .new_ast = new_ast,
            .metadata = metadata,
        });
    }
    
    /// Compose all transformations into a single AST
    /// Applies transforms in priority order
    pub fn compose(self: *TransformCollector, base_ast: *const ast.Program) !ast.Program {
        // Sort by priority
        std.sort.sort(Transform, self.transforms.items, {}, comparePriority);
        
        // Start with a copy of the base AST
        const ast_functional = @import("ast_functional");
        var result = try ast_functional.cloneSourceFile(self.allocator, base_ast);
        errdefer result.deinit();
        
        // Apply each transformation in order
        for (self.transforms.items) |transform| {
            if (transform.new_ast) |transformed| {
                // Replace the current result with the transformed AST
                // In a real implementation, we might merge instead of replace
                result.deinit();
                result = try ast_functional.cloneSourceFile(self.allocator, &transformed);
            }
        }
        
        return result;
    }
    
    /// Merge multiple ASTs intelligently
    /// This is a more sophisticated composition that can handle conflicts
    pub fn merge(
        self: *TransformCollector,
        base_ast: *const ast.Program,
        strategy: MergeStrategy,
    ) !ast.Program {
        // Sort by priority
        std.sort.sort(Transform, self.transforms.items, {}, comparePriority);
        
        const ast_functional = @import("ast_functional");
        var result = try ast_functional.cloneSourceFile(self.allocator, base_ast);
        errdefer result.deinit();
        
        for (self.transforms.items) |transform| {
            if (transform.new_ast) |transformed| {
                result = try mergeASTs(self.allocator, &result, &transformed, strategy);
            }
        }
        
        return result;
    }
    
    fn comparePriority(context: void, a: Transform, b: Transform) bool {
        _ = context;
        return a.priority < b.priority;
    }
    
    /// Get statistics about collected transforms
    pub fn getStats(self: *TransformCollector) TransformStats {
        var stats = TransformStats{};
        
        for (self.transforms.items) |transform| {
            stats.total_transforms += 1;
            if (transform.new_ast != null) {
                stats.active_transforms += 1;
            }
            stats.total_items_added += transform.metadata.items_added;
            stats.total_items_removed += transform.metadata.items_removed;
            stats.total_items_modified += transform.metadata.items_modified;
        }
        
        return stats;
    }
    
    pub const TransformStats = struct {
        total_transforms: usize = 0,
        active_transforms: usize = 0,  // Transforms that actually change the AST
        total_items_added: usize = 0,
        total_items_removed: usize = 0,
        total_items_modified: usize = 0,
    };
    
    pub const MergeStrategy = enum {
        replace,        // Later transforms completely replace earlier ones
        append,         // Add new items without replacing
        smart_merge,    // Intelligently merge based on item types
        conflict_error, // Error on conflicts
    };
};

/// Merge two ASTs according to a strategy
fn mergeASTs(
    allocator: std.mem.Allocator,
    base: *const ast.Program,
    transform: *const ast.Program,
    strategy: TransformCollector.MergeStrategy,
) !ast.Program {
    const ast_functional = @import("ast_functional");
    
    switch (strategy) {
        .replace => {
            // Simple replacement - use the transform AST
            return try ast_functional.cloneSourceFile(allocator, transform);
        },
        .append => {
            // Append transform items to base
            var items = try std.ArrayList(ast.Item).initCapacity(
                allocator,
                base.items.len + transform.items.len
            );
            defer items.deinit();
            
            // Copy base items
            for (base.items) |*item| {
                try items.append(try ast_functional.cloneItem(allocator, item));
            }
            
            // Append transform items
            for (transform.items) |*item| {
                try items.append(try ast_functional.cloneItem(allocator, item));
            }
            
            return ast.Program{
                .items = try items.toOwnedSlice(),
                .allocator = allocator,
            };
        },
        .smart_merge => {
            // Intelligent merging based on item types and paths
            // This is a simplified implementation
            var result_items = std.StringHashMap(ast.Item).init(allocator);
            defer result_items.deinit();
            
            // Add base items with keys
            for (base.items) |*item| {
                const key = try getItemKey(allocator, item);
                defer allocator.free(key);
                try result_items.put(key, try ast_functional.cloneItem(allocator, item));
            }
            
            // Override or add transform items
            for (transform.items) |*item| {
                const key = try getItemKey(allocator, item);
                defer allocator.free(key);
                
                // Replace if exists, otherwise add
                try result_items.put(key, try ast_functional.cloneItem(allocator, item));
            }
            
            // Convert back to array
            var items = try std.ArrayList(ast.Item).initCapacity(allocator, result_items.count());
            defer items.deinit();
            
            var iter = result_items.iterator();
            while (iter.next()) |entry| {
                try items.append(entry.value_ptr.*);
            }
            
            return ast.Program{
                .items = try items.toOwnedSlice(),
                .allocator = allocator,
            };
        },
        .conflict_error => {
            // Check for conflicts and error if found
            for (transform.items) |*t_item| {
                for (base.items) |*b_item| {
                    if (try itemsConflict(b_item, t_item)) {
                        return error.MergeConflict;
                    }
                }
            }
            
            // No conflicts, append
            return mergeASTs(allocator, base, transform, .append);
        },
    }
}

/// Generate a unique key for an AST item for merging
fn getItemKey(allocator: std.mem.Allocator, item: *const ast.Item) ![]u8 {
    switch (item.*) {
        .event_decl => |event| {
            return try std.fmt.allocPrint(allocator, "event:{s}", .{
                try pathToString(allocator, &event.path),
            });
        },
        .proc_decl => |proc| {
            return try std.fmt.allocPrint(allocator, "proc:{s}", .{
                try pathToString(allocator, &proc.path),
            });
        },
        .flow => |flow| {
            return try std.fmt.allocPrint(allocator, "flow:{s}", .{
                try pathToString(allocator, &flow.invocation.path),
            });
        },
        .label_decl => |label| {
            return try std.fmt.allocPrint(allocator, "label:{s}", .{label.name});
        },
        .immediate_impl => |ii| {
            return try std.fmt.allocPrint(allocator, "immediate_impl:{s}", .{
                try pathToString(allocator, &ii.event_path),
            });
        },
        .import_decl => |import| {
            return try std.fmt.allocPrint(allocator, "import:{s}", .{import.path});
        },
        .host_line => |line| {
            // Use hash for host lines since they don't have unique identifiers
            const hash = std.hash.Wyhash.hash(0, line);
            return try std.fmt.allocPrint(allocator, "host:{x}", .{hash});
        },
    }
}

/// Convert a dotted path to a string
fn pathToString(allocator: std.mem.Allocator, path: *const ast.DottedPath) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    for (path.segments, 0..) |segment, i| {
        if (i > 0) try result.append('.');
        try result.appendSlice(segment);
    }
    
    return try result.toOwnedSlice();
}

/// Check if two items conflict (simplified)
fn itemsConflict(a: *const ast.Item, b: *const ast.Item) !bool {
    // Items conflict if they're the same type with the same path/name
    if (@intFromEnum(a.*) != @intFromEnum(b.*)) return false;
    
    switch (a.*) {
        .event_decl => |a_event| {
            const b_event = b.event_decl;
            return pathsEqual(&a_event.path, &b_event.path);
        },
        .proc_decl => |a_proc| {
            const b_proc = b.proc_decl;
            return pathsEqual(&a_proc.path, &b_proc.path);
        },
        .label_decl => |a_label| {
            const b_label = b.label_decl;
            return std.mem.eql(u8, a_label.name, b_label.name);
        },
        .immediate_impl => |a_ii| {
            const b_ii = b.immediate_impl;
            return pathsEqual(&a_ii.event_path, &b_ii.event_path);
        },
        else => return false,  // Other items don't conflict
    }
}

/// Check if two paths are equal
fn pathsEqual(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
    if (a.segments.len != b.segments.len) return false;
    
    for (a.segments, b.segments) |a_seg, b_seg| {
        if (!std.mem.eql(u8, a_seg, b_seg)) return false;
    }
    
    return true;
}

// Tests
test "TransformCollector init and deinit" {
    var collector = TransformCollector.init(std.testing.allocator);
    defer collector.deinit();
    
    try std.testing.expect(collector.transforms.items.len == 0);
}

test "TransformCollector register and stats" {
    var collector = TransformCollector.init(std.testing.allocator);
    defer collector.deinit();
    
    // Register a null transform (no change)
    try collector.register("test.transform1", 10, null);
    
    // Register an active transform (with AST)
    // For testing, we'll pass null but in reality this would be an AST
    try collector.register("test.transform2", 20, null);
    
    const stats = collector.getStats();
    try std.testing.expect(stats.total_transforms == 2);
    try std.testing.expect(stats.active_transforms == 0);  // Both are null in this test
}