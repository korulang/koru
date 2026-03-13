//! Koru Interpreter Core
//! This module provides the core interpreter logic for executing Koru flows.
//! It is used by:
//! - The compiler's [frontend] execution mode
//! - The runtime interpreter (koru_std/interpreter.kz)
//!
//! DESIGN:
//! - Walks the AST and executes events via registered dispatchers
//! - Tracks bindings in an environment as flow progresses
//! - Handles control flow (~if, ~for) specially
//! - Uses typed FieldValue for dispatcher results (no string parsing!)

const log = @import("log");
const std = @import("std");
const ast = @import("ast");

// ============================================================================
// INTERPRETER VALUE - Runtime representation of Koru values
// ============================================================================

pub const FieldValue = union(enum) {
    string_val: []const u8,
    int_val: i64,
    float_val: f64,
    bool_val: bool,
};

pub const NamedField = struct {
    name: []const u8,
    value: FieldValue,
};

pub const Value = struct {
    branch: []const u8, // Which branch was taken/constructed
    fields: []const NamedField, // Structured fields (typed from dispatcher)

    pub fn empty(branch_name: []const u8) Value {
        return .{
            .branch = branch_name,
            .fields = &[_]NamedField{},
        };
    }

    /// Create a Value from dispatcher results - direct field handoff, zero parsing!
    pub fn fromDispatch(branch_name: []const u8, fields: []const NamedField) Value {
        return .{
            .branch = branch_name,
            .fields = fields,
        };
    }

    /// Clone value into a page-allocated persistent copy (survives arena teardown).
    pub fn clonePersistent(self: Value) Value {
        const allocator = std.heap.page_allocator;
        const branch_copy = allocator.dupe(u8, self.branch) catch self.branch;
        var field_copy = allocator.alloc(NamedField, self.fields.len) catch {
            return self;
        };
        for (self.fields, 0..) |f, i| {
            const name_copy = allocator.dupe(u8, f.name) catch f.name;
            const value_copy = switch (f.value) {
                .string_val => |s| FieldValue{ .string_val = allocator.dupe(u8, s) catch s },
                .bool_val => |b| FieldValue{ .bool_val = b },
                .int_val => |n| FieldValue{ .int_val = n },
                .float_val => |fl| FieldValue{ .float_val = fl },
            };
            field_copy[i] = .{ .name = name_copy, .value = value_copy };
        }
        return .{ .branch = branch_copy, .fields = field_copy };
    }
};

// ============================================================================
// ENVIRONMENT - Tracks bindings during interpretation
// ============================================================================

pub const Environment = struct {
    bindings: std.StringHashMap(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{
            .bindings = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.bindings.deinit();
    }

    /// Clear bindings but keep capacity to avoid reallocating in hot paths.
    pub fn clear(self: *Environment) void {
        self.bindings.clearRetainingCapacity();
    }

    pub fn bind(self: *Environment, name: []const u8, value: Value) !void {
        try self.bindings.put(name, value);
    }

    pub fn get(self: *Environment, name: []const u8) ?Value {
        return self.bindings.get(name);
    }
};

// ============================================================================
// DISPATCH RESULT - What dispatchers return to the interpreter
// ============================================================================

pub const DispatchResult = struct {
    branch: []const u8,
    fields: []const NamedField, // Direct typed field values
};

// ============================================================================
// DISPATCHER TYPE - Function signature for scope dispatchers
// ============================================================================

pub const DispatchFn = *const fn (*const ast.Invocation, *DispatchResult) anyerror!void;

// ============================================================================
// INTERPRETER CONTEXT - Passed to the execution loop
// ============================================================================

pub const InterpreterContext = struct {
    env: *Environment,
    expr_bindings: *ExprBindings, // For expression evaluation in ~if
    allocator: std.mem.Allocator,
    // Dispatcher function pointer - set by the scope
    dispatcher: ?DispatchFn,
};

const InterpreterThreadState = struct {
    threadlocal var inited: bool = false;
    threadlocal var arena: std.heap.ArenaAllocator = undefined;
    threadlocal var env: Environment = undefined;
    threadlocal var expr_bindings: ExprBindings = undefined;

    fn ensureInit() void {
        if (!inited) {
            arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            env = Environment.init(std.heap.page_allocator);
            expr_bindings = ExprBindings.init(std.heap.page_allocator);
            inited = true;
        }
    }

    fn prepare() std.mem.Allocator {
        ensureInit();
        _ = arena.reset(.retain_capacity);
        if (env.bindings.count() != 0) env.clear();
        if (expr_bindings.values.count() != 0) expr_bindings.clear();
        return arena.allocator();
    }
};

const InterpreterFlowCache = struct {
    threadlocal var inited: bool = false;
    threadlocal var arena: std.heap.ArenaAllocator = undefined;
    threadlocal var source_hash: u64 = 0;
    threadlocal var source_len: usize = 0;
    threadlocal var source_copy: []const u8 = &[_]u8{};
    threadlocal var flow: ast.Flow = undefined;
    threadlocal var has_flow: bool = false;

    fn ensureInit() void {
        if (!inited) {
            arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            inited = true;
        }
    }

    fn getOrParse(source: []const u8) ?*const ast.Flow {
        ensureInit();
        const hash = std.hash.Wyhash.hash(0, source);
        if (has_flow and source_len == source.len and source_hash == hash and std.mem.eql(u8, source, source_copy)) {
            return &flow;
        }

        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();
        source_copy = allocator.dupe(u8, source) catch {
            has_flow = false;
            return null;
        };
        const flow_parser = @import("flow_parser");
        const parse_result = flow_parser.parseFlow(allocator, source_copy);
        switch (parse_result) {
            .flow => |f| {
                flow = f;
                has_flow = true;
                source_len = source.len;
                source_hash = hash;
                return &flow;
            },
            .err => {
                has_flow = false;
                return null;
            },
        }
    }
};

// ============================================================================
// AST VALIDATION - Pre-execution validation (shadowing, etc.)
// ============================================================================

pub const ValidationError = struct {
    message: []const u8,
    binding_name: []const u8,
};

/// Validates a flow AST before execution.
/// Checks for shadowing (duplicate bindings) and other semantic errors.
/// Returns null if valid, or ValidationError if invalid.
pub fn validateFlow(flow: *const ast.Flow, allocator: std.mem.Allocator) ?ValidationError {
    var seen_bindings = std.StringHashMap(void).init(allocator);
    defer seen_bindings.deinit();

    return validateFlowRecursive(flow, &seen_bindings);
}

fn validateFlowRecursive(flow: *const ast.Flow, seen: *std.StringHashMap(void)) ?ValidationError {
    // Check each continuation for bindings
    for (flow.continuations) |cont| {
        if (cont.binding) |binding_name| {
            // Check for shadowing
            if (seen.contains(binding_name)) {
                return .{
                    .message = "Shadowing not allowed: binding already exists",
                    .binding_name = binding_name,
                };
            }
            // Record this binding
            seen.put(binding_name, {}) catch {
                return .{
                    .message = "Validation internal error",
                    .binding_name = binding_name,
                };
            };
        }

        // Note: AST structure changed - cont.node is now ?Node not *Flow
        // Nested continuations are in cont.continuations, handled in the outer loop
    }

    return null; // Valid!
}

// ============================================================================
// EXPRESSION VALUE - For runtime expression evaluation (different from Value)
// ============================================================================

pub const ExprValue = union(enum) {
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    null_val: void,

    pub fn isTruthy(self: ExprValue) bool {
        return switch (self) {
            .bool_val => |b| b,
            .int_val => |n| n != 0,
            .float_val => |f| f != 0.0,
            .string_val => |s| s.len > 0,
            .null_val => false,
        };
    }
};

// ============================================================================
// EXPRESSION BINDINGS - Maps names to ExprValues for expression evaluation
// ============================================================================

pub const ExprBindings = struct {
    values: std.StringHashMap(ExprValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExprBindings {
        return .{
            .values = std.StringHashMap(ExprValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExprBindings) void {
        self.values.deinit();
    }

    /// Clear bindings but keep capacity to avoid reallocating in hot paths.
    pub fn clear(self: *ExprBindings) void {
        self.values.clearRetainingCapacity();
    }

    pub fn set(self: *ExprBindings, name: []const u8, value: ExprValue) !void {
        try self.values.put(name, value);
    }

    pub fn get(self: *const ExprBindings, name: []const u8) ?ExprValue {
        return self.values.get(name);
    }
};

// ============================================================================
// EXPRESSION EVALUATOR - Evaluates AST Expression against ExprBindings
// ============================================================================

pub const ExprEvalError = error{
    UnknownBinding,
    TypeMismatch,
    DivisionByZero,
    InvalidExpression,
    UnsupportedOperator,
};

pub fn evaluateExpression(expression: *const ast.Expression, bindings: *const ExprBindings) ExprEvalError!ExprValue {
    return evaluateExprNode(&expression.node, bindings);
}

fn evaluateExprNode(node: *const ast.ExprNode, bindings: *const ExprBindings) ExprEvalError!ExprValue {
    return switch (node.*) {
        .literal => |lit| evaluateExprLiteral(lit),
        .identifier => |id| evaluateExprIdentifier(id, bindings),
        .binary => |bin| evaluateExprBinaryOp(&bin, bindings),
        .unary => |un| evaluateExprUnaryOp(&un, bindings),
        .field_access => |fa| evaluateExprFieldAccess(&fa, bindings),
        .grouped => |g| evaluateExpression(g, bindings),
        // These node types are structural — they pass through as opaque strings
        // and are handled by the Zig backend, not the interpreter.
        .builtin_call, .array_index, .conditional, .function_call => ExprEvalError.InvalidExpression,
    };
}

fn evaluateExprLiteral(lit: ast.Literal) ExprValue {
    return switch (lit) {
        .number => |n| blk: {
            if (std.fmt.parseInt(i64, n, 10)) |i| {
                break :blk .{ .int_val = i };
            } else |_| {}
            if (std.fmt.parseFloat(f64, n)) |f| {
                break :blk .{ .float_val = f };
            } else |_| {}
            break :blk .{ .int_val = 0 };
        },
        .string => |s| .{ .string_val = s },
        .boolean => |b| .{ .bool_val = b },
    };
}

fn evaluateExprIdentifier(id: []const u8, bindings: *const ExprBindings) ExprEvalError!ExprValue {
    return bindings.get(id) orelse ExprEvalError.UnknownBinding;
}

fn evaluateExprFieldAccess(fa: *const ast.FieldAccess, bindings: *const ExprBindings) ExprEvalError!ExprValue {
    const obj_node = &fa.object.node;
    if (obj_node.* == .identifier) {
        const obj_name = obj_node.identifier;
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ obj_name, fa.field }) catch {
            return ExprEvalError.InvalidExpression;
        };
        if (bindings.get(key)) |val| {
            return val;
        }
    }
    return ExprEvalError.UnknownBinding;
}

fn evaluateExprBinaryOp(bin: *const ast.BinaryOp, bindings: *const ExprBindings) ExprEvalError!ExprValue {
    const left = try evaluateExpression(bin.left, bindings);
    const right = try evaluateExpression(bin.right, bindings);

    return switch (bin.op) {
        .equal => exprCompareEq(left, right),
        .not_equal => exprCompareNeq(left, right),
        .less => exprCompareLt(left, right),
        .greater => exprCompareGt(left, right),
        .less_equal => exprCompareLte(left, right),
        .greater_equal => exprCompareGte(left, right),
        .and_op => .{ .bool_val = left.isTruthy() and right.isTruthy() },
        .or_op => .{ .bool_val = left.isTruthy() or right.isTruthy() },
        .add => exprArithmeticOp(left, right, .add),
        .subtract => exprArithmeticOp(left, right, .sub),
        .multiply => exprArithmeticOp(left, right, .mul),
        .divide => exprArithmeticOp(left, right, .div),
        .modulo => exprArithmeticOp(left, right, .mod),
        .string_concat => ExprEvalError.UnsupportedOperator,
    };
}

fn evaluateExprUnaryOp(un: *const ast.UnaryOp, bindings: *const ExprBindings) ExprEvalError!ExprValue {
    const operand = try evaluateExpression(un.operand, bindings);
    return switch (un.op) {
        .not => .{ .bool_val = !operand.isTruthy() },
        .negate => switch (operand) {
            .int_val => |n| .{ .int_val = -n },
            .float_val => |f| .{ .float_val = -f },
            else => ExprEvalError.TypeMismatch,
        },
    };
}

fn exprCompareEq(left: ExprValue, right: ExprValue) ExprValue {
    const result = switch (left) {
        .bool_val => |l| switch (right) {
            .bool_val => |r| l == r,
            else => false,
        },
        .int_val => |l| switch (right) {
            .int_val => |r| l == r,
            .float_val => |r| @as(f64, @floatFromInt(l)) == r,
            else => false,
        },
        .float_val => |l| switch (right) {
            .int_val => |r| l == @as(f64, @floatFromInt(r)),
            .float_val => |r| l == r,
            else => false,
        },
        .string_val => |l| switch (right) {
            .string_val => |r| std.mem.eql(u8, l, r),
            else => false,
        },
        .null_val => switch (right) {
            .null_val => true,
            else => false,
        },
    };
    return .{ .bool_val = result };
}

fn exprCompareNeq(left: ExprValue, right: ExprValue) ExprValue {
    return .{ .bool_val = !exprCompareEq(left, right).bool_val };
}

fn exprCompareLt(left: ExprValue, right: ExprValue) ExprEvalError!ExprValue {
    return switch (left) {
        .int_val => |l| switch (right) {
            .int_val => |r| .{ .bool_val = l < r },
            .float_val => |r| .{ .bool_val = @as(f64, @floatFromInt(l)) < r },
            else => ExprEvalError.TypeMismatch,
        },
        .float_val => |l| switch (right) {
            .int_val => |r| .{ .bool_val = l < @as(f64, @floatFromInt(r)) },
            .float_val => |r| .{ .bool_val = l < r },
            else => ExprEvalError.TypeMismatch,
        },
        else => ExprEvalError.TypeMismatch,
    };
}

fn exprCompareGt(left: ExprValue, right: ExprValue) ExprEvalError!ExprValue {
    return switch (left) {
        .int_val => |l| switch (right) {
            .int_val => |r| .{ .bool_val = l > r },
            .float_val => |r| .{ .bool_val = @as(f64, @floatFromInt(l)) > r },
            else => ExprEvalError.TypeMismatch,
        },
        .float_val => |l| switch (right) {
            .int_val => |r| .{ .bool_val = l > @as(f64, @floatFromInt(r)) },
            .float_val => |r| .{ .bool_val = l > r },
            else => ExprEvalError.TypeMismatch,
        },
        else => ExprEvalError.TypeMismatch,
    };
}

fn exprCompareLte(left: ExprValue, right: ExprValue) ExprEvalError!ExprValue {
    return .{ .bool_val = !(try exprCompareGt(left, right)).bool_val };
}

fn exprCompareGte(left: ExprValue, right: ExprValue) ExprEvalError!ExprValue {
    return .{ .bool_val = !(try exprCompareLt(left, right)).bool_val };
}

const ExprArithOp = enum { add, sub, mul, div, mod };

fn exprArithmeticOp(left: ExprValue, right: ExprValue, op: ExprArithOp) ExprEvalError!ExprValue {
    return switch (left) {
        .int_val => |l| switch (right) {
            .int_val => |r| exprIntOp(l, r, op),
            .float_val => |r| exprFloatOp(@as(f64, @floatFromInt(l)), r, op),
            else => ExprEvalError.TypeMismatch,
        },
        .float_val => |l| switch (right) {
            .int_val => |r| exprFloatOp(l, @as(f64, @floatFromInt(r)), op),
            .float_val => |r| exprFloatOp(l, r, op),
            else => ExprEvalError.TypeMismatch,
        },
        else => ExprEvalError.TypeMismatch,
    };
}

fn exprIntOp(l: i64, r: i64, op: ExprArithOp) ExprEvalError!ExprValue {
    return .{ .int_val = switch (op) {
        .add => l + r,
        .sub => l - r,
        .mul => l * r,
        .div => if (r == 0) return ExprEvalError.DivisionByZero else @divTrunc(l, r),
        .mod => if (r == 0) return ExprEvalError.DivisionByZero else @mod(l, r),
    } };
}

fn exprFloatOp(l: f64, r: f64, op: ExprArithOp) ExprEvalError!ExprValue {
    return .{ .float_val = switch (op) {
        .add => l + r,
        .sub => l - r,
        .mul => l * r,
        .div => if (r == 0.0) return ExprEvalError.DivisionByZero else l / r,
        .mod => @mod(l, r),
    } };
}

// ============================================================================
// FLOW EXECUTION HELPERS
// ============================================================================

/// Evaluate a simple expression against the environment
/// Handles: literals ("hello"), bindings (r), field access (r.message)
pub fn evaluateExpr(expr_str: []const u8, env: *Environment, allocator: std.mem.Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, expr_str, " \t");

    // String literal - return without quotes
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }

    // Check for field access (binding.field)
    if (std.mem.indexOf(u8, trimmed, ".")) |dot_pos| {
        const binding_name = trimmed[0..dot_pos];
        const field_name = trimmed[dot_pos + 1 ..];

        if (env.get(binding_name)) |bound_value| {
            // Look up field in bound value
            for (bound_value.fields) |fv| {
                if (std.mem.eql(u8, fv.name, field_name)) {
                    return try fieldValueToString(fv.value, allocator);
                }
            }
            // Field not found in dispatcher-provided fields
            // Return placeholder - dispatcher should have included this field
            return try std.fmt.allocPrint(allocator, "<{s}.{s}>", .{ binding_name, field_name });
        }
        return try std.fmt.allocPrint(allocator, "<unbound:{s}>", .{binding_name});
    }

    // Simple binding reference
    if (env.get(trimmed)) |bound_value| {
        // Return the branch name or first field value
        if (bound_value.fields.len > 0) {
            return try fieldValueToString(bound_value.fields[0].value, allocator);
        }
        return bound_value.branch;
    }

    // Return as-is (number, boolean, etc.)
    return try allocator.dupe(u8, trimmed);
}

pub fn fieldValueToString(fv: FieldValue, allocator: std.mem.Allocator) ![]const u8 {
    return switch (fv) {
        .string_val => |s| allocator.dupe(u8, s),
        .bool_val => |b| if (b) allocator.dupe(u8, "true") else allocator.dupe(u8, "false"),
        .int_val => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float_val => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
    };
}

pub fn fieldValueToExprValue(fv: FieldValue) ExprValue {
    return switch (fv) {
        .string_val => |s| .{ .string_val = s },
        .bool_val => |b| .{ .bool_val = b },
        .int_val => |i| .{ .int_val = i },
        .float_val => |f| .{ .float_val = f },
    };
}

// ============================================================================
// FLOW EXECUTION - The core interpreter loop
// ============================================================================

pub const ExecuteFlowError = error{
    NoDispatcher,
    NoBranchMatch,
    UnsupportedNode,
    OutOfMemory,
};

/// Execute a single flow node, returning the final value
pub fn executeFlow(
    flow: *const ast.Flow,
    ctx: *InterpreterContext,
    expr_parser_module: anytype, // ExpressionParser module for parsing conditions
) ExecuteFlowError!Value {
    const inv = &flow.invocation;

    // Build invocation for dispatcher
    var dispatch_result: DispatchResult = undefined;

    // =========================================================================
    // SPECIAL HANDLING: Control flow (~if, ~for)
    // Recognized as both bare (if) and qualified (std.control:if)
    // =========================================================================
    const is_if = (inv.path.module_qualifier == null and
        inv.path.segments.len == 1 and
        std.mem.eql(u8, inv.path.segments[0], "if")) or
        (inv.path.module_qualifier != null and
        std.mem.eql(u8, inv.path.module_qualifier.?, "std.control") and
        inv.path.segments.len == 1 and
        std.mem.eql(u8, inv.path.segments[0], "if"));

    const is_for = (inv.path.module_qualifier == null and
        inv.path.segments.len == 1 and
        std.mem.eql(u8, inv.path.segments[0], "for")) or
        (inv.path.module_qualifier != null and
        std.mem.eql(u8, inv.path.module_qualifier.?, "std.control") and
        inv.path.segments.len == 1 and
        std.mem.eql(u8, inv.path.segments[0], "for"));

    if (is_if) {
        log.debug("[INTERPRETER] Detected ~if, evaluating condition\n", .{});

        // Get expression from the first arg (should be the condition)
        var condition_result: bool = false;

        if (inv.args.len > 0) {
            const first_arg = &inv.args[0];

            // Get expression text - from CapturedExpression if available, else from value
            const expr_text = if (first_arg.expression_value) |captured|
                captured.text
            else
                first_arg.value;

            {
                // Runtime parsing: parse the expression string using ExpressionParser
                log.debug("[INTERPRETER] Parsing expression: '{s}'\n", .{expr_text});

                // Quick check for simple literals first
                if (std.mem.eql(u8, expr_text, "true")) {
                    condition_result = true;
                } else if (std.mem.eql(u8, expr_text, "false")) {
                    condition_result = false;
                } else {
                    // Parse complex expression using ExpressionParser
                    var expr_parser = expr_parser_module.ExpressionParser.init(ctx.allocator, expr_text);
                    defer expr_parser.deinit();

                    if (expr_parser.parse()) |parsed_expr| {
                        // Evaluate the parsed expression against our bindings
                        if (evaluateExpression(parsed_expr, ctx.expr_bindings)) |eval_result| {
                            condition_result = eval_result.isTruthy();
                            log.debug("[INTERPRETER] Expression evaluated to: {}\n", .{condition_result});
                        } else |err| {
                            log.debug("[INTERPRETER] Expression eval error: {s}\n", .{@errorName(err)});
                            condition_result = false;
                        }
                    } else |parse_err| {
                        log.debug("[INTERPRETER] Expression parse error: {s}\n", .{@errorName(parse_err)});
                        // Fallback: try as simple identifier binding
                        if (ctx.expr_bindings.get(expr_text)) |val| {
                            condition_result = val.isTruthy();
                        } else {
                            condition_result = expr_text.len > 0;
                        }
                    }
                }
                log.debug("[INTERPRETER] Condition (from string '{s}'): {}\n", .{ expr_text, condition_result });
            }
        }

        // Set the branch based on condition result
        dispatch_result.branch = if (condition_result) "then" else "else";
        dispatch_result.fields = &[_]NamedField{};
        log.debug("[INTERPRETER] ~if taking branch: | {s} |>\n", .{dispatch_result.branch});
    } else if (is_for) {
        // =====================================================================
        // SPECIAL HANDLING: ~for - Runtime loop
        // ~for(0..N) | each i |> body | done |> after
        // =====================================================================

        // Parse range from first arg (format: "start..end")
        var start: i64 = 0;
        var end: i64 = 0;

        if (inv.args.len > 0) {
            const range_str = inv.args[0].value;
            if (std.mem.indexOf(u8, range_str, "..")) |dot_pos| {
                start = std.fmt.parseInt(i64, range_str[0..dot_pos], 10) catch 0;
                end = std.fmt.parseInt(i64, range_str[dot_pos + 2 ..], 10) catch 0;
            }
        }

        // Find | each | and | done | continuations
        var each_cont: ?*const ast.Continuation = null;
        var done_cont: ?*const ast.Continuation = null;

        for (flow.continuations) |*cont| {
            if (std.mem.eql(u8, cont.branch, "each")) {
                each_cont = cont;
            } else if (std.mem.eql(u8, cont.branch, "done")) {
                done_cont = cont;
            }
        }

        // Execute | each | continuation for each iteration
        if (each_cont) |cont| {
            var i = start;
            while (i < end) : (i += 1) {
                // Bind loop variable if there's a binding
                if (cont.binding) |binding_name| {
                    var iter_buf: [32]u8 = undefined;
                    const iter_str = std.fmt.bufPrint(&iter_buf, "{d}", .{i}) catch "0";
                    const iter_value = Value{
                        .branch = "each",
                        .fields = &[_]NamedField{.{ .name = "value", .value = .{ .string_val = iter_str } }},
                    };
                    ctx.env.bind(binding_name, iter_value) catch return ExecuteFlowError.OutOfMemory;

                    // Also add to expr_bindings for nested conditions
                    ctx.expr_bindings.set(binding_name, .{ .int_val = i }) catch return ExecuteFlowError.OutOfMemory;
                }

                // Execute the body if there's a next node
                if (cont.node) |node| {
                    switch (node) {
                        .invocation => |next_inv| {
                            const next_flow = ast.Flow{
                                .invocation = next_inv,
                                .continuations = cont.continuations,
                                .module = flow.module,
                            };
                            _ = try executeFlow(&next_flow, ctx, expr_parser_module);
                        },
                        .branch_constructor => {
                            // Branch constructor in for body - nothing to do
                        },
                        else => {},
                    }
                }
            }
        }

        // After loop, take | done | branch
        dispatch_result.branch = "done";
        dispatch_result.fields = &[_]NamedField{};

        // If there's a done continuation with a node, follow it
        if (done_cont) |cont| {
            if (cont.node) |node| {
                switch (node) {
                    .invocation => |next_inv| {
                        const next_flow = ast.Flow{
                            .invocation = next_inv,
                            .continuations = cont.continuations,
                            .module = flow.module,
                        };
                        return try executeFlow(&next_flow, ctx, expr_parser_module);
                    },
                    .branch_constructor => |bc| {
                        var fields = ctx.allocator.alloc(NamedField, bc.fields.len) catch return ExecuteFlowError.OutOfMemory;
                        for (bc.fields, 0..) |field, idx| {
                            const value = if (field.expression_str) |expr|
                                FieldValue{ .string_val = evaluateExpr(expr, ctx.env, ctx.allocator) catch return ExecuteFlowError.OutOfMemory }
                            else
                                FieldValue{ .string_val = ctx.allocator.dupe(u8, field.name) catch return ExecuteFlowError.OutOfMemory };
                            fields[idx] = .{
                                .name = ctx.allocator.dupe(u8, field.name) catch return ExecuteFlowError.OutOfMemory,
                                .value = value,
                            };
                        }
                        return Value{
                            .branch = ctx.allocator.dupe(u8, bc.branch_name) catch return ExecuteFlowError.OutOfMemory,
                            .fields = fields,
                        };
                    },
                    else => {},
                }
            }
        }

        return Value.fromDispatch(dispatch_result.branch, dispatch_result.fields);
    } else {
        // Normal dispatch for other events
        if (ctx.dispatcher) |dispatcher| {
            // Evaluate args against environment before dispatching
            // This resolves binding references like "v.num" to actual values
            var evaluated_args = ctx.allocator.alloc(ast.Arg, inv.args.len) catch return ExecuteFlowError.OutOfMemory;
            for (inv.args, 0..) |arg, i| {
                evaluated_args[i] = ast.Arg{
                    .name = arg.name,
                    .value = evaluateExpr(arg.value, ctx.env, ctx.allocator) catch return ExecuteFlowError.OutOfMemory,
                    .source_value = arg.source_value,
                    .expression_value = arg.expression_value,
                    .parsed_expression = arg.parsed_expression,
                };
            }

            // Create invocation with evaluated args
            var evaluated_inv = inv.*;
            evaluated_inv.args = evaluated_args;

            dispatcher(&evaluated_inv, &dispatch_result) catch return ExecuteFlowError.NoDispatcher;
        } else {
            return ExecuteFlowError.NoDispatcher;
        }
    }

    // If no continuations, just return the dispatch result
    if (flow.continuations.len == 0) {
        return Value.fromDispatch(
            dispatch_result.branch,
            dispatch_result.fields,
        );
    }

    // Find matching continuation
    for (flow.continuations) |cont| {
        if (std.mem.eql(u8, cont.branch, dispatch_result.branch)) {
            // Bind the result if there's a binding name
            if (cont.binding) |binding_name| {
                const bound_value = Value.fromDispatch(
                    dispatch_result.branch,
                    dispatch_result.fields,
                );
                ctx.env.bind(binding_name, bound_value) catch return ExecuteFlowError.OutOfMemory;

                // Also populate expr_bindings for ~if conditions
                // The binding itself gets the branch name as a string
                ctx.expr_bindings.set(binding_name, .{ .string_val = dispatch_result.branch }) catch return ExecuteFlowError.OutOfMemory;

                // If we have fields, add them as binding.field entries
                for (bound_value.fields) |fv| {
                    var field_key_buf: [256]u8 = undefined;
                    const field_key = std.fmt.bufPrint(&field_key_buf, "{s}.{s}", .{ binding_name, fv.name }) catch continue;
                    const field_key_owned = ctx.allocator.dupe(u8, field_key) catch continue;
                    ctx.expr_bindings.set(field_key_owned, fieldValueToExprValue(fv.value)) catch continue;
                }
            }

            // If there's a next node, execute it
            if (cont.node) |node| {
                switch (node) {
                    .invocation => |next_inv| {
                        // Create a synthetic flow for the next invocation
                        const next_flow = ast.Flow{
                            .invocation = next_inv,
                            .continuations = cont.continuations,
                            .module = flow.module,
                        };
                        return executeFlow(&next_flow, ctx, expr_parser_module);
                    },
                    .terminal => {
                        // End of flow - return current dispatch result
                        return Value.fromDispatch(
                            dispatch_result.branch,
                            dispatch_result.fields,
                        );
                    },
                    .branch_constructor => |bc| {
                        // Construct a new value from the branch constructor!
                        var fields = ctx.allocator.alloc(NamedField, bc.fields.len) catch return ExecuteFlowError.OutOfMemory;
                        for (bc.fields, 0..) |field, i| {
                            const value = if (field.expression_str) |expr|
                                FieldValue{ .string_val = evaluateExpr(expr, ctx.env, ctx.allocator) catch return ExecuteFlowError.OutOfMemory }
                            else
                                FieldValue{ .string_val = ctx.allocator.dupe(u8, field.name) catch return ExecuteFlowError.OutOfMemory };

                            fields[i] = .{
                                .name = ctx.allocator.dupe(u8, field.name) catch return ExecuteFlowError.OutOfMemory,
                                .value = value,
                            };
                        }

                        return Value{
                            .branch = ctx.allocator.dupe(u8, bc.branch_name) catch return ExecuteFlowError.OutOfMemory,
                            .fields = fields,
                        };
                    },
                    else => {
                        // TODO: Handle labels, derefs
                        return ExecuteFlowError.UnsupportedNode;
                    },
                }
            } else {
                // No next node - return current dispatch result
                return Value.fromDispatch(
                    dispatch_result.branch,
                    dispatch_result.fields,
                );
            }
        }
    }

    return ExecuteFlowError.NoBranchMatch;
}

// ============================================================================
// HIGH-LEVEL RUN/EVAL - Entry points for interpreting Koru
// ============================================================================

pub const RunResult = union(enum) {
    result: struct { value: Value },
    parse_error: struct { message: []const u8, line: u32, column: u32 },
    validation_error: struct { message: []const u8 },
    dispatch_error: struct { event_name: []const u8, message: []const u8 },
};

pub const EvalResult = union(enum) {
    result: struct { value: Value },
    validation_error: struct { message: []const u8 },
    dispatch_error: struct { event_name: []const u8, message: []const u8 },
};

/// Run Koru source code - parses and executes in one step.
/// Requires parser_module (koru_parser) to be passed in.
pub fn runSource(
    source: []const u8,
    dispatcher: DispatchFn,
    parser_module: anytype,
    errors_module: anytype,
) RunResult {
    log.debug("[INTERPRETER] Parsing source ({d} bytes)\n", .{source.len});

    const allocator = InterpreterThreadState.prepare();

    // Create error reporter
    var reporter = errors_module.ErrorReporter.init(
        allocator,
        "interpreter",
        source,
    ) catch {
        return .{ .parse_error = .{
            .message = "Failed to initialize error reporter",
            .line = 0,
            .column = 0,
        } };
    };
    defer reporter.deinit();

    // Initialize parser
    var parser = parser_module.Parser.init(
        allocator,
        source,
        "runtime_input",
        &[_][]const u8{}, // No compiler flags
        null, // No resolver
    ) catch {
        return .{ .parse_error = .{
            .message = "Failed to initialize parser",
            .line = 0,
            .column = 0,
        } };
    };
    defer parser.deinit();

    // Parse!
    const parse_result = parser.parse() catch {
        // Get error details from reporter
        if (parser.reporter.hasErrors()) {
            const err = parser.reporter.errors.items[0];
            return .{ .parse_error = .{
                .message = err.message,
                .line = @intCast(err.location.line),
                .column = @intCast(err.location.column),
            } };
        }
        return .{ .parse_error = .{
            .message = "Parse failed",
            .line = 0,
            .column = 0,
        } };
    };

    log.debug("[INTERPRETER] Parsed {d} items\n", .{parse_result.source_file.items.len});

    // Find the first flow to execute
    var flow_to_run: ?*const ast.Flow = null;
    for (parse_result.source_file.items) |*item| {
        if (item.* == .flow) {
            flow_to_run = &item.flow;
            break;
        }
    }

    if (flow_to_run == null) {
        return .{ .parse_error = .{
            .message = "No flow found in source",
            .line = 0,
            .column = 0,
        } };
    }

    const flow = flow_to_run.?;
    log.debug("[INTERPRETER] Found flow to execute\n", .{});

    // Validation pass
    if (validateFlow(flow, allocator)) |validation_err| {
        log.debug("[INTERPRETER] Validation failed: {s} (binding: {s})\n", .{ validation_err.message, validation_err.binding_name });
        return .{ .validation_error = .{
            .message = validation_err.message,
        } };
    }
    log.debug("[INTERPRETER] Validation passed\n", .{});

    // Create environment and context
    const env = &InterpreterThreadState.env;
    const expr_bindings = &InterpreterThreadState.expr_bindings;

    var ctx = InterpreterContext{
        .env = env,
        .expr_bindings = expr_bindings,
        .allocator = allocator,
        .dispatcher = dispatcher,
    };

    // Execute the flow!
    const result_value = executeFlow(flow, &ctx, parser_module) catch |err| {
        // Build event name for error reporting
        const inv = &flow.invocation;
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        if (inv.path.module_qualifier) |mq| {
            @memcpy(name_buf[name_len..][0..mq.len], mq);
            name_len += mq.len;
            name_buf[name_len] = ':';
            name_len += 1;
        }
        for (inv.path.segments, 0..) |seg, i| {
            if (i > 0) {
                name_buf[name_len] = '.';
                name_len += 1;
            }
            @memcpy(name_buf[name_len..][0..seg.len], seg);
            name_len += seg.len;
        }

        return .{ .dispatch_error = .{
            .event_name = name_buf[0..name_len],
            .message = @errorName(err),
        } };
    };

    const stable_value = result_value.clonePersistent();
    log.debug("[INTERPRETER] Execution complete, branch: {s}\n", .{stable_value.branch});
    return .{ .result = .{ .value = stable_value } };
}

/// Fast path: parse and execute a single flow using the lightweight flow parser.
/// No type registry, module resolver, or full parser initialization.
/// Falls back to runSource() if the flow parser returns an error (e.g., complex input).
pub fn runSourceFast(
    source: []const u8,
    dispatcher: DispatchFn,
    parser_module: anytype,
    errors_module: anytype,
    expr_parser_module: anytype,
) RunResult {
    const flow_parser = @import("flow_parser");

    log.debug("[INTERPRETER] Fast-path parsing source ({d} bytes)\n", .{source.len});

    const allocator = InterpreterThreadState.prepare();

    // Try the lightweight flow parser first
    const parse_result = flow_parser.parseFlow(allocator, source);
    switch (parse_result) {
        .err => |e| {
            log.debug("[INTERPRETER] Fast-path parse failed: {s}, falling back to full parser\n", .{e.message});
            // Fall back to the full parser
            return runSource(source, dispatcher, parser_module, errors_module);
        },
        .flow => |flow| {
            log.debug("[INTERPRETER] Fast-path parse succeeded\n", .{});

            // Validation pass
            if (validateFlow(&flow, allocator)) |validation_err| {
                log.debug("[INTERPRETER] Validation failed: {s} (binding: {s})\n", .{ validation_err.message, validation_err.binding_name });
                return .{ .validation_error = .{
                    .message = validation_err.message,
                } };
            }
            log.debug("[INTERPRETER] Validation passed\n", .{});

            // Create environment and context
            const env = &InterpreterThreadState.env;
            const expr_bindings = &InterpreterThreadState.expr_bindings;

            var ctx = InterpreterContext{
                .env = env,
                .expr_bindings = expr_bindings,
                .allocator = allocator,
                .dispatcher = dispatcher,
            };

            // Execute the flow
            const result_value = executeFlow(&flow, &ctx, expr_parser_module) catch |err| {
                const inv = &flow.invocation;
                var name_buf: [256]u8 = undefined;
                var name_len: usize = 0;
                if (inv.path.module_qualifier) |mq| {
                    @memcpy(name_buf[name_len..][0..mq.len], mq);
                    name_len += mq.len;
                    name_buf[name_len] = ':';
                    name_len += 1;
                }
                for (inv.path.segments, 0..) |seg, i| {
                    if (i > 0) {
                        name_buf[name_len] = '.';
                        name_len += 1;
                    }
                    @memcpy(name_buf[name_len..][0..seg.len], seg);
                    name_len += seg.len;
                }

                return .{ .dispatch_error = .{
                    .event_name = name_buf[0..name_len],
                    .message = @errorName(err),
                } };
            };

            const stable_value = result_value.clonePersistent();
            log.debug("[INTERPRETER] Fast-path execution complete, branch: {s}\n", .{stable_value.branch});
            return .{ .result = .{ .value = stable_value } };
        },
    }
}

/// Cached fast path: reuse parsed flow when the source string matches.
/// Falls back to runSource() if parsing fails.
pub fn runSourceFastCached(
    source: []const u8,
    dispatcher: DispatchFn,
    parser_module: anytype,
    errors_module: anytype,
    expr_parser_module: anytype,
) RunResult {
    log.debug("[INTERPRETER] Cached fast-path parsing source ({d} bytes)\n", .{source.len});

    const allocator = InterpreterThreadState.prepare();
    const cached_flow = InterpreterFlowCache.getOrParse(source) orelse {
        return runSource(source, dispatcher, parser_module, errors_module);
    };

    // Validation pass
    if (validateFlow(cached_flow, allocator)) |validation_err| {
        log.debug("[INTERPRETER] Validation failed: {s} (binding: {s})\n", .{ validation_err.message, validation_err.binding_name });
        return .{ .validation_error = .{
            .message = validation_err.message,
        } };
    }

    const env = &InterpreterThreadState.env;
    const expr_bindings = &InterpreterThreadState.expr_bindings;

    var ctx = InterpreterContext{
        .env = env,
        .expr_bindings = expr_bindings,
        .allocator = allocator,
        .dispatcher = dispatcher,
    };

    const result_value = executeFlow(cached_flow, &ctx, expr_parser_module) catch |err| {
        const inv = &cached_flow.invocation;
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        if (inv.path.module_qualifier) |mq| {
            @memcpy(name_buf[name_len..][0..mq.len], mq);
            name_len += mq.len;
            name_buf[name_len] = ':';
            name_len += 1;
        }
        for (inv.path.segments, 0..) |seg, i| {
            if (i > 0) {
                name_buf[name_len] = '.';
                name_len += 1;
            }
            @memcpy(name_buf[name_len..][0..seg.len], seg);
            name_len += seg.len;
        }

        return .{ .dispatch_error = .{
            .event_name = name_buf[0..name_len],
            .message = @errorName(err),
        } };
    };

    const stable_value = result_value.clonePersistent();
    log.debug("[INTERPRETER] Cached fast-path execution complete, branch: {s}\n", .{stable_value.branch});
    return .{ .result = .{ .value = stable_value } };
}

/// Execute a pre-parsed flow AST - the fast path with no parsing overhead.
pub fn evalFlow(
    flow: *const ast.Flow,
    dispatcher: DispatchFn,
    expr_parser_module: anytype,
) EvalResult {
    log.debug("[EVAL] Starting execution of pre-parsed flow\n", .{});

    const allocator = InterpreterThreadState.prepare();

    // Validation pass
    if (validateFlow(flow, allocator)) |validation_err| {
        log.debug("[EVAL] Validation failed: {s} (binding: {s})\n", .{ validation_err.message, validation_err.binding_name });
        return .{ .validation_error = .{
            .message = validation_err.message,
        } };
    }
    log.debug("[EVAL] Validation passed\n", .{});

    // Create environment and context
    const env = &InterpreterThreadState.env;
    const expr_bindings = &InterpreterThreadState.expr_bindings;

    var ctx = InterpreterContext{
        .env = env,
        .expr_bindings = expr_bindings,
        .allocator = allocator,
        .dispatcher = dispatcher,
    };

    // Execute the flow!
    const result_value = executeFlow(flow, &ctx, expr_parser_module) catch |err| {
        // Build event name for error reporting
        const inv = &flow.invocation;
        var name_buf: [256]u8 = undefined;
        var name_len: usize = 0;
        if (inv.path.module_qualifier) |mq| {
            @memcpy(name_buf[name_len..][0..mq.len], mq);
            name_len += mq.len;
            name_buf[name_len] = ':';
            name_len += 1;
        }
        for (inv.path.segments, 0..) |seg, i| {
            if (i > 0) {
                name_buf[name_len] = '.';
                name_len += 1;
            }
            @memcpy(name_buf[name_len..][0..seg.len], seg);
            name_len += seg.len;
        }

        return .{ .dispatch_error = .{
            .event_name = name_buf[0..name_len],
            .message = @errorName(err),
        } };
    };

    const stable_value = result_value.clonePersistent();
    log.debug("[EVAL] Execution complete, branch: {s}\n", .{stable_value.branch});
    return .{ .result = .{ .value = stable_value } };
}
