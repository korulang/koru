const std = @import("std");
const ast = @import("ast");
const type_registry = @import("type_registry");

/// Type context that flows through AST walks, tracking bindings
pub const TypeContext = struct {
    allocator: std.mem.Allocator,
    registry: *const type_registry.TypeRegistry,
    
    // Stack of binding scopes (for nested contexts)
    scopes: std.ArrayList(BindingScope),
    
    pub fn init(allocator: std.mem.Allocator, registry: *const type_registry.TypeRegistry) !TypeContext {
        const scopes = try std.ArrayList(BindingScope).initCapacity(allocator, 8);
        var ctx = TypeContext{
            .allocator = allocator,
            .registry = registry,
            .scopes = scopes,
        };
        
        // Start with a root scope
        try ctx.pushScope();
        
        return ctx;
    }
    
    pub fn deinit(self: *TypeContext) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(self.allocator);
    }
    
    /// Push a new binding scope (for nested contexts)
    pub fn pushScope(self: *TypeContext) !void {
        const scope = BindingScope.init(self.allocator);
        try self.scopes.append(self.allocator, scope);
    }
    
    /// Pop the current binding scope
    pub fn popScope(self: *TypeContext) void {
        if (self.scopes.items.len > 1) { // Keep at least the root scope
            var scope = self.scopes.pop();
            scope.deinit();
        }
    }
    
    /// Enter a continuation with a branch binding
    pub fn enterContinuation(
        self: *TypeContext,
        event_path: []const u8,
        branch_name: []const u8,
        binding: ?[]const u8,
    ) !void {
        if (binding) |name| {
            // Look up the branch type from the event
            if (self.registry.getBranchType(event_path, branch_name)) |branch_type| {
                // Register the binding with its type
                try self.registerBinding(name, BoundType{
                    .branch = branch_type,
                });
            }
        }
    }
    
    /// Register event input fields as bindings for subflow implementation
    pub fn registerEventInputFields(
        self: *TypeContext,
        event_path: []const u8,
    ) !void {
        // Look up the event in the registry
        if (self.registry.getEventType(event_path)) |event_type| {
            // Register each input field as a binding
            if (event_type.input_shape) |shape| {
                for (shape.fields) |field| {
                    try self.registerBinding(field.name, BoundType{
                        .concrete = field.type,
                    });
                }
            }
        }
    }
    
    /// Register a binding in the current scope
    pub fn registerBinding(self: *TypeContext, name: []const u8, bound_type: BoundType) !void {
        if (self.scopes.items.len == 0) return error.NoScope;
        
        const current_scope = &self.scopes.items[self.scopes.items.len - 1];
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        
        var value = try bound_type.duplicate(self.allocator);
        errdefer value.deinit(self.allocator);
        
        try current_scope.bindings.put(key, value);
    }
    
    /// Look up a binding's type (searches all scopes from innermost to outermost)
    pub fn lookupBinding(self: *TypeContext, name: []const u8) ?BoundType {
        // Search from innermost to outermost scope
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].bindings.get(name)) |bound_type| {
                return bound_type;
            }
        }
        return null;
    }
    
    /// Resolve the type of a field access expression (e.g., "p.value")
    pub fn resolveFieldAccess(self: *TypeContext, expr: []const u8) ![]const u8 {
        // Check for field access pattern
        if (std.mem.indexOf(u8, expr, ".")) |dot_idx| {
            const binding_name = expr[0..dot_idx];
            const field_name = expr[dot_idx + 1..];
            
            // Look up the binding
            if (self.lookupBinding(binding_name)) |bound_type| {
                switch (bound_type) {
                    .branch => |branch| {
                        // Find the field in the branch payload
                        if (branch.payload) |shape| {
                            for (shape.fields) |field| {
                                if (std.mem.eql(u8, field.name, field_name)) {
                                    return field.type;
                                }
                            }
                        }
                        return error.FieldNotFound;
                    },
                    .shape => |shape| {
                        // Find the field in the shape
                        for (shape.fields) |field| {
                            if (std.mem.eql(u8, field.name, field_name)) {
                                return field.type;
                            }
                        }
                        return error.FieldNotFound;
                    },
                    .concrete => |type_name| {
                        // Special case for anytype - we can't verify field existence
                        // but we return the expression itself for the emitter to use
                        if (std.mem.eql(u8, type_name, "anytype")) {
                            // Return the full expression - the emitter will handle it
                            return expr;
                        }
                        // Can't resolve fields on other concrete types without more context
                        return error.CannotResolveField;
                    },
                }
            } else {
                return error.BindingNotFound;
            }
        }
        
        // Not a field access - check if it's a simple binding reference
        if (self.lookupBinding(expr)) |bound_type| {
            switch (bound_type) {
                .concrete => |type_name| return type_name,
                else => return error.NotAConcreteType,
            }
        }
        
        return error.UnknownExpression;
    }
    
    /// Infer the type of any expression
    pub fn inferType(self: *TypeContext, expr: []const u8) ![]const u8 {
        // Check for string literals
        if (std.mem.startsWith(u8, expr, "\"")) {
            return "[]const u8";
        }
        
        // Check for numeric literals
        if (expr.len > 0) {
            const first = expr[0];
            if (std.ascii.isDigit(first) or first == '-') {
                // Simple numeric literal check
                var all_digits = true;
                var has_dot = false;
                for (expr, 0..) |c, i| {
                    if (c == '.' and !has_dot) {
                        has_dot = true;
                    } else if (c == '-' and i == 0) {
                        // Negative sign at start is ok
                    } else if (!std.ascii.isDigit(c)) {
                        all_digits = false;
                        break;
                    }
                }
                
                if (all_digits) {
                    if (has_dot) {
                        return "f64";
                    } else {
                        return "i32";
                    }
                }
            }
        }
        
        // Try to resolve as field access or binding
        return self.resolveFieldAccess(expr);
    }
};

/// A scope for bindings (allows nesting)
const BindingScope = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(BoundType),
    
    fn init(allocator: std.mem.Allocator) BindingScope {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(BoundType).init(allocator),
        };
    }
    
    fn deinit(self: *BindingScope) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.bindings.deinit();
    }
};

/// Type of a bound value
pub const BoundType = union(enum) {
    branch: type_registry.BranchType,
    shape: ast.Shape,
    concrete: []const u8, // e.g., "i32", "[]const u8"
    
    pub fn duplicate(self: BoundType, allocator: std.mem.Allocator) !BoundType {
        switch (self) {
            .branch => |branch| {
                var payload: ?ast.Shape = null;
                if (branch.payload) |p| {
                    var fields = try allocator.alloc(ast.Field, p.fields.len);
                    for (p.fields, 0..) |field, i| {
                        fields[i] = ast.Field{
                            .name = try allocator.dupe(u8, field.name),
                            .type = try allocator.dupe(u8, field.type),
                        };
                    }
                    payload = ast.Shape{ .fields = fields };
                }
                
                return BoundType{
                    .branch = type_registry.BranchType{
                        .name = try allocator.dupe(u8, branch.name),
                        .payload = payload,
                    },
                };
            },
            .shape => |shape| {
                var fields = try allocator.alloc(ast.Field, shape.fields.len);
                for (shape.fields, 0..) |field, i| {
                    fields[i] = ast.Field{
                        .name = try allocator.dupe(u8, field.name),
                        .type = try allocator.dupe(u8, field.type),
                    };
                }
                return BoundType{
                    .shape = ast.Shape{ .fields = fields },
                };
            },
            .concrete => |type_name| {
                return BoundType{
                    .concrete = try allocator.dupe(u8, type_name),
                };
            },
        }
    }
    
    pub fn deinit(self: *BoundType, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .branch => |*branch| {
                allocator.free(branch.name);
                if (branch.payload) |shape| {
                    for (shape.fields) |field| {
                        allocator.free(field.name);
                        allocator.free(field.type);
                    }
                    allocator.free(shape.fields);
                }
            },
            .shape => |shape| {
                for (shape.fields) |field| {
                    allocator.free(field.name);
                    allocator.free(field.type);
                }
                allocator.free(shape.fields);
            },
            .concrete => |type_name| {
                allocator.free(type_name);
            },
        }
    }
};

// Tests
test "type context binding and field resolution" {
    const allocator = std.testing.allocator;
    
    // Set up a registry with an event
    var registry = type_registry.TypeRegistry.init(allocator);
    defer registry.deinit();
    
    var success_fields = [_]ast.Field{
        .{ .name = "value", .type = "i32" },
        .{ .name = "message", .type = "[]const u8" },
    };
    
    var branches = [_]ast.Branch{
        .{
            .name = "success",
            .payload = ast.Shape{ .fields = &success_fields },
        },
    };
    
    const event_decl = ast.EventDecl{
        .path = ast.DottedPath{ .segments = &[_][]const u8{ "test", "event" } },
        .input_shape = null,
        .branches = &branches,
    };
    
    try registry.registerEvent("test.event", &event_decl);
    
    // Create type context
    var ctx = try TypeContext.init(allocator, &registry);
    defer ctx.deinit();
    
    // Enter a continuation with binding
    try ctx.enterContinuation("test.event", "success", "s");
    
    // Resolve field access
    const value_type = try ctx.resolveFieldAccess("s.value");
    try std.testing.expectEqualSlices(u8, value_type, "i32");
    
    const message_type = try ctx.resolveFieldAccess("s.message");
    try std.testing.expectEqualSlices(u8, message_type, "[]const u8");
}

test "type context literal inference" {
    const allocator = std.testing.allocator;
    var registry = type_registry.TypeRegistry.init(allocator);
    defer registry.deinit();
    
    var ctx = try TypeContext.init(allocator, &registry);
    defer ctx.deinit();
    
    // Test string literal
    const string_type = try ctx.inferType("\"hello\"");
    try std.testing.expectEqualSlices(u8, string_type, "[]const u8");
    
    // Test integer literal
    const int_type = try ctx.inferType("42");
    try std.testing.expectEqualSlices(u8, int_type, "i32");
    
    // Test float literal
    const float_type = try ctx.inferType("3.14");
    try std.testing.expectEqualSlices(u8, float_type, "f64");
    
    // Test negative number
    const neg_type = try ctx.inferType("-10");
    try std.testing.expectEqualSlices(u8, neg_type, "i32");
}