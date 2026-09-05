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

/// Resolve the package name for an emitted build.zig.zon.
/// The zon lives in the output directory and is shared by every entry point
/// built there, so the name must be stable per DIRECTORY, not per input file:
/// compiling `live.k` then `headed.k` in one directory must not flip `.name`
/// (zig folds the name into `.fingerprint`, so a flip rewrites the fingerprint
/// and dirties the tree on every build — hole 5).
/// `cwd_basename` is the basename of the process working directory, used when
/// `output_dir` is in-place ("." or empty); the input file stem is the last
/// resort when neither directory yields a name.
pub fn resolveProjectName(output_dir: []const u8, cwd_basename: []const u8, input_file: ?[]const u8) []const u8 {
    const dir_basename = std.fs.path.basename(output_dir);
    if (dir_basename.len > 0 and !std.mem.eql(u8, dir_basename, ".")) return dir_basename;
    if (cwd_basename.len > 0 and !std.mem.eql(u8, cwd_basename, ".") and !std.mem.eql(u8, cwd_basename, "/")) return cwd_basename;
    return std.fs.path.stem(std.fs.path.basename(input_file orelse "koru_app"));
}

/// Extract the `.fingerprint = 0x...` value from an existing build.zig.zon.
/// Returns null when absent, malformed, or the 0xDEAD placeholder (which means
/// "never resolved", not a fingerprint). The caller re-emits a kept fingerprint
/// and lets zig's probe reject it if it went stale, rather than minting a fresh
/// one every build — zig accepts previously-issued fingerprints, but mints a
/// nondeterministic low half on each fresh probe, so re-probing unconditionally
/// can never converge.
pub fn existingFingerprint(zon_content: []const u8) ?[]const u8 {
    const marker = ".fingerprint = 0x";
    const idx = std.mem.indexOf(u8, zon_content, marker) orelse return null;
    var end = idx + marker.len;
    while (end < zon_content.len and std.ascii.isHex(zon_content[end])) : (end += 1) {}
    if (end == idx + marker.len) return null;
    const value = zon_content[idx + ".fingerprint = ".len .. end];
    if (std.mem.eql(u8, value, "0xDEAD")) return null;
    return value;
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
/// `fingerprint` is the previously-resolved value to keep, or null to emit the
/// 0xDEAD placeholder for the probe-and-patch pass. Returns true when the file
/// was written, false when the existing content was already identical (so a
/// no-change build leaves the tree untouched).
pub fn emitBuildZigZon(
    allocator: std.mem.Allocator,
    zig_requirements: []const []const u8,
    output_path: []const u8,
    project_name: []const u8,
    fingerprint: ?[]const u8,
) !bool {
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
    // A kept value from the previous zon is re-emitted verbatim; the probe
    // pass rejects it if it went stale. Null means "never resolved": emit the
    // placeholder the probe-and-patch pass replaces.
    if (fingerprint) |fp| {
        try writer.print("    .fingerprint = {s},\n", .{fp});
    } else {
        try writer.writeAll("    .fingerprint = 0xDEAD,\n");
    }

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

    // A no-change build must leave the tree untouched: skip the write when the
    // existing file is already byte-identical.
    if (std.fs.cwd().openFile(output_path, .{})) |existing| {
        defer existing.close();
        const old = existing.readToEndAlloc(allocator, 1024 * 1024) catch null;
        if (old) |old_content| {
            defer allocator.free(old_content);
            if (std.mem.eql(u8, old_content, content.items)) return false;
        }
    } else |_| {}

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(content.items);
    return true;
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

    const wrote = try emitBuildZigZon(allocator, &requirements, output_path, "hello_vaxis", null);
    try std.testing.expect(wrote);

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

    const wrote = try emitBuildZigZon(allocator, &requirements, output_path, "myproject", "0x1234abcd");
    try std.testing.expect(wrote);

    const file = try std.fs.cwd().openFile(output_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".vaxis = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".zap = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".name = .myproject,") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".fingerprint = 0x1234abcd,") != null);
}

test "resolveProjectName is stable per directory, not per entry file" {
    // An explicit output directory names the package.
    try std.testing.expectEqualStrings("backend", resolveProjectName("backend", "whatever", "live.kz"));
    try std.testing.expectEqualStrings("backend", resolveProjectName("/tmp/build/backend", "whatever", null));
    // In-place builds ("." or empty) take the working directory's basename —
    // two entry files in one directory share one identity (hole 5).
    try std.testing.expectEqualStrings("headless", resolveProjectName(".", "headless", "live.kz"));
    try std.testing.expectEqualStrings("headless", resolveProjectName(".", "headless", "headed.k"));
    try std.testing.expectEqualStrings("headless", resolveProjectName("", "headless", "session.k"));
    // Only when no directory yields a name does the input stem serve.
    try std.testing.expectEqualStrings("live", resolveProjectName(".", "", "live.kz"));
    try std.testing.expectEqualStrings("koru_app", resolveProjectName(".", "", null));
}

test "existingFingerprint keeps resolved values, refuses the placeholder" {
    try std.testing.expectEqualStrings("0x9aa61d90bb082983", existingFingerprint(
        ".{\n    .name = .headless,\n    .fingerprint = 0x9aa61d90bb082983,\n}\n",
    ).?);
    try std.testing.expect(existingFingerprint(
        ".{\n    .name = .headless,\n    .fingerprint = 0xDEAD,\n}\n",
    ) == null);
    try std.testing.expect(existingFingerprint(".{\n    .name = .x,\n}\n") == null);
}

test "emit build.zig.zon skips identical rewrites" {
    const allocator = std.testing.allocator;

    const requirements = [_][]const u8{
        \\{ "name": "vaxis", "url": "git+https://example.com/vaxis#abc", "hash": "hash1" }
    };

    const output_path = "test_build_idempotent.zig.zon";
    defer std.fs.cwd().deleteFile(output_path) catch {};

    // First emit writes; second emit with identical inputs skips.
    try std.testing.expect(try emitBuildZigZon(allocator, &requirements, output_path, "stable", "0xaaaa"));
    try std.testing.expect(!try emitBuildZigZon(allocator, &requirements, output_path, "stable", "0xaaaa"));
    // A changed name or fingerprint is a real change and writes again.
    try std.testing.expect(try emitBuildZigZon(allocator, &requirements, output_path, "other", "0xaaaa"));
    try std.testing.expect(try emitBuildZigZon(allocator, &requirements, output_path, "other", "0xbbbb"));
    try std.testing.expect(!try emitBuildZigZon(allocator, &requirements, output_path, "other", "0xbbbb"));
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
