// Template processor pass.
//
// Two modes, distinguished by variant-arg:
//
//   `~proc foo|template|zig {...}`       — PER-CALL (default, not yet built):
//                                          render the body per invocation
//                                          with call-site captured args in
//                                          the context, inline at call site.
//   `~proc foo|template(once)|zig {...}` — PER-DECL (one-shot): render the
//                                          body once at proc-decl time with
//                                          proc-decl context; result shared
//                                          across all invocations.
//
// Per-call subsumes per-decl semantically, but per-decl is preserved as an
// opt-in for the (probably rare) case where the user wants the contract
// guarantee that the template doesn't depend on call args.
//
// This implements the variant-with-args story already established for
// `|zig(reference)` / `|zig(optimized)` in the suite.

const std = @import("std");
const ast = @import("ast");
const liquid = @import("liquid");
const log = @import("log");
const errors = @import("errors");
const struct_literal = @import("struct_literal");

const TEMPLATE_TAG = "template";
const ONCE_MODE = "once";

/// A `{% comp error %}` reached during template rendering is a template-author
/// contract violation (e.g. a required branch the consumer didn't provide).
/// Surface it as a located Koru diagnostic (KORU120) pointing at the source
/// the template was rendered for, then fail the compile cleanly — never let
/// the host language's downstream error be the one the user sees.
fn emitCompErrorAndExit(location: errors.SourceLocation, message: []const u8) noreturn {
    std.debug.print("error[{s}]: {s}\n  --> {s}:{d}:{d}\n", .{
        @tagName(errors.ErrorCode.KORU120),
        message,
        location.file,
        location.line,
        location.column,
    });
    std.process.exit(1);
}

/// An `{% if %}` / `{% unless %}` condition the template engine cannot parse
/// (KORU125). The failure this replaces was silent: the whole condition text was
/// taken as one variable NAME, so it missed, read as false, and rendered the
/// `{% else %}` branch forever — the guarded branch sat there looking live while
/// being dead code. Teach the grammar at the point of the mistake.
fn emitInvalidConditionAndExit(location: errors.SourceLocation, condition: []const u8) noreturn {
    std.debug.print(
        \\error[{s}]: template condition `{s}` is not something `{{% if %}}` can evaluate
        \\  --> {s}:{d}:{d}
        \\
        \\  a condition is a bare key, or two operands compared with `==` / `!=`:
        \\      {{% if arm.guard %}}              key is truthy (missing key = false)
        \\      {{% if arm.guard != "" %}}        key is bound and non-empty
        \\      {{% if node.kind == "call" %}}    key equals a literal
        \\
        \\  an operand is a key or a "quoted literal". `and`, `or`, `>` and filters
        \\  are not part of the grammar — restructure with nested tags, or move the
        \\  decision into the Zig side that builds the context.
        \\
    , .{
        @tagName(errors.ErrorCode.KORU125),
        condition,
        location.file,
        location.line,
        location.column,
    });
    std.process.exit(1);
}

/// Index of a top-level `..` (range operator) in `s` — one not nested inside
/// `()`/`[]`/`{}` (so a slice like `buf[0..n]` is NOT seen as a range). Null if
/// there is no top-level range. The "simplified ranges for JS" classifier; the
/// richer Zig-subset translator is the deferred follow-up (docs/PARSER_PALETTE.md §8.4).
fn findTopLevelRange(s: []const u8) ?usize {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        switch (s[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '.' => if (depth == 0 and s[i + 1] == '.') return i,
            else => {},
        }
    }
    return null;
}

/// `parse_range(expr)` filter: classify an iterable expression as a range.
/// Returns a record node `{ is_range, lo, hi }` the `for|template|js` body
/// branches on — a range becomes a JS counting loop, anything else stays a
/// `for…of`. This is the simplified-range path that unblocks cross-target `~for`
/// (140_014); it deliberately handles only `LO..HI`, leaving array literals etc.
/// to flow through verbatim (which already works for JS-shaped iterables).
fn parseRangeFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const s = std.mem.trim(u8, args[0].string, " \t");

    const node = try allocator.create(liquid.Context);
    node.* = liquid.Context.init(allocator);
    if (findTopLevelRange(s)) |idx| {
        try node.put("is_range", .{ .boolean = true });
        try node.put("lo", .{ .string = std.mem.trim(u8, s[0..idx], " \t") });
        try node.put("hi", .{ .string = std.mem.trim(u8, s[idx + 2 ..], " \t") });
    } else {
        try node.put("is_range", .{ .boolean = false });
    }
    return liquid.Value{ .record = node };
}

/// Return the index of the next top-level `,` (or end / closing `}`) at or
/// after `start`, treating `{}`/`()`/`[]` nesting and `"…"` string literals as
/// opaque. Mirrors codegen_utils.parseValue's depth tracking — the value of a
/// field runs until the next separator that isn't inside a nested construct.
fn scanValueEnd(s: []const u8, start: usize) usize {
    var i = start;
    var brace: usize = 0;
    var paren: usize = 0;
    var bracket: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
            }
            continue; // i lands on the closing quote; loop's i+=1 steps past it
        }
        switch (c) {
            '{' => brace += 1,
            '}' => {
                if (brace == 0) break; // closing brace of an unstripped struct → end
                brace -= 1;
            },
            '(' => paren += 1,
            ')' => if (paren > 0) {
                paren -= 1;
            },
            '[' => bracket += 1,
            ']' => if (bracket > 0) {
                bracket -= 1;
            },
            // A top-level `,` OR newline ends a field. Newlines inside a nested
            // construct (a multi-line struct value) are protected by depth, so a
            // value may still span lines when braced — only an unnested newline
            // separates fields (the canonical `const { … }` block shape).
            ',', '\n', '\r' => if (brace == 0 and paren == 0 and bracket == 0) break,
            else => {},
        }
    }
    return i;
}

/// Koru-native base types — a bounded, defined set (mirrors the units-of-measure
/// scope guard). Only these are recognized as a `value[type]` annotation; anything
/// else in a trailing `[…]` (array literals `[1,2,3]`, indexing) is left in the value.
/// The `value[type]` annotation parser lives in struct_literal (the projector
/// module) — `const`'s filter here and `capture`'s seed builder both call THAT
/// single implementation, so the two lowerings cannot drift.
const peelBaseType = struct_literal.peelBaseType;

/// Infer the Zig element type of a homogeneous array-literal body from its
/// first element: a string literal ⇒ `[]const u8`, an integer literal ⇒ `i64`.
/// Returns null when it can't tell (empty or mixed/other) — the caller then
/// leaves the value verbatim and Zig reports the real error loudly.
fn inferElemType(inner: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, inner, " \t\n\r");
    if (t.len == 0) return null;
    if (t[0] == '"') return "[]const u8";
    if (t[0] == '-' or std.ascii.isDigit(t[0])) return "i64";
    return null;
}

/// Render a `const {}` field value for the ZIG target. Three cases, same parser
/// the JS variant uses so they can't drift on what a "value" is:
///   • array literal `[a, b, c]` → `[_]<elem>{ a, b, c }` (elem from the
///     `[type]` annotation if present, else inferred). Koru/JS `[...]` syntax
///     is NOT valid Zig, so this is the lowering that makes pure-`.k` const
///     arrays compile at all.
///   • typed scalar `42[i32]`    → `@as(i32, 42)`
///   • everything else           → verbatim (strings, bools, bare numbers)
fn renderZigConstValue(allocator: std.mem.Allocator, value: []const u8, type_ann: []const u8) ![]const u8 {
    const v = std.mem.trim(u8, value, " \t\n\r");
    if (v.len >= 2 and v[0] == '[' and v[v.len - 1] == ']') {
        const inner = std.mem.trim(u8, v[1 .. v.len - 1], " \t\n\r");
        const elem = if (type_ann.len > 0) type_ann else (inferElemType(inner) orelse return allocator.dupe(u8, v));
        return std.fmt.allocPrint(allocator, "[_]{s}{{ {s} }}", .{ elem, inner });
    }
    if (type_ann.len > 0) return std.fmt.allocPrint(allocator, "@as({s}, {s})", .{ type_ann, v });
    return allocator.dupe(u8, v);
}

/// `parse_fields(struct_text)` filter: split a brace-optional Koru field list
/// (`name: "X", count: 42[i32]`, or `{ … }`, comma- OR newline-separated) into an
/// array of `{ name, value, type }` record nodes the template iterates with
/// `{% for f in fields %}`. `type` is the OPTIONAL Koru-native base-type annotation
/// (`42[i32]` → value "42", type "i32"); empty when absent. The per-target template
/// branches on `{% if f.type %}` to emit `@as(i32, 42)` (Zig) vs `42` (JS) — the
/// annotation is the first thing that genuinely DIVERGES between the variants. Both
/// `|zig` and `|js` call THIS single parser, so the lowerings cannot drift. The
/// input is a Source's `.text`, so the caller has location context for diagnostics.
fn parseFieldsFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const input = std.mem.trim(u8, args[0].string, " \t\n\r");
    // Accept the field list with or without wrapping braces.
    const body = if (input.len >= 2 and input[0] == '{' and input[input.len - 1] == '}')
        std.mem.trim(u8, input[1 .. input.len - 1], " \t\n\r")
    else
        input;

    var nodes: std.ArrayList(*liquid.Context) = .empty;

    var i: usize = 0;
    while (i < body.len) {
        // Skip whitespace and field separators (`,` or newline).
        while (i < body.len and (body[i] == ' ' or body[i] == '\t' or
            body[i] == '\n' or body[i] == '\r' or body[i] == ',')) i += 1;
        if (i >= body.len) break;

        // Field name (identifier).
        const name_start = i;
        while (i < body.len and (std.ascii.isAlphanumeric(body[i]) or body[i] == '_')) i += 1;
        const field_name = body[name_start..i];
        if (field_name.len == 0) break;

        // Skip whitespace, require `:`.
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
        if (i >= body.len or body[i] != ':') break;
        i += 1;
        while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;

        // Value runs until the next top-level separator.
        const value_start = i;
        i = scanValueEnd(body, i);
        const field_value = std.mem.trim(u8, body[value_start..i], " \t\n\r");
        const peeled = peelBaseType(field_value);

        const node = try allocator.create(liquid.Context);
        node.* = liquid.Context.init(allocator);
        try node.put("name", .{ .string = field_name });
        try node.put("value", .{ .string = peeled.value });
        try node.put("type", .{ .string = peeled.type });
        // `zig`: the value lowered for the Zig target (array literals → `[_]T{…}`,
        // typed scalars → `@as(T, v)`). JS keeps using `value` verbatim.
        const zig_rendered = renderZigConstValue(allocator, peeled.value, peeled.type) catch peeled.value;
        try node.put("zig", .{ .string = zig_rendered });
        try nodes.append(allocator, node);
    }

    return liquid.Value{ .array = try nodes.toOwnedSlice(allocator) };
}

/// Minimal integer-expression evaluator for comprehension `keep` guards. Supports
/// the bound variable, integer literals, `+ - * / %`, comparisons (`== != < <= >
/// >=` -> 1/0), `&& ||`, unary `! -`, parentheses, and the `gcd(a, b)` builtin —
/// the coprimality test the prime-sieve wheel needs. Returns null on any parse
/// error (caller treats it as a malformed comprehension). This is REAL comptime
/// evaluation in Zig — the sanctioned regex->DFA path — not string substitution.
const GuardEval = struct {
    s: []const u8,
    i: usize,
    var_name: []const u8,
    x: i64,

    fn eval(s: []const u8, var_name: []const u8, x: i64) ?i64 {
        var ge = GuardEval{ .s = s, .i = 0, .var_name = var_name, .x = x };
        const v = ge.pOr() orelse return null;
        ge.ws();
        if (ge.i != ge.s.len) return null; // trailing junk = malformed
        return v;
    }

    fn ws(self: *GuardEval) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
    }
    fn eat(self: *GuardEval, tok: []const u8) bool {
        self.ws();
        if (self.i + tok.len <= self.s.len and std.mem.eql(u8, self.s[self.i .. self.i + tok.len], tok)) {
            self.i += tok.len;
            return true;
        }
        return false;
    }
    fn pOr(self: *GuardEval) ?i64 {
        var l = self.pAnd() orelse return null;
        while (self.eat("||")) {
            const r = self.pAnd() orelse return null;
            l = if (l != 0 or r != 0) 1 else 0;
        }
        return l;
    }
    fn pAnd(self: *GuardEval) ?i64 {
        var l = self.pCmp() orelse return null;
        while (self.eat("&&")) {
            const r = self.pCmp() orelse return null;
            l = if (l != 0 and r != 0) 1 else 0;
        }
        return l;
    }
    fn pCmp(self: *GuardEval) ?i64 {
        const l = self.pAdd() orelse return null;
        if (self.eat("==")) return if (l == (self.pAdd() orelse return null)) 1 else 0;
        if (self.eat("!=")) return if (l != (self.pAdd() orelse return null)) 1 else 0;
        if (self.eat("<=")) return if (l <= (self.pAdd() orelse return null)) 1 else 0;
        if (self.eat(">=")) return if (l >= (self.pAdd() orelse return null)) 1 else 0;
        if (self.eat("<")) return if (l < (self.pAdd() orelse return null)) 1 else 0;
        if (self.eat(">")) return if (l > (self.pAdd() orelse return null)) 1 else 0;
        return l;
    }
    fn pAdd(self: *GuardEval) ?i64 {
        var l = self.pMul() orelse return null;
        while (true) {
            if (self.eat("+")) {
                l += self.pMul() orelse return null;
            } else if (self.eat("-")) {
                l -= self.pMul() orelse return null;
            } else break;
        }
        return l;
    }
    fn pMul(self: *GuardEval) ?i64 {
        var l = self.pUnary() orelse return null;
        while (true) {
            if (self.eat("*")) {
                l *= self.pUnary() orelse return null;
            } else if (self.eat("/")) {
                const r = self.pUnary() orelse return null;
                if (r == 0) return null;
                l = @divTrunc(l, r);
            } else if (self.eat("%")) {
                const r = self.pUnary() orelse return null;
                if (r == 0) return null;
                l = @mod(l, r);
            } else break;
        }
        return l;
    }
    fn pUnary(self: *GuardEval) ?i64 {
        if (self.eat("!")) return if ((self.pUnary() orelse return null) == 0) 1 else 0;
        if (self.eat("-")) return -(self.pUnary() orelse return null);
        return self.pPrimary();
    }
    fn pPrimary(self: *GuardEval) ?i64 {
        if (self.eat("(")) {
            const v = self.pOr() orelse return null;
            if (!self.eat(")")) return null;
            return v;
        }
        if (self.eat("gcd")) {
            if (!self.eat("(")) return null;
            const a = self.pOr() orelse return null;
            if (!self.eat(",")) return null;
            const b = self.pOr() orelse return null;
            if (!self.eat(")")) return null;
            return gcd(a, b);
        }
        self.ws();
        // Bound variable (identifier matching the generator's var name).
        if (self.i < self.s.len and (std.ascii.isAlphabetic(self.s[self.i]) or self.s[self.i] == '_')) {
            const start = self.i;
            while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_')) self.i += 1;
            const ident = self.s[start..self.i];
            if (std.mem.eql(u8, ident, self.var_name)) return self.x;
            return null; // unknown identifier — malformed for v1
        }
        // Integer literal.
        const start = self.i;
        while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
        if (self.i == start) return null;
        return std.fmt.parseInt(i64, self.s[start..self.i], 10) catch null;
    }
    fn gcd(a_: i64, b_: i64) i64 {
        var a = if (a_ < 0) -a_ else a_;
        var b = if (b_ < 0) -b_ else b_;
        while (b != 0) {
            const t = b;
            b = @mod(a, b);
            a = t;
        }
        return a;
    }
};

/// `table_from(comprehension_text)` filter: EVALUATE a v1 comprehension
/// `<var> over <lo>..<hi>` at COMPILE TIME into the list of integer values it
/// generates, returned as `{ v }` records the template bakes into a const table
/// (`{% for r in table_from(source) %}{{ r.v }}, {% endfor %}`). Upper-exclusive,
/// matching the sieve's `for(2..1001)`. This is the regex->DFA move generalized
/// from strings to data: a restricted, closed comprehension read at comptime and
/// lowered to a native table. The COMPUTATION here is real Zig integer iteration —
/// the banned shortcut is FAKING the table via string-substitution, never using a
/// template to EMIT a table a real evaluator computed. Both `|zig` and `|js`
/// variants call THIS one filter, so the two lowerings cannot drift.
/// The result of evaluating a comprehension: the generated values, the period (the
/// range's upper bound, used by the gap table's cyclic wraparound), and the element
/// type the table bakes to (`i64` by default; `x: usize over …` types it).
const Comprehension = struct { values: []i64, period: i64, elem_type: []const u8 };

/// Shared comptime evaluator for the `<var> over <lo>..<hi> [| keep <guard>]`
/// comprehension grammar. The single source of truth both `table_from` and
/// `table_gaps` (and future reduces) lower through — so the language has ONE
/// evaluator, not one per surface. (Inhale phase: it lives here as a filter helper;
/// the cohesion pass may re-home it to its own module behind this same interface.)
fn evalComprehension(allocator: std.mem.Allocator, raw: []const u8) anyerror!Comprehension {
    var input = std.mem.trim(u8, raw, " \t\n\r");
    // The block interior may arrive with or without wrapping braces.
    if (input.len >= 2 and input[0] == '{' and input[input.len - 1] == '}') {
        input = std.mem.trim(u8, input[1 .. input.len - 1], " \t\n\r");
    }
    // An optional `| keep <guard>` clause filters the generated values; the guard
    // is an integer expression over the bound variable, evaluated at COMPILE TIME.
    var gen_part = input;
    var guard: ?[]const u8 = null;
    if (std.mem.indexOf(u8, input, "| keep ")) |kidx| {
        gen_part = std.mem.trim(u8, input[0..kidx], " \t\n\r");
        guard = std.mem.trim(u8, input[kidx + "| keep ".len ..], " \t\n\r");
    }

    const over_kw = " over ";
    const over_idx = std.mem.indexOf(u8, gen_part, over_kw) orelse return error.BadArgs;
    // The bound variable, with an optional `: <type>` annotation that types the
    // baked table (`x: usize over …` -> `[_]usize{…}`; default `i64`).
    const before_over = std.mem.trim(u8, gen_part[0..over_idx], " \t");
    var var_name = before_over;
    var elem_type: []const u8 = "i64";
    if (std.mem.indexOfScalar(u8, before_over, ':')) |ci| {
        var_name = std.mem.trim(u8, before_over[0..ci], " \t");
        elem_type = std.mem.trim(u8, before_over[ci + 1 ..], " \t");
    }
    const gen = std.mem.trim(u8, gen_part[over_idx + over_kw.len ..], " \t\n\r");
    const dotdot = findTopLevelRange(gen) orelse return error.BadArgs;
    const lo = std.fmt.parseInt(i64, std.mem.trim(u8, gen[0..dotdot], " \t"), 10) catch return error.BadArgs;
    const hi = std.fmt.parseInt(i64, std.mem.trim(u8, gen[dotdot + 2 ..], " \t"), 10) catch return error.BadArgs;

    var vals: std.ArrayList(i64) = .empty;
    var x = lo;
    while (x < hi) : (x += 1) { // upper-exclusive, matching `for(2..1001)`
        if (guard) |g| {
            const keep = GuardEval.eval(g, var_name, x) orelse return error.BadArgs;
            if (keep == 0) continue;
        }
        try vals.append(allocator, x);
    }
    return .{ .values = try vals.toOwnedSlice(allocator), .period = hi, .elem_type = elem_type };
}

/// `table_type(comprehension)`: the element type the table bakes to (default `i64`),
/// so the `|zig` template can write `[_]<type>{…}`. The `|js` template ignores it.
fn tableTypeFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const c = try evalComprehension(allocator, args[0].string);
    return liquid.Value{ .string = c.elem_type };
}

/// Wrap a list of integers as `{ v }` records for the template's `{% for %}`.
fn valuesToRecords(allocator: std.mem.Allocator, values: []const i64) anyerror!liquid.Value {
    var nodes: std.ArrayList(*liquid.Context) = .empty;
    for (values) |v| {
        const node = try allocator.create(liquid.Context);
        node.* = liquid.Context.init(allocator);
        try node.put("v", .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{v}) });
        try nodes.append(allocator, node);
    }
    return liquid.Value{ .array = try nodes.toOwnedSlice(allocator) };
}

fn tableFromFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const c = try evalComprehension(allocator, args[0].string);
    return valuesToRecords(allocator, c.values);
}

/// `table_gaps(comprehension)`: the CYCLIC differences between consecutive
/// generated values — the residue-gap sequence a wheel sieve walks. The last gap
/// wraps to the first value one period on (`values[0] + period - values[last]`),
/// so the k gaps tile exactly one turn and sum to the period. For the mod-6 wheel
/// [1,5] over period 6: gaps [4, 2] (sum 6). This is the table `primesieve.cpp`
/// hand-writes for the big wheels — here it's derived at compile time.
fn tableGapsFilter(allocator: std.mem.Allocator, args: []const liquid.Value) anyerror!liquid.Value {
    if (args.len != 1 or args[0] != .string) return error.BadArgs;
    const c = try evalComprehension(allocator, args[0].string);
    if (c.values.len == 0) return liquid.Value{ .array = &.{} };
    const gaps = try allocator.alloc(i64, c.values.len);
    for (c.values, 0..) |v, i| {
        const next = if (i + 1 < c.values.len) c.values[i + 1] else c.values[0] + c.period;
        gaps[i] = next - v;
    }
    return valuesToRecords(allocator, gaps);
}

/// Walk the AST and process every proc whose variant chain begins with
/// `template(once)|...`. Mutates ProcDecl.body and ProcDecl.target in place.
/// Also runs the per-call template pass for bare `|template|...` procs:
/// each invocation site gets its template body rendered with that call's
/// captured args, the result stored on the flow's `inline_body` so the
/// emitter inlines it instead of calling a handler.
pub fn processTemplateProcs(
    program: *const ast.Program,
    allocator: std.mem.Allocator,
    build_lang: []const u8,
) !void {
    const items = @constCast(program.items);
    try processItems(items, allocator);
    try processPerCallInvocations(items, items, build_lang, allocator);
}

fn processItems(items: []ast.Item, allocator: std.mem.Allocator) !void {
    for (items) |*item| {
        switch (item.*) {
            .proc_decl => |*pd| try processProc(pd, allocator),
            .module_decl => |*md| try processItems(@constCast(md.items), allocator),
            else => {},
        }
    }
}

/// Walk all flows, rendering per-call templates at the invocation site.
/// `all_items` is the full program root (for cross-module proc lookup);
/// `items` is the scope currently being walked.
fn processPerCallInvocations(
    all_items: []ast.Item,
    items: []ast.Item,
    build_lang: []const u8,
    allocator: std.mem.Allocator,
) !void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| try maybeRenderPerCall(all_items, flow, build_lang, allocator),
            .module_decl => |*md| try processPerCallInvocations(all_items, @constCast(md.items), build_lang, allocator),
            else => {},
        }
    }
}

/// The build language, for the few places a per-call template render produces
/// HOST text rather than target-agnostic structure.
///
/// Most of what a template renders is shared: a dispatch cascade, a loop body, a
/// substituted arg. What is NOT shared is anything that has to be *spelled* in
/// the host — declarations and host builtins. Two renders qualify today, and
/// both are keyed on this one enum rather than growing per-target siblings:
///
///   `{{ binds }}` — `cond`'s binder preamble (buildCondBinds). Zig needs
///                   `.{ .f = v }` anon-struct syntax, `: T` annotations and
///                   `_ = &v;` unused-suppression; JS needs none of the three.
///   `~if(<arm>)`  — the optional-arm PRESENCE test
///                   (presenceRewriteTemplateArg). Zig asks the handler type
///                   `@hasDecl(__H, "arm")`; JS asks the handler object
///                   `H.arm !== undefined`.
///
/// "Two" is a claim, put here to be falsified cheaply. Falsify it by finding a
/// render that emits host syntax without consulting a HostLang.
///
/// One BOUNDED blind spot in that falsification, in js_emitter (js-gap-a
/// 31f3aa2a; unmerged at the time of writing, so the spelling is theirs to
/// correct, not mine to assert): `Emitter.writeHostText` translates Zig host
/// BUILTINS out of rendered template text on the way to JS —
/// `writeHostBuiltin` holds the exhaustive set (`@as`/`@intCast`/`@truncate`
/// and the other identity casts, `@divTrunc`/`@divFloor`/`@rem`/`@mod`,
/// `@min`/`@max`/`@abs`/`@sqrt`). That is the emitter cleaning up after a
/// target-blind path, not a third site here, so the count survives.
///
/// What it costs: a third site emitting one of THOSE builtins runs correctly on
/// JS and shows no symptom, so a green JS test is weak evidence over exactly
/// that list. It is not weak evidence in general — any other `@name(` reaching
/// the JS emitter is REFUSED with UnsupportedConstruct rather than passed
/// through, so an unmodelled builtin from a third site fails loudly at compile
/// time. Read the renders when the suspect is in the list above; trust the
/// compiler otherwise.
///
/// A third target reaching here is walled upstream: a render only happens after
/// selectPerCallTemplateProc found a `<name>|template|<build_lang>` proc, and
/// only `zig` and `js` declare any — KORU121 refuses every other lang first.
const HostLang = enum {
    zig,
    js,

    fn of(build_lang: []const u8) HostLang {
        return if (std.mem.eql(u8, build_lang, "js")) .js else .zig;
    }
};

/// Lower a Koru scrutinee expression to a host value. A struct literal
/// (`{ value: n }`) becomes a Zig anonymous struct (`.{ .value = n, }`) or a JS
/// object literal (`{ value: n, }`) via the single struct-literal parser;
/// anything else (a bare identifier `k`, an arithmetic expr) is already shaped
/// for either host and passes through verbatim. Used to materialize a `cond`
/// scrutinee before an arm destructures/binds it.
fn lowerScrutinee(allocator: std.mem.Allocator, text: []const u8, host: HostLang) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return text;
    const fields = struct_literal.parseFields(allocator, trimmed) catch return text;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, switch (host) {
        .zig => ".{ ",
        .js => "{ ",
    });
    for (fields) |f| {
        if (host == .zig) try buf.appendSlice(allocator, ".");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, switch (host) {
            .zig => " = ",
            .js => ": ",
        });
        try buf.appendSlice(allocator, f.value);
        try buf.appendSlice(allocator, ", ");
    }
    try buf.appendSlice(allocator, "}");
    return buf.toOwnedSlice(allocator);
}

/// Append `const <name>[: <type>] = <prefix>.<name>;` per named destructure leaf
/// (recursing into nested sub-shapes), skipping `_` slots. String-building twin
/// of emitter_helpers.emitDestructureConsts.
///
/// `seen`, when given, is a name set shared across the arms of one dispatch:
/// the binders are hoisted into ONE scope (see `buildCondBinds`), so a name two
/// arms both bind must be declared once. Both bind the same field of the same
/// scrutinee, so the single declaration is the same value either arm would see.
///
/// Two pieces are Zig-only and dropped on the JS host: the `: <type>`
/// representation annotation (JS consts carry no type), and the `_ = &<name>;`
/// unused-suppression (Zig refuses an unused const; JS does not, and `_ = &x;`
/// is not even parseable there).
fn appendDestructureConsts(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    fields: []const ast.DestructureField,
    prefix: []const u8,
    seen: ?*std.StringHashMap(void),
    host: HostLang,
) !void {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "_")) continue;
        if (f.sub.len > 0) {
            const sub_prefix = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, f.name });
            try appendDestructureConsts(allocator, buf, f.sub, sub_prefix, seen, host);
            continue;
        }
        if (seen) |s| {
            if (s.contains(f.name)) continue;
            try s.put(f.name, {});
        }
        try buf.appendSlice(allocator, "const ");
        try buf.appendSlice(allocator, f.name);
        if (host == .zig) {
            if (f.type_text) |t| {
                try buf.appendSlice(allocator, ": ");
                try buf.appendSlice(allocator, t);
            }
        }
        try buf.appendSlice(allocator, " = ");
        try buf.appendSlice(allocator, prefix);
        try buf.appendSlice(allocator, ".");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, ";");
        if (host == .zig) {
            try buf.appendSlice(allocator, " _ = &");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, ";");
        }
        try buf.appendSlice(allocator, " ");
    }
}

/// Build the host binder preamble for a whole `cond`: one `const` per distinct
/// arm binder (`c <name>` scalar, `c { field }` destructure), bound to the
/// scrutinee, emitted ONCE ahead of the dispatch as `{{ binds }}`.
///
/// Hoisted, not per-arm, because a first-match dispatch is an `if / else if`
/// CASCADE: each arm's `when` guard sits in the cascade's condition position,
/// where the binder it names must already be in scope. Binding inside the arm
/// body — where the guard cannot see it — is what forced `cond` to emit N
/// independent blocks instead, and independent blocks all run (`320_138`).
///
/// Distinct-by-NAME: arms routinely reuse one binder (`| c k when …` ×5), and
/// every arm binds the same scrutinee, so one declaration serves all of them.
/// Returns "" when nothing binds — a `_` catch-all, or an `~if`/`~for` terminal
/// with no scrutinee to bind. Cond arms reuse the payload-less terminal marker,
/// so — unlike an effect splice, whose call arg the emitter binds — the
/// scrutinee is threaded in here.
fn buildCondBinds(
    allocator: std.mem.Allocator,
    conts: []const ast.Continuation,
    scrutinee: []const u8,
    host: HostLang,
) ![]const u8 {
    if (scrutinee.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (conts) |cont| {
        if (cont.branch.len == 0) continue;
        // Destructure binder (`c { field, ... }`): materialize the scrutinee once
        // to a site-unique temp, then one `const <field> = <tmp>.<field>;` per leaf.
        if (cont.destructure.len > 0) {
            const s_host = try lowerScrutinee(allocator, scrutinee, host);
            const tmp = try std.fmt.allocPrint(allocator, "__koru_cond_s_{d}_{d}", .{ cont.location.line, cont.location.column });
            try buf.appendSlice(allocator, "const ");
            try buf.appendSlice(allocator, tmp);
            try buf.appendSlice(allocator, " = ");
            try buf.appendSlice(allocator, s_host);
            try buf.appendSlice(allocator, ";");
            // Zig-only: the temp is read only by the per-leaf consts below, and
            // Zig refuses an unused const. JS has no such rule, and `_ = &x;`
            // does not parse there.
            if (host == .zig) {
                try buf.appendSlice(allocator, " _ = &");
                try buf.appendSlice(allocator, tmp);
                try buf.appendSlice(allocator, ";");
            }
            try buf.appendSlice(allocator, " ");
            try appendDestructureConsts(allocator, &buf, cont.destructure, tmp, &seen, host);
            continue;
        }
        // Scalar binder (`c v`): bind the whole scrutinee. `_`/empty = no binder.
        const b = cont.binding orelse continue;
        if (b.len == 0 or std.mem.eql(u8, b, "_")) continue;
        // The scrutinee expression IS the binder name (`cond(k) | c k …`): the
        // name is already in scope, so `const k = k;` would self-shadow. Use it
        // as-is — the binder is a no-op. Mirrors the effect splice's same guard
        // in emitter_helpers. BOTH hosts need this: Zig rejects the shadow at
        // compile time, JS throws a TDZ ReferenceError at run time.
        if (std.mem.eql(u8, std.mem.trim(u8, scrutinee, " \t\n\r"), b)) continue;
        if (seen.contains(b)) continue;
        try seen.put(b, {});
        const s_host = try lowerScrutinee(allocator, scrutinee, host);
        try buf.appendSlice(allocator, switch (host) {
            .zig => try std.fmt.allocPrint(allocator, "const {s} = {s}; _ = &{s}; ", .{ b, s_host, b }),
            .js => try std.fmt.allocPrint(allocator, "const {s} = {s}; ", .{ b, s_host }),
        });
    }
    return buf.toOwnedSlice(allocator);
}

/// Render a bare `|template|` proc for one invocation, returning the rendered
/// inline_body (with the inline_stmt marker), or null if the invocation doesn't
/// resolve to a per-call template proc. Shared by top-level flows and nested
/// continuations so inline-template lowering works at every depth.
fn renderTemplateInvocation(
    all_items: []ast.Item,
    invocation: *const ast.Invocation,
    continuations: []const ast.Continuation,
    location: errors.SourceLocation,
    build_lang: []const u8,
    impl_event: ?*const ast.EventDecl,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    // The per-call inline render happens UPSTREAM of the emitter's variant pick
    // (the template is spliced inline, not left as a surviving proc), so the
    // selection of `|zig` vs `|js` must happen HERE, keyed on the build language.
    // selectPerCallTemplateProc returns the bare-`|template|<build_lang>` proc,
    // or null if the invocation isn't a per-call template at all. A missing
    // lang variant for an event that DOES have a per-call template is a loud
    // compile error (never a silent fall-through to the `|zig` body on a JS
    // build — that is the leak this whole pass exists to kill).
    const proc = selectPerCallTemplateProc(all_items, &invocation.path, build_lang, location) orelse return null;

    // Build context from invocation args. Named args (`name: value`) key on the
    // arg name; positional args (`~for(&items)`, which parse with name == value)
    // bind to the event's field at that position so `{{ iterable }}` resolves.
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    const event_decl = findEventDeclByLastSegment(all_items, &invocation.path);

    // The scrutinee of a `cond` (`~cond(expr)`) — the first arg's text. Threaded
    // to each arm's binder below: a cond arm reuses the payload-less terminal
    // marker, so the scrutinee it binds must be captured HERE, not by the
    // emitter's continue-marker resolver (which has no payload to bind).
    var scrutinee_text: []const u8 = "";

    for (invocation.args, 0..) |arg, i| {
        const raw_text = if (arg.expression_value) |expr_val| expr_val.text else arg.value;
        // PRESENCE (400_146, ruled 2026-07-03): inside the declaring event's
        // impl, an optional arm's bare name as `if`'s condition is a presence
        // test. The `~if` template bakes its condition right here ({{ expr }}),
        // upstream of every emitter rewrite site, so the substitution must happen
        // BEFORE the render — which is also why the BUILD LANGUAGE has to be
        // known here: the test is host text (`@hasDecl(__H, …)` vs
        // `H.… !== undefined`), and no later pass gets a chance to retarget it.
        // A required arm is left verbatim: the shape checker walls it (KORU131)
        // before emission is reached.
        const text = try presenceRewriteTemplateArg(allocator, invocation, impl_event, raw_text, HostLang.of(build_lang));
        if (i == 0) scrutinee_text = text;
        const is_positional = std.mem.eql(u8, arg.name, arg.value);
        const key = if (!is_positional)
            arg.name
        else if (event_decl) |ed| (if (i < ed.input.fields.len) ed.input.fields[i].name else arg.name) else arg.name;
        if (key.len > 0) {
            try ctx.put(key, .{ .string = text });
        }
    }

    // `binds`: the whole dispatch's binder preamble, emitted once ahead of the
    // arms so every arm's `when` guard can be read in condition position. Empty
    // for a template whose arms bind nothing (`~if`, `~for`); `cond` is its
    // consumer. See buildCondBinds for why this is hoisted and deduped.
    //
    // ONE key, rendered in the BUILD language — not a `binds`/`binds_js` pair.
    // The two `cond|template|<lang>` variants share every structural decision
    // (which arms bind, dedup by name, hoisting ahead of the cascade); only the
    // declaration syntax differs, and that is what HostLang selects. A second
    // context key would have let the next person improve one host's binder and
    // silently leave the other behind — the two-lowerings-of-one-construct shape
    // `~for`/`scan` was converged to avoid (control.kz, `~for` prose).
    try ctx.put("binds", .{ .string = try buildCondBinds(allocator, continuations, scrutinee_text, HostLang.of(build_lang)) });

    // Expose the invoking handlers to the template, SPLIT BY KIND. Effect
    // handlers (`! each`, fire 0-to-N during) land under `effects["<branch>"]`;
    // terminal handlers (`| done`, fire once after) under
    // `continuations["<branch>"]`. The pair is complete — there is no third
    // branch-kind — so this exhausts the surface. Each entry is a sub-context
    // { link, binding, guard, kind, inlined_link }; presence doubles as
    // truthiness. See the template-engine cluster (250_*) for what templates
    // program against. This is a pure SEMANTIC split — the AST keeps one
    // `Continuation` type carrying `kind`; only the template-facing names differ.
    {
        var by_effect = std.StringHashMap(std.ArrayList(*liquid.Context)).init(allocator);
        var by_terminal = std.StringHashMap(std.ArrayList(*liquid.Context)).init(allocator);
        for (continuations, 0..) |cont, idx| {
            if (cont.branch.len == 0) continue; // skip void-chain continuations
            const sub = try allocator.create(liquid.Context);
            sub.* = liquid.Context.init(allocator);
            try sub.put("link", .{ .string = cont.branch });
            try sub.put("binding", .{ .string = cont.binding orelse "" });
            try sub.put("guard", .{ .string = cont.condition orelse "" });
            try sub.put("kind", .{ .string = if (cont.kind == .effect) "effect" else "terminal" });
            // `inlined_link` is a marker the emitter resolves to the handler's
            // body spliced INLINE (in the enclosing scope), vs `link` which is a
            // call to the isolated Handlers fn. `<idx>` is this continuation's
            // position in the node's continuation list — the same slice the
            // emitter resolves against, so it round-trips deterministically.
            const marker = try std.fmt.allocPrint(allocator, "__koru_inline_{d}", .{idx});
            try sub.put("inlined_link", .{ .string = marker });
            // `inlined_link[scope]` splices the body identically AND declares the
            // handler an obligation boundary: the `scoped_` infix is a signal the
            // template_processor scans for post-render to stamp `@scope` on this
            // continuation. Scope is thus a property of the SPLICE SITE the
            // template author chooses, not of the event declaration. Stored under
            // the literal key — liquid's dotted access is exact-match, so
            // `{{ h.inlined_link[scope] }}` resolves here with no parser change.
            const scoped_marker = try std.fmt.allocPrint(allocator, "__koru_inline_scoped_{d}", .{idx});
            try sub.put("inlined_link[scope]", .{ .string = scoped_marker });
            // `continue`: a continuation is CONTINUED (continuation-passing —
            // the producer hands off to the consumer's handler), not called. For
            // terminal handlers, expose a `__koru_continue_<idx>` marker the
            // emitter resolves to the consumer's terminal body at the hand-off
            // point. Effects never get this — they fire during and are called.
            // This is the continuation half of the effect/continuation symmetry
            // (`effects[..]` → call; `continuations[..]` → continue). NB: `.continue`
            // names the concept; the Zig lowering happens to be `return`, but that
            // is a backend detail this surface deliberately does not leak.
            if (cont.kind != .effect) {
                const cont_marker = try std.fmt.allocPrint(allocator, "__koru_continue_{d}", .{idx});
                try sub.put("continue", .{ .string = cont_marker });
                // `continue[unguarded]` hands off the SAME body without the
                // `if (<guard>)` wrapper the plain marker carries — for a
                // template that has already put the guard somewhere the plain
                // marker cannot reach. `cond` needs exactly this: its guards go
                // into an `if / else if` cascade's condition position, and a
                // second copy inside the body would evaluate every guard twice.
                // Which of the two a hand-off uses is a property of the SPLICE
                // SITE the template author chooses, same as `inlined_link[scope]`.
                const bare_marker = try std.fmt.allocPrint(allocator, "__koru_continue_bare_{d}", .{idx});
                try sub.put("continue[unguarded]", .{ .string = bare_marker });
            }

            const target_map = if (cont.kind == .effect) &by_effect else &by_terminal;
            const gop = try target_map.getOrPut(cont.branch);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, sub);
        }

        const Putter = struct {
            fn flush(c: *liquid.Context, map: *std.StringHashMap(std.ArrayList(*liquid.Context)), comptime prefix: []const u8, a: std.mem.Allocator) !void {
                var it = map.iterator();
                while (it.next()) |entry| {
                    const arr = try a.alloc(*liquid.Context, entry.value_ptr.items.len);
                    @memcpy(arr, entry.value_ptr.items);
                    const key = try std.fmt.allocPrint(a, prefix ++ "[\"{s}\"]", .{entry.key_ptr.*});
                    try c.put(key, .{ .array = arr });
                }
            }
        };
        try Putter.flush(&ctx, &by_effect, "effects", allocator);
        try Putter.flush(&ctx, &by_terminal, "continuations", allocator);

        // Direct `continuations["<branch>"].continue` keys, so a template writes
        // `{{ continuations["done"].continue }}` WITHOUT iterating — a continuation
        // is continued once, not called N times. Stored under the literal dotted
        // key (liquid's access is exact-match, no parser change). Concatenates
        // markers if a branch carries multiple handlers (when-guards).
        {
            var it = by_terminal.iterator();
            while (it.next()) |entry| {
                var buf: std.ArrayList(u8) = .empty;
                for (entry.value_ptr.items) |sub| {
                    if (sub.get("continue")) |v| {
                        if (v == .string) try buf.appendSlice(allocator, v.string);
                    }
                }
                const key = try std.fmt.allocPrint(allocator, "continuations[\"{s}\"].continue", .{entry.key_ptr.*});
                try ctx.put(key, .{ .string = try buf.toOwnedSlice(allocator) });
            }
        }
    }

    // Per-call templates can call filters (e.g. `parse_range` for cross-target
    // `~for`). Build the registry and render through it.
    var filters = liquid.FilterRegistry.init(allocator);
    defer filters.deinit();
    try filters.put("parse_range", parseRangeFilter);
    try filters.put("parse_fields", parseFieldsFilter);
    try filters.put("table_from", tableFromFilter);
    try filters.put("table_gaps", tableGapsFilter);
    try filters.put("table_type", tableTypeFilter);

    var comp_err: ?[]const u8 = null;
    const rendered = liquid.renderWithEnv(allocator, proc.body.text, &ctx, &comp_err, .{ .filters = &filters }) catch |err| {
        if (err == error.CompError) {
            emitCompErrorAndExit(location, comp_err orelse "template comp error");
        }
        if (err == error.InvalidIfCondition) {
            emitInvalidConditionAndExit(location, comp_err orelse "");
        }
        return err;
    };

    // Prepend the `inline_stmt` marker so the emitter knows the rendered body is
    // statement-shaped (no trailing `;`). NOTE: we do NOT blank `proc.body` —
    // the emitter stubs `|template|` handlers (`unreachable`), and blanking
    // would corrupt rendering for any *second* invocation of the same template.
    const inline_marker = "//@koru:inline_stmt\n";
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ inline_marker, rendered });
}

fn maybeRenderPerCall(
    all_items: []ast.Item,
    flow: *ast.Flow,
    build_lang: []const u8,
    allocator: std.mem.Allocator,
) !void {
    // The event this flow implements (`gen = for(...)`, `query = if(...)`),
    // if any — presence expressions resolve against ITS optional arms.
    const impl_event: ?*const ast.EventDecl = blk: {
        const impl_path = flow.impl_of orelse break :blk null;
        break :blk findEventDeclByLastSegment(all_items, &impl_path);
    };
    if (flow.inline_body == null) {
        if (try renderTemplateInvocation(all_items, flow.inv(), flow.body.continuations, flow.location, build_lang, impl_event, allocator)) |rendered| {
            flow.inline_body = rendered;
            log.debug("[TEMPLATE/per-call] rendered '{s}' at top-level call site\n", .{
                if (flow.inv().path.segments.len > 0) flow.inv().path.segments[0] else "<?>",
            });
        }
    }

    // If the rendered body spliced any handler with `[scope]`, stamp `@scope` on
    // the matching continuations so the obligation checker treats each handler
    // body as a per-iteration scope boundary (auto-discharge per loop).
    if (flow.inline_body) |body| {
        try tagScopeFromRenderedBody(body, @constCast(flow.body.continuations), allocator);
    }

    // Nested template invocations (e.g. `~for` inside a pipeline continuation)
    // get the same per-call rendering, depth-first. The inline_body lands on
    // the continuation's invocation node; emitContinuationBody honors it via the
    // shared emitInlineBodyNode — the SAME path as a top-level flow.
    try renderNestedTemplates(all_items, @constCast(flow.body.continuations), build_lang, impl_event, allocator);
}

/// Scope is declared at the SPLICE SITE, not the event. When a template splices
/// a handler with `{{ h.inlined_link[scope] }}`, that renders a
/// `__koru_inline_scoped_<idx>` marker into the body. After rendering, scan the
/// body for those markers and stamp `@scope` onto the matching continuations'
/// `binding_annotations`. The obligation checker (`auto_discharge_inserter`)
/// reads `@scope` on a continuation and treats that handler body as a scope
/// boundary — per-iteration resource discharge, outer resources suspended. This
/// is how a template construct declares "this spliced body is a scope" without a
/// dedicated node and without baking scope into the event declaration: the
/// template author picks `inlined_link[scope]` exactly where the boundary is.
const SCOPED_SPLICE_MARKER = "__koru_inline_scoped_";

fn tagScopeFromRenderedBody(
    rendered: []const u8,
    continuations: []ast.Continuation,
    allocator: std.mem.Allocator,
) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, pos, SCOPED_SPLICE_MARKER)) |m| {
        var i = m + SCOPED_SPLICE_MARKER.len;
        var idx: usize = 0;
        var saw_digit = false;
        while (i < rendered.len and rendered[i] >= '0' and rendered[i] <= '9') : (i += 1) {
            idx = idx * 10 + (rendered[i] - '0');
            saw_digit = true;
        }
        if (saw_digit and idx < continuations.len) {
            try stampScope(&continuations[idx], allocator);
        }
        pos = i;
    }
}

/// Idempotently add `@scope` to a continuation's `binding_annotations`.
fn stampScope(cont: *ast.Continuation, allocator: std.mem.Allocator) !void {
    for (cont.binding_annotations) |ann| {
        if (std.mem.eql(u8, ann, "@scope")) return;
    }
    const old = cont.binding_annotations;
    const new_anns = try allocator.alloc([]const u8, old.len + 1);
    @memcpy(new_anns[0..old.len], old);
    new_anns[old.len] = "@scope";
    cont.binding_annotations = new_anns;
}

/// Walk continuations depth-first, rendering any `for`/template invocation found
/// as a continuation's node. This is what makes nested `~for` (`| result r |>
/// for(0..r) ! each … | done …`) lower the same as a top-level `~for`.
fn renderNestedTemplates(
    all_items: []ast.Item,
    continuations: []ast.Continuation,
    build_lang: []const u8,
    impl_event: ?*const ast.EventDecl,
    allocator: std.mem.Allocator,
) !void {
    for (continuations) |*cont| {
        if (cont.node) |*node| {
            if (node.* == .invocation) {
                if (node.invocation.inline_body == null) {
                    if (try renderTemplateInvocation(all_items, &node.invocation, cont.continuations, .{ .file = "generated", .line = 0, .column = 0 }, build_lang, impl_event, allocator)) |rendered| {
                        node.invocation.inline_body = rendered;
                        log.debug("[TEMPLATE/per-call] rendered nested '{s}'\n", .{
                            if (node.invocation.path.segments.len > 0) node.invocation.path.segments[0] else "<?>",
                        });
                    }
                }
                // Same splice-driven `@scope` stamping for nested constructs.
                if (node.invocation.inline_body) |body| {
                    try tagScopeFromRenderedBody(body, @constCast(cont.continuations), allocator);
                }
            }
        }
        try renderNestedTemplates(all_items, @constCast(cont.continuations), build_lang, impl_event, allocator);
    }
}

/// PRESENCE substitution for a template-invocation arg: `if(<optional arm>)`
/// inside the arm's declaring event's impl becomes a host presence test.
/// Only the `if` keyword event's condition is a presence home (ruled
/// 2026-07-03 — the other home, `when` guards, is emitter-resolved because
/// guards are not baked by templates). Anything that isn't a bare optional-arm
/// name of the enclosing impl event passes through verbatim.
///
/// The test is HOST text, so it is keyed on the build language — this render sits
/// upstream of every emitter rewrite site (the `~if` template bakes its condition
/// right here), which is exactly why the language has to be known at this point.
///
///   zig   `@hasDecl(__H, "arm")`   the handler TYPE param; a comptime bool, so
///                                  Zig analyzes only the taken branch and the
///                                  absent case never names `__H.arm`.
///   js    `H.arm !== undefined`    `H` is the JS twin of `__H` (js_emitter.zig
///                                  :270-279 takes it on every effect-bearing
///                                  event and binds `const arm = H.arm;` for
///                                  each DECLARED branch, optional included, so
///                                  an absent arm reads `undefined` rather than
///                                  throwing). Asked of the handler bundle, not
///                                  of the derived local, so it stays true to
///                                  `@hasDecl`'s question and does not depend on
///                                  the alias line. JS has no comptime, so both
///                                  arms are emitted and the guard keeps the
///                                  absent one from ever being called.
fn presenceRewriteTemplateArg(
    allocator: std.mem.Allocator,
    invocation: *const ast.Invocation,
    impl_event: ?*const ast.EventDecl,
    text: []const u8,
    host: HostLang,
) ![]const u8 {
    const ev = impl_event orelse return text;
    if (invocation.path.segments.len == 0) return text;
    if (!std.mem.eql(u8, invocation.path.segments[invocation.path.segments.len - 1], "if")) return text;
    const trimmed = std.mem.trim(u8, text, " \t");
    for (ev.branches) |*b| {
        if (b.kind != .effect) continue;
        if (!b.is_optional) continue;
        if (!std.mem.eql(u8, b.name, trimmed)) continue;
        return switch (host) {
            .zig => try std.fmt.allocPrint(allocator, "@hasDecl(__H, \"{s}\")", .{b.name}),
            .js => try std.fmt.allocPrint(allocator, "H.{s} !== undefined", .{b.name}),
        };
    }
    return text;
}

/// Find the event declaration whose path's last segment matches the
/// invocation's last segment (top-level + nested modules). Used to bind
/// positional invocation args to the event's field names.
fn findEventDeclByLastSegment(items: []ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
    if (path.segments.len == 0) return null;
    const target = path.segments[path.segments.len - 1];
    for (items) |*item| {
        switch (item.*) {
            .event_decl => |*ed| {
                if (ed.path.segments.len == 0) continue;
                if (std.mem.eql(u8, ed.path.segments[ed.path.segments.len - 1], target)) return ed;
            },
            .module_decl => |*md| {
                if (findEventDeclByLastSegment(@constCast(md.items), path)) |found| return found;
            },
            else => {},
        }
    }
    return null;
}

/// The build-language variant of a bare `|template|<lang>` proc, e.g. `zig`
/// for `for|template|zig` or `js` for `for|template|js`. Returns null if the
/// proc is not a bare per-call template (no `template` tag, OR `template(once)`
/// per-decl, OR a `template|` with no trailing lang segment).
fn perCallTemplateLang(proc: *const ast.ProcDecl) ?[]const u8 {
    const target = proc.target orelse return null;
    const first_sep = firstTagEnd(target);
    const parts = parseTag(target[0..first_sep]);
    if (!std.mem.eql(u8, parts.name, TEMPLATE_TAG)) return null;
    if (parts.args.len != 0) return null; // `template(once)` is per-decl, not per-call.
    if (first_sep >= target.len) return null; // bare `template` with no lang segment.
    // Lang is the segment immediately after `template|`, up to the next `|`.
    const rest = target[first_sep + 1 ..];
    const lang_end = firstTagEnd(rest);
    const lang = parseTag(rest[0..lang_end]).name;
    if (lang.len == 0) return null;
    return lang;
}

/// Surface a missing-target-variant as a fantastic, located Koru diagnostic
/// (KORU121), then fail the compile. This is the loud failure that replaces the
/// old silent `|zig`-body leak onto a non-Zig target: a per-call template
/// construct (`~for`, `~if`, …) was invoked on a `--lang=<build_lang>` build,
/// but the construct only declares `<event>|template|<other-lang>` variants.
fn emitMissingVariantAndExit(
    location: errors.SourceLocation,
    event_name: []const u8,
    build_lang: []const u8,
) noreturn {
    std.debug.print(
        \\error[{s}]: control-flow construct `~{s}` has no `|template|{s}` variant for the `--lang={s}` build
        \\  --> {s}:{d}:{d}
        \\  `~{s}` is a per-call template: its body is spliced inline at the call
        \\  site BEFORE the emitter picks a target, so the variant must be chosen
        \\  here, by build language. This build is `{s}`, but `{s}|template|{s}`
        \\  is not declared.
        \\  fix: add `~proc {s}|template|{s} {{ ... }}` next to the existing
        \\  variants in the construct's source (e.g. koru_std/control.kz), emitting
        \\  a {s}-native body.
        \\
    , .{
        @tagName(errors.ErrorCode.KORU121),
        event_name,
        build_lang,
        build_lang,
        location.file,
        location.line,
        location.column,
        event_name,
        build_lang,
        event_name,
        build_lang,
        event_name,
        build_lang,
        build_lang,
    });
    std.process.exit(1);
}

/// Select the per-call template proc for an invocation, keyed on build language.
///
/// Per-call template selection happens UPSTREAM of the emitter's variant pick,
/// so it must be target-aware HERE — STRICT, with no cross-lang fallback. Walk
/// every proc whose path last-segment matches the invocation's, classify each
/// via `perCallTemplateLang`:
///   - If NONE are per-call templates → return null (ordinary invocation; the
///     caller leaves it untouched).
///   - If a per-call template variant matches `build_lang` exactly → return it.
///   - If per-call template variants exist but NONE match `build_lang` → loud
///     KORU121 (never fall back to `|zig` on a JS build).
fn selectPerCallTemplateProc(
    items: []ast.Item,
    path: *const ast.DottedPath,
    build_lang: []const u8,
    location: errors.SourceLocation,
) ?*ast.ProcDecl {
    if (path.segments.len == 0) return null;
    const target_name = path.segments[path.segments.len - 1];

    const Walker = struct {
        fn search(
            its: []ast.Item,
            name: []const u8,
            blang: []const u8,
            saw_any_template: *bool,
        ) ?*ast.ProcDecl {
            for (its) |*item| {
                switch (item.*) {
                    .proc_decl => |*pd| {
                        if (pd.path.segments.len == 0) continue;
                        const pd_name = pd.path.segments[pd.path.segments.len - 1];
                        if (!std.mem.eql(u8, pd_name, name)) continue;
                        const lang = perCallTemplateLang(pd) orelse continue;
                        saw_any_template.* = true;
                        if (std.mem.eql(u8, lang, blang)) return pd;
                    },
                    .module_decl => |*md| {
                        if (search(@constCast(md.items), name, blang, saw_any_template)) |found| return found;
                    },
                    else => {},
                }
            }
            return null;
        }
    };

    var saw_any_template = false;
    if (Walker.search(items, target_name, build_lang, &saw_any_template)) |pd| return pd;

    // A per-call template construct exists for this event name, but no variant
    // matches the build language — fail loudly rather than leak a wrong-target
    // body. (If `saw_any_template` is false, this wasn't a template invocation
    // at all; leave it for normal handling.)
    if (saw_any_template) {
        emitMissingVariantAndExit(location, target_name, build_lang);
    }
    return null;
}

/// Find the end of the first tag in a variant chain, respecting `(...)`
/// argument groups. For `template(once)|zig`, returns index of the `|`
/// between `)` and `zig`. For `template|zig`, returns index of the first `|`.
fn firstTagEnd(target: []const u8) usize {
    var i: usize = 0;
    var paren_depth: usize = 0;
    while (i < target.len) : (i += 1) {
        const c = target[i];
        if (c == '(') paren_depth += 1
        else if (c == ')') {
            if (paren_depth > 0) paren_depth -= 1;
        } else if (c == '|' and paren_depth == 0) {
            return i;
        }
    }
    return target.len;
}

/// Split `template(once)` into base name `template` and args `once` (or
/// empty if no args). Returns null base if the tag isn't a valid form.
const TagParts = struct {
    name: []const u8,
    args: []const u8, // empty if no `(...)` group
};

fn parseTag(tag: []const u8) TagParts {
    if (std.mem.indexOfScalar(u8, tag, '(')) |open| {
        // Expect closing paren at end.
        if (tag.len > 0 and tag[tag.len - 1] == ')') {
            return .{ .name = tag[0..open], .args = tag[open + 1 .. tag.len - 1] };
        }
    }
    return .{ .name = tag, .args = "" };
}

fn processProc(pd: *ast.ProcDecl, allocator: std.mem.Allocator) !void {
    const target = pd.target orelse return;

    const first_sep = firstTagEnd(target);
    const first_tag = target[0..first_sep];
    const parts = parseTag(first_tag);

    if (!std.mem.eql(u8, parts.name, TEMPLATE_TAG)) return;

    // Bare `template` (no args) = per-call mode. Handled by
    // processPerCallInvocations later; skip here.
    if (parts.args.len == 0) return;

    if (!std.mem.eql(u8, parts.args, ONCE_MODE)) {
        std.debug.panic(
            "Unknown template mode '({s})' on proc '{s}'. " ++
                "Supported: |template(once)|...",
            .{ parts.args, first_tag },
        );
    }

    // Build Liquid context. First-cut data: the proc's PATH segments are
    // available as `{{ proc_name }}`. Future extensions: input field names
    // (from the matching event_decl), types, annotation flags, comptime
    // values from the call site.
    var ctx = liquid.Context.init(allocator);
    defer ctx.deinit();

    var proc_name_buf: [256]u8 = undefined;
    var name_len: usize = 0;
    for (pd.path.segments, 0..) |seg, i| {
        if (i > 0 and name_len < proc_name_buf.len) {
            proc_name_buf[name_len] = '.';
            name_len += 1;
        }
        const remaining = proc_name_buf.len -| name_len;
        const copy_len = @min(seg.len, remaining);
        @memcpy(proc_name_buf[name_len .. name_len + copy_len], seg[0..copy_len]);
        name_len += copy_len;
    }
    const proc_name = try allocator.dupe(u8, proc_name_buf[0..name_len]);
    // Leak — context only outlives the render call.
    try ctx.put("proc_name", .{ .string = proc_name });

    var comp_err: ?[]const u8 = null;
    const rendered = liquid.renderCollectDiag(allocator, pd.body.text, &ctx, &comp_err) catch |err| {
        if (err == error.CompError) {
            emitCompErrorAndExit(pd.location, comp_err orelse "template comp error");
        }
        if (err == error.InvalidIfCondition) {
            emitInvalidConditionAndExit(pd.location, comp_err orelse "");
        }
        return err;
    };

    // Replace body text with rendered output, preserving the Source's
    // location/scope/phantom_type provenance. NOTE: do NOT free the old slice —
    // the backend's AST lives in program_ast.zig as a static const value
    // and isn't allocator-owned. Leak is acceptable here (one-shot compile).
    pd.body.text = rendered;

    // Strip the `template|` prefix from the variant chain. Same ownership
    // caveat — don't free the old target slice.
    if (first_sep == target.len) {
        pd.target = null;
    } else {
        const remaining = target[first_sep + 1 ..];
        const new_target = try allocator.dupe(u8, remaining);
        pd.target = new_target;
    }

    log.debug("[TEMPLATE] processed proc body, new target: {s}\n", .{
        if (pd.target) |t| t else "<none>",
    });
}

test "parse_fields: splits brace-optional, comma/newline-separated field lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Case = struct { in: []const u8, names: []const []const u8, vals: []const []const u8, types: []const []const u8 };
    const cases = [_]Case{
        // Comma-separated; values returned VERBATIM (string literal keeps its quotes), no type annotation.
        .{ .in = "name: \"Claude\", count: 42", .names = &.{ "name", "count" }, .vals = &.{ "\"Claude\"", "42" }, .types = &.{ "", "" } },
        // Newline-separated — the canonical `const { … }` block shape.
        .{ .in = "name: \"Claude\"\n    count: 42\n", .names = &.{ "name", "count" }, .vals = &.{ "\"Claude\"", "42" }, .types = &.{ "", "" } },
        // Wrapping braces are accepted and stripped.
        .{ .in = "{ a: 1, b: 2 }", .names = &.{ "a", "b" }, .vals = &.{ "1", "2" }, .types = &.{ "", "" } },
        // A nested struct value's inner comma is NOT a field separator.
        .{ .in = "pt: Point{ x: 1, y: 2 }, n: 3", .names = &.{ "pt", "n" }, .vals = &.{ "Point{ x: 1, y: 2 }", "3" }, .types = &.{ "", "" } },
        // A comma inside a string literal is NOT a field separator.
        .{ .in = "s: \"a, b\"", .names = &.{"s"}, .vals = &.{"\"a, b\""}, .types = &.{""} },
        // Optional `[base_type]` annotation is peeled: value/type split per field.
        .{ .in = "x: 10[i32], y: 20", .names = &.{ "x", "y" }, .vals = &.{ "10", "20" }, .types = &.{ "i32", "" } },
        .{ .in = "ratio: 3.14[f64], flag: true[bool]", .names = &.{ "ratio", "flag" }, .vals = &.{ "3.14", "true" }, .types = &.{ "f64", "bool" } },
        // A leading-`[` array literal is NOT a type annotation (no value before `[`).
        .{ .in = "arr: [1, 2, 3]", .names = &.{"arr"}, .vals = &.{"[1, 2, 3]"}, .types = &.{""} },
        // A non-base-type trailing `[…]` is left in the value.
        .{ .in = "got: thing[99]", .names = &.{"got"}, .vals = &.{"thing[99]"}, .types = &.{""} },
    };

    for (cases) |c| {
        const v = try parseFieldsFilter(a, &.{.{ .string = c.in }});
        try std.testing.expect(v == .array);
        try std.testing.expectEqual(c.names.len, v.array.len);
        for (v.array, 0..) |node, i| {
            try std.testing.expectEqualStrings(c.names[i], node.get("name").?.string);
            try std.testing.expectEqualStrings(c.vals[i], node.get("value").?.string);
            try std.testing.expectEqualStrings(c.types[i], node.get("type").?.string);
        }
    }
}

test "parse_fields: empty / malformed inputs yield an empty field list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "   ", "{}", "{ }" }) |s| {
        const v = try parseFieldsFilter(a, &.{.{ .string = s }});
        try std.testing.expect(v == .array);
        try std.testing.expectEqual(@as(usize, 0), v.array.len);
    }
}

// The two host-keyed renders (see `HostLang`) are the only places a per-call
// template emits text that must be SPELLED in the build language. Both are
// reachable end-to-end only through positions the JS emitter cannot yet emit
// (a `cond` dispatch and an optional-arm presence test both live in a SUBFLOW
// impl, which js_emitter refuses with NoJsProcBody), so the regression corpus
// cannot judge the JS side of either one yet. These pin the rendered text
// directly, which is the part that is mine to get right.

test "cond binds: the scalar binder is declared in the build language" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `cond(k) | c v when …` — one guarded arm binding the scrutinee to `v`.
    const conts = [_]ast.Continuation{.{
        .branch = "c",
        .binding = "v",
        .condition = "v > 2",
        .node = null,
        .indent = 0,
        .continuations = &.{},
        .location = .{ .file = "t", .line = 3, .column = 1 },
    }};

    // Zig carries the `_ = &v;` unused-suppression it needs; JS must not, because
    // `_ = &v;` is not parseable there and an unused const is legal anyway.
    try std.testing.expectEqualStrings(
        "const v = k; _ = &v; ",
        try buildCondBinds(a, &conts, "k", .zig),
    );
    try std.testing.expectEqualStrings(
        "const v = k; ",
        try buildCondBinds(a, &conts, "k", .js),
    );
}

test "cond binds: a struct scrutinee lowers to each host's literal syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `cond({ value: n }) | c { value } when …` — destructure binder. The
    // scrutinee is materialized to a site-unique temp, then one const per leaf.
    const fields = [_]ast.DestructureField{.{ .name = "value" }};
    const conts = [_]ast.Continuation{.{
        .branch = "c",
        .binding = null,
        .destructure = &fields,
        .condition = "value == 4",
        .node = null,
        .indent = 0,
        .continuations = &.{},
        .location = .{ .file = "t", .line = 9, .column = 3 },
    }};

    // Zig: anon-struct `.{ .value = n, }`. JS: object literal `{ value: n, }`.
    try std.testing.expectEqualStrings(
        "const __koru_cond_s_9_3 = .{ .value = n, }; _ = &__koru_cond_s_9_3; " ++
            "const value = __koru_cond_s_9_3.value; _ = &value; ",
        try buildCondBinds(a, &conts, "{ value: n }", .zig),
    );
    try std.testing.expectEqualStrings(
        "const __koru_cond_s_9_3 = { value: n, }; " ++
            "const value = __koru_cond_s_9_3.value; ",
        try buildCondBinds(a, &conts, "{ value: n }", .js),
    );
}

test "cond binds: the binder that IS the scrutinee is never redeclared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `cond(k) | c k when …` (320_133's shape). `const k = k;` would self-shadow
    // on BOTH hosts — Zig rejects it, JS throws a TDZ ReferenceError — so the
    // binder is a no-op and the preamble stays empty either way.
    const conts = [_]ast.Continuation{.{
        .branch = "c",
        .binding = "k",
        .condition = "k == 1",
        .node = null,
        .indent = 0,
        .continuations = &.{},
        .location = .{ .file = "t", .line = 1, .column = 1 },
    }};
    try std.testing.expectEqualStrings("", try buildCondBinds(a, &conts, "k", .zig));
    try std.testing.expectEqualStrings("", try buildCondBinds(a, &conts, "k", .js));
}

test "presence: an optional arm's name becomes each host's presence test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `query = if(ask)` where query declares `! ?ask` (400_146's shape).
    const empty_shape = ast.Shape{ .fields = &.{} };
    const branches = [_]ast.Branch{
        .{ .name = "ask", .payload = empty_shape, .kind = .effect, .is_optional = true },
        .{ .name = "done", .payload = empty_shape, .kind = .terminal },
    };
    const ev = ast.EventDecl{
        .path = .{ .segments = &.{"query"} },
        .input = empty_shape,
        .branches = &branches,
    };
    const inv = ast.Invocation{ .path = .{ .segments = &.{"if"} }, .args = &.{} };

    // Zig asks the handler TYPE param; JS asks the handler OBJECT (js_emitter
    // :270 takes it as `H` on every effect-bearing event).
    try std.testing.expectEqualStrings(
        "@hasDecl(__H, \"ask\")",
        try presenceRewriteTemplateArg(a, &inv, &ev, "ask", .zig),
    );
    try std.testing.expectEqualStrings(
        "H.ask !== undefined",
        try presenceRewriteTemplateArg(a, &inv, &ev, "ask", .js),
    );

    // A REQUIRED arm is not a presence home — the shape checker walls it
    // (KORU131) — so it passes through verbatim on both hosts. Same for a name
    // that is no arm at all, and for any construct other than `if`.
    const other = ast.Invocation{ .path = .{ .segments = &.{"cond"} }, .args = &.{} };
    for ([_]HostLang{ .zig, .js }) |h| {
        try std.testing.expectEqualStrings("done", try presenceRewriteTemplateArg(a, &inv, &ev, "done", h));
        try std.testing.expectEqualStrings("nope", try presenceRewriteTemplateArg(a, &inv, &ev, "nope", h));
        try std.testing.expectEqualStrings("ask", try presenceRewriteTemplateArg(a, &other, &ev, "ask", h));
    }
}
