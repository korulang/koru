const std = @import("std");
const testing = std.testing;
const ast = @import("ast");
const emitter_helpers = @import("emitter_helpers");
const VisitorEmitter = @import("visitor_emitter.zig").VisitorEmitter;
const tap_registry_module = @import("tap_registry.zig");
const type_registry_module = @import("type_registry.zig");

// ============================================================================
// VISITOR-BASED ORCHESTRATION TESTS
// These test the high-level visitor that orchestrates emission
// ============================================================================

test "visitor emits only user code, not compiler infrastructure" {
    // This is the KEY test - the whole reason for this refactor
    // Given an AST with:
    // - compiler.emit.zig event (with [compiler] annotation)
    // - user's hello event (without annotation)
    //
    // Should emit ONLY the user code (hello event)
    // Should NOT emit compiler.* items

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter_helpers.CodeEmitter.init(&buffer);

    // Create compiler event with [compiler] annotation
    var compiler_input_fields = [_]ast.Field{
        .{ .name = "ast", .type = "ProgramAST", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var compiler_output_fields = [_]ast.Field{
        .{ .name = "code", .type = "[]const u8", .is_file = false, .is_embed_file = false, .is_source = false, .phantom = null, .expression = null, .expression_str = null, .owns_expression = false },
    };
    var compiler_branches = [_]ast.Branch{
        .{ .name = "emitted", .payload = .{ .fields = &compiler_output_fields }, .is_deferred = false, .is_optional = false },
    };
    const compiler_event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{ "compiler", "emit", "zig" }) },
        .input = .{ .fields = &compiler_input_fields },
        .branches = &compiler_branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{"compiler"}), // [compiler] annotation
        .location = .{ .line = 1, .column = 0, .file = "compiler_bootstrap.kz" },
        .module = "compiler_bootstrap",
    };

    // Create user event WITHOUT [compiler] annotation
    var user_fields = [_]ast.Field{};
    var user_output_fields = [_]ast.Field{};
    var user_branches = [_]ast.Branch{
        .{ .name = "done", .payload = .{ .fields = &user_output_fields }, .is_deferred = false, .is_optional = false },
    };
    const user_event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"hello"}) },
        .input = .{ .fields = &user_fields },
        .branches = &user_branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}), // NO annotation
        .location = .{ .line = 1, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    // Create AST with both events
    var items = [_]ast.Item{
        .{ .event_decl = compiler_event },
        .{ .event_decl = user_event },
    };
    const source_file = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .allocator = testing.allocator,
    };

    // Emit using visitor (with empty tap registry and type registry)
    var tap_registry = tap_registry_module.TapRegistry.init(testing.allocator);
    defer tap_registry.deinit();
    var type_registry = type_registry_module.TypeRegistry.init(testing.allocator);
    defer type_registry.deinit();
    var visitor_emitter = VisitorEmitter.init(testing.allocator, &code_emitter, &items, &tap_registry, &type_registry, .all);
    try visitor_emitter.emit(&source_file);

    const output = code_emitter.getOutput();

    // Should contain user event
    try testing.expect(std.mem.indexOf(u8, output, "hello_event") != null);

    // Should NOT contain compiler event
    try testing.expect(std.mem.indexOf(u8, output, "compiler") == null);
    try testing.expect(std.mem.indexOf(u8, output, "emit") == null or std.mem.indexOf(u8, output, "emitted") != null); // "emitted" is OK (branch name in user events)
}

test "visitor filters out host_lines from compiler_bootstrap module" {
    // Host lines like "const emitter_lib = @import(\"emitter\");"
    // that come from compiler_bootstrap.kz should be filtered out

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter_helpers.CodeEmitter.init(&buffer);

    // Create host_line from compiler_bootstrap (should be filtered)
    const compiler_host_line = ast.HostLine{
        .content = "const emitter_lib = @import(\"emitter\");",
        .location = .{ .line = 10, .column = 0, .file = "compiler_bootstrap.kz" },
        .module = "compiler_bootstrap",
    };

    // Create host_line from user code (should be preserved)
    const user_host_line = ast.HostLine{
        .content = "const std = @import(\"std\");",
        .location = .{ .line = 1, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    // Create AST with both host lines
    var items = [_]ast.Item{
        .{ .host_line = compiler_host_line },
        .{ .host_line = user_host_line },
    };
    const source_file = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .allocator = testing.allocator,
    };

    // Emit using visitor (with empty tap registry and type registry)
    var tap_registry = tap_registry_module.TapRegistry.init(testing.allocator);
    defer tap_registry.deinit();
    var type_registry = type_registry_module.TypeRegistry.init(testing.allocator);
    defer type_registry.deinit();
    var visitor_emitter = VisitorEmitter.init(testing.allocator, &code_emitter, &items, &tap_registry, &type_registry, .all);
    try visitor_emitter.emit(&source_file);

    const output = code_emitter.getOutput();

    // Should contain user host_line
    try testing.expect(std.mem.indexOf(u8, output, "const std = @import(\"std\");") != null);

    // Should NOT contain compiler_bootstrap host_line
    try testing.expect(std.mem.indexOf(u8, output, "emitter_lib") == null);
}

test "visitor preserves host_lines from user code" {
    // Host lines like "const std = @import(\"std\");"
    // from user's input.kz should be preserved

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter_helpers.CodeEmitter.init(&buffer);

    // Create multiple host_lines from user code
    const user_host_line1 = ast.HostLine{
        .content = "const std = @import(\"std\");",
        .location = .{ .line = 1, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    const user_host_line2 = ast.HostLine{
        .content = "const my_lib = @import(\"my_lib\");",
        .location = .{ .line = 2, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    // Create AST with user host lines
    var items = [_]ast.Item{
        .{ .host_line = user_host_line1 },
        .{ .host_line = user_host_line2 },
    };
    const source_file = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .allocator = testing.allocator,
    };

    // Emit using visitor (with empty tap registry and type registry)
    var tap_registry = tap_registry_module.TapRegistry.init(testing.allocator);
    defer tap_registry.deinit();
    var type_registry = type_registry_module.TypeRegistry.init(testing.allocator);
    defer type_registry.deinit();
    var visitor_emitter = VisitorEmitter.init(testing.allocator, &code_emitter, &items, &tap_registry, &type_registry, .all);
    try visitor_emitter.emit(&source_file);

    const output = code_emitter.getOutput();

    // Should contain both user host_lines
    try testing.expect(std.mem.indexOf(u8, output, "const std = @import(\"std\");") != null);
    try testing.expect(std.mem.indexOf(u8, output, "const my_lib = @import(\"my_lib\");") != null);
}

test "visitor emits events in correct order" {
    // Events should be emitted in the order they appear in user code

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter_helpers.CodeEmitter.init(&buffer);

    // Create three events in specific order
    var empty_fields = [_]ast.Field{};
    var empty_branches = [_]ast.Branch{
        .{ .name = "done", .payload = .{ .fields = &empty_fields }, .is_deferred = false, .is_optional = false },
    };

    const event1 = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"first"}) },
        .input = .{ .fields = &empty_fields },
        .branches = &empty_branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 1, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    const event2 = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"second"}) },
        .input = .{ .fields = &empty_fields },
        .branches = &empty_branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 5, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    const event3 = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"third"}) },
        .input = .{ .fields = &empty_fields },
        .branches = &empty_branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 10, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    // Create AST with events in order
    var items = [_]ast.Item{
        .{ .event_decl = event1 },
        .{ .event_decl = event2 },
        .{ .event_decl = event3 },
    };
    const source_file = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .allocator = testing.allocator,
    };

    // Emit using visitor (with empty tap registry and type registry)
    var tap_registry = tap_registry_module.TapRegistry.init(testing.allocator);
    defer tap_registry.deinit();
    var type_registry = type_registry_module.TypeRegistry.init(testing.allocator);
    defer type_registry.deinit();
    var visitor_emitter = VisitorEmitter.init(testing.allocator, &code_emitter, &items, &tap_registry, &type_registry, .all);
    try visitor_emitter.emit(&source_file);

    const output = code_emitter.getOutput();

    // Find positions of each event in output
    const first_pos = std.mem.indexOf(u8, output, "first_event") orelse return error.TestFailed;
    const second_pos = std.mem.indexOf(u8, output, "second_event") orelse return error.TestFailed;
    const third_pos = std.mem.indexOf(u8, output, "third_event") orelse return error.TestFailed;

    // Verify they appear in the correct order
    try testing.expect(first_pos < second_pos);
    try testing.expect(second_pos < third_pos);
}

test "visitor handles modules correctly" {
    // Test that modules are emitted as nested structs

    // TODO: Implement when visitor exists
    return error.SkipZigTest;
}

test "visitor handles flows with label loops" {
    // Test emission of ~#label syntax and @label jumps

    // TODO: Implement when visitor exists
    return error.SkipZigTest;
}

test "visitor emits complete valid program" {
    // End-to-end test: given a simple program AST,
    // emit complete valid Zig code that compiles

    var buffer: [4096]u8 = undefined;
    var code_emitter = emitter_helpers.CodeEmitter.init(&buffer);

    // Create a simple complete program:
    // - host_line for imports
    // - simple event with no inputs
    const host_line = ast.HostLine{
        .content = "const std = @import(\"std\");",
        .location = .{ .line = 1, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    var empty_fields = [_]ast.Field{};
    var branches = [_]ast.Branch{
        .{ .name = "done", .payload = .{ .fields = &empty_fields }, .is_deferred = false, .is_optional = false },
    };
    const simple_event = ast.EventDecl{
        .path = .{ .module_qualifier = null, .segments = @constCast(&[_][]const u8{"hello"}) },
        .input = .{ .fields = &empty_fields },
        .branches = &branches,
        .is_public = true,
        .is_implicit_flow = false,
        .annotations = @constCast(&[_][]const u8{}),
        .location = .{ .line = 3, .column = 0, .file = "input.kz" },
        .module = "input",
    };

    // Create AST
    var items = [_]ast.Item{
        .{ .host_line = host_line },
        .{ .event_decl = simple_event },
    };
    const source_file = ast.Program{
        .items = &items,
        .module_annotations = &[_][]const u8{},
        .allocator = testing.allocator,
    };

    // Emit using visitor (with empty tap registry and type registry)
    var tap_registry = tap_registry_module.TapRegistry.init(testing.allocator);
    defer tap_registry.deinit();
    var type_registry = type_registry_module.TypeRegistry.init(testing.allocator);
    defer type_registry.deinit();
    var visitor_emitter = VisitorEmitter.init(testing.allocator, &code_emitter, &items, &tap_registry, &type_registry, .all);
    try visitor_emitter.emit(&source_file);

    const output = code_emitter.getOutput();

    // Verify output contains expected elements
    try testing.expect(std.mem.indexOf(u8, output, "const std = @import(\"std\");") != null);
    try testing.expect(std.mem.indexOf(u8, output, "hello_event") != null);
    try testing.expect(std.mem.indexOf(u8, output, "done") != null);
}
