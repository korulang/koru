const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

/// Type information for tracking during inference
pub const TypeInfo = union(enum) {
    /// A concrete type like u32, []const u8
    concrete: []const u8,
    /// A tagged union branch with fields
    branch: BranchType,
    /// A full tagged union with multiple branches
    tagged_union: []const BranchType,
    /// Unknown type - needs inference
    unknown: void,
};

pub const BranchType = struct {
    name: []const u8,
    fields: []FieldType,
};

pub const FieldType = struct {
    name: []const u8,
    type: []const u8,
};

/// Type inference engine for branch constructors and subflows
pub const TypeInference = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.ErrorReporter,
    
    // Type environment: maps bindings to their types
    bindings: std.StringHashMap(TypeInfo),
    
    // Event output types: maps event paths to their output shapes
    event_outputs: std.StringHashMap(TypeInfo),
    
    pub fn init(allocator: std.mem.Allocator, reporter: *errors.ErrorReporter) !TypeInference {
        return TypeInference{
            .allocator = allocator,
            .reporter = reporter,
            .bindings = std.StringHashMap(TypeInfo).init(allocator),
            .event_outputs = std.StringHashMap(TypeInfo).init(allocator),
        };
    }
    
    pub fn deinit(self: *TypeInference) void {
        // Free all binding keys and values
        var bindings_iter = self.bindings.iterator();
        while (bindings_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // TypeInfo values may contain allocated memory
            self.freeTypeInfo(entry.value_ptr.*);
        }
        self.bindings.deinit();
        
        // Free all event output keys and values  
        var events_iter = self.event_outputs.iterator();
        while (events_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeTypeInfo(entry.value_ptr.*);
        }
        self.event_outputs.deinit();
    }
    
    fn freeTypeInfo(self: *TypeInference, info: TypeInfo) void {
        switch (info) {
            .concrete => |str| {
                self.allocator.free(str);
            },
            .branch => |branch| {
                self.allocator.free(branch.name);
                for (branch.fields) |field| {
                    self.allocator.free(field.name);
                    self.allocator.free(field.type);
                }
                self.allocator.free(branch.fields);
            },
            .tagged_union => |branches| {
                for (branches) |branch| {
                    self.allocator.free(branch.name);
                    for (branch.fields) |field| {
                        self.allocator.free(field.name);
                        self.allocator.free(field.type);
                    }
                    self.allocator.free(branch.fields);
                }
                self.allocator.free(branches);
            },
            .unknown => {},
        }
    }
    
    /// Register an event's output type from its declaration
    pub fn registerEvent(self: *TypeInference, path: []const u8, branches: []const ast.Branch) !void {
        var branch_types = try self.allocator.alloc(BranchType, branches.len);
        
        for (branches, 0..) |branch, i| {
            var field_types = try self.allocator.alloc(FieldType, branch.payload.fields.len);
            
            for (branch.payload.fields, 0..) |field, j| {
                field_types[j] = FieldType{
                    .name = try self.allocator.dupe(u8, field.name),
                    .type = try self.allocator.dupe(u8, field.type),
                };
            }
            
            branch_types[i] = BranchType{
                .name = try self.allocator.dupe(u8, branch.name),
                .fields = field_types,
            };
        }
        
        const key = try self.allocator.dupe(u8, path);
        try self.event_outputs.put(key, TypeInfo{ .tagged_union = branch_types });
    }
    
    /// Infer types for a branch constructor based on context
    pub fn inferBranchConstructor(
        self: *TypeInference,
        constructor: *ast.BranchConstructor,
        expected_type: ?TypeInfo,
    ) !TypeInfo {
        // If we have an expected type and it's a tagged union, validate against it
        if (expected_type) |expected| {
            switch (expected) {
                .tagged_union => |branches| {
                    // Find the matching branch
                    for (branches) |branch| {
                        if (std.mem.eql(u8, branch.name, constructor.branch_name)) {
                            // Validate and infer field types
                            try self.inferFieldTypes(constructor, branch);
                            
                            return TypeInfo{ .branch = branch };
                        }
                    }
                    
                    // Branch not found in expected union
                    try self.reporter.addError(
                        .TYPE001,
                        0, 0,
                        "Branch '{s}' not found in expected tagged union",
                        .{constructor.branch_name},
                    );
                    return error.TypeMismatch;
                },
                else => {
                    // Expected type is not a tagged union
                    try self.reporter.addError(
                        .TYPE002,
                        0, 0,
                        "Branch constructor used where tagged union not expected",
                        .{},
                    );
                    return error.TypeMismatch;
                },
            }
        }
        
        // No expected type - construct a new branch type
        var field_types = try self.allocator.alloc(FieldType, constructor.fields.len);
        
        for (constructor.fields, 0..) |field, i| {
            // For now, use the raw expression as the type
            // In a full implementation, we'd infer this from the expression
            field_types[i] = FieldType{
                .name = try self.allocator.dupe(u8, field.name),
                .type = try self.inferFieldExpression(field.type),
            };
        }
        
        return TypeInfo{
            .branch = BranchType{
                .name = try self.allocator.dupe(u8, constructor.branch_name),
                .fields = field_types,
            },
        };
    }
    
    /// Infer field types and validate against expected branch shape
    fn inferFieldTypes(
        self: *TypeInference,
        constructor: *ast.BranchConstructor,
        expected_branch: BranchType,
    ) !void {
        // Check that all required fields are present
        for (expected_branch.fields) |expected_field| {
            var found = false;
            
            for (constructor.fields) |provided_field| {
                if (std.mem.eql(u8, expected_field.name, provided_field.name)) {
                    // Validate type compatibility
                    const inferred_type = try self.inferFieldExpression(provided_field.type);
                    
                    if (!self.typesCompatible(inferred_type, expected_field.type)) {
                        try self.reporter.addError(
                            .TYPE003,
                            0, 0,
                            "Field '{s}' type mismatch: expected '{s}', got '{s}'",
                            .{expected_field.name, expected_field.type, inferred_type},
                        );
                        return error.TypeMismatch;
                    }
                    
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                try self.reporter.addError(
                    .TYPE004,
                    0, 0,
                    "Missing required field '{s}' in branch constructor",
                    .{expected_field.name},
                );
                return error.MissingField;
            }
        }
        
        // Check for extra fields
        for (constructor.fields) |provided_field| {
            var found = false;
            
            for (expected_branch.fields) |expected_field| {
                if (std.mem.eql(u8, expected_field.name, provided_field.name)) {
                    found = true;
                    break;
                }
            }
            
            if (!found) {
                try self.reporter.addError(
                    .TYPE005,
                    0, 0,
                    "Unexpected field '{s}' in branch constructor",
                    .{provided_field.name},
                );
                return error.ExtraField;
            }
        }
    }
    
    /// Infer the type of a field expression
    pub fn inferFieldExpression(self: *TypeInference, expr: []const u8) ![]const u8 {
        // For now, this is a simple heuristic
        // In a full implementation, we'd parse and analyze the expression
        
        // Check if it's a binding reference (e.g., "s.result")
        if (std.mem.indexOf(u8, expr, ".")) |dot_idx| {
            const binding = expr[0..dot_idx];
            const field = expr[dot_idx + 1..];
            
            // Look up the binding type
            if (self.bindings.get(binding)) |binding_type| {
                switch (binding_type) {
                    .branch => |branch| {
                        // Find the field type in the branch
                        for (branch.fields) |field_type| {
                            if (std.mem.eql(u8, field_type.name, field)) {
                                return field_type.type;
                            }
                        }
                    },
                    .concrete => |type_name| {
                        // For concrete types, we'd need more context
                        return type_name;
                    },
                    else => {},
                }
            }
        }
        
        // Check for literals
        if (std.mem.startsWith(u8, expr, "\"")) {
            return "[]const u8";
        }
        
        // Check for numeric literals
        if (std.ascii.isDigit(expr[0])) {
            if (std.mem.indexOf(u8, expr, ".") != null) {
                return "f64";
            } else {
                return "u32"; // Default to u32 for integers
            }
        }
        
        // Default fallback
        return try self.allocator.dupe(u8, expr);
    }
    
    /// Check if two types are compatible
    fn typesCompatible(self: *TypeInference, actual: []const u8, expected: []const u8) bool {
        _ = self;
        
        // For now, exact match
        // In a full implementation, we'd handle subtyping, coercions, etc.
        return std.mem.eql(u8, actual, expected);
    }
    
    /// Process a continuation and update type bindings
    pub fn processContinuation(
        self: *TypeInference,
        continuation: *const ast.Continuation,
        branch_type: BranchType,
    ) !void {
        // If there's a binding, register its type
        if (continuation.binding) |binding| {
            const key = try self.allocator.dupe(u8, binding);
            try self.bindings.put(key, TypeInfo{ .branch = branch_type });
        }
        
        // Process pipeline steps to infer types forward
        for (continuation.pipeline) |step| {
            switch (step) {
                .branch_constructor => |bc| {
                    // Infer type for this constructor
                    _ = try self.inferBranchConstructor(bc, null);
                },
                else => {},
            }
        }
    }
};

// Tests
test "type inference for simple branch constructor" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var inference = try TypeInference.init(allocator, &reporter);
    defer inference.deinit();
    
    // Register a binding type
    const binding_fields = try allocator.alloc(FieldType, 1);
    binding_fields[0] = .{ .name = "result", .type = "u32" };
    try inference.bindings.put(
        "s",
        TypeInfo{
            .branch = BranchType{
                .name = "success",
                .fields = binding_fields,
            },
        },
    );
    
    // Create a branch constructor
    var fields = [_]ast.Field{
        .{ .name = "output", .type = "s.result" },
    };
    
    var constructor = ast.BranchConstructor{
        .branch_name = "done",
        .fields = &fields,
    };
    
    // Infer its type
    const inferred = try inference.inferBranchConstructor(&constructor, null);
    
    try std.testing.expect(inferred == .branch);
    try std.testing.expectEqualSlices(u8, inferred.branch.name, "done");
}

test "type inference with expected type validation" {
    const allocator = std.testing.allocator;
    var reporter = try errors.ErrorReporter.init(allocator, "test.kz", "");
    defer reporter.deinit();
    
    var inference = try TypeInference.init(allocator, &reporter);
    defer inference.deinit();
    
    // Define expected type
    var expected_fields = [_]FieldType{
        .{ .name = "value", .type = "u32" },
        .{ .name = "status", .type = "[]const u8" },
    };
    
    var expected_branches = [_]BranchType{
        .{
            .name = "success",
            .fields = &expected_fields,
        },
    };
    
    const expected_type = TypeInfo{ .tagged_union = &expected_branches };
    
    // Create matching branch constructor  
    var fields = [_]ast.Field{
        .{ .name = "value", .type = "42" },
        .{ .name = "status", .type = "\"ok\"" },
    };
    
    var constructor = ast.BranchConstructor{
        .branch_name = "success",
        .fields = &fields,
    };
    
    // Should succeed with matching fields
    const inferred = try inference.inferBranchConstructor(&constructor, expected_type);
    
    try std.testing.expect(inferred == .branch);
    try std.testing.expectEqualSlices(u8, inferred.branch.name, "success");
}