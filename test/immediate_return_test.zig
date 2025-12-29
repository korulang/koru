const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const ast = @import("ast");

test "parse immediate return syntax" {
    const allocator = testing.allocator;
    
    const source =
        \\~event test.mock { input: i32 }
        \\| success { value: i32 }
        \\| failure {}
        \\
        \\// Immediate return - just return success
        \\~test.mock = success { value: 42 }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    const result = try p.parse();
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    
    // Should have 3 items: event decl, zig_line (comment), and subflow impl
    try testing.expectEqual(@as(usize, 3), result.source_file.items.len);
    
    // Check the subflow impl (now at index 2)
    const subflow = result.source_file.items[2].subflow_impl;
    
    // Event path should be test.mock
    try testing.expectEqual(@as(usize, 2), subflow.event_path.segments.len);
    try testing.expectEqualStrings("test", subflow.event_path.segments[0]);
    try testing.expectEqualStrings("mock", subflow.event_path.segments[1]);
    
    // Body should be immediate
    switch (subflow.body) {
        .immediate => |bc| {
            try testing.expectEqualStrings("success", bc.branch_name);
            try testing.expectEqual(@as(usize, 1), bc.fields.len);
            try testing.expectEqualStrings("value", bc.fields[0].name);
            try testing.expectEqualStrings("42", bc.fields[0].type); // 'type' holds the value expression
        },
        .flow => {
            try testing.expect(false); // Should not be a flow!
        },
    }
}

test "parse immediate return with multiple fields" {
    const allocator = testing.allocator;
    
    const source =
        \\~event user.get { id: i32 }
        \\| found { name: []const u8, email: []const u8 }
        \\
        \\~user.get = found { name: "Alice", email: "alice@test.com" }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    const result = try p.parse();
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    
    const subflow = result.source_file.items[1].subflow_impl;
    
    switch (subflow.body) {
        .immediate => |bc| {
            try testing.expectEqualStrings("found", bc.branch_name);
            try testing.expectEqual(@as(usize, 2), bc.fields.len);
            try testing.expectEqualStrings("name", bc.fields[0].name);
            try testing.expectEqualStrings("\"Alice\"", bc.fields[0].type);
            try testing.expectEqualStrings("email", bc.fields[1].name);
            try testing.expectEqualStrings("\"alice@test.com\"", bc.fields[1].type);
        },
        .flow => {
            try testing.expect(false); // Should not be a flow!
        },
    }
}

test "parse regular subflow still works" {
    const allocator = testing.allocator;
    
    const source =
        \\~event process.data { input: i32 }
        \\| done { result: i32 }
        \\
        \\~process.data = compute.run(value: input)
        \\| success s |> done { result: s.output }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    const result = try p.parse();
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    
    const subflow = result.source_file.items[1].subflow_impl;
    
    // Should be a flow, not immediate
    switch (subflow.body) {
        .flow => |f| {
            try testing.expectEqual(@as(usize, 2), f.invocation.path.segments.len);
            try testing.expectEqualStrings("compute", f.invocation.path.segments[0]);
            try testing.expectEqualStrings("run", f.invocation.path.segments[1]);
            try testing.expectEqual(@as(usize, 1), f.continuations.len);
        },
        .immediate => {
            try testing.expect(false); // Should be a flow!
        },
    }
}