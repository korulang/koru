const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const type_registry = @import("type_registry");
const type_context = @import("type_context");

/// Shape analyzer for inferring subflow output shapes
pub const ShapeAnalyzer = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    registry: *const type_registry.TypeRegistry,
    
    // Track analyzed shapes to avoid recomputation
    analyzed_subflows: std.StringHashMap(ShapeUnion),
    
    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter, registry: *const type_registry.TypeRegistry) !ShapeAnalyzer {
        return ShapeAnalyzer{
            .allocator = allocator,
            .reporter = reporter,
            .registry = registry,
            .analyzed_subflows = std.StringHashMap(ShapeUnion).init(allocator),
        };
    }
    
    pub fn deinit(self: *ShapeAnalyzer) void {
        var iter = self.analyzed_subflows.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.analyzed_subflows.deinit();
    }
    
    /// Analyze all exit points of a subflow implementation to collect output shapes
    pub fn analyzeSubflowImpl(
        self: *ShapeAnalyzer,
        subflow_impl: *const ast.SubflowImpl,
    ) ![]ExitPoint {
        var exit_points = try std.ArrayList(ExitPoint).initCapacity(self.allocator, 8);
        errdefer {
            for (exit_points.items) |*ep| {
                ep.deinit(self.allocator);
            }
            exit_points.deinit(self.allocator);
        }
        
        // Create a type context for this analysis
        var ctx = try type_context.TypeContext.init(self.allocator, self.registry);
        defer ctx.deinit();
        
        // Register event input fields as bindings for the subflow
        // This is the key difference from old subflows - we use the event's input fields
        const event_path = try self.pathToString(subflow_impl.event_path);
        defer self.allocator.free(event_path);
        try ctx.registerEventInputFields(event_path);
        
        // Handle based on body type
        switch (subflow_impl.body) {
            .flow => |flow| {
                // Start from the root flow
                try self.collectExitPoints(&flow, &exit_points, &ctx);
            },
            .immediate => |branch_constructor| {
                // For immediate returns, there's just one exit point
                const exit_point = ExitPoint{
                    .branch_name = try self.allocator.dupe(u8, branch_constructor.branch_name),
                    .fields = try self.duplicateFieldsWithTypes(branch_constructor.fields, &ctx),
                };
                try exit_points.append(self.allocator, exit_point);
            },
        }
        
        return try exit_points.toOwnedSlice(self.allocator);
    }
    
    /// Convert DottedPath to string for registry lookups
    fn pathToString(self: *ShapeAnalyzer, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        defer buf.deinit(self.allocator);
        for (path.segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }
        return try self.allocator.dupe(u8, buf.items);
    }
    
    /// Recursively collect exit points from a flow
    fn collectExitPoints(
        self: *ShapeAnalyzer,
        flow: *const ast.Flow,
        exit_points: *std.ArrayList(ExitPoint),
        ctx: *type_context.TypeContext,
    ) !void {
        // Get the event path for type lookups
        // Convert dotted path to string
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        defer buf.deinit(self.allocator);
        for (flow.invocation.path.segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }
        const event_path = try self.allocator.dupe(u8, buf.items);
        defer self.allocator.free(event_path);
        
        // Process each continuation
        for (flow.continuations) |cont| {
            try self.collectExitPointsFromContinuation(&cont, exit_points, ctx, event_path);
        }
    }
    
    /// Collect exit points from a continuation
    fn collectExitPointsFromContinuation(
        self: *ShapeAnalyzer,
        cont: *const ast.Continuation,
        exit_points: *std.ArrayList(ExitPoint),
        ctx: *type_context.TypeContext,
        event_path: ?[]const u8,
    ) !void {
        // If this continuation has a binding, register it with the type context
        if (cont.binding) |binding| {
            if (event_path) |path| {
                try ctx.enterContinuation(path, cont.branch, binding);
            }
        }
        
        // Walk through the step (single optional step)
        if (cont.node) |step| {
            switch (step) {
                .branch_constructor => |bc| {
                    // This is an exit point - a branch constructor
                    const exit_point = ExitPoint{
                        .branch_name = try self.allocator.dupe(u8, bc.branch_name),
                        .fields = try self.duplicateFieldsWithTypes(bc.fields, ctx),
                    };
                    try exit_points.append(self.allocator, exit_point);

                    // Branch constructors are terminal - no need to process further
                    return;
                },
                .terminal => {
                    // Terminal marker - no shape output
                    return;
                },
                .invocation => |inv| {
                    // Check if there are nested continuations
                    if (cont.continuations.len > 0) {
                        // Get the event path for the invoked event
                        const inv_path = try self.pathToString(inv.path);
                        defer self.allocator.free(inv_path);

                        // Process nested continuations with the correct event path
                        for (cont.continuations) |nested_cont| {
                            try self.collectExitPointsFromContinuation(&nested_cont, exit_points, ctx, inv_path);
                        }
                        return;
                    }
                },
                else => {},
            }
        }
    }
    
    /// Duplicate fields and infer their types using type context
    fn duplicateFieldsWithTypes(self: *ShapeAnalyzer, fields: []const ast.Field, ctx: *type_context.TypeContext) ![]ast.Field {
        var dup_fields = try self.allocator.alloc(ast.Field, fields.len);
        for (fields, 0..) |field, i| {
            // field.type contains the expression value, we need to infer its type
            const inferred_type = ctx.inferType(field.type) catch |err| {
                // NO FALLBACKS - fail loudly!
                std.debug.print("ERROR: Failed to infer type for field '{s}' with expression '{s}': {}\n", .{field.name, field.type, err});
                try self.reporter.addError(
                    .TYPE003,
                    0, 0,
                    "Cannot infer type for field '{s}' with expression '{s}'",
                    .{field.name, field.type},
                );
                return err;
            };
            dup_fields[i] = ast.Field{
                .name = try self.allocator.dupe(u8, field.name),
                .type = try self.allocator.dupe(u8, inferred_type),
            };
        }
        return dup_fields;
    }
    
    /// Duplicate fields for simple copying (no type inference)
    fn duplicateFields(self: *ShapeAnalyzer, fields: []const ast.Field) ![]ast.Field {
        var dup_fields = try self.allocator.alloc(ast.Field, fields.len);
        for (fields, 0..) |field, i| {
            dup_fields[i] = ast.Field{
                .name = try self.allocator.dupe(u8, field.name),
                .type = try self.allocator.dupe(u8, field.type),
            };
        }
        return dup_fields;
    }
    
    /// Infer the output shape union from collected exit points
    pub fn inferSubflowShape(
        self: *ShapeAnalyzer,
        subflow_name: []const u8,
        exit_points: []const ExitPoint,
    ) !ShapeUnion {
        // Group exit points by branch name
        var branch_map = std.StringHashMap(std.ArrayList(ExitPoint)).init(self.allocator);
        defer {
            var iter = branch_map.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            branch_map.deinit();
        }
        
        for (exit_points) |exit_point| {
            const result = try branch_map.getOrPut(exit_point.branch_name);
            if (!result.found_existing) {
                result.value_ptr.* = try std.ArrayList(ExitPoint).initCapacity(self.allocator, 4);
            }
            try result.value_ptr.append(self.allocator, exit_point);
        }
        
        // Build the shape union
        var branches = try std.ArrayList(BranchShape).initCapacity(self.allocator, exit_points.len);
        errdefer {
            for (branches.items) |*branch| {
                branch.deinit(self.allocator);
            }
            branches.deinit(self.allocator);
        }
        
        var iter = branch_map.iterator();
        while (iter.next()) |entry| {
            const branch_name = entry.key_ptr.*;
            const points = entry.value_ptr.items;
            
            // Verify structural equality for all points with this branch name
            if (points.len > 1) {
                const first = &points[0];
                for (points[1..]) |point| {
                    if (!self.structurallyEqual(first.fields, point.fields)) {
                        try self.reporter.addError(
                            .SHAPE001,
                            0, 0,
                            "Branch '{s}' has inconsistent shapes in subflow '{s}'",
                            .{ branch_name, subflow_name },
                        );
                        return error.InconsistentBranchShapes;
                    }
                }
            }
            
            // Add this branch to the union
            const branch_shape = BranchShape{
                .name = try self.allocator.dupe(u8, branch_name),
                .fields = try self.duplicateFields(points[0].fields),
            };
            try branches.append(self.allocator, branch_shape);
        }
        
        return ShapeUnion{
            .branches = try branches.toOwnedSlice(self.allocator),
        };
    }
    
    /// Check if two field sets are structurally equal
    fn structurallyEqual(self: *ShapeAnalyzer, a: []const ast.Field, b: []const ast.Field) bool {
        _ = self;
        if (a.len != b.len) return false;
        
        // Check that all fields in 'a' exist in 'b' with same type
        for (a) |field_a| {
            var found = false;
            for (b) |field_b| {
                if (std.mem.eql(u8, field_a.name, field_b.name)) {
                    if (!std.mem.eql(u8, field_a.type, field_b.type)) {
                        return false; // Same name, different type
                    }
                    found = true;
                    break;
                }
            }
            if (!found) return false; // Field not found in b
        }
        
        return true;
    }
    
    /// Generate a unique type name for a subflow's output union
    pub fn generateUnionTypeName(self: *ShapeAnalyzer, subflow_name: []const u8) ![]const u8 {
        // Sanitize the subflow name by replacing dots with underscores
        const sanitized = try self.allocator.alloc(u8, subflow_name.len);
        defer self.allocator.free(sanitized);
        for (subflow_name, 0..) |char, i| {
            sanitized[i] = if (char == '.') '_' else char;
        }
        
        return try std.fmt.allocPrint(
            self.allocator,
            "SubflowResult_{s}",
            .{sanitized},
        );
    }
    
    /// Cache an analyzed shape for a subflow
    pub fn cacheShape(self: *ShapeAnalyzer, subflow_name: []const u8, shape: ShapeUnion) !void {
        const key = try self.allocator.dupe(u8, subflow_name);
        try self.analyzed_subflows.put(key, shape);
    }
    
    /// Get a cached shape for a subflow
    pub fn getCachedShape(self: *ShapeAnalyzer, subflow_name: []const u8) ?ShapeUnion {
        return self.analyzed_subflows.get(subflow_name);
    }
    
    /// Free exit points allocated by analyzeSubflowExitPoints
    /// Caller is responsible for calling this
    pub fn freeExitPoints(self: *ShapeAnalyzer, exit_points: []ExitPoint) void {
        for (exit_points) |*ep| {
            ep.deinit(self.allocator);
        }
        self.allocator.free(exit_points);
    }
};

/// An exit point in a subflow (branch constructor or terminal)
pub const ExitPoint = struct {
    branch_name: []const u8,
    fields: []ast.Field,
    
    pub fn deinit(self: *ExitPoint, allocator: std.mem.Allocator) void {
        allocator.free(self.branch_name);
        for (self.fields) |field| {
            allocator.free(field.name);
            allocator.free(field.type);
        }
        allocator.free(self.fields);
    }
};

/// Shape union representing all possible outputs of a subflow
pub const ShapeUnion = struct {
    branches: []BranchShape,
    
    pub fn deinit(self: *ShapeUnion, allocator: std.mem.Allocator) void {
        for (self.branches) |*branch| {
            branch.deinit(allocator);
        }
        allocator.free(self.branches);
    }
};

/// A single branch in a shape union
pub const BranchShape = struct {
    name: []const u8,
    fields: []ast.Field,
    
    pub fn deinit(self: *BranchShape, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.fields) |field| {
            allocator.free(field.name);
            allocator.free(field.type);
        }
        allocator.free(self.fields);
    }
};

// Tests
test "analyze simple subflow exit points" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var registry = type_registry.TypeRegistry.init(allocator);
    defer registry.deinit();
    
    var analyzer = try ShapeAnalyzer.init(allocator, &reporter, &registry);
    defer analyzer.deinit();
    
    // Create a simple subflow with two branch constructors
    var success_fields = [_]ast.Field{
        .{ .name = "value", .type = "i32" },
    };
    var failure_fields = [_]ast.Field{
        .{ .name = "error", .type = "[]const u8" },
    };
    
    const success_constructor = ast.BranchConstructor{
        .branch_name = "success",
        .fields = &success_fields,
    };
    const failure_constructor = ast.BranchConstructor{
        .branch_name = "failure", 
        .fields = &failure_fields,
    };
    
    const success_step = ast.Step{ .branch_constructor = success_constructor };
    const failure_step = ast.Step{ .branch_constructor = failure_constructor };
    
    var success_pipeline = [_]ast.Step{success_step};
    var failure_pipeline = [_]ast.Step{failure_step};
    
    var continuations = [_]ast.Continuation{
        .{
            .branch = "ok",
            .binding = null,
            .pipeline = &success_pipeline,
            .indent = 0,
            .nested = &[_]ast.Continuation{},
        },
        .{
            .branch = "error",
            .binding = null,
            .pipeline = &failure_pipeline,
            .indent = 0,
            .nested = &[_]ast.Continuation{},
        },
    };
    
    const invocation = ast.Invocation{
        .event = .{
            .path = ast.DottedPath{ .segments = &[_][]const u8{"test"} },
            .args = &[_]ast.Arg{},
        },
    };
    
    const flow = ast.Flow{
        .invocation = invocation,
        .continuations = &continuations,
    };
    
    const subflow = ast.SubflowDecl{
        .name = "test_subflow",
        .params = &[_][]const u8{},
        .body = flow,
    };
    
    // Analyze exit points
    const exit_points = try analyzer.analyzeSubflowExitPoints(&subflow);
    defer allocator.free(exit_points);
    
    try std.testing.expect(exit_points.len == 2);
    try std.testing.expectEqualSlices(u8, exit_points[0].branch_name, "success");
    try std.testing.expectEqualSlices(u8, exit_points[1].branch_name, "failure");
}

test "infer shape union from exit points" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var registry = type_registry.TypeRegistry.init(allocator);
    defer registry.deinit();
    
    var analyzer = try ShapeAnalyzer.init(allocator, &reporter, &registry);
    defer analyzer.deinit();
    
    // Create exit points
    var success_fields = [_]ast.Field{
        .{ .name = "value", .type = "i32" },
    };
    var failure_fields = [_]ast.Field{
        .{ .name = "error", .type = "[]const u8" },
    };
    
    var exit_points = [_]ExitPoint{
        .{
            .branch_name = "success",
            .fields = &success_fields,
        },
        .{
            .branch_name = "failure",
            .fields = &failure_fields,
        },
    };
    
    // Infer shape
    const shape = try analyzer.inferSubflowShape("test_subflow", &exit_points);
    defer {
        var mut_shape = shape;
        mut_shape.deinit(allocator);
    }
    
    try std.testing.expect(shape.branches.len == 2);
    
    // Find success branch
    var found_success = false;
    var found_failure = false;
    for (shape.branches) |branch| {
        if (std.mem.eql(u8, branch.name, "success")) {
            found_success = true;
            try std.testing.expect(branch.fields.len == 1);
            try std.testing.expectEqualSlices(u8, branch.fields[0].name, "value");
        } else if (std.mem.eql(u8, branch.name, "failure")) {
            found_failure = true;
            try std.testing.expect(branch.fields.len == 1);
            try std.testing.expectEqualSlices(u8, branch.fields[0].name, "error");
        }
    }
    
    try std.testing.expect(found_success);
    try std.testing.expect(found_failure);
}

test "detect inconsistent branch shapes" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var registry = type_registry.TypeRegistry.init(allocator);
    defer registry.deinit();
    
    var analyzer = try ShapeAnalyzer.init(allocator, &reporter, &registry);
    defer analyzer.deinit();
    
    // Create exit points with inconsistent shapes for same branch
    var success_fields1 = [_]ast.Field{
        .{ .name = "value", .type = "i32" },
    };
    var success_fields2 = [_]ast.Field{
        .{ .name = "value", .type = "[]const u8" }, // Different type!
    };
    
    var exit_points = [_]ExitPoint{
        .{
            .branch_name = "success",
            .fields = &success_fields1,
        },
        .{
            .branch_name = "success",
            .fields = &success_fields2,
        },
    };
    
    // Should fail due to inconsistent shapes
    _ = analyzer.inferSubflowShape("test_subflow", &exit_points) catch |err| {
        try std.testing.expect(err == error.InconsistentBranchShapes);
        return;
    };
    
    try std.testing.expect(false); // Should not reach here
}