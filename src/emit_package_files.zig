const std = @import("std");

/// Emit package.json for npm dependencies
/// Takes Source parameters like:
///   "@koru/graphics": "^1.0.0"
///   "lodash": "^4.17.21"
/// Generates:
///   {
///     "dependencies": {
///       "@koru/graphics": "^1.0.0",
///       "lodash": "^4.17.21"
///     }
///   }
pub fn emitPackageJson(
    allocator: std.mem.Allocator,
    npm_requirements: []const []const u8,
    output_path: []const u8,
) !void {
    var content = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer content.deinit(allocator);

    const writer = content.writer(allocator);

    try writer.writeAll("{\n");
    try writer.writeAll("  \"dependencies\": {\n");

    for (npm_requirements, 0..) |req, i| {
        // Trim whitespace from Source parameter content
        const trimmed = std.mem.trim(u8, req, " \t\r\n");
        try writer.writeAll("    ");
        try writer.writeAll(trimmed);

        // Add comma immediately after content (not on new line)
        if (i < npm_requirements.len - 1) {
            try writer.writeAll(",");
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(content.items);
}

/// Emit Cargo.toml for Rust dependencies
/// Takes Source parameters like:
///   serde = "1.0"
///   tokio = { version = "1.0", features = ["full"] }
/// Generates:
///   [dependencies]
///   serde = "1.0"
///   tokio = { version = "1.0", features = ["full"] }
pub fn emitCargoToml(
    allocator: std.mem.Allocator,
    cargo_requirements: []const []const u8,
    output_path: []const u8,
) !void {
    var content = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer content.deinit(allocator);

    const writer = content.writer(allocator);

    try writer.writeAll("[dependencies]\n");

    for (cargo_requirements) |req| {
        const trimmed = std.mem.trim(u8, req, " \t\r\n");
        try writer.writeAll(trimmed);
        try writer.writeAll("\n");
    }

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(content.items);
}

/// Emit go.mod for Go module dependencies
/// Takes Source parameters like:
///   github.com/gin-gonic/gin v1.9.1
///   golang.org/x/crypto v0.14.0
/// Generates:
///   module main
///
///   go 1.21
///
///   require (
///       github.com/gin-gonic/gin v1.9.1
///       golang.org/x/crypto v0.14.0
///   )
pub fn emitGoMod(
    allocator: std.mem.Allocator,
    go_requirements: []const []const u8,
    output_path: []const u8,
) !void {
    var content = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer content.deinit(allocator);

    const writer = content.writer(allocator);

    try writer.writeAll("module main\n\n");
    try writer.writeAll("go 1.21\n\n");
    try writer.writeAll("require (\n");

    for (go_requirements) |req| {
        const trimmed = std.mem.trim(u8, req, " \t\r\n");
        try writer.writeAll("    ");
        try writer.writeAll(trimmed);
        try writer.writeAll("\n");
    }

    try writer.writeAll(")\n");

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(content.items);
}

/// Emit requirements.txt for Python pip dependencies
/// Takes Source parameters like:
///   flask==2.3.0
///   requests>=2.31.0
/// Generates:
///   flask==2.3.0
///   requests>=2.31.0
pub fn emitRequirementsTxt(
    allocator: std.mem.Allocator,
    pip_requirements: []const []const u8,
    output_path: []const u8,
) !void {
    var content = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer content.deinit(allocator);

    const writer = content.writer(allocator);

    for (pip_requirements) |req| {
        const trimmed = std.mem.trim(u8, req, " \t\r\n");
        try writer.writeAll(trimmed);
        try writer.writeAll("\n");
    }

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(content.items);
}

// Tests
test "emit package.json with single dependency" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        "\"lodash\": \"^4.17.21\"",
    };

    const output_path = "test_package.json";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitPackageJson(allocator, &requirements, output_path);

    // Read back and verify
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "\"dependencies\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"lodash\": \"^4.17.21\"") != null);
}

test "emit package.json with multiple dependencies" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        "\"@koru/graphics\": \"^1.0.0\"",
        "\"lodash\": \"^4.17.21\"",
        "\"axios\": \"^1.6.0\"",
    };

    const output_path = "test_package_multi.json";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitPackageJson(allocator, &requirements, output_path);

    // Read back and verify
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "@koru/graphics") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "lodash") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "axios") != null);
}

test "emit Cargo.toml with dependencies" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        "serde = \"1.0\"",
        "tokio = { version = \"1.0\", features = [\"full\"] }",
    };

    const output_path = "test_Cargo.toml";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitCargoToml(allocator, &requirements, output_path);

    // Read back and verify
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "[dependencies]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "serde = \"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "tokio") != null);
}

test "emit go.mod with dependencies" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        "github.com/gin-gonic/gin v1.9.1",
        "golang.org/x/crypto v0.14.0",
    };

    const output_path = "test_go.mod";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitGoMod(allocator, &requirements, output_path);

    // Read back and verify
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "module main") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "require (") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "github.com/gin-gonic/gin") != null);
}

test "emit requirements.txt with dependencies" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        "flask==2.3.0",
        "requests>=2.31.0",
    };

    const output_path = "test_requirements.txt";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitRequirementsTxt(allocator, &requirements, output_path);

    // Read back and verify
    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "flask==2.3.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "requests>=2.31.0") != null);
}
