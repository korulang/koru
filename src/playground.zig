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
const js_emitter = @import("js_emitter");
const module_resolver_mod = @import("module_resolver");
const ModuleResolver = module_resolver_mod.ModuleResolver;
const embedded_fs = @import("embedded_fs");
const Config = @import("config").Config;
const canonicalize_names = @import("canonicalize_names");
const file_types = @import("file_types");
const DeadStripPass = @import("dead_strip").DeadStripPass;

/// "std/io" → "std.io" (slashes to dots, Koru extension stripped). Mirrors
/// main.zig's deriveCanonicalName — the name js_emit matches a qualified call
/// (`std.io:println`) against. Trivial enough to own here rather than extract.
fn deriveLogicalName(allocator: std.mem.Allocator, import_path: []const u8) ![]const u8 {
    const without_ext = if (file_types.koruExtensionOf(import_path)) |ext|
        import_path[0 .. import_path.len - ext.len]
    else
        import_path;
    const result = try allocator.alloc(u8, without_ext.len);
    for (without_ext, 0..) |c, i| result[i] = if (c == '/') '.' else c;
    return result;
}

/// Materialize each DIRECT import as a `module_decl` AST item so js_emit (Phase
/// 1b) can emit it. The parser already registers imports into the type registry
/// (and follows transitive imports there via the Fs seam) — but js_emit walks
/// the AST, not the registry, so the entry program needs the imported modules
/// present as items. Reuses the shared resolver (resolveBoth/findCompanionFiles
/// over the embedded Fs); facet companions (.k/.kjs siblings) merge into one
/// module's items, exactly like main.zig's loadFileWithCompanions.
fn materializeImports(allocator: std.mem.Allocator, source_file: *ast.Program, resolver: *ModuleResolver) !void {
    var combined = std.ArrayList(ast.Item){ .items = &.{}, .capacity = 0 };
    try combined.appendSlice(allocator, source_file.items);

    for (source_file.items) |item| {
        if (item != .import_decl) continue;
        const imp = item.import_decl;

        var resolved = resolver.resolveBoth(imp.path, null) catch continue;
        defer resolved.deinit(allocator);
        const file_path = resolved.file_path orelse continue;

        const bytes = (try resolver.fs.readFile(allocator, file_path)) orelse continue;
        var p = try Parser.init(allocator, bytes, file_path, &[_][]const u8{}, resolver);
        defer p.deinit();
        const parsed = try p.parse();

        var mod_items = std.ArrayList(ast.Item){ .items = &.{}, .capacity = 0 };
        try mod_items.appendSlice(allocator, parsed.source_file.items);

        // Fold in facet companions (e.g. a .kjs sibling carrying |js bodies).
        const companions = try module_resolver_mod.findCompanionFiles(resolver.fs, allocator, file_path);
        for (companions) |cp| {
            const cbytes = (try resolver.fs.readFile(allocator, cp)) orelse continue;
            var cp_parser = try Parser.init(allocator, cbytes, cp, &[_][]const u8{}, resolver);
            defer cp_parser.deinit();
            const cparsed = try cp_parser.parse();
            try mod_items.appendSlice(allocator, cparsed.source_file.items);
        }

        try combined.append(allocator, .{ .module_decl = .{
            .logical_name = try deriveLogicalName(allocator, imp.local_name orelse imp.path),
            .canonical_path = try allocator.dupe(u8, file_path),
            .items = try mod_items.toOwnedSlice(allocator),
            .is_system = resolver.isSystemModule(file_path),
            .annotations = &.{},
            .location = .{ .file = file_path, .line = 1, .column = 0 },
        } });
    }

    source_file.items = try combined.toOwnedSlice(allocator);
}

/// A Config that maps the `std` import alias to the embedded stdlib root, so
/// `import "std/io"` resolves against the baked-in koru_std bytes. project_root
/// is the virtual root "/"; no koru.json, no disk.
fn embeddedConfig(allocator: std.mem.Allocator) !Config {
    var paths = std.StringHashMap([][]const u8).init(allocator);
    const std_paths = try allocator.alloc([]const u8, 1);
    std_paths[0] = try allocator.dupe(u8, "/koru_std");
    try paths.put(try allocator.dupe(u8, "std"), std_paths);
    return Config{
        .name = try allocator.dupe(u8, "playground"),
        .version = try allocator.dupe(u8, "0.0.0"),
        .paths = paths,
        .allocator = allocator,
    };
}

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

    // --- Parse (Stage A guts, no bootstrap injection) ---
    // Imports resolve against the embedded stdlib (no disk).
    var config = try embeddedConfig(allocator);
    var resolver = try ModuleResolver.initEmbedded(allocator, &config, embedded_fs.fs(), "/koru_std");
    var parser = try Parser.init(allocator, source, file_name, &[_][]const u8{}, &resolver);
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

    // NOTE: we deliberately do NOT materialize imports here (the JS path does).
    // Materializing only DIRECT imports surfaces stdlib-internal references
    // (e.g. io.kz → std.build:variants) as false KORU040s, because the checkers
    // run on the un-pruned AST. Correct import-aware diagnostics need full
    // TRANSITIVE materialization + user-scoped checking — a follow-up. For now
    // the checkers validate the user's own program shape; calls into stdlib
    // events are left to the JS-compile path.
    canonicalize_names.canonicalize(&source_file, allocator) catch {};

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

/// Compile a snippet straight to JavaScript — the "compile to JS and run" path.
/// No metacircular backend, no `zig build`: parse → js_emitter.emit, in-process.
/// The transform passes that sit between parse and emit in the full pipeline
/// (template processing, auto-discharge, if/for lowering — the "limited
/// compile-time selection") are NOT wired yet; we add them empirically as real
/// programs reveal which ones are load-bearing. A JsEmitError (NoJsProcBody,
/// UnsupportedConstruct, ...) propagates so we see exactly what's missing.
pub fn compileToJs(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) ![]const u8 {
    var config = try embeddedConfig(allocator);
    var resolver = try ModuleResolver.initEmbedded(allocator, &config, embedded_fs.fs(), "/koru_std");
    var parser = try Parser.init(allocator, source, file_name, &[_][]const u8{}, &resolver);
    defer parser.deinit();
    const parse_result = try parser.parse();
    var source_file = parse_result.source_file;
    // Bring imported modules into the AST as module_decl items (js_emit walks
    // the AST), then qualify DottedPaths so `std.io:println` matches them.
    // Order mirrors main(): materialize imports → canonicalize.
    try materializeImports(allocator, &source_file, &resolver);
    try canonicalize_names.canonicalize(&source_file, allocator);
    // Strip unreachable events (e.g. unused stdlib procs whose comptime/template
    // |js variants aren't runnable JS) so only what the program actually calls
    // gets emitted — same pass the real pipeline runs before emission.
    var ds = DeadStripPass.init(allocator);
    defer ds.deinit();
    const pruned = try ds.run(&source_file);
    return try js_emitter.emit(allocator, pruned);
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

    // `--js` emits JavaScript; default emits JSON diagnostics. The remaining
    // non-flag arg is an input file; otherwise read the snippet from stdin.
    var emit_js = false;
    var file: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--js")) emit_js = true else file = arg;
    }

    const file_name = file orelse "playground.kz";
    const source = if (file) |f|
        try std.fs.cwd().readFileAlloc(allocator, f, 16 * 1024 * 1024)
    else
        try std.fs.File.stdin().readToEndAlloc(allocator, 16 * 1024 * 1024);

    const out = if (emit_js)
        try compileToJs(allocator, source, file_name)
    else
        try check(allocator, source, file_name);

    var stdout = std.fs.File.stdout();
    try stdout.writeAll(out);
    try stdout.writeAll("\n");
}
