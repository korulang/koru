//! Transitive import resolution and AST combination — shared by `koruc` CLI
//! (`glance`, full compile) and `koruc --ccp` frontend introspection.

const std = @import("std");
const log = @import("log");
const Parser = @import("parser").Parser;
const ast = @import("ast");
const errors = @import("errors");
const ModuleResolver = @import("module_resolver").ModuleResolver;
const module_resolver_mod = @import("module_resolver");
const file_types = @import("file_types");

const FileWriter = errors.FileSink;

pub fn printAstParseErrors(source_file: *const ast.Program, writer: anytype) !void {
    for (source_file.items) |*item| {
        if (item.* == .parse_error) {
            const pe = item.parse_error;
            try writer.print("error[{s}]: {s}\n", .{ @tagName(pe.error_code), pe.message });
            try writer.print("  --> {s}:{}:{}\n", .{ pe.location.file, pe.location.line, pe.location.column });
            if (pe.hint) |hint| {
                try writer.print("  hint: {s}\n", .{hint});
            }
            try writer.writeAll("\n");
        }
    }
}
const ImportedModule = struct {
    logical_name: []const u8, // Module name used in code (e.g., "io")
    canonical_path: []const u8, // Full resolved path to the module file/directory
    public_events: []ast.EventDecl, // Only public events for type checking
    source_file: ast.Program, // Full AST for the module
    is_directory: bool, // True if this is a directory import
    submodules: []ImportedModule, // Submodules (for directory imports)

    pub fn deinit(self: *ImportedModule, allocator: std.mem.Allocator) void {
        allocator.free(self.logical_name);
        allocator.free(self.canonical_path);
        // Recursively deinit submodules
        for (self.submodules) |*submod| {
            submod.deinit(allocator);
        }
        allocator.free(self.submodules);
        // NOTE: Don't deinit public_events items - they're shallow copies of events
        // that are in source_file.items. Deiniting them causes double-free.
        // Just free the array itself.
        allocator.free(self.public_events);
        // NOTE: Don't call source_file.deinit() because we transfer ownership
        // of items to the combined AST. The items array is set to &.{} after transfer,
        // and freeing that constant causes crashes.
        // NOTE: Also don't free main_module_name - it's allocated by the arena allocator
        // that will free everything when the arena is destroyed.
    }
};

/// Derives canonical module name from import path
/// - $alias/path imports: "alias.path" (preserve alias + path as dotted name)
/// - Regular path imports: Last component only (directory name as package)
///
/// Examples:
/// - "$std/io" → "std.io" (alias import: keep both parts)
/// - "lib/io" → "io" (directory import: last component only)
/// - "helper" → "helper" (single file)
fn deriveCanonicalName(allocator: std.mem.Allocator, import_path: []const u8) ![]const u8 {
    // Remove Koru extension if present
    const without_ext = if (file_types.koruExtensionOf(import_path)) |ext|
        import_path[0 .. import_path.len - ext.len]
    else
        import_path;

    // Replace / with . to create dotted name
    // "std/io" → "std.io"
    // "std/compiler" → "std.compiler"
    var result = try allocator.alloc(u8, without_ext.len);
    for (without_ext, 0..) |c, i| {
        result[i] = if (c == '/') '.' else c;
    }
    return result;
}

/// Probe each Koru extension on `stem` (an alias-prefixed module path stem
/// like "$std/io" or "$std/index"). Returns the first stem+extension that
/// resolves to an existing file through the resolver, or null. Caller owns
/// the returned path string.
fn probeImportExtensions(
    allocator: std.mem.Allocator,
    resolver: *ModuleResolver,
    stem: []const u8,
    base_file: []const u8,
) !?[]u8 {
    for (file_types.koru_extensions) |ext| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
        var maybe = resolver.resolveBoth(candidate, base_file) catch |err| {
            allocator.free(candidate);
            if (err == error.ModuleNotFound) continue;
            return err;
        };
        defer maybe.deinit(allocator);
        if (maybe.file_path != null) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

/// Queue parent imports for aliased paths.
/// For "$std/io/file" this queues "$std/io" as an additional import.
/// This enables parent module utilities to be available when importing submodules.
/// Only queues the parent if the parent file actually exists.
fn queueParentImports(
    allocator: std.mem.Allocator,
    work_queue: anytype,
    resolver: *ModuleResolver,
    import_decl: ast.ImportDecl,
    base_file: []const u8,
) !void {
    const import_path = import_decl.path;

    // If import_path starts with `./` or `/`, it's not an aliased import
    if (std.mem.startsWith(u8, import_path, "./") or std.mem.startsWith(u8, import_path, "/") or import_path.len == 0) return;

    // Find the alias and path parts
    const slash_pos = std.mem.indexOf(u8, import_path, "/") orelse return;
    const alias = import_path[0..slash_pos]; // e.g., "std"
    const subpath = import_path[slash_pos + 1 ..]; // e.g., "io/file"

    // If subpath is empty or has no further segments, nothing to queue
    if (subpath.len == 0) return;
    const last_slash = std.mem.lastIndexOf(u8, subpath, "/") orelse return;

    // Build parent stem and probe each Koru extension (e.g., std/io.kz,
    // std/io.kjs, ...). Append an extension so we only consider the FILE,
    // not the directory (which would include submodules). First hit wins.
    const parent_subpath = subpath[0..last_slash];
    const parent_stem = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ alias, parent_subpath });
    defer allocator.free(parent_stem);

    const parent_path = (try probeImportExtensions(allocator, resolver, parent_stem, base_file)) orelse {
        // No parent file exists for any Koru extension — fine, skip silently.
        return;
    };
    defer allocator.free(parent_path);

    // Build namespace for parent: alias.parent (e.g., "std.io")
    const alias_name = alias;
    var parent_namespace = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer parent_namespace.deinit(allocator);
    try parent_namespace.appendSlice(allocator, alias_name);

    var parts = std.mem.splitScalar(u8, parent_subpath, '/');
    while (parts.next()) |part| {
        try parent_namespace.append(allocator, '.');
        try parent_namespace.appendSlice(allocator, part);
    }

    // Copy the path - we already deferred freeing the original
    const parent_path_owned = try allocator.dupe(u8, parent_path);
    const parent_local_name = try allocator.dupe(u8, parent_namespace.items);

    log.debug("AUTO-IMPORT: Queueing parent '{s}' (namespace: {s})\n", .{ parent_path_owned, parent_local_name });

    // Create synthetic ImportDecl for the parent
    const synthetic_import = ast.ImportDecl{
        .path = parent_path_owned,
        .local_name = parent_local_name,
        .location = import_decl.location,
        .module = import_decl.module,
    };

    try work_queue.append(allocator, .{
        .import_decl = synthetic_import,
        .base_file = base_file,
        .is_synthetic = true,
    });
}

/// Queue index.kz import for aliased paths.
/// For ANY "$alias/*" import, this queues "$alias/index.kz" as an additional import.
/// This enables root-level utilities (like keywords) to be available when importing any submodule.
/// Only queues the index if index.kz actually exists AND is not the entry file itself.
fn queueIndexImport(
    allocator: std.mem.Allocator,
    work_queue: anytype,
    resolver: *ModuleResolver,
    import_decl: ast.ImportDecl,
    base_file: []const u8,
    entry_file: []const u8,
) !void {
    const import_path = import_decl.path;

    // If import_path starts with `./` or `/`, it's not an aliased import
    if (std.mem.startsWith(u8, import_path, "./") or std.mem.startsWith(u8, import_path, "/") or import_path.len == 0) return;

    // Find the alias part
    const slash_pos = std.mem.indexOf(u8, import_path, "/") orelse return;
    const alias = import_path[0..slash_pos]; // e.g., "std"

    // Build index stem and probe each Koru extension (alias/index.kz,
    // alias/index.kjs, ...). First hit wins.
    const index_stem = try std.fmt.allocPrint(allocator, "{s}/index", .{alias});
    defer allocator.free(index_stem);

    const index_path = (try probeImportExtensions(allocator, resolver, index_stem, base_file)) orelse {
        // No index file exists for any Koru extension — fine, skip silently.
        return;
    };
    defer allocator.free(index_path);

    // Re-resolve to get the canonical file path for the entry-file dedup check.
    var resolved = try resolver.resolveBoth(index_path, base_file);
    defer resolved.deinit(allocator);

    // CRITICAL: Don't queue if the resolved file is the entry file itself!
    // This prevents the main file from being imported as a module when it
    // imports something from its own namespace (e.g., $orisha/router from src/index.kz)
    if (resolved.file_path) |fp| {
        if (std.mem.eql(u8, fp, entry_file)) {
            log.debug("AUTO-IMPORT: Skipping index '{s}' (same as entry file)\n", .{fp});
            return;
        }
    }

    // Namespace is just the alias name (e.g., "std")
    const alias_name = alias;
    const index_path_owned = try allocator.dupe(u8, index_path);
    const index_local_name = try allocator.dupe(u8, alias_name);

    log.debug("AUTO-IMPORT: Queueing index '{s}' (namespace: {s})\n", .{ index_path_owned, index_local_name });

    // Create synthetic ImportDecl for index.kz
    const synthetic_import = ast.ImportDecl{
        .path = index_path_owned,
        .local_name = index_local_name,
        .location = import_decl.location,
        .module = import_decl.module,
    };

    try work_queue.append(allocator, .{
        .import_decl = synthetic_import,
        .base_file = base_file,
        .is_synthetic = true,
    });
}

/// Dedup identity for an imported module.
///
/// A directory import (`~import mylib`) and a file import of that directory's
/// `index.<ext>` (`~import mylib/index`, which `queueIndexImport` synthesizes
/// for every `~import mylib/<submodule>`) ARE THE SAME MODULE reached two ways
/// — the directory load parses that exact file as its own `source_file`. Their
/// `canonical_path`s differ though: one is `<dir>`, the other `<dir>/index.kz`.
///
/// Keying dedup on the raw path let both through, and since they also share a
/// `logical_name`, `emitModuleNode` concatenated them into ONE Zig struct: every
/// declaration in the index file emitted twice. It surfaced as `duplicate struct
/// member name 'std'` — reading like a submodule's `const std` colliding with
/// its parent's — and as duplicate top-level transform wrappers. Normalizing a
/// directory to its index file makes the two spellings one key.
fn moduleIdentity(allocator: std.mem.Allocator, module: *const ImportedModule) ![]u8 {
    if (module.is_directory) {
        if (try module_resolver_mod.resolveKoruFileIn(allocator, module.canonical_path, "index")) |index_path| {
            return index_path;
        }
    }
    return allocator.dupe(u8, module.canonical_path);
}

fn processImport(allocator: std.mem.Allocator, parse_allocator: std.mem.Allocator, resolver: *ModuleResolver, import_decl: ast.ImportDecl, base_file: []const u8, entry_file: []const u8) !ImportedModule {
    // Use ModuleResolver to find BOTH file and directory (if they exist)
    var resolved = try resolver.resolveBoth(import_decl.path, base_file);
    defer resolved.deinit(allocator);

    // Determine import mode based on what was found
    const has_file = resolved.file_path != null;
    const has_dir = resolved.dir_path != null;

    log.debug("processImport: has_file={}, has_dir={}\n", .{ has_file, has_dir });

    // Helper to load submodules from directory
    const loadSubmodules = struct {
        fn load(alloc: std.mem.Allocator, parse_alloc: std.mem.Allocator, res: *ModuleResolver, dir_path: []const u8, entry_file_to_exclude: []const u8) ![]ImportedModule {
            const files = try res.enumerateDirectory(dir_path);
            defer {
                for (files) |file| alloc.free(file);
                alloc.free(files);
            }

            var submodules = std.ArrayList(ImportedModule){ .items = &.{}, .capacity = 0 };
            errdefer {
                for (submodules.items) |*submod| submod.deinit(alloc);
                submodules.deinit(alloc);
            }

            // ONE submodule per STEM, not per file. `user.kz` and `user.kjs` are
            // two FACETS of one module, and enumerating dirents made them two
            // ImportedModules both called `user`: the event decls landed in one,
            // the `|js` proc bodies that implement them in the other. The JS
            // emitter looks for a proc among the event's OWN module items, found
            // none, and emitted a throwing stub — `has no JavaScript
            // implementation` for a module whose implementation was sitting one
            // dirent away. The FILE-import path has merged facets since Phase 2.1
            // (`loadFileWithCompanions`); only the directory path did not, and
            // 140_003 missed it by giving its two files different stems.
            var seen_stems = std.StringHashMap(void).init(alloc);
            defer {
                var stem_it = seen_stems.keyIterator();
                while (stem_it.next()) |k| alloc.free(k.*);
                seen_stems.deinit();
            }

            const stemOf = struct {
                fn f(path: []const u8) []const u8 {
                    const base = std.fs.path.basename(path);
                    const ext = file_types.koruExtensionOf(base) orelse return base;
                    return base[0 .. base.len - ext.len];
                }
            }.f;

            // The entry file is already the main module and `mergeEntryCompanions`
            // folded its own facets in there, so claim its whole stem rather than
            // just its path — otherwise a directory that contains the entry gets
            // the entry's `.kjs` sibling back as a submodule. Claimed only when
            // the entry is genuinely one of THESE dirents, so an unrelated
            // `test_lib/input.kz` under an entry also named `input.kz` still loads.
            for (files) |file_path| {
                if (!std.mem.eql(u8, file_path, entry_file_to_exclude)) continue;
                log.debug("SUBMODULE: Skipping entry file '{s}' (already main_module)\n", .{file_path});
                try seen_stems.put(try alloc.dupe(u8, stemOf(file_path)), {});
                break;
            }

            for (files) |file_path| {
                const submod_name = stemOf(file_path);

                // Skip index.<ext> - it represents the directory itself, not a submodule.
                // The directory's source_file is populated from the index file separately.
                if (std.mem.eql(u8, submod_name, "index")) {
                    log.debug("SUBMODULE: Skipping index file '{s}' (loaded as directory source)\n", .{file_path});
                    continue;
                }

                if (seen_stems.contains(submod_name)) continue;
                try seen_stems.put(try alloc.dupe(u8, submod_name), {});

                // Loads this dirent AND its facet siblings, merging their items,
                // module annotations and public events into one program — the same
                // call the file-import path makes. It also owns the arena dupe of
                // the path the parser hangs every SourceLocation.file off, which
                // matters because the `files` slice is freed when this returns.
                const loaded = try loadFileWithCompanions(alloc, parse_alloc, file_path);

                try submodules.append(alloc, ImportedModule{
                    .logical_name = try alloc.dupe(u8, submod_name),
                    .canonical_path = try alloc.dupe(u8, file_path),
                    .public_events = loaded.public_events,
                    .source_file = loaded.source_file,
                    .is_directory = false,
                    .submodules = &.{},
                });
            }

            return try submodules.toOwnedSlice(alloc);
        }
    }.load;

    // Use local_name if provided (for synthetic imports like auto-parent and auto-index),
    // otherwise derive from path
    const module_name = if (import_decl.local_name) |ln|
        try allocator.dupe(u8, ln)
    else
        try deriveCanonicalName(allocator, import_decl.path);
    errdefer allocator.free(module_name); // Clean up if we error before consuming module_name

    if (has_file and has_dir) {
        // ERROR: Both foo.kz and foo/ exist - this is ambiguous
        // Modules must be self-contained: use EITHER foo.kz OR foo/index.kz
        log.err("\n", .{});
        log.err("error[KORU200]: Ambiguous module structure\n", .{});
        log.err("  --> {s}\n", .{import_decl.path});
        log.err("  |\n", .{});
        log.err("  | Found both '{s}.kz' and '{s}/' directory\n", .{ module_name, module_name });
        log.err("  | \n", .{});
        log.err("  | Modules must be self-contained. Choose one:\n", .{});
        log.err("  |   - Single file: {s}.kz\n", .{module_name});
        log.err("  |   - Directory:   {s}/index.kz (with submodules)\n", .{module_name});
        log.err("  |\n", .{});
        log.err("  = help: Delete or rename one of them\n\n", .{});
        return error.ModuleNotFound; // TODO: route KORU200 through ErrorReporter (code now declared in errors.zig)
    } else if (has_dir) {
        // ONLY directory
        log.debug("  Importing directory only: {s}\n", .{import_decl.path});

        const submodules = try loadSubmodules(allocator, parse_allocator, resolver, resolved.dir_path.?, entry_file);

        // FIX: Load index.<ext> content for the directory's source_file.
        // Previously this was empty, causing flow arguments (like Source blocks) to be lost.
        // Phase 2: probe all Koru extensions so .kjs/.k/etc. projects can have
        // their own index.<ext> file.
        const maybe_index_path = try module_resolver_mod.resolveKoruFileIn(allocator, resolved.dir_path.?, "index");
        if (maybe_index_path == null) {
            // No index file - use empty source_file (original behavior)
            log.debug("  No index.<ext> file found in directory\n", .{});
            return ImportedModule{
                .logical_name = module_name,
                .canonical_path = try allocator.dupe(u8, resolved.dir_path.?),
                .public_events = &.{},
                .source_file = .{ .items = &.{}, .module_annotations = &.{}, .main_module_name = try parse_allocator.dupe(u8, module_name), .allocator = parse_allocator },
                .is_directory = true,
                .submodules = submodules,
            };
        }
        const index_path = maybe_index_path.?;
        defer allocator.free(index_path);

        // index file exists - parse it and use its content
        log.debug("  Loading index file from directory: {s}\n", .{index_path});
        const index_data = try loadFileWithCompanions(allocator, parse_allocator, index_path);

        return ImportedModule{
            .logical_name = module_name,
            .canonical_path = try allocator.dupe(u8, resolved.dir_path.?),
            .public_events = index_data.public_events,
            .source_file = index_data.source_file,
            .is_directory = true,
            .submodules = submodules,
        };
    } else {
        // ONLY file
        log.debug("  Importing file only: {s}\n", .{import_decl.path});

        const merged = try loadFileWithCompanions(allocator, parse_allocator, resolved.file_path.?);

        return ImportedModule{
            .logical_name = module_name,
            .canonical_path = try allocator.dupe(u8, resolved.file_path.?),
            .public_events = merged.public_events,
            .source_file = merged.source_file,
            .is_directory = false,
            .submodules = &.{},
        };
    }
}

/// Load a Koru file plus any companion files (same directory, same stem,
/// different Koru extension) and merge their items into a single
/// `ast.Program`. Phase 2.1: the `.k` (contract) + `.kz` (implementation)
/// sibling layout was promised by Phase 2 but the resolver returns only
/// one path. Companion sweep happens here, at the layer that turns a
/// resolved path into a parsed module.
///
/// The primary file's `main_module_name` is preserved; companions
/// contribute their `items` and `module_annotations` only. Allocations on
/// `parse_alloc` (the arena) survive for the rest of compilation; orphan
/// per-file arrays from the individual `loadFile` calls are not freed
/// because the arena owns them.
const LoadedFile = struct {
    public_events: []ast.EventDecl,
    source_file: ast.Program,
};

fn loadFileWithCompanions(
    allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    primary_path: []const u8,
) !LoadedFile {
    const loadFile = struct {
        fn load(alloc: std.mem.Allocator, parse_alloc: std.mem.Allocator, file_path: []const u8) !LoadedFile {
            const file = try std.fs.cwd().openFile(file_path, .{});
            defer file.close();

            // Dupe the path into the arena: the parser stores it on reporter.file_name
            // (and thus on every EventDecl/SourceLocation it produces), so it must
            // survive for the lifetime of the AST — caller may free the original
            // immediately after loadFile returns.
            const file_path_owned = try parse_alloc.dupe(u8, file_path);

            const source = try file.readToEndAlloc(parse_alloc, 1024 * 1024);
            var parser = try Parser.init(parse_alloc, source, file_path_owned, &[_][]const u8{}, null);
            parser.fail_fast = false;
            defer parser.deinit();

            const parse_result = try parser.parse();

            if (parser.reporter.hasErrors() or parse_result.source_file.hasParseErrors()) {
                const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
                try parser.reporter.printErrors(stderr_writer);
                if (!parser.reporter.hasErrors()) {
                    try printAstParseErrors(&parse_result.source_file, stderr_writer);
                }
                std.process.exit(1);
            }

            var public_events = std.ArrayListAligned(ast.EventDecl, null){ .items = &.{}, .capacity = 0 };
            for (parse_result.source_file.items) |item| {
                if (item == .event_decl and item.event_decl.is_public) {
                    try public_events.append(alloc, item.event_decl);
                }
            }

            return .{
                .public_events = try public_events.toOwnedSlice(alloc),
                .source_file = parse_result.source_file,
            };
        }
    }.load;

    const companions = try module_resolver_mod.findCompanionFiles(allocator, primary_path);
    defer {
        for (companions) |c| allocator.free(c);
        allocator.free(companions);
    }

    const primary = try loadFile(allocator, parse_allocator, primary_path);

    if (companions.len == 0) {
        return primary;
    }

    log.debug("  Phase 2.1: merging {} companion file(s) for {s}\n", .{ companions.len, primary_path });

    var merged_items = std.ArrayList(ast.Item){ .items = &.{}, .capacity = 0 };
    try merged_items.appendSlice(parse_allocator, primary.source_file.items);

    var merged_annotations = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    try merged_annotations.appendSlice(parse_allocator, primary.source_file.module_annotations);

    var merged_events = std.ArrayList(ast.EventDecl){ .items = &.{}, .capacity = 0 };
    try merged_events.appendSlice(allocator, primary.public_events);
    allocator.free(primary.public_events);

    for (companions) |companion_path| {
        log.debug("    Companion: {s}\n", .{companion_path});
        const companion = try loadFile(allocator, parse_allocator, companion_path);
        try merged_items.appendSlice(parse_allocator, companion.source_file.items);
        try merged_annotations.appendSlice(parse_allocator, companion.source_file.module_annotations);
        try merged_events.appendSlice(allocator, companion.public_events);
        allocator.free(companion.public_events);
    }

    return .{
        .public_events = try merged_events.toOwnedSlice(allocator),
        .source_file = ast.Program{
            .items = try merged_items.toOwnedSlice(parse_allocator),
            .module_annotations = try merged_annotations.toOwnedSlice(parse_allocator),
            .main_module_name = primary.source_file.main_module_name,
            .allocator = parse_allocator,
            .type_registry = primary.source_file.type_registry,
        },
    };
}

/// Parse the entry's Koru companion facets (siblings sharing the stem, with a
/// different Koru extension) and fold their items + module annotations into the
/// already-parsed `primary` program. Returns the union; `primary`'s registry,
/// `main_module_name`, and allocator are preserved.
///
/// This is the entry-side mirror of `loadFileWithCompanions` (which serves
/// imports). The difference: the entry's `primary` was already parsed with
/// compiler-import injection and the import resolver wired in; the impl facets
/// only contribute procs + host lines, which are opaque to import resolution,
/// so they're parsed plainly (empty flags, null resolver). An empty companion
/// set returns `primary` untouched, so single-file programs pay nothing.
pub fn mergeEntryCompanions(
    allocator: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    primary_path: []const u8,
    primary: ast.Program,
) !ast.Program {
    const companions = try module_resolver_mod.findCompanionFiles(allocator, primary_path);
    defer {
        for (companions) |c| allocator.free(c);
        allocator.free(companions);
    }
    if (companions.len == 0) return primary;

    log.debug("  Entry companion merge: {} sibling(s) for {s}\n", .{ companions.len, primary_path });

    var merged_items = std.ArrayList(ast.Item){ .items = &.{}, .capacity = 0 };
    try merged_items.appendSlice(parse_allocator, primary.items);
    var merged_annotations = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
    try merged_annotations.appendSlice(parse_allocator, primary.module_annotations);

    for (companions) |companion_path| {
        log.debug("    Companion: {s}\n", .{companion_path});
        const file = try std.fs.cwd().openFile(companion_path, .{});
        defer file.close();
        const path_owned = try parse_allocator.dupe(u8, companion_path);
        const source = try file.readToEndAlloc(parse_allocator, 1024 * 1024);
        var parser = try Parser.init(parse_allocator, source, path_owned, &[_][]const u8{}, null);
        parser.fail_fast = false;
        defer parser.deinit();
        const parsed = try parser.parse();
        if (parser.reporter.hasErrors() or parsed.source_file.hasParseErrors()) {
            const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
            try parser.reporter.printErrors(stderr_writer);
            if (!parser.reporter.hasErrors()) try printAstParseErrors(&parsed.source_file, stderr_writer);
            std.process.exit(1);
        }
        try merged_items.appendSlice(parse_allocator, parsed.source_file.items);
        try merged_annotations.appendSlice(parse_allocator, parsed.source_file.module_annotations);
    }

    return ast.Program{
        .items = try merged_items.toOwnedSlice(parse_allocator),
        .module_annotations = try merged_annotations.toOwnedSlice(parse_allocator),
        .main_module_name = primary.main_module_name,
        .allocator = parse_allocator,
        .type_registry = primary.type_registry,
    };
}
fn rewriteDefaultEventCalls(allocator: std.mem.Allocator, items: []const ast.Item) void {
    for (items) |*item_const| {
        if (item_const.* != .flow) continue;
        const item = @constCast(item_const);
        const node_ptr = if (item.flow.body.node) |*n| n else continue;
        if (node_ptr.* != .invocation) continue;
        const path = &node_ptr.invocation.path;
        if (path.module_qualifier != null or path.segments.len != 1) continue;
        const seg = path.segments[0];
        if (std.mem.indexOfScalar(u8, seg, '/') == null) continue;
        var local_name: ?[]const u8 = null;
        for (items) |*it2| {
            if (it2.* == .import_decl and std.mem.eql(u8, it2.import_decl.path, seg)) {
                local_name = it2.import_decl.local_name;
                break;
            }
        }
        const lname = local_name orelse continue;
        path.module_qualifier = lname;
        const new_segs = allocator.alloc([]const u8, 1) catch continue;
        new_segs[0] = "default";
        path.segments = new_segs;
    }
}

pub const CombineResult = struct {
    imported_module_count: usize,
    /// Canonical paths of resolved imports (gpa-owned strings).
    imported_paths: []const []const u8,
};

/// Resolve transitive imports and merge imported `module_decl` items into
/// `source_file`. Replaces `source_file.items` with the combined program
/// (same shape as post-import `koruc` CLI AST before backend passes).
pub fn combineImports(
    gpa: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    resolver: *ModuleResolver,
    source_file: *ast.Program,
    input: []const u8,
    entry_file_absolute: []const u8,
) !CombineResult {
    var imported_modules = std.ArrayListAligned(ImportedModule, null){
        .items = &.{},
        .capacity = 0,
    };
    defer {
        for (imported_modules.items) |*module| {
            module.deinit(gpa);
        }
        imported_modules.deinit(gpa);
    }

    // Key is the module IDENTITY (see moduleIdentity), not the raw canonical
    // path; the value is the index into `imported_modules` so a directory load
    // can supersede a bare index-file load of the same module.
    var imported_paths_map = std.StringHashMap(usize).init(gpa);
    defer {
        var it = imported_paths_map.keyIterator();
        while (it.next()) |key| {
            gpa.free(key.*);
        }
        imported_paths_map.deinit();
    }

    const WorkItem = struct {
        import_decl: ast.ImportDecl,
        base_file: []const u8,
        is_synthetic: bool = false,
    };
    var work_queue = std.ArrayListAligned(WorkItem, null){
        .items = &.{},
        .capacity = 0,
    };
    defer work_queue.deinit(gpa);

    for (source_file.items) |item| {
        if (item == .import_decl) {
            try work_queue.append(gpa, .{
                .import_decl = item.import_decl,
                .base_file = input,
                .is_synthetic = false,
            });
        }
    }

    while (work_queue.items.len > 0) {
        const work_item = work_queue.orderedRemove(0);
        defer {
            if (work_item.is_synthetic) {
                gpa.free(work_item.import_decl.path);
                if (work_item.import_decl.local_name) |name| {
                    gpa.free(name);
                }
            }
        }

        const module = try processImport(gpa, parse_allocator, resolver, work_item.import_decl, work_item.base_file, entry_file_absolute);

        const identity = try moduleIdentity(gpa, &module);
        var identity_owned = true;
        defer if (identity_owned) gpa.free(identity);

        // Slot this module occupies in `imported_modules`, or null if it was a
        // duplicate that lost. A directory load carries the index file's
        // content PLUS the sibling submodules, so it is a strict superset of a
        // bare index-file load and supersedes one already in the list.
        var slot: ?usize = null;
        if (imported_paths_map.get(identity)) |existing_idx| {
            const existing = &imported_modules.items[existing_idx];
            if (module.is_directory and !existing.is_directory) {
                log.debug("DEDUPLICATION: Directory import of '{s}' supersedes its index file (identity: {s})\n", .{ module.logical_name, identity });
                existing.deinit(gpa);
                imported_modules.items[existing_idx] = module;
                slot = existing_idx;
            } else {
                log.debug("DEDUPLICATION: Skipping duplicate import of '{s}' (identity: {s})\n", .{ module.logical_name, identity });
                var mut_module = module;
                mut_module.deinit(gpa);
                continue;
            }
        } else {
            try imported_paths_map.put(identity, imported_modules.items.len);
            identity_owned = false; // the map owns it now
            log.debug("IMPORT: Added '{s}' (canonical: {s})\n", .{ module.logical_name, module.canonical_path });
        }

        try queueParentImports(gpa, &work_queue, resolver, work_item.import_decl, work_item.base_file);
        try queueIndexImport(gpa, &work_queue, resolver, work_item.import_decl, work_item.base_file, entry_file_absolute);

        for (module.source_file.items) |item| {
            if (item == .import_decl) {
                try work_queue.append(gpa, .{
                    .import_decl = item.import_decl,
                    .base_file = module.canonical_path,
                    .is_synthetic = false,
                });
            }
        }

        for (module.submodules) |*submod| {
            for (submod.source_file.items) |item| {
                if (item == .import_decl) {
                    try work_queue.append(gpa, .{
                        .import_decl = item.import_decl,
                        .base_file = submod.canonical_path,
                        .is_synthetic = false,
                    });
                }
            }
        }

        // Already written into its slot when a directory superseded an index
        // file; only a genuinely new module extends the list.
        if (slot == null) {
            try imported_modules.append(gpa, module);
        }
    }

    var combined_items = try std.ArrayList(ast.Item).initCapacity(parse_allocator, source_file.items.len);
    defer combined_items.deinit(parse_allocator);

    const addModuleToAST = struct {
        fn add(
            alloc: std.mem.Allocator,
            set_alloc: std.mem.Allocator,
            seen: *std.StringHashMap(void),
            items: *std.ArrayList(ast.Item),
            module: *ImportedModule,
            res: *ModuleResolver,
        ) !void {
            // ONE ModuleDecl PER SOURCE FILE — the invariant the emitter needs.
            // `emitModuleNode` groups ModuleDecls by logical_name and emits every
            // one of them into a single Zig struct, so a file reached twice puts
            // its whole declaration surface in twice. The queue-level dedup above
            // catches a module imported twice by name, but a file can ALSO arrive
            // as a directory's submodule and again as an explicit
            // `~import <pkg>/<file>` — two different ImportedModules, one file.
            const claim = struct {
                fn f(sa: std.mem.Allocator, s: *std.StringHashMap(void), path: []const u8) !bool {
                    if (s.contains(path)) return false;
                    try s.put(try sa.dupe(u8, path), {});
                    return true;
                }
            }.f;

            const has_source = (module.source_file.items.len > 0 or module.source_file.module_annotations.len > 0) and
                try claim(set_alloc, seen, module.canonical_path);
            if (has_source) {
                const is_system = res.isSystemModule(module.canonical_path);
                const annotations = try alloc.alloc([]const u8, module.source_file.module_annotations.len);
                for (module.source_file.module_annotations, 0..) |ann, ann_idx| {
                    annotations[ann_idx] = try alloc.dupe(u8, ann);
                }

                const canon_owned = try alloc.dupe(u8, module.canonical_path);
                const module_decl = ast.ModuleDecl{
                    .logical_name = try alloc.dupe(u8, module.logical_name),
                    .canonical_path = canon_owned,
                    .items = module.source_file.items,
                    .is_system = is_system,
                    .annotations = annotations,
                    .location = .{ .file = canon_owned, .line = 1, .column = 0 },
                };
                module.source_file.items = &.{};
                try items.append(alloc, .{ .module_decl = module_decl });
            }

            if (module.is_directory and module.submodules.len > 0) {
                for (module.submodules) |*submod| {
                    if (!try claim(set_alloc, seen, submod.canonical_path)) continue;
                    const is_system = res.isSystemModule(submod.canonical_path);

                    const dotted_name = if (std.mem.eql(u8, submod.logical_name, "index"))
                        try alloc.dupe(u8, module.logical_name)
                    else
                        try std.fmt.allocPrint(alloc, "{s}.{s}", .{ module.logical_name, submod.logical_name });

                    const annotations = try alloc.alloc([]const u8, submod.source_file.module_annotations.len);
                    for (submod.source_file.module_annotations, 0..) |ann, ann_idx| {
                        annotations[ann_idx] = try alloc.dupe(u8, ann);
                    }

                    const submod_canon_owned = try alloc.dupe(u8, submod.canonical_path);
                    const module_decl = ast.ModuleDecl{
                        .logical_name = dotted_name,
                        .canonical_path = submod_canon_owned,
                        .items = submod.source_file.items,
                        .is_system = is_system,
                        .annotations = annotations,
                        .location = .{ .file = submod_canon_owned, .line = 1, .column = 0 },
                    };
                    submod.source_file.items = &.{};
                    try items.append(alloc, .{ .module_decl = module_decl });
                }
            }
        }
    }.add;

    rewriteDefaultEventCalls(parse_allocator, source_file.items);

    var emitted_files = std.StringHashMap(void).init(gpa);
    defer {
        var seen_it = emitted_files.keyIterator();
        while (seen_it.next()) |k| gpa.free(k.*);
        emitted_files.deinit();
    }

    for (imported_modules.items) |*module| {
        try addModuleToAST(parse_allocator, gpa, &emitted_files, &combined_items, module, resolver);
    }

    for (source_file.items) |item| {
        switch (item) {
            .import_decl => continue,
            else => try combined_items.append(parse_allocator, item),
        }
    }

    source_file.items = try combined_items.toOwnedSlice(parse_allocator);

    var path_list = try std.ArrayList([]const u8).initCapacity(gpa, imported_paths_map.count());
    var path_iter = imported_paths_map.keyIterator();
    while (path_iter.next()) |path_ptr| {
        try path_list.append(gpa, try gpa.dupe(u8, path_ptr.*));
    }

    log.debug("AST combined with {} imported modules\n", .{imported_modules.items.len});

    return .{
        .imported_module_count = imported_modules.items.len,
        .imported_paths = try path_list.toOwnedSlice(gpa),
    };
}
