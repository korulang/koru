// Continuation Code Generation Helpers
//
// This module provides reusable functions for generating Zig code from
// AST continuation structures. Intended for use by comptime transforms
// that need to inline continuation handling (e.g., ~for).
//
// Design: String-based code generation that doesn't depend on CodeEmitter state.

const std = @import("std");
const ast = @import("ast");
const codegen_utils = @import("codegen_utils");

/// Generate indentation string for the given level
fn indent(allocator: std.mem.Allocator, level: usize) ![]const u8 {
    const spaces = try allocator.alloc(u8, level * 4);
    @memset(spaces, ' ');
    return spaces;
}

/// Convert Koru struct syntax { field: value } to Zig syntax .{ .field = value }
/// Handles nested structs and preserves expressions like @as(i32, 0)
fn convertToZigStructSyntax(allocator: std.mem.Allocator, koru_expr: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, koru_expr, " \t\n\r");

    // If it doesn't look like a struct literal, return as-is
    if (trimmed.len < 2 or trimmed[0] != '{') {
        return allocator.dupe(u8, koru_expr) catch unreachable;
    }

    // Already in Zig format (starts with .{)?
    if (std.mem.startsWith(u8, koru_expr, ".{")) {
        return allocator.dupe(u8, koru_expr) catch unreachable;
    }

    var result = std.ArrayList(u8).initCapacity(allocator, koru_expr.len + 20) catch unreachable;

    // Start with .{
    result.appendSlice(allocator, ".{") catch unreachable;

    var i: usize = 1; // Skip opening {

    while (i < trimmed.len) {
        const c = trimmed[i];

        if (c == '}') {
            // End of struct
            result.append(allocator, '}') catch unreachable;
            i += 1;
            break;
        } else if (c == ':') {
            // Convert field colon to equals
            result.append(allocator, '=') catch unreachable;
            result.append(allocator, ' ') catch unreachable;
            i += 1;
        } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            // Whitespace
            result.append(allocator, c) catch unreachable;
            i += 1;
        } else if (c == ',') {
            // Field separator
            result.append(allocator, ',') catch unreachable;
            i += 1;
        } else if (c == '@' or c == '(' or c == ')' or (c >= '0' and c <= '9')) {
            // Part of an expression - copy as-is
            result.append(allocator, c) catch unreachable;
            i += 1;
        } else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            // Identifier start - could be a field name or part of an expression
            // Look ahead to see if this is followed by : (field name) or something else
            const id_start = i;
            while (i < trimmed.len) {
                const cc = trimmed[i];
                if (!((cc >= 'a' and cc <= 'z') or (cc >= 'A' and cc <= 'Z') or (cc >= '0' and cc <= '9') or cc == '_')) {
                    break;
                }
                i += 1;
            }
            const identifier = trimmed[id_start..i];

            // Skip whitespace to see what's next
            while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}

            if (i < trimmed.len and trimmed[i] == ':') {
                // This is a field name - add dot prefix
                result.append(allocator, '.') catch unreachable;
                result.appendSlice(allocator, identifier) catch unreachable;
            } else {
                // Part of an expression - just copy
                result.appendSlice(allocator, identifier) catch unreachable;
            }
        } else {
            // Other character - copy as-is
            result.append(allocator, c) catch unreachable;
            i += 1;
        }
    }

    // Copy any remaining characters
    if (i < trimmed.len) {
        result.appendSlice(allocator, trimmed[i..]) catch unreachable;
    }

    return result.toOwnedSlice(allocator) catch unreachable;
}

/// Build event path string: module.event_name_event
/// If module matches main_module_name, uses "main_module." prefix
fn buildEventPath(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    main_module_name: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 64) catch unreachable;

    // Determine module prefix - matches writeModulePath in emitter_helpers.zig
    if (invocation.path.module_qualifier) |mq| {
        if (std.mem.eql(u8, mq, main_module_name)) {
            // Same module as main - use main_module.
            try buf.appendSlice(allocator, "main_module.");
        } else {
            // Different module - use koru_ prefix and preserve dots
            // e.g., "std.io" becomes "koru_std.io."
            try buf.appendSlice(allocator, "koru_");
            try buf.appendSlice(allocator, mq);
            try buf.append(allocator, '.');
        }
    } else {
        // No qualifier - use main_module
        try buf.appendSlice(allocator, "main_module.");
    }

    // Event name with segments joined by underscore
    for (invocation.path.segments, 0..) |seg, i| {
        if (i > 0) try buf.append(allocator, '_');
        try buf.appendSlice(allocator, seg);
    }

    // Add _event suffix
    try buf.appendSlice(allocator, "_event");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate a handler call: _ = module.event_event.handler(.{ .arg = val, ... });
/// Returns owned string - caller must free.
pub fn generateHandlerCall(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    main_module_name: []const u8,
    indent_level: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;

    // Indentation
    const ind = try indent(allocator, indent_level);
    defer allocator.free(ind);
    try buf.appendSlice(allocator, ind);

    // _ = module.event_event.handler(.{
    try buf.appendSlice(allocator, "_ = ");

    const event_path = try buildEventPath(allocator, invocation, main_module_name);
    defer allocator.free(event_path);
    try buf.appendSlice(allocator, event_path);

    try buf.appendSlice(allocator, ".handler(.{");

    // Args
    for (invocation.args, 0..) |arg, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, " .");
        try buf.appendSlice(allocator, arg.name);
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, arg.value);
    }

    try buf.appendSlice(allocator, " });\n");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate a handler call that captures the result in a variable
/// Returns: const result_N = module.event_event.handler(.{ ... });
pub fn generateHandlerCallWithResult(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    main_module_name: []const u8,
    result_var: []const u8,
    indent_level: usize,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;

    // Indentation
    const ind = try indent(allocator, indent_level);
    defer allocator.free(ind);
    try buf.appendSlice(allocator, ind);

    // const result_N = module.event_event.handler(.{
    try buf.appendSlice(allocator, "const ");
    try buf.appendSlice(allocator, result_var);
    try buf.appendSlice(allocator, " = ");

    const event_path = try buildEventPath(allocator, invocation, main_module_name);
    defer allocator.free(event_path);
    try buf.appendSlice(allocator, event_path);

    try buf.appendSlice(allocator, ".handler(.{");

    // Args
    for (invocation.args, 0..) |arg, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, " .");
        try buf.appendSlice(allocator, arg.name);
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, arg.value);
    }

    try buf.appendSlice(allocator, " });\n");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Error type for codegen operations
pub const CodegenError = std.mem.Allocator.Error || error{FormatError};

/// Generate code for a single continuation's pipeline (the steps after |>)
/// This handles invoking events and recursively processing nested continuations.
fn generatePipelineCode(
    allocator: std.mem.Allocator,
    pipeline: []const ast.Step,
    nested: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
) CodegenError![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;

    for (pipeline) |step| {
        switch (step) {
            .invocation => |inv| {
                if (nested.len > 0) {
                    // This invocation has nested continuations - capture result and switch
                    const result_var = try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                    defer allocator.free(result_var);
                    result_counter.* += 1;

                    const call_code = try generateHandlerCallWithResult(
                        allocator,
                        &inv,
                        main_module_name,
                        result_var,
                        indent_level,
                    );
                    defer allocator.free(call_code);
                    try buf.appendSlice(allocator, call_code);

                    // Generate switch for nested continuations
                    const switch_code = try generateBranchSwitch(
                        allocator,
                        result_var,
                        nested,
                        main_module_name,
                        result_counter,
                        indent_level,
                        var_prefix,
                    );
                    defer allocator.free(switch_code);
                    try buf.appendSlice(allocator, switch_code);
                } else {
                    // Simple invocation - ignore result
                    const call_code = try generateHandlerCall(
                        allocator,
                        &inv,
                        main_module_name,
                        indent_level,
                    );
                    defer allocator.free(call_code);
                    try buf.appendSlice(allocator, call_code);
                }
            },
            .terminal => {
                // Terminal step - nothing to generate
            },
            .branch_constructor => |bc| {
                // Generate return statement for branch constructor
                // Output: return .{ .branch_name = .{ .field1 = value1, ... } };
                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "return .{ .");

                // Use escaped branch name if it's a keyword
                try codegen_utils.appendEscapedIdentifier(&buf, allocator, bc.branch_name);

                try buf.appendSlice(allocator, " = .{");

                for (bc.fields, 0..) |field, field_idx| {
                    if (field_idx > 0) {
                        try buf.appendSlice(allocator, ",");
                    }
                    try buf.appendSlice(allocator, " .");
                    try buf.appendSlice(allocator, field.name);
                    try buf.appendSlice(allocator, " = ");
                    // Use expression_str if available, otherwise fall back to type (for simple values)
                    const value = if (field.expression_str) |expr| expr else field.type;
                    try buf.appendSlice(allocator, value);
                }

                try buf.appendSlice(allocator, " } };\n");
            },
            .inline_code => |code| {
                // Emit inline code directly (used by transforms like ~capture)
                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, code);
                try buf.appendSlice(allocator, "\n");
            },
            .assignment => |asgn| {
                // Emit assignment: target = .{ .field1 = expr1, .field2 = expr2 };
                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, asgn.target);
                try buf.appendSlice(allocator, " = .{");
                for (asgn.fields, 0..) |field, field_idx| {
                    if (field_idx > 0) {
                        try buf.appendSlice(allocator, ",");
                    }
                    try buf.appendSlice(allocator, " .");
                    try buf.appendSlice(allocator, field.name);
                    try buf.appendSlice(allocator, " = ");
                    const value = if (field.expression_str) |expr| expr else field.type;
                    try buf.appendSlice(allocator, value);
                }
                try buf.appendSlice(allocator, " };\n");
            },
            .foreach => |fe| {
                // Emit for loop with body
                const each_binding = ast.NamedBranch.getBinding(fe.branches, "each") orelse "_";
                const each_body = ast.NamedBranch.getBody(fe.branches, "each");
                const done_body = ast.NamedBranch.getBody(fe.branches, "done");

                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "for (");
                try buf.appendSlice(allocator, fe.iterable);
                try buf.appendSlice(allocator, ") |");
                try buf.appendSlice(allocator, each_binding);
                try buf.appendSlice(allocator, "| {\n");

                // Emit body continuations
                for (each_body) |*body_cont| {
                    const body_code = try generateContinuationChainWithPrefix(
                        allocator,
                        body_cont,
                        main_module_name,
                        result_counter,
                        indent_level + 1,
                        var_prefix,
                    );
                    defer allocator.free(body_code);
                    try buf.appendSlice(allocator, body_code);
                }

                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "}\n");

                // Emit done_body after the loop
                for (done_body) |*done_cont| {
                    const done_code = try generateContinuationChainWithPrefix(
                        allocator,
                        done_cont,
                        main_module_name,
                        result_counter,
                        indent_level,
                        var_prefix,
                    );
                    defer allocator.free(done_code);
                    try buf.appendSlice(allocator, done_code);
                }
            },
            .conditional => |cond| {
                // Emit if/else with bodies
                const then_body = ast.NamedBranch.getBody(cond.branches, "then");
                const else_body = ast.NamedBranch.getBody(cond.branches, "else");

                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "if (");
                try buf.appendSlice(allocator, cond.condition);
                try buf.appendSlice(allocator, ") {\n");

                // Emit then_body
                for (then_body) |*then_cont| {
                    const then_code = try generateContinuationChainWithPrefix(
                        allocator,
                        then_cont,
                        main_module_name,
                        result_counter,
                        indent_level + 1,
                        var_prefix,
                    );
                    defer allocator.free(then_code);
                    try buf.appendSlice(allocator, then_code);
                }

                if (else_body.len > 0) {
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "} else {\n");

                    for (else_body) |*else_cont| {
                        const else_code = try generateContinuationChainWithPrefix(
                            allocator,
                            else_cont,
                            main_module_name,
                            result_counter,
                            indent_level + 1,
                            var_prefix,
                        );
                        defer allocator.free(else_code);
                        try buf.appendSlice(allocator, else_code);
                    }
                }

                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "}\n");
            },
            .capture => |cap| {
                // Emit nested capture with comptime type transformation
                const as_binding = ast.NamedBranch.getBinding(cap.branches, "as") orelse "__capture";
                const as_body = ast.NamedBranch.getBody(cap.branches, "as");
                const done_binding = ast.NamedBranch.getBinding(cap.branches, "done");
                const done_body = ast.NamedBranch.getBody(cap.branches, "done");

                const ind = try indent(allocator, indent_level);
                defer allocator.free(ind);

                // Convert init_expr from Koru syntax { field: value } to Zig syntax .{ .field = value }
                const zig_init_expr = convertToZigStructSyntax(allocator, cap.init_expr);
                defer allocator.free(zig_init_expr);

                // First, generate the runtime struct type using comptime metaprogramming
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "const __CaptureT_nested = comptime blk: {\n");

                const ind2 = try indent(allocator, indent_level + 1);
                defer allocator.free(ind2);

                try buf.appendSlice(allocator, ind2);
                try buf.appendSlice(allocator, "const info = @typeInfo(@TypeOf(");
                try buf.appendSlice(allocator, zig_init_expr);
                try buf.appendSlice(allocator, "));\n");

                try buf.appendSlice(allocator, ind2);
                try buf.appendSlice(allocator, "var fields: [info.@\"struct\".fields.len]@import(\"std\").builtin.Type.StructField = undefined;\n");

                try buf.appendSlice(allocator, ind2);
                try buf.appendSlice(allocator, "for (info.@\"struct\".fields, 0..) |f, i| {\n");

                const ind3 = try indent(allocator, indent_level + 2);
                defer allocator.free(ind3);

                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, "fields[i] = .{\n");

                const ind4 = try indent(allocator, indent_level + 3);
                defer allocator.free(ind4);

                try buf.appendSlice(allocator, ind4);
                try buf.appendSlice(allocator, ".name = f.name,\n");
                try buf.appendSlice(allocator, ind4);
                try buf.appendSlice(allocator, ".type = f.type,\n");
                try buf.appendSlice(allocator, ind4);
                try buf.appendSlice(allocator, ".default_value_ptr = null,\n");
                try buf.appendSlice(allocator, ind4);
                try buf.appendSlice(allocator, ".is_comptime = false,\n");
                try buf.appendSlice(allocator, ind4);
                try buf.appendSlice(allocator, ".alignment = f.alignment,\n");

                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, "};\n");

                try buf.appendSlice(allocator, ind2);
                try buf.appendSlice(allocator, "}\n");

                try buf.appendSlice(allocator, ind2);
                try buf.appendSlice(allocator, "break :blk @Type(.{ .@\"struct\" = .{\n");

                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, ".layout = .auto,\n");
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, ".fields = &fields,\n");
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, ".decls = &.{},\n");
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, ".is_tuple = false,\n");

                try buf.appendSlice(allocator, ind2);
                try buf.appendSlice(allocator, "}});\n");

                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "};\n");

                // Initialize the capture variable
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "var ");
                try buf.appendSlice(allocator, as_binding);
                try buf.appendSlice(allocator, ": __CaptureT_nested = ");
                try buf.appendSlice(allocator, zig_init_expr);
                try buf.appendSlice(allocator, ";\n");

                // Suppress unused warning
                try buf.appendSlice(allocator, ind);
                try buf.appendSlice(allocator, "_ = &");
                try buf.appendSlice(allocator, as_binding);
                try buf.appendSlice(allocator, ";\n");

                // Emit as_body continuations (may contain assignment nodes)
                for (as_body) |*as_cont| {
                    const as_code = try generateContinuationChainWithPrefix(
                        allocator,
                        as_cont,
                        main_module_name,
                        result_counter,
                        indent_level,
                        var_prefix,
                    );
                    defer allocator.free(as_code);
                    try buf.appendSlice(allocator, as_code);
                }

                // Bind final value and emit done_body
                if (done_binding) |done_bind| {
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "const ");
                    try buf.appendSlice(allocator, done_bind);
                    try buf.appendSlice(allocator, " = ");
                    try buf.appendSlice(allocator, as_binding);
                    try buf.appendSlice(allocator, ";\n");

                    // Suppress unused warning
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "_ = &");
                    try buf.appendSlice(allocator, done_bind);
                    try buf.appendSlice(allocator, ";\n");
                }

                // Emit done_body continuations
                for (done_body) |*done_cont| {
                    const done_code = try generateContinuationChainWithPrefix(
                        allocator,
                        done_cont,
                        main_module_name,
                        result_counter,
                        indent_level,
                        var_prefix,
                    );
                    defer allocator.free(done_code);
                    try buf.appendSlice(allocator, done_code);
                }
            },
            else => {
                // Other step types - skip for now
            },
        }
    }

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate a switch statement to handle event result branches
fn generateBranchSwitch(
    allocator: std.mem.Allocator,
    result_var: []const u8,
    continuations: []const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
) CodegenError![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch unreachable;

    const ind = try indent(allocator, indent_level);
    defer allocator.free(ind);

    // switch (result_var) {
    try buf.appendSlice(allocator, ind);
    try buf.appendSlice(allocator, "switch (");
    try buf.appendSlice(allocator, result_var);
    try buf.appendSlice(allocator, ") {\n");

    for (continuations) |cont| {
        const ind2 = try indent(allocator, indent_level + 1);
        defer allocator.free(ind2);

        // .branch_name => |binding| {
        try buf.appendSlice(allocator, ind2);
        try buf.append(allocator, '.');

        // Escape branch name if it's a keyword
        try codegen_utils.appendEscapedIdentifier(&buf, allocator, cont.branch);

        try buf.appendSlice(allocator, " => ");

        if (cont.binding) |binding| {
            try buf.append(allocator, '|');
            try buf.appendSlice(allocator, binding);
            // Suffix with indent level to avoid shadowing in nested switches
            try buf.append(allocator, '_');
            var level_buf: [16]u8 = undefined;
            const level_str = std.fmt.bufPrint(&level_buf, "{d}", .{indent_level}) catch unreachable;
            try buf.appendSlice(allocator, level_str);
            try buf.appendSlice(allocator, "| {\n");
        } else {
            try buf.appendSlice(allocator, "{\n");
        }

        // Generate code for this branch's step and nested continuations
        // Convert single step to array for compatibility with generatePipelineCode
        const pipeline = if (cont.node) |step| &[_]ast.Step{step} else &[_]ast.Step{};
        const pipeline_code = try generatePipelineCode(
            allocator,
            pipeline,
            cont.continuations,
            main_module_name,
            result_counter,
            indent_level + 2,
            var_prefix,
        );
        defer allocator.free(pipeline_code);
        try buf.appendSlice(allocator, pipeline_code);

        // Close branch
        try buf.appendSlice(allocator, ind2);
        try buf.appendSlice(allocator, "},\n");
    }

    // Close switch
    try buf.appendSlice(allocator, ind);
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator) catch unreachable;
}

/// Generate code for a full continuation chain starting from a single continuation.
/// This is the main entry point for ~for and other transforms.
///
/// Example input: | each item |> step1(x: item) | result r |> step2(y: r.y)
/// Example output:
///   const result_0 = step1_event.handler(.{ .x = item });
///   switch (result_0) {
///       .result => |r| {
///           _ = step2_event.handler(.{ .y = r.y });
///       },
///   }
///
/// var_prefix: Prefix for generated variable names (default "result_").
///             Use unique prefixes like "fe_" or "fd_" to avoid shadowing.
pub fn generateContinuationChain(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
) CodegenError![]const u8 {
    return generateContinuationChainWithPrefix(
        allocator,
        continuation,
        main_module_name,
        result_counter,
        indent_level,
        "result_", // Default prefix for backward compatibility
    );
}

/// Generate code for a continuation chain with a custom variable prefix.
/// Use this when you need to avoid variable shadowing in generated code.
pub fn generateContinuationChainWithPrefix(
    allocator: std.mem.Allocator,
    continuation: *const ast.Continuation,
    main_module_name: []const u8,
    result_counter: *usize,
    indent_level: usize,
    var_prefix: []const u8,
) CodegenError![]const u8 {
    // Convert single step to array for compatibility with generatePipelineCode
    const pipeline = if (continuation.node) |node| &[_]ast.Node{node} else &[_]ast.Node{};
    return generatePipelineCode(
        allocator,
        pipeline,
        continuation.continuations,
        main_module_name,
        result_counter,
        indent_level,
        var_prefix,
    );
}
