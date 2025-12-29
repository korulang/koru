// Test: Bootstrap Compiler Constraint Validation
// Verifies that the compiler bootstrap library correctly rejects inline flows
// while normal code and user compiler extensions can use them freely

const std = @import("std");
const testing = std.testing;
const Parser = @import("parser").Parser;

test "bootstrap library rejects inline flows in procs" {
    const allocator = testing.allocator;
    
    const source = 
        \\// Proc with inline flow
        \\~proc compiler.emit.test {
        \\    const data = prepare();
        \\    
        \\    // This inline flow should be rejected in bootstrap
        \\    const result = ~validate(data: data)
        \\    | valid v |> success { v }
        \\    | invalid |> error {}
        \\    
        \\    return result;
        \\}
    ;
    
    // Parse as compiler bootstrap library
    var parser = try Parser.init(allocator, source, "test_bootstrap.kz");
    parser.is_compiler_library = true;  // Mark as bootstrap library
    defer parser.deinit();
    
    // Should fail with CompilerProcCannotUseInlineFlows
    const result = parser.parse();
    try testing.expectError(error.CompilerProcCannotUseInlineFlows, result);
    
    // Verify error message is helpful
    try testing.expect(parser.reporter.hasErrors());
    const errors = parser.reporter.errors.items;
    try testing.expect(errors.len > 0);
    try testing.expect(std.mem.indexOf(u8, errors[0].message, "bootstrap library") != null);
}

test "normal files allow inline flows in any proc" {
    const allocator = testing.allocator;
    
    const source = 
        \\// Same proc but in normal file
        \\~proc compiler.emit.test {
        \\    const data = prepare();
        \\    
        \\    // This is fine in normal files
        \\    const result = ~validate(data: data)
        \\    | valid v |> success { v }
        \\    | invalid |> error {}
        \\    
        \\    return result;
        \\}
    ;
    
    // Parse as normal file (default)
    var parser = try Parser.init(allocator, source, "test_normal.kz");
    // is_compiler_library defaults to false
    defer parser.deinit();
    
    // Should succeed
    const result = try parser.parse();
    var mutable_result = result;
    defer mutable_result.deinit();
    
    // Verify the proc was parsed correctly
    try testing.expect(result.source_file.items.len == 1);
    const item = result.source_file.items[0];
    try testing.expect(item == .proc_decl);
    
    // Verify inline flows were extracted
    const proc = item.proc_decl;
    try testing.expect(proc.inline_flows.len > 0);
}

test "user compiler extensions can use inline flows" {
    const allocator = testing.allocator;
    
    const source = 
        \\// User-defined compiler extension
        \\~proc compiler.custom.transform {
        \\    const ast = e.ast;
        \\    
        \\    // User extensions CAN use all Koru features
        \\    const analyzed = ~analyze(ast: ast)
        \\    | analyzed a |> continue { ast: a }
        \\    | failed |> original { ast: ast }
        \\    
        \\    // Can even have multiple inline flows
        \\    const optimized = ~optimize(ast: analyzed)
        \\    | optimized o |> final { ast: o }
        \\    | unchanged |> keep { ast: analyzed }
        \\    
        \\    return optimized;
        \\}
    ;
    
    // Parse as normal user code
    var parser = try Parser.init(allocator, source, "user_extension.kz");
    parser.is_compiler_library = false;
    defer parser.deinit();
    
    // Should succeed even though it's compiler.* namespace
    const result = try parser.parse();
    var mutable_result = result;
    defer mutable_result.deinit();
    
    // Verify the proc was parsed and allowed inline flows
    // The important part is that parsing succeeded with inline flows present
    try testing.expect(result.source_file.items.len == 1);
    try testing.expect(result.source_file.items[0] == .proc_decl);
}

test "bootstrap library allows procs without inline flows" {
    const allocator = testing.allocator;
    
    const source = 
        \\// Pure Zig proc - allowed in bootstrap
        \\~proc compiler.emit.zig {
        \\    const buffer: [1024]u8 = undefined;
        \\    var pos: usize = 0;
        \\    
        \\    // Pure Zig code is fine
        \\    pos = writeStr(&buffer, pos, "// Generated\\n");
        \\    
        \\    return .{ .emitted = .{ .code = buffer[0..pos] } };
        \\}
    ;
    
    // Parse as bootstrap library
    var parser = try Parser.init(allocator, source, "bootstrap.kz");
    parser.is_compiler_library = true;
    defer parser.deinit();
    
    // Should succeed - no inline flows
    const result = try parser.parse();
    var mutable_result = result;
    defer mutable_result.deinit();
    
    // Verify proc was parsed
    try testing.expect(result.source_file.items.len == 1);
    const proc = result.source_file.items[0].proc_decl;
    try testing.expect(proc.inline_flows.len == 0);
}

test "bootstrap detects flow invocations in proc body" {
    const allocator = testing.allocator;
    
    const source = 
        \\~proc compiler.test {
        \\    const x = 10;
        \\    // Sneaky inline flow in body
        \\    const y = process();
        \\    ~doSomething(val: y);
        \\    return x;
        \\}
    ;
    
    // Parse as bootstrap library
    var parser = try Parser.init(allocator, source, "bootstrap.kz");
    parser.is_compiler_library = true;
    defer parser.deinit();
    
    // Should fail - has flow invocation
    const result = parser.parse();
    try testing.expectError(error.CompilerProcCannotUseInlineFlows, result);
}

test "imported libraries are not restricted" {
    const allocator = testing.allocator;
    
    // Simulate parsing a library that the compiler might import
    const source = 
        \\// IO library with full Koru features
        \\~proc io.read {
        \\    const file = getFile();
        \\    
        \\    const content = ~readFile(path: file)
        \\    | success data |> content { data }
        \\    | failure |> empty {}
        \\    
        \\    return content;
        \\}
    ;
    
    // Parse as regular library (not bootstrap)
    var parser = try Parser.init(allocator, source, "io.kz");
    parser.is_compiler_library = false;  // Regular library
    defer parser.deinit();
    
    // Should succeed
    const result = try parser.parse();
    var mutable_result = result;
    defer mutable_result.deinit();
    
    try testing.expect(result.source_file.items.len == 1);
}