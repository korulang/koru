const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const ast = @import("ast");

test "extract inline flow with return pattern" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc test_return {
        \\    return ~http.get(url)
        \\    | ok o |> success { data: o }
        \\    | error e |> failed { msg: e }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should extract the inline flow
    try testing.expect(proc.inline_flows.len > 0);
    
    // Modified body should have "return __inline_flow_1()"
    try testing.expect(std.mem.indexOf(u8, proc.body, "return __inline_flow_") != null);
    
    std.debug.print("\n=== Extracted Flows: {} ===\n", .{proc.inline_flows.len});
    std.debug.print("Modified body:\n{s}\n", .{proc.body});
}

test "extract inline flow with const assignment" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc test_const {
        \\    const result = ~validate(input)
        \\    | valid v |> success { value: v }
        \\    | invalid i |> error { reason: i }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should extract the inline flow
    try testing.expect(proc.inline_flows.len > 0);
    
    // Modified body should preserve "const result = "
    try testing.expect(std.mem.indexOf(u8, proc.body, "const result = __inline_flow_") != null);
    
    std.debug.print("\n=== Extracted Flows: {} ===\n", .{proc.inline_flows.len});
    std.debug.print("Modified body:\n{s}\n", .{proc.body});
}

test "extract direct inline flow" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc test_direct {
        \\    ~transform(data)
        \\    | done d |> success { result: d }
        \\    | error e |> failed { error: e }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should extract the inline flow
    try testing.expect(proc.inline_flows.len > 0);
    
    // Modified body should have "const result_1 = __inline_flow_1()"
    try testing.expect(std.mem.indexOf(u8, proc.body, "const result_") != null);
    
    std.debug.print("\n=== Extracted Flows: {} ===\n", .{proc.inline_flows.len});
    std.debug.print("Modified body:\n{s}\n", .{proc.body});
}

test "extract multiple inline flows" {
    const allocator = testing.allocator;
    
    const source =
        \\~proc test_multiple {
        \\    const a = ~first(x)
        \\    | ok o |> o.value
        \\    | err e |> 0
        \\    
        \\    const b = ~second(y)
        \\    | ok o |> o.value
        \\    | err e |> 0
        \\    
        \\    return ~combine(a, b)
        \\    | result r |> success { total: r }
        \\    | error e |> failed { reason: e }
        \\}
    ;
    
    var p = try parser.Parser.init(allocator, source, "test.kz");
    defer p.deinit();
    
    var result = try p.parse();
    defer result.deinit();
    
    const proc = result.source_file.items[0].proc_decl;
    
    // Should extract all three inline flows
    try testing.expectEqual(@as(usize, 3), proc.inline_flows.len);
    
    // Modified body should have all replacements
    try testing.expect(std.mem.indexOf(u8, proc.body, "const a = __inline_flow_1") != null);
    try testing.expect(std.mem.indexOf(u8, proc.body, "const b = __inline_flow_2") != null);
    try testing.expect(std.mem.indexOf(u8, proc.body, "return __inline_flow_3") != null);
    
    std.debug.print("\n=== Extracted Flows: {} ===\n", .{proc.inline_flows.len});
    std.debug.print("Modified body:\n{s}\n", .{proc.body});
}