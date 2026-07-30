//! Frontend AST introspection — parse + import resolution without backend codegen.
//! Powers `glance`, CCP `ast_json`, and future hover/definition commands.

const std = @import("std");
const Parser = @import("parser").Parser;
const ast = @import("ast");
const TypeRegistry = @import("type_registry").TypeRegistry;
const ModuleResolver = @import("module_resolver").ModuleResolver;
const Config = @import("config").Config;
const file_types = @import("file_types");
const import_pipeline = @import("import_pipeline.zig");
const frontend_diagnostics = @import("frontend_diagnostics.zig");

pub const Options = struct {
    merge_companions: bool = true,
    inject_compiler: bool = true,
    fail_fast: bool = false,
    compiler_flags: []const []const u8 = &.{},
};

pub const Result = struct {
    program: ast.Program,
    registry: TypeRegistry,
    imported_paths: []const []const u8,
    /// True when the parser reporter recorded errors (program may still carry parse_error nodes).
    had_reporter_errors: bool,
    diagnostics: []frontend_diagnostics.Diagnostic,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    project_root: []const u8,
    entry_dir_absolute: []const u8,
    resolver: ModuleResolver,
    project_config: Config,

    pub fn deinit(self: *Context) void {
        self.resolver.deinit();
        self.project_config.deinit();
        self.gpa.free(self.project_root);
        self.gpa.free(self.entry_dir_absolute);
    }
};

/// Discover `koru.json` project root from a file path's directory.
pub fn findProjectRoot(gpa: std.mem.Allocator, input_dir_absolute: []const u8) ![]const u8 {
    var search_dir: []const u8 = input_dir_absolute;
    while (true) {
        const json_path = try std.fs.path.join(gpa, &[_][]const u8{ search_dir, "koru.json" });
        defer gpa.free(json_path);

        if (std.fs.cwd().access(json_path, .{})) |_| {
            return try gpa.dupe(u8, search_dir);
        } else |_| {}

        const parent = std.fs.path.dirname(search_dir);
        if (parent == null or std.mem.eql(u8, parent.?, search_dir)) {
            return try gpa.dupe(u8, input_dir_absolute);
        }
        search_dir = parent.?;
    }
}

pub fn initContext(gpa: std.mem.Allocator, file_path: []const u8, out: *Context) !void {
    const input_dir = std.fs.path.dirname(file_path) orelse ".";
    out.entry_dir_absolute = try std.fs.cwd().realpathAlloc(gpa, input_dir);
    errdefer gpa.free(out.entry_dir_absolute);

    out.project_root = try findProjectRoot(gpa, out.entry_dir_absolute);
    errdefer gpa.free(out.project_root);

    out.gpa = gpa;
    out.project_config = try Config.load(gpa, out.project_root) orelse try Config.default(gpa);
    errdefer out.project_config.deinit();

    out.resolver = try ModuleResolver.init(gpa, &out.project_config, out.project_root, out.entry_dir_absolute);
}

fn prepareSourceWithCompilerInject(
    parse_allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    inject_compiler: bool,
) !struct { final_source: []const u8, user_source: []const u8, bootstrap_line_offset: usize } {
    const user_already_imported_compiler =
        std.mem.indexOf(u8, source, "~import std/compiler") != null or
        std.mem.indexOf(u8, source, "import std/compiler") != null;

    if (inject_compiler and !user_already_imported_compiler) {
        const input_basename = std.fs.path.basename(file_path);
        const is_pure_k = if (file_types.koruExtensionOf(input_basename)) |ext|
            std.mem.eql(u8, ext, ".k")
        else
            false;
        const import_line = if (is_pure_k) "import std/compiler\n" else "~import std/compiler\n";
        const injected = try parse_allocator.alloc(u8, import_line.len + source.len);
        @memcpy(injected[0..import_line.len], import_line);
        @memcpy(injected[import_line.len..], source);
        return .{ .final_source = injected, .user_source = source, .bootstrap_line_offset = 1 };
    }

    return .{ .final_source = source, .user_source = source, .bootstrap_line_offset = 0 };
}

/// Parse `file_path` from disk, resolve imports, return the combined frontend AST.
pub fn introspectFile(
    gpa: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    file_path: []const u8,
    opts: Options,
) !Result {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    const source = try parse_allocator.alloc(u8, file_size);
    const n = try file.read(source);
    if (n != file_size) return error.ShortRead;
    return introspectSource(gpa, parse_allocator, source, file_path, opts);
}

/// Parse in-memory `source` as `file_path`, resolve imports, return combined AST.
pub fn introspectSource(
    gpa: std.mem.Allocator,
    parse_allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    opts: Options,
) !Result {
    var ctx: Context = undefined;
    try initContext(gpa, file_path, &ctx);
    defer ctx.deinit();

    const entry_basename = std.fs.path.basename(file_path);
    const entry_file_absolute = try std.fs.path.join(gpa, &[_][]const u8{
        ctx.entry_dir_absolute,
        entry_basename,
    });
    defer gpa.free(entry_file_absolute);

    const prepared = try prepareSourceWithCompilerInject(parse_allocator, source, file_path, opts.inject_compiler);

    var parser = try Parser.init(parse_allocator, prepared.final_source, file_path, opts.compiler_flags, &ctx.resolver);
    parser.fail_fast = opts.fail_fast;
    defer parser.deinit();

    if (prepared.bootstrap_line_offset > 0) {
        try parser.reporter.setUserSource(prepared.user_source, prepared.bootstrap_line_offset);
    }

    const parse_result = parser.parse() catch |err| {
        if (parser.reporter.hasErrors()) return err;
        return err;
    };

    const diagnostics = try frontend_diagnostics.collectReporter(gpa, &parser.reporter, file_path);
    errdefer frontend_diagnostics.freeSlice(gpa, diagnostics);

    var source_file = parse_result.source_file;
    const user_registry = parse_result.registry;

    if (opts.merge_companions) {
        source_file = try import_pipeline.mergeEntryCompanions(gpa, parse_allocator, file_path, source_file);
    }

    const combine = try import_pipeline.combineImports(
        gpa,
        parse_allocator,
        &ctx.resolver,
        &source_file,
        file_path,
        entry_file_absolute,
    );

    return .{
        .program = source_file,
        .registry = user_registry,
        .imported_paths = combine.imported_paths,
        .had_reporter_errors = parser.reporter.hasErrors(),
        .diagnostics = diagnostics,
    };
}
