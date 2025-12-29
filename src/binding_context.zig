const std = @import("std");
const ast = @import("ast");

/// Information about a binding in scope
pub const BindingInfo = struct {
    name: []const u8,
    type_path: []const u8,  // The type (e.g., "User", "i32")
    source_branch: ?[]const u8,  // Which branch this came from (if any)
    scope_depth: usize,
    is_mutable: bool,
};

/// A single scope in the binding stack
pub const Scope = struct {
    bindings: std.StringHashMap(BindingInfo),
    parent_depth: usize,
    scope_type: ScopeType,
    
    pub const ScopeType = enum {
        global,
        flow,
        continuation,
        pipeline,
        nested_continuation,
        label,
        subflow,
    };
    
    pub fn init(allocator: std.mem.Allocator, scope_type: ScopeType, parent_depth: usize) !Scope {
        return Scope{
            .bindings = std.StringHashMap(BindingInfo).init(allocator),
            .parent_depth = parent_depth,
            .scope_type = scope_type,
        };
    }
    
    pub fn deinit(self: *Scope) void {
        var iter = self.bindings.iterator();
        while (iter.next()) |entry| {
            // Note: We don't free the keys/values as they're owned by the allocator
            _ = entry;
        }
        self.bindings.deinit();
    }
};

/// Manages variable scopes and bindings during code emission
pub const BindingContext = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),
    current_depth: usize,
    
    pub fn init(allocator: std.mem.Allocator) !BindingContext {
        var ctx = BindingContext{
            .allocator = allocator,
            .scopes = std.ArrayList(Scope).init(allocator),
            .current_depth = 0,
        };
        
        // Create the global scope
        const global_scope = try Scope.init(allocator, .global, 0);
        try ctx.scopes.append(global_scope);
        
        return ctx;
    }
    
    pub fn deinit(self: *BindingContext) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit();
    }
    
    /// Push a new scope onto the stack
    pub fn pushScope(self: *BindingContext, scope_type: Scope.ScopeType) !void {
        self.current_depth += 1;
        const new_scope = try Scope.init(self.allocator, scope_type, self.current_depth - 1);
        try self.scopes.append(new_scope);
    }
    
    /// Pop the current scope from the stack
    pub fn popScope(self: *BindingContext) void {
        if (self.current_depth > 0) {
            const scope = self.scopes.pop();
            scope.deinit();
            self.current_depth -= 1;
        }
    }
    
    /// Add a binding to the current scope
    pub fn addBinding(self: *BindingContext, name: []const u8, binding: BindingInfo) !void {
        if (self.scopes.items.len == 0) return error.NoScope;
        
        const current_scope = &self.scopes.items[self.scopes.items.len - 1];
        const key = try self.allocator.dupe(u8, name);
        
        try current_scope.bindings.put(key, binding);
    }
    
    /// Resolve a binding by searching up the scope chain
    pub fn resolve(self: *const BindingContext, name: []const u8) ?BindingInfo {
        // Search from current scope upward
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.bindings.get(name)) |binding| {
                return binding;
            }
        }
        return null;
    }
    
    /// Check if a binding exists in the current scope only
    pub fn hasLocalBinding(self: *const BindingContext, name: []const u8) bool {
        if (self.scopes.items.len == 0) return false;
        const current_scope = &self.scopes.items[self.scopes.items.len - 1];
        return current_scope.bindings.contains(name);
    }
    
    /// Get all bindings at the current scope level
    pub fn getCurrentBindings(self: *const BindingContext) ?std.StringHashMap(BindingInfo) {
        if (self.scopes.items.len == 0) return null;
        return self.scopes.items[self.scopes.items.len - 1].bindings;
    }
    
    /// Create a snapshot of current bindings (for label context capture)
    pub fn captureContext(self: *const BindingContext) !std.ArrayList(BindingInfo) {
        var captured = std.ArrayList(BindingInfo).init(self.allocator);
        
        // Collect all bindings from all scopes
        for (self.scopes.items) |scope| {
            var iter = scope.bindings.iterator();
            while (iter.next()) |entry| {
                try captured.append(entry.value_ptr.*);
            }
        }
        
        return captured;
    }
    
    /// Get the current scope type
    pub fn getCurrentScopeType(self: *const BindingContext) ?Scope.ScopeType {
        if (self.scopes.items.len == 0) return null;
        return self.scopes.items[self.scopes.items.len - 1].scope_type;
    }
    
    /// Get the depth of the current scope
    pub fn getCurrentDepth(self: *const BindingContext) usize {
        return self.current_depth;
    }
    
    /// Check if we're in a specific type of scope
    pub fn isInScope(self: *const BindingContext, scope_type: Scope.ScopeType) bool {
        for (self.scopes.items) |scope| {
            if (scope.scope_type == scope_type) {
                return true;
            }
        }
        return false;
    }
};