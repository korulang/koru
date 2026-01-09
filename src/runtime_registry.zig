// ============================================================================
// Runtime Registry - Stores scope definitions for runtime dispatch
// ============================================================================
// Populated by the registry collection pass, consumed by the emitter to
// generate per-scope dispatcher functions.
//
// Design:
// - Each scope has a name and a list of fully-qualified event names
// - Globs and scope compositions are resolved at collection time
// - The emitter generates a dispatcher per scope with only the allowed events

const std = @import("std");

pub const RuntimeScope = struct {
    name: []const u8,
    /// Fully-qualified event names (e.g., "greet", "std.io:print.ln")
    events: []const []const u8,
};

pub const RuntimeRegistry = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(RuntimeScope),

    pub fn init(allocator: std.mem.Allocator) RuntimeRegistry {
        return .{
            .allocator = allocator,
            .scopes = std.ArrayList(RuntimeScope){
                .items = &.{},
                .capacity = 0,
            },
        };
    }

    pub fn deinit(self: *RuntimeRegistry) void {
        for (self.scopes.items) |scope| {
            self.allocator.free(scope.name);
            for (scope.events) |event| {
                self.allocator.free(event);
            }
            self.allocator.free(scope.events);
        }
        self.scopes.deinit();
    }

    /// Add a new scope with resolved event list
    pub fn addScope(self: *RuntimeRegistry, name: []const u8, events: []const []const u8) !void {
        // Duplicate strings for ownership
        const owned_name = try self.allocator.dupe(u8, name);
        const owned_events = try self.allocator.alloc([]const u8, events.len);
        for (events, 0..) |event, i| {
            owned_events[i] = try self.allocator.dupe(u8, event);
        }

        try self.scopes.append(self.allocator, .{
            .name = owned_name,
            .events = owned_events,
        });
    }

    /// Get a scope by name (for scope composition lookup)
    pub fn getScope(self: *const RuntimeRegistry, name: []const u8) ?*const RuntimeScope {
        for (self.scopes.items) |*scope| {
            if (std.mem.eql(u8, scope.name, name)) {
                return scope;
            }
        }
        return null;
    }

    /// Check if registry has any scopes (determines if dispatcher code is needed)
    pub fn hasScopes(self: *const RuntimeRegistry) bool {
        return self.scopes.items.len > 0;
    }
};

// ============================================================================
// Registry Entry Parser - Parses Source block lines
// ============================================================================

pub const RegistryEntry = union(enum) {
    event: []const u8,            // Direct event: "greet" or "std.io:print.ln"
    glob_prefix: []const u8,       // Glob: "users" from "users:*"
    scope_ref: []const u8,         // scope(other) reference
};

pub fn parseRegistrySource(allocator: std.mem.Allocator, source: []const u8) ![]RegistryEntry {
    var entries = std.ArrayList(RegistryEntry){ .items = &.{}, .capacity = 0 };
    errdefer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;

        // Skip conditional prefix for now: [debug]event -> event
        var entry_text = trimmed;
        if (entry_text[0] == '[') {
            if (std.mem.indexOf(u8, entry_text, "]")) |close| {
                entry_text = std.mem.trim(u8, entry_text[close + 1..], " \t");
            }
        }

        const entry = try parseRegistryLine(allocator, entry_text);
        try entries.append(allocator, entry);
    }

    return entries.toOwnedSlice(allocator);
}

fn parseRegistryLine(allocator: std.mem.Allocator, line: []const u8) !RegistryEntry {
    const trimmed = std.mem.trim(u8, line, " \t");

    // Check for scope composition: scope(name)
    if (std.mem.startsWith(u8, trimmed, "scope(")) {
        const close_paren = std.mem.indexOf(u8, trimmed, ")") orelse return error.InvalidSyntax;
        return RegistryEntry{ .scope_ref = try allocator.dupe(u8, trimmed[6..close_paren]) };
    }

    // Check for glob or qualified event (contains ":")
    if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
        const prefix = trimmed[0..colon_pos];
        const suffix = trimmed[colon_pos + 1..];

        // Check for glob: prefix:*
        if (std.mem.eql(u8, suffix, "*")) {
            return RegistryEntry{ .glob_prefix = try allocator.dupe(u8, prefix) };
        }

        // Module-qualified event
        return RegistryEntry{ .event = try allocator.dupe(u8, trimmed) };
    }

    // Simple event reference
    return RegistryEntry{ .event = try allocator.dupe(u8, trimmed) };
}

/// Expand a list of registry entries into concrete event names
pub fn expandEntries(
    allocator: std.mem.Allocator,
    entries: []const RegistryEntry,
    all_events: []const EventInfo,
    scope_lookup: *const RuntimeRegistry,
) ![][]const u8 {
    var result = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    errdefer result.deinit(allocator);

    for (entries) |entry| {
        switch (entry) {
            .event => |name| {
                try result.append(allocator, try allocator.dupe(u8, name));
            },
            .glob_prefix => |prefix| {
                // Expand glob by matching against all_events
                for (all_events) |ev| {
                    if (matchGlob(prefix, ev.qualified_name)) {
                        try result.append(allocator, try allocator.dupe(u8, ev.qualified_name));
                    }
                }
            },
            .scope_ref => |scope_name| {
                // Include events from referenced scope
                if (scope_lookup.getScope(scope_name)) |scope| {
                    for (scope.events) |ev| {
                        try result.append(allocator, try allocator.dupe(u8, ev));
                    }
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// Event Collector - Gathers all event declarations from AST
// ============================================================================
// Used for glob expansion - we need to know what events exist to expand "users:*"

pub const EventInfo = struct {
    /// Fully-qualified name (e.g., "users.get", "std.io:print.ln")
    qualified_name: []const u8,
    /// Module path if from import
    module: ?[]const u8,
    /// Local event name within module
    local_name: []const u8,
};

pub fn collectAllEvents(allocator: std.mem.Allocator, ast: anytype) ![]EventInfo {
    var events = std.ArrayList(EventInfo){ .items = &.{}, .capacity = 0 };
    errdefer events.deinit(allocator);

    // Walk AST items
    for (ast.items) |item| {
        switch (item) {
            .event_decl => |event| {
                // Top-level event - get name from path segments
                if (event.path.segments.len > 0) {
                    // Join segments with dots for the full name
                    var name_buf: [256]u8 = undefined;
                    var name_len: usize = 0;
                    for (event.path.segments, 0..) |seg, i| {
                        if (i > 0) {
                            name_buf[name_len] = '.';
                            name_len += 1;
                        }
                        @memcpy(name_buf[name_len..][0..seg.len], seg);
                        name_len += seg.len;
                    }
                    const name = try allocator.dupe(u8, name_buf[0..name_len]);
                    try events.append(allocator, .{
                        .qualified_name = name,
                        .module = null,
                        .local_name = name,
                    });
                }
            },
            .module_decl => |module| {
                // Events inside modules
                for (module.items) |mod_item| {
                    if (mod_item == .event_decl) {
                        const event = mod_item.event_decl;
                        if (event.path.segments.len > 0) {
                            // Build event name from path segments
                            var event_name_buf: [256]u8 = undefined;
                            var event_name_len: usize = 0;
                            for (event.path.segments, 0..) |seg, i| {
                                if (i > 0) {
                                    event_name_buf[event_name_len] = '.';
                                    event_name_len += 1;
                                }
                                @memcpy(event_name_buf[event_name_len..][0..seg.len], seg);
                                event_name_len += seg.len;
                            }
                            const event_name = event_name_buf[0..event_name_len];

                            // Qualified name: module.path:event.path
                            const qualified = try std.fmt.allocPrint(
                                allocator,
                                "{s}:{s}",
                                .{ module.logical_name, event_name },
                            );
                            try events.append(allocator, .{
                                .qualified_name = qualified,
                                .module = try allocator.dupe(u8, module.logical_name),
                                .local_name = try allocator.dupe(u8, event_name),
                            });
                        }
                    }
                }
            },
            else => {},
        }
    }

    return events.toOwnedSlice(allocator);
}

/// Match events against a glob pattern (e.g., "users:*" matches "users:get", "users:list")
pub fn matchGlob(pattern_prefix: []const u8, event_name: []const u8) bool {
    // Pattern "users:*" should match "users:get", "users:list", etc.
    // Pattern "users.*" should match "users.get", "users.list" (dot-separated)

    // If event starts with prefix, it's a match
    // Handle both "prefix:" and "prefix." separators
    if (std.mem.startsWith(u8, event_name, pattern_prefix)) {
        const rest = event_name[pattern_prefix.len..];
        // Must have separator after prefix
        if (rest.len > 0 and (rest[0] == ':' or rest[0] == '.')) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "matchGlob - colon separator" {
    try std.testing.expect(matchGlob("users", "users:get"));
    try std.testing.expect(matchGlob("users", "users:list"));
    try std.testing.expect(matchGlob("std.io", "std.io:print.ln"));
    try std.testing.expect(!matchGlob("users", "admin:delete"));
    try std.testing.expect(!matchGlob("users", "userspace:thing")); // "userspace" != "users"
}

test "matchGlob - dot separator" {
    try std.testing.expect(matchGlob("users", "users.get"));
    try std.testing.expect(matchGlob("users", "users.nested.thing"));
    try std.testing.expect(!matchGlob("users", "usersget")); // No separator
}

test "RuntimeRegistry - add and get scope" {
    var registry = RuntimeRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const events = &[_][]const u8{ "greet", "farewell" };
    try registry.addScope("api", events);

    const scope = registry.getScope("api");
    try std.testing.expect(scope != null);
    try std.testing.expectEqualStrings("api", scope.?.name);
    try std.testing.expectEqual(@as(usize, 2), scope.?.events.len);
}
