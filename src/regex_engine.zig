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
    UnsupportedEscape, // `\q` etc. — unknown alphanumeric escapes never silently mean the letter
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
            '\\' => {
                self.pos += 1;
                switch (try self.parseEscape()) {
                    .byte => |b| return self.mk(.{ .literal = b }),
                    .class => |cl| return self.mk(.{ .class = cl }),
                }
            },
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
            // Escapes inside a class: a byte escape is a single member (it
            // does not open a range — `[\]-x]` means `]`, `-`, `x`); a
            // shorthand (\d \s \w) unions its set in. Negated shorthands
            // (\D…) have no single-set meaning inside a class — rejected.
            if (c == '\\') {
                switch (try self.parseEscape()) {
                    .byte => |b| class.set[b] = true,
                    .class => |cl| {
                        if (cl.negated) return error.UnsupportedEscape;
                        for (cl.set, 0..) |on, i| {
                            if (on) class.set[i] = true;
                        }
                    },
                }
                continue;
            }
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

    const Escaped = union(enum) { byte: u8, class: Class };

    /// Resolve the char after a consumed '\'. Control escapes and shorthand
    /// classes are the usual ones; any PUNCTUATION escapes to itself (that is
    /// how metachars are matched literally: `\[` `\.` `\\` …); an UNKNOWN
    /// alphanumeric escape is a loud error — `\q` never silently means `q`.
    fn parseEscape(self: *Parser) ParseError!Escaped {
        const c = self.peek() orelse return error.UnexpectedEnd;
        self.pos += 1;
        switch (c) {
            'n' => return .{ .byte = '\n' },
            't' => return .{ .byte = '\t' },
            'r' => return .{ .byte = '\r' },
            'd', 'D', 's', 'S', 'w', 'W' => {
                var cl = Class{};
                switch (c | 0x20) { // lowercase
                    'd' => {
                        var x: u16 = '0';
                        while (x <= '9') : (x += 1) cl.set[@intCast(x)] = true;
                    },
                    's' => {
                        cl.set[' '] = true;
                        cl.set['\t'] = true;
                        cl.set['\n'] = true;
                        cl.set['\r'] = true;
                        cl.set[0x0B] = true; // \v
                        cl.set[0x0C] = true; // \f
                    },
                    'w' => {
                        var x: u16 = 'a';
                        while (x <= 'z') : (x += 1) cl.set[@intCast(x)] = true;
                        x = 'A';
                        while (x <= 'Z') : (x += 1) cl.set[@intCast(x)] = true;
                        x = '0';
                        while (x <= '9') : (x += 1) cl.set[@intCast(x)] = true;
                        cl.set['_'] = true;
                    },
                    else => unreachable,
                }
                if (c >= 'A' and c <= 'Z') cl.negated = true;
                return .{ .class = cl };
            },
            else => {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) return error.UnsupportedEscape;
                return .{ .byte = c };
            },
        }
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

test "escapes: metachars match literally, atom and class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `\[` — the parser-library bracket terminal that surfaced the gap
    const br = try parseWith(a, "\\[");
    try testing.expect(br.* == .literal and br.literal == '[');
    // `\\` `\.` `\*`
    const bs = try parseWith(a, "\\\\");
    try testing.expect(bs.* == .literal and bs.literal == '\\');
    const dot = try parseWith(a, "a\\.b");
    try testing.expect(dot.* == .concat and dot.concat[1].literal == '.');
    // class member escape: `[\]x]` contains ']' and 'x', no range opened
    const cl = try parseWith(a, "[\\]x]");
    try testing.expect(cl.* == .class);
    try testing.expect(cl.class.contains(']') and cl.class.contains('x'));
    try testing.expect(!cl.class.contains('-'));
}

test "escapes: shorthand classes and control chars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try parseWith(a, "\\d");
    try testing.expect(d.* == .class and d.class.contains('7') and !d.class.contains('a'));
    const nd = try parseWith(a, "\\D");
    try testing.expect(nd.* == .class and nd.class.negated);
    const w = try parseWith(a, "[\\w-]");
    try testing.expect(w.* == .class and w.class.contains('_') and w.class.contains('-') and !w.class.contains('%'));
    const nl = try parseWith(a, "\\n");
    try testing.expect(nl.* == .literal and nl.literal == '\n');
    // and the whole thing runs: `\d+\.\d+` matches "3.14"
    const nfa = try nfaFor(a, "\\d+\\.\\d+");
    try testing.expect(nfa.matches("3.14"));
    try testing.expect(!nfa.matches("314"));
}

test "escapes: unknown alphanumeric escape is a loud error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedEscape, parseWith(arena.allocator(), "\\q"));
    try testing.expectError(error.UnsupportedEscape, parseWith(arena.allocator(), "[\\D]"));
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

/// A half-open match span [start, end) over the scanned input.
pub const Span = struct { start: usize, end: usize };

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

    /// Unanchored leftmost-LONGEST prefix match from `start`: returns the END
    /// index of the longest prefix of input[start..] the DFA accepts (span is
    /// [start, end)), or null if nothing — not even the empty match — matches.
    /// This is the `match`-cut's missing twin: `matches` asks "whole input?",
    /// this asks "longest from here?". Walks to end-of-input tracking the last
    /// accept (correctness-first reference; the emitted version adds the
    /// dead-state early-exit). O(input) per call.
    pub fn searchLongestFrom(self: *const Dfa, input: []const u8, start: usize) ?usize {
        var s = self.start;
        var last_accept: ?usize = if (self.accept[s]) start else null;
        var i = start;
        while (i < input.len) : (i += 1) {
            s = self.trans[s * 256 + input[i]];
            if (self.accept[s]) last_accept = i + 1;
        }
        return last_accept;
    }

    /// All non-overlapping leftmost-longest matches, left to right — the
    /// unanchored `scan` over the whole input. Empty matches advance one byte so
    /// scanning always terminates. Spans owned by `alloc`. O(input²) reference
    /// (try-each-start); the emitted matcher restarts from the dead state in a
    /// single pass.
    pub fn scanAll(self: *const Dfa, input: []const u8, alloc: std.mem.Allocator) ![]Span {
        var out = std.ArrayList(Span){};
        var pos: usize = 0;
        while (pos <= input.len) {
            var found = false;
            var s: usize = pos;
            while (s <= input.len) : (s += 1) {
                if (self.searchLongestFrom(input, s)) |end| {
                    try out.append(alloc, .{ .start = s, .end = end });
                    pos = if (end > s) end else s + 1; // empty match: step one
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
        return out.toOwnedSlice(alloc);
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

test "searchLongestFrom: agrees with anchored matches at the boundaries" {
    var dfa = try dfaFor(testing.allocator, "[a-z]+@[a-z]+");
    defer dfa.deinit();
    // whole-string match: longest from 0 consumes the whole input
    try testing.expectEqual(@as(?usize, 7), dfa.searchLongestFrom("foo@bar", 0));
    // unanchored: finds it starting mid-string, stops at the non-matching byte
    try testing.expectEqual(@as(?usize, 9), dfa.searchLongestFrom("xxfoo@bar?", 2));
    // a position that cannot start a match → null (not even empty: start state non-accepting)
    try testing.expectEqual(@as(?usize, null), dfa.searchLongestFrom("foo@bar", 3));
}

test "prefix-at-offset: the parser terminal shape (searchLongestFrom is the reference)" {
    // A grammar terminal asks "does this token start HERE, how far?" — the
    // 641_001 flagship's own input: `[0-9]+` against "[42]".
    var dfa = try dfaFor(testing.allocator, "-?[0-9]+");
    defer dfa.deinit();
    try testing.expectEqual(@as(?usize, 3), dfa.searchLongestFrom("[42]", 1)); // "42", longest not "4"
    try testing.expectEqual(@as(?usize, null), dfa.searchLongestFrom("[42]", 0)); // '[' can't start
    try testing.expectEqual(@as(?usize, null), dfa.searchLongestFrom("[42]", 3)); // ']' can't start
    try testing.expectEqual(@as(?usize, null), dfa.searchLongestFrom("[42]", 4)); // at end-of-input:
    // `-?[0-9]+` needs at least one digit, start state non-accepting → not even the empty prefix
}

test "scan: leftmost-longest, non-overlapping spans" {
    var dfa = try dfaFor(testing.allocator, "[0-9]+");
    defer dfa.deinit();
    const spans = try dfa.scanAll("a12b345c", testing.allocator);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(Span{ .start = 1, .end = 3 }, spans[0]); // "12"
    try testing.expectEqual(Span{ .start = 4, .end = 7 }, spans[1]); // "345"
}

test "scan: longest wins at each start (greedy)" {
    var dfa = try dfaFor(testing.allocator, "a+");
    defer dfa.deinit();
    const spans = try dfa.scanAll("baaa", testing.allocator);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 1), spans.len);
    try testing.expectEqual(Span{ .start = 1, .end = 4 }, spans[0]); // "aaa", not "a"
}

test "scan: no match yields no spans" {
    var dfa = try dfaFor(testing.allocator, "[0-9]+");
    defer dfa.deinit();
    const spans = try dfa.scanAll("abc", testing.allocator);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 0), spans.len);
}

test "scan: empty-capable pattern terminates (advance-by-one, matches JS matchAll)" {
    var dfa = try dfaFor(testing.allocator, "[0-9]*");
    defer dfa.deinit();
    const spans = try dfa.scanAll("a5", testing.allocator);
    defer testing.allocator.free(spans);
    // "" @0, "5" @1, "" @2 — three, like /[0-9]*/g over "a5"
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, spans[0]);
    try testing.expectEqual(Span{ .start = 1, .end = 2 }, spans[1]);
    try testing.expectEqual(Span{ .start = 2, .end = 2 }, spans[2]);
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

// ── Tagged DFA (one-pass capture extraction) ────────────────────────────────
//
// The Pike VM above is correct for ANY tagged NFA, but it simulates every live
// thread per byte — O(states)/byte. For the regular subset Koru actually allows
// — NO capture group under a quantifier or an alternation (640_008/009), so
// every group is a clean once-entered bracket — capture positions are
// STRUCTURALLY DETERMINISTIC, and subset construction can bake the tag-record
// actions onto each transition. Captures then run at DFA speed (O(1)/byte), the
// same class as the groupless matcher. This is RE2's "one-pass" engine narrowed
// to Koru's grammar.
//
// The rule is the Pike VM's, precomputed: a tag fires when the epsilon-closure
// that follows a byte transition crosses its edge, valued at the post-byte
// position (ip+1); tags crossed by the START closure fire at 0. Because the
// grammar guarantees a single live thread, the per-transition tag SET is fixed
// at compile time. Any pattern that is NOT one-pass (two states in a closure
// consume the same byte) returns error.NotOnePass and the caller emits the Pike
// VM instead — correct, just slower. Under the current grammar that should be
// unreachable for legal patterns; the check is a correctness backstop, not a
// silent fallback for a bug.

const TagBits = u32; // max_tags == 32 fits one word
const OnePassError = error{ OutOfMemory, DfaTooLarge, NotOnePass };

pub const TaggedDfa = struct {
    n_states: usize,
    n_tags: usize,
    trans: []u32, // trans[state * 256 + byte] = next state
    tag_off: []u32, // CSR offsets into tag_ids, len n_states*256 + 1
    tag_ids: []u8, // tag ids fired on each transition (value = ip+1)
    start_tags: []u8, // tags fired by the START closure (value 0)
    accept: []bool,
    start: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaggedDfa) void {
        self.allocator.free(self.trans);
        self.allocator.free(self.tag_off);
        self.allocator.free(self.tag_ids);
        self.allocator.free(self.start_tags);
        self.allocator.free(self.accept);
    }

    /// Reference runner — byte-for-byte the shape `emitTaggedCapturesMatcher`
    /// emits, and the oracle the cross-check tests pin against the Pike VM.
    /// Writes the tag vector into `out` (len n_tags); returns whole-input match.
    pub fn run(self: *const TaggedDfa, input: []const u8, out: []u32) bool {
        for (out) |*t| t.* = 0xFFFFFFFF;
        for (self.start_tags) |t| out[t] = 0;
        var s: u32 = self.start;
        for (input, 0..) |c, ip| {
            const base = @as(usize, s) * 256 + @as(usize, c);
            var k: usize = self.tag_off[base];
            while (k < self.tag_off[base + 1]) : (k += 1) out[self.tag_ids[k]] = @as(u32, @intCast(ip + 1));
            s = self.trans[base];
        }
        return self.accept[s];
    }
};

/// Epsilon-closure that mirrors the Pike VM's add(): eps edges in priority
/// order, mark-on-first-visit, and union a tag iff the edge that FIRST reaches
/// a new node carries one (an edge into an already-claimed node fires nothing —
/// exactly add()'s `if (on[s]) return`). Fills `marked`; ORs tags into `*tags`.
fn closeTagged(nfa: *const Nfa, s: usize, marked: []bool, tags: *TagBits) void {
    if (marked[s]) return;
    marked[s] = true;
    for (nfa.states.items[s].eps.items) |e| {
        if (!marked[e.to]) {
            if (e.tag) |t| tags.* |= (@as(TagBits, 1) << @as(u5, @intCast(t)));
            closeTagged(nfa, e.to, marked, tags);
        }
    }
}

/// Set bits of `bits` as ascending tag ids, owned by `a`.
fn tagIds(a: std.mem.Allocator, bits: TagBits) ![]u8 {
    var ids = std.ArrayList(u8){};
    var t: u8 = 0;
    while (t < max_tags) : (t += 1) {
        if ((bits >> @as(u5, @intCast(t))) & 1 == 1) try ids.append(a, t);
    }
    return ids.toOwnedSlice(a);
}

/// Closure of a single optional seed (null ⇒ the empty/dead set), as an
/// ASCENDING set (so equal sets intern by bytes), unioning crossed tags.
fn closeSeed(nfa: *const Nfa, n: usize, seed: ?usize, a: std.mem.Allocator, tags: *TagBits) ![]usize {
    const marked = try a.alloc(bool, n);
    @memset(marked, false);
    if (seed) |sd| closeTagged(nfa, sd, marked, tags);
    var out = std.ArrayList(usize){};
    var i: usize = 0;
    while (i < n) : (i += 1) if (marked[i]) try out.append(a, i);
    return out.toOwnedSlice(a);
}

/// Build a one-pass tagged DFA from a tagged NFA, or error.NotOnePass if the
/// pattern needs the Pike VM. The dead (empty) set is the natural absorbing
/// non-accepting sink, so no input is ever rejected mid-walk — the walk runs to
/// the end and the accept bit decides, matching the groupless emitter.
pub fn buildTaggedDfa(allocator: std.mem.Allocator, nfa: *const Nfa) OnePassError!TaggedDfa {
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const n = nfa.states.items.len;
    const nt = nfa.n_tags;

    var interned = std.StringHashMap(usize).init(a);
    var sets = std.ArrayList([]usize){};

    var start_bits: TagBits = 0;
    const start_set = try closeSeed(nfa, n, nfa.start, a, &start_bits);
    try interned.put(std.mem.sliceAsBytes(start_set), 0);
    try sets.append(a, start_set);

    var trans = std.ArrayList(u32){};
    var tag_lists = std.ArrayList([]const u8){};
    var accept = std.ArrayList(bool){};
    try accept.append(a, setContains(start_set, nfa.accept));

    var processed: usize = 0;
    while (processed < sets.items.len) : (processed += 1) {
        const set = sets.items[processed];
        var byte: usize = 0;
        while (byte < 256) : (byte += 1) {
            // one-pass: at most one sym-state in this set may consume `byte`.
            var seed: ?usize = null;
            for (set) |s| {
                if (nfa.states.items[s].sym) |cls| {
                    if (cls.contains(@intCast(byte))) {
                        if (seed != null) return error.NotOnePass;
                        seed = nfa.states.items[s].out;
                    }
                }
            }
            var tbits: TagBits = 0;
            const move = try closeSeed(nfa, n, seed, a, &tbits);
            const key = std.mem.sliceAsBytes(move);
            const target = interned.get(key) orelse blk: {
                if (sets.items.len >= max_dfa_states) return error.DfaTooLarge;
                const idx = sets.items.len;
                try interned.put(key, idx);
                try sets.append(a, move);
                try accept.append(a, setContains(move, nfa.accept));
                break :blk idx;
            };
            try trans.append(a, @intCast(target));
            try tag_lists.append(a, try tagIds(a, tbits));
        }
    }

    const nstates = sets.items.len;
    const trans_out = try allocator.alloc(u32, nstates * 256);
    @memcpy(trans_out, trans.items);
    const accept_out = try allocator.alloc(bool, nstates);
    @memcpy(accept_out, accept.items);

    var total: usize = 0;
    for (tag_lists.items) |tl| total += tl.len;
    const tag_off = try allocator.alloc(u32, nstates * 256 + 1);
    const tag_ids_out = try allocator.alloc(u8, total);
    var acc: u32 = 0;
    for (tag_lists.items, 0..) |tl, i| {
        tag_off[i] = acc;
        for (tl) |t| {
            tag_ids_out[acc] = t;
            acc += 1;
        }
    }
    tag_off[nstates * 256] = acc;

    return TaggedDfa{
        .n_states = nstates,
        .n_tags = nt,
        .trans = trans_out,
        .tag_off = tag_off,
        .tag_ids = tag_ids_out,
        .start_tags = try tagIds(allocator, start_bits),
        .accept = accept_out,
        .start = 0,
        .allocator = allocator,
    };
}

fn taggedDfaFor(allocator: std.mem.Allocator, src: []const u8) !TaggedDfa {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const an = try analyze(arena.allocator(), src);
    var nfa = try buildNfa(arena.allocator(), an.root);
    return buildTaggedDfa(allocator, &nfa);
}

test "tagged-dfa: dims flagship spans match the pike vm" {
    var td = try taggedDfaFor(testing.allocator, "(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)");
    defer td.deinit();
    var out: [max_tags]u32 = undefined;
    try testing.expect(td.run("25x300x1", out[0..6]));
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3, 6, 7, 8 }, out[0..6]);
    try testing.expect(!td.run("25x300", out[0..6]));
    try testing.expect(!td.run("", out[0..6]));
}

test "tagged-dfa == pike vm: spans agree across patterns and inputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patterns = [_][]const u8{
        "(?<l>[0-9]+)x(?<w>[0-9]+)x(?<h>[0-9]+)",
        "(?<n>[0-9]+)x(?<m>[0-9]+)",
        "(?<a>[A-Za-z]+) to (?<b>[A-Za-z]+) = (?<d>[0-9]+)",
        "(?<x>a)(?<y>a)",
        "(?<g>ab|cd)e",
        "(?<outer>a(?<inner>b+)c)",
        "(?<neg>-?[0-9]+)",
    };
    const inputs = [_][]const u8{ "", "2x3x4", "25x300x1", "2x3", "12x34", "Foo to Bar = 99", "aa", "abe", "cde", "abbc", "x", "2x3x", "-42", "7", "Q to Z = 1" };
    for (patterns) |pat| {
        const an = try analyze(a, pat);
        var nfa = try buildNfa(a, an.root);
        const nt = nfa.n_tags;
        var td = buildTaggedDfa(testing.allocator, &nfa) catch |e| switch (e) {
            error.NotOnePass => continue, // legitimately falls back to the Pike VM
            else => return e,
        };
        defer td.deinit();
        var out: [max_tags]u32 = undefined;
        for (inputs) |inp| {
            const pike = try captures(a, &nfa, inp);
            const matched = td.run(inp, out[0..nt]);
            try testing.expectEqual(pike != null, matched);
            if (pike) |sp| {
                for (sp, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(v)), out[i]);
            }
        }
    }
}

test "tagged-dfa: ambiguous (groups over star) is rejected as not-one-pass" {
    // `(?<a>a*)(?<b>a*)` — both groups can consume 'a' from the same state, so
    // there's no single deterministic capture. The one-pass check must catch it
    // (the emitter then falls back to the Pike VM).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const an = try analyze(arena.allocator(), "(?<a>a*)(?<b>a*)");
    var nfa = try buildNfa(arena.allocator(), an.root);
    try testing.expectError(error.NotOnePass, buildTaggedDfa(testing.allocator, &nfa));
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

/// Emit `fn <name>(input: []const u8, from: usize) ?[2]usize { … }` — the
/// unanchored leftmost-LONGEST finder: returns {start, end} of the next match
/// at-or-after `from`, or null. Same DFA tables as `emitMatcher`; the only
/// difference is the scan-from-each-start + track-last-accept loop — the baked,
/// self-contained shape of `Dfa.scanAll`/`searchLongestFrom`. Correctness-first
/// (try-each-start); the dead-state early-exit is a later speed cut.
pub fn emitSearchMatcher(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    try w.print("fn {s}(input: []const u8, from: usize) ?[2]usize {{\n", .{name});
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
    try w.writeAll("    var start: usize = from;\n");
    try w.writeAll("    while (start <= input.len) : (start += 1) {\n");
    try w.print("        var s: u32 = {d};\n", .{dfa.start});
    try w.writeAll("        var last_end: ?usize = if (A[s]) start else null;\n");
    try w.writeAll("        var i: usize = start;\n");
    try w.writeAll("        while (i < input.len) : (i += 1) {\n");
    try w.writeAll("            s = T[@as(usize, s) * 256 + @as(usize, input[i])];\n");
    try w.writeAll("            if (A[s]) last_end = i + 1;\n");
    try w.writeAll("        }\n");
    try w.writeAll("        if (last_end) |e| return .{ start, e };\n");
    try w.writeAll("    }\n");
    try w.writeAll("    return null;\n");
    try w.writeAll("}\n");
}

/// Compile a pattern to a self-contained unanchored search function (the
/// span-finder `scan` loops over). Captures, if any, are extracted per span by
/// the matcher from `compileCapturesToZig` — this only locates the spans.
pub fn compileSearchToZig(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitSearchMatcher(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// Emit `fn <name>(input: []const u8, from: usize) ?usize { … }` — the ANCHORED
/// longest-prefix matcher at a fixed offset: returns the END of the longest
/// prefix of input[from..] the DFA accepts (span is [from, end)), or null if
/// nothing — not even the empty match — accepts. This is `Dfa.searchLongestFrom`
/// baked self-contained: `emitSearchMatcher`'s inner loop without the
/// try-each-start outer loop. It is the PARSER TERMINAL primitive — a grammar
/// terminal asks "does this token start HERE, and how far does it reach?",
/// never "where is it?" (search) or "is it everything?" (match).
///
/// Unlike the search emitter (where early-exit is a deferred speed cut), the
/// dead-state exit is emitted HERE AND NOW: a terminal typically matches a few
/// bytes near `from`, and without the exit every failed terminal walks to
/// end-of-input — an O(n²) parser on large inputs. The dead state is detected
/// at emit time (non-accepting, all 256 transitions self-looping); patterns
/// whose DFA has none simply omit the check.
pub fn emitPrefixMatcher(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    // Detect the dead sink: non-accepting, every byte loops back to itself.
    var dead: ?usize = null;
    var st: usize = 0;
    outer: while (st < dfa.n_states) : (st += 1) {
        if (dfa.accept[st]) continue;
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            if (dfa.trans[st * 256 + b] != st) continue :outer;
        }
        dead = st;
        break;
    }

    try w.print("fn {s}(input: []const u8, from: usize) ?usize {{\n", .{name});
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
    // Suffix-terminal DFA: every accepting state transitions ONLY to the dead
    // sink (accepting is a dead-end — string, keyword). Then an accept is
    // reached at most once, immediately before the dead break, so the per-byte
    // accept test/write is pure overhead: hoist it out and read the accept off
    // the state we broke on. Numbers (digit -> digit keeps accepting) are NOT
    // suffix-terminal and keep the per-byte last_end write.
    var suffix_terminal = dead != null;
    if (dead) |d| {
        for (0..dfa.n_states) |q| {
            if (!dfa.accept[q]) continue;
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (dfa.trans[q * 256 + b] != d) {
                    suffix_terminal = false;
                    break;
                }
            }
            if (!suffix_terminal) break;
        }
    }

    try w.print("    var s: u32 = {d};\n", .{dfa.start});
    if (suffix_terminal) {
        // No per-byte accept work: walk transitions until dead/end, then the
        // state we stopped on decides the (single) match end — `i` at the dead
        // break is exactly the accepting end, `input.len` at a clean run-out.
        // `for` over the input SPAN, not a manual-index `while` — the canonical
        // monotonic-iteration form the for-over-while rule prefers (measured on
        // Zig hot loops). `end` carries the break position out of the loop body.
        try w.writeAll("    if (A[s]) return from;\n");
        try w.writeAll("    var end: usize = input.len;\n");
        try w.writeAll("    for (input[from..], from..) |b, i| {\n");
        try w.print("        const ns = T[@as(usize, s) * 256 + @as(usize, b)];\n", .{});
        try w.print("        if (ns == {d}) {{ end = i; break; }}\n", .{dead.?});
        try w.writeAll("        s = ns;\n");
        try w.writeAll("    }\n");
        try w.writeAll("    return if (A[s]) end else null;\n");
        try w.writeAll("}\n");
        return;
    }
    try w.writeAll("    var last_end: ?usize = if (A[s]) from else null;\n");
    try w.writeAll("    for (input[from..], from..) |b, i| {\n");
    try w.writeAll("        s = T[@as(usize, s) * 256 + @as(usize, b)];\n");
    if (dead) |d| try w.print("        if (s == {d}) break;\n", .{d});
    try w.writeAll("        if (A[s]) last_end = i + 1;\n");
    try w.writeAll("    }\n");
    try w.writeAll("    return last_end;\n");
    try w.writeAll("}\n");
}

/// Compile a pattern to a self-contained anchored longest-prefix-at-offset
/// function (the parser terminal primitive; see `emitPrefixMatcher`). Captures,
/// if any, are extracted from the matched span by the matcher from
/// `compileCapturesToZig` — exactly the search/captures split `scan` uses.
pub fn compilePrefixToZig(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitPrefixMatcher(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// C sibling of `emitPrefixMatcher`. Same DFA, C vocabulary: a slice is a
/// `(const uint8_t* input, size_t len)` pair; the `?usize` result becomes a
/// `size_t` returning the match end, or `SIZE_MAX` for "no match" (offsets are
/// always < len <= SIZE_MAX, so the sentinel is unambiguous). The suffix-terminal
/// accept-write hoist (rung 3) carries over unchanged. Emitted functions assume
/// <stdint.h>/<stddef.h>/<stdbool.h> are included by the enclosing file.
pub fn emitPrefixMatcherC(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    // Detect the dead sink: non-accepting, every byte loops back to itself.
    var dead: ?usize = null;
    var st: usize = 0;
    outer: while (st < dfa.n_states) : (st += 1) {
        if (dfa.accept[st]) continue;
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            if (dfa.trans[st * 256 + b] != st) continue :outer;
        }
        dead = st;
        break;
    }

    try w.print("static size_t {s}(const uint8_t* input, size_t len, size_t from) {{\n", .{name});
    try w.writeAll("    static const uint32_t T[] = { ");
    for (dfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d}", .{t});
    }
    try w.writeAll(" };\n");
    try w.writeAll("    static const bool A[] = { ");
    for (dfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll(" };\n");

    // Suffix-terminal DFA: every accepting state transitions ONLY to the dead
    // sink — accept reached at most once, immediately before break, so the
    // per-byte accept test is pure overhead (rung 3). Numbers (digit -> digit
    // re-accepts) are NOT suffix-terminal and keep the per-byte write.
    var suffix_terminal = dead != null;
    if (dead) |d| {
        for (0..dfa.n_states) |q| {
            if (!dfa.accept[q]) continue;
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (dfa.trans[q * 256 + b] != d) {
                    suffix_terminal = false;
                    break;
                }
            }
            if (!suffix_terminal) break;
        }
    }

    try w.print("    uint32_t s = {d};\n", .{dfa.start});
    // The byte-scan is a `for` over a KNOWN SPAN, never a manual-index `while`:
    // `for (i = from; i < len; i++)` hands the C compiler a canonical monotonic
    // induction variable + contiguous bounds over `input`, unlocking
    // vectorization / bounds-check elision / alias analysis. A hand-index while
    // with a bottom `i++` emits weaker IR for the same logic (the standing
    // for-over-while rule — measured up to ~20% on hot loops). This IS the
    // recognizer's inner loop, so it is exactly where the span form pays.
    if (suffix_terminal) {
        try w.writeAll("    if (A[s]) return from;\n");
        try w.writeAll("    size_t i = from;\n");
        try w.writeAll("    for (i = from; i < len; i++) {\n");
        try w.writeAll("        uint32_t ns = T[(size_t)s * 256 + (size_t)input[i]];\n");
        try w.print("        if (ns == {d}) break;\n", .{dead.?});
        try w.writeAll("        s = ns;\n");
        try w.writeAll("    }\n");
        try w.writeAll("    return A[s] ? i : SIZE_MAX;\n");
        try w.writeAll("}\n");
        return;
    }
    try w.writeAll("    size_t last_end = A[s] ? from : SIZE_MAX;\n");
    try w.writeAll("    for (size_t i = from; i < len; i++) {\n");
    try w.writeAll("        s = T[(size_t)s * 256 + (size_t)input[i]];\n");
    if (dead) |d| try w.print("        if (s == {d}) break;\n", .{d});
    try w.writeAll("        if (A[s]) last_end = i + 1;\n");
    try w.writeAll("    }\n");
    try w.writeAll("    return last_end;\n");
    try w.writeAll("}\n");
}

/// C sibling of `compilePrefixToZig` — compile a pattern to a self-contained
/// anchored longest-prefix-at-offset C function.
pub fn compilePrefixToC(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitPrefixMatcherC(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// JS sibling of `emitPrefixMatcherC`. Same DFA, JS vocabulary: a slice is a
/// Node `Buffer` (byte-indexed, matching C's `const uint8_t*`) plus a
/// `(from)` offset; the "no match" sentinel is `-1` (offsets are always >= 0,
/// so it is unambiguous, mirroring C's SIZE_MAX). No goto in JS, so the
/// suffix-terminal early-return shape carries over as a plain early `return`
/// inside the loop instead of a labeled break — this matcher never needs to
/// jump past its own loop, only return from the function.
pub fn emitPrefixMatcherJs(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    var dead: ?usize = null;
    var st: usize = 0;
    outer: while (st < dfa.n_states) : (st += 1) {
        if (dfa.accept[st]) continue;
        var b: usize = 0;
        while (b < 256) : (b += 1) {
            if (dfa.trans[st * 256 + b] != st) continue :outer;
        }
        dead = st;
        break;
    }

    try w.print("function {s}(input, len, from) {{\n", .{name});
    try w.writeAll("    const T = [");
    for (dfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{t});
    }
    try w.writeAll("];\n");
    try w.writeAll("    const A = [");
    for (dfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll("];\n");

    var suffix_terminal = dead != null;
    if (dead) |d| {
        for (0..dfa.n_states) |q| {
            if (!dfa.accept[q]) continue;
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (dfa.trans[q * 256 + b] != d) {
                    suffix_terminal = false;
                    break;
                }
            }
            if (!suffix_terminal) break;
        }
    }

    try w.print("    let s = {d};\n", .{dfa.start});
    if (suffix_terminal) {
        try w.writeAll("    if (A[s]) return from;\n");
        try w.writeAll("    let i = from;\n");
        try w.writeAll("    for (i = from; i < len; i++) {\n");
        try w.writeAll("        const ns = T[s * 256 + input[i]];\n");
        try w.print("        if (ns === {d}) break;\n", .{dead.?});
        try w.writeAll("        s = ns;\n");
        try w.writeAll("    }\n");
        try w.writeAll("    return A[s] ? i : -1;\n");
        try w.writeAll("}\n");
        return;
    }
    try w.writeAll("    let last_end = A[s] ? from : -1;\n");
    try w.writeAll("    for (let i = from; i < len; i++) {\n");
    try w.writeAll("        s = T[s * 256 + input[i]];\n");
    if (dead) |d| try w.print("        if (s === {d}) break;\n", .{d});
    try w.writeAll("        if (A[s]) last_end = i + 1;\n");
    try w.writeAll("    }\n");
    try w.writeAll("    return last_end;\n");
    try w.writeAll("}\n");
}

/// JS sibling of `compilePrefixToC`.
pub fn compilePrefixToJs(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitPrefixMatcherJs(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// JS sibling of `emitMatcher` — `function <name>(input) { … } → bool`, the
/// FULL-match predicate `std/regex:match` dispatches on.
///
/// `input` is a BYTE VIEW (Buffer / Uint8Array), never a js string, so the walk
/// consumes exactly the bytes the Zig matcher consumes and the two targets agree
/// on every non-ASCII pattern. `koru_std/parser.kz:1051` established that view
/// (`Buffer.from(s, "utf8")`) for the JS parser terminals; regex uses the same
/// one. Indexing a js string here would feed the table UTF-16 code units and
/// silently diverge from Zig on the first multi-byte character.
pub fn emitMatcherJs(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    try w.print("function {s}(input) {{\n", .{name});
    try w.writeAll("    const T = [");
    for (dfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{t});
    }
    try w.writeAll("];\n");
    try w.writeAll("    const A = [");
    for (dfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll("];\n");
    try w.print("    let s = {d};\n", .{dfa.start});
    try w.writeAll("    for (let i = 0; i < input.length; i++) s = T[s * 256 + input[i]];\n");
    try w.writeAll("    return A[s];\n");
    try w.writeAll("}\n");
}

/// JS sibling of `compileToZig`.
pub fn compileToJs(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitMatcherJs(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// JS sibling of `emitSearchMatcher` — `function <name>(input, from)` returning
/// `[start, end]` for the leftmost-longest match at-or-after `from`, or `null`.
///
/// Zig's `?usize` accumulator becomes a `-1` sentinel: offsets are non-negative,
/// so the sentinel cannot collide with a real end. The RETURN stays `null` rather
/// than a sentinel pair, because `scan`'s loop tests it directly and a nullable
/// object reads the same on both targets.
pub fn emitSearchMatcherJs(w: anytype, dfa: *const Dfa, name: []const u8) !void {
    try w.print("function {s}(input, from) {{\n", .{name});
    try w.writeAll("    const T = [");
    for (dfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{t});
    }
    try w.writeAll("];\n");
    try w.writeAll("    const A = [");
    for (dfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll("];\n");
    try w.writeAll("    for (let start = from; start <= input.length; start++) {\n");
    try w.print("        let s = {d};\n", .{dfa.start});
    try w.writeAll("        let last_end = A[s] ? start : -1;\n");
    try w.writeAll("        for (let i = start; i < input.length; i++) {\n");
    try w.writeAll("            s = T[s * 256 + input[i]];\n");
    try w.writeAll("            if (A[s]) last_end = i + 1;\n");
    try w.writeAll("        }\n");
    try w.writeAll("        if (last_end !== -1) return [start, last_end];\n");
    try w.writeAll("    }\n");
    try w.writeAll("    return null;\n");
    try w.writeAll("}\n");
}

/// JS sibling of `compileSearchToZig`.
pub fn compileSearchToJs(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    var dfa = try buildDfa(a, &nfa);
    var buf = std.ArrayList(u8){};
    try emitSearchMatcherJs(buf.writer(out), &dfa, name);
    return buf.toOwnedSlice(out);
}

/// The admissible FIRST-BYTE set of an anchored-prefix matcher: for each byte,
/// can a (non-empty) match begin with it? Derived from the prefix DFA's start
/// state — a byte is admissible iff consuming it lands in a LIVE state (one
/// from which some accept is still reachable). Bytes that fall straight into
/// the dead sink can never begin a match, so a caller may skip the matcher for
/// them entirely (std/parser's rung-1 first-byte gate). Conservative by
/// construction: it only ever excludes bytes that PROVABLY cannot start a
/// match, so gating on it cannot change which inputs match. If the matcher
/// accepts the empty string (start state is accepting), every byte is
/// admissible — the matcher always succeeds, so there is nothing to gate.
pub fn prefixFirstBytes(out: std.mem.Allocator, pattern: []const u8) ![256]bool {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, pattern);
    const ast = try p.parse();
    var nfa = try buildNfa(a, ast);
    const dfa = try buildDfa(a, &nfa);

    var result: [256]bool = undefined;
    // Empty match allowed → matcher never fails → never gate.
    if (dfa.accept[dfa.start]) {
        for (&result) |*x| x.* = true;
        return result;
    }

    // Liveness: a state is live if it accepts or can reach an accept. Backward
    // fixpoint over the transition table (states are few; grammars are tiny).
    const live = try a.alloc(bool, dfa.n_states);
    for (0..dfa.n_states) |s| live[s] = dfa.accept[s];
    var changed = true;
    while (changed) {
        changed = false;
        for (0..dfa.n_states) |s| {
            if (live[s]) continue;
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (live[dfa.trans[s * 256 + b]]) {
                    live[s] = true;
                    changed = true;
                    break;
                }
            }
        }
    }

    var b: usize = 0;
    while (b < 256) : (b += 1) {
        result[b] = live[dfa.trans[dfa.start * 256 + b]];
    }
    return result;
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
    // Fast path: one-pass tagged DFA (O(1)/byte). Any pattern that isn't
    // one-pass — or whose DFA blows the state cap — falls back to the Pike VM,
    // which is correct for every tagged NFA, just O(states)/byte.
    if (buildTaggedDfa(a, &nfa)) |tdfa| {
        var td = tdfa;
        try emitTaggedCapturesMatcher(buf.writer(out), &td, name);
    } else |err| switch (err) {
        error.NotOnePass, error.DfaTooLarge => try emitCapturesMatcher(buf.writer(out), &nfa, name),
        error.OutOfMemory => return error.OutOfMemory,
    }
    return buf.toOwnedSlice(out);
}

/// Emit the one-pass tagged DFA as `fn <name>(input) ?[<2N>]u32` — the table
/// walk `TaggedDfa.run` shows, baked self-contained. O(1) per byte: one
/// transition lookup plus firing this transition's (usually empty) tag set.
/// Same signature/tag layout as the Pike VM emitter, so the call site is
/// identical; this is just the fast specialization when the pattern is one-pass.
pub fn emitTaggedCapturesMatcher(w: anytype, tdfa: *const TaggedDfa, name: []const u8) !void {
    const nt = tdfa.n_tags;
    try w.print("fn {s}(input: []const u8) ?[{d}]u32 {{\n", .{ name, nt });

    try w.writeAll("    const T = [_]u32{ ");
    for (tdfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d}", .{t});
    }
    try w.writeAll(" };\n");

    try w.writeAll("    const A = [_]bool{ ");
    for (tdfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll(" };\n");

    try w.writeAll("    const TAG_OFF = [_]u32{ ");
    for (tdfa.tag_off, 0..) |o, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d}", .{o});
    }
    try w.writeAll(" };\n");

    try w.writeAll("    const TAG_ID = [_]u8{ ");
    if (tdfa.tag_ids.len == 0) {
        try w.writeAll("0"); // Zig rejects empty [_]T{}; the index range is dead
    } else {
        for (tdfa.tag_ids, 0..) |id, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{d}", .{id});
        }
    }
    try w.writeAll(" };\n");

    try w.print("    var tags = [_]u32{{0xFFFFFFFF}} ** {d};\n", .{nt});
    for (tdfa.start_tags) |t| try w.print("    tags[{d}] = 0;\n", .{t});
    try w.print("    var s: u32 = {d};\n", .{tdfa.start});
    try w.writeAll("    for (input, 0..) |c, ip| {\n");
    try w.writeAll("        const base = @as(usize, s) * 256 + @as(usize, c);\n");
    try w.writeAll("        var k: usize = TAG_OFF[base];\n");
    try w.writeAll("        while (k < TAG_OFF[base + 1]) : (k += 1) tags[TAG_ID[k]] = @as(u32, @intCast(ip + 1));\n");
    try w.writeAll("        s = T[base];\n");
    try w.writeAll("    }\n");
    try w.writeAll("    if (!A[s]) return null;\n");
    try w.writeAll("    return tags;\n}\n");
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

/// JS sibling of `compileCapturesToZig` — same two-path choice, same tag layout,
/// so `match`/`scan` read the result identically on both targets.
pub fn compileCapturesToJs(out: std.mem.Allocator, pattern: []const u8, name: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(out);
    defer arena.deinit();
    const a = arena.allocator();
    const analysis = try analyze(a, pattern);
    var nfa = try buildNfa(a, analysis.root);
    std.debug.assert(nfa.n_tags > 0); // groupless patterns take the DFA path
    var buf = std.ArrayList(u8){};
    if (buildTaggedDfa(a, &nfa)) |tdfa| {
        var td = tdfa;
        try emitTaggedCapturesMatcherJs(buf.writer(out), &td, name);
    } else |err| switch (err) {
        error.NotOnePass, error.DfaTooLarge => try emitCapturesMatcherJs(buf.writer(out), &nfa, name),
        error.OutOfMemory => return error.OutOfMemory,
    }
    return buf.toOwnedSlice(out);
}

/// JS sibling of `emitTaggedCapturesMatcher` — `function <name>(input)` returning
/// the tag array, or `null` when the input does not fully match.
///
/// The empty-table workaround its Zig kin carries is absent on purpose: Zig
/// rejects `[_]T{}`, JavaScript accepts `[]`, so the honest empty array is
/// emitted rather than a dummy element sitting in a dead index range.
pub fn emitTaggedCapturesMatcherJs(w: anytype, tdfa: *const TaggedDfa, name: []const u8) !void {
    const nt = tdfa.n_tags;
    try w.print("function {s}(input) {{\n", .{name});

    try w.writeAll("    const T = [");
    for (tdfa.trans, 0..) |t, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{t});
    }
    try w.writeAll("];\n");

    try w.writeAll("    const A = [");
    for (tdfa.accept, 0..) |acc, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll(if (acc) "true" else "false");
    }
    try w.writeAll("];\n");

    try w.writeAll("    const TAG_OFF = [");
    for (tdfa.tag_off, 0..) |o, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{o});
    }
    try w.writeAll("];\n");

    try w.writeAll("    const TAG_ID = [");
    for (tdfa.tag_ids, 0..) |id, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("{d}", .{id});
    }
    try w.writeAll("];\n");

    try w.print("    const tags = new Uint32Array({d}).fill(0xFFFFFFFF);\n", .{nt});
    for (tdfa.start_tags) |t| try w.print("    tags[{d}] = 0;\n", .{t});
    try w.print("    let s = {d};\n", .{tdfa.start});
    try w.writeAll("    for (let ip = 0; ip < input.length; ip++) {\n");
    try w.writeAll("        const base = s * 256 + input[ip];\n");
    try w.writeAll("        for (let k = TAG_OFF[base]; k < TAG_OFF[base + 1]; k++) tags[TAG_ID[k]] = ip + 1;\n");
    try w.writeAll("        s = T[base];\n");
    try w.writeAll("    }\n");
    try w.writeAll("    if (!A[s]) return null;\n");
    try w.writeAll("    return tags;\n}\n");
}

/// JS sibling of `emitCapturesMatcher` — the specialized Pike VM, for the
/// patterns that are not one-pass.
///
/// ONE STRUCTURAL DIVERGENCE, and it is forced rather than stylistic: the Zig
/// emitter packs class membership as `[4]u64` and tests it with a 64-bit shift.
/// JavaScript's bitwise operators coerce to 32 bits, so a `u64` mask would be
/// silently truncated — every class above byte 31 would stop matching. The JS
/// rendering therefore packs the same 256 bits as `[8]u32` and indexes with
/// `c >> 5` / `c & 31`. Identical information, a word size the host can actually
/// test, and the reason this is a rendering rather than a transliteration.
pub fn emitCapturesMatcherJs(w: anytype, nfa: *const Nfa, name: []const u8) !void {
    const ns = nfa.states.items.len;
    const nt = nfa.n_tags;

    try w.print("function {s}(input) {{\n", .{name});
    try w.print("    const NS = {d}, NT = {d};\n", .{ ns, nt });
    try w.writeAll("    const UNSET = 0xFFFFFFFF;\n");

    try w.writeAll("    const OUT = [");
    for (nfa.states.items, 0..) |st, i| {
        if (i != 0) try w.writeAll(",");
        if (st.sym != null) try w.print("{d}", .{st.out}) else try w.writeAll("0xFFFFFFFF");
    }
    try w.writeAll("];\n");

    // 256 bits per state as [8]u32 — see the divergence note above.
    try w.writeAll("    const MASK = [");
    for (nfa.states.items, 0..) |st, si| {
        var mask = [_]u32{0} ** 8;
        if (st.sym) |cls| {
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (cls.contains(@intCast(b))) mask[b >> 5] |= @as(u32, 1) << @intCast(b & 31);
            }
        }
        if (si != 0) try w.writeAll(",");
        try w.print("[{d},{d},{d},{d},{d},{d},{d},{d}]", .{ mask[0], mask[1], mask[2], mask[3], mask[4], mask[5], mask[6], mask[7] });
    }
    try w.writeAll("];\n");

    try w.writeAll("    const EPS_OFF = [0");
    {
        var off: usize = 0;
        for (nfa.states.items) |st| {
            off += st.eps.items.len;
            try w.print(",{d}", .{off});
        }
    }
    try w.writeAll("];\n");

    try w.writeAll("    const EPS_TO = [");
    {
        var first = true;
        for (nfa.states.items) |st| {
            for (st.eps.items) |e| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{d}", .{e.to});
            }
        }
    }
    try w.writeAll("];\n");

    try w.writeAll("    const EPS_TAG = [");
    {
        var first = true;
        for (nfa.states.items) |st| {
            for (st.eps.items) |e| {
                if (!first) try w.writeAll(",");
                first = false;
                if (e.tag) |t| try w.print("{d}", .{t}) else try w.writeAll("-1");
            }
        }
    }
    try w.writeAll("];\n");

    try w.print("    const START = {d}, ACCEPT = {d};\n", .{ nfa.start, nfa.accept });

    try w.writeAll(
        \\    function add(on, order, st, tags, s, t, pos) {
        \\        if (on[s]) return;
        \\        on[s] = true;
        \\        tags[s] = t.slice();
        \\        order[st.count++] = s;
        \\        for (let i = EPS_OFF[s]; i < EPS_OFF[s + 1]; i++) {
        \\            const t2 = t.slice();
        \\            if (EPS_TAG[i] >= 0) t2[EPS_TAG[i]] = pos;
        \\            add(on, order, st, tags, EPS_TO[i], t2, pos);
        \\        }
        \\    }
        \\    let on = new Array(NS).fill(false);
        \\    let order = new Array(NS);
        \\    let tags = new Array(NS);
        \\    let st = { count: 0 };
        \\    add(on, order, st, tags, START, new Array(NT).fill(UNSET), 0);
        \\    for (let ip = 0; ip < input.length; ip++) {
        \\        const c = input[ip];
        \\        const on2 = new Array(NS).fill(false);
        \\        const order2 = new Array(NS);
        \\        const tags2 = new Array(NS);
        \\        const st2 = { count: 0 };
        \\        for (let k = 0; k < st.count; k++) {
        \\            const s = order[k];
        \\            if (OUT[s] !== UNSET && ((MASK[s][c >> 5] >>> (c & 31)) & 1) === 1) {
        \\                add(on2, order2, st2, tags2, OUT[s], tags[s], ip + 1);
        \\            }
        \\        }
        \\        on = on2; order = order2; tags = tags2; st = st2;
        \\        if (st.count === 0) return null;
        \\    }
        \\    if (!on[ACCEPT]) return null;
        \\    return tags[ACCEPT];
        \\}
        \\
    );
}

test "emit js: full-match matcher carries the same table as its Zig kin" {
    const js = try compileToJs(testing.allocator, "[a-z]+@[a-z]+", "m0");
    defer testing.allocator.free(js);
    try testing.expect(std.mem.indexOf(u8, js, "function m0(input) {") != null);
    try testing.expect(std.mem.indexOf(u8, js, "return A[s];") != null);
    // No Zig type syntax may survive into JavaScript — the exact leak that made
    // every regex test fail with "Missing initializer in const declaration".
    try testing.expect(std.mem.indexOf(u8, js, "[]const u8") == null);
    try testing.expect(std.mem.indexOf(u8, js, "[_]u32") == null);

    var dfa = try dfaFor(testing.allocator, "[a-z]+@[a-z]+");
    defer dfa.deinit();
    var commas: usize = 0;
    const t_start = std.mem.indexOf(u8, js, "const T = [").?;
    const t_end = std.mem.indexOfPos(u8, js, t_start, "];").?;
    for (js[t_start..t_end]) |c| {
        if (c == ',') commas += 1;
    }
    try testing.expectEqual(dfa.n_states * 256, commas + 1);
}

test "emit js: search finder returns a span pair, null when nothing matches" {
    const js = try compileSearchToJs(testing.allocator, "[0-9]+", "f0");
    defer testing.allocator.free(js);
    try testing.expect(std.mem.indexOf(u8, js, "function f0(input, from) {") != null);
    try testing.expect(std.mem.indexOf(u8, js, "return [start, last_end];") != null);
    try testing.expect(std.mem.indexOf(u8, js, "return null;") != null);
    try testing.expect(std.mem.indexOf(u8, js, "?[2]usize") == null);
}

test "emit js: captures matcher packs class masks as u32, never u64" {
    // `(?<a>[0-9]+)x(?<b>[0-9]+)` is one-pass, so this takes the tagged-DFA path.
    const js = try compileCapturesToJs(testing.allocator, "(?<a>[0-9]+)x(?<b>[0-9]+)", "c0");
    defer testing.allocator.free(js);
    try testing.expect(std.mem.indexOf(u8, js, "function c0(input) {") != null);
    try testing.expect(std.mem.indexOf(u8, js, "new Uint32Array(") != null);
    try testing.expect(std.mem.indexOf(u8, js, "return tags;") != null);
    try testing.expect(std.mem.indexOf(u8, js, "[_]u32") == null);
}

test "emit js: the Pike VM fallback shifts within 32 bits" {
    // A back-to-back optional group defeats the one-pass check, forcing the VM.
    const js = try compileCapturesToJs(testing.allocator, "(?<a>[a-z]*)(?<b>[a-z]*)", "v0");
    defer testing.allocator.free(js);
    try testing.expect(std.mem.indexOf(u8, js, "function v0(input) {") != null);
    // The whole point of the divergence: 32-bit indexing, never `c >> 6`.
    try testing.expect(std.mem.indexOf(u8, js, "MASK[s][c >> 5] >>> (c & 31)") != null);
    try testing.expect(std.mem.indexOf(u8, js, "c >> 6") == null);
    // Eight words of 32 bits cover the same 256 bytes as four of 64.
    const m_start = std.mem.indexOf(u8, js, "const MASK = [[").?;
    const m_end = std.mem.indexOfPos(u8, js, m_start, "]];").?;
    var commas: usize = 0;
    for (js[m_start + "const MASK = [[".len .. m_end]) |c| {
        if (c == ',') commas += 1;
    }
    // n_states groups of 8 words: (8*n - 1) inner commas + (n - 1) separators.
    try testing.expect(commas > 0 and (commas + 1) % 8 == 0);
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

test "emit search: well-formed unanchored finder fn" {
    const src = try compileSearchToZig(testing.allocator, "[0-9]+", "f0");
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "fn f0(input: []const u8, from: usize) ?[2]usize") != null);
    try testing.expect(std.mem.indexOf(u8, src, "const T = [_]u32{") != null);
    try testing.expect(std.mem.indexOf(u8, src, "while (start <= input.len)") != null);
    try testing.expect(std.mem.indexOf(u8, src, "if (last_end) |e| return .{ start, e };") != null);
}

test "emit prefix: well-formed anchored longest-prefix fn with dead-state exit" {
    const src = try compilePrefixToZig(testing.allocator, "[0-9]+", "p0");
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "fn p0(input: []const u8, from: usize) ?usize") != null);
    try testing.expect(std.mem.indexOf(u8, src, "const T = [_]u32{") != null);
    try testing.expect(std.mem.indexOf(u8, src, "return last_end;") != null);
    // anchored: no try-each-start outer loop
    try testing.expect(std.mem.indexOf(u8, src, "while (start <= input.len)") == null);
    // `[0-9]+` has a dead sink (any non-digit) — the early-exit must be emitted
    try testing.expect(std.mem.indexOf(u8, src, "break;") != null);
}

test "emit prefix: suffix-terminal patterns hoist the accept-write out of the loop" {
    // A JSON string terminal: the only accepting state (post-close-quote)
    // transitions solely to the dead sink, so no per-byte last_end write.
    {
        const src = try compilePrefixToZig(testing.allocator, "\"([^\"\\\\]|\\\\.)*\"", "ps");
        defer testing.allocator.free(src);
        try testing.expect(std.mem.indexOf(u8, src, "last_end = i + 1;") == null);
        // The single accept-read off the stopped state. The scan loops over the
        // input SPAN with `for (input[from..], from..) |b, i|`, so the break
        // position is carried out in `end` (the for-body's `i` is scoped) — the
        // hoist (no per-byte last_end) is what this test pins, not the loop form.
        try testing.expect(std.mem.indexOf(u8, src, "return if (A[s]) end else null;") != null);
    }
    // A keyword terminal — accepts only at word end, also suffix-terminal.
    {
        const src = try compilePrefixToZig(testing.allocator, "true|false|null", "pk");
        defer testing.allocator.free(src);
        try testing.expect(std.mem.indexOf(u8, src, "last_end = i + 1;") == null);
    }
    // A number terminal: digit -> digit keeps re-accepting, so it is NOT
    // suffix-terminal and MUST keep the per-byte last_end write.
    {
        const src = try compilePrefixToZig(testing.allocator, "-?(0|[1-9][0-9]*)(\\.[0-9]+)?", "pn");
        defer testing.allocator.free(src);
        try testing.expect(std.mem.indexOf(u8, src, "last_end = i + 1;") != null);
    }
}

test "prefix first-bytes: only the admissible starts are set" {
    // `[0-9]+` — digits begin a match, nothing else does.
    {
        const fb = try prefixFirstBytes(testing.allocator, "[0-9]+");
        for (0..256) |b| {
            const want = (b >= '0' and b <= '9');
            try testing.expectEqual(want, fb[b]);
        }
    }
    // JSON string terminal — only `"` can begin it.
    {
        const fb = try prefixFirstBytes(testing.allocator, "\"([^\"\\\\]|\\\\.)*\"");
        for (0..256) |b| try testing.expectEqual(b == '"', fb[b]);
    }
    // JSON keyword terminal — first bytes are exactly f/n/t.
    {
        const fb = try prefixFirstBytes(testing.allocator, "true|false|null");
        for (0..256) |b| {
            const want = (b == 'f' or b == 'n' or b == 't');
            try testing.expectEqual(want, fb[b]);
        }
    }
    // Nullable matcher (`[0-9]*` accepts empty) — every byte admissible, no gate.
    {
        const fb = try prefixFirstBytes(testing.allocator, "[0-9]*");
        for (0..256) |b| try testing.expect(fb[b]);
    }
}
