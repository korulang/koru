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
//! Cut 2 grammar (the regular subset + NAMED capture groups; still no
//! backrefs — they'd force backtracking):
//!   alt    := concat ('|' concat)*
//!   concat := repeat*
//!   repeat := atom ('*' | '+' | '?')*
//!   atom   := group | '[' class ']' | '.' | '^' | '$' | literal
//!   group  := '(' '?<' name '>' alt ')'   — named CAPTURE group
//!           | '(' alt ')'                 — non-capturing structure
//!   class  := '^'? ( char ('-' char)? )+
//!
//! Named groups (`(?<name>...)`) are the ONLY capture form — bare `(...)`
//! stays non-capturing, so positional captures are unrepresentable and the
//! silent-transposition trap dies at the grammar. Capture groups may not sit
//! under a quantifier or an alternation (rejected loudly, same doctrine as
//! backrefs): every group therefore matches EXACTLY ONCE in any successful
//! match and owns exactly one span. Span extraction is a Pike VM over the
//! tagged NFA — linear-time, no backtracking, the ReDoS guarantee intact.
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

/// A named capture group `(?<name>inner)`. `index` is the group's position in
/// pattern open-order; tags 2·index (start) and 2·index+1 (end) mark its span.
pub const Group = struct {
    name: []const u8,
    index: usize,
    inner: *Node,
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
    group: Group, // (?<name>...)
};

pub const ParseError = error{
    UnexpectedEnd,
    UnterminatedClass,
    EmptyClass,
    UnterminatedGroup,
    TrailingInput,
    OutOfMemory,
    // named-group errors
    UnsupportedGroupSyntax, // `(?` not followed by `<` (no `(?:`, `(?=`, …)
    UnterminatedGroupName, // `(?<name` with no closing `>`
    EmptyGroupName,
    BadGroupName, // names are [A-Za-z_][A-Za-z0-9_]* — they become host identifiers
    DuplicateGroupName,
    TooManyGroups, // hard cap so emitted tag vectors stay fixed-size
    GroupUnderQuantifier, // a repeated group has no single span — rejected
    GroupUnderAlternation, // a group on an untaken branch has no span — rejected
};

/// Hard cap on named groups per pattern (tag vectors are 2× this).
pub const max_groups: usize = 16;

/// Recursive-descent parser. Allocate the parser's nodes from an arena and free
/// them all at once; nothing here frees individual nodes.
pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,
    /// Named-group names in pattern open-order; group i owns tags 2i / 2i+1.
    group_names: std.ArrayList([]const u8) = .{},

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
                if (self.peek() == @as(u8, '?')) {
                    // `(?` — only the named-capture form `(?<name>...)` exists.
                    self.pos += 1;
                    if (!self.eat('<')) return error.UnsupportedGroupSyntax;
                    const name = try self.parseGroupName();
                    const index = self.group_names.items.len;
                    for (self.group_names.items) |existing| {
                        if (std.mem.eql(u8, existing, name)) return error.DuplicateGroupName;
                    }
                    if (index >= max_groups) return error.TooManyGroups;
                    try self.group_names.append(self.allocator, name);
                    const inner = try self.parseAlt();
                    if (!self.eat(')')) return error.UnterminatedGroup;
                    return self.mk(.{ .group = .{ .name = name, .index = index, .inner = inner } });
                }
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

    /// Parse `name>` after `(?<`. Names become host struct fields, so the
    /// charset is the identifier subset: [A-Za-z_][A-Za-z0-9_]* (no kebab —
    /// `-` is a minus in host expressions; see the FRONTIERS tension).
    fn parseGroupName(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '>') {
                const name = self.src[start..self.pos];
                self.pos += 1;
                if (name.len == 0) return error.EmptyGroupName;
                for (name, 0..) |ch, i| {
                    const alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
                    const digit = ch >= '0' and ch <= '9';
                    if (!(alpha or (digit and i > 0))) return error.BadGroupName;
                }
                return name;
            }
            self.pos += 1;
        }
        return error.UnterminatedGroupName;
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

/// A parsed-and-validated pattern: the AST plus its named groups in open
/// (= tag) order. The validation guarantees every group matches exactly once
/// in any successful match — each owns one definite span.
pub const Analysis = struct {
    root: *Node,
    group_names: []const []const u8,
};

/// Parse + validate a pattern. This is the front door for callers that care
/// about named groups (the match transform); errors carry the cut-2 doctrine
/// (`GroupUnderQuantifier` / `GroupUnderAlternation`) for loud surfacing.
pub fn analyze(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Analysis {
    var p = Parser.init(allocator, pattern);
    const root = try p.parse();
    try validateGroups(root, false, false);
    return .{ .root = root, .group_names = p.group_names.items };
}

/// Capture groups may not sit under a quantifier (no single span) or an
/// alternation (no span on the untaken branch). Nesting groups is legal —
/// the inner span is simply contained in the outer one.
fn validateGroups(node: *const Node, in_quant: bool, in_alt: bool) ParseError!void {
    switch (node.*) {
        .group => |g| {
            if (in_quant) return error.GroupUnderQuantifier;
            if (in_alt) return error.GroupUnderAlternation;
            try validateGroups(g.inner, in_quant, in_alt);
        },
        .star, .plus, .opt => |inner| try validateGroups(inner, true, in_alt),
        .alt => |branches| for (branches) |b| try validateGroups(b, in_quant, true),
        .concat => |parts| for (parts) |part| try validateGroups(part, in_quant, in_alt),
        .empty, .literal, .any, .class, .anchor_start, .anchor_end => {},
    }
}

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

test "named groups: parse + analyze collects names in open order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const an = try analyze(arena.allocator(), "(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)");
    try testing.expectEqual(@as(usize, 3), an.group_names.len);
    try testing.expectEqualStrings("l", an.group_names[0]);
    try testing.expectEqualStrings("w", an.group_names[1]);
    try testing.expectEqualStrings("h", an.group_names[2]);
}

test "named groups: bare (...) stays non-capturing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const an = try analyze(arena.allocator(), "(ab)*(?<x>c)");
    try testing.expectEqual(@as(usize, 1), an.group_names.len);
    try testing.expectEqualStrings("x", an.group_names[0]);
}

test "named groups: rejection doctrine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnsupportedGroupSyntax, analyze(a, "(?:a)"));
    try testing.expectError(error.EmptyGroupName, analyze(a, "(?<>a)"));
    try testing.expectError(error.BadGroupName, analyze(a, "(?<a b>x)"));
    try testing.expectError(error.BadGroupName, analyze(a, "(?<my-name>x)")); // kebab is a minus in host exprs
    try testing.expectError(error.BadGroupName, analyze(a, "(?<1x>a)")); // leading digit
    try testing.expectError(error.UnterminatedGroupName, analyze(a, "(?<abc"));
    try testing.expectError(error.DuplicateGroupName, analyze(a, "(?<a>x)(?<a>y)"));
    try testing.expectError(error.GroupUnderQuantifier, analyze(a, "(?<x>a)+"));
    try testing.expectError(error.GroupUnderQuantifier, analyze(a, "((?<x>a))*")); // through non-capturing structure
    try testing.expectError(error.GroupUnderQuantifier, analyze(a, "(?<x>a)?")); // opt counts: no span when skipped
    try testing.expectError(error.GroupUnderAlternation, analyze(a, "a|(?<x>b)"));
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

// ── NFA (Thompson construction) + epsilon-closure simulation ─────────────────
//
// AST → NFA with epsilon transitions. Matching is epsilon-closure simulation:
// O(input_len × states), NO backtracking — linear-time, ReDoS-immune. (The DFA
// is a later speed optimization; this simulator is already a safe, working
// matcher and the reference the DFA will be checked against.)
//
// `match` semantics (cut 1): FULL match — the whole input must match. `^`/`$`
// are therefore no-ops here (the match is already whole-string-anchored); they
// build as epsilon. Real zero-width anchors + search semantics are a later cut.

/// An epsilon transition. `tag`, when set, records the current input position
/// into that tag slot as the transition is taken (group i: tag 2i = span
/// start, 2i+1 = span end). Tags are transparent to the bool matchers.
pub const Eps = struct { to: usize, tag: ?usize = null };

pub const NfaState = struct {
    sym: ?Class = null, // class-guarded transition (consumes one byte) …
    out: usize = 0, // … to this state (valid iff sym != null)
    eps: std.ArrayList(Eps) = .{}, // epsilon transitions (consume nothing)
};

pub const Nfa = struct {
    states: std.ArrayList(NfaState) = .{},
    start: usize = 0,
    accept: usize = 0,
    n_tags: usize = 0, // 2 × named-group count
    allocator: std.mem.Allocator,

    fn newState(self: *Nfa) !usize {
        try self.states.append(self.allocator, .{});
        return self.states.items.len - 1;
    }
    fn addEps(self: *Nfa, from: usize, to: usize) !void {
        try self.states.items[from].eps.append(self.allocator, .{ .to = to });
    }
    fn addTagEps(self: *Nfa, from: usize, to: usize, tag: usize) !void {
        try self.states.items[from].eps.append(self.allocator, .{ .to = to, .tag = tag });
    }

    /// Full-match: does the ENTIRE input match the pattern? Linear in input.
    pub fn matches(self: *const Nfa, input: []const u8) bool {
        const n = self.states.items.len;
        var cur = self.allocator.alloc(bool, n) catch return false;
        defer self.allocator.free(cur);
        var nxt = self.allocator.alloc(bool, n) catch return false;
        defer self.allocator.free(nxt);
        var stack = std.ArrayList(usize).initCapacity(self.allocator, n) catch return false;
        defer stack.deinit(self.allocator);

        @memset(cur, false);
        self.epsClosure(self.start, cur, &stack);
        for (input) |c| {
            @memset(nxt, false);
            var s: usize = 0;
            while (s < n) : (s += 1) {
                if (!cur[s]) continue;
                if (self.states.items[s].sym) |cls| {
                    if (cls.contains(c)) self.epsClosure(self.states.items[s].out, nxt, &stack);
                }
            }
            const tmp = cur;
            cur = nxt;
            nxt = tmp;
        }
        return cur[self.accept];
    }

    fn epsClosure(self: *const Nfa, from: usize, marked: []bool, stack: *std.ArrayList(usize)) void {
        if (marked[from]) return;
        stack.clearRetainingCapacity();
        stack.append(self.allocator, from) catch return;
        marked[from] = true;
        while (stack.pop()) |st| {
            for (self.states.items[st].eps.items) |e| {
                if (!marked[e.to]) {
                    marked[e.to] = true;
                    stack.append(self.allocator, e.to) catch return;
                }
            }
        }
    }
};

const Frag = struct { start: usize, accept: usize };

/// Build an NFA from a regex AST (Thompson). Allocate from an arena.
pub fn buildNfa(allocator: std.mem.Allocator, ast: *const Node) !Nfa {
    var nfa = Nfa{ .allocator = allocator };
    const frag = try buildFrag(&nfa, ast);
    nfa.start = frag.start;
    nfa.accept = frag.accept;
    nfa.n_tags = 2 * countGroups(ast);
    return nfa;
}

fn countGroups(node: *const Node) usize {
    return switch (node.*) {
        .group => |g| 1 + countGroups(g.inner),
        .star, .plus, .opt => |inner| countGroups(inner),
        .alt, .concat => |parts| blk: {
            var n: usize = 0;
            for (parts) |p| n += countGroups(p);
            break :blk n;
        },
        .empty, .literal, .any, .class, .anchor_start, .anchor_end => 0,
    };
}

fn symFrag(nfa: *Nfa, cls: Class) !Frag {
    const s = try nfa.newState();
    const acc = try nfa.newState();
    nfa.states.items[s].sym = cls;
    nfa.states.items[s].out = acc;
    return .{ .start = s, .accept = acc };
}

fn buildFrag(nfa: *Nfa, node: *const Node) anyerror!Frag {
    switch (node.*) {
        .empty, .anchor_start, .anchor_end => {
            const a = try nfa.newState();
            const b = try nfa.newState();
            try nfa.addEps(a, b);
            return .{ .start = a, .accept = b };
        },
        .literal => |ch| {
            var cls = Class{};
            cls.set[ch] = true;
            return symFrag(nfa, cls);
        },
        .any => return symFrag(nfa, Class{ .negated = true }), // negated empty = all bytes
        .class => |cls| return symFrag(nfa, cls),
        .concat => |parts| {
            const first = try buildFrag(nfa, parts[0]);
            var prev = first.accept;
            for (parts[1..]) |p| {
                const f = try buildFrag(nfa, p);
                try nfa.addEps(prev, f.start);
                prev = f.accept;
            }
            return .{ .start = first.start, .accept = prev };
        },
        .alt => |branches| {
            const start = try nfa.newState();
            const accept = try nfa.newState();
            for (branches) |b| {
                const f = try buildFrag(nfa, b);
                try nfa.addEps(start, f.start);
                try nfa.addEps(f.accept, accept);
            }
            return .{ .start = start, .accept = accept };
        },
        .star => |inner| {
            const start = try nfa.newState();
            const accept = try nfa.newState();
            const f = try buildFrag(nfa, inner);
            try nfa.addEps(start, f.start);
            try nfa.addEps(start, accept);
            try nfa.addEps(f.accept, f.start);
            try nfa.addEps(f.accept, accept);
            return .{ .start = start, .accept = accept };
        },
        .plus => |inner| {
            const f = try buildFrag(nfa, inner);
            const accept = try nfa.newState();
            try nfa.addEps(f.accept, f.start);
            try nfa.addEps(f.accept, accept);
            return .{ .start = f.start, .accept = accept };
        },
        .opt => |inner| {
            const start = try nfa.newState();
            const accept = try nfa.newState();
            const f = try buildFrag(nfa, inner);
            try nfa.addEps(start, f.start);
            try nfa.addEps(start, accept);
            try nfa.addEps(f.accept, accept);
            return .{ .start = start, .accept = accept };
        },
        .group => |g| {
            // Tagged eps bracket the inner frag: entering records the span
            // start (tag 2i), leaving records the span end (tag 2i+1).
            const start = try nfa.newState();
            const accept = try nfa.newState();
            const f = try buildFrag(nfa, g.inner);
            try nfa.addTagEps(start, f.start, 2 * g.index);
            try nfa.addTagEps(f.accept, accept, 2 * g.index + 1);
            return .{ .start = start, .accept = accept };
        },
    }
}

fn nfaFor(arena: std.mem.Allocator, src: []const u8) !Nfa {
    var p = Parser.init(arena, src);
    const ast = try p.parse();
    return buildNfa(arena, ast);
}

test "nfa: literal full-match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nfa = try nfaFor(arena.allocator(), "abc");
    try testing.expect(nfa.matches("abc"));
    try testing.expect(!nfa.matches("ab"));
    try testing.expect(!nfa.matches("abcd"));
    try testing.expect(!nfa.matches(""));
}

test "nfa: class + plus" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nfa = try nfaFor(arena.allocator(), "[a-z]+");
    try testing.expect(nfa.matches("foo"));
    try testing.expect(!nfa.matches("")); // + needs ≥1
    try testing.expect(!nfa.matches("f1")); // '1' not in [a-z], full match fails
}

test "nfa: the flagship [a-z]+@[a-z]+" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nfa = try nfaFor(arena.allocator(), "[a-z]+@[a-z]+");
    try testing.expect(nfa.matches("foo@bar"));
    try testing.expect(nfa.matches("a@b"));
    try testing.expect(!nfa.matches("FOO@bar")); // uppercase
    try testing.expect(!nfa.matches("foo@")); // second part empty
    try testing.expect(!nfa.matches("@bar")); // first part empty
}

test "nfa: alternation, star, opt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = try nfaFor(arena.allocator(), "a|bb");
    try testing.expect(a.matches("a") and a.matches("bb"));
    try testing.expect(!a.matches("b") and !a.matches("ab"));
    const s = try nfaFor(arena.allocator(), "a*");
    try testing.expect(s.matches("") and s.matches("aaa") and !s.matches("ab"));
    const o = try nfaFor(arena.allocator(), "ab?c");
    try testing.expect(o.matches("ac") and o.matches("abc") and !o.matches("abbc"));
}

test "nfa: ReDoS pattern stays linear (no catastrophic backtracking)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // `(a+)+` is the canonical ReDoS bomb — a backtracking engine goes
    // exponential on a long run of 'a' ending in a non-match. The NFA simulator
    // is linear, so this completes instantly and returns the correct answer.
    const nfa = try nfaFor(arena.allocator(), "(a+)+");
    try testing.expect(nfa.matches("aaaa"));
    try testing.expect(!nfa.matches("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX"));
}

// ── DFA (subset construction) ────────────────────────────────────────────────
//
// Subset construction turns the epsilon-NFA into a DFA: each DFA state is the
// epsilon-closure of a set of NFA states, and each (state, byte) has exactly one
// next state. Matching is then a flat table walk — O(1) per byte, O(input)
// total, straight-line. This is the shape we emit as native code. The empty set
// is the natural "dead" sink (all transitions loop to it; non-accepting), so no
// special-casing is needed. Matching stays linear-time / ReDoS-immune.

pub const Dfa = struct {
    n_states: usize,
    trans: []usize, // trans[state * 256 + byte] = next state
    accept: []bool,
    start: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dfa) void {
        self.allocator.free(self.trans);
        self.allocator.free(self.accept);
    }

    /// Full-match: does the ENTIRE input match? O(1) per byte.
    pub fn matches(self: *const Dfa, input: []const u8) bool {
        var s = self.start;
        for (input) |c| s = self.trans[s * 256 + c];
        return self.accept[s];
    }
};

const DfaError = error{ OutOfMemory, DfaTooLarge };
const max_dfa_states: usize = 1 << 16; // loud cap; the regular subset stays well under

/// epsilon-closure of `seeds`, collected as a sorted (ascending) set. Sorted so
/// equal sets have identical bytes → interning by content via a byte-keyed map.
fn closureSet(nfa: *const Nfa, seeds: []const usize, a: std.mem.Allocator) ![]usize {
    const n = nfa.states.items.len;
    const marked = try a.alloc(bool, n);
    @memset(marked, false);
    var stack = std.ArrayList(usize){};
    for (seeds) |s| {
        if (!marked[s]) {
            marked[s] = true;
            try stack.append(a, s);
        }
    }
    while (stack.pop()) |st| {
        for (nfa.states.items[st].eps.items) |e| {
            if (!marked[e.to]) {
                marked[e.to] = true;
                try stack.append(a, e.to);
            }
        }
    }
    var out = std.ArrayList(usize){};
    var i: usize = 0;
    while (i < n) : (i += 1) if (marked[i]) try out.append(a, i);
    return out.items;
}

fn setContains(set: []const usize, target: usize) bool {
    for (set) |s| if (s == target) return true;
    return false;
}

/// Build a DFA from an NFA via subset construction. The DFA arrays are owned by
/// `allocator`; all transient sets live in an internal arena.
pub fn buildDfa(allocator: std.mem.Allocator, nfa: *const Nfa) DfaError!Dfa {
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    var interned = std.StringHashMap(usize).init(a);
    var nfa_sets = std.ArrayList([]usize){}; // dfa state index -> its NFA set

    var dfa_trans = std.ArrayList(usize){};
    var dfa_accept = std.ArrayList(bool){};

    // intern the start set
    const start_set = try closureSet(nfa, &.{nfa.start}, a);
    try interned.put(std.mem.sliceAsBytes(start_set), 0);
    try nfa_sets.append(a, start_set);
    try dfa_accept.append(allocator, setContains(start_set, nfa.accept));

    var processed: usize = 0;
    while (processed < nfa_sets.items.len) : (processed += 1) {
        const set = nfa_sets.items[processed];
        var byte: usize = 0;
        while (byte < 256) : (byte += 1) {
            // move: NFA states reachable from `set` on this byte, then closure.
            var seeds = std.ArrayList(usize){};
            for (set) |s| {
                if (nfa.states.items[s].sym) |cls| {
                    if (cls.contains(@intCast(byte))) try seeds.append(a, nfa.states.items[s].out);
                }
            }
            const move = try closureSet(nfa, seeds.items, a);

            const key = std.mem.sliceAsBytes(move);
            const target = interned.get(key) orelse blk: {
                if (nfa_sets.items.len >= max_dfa_states) return error.DfaTooLarge;
                const idx = nfa_sets.items.len;
                try interned.put(key, idx);
                try nfa_sets.append(a, move);
                try dfa_accept.append(allocator, setContains(move, nfa.accept));
                break :blk idx;
            };
            try dfa_trans.append(allocator, target);
        }
    }

    return Dfa{
        .n_states = nfa_sets.items.len,
        .trans = try dfa_trans.toOwnedSlice(allocator),
        .accept = try dfa_accept.toOwnedSlice(allocator),
        .start = 0,
        .allocator = allocator,
    };
}

fn dfaFor(allocator: std.mem.Allocator, src: []const u8) !Dfa {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), src);
    const ast = try p.parse();
    var nfa = try buildNfa(arena.allocator(), ast);
    return buildDfa(allocator, &nfa);
}

test "dfa: flagship matches like the nfa" {
    var dfa = try dfaFor(testing.allocator, "[a-z]+@[a-z]+");
    defer dfa.deinit();
    try testing.expect(dfa.matches("foo@bar"));
    try testing.expect(dfa.matches("a@b"));
    try testing.expect(!dfa.matches("FOO@bar"));
    try testing.expect(!dfa.matches("foo@"));
    try testing.expect(!dfa.matches("@bar"));
}

test "dfa: alternation, star, opt, anchors" {
    {
        var d = try dfaFor(testing.allocator, "a|bb");
        defer d.deinit();
        try testing.expect(d.matches("a") and d.matches("bb") and !d.matches("b") and !d.matches("ab"));
    }
    {
        var d = try dfaFor(testing.allocator, "a*");
        defer d.deinit();
        try testing.expect(d.matches("") and d.matches("aaa") and !d.matches("ab"));
    }
    {
        var d = try dfaFor(testing.allocator, "ab?c");
        defer d.deinit();
        try testing.expect(d.matches("ac") and d.matches("abc") and !d.matches("abbc"));
    }
    {
        var d = try dfaFor(testing.allocator, "^.$");
        defer d.deinit();
        try testing.expect(d.matches("x") and !d.matches("") and !d.matches("xy"));
    }
}

test "dfa == nfa cross-check over many inputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const patterns = [_][]const u8{ "[a-z]+@[a-z]+", "a|bb|ccc", "(ab)*", "[0-9]?x", "a.c", "(a+)+" };
    const inputs = [_][]const u8{ "", "a", "ab", "abc", "foo@bar", "x", "9x", "ccc", "abab", "aXc", "aaaa", "aaaaX" };
    for (patterns) |pat| {
        const nfa = try nfaFor(arena.allocator(), pat);
        var dfa = try dfaFor(testing.allocator, pat);
        defer dfa.deinit();
        for (inputs) |inp| {
            try testing.expectEqual(nfa.matches(inp), dfa.matches(inp));
        }
    }
}

// ── Pike VM (tagged NFA simulation → capture spans) ─────────────────────────
//
// Span extraction runs the NFA breadth-first with one thread per reachable
// state, each carrying a tag vector; tagged eps transitions record the current
// input position as they're taken. Thread priority is DFS pre-order over the
// eps lists (Thompson construction orders them greedy-first), and the FIRST
// thread to claim a state wins — that is exactly leftmost-greedy
// disambiguation. O(input × states × tags), linear in the input, zero
// backtracking: the ReDoS guarantee survives captures (the RE2 design).
// Validation guarantees every group matches exactly once, so on accept every
// tag is set — no optional-span semantics exist to get wrong.

pub const max_tags = 2 * max_groups;
const tag_unset = std.math.maxInt(usize);

const ThreadList = struct {
    on: []bool,
    order: []usize,
    count: usize = 0,
    tags: []usize, // states × nt, keyed by state
    nt: usize,

    fn init(a: std.mem.Allocator, ns: usize, nt: usize) !ThreadList {
        return .{
            .on = blk: {
                const on = try a.alloc(bool, ns);
                @memset(on, false);
                break :blk on;
            },
            .order = try a.alloc(usize, ns),
            .tags = try a.alloc(usize, ns * nt),
            .nt = nt,
        };
    }

    fn clear(self: *ThreadList) void {
        @memset(self.on, false);
        self.count = 0;
    }

    /// Add a thread at `s`, then follow eps transitions in priority order.
    /// First thread to claim a state wins (leftmost-greedy).
    fn add(self: *ThreadList, nfa: *const Nfa, s: usize, tags: []const usize, pos: usize) void {
        if (self.on[s]) return;
        self.on[s] = true;
        @memcpy(self.tags[s * self.nt ..][0..self.nt], tags);
        self.order[self.count] = s;
        self.count += 1;
        for (nfa.states.items[s].eps.items) |e| {
            if (e.tag) |t| {
                var buf: [max_tags]usize = undefined;
                @memcpy(buf[0..self.nt], tags);
                buf[t] = pos;
                self.add(nfa, e.to, buf[0..self.nt], pos);
            } else {
                self.add(nfa, e.to, tags, pos);
            }
        }
    }
};

/// Full-match with capture spans: returns the tag vector (2 per group, byte
/// offsets, group-open order) for the highest-priority accepting thread, or
/// null on no match. The returned slice is owned by `allocator`.
pub fn captures(allocator: std.mem.Allocator, nfa: *const Nfa, input: []const u8) !?[]usize {
    const ns = nfa.states.items.len;
    const nt = nfa.n_tags;
    std.debug.assert(nt <= max_tags);

    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    var cur = try ThreadList.init(a, ns, nt);
    var nxt = try ThreadList.init(a, ns, nt);

    const t0 = [_]usize{tag_unset} ** max_tags;
    cur.add(nfa, nfa.start, t0[0..nt], 0);

    for (input, 0..) |c, i| {
        nxt.clear();
        for (cur.order[0..cur.count]) |s| {
            const st = nfa.states.items[s];
            if (st.sym) |cls| {
                if (cls.contains(c)) nxt.add(nfa, st.out, cur.tags[s * nt ..][0..nt], i + 1);
            }
        }
        const tmp = cur;
        cur = nxt;
        nxt = tmp;
        if (cur.count == 0) return null;
    }
    if (!cur.on[nfa.accept]) return null;
    const out = try allocator.alloc(usize, nt);
    @memcpy(out, cur.tags[nfa.accept * nt ..][0..nt]);
    return out;
}

fn capturesFor(arena: std.mem.Allocator, pattern: []const u8, input: []const u8) !?[]usize {
    const an = try analyze(arena, pattern);
    var nfa = try buildNfa(arena, an.root);
    return captures(arena, &nfa, input);
}

test "pike vm: dims flagship spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sp = (try capturesFor(a, "(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)", "25x300x1")).?;
    try testing.expectEqualSlices(usize, &.{ 0, 2, 3, 6, 7, 8 }, sp);
    try testing.expectEqual(@as(?[]usize, null), try capturesFor(a, "(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)", "25x300"));
    try testing.expectEqual(@as(?[]usize, null), try capturesFor(a, "(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)", ""));
}

test "pike vm: leftmost-greedy disambiguation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Both groups can take any split of "aa"; greedy gives the first all of it.
    const sp = (try capturesFor(arena.allocator(), "(?<a>a*)(?<b>a*)", "aa")).?;
    try testing.expectEqualSlices(usize, &.{ 0, 2, 2, 2 }, sp);
}

test "pike vm: nested groups, inner span inside outer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sp = (try capturesFor(arena.allocator(), "(?<outer>a(?<inner>b+)c)", "abbc")).?;
    try testing.expectEqualSlices(usize, &.{ 0, 4, 1, 3 }, sp);
}

test "pike vm: bool answer agrees with the dfa" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pattern = "(?<n>[0-9]+)x(?<m>[0-9]+)";
    const inputs = [_][]const u8{ "", "2x3", "12x34", "x", "2x", "x3", "2x3x4", "ax3" };
    var dfa = try dfaFor(testing.allocator, pattern);
    defer dfa.deinit();
    for (inputs) |inp| {
        const got = (try capturesFor(a, pattern, inp)) != null;
        try testing.expectEqual(dfa.matches(inp), got);
    }
}

// ── Emit (DFA → specialized native Zig matcher) ──────────────────────────────
//
// Serialize a DFA as a self-contained Zig function `fn <name>(input) bool` — the
// pattern's transition table baked in as data, walked O(1) per byte. The table
// IS the per-pattern specialization; because it's exactly the (cross-checked)
// DFA's `trans`/`accept`/`start`, the emitted matcher is equivalent to
// Dfa.matches by construction. (A switch-per-state emit is the later perf
// refinement; this table form is correct and fast and unblocks the e2e + the
// benchmark.) This is the function the `match` transform emits per `…`-branch.

/// Compile a regex pattern straight to emitted Zig matcher source. Convenience
/// for the `match` transform: pattern bytes in, `fn <name>(input: []const u8) bool`
/// source out. Uses an arena internally; the returned source is owned by `out`.
pub fn compileToZig(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitMatcher(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// Emit `fn <name>(input: []const u8) bool { … }` for the given DFA.
pub fn emitMatcher(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    try w.print("fn {s}(input: []const u8) bool {{\n", .{name});
    try w.writeAll("    const T = [_]u32{ ");
    for (dfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d}", .{t});
    }
    try w.writeAll(" };\n");
    try w.writeAll("    const A = [_]bool{ ");
    for (dfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll(" };\n");
    try w.print("    var s: u32 = {d};\n", .{dfa.start});
    try w.writeAll("    for (input) |c| s = T[@as(usize, s) * 256 + @as(usize, c)];\n");
    try w.writeAll("    return A[s];\n");
    try w.writeAll("}\n");
}

/// Compile a pattern WITH named groups straight to an emitted Zig captures
/// matcher: `fn <name>(input: []const u8) ?[<2N>]u32` — null on no match,
/// else the tag vector (2 byte-offsets per group, group-open order). The
/// emitted code is the same Pike VM as `captures`, specialized: NFA tables
/// baked as consts, fixed-size thread arrays, zero allocation. Caller is
/// expected to have run `analyze` (this re-validates and errors identically).
pub fn compileCapturesToZig(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    const analysis = try analyze(a, pattern);
    var nfa = try buildNfa(a, analysis.root);
    std.debug.assert(nfa.n_tags > 0); // groupless patterns take the DFA path
    var buf = std.ArrayList(u8){};
    try emitCapturesMatcher(buf.writer(out), &nfa, name);
    return buf.toOwnedSlice(out);
}

/// Emit the specialized Pike VM for a tagged NFA. Mirrors `captures` exactly;
/// the runtime version is the reference the unit tests pin, this is the shape
/// that ships in output_emitted.zig (self-contained, no std dependency).
pub fn emitCapturesMatcher(w: anytype, nfa: *const Nfa, name: []const u8) !void {
    const ns = nfa.states.items.len;
    const nt = nfa.n_tags;

    try w.print("const {s}_vm = struct {{\n", .{name});
    try w.print("    const NS: usize = {d};\n", .{ns});
    try w.print("    const NT: usize = {d};\n", .{nt});
    try w.writeAll("    const UNSET: u32 = 0xFFFFFFFF;\n");

    // OUT: sym-transition target per state (UNSET when the state has none).
    try w.writeAll("    const OUT = [_]u32{ ");
    for (nfa.states.items, 0..) |st, i| {
        if (i != 0) try w.writeAll(", ");
        if (st.sym != null) try w.print("{d}", .{st.out}) else try w.writeAll("0xFFFFFFFF");
    }
    try w.writeAll(" };\n");

    // MASK: 256-bit class membership per state ([4]u64).
    try w.writeAll("    const MASK = [_][4]u64{\n");
    for (nfa.states.items) |st| {
        var mask = [_]u64{0} ** 4;
        if (st.sym) |cls| {
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (cls.contains(@intCast(b))) mask[b >> 6] |= @as(u64, 1) << @intCast(b & 63);
            }
        }
        try w.print("        .{{ 0x{x}, 0x{x}, 0x{x}, 0x{x} }},\n", .{ mask[0], mask[1], mask[2], mask[3] });
    }
    try w.writeAll("    };\n");

    // Eps lists, flattened with per-state offsets; order preserved (priority).
    try w.writeAll("    const EPS_OFF = [_]u32{ 0");
    {
        var off: usize = 0;
        for (nfa.states.items) |st| {
            off += st.eps.items.len;
            try w.print(", {d}", .{off});
        }
    }
    try w.writeAll(" };\n");
    try w.writeAll("    const EPS_TO = [_]u32{ ");
    {
        var first = true;
        for (nfa.states.items) |st| {
            for (st.eps.items) |e| {
                if (!first) try w.writeAll(", ");
                first = false;
                try w.print("{d}", .{e.to});
            }
        }
        if (first) try w.writeAll("0"); // Zig rejects empty [_]T{}; index range is dead anyway
    }
    try w.writeAll(" };\n");
    try w.writeAll("    const EPS_TAG = [_]i8{ ");
    {
        var first = true;
        for (nfa.states.items) |st| {
            for (st.eps.items) |e| {
                if (!first) try w.writeAll(", ");
                first = false;
                if (e.tag) |t| try w.print("{d}", .{t}) else try w.writeAll("-1");
            }
        }
        if (first) try w.writeAll("-1");
    }
    try w.writeAll(" };\n");
    try w.print("    const START: u32 = {d};\n", .{nfa.start});
    try w.print("    const ACCEPT: u32 = {d};\n", .{nfa.accept});

    try w.writeAll(
        \\    fn add(on: *[NS]bool, order: *[NS]u32, count: *usize, tags: *[NS][NT]u32, s: u32, t: [NT]u32, pos: u32) void {
        \\        if (on[s]) return;
        \\        on[s] = true;
        \\        tags[s] = t;
        \\        order[count.*] = s;
        \\        count.* += 1;
        \\        var i: usize = EPS_OFF[s];
        \\        while (i < EPS_OFF[s + 1]) : (i += 1) {
        \\            var t2 = t;
        \\            if (EPS_TAG[i] >= 0) t2[@as(usize, @intCast(EPS_TAG[i]))] = pos;
        \\            add(on, order, count, tags, EPS_TO[i], t2, pos);
        \\        }
        \\    }
        \\    fn run(input: []const u8) ?[NT]u32 {
        \\        var on = [_]bool{false} ** NS;
        \\        var order: [NS]u32 = undefined;
        \\        var count: usize = 0;
        \\        var tags: [NS][NT]u32 = undefined;
        \\        add(&on, &order, &count, &tags, START, [_]u32{UNSET} ** NT, 0);
        \\        for (input, 0..) |c, ip| {
        \\            var on2 = [_]bool{false} ** NS;
        \\            var order2: [NS]u32 = undefined;
        \\            var count2: usize = 0;
        \\            var tags2: [NS][NT]u32 = undefined;
        \\            for (order[0..count]) |s| {
        \\                if (OUT[s] != UNSET and (MASK[s][c >> 6] >> @as(u6, @intCast(c & 63))) & 1 == 1) {
        \\                    add(&on2, &order2, &count2, &tags2, OUT[s], tags[s], @as(u32, @intCast(ip + 1)));
        \\                }
        \\            }
        \\            on = on2;
        \\            order = order2;
        \\            count = count2;
        \\            tags = tags2;
        \\            if (count == 0) return null;
        \\        }
        \\        if (!on[ACCEPT]) return null;
        \\        return tags[ACCEPT];
        \\    }
        \\};
        \\
    );
    try w.print("fn {s}(input: []const u8) ?[{d}]u32 {{\n    return {s}_vm.run(input);\n}}\n", .{ name, nt, name });
}

test "emit: produces a well-formed matcher fn that encodes the DFA" {
    const src = try compileToZig(testing.allocator, "[a-z]+@[a-z]+", "m0");
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "fn m0(input: []const u8) bool") != null);
    try testing.expect(std.mem.indexOf(u8, src, "const T = [_]u32{") != null);
    try testing.expect(std.mem.indexOf(u8, src, "const A = [_]bool{") != null);
    try testing.expect(std.mem.indexOf(u8, src, "return A[s];") != null);
    // table has exactly n_states * 256 entries
    var dfa = try dfaFor(testing.allocator, "[a-z]+@[a-z]+");
    defer dfa.deinit();
    var commas: usize = 0;
    const t_start = std.mem.indexOf(u8, src, "[_]u32{").?;
    const t_end = std.mem.indexOfPos(u8, src, t_start, "};").?;
    for (src[t_start..t_end]) |c| {
        if (c == ',') commas += 1;
    }
    try testing.expectEqual(dfa.n_states * 256, commas + 1);
}
