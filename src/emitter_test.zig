const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const emitter = @import("emitter.zig");

// ============================================================================
// VISITOR-BASED EMITTER TESTS
// These tests define what the new visitor-based emitter should do
// ============================================================================

test "emit simple event with one branch" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    // Create a simple event: ~event hello {} | done {}
    var fields = [_]ast.Field{};
    var done_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &fields };
    const done_shape = ast.Shape{ .fields = &done_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = done_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"hello"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    // Emit the event
    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Verify output contains key structures
    try testing.expect(std.mem.indexOf(u8, output, "pub const hello_event = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const Input = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub const Output = union(enum) {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "done: struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "pub fn handler(__koru_event_input: Input) Output {") != null);
}

test "emit event with fields" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    // Create: ~event add { a: i32, b: i32 } | sum { result: i32 }
    var input_fields = [_]ast.Field{
        .{ .name = "a", .type = "i32", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
        .{ .name = "b", .type = "i32", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var output_fields = [_]ast.Field{
        .{ .name = "result", .type = "i32", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "sum", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"add"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Verify input fields
    try testing.expect(std.mem.indexOf(u8, output, "a: i32") != null);
    try testing.expect(std.mem.indexOf(u8, output, "b: i32") != null);
    // Verify output fields
    try testing.expect(std.mem.indexOf(u8, output, "result: i32") != null);
}

test "skip events with [compiler] annotation" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    // Create: ~[compiler]event compiler.emit.zig { ast: ProgramAST } | emitted { code: []const u8 }
    var input_fields = [_]ast.Field{
        .{ .name = "ast", .type = "ProgramAST", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var output_fields = [_]ast.Field{
        .{ .name = "code", .type = "[]const u8", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "emitted", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{ "compiler", "emit", "zig" }) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{"compiler"}), // <-- KEY: has [compiler] annotation
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    // This should be skipped because it has [compiler] annotation
    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Output should be empty (event was skipped)
    try testing.expectEqual(@as(usize, 0), output.len);
}

test "user event named 'compiler.foo' WITHOUT annotation is emitted" {
    // Users can have events named compiler.* if they want
    // Only [compiler] annotation triggers filtering
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{};
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{ "compiler", "foo" }) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}), // <-- NO [compiler] annotation
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Should be emitted (no [compiler] annotation)
    try testing.expect(output.len > 0);
    try testing.expect(std.mem.indexOf(u8, output, "compiler_foo_event") != null);
}

test "emit keyword escaping" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    // Create event with Zig keyword as branch name: | error { msg: []const u8 }
    var output_fields = [_]ast.Field{
        .{ .name = "msg", .type = "[]const u8", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var input_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "error", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"test"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // "error" should be escaped as @"error"
    try testing.expect(std.mem.indexOf(u8, output, "@\"error\": struct {") != null);
}

test "emit host lines" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    const host_line = "const std = @import(\"std\");";
    try emitter.emitHostLineWithIndent(&code_emitter, "    ", host_line);

    const output = code_emitter.getOutput();

    // Should have indentation + content
    try testing.expect(std.mem.indexOf(u8, output, "    const std = @import(\"std\");") != null);
}

test "emit file header" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    try emitter.emitFileHeader(&code_emitter);

    const output = code_emitter.getOutput();

    // Should contain the generated comment
    try testing.expect(std.mem.indexOf(u8, output, "Generated by Koru") != null);
}

test "emit main module start and end" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    try emitter.emitMainModuleStart(&code_emitter);
    try code_emitter.writeLine("    // test content");
    try emitter.emitMainModuleEnd(&code_emitter);

    const output = code_emitter.getOutput();

    try testing.expect(std.mem.indexOf(u8, output, "pub const main_module = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "};") != null);
}

test "emit multiple branches" {
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    // Create: ~event result {} | ok { value: i32 } | error { msg: []const u8 }
    var ok_fields = [_]ast.Field{
        .{ .name = "value", .type = "i32", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var error_fields = [_]ast.Field{
        .{ .name = "msg", .type = "[]const u8", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var input_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const ok_shape = ast.Shape{ .fields = &ok_fields };
    const error_shape = ast.Shape{ .fields = &error_fields };
    var branches = [_]ast.Branch{
        .{ .name = "ok", .payload = ok_shape, .is_deferred = false, .is_optional = false },
        .{ .name = "error", .payload = error_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"result"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Both branches should be present
    try testing.expect(std.mem.indexOf(u8, output, "ok: struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "@\"error\": struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "value: i32") != null);
    try testing.expect(std.mem.indexOf(u8, output, "msg: []const u8") != null);
}

// ============================================================================
// CORNER CASES FROM THE PROCEDURAL MONSTER
// ============================================================================

test "skip events with Source parameters (comptime-only)" {
    // Line 2132-2146 of compiler_bootstrap.kz: Skip comptime-only events
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{
        .{ .name = "source", .type = "Source", .is_file = false, .is_embed_file = false, .is_source = true, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"comptime_event"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Should be skipped (comptime-only event)
    try testing.expectEqual(@as(usize, 0), output.len);
}

test "skip events with ProgramAST parameters" {
    // Another comptime-only marker
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{
        .{ .name = "program", .type = "ProgramAST", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"comptime_event"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Should be skipped
    try testing.expectEqual(@as(usize, 0), output.len);
}

test "skip events with Program parameters" {
    // Yet another comptime-only marker
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{
        .{ .name = "source", .type = "Program", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"comptime_event"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Should be skipped
    try testing.expectEqual(@as(usize, 0), output.len);
}

test "event name becomes snake_case with _event suffix" {
    // Convention: ~event hello becomes hello_event
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{};
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"hello"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Should be named hello_event
    try testing.expect(std.mem.indexOf(u8, output, "pub const hello_event = struct {") != null);
}

test "dotted event path becomes underscore-separated" {
    // Convention: ~event math.add becomes math_add_event
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{};
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{ "math", "add" }) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Should be named math_add_event
    try testing.expect(std.mem.indexOf(u8, output, "pub const math_add_event = struct {") != null);
}

test "empty branch payload generates empty struct" {
    // Branch with no fields: | done {}
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{};
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"test"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Empty struct should still be generated
    try testing.expect(std.mem.indexOf(u8, output, "done: struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "},") != null);
}

test "handler always takes __koru_event_input parameter" {
    // Convention from line ~2150 of compiler_bootstrap
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{};
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"test"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Handler signature must use __koru_event_input
    try testing.expect(std.mem.indexOf(u8, output, "pub fn handler(__koru_event_input: Input) Output {") != null);
}

test "keyword escaping in field names" {
    // If a field name is a Zig keyword, it must be escaped
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{
        .{ .name = "type", .type = "i32", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
        .{ .name = "return", .type = "bool", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"test"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Keywords should be escaped in field declarations
    try testing.expect(std.mem.indexOf(u8, output, "@\"type\": i32") != null);
    try testing.expect(std.mem.indexOf(u8, output, "@\"return\": bool") != null);
}

test "dot-identifier keyword escaping in proc bodies" {
    // Lines 233-282: .return becomes .@"return", .error becomes .@"error"
    // This is for patterns like: return .{ .error = .{ .msg = "fail" } }
    // Should become: return .{ .@"error" = .{ .msg = "fail" } }

    // TODO: This requires testing proc body emission, which is complex
    // For now, document that this corner case exists
    return error.SkipZigTest;
}

test "all 36 Zig keywords are recognized for escaping" {
    // Line 187-196: Complete list of Zig keywords
    const keywords = [_][]const u8{
        "align", "allowzero", "and", "anyframe", "anytype", "asm",
        "async", "await", "break", "callconv", "catch", "comptime",
        "const", "continue", "defer", "else", "enum", "errdefer",
        "error", "export", "extern", "fn", "for", "if", "inline",
        "noalias", "noinline", "nosuspend", "opaque", "or", "orelse",
        "packed", "pub", "resume", "return", "linksection", "struct",
        "suspend", "switch", "test", "threadlocal", "try", "union",
        "unreachable", "usingnamespace", "var", "volatile", "while",
    };

    // Test each keyword as a branch name
    for (keywords) |keyword| {
        var buffer: [4096]u8 = undefined;
        var code_emitter = emitter.CodeEmitter.init(&buffer);

        var input_fields = [_]ast.Field{};
        var output_fields = [_]ast.Field{};
        const input_shape = ast.Shape{ .fields = &input_fields };
        const output_shape = ast.Shape{ .fields = &output_fields };
        var branches = [_]ast.Branch{
            .{ .name = keyword, .payload = output_shape, .is_deferred = false, .is_optional = false },
        };

        const event = ast.EventDecl{
            .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"test"}) },
            .input = input_shape,
            .branches = &branches,
            .is_public = true,
            .is_implicit_flow = false,
            .annotations = @constCast(&[_][]const u8{}),
            .location = .{ .line = 1, .column = 0, .file = "test.kz" },
            .module = "test",
        };

        try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

        const output = code_emitter.getOutput();

        // Each keyword should be escaped
        var expected_buf: [256]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "@\"{s}\": struct {{", .{keyword});
        try testing.expect(std.mem.indexOf(u8, output, expected) != null);
    }
}

test "non-keywords are not escaped" {
    // Normal identifiers should NOT have @ escaping
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    var input_fields = [_]ast.Field{};
    var output_fields = [_]ast.Field{};
    const input_shape = ast.Shape{ .fields = &input_fields };
    const output_shape = ast.Shape{ .fields = &output_fields };
    var branches = [_]ast.Branch{
        .{ .name = "success", .payload = output_shape, .is_deferred = false, .is_optional = false },
        .{ .name = "failure", .payload = output_shape, .is_deferred = false, .is_optional = false },
    };

    const event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"test"}) },
        .input = input_shape,
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "test.kz" },
        .module = "test",
    };

    try emitter.emitEventDeclInMainModule(&code_emitter, &event, &[_]ast.Item{});

    const output = code_emitter.getOutput();

    // Non-keywords should NOT be escaped
    try testing.expect(std.mem.indexOf(u8, output, "success: struct {") != null);
    try testing.expect(std.mem.indexOf(u8, output, "failure: struct {") != null);
    // Should NOT contain @ escaping
    try testing.expect(std.mem.indexOf(u8, output, "@\"success\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "@\"failure\"") == null);
}

test "module items are skipped from compiler_bootstrap module" {
    // Key filtering rule: Items with .module = "/path/to/compiler_bootstrap" should be skipped
    // This is how we avoid emitting compiler infrastructure

    // TODO: This requires visitor-level testing (filtering by module path)
    return error.SkipZigTest;
}

test "host lines are emitted with proper indentation" {
    // Host lines inside main_module get 4-space indent
    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    try emitter.emitHostLineWithIndent(&code_emitter, "    ", "const x = 42;");

    const output = code_emitter.getOutput();

    try testing.expect(std.mem.indexOf(u8, output, "    const x = 42;\n") != null);
}

test "transition type generation for taps" {
    // Lines 1567-1583: Generate Transition and Transition_profiling types
    // When event taps use transition bindings

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    try emitter.emitTransitionType(&code_emitter);

    const output = code_emitter.getOutput();

    // Should generate Transition type
    try testing.expect(std.mem.indexOf(u8, output, "const Transition = struct {") != null);
}

test "profiling transition type generation" {
    // Transition_profiling variant for taps with [profiling] annotation

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    try emitter.emitTransitionProfilingType(&code_emitter);

    const output = code_emitter.getOutput();

    // Should generate Transition_profiling type
    try testing.expect(std.mem.indexOf(u8, output, "const Transition_profiling = struct {") != null);
}

test "tap registry placeholder" {
    // Lines 2158-2162: Generate tap registry placeholder

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter.CodeEmitter.init(&buffer);

    try emitter.emitTapRegistryPlaceholder(&code_emitter);

    const output = code_emitter.getOutput();

    // Should generate TapRegistry struct
    try testing.expect(std.mem.indexOf(u8, output, "const TapRegistry = struct {") != null);
}

// TODO: Still need tests for:
// - Flow emission (emitFlowInMainModule) - complex, multiple continuation chains
// - Module declarations (nested, dotted names)
// - Inline flow helper functions
// - Host type declarations
// - Main function generation
// - Complete program orchestration (visitor level)
