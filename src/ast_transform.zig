const std = @import("std");
const ast = @import("ast");

/// AST Transformation Infrastructure
/// Provides mutation primitives and context for safely transforming AST nodes

/// Core transformation context for tracking state during AST mutations
pub const TransformContext = struct {
    allocator: std.mem.Allocator,
    original_ast: *const ast.Program,
    current_ast: *ast.Program,
    parent_stack: std.ArrayList(*ast.Item),
    transforms_applied: std.StringHashMap(void),
    symbol_table: SymbolTable,
    
    pub fn init(allocator: std.mem.Allocator, source_file: *ast.Program) !TransformContext {
        var ctx = TransformContext{
            .allocator = allocator,
            .original_ast = source_file,
            .current_ast = source_file,
            .parent_stack = try std.ArrayList(*ast.Item).initCapacity(allocator, 0),
            .transforms_applied = std.StringHashMap(void).init(allocator),
            .symbol_table = try SymbolTable.init(allocator),
        };
        
        // Build symbol table from AST
        try ctx.symbol_table.buildFrom(source_file);
        
        return ctx;
    }
    
    pub fn deinit(self: *TransformContext) void {
        self.parent_stack.deinit(self.allocator);
        self.transforms_applied.deinit();
        self.symbol_table.deinit();
    }
    
    /// Track that we're entering a node during traversal
    pub fn pushParent(self: *TransformContext, item: *ast.Item) !void {
        try self.parent_stack.append(self.allocator, item);
    }
    
    /// Track that we're leaving a node during traversal
    pub fn popParent(self: *TransformContext) void {
        _ = self.parent_stack.pop();
    }
    
    /// Get the current parent node
    pub fn currentParent(self: *TransformContext) ?*ast.Item {
        if (self.parent_stack.items.len == 0) return null;
        return self.parent_stack.items[self.parent_stack.items.len - 1];
    }
    
    /// Check if a transformation has already been applied
    pub fn hasTransformed(self: *TransformContext, key: []const u8) bool {
        return self.transforms_applied.contains(key);
    }
    
    /// Mark a transformation as applied
    pub fn markTransformed(self: *TransformContext, key: []const u8) !void {
        try self.transforms_applied.put(key, {});
    }
    
    /// Check if an event can be safely inlined
    pub fn canInline(self: *TransformContext, event_path: ast.DottedPath) bool {
        const info = self.symbol_table.getEventInfo(event_path) orelse return false;
        
        // Can inline if:
        // - Has a proc implementation (not subflow)
        // - Is not recursive
        // - Is small (heuristic: less than 10 lines)
        return info.has_proc and 
               !info.is_recursive and 
               info.size_estimate < 10;
    }
};

/// Symbol table for tracking relationships between events, procs, and flows
pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    events: std.StringHashMap(EventInfo),
    procs: std.StringHashMap(ProcInfo),
    
    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        return .{
            .allocator = allocator,
            .events = std.StringHashMap(EventInfo).init(allocator),
            .procs = std.StringHashMap(ProcInfo).init(allocator),
        };
    }
    
    pub fn deinit(self: *SymbolTable) void {
        self.events.deinit();
        self.procs.deinit();
    }
    
    pub fn buildFrom(self: *SymbolTable, source_file: *const ast.Program) !void {
        for (source_file.items) |item| {
            switch (item) {
                .event_decl => |event| {
                    const path_str = try pathToString(self.allocator, event.path);
                    try self.events.put(path_str, EventInfo{
                        .path = event.path,
                        .has_proc = false,
                        .has_subflow = false,
                        .is_recursive = false,
                        .size_estimate = 0,
                    });
                },
                .proc_decl => |proc| {
                    const path_str = try pathToString(self.allocator, proc.path);
                    
                    // Mark that this event has a proc
                    if (self.events.getPtr(path_str)) |info| {
                        info.has_proc = true;
                        info.size_estimate = estimateProcSize(proc.body);
                    }
                    
                    try self.procs.put(path_str, ProcInfo{
                        .path = proc.path,
                        .body = proc.body,
                    });
                },
                .subflow_impl => |subflow| {
                    const path_str = try pathToString(self.allocator, subflow.event_path);
                    if (self.events.getPtr(path_str)) |info| {
                        info.has_subflow = true;
                    }
                },
                else => {},
            }
        }
    }
    
    pub fn getEventInfo(self: *SymbolTable, path: ast.DottedPath) ?EventInfo {
        const path_str = pathToString(self.allocator, path) catch return null;
        return self.events.get(path_str);
    }
    
    fn estimateProcSize(body: []const u8) usize {
        // Simple heuristic: count lines
        var lines: usize = 0;
        for (body) |c| {
            if (c == '\n') lines += 1;
        }
        return lines;
    }
};

pub const EventInfo = struct {
    path: ast.DottedPath,
    has_proc: bool,
    has_subflow: bool,
    is_recursive: bool,
    size_estimate: usize,
};

pub const ProcInfo = struct {
    path: ast.DottedPath,
    body: []const u8,
};

/// Convert DottedPath to string for use as hashmap key
fn pathToString(allocator: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    for (path.segments, 0..) |segment, i| {
        if (i > 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, segment);
    }
    return try buf.toOwnedSlice(allocator);
}

// ============================================================================
// AST Mutation Primitives
// ============================================================================

/// Clone an AST node (deep copy)
pub fn cloneNode(allocator: std.mem.Allocator, node: ast.Item) !ast.Item {
    switch (node) {
        .event_decl => |event| {
            return .{ .event_decl = try cloneEvent(allocator, event) };
        },
        .proc_decl => |proc| {
            return .{ .proc_decl = try cloneProc(allocator, proc) };
        },
        .flow => |flow| {
            return .{ .flow = try cloneFlow(allocator, flow) };
        },
        .host_line => |line| {
            return .{ .host_line = try allocator.dupe(u8, line) };
        },
        else => return node, // TODO: Implement other node types
    }
}

fn cloneEvent(allocator: std.mem.Allocator, event: ast.EventDecl) !ast.EventDecl {
    var branches = try allocator.alloc(ast.Branch, event.branches.len);
    for (event.branches, 0..) |branch, i| {
        branches[i] = try cloneBranch(allocator, branch);
    }
    
    return .{
        .path = try clonePath(allocator, event.path),
        .input = try cloneShape(allocator, event.input),
        .branches = branches,
        .is_public = event.is_public,
    };
}

fn cloneProc(allocator: std.mem.Allocator, proc: ast.ProcDecl) !ast.ProcDecl {
    // Clone annotations
    var annotations = try allocator.alloc([]const u8, proc.annotations.len);
    for (proc.annotations, 0..) |ann, i| {
        annotations[i] = try allocator.dupe(u8, ann);
    }

    // Clone inline flows
    var inline_flows = try allocator.alloc(ast.Flow, proc.inline_flows.len);
    for (proc.inline_flows, 0..) |flow, i| {
        inline_flows[i] = try cloneFlow(allocator, flow);
    }

    return .{
        .path = try clonePath(allocator, proc.path),
        .body = try allocator.dupe(u8, proc.body),
        .inline_flows = inline_flows,
        .annotations = annotations,
        .target = if (proc.target) |t| try allocator.dupe(u8, t) else null,
        .location = proc.location,
        .module = try allocator.dupe(u8, proc.module),
    };
}

fn cloneFlow(allocator: std.mem.Allocator, flow: ast.Flow) !ast.Flow {
    return .{
        .invocation = try cloneInvocation(allocator, flow.invocation),
        .continuations = try cloneContinuations(allocator, flow.continuations),
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
        .post_label = if (flow.post_label) |l| try allocator.dupe(u8, l) else null,
    };
}

fn clonePath(allocator: std.mem.Allocator, path: ast.DottedPath) !ast.DottedPath {
    var segments = try allocator.alloc([]const u8, path.segments.len);
    for (path.segments, 0..) |segment, i| {
        segments[i] = try allocator.dupe(u8, segment);
    }
    return .{ .segments = segments };
}

fn cloneShape(allocator: std.mem.Allocator, shape: ast.Shape) !ast.Shape {
    var fields = try allocator.alloc(ast.Field, shape.fields.len);
    for (shape.fields, 0..) |field, i| {
        fields[i] = .{
            .name = try allocator.dupe(u8, field.name),
            .type = try allocator.dupe(u8, field.type),
        };
    }
    return .{ .fields = fields };
}

fn cloneBranch(allocator: std.mem.Allocator, branch: ast.Branch) !ast.Branch {
    return .{
        .name = try allocator.dupe(u8, branch.name),
        .payload = try cloneShape(allocator, branch.payload),
        .is_deferred = branch.is_deferred,
    };
}

fn cloneInvocation(allocator: std.mem.Allocator, invocation: ast.Invocation) !ast.Invocation {
    var args = try allocator.alloc(ast.Arg, invocation.args.len);
    for (invocation.args, 0..) |arg, i| {
        args[i] = .{
            .name = try allocator.dupe(u8, arg.name),
            .value = try allocator.dupe(u8, arg.value),
        };
    }
    
    return .{
        .path = try clonePath(allocator, invocation.path),
        .args = args,
    };
}

fn cloneArgs(allocator: std.mem.Allocator, args: []ast.Arg) ![]ast.Arg {
    var result = try allocator.alloc(ast.Arg, args.len);
    for (args, 0..) |arg, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, arg.name),
            .value = try allocator.dupe(u8, arg.value),
        };
    }
    return result;
}

fn cloneFields(allocator: std.mem.Allocator, fields: []ast.Field) ![]ast.Field {
    var result = try allocator.alloc(ast.Field, fields.len);
    for (fields, 0..) |field, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, field.name),
            .type = try allocator.dupe(u8, field.type),
        };
    }
    return result;
}

fn cloneSteps(allocator: std.mem.Allocator, steps: []ast.Step) ![]ast.Step {
    var result = try allocator.alloc(ast.Step, steps.len);
    for (steps, 0..) |step, i| {
        result[i] = try cloneStep(allocator, step);
    }
    return result;
}

fn cloneStep(allocator: std.mem.Allocator, step: ast.Step) !ast.Step {
    switch (step) {
        .invocation => |inv| return .{ .invocation = try cloneInvocation(allocator, inv) },
        .label_apply => |label| return .{ .label_apply = try allocator.dupe(u8, label) },
        .label_with_invocation => |lwi| return .{ .label_with_invocation = .{
            .label = try allocator.dupe(u8, lwi.label),
            .invocation = try cloneInvocation(allocator, lwi.invocation),
        }},
        .label_jump => |lj| return .{ .label_jump = .{
            .label = try allocator.dupe(u8, lj.label),
            .args = try cloneArgs(allocator, lj.args),
        }},
        .terminal => return .terminal,
        .deref => |d| return .{ .deref = .{
            .target = try allocator.dupe(u8, d.target),
            .args = if (d.args) |args| try cloneArgs(allocator, args) else null,
        }},
        .branch_constructor => |bc| return .{ .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, bc.branch_name),
            .fields = try cloneFields(allocator, bc.fields),
        }},
    }
}

fn cloneContinuations(allocator: std.mem.Allocator, continuations: []ast.Continuation) ![]ast.Continuation {
    var result = try allocator.alloc(ast.Continuation, continuations.len);
    for (continuations, 0..) |cont, i| {
        result[i] = .{
            .branch = try allocator.dupe(u8, cont.branch),
            .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
            .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
            .pipeline = try cloneSteps(allocator, cont.pipeline),
            .indent = cont.indent,
            .nested = try cloneContinuations(allocator, cont.nested),
        };
    }
    return result;
}

// These types are no longer in the AST structure but kept for reference
// The actual Step union handles these cases directly

/// Replace a node in the AST
pub fn replaceNode(ctx: *TransformContext, index: usize, new_node: ast.Item) !void {
    if (index >= ctx.current_ast.items.len) return error.IndexOutOfBounds;
    
    // Free the old node
    ctx.current_ast.items[index].deinit(ctx.allocator);
    
    // Replace with new node
    ctx.current_ast.items[index] = new_node;
}

/// Insert a node after the specified index
pub fn insertAfter(ctx: *TransformContext, index: usize, new_node: ast.Item) !void {
    if (index >= ctx.current_ast.items.len) return error.IndexOutOfBounds;
    
    // Allocate new array with space for one more item
    var new_items = try ctx.allocator.alloc(ast.Item, ctx.current_ast.items.len + 1);
    
    // Copy items before insertion point
    for (ctx.current_ast.items[0..index + 1], 0..) |item, i| {
        new_items[i] = item;
    }
    
    // Insert new node
    new_items[index + 1] = new_node;
    
    // Copy items after insertion point
    for (ctx.current_ast.items[index + 1..], 0..) |item, i| {
        new_items[index + 2 + i] = item;
    }
    
    // Free old array and update
    ctx.allocator.free(ctx.current_ast.items);
    ctx.current_ast.items = new_items;
}

/// Remove a node from the AST
pub fn removeNode(ctx: *TransformContext, index: usize) !void {
    if (index >= ctx.current_ast.items.len) return error.IndexOutOfBounds;
    
    // Free the node being removed
    ctx.current_ast.items[index].deinit(ctx.allocator);
    
    // Allocate new array with one less item
    var new_items = try ctx.allocator.alloc(ast.Item, ctx.current_ast.items.len - 1);
    
    // Copy items before removal point
    for (ctx.current_ast.items[0..index], 0..) |item, i| {
        new_items[i] = item;
    }
    
    // Copy items after removal point
    for (ctx.current_ast.items[index + 1..], 0..) |item, i| {
        new_items[index + i] = item;
    }
    
    // Free old array and update
    ctx.allocator.free(ctx.current_ast.items);
    ctx.current_ast.items = new_items;
}

/// Find the index of a specific item in the AST
pub fn findNodeIndex(ctx: *TransformContext, target: *ast.Item) ?usize {
    for (ctx.current_ast.items, 0..) |*item, i| {
        if (item == target) return i;
    }
    return null;
}

/// Replace an event invocation with its proc implementation inline
pub fn inlineEvent(ctx: *TransformContext, invocation: *ast.Invocation, proc: *ast.ProcDecl) !void {
    // This is a complex transformation that would:
    // 1. Parse the proc body to extract the Zig code
    // 2. Replace parameter references (e.field) with invocation arguments
    // 3. Convert return statements to appropriate continuations
    // 4. Insert the transformed code at the invocation site
    
    // For now, this is a placeholder for the actual implementation
    _ = ctx;
    _ = invocation;
    _ = proc;
    
    // TODO: Implement actual inlining logic
}