const std = @import("std");
const ast = @import("ast");

/// Tap Code Generator - Generates code for Event Tap invocations
/// 
/// This module is responsible for generating the code that gets injected
/// at event transition points to invoke registered taps. It's part of the
/// metacircular compilation pipeline and runs as a compiler pass.
pub const TapCodegen = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator) !TapCodegen {
        return TapCodegen{
            .allocator = allocator,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 1024),
        };
    }
    
    pub fn deinit(self: *TapCodegen) void {
        self.buffer.deinit(self.allocator);
    }
    
    /// Generate code to invoke input taps for an event
    pub fn generateInputTapCalls(
        self: *TapCodegen,
        event_name: []const u8,
        input_taps: []const *const ast.EventTap,
        universal_taps: []const *const ast.EventTap,
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        
        // Generate calls for specific input taps
        for (input_taps) |tap| {
            try self.generateSingleTapCall(tap, event_name, .input);
        }
        
        // Generate calls for universal input taps
        for (universal_taps) |tap| {
            try self.generateUniversalTapCall(tap, event_name, .input);
        }
        
        return try self.buffer.toOwnedSlice(self.allocator);
    }
    
    /// Generate code to invoke output taps for an event
    pub fn generateOutputTapCalls(
        self: *TapCodegen,
        event_name: []const u8,
        output_taps: []const *const ast.EventTap,
        universal_taps: []const *const ast.EventTap,
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        
        // Generate calls for specific output taps
        for (output_taps) |tap| {
            try self.generateSingleTapCall(tap, event_name, .output);
        }
        
        // Generate calls for universal output taps
        for (universal_taps) |tap| {
            try self.generateUniversalTapCall(tap, event_name, .output);
        }
        
        return try self.buffer.toOwnedSlice(self.allocator);
    }
    
    /// Generate a static tap registry for runtime lookup
    pub fn generateTapRegistry(
        self: *TapCodegen,
        all_taps: []const *const ast.EventTap,
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        const writer = self.buffer.writer(self.allocator);
        
        // Generate the tap registry structure
        try writer.writeAll("// Event Tap Registry\n");
        try writer.writeAll("const TapRegistry = struct {\n");
        try writer.writeAll("    const TapEntry = struct {\n");
        try writer.writeAll("        source: ?[]const u8,\n");
        try writer.writeAll("        destination: ?[]const u8,\n");
        try writer.writeAll("        is_input: bool,\n");
        try writer.writeAll("        handler_fn: *const fn(transition: TransitionMetadata) void,\n");
        try writer.writeAll("    };\n\n");
        
        // Generate array of tap entries
        try writer.print("    pub const taps = [_]TapEntry{{\n", .{});
        
        for (all_taps, 0..) |tap, idx| {
            try writer.writeAll("        .{\n");
            
            // Source path
            if (tap.source) |src| {
                try writer.writeAll("            .source = \"");
                try self.writePath(src);
                try writer.writeAll("\",\n");
            } else {
                try writer.writeAll("            .source = null,\n");
            }
            
            // Destination path
            if (tap.destination) |dst| {
                try writer.writeAll("            .destination = \"");
                try self.writePath(dst);
                try writer.writeAll("\",\n");
            } else {
                try writer.writeAll("            .destination = null,\n");
            }
            
            // Input/output flag
            try writer.print("            .is_input = {},\n", .{tap.is_input_tap});
            
            // Handler function reference
            try writer.print("            .handler_fn = &tap_handler_{},\n", .{idx});
            
            try writer.writeAll("        },\n");
        }
        
        try writer.writeAll("    };\n");
        try writer.writeAll("};\n\n");
        
        // Generate individual tap handler functions
        for (all_taps, 0..) |tap, idx| {
            try self.generateTapHandlerFunction(tap, idx);
        }
        
        return try self.buffer.toOwnedSlice(self.allocator);
    }
    
    /// Generate the TransitionMetadata structure
    pub fn generateTransitionMetadata(self: *TapCodegen) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        const writer = self.buffer.writer(self.allocator);
        
        try writer.writeAll(
            \\// Transition metadata for Event Taps
            \\const TransitionMetadata = struct {
            \\    source: []const u8,       // Source event name
            \\    destination: []const u8,  // Destination event name  
            \\    branch: []const u8,        // Which branch was taken
            \\    duration_ns: u64,          // Execution time
            \\    timestamp: i64,            // When transition occurred
            \\    input_data: anytype,       // Input to the event
            \\    output_data: anytype,      // Output from the event
            \\};
            \\
            \\// Helper to invoke taps with metadata
            \\fn invokeTaps(
            \\    tap_type: enum { input, output },
            \\    event_name: []const u8,
            \\    data: anytype,
            \\) void {
            \\    const metadata = TransitionMetadata{
            \\        .source = if (tap_type == .output) event_name else "",
            \\        .destination = if (tap_type == .input) event_name else "",
            \\        .branch = "", // TODO: Extract branch name from data
            \\        .duration_ns = 0, // TODO: Measure if needed
            \\        .timestamp = std.time.milliTimestamp(),
            \\        .input_data = if (tap_type == .input) data else {},
            \\        .output_data = if (tap_type == .output) data else {},
            \\    };
            \\    
            \\    // Find and invoke matching taps
            \\    for (TapRegistry.taps) |tap| {
            \\        if (tap.is_input == (tap_type == .input)) {
            \\            // Check if this tap matches the event
            \\            const matches = if (tap_type == .input)
            \\                matchesTap(tap.destination, event_name)
            \\            else
            \\                matchesTap(tap.source, event_name);
            \\                
            \\            if (matches) {
            \\                tap.handler_fn(metadata);
            \\            }
            \\        }
            \\    }
            \\}
            \\
            \\fn matchesTap(tap_pattern: ?[]const u8, event_name: []const u8) bool {
            \\    if (tap_pattern) |pattern| {
            \\        return std.mem.eql(u8, pattern, event_name);
            \\    }
            \\    // null pattern means wildcard - matches everything
            \\    return true;
            \\}
            \\
        );
        
        return try self.buffer.toOwnedSlice(self.allocator);
    }
    
    // Private helper functions
    
    const TapType = enum { input, output };
    
    fn generateSingleTapCall(
        self: *TapCodegen,
        tap: *const ast.EventTap,
        event_name: []const u8,
        tap_type: TapType,
    ) !void {
        const writer = self.buffer.writer(self.allocator);
        
        // Generate comment
        try writer.print("    // {} tap: ", .{@tagName(tap_type)});
        if (tap.source) |src| {
            try self.writePath(src);
        } else {
            try writer.writeAll("*");
        }
        try writer.writeAll(" -> ");
        if (tap.destination) |dst| {
            try self.writePath(dst);
        } else {
            try writer.writeAll("*");
        }
        try writer.writeAll("\n");
        
        // Generate tap invocation
        try writer.writeAll("    {\n");
        try writer.print("        const tap_meta = TransitionMetadata{{\n", .{});
        try writer.print("            .source = \"{s}\",\n", .{if (tap_type == .output) event_name else ""});
        try writer.print("            .destination = \"{s}\",\n", .{if (tap_type == .input) event_name else ""});
        try writer.writeAll("            .branch = \"\", // TODO\n");
        try writer.writeAll("            .duration_ns = 0,\n");
        try writer.writeAll("            .timestamp = std.time.milliTimestamp(),\n");
        if (tap_type == .input) {
            try writer.writeAll("            .input_data = e,\n");
            try writer.writeAll("            .output_data = {},\n");
        } else {
            try writer.writeAll("            .input_data = {},\n");
            try writer.writeAll("            .output_data = result,\n");
        }
        try writer.writeAll("        };\n");
        
        // Generate continuation execution
        for (tap.continuations) |*cont| {
            try self.generateContinuation(cont);
        }
        
        try writer.writeAll("    }\n");
    }
    
    fn generateUniversalTapCall(
        self: *TapCodegen,
        tap: *const ast.EventTap,
        event_name: []const u8,
        tap_type: TapType,
    ) !void {
        const writer = self.buffer.writer(self.allocator);
        
        // Universal taps need special handling for transition binding
        try writer.print("    // Universal {} tap\n", .{@tagName(tap_type)});
        try writer.writeAll("    {\n");
        try writer.writeAll("        const transition = TransitionMetadata{\n");
        try writer.print("            .source = \"{s}\",\n", .{if (tap_type == .output) event_name else "*"});
        try writer.print("            .destination = \"{s}\",\n", .{if (tap_type == .input) event_name else "*"});
        try writer.writeAll("            .branch = \"\",\n");
        try writer.writeAll("            .duration_ns = 0,\n");
        try writer.writeAll("            .timestamp = std.time.milliTimestamp(),\n");
        if (tap_type == .input) {
            try writer.writeAll("            .input_data = e,\n");
            try writer.writeAll("            .output_data = {},\n");
        } else {
            try writer.writeAll("            .input_data = {},\n");
            try writer.writeAll("            .output_data = result,\n");
        }
        try writer.writeAll("        };\n");
        
        // Execute continuation with transition binding
        for (tap.continuations) |*cont| {
            try self.generateContinuation(cont);
        }
        
        try writer.writeAll("    }\n");
    }
    
    fn generateTapHandlerFunction(
        self: *TapCodegen,
        tap: *const ast.EventTap,
        index: usize,
    ) !void {
        const writer = self.buffer.writer(self.allocator);
        
        try writer.print("fn tap_handler_{}(metadata: TransitionMetadata) void {{\n", .{index});
        
        // Generate the tap continuation logic
        if (tap.continuations.len > 0) {
            try writer.writeAll("    // Execute tap continuation\n");
            for (tap.continuations) |*cont| {
                // TODO: Generate actual continuation execution
                _ = cont;
            }
            try writer.writeAll("    _ = metadata;\n");
        } else {
            try writer.writeAll("    _ = metadata;\n");
        }
        
        try writer.writeAll("}\n\n");
    }
    
    fn generateContinuation(self: *TapCodegen, continuation: *const ast.Continuation) !void {
        const writer = self.buffer.writer(self.allocator);
        
        // Generate continuation execution
        try writer.writeAll("        // Execute tap continuation\n");
        
        // Check for where clause condition
        if (continuation.condition_expr) |cond_expr| {
            // Generate the where clause check at the emission point!
            try writer.writeAll("        if (");
            
            // Use expression codegen to generate the condition
            const expression_codegen = @import("expression_codegen");
            var expr_gen = expression_codegen.ExpressionCodegen.init(self.allocator);
            defer expr_gen.deinit();
            
            const condition_code = try expr_gen.generate(cond_expr);
            defer self.allocator.free(condition_code);
            
            try writer.writeAll(condition_code);
            try writer.writeAll(") {\n");
            
            // Generate the pipeline inside the if block
            try writer.writeAll("    ");  // Extra indent for if body
        }
        
        // Handle the continuation pipeline
        for (continuation.pipeline) |step| {
            // Add extra indentation if we're inside a where clause if block
            const indent = if (continuation.condition_expr != null) "            " else "        ";
            
            switch (step) {
                .invocation => |inv| {
                    try writer.writeAll(indent);
                    try writer.writeAll("const tap_out = ");
                    try self.writePath(inv.path);
                    try writer.writeAll(".handler(.{");
                    
                    // Generate arguments
                    for (inv.args, 0..) |arg, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print(" .{s} = {s}", .{ arg.name, arg.value });
                    }
                    
                    try writer.writeAll(" });\n");
                },
                .terminal => {
                    try writer.writeAll(indent);
                    try writer.writeAll("// Terminal continuation\n");
                },
                .label_apply => |label| {
                    try writer.writeAll(indent);
                    try writer.print("// Apply label: {s}\n", .{label});
                },
            }
        }
        
        // Close the if block if we had a where clause
        if (continuation.condition_expr != null) {
            try writer.writeAll("        }\n");
        }
        
        // Handle nested continuations if any
        for (continuation.nested) |nested| {
            try writer.print("        switch (tap_out) {{\n", .{});
            try writer.print("            .{s} => |{s}| {{\n", .{ 
                nested.branch, 
                nested.binding orelse "_" 
            });
            
            // Generate nested continuation
            try self.generateContinuation(nested);
            
            try writer.writeAll("            },\n");
            try writer.writeAll("            else => {},\n");
            try writer.writeAll("        }\n");
        }
    }
    
    fn writePath(self: *TapCodegen, path: ast.DottedPath) !void {
        const writer = self.buffer.writer(self.allocator);
        for (path.segments, 0..) |segment, i| {
            if (i > 0) try writer.writeAll(".");
            try writer.writeAll(segment);
        }
    }
};