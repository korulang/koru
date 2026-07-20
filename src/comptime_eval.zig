const std = @import("std");
const ast = @import("ast");
const expression_parser = @import("expression_parser");

/// Comptime Koru evaluator — the expression core.
///
/// This is the interpreter the comptime-interpreter vision names
/// (docs/comptime_interpreter_vision.md, docs/comptime_core_ast_inventory.md):
/// a fresh tree-walking evaluator that EXECUTES the pure subset of Koru over
/// the AST the backend already holds. It is a sibling of the pipeline passes,
/// optimized for completeness and correctness — never a budget, never a wire,
/// never host-text output. Its results are Values (spliced as literals) or,
/// in later rungs, Koru AST fragments (spliced as program).
///
/// Rung one: evaluate ast.Expression trees (the ExpressionParser output) over
/// an environment. Flow walking, structured-node interpretation (foreach/
/// conditional/assignment/#loop) and the source-time call bridge build on top.
///
/// Allocation contract: everything is allocated from the caller's allocator
/// and never freed here — the pipeline runs on arenas (context_create), and
/// the evaluator follows that convention.
///
/// Failure contract: every EvalError is accompanied by a diagnostic on the
/// Evaluator naming exactly what could not be evaluated and why, so the
/// koru-level error the pipeline reports can guide the user (or us) to the
/// wall. No silent fallbacks: anything unsupported is a loud error, never an
/// approximation.
pub const EvalError = error{
    UnknownIdentifier,
    UnknownField,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    TypeMismatch,
    DivisionByZero,
    IndexOutOfBounds,
    InvalidLiteral,
    OutOfMemory,
};

/// A comptime value. The `fragment` variant is declared now because the
/// multi-level design requires AST to be a first-class value (metaprograms
/// return program); rung one never produces it.
pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    array: []Value,
    cell: *Cell,
    fragment: Fragment,

    pub fn expectInt(self: Value) EvalError!i64 {
        return switch (self) {
            .int => |i| i,
            else => error.TypeMismatch,
        };
    }

    pub fn expectBool(self: Value) EvalError!bool {
        return switch (self) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .boolean => |b| try writer.print("{}", .{b}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .array => |a| {
                try writer.writeAll("[");
                for (a, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.format(writer);
                }
                try writer.writeAll("]");
            },
            .cell => |c| {
                try writer.writeAll("{ ");
                var it = c.fields.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try writer.writeAll(", ");
                    first = false;
                    try writer.print("{s}: ", .{entry.key_ptr.*});
                    try entry.value_ptr.format(writer);
                }
                try writer.writeAll(" }");
            },
            .fragment => try writer.writeAll("<ast fragment>"),
        }
    }
};

/// A mutable record value — the capture cell, an event payload, a struct.
/// Held by pointer inside Value so writes are visible through every binding.
pub const Cell = struct {
    fields: std.StringArrayHashMapUnmanaged(Value) = .{},

    pub fn get(self: *const Cell, name: []const u8) ?Value {
        return self.fields.get(name);
    }

    pub fn put(self: *Cell, allocator: std.mem.Allocator, name: []const u8, value: Value) EvalError!void {
        self.fields.put(allocator, name, value) catch return error.OutOfMemory;
    }
};

/// AST as data — the quote form. Grows variants as metaprograms need them.
pub const Fragment = union(enum) {
    item: *const ast.Item,
    node: *const ast.Node,
};

/// Lexical environment: a chain of scopes (event args, loop vars, the cell).
pub const Env = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringArrayHashMapUnmanaged(Value) = .{},
    parent: ?*Env = null,

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{ .allocator = allocator };
    }

    pub fn child(self: *Env) Env {
        return .{ .allocator = self.allocator, .parent = self };
    }

    pub fn bind(self: *Env, name: []const u8, value: Value) EvalError!void {
        self.bindings.put(self.allocator, name, value) catch return error.OutOfMemory;
    }

    pub fn lookup(self: *const Env, name: []const u8) ?Value {
        var env: ?*const Env = self;
        while (env) |e| : (env = e.parent) {
            if (e.bindings.get(name)) |v| return v;
        }
        return null;
    }
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    /// Set on every error: names exactly what failed. The pipeline turns this
    /// into the koru-level diagnostic; it is never optional information.
    diag: []const u8 = "",
    /// The Stage A-generated dispatch table (THE THUNK LAW). Empty until the
    /// pipeline wires it in; resolution falls through to subflow/bare-return.
    thunks: []const Thunk = &.{},

    pub fn init(allocator: std.mem.Allocator) Evaluator {
        return .{ .allocator = allocator };
    }

    fn fail(self: *Evaluator, err: EvalError, comptime fmt: []const u8, args: anytype) EvalError {
        self.diag = std.fmt.allocPrint(self.allocator, fmt, args) catch "diagnostic allocation failed";
        return err;
    }

    pub fn evalExpr(self: *Evaluator, env: *Env, expr: *const ast.Expression) EvalError!Value {
        return self.evalNode(env, &expr.node);
    }

    fn evalNode(self: *Evaluator, env: *Env, node: *const ast.ExprNode) EvalError!Value {
        switch (node.*) {
            .literal => |lit| return self.evalLiteral(lit),
            .identifier => |name| {
                return env.lookup(name) orelse
                    self.fail(error.UnknownIdentifier, "comptime evaluation: `{s}` is not bound in this scope", .{name});
            },
            .binary => |bin| return self.evalBinary(env, bin),
            .unary => |un| {
                const operand = try self.evalNode(env, &un.operand.node);
                return switch (un.op) {
                    .not => .{ .boolean = !(try operand.expectBool()) },
                    .negate => switch (operand) {
                        .int => |i| .{ .int = -i },
                        .float => |f| .{ .float = -f },
                        else => self.fail(error.TypeMismatch, "comptime evaluation: unary `-` needs a number", .{}),
                    },
                };
            },
            .field_access => |fa| {
                const object = try self.evalNode(env, &fa.object.node);
                switch (object) {
                    .cell => |cell| {
                        return cell.get(fa.field) orelse
                            self.fail(error.UnknownField, "comptime evaluation: no field `{s}` on cell", .{fa.field});
                    },
                    else => return self.fail(error.TypeMismatch, "comptime evaluation: `.{s}` needs a cell/struct value", .{fa.field}),
                }
            },
            .grouped => |inner| return self.evalNode(env, &inner.node),
            .builtin_call => |bc| return self.evalBuiltin(env, bc),
            .array_index => |ai| {
                const object = try self.evalNode(env, &ai.object.node);
                const index_value = try self.evalNode(env, &ai.index.node);
                const index = try index_value.expectInt();
                switch (object) {
                    .array => |items| {
                        if (index < 0 or index >= items.len)
                            return self.fail(error.IndexOutOfBounds, "comptime evaluation: index {d} out of bounds for array of length {d}", .{ index, items.len });
                        return items[@intCast(index)];
                    },
                    else => return self.fail(error.TypeMismatch, "comptime evaluation: indexing needs an array value", .{}),
                }
            },
            .conditional => |cond| {
                const condition = try self.evalNode(env, &cond.condition.node);
                return if (try condition.expectBool())
                    self.evalNode(env, &cond.then_expr.node)
                else
                    self.evalNode(env, &cond.else_expr.node);
            },
            .function_call => {
                // The source-time call bridge is a later rung; until it lands
                // this is a named wall, never a guess.
                return self.fail(error.UnsupportedConstruct, "comptime evaluation: function calls need the source-time call bridge (not built yet)", .{});
            },
        }
    }

    fn evalLiteral(self: *Evaluator, lit: ast.Literal) EvalError!Value {
        switch (lit) {
            .number => |text| {
                if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .int = i } else |_| {}
                if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
                return self.fail(error.InvalidLiteral, "comptime evaluation: `{s}` is not a number the evaluator understands", .{text});
            },
            .string => |text| {
                // The parser may or may not keep the surrounding quotes; store bare.
                const bare = if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
                    text[1 .. text.len - 1]
                else
                    text;
                return .{ .string = bare };
            },
            .boolean => |b| return .{ .boolean = b },
        }
    }

    fn evalBinary(self: *Evaluator, env: *Env, bin: ast.BinaryOp) EvalError!Value {
        // Short-circuit forms first: the right side must not evaluate.
        switch (bin.op) {
            .and_op => {
                const left = try self.evalNode(env, &bin.left.node);
                if (!(try left.expectBool())) return .{ .boolean = false };
                const right = try self.evalNode(env, &bin.right.node);
                return .{ .boolean = try right.expectBool() };
            },
            .or_op => {
                const left = try self.evalNode(env, &bin.left.node);
                if (try left.expectBool()) return .{ .boolean = true };
                const right = try self.evalNode(env, &bin.right.node);
                return .{ .boolean = try right.expectBool() };
            },
            else => {},
        }

        const left = try self.evalNode(env, &bin.left.node);
        const right = try self.evalNode(env, &bin.right.node);

        if (bin.op == .string_concat) {
            const ls = switch (left) {
                .string => |s| s,
                else => return self.fail(error.TypeMismatch, "comptime evaluation: `++` needs strings", .{}),
            };
            const rs = switch (right) {
                .string => |s| s,
                else => return self.fail(error.TypeMismatch, "comptime evaluation: `++` needs strings", .{}),
            };
            const joined = std.mem.concat(self.allocator, u8, &.{ ls, rs }) catch return error.OutOfMemory;
            return .{ .string = joined };
        }

        // Numeric tower: int op int stays int; any float promotes both.
        if (left == .float or right == .float) {
            const lf = try self.asFloat(left);
            const rf = try self.asFloat(right);
            return switch (bin.op) {
                .add => .{ .float = lf + rf },
                .subtract => .{ .float = lf - rf },
                .multiply => .{ .float = lf * rf },
                .divide => .{ .float = lf / rf },
                .modulo => .{ .float = @rem(lf, rf) },
                .equal => .{ .boolean = lf == rf },
                .not_equal => .{ .boolean = lf != rf },
                .less => .{ .boolean = lf < rf },
                .less_equal => .{ .boolean = lf <= rf },
                .greater => .{ .boolean = lf > rf },
                .greater_equal => .{ .boolean = lf >= rf },
                else => unreachable,
            };
        }

        if (left == .int and right == .int) {
            const li = left.int;
            const ri = right.int;
            return switch (bin.op) {
                .add => .{ .int = li + ri },
                .subtract => .{ .int = li - ri },
                .multiply => .{ .int = li * ri },
                // Truncating division and C-style remainder: matches what the
                // compiled kernels use (@divTrunc/@rem — the C-parity choice
                // from the expression-layer work).
                .divide => if (ri == 0)
                    self.fail(error.DivisionByZero, "comptime evaluation: division by zero", .{})
                else
                    .{ .int = @divTrunc(li, ri) },
                .modulo => if (ri == 0)
                    self.fail(error.DivisionByZero, "comptime evaluation: remainder by zero", .{})
                else
                    .{ .int = @rem(li, ri) },
                .equal => .{ .boolean = li == ri },
                .not_equal => .{ .boolean = li != ri },
                .less => .{ .boolean = li < ri },
                .less_equal => .{ .boolean = li <= ri },
                .greater => .{ .boolean = li > ri },
                .greater_equal => .{ .boolean = li >= ri },
                else => unreachable,
            };
        }

        if (left == .boolean and right == .boolean) {
            return switch (bin.op) {
                .equal => .{ .boolean = left.boolean == right.boolean },
                .not_equal => .{ .boolean = left.boolean != right.boolean },
                else => self.fail(error.TypeMismatch, "comptime evaluation: `{s}` is not defined on booleans", .{@tagName(bin.op)}),
            };
        }

        if (left == .string and right == .string) {
            return switch (bin.op) {
                .equal => .{ .boolean = std.mem.eql(u8, left.string, right.string) },
                .not_equal => .{ .boolean = !std.mem.eql(u8, left.string, right.string) },
                else => self.fail(error.TypeMismatch, "comptime evaluation: `{s}` is not defined on strings", .{@tagName(bin.op)}),
            };
        }

        return self.fail(error.TypeMismatch, "comptime evaluation: `{s}` got mismatched operand types", .{@tagName(bin.op)});
    }

    fn asFloat(self: *Evaluator, value: Value) EvalError!f64 {
        return switch (value) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            else => self.fail(error.TypeMismatch, "comptime evaluation: expected a number", .{}),
        };
    }

    /// Zig-flavored builtins that appear in expression text today. Type
    /// arguments (`i64` in `@as(i64, x)`) are type NAMES, not values — they
    /// are ignored, not evaluated. Values are already exact i64/f64 in the
    /// evaluator, so the casts are passthroughs; the point is that real
    /// corpus expressions evaluate, not that we model Zig's integer widths.
    fn evalBuiltin(self: *Evaluator, env: *Env, bc: ast.BuiltinCall) EvalError!Value {
        if (std.mem.eql(u8, bc.name, "as")) {
            if (bc.args.len != 2)
                return self.fail(error.UnsupportedBuiltin, "comptime evaluation: @as expects (type, value)", .{});
            return self.evalNode(env, &bc.args[1].node);
        }
        if (std.mem.eql(u8, bc.name, "intCast") or std.mem.eql(u8, bc.name, "truncate")) {
            if (bc.args.len != 1)
                return self.fail(error.UnsupportedBuiltin, "comptime evaluation: @{s} expects one value", .{bc.name});
            const v = try self.evalNode(env, &bc.args[0].node);
            _ = try v.expectInt();
            return v;
        }
        if (std.mem.eql(u8, bc.name, "divTrunc") or std.mem.eql(u8, bc.name, "rem") or std.mem.eql(u8, bc.name, "mod")) {
            if (bc.args.len != 2)
                return self.fail(error.UnsupportedBuiltin, "comptime evaluation: @{s} expects two values", .{bc.name});
            const a = try (try self.evalNode(env, &bc.args[0].node)).expectInt();
            const b = try (try self.evalNode(env, &bc.args[1].node)).expectInt();
            if (b == 0) return self.fail(error.DivisionByZero, "comptime evaluation: @{s} by zero", .{bc.name});
            if (std.mem.eql(u8, bc.name, "divTrunc")) return .{ .int = @divTrunc(a, b) };
            if (std.mem.eql(u8, bc.name, "rem")) return .{ .int = @rem(a, b) };
            return .{ .int = @mod(a, b) };
        }
        return self.fail(error.UnsupportedBuiltin, "comptime evaluation: builtin @{s} is not comptime-evaluable (known: @as, @intCast, @truncate, @divTrunc, @rem, @mod)", .{bc.name});
    }

    // ------------------------------------------------------------
    // The flow walker (rung two) — methods share the allocator, the
    // diagnostic contract, and the expression core above.
    // ------------------------------------------------------------

    pub fn setThunks(self: *Evaluator, thunks: []const Thunk) void {
        self.thunks = thunks;
    }

    fn findThunk(self: *const Evaluator, name: []const u8) ?*const Thunk {
        for (self.thunks) |*t| {
            if (std.mem.eql(u8, t.event_name, name)) return t;
        }
        return null;
    }

    /// Parse + evaluate expression TEXT (an argument value, a when-guard) in
    /// `env`. The single text→Value path for the walker and the Folder both.
    pub fn evalText(self: *Evaluator, env: *Env, text: []const u8) EvalError!Value {
        var parser = expression_parser.ExpressionParser.init(self.allocator, text);
        const expr = parser.parseAll() catch |err| {
            return self.fail(error.UnsupportedConstruct, "comptime evaluation: `{s}` did not parse as an expression ({s})", .{ text, @errorName(err) });
        };
        return self.evalExpr(env, expr);
    }

    fn evalArgs(self: *Evaluator, env: *Env, args: []const ast.Arg) EvalError![]ArgValue {
        const out = self.allocator.alloc(ArgValue, args.len) catch return error.OutOfMemory;
        for (args, 0..) |arg, i| {
            out[i] = .{ .name = arg.name, .value = try self.evalText(env, arg.value) };
        }
        return out;
    }

    /// Resolve + call an invocation target — a thunk, a subflow
    /// implementation, or a pure-Koru bare-return impl, in that order. Loud
    /// named wall otherwise.
    pub fn invokePath(self: *Evaluator, items: []const ast.Item, path: *const ast.DottedPath, args: []const ArgValue) EvalError!ThunkResult {
        const name = lastSegment(path);

        if (self.findThunk(name)) |thunk| {
            return thunk.call(self.allocator, args);
        }

        if (findSubflowImpl(items, path)) |sub| {
            const value = try self.walkFlow(items, sub, args);
            return .{ .branch = null, .payload = value };
        }

        if (findBareReturnImpl(items, path)) |impl| {
            var env = Env.init(self.allocator);
            for (args) |a| try env.bind(a.name, a.value);
            const plain = impl.value.plain_value orelse
                return self.fail(error.UnsupportedConstruct, "comptime walk: impl of `{s}` has no bare-return expression", .{name});
            const value = try self.evalText(&env, plain);
            return .{ .branch = null, .payload = value };
        }

        return self.fail(error.UnsupportedConstruct, "comptime walk: `{s}` is not callable at comptime — not in the thunk table (no source-time proc handler), no subflow implementation, no bare-return impl", .{name});
    }

    /// Walk a subflow implementation with `args` bound in a FRESH scope — a
    /// subflow body sees its own arguments, never the caller's bindings.
    /// Returns the walked flow's value (null = void).
    pub fn walkFlow(self: *Evaluator, items: []const ast.Item, flow: *const ast.Flow, args: []const ArgValue) EvalError!?Value {
        var env = Env.init(self.allocator);
        for (args) |a| try env.bind(a.name, a.value);
        return self.walkLabeledBody(items, &flow.body, flow.pre_label, &env);
    }

    const Outcome = union(enum) {
        result: ThunkResult,
        jump: Jump,
        none,
    };

    const Jump = struct {
        label: []const u8,
        /// Evaluated in the arm's scope BEFORE bubbling — a jump carries
        /// values, never unevaluated text.
        args: []ArgValue,
    };

    /// The labeled-loop core: invoke the head, dispatch the arms, re-enter
    /// the head with the jump's arguments when the matched chain bubbles a
    /// `@label(...)` naming this flow's `#label`.
    fn walkLabeledBody(self: *Evaluator, items: []const ast.Item, body: *const ast.Continuation, pre_label: ?[]const u8, env: *Env) EvalError!?Value {
        if (body.node == null or body.node.? != .invocation)
            return self.fail(error.UnsupportedConstruct, "comptime walk: flow head must be an invocation", .{});
        const inv = &body.node.?.invocation;

        var head_args: []const ArgValue = try self.evalArgs(env, inv.args);
        var iterations: usize = 0;
        while (true) {
            iterations += 1;
            if (iterations > WALK_ITERATION_WALL)
                return self.fail(error.UnsupportedConstruct, "comptime walk: labeled loop `#{s}` exceeded {d} iterations — non-terminating comptime loop?", .{ pre_label orelse "<unlabeled>", WALK_ITERATION_WALL });

            const result = try self.invokePath(items, &inv.path, head_args);

            if (body.continuations.len == 0) return result.payload;

            const outcome = try self.dispatchArms(items, body.continuations, result, env);
            switch (outcome) {
                .jump => |j| {
                    const label = pre_label orelse
                        return self.fail(error.UnsupportedConstruct, "comptime walk: `@{s}(...)` jump but the flow head carries no `#label` anchor", .{j.label});
                    if (!std.mem.eql(u8, j.label, label))
                        return self.fail(error.UnsupportedConstruct, "comptime walk: jump to `@{s}` but the enclosing anchor is `#{s}` — nested labels are a later rung", .{ j.label, label });
                    head_args = j.args;
                    continue;
                },
                .result => |r| return r.payload,
                .none => return null,
            }
        }
    }

    /// Match `result` against the arms IN ORDER: the branch name must equal
    /// the constructed branch; the payload binds FIRST so the when-guard can
    /// see it; a guarded arm matches only when its guard is true. First match
    /// wins — the runtime's arm semantics, interpreted.
    fn dispatchArms(self: *Evaluator, items: []const ast.Item, arms: []const ast.Continuation, result: ThunkResult, env: *Env) EvalError!Outcome {
        const branch = result.branch orelse
            return self.fail(error.UnsupportedConstruct, "comptime walk: a void call cannot dispatch branch arms", .{});

        for (arms) |*arm| {
            if (!std.mem.eql(u8, arm.branch, branch)) continue;
            if (arm.destructure.len > 0)
                return self.fail(error.UnsupportedConstruct, "comptime walk: shape-destructure arms are a later rung", .{});

            var arm_env = env.child();
            if (arm.binding) |b| {
                const payload = result.payload orelse
                    return self.fail(error.UnsupportedConstruct, "comptime walk: arm `| {s} {s}` binds a payload but branch `{s}` carried none", .{ arm.branch, b, branch });
                try arm_env.bind(b, payload);
            }

            if (try self.armGuardPasses(arm, &arm_env)) {
                return self.walkArm(items, arm, &arm_env);
            }
        }
        return self.fail(error.UnsupportedConstruct, "comptime walk: branch `{s}` matched no arm — name unhandled or every guard false", .{branch});
    }

    fn armGuardPasses(self: *Evaluator, arm: *const ast.Continuation, env: *Env) EvalError!bool {
        if (arm.condition_expr) |expr| return (try self.evalExpr(env, expr)).expectBool();
        if (arm.condition) |text| return (try self.evalText(env, text)).expectBool();
        return true;
    }

    /// Execute a matched arm: its node, then — when the node produced a
    /// dispatchable result and the arm has nested arms — recurse. Jumps
    /// bubble up to the enclosing labeled loop.
    fn walkArm(self: *Evaluator, items: []const ast.Item, arm: *const ast.Continuation, env: *Env) EvalError!Outcome {
        const node = arm.node orelse return .none;
        switch (node) {
            .terminal => return .none,
            .label_jump => |lj| {
                return .{ .jump = .{ .label = lj.label, .args = try self.evalArgs(env, lj.args) } };
            },
            .invocation => |chain_inv| {
                const args = try self.evalArgs(env, chain_inv.args);
                const result = try self.invokePath(items, &chain_inv.path, args);
                if (arm.continuations.len == 0) return .{ .result = result };
                return self.dispatchArms(items, arm.continuations, result, env);
            },
            else => return self.fail(error.UnsupportedConstruct, "comptime walk: arm node `{s}` is a later rung", .{@tagName(node)}),
        }
    }
};

// ============================================================
// The flow walker — branch dispatch, when-guards, labeled loops
// ============================================================
//
// Rung two of the comptime interpreter: walk a [comptime] flow the way the
// runtime emitter would have COMPILED it — invoke the head, dispatch the
// constructed branch over the arms (bind the payload, evaluate the when-guard,
// first match wins), follow the matched arm's chain, and re-enter the labeled
// head when the chain ends in an `@label(...)` jump.
//
// Calls resolve through THE THUNK LAW (docs/comptime_core_ast_inventory.md
// §6a): a source-time event with a proc handler is callable at comptime
// because Stage A emitted a wrapper — a thunk — marshalling Values into the
// handler's Input struct and its Output back into (branch, Value). Stage B
// compiled handler and wrapper natively; the walker calls through the table.
// Resolution order: thunk, subflow implementation, pure-Koru bare-return
// impl. Anything else is a loud named wall, never a guess.

/// A named argument value, marshalled across the thunk boundary.
pub const ArgValue = struct {
    name: []const u8,
    value: Value,
};

/// What one call produced: the branch the callee constructed and that
/// branch's payload. A void callee (report) produces neither.
pub const ThunkResult = struct {
    branch: ?[]const u8 = null,
    payload: ?Value = null,
};

/// One entry of the Stage A-generated dispatch table. `call` is a bare
/// function pointer on purpose: the generated wrappers are top-level fns
/// closing over nothing — the compiled handler IS the context.
pub const Thunk = struct {
    /// Resolution key: the event path's last segment (module-qualified
    /// resolution joins in a later rung, with a loud wall on ambiguity).
    event_name: []const u8,
    call: *const fn (allocator: std.mem.Allocator, args: []const ArgValue) EvalError!ThunkResult,
};

/// Runaway-comptime wall. A labeled loop that re-enters its head more than
/// this many times is almost certainly non-terminating at compile time; the
/// walker stops LOUDLY instead of hanging the build.
pub const WALK_ITERATION_WALL: usize = 1_000_000;

/// Find a named subflow implementation (`name = #loop tick(...) | ...`,
/// carried as a Flow with `impl_of` set) — the walker's second resolution
/// tier, after the thunk table.
pub fn findSubflowImpl(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.Flow {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                if (flow.impl_of) |*impl_path| {
                    if (pathsMatch(impl_path, path)) return flow;
                }
            },
            .module_decl => |*module| {
                for (module.items) |*mod_item| {
                    if (mod_item.* == .flow) {
                        if (mod_item.flow.impl_of) |*impl_path| {
                            if (pathsMatch(impl_path, path)) return &mod_item.flow;
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

// ============================================================
// The fold pass — Stage C partial evaluation of [comptime] flows
// ============================================================
//
// A flow is FOLDABLE when its head invocation targets a [comptime] event that
// has a pure-Koru bare-return impl (`~answer -> 40 + 2`, an ImmediateImpl with
// is_bare_return). The Folder evaluates the head at Stage C and rewrites the
// flow to its RESIDUE: the continuation chain, promoted to flow root, with the
// return binding substituted by the folded literal, and the [comptime]
// annotation dropped — so the residue emits as ordinary runtime code.
//
// Stage A (visitor_emitter) skips foldable flows in comptime_only mode via the
// mirror predicate flowIsInterpreterFoldable — they are consumed HERE, never
// compiled as comptime_flowN.

pub const Folder = struct {
    allocator: std.mem.Allocator,
    evaluator: Evaluator,

    pub fn init(allocator: std.mem.Allocator) Folder {
        return .{ .allocator = allocator, .evaluator = Evaluator.init(allocator) };
    }

    pub fn diag(self: *const Folder) []const u8 {
        return self.evaluator.diag;
    }

    /// Hand the walker its Stage A-generated dispatch table (THE THUNK LAW).
    pub fn setThunks(self: *Folder, thunks: []const Thunk) void {
        self.evaluator.setThunks(thunks);
    }

    /// Returns the input program untouched when nothing is consumable.
    /// Foldable flows are rewritten to their residue; walkable flows are
    /// EXECUTED to completion and dropped — they happened at compile time,
    /// nothing of them reaches runtime.
    pub fn fold(self: *Folder, program: *const ast.Program) EvalError!*const ast.Program {
        var found = false;
        for (program.items) |item| {
            if (item == .flow and flowIsInterpreterConsumable(program.items, &item.flow) != null) {
                found = true;
                break;
            }
        }
        if (!found) return program;

        var new_items = std.ArrayList(ast.Item).initCapacity(self.allocator, program.items.len) catch return error.OutOfMemory;
        for (program.items) |item| {
            if (item == .flow) {
                if (flowIsInterpreterConsumable(program.items, &item.flow)) |consumable| {
                    switch (consumable) {
                        .fold => |impl| {
                            new_items.append(self.allocator, .{ .flow = try self.foldFlow(&item.flow, impl) }) catch return error.OutOfMemory;
                        },
                        .walk => |sub| {
                            try self.walkFlowToCompletion(program, &item.flow, sub);
                            // Fully consumed at comptime: no residue item.
                        },
                    }
                    continue;
                }
            }
            new_items.append(self.allocator, item) catch return error.OutOfMemory;
        }

        const new_program = self.allocator.create(ast.Program) catch return error.OutOfMemory;
        new_program.* = .{
            .items = new_items.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .module_annotations = program.module_annotations,
            .main_module_name = program.main_module_name,
            .allocator = program.allocator,
            .type_registry = program.type_registry,
        };
        return new_program;
    }

    /// Run a walkable flow through the interpreter. Residue continuations on
    /// a walked flow are a later rung — for now the flow must be FULLY
    /// comptime, and the walk's effects (thunked prints, file IO) happen
    /// right here, during compilation.
    fn walkFlowToCompletion(self: *Folder, program: *const ast.Program, flow: *const ast.Flow, sub: *const ast.Flow) EvalError!void {
        if (flow.body.continuations.len != 0)
            return self.evaluator.fail(error.UnsupportedConstruct, "comptime walk: residue continuations on a walked flow are a later rung — the flow must be fully comptime", .{});
        const inv = &flow.body.node.?.invocation;
        var env = Env.init(self.allocator);
        const args = try self.evaluator.evalArgs(&env, inv.args);
        _ = try self.evaluator.walkFlow(program.items, sub, args);
    }

    fn foldFlow(self: *Folder, flow: *const ast.Flow, impl: *const ast.ImmediateImpl) EvalError!ast.Flow {
        const inv = &flow.body.node.?.invocation;

        // Bind event args: each arg value is itself a comptime expression.
        var env = Env.init(self.allocator);
        for (inv.args) |arg| {
            const arg_value = try self.evalText(&env, arg.value);
            try env.bind(arg.name, arg_value);
        }

        const plain = impl.value.plain_value orelse
            return self.evaluator.fail(error.UnsupportedConstruct, "comptime fold: impl of `{s}` has no bare-return expression", .{lastSegment(&impl.event_path)});
        const value = try self.evalText(&env, plain);
        const literal = try self.literalText(value);

        // Residue: exactly one chain continuation whose node is an invocation,
        // promoted to flow root. Multi-arm residue is a later rung.
        if (flow.body.continuations.len != 1)
            return self.evaluator.fail(error.UnsupportedConstruct, "comptime fold: expected exactly one residue continuation, got {d} — multi-arm residue is a later rung", .{flow.body.continuations.len});
        const chain = flow.body.continuations[0];
        if (chain.node == null or chain.node.? != .invocation)
            return self.evaluator.fail(error.UnsupportedConstruct, "comptime fold: residue must be an invocation chain — other residue shapes are a later rung", .{});

        const new_root = try self.substituteContinuation(chain, inv.return_binding, literal);

        var new_flow = flow.*;
        new_flow.body = new_root;
        new_flow.annotations = try self.stripAnnotationPart(flow.annotations, "comptime");
        return new_flow;
    }

    fn substituteContinuation(self: *Folder, cont: ast.Continuation, binding: ?[]const u8, literal: []const u8) EvalError!ast.Continuation {
        var new_cont = cont;

        if (binding) |name| {
            if (cont.node) |node| {
                if (node == .invocation) {
                    var new_inv = node.invocation;
                    const new_args = self.allocator.alloc(ast.Arg, new_inv.args.len) catch return error.OutOfMemory;
                    for (new_inv.args, 0..) |arg, i| {
                        var new_arg = arg;
                        new_arg.value = try self.substituteIdent(arg.value, name, literal);
                        if (arg.expression_value) |ev| {
                            const new_ev = self.allocator.create(@TypeOf(ev.*)) catch return error.OutOfMemory;
                            new_ev.* = ev.*;
                            new_ev.text = try self.substituteIdent(ev.text, name, literal);
                            new_arg.expression_value = new_ev;
                        }
                        // The stale parse of the ORIGINAL text must not survive
                        // substitution — downstream re-parses from text.
                        new_arg.parsed_expression = null;
                        new_args[i] = new_arg;
                    }
                    new_inv.args = new_args;
                    new_cont.node = .{ .invocation = new_inv };
                }
            }
            if (cont.condition) |condition| {
                new_cont.condition = try self.substituteIdent(condition, name, literal);
                new_cont.condition_expr = null;
            }
            if (cont.continuations.len > 0) {
                const new_children = self.allocator.alloc(ast.Continuation, cont.continuations.len) catch return error.OutOfMemory;
                for (cont.continuations, 0..) |child, i| {
                    new_children[i] = try self.substituteContinuation(child, binding, literal);
                }
                new_cont.continuations = new_children;
            }
        }

        return new_cont;
    }

    /// Identifier-boundary textual substitution. Koru identifiers are
    /// kebab-friendly: [A-Za-z0-9_-] are identifier characters.
    fn substituteIdent(self: *Folder, text: []const u8, name: []const u8, replacement: []const u8) EvalError![]const u8 {
        var out = std.ArrayList(u8).initCapacity(self.allocator, text.len) catch return error.OutOfMemory;
        var i: usize = 0;
        while (i < text.len) {
            const match = i + name.len <= text.len and
                std.mem.eql(u8, text[i .. i + name.len], name) and
                (i == 0 or !isIdentChar(text[i - 1])) and
                (i + name.len == text.len or !isIdentChar(text[i + name.len]));
            if (match) {
                out.appendSlice(self.allocator, replacement) catch return error.OutOfMemory;
                i += name.len;
            } else {
                out.append(self.allocator, text[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn evalText(self: *Folder, env: *Env, text: []const u8) EvalError!Value {
        // One text→Value path for fold and walk both — the Evaluator's.
        return self.evaluator.evalText(env, text);
    }

    fn literalText(self: *Folder, value: Value) EvalError![]const u8 {
        return switch (value) {
            .int => |i| std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch error.OutOfMemory,
            .float => |f| std.fmt.allocPrint(self.allocator, "{d}", .{f}) catch error.OutOfMemory,
            .boolean => |b| if (b) "true" else "false",
            .string => |s| std.fmt.allocPrint(self.allocator, "\"{s}\"", .{s}) catch error.OutOfMemory,
            else => self.evaluator.fail(error.UnsupportedConstruct, "comptime fold: only scalar values splice as literals so far — arrays/cells/fragments are a later rung", .{}),
        };
    }

    fn stripAnnotationPart(self: *Folder, annotations: []const []const u8, part: []const u8) EvalError![]const []const u8 {
        var out = std.ArrayList([]const u8).initCapacity(self.allocator, annotations.len) catch return error.OutOfMemory;
        for (annotations) |annotation| {
            var kept = std.ArrayList(u8).initCapacity(self.allocator, annotation.len) catch return error.OutOfMemory;
            var it = std.mem.splitScalar(u8, annotation, '|');
            while (it.next()) |p| {
                if (std.mem.eql(u8, p, part)) continue;
                if (kept.items.len > 0) kept.append(self.allocator, '|') catch return error.OutOfMemory;
                kept.appendSlice(self.allocator, p) catch return error.OutOfMemory;
            }
            if (kept.items.len > 0)
                out.append(self.allocator, kept.toOwnedSlice(self.allocator) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// THE foldability predicate — shared by the Stage-C Folder and Stage A's
/// visitor_emitter (which must skip these flows instead of emitting them as
/// comptime_flowN). One predicate, two consumers: if they ever disagreed,
/// foldable flows would either break Stage B or silently vanish.
pub fn flowIsFoldable(items: []const ast.Item, flow: *const ast.Flow) ?*const ast.ImmediateImpl {
    if (flow.body.node == null or flow.body.node.? != .invocation) return null;
    const inv = &flow.body.node.?.invocation;

    const decl = findEventDecl(items, &inv.path) orelse return null;
    if (!hasAnnotationPart(decl.annotations, "comptime")) return null;
    // Events with Source params are transform/build machinery, never foldable.
    for (decl.input.fields) |field| {
        if (field.is_source) return null;
    }
    return findBareReturnImpl(items, &inv.path);
}

/// A [comptime] flow whose head invocation resolves to a SUBFLOW
/// implementation is WALKED by the interpreter. Comptime-ness derives from
/// the call site: the flow's own [comptime] annotation OR the invoked
/// event's — the subflow definition itself needs no marking (though marking
/// it is legal and harmless).
pub fn flowIsWalkable(items: []const ast.Item, flow: *const ast.Flow) ?*const ast.Flow {
    if (flow.body.node == null or flow.body.node.? != .invocation) return null;
    const inv = &flow.body.node.?.invocation;
    const comptime_by_flow = hasAnnotationPart(flow.annotations, "comptime");
    const comptime_by_event = if (findEventDecl(items, &inv.path)) |decl|
        hasAnnotationPart(decl.annotations, "comptime")
    else
        false;
    if (!comptime_by_flow and !comptime_by_event) return null;
    return findSubflowImpl(items, &inv.path);
}

/// What the interpreter consumes at Stage C: a foldable flow (bare-return
/// head, rung one) or a walkable flow (subflow-implemented head, rung two).
pub const InterpreterConsumable = union(enum) {
    fold: *const ast.ImmediateImpl,
    walk: *const ast.Flow,
};

pub fn flowIsInterpreterConsumable(items: []const ast.Item, flow: *const ast.Flow) ?InterpreterConsumable {
    if (flowIsFoldable(items, flow)) |impl| return .{ .fold = impl };
    if (flowIsWalkable(items, flow)) |sub| return .{ .walk = sub };
    return null;
}

/// THE Stage A skip predicate — shared by BOTH visitor_emitter emission
/// sites (comptime_flowN bodies + the comptime_main call loop). True when
/// the interpreter owns this flow at Stage C: emitting it as comptime_flowN
/// would double-run it (a definition entered on demand would run standalone —
/// the 733MB-of-zeros failure shape) or break Stage B on runtime-effectful
/// residue.
pub fn flowIsInterpreterOwned(items: []const ast.Item, flow: *const ast.Flow) bool {
    if (flowIsInterpreterConsumable(items, flow) != null) return true;
    // A comptime subflow DEFINITION is entered by the walker when its event
    // is invoked — never a standalone comptime flow for comptime_main to
    // call. Comptime-ness is the def's own annotation OR the implemented
    // event's (derivation: marking the def is legal, not required).
    if (flow.impl_of) |*impl_path| {
        if (hasAnnotationPart(flow.annotations, "comptime")) return true;
        if (findEventDecl(items, impl_path)) |decl| {
            if (hasAnnotationPart(decl.annotations, "comptime")) return true;
        }
    }
    return false;
}

pub fn hasAnnotationPart(annotations: []const []const u8, part: []const u8) bool {
    for (annotations) |annotation| {
        var it = std.mem.splitScalar(u8, annotation, '|');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, part)) return true;
        }
    }
    return false;
}

fn pathsMatch(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    if (a.module_qualifier) |qa| {
        if (b.module_qualifier) |qb| return std.mem.eql(u8, qa, qb);
    }
    // A missing qualifier on either side matches on segments alone.
    return true;
}

pub fn findEventDecl(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.EventDecl {
    for (items) |*item| {
        switch (item.*) {
            .event_decl => |*decl| {
                if (pathsMatch(&decl.path, path)) return decl;
            },
            .module_decl => |*module| {
                for (module.items) |*mod_item| {
                    if (mod_item.* == .event_decl and pathsMatch(&mod_item.event_decl.path, path))
                        return &mod_item.event_decl;
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn findBareReturnImpl(items: []const ast.Item, path: *const ast.DottedPath) ?*const ast.ImmediateImpl {
    for (items) |*item| {
        switch (item.*) {
            .immediate_impl => |*impl| {
                if (impl.value.is_bare_return and pathsMatch(&impl.event_path, path)) return impl;
            },
            .module_decl => |*module| {
                for (module.items) |*mod_item| {
                    if (mod_item.* == .immediate_impl and
                        mod_item.immediate_impl.value.is_bare_return and
                        pathsMatch(&mod_item.immediate_impl.event_path, path))
                        return &mod_item.immediate_impl;
                }
            },
            else => {},
        }
    }
    return null;
}

fn lastSegment(path: *const ast.DottedPath) []const u8 {
    return if (path.segments.len > 0) path.segments[path.segments.len - 1] else "<empty>";
}

// ============================================================================
// ANNOTATION ENTRY EVALUATION — the shared entry vocabulary
// ============================================================================
//
// Annotation entries are expressions in the shared when-clause grammar, but
// their meaning belongs to CONSUMERS, never the language: a pass that ignores
// an entry ignores it freely; a pass that EVALUATES one and can't gets a loud
// EvalError to report as itself (the import gate is the first and most
// privileged such consumer — it decides AST membership, so its entries MUST
// evaluate). Nothing here rejects an annotation globally; there is no global
// rejector, by ruling (2026-07-20).
//
// Position rules (ruled 2026-07-20):
//   - Truthiness positions (entry root, and/or/not operands): a bare
//     identifier RESOLVES through the provider chain; absent-is-false.
//   - Comparison RHS: a bare identifier is a SYMBOL — the word itself,
//     never a chain lookup (`build == release` asks "is build the word
//     'release'", and chain-resolving the RHS under absent-is-false would
//     make it always-false, which nobody means).
//   - Comparison LHS resolves (it names the thing being asked about).
//   - Narrowing calls cflag(x) / env(x) / command(x) pin one provider
//     instead of walking the chain.
//
// Provider chain: compiler flags → process env → absent-is-false. The
// build:config provider slots between flags and env when Stage-C consumers
// ride this vocabulary — the parse-time import gate structurally cannot see
// config declared in the program it is still parsing.

pub const ResolutionSource = enum {
    cflag,
    env,
    command,
    absent,

    pub fn name(self: ResolutionSource) []const u8 {
        return switch (self) {
            .cflag => "compiler flag",
            .env => "environment",
            .command => "command",
            .absent => "absent",
        };
    }
};

pub const Resolution = struct {
    value: Value,
    source: ResolutionSource,
};

/// Reader-side provenance: the entry author writes the terse intent-shaped
/// atom; resolution answers "where did this value come from this build".
pub const Provider = struct {
    /// CLI flags exactly as koruc stores them: "name" or "name=value".
    flags: []const []const u8 = &.{},
    /// Process environment; null when the consumer has none to offer.
    env_map: ?*const std.process.EnvMap = null,
    /// The active koruc command, when one is running (e.g. "explain").
    command: ?[]const u8 = null,

    /// A flag value is textual on the CLI; numbers travel as numbers so
    /// `version >= 15` works against `--version=15`. Everything else stays
    /// a string.
    fn coerce(text: []const u8) Value {
        if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .int = i } else |_| {}
        if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
        return .{ .string = text };
    }

    pub fn resolveFlag(self: *const Provider, atom: []const u8) ?Value {
        for (self.flags) |f| {
            if (std.mem.eql(u8, f, atom)) return .{ .boolean = true };
            if (f.len > atom.len and f[atom.len] == '=' and std.mem.startsWith(u8, f, atom))
                return coerce(f[atom.len + 1 ..]);
        }
        return null;
    }

    pub fn resolveEnv(self: *const Provider, atom: []const u8) ?Value {
        const m = self.env_map orelse return null;
        if (m.get(atom)) |v| return coerce(v);
        return null;
    }

    pub fn resolve(self: *const Provider, atom: []const u8) Resolution {
        if (self.resolveFlag(atom)) |v| return .{ .value = v, .source = .cflag };
        if (self.resolveEnv(atom)) |v| return .{ .value = v, .source = .env };
        return .{ .value = .{ .boolean = false }, .source = .absent };
    }
};

pub const EntryResult = struct {
    value: Value,
    truthy: bool,
    /// One line per resolution performed, e.g. `build = "release" (compiler
    /// flag)` — the consumer's loud report prints these verbatim.
    trace: []const []const u8,
};

/// Entry truthiness: presence-shaped, not strict-bool. A resolved flag is
/// true by being there; an empty string is as good as absent.
fn entryTruthy(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .string => |s| s.len > 0,
        .int => |i| i != 0,
        .float => |f| f != 0,
        else => false,
    };
}

/// Evaluate one annotation entry against the provider chain. All allocations
/// ride the caller's allocator (arena convention). Loud-failure contract:
/// anything unevaluable is an EvalError with a diagnostic, never a guess.
pub fn evalAnnotationEntry(
    allocator: std.mem.Allocator,
    provider: *const Provider,
    entry_text: []const u8,
) EvalError!EntryResult {
    var parser = expression_parser.ExpressionParser.init(allocator, entry_text);
    defer parser.deinit();
    const expr = parser.parseAll() catch {
        return error.UnsupportedConstruct;
    };

    var ev = EntryEvaluator{
        .allocator = allocator,
        .provider = provider,
        .trace = std.ArrayList([]const u8).initCapacity(allocator, 4) catch return error.OutOfMemory,
    };
    const value = try ev.evalNode(&expr.node, .resolve);
    return .{
        .value = value,
        .truthy = entryTruthy(value),
        .trace = ev.trace.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Like evalAnnotationEntry but with the parse/eval diagnostic surfaced for
/// the consumer's error message.
pub fn evalAnnotationEntryDiag(
    allocator: std.mem.Allocator,
    provider: *const Provider,
    entry_text: []const u8,
    diag_out: *[]const u8,
) EvalError!EntryResult {
    var parser = expression_parser.ExpressionParser.init(allocator, entry_text);
    defer parser.deinit();
    const expr = parser.parseAll() catch |err| {
        diag_out.* = std.fmt.allocPrint(allocator, "entry does not parse as an expression ({s})", .{@errorName(err)}) catch return error.OutOfMemory;
        return error.UnsupportedConstruct;
    };

    var ev = EntryEvaluator{
        .allocator = allocator,
        .provider = provider,
        .trace = std.ArrayList([]const u8).initCapacity(allocator, 4) catch return error.OutOfMemory,
    };
    const value = ev.evalNode(&expr.node, .resolve) catch |err| {
        diag_out.* = ev.diag orelse @errorName(err);
        return err;
    };
    return .{
        .value = value,
        .truthy = entryTruthy(value),
        .trace = ev.trace.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

const EntryEvaluator = struct {
    allocator: std.mem.Allocator,
    provider: *const Provider,
    trace: std.ArrayList([]const u8),
    diag: ?[]const u8 = null,

    const Mode = enum { resolve, symbol };

    fn fail(self: *EntryEvaluator, err: EvalError, comptime fmt: []const u8, args: anytype) EvalError {
        self.diag = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        return err;
    }

    fn note(self: *EntryEvaluator, atom: []const u8, r: Resolution) EvalError!void {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 32) catch return error.OutOfMemory;
        const w = buf.writer(self.allocator);
        w.print("{s} = ", .{atom}) catch return error.OutOfMemory;
        r.value.format(w) catch return error.OutOfMemory;
        w.print(" ({s})", .{r.source.name()}) catch return error.OutOfMemory;
        self.trace.append(self.allocator, buf.toOwnedSlice(self.allocator) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }

    fn evalNode(self: *EntryEvaluator, node: *const ast.ExprNode, mode: Mode) EvalError!Value {
        switch (node.*) {
            .identifier => |name| switch (mode) {
                .symbol => return .{ .string = name },
                .resolve => {
                    const r = self.provider.resolve(name);
                    try self.note(name, r);
                    return r.value;
                },
            },
            .literal => |lit| return self.evalLiteral(lit),
            .grouped => |inner| return self.evalNode(&inner.node, mode),
            .unary => |un| switch (un.op) {
                .not => {
                    const v = try self.evalNode(&un.operand.node, .resolve);
                    return .{ .boolean = !entryTruthy(v) };
                },
                .negate => {
                    const v = try self.evalNode(&un.operand.node, .symbol);
                    return switch (v) {
                        .int => |i| .{ .int = -i },
                        .float => |f| .{ .float = -f },
                        else => self.fail(error.TypeMismatch, "unary `-` needs a number", .{}),
                    };
                },
            },
            .binary => |bin| return self.evalBinary(bin),
            .function_call => |fc| return self.evalNarrowing(fc),
            else => return self.fail(error.UnsupportedConstruct, "this construct has no meaning in an annotation entry", .{}),
        }
    }

    fn evalLiteral(self: *EntryEvaluator, lit: ast.Literal) EvalError!Value {
        switch (lit) {
            .number => |text| {
                if (std.fmt.parseInt(i64, text, 0)) |i| return .{ .int = i } else |_| {}
                if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
                return self.fail(error.InvalidLiteral, "`{s}` is not a number", .{text});
            },
            .string => |text| {
                const bare = if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"')
                    text[1 .. text.len - 1]
                else
                    text;
                return .{ .string = bare };
            },
            .boolean => |b| return .{ .boolean = b },
        }
    }

    fn isComparison(op: ast.BinaryOperator) bool {
        return switch (op) {
            .equal, .not_equal, .less, .greater, .less_equal, .greater_equal => true,
            else => false,
        };
    }

    fn evalBinary(self: *EntryEvaluator, bin: ast.BinaryOp) EvalError!Value {
        switch (bin.op) {
            .and_op => {
                const l = try self.evalNode(&bin.left.node, .resolve);
                if (!entryTruthy(l)) return .{ .boolean = false };
                const r = try self.evalNode(&bin.right.node, .resolve);
                return .{ .boolean = entryTruthy(r) };
            },
            .or_op => {
                const l = try self.evalNode(&bin.left.node, .resolve);
                if (entryTruthy(l)) return .{ .boolean = true };
                const r = try self.evalNode(&bin.right.node, .resolve);
                return .{ .boolean = entryTruthy(r) };
            },
            else => {},
        }

        if (!isComparison(bin.op)) {
            return self.fail(error.UnsupportedConstruct, "only comparisons and and/or/not compose in annotation entries", .{});
        }

        // Comparison: LHS resolves, bare-identifier RHS is a symbol (ruled).
        const left = try self.evalNode(&bin.left.node, .resolve);
        const right = try self.evalNode(&bin.right.node, .symbol);

        switch (bin.op) {
            .equal => return .{ .boolean = try self.valuesEqual(left, right) },
            .not_equal => return .{ .boolean = !(try self.valuesEqual(left, right)) },
            else => {},
        }

        // Ordering needs numbers on both sides.
        const lf = try self.asNumber(left, "left side of comparison");
        const rf = try self.asNumber(right, "right side of comparison");
        return .{ .boolean = switch (bin.op) {
            .less => lf < rf,
            .less_equal => lf <= rf,
            .greater => lf > rf,
            .greater_equal => lf >= rf,
            else => unreachable,
        } };
    }

    fn asNumber(self: *EntryEvaluator, v: Value, what: []const u8) EvalError!f64 {
        return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .string => |s| std.fmt.parseFloat(f64, s) catch
                self.fail(error.TypeMismatch, "{s} is `{s}`, not a number", .{ what, s }),
            .boolean => self.fail(error.TypeMismatch, "{s} resolved absent or boolean; ordering needs numbers", .{what}),
            else => self.fail(error.TypeMismatch, "{s} is not a number", .{what}),
        };
    }

    fn valuesEqual(self: *EntryEvaluator, l: Value, r: Value) EvalError!bool {
        _ = self;
        return switch (l) {
            .string => |ls| switch (r) {
                .string => |rs| std.mem.eql(u8, ls, rs),
                else => false,
            },
            .int => |li| switch (r) {
                .int => |ri| li == ri,
                .float => |rf| @as(f64, @floatFromInt(li)) == rf,
                .string => |rs| if (std.fmt.parseInt(i64, rs, 0)) |ri| li == ri else |_| false,
                else => false,
            },
            .float => |lf| switch (r) {
                .float => |rf| lf == rf,
                .int => |ri| lf == @as(f64, @floatFromInt(ri)),
                .string => |rs| if (std.fmt.parseFloat(f64, rs)) |rf| lf == rf else |_| false,
                else => false,
            },
            .boolean => |lb| switch (r) {
                .boolean => |rb| lb == rb,
                else => false,
            },
            else => false,
        };
    }

    /// cflag(x) / env(x) / command(x): pin one provider instead of walking
    /// the chain. The argument is a symbol (identifier) or string literal.
    fn evalNarrowing(self: *EntryEvaluator, fc: ast.FunctionCall) EvalError!Value {
        const head = switch (fc.callee.node) {
            .identifier => |n| n,
            else => return self.fail(error.UnsupportedConstruct, "a narrowing call needs a plain head (cflag/env/command)", .{}),
        };
        if (fc.args.len != 1) {
            return self.fail(error.UnsupportedConstruct, "{s}(...) takes exactly one atom", .{head});
        }
        const atom = switch (fc.args[0].node) {
            .identifier => |n| n,
            .literal => |lit| switch (lit) {
                .string => |s| if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s,
                else => return self.fail(error.UnsupportedConstruct, "{s}(...) takes a name, not a number", .{head}),
            },
            else => return self.fail(error.UnsupportedConstruct, "{s}(...) takes a plain atom", .{head}),
        };

        if (std.mem.eql(u8, head, "cflag")) {
            const r: Resolution = if (self.provider.resolveFlag(atom)) |v|
                .{ .value = v, .source = .cflag }
            else
                .{ .value = .{ .boolean = false }, .source = .absent };
            try self.note(atom, r);
            return r.value;
        }
        if (std.mem.eql(u8, head, "env")) {
            const r: Resolution = if (self.provider.resolveEnv(atom)) |v|
                .{ .value = v, .source = .env }
            else
                .{ .value = .{ .boolean = false }, .source = .absent };
            try self.note(atom, r);
            return r.value;
        }
        if (std.mem.eql(u8, head, "command")) {
            const active = self.provider.command;
            const matches = active != null and std.mem.eql(u8, active.?, atom);
            const r: Resolution = if (matches)
                .{ .value = .{ .boolean = true }, .source = .command }
            else
                .{ .value = .{ .boolean = false }, .source = if (active == null) .absent else .command };
            try self.note(atom, r);
            return r.value;
        }
        return self.fail(error.UnsupportedConstruct, "unknown narrowing head `{s}` — known: cflag, env, command", .{head});
    }
};
