const std = @import("std");
const ast = @import("ast");
const expression_codegen = @import("expression_codegen");
const codegen_utils = @import("codegen_utils");

/// Generates Zig union types from SuperShape definitions
pub const UnionCodegen = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) UnionCodegen {
        return UnionCodegen{ .allocator = allocator };
    }
    
    /// Generate a unique name for an inline flow's union type
    pub fn generateInlineFlowTypeName(
        self: *UnionCodegen,
        proc_name: []const u8,
        flow_index: usize
    ) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "InlineFlow_{s}_{}_Result",
            .{ proc_name, flow_index }
        );
    }
    
    /// Generate a Zig union type declaration from a SuperShape
    pub fn generateUnionType(
        self: *UnionCodegen,
        type_name: []const u8,
        super_shape: *const ast.SuperShape
    ) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer result.deinit(self.allocator);
        
        // Start union declaration
        try result.appendSlice(self.allocator, "const ");
        try result.appendSlice(self.allocator, type_name);
        try result.appendSlice(self.allocator, " = union(enum) {\n");
        
        // Generate each branch variant
        for (super_shape.branches) |branch| {
            try result.appendSlice(self.allocator, "    ");
            try codegen_utils.appendEscapedIdentifier(&result, self.allocator, branch.name);
            try result.appendSlice(self.allocator, ": ");
            
            // Generate struct for branch payload
            if (branch.payload.fields.len == 0) {
                try result.appendSlice(self.allocator, "void");
            } else {
                try result.appendSlice(self.allocator, "struct {\n");
                
                for (branch.payload.fields) |field| {
                    try result.appendSlice(self.allocator, "        ");
                    try codegen_utils.appendEscapedIdentifier(&result, self.allocator, field.name);
                    try result.appendSlice(self.allocator, ": ");
                    
                    // Use the type or infer from expression
                    if (std.mem.eql(u8, field.type, "auto")) {
                        // For expression fields, we'll generate the type based on context
                        // For now, use a generic type that works at runtime
                        if (field.expression_str != null) {
                            // TODO: Proper type inference from expression context
                            // For now, common patterns:
                            if (std.mem.indexOf(u8, field.expression_str.?, ".len") != null) {
                                try result.appendSlice(self.allocator, "usize");
                            } else {
                                try result.appendSlice(self.allocator, "[]const u8"); // Default to string for now
                            }
                        } else {
                            try result.appendSlice(self.allocator, "anytype");
                        }
                    } else {
                        try result.appendSlice(self.allocator, field.type);
                    }
                    
                    try result.appendSlice(self.allocator, ",\n");
                }
                
                try result.appendSlice(self.allocator, "    }");
            }
            
            try result.appendSlice(self.allocator, ",\n");
        }
        
        try result.appendSlice(self.allocator, "};\n");
        
        return try result.toOwnedSlice(self.allocator);
    }
    
    /// Generate a union constructor expression
    pub fn generateUnionConstructor(
        self: *UnionCodegen,
        union_type: []const u8,
        branch_constructor: *const ast.BranchConstructor
    ) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer result.deinit(self.allocator);
        
        // Start with union type
        try result.appendSlice(self.allocator, union_type);
        try result.appendSlice(self.allocator, "{ .");
        try codegen_utils.appendEscapedIdentifier(&result, self.allocator, branch_constructor.branch_name);
        try result.appendSlice(self.allocator, " = ");
        
        if (branch_constructor.fields.len == 0) {
            try result.appendSlice(self.allocator, "{}");
        } else {
            try result.appendSlice(self.allocator, ".{ ");
            
            for (branch_constructor.fields, 0..) |field, i| {
                if (i > 0) try result.appendSlice(self.allocator, ", ");

                try result.append(self.allocator, '.');
                try codegen_utils.appendEscapedIdentifier(&result, self.allocator, field.name);
                try result.appendSlice(self.allocator, " = ");
                
                // Generate value expression
                if (field.expression) |expr| {
                    // Use expression codegen to generate the value
                    const expr_code = try expression_codegen.generateExpression(self.allocator, expr);
                    defer self.allocator.free(expr_code);
                    try result.appendSlice(self.allocator, expr_code);
                } else if (field.expression_str) |expr_str| {
                    // Use raw expression string
                    try result.appendSlice(self.allocator, expr_str);
                } else {
                    // Use the type field as a literal value (legacy behavior)
                    try result.appendSlice(self.allocator, field.type);
                }
            }
            
            try result.appendSlice(self.allocator, " }");
        }
        
        try result.appendSlice(self.allocator, " }");
        
        return try result.toOwnedSlice(self.allocator);
    }
    
    /// Generate a complete inline flow function that returns a union type
    pub fn generateInlineFlowFunction(
        self: *UnionCodegen,
        flow_name: []const u8,
        flow: *const ast.Flow,
        union_type_name: []const u8,
        super_shape: *const ast.SuperShape
    ) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer result.deinit(self.allocator);
        
        // Generate union type declaration
        const union_decl = try self.generateUnionType(union_type_name, super_shape);
        defer self.allocator.free(union_decl);
        try result.appendSlice(self.allocator, union_decl);
        try result.append(self.allocator, '\n');
        
        // Generate function signature
        try result.appendSlice(self.allocator, "fn ");
        try result.appendSlice(self.allocator, flow_name);
        try result.appendSlice(self.allocator, "() !");
        try result.appendSlice(self.allocator, union_type_name);
        try result.appendSlice(self.allocator, " {\n");
        
        // Generate flow invocation
        try result.appendSlice(self.allocator, "    const __result = try ");
        try self.generateFlowInvocation(&result, &flow.invocation);
        try result.appendSlice(self.allocator, ";\n");
        
        // Generate switch statement for continuations
        try result.appendSlice(self.allocator, "    return switch (__result) {\n");
        
        for (flow.continuations) |cont| {
            try result.appendSlice(self.allocator, "        .");
            try codegen_utils.appendEscapedIdentifier(&result, self.allocator, cont.branch);
            try result.appendSlice(self.allocator, " => |");
            if (cont.binding) |binding| {
                try codegen_utils.appendEscapedIdentifier(&result, self.allocator, binding);
            } else {
                try result.appendSlice(self.allocator, "_");
            }
            try result.appendSlice(self.allocator, "| ");
            
            // Generate condition if present
            if (cont.condition_expr) |cond_expr| {
                try result.appendSlice(self.allocator, "if (");
                const cond_code = try expression_codegen.generateExpression(self.allocator, cond_expr);
                defer self.allocator.free(cond_code);
                try result.appendSlice(self.allocator, cond_code);
                try result.appendSlice(self.allocator, ") ");
            }
            
            // Generate branch constructor
            for (cont.pipeline) |step| {
                if (step == .branch_constructor) {
                    const constructor_code = try self.generateUnionConstructor(
                        union_type_name,
                        &step.branch_constructor
                    );
                    defer self.allocator.free(constructor_code);
                    try result.appendSlice(self.allocator, constructor_code);
                }
            }
            
            try result.appendSlice(self.allocator, ",\n");
        }
        
        try result.appendSlice(self.allocator, "    };\n");
        try result.appendSlice(self.allocator, "}\n");
        
        return try result.toOwnedSlice(self.allocator);
    }
    
    fn generateFlowInvocation(
        self: *UnionCodegen,
        result: *std.ArrayList(u8),
        invocation: *const ast.Invocation
    ) !void {
        // Generate path
        for (invocation.path.segments, 0..) |seg, i| {
            if (i > 0) try result.append(self.allocator, '.');
            try result.appendSlice(self.allocator, seg);
        }
        
        // Generate arguments
        try result.appendSlice(self.allocator, "(.{");
        for (invocation.args, 0..) |arg, i| {
            if (i > 0) try result.appendSlice(self.allocator, ", ");
            try result.append(self.allocator, '.');
            try result.appendSlice(self.allocator, arg.name);
            try result.appendSlice(self.allocator, " = ");
            try result.appendSlice(self.allocator, arg.value);
        }
        try result.appendSlice(self.allocator, "})");
    }
};

test "generate union type" {
    const allocator = std.testing.allocator;
    
    // Create a simple SuperShape
    var branches = try allocator.alloc(ast.SuperShape.BranchVariant, 2);
    defer allocator.free(branches);
    
    // Success branch with data field
    var success_fields = try allocator.alloc(ast.Field, 1);
    success_fields[0] = .{
        .name = "data",
        .type = "[]const u8",
        .owns_expression = false,
    };
    branches[0] = .{
        .name = "success",
        .payload = .{ .fields = success_fields },
        .sources = &[_]ast.DottedPath{},
    };
    
    // Error branch with msg field
    var error_fields = try allocator.alloc(ast.Field, 1);
    error_fields[0] = .{
        .name = "msg",
        .type = "[]const u8",
        .owns_expression = false,
    };
    branches[1] = .{
        .name = "error",
        .payload = .{ .fields = error_fields },
        .sources = &[_]ast.DottedPath{},
    };
    
    const super_shape = ast.SuperShape{ .branches = branches };
    
    var codegen = UnionCodegen.init(allocator);
    const union_code = try codegen.generateUnionType("Result", &super_shape);
    defer allocator.free(union_code);
    
    // Clean up
    allocator.free(success_fields);
    allocator.free(error_fields);
    
    // Check that the generated code contains expected elements
    try std.testing.expect(std.mem.indexOf(u8, union_code, "const Result = union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_code, "success: struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_code, "error: struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_code, "data: []const u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, union_code, "msg: []const u8") != null);
}

test "generate union constructor" {
    const allocator = std.testing.allocator;
    
    // Create a branch constructor
    var fields = try allocator.alloc(ast.Field, 1);
    defer allocator.free(fields);
    fields[0] = .{
        .name = "data",
        .type = "auto",
        .expression_str = "o.value",
        .owns_expression = false,
    };
    
    const branch_constructor = ast.BranchConstructor{
        .branch_name = "success",
        .fields = fields,
        .has_expressions = true,
    };
    
    var codegen = UnionCodegen.init(allocator);
    const constructor_code = try codegen.generateUnionConstructor("Result", &branch_constructor);
    defer allocator.free(constructor_code);
    
    // Check generated code
    try std.testing.expect(std.mem.indexOf(u8, constructor_code, "Result{ .success =") != null);
    try std.testing.expect(std.mem.indexOf(u8, constructor_code, ".data = o.value") != null);
}