/// Build.zig Generation Library
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
    std.debug.print("📦 Generating build.zig with {d} requirements\n", .{requires.len});

    // Use stack-allocated buffer for build.zig generation (64KB should be enough)
    var buffer: [64 * 1024]u8 = undefined;
    var pos: usize = 0;

    // Helper: Append string to buffer
    const append = struct {
        fn call(buf: []u8, p: *usize, str: []const u8) void {
            @memcpy(buf[p.*..p.* + str.len], str);
            p.* += str.len;
        }
    }.call;

    // Helper: Sanitize module name to valid Zig identifier
    // Converts slashes, dots, and dashes to underscores
    const sanitizeModuleName = struct {
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

    // Generate build.zig header
    // Note: We use __koru_ prefix for outer scope to avoid shadowing the nice names
    // (b, exe) that we want users to use in their ~build:requires blocks
    append(&buffer, &pos,
        \\const std = @import("std");
        \\
        \\pub fn build(__koru_b: *std.Build) void {
        \\    const __koru_target = __koru_b.standardTargetOptions(.{});
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
    for (requires, 0..) |req, i| {
        const sanitized = sanitizeModuleName(req.module_name);
        const sanitized_len = req.module_name.len;

        // Format the index as a string
        var index_buf: [32]u8 = undefined;
        const index_str = std.fmt.bufPrint(&index_buf, "{d}", .{i}) catch unreachable;

        // Comment showing original module name
        append(&buffer, &pos, "    // Module: ");
        append(&buffer, &pos, req.module_name);
        append(&buffer, &pos, "\n");

        // Start struct wrapper
        append(&buffer, &pos, "    const ");
        append(&buffer, &pos, sanitized[0..sanitized_len]);
        append(&buffer, &pos, "_build_");
        append(&buffer, &pos, index_str);
        append(&buffer, &pos,
            \\ = struct {
            \\        fn call(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
            \\            _ = &b; _ = &exe; _ = &target; _ = &optimize; // Suppress unused warnings
            \\
        );

        // Inject the user's build code (already properly indented from Source capture)
        // Replace ${REL_TO_ROOT} with the actual relative path
        const substituted_code = try std.mem.replaceOwned(u8, allocator, req.source_code, "${REL_TO_ROOT}", rel_to_root);
        defer allocator.free(substituted_code);
        append(&buffer, &pos, substituted_code);

        // Close struct wrapper
        append(&buffer, &pos,
            \\
            \\        }
            \\    }.call;
            \\
        );

        // Call the wrapper (pass __koru_ prefixed names from outer scope)
        append(&buffer, &pos, sanitized[0..sanitized_len]);
        append(&buffer, &pos, "_build_");
        append(&buffer, &pos, index_str);
        append(&buffer, &pos, "(__koru_b, __koru_exe, __koru_target, __koru_optimize);\n\n");
    }

    // Add final installArtifact call
    append(&buffer, &pos,
        \\    __koru_b.installArtifact(__koru_exe);
        \\}
        \\
    );

    const final_content = buffer[0..pos];

    std.debug.print("📦 Generated {d} bytes of build.zig\n", .{final_content.len});
    std.debug.print("📦 Writing to: {s}\n", .{output_path});

    // Write to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    try file.writeAll(final_content);

    std.debug.print("✅ Successfully wrote build.zig\n", .{});
}

/// Generate a build.zig file for the OUTPUT binary (compiled from output_emitted.zig)
/// This is separate from the backend build.zig as it uses user dependencies (build:requires)
pub fn emitOutputBuildZig(
    _: std.mem.Allocator, // Reserved for future use
    requires: []const BuildRequirement,
    output_path: []const u8,
) !void {
    std.debug.print("📦 Generating output build.zig with {d} requirements\n", .{requires.len});

    var buffer: [64 * 1024]u8 = undefined;
    var pos: usize = 0;

    const append = struct {
        fn call(buf: []u8, p: *usize, str: []const u8) void {
            @memcpy(buf[p.*..p.* + str.len], str);
            p.* += str.len;
        }
    }.call;

    const sanitizeModuleName = struct {
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
            }
            return result;
        }
    }.call;

    // Header - note we target output_emitted.zig, not backend.zig
    append(&buffer, &pos,
        \\const std = @import("std");
        \\
        \\pub fn build(__koru_b: *std.Build) void {
        \\    const __koru_target = __koru_b.standardTargetOptions(.{});
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
        \\
        \\
    );

    // Add each build requirement
    for (requires, 0..) |req, i| {
        const sanitized = sanitizeModuleName(req.module_name);
        const sanitized_len = req.module_name.len;

        var index_buf: [32]u8 = undefined;
        const index_str = std.fmt.bufPrint(&index_buf, "{d}", .{i}) catch unreachable;

        append(&buffer, &pos, "    // User module: ");
        append(&buffer, &pos, req.module_name);
        append(&buffer, &pos, "\n");

        append(&buffer, &pos, "    const ");
        append(&buffer, &pos, sanitized[0..sanitized_len]);
        append(&buffer, &pos, "_build_");
        append(&buffer, &pos, index_str);
        append(&buffer, &pos,
            \\ = struct {
            \\        fn call(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
            \\            _ = &b; _ = &exe; _ = &target; _ = &optimize; // Suppress unused warnings
            \\
        );

        // Add the user's build code directly (no REL_TO_ROOT substitution needed)
        append(&buffer, &pos, req.source_code);

        append(&buffer, &pos,
            \\
            \\        }
            \\    }.call;
            \\
        );

        append(&buffer, &pos, sanitized[0..sanitized_len]);
        append(&buffer, &pos, "_build_");
        append(&buffer, &pos, index_str);
        append(&buffer, &pos, "(__koru_b, __koru_exe, __koru_target, __koru_optimize);\n\n");
    }

    append(&buffer, &pos,
        \\    __koru_b.installArtifact(__koru_exe);
        \\}
        \\
    );

    const final_content = buffer[0..pos];

    std.debug.print("📦 Generated {d} bytes of output build.zig\n", .{final_content.len});
    std.debug.print("📦 Writing to: {s}\n", .{output_path});

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(final_content);

    std.debug.print("✅ Successfully wrote output build.zig\n", .{});
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
