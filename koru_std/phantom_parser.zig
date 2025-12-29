// Koru Phantom State Parser Library
// Interprets phantom strings according to Koru's state forwarding semantics

const std = @import("std");

/// Represents a parsed phantom state
pub const PhantomState = union(enum) {
    concrete: ConcreteState,
    variable: StateVariable,
    
    pub fn parse(allocator: std.mem.Allocator, phantom_str: []const u8) !PhantomState {
        // Check for state variable syntax (contains ' apostrophe)
        // Example: M'owned|borrowed, F'_
        if (std.mem.indexOf(u8, phantom_str, "'")) |apos_idx| {
            // This is a state variable!
            const var_name = phantom_str[0..apos_idx];
            const constraints = if (apos_idx + 1 < phantom_str.len)
                phantom_str[apos_idx + 1..]
            else
                null;

            return .{ .variable = .{
                .name = try allocator.dupe(u8, var_name),
                .constraints = if (constraints) |c|
                    try allocator.dupe(u8, c)
                else
                    null,
            }};
        }

        // Check for consumption marker (! prefix)
        // Example: !opened, !fs:opened
        var remaining = phantom_str;
        const consumes_obligation = if (remaining.len > 0 and remaining[0] == '!') blk: {
            remaining = remaining[1..];  // Strip the !
            break :blk true;
        } else false;

        // Check for module-qualified state (uses : like events)
        // Example: mipmap:open, fs:closed, fs:opened!
        if (std.mem.indexOf(u8, remaining, ":")) |colon_idx| {
            // Has module qualifier
            const module_path = remaining[0..colon_idx];
            var state_name = remaining[colon_idx + 1..];

            // Check for cleanup marker (! suffix)
            const requires_cleanup = if (state_name.len > 0 and state_name[state_name.len - 1] == '!') blk: {
                state_name = state_name[0..state_name.len - 1];  // Strip the !
                break :blk true;
            } else false;

            return .{ .concrete = .{
                .module_path = try allocator.dupe(u8, module_path),
                .name = try allocator.dupe(u8, state_name),
                .requires_cleanup = requires_cleanup,
                .consumes_obligation = consumes_obligation,
            }};
        }

        // Simple local state (no module qualifier)
        // Example: open, closed, opened!, !opened
        var state_name = remaining;

        // Check for cleanup marker (! suffix)
        const requires_cleanup = if (state_name.len > 0 and state_name[state_name.len - 1] == '!') blk: {
            state_name = state_name[0..state_name.len - 1];  // Strip the !
            break :blk true;
        } else false;

        return .{ .concrete = .{
            .module_path = null,
            .name = try allocator.dupe(u8, state_name),
            .requires_cleanup = requires_cleanup,
            .consumes_obligation = consumes_obligation,
        }};
    }
    
    pub fn deinit(self: *PhantomState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .concrete => |*c| c.deinit(allocator),
            .variable => |*v| v.deinit(allocator),
        }
    }
};

/// Concrete phantom state (e.g., "open", "mipmap:open", "fs:closed", "opened!", "!opened")
pub const ConcreteState = struct {
    module_path: ?[]const u8,  // null for local, "mipmap" for module-qualified
    name: []const u8,           // "open", "closed", "owned", etc.
    requires_cleanup: bool = false,  // true if state name ended with ! (e.g., "opened!")
    consumes_obligation: bool = false,  // true if state name starts with ! (e.g., "!opened")

    pub fn deinit(self: *ConcreteState, allocator: std.mem.Allocator) void {
        if (self.module_path) |path| allocator.free(path);
        allocator.free(self.name);
    }
};

/// State variable for forwarding (e.g., "M'owned|borrowed", "F'_")
pub const StateVariable = struct {
    name: []const u8,           // Variable name like "M", "F"
    constraints: ?[]const u8,   // "owned|borrowed|gc" or "_" for wildcard
    
    pub fn deinit(self: *StateVariable, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.constraints) |c| allocator.free(c);
    }
    
    /// Check if a concrete state satisfies this variable's constraints
    pub fn allows(self: StateVariable, state: []const u8) bool {
        const cons = self.constraints orelse return true; // No constraints = allow all
        
        // Wildcard constraint
        if (std.mem.eql(u8, cons, "_")) return true;
        
        // Check if state is in the constraint list
        var iter = std.mem.tokenizeScalar(u8, cons, '|');
        while (iter.next()) |allowed| {
            if (std.mem.eql(u8, allowed, state)) return true;
        }
        
        return false;
    }
};

/// Check if two phantom states are compatible for shape checking
pub fn areCompatible(allocator: std.mem.Allocator, required_str: ?[]const u8, provided_str: ?[]const u8) !bool {
    // No phantom requirement = accepts any state
    if (required_str == null) return true;
    
    // State required but not provided = incompatible
    if (provided_str == null) return false;
    
    const req_str = required_str.?;
    const prov_str = provided_str.?;
    
    // Parse both states
    const required = try PhantomState.parse(allocator, req_str);
    defer {
        var req_copy = required;
        req_copy.deinit(allocator);
    }
    
    const provided = try PhantomState.parse(allocator, prov_str);
    defer {
        var prov_copy = provided;
        prov_copy.deinit(allocator);
    }
    
    // Check compatibility based on types
    switch (required) {
        .concrete => |req_concrete| {
            switch (provided) {
                .concrete => |prov_concrete| {
                    // Module paths must match
                    const module_match = if (req_concrete.module_path) |req_mod|
                        if (prov_concrete.module_path) |prov_mod|
                            std.mem.eql(u8, req_mod, prov_mod)
                        else false
                    else
                        prov_concrete.module_path == null;
                    
                    if (!module_match) return false;
                    
                    // Names must match
                    return std.mem.eql(u8, req_concrete.name, prov_concrete.name);
                },
                .variable => return false, // Can't match concrete with variable
            }
        },
        .variable => |req_var| {
            switch (provided) {
                .concrete => |prov_concrete| {
                    // Check if concrete state satisfies variable constraints
                    const state_name = prov_concrete.name;
                    return req_var.allows(state_name);
                },
                .variable => |prov_var| {
                    // Variable names must match for forwarding
                    if (!std.mem.eql(u8, req_var.name, prov_var.name)) return false;
                    
                    // Constraints must be compatible
                    // TODO: More sophisticated constraint checking
                    const req_cons = req_var.constraints orelse "_";
                    const prov_cons = prov_var.constraints orelse "_";
                    return std.mem.eql(u8, req_cons, prov_cons);
                },
            }
        },
    }
}

/// Check if a phantom string represents a state variable
pub fn isStateVariable(phantom_str: []const u8) bool {
    return std.mem.indexOf(u8, phantom_str, "'") != null;
}

/// Extract the variable name from a state variable phantom
pub fn getVariableName(phantom_str: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, phantom_str, "'")) |apos_idx| {
        return phantom_str[0..apos_idx];
    }
    return null;
}

/// Check if two phantom strings represent the same forwarding variable
pub fn isSameVariable(phantom1: []const u8, phantom2: []const u8) bool {
    const var1 = getVariableName(phantom1);
    const var2 = getVariableName(phantom2);
    
    if (var1 == null or var2 == null) return false;
    return std.mem.eql(u8, var1.?, var2.?);
}

// Tests
test "parse concrete state" {
    const allocator = std.testing.allocator;
    
    const state = try PhantomState.parse(allocator, "open");
    defer {
        var s = state;
        s.deinit(allocator);
    }
    
    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expect(concrete.module_path == null);
    try std.testing.expectEqualStrings("open", concrete.name);
}

test "parse module-qualified state" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "mipmap:open");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expectEqualStrings("mipmap", concrete.module_path.?);
    try std.testing.expectEqualStrings("open", concrete.name);
}

test "parse state variable with constraints" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "M'owned|borrowed|gc");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .variable), @as(std.meta.Tag(PhantomState), state));
    const variable = state.variable;
    try std.testing.expectEqualStrings("M", variable.name);
    try std.testing.expectEqualStrings("owned|borrowed|gc", variable.constraints.?);
}

test "parse state variable with wildcard" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "F'_");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .variable), @as(std.meta.Tag(PhantomState), state));
    const variable = state.variable;
    try std.testing.expectEqualStrings("F", variable.name);
    try std.testing.expectEqualStrings("_", variable.constraints.?);
}

test "state variable allows constraint" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "M'owned|borrowed");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    const variable = state.variable;
    try std.testing.expect(variable.allows("owned"));
    try std.testing.expect(variable.allows("borrowed"));
    try std.testing.expect(!variable.allows("gc"));
}

test "compatibility checking" {
    const allocator = std.testing.allocator;

    // Concrete states must match exactly
    try std.testing.expect(try areCompatible(allocator, "open", "open"));
    try std.testing.expect(!try areCompatible(allocator, "open", "closed"));

    // Module-qualified states must match
    try std.testing.expect(try areCompatible(allocator, "fs:open", "fs:open"));
    try std.testing.expect(!try areCompatible(allocator, "fs:open", "mipmap:open"));

    // Variables with same name are compatible
    try std.testing.expect(try areCompatible(allocator, "M'owned|borrowed", "M'owned|borrowed"));
    try std.testing.expect(!try areCompatible(allocator, "M'owned", "N'owned"));

    // Wildcard accepts any state
    try std.testing.expect(try areCompatible(allocator, "F'_", "F'_"));

    // No requirement accepts anything
    try std.testing.expect(try areCompatible(allocator, null, "open"));
    try std.testing.expect(try areCompatible(allocator, null, null));
}

test "parse cleanup marker - local state" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "opened!");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expect(concrete.module_path == null);
    try std.testing.expectEqualStrings("opened", concrete.name);  // ! stripped
    try std.testing.expect(concrete.requires_cleanup);  // Flag set
}

test "parse cleanup marker - module-qualified state" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "fs:opened!");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expectEqualStrings("fs", concrete.module_path.?);
    try std.testing.expectEqualStrings("opened", concrete.name);  // ! stripped
    try std.testing.expect(concrete.requires_cleanup);  // Flag set
}

test "parse non-cleanup state" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "closed");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expectEqualStrings("closed", concrete.name);
    try std.testing.expect(!concrete.requires_cleanup);  // No cleanup needed
    try std.testing.expect(!concrete.consumes_obligation);  // Doesn't consume
}

test "parse consumption marker - local state" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "!opened");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expect(concrete.module_path == null);
    try std.testing.expectEqualStrings("opened", concrete.name);  // ! prefix stripped
    try std.testing.expect(!concrete.requires_cleanup);  // No ! suffix
    try std.testing.expect(concrete.consumes_obligation);  // ! prefix set
}

test "parse consumption marker - module-qualified state" {
    const allocator = std.testing.allocator;

    const state = try PhantomState.parse(allocator, "!fs:opened");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expectEqualStrings("fs", concrete.module_path.?);
    try std.testing.expectEqualStrings("opened", concrete.name);  // ! prefix stripped
    try std.testing.expect(!concrete.requires_cleanup);  // No ! suffix
    try std.testing.expect(concrete.consumes_obligation);  // ! prefix set
}

test "parse both markers - produces and consumes" {
    const allocator = std.testing.allocator;

    // Edge case: !opened! would mean both produces AND consumes
    // This might not make semantic sense, but parser should handle it
    const state = try PhantomState.parse(allocator, "!opened!");
    defer {
        var s = state;
        s.deinit(allocator);
    }

    try std.testing.expectEqual(@as(std.meta.Tag(PhantomState), .concrete), @as(std.meta.Tag(PhantomState), state));
    const concrete = state.concrete;
    try std.testing.expectEqualStrings("opened", concrete.name);
    try std.testing.expect(concrete.requires_cleanup);  // ! suffix
    try std.testing.expect(concrete.consumes_obligation);  // ! prefix
}