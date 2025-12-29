const std = @import("std");
const ast = @import("ast");
const transform = @import("ast_transform");
const visitor = @import("ast_visitor");

/// Transformation: Inline Small Events
/// 
/// This transformation finds events with small proc implementations and inlines
/// them at their call sites. This eliminates function call overhead for trivial
/// operations while maintaining the event abstraction at the source level.

pub const InlineSmallEventsTransform = struct {
    allocator: std.mem.Allocator,
    context: *transform.TransformContext,
    size_threshold: usize = 5, // Lines of code threshold
    inlined_count: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, context: *transform.TransformContext) InlineSmallEventsTransform {
        return .{
            .allocator = allocator,
            .context = context,
        };
    }
    
    /// Apply the transformation to the AST
    pub fn apply(self: *InlineSmallEventsTransform) !void {
        // First pass: Find candidates for inlining
        var candidates = try self.findCandidates();
        defer {
            // Clean up allocated strings
            for (candidates.items) |candidate| {
                self.allocator.free(candidate.proc_path_str);
                self.allocator.free(candidate.proc_body);
            }
            candidates.deinit(self.allocator);
        }
        
        // Second pass: Generate all inlined code BEFORE modifying AST
        var inlined_codes = try std.ArrayList(InlinedCode).initCapacity(self.allocator, candidates.items.len);
        defer {
            for (inlined_codes.items) |code| {
                // Don't free the code itself - it's owned by the AST now
                _ = code;
            }
            inlined_codes.deinit(self.allocator);
        }
        
        for (candidates.items) |candidate| {
            const inlined_code = try self.generateInlinedCode(candidate);
            try inlined_codes.append(self.allocator, InlinedCode{
                .flow_index = candidate.flow_index,
                .code = inlined_code,
            });
        }
        
        // Third pass: Apply all transformations in reverse order to preserve indices
        var i: usize = inlined_codes.items.len;
        while (i > 0) {
            i -= 1;
            const inlined = inlined_codes.items[i];
            const new_item = ast.Item{ .host_line = inlined.code };
            try transform.replaceNode(self.context, inlined.flow_index, new_item);
            self.inlined_count += 1;
        }
    }
    
    /// Find all events that are good candidates for inlining
    fn findCandidates(self: *InlineSmallEventsTransform) !std.ArrayList(InlineCandidate) {
        var candidates = try std.ArrayList(InlineCandidate).initCapacity(self.allocator, 0);
        
        // Scan through all items looking for flows and their corresponding procs
        var flow_indices = try std.ArrayList(usize).initCapacity(self.allocator, 0);
        defer flow_indices.deinit(self.allocator);
        
        // Store proc bodies directly instead of pointers to avoid corruption
        const ProcData = struct {
            body: []const u8,
        };
        var proc_map = std.StringHashMap(ProcData).init(self.allocator);
        defer {
            var it = proc_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.body);
            }
            proc_map.deinit();
        }
        
        // Build maps of flows and procs
        for (self.context.current_ast.items, 0..) |item, i| {
            switch (item) {
                .flow => {
                    try flow_indices.append(self.allocator, i);
                },
                .proc_decl => |*proc| {
                    const path_str = try localPathToString(self.allocator, proc.path.segments);
                    const path_copy = try self.allocator.dupe(u8, path_str);
                    const body_copy = try self.allocator.dupe(u8, proc.body);
                    
                    std.debug.print("DEBUG: Storing proc {s} with body len={}, copy len={}\n", .{path_str, proc.body.len, body_copy.len});
                    
                    try proc_map.put(path_copy, ProcData{ .body = body_copy });
                },
                else => {},
            }
        }
        
        // Check each flow to see if it calls an inlinable event
        for (flow_indices.items) |flow_index| {
            const flow = &self.context.current_ast.items[flow_index].flow;
            const path_str = try localPathToString(self.allocator, flow.invocation.path.segments);
            
            if (proc_map.get(path_str)) |proc_data| {
                std.debug.print("DEBUG: Retrieved proc {s} with body len={}\n", .{path_str, proc_data.body.len});
                
                // Check if we should inline based on body size
                if (proc_data.body.len > 0 and proc_data.body.len < 200) { // Simple heuristic
                    // Store copies for the candidate
                    const path_copy = try self.allocator.dupe(u8, path_str);
                    const body_copy = try self.allocator.dupe(u8, proc_data.body);
                    
                    std.debug.print("DEBUG: Creating candidate for {s}, body len={}\n", .{path_str, body_copy.len});
                    
                    try candidates.append(self.allocator, InlineCandidate{
                        .flow_index = flow_index,
                        .flow = flow,
                        .proc_body = body_copy,
                        .proc_path_str = path_copy,
                    });
                }
            }
        }
        
        return candidates;
    }
    
    
    
    /// Generate the inlined code for a proc call
    fn generateInlinedCode(self: *InlineSmallEventsTransform, candidate: InlineCandidate) ![]const u8 {
        var code = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer code.deinit(self.allocator);
        
        // Generate comment showing this was inlined
        try code.appendSlice(self.allocator, "// Inlined from ");
        
        // Use the safely stored path string instead of accessing proc.path
        try code.appendSlice(self.allocator, candidate.proc_path_str);
        try code.appendSlice(self.allocator, "\n");
        
        // Start a block scope for the inlined code
        try code.appendSlice(self.allocator, "{\n");
        
        // Generate parameter bindings
        try code.appendSlice(self.allocator, "    // Bind parameters\n");
        try code.appendSlice(self.allocator, "    const e = .{\n");
        for (candidate.flow.invocation.args) |arg| {
            try code.appendSlice(self.allocator, "        .");
            try code.appendSlice(self.allocator, arg.name);
            try code.appendSlice(self.allocator, " = ");
            try code.appendSlice(self.allocator, arg.value);
            try code.appendSlice(self.allocator, ",\n");
        }
        try code.appendSlice(self.allocator, "    };\n");
        
        // Insert the proc body (with proper indentation)
        try code.appendSlice(self.allocator, "    // Inlined body\n");
        
        // Trim leading/trailing whitespace from proc body
        const trimmed_body = std.mem.trim(u8, candidate.proc_body, " \t\n\r");
        
        var lines = std.mem.tokenizeScalar(u8, trimmed_body, '\n');
        while (lines.next()) |line| {
            // Skip empty lines
            const trimmed_line = std.mem.trim(u8, line, " \t");
            if (trimmed_line.len > 0) {
                try code.appendSlice(self.allocator, "    ");
                try code.appendSlice(self.allocator, trimmed_line);
                try code.appendSlice(self.allocator, "\n");
            }
        }
        
        // Handle continuations
        try code.appendSlice(self.allocator, "    // Handle continuations\n");
        try self.generateContinuationHandling(&code, candidate);
        
        try code.appendSlice(self.allocator, "}\n");
        
        return try code.toOwnedSlice(self.allocator);
    }
    
    /// Generate code to handle the continuations after inlining
    fn generateContinuationHandling(self: *InlineSmallEventsTransform, code: *std.ArrayList(u8), candidate: InlineCandidate) !void {
        
        // This would need to parse the return statements in the proc
        // and map them to the appropriate continuations
        
        // For now, generate a simple switch on the result
        try code.appendSlice(self.allocator, "    // TODO: Map return values to continuations\n");
        
        for (candidate.flow.continuations) |cont| {
            try code.appendSlice(self.allocator, "    // Branch: ");
            try code.appendSlice(self.allocator, cont.branch);
            try code.appendSlice(self.allocator, "\n");
        }
    }
};

const InlineCandidate = struct {
    flow_index: usize,
    flow: *const ast.Flow,
    proc_body: []const u8,  // Copy of the proc body for safety
    proc_path_str: []const u8,  // Store the path string separately for safety
};

const InlinedCode = struct {
    flow_index: usize,
    code: []const u8,
};

/// Helper to convert path array to string
fn localPathToString(allocator: std.mem.Allocator, path: []const []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    for (path, 0..) |segment, i| {
        if (i > 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, segment);
    }
    return try buf.toOwnedSlice(allocator);
}

/// Public entry point for the transformation
pub fn transformAST(allocator: std.mem.Allocator, source_file: *ast.Program) !usize {
    var ctx = try transform.TransformContext.init(allocator, source_file);
    defer ctx.deinit();
    
    var transformer = InlineSmallEventsTransform.init(allocator, &ctx);
    try transformer.apply();
    
    return transformer.inlined_count;
}