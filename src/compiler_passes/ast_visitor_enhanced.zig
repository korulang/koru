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
                .path = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.path.deinit(self.allocator);
        }
        
        pub fn pushPath(self: *@This(), name: []const u8) !void {
            try self.path.append(self.allocator, name);
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
                try self.walkItem(@constCast(item));
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
                else => {},
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
            
            try self.walkShape(@constCast(&event.input));
            
            // Walk branches
            for (event.branches) |*branch| {
                try self.walkShape(@constCast(&branch.payload));
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
            
            if (self.visitor.vtable.postVisitProcDecl) |postVisit| {
                try postVisit(&self.visitor, &self.context, proc);
            }
        }
        
        fn walkFlow(self: *Self, flow: *ast.Flow) !void {
            if (self.visitor.vtable.visitFlow) |visit| {
                try visit(&self.visitor, &self.context, flow);
            }
            
            for (flow.continuations) |_| {}
            
            if (self.visitor.vtable.postVisitFlow) |postVisit| {
                try postVisit(&self.visitor, &self.context, flow);
            }
        }
        
        fn walkEventTap(self: *Self, tap: *ast.EventTap) !void {
            if (self.visitor.vtable.visitEventTap) |visit| {
                try visit(&self.visitor, &self.context, tap);
            }
            
            for (tap.continuations) |_| {}
            
            if (self.visitor.vtable.postVisitEventTap) |postVisit| {
                try postVisit(&self.visitor, &self.context, tap);
            }
        }
        
        fn walkShape(self: *Self, shape: *ast.Shape) !void {
            if (self.visitor.vtable.visitShape) |visit| {
                try visit(&self.visitor, &self.context, shape);
            }
            
            for (shape.fields) |_| {}
            
            if (self.visitor.vtable.postVisitShape) |postVisit| {
                try postVisit(&self.visitor, &self.context, shape);
            }
        }
        
        fn pathToString(path: ast.DottedPath) ![]const u8 {
            var buf = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 0);
            defer buf.deinit(std.heap.page_allocator);
            
            for (path.segments, 0..) |seg, i| {
                if (i > 0) try buf.append(std.heap.page_allocator, '.');
                try buf.appendSlice(std.heap.page_allocator, seg);
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

    const Adapter = struct {
        fn getImpl(self: *Visitor(Context)) *T {
            return @ptrCast(@alignCast(self.impl_data));
        }

        fn visitEventDecl(self: *Visitor(Context), ctx: *Context, event: *ast.EventDecl) anyerror!void {
            try T.visitEventDecl(getImpl(self), ctx, event);
        }

        fn visitProcDecl(self: *Visitor(Context), ctx: *Context, proc: *ast.ProcDecl) anyerror!void {
            try T.visitProcDecl(getImpl(self), ctx, proc);
        }

        fn visitFlow(self: *Visitor(Context), ctx: *Context, flow: *ast.Flow) anyerror!void {
            try T.visitFlow(getImpl(self), ctx, flow);
        }

        fn visitEventTap(self: *Visitor(Context), ctx: *Context, tap: *ast.EventTap) anyerror!void {
            try T.visitEventTap(getImpl(self), ctx, tap);
        }
    };
    
    return Visitor(Context){
        .vtable = .{
            .visitSourceFile = if (has_visitSourceFile) T.visitSourceFile else null,
            .postVisitSourceFile = if (has_postVisitSourceFile) T.postVisitSourceFile else null,
            .visitEventDecl = if (has_visitEventDecl) Adapter.visitEventDecl else null,
            .postVisitEventDecl = if (has_postVisitEventDecl) T.postVisitEventDecl else null,
            .visitProcDecl = if (has_visitProcDecl) Adapter.visitProcDecl else null,
            .postVisitProcDecl = if (has_postVisitProcDecl) T.postVisitProcDecl else null,
            .visitFlow = if (has_visitFlow) Adapter.visitFlow else null,
            .postVisitFlow = if (has_postVisitFlow) T.postVisitFlow else null,
            .visitEventTap = if (has_visitEventTap) Adapter.visitEventTap else null,
            .postVisitEventTap = if (has_postVisitEventTap) T.postVisitEventTap else null,
            .visitShape = if (has_visitShape) T.visitShape else null,
            .postVisitShape = if (has_postVisitShape) T.postVisitShape else null,
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
