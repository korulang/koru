const std = @import("std");

/// JSON file structure for koru.json
const KoruJson = struct {
    name: []const u8 = "unnamed",
    version: []const u8 = "0.0.0",
    description: ?[]const u8 = null,
    paths: ?std.json.ArrayHashMap([]const u8) = null,
};

/// Koru project configuration loaded from koru.json
pub const Config = struct {
    name: []const u8,
    version: []const u8,
    paths: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);

        var iter = self.paths.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.paths.deinit();
    }

    /// Load koru.json from the project root
    /// Returns null if no koru.json found (use defaults)
    pub fn load(allocator: std.mem.Allocator, project_root: []const u8) !?Config {
        const json_path = try std.fs.path.join(allocator, &[_][]const u8{ project_root, "koru.json" });
        defer allocator.free(json_path);

        // Try to open koru.json
        const file = std.fs.cwd().openFile(json_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const source = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(source);

        return try parse(allocator, source);
    }

    /// Parse koru.json content using Zig's built-in JSON parser
    fn parse(allocator: std.mem.Allocator, source: []const u8) !Config {
        // Use Zig's native JSON parsing
        const parsed = try std.json.parseFromSlice(
            KoruJson,
            allocator,
            source,
            .{},
        );
        defer parsed.deinit();

        const json = parsed.value;

        // Convert to Config
        var paths = std.StringHashMap([]const u8).init(allocator);
        errdefer paths.deinit();

        // Copy paths from JSON if present
        if (json.paths) |json_paths| {
            var iter = json_paths.map.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = try allocator.dupe(u8, entry.value_ptr.*);

                // Validate: 'main' is reserved
                if (std.mem.eql(u8, key, "main")) {
                    std.debug.print("ERROR: Reserved namespace in koru.json:\n", .{});
                    std.debug.print("  Path alias 'main' is reserved for the entry module\n", .{});
                    return error.ReservedNamespace;
                }

                try paths.put(key, value);
            }
        }

        // Merge with defaults
        var defaults = try Config.default(allocator);
        defer defaults.deinit();

        var defaults_iter = defaults.paths.iterator();
        while (defaults_iter.next()) |entry| {
            if (!paths.contains(entry.key_ptr.*)) {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const value = try allocator.dupe(u8, entry.value_ptr.*);
                try paths.put(key, value);
            }
        }

        return Config{
            .name = try allocator.dupe(u8, json.name),
            .version = try allocator.dupe(u8, json.version),
            .paths = paths,
            .allocator = allocator,
        };
    }

    /// Get default configuration with built-in aliases
    pub fn default(allocator: std.mem.Allocator) !Config {
        var paths = std.StringHashMap([]const u8).init(allocator);

        // Default: $std points to global koru_std installation
        try paths.put(try allocator.dupe(u8, "std"), try allocator.dupe(u8, "/usr/local/lib/koru_std"));
        try paths.put(try allocator.dupe(u8, "lib"), try allocator.dupe(u8, "./lib"));
        try paths.put(try allocator.dupe(u8, "root"), try allocator.dupe(u8, "."));
        try paths.put(try allocator.dupe(u8, "app"), try allocator.dupe(u8, "{ENTRY}"));

        return Config{
            .name = try allocator.dupe(u8, "unnamed"),
            .version = try allocator.dupe(u8, "0.0.0"),
            .paths = paths,
            .allocator = allocator,
        };
    }
};
