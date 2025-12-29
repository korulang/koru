const std = @import("std");
const ast = @import("ast");

/// Collects branch constructors from inline flow continuations and builds union type information
pub const UnionCollector = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) UnionCollector {
        return UnionCollector{ .allocator = allocator };
    }
    
    /// Result of collecting branches from an inline flow
    pub const CollectionResult = struct {
        super_shape: ast.SuperShape,
        has_conflicts: bool,
        conflicts: []const Conflict,
        
        pub const Conflict = struct {
            branch_name: []const u8,
            shapes: []const ast.Shape,
            locations: []const usize, // Line numbers where the conflicts occur
        };
        
        /// Transfer ownership of super_shape and return it, leaving it null in self
        pub fn transferSuperShape(self: *CollectionResult) ?ast.SuperShape {
            if (self.super_shape.branches.len > 0) {
                const shape = self.super_shape;
                // Clear our reference to indicate ownership transferred
                self.super_shape = .{ .branches = &[_]ast.SuperShape.BranchVariant{} };
                return shape;
            }
            return null;
        }
        
        pub fn deinit(self: *CollectionResult, allocator: std.mem.Allocator) void {
            // Clean up super_shape only if we still own it
            if (self.super_shape.branches.len > 0) {
                for (self.super_shape.branches) |*branch| {
                    allocator.free(branch.name);
                    var mutable_payload = branch.payload;
                    mutable_payload.deinit(allocator);
                    for (branch.sources) |source| {
                        var mutable_source = source;
                        mutable_source.deinit(allocator);
                    }
                    allocator.free(branch.sources);
                }
                allocator.free(self.super_shape.branches);
            }
            
            // Clean up conflicts
            for (self.conflicts) |*conflict| {
                allocator.free(conflict.branch_name);
                for (conflict.shapes) |shape| {
                    var mutable_shape = shape;
                    mutable_shape.deinit(allocator);
                }
                allocator.free(conflict.shapes);
                allocator.free(conflict.locations);
            }
            allocator.free(self.conflicts);
        }
    };
    
    /// Collect all branch constructors from flow continuations
    pub fn collectFromFlow(self: *UnionCollector, flow: *const ast.Flow) !CollectionResult {
        var branch_map = std.StringHashMap(BranchInfo).init(self.allocator);
        defer branch_map.deinit();
        
        // Collect all branch constructors from continuations
        try self.collectFromContinuations(flow.continuations, &branch_map);
        
        // Check for conflicts and build SuperShape
        return try self.buildResult(&branch_map);
    }
    
    const BranchInfo = struct {
        shapes: std.ArrayList(ast.Shape),
        locations: std.ArrayList(usize),
        
        pub fn deinit(self: *BranchInfo, allocator: std.mem.Allocator) void {
            for (self.shapes.items) |*shape| {
                shape.deinit(allocator);
            }
            self.shapes.deinit(allocator);
            self.locations.deinit(allocator);
        }
    };
    
    fn collectFromContinuations(
        self: *UnionCollector, 
        continuations: []const ast.Continuation,
        branch_map: *std.StringHashMap(BranchInfo)
    ) !void {
        for (continuations) |cont| {
            // Process node if present
            if (cont.node) |n| {
                if (n == .branch_constructor) {
                    const bc = n.branch_constructor;

                    // Convert fields to Shape
                    const shape = try self.fieldsToShape(bc.fields);

                    // Add to branch map
                    const result = try branch_map.getOrPut(bc.branch_name);
                    if (!result.found_existing) {
                        result.value_ptr.* = BranchInfo{
                            .shapes = try std.ArrayList(ast.Shape).initCapacity(self.allocator, 0),
                            .locations = try std.ArrayList(usize).initCapacity(self.allocator, 0),
                        };
                    }

                    try result.value_ptr.shapes.append(self.allocator, shape);
                    try result.value_ptr.locations.append(self.allocator, 0); // TODO: Add actual line numbers
                }
            }

            // Recursively process nested continuations
            if (cont.continuations.len > 0) {
                try self.collectFromContinuations(cont.continuations, branch_map);
            }
        }
    }
    
    fn fieldsToShape(self: *UnionCollector, fields: []const ast.Field) !ast.Shape {
        var shape_fields = try std.ArrayList(ast.Field).initCapacity(self.allocator, fields.len);
        errdefer {
            for (shape_fields.items) |*field| field.deinit(self.allocator);
            shape_fields.deinit(self.allocator);
        }
        
        for (fields) |field| {
            // Clone the field for the shape
            const new_field = ast.Field{
                .name = try self.allocator.dupe(u8, field.name),
                .type = if (field.expression != null)
                    try self.allocator.dupe(u8, "auto") // Type will be inferred from expression
                else
                    try self.allocator.dupe(u8, field.type),
                .phantom = if (field.phantom) |p| try self.allocator.dupe(u8, p) else null,
                .expression = field.expression, // Reference same expression AST (not owned)
                .expression_str = if (field.expression_str) |s| try self.allocator.dupe(u8, s) else null,
                .owns_expression = false, // We don't own the expression, just reference it
            };
            shape_fields.appendAssumeCapacity(new_field);
        }
        
        return ast.Shape{
            .fields = try shape_fields.toOwnedSlice(self.allocator),
        };
    }
    
    fn buildResult(self: *UnionCollector, branch_map: *std.StringHashMap(BranchInfo)) !CollectionResult {
        var branches = try std.ArrayList(ast.SuperShape.BranchVariant).initCapacity(
            self.allocator, 
            branch_map.count()
        );
        errdefer {
            for (branches.items) |*branch| {
                self.allocator.free(branch.name);
                var mutable_payload = branch.payload;
                mutable_payload.deinit(self.allocator);
                for (branch.sources) |source| {
                    var mutable_source = source;
                    mutable_source.deinit(self.allocator);
                }
                self.allocator.free(branch.sources);
            }
            branches.deinit(self.allocator);
        }
        
        var conflicts = try std.ArrayList(CollectionResult.Conflict).initCapacity(self.allocator, 0);
        errdefer {
            for (conflicts.items) |*conflict| {
                self.allocator.free(conflict.branch_name);
                for (conflict.shapes) |shape| {
                    var mutable_shape = shape;
                    mutable_shape.deinit(self.allocator);
                }
                self.allocator.free(conflict.shapes);
                self.allocator.free(conflict.locations);
            }
            conflicts.deinit(self.allocator);
        }
        
        // Process each branch
        var iter = branch_map.iterator();
        while (iter.next()) |entry| {
            const branch_name = entry.key_ptr.*;
            const info = entry.value_ptr.*;
            
            // Check if all shapes for this branch are equal
            if (info.shapes.items.len > 1) {
                const first_shape = &info.shapes.items[0];
                var all_equal = true;
                
                for (info.shapes.items[1..]) |*shape| {
                    if (!shapesEqual(first_shape, shape)) {
                        all_equal = false;
                        break;
                    }
                }
                
                if (!all_equal) {
                    // We have a conflict!
                    var conflict_shapes = try self.allocator.alloc(ast.Shape, info.shapes.items.len);
                    for (info.shapes.items, 0..) |shape, i| {
                        conflict_shapes[i] = try cloneShape(self.allocator, &shape);
                    }
                    
                    try conflicts.append(self.allocator, .{
                        .branch_name = try self.allocator.dupe(u8, branch_name),
                        .shapes = conflict_shapes,
                        .locations = try self.allocator.dupe(usize, info.locations.items),
                    });
                }
            }
            
            // Add the branch variant (use first shape as representative)
            if (info.shapes.items.len > 0) {
                var sources = try self.allocator.alloc(ast.DottedPath, 1);
                sources[0] = ast.DottedPath{ .module_qualifier = null, .segments = &[_][]const u8{} };
                
                try branches.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, branch_name),
                    .payload = try cloneShape(self.allocator, &info.shapes.items[0]),
                    .sources = sources,
                });
            }
        }
        
        return CollectionResult{
            .super_shape = .{
                .branches = try branches.toOwnedSlice(self.allocator),
            },
            .has_conflicts = conflicts.items.len > 0,
            .conflicts = try conflicts.toOwnedSlice(self.allocator),
        };
    }
    
    fn shapesEqual(a: *const ast.Shape, b: *const ast.Shape) bool {
        if (a.fields.len != b.fields.len) return false;
        
        // Check that all fields in 'a' exist in 'b' with same type
        for (a.fields) |field_a| {
            var found = false;
            for (b.fields) |field_b| {
                if (std.mem.eql(u8, field_a.name, field_b.name)) {
                    // For expression fields, compare the expression strings
                    if (field_a.expression_str != null and field_b.expression_str != null) {
                        if (!std.mem.eql(u8, field_a.expression_str.?, field_b.expression_str.?)) {
                            return false;
                        }
                    } else if (!std.mem.eql(u8, field_a.type, field_b.type)) {
                        return false;
                    }
                    
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        
        return true;
    }
    
    fn cloneShape(allocator: std.mem.Allocator, shape: *const ast.Shape) !ast.Shape {
        var fields = try allocator.alloc(ast.Field, shape.fields.len);
        errdefer {
            for (fields) |*field| field.deinit(allocator);
            allocator.free(fields);
        }
        
        for (shape.fields, 0..) |field, i| {
            fields[i] = ast.Field{
                .name = try allocator.dupe(u8, field.name),
                .type = try allocator.dupe(u8, field.type),
                .phantom = if (field.phantom) |p| try allocator.dupe(u8, p) else null,
                .expression = field.expression, // Share expression AST (not owned)
                .expression_str = if (field.expression_str) |s| try allocator.dupe(u8, s) else null,
                .owns_expression = false, // Clone doesn't own the expression
            };
        }
        
        return ast.Shape{ .fields = fields };
    }
};

// Test helper to create a flow with branch constructors
pub fn testFlow(allocator: std.mem.Allocator) !ast.Flow {
    // Create continuations with branch constructors
    var continuations = try allocator.alloc(ast.Continuation, 2);
    
    // First continuation: | ok o |> success { data: o.value }
    var fields1 = try allocator.alloc(ast.Field, 1);
    fields1[0] = .{
        .name = try allocator.dupe(u8, "data"),
        .type = try allocator.dupe(u8, "auto"),
        .expression_str = try allocator.dupe(u8, "o.value"),
        .owns_expression = false,
    };
    
    var pipeline1 = try allocator.alloc(ast.Step, 1);
    pipeline1[0] = .{
        .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, "success"),
            .fields = fields1,
            .has_expressions = true,
        },
    };
    
    continuations[0] = .{
        .branch = try allocator.dupe(u8, "ok"),
        .binding = try allocator.dupe(u8, "o"),
        .condition = null,
        .condition_expr = null,
        .pipeline = pipeline1,
        .indent = 0,
        .nested = &[_]ast.Continuation{},
    };
    
    // Second continuation: | error e |> failure { msg: e.reason }
    var fields2 = try allocator.alloc(ast.Field, 1);
    fields2[0] = .{
        .name = try allocator.dupe(u8, "msg"),
        .type = try allocator.dupe(u8, "auto"),
        .expression_str = try allocator.dupe(u8, "__koru_event_input.reason"),
        .owns_expression = false,
    };
    
    var pipeline2 = try allocator.alloc(ast.Step, 1);
    pipeline2[0] = .{
        .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, "failure"),
            .fields = fields2,
            .has_expressions = true,
        },
    };
    
    continuations[1] = .{
        .branch = try allocator.dupe(u8, "error"),
        .binding = try allocator.dupe(u8, "e"),
        .condition = null,
        .condition_expr = null,
        .pipeline = pipeline2,
        .indent = 0,
        .nested = &[_]ast.Continuation{},
    };
    
    // Create flow invocation
    var args = try allocator.alloc(ast.Arg, 1);
    args[0] = .{
        .name = try allocator.dupe(u8, "url"),
        .value = try allocator.dupe(u8, "__koru_event_input.url"),
    };
    
    return ast.Flow{
        .invocation = .{
            .path = .{ .segments = try allocator.dupe([]const u8, &[_][]const u8{ "http", "get" }) },
            .args = args,
        },
        .continuations = continuations,
    };
}

test "collect branches from simple flow" {
    const allocator = std.testing.allocator;
    
    var flow = try testFlow(allocator);
    defer flow.deinit(allocator);
    
    var collector = UnionCollector.init(allocator);
    var result = try collector.collectFromFlow(&flow);
    defer result.deinit(allocator);
    
    // Should have 2 branches: success and failure
    try std.testing.expectEqual(@as(usize, 2), result.super_shape.branches.len);
    try std.testing.expect(!result.has_conflicts);
    
    // Check branch names
    const branch_names = [_][]const u8{ "success", "failure" };
    for (result.super_shape.branches) |branch| {
        var found = false;
        for (branch_names) |expected| {
            if (std.mem.eql(u8, branch.name, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}