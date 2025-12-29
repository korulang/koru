// Template Utilities - Lookup and Interpolation for Code Templates
//
// These functions are used by transforms to:
// 1. Find templates defined with ~std.template:define(name: "...")
// 2. Interpolate placeholders with actual values and continuation code

const std = @import("std");
const ast = @import("ast");

/// Error types for template operations
pub const TemplateError = error{
    TemplateNotFound,
    InvalidPlaceholder,
    MissingBinding,
    OutOfMemory,
};

/// Binding for template interpolation
pub const Binding = struct {
    name: []const u8,
    value: []const u8,
};

/// Look up a template by name in the AST
/// Walks the AST looking for flows that invoke "std.template:define" with matching name
/// Returns the source code of the template, or null if not found
pub fn lookupTemplate(program: *const ast.Program, name: []const u8) ?[]const u8 {
    return lookupTemplateInItems(program.items, name);
}

fn lookupTemplateInItems(items: []const ast.Item, name: []const u8) ?[]const u8 {
    for (items) |item| {
        switch (item) {
            .flow => |flow| {
                // Check if this is std.template:define
                if (isTemplateDefine(&flow)) {
                    // Check if name matches
                    if (getTemplateName(&flow)) |template_name| {
                        if (std.mem.eql(u8, template_name, name)) {
                            // Found it! Return the source
                            return getTemplateSource(&flow);
                        }
                    }
                }
            },
            .module_decl => |module| {
                // Recursively search imported modules
                if (lookupTemplateInItems(module.items, name)) |source| {
                    return source;
                }
            },
            else => {},
        }
    }
    return null;
}

fn isTemplateDefine(flow: *const ast.Flow) bool {
    const path = flow.invocation.path;

    // Check module qualifier is "std.template"
    const mq = path.module_qualifier orelse return false;
    if (!std.mem.eql(u8, mq, "std.template")) return false;

    // Check segments is ["define"]
    if (path.segments.len != 1) return false;
    if (!std.mem.eql(u8, path.segments[0], "define")) return false;

    return true;
}

fn getTemplateName(flow: *const ast.Flow) ?[]const u8 {
    for (flow.invocation.args) |arg| {
        if (std.mem.eql(u8, arg.name, "name")) {
            // Remove quotes if present
            const value = arg.value;
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                return value[1 .. value.len - 1];
            }
            return value;
        }
    }
    return null;
}

fn getTemplateSource(flow: *const ast.Flow) ?[]const u8 {
    for (flow.invocation.args) |arg| {
        if (std.mem.eql(u8, arg.name, "source")) {
            // Prefer source_value.text (full Source block content) over arg.value
            // arg.value may be truncated for multiline sources
            if (arg.source_value) |sv| {
                return sv.text;
            }
            return arg.value;
        }
    }
    return null;
}

/// Interpolate placeholders in template source with actual values
///
/// Placeholder syntax:
///   ${name}       - substitute with binding value
///   ${| branch |} - substitute with continuation code (branch name extracted)
///
/// Uses ${} syntax to avoid conflicts with Zig's {} braces
///
/// Returns newly allocated string with substitutions applied
pub fn interpolate(
    allocator: std.mem.Allocator,
    template: []const u8,
    bindings: []const Binding,
) TemplateError![]const u8 {
    var result = std.ArrayList(u8){
        .items = &.{},
        .capacity = 0,
    };
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        // Check for ${...} placeholder
        if (i + 1 < template.len and template[i] == '$' and template[i + 1] == '{') {
            // Check for ${| branch |} syntax (continuation placeholder)
            if (i + 2 < template.len and template[i + 2] == '|') {
                // Find closing |}
                const start = i + 3; // After "${|"
                var end = start;
                while (end + 1 < template.len) {
                    if (template[end] == '|' and template[end + 1] == '}') {
                        break;
                    }
                    end += 1;
                }

                if (end + 1 >= template.len) {
                    return TemplateError.InvalidPlaceholder;
                }

                // Extract branch name (trim whitespace)
                const branch_name = std.mem.trim(u8, template[start..end], " \t");

                // Look up binding
                const value = findBinding(bindings, branch_name) orelse {
                    return TemplateError.MissingBinding;
                };

                result.appendSlice(allocator, value) catch return TemplateError.OutOfMemory;
                i = end + 2; // Skip past "|}"
            } else {
                // Simple ${name} placeholder
                const start = i + 2; // After "${"
                var end = start;
                while (end < template.len and template[end] != '}') {
                    end += 1;
                }

                if (end >= template.len) {
                    return TemplateError.InvalidPlaceholder;
                }

                const placeholder_name = template[start..end];

                // Look up binding
                const value = findBinding(bindings, placeholder_name) orelse {
                    return TemplateError.MissingBinding;
                };

                result.appendSlice(allocator, value) catch return TemplateError.OutOfMemory;
                i = end + 1; // Skip past "}"
            }
        } else {
            result.append(allocator, template[i]) catch return TemplateError.OutOfMemory;
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator) catch return TemplateError.OutOfMemory;
}

fn findBinding(bindings: []const Binding, name: []const u8) ?[]const u8 {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) {
            return binding.value;
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "interpolate simple placeholder" {
    const allocator = std.testing.allocator;

    const template = "if (${condition}) { return true; }";
    const bindings = [_]Binding{
        .{ .name = "condition", .value = "x > 10" },
    };

    const result = try interpolate(allocator, template, &bindings);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("if (x > 10) { return true; }", result);
}

test "interpolate multiple placeholders" {
    const allocator = std.testing.allocator;

    const template = "for (${range}) |${item}| { ${body} }";
    const bindings = [_]Binding{
        .{ .name = "range", .value = "0..n" },
        .{ .name = "item", .value = "i" },
        .{ .name = "body", .value = "sum += i;" },
    };

    const result = try interpolate(allocator, template, &bindings);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("for (0..n) |i| { sum += i; }", result);
}

test "interpolate continuation placeholder" {
    const allocator = std.testing.allocator;

    const template =
        \\if (cond) {
        \\    ${| then |}
        \\} else {
        \\    ${| else |}
        \\}
    ;
    const bindings = [_]Binding{
        .{ .name = "then", .value = "doThing();" },
        .{ .name = "else", .value = "doOther();" },
    };

    const result = try interpolate(allocator, template, &bindings);
    defer allocator.free(result);

    const expected =
        \\if (cond) {
        \\    doThing();
        \\} else {
        \\    doOther();
        \\}
    ;
    try std.testing.expectEqualStrings(expected, result);
}

test "interpolate missing binding returns error" {
    const allocator = std.testing.allocator;

    const template = "value = ${missing}";
    const bindings = [_]Binding{};

    const result = interpolate(allocator, template, &bindings);
    try std.testing.expectError(TemplateError.MissingBinding, result);
}

test "interpolate unclosed placeholder returns error" {
    const allocator = std.testing.allocator;

    const template = "value = ${unclosed";
    const bindings = [_]Binding{
        .{ .name = "unclosed", .value = "x" },
    };

    const result = interpolate(allocator, template, &bindings);
    try std.testing.expectError(TemplateError.InvalidPlaceholder, result);
}

// NOTE: lookupTemplate tests require AST module which isn't available in standalone zig test.
// These are tested through the regression test suite (320_019_template_lookup) and
// implicitly through ~if/~for transforms that use lookupTemplate.
//
// To run AST-dependent tests, use: ./run_regression.sh --run-units
