//! CCP: Compiler Communication Protocol
//!
//! Implements a JSONL-based bidirectional protocol for Studio ↔ Compiler communication.
//! When invoked with `koruc --ccp`, the compiler enters daemon mode and accepts
//! commands via stdin, streaming responses via stdout.

const std = @import("std");
const Parser = @import("parser").Parser;
const ast_serializer = @import("ast_serializer");
const ast = @import("ast");

/// CCP command types
const CommandType = enum {
    parse,
    compile,
    ast_json,
    set_flag,
    exit,
    unknown,
};

/// Parse a command type from string
fn parseCommandType(cmd: []const u8) CommandType {
    if (std.mem.eql(u8, cmd, "parse")) return .parse;
    if (std.mem.eql(u8, cmd, "compile")) return .compile;
    if (std.mem.eql(u8, cmd, "ast_json")) return .ast_json;
    if (std.mem.eql(u8, cmd, "set_flag")) return .set_flag;
    if (std.mem.eql(u8, cmd, "exit")) return .exit;
    return .unknown;
}

/// CCP daemon state
pub const CcpDaemon = struct {
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stdin: std.fs.File,
    
    // Response buffer
    response_buf: [8192]u8 = undefined,
    
    // State
    project_root: ?[]const u8 = null,
    ccp_runtime_enabled: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) CcpDaemon {
        return .{
            .allocator = allocator,
            .stdout = std.fs.File.stdout(),
            .stdin = std.fs.File.stdin(),
        };
    }
    
    fn writeJson(self: *CcpDaemon, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.response_buf, fmt ++ "\n", args) catch return;
        self.stdout.writeAll(msg) catch {};
    }
    
    fn writeRaw(self: *CcpDaemon, data: []const u8) void {
        self.stdout.writeAll(data) catch {};
    }
    
    fn writeError(self: *CcpDaemon, msg: []const u8) void {
        const response = std.fmt.bufPrint(&self.response_buf, "{{\"type\":\"error\",\"msg\":\"{s}\"}}\n", .{msg}) catch return;
        self.stdout.writeAll(response) catch {};
    }
    
    /// Run the CCP daemon main loop
    pub fn run(self: *CcpDaemon) !void {
        // Signal ready
        self.writeJson("{{\"type\":\"ready\",\"version\":\"0.1.0\"}}", .{});
        
        var line_buf: [64 * 1024]u8 = undefined;
        var pos: usize = 0;
        
        while (true) {
            // Read from stdin
            const bytes_read = self.stdin.read(line_buf[pos..]) catch |err| {
                switch (err) {
                    error.BrokenPipe => return,
                    else => {
                        self.writeError("Failed to read from stdin");
                        continue;
                    },
                }
            };
            
            if (bytes_read == 0) {
                // EOF - stdin closed, exit gracefully
                return;
            }
            
            pos += bytes_read;
            
            // Process complete lines
            while (std.mem.indexOf(u8, line_buf[0..pos], "\n")) |newline_pos| {
                const line = line_buf[0..newline_pos];
                
                // Skip empty lines
                if (line.len > 0) {
                    self.handleCommand(line) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_msg = std.fmt.bufPrint(&err_buf, "Command failed: {}", .{err}) catch "Command failed";
                        self.writeError(err_msg);
                    };
                }
                
                // Move remaining data to start of buffer
                const remaining = pos - newline_pos - 1;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, line_buf[0..remaining], line_buf[newline_pos + 1 .. pos]);
                }
                pos = remaining;
            }
        }
    }
    
    fn handleCommand(self: *CcpDaemon, line: []const u8) !void {
        // Simple JSON parsing - find "cmd" field
        const cmd_type = self.extractCommandType(line);
        
        switch (cmd_type) {
            .parse => self.handleParse(line),
            .compile => self.handleCompile(line),
            .ast_json => self.handleAstJson(line),
            .set_flag => self.handleSetFlag(line),
            .exit => {
                self.writeJson("{{\"type\":\"exit\",\"code\":0}}", .{});
                std.process.exit(0);
            },
            .unknown => {
                self.writeError("Unknown command");
            },
        }
    }
    
    fn extractCommandType(self: *CcpDaemon, line: []const u8) CommandType {
        _ = self;
        // Simple extraction: find "cmd":"<value>"
        const cmd_prefix = "\"cmd\":\"";
        if (std.mem.indexOf(u8, line, cmd_prefix)) |start| {
            const value_start = start + cmd_prefix.len;
            if (std.mem.indexOfScalarPos(u8, line, value_start, '"')) |end| {
                return parseCommandType(line[value_start..end]);
            }
        }
        return .unknown;
    }
    
    fn extractStringField(self: *CcpDaemon, line: []const u8, field: []const u8) ?[]const u8 {
        _ = self;
        // Find "field":"value"
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{field}) catch return null;
        
        if (std.mem.indexOf(u8, line, search)) |start| {
            const value_start = start + search.len;
            if (std.mem.indexOfScalarPos(u8, line, value_start, '"')) |end| {
                return line[value_start..end];
            }
        }
        return null;
    }
    
    fn handleParse(self: *CcpDaemon, line: []const u8) void {
        const file_path = self.extractStringField(line, "file") orelse {
            self.writeError("Missing 'file' field");
            return;
        };
        
        // Read the file
        const source = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to read file: {}", .{err}) catch "Failed to read file";
            self.writeError(err_msg);
            return;
        };
        defer self.allocator.free(source);
        
        // Parse the file
        var parser = Parser.init(self.allocator, source, file_path, &[_][]const u8{}, null) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to init parser: {}", .{err}) catch "Failed to init parser";
            self.writeError(err_msg);
            return;
        };
        defer parser.deinit();
        
        const parse_result = parser.parse() catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Parse error: {}", .{err}) catch "Parse error";
            self.writeError(err_msg);
            return;
        };
        
        // Report success with basic stats
        const item_count = parse_result.source_file.items.len;
        self.writeJson("{{\"type\":\"parsed\",\"file\":\"{s}\",\"items\":{d}}}", .{ file_path, item_count });
    }
    
    fn handleCompile(self: *CcpDaemon, line: []const u8) void {
        const entry = self.extractStringField(line, "entry") orelse {
            self.writeError("Missing 'entry' field");
            return;
        };
        
        // TODO: Actually compile using the full pipeline
        self.writeJson("{{\"type\":\"pass_start\",\"pass\":\"frontend\"}}", .{});
        self.writeJson("{{\"type\":\"pass_done\",\"pass\":\"frontend\",\"duration_ms\":0}}", .{});
        self.writeJson("{{\"type\":\"compiled\",\"entry\":\"{s}\",\"status\":\"stub\"}}", .{entry});
    }
    
    fn handleAstJson(self: *CcpDaemon, line: []const u8) void {
        const file_path = self.extractStringField(line, "file") orelse {
            self.writeError("Missing 'file' field");
            return;
        };
        
        // Read the file
        const source = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to read file: {}", .{err}) catch "Failed to read file";
            self.writeError(err_msg);
            return;
        };
        defer self.allocator.free(source);
        
        // Parse the file
        var parser = Parser.init(self.allocator, source, file_path, &[_][]const u8{}, null) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to init parser: {}", .{err}) catch "Failed to init parser";
            self.writeError(err_msg);
            return;
        };
        defer parser.deinit();
        
        const parse_result = parser.parse() catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Parse error: {}", .{err}) catch "Parse error";
            self.writeError(err_msg);
            return;
        };
        
        // Serialize AST to JSON
        var serializer = ast_serializer.AstSerializer.init(self.allocator) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to init serializer: {}", .{err}) catch "Failed to init serializer";
            self.writeError(err_msg);
            return;
        };
        defer serializer.deinit();
        
        var source_file = parse_result.source_file;
        const json_output = serializer.serializeToJson(&source_file) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to serialize AST: {}", .{err}) catch "Failed to serialize AST";
            self.writeError(err_msg);
            return;
        };
        
        // Write response with embedded AST JSON
        // Format: {"type":"ast_json","file":"...","ast":...}
        self.writeRaw("{\"type\":\"ast_json\",\"file\":\"");
        self.writeRaw(file_path);
        self.writeRaw("\",\"ast\":");
        self.writeRaw(json_output);
        self.writeRaw("}\n");
    }
    
    fn handleSetFlag(self: *CcpDaemon, line: []const u8) void {
        const flag = self.extractStringField(line, "flag") orelse {
            self.writeError("Missing 'flag' field");
            return;
        };
        
        // Handle known flags
        if (std.mem.eql(u8, flag, "emit_ccp")) {
            self.ccp_runtime_enabled = true;
            self.writeJson("{{\"type\":\"flag_set\",\"flag\":\"emit_ccp\",\"value\":true}}", .{});
        } else {
            self.writeJson("{{\"type\":\"flag_set\",\"flag\":\"{s}\",\"status\":\"unknown\"}}", .{flag});
        }
    }
};

/// Entry point for CCP daemon mode
pub fn ccpMain(allocator: std.mem.Allocator) !void {
    var daemon = CcpDaemon.init(allocator);
    try daemon.run();
}
