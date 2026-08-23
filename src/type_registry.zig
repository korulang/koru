const std = @import("std");
const log = @import("log");
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
    
    // Declared types: name-keyed identities minted by std/types declaration
    // tors (`~std/types:struct(Player)`, `~string(EmailAddress)`). The entry
    // IS the identity — a stamped name (`box#i64`) carries monomorphized
    // identity in the name itself. Rung 1 of the type registry (belief
    // frag-type-system-design, 2026-08-13): registration from the
    // canonicalized AST; the register/lookup Koru-surface layer arrives as
    // the gray-zone module later. Collision policy: same name re-registered
    // is idempotent (HashMap(void)); the loud two-registrant error is the
    // Koru-surface layer's job when it lands.
    declared_types: std.StringHashMap(void),
    
    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .events = std.StringHashMap(EventType).init(allocator),
            .procs = std.StringHashMap(ProcSignature).init(allocator),
            .subflows = std.StringHashMap(SubflowType).init(allocator),
            .labels = std.StringHashMap(LabelType).init(allocator),
            .imports = std.StringHashMap([]const u8).init(allocator),
            .public_events = std.StringHashMap(void).init(allocator),
            .declared_types = std.StringHashMap(void).init(allocator),
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

        // Free declared types
        var declared_iter = self.declared_types.iterator();
        while (declared_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.declared_types.deinit();
    }

    /// Clone this TypeRegistry with a new allocator
    /// Enables transforms to create local registries for supplemental parsing
    pub fn clone(self: *const TypeRegistry, allocator: std.mem.Allocator) !TypeRegistry {
        var new_registry = TypeRegistry.init(allocator);
        errdefer new_registry.deinit();

        // Clone events
        var event_iter = self.events.iterator();
        while (event_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);

            const event_type = entry.value_ptr.*;
            const cloned_event = EventType{
                .input_shape = try new_registry.duplicateShape(event_type.input_shape),
                .branches = try new_registry.duplicateBranches(event_type.branches),
                .has_effect_branches = event_type.has_effect_branches,
                .is_public = event_type.is_public,
                .is_implicit_flow = event_type.is_implicit_flow,
                .return_type = if (event_type.return_type) |rt| try new_registry.allocator.dupe(u8, rt) else null,
            };
            try new_registry.events.put(key, cloned_event);
        }

        // Clone procs
        var proc_iter = self.procs.iterator();
        while (proc_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);

            const proc_sig = entry.value_ptr.*;
            const cloned_proc = ProcSignature{
                .input_shape = try new_registry.duplicateShape(proc_sig.input_shape),
                .output_branches = if (proc_sig.output_branches) |branches|
                    try new_registry.duplicateBranches(branches)
                else
                    null,
            };
            try new_registry.procs.put(key, cloned_proc);
        }

        // Clone subflows
        var subflow_iter = self.subflows.iterator();
        while (subflow_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);

            const subflow_type = entry.value_ptr.*;
            const cloned_subflow = SubflowType{
                .event_path = try allocator.dupe(u8, subflow_type.event_path),
                .output_shape = if (subflow_type.output_shape) |shape| blk: {
                    break :blk ShapeUnion{
                        .branches = try new_registry.duplicateBranches(shape.branches),
                    };
                } else null,
            };
            try new_registry.subflows.put(key, cloned_subflow);
        }

        // Clone labels
        var label_iter = self.labels.iterator();
        while (label_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);

            const label_type = entry.value_ptr.*;
            const cloned_label = LabelType{
                .expected_shape = try new_registry.duplicateShape(label_type.expected_shape),
            };
            try new_registry.labels.put(key, cloned_label);
        }

        // Clone imports
        var import_iter = self.imports.iterator();
        while (import_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try new_registry.imports.put(key, value);
        }

        // Clone public_events
        var public_iter = self.public_events.iterator();
        while (public_iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            try new_registry.public_events.put(key, {});
        }

        return new_registry;
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
        
        var has_effect = false;
        for (event_decl.branches) |*b| {
            if (b.kind == .effect) {
                has_effect = true;
                break;
            }
        }
        var event_type = EventType{
            .input_shape = try self.duplicateShape(event_decl.input),
            .branches = try self.allocator.alloc(BranchType, event_decl.branches.len),
            .has_effect_branches = has_effect,
            .is_public = event_decl.is_public,
            .is_implicit_flow = is_implicit_flow,
            .return_type = if (event_decl.return_type) |rt| try self.allocator.dupe(u8, rt) else null,
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
    
    /// Register a subflow implementation for an event (from a Flow with impl_of set)
    pub fn registerImplFlow(self: *TypeRegistry, event_path: []const u8, _: *const ast.Flow) !void {
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

    /// Register an immediate impl for an event
    pub fn registerImmediateImpl(self: *TypeRegistry, event_path: []const u8, _: *const ast.ImmediateImpl) !void {
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
            .flow => |flow| {
                // Register impl flows (flows with impl_of set)
                if (flow.impl_of) |impl_path| {
                    const canonical_name = try self.buildCanonicalName(&impl_path);
                    defer self.allocator.free(canonical_name);
                    try self.registerImplFlow(canonical_name, &flow);
                }
                // Declared-type registration (rung 1 of the type registry): a
                // flow invoking a std/types declaration tor (`struct`, nominal
                // wrappers) declares a type under its first argument's name.
                // Stamped identities (`box#i64`) ARE the name — the entry is
                // the identity. Same bare-`struct` keyword form is a null
                // qualifier; both register.
                const inv = flow.inv();
                const mq = inv.path.module_qualifier;
                const types_tor = if (mq) |mqv|
                    std.mem.eql(u8, mqv, "std.types") or std.mem.eql(u8, mqv, "std/types")
                else
                    true;
                if (types_tor and inv.path.segments.len > 0) {
                    const last_seg = inv.path.segments[inv.path.segments.len - 1];
                    const is_decl_tor = std.mem.eql(u8, last_seg, "struct") or
                        std.mem.eql(u8, last_seg, "string") or
                        std.mem.eql(u8, last_seg, "int") or
                        std.mem.eql(u8, last_seg, "float") or
                        std.mem.eql(u8, last_seg, "bool");
                    // PROTO rung: `std/types:proto(Name)` is the declared-type
                    // front door; the container name it derives (`List_<Name>`)
                    // is registered alongside, so the identity set the
                    // nominal-distinctness gate consults covers both the entry
                    // and the containers built over it. Idempotent on the
                    // registry side — the LOUD collision is the checker's scan
                    // (it can cite both registrants); this scan only feeds the
                    // identity test.
                    const is_proto = std.mem.eql(u8, last_seg, "proto");
                    if ((is_decl_tor or is_proto) and inv.args.len > 0) {
                        var name = inv.args[0].value;
                        if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"')
                            name = name[1 .. name.len - 1];
                        if (name.len > 0) try self.registerDeclaredType(name);
                        if (is_proto and name.len > 0) {
                            const container = try std.fmt.allocPrint(self.allocator, "List_{s}", .{name});
                            defer self.allocator.free(container);
                            try self.registerDeclaredType(container);
                        }
                    }
                }
            },
            .immediate_impl => |ii| {
                const canonical_name = try self.buildCanonicalName(&ii.event_path);
                defer self.allocator.free(canonical_name);
                try self.registerImmediateImpl(canonical_name, &ii);
            },
            .module_decl => |module| {
                // Recursively process module items
                for (module.items) |module_item| {
                    try self.populateFromItem(module_item);
                }
            },
            .import_decl, .host_line, .host_type_decl, .parse_error, .event_tap, .label_decl, .native_loop, .fused_event, .inlined_event, .inline_code => {
                // These don't need registration in TypeRegistry
            },
        }
    }

    /// Register a declared type identity. Idempotent — the same name at two
    /// declaration sites is one entry (the deterministic name IS the identity).
    pub fn registerDeclaredType(self: *TypeRegistry, name: []const u8) !void {
        if (self.declared_types.contains(name)) return;
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.declared_types.put(key, {});
    }

    /// Is this name a declared type identity (minted by a std/types tor)?
    pub fn isDeclaredType(self: *const TypeRegistry, name: []const u8) bool {
        return self.declared_types.contains(name);
    }

    /// Build canonical name from a DottedPath (after canonicalization)
    /// Format: "module:segment.segment.segment"
    fn buildCanonicalName(self: *TypeRegistry, path: *const ast.DottedPath) ![]const u8 {
        // After canonicalization, ALL paths must have module_qualifier set
        const module = path.module_qualifier orelse {
            log.debug("FATAL: buildCanonicalName called on non-canonicalized path!\n", .{});
            log.debug("  Path segments: ", .{});
            for (path.segments, 0..) |seg, i| {
                if (i > 0) log.debug(".", .{});
                log.debug("{s}", .{seg});
            }
            log.debug("\n", .{});
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
                    .module_path = if (field.module_path) |mp| try self.allocator.dupe(u8, mp) else null,
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
    // True when the event declares any `!` effect branch — its emitted
    // handler then takes `(Input, comptime __H: type)`, and every call
    // site must pass a Handlers type (empty `struct {}` when no arms are
    // installed). Recorded here because cross-module call sites resolve
    // through the registry, where ast branch kinds are otherwise lost.
    has_effect_branches: bool = false,
    is_public: bool = false,
    is_implicit_flow: bool = false,  // True for events with single Source param
    return_type: ?[]const u8 = null,  // `-> T` bare return type (mirrors ast.EventDecl.return_type); null = branch-based event

    pub fn deinit(self: *EventType, allocator: std.mem.Allocator) void {
        if (self.return_type) |rt| allocator.free(rt);
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

/// The type→module registry: which host types does this program declare, and
/// in which module? Built from the program's final (post-transform) items —
/// imported modules ride along as module_decl items, and synthesized
/// declarations (e.g. std/store's `pub const <Entity> = ...` entity alias,
/// appended as a host_line during flow expansion) are visible. This is the
/// emission-time ground truth writeFieldType consults to resolve a bare
/// phantom-carrying base type's home from actual declarations. There is no
/// name-shape guessing.
///
/// Maps declared name → declaring module's logical name ("" for the program's
/// own top level). Position in the item tree is the truth: a decl registers
/// under its enclosing module_decl, whatever any per-item module tag says.
/// A top-level ("") declaration always wins a name collision — the user's own
/// type shadows a module's; between modules, first declaration wins.
///
/// Keys and values are slices into the item ASTs — the map must not outlive
/// the program's allocation.
pub const HostTypeHomes = std.StringHashMap([]const u8);

pub fn buildHostTypeHomes(allocator: std.mem.Allocator, items: []const ast.Item) !HostTypeHomes {
    var homes = HostTypeHomes.init(allocator);
    errdefer homes.deinit();
    try collectHostTypeHomes(&homes, items, "");
    return homes;
}

fn collectHostTypeHomes(homes: *HostTypeHomes, items: []const ast.Item, enclosing_module: []const u8) !void {
    for (items) |item| {
        switch (item) {
            .host_line => |hl| try scanHostDecls(homes, hl.content, enclosing_module),
            .host_type_decl => |ht| try registerHome(homes, ht.name, enclosing_module),
            .module_decl => |m| try collectHostTypeHomes(homes, m.items, m.logical_name),
            else => {},
        }
    }
}

fn registerHome(homes: *HostTypeHomes, name: []const u8, module: []const u8) !void {
    const gop = try homes.getOrPut(name);
    if (!gop.found_existing or module.len == 0) gop.value_ptr.* = module;
}

/// Register every top-level `const NAME` / `pub const NAME` in a host-code blob.
/// Top-level means column 0 — nested decls (struct fields, fn locals) are
/// indented and deliberately excluded: only module-scope names are addressable
/// as field types.
fn scanHostDecls(homes: *HostTypeHomes, content: []const u8, module: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var rest = line;
        if (std.mem.startsWith(u8, rest, "pub ")) rest = rest[4..];
        if (!std.mem.startsWith(u8, rest, "const ")) continue;
        rest = rest[6..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        if (end == 0) continue;
        try registerHome(homes, rest[0..end], module);
    }
}

/// Module-name equality across spelling conventions: the phantom qualifier
/// spells `std/field` (slash canon), a module_decl's logical name spells
/// `std.field` (dotted namespace). Separators unify; everything else is exact.
pub fn moduleNamesMatch(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '/') '.' else ca;
        const nb = if (cb == '/') '.' else cb;
        if (na != nb) return false;
    }
    return true;
}

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

test "declared types register and look up as name-keyed identities" {
    var registry = TypeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerDeclaredType("Player");
    try registry.registerDeclaredType("box#i64");
    try registry.registerDeclaredType("box#f64");

    try std.testing.expect(registry.isDeclaredType("Player"));
    try std.testing.expect(registry.isDeclaredType("box#i64"));
    try std.testing.expect(registry.isDeclaredType("box#f64"));

    // Primitives and the Koru surface `string` are NOT declared identities.
    try std.testing.expect(!registry.isDeclaredType("i64"));
    try std.testing.expect(!registry.isDeclaredType("string"));
    try std.testing.expect(!registry.isDeclaredType("Meters"));

    // Idempotent: the same stamped name at two sites is one entry.
    try registry.registerDeclaredType("box#i64");
    try std.testing.expect(registry.isDeclaredType("box#i64"));
}
