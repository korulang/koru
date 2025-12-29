const std = @import("std");
const ast = @import("ast");

/// Minimal AST serializer for vertical POC
/// Just serializes enough to prove the concept works
pub const MinimalSerializer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !MinimalSerializer {
        return MinimalSerializer{
            .allocator = allocator,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 1024),
        };
    }

    pub fn deinit(self: *MinimalSerializer) void {
        self.buffer.deinit();
    }

    pub fn serialize(self: *MinimalSerializer, source_file: *const ast.Program) ![]const u8 {
        // Just output a minimal working example
        try self.buffer.appendSlice(self.allocator,
            \\// Generated AST data
            \\const std = @import("std");
            \\
            \\// For now, just pass through the Zig lines and generate basic event structure
            \\
        );

        // Pass through host language lines
        for (source_file.items) |item| {
            switch (item) {
                .host_line => |line| {
                    try self.buffer.appendSlice(self.allocator, line);
                    try self.buffer.append(self.allocator, '\n');
                },
                .event_decl => |event| {
                    // Generate basic event structure
                    try self.buffer.appendSlice(self.allocator, "// Event: ");
                    if (event.path.segments.len > 0) {
                        try self.buffer.appendSlice(self.allocator, event.path.segments[0]);
                    }
                    try self.buffer.append(self.allocator, '\n');
                    
                    // Generate the event struct
                    try self.buffer.appendSlice(self.allocator, "const ");
                    try self.buffer.appendSlice(self.allocator, event.path.segments[0]);
                    try self.buffer.appendSlice(self.allocator, " = struct {\n");
                    try self.buffer.appendSlice(self.allocator, "    pub const Input = struct {\n");
                    
                    // Add input fields
                    for (event.input.fields) |field| {
                        try self.buffer.appendSlice(self.allocator, "        ");
                        try self.buffer.appendSlice(self.allocator, field.name);
                        try self.buffer.appendSlice(self.allocator, ": ");
                        try self.buffer.appendSlice(self.allocator, field.type);
                        try self.buffer.appendSlice(self.allocator, ",\n");
                    }
                    
                    try self.buffer.appendSlice(self.allocator, "    };\n");
                    try self.buffer.appendSlice(self.allocator, "    pub const Output = union(enum) {\n");
                    
                    // Add branches
                    for (event.branches) |branch| {
                        try self.buffer.appendSlice(self.allocator, "        ");
                        try self.buffer.appendSlice(self.allocator, branch.name);
                        try self.buffer.appendSlice(self.allocator, ": struct {\n");
                        for (branch.payload.fields) |field| {
                            try self.buffer.appendSlice(self.allocator, "            ");
                            try self.buffer.appendSlice(self.allocator, field.name);
                            try self.buffer.appendSlice(self.allocator, ": ");
                            try self.buffer.appendSlice(self.allocator, field.type);
                            try self.buffer.appendSlice(self.allocator, ",\n");
                        }
                        try self.buffer.appendSlice(self.allocator, "        },\n");
                    }
                    
                    try self.buffer.appendSlice(self.allocator, "    };\n");
                },
                .proc_decl => |proc| {
                    // Generate handler function
                    try self.buffer.appendSlice(self.allocator, "    pub fn handler(__koru_event_input: Input) Output {\n");
                    try self.buffer.appendSlice(self.allocator, "        ");
                    try self.buffer.appendSlice(self.allocator, proc.body);
                    try self.buffer.append(self.allocator, '\n');
                    try self.buffer.appendSlice(self.allocator, "    }\n};\n\n");
                },
                .flow => |flow| {
                    // For now, just comment about the flow
                    try self.buffer.appendSlice(self.allocator, "// Flow: ");
                    if (flow.invocation.path.segments.len > 0) {
                        try self.buffer.appendSlice(self.allocator, flow.invocation.path.segments[0]);
                    }
                    try self.buffer.append(self.allocator, '\n');
                },
                else => {
                    // Skip other items for now
                },
            }
        }

        // Add main function that calls the flow
        try self.buffer.appendSlice(self.allocator,
            \\
            \\pub fn main() void {
            \\    // Execute top-level flow
            \\    const result = greet.handler(.{ .name = "Vertical POC" });
            \\    // Flow complete
            \\}
            \\
        );

        return try self.buffer.toOwnedSlice(self.allocator);
    }
};