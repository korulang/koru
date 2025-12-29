const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const ast = @import("ast");

test "empty branch constructor" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc empty_branches {
        \\    ~validate(data)
        \\    | ok _ |> success {}
        \\    | error _ |> failure {}
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    try testing.expect(proc.inline_flows.len > 0);
    
    const flow = &proc.inline_flows[0];
    
    // Check empty constructors
    for (flow.continuations) |cont| {
        for (cont.pipeline) |step| {
            if (step == .branch_constructor) {
                const bc = &step.branch_constructor;
                // Empty constructors should have 0 fields
                try testing.expectEqual(@as(usize, 0), bc.fields.len);
            }
        }
    }
}

test "nested field access in branch constructor" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc nested_access {
        \\    ~fetch(url)
        \\    | ok o |> success { 
        \\        content: o.body.content.value,
        \\        meta: o.headers.meta.timestamp
        \\    }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    const bc = &flow.continuations[0].pipeline[0].branch_constructor;
    
    // Check nested field access
    try testing.expectEqualStrings("content", bc.fields[0].name);
    try testing.expectEqualStrings("o.body.content.value", bc.fields[0].expression_str.?);
    
    try testing.expectEqualStrings("meta", bc.fields[1].name);
    try testing.expectEqualStrings("o.headers.meta.timestamp", bc.fields[1].expression_str.?);
}

test "complex expressions in branch constructor" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc complex_expr {
        \\    ~process(items)
        \\    | ok o |> stats { 
        \\        count: o.items.len + 1,
        \\        has_data: o.items.len > 0,
        \\        message: "processed"
        \\    }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    const bc = &flow.continuations[0].pipeline[0].branch_constructor;
    
    // Check complex expressions
    try testing.expectEqualStrings("count", bc.fields[0].name);
    try testing.expectEqualStrings("o.items.len + 1", bc.fields[0].expression_str.?);
    
    try testing.expectEqualStrings("has_data", bc.fields[1].name);
    try testing.expectEqualStrings("o.items.len > 0", bc.fields[1].expression_str.?);
    
    // String literal should not have expression_str
    try testing.expectEqualStrings("message", bc.fields[2].name);
    try testing.expect(bc.fields[2].expression_str == null);
}

test "mixed literals and expressions" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc mixed_fields {
        \\    ~query(db)
        \\    | ok o |> result { 
        \\        data: o.rows,
        \\        count: o.rows.len,
        \\        status: 200,
        \\        ok: true
        \\    }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    const bc = &flow.continuations[0].pipeline[0].branch_constructor;
    
    // Check mix of expressions and literals
    try testing.expectEqualStrings("data", bc.fields[0].name);
    try testing.expectEqualStrings("o.rows", bc.fields[0].expression_str.?);
    
    try testing.expectEqualStrings("count", bc.fields[1].name);
    try testing.expectEqualStrings("o.rows.len", bc.fields[1].expression_str.?);
    
    // Numeric and boolean literals
    try testing.expectEqualStrings("status", bc.fields[2].name);
    try testing.expect(bc.fields[2].expression_str == null);
    
    try testing.expectEqualStrings("ok", bc.fields[3].name);
    try testing.expect(bc.fields[3].expression_str == null);
}

test "single field shorthand" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc single_shorthand {
        \\    ~transform(input)
        \\    | ok o |> wrapped { o.value }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    const bc = &flow.continuations[0].pipeline[0].branch_constructor;
    
    // Shorthand should extract field name from expression
    try testing.expectEqual(@as(usize, 1), bc.fields.len);
    try testing.expectEqualStrings("value", bc.fields[0].name);
    try testing.expectEqualStrings("o.value", bc.fields[0].expression_str.?);
}

test "conflicting shapes across branches" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc conflicting_shapes {
        \\    ~fetch(url)
        \\    | ok o where o.type == "json" |> data { 
        \\        content: o.json,
        \\        format: "json"
        \\    }
        \\    | ok o where o.type == "xml" |> data { 
        \\        body: o.xml,
        \\        schema: o.xsd
        \\    }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    const flow = &proc.inline_flows[0];
    
    // Should have super_shape with conflict info
    try testing.expect(flow.super_shape != null);
    
    // Both continuations create "data" branch with different shapes
    const ss = flow.super_shape.?;
    var found_data = false;
    for (ss.branches) |branch| {
        if (std.mem.eql(u8, branch.name, "data")) {
            found_data = true;
            // The collector should have detected the different shapes
            // and chosen one (implementation dependent)
        }
    }
    try testing.expect(found_data);
}

test "branch constructor outside proc context fails" {
    const allocator = testing.allocator;
    
    // Branch constructors with expressions should not work in events
    const source =
        \\~event test_event : { value: Text } => 
        \\    | ok o |> success { data: o.value }
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const event = result.source_file.items[0].event_decl;
    
    // This should parse but the field should NOT have an expression
    // (expressions only allowed in proc context)
    const branch = &event.branches[0];
    if (branch.payload.fields.len > 0) {
        const field = &branch.payload.fields[0];
        try testing.expect(field.expression == null);
        try testing.expect(field.expression_str == null);
    }
}