// GLSL Compiler Pass - Completely isolated from main compiler
// This module transforms procs with .target = "glsl" into Vulkan wrapper code
//
// Architecture:
// - Called ONLY when proc.target == "glsl"
// - Compiles GLSL → SPIR-V at compile time
// - Generates Zig wrapper code that uses gpu_runtime
// - Returns transformed Zig code as string
// - Zero impact on main compiler pipeline

const std = @import("std");

pub const GLSLCompileError = error{
    GLSLSyntaxError,
    GLSLCompilationFailed,
    BindingParseFailed,
    NoMatchingField,
    TypeMismatch,
    OutOfMemory,
};

pub const Binding = struct {
    index: u32,
    name: []const u8,
    binding_type: BindingType,
};

pub const BindingType = enum {
    storage_buffer,
    uniform_buffer,
    push_constant,
};

/// Main entry point: Transform a GLSL proc into Zig wrapper code
pub fn compileGLSLProc(
    allocator: std.mem.Allocator,
    proc_body: []const u8,
    event_name: []const []const u8, // Dotted path
    event_input_shape: anytype, // EventDecl.Shape
) ![]const u8 {
    // Step 1: Extract GLSL source from proc body
    const glsl_source = try extractGLSLSource(allocator, proc_body);
    defer allocator.free(glsl_source);

    // Step 2: Compile GLSL to SPIR-V
    const spv_path = try compileGLSLToSPIRV(allocator, glsl_source, event_name);
    defer allocator.free(spv_path);

    // Step 3: Parse GLSL bindings
    const bindings = try parseGLSLBindings(allocator, glsl_source);
    defer {
        for (bindings) |binding| {
            allocator.free(binding.name);
        }
        allocator.free(bindings);
    }

    // Step 4: Match bindings to event fields
    try validateBindings(bindings, event_input_shape);

    // Step 5: Parse local_size_x from GLSL (default 256)
    const local_size_x = try parseLocalSizeX(glsl_source);

    // Step 6: Generate Vulkan wrapper code
    const wrapper_code = try generateVulkanWrapper(
        allocator,
        event_name,
        spv_path,
        bindings,
        event_input_shape,
        local_size_x,
    );

    return wrapper_code;
}

/// Extract GLSL source from proc body (remove comments, trim whitespace)
fn extractGLSLSource(allocator: std.mem.Allocator, proc_body: []const u8) ![]const u8 {
    // For now, just return trimmed body
    // TODO: Strip Zig-style comments if any
    const trimmed = std.mem.trim(u8, proc_body, &std.ascii.whitespace);
    return try allocator.dupe(u8, trimmed);
}

/// Compile GLSL to SPIR-V using glslangValidator
fn compileGLSLToSPIRV(
    allocator: std.mem.Allocator,
    glsl_source: []const u8,
    event_name: []const []const u8,
) ![]const u8 {
    // Generate file names
    const name_joined = try joinPath(allocator, event_name, "_");
    defer allocator.free(name_joined);

    var glsl_path_buf: [256]u8 = undefined;
    const glsl_path = try std.fmt.bufPrint(&glsl_path_buf, "/tmp/{s}.comp", .{name_joined});

    var spv_path_buf: [256]u8 = undefined;
    const spv_path = try std.fmt.bufPrint(&spv_path_buf, "/tmp/{s}.spv", .{name_joined});

    // Write GLSL to temp file
    const glsl_file = try std.fs.createFileAbsolute(glsl_path, .{});
    defer glsl_file.close();
    try glsl_file.writeAll(glsl_source);

    // Compile with glslangValidator
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "glslangValidator",
            "-V",
            glsl_path,
            "-o",
            spv_path,
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("GLSL compilation failed:\n{s}\n", .{result.stderr});
        return error.GLSLCompilationFailed;
    }

    return try allocator.dupe(u8, spv_path);
}

/// Parse GLSL bindings from layout declarations
fn parseGLSLBindings(allocator: std.mem.Allocator, glsl_source: []const u8) ![]Binding {
    var bindings = std.ArrayList(Binding).init(allocator);
    errdefer bindings.deinit();

    // Simple regex-style parsing: layout(binding = N) buffer Name { ... } name;
    var i: usize = 0;
    while (i < glsl_source.len) {
        // Look for "layout(binding"
        if (std.mem.indexOf(u8, glsl_source[i..], "layout(binding")) |offset| {
            i += offset;

            // Extract binding index
            if (std.mem.indexOf(u8, glsl_source[i..], "=")) |eq_offset| {
                i += eq_offset + 1;
                // Skip whitespace
                while (i < glsl_source.len and std.ascii.isWhitespace(glsl_source[i])) i += 1;

                // Parse number
                var binding_index: u32 = 0;
                while (i < glsl_source.len and std.ascii.isDigit(glsl_source[i])) {
                    binding_index = binding_index * 10 + (glsl_source[i] - '0');
                    i += 1;
                }

                // Look for "buffer" keyword
                if (std.mem.indexOf(u8, glsl_source[i..], "buffer")) |buf_offset| {
                    i += buf_offset + 6; // Skip "buffer"

                    // Skip whitespace and struct name
                    while (i < glsl_source.len and std.ascii.isWhitespace(glsl_source[i])) i += 1;
                    // Skip struct name (until {)
                    while (i < glsl_source.len and glsl_source[i] != '{') i += 1;
                    // Skip to closing }
                    var depth: u32 = 0;
                    while (i < glsl_source.len) {
                        if (glsl_source[i] == '{') depth += 1;
                        if (glsl_source[i] == '}') {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                        i += 1;
                    }
                    i += 1; // Skip closing }

                    // Now extract the variable name
                    while (i < glsl_source.len and std.ascii.isWhitespace(glsl_source[i])) i += 1;

                    const name_start = i;
                    while (i < glsl_source.len and (std.ascii.isAlphanumeric(glsl_source[i]) or glsl_source[i] == '_')) {
                        i += 1;
                    }
                    const name_end = i;

                    if (name_end > name_start) {
                        const name = try allocator.dupe(u8, glsl_source[name_start..name_end]);
                        try bindings.append(.{
                            .index = binding_index,
                            .name = name,
                            .binding_type = .storage_buffer,
                        });
                    }
                }
            }
        } else {
            break;
        }
    }

    return bindings.toOwnedSlice();
}

/// Validate that all GLSL bindings have matching event fields
fn validateBindings(bindings: []const Binding, event_shape: anytype) !void {
    for (bindings) |binding| {
        var found = false;
        for (event_shape.fields) |field| {
            if (std.mem.eql(u8, binding.name, field.name)) {
                found = true;
                // TODO: Validate type compatibility ([]T -> storage buffer)
                break;
            }
        }
        if (!found) {
            std.debug.print("ERROR: GLSL binding '{s}' has no matching event field\n", .{binding.name});
            return error.NoMatchingField;
        }
    }
}

/// Parse local_size_x from GLSL
fn parseLocalSizeX(glsl_source: []const u8) !u32 {
    if (std.mem.indexOf(u8, glsl_source, "local_size_x")) |offset| {
        var i = offset + 12; // Skip "local_size_x"
        // Skip to '='
        while (i < glsl_source.len and glsl_source[i] != '=') i += 1;
        i += 1; // Skip '='
        // Skip whitespace
        while (i < glsl_source.len and std.ascii.isWhitespace(glsl_source[i])) i += 1;
        // Parse number
        var result: u32 = 0;
        while (i < glsl_source.len and std.ascii.isDigit(glsl_source[i])) {
            result = result * 10 + (glsl_source[i] - '0');
            i += 1;
        }
        return result;
    }
    return 256; // Default
}

/// Generate Vulkan wrapper code
fn generateVulkanWrapper(
    allocator: std.mem.Allocator,
    event_name: []const []const u8,
    spv_path: []const u8,
    bindings: []const Binding,
    event_shape: anytype,
    local_size_x: u32,
) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    // Write comment
    try writer.print("// GPU implementation (GLSL) - generated by glsl_compiler.zig\n", .{});
    try writer.print("// SPIR-V: {s}\n\n", .{spv_path});

    // Embed SPIR-V
    try writer.print("const spv_code = @embedFile(\"{s}\");\n\n", .{spv_path});

    // Get GPU runtime
    try writer.writeAll("const gpu = @import(\"gpu_runtime\"); // TODO: Proper import path\n\n");

    // Create buffers for each binding
    for (bindings) |binding| {
        // Find field type
        var field_type: []const u8 = "[]f32"; // Default
        for (event_shape.fields) |field| {
            if (std.mem.eql(u8, binding.name, field.name)) {
                field_type = field.field_type;
                break;
            }
        }

        try writer.print("var buffer_{s} = try gpu.createBuffer(", .{binding.name});
        // Extract element type from []T
        if (std.mem.startsWith(u8, field_type, "[]")) {
            const elem_type = field_type[2..];
            try writer.print("{s}, e.{s}", .{ elem_type, binding.name });
        } else {
            try writer.print("{s}, &[_]{s}{{e.{s}}}", .{ field_type, field_type, binding.name });
        }
        try writer.writeAll(");\n");
        try writer.print("defer buffer_{s}.destroy();\n\n", .{binding.name});
    }

    // Create pipeline
    try writer.print("var pipeline = try gpu.createComputePipeline(spv_code, {});\n", .{bindings.len});
    try writer.writeAll("defer pipeline.destroy();\n\n");

    // Bind buffers
    for (bindings) |binding| {
        try writer.print("try gpu.bindBuffer(&pipeline, {}, &buffer_{s});\n", .{ binding.index, binding.name });
    }
    try writer.writeAll("\n");

    // Dispatch
    // Find first buffer field to calculate workgroups
    var first_buffer_field: ?[]const u8 = null;
    for (bindings) |binding| {
        if (first_buffer_field == null) {
            first_buffer_field = binding.name;
            break;
        }
    }

    if (first_buffer_field) |field| {
        try writer.print("const local_size_x = {};\n", .{local_size_x});
        try writer.print("const workgroups = (e.{s}.len + local_size_x - 1) / local_size_x;\n", .{field});
        try writer.writeAll("try gpu.dispatch(&pipeline, @intCast(workgroups), 1, 1);\n\n");
    } else {
        try writer.writeAll("try gpu.dispatch(&pipeline, 1, 1, 1);\n\n");
    }

    // Read back buffers
    for (bindings) |binding| {
        // Find field type
        var field_type: []const u8 = "[]f32";
        for (event_shape.fields) |field| {
            if (std.mem.eql(u8, binding.name, field.name)) {
                field_type = field.field_type;
                break;
            }
        }

        if (std.mem.startsWith(u8, field_type, "[]")) {
            const elem_type = field_type[2..];
            try writer.print("try gpu.readBuffer({s}, &buffer_{s}, e.{s});\n", .{ elem_type, binding.name, binding.name });
        }
    }
    try writer.writeAll("\n");

    // Return done branch (TODO: Parse actual branches from event)
    try writer.writeAll("return .{ .done = .{} };\n");

    return buffer.toOwnedSlice();
}

/// Helper: Join dotted path with separator
fn joinPath(allocator: std.mem.Allocator, path: []const []const u8, sep: []const u8) ![]const u8 {
    if (path.len == 0) return try allocator.dupe(u8, "");
    if (path.len == 1) return try allocator.dupe(u8, path[0]);

    var total_len: usize = path[0].len;
    for (path[1..]) |seg| {
        total_len += sep.len + seg.len;
    }

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    @memcpy(result[pos..pos + path[0].len], path[0]);
    pos += path[0].len;

    for (path[1..]) |seg| {
        @memcpy(result[pos..pos + sep.len], sep);
        pos += sep.len;
        @memcpy(result[pos..pos + seg.len], seg);
        pos += seg.len;
    }

    return result;
}
