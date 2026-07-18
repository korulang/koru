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
        var event_iter = self.events.iterator();
        while (event_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        var proc_iter = self.procs.iterator();
        while (proc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.events.deinit();
        self.procs.deinit();
    }
    
    pub fn buildFrom(self: *SymbolTable, source_file: *const ast.Program) !void {
        try self.buildFromItems(source_file.items);
    }

    fn buildFromItems(self: *SymbolTable, items: []const ast.Item) !void {
        for (items) |item| {
            switch (item) {
                .event_decl => |event| {
                    const path_str = try eventKey(self.allocator, event.path);
                    try self.events.put(path_str, EventInfo{
                        .path = event.path,
                        .input = event.input,
                        .branches = event.branches,
                        .has_proc = false,
                        .has_subflow = false,
                        .is_recursive = false,
                        .size_estimate = 0,
                    });
                },
                .proc_decl => |proc| {
                    const path_str = try eventKey(self.allocator, proc.path);

                    // Mark that this event has a proc
                    if (self.events.getPtr(path_str)) |info| {
                        info.has_proc = true;
                        info.size_estimate = estimateProcSize(proc.body.text);
                    }

                    try self.procs.put(path_str, ProcInfo{
                        .path = proc.path,
                        .body = proc.body.text,
                    });
                },
                .flow => |flow| {
                    if (flow.impl_of) |impl_path| {
                        const path_str = try eventKey(self.allocator, impl_path);
                        defer self.allocator.free(path_str);
                        if (self.events.getPtr(path_str)) |info| {
                            info.has_subflow = true;
                        }
                    }
                },
                .immediate_impl => |ii| {
                    const path_str = try eventKey(self.allocator, ii.event_path);
                    defer self.allocator.free(path_str);
                    if (self.events.getPtr(path_str)) |info| {
                        info.has_subflow = true;
                    }
                },
                .module_decl => |module| {
                    // Declarations live inside modules too (the metacircular
                    // pipeline itself is a module) — recurse so lookups are
                    // whole-program.
                    try self.buildFromItems(module.items);
                },
                else => {},
            }
        }
    }

    pub fn getEventInfo(self: *SymbolTable, path: ast.DottedPath) ?EventInfo {
        const path_str = eventKey(self.allocator, path) catch return null;
        defer self.allocator.free(path_str);
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
    /// Declared input shape (references the AST; valid while the AST lives).
    input: ast.Shape = .{ .fields = &.{} },
    /// Declared branches (references the AST; valid while the AST lives).
    branches: []const ast.Branch = &.{},
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

/// Qualifier-aware hashmap key for event/proc lookup: `<qualifier>|<segments>`.
/// Same-named events in different modules must not collide once module items
/// are indexed, and post-canonicalization both decls and invocations carry the
/// module qualifier, so keying on it is symmetric.
fn eventKey(allocator: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    if (path.module_qualifier) |mq| {
        try buf.appendSlice(allocator, mq);
    }
    try buf.append(allocator, '|');
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
            return .{ .host_line = .{
                .content = try allocator.dupe(u8, line.content),
                .location = line.location,
                .module = if (line.module.len > 0) try allocator.dupe(u8, line.module) else "",
            } };
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

    const body_bindings = try allocator.alloc(ast.ScopeBinding, proc.body.scope.bindings.len);
    for (proc.body.scope.bindings, 0..) |b, i| {
        body_bindings[i] = .{
            .name = try allocator.dupe(u8, b.name),
            .type = try allocator.dupe(u8, b.type),
            .value_ref = try allocator.dupe(u8, b.value_ref),
        };
    }
    return .{
        .path = try clonePath(allocator, proc.path),
        .body = ast.Source{
            .text = try allocator.dupe(u8, proc.body.text),
            .location = proc.body.location,
            .scope = .{ .bindings = body_bindings },
            .phantom_type = if (proc.body.phantom_type) |pt| try allocator.dupe(u8, pt) else null,
        },
        .inline_flows = try cloneFlows(allocator, proc.inline_flows),
        .annotations = annotations,
        .target = if (proc.target) |t| try allocator.dupe(u8, t) else null,
        .location = proc.location,
        .module = try allocator.dupe(u8, proc.module),
    };
}

fn cloneFlows(allocator: std.mem.Allocator, flows: []const ast.Flow) ![]const ast.Flow {
    var result = try allocator.alloc(ast.Flow, flows.len);
    for (flows, 0..) |flow, i| {
        result[i] = try cloneFlow(allocator, flow);
    }
    return result;
}

fn cloneFlow(allocator: std.mem.Allocator, flow: ast.Flow) !ast.Flow {
    return .{
        .body = ast.rootSite(try cloneInvocation(allocator, flow.inv().*), try cloneContinuations(allocator, flow.body.continuations), .{ .file = "generated", .line = 0, .column = 0 }),
        .pre_label = if (flow.pre_label) |l| try allocator.dupe(u8, l) else null,
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
    // Preserve `is_wildcard` (bare `*` payload) across clones.
    return .{ .fields = fields, .is_wildcard = shape.is_wildcard };
}

fn cloneBranch(allocator: std.mem.Allocator, branch: ast.Branch) !ast.Branch {
    return .{
        .name = try allocator.dupe(u8, branch.name),
        .payload = try cloneShape(allocator, branch.payload),
        // Preserve resume type + its phantom/obligation across clones (lossy before).
        .resume_type = if (branch.resume_type) |rt| try allocator.dupe(u8, rt) else null,
        .resume_phantom = if (branch.resume_phantom) |rp| try allocator.dupe(u8, rp) else null,
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
        .source_module = if (invocation.source_module.len > 0)
            try allocator.dupe(u8, invocation.source_module)
        else
            "",
    };
}

fn cloneArgs(allocator: std.mem.Allocator, args: []const ast.Arg) ![]ast.Arg {
    var result = try allocator.alloc(ast.Arg, args.len);
    for (args, 0..) |arg, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, arg.name),
            .value = try allocator.dupe(u8, arg.value),
        };
    }
    return result;
}

fn cloneFields(allocator: std.mem.Allocator, fields: []const ast.Field) ![]ast.Field {
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
            .is_declaration = lwi.is_declaration,
        }},
        .label_jump => |lj| return .{ .label_jump = .{
            .label = try allocator.dupe(u8, lj.label),
            .args = try cloneArgs(allocator, lj.args),
        }},
        .terminal => return .terminal,
        .branch_constructor => |bc| return .{ .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, bc.branch_name),
            .fields = try cloneFields(allocator, bc.fields),
            // Preserve the single-plain-value form and its flags — a clone that
            // drops `plain_value` turns `=> failed f` into an empty record.
            .plain_value = if (bc.plain_value) |pv| try allocator.dupe(u8, pv) else null,
            .has_expressions = bc.has_expressions,
            .is_bare_return = bc.is_bare_return,
        }},
        else => return step,
    }
}

fn cloneContinuations(allocator: std.mem.Allocator, continuations: []const ast.Continuation) ![]const ast.Continuation {
    var result = try allocator.alloc(ast.Continuation, continuations.len);
    for (continuations, 0..) |cont, i| {
        const anns = if (cont.binding_annotations.len > 0) blk: {
            var list = try allocator.alloc([]const u8, cont.binding_annotations.len);
            for (cont.binding_annotations, 0..) |ann, j| {
                list[j] = try allocator.dupe(u8, ann);
            }
            break :blk list;
        } else &[_][]const u8{};
        result[i] = .{
            .branch = try allocator.dupe(u8, cont.branch),
            .binding = if (cont.binding) |b| try allocator.dupe(u8, b) else null,
            .binding_annotations = anns,
            .destructure = try ast.copyDestructure(allocator, cont.destructure),
            .binding_type = cont.binding_type,
            // Preserve the branch axis (`|` vs `!`) and catch-all markers — a
            // clone that resets `kind` would turn an effect arm into a terminal.
            .kind = cont.kind,
            .is_catchall = cont.is_catchall,
            .catchall_metatype = if (cont.catchall_metatype) |m| try allocator.dupe(u8, m) else null,
            .condition = if (cont.condition) |c| try allocator.dupe(u8, c) else null,
            .condition_expr = null,
            .node = if (cont.node) |node| try cloneStep(allocator, node) else null,
            .indent = cont.indent,
            .continuations = try cloneContinuations(allocator, cont.continuations),
            .is_transformed_subtree = cont.is_transformed_subtree,
            .location = cont.location,
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
    @constCast(&ctx.current_ast.items[index]).deinit(ctx.allocator);
    
    // Replace with new node
    @constCast(ctx.current_ast.items)[index] = new_node;
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

// ============================================================================
// Point-free pipeline + choke desugar
// ============================================================================
//
// `~run = stage-a |> stage-b | failed f => failed f` parses as a chain of
// UNNAMED continuations (branch == "") with the choke handler(s) attached at
// the innermost step. Downstream (shape/flow checkers, emitter) only knows the
// canonical explicit-continuation pyramid, so this pass rewrites the chain,
// declaration-aware:
//
//   1. Each unnamed step is renamed to the producing stage's SURVIVOR branch —
//      the one declared terminal branch LEFT after the choke handlers claim
//      theirs (the thread follows ARITY, not polarity) — bound to a fresh
//      temp, and the payload threads into the next stage's single open input
//      field.
//   2. The choke handlers replicate at EVERY stage of the chain (their reach
//      is the whole lexical block). `!` effect arms clone through unchanged.
//   3. The terminus closes the last stage's survivor into a branch
//      constructor producing the flow's own output.
//   4. A bare HEAD stage takes the flow's whole input by pun (`stage-a` →
//      `stage-a(ctx: ctx)`).
//
// If at any stage zero or more than one branch is left unclaimed — or a
// declaration can't be resolved — the chain is left UNTOUCHED and the
// downstream coverage wall (KORU022 "branch must be handled") forces explicit
// handling; the pass never guesses.
//
// Void chains (`a() |> b()`) also parse as unnamed continuations; the
// declaration lookup is what separates them — a producer with no declared
// terminal branches has nothing to thread and is left alone.

/// Entry point: desugar every point-free chain in the program, in place.
pub fn desugarPointfreeChains(allocator: std.mem.Allocator, program: *ast.Program) !void {
    var table = try SymbolTable.init(allocator);
    defer table.deinit();
    try table.buildFrom(program);

    var counter: usize = 0;
    try desugarItemsPointfree(allocator, &table, program.items, &counter);
}

fn desugarItemsPointfree(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    items: []const ast.Item,
    counter: *usize,
) std.mem.Allocator.Error!void {
    for (@constCast(items)) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                const enclosing: ?EventInfo = if (flow.impl_of) |p| table.getEventInfo(p) else null;
                try desugarSitePointfree(allocator, table, &flow.body, enclosing, counter);
            },
            .proc_decl => |*proc| {
                for (@constCast(proc.inline_flows)) |*flow| {
                    const enclosing: ?EventInfo = if (flow.impl_of) |p| table.getEventInfo(p) else null;
                    try desugarSitePointfree(allocator, table, &flow.body, enclosing, counter);
                }
            },
            .module_decl => |*module| try desugarItemsPointfree(allocator, table, module.items, counter),
            else => {},
        }
    }
}

/// Desugar one invocation site (a flow body or any continuation) and recurse.
/// `enclosing` is the declared event this flow implements — only set at the
/// flow root, where it supplies the bare head's punned input.
fn desugarSitePointfree(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    site: *ast.Continuation,
    enclosing: ?EventInfo,
    counter: *usize,
) std.mem.Allocator.Error!void {
    const transformed = try tryDesugarChain(allocator, table, site, enclosing, counter);
    if (transformed) return;
    for (@constCast(site.continuations)) |*child| {
        try desugarSitePointfree(allocator, table, child, null, counter);
    }
}

/// An unnamed chain step: the `|>` continuation the parser produces for a
/// point-free stage (and for void-chain steps — the declaration lookup in
/// `tryDesugarChain` separates the two).
fn isUnnamedStep(c: *const ast.Continuation) bool {
    if (c.branch.len != 0) return false;
    if (c.is_catchall) return false;
    if (c.condition != null) return false;
    if (c.binding != null) return false;
    const n = c.node orelse return false;
    return n == .invocation;
}

fn countTerminalBranches(info: EventInfo) usize {
    var count: usize = 0;
    for (info.branches) |b| {
        if (b.kind == .terminal) count += 1;
    }
    return count;
}

/// The one declared terminal branch left after `claimed` names are removed.
/// Zero or several left → null (the chain must then be handled explicitly).
fn soleSurvivor(info: EventInfo, claimed: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (info.branches) |b| {
        if (b.kind != .terminal) continue;
        var is_claimed = false;
        for (claimed) |name| {
            if (std.mem.eql(u8, name, b.name)) {
                is_claimed = true;
                break;
            }
        }
        if (is_claimed) continue;
        if (found != null) return null;
        found = b.name;
    }
    return found;
}

fn argNamed(args: []const ast.Arg, name: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a.name, name)) return true;
    }
    return false;
}

fn shapeHasField(shape: ast.Shape, name: []const u8) bool {
    for (shape.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// The single input field of `info` not already supplied by `args` — the slot
/// the threaded payload puns into. Zero or several open slots → null (the
/// thread has no unambiguous home; the stage must keep explicit parens).
fn soleOpenInputField(info: EventInfo, args: []const ast.Arg) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (info.input.fields) |f| {
        if (argNamed(args, f.name)) continue;
        if (found != null) return null;
        found = f.name;
    }
    return found;
}

fn appendedArgs(
    allocator: std.mem.Allocator,
    args: []const ast.Arg,
    name: []const u8,
    value: []const u8,
    explicit_label: bool,
) ![]const ast.Arg {
    var new_args = try allocator.alloc(ast.Arg, args.len + 1);
    for (args, 0..) |a, i| new_args[i] = a;
    new_args[args.len] = .{
        .name = try allocator.dupe(u8, name),
        .value = try allocator.dupe(u8, value),
        .had_explicit_label = explicit_label,
    };
    return new_args;
}

/// `[first] ++ clones-of-chokes`, every element stamped with `indent`.
fn levelContinuations(
    allocator: std.mem.Allocator,
    first: ast.Continuation,
    chokes: []const ast.Continuation,
    indent: usize,
) ![]ast.Continuation {
    var list = try allocator.alloc(ast.Continuation, 1 + chokes.len);
    list[0] = first;
    list[0].indent = indent;
    const cloned = try cloneContinuations(allocator, chokes);
    for (cloned, 0..) |c, i| {
        list[1 + i] = c;
        list[1 + i].indent = indent;
    }
    return list;
}

/// Detect and rewrite a point-free chain rooted at `site`. Returns true if the
/// site was rewritten (its whole subtree is then canonical); false leaves the
/// site untouched for normal recursion. All validation happens BEFORE any
/// mutation — a chain that cannot be fully resolved is left exactly as parsed.
fn tryDesugarChain(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    site: *ast.Continuation,
    enclosing: ?EventInfo,
    counter: *usize,
) std.mem.Allocator.Error!bool {
    const site_node = if (site.node) |*n| n else return false;
    if (site_node.* != .invocation) return false;

    // Quick gate: no unnamed invocation continuation here → no chain.
    var has_unnamed = false;
    for (site.continuations) |*child| {
        if (isUnnamedStep(child)) has_unnamed = true;
    }
    if (!has_unnamed) return false;

    const head_info = table.getEventInfo(site_node.invocation.path) orelse return false;
    if (countTerminalBranches(head_info) == 0) return false; // void chain — not ours

    // ---- Collect the chain: stages, steps, choke handlers ----
    var stage_infos = try std.ArrayList(EventInfo).initCapacity(allocator, 4);
    defer stage_infos.deinit(allocator);
    var steps = try std.ArrayList(*ast.Continuation).initCapacity(allocator, 4);
    defer steps.deinit(allocator);
    var chokes = try std.ArrayList(ast.Continuation).initCapacity(allocator, 4);
    defer chokes.deinit(allocator);

    try stage_infos.append(allocator, head_info);

    var cur: *ast.Continuation = site;
    while (true) {
        var unnamed: ?*ast.Continuation = null;
        for (@constCast(cur.continuations)) |*child| {
            if (isUnnamedStep(child)) {
                if (unnamed != null) return false; // two steps at one level: not a linear chain
                unnamed = child;
            } else {
                // Choke handler. Desugar its own subtree first (it may host a
                // nested chain), then record it for replication.
                try desugarSitePointfree(allocator, table, child, null, counter);
                try chokes.append(allocator, child.*);
            }
        }
        const step = unnamed orelse break;
        const info = table.getEventInfo(step.node.?.invocation.path) orelse return false;
        try steps.append(allocator, step);
        try stage_infos.append(allocator, info);
        cur = step;
    }
    if (steps.items.len == 0) return false;
    const n = steps.items.len;

    // ---- Validate: survivor per stage, thread slot per step, head pun ----
    var claimed = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer claimed.deinit(allocator);
    for (chokes.items) |c| try claimed.append(allocator, c.branch);

    var survivors = try std.ArrayList([]const u8).initCapacity(allocator, n + 1);
    defer survivors.deinit(allocator);
    for (stage_infos.items) |info| {
        const s = soleSurvivor(info, claimed.items) orelse return false;
        try survivors.append(allocator, s);
    }

    var slots = try std.ArrayList([]const u8).initCapacity(allocator, n);
    defer slots.deinit(allocator);
    for (steps.items, 0..) |step, i| {
        const slot = soleOpenInputField(stage_infos.items[i + 1], step.node.?.invocation.args) orelse return false;
        try slots.append(allocator, slot);
    }

    // A bare head stage takes the flow's whole input by pun; every open head
    // field must exist on the enclosing event's input.
    var head_fill = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer head_fill.deinit(allocator);
    for (head_info.input.fields) |f| {
        if (argNamed(site_node.invocation.args, f.name)) continue;
        const encl = enclosing orelse return false;
        if (!shapeHasField(encl.input, f.name)) return false;
        try head_fill.append(allocator, f.name);
    }

    // ---- Build the canonical pyramid bottom-up ----
    var temps = try std.ArrayList([]const u8).initCapacity(allocator, n + 1);
    defer temps.deinit(allocator);
    for (0..n + 1) |_| {
        const t = try std.fmt.allocPrint(allocator, "__pf_t{d}", .{counter.*});
        counter.* += 1;
        try temps.append(allocator, t);
    }

    // Terminus: the last stage's survivor becomes the flow's own output.
    const term_name = survivors.items[n];
    const terminus = ast.Continuation{
        .branch = try allocator.dupe(u8, term_name),
        .binding = try allocator.dupe(u8, temps.items[n]),
        .condition = null,
        .node = .{ .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, term_name),
            .fields = &.{},
            .plain_value = try allocator.dupe(u8, temps.items[n]),
            .has_expressions = true,
        } },
        .indent = 0,
        .continuations = &.{},
    };

    var inner: []ast.Continuation = try levelContinuations(allocator, terminus, chokes.items, n * 4);

    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const step = steps.items[i];
        // Move the step's invocation (keeps location/source_module intact) and
        // thread the survivor payload into its open input field.
        var inv = step.node.?.invocation;
        inv.args = try appendedArgs(allocator, inv.args, slots.items[i], temps.items[i], true);
        const chain_cont = ast.Continuation{
            .branch = try allocator.dupe(u8, survivors.items[i]),
            .binding = try allocator.dupe(u8, temps.items[i]),
            .condition = null,
            .node = .{ .invocation = inv },
            .indent = 0,
            .continuations = inner,
        };
        inner = try levelContinuations(allocator, chain_cont, chokes.items, i * 4);
    }

    // Fill the bare head's punned input args, then swap in the new subtree.
    for (head_fill.items) |fname| {
        site_node.invocation.args = try appendedArgs(allocator, site_node.invocation.args, fname, fname, false);
    }
    site.continuations = inner;
    return true;
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
