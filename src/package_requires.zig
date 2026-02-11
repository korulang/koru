const std = @import("std");
const ast = @import("ast");

/// PackageRequirementsCollector gathers all ~std.package:requires.* invocations
/// from the AST to generate package files (package.json, Cargo.toml, etc.).
/// This is a compiler pass that walks the AST looking for package requirement
/// invocations for different package managers.
pub const PackageRequirementsCollector = struct {
    allocator: std.mem.Allocator,
    npm_requirements: std.ArrayList([]const u8),
    cargo_requirements: std.ArrayList([]const u8),
    go_requirements: std.ArrayList([]const u8),
    pip_requirements: std.ArrayList([]const u8),
    zig_requirements: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !PackageRequirementsCollector {
        return PackageRequirementsCollector{
            .allocator = allocator,
            .npm_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .cargo_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .go_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .pip_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .zig_requirements = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *PackageRequirementsCollector) void {
        for (self.npm_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.npm_requirements.deinit(self.allocator);

        for (self.cargo_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.cargo_requirements.deinit(self.allocator);

        for (self.go_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.go_requirements.deinit(self.allocator);

        for (self.pip_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.pip_requirements.deinit(self.allocator);

        for (self.zig_requirements.items) |req| {
            self.allocator.free(req);
        }
        self.zig_requirements.deinit(self.allocator);
    }

    /// Collect all ~std.package:requires.* invocations from the source file
    pub fn collectFromSourceFile(self: *PackageRequirementsCollector, source_file: *const ast.Program) !void {
        // Walk top-level items
        for (source_file.items) |item| {
            switch (item) {
                .flow => |flow| {
                    try self.checkFlowForPackageRequires(&flow);
                },
                .module_decl => |module| {
                    // Also check imported modules
                    for (module.items) |mod_item| {
                        switch (mod_item) {
                            .flow => |flow_inner| {
                                try self.checkFlowForPackageRequires(&flow_inner);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn checkFlowForPackageRequires(self: *PackageRequirementsCollector, flow: *const ast.Flow) !void {
        // Check if this is a package requirements invocation
        // Looking for std.package:requires.npm, std.package:requires.cargo, etc.
        // After canonicalization, module_qualifier is the full module name "std.package"
        if (flow.invocation.path.module_qualifier) |mq| {
            if (std.mem.eql(u8, mq, "std.package") and
                flow.invocation.path.segments.len == 2 and
                std.mem.eql(u8, flow.invocation.path.segments[0], "requires"))
            {
                const package_type = flow.invocation.path.segments[1];

                // Determine which package manager
                const is_npm = std.mem.eql(u8, package_type, "npm");
                const is_cargo = std.mem.eql(u8, package_type, "cargo");
                const is_go = std.mem.eql(u8, package_type, "go");
                const is_pip = std.mem.eql(u8, package_type, "pip");

                if (is_npm or is_cargo or is_go or is_pip) {
                    // Extract source parameter
                    for (flow.invocation.args) |arg| {
                        if (std.mem.eql(u8, arg.name, "source")) {
                            const source_copy = try self.allocator.dupe(u8, arg.value);

                            // Add to appropriate list
                            if (is_npm) {
                                try self.npm_requirements.append(self.allocator, source_copy);
                            } else if (is_cargo) {
                                try self.cargo_requirements.append(self.allocator, source_copy);
                            } else if (is_go) {
                                try self.go_requirements.append(self.allocator, source_copy);
                            } else if (is_pip) {
                                try self.pip_requirements.append(self.allocator, source_copy);
                            }
                        }
                    }
                }
            }

            // Also check for std.deps:requires.zig (Zig package manager dependencies)
            if (std.mem.eql(u8, mq, "std.deps") and
                flow.invocation.path.segments.len == 2 and
                std.mem.eql(u8, flow.invocation.path.segments[0], "requires") and
                std.mem.eql(u8, flow.invocation.path.segments[1], "zig"))
            {
                for (flow.invocation.args) |arg| {
                    if (std.mem.eql(u8, arg.name, "source")) {
                        const source_copy = try self.allocator.dupe(u8, arg.value);
                        try self.zig_requirements.append(self.allocator, source_copy);
                    }
                }
            }
        }
    }

    /// Get the collected requirements for each package manager
    pub fn getNpmRequirements(self: *PackageRequirementsCollector) []const []const u8 {
        return self.npm_requirements.items;
    }

    pub fn getCargoRequirements(self: *PackageRequirementsCollector) []const []const u8 {
        return self.cargo_requirements.items;
    }

    pub fn getGoRequirements(self: *PackageRequirementsCollector) []const []const u8 {
        return self.go_requirements.items;
    }

    pub fn getPipRequirements(self: *PackageRequirementsCollector) []const []const u8 {
        return self.pip_requirements.items;
    }

    pub fn getZigRequirements(self: *PackageRequirementsCollector) []const []const u8 {
        return self.zig_requirements.items;
    }

    /// Check if any requirements were collected
    pub fn hasAnyRequirements(self: *PackageRequirementsCollector) bool {
        return self.npm_requirements.items.len > 0 or
            self.cargo_requirements.items.len > 0 or
            self.go_requirements.items.len > 0 or
            self.pip_requirements.items.len > 0 or
            self.zig_requirements.items.len > 0;
    }
};

// Tests
test "collects npm requirements" {
    const allocator = std.testing.allocator;

    var collector = try PackageRequirementsCollector.init(allocator);
    defer collector.deinit();

    // Create a flow for std.package:requires.npm
    var segments = [_][]const u8{ "package", "requires.npm" };
    var args = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "\"lodash\": \"^4.17.21\"",
            .source_value = null,
        },
    };

    const flow = ast.Flow{
        .invocation = ast.Invocation{
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "std",
            },
            .args = &args,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForPackageRequires(&flow);

    const npm_reqs = collector.getNpmRequirements();
    try std.testing.expectEqual(@as(usize, 1), npm_reqs.len);
    try std.testing.expectEqualStrings("\"lodash\": \"^4.17.21\"", npm_reqs[0]);

    // Other lists should be empty
    try std.testing.expectEqual(@as(usize, 0), collector.getCargoRequirements().len);
    try std.testing.expectEqual(@as(usize, 0), collector.getGoRequirements().len);
    try std.testing.expectEqual(@as(usize, 0), collector.getPipRequirements().len);
}

test "collects cargo requirements" {
    const allocator = std.testing.allocator;

    var collector = try PackageRequirementsCollector.init(allocator);
    defer collector.deinit();

    // Create a flow for std.package:requires.cargo
    var segments = [_][]const u8{ "package", "requires.cargo" };
    var args = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "serde = \"1.0\"",
            .source_value = null,
        },
    };

    const flow = ast.Flow{
        .invocation = ast.Invocation{
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "std",
            },
            .args = &args,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForPackageRequires(&flow);

    const cargo_reqs = collector.getCargoRequirements();
    try std.testing.expectEqual(@as(usize, 1), cargo_reqs.len);
    try std.testing.expectEqualStrings("serde = \"1.0\"", cargo_reqs[0]);
}

test "collects multiple npm requirements" {
    const allocator = std.testing.allocator;

    var collector = try PackageRequirementsCollector.init(allocator);
    defer collector.deinit();

    // Create multiple npm flows
    var segments = [_][]const u8{ "package", "requires.npm" };
    var args1 = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "\"@koru/graphics\": \"^1.0.0\"",
            .source_value = null,
        },
    };
    var args2 = [_]ast.Argument{
        ast.Argument{
            .name = "source",
            .value = "\"lodash\": \"^4.17.21\"",
            .source_value = null,
        },
    };

    const flow1 = ast.Flow{
        .invocation = ast.Invocation{
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "std",
            },
            .args = &args1,
        },
        .continuations = &.{},
    };

    const flow2 = ast.Flow{
        .invocation = ast.Invocation{
            .path = ast.DottedPath{
                .segments = &segments,
                .module_qualifier = "std",
            },
            .args = &args2,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForPackageRequires(&flow1);
    try collector.checkFlowForPackageRequires(&flow2);

    const npm_reqs = collector.getNpmRequirements();
    try std.testing.expectEqual(@as(usize, 2), npm_reqs.len);
    try std.testing.expectEqualStrings("\"@koru/graphics\": \"^1.0.0\"", npm_reqs[0]);
    try std.testing.expectEqualStrings("\"lodash\": \"^4.17.21\"", npm_reqs[1]);
}

test "ignores non-package flows" {
    const allocator = std.testing.allocator;

    var collector = try PackageRequirementsCollector.init(allocator);
    defer collector.deinit();

    // Create a flow that is NOT a package requirement
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
                .module_qualifier = "std",
            },
            .args = &args,
        },
        .continuations = &.{},
    };

    try collector.checkFlowForPackageRequires(&flow);

    try std.testing.expectEqual(@as(usize, 0), collector.getNpmRequirements().len);
    try std.testing.expectEqual(@as(usize, 0), collector.getCargoRequirements().len);
    try std.testing.expectEqual(@as(usize, 0), collector.getGoRequirements().len);
    try std.testing.expectEqual(@as(usize, 0), collector.getPipRequirements().len);
    try std.testing.expect(!collector.hasAnyRequirements());
}
