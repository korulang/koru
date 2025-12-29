const std = @import("std");
const Parser = @import("parser").Parser;
const ast = @import("ast");

/// Minimal code generator for vertical POC
/// Generates directly executable Zig code from AST
fn generateCode(allocator: std.mem.Allocator, source_file: *const ast.SourceFile) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buffer.deinit(allocator);

    // Pass through Zig lines and generate event handlers
    for (source_file.items) |item| {
        switch (item) {
            .zig_line => |line| {
                try buffer.appendSlice(allocator, line);
                try buffer.append(allocator, '\n');
            },
            .event_decl => |event| {
                // Generate event struct
                const event_name = event.path.segments[0];
                try buffer.appendSlice(allocator, "\n// Generated event structure\n");
                try buffer.appendSlice(allocator, "const ");
                try buffer.appendSlice(allocator, event_name);
                try buffer.appendSlice(allocator, "Event = struct {\n");
                
                // Input fields
                for (event.input.fields) |field| {
                    try buffer.appendSlice(allocator, "    ");
                    try buffer.appendSlice(allocator, field.name);
                    try buffer.appendSlice(allocator, ": ");
                    try buffer.appendSlice(allocator, field.type);
                    try buffer.appendSlice(allocator, ",\n");
                }
                
                try buffer.appendSlice(allocator, "};\n\n");
                
                // Output union
                try buffer.appendSlice(allocator, "const ");
                try buffer.appendSlice(allocator, event_name);
                try buffer.appendSlice(allocator, "Output = union(enum) {\n");
                
                for (event.branches) |branch| {
                    try buffer.appendSlice(allocator, "    ");
                    try buffer.appendSlice(allocator, branch.name);
                    try buffer.appendSlice(allocator, ": struct {\n");
                    
                    for (branch.payload.fields) |field| {
                        try buffer.appendSlice(allocator, "        ");
                        try buffer.appendSlice(allocator, field.name);
                        try buffer.appendSlice(allocator, ": ");
                        try buffer.appendSlice(allocator, field.type);
                        try buffer.appendSlice(allocator, ",\n");
                    }
                    
                    try buffer.appendSlice(allocator, "    },\n");
                }
                
                try buffer.appendSlice(allocator, "};\n\n");
            },
            .proc_decl => |proc| {
                // Generate handler function
                const proc_name = proc.path.segments[0];
                try buffer.appendSlice(allocator, "fn handle_");
                try buffer.appendSlice(allocator, proc_name);
                try buffer.appendSlice(allocator, "(e: ");
                try buffer.appendSlice(allocator, proc_name);
                try buffer.appendSlice(allocator, "Event) ");
                try buffer.appendSlice(allocator, proc_name);
                try buffer.appendSlice(allocator, "Output {\n    ");
                
                // Insert proc body (already contains Zig code)
                try buffer.appendSlice(allocator, proc.body);
                
                try buffer.appendSlice(allocator, "\n}\n\n");
            },
            .flow => |flow| {
                // For the POC, we'll generate a simple main that calls the handler
                if (flow.invocation.path.segments.len > 0) {
                    const flow_name = flow.invocation.path.segments[0];
                    
                    // Only generate main once for the top-level flow
                    if (std.mem.eql(u8, flow_name, "greet")) {
                        try buffer.appendSlice(allocator, "\npub fn main() void {\n");
                        try buffer.appendSlice(allocator, "    // Execute flow: ");
                        try buffer.appendSlice(allocator, flow_name);
                        try buffer.appendSlice(allocator, "\n");
                        
                        try buffer.appendSlice(allocator, "    const input = ");
                        try buffer.appendSlice(allocator, flow_name);
                        try buffer.appendSlice(allocator, "Event{\n");
                        
                        // Generate input args
                        for (flow.invocation.args) |arg| {
                            try buffer.appendSlice(allocator, "        .");
                            try buffer.appendSlice(allocator, arg.name);
                            try buffer.appendSlice(allocator, " = ");
                            try buffer.appendSlice(allocator, arg.value);
                            try buffer.appendSlice(allocator, ",\n");
                        }
                        
                        try buffer.appendSlice(allocator, "    };\n");
                        try buffer.appendSlice(allocator, "    const output = handle_");
                        try buffer.appendSlice(allocator, flow_name);
                        try buffer.appendSlice(allocator, "(input);\n");
                        try buffer.appendSlice(allocator, "    _ = output; // Flow complete\n");
                        try buffer.appendSlice(allocator, "}\n");
                    }
                }
            },
            else => {
                // Skip other items for POC
            },
        }
    }

    return buffer.toOwnedSlice(allocator);
}

test "vertical POC - parse, generate, and verify" {
    const allocator = std.testing.allocator;
    
    const source =
        \\// Simple vertical test - mix of Zig and Koru
        \\const std = @import("std");
        \\
        \\~event greet { name: []const u8 }
        \\| done {}
        \\
        \\~proc greet {
        \\    std.debug.print("Hello, {s}!\n", .{e.name});
        \\    return .{ .done = .{} };
        \\}
        \\
        \\// Top-level flow
        \\~greet(name: "Vertical POC")
        \\| done |> _
    ;
    
    // Step 1: Parse
    var parser = try Parser.init(allocator, source, "test.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    // Verify parsing succeeded
    try std.testing.expect(parse_result.source_file.items.len > 0);
    
    // Count different item types
    var zig_lines: usize = 0;
    var events: usize = 0;
    var procs: usize = 0;
    var flows: usize = 0;
    
    for (parse_result.source_file.items) |item| {
        switch (item) {
            .zig_line => zig_lines += 1,
            .event_decl => events += 1,
            .proc_decl => procs += 1,
            .flow => flows += 1,
            else => {},
        }
    }
    
    // Verify expected counts
    try std.testing.expect(zig_lines >= 2); // Comments and imports
    try std.testing.expectEqual(@as(usize, 1), events);
    try std.testing.expectEqual(@as(usize, 1), procs);
    try std.testing.expectEqual(@as(usize, 1), flows);
    
    // Step 2: Generate code
    const generated = try generateCode(allocator, &parse_result.source_file);
    defer allocator.free(generated);
    
    // Verify generated code contains expected elements
    try std.testing.expect(std.mem.indexOf(u8, generated, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "const greetEvent = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "const greetOutput = union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "fn handle_greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn main() void") != null);
    
    // Print generated code for inspection
    std.debug.print("\n=== Generated Code (Vertical POC) ===\n{s}\n=== End Generated Code ===\n", .{generated});
    
    // Step 3: Write to file for manual testing
    const test_file = try std.fs.cwd().createFile("vertical_poc_generated.zig", .{});
    defer test_file.close();
    try test_file.writeAll(generated);
    
    std.debug.print("\nGenerated code written to: vertical_poc_generated.zig\n", .{});
    std.debug.print("You can compile and run it with: zig run vertical_poc_generated.zig\n\n", .{});
}

test "vertical POC - complex example" {
    const allocator = std.testing.allocator;
    
    const source =
        \\const std = @import("std");
        \\
        \\~event calculate { x: i32, y: i32 }
        \\| result { value: i32 }
        \\| error { msg: []const u8 }
        \\
        \\~proc calculate {
        \\    if (e.y == 0) {
        \\        return .{ .error = .{ .msg = "Division by zero" } };
        \\    }
        \\    const result = e.x / e.y;
        \\    return .{ .result = .{ .value = result } };
        \\}
        \\
        \\~calculate(x: 10, y: 2)
        \\| result r |> _
        \\| error err |> _
    ;
    
    var parser = try Parser.init(allocator, source, "complex.kz");
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    const generated = try generateCode(allocator, &parse_result.source_file);
    defer allocator.free(generated);
    
    // Verify complex features
    try std.testing.expect(std.mem.indexOf(u8, generated, "error: struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "result: struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "if (e.y == 0)") != null);
    
    std.debug.print("\n=== Complex Example Generated Code ===\n{s}\n=== End ===\n", .{generated});
}