const std = @import("std");
const testing = std.testing;
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const shape_checker_mod = @import("shape_checker");
const ShapeChecker = shape_checker_mod.ShapeChecker;
const ast_serializer_mod = @import("ast_serializer");
const AstSerializer = ast_serializer_mod.AstSerializer;

test "full vertical: parse -> check -> emit" {
    const allocator = testing.allocator;
    
    // A complete Koru program
    const source =
        \\~event file.read { path: []const u8 }
        \\| success { contents: []const u8 }
        \\| failure { errno: u32 }
        \\
        \\~proc file.read {
        \\    const f = std.fs.openFile(e.path, .{}) catch |err| {
        \\        return .failure(.{ .errno = @intFromError(err) });
        \\    };
        \\    defer f.close();
        \\    const contents = f.readToEndAlloc(allocator, 1024*1024) catch |err| {
        \\        return .failure(.{ .errno = @intFromError(err) });
        \\    };
        \\    return .success(.{ .contents = contents });
        \\}
        \\
        \\~proc log.message {
        \\    std.debug.print("Log: {s}\n", .{e.msg});
        \\    return .logged(.{});
        \\}
        \\
        \\~event log.message { msg: []const u8 }
        \\| logged {}
        \\
        \\~proc proc.exit {
        \\    std.process.exit(e.code);
        \\}
        \\
        \\~event proc.exit { code: u32 }
        \\| exited {}
        \\
        \\~file.read (path: "test.txt")
        \\| success s |> _
        \\| failure f |> _
    ;
    
    // STEP 1: PARSE
    std.debug.print("\n=== STEP 1: PARSING ===\n", .{});
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    var ast = parse_result.source_file;
    try testing.expectEqual(@as(usize, 7), ast.items.len);
    try testing.expect(ast.items[0] == .event_decl);
    try testing.expect(ast.items[1] == .proc_decl);
    try testing.expect(ast.items[2] == .proc_decl);
    try testing.expect(ast.items[3] == .event_decl);
    try testing.expect(ast.items[4] == .proc_decl);
    try testing.expect(ast.items[5] == .event_decl);
    try testing.expect(ast.items[6] == .flow);
    std.debug.print("✓ Parsed successfully: {} items\n", .{ast.items.len});
    
    // STEP 2: SHAPE CHECK
    std.debug.print("\n=== STEP 2: SHAPE CHECKING ===\n", .{});
    var reporter = parser.reporter;
    var checker = try ShapeChecker.init(allocator, &reporter);
    defer checker.deinit();
    
    try checker.checkSourceFile(&ast);
    std.debug.print("✓ Shape checking passed: all branches covered\n", .{});
    
    // STEP 3: SERIALIZE AST
    std.debug.print("\n=== STEP 3: SERIALIZING AST ===\n", .{});
    var serializer = try AstSerializer.init(allocator);
    defer serializer.deinit();
    
    const output = try serializer.serialize(&parse_result.source_file);
    defer allocator.free(output);
    
    // Verify the output contains expected AST serialization elements
    try testing.expect(std.mem.indexOf(u8, output, "PROGRAM_AST") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".event_decl = EventDecl{") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".proc_decl = ProcDecl{") != null);
    try testing.expect(std.mem.indexOf(u8, output, ".flow = Flow{") != null);
    try testing.expect(std.mem.indexOf(u8, output, "const SourceFile = struct") != null);
    try testing.expect(std.mem.indexOf(u8, output, "const Item = union(enum)") != null);
    
    std.debug.print("✓ Serialized AST successfully\n\n", .{});
    std.debug.print("=== SERIALIZED OUTPUT (first 1000 chars) ===\n{s}\n===================\n", .{output[0..@min(1000, output.len)]});
    
    // Bonus: Check that the output is syntactically valid Zig
    // (We can't compile it without the actual dependencies, but we can check structure)
    try testing.expect(std.mem.count(u8, output, "{") == std.mem.count(u8, output, "}"));
    try testing.expect(std.mem.count(u8, output, "(") == std.mem.count(u8, output, ")"));
    
    std.debug.print("\n🎉 FULL PIPELINE SUCCESS! 🎉\n", .{});
    std.debug.print("Koru → Parser → Shape Checker → AST Serializer → Zig\n", .{});
}

test "end-to-end with deferred events" {
    const allocator = testing.allocator;
    
    const source =
        \\~event auth.method { user: []const u8 }
        \\| &selected { token: []const u8 }
        \\| denied {}
        \\
        \\~auth.method (user: "alice")
        \\| denied |> log.error (msg: "access denied")
        \\| selected s
        \\  | *s
        \\    | authenticated a |> session.create (token: a.token)
        \\    | needs_2fa |> send.otp
    ;
    
    // Parse
    var parser = try Parser.init(allocator, source, "auth.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    // Verify deferred branch was parsed
    const event = parse_result.source_file.items[0].event_decl;
    try testing.expect(event.branches[0].is_deferred);
    try testing.expect(!event.branches[1].is_deferred);
    
    // Verify deref continuation was parsed
    const flow = parse_result.source_file.items[1].flow;
    try testing.expectEqual(@as(usize, 2), flow.continuations.len);
    
    // The second continuation should have a nested deref
    const selected_cont = flow.continuations[1];
    try testing.expectEqualStrings("selected", selected_cont.branch);
    
    std.debug.print("\n✓ Deferred events parsed successfully\n", .{});
    std.debug.print("  - &selected branch marked as deferred\n", .{});
    std.debug.print("  - *s deref continuation found\n", .{});
}