const std = @import("std");
const testing = std.testing;
const TapCodegen = @import("tap_codegen").TapCodegen;
const ast = @import("ast");

test "TapCodegen initialization" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    // Basic initialization test - allocators are the same
    // Can't compare allocators directly, just check it's initialized
    try testing.expect(codegen.buffer.items.len == 0);
}

test "Generate transition metadata structure" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    const metadata_code = try codegen.generateTransitionMetadata();
    defer allocator.free(metadata_code);
    
    // Check that key structures are generated
    try testing.expect(std.mem.indexOf(u8, metadata_code, "TransitionMetadata") != null);
    try testing.expect(std.mem.indexOf(u8, metadata_code, "source:") != null);
    try testing.expect(std.mem.indexOf(u8, metadata_code, "destination:") != null);
    try testing.expect(std.mem.indexOf(u8, metadata_code, "invokeTaps") != null);
}

test "Generate empty tap registry" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    const empty_taps = [_]*const ast.EventTap{};
    const registry_code = try codegen.generateTapRegistry(&empty_taps);
    defer allocator.free(registry_code);
    
    // Check that registry structure is generated even when empty
    try testing.expect(std.mem.indexOf(u8, registry_code, "TapRegistry") != null);
    try testing.expect(std.mem.indexOf(u8, registry_code, "TapEntry") != null);
}

test "Generate input tap calls" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create a test tap
    var segments = [_][]const u8{"test", "event"};
    const test_path = ast.DottedPath{
        .segments = &segments,
    };
    
    const test_tap = ast.EventTap{
        .source = null,
        .destination = test_path,
        .is_input_tap = true,
        .continuations = &[_]ast.Continuation{},
    };
    
    const input_taps = [_]*const ast.EventTap{&test_tap};
    const universal_taps = [_]*const ast.EventTap{};
    
    const tap_calls = try codegen.generateInputTapCalls(
        "test.event",
        &input_taps,
        &universal_taps,
    );
    defer allocator.free(tap_calls);
    
    // Check that input tap code is generated
    try testing.expect(std.mem.indexOf(u8, tap_calls, "input tap") != null);
    try testing.expect(std.mem.indexOf(u8, tap_calls, "TransitionMetadata") != null);
}

test "Generate output tap calls" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create a test tap
    var segments = [_][]const u8{"test", "event"};
    const test_path = ast.DottedPath{
        .segments = &segments,
    };
    
    const test_tap = ast.EventTap{
        .source = test_path,
        .destination = null,
        .is_input_tap = false,
        .continuations = &[_]ast.Continuation{},
    };
    
    const output_taps = [_]*const ast.EventTap{&test_tap};
    const universal_taps = [_]*const ast.EventTap{};
    
    const tap_calls = try codegen.generateOutputTapCalls(
        "test.event",
        &output_taps,
        &universal_taps,
    );
    defer allocator.free(tap_calls);
    
    // Check that output tap code is generated
    try testing.expect(std.mem.indexOf(u8, tap_calls, "output tap") != null);
    try testing.expect(std.mem.indexOf(u8, tap_calls, "TransitionMetadata") != null);
}

test "Generate universal tap calls" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create a universal tap (* -> *)
    const universal_tap = ast.EventTap{
        .source = null,
        .destination = null,
        .is_input_tap = false,
        .continuations = &[_]ast.Continuation{},
    };
    
    const specific_taps = [_]*const ast.EventTap{};
    const universal_taps = [_]*const ast.EventTap{&universal_tap};
    
    const tap_calls = try codegen.generateOutputTapCalls(
        "any.event",
        &specific_taps,
        &universal_taps,
    );
    defer allocator.free(tap_calls);
    
    // Check that universal tap code is generated
    try testing.expect(std.mem.indexOf(u8, tap_calls, "Universal") != null);
    try testing.expect(std.mem.indexOf(u8, tap_calls, "transition") != null);
}

test "Generate tap with continuation" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    // Create a tap with a simple continuation
    var event_segments = [_][]const u8{"logger", "info"};
    const event_path = ast.DottedPath{
        .segments = &event_segments,
    };
    
    const invocation = ast.Invocation{
        .path = event_path,
        .args = &[_]ast.Arg{
            .{ .name = "message", .value = "\"Tap fired!\"" },
        },
    };
    
    const continuation = ast.Continuation{
        .branch = "",
        .binding = null,
        .pipeline = &[_]ast.Step{
            .{ .invocation = invocation },
        },
        .nested = &[_]ast.Continuation{},
    };
    
    const test_tap = ast.EventTap{
        .source = event_path,
        .destination = null,
        .is_input_tap = false,
        .continuations = &[_]ast.Continuation{continuation},
    };
    
    const output_taps = [_]*const ast.EventTap{&test_tap};
    const universal_taps = [_]*const ast.EventTap{};
    
    const tap_calls = try codegen.generateOutputTapCalls(
        "logger.info",
        &output_taps,
        &universal_taps,
    );
    defer allocator.free(tap_calls);
    
    // Check that continuation code is generated
    try testing.expect(std.mem.indexOf(u8, tap_calls, "tap continuation") != null);
    try testing.expect(std.mem.indexOf(u8, tap_calls, "logger.info.handler") != null);
}

test "Generate tap registry with multiple taps" {
    const allocator = testing.allocator;
    
    var codegen = try TapCodegen.init(allocator);
    defer codegen.deinit();
    
    var segments1 = [_][]const u8{"event", "one"};
    var segments2 = [_][]const u8{"event", "two"};
    const path1 = ast.DottedPath{
        .segments = &segments1,
    };
    const path2 = ast.DottedPath{
        .segments = &segments2,
    };
    
    const tap1 = ast.EventTap{
        .source = path1,
        .destination = null,
        .is_input_tap = false,
        .continuations = &[_]ast.Continuation{},
    };
    
    const tap2 = ast.EventTap{
        .source = null,
        .destination = path2,
        .is_input_tap = true,
        .continuations = &[_]ast.Continuation{},
    };
    
    const tap3 = ast.EventTap{
        .source = null,
        .destination = null,
        .is_input_tap = false,
        .continuations = &[_]ast.Continuation{},
    };
    
    const all_taps = [_]*const ast.EventTap{ &tap1, &tap2, &tap3 };
    const registry_code = try codegen.generateTapRegistry(&all_taps);
    defer allocator.free(registry_code);
    
    // Check that all taps are in the registry
    try testing.expect(std.mem.indexOf(u8, registry_code, "tap_handler_0") != null);
    try testing.expect(std.mem.indexOf(u8, registry_code, "tap_handler_1") != null);
    try testing.expect(std.mem.indexOf(u8, registry_code, "tap_handler_2") != null);
    
    // Check that source and destination are correctly set
    try testing.expect(std.mem.indexOf(u8, registry_code, "event.one") != null);
    try testing.expect(std.mem.indexOf(u8, registry_code, "event.two") != null);
    try testing.expect(std.mem.indexOf(u8, registry_code, ".source = null") != null);
    try testing.expect(std.mem.indexOf(u8, registry_code, ".destination = null") != null);
}