// JSON → liquid record tree.
// ===========================
//
// A real recursive-descent JSON parser that produces `liquid.Value` record
// nodes — the universal walkable shape the template engine consumes. This is one
// entry in the "parser palette" (docs/PARSER_PALETTE.md): smartness lives here in
// Zig, with real errors; the template only walks the result. Registered as the
// `parse_json` filter so `{% const tree = parse_json(src) %}` parses a Source
// block on demand and the body walks it.
//
// Node shapes (every node is a `record` Context with a `kind` field):
//   object  → kind="object", children = array of entry records {key, value}
//   array   → kind="array",  children = array of element nodes
//   string  → kind="string", value = raw inner text
//   number  → kind="number", value = literal text
//   bool    → kind="bool",   value = "true" | "false"
//   null    → kind="null"

const std = @import("std");
const liquid = @import("liquid");
const Allocator = std.mem.Allocator;
const Value = liquid.Value;
const Context = liquid.Context;

pub const ParseError = error{
    OutOfMemory,
    UnexpectedEnd,
    UnexpectedChar,
    InvalidLiteral,
    UnterminatedString,
};

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,

    fn peek(self: *Parser) u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else 0;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) self.pos += 1;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.peek())) : (self.advance()) {}
    }

    /// Allocate a fresh node Context with its `kind` set.
    fn newNode(self: *Parser, kind: []const u8) ParseError!*Context {
        const c = try self.allocator.create(Context);
        c.* = Context.init(self.allocator);
        try c.put("kind", .{ .string = kind });
        return c;
    }

    fn parseValue(self: *Parser) ParseError!*Context {
        self.skipWs();
        const ch = self.peek();
        return switch (ch) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => self.parseString(),
            't', 'f' => self.parseBool(),
            'n' => self.parseNull(),
            else => if (ch == '-' or std.ascii.isDigit(ch))
                self.parseNumber()
            else
                error.UnexpectedChar,
        };
    }

    /// Read a JSON string's raw inner bytes (escapes preserved, not unescaped),
    /// leaving `pos` just past the closing quote. Returns the inner slice.
    fn readStringInner(self: *Parser) ParseError![]const u8 {
        if (self.peek() != '"') return error.UnexpectedChar;
        self.advance(); // opening quote
        const start = self.pos;
        while (self.pos < self.input.len and self.peek() != '"') {
            if (self.peek() == '\\') {
                self.advance();
                if (self.pos < self.input.len) self.advance();
            } else {
                self.advance();
            }
        }
        if (self.peek() != '"') return error.UnterminatedString;
        const inner = self.input[start..self.pos];
        self.advance(); // closing quote
        return inner;
    }

    fn parseString(self: *Parser) ParseError!*Context {
        const inner = try self.readStringInner();
        const node = try self.newNode("string");
        try node.put("value", .{ .string = inner });
        return node;
    }

    fn parseNumber(self: *Parser) ParseError!*Context {
        const start = self.pos;
        if (self.peek() == '-') self.advance();
        while (self.pos < self.input.len) {
            const c = self.peek();
            if (std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                self.advance();
            } else break;
        }
        const node = try self.newNode("number");
        try node.put("value", .{ .string = self.input[start..self.pos] });
        return node;
    }

    fn parseBool(self: *Parser) ParseError!*Context {
        if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            self.pos += 4;
            const node = try self.newNode("bool");
            try node.put("value", .{ .string = "true" });
            return node;
        }
        if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            self.pos += 5;
            const node = try self.newNode("bool");
            try node.put("value", .{ .string = "false" });
            return node;
        }
        return error.InvalidLiteral;
    }

    fn parseNull(self: *Parser) ParseError!*Context {
        if (std.mem.startsWith(u8, self.input[self.pos..], "null")) {
            self.pos += 4;
            return self.newNode("null");
        }
        return error.InvalidLiteral;
    }

    fn parseArray(self: *Parser) ParseError!*Context {
        self.advance(); // '['
        var children = try std.ArrayList(*Context).initCapacity(self.allocator, 0);
        self.skipWs();
        if (self.peek() == ']') {
            self.advance();
        } else {
            while (true) {
                const el = try self.parseValue();
                try children.append(self.allocator, el);
                self.skipWs();
                const c = self.peek();
                if (c == ',') {
                    self.advance();
                    continue;
                }
                if (c == ']') {
                    self.advance();
                    break;
                }
                return error.UnexpectedChar;
            }
        }
        const node = try self.newNode("array");
        try node.put("children", .{ .array = try children.toOwnedSlice(self.allocator) });
        return node;
    }

    fn parseObject(self: *Parser) ParseError!*Context {
        self.advance(); // '{'
        var children = try std.ArrayList(*Context).initCapacity(self.allocator, 0);
        self.skipWs();
        if (self.peek() == '}') {
            self.advance();
        } else {
            while (true) {
                self.skipWs();
                const key = try self.readStringInner();
                self.skipWs();
                if (self.peek() != ':') return error.UnexpectedChar;
                self.advance();
                const val = try self.parseValue();

                // An entry is itself a record: { key, value }, so the walker can
                // iterate `object.children` and read `entry.key` / `entry.value`.
                const entry = try self.allocator.create(Context);
                entry.* = Context.init(self.allocator);
                try entry.put("key", .{ .string = key });
                try entry.put("value", .{ .record = val });
                try children.append(self.allocator, entry);

                self.skipWs();
                const c = self.peek();
                if (c == ',') {
                    self.advance();
                    continue;
                }
                if (c == '}') {
                    self.advance();
                    break;
                }
                return error.UnexpectedChar;
            }
        }
        const node = try self.newNode("object");
        try node.put("children", .{ .array = try children.toOwnedSlice(self.allocator) });
        return node;
    }
};

/// Parse JSON text into a liquid record tree. All nodes are allocated with
/// `allocator`; use an arena so the whole tree is freed in one shot.
pub fn parse(allocator: Allocator, input: []const u8) ParseError!Value {
    var p = Parser{ .allocator = allocator, .input = input, .pos = 0 };
    p.skipWs();
    const node = try p.parseValue();
    return Value{ .record = node };
}

/// Filter adapter matching `liquid.Filter`: `parse_json(src)`.
pub fn filter(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    return parse(allocator, args[0].string);
}

// --- Tests: parse real JSON, then walk it with the template engine ---

test "parse + walk a JSON object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_json", filter);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("src", .{ .string =
        \\{"name": "koru", "kind": "language"}
    });

    // Walk the object: emit `key=value.value; ` per entry.
    const tmpl = "{% const tree = parse_json(src) %}" ++
        "{% case tree.kind %}{% when \"object\" %}" ++
        "{% for e in tree.children %}{{ e.key }}={{ e.value.value }}; {% endfor %}" ++
        "{% endcase %}";

    const result = try liquid.renderWithEnv(allocator, tmpl, &ctx, null, .{ .filters = &filters });
    try std.testing.expectEqualStrings("name=koru; kind=language; ", result);
}

test "parse + walk a JSON array with a recursive value-emitter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_json", filter);

    var templates = liquid.TemplateRegistry.init(allocator);
    defer templates.deinit();
    // A recursive JSON → compact-text emitter, exercising case + render + for.
    const emit =
        "{% case node.kind %}" ++
        "{% when \"string\" %}\"{{ node.value }}\"" ++
        "{% when \"number\" %}{{ node.value }}" ++
        "{% when \"bool\" %}{{ node.value }}" ++
        "{% when \"null\" %}null" ++
        "{% when \"array\" %}[{% for el in node.children %}{% render \"emit\", node: el %}{% endfor %}]" ++
        "{% when \"object\" %}{{% for e in node.children %}{{ e.key }}:{% render \"emit\", node: e.value %}{% endfor %}}" ++
        "{% endcase %}";
    try templates.put("emit", emit);

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.put("src", .{ .string =
        \\[1, "two", true, null]
    });

    const tmpl = "{% const tree = parse_json(src) %}{% render \"emit\", node: tree %}";
    const result = try liquid.renderWithEnv(allocator, tmpl, &ctx, null, .{
        .filters = &filters,
        .templates = &templates,
    });
    try std.testing.expectEqualStrings("[1\"two\"truenull]", result);
}
