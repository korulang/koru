const std = @import("std");

pub const ProjectType = enum {
    exe,
    lib,
};

pub fn createProject(
    allocator: std.mem.Allocator,
    project_type: ProjectType,
    name: []const u8,
    parent_dir: ?[]const u8,
) !void {
    // 1. Validate name
    if (!isValidProjectName(name)) {
        return error.InvalidProjectName;
    }

    // 2. Create directory structure
    const project_root = if (parent_dir) |p|
        try std.fs.path.join(allocator, &.{ p, name })
    else
        name;
    defer if (parent_dir != null) allocator.free(project_root);

    try std.fs.cwd().makeDir(project_root);
    errdefer std.fs.cwd().deleteTree(project_root) catch {};

    // 3. Create subdirs
    const src_dir = try std.fs.path.join(allocator, &.{ project_root, "src" });
    defer allocator.free(src_dir);
    try std.fs.cwd().makeDir(src_dir);

    if (project_type == .exe) {
        const lib_dir = try std.fs.path.join(allocator, &.{ project_root, "lib" });
        defer allocator.free(lib_dir);
        try std.fs.cwd().makeDir(lib_dir);
    } else {
        const tests_dir = try std.fs.path.join(allocator, &.{ project_root, "tests" });
        defer allocator.free(tests_dir);
        try std.fs.cwd().makeDir(tests_dir);
    }

    // 4. Write files
    try writeKoruJson(allocator, project_root, project_type, name);
    try writeGitignore(allocator, project_root);
    try writeReadme(allocator, project_root, project_type, name);
    try writeMainFile(allocator, project_root, project_type, name);

    // 5. Success message
    std.debug.print("Created {s} in ./{s}\n\n", .{ name, name });
    std.debug.print("Get started:\n", .{});
    std.debug.print("  cd {s}\n", .{name});
    std.debug.print("  koruc src/main.kz\n", .{});
    if (project_type == .exe) {
        std.debug.print("  ./a.out\n", .{});
    }
}

fn isValidProjectName(name: []const u8) bool {
    if (name.len == 0) return false;

    // Must start with letter or underscore
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;

    // Only alphanumeric, dash, underscore
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            return false;
        }
    }

    return true;
}

fn writeKoruJson(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    project_type: ProjectType,
    name: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ project_root, "koru.json" });
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    if (project_type == .exe) {
        const content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "0.1.0",
            \\  "description": "A Koru application",
            \\  "paths": {{
            \\    "src": "src",
            \\    "lib": "lib"
            \\  }}
            \\}}
            \\
        , .{name});
        defer allocator.free(content);
        try file.writeAll(content);
    } else {
        const content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "0.1.0",
            \\  "description": "A Koru library",
            \\  "license": "MIT",
            \\  "paths": {{
            \\    "src": "src",
            \\    "lib": "lib",
            \\    "tests": "tests"
            \\  }}
            \\}}
            \\
        , .{name});
        defer allocator.free(content);
        try file.writeAll(content);
    }
}

fn writeGitignore(allocator: std.mem.Allocator, project_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ project_root, ".gitignore" });
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    try file.writeAll(
        \\# Koru build artifacts
        \\*.zig.generated
        \\backend.zig
        \\output_emitted.zig
        \\/zig-cache/
        \\/zig-out/
        \\*.o
        \\*.a
        \\a.out
        \\
        \\# Test artifacts
        \\/tests/**/*.err
        \\/tests/**/backend.zig
        \\/tests/**/output_emitted.zig
        \\
        \\# OS files
        \\.DS_Store
        \\Thumbs.db
        \\
        \\# IDE
        \\.vscode/
        \\.idea/
        \\*.swp
        \\*.swo
        \\*~
        \\
        \\# Environment
        \\.env
        \\.env.local
        \\
    );
}

fn writeReadme(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    project_type: ProjectType,
    name: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ project_root, "README.md" });
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    if (project_type == .exe) {
        const content = try std.fmt.allocPrint(allocator,
            \\# {s}
            \\
            \\A Koru application.
            \\
            \\## Getting Started
            \\
            \\### Build and Run
            \\
            \\```bash
            \\koruc src/main.kz
            \\./a.out
            \\```
            \\
            \\### Development
            \\
            \\- Source code: `src/main.kz`
            \\- Your modules: `lib/`
            \\
            \\### Project Structure
            \\
            \\```
            \\{s}/
            \\├── koru.json         # Project configuration
            \\├── src/
            \\│   └── main.kz       # Entry point
            \\└── lib/              # Your modules
            \\```
            \\
            \\## Learn More
            \\
            \\- [Koru Language Specification](https://github.com/koru-lang/koru/blob/main/SPEC.md)
            \\
        , .{ name, name });
        defer allocator.free(content);
        try file.writeAll(content);
    } else {
        const content = try std.fmt.allocPrint(allocator,
            \\# {s}
            \\
            \\A Koru library.
            \\
            \\## Usage
            \\
            \\Import in your code:
            \\
            \\```koru
            \\~import "$lib/{s}"
            \\
            \\~{s}:greet(name: "World")
            \\| done |> _
            \\```
            \\
            \\## Development
            \\
            \\### Build
            \\
            \\```bash
            \\koruc src/lib.kz
            \\```
            \\
            \\### Project Structure
            \\
            \\```
            \\{s}/
            \\├── koru.json         # Project configuration
            \\├── src/
            \\│   └── lib.kz        # Public API
            \\└── tests/            # Tests
            \\```
            \\
            \\## API
            \\
            \\See [src/lib.kz](src/lib.kz) for the public API.
            \\
        , .{ name, name, name, name });
        defer allocator.free(content);
        try file.writeAll(content);
    }
}

fn writeMainFile(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    project_type: ProjectType,
    name: []const u8,
) !void {
    if (project_type == .exe) {
        const path = try std.fs.path.join(allocator, &.{ project_root, "src", "main.kz" });
        defer allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const content = try std.fmt.allocPrint(allocator,
            \\// {s}
            \\~import "$std/io"
            \\
            \\~std.io:print.ln("Hello from {s}!")
            \\
        , .{ name, name });
        defer allocator.free(content);
        try file.writeAll(content);
    } else {
        const path = try std.fs.path.join(allocator, &.{ project_root, "src", "lib.kz" });
        defer allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const content = try std.fmt.allocPrint(allocator,
            \\// {s} - Library entry point
            \\//
            \\// This file defines the public API of your library.
            \\// Mark events with ~pub to export them.
            \\
            \\~import "$std/io"
            \\
            \\// Example public event - void events just do their work
            \\~pub event greet {{ name: []const u8 }}
            \\
            \\~proc greet =
            \\    std.io:print.ln("Hello, ${{name}}")
            \\
        , .{name});
        defer allocator.free(content);
        try file.writeAll(content);
    }
}
