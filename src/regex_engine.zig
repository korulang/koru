//! std/regex engine — FRONTEND (parser): regex pattern string → regex AST.
//!
//! This is the foundation of Koru's compile-time, DFA-based regex. The whole
//! engine is: pattern → AST (here) → NFA (Thompson) → DFA (subset construction)
//! → minimized DFA (Hopcroft) → emitted as a specialized native matcher. Because
//! it compiles to a DFA, matching is GUARANTEED linear in the input with zero
//! backtracking — ReDoS is impossible by construction (the RE2 / Rust-regex /
//! Go-regexp design). That guarantee is WHY the regular subset rejects
//! backreferences: they'd force backtracking and reopen catastrophic blowup.
//!
//! Cut 1 grammar (the regular subset — complete and correct, just no captures
//! or backrefs yet):
//!   alt    := concat ('|' concat)*
//!   concat := repeat*
//!   repeat := atom ('*' | '+' | '?')*
//!   atom   := '(' alt ')' | '[' class ']' | '.' | '^' | '$' | literal
//!   class  := '^'? ( char ('-' char)? )+
const std = @import("std");

/// A character class `[...]`: a 256-entry membership set + optional negation.
pub const Class = struct {
    negated: bool = false,
    set: [256]bool = [_]bool{false} ** 256,

    pub fn contains(self: *const Class, c: u8) bool {
        const in = self.set[c];
        return if (self.negated) !in else in;
    }
};

/// Regex AST node. Pointers are arena-allocated by the Parser's allocator.
pub const Node = union(enum) {
    empty,
    literal: u8,
    any, // .
    class: Class, // [...]
    anchor_start, // ^
    anchor_end, // $
    concat: []*Node,
    alt: []*Node,
    star: *Node, // *
    plus: *Node, // +
    opt: *Node, // ?
};

pub const ParseError = error{
    UnexpectedEnd,
    UnterminatedClass,
    EmptyClass,
    UnterminatedGroup,
    TrailingInput,
    OutOfMemory,
};

/// Recursive-descent parser. Allocate the parser's nodes from an arena and free
/// them all at once; nothing here frees individual nodes.
pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Parser {
        return .{ .src = src, .pos = 0, .allocator = allocator };
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn mk(self: *Parser, n: Node) ParseError!*Node {
        const p = try self.allocator.create(Node);
        p.* = n;
        return p;
    }

    /// Parse the whole pattern. Errors on leftover input (e.g. an unbalanced `)`).
    pub fn parse(self: *Parser) ParseError!*Node {
        const n = try self.parseAlt();
        if (self.pos != self.src.len) return error.TrailingInput;
        return n;
    }

    fn parseAlt(self: *Parser) ParseError!*Node {
        var branches = try std.ArrayList(*Node).initCapacity(self.allocator, 2);
        try branches.append(self.allocator, try self.parseConcat());
        while (self.eat('|')) {
            try branches.append(self.allocator, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.mk(.{ .alt = try branches.toOwnedSlice(self.allocator) });
    }

    fn parseConcat(self: *Parser) ParseError!*Node {
        var parts = try std.ArrayList(*Node).initCapacity(self.allocator, 4);
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(self.allocator, try self.parseRepeat());
        }
        if (parts.items.len == 0) return self.mk(.empty);
        if (parts.items.len == 1) return parts.items[0];
        return self.mk(.{ .concat = try parts.toOwnedSlice(self.allocator) });
    }

    fn parseRepeat(self: *Parser) ParseError!*Node {
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    self.pos += 1;
                    atom = try self.mk(.{ .star = atom });
                },
                '+' => {
                    self.pos += 1;
                    atom = try self.mk(.{ .plus = atom });
                },
                '?' => {
                    self.pos += 1;
                    atom = try self.mk(.{ .opt = atom });
                },
                else => break,
            }
        }
        return atom;
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const c = self.peek() orelse return error.UnexpectedEnd;
        switch (c) {
            '(' => {
                self.pos += 1;
                const inner = try self.parseAlt();
                if (!self.eat(')')) return error.UnterminatedGroup;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.mk(.any);
            },
            '^' => {
                self.pos += 1;
                return self.mk(.anchor_start);
            },
            '$' => {
                self.pos += 1;
                return self.mk(.anchor_end);
            },
            else => {
                self.pos += 1;
                return self.mk(.{ .literal = c });
            },
        }
    }

    fn parseClass(self: *Parser) ParseError!*Node {
        self.pos += 1; // consume '['
        var class = Class{};
        if (self.eat('^')) class.negated = true;
        var saw_item = false;
        while (self.peek()) |c| {
            if (c == ']') {
                self.pos += 1;
                if (!saw_item) return error.EmptyClass;
                return self.mk(.{ .class = class });
            }
            self.pos += 1;
            saw_item = true;
            // Range `a-z`: a '-' that isn't the last char before ']'.
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1; // consume '-'
                const hi = self.src[self.pos];
                self.pos += 1; // consume high bound
                var x: u16 = c;
                while (x <= hi) : (x += 1) class.set[@intCast(x)] = true;
            } else {
                class.set[c] = true;
            }
        }
        return error.UnterminatedClass;
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseWith(arena: std.mem.Allocator, src: []const u8) ParseError!*Node {
    var p = Parser.init(arena, src);
    return p.parse();
}

test "literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "a");
    try testing.expect(n.* == .literal and n.literal == 'a');
}

test "any and anchors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "^.$");
    try testing.expect(n.* == .concat);
    try testing.expectEqual(@as(usize, 3), n.concat.len);
    try testing.expect(n.concat[0].* == .anchor_start);
    try testing.expect(n.concat[1].* == .any);
    try testing.expect(n.concat[2].* == .anchor_end);
}

test "quantifiers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "a*");
    try testing.expect(n.* == .star and n.star.* == .literal and n.star.literal == 'a');
}

test "char class with range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "[a-z]");
    try testing.expect(n.* == .class);
    try testing.expect(n.class.contains('a'));
    try testing.expect(n.class.contains('m'));
    try testing.expect(n.class.contains('z'));
    try testing.expect(!n.class.contains('A'));
    try testing.expect(!n.class.contains('0'));
}

test "negated class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "[^0-9]");
    try testing.expect(n.* == .class and n.class.negated);
    try testing.expect(!n.class.contains('5'));
    try testing.expect(n.class.contains('x'));
}

test "alternation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "a|b");
    try testing.expect(n.* == .alt);
    try testing.expectEqual(@as(usize, 2), n.alt.len);
}

test "the email-ish flagship pattern: [a-z]+@[a-z]+" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = try parseWith(arena.allocator(), "[a-z]+@[a-z]+");
    try testing.expect(n.* == .concat);
    try testing.expectEqual(@as(usize, 3), n.concat.len);
    try testing.expect(n.concat[0].* == .plus and n.concat[0].plus.* == .class);
    try testing.expect(n.concat[1].* == .literal and n.concat[1].literal == '@');
    try testing.expect(n.concat[2].* == .plus and n.concat[2].plus.* == .class);
}

test "unbalanced group errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnterminatedGroup, parseWith(arena.allocator(), "(ab"));
}

test "unterminated class errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnterminatedClass, parseWith(arena.allocator(), "[a-z"));
}
