const std = @import("std");
const log = std.log.scoped(.config);

/// JSON file structure for koru.json
/// Note: paths can be either string or array of strings, handled in parsePathsFromJson
const KoruJson = struct {
    name: []const u8 = "unnamed",
    version: []const u8 = "0.0.0",
    description: ?[]const u8 = null,
    entry: ?[]const u8 = null,
    // paths handled separately via raw JSON parsing to support string | []string
};

/// Koru project configuration loaded from koru.json
/// paths maps alias -> array of fallback paths (tried in order until one exists)
pub const Config = struct {
    name: []const u8,
    version: []const u8,
    paths: std.StringHashMap([][]const u8),  // alias -> [path1, path2, ...]
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);

        var iter = self.paths.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Free each path in the array
            for (entry.value_ptr.*) |path| {
                self.allocator.free(path);
            }
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
        // Parse as dynamic JSON first to handle paths flexibility
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            source,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJson;

        // Extract name and version with defaults
        const name = if (root.object.get("name")) |v| switch (v) {
            .string => |s| s,
            else => "unnamed",
        } else "unnamed";

        const version = if (root.object.get("version")) |v| switch (v) {
            .string => |s| s,
            else => "0.0.0",
        } else "0.0.0";

        // Convert to Config
        var paths = std.StringHashMap([][]const u8).init(allocator);
        errdefer {
            var iter = paths.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.*) |p| allocator.free(p);
                allocator.free(entry.value_ptr.*);
            }
            paths.deinit();
        }

        // Parse paths - supports both string and array values
        if (root.object.get("paths")) |paths_value| {
            if (paths_value == .object) {
                var iter = paths_value.object.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);

                    // Validate: 'main' is reserved
                    if (std.mem.eql(u8, key, "main")) {
                        log.debug("ERROR: Reserved namespace in koru.json:\n", .{});
                        log.debug("  Path alias 'main' is reserved for the entry module\n", .{});
                        allocator.free(key);
                        return error.ReservedNamespace;
                    }

                    const path_array = switch (entry.value_ptr.*) {
                        // Single string -> wrap in array
                        .string => |s| blk: {
                            var arr = try allocator.alloc([]const u8, 1);
                            arr[0] = try allocator.dupe(u8, s);
                            break :blk arr;
                        },
                        // Array of strings -> copy each
                        .array => |arr| blk: {
                            var result = try allocator.alloc([]const u8, arr.items.len);
                            for (arr.items, 0..) |item, i| {
                                if (item == .string) {
                                    result[i] = try allocator.dupe(u8, item.string);
                                } else {
                                    // Invalid: array contains non-string
                                    for (result[0..i]) |p| allocator.free(p);
                                    allocator.free(result);
                                    allocator.free(key);
                                    return error.InvalidPathValue;
                                }
                            }
                            break :blk result;
                        },
                        else => {
                            allocator.free(key);
                            return error.InvalidPathValue;
                        },
                    };

                    try paths.put(key, path_array);
                }
            }
        }

        // Merge with defaults
        var defaults = try Config.default(allocator);
        defer defaults.deinit();

        var defaults_iter = defaults.paths.iterator();
        while (defaults_iter.next()) |entry| {
            if (!paths.contains(entry.key_ptr.*)) {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                // Copy the array of paths
                var path_array = try allocator.alloc([]const u8, entry.value_ptr.*.len);
                for (entry.value_ptr.*, 0..) |p, i| {
                    path_array[i] = try allocator.dupe(u8, p);
                }
                try paths.put(key, path_array);
            }
        }

        return Config{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .paths = paths,
            .allocator = allocator,
        };
    }

    /// Get default configuration with built-in aliases
    pub fn default(allocator: std.mem.Allocator) !Config {
        var paths = std.StringHashMap([][]const u8).init(allocator);

        // Helper to create single-element path array
        const makePath = struct {
            fn make(alloc: std.mem.Allocator, path: []const u8) ![][]const u8 {
                var arr = try alloc.alloc([]const u8, 1);
                arr[0] = try alloc.dupe(u8, path);
                return arr;
            }
        }.make;

        // Default: $std points to koru_std relative to koruc installation
        // {{ KORU_HOME }} is interpolated by ModuleResolver at resolution time
        try paths.put(try allocator.dupe(u8, "std"), try makePath(allocator, "{{ KORU_HOME }}/koru_std"));
        try paths.put(try allocator.dupe(u8, "lib"), try makePath(allocator, "./lib"));
        try paths.put(try allocator.dupe(u8, "root"), try makePath(allocator, "."));
        try paths.put(try allocator.dupe(u8, "app"), try makePath(allocator, "{{ ENTRY }}"));

        return Config{
            .name = try allocator.dupe(u8, "unnamed"),
            .version = try allocator.dupe(u8, "0.0.0"),
            .paths = paths,
            .allocator = allocator,
        };
    }
};
