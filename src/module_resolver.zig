const std = @import("std");
const Config = @import("config").Config;

const DEBUG = false;  // Set to true for verbose module resolution logging

/// ModuleResolver handles finding and loading Koru modules from various locations
/// Search order:
/// 1. Relative to the importing file
/// 2. Project .paths from koru.json
/// 3. KORU_PATH directories
/// 4. Standard library location
/// 5. Absolute paths
///
/// Import semantics:
/// - If both foo.kz and foo/ exist, ~import "foo" imports BOTH
/// - foo.kz becomes the main module
/// - foo/*.kz files become submodules
pub const ResolveResult = struct {
    file_path: ?[]const u8,      // Path to foo.kz (if exists)
    dir_path: ?[]const u8,       // Path to foo/ (if exists)

    pub fn deinit(self: *ResolveResult, allocator: std.mem.Allocator) void {
        if (self.file_path) |p| allocator.free(p);
        if (self.dir_path) |p| allocator.free(p);
    }
};

pub const ModuleResolver = struct {
    allocator: std.mem.Allocator,
    search_paths: std.ArrayList([]const u8),
    stdlib_path: ?[]const u8,
    config: *const Config,
    project_root: []const u8,  // Directory containing koru.json (for resolving alias paths)
    entry_dir: []const u8,     // Directory of the entry file being compiled (for {ENTRY} interpolation)
    parsing_files: std.StringHashMap(void),  // Track files currently being parsed (for cycle detection)

    pub fn init(allocator: std.mem.Allocator, config: *const Config, project_root: []const u8, entry_dir: []const u8) !ModuleResolver {
        var resolver = ModuleResolver{
            .allocator = allocator,
            .search_paths = std.ArrayList([]const u8){
                .items = &.{},
                .capacity = 0,
            },
            .stdlib_path = null,
            .config = config,
            .project_root = project_root,
            .entry_dir = entry_dir,
            .parsing_files = std.StringHashMap(void).init(allocator),
        };

        // Initialize with default search paths
        try resolver.initializeSearchPaths();

        return resolver;
    }
    
    pub fn deinit(self: *ModuleResolver) void {
        for (self.search_paths.items) |path| {
            self.allocator.free(path);
        }
        self.search_paths.deinit(self.allocator);

        if (self.stdlib_path) |path| {
            self.allocator.free(path);
        }

        // Clean up parsing_files keys
        var it = self.parsing_files.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.parsing_files.deinit();
    }

    /// Check if a file is currently being parsed (cycle detection)
    pub fn isBeingParsed(self: *ModuleResolver, file_path: []const u8) bool {
        return self.parsing_files.contains(file_path);
    }

    /// Mark a file as being parsed
    pub fn markParsing(self: *ModuleResolver, file_path: []const u8) !void {
        const key = try self.allocator.dupe(u8, file_path);
        try self.parsing_files.put(key, {});
    }

    /// Unmark a file as being parsed
    pub fn unmarkParsing(self: *ModuleResolver, file_path: []const u8) void {
        if (self.parsing_files.fetchRemove(file_path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Interpolate {ENTRY} placeholder with entry_dir
    /// Returns new string if interpolation happened, null otherwise
    fn interpolateEntry(self: *ModuleResolver, path: []const u8) !?[]u8 {
        if (std.mem.indexOf(u8, path, "{ENTRY}")) |pos| {
            // Build new string: prefix + entry_dir + suffix
            const prefix = path[0..pos];
            const suffix = path[pos + 7..]; // Skip "{ENTRY}"

            return try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}{s}",
                .{ prefix, self.entry_dir, suffix }
            );
        }
        return null;
    }

    fn initializeSearchPaths(self: *ModuleResolver) !void {
        // 1. Check KORU_PATH environment variable
        if (std.process.getEnvVarOwned(self.allocator, "KORU_PATH")) |koru_path| {
            defer self.allocator.free(koru_path);
            
            // Split by : on Unix, ; on Windows
            const delimiter = if (@import("builtin").os.tag == .windows) ';' else ':';
            var it = std.mem.tokenizeAny(u8, koru_path, &[_]u8{delimiter});
            while (it.next()) |path| {
                try self.search_paths.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        } else |_| {
            // KORU_PATH not set, that's okay
        }
        
        // 2. Check KORU_STDLIB environment variable
        if (std.process.getEnvVarOwned(self.allocator, "KORU_STDLIB")) |stdlib| {
            self.stdlib_path = stdlib; // Take ownership
        } else |_| {
            // Try to find stdlib relative to executable
            self.stdlib_path = try self.findDefaultStdlibPath();
        }
    }
    
    fn findDefaultStdlibPath(self: *ModuleResolver) !?[]const u8 {
        if (DEBUG) std.debug.print("ModuleResolver: Searching for stdlib (koru_std)...\n", .{});

        // Try: /usr/local/lib/koru_std (global installation)
        const global_path = "/usr/local/lib/koru_std";
        if (DEBUG) std.debug.print("  Trying: {s}\n", .{global_path});
        if (std.fs.cwd().access(global_path, .{})) |_| {
            if (DEBUG) std.debug.print("  ✓ FOUND stdlib at: {s}\n", .{global_path});
            return try self.allocator.dupe(u8, global_path);
        } else |err| {
            if (DEBUG) std.debug.print("  ✗ Not found: {}\n", .{err});
        }

        // Get the path to the current executable for relative lookups
        var exe_path_buf: [4096]u8 = undefined;
        const exe_path = try std.fs.selfExePath(&exe_path_buf);
        const exe_dir = std.fs.path.dirname(exe_path) orelse return null;

        // Try: executable_dir/../koru_std
        const candidate1 = try std.fs.path.join(self.allocator, &[_][]const u8{
            exe_dir, "..", "koru_std"
        });
        defer self.allocator.free(candidate1);

        if (DEBUG) std.debug.print("  Trying: {s}\n", .{candidate1});
        if (std.fs.cwd().access(candidate1, .{})) |_| {
            if (DEBUG) std.debug.print("  ✓ FOUND stdlib at: {s}\n", .{candidate1});
            return try self.allocator.dupe(u8, candidate1);
        } else |err| {
            if (DEBUG) std.debug.print("  ✗ Not found: {}\n", .{err});
        }

        // Try: executable_dir/../../koru_std (for zig-out/bin/koruc)
        const candidate2 = try std.fs.path.join(self.allocator, &[_][]const u8{
            exe_dir, "..", "..", "koru_std"
        });
        defer self.allocator.free(candidate2);

        if (DEBUG) std.debug.print("  Trying: {s}\n", .{candidate2});
        if (std.fs.cwd().access(candidate2, .{})) |_| {
            if (DEBUG) std.debug.print("  ✓ FOUND stdlib at: {s}\n", .{candidate2});
            return try self.allocator.dupe(u8, candidate2);
        } else |err| {
            if (DEBUG) std.debug.print("  ✗ Not found: {}\n", .{err});
        }

        // Try: ./koru_std (current directory)
        if (DEBUG) std.debug.print("  Trying: ./koru_std\n", .{});
        if (std.fs.cwd().access("koru_std", .{})) |_| {
            if (DEBUG) std.debug.print("  ✓ FOUND stdlib at: ./koru_std\n", .{});
            return try self.allocator.dupe(u8, "koru_std");
        } else |err| {
            if (DEBUG) std.debug.print("  ✗ Not found: {}\n", .{err});
        }

        if (DEBUG) std.debug.print("  ✗✗✗ STDLIB NOT FOUND ANYWHERE ✗✗✗\n", .{});
        return null;
    }
    
    /// Check if a path is a directory
    pub fn isDirectory(path: []const u8) bool {
        const dir = std.fs.cwd().openDir(path, .{}) catch return false;
        var d = dir;
        d.close();
        return true;
    }

    /// Enumerate all .kz files in a directory
    /// Returns owned slice that must be freed by caller
    /// Each string in the slice must also be freed
    pub fn enumerateDirectory(
        self: *ModuleResolver,
        dir_path: []const u8,
    ) ![][]const u8 {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var files = std.ArrayList([]const u8){
            .items = &.{},
            .capacity = 0,
        };
        errdefer {
            for (files.items) |file| self.allocator.free(file);
            files.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".kz")) continue;

            // Build full path: dir_path/file.kz
            const full_path = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ dir_path, entry.name }
            );
            try files.append(self.allocator, full_path);
        }

        return try files.toOwnedSlice(self.allocator);
    }

    /// Resolve an import path to BOTH file and directory (if they exist)
    /// This enables importing both foo.kz and foo/ directory simultaneously
    /// Returns ResolveResult with file_path and/or dir_path set
    pub fn resolveBoth(
        self: *ModuleResolver,
        import_path: []const u8,
        base_file: ?[]const u8,
    ) !ResolveResult {
        if (DEBUG) std.debug.print("\n═══ ModuleResolver.resolveBoth() ═══\n", .{});
        if (DEBUG) std.debug.print("  Import path: '{s}'\n", .{import_path});
        if (base_file) |bf| {
            if (DEBUG) std.debug.print("  Base file: '{s}'\n", .{bf});
        } else {
            if (DEBUG) std.debug.print("  Base file: (none)\n", .{});
        }

        var result = ResolveResult{
            .file_path = null,
            .dir_path = null,
        };

        // Handle $alias path prefixes
        var resolved_import_path = import_path;

        if (import_path.len > 0 and import_path[0] == '$') {
            const slash_pos = std.mem.indexOf(u8, import_path, "/");
            const alias_end = slash_pos orelse import_path.len;
            const alias = import_path[1..alias_end];

            if (DEBUG) std.debug.print("  Resolving alias: ${s}\n", .{alias});

            if (self.config.paths.get(alias)) |alias_path_raw| {
                // Interpolate {ENTRY} if present
                const alias_path = if (try self.interpolateEntry(alias_path_raw)) |interpolated|
                    interpolated
                else
                    alias_path_raw;
                defer if (alias_path.ptr != alias_path_raw.ptr) self.allocator.free(alias_path);

                if (DEBUG) std.debug.print("  ✓ Alias found: ${s} -> {s}\n", .{alias, alias_path});

                // Build and resolve path - this creates owned memory that needs cleanup
                {
                    // Build the path to check (alias + remainder if any)
                    const path_to_resolve = if (slash_pos) |pos| blk: {
                        const remainder = import_path[pos + 1..];
                        break :blk try std.fs.path.join(
                            self.allocator,
                            &[_][]const u8{ alias_path, remainder }
                        );
                    } else blk: {
                        break :blk try self.allocator.dupe(u8, alias_path);
                    };
                    defer self.allocator.free(path_to_resolve);

                    // Alias paths are RELATIVE TO PROJECT ROOT (where koru.json is)
                    // Resolve them absolutely using project_root as base
                    const absolute_path = if (std.fs.path.isAbsolute(path_to_resolve))
                        try self.allocator.dupe(u8, path_to_resolve)
                    else
                        try std.fs.path.resolve(self.allocator, &[_][]const u8{ self.project_root, path_to_resolve });
                    defer self.allocator.free(absolute_path);

                    resolved_import_path = absolute_path;
                    if (DEBUG) std.debug.print("  Resolved to (absolute): {s}\n", .{resolved_import_path});

                    // Check for BOTH file and directory
                    if (DEBUG) std.debug.print("  [ALIAS] Checking for both file and directory...\n", .{});

                    // Check directory
                    if (isDirectory(resolved_import_path)) {
                        const dir_resolved = try std.fs.path.resolve(
                            self.allocator,
                            &[_][]const u8{resolved_import_path}
                        );
                        result.dir_path = dir_resolved;
                        if (DEBUG) std.debug.print("    ✓ FOUND directory: {s}\n", .{dir_resolved});
                    }

                    // Check file
                    const needs_ext = !std.mem.endsWith(u8, resolved_import_path, ".kz");
                    const path_with_ext = if (needs_ext)
                        try std.fmt.allocPrint(self.allocator, "{s}.kz", .{resolved_import_path})
                    else
                        try self.allocator.dupe(u8, resolved_import_path);
                    defer self.allocator.free(path_with_ext);

                    if (std.fs.cwd().access(path_with_ext, .{})) |_| {
                        const file_resolved = try std.fs.path.resolve(
                            self.allocator,
                            &[_][]const u8{path_with_ext}
                        );
                        result.file_path = file_resolved;
                        if (DEBUG) std.debug.print("    ✓ FOUND file: {s}\n", .{file_resolved});
                    } else |_| {}

                    if (result.file_path == null and result.dir_path == null) {
                        if (DEBUG) std.debug.print("\n✗✗✗ FATAL: Alias ${s} resolved to '{s}' but nothing found ✗✗✗\n", .{alias, resolved_import_path});
                        return error.ModuleNotFound;
                    }
                } // absolute_path and path_to_resolve freed here

                return result;
            } else {
                if (DEBUG) std.debug.print("✗✗✗ FATAL: Unknown import alias: ${s}\n", .{alias});
                if (DEBUG) std.debug.print("Available aliases from koru.json:\n", .{});
                var iter = self.config.paths.iterator();
                while (iter.next()) |entry| {
                    if (DEBUG) std.debug.print("  ${s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                return error.UnknownImportAlias;
            }
        }

        // Helper to check both file and dir at a given base path
        const checkBoth = struct {
            fn check(alloc: std.mem.Allocator, base: []const u8, import: []const u8, res: *ResolveResult) !bool {
                var found_any = false;

                // Check directory
                const dir_candidate = try std.fs.path.join(
                    alloc,
                    &[_][]const u8{ base, import }
                );
                defer alloc.free(dir_candidate);

                if (isDirectory(dir_candidate)) {
                    const resolved = try std.fs.path.resolve(alloc, &[_][]const u8{dir_candidate});
                    res.dir_path = resolved;
                    if (DEBUG) std.debug.print("      ✓ FOUND directory: {s}\n", .{resolved});
                    found_any = true;
                }

                // Check file
                const needs_ext = !std.mem.endsWith(u8, import, ".kz");
                const path_with_ext = if (needs_ext)
                    try std.fmt.allocPrint(alloc, "{s}.kz", .{import})
                else
                    try alloc.dupe(u8, import);
                defer alloc.free(path_with_ext);

                const file_candidate = try std.fs.path.join(
                    alloc,
                    &[_][]const u8{ base, path_with_ext }
                );
                defer alloc.free(file_candidate);

                if (std.fs.cwd().access(file_candidate, .{})) |_| {
                    const resolved = try std.fs.path.resolve(alloc, &[_][]const u8{file_candidate});
                    res.file_path = resolved;
                    if (DEBUG) std.debug.print("      ✓ FOUND file: {s}\n", .{resolved});
                    found_any = true;
                } else |_| {}

                return found_any;
            }
        }.check;

        // 1. Absolute path
        if (std.fs.path.isAbsolute(resolved_import_path)) {
            if (try checkBoth(self.allocator, "", resolved_import_path, &result)) {
                return result;
            }
        }

        // 2. Relative to importing file
        if (DEBUG) std.debug.print("  [2] Trying relative to importing file...\n", .{});
        if (base_file) |base| {
            const base_dir = std.fs.path.dirname(base) orelse ".";
            if (try checkBoth(self.allocator, base_dir, resolved_import_path, &result)) {
                return result;
            }
        }

        // 3. KORU_PATH search paths
        if (DEBUG) std.debug.print("  [3] Trying KORU_PATH search paths...\n", .{});
        for (self.search_paths.items) |search_path| {
            if (try checkBoth(self.allocator, search_path, resolved_import_path, &result)) {
                return result;
            }
        }

        // 4. Standard library
        if (DEBUG) std.debug.print("  [4] Trying standard library...\n", .{});
        if (self.stdlib_path) |stdlib| {
            if (try checkBoth(self.allocator, stdlib, resolved_import_path, &result)) {
                return result;
            }
        }

        // Nothing found
        if (DEBUG) std.debug.print("\n✗✗✗ FATAL: Module not found: '{s}' ✗✗✗\n", .{import_path});
        return error.ModuleNotFound;
    }

    /// Resolve an import path to a full file path
    /// Returns owned memory that must be freed by the caller
    /// DEPRECATED: Use resolveBoth() for proper file+directory support
    pub fn resolve(
        self: *ModuleResolver,
        import_path: []const u8,
        base_file: ?[]const u8,
    ) ![]u8 {
        if (DEBUG) std.debug.print("\n═══ ModuleResolver.resolve() ═══\n", .{});
        if (DEBUG) std.debug.print("  Import path: '{s}'\n", .{import_path});
        if (base_file) |bf| {
            if (DEBUG) std.debug.print("  Base file: '{s}'\n", .{bf});
        } else {
            if (DEBUG) std.debug.print("  Base file: (none)\n", .{});
        }

        // Handle $alias path prefixes
        var resolved_import_path = import_path;
        var alias_resolved: ?[]u8 = null;
        defer if (alias_resolved) |p| self.allocator.free(p);

        if (import_path.len > 0 and import_path[0] == '$') {
            // Find the end of the alias (first '/' or end of string)
            const slash_pos = std.mem.indexOf(u8, import_path, "/");
            const alias_end = slash_pos orelse import_path.len;
            const alias = import_path[1..alias_end]; // Skip the '$'

            if (DEBUG) std.debug.print("  Resolving alias: ${s}\n", .{alias});

            // Look up alias in config.paths
            if (self.config.paths.get(alias)) |alias_path_raw| {
                // Interpolate {ENTRY} if present
                const alias_path = if (try self.interpolateEntry(alias_path_raw)) |interpolated|
                    interpolated
                else
                    alias_path_raw;
                defer if (alias_path.ptr != alias_path_raw.ptr) self.allocator.free(alias_path);

                if (DEBUG) std.debug.print("  ✓ Alias found: ${s} -> {s}\n", .{alias, alias_path});

                // Build the path to check (alias + remainder if any)
                const path_to_resolve = if (slash_pos) |pos| blk: {
                    const remainder = import_path[pos + 1..];
                    break :blk try std.fs.path.join(
                        self.allocator,
                        &[_][]const u8{ alias_path, remainder }
                    );
                } else blk: {
                    break :blk try self.allocator.dupe(u8, alias_path);
                };
                defer self.allocator.free(path_to_resolve);

                // Alias paths are RELATIVE TO PROJECT ROOT (where koru.json is)
                const absolute_path = if (std.fs.path.isAbsolute(path_to_resolve))
                    try self.allocator.dupe(u8, path_to_resolve)
                else
                    try std.fs.path.resolve(self.allocator, &[_][]const u8{ self.project_root, path_to_resolve });

                alias_resolved = absolute_path;
                resolved_import_path = alias_resolved.?;
                if (DEBUG) std.debug.print("  Resolved to (absolute): {s}\n", .{resolved_import_path});

                // CRITICAL: After alias resolution, try the path DIRECTLY!
                // Don't go through the normal search logic which would double-append to stdlib
                if (DEBUG) std.debug.print("  [ALIAS] Checking resolved alias path directly...\n", .{});

                // Check if it's a directory
                if (DEBUG) std.debug.print("    Checking directory: {s}\n", .{resolved_import_path});
                if (isDirectory(resolved_import_path)) {
                    const resolved = try std.fs.path.resolve(
                        self.allocator,
                        &[_][]const u8{resolved_import_path}
                    );
                    if (DEBUG) std.debug.print("    ✓ FOUND directory: {s}\n", .{resolved});
                    return resolved;
                } else {
                    if (DEBUG) std.debug.print("    ✗ Not a directory\n", .{});
                }

                // Check if it's a file (add .kz if needed)
                const needs_ext = !std.mem.endsWith(u8, resolved_import_path, ".kz");
                const path_with_ext = if (needs_ext)
                    try std.fmt.allocPrint(self.allocator, "{s}.kz", .{resolved_import_path})
                else
                    try self.allocator.dupe(u8, resolved_import_path);
                defer self.allocator.free(path_with_ext);

                if (DEBUG) std.debug.print("    Checking file: {s}\n", .{path_with_ext});
                if (std.fs.cwd().access(path_with_ext, .{})) |_| {
                    const resolved = try std.fs.path.resolve(
                        self.allocator,
                        &[_][]const u8{path_with_ext}
                    );
                    if (DEBUG) std.debug.print("    ✓ FOUND file: {s}\n", .{resolved});
                    return resolved;
                } else |err| {
                    if (DEBUG) std.debug.print("    ✗ Not found: {}\n", .{err});
                    // Alias resolved but file not found - this is a FATAL error!
                    if (DEBUG) std.debug.print("\n✗✗✗ FATAL: Alias ${s} resolved to '{s}' but file not found ✗✗✗\n", .{alias, path_with_ext});
                    return error.ModuleNotFound;
                }
            } else {
                // Alias not found in config
                if (DEBUG) std.debug.print("✗✗✗ FATAL: Unknown import alias: ${s}\n", .{alias});
                if (DEBUG) std.debug.print("Available aliases from koru.json:\n", .{});
                var iter = self.config.paths.iterator();
                while (iter.next()) |entry| {
                    if (DEBUG) std.debug.print("  ${s} -> {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                return error.UnknownImportAlias;
            }
        }

        // 1. If it's an absolute path, use it directly
        if (std.fs.path.isAbsolute(resolved_import_path)) {
            // Check if it's a directory first
            if (isDirectory(resolved_import_path)) {
                return try self.allocator.dupe(u8, resolved_import_path);
            }
            // Otherwise add .kz extension if needed
            const needs_ext = !std.mem.endsWith(u8, resolved_import_path, ".kz");
            if (needs_ext) {
                return try std.fmt.allocPrint(self.allocator, "{s}.kz", .{resolved_import_path});
            }
            return try self.allocator.dupe(u8, resolved_import_path);
        }
        
        // 2. Try relative to the importing file
        if (DEBUG) std.debug.print("  [2] Trying relative to importing file...\n", .{});
        if (base_file) |base| {
            const base_dir = std.fs.path.dirname(base) orelse ".";

            // Try as directory first
            const dir_candidate = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ base_dir, resolved_import_path }
            );
            defer self.allocator.free(dir_candidate);

            if (DEBUG) std.debug.print("    Checking directory: {s}\n", .{dir_candidate});
            if (isDirectory(dir_candidate)) {
                const resolved = try std.fs.path.resolve(
                    self.allocator,
                    &[_][]const u8{dir_candidate}
                );
                if (DEBUG) std.debug.print("    ✓ FOUND directory: {s}\n", .{resolved});
                return resolved;
            } else {
                if (DEBUG) std.debug.print("    ✗ Not a directory\n", .{});
            }

            // Try as file - add .kz extension only if not already present
            const needs_ext = !std.mem.endsWith(u8, resolved_import_path, ".kz");
            const path_with_ext = if (needs_ext)
                try std.fmt.allocPrint(self.allocator, "{s}.kz", .{resolved_import_path})
            else
                try self.allocator.dupe(u8, resolved_import_path);
            defer self.allocator.free(path_with_ext);

            const file_candidate = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ base_dir, path_with_ext }
            );
            defer self.allocator.free(file_candidate);

            if (DEBUG) std.debug.print("    Checking file: {s}\n", .{file_candidate});
            if (std.fs.cwd().access(file_candidate, .{})) |_| {
                const resolved = try std.fs.path.resolve(
                    self.allocator,
                    &[_][]const u8{file_candidate}
                );
                if (DEBUG) std.debug.print("    ✓ FOUND file: {s}\n", .{resolved});
                return resolved;
            } else |err| {
                if (DEBUG) std.debug.print("    ✗ Not found: {}\n", .{err});
            }
        } else {
            if (DEBUG) std.debug.print("    (skipped - no base file)\n", .{});
        }
        
        // 3. Try each search path from KORU_PATH
        if (DEBUG) std.debug.print("  [3] Trying KORU_PATH search paths ({} paths)...\n", .{self.search_paths.items.len});
        for (self.search_paths.items) |search_path| {
            if (DEBUG) std.debug.print("    Searching in: {s}\n", .{search_path});

            // Try directory
            const dir_candidate = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ search_path, resolved_import_path }
            );
            defer self.allocator.free(dir_candidate);

            if (DEBUG) std.debug.print("      Checking directory: {s}\n", .{dir_candidate});
            if (isDirectory(dir_candidate)) {
                const resolved = try std.fs.path.resolve(
                    self.allocator,
                    &[_][]const u8{dir_candidate}
                );
                if (DEBUG) std.debug.print("      ✓ FOUND directory: {s}\n", .{resolved});
                return resolved;
            } else {
                if (DEBUG) std.debug.print("      ✗ Not a directory\n", .{});
            }

            // Try file - add .kz extension only if not already present
            const needs_ext = !std.mem.endsWith(u8, resolved_import_path, ".kz");
            const path_with_ext = if (needs_ext)
                try std.fmt.allocPrint(self.allocator, "{s}.kz", .{resolved_import_path})
            else
                try self.allocator.dupe(u8, resolved_import_path);
            defer self.allocator.free(path_with_ext);

            const file_candidate = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ search_path, path_with_ext }
            );
            defer self.allocator.free(file_candidate);

            if (DEBUG) std.debug.print("      Checking file: {s}\n", .{file_candidate});
            if (std.fs.cwd().access(file_candidate, .{})) |_| {
                const resolved = try std.fs.path.resolve(
                    self.allocator,
                    &[_][]const u8{file_candidate}
                );
                if (DEBUG) std.debug.print("      ✓ FOUND file: {s}\n", .{resolved});
                return resolved;
            } else |err| {
                if (DEBUG) std.debug.print("      ✗ Not found: {}\n", .{err});
            }
        }

        // 4. Try the standard library
        if (DEBUG) std.debug.print("  [4] Trying standard library...\n", .{});
        if (self.stdlib_path) |stdlib| {
            if (DEBUG) std.debug.print("    Stdlib path: {s}\n", .{stdlib});

            // Try directory
            const dir_candidate = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ stdlib, resolved_import_path }
            );
            defer self.allocator.free(dir_candidate);

            if (DEBUG) std.debug.print("    Checking directory: {s}\n", .{dir_candidate});
            if (isDirectory(dir_candidate)) {
                const resolved = try std.fs.path.resolve(
                    self.allocator,
                    &[_][]const u8{dir_candidate}
                );
                if (DEBUG) std.debug.print("    ✓ FOUND directory: {s}\n", .{resolved});
                return resolved;
            } else {
                if (DEBUG) std.debug.print("    ✗ Not a directory\n", .{});
            }

            // Try file - add .kz extension only if not already present
            const needs_ext = !std.mem.endsWith(u8, resolved_import_path, ".kz");
            const path_with_ext = if (needs_ext)
                try std.fmt.allocPrint(self.allocator, "{s}.kz", .{resolved_import_path})
            else
                try self.allocator.dupe(u8, resolved_import_path);
            defer self.allocator.free(path_with_ext);

            const file_candidate = try std.fs.path.join(
                self.allocator,
                &[_][]const u8{ stdlib, path_with_ext }
            );
            defer self.allocator.free(file_candidate);

            if (DEBUG) std.debug.print("    Checking file: {s}\n", .{file_candidate});
            if (std.fs.cwd().access(file_candidate, .{})) |_| {
                const resolved = try std.fs.path.resolve(
                    self.allocator,
                    &[_][]const u8{file_candidate}
                );
                if (DEBUG) std.debug.print("    ✓ FOUND file: {s}\n", .{resolved});
                return resolved;
            } else |err| {
                if (DEBUG) std.debug.print("    ✗ Not found: {}\n", .{err});
            }
        } else {
            if (DEBUG) std.debug.print("    (no stdlib path configured)\n", .{});
        }

        // Module not found
        if (DEBUG) std.debug.print("\n✗✗✗ FATAL: Module not found: '{s}' ✗✗✗\n", .{import_path});
        if (DEBUG) std.debug.print("Tried:\n", .{});
        if (DEBUG) std.debug.print("  - Absolute path\n", .{});
        if (DEBUG) std.debug.print("  - Relative to base file\n", .{});
        if (DEBUG) std.debug.print("  - KORU_PATH ({} paths)\n", .{self.search_paths.items.len});
        if (self.stdlib_path) |stdlib| {
            if (DEBUG) std.debug.print("  - Standard library: {s}\n", .{stdlib});
        }
        return error.ModuleNotFound;
    }
    
    /// Check if a resolved path is a system/stdlib module
    pub fn isSystemModule(self: *ModuleResolver, canonical_path: []const u8) bool {
        // Check if the path is within the stdlib directory
        if (self.stdlib_path) |stdlib| {
            // Normalize both paths for comparison
            const normalized_stdlib = std.fs.path.resolve(
                self.allocator,
                &[_][]const u8{stdlib}
            ) catch return false;
            defer self.allocator.free(normalized_stdlib);
            
            return std.mem.startsWith(u8, canonical_path, normalized_stdlib);
        }
        
        // Fallback: check for koru_std in the path
        return std.mem.indexOf(u8, canonical_path, "koru_std") != null;
    }
};