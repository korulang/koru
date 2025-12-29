const std = @import("std");
const Parser = @import("parser.zig").Parser;
const ast = @import("ast.zig");

test "parser captures .call suffix in proc body" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~proc test.func {
        \\    const helper = struct {
        \\        fn call() void {}
        \\    }.call;
        \\    helper();
        \\}
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    const result = try parser.parse();
    defer result.deinit(allocator);
    
    // Find the proc
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                // The proc body should contain the full ".call;" suffix
                std.debug.print("\n=== PROC BODY ===\n{s}\n=== END ===\n", .{proc.body});
                
                // This should pass but currently fails!
                try std.testing.expect(std.mem.indexOf(u8, proc.body, ".call;") != null);
                return;
            },
            else => {},
        }
    }
    
    try std.testing.expect(false); // Should have found a proc
}

test "parser captures multiline .call suffix" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~proc test.multiline {
        \\    const helper = struct {
        \\        fn call() void {
        \\            // Some code
        \\        }
        \\    }.call;
        \\}
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    const result = try parser.parse();
    defer result.deinit(allocator);
    
    // Find the proc
    for (result.source_file.items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                std.debug.print("\n=== MULTILINE PROC BODY ===\n{s}\n=== END ===\n", .{proc.body});
                
                // Check that it ends with .call;
                const trimmed = std.mem.trimRight(u8, proc.body, " \n\r\t");
                try std.testing.expect(std.mem.endsWith(u8, trimmed, ".call;"));
                return;
            },
            else => {},
        }
    }
    
    try std.testing.expect(false); // Should have found a proc
}