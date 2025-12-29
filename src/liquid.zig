// Minimal Liquid Template Engine for Koru
// ========================================
//
// A simple, runtime Liquid-like template engine for code generation.
// Designed to be extended for Oya (full Liquid with filters, etc.)
//
// Supported syntax:
//   {{ variable }}                    - Output value
//   {% if key %}...{% endif %}        - Conditional block
//   {% unless key %}...{% endunless %} - Inverted conditional
//   {% for item in array %}...{% endfor %} - Iteration
//
// Usage:
//   var ctx = Context.init(allocator);
//   try ctx.put("name", .{ .string = "Player" });
//   try ctx.put("is_pub", .{ .boolean = true });
//   const result = try render(allocator, template, &ctx);

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Value type for template context
pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    array: []const *Context,

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .string => |s| s.len > 0,
            .boolean => |b| b,
            .array => |a| a.len > 0,
        };
    }
};

/// Template context - maps variable names to values
pub const Context = struct {
    allocator: Allocator,
    data: std.StringHashMap(Value),

    pub fn init(allocator: Allocator) Context {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.data.deinit();
    }

    pub fn put(self: *Context, key: []const u8, value: Value) !void {
        try self.data.put(key, value);
    }

    pub fn get(self: *const Context, key: []const u8) ?Value {
        return self.data.get(key);
    }
};

/// Render a template with the given context
pub fn render(allocator: Allocator, template: []const u8, ctx: *const Context) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, template.len);
    errdefer output.deinit(allocator);

    try renderTo(template, ctx, output.writer(allocator));

    return try output.toOwnedSlice(allocator);
}

/// Render a template directly to a writer
pub fn renderTo(template: []const u8, ctx: *const Context, writer: anytype) !void {
    var pos: usize = 0;

    while (pos < template.len) {
        // Look for next tag - find whichever comes first: {{ or {%
        const output_tag = std.mem.indexOfPos(u8, template, pos, "{{");
        const logic_tag = std.mem.indexOfPos(u8, template, pos, "{%");

        // Determine which tag comes first (if any)
        const next_tag: ?struct { start: usize, is_output: bool } = blk: {
            if (output_tag) |o| {
                if (logic_tag) |l| {
                    break :blk .{ .start = @min(o, l), .is_output = o < l };
                }
                break :blk .{ .start = o, .is_output = true };
            } else if (logic_tag) |l| {
                break :blk .{ .start = l, .is_output = false };
            }
            break :blk null;
        };

        if (next_tag) |tag| {
            // Output literal text before tag
            try writer.writeAll(template[pos..tag.start]);

            if (tag.is_output) {
                // {{ variable }} - output tag
                if (std.mem.indexOfPos(u8, template, tag.start + 2, "}}")) |end| {
                    const tag_content = std.mem.trim(u8, template[tag.start + 2 .. end], " \t");

                    // Output variable value
                    if (ctx.get(tag_content)) |value| {
                        switch (value) {
                            .string => |s| try writer.writeAll(s),
                            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
                            .array => try writer.writeAll("[array]"),
                        }
                    }

                    pos = end + 2;
                    continue;
                }
            } else {
                // {% logic %} - logic tag
                if (std.mem.indexOfPos(u8, template, tag.start + 2, "%}")) |end| {
                    const tag_content = std.mem.trim(u8, template[tag.start + 2 .. end], " \t");

                    // Parse the tag
                    if (std.mem.startsWith(u8, tag_content, "if ")) {
                        const key = std.mem.trim(u8, tag_content[3..], " \t");
                        const block_end = findEndTag(template, end + 2, "endif") orelse return error.UnmatchedIf;
                        const inner = template[end + 2 .. block_end.start];

                        // Render if truthy
                        if (ctx.get(key)) |value| {
                            if (value.truthy()) {
                                try renderTo(inner, ctx, writer);
                            }
                        }

                        pos = block_end.end;
                        continue;
                    }

                    if (std.mem.startsWith(u8, tag_content, "unless ")) {
                        const key = std.mem.trim(u8, tag_content[7..], " \t");
                        const block_end = findEndTag(template, end + 2, "endunless") orelse return error.UnmatchedUnless;
                        const inner = template[end + 2 .. block_end.start];

                        // Render if falsy or missing
                        const should_render = if (ctx.get(key)) |value| !value.truthy() else true;
                        if (should_render) {
                            try renderTo(inner, ctx, writer);
                        }

                        pos = block_end.end;
                        continue;
                    }

                    if (std.mem.startsWith(u8, tag_content, "for ")) {
                        // Parse "for item in array"
                        const rest = std.mem.trim(u8, tag_content[4..], " \t");
                        const in_pos = std.mem.indexOf(u8, rest, " in ") orelse return error.InvalidForSyntax;
                        const item_name = std.mem.trim(u8, rest[0..in_pos], " \t");
                        const array_name = std.mem.trim(u8, rest[in_pos + 4 ..], " \t");
                        _ = item_name; // Used for nested context in full implementation

                        const block_end = findEndTag(template, end + 2, "endfor") orelse return error.UnmatchedFor;
                        const inner = template[end + 2 .. block_end.start];

                        // Iterate over array
                        if (ctx.get(array_name)) |value| {
                            switch (value) {
                                .array => |items| {
                                    for (items) |item_ctx| {
                                        try renderTo(inner, item_ctx, writer);
                                    }
                                },
                                else => {},
                            }
                        }

                        pos = block_end.end;
                        continue;
                    }

                    // Unknown tag - skip it
                    pos = end + 2;
                    continue;
                }
            }
        }

        // No more tags - output rest of template
        try writer.writeAll(template[pos..]);
        break;
    }
}

const BlockEnd = struct {
    start: usize,  // Start of {% end... %}
    end: usize,    // After %}
};

fn findEndTag(template: []const u8, start_pos: usize, end_tag: []const u8) ?BlockEnd {
    var pos = start_pos;
    var depth: usize = 1;

    // Determine what tag type we're looking for
    const start_tag = if (std.mem.eql(u8, end_tag, "endif"))
        "if "
    else if (std.mem.eql(u8, end_tag, "endunless"))
        "unless "
    else if (std.mem.eql(u8, end_tag, "endfor"))
        "for "
    else
        return null;

    while (pos < template.len) {
        if (std.mem.indexOfPos(u8, template, pos, "{%")) |tag_start| {
            if (std.mem.indexOfPos(u8, template, tag_start + 2, "%}")) |tag_end| {
                const tag_content = std.mem.trim(u8, template[tag_start + 2 .. tag_end], " \t");

                if (std.mem.startsWith(u8, tag_content, start_tag)) {
                    depth += 1;
                } else if (std.mem.eql(u8, tag_content, end_tag)) {
                    depth -= 1;
                    if (depth == 0) {
                        return .{
                            .start = tag_start,
                            .end = tag_end + 2,
                        };
                    }
                }

                pos = tag_end + 2;
                continue;
            }
        }
        break;
    }

    return null;
}

// Tests
test "simple interpolation" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "Player" });

    const result = try render(allocator, "const {{ name }} = struct {};", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("const Player = struct {};", result);
}

test "if conditional - true" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("is_pub", .{ .boolean = true });
    try ctx.put("name", .{ .string = "Player" });

    const result = try render(allocator, "{% if is_pub %}pub {% endif %}const {{ name }} = struct {};", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("pub const Player = struct {};", result);
}

test "if conditional - false" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("is_pub", .{ .boolean = false });
    try ctx.put("name", .{ .string = "Player" });

    const result = try render(allocator, "{% if is_pub %}pub {% endif %}const {{ name }} = struct {};", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("const Player = struct {};", result);
}

test "unless conditional" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("is_private", .{ .boolean = false });

    const result = try render(allocator, "{% unless is_private %}pub {% endunless %}fn foo() void {}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("pub fn foo() void {}", result);
}

test "for loop" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Create array items
    var item1 = Context.init(allocator);
    defer item1.deinit();
    try item1.put("name", .{ .string = "red" });

    var item2 = Context.init(allocator);
    defer item2.deinit();
    try item2.put("name", .{ .string = "green" });

    var item3 = Context.init(allocator);
    defer item3.deinit();
    try item3.put("name", .{ .string = "blue" });

    const items = [_]*Context{ &item1, &item2, &item3 };
    try ctx.put("colors", .{ .array = &items });

    const result = try render(allocator, "{% for c in colors %}{{ name }}, {% endfor %}", &ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("red, green, blue, ", result);
}
