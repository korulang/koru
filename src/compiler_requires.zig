const std = @import("std");
const ast = @import("ast");

/// CompilerRequiresCollector gathers build requirements from the AST.
/// It distinguishes between:
/// - std.compiler:requires → for BACKEND compilation (backend.zig)
/// - std.build:requires → for OUTPUT binary (output_emitted.zig)
pub const CompilerRequiresCollector = struct {
    allocator: std.mem.Allocator,
    compiler_requirements: std.ArrayList([]const u8), // For backend.zig
    build_requirements: std.ArrayList([]const u8), // For output binary

    pub fn init(allocator: std.mem.Allocator) !CompilerRequiresCollector {
        return CompilerRequiresCollector{
            .allocator = allocator,
            .compiler_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .build_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *CompilerRequiresCollector) void {
        for (self.compiler_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.compiler_requirements.deinit(self.allocator);

        for (self.build_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.build_requirements.deinit(self.allocator);
    }

    // Legacy alias for backwards compatibility
    pub fn getRequirements(self: *CompilerRequiresCollector) []const []const u8 {
        return self.compiler_requirements.items;
    }

    /// Collect all ~compiler:requires invocations from the source file
    pub fn collectFromSourceFile(self: *CompilerRequiresCollector, source_file: *const ast.Program) !void {
        std.debug.print("[CompilerRequiresCollector] Starting collection from {} items\n", .{source_file.items.len});

        // Walk top-level items
        for (source_file.items) |item| {
            switch (item) {
                .flow => |flow| {
                    try self.checkFlowForRequires(&flow);
                },
                .module_decl => |module| {
                    std.debug.print("[CompilerRequiresCollector] Checking module: {s} ({} items)\n", .{ module.logical_name, module.items.len });
                    // Also check imported modules
                    for (module.items) |mod_item| {
                        const item_type = @tagName(mod_item);
                        std.debug.print("[CompilerRequiresCollector]   Item type: {s}\n", .{item_type});
                        switch (mod_item) {
                            .flow => |flow_inner| {
                                try self.checkFlowForRequires(&flow_inner);
                            },
                            .parse_error => |err| {
                                std.debug.print("[CompilerRequiresCollector]   PARSE ERROR: {s}\n", .{err.message});
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn checkFlowForRequires(self: *CompilerRequiresCollector, flow: *const ast.Flow) !void {
        if (flow.invocation.path.module_qualifier) |mq| {
            if (flow.invocation.path.segments.len < 1) return;

            // DEBUG: Print what we're checking
            std.debug.print("[CompilerRequiresCollector] Checking flow: {s}:{s}\n", .{ mq, flow.invocation.path.segments[0] });

            // Check for std.build:requires (for OUTPUT binary)
            const is_build_module = std.mem.endsWith(u8, mq, ".build") or std.mem.eql(u8, mq, "build");
            const is_build_requires = is_build_module and
                flow.invocation.path.segments.len == 1 and
                std.mem.eql(u8, flow.invocation.path.segments[0], "requires");

            // Check for std.compiler:requires or std.compiler_requirements:requires (for BACKEND)
            const is_compiler_module = std.mem.endsWith(u8, mq, ".compiler") or std.mem.eql(u8, mq, "compiler");
            const is_compiler_requirements_module = std.mem.endsWith(u8, mq, ".compiler_requirements") or std.mem.eql(u8, mq, "compiler_requirements");
            const is_compiler_requires = (is_compiler_module or is_compiler_requirements_module) and
                flow.invocation.path.segments.len == 1 and
                std.mem.eql(u8, flow.invocation.path.segments[0], "requires");

            if (is_build_requires) {
                std.debug.print("[CompilerRequiresCollector] ✓ FOUND build:requires (for output binary)!\n", .{});
                try self.extractAndAddSource(flow, &self.build_requirements);
            } else if (is_compiler_requires) {
                std.debug.print("[CompilerRequiresCollector] ✓ FOUND compiler:requires (for backend)!\n", .{});
                try self.extractAndAddSource(flow, &self.compiler_requirements);
            }
        }
    }

    fn extractAndAddSource(self: *CompilerRequiresCollector, flow: *const ast.Flow, target_list: *std.ArrayList([]const u8)) !void {
        for (flow.invocation.args) |arg| {
            // Accept both "source" (named) and "" (anonymous block with source_value)
            if (std.mem.eql(u8, arg.name, "source") or (std.mem.eql(u8, arg.name, "") and arg.source_value != null)) {
                const source_code = if (arg.source_value) |sv| sv.text else arg.value;
                const source_copy = try self.allocator.dupe(u8, source_code);
                try target_list.append(self.allocator, source_copy);
                std.debug.print("[CompilerRequiresCollector]   Added requirement ({d} bytes)\n", .{source_code.len});
            }
        }
    }

    /// Get compiler requirements (for backend.zig)
    pub fn getCompilerRequirements(self: *CompilerRequiresCollector) []const []const u8 {
        return self.compiler_requirements.items;
    }

    /// Get build requirements (for output binary)
    pub fn getBuildRequirements(self: *CompilerRequiresCollector) []const []const u8 {
        return self.build_requirements.items;
    }
};

// Tests
test "collects single compiler:requires" {
    const allocator = std.testing.allocator;

    var collector = try CompilerRequiresCollector.init(allocator);
    defer collector.deinit();

    // Create a minimal flow with compiler:requires
    var segments = [_][]const u8{"requires"};
    var args = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "exe.linkSystemLibrary(\"sqlite3\");",
            .source_value = null,
        },
    };

    const flow = ast.Flow{
        .invocation = ast.Invocation{
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "compiler",
            },
            .args = &args,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForRequires(&flow);

    const reqs = collector.getCompilerRequirements();
    try std.testing.expectEqual(@as(usize, 1), reqs.len);
    try std.testing.expectEqualStrings("exe.linkSystemLibrary(\"sqlite3\");", reqs[0]);
}

test "collects multiple compiler:requires" {
    const allocator = std.testing.allocator;

    var collector = try CompilerRequiresCollector.init(allocator);
    defer collector.deinit();

    // Create two flows
    var segments = [_][]const u8{"requires"};
    var args1 = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "exe.linkSystemLibrary(\"sqlite3\");",
            .source_value = null,
        },
    };
    var args2 = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "exe.linkSystemLibrary(\"c\");",
            .source_value = null,
        },
    };

    const flow1 = ast.Flow{
        .invocation = ast.Invocation{
            .module_qualifier = "compiler",
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "compiler",
            },
            .args = &args1,
        },
        .continuations = &.{},
    };

    const flow2 = ast.Flow{
        .invocation = ast.Invocation{
            .module_qualifier = "compiler",
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "compiler",
            },
            .args = &args2,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForRequires(&flow1);
    try collector.checkFlowForRequires(&flow2);

    const reqs = collector.getCompilerRequirements();
    try std.testing.expectEqual(@as(usize, 2), reqs.len);
    try std.testing.expectEqualStrings("exe.linkSystemLibrary(\"sqlite3\");", reqs[0]);
    try std.testing.expectEqualStrings("exe.linkSystemLibrary(\"c\");", reqs[1]);
}

test "ignores non-compiler:requires flows" {
    const allocator = std.testing.allocator;

    var collector = try CompilerRequiresCollector.init(allocator);
    defer collector.deinit();

    // Create a flow that is NOT compiler:requires
    var segments = [_][]const u8{"somethingElse"};
    var args = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "this should be ignored",
            .source_value = null,
        },
    };

    const flow = ast.Flow{
        .invocation = ast.Invocation{
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "compiler",
            },
            .args = &args,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForRequires(&flow);

    const reqs = collector.getCompilerRequirements();
    try std.testing.expectEqual(@as(usize, 0), reqs.len);
    // Also check build requirements are empty
    try std.testing.expectEqual(@as(usize, 0), collector.getBuildRequirements().len);
}
