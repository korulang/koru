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
    
    var p = try parser.Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer p.deinit();
    
    const result = try p.parse();
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    
    // Should have 3 items: event decl, host line (comment), and immediate impl
    try testing.expectEqual(@as(usize, 3), result.source_file.items.len);
    
    // Check the immediate impl (now at index 2)
    const immediate = result.source_file.items[2].immediate_impl;
    
    // Event path should be test.mock
    try testing.expectEqual(@as(usize, 2), immediate.event_path.segments.len);
    try testing.expectEqualStrings("test", immediate.event_path.segments[0]);
    try testing.expectEqualStrings("mock", immediate.event_path.segments[1]);
    
    try testing.expectEqualStrings("success", immediate.value.branch_name);
    try testing.expectEqual(@as(usize, 1), immediate.value.fields.len);
    try testing.expectEqualStrings("value", immediate.value.fields[0].name);
    try testing.expectEqualStrings("42", immediate.value.fields[0].expression_str.?);
}

test "parse immediate return with multiple fields" {
    const allocator = testing.allocator;
    
    const source =
        \\~event user.get { id: i32 }
        \\| found { name: []const u8, email: []const u8 }
        \\
        \\~user.get = found { name: "Alice", email: "alice@test.com" }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer p.deinit();
    
    const result = try p.parse();
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    
    const immediate = result.source_file.items[1].immediate_impl;
    
    try testing.expectEqualStrings("found", immediate.value.branch_name);
    try testing.expectEqual(@as(usize, 2), immediate.value.fields.len);
    try testing.expectEqualStrings("name", immediate.value.fields[0].name);
    try testing.expectEqualStrings("\"Alice\"", immediate.value.fields[0].expression_str.?);
    try testing.expectEqualStrings("email", immediate.value.fields[1].name);
    try testing.expectEqualStrings("\"alice@test.com\"", immediate.value.fields[1].expression_str.?);
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
    
    var p = try parser.Parser.init(allocator, source, "test.kz", &[_][]const u8{}, null);
    defer p.deinit();
    
    const result = try p.parse();
    defer {
        var mut_result = result;
        mut_result.deinit();
    }
    
    const flow = result.source_file.items[1].flow;
    
    try testing.expect(flow.impl_of != null);
    try testing.expectEqual(@as(usize, 2), flow.invocation.path.segments.len);
    try testing.expectEqualStrings("compute", flow.invocation.path.segments[0]);
    try testing.expectEqualStrings("run", flow.invocation.path.segments[1]);
    try testing.expectEqual(@as(usize, 1), flow.continuations.len);
}
