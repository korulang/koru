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

pub const NfaState = struct {
    sym: ?Class = null, // class-guarded transition (consumes one byte) …
    out: usize = 0, // … to this state (valid iff sym != null)
    eps: std.ArrayList(usize) = .{}, // epsilon transitions (consume nothing)
};

pub const Nfa = struct {
    states: std.ArrayList(NfaState) = .{},
    start: usize = 0,
    accept: usize = 0,
    allocator: std.mem.Allocator,

    fn newState(self: *Nfa) !usize {
        try self.states.append(self.allocator, .{});
        return self.states.items.len - 1;
    }
    fn addEps(self: *Nfa, from: usize, to: usize) !void {
        try self.states.items[from].eps.append(self.allocator, to);
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
            for (self.states.items[st].eps.items) |to| {
                if (!marked[to]) {
                    marked[to] = true;
                    stack.append(self.allocator, to) catch return;
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
    return nfa;
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
        for (nfa.states.items[st].eps.items) |to| {
            if (!marked[to]) {
                marked[to] = true;
                try stack.append(a, to);
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
