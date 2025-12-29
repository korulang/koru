const std = @import("std");
const parser = @import("parser");
const ast = @import("ast");

test "parse where clause in continuation" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~http.get(url: "/api/data")
        \\| ok o where o.status == 200 |> success { data: o.body }
        \\| ok o where o.status >= 500 |> retry { after: 5 }
        \\| ok o where o.status >= 400 |> client_error { code: o.status }
        \\| ok o |> error { status: o.status }
        \\| err e |> network_error { msg: e.message }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    // Should parse one flow
    try std.testing.expectEqual(@as(usize, 1), result.source_file.items.len);
    
    const flow = result.source_file.items[0].flow;
    
    // Check the continuations
    try std.testing.expectEqual(@as(usize, 5), flow.continuations.len);
    
    // First continuation: ok o where o.status == 200
    const cont1 = flow.continuations[0];
    try std.testing.expectEqualStrings("ok", cont1.branch);
    try std.testing.expect(cont1.binding != null);
    try std.testing.expectEqualStrings("o", cont1.binding.?);
    try std.testing.expect(cont1.condition != null);
    try std.testing.expectEqualStrings("o.status == 200", cont1.condition.?);
    
    // Second continuation: ok o where o.status >= 500
    const cont2 = flow.continuations[1];
    try std.testing.expectEqualStrings("ok", cont2.branch);
    try std.testing.expect(cont2.binding != null);
    try std.testing.expectEqualStrings("o", cont2.binding.?);
    try std.testing.expect(cont2.condition != null);
    try std.testing.expectEqualStrings("o.status >= 500", cont2.condition.?);
    
    // Third continuation: ok o where o.status >= 400
    const cont3 = flow.continuations[2];
    try std.testing.expectEqualStrings("ok", cont3.branch);
    try std.testing.expect(cont3.binding != null);
    try std.testing.expectEqualStrings("o", cont3.binding.?);
    try std.testing.expect(cont3.condition != null);
    try std.testing.expectEqualStrings("o.status >= 400", cont3.condition.?);
    
    // Fourth continuation: ok o (no where clause - catch-all)
    const cont4 = flow.continuations[3];
    try std.testing.expectEqualStrings("ok", cont4.branch);
    try std.testing.expect(cont4.binding != null);
    try std.testing.expectEqualStrings("o", cont4.binding.?);
    try std.testing.expect(cont4.condition == null); // No condition - catch-all
    
    // Fifth continuation: err e (no where clause)
    const cont5 = flow.continuations[4];
    try std.testing.expectEqualStrings("err", cont5.branch);
    try std.testing.expect(cont5.binding != null);
    try std.testing.expectEqualStrings("e", cont5.binding.?);
    try std.testing.expect(cont5.condition == null);
}

test "where clause in proc context" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~proc handle_response {
        \\    ~http.get(url: e.url)
        \\    | ok o where o.status == 200 |> success { data: o.body }
        \\    | ok o where o.status >= 500 |> retry { after: backoff() }
        \\    | ok o where o.status >= 400 |> client_error { code: o.status }
        \\    | ok o |> error { status: o.status }
        \\    | err e |> network_error { msg: e.message }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    // Should parse one proc
    try std.testing.expectEqual(@as(usize, 1), result.source_file.items.len);
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should have one inline flow
    try std.testing.expectEqual(@as(usize, 1), proc.inline_flows.len);
    
    const flow = proc.inline_flows[0];
    
    // Check that where clauses are preserved in inline flows
    try std.testing.expectEqual(@as(usize, 5), flow.continuations.len);
    
    // Verify first where clause
    const cont1 = flow.continuations[0];
    try std.testing.expect(cont1.condition != null);
    try std.testing.expectEqualStrings("o.status == 200", cont1.condition.?);
}

test "complex where clause expressions" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~validate(input: e.data)
        \\| result r where r.score > 90 && r.valid |> excellent { score: r.score }
        \\| result r where r.score > 70 && r.score <= 90 |> good { score: r.score }
        \\| result r where r.score > 50 |> pass { score: r.score }
        \\| result r |> fail { score: r.score, reason: "too low" }
        \\| error e |> invalid { reason: e.message }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const flow = result.source_file.items[0].flow;
    
    // Check complex conditions are captured correctly
    const cont1 = flow.continuations[0];
    try std.testing.expect(cont1.condition != null);
    try std.testing.expectEqualStrings("r.score > 90 && r.valid", cont1.condition.?);
    
    const cont2 = flow.continuations[1];
    try std.testing.expect(cont2.condition != null);
    try std.testing.expectEqualStrings("r.score > 70 && r.score <= 90", cont2.condition.?);
}

test "where clause with parentheses" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~process(data: e.input)
        \\| result r where (r.a > 10 || r.b < 5) && r.valid |> accept { value: r }
        \\| result r |> reject { reason: "criteria not met" }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const flow = result.source_file.items[0].flow;
    
    // Check that parentheses are preserved
    const cont1 = flow.continuations[0];
    try std.testing.expect(cont1.condition != null);
    try std.testing.expectEqualStrings("(r.a > 10 || r.b < 5) && r.valid", cont1.condition.?);
}

test "where clause without binding" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~process(data: e.input)
        \\| result where score > 50 |> pass { }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    // This parses with "where" as a keyword, not as the binding
    var result = try p.parse();
    defer result.deinit();
    
    const flow = result.source_file.items[0].flow;
    const cont = flow.continuations[0];
    
    // The parser handles "where" specially, so there's no binding
    // but there is a condition
    try std.testing.expect(cont.binding == null);
    try std.testing.expect(cont.condition != null);
    try std.testing.expectEqualStrings("score > 50", cont.condition.?);
    
    // Note: This would be a semantic error (where clause needs a binding)
    // but the parser accepts it syntactically
}