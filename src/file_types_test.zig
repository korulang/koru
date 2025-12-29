const std = @import("std");
const Parser = @import("parser").Parser;
const AstSerializer = @import("ast_serializer").AstSerializer;

test "parse File and EmbedFile types" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event test_files {
        \\    compile_only: File,
        \\    runtime_data: EmbedFile,
        \\    normal_field: []const u8
        \\}
        \\| processed {}
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var result = try parser.parse();
    defer result.deinit();
    
    // Verify we have one event
    try std.testing.expectEqual(@as(usize, 1), result.source_file.items.len);
    
    const item = result.source_file.items[0];
    try std.testing.expect(item == .event_decl);
    
    const event = item.event_decl;
    try std.testing.expectEqual(@as(usize, 3), event.input.fields.len);
    
    // Check first field (File type)
    const file_field = event.input.fields[0];
    try std.testing.expectEqualStrings("compile_only", file_field.name);
    try std.testing.expectEqualStrings("File", file_field.type);
    try std.testing.expect(file_field.is_file == true);
    try std.testing.expect(file_field.is_embed_file == false);
    try std.testing.expect(file_field.is_source == false);

    // Check second field (EmbedFile type)
    const embed_field = event.input.fields[1];
    try std.testing.expectEqualStrings("runtime_data", embed_field.name);
    try std.testing.expectEqualStrings("EmbedFile", embed_field.type);
    try std.testing.expect(embed_field.is_file == false);
    try std.testing.expect(embed_field.is_embed_file == true);
    try std.testing.expect(embed_field.is_source == false);

    // Check third field (normal type)
    const normal_field = event.input.fields[2];
    try std.testing.expectEqualStrings("normal_field", normal_field.name);
    try std.testing.expectEqualStrings("[]const u8", normal_field.type);
    try std.testing.expect(normal_field.is_file == false);
    try std.testing.expect(normal_field.is_embed_file == false);
    try std.testing.expect(normal_field.is_source == false);
}

test "serialize File and EmbedFile types" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event loader {
        \\    config: File,
        \\    asset: EmbedFile
        \\}
        \\| loaded {}
        \\
        \\~proc loader {
        \\    return .{ .loaded = .{} };
        \\}
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    // Serialize the AST
    var serializer = try AstSerializer.init(allocator);
    defer serializer.deinit();
    
    const serialized = try serializer.serialize(&parse_result.source_file);
    defer allocator.free(serialized);
    
    // Verify serialized output contains the file type markers
    try std.testing.expect(std.mem.indexOf(u8, serialized, ".is_file = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, ".is_file = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, ".is_embed_file = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, ".is_embed_file = false") != null);
    
    // Verify the Field struct definition includes is_embed_file
    try std.testing.expect(std.mem.indexOf(u8, serialized, "is_embed_file: bool,") != null);
}

test "File and EmbedFile with other special types" {
    const allocator = std.testing.allocator;

    const source =
        \\~event mixed {
        \\    src: Source,
        \\    file: File,
        \\    embed: EmbedFile,
        \\    normal: i32
        \\}
        \\| done {}
    ;

    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();

    var result = try parser.parse();
    defer result.deinit();

    const event = result.source_file.items[0].event_decl;
    try std.testing.expectEqual(@as(usize, 4), event.input.fields.len);

    // Verify each field has correct type flags
    const fields = event.input.fields;

    // Source field
    try std.testing.expect(fields[0].is_source == true);
    try std.testing.expect(fields[0].is_file == false);
    try std.testing.expect(fields[0].is_embed_file == false);

    // File field
    try std.testing.expect(fields[1].is_source == false);
    try std.testing.expect(fields[1].is_file == true);
    try std.testing.expect(fields[1].is_embed_file == false);

    // EmbedFile field
    try std.testing.expect(fields[2].is_source == false);
    try std.testing.expect(fields[2].is_file == false);
    try std.testing.expect(fields[2].is_embed_file == true);

    // Normal field
    try std.testing.expect(fields[3].is_source == false);
    try std.testing.expect(fields[3].is_file == false);
    try std.testing.expect(fields[3].is_embed_file == false);
}