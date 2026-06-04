//! Playground entrypoint — the diagnostics core for the in-browser Koru playground.
//!
//! This is deliberately NOT the metacircular compiler. `koruc input.kz` runs a
//! four-stage pipeline that shells out to `zig build` twice (Stage B + Stage D,
//! see src/main.zig where std.process.Child spawns the toolchain). A browser
//! cannot spawn a process, so that path can never be WASM.
//!
//! But the semantic checkers and the parser are pure Zig with no subprocess and
//! no filesystem dependency for single-file snippets. This entrypoint wires them
//! directly: source string in → parse → shape/flow/phantom checks → structured
//! diagnostics out. It compiles natively today (proof of the glue); the same
//! source compiles to wasm32 next (slice 2), with `js_emitter` bolted on for
//! actual execution (slice 3).
//!
//! Output is a JSON array of diagnostics so the web shell can render Monaco
//! markers. Native usage: `playground <file.kz>` (or pipe source on stdin).

const std = @import("std");

const ast = @import("ast");
const errors = @import("errors");
const Parser = @import("parser").Parser;
const ShapeChecker = @import("shape_checker").ShapeChecker;
const FlowChecker = @import("flow_checker").FlowChecker;
const PhantomSemanticChecker = @import("phantom_semantic_checker").PhantomSemanticChecker;

/// One diagnostic in the shape the web shell consumes. Mirrors the fields of
/// errors.ParseError that a Monaco marker needs, plus which pass produced it.
const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    line: usize,
    column: usize,
    span_length: usize,
    hint: ?[]const u8,
    stage: []const u8,
};

/// Copy every error the reporter accumulated into `out`, tagging each with the
/// pass that produced it. The reporter owns its strings; we borrow them for the
/// lifetime of JSON emission (single-shot process / single WASM call).
fn collect(out: *std.ArrayList(Diagnostic), reporter: *const errors.ErrorReporter, stage: []const u8, allocator: std.mem.Allocator) !void {
    for (reporter.errors.items) |e| {
        try out.append(allocator, .{
            .code = @tagName(e.code),
            .message = e.message,
            .line = e.location.line,
            .column = e.location.column,
            .span_length = e.span_length,
            .hint = e.hint,
            .stage = stage,
        });
    }
}

/// The whole diagnostics core, allocator-driven and filesystem-free so it
/// transplants to WASM unchanged. `file_name` is cosmetic (shows up in
/// diagnostics). Returns owned JSON; caller frees.
pub fn check(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) ![]const u8 {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    // --- Parse (Stage A guts, no bootstrap injection, no module resolver) ---
    // A single-file snippet resolves nothing, so resolver = null. Imports are
    // the known next gap (needs an in-memory stdlib FS); they'll surface here
    // as KORU002 rather than silently passing.
    var parser = try Parser.init(allocator, source, file_name, &[_][]const u8{}, null);
    defer parser.deinit();

    const parse_result = parser.parse() catch |err| {
        // Parse can both populate the reporter AND return an error. Either way,
        // surface whatever it recorded; if it recorded nothing, the error is a
        // real bug, so let it crash loudly rather than swallow it.
        if (!parser.reporter.hasErrors()) return err;
        try collect(&diagnostics, &parser.reporter, "parse", allocator);
        return try emitJson(allocator, diagnostics.items);
    };
    var source_file = parse_result.source_file;
    try collect(&diagnostics, &parser.reporter, "parse", allocator);

    // --- Semantic checkers (Stage C guts, called directly, no backend binary) ---
    // All three share one reporter and consume only the AST. None need the
    // parser's TypeRegistry — they rebuild what they need from the AST.
    var reporter = try errors.ErrorReporter.init(allocator, file_name, source);
    defer reporter.deinit();

    var shape = try ShapeChecker.init(allocator, &reporter);
    defer shape.deinit();
    shape.checkSourceFile(&source_file) catch |err| if (!reporter.hasErrors()) return err;

    var flow = try FlowChecker.init(allocator, &reporter);
    defer flow.deinit();
    flow.checkSourceFile(&source_file) catch |err| if (!reporter.hasErrors()) return err;

    var phantom = try PhantomSemanticChecker.init(allocator, &reporter);
    defer phantom.deinit();
    phantom.check(&source_file) catch |err| if (!reporter.hasErrors()) return err;

    try collect(&diagnostics, &reporter, "check", allocator);

    return try emitJson(allocator, diagnostics.items);
}

fn appendStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => if (c < 0x20) {
            var tmp: [8]u8 = undefined;
            try buf.appendSlice(a, std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable);
        } else try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn appendInt(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: usize) !void {
    var tmp: [20]u8 = undefined;
    try buf.appendSlice(a, std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable);
}

/// Hand-built JSON so we don't ride the churning std.json stringify API (the
/// rest of the compiler hand-builds JSON too). Fixed 7-field schema per item.
fn emitJson(allocator: std.mem.Allocator, items: []const Diagnostic) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |d, i| {
        if (i != 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"code\":");
        try appendStr(&buf, allocator, d.code);
        try buf.appendSlice(allocator, ",\"message\":");
        try appendStr(&buf, allocator, d.message);
        try buf.appendSlice(allocator, ",\"line\":");
        try appendInt(&buf, allocator, d.line);
        try buf.appendSlice(allocator, ",\"column\":");
        try appendInt(&buf, allocator, d.column);
        try buf.appendSlice(allocator, ",\"span_length\":");
        try appendInt(&buf, allocator, d.span_length);
        try buf.appendSlice(allocator, ",\"hint\":");
        if (d.hint) |h| try appendStr(&buf, allocator, h) else try buf.appendSlice(allocator, "null");
        try buf.appendSlice(allocator, ",\"stage\":");
        try appendStr(&buf, allocator, d.stage);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

pub fn main() !void {
    // Arena: a playground run is allocate → check → emit → discard, exactly how
    // a single WASM `check()` call will work. No per-allocation frees, no leak
    // noise — the whole run is freed in one shot at the end.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var source: []const u8 = undefined;
    var owned = false;
    var file_name: []const u8 = "playground.kz";

    if (args.len > 1) {
        file_name = args[1];
        source = try std.fs.cwd().readFileAlloc(allocator, args[1], 16 * 1024 * 1024);
        owned = true;
    } else {
        // Read the snippet from stdin.
        source = try std.fs.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);
        owned = true;
    }
    defer if (owned) allocator.free(source);

    const json = try check(allocator, source, file_name);
    defer allocator.free(json);

    var stdout = std.fs.File.stdout();
    try stdout.writeAll(json);
    try stdout.writeAll("\n");
}
