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

/// Parse a JSON field value from a source string.
/// Looks for "field": "value" and returns the value.
fn parseJsonField(source: []const u8, field: []const u8) []const u8 {
    var search_buf: [64]u8 = undefined;
    const search_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return "";

    if (std.mem.indexOf(u8, source, search_pattern)) |start| {
        const after_key = source[start + search_pattern.len ..];
        var i: usize = 0;
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == '\t' or after_key[i] == '\n')) : (i += 1) {}
        if (i >= after_key.len or after_key[i] != '"') return "";
        i += 1;
        const value_start = i;
        while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
        return after_key[value_start..i];
    }
    return "";
}

/// Emit build.zig.zon for Zig package manager dependencies
/// Takes Source parameters (JSON) like:
///   { "name": "vaxis", "url": "git+https://...", "hash": "vaxis-0.5.1-..." }
/// Generates:
///   .{
///       .name = .project_name,
///       .version = "0.0.0",
///       .dependencies = .{
///           .vaxis = .{
///               .url = "git+https://...",
///               .hash = "vaxis-0.5.1-...",
///           },
///       },
///       .paths = .{""},
///   }
pub fn emitBuildZigZon(
    allocator: std.mem.Allocator,
    zig_requirements: []const []const u8,
    output_path: []const u8,
    project_name: []const u8,
) !void {
    var content = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer content.deinit(allocator);

    const writer = content.writer(allocator);

    try writer.writeAll(".{\n");

    // Zig 0.15+ requires .name as an enum literal, not a string
    // Use @"..." syntax if name contains non-identifier characters (hyphens, etc.)
    const needs_at_quote = blk: {
        for (project_name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') break :blk true;
        }
        break :blk false;
    };
    if (needs_at_quote) {
        try writer.print("    .name = .@\"{s}\",\n", .{project_name});
    } else {
        try writer.print("    .name = .{s},\n", .{project_name});
    }

    try writer.writeAll("    .version = \"0.0.0\",\n");

    // Zig 0.15 requires a .fingerprint for package identity.
    // We emit a placeholder that main.zig will fix up by running zig build once
    // to get the correct value from the error message.
    try writer.writeAll("    .fingerprint = 0xDEAD,\n");

    try writer.writeAll("    .dependencies = .{\n");

    for (zig_requirements) |req| {
        const trimmed = std.mem.trim(u8, req, " \t\r\n");
        const name = parseJsonField(trimmed, "name");
        const url = parseJsonField(trimmed, "url");
        const hash = parseJsonField(trimmed, "hash");

        if (name.len == 0 or url.len == 0 or hash.len == 0) continue;

        try writer.print("        .{s} = .{{\n", .{name});
        try writer.print("            .url = \"{s}\",\n", .{url});
        try writer.print("            .hash = \"{s}\",\n", .{hash});
        try writer.writeAll("        },\n");
    }

    try writer.writeAll("    },\n");
    try writer.writeAll("    .paths = .{\"\"},\n");
    try writer.writeAll("}\n");

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

test "emit build.zig.zon with single dependency" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        \\{ "name": "vaxis", "url": "git+https://github.com/rockorager/libvaxis.git#abc123", "hash": "vaxis-0.5.1-HASH" }
    };

    const output_path = "test_build.zig.zon";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitBuildZigZon(allocator, &requirements, output_path, "hello_vaxis");

    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .hello_vaxis,") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".fingerprint = 0x") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".vaxis = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "git+https://github.com/rockorager/libvaxis.git#abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "vaxis-0.5.1-HASH") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".paths = .{\"\"}")  != null);
}

test "emit build.zig.zon with multiple dependencies" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        \\{ "name": "vaxis", "url": "git+https://example.com/vaxis#abc", "hash": "hash1" }
        ,
        \\{ "name": "zap", "url": "git+https://example.com/zap#def", "hash": "hash2" }
    };

    const output_path = "test_build_multi.zig.zon";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    try emitBuildZigZon(allocator, &requirements, output_path, "myproject");

    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".vaxis = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".zap = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .myproject,") != null);
}

test "parseJsonField extracts values" {
    const source =
        \\{ "name": "vaxis", "url": "git+https://example.com", "hash": "abc123" }
    ;
    try std.testing.expectEqualStrings("vaxis", parseJsonField(source, "name"));
    try std.testing.expectEqualStrings("git+https://example.com", parseJsonField(source, "url"));
    try std.testing.expectEqualStrings("abc123", parseJsonField(source, "hash"));
    try std.testing.expectEqualStrings("", parseJsonField(source, "nonexistent"));
}
