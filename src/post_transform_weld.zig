//! Post-transform weld — resolve transform-appended imports and refresh
//! `build_output.zig` so per-model `build:requires` land in the output link.

const std = @import("std");
const ast = @import("ast");
const config = @import("config");
const module_resolver = @import("module_resolver");
const import_pipeline = @import("import_pipeline");
const compiler_requires = @import("compiler_requires");
const emit_build_zig = @import("emit_build_zig");
const log = @import("log");
const canonicalize_names = @import("canonicalize_names");

pub fn weldAfterTransform(program: *ast.Program, allocator: std.mem.Allocator) !void {
    const env = @import("compiler_env").CompilerEnv;
    if (env.entry_file.len == 0 or env.project_root.len == 0 or env.koru_home.len == 0) {
        return;
    }

    var project_config = (try config.Config.load(allocator, env.project_root)) orelse try config.Config.default(allocator);
    defer project_config.deinit();

    var resolver = try module_resolver.ModuleResolver.init(allocator, &project_config, env.project_root, env.entry_dir, env.flags, env.koru_home);
    defer resolver.deinit();

    const merged = try import_pipeline.mergeOutstandingImports(allocator, allocator, &resolver, program, env.entry_file);
    if (!merged) return;

    // Welded modules parse with basename module names and unqualified tor paths.
    // Canonicalize stamps logical module qualifiers so dead_strip keys match
    // cross-module invocations (frag-0002 — same rule as synthesized tors).
    try canonicalize_names.canonicalize(program, allocator);

    log.debug("[post_transform_weld] merged transform-appended imports — refreshing build_output.zig\n", .{});

    var collector = try compiler_requires.CompilerRequiresCollector.init(allocator);
    defer collector.deinit();
    try collector.collectFromProgram(program);

    const build_reqs_raw = collector.getBuildRequirements();
    if (build_reqs_raw.len == 0) return;

    var output_build_reqs = try std.ArrayList(emit_build_zig.BuildRequirement).initCapacity(allocator, build_reqs_raw.len);
    defer output_build_reqs.deinit(allocator);

    for (build_reqs_raw) |req| {
        try output_build_reqs.append(allocator, .{
            .module_name = "user",
            .source_code = req,
        });
    }

    try emit_build_zig.emitOutputBuildZig(allocator, output_build_reqs.items, "build_output.zig", env.koru_home);
}
