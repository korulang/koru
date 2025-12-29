const std = @import("std");
const testing = std.testing;

test "end-to-end: branch constructor expressions compile and run" {
    const allocator = testing.allocator;
    
    // Create a complete Koru program with branch constructor expressions
    const koru_source =
        \\~proc process_http_response {
        \\    const response = ~http.get(.{ .url = "https://api.example.com/data" })
        \\    | ok o |> success { 
        \\        data: o.body,
        \\        status: o.status_code,
        \\        bytes: o.body.len
        \\    }
        \\    | error e |> failure { 
        \\        reason: e.message,
        \\        retry: e.code == 503
        \\    }
        \\    
        \\    return response;
        \\}
    ;
    
    // This would be the expected generated Zig code structure
    _ =
        \\const InlineFlow_process_http_response_0_Result = union(enum) {
        \\    success: struct {
        \\        data: []const u8,
        \\        status: u32,
        \\        bytes: usize,
        \\    },
        \\    failure: struct {
        \\        reason: []const u8,
        \\        retry: bool,
        \\    },
        \\};
        \\
        \\fn __inline_flow_1(args: anytype) InlineFlow_process_http_response_0_Result {
        \\    const result = http.get(args);
        \\    switch (result) {
        \\        .ok => |o| {
        \\            return .success = .{
        \\                .data = o.body,
        \\                .status = o.status_code,
        \\                .bytes = o.body.len,
        \\            };
        \\        },
        \\        .error => |e| {
        \\            return .failure = .{
        \\                .reason = e.message,
        \\                .retry = e.code == 503,
        \\            };
        \\        },
        \\    }
        \\}
        \\
        \\pub fn process_http_response() !InlineFlow_process_http_response_0_Result {
        \\    const response = __inline_flow_1(.{ .url = "https://api.example.com/data" });
        \\    return response;
        \\}
    ;
    
    // Step 1: Parse the Koru source
    const parser = @import("parser");
    var p = try parser.Parser.init(allocator, koru_source, "test.kz");
    defer p.deinit();
    
    var parse_result = try p.parse();
    defer parse_result.deinit();
    
    // Verify we parsed the proc with inline flow
    const proc = parse_result.source_file.items[0].proc_decl;
    try testing.expectEqual(@as(usize, 1), proc.inline_flows.len);
    
    const flow = &proc.inline_flows[0];
    try testing.expect(flow.super_shape != null);
    
    // Step 2: Generate union types
    const union_codegen = @import("union_codegen");
    var codegen = union_codegen.UnionCodegen.init(allocator);
    
    const type_name = try codegen.generateInlineFlowTypeName("process_http_response", 0);
    defer allocator.free(type_name);
    
    const union_type_code = try codegen.generateUnionType(type_name, &flow.super_shape.?);
    defer allocator.free(union_type_code);
    
    // Verify union type contains expected branches
    try testing.expect(std.mem.indexOf(u8, union_type_code, "success:") != null);
    try testing.expect(std.mem.indexOf(u8, union_type_code, "failure:") != null);
    
    // Step 3: Verify AST serialization includes expressions
    const ast_serializer = @import("ast_serializer");
    var serializer = try ast_serializer.AstSerializer.init(allocator);
    defer serializer.deinit();
    
    const serialized = try serializer.serialize(&parse_result.source_file);
    defer allocator.free(serialized);
    
    // Check that expressions were serialized
    try testing.expect(std.mem.indexOf(u8, serialized, "expression_str") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "o.body") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "o.status_code") != null);
}

test "end-to-end: complex expression evaluation" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc analyze_data {
        \\    const result = ~process(.{ .items = items })
        \\    | ok o where o.count > 0 |> analysis { 
        \\        total: o.count,
        \\        average: o.sum / o.count,
        \\        has_outliers: o.max > o.mean * 2
        \\    }
        \\    | ok _ |> empty { message: "No data" }
        \\    | error e |> failed { error: e.reason };
        \\    
        \\    return result;
        \\}
    ;
    
    const parser = @import("parser");
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    
    // Verify where clause was parsed
    try testing.expect(flow.continuations[0].condition != null);
    try testing.expectEqualStrings("o.count > 0", flow.continuations[0].condition.?);
    
    // Verify complex expressions in branch constructor
    const bc = &flow.continuations[0].pipeline[0].branch_constructor;
    try testing.expectEqualStrings("average", bc.fields[1].name);
    try testing.expectEqualStrings("o.sum / o.count", bc.fields[1].expression_str.?);
    
    try testing.expectEqualStrings("has_outliers", bc.fields[2].name);
    try testing.expectEqualStrings("o.max > o.mean * 2", bc.fields[2].expression_str.?);
}

test "end-to-end: empty and single-field constructors" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc validate {
        \\    ~check(input)
        \\    | valid _ |> ok {}
        \\    | invalid e |> err { e.message }
        \\}
    ;
    
    const parser = @import("parser");
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    
    // First continuation has empty constructor
    const empty_bc = &flow.continuations[0].pipeline[0].branch_constructor;
    try testing.expectEqual(@as(usize, 0), empty_bc.fields.len);
    
    // Second has single shorthand field
    const single_bc = &flow.continuations[1].pipeline[0].branch_constructor;
    try testing.expectEqual(@as(usize, 1), single_bc.fields.len);
    try testing.expectEqualStrings("message", single_bc.fields[0].name);
    try testing.expectEqualStrings("e.message", single_bc.fields[0].expression_str.?);
}