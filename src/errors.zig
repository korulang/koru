const std = @import("std");

pub const ErrorCode = enum(u16) {
    // Construct errors
    KORU001, // Unknown construct after ~
    KORU002, // Module not found (import resolution failed)
    KORU010, // Stray continuation (| without context)
    
    // Branch errors
    KORU020, // Duplicate branch in event
    KORU021, // Unknown branch in continuation
    KORU022, // Missing required branch
    
    // Shape errors
    KORU030, // Shape mismatch
    KORU031, // Payload type mismatch
    KORU032, // Cannot auto-discharge outer-scope resource inside loop
    KORU033, // Invalid phantom annotation (e.g., obligation issuance on input)
    SHAPE001, // Inconsistent branch shapes in subflow
    SHAPE002, // Duplicate branch handler at same level (indentation error)
    
    // Name resolution errors
    KORU040, // Unknown event/proc/subflow
    KORU041, // Unknown label
    KORU042, // Duplicate label
    KORU043, // Label shape mismatch
    KORU044, // Private event access from another module
    KORU045, // Label requires parameters (pre-invocation label)
    KORU046, // Label does not accept parameters (post-invocation label)
    
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
    KORU083, // [!] annotation on multi-branch event (must be single-outcome)

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
    /// How many characters the caret should span. Default 1 (point at the
    /// single column). Use larger values to highlight a multi-char token like
    /// `|>` (span = 2). The caret block prints `^` repeated span_length times.
    span_length: usize = 1,
    /// True when this error originates inside the auto-injected compiler
    /// bootstrap prelude — content the user did not write. Renderers should
    /// preview from the bootstrap source slice rather than the user source so
    /// the user sees the line they're actually being told about.
    is_bootstrap: bool = false,
    /// 1-based line within the bootstrap prelude. Only meaningful when
    /// `is_bootstrap` is true.
    bootstrap_line: usize = 0,

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
    /// Source lines for the user-facing preview block. After setUserSource,
    /// these are the user's original lines (no injected prelude). Indexed by
    /// user-coordinate `line - 1`.
    source_lines: [][]const u8,
    /// Source lines for the auto-injected bootstrap prelude. Populated by
    /// setUserSource. Used to render previews for errors that originate inside
    /// the prelude (the user didn't write those lines, but we still need to
    /// show what was rejected).
    bootstrap_source_lines: ?[][]const u8 = null,
    file_name: []const u8,
    /// Number of injected lines prepended to the parsed source before parsing
    /// (e.g. the `~import "$std/compiler"` bootstrap line). The parser sees
    /// line numbers in INJECTED coordinates; we translate to user coordinates
    /// (subtract this count) when storing errors so user output is correct.
    /// 0 means no injection — translation is a no-op.
    injection_line_count: usize = 0,

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

    /// Reconfigure the reporter to render previews from `user_source` (the
    /// original file content, without any injected prelude) and translate
    /// stored line numbers back to user coordinates by subtracting
    /// `injection_line_count`. The current `source_lines` is preserved as
    /// `bootstrap_source_lines` so previews for errors that originate inside
    /// the prelude can still show what the parser rejected. Call this after
    /// Parser.init when the caller prepended lines to the parsed source.
    pub fn setUserSource(self: *ErrorReporter, user_source: []const u8, injection_line_count: usize) !void {
        var lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        var iter = std.mem.splitScalar(u8, user_source, '\n');
        while (iter.next()) |line| {
            try lines.append(self.allocator, line);
        }
        // Preserve the previously-built (full=injected) source_lines as the
        // bootstrap preview slice. The user_source slice gets a fresh split.
        self.bootstrap_source_lines = self.source_lines;
        self.source_lines = try lines.toOwnedSlice(self.allocator);
        self.injection_line_count = injection_line_count;
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
        if (self.bootstrap_source_lines) |bsl| self.allocator.free(bsl);
    }

    const LineClass = struct {
        /// Line number to render in the error output. For bootstrap errors,
        /// this is 0 — the user sees `:0` to signal "before your file starts".
        line: usize,
        is_bootstrap: bool,
        /// 1-based bootstrap line for preview lookup. Only set when
        /// `is_bootstrap` is true.
        bootstrap_line: usize,
    };

    /// Classify an injected-coordinate line number. Lines in (0, injection_line_count]
    /// originate inside the auto-injected prelude (the user didn't write them);
    /// lines beyond that translate down to user coordinates.
    fn classifyLine(self: *ErrorReporter, line: usize) LineClass {
        if (line == 0) return .{ .line = 0, .is_bootstrap = false, .bootstrap_line = 0 };
        if (line <= self.injection_line_count) {
            return .{ .line = 0, .is_bootstrap = true, .bootstrap_line = line };
        }
        return .{ .line = line - self.injection_line_count, .is_bootstrap = false, .bootstrap_line = 0 };
    }

    pub fn addError(self: *ErrorReporter, code: ErrorCode, line: usize, column: usize, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const cls = self.classifyLine(line);

        // Deduplicate: don't add if exact same error already exists
        for (self.errors.items) |existing| {
            if (existing.code == code and
                existing.location.line == cls.line and
                existing.location.column == column and
                existing.is_bootstrap == cls.is_bootstrap and
                existing.bootstrap_line == cls.bootstrap_line and
                std.mem.eql(u8, existing.message, message)) {
                self.allocator.free(message);
                return;
            }
        }

        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = cls.line,
                .column = column,
                .file = self.file_name,
            },
            .hint = null,
            .is_bootstrap = cls.is_bootstrap,
            .bootstrap_line = cls.bootstrap_line,
        });
    }

    /// Like addError, but uses the full SourceLocation (including file) from the caller
    /// instead of the reporter's file_name. Use this when errors can originate from
    /// multiple files (e.g. shape_checker validating flows with per-flow locations).
    /// Line translation only applies when the location's file matches our file_name —
    /// errors from imported files are already in their own user coordinates.
    pub fn addErrorAtLocation(self: *ErrorReporter, code: ErrorCode, location: SourceLocation, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        var loc = location;
        var is_bootstrap = false;
        var bootstrap_line: usize = 0;
        if (std.mem.eql(u8, loc.file, self.file_name)) {
            const cls = self.classifyLine(loc.line);
            loc.line = cls.line;
            is_bootstrap = cls.is_bootstrap;
            bootstrap_line = cls.bootstrap_line;
        }
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = loc,
            .hint = null,
            .is_bootstrap = is_bootstrap,
            .bootstrap_line = bootstrap_line,
        });
    }

    pub fn addErrorWithHint(self: *ErrorReporter, code: ErrorCode, line: usize, column: usize, comptime fmt: []const u8, args: anytype, comptime hint_fmt: []const u8, hint_args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const hint = try std.fmt.allocPrint(self.allocator, hint_fmt, hint_args);
        const cls = self.classifyLine(line);
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = cls.line,
                .column = column,
                .file = self.file_name,
            },
            .hint = hint,
            .is_bootstrap = cls.is_bootstrap,
            .bootstrap_line = cls.bootstrap_line,
        });
    }

    /// Like addErrorWithHint, but lets the caller declare how many characters
    /// the caret should span (e.g. 2 for `|>`). Use when the error is about a
    /// specific multi-char token and pointing at one column would understate
    /// the offending span.
    pub fn addErrorWithHintAndSpan(
        self: *ErrorReporter,
        code: ErrorCode,
        line: usize,
        column: usize,
        span_length: usize,
        comptime fmt: []const u8,
        args: anytype,
        comptime hint_fmt: []const u8,
        hint_args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        const hint = try std.fmt.allocPrint(self.allocator, hint_fmt, hint_args);
        const cls = self.classifyLine(line);
        try self.errors.append(self.allocator, .{
            .code = code,
            .message = message,
            .location = .{
                .line = cls.line,
                .column = column,
                .file = self.file_name,
            },
            .hint = hint,
            .span_length = span_length,
            .is_bootstrap = cls.is_bootstrap,
            .bootstrap_line = cls.bootstrap_line,
        });
    }

    pub fn printErrors(self: *ErrorReporter, writer: anytype) !void {
        for (self.errors.items) |err| {
            try writer.print("error[{s}]: {s}\n", .{ @tagName(err.code), err.message });
            try writer.print("  --> {s}:{}:{}\n", .{ err.location.file, err.location.line, err.location.column });

            // Pick the right source slice for the preview block. Bootstrap
            // errors render from the auto-injected prelude so the user sees
            // the line they're being told about, even though they didn't
            // write it. Other errors render from the user source.
            const preview: ?struct { line: []const u8, line_no: usize } = blk: {
                if (err.is_bootstrap) {
                    if (self.bootstrap_source_lines) |bsl| {
                        if (err.bootstrap_line > 0 and err.bootstrap_line <= bsl.len) {
                            break :blk .{ .line = bsl[err.bootstrap_line - 1], .line_no = err.location.line };
                        }
                    }
                    break :blk null;
                }
                if (err.location.line > 0 and err.location.line <= self.source_lines.len) {
                    break :blk .{ .line = self.source_lines[err.location.line - 1], .line_no = err.location.line };
                }
                break :blk null;
            };

            if (preview) |p| {
                try writer.print("    |\n", .{});  // Match line number width
                try writer.print("{d: >3} | {s}\n", .{ p.line_no, p.line });
                try writer.print("    | ", .{});  // 4 spaces + " | " = 6 chars to match line prefix

                // Print caret pointing to error location
                // Column is 1-based, so we need column-1 spaces to point at column N
                if (err.location.column > 0) {
                    for (0..err.location.column - 1) |_| {
                        try writer.writeAll(" ");
                    }
                }
                const span = if (err.span_length == 0) 1 else err.span_length;
                for (0..span) |_| {
                    try writer.writeAll("^");
                }
                try writer.writeAll("\n");
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

pub fn moduleNotFound(reporter: *ErrorReporter, line: usize, column: usize, import_path: []const u8) !void {
    try reporter.addErrorWithHint(
        .KORU002,
        line,
        column,
        "module not found: '{s}'",
        .{import_path},
        "check the import path, koru.json paths, and KORU_STDLIB/KORU_PATH environment variables",
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
