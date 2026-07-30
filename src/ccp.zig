//! CCP: Compiler Communication Protocol
//!
//! JSONL over stdin/stdout for editor/Studio ↔ compiler communication.
//! Launch: `koruc --ccp` (no input file).
//!
//! Trace: set `KORU_CCP_TRACE=1` to log commands/responses on stderr.

const std = @import("std");
const ast_serializer = @import("ast_serializer");
const frontend_introspect = @import("frontend_introspect.zig");
const frontend_hover = @import("frontend_hover.zig");
const frontend_diagnostics = @import("frontend_diagnostics.zig");
const frontend_completion = @import("frontend_completion.zig");

pub const koruc_version = "0.1.7";

const CommandType = enum {
    parse,
    compile,
    ast_json,
    glance,
    open,
    change,
    close,
    hover,
    definition,
    diagnostics,
    completion,
    set_flag,
    exit,
    unknown,
};

const OpenBuffer = struct {
    text: []const u8,
    version: u64,
};

const ParsedCommand = struct {
    cmd: CommandType,
    id: ?i64 = null,
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
    version: ?u64 = null,
    entry: ?[]const u8 = null,
    flag: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    merge_companions: bool = true,
    app: bool = false,

    fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        if (self.file) |s| allocator.free(s);
        if (self.text) |s| allocator.free(s);
        if (self.entry) |s| allocator.free(s);
        if (self.flag) |s| allocator.free(s);
    }
};

fn parseCommandType(cmd: []const u8) CommandType {
    if (std.mem.eql(u8, cmd, "parse")) return .parse;
    if (std.mem.eql(u8, cmd, "compile")) return .compile;
    if (std.mem.eql(u8, cmd, "ast_json")) return .ast_json;
    if (std.mem.eql(u8, cmd, "glance")) return .glance;
    if (std.mem.eql(u8, cmd, "open")) return .open;
    if (std.mem.eql(u8, cmd, "change")) return .change;
    if (std.mem.eql(u8, cmd, "close")) return .close;
    if (std.mem.eql(u8, cmd, "hover")) return .hover;
    if (std.mem.eql(u8, cmd, "definition")) return .definition;
    if (std.mem.eql(u8, cmd, "diagnostics")) return .diagnostics;
    if (std.mem.eql(u8, cmd, "completion")) return .completion;
    if (std.mem.eql(u8, cmd, "set_flag")) return .set_flag;
    if (std.mem.eql(u8, cmd, "exit")) return .exit;
    return .unknown;
}

pub const CcpDaemon = struct {
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stdin: std.fs.File,
    response_buf: [8192]u8 = undefined,
    ccp_runtime_enabled: bool = false,
    trace_enabled: bool = undefined,
    buffers: std.StringHashMap(OpenBuffer),

    pub fn init(allocator: std.mem.Allocator) CcpDaemon {
        return .{
            .allocator = allocator,
            .stdout = std.fs.File.stdout(),
            .stdin = std.fs.File.stdin(),
            .trace_enabled = std.process.hasEnvVarConstant("KORU_CCP_TRACE"),
            .buffers = std.StringHashMap(OpenBuffer).init(allocator),
        };
    }

    pub fn deinit(self: *CcpDaemon) void {
        var it = self.buffers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
        }
        self.buffers.deinit();
    }

    fn trace(self: *CcpDaemon, comptime fmt: []const u8, args: anytype) void {
        if (!self.trace_enabled) return;
        std.debug.print("[ccp] " ++ fmt ++ "\n", args);
    }

    fn writeJson(self: *CcpDaemon, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.response_buf, fmt ++ "\n", args) catch return;
        self.stdout.writeAll(msg) catch {};
        self.trace(">> {s}", .{std.mem.trimRight(u8, msg, "\n")});
    }

    fn writeRaw(self: *CcpDaemon, data: []const u8) void {
        self.stdout.writeAll(data) catch {};
    }

    fn writeError(self: *CcpDaemon, msg: []const u8, id: ?i64) void {
        if (id) |req_id| {
            self.writeJson("{{\"type\":\"error\",\"id\":{d},\"msg\":\"{s}\"}}", .{ req_id, msg });
        } else {
            self.writeJson("{{\"type\":\"error\",\"msg\":\"{s}\"}}", .{msg});
        }
    }

    pub fn run(self: *CcpDaemon) !void {
        self.writeJson("{{\"type\":\"ready\",\"version\":\"{s}\"}}", .{koruc_version});

        var line_buf: [256 * 1024]u8 = undefined;
        var pos: usize = 0;

        while (true) {
            const bytes_read = self.stdin.read(line_buf[pos..]) catch |err| {
                switch (err) {
                    error.BrokenPipe => return,
                    else => {
                        self.writeError("Failed to read from stdin", null);
                        continue;
                    },
                }
            };

            if (bytes_read == 0) return;

            pos += bytes_read;

            while (std.mem.indexOf(u8, line_buf[0..pos], "\n")) |newline_pos| {
                const line = line_buf[0..newline_pos];
                if (line.len > 0) {
                    self.trace("<< {s}", .{line});
                    self.handleCommand(line) catch |err| {
                        var err_buf: [256]u8 = undefined;
                        const err_msg = std.fmt.bufPrint(&err_buf, "Command failed: {}", .{err}) catch "Command failed";
                        self.writeError(err_msg, null);
                    };
                }

                const remaining = pos - newline_pos - 1;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, line_buf[0..remaining], line_buf[newline_pos + 1 .. pos]);
                }
                pos = remaining;
            }
        }
    }

    fn parseCommand(self: *CcpDaemon, line: []const u8) !ParsedCommand {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidCommand;

        const obj = root.object;
        const cmd_str = obj.get("cmd") orelse return error.MissingCmd;
        if (cmd_str != .string) return error.InvalidCmd;

        var cmd: ParsedCommand = .{
            .cmd = parseCommandType(cmd_str.string),
        };

        if (obj.get("id")) |id_val| {
            cmd.id = switch (id_val) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => null,
            };
        }

        if (obj.get("file")) |v| {
            if (v == .string) cmd.file = try self.allocator.dupe(u8, v.string);
        }
        if (obj.get("text")) |v| {
            if (v == .string) cmd.text = try self.allocator.dupe(u8, v.string);
        }
        if (obj.get("version")) |v| {
            cmd.version = switch (v) {
                .integer => @intCast(v.integer),
                .float => @intFromFloat(v.float),
                else => null,
            };
        }
        if (obj.get("entry")) |v| {
            if (v == .string) cmd.entry = try self.allocator.dupe(u8, v.string);
        }
        if (obj.get("flag")) |v| {
            if (v == .string) cmd.flag = try self.allocator.dupe(u8, v.string);
        }
        if (obj.get("line")) |v| {
            cmd.line = switch (v) {
                .integer => @intCast(v.integer),
                .float => @intFromFloat(v.float),
                else => null,
            };
        }
        if (obj.get("column")) |v| {
            cmd.column = switch (v) {
                .integer => @intCast(v.integer),
                .float => @intFromFloat(v.float),
                else => null,
            };
        }
        if (obj.get("merge_companions")) |v| {
            if (v == .bool) cmd.merge_companions = v.bool;
        }
        if (obj.get("app")) |v| {
            if (v == .bool) cmd.app = v.bool;
        }

        return cmd;
    }

    fn handleCommand(self: *CcpDaemon, line: []const u8) !void {
        var parsed = self.parseCommand(line) catch {
            self.writeError("Invalid JSON command", null);
            return;
        };
        defer parsed.deinit(self.allocator);

        switch (parsed.cmd) {
            .parse => try self.handleParse(parsed),
            .compile => self.handleCompile(parsed),
            .ast_json => self.handleAstJson(parsed),
            .glance => try self.handleGlance(parsed),
            .open => try self.handleOpen(parsed),
            .change => try self.handleChange(parsed),
            .close => try self.handleClose(parsed),
            .hover => self.handleHover(parsed),
            .definition => self.handleDefinition(parsed),
            .diagnostics => self.handleDiagnostics(parsed),
            .completion => self.handleCompletion(parsed),
            .set_flag => self.handleSetFlag(parsed),
            .exit => {
                if (parsed.id) |req_id| {
                    self.writeJson("{{\"type\":\"exit\",\"id\":{d},\"code\":0}}", .{req_id});
                } else {
                    self.writeJson("{{\"type\":\"exit\",\"code\":0}}", .{});
                }
                std.process.exit(0);
            },
            .unknown => self.writeError("Unknown command", parsed.id),
        }
    }

    fn bufferText(self: *CcpDaemon, file_path: []const u8) ?[]const u8 {
        const entry = self.buffers.get(file_path) orelse return null;
        return entry.text;
    }

    fn introspect(
        self: *CcpDaemon,
        parse_arena: *std.heap.ArenaAllocator,
        file_path: []const u8,
        merge: bool,
    ) !frontend_introspect.Result {
        const opts = frontend_introspect.Options{
            .merge_companions = merge,
            .inject_compiler = true,
            .fail_fast = false,
        };

        if (self.bufferText(file_path)) |text| {
            return frontend_introspect.introspectSource(
                self.allocator,
                parse_arena.allocator(),
                text,
                file_path,
                opts,
            );
        }

        return frontend_introspect.introspectFile(
            self.allocator,
            parse_arena.allocator(),
            file_path,
            opts,
        );
    }

    fn freeIntrospectResult(self: *CcpDaemon, result: frontend_introspect.Result) void {
        var reg = result.registry;
        reg.deinit();
        for (result.imported_paths) |p| self.allocator.free(p);
        self.allocator.free(result.imported_paths);
        frontend_diagnostics.freeSlice(self.allocator, result.diagnostics);
    }

    fn handleParse(self: *CcpDaemon, cmd: ParsedCommand) !void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };

        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();

        const result = self.introspect(&parse_arena, file_path, cmd.merge_companions) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Introspect failed: {}", .{err}) catch "Introspect failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer self.freeIntrospectResult(result);

        if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"parsed\",\"id\":{d},\"file\":\"{s}\",\"items\":{d},\"imports\":{d}}}", .{
                req_id, file_path, result.program.items.len, result.imported_paths.len,
            });
        } else {
            self.writeJson("{{\"type\":\"parsed\",\"file\":\"{s}\",\"items\":{d},\"imports\":{d}}}", .{
                file_path, result.program.items.len, result.imported_paths.len,
            });
        }
    }

    fn handleAstJson(self: *CcpDaemon, cmd: ParsedCommand) void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };

        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();

        const result = self.introspect(&parse_arena, file_path, cmd.merge_companions) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Introspect failed: {}", .{err}) catch "Introspect failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer self.freeIntrospectResult(result);

        var serializer = ast_serializer.AstSerializer.init(self.allocator) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to init serializer: {}", .{err}) catch "Failed to init serializer";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer serializer.deinit();

        const json_output = serializer.serializeToJson(&result.program) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Failed to serialize AST: {}", .{err}) catch "Failed to serialize AST";
            self.writeError(err_msg, cmd.id);
            return;
        };

        self.writeRaw("{\"type\":\"ast_json\"");
        if (cmd.id) |req_id| {
            var id_buf: [32]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, ",\"id\":{d}", .{req_id}) catch "";
            self.writeRaw(id_str);
        }
        self.writeRaw(",\"file\":\"");
        self.writeRaw(file_path);
        self.writeRaw("\",\"imports\":");
        var imports_buf: [16]u8 = undefined;
        const imports_str = std.fmt.bufPrint(&imports_buf, "{d}", .{result.imported_paths.len}) catch "0";
        self.writeRaw(imports_str);
        self.writeRaw(",\"ast\":");
        self.writeRaw(json_output);
        self.writeRaw("}\n");
    }

    fn handleGlance(self: *CcpDaemon, cmd: ParsedCommand) !void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };

        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();

        const result = self.introspect(&parse_arena, file_path, true) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Introspect failed: {}", .{err}) catch "Introspect failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer self.freeIntrospectResult(result);

        var module_count: usize = 0;
        var event_count: usize = 0;
        for (result.program.items) |item| {
            switch (item) {
                .module_decl => |mod| {
                    if (cmd.app and (std.mem.startsWith(u8, mod.logical_name, "std") or
                        std.mem.startsWith(u8, mod.logical_name, "koru"))) continue;
                    module_count += 1;
                    for (mod.items) |mi| {
                        if (mi == .event_decl) event_count += 1;
                    }
                },
                .event_decl => event_count += 1,
                else => {},
            }
        }

        if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"glance\",\"id\":{d},\"file\":\"{s}\",\"modules\":{d},\"events\":{d}}}", .{
                req_id, file_path, module_count, event_count,
            });
        } else {
            self.writeJson("{{\"type\":\"glance\",\"file\":\"{s}\",\"modules\":{d},\"events\":{d}}}", .{
                file_path, module_count, event_count,
            });
        }
    }

    fn putBuffer(self: *CcpDaemon, file_path: []const u8, text: []const u8, version: u64) !void {
        const key = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(key);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);

        const gop = try self.buffers.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.text);
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = .{ .text = owned_text, .version = version };
    }

    fn handleOpen(self: *CcpDaemon, cmd: ParsedCommand) !void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };
        const text = cmd.text orelse {
            self.writeError("Missing 'text' field", cmd.id);
            return;
        };
        const version = cmd.version orelse 1;

        try self.putBuffer(file_path, text, version);

        if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"opened\",\"id\":{d},\"file\":\"{s}\",\"version\":{d}}}", .{ req_id, file_path, version });
        } else {
            self.writeJson("{{\"type\":\"opened\",\"file\":\"{s}\",\"version\":{d}}}", .{ file_path, version });
        }
    }

    fn handleChange(self: *CcpDaemon, cmd: ParsedCommand) !void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };
        const text = cmd.text orelse {
            self.writeError("Missing 'text' field", cmd.id);
            return;
        };
        const version = cmd.version orelse {
            self.writeError("Missing 'version' field", cmd.id);
            return;
        };

        try self.putBuffer(file_path, text, version);

        if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"changed\",\"id\":{d},\"file\":\"{s}\",\"version\":{d}}}", .{ req_id, file_path, version });
        } else {
            self.writeJson("{{\"type\":\"changed\",\"file\":\"{s}\",\"version\":{d}}}", .{ file_path, version });
        }
    }

    fn handleClose(self: *CcpDaemon, cmd: ParsedCommand) !void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };

        if (self.buffers.fetchRemove(file_path)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.text);
        }

        if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"closed\",\"id\":{d},\"file\":\"{s}\"}}", .{ req_id, file_path });
        } else {
            self.writeJson("{{\"type\":\"closed\",\"file\":\"{s}\"}}", .{file_path});
        }
    }

    fn readSource(self: *CcpDaemon, arena: *std.heap.ArenaAllocator, file_path: []const u8) ![]const u8 {
        if (self.bufferText(file_path)) |text| return text;
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        const size = try file.getEndPos();
        const buf = try arena.allocator().alloc(u8, size);
        const n = try file.readAll(buf);
        return buf[0..n];
    }

    fn lookupHover(self: *CcpDaemon, file_path: []const u8, line: u32, column: u32) !?frontend_hover.HoverResult {
        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();

        const source = try self.readSource(&parse_arena, file_path);
        const intro = try self.introspect(&parse_arena, file_path, true);
        defer self.freeIntrospectResult(intro);

        return frontend_hover.hoverAt(self.allocator, source, &intro.program, line, column);
    }

    fn writeHoverJson(
        self: *CcpDaemon,
        cmd: ParsedCommand,
        found: ?frontend_hover.HoverResult,
        comptime response_type: []const u8,
    ) void {
        const file_path = cmd.file orelse return;
        const line = cmd.line orelse return;
        const column = cmd.column orelse return;

        if (found) |result| {
            defer frontend_hover.deinitHoverResult(self.allocator, result);
            const contents_esc = frontend_hover.jsonEscape(self.allocator, result.contents) catch {
                self.writeError("Failed to encode hover", cmd.id);
                return;
            };
            defer self.allocator.free(contents_esc);
            const def_file_esc = frontend_hover.jsonEscape(self.allocator, result.definition_file) catch {
                self.writeError("Failed to encode hover", cmd.id);
                return;
            };
            defer self.allocator.free(def_file_esc);

            const msg = if (cmd.id) |req_id| blk: {
                break :blk std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"id\":{d},\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"contents\":\"{s}\",\"definition\":{{\"file\":\"{s}\",\"line\":{d},\"column\":{d}}}}}\n", .{
                    response_type, req_id, file_path, line, column, contents_esc, def_file_esc, result.definition_line, result.definition_column,
                }) catch {
                    self.writeError("Failed to format hover", cmd.id);
                    return;
                };
            } else blk: {
                break :blk std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"contents\":\"{s}\",\"definition\":{{\"file\":\"{s}\",\"line\":{d},\"column\":{d}}}}}\n", .{
                    response_type, file_path, line, column, contents_esc, def_file_esc, result.definition_line, result.definition_column,
                }) catch {
                    self.writeError("Failed to format hover", cmd.id);
                    return;
                };
            };
            defer self.allocator.free(msg);
            self.writeRaw(msg);
            self.trace(">> {s}", .{std.mem.trimRight(u8, msg, "\n")});
        } else {
            if (cmd.id) |req_id| {
                self.writeJson("{{\"type\":\"{s}\",\"id\":{d},\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"contents\":null}}", .{
                    response_type, req_id, file_path, line, column,
                });
            } else {
                self.writeJson("{{\"type\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"contents\":null}}", .{
                    response_type, file_path, line, column,
                });
            }
        }
    }

    fn handleHover(self: *CcpDaemon, cmd: ParsedCommand) void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };
        const line = cmd.line orelse {
            self.writeError("Missing 'line' field", cmd.id);
            return;
        };
        const column = cmd.column orelse {
            self.writeError("Missing 'column' field", cmd.id);
            return;
        };

        const found = self.lookupHover(file_path, line, column) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Hover failed: {}", .{err}) catch "Hover failed";
            self.writeError(err_msg, cmd.id);
            return;
        };

        self.writeHoverJson(cmd, found, "hover");
    }

    fn handleDefinition(self: *CcpDaemon, cmd: ParsedCommand) void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };
        const line = cmd.line orelse {
            self.writeError("Missing 'line' field", cmd.id);
            return;
        };
        const column = cmd.column orelse {
            self.writeError("Missing 'column' field", cmd.id);
            return;
        };

        const found = self.lookupHover(file_path, line, column) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Definition failed: {}", .{err}) catch "Definition failed";
            self.writeError(err_msg, cmd.id);
            return;
        };

        if (found) |result| {
            defer frontend_hover.deinitHoverResult(self.allocator, result);
            const def_file_esc = frontend_hover.jsonEscape(self.allocator, result.definition_file) catch {
                self.writeError("Failed to encode definition", cmd.id);
                return;
            };
            defer self.allocator.free(def_file_esc);

            if (cmd.id) |req_id| {
                self.writeJson("{{\"type\":\"definition\",\"id\":{d},\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"target\":{{\"file\":\"{s}\",\"line\":{d},\"column\":{d}}}}}", .{
                    req_id, file_path, line, column, def_file_esc, result.definition_line, result.definition_column,
                });
            } else {
                self.writeJson("{{\"type\":\"definition\",\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"target\":{{\"file\":\"{s}\",\"line\":{d},\"column\":{d}}}}}", .{
                    file_path, line, column, def_file_esc, result.definition_line, result.definition_column,
                });
            }
        } else if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"definition\",\"id\":{d},\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"target\":null}}", .{
                req_id, file_path, line, column,
            });
        } else {
            self.writeJson("{{\"type\":\"definition\",\"file\":\"{s}\",\"line\":{d},\"column\":{d},\"target\":null}}", .{
                file_path, line, column,
            });
        }
    }

    fn handleDiagnostics(self: *CcpDaemon, cmd: ParsedCommand) void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };

        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();

        const result = self.introspect(&parse_arena, file_path, true) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Diagnostics failed: {}", .{err}) catch "Diagnostics failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer self.freeIntrospectResult(result);

        const json = frontend_diagnostics.serializeJson(self.allocator, file_path, result.diagnostics, cmd.id) catch {
            self.writeError("Failed to serialize diagnostics", cmd.id);
            return;
        };
        defer self.allocator.free(json);

        self.writeRaw(json);
        self.writeRaw("\n");
        self.trace(">> diagnostics ({d} items)", .{result.diagnostics.len});
    }

    fn handleCompletion(self: *CcpDaemon, cmd: ParsedCommand) void {
        const file_path = cmd.file orelse {
            self.writeError("Missing 'file' field", cmd.id);
            return;
        };
        const line = cmd.line orelse {
            self.writeError("Missing 'line' field", cmd.id);
            return;
        };
        const column = cmd.column orelse {
            self.writeError("Missing 'column' field", cmd.id);
            return;
        };

        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();

        var ctx: frontend_introspect.Context = undefined;
        frontend_introspect.initContext(self.allocator, file_path, &.{}, &ctx) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Completion failed: {}", .{err}) catch "Completion failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer ctx.deinit();

        const source = self.readSource(&parse_arena, file_path) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Completion failed: {}", .{err}) catch "Completion failed";
            self.writeError(err_msg, cmd.id);
            return;
        };

        const intro = self.introspect(&parse_arena, file_path, true) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Completion failed: {}", .{err}) catch "Completion failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer self.freeIntrospectResult(intro);

        const completion = frontend_completion.completeAt(self.allocator, source, &intro.program, &ctx, line, column) catch |err| {
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Completion failed: {}", .{err}) catch "Completion failed";
            self.writeError(err_msg, cmd.id);
            return;
        };
        defer frontend_completion.deinitResult(self.allocator, completion);

        const json = frontend_completion.serializeJson(self.allocator, file_path, completion, cmd.id) catch {
            self.writeError("Failed to serialize completion", cmd.id);
            return;
        };
        defer self.allocator.free(json);

        self.writeRaw(json);
        self.writeRaw("\n");
        self.trace(">> completion ({d} items)", .{completion.items.len});
    }

    fn handleCompile(self: *CcpDaemon, cmd: ParsedCommand) void {
        const entry = cmd.entry orelse {
            self.writeError("Missing 'entry' field", cmd.id);
            return;
        };
        self.writeJson("{{\"type\":\"pass_start\",\"pass\":\"frontend\"}}", .{});
        self.writeJson("{{\"type\":\"pass_done\",\"pass\":\"frontend\",\"duration_ms\":0}}", .{});
        if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"compiled\",\"id\":{d},\"entry\":\"{s}\",\"status\":\"stub\"}}", .{ req_id, entry });
        } else {
            self.writeJson("{{\"type\":\"compiled\",\"entry\":\"{s}\",\"status\":\"stub\"}}", .{entry});
        }
    }

    fn handleSetFlag(self: *CcpDaemon, cmd: ParsedCommand) void {
        const flag = cmd.flag orelse {
            self.writeError("Missing 'flag' field", cmd.id);
            return;
        };
        if (std.mem.eql(u8, flag, "emit_ccp")) {
            self.ccp_runtime_enabled = true;
            if (cmd.id) |req_id| {
                self.writeJson("{{\"type\":\"flag_set\",\"id\":{d},\"flag\":\"emit_ccp\",\"value\":true}}", .{req_id});
            } else {
                self.writeJson("{{\"type\":\"flag_set\",\"flag\":\"emit_ccp\",\"value\":true}}", .{});
            }
        } else if (cmd.id) |req_id| {
            self.writeJson("{{\"type\":\"flag_set\",\"id\":{d},\"flag\":\"{s}\",\"status\":\"unknown\"}}", .{ req_id, flag });
        } else {
            self.writeJson("{{\"type\":\"flag_set\",\"flag\":\"{s}\",\"status\":\"unknown\"}}", .{flag});
        }
    }
};

pub fn ccpMain(allocator: std.mem.Allocator) !void {
    var daemon = CcpDaemon.init(allocator);
    defer daemon.deinit();
    try daemon.run();
}
