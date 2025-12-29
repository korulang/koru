const std = @import("std");

/// Registry for keyword annotations that allow unqualified event invocation.
///
/// Events marked with [keyword] can be invoked without module qualification:
///   ~[keyword]pub event if { condition: bool } | then {} | else {}
///
///   ~if(condition)  // Instead of ~std.control:if(condition)
///
/// Collision tracking: If two imported modules define the same keyword,
/// the registry stores both - error is emitted only at usage time.
pub const KeywordRegistry = struct {
    allocator: std.mem.Allocator,

    /// Maps keyword name -> list of definitions (for collision detection)
    /// Example: "if" -> [KeywordInfo{canonical_path: "std.control:if", module: "std.control"}]
    keywords: std.StringHashMap(KeywordList),

    pub const KeywordInfo = struct {
        canonical_path: []const u8,  // Full path: "std.control:if"
        module_path: []const u8,     // Module that defines it: "std.control"
    };

    pub const KeywordList = struct {
        items: std.ArrayList(KeywordInfo),

        pub fn deinit(self: *KeywordList, allocator: std.mem.Allocator) void {
            // Free the stored strings
            for (self.items.items) |info| {
                allocator.free(info.canonical_path);
                allocator.free(info.module_path);
            }
            self.items.deinit(allocator);
        }

        pub fn hasCollision(self: *const KeywordList) bool {
            return self.items.items.len > 1;
        }
    };

    pub fn init(allocator: std.mem.Allocator) KeywordRegistry {
        return .{
            .allocator = allocator,
            .keywords = std.StringHashMap(KeywordList).init(allocator),
        };
    }

    pub fn deinit(self: *KeywordRegistry) void {
        var it = self.keywords.iterator();
        while (it.next()) |entry| {
            // Free the key (keyword name)
            self.allocator.free(entry.key_ptr.*);
            // Free the value (KeywordList and its contents)
            entry.value_ptr.deinit(self.allocator);
        }
        self.keywords.deinit();
    }

    /// Register a keyword from an event with [keyword] annotation.
    /// May have multiple entries for the same keyword (collision detection).
    pub fn registerKeyword(
        self: *KeywordRegistry,
        keyword_name: []const u8,
        canonical_path: []const u8,
        module_path: []const u8,
    ) !void {
        // Duplicate the strings for storage
        const canonical_copy = try self.allocator.dupe(u8, canonical_path);
        errdefer self.allocator.free(canonical_copy);

        const module_copy = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(module_copy);

        const gop = try self.keywords.getOrPut(keyword_name);
        if (!gop.found_existing) {
            // New keyword - need to dupe the key
            const key_copy = try self.allocator.dupe(u8, keyword_name);
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = KeywordList{ .items = .{} };
        }

        try gop.value_ptr.items.append(self.allocator, .{
            .canonical_path = canonical_copy,
            .module_path = module_copy,
        });
    }

    /// Resolve a keyword to its canonical path.
    /// Returns the canonical path if exactly one definition exists.
    /// Returns error.KeywordCollision if multiple modules define it.
    /// Returns null if not found.
    pub fn resolveKeyword(self: *const KeywordRegistry, keyword_name: []const u8) error{KeywordCollision}!?[]const u8 {
        if (self.keywords.get(keyword_name)) |list| {
            if (list.items.items.len == 1) {
                return list.items.items[0].canonical_path;
            } else if (list.items.items.len > 1) {
                return error.KeywordCollision;
            }
        }
        return null;
    }

    /// Get all definitions for a keyword (for collision error messages).
    pub fn getCollisionInfo(self: *const KeywordRegistry, keyword_name: []const u8) ?[]const KeywordInfo {
        if (self.keywords.get(keyword_name)) |list| {
            return list.items.items;
        }
        return null;
    }

    /// Check if a keyword exists (regardless of collisions).
    pub fn hasKeyword(self: *const KeywordRegistry, keyword_name: []const u8) bool {
        return self.keywords.contains(keyword_name);
    }

    /// Get count of registered keywords (for debugging/testing).
    pub fn count(self: *const KeywordRegistry) usize {
        return self.keywords.count();
    }
};

// Unit tests
test "register and resolve single keyword" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("if", "std.control:if", "std.control");

    const resolved = try registry.resolveKeyword("if");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("std.control:if", resolved.?);
}

test "resolve unknown keyword returns null" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    const resolved = try registry.resolveKeyword("unknown");
    try std.testing.expect(resolved == null);
}

test "collision detection returns error" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("process", "lib_a:process", "lib_a");
    try registry.registerKeyword("process", "lib_b:process", "lib_b");

    const result = registry.resolveKeyword("process");
    try std.testing.expectError(error.KeywordCollision, result);
}

test "get collision info" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("foo", "mod_a:foo", "mod_a");
    try registry.registerKeyword("foo", "mod_b:foo", "mod_b");

    const info = registry.getCollisionInfo("foo");
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 2), info.?.len);
    try std.testing.expectEqualStrings("mod_a:foo", info.?[0].canonical_path);
    try std.testing.expectEqualStrings("mod_b:foo", info.?[1].canonical_path);
}

test "multiple different keywords" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("if", "control:if", "control");
    try registry.registerKeyword("while", "control:while", "control");
    try registry.registerKeyword("print", "io:print", "io");

    try std.testing.expectEqual(@as(usize, 3), registry.count());

    const if_resolved = try registry.resolveKeyword("if");
    try std.testing.expectEqualStrings("control:if", if_resolved.?);

    const print_resolved = try registry.resolveKeyword("print");
    try std.testing.expectEqualStrings("io:print", print_resolved.?);
}
