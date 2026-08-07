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
            const prefix = try codegen_utils.buildKoruModulePath(allocator, mq);
            defer allocator.free(prefix);
            try buf.appendSlice(allocator, prefix);
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
                if (inv.inline_body) |ib| {
                    // Transform set inline_body — emit inline code instead of handler call
                    const result_var = try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                    defer allocator.free(result_var);
                    result_counter.* += 1;

                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);

                    // Emit: const result_N = label: { <inline code with label replaced> };
                    const label = try std.fmt.allocPrint(allocator, "__koru_inline_{d}", .{result_counter.*});
                    defer allocator.free(label);

                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "const ");
                    try buf.appendSlice(allocator, result_var);
                    try buf.appendSlice(allocator, " = ");
                    try buf.appendSlice(allocator, label);
                    try buf.appendSlice(allocator, ": ");

                    // Replace __KORU_INLINE__ placeholder with actual label
                    const placeholder = "__KORU_INLINE__";
                    var pos: usize = 0;
                    while (pos < ib.len) {
                        if (pos + placeholder.len <= ib.len and std.mem.eql(u8, ib[pos .. pos + placeholder.len], placeholder)) {
                            try buf.appendSlice(allocator, label);
                            pos += placeholder.len;
                        } else {
                            try buf.append(allocator, ib[pos]);
                            pos += 1;
                        }
                    }
                    try buf.appendSlice(allocator, ";\n");

                    if (nested.len > 0) {
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
                    }
                } else if (nested.len > 0) {
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
                if (nested.len > 0) {
                    // Inline code produces a result value — wrap in labeled block,
                    // assign to result variable, and generate switch on nested continuations.
                    // Convention: inline code uses break :__KORU_INLINE__ to produce its result.
                    const result_var = try std.fmt.allocPrint(allocator, "{s}{d}", .{ var_prefix, result_counter.* });
                    defer allocator.free(result_var);
                    result_counter.* += 1;

                    // Generate unique label
                    const label = try std.fmt.allocPrint(allocator, "__koru_inline_{d}", .{result_counter.*});
                    defer allocator.free(label);

                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);

                    // const result_N = __koru_inline_N: { <code with label replaced> };
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, "const ");
                    try buf.appendSlice(allocator, result_var);
                    try buf.appendSlice(allocator, " = ");
                    try buf.appendSlice(allocator, label);
                    try buf.appendSlice(allocator, ": ");

                    // Replace __KORU_INLINE__ placeholder with actual label in the inline code
                    var pos: usize = 0;
                    while (pos < code.len) {
                        if (pos + 15 <= code.len and std.mem.eql(u8, code[pos..pos + 15], "__KORU_INLINE__")) {
                            try buf.appendSlice(allocator, label);
                            pos += 15;
                        } else {
                            try buf.append(allocator, code[pos]);
                            pos += 1;
                        }
                    }
                    try buf.appendSlice(allocator, ";\n");

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
                    // Simple inline code — no result needed
                    const ind = try indent(allocator, indent_level);
                    defer allocator.free(ind);
                    try buf.appendSlice(allocator, ind);
                    try buf.appendSlice(allocator, code);
                    try buf.appendSlice(allocator, "\n");
                }
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
                // Runtime string equality (Zig): this module generates Zig
                // only (header prose above), so the value-equality spelling
                // for a literal-grounded string comparison applies here too.
                const cond_out = (codegen_utils.rewriteStringEqualityZig(allocator, cond.condition) catch null) orelse cond.condition;
                try buf.appendSlice(allocator, cond_out);
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
            // Discard bindings ("_") should not generate a capture to avoid unused variable errors
            if (std.mem.eql(u8, binding, "_")) {
                try buf.appendSlice(allocator, "{\n");
            } else {
                try buf.append(allocator, '|');
                try buf.appendSlice(allocator, binding);
                // Suffix with indent level to avoid shadowing in nested switches
                try buf.append(allocator, '_');
                var level_buf: [16]u8 = undefined;
                const level_str = std.fmt.bufPrint(&level_buf, "{d}", .{indent_level}) catch unreachable;
                try buf.appendSlice(allocator, level_str);
                try buf.appendSlice(allocator, "| {\n");

                // Alias original binding name for inline code that references source-level names.
                // E.g., `| result r |>` becomes `|r_2| { const r = r_2; _ = &r; ... }`
                // This lets inline code use `r.field` while the switch binding is `r_2`.
                const ind3 = try indent(allocator, indent_level + 2);
                defer allocator.free(ind3);
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, "const ");
                try buf.appendSlice(allocator, binding);
                try buf.appendSlice(allocator, " = ");
                try buf.appendSlice(allocator, binding);
                try buf.append(allocator, '_');
                try buf.appendSlice(allocator, level_str);
                try buf.appendSlice(allocator, ";\n");
                try buf.appendSlice(allocator, ind3);
                try buf.appendSlice(allocator, "_ = &");
                try buf.appendSlice(allocator, binding);
                try buf.appendSlice(allocator, ";\n");
            }
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
