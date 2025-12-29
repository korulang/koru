const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const ast = @import("ast");
const expression_codegen = @import("expression_codegen");

test "parse and generate code for where clause" {
    const allocator = testing.allocator;
    
    const source =
        \\~api.fetch(url: "https://api.example.com/data")
        \\| ok response where response.status == 200 |> json.parse(response.body)
        \\| error e |> log.error(e)
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const flow = result.source_file.items[0].flow;
    const ok_cont = flow.continuations[0];
    
    // Check that we parsed the where clause
    try testing.expect(ok_cont.condition != null);
    try testing.expectEqualStrings("response.status == 200", ok_cont.condition.?);
    
    // Check that we parsed the expression
    try testing.expect(ok_cont.condition_expr != null);
    
    // Generate code for the continuation
    const code = try expression_codegen.generateContinuationWithWhere(
        allocator,
        &ok_cont,
        4,
    );
    defer allocator.free(code);
    
    // Verify the generated code contains the if statement
    try testing.expect(std.mem.indexOf(u8, code, ".ok => |response|") != null);
    try testing.expect(std.mem.indexOf(u8, code, "if (response.status == 200)") != null);
    
    std.debug.print("\n=== Generated Code ===\n{s}\n", .{code});
}

test "complex where clause with logical operators" {
    const allocator = testing.allocator;
    
    const source =
        \\~validate(input: data)
        \\| valid v where v.score > 90 and v.approved |> process(v)
        \\| invalid i where i.retryable or i.code == "TEMP_ERROR" |> retry(i)
        \\| invalid i |> reject(i)
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const flow = result.source_file.items[0].flow;
    
    // Check first continuation with AND
    const valid_cont = flow.continuations[0];
    try testing.expect(valid_cont.condition != null);
    try testing.expectEqualStrings("v.score > 90 and v.approved", valid_cont.condition.?);
    try testing.expect(valid_cont.condition_expr != null);
    
    // Check second continuation with OR
    const invalid_retry_cont = flow.continuations[1];
    try testing.expect(invalid_retry_cont.condition != null);
    try testing.expectEqualStrings("i.retryable or i.code == \"TEMP_ERROR\"", invalid_retry_cont.condition.?);
    try testing.expect(invalid_retry_cont.condition_expr != null);
    
    // Verify the generated code uses correct Zig operators  
    const code = try expression_codegen.generateContinuationWithWhere(
        allocator,
        &valid_cont,
        4,
    );
    defer allocator.free(code);
    
    // Verify 'and' is used (correct Zig logical operator)
    try testing.expect(std.mem.indexOf(u8, code, " and ") != null);
    try testing.expect(std.mem.indexOf(u8, code, "&&") == null);
    
    // Check third continuation without where clause
    const invalid_reject_cont = flow.continuations[2];
    try testing.expect(invalid_reject_cont.condition == null);
    try testing.expect(invalid_reject_cont.condition_expr == null);
}

test "where clause in proc context" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc handle_response {
        \\    return ~http.get(url)
        \\    | ok o where o.status == 200 |> .{ success = o.body }
        \\    | ok o where o.status >= 500 |> .{ retry = .{} }
        \\    | ok o |> .{ failure = .{ code = o.status } }
        \\    | error e |> .{ failure = .{ message = e } }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Check inline flows were extracted
    try testing.expect(proc.inline_flows.len > 0);
    
    const inline_flow = proc.inline_flows[0];
    
    // Check multiple where clauses
    const ok_200 = inline_flow.continuations[0];
    try testing.expect(ok_200.condition != null);
    try testing.expectEqualStrings("o.status == 200", ok_200.condition.?);
    try testing.expect(ok_200.condition_expr != null);
    
    const ok_500 = inline_flow.continuations[1];
    try testing.expect(ok_500.condition != null);
    try testing.expectEqualStrings("o.status >= 500", ok_500.condition.?);
    try testing.expect(ok_500.condition_expr != null);
    
    // Generate code for one of the continuations
    const code = try expression_codegen.generateContinuationWithWhere(
        allocator,
        &ok_200,
        8,
    );
    defer allocator.free(code);
    
    std.debug.print("\n=== Generated Proc Where Clause ===\n{s}\n", .{code});
    
    try testing.expect(std.mem.indexOf(u8, code, "if (o.status == 200)") != null);
}