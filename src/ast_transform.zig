const std = @import("std");
const ast = @import("ast");
const errors_mod = @import("errors");

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
                        .return_type = event.return_type,
                        .input_is_compiler_supplied = event.isComptimeOnly() or event.hasAnnotation("transform"),
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
    /// Declared `-> T` single return type name (null if the event returns via
    /// named branches). A `[transform]` event lands as `-> SiteResult`; its
    /// RUNTIME value is a result struct the caller must field-access (e.g.
    /// std/fmt:ln's `{ text }`), never punned whole into a scalar param.
    return_type: ?[]const u8 = null,
    /// This event's INPUT is assembled by the compiler at the call site, not
    /// written by the author — a `[transform]` receives the site itself
    /// (`invocation` / `item` / `program` / `allocator`), and a Source or
    /// Expression parameter is comptime-only for the same reason. Its open
    /// parameters are therefore not slots: nothing there is a home for a
    /// runtime thread. `std/fmt:ln` and `std/io:print.ln` are the instances.
    /// `[comptime]` alone does NOT qualify — `frontend { ctx: CompilerContext }`
    /// runs at comptime and its `ctx` is an ordinary author-written parameter.
    input_is_compiler_supplied: bool = false,
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
            // Preserve the field's VALUE and flags, not just name+type. A clone
            // that keeps only name+type turns a record body `{ f.ctx, f.message }`
            // into an empty `{ }`, so the bound `f` goes unused (KORU100). This is
            // the record-construct sibling of the plain_value/kind clone fixes:
            // faithful choke replication over a `=> failed { ... }` body needs it.
            // `expression` is shared (not deep-cloned); the clone does not own it.
            .module_path = if (field.module_path) |mp| try allocator.dupe(u8, mp) else null,
            .phantom = if (field.phantom) |p| try allocator.dupe(u8, p) else null,
            .is_source = field.is_source,
            .is_file = field.is_file,
            .is_embed_file = field.is_embed_file,
            .is_expression = field.is_expression,
            .is_invocation_meta = field.is_invocation_meta,
            .expression = field.expression,
            .expression_str = if (field.expression_str) |e| try allocator.dupe(u8, e) else null,
            .owns_expression = false,
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
//      Claim is NAME-first, then TYPE-aware: every stage that declares the
//      claimed branch must carry the SAME payload shape (and if the enclosing
//      event declares it too, that shape is the reference). Mismatch → KORU031
//      at the choke site; the chain is left untouched (never guess, never
//      hand the host a silent type lie — 220_025).
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
/// `reporter` receives KORU031 when a choke claims a branch whose payload
/// shape disagrees across stages (type-aware claim wall).
pub fn desugarPointfreeChains(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    reporter: *errors_mod.ErrorReporter,
) !void {
    var table = try SymbolTable.init(allocator);
    defer table.deinit();
    try table.buildFrom(program);

    var counter: usize = 0;
    try desugarItemsPointfree(allocator, &table, program.items, &counter, reporter);
}

fn desugarItemsPointfree(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    items: []const ast.Item,
    counter: *usize,
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    for (@constCast(items)) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                const enclosing: ?EventInfo = if (flow.impl_of) |p| table.getEventInfo(p) else null;
                try desugarSitePointfree(allocator, table, &flow.body, enclosing, counter, reporter);
            },
            .proc_decl => |*proc| {
                for (@constCast(proc.inline_flows)) |*flow| {
                    const enclosing: ?EventInfo = if (flow.impl_of) |p| table.getEventInfo(p) else null;
                    try desugarSitePointfree(allocator, table, &flow.body, enclosing, counter, reporter);
                }
            },
            .module_decl => |*module| try desugarItemsPointfree(allocator, table, module.items, counter, reporter),
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
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    const transformed = try tryDesugarChain(allocator, table, site, enclosing, counter, reporter);
    if (transformed) return;
    for (@constCast(site.continuations)) |*child| {
        try desugarSitePointfree(allocator, table, child, null, counter, reporter);
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

/// Branch payload shape equality for choke claims. Phantom states ignored
/// (same rule as ShapeChecker.shapesEqual) — this wall is about the host
/// type the binding carries, not obligation polarity.
fn payloadShapesEqual(a: ast.Shape, b: ast.Shape) bool {
    if (a.is_wildcard or b.is_wildcard) return a.is_wildcard and b.is_wildcard;
    if (a.fields.len != b.fields.len) return false;
    for (a.fields) |field_a| {
        var found = false;
        for (b.fields) |field_b| {
            if (std.mem.eql(u8, field_a.name, field_b.name)) {
                if (!std.mem.eql(u8, field_a.type, field_b.type)) return false;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Human-readable payload summary for diagnostics: identity `string`,
/// struct `{ a: i64, b: string }`, void `(none)`, wildcard `*`.
fn formatPayload(allocator: std.mem.Allocator, shape: ast.Shape) ![]const u8 {
    if (shape.is_wildcard) return try allocator.dupe(u8, "*");
    if (shape.fields.len == 0) return try allocator.dupe(u8, "(none)");
    if (shape.fields.len == 1 and std.mem.eql(u8, shape.fields[0].name, "__type_ref")) {
        return try allocator.dupe(u8, shape.fields[0].type);
    }
    var buf = try std.ArrayList(u8).initCapacity(allocator, 32);
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{ ");
    for (shape.fields, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, f.type);
    }
    try buf.appendSlice(allocator, " }");
    return try buf.toOwnedSlice(allocator);
}

fn branchNamed(info: EventInfo, name: []const u8) ?ast.Branch {
    for (info.branches) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

fn eventLeafName(info: EventInfo) []const u8 {
    if (info.path.segments.len == 0) return "<event>";
    return info.path.segments[info.path.segments.len - 1];
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
    reporter: *errors_mod.ErrorReporter,
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
                try desugarSitePointfree(allocator, table, child, null, counter, reporter);
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

    // TYPE-AWARE CHOKE CLAIM (KORU031): every stage that declares a claimed
    // branch must agree on its payload shape. Reference = enclosing event's
    // same-named branch when present (the analysis shape), else the first
    // stage that carries it. Name-only replication was the silent Zig leak
    // 220_025 pins.
    var type_mismatch = false;
    for (chokes.items) |choke| {
        if (choke.branch.len == 0 or choke.is_catchall) continue;
        var ref_payload: ?ast.Shape = null;
        var ref_label: []const u8 = "choke";
        if (enclosing) |encl| {
            if (branchNamed(encl, choke.branch)) |b| {
                ref_payload = b.payload;
                ref_label = eventLeafName(encl);
            }
        }
        for (stage_infos.items) |info| {
            const b = branchNamed(info, choke.branch) orelse continue;
            if (b.payload.is_wildcard) continue;
            if (ref_payload == null) {
                ref_payload = b.payload;
                ref_label = eventLeafName(info);
                continue;
            }
            if (payloadShapesEqual(ref_payload.?, b.payload)) continue;
            const expected = try formatPayload(allocator, ref_payload.?);
            defer allocator.free(expected);
            const actual = try formatPayload(allocator, b.payload);
            defer allocator.free(actual);
            try reporter.addErrorAtLocationWithHint(
                .KORU031,
                choke.location,
                "`| {s}` handled here, but has wrong type: '{s}' carries {s}, choke expects {s} (from '{s}')",
                .{ choke.branch, eventLeafName(info), actual, expected, ref_label },
                "a point-free choke claims by name across every stage — payload shapes must agree (see `analysis` in compiler.kz)",
                .{},
            );
            type_mismatch = true;
        }
    }
    if (type_mismatch) return false;

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

// ============================================================================
// Inline scalar-bind pun
// ============================================================================
//
// A `: bind` names a scalar-return (or branch-payload) value; that name becomes
// a real symbol legal through the whole subtree (Koru forbids shadowing, so the
// name is unique). When a later invocation in that subtree declares an input
// field of the SAME name that the call site left unfilled, the pun synthesizes
// the explicit arg `field: field` — as if the author had typed it.
//
// This runs as a Stage-A desugar (after the point-free rewrite, before every
// checker), so the synthesized arg is explicit-form-equivalent by the time the
// structure and phantom-semantic passes see it: type and obligation validation
// treat a punned arg identically to a hand-written one. No phantom logic lives
// here — the pun only inserts the reference; correctness is the checkers' job.
//
// Scope rule: branch names are NOT durable symbols (a stage may repeat `| ctx`),
// so they thread only one step in the point-free desugar; a `: bind` IS a
// durable symbol, so its pun reaches its full subtree. No shadowing means the
// in-scope match is always unique — never ambiguous.

/// Entry point: synthesize binding-name puns across the program, in place.
pub fn desugarBindingPuns(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    reporter: *errors_mod.ErrorReporter,
) !void {
    var table = try SymbolTable.init(allocator);
    defer table.deinit();
    try table.buildFrom(program);
    var thread_counter: usize = 0;

    // scope maps a live binding NAME -> the `-> T` return type of the event
    // that produced it (null for branch payloads and non-return binds). RULING
    // 3 reads this: a bind whose producer returns `SiteResult` (a transform
    // result struct — e.g. std/fmt:ln's `{ text }`) must be field-accessed, not
    // punned whole into a scalar param.
    var scope = std.StringHashMap(?[]const u8).init(allocator);
    defer scope.deinit();
    try punItemsBinding(allocator, &table, program.items, &scope, &thread_counter, reporter);
}

fn punItemsBinding(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    items: []const ast.Item,
    scope: *std.StringHashMap(?[]const u8),
    counter: *usize,
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    for (@constCast(items)) |*item| {
        switch (item.*) {
            .flow => |*flow| try punContinuationBinding(allocator, table, &flow.body, scope, counter, null, reporter),
            .proc_decl => |*proc| {
                for (@constCast(proc.inline_flows)) |*flow| {
                    try punContinuationBinding(allocator, table, &flow.body, scope, counter, null, reporter);
                }
            },
            .module_decl => |*module| try punItemsBinding(allocator, table, module.items, scope, counter, reporter),
            else => {},
        }
    }
}

// ----------------------------------------------------------------------------
// The point-free thread: a `-> T` stage's value, bound by TYPE
// ----------------------------------------------------------------------------
//
// A `-> T` stage in a `|>` chain hands its value to the next step. That value
// has no name to bind by — having no name is what `-> T` MEANS — so it binds
// by TYPE: it fills the one UNFILLED parameter whose type it matches. Written
// arguments (including the ones the bind-pun above already synthesized) narrow
// the field first; then the type decides. Exactly one candidate binds; several
// is KORU093 naming them; none, with the call still incomplete, is KORU092.
// Pin: 210_176. Belief: `frag-the-thread-binds-by-type`.
//
// BASE TYPE ONLY. Phantom state lives on `Field.phantom` and in the decl's
// `return_phantom`, never inside `Field.type` / `return_type` — so the string
// compare here IS the base-type compare, and no phantom logic lives in this
// desugar (the invariant stated at the head of this section holds). A
// `*Multi<empty!>` thread finds `m: *Multi<!empty|!open>`; the phantom-semantic
// checker then validates the state exactly as it does for a hand-written arg.
// Two parameters differing ONLY in phantom state stay ambiguous, which is
// correct — the thread has no basis to choose.
//
// An OPTIONAL parameter (`?T`) is never a candidate, because an optional is
// never *unfilled*: omitting it is already a complete call. Not an exception —
// it is what "unfilled" means.

/// The value a bare-return stage hands to the next `|>` step: the invocation
/// that produced it (so a holder name can be minted on demand) and the base
/// type it carries.
const Thread = struct {
    producer: *ast.Invocation,
    type: []const u8,
};

/// An optional input (`?T`) is never *unfilled* — omitting it is already a
/// complete call — so it is never a thread candidate.
fn isOptionalInput(f: ast.Field) bool {
    return f.type.len > 0 and f.type[0] == '?';
}

/// Compiler-supplied inputs (Source / Expression / File / InvocationMeta) are
/// never author-written, so they are never a home for the thread either.
fn isCompilerSuppliedInput(f: ast.Field) bool {
    return f.is_source or f.is_file or f.is_embed_file or
        f.is_expression or f.is_invocation_meta;
}

/// Still open to the thread: not written, not optional, not compiler-supplied.
fn isOpenThreadSlot(f: ast.Field, args: []const ast.Arg) bool {
    if (argNamed(args, f.name)) return false;
    if (isOptionalInput(f)) return false;
    if (isCompilerSuppliedInput(f)) return false;
    return true;
}

/// The name that holds the thread's value. A stage the author already bound
/// (`stage(): r`) is its own holder; an unbound one gets a synthesized bind —
/// minted only at the moment a consumer is found, so a thread nobody takes
/// never invents a dead local for KORU100 to trip over.
fn threadHolderName(
    allocator: std.mem.Allocator,
    inv: *ast.Invocation,
    counter: *usize,
) ![]const u8 {
    if (inv.return_binding) |rb| return rb;
    const name = try std.fmt.allocPrint(allocator, "__thread{d}", .{counter.*});
    counter.* += 1;
    inv.return_binding = name;
    return name;
}

/// `'a' (i64), 'b' (string)` — the open slots, for the no-home diagnostic.
fn formatOpenSlots(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    types: []const []const u8,
) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 48);
    errdefer buf.deinit(allocator);
    for (names, 0..) |nm, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '\'');
        try buf.appendSlice(allocator, nm);
        try buf.appendSlice(allocator, "' (");
        try buf.appendSlice(allocator, types[i]);
        try buf.append(allocator, ')');
    }
    return try buf.toOwnedSlice(allocator);
}

/// `'base', 'incoming'` — the tied candidates, for the cannot-elect diagnostic.
fn formatQuotedNames(allocator: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 32);
    errdefer buf.deinit(allocator);
    for (names, 0..) |nm, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '\'');
        try buf.appendSlice(allocator, nm);
        try buf.append(allocator, '\'');
    }
    return try buf.toOwnedSlice(allocator);
}

/// Fill this step's one type-matched open slot with the thread — or say, in
/// koru, why the thread has no unambiguous home there.
fn bindThreadIntoStep(
    allocator: std.mem.Allocator,
    node: *ast.Node,
    info: EventInfo,
    thread: Thread,
    counter: *usize,
    location: errors_mod.SourceLocation,
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    // A comptime transform's input is assembled by the compiler at the call
    // site, not written by the author. Its open parameters are not slots.
    if (info.input_is_compiler_supplied) return;

    var open_names = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer open_names.deinit(allocator);
    var open_types = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer open_types.deinit(allocator);
    var matches = try std.ArrayList([]const u8).initCapacity(allocator, 2);
    defer matches.deinit(allocator);

    for (info.input.fields) |f| {
        if (!isOpenThreadSlot(f, node.invocation.args)) continue;
        try open_names.append(allocator, f.name);
        try open_types.append(allocator, f.type);
        if (std.mem.eql(u8, f.type, thread.type)) try matches.append(allocator, f.name);
    }

    // Nothing is unfilled: the call the author wrote is already complete, so
    // the thread simply is not taken here. Complete is never an error.
    if (open_names.items.len == 0) return;

    const step = eventLeafName(info);

    if (matches.items.len == 1) {
        const holder = try threadHolderName(allocator, thread.producer, counter);
        node.invocation.args = try appendedArgs(
            allocator,
            node.invocation.args,
            matches.items[0],
            holder,
            !std.mem.eql(u8, matches.items[0], holder),
        );
        return;
    }

    if (matches.items.len > 1) {
        const tied = try formatQuotedNames(allocator, matches.items);
        defer allocator.free(tied);
        try reporter.addErrorAtLocationWithHint(
            .KORU093,
            location,
            "'{s}' has {d} unfilled parameters accepting a {s}: {s} — the thread cannot elect between them",
            .{ step, matches.items.len, thread.type, tied },
            "write one of them at the call site; the thread fills whichever is left open (writing narrows, and what you write binds by name)",
            .{},
        );
        return;
    }

    if (open_names.items.len == 1) {
        try reporter.addErrorAtLocationWithHint(
            .KORU092,
            location,
            "nothing in '{s}' accepts a {s} — its parameter '{s}' is a {s}",
            .{ step, thread.type, open_names.items[0], open_types.items[0] },
            "a `|>` step takes the previous stage's `-> T` by TYPE into an unfilled parameter. Give '{s}' a {s} parameter, or write '{s}' explicitly and end the thread there.",
            .{ step, thread.type, open_names.items[0] },
        );
        return;
    }

    const listed = try formatOpenSlots(allocator, open_names.items, open_types.items);
    defer allocator.free(listed);
    try reporter.addErrorAtLocationWithHint(
        .KORU092,
        location,
        "nothing in '{s}' accepts a {s} — its unfilled parameters are {s}",
        .{ step, thread.type, listed },
        "a `|>` step takes the previous stage's `-> T` by TYPE into an unfilled parameter. Give '{s}' a {s} parameter, or write the remaining ones explicitly and end the thread there.",
        .{ step, thread.type },
    );
}

/// The thread `cont`'s own node hands downstream, if it produces one. Only a
/// declared `-> T` threads: a branch-carrying stage threads its PAYLOAD through
/// the point-free desugar above instead, and a `[transform]` result is a struct
/// the caller must field-access (`l.text`), never a value to pass whole.
fn threadProducedBy(
    table: *SymbolTable,
    node: *ast.Node,
) ?Thread {
    if (node.* != .invocation) return null;
    // A destructured return (`f(): { a, b }`) has no single name to hand on.
    if (node.invocation.return_destructure.len > 0) return null;
    const info = table.getEventInfo(node.invocation.path) orelse return null;
    if (info.input_is_compiler_supplied) return null;
    const rt = info.return_type orelse return null;
    if (isTransformResultReturn(rt)) return null;
    return .{ .producer = &node.invocation, .type = rt };
}

// ----------------------------------------------------------------------------
// The flow's return terminus: the last step's `-> T` IS the flow's `-> T`
// ----------------------------------------------------------------------------
//
// A flow declaring `-> T` is done when its chain has produced a `T`. Writing
// `last-step(): v -> v` names a value for one line in order to hand it straight
// back — it says nothing the two signatures do not already say — so the
// terminus is synthesized instead, matched by TYPE.
//
// This is the courtesy a BRANCH terminus already gets. `tryDesugarChain` above
// builds the branch terminus for a branch-carrying chain, which is why
// `~analysis` ends at its last stage with only a dedented `| failed` choke and
// no `| ctx c5 => ctx c5`. A bare return had no such path: the value simply
// went nowhere, and Zig said so ("function with non-void return type 'i64'
// implicitly returns") in a file the author never opened. Pin: 210_184.
//
// The rule reaches a LINEAR chain only — every level exactly one unnamed `|>`
// step and nothing else, down to a level with none. Any other shape (a branch
// arm, a choke, an effect arm, a fork) says where the flow's value comes from
// in a way this rule does not govern, and a single call with no `|>` at all is
// its own last step.

/// The last step of a flow body that is a linear point-free chain, or null if
/// the body is any other shape. A body whose last step ALREADY carries a
/// terminus fails the `isUnnamedStep` test on that child and lands here as
/// null, which is what keeps a written `-> v` authoritative.
fn linearChainLastStep(body: *ast.Continuation) ?*ast.Continuation {
    var cur: *ast.Continuation = body;
    while (true) {
        if (cur.continuations.len == 0) return cur;
        if (cur.continuations.len != 1) return null;
        const child = &(@constCast(cur.continuations))[0];
        if (!isUnnamedStep(child)) return null;
        cur = child;
    }
}

/// The name holding the value the flow produces. A last step the author already
/// bound is its own holder; an unbound one gets a synthesized bind — precisely
/// the `: v` the author would otherwise have had to write.
fn returnHolderName(
    allocator: std.mem.Allocator,
    inv: *ast.Invocation,
    counter: *usize,
) ![]const u8 {
    if (inv.return_binding) |rb| return rb;
    const name = try std.fmt.allocPrint(allocator, "__ret{d}", .{counter.*});
    counter.* += 1;
    inv.return_binding = name;
    return name;
}

/// Entry point: give every `-> T` flow whose chain ends without one the
/// terminus its last step already earned.
pub fn desugarFlowReturnTerminus(
    allocator: std.mem.Allocator,
    program: *ast.Program,
    reporter: *errors_mod.ErrorReporter,
) !void {
    var table = try SymbolTable.init(allocator);
    defer table.deinit();
    try table.buildFrom(program);
    var counter: usize = 0;
    try terminusItems(allocator, &table, program.items, &counter, reporter);
}

fn terminusItems(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    items: []const ast.Item,
    counter: *usize,
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    for (@constCast(items)) |*item| {
        switch (item.*) {
            .flow => |*flow| try addFlowReturnTerminus(allocator, table, flow, counter, reporter),
            .proc_decl => |*proc| {
                for (@constCast(proc.inline_flows)) |*flow| {
                    try addFlowReturnTerminus(allocator, table, flow, counter, reporter);
                }
            },
            .module_decl => |*module| try terminusItems(allocator, table, module.items, counter, reporter),
            else => {},
        }
    }
}

fn addFlowReturnTerminus(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    flow: *ast.Flow,
    counter: *usize,
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    // An inline body is emitted verbatim; there is no chain here to read.
    if (flow.inline_body != null) return;

    // A top-level statement implements nothing and produces nothing.
    const impl = flow.impl_of orelse return;
    const encl = table.getEventInfo(impl) orelse return;
    // A branch-returning flow gets its terminus from the point-free desugar.
    const want = encl.return_type orelse return;
    // A `[transform]`'s lowering constructs its own SiteResult.
    if (isTransformResultReturn(want)) return;

    const last = linearChainLastStep(&flow.body) orelse return;
    const node = if (last.node) |*n| n else return;
    if (node.* != .invocation) return;

    const step = table.getEventInfo(node.invocation.path) orelse return;

    // A step with declared branches produces no bare value, and the
    // branch-coverage wall already has the better sentence for that shape.
    if (step.branches.len > 0) return;

    const flow_name = eventLeafName(encl);
    const leaf = eventLeafName(step);

    const got = step.return_type orelse {
        try reporter.addErrorAtLocationWithHint(
            .KORU094,
            last.location,
            "'{s}' declares `-> {s}`, but its chain ends at '{s}', which produces no value",
            .{ flow_name, want, leaf },
            "a chain satisfies its flow's `-> {s}` when its LAST step returns one. End on a step that produces a {s}, or drop the `-> {s}` from '{s}'.",
            .{ want, want, want, flow_name },
        );
        return;
    };

    if (!std.mem.eql(u8, got, want)) {
        try reporter.addErrorAtLocationWithHint(
            .KORU094,
            last.location,
            "'{s}' declares `-> {s}`, but its chain ends at '{s}', which produces a {s}",
            .{ flow_name, want, leaf, got },
            "the last step's return type IS the flow's return — nothing converts between them. End the chain on a step returning {s}.",
            .{want},
        );
        return;
    }

    // The types agree, so the value the last step produces IS the flow's
    // output. Synthesize exactly the `-> v` the author would have written.
    const holder = try returnHolderName(allocator, &node.invocation, counter);
    const conts = try allocator.alloc(ast.Continuation, 1);
    conts[0] = .{
        .branch = try allocator.dupe(u8, ""),
        .binding = null,
        .condition = null,
        .node = .{ .branch_constructor = .{
            .branch_name = try allocator.dupe(u8, ""),
            .fields = &.{},
            .plain_value = try allocator.dupe(u8, holder),
            .has_expressions = true,
            .is_bare_return = true,
        } },
        .indent = last.indent,
        .continuations = &.{},
    };
    last.continuations = conts;
}

/// A `[transform]` event's declared single-return type. Its RUNTIME value is a
/// result struct (not the type name itself) that the caller must field-access
/// (std/fmt:ln → `{ text }`), never pun whole into a scalar param.
fn isTransformResultReturn(return_type: ?[]const u8) bool {
    const rt = return_type orelse return false;
    return std.mem.eql(u8, rt, "SiteResult");
}

/// A string-typed parameter — the class RULING 3 governs. A whole result struct
/// punned into a string param is the leak; a struct-typed param could legitimately
/// receive a struct, so the KORU038 wall is scoped to string params only.
fn isStringParamType(type_str: []const u8) bool {
    return std.mem.eql(u8, type_str, "string") or
        std.mem.eql(u8, type_str, "[]const u8") or
        std.mem.eql(u8, type_str, "[]u8");
}

/// Fill this invocation's unfilled fields from in-scope bindings, then descend
/// with this continuation's own binding added to scope for its subtree.
fn punContinuationBinding(
    allocator: std.mem.Allocator,
    table: *SymbolTable,
    cont: *ast.Continuation,
    scope: *std.StringHashMap(?[]const u8),
    counter: *usize,
    thread: ?Thread,
    reporter: *errors_mod.ErrorReporter,
) std.mem.Allocator.Error!void {
    // The names this continuation introduces into scope are added in two phases
    // relative to the step-1 fill of cont.node, keyed by WHERE the value is
    // produced:
    //   PHASE A (before the fill) — a BRANCH PAYLOAD binding (`| emit text`,
    //     `| ok x`). The payload is produced UPSTREAM (the emitting event / a
    //     prior branch), so cont.node here is a CONSUMER that may legitimately
    //     pun the payload into its own unfilled args. Seeding it first is what
    //     lets `! emit text |> render-at(x:5)` fill `text` implicitly (210_157).
    //   PHASE B (after the fill) — a RETURN bind (`producer(): x`) or a
    //     destructured return. That value is produced BY cont.node itself, so it
    //     must NOT pun into the very invocation that produces it.
    // No shadowing means a name added here cannot already be live — but we guard
    // anyway and only remove names we actually added. A return bind carries its
    // producer's declared return type so a downstream pun can tell a transform
    // result struct (SiteResult) from a plain scalar.
    var added = try std.ArrayList([]const u8).initCapacity(allocator, 3);
    defer added.deinit(allocator);

    // Phase A: branch payload — in scope BEFORE this node's fill (upstream value).
    if (cont.binding) |b| {
        if (!scope.contains(b)) {
            try scope.put(b, null); // branch payload — no producer return type
            try added.append(allocator, b);
        }
    }

    // 1. Fill unfilled input fields from bindings already in scope — including
    //    this continuation's own branch payload (phase A), but NOT its return
    //    bind (phase B, added after this), so a value never puns into the very
    //    invocation that produces it.
    if (cont.node) |*node| {
        if (node.* == .invocation) {
            if (table.getEventInfo(node.invocation.path)) |info| {
                for (info.input.fields) |f| {
                    if (argNamed(node.invocation.args, f.name)) continue;
                    if (scope.get(f.name)) |producer_ret| {
                        // RULING 3: the in-scope binding `f.name` is a whole
                        // transform result struct (producer returns SiteResult).
                        // Punning it into this scalar/string param would emit
                        // invalid Zig (`.text = text` where `text` is a struct).
                        // Reject at the koru level with a source line that guides
                        // to the field access, instead of leaking the raw Zig
                        // type error. (Every passing fmt test field-accesses the
                        // result — `l.text` — never bare `l`.)
                        if (isTransformResultReturn(producer_ret) and isStringParamType(f.type)) {
                            try reporter.addErrorAtLocationWithHint(
                                .KORU038,
                                cont.location,
                                "cannot fill '{s}' by punning binding '{s}' — '{s}' names a formatted-result struct, not a plain value",
                                .{ f.name, f.name, f.name },
                                "reach the field explicitly: write `{s}: {s}.{s}` (a std/fmt result carries its string in `.{s}`). A bare `{s}` puns the whole result struct into the parameter.",
                                .{ f.name, f.name, f.name, f.name, f.name },
                            );
                            continue;
                        }
                        node.invocation.args = try appendedArgs(
                            allocator,
                            node.invocation.args,
                            f.name,
                            f.name,
                            false,
                        );
                    }
                }
            }
        }
    }

    // 1b. THE THREAD. The upstream `-> T` value lands in the one UNFILLED
    //    parameter whose type it matches. It runs AFTER the name fill above, so
    //    a name-punned arg counts as written and narrows the field exactly like
    //    a hand-written one — the bright line is written versus not written.
    if (thread) |th| {
        if (cont.node) |*node| {
            if (node.* == .invocation) {
                if (table.getEventInfo(node.invocation.path)) |info| {
                    try bindThreadIntoStep(allocator, node, info, th, counter, cont.location, reporter);
                }
            }
        }
    }

    // Phase B: return bind (`producer(): x`) and destructured return
    //    (`producer(): { a, b }`) — produced BY cont.node, so added to scope only
    //    AFTER its own fill above, never punning into the very invocation that
    //    produces them. The producer's declared return type rides with a return
    //    bind so a downstream pun can tell a transform result struct (SiteResult)
    //    from a plain scalar.
    if (cont.node) |node| {
        if (node == .invocation) {
            const producer_ret: ?[]const u8 = if (table.getEventInfo(node.invocation.path)) |info| info.return_type else null;
            if (node.invocation.return_binding) |rb| {
                if (!scope.contains(rb)) {
                    try scope.put(rb, producer_ret);
                    try added.append(allocator, rb);
                }
            }
            for (node.invocation.return_destructure) |df| {
                if (!scope.contains(df.name)) {
                    try scope.put(df.name, null);
                    try added.append(allocator, df.name);
                }
            }
        }
    }

    // The thread this node hands on. Only an unnamed `|>` step receives it —
    // a branch arm, a guarded arm and an effect arm are not the chain.
    const downstream: ?Thread = if (cont.node) |*node| threadProducedBy(table, node) else null;

    for (@constCast(cont.continuations)) |*child| {
        const passed: ?Thread = if (downstream != null and isUnnamedStep(child)) downstream else null;
        try punContinuationBinding(allocator, table, child, scope, counter, passed, reporter);
    }

    for (added.items) |b| _ = scope.remove(b);
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
