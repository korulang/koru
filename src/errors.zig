const std = @import("std");

pub const ErrorCode = enum(u16) {
    // Construct errors
    KORU001, // Unknown construct after ~
    KORU010, // Stray continuation (| without context)
    
    // Branch errors
    KORU020, // Duplicate branch in event
    KORU021, // Unknown branch in continuation
    KORU022, // Missing required branch
    
    // Shape errors
    KORU030, // Shape mismatch
    KORU031, // Payload type mismatch
    SHAPE001, // Inconsistent branch shapes in subflow
    SHAPE002, // Duplicate branch handler at same level (indentation error)
    
    // Name resolution errors
    KORU040, // Unknown event/proc/subflow
    KORU041, // Unknown label
    KORU042, // Duplicate label
    KORU043, // Label shape mismatch
    
    // Proc errors
    KORU050, // Proc without matching event
    KORU051, // Proc returns unknown branch
    KORU052, // Proc payload mismatch
    
    // Subflow errors
    KORU060, // Subflow arity mismatch
    KORU061, // Subflow recursion detected
    
    // First-class event errors
    KORU070, // Cannot determine shape at compile time
    
    // Argument errors
    KORU080, // Missing required field
    KORU081, // Unknown field
    KORU082, // Field type mismatch
    
    // Pipeline errors
    KORU090, // Unhandled split in pipeline
    KORU091, // Invalid use of 'p' symbol
    
    // Parser errors
    PARSE001, // Unexpected end of file
    PARSE002, // Invalid indentation
    PARSE003, // Malformed construct
    PARSE004, // Unbalanced braces
    
    // Type inference errors
    TYPE001, // Branch not found in expected union
    TYPE002, // Branch constructor where union not expected
    TYPE003, // Field type mismatch
    TYPE004, // Missing required field
    TYPE005, // Unexpected field in branch constructor

    // Binding errors
    KORU100, // Unused binding
};

pub const SourceLocation = struct {
    line: usize,
    column: usize,
    file: []const u8,
};

pub const ParseError = struct {
    code: ErrorCode,
    message: []const u8,
    location: SourceLocation,
    hint: ?[]const u8,
    
    pub fn format(
        self: ParseError,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        
        try writer.print("error[{s}]: {s}\n", .{ @tagName(self.code), self.message });
        try writer.print("  --> {s}:{}:{}\n", .{ self.location.file, self.location.line, self.location.column });
        
        if (self.hint) |hint| {
            try writer.print("  hint: {s}\n", .{hint});
        }
    }
};

pub const ErrorReporter = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList(ParseError),
    source_lines: [][]const u8,
    file_name: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, file_name: []const u8, source: []const u8) !ErrorReporter {
        var lines = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        var iter = std.mem.splitScalar(u8, source, '\n');
        while (iter.next()) |line| {
            try lines.append(allocator, line);
        }

        return ErrorReporter{
            .allocator = allocator,
            .errors = try std.ArrayList(ParseError).initCapacity(allocator, 8),
            .source_lines = try lines.toOwnedSlice(allocator),
            .file_name = file_name,
        };
    }
    
    pub fn deinit(self: *ErrorReporter) void {
        for (self.errors.items) |*err| {
            self.allocator.free(err.message);
            if (err.hint) |hint| {
                self.allocator.free(hint);
            }
        }
        self.errors.deinit(self.allocator);
        self.allocator.free(self.source_lines);
    }
    
    pub fn addError(self: *ErrorReporter, code: ErrorCode, line: usize, column: usize, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = line,
                .column = column,
                .file = self.file_name,
            },
            .hint = null,
        });
    }
    
    pub fn addErrorWithHint(self: *ErrorReporter, code: ErrorCode, line: usize, column: usize, comptime fmt: []const u8, args: anytype, comptime hint_fmt: []const u8, hint_args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const hint = try std.fmt.allocPrint(self.allocator, hint_fmt, hint_args);
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = line,
                .column = column,
                .file = self.file_name,
            },
            .hint = hint,
        });
    }
    
    pub fn printErrors(self: *ErrorReporter, writer: anytype) !void {
        for (self.errors.items) |err| {
            try writer.print("error[{s}]: {s}\n", .{ @tagName(err.code), err.message });
            try writer.print("  --> {s}:{}:{}\n", .{ err.location.file, err.location.line, err.location.column });
            
            // Show the source line
            if (err.location.line > 0 and err.location.line <= self.source_lines.len) {
                const line = self.source_lines[err.location.line - 1];
                try writer.print("  |\n", .{});
                try writer.print("{d: >3} | {s}\n", .{ err.location.line, line });
                try writer.print("  | ", .{});
                
                // Print caret pointing to error location
                for (0..err.location.column) |_| {
                    try writer.writeAll(" ");
                }
                try writer.writeAll("^\n");
            }
            
            // Print hint if present
            if (err.hint) |hint| {
                try writer.print("  hint: {s}\n", .{hint});
            }
            
            try writer.writeAll("\n");
        }
    }
    
    pub fn hasErrors(self: *ErrorReporter) bool {
        return self.errors.items.len > 0;
    }
};

// Helper functions for common error messages

pub fn unknownConstruct(reporter: *ErrorReporter, line: usize, column: usize, construct: []const u8) !void {
    try reporter.addErrorWithHint(
        .KORU001,
        line,
        column,
        "unknown Koru construct after '~': '{s}'",
        .{construct},
        "expected event, proc, @label, [Attr], or invocation",
        .{},
    );
}

pub fn strayContinuation(reporter: *ErrorReporter, line: usize, column: usize) !void {
    try reporter.addErrorWithHint(
        .KORU010,
        line,
        column,
        "continuation line '|' without an open Koru construct",
        .{},
        "place after an event/proc/flow start",
        .{},
    );
}

pub fn duplicateBranch(reporter: *ErrorReporter, line: usize, column: usize, branch: []const u8, event: []const u8) !void {
    try reporter.addErrorWithHint(
        .KORU020,
        line,
        column,
        "duplicate branch '{s}' in event '{s}'",
        .{ branch, event },
        "rename or remove duplicate",
        .{},
    );
}

pub fn unknownBranch(reporter: *ErrorReporter, line: usize, column: usize, branch: []const u8, event: []const u8, valid_branches: []const []const u8) !void {
    var hint_buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&hint_buf);
    try stream.writer().writeAll("use one of: ");
    for (valid_branches, 0..) |valid, i| {
        if (i > 0) try stream.writer().writeAll(", ");
        try stream.writer().writeAll(valid);
    }
    
    try reporter.addErrorWithHint(
        .KORU021,
        line,
        column,
        "continuation branch '{s}' not declared by event '{s}'",
        .{ branch, event },
        "{s}",
        .{stream.getWritten()},
    );
}