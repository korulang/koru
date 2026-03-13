const std = @import("std");
const lexer = @import("lexer");
const ast = @import("ast");

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    MissingClosingParen,
    MissingClosingBracket,
    ExpectedOpenParen,
    ExpectedCloseParen,
    ExpectedElse,
    UnknownOperator,
    InvalidNumber,
    InvalidCharLiteral,
    UnterminatedString,
    InvalidIdentifier,
};

/// Simple expression parser for Koru
/// Supports a minimal set of pure expressions for use in proc contexts:
/// - Arithmetic: +, -, *, /, %
/// - Comparison: ==, !=, <, >, <=, >=
/// - Logical: &&, ||, !
/// - String concat: ++
/// - Field access: .field
/// - Grouping: (expr)

// Re-export AST types for convenience
pub const Expression = ast.Expression;
pub const ExprNode = ast.ExprNode;
pub const Literal = ast.Literal;
pub const BinaryOp = ast.BinaryOp;
pub const UnaryOp = ast.UnaryOp;
pub const FieldAccess = ast.FieldAccess;
pub const BuiltinCall = ast.BuiltinCall;
pub const ArrayIndex = ast.ArrayIndex;
pub const Conditional = ast.Conditional;
pub const FunctionCall = ast.FunctionCall;
pub const BinaryOperator = ast.BinaryOperator;
pub const UnaryOperator = ast.UnaryOperator;

pub const Operator = enum {
    // Arithmetic
    add, // +
    subtract, // -
    multiply, // *
    divide, // /
    modulo, // %

    // Comparison
    equal, // ==
    not_equal, // !=
    less_than, // <
    greater_than, // >
    less_equal, // <=
    greater_equal, // >=

    // Logical
    and_op, // &&
    or_op, // ||
    not_op, // !

    // String
    concat, // ++

    // Unary
    negate, // unary -

    // Convert to AST BinaryOperator
    pub fn toBinaryOp(self: Operator) ?BinaryOperator {
        return switch (self) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
            .modulo => .modulo,
            .equal => .equal,
            .not_equal => .not_equal,
            .less_than => .less,
            .less_equal => .less_equal,
            .greater_than => .greater,
            .greater_equal => .greater_equal,
            .and_op => .and_op,
            .or_op => .or_op,
            .concat => .string_concat,
            .not_op, .negate => null, // These are unary
        };
    }

    // Convert to AST UnaryOperator
    pub fn toUnaryOp(self: Operator) ?UnaryOperator {
        return switch (self) {
            .not_op => .not,
            .negate => .negate,
            else => null, // Not a unary operator
        };
    }
};

const Precedence = enum(u8) {
    lowest = 0,
    logical_or = 1, // ||
    logical_and = 2, // &&
    equality = 3, // ==, !=
    comparison = 4, // <, >, <=, >=
    concat = 5, // ++
    additive = 6, // +, -
    multiplicative = 7, // *, /, %
    unary = 8, // !, -
    call = 9, // function(), .field
    highest = 10,
};

pub const ExpressionParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) ExpressionParser {
        return .{
            .allocator = allocator,
            .input = lexer.trim(input),
            .pos = 0,
        };
    }

    pub fn deinit(self: *ExpressionParser) void {
        _ = self;
    }

    /// Parse an expression string
    pub fn parse(self: *ExpressionParser) ParseError!*Expression {
        return try self.parseExpression(.lowest);
    }

    fn parseExpression(self: *ExpressionParser, min_prec: Precedence) ParseError!*Expression {
        self.skipWhitespace();

        // Parse primary expression
        var left = try self.parsePrimary();

        // Parse binary operators with precedence climbing
        while (self.pos < self.input.len) {
            self.skipWhitespace();

            const op_prec = self.peekPrecedence();
            // Stop if the next operator has lower precedence than our minimum
            // For left-associative operators, we want strictly lower
            if (@intFromEnum(op_prec) <= @intFromEnum(min_prec)) {
                break;
            }

            const op = try self.parseOperator();
            // For left-associative operators, pass the current precedence to recursive call
            const right = try self.parseExpression(op_prec);

            const binary_op = op.toBinaryOp() orelse return error.UnknownOperator;
            const binary = try self.allocator.create(Expression);
            binary.* = .{ .node = .{ .binary = .{
                .op = binary_op,
                .left = left,
                .right = right,
            } } };
            left = binary;
        }

        return left;
    }

    fn parsePrimary(self: *ExpressionParser) ParseError!*Expression {
        self.skipWhitespace();

        // Check for grouped expression
        if (self.peek() == '(') {
            self.advance();
            const expr = try self.parseExpression(.lowest);
            self.skipWhitespace();
            if (self.peek() != ')') {
                return error.MissingClosingParen;
            }
            self.advance();

            const grouped = try self.allocator.create(Expression);
            grouped.* = .{ .node = .{ .grouped = expr } };
            return grouped;
        }

        // Check for unary operators
        if (self.peek() == '!' or self.peek() == '-') {
            const op = if (self.peek() == '!') Operator.not_op else Operator.negate;
            self.advance();
            const operand = try self.parsePrimary();

            const unary_op = op.toUnaryOp() orelse return error.UnknownOperator;
            const unary = try self.allocator.create(Expression);
            unary.* = .{ .node = .{ .unary = .{
                .op = unary_op,
                .operand = operand,
            } } };
            return unary;
        }

        // Check for builtin call (@as, @intCast, etc.)
        if (self.peek() == '@') {
            return try self.parseBuiltinCall();
        }

        // Check for conditional expression (if(cond) then else else_expr)
        if (self.matchKeywordBoundary("if")) {
            return try self.parseConditional();
        }

        // Check for char literal
        if (self.peek() == '\'') {
            return try self.parseCharLiteral();
        }

        // Check for string literal
        if (self.peek() == '"') {
            return try self.parseString();
        }

        // Check for boolean literal
        if (self.matchKeyword("true") or self.matchKeyword("false")) {
            const bool_expr = try self.allocator.create(Expression);
            bool_expr.* = .{ .node = .{ .literal = .{ .boolean = self.matchKeyword("true") } } };
            if (bool_expr.node.literal.boolean) {
                self.pos += 4; // "true"
            } else {
                self.pos += 5; // "false"
            }
            return bool_expr;
        }

        // Check for number or identifier

        // Check if it's a number
        if (std.ascii.isDigit(self.peek()) or
            (self.peek() == '-' and self.pos + 1 < self.input.len and std.ascii.isDigit(self.input[self.pos + 1])))
        {
            return try self.parseNumber();
        }

        // Must be an identifier
        const ident = try self.parseIdentifier();

        var result = try self.allocator.create(Expression);
        result.* = .{ .node = .{ .identifier = ident } };

        // Parse postfix operators: field access, array indexing, function calls
        result = try self.parsePostfix(result);

        return result;
    }

    fn parseString(self: *ExpressionParser) ParseError!*Expression {
        self.advance(); // Skip opening quote
        const start = self.pos;

        while (self.pos < self.input.len and self.peek() != '"') {
            if (self.peek() == '\\') {
                self.advance(); // Skip escape character
                if (self.pos < self.input.len) {
                    self.advance(); // Skip escaped character
                }
            } else {
                self.advance();
            }
        }

        const str = self.input[start..self.pos];

        if (self.peek() != '"') {
            return error.UnterminatedString;
        }
        self.advance(); // Skip closing quote

        const expr = try self.allocator.create(Expression);
        expr.* = .{ .node = .{ .literal = .{ .string = try self.allocator.dupe(u8, str) } } };
        return expr;
    }

    fn parseCharLiteral(self: *ExpressionParser) ParseError!*Expression {
        // Parse single-quoted character literal and emit as numeric literal
        self.advance(); // Skip opening '

        if (self.pos >= self.input.len) {
            return error.UnterminatedString;
        }

        var codepoint: u21 = 0;

        if (self.peek() == '\\') {
            self.advance(); // Skip backslash
            if (self.pos >= self.input.len) {
                return error.InvalidCharLiteral;
            }

            const esc = self.peek();
            self.advance();
            switch (esc) {
                'n' => codepoint = '\n',
                't' => codepoint = '\t',
                'r' => codepoint = '\r',
                '0' => codepoint = 0,
                '\\' => codepoint = '\\',
                '\'' => codepoint = '\'',
                'x' => {
                    // \xNN (2 hex digits)
                    if (self.pos + 1 >= self.input.len) {
                        return error.InvalidCharLiteral;
                    }
                    const hex_slice = self.input[self.pos .. self.pos + 2];
                    const value = std.fmt.parseInt(u8, hex_slice, 16) catch return error.InvalidCharLiteral;
                    codepoint = value;
                    self.pos += 2;
                },
                'u' => {
                    // \u{...}
                    if (self.peek() != '{') {
                        return error.InvalidCharLiteral;
                    }
                    self.advance(); // Skip {
                    const start = self.pos;
                    while (self.pos < self.input.len and self.peek() != '}') {
                        self.advance();
                    }
                    if (self.pos >= self.input.len) {
                        return error.InvalidCharLiteral;
                    }
                    const hex_slice = self.input[start..self.pos];
                    const value = std.fmt.parseInt(u21, hex_slice, 16) catch return error.InvalidCharLiteral;
                    codepoint = value;
                    self.advance(); // Skip }
                },
                else => return error.InvalidCharLiteral,
            }
        } else {
            codepoint = self.peek();
            self.advance();
        }

        // Must close the literal immediately
        if (self.peek() != '\'') {
            return error.InvalidCharLiteral;
        }
        self.advance(); // Skip closing '

        const num_str = try std.fmt.allocPrint(self.allocator, "{d}", .{codepoint});
        const expr = try self.allocator.create(Expression);
        expr.* = .{ .node = .{ .literal = .{ .number = num_str } } };
        return expr;
    }

    fn parseNumber(self: *ExpressionParser) ParseError!*Expression {
        const start = self.pos;

        // Handle negative numbers
        if (self.peek() == '-') {
            self.advance();
        }

        // Parse integer part
        while (self.pos < self.input.len and std.ascii.isDigit(self.peek())) {
            self.advance();
        }

        // Parse decimal part
        if (self.peek() == '.' and self.pos + 1 < self.input.len and std.ascii.isDigit(self.input[self.pos + 1])) {
            self.advance(); // Skip '.'
            while (self.pos < self.input.len and std.ascii.isDigit(self.peek())) {
                self.advance();
            }
        }

        const num = self.input[start..self.pos];

        const expr = try self.allocator.create(Expression);
        expr.* = .{ .node = .{ .literal = .{ .number = try self.allocator.dupe(u8, num) } } };
        return expr;
    }

    fn parseIdentifier(self: *ExpressionParser) ParseError![]const u8 {
        const start = self.pos;

        // Identifier must start with letter or underscore
        if (!std.ascii.isAlphabetic(self.peek()) and self.peek() != '_') {
            return error.InvalidIdentifier;
        }

        while (self.pos < self.input.len) {
            const c = self.peek();
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        return try self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    /// Parse postfix operators: field access (.field), array indexing ([i]),
    /// and function calls (args). These chain left-to-right.
    fn parsePostfix(self: *ExpressionParser, initial: *Expression) ParseError!*Expression {
        var result = initial;
        while (true) {
            self.skipWhitespace();
            if (self.peek() == '.') {
                self.advance();
                const field = try self.parseIdentifier();

                const field_access = try self.allocator.create(Expression);
                field_access.* = .{ .node = .{ .field_access = .{
                    .object = result,
                    .field = field,
                } } };
                result = field_access;
            } else if (self.peek() == '[') {
                self.advance();
                const index = try self.parseExpression(.lowest);
                self.skipWhitespace();
                if (self.peek() != ']') {
                    return error.MissingClosingBracket;
                }
                self.advance();

                const array_index = try self.allocator.create(Expression);
                array_index.* = .{ .node = .{ .array_index = .{
                    .object = result,
                    .index = index,
                } } };
                result = array_index;
            } else if (self.peek() == '(') {
                // Function call
                const args = try self.parseArgList();

                const function_call = try self.allocator.create(Expression);
                function_call.* = .{ .node = .{ .function_call = .{
                    .callee = result,
                    .args = args,
                } } };
                result = function_call;
            } else {
                break;
            }
        }
        return result;
    }

    /// Parse a builtin call: @name(args...)
    fn parseBuiltinCall(self: *ExpressionParser) ParseError!*Expression {
        self.advance(); // skip '@'

        const name = try self.parseIdentifier();

        self.skipWhitespace();
        if (self.peek() != '(') return error.ExpectedOpenParen;
        const args = try self.parseArgList();

        const result = try self.allocator.create(Expression);
        result.* = .{ .node = .{ .builtin_call = .{
            .name = name,
            .args = args,
        } } };
        return result;
    }

    /// Parse a conditional: if(cond) then_expr else else_expr
    fn parseConditional(self: *ExpressionParser) ParseError!*Expression {
        self.pos += 2; // skip "if"
        self.skipWhitespace();

        // Parse condition in parens
        if (self.peek() != '(') return error.ExpectedOpenParen;
        self.advance();
        const condition = try self.parseExpression(.lowest);
        self.skipWhitespace();
        if (self.peek() != ')') return error.ExpectedCloseParen;
        self.advance();

        // Parse then expression
        self.skipWhitespace();
        const then_expr = try self.parseExpression(.lowest);

        // Expect 'else' keyword
        self.skipWhitespace();
        if (!self.matchKeywordBoundary("else")) {
            return error.ExpectedElse;
        }
        self.pos += 4; // skip "else"

        // Parse else expression (may be another if-else)
        self.skipWhitespace();
        const else_expr = try self.parseExpression(.lowest);

        const result = try self.allocator.create(Expression);
        result.* = .{ .node = .{ .conditional = .{
            .condition = condition,
            .then_expr = then_expr,
            .else_expr = else_expr,
        } } };
        return result;
    }

    /// Parse a comma-separated argument list: (expr, expr, ...)
    fn parseArgList(self: *ExpressionParser) ParseError![]const *Expression {
        if (self.peek() != '(') return error.ExpectedOpenParen;
        self.advance(); // skip '('

        var args = try std.ArrayList(*Expression).initCapacity(self.allocator, 0);

        self.skipWhitespace();
        if (self.peek() == ')') {
            self.advance();
            return try args.toOwnedSlice(self.allocator);
        }

        // Parse first argument
        try args.append(self.allocator, try self.parseExpression(.lowest));

        // Parse remaining arguments
        while (true) {
            self.skipWhitespace();
            if (self.peek() == ')') {
                self.advance();
                break;
            }
            if (self.peek() != ',') {
                return error.ExpectedCloseParen;
            }
            self.advance(); // skip ','
            self.skipWhitespace();
            try args.append(self.allocator, try self.parseExpression(.lowest));
        }

        return try args.toOwnedSlice(self.allocator);
    }

    fn parseOperator(self: *ExpressionParser) ParseError!Operator {
        self.skipWhitespace();

        // Two-character operators
        if (self.pos + 1 < self.input.len) {
            const two_char = self.input[self.pos .. self.pos + 2];

            if (std.mem.eql(u8, two_char, "++")) {
                self.pos += 2;
                return .concat;
            } else if (std.mem.eql(u8, two_char, "==")) {
                self.pos += 2;
                return .equal;
            } else if (std.mem.eql(u8, two_char, "!=")) {
                self.pos += 2;
                return .not_equal;
            } else if (std.mem.eql(u8, two_char, "<=")) {
                self.pos += 2;
                return .less_equal;
            } else if (std.mem.eql(u8, two_char, ">=")) {
                self.pos += 2;
                return .greater_equal;
            } else if (std.mem.eql(u8, two_char, "&&")) {
                self.pos += 2;
                return .and_op;
            } else if (std.mem.eql(u8, two_char, "||")) {
                self.pos += 2;
                return .or_op;
            }
        }

        // Single-character operators
        const op = switch (self.peek()) {
            '+' => Operator.add,
            '-' => Operator.subtract,
            '*' => Operator.multiply,
            '/' => Operator.divide,
            '%' => Operator.modulo,
            '<' => Operator.less_than,
            '>' => Operator.greater_than,
            else => return error.UnknownOperator,
        };

        self.advance();
        return op;
    }

    fn peekPrecedence(self: *ExpressionParser) Precedence {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return .lowest;
        }

        // Check two-character operators first
        if (self.pos + 1 < self.input.len) {
            const two_char = self.input[self.pos .. self.pos + 2];

            if (std.mem.eql(u8, two_char, "||")) return .logical_or;
            if (std.mem.eql(u8, two_char, "&&")) return .logical_and;
            if (std.mem.eql(u8, two_char, "==") or std.mem.eql(u8, two_char, "!=")) return .equality;
            if (std.mem.eql(u8, two_char, "<=") or std.mem.eql(u8, two_char, ">=")) return .comparison;
            if (std.mem.eql(u8, two_char, "++")) return .concat;
        }

        // Single-character operators
        return switch (self.peek()) {
            '<', '>' => .comparison,
            '+', '-' => .additive,
            '*', '/', '%' => .multiplicative,
            '.' => .call,
            else => .lowest,
        };
    }

    fn peek(self: *ExpressionParser) u8 {
        if (self.pos >= self.input.len) return 0;
        return self.input[self.pos];
    }

    fn advance(self: *ExpressionParser) void {
        if (self.pos < self.input.len) {
            self.pos += 1;
        }
    }

    fn skipWhitespace(self: *ExpressionParser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.peek())) {
            self.advance();
        }
    }

    fn matchKeyword(self: *ExpressionParser, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos .. self.pos + keyword.len], keyword);
    }

    /// Like matchKeyword but also checks that the next character after the keyword
    /// is not alphanumeric or underscore (word boundary check).
    fn matchKeywordBoundary(self: *ExpressionParser, keyword: []const u8) bool {
        if (!self.matchKeyword(keyword)) return false;
        const end = self.pos + keyword.len;
        if (end >= self.input.len) return true;
        const next = self.input[end];
        return !std.ascii.isAlphanumeric(next) and next != '_';
    }

    fn isRightAssociative(op: Operator) bool {
        _ = op;
        return false; // All our operators are left-associative
    }

    fn incrementPrecedence(prec: Precedence) Precedence {
        const val = @intFromEnum(prec);
        if (val >= @intFromEnum(Precedence.highest)) {
            return .highest;
        }
        return @as(Precedence, @enumFromInt(val + 1));
    }
};

/// Walk the AST and return true if any node is a function_call.
/// Builtin calls (@as, @intCast) are NOT considered function calls.
pub fn containsFunctionCall(expr: *const Expression) bool {
    switch (expr.node) {
        .function_call => return true,
        .literal => return false,
        .identifier => return false,
        .binary => |bin| return containsFunctionCall(bin.left) or containsFunctionCall(bin.right),
        .unary => |un| return containsFunctionCall(un.operand),
        .field_access => |fa| return containsFunctionCall(fa.object),
        .grouped => |g| return containsFunctionCall(g),
        .builtin_call => |bc| {
            for (bc.args) |arg| {
                if (containsFunctionCall(arg)) return true;
            }
            return false;
        },
        .array_index => |ai| return containsFunctionCall(ai.object) or containsFunctionCall(ai.index),
        .conditional => |c| return containsFunctionCall(c.condition) or
            containsFunctionCall(c.then_expr) or
            containsFunctionCall(c.else_expr),
    }
}

/// Convert an expression to a string (for code generation)
pub fn expressionToString(expr: *const Expression, writer: anytype) !void {
    switch (expr.node) {
        .literal => |lit| {
            switch (lit) {
                .number => |n| try writer.print("{s}", .{n}),
                .string => |s| try writer.print("\"{s}\"", .{s}),
                .boolean => |b| try writer.print("{}", .{b}),
            }
        },
        .identifier => |id| try writer.print("{s}", .{id}),
        .binary => |bin| {
            try writer.print("(", .{});
            try expressionToString(bin.left, writer);
            try writer.print(" {s} ", .{binaryOpToString(bin.op)});
            try expressionToString(bin.right, writer);
            try writer.print(")", .{});
        },
        .unary => |un| {
            try writer.print("{s}", .{unaryOpToString(un.op)});
            try expressionToString(un.operand, writer);
        },
        .field_access => |fa| {
            try expressionToString(fa.object, writer);
            try writer.print(".{s}", .{fa.field});
        },
        .grouped => |g| {
            try writer.print("(", .{});
            try expressionToString(g, writer);
            try writer.print(")", .{});
        },
        .builtin_call => |bc| {
            try writer.print("@{s}(", .{bc.name});
            for (bc.args, 0..) |arg, i| {
                if (i > 0) try writer.print(", ", .{});
                try expressionToString(arg, writer);
            }
            try writer.print(")", .{});
        },
        .array_index => |ai| {
            try expressionToString(ai.object, writer);
            try writer.print("[", .{});
            try expressionToString(ai.index, writer);
            try writer.print("]", .{});
        },
        .conditional => |c| {
            try writer.print("if(", .{});
            try expressionToString(c.condition, writer);
            try writer.print(") ", .{});
            try expressionToString(c.then_expr, writer);
            try writer.print(" else ", .{});
            try expressionToString(c.else_expr, writer);
        },
        .function_call => |fc| {
            try expressionToString(fc.callee, writer);
            try writer.print("(", .{});
            for (fc.args, 0..) |arg, i| {
                if (i > 0) try writer.print(", ", .{});
                try expressionToString(arg, writer);
            }
            try writer.print(")", .{});
        },
    }
}

fn binaryOpToString(op: BinaryOperator) []const u8 {
    return switch (op) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .modulo => "%",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .greater => ">",
        .less_equal => "<=",
        .greater_equal => ">=",
        .and_op => "&&",
        .or_op => "||",
        .string_concat => "++",
    };
}

fn unaryOpToString(op: UnaryOperator) []const u8 {
    return switch (op) {
        .not => "!",
        .negate => "-",
    };
}
