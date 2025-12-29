const std = @import("std");
const ast = @import("ast");

/// Expression Code Generator
/// Converts AST expressions to Zig code
pub const ExpressionCodegen = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) ExpressionCodegen {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
        };
    }
    
    pub fn deinit(self: *ExpressionCodegen) void {
        self.buffer.deinit(self.allocator);
    }
    
    /// Generate Zig code for an expression
    pub fn generate(self: *ExpressionCodegen, expr: *const ast.Expression) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        try self.generateExpr(expr);
        return try self.allocator.dupe(u8, self.buffer.items);
    }
    
    fn generateExpr(self: *ExpressionCodegen, expr: *const ast.Expression) anyerror!void {
        switch (expr.node) {
            .literal => |lit| try self.generateLiteral(lit),
            .identifier => |id| try self.buffer.appendSlice(self.allocator, id),
            .binary => |bin| try self.generateBinary(bin),
            .unary => |un| try self.generateUnary(un),
            .field_access => |fa| try self.generateFieldAccess(fa),
            .grouped => |g| {
                try self.buffer.append(self.allocator, '(');
                try self.generateExpr(g);
                try self.buffer.append(self.allocator, ')');
            },
        }
    }
    
    fn generateLiteral(self: *ExpressionCodegen, lit: ast.Literal) !void {
        switch (lit) {
            .number => |n| try self.buffer.appendSlice(self.allocator, n),
            .string => |s| {
                try self.buffer.append(self.allocator, '"');
                // TODO: Escape string properly
                try self.buffer.appendSlice(self.allocator, s);
                try self.buffer.append(self.allocator, '"');
            },
            .boolean => |b| try self.buffer.appendSlice(self.allocator, if (b) "true" else "false"),
        }
    }
    
    fn generateBinary(self: *ExpressionCodegen, bin: ast.BinaryOp) !void {
        // Generate left operand
        try self.generateExpr(bin.left);
        
        // Generate operator
        try self.buffer.append(self.allocator, ' ');
        try self.buffer.appendSlice(self.allocator, binaryOpToString(bin.op));
        try self.buffer.append(self.allocator, ' ');
        
        // Generate right operand
        try self.generateExpr(bin.right);
    }
    
    fn generateUnary(self: *ExpressionCodegen, un: ast.UnaryOp) !void {
        // Generate operator
        try self.buffer.appendSlice(self.allocator, unaryOpToString(un.op));
        
        // Generate operand (with grouping if needed)
        const needs_grouping = switch (un.operand.node) {
            .binary => true,
            else => false,
        };
        
        if (needs_grouping) try self.buffer.append(self.allocator, '(');
        try self.generateExpr(un.operand);
        if (needs_grouping) try self.buffer.append(self.allocator, ')');
    }
    
    fn generateFieldAccess(self: *ExpressionCodegen, fa: ast.FieldAccess) !void {
        try self.generateExpr(fa.object);
        try self.buffer.append(self.allocator, '.');
        try self.buffer.appendSlice(self.allocator, fa.field);
    }
    
    fn binaryOpToString(op: ast.BinaryOperator) []const u8 {
        return switch (op) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .modulo => "%",
            .equal => "==",
            .not_equal => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .and_op => "and",
            .or_op => "or",
            .string_concat => "++",
        };
    }
    
    fn unaryOpToString(op: ast.UnaryOperator) []const u8 {
        return switch (op) {
            .not => "!",
            .negate => "-",
        };
    }
};

/// Generate a where clause condition as an if statement
pub fn generateWhereCondition(
    allocator: std.mem.Allocator,
    condition_expr: *const ast.Expression,
    _: ?[]const u8, // binding - TODO: use for field access replacement
) ![]const u8 {
    var codegen = ExpressionCodegen.init(allocator);
    defer codegen.deinit();
    
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer result.deinit(allocator);
    
    // Start the if statement
    try result.appendSlice(allocator, "if (");
    
    // Generate the condition, replacing identifiers with binding if needed
    const condition = try codegen.generate(condition_expr);
    defer allocator.free(condition);
    
    // If we have a binding, we might need to prefix field accesses
    // For now, just use the condition as-is
    try result.appendSlice(allocator, condition);
    
    try result.appendSlice(allocator, ")");
    
    return try allocator.dupe(u8, result.items);
}

/// Generate code for a continuation with where clause
pub fn generateContinuationWithWhere(
    allocator: std.mem.Allocator,
    cont: *const ast.Continuation,
    indent: usize,
) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
    defer result.deinit(allocator);
    
    // Add indentation
    try result.appendNTimes(allocator, ' ', indent);
    
    // Generate the branch match
    try result.append(allocator, '.');
    try result.appendSlice(allocator, cont.branch);
    try result.appendSlice(allocator, " => ");
    
    if (cont.binding) |bind| {
        try result.append(allocator, '|');
        try result.appendSlice(allocator, bind);
        try result.appendSlice(allocator, "| ");
    }
    
    try result.appendSlice(allocator, "{\n");
    
    // If there's a where condition, generate the if statement
    if (cont.condition_expr) |expr| {
        try result.appendNTimes(allocator, ' ', indent + 4);
        
        const where_cond = try generateWhereCondition(allocator, expr, cont.binding);
        defer allocator.free(where_cond);
        
        try result.appendSlice(allocator, where_cond);
        try result.appendSlice(allocator, " {\n");
        
        // Generate the pipeline inside the if
        try result.appendNTimes(allocator, ' ', indent + 8);
        try result.appendSlice(allocator, "// Continue to next step\n");
        
        try result.appendNTimes(allocator, ' ', indent + 4);
        try result.appendSlice(allocator, "}\n");
    } else {
        // No where clause, generate pipeline directly
        try result.appendNTimes(allocator, ' ', indent + 4);
        try result.appendSlice(allocator, "// Pipeline steps here\n");
    }
    
    try result.appendNTimes(allocator, ' ', indent);
    try result.appendSlice(allocator, "},\n");
    
    return try allocator.dupe(u8, result.items);
}