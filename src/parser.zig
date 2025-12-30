const std = @import("std");
const ast = @import("ast");
const lexer = @import("lexer");
const errors = @import("errors");
const type_registry = @import("type_registry");
const expression_parser = @import("expression_parser");
const ModuleResolver = @import("module_resolver").ModuleResolver;

const DEBUG = false;  // Set to true for verbose parser logging

/// Parser error set - explicit to avoid circular dependency issues
pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
    UnexpectedEOF,  // Match the actual error used in the code
    InvalidEventDeclaration,
    InvalidProcDeclaration,
    InvalidFlowSyntax,
    InvalidContinuation,
    MissingEventImplementation,
    DuplicateDeclaration,
    TypeRegistryError,
};

/// Result of parsing that includes both the AST and type registry
pub const ParseResult = struct {
    source_file: ast.Program,
    registry: type_registry.TypeRegistry,
    
    pub fn deinit(self: *ParseResult) void {
        self.source_file.deinit();
        self.registry.deinit();
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lines: [][]const u8,
    current: usize,
    reporter: errors.ErrorReporter,

    // Parser state
    context_stack: std.ArrayList(Context),
    // Events can be implemented by procs or subflows
    registry: type_registry.TypeRegistry,  // Type registry for all declarations

    // Flag to indicate if we're parsing the compiler bootstrap library
    // When true, procs in this file cannot use inline flows (metacircular requirement)
    is_compiler_library: bool,

    // FOUNDATIONAL: Module context for all parsed items
    module_name: []const u8,  // Canonical module path (e.g., "input", "lib/fs")

    // Global inline flow counter - must match emitter's global numbering
    inline_flow_counter: u32,

    // Parse mode: false = lenient (continue past errors), true = fail-fast (stop at first error)
    fail_fast: bool,

    // Compiler flags for conditional compilation (e.g., ~[profile]import)
    compiler_flags: []const []const u8,

    // Module resolver for imports (null for bootstrap/help parsing)
    resolver: ?*ModuleResolver,

    const Context = union(enum) {
        top_level,
        in_event,
        in_proc,
        in_subflow_impl,
        in_flow,
        in_continuation: struct {
            branch: []const u8,
            binding: ?[]const u8,
        },
    };

    fn isInProc(self: *Parser) bool {
        // Check if any context in the stack allows full expressions
        // Both procs and subflow impls are implementation code that allows arithmetic/complex expressions
        for (self.context_stack.items) |ctx| {
            switch (ctx) {
                .in_proc, .in_subflow_impl => return true,
                else => {},
            }
        }
        return false;
    }

    /// Get current source location for error reporting and AST metadata
    fn getCurrentLocation(self: *Parser) errors.SourceLocation {
        return self.getLineLocation(self.current, 0);
    }

    /// Get source location for a specific line and indent (column)
    fn getLineLocation(self: *Parser, line_idx: usize, indent: usize) errors.SourceLocation {
        // CRITICAL: Duplicate file string into parse_arena so it survives import_parser.deinit()
        // The reporter.file_name might be a temporary stack string or might get freed when
        // the parser is deinit'd, but AST nodes need the file string to stay alive.
        const file_copy = self.allocator.dupe(u8, self.reporter.file_name) catch {
            // If allocation fails, return a static error string rather than crashing
            return .{
                .file = "<allocation_failed>",
                .line = if (line_idx < self.lines.len) line_idx + 1 else self.lines.len,
                .column = indent,
            };
        };
        return .{
            .file = file_copy,
            .line = if (line_idx < self.lines.len) line_idx + 1 else self.lines.len,
            .column = indent,
        };
    }

    /// Read a source file for [type]"path" syntax
    /// Resolves relative paths from the current file's directory
    fn readSourceFile(self: *Parser, path: []const u8) ![]const u8 {
        const fs = std.fs;

        // Get the directory of the current file being parsed
        const current_file = self.reporter.file_name;
        const dir_end = std.mem.lastIndexOf(u8, current_file, "/") orelse 0;
        const current_dir = if (dir_end > 0) current_file[0..dir_end] else ".";

        // Build full path (relative to current file's directory)
        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = if (path[0] == '/' or path[0] == '~')
            // Absolute path - use as-is
            path
        else blk: {
            // Relative path - resolve from current file's directory
            const written = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ current_dir, path }) catch {
                return error.PathTooLong;
            };
            break :blk written;
        };

        // Open and read the file
        const file = fs.cwd().openFile(full_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            return err;
        };

        return content;
    }

    pub fn init(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8, compiler_flags: []const []const u8, resolver: ?*ModuleResolver) !Parser {
        // Parser init
        var lines_list = try std.ArrayList([]const u8).initCapacity(allocator, 8);
        var iter = std.mem.splitScalar(u8, source, '\n');
        while (iter.next()) |line| {
            try lines_list.append(allocator, line);
        }
        // Lines parsed

        var context_stack = try std.ArrayList(Context).initCapacity(allocator, 8);
        try context_stack.append(allocator, .top_level);

        // Derive module name from file_name
        // Module name is always the filename without .kz extension
        // Examples:
        //   "input.kz" → "input"
        //   "test_lib/graphics.kz" → "graphics"
        //   "koru_std/profiler.kz" → "profiler"
        // This enables circular imports and consistent naming across the codebase
        const basename = std.fs.path.basename(file_name);
        const module_name = blk: {
            // Extract filename without .kz extension
            if (std.mem.endsWith(u8, basename, ".kz")) {
                const name_without_ext = basename[0 .. basename.len - 3];
                break :blk try allocator.dupe(u8, name_without_ext);
            } else {
                // No .kz extension, use basename as-is
                break :blk try allocator.dupe(u8, basename);
            }
        };

        return Parser{
            .allocator = allocator,
            .lines = try lines_list.toOwnedSlice(allocator),
            .current = 0,
            .reporter = try errors.ErrorReporter.init(allocator, file_name, source),
            .context_stack = context_stack,
            // No subflow tracking needed - events are the interface
            .registry = type_registry.TypeRegistry.init(allocator),
            .is_compiler_library = false,  // Default to false, caller can set if needed
            .module_name = module_name,
            .inline_flow_counter = 0,  // Global counter across all procs
            .fail_fast = false,  // Default to lenient mode (continue past errors)
            .compiler_flags = compiler_flags,  // Flags for conditional imports
            .resolver = resolver,  // Module resolver for import paths
        };
    }
    
    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
        self.reporter.deinit();
        self.context_stack.deinit(self.allocator);
        self.allocator.free(self.module_name);

        // Free subflow names
        // Clean shutdown
        // Note: registry ownership is transferred to ParseResult, so we don't deinit it here
    }

    /// Create an error node for lenient parsing mode
    /// Captures the raw source text and error details for IDE tooling
    fn createErrorNode(self: *Parser, start_line: usize, end_line: usize) !ast.ParseErrorNode {
        // Capture the raw text that failed to parse
        const actual_end = @min(end_line, self.lines.len);
        var raw_text_list = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer raw_text_list.deinit(self.allocator);

        for (start_line..actual_end) |i| {
            if (i < self.lines.len) {
                try raw_text_list.appendSlice(self.allocator, self.lines[i]);
                try raw_text_list.append(self.allocator, '\n');
            }
        }

        // Get the last error from reporter (the one that just occurred)
        const last_error = if (self.reporter.errors.items.len > 0)
            self.reporter.errors.items[self.reporter.errors.items.len - 1]
        else
            // Fallback if no error was recorded
            errors.ParseError{
                .code = .PARSE001,
                .message = try self.allocator.dupe(u8, "parse error"),
                .location = self.getCurrentLocation(),
                .hint = null,
            };

        return ast.ParseErrorNode{
            .error_code = last_error.code,
            .message = try self.allocator.dupe(u8, last_error.message),
            .location = last_error.location,
            .raw_text = try raw_text_list.toOwnedSlice(self.allocator),
            .hint = if (last_error.hint) |h| try self.allocator.dupe(u8, h) else null,
        };
    }

    /// Recover to the next Koru construct (next line starting with ~)
    /// Used in lenient parsing mode to skip past errors
    fn recoverToNextConstruct(self: *Parser) void {
        // Scan forward to next line starting with ~
        while (self.current < self.lines.len) {
            self.current += 1;
            if (self.current >= self.lines.len) break;

            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);
            if (lexer.startsWith(trimmed, "~")) break;
        }
    }

    pub fn parse(self: *Parser) !ParseResult {
        // Parse all items in the source file
        // Starting parse

        var items = try std.ArrayList(ast.Item).initCapacity(self.allocator, 8);
        errdefer {
            for (items.items) |*item| {
                item.deinit(self.allocator);
            }
            items.deinit(self.allocator);
        }

        var module_annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (module_annotations.items) |annotation| {
                self.allocator.free(annotation);
            }
            module_annotations.deinit(self.allocator);
        }

        // Parse each line
        while (self.current < self.lines.len) {
            // Process line

            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            if (trimmed.len == 0) {
                self.current += 1;
                continue;
            }

            if (lexer.startsWith(line, "~")) {
                // Check if this is a module-level annotation: ~[annotation] on its own line
                const after_tilde = lexer.trim(trimmed[1..]);

                if (std.mem.startsWith(u8, after_tilde, "[")) {
                    // Parse annotation block (supports both inline ~[a|b] and vertical ~[\n-a\n-b\n])
                    const current_before = self.current;
                    const result = self.parseAnnotationBlock(after_tilde, self.current) catch |err| {
                        if (self.fail_fast) {
                            return err;
                        }
                        // Lenient mode: create error node and skip to next construct
                        const start_line = self.current;
                        self.recoverToNextConstruct();
                        const error_node = try self.createErrorNode(start_line, self.current);
                        try items.append(self.allocator, .{ .parse_error = error_node });
                        continue;
                    };
                    const used_vertical_syntax = (self.current != current_before);

                    // If there's nothing after the closing bracket, check if the next line has a construct
                    if (result.remaining.len == 0) {
                        // Look ahead to see if the next line has a Koru construct
                        // For inline syntax, we need to look at the NEXT line (self.current + 1)
                        // For vertical syntax, self.current already points to the line after the ]
                        const next_line_idx = if (used_vertical_syntax) self.current else self.current + 1;
                        const has_construct_on_next_line = if (next_line_idx < self.lines.len) blk: {
                            const next_line = self.lines[next_line_idx];
                            const next_trimmed = lexer.trim(next_line);
                            // Check if next line starts with ~ OR looks like a construct
                            // Constructs can be:
                            // - Explicit: ~event, ~proc, ~import
                            // - Implicit flow calls: identifier(args) or namespace.identifier(args)
                            if (next_trimmed.len > 0 and next_trimmed[0] == '~') {
                                break :blk true;
                            }
                            // Check for flow call patterns: word.word:event(...) or word(...)
                            // But exclude comments and empty lines
                            if (next_trimmed.len == 0 or std.mem.startsWith(u8, next_trimmed, "//")) {
                                break :blk false;
                            }
                            // Look for identifier patterns (flow calls, event, proc, etc.)
                            // Simple heuristic: starts with letter or contains ( or : or event/proc keywords
                            const looks_like_construct =
                                std.mem.indexOf(u8, next_trimmed, "(") != null or
                                std.mem.indexOf(u8, next_trimmed, ":") != null or
                                std.mem.startsWith(u8, next_trimmed, "pub ") or
                                std.mem.startsWith(u8, next_trimmed, "event ") or
                                std.mem.startsWith(u8, next_trimmed, "proc ");
                            break :blk looks_like_construct;
                        } else false;

                        if (!has_construct_on_next_line) {
                            // It's a module-level annotation
                            for (result.annotations) |ann| {
                                try module_annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
                            }
                            for (result.annotations) |ann| {
                                self.allocator.free(ann);
                            }
                            self.allocator.free(result.annotations);

                            // For inline syntax, advance to next line; for vertical, parseAnnotationBlock already did
                            if (!used_vertical_syntax) {
                                self.current += 1;
                            }
                            continue;
                        }

                        // There IS a construct on the next line - treat this as an item-level annotation
                        // The construct is on the next line, so synthesize ~[annotations]construct_text and parse it
                        const construct_line = self.lines[next_line_idx];
                        const construct_trimmed = lexer.trim(construct_line);
                        // Remove the leading ~ from the construct if present (for events/procs)
                        // For flow calls, there might be no ~
                        const construct_content = if (construct_trimmed.len > 0 and construct_trimmed[0] == '~')
                            if (construct_trimmed.len > 1) construct_trimmed[1..] else ""
                        else
                            construct_trimmed;

                        // Build annotation string: [ann1|ann2|ann3]
                        var ann_str = try std.ArrayList(u8).initCapacity(self.allocator, 64);
                        defer ann_str.deinit(self.allocator);
                        try ann_str.append(self.allocator, '[');
                        for (result.annotations, 0..) |ann, i| {
                            if (i > 0) try ann_str.append(self.allocator, '|');
                            try ann_str.appendSlice(self.allocator, ann);
                        }
                        try ann_str.append(self.allocator, ']');

                        const synthetic_line = try std.fmt.allocPrint(self.allocator, "~{s}{s}", .{ann_str.items, construct_content});
                        defer self.allocator.free(synthetic_line);

                        // Temporarily replace the next line with the synthetic line
                        const saved_line = self.lines[next_line_idx];
                        self.lines[next_line_idx] = synthetic_line;
                        const saved_current = self.current;
                        self.current = next_line_idx;

                        // Parse the Koru construct
                        const item = self.parseKoruConstruct() catch |err| {
                            self.lines[next_line_idx] = saved_line;
                            // Clean up annotations
                            for (result.annotations) |ann| {
                                self.allocator.free(ann);
                            }
                            self.allocator.free(result.annotations);
                            if (self.fail_fast) {
                                return err;
                            }
                            // Ensure valid range for error node (start <= end)
                            const error_start = @min(saved_current, next_line_idx);
                            const error_end = @max(saved_current, next_line_idx) + 1;
                            const error_node = try self.createErrorNode(error_start, error_end);
                            try items.append(self.allocator, .{ .parse_error = error_node });
                            // Skip past BOTH the annotation line and the failed construct line to avoid infinite loop
                            // Use max in case parseKoruConstruct advanced self.current partway through a multi-line construct
                            self.current = @max(self.current, next_line_idx + 1);
                            continue;
                        };

                        // Clean up annotations
                        for (result.annotations) |ann| {
                            self.allocator.free(ann);
                        }
                        self.allocator.free(result.annotations);

                        // Restore the original line
                        self.lines[next_line_idx] = saved_line;
                        try items.append(self.allocator, item);
                        continue;
                    }

                    // If there IS something after ], it's an item-level construct (event/proc/import)
                    // Clean up annotations first
                    for (result.annotations) |ann| {
                        self.allocator.free(ann);
                    }
                    self.allocator.free(result.annotations);

                    // For vertical syntax, the construct is on a different line, so we synthesize a new line
                    // For inline syntax, the construct is on the SAME line, so just continue parsing this line
                    if (used_vertical_syntax) {
                        // Vertical: synthesize ~{remaining} and process it
                        const synthetic_line = try std.fmt.allocPrint(self.allocator, "~{s}", .{result.remaining});
                        defer self.allocator.free(synthetic_line);

                        // Temporarily replace the line BEFORE current (which has the ]) with the synthetic line
                        const line_with_bracket = self.current - 1;
                        const saved_line = self.lines[line_with_bracket];
                        self.lines[line_with_bracket] = synthetic_line;
                        const saved_current = self.current;
                        self.current = line_with_bracket;

                        // Parse the Koru construct
                        const item = self.parseKoruConstruct() catch |err| {
                            self.lines[line_with_bracket] = saved_line;
                            self.current = saved_current;
                            if (self.fail_fast) {
                                return err;
                            }
                            const error_node = try self.createErrorNode(line_with_bracket, saved_current);
                            try items.append(self.allocator, .{ .parse_error = error_node });
                            continue;
                        };

                        // Restore the original line, but DON'T restore self.current!
                        // parseKoruConstruct advanced past the event and its branches, and we want to keep that
                        self.lines[line_with_bracket] = saved_line;
                        try items.append(self.allocator, item);
                        continue;
                    } else {
                        // Inline: the construct is on the same line, so fall through to normal parsing
                        // Don't continue here - let the code below handle it
                    }
                }

                // Check for conditional imports: ~[flag]import
                // If the import has annotations but no matching compiler flag, skip it
                if (std.mem.indexOf(u8, after_tilde, "[") != null and
                    std.mem.indexOf(u8, after_tilde, "]import ") != null) {
                    // This is an annotated import - check if we should skip it
                    const close_bracket = std.mem.indexOf(u8, after_tilde, "]") orelse 0;
                    if (close_bracket > 0) {
                        const ann_str = after_tilde[1..close_bracket];
                        var has_matching_flag = false;

                        // Check each annotation against compiler flags
                        var ann_iter = std.mem.splitScalar(u8, ann_str, '|');
                        while (ann_iter.next()) |ann| {
                            const trimmed_ann = lexer.trim(ann);
                            if (trimmed_ann.len > 0) {
                                for (self.compiler_flags) |flag| {
                                    if (std.mem.eql(u8, trimmed_ann, flag)) {
                                        has_matching_flag = true;
                                        break;
                                    }
                                }
                                if (has_matching_flag) break;
                            }
                        }

                        // If no matching flag found, skip this import
                        if (!has_matching_flag) {
                            self.current += 1;
                            continue;
                        }

                        // Flag matches - normalize the line by stripping [flag] annotation
                        // Transform "~[profile]import ..." to "~import ..."
                        const import_start = std.mem.indexOf(u8, after_tilde, "]import ") orelse unreachable;
                        const after_bracket = after_tilde[import_start + 1..]; // Skip the ]
                        // Allocate normalized line: ~ + (stuff after ])
                        const normalized_line = try std.fmt.allocPrint(self.allocator, "~{s}", .{after_bracket});
                        self.lines[self.current] = normalized_line;
                    }
                }

                // Otherwise, it's an item-level construct
                const start_line = self.current;
                const item = self.parseKoruConstruct() catch |err| {
                    if (self.fail_fast) {
                        return err;
                    }
                    // Lenient mode: reset position and skip to next construct
                    // (parseKoruConstruct may have advanced self.current past EOF while looking for closing braces)
                    self.current = start_line;
                    self.recoverToNextConstruct();
                    const error_node = try self.createErrorNode(start_line, self.current);
                    try items.append(self.allocator, .{ .parse_error = error_node });
                    continue;
                };
                try items.append(self.allocator, item);
            } else if (lexer.startsWith(line, "|")) {
                try self.reporter.addError(
                    .KORU010,
                    self.current + 1,
                    lexer.getIndent(line) + 1,
                    "stray continuation line without Koru construct",
                    .{},
                );
                self.current += 1;
            } else {
                // Pass through host language line
                const owned_line = try self.allocator.dupe(u8, line);
                try items.append(self.allocator, .{ .host_line = .{
                    .content = owned_line,
                    .location = self.getCurrentLocation(),
                    .module = try self.allocator.dupe(u8, self.module_name),
                } });
                self.current += 1;
            }
        }

        return ParseResult{
            .source_file = ast.Program{
                .items = try items.toOwnedSlice(self.allocator),
                .module_annotations = try module_annotations.toOwnedSlice(self.allocator),
                .main_module_name = try self.allocator.dupe(u8, self.module_name),
                .allocator = self.allocator,
            },
            .registry = self.registry,
        };
    }

    const AnnotationBlockResult = struct {
        annotations: [][]const u8,  // Owned slice, caller must free individual strings and the slice
        /// Content after the closing ] (for inline syntax)
        /// For vertical syntax, this is always empty since ] is on its own line or line ending
        remaining: []const u8,
    };

    /// Parse annotation block supporting both inline and vertical syntax:
    /// - Inline: [a|b|c] on same line
    /// - Vertical: [\n-a\n-b\n-c\n] across multiple lines
    /// Returns annotations and content after ] (caller owns annotations)
    fn parseAnnotationBlock(self: *Parser, content_with_bracket: []const u8, starting_line: usize) !AnnotationBlockResult {
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (annotations.items) |ann| {
                self.allocator.free(ann);
            }
            annotations.deinit(self.allocator);
        }

        // Check if ] is on the same line (inline syntax)
        if (std.mem.indexOf(u8, content_with_bracket, "]")) |close_bracket| {
            // Inline syntax: [a|b|c]
            const ann_str = content_with_bracket[1..close_bracket];
            var ann_iter = std.mem.splitScalar(u8, ann_str, '|');
            while (ann_iter.next()) |ann| {
                const trimmed_ann = lexer.trim(ann);
                if (trimmed_ann.len > 0) {
                    try annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                }
            }
            const remaining = content_with_bracket[close_bracket + 1..];
            return AnnotationBlockResult{
                .annotations = try annotations.toOwnedSlice(self.allocator),
                .remaining = remaining,
            };
        }

        // Vertical syntax: [\n-a\n-b\n]
        // The opening [ is at end of current line, advance to next line
        self.current += 1;

        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            // Skip empty lines and comments
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
                self.current += 1;
                continue;
            }

            // Check if this line contains the closing ]
            if (std.mem.indexOf(u8, trimmed, "]")) |bracket_idx| {
                // Found closing bracket
                // Check if there's a bullet annotation on this line before the ]
                if (trimmed.len > 0 and trimmed[0] == '-') {
                    const ann_content = lexer.trim(trimmed[1..bracket_idx]); // Skip the - and content after ]
                    if (ann_content.len > 0) {
                        try annotations.append(self.allocator, try self.allocator.dupe(u8, ann_content));
                    }
                }
                const remaining = lexer.trim(trimmed[bracket_idx + 1..]); // Content after ]
                self.current += 1;
                return AnnotationBlockResult{
                    .annotations = try annotations.toOwnedSlice(self.allocator),
                    .remaining = remaining,
                };
            }

            // Check if line starts with - (bullet annotation)
            if (trimmed.len > 0 and trimmed[0] == '-') {
                const ann_content = lexer.trim(trimmed[1..]); // Skip the -
                if (ann_content.len > 0) {
                    try annotations.append(self.allocator, try self.allocator.dupe(u8, ann_content));
                }
                self.current += 1;
                continue;
            }

            // If we get here: line is not empty, not comment, not -, not ]
            // This is INVALID syntax in vertical annotation block!
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,  // Convert to 1-based line number
                1,
                "invalid line in vertical annotation block - expected '-' bullet or ']'",
                .{},
            );
            return error.ParseError;
        }

        // Ran out of lines without finding ]
        try self.reporter.addError(.PARSE003, starting_line, 1, "unclosed annotation bracket", .{});
        return error.ParseError;
    }

    fn parseKoruConstruct(self: *Parser) !ast.Item {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file in parseKoruConstruct",
                .{},
            );
            return error.UnexpectedEOF;
        }
        
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);
        
        // Remove the ~ prefix
        const after_tilde = lexer.trim(trimmed[1..]);
        
        // Check for annotations first: ~[annotation]construct
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer {
            for (annotations.items) |ann| {
                self.allocator.free(ann);
            }
            annotations.deinit(self.allocator);
        }
        
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            // Parse annotation block (supports both inline ~[a|b] and vertical ~[\n-a\n-b\n])
            const result = try self.parseAnnotationBlock(after_tilde, self.current);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }

            for (result.annotations) |ann| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
            }

            remaining = lexer.trim(result.remaining);
        }

        // Check for ~impl prefix (marks abstract event implementation)
        var is_impl = false;
        if (lexer.startsWith(remaining, "impl ")) {
            is_impl = true;
            remaining = lexer.trim(remaining[5..]); // Skip "impl "
        }

        // Now check for constructs
        if (lexer.startsWith(remaining, "abstract pub event")) {
            // Abstract public event declaration with annotations
            return .{ .event_decl = try self.parseEventDeclWithAnnotations(true, annotations.items, true) };
        } else if (lexer.startsWith(remaining, "abstract event")) {
            // Abstract private event declaration with annotations
            return .{ .event_decl = try self.parseEventDeclWithAnnotations(false, annotations.items, true) };
        } else if (lexer.startsWith(remaining, "pub event")) {
            // Public event declaration with annotations
            return .{ .event_decl = try self.parseEventDeclWithAnnotations(true, annotations.items, false) };
        } else if (lexer.startsWith(remaining, "import ")) {
            // Note: Conditional imports (~[flag]import) are already filtered out
            // at a higher level in parse(), so if we reach here the import is allowed
            return .{ .import_decl = try self.parseImportDecl() };
        } else if (lexer.startsWith(remaining, "event ")) {
            // Private event declaration with annotations
            return .{ .event_decl = try self.parseEventDeclWithAnnotations(false, annotations.items, false) };
        } else if (lexer.startsWith(remaining, "proc ")) {
            var proc = try self.parseProcDeclWithAnnotations(annotations.items);
            proc.is_impl = is_impl;
            return .{ .proc_decl = proc };
        } else if (lexer.startsWith(after_tilde, "#")) {
            // New label anchor syntax or pre-invocation label
            return try self.parseLabelAnchor();
        } else if (lexer.startsWith(after_tilde, "@")) {
            // Old syntax - we'll deprecate this for standalone labels
            return .{ .label_decl = try self.parseLabelDecl() };
        } else if (std.mem.indexOf(u8, remaining, "=") != null) {
            // Event implementation via subflow: ~event.name = ...
            var subflow = try self.parseSubflowImpl();
            subflow.is_impl = is_impl;
            return .{ .subflow_impl = subflow };
        } else if (std.mem.indexOfScalar(u8, remaining, '(') != null) {
            // It's an invocation with args
            return .{ .flow = try self.parseFlow(annotations.items) };
        } else {
            // Flow invocation without args
            return .{ .flow = try self.parseFlow(annotations.items) };
        }
    }
    
    fn parseEventInputShape(self: *Parser, event_line: []const u8, event_line_index: usize) !ast.Shape {
        const trimmed_line = lexer.trim(event_line);

        if (std.mem.indexOf(u8, trimmed_line, "{")) |brace_start| {
            return self.parseEventInputShapeFromLine(trimmed_line, brace_start);
        }

        return self.parseEventInputShapeFromFollowingLines(event_line_index);
    }

    fn parseEventInputShapeFromLine(self: *Parser, line: []const u8, brace_start: usize) !ast.Shape {
        const close_offset = blk: {
            var depth: i32 = 0;
            var i = brace_start;
            while (i < line.len) : (i += 1) {
                if (line[i] == '{') {
                    depth += 1;
                } else if (line[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        break :blk i - brace_start;
                    }
                }
            }
            break :blk null;
        };

        if (close_offset) |off| {
            const content = lexer.trim(line[brace_start + 1 .. brace_start + off]);
            return self.parseShape(content);
        }

        var shape_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer shape_content.deinit(self.allocator);

        const first_line_content = lexer.trim(line[brace_start + 1 ..]);
        if (first_line_content.len > 0) {
            try shape_content.appendSlice(self.allocator, first_line_content);
            try shape_content.append(self.allocator, ',');
        }

        var brace_depth: i32 = 1;
        const start_line = self.current;

        while (self.current < self.lines.len and brace_depth > 0) {
            const current_line = self.lines[self.current];
            self.current += 1;

            const trimmed = lexer.trim(current_line);
            if (trimmed.len == 0) continue;

            for (trimmed) |c| {
                if (c == '{') brace_depth += 1;
                if (c == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        const end_idx = std.mem.indexOf(u8, trimmed, "}").?;
                        const final_content = lexer.trim(trimmed[0..end_idx]);
                        if (final_content.len > 0) {
                            try shape_content.appendSlice(self.allocator, final_content);
                        }
                        break;
                    }
                }
            }

            if (brace_depth > 0) {
                try shape_content.appendSlice(self.allocator, trimmed);
                try shape_content.append(self.allocator, ',');
            }
        }

        if (brace_depth != 0) {
            try self.reporter.addError(
                .PARSE004,
                start_line,
                @intCast(brace_start),
                "unmatched '{{' in event shape",
                .{},
            );
            return error.ParseError;
        }

        return self.parseShape(shape_content.items);
    }

    fn parseEventInputShapeFromFollowingLines(self: *Parser, event_line_index: usize) !ast.Shape {
        const error_line = event_line_index + 1; // convert to 1-based for reporting
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
                self.current += 1;
                continue;
            }

            if (lexer.isBranchContinuation(line)) {
                try self.reporter.addError(
                    .PARSE003,
                    error_line,
                    1,
                    "event declaration missing input shape",
                    .{},
                );
                return error.ParseError;
            }

            if (std.mem.indexOf(u8, trimmed, "{")) |brace_start| {
                self.current += 1;
                return self.parseEventInputShapeFromLine(trimmed, brace_start);
            }

            try self.reporter.addError(
                .PARSE003,
                error_line,
                1,
                "event declaration missing input shape",
                .{},
            );
            return error.ParseError;
        }

        try self.reporter.addError(
            .PARSE003,
            error_line,
            1,
            "event declaration missing input shape",
            .{},
        );
        return error.ParseError;
    }
    
    fn parseEventDeclWithAnnotations(self: *Parser, is_public: bool, annotations: [][]const u8, is_abstract: bool) !ast.EventDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing event declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }
        
        const line = self.lines[self.current];
        self.current += 1;
        const event_line_index = self.current - 1;
        
        // Parse: ~[annotations]pub event <path> { <fields> } or ~[annotations]event <path> { <fields> }
        const trimmed = lexer.trim(line);
        const after_tilde = lexer.trim(trimmed[1..]); // Skip ~
        
        // Skip past annotations if present (both inline and vertical syntax)
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            const result = try self.parseAnnotationBlock(after_tilde, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            // We don't need the annotations, just skip past them
            remaining = lexer.trim(result.remaining);
        }

        // Strip the event keyword (with optional abstract and pub prefixes)
        const after_event = if (is_abstract) blk: {
            // For abstract events, strip "abstract pub event" or "abstract event"
            if (lexer.afterPrefix(remaining, "abstract pub event")) |ae| {
                break :blk ae;
            } else if (lexer.afterPrefix(remaining, "abstract event")) |ae| {
                break :blk ae;
            } else {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "malformed abstract event declaration",
                    .{},
                );
                return error.ParseError;
            }
        } else if (lexer.afterPrefix(remaining, "pub event")) |ae|
            ae
        else if (lexer.afterPrefix(remaining, "event")) |ae|
            ae
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "malformed event declaration",
                .{},
            );
            return error.ParseError;
        };
        
        const trimmed_after_event = lexer.trim(after_event);
        const brace_idx_opt = std.mem.indexOf(u8, trimmed_after_event, "{");
        const parsed_path_str = if (brace_idx_opt) |idx|
            lexer.trim(trimmed_after_event[0..idx])
        else
            trimmed_after_event;

        if (parsed_path_str.len == 0) {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "event declaration missing name",
                .{},
            );
            return error.ParseError;
        }

        const path = try lexer.parseQualifiedPath(self.allocator, parsed_path_str, ast);
        if (DEBUG) std.debug.print("PARSER parseEventDeclWithAnnotations: Just parsed event path: module={s} segments=", .{if (path.module_qualifier) |m| m else "null"});
        if (DEBUG) for (path.segments) |s| std.debug.print("{s}.", .{s});
        std.debug.print("\n", .{});

        const shape_source = if (brace_idx_opt) |idx|
            trimmed_after_event[idx..]
        else
            "";
        const input = try self.parseEventInputShape(shape_source, event_line_index);

        // Parse branches (both same-line and continuation lines)
        var branches = try std.ArrayList(ast.Branch).initCapacity(self.allocator, 8);
        errdefer {
            for (branches.items) |*branch| {
                branch.deinit(self.allocator);
            }
            branches.deinit(self.allocator);
        }

        // Check for trailing annotations on the event (e.g., ~event foo() [annotation])
        // These can be on the same line as the closing brace of the input shape
        var trailing_annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            for (trailing_annotations.items) |ann| self.allocator.free(ann);
            trailing_annotations.deinit(self.allocator);
        }

        // First, check same-line branches and trailing annotations
        if (brace_idx_opt) |brace_idx| {
            // Find where the input shape ends in trimmed_after_event
            const shape_end_opt = blk: {
                var depth: i32 = 0;
                var i = brace_idx;
                while (i < trimmed_after_event.len) : (i += 1) {
                    if (trimmed_after_event[i] == '{') {
                        depth += 1;
                    } else if (trimmed_after_event[i] == '}') {
                        depth -= 1;
                        if (depth == 0) {
                            break :blk i + 1;
                        }
                    }
                }
                break :blk null;
            };

            if (shape_end_opt) |shape_end| {
                var branch_content = lexer.trim(trimmed_after_event[shape_end..]);

                // Check for trailing annotations before branches
                if (lexer.startsWith(branch_content, "[")) {
                    // Find the matching closing bracket of the annotation block
                    const close_bracket_idx = blk: {
                        var depth: i32 = 0;
                        var i: usize = 0;
                        while (i < branch_content.len) : (i += 1) {
                            if (branch_content[i] == '[') {
                                depth += 1;
                            } else if (branch_content[i] == ']') {
                                depth -= 1;
                                if (depth == 0) {
                                    break :blk i;
                                }
                            }
                        }
                        break :blk null;
                    } orelse {
                        try self.reporter.addError(
                            .PARSE003,
                            event_line_index + 1,
                            @intCast(shape_end + 1), // Column where the annotation block starts
                            "event annotation missing closing ']'",
                            .{},
                        );
                        return error.ParseError;
                    };

                    const annotation_content = lexer.trim(branch_content[1..close_bracket_idx]);
                    var iter = std.mem.splitScalar(u8, annotation_content, '|');
                    while (iter.next()) |ann| {
                        const trimmed_ann = lexer.trim(ann);
                        if (trimmed_ann.len > 0) {
                            try trailing_annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                        }
                    }
                    branch_content = lexer.trim(branch_content[close_bracket_idx + 1..]);
                }

                // Parse all branches on this line (separated by |)
                while (branch_content.len > 0 and branch_content[0] == '|') {
                    // Skip the | separator
                    branch_content = lexer.trim(branch_content[1..]);
                    if (branch_content.len == 0) break;

                    // Check for & prefix (deferred)
                    var is_deferred = false;
                    if (lexer.startsWith(branch_content, "&")) {
                        is_deferred = true;
                        branch_content = lexer.trim(branch_content[1..]);
                    }

                    // Check for ? prefix (optional)
                    var is_optional = false;
                    if (lexer.startsWith(branch_content, "?")) {
                        is_optional = true;
                        branch_content = lexer.trim(branch_content[1..]);
                    }

                    // Find branch name (everything before {)
                    const branch_brace_idx = std.mem.indexOf(u8, branch_content, "{") orelse {
                        try self.reporter.addError(
                            .PARSE003,
                            event_line_index + 1,
                            1,
                            "branch missing payload shape",
                            .{},
                        );
                        return error.ParseError;
                    };

                    const branch_name = lexer.trim(branch_content[0..branch_brace_idx]);

                    // Find the matching closing brace for the payload
                    const payload_end = blk: {
                        var depth: i32 = 0;
                        var i: usize = branch_brace_idx;
                        while (i < branch_content.len) : (i += 1) {
                            if (branch_content[i] == '{') {
                                depth += 1;
                            } else if (branch_content[i] == '}') {
                                depth -= 1;
                                if (depth == 0) {
                                    break :blk i + 1;
                                }
                            }
                        }
                        break :blk branch_content.len;
                    };

                    // Parse the payload shape
                    const payload_str = branch_content[branch_brace_idx..payload_end];
                    const payload = try self.parseBranchPayloadShape(payload_str);

                    const branch = ast.Branch{
                        .name = try self.allocator.dupe(u8, branch_name),
                        .payload = payload,
                        .is_deferred = is_deferred,
                        .is_optional = is_optional,
                    };

                    try branches.append(self.allocator, branch);

                    // Move past this branch to check for more
                    branch_content = lexer.trim(branch_content[payload_end..]);
                }
            }
        } else {
            // Multi-line or complex shape - self.current should be at the line after }
            // Check for trailing annotations on the line containing the closing brace
            const last_shape_line = self.lines[self.current - 1];
            if (std.mem.lastIndexOf(u8, last_shape_line, "}")) |close_idx| {
                var after_brace = lexer.trim(last_shape_line[close_idx + 1..]);
                if (lexer.startsWith(after_brace, "[")) {
                    // Find the matching closing bracket of the annotation block
                    const close_bracket_idx = blk: {
                        var depth: i32 = 0;
                        var i: usize = 0;
                        while (i < after_brace.len) : (i += 1) {
                            if (after_brace[i] == '[') {
                                depth += 1;
                            } else if (after_brace[i] == ']') {
                                depth -= 1;
                                if (depth == 0) {
                                    break :blk i;
                                }
                            }
                        }
                        break :blk null;
                    } orelse {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current,
                            @intCast(close_idx + 1),
                            "event annotation missing closing ']'",
                            .{},
                        );
                        return error.ParseError;
                    };

                    const annotation_content = lexer.trim(after_brace[1..close_bracket_idx]);
                    var iter = std.mem.splitScalar(u8, annotation_content, '|');
                    while (iter.next()) |ann| {
                        const trimmed_ann = lexer.trim(ann);
                        if (trimmed_ann.len > 0) {
                            try trailing_annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                        }
                    }
                }
            }
        }

        // Then check for continuation lines (multi-line branch syntax)
        while (self.current < self.lines.len) {
            const next_line = self.lines[self.current];
            if (!lexer.isBranchContinuation(next_line)) break;

            const branch = try self.parseBranch();
            try branches.append(self.allocator, branch);
        }

        // Check if this is an implicit flow event
        const is_implicit_flow = self.checkImplicitFlowEvent(&input);

        // Check if any field has is_expression or is_source - auto-add comptime annotation
        var needs_comptime = false;
        for (input.fields) |field| {
            if (field.is_expression or field.is_source) {
                needs_comptime = true;
                break;
            }
        }

        // Combined annotations (passed-in + trailing)
        var all_annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer all_annotations.deinit(self.allocator);
        
        for (annotations) |ann| {
            try all_annotations.append(self.allocator, ann);
        }
        for (trailing_annotations.items) |ann| {
            try all_annotations.append(self.allocator, ann);
        }

        // Check if comptime is already in annotations
        var has_comptime = false;
        for (all_annotations.items) |ann| {
            if (std.mem.eql(u8, ann, "comptime")) {
                has_comptime = true;
                break;
            }
        }

        // Validate: [keyword] requires pub
        for (all_annotations.items) |ann| {
            if (std.mem.eql(u8, ann, "keyword")) {
                if (!is_public) {
                    try self.reporter.addError(
                        .PARSE003,
                        event_line_index,
                        1,
                        "[keyword] annotation requires 'pub' - only public events can be keywords",
                        .{},
                    );
                    return error.ParseError;
                }
                break;
            }
        }

        // Copy annotations, adding comptime if needed
        const extra_annotations: usize = if (needs_comptime and !has_comptime) 1 else 0;
        var annotations_copy = try self.allocator.alloc([]const u8, all_annotations.items.len + extra_annotations);
        for (all_annotations.items, 0..) |ann, i| {
            annotations_copy[i] = try self.allocator.dupe(u8, ann);
        }
        if (needs_comptime and !has_comptime) {
            annotations_copy[all_annotations.items.len] = try self.allocator.dupe(u8, "comptime");
        }

        const event_decl = ast.EventDecl{
            .path = path,
            .input = input,
            .branches = try branches.toOwnedSlice(self.allocator),
            .is_public = is_public,
            .is_implicit_flow = is_implicit_flow,
            .is_abstract = is_abstract,
            .annotations = annotations_copy,
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };

        if (DEBUG) std.debug.print("PARSER: Created EventDecl module='{s}', path.module_qualifier={s}\n", .{event_decl.module, if (event_decl.path.module_qualifier) |m| m else "null"});

        // Register the event with the type registry
        const path_str = try self.pathToString(event_decl.path);
        defer self.allocator.free(path_str);
        try self.registry.registerEvent(path_str, &event_decl);
        
        return event_decl;
    }

    fn parseEventDecl(self: *Parser, is_public: bool) !ast.EventDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing event declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }
        
        const line = self.lines[self.current];
        self.current += 1;
        const event_line_index = self.current - 1;

        // Parse: ~[pub] event[annotations] <path> { <fields> }
        const after_event = if (lexer.afterPrefix(line, "~pub event")) |ae|
            ae
        else if (lexer.afterPrefix(line, "~event")) |ae|
            ae
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "malformed event declaration",
                .{},
            );
            return error.ParseError;
        };
        
        // Check for annotations: [pure|fusible|...]
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer annotations.deinit(self.allocator);
        
        var path_start = after_event;
        const trimmed_after = lexer.trim(after_event);
        if (std.mem.startsWith(u8, trimmed_after, "[")) {
            // Parse annotation block (supports both inline event[a|b] and vertical event[\n-a\n-b\n])
            const result = try self.parseAnnotationBlock(trimmed_after, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }

            for (result.annotations) |ann| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
            }

            path_start = lexer.trim(result.remaining);
        }
        
        const trimmed_path_start = lexer.trim(path_start);
        const brace_idx_opt = std.mem.indexOf(u8, trimmed_path_start, "{");
        const parsed_path_str = if (brace_idx_opt) |idx|
            lexer.trim(trimmed_path_start[0..idx])
        else
            trimmed_path_start;

        if (parsed_path_str.len == 0) {
            try self.reporter.addError(
                .PARSE003,
                event_line_index + 1,
                1,
                "event declaration missing name",
                .{},
            );
            return error.ParseError;
        }

        const path = try lexer.parseQualifiedPath(self.allocator, parsed_path_str, ast);

        const shape_source = if (brace_idx_opt) |idx|
            trimmed_path_start[idx..]
        else
            "";
        const input = try self.parseEventInputShape(shape_source, event_line_index);
        
        // Parse branches (continuation lines starting with |)
        var branches = try std.ArrayList(ast.Branch).initCapacity(self.allocator, 8);
        errdefer {
            for (branches.items) |*branch| {
                branch.deinit(self.allocator);
            }
            branches.deinit(self.allocator);
        }
        
        while (self.current < self.lines.len) {
            const next_line = self.lines[self.current];
            if (!lexer.isBranchContinuation(next_line)) break;
            
            const branch = try self.parseBranch();
            try branches.append(self.allocator, branch);
            // parseBranch handles line advancement including multi-line payloads
        }
        
        // Check if this is an implicit flow event
        const is_implicit_flow = self.checkImplicitFlowEvent(&input);
        
        const event_decl = ast.EventDecl{
            .path = path,
            .input = input,
            .branches = try branches.toOwnedSlice(self.allocator),
            .is_public = is_public,
            .is_implicit_flow = is_implicit_flow,
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
        
        // Register the event with the type registry
        const path_str = try self.pathToString(event_decl.path);
        defer self.allocator.free(path_str);
        try self.registry.registerEvent(path_str, &event_decl);
        
        return event_decl;
    }
    
    fn parseProcDeclWithAnnotations(self: *Parser, annotations: [][]const u8) !ast.ProcDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing proc declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }
        
        const line = self.lines[self.current];
        self.current += 1;
        
        // Parse: ~[annotations]proc <path> { ... }
        const trimmed = lexer.trim(line);
        const after_tilde = lexer.trim(trimmed[1..]); // Skip ~
        
        // Skip past annotations if present (both inline and vertical syntax)
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            const result = try self.parseAnnotationBlock(after_tilde, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }
            // We don't need the annotations, just skip past them
            remaining = lexer.trim(result.remaining);
        }

        const after_proc = if (lexer.afterPrefix(remaining, "proc")) |ap|
            ap
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "malformed proc declaration",
                .{},
            );
            return error.ParseError;
        };
        
        // Find the path (everything before { or =)
        // Check for both ~proc name { ... } and ~proc name = flow syntax
        const brace_idx_opt = std.mem.indexOf(u8, after_proc, "{");
        const equals_idx_opt = std.mem.indexOf(u8, after_proc, "=");

        const is_flow_expression = if (brace_idx_opt) |brace_idx|
            if (equals_idx_opt) |equals_idx|
                equals_idx < brace_idx  // = comes before { means it's a flow expression
            else
                false
        else
            equals_idx_opt != null;  // No { but has = means flow expression

        const delimiter_idx = if (is_flow_expression)
            equals_idx_opt.?
        else
            brace_idx_opt orelse {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "proc declaration missing body or flow expression",
                    .{},
                );
                return error.ParseError;
            };

        const parsed_path_str = lexer.trim(after_proc[0..delimiter_idx]);

        // Check for |variant suffix (e.g., "blur|gpu" or "compute|naive")
        var target: ?[]const u8 = null;
        var path_for_parsing = parsed_path_str;

        if (std.mem.indexOfScalar(u8, parsed_path_str, '|')) |pipe_idx| {
            // Split at pipe: path before, variant after
            path_for_parsing = lexer.trim(parsed_path_str[0..pipe_idx]);
            const target_str = lexer.trim(parsed_path_str[pipe_idx + 1..]);
            if (target_str.len > 0) {
                target = try self.allocator.dupe(u8, target_str);
            }
        }

        const path = try lexer.parseQualifiedPath(self.allocator, path_for_parsing, ast);

        // Handle two cases: ~proc name { body } vs ~proc name = flow
        var raw_body: []const u8 = undefined;

        if (is_flow_expression) {
            // Flow expression: transform to `return ~flow;` so existing inline flow extraction works
            // Extract flow body after =, looking for lines that continue the flow
            var flow_lines = try std.ArrayList(u8).initCapacity(self.allocator, 256);
            defer flow_lines.deinit(self.allocator);

            // Get the first line after =
            const first_line = lexer.trim(after_proc[delimiter_idx + 1..]);
            try flow_lines.appendSlice(self.allocator, first_line);

            // Track base indentation from first continuation line
            var base_indent: ?usize = null;

            // Continue reading lines that are part of the flow (start with | or are continuations)
            while (self.current < self.lines.len) {
                const next_line = self.lines[self.current];
                const trimmed_next = lexer.trim(next_line);

                // Check if this line continues the flow (starts with |)
                if (trimmed_next.len > 0 and trimmed_next[0] == '|') {
                    const line_indent = lexer.getIndent(next_line);

                    // Set base indent from first continuation line
                    if (base_indent == null) {
                        base_indent = line_indent;
                    }

                    // Calculate relative indent
                    const relative_indent = line_indent - base_indent.?;

                    try flow_lines.append(self.allocator, '\n');
                    // Preserve relative indentation
                    for (0..relative_indent) |_| {
                        try flow_lines.append(self.allocator, ' ');
                    }
                    try flow_lines.appendSlice(self.allocator, trimmed_next);
                    self.current += 1;
                } else {
                    // Not part of flow, stop
                    break;
                }
            }

            // Check if this is a branch constructor pattern: "branch_name {}"
            const flow_body = try flow_lines.toOwnedSlice(self.allocator);
            const trimmed_flow = lexer.trim(flow_body);

            // Branch constructor detection: identifier followed by {}
            const is_branch_constructor = blk: {
                // Find first whitespace or {
                var i: usize = 0;
                while (i < trimmed_flow.len) : (i += 1) {
                    const c = trimmed_flow[i];
                    if (c == ' ' or c == '\t' or c == '{') break;
                }
                if (i >= trimmed_flow.len) break :blk false;

                const identifier = lexer.trim(trimmed_flow[0..i]);
                const rest = lexer.trim(trimmed_flow[i..]);

                // Check if rest is just "{}" or "{ }" with optional fields
                if (rest.len >= 2 and rest[0] == '{' and std.mem.endsWith(u8, rest, "}")) {
                    break :blk identifier.len > 0;
                }
                break :blk false;
            };

            const transformed = if (is_branch_constructor) blk: {
                // Branch constructor: generate direct return with field expressions
                // Extract branch name
                const branch_end = std.mem.indexOf(u8, trimmed_flow, " ") orelse std.mem.indexOf(u8, trimmed_flow, "{").?;
                const branch_name = trimmed_flow[0..branch_end];

                // Extract field expressions from { ... }
                const brace_start = std.mem.indexOf(u8, trimmed_flow, "{").?;
                const brace_end = std.mem.lastIndexOf(u8, trimmed_flow, "}").?;
                const fields_str = lexer.trim(trimmed_flow[brace_start + 1..brace_end]);

                // Transform Koru field syntax to Zig syntax
                // Koru: "field: value" or "field1: value1, field2: value2"
                // Zig: ".field = value" or ".field1 = value1, .field2 = value2"
                var zig_fields = try std.ArrayList(u8).initCapacity(self.allocator, fields_str.len + 20);
                defer zig_fields.deinit(self.allocator);

                var field_iter = std.mem.splitScalar(u8, fields_str, ',');
                var first = true;
                while (field_iter.next()) |field| {
                    const trimmed_field = lexer.trim(field);
                    if (trimmed_field.len == 0) continue;

                    if (!first) try zig_fields.appendSlice(self.allocator, ", ");
                    first = false;

                    // Split on : to get field name and value
                    if (std.mem.indexOf(u8, trimmed_field, ":")) |colon_idx| {
                        const field_name = lexer.trim(trimmed_field[0..colon_idx]);
                        const field_value = lexer.trim(trimmed_field[colon_idx + 1..]);

                        try zig_fields.append(self.allocator, '.');
                        try zig_fields.appendSlice(self.allocator, field_name);
                        try zig_fields.appendSlice(self.allocator, " = ");
                        try zig_fields.appendSlice(self.allocator, field_value);
                    } else {
                        // No colon, just copy as-is (might be a single expression)
                        try zig_fields.appendSlice(self.allocator, trimmed_field);
                    }
                }

                const zig_fields_str = try zig_fields.toOwnedSlice(self.allocator);
                defer self.allocator.free(zig_fields_str);

                // Generate return statement with transformed fields
                break :blk try std.fmt.allocPrint(
                    self.allocator,
                    "return .{{ .{s} = .{{ {s} }} }};",
                    .{branch_name, zig_fields_str}
                );
            }
            else
                // Regular flow: wrap with ~ for inline flow extraction
                try std.fmt.allocPrint(
                    self.allocator,
                    "return ~{s};",
                    .{flow_body}
                );
            raw_body = transformed;
        } else {
            // Brace body: extract balanced braces
            raw_body = try self.extractProcBody(after_proc[delimiter_idx..]);
        }

        // Check if this proc has the [raw] annotation - if so, skip inline flow extraction
        var has_raw_annotation = false;
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann, "raw")) {
                has_raw_annotation = true;
                break;
            }
        }

        // Extract inline flows and get modified body (unless [raw] annotation is present)
        const extraction_result = if (has_raw_annotation)
            FlowExtractionResult{ .flows = &.{}, .modified_body = raw_body }
        else
            try self.extractInlineFlows(raw_body, path);
        
        // Copy annotations
        var annotations_copy = try self.allocator.alloc([]const u8, annotations.len);
        for (annotations, 0..) |ann, i| {
            annotations_copy[i] = try self.allocator.dupe(u8, ann);
        }

        // Check for ~[pure] annotation
        var is_pure = false;
        for (annotations) |ann| {
            if (std.mem.eql(u8, ann, "pure")) {
                is_pure = true;
                break;
            }
        }

        return ast.ProcDecl{
            .path = path,
            .body = extraction_result.modified_body,
            .inline_flows = extraction_result.flows,
            .annotations = annotations_copy,
            .target = target,
            .is_pure = is_pure,
            // is_transitively_pure defaults to false, will be set by purity checker
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }

    fn parseProcDecl(self: *Parser) !ast.ProcDecl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing proc declaration",
                .{},
            );
            return error.UnexpectedEOF;
        }
        
        const line = self.lines[self.current];
        self.current += 1;
        
        // Parse: ~proc[annotations] <path> { ... }
        const after_proc = lexer.afterPrefix(line, "~proc") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "malformed proc declaration",
                .{},
            );
            return error.ParseError;
        };
        
        // Check for annotations: [pure|async|...]
        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        defer annotations.deinit(self.allocator);
        
        var path_start = after_proc;
        const trimmed_after = lexer.trim(after_proc);
        if (std.mem.startsWith(u8, trimmed_after, "[")) {
            // Parse annotation block (supports both inline proc[a|b] and vertical proc[\n-a\n-b\n])
            const result = try self.parseAnnotationBlock(trimmed_after, self.current - 1);
            defer {
                for (result.annotations) |ann| {
                    self.allocator.free(ann);
                }
                self.allocator.free(result.annotations);
            }

            for (result.annotations) |ann| {
                try annotations.append(self.allocator, try self.allocator.dupe(u8, ann));
            }

            path_start = lexer.trim(result.remaining);
        }
        
        // Find the path (everything before the first {)
        const brace_idx = std.mem.indexOf(u8, path_start, "{") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "proc declaration missing body",
                .{},
            );
            return error.ParseError;
        };
        
        const parsed_path_str = lexer.trim(path_start[0..brace_idx]);

        // Check for |variant suffix (e.g., "blur|gpu" or "compute|naive")
        var target: ?[]const u8 = null;
        var path_for_parsing = parsed_path_str;

        if (std.mem.indexOfScalar(u8, parsed_path_str, '|')) |pipe_idx| {
            // Split at pipe: path before, variant after
            path_for_parsing = lexer.trim(parsed_path_str[0..pipe_idx]);
            const target_str = lexer.trim(parsed_path_str[pipe_idx + 1..]);
            if (target_str.len > 0) {
                target = try self.allocator.dupe(u8, target_str);
            }
        }

        const path = try lexer.parseQualifiedPath(self.allocator, path_for_parsing, ast);

        // Extract the body (balanced braces)
        const raw_body = try self.extractProcBody(path_start[brace_idx..]);
        
        // Check if this proc has the [raw] annotation - if so, skip inline flow extraction
        var has_raw_annotation = false;
        for (annotations.items) |ann| {
            if (std.mem.eql(u8, ann, "raw")) {
                has_raw_annotation = true;
                break;
            }
        }
        
        // Extract inline flows and get modified body (unless [raw] annotation is present)
        const extraction_result = if (has_raw_annotation)
            FlowExtractionResult{ .flows = &.{}, .modified_body = raw_body }
        else
            try self.extractInlineFlows(raw_body, path);
        
        // Debug output for flow extraction
        const path_debug = try self.pathToString(path);
        defer self.allocator.free(path_debug);
        
        // Debug: Show modified body if flows were found
        if (extraction_result.flows.len > 0 or extraction_result.modified_body.len != raw_body.len) {
        }
        
        const proc_decl = ast.ProcDecl{
            .path = path,
            .body = extraction_result.modified_body,
            .inline_flows = extraction_result.flows,
            .annotations = try annotations.toOwnedSlice(self.allocator),
            .target = target,
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
        
        // Register the proc with the type registry
        const path_str = try self.pathToString(proc_decl.path);
        defer self.allocator.free(path_str);
        try self.registry.registerProc(path_str, &proc_decl);
        
        return proc_decl;
    }
    
    const FlowExtractionResult = struct {
        modified_body: []const u8,
        flows: []ast.Flow,
    };
    
    fn extractInlineFlows(self: *Parser, body: []const u8, proc_path: ast.DottedPath) !FlowExtractionResult {
        var extracted_flows = try std.ArrayList(ast.Flow).initCapacity(self.allocator, 0);
        errdefer {
            for (extracted_flows.items) |*flow| {
                flow.deinit(self.allocator);
            }
            extracted_flows.deinit(self.allocator);
        }
        
        var modified_body = try std.ArrayList(u8).initCapacity(self.allocator, body.len);
        defer modified_body.deinit(self.allocator);
        
        // Split body into lines for processing
        var body_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
        defer body_lines.deinit(self.allocator);
        
        var line_iter = std.mem.splitScalar(u8, body, '\n');
        while (line_iter.next()) |line| {
            try body_lines.append(self.allocator, line);
        }
        
        // Process line by line
        var i: usize = 0;
        // Note: Using self.inline_flow_counter (global) instead of local counter
        // This ensures numbering matches the emitter's global numbering

        while (i < body_lines.items.len) {
            const line = body_lines.items[i];
            const trimmed = lexer.trim(line);
            const current_indent = lexer.getIndent(line);
            
            // Check if this line contains an inline flow
            // Patterns: "~...", "return ~...", "const name = ~..."
            const has_inline_flow = blk: {
                if (lexer.startsWith(trimmed, "~") and 
                    !lexer.startsWith(trimmed, "~proc") and
                    !lexer.startsWith(trimmed, "~event")) {
                    break :blk true;
                }
                if (lexer.startsWith(trimmed, "return ~")) {
                    break :blk true;
                }
                if (lexer.startsWith(trimmed, "const ")) {
                    if (std.mem.indexOf(u8, trimmed, " = ~")) |_| {
                        break :blk true;
                    }
                }
                break :blk false;
            };
            
            if (has_inline_flow) {
                // Found an inline flow! 
                
                // Collect all lines belonging to this flow
                var flow_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
                defer flow_lines.deinit(self.allocator);
                
                // Add the first line (the ~ line)
                try flow_lines.append(self.allocator, line);
                i += 1;
                
                // Collect continuation lines (including nested ones)
                var brace_depth: i32 = 0;
                
                // Check if the first line has unmatched braces
                for (trimmed) |c| {
                    if (c == '{') brace_depth += 1;
                    if (c == '}') brace_depth -= 1;
                }
                
                while (i < body_lines.items.len) {
                    const next_line = body_lines.items[i];
                    const next_trimmed = lexer.trim(next_line);
                    const next_indent = lexer.getIndent(next_line);
                    
                    // A line belongs to the flow if:
                    // 1. It starts with | and has indent > the flow's indent (continuation)
                    // 2. It's part of a multi-line constructor (brace_depth > 0)
                    // 3. It's an empty line or comment within the flow structure
                    if (next_trimmed.len == 0 or lexer.startsWith(next_trimmed, "//")) {
                        // Could be part of the flow - check if we should continue
                        // Look ahead to see if there are more flow lines
                        var j = i + 1;
                        var found_more_flow = false;
                        while (j < body_lines.items.len) {
                            const peek_line = body_lines.items[j];
                            const peek_trimmed = lexer.trim(peek_line);
                            const peek_indent = lexer.getIndent(peek_line);
                            
                            if (peek_trimmed.len > 0 and !lexer.startsWith(peek_trimmed, "//")) {
                                if (lexer.startsWith(peek_trimmed, "|") and peek_indent >= current_indent) {
                                    found_more_flow = true;
                                }
                                break;
                            }
                            j += 1;
                        }
                        
                        if (found_more_flow) {
                            try flow_lines.append(self.allocator, next_line);
                            
                            // Update brace depth for empty/comment lines
                            for (next_trimmed) |c| {
                                if (c == '{') brace_depth += 1;
                                if (c == '}') brace_depth -= 1;
                            }
                            
                            i += 1;
                        } else {
                            break;
                        }
                    } else if (lexer.startsWith(next_trimmed, "|") and next_indent >= current_indent) {
                        // This is a continuation at same or greater indent
                        try flow_lines.append(self.allocator, next_line);
                        
                        // Update brace depth for continuation lines
                        for (next_trimmed) |c| {
                            if (c == '{') brace_depth += 1;
                            if (c == '}') brace_depth -= 1;
                        }
                        
                        i += 1;
                    } else if (brace_depth > 0) {
                        // We're inside a multi-line constructor
                        // Check if this line is part of the constructor (field or closing brace)
                        const is_valid_constructor_line = blk: {
                            // Check if it's a closing brace
                            if (std.mem.eql(u8, next_trimmed, "}")) {
                                break :blk true;
                            }
                            // For lines with greater indent, check if it looks like a field
                            if (next_indent > current_indent) {
                                // Check if it looks like a field definition (name: value)
                                if (std.mem.indexOf(u8, next_trimmed, ":") != null) {
                                    // Make sure it's not a Zig statement like const x: Type
                                    if (!lexer.startsWith(next_trimmed, "const ") and
                                        !lexer.startsWith(next_trimmed, "var ") and
                                        !lexer.startsWith(next_trimmed, "fn ") and
                                        !lexer.startsWith(next_trimmed, "if ") and
                                        !lexer.startsWith(next_trimmed, "while ") and
                                        !lexer.startsWith(next_trimmed, "for ")) {
                                        break :blk true;
                                    }
                                }
                            }
                            break :blk false;
                        };
                        
                        if (is_valid_constructor_line) {
                            try flow_lines.append(self.allocator, next_line);
                            
                            // Update brace depth
                            for (next_trimmed) |c| {
                                if (c == '{') brace_depth += 1;
                                if (c == '}') brace_depth -= 1;
                            }
                            
                            i += 1;
                        } else {
                            // Not a valid constructor line, stop collecting
                            break;
                        }
                    } else {
                        // Not a continuation, end of flow
                        break;
                    }
                }
                
                // Parse the collected flow
                var parsed_flow = try self.parseCollectedFlow(flow_lines.items, current_indent);
                
                // Use UnionCollector to analyze branches and build SuperShape
                const union_collector = @import("union_collector");
                var collector = union_collector.UnionCollector.init(self.allocator);
                var collection_result = try collector.collectFromFlow(&parsed_flow);
                defer collection_result.deinit(self.allocator);
                
                // Transfer ownership of super_shape to the flow
                if (collection_result.transferSuperShape()) |super_shape| {
                    parsed_flow.super_shape = super_shape;
                }
                
                // Check for conflicts and report them
                if (collection_result.has_conflicts) {
                    for (collection_result.conflicts) |_| {
                        // TODO: Report as semantic error - branch has conflicting shapes
                        // For now, we'll continue but the code generator will need to handle this
                    }
                }
                
                try extracted_flows.append(self.allocator, parsed_flow);

                // Generate a unique name for this flow (global counter)
                self.inline_flow_counter += 1;
                const flow_name = try std.fmt.allocPrint(
                    self.allocator,
                    "__inline_flow_{d}",
                    .{self.inline_flow_counter}
                );
                defer self.allocator.free(flow_name);
                
                // Generate replacement based on the pattern
                const replacement = blk: {
                    // Create indentation string
                    const indent_str = try self.allocator.alloc(u8, current_indent);
                    defer self.allocator.free(indent_str);
                    @memset(indent_str, ' ');

                    // INLINE FLOW FIX: Pass ALL proc parameters, not just first invocation's args
                    // Look up the proc's event to get its full input shape
                    const proc_path_str = try self.pathToString(proc_path);
                    defer self.allocator.free(proc_path_str);

                    const args_str = if (self.registry.getEventType(proc_path_str)) |event_type| blk2: {
                        // Event found! Use its input shape to generate ALL parameter passing
                        if (event_type.input_shape) |input_shape| {
                            var args_buf = try std.ArrayList(u8).initCapacity(self.allocator, 128);
                            defer args_buf.deinit(self.allocator);

                            // Generate .{ .field1 = field1, .field2 = field2, ... }
                            try args_buf.appendSlice(self.allocator, ".{ ");
                            for (input_shape.fields, 0..) |field, idx| {
                                if (idx > 0) {
                                    try args_buf.appendSlice(self.allocator, ", ");
                                }
                                try args_buf.appendSlice(self.allocator, ".");
                                try args_buf.appendSlice(self.allocator, field.name);
                                try args_buf.appendSlice(self.allocator, " = ");
                                try args_buf.appendSlice(self.allocator, field.name);
                            }
                            try args_buf.appendSlice(self.allocator, " }");

                            break :blk2 try args_buf.toOwnedSlice(self.allocator);
                        } else {
                            // No input shape (event has no parameters)
                            break :blk2 try self.allocator.dupe(u8, ".{}");
                        }
                    } else try self.allocator.dupe(u8, ".{}");
                    defer self.allocator.free(args_str);
                    
                    if (lexer.startsWith(trimmed, "return ~")) {
                        // Terminal flow: return ~... -> return __inline_flow_N(args)
                        break :blk try std.fmt.allocPrint(
                            self.allocator,
                            "{s}return {s}({s});",
                            .{ indent_str, flow_name, args_str }
                        );
                    } else if (lexer.startsWith(trimmed, "const ")) {
                        // Assignment flow: const x = ~... -> const x = __inline_flow_N(args)
                        const eq_idx = std.mem.indexOf(u8, trimmed, " = ~") orelse unreachable;
                        const var_decl = trimmed[0..eq_idx + 3]; // "const x = "
                        break :blk try std.fmt.allocPrint(
                            self.allocator,
                            "{s}{s}{s}({s});",
                            .{ indent_str, var_decl, flow_name, args_str }
                        );
                    } else {
                        // Direct flow: ~...
                        // Check if this is the last non-empty statement in the proc body
                        // If yes, it should implicitly return; otherwise assign to result_N
                        const is_terminal = blk2: {
                            // Look ahead from current position (i) to see if there are more statements
                            var j = i;
                            while (j < body_lines.items.len) : (j += 1) {
                                const remaining_line = body_lines.items[j];
                                const remaining_trimmed = lexer.trim(remaining_line);

                                // Skip empty lines and comments
                                if (remaining_trimmed.len == 0 or lexer.startsWith(remaining_trimmed, "//")) {
                                    continue;
                                }

                                // Found a non-empty, non-comment line after this flow
                                break :blk2 false;
                            }
                            // No more statements found - this is terminal!
                            break :blk2 true;
                        };

                        if (is_terminal) {
                            // Terminal flow with implicit return
                            break :blk try std.fmt.allocPrint(
                                self.allocator,
                                "{s}return {s}({s});",
                                .{ indent_str, flow_name, args_str }
                            );
                        } else {
                            // Non-terminal flow: assign to result variable
                            break :blk try std.fmt.allocPrint(
                                self.allocator,
                                "{s}const result_{d} = {s}({s});",
                                .{ indent_str, self.inline_flow_counter, flow_name, args_str }
                            );
                        }
                    }
                };
                defer self.allocator.free(replacement);
                
                try modified_body.appendSlice(self.allocator, replacement);
                try modified_body.append(self.allocator, '\n');
                
            } else {
                // Not a flow, keep line as-is
                try modified_body.appendSlice(self.allocator, line);
                try modified_body.append(self.allocator, '\n');
                i += 1;
            }
        }
        
        // Remove trailing newline if present
        if (modified_body.items.len > 0 and modified_body.items[modified_body.items.len - 1] == '\n') {
            _ = modified_body.pop();
        }
        
        return FlowExtractionResult{
            .modified_body = try modified_body.toOwnedSlice(self.allocator),
            .flows = try extracted_flows.toOwnedSlice(self.allocator),
        };
    }
    
    fn parseCollectedFlow(self: *Parser, flow_lines: [][]const u8, base_indent: usize) anyerror!ast.Flow {
        // Adjust indentation - make it relative to base_indent
        var adjusted_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, flow_lines.len);
        defer adjusted_lines.deinit(self.allocator);
        
        for (flow_lines, 0..) |line, idx| {
            const line_indent = lexer.getIndent(line);
            const relative_indent = if (line_indent >= base_indent) line_indent - base_indent else 0;
            
            // Get the trimmed line
            var trimmed = lexer.trim(line);
            
            // For the first line, strip any prefix (return, const x = )
            if (idx == 0) {
                if (lexer.startsWith(trimmed, "return ~")) {
                    trimmed = trimmed[7..]; // Skip "return "
                } else if (lexer.startsWith(trimmed, "const ")) {
                    if (std.mem.indexOf(u8, trimmed, " = ~")) |eq_idx| {
                        trimmed = trimmed[eq_idx + 3..]; // Skip "const x = "
                    }
                }
            }
            
            // Create new line with adjusted indentation
            const spaces = try self.allocator.alloc(u8, relative_indent);
            defer self.allocator.free(spaces);
            @memset(spaces, ' ');
            
            const adjusted_line = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ spaces, trimmed }
            );
            try adjusted_lines.append(self.allocator, adjusted_line);
        }
        
        // Create a temporary parser with these lines
        var context_stack = try std.ArrayList(Context).initCapacity(self.allocator, 8);
        defer context_stack.deinit(self.allocator);
        try context_stack.append(self.allocator, .in_proc); // We're in a proc context
        
        var temp_parser = Parser{
            .allocator = self.allocator,
            .lines = adjusted_lines.items,
            .current = 0,
            .reporter = self.reporter,
            .context_stack = context_stack,
            .registry = self.registry,
            .is_compiler_library = self.is_compiler_library,
            .module_name = self.module_name,
            .inline_flow_counter = self.inline_flow_counter,  // Inherit parent's counter
            .fail_fast = self.fail_fast,  // Inherit parent's fail_fast mode
            .compiler_flags = self.compiler_flags,  // Inherit parent's compiler flags
            .resolver = self.resolver,  // Inherit parent's resolver
        };

        // Parse the flow (no annotations in embedded context)
        const flow = try temp_parser.parseFlow(&[_][]const u8{});

        // Clean up adjusted lines
        for (adjusted_lines.items) |line| {
            self.allocator.free(line);
        }
        
        return flow;
    }
    
    
    fn pathToString(self: *Parser, path: ast.DottedPath) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 64);
        errdefer buf.deinit(self.allocator);

        // Add module qualifier if present (e.g., "build" in "build:requires")
        if (path.module_qualifier) |mq| {
            try buf.appendSlice(self.allocator, mq);
            try buf.append(self.allocator, ':');
        }

        for (path.segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '.');
            try buf.appendSlice(self.allocator, segment);
        }

        return buf.toOwnedSlice(self.allocator);
    }
    
    /// Check if an event is an implicit flow event
    /// Returns true if the event has exactly one parameter of type Source
    fn checkImplicitFlowEvent(self: *Parser, input: *const ast.Shape) bool {
        _ = self; // Parser context not needed for this check
        
        // Must have exactly one field
        if (input.fields.len != 1) return false;
        
        const field = input.fields[0];

        // Check for Source parameter named "source"
        if (std.mem.eql(u8, field.name, "source") and field.is_source) {
            return true;
        }

        return false;
    }
    
    /// Create an invocation with synthetic Source argument for implicit flow events
    fn createImplicitFlowInvocation(
        self: *Parser,
        original: ast.Invocation,
        continuations: []ast.Continuation,
        event_type: type_registry.EventType
    ) !ast.Invocation {
        _ = continuations; // No longer needed

        // Determine which field is the implicit flow field
        var flow_field_name: []const u8 = undefined;

        // EventType has input shape info
        const input_shape = event_type.input_shape orelse return original;
        for (input_shape.fields) |field| {
            if (std.mem.eql(u8, field.type, "Source")) {
                flow_field_name = field.name;
                break;
            }
        }

        // Create new args array with the synthetic Source argument
        var new_args = try std.ArrayList(ast.Arg).initCapacity(
            self.allocator,
            original.args.len + 1
        );
        defer new_args.deinit(self.allocator);

        // Copy existing args
        for (original.args) |arg| {
            try new_args.append(self.allocator, arg);
        }

        // Create synthetic Source argument
        const source_arg = ast.Arg{
            .name = try self.allocator.dupe(u8, flow_field_name),
            .value = try self.allocator.dupe(u8, "<implicit_source>"),
        };

        try new_args.append(self.allocator, source_arg);
        
        // Check if we need to add ProgramAST
        for (input_shape.fields) |field| {
            if (std.mem.eql(u8, field.type, "ProgramAST")) {
                const ast_arg = ast.Arg{
                    .name = try self.allocator.dupe(u8, field.name),
                    .value = try self.allocator.dupe(u8, "<program_ast>"),
                };
                try new_args.append(self.allocator, ast_arg);
                break;
            }
        }
        
        return ast.Invocation{
            .path = original.path,
            .args = try new_args.toOwnedSlice(self.allocator),
        };
    }

    fn createImplicitSourceInvocation(
        self: *Parser,
        original: ast.Invocation,
        source_text: []const u8,
        phantom_type: ?[]const u8,
        event_type: type_registry.EventType
    ) !ast.Invocation {
        // Find the 'source' field of type Source
        var source_field_name: []const u8 = undefined;
        var found_source = false;
        var alternate_source_name: ?[]const u8 = null;

        const input_shape = event_type.input_shape orelse return original;
        for (input_shape.fields) |field| {
            if (std.mem.eql(u8, field.name, "source") and field.is_source) {
                source_field_name = field.name;
                found_source = true;
                break;
            } else if (field.is_source) {
                // Found a Source parameter with different name
                alternate_source_name = field.name;
            }
        }

        if (!found_source) {
            // Check if there's a Source parameter with a different name
            if (alternate_source_name) |alt_name| {
                // Get event name for error message
                const path_str = try self.pathToString(original.path);
                defer self.allocator.free(path_str);

                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "Implicit source block syntax [Type]{{ }} requires parameter named 'source'. Event '{s}' has Source parameter named '{s}'. Either rename parameter to 'source' or use explicit syntax: ~{s}({s}: [Type]{{ }})",
                    .{ path_str, alt_name, path_str, alt_name }
                );
                return error.ParseError;
            }
            return original;
        }

        // Create new args array with the source argument
        var new_args = try std.ArrayList(ast.Arg).initCapacity(
            self.allocator,
            original.args.len + 1
        );
        defer new_args.deinit(self.allocator);

        // Copy existing args
        for (original.args) |arg| {
            try new_args.append(self.allocator, arg);
        }

        // Capture continuation bindings from context stack
        var bindings = try std.ArrayList(ast.ScopeBinding).initCapacity(self.allocator, 4);
        defer bindings.deinit(self.allocator);

        for (self.context_stack.items) |ctx| {
            switch (ctx) {
                .in_continuation => |cont| {
                    if (cont.binding) |binding_name| {
                        // Create scope binding for this continuation variable
                        const scope_binding = ast.ScopeBinding{
                            .name = try self.allocator.dupe(u8, binding_name),
                            .type = try self.allocator.dupe(u8, "unknown"),  // Type inference would go here
                            .value_ref = try self.allocator.dupe(u8, binding_name),
                        };
                        try bindings.append(self.allocator, scope_binding);
                    }
                },
                else => {},
            }
        }

        const captured_scope = ast.CapturedScope{
            .bindings = try bindings.toOwnedSlice(self.allocator),
        };

        const source_value = try self.allocator.create(ast.Source);
        source_value.* = ast.Source{
            .text = try self.allocator.dupe(u8, source_text),
            .location = self.getCurrentLocation(),
            .scope = captured_scope,
            .phantom_type = if (phantom_type) |pt| try self.allocator.dupe(u8, pt) else null,
        };

        // Add the source argument with Source value
        const source_arg = ast.Arg{
            .name = try self.allocator.dupe(u8, source_field_name),
            .value = try self.allocator.dupe(u8, source_text),  // Keep string value for compatibility
            .source_value = source_value,  // Add Source struct with scope
        };

        try new_args.append(self.allocator, source_arg);

        return ast.Invocation{
            .path = original.path,
            .args = try new_args.toOwnedSlice(self.allocator),
        };
    }

    fn extractProcBody(self: *Parser, start: []const u8) ![]const u8 {
        var depth: i32 = 0;
        var body_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer body_lines.deinit(self.allocator);
        
        // First line contains the opening brace
        if (!std.mem.startsWith(u8, lexer.trim(start), "{")) {
            return error.ParseError;
        }
        
        // Debug: Starting extraction
        
        // Check if it's a single-line body
        // Look for a closing brace AFTER the opening brace
        var brace_count: i32 = 1; // We already have the opening brace
        var single_line_end: ?usize = null;
        for (start[1..], 1..) |c, idx| {
            if (c == '{') brace_count += 1;
            if (c == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    single_line_end = idx;
                    break;
                }
            }
        }
        
        if (single_line_end) |end_idx| {
            // Single line body - extract everything between the braces
            const body_content = lexer.trim(start[1..end_idx]);
            // Single-line body
            return try self.allocator.dupe(u8, body_content);
        }
        
        // Multi-line body
        depth = 1;
        // Multi-line body
        try body_lines.append(self.allocator, start[1..]); // Skip opening brace
        
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            self.current += 1;
            
            // Processing line
            
            // First check if this line would close the proc
            // A proc ends when we see a closing brace that would bring depth to 0
            var temp_depth = depth;
            var in_string = false;
            var in_char = false;
            var prev_char: u8 = 0;
            var i: usize = 0;
            
            while (i < line.len) {
                const c = line[i];

                // Skip line comments: everything after // is ignored
                if (!in_string and !in_char and c == '/' and i + 1 < line.len and line[i + 1] == '/') {
                    break; // Rest of line is comment, stop processing
                }

                // Handle character literals
                if (c == '\'' and prev_char != '\\' and !in_string) {
                    in_char = !in_char;
                }
                // Handle string literals
                else if (c == '"' and prev_char != '\\' and !in_char) {
                    in_string = !in_string;
                }
                // Count braces only when not in strings or char literals
                else if (!in_string and !in_char) {
                    if (c == '{') temp_depth += 1;
                    if (c == '}') temp_depth -= 1;
                }

                prev_char = c;
                i += 1;
            }
            
            // Check depth change
            
            // If this line would make depth go to 0 or negative, the proc is ending
            if (temp_depth <= 0) {
                // Don't include the closing brace line in the body
                // The line has already been consumed (self.current was incremented)
                depth = temp_depth; // Update depth to reflect we found the closing brace
                break;
            }
            
            // This line is part of the proc body, include it
            // Including line in body
            try body_lines.append(self.allocator, line);
            depth = temp_depth;
        }
        
        if (depth != 0) {
            std.debug.print("ERROR: Proc body extraction failed! Final depth = {}, body_lines count = {}\n", .{depth, body_lines.items.len});
            if (body_lines.items.len > 0) {
                std.debug.print("  First line: {s}\n", .{body_lines.items[0]});
                if (body_lines.items.len > 1) {
                    const last = body_lines.items[body_lines.items.len - 1];
                    std.debug.print("  Last line: {s}\n", .{last});
                }
            }
            try self.reporter.addError(
                .PARSE004,
                self.current,
                1,
                "unbalanced braces in proc body",
                .{},
            );
            return error.ParseError;
        }
        
        // Join lines with newlines
        var total_len: usize = 0;
        for (body_lines.items, 0..) |line, i| {
            total_len += line.len;
            if (i < body_lines.items.len - 1) {
                total_len += 1; // for newline
            }
        }
        
        if (total_len == 0) {
            return try self.allocator.dupe(u8, "");
        }
        
        var result = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (body_lines.items, 0..) |line, i| {
            @memcpy(result[offset..][0..line.len], line);
            offset += line.len;
            if (i < body_lines.items.len - 1) {
                result[offset] = '\n';
                offset += 1;
            }
        }
        
        // Return final body
        
        return result;
    }

    // NOTE: parseEventTapWithAnnotations and parseEventTap removed.
    // Taps are now a library feature using the transform system.
    // See koru_std/taps.kz for the ~tap() transform implementation.

    fn parseFlow(self: *Parser, annotations: [][]const u8) anyerror!ast.Flow {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing flow",
                .{},
            );
            return error.UnexpectedEOF;
        }

        const location = self.getLineLocation(self.current, lexer.getIndent(self.lines[self.current]));
        const line = self.lines[self.current];
        self.current += 1;

        const trimmed = lexer.trim(line);
        const after_tilde = trimmed[1..]; // Skip ~

        // Skip past annotations if present (annotations were already parsed in parseKoruConstruct)
        var remaining = after_tilde;
        if (std.mem.startsWith(u8, after_tilde, "[")) {
            // Find the closing ] and skip past it
            if (std.mem.indexOf(u8, after_tilde, "]")) |close_pos| {
                remaining = lexer.trim(after_tilde[close_pos + 1..]);
            }
        }

        // Check if this uses implicit Source syntax
        // We look for patterns like:
        //   event_name {           - no args
        //   event_name() {         - empty args
        //   event_name(...) {      - with args
        //   module:event_name {    - module-qualified, no args
        //   event_name [type]"path" - file source syntax
        const trimmed_after = lexer.trim(remaining);

        // Check if it ends with { or ]{  - that's the marker for implicit flow/source syntax
        const has_implicit_flow_brace = std.mem.endsWith(u8, trimmed_after, "{");

        // Check if it ends with " and contains ]" - that's the marker for file source syntax
        // e.g., ~print [text]"hello.md"
        const has_implicit_file_source = std.mem.endsWith(u8, trimmed_after, "\"") and
            std.mem.indexOf(u8, trimmed_after, "]\"") != null;

        var invocation: ast.Invocation = undefined;
        var uses_implicit_flow = false;
        var uses_implicit_source = false;
        var implicit_source_text: ?[]const u8 = null;
        var implicit_source_phantom_type: ?[]const u8 = null;
        var implicit_source_file_path: ?[]const u8 = null;
        var continuations: []ast.Continuation = undefined;

        if (has_implicit_file_source) {
            // Parse file source syntax: ~event [type]"path"
            // Extract: invocation before [, phantom type in [...], file path in "..."

            // Find the last ]" to locate where the path starts
            const quote_start = std.mem.lastIndexOf(u8, trimmed_after, "]\"") orelse unreachable;
            const path_start = quote_start + 2; // Skip ]"
            const path_end = trimmed_after.len - 1; // Exclude trailing "
            const file_path = trimmed_after[path_start..path_end];

            // Find the [ to extract phantom type
            const bracket_start = std.mem.lastIndexOf(u8, trimmed_after[0..quote_start + 1], "[") orelse {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "File source syntax requires phantom type: ~event [type]\"path\"",
                    .{}
                );
                return error.ParseError;
            };
            const phantom_type = trimmed_after[bracket_start + 1 .. quote_start];

            // Extract invocation string (before the [)
            const invocation_str = lexer.trim(trimmed_after[0..bracket_start]);
            invocation = try self.parseEventInvocation(invocation_str);

            // Read the file content
            const file_content = self.readSourceFile(file_path) catch |err| {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "Failed to read source file '{s}': {s}",
                    .{ file_path, @errorName(err) }
                );
                return error.ParseError;
            };

            uses_implicit_source = true;
            implicit_source_text = file_content;
            implicit_source_phantom_type = try self.allocator.dupe(u8, phantom_type);
            implicit_source_file_path = try self.allocator.dupe(u8, file_path);

            // No multi-line block to parse, just get continuations from next lines
            continuations = try self.parseContinuations(lexer.getIndent(line));
        } else if (has_implicit_flow_brace) {
            // Parse event name and args up to the {
            const brace_idx = std.mem.lastIndexOf(u8, remaining, "{") orelse unreachable;
            var invocation_str = lexer.trim(remaining[0..brace_idx]);

            // Check for phantom type annotation [Type]{ and strip it from invocation string
            const phantom_type = try self.parseSourcePhantomType(invocation_str);
            if (phantom_type != null) {
                // Strip [Type] from the invocation string
                const bracket_start = std.mem.lastIndexOf(u8, invocation_str, "[") orelse invocation_str.len;
                invocation_str = lexer.trim(invocation_str[0..bracket_start]);
            }

            invocation = try self.parseEventInvocation(invocation_str);

            // Validate: if using [Type]{ } syntax with zero other params, () is forbidden
            if (phantom_type != null and invocation.args.len == 0) {
                // Check if invocation_str has explicit ()
                if (std.mem.indexOf(u8, invocation_str, "()")) |_| {
                    // Get event name without ()
                    const event_name_end = std.mem.indexOf(u8, invocation_str, "()") orelse invocation_str.len;
                    const event_name = lexer.trim(invocation_str[0..event_name_end]);
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        0,
                        "Cannot use '()' with Source block syntax. Use '~{s} [{s}]{{ }}' (without parentheses) or add parameters: '~{s}(param: value) [{s}]{{ }}'",
                        .{ event_name, phantom_type.?, event_name, phantom_type.? },
                    );
                    return error.InvalidSourceBlockSyntax;
                }
            }

            // Look up the event to determine if it expects Source
            const path_str = try self.pathToString(invocation.path);
            defer self.allocator.free(path_str);

            if (self.registry.getEventType(path_str)) |event_type| {
                // Check if it has any Source parameter
                var has_source_param = false;
                if (event_type.input_shape) |shape| {
                    for (shape.fields) |field| {
                        if (field.is_source) {
                            has_source_param = true;
                            break;
                        }
                    }
                }

                if (has_source_param) {
                    // Parse as Source block (raw text) - used by both implicit flow and templates
                    uses_implicit_source = true;
                    const result = try self.parseImplicitSourceBlock(lexer.getIndent(line), phantom_type);
                    implicit_source_text = result.source;
                    implicit_source_phantom_type = result.phantom_type;
                    continuations = result.continuations;
                } else {
                    // Parse as implicit flow block (no Source parameter)
                    uses_implicit_flow = true;
                    continuations = try self.parseImplicitFlowBlock(lexer.getIndent(line));
                }
            } else {
                // Event not found in registry - might be a keyword that hasn't been resolved yet.
                // Assume it takes a Source parameter (optimistic parsing).
                // If it's truly invalid, later passes will catch it after keyword resolution.
                uses_implicit_source = true;
                const result = try self.parseImplicitSourceBlock(lexer.getIndent(line), phantom_type);
                implicit_source_text = result.source;
                implicit_source_phantom_type = result.phantom_type;
                continuations = result.continuations;
            }
        } else {
            // Check if this opens a multi-line argument block (regular)
            const invocation_str = remaining;
            invocation = if (std.mem.endsWith(u8, lexer.trim(invocation_str), "{"))
                try self.parseMultiLineInvocation(invocation_str)
            else
                try self.parseEventInvocation(invocation_str);

            // Check for invalid inline branch continuations: ~event() | branch |> _
            // Branch continuations must be on a new line - only void chaining (|>) is allowed inline
            // Look for `| ` followed by a word (not > or ?)
            {
                var i: usize = 0;
                while (i < invocation_str.len) : (i += 1) {
                    if (invocation_str[i] == '|' and i + 1 < invocation_str.len) {
                        const next_char = invocation_str[i + 1];
                        // |> is valid (void chaining), |? is valid (catch-all)
                        // | followed by space then word is invalid (branch must be on new line)
                        if (next_char == ' ') {
                            // Check if there's a word after the space (branch name)
                            const after_pipe = lexer.trim(invocation_str[i + 1..]);
                            if (after_pipe.len > 0 and after_pipe[0] != '>' and after_pipe[0] != '?') {
                                try self.reporter.addError(
                                    .PARSE001,
                                    self.current,
                                    @as(u16, @intCast(i)),
                                    "Branch continuation '|' must start on a new line with proper indentation",
                                    .{}
                                );
                                return error.ParseError;
                            }
                        }
                    }
                }
            }

            // Check if this line has an inline continuation (|> on same line)
            // This is needed for void event chaining: ~void_event() |> another_event()
            const has_inline_continuation = std.mem.indexOf(u8, invocation_str, "|>") != null;

            if (has_inline_continuation) {
                // Parse inline continuation from the same line
                continuations = try self.parseInlineContinuation(invocation_str, lexer.getIndent(line));
            } else {
                // Parse regular multi-line continuations
                continuations = try self.parseContinuations(lexer.getIndent(line));
            }
        }

        // Check for post-invocation label anchor (#label)
        const post_label = if (lexer.extractLabelAnchor(remaining)) |l|
            try self.allocator.dupe(u8, l)
        else
            null;
        
        // Check if this is an invocation of an implicit flow event
        const path_str = try self.pathToString(invocation.path);
        defer self.allocator.free(path_str);
        
        var final_invocation = invocation;
        var final_continuations = continuations;
        
        if (uses_implicit_flow) {
            // With {} syntax, we need to separate flow items from output continuations
            // and create the synthetic flow parameter
            if (self.registry.getEventType(path_str)) |event_type| {
                // Separate flow items from output continuations
                var flow_ast_items = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 4);
                var output_items = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 4);
                defer flow_ast_items.deinit(self.allocator);
                defer output_items.deinit(self.allocator);
                
                for (continuations) |cont| {
                    if (std.mem.eql(u8, cont.branch, "<flow_ast_item>")) {
                        try flow_ast_items.append(self.allocator, cont);
                    } else {
                        try output_items.append(self.allocator, cont);
                    }
                }
                
                // Create synthetic invocation with flow parameter
                final_invocation = try self.createImplicitFlowInvocation(
                    invocation,
                    try flow_ast_items.toOwnedSlice(self.allocator),
                    event_type
                );
                
                // Use only the output continuations
                final_continuations = try output_items.toOwnedSlice(self.allocator);
            }
        } else if (uses_implicit_source) {
            // With {} syntax and Source parameter, add the captured text as source parameter
            if (self.registry.getEventType(path_str)) |event_type| {
                final_invocation = try self.createImplicitSourceInvocation(
                    invocation,
                    implicit_source_text.?,
                    implicit_source_phantom_type,
                    event_type
                );
                // continuations are already the output continuations from parseImplicitSourceBlock
            }
        } else if (self.registry.getEventType(path_str)) |event_type| {
            if (event_type.is_implicit_flow) {
                // Regular syntax - continuations become flow parameter
                final_invocation = try self.createImplicitFlowInvocation(
                    invocation,
                    continuations,
                    event_type
                );
            }
        }
        
        // Duplicate annotations for the Flow (caller will free the original annotations)
        var flow_annotations = try self.allocator.alloc([]const u8, annotations.len);
        for (annotations, 0..) |ann, i| {
            flow_annotations[i] = try self.allocator.dupe(u8, ann);
        }

        return ast.Flow{
            .invocation = final_invocation,
            .continuations = final_continuations,
            .annotations = flow_annotations,
            .pre_label = null, // Pre-label is handled in parseLabelAnchor
            .post_label = post_label,
            .super_shape = null, // Will be set later for inline flows
            .location = location,
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }
    
    fn looksLikeZigCode(self: *Parser, content: []const u8) bool {
        _ = self;
        // Detect patterns that indicate Zig code rather than Koru event invocations
        // Note: We allow .{} and @as in arguments (Expression fields), so we need to be careful
        // to only flag Zig builtins that appear OUTSIDE of argument parentheses

        // Find the position of the first paren (start of arguments)
        const paren_start = std.mem.indexOf(u8, content, "(");
        const check_range = if (paren_start) |idx| content[0..idx] else content;

        // Check for @import, @as, etc. at the TOP LEVEL (not inside args)
        // This allows ~capture(expr: { total: @as(i32, 0) }) while blocking ~@as(...)
        if (std.mem.indexOf(u8, check_range, "@import") != null or
            std.mem.indexOf(u8, check_range, "@as") != null or
            std.mem.indexOf(u8, check_range, "@field") != null) {
            return true;
        }
        
        // Check for print patterns with format strings and tuple args
        if (std.mem.indexOf(u8, content, "std.debug.print") != null or
            std.mem.indexOf(u8, content, "std.log") != null) {
            return true;
        }
        
        // Check for raw string literals with escape sequences as first argument
        // This catches things like "text\n" which is Zig, not Koru
        if (std.mem.indexOf(u8, content, "(\"") != null) {
            const after_paren = content[std.mem.indexOf(u8, content, "(\"").? + 1..];
            // Look for string with \n, \t, etc. followed by comma (Zig printf style)
            if (std.mem.indexOf(u8, after_paren, "\\n") != null or
                std.mem.indexOf(u8, after_paren, "\\t") != null) {
                return true;
            }
        }
        
        return false;
    }
    
    fn parseMultiLineInvocation(self: *Parser, first_line: []const u8) anyerror!ast.Invocation {
        // Parse event name from first line (everything before the {)
        const brace_idx = std.mem.lastIndexOf(u8, first_line, "{") orelse unreachable;
        const event_name = lexer.trim(first_line[0..brace_idx]);
        const parsed_path = try lexer.parseQualifiedPath(self.allocator, event_name, ast);
        
        // Now parse multi-line arguments
        var args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, 8);
        defer args.deinit(self.allocator);
        
        // Keep consuming lines until we find the closing }
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);
            
            // Check if this is the closing brace
            if (std.mem.eql(u8, trimmed, "}")) {
                self.current += 1;
                break;
            }
            
            // Check if this line has a field: pattern (use depth-aware search for { ... } expressions)
            if (lexer.indexOfAtDepthZero(trimmed, ':')) |colon_idx| {
                const field_name = lexer.trim(trimmed[0..colon_idx]);
                const after_colon = lexer.trim(trimmed[colon_idx + 1..]);
                
                // Check if this starts a block { for Source
                if (std.mem.eql(u8, after_colon, "{")) {
                    // This is a Source block
                    const block_arg = try self.parseFlowAstOrSourceArg(field_name, self.current);
                    try args.append(self.allocator, block_arg);
                } else if (std.mem.endsWith(u8, after_colon, ",")) {
                    // Normal argument with trailing comma
                    const value = lexer.trim(after_colon[0..after_colon.len - 1]);
                    try args.append(self.allocator, ast.Arg{
                        .name = try self.allocator.dupe(u8, field_name),
                        .value = try self.allocator.dupe(u8, value),
                    });
                    self.current += 1;
                } else {
                    // Normal argument without comma (last one)
                    try args.append(self.allocator, ast.Arg{
                        .name = try self.allocator.dupe(u8, field_name),
                        .value = try self.allocator.dupe(u8, after_colon),
                    });
                    self.current += 1;
                }
            } else {
                self.current += 1;
            }
        }
        
        return ast.Invocation{
            .path = parsed_path,
            .args = try args.toOwnedSlice(self.allocator),
        };
    }
    
    fn parseFlowAstOrSourceArg(self: *Parser, field_name: []const u8, start_line: usize) anyerror!ast.Arg {
        // We're at a line like "field: {" 
        // Need to consume lines until we find the closing }
        var content_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);
        defer content_lines.deinit(self.allocator);
        
        // Track the indentation of the closing brace
        var closing_brace_indent: ?usize = null;
        var start_idx = start_line + 1; // Start from line after the opening {
        
        while (start_idx < self.lines.len) : (start_idx += 1) {
            const line = self.lines[start_idx];
            const trimmed = lexer.trim(line);
            
            // Check if this line is just a closing brace
            if (std.mem.eql(u8, trimmed, "}") or std.mem.endsWith(u8, trimmed, "},")) {
                // Found the closing brace - record its indentation
                closing_brace_indent = lexer.getIndent(line);
                self.current = start_idx + 1; // Move past the closing brace
                break;
            }
            
            // Otherwise, this line is part of the content
            try content_lines.append(self.allocator, line);
        }
        
        // Now dedent the content based on the closing brace position
        const dedent_amount = closing_brace_indent orelse 0;
        var final_content = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer final_content.deinit(self.allocator);
        
        for (content_lines.items, 0..) |line, i| {
            if (i > 0) try final_content.appendSlice(self.allocator, "\n");
            
            // Remove dedent_amount spaces from the beginning
            const line_indent = lexer.getIndent(line);
            const start_pos = @min(dedent_amount, line_indent);
            try final_content.appendSlice(self.allocator, line[start_pos..]);
        }

        const string_value = try final_content.toOwnedSlice(self.allocator);

        return ast.Arg{
            .name = try self.allocator.dupe(u8, field_name),
            .value = string_value,
        };
    }
    
    fn parseEventInvocation(self: *Parser, line: []const u8) anyerror!ast.Invocation {
        // Parse event invocation
        // Remove label anchors if present (both # and @ for now)
        var clean = lexer.withoutLabelAnchor(line);
        clean = lexer.withoutLabel(clean);

        // Detect Zig code patterns and report error
        if (self.looksLikeZigCode(clean)) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "Zig code not allowed in flows. Flows are pure plumbing - use events for computation.",
                .{},
            );
            return error.ZigCodeInFlow;
        }

        // Find the first pipe that's not inside parentheses or braces
        var pipe_idx: ?usize = null;
        var paren_depth: i32 = 0;
        var brace_depth: i32 = 0;
        var in_string = false;
        var i: usize = 0;
        while (i < clean.len) : (i += 1) {
            const c = clean[i];
            if (c == '"' and (i == 0 or clean[i-1] != '\\')) {
                in_string = !in_string;
            } else if (!in_string) {
                if (c == '(') paren_depth += 1;
                if (c == ')') paren_depth -= 1;
                if (c == '{') brace_depth += 1;
                if (c == '}') brace_depth -= 1;
                if (c == '|' and paren_depth == 0 and brace_depth == 0 and i > 0 and clean[i-1] == ' ') {
                    pipe_idx = i - 1; // Point to the space before the pipe
                    break;
                }
            }
        }

        const invocation_part = if (pipe_idx) |idx|
            clean[0..idx]
        else
            clean;

        // Check for Source block syntax: eventName [Type]{ ... }
        // Look for ]{ pattern to distinguish from array types like [100]f64
        const source_block_marker = std.mem.indexOf(u8, invocation_part, "]{");

        if (source_block_marker) |marker_idx| {
            // Find the opening [ by searching backwards from ]{
            const bracket_idx = std.mem.lastIndexOf(u8, invocation_part[0..marker_idx + 1], "[");

            if (bracket_idx) |b_idx| {
                // This is a Source block invocation!
                const before_bracket = lexer.trim(invocation_part[0..b_idx]);

                // Extract phantom type from [Type] (we know ] is at marker_idx)
                const phantom_type = lexer.trim(invocation_part[b_idx + 1..marker_idx]);

                // Extract block content from { ... } (marker_idx + 1 points to { position + 1)
                const brace_start = marker_idx + 1; // Position of {
                const close_brace_idx = std.mem.lastIndexOf(u8, invocation_part, "}");
                if (close_brace_idx == null) {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        0,
                        "Source block missing closing brace",
                        .{},
                    );
                    return error.ParseError;
                }

                const source_text = lexer.trim(invocation_part[brace_start + 1..close_brace_idx.?]);

                // Parse the event path
                const parsed_path = try lexer.parseQualifiedPath(self.allocator, before_bracket, ast);

                // Build path string for registry lookup
                const path_str = try self.pathToString(parsed_path);
                defer self.allocator.free(path_str);

                // Look up event type
                if (self.registry.getEventType(path_str)) |event_type| {
                    // Create base invocation with no args
                    const base_invocation = ast.Invocation{
                        .path = parsed_path,
                        .args = &[_]ast.Arg{},
                    };

                    // Create invocation with implicit Source parameter
                    return try self.createImplicitSourceInvocation(
                        base_invocation,
                        source_text,
                        phantom_type,
                        event_type
                    );
                } else {
                    // Event not found in registry - return base invocation
                    return ast.Invocation{
                        .path = parsed_path,
                        .args = &[_]ast.Arg{},
                    };
                }
            }
        }

        // Check for bare source block: eventName { ... } (no type annotation)
        // Must check BEFORE regular invocation parsing
        const bare_brace_idx = std.mem.indexOf(u8, invocation_part, "{");
        const has_paren_before_brace = if (bare_brace_idx) |b_idx|
            std.mem.indexOf(u8, invocation_part[0..b_idx], "(") != null
        else
            false;

        if (bare_brace_idx != null and !has_paren_before_brace) {
            const b_idx = bare_brace_idx.?;
            const before_brace = lexer.trim(invocation_part[0..b_idx]);

            // Find the closing brace
            const close_brace_idx = std.mem.lastIndexOf(u8, invocation_part, "}");
            if (close_brace_idx == null) {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "Source block missing closing brace",
                    .{},
                );
                return error.ParseError;
            }

            const source_text = lexer.trim(invocation_part[b_idx + 1..close_brace_idx.?]);

            // Parse the event path
            const parsed_path = try lexer.parseQualifiedPath(self.allocator, before_brace, ast);

            // Build path string for registry lookup
            const path_str = try self.pathToString(parsed_path);
            defer self.allocator.free(path_str);

            // Look up event type
            if (self.registry.getEventType(path_str)) |event_type| {
                // Create base invocation with no args
                const base_invocation = ast.Invocation{
                    .path = parsed_path,
                    .args = &[_]ast.Arg{},
                };

                // Create invocation with implicit Source parameter (no phantom type)
                return try self.createImplicitSourceInvocation(
                    base_invocation,
                    source_text,
                    null,  // No phantom type for bare source blocks
                    event_type
                );
            } else {
                // Event not found in registry - create source arg manually
                var args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, 1);
                const source_obj = try self.allocator.create(ast.Source);
                source_obj.* = ast.Source{
                    .text = try self.allocator.dupe(u8, source_text),
                    .location = self.getCurrentLocation(),
                    .phantom_type = null,
                    .scope = ast.CapturedScope{ .bindings = &[_]ast.ScopeBinding{} },
                };
                try args.append(self.allocator, ast.Arg{
                    .name = try self.allocator.dupe(u8, "source"),
                    .value = try self.allocator.dupe(u8, source_text),
                    .source_value = source_obj,
                });
                return ast.Invocation{
                    .path = parsed_path,
                    .args = try args.toOwnedSlice(self.allocator),
                };
            }
        }

        // Regular invocation without Source block
        // Find arguments in just the invocation part
        const paren_idx = std.mem.indexOf(u8, invocation_part, "(");

        const path_str = if (paren_idx) |idx|
            lexer.trim(invocation_part[0..idx])
        else
            lexer.trim(invocation_part);

        const parsed_path = try lexer.parseQualifiedPath(self.allocator, path_str, ast);

        // Parse arguments if present
        var args = try std.ArrayList(ast.Arg).initCapacity(self.allocator, 8);
        defer args.deinit(self.allocator);

        if (paren_idx) |idx| {
            // Find the matching closing parenthesis for this opening one
            var depth: usize = 1;
            var args_end = idx + 1;
            while (args_end < invocation_part.len and depth > 0) : (args_end += 1) {
                if (invocation_part[args_end] == '(') depth += 1;
                if (invocation_part[args_end] == ')') depth -= 1;
            }

            if (depth == 0) {
                const args_str = invocation_part[idx..args_end];
                const parsed_args = try lexer.parseArgs(self.allocator, args_str);
                defer self.allocator.free(parsed_args);

                // Transfer ownership of the strings to the AST
                for (parsed_args) |arg| {
                    try args.append(self.allocator, ast.Arg{
                        .name = arg.name,
                        .value = arg.value,
                    });
                }
            }
        }

        // Handle implicit `expr` parameter for Expression fields
        // Similar to how `source` works for Source fields
        if (args.items.len > 0) {
            const full_path_str = try self.pathToString(parsed_path);
            defer self.allocator.free(full_path_str);

            if (self.registry.getEventType(full_path_str)) |event_type| {
                if (event_type.input_shape) |input_shape| {
                    // Find if there's an 'expr' field with is_expression=true
                    var has_implicit_expr = false;
                    for (input_shape.fields) |field| {
                        if (std.mem.eql(u8, field.name, "expr") and field.is_expression) {
                            has_implicit_expr = true;
                            break;
                        }
                    }

                    if (has_implicit_expr) {
                        // Check each arg - if its name doesn't match any field, remap to 'expr'
                        // This handles Expression params where the lexer extracted a partial name
                        // from dotted expressions (e.g., "d.value > 10" -> name="value > 10")
                        // Only ONE arg can be implicitly mapped to 'expr'
                        var remapped_expr = false;
                        for (args.items) |*arg| {
                            if (remapped_expr) break;
                            // Skip if already explicitly named 'expr'
                            if (std.mem.eql(u8, arg.name, "expr")) continue;

                            // Check if this arg name matches any field in the event
                            var matches_field = false;
                            for (input_shape.fields) |field| {
                                if (std.mem.eql(u8, field.name, arg.name)) {
                                    matches_field = true;
                                    break;
                                }
                            }

                            if (!matches_field) {
                                // Arg doesn't match any field - remap to implicit 'expr' parameter
                                self.allocator.free(arg.name);
                                arg.name = try self.allocator.dupe(u8, "expr");
                                remapped_expr = true;
                            }
                        }
                    }

                    // Now capture scope for any Expression args
                    for (args.items) |*arg| {
                        // Check if this arg matches an is_expression field
                        for (input_shape.fields) |field| {
                            if (std.mem.eql(u8, field.name, arg.name) and field.is_expression) {
                                // Capture scope bindings from context stack
                                var bindings = try std.ArrayList(ast.ScopeBinding).initCapacity(self.allocator, 4);
                                defer bindings.deinit(self.allocator);

                                for (self.context_stack.items) |ctx| {
                                    switch (ctx) {
                                        .in_continuation => |cont| {
                                            if (cont.binding) |binding_name| {
                                                const scope_binding = ast.ScopeBinding{
                                                    .name = try self.allocator.dupe(u8, binding_name),
                                                    .type = try self.allocator.dupe(u8, "unknown"),
                                                    .value_ref = try self.allocator.dupe(u8, binding_name),
                                                };
                                                try bindings.append(self.allocator, scope_binding);
                                            }
                                        },
                                        else => {},
                                    }
                                }

                                const captured_scope = ast.CapturedScope{
                                    .bindings = try bindings.toOwnedSlice(self.allocator),
                                };

                                const expression_value = try self.allocator.create(ast.CapturedExpression);
                                expression_value.* = ast.CapturedExpression{
                                    .text = try self.allocator.dupe(u8, arg.value),
                                    .location = self.getCurrentLocation(),
                                    .scope = captured_scope,
                                };

                                arg.expression_value = expression_value;
                                break;
                            }
                        }
                    }
                }
            }
        }

        return ast.Invocation{
            .path = parsed_path,
            .args = try args.toOwnedSlice(self.allocator),
        };
    }
    
    fn parseSubflowImpl(self: *Parser) !ast.SubflowImpl {
        if (self.current >= self.lines.len) {
            try self.reporter.addError(
                .PARSE001,
                self.current,
                0,
                "unexpected end of file while parsing subflow implementation",
                .{},
            );
            return error.UnexpectedEOF;
        }
        
        const line = self.lines[self.current];
        self.current += 1;
        
        // Parse: ~event.name = ...
        // OR: ~impl event.name = ... (impl keyword will be handled by caller via is_impl flag)
        const after_tilde = lexer.trim(line[1..]);
        const eq_idx = std.mem.indexOf(u8, after_tilde, "=") orelse return error.InvalidSyntax;

        var event_path_str = lexer.trim(after_tilde[0..eq_idx]);
        // Strip "impl " prefix if present (caller will set is_impl flag on returned struct)
        if (lexer.startsWith(event_path_str, "impl ")) {
            event_path_str = lexer.trim(event_path_str[5..]);
        }
        const event_path = try lexer.parseQualifiedPath(self.allocator, event_path_str, ast);
        
        // The flow body follows the = sign
        const body_str = lexer.trim(after_tilde[eq_idx + 1..]);
        
        // Check if it's a branch constructor (immediate return syntax)
        if (body_str.len > 0) {
            // Check for branch constructor pattern: word followed by {
            const brace_idx = std.mem.indexOf(u8, body_str, "{");
            if (brace_idx) |b_idx| {
                const before_brace = lexer.trim(body_str[0..b_idx]);
                // If there's no dot or paren before the brace, it's a branch constructor
                if (std.mem.indexOf(u8, before_brace, ".") == null and
                    !std.mem.containsAtLeast(u8, before_brace, 1, "(")) {
                    // It's an immediate branch constructor!
                    // Check if we have closing brace on same line
                    const closing_idx = std.mem.lastIndexOf(u8, body_str, "}");
                    
                    if (closing_idx != null and closing_idx.? > b_idx) {
                        // Single-line, complete branch constructor
                        const branch_constructor = try self.parseBranchConstructor(body_str);
                        return ast.SubflowImpl{
                            .event_path = event_path,
                            .body = ast.SubflowBody{ .immediate = branch_constructor },
                            .location = self.getCurrentLocation(),
                            .module = try self.allocator.dupe(u8, self.module_name),
                        };
                    } else {
                        // Multi-line branch constructor starting on this line
                        var constructor_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                        defer constructor_content.deinit(self.allocator);
                        
                        // Add the content from the first line
                        try constructor_content.appendSlice(self.allocator, body_str);
                        try constructor_content.append(self.allocator, ' ');
                        
                        // Track brace depth (already have one open brace)
                        var brace_depth: i32 = 1;
                        // NOTE: Don't increment self.current here - line 3277 already advanced past
                        // the opening line, so we're already at the first field line

                        while (self.current < self.lines.len and brace_depth > 0) {
                            const curr_line = self.lines[self.current];
                            self.current += 1;
                            
                            const trimmed_line = lexer.trim(curr_line);
                            if (trimmed_line.len == 0) continue;
                            
                            // Count braces
                            for (trimmed_line) |c| {
                                if (c == '{') brace_depth += 1;
                                if (c == '}') brace_depth -= 1;
                            }
                            
                            // Add this line's content
                            try constructor_content.appendSlice(self.allocator, trimmed_line);
                            if (brace_depth > 0) {
                                try constructor_content.append(self.allocator, ' ');
                            }
                        }
                        
                        // Parse the complete constructor
                        const branch_constructor = try self.parseBranchConstructor(constructor_content.items);
                        return ast.SubflowImpl{
                            .event_path = event_path,
                            .body = ast.SubflowBody{ .immediate = branch_constructor },
                            .location = self.getCurrentLocation(),
                            .module = try self.allocator.dupe(u8, self.module_name),
                        };
                    }
                }
            }
            
            // Otherwise parse as normal flow with invocation
            // Push in_subflow_impl context to allow full expressions in branch constructors
            try self.context_stack.append(self.allocator, .in_subflow_impl);
            defer _ = self.context_stack.pop();

            const invocation = try self.parseEventInvocation(body_str);
            const continuations = try self.parseContinuations(lexer.getIndent(line));

            return ast.SubflowImpl{
                .event_path = event_path,
                .body = ast.SubflowBody{
                    .flow = ast.Flow{
                        .invocation = invocation,
                        .continuations = continuations,
                        .pre_label = null,
                        .post_label = null,
                        .super_shape = null,
                        .location = self.getCurrentLocation(),
                        .module = try self.allocator.dupe(u8, self.module_name),
                    },
                },
                .location = self.getCurrentLocation(),
                .module = try self.allocator.dupe(u8, self.module_name),
            };
        }
        
        // Flow body on next line(s) - handle multi-line flows
        if (self.current >= self.lines.len) return error.UnexpectedEof;
        
        // Skip blank lines
        while (self.current < self.lines.len) {
            const next_line = self.lines[self.current];
            const trimmed_next = lexer.trim(next_line);
            if (trimmed_next.len > 0) break;
            self.current += 1;
        }
        
        if (self.current >= self.lines.len) return error.UnexpectedEof;
        const body_line = self.lines[self.current];
        const trimmed_body = lexer.trim(body_line);
        
        // Check for branch constructor (immediate return syntax)
        const brace_idx = std.mem.indexOf(u8, trimmed_body, "{");
        if (brace_idx) |b_idx| {
            const before_brace = lexer.trim(trimmed_body[0..b_idx]);
            if (std.mem.indexOf(u8, before_brace, ".") == null and
                !std.mem.containsAtLeast(u8, before_brace, 1, "(") and
                !lexer.startsWith(trimmed_body, "|")) {  // Not a continuation
                // It's an immediate branch constructor!
                // Check if it's multiline by looking for closing brace
                const closing_idx = std.mem.lastIndexOf(u8, trimmed_body, "}");
                
                if (closing_idx != null and closing_idx.? > b_idx) {
                    // Single-line branch constructor
                    self.current += 1;
                    const branch_constructor = try self.parseBranchConstructor(trimmed_body);
                    return ast.SubflowImpl{
                        .event_path = event_path,
                        .body = ast.SubflowBody{ .immediate = branch_constructor },
                        .location = self.getCurrentLocation(),
                        .module = try self.allocator.dupe(u8, self.module_name),
                    };
                } else {
                    // Multi-line branch constructor - collect all lines
                    var constructor_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                    defer constructor_content.deinit(self.allocator);
                    
                    // Add the first line
                    try constructor_content.appendSlice(self.allocator, trimmed_body);
                    try constructor_content.append(self.allocator, ' ');
                    
                    // Track brace depth
                    var brace_depth: i32 = 1;
                    self.current += 1; // Move to next line
                    
                    while (self.current < self.lines.len and brace_depth > 0) {
                        const curr_line = self.lines[self.current];
                        self.current += 1;
                        
                        const trimmed_line = lexer.trim(curr_line);
                        if (trimmed_line.len == 0) continue;
                        
                        // Count braces
                        for (trimmed_line) |c| {
                            if (c == '{') brace_depth += 1;
                            if (c == '}') brace_depth -= 1;
                        }
                        
                        // Add this line's content
                        try constructor_content.appendSlice(self.allocator, trimmed_line);
                        if (brace_depth > 0) {
                            try constructor_content.append(self.allocator, ' ');
                        }
                    }
                    
                    // Parse the complete constructor
                    const branch_constructor = try self.parseBranchConstructor(constructor_content.items);
                    return ast.SubflowImpl{
                        .event_path = event_path,
                        .body = ast.SubflowBody{ .immediate = branch_constructor },
                        .location = self.getCurrentLocation(),
                        .module = try self.allocator.dupe(u8, self.module_name),
                    };
                }
            }
        }
        
        // Check if the line is an invocation or a continuation
        if (lexer.startsWith(trimmed_body, "|")) {
            // This is a continuation line, but we haven't parsed an invocation yet!
            // This means the subflow starts with just continuations (like a multi-line flow)
            // We need to backtrack and parse this as a full multi-line flow

            // Push in_subflow_impl context to allow full expressions in branch constructors
            try self.context_stack.append(self.allocator, .in_subflow_impl);
            defer _ = self.context_stack.pop();

            // Create a dummy "pass-through" invocation for now
            // In the future, we might want to handle this case differently
            // Duplicate the event_path for the invocation
            var dup_segments = try self.allocator.alloc([]const u8, event_path.segments.len);
            for (event_path.segments, 0..) |seg, i| {
                dup_segments[i] = try self.allocator.dupe(u8, seg);
            }
            const invocation = ast.Invocation{
                .path = ast.DottedPath{
                    .module_qualifier = if (event_path.module_qualifier) |mq| try self.allocator.dupe(u8, mq) else null,
                    .segments = dup_segments,
                },
                .args = &.{},
            };

            // Now parse all the continuations starting from current line
            const continuations = try self.parseContinuations(lexer.getIndent(line));

            return ast.SubflowImpl{
                .event_path = event_path,
                .body = ast.SubflowBody{
                    .flow = ast.Flow{
                        .invocation = invocation,
                        .continuations = continuations,
                        .pre_label = null,
                        .post_label = null,
                        .super_shape = null,
                        .location = self.getCurrentLocation(),
                        .module = try self.allocator.dupe(u8, self.module_name),
                    },
                },
                .location = self.getCurrentLocation(),
                .module = try self.allocator.dupe(u8, self.module_name),
            };
        }
        
        // Otherwise parse as normal flow starting with an invocation
        // Push in_subflow_impl context to allow full expressions in branch constructors
        try self.context_stack.append(self.allocator, .in_subflow_impl);
        defer _ = self.context_stack.pop();

        const invocation = try self.parseEventInvocation(trimmed_body);
        self.current += 1; // Move past the invocation line
        const continuations = try self.parseContinuations(lexer.getIndent(body_line));

        return ast.SubflowImpl{
            .event_path = event_path,
            .body = ast.SubflowBody{
                .flow = ast.Flow{
                    .invocation = invocation,
                    .continuations = continuations,
                    .pre_label = null,
                    .post_label = null,
                    .location = self.getCurrentLocation(),
                    .module = try self.allocator.dupe(u8, self.module_name),
                },
            },
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }

    fn parseImplicitFlowBlock(self: *Parser, base_indent: usize) ![]ast.Continuation {
        // Parse the flow content inside {} and then any output continuations after
        // Returns ALL continuations - the caller will package the flow part appropriately
        
        var all_continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (all_continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            all_continuations.deinit(self.allocator);
        }
        
        // First, parse the flow content inside {}
        var flow_ast_continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 4);
        defer flow_ast_continuations.deinit(self.allocator);
        
        var inside_braces = true;
        
        while (self.current < self.lines.len and inside_braces) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);
            
            // Check for closing brace
            if (std.mem.eql(u8, trimmed, "}")) {
                self.current += 1;
                inside_braces = false;
                break;
            }
            
            // Skip empty lines
            if (trimmed.len == 0) {
                self.current += 1;
                continue;
            }
            
            // Inside {}, we require ~ for each flow
            if (!lexer.startsWith(trimmed, "~")) {
                try self.reporter.addError(
                    .PARSE001,
                    self.current,
                    0,
                    "Flows inside block must start with ~",
                    .{},
                );
                return error.MissingTilde;
            }

            // Parse this flow and its continuations
            const flow_invocation_str = trimmed[1..]; // Skip ~

            // Parse the invocation
            const flow_invocation = try self.parseEventInvocation(flow_invocation_str);

            // Move past the invocation line before parsing continuations
            self.current += 1;

            // Parse its continuations (must be exhaustive!)
            const indent = lexer.getIndent(line);
            const flow_continuations = try self.parseContinuations(indent);

            // Package as a single continuation representing this flow
            // We'll mark it specially so the emitter knows it's a flow item
            const flow_cont = ast.Continuation{
                .branch = try self.allocator.dupe(u8, "<flow_ast_item>"),
                .binding = null,
                .condition = null,
                .node = .{ .invocation = flow_invocation },
                .indent = indent,
                .continuations = flow_continuations,
                .location = self.getCurrentLocation(),
            };

            try flow_ast_continuations.append(self.allocator, flow_cont);
        }
        
        // Now parse any output continuations after the }
        const output_continuations = try self.parseContinuations(base_indent);
        
        // Combine: flow items first, then output continuations
        for (flow_ast_continuations.items) |cont| {
            try all_continuations.append(self.allocator, cont);
        }
        for (output_continuations) |cont| {
            try all_continuations.append(self.allocator, cont);
        }
        
        // The caller will need to distinguish flow items from output continuations
        // For now, we use the special "<flow_ast_item>" branch name as a marker
        
        return all_continuations.toOwnedSlice(self.allocator);
    }

    /// Parse phantom type annotation before Source block
    /// Syntax: [Type] or [] (empty)
    /// Returns the phantom type string (empty string for [])
    fn parseSourcePhantomType(self: *Parser, line: []const u8) !?[]const u8 {
        const trimmed = lexer.trim(line);

        // Look for [ at the start
        const bracket_start = std.mem.indexOf(u8, trimmed, "[") orelse return null;
        const bracket_end = std.mem.indexOf(u8, trimmed[bracket_start..], "]") orelse return null;

        // Extract the phantom type between [ and ]
        const phantom_content = lexer.trim(trimmed[bracket_start + 1..bracket_start + bracket_end]);

        // Return duplicated string (empty string for [])
        return try self.allocator.dupe(u8, phantom_content);
    }

    fn parseImplicitSourceBlock(self: *Parser, base_indent: usize, phantom_type: ?[]const u8) !struct { source: []const u8, continuations: []ast.Continuation, phantom_type: ?[]const u8 } {
        // Parse Source content inside {} as raw text, then any output continuations after
        // Source is captured as a string - no parsing of flows inside
        //
        // INDENT-AWARE: We dedent the content by stripping the minimum indentation
        // from all non-empty lines. This allows natural code formatting:
        //
        //   ~print [text]{
        //       <h1>Hello</h1>
        //       <p>World</p>
        //   }
        //
        // Captures "<h1>Hello</h1>\n<p>World</p>\n" (no leading spaces)

        var source_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer source_lines.deinit(self.allocator);

        var inside_braces = true;
        var min_indent: ?usize = null;

        // First pass: collect lines and find minimum indentation
        while (self.current < self.lines.len and inside_braces) {
            const line = self.lines[self.current];
            const trimmed = lexer.trim(line);

            // Check for closing brace - must be on its own line at or before base_indent
            // This allows braces inside content as long as they have more indentation
            const line_indent = lexer.getIndent(line);
            if (std.mem.eql(u8, trimmed, "}") and line_indent <= base_indent) {
                self.current += 1;
                inside_braces = false;
                break;
            }

            // Track minimum indentation of non-empty lines
            if (trimmed.len > 0) {
                if (min_indent == null or line_indent < min_indent.?) {
                    min_indent = line_indent;
                }
            }

            try source_lines.append(self.allocator, line);
            self.current += 1;
        }

        const dedent = min_indent orelse 0;

        // Calculate total length after dedenting
        const total_len = blk: {
            var len: usize = 0;
            for (source_lines.items) |line| {
                // Dedent: skip first 'dedent' characters if line is long enough
                const dedented_len = if (line.len >= dedent) line.len - dedent else line.len;
                len += dedented_len + 1; // +1 for newline
            }
            break :blk len;
        };

        var source_buf = try self.allocator.alloc(u8, total_len);
        var pos: usize = 0;
        for (source_lines.items) |line| {
            // Dedent: skip first 'dedent' characters
            const dedented = if (line.len >= dedent) line[dedent..] else line;
            @memcpy(source_buf[pos..][0..dedented.len], dedented);
            pos += dedented.len;
            source_buf[pos] = '\n';
            pos += 1;
        }

        const source = source_buf[0..pos];

        // Now parse any output continuations after the }
        const output_continuations = try self.parseContinuations(base_indent);

        return .{
            .source = source,
            .continuations = output_continuations,
            .phantom_type = phantom_type,
        };
    }

    /// Parse inline continuation (same-line |> pattern)
    /// Used for void event chaining: ~void_event() |> another_event()
    fn parseInlineContinuation(self: *Parser, full_line: []const u8, indent: usize) ![]ast.Continuation {
        // Find the first |> that's not inside parentheses
        var pipe_idx: ?usize = null;
        var paren_depth: i32 = 0;
        var i: usize = 0;
        while (i < full_line.len - 1) : (i += 1) {
            const c = full_line[i];
            if (c == '(') paren_depth += 1;
            if (c == ')') paren_depth -= 1;
            if (c == '|' and full_line[i + 1] == '>' and paren_depth == 0) {
                pipe_idx = i;
                break;
            }
        }

        if (pipe_idx == null) {
            // No inline continuation found
            return &[_]ast.Continuation{};
        }

        // Extract the continuation part after |>
        const continuation_part = lexer.trim(full_line[pipe_idx.? + 2..]);

        // Parse the pipeline steps from the continuation
        const steps = try self.parsePipelineSteps(continuation_part);
        const step: ?ast.Step = if (steps.len > 0) steps[0] else null;

        // Create a continuation with empty branch (for void events)
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 1);
        var cont = ast.Continuation{
            .branch = try self.allocator.dupe(u8, ""),  // Empty branch for void event continuation
            .binding = null,
            .binding_type = .branch_payload,  // Use branch_payload even though there's no binding
            .condition = null,
            .condition_expr = null,
            .node = step,
            .indent = indent,
            .continuations = &[_]ast.Continuation{},  // Temporary - will be replaced
            .location = self.getCurrentLocation(),
        };

        // Parse nested continuations (multi-line continuations that follow the inline |>)
        // For example: ~void() |> event()
        //                  | done |> _       <-- nested continuation
        cont.continuations = try self.parseNestedContinuationsForLevel(indent);

        try continuations.append(self.allocator, cont);
        return continuations.toOwnedSlice(self.allocator);
    }

    fn parseContinuations(self: *Parser, base_indent: usize) ![]ast.Continuation {
        _ = base_indent; // Will use this for nested continuations later
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            continuations.deinit(self.allocator);
        }
        
        // Determine expected indent for direct children
        // If this is following a ~flow line at indent 0, children are at indent 0 or greater
        // If there's leading space, look for the first continuation to set the level
        var expected_indent: ?usize = null;
        
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            
            // Check if this is a continuation
            if (!lexer.isContinuationLine(line)) break;
            
            const indent = lexer.getIndent(line);
            
            // Set expected indent from first continuation if not set
            if (expected_indent == null) {
                expected_indent = indent;
            }
            
            // Only take continuations at the expected level
            if (indent != expected_indent.?) break;
            
            // Parse the continuation (which will also parse its nested continuations)
            const location = self.getLineLocation(self.current, indent);
            self.current += 1; // Move past current line before parsing
            const cont = try self.parseContinuationWithNested(indent, location);
            try continuations.append(self.allocator, cont);
        }
        
        return continuations.toOwnedSlice(self.allocator);
    }
    
    fn parseContinuationInternal(self: *Parser, indent: usize, parent_indent: usize, location: errors.SourceLocation) !ast.Continuation {
        _ = parent_indent;
        const line = self.lines[self.current - 1]; // We already incremented
        const trimmed = lexer.trim(line);
        
        // Skip the | prefix
        const after_bar = lexer.trim(trimmed[1..]);
        
        var cont: ast.Continuation = undefined;
        
        if (lexer.startsWith(after_bar, ">")) {
            // Pipeline continuation |>
            cont = try self.parsePipelineContinuationBase(after_bar[1..], indent, location);
        } else if (lexer.startsWith(after_bar, "*")) {
            // Deref continuation
            cont = try self.parseDerefContinuationBase(after_bar[1..], indent, location);
        } else {
            // Branch continuation
            cont = try self.parseBranchContinuationBase(after_bar, indent, location);
        }
        
        // Initialize continuations as empty, will be filled by caller if needed
        cont.continuations = &[_]ast.Continuation{};
        
        return cont;
    }
    
    fn parseContinuationWithNested(self: *Parser, indent: usize, location: errors.SourceLocation) anyerror!ast.Continuation {
        const line = self.lines[self.current - 1]; // We already incremented in parseContinuations
        const trimmed = lexer.trim(line);

        // Skip the | prefix
        const after_bar = lexer.trim(trimmed[1..]);

        var cont: ast.Continuation = undefined;

        if (lexer.startsWith(after_bar, ">")) {
            // Pipeline continuation |>
            cont = try self.parsePipelineContinuationBase(after_bar[1..], indent, location);
        } else if (lexer.startsWith(after_bar, "*")) {
            // Deref continuation
            cont = try self.parseDerefContinuationBase(after_bar[1..], indent, location);
        } else {
            // Branch continuation
            cont = try self.parseBranchContinuationBase(after_bar, indent, location);
        }

        // Parse nested continuations - ONLY greater indentation means nesting
        // Same-indent continuations are siblings, period. No magic auto-nesting.
        cont.continuations = try self.parseNestedContinuationsForLevel(indent);

        return cont;
    }
    
    fn parseNestedContinuationsForLevel(self: *Parser, parent_indent: usize) anyerror![]ast.Continuation {
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            continuations.deinit(self.allocator);
        }
        
        // Look for continuation lines at greater indentation
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            
            if (!lexer.isContinuationLine(line)) break;
            
            const indent = lexer.getIndent(line);
            if (indent <= parent_indent) break;
            
            // Found a nested continuation - parse it and its nested ones recursively
            const location = self.getLineLocation(self.current, indent);
            self.current += 1;
            const cont = try self.parseContinuationWithNested(indent, location);
            
            // After parsing this continuation, check for its nested ones
            
            try continuations.append(self.allocator, cont);
        }
        
        return continuations.toOwnedSlice(self.allocator);
    }
    
    fn parseContinuation(self: *Parser, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);
        
        // Skip the | prefix
        const after_bar = lexer.trim(trimmed[1..]);
        
        if (lexer.startsWith(after_bar, ">")) {
            // Pipeline continuation |>
            return self.parsePipelineContinuation(after_bar[1..], indent, location);
        } else {
            // Branch continuation
            return self.parseBranchContinuation(after_bar, indent, location);
        }
    }
    
    fn parsePipelineContinuation(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        var cont = try self.parsePipelineContinuationBase(content, indent, location);
        cont.continuations = try self.parseNestedContinuationsForLevel(indent);
        return cont;
    }
    
    fn parseDerefContinuationBase(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {

        // Parse: *target [(args)]
        // Note: Additional pipeline steps after deref (|> ...) are not supported in new AST model
        // Each continuation has a single step; chaining should use nested continuations
        const trimmed = lexer.trim(content);

        // Find optional args - look for opening paren
        const paren_idx = std.mem.indexOf(u8, trimmed, "(");

        // Target ends at paren (if present) or at end of identifier
        var target_end = trimmed.len;
        if (paren_idx) |p| {
            target_end = p;
        }

        const target = lexer.trim(trimmed[0..target_end]);

        // Parse optional arguments
        var args: ?[]ast.Arg = null;

        if (paren_idx) |p| {
            const args_end = std.mem.indexOf(u8, trimmed[p..], ")") orelse trimmed.len - p;
            const args_str = trimmed[p..p + args_end + 1];
            const parsed_args = try lexer.parseArgs(self.allocator, args_str);
            defer self.allocator.free(parsed_args);

            // Transfer ownership of the strings to the AST
            var args_list = try std.ArrayList(ast.Arg).initCapacity(self.allocator, parsed_args.len);
            for (parsed_args) |arg| {
                try args_list.append(self.allocator, ast.Arg{
                    .name = arg.name,
                    .value = arg.value,
                });
            }
            args = try args_list.toOwnedSlice(self.allocator);
        }

        // Create the deref step
        const deref_step = ast.Step{
            .deref = .{
                .target = try self.allocator.dupe(u8, target),
                .args = args,
            },
        };

        return ast.Continuation{
            .branch = try self.allocator.dupe(u8, "*deref"),  // Special marker
            .binding = null,
            .condition = null,
            .condition_expr = null,
            .node = deref_step,
            .indent = indent,
            .continuations = &[_]ast.Continuation{}, // Will be filled by caller
            .location = location,
        };
    }
    
    fn parseBranchContinuationBase(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        // Note: *deref syntax is handled at a higher level, not here
        
        // Parse: branch [binding] [|> pipeline...]
        var parts = std.mem.tokenizeAny(u8, content, " ");
        
        const branch_name = parts.next() orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                indent + 2,
                "missing branch name in continuation",
                .{},
            );
            return error.ParseError;
        };

        // Check for |? catch-all continuation
        if (std.mem.eql(u8, branch_name, "?")) {
            // This is a catch-all continuation: |? [Metatype binding] |> pipeline
            var catchall_metatype: ?[]const u8 = null;
            var binding: ?[]const u8 = null;
            var rest = parts.rest();

            // Check if next token is a metatype (Transition, Profile, or Audit)
            if (parts.peek()) |next| {
                if (std.mem.eql(u8, next, "Transition") or
                    std.mem.eql(u8, next, "Profile") or
                    std.mem.eql(u8, next, "Audit")) {
                    catchall_metatype = try self.allocator.dupe(u8, next);
                    _ = parts.next(); // consume metatype

                    // Next token should be the binding variable
                    if (parts.peek()) |binding_name| {
                        if (!std.mem.startsWith(u8, binding_name, "|>")) {
                            // Validate binding is a valid identifier
                            if (!lexer.isValidIdentifier(binding_name)) {
                                try self.reporter.addError(
                                    .PARSE001,
                                    self.current,
                                    indent + 2,
                                    "Invalid binding '{s}'. Bindings must be valid identifiers.",
                                    .{binding_name},
                                );
                                return error.InvalidBinding;
                            }
                            binding = try self.allocator.dupe(u8, binding_name);
                            _ = parts.next(); // consume binding
                        }
                    }
                    rest = parts.rest();
                }
            }


            const catch_all_branch = try self.allocator.dupe(u8, "?");
            try self.context_stack.append(self.allocator, .{
                .in_continuation = .{
                    .branch = catch_all_branch,
                    .binding = binding,
                },
            });
            defer {
                _ = self.context_stack.pop();
                self.allocator.free(catch_all_branch);
            }

            // Parse step if present
            var step: ?ast.Step = null;

            if (std.mem.indexOf(u8, rest, "|>")) |_| {
                const steps = try self.parsePipelineSteps(rest);
                defer self.allocator.free(steps);
                if (steps.len > 0) {
                    step = steps[0];
                }
            }

            return ast.Continuation{
                .branch = try self.allocator.dupe(u8, "?"),  // Special branch name for catch-all
                .binding = binding,
                .binding_type = .branch_payload,
                .is_catchall = true,
                .catchall_metatype = catchall_metatype,
                .condition = null,
                .condition_expr = null,
                .node = step,
                .indent = indent,
                .continuations = &[_]ast.Continuation{},
                .location = location,
            };
        }

        // Normal branch continuation - validate branch name is a valid identifier
        if (!isValidIdentifier(branch_name)) {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                indent + 2,
                "invalid branch name '{s}' - must be a valid identifier",
                .{branch_name},
            );
            return error.ParseError;
        }

        const owned_branch = try self.allocator.dupe(u8, branch_name);

        // Check for binding (with optional annotations like r[mutable])
        var binding: ?[]const u8 = null;
        var binding_annotations: [][]const u8 = &[_][]const u8{};
        var rest = parts.rest();

        if (parts.peek()) |next| {
            if (!std.mem.startsWith(u8, next, "|>") and !std.mem.startsWith(u8, next, "@") and
                !std.mem.eql(u8, next, "when")) {
                // Check if binding has annotations: identifier[ann1|ann2|...]
                var identifier: []const u8 = next;

                if (std.mem.indexOf(u8, next, "[")) |bracket_start| {
                    // Has annotations - split into identifier and annotation parts
                    identifier = next[0..bracket_start];

                    // Find closing bracket
                    if (std.mem.indexOf(u8, next, "]")) |bracket_end| {
                        if (bracket_end > bracket_start + 1) {
                            // Parse annotations between [ and ]
                            const ann_str = next[bracket_start + 1..bracket_end];
                            var ann_list = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
                            errdefer {
                                for (ann_list.items) |ann| {
                                    self.allocator.free(ann);
                                }
                                ann_list.deinit(self.allocator);
                            }

                            var ann_iter = std.mem.splitScalar(u8, ann_str, '|');
                            while (ann_iter.next()) |ann| {
                                const trimmed_ann = lexer.trim(ann);
                                if (trimmed_ann.len > 0) {
                                    try ann_list.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                                }
                            }
                            binding_annotations = try ann_list.toOwnedSlice(self.allocator);
                        }
                    } else {
                        // Unclosed bracket
                        try self.reporter.addError(
                            .PARSE001,
                            self.current,
                            indent + 2,
                            "Unclosed bracket in binding annotation '{s}'.",
                            .{next},
                        );
                        return error.InvalidBinding;
                    }
                }

                // Validate that the identifier part is valid
                if (!lexer.isValidIdentifier(identifier)) {
                    try self.reporter.addError(
                        .PARSE001,
                        self.current,
                        indent + 2,
                        "Invalid binding '{s}'. Bindings must be valid identifiers. Use '|>' for pipelines.",
                        .{identifier},
                    );
                    return error.InvalidBinding;
                }
                // This is a binding
                binding = try self.allocator.dupe(u8, identifier);
                _ = parts.next(); // consume it
                rest = parts.rest();
            }
        }

        // Check for when clause
        var condition: ?[]const u8 = null;
        if (parts.peek()) |next| {
            if (std.mem.eql(u8, next, "when")) {
                _ = parts.next(); // consume "when"

                // Find when the condition ends (before |> or end of line)
                const remaining = parts.rest();
                const pipe_idx = std.mem.indexOf(u8, remaining, "|>");
                
                const condition_str = if (pipe_idx) |idx|
                    lexer.trim(remaining[0..idx])
                else
                    lexer.trim(remaining);
                    
                if (condition_str.len == 0) {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        indent + 2,
                        "missing condition after 'when'",
                        .{},
                    );
                    return error.ParseError;
                }
                
                condition = try self.allocator.dupe(u8, condition_str);
                
                // Update rest to skip past the condition
                if (pipe_idx) |idx| {
                    rest = remaining[idx..];
                } else {
                    rest = "";
                }
            }
        }
        
        // Parse the condition expression if we have one
        var condition_expr: ?*ast.Expression = null;
        if (condition) |cond_str| {
            var expr_parser = expression_parser.ExpressionParser.init(self.allocator, cond_str);
            defer expr_parser.deinit();
            
            condition_expr = expr_parser.parse() catch |err| {
                // Failed to parse when expression - error will be returned
                return err;
            };
        }
        
        // Parse step if present
        var step: ?ast.Step = null;

        if (std.mem.indexOf(u8, rest, "|>")) |_| {
            // Check for multi-line branch constructor in the pipeline
            var full_rest = rest;
            var allocated_rest: ?[]u8 = null;
            defer if (allocated_rest) |ar| self.allocator.free(ar);

            // If we have an opening brace without closing, collect multi-line content
            if (std.mem.indexOf(u8, rest, "{") != null and std.mem.indexOf(u8, rest, "}") == null) {
                var rest_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                defer rest_buf.deinit(self.allocator);
                try rest_buf.appendSlice(self.allocator, rest);

                // Keep reading lines until we find the closing brace
                _ = self.current; // Track that we're modifying current
                while (self.current < self.lines.len) {
                    const next_line = self.lines[self.current];
                    const next_indent = lexer.getIndent(next_line);
                    const next_trimmed = lexer.trim(next_line);

                    // Stop if we hit a line with less indentation (unless it contains a closing brace)
                    if (next_indent < indent) {
                        // Check if this line contains a closing brace
                        if (std.mem.indexOf(u8, next_trimmed, "}") == null) {
                            break;
                        }
                    } else if (next_indent == indent) {
                        // At same indentation - only continue if this is just a closing brace
                        if (!std.mem.eql(u8, next_trimmed, "}") and !std.mem.startsWith(u8, next_trimmed, "} ")) {
                            // This is something else at the same level, not part of our constructor
                            break;
                        }
                    }

                    // Add this line to our content
                    try rest_buf.appendSlice(self.allocator, " ");
                    try rest_buf.appendSlice(self.allocator, next_trimmed);
                    self.current += 1;

                    // Check if we found the closing brace
                    if (std.mem.indexOf(u8, next_trimmed, "}") != null) {
                        break;
                    }
                }

                allocated_rest = try rest_buf.toOwnedSlice(self.allocator);
                full_rest = allocated_rest.?;
            }

            // FIX: Handle |> followed by newline with step on next line
            // Pattern: | branch |>
            //            step_on_next_line()
            // When rest is just "|>" or "  |>" with nothing after, look at next line
            const after_pipe = blk: {
                if (std.mem.indexOf(u8, full_rest, "|>")) |pipe_idx| {
                    break :blk lexer.trim(full_rest[pipe_idx + 2..]);
                }
                break :blk full_rest;
            };

            if (after_pipe.len == 0 and self.current < self.lines.len) {
                // Nothing after |> on this line - check next line for the step
                const next_line = self.lines[self.current];
                const next_indent = lexer.getIndent(next_line);
                const next_trimmed = lexer.trim(next_line);

                // Next line must be more indented and not be a continuation line (|)
                if (next_indent > indent and next_trimmed.len > 0 and next_trimmed[0] != '|') {
                    // This is the step content - consume it
                    self.current += 1;

                    // Build full_rest as "|> " + next line content
                    var next_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                    defer next_buf.deinit(self.allocator);
                    try next_buf.appendSlice(self.allocator, "|> ");
                    try next_buf.appendSlice(self.allocator, next_trimmed);

                    if (allocated_rest) |ar| self.allocator.free(ar);
                    allocated_rest = try next_buf.toOwnedSlice(self.allocator);
                    full_rest = allocated_rest.?;
                }
            }

            // Push continuation context so Source blocks can capture the binding
            try self.context_stack.append(self.allocator, .{
                .in_continuation = .{
                    .branch = owned_branch,
                    .binding = binding,
                },
            });
            defer _ = self.context_stack.pop();

            // Handle multi-line source blocks in continuations
            // If full_rest ends with { (after trimming), collect lines until matching }
            const trimmed_rest = lexer.trim(full_rest);
            if (trimmed_rest.len > 0 and trimmed_rest[trimmed_rest.len - 1] == '{') {
                // Multi-line source block - collect content
                var source_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                defer source_buf.deinit(self.allocator);

                // Start with the opening line
                try source_buf.appendSlice(self.allocator, full_rest);
                try source_buf.append(self.allocator, '\n');

                // Collect lines until we find matching }
                var brace_depth: i32 = 1;
                while (self.current < self.lines.len and brace_depth > 0) {
                    const src_line = self.lines[self.current];
                    const src_trimmed = lexer.trim(src_line);

                    // Count braces
                    for (src_trimmed) |c| {
                        if (c == '{') brace_depth += 1;
                        if (c == '}') brace_depth -= 1;
                    }

                    try source_buf.appendSlice(self.allocator, src_line);
                    try source_buf.append(self.allocator, '\n');
                    self.current += 1;
                }

                if (allocated_rest) |ar| self.allocator.free(ar);
                allocated_rest = try source_buf.toOwnedSlice(self.allocator);
                full_rest = allocated_rest.?;
            }

            const steps = try self.parsePipelineSteps(full_rest);
            defer self.allocator.free(steps);
            if (steps.len > 0) {
                step = steps[0];
            }
        }

        return ast.Continuation{
            .branch = owned_branch,
            .binding = binding,
            .binding_annotations = binding_annotations,
            .binding_type = .branch_payload,  // Parser always uses branch_payload; backend determines transition semantics
            .condition = condition,
            .condition_expr = condition_expr,
            .node = step,
            .indent = indent,
            .continuations = &[_]ast.Continuation{}, // Will be filled by caller
            .location = location,
        };
    }
    
    fn parseNestedContinuations(self: *Parser, parent_indent: usize) ![]ast.Continuation {
        var continuations = try std.ArrayList(ast.Continuation).initCapacity(self.allocator, 8);
        errdefer {
            for (continuations.items) |*cont| {
                cont.deinit(self.allocator);
            }
            continuations.deinit(self.allocator);
        }
        
        // Look for continuation lines at greater indentation
        const saved_current = self.current;
        while (self.current < self.lines.len) {
            const line = self.lines[self.current];
            
            // Check if this is a continuation line
            if (!lexer.isContinuationLine(line)) break;
            
            const indent = lexer.getIndent(line);
            
            // Only take continuations with greater indentation than parent
            if (indent <= parent_indent) break;
            
            // Parse this continuation and its nested ones
            self.current += 1;
        }
        
        // Now parse them in a second pass to avoid circular dependencies
        const end_current = self.current;
        self.current = saved_current;
        
        while (self.current < end_current) {
            const line = self.lines[self.current];
            if (!lexer.isContinuationLine(line)) break;
            
            const indent = lexer.getIndent(line);
            if (indent <= parent_indent) break;
            
            self.current += 1;
            const cont = try self.parseContinuationInternal(indent, parent_indent, self.getLineLocation(self.current - 1, indent));
            try continuations.append(self.allocator, cont);
        }
        
        return continuations.toOwnedSlice(self.allocator);
    }
    
    fn parseDerefContinuation(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        var cont = try self.parseDerefContinuationBase(content, indent, location);
        cont.continuations = try self.parseNestedContinuationsForLevel(indent);
        return cont;
    }

    fn parseBranchContinuation(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        var cont = try self.parseBranchContinuationBase(content, indent, location);

        // Advance cursor to look for nested continuations on following lines
        // (parseNestedContinuationsForLevel expects self.current to point at potential nested lines)
        self.current += 1;

        cont.continuations = try self.parseNestedContinuationsForLevel(indent);
        return cont;
    }
    
    fn parsePipelineContinuationBase(self: *Parser, content: []const u8, indent: usize, location: errors.SourceLocation) !ast.Continuation {
        // This is a |> continuation (pipeline step on new line)
        // Check if we have a multi-line branch constructor
        var full_content = content;
        var allocated_content: ?[]u8 = null;
        defer if (allocated_content) |ac| self.allocator.free(ac);
        
        // Check if this might be starting a multi-line branch constructor
        if (std.mem.indexOf(u8, content, "{") != null and std.mem.indexOf(u8, content, "}") == null) {
            // We have an opening brace but no closing brace - look for it on subsequent lines
            var content_buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
            defer content_buf.deinit(self.allocator);
            try content_buf.appendSlice(self.allocator, content);
            
            // Track brace depth to handle nested objects
            var brace_depth: i32 = 0;
            for (content) |c| {
                if (c == '{') brace_depth += 1;
                if (c == '}') brace_depth -= 1;
            }
            
            // Keep reading lines until all braces are matched
            while (self.current < self.lines.len and brace_depth > 0) {
                const next_line = self.lines[self.current];
                const next_indent = lexer.getIndent(next_line);
                
                // Stop if we hit a line with less indentation (unless it's just closing braces)
                const next_trimmed = lexer.trim(next_line);
                if (next_indent <= indent) {
                    // Check if it's only closing braces
                    var only_closing_braces = true;
                    for (next_trimmed) |c| {
                        if (c != '}' and c != ' ' and c != '\t') {
                            only_closing_braces = false;
                            break;
                        }
                    }
                    if (!only_closing_braces) break;
                }
                
                // Add this line to our content
                try content_buf.appendSlice(self.allocator, " ");
                try content_buf.appendSlice(self.allocator, next_trimmed);
                self.current += 1;
                
                // Update brace depth
                for (next_trimmed) |c| {
                    if (c == '{') brace_depth += 1;
                    if (c == '}') brace_depth -= 1;
                }
            }
            
            allocated_content = try content_buf.toOwnedSlice(self.allocator);
            full_content = allocated_content.?;
        }
        
        const steps = try self.parsePipelineSteps(full_content);
        const step: ?ast.Step = if (steps.len > 0) steps[0] else null;

        return ast.Continuation{
            .branch = try self.allocator.dupe(u8, ""),  // Empty branch for pipeline continuation
            .binding = null,
            .condition = null,
            .condition_expr = null,
            .node = step,
            .indent = indent,
            .continuations = &[_]ast.Continuation{}, // Will be filled by caller
            .location = location,
        };
    }
    
    fn parsePipelineSteps(self: *Parser, content: []const u8) ![]ast.Step {
        var steps = try std.ArrayList(ast.Step).initCapacity(self.allocator, 8);
        errdefer {
            for (steps.items) |*step| {
                step.deinit(self.allocator);
            }
            steps.deinit(self.allocator);
        }
        
        // Check if there's a @label at the end (without |>)
        var working_content = content;
        var trailing_label: ?[]const u8 = null;
        if (lexer.extractLabel(content)) |label| {
            trailing_label = try self.allocator.dupe(u8, label);
            working_content = lexer.withoutLabel(content);
        }
        
        // Split on |> and parse each step
        var iter = std.mem.splitSequence(u8, working_content, "|>");
        while (iter.next()) |step_str| {
            const trimmed = lexer.trim(step_str);
            if (trimmed.len == 0) continue;
            
            const step = try self.parseStep(trimmed);
            try steps.append(self.allocator, step);
        }
        
        // Add trailing label if present
        if (trailing_label) |label| {
            try steps.append(self.allocator, ast.Step{ .label_apply = label });
        }
        
        return steps.toOwnedSlice(self.allocator);
    }
    
    fn parseStep(self: *Parser, content: []const u8) !ast.Step {
        // Strip comments first (everything after //)
        var clean_content = content;
        if (std.mem.indexOf(u8, content, "//")) |comment_idx| {
            clean_content = content[0..comment_idx];
        }
        
        // Check for terminal marker (_)
        if (std.mem.eql(u8, lexer.trim(clean_content), "_")) {
            return ast.Step{ .terminal = {} };
        }

        // Check for label anchor declaration (#name event(...))
        if (lexer.startsWith(clean_content, "#")) {
            const after_hash = lexer.trim(clean_content[1..]);

            // Check if there's an event invocation after the label
            // Pattern: #label event(args) or #label event.path(args)
            const space_idx = std.mem.indexOfScalar(u8, after_hash, ' ');
            if (space_idx) |idx| {
                // We have something after the label - check if it looks like an invocation
                const potential_label = after_hash[0..idx];
                const after_space = lexer.trim(after_hash[idx + 1..]);

                // Check if what follows looks like an event invocation
                if (std.mem.indexOfScalar(u8, after_space, '(') != null or
                    std.mem.indexOfScalar(u8, after_space, '.') != null) {
                    // This is a label declaration pattern: #label event(args)
                    // Parse the invocation part
                    const inv_step = try self.parseStep(after_space);
                    if (inv_step == .invocation) {
                        return ast.Step{
                            .label_with_invocation = .{
                                .label = try self.allocator.dupe(u8, potential_label),
                                .invocation = inv_step.invocation,
                                .is_declaration = true,  // # means declaration/anchor
                            }
                        };
                    }
                }
            }

            // If we get here, it's malformed - for now, parse as invocation
            // TODO: Better error handling
            return try self.parseStep(after_hash);
        }

        // Check for label jump (@label(args))
        if (lexer.startsWith(clean_content, "@")) {
            const after_at = lexer.trim(clean_content[1..]);

            // Check if there's a paren (args) after the label: @label(args)
            const paren_idx = std.mem.indexOfScalar(u8, after_at, '(');
            if (paren_idx) |p_idx| {
                // Extract label name (everything before the paren)
                const label_name = lexer.trim(after_at[0..p_idx]);

                // Find the matching closing parenthesis
                var depth: usize = 1;
                var args_end = p_idx + 1;
                while (args_end < after_at.len and depth > 0) : (args_end += 1) {
                    if (after_at[args_end] == '(') depth += 1;
                    if (after_at[args_end] == ')') depth -= 1;
                }

                // Parse the arguments
                const args_str = after_at[p_idx..args_end];
                const parsed_args = try lexer.parseArgs(self.allocator, args_str);
                defer self.allocator.free(parsed_args);

                // Transfer ownership to AST
                var arg_list = try std.ArrayList(ast.Arg).initCapacity(self.allocator, parsed_args.len);
                defer arg_list.deinit(self.allocator);
                for (parsed_args) |arg| {
                    try arg_list.append(self.allocator, ast.Arg{
                        .name = arg.name,
                        .value = arg.value,
                    });
                }

                return ast.Step{
                    .label_jump = .{
                        .label = try self.allocator.dupe(u8, label_name),
                        .args = try arg_list.toOwnedSlice(self.allocator),
                    }
                };
            }

            // Simple label apply without args (for compatibility)
            return ast.Step{ .label_apply = try self.allocator.dupe(u8, after_at) };
        }
        
        // Check for branch constructor: identifier { field: value, ... }
        // Also recognize .{ as shorthand branch constructor (immediate return)
        const brace_idx = std.mem.indexOf(u8, clean_content, "{");
        if (brace_idx) |b_idx| {
            const before_brace = lexer.trim(clean_content[0..b_idx]);

            // Check for .{ pattern (immediate branch constructor)
            const is_immediate_bc = std.mem.eql(u8, before_brace, ".");

            // Check if this is a Source block invocation: eventName [Type]{
            // Look for [ ] pattern before the {
            const has_bracket = std.mem.indexOf(u8, before_brace, "[") != null and
                std.mem.indexOf(u8, before_brace, "]") != null;

            // Check for regular branch constructor pattern (no dot, no paren before brace)
            const is_regular_bc = std.mem.indexOf(u8, before_brace, ".") == null and
                !std.mem.containsAtLeast(u8, before_brace, 1, "(") and
                !has_bracket;  // Not a Source block!

            if (is_immediate_bc or is_regular_bc) {
                // It's a branch constructor!
                // Check if we're in a proc context
                const in_proc = self.isInProc();
                return ast.Step{ .branch_constructor = try self.parseBranchConstructorWithContext(clean_content, in_proc) };
            }
        }
        
        // Otherwise it's an invocation - always an event now
        return ast.Step{ .invocation = try self.parseEventInvocation(clean_content) };
    }
    
    fn splitFieldsRespectingBraces(self: *Parser, fields_str: []const u8) ![][]const u8 {
        var result = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer result.deinit(self.allocator);

        var brace_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        var paren_depth: i32 = 0;
        var in_string = false;
        var field_start: usize = 0;

        var i: usize = 0;
        while (i < fields_str.len) : (i += 1) {
            const c = fields_str[i];

            // Handle string literals
            if (c == '"' and (i == 0 or fields_str[i-1] != '\\')) {
                in_string = !in_string;
                continue;
            }

            if (in_string) continue;

            // Track brace, bracket, and paren depth
            if (c == '{') brace_depth += 1;
            if (c == '}') brace_depth -= 1;
            if (c == '[') bracket_depth += 1;
            if (c == ']') bracket_depth -= 1;
            if (c == '(') paren_depth += 1;
            if (c == ')') paren_depth -= 1;

            // Split on comma only at top level (outside all nested structures)
            if (c == ',' and brace_depth == 0 and bracket_depth == 0 and paren_depth == 0) {
                const field = lexer.trim(fields_str[field_start..i]);
                if (field.len > 0) {
                    try result.append(self.allocator, field);
                }
                field_start = i + 1;
            }
        }
        
        // Don't forget the last field
        const last_field = lexer.trim(fields_str[field_start..]);
        if (last_field.len > 0) {
            try result.append(self.allocator, last_field);
        }
        
        return try result.toOwnedSlice(self.allocator);
    }
    
    fn parseBranchConstructor(self: *Parser, content: []const u8) !ast.BranchConstructor {
        return self.parseBranchConstructorWithContext(content, self.isInProc());
    }
    
    fn parseBranchConstructorWithContext(self: *Parser, content: []const u8, _: bool) !ast.BranchConstructor {
        // Format: branch_name { field: value, field: value }
        // OR shorthand: .{ .branch_name = .{ fields } }
        const brace_idx = std.mem.indexOf(u8, content, "{") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                1,
                "expected '{{' in branch constructor",
                .{},
            );
            return error.ParseError;
        };

        // Find the closing brace first (needed for both regular and shorthand forms)
        const closing_idx = std.mem.lastIndexOf(u8, content, "}") orelse {
            try self.reporter.addError(
                .PARSE004,
                self.current + 1,
                @intCast(brace_idx + 1),
                "unmatched '{{' in branch constructor",
                .{},
            );
            return error.ParseError;
        };

        var branch_name = lexer.trim(content[0..brace_idx]);
        var fields_content: []const u8 = content[brace_idx + 1 .. closing_idx];

        // Check for .{ shorthand (immediate return)
        // Format: .{ .branch_name = .{ fields } }
        if (std.mem.eql(u8, branch_name, ".")) {
            const inner_content = lexer.trim(content[brace_idx + 1 .. closing_idx]);
            // Format should be: .branch_name = .{ fields }
            // Extract branch_name from .branch_name
            if (lexer.startsWith(inner_content, ".")) {
                const after_dot = inner_content[1..];
                const eq_idx = std.mem.indexOf(u8, after_dot, "=");
                if (eq_idx) |idx| {
                    branch_name = lexer.trim(after_dot[0..idx]);
                    // Extract fields from the inner .{ fields } part
                    const after_eq = lexer.trim(after_dot[idx + 1..]);
                    // Find the inner .{ ... }
                    const inner_brace_idx = std.mem.indexOf(u8, after_eq, "{");
                    const inner_closing_idx = std.mem.lastIndexOf(u8, after_eq, "}");
                    if (inner_brace_idx != null and inner_closing_idx != null) {
                        fields_content = after_eq[inner_brace_idx.? + 1 .. inner_closing_idx.?];
                    } else {
                        try self.reporter.addError(
                            .PARSE003,
                            self.current + 1,
                            0,
                            "invalid .{{ shorthand syntax - expected .{{ .branch_name = .{{ fields }} }}",
                            .{},
                        );
                        return error.ParseError;
                    }
                } else {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current + 1,
                        0,
                        "invalid .{{ shorthand syntax - expected .{{ .branch_name = ... }}",
                        .{},
                    );
                    return error.ParseError;
                }
            } else {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    0,
                    "invalid .{{ shorthand syntax - expected .{{ .branch_name = ... }}",
                    .{},
                );
                return error.ParseError;
            }
        }

        // Validate branch name is a valid identifier
        if (!isValidIdentifier(branch_name)) {
            try self.reporter.addError(
                .PARSE003,
                self.current + 1,
                0,
                "invalid branch name '{s}' in constructor - must be a valid identifier",
                .{branch_name},
            );
            return error.ParseError;
        }

        const fields_str = lexer.trim(fields_content);

        // Check if this is a plain value (no field separators at the top level)
        // A plain value has no ':' or '=' outside of nested braces/parens/brackets
        const is_plain_value = blk: {
            if (fields_str.len == 0) break :blk false;
            var depth: i32 = 0;
            for (fields_str) |c| {
                switch (c) {
                    '{', '(', '[' => depth += 1,
                    '}', ')', ']' => depth -= 1,
                    ':', '=' => if (depth == 0) break :blk false,
                    else => {},
                }
            }
            break :blk true;
        };

        if (is_plain_value) {
            // Plain value syntax: branch { expr } → return .{ .branch = expr }
            return ast.BranchConstructor{
                .branch_name = try self.allocator.dupe(u8, branch_name),
                .fields = &.{},
                .plain_value = try self.allocator.dupe(u8, fields_str),
                .has_expressions = true,
            };
        }

        var fields = try std.ArrayList(ast.Field).initCapacity(self.allocator, 4);
        errdefer {
            for (fields.items) |*field| field.deinit(self.allocator);
            fields.deinit(self.allocator);
        }

        if (fields_str.len > 0) {
            // Parse fields: field: value, field: value
            // But be careful with nested objects that contain commas
            const fields_list = try self.splitFieldsRespectingBraces(fields_str);
            defer self.allocator.free(fields_list);

            for (fields_list) |field_str| {
                const trimmed = lexer.trim(field_str);
                // Support both : and = as field separators
                const colon_idx = std.mem.indexOf(u8, trimmed, ":");
                const eq_idx = std.mem.indexOf(u8, trimmed, "=");
                const sep_idx = if (colon_idx) |c_idx|
                    (if (eq_idx) |e_idx| @min(c_idx, e_idx) else c_idx)
                else
                    eq_idx;

                var field_name: []const u8 = if (sep_idx) |idx| blk: {
                    // Explicit form: name: value or .name = value
                    break :blk lexer.trim(trimmed[0..idx]);
                } else blk: {
                    // Shorthand form - check if it's a field access like b.value
                    const dot_idx = std.mem.lastIndexOf(u8, trimmed, ".");
                    if (dot_idx) |idx| {
                        // Take the field name after the dot
                        break :blk lexer.trim(trimmed[idx + 1..]);
                    } else {
                        // Simple identifier - use as is
                        break :blk trimmed;
                    }
                };

                // Strip leading . from field name (Zig anonymous struct syntax)
                if (lexer.startsWith(field_name, ".")) {
                    field_name = field_name[1..];
                }

                const field_value = if (sep_idx) |idx|
                    lexer.trim(trimmed[idx + 1 ..])
                else
                    trimmed;  // The whole expression becomes the value
                
                // Expressions are allowed everywhere - they're pure by construction
                // (no arbitrary function calls, side effects controlled by event system)
                const is_complex_expr = !self.isValidBranchConstructorValue(field_value);

                // Always store expression string for code generation
                try fields.append(self.allocator, ast.Field{
                    .name = try self.allocator.dupe(u8, field_name),
                    .type = try self.allocator.dupe(u8, "auto"), // Type will be inferred
                    .expression_str = try self.allocator.dupe(u8, field_value),
                    .expression = null,
                    .owns_expression = false,
                });

                _ = is_complex_expr; // May be useful for optimization hints later
            }
        }

        // Has expressions if any field has a non-simple value
        const has_expressions = true; // All branch constructors can have expressions now
        
        return ast.BranchConstructor{
            .branch_name = try self.allocator.dupe(u8, branch_name),
            .fields = try fields.toOwnedSlice(self.allocator),
            .has_expressions = has_expressions,
        };
    }
    
    fn parseBranchPayloadShape(self: *Parser, branch_line: []const u8) !ast.Shape {
        // Look for opening brace on the current line
        const brace_start = std.mem.indexOf(u8, branch_line, "{") orelse {
            // No shape specified, return empty shape
            return ast.Shape{ .fields = &.{} };
        };
        
        // Check if closing brace is on the same line - BUT find the MATCHING one
        const close_offset = blk: {
            var depth: i32 = 0;
            var i = brace_start;
            while (i < branch_line.len) : (i += 1) {
                if (branch_line[i] == '{') {
                    depth += 1;
                } else if (branch_line[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        // Found matching closing brace
                        break :blk i - brace_start;
                    }
                }
            }
            break :blk null;
        };
        
        if (close_offset) |off| {
            // Single-line shape
            const content = lexer.trim(branch_line[brace_start + 1..brace_start + off]);
            return self.parseShape(content);
        }
        
        // Multi-line shape - collect lines until matching brace
        var shape_content = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer shape_content.deinit(self.allocator);
        
        // Add content from the first line (after the opening brace)
        const first_line_content = lexer.trim(branch_line[brace_start + 1..]);
        if (first_line_content.len > 0) {
            try shape_content.appendSlice(self.allocator, first_line_content);
            try shape_content.append(self.allocator, ',');
        }
        
        // Track brace depth to handle nested types
        var brace_depth: i32 = 1;
        const start_line = self.current;
        
        while (self.current < self.lines.len and brace_depth > 0) {
            const line = self.lines[self.current];
            self.current += 1;
            
            // Skip empty lines
            const trimmed = lexer.trim(line);
            if (trimmed.len == 0) continue;
            
            // Count braces in this line
            for (trimmed) |c| {
                if (c == '{') brace_depth += 1;
                if (c == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        // Found closing brace - extract content before it
                        const end_idx = std.mem.indexOf(u8, trimmed, "}").?;
                        const final_content = lexer.trim(trimmed[0..end_idx]);
                        if (final_content.len > 0) {
                            try shape_content.appendSlice(self.allocator, final_content);
                        }
                        // Don't back up - parseBranch expects current to be at the next line
                        break;
                    }
                }
            }
            
            if (brace_depth > 0) {
                // Add this line's content
                try shape_content.appendSlice(self.allocator, trimmed);
                try shape_content.append(self.allocator, ',');
            }
        }
        
        if (brace_depth != 0) {
            try self.reporter.addError(
                .PARSE004,
                start_line,
                @intCast(brace_start),
                "unmatched '{{' in branch payload shape",
                .{},
            );
            return error.ParseError;
        }
        
        return self.parseShape(shape_content.items);
    }
    
    fn parseBranch(self: *Parser) !ast.Branch {
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);
        
        // We'll consume this line
        self.current += 1;
        
        // Skip | prefix
        const after_bar = lexer.trim(trimmed[1..]);

        // Check for & prefix (deferred branch)
        var is_deferred = false;
        var branch_start = after_bar;
        if (lexer.startsWith(after_bar, "&")) {
            is_deferred = true;
            branch_start = lexer.trim(after_bar[1..]);
        }

        // Check for ? prefix (optional branch)
        var is_optional = false;
        if (lexer.startsWith(branch_start, "?")) {
            is_optional = true;
            branch_start = lexer.trim(branch_start[1..]);
        }

        // Check for struct shape { ... } vs identity type
        const brace_idx = std.mem.indexOf(u8, branch_start, "{");

        var annotations = try std.ArrayList([]const u8).initCapacity(self.allocator, 4);
        errdefer {
            for (annotations.items) |ann| self.allocator.free(ann);
            annotations.deinit(self.allocator);
        }

        // Identity branch syntax: | branch Type or | branch Type[annotation]
        // Struct branch syntax: | branch { field: Type } or | branch { field: Type }[annotation]
        if (brace_idx == null) {
            // Identity branch: | branch Type[annotation]
            // Find branch name (first identifier token)
            var name_end: usize = 0;
            while (name_end < branch_start.len and
                   (std.ascii.isAlphanumeric(branch_start[name_end]) or branch_start[name_end] == '_')) {
                name_end += 1;
            }

            if (name_end == 0) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "branch missing name",
                    .{},
                );
                return error.ParseError;
            }

            const branch_name = branch_start[0..name_end];

            // Validate branch name is a valid identifier
            if (!isValidIdentifier(branch_name)) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current - 1,
                    1,
                    "invalid branch name '{s}' - must be a valid identifier",
                    .{branch_name},
                );
                return error.ParseError;
            }

            // Rest is the type, possibly with [annotation]
            var type_and_annotation = lexer.trim(branch_start[name_end..]);

            // Check if this is an empty payload (just branch name, no type)
            if (type_and_annotation.len == 0) {
                // Empty payload - like | done
                return ast.Branch{
                    .name = try self.allocator.dupe(u8, branch_name),
                    .payload = ast.Shape{ .fields = &.{} },
                    .is_deferred = is_deferred,
                    .is_optional = is_optional,
                    .annotations = try annotations.toOwnedSlice(self.allocator),
                };
            }

            // Find annotation start (last [ that starts an annotation, not part of type)
            // Annotations are [identifier], array types are [number] or [_]
            var annotation_start: ?usize = null;
            var i: usize = type_and_annotation.len;
            while (i > 0) {
                i -= 1;
                if (type_and_annotation[i] == '[') {
                    // Check if this is an annotation (followed by identifier) or array type (followed by digit or _)
                    if (i + 1 < type_and_annotation.len) {
                        const next_char = type_and_annotation[i + 1];
                        if (std.ascii.isAlphabetic(next_char)) {
                            // This is an annotation like [mutable]
                            annotation_start = i;
                            break;
                        }
                    }
                }
            }

            var type_str: []const u8 = undefined;
            if (annotation_start) |ann_start| {
                type_str = lexer.trim(type_and_annotation[0..ann_start]);
                const annotation_content = type_and_annotation[ann_start..];

                // Parse annotation: [name]
                if (annotation_content.len > 2 and annotation_content[0] == '[') {
                    const close_bracket = std.mem.indexOf(u8, annotation_content, "]") orelse annotation_content.len - 1;
                    const ann_name = annotation_content[1..close_bracket];
                    try annotations.append(self.allocator, try self.allocator.dupe(u8, ann_name));
                }
            } else {
                type_str = type_and_annotation;
            }

            // Create identity field with __type_ref convention
            var fields = try self.allocator.alloc(ast.Field, 1);
            fields[0] = ast.Field{
                .name = try self.allocator.dupe(u8, "__type_ref"),
                .type = try self.allocator.dupe(u8, type_str),
            };

            return ast.Branch{
                .name = try self.allocator.dupe(u8, branch_name),
                .payload = ast.Shape{ .fields = fields },
                .is_deferred = is_deferred,
                .is_optional = is_optional,
                .annotations = try annotations.toOwnedSlice(self.allocator),
            };
        }

        // Struct branch syntax: | branch { field: Type }
        const branch_name = lexer.trim(branch_start[0..brace_idx.?]);

        // Validate branch name is a valid identifier
        if (!isValidIdentifier(branch_name)) {
            try self.reporter.addError(
                .PARSE003,
                self.current - 1,
                1,
                "invalid branch name '{s}' - must be a valid identifier",
                .{branch_name},
            );
            return error.ParseError;
        }

        // Parse the payload shape (might be multi-line)
        // Note: parseBranchPayloadShape will advance self.current if multi-line
        const payload = try self.parseBranchPayloadShape(branch_start);

        // Find the closing brace position
        const close_brace_idx = blk: {
            var depth: i32 = 0;
            var idx: usize = brace_idx.?;
            while (idx < branch_start.len) : (idx += 1) {
                if (branch_start[idx] == '{') {
                    depth += 1;
                } else if (branch_start[idx] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        break :blk idx;
                    }
                }
            }
            break :blk null;
        };

        if (close_brace_idx) |close_idx| {
            // Single-line shape - check for annotations after }
            const after_brace = lexer.trim(branch_start[close_idx + 1..]);
            if (lexer.startsWith(after_brace, "[")) {
                // Find matching ] for the entire annotation block, respecting nested brackets
                const close_bracket_idx = blk: {
                    var depth: i32 = 0;
                    var i: usize = 0;
                    while (i < after_brace.len) : (i += 1) {
                        if (after_brace[i] == '[') {
                            depth += 1;
                        } else if (after_brace[i] == ']') {
                            depth -= 1;
                            if (depth == 0) {
                                break :blk i;
                            }
                        }
                    }
                    break :blk null;
                } orelse {
                    try self.reporter.addError(
                        .PARSE003,
                        self.current - 1,
                        @intCast(close_idx + 1),
                        "branch annotation missing closing ']'",
                        .{},
                    );
                    return error.ParseError;
                };

                const annotation_content = lexer.trim(after_brace[1..close_bracket_idx]);
                // Split on | for multiple annotations
                var iter = std.mem.splitScalar(u8, annotation_content, '|');
                while (iter.next()) |ann| {
                    const trimmed_ann = lexer.trim(ann);
                    if (trimmed_ann.len > 0) {
                        try annotations.append(self.allocator, try self.allocator.dupe(u8, trimmed_ann));
                    }
                }
            }
        }

        return ast.Branch{
            .name = try self.allocator.dupe(u8, branch_name),
            .payload = payload,
            .is_deferred = is_deferred,
            .is_optional = is_optional,
            .annotations = try annotations.toOwnedSlice(self.allocator),
        };
    }
    
    /// Split fields on commas, but respect bracket boundaries
    /// e.g., "a: Type[x,y], b: Other" -> ["a: Type[x,y]", "b: Other"]
    /// Check if a string is a valid identifier (letters, numbers, underscores, no leading digit)
    fn isValidIdentifier(name: []const u8) bool {
        if (name.len == 0) return false;
        
        // First character must be letter or underscore
        const first = name[0];
        if (!std.ascii.isAlphabetic(first) and first != '_') return false;
        
        // Rest can be letters, numbers, or underscores
        for (name[1..]) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        
        return true;
    }
    
    fn splitFieldsRespectingBrackets(self: *Parser, content: []const u8) !std.ArrayList([]const u8) {
        var result = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        errdefer result.deinit(self.allocator);

        var bracket_depth: i32 = 0;
        var paren_depth: i32 = 0;
        var field_start: usize = 0;
        var i: usize = 0;

        while (i < content.len) : (i += 1) {
            const ch = content[i];

            if (ch == '[') {
                bracket_depth += 1;
            } else if (ch == ']') {
                bracket_depth -= 1;
            } else if (ch == '(') {
                paren_depth += 1;
            } else if (ch == ')') {
                paren_depth -= 1;
            } else if (ch == ',' and bracket_depth == 0 and paren_depth == 0) {
                // Found a field separator at top level (outside all brackets and parens)
                const field = lexer.trim(content[field_start..i]);
                if (field.len > 0) {
                    try result.append(self.allocator, field);
                }
                field_start = i + 1;
            }
        }

        // Don't forget the last field
        if (field_start < content.len) {
            const field = lexer.trim(content[field_start..]);
            if (field.len > 0) {
                try result.append(self.allocator, field);
            }
        }

        return result;
    }
    
    fn parseShape(self: *Parser, content: []const u8) !ast.Shape {
        var fields = try std.ArrayList(ast.Field).initCapacity(self.allocator, 8);
        errdefer {
            for (fields.items) |*field| {
                field.deinit(self.allocator);
            }
            fields.deinit(self.allocator);
        }

        if (content.len == 0) {
            // Empty shape - no bindable payload
            return ast.Shape{ .fields = try fields.toOwnedSlice(self.allocator) };
        }

        // Check for wildcard shape: { * }
        // Means "has bindable payload, shape unspecified"
        if (std.mem.eql(u8, lexer.trim(content), "*")) {
            return ast.Shape{
                .fields = try fields.toOwnedSlice(self.allocator),
                .is_wildcard = true,
            };
        }
        
        // Parse fields: name: type, name: type, ...
        // BUT respect brackets - don't split on commas inside []
        var field_strings = try self.splitFieldsRespectingBrackets(content);
        defer field_strings.deinit(self.allocator);
        
        for (field_strings.items) |field_str| {
            const trimmed_field = lexer.trim(field_str);
            if (trimmed_field.len == 0) continue;
            
            const colon_idx = std.mem.indexOf(u8, trimmed_field, ":") orelse {
                try self.reporter.addError(
                    .PARSE003,
                    self.current + 1,
                    1,
                    "field missing type annotation",
                    .{},
                );
                continue;
            };
            
            const field_name = lexer.trim(trimmed_field[0..colon_idx]);
            var field_type = lexer.trim(trimmed_field[colon_idx + 1..]);

            // Check for special types: Source, File, EmbedFile, and Expression
            // Source can have phantom type: Source[HTML], Source[SQL], etc.
            // Expression captures Zig expressions verbatim as strings
            var is_source = false;
            var is_file = false;
            var is_embed_file = false;
            var is_expression = false;
            if (std.mem.eql(u8, field_type, "Source") or std.mem.startsWith(u8, field_type, "Source[")) {
                is_source = true;
            } else if (std.mem.eql(u8, field_type, "Expression") or std.mem.startsWith(u8, field_type, "Expression[")) {
                is_expression = true;
            } else if (std.mem.eql(u8, field_type, "File")) {
                is_file = true;
            } else if (std.mem.eql(u8, field_type, "EmbedFile")) {
                is_embed_file = true;
            }

            // Check for phantom tags/states: Type[tag] or *Type[state]
            // Opaque capture - analyzers decide interpretation!
            var phantom: ?[]const u8 = null;
            if (!is_source and !is_file and !is_embed_file and !is_expression) {
                // Find the LAST matching bracket pair which might be a phantom tag
                // We need to match brackets properly, respecting nesting
                var last_phantom_start: ?usize = null;
                var last_phantom_end: ?usize = null;
                
                // Scan from the end backwards to find the last complete bracket pair
                if (field_type.len > 0 and field_type[field_type.len - 1] == ']') {
                    // Type ends with ], might have a phantom tag
                    var bracket_depth: i32 = 0;
                    var i = field_type.len - 1;
                    const end_pos = i;
                    
                    // Find matching [ for this ]
                    while (i > 0) : (i -= 1) {
                        if (field_type[i] == ']') {
                            bracket_depth += 1;
                        } else if (field_type[i] == '[') {
                            bracket_depth -= 1;
                            if (bracket_depth == 0) {
                                // Found the matching opening bracket
                                last_phantom_start = i;
                                last_phantom_end = end_pos;
                                break;
                            }
                        }
                    }
                }
                
                // Check if we found a phantom tag
                if (last_phantom_start) |start| {
                    if (last_phantom_end) |end| {
                        // Ensure this isn't at position 0 (would be array type like []u8)
                        if (start > 0) {
                            const bracket_content = field_type[start + 1..end];
                            
                            // Check if this looks like a tag (not a number or empty)
                            const is_number = blk: {
                                for (bracket_content) |c| {
                                    if (c < '0' or c > '9') break :blk false;
                                }
                                break :blk bracket_content.len > 0;
                            };
                            
                            if (!is_number and bracket_content.len > 0) {
                                // This is a phantom tag/state!
                                // Just capture the raw string - analyzers interpret
                                phantom = try self.allocator.dupe(u8, bracket_content);
                                
                                // Remove tag from type for Zig emission
                                field_type = field_type[0..start];
                            }
                        }
                    }
                }
            }
            
            // Check for cross-module type reference: module.path:TypeName
            var module_path: ?[]const u8 = null;
            var actual_type = field_type;

            // Count colons - should be 0 (local type) or 1 (cross-module type)
            const colon_count = std.mem.count(u8, field_type, ":");
            if (colon_count > 1) {
                // Multiple colons are ambiguous - which is the module boundary?
                try self.reporter.addError(.PARSE003, self.current, 1,
                    "Multiple colons in type reference '{s}' - expected format 'module.path:Type' or just 'Type'",
                    .{field_type});
                return error.ParseError;
            }

            // Parse cross-module type reference
            if (std.mem.indexOfScalar(u8, field_type, ':')) |module_colon_idx| {
                // Extract module path before the colon
                module_path = try self.allocator.dupe(u8, field_type[0..module_colon_idx]);
                // Everything after colon is the type name
                actual_type = field_type[module_colon_idx + 1..];
            }

            const field = ast.Field{
                .name = try self.allocator.dupe(u8, field_name),
                .type = try self.allocator.dupe(u8, actual_type),
                .module_path = module_path,
                .phantom = phantom,
                .is_source = is_source,
                .is_file = is_file,
                .is_embed_file = is_embed_file,
                .is_expression = is_expression,
            };

            try fields.append(self.allocator, field);
        }
        
        return ast.Shape{ .fields = try fields.toOwnedSlice(self.allocator) };
    }
    
    fn isValidBranchConstructorValue(self: *Parser, value: []const u8) bool {
        _ = self;
        const trimmed = lexer.trim(value);
        
        // Allow string literals
        if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
            return true;
        }
        
        // Allow nested objects { ... }
        if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
            // TODO: Could validate the object contents recursively
            return true;
        }
        
        // Allow array literals [ ... ]
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            // TODO: Could validate the array contents recursively
            return true;
        }
        
        // Allow number literals
        if (trimmed.len > 0) {
            var all_numeric = true;
            var has_one_dot = false;
            for (trimmed, 0..) |c, i| {
                if (c == '.' and !has_one_dot) {
                    has_one_dot = true;
                } else if (c == '-' and i == 0) {
                    // Allow negative sign at start
                } else if (!std.ascii.isDigit(c)) {
                    all_numeric = false;
                    break;
                }
            }
            if (all_numeric) return true;
        }
        
        // Allow field access (including chained access like r.user.id)
        if (std.mem.indexOf(u8, trimmed, ".")) |_| {
            // But make sure it doesn't start with { or [ (those are handled above)
            if (trimmed[0] != '{' and trimmed[0] != '[') {
                // Split by dots and check each part is a valid identifier
                var parts_iter = std.mem.tokenizeScalar(u8, trimmed, '.');
                var valid_chain = true;
                var part_count: u32 = 0;
                
                while (parts_iter.next()) |part| {
                    if (!isValidIdentifier(part)) {
                        valid_chain = false;
                        break;
                    }
                    part_count += 1;
                }
                
                // Must have at least 2 parts (binding.field)
                if (valid_chain and part_count >= 2) {
                    return true;
                }
            }
        }
        
        // Allow bare identifiers (for passing through values)
        if (isValidIdentifier(trimmed)) {
            return true;
        }
        
        // Reject anything with operators or function calls
        const forbidden = [_][]const u8{ 
            "+", "*", "/", "%", // Arithmetic (but minus is allowed at start for negatives)
            "(", ")", // Function calls (unless part of nested structure)
            "&&", "||", "!", // Logic
            "<", ">", "==", "!=", // Comparison
            "?", ":", // Ternary
        };
        
        for (forbidden) |op| {
            // Skip minus at start (negative numbers)
            if (std.mem.eql(u8, op, "-") and trimmed.len > 0 and trimmed[0] == '-') {
                if (std.mem.indexOf(u8, trimmed[1..], op) != null) {
                    return false;
                }
            } else if (std.mem.indexOf(u8, trimmed, op) != null) {
                return false;
            }
        }
        
        return false;
    }
    
    
    fn parseLabelAnchor(self: *Parser) !ast.Item {
        const line = self.lines[self.current];
        const trimmed = lexer.trim(line);
        const after_hash = lexer.trim(trimmed[2..]); // Skip ~#
        
        // Check if this is a standalone label (~#name) or pre-invocation (~#name event)
        const space_idx = std.mem.indexOf(u8, after_hash, " ");
        
        if (space_idx) |idx| {
            // Pre-invocation label: ~#name event(args)
            const label_name = after_hash[0..idx];
            const event_part = lexer.trim(after_hash[idx + 1..]);
            
            // Parse the event invocation
            const invocation = try self.parseEventInvocation(event_part);
            
            // Move to next line and parse continuations
            self.current += 1;
            const continuations = try self.parseContinuations(lexer.getIndent(line));
            
            return .{ .flow = ast.Flow{
                .invocation = invocation,
                .continuations = continuations,
                .pre_label = try self.allocator.dupe(u8, label_name),
                .post_label = null,
                .super_shape = null,
                .location = self.getCurrentLocation(),
                .module = try self.allocator.dupe(u8, self.module_name),
            }};
        } else {
            // Standalone label: ~#name
            self.current += 1;
            const continuations = try self.parseContinuations(lexer.getIndent(line));
            
            return .{ .label_decl = ast.LabelDecl{
                .name = try self.allocator.dupe(u8, after_hash),
                .continuations = continuations,
            }};
        }
    }
    
    fn parseLabelDecl(self: *Parser) !ast.LabelDecl {
        const line = self.lines[self.current];
        self.current += 1;
        
        // Parse: ~@name
        const after_at = lexer.afterPrefix(line, "~@") orelse {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "malformed label declaration",
                .{},
            );
            return error.ParseError;
        };
        
        const name = lexer.trim(after_at);
        const continuations = try self.parseContinuations(lexer.getIndent(line));
        
        return ast.LabelDecl{
            .name = try self.allocator.dupe(u8, name),
            .continuations = continuations,
        };
    }
    
    
    fn parseImportDecl(self: *Parser) !ast.ImportDecl {
        const line = self.lines[self.current];
        self.current += 1;
        
        // Parse: ~import "path"
        const after_tilde = lexer.trim(line[1..]);
        
        // Skip the "import " part
        const after_import = if (lexer.startsWith(after_tilde, "import "))
            lexer.trim(after_tilde[7..])
        else {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "invalid import syntax",
                .{},
            );
            return error.ParseError;
        };
        
        // Extract the path from quotes
        var path: []const u8 = undefined;
        const path_str = after_import;
        if (lexer.startsWith(path_str, "\"") and std.mem.endsWith(u8, path_str, "\"")) {
            // Quoted path
            path = path_str[1..path_str.len - 1];
        } else if (lexer.startsWith(path_str, "'") and std.mem.endsWith(u8, path_str, "'")) {
            // Single quoted path
            path = path_str[1..path_str.len - 1];
        } else {
            // Unquoted path (for simplicity)
            path = path_str;
        }

        // Validate import path
        // 1. Forbid ../ for security and simplicity (only allowed in koru.json)
        if (std.mem.indexOf(u8, path, "../") != null) {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "import paths cannot contain '../' - use path aliases in koru.json instead",
                .{},
            );
            return error.ParseError;
        }

        // 2. Require $alias prefix for all imports (for truly canonical module names)
        if (path.len == 0 or path[0] != '$') {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "import paths must start with $ alias (e.g., '$std/io', '$src/helper') - define aliases in koru.json",
                .{},
            );
            return error.ParseError;
        }

        // 3. Validate $alias syntax (if present)
        if (path.len > 0 and path[0] == '$') {
            // Find the end of the alias
            const slash_pos = std.mem.indexOf(u8, path, "/");
            const alias_end = slash_pos orelse path.len;

            // Alias must have at least one character after $
            if (alias_end <= 1) {
                try self.reporter.addError(
                    .PARSE003,
                    self.current,
                    1,
                    "invalid import alias: expected '$name' or '$name/path'",
                    .{},
                );
                return error.ParseError;
            }

            // 4. Enforce maximum import depth: $alias/a/b (2 segments max)
            if (slash_pos) |first_slash| {
                const path_after_alias = path[first_slash + 1..];
                var segment_count: usize = 1; // Count the first segment
                var i: usize = 0;
                while (i < path_after_alias.len) : (i += 1) {
                    if (path_after_alias[i] == '/') {
                        segment_count += 1;
                    }
                }

                if (segment_count > 2) {
                    const alias_name = path[1..alias_end];
                    try self.reporter.addError(
                        .PARSE003,
                        self.current,
                        1,
                        "import path too deep: '{s}' has {d} segments after alias (max: 2)\n" ++
                        "  To fix: add a new alias to koru.json, e.g.:\n" ++
                        "    \"paths\": {{ \"mylib\": \"./path/to/lib\" }}\n" ++
                        "  Then use: ~import \"$mylib/...\" (Suggested: extract '{s}' as its own alias)",
                        .{path, segment_count, alias_name},
                    );
                    return error.ParseError;
                }
            }
        }

        // Derive namespace from import path
        // For $alias/path imports: strip $ and convert / to . (e.g., "$std/build" -> "std.build")
        // For regular imports: just use the filename (e.g., "utils/math.kz" -> "math")
        const final_name = if (std.mem.startsWith(u8, path, "$")) blk: {
            // Strip $ and convert / to . for aliased imports
            const without_dollar = path[1..];
            var namespace = try std.ArrayList(u8).initCapacity(self.allocator, without_dollar.len);
            defer namespace.deinit(self.allocator);

            for (without_dollar) |c| {
                if (c == '/') {
                    try namespace.append(self.allocator, '.');
                } else {
                    try namespace.append(self.allocator, c);
                }
            }

            // Strip .kz extension if present
            var result = try namespace.toOwnedSlice(self.allocator);
            if (std.mem.endsWith(u8, result, ".kz")) {
                const trimmed = result[0..result.len - 3];
                const final = try self.allocator.dupe(u8, trimmed);
                self.allocator.free(result);
                break :blk final;
            }
            break :blk result;
        } else blk: {
            // Just use filename for non-aliased imports
            const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse 0;
            const filename_start = if (last_slash > 0) last_slash + 1 else 0;
            const filename = path[filename_start..];
            const base_name = if (std.mem.endsWith(u8, filename, ".kz"))
                filename[0..filename.len - 3]
            else
                filename;
            break :blk try self.allocator.dupe(u8, base_name);
        };

        // Parse the imported file to populate registry with public events
        // We use final_name which is the full dotted namespace (e.g., "std.compiler")
        try self.parseAndRegisterImport(path, final_name);

        return ast.ImportDecl{
            .path = try self.allocator.dupe(u8, path),
            .local_name = try self.allocator.dupe(u8, final_name),
            .location = self.getCurrentLocation(),
            .module = try self.allocator.dupe(u8, self.module_name),
        };
    }

    fn parseAndRegisterImport(self: *Parser, import_path: []const u8, namespace: []const u8) anyerror!void {
        // If no resolver is available (help text parsing), skip import resolution
        const resolver = self.resolver orelse {
            if (DEBUG) std.debug.print("Parser: No resolver available, skipping import resolution for: {s}\n", .{import_path});
            return;
        };

        // NOTE: Auto-import of parent modules (e.g., importing $std/io.kz when importing $std/io/file)
        // is handled in main.zig's queueParentImports() during import resolution phase.

        // Use ModuleResolver to resolve the import path
        var result = try resolver.resolveBoth(import_path, self.reporter.file_name);
        defer result.deinit(resolver.allocator);  // CRITICAL: Use resolver's allocator, not parser's!

        // Process directory imports (if directory was found)
        if (result.dir_path) |dir_path| {
            // Enumerate all .kz files in the directory
            const files = try resolver.enumerateDirectory(dir_path);
            defer {
                // CRITICAL: Use resolver's allocator (GPA), not parser's allocator (arena)!
                for (files) |file| resolver.allocator.free(file);
                resolver.allocator.free(files);
            }

            for (files) |file_path| {
                // Extract filename without .kz extension for namespace
                const basename = std.fs.path.basename(file_path);
                const file_name = if (std.mem.endsWith(u8, basename, ".kz"))
                    basename[0..basename.len - 3]
                else
                    basename;

                // Combined namespace: namespace.filename
                var combined_namespace_buf: [256]u8 = undefined;
                const combined_namespace = try std.fmt.bufPrint(&combined_namespace_buf, "{s}.{s}", .{namespace, file_name});

                // Parse and register this file
                try self.parseAndRegisterSingleFile(file_path, combined_namespace);
            }
        }

        // Process file import (if file was found)
        if (result.file_path) |file_path| {
            try self.parseAndRegisterSingleFile(file_path, namespace);
        }
    }

    fn parseAndRegisterSingleFile(self: *Parser, file_path: []const u8, namespace: []const u8) anyerror!void {
        const resolver = self.resolver orelse return;

        // Check for circular import - if this file is already being parsed, skip it
        // The events will be registered when the original parse completes
        if (resolver.isBeingParsed(file_path)) {
            if (DEBUG) std.debug.print("CIRCULAR IMPORT: Skipping '{s}' (already being parsed)\n", .{file_path});
            return;
        }

        // Mark this file as being parsed
        try resolver.markParsing(file_path);
        defer resolver.unmarkParsing(file_path);

        // Read the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "failed to open import file '{s}': {s}",
                .{file_path, @errorName(err)}
            );
            return error.ParseError;
        };
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            try self.reporter.addError(
                .PARSE003,
                self.current,
                1,
                "failed to read import file '{s}': {s}",
                .{file_path, @errorName(err)}
            );
            return error.ParseError;
        };
        defer self.allocator.free(source);

        // Parse the imported file
        var import_parser = try Parser.init(self.allocator, source, file_path, &[_][]const u8{}, self.resolver);
        defer import_parser.deinit();

        // Parse import - errors will propagate naturally
        // NOTE: We intentionally don't call import_result.deinit() because we're storing
        // pointers to its EventTypes in our registry. Those need to stay alive.
        var import_result = try import_parser.parse();

        // Register all public events from the imported file with namespace prefix
        var event_iter = import_result.registry.events.iterator();
        while (event_iter.next()) |entry| {
            const event_path = entry.key_ptr.*;
            const event_type = entry.value_ptr.*;

            // Only register public events
            if (event_type.is_public) {
                // Register with FULL namespace (e.g., "std.compiler:requires")
                const namespaced_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}:{s}",
                    .{namespace, event_path}
                );
                try self.registry.events.put(namespaced_path, event_type);
            }
        }
    }
};

// Parser tests - Verifying that parser produces clean AST without validation

test "parser produces AST from simple event" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event compute { x: i32 }
        \\| done { result: i32 }
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    // Verify we got an AST
    try std.testing.expect(parse_result.source_file.items.len == 1);
    
    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .event_decl);
    
    const event = item.event_decl;
    try std.testing.expectEqualStrings(event.path.segments[0], "compute");
    try std.testing.expect(event.input.fields.len == 1);
    try std.testing.expectEqualStrings(event.input.fields[0].name, "x");
    try std.testing.expect(event.branches.len == 1);
    try std.testing.expectEqualStrings(event.branches[0].name, "done");
}

test "parser handles flow with continuation" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~hello()
        \\| greeting g -> ~print(g.message)
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    try std.testing.expect(parse_result.source_file.items.len == 1);
    
    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .flow);
    
    const flow = item.flow;
    try std.testing.expectEqualStrings(flow.invocation.path.segments[0], "hello");
    try std.testing.expect(flow.continuations.len == 1);
    
    const cont = flow.continuations[0];
    try std.testing.expectEqualStrings(cont.branch, "greeting");
    try std.testing.expect(cont.binding != null);
    try std.testing.expectEqualStrings(cont.binding.?, "g");
}

test "parser handles proc declaration" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~proc compute {
        \\    return .done{ .result = x + y };
        \\}
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    try std.testing.expect(parse_result.source_file.items.len == 1);
    
    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .proc_decl);
    
    const proc = item.proc_decl;
    try std.testing.expectEqualStrings(proc.path.segments[0], "compute");
    // ProcDecl only stores the body as opaque Zig code
    try std.testing.expect(proc.body.len > 0);
}

test "parser handles complex nested proc body extraction" {
    const allocator = std.testing.allocator;
    
    // Test with complex nested braces, including strings with braces
    const source =
        \\~[raw]proc complex.test {
        \\    const str1 = "test { brace }";
        \\    if (condition) {
        \\        for (items) |item| {
        \\            switch (item) {
        \\                .foo => {
        \\                    const nested = "another { nested } brace";
        \\                    if (true) {
        \\                        doSomething();
        \\                    }
        \\                },
        \\                else => {},
        \\            }
        \\        }
        \\    }
        \\    return result;
        \\}
        \\~something.after.proc()
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    // Should have 2 items: the proc and the flow after
    try std.testing.expect(parse_result.source_file.items.len == 2);
    
    const proc_item = parse_result.source_file.items[0];
    try std.testing.expect(proc_item == .proc_decl);
    
    const proc = proc_item.proc_decl;
    try std.testing.expectEqualStrings(proc.path.segments[0], "complex");
    try std.testing.expectEqualStrings(proc.path.segments[1], "test");
    
    // The body should contain all the nested code
    try std.testing.expect(std.mem.indexOf(u8, proc.body, "const str1") != null);
    try std.testing.expect(std.mem.indexOf(u8, proc.body, "return result") != null);
    
    // Make sure the flow after the proc was parsed
    const flow_item = parse_result.source_file.items[1];
    try std.testing.expect(flow_item == .flow);
    try std.testing.expectEqualStrings(flow_item.flow.invocation.path.segments[0], "something");
}

test "parser handles import statement" {
    const allocator = std.testing.allocator;
    
    const source = \\~import math = "std/math.kz"
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    try std.testing.expect(parse_result.source_file.items.len == 1);
    
    const item = parse_result.source_file.items[0];
    try std.testing.expect(item == .import_decl);
    
    const import = item.import_decl;
    try std.testing.expectEqualStrings(import.path, "std/math.kz");
    try std.testing.expectEqualStrings(import.local_name.?, "math");
}

test "parser handles empty file" {
    const allocator = std.testing.allocator;
    
    const source = "";
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    try std.testing.expect(parse_result.source_file.items.len == 0);
}

test "parser handles Source in event field" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event macro { code: Source }
        \\| done { result: Source }
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    const event = parse_result.source_file.items[0].event_decl;
    try std.testing.expect(event.input.fields[0].is_source);
    try std.testing.expectEqualStrings(event.input.fields[0].name, "code");
}

test "parser validates branch names" {
    const allocator = std.testing.allocator;
    
    // Valid branch name
    {
        const source =
            \\~event test {}
            \\| valid_branch { data: i32 }
            \\| another_one { msg: []const u8 }
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var parse_result = try parser.parse();
        defer parse_result.deinit();
        
        try std.testing.expect(parse_result.source_file.items.len == 1);
        const event = parse_result.source_file.items[0].event_decl;
        try std.testing.expect(event.branches.len == 2);
        try std.testing.expectEqualStrings(event.branches[0].name, "valid_branch");
        try std.testing.expectEqualStrings(event.branches[1].name, "another_one");
    }
    
    // Invalid branch name with spaces
    {
        const source =
            \\~event test {}
            \\| this is invalid { data: i32 }
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        const result = parser.parse();
        
        // Should fail due to invalid branch name
        try std.testing.expectError(error.ParseError, result);
        try std.testing.expect(parser.reporter.hasErrors());
    }
    
    // Invalid branch name starting with number
    {
        const source =
            \\~event test {}
            \\| 123invalid { data: i32 }
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        const result = parser.parse();
        
        // Should fail due to invalid branch name
        try std.testing.expectError(error.ParseError, result);
        try std.testing.expect(parser.reporter.hasErrors());
    }
}

test "parser validates branch constructors" {
    const allocator = std.testing.allocator;
    
    // Valid branch constructor
    {
        const source =
            \\~event test {}
            \\| ok { msg: []const u8 }
            \\
            \\~test() 
            \\| ok |> ok { msg: "success" }
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var parse_result = try parser.parse();
        defer parse_result.deinit();
        
        try std.testing.expect(parse_result.source_file.items.len == 2);
    }
    
    // Invalid branch constructor with spaces in name
    {
        const source =
            \\~event test {}
            \\| ok { msg: []const u8 }
            \\
            \\~test() 
            \\| ok |> invalid name { msg: "fail" }
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        const result = parser.parse();
        
        // Should fail due to invalid branch name in constructor
        try std.testing.expectError(error.ParseError, result);
    }
}

test "parser handles shorthand notation in branch constructors" {
    const allocator = std.testing.allocator;
    
    const source =
        \\~event test {}
        \\| ok { data: i32 }
        \\
        \\~test = ok { r.user.id }
    ;
    
    var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
    defer parser.deinit();
    
    var parse_result = try parser.parse();
    defer parse_result.deinit();
    
    try std.testing.expect(parse_result.source_file.items.len == 2);
    const subflow = parse_result.source_file.items[1].subflow_impl;
    const bc = subflow.body.immediate;
    try std.testing.expectEqualStrings(bc.branch_name, "ok");
    try std.testing.expect(bc.fields.len == 1);
    // In shorthand, r.user.id becomes field name "id" with value "r.user.id"
    try std.testing.expectEqualStrings(bc.fields[0].name, "id");
    try std.testing.expectEqualStrings(bc.fields[0].type, "r.user.id"); // temporarily stored as type
}

test "parser handles event taps" {
    const allocator = std.testing.allocator;
    
    // Test basic output tap
    {
        const source =
            \\~file.read -> * | error e |> log.error(e)
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var result = try parser.parse();
        defer result.deinit();
        
        try std.testing.expectEqual(@as(usize, 1), result.source_file.items.len);
        const tap = result.source_file.items[0].event_tap;
        
        // Check source
        try std.testing.expect(tap.source != null);
        try std.testing.expectEqual(@as(usize, 2), tap.source.?.segments.len);
        try std.testing.expectEqualStrings("file", tap.source.?.segments[0]);
        try std.testing.expectEqualStrings("read", tap.source.?.segments[1]);
        
        // Check destination is wildcard
        try std.testing.expect(tap.destination == null);
        
        // Check it's an output tap
        try std.testing.expect(!tap.is_input_tap);
        
        // Check continuation
        try std.testing.expectEqual(@as(usize, 1), tap.continuations.len);
        try std.testing.expectEqualStrings("error", tap.continuations[0].branch);
    }
    
    // Test wildcard source
    {
        const source =
            \\~* -> db.query | sql s |> log.sql(s)
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var result = try parser.parse();
        defer result.deinit();
        
        const tap = result.source_file.items[0].event_tap;
        
        // Check source is wildcard
        try std.testing.expect(tap.source == null);
        
        // Check destination
        try std.testing.expect(tap.destination != null);
        try std.testing.expectEqual(@as(usize, 2), tap.destination.?.segments.len);
        try std.testing.expectEqualStrings("db", tap.destination.?.segments[0]);
        try std.testing.expectEqualStrings("query", tap.destination.?.segments[1]);
    }
    
    // Test concrete to concrete tap
    {
        const source =
            \\~auth.check -> grant.access | user u |> audit.log(u)
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var result = try parser.parse();
        defer result.deinit();
        
        const tap = result.source_file.items[0].event_tap;
        
        // Check both source and destination are concrete
        try std.testing.expect(tap.source != null);
        try std.testing.expect(tap.destination != null);
        try std.testing.expectEqualStrings("auth", tap.source.?.segments[0]);
        try std.testing.expectEqualStrings("check", tap.source.?.segments[1]);
        try std.testing.expectEqualStrings("grant", tap.destination.?.segments[0]);
        try std.testing.expectEqualStrings("access", tap.destination.?.segments[1]);
    }
    
    // Test universal tap
    {
        const source =
            \\~* -> * |> transition t |> profiler.record(t)
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var result = try parser.parse();
        defer result.deinit();
        
        const tap = result.source_file.items[0].event_tap;
        
        // Both should be wildcards
        try std.testing.expect(tap.source == null);
        try std.testing.expect(tap.destination == null);
    }
}

test "parser handles input taps" {
    const allocator = std.testing.allocator;
    
    // Test basic input tap
    {
        const source =
            \\~* -> auth.validate |> input i |> log.auth(i)
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var result = try parser.parse();
        defer result.deinit();
        
        try std.testing.expectEqual(@as(usize, 1), result.source_file.items.len);
        const tap = result.source_file.items[0].event_tap;
        
        // Check it's an input tap
        try std.testing.expect(tap.is_input_tap);
        
        // Check source is wildcard
        try std.testing.expect(tap.source == null);
        
        // Check destination
        try std.testing.expect(tap.destination != null);
        try std.testing.expectEqualStrings("auth", tap.destination.?.segments[0]);
        try std.testing.expectEqualStrings("validate", tap.destination.?.segments[1]);
        
        // Check continuation
        try std.testing.expectEqual(@as(usize, 1), tap.continuations.len);
        try std.testing.expectEqualStrings("input", tap.continuations[0].branch);
        try std.testing.expectEqualStrings("i", tap.continuations[0].binding.?);
    }
    
    // Test input tap with specific source
    {
        const source =
            \\~user.action -> db.save |> input data |> validate(data)
        ;
        
        var parser = try Parser.init(allocator, source, "test.kz", &[_][]const u8{});
        defer parser.deinit();
        
        var result = try parser.parse();
        defer result.deinit();
        
        const tap = result.source_file.items[0].event_tap;
        
        // Check it's an input tap
        try std.testing.expect(tap.is_input_tap);
        
        // Check source
        try std.testing.expect(tap.source != null);
        try std.testing.expectEqualStrings("user", tap.source.?.segments[0]);
        try std.testing.expectEqualStrings("action", tap.source.?.segments[1]);
        
        // Check binding
        try std.testing.expectEqualStrings("input", tap.continuations[0].branch);
        try std.testing.expectEqualStrings("data", tap.continuations[0].binding.?);
    }
}