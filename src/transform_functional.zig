const std = @import("std");
const ast = @import("ast");
const functional = @import("ast_functional");

/// Functional Transformation Context
/// 
/// This module provides a purely functional context for AST transformations.
/// Unlike the imperative TransformContext, this context:
/// - Never mutates the original AST
/// - Tracks transformation history
/// - Supports composition and rollback
/// - Enables safe multi-pass compilation

/// A transformation is a pure function that takes an AST and returns a new AST
pub const Transformation = fn (allocator: std.mem.Allocator, source: *const ast.Program) anyerror!ast.Program;

/// Functional transformation context
pub const FunctionalContext = struct {
    allocator: std.mem.Allocator,
    /// The original, immutable AST
    original_ast: *const ast.Program,
    /// History of all transformations applied
    transformation_history: std.ArrayList(TransformationRecord),
    /// Symbol table built from the original AST
    symbol_table: SymbolTable,
    /// Metadata about Source captures
    captures: CaptureMetadata,
    
    pub fn init(allocator: std.mem.Allocator, source_file: *const ast.Program) !FunctionalContext {
        var ctx = FunctionalContext{
            .allocator = allocator,
            .original_ast = source_file,
            .transformation_history = try std.ArrayList(TransformationRecord).initCapacity(allocator, 0),
            .symbol_table = try SymbolTable.init(allocator),
            .captures = try CaptureMetadata.init(allocator),
        };
        
        // Build symbol table and capture metadata from original AST
        try ctx.symbol_table.buildFrom(source_file);
        try ctx.captures.scanFor(source_file);
        
        return ctx;
    }
    
    pub fn deinit(self: *FunctionalContext) void {
        for (self.transformation_history.items) |*record| {
            record.deinit();
        }
        self.transformation_history.deinit(self.allocator);
        self.symbol_table.deinit();
        self.captures.deinit();
    }
    
    /// Apply a single transformation and record it in history
    pub fn apply(
        self: *FunctionalContext,
        name: []const u8,
        transform: Transformation,
    ) !ast.Program {
        // Get the current AST (either original or last transformation result)
        const current_ast = if (self.transformation_history.items.len > 0)
            &self.transformation_history.items[self.transformation_history.items.len - 1].result_ast
        else
            self.original_ast;
        
        // Apply the transformation
        const start_time = std.time.milliTimestamp();
        const result_ast = try transform(self.allocator, current_ast);
        const end_time = std.time.milliTimestamp();
        
        // Record the transformation
        try self.transformation_history.append(self.allocator, TransformationRecord{
            .name = try self.allocator.dupe(u8, name),
            .result_ast = result_ast,
            .duration_ms = @as(u32, @intCast(end_time - start_time)),
            .timestamp = std.time.timestamp(),
        });
        
        // Update symbol table and captures with new AST
        try self.symbol_table.update(&result_ast);
        try self.captures.update(&result_ast);
        
        return result_ast;
    }
    
    /// Apply multiple transformations in sequence
    pub fn applySequence(
        self: *FunctionalContext,
        transformations: []const NamedTransformation,
    ) !ast.Program {
        var result = try functional.cloneSourceFile(self.allocator, self.original_ast);
        
        for (transformations) |named_transform| {
            const new_result = try self.apply(named_transform.name, named_transform.transform);
            result.deinit(); // Clean up intermediate result
            result = new_result;
        }
        
        return result;
    }
    
    /// Get the current AST (result of all transformations)
    pub fn getCurrentAST(self: *FunctionalContext) *const ast.Program {
        if (self.transformation_history.items.len > 0) {
            return &self.transformation_history.items[self.transformation_history.items.len - 1].result_ast;
        }
        return self.original_ast;
    }
    
    /// Rollback to a specific transformation in history
    pub fn rollbackTo(self: *FunctionalContext, index: usize) !ast.Program {
        if (index >= self.transformation_history.items.len) {
            return error.InvalidRollbackIndex;
        }
        
        // Clean up transformations after the rollback point
        var i = self.transformation_history.items.len;
        while (i > index + 1) {
            i -= 1;
            var record = self.transformation_history.pop();
            record.deinit();
        }
        
        // Return a copy of the AST at the rollback point
        return try functional.cloneSourceFile(
            self.allocator,
            &self.transformation_history.items[index].result_ast,
        );
    }
    
    /// Get transformation metrics
    pub fn getMetrics(self: *FunctionalContext) TransformationMetrics {
        var total_duration: u64 = 0;
        const node_count_original: usize = countNodes(self.original_ast);
        var node_count_current: usize = node_count_original;
        
        if (self.transformation_history.items.len > 0) {
            for (self.transformation_history.items) |record| {
                total_duration += record.duration_ms;
            }
            const current = &self.transformation_history.items[self.transformation_history.items.len - 1].result_ast;
            node_count_current = countNodes(current);
        }
        
        return .{
            .transformations_applied = self.transformation_history.items.len,
            .total_duration_ms = total_duration,
            .node_count_original = node_count_original,
            .node_count_current = node_count_current,
            .source_captures = self.captures.source_count,
        };
    }
};

/// Named transformation for sequence application
pub const NamedTransformation = struct {
    name: []const u8,
    transform: Transformation,
};

/// Record of a single transformation
const TransformationRecord = struct {
    name: []const u8,
    result_ast: ast.Program,
    duration_ms: u32,
    timestamp: i64,
    
    fn deinit(self: *TransformationRecord) void {
        self.result_ast.deinit();
        // Note: name is owned by allocator, will be freed with context
    }
};

/// Metrics about transformations
pub const TransformationMetrics = struct {
    transformations_applied: usize,
    total_duration_ms: u64,
    node_count_original: usize,
    node_count_current: usize,
    source_captures: usize,
};

/// Symbol table for tracking event/proc relationships
pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    events: std.StringHashMap(EventInfo),
    procs: std.StringHashMap(ProcInfo),
    flows: std.ArrayList(FlowInfo),
    
    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        return .{
            .allocator = allocator,
            .events = std.StringHashMap(EventInfo).init(allocator),
            .procs = std.StringHashMap(ProcInfo).init(allocator),
            .flows = try std.ArrayList(FlowInfo).initCapacity(allocator, 0),
        };
    }
    
    pub fn deinit(self: *SymbolTable) void {
        // Free all keys and values
        var event_iter = self.events.iterator();
        while (event_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.events.deinit();
        
        var proc_iter = self.procs.iterator();
        while (proc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.procs.deinit();
        
        self.flows.deinit(self.allocator);
    }
    
    pub fn buildFrom(self: *SymbolTable, source_file: *const ast.Program) !void {
        // Clear existing data
        self.events.clearRetainingCapacity();
        self.procs.clearRetainingCapacity();
        self.flows.clearRetainingCapacity();
        
        // Scan the AST and build symbol table
        for (source_file.items) |*item| {
            switch (item.*) {
                .event_decl => |event| {
                    const path_str = try pathToString(self.allocator, &event.path);
                    try self.events.put(path_str, EventInfo{
                        .has_proc = false,
                        .has_subflow = false,
                        .branch_count = event.branches.len,
                        .has_source_fields = hasSourceFields(&event),
                    });
                },
                .proc_decl => |proc| {
                    const path_str = try pathToString(self.allocator, &proc.path);
                    defer self.allocator.free(path_str);

                    // Mark that this event has a proc
                    if (self.events.getPtr(path_str)) |info| {
                        info.has_proc = true;
                    }

                    const body_size = proc.body.len;
                    try self.procs.put(try self.allocator.dupe(u8, path_str), ProcInfo{
                        .body_size = body_size,
                    });
                },
                .flow => |flow| {
                    if (flow.impl_of) |impl_path| {
                        const path_str = try pathToString(self.allocator, &impl_path);
                        defer self.allocator.free(path_str);
                        if (self.events.getPtr(path_str)) |info| {
                            info.has_subflow = true;
                        }
                    } else {
                        try self.flows.append(self.allocator, FlowInfo{
                            .has_label = flow.pre_label != null or flow.post_label != null,
                            .continuation_count = flow.continuations.len,
                        });
                    }
                },
                .immediate_impl => |ii| {
                    const path_str = try pathToString(self.allocator, &ii.event_path);
                    defer self.allocator.free(path_str);
                    if (self.events.getPtr(path_str)) |info| {
                        info.has_subflow = true;
                    }
                },
                else => {},
            }
        }
    }
    
    pub fn update(self: *SymbolTable, source_file: *const ast.Program) !void {
        // For now, just rebuild from scratch
        // In the future, could do incremental updates
        try self.buildFrom(source_file);
    }
};

pub const EventInfo = struct {
    has_proc: bool,
    has_subflow: bool,
    branch_count: usize,
    has_source_fields: bool,
};

pub const ProcInfo = struct {
    body_size: usize,
};

pub const FlowInfo = struct {
    has_label: bool,
    continuation_count: usize,
};

/// Metadata about Source captures
pub const CaptureMetadata = struct {
    allocator: std.mem.Allocator,
    source_count: usize,
    source_locations: std.ArrayList(CaptureLocation),

    pub fn init(allocator: std.mem.Allocator) !CaptureMetadata {
        return .{
            .allocator = allocator,
            .source_count = 0,
            .source_locations = try std.ArrayList(CaptureLocation).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *CaptureMetadata) void {
        for (self.source_locations.items) |*loc| {
            loc.deinit(self.allocator);
        }
        self.source_locations.deinit(self.allocator);
    }

    pub fn scanFor(self: *CaptureMetadata, source_file: *const ast.Program) !void {
        self.source_count = 0;
        self.source_locations.clearRetainingCapacity();
        
        for (source_file.items) |*item| {
            switch (item.*) {
                .event_decl => |event| {
                    for (event.input.fields) |field| {
                        if (field.is_source) {
                            self.source_count += 1;
                            try self.source_locations.append(self.allocator, CaptureLocation{
                                .event_path = try pathToString(self.allocator, &event.path),
                                .field_name = try self.allocator.dupe(u8, field.name),
                            });
                        }
                    }
                },
                else => {},
            }
        }
    }
    
    pub fn update(self: *CaptureMetadata, source_file: *const ast.Program) !void {
        try self.scanFor(source_file);
    }
};

pub const CaptureLocation = struct {
    event_path: []const u8,
    field_name: []const u8,
    
    fn deinit(self: *CaptureLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.event_path);
        allocator.free(self.field_name);
    }
};

// Helper functions

fn pathToString(allocator: std.mem.Allocator, path: *const ast.DottedPath) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    for (path.segments, 0..) |segment, i| {
        if (i > 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, segment);
    }
    return try buf.toOwnedSlice(allocator);
}

fn countNodes(source_file: *const ast.Program) usize {
    var count: usize = source_file.items.len;
    
    // Count nested nodes
    for (source_file.items) |*item| {
        switch (item.*) {
            .flow => |flow| {
                count += flow.continuations.len;
                for (flow.continuations) |*cont| {
                    count += cont.pipeline.len;
                    count += cont.nested.len;
                }
            },
            .event_decl => |event| {
                count += event.branches.len;
                count += event.input.fields.len;
            },
            else => {},
        }
    }
    
    return count;
}

fn hasSourceFields(event: *const ast.EventDecl) bool {
    for (event.input.fields) |field| {
        if (field.is_source) return true;
    }
    return false;
}

/// Create a transformation that applies a function to all items
pub fn createMapTransformation(
    map_fn: fn (allocator: std.mem.Allocator, item: *const ast.Item) anyerror!ast.Item,
) Transformation {
    return struct {
        fn transform(allocator: std.mem.Allocator, source: *const ast.Program) anyerror!ast.Program {
            return functional.mapItems(allocator, source, map_fn);
        }
    }.transform;
}

/// Create a transformation that filters items
pub fn createFilterTransformation(
    predicate: fn (item: *const ast.Item) bool,
) Transformation {
    return struct {
        fn transform(allocator: std.mem.Allocator, source: *const ast.Program) anyerror!ast.Program {
            return functional.filterItems(allocator, source, predicate);
        }
    }.transform;
}

/// Create a transformation that replaces specific items
pub fn createReplaceTransformation(
    should_replace: fn (item: *const ast.Item) bool,
    replacement: fn (allocator: std.mem.Allocator, item: *const ast.Item) anyerror!ast.Item,
) Transformation {
    return struct {
        fn transform(allocator: std.mem.Allocator, source: *const ast.Program) anyerror!ast.Program {
            return functional.transformWhere(allocator, source, should_replace, replacement);
        }
    }.transform;
}