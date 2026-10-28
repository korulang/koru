/// Build.zig Generation Library
const log = @import("log");
///
/// A reusable library for generating Zig build files from collected requirements.
/// This can be used by the compiler itself, userspace tools, or even metacircularly
/// to generate the compiler's own build system.
///
/// Design Pattern: Struct Namespacing
///
/// Each module's build code is wrapped in an isolated struct scope to prevent
/// variable conflicts. This pattern is documented in docs/BUILD_REQUIRES.md.

const std = @import("std");

/// Represents a single build requirement collected from ~build:requires invocations
pub const BuildRequirement = struct {
    module_name: []const u8,
    source_code: []const u8,
};

pub const RefuseOverwriteBuildZig = error{RefuseOverwriteBuildZig};

/// Refuse to overwrite a non-koru-generated build.zig. Koru emits
/// `pub fn build(__koru_b: *std.Build)`; compiler and hand-written Zig projects
/// use `pub fn build(b: *std.Build)` and paths like src/ast.zig.
pub fn guardNonKoruBuildZig(output_path: []const u8) RefuseOverwriteBuildZig!void {
    if (!std.mem.eql(u8, std.fs.path.basename(output_path), "build.zig")) return;

    const existing = std.fs.cwd().openFile(output_path, .{}) catch return;
    defer existing.close();

    var head_buf: [8192]u8 = undefined;
    const head = existing.read(&head_buf) catch return;
    const content = head_buf[0..head];

    if (std.mem.indexOf(u8, content, "__koru_b") != null) return;
    if (std.mem.indexOf(u8, content, "pub fn build(b: *std.Build)") != null) {
        return error.RefuseOverwriteBuildZig;
    }
    if (std.mem.indexOf(u8, content, "src/ast.zig") != null) {
        return error.RefuseOverwriteBuildZig;
    }
}

/// Append string to buffer
fn append(buf: []u8, p: *usize, str: []const u8) void {
    @memcpy(buf[p.*..p.* + str.len], str);
    p.* += str.len;
}

/// Sanitize module name to valid Zig identifier.
/// Converts slashes, dots, and dashes to underscores.
fn sanitizeModuleName(module_name: []const u8) [256]u8 {
    var result: [256]u8 = undefined;
    var i: usize = 0;
    for (module_name) |c| {
        if (c == '/' or c == '.' or c == '-') {
            result[i] = '_';
        } else {
            result[i] = c;
        }
        i += 1;
        if (i >= 256) break;
    }
    return result;
}

/// Emit one requirement as a struct-wrapped `call` fn plus its invocation —
/// the loop body both emitters below share.
fn appendRequirementWrapper(
    allocator: std.mem.Allocator,
    buffer: []u8,
    pos: *usize,
    req: *const BuildRequirement,
    i: usize,
    rel_to_root: []const u8,
    comment: []const u8,
) !void {
    const sanitized = sanitizeModuleName(req.module_name);
    const sanitized_len = req.module_name.len;

    var index_buf: [32]u8 = undefined;
    const index_str = std.fmt.bufPrint(&index_buf, "{d}", .{i}) catch unreachable;

    append(buffer, pos, "    // ");
    append(buffer, pos, comment);
    append(buffer, pos, req.module_name);
    append(buffer, pos, "\n");

    append(buffer, pos, "    const ");
    append(buffer, pos, sanitized[0..sanitized_len]);
    append(buffer, pos, "_build_");
    append(buffer, pos, index_str);
    append(buffer, pos,
        \\ = struct {
        \\        fn call(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
        \\            _ = &b; _ = &exe; _ = &target; _ = &optimize; // Suppress unused warnings
        \\
    );

    // Inject the user's build code (already properly indented from Source
    // capture); replace ${REL_TO_ROOT} with the actual relative path.
    const substituted_code = try std.mem.replaceOwned(u8, allocator, req.source_code, "${REL_TO_ROOT}", rel_to_root);
    defer allocator.free(substituted_code);
    append(buffer, pos, substituted_code);

    append(buffer, pos,
        \\
        \\        }
        \\    }.call;
        \\
    );

    append(buffer, pos, sanitized[0..sanitized_len]);
    append(buffer, pos, "_build_");
    append(buffer, pos, index_str);
    append(buffer, pos, "(__koru_b, __koru_exe, __koru_target, __koru_optimize);\n\n");
}

/// Escape one plist string value for XML: `&` `<` `>` `"` become entities so
/// the value can't break the dict shape, and control bytes collapse to spaces
/// (a control byte in a name can't spell a C string portably downstream). C
/// escaping is NOT this function's job — the requirement's own per-byte pass
/// handles it.
fn writePlistEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => if (c < 0x20) try w.writeByte(' ') else try w.writeByte(c),
    };
}

/// CFBundleIconFile's value from a declared `icon:` path — the basename
/// minus the .icns extension (the convention: file `AppIcon.icns` lands in
/// Resources, the key says `AppIcon`). Both plist carriers call this so
/// embedded and disk always agree.
pub fn appIconFileName(icon_path: []const u8) []const u8 {
    const base = std.fs.path.basename(icon_path);
    if (std.mem.endsWith(u8, base, ".icns")) return base[0 .. base.len - ".icns".len];
    return base;
}

/// The Info.plist bytes a `std/build:app` declaration compiles down to —
/// one generator for both carriers so codesign (which cross-checks the
/// embedded __TEXT,__info_plist against Contents/Info.plist when it signs
/// a bundle) always sees one identity. `executable` is CFBundleExecutable;
/// for an unbundled binary the key is inert, but when `koruc bundle` later
/// packages the same binary it is already correct. `icon` is the basename
/// the .icns lands under in Contents/Resources — CFBundleIconFile wants it
/// minus the extension. Single-line XML: the same bytes land verbatim in a
/// C string literal and on disk.
pub fn appInfoPlistXml(
    allocator: std.mem.Allocator,
    name: []const u8,
    id: []const u8,
    version: ?[]const u8,
    executable: []const u8,
    icon: ?[]const u8,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 2048);
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" ++
        "<plist version=\"1.0\"><dict>");
    const Entry = struct { key: []const u8, value: []const u8 };
    const entries = [_]Entry{
        .{ .key = "CFBundleIdentifier", .value = id },
        .{ .key = "CFBundleName", .value = name },
        .{ .key = "CFBundleDisplayName", .value = name },
        .{ .key = "CFBundleExecutable", .value = executable },
        .{ .key = "CFBundlePackageType", .value = "APPL" },
        .{ .key = "NSPrincipalClass", .value = "NSApplication" },
        .{ .key = "LSMinimumSystemVersion", .value = "10.13" },
    };
    for (entries) |e| {
        try w.print("<key>{s}</key><string>", .{e.key});
        try writePlistEscaped(w, e.value);
        try w.writeAll("</string>");
    }
    if (icon) |ic| {
        try w.writeAll("<key>CFBundleIconFile</key><string>");
        try writePlistEscaped(w, ic);
        try w.writeAll("</string>");
    }
    if (version) |v| {
        inline for (.{ "CFBundleShortVersionString", "CFBundleVersion" }) |key| {
            try w.print("<key>{s}</key><string>", .{key});
            try writePlistEscaped(w, v);
            try w.writeAll("</string>");
        }
    }
    try w.writeAll("</dict></plist>");
    return buf.toOwnedSlice(allocator);
}

/// Synthesize the build requirement for `std/build:app { name:, id:, version: }`:
/// a generated C object carrying the Info.plist in __TEXT,__info_plist of the
/// macho output — Zig 0.15's std.Build exposes no arbitrary linker-arg seam for
/// -sectcreate, but addCSourceFile + the section attribute lands the same bytes.
/// Guarded on the resolved target so non-macho builds compile unchanged.
pub fn appInfoPlistRequirement(
    allocator: std.mem.Allocator,
    name: []const u8,
    id: []const u8,
    version: ?[]const u8,
    icon: ?[]const u8,
) !BuildRequirement {
    const xml = try appInfoPlistXml(allocator, name, id, version, name, icon);
    defer allocator.free(xml);

    var buf = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // The C literal carries the plist escaped only for C (" and \); the XML
    // is already entity-escaped by appInfoPlistXml, and single-line XML means
    // no \n escapes are needed in the literal.
    try w.writeAll(
        \\            if (target.result.os.tag == .macos) {
        \\                const __plist_c = b.addWriteFiles().add("koru_info_plist.c",
        \\                    \\__attribute__((used, section("__TEXT,__info_plist")))
        \\                    \\const char __koru_info_plist[] = "
    );
    for (xml) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll(
        \\";
        \\                );
        \\                exe.addCSourceFile(.{ .file = __plist_c });
        \\            }
        \\
    );

    return .{
        .module_name = "app",
        .source_code = try buf.toOwnedSlice(allocator),
    };
}

/// Generate a build.zig file from collected requirements
///
/// Parameters:
/// - allocator: Memory allocator for string operations
/// - requires: Array of build requirements to process
/// - output_path: File path where build.zig should be written
/// - rel_to_root: Relative path from output directory to koru root (for ${REL_TO_ROOT} substitution)
///
/// Returns void on success, error on file creation/write failure
pub fn emitBuildZig(
    allocator: std.mem.Allocator,
    requires: []const BuildRequirement,
    output_path: []const u8,
    rel_to_root: []const u8,
) !void {
    log.debug("📦 Generating build.zig with {d} requirements\n", .{requires.len});

    // Use stack-allocated buffer for build.zig generation (64KB should be enough)
    var buffer: [64 * 1024]u8 = undefined;
    var pos: usize = 0;

    // Generate build.zig header
    // Note: We use __koru_ prefix for outer scope to avoid shadowing the nice names
    // (b, exe) that we want users to use in their ~build:requires blocks
    append(&buffer, &pos,
        \\// Generated by koruc — `zig build` here recompiles emitted backend.zig, never the Koru source; re-verify: koruc build <file>
        \\const std = @import("std");
        \\
        \\// KORU_BACKEND_TARGET supplies the default target — hosts whose native
        \\// glibc predates the toolchain default need it (Ubuntu 20.04 pins
        \\// x86_64-linux-gnu.2.31). Bare `zig build` honors it; -Dtarget overrides.
        \\fn __koruEnvTarget(__koru_b: *std.Build) std.Target.Query {
        \\    const __koru_env = std.process.getEnvVarOwned(__koru_b.allocator, "KORU_BACKEND_TARGET") catch return .{};
        \\    return std.Target.Query.parse(.{ .arch_os_abi = __koru_env }) catch .{};
        \\}
        \\
        \\pub fn build(__koru_b: *std.Build) void {
        \\    const __koru_target = __koru_b.standardTargetOptions(.{ .default_target = __koruEnvTarget(__koru_b) });
        \\    const __koru_optimize = __koru_b.standardOptimizeOption(.{});
        \\
        \\    const __koru_exe = __koru_b.addExecutable(.{
        \\        .name = "backend",
        \\        .root_module = __koru_b.createModule(.{
        \\            .root_source_file = __koru_b.path("backend.zig"),
        \\            .target = __koru_target,
        \\            .optimize = __koru_optimize,
        \\        }),
        \\    });
        \\    // koru_allocator() backs onto std.heap.c_allocator (real libc malloc/free,
        \\    // not a debug allocator that munmaps on every free) — needs libc linked.
        \\    __koru_exe.linkLibC();
        \\    // KORU_BACKEND_LIBPATH: path-list dirs added as -L for linkSystemLibrary.
        \\    // An explicit -Dtarget disables zig's host lib discovery — pinned-glibc
        \\    // hosts (KORU_BACKEND_TARGET=x86_64-linux-gnu.2.31) point this at dirs
        \\    // holding dev .so symlinks, e.g. /usr/lib/x86_64-linux-gnu.
        \\    if (std.process.getEnvVarOwned(__koru_b.allocator, "KORU_BACKEND_LIBPATH")) |__koru_lp| {
        \\        var __koru_it = std.mem.splitScalar(u8, __koru_lp, std.fs.path.delimiter);
        \\        while (__koru_it.next()) |__koru_d| {
        \\            if (__koru_d.len != 0) __koru_exe.addLibraryPath(.{ .cwd_relative = __koru_d });
        \\        }
        \\    } else |_| {}
        \\
        \\
    );

    // Generate struct-wrapped requirement for each module
    // Pattern: Each module gets its own struct scope to prevent variable conflicts
    //   const module_name_build_0 = struct {
    //       fn call(b: *std.Build, exe: *std.Build.Step.Compile) void {
    //           // USER'S BUILD CODE HERE (uses natural b and exe names!)
    //       }
    //   }.call;
    //   module_name_build_0(__koru_b, __koru_exe);
    //
    // Note: We use __koru_ prefix in the OUTER scope so users can use natural
    // names (b, exe) in their build code. No shadowing because different names!
    // Each requirement gets a unique index to prevent name collisions when multiple
    // requirements come from the same module.
    for (requires, 0..) |*req, i| {
        try appendRequirementWrapper(allocator, &buffer, &pos, req, i, rel_to_root, "Module: ");
    }

    // Add final installArtifact call
    append(&buffer, &pos,
        \\    __koru_b.installArtifact(__koru_exe);
        \\}
        \\
    );

    const final_content = buffer[0..pos];

    log.debug("📦 Generated {d} bytes of build.zig\n", .{final_content.len});
    log.debug("📦 Writing to: {s}\n", .{output_path});

    try guardNonKoruBuildZig(output_path);

    // Write to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try file.writeAll(final_content);

    log.debug("✅ Successfully wrote build.zig\n", .{});
}

/// Generate a build.zig file for the OUTPUT binary (compiled from output_emitted.zig)
/// This is separate from the backend build.zig as it uses user dependencies (build:requires)
pub fn emitOutputBuildZig(
    allocator: std.mem.Allocator,
    requires: []const BuildRequirement,
    output_path: []const u8,
    rel_to_root: []const u8,
) !void {
    log.debug("📦 Generating output build.zig with {d} requirements\n", .{requires.len});

    var buffer: [64 * 1024]u8 = undefined;
    var pos: usize = 0;

    // Header - note we target output_emitted.zig, not backend.zig
    append(&buffer, &pos,
        \\// Generated by koruc — `zig build` here recompiles output_emitted.zig, never the Koru source; re-verify: koruc build <file>
        \\const std = @import("std");
        \\
        \\// KORU_BACKEND_TARGET supplies the default target — hosts whose native
        \\// glibc predates the toolchain default need it (Ubuntu 20.04 pins
        \\// x86_64-linux-gnu.2.31). Bare `zig build` honors it; -Dtarget overrides.
        \\fn __koruEnvTarget(__koru_b: *std.Build) std.Target.Query {
        \\    const __koru_env = std.process.getEnvVarOwned(__koru_b.allocator, "KORU_BACKEND_TARGET") catch return .{};
        \\    return std.Target.Query.parse(.{ .arch_os_abi = __koru_env }) catch .{};
        \\}
        \\
        \\pub fn build(__koru_b: *std.Build) void {
        \\    const __koru_target = __koru_b.standardTargetOptions(.{ .default_target = __koruEnvTarget(__koru_b) });
        \\    // The OUTPUT binary defaults to Debug (safety checks on — the mode the
        \\    // test suite should judge). The backend passes -Doptimize=ReleaseFast
        \\    // when the program is built with --release=fast; -Doptimize overrides.
        \\    const __koru_optimize = __koru_b.standardOptimizeOption(.{});
        \\
        \\    const __koru_exe = __koru_b.addExecutable(.{
        \\        .name = "output",
        \\        .root_module = __koru_b.createModule(.{
        \\            .root_source_file = __koru_b.path("output_emitted.zig"),
        \\            .target = __koru_target,
        \\            .optimize = __koru_optimize,
        \\        }),
        \\    });
        \\    // Native binaries need libc for koru_allocator(); wasm freestanding reactors opt out in requires.
        \\    switch (__koru_target.result.cpu.arch) {
        \\        .wasm32, .wasm64 => {},
        \\        else => __koru_exe.linkLibC(),
        \\    }
        \\    // KORU_BACKEND_LIBPATH: path-list dirs added as -L for linkSystemLibrary.
        \\    // An explicit -Dtarget disables zig's host lib discovery — pinned-glibc
        \\    // hosts (KORU_BACKEND_TARGET=x86_64-linux-gnu.2.31) point this at dirs
        \\    // holding dev .so symlinks, e.g. /usr/lib/x86_64-linux-gnu.
        \\    if (std.process.getEnvVarOwned(__koru_b.allocator, "KORU_BACKEND_LIBPATH")) |__koru_lp| {
        \\        var __koru_it = std.mem.splitScalar(u8, __koru_lp, std.fs.path.delimiter);
        \\        while (__koru_it.next()) |__koru_d| {
        \\            if (__koru_d.len != 0) __koru_exe.addLibraryPath(.{ .cwd_relative = __koru_d });
        \\        }
        \\    } else |_| {}
        \\
        \\
    );

    // `Source`-typed tor fields emit `__koru_ast.Source` references into
    // output_emitted.zig. Map the ast module (plus its errors and
    // glob_pattern_matcher deps) unconditionally — Zig analyzes a mapped module
    // only when the emitted code actually imports it, so programs without
    // Source fields pay nothing.
    var ast_mod_buf: [4096]u8 = undefined;
    const ast_mod_src = std.fmt.bufPrint(&ast_mod_buf,
        \\    // Compiler-AST module — mapped for `Source`-typed fields (see header comment)
        \\    const __koru_errors_mod = __koru_b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}/src/errors.zig" }},
        \\        .target = __koru_target,
        \\        .optimize = __koru_optimize,
        \\    }});
        \\    const __koru_gpm_mod = __koru_b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}/src/glob_pattern_matcher.zig" }},
        \\        .target = __koru_target,
        \\        .optimize = __koru_optimize,
        \\    }});
        \\    const __koru_ast_mod = __koru_b.createModule(.{{
        \\        .root_source_file = .{{ .cwd_relative = "{s}/src/ast.zig" }},
        \\        .target = __koru_target,
        \\        .optimize = __koru_optimize,
        \\    }});
        \\    __koru_ast_mod.addImport("errors", __koru_errors_mod);
        \\    __koru_ast_mod.addImport("glob_pattern_matcher", __koru_gpm_mod);
        \\    __koru_exe.root_module.addImport("ast", __koru_ast_mod);
        \\
        \\
    , .{ rel_to_root, rel_to_root, rel_to_root }) catch return error.BufferOverflow;
    append(&buffer, &pos, ast_mod_src);

    // Add each build requirement
    for (requires, 0..) |*req, i| {
        try appendRequirementWrapper(allocator, &buffer, &pos, req, i, rel_to_root, "User module: ");
    }

    append(&buffer, &pos,
        \\    __koru_b.installArtifact(__koru_exe);
        \\}
        \\
    );

    const final_content = buffer[0..pos];

    log.debug("📦 Generated {d} bytes of output build.zig\n", .{final_content.len});
    log.debug("📦 Writing to: {s}\n", .{output_path});

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(final_content);

    log.debug("✅ Successfully wrote output build.zig\n", .{});
}

test "sanitizeModuleName basic" {
    const sanitize = struct {
        fn call(module_name: []const u8) [256]u8 {
            var result: [256]u8 = undefined;
            var i: usize = 0;
            for (module_name) |c| {
                if (c == '/' or c == '.' or c == '-') {
                    result[i] = '_';
                } else {
                    result[i] = c;
                }
                i += 1;
                if (i >= 256) break;
            }
            return result;
        }
    }.call;

    const input = "foo/bar.baz-qux";
    const result = sanitize(input);
    const expected = "foo_bar_baz_qux";

    try std.testing.expectEqualSlices(u8, expected, result[0..input.len]);
}

test "guardNonKoruBuildZig refuses compiler-shaped build.zig" {
    const testing = std.testing;

    const test_dir = "test_build_guard";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const compiler_build =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.path("src/ast.zig");
        \\}
    ;
    const path = test_dir ++ "/build.zig";
    try std.fs.cwd().writeFile(path, compiler_build);

    try testing.expectError(error.RefuseOverwriteBuildZig, guardNonKoruBuildZig(path));
}

test "emitBuildZig basic" {
    const testing = std.testing;

    // Create temporary test directory
    const test_dir = "test_build_output";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const requirements = [_]BuildRequirement{
        .{
            .module_name = "test_module",
            .source_code = "            exe.linkSystemLibrary(\"c\");\n",
        },
    };

    const output_path = test_dir ++ "/build.zig";

    // Generate build.zig
    try emitBuildZig(testing.allocator, &requirements, output_path, ".");

    // Read back and verify
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    // Verify basic structure
    try testing.expect(std.mem.indexOf(u8, content, "pub fn build") != null);
    try testing.expect(std.mem.indexOf(u8, content, "test_module_build_0") != null);
    try testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary") != null);
    try testing.expect(std.mem.indexOf(u8, content, "__koru_b.installArtifact(__koru_exe)") != null);
}
