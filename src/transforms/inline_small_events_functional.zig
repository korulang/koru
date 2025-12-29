const std = @import("std");
const ast = @import("ast");
const functional = @import("ast_functional");
const transform_functional = @import("transform_functional");

/// Functional Inline Small Events Transformation
/// 
/// This is a purely functional version of the inline transformation.
/// It creates a new AST with small events inlined, without mutating the original.

/// Configuration for the inline transformation
pub const InlineConfig = struct {
    size_threshold: usize = 5, // Lines of code threshold
    inline_recursive: bool = false, // Whether to inline recursive events
};

/// Create an inline transformation with the given configuration
pub fn createInlineTransformation(config: InlineConfig) transform_functional.Transformation {
    return struct {
        fn transform(allocator: std.mem.Allocator, source: *const ast.Program) anyerror!ast.Program {
            return inlineSmallEvents(allocator, source, config);
        }
    }.transform;
}

/// Main transformation function
fn inlineSmallEvents(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    config: InlineConfig,
) !ast.Program {
    // First pass: Build maps of procs and event declarations
    var proc_map = std.StringHashMap(ProcData).init(allocator);
    defer {
        var it = proc_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.body);
        }
        proc_map.deinit();
    }
    
    var event_map = std.StringHashMap(*const ast.EventDecl).init(allocator);
    defer {
        var it = event_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        event_map.deinit();
    }
    
    // Collect all procs and events
    for (source.items) |*item| {
        switch (item.*) {
            .proc_decl => |proc| {
                const path_str = try pathToString(allocator, proc.path.segments);
                const body_copy = try allocator.dupe(u8, proc.body);
                try proc_map.put(path_str, ProcData{
                    .body = body_copy,
                    .line_count = countLines(proc.body),
                });
            },
            .event_decl => |*event| {
                const path_str = try pathToString(allocator, event.path.segments);
                try event_map.put(path_str, event);
            },
            else => {},
        }
    }
    
    // Second pass: Transform flows that call small events
    var new_items = try std.ArrayList(ast.Item).initCapacity(allocator, source.items.len);
    defer new_items.deinit(allocator);
    
    for (source.items) |*item| {
        switch (item.*) {
            .flow => |flow| {
                // Skip flows with labels - they need special handling
                if (flow.pre_label != null or flow.post_label != null) {
                    try new_items.append(allocator, try functional.cloneItem(allocator, item));
                } else {
                    const path_str = try pathToString(allocator, flow.invocation.path.segments);
                    defer allocator.free(path_str);
                    
                    if (proc_map.get(path_str)) |proc_data| {
                        // Only check size threshold
                        if (proc_data.line_count <= config.size_threshold) {
                            // Inline this flow
                            const event_decl = event_map.get(path_str);
                            const inlined_code = try generateInlinedCode(
                                allocator,
                                &flow,
                                proc_data.body,
                                path_str,
                                event_decl,
                            );
                            try new_items.append(allocator, .{ .host_line = inlined_code });
                        } else {
                            // Keep the flow as-is (too large)
                            try new_items.append(allocator, try functional.cloneItem(allocator, item));
                        }
                    } else {
                        // No proc found, keep the flow as-is
                        try new_items.append(allocator, try functional.cloneItem(allocator, item));
                    }
                }
            },
            else => {
                // Keep all other items unchanged
                try new_items.append(allocator, try functional.cloneItem(allocator, item));
            },
        }
    }
    
    return ast.Program{
        .items = try new_items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const ProcData = struct {
    body: []const u8,
    line_count: usize,
};

fn countLines(text: []const u8) usize {
    var count: usize = 1; // At least one line
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn pathToString(allocator: std.mem.Allocator, path: []const []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 64);
    for (path, 0..) |segment, i| {
        if (i > 0) try buf.append(allocator, '.');
        try buf.appendSlice(allocator, segment);
    }
    return try buf.toOwnedSlice(allocator);
}

fn generateInlinedCode(
    allocator: std.mem.Allocator,
    flow: *const ast.Flow,
    proc_body: []const u8,
    event_path: []const u8,
    event_decl: ?*const ast.EventDecl,
) ![]const u8 {
    var code = try std.ArrayList(u8).initCapacity(allocator, 512);
    defer code.deinit(allocator);
    
    // Generate comment showing this was inlined
    try code.appendSlice(allocator, "// [Functional] Inlined from ");
    try code.appendSlice(allocator, event_path);
    try code.appendSlice(allocator, "\n");
    
    // Start a block scope for the inlined code
    try code.appendSlice(allocator, "{\n");
    
    // Generate parameter bindings
    if (flow.invocation.args.len > 0) {
        try code.appendSlice(allocator, "    // Bind parameters\n");
        try code.appendSlice(allocator, "    const e = .{\n");
        for (flow.invocation.args) |arg| {
            // Check if this field is a File type
            var is_file_field = false;
            if (event_decl) |event| {
                for (event.input.fields) |field| {
                    if (std.mem.eql(u8, field.name, arg.name)) {
                        if (field.is_file) {
                            is_file_field = true;
                            break;
                        }
                    }
                }
            }

            try code.appendSlice(allocator, "        .");
            try code.appendSlice(allocator, arg.name);
            try code.appendSlice(allocator, " = ");

            if (is_file_field) {
                // For File type, read the file contents at compile time
                // arg.value contains the filename (relative path)
                // We need to read this file relative to the source file location
                // For now, embed a @embedFile call
                try code.appendSlice(allocator, "@embedFile(\"");
                try code.appendSlice(allocator, arg.value);
                try code.appendSlice(allocator, "\")");
            } else {
                // Regular value
                try code.appendSlice(allocator, arg.value);
            }
            try code.appendSlice(allocator, ",\n");
        }
        try code.appendSlice(allocator, "    };\n\n");
    }
    
    // Insert the proc body (with proper indentation)
    try code.appendSlice(allocator, "    // Inlined body\n");
    
    // Process the proc body line by line for proper indentation
    var lines = std.mem.tokenizeScalar(u8, proc_body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            try code.appendSlice(allocator, "    ");
            try code.appendSlice(allocator, trimmed);
            try code.appendSlice(allocator, "\n");
        }
    }
    
    // Handle continuations if present
    if (flow.continuations.len > 0) {
        try code.appendSlice(allocator, "\n    // Handle continuations\n");
        try generateContinuationHandling(&code, flow, allocator);
    }
    
    try code.appendSlice(allocator, "}\n");
    
    return try code.toOwnedSlice(allocator);
}

fn generateContinuationHandling(code: *std.ArrayList(u8), flow: *const ast.Flow, allocator: std.mem.Allocator) !void {
    // Generate a comment for each continuation
    // In a full implementation, this would map return values to continuations
    for (flow.continuations) |cont| {
        try code.appendSlice(allocator, "    // Branch: ");
        try code.appendSlice(allocator, cont.branch);
        
        if (cont.binding) |binding| {
            try code.appendSlice(allocator, " (bound to: ");
            try code.appendSlice(allocator, binding);
            try code.appendSlice(allocator, ")");
        }
        
        try code.appendSlice(allocator, "\n");
    }
}

/// Count how many events would be inlined with the given configuration
pub fn countInlineCandidates(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    config: InlineConfig,
) !usize {
    // Build proc map
    var proc_map = std.StringHashMap(usize).init(allocator);
    defer {
        var it = proc_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        proc_map.deinit();
    }
    
    // Collect proc sizes
    for (source.items) |*item| {
        switch (item.*) {
            .proc_decl => |proc| {
                const path_str = try pathToString(allocator, proc.path.segments);
                const line_count = countLines(proc.body);
                try proc_map.put(path_str, line_count);
            },
            else => {},
        }
    }
    
    // Count flows that would be inlined
    var count: usize = 0;
    for (source.items) |*item| {
        switch (item.*) {
            .flow => |flow| {
                const path_str = try pathToString(allocator, flow.invocation.path.segments);
                defer allocator.free(path_str);
                
                if (proc_map.get(path_str)) |line_count| {
                    if (line_count <= config.size_threshold) {
                        count += 1;
                    }
                }
            },
            else => {},
        }
    }
    
    return count;
}

/// Get metrics about what would be inlined
pub const InlineMetrics = struct {
    total_flows: usize,
    inlinable_flows: usize,
    total_proc_lines: usize,
    inlined_proc_lines: usize,
    largest_inlined_size: usize,
};

pub fn getInlineMetrics(
    allocator: std.mem.Allocator,
    source: *const ast.Program,
    config: InlineConfig,
) !InlineMetrics {
    var metrics = InlineMetrics{
        .total_flows = 0,
        .inlinable_flows = 0,
        .total_proc_lines = 0,
        .inlined_proc_lines = 0,
        .largest_inlined_size = 0,
    };
    
    // Build proc map
    var proc_map = std.StringHashMap(usize).init(allocator);
    defer {
        var it = proc_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        proc_map.deinit();
    }
    
    // Collect proc sizes
    for (source.items) |*item| {
        switch (item.*) {
            .proc_decl => |proc| {
                const path_str = try pathToString(allocator, proc.path.segments);
                const line_count = countLines(proc.body);
                try proc_map.put(path_str, line_count);
                metrics.total_proc_lines += line_count;
            },
            else => {},
        }
    }
    
    // Analyze flows
    for (source.items) |*item| {
        switch (item.*) {
            .flow => |flow| {
                metrics.total_flows += 1;
                
                const path_str = try pathToString(allocator, flow.invocation.path.segments);
                defer allocator.free(path_str);
                
                if (proc_map.get(path_str)) |line_count| {
                    if (line_count <= config.size_threshold) {
                        metrics.inlinable_flows += 1;
                        metrics.inlined_proc_lines += line_count;
                        if (line_count > metrics.largest_inlined_size) {
                            metrics.largest_inlined_size = line_count;
                        }
                    }
                }
            },
            else => {},
        }
    }
    
    return metrics;
}