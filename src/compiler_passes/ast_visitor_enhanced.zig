const std = @import("std");
const ast = @import("ast");

/// Enhanced AST Visitor Framework
/// Provides easy traversal patterns for compiler pass writers
/// 
/// Features:
/// - Context passing through visits
/// - Optional method overriding (only implement what you need)
/// - Pre/post visit hooks for each node type
/// - Built-in traversal patterns (depth-first, breadth-first)
/// - Error propagation with proper cleanup

/// Visitor context that flows through traversal
pub fn VisitorContext(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        user_data: T,
        depth: usize = 0,
        path: std.ArrayList([]const u8),
        
        pub fn init(allocator: std.mem.Allocator, user_data: T) !@This() {
            return .{
                .allocator = allocator,
                .user_data = user_data,
                .depth = 0,
                .path = std.ArrayList([]const u8).init(allocator),
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.path.deinit();
        }
        
        pub fn pushPath(self: *@This(), name: []const u8) !void {
            try self.path.append(name);
            self.depth += 1;
        }
        
        pub fn popPath(self: *@This()) void {
            _ = self.path.pop();
            self.depth -= 1;
        }
        
        pub fn getCurrentPath(self: *@This()) []const []const u8 {
            return self.path.items;
        }
    };
}

/// Base visitor trait that can be implemented
pub fn Visitor(comptime Context: type) type {
    return struct {
        const Self = @This();
        
        // Virtual function table for dynamic dispatch
        vtable: struct {
            // Source file level
            visitSourceFile: ?*const fn (*Self, *Context, *ast.Program) anyerror!void = null,
            postVisitSourceFile: ?*const fn (*Self, *Context, *ast.Program) anyerror!void = null,
            
            // Module level (removed - no longer in AST)
            
            // Event declarations
            visitEventDecl: ?*const fn (*Self, *Context, *ast.EventDecl) anyerror!void = null,
            postVisitEventDecl: ?*const fn (*Self, *Context, *ast.EventDecl) anyerror!void = null,
            
            // Proc declarations
            visitProcDecl: ?*const fn (*Self, *Context, *ast.ProcDecl) anyerror!void = null,
            postVisitProcDecl: ?*const fn (*Self, *Context, *ast.ProcDecl) anyerror!void = null,
            
            // Flows
            visitFlow: ?*const fn (*Self, *Context, *ast.Flow) anyerror!void = null,
            postVisitFlow: ?*const fn (*Self, *Context, *ast.Flow) anyerror!void = null,
            
            // Event taps
            visitEventTap: ?*const fn (*Self, *Context, *ast.EventTap) anyerror!void = null,
            postVisitEventTap: ?*const fn (*Self, *Context, *ast.EventTap) anyerror!void = null,
            
            // Shapes
            visitShape: ?*const fn (*Self, *Context, *ast.Shape) anyerror!void = null,
            postVisitShape: ?*const fn (*Self, *Context, *ast.Shape) anyerror!void = null,
            
            // Fields (part of shapes)
            visitField: ?*const fn (*Self, *Context, *ast.Field) anyerror!void = null,
            postVisitField: ?*const fn (*Self, *Context, *ast.Field) anyerror!void = null,
        },
        
        // User data for the visitor implementation
        impl_data: *anyopaque,
    };
}

/// AST Walker that uses the visitor pattern
pub fn Walker(comptime UserData: type) type {
    return struct {
        const Self = @This();
        const Context = VisitorContext(UserData);
        const VisitorType = Visitor(Context);
        
        visitor: VisitorType,
        context: Context,
        
        pub fn init(allocator: std.mem.Allocator, user_data: UserData, visitor: VisitorType) !Self {
            return .{
                .visitor = visitor,
                .context = try Context.init(allocator, user_data),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.context.deinit();
        }
        
        /// Walk the entire AST starting from source file
        pub fn walk(self: *Self, source_file: *ast.Program) !void {
            try self.walkSourceFile(source_file);
        }
        
        fn walkSourceFile(self: *Self, source_file: *ast.Program) !void {
            // Pre-visit
            if (self.visitor.vtable.visitSourceFile) |visit| {
                try visit(&self.visitor, &self.context, source_file);
            }
            
            // Walk items
            for (source_file.items) |*item| {
                try self.walkItem(item);
            }
            
            // Post-visit
            if (self.visitor.vtable.postVisitSourceFile) |postVisit| {
                try postVisit(&self.visitor, &self.context, source_file);
            }
        }
        
        fn walkItem(self: *Self, item: *ast.Item) !void {
            switch (item.*) {
                .event_decl => |*event| try self.walkEventDecl(event),
                .proc_decl => |*proc| try self.walkProcDecl(proc),
                .flow => |*flow| try self.walkFlow(flow),
                .event_tap => |*tap| try self.walkEventTap(tap),
                .label_decl => {}, // TODO: Handle labels
                .immediate_impl => {}, // Immediate impls are leaf nodes
                .import_decl => {}, // TODO: Handle imports
                .host_line => {}, // Skip host lines
            }
        }
        
        fn walkEventDecl(self: *Self, event: *ast.EventDecl) !void {
            if (self.visitor.vtable.visitEventDecl) |visit| {
                try visit(&self.visitor, &self.context, event);
            }
            
            const name = pathToString(event.path) catch "unknown";
            defer if (!std.mem.eql(u8, name, "unknown")) self.context.allocator.free(name);
            try self.context.pushPath(name);
            defer self.context.popPath();
            
            // Walk shape if present
            if (event.shape) |*shape| {
                try self.walkShape(shape);
            }
            
            // Walk branches
            for (event.branches) |*branch| {
                if (branch.shape) |*shape| {
                    try self.walkShape(shape);
                }
            }
            
            if (self.visitor.vtable.postVisitEventDecl) |postVisit| {
                try postVisit(&self.visitor, &self.context, event);
            }
        }
        
        fn walkProcDecl(self: *Self, proc: *ast.ProcDecl) !void {
            if (self.visitor.vtable.visitProcDecl) |visit| {
                try visit(&self.visitor, &self.context, proc);
            }
            
            const name = pathToString(proc.path) catch "unknown";
            defer if (!std.mem.eql(u8, name, "unknown")) self.context.allocator.free(name);
            try self.context.pushPath(name);
            defer self.context.popPath();
            
            // Walk inline flows
            for (proc.inline_flows) |*flow| {
                try self.walkFlow(flow);
            }
            
            if (self.visitor.vtable.postVisitProcDecl) |postVisit| {
                try postVisit(&self.visitor, &self.context, proc);
            }
        }
        
        fn walkFlow(self: *Self, flow: *ast.Flow) !void {
            if (self.visitor.vtable.visitFlow) |visit| {
                try visit(&self.visitor, &self.context, flow);
            }
            
            // Walk source binding if present
            if (flow.source_binding) |*binding| {
                try self.walkBinding(binding);
            }
            
            // Walk each step
            for (flow.steps) |*step| {
                switch (step.*) {
                    .event_call => |*call| {
                        if (call.args) |*shape| {
                            try self.walkShape(shape);
                        }
                    },
                    .match_branch => |*branch| {
                        try self.walkBinding(&branch.binding);
                        // TODO: Handle immediate return if needed
                    },
                }
            }
            
            if (self.visitor.vtable.postVisitFlow) |postVisit| {
                try postVisit(&self.visitor, &self.context, flow);
            }
        }
        
        fn walkEventTap(self: *Self, tap: *ast.EventTap) !void {
            if (self.visitor.vtable.visitEventTap) |visit| {
                try visit(&self.visitor, &self.context, tap);
            }
            
            try self.walkFlow(&tap.flow);
            
            if (self.visitor.vtable.postVisitEventTap) |postVisit| {
                try postVisit(&self.visitor, &self.context, tap);
            }
        }
        
        fn walkShape(self: *Self, shape: *ast.Shape) !void {
            if (self.visitor.vtable.visitShape) |visit| {
                try visit(&self.visitor, &self.context, shape);
            }
            
            for (shape.fields) |field| {
                var field_type = field.type_;
                try self.walkType(&field_type);
            }
            
            if (self.visitor.vtable.postVisitShape) |postVisit| {
                try postVisit(&self.visitor, &self.context, shape);
            }
        }
        
        fn walkType(self: *Self, type_: *ast.Type) !void {
            if (self.visitor.vtable.visitType) |visit| {
                try visit(&self.visitor, &self.context, type_);
            }
            
            // Recursively walk composite types
            switch (type_.*) {
                .array => |*arr| try self.walkType(arr.element_type),
                .optional => |*opt| try self.walkType(opt),
                .shape => |*shape| try self.walkShape(shape),
                else => {},
            }
            
            if (self.visitor.vtable.postVisitType) |postVisit| {
                try postVisit(&self.visitor, &self.context, type_);
            }
        }
        
        fn walkBinding(self: *Self, binding: *ast.Binding) !void {
            if (self.visitor.vtable.visitBinding) |visit| {
                try visit(&self.visitor, &self.context, binding);
            }
            
            if (self.visitor.vtable.postVisitBinding) |postVisit| {
                try postVisit(&self.visitor, &self.context, binding);
            }
        }
        
        fn walkImmediateReturn(self: *Self, ret: *ast.ImmediateReturn) !void {
            if (self.visitor.vtable.visitImmediateReturn) |visit| {
                try visit(&self.visitor, &self.context, ret);
            }
            
            if (ret.shape) |*shape| {
                try self.walkShape(shape);
            }
            
            if (self.visitor.vtable.postVisitImmediateReturn) |postVisit| {
                try postVisit(&self.visitor, &self.context, ret);
            }
        }
        
        fn pathToString(path: ast.DottedPath) ![]const u8 {
            var buf = std.ArrayList(u8).init(std.heap.page_allocator);
            defer buf.deinit();
            
            for (path.segments, 0..) |seg, i| {
                if (i > 0) try buf.append('.');
                try buf.appendSlice(seg);
            }
            
            return try std.heap.page_allocator.dupe(u8, buf.items);
        }
    };
}

/// Helper to create a visitor from a struct with methods
pub fn makeVisitor(comptime T: type, comptime Context: type, impl: *T) Visitor(Context) {
    const has_visitSourceFile = @hasDecl(T, "visitSourceFile");
    const has_postVisitSourceFile = @hasDecl(T, "postVisitSourceFile");
    const has_visitEventDecl = @hasDecl(T, "visitEventDecl");
    const has_postVisitEventDecl = @hasDecl(T, "postVisitEventDecl");
    const has_visitProcDecl = @hasDecl(T, "visitProcDecl");
    const has_postVisitProcDecl = @hasDecl(T, "postVisitProcDecl");
    const has_visitFlow = @hasDecl(T, "visitFlow");
    const has_postVisitFlow = @hasDecl(T, "postVisitFlow");
    const has_visitEventTap = @hasDecl(T, "visitEventTap");
    const has_postVisitEventTap = @hasDecl(T, "postVisitEventTap");
    const has_visitShape = @hasDecl(T, "visitShape");
    const has_postVisitShape = @hasDecl(T, "postVisitShape");
    const has_visitType = @hasDecl(T, "visitType");
    const has_postVisitType = @hasDecl(T, "postVisitType");
    const has_visitImmediateReturn = @hasDecl(T, "visitImmediateReturn");
    const has_postVisitImmediateReturn = @hasDecl(T, "postVisitImmediateReturn");
    const has_visitBinding = @hasDecl(T, "visitBinding");
    const has_postVisitBinding = @hasDecl(T, "postVisitBinding");
    
    return Visitor(Context){
        .vtable = .{
            .visitSourceFile = if (has_visitSourceFile) T.visitSourceFile else null,
            .postVisitSourceFile = if (has_postVisitSourceFile) T.postVisitSourceFile else null,
            .visitEventDecl = if (has_visitEventDecl) T.visitEventDecl else null,
            .postVisitEventDecl = if (has_postVisitEventDecl) T.postVisitEventDecl else null,
            .visitProcDecl = if (has_visitProcDecl) T.visitProcDecl else null,
            .postVisitProcDecl = if (has_postVisitProcDecl) T.postVisitProcDecl else null,
            .visitFlow = if (has_visitFlow) T.visitFlow else null,
            .postVisitFlow = if (has_postVisitFlow) T.postVisitFlow else null,
            .visitEventTap = if (has_visitEventTap) T.visitEventTap else null,
            .postVisitEventTap = if (has_postVisitEventTap) T.postVisitEventTap else null,
            .visitShape = if (has_visitShape) T.visitShape else null,
            .postVisitShape = if (has_postVisitShape) T.postVisitShape else null,
            .visitType = if (has_visitType) T.visitType else null,
            .postVisitType = if (has_postVisitType) T.postVisitType else null,
            .visitImmediateReturn = if (has_visitImmediateReturn) T.visitImmediateReturn else null,
            .postVisitImmediateReturn = if (has_postVisitImmediateReturn) T.postVisitImmediateReturn else null,
            .visitBinding = if (has_visitBinding) T.visitBinding else null,
            .postVisitBinding = if (has_postVisitBinding) T.postVisitBinding else null,
        },
        .impl_data = @ptrCast(impl),
    };
}

// Example visitor implementation for testing
pub const ExampleCountingVisitor = struct {
    allocator: std.mem.Allocator,
    event_count: usize = 0,
    proc_count: usize = 0,
    flow_count: usize = 0,
    tap_count: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) ExampleCountingVisitor {
        return .{ .allocator = allocator };
    }
    
    pub fn visitEventDecl(self: *ExampleCountingVisitor, ctx: anytype, event: *ast.EventDecl) !void {
        _ = ctx;
        _ = event;
        self.event_count += 1;
    }
    
    pub fn visitProcDecl(self: *ExampleCountingVisitor, ctx: anytype, proc: *ast.ProcDecl) !void {
        _ = ctx;
        _ = proc;
        self.proc_count += 1;
    }
    
    pub fn visitFlow(self: *ExampleCountingVisitor, ctx: anytype, flow: *ast.Flow) !void {
        _ = ctx;
        _ = flow;
        self.flow_count += 1;
    }
    
    pub fn visitEventTap(self: *ExampleCountingVisitor, ctx: anytype, tap: *ast.EventTap) !void {
        _ = ctx;
        _ = tap;
        self.tap_count += 1;
    }
};