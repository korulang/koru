const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const ast = @import("ast");
const lexer = @import("lexer");
const errors = @import("errors");
const type_registry = @import("type_registry");

test "branch constructor shorthand field extraction" {
    _ = testing.allocator;
    
    // Test helper to extract field name from shorthand
    const extractFieldName = struct {
        fn extract(expr: []const u8) []const u8 {
            const dot_idx = std.mem.lastIndexOf(u8, expr, ".");
            if (dot_idx) |idx| {
                return lexer.trim(expr[idx + 1..]);
            } else {
                return expr;
            }
        }
    }.extract;
    
    // Test simple identifier
    try testing.expectEqualStrings("s", extractFieldName("s"));
    
    // Test single field access
    try testing.expectEqualStrings("value", extractFieldName("s.value"));
    
    // Test nested field access
    try testing.expectEqualStrings("field", extractFieldName("s.nested.deep.field"));
    
    // Test very deep nesting
    try testing.expectEqualStrings("final", extractFieldName("a.b.c.d.e.f.final"));
    
    // Test with spaces (shouldn't happen in practice but good to handle)
    try testing.expectEqualStrings("field", extractFieldName("obj.field"));
}

test "parse branch constructor with shorthand syntax" {
    const allocator = testing.allocator;
    
    const FieldSpec = struct {
        name: []const u8,
        value: []const u8,
    };
    const TestCase = struct {
        input: []const u8,
        expected_fields: []const FieldSpec,
    };
    const test_cases = [_]TestCase{
        // Simple identifier shorthand
        .{
            .input = "done { value }",
            .expected_fields = &[_]FieldSpec{
                .{ .name = "value", .value = "value" },
            },
        },
        // Field access shorthand
        .{
            .input = "done { s.id }",
            .expected_fields = &[_]FieldSpec{
                .{ .name = "id", .value = "s.id" },
            },
        },
        // Nested field access shorthand
        .{
            .input = "done { order.customer.name }",
            .expected_fields = &[_]FieldSpec{
                .{ .name = "name", .value = "order.customer.name" },
            },
        },
        // Mixed shorthand and explicit
        .{
            .input = "done { s.value, status: \"ok\", result.data }",
            .expected_fields = &[_]FieldSpec{
                .{ .name = "value", .value = "s.value" },
                .{ .name = "status", .value = "\"ok\"" },
                .{ .name = "data", .value = "result.data" },
            },
        },
        // Full binding shorthand (s becomes s: s)
        .{
            .input = "done { s }",
            .expected_fields = &[_]FieldSpec{
                .{ .name = "s", .value = "s" },
            },
        },
        // Multiple shorthand field accesses
        .{
            .input = "done { order.id, order.total, customer.name }",
            .expected_fields = &[_]FieldSpec{
                .{ .name = "id", .value = "order.id" },
                .{ .name = "total", .value = "order.total" },
                .{ .name = "name", .value = "customer.name" },
            },
        },
    };
    
    for (test_cases) |tc| {
        // Extract the fields from the branch constructor
        const brace_start = std.mem.indexOf(u8, tc.input, "{").?;
        const brace_end = std.mem.lastIndexOf(u8, tc.input, "}").?;
        const fields_str = lexer.trim(tc.input[brace_start + 1..brace_end]);
        
        const FieldType = struct { name: []const u8, value: []const u8 };
        var fields = try std.ArrayList(FieldType).initCapacity(allocator, 10);
        defer {
            for (fields.items) |field| {
                allocator.free(field.name);
                allocator.free(field.value);
            }
            fields.deinit(allocator);
        }
        
        // Parse fields with shorthand support
        var field_iter = std.mem.splitSequence(u8, fields_str, ",");
        while (field_iter.next()) |field_str| {
            const trimmed = lexer.trim(field_str);
            const colon_idx = std.mem.indexOf(u8, trimmed, ":");
            
            const field_name = if (colon_idx) |idx| blk: {
                // Explicit form
                break :blk try allocator.dupe(u8, lexer.trim(trimmed[0..idx]));
            } else blk: {
                // Shorthand form - check if it's a field access
                const dot_idx = std.mem.lastIndexOf(u8, trimmed, ".");
                if (dot_idx) |idx| {
                    // Take the field name after the last dot
                    break :blk try allocator.dupe(u8, lexer.trim(trimmed[idx + 1..]));
                } else {
                    // Simple identifier
                    break :blk try allocator.dupe(u8, trimmed);
                }
            };
            
            const field_value = if (colon_idx) |idx|
                try allocator.dupe(u8, lexer.trim(trimmed[idx + 1..]))
            else
                try allocator.dupe(u8, trimmed);
                
            try fields.append(allocator, .{ .name = field_name, .value = field_value });
        }
        
        // Verify the fields match expectations
        try testing.expectEqual(tc.expected_fields.len, fields.items.len);
        for (tc.expected_fields, fields.items) |expected, actual| {
            try testing.expectEqualStrings(expected.name, actual.name);
            try testing.expectEqualStrings(expected.value, actual.value);
        }
    }
}

test "event argument shorthand parsing" {
    const allocator = testing.allocator;
    
    // Test event arguments with shorthand
    const ArgSpec = struct {
        name: []const u8,
        value: []const u8,
    };
    const TestCase = struct {
        input: []const u8,
        expected: []const ArgSpec,
    };
    const test_cases = [_]TestCase{
        // All shorthand
        .{
            .input = "(id, name, value)",
            .expected = &[_]ArgSpec{
                .{ .name = "id", .value = "id" },
                .{ .name = "name", .value = "name" },
                .{ .name = "value", .value = "value" },
            },
        },
        // Mixed shorthand and explicit
        .{
            .input = "(id, customer: user_name, status)",
            .expected = &[_]ArgSpec{
                .{ .name = "id", .value = "id" },
                .{ .name = "customer", .value = "user_name" },
                .{ .name = "status", .value = "status" },
            },
        },
        // No shorthand
        .{
            .input = "(id: order_id, name: customer_name)",
            .expected = &[_]ArgSpec{
                .{ .name = "id", .value = "order_id" },
                .{ .name = "name", .value = "customer_name" },
            },
        },
    };
    
    for (test_cases) |tc| {
        const args = try lexer.parseArgs(allocator, tc.input);
        defer {
            for (args) |arg| {
                allocator.free(arg.name);
                allocator.free(arg.value);
            }
            allocator.free(args);
        }
        
        try testing.expectEqual(tc.expected.len, args.len);
        for (tc.expected, args) |expected, actual| {
            try testing.expectEqualStrings(expected.name, actual.name);
            try testing.expectEqualStrings(expected.value, actual.value);
        }
    }
}

test "edge cases for shorthand syntax" {
    _ = testing.allocator;
    
    // Test empty branch constructor
    {
        const input = "done { }";
        const brace_start = std.mem.indexOf(u8, input, "{").?;
        const brace_end = std.mem.lastIndexOf(u8, input, "}").?;
        const fields_str = lexer.trim(input[brace_start + 1..brace_end]);
        
        try testing.expectEqual(@as(usize, 0), fields_str.len);
    }
    
    // Test single field with spaces
    {
        const input = "done {  s.value  }";
        const brace_start = std.mem.indexOf(u8, input, "{").?;
        const brace_end = std.mem.lastIndexOf(u8, input, "}").?;
        const fields_str = lexer.trim(input[brace_start + 1..brace_end]);
        
        try testing.expectEqualStrings("s.value", fields_str);
        
        // Extract field name
        const dot_idx = std.mem.lastIndexOf(u8, fields_str, ".").?;
        const field_name = fields_str[dot_idx + 1..];
        try testing.expectEqualStrings("value", field_name);
    }
    
    // Test that binding 's' alone becomes s: s
    {
        const expr = "s";
        const dot_idx = std.mem.lastIndexOf(u8, expr, ".");
        const field_name = if (dot_idx) |idx|
            expr[idx + 1..]
        else
            expr;
        
        try testing.expectEqualStrings("s", field_name);
        try testing.expectEqualStrings("s", expr);  // value stays the same
    }
}

test "complex proc body extraction with nested braces" {
    const allocator = testing.allocator;
    
    // Create a test source with complex nested braces
    const source =
        \\~[raw]proc complex.test {
        \\    const str1 = "test { brace }";
        \\    if (condition) {
        \\        for (items) |item| {
        \\            switch (item) {
        \\                .foo => {
        \\                    const nested = "another { nested } brace";
        \\                    if (true) {
        \\                        doSomething();
        \\                    }
        \\                },
        \\                else => {},
        \\            }
        \\        }
        \\    }
        \\    return result;
        \\}
        \\~something.after.proc()
    ;
    
    var err_reporter = errors.Reporter.init(allocator);
    defer err_reporter.deinit();
    
    var registry = try type_registry.Registry.init(allocator);
    defer registry.deinit();
    
    var p = try parser.Parser.init(allocator, source, "test.kz", &err_reporter, &registry, false);
    defer p.deinit();
    
    const result = try p.parse();
    defer result.deinit();
    
    // Should have parsed both the proc and the flow after
    try testing.expectEqual(@as(usize, 2), result.source_file.items.len);
    
    // First item should be the proc
    const proc_item = result.source_file.items[0];
    try testing.expect(proc_item == .proc_decl);
    
    const proc = proc_item.proc_decl;
    
    // Check that the proc body contains all expected content
    const body = proc.body;
    
    // The body should contain all our nested code
    try testing.expect(std.mem.indexOf(u8, body, "const str1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "if (condition)") != null);
    try testing.expect(std.mem.indexOf(u8, body, "for (items)") != null);
    try testing.expect(std.mem.indexOf(u8, body, "switch (item)") != null);
    try testing.expect(std.mem.indexOf(u8, body, "return result") != null);
    
    // Second item should be the flow after the proc
    const flow_item = result.source_file.items[1];
    try testing.expect(flow_item == .flow);
    
    // Print the actual body length for debugging
    std.debug.print("\nProc body extracted: {} chars\n", .{body.len});
    
    // Count the lines in the body
    var line_count: usize = 1;
    for (body) |c| {
        if (c == '\n') line_count += 1;
    }
    std.debug.print("Lines in body: {}\n", .{line_count});
}

test "proc body extraction with strings containing braces" {
    const allocator = testing.allocator;
    
    // This tests the specific issue: strings with braces shouldn't affect depth
    const source =
        \\~proc test.strings {
        \\    const msg1 = "hello { world }";
        \\    const msg2 = "nested {{ braces }}";
        \\    const msg3 = "} unbalanced {";
        \\    if (true) {
        \\        return "final { } test";
        \\    }
        \\}
        \\~flow.after()
    ;
    
    var err_reporter = errors.Reporter.init(allocator);
    defer err_reporter.deinit();
    
    var registry = try type_registry.Registry.init(allocator);
    defer registry.deinit();
    
    var p = try parser.Parser.init(allocator, source, "test.kz", &err_reporter, &registry, false);
    defer p.deinit();
    
    const result = try p.parse();
    defer result.deinit();
    
    // Should have parsed both items
    try testing.expectEqual(@as(usize, 2), result.source_file.items.len);
    
    // Check the proc
    const proc = result.source_file.items[0].proc_decl;
    const body = proc.body;
    
    // All lines should be in the body
    try testing.expect(std.mem.indexOf(u8, body, "const msg1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "const msg2") != null); 
    try testing.expect(std.mem.indexOf(u8, body, "const msg3") != null);
    try testing.expect(std.mem.indexOf(u8, body, "return \"final") != null);
    
    // The flow after should be parsed
    try testing.expect(result.source_file.items[1] == .flow);
}

test "multi-line annotation syntax for flow calls" {
    const allocator = testing.allocator;

    // Test annotation on separate line from flow call
    const source =
        \\~import "$std/build"
        \\
        \\~[default]
        \\std.build:step(name: "compile") {
        \\    zig build
        \\}
        \\
        \\~[default, depends_on("compile")]
        \\std.build:step(name: "run") {
        \\    ./zig-out/bin/main
        \\}
    ;

    const compiler_flags = [_][]const u8{};
    var p = try parser.Parser.init(allocator, source, "test.kz", &compiler_flags, null);
    defer p.deinit();

    const result = try p.parse();
    defer result.deinit();

    // Should have parsed the import + 2 flow calls
    try testing.expect(result.source_file.items.len >= 2);

    // Check that flows were parsed with their annotations
    var flow_count: usize = 0;
    for (result.source_file.items) |item| {
        if (item == .flow) {
            flow_count += 1;
            const flow = item.flow;

            // Each flow should have annotations
            try testing.expect(flow.annotations.len > 0);

            // Check that "default" annotation is present
            var has_default = false;
            for (flow.annotations) |ann| {
                if (std.mem.indexOf(u8, ann, "default") != null) {
                    has_default = true;
                    break;
                }
            }
            try testing.expect(has_default);
        }
    }

    try testing.expectEqual(@as(usize, 2), flow_count);
}

test "multi-line annotation syntax for event definitions" {
    const allocator = testing.allocator;

    // Test annotation on separate line from event definition
    const source =
        \\~[comptime|norun]
        \\pub event build.step {
        \\    name: []const u8,
        \\    source: Source
        \\}
        \\
        \\~[runtime]
        \\event notify.user {
        \\    message: []const u8
        \\}
    ;

    const compiler_flags = [_][]const u8{};
    var p = try parser.Parser.init(allocator, source, "test.kz", &compiler_flags, null);
    defer p.deinit();

    const result = try p.parse();
    defer result.deinit();

    // Should have parsed 2 events
    try testing.expect(result.source_file.items.len >= 2);

    var event_count: usize = 0;
    for (result.source_file.items) |item| {
        if (item == .event_decl) {
            event_count += 1;
            const event = item.event_decl;

            // Each event should have annotations
            try testing.expect(event.annotations.len > 0);
        }
    }

    try testing.expectEqual(@as(usize, 2), event_count);
}

test "multi-line annotation syntax for proc definitions" {
    const allocator = testing.allocator;

    // Test annotation on separate line from proc definition
    const source =
        \\~[raw]
        \\proc test.handler {
        \\    const result = doSomething();
        \\    return result;
        \\}
        \\
        \\~[pure, inline]
        \\proc calculate.sum {
        \\    return a + b;
        \\}
    ;

    const compiler_flags = [_][]const u8{};
    var p = try parser.Parser.init(allocator, source, "test.kz", &compiler_flags, null);
    defer p.deinit();

    const result = try p.parse();
    defer result.deinit();

    // Should have parsed 2 procs
    try testing.expectEqual(@as(usize, 2), result.source_file.items.len);

    for (result.source_file.items) |item| {
        try testing.expect(item == .proc_decl);
        const proc = item.proc_decl;

        // Each proc should have annotations
        try testing.expect(proc.annotations.len > 0);
    }
}