const std = @import("std");
const ast = @import("ast");

/// WAY-TWO recurrence-collapse recognition (design: /tmp/waytwo-collapse.md,
/// arbiter commission t5w leg WAY-TWO). Runs in elaborate after pre-transforms
/// and BEFORE unroll-recursion / process-template-procs while `if` is still a
/// structured invocation with a continuation tree.
///
/// Three gates per flow: hygiene (int-scalar event, untouched flow), purity
/// (continuation walk judged on parsed_expression — no foreign calls, builtin
/// whitelist), family solver (R1 nested accumulator / R2 tail-affine
/// accumulator additive+multiplicative / B1 fib doubling / B2 binomial
/// quotient). Every emitted body is guard → closed form, else → exact
/// fallback: the transform is the identity outside the proven domain.
///
/// Auto-fire per seat ruling (t5w): proof-should-be-free. Escape hatches:
/// KORU_COLLAPSE_OFF=1 disables the pass entirely, KORU_COLLAPSE_DEBUG=1 logs
/// admissions to stderr.
pub const Collapse = struct {
    allocator: std.mem.Allocator,
    transformed: usize = 0,
    debug: bool = false,

    const INT_TYPES = [_][]const u8{
        "i8",  "i16",  "i32",  "i64",  "i128", "isize",
        "u8",  "u16",  "u32",  "u64",  "u128", "usize",
    };
    /// Builtins admitted inside Koru arg/leaf expressions (name has no `@`).
    const BUILTIN_OK = [_][]const u8{ "rem", "divTrunc", "as", "intCast", "min", "max" };
    /// Boundary/literal sanity bound — keeps emitted comptime arithmetic
    /// (L + 62, S_p(L)) inside i64 and residual comparisons cheap.
    const LIT_LIMIT: i64 = 1 << 40;
    /// Coefficient atoms (param idents or literals) may each reach this bound;
    /// two atoms keep |coeff| <= ~2^62 so guard-time evaluation cannot wrap.
    const ATOM_LIMIT: i64 = 1 << 31;
    /// pow-mod domain: every product stays < 2^63 (3e9 * 3e9 = 9e18 < i64 max).
    const MUL_DOMAIN: i64 = 3000000000;
    /// fib fast-doubling is exact for n <= 91: the largest intermediate is
    /// fib(92) = 7540113804746346429 < i64 max; n = 92 would compute fib(93)
    /// which overflows where the original does not.
    const FIB_MAX: i64 = 91;
    /// Largest per-step magnitude the original can add without wrapping:
    /// keeps acc + step < 2^63 for acc < M <= 3e9.
    const STEP_LIMIT: i64 = 4611686018427387903; // 2^62 - 1

    const ZIG_KEYWORDS = [_][]const u8{
        "align",         "allowzero",   "and",        "anyframe",   "anytype",
        "asm",           "async",       "await",      "break",      "callconv",
        "catch",         "comptime",    "const",      "continue",   "defer",
        "else",          "enum",        "errdefer",   "error",      "export",
        "extern",        "fn",          "for",        "if",         "inline",
        "noalias",       "nosuspend",   "opaque",     "or",         "orelse",
        "packed",        "pub",         "resume",     "return",     "linksection",
        "struct",        "suspend",     "switch",     "test",       "threadlocal",
        "try",           "union",       "unreachable","usingnamespace","var",
        "volatile",      "while",
    };

    pub fn run(program: *const ast.Program, allocator: std.mem.Allocator) usize {
        if (std.posix.getenv("KORU_COLLAPSE_OFF") != null) return 0;
        var c = Collapse{
            .allocator = allocator,
            .debug = std.posix.getenv("KORU_COLLAPSE_DEBUG") != null,
        };
        runItems(@constCast(program.items), &c);
        return c.transformed;
    }

    // ---------------- small shared helpers (mirrors of the peel pass's) --------

    fn isIntType(t: []const u8) bool {
        for (INT_TYPES) |k| {
            if (std.mem.eql(u8, t, k)) return true;
        }
        return false;
    }

    fn pathsEqual(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
        const aq = a.module_qualifier orelse "";
        const bq = b.module_qualifier orelse "";
        if (!std.mem.eql(u8, aq, bq)) return false;
        if (a.segments.len != b.segments.len) return false;
        for (a.segments, b.segments) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }

    fn lastSegment(p: *const ast.DottedPath) []const u8 {
        return p.segments[p.segments.len - 1];
    }

    fn isIfKeyword(p: *const ast.DottedPath) bool {
        const mq = p.module_qualifier orelse "";
        const qualified = std.mem.eql(u8, mq, "std.control");
        const bare = mq.len == 0;
        if (!qualified and !bare) return false;
        return p.segments.len == 1 and std.mem.eql(u8, p.segments[0], "if");
    }

    fn identChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Param/rb names are emitted verbatim into Zig — refuse anything that is
    /// not a plain identifier or collides with a Zig keyword.
    fn zigNameOk(name: []const u8) bool {
        if (name.len == 0) return false;
        if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
        for (name) |c| {
            if (!identChar(c)) return false;
        }
        for (ZIG_KEYWORDS) |k| {
            if (std.mem.eql(u8, k, name)) return false;
        }
        return true;
    }

    fn litToI64(text: []const u8) ?i64 {
        var buf: [72]u8 = undefined;
        var n: usize = 0;
        for (text) |c| {
            if (c == '_') continue;
            if (n >= buf.len) return null;
            buf[n] = c;
            n += 1;
        }
        if (n == 0) return null;
        return std.fmt.parseInt(i64, buf[0..n], 0) catch null;
    }

    fn ungroup(e: *const ast.Expression) *const ast.Expression {
        var cur: *const ast.Expression = e;
        while (true) {
            switch (cur.node) {
                .grouped => |g| cur = g,
                else => return cur,
            }
        }
    }

    fn exprIsIdent(e: *const ast.Expression, name: []const u8) bool {
        const u = ungroup(e);
        return switch (u.node) {
            .identifier => |id| std.mem.eql(u8, id, name),
            else => false,
        };
    }

    fn paramOf(e: *const ast.Expression, params: []const []const u8) ?[]const u8 {
        const u = ungroup(e);
        const id = switch (u.node) {
            .identifier => |v| v,
            else => return null,
        };
        for (params) |p| {
            if (std.mem.eql(u8, p, id)) return id;
        }
        return null;
    }

    fn litNumber(e: *const ast.Expression) ?i64 {
        const u = ungroup(e);
        return switch (u.node) {
            .literal => |l| switch (l) {
                .number => |n| litToI64(n),
                else => null,
            },
            else => null,
        };
    }

    fn builtinOk(name: []const u8) bool {
        for (BUILTIN_OK) |k| {
            if (std.mem.eql(u8, k, name)) return true;
        }
        return false;
    }

    /// Purity + emittability: every identifier must be in `allowed`, every node
    /// kind serializable to Zig, every builtin whitelisted. Refuses
    /// divide/modulo/string_concat and all call/index/field/conditional shapes.
    fn exprAdmitted(e: *const ast.Expression, allowed: []const []const u8) bool {
        switch (e.node) {
            .literal => |l| return switch (l) {
                .number, .boolean => true,
                .string => false,
            },
            .identifier => |id| {
                for (allowed) |a| {
                    if (std.mem.eql(u8, a, id)) return true;
                }
                return false;
            },
            .binary => |b| {
                switch (b.op) {
                    .add, .subtract, .multiply,
                    .equal, .not_equal, .less, .less_equal,
                    .greater, .greater_equal, .and_op, .or_op,
                    => {},
                    else => return false,
                }
                return exprAdmitted(b.left, allowed) and exprAdmitted(b.right, allowed);
            },
            .unary => |u| return exprAdmitted(u.operand, allowed),
            .grouped => |g| return exprAdmitted(g, allowed),
            .builtin_call => |bc| {
                if (!builtinOk(bc.name)) return false;
                for (bc.args) |a| {
                    if (!exprAdmitted(a, allowed)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// Conservative "does this expression mention `name`" — unknown node kinds
    /// answer true so callers refuse rather than admit.
    fn exprMentions(e: *const ast.Expression, name: []const u8) bool {
        switch (e.node) {
            .literal => return false,
            .identifier => |id| return std.mem.eql(u8, id, name),
            .binary => |b| return exprMentions(b.left, name) or exprMentions(b.right, name),
            .unary => |u| return exprMentions(u.operand, name),
            .grouped => |g| return exprMentions(g, name),
            .builtin_call => |bc| {
                for (bc.args) |a| {
                    if (exprMentions(a, name)) return true;
                }
                return false;
            },
            else => return true,
        }
    }

    const Rename = struct { from: []const u8, to: []const u8 };

    fn binaryOpZig(op: ast.BinaryOperator) ?[]const u8 {
        return switch (op) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .equal => "==",
            .not_equal => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .and_op => "&&",
            .or_op => "||",
            else => null,
        };
    }

    /// Serialize an admitted expression to Zig text. `env` renames identifiers
    /// (accumulator → __rc_a, measure → __rc_m in fallback loops).
    fn emitExprZig(
        buf: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        e: *const ast.Expression,
        env: []const Rename,
    ) !void {
        switch (e.node) {
            .literal => |l| switch (l) {
                .number => |n| try buf.appendSlice(alloc, n),
                .string => |s| {
                    try buf.append(alloc, '"');
                    try buf.appendSlice(alloc, s);
                    try buf.append(alloc, '"');
                },
                .boolean => |b| try buf.appendSlice(alloc, if (b) "true" else "false"),
            },
            .identifier => |id| {
                for (env) |r| {
                    if (std.mem.eql(u8, r.from, id)) {
                        try buf.appendSlice(alloc, r.to);
                        return;
                    }
                }
                try buf.appendSlice(alloc, id);
            },
            .binary => |b| {
                const op = binaryOpZig(b.op) orelse return error.UnsupportedOp;
                try buf.append(alloc, '(');
                try emitExprZig(buf, alloc, b.left, env);
                try buf.append(alloc, ' ');
                try buf.appendSlice(alloc, op);
                try buf.append(alloc, ' ');
                try emitExprZig(buf, alloc, b.right, env);
                try buf.append(alloc, ')');
            },
            .unary => |u| {
                try buf.append(alloc, '(');
                try buf.appendSlice(alloc, if (u.op == .negate) "-" else "!");
                try emitExprZig(buf, alloc, u.operand, env);
                try buf.append(alloc, ')');
            },
            .grouped => |g| {
                try buf.append(alloc, '(');
                try emitExprZig(buf, alloc, g, env);
                try buf.append(alloc, ')');
            },
            .builtin_call => |bc| {
                try buf.append(alloc, '@');
                try buf.appendSlice(alloc, bc.name);
                try buf.append(alloc, '(');
                for (bc.args, 0..) |a, i| {
                    if (i > 0) try buf.appendSlice(alloc, ", ");
                    try emitExprZig(buf, alloc, a, env);
                }
                try buf.append(alloc, ')');
            },
            else => return error.UnsupportedNode,
        }
    }

    // ---------------- guard / leaf / structure matchers -----------------------

    const Guard = struct {
        param: []const u8,
        /// Base region is `m <= boundary` for kind .le, `m == boundary` for .eq.
        kind: enum { eq, le },
        boundary: i64,
    };

    fn flipOp(op: ast.BinaryOperator) ast.BinaryOperator {
        return switch (op) {
            .less => .greater,
            .less_equal => .greater_equal,
            .greater => .less,
            .greater_equal => .less_equal,
            else => op,
        };
    }

    /// Normalize `m <cmp> lit` (either orientation) into {param, kind, boundary}.
    /// Admitted: ==, <=, <  (>= / > heads recurse away from base — diverge).
    /// lt b  →  base covers m <= b-1  →  boundary = b-1, kind = .le
    /// le b  →  base covers m <= b    →  boundary = b,   kind = .le
    /// eq b  →  base covers m == b    →  boundary = b,   kind = .eq
    fn guardFromOp(op: ast.BinaryOperator, param: []const u8, lit: i64) ?Guard {
        if (lit < -LIT_LIMIT or lit > LIT_LIMIT) return null;
        return switch (op) {
            .equal => Guard{ .param = param, .kind = .eq, .boundary = lit },
            .less_equal => Guard{ .param = param, .kind = .le, .boundary = lit },
            .less => Guard{ .param = param, .kind = .le, .boundary = lit - 1 },
            else => null,
        };
    }

    fn parseGuard(e: *const ast.Expression, params: []const []const u8) ?Guard {
        const u = ungroup(e);
        const b = switch (u.node) {
            .binary => |bb| bb,
            else => return null,
        };
        const lp = paramOf(b.left, params);
        const rp = paramOf(b.right, params);
        const ll = litNumber(b.left);
        const rl = litNumber(b.right);
        if (lp != null and rl != null and rp == null) {
            return guardFromOp(b.op, lp.?, rl.?);
        }
        if (rp != null and ll != null and lp == null) {
            return guardFromOp(flipOp(b.op), rp.?, ll.?);
        }
        return null;
    }

    /// `m - <int lit>` — the constant-decrement witness.
    fn matchDecrement(e: *const ast.Expression, m: []const u8) ?i64 {
        const u = ungroup(e);
        const b = switch (u.node) {
            .binary => |bb| bb,
            else => return null,
        };
        if (b.op != .subtract) return null;
        if (!exprIsIdent(b.left, m)) return null;
        return litNumber(b.right);
    }

    fn parensWrap(s: []const u8) bool {
        var depth: i64 = 0;
        for (s, 0..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (depth < 0) return false;
            if (depth == 0 and i != s.len - 1) return false;
        }
        return depth == 0;
    }

    /// Leaf text of the form `ident`, `ident + lit`, `ident - lit`, `lit + ident`
    /// (outer parens stripped). Returns the signed delta, or null.
    fn leafIdentDelta(text_in: []const u8, ident: []const u8) ?i64 {
        var s = std.mem.trim(u8, text_in, " \t\n\r");
        while (s.len >= 2 and s[0] == '(' and s[s.len - 1] == ')' and parensWrap(s)) {
            s = std.mem.trim(u8, s[1 .. s.len - 1], " \t\n\r");
        }
        if (std.mem.eql(u8, s, ident)) return 0;

        // ident <op> num
        if (s.len > ident.len and std.mem.startsWith(u8, s, ident)) {
            var i = ident.len;
            if (identChar(s[i])) return null;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
            if (i >= s.len) return null;
            const op = s[i];
            if (op != '+' and op != '-') return null;
            i += 1;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
            const num_start = i;
            while (i < s.len and (identChar(s[i]) or s[i] == '+' or s[i] == '-')) i += 1;
            if (std.mem.trim(u8, s[i..], " \t\n\r").len != 0) return null;
            const num = litToI64(s[num_start..i]) orelse return null;
            if (num > LIT_LIMIT or num < -LIT_LIMIT) return null;
            return if (op == '+') num else -num;
        }

        // num + ident  (num - ident is NOT affine — refuse)
        var i: usize = 0;
        while (i < s.len and (identChar(s[i]) or s[i] == '+' or s[i] == '-')) i += 1;
        const num = litToI64(s[0..i]) orelse return null;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len or s[i] != '+') return null;
        i += 1;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (!std.mem.eql(u8, s[i..], ident)) return null;
        if (num > LIT_LIMIT or num < -LIT_LIMIT) return null;
        return num;
    }

    /// Produce leaf that is exactly `x + y` (either order, whitespace-free).
    fn leafIsSumOf(text_in: []const u8, x: []const u8, y: []const u8) bool {
        var buf: [512]u8 = undefined;
        var n: usize = 0;
        for (text_in) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
            if (n >= buf.len) return false;
            buf[n] = c;
            n += 1;
        }
        const t = buf[0..n];
        var c1: [520]u8 = undefined;
        var m: usize = 0;
        for ([_][]const u8{ x, "+", y }) |p| {
            for (p) |c| {
                if (m >= c1.len) return false;
                c1[m] = c;
                m += 1;
            }
        }
        if (std.mem.eql(u8, t, c1[0..m])) return true;
        m = 0;
        for ([_][]const u8{ y, "+", x }) |p| {
            for (p) |c| {
                if (m >= c1.len) return false;
                c1[m] = c;
                m += 1;
            }
        }
        return std.mem.eql(u8, t, c1[0..m]);
    }

    fn leafIsLiteral(text_in: []const u8, want: []const u8) bool {
        const t = std.mem.trim(u8, text_in, " \t\n\r");
        return std.mem.eql(u8, t, want);
    }

    fn leafIsIdent(text_in: []const u8, ident: []const u8) bool {
        const t = std.mem.trim(u8, text_in, " \t\n\r");
        return std.mem.eql(u8, t, ident);
    }

    fn leafText(c: *const ast.Continuation) ?[]const u8 {
        const n = c.node orelse return null;
        return switch (n) {
            .expression => |t| t,
            .branch_constructor => |bc| bc.plain_value orelse null,
            else => null,
        };
    }

    /// Structural hygiene for a continuation we descend into: terminal kind, no
    /// binding/condition/produce/destructure/catchall/marks, no grafted subtree.
    fn contClean(c: *const ast.Continuation) bool {
        if (c.kind != .terminal) return false;
        if (c.is_catchall or c.catchall_metatype != null) return false;
        if (c.is_transformed_subtree) return false;
        if (c.condition != null or c.condition_expr != null or c.post_condition != null) return false;
        if (c.binding != null) return false;
        if (c.destructure.len != 0 or c.produce.len != 0 or c.destructure_named) return false;
        if (c.binding_annotations.len != 0 or c.binding_marks.len != 0) return false;
        return true;
    }

    /// Pointer into the continuation's stored Node — payload pointers stay valid
    /// for the duration of the match (the AST outlives the pass).
    fn selfCallOf(c: *const ast.Continuation, impl_of: *const ast.DottedPath) ?*const ast.Invocation {
        if (c.node == null) return null;
        const n: *const ast.Node = &c.node.?;
        if (n.* != .invocation) return null;
        const inv: *const ast.Invocation = &n.invocation;
        if (!pathsEqual(&inv.path, impl_of)) return null;
        return inv;
    }

    /// Same, for a std.control:if head node.
    fn ifNodeOf(c: *const ast.Continuation) ?*const ast.Invocation {
        if (c.node == null) return null;
        const n: *const ast.Node = &c.node.?;
        if (n.* != .invocation) return null;
        const inv: *const ast.Invocation = &n.invocation;
        if (!isIfKeyword(&inv.path)) return null;
        return inv;
    }

    /// The step is an invocation of `<qual>:<seg>` (single-segment call).
    fn callOnPath(c: *const ast.Continuation, qual: []const u8, seg: []const u8) ?*const ast.Invocation {
        if (c.node == null) return null;
        const n: *const ast.Node = &c.node.?;
        if (n.* != .invocation) return null;
        const inv: *const ast.Invocation = &n.invocation;
        const mq = inv.path.module_qualifier orelse "";
        if (!std.mem.eql(u8, mq, qual)) return null;
        if (inv.path.segments.len != 1) return null;
        if (!std.mem.eql(u8, inv.path.segments[0], seg)) return null;
        return inv;
    }

    fn fieldAccessOf(e: *const ast.Expression) ?*const ast.FieldAccess {
        const u = ungroup(e);
        return switch (u.node) {
            .field_access => |*fa| fa,
            else => null,
        };
    }

    fn identName(e: *const ast.Expression) ?[]const u8 {
        const u = ungroup(e);
        return switch (u.node) {
            .identifier => |id| id,
            else => null,
        };
    }

    /// The single clean branch-less continuation link, or null.
    fn linkCont(c: *const ast.Continuation) ?*const ast.Continuation {
        if (c.continuations.len != 1) return null;
        const n = &c.continuations[0];
        if (!contClean(n)) return null;
        if (n.branch.len != 0) return null;
        return n;
    }

    fn rbOk(inv: *const ast.Invocation) bool {
        const rb = inv.return_binding orelse return false;
        if (rb.len == 0 or std.mem.eql(u8, rb, "_")) return false;
        return zigNameOk(rb);
    }

    fn findBranch(conts: []const ast.Continuation, name: []const u8) ?*const ast.Continuation {
        for (conts) |*c| {
            if (std.mem.eql(u8, c.branch, name)) return c;
        }
        return null;
    }

    fn argForParam(inv: *const ast.Invocation, name: []const u8) ?*const ast.Arg {
        for (inv.args) |*a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    /// All params covered by args, each with a parsed_expression.
    fn argsCoverParams(inv: *const ast.Invocation, params: []const []const u8) bool {
        if (inv.args.len != params.len) return false;
        for (params) |p| {
            const a = argForParam(inv, p) orelse return false;
            if (a.parsed_expression == null) return false;
        }
        return true;
    }

    fn appendLit(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i64) !void {
        var tmp: [24]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{v});
        try buf.appendSlice(alloc, s);
    }

    fn ap(
        buf: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try buf.appendSlice(alloc, s);
    }

    fn setBody(flow: *ast.Flow, c: *Collapse, family: []const u8, body: []const u8) void {
        const text = std.fmt.allocPrint(c.allocator, "//@koru:inline_stmt\n// __koru_collapse_{s}\n{s}", .{ family, body }) catch return;
        flow.inline_body = text;
        c.transformed += 1;
        if (c.debug) {
            std.debug.print("collapse: admitted {s} at {s}:{d}\n", .{ family, flow.location.file, flow.location.line });
        }
    }

    // ---------------- family matchers ----------------------------------------

    const Ctx = struct {
        c: *Collapse,
        params: []const []const u8,
        impl_of: *const ast.DottedPath,
        residual: []const u8,
    };

    /// R1 — nested accumulator chain (hanoi): T(m,a) = T(m-1, T(m-1,a)+d) + k.
    /// Closed form: a + B*2^e + D*(2^e - 1) + K where e = m - L.
    fn tryR1(ctx: *const Ctx, g: Guard, then_leaf: []const u8, else_c: *const ast.Continuation) !?[]const u8 {
        if (ctx.c.debug) std.debug.print("collapse: tryR1 entered\n", .{});
        if (ctx.params.len != 2) return null;
        const alloc = ctx.c.allocator;
        const m = g.param;
        const acc = if (std.mem.eql(u8, ctx.params[0], m)) ctx.params[1] else ctx.params[0];

        const B = leafIdentDelta(then_leaf, acc) orelse return null;

        if (!contClean(else_c)) return null;
        const inv1 = selfCallOf(else_c, ctx.impl_of) orelse return null;
        if (!rbOk(inv1)) return null;
        if (else_c.continuations.len != 1) return null;
        const link1 = &else_c.continuations[0];
        if (!contClean(link1)) return null;
        if (link1.branch.len != 0) return null;
        const inv2 = selfCallOf(link1, ctx.impl_of) orelse return null;
        if (!rbOk(inv2)) return null;
        if (link1.continuations.len != 1) return null;
        const link2 = &link1.continuations[0];
        if (!contClean(link2)) return null;
        if (link2.branch.len != 0) return null;
        if (link2.continuations.len != 0) return null;
        const prod = leafText(link2) orelse return null;

        if (!argsCoverParams(inv1, ctx.params)) return null;
        if (!argsCoverParams(inv2, ctx.params)) return null;
        if ((matchDecrement(argForParam(inv1, m).?.parsed_expression.?, m) orelse return null) != 1) return null;
        if ((matchDecrement(argForParam(inv2, m).?.parsed_expression.?, m) orelse return null) != 1) return null;

        // call1 acc arg: bare identifier acc
        if (!exprIsIdent(argForParam(inv1, acc).?.parsed_expression.?, acc)) return null;

        // call2 acc arg: rb1 +- lit → D
        const rb1 = inv1.return_binding.?;
        const ae2 = argForParam(inv2, acc).?.parsed_expression.?;
        const ug = ungroup(ae2);
        const bb = switch (ug.node) {
            .binary => |x| x,
            else => return null,
        };
        var D: i64 = 0;
        if (bb.op == .add) {
            const lbind = exprIsIdent(bb.left, rb1);
            const rbind = exprIsIdent(bb.right, rb1);
            if (lbind == rbind) return null;
            const lv = litNumber(if (lbind) bb.right else bb.left) orelse return null;
            if (lv > LIT_LIMIT or lv < -LIT_LIMIT) return null;
            D = lv;
        } else if (bb.op == .subtract) {
            if (!exprIsIdent(bb.left, rb1)) return null;
            const lv = litNumber(bb.right) orelse return null;
            if (lv > LIT_LIMIT or lv < -LIT_LIMIT) return null;
            D = -lv;
        } else return null;

        // produce leaf: rb2 +- lit → K
        const rb2 = inv2.return_binding.?;
        const K = leafIdentDelta(prod, rb2) orelse return null;

        for (inv1.args) |a| {
            if (!exprAdmitted(a.parsed_expression.?, ctx.params)) return null;
        }
        {
            var allowed2: [3][]const u8 = undefined;
            allowed2[0] = ctx.params[0];
            allowed2[1] = ctx.params[1];
            allowed2[2] = rb1;
            for (inv2.args) |a| {
                if (!exprAdmitted(a.parsed_expression.?, &allowed2)) return null;
            }
        }

        const residual = ctx.residual;
        var b = std.ArrayList(u8){};
        defer b.deinit(alloc);
        if (g.kind == .eq) {
            try ap(&b, alloc, "if ({s} == {d}) return {s} + ({d});\n", .{ m, g.boundary, acc, B });
        } else {
            try ap(&b, alloc, "if ({s} <= {d}) return {s} + ({d});\n", .{ m, g.boundary, acc, B });
        }
        try ap(&b, alloc, "if ({s} > {d} and {s} <= {d}) {{\n", .{ m, g.boundary, m, g.boundary + 62 });
        try ap(&b, alloc, "    const __e: i64 = {s} - ({d});\n", .{ m, g.boundary });
        try b.appendSlice(alloc, "    const __p2: i64 = @as(i64, 1) << @as(u6, @intCast(__e));\n");
        try ap(&b, alloc, "    const __ub = @import(\"std\").math.mul(i64, {d}, __p2) catch return {s};\n", .{ B, residual });
        try ap(&b, alloc, "    const __ud = @import(\"std\").math.mul(i64, {d}, __p2 - 1) catch return {s};\n", .{ D, residual });
        try ap(&b, alloc, "    const __us = @import(\"std\").math.add(i64, __ub, __ud) catch return {s};\n", .{residual});
        try ap(&b, alloc, "    const __uk = @import(\"std\").math.add(i64, __us, {d}) catch return {s};\n", .{ K, residual });
        try ap(&b, alloc, "    return @import(\"std\").math.add(i64, {s}, __uk) catch return {s};\n", .{ acc, residual });
        try b.appendSlice(alloc, "}\n");
        try ap(&b, alloc, "return {s};\n", .{residual});
        return try b.toOwnedSlice(alloc);
    }

    const UpdateInfo = struct {
        multiplicative: bool,
        modulus: i64, // 0 = none
        operand: *const ast.Expression, // step (additive) or factor (multiplicative)
    };

    /// Classify the accumulator arg: `acc + step` optionally under `@rem(., M)`,
    /// or `acc * factor` under `@rem(., M)` (multiplicative requires modulus).
    fn classifyUpdate(e: *const ast.Expression, acc: []const u8) ?UpdateInfo {
        var u = ungroup(e);
        var modulus: i64 = 0;
        if (u.node == .builtin_call) {
            const bc = u.node.builtin_call;
            if (!std.mem.eql(u8, bc.name, "rem") or bc.args.len != 2) return null;
            const mv = litNumber(bc.args[1]) orelse return null;
            if (mv <= 0 or mv > MUL_DOMAIN) return null;
            modulus = mv;
            u = ungroup(bc.args[0]);
        }
        const b = switch (u.node) {
            .binary => |bb| bb,
            else => return null,
        };
        if (b.op == .add) {
            const lacc = exprIsIdent(b.left, acc);
            const racc = exprIsIdent(b.right, acc);
            if (lacc == racc) return null;
            const step = if (lacc) b.right else b.left;
            if (exprMentions(step, acc)) return null;
            return UpdateInfo{ .multiplicative = false, .modulus = modulus, .operand = step };
        }
        if (b.op == .multiply) {
            if (modulus == 0) return null;
            const lacc = exprIsIdent(b.left, acc);
            const racc = exprIsIdent(b.right, acc);
            if (lacc == racc) return null;
            const factor = if (lacc) b.right else b.left;
            if (exprMentions(factor, acc)) return null;
            return UpdateInfo{ .multiplicative = true, .modulus = modulus, .operand = factor };
        }
        return null;
    }

    const StepInfo = struct {
        power: u8, // 0,1,2
        coeff: []const u8, // serialized coeff (product of non-m atoms)
        coeff_params: []const []const u8, // param idents inside coeff (for guards)
    };

    /// step = coeff * m^p, p in {0,1,2}; coeff = product of <=2 atoms each a
    /// param ident (not m/acc) or int literal |v| <= ATOM_LIMIT.
    fn classifyStep(
        alloc: std.mem.Allocator,
        step: *const ast.Expression,
        m: []const u8,
        acc: []const u8,
        params: []const []const u8,
    ) ?StepInfo {
        var factors = std.ArrayList(*const ast.Expression){};
        defer factors.deinit(alloc);
        flattenMul(alloc, step, &factors);

        var power: u8 = 0;
        var atoms = std.ArrayList(*const ast.Expression){};
        defer atoms.deinit(alloc);
        for (factors.items) |f| {
            if (exprIsIdent(f, m)) {
                power += 1;
                if (power > 2) return null;
                continue;
            }
            atoms.append(alloc, f) catch return null;
        }
        if (atoms.items.len > 2) return null;
        if (atoms.items.len == 0 and power == 0) return null;

        var coeff_params = std.ArrayList([]const u8){};
        defer coeff_params.deinit(alloc);
        var coeff_buf = std.ArrayList(u8){};
        defer coeff_buf.deinit(alloc);
        for (atoms.items, 0..) |a, i| {
            const u = ungroup(a);
            switch (u.node) {
                .identifier => |id| {
                    if (std.mem.eql(u8, id, m) or std.mem.eql(u8, id, acc)) return null;
                    var is_param = false;
                    for (params) |p| {
                        if (std.mem.eql(u8, p, id)) {
                            is_param = true;
                            break;
                        }
                    }
                    if (!is_param) return null;
                    var dup = false;
                    for (coeff_params.items) |cp| {
                        if (std.mem.eql(u8, cp, id)) dup = true;
                    }
                    if (!dup) coeff_params.append(alloc, id) catch return null;
                },
                .literal => |l| switch (l) {
                    .number => |n| {
                        const v = litToI64(n) orelse return null;
                        if (v > ATOM_LIMIT or v < -ATOM_LIMIT) return null;
                    },
                    else => return null,
                },
                else => return null,
            }
            if (exprMentions(a, m) or exprMentions(a, acc)) return null;
            if (i > 0) coeff_buf.appendSlice(alloc, " * ") catch return null;
            emitExprZig(&coeff_buf, alloc, a, &[_]Rename{}) catch return null;
        }
        if (coeff_buf.items.len == 0) {
            coeff_buf.appendSlice(alloc, "1") catch return null;
        }
        return StepInfo{
            .power = power,
            .coeff = coeff_buf.toOwnedSlice(alloc) catch return null,
            .coeff_params = coeff_params.toOwnedSlice(alloc) catch return null,
        };
    }

    fn flattenMul(alloc: std.mem.Allocator, e: *const ast.Expression, out: *std.ArrayList(*const ast.Expression)) void {
        const u = ungroup(e);
        switch (u.node) {
            .binary => |b| {
                if (b.op == .multiply) {
                    flattenMul(alloc, b.left, out);
                    flattenMul(alloc, b.right, out);
                    return;
                }
            },
            else => {},
        }
        out.append(alloc, u) catch {};
    }

    /// Emit the checked S_p(x) chain for the additive closed form. `xt` is the
    /// operand text (param name or literal), `itype` is "i64" or "i128", and
    /// `cf` is the enclosing block label overflow-breaks target.
    fn appendFaulhaber(
        b: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        out: []const u8,
        xt: []const u8,
        p: u8,
        itype: []const u8,
        cf: []const u8,
    ) !void {
        switch (p) {
            0 => try ap(b, alloc, "            const {s} = @as({s}, ({s}));\n", .{ out, itype, xt }),
            1 => {
                try ap(b, alloc, "            const {s}_t = @import(\"std\").math.mul({s}, @as({s}, ({s})), @as({s}, ({s})) + 1) catch break :{s} null;\n", .{ out, itype, itype, xt, itype, xt, cf });
                try ap(b, alloc, "            const {s} = @divTrunc({s}_t, 2);\n", .{ out, out });
            },
            2 => {
                try ap(b, alloc, "            const {s}_t1 = @import(\"std\").math.mul({s}, @as({s}, ({s})), @as({s}, ({s})) + 1) catch break :{s} null;\n", .{ out, itype, itype, xt, itype, xt, cf });
                try ap(b, alloc, "            const {s}_t2 = @import(\"std\").math.mul({s}, {s}_t1, 2 * @as({s}, ({s})) + 1) catch break :{s} null;\n", .{ out, itype, out, itype, xt, cf });
                try ap(b, alloc, "            const {s} = @divTrunc({s}_t2, 6);\n", .{ out, out });
            },
            else => unreachable,
        }
    }

    /// R2 — single tail self-call with affine/multiplicative accumulator update.
    /// Fallback is an exact while-loop of the original recurrence (handles any
    /// depth, reproduces wrap/trap behavior bit-for-bit); native residual only
    /// for the divergence residue (measure below boundary under == base).
    fn tryR2(ctx: *const Ctx, g: Guard, then_leaf: []const u8, else_c: *const ast.Continuation) !?[]const u8 {
        if (ctx.c.debug) std.debug.print("collapse: tryR2 entered\n", .{});
        if (ctx.params.len < 2) return null;
        const alloc = ctx.c.allocator;
        const m = g.param;

        if (!contClean(else_c)) return null;
        const inv = selfCallOf(else_c, ctx.impl_of) orelse return null;
        if (!rbOk(inv)) return null;
        if (else_c.continuations.len != 1) return null;
        const link = &else_c.continuations[0];
        if (!contClean(link)) return null;
        if (link.branch.len != 0) return null;
        if (link.continuations.len != 0) return null;
        const prod = leafText(link) orelse return null;
        const rb = inv.return_binding.?;
        const pd = leafIdentDelta(prod, rb) orelse return null;
        if (pd != 0) return null; // post-transform produce — not an accumulator

        if (!argsCoverParams(inv, ctx.params)) return null;
        if ((matchDecrement(argForParam(inv, m).?.parsed_expression.?, m) orelse return null) != 1) return null;

        // find acc: exactly one non-measure param whose arg is a non-passthrough
        // update; every other non-measure param must be an identifier pun.
        var acc_name: ?[]const u8 = null;
        var upd: ?UpdateInfo = null;
        var upd_expr: ?*const ast.Expression = null;
        for (ctx.params) |p| {
            if (std.mem.eql(u8, p, m)) continue;
            const e = argForParam(inv, p).?.parsed_expression.?;
            if (exprIsIdent(e, p)) continue;
            if (acc_name != null) return null;
            const u = ungroup(e);
            if (u.node == .identifier) return null; // rename, not passthrough
            const info = classifyUpdate(e, p) orelse return null;
            if (!exprMentions(e, p)) return null;
            acc_name = p;
            upd = info;
            upd_expr = e;
        }
        const accn = acc_name orelse return null;
        const up = upd.?;
        const uexpr = upd_expr.?;

        const B = leafIdentDelta(then_leaf, accn) orelse return null;

        for (inv.args) |a| {
            if (!exprAdmitted(a.parsed_expression.?, ctx.params)) return null;
        }
        if (up.multiplicative and exprMentions(up.operand, m)) return null;

        const residual = ctx.residual;
        var b = std.ArrayList(u8){};
        defer b.deinit(alloc);

        if (g.kind == .eq) {
            try ap(&b, alloc, "if ({s} == {d}) return {s} + ({d});\n", .{ m, g.boundary, accn, B });
        } else {
            try ap(&b, alloc, "if ({s} <= {d}) return {s} + ({d});\n", .{ m, g.boundary, accn, B });
        }

        try b.appendSlice(alloc, "const __out: i64 = __fb: {\n    if (");

        if (up.multiplicative) {
            // R2b — acc * factor^(e-L) mod M via square-and-multiply.
            // Requires L >= 0 so e - L cannot overflow.
            if (g.boundary < 0) return null;
            const factor = up.operand;
            const fp = paramOf(factor, ctx.params);
            const factor_is_param = fp != null and !std.mem.eql(u8, fp.?, m) and !std.mem.eql(u8, fp.?, accn);
            try ap(&b, alloc, "{s} > {d} and {s} >= 0 and {s} <= {d}", .{ m, g.boundary, accn, accn, MUL_DOMAIN });
            if (factor_is_param) {
                try ap(&b, alloc, " and {s} >= 0 and {s} <= {d}", .{ fp.?, fp.?, MUL_DOMAIN });
            } else {
                const fv = litNumber(factor) orelse return null;
                if (fv < 0 or fv > MUL_DOMAIN) return null;
            }
            try b.appendSlice(alloc, ") {\n");
            try ap(&b, alloc, "        var __r: i64 = {s};\n", .{accn});
            var fb2 = std.ArrayList(u8){};
            defer fb2.deinit(alloc);
            emitExprZig(&fb2, alloc, factor, &[_]Rename{}) catch return null;
            try ap(&b, alloc, "        var __b: i64 = {s};\n", .{fb2.items});
            try ap(&b, alloc, "        var __x: i64 = {s} - ({d});\n", .{ m, g.boundary });
            try b.appendSlice(alloc, "        while (__x > 0) {\n");
            try ap(&b, alloc, "            if (@rem(__x, 2) == 1) __r = @rem(__r * __b, {d});\n", .{up.modulus});
            try ap(&b, alloc, "            __b = @rem(__b * __b, {d});\n", .{up.modulus});
            try b.appendSlice(alloc, "            __x = @divTrunc(__x, 2);\n        }\n");
            try ap(&b, alloc, "        break :__fb __r + ({d});\n", .{B});
            try b.appendSlice(alloc, "    }\n");
        } else {
            // R2a — additive accumulator step = coeff * m^p, optional @rem modulus.
            const step = up.operand;
            const si = classifyStep(alloc, step, m, accn, ctx.params) orelse return null;
            const has_mod = up.modulus != 0;
            if (has_mod and g.boundary < -1) return null; // running sum must stay >= 0

            try ap(&b, alloc, "{s} > {d}", .{ m, g.boundary });
            for (si.coeff_params) |cp| {
                try ap(&b, alloc, " and {s} >= -{d} and {s} <= {d}", .{ cp, ATOM_LIMIT, cp, ATOM_LIMIT });
            }
            if (has_mod) {
                try ap(&b, alloc, " and {s} >= 0 and ({s}) >= 0", .{ accn, si.coeff });
            }
            switch (si.power) {
                0 => {},
                1 => try ap(&b, alloc, " and (({s}) == 0 or {s} <= @divTrunc({d}, ({s})))", .{ si.coeff, m, STEP_LIMIT, si.coeff }),
                2 => try ap(&b, alloc, " and (({s}) == 0 or ({s} <= 2147483647 and {s} * {s} <= @divTrunc({d}, ({s}))))", .{ si.coeff, m, m, m, STEP_LIMIT, si.coeff }),
                else => unreachable,
            }
            try b.appendSlice(alloc, ") {\n");

            // coeff == 0 → every step adds 0 → rem(acc, M) stabilizes immediately
            try ap(&b, alloc, "        if (({s}) == 0) break :__fb ", .{si.coeff});
            if (has_mod) {
                try ap(&b, alloc, "@rem({s}, {d}) + ({d});\n", .{ accn, up.modulus, B });
            } else {
                try ap(&b, alloc, "{s} + ({d});\n", .{ accn, B });
            }

            if (has_mod) {
                // i128 lane: the true sum can exceed i64 while staying exact;
                // per-step bound guards keep the ORIGINAL wrap-free, and the
                // i128 checked chain covers every feasible closed-form input.
                try b.appendSlice(alloc, "        const __t: ?i128 = __cf: {\n");
                var lbuf = std.ArrayList(u8){};
                defer lbuf.deinit(alloc);
                appendLit(&lbuf, alloc, g.boundary) catch return null;
                const xtexts = [_][]const u8{ m, lbuf.items };
                try appendFaulhaber(&b, alloc, "__xm", xtexts[0], si.power, "i128", "__cf");
                try appendFaulhaber(&b, alloc, "__xl", xtexts[1], si.power, "i128", "__cf");
                try b.appendSlice(alloc, "            const __df = @import(\"std\").math.sub(i128, __xm, __xl) catch break :__cf null;\n");
                try ap(&b, alloc, "            const __prod = @import(\"std\").math.mul(i128, @as(i128, ({s})), __df) catch break :__cf null;\n", .{si.coeff});
                try ap(&b, alloc, "            break :__cf @import(\"std\").math.add(i128, @as(i128, {s}), __prod) catch break :__cf null;\n", .{accn});
                try b.appendSlice(alloc, "        };\n");
                try b.appendSlice(alloc, "        if (__t) |v| {\n");
                try ap(&b, alloc, "            const __w = @rem(v, @as(i128, {d}));\n", .{up.modulus});
                try ap(&b, alloc, "            break :__fb @as(i64, @intCast(__w)) + ({d});\n", .{B});
                try b.appendSlice(alloc, "        }\n");
                try b.appendSlice(alloc, "    }\n");
            } else {
                // no modulus: closed form must match the original's i64 wrap
                // semantics exactly — checked i64 chain, overflow → fallback.
                try b.appendSlice(alloc, "        const __t: ?i64 = __cf: {\n");
                var lbuf = std.ArrayList(u8){};
                defer lbuf.deinit(alloc);
                appendLit(&lbuf, alloc, g.boundary) catch return null;
                const xtexts = [_][]const u8{ m, lbuf.items };
                try appendFaulhaber(&b, alloc, "__xm", xtexts[0], si.power, "i64", "__cf");
                try appendFaulhaber(&b, alloc, "__xl", xtexts[1], si.power, "i64", "__cf");
                try b.appendSlice(alloc, "            const __df = @import(\"std\").math.sub(i64, __xm, __xl) catch break :__cf null;\n");
                try ap(&b, alloc, "            const __prod = @import(\"std\").math.mul(i64, ({s}), __df) catch break :__cf null;\n", .{si.coeff});
                try ap(&b, alloc, "            break :__cf @import(\"std\").math.add(i64, {s}, __prod) catch break :__cf null;\n", .{accn});
                try b.appendSlice(alloc, "        };\n");
                try b.appendSlice(alloc, "        if (__t) |v| break :__fb v + (");
                try appendLit(&b, alloc, B);
                try b.appendSlice(alloc, ");\n    }\n");
            }
        }

        // fallback: exact iteration of the original recurrence
        try ap(&b, alloc, "    var __rc_m: i64 = {s};\n", .{m});
        try ap(&b, alloc, "    var __rc_a: i64 = {s};\n", .{accn});
        try ap(&b, alloc, "    while (__rc_m > ({d})) {{\n", .{g.boundary});
        var fb = std.ArrayList(u8){};
        defer fb.deinit(alloc);
        const env = [_]Rename{
            .{ .from = m, .to = "__rc_m" },
            .{ .from = accn, .to = "__rc_a" },
        };
        emitExprZig(&fb, alloc, uexpr, &env) catch return null;
        try ap(&b, alloc, "        __rc_a = {s};\n", .{fb.items});
        try b.appendSlice(alloc, "        __rc_m -= 1;\n    }\n");
        if (g.kind == .eq) {
            try ap(&b, alloc, "    if (__rc_m != ({d})) return {s};\n", .{ g.boundary, residual });
        }
        try ap(&b, alloc, "    break :__fb __rc_a + (", .{});
        try appendLit(&b, alloc, B);
        try b.appendSlice(alloc, ");\n};\nreturn __out;\n");
        return try b.toOwnedSlice(alloc);
    }

    /// B1 — fib shape: U(n) = U(n-1) + U(n-2), base n <= 1 → n. Fast doubling,
    /// exact for 2 <= n <= 91 (intermediates are fib(j), j <= n+1 <= 92).
    fn tryFib(ctx: *const Ctx, g: Guard, then_leaf: []const u8, else_c: *const ast.Continuation) !?[]const u8 {
        if (ctx.c.debug) std.debug.print("collapse: tryFib entered\n", .{});
        if (ctx.params.len != 1) return null;
        const alloc = ctx.c.allocator;
        const n = ctx.params[0];
        if (!std.mem.eql(u8, g.param, n)) return null;
        if (g.kind != .le or g.boundary != 1) return null; // fib base: n <= 1 → n
        if (!leafIsIdent(then_leaf, n)) return null;

        if (!contClean(else_c)) return null;
        const inv1 = selfCallOf(else_c, ctx.impl_of) orelse return null;
        if (!rbOk(inv1)) return null;
        if (else_c.continuations.len != 1) return null;
        const link1 = &else_c.continuations[0];
        if (!contClean(link1)) return null;
        if (link1.branch.len != 0) return null;
        const inv2 = selfCallOf(link1, ctx.impl_of) orelse return null;
        if (!rbOk(inv2)) return null;
        if (link1.continuations.len != 1) return null;
        const link2 = &link1.continuations[0];
        if (!contClean(link2)) return null;
        if (link2.branch.len != 0 or link2.continuations.len != 0) return null;
        const prod = leafText(link2) orelse return null;

        if (!argsCoverParams(inv1, ctx.params)) return null;
        if (!argsCoverParams(inv2, ctx.params)) return null;
        const d1 = matchDecrement(argForParam(inv1, n).?.parsed_expression.?, n) orelse return null;
        const d2 = matchDecrement(argForParam(inv2, n).?.parsed_expression.?, n) orelse return null;
        if (!((d1 == 1 and d2 == 2) or (d1 == 2 and d2 == 1))) return null;

        const rb1 = inv1.return_binding.?;
        const rb2 = inv2.return_binding.?;
        if (!leafIsSumOf(prod, rb1, rb2)) return null;

        for (inv1.args) |a| {
            if (!exprAdmitted(a.parsed_expression.?, ctx.params)) return null;
        }
        for (inv2.args) |a| {
            if (!exprAdmitted(a.parsed_expression.?, ctx.params)) return null;
        }

        const residual = ctx.residual;
        var b = std.ArrayList(u8){};
        defer b.deinit(alloc);
        try ap(&b, alloc, "if ({s} <= {d}) return {s};\n", .{ n, g.boundary, n });
        try ap(&b, alloc, "if ({s} <= {d}) {{\n", .{ n, FIB_MAX });
        try b.appendSlice(alloc, "    var __a: i64 = 0;\n    var __b: i64 = 1;\n");
        try ap(&b, alloc, "    const __nu: u64 = @bitCast({s});\n", .{n});
        try b.appendSlice(alloc, "    var __p: u64 = @as(u64, 1) << @as(u6, @intCast(63 - @clz(__nu)));\n");
        try b.appendSlice(alloc, "    while (__p != 0) : (__p >>= 1) {\n");
        try b.appendSlice(alloc, "        const __c = __a * (__b + (__b - __a));\n");
        try b.appendSlice(alloc, "        const __d = __a * __a + __b * __b;\n");
        try ap(&b, alloc, "        if (({s} & @as(i64, @intCast(__p))) != 0) {{\n", .{n});
        try b.appendSlice(alloc, "            __a = __d;\n            __b = __c + __d;\n        } else {\n            __a = __c;\n            __b = __d;\n        }\n    }\n    return __a;\n}\n");
        // n == 92 is the last i64-exact fib (7540113804746346429); doubling
        // would compute fib(93) and overflow where the original does not.
        // n >= 93 leaves fib outside i64 — the original diverges (exponential
        // tree), so the residual's self-call divergence is equivalent.
        try ap(&b, alloc, "if ({s} == 92) return 7540113804746346429;\n", .{n});
        try ap(&b, alloc, "return {s};\n", .{residual});
        return try b.toOwnedSlice(alloc);
    }

    /// B2 entry: head guard is `k == 0` (kind eq, boundary 0). Then verify inner
    /// `k == n`, calls, produce — and emit.
    fn tryBinomEntry(ctx: *const Ctx, g: Guard, then_leaf: []const u8, else_c: *const ast.Continuation) !?[]const u8 {
        if (ctx.c.debug) std.debug.print("collapse: tryBinom entered\n", .{});
        if (ctx.params.len != 2) return null;
        if (g.kind != .eq or g.boundary != 0) return null;
        if (!leafIsLiteral(then_leaf, "1")) return null;
        const alloc = ctx.c.allocator;
        const k = g.param;
        const n = if (std.mem.eql(u8, ctx.params[0], k)) ctx.params[1] else ctx.params[0];
        if (std.mem.eql(u8, n, k)) return null;

        if (!contClean(else_c)) return null;
        const inner = ifNodeOf(else_c) orelse return null;
        const icond = ifCondExpr(inner) orelse return null;
        const iu = ungroup(icond);
        const ib = switch (iu.node) {
            .binary => |bb| bb,
            else => return null,
        };
        if (ib.op != .equal) return null;
        const lparam = paramOf(ib.left, ctx.params) orelse return null;
        const rparam = paramOf(ib.right, ctx.params) orelse return null;
        if (!((std.mem.eql(u8, lparam, k) and std.mem.eql(u8, rparam, n)) or
              (std.mem.eql(u8, lparam, n) and std.mem.eql(u8, rparam, k)))) return null;

        if (else_c.continuations.len != 2) return null;
        const then2 = findBranch(else_c.continuations, "then") orelse return null;
        const else2 = findBranch(else_c.continuations, "else") orelse return null;
        if (!contClean(then2) or !contClean(else2)) return null;
        if (then2.continuations.len != 0) return null;
        if (!leafIsLiteral(leafText(then2) orelse return null, "1")) return null;

        const inv1 = selfCallOf(else2, ctx.impl_of) orelse return null;
        if (!rbOk(inv1)) return null;
        if (else2.continuations.len != 1) return null;
        const link1 = &else2.continuations[0];
        if (!contClean(link1)) return null;
        if (link1.branch.len != 0) return null;
        const inv2 = selfCallOf(link1, ctx.impl_of) orelse return null;
        if (!rbOk(inv2)) return null;
        if (link1.continuations.len != 1) return null;
        const link2 = &link1.continuations[0];
        if (!contClean(link2)) return null;
        if (link2.branch.len != 0 or link2.continuations.len != 0) return null;
        const prod = leafText(link2) orelse return null;

        if (!argsCoverParams(inv1, ctx.params)) return null;
        if (!argsCoverParams(inv2, ctx.params)) return null;

        const rb1 = inv1.return_binding.?;
        const rb2 = inv2.return_binding.?;
        var km1_count: usize = 0;
        var kpun_count: usize = 0;
        for ([_]*const ast.Invocation{ inv1, inv2 }) |inv| {
            const an = argForParam(inv, n).?;
            if ((matchDecrement(an.parsed_expression.?, n) orelse return null) != 1) return null;
            const ke = argForParam(inv, k).?.parsed_expression.?;
            if (matchDecrement(ke, k)) |kd| {
                if (kd != 1) return null;
                km1_count += 1;
            } else if (exprIsIdent(ke, k)) {
                kpun_count += 1;
            } else return null;
        }
        if (km1_count != 1 or kpun_count != 1) return null;

        if (!leafIsSumOf(prod, rb1, rb2)) return null;

        for (inv1.args) |a| {
            if (!exprAdmitted(a.parsed_expression.?, ctx.params)) return null;
        }
        for (inv2.args) |a| {
            if (!exprAdmitted(a.parsed_expression.?, ctx.params)) return null;
        }

        const residual = ctx.residual;
        var b = std.ArrayList(u8){};
        defer b.deinit(alloc);
        try ap(&b, alloc, "if ({s} == 0) return 1;\n", .{k});
        try ap(&b, alloc, "if ({s} == {s}) return 1;\n", .{ k, n });
        try ap(&b, alloc, "if ({s} < 0 or {s} < 0 or {s} > {s}) return {s};\n", .{ n, k, k, n, residual });
        try ap(&b, alloc, "const __kk = @min({s}, {s} - {s});\n", .{ k, n, k });
        try b.appendSlice(alloc, "var __r: i64 = 1;\n");
        try b.appendSlice(alloc, "for (0..@as(usize, @intCast(__kk))) |__iu| {\n");
        try b.appendSlice(alloc, "    const __i: i64 = @intCast(__iu);\n");
        try ap(&b, alloc, "    __r = @import(\"std\").math.mul(i64, __r, {s} - __kk + __i + 1) catch return {s};\n", .{ n, residual });
        try b.appendSlice(alloc, "    __r = @divTrunc(__r, __i + 1);\n}\n    return __r;\n");
        return try b.toOwnedSlice(alloc);
    }

    /// A custody kit — a module whose canon strings back a ring C3 can
    /// fast-double over. The phantom tag the custody params share selects the
    /// row (`custodyEligible` already requires one tag across params+return).
    /// `.mod`/`.t_*` are the .k spellings the matcher walks; the emitted body
    /// calls the kit's value-level zig through `koru_std.<zns>` — every kit
    /// exposes the same contract names there:
    ///   kitFree(s)              custody-string free
    ///   kitParse(alloc, s) !V   canon decode
    ///   kitFromInt(alloc,i64)!V small-int mint
    ///   kitMul/kitAdd(alloc,*V,*V) !V
    ///   kitNeg(*V)              in-place negate
    ///   kitDeinit(*V)           value teardown
    ///   kitEmit(alloc,*V)![]u8  canon encode
    /// The collapsed event's caller must itself invoke the kit's tors to mint
    /// operands — that invocation is what lands `koru_std.<zns>` in the
    /// emitted file (module zig is dead-stripped without a tor call).
    const CustodyKit = struct {
        tag: []const u8,
        mod: []const u8,
        zns: []const u8,
        family: []const u8,
        t_free: []const u8,
        t_dup: []const u8,
        t_from_int: []const u8,
        t_mul: []const u8,
        t_add: []const u8,
    };

    const CUSTODY_KITS = [_]CustodyKit{
        .{ .tag = "std.num:exact", .mod = "std.num", .zns = "koru_num", .family = "c3_numacc",
            .t_free = "free", .t_dup = "dup", .t_from_int = "from-int", .t_mul = "mul", .t_add = "add" },
        .{ .tag = "std.rational:rational", .mod = "std.rational", .zns = "koru_rational", .family = "c3_ratacc",
            .t_free = "free", .t_dup = "dup", .t_from_int = "from-int", .t_mul = "mul", .t_add = "add" },
    };

    fn kitForTag(tag: []const u8) ?*const CustodyKit {
        for (&CUSTODY_KITS) |*k| {
            if (std.mem.eql(u8, k.tag, tag)) return k;
        }
        return null;
    }

    /// Kit-templated emission for the long literal blocks — `KNS` stands in
    /// for the kit's zig namespace so `while`/`for` braces stay literal (fmt
    /// can't carry them). One substitution point for the whole ring contract.
    fn apKit(
        buf: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        kit: *const CustodyKit,
        comptime text: []const u8,
    ) !void {
        const zns_full = try std.fmt.allocPrint(alloc, "koru_std.{s}", .{kit.zns});
        defer alloc.free(zns_full);
        const em = try std.mem.replaceOwned(u8, alloc, text, "KNS", zns_full);
        defer alloc.free(em);
        try buf.appendSlice(alloc, em);
    }

    /// C3 — custody-kit linear recurrence (numacc over Dec, ratacc over Rat):
    ///   T(m, a, b, c*) = if (m <= B) then-arm [kit free steps] -> a
    ///                    else |> kit dup(b): d |> [dup(c) | from-int | mul]*
    ///                         |> kit add(term_p, term_q): s
    ///                         |> T(m-1, a: d.f2, b: s, c*): r -> r
    /// The step is the general two-term linear recurrence
    ///   x_{i+1} = p*x_i + q*x_{i-1}
    /// — fib is p=q=1 (the bare add), Pell p=2 q=1, coefficients arriving
    /// either as dup'd custody params or from-int literals. Collapse parses
    /// the operands (and coefficient params) once, fast-doubles the
    /// fundamental sequence u_0=0,u_1=1 of M=[[0,1],[q,p]] on Dec limbs,
    /// combines x_n = a*(u_{n+1} - p*u_n) + b*u_n, formats once: the O(n)
    /// string round-trips become O(log n) limb passes whose cost tracks the
    /// value's width, not n. Dups are custody plumbing — erased, not
    /// lowered. Emitted body runs inside main_module.<T>_event.handler;
    /// the kit helpers it calls live in koru_std.<zns>, same file.
    /// Where a step's coefficient comes from: implicit 1 (bare state
    /// operand), a from-int literal minted in-chain, or a dup'd half of a
    /// carried coefficient param (index into CustodyInfo.coeffs).
    const Coeff = union(enum) {
        one,
        lit: i64,
        param: usize,
    };

    fn tryCustodyKit(
        ctx: *const Ctx,
        ci: CustodyInfo,
        kit: *const CustodyKit,
        g: Guard,
        then_c: *const ast.Continuation,
        else_c: *const ast.Continuation,
    ) !?[]const u8 {
        if (ctx.c.debug) std.debug.print("collapse: tryCustodyKit({s}) entered\n", .{kit.tag});
        if (!std.mem.eql(u8, g.param, ci.measure)) return null;
        if (g.kind != .le) return null;

        // then arm: zero+ `std.num:free(<custody param>)` steps, leaf `a`.
        // The frees are replayed verbatim in the base arm so a source that
        // leaves a param unfreed keeps its leak.
        var freed = std.ArrayList([]const u8){};
        defer freed.deinit(ctx.c.allocator);
        var cur = then_c;
        while (callOnPath(cur, kit.mod, kit.t_free)) |finv| {
            if (finv.return_binding != null) return null;
            if (finv.args.len != 1) return null;
            const farg = finv.args[0];
            const fexpr = farg.parsed_expression orelse return null;
            const fname = identName(fexpr) orelse return null;
            if (!ci.isCustody(fname)) return null;
            if (freed.items.len >= 2 + ci.n_coeffs) return null;
            freed.append(ctx.c.allocator, fname) catch return null;
            const nxt = linkCont(cur) orelse return null;
            cur = nxt;
        }
        if (cur.continuations.len != 0) return null;
        const tleaf = leafText(cur) orelse return null;
        if (!leafIsIdent(tleaf, ci.a)) return null;

        // else arm: dup(b) -> [dup(coeff)]* -> [from-int | mul]* -> add -> self-call -> produce.
        // The step is the general two-term recurrence x_{i+1} = p*x_i + q*x_{i-1}:
        // each add arg is a state operand (a, or a dup_b half) optionally
        // wrapped in a mul against a coefficient operand (coeff-param dup half,
        // or a from-int literal). Bare state operand = coefficient 1.
        if (!contClean(else_c)) return null;
        const dinv = callOnPath(else_c, kit.mod, kit.t_dup) orelse return null;
        if (!rbOk(dinv)) return null;
        if (dinv.args.len != 1) return null;
        const darg = dinv.args[0];
        const dexpr = darg.parsed_expression orelse return null;
        const dup_src = identName(dexpr) orelse return null;
        if (!std.mem.eql(u8, dup_src, ci.b)) return null;
        const dup_rb = dinv.return_binding.?;

        if (ctx.c.debug) std.debug.print("c3: b dup ok\n", .{});

        // coefficient-param dups — each coeff param dup'd at most once.
        cur = linkCont(else_c) orelse return null;
        var coeff_dup: [4]?[]const u8 = .{ null, null, null, null };
        var coeff_half: [4]?[]const u8 = .{ null, null, null, null };
        while (callOnPath(cur, kit.mod, kit.t_dup)) |cinv| {
            if (!rbOk(cinv)) return null;
            if (cinv.args.len != 1) return null;
            const cexpr = cinv.args[0].parsed_expression orelse return null;
            const cname = identName(cexpr) orelse return null;
            const cidx = ci.coeffIndex(cname) orelse return null;
            if (coeff_dup[cidx] != null) return null;
            coeff_dup[cidx] = cinv.return_binding.?;
            cur = linkCont(cur) orelse return null;
        }

        // from-int mints and step muls — each mint must feed exactly one mul;
        // a binding that shadows a custody param would confuse the step
        // classification below, so name-colliding chains refuse.
        if (ctx.c.debug) std.debug.print("c3: coeff dups ok\n", .{});
        var lit_bind: [4][]const u8 = undefined;
        var lit_val: [4]i64 = undefined;
        var lit_used: [4]bool = .{ false, false, false, false };
        var n_lits: usize = 0;
        var muls: [2]*const ast.Invocation = undefined;
        var mul_used: [2]bool = .{ false, false };
        var n_muls: usize = 0;
        while (true) {
            if (callOnPath(cur, kit.mod, kit.t_from_int)) |finv| {
                if (!rbOk(finv)) return null;
                if (finv.args.len != 1) return null;
                const fexpr = finv.args[0].parsed_expression orelse return null;
                const v = litNumber(fexpr) orelse return null;
                const rb = finv.return_binding.?;
                if (ci.isCustody(rb)) return null;
                for (lit_bind[0..n_lits]) |lb| {
                    if (std.mem.eql(u8, rb, lb)) return null;
                }
                for (muls[0..n_muls]) |m| {
                    if (std.mem.eql(u8, rb, m.return_binding.?)) return null;
                }
                if (n_lits >= 4) return null;
                lit_bind[n_lits] = rb;
                lit_val[n_lits] = v;
                n_lits += 1;
                cur = linkCont(cur) orelse return null;
                continue;
            }
            if (callOnPath(cur, kit.mod, kit.t_mul)) |minv| {
                if (!rbOk(minv)) return null;
                if (minv.args.len != 2) return null;
                const mrb = minv.return_binding.?;
                if (ci.isCustody(mrb)) return null;
                for (lit_bind[0..n_lits]) |lb| {
                    if (std.mem.eql(u8, mrb, lb)) return null;
                }
                for (muls[0..n_muls]) |m| {
                    if (std.mem.eql(u8, mrb, m.return_binding.?)) return null;
                }
                if (n_muls >= 2) return null;
                muls[n_muls] = minv;
                n_muls += 1;
                if (ctx.c.debug) std.debug.print("c3: mul collected {s}\n", .{mrb});
                cur = linkCont(cur) orelse return null;
                continue;
            }
            if (ctx.c.debug) std.debug.print("c3: loop done n_muls={d} n_lits={d}\n", .{ n_muls, n_lits });
            break;
        }

        const ainv = callOnPath(cur, kit.mod, kit.t_add) orelse { if (ctx.c.debug) std.debug.print("c3: no add\n", .{}); return null; };
        if (!rbOk(ainv)) return null;
        if (ainv.args.len != 2) return null;
        const add_rb = ainv.return_binding.?;
        var coeff_p: Coeff = .one;
        var coeff_q: Coeff = .one;
        var state_half_used: ?[]const u8 = null;
        var saw_p = false;
        var saw_q = false;
        if (ctx.c.debug) std.debug.print("c3: add found\n", .{});
        for (ainv.args) |a| {
            const e = a.parsed_expression orelse return null;
            var is_p = false;
            var cf: Coeff = .one;
            if (fieldAccessOf(e)) |fa| {
                if (!exprIsIdent(fa.object, dup_rb)) return null;
                is_p = true;
                if (state_half_used != null) return null;
                state_half_used = fa.field;
            } else if (identName(e)) |id| {
                if (std.mem.eql(u8, id, ci.a)) {
                    is_p = false;
                } else {
                    // a mul binding — one state operand, one coefficient operand
                    var midx: ?usize = null;
                    for (muls[0..n_muls], 0..) |m, i| {
                        if (std.mem.eql(u8, m.return_binding.?, id)) midx = i;
                    }
                    const mi = midx orelse return null;
                    if (mul_used[mi]) return null;
                    mul_used[mi] = true;
                    var saw_state = false;
                    var saw_coeff = false;
                    for (muls[mi].args) |marg| {
                        const me = marg.parsed_expression orelse return null;
                        if (identName(me)) |mid| {
                            if (std.mem.eql(u8, mid, ci.a)) {
                                if (saw_state) return null;
                                saw_state = true;
                                continue;
                            }
                            var lit_hit = false;
                            for (lit_bind[0..n_lits], 0..) |lb, j| {
                                if (std.mem.eql(u8, mid, lb)) {
                                    if (saw_coeff) return null;
                                    cf = .{ .lit = lit_val[j] };
                                    lit_used[j] = true;
                                    lit_hit = true;
                                    saw_coeff = true;
                                    break;
                                }
                            }
                            if (!lit_hit) return null;
                        } else if (fieldAccessOf(me)) |fa2| {
                            if (exprIsIdent(fa2.object, dup_rb)) {
                                if (saw_state) return null;
                                is_p = true;
                                if (state_half_used != null) return null;
                                state_half_used = fa2.field;
                                saw_state = true;
                                continue;
                            }
                            var chit = false;
                            for (coeff_dup, 0..) |cd, i| {
                                if (cd) |rb| {
                                    if (exprIsIdent(fa2.object, rb)) {
                                        if (saw_coeff) return null;
                                        cf = .{ .param = i };
                                        if (coeff_half[i] != null) return null;
                                        coeff_half[i] = fa2.field;
                                        chit = true;
                                        saw_coeff = true;
                                        break;
                                    }
                                }
                            }
                            if (!chit) return null;
                        } else return null;
                    }
                    if (!saw_state or !saw_coeff) return null;
                }
            } else return null;
            if (is_p) {
                if (saw_p) return null;
                saw_p = true;
                coeff_p = cf;
            } else {
                if (saw_q) return null;
                saw_q = true;
                coeff_q = cf;
            }
        }
        if (!saw_p or !saw_q) return null;
        for (lit_used[0..n_lits]) |u| {
            if (!u) return null;
        }
        for (mul_used[0..n_muls]) |u| {
            if (!u) return null;
        }
        if (state_half_used == null) return null;

        if (ctx.c.debug) std.debug.print("c3: add ok\n", .{});
        cur = linkCont(cur) orelse return null;
        const sinv = selfCallOf(cur, ctx.impl_of) orelse return null;
        if (!rbOk(sinv)) return null;
        const self_rb = sinv.return_binding.?;
        if (!argsCoverParams(sinv, ctx.params)) return null;
        const dec = matchDecrement(argForParam(sinv, ci.measure).?.parsed_expression.?, ci.measure) orelse return null;
        if (dec != 1) return null;
        const aexpr = argForParam(sinv, ci.a).?.parsed_expression.?;
        const fa2 = fieldAccessOf(aexpr) orelse return null;
        if (!exprIsIdent(fa2.object, dup_rb)) return null;
        if (std.mem.eql(u8, fa2.field, state_half_used.?)) return null;
        const bexpr = argForParam(sinv, ci.b).?.parsed_expression.?;
        if (!exprIsIdent(bexpr, add_rb)) return null;
        // each coeff param: dup'd (coefficient — one half consumed by a mul,
        // the other carried here) or carried verbatim (unused — emitted body
        // frees it since the collapse never issues it onward).
        var carried_free = std.ArrayList([]const u8){};
        defer carried_free.deinit(ctx.c.allocator);
        for (0..ci.n_coeffs) |i| {
            const carg = argForParam(sinv, ci.coeffs[i]) orelse return null;
            const e2 = carg.parsed_expression orelse return null;
            if (coeff_dup[i]) |cd| {
                if (coeff_half[i] == null) return null;
                const fa3 = fieldAccessOf(e2) orelse return null;
                if (!exprIsIdent(fa3.object, cd)) return null;
                if (std.mem.eql(u8, fa3.field, coeff_half[i].?)) return null;
            } else {
                if (!exprIsIdent(e2, ci.coeffs[i])) return null;
                carried_free.append(ctx.c.allocator, ci.coeffs[i]) catch return null;
            }
        }

        if (ctx.c.debug) std.debug.print("c3: selfcall ok\n", .{});
        cur = linkCont(cur) orelse return null;
        if (cur.continuations.len != 0) return null;
        const prod = leafText(cur) orelse return null;
        if (!leafIsIdent(prod, self_rb)) return null;

        if (ctx.c.debug) std.debug.print("c3: match complete\n", .{});
        const alloc = ctx.c.allocator;
        var b = std.ArrayList(u8){};
        defer b.deinit(alloc);
        try ap(&b, alloc, "if ({s} <= {d}) {{\n", .{ ci.measure, g.boundary });
        for (freed.items) |fp| {
            try ap(&b, alloc, "    koru_std.{s}.kitFree({s});\n", .{ kit.zns, fp });
        }
        try ap(&b, alloc, "    return {s};\n}}\n", .{ci.a});
        try b.appendSlice(alloc, "const __ka = koru_allocator();\n");
        try ap(&b, alloc, "var __da = koru_std.{s}.kitParse(__ka, {s}) catch @panic(\"collapse c3: malformed operand\");\n", .{ kit.zns, ci.a });
        try ap(&b, alloc, "var __db = koru_std.{s}.kitParse(__ka, {s}) catch @panic(\"collapse c3: malformed operand\");\n", .{ kit.zns, ci.b });
        try ap(&b, alloc, "koru_std.{s}.kitFree({s});\nkoru_std.{s}.kitFree({s});\n", .{ kit.zns, ci.a, kit.zns, ci.b });
        // coefficient Decs — literal via decInit, param via decParse. A param
        // sourced for both p and q parses twice and frees once.
        for ([2]Coeff{ coeff_p, coeff_q }, [2][]const u8{ "__cp", "__cq" }) |cf, vn| {
            switch (cf) {
                .one => try ap(&b, alloc, "var {s} = koru_std.{s}.kitFromInt(__ka, 1) catch @panic(\"collapse c3: init\");\n", .{ vn, kit.zns }),
                .lit => |v| try ap(&b, alloc, "var {s} = koru_std.{s}.kitFromInt(__ka, {d}) catch @panic(\"collapse c3: init\");\n", .{ vn, kit.zns, v }),
                .param => |i| try ap(&b, alloc, "var {s} = koru_std.{s}.kitParse(__ka, {s}) catch @panic(\"collapse c3: malformed operand\");\n", .{ vn, kit.zns, ci.coeffs[i] }),
            }
        }
        var freed_coeff: [4][]const u8 = undefined;
        var n_freed: usize = 0;
        for ([2]Coeff{ coeff_p, coeff_q }) |cf| {
            if (cf == .param) {
                const nm = ci.coeffs[cf.param];
                var seen = false;
                for (freed_coeff[0..n_freed]) |f| {
                    if (std.mem.eql(u8, f, nm)) seen = true;
                }
                if (!seen) {
                    try ap(&b, alloc, "koru_std.{s}.kitFree({s});\n", .{ kit.zns, nm });
                    freed_coeff[n_freed] = nm;
                    n_freed += 1;
                }
            }
        }
        for (carried_free.items) |fp| {
            try ap(&b, alloc, "koru_std.{s}.kitFree({s});\n", .{ kit.zns, fp });
        }
        // else ran: m > B, so m - B >= 1. The recurrence x_{i+1} = p*x_i +
        // q*x_{i-1} is the companion matrix M = [[0,1],[q,p]] — its power
        // M^n = [[q*u_{n-1}, u_n],[...]] over the fundamental sequence
        // u_0=0, u_1=1, so x_n = a*(u_{n+1} - p*u_n) + b*u_n. The loop
        // fast-doubles (u_j, u_{j+1}) over the bits of the trip count:
        //   u_{2k}   = u_k*(2*u_{k+1} - p*u_k)
        //   u_{2k+1} = u_{k+1}^2 + q*u_k^2
        //   u_{2k+2} = p*u_{2k+1} + q*u_{2k}
        // O(log iters) decMul steps whose cost tracks the VALUE's limb
        // width, not the count. Bit-scan `while` (not `for`) — the trip
        // count is a bit-length, unknowable statically; same shape as B1.
        try ap(&b, alloc, "const __iters: u64 = @intCast({s} - {d});\n", .{ ci.measure, g.boundary });
        try apKit(&b, alloc, kit,
            "var __fk = KNS.kitFromInt(__ka, 0) catch @panic(\"collapse c3: init\");\n" ++
            "var __fk1 = KNS.kitFromInt(__ka, 1) catch @panic(\"collapse c3: init\");\n" ++
            "var __p: u64 = @as(u64, 1) << @as(u6, @intCast(63 - @clz(__iters)));\n" ++
            "while (__p != 0) : (__p >>= 1) {\n" ++
            "    var __pfk = KNS.kitMul(__ka, &__cp, &__fk) catch @panic(\"collapse c3: mul\");\n" ++
            "    var __two = KNS.kitAdd(__ka, &__fk1, &__fk1) catch @panic(\"collapse c3: add\");\n" ++
            "    KNS.kitNeg(&__pfk);\n" ++
            "    var __diff = KNS.kitAdd(__ka, &__two, &__pfk) catch @panic(\"collapse c3: add\");\n" ++
            "    KNS.kitDeinit(&__two);\n" ++
            "    KNS.kitDeinit(&__pfk);\n" ++
            "    var __c = KNS.kitMul(__ka, &__fk, &__diff) catch @panic(\"collapse c3: mul\");\n" ++
            "    KNS.kitDeinit(&__diff);\n" ++
            "    var __f2 = KNS.kitMul(__ka, &__fk, &__fk) catch @panic(\"collapse c3: mul\");\n" ++
            "    var __qf2 = KNS.kitMul(__ka, &__cq, &__f2) catch @panic(\"collapse c3: mul\");\n" ++
            "    KNS.kitDeinit(&__f2);\n" ++
            "    var __f12 = KNS.kitMul(__ka, &__fk1, &__fk1) catch @panic(\"collapse c3: mul\");\n" ++
            "    const __d = KNS.kitAdd(__ka, &__f12, &__qf2) catch @panic(\"collapse c3: add\");\n" ++
            "    KNS.kitDeinit(&__f12);\n" ++
            "    KNS.kitDeinit(&__qf2);\n" ++
            "    KNS.kitDeinit(&__fk);\n" ++
            "    KNS.kitDeinit(&__fk1);\n" ++
            "    if ((__iters & __p) != 0) {\n" ++
            "        var __pd = KNS.kitMul(__ka, &__cp, &__d) catch @panic(\"collapse c3: mul\");\n" ++
            "        var __qc = KNS.kitMul(__ka, &__cq, &__c) catch @panic(\"collapse c3: mul\");\n" ++
            "        const __e = KNS.kitAdd(__ka, &__pd, &__qc) catch @panic(\"collapse c3: add\");\n" ++
            "        KNS.kitDeinit(&__pd);\n" ++
            "        KNS.kitDeinit(&__qc);\n" ++
            "        KNS.kitDeinit(&__c);\n" ++
            "        __fk = __d;\n" ++
            "        __fk1 = __e;\n" ++
            "    } else {\n" ++
            "        __fk = __c;\n" ++
            "        __fk1 = __d;\n" ++
            "    }\n" ++
            "}\n");
        // result = a*(u_{n+1} - p*u_n) + b*u_n
        try apKit(&b, alloc, kit,
            "var __pfk2 = KNS.kitMul(__ka, &__cp, &__fk) catch @panic(\"collapse c3: mul\");\n" ++
            "KNS.kitNeg(&__pfk2);\n" ++
            "var __fm1 = KNS.kitAdd(__ka, &__fk1, &__pfk2) catch @panic(\"collapse c3: add\");\n" ++
            "KNS.kitDeinit(&__pfk2);\n" ++
            "var __t1 = KNS.kitMul(__ka, &__da, &__fm1) catch @panic(\"collapse c3: mul\");\n" ++
            "KNS.kitDeinit(&__fm1);\n" ++
            "var __t2 = KNS.kitMul(__ka, &__db, &__fk) catch @panic(\"collapse c3: mul\");\n" ++
            "var __res = KNS.kitAdd(__ka, &__t1, &__t2) catch @panic(\"collapse c3: add\");\n" ++
            "KNS.kitDeinit(&__t1);\n" ++
            "KNS.kitDeinit(&__t2);\n" ++
            "KNS.kitDeinit(&__da);\n" ++
            "KNS.kitDeinit(&__db);\n" ++
            "KNS.kitDeinit(&__fk);\n" ++
            "KNS.kitDeinit(&__fk1);\n" ++
            "KNS.kitDeinit(&__cp);\n" ++
            "KNS.kitDeinit(&__cq);\n" ++
            "const __rs = KNS.kitEmit(__ka, &__res) catch @panic(\"collapse c3: fmt\");\n" ++
            "KNS.kitDeinit(&__res);\n" ++
            "return __rs;\n");
        return try b.toOwnedSlice(alloc);
    }

    // ---------------- driver --------------------------------------------------

    fn findEventDecl(items: []ast.Item, path: *const ast.DottedPath) ?*ast.EventDecl {
        for (items) |*it| {
            switch (it.*) {
                .event_decl => |*e| {
                    if (pathsEqual(&e.path, path)) return e;
                },
                .module_decl => |*m| {
                    if (findEventDecl(@constCast(m.items), path)) |f| return f;
                },
                else => {},
            }
        }
        return null;
    }

    fn eventEligible(ev: *const ast.EventDecl) bool {
        const rt = ev.return_type orelse return false;
        if (!isIntType(rt)) return false;
        if (ev.return_phantom != null) return false;
        if (ev.branches.len != 0) return false;
        if (ev.input.fields.len == 0) return false;
        for (ev.input.fields) |f| {
            if (!isIntType(f.type)) return false;
            if (f.is_source or f.is_expression) return false;
            if (!zigNameOk(f.name)) return false;
        }
        if (ev.path.segments.len != 1) return false;
        return true;
    }

    /// Custody events — the C3 num-accumulator leg. Eligible shape:
    ///   T { m:int, a:string<!P>, b:string<!P>, c:string<!P>* } -> string<P!>
    /// The int-scalar gate refuses these outright; custodyEligible re-judges
    /// on the phantom fields. All custody params must consume the SAME tag
    /// (`<!P>`) and the return must issue it (`<P!>`) — a tor that produces a
    /// different family than it consumes is not the recurrence we recognize.
    /// The first two custody params are the accumulator pair; any further
    /// ones are coefficient/carried params (constant multipliers in the step,
    /// or params carried unchanged — the matcher sorts out which).
    const CustodyInfo = struct {
        measure: []const u8,
        a: []const u8,
        b: []const u8,
        coeffs: [4][]const u8,
        n_coeffs: usize,
        tag: []const u8,

        fn isCustody(self: CustodyInfo, name: []const u8) bool {
            if (std.mem.eql(u8, name, self.a) or std.mem.eql(u8, name, self.b)) return true;
            for (self.coeffs[0..self.n_coeffs]) |c| {
                if (std.mem.eql(u8, name, c)) return true;
            }
            return false;
        }

        fn coeffIndex(self: CustodyInfo, name: []const u8) ?usize {
            for (self.coeffs[0..self.n_coeffs], 0..) |c, i| {
                if (std.mem.eql(u8, name, c)) return i;
            }
            return null;
        }
    };

    fn custodyEligible(ev: *const ast.EventDecl) ?CustodyInfo {
        const rt = ev.return_type orelse return null;
        if (!std.mem.eql(u8, rt, "string")) return null;
        const rp = ev.return_phantom orelse return null;
        if (rp.len < 2 or rp[rp.len - 1] != '!') return null;
        if (ev.branches.len != 0) return null;
        if (ev.input.fields.len < 3 or ev.input.fields.len > 7) return null;
        if (ev.path.segments.len != 1) return null;
        var measure: ?[]const u8 = null;
        var cust: [6][]const u8 = undefined;
        var n_cust: usize = 0;
        var tag: ?[]const u8 = null;
        for (ev.input.fields) |f| {
            if (f.is_source or f.is_expression) return null;
            if (!zigNameOk(f.name)) return null;
            if (isIntType(f.type)) {
                // The loop emitted for this family computes `m - B` then
                // intCasts to usize — signed measures keep that well-formed
                // for any boundary literal.
                if (f.type[0] != 'i') return null;
                if (measure != null) return null;
                measure = f.name;
                continue;
            }
            if (!std.mem.eql(u8, f.type, "string")) return null;
            const ph = f.phantom orelse return null;
            if (ph.len < 3 or ph[0] != '!') return null;
            if (tag) |t| {
                if (!std.mem.eql(u8, t, ph[1..])) return null;
            } else tag = ph[1..];
            if (n_cust >= 6) return null;
            cust[n_cust] = f.name;
            n_cust += 1;
        }
        if (measure == null or n_cust < 2) return null;
        if (!std.mem.eql(u8, rp[0 .. rp.len - 1], tag.?)) return null;
        var ci = CustodyInfo{
            .measure = measure.?,
            .a = cust[0],
            .b = cust[1],
            .coeffs = undefined,
            .n_coeffs = n_cust - 2,
            .tag = tag.?,
        };
        for (cust[2..n_cust], 0..) |c, i| ci.coeffs[i] = c;
        return ci;
    }

    fn ifCondExpr(inv: *const ast.Invocation) ?*const ast.Expression {
        for (inv.args) |a| {
            if (a.parsed_expression) |e| return e;
        }
        return null;
    }

    fn refuse(c: *Collapse, comptime reason: []const u8) void {
        if (c.debug) std.debug.print("collapse: refuse {s}\n", .{reason});
    }

    fn tryFlow(flow: *ast.Flow, items: []ast.Item, c: *Collapse) void {
        const impl_of = flow.impl_of orelse {
            refuse(c, "no impl_of");
            return;
        };
        if (flow.inline_body != null or flow.preamble_code != null or
            flow.pre_label != null or flow.impl_variant != null)
        {
            refuse(c, "flow already transformed");
            return;
        }

        const ev = findEventDecl(items, &impl_of) orelse {
            refuse(c, "event decl not found");
            return;
        };
        var custody: ?CustodyInfo = null;
        if (!eventEligible(ev)) {
            custody = custodyEligible(ev) orelse {
                refuse(c, "event not eligible");
                return;
            };
        }

        var params_buf: [16][]const u8 = undefined;
        if (ev.input.fields.len == 0 or ev.input.fields.len > params_buf.len) {
            refuse(c, "param count out of range");
            return;
        }
        var params = params_buf[0..ev.input.fields.len];
        for (ev.input.fields, 0..) |f, i| params[i] = f.name;

        const head_node = flow.body.node orelse {
            refuse(c, "empty body node");
            return;
        };
        const head = switch (head_node) {
            .invocation => |inv| if (isIfKeyword(&inv.path)) inv else {
                refuse(c, "head not if");
                return;
            },
            else => {
                refuse(c, "head not invocation");
                return;
            },
        };
        const cond = ifCondExpr(&head) orelse {
            refuse(c, "if has no parsed condition");
            return;
        };
        const g = parseGuard(cond, params) orelse {
            refuse(c, "guard not param-vs-literal cmp");
            return;
        };
        if (c.debug) std.debug.print("collapse: candidate {s} guard {s} kind={s} L={d}\n", .{ lastSegment(&ev.path), g.param, @tagName(g.kind), g.boundary });

        if (flow.body.continuations.len != 2) {
            refuse(c, "continuations != 2");
            return;
        }
        const then_c = findBranch(flow.body.continuations, "then") orelse {
            refuse(c, "no then branch");
            return;
        };
        const else_c = findBranch(flow.body.continuations, "else") orelse {
            refuse(c, "no else branch");
            return;
        };
        if (!contClean(then_c) or !contClean(else_c)) {
            refuse(c, "continuation not clean");
            return;
        }
        var then_leaf: []const u8 = "";
        if (custody == null) {
            if (then_c.continuations.len != 0) {
                refuse(c, "then arm not leaf");
                return;
            }
            then_leaf = leafText(then_c) orelse {
                refuse(c, "then leaf no text");
                return;
            };
        }

        // Event names may be kebab-case (`pow-mod`, `loop-k`); the emitter
        // mangles `-` → `_` for Zig idents (writeMangledSeg), so the residual
        // spelling must too — `main_module.pow-mod_event` parses as subtraction.
        const ev_raw = lastSegment(&ev.path);
        var ev_name_buf: [128]u8 = undefined;
        if (ev_raw.len > ev_name_buf.len) return;
        for (ev_raw, 0..) |ch, i| ev_name_buf[i] = if (ch == '-') '_' else ch;
        const ev_name = ev_name_buf[0..ev_raw.len];
        if (!zigNameOk(ev_name)) return;
        var rb = std.ArrayList(u8){};
        defer rb.deinit(c.allocator);
        rb.appendSlice(c.allocator, "main_module.") catch return;
        rb.appendSlice(c.allocator, ev_name) catch return;
        rb.appendSlice(c.allocator, "_event.handler(.{") catch return;
        for (params, 0..) |p, i| {
            if (i > 0) rb.appendSlice(c.allocator, ", ") catch return;
            rb.append(c.allocator, '.') catch return;
            rb.appendSlice(c.allocator, p) catch return;
            rb.appendSlice(c.allocator, " = ") catch return;
            rb.appendSlice(c.allocator, p) catch return;
        }
        rb.appendSlice(c.allocator, " })") catch return;
        const residual = rb.items;

        const ctx = Ctx{
            .c = c,
            .params = params,
            .impl_of = &impl_of,
            .residual = residual,
        };

        if (c.debug) std.debug.print("collapse: dispatch matchers\n", .{});
        if (custody) |ci| {
            if (kitForTag(ci.tag)) |kit| {
                if (tryCustodyKit(&ctx, ci, kit, g, then_c, else_c) catch return) |body| {
                    setBody(flow, c, kit.family, body);
                }
            }
            return;
        }
        if (tryR1(&ctx, g, then_leaf, else_c) catch return) |body| {
            setBody(flow, c, "r1", body);
            return;
        }
        if (tryR2(&ctx, g, then_leaf, else_c) catch return) |body| {
            setBody(flow, c, "r2", body);
            return;
        }
        if (tryFib(&ctx, g, then_leaf, else_c) catch return) |body| {
            setBody(flow, c, "b1_fib", body);
            return;
        }
        if (tryBinomEntry(&ctx, g, then_leaf, else_c) catch return) |body| {
            setBody(flow, c, "b2_binom", body);
            return;
        }
    }

    fn runItems(items: []ast.Item, c: *Collapse) void {
        for (items) |*it| {
            switch (it.*) {
                .flow => |*f| tryFlow(f, items, c),
                .module_decl => |*m| runItems(@constCast(m.items), c),
                else => {},
            }
        }
    }
};
