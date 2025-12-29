const std = @import("std");
const ast = @import("ast");

/// Central registry for all type information in a Koru program
pub const TypeRegistry = struct {
    allocator: std.mem.Allocator,
    
    // Event declarations mapped by full path (e.g., "io.read")
    events: std.StringHashMap(EventType),
    
    // Proc signatures mapped by full path
    procs: std.StringHashMap(ProcSignature),
    
    // Subflow implementations mapped by event path
    subflows: std.StringHashMap(SubflowType),
    
    // Label types mapped by name
    labels: std.StringHashMap(LabelType),
    
    // Imported modules: maps namespace name to module path
    imports: std.StringHashMap([]const u8),
    
    // Public events that can be imported by other modules
    public_events: std.StringHashMap(void),
    
    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .events = std.StringHashMap(EventType).init(allocator),
            .procs = std.StringHashMap(ProcSignature).init(allocator),
            .subflows = std.StringHashMap(SubflowType).init(allocator),
            .labels = std.StringHashMap(LabelType).init(allocator),
            .imports = std.StringHashMap([]const u8).init(allocator),
            .public_events = std.StringHashMap(void).init(allocator),
        };
    }
    
    pub fn deinit(self: *TypeRegistry) void {
        // Free event types
        var event_iter = self.events.iterator();
        while (event_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.events.deinit();
        
        // Free proc signatures
        var proc_iter = self.procs.iterator();
        while (proc_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.procs.deinit();
        
        // Free subflow types
        var subflow_iter = self.subflows.iterator();
        while (subflow_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.subflows.deinit();
        
        // Free label types
        var label_iter = self.labels.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.labels.deinit();
        
        // Free imports
        var import_iter = self.imports.iterator();
        while (import_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.imports.deinit();
        
        // Free public events
        var public_iter = self.public_events.iterator();
        while (public_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.public_events.deinit();
    }
    
    /// Register an event with its branch types
    pub fn registerEvent(self: *TypeRegistry, path: []const u8, event_decl: *const ast.EventDecl) !void {
        // Check if event already exists
        if (self.events.get(path)) |existing| {
            // Event already registered, skip to avoid duplicates and leaks
            _ = existing;
            return;
        }
        
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        
        // Check if this is an implicit flow event
        const is_implicit_flow = self.checkImplicitFlowEvent(&event_decl.input);
        
        var event_type = EventType{
            .input_shape = try self.duplicateShape(event_decl.input),
            .branches = try self.allocator.alloc(BranchType, event_decl.branches.len),
            .is_public = event_decl.is_public,
            .is_implicit_flow = is_implicit_flow,
        };
        errdefer event_type.deinit(self.allocator);
        
        for (event_decl.branches, 0..) |branch, i| {
            event_type.branches[i] = BranchType{
                .name = try self.allocator.dupe(u8, branch.name),
                .payload = try self.duplicateShape(branch.payload),
            };
        }
        
        try self.events.put(key, event_type);
        
        // Track public events separately for easy lookup
        if (event_decl.is_public) {
            if (!self.public_events.contains(path)) {
                const public_key = try self.allocator.dupe(u8, path);
                try self.public_events.put(public_key, {});
            }
        }
    }
    
    /// Register a proc with its signature
    pub fn registerProc(self: *TypeRegistry, path: []const u8, _: *const ast.ProcDecl) !void {
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        
        // Look up the corresponding event to get output type
        const event_type = self.events.get(path);
        
        const proc_sig = ProcSignature{
            .input_shape = if (event_type) |et| try self.duplicateShape(et.input_shape) else null,
            .output_branches = if (event_type) |et| try self.duplicateBranches(et.branches) else null,
        };
        
        try self.procs.put(key, proc_sig);
    }
    
    /// Register a subflow implementation for an event
    pub fn registerSubflowImpl(self: *TypeRegistry, event_path: []const u8, _: *const ast.SubflowImpl) !void {
        const key = try self.allocator.dupe(u8, event_path);
        errdefer self.allocator.free(key);
        
        // Look up the corresponding event to get types
        const event_type = self.events.get(event_path);
        
        var subflow_type = SubflowType{
            .event_path = try self.allocator.dupe(u8, event_path),
            .output_shape = null, // Will be set from event type if available
        };
        errdefer subflow_type.deinit(self.allocator);
        
        // TODO: Set output_shape from event_type branches
        _ = event_type;
        
        try self.subflows.put(key, subflow_type);
    }
    
    /// Register an import mapping
    pub fn registerImport(self: *TypeRegistry, namespace: []const u8, path: []const u8) !void {
        // Check if import already exists
        if (self.imports.get(namespace)) |existing| {
            // Import already registered, skip to avoid duplicates and leaks
            _ = existing;
            return;
        }
        
        const ns_key = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_key);
        
        const path_value = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_value);
        
        try self.imports.put(ns_key, path_value);
    }
    
    /// Populate registry from a canonicalized AST
    /// MUST be called AFTER canonicalization - uses module_qualifier from paths
    pub fn populateFromAST(self: *TypeRegistry, items: []const ast.Item) !void {
        for (items) |item| {
            try self.populateFromItem(item);
        }
    }

    fn populateFromItem(self: *TypeRegistry, item: ast.Item) !void {
        switch (item) {
            .event_decl => |event| {
                const canonical_name = try self.buildCanonicalName(&event.path);
                defer self.allocator.free(canonical_name);
                try self.registerEvent(canonical_name, &event);
            },
            .proc_decl => |proc| {
                const canonical_name = try self.buildCanonicalName(&proc.path);
                defer self.allocator.free(canonical_name);
                try self.registerProc(canonical_name, &proc);
            },
            .subflow_impl => |subflow| {
                const canonical_name = try self.buildCanonicalName(&subflow.event_path);
                defer self.allocator.free(canonical_name);
                try self.registerSubflowImpl(canonical_name, &subflow);
            },
            .module_decl => |module| {
                // Recursively process module items
                for (module.items) |module_item| {
                    try self.populateFromItem(module_item);
                }
            },
            .import_decl, .host_line, .host_type_decl, .parse_error, .flow, .event_tap, .label_decl, .native_loop, .fused_event, .inlined_event, .inline_code => {
                // These don't need registration in TypeRegistry
            },
        }
    }

    /// Build canonical name from a DottedPath (after canonicalization)
    /// Format: "module:segment.segment.segment"
    fn buildCanonicalName(self: *TypeRegistry, path: *const ast.DottedPath) ![]const u8 {
        // After canonicalization, ALL paths must have module_qualifier set
        const module = path.module_qualifier orelse {
            std.debug.print("FATAL: buildCanonicalName called on non-canonicalized path!\n", .{});
            std.debug.print("  Path segments: ", .{});
            for (path.segments, 0..) |seg, i| {
                if (i > 0) std.debug.print(".", .{});
                std.debug.print("{s}", .{seg});
            }
            std.debug.print("\n", .{});
            @panic("TypeRegistry.populateFromAST must be called AFTER canonicalization!");
        };

        // Calculate total length needed
        var total_len: usize = module.len + 1; // module + ':'
        for (path.segments, 0..) |seg, i| {
            total_len += seg.len;
            if (i > 0) total_len += 1; // for '.'
        }

        // Build the canonical name
        var buf = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;

        // Add module qualifier
        @memcpy(buf[pos..pos + module.len], module);
        pos += module.len;
        buf[pos] = ':';
        pos += 1;

        // Add segments with dots
        for (path.segments, 0..) |seg, i| {
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
            @memcpy(buf[pos..pos + seg.len], seg);
            pos += seg.len;
        }

        return buf;
    }

    /// Look up an event's type information
    pub fn getEventType(self: *const TypeRegistry, path: []const u8) ?EventType {
        if (self.events.get(path)) |event_type| {
            return event_type;
        }
        return null;
    }
    
    /// Look up a branch type by event path and branch name
    pub fn getBranchType(self: *const TypeRegistry, event_path: []const u8, branch_name: []const u8) ?BranchType {
        if (self.getEventType(event_path)) |event_type| {
            for (event_type.branches) |branch| {
                if (std.mem.eql(u8, branch.name, branch_name)) {
                    return branch;
                }
            }
        }
        return null;
    }
    
    /// Check if an event has implicit flow parameter (has Source param)
    fn checkImplicitFlowEvent(self: *TypeRegistry, input: *const ast.Shape) bool {
        _ = self;

        // Check if any field is Source
        // (Not necessarily the only field - can have other params)
        for (input.fields) |field| {
            if (field.is_source) {
                return true;
            }
        }

        return false;
    }
    
    /// Duplicate a shape for storage
    fn duplicateShape(self: *TypeRegistry, shape: ?ast.Shape) !?ast.Shape {
        if (shape) |s| {
            var fields = try self.allocator.alloc(ast.Field, s.fields.len);
            for (s.fields, 0..) |field, i| {
                fields[i] = ast.Field{
                    .name = try self.allocator.dupe(u8, field.name),
                    .type = try self.allocator.dupe(u8, field.type),
                    .is_source = field.is_source,
                    .is_file = field.is_file,
                    .is_embed_file = field.is_embed_file,
                    .is_expression = field.is_expression,
                    .phantom = field.phantom,  // TODO: might need to deep copy this
                };
            }
            return ast.Shape{ .fields = fields };
        }
        return null;
    }
    
    /// Duplicate branch types
    fn duplicateBranches(self: *TypeRegistry, branches: []const BranchType) ![]BranchType {
        var dup = try self.allocator.alloc(BranchType, branches.len);
        for (branches, 0..) |branch, i| {
            dup[i] = BranchType{
                .name = try self.allocator.dupe(u8, branch.name),
                .payload = try self.duplicateShape(branch.payload),
            };
        }
        return dup;
    }
};

/// Type information for an event
pub const EventType = struct {
    input_shape: ?ast.Shape,
    branches: []BranchType,
    is_public: bool = false,
    is_implicit_flow: bool = false,  // True for events with single Source param
    
    pub fn deinit(self: *EventType, allocator: std.mem.Allocator) void {
        if (self.input_shape) |shape| {
            for (shape.fields) |field| {
                allocator.free(field.name);
                allocator.free(field.type);
            }
            allocator.free(shape.fields);
        }
        
        for (self.branches) |*branch| {
            branch.deinit(allocator);
        }
        allocator.free(self.branches);
    }
};

/// Type information for a branch
pub const BranchType = struct {
    name: []const u8,
    payload: ?ast.Shape,
    
    pub fn deinit(self: *BranchType, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.payload) |shape| {
            for (shape.fields) |field| {
                allocator.free(field.name);
                allocator.free(field.type);
            }
            allocator.free(shape.fields);
        }
    }
};

/// Type signature for a proc
pub const ProcSignature = struct {
    input_shape: ?ast.Shape,
    output_branches: ?[]BranchType,
    
    pub fn deinit(self: *ProcSignature, allocator: std.mem.Allocator) void {
        if (self.input_shape) |shape| {
            for (shape.fields) |field| {
                allocator.free(field.name);
                allocator.free(field.type);
            }
            allocator.free(shape.fields);
        }
        
        if (self.output_branches) |branches| {
            for (branches) |*branch| {
                branch.deinit(allocator);
            }
            allocator.free(branches);
        }
    }
};

/// Type information for a subflow implementation
pub const SubflowType = struct {
    event_path: []const u8,  // The event this subflow implements
    output_shape: ?ShapeUnion, // From the event declaration
    
    pub fn deinit(self: *SubflowType, allocator: std.mem.Allocator) void {
        allocator.free(self.event_path);
        
        if (self.output_shape) |*shape| {
            shape.deinit(allocator);
        }
    }
};

/// Type information for a label
pub const LabelType = struct {
    expected_shape: ?ast.Shape,
    
    pub fn deinit(self: *LabelType, allocator: std.mem.Allocator) void {
        if (self.expected_shape) |shape| {
            for (shape.fields) |field| {
                allocator.free(field.name);
                allocator.free(field.type);
            }
            allocator.free(shape.fields);
        }
    }
};

/// Union of possible shapes (for subflow outputs)
pub const ShapeUnion = struct {
    branches: []BranchType,
    
    pub fn deinit(self: *ShapeUnion, allocator: std.mem.Allocator) void {
        for (self.branches) |*branch| {
            branch.deinit(allocator);
        }
        allocator.free(self.branches);
    }
};

// Tests
test "register and lookup event" {
    const allocator = std.testing.allocator;
    var registry = TypeRegistry.init(allocator);
    defer registry.deinit();
    
    // Create a test event
    var input_fields = [_]ast.Field{
        .{ .name = "path", .type = "[]const u8" },
    };
    var success_fields = [_]ast.Field{
        .{ .name = "data", .type = "[]const u8" },
    };
    var error_fields = [_]ast.Field{
        .{ .name = "errno", .type = "u32" },
    };
    
    var branches = [_]ast.Branch{
        .{ 
            .name = "success",
            .payload = ast.Shape{ .fields = &success_fields },
        },
        .{
            .name = "error",
            .payload = ast.Shape{ .fields = &error_fields },
        },
    };
    
    const event_decl = ast.EventDecl{
        .path = ast.DottedPath{ .segments = &[_][]const u8{ "io", "read" } },
        .input_shape = ast.Shape{ .fields = &input_fields },
        .branches = &branches,
    };
    
    // Register the event
    try registry.registerEvent("io.read", &event_decl);
    
    // Look it up
    const event_type = registry.getEventType("io.read");
    try std.testing.expect(event_type != null);
    try std.testing.expect(event_type.?.branches.len == 2);
    
    // Look up specific branch
    const branch = registry.getBranchType("io.read", "success");
    try std.testing.expect(branch != null);
    try std.testing.expectEqualSlices(u8, branch.?.name, "success");
}