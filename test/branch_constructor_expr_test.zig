const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const ast = @import("ast");

test "parse branch constructor with expressions in proc" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc handle_response {
        \\    const result = ~http.get(url)
        \\    | ok o |> success { 
        \\        data: o.body,
        \\        status: o.status,
        \\        length: o.body.len
        \\    }
        \\    | error e |> failure { 
        \\        reason: e.msg,
        \\        code: e.status 
        \\    }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should have extracted the inline flow
    try testing.expect(proc.inline_flows.len > 0);
    
    const flow = &proc.inline_flows[0];
    
    // Check that continuations have branch constructors with expressions
    for (flow.continuations) |cont| {
        for (cont.pipeline) |step| {
            if (step == .branch_constructor) {
                const bc = &step.branch_constructor;
                
                // Should be marked as having expressions
                try testing.expect(bc.has_expressions);
                
                // Fields should have expression strings
                for (bc.fields) |field| {
                    try testing.expect(field.expression_str != null);
                    
                    // Type should be "auto" for expression fields
                    try testing.expectEqualStrings("auto", field.type);
                }
            }
        }
    }
}

test "parse shorthand branch constructor in proc" {
    const allocator = testing.allocator;
    
    // Shorthand: just "o.value" instead of "field: o.value"
    const source =
        \\~proc shorthand_test {
        \\    ~transform(input)
        \\    | ok o |> success { o.value }
        \\    | err e |> failure { e.reason }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should have extracted the inline flow
    try testing.expectEqual(@as(usize, 1), proc.inline_flows.len);
    
    const flow = &proc.inline_flows[0];
    
    // Check the success branch constructor
    const success_cont = flow.continuations[0];
    const success_bc = &success_cont.pipeline[0].branch_constructor;
    
    try testing.expect(success_bc.has_expressions);
    try testing.expectEqual(@as(usize, 1), success_bc.fields.len);
    
    // Shorthand should use field name from expression
    const field = &success_bc.fields[0];
    try testing.expectEqualStrings("value", field.name); // Extracted from "o.value"
    try testing.expectEqualStrings("o.value", field.expression_str.?);
}

test "where clauses with expressions in proc" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc status_handler {
        \\    ~fetch(url)
        \\    | ok o where o.status == 200 |> success { data: o.body }
        \\    | ok o where o.status >= 400 and o.status < 500 |> client_error { code: o.status }
        \\    | ok o where o.status >= 500 |> server_error { retry: true }
        \\    | error e |> network_failure { msg: e.message }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    try testing.expectEqual(@as(usize, 1), proc.inline_flows.len);
    
    const flow = &proc.inline_flows[0];
    
    // Should have 4 continuations
    try testing.expectEqual(@as(usize, 4), flow.continuations.len);
    
    // First three should have where conditions
    for (flow.continuations[0..3]) |cont| {
        try testing.expect(cont.condition != null);
        try testing.expect(cont.condition_expr != null);
    }
    
    // Last one (error branch) should not have a where condition
    try testing.expect(flow.continuations[3].condition == null);
    try testing.expect(flow.continuations[3].condition_expr == null);
}