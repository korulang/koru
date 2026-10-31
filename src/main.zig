const std = @import("std");
const log = @import("log");
const Parser = @import("parser").Parser;
const errors = @import("errors");
const ErrorReporter = errors.ErrorReporter;
const shape_checker = @import("shape_checker");
const ShapeChecker = shape_checker.ShapeChecker;
const purity_checker = @import("purity_checker.zig");
const PurityChecker = purity_checker.PurityChecker;
const threaded_checker = @import("threaded_checker.zig");
const compiler_feature_flags = @import("compiler_config");
// Old Emitter no longer needed - using ComptimeEmitter
const ast = @import("ast");
const TypeRegistry = @import("type_registry").TypeRegistry;
const validate_abstract_impl = @import("validate_abstract_impl");
// CompilerBootstrap removed - using abstract/impl mechanism instead
// compiler_coordination.zig removed - all passes run in backend via compiler.kz
// emitter.zig removed - using visitor_emitter now
const TapCollector = @import("tap_collector").TapCollector;
const CompilerRequiresCollector = @import("compiler_requires").CompilerRequiresCollector;
const emit_build_zig = @import("emit_build_zig");
const app_bundle = @import("app_bundle");
const PackageRequirementsCollector = @import("package_requires").PackageRequirementsCollector;
const emit_package_files = @import("emit_package_files");
const ModuleResolver = @import("module_resolver").ModuleResolver;
const module_resolver_mod = @import("module_resolver");
const file_types = @import("file_types");
const project_template = @import("project_template.zig");
const Config = @import("config").Config;
const annotation_parser = @import("annotation_parser");
const keyword_registry = @import("keyword_registry");
const flow_checker = @import("flow_checker");
const FlowChecker = flow_checker.FlowChecker;
const codegen_utils = @import("codegen_utils");
const lexer = @import("lexer");
const liquid = @import("liquid");
const struct_literal = @import("struct_literal");
const emitter_helpers = @import("emitter_helpers");
const site_hash = @import("site_hash");

/// Native-only link steps (OpenSSL, etc.) must not run on wasm reactor builds.
fn buildRequireSkippedOnWasm(req: []const u8) bool {
    const build_target = emitter_helpers.getBuildConfig("target") orelse return false;
    if (std.mem.indexOf(u8, build_target, "wasm") == null) return false;
    return std.mem.indexOf(u8, req, "linkSystemLibrary(\"ssl\")") != null or
        std.mem.indexOf(u8, req, "linkSystemLibrary(\"crypto\")") != null or
        std.mem.indexOf(u8, req, "openssl@3") != null;
}
const ccp = @import("ccp.zig");
const import_pipeline = @import("import_pipeline.zig");

const version = "0.1.7";

/// Write a branch name as a Zig identifier: kebab `-` mangled to `_`, otherwise
/// escaped if it collides with a Zig keyword.
///
/// THE MANGLE IS NOT OPTIONAL, AND THIS COPY DID NOT HAVE IT. The union that
/// declares these branches is written by `emitter_helpers.writeBranchName`,
/// which mangles — so `| parse-error` becomes the field `parse_error`. This
/// site writes the switch ARM that matches it, and without the mangle it wrote
/// `.@"parse-error"`: a legal Zig identifier naming a field that does not
/// exist. The two spellings only ever meet when a program switches on a
/// hyphenated branch of a tor declared in ANOTHER module, which is why it
/// stayed invisible. No minimal test distinguishes it yet — see the note on
/// `codegen_utils.appendBranchName` for what was tried and what was measured.
///
/// Both writers answer one question. If you change how a branch name is spelled,
/// change it in `emitter_helpers.writeBranchName` too, or the union and its
/// switch arms drift apart again.
fn writeBranchName(writer: anytype, name: []const u8) !void {
    for (name) |c| {
        if (c == '-') {
            for (name) |ch| try writer.writeAll(&[_]u8{if (ch == '-') '_' else ch});
            return;
        }
    }
    if (codegen_utils.needsEscaping(name)) {
        try writer.writeAll("@\"");
        try writer.writeAll(name);
        try writer.writeAll("\"");
    } else {
        try writer.writeAll(name);
    }
}

/// Compiler configuration - captures all flags and environment for backend embedding
const CompilerConfig = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList([]const u8),
    env_vars: std.StringHashMap([]const u8),
    /// Default language target — selects which variant gets emitted when no
    /// explicit ~[build]std.build:variants registration exists. Matches the
    /// variant-tag namespace ("zig", "js", "gpu", ...) so `--lang=js` selects
    /// the `~proc foo|js` variant. Set via `--lang=<name>` on the koruc CLI.
    lang: []const u8 = "zig",
    /// True for `koruc lib`: this compilation is a LIBRARY, so the entry
    /// module's `pub` items are roots and survive with no caller here. A
    /// program's roots are its flows and an uncalled item is dead.
    library: bool = false,

    pub fn init(allocator: std.mem.Allocator) !CompilerConfig {
        return .{
            .allocator = allocator,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .env_vars = std.StringHashMap([]const u8).init(allocator),
            .lang = try allocator.dupe(u8, "zig"),
        };
    }

    pub fn deinit(self: *CompilerConfig) void {
        for (self.flags.items) |flag| {
            self.allocator.free(flag);
        }
        self.flags.deinit(self.allocator);

        var it = self.env_vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.env_vars.deinit();

        self.allocator.free(self.lang);
    }

    /// Replace the lang value with an owned copy of `new_lang`, freeing the
    /// previous owned slice. Used by `--lang=<name>` CLI parsing.
    pub fn setLang(self: *CompilerConfig, new_lang: []const u8) !void {
        const owned = try self.allocator.dupe(u8, new_lang);
        self.allocator.free(self.lang);
        self.lang = owned;
    }

    pub fn addFlag(self: *CompilerConfig, flag: []const u8) !void {
        const owned = try self.allocator.dupe(u8, flag);
        try self.flags.append(self.allocator, owned);
    }

    pub fn addEnv(self: *CompilerConfig, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.env_vars.put(owned_key, owned_value);
    }

    pub fn hasFlag(self: *const CompilerConfig, flag: []const u8) bool {
        for (self.flags.items) |f| {
            if (std.mem.eql(u8, f, flag)) {
                return true;
            }
        }
        return false;
    }
};

fn printStderr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    const stderr = std.fs.File.stderr();
    try stderr.writeAll(msg);
}

// ============================================================================
// Subprocess termination — the full Term union, every time.
//
// `result.term.Exited` is a union field access: when the child was killed by
// a signal (the OOM killer under memory pressure, an external `kill`), the
// active field is `.Signal` and the access PANICS — koruc dies with
// "access of union field 'Exited' while field 'Signal' is active", which
// reads exactly like a compiler crash and gets diagnosed as one (it did,
// 2026-07-31: a signal-killed backend build was recorded as "BUILD FAILED"
// with an empty diagnostic). Every site that inspects a child's termination
// goes through these helpers or through an explicit switch over all four
// variants.
// ============================================================================

/// Name the signals a build subprocess plausibly dies by. Numbers-only for
/// the rest — the number is always printed alongside.
fn signalName(sig: u32) []const u8 {
    const SIG = std.posix.SIG;
    return switch (sig) {
        SIG.KILL => "SIGKILL",
        SIG.TERM => "SIGTERM",
        SIG.INT => "SIGINT",
        SIG.HUP => "SIGHUP",
        SIG.QUIT => "SIGQUIT",
        SIG.SEGV => "SIGSEGV",
        SIG.ABRT => "SIGABRT",
        SIG.BUS => "SIGBUS",
        SIG.FPE => "SIGFPE",
        SIG.ILL => "SIGILL",
        SIG.PIPE => "SIGPIPE",
        SIG.TRAP => "SIGTRAP",
        else => "unnamed signal",
    };
}

/// Did the child exit on its own with code 0? The safe fold for sites whose
/// only question is success/failure.
fn termIsClean(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Render a termination for a diagnostic, into a caller buffer (64 bytes is
/// ample). Infallible so it can be used on error paths.
fn describeTerm(buf: []u8, term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .Exited => |code| std.fmt.bufPrint(buf, "exited with code {d}", .{code}) catch "exited",
        .Signal => |sig| std.fmt.bufPrint(buf, "was killed by signal {d} ({s})", .{ sig, signalName(sig) }) catch "was killed by a signal",
        .Stopped => |sig| std.fmt.bufPrint(buf, "was stopped by signal {d}", .{sig}) catch "was stopped by a signal",
        .Unknown => |status| std.fmt.bufPrint(buf, "ended in an unknown state (status {d})", .{status}) catch "ended in an unknown state",
    };
}

/// Forward a spawned command's termination: exit with its code, or name a
/// signal/machine end out loud rather than folding it into a bare exit 1.
fn exitLikeCommand(allocator: std.mem.Allocator, cmd_name: []const u8, term: std.process.Child.Term) !noreturn {
    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |sig| {
            try printStderr(allocator, "✗ Command '{s}' was killed by signal {d} ({s})\n", .{ cmd_name, sig, signalName(sig) });
            std.process.exit(@intCast(128 + (sig & 0x7f)));
        },
        else => {
            var term_buf: [64]u8 = undefined;
            try printStderr(allocator, "✗ Command '{s}' {s}\n", .{ cmd_name, describeTerm(&term_buf, term) });
            std.process.exit(1);
        },
    }
}

/// Write one requirements manifest (`package.json`, `Cargo.toml`, …) into
/// `output_dir` and report the generated path.
fn emitRequirementFile(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    comptime filename: []const u8,
    reqs: []const []const u8,
    emitFn: *const fn (std.mem.Allocator, []const []const u8, []const u8) anyerror!void,
) !void {
    const path = try std.fs.path.join(allocator, &.{ output_dir, filename });
    defer allocator.free(path);
    try emitFn(allocator, reqs, path);
    try printStdout(allocator, "✓ Generated {s}\n", .{path});
}

/// One `--install-packages` step: run a package manager inside `output_dir`
/// and report the outcome. `action`/`done_msg` are the shown phrases
/// ("Running npm install...", "✓ npm packages installed").
fn runPackageStep(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    argv: []const []const u8,
    comptime action: []const u8,
    comptime done_msg: []const u8,
) !void {
    try printStdout(allocator, "  Running " ++ action ++ "...\n", .{});
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = output_dir,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!termIsClean(result.term)) {
        var term_buf: [64]u8 = undefined;
        try printStderr(allocator, "✗ " ++ action ++ " failed ({s}):\n{s}\n", .{ describeTerm(&term_buf, result.term), result.stderr });
    } else {
        try printStdout(allocator, "  ✓ " ++ done_msg ++ "\n", .{});
    }
}

/// The teaching for a PIPELINE subprocess (backend build, backend run) that
/// never got to exit. A signal here is a fact about the machine, not about
/// the program being compiled — say which subprocess, what ended it, where
/// BACKEND BINARY CACHE (2026-08-15): the backend executable (compiled from
/// src/*.zig plus the koru_std files embedded via backend_output_emitted.zig)
/// is byte-reusable across user programs — its Design comment says so, and
/// rebuilding it dominates every compile (~11.6s measured on a 512-flow
/// store program; the transform passes themselves are ~0.4s). Cache the
/// produced binary keyed on the compiler-side inputs' content: a hit copies
/// the cached backend and skips the zig build entirely. The cache is a SPEED
/// optimization — any doubt (IO error, missing dir, zero files) disables it
/// and the normal build runs.
///
/// The key covers every file that can change the backend: src/ + koru_std/
/// plus the generated backend_output_emitted.zig in the output directory
/// (the compiled comptime modules + user-library transforms).
///
/// Deliberately NOT covered: compiler_env.json. The per-invocation
/// environment (lang, library, flags, paths) is runtime data the backend
/// loads at startup — before the unbake it was baked into compiler_env.zig
/// and hashed here, so every flag flip (even the bare `koruc prog` vs
/// `koruc prog run` verb change via the injected `command=` atom) forced a
/// full backend rebuild. Runtime data cannot poison a build cache, which is
/// also what makes the old --lang cross-serve bug unrepresentable now.
/// (History: before 2026-08-16 the key hashed only src/ + koru_std/, so a
/// backend built with `--lang=js` was served to a later zig build under the
/// same key — the cached binary carried the old lang baked into CompilerEnv
/// and silently emitted JS for zig programs. Proof: `koruc input.k --lang=js`
/// then `koruc input.k` with a shared cache produced output_emitted.js from
/// the zig invocation.)
fn backendCacheKey(allocator: std.mem.Allocator, koru_home: []const u8, output_dir: []const u8, emitted_source: []const u8) ?[]const u8 {
    var h = std.hash.Fnv1a_64.init();
    var count: usize = 0;
    const roots = [_][]const u8{ "src", "koru_std" };
    for (roots) |root| {
        const root_path = std.fs.path.join(allocator, &[_][]const u8{ koru_home, root }) catch return null;
        defer allocator.free(root_path);
        var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return null;
        defer dir.close();
        var wlk = dir.walk(allocator) catch return null;
        defer wlk.deinit();
        h.update(root);
        while (wlk.next() catch return null) |entry| {
            if (entry.kind != .file) continue;
            // CONTENT hash, not mtime: a mid-edit rebuild can cache POISON
            // (a backend built from half-written sources); mtimes that happen
            // to match across the edit would then serve it forever. Content
            // bytes of the partially-written file can never equal the clean
            // state, so the poison key cannot be reproduced. Reading ~200
            // files is a few ms against the ~11.6s build being skipped.
            const contents = entry.dir.readFileAlloc(allocator, entry.basename, 64 * 1024 * 1024) catch return null;
            h.update(entry.path);
            h.update(contents);
            allocator.free(contents);
            count += 1;
        }
    }
    // backend_output_emitted.zig is the generated embed: it carries the
    // COMPILED comptime modules the backend binary bakes in — koru_std's own
    // flows AND user-library transforms (orisha's router, std/store, std/regex).
    // The roots cannot see it (generated into output_dir, not koru_home), and
    // it is the ONLY key input that moves when a sibling library like orisha is
    // edited: an orisha change regenerates it with the new koru_orisha module,
    // and hashing it here is what turns that edit into a cache miss instead of
    // a stale backend serving an old a.out. Same FAIL-LOUD rule as above:
    // unreadable means disable the cache, never serve a mismatch.
    const embedded_path = std.fs.path.join(allocator, &[_][]const u8{ output_dir, "backend_output_emitted.zig" }) catch return null;
    defer allocator.free(embedded_path);
    const embedded_contents = std.fs.cwd().readFileAlloc(allocator, embedded_path, 64 * 1024 * 1024) catch return null;
    defer allocator.free(embedded_contents);
    h.update("backend_output_emitted.zig");
    h.update(embedded_contents);
    count += 1;
    // The emitted backend source and its build file are generated per-compile
    // by THIS koruc binary — the src+koru_std hash above only sees the tree,
    // not the emitter. A stale koruc over a current tree emits a stale
    // backend and would otherwise cache it under a current-src key,
    // poisoning every later build that hits it (measured 2026-10-11: a
    // post-overlay koruc was served a pre-overlay backend; the emitted
    // program silently compiled against stock zig std). Hashing the emitted
    // files keys on the actual zig-build inputs. `emitted_source` is the
    // caller's own output path so a renamed emit is keyed too. Same
    // FAIL-LOUD rule: unreadable means disable the cache, never serve a
    // mismatch.
    for ([_][]const u8{ emitted_source, "build_backend.zig" }) |emitted| {
        const emitted_path = if (std.fs.path.dirname(emitted)) |_|
            emitted
        else
            std.fs.path.join(allocator, &[_][]const u8{ output_dir, emitted }) catch return null;
        defer if (std.fs.path.dirname(emitted) == null) allocator.free(emitted_path);
        const emitted_contents = std.fs.cwd().readFileAlloc(allocator, emitted_path, 64 * 1024 * 1024) catch return null;
        defer allocator.free(emitted_contents);
        h.update(emitted);
        h.update(emitted_contents);
        count += 1;
    }
    // ABI identity: backend binaries are dynamically linked, and a binary
    // minted under one host glibc (or an explicit KORU_BACKEND_TARGET)
    // hard-fails on another via versioned symbols — the key must refuse
    // that replay instead of trusting it. Same block as backendHashComponents
    // (the mint key); this cache predates it and stayed env-blind — measured
    // 2026-10-14: a glibc-2.34 mint replayed under a 2.31-targeted build.
    {
        const builtin = @import("builtin");
        const backend_target_env: ?[]const u8 = std.process.getEnvVarOwned(allocator, "KORU_BACKEND_TARGET") catch null;
        defer if (backend_target_env) |t| allocator.free(t);
        if (backend_target_env) |t| {
            h.update("KORU_BACKEND_TARGET");
            h.update(t);
        } else {
            h.update("native");
            h.update(@tagName(builtin.target.abi));
            if (builtin.target.os.versionRange().gnuLibCVersion()) |v| {
                h.update(std.mem.asBytes(&v.major));
                h.update(std.mem.asBytes(&v.minor));
            }
        }
    }
    if (count == 0) return null;
    return std.fmt.allocPrint(allocator, "{x}", .{h.final()}) catch null;
}

/// The backend cache directory: $ZIG_GLOBAL_CACHE when set (the convention
/// the regression harness uses), else $HOME/.cache/koru-backend-cache.
/// ALWAYS returns an owned allocation (callers free); the fallback chain
/// never yields a literal that a caller could free.
fn backendCacheDir(allocator: std.mem.Allocator) []const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZIG_GLOBAL_CACHE")) |z| {
        if (std.fs.path.join(allocator, &[_][]const u8{ z, "koru-backend-cache" })) |p| {
            allocator.free(z);
            return p;
        } else |_| allocator.free(z);
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "HOME")) |h| {
        if (std.fs.path.join(allocator, &[_][]const u8{ h, ".cache", "koru-backend-cache" })) |p| {
            allocator.free(h);
            return p;
        } else |_| allocator.free(h);
    } else |_| {}
    // Last resort: an owned copy of a relative name. Only an allocator
    // failure can reach here, and freeing a fresh dup is always safe.
    return allocator.dupe(u8, ".koru-backend-cache") catch ".koru-backend-cache";
}

// ============================================================
// COMPILER MINTS — named, durable backend binaries.
//
// `koruc <file> mint <name>` builds this program's backend and stores the
// binary + a manifest in the mint store ($KORU_MINT_DIR, else
// ~/.koru/mints/<name>/). `std/compiler:use("name", hash: "…")` in a program
// pins the compile to a mint: the frontend writes program.ast.json +
// compiler_env.json and runs the minted binary directly — backend.zig,
// backend_output_emitted.zig and the zig build are all skipped.
// `koruc <file> mint check <name>` recomputes the closure over the live tree
// and diffs it against the manifest — the audit verb `use` skips.
//
// The COVERAGE predicate is the hash of backend_output_emitted.zig: it is the
// only program-derived input compiled into the backend (comptime modules,
// transform handlers, the baked command dispatch). Emitting it is codegen
// over the already-parsed AST — cheap next to the zig build it replaces.
// ============================================================

const CompilerUse = struct {
    name: []const u8,
    hash: ?[]const u8,
};

/// One library root the resolver would consult — usually a directory, but an
/// alias path can name a .kz file directly. key null = configured but absent
/// at measurement time; a present root hashes the files this compilation
/// loaded under it (path-seeded — a root that contributed nothing still has
/// a deterministic key), so a root appearing or vanishing is drift.
const LibRoot = struct {
    path: []const u8,
    key: ?u64,
};

/// Per-component content hashes of everything compiled into a backend binary.
/// `use` verifies `emitted` + `iface`; `mint check` diffs all of them. `libs`
/// is the resolver's full root set — the stdlib is just one root among them,
/// not a privileged component.
const BackendHashComponents = struct {
    src: u64,
    libs: []LibRoot,
    emitted: u64,
    iface: u64,
    combined: u64,

    pub fn deinit(self: *BackendHashComponents, allocator: std.mem.Allocator) void {
        for (self.libs) |lib| allocator.free(lib.path);
        allocator.free(self.libs);
    }
};

fn fnvHex(allocator: std.mem.Allocator, v: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{v});
}

/// Content-hash every file under root_path (relative paths + bytes). Same
/// fail-loud rule as backendCacheKey: unreadable means null, never a mismatch.
fn hashTree(allocator: std.mem.Allocator, root_path: []const u8, label: []const u8) ?u64 {
    var h = std.hash.Fnv1a_64.init();
    var count: usize = 0;
    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var wlk = dir.walk(allocator) catch return null;
    defer wlk.deinit();
    h.update(label);
    while (wlk.next() catch return null) |entry| {
        if (entry.kind != .file) continue;
        const contents = entry.dir.readFileAlloc(allocator, entry.basename, 64 * 1024 * 1024) catch return null;
        h.update(entry.path);
        h.update(contents);
        allocator.free(contents);
        count += 1;
    }
    if (count == 0) return null;
    return h.final();
}

/// The frontend/backend runtime contract: program.ast.json is written by this
/// koruc (ast_json.zig) and read by the minted backend's baked deserializer;
/// compiler_env.json likewise (compiler_env.zig). If any of these files moved
/// since the mint, the mint speaks a different wire protocol — refuse.
fn hashIfaceFiles(allocator: std.mem.Allocator, koru_home: []const u8) ?u64 {
    const files = [_][]const u8{ "src/ast_json.zig", "src/compiler_env.zig" };
    var h = std.hash.Fnv1a_64.init();
    for (files) |rel| {
        const p = std.fs.path.join(allocator, &[_][]const u8{ koru_home, rel }) catch return null;
        defer allocator.free(p);
        const contents = std.fs.cwd().readFileAlloc(allocator, p, 64 * 1024 * 1024) catch return null;
        defer allocator.free(contents);
        h.update(rel);
        h.update(contents);
    }
    return h.final();
}

/// Hash the emitted backend minus `//` comments. Provenance comments carry
/// `[file:line]` markers — the program's own filename and absolute stdlib
/// paths — that are not part of the comptime/command closure; without
/// normalization the coverage hash would pin a mint to one filename and one
/// checkout location.
fn hashEmittedNormalized(contents: []const u8) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update("backend_output_emitted.zig");
    var in_string = false;
    var in_comment = false;
    var span_start: usize = 0;
    var i: usize = 0;
    while (i < contents.len) {
        const c = contents[i];
        if (in_comment) {
            i += 1;
            if (c == '\n') {
                in_comment = false;
                span_start = i;
            }
            continue;
        }
        if (in_string) {
            i += 1;
            if (c == '\\' and i < contents.len) {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < contents.len and contents[i + 1] == '/') {
            h.update(contents[span_start..i]);
            in_comment = true;
            i += 2;
            continue;
        }
        i += 1;
    }
    h.update(contents[span_start..]);
    return h.final();
}

/// Does this configured root exist at all — dir or file?
fn libRootExists(path: []const u8) bool {
    if (ModuleResolver.isDirectory(path)) return true;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Content-hash one library root over the files the compilation actually
/// loaded under it — the closure is what the program READ, not everything
/// sitting in the directory. Path-seeded so a renamed identical tree is a
/// different root; a root that exists but contributed no loaded file still
/// hashes deterministically (its bare path).
fn hashLibRoot(allocator: std.mem.Allocator, root: []const u8, files: []const []const u8) ?u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(root);
    for (files) |f| {
        const rel = f[root.len..];
        const contents = std.fs.cwd().readFileAlloc(allocator, f, 64 * 1024 * 1024) catch return null;
        defer allocator.free(contents);
        h.update(rel);
        h.update(contents);
    }
    return h.final();
}

fn backendHashComponents(allocator: std.mem.Allocator, koru_home: []const u8, resolver: *ModuleResolver, emitted_contents: []const u8) ?BackendHashComponents {
    const src_path = std.fs.path.join(allocator, &[_][]const u8{ koru_home, "src" }) catch return null;
    defer allocator.free(src_path);
    const src = hashTree(allocator, src_path, "src") orelse return null;
    const iface = hashIfaceFiles(allocator, koru_home) orelse return null;
    const emitted = hashEmittedNormalized(emitted_contents);
    // Path ownership moves element-wise into libs; only the slice is freed here.
    const root_paths = resolver.libraryRoots(allocator) catch return null;
    defer allocator.free(root_paths);
    const libs = allocator.alloc(LibRoot, root_paths.len) catch {
        for (root_paths) |p| allocator.free(p);
        return null;
    };

    // Bucket the loaded set by containing root — longest prefix wins, so a
    // root nested under another (vaxis under examples) claims its own files.
    const buckets = allocator.alloc(std.ArrayList([]const u8), root_paths.len) catch return null;
    for (buckets) |*b| b.* = .{};
    defer {
        for (buckets) |*b| b.deinit(allocator);
        allocator.free(buckets);
    }
    var fiter = resolver.resolved_files.keyIterator();
    while (fiter.next()) |fp| {
        const f = fp.*;
        var best: ?usize = null;
        for (root_paths, 0..) |r, i| {
            const under = f.len == r.len or (f.len > r.len and f[r.len] == '/');
            if (under and std.mem.eql(u8, f[0..r.len], r)) {
                if (best == null or r.len > root_paths[best.?].len) best = i;
            }
        }
        if (best) |i| buckets[i].append(allocator, f) catch return null;
    }
    for (root_paths, 0..) |p, i| {
        if (!libRootExists(p)) {
            libs[i] = .{ .path = p, .key = null };
            continue;
        }
        std.mem.sort([]const u8, buckets[i].items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        libs[i] = .{ .path = p, .key = hashLibRoot(allocator, p, buckets[i].items) orelse return null };
    }
    var ch = std.hash.Fnv1a_64.init();
    ch.update(std.mem.asBytes(&src));
    for (libs) |lib| {
        ch.update(lib.path);
        const k: u64 = lib.key orelse 0;
        ch.update(std.mem.asBytes(&k));
    }
    ch.update(std.mem.asBytes(&emitted));
    // ABI identity: backend binaries are dynamically linked, and a binary
    // minted under one host glibc (or an explicit KORU_BACKEND_TARGET)
    // hard-fails on another via versioned symbols — the key must refuse
    // that replay instead of trusting it.
    const builtin = @import("builtin");
    const backend_target_env: ?[]const u8 = std.process.getEnvVarOwned(allocator, "KORU_BACKEND_TARGET") catch null;
    defer if (backend_target_env) |t| allocator.free(t);
    if (backend_target_env) |t| {
        ch.update("KORU_BACKEND_TARGET");
        ch.update(t);
    } else {
        ch.update("native");
        ch.update(@tagName(builtin.target.abi));
        if (builtin.target.os.versionRange().gnuLibCVersion()) |v| {
            ch.update(std.mem.asBytes(&v.major));
            ch.update(std.mem.asBytes(&v.minor));
        }
    }
    return .{ .src = src, .libs = libs, .emitted = emitted, .iface = iface, .combined = ch.final() };
}

/// JSON-escape a raw byte string into a writer — filesystem paths are not
/// guaranteed clean, so quotes, backslashes, and control bytes all escape.
fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{b}),
            else => try w.writeByte(b),
        }
    }
}

fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const contents = std.fs.cwd().readFileAlloc(allocator, path, 512 * 1024 * 1024) catch return null;
    defer allocator.free(contents);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    const hex = "0123456789abcdef";
    var out = allocator.alloc(u8, 64) catch return null;
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

/// Mint names are store keys — a name that escapes the store directory is a
/// path traversal, so anything outside [A-Za-z0-9._-] (and bare dots) refuses.
fn mintNameValid(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn mintDir(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (!mintNameValid(name)) {
        try printStderr(allocator, "error: invalid mint name '{s}'\n\n  Mint names are store keys — letters, digits, '.', '_', '-' only.\n", .{name});
        return null;
    }
    const root = if (std.process.getEnvVarOwned(allocator, "KORU_MINT_DIR")) |d|
        d
    else |_| blk: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
        defer allocator.free(home);
        break :blk std.fs.path.join(allocator, &[_][]const u8{ home, ".koru", "mints" }) catch return null;
    };
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &[_][]const u8{ root, name });
}

/// Scan the merged program for `compiler:use(name, hash: "…")` directives.
/// Frontend-only — collected textually like compiler:requires. More than one
/// is a refusal: a program cannot pin two backends.
fn collectCompilerUse(allocator: std.mem.Allocator, items: []const ast.Item, found: *?CompilerUse) !void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                const inv = flow.inv();
                const mq = inv.path.module_qualifier orelse continue;
                const is_compiler = std.mem.eql(u8, mq, "compiler") or std.mem.endsWith(u8, mq, ".compiler");
                if (!is_compiler or inv.path.segments.len != 1) continue;
                if (!std.mem.eql(u8, inv.path.segments[0], "use")) continue;
                if (found.* != null) {
                    try printStderr(allocator, "error: more than one compiler:use directive\n\n  A program pins one minted backend — delete the extra use.\n", .{});
                    std.process.exit(1);
                }
                var name: ?[]const u8 = null;
                var pin: ?[]const u8 = null;
                for (inv.args) |arg| {
                    const v = stripQuotes(arg.value);
                    if (std.mem.eql(u8, arg.name, "hash")) {
                        pin = v;
                    } else if (std.mem.eql(u8, arg.name, "name") or
                        std.mem.eql(u8, arg.name, "expr") or
                        arg.name.len == 0 or std.mem.eql(u8, arg.name, arg.value))
                    {
                        // Positional/expr arg — the mint name.
                        if (name == null) name = v;
                    }
                }
                if (name == null) {
                    try printStderr(allocator, "error: compiler:use needs a mint name\n\n  Spell it compiler:use(\"my-compiler\") or compiler:use(my-compiler).\n", .{});
                    std.process.exit(1);
                }
                found.* = .{ .name = name.?, .hash = pin };
            },
            .module_decl => |*module| try collectCompilerUse(allocator, module.items, found),
            else => {},
        }
    }
}

fn isCompilerUseFlow(flow: *const ast.Flow) bool {
    const inv = flow.inv();
    const mq = inv.path.module_qualifier orelse return false;
    const is_compiler = std.mem.eql(u8, mq, "compiler") or std.mem.endsWith(u8, mq, ".compiler");
    return is_compiler and inv.path.segments.len == 1 and
        std.mem.eql(u8, inv.path.segments[0], "use");
}

/// Remove compiler:use directive flows after collection. The directive is
/// frontend-only; left in the AST it lands in the emitted comptime backend as
/// a comptime flow call, so the mint name itself would join the coverage hash —
/// `use(A)` and `use(B)` would read as different closures.
fn stripCompilerUseFlows(allocator: std.mem.Allocator, items: []const ast.Item) ![]const ast.Item {
    var out = try std.ArrayList(ast.Item).initCapacity(allocator, items.len);
    for (items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                if (isCompilerUseFlow(f)) continue;
                try out.append(allocator, item.*);
            },
            .module_decl => |*m| {
                var module_copy = m.*;
                module_copy.items = try stripCompilerUseFlows(allocator, m.items);
                try out.append(allocator, .{ .module_decl = module_copy });
            },
            else => try out.append(allocator, item.*),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

fn loadMintManifest(allocator: std.mem.Allocator, mint_dir: []const u8) ?std.json.Parsed(std.json.Value) {
    const path = std.fs.path.join(allocator, &[_][]const u8{ mint_dir, "mint.json" }) catch return null;
    defer allocator.free(path);
    const text = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    // alloc_always: parsed strings are copies, so the buffer dies at parse end.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always }) catch {
        allocator.free(text);
        return null;
    };
    allocator.free(text);
    return parsed;
}

fn manifestStr(m: std.json.Value, key: []const u8) []const u8 {
    if (m != .object) return "";
    const v = m.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// Verify a mint against this program and return the backend binary path.
/// Two hard gates: emitted coverage (the mint's comptime/command closure
/// matches THIS program's) and iface (the mint's AST/env wire protocol matches
/// THIS koruc's). Optional `hash:` additionally pins the binary's sha256.
fn resolveMintedBackend(allocator: std.mem.Allocator, koru_home: []const u8, resolver: *ModuleResolver, ud: CompilerUse, emitted_code: []const u8) ![]const u8 {
    const dir = (try mintDir(allocator, ud.name)) orelse std.process.exit(1);
    defer allocator.free(dir);
    const manifest_parsed = loadMintManifest(allocator, dir) orelse {
        try printStderr(allocator, "error: no mint named '{s}'\n\n  Mint one first:\n      koruc <file.k> mint {s}\n", .{ ud.name, ud.name });
        std.process.exit(1);
    };
    const manifest = manifest_parsed.value;
    defer manifest_parsed.deinit();
    if (manifest != .object) {
        try printStderr(allocator, "error: mint '{s}' manifest is corrupt — delete {s} and re-mint\n", .{ ud.name, dir });
        std.process.exit(1);
    }

    var now = backendHashComponents(allocator, koru_home, resolver, emitted_code) orelse {
        try printStderr(allocator, "error: cannot verify mint '{s}' — compiler sources unreadable\n", .{ud.name});
        std.process.exit(1);
    };
    defer now.deinit(allocator);
    const emitted_now = try fnvHex(allocator, now.emitted);
    defer allocator.free(emitted_now);
    if (!std.mem.eql(u8, emitted_now, manifestStr(manifest, "emitted_key"))) {
        try printStderr(allocator, "error: mint '{s}' does not cover this program\n\n  The mint's comptime/command closure differs from what this program needs\n  (a transform or command import changed since the mint). Re-mint:\n      koruc <file.k> mint {s}\n", .{ ud.name, ud.name });
        std.process.exit(1);
    }
    const iface_now = try fnvHex(allocator, now.iface);
    defer allocator.free(iface_now);
    if (!std.mem.eql(u8, iface_now, manifestStr(manifest, "iface_key"))) {
        try printStderr(allocator, "error: mint '{s}' speaks an older AST/env protocol\n\n  src/ast_json.zig or src/compiler_env.zig moved since the mint — the\n  minted backend cannot read this frontend's program.ast.json. Re-mint:\n      koruc <file.k> mint {s}\n", .{ ud.name, ud.name });
        std.process.exit(1);
    }

    const bin = try std.fs.path.join(allocator, &[_][]const u8{ dir, "backend" });
    std.fs.cwd().access(bin, .{}) catch {
        try printStderr(allocator, "error: mint '{s}' has no backend binary at {s}\n", .{ ud.name, bin });
        std.process.exit(1);
    };
    if (ud.hash) |pin| {
        const actual = sha256FileHex(allocator, bin) orelse {
            try printStderr(allocator, "error: cannot hash minted backend at {s}\n", .{bin});
            std.process.exit(1);
        };
        defer allocator.free(actual);
        if (!std.mem.eql(u8, actual, pin)) {
            try printStderr(allocator, "error: mint '{s}' binary does not match pinned hash\n\n  pinned: {s}\n  actual: {s}\n\n  The mint was re-created or modified since the pin. Re-mint and update\n  the hash, or drop `hash:` to follow the name.\n", .{ ud.name, pin, actual });
            std.process.exit(1);
        }
    }
    try printStdout(allocator, "✓ Minted backend '{s}' verified (closure match)\n", .{ud.name});
    return bin;
}

/// `koruc <file> mint <name>` — after the backend build: store the binary and
/// a manifest recording the closure it was minted from.
fn storeMint(allocator: std.mem.Allocator, koru_home: []const u8, resolver: *ModuleResolver, name: []const u8, built_backend: []const u8, emitted_code: []const u8, source: []const u8) !void {
    const dir = (try mintDir(allocator, name)) orelse std.process.exit(1);
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch |err| {
        try printStderr(allocator, "error: cannot create mint store {s}: {s}\n", .{ dir, @errorName(err) });
        std.process.exit(1);
    };
    const dest = try std.fs.path.join(allocator, &[_][]const u8{ dir, "backend" });
    defer allocator.free(dest);
    std.fs.cwd().copyFile(built_backend, std.fs.cwd(), dest, .{}) catch |err| {
        try printStderr(allocator, "error: cannot store minted backend: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    var c = backendHashComponents(allocator, koru_home, resolver, emitted_code) orelse {
        try printStderr(allocator, "error: mint stored but manifest failed — compiler sources unreadable\n", .{});
        std.process.exit(1);
    };
    defer c.deinit(allocator);
    const sha = sha256FileHex(allocator, dest) orelse {
        try printStderr(allocator, "error: mint stored but sha256 failed\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(sha);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, "mint.json" });
    defer allocator.free(manifest_path);
    const mf = std.fs.cwd().createFile(manifest_path, .{}) catch |err| {
        try printStderr(allocator, "error: cannot write manifest: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer mf.close();
    var libs_json = std.ArrayList(u8){};
    defer libs_json.deinit(allocator);
    const lw = libs_json.writer(allocator);
    try lw.writeAll("{");
    for (c.libs, 0..) |lib, i| {
        if (i > 0) try lw.writeAll(",");
        try lw.writeByte('"');
        try writeJsonEscaped(lw, lib.path);
        try lw.writeAll("\":");
        if (lib.key) |k| {
            try lw.print("\"{x}\"", .{k});
        } else {
            try lw.writeAll("\"absent\"");
        }
    }
    try lw.writeAll("}");
    const json = try std.fmt.allocPrint(allocator,
        \\{{"name":"{s}","sha256":"{s}","closure_key":"{x}","src_key":"{x}","libs":{s},"emitted_key":"{x}","iface_key":"{x}","koruc":"{s}","source":"{s}","minted":{d}}}
        \\
    , .{ name, sha, c.combined, c.src, libs_json.items, c.emitted, c.iface, version, source, std.time.timestamp() });
    defer allocator.free(json);
    try mf.writeAll(json);
    try printStdout(allocator, "✓ Minted '{s}' → {s}\n  sha256 {s}\n  pin it: std/compiler:use(\"{s}\", hash: \"{s}\")\n", .{ name, dest, sha, name, sha });
}

/// `koruc <file> mint check <name>` — the audit verb. Recomputes the closure
/// over the live tree and diffs every component against the manifest. Exit 1
/// on any drift or mismatch so `mint check || mint` composes in scripts.
fn runMintCheck(allocator: std.mem.Allocator, koru_home: []const u8, resolver: *ModuleResolver, name: []const u8, emitted_code: []const u8) !void {
    const dir = (try mintDir(allocator, name)) orelse std.process.exit(1);
    defer allocator.free(dir);
    const manifest_parsed = loadMintManifest(allocator, dir) orelse {
        try printStderr(allocator, "error: no mint named '{s}'\n", .{name});
        std.process.exit(1);
    };
    const manifest = manifest_parsed.value;
    defer manifest_parsed.deinit();
    if (manifest != .object) {
        try printStderr(allocator, "error: mint '{s}' manifest is corrupt — delete {s} and re-mint\n", .{ name, dir });
        std.process.exit(1);
    }

    const minted_ts: i64 = if (manifest.object.get("minted")) |v| switch (v) {
        .integer => |i| i,
        else => 0,
    } else 0;
    try printStdout(allocator, "mint {s} (minted {d}, koruc {s}, source {s})\n", .{ name, minted_ts, manifestStr(manifest, "koruc"), manifestStr(manifest, "source") });

    var drift = false;
    var now = backendHashComponents(allocator, koru_home, resolver, emitted_code);
    defer if (now) |*c| c.deinit(allocator);

    const bin = try std.fs.path.join(allocator, &[_][]const u8{ dir, "backend" });
    defer allocator.free(bin);
    if (sha256FileHex(allocator, bin)) |actual| {
        defer allocator.free(actual);
        const ok = std.mem.eql(u8, actual, manifestStr(manifest, "sha256"));
        if (!ok) drift = true;
        try printStdout(allocator, "  binary integrity   {s}\n", .{if (ok) "sha256 match" else "MISMATCH — binary moved since mint"});
    } else {
        drift = true;
        try printStdout(allocator, "  binary integrity   MISSING — {s}\n", .{bin});
    }

    if (now) |c| {
        const rows = [_]struct { label: []const u8, key: []const u8, cur: u64 }{
            .{ .label = "ast/env protocol", .key = "iface_key", .cur = c.iface },
            .{ .label = "core (src/)", .key = "src_key", .cur = c.src },
            .{ .label = "program closure", .key = "emitted_key", .cur = c.emitted },
        };
        for (rows) |row| {
            const cur_hex = try fnvHex(allocator, row.cur);
            defer allocator.free(cur_hex);
            const ok = std.mem.eql(u8, cur_hex, manifestStr(manifest, row.key));
            if (!ok) drift = true;
            try printStdout(allocator, "  {s: <19}{s}\n", .{ row.label, if (ok) "clean" else "DRIFT — tree moved since mint" });
        }

        // Library roots: the union of what the manifest recorded and what the
        // resolver consults now. A root new since the mint, gone since the
        // mint, or flipped between present/absent is drift like any other.
        const libs_val = manifest.object.get("libs");
        if (libs_val == null or libs_val.? != .object) {
            drift = true;
            try printStdout(allocator, "  libraries          manifest predates root enumeration — re-mint\n", .{});
        } else {
            const mlibs = libs_val.?.object;
            for (c.libs) |lib| {
                const cur = if (lib.key) |k|
                    try fnvHex(allocator, k)
                else
                    try allocator.dupe(u8, "absent");
                defer allocator.free(cur);
                const recorded = mlibs.get(lib.path);
                const recorded_str = if (recorded) |v| (if (v == .string) v.string else "") else "";
                if (recorded == null) {
                    drift = true;
                    try printStdout(allocator, "  lib {s}  DRIFT — new root since mint\n", .{lib.path});
                } else if (std.mem.eql(u8, recorded_str, cur)) {
                    try printStdout(allocator, "  lib {s}  clean\n", .{lib.path});
                } else {
                    drift = true;
                    try printStdout(allocator, "  lib {s}  DRIFT — tree moved since mint\n", .{lib.path});
                }
            }
            var miter = mlibs.iterator();
            while (miter.next()) |e| {
                var still_configured = false;
                for (c.libs) |lib| {
                    if (std.mem.eql(u8, lib.path, e.key_ptr.*)) {
                        still_configured = true;
                        break;
                    }
                }
                if (!still_configured) {
                    drift = true;
                    try printStdout(allocator, "  lib {s}  DRIFT — root no longer configured\n", .{e.key_ptr.*});
                }
            }
        }
    } else {
        try printStdout(allocator, "  closure            unmeasurable — compiler sources unreadable\n", .{});
        drift = true;
    }

    try printStdout(allocator, "  verdict            {s}\n", .{if (drift) "stale — re-mint to absorb the drift" else "fresh — mint still represents this tree"});
    if (drift) std.process.exit(1);
}


/// that usually comes from, and what to do. Not for running the USER's own
/// binary: a SIGSEGV there is the program's own crash and must not be
/// blamed on the machine.
fn reportAbnormalTerm(allocator: std.mem.Allocator, what: []const u8, term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| try printStderr(allocator, "✗ {s} failed (exit code {d})\n", .{ what, code }),
        .Signal => |sig| try printStderr(allocator, "✗ {s} was killed by signal {d} ({s}) — ended from outside, before it could finish.\n" ++
            "  This usually means the machine ran out of memory (the OS kills the biggest\n" ++
            "  process under pressure), or something killed it externally. Check memory and\n" ++
            "  load, then rerun the same command. The source program was never judged —\n" ++
            "  there is no compiler diagnostic to fix here.\n", .{ what, sig, signalName(sig) }),
        .Stopped => |sig| try printStderr(allocator, "✗ {s} was stopped by signal {d} and never resumed — resume or kill it, then rerun.\n", .{ what, sig }),
        .Unknown => |status| try printStderr(allocator, "✗ {s} ended in a state the OS did not classify (status {d}) — rerun; if it repeats, the machine is the suspect, not the source program.\n", .{ what, status }),
    }
}

/// Mirror one backend stderr line to our stderr and into the capture buffer —
/// unless it is the coordination echo (`❌ Compiler coordination error:` or
/// its trace hint) following a diagnostic that already streamed. A refusal
/// that told the author something doesn't get the vaguer repeat; a
/// diagnostic-free failure (user coordinator override, internal error)
/// keeps the line because there it IS the message.
fn mirrorBackendLine(
    allocator: std.mem.Allocator,
    raw: []const u8,
    saw_backend_diagnostic: *bool,
    stderr_buf: *std.ArrayList(u8),
    capture_cap: usize,
) void {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    const is_coord_echo = std.mem.startsWith(u8, line, "❌ Compiler coordination error:") or
        std.mem.startsWith(u8, line, "(set KORU_BACKEND_TRACE=1");
    if (saw_backend_diagnostic.* and is_coord_echo) return;
    if (isDiagnosticLine(line)) saw_backend_diagnostic.* = true;
    std.fs.File.stderr().writeAll(raw) catch {};
    if (stderr_buf.items.len < capture_cap) {
        const room = capture_cap - stderr_buf.items.len;
        const take = @min(room, raw.len);
        stderr_buf.appendSlice(allocator, raw[0..take]) catch {};
    }
}

/// Scan a captured stderr buffer for compiler-diagnostic lines (Zig's
/// `path:line:col: error:` / `path:line:col: note:` format, plus Koru's
/// own `error[KORUxxx]:` lines) and re-emit them in a clean summary block.
///
/// Zig's build-system output buries real diagnostics under multi-line
/// build-command echoes ("the following command failed with N compilation
/// errors:" followed by a 30-line zig invocation) and Build Summary
/// noise. The raw output is preserved (we stream it through verbatim),
/// but on failure this summary surfaces just the parts a human cares
/// about so they don't have to fish.
fn emitDiagnosticsSummary(allocator: std.mem.Allocator, captured: []const u8) !void {
    // Count first; only emit the summary block if there's at least one
    // line worth surfacing (otherwise we'd just add more noise).
    var count: usize = 0;
    var noise: usize = 0;
    var line_iter = std.mem.splitScalar(u8, captured, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (isDiagnosticLine(line)) {
            count += 1;
            continue;
        }
        // Diagnostic continuation lines — location arrows, source gutters,
        // hints — are indented. A column-0 line that isn't a diagnostic
        // headline is the noise this summary exists to unbury.
        if (raw_line[0] == ' ' or raw_line[0] == '\t') continue;
        noise += 1;
    }
    if (count == 0) return;
    // A clean refusal: the diagnostics were the only output, so the live
    // mirror already delivered them complete — re-printing would be a second
    // copy of one message.
    if (noise == 0) return;

    try printStderr(allocator, "\n──── diagnostics ({d}) ────\n", .{count});

    line_iter = std.mem.splitScalar(u8, captured, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (isDiagnosticLine(line)) {
            try printStderr(allocator, "{s}\n", .{line});
        }
    }
    try printStderr(allocator, "──────────────────────────\n", .{});
}

/// True for lines that look like compiler diagnostics worth surfacing
/// in the post-failure summary. Currently:
///   - `path:line:col: error: ...`
///   - `path:line:col: note: ...`
///   - `error[KORUxxx]: ...`
fn isDiagnosticLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "error[KORU")) return true;
    // Match `<anything>:<digits>:<digits>: error:` or ...: note:
    // Cheap heuristic: at least two colons before " error:"/" note:".
    if (std.mem.indexOf(u8, line, ": error:")) |_| {
        // Require a colon-digit-colon-digit-colon pattern before " error:".
        return hasFileLineColPrefix(line);
    }
    if (std.mem.indexOf(u8, line, ": note:")) |_| {
        return hasFileLineColPrefix(line);
    }
    return false;
}

fn hasFileLineColPrefix(line: []const u8) bool {
    // Find the FIRST ":" preceded by a non-digit and followed by digits.
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;
        // After this colon, expect: digits, ":", digits, ":"
        var j = i + 1;
        var saw_digit_a = false;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) saw_digit_a = true;
        if (!saw_digit_a or j >= line.len or line[j] != ':') continue;
        j += 1;
        var saw_digit_b = false;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) saw_digit_b = true;
        if (!saw_digit_b or j >= line.len or line[j] != ':') continue;
        return true;
    }
    return false;
}

/// Escape a string for JSON output (quotes, backslashes, control chars).
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, s.len + 2);
    for (s) |c| {
        if (c == '"') {
            try out.appendSlice(allocator, "\\\"");
        } else if (c == '\\') {
            try out.appendSlice(allocator, "\\\\");
        } else if (c == '\n') {
            try out.appendSlice(allocator, "\\n");
        } else if (c == '\r') {
            try out.appendSlice(allocator, "\\r");
        } else if (c == '\t') {
            try out.appendSlice(allocator, "\\t");
        } else if (c < 0x20) {
            const hex = "0123456789abcdef";
            try out.appendSlice(allocator, "\\u00");
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0xF]);
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Generate compiler_env.json — the per-invocation compiler environment
/// (lang, library, flags, env vars, paths) the backend loads at startup.
///
/// Previously this was compiler_env.zig with comptime-baked consts embedded
/// in the backend build (and hashed into the backend cache key), so every
/// flag flip — including the bare `koruc prog` vs `koruc prog run` verb
/// change via the injected `command=` atom — forced a full backend rebuild.
/// As runtime JSON on the same channel as program.ast.json, one backend
/// binary serves every flag combination.
fn generateCompilerEnvJson(
    allocator: std.mem.Allocator,
    config: *const CompilerConfig,
    entry_file: []const u8,
    entry_dir: []const u8,
    project_root: []const u8,
    koru_home: []const u8,
) ![]const u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    const writer = buffer.writer(allocator);

    const esc_lang = try jsonEscape(allocator, config.lang);
    defer allocator.free(esc_lang);
    const esc_entry_file = try jsonEscape(allocator, entry_file);
    defer allocator.free(esc_entry_file);
    const esc_entry_dir = try jsonEscape(allocator, entry_dir);
    defer allocator.free(esc_entry_dir);
    const esc_project_root = try jsonEscape(allocator, project_root);
    defer allocator.free(esc_project_root);
    const esc_koru_home = try jsonEscape(allocator, koru_home);
    defer allocator.free(esc_koru_home);

    try writer.print("{{\"lang\":\"{s}\",\"library\":{s},\"flags\":[", .{
        esc_lang,
        if (config.library) "true" else "false",
    });
    for (config.flags.items, 0..) |flag, i| {
        if (i > 0) try writer.writeAll(",");
        const esc_flag = try jsonEscape(allocator, flag);
        defer allocator.free(esc_flag);
        try writer.print("\"{s}\"", .{esc_flag});
    }
    try writer.writeAll("],");
    try writer.print("\"entry_file\":\"{s}\",\"entry_dir\":\"{s}\",\"project_root\":\"{s}\",\"koru_home\":\"{s}\",\"env\":{{", .{
        esc_entry_file, esc_entry_dir, esc_project_root, esc_koru_home,
    });
    var first_env = true;
    var env_it = config.env_vars.iterator();
    while (env_it.next()) |entry| {
        if (!first_env) try writer.writeAll(",");
        first_env = false;
        const esc_k = try jsonEscape(allocator, entry.key_ptr.*);
        defer allocator.free(esc_k);
        const esc_v = try jsonEscape(allocator, entry.value_ptr.*);
        defer allocator.free(esc_v);
        try writer.print("\"{s}\":\"{s}\"", .{ esc_k, esc_v });
    }
    try writer.writeAll("}}");

    return buffer.toOwnedSlice(allocator);
}

/// Emit one comptime-thunk body step. The `.invocation` arm writes
/// `_ = backend_output.<path>_event.handler(.{ … })` with every arg value
/// quoted — thunk args are AST data, not runtime expressions. `indent` is
/// the continuation-depth prefix written first.
fn emitThunkStep(writer: anytype, step: anytype, module_alias_map: *const std.StringHashMap([]const u8), indent: []const u8) !void {
    try writer.writeAll(indent);
    switch (step) {
        .invocation => |inv| {
            // Call the handler from backend_output
            try writer.writeAll("_ = ");
            if (inv.path.module_qualifier) |mq| {
                // Module-qualified event: backend_output.koru_<module>.<event>_event
                try writer.writeAll("backend_output.koru_");
                if (module_alias_map.get(mq)) |full_path| {
                    try writer.writeAll(full_path);
                } else {
                    try writer.writeAll(mq);
                }
                try writer.writeAll(".");
                for (inv.path.segments, 0..) |seg, i| {
                    if (i > 0) try writer.writeAll("_");
                    try writer.writeAll(seg);
                }
            } else {
                // Local event: backend_output.main_module.<event>_event
                try writer.writeAll("backend_output.main_module.");
                for (inv.path.segments, 0..) |seg, i| {
                    if (i > 0) try writer.writeAll("_");
                    try writer.writeAll(seg);
                }
            }
            try writer.writeAll("_event.handler(.{");
            // For now, use a simple heuristic: if arg.name starts with quote, it's positional
            // and we use "text" as the field name (works for println, print, etc.)
            for (inv.args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(" .");
                // Check if this is a positional argument (name starts with quote or is the value)
                if (arg.name.len > 0 and (arg.name[0] == '"' or (!arg.had_explicit_label and std.mem.eql(u8, arg.name, arg.value)))) {
                    // Positional argument - use "text" as field name for now
                    try writer.writeAll("text");
                } else {
                    try writer.writeAll(arg.name);
                }
                try writer.writeAll(" = ");
                // Always quote nested invocation args in comptime thunks.
                // These are AST data, not runtime expressions.
                const text_to_quote = if (arg.source_value) |sv| sv.text else arg.value;
                try writer.writeAll("\"");
                for (text_to_quote) |c| {
                    switch (c) {
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        '\\' => try writer.writeAll("\\\\"),
                        '"' => try writer.writeAll("\\\""),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeAll("\"");
            }
            try writer.writeAll(" });\n");
        },
        .terminal => {},
        else => {
            try writer.writeAll("// TODO: Handle step type\n");
        },
    }
}

/// Generate the backend code that will perform code generation at compile-time
/// This is Pass 2 of the Koru compiler - the Zig backend
// Frontend mirror of the backend's diagnostic-join matcher (the emitted
// backend re-derives it on the deserialized AST — ast.zig is shared, so the
// two walks can't drift on field names, only on intent). Decides whether a
// builtin sink's code + link dep get emitted at all: a `sqlite` arm pulls
// extern sqlite3_* decls and linkSystemLibrary("sqlite3"), and neither may be
// unconditional — a backend that always links sqlite3 is a hard dep.
fn isDiagJoinInvocationFrontend(inv: *const ast.Invocation) bool {
    const p = &inv.path;
    const on_door = if (p.module_qualifier) |mq|
        (std.mem.eql(u8, mq, "std/compiler") or std.mem.eql(u8, mq, "std.compiler")) and
            p.segments.len == 1 and std.mem.eql(u8, p.segments[0], "default")
    else
        p.segments.len == 1 and (std.mem.eql(u8, p.segments[0], "std/compiler") or
            std.mem.eql(u8, p.segments[0], "std.compiler"));
    if (!on_door) return false;
    return inv.args.len > 0 and std.mem.eql(u8, inv.args[0].value, "diagnostic");
}

fn itemsWantDiagSink(items: []const ast.Item, want: []const u8) bool {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                var is_join = false;
                if (f.body.node) |*n| {
                    if (n.* == .invocation and isDiagJoinInvocationFrontend(&n.invocation)) is_join = true;
                }
                if (!is_join) continue;
                for (f.body.continuations) |*cont| {
                    const step = cont.node orelse continue;
                    if (step != .invocation) continue;
                    const segs = step.invocation.path.segments;
                    if (segs.len > 0 and std.mem.eql(u8, segs[segs.len - 1], want)) return true;
                }
            },
            .module_decl => |*md| {
                if (itemsWantDiagSink(md.items, want)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn programWantsDiagSink(prog: *const ast.Program, want: []const u8) bool {
    return itemsWantDiagSink(prog.items, want);
}

fn generateBackendCode(allocator: std.mem.Allocator, input_file: []const u8, source_file: *ast.Program, use_visitor: bool, config: *const CompilerConfig, has_transforms: bool) ![]const u8 {
    _ = input_file; // The per-user filename used to land in the header comment.
    // Dropping it keeps backend.zig byte-identical across user programs so
    // Zig's content-addressed cache hits across compiles. Per-user identity
    // lives in program_ast.zig, which IS unique per program.

    var buffer = try std.ArrayList(u8).initCapacity(allocator, 16 * 1024);
    const writer = buffer.writer(allocator);

    // Header
    try writer.writeAll("// Koru Backend (Pass 2) — thin driver; PROGRAM_AST lives in program_ast.zig\n");
    try writer.writeAll("// This file IS the compiler backend - it generates final code at compile-time\n\n");

    // The program AST is no longer baked into this binary as a `pub const`.
    // It is read from `program.ast.json` at runtime (see main()) and deserialized
    // onto the compile arena via the reflective ast_json round-trip. That makes
    // this backend binary reusable across any program with the same handler set,
    // and the seed AST lands on writable heap by construction — so the old
    // rodata-SIGSEGV / heap-clone dance is gone. `Program` comes straight from
    // the `ast` module; `ast_json` provides the deserializer.
    try writer.writeAll("const Program = @import(\"ast\").Program;\n");
    try writer.writeAll("const ast_json_mod = @import(\"ast_json\");\n");
    // The seed AST and every transform output live on the compile arena, which
    // reclaims them wholesale at teardown — nothing to free per-AST. Kept as a
    // no-op so the existing `defer maybeDeinitAst(...)` call sites are untouched.
    try writer.writeAll("fn maybeDeinitAst(_: *const Program) void {}\n\n");

    // Import emitter_helpers at top level so build:config can be queried during compilation
    try writer.writeAll("const emitter_helpers = @import(\"emitter_helpers\");\n");
    // Standard library import — namespaced to avoid shadowing struct-scoped 'std' in modules
    try writer.writeAll("const __koru_std = @import(\"std\");\n");
    // Log module for conditional debug output
    try writer.writeAll("const log = @import(\"log\");\n\n");

    // CompilerEnv lives in the static src/compiler_env.zig module (runtime
    // state loaded from compiler_env.json at backend startup).
    // Re-exported as pub so @import("root").CompilerEnv keeps working for code in src/
    // and in backend_output_emitted.zig that still reaches it through root.
    try writer.writeAll("// Compiler environment lives in the static compiler_env module — re-exported here so\n");
    try writer.writeAll("// `@import(\"root\").CompilerEnv` keeps working for existing consumers.\n");
    try writer.writeAll("pub const CompilerEnv = @import(\"compiler_env\").CompilerEnv;\n\n");
    // `config` is now used below to pass the default lang to the visitor backend.
    // (Most of CompilerConfig still lives in the compiler_env module — only .lang is read here.)

    // NOTE: Transform handlers are now generated into backend_output_emitted.zig
    // See generateComptimeBackendEmitted() for the call to generateTransformHandlersToEmitter()

    // Choose which backend implementation to use
    if (use_visitor) {
        // Use the new visitor pattern implementation
        try writer.writeAll("// Using Visitor Pattern Backend\n\n");
        try generateVisitorBackend(writer, allocator, source_file, config.lang);
    } else {
        // Use the old implementation
        try writer.writeAll("// Metacircular Code Generator\n\n");

        // Import ast for type access in extern fn signatures.
        // (ast_functional + emit_build_zig were unused dead imports — dropped.)
        // backend_output_emitted.zig is a MODULE of the SAME exe compilation now
        // (one std). backend.zig still calls its handlers through the C-ABI
        // extern-fn bridge below, but we force the module into the compilation so
        // its `pub export fn` wrappers are emitted (otherwise dead-stripped →
        // "undefined symbol: koru_coordinate"). One compilation = one std = one
        // os.environ — fixes the dual-std segfault in getenv on Linux (no-libc).
        try writer.writeAll("const __koru_ast = @import(\"ast\");\n");
        try writer.writeAll("comptime { _ = @import(\"backend_output\"); }\n\n");

        // Extern wrappers — backend_output_emitted.zig exports these as
        // `pub export fn`. C-ABI flat extern struct because Zig 0.15 won't let
        // extern fn carry Zig-native unions/slices. Both sides must declare
        // structurally-identical types; the wrapper translates back to Zig-native
        // before invoking the real handler.
        try writer.writeAll(
            \\const KoruCoordinateResult = extern struct {
            \\    is_error: bool,
            \\    code_ptr: [*]const u8,
            \\    code_len: usize,
            \\    metrics_ptr: [*]const u8,
            \\    metrics_len: usize,
            \\    error_ptr: [*]const u8,
            \\    error_len: usize,
            \\};
            \\extern fn koru_coordinate(
            \\    program_ast: *const __koru_ast.Program,
            \\    allocator: *const __koru_std.mem.Allocator,
            \\) KoruCoordinateResult;
            \\
            \\extern fn koru_command_dispatch(
            \\    name: *const anyopaque, // *const []const u8
            \\    program: *const __koru_ast.Program,
            \\    allocator: *const __koru_std.mem.Allocator,
            \\    argv: *const anyopaque, // *const []const []const u8 (Zig slice; cast on the other side)
            \\) void;
            \\
            \\extern fn koru_run_pass(
            \\    annotation: *const anyopaque, // *const []const u8
            \\    program: *const __koru_ast.Program,
            \\    allocator: *const __koru_std.mem.Allocator,
            \\    out_program: *?*const __koru_ast.Program,
            \\    ctx: ?*anyopaque, // *CompilerContext, opaque across the unit boundary
            \\) bool;
            \\
            \\
        );

        // Note: comptime_main() is now called from compiler.passes.evaluate_comptime
        // It executes at Zig runtime (when ./backend runs), not Zig comptime

        // Re-export transform dispatcher via @import("root") so the
        // evaluate_comptime pass can call Root.process_all_transforms(). The
        // body forwards to the koru_run_pass extern wrapper exported by
        // backend_output_emitted.zig.
        if (has_transforms) {
            try writer.writeAll(
                \\// Re-export transform dispatcher — Zig-side shim around the extern wrapper
                \\// so existing callers in src/ see an unchanged calling convention.
                \\pub fn process_all_transforms(
                \\    annotation: []const u8,
                \\    program: *const __koru_ast.Program,
                \\    allocator: __koru_std.mem.Allocator,
                \\    ctx: ?*anyopaque,
                \\) !*const __koru_ast.Program {
                \\    var out_program: ?*const __koru_ast.Program = null;
                \\    const ok = koru_run_pass(@ptrCast(&annotation), program, &allocator, &out_program, ctx);
                \\    if (!ok) return error.TransformFailed;
                \\    return out_program orelse return error.TransformFailed;
                \\}
                \\
                \\
            );
        }

        // Note: emitter_lib, visitor_emitter_lib, and tap_registry_module are imported inside compiler.emit.zig proc

        // NO MANUAL RECONSTRUCTION NEEDED!
        //
        // The visitor emitter already emitted ALL handlers to backend_output_emitted.zig,
        // including the user's compiler.coordinate override (if any).
        //
        // Backend.zig will import backend_output_emitted.zig and call the handlers from there.
        //
        // This eliminates:
        //   - Manual string construction bugs
        //   - Keyword escaping issues (error vs @"error")
        //   - Code duplication between visitor emitter and manual reconstruction
        //
        // The compiler is now FULLY metacircular - all code emission goes through
        // the same visitor emitter that emits user code!

        // All checker passes now come from compiler.kz (imported via backend_output)

        // Emit helper functions needed by comptime handlers
        try writer.writeAll(
            \\// Helper: Join path segments with dots
            \\const joinPath = struct {
            \\    fn call(path: []const []const u8) []const u8 {
            \\        if (path.len == 0) return "";
            \\        if (path.len == 1) return path[0];
            \\        var total_len: usize = path[0].len;
            \\        var i: usize = 1;
            \\        while (i < path.len) : (i += 1) {
            \\            total_len += 1 + path[i].len;
            \\        }
            \\        var result: [256]u8 = undefined;
            \\        var pos: usize = 0;
            \\        @memcpy(result[pos..pos + path[0].len], path[0]);
            \\        pos += path[0].len;
            \\        i = 1;
            \\        while (i < path.len) : (i += 1) {
            \\            result[pos] = '.';
            \\            pos += 1;
            \\            @memcpy(result[pos..pos + path[i].len], path[i]);
            \\            pos += path[i].len;
            \\        }
            \\        return result[0..pos];
            \\    }
            \\}.call;
            \\
            \\
        );

        // ============================================================================
        // COMPTIME FLOW THUNKS - Enable branch handlers for comptime events
        // ============================================================================
        // Comptime flows (flows invoking events with Source/Program params)
        // exist in TWO forms:
        //   1. AST (data) - serialized in PROGRAM_AST for compiler passes to analyze
        //   2. Thunks (executable) - emitted here so branch handlers can execute
        //
        // This enables:
        //   - Multiple ~build:requires calls (each gets own thunk)
        //   - Branch handlers work (they're executable code, not data)
        //   - Compiler passes can call executeComptimeFlowThunk(ast_index)
        // ============================================================================

        // Step 1: Build map of comptime event names
        // NOTE: Events with Source/Program parameters are [comptime|transform] events
        // Flows invoking them should be transformed at runtime, NOT executed as comptime thunks
        // For now, we SKIP these from comptime thunk generation (user guidance: postpone top-level comptime flows)
        var comptime_event_names = try std.ArrayList([]const u8).initCapacity(allocator, 16);
        defer comptime_event_names.deinit(allocator);

        // Step 2: Find comptime flows
        // NOTE: Transform events ([comptime|transform]) are handled entirely by
        // the transform pass runner at Zig comptime — they don't need thunks.
        const ComptimeFlowInfo = struct {
            ast_index: usize,
            flow: *const ast.Flow,
        };
        var comptime_flows = try std.ArrayList(ComptimeFlowInfo).initCapacity(allocator, 16);
        defer comptime_flows.deinit(allocator);

        for (source_file.items, 0..) |*item, idx| {
            if (item.* == .flow) {
                const flow = &item.flow;

                // Build invoked event name
                var inv_name_buf: [256]u8 = undefined;
                const inv_name_len = flow.inv().path.writeQualified(&inv_name_buf, 0);
                const inv_name = inv_name_buf[0..inv_name_len];

                for (comptime_event_names.items) |comptime_name| {
                    if (std.mem.eql(u8, inv_name, comptime_name)) {
                        log.debug("  [MATCH] Flow '{s}' (idx={}) matches comptime event '{s}'\n", .{ inv_name, idx, comptime_name });
                        try comptime_flows.append(allocator, .{
                            .ast_index = idx,
                            .flow = flow,
                        });
                        log.debug("    → Appended to comptime_flows, now {} items\n", .{comptime_flows.items.len});
                        break;
                    }
                }
            }

            // Also check flows in imported modules (though typically flows are top-level)
            if (item.* == .module_decl) {
                const module = item.module_decl;
                for (module.items) |*mod_item| {
                    if (mod_item.* == .flow) {
                        const flow = &mod_item.flow;

                        // Build invoked event name
                        var inv_name_buf: [256]u8 = undefined;
                        const inv_name_len = flow.inv().path.writeQualified(&inv_name_buf, 0);
                        const inv_name = inv_name_buf[0..inv_name_len];

                        for (comptime_event_names.items) |comptime_name| {
                            if (std.mem.eql(u8, inv_name, comptime_name)) {
                                log.debug("  [MATCH-MODULE] Flow '{s}' in module matches comptime event '{s}'\n", .{ inv_name, comptime_name });
                                try comptime_flows.append(allocator, .{
                                    .ast_index = idx,
                                    .flow = flow,
                                });
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Debug: Print detected comptime flows
        if (comptime_flows.items.len > 0) {
            log.debug("\n=== COMPTIME FLOW DETECTION ===\n", .{});
            for (comptime_flows.items) |flow_info| {
                const flow = flow_info.flow;
                // Build invocation name for display
                var inv_name_buf: [256]u8 = undefined;
                const inv_name_len = flow.inv().path.writeQualified(&inv_name_buf, 0);
                const inv_name = inv_name_buf[0..inv_name_len];
                log.debug("  Detected comptime flow: {s} (ast_index={})\n", .{ inv_name, flow_info.ast_index });
            }
            log.debug("===============================\n\n", .{});
        }

        // Build a map of module aliases to full module paths
        // This is needed to resolve handler names in thunks
        // e.g. flow says "build:requires" but handler is "std_build_requires_handler"
        var module_alias_map = std.StringHashMap([]const u8).init(allocator);
        defer module_alias_map.deinit();

        for (source_file.items) |item| {
            if (item == .module_decl) {
                const module = item.module_decl;
                // Extract last segment of logical_name as the alias
                // "std.build" → alias "build"
                if (std.mem.lastIndexOf(u8, module.logical_name, ".")) |dot_idx| {
                    const alias = module.logical_name[dot_idx + 1 ..];
                    try module_alias_map.put(alias, module.logical_name);
                } else {
                    // No dot, use whole name
                    try module_alias_map.put(module.logical_name, module.logical_name);
                }
            }
        }

        // Step 3: Emit thunks, mapping, and helper (only if we found comptime flows)
        if (comptime_flows.items.len > 0) {
            try writer.writeAll(
                \\// Comptime flow thunks - executable functions for comptime flows
                \\const comptime_flow_thunks = struct {
                \\
            );

            for (comptime_flows.items, 0..) |info, thunk_idx| {
                const flow = info.flow;

                try writer.writeAll("    fn flow_");
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{thunk_idx});
                try writer.writeAll(num_str);
                try writer.writeAll("() void {\n");

                // Call handler from backend_output with full module path
                // Use __thunk_result to avoid shadowing user bindings like |result|
                try writer.writeAll("        const __thunk_result = ");
                if (flow.inv().path.module_qualifier) |mq| {
                    // Module-qualified event: backend_output.koru_<module>.<event>_event
                    try writer.writeAll("backend_output.koru_");
                    // Resolve alias to full module path
                    if (module_alias_map.get(mq)) |full_path| {
                        try writer.writeAll(full_path);
                    } else {
                        try writer.writeAll(mq);
                    }
                    try writer.writeAll(".");
                    for (flow.inv().path.segments, 0..) |seg, i| {
                        if (i > 0) try writer.writeAll("_");
                        try writer.writeAll(seg);
                    }
                } else {
                    // Local event: backend_output.main_module.<event>_event
                    try writer.writeAll("backend_output.main_module.");
                    for (flow.inv().path.segments, 0..) |seg, i| {
                        if (i > 0) try writer.writeAll("_");
                        try writer.writeAll(seg);
                    }
                }
                try writer.writeAll("_event.handler(.{");

                for (flow.inv().args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(" .");
                    try writer.writeAll(arg.name);
                    try writer.writeAll(" = ");

                    // Always quote and escape Source parameter values
                    // Anonymous block content is raw text that needs escaping
                    try writer.writeAll("\"");
                    for (arg.value) |c| {
                        switch (c) {
                            '\n' => try writer.writeAll("\\n"),
                            '\r' => try writer.writeAll("\\r"),
                            '\t' => try writer.writeAll("\\t"),
                            '\\' => try writer.writeAll("\\\\"),
                            '"' => try writer.writeAll("\\\""),
                            else => try writer.writeByte(c),
                        }
                    }
                    try writer.writeAll("\"");
                }

                try writer.writeAll(" });\n");
                const has_void_continuation = flow.body.continuations.len == 1 and flow.body.continuations[0].branch.len == 0;
                if (has_void_continuation) {
                    const cont = flow.body.continuations[0];
                    try writer.writeAll("        _ = &__thunk_result;\n");
                    if (cont.node) |step| {
                        try emitThunkStep(writer, step, &module_alias_map, "        ");
                    }
                } else {
                    try writer.writeAll("        switch (__thunk_result) {\n");

                    for (flow.body.continuations) |cont| {
                        try writer.writeAll("            .");
                        try writeBranchName(writer, cont.branch);
                        try writer.writeAll(" => ");

                        if (cont.binding) |binding| {
                            try writer.writeAll("|");
                            try writer.writeAll(binding);
                            try writer.writeAll("| ");
                        }

                        try writer.writeAll("{\n");

                        // Suppress unused binding warning
                        // Skip for "_" since that's a discard and can't be referenced
                        if (cont.binding) |binding| {
                            if (!std.mem.eql(u8, binding, "_")) {
                                try writer.writeAll("                _ = &");
                                try writer.writeAll(binding);
                                try writer.writeAll(";\n");
                            }
                        }

                        if (cont.node) |step| {
                            try emitThunkStep(writer, step, &module_alias_map, "                ");
                        }

                        try writer.writeAll("            },\n");
                    }

                    try writer.writeAll("        }\n");
                }
                try writer.writeAll("    }\n\n");
            }

            try writer.writeAll(
                \\};
                \\
                \\const comptime_flow_mapping = &[_]struct {
                \\    ast_index: usize,
                \\    executor: *const fn() void,
                \\}{
                \\
            );

            for (comptime_flows.items, 0..) |info, thunk_idx| {
                try writer.writeAll("    .{ .ast_index = ");
                var idx_buf: [32]u8 = undefined;
                const idx_str = try std.fmt.bufPrint(&idx_buf, "{d}", .{info.ast_index});
                try writer.writeAll(idx_str);
                try writer.writeAll(", .executor = &comptime_flow_thunks.flow_");
                var num_buf: [32]u8 = undefined;
                const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{thunk_idx});
                try writer.writeAll(num_str);
                try writer.writeAll(" },\n");
            }

            try writer.writeAll(
                \\};
                \\
                \\
            );
        }

        // Find the compiler module's logical name
        // CRITICAL: The compiler module MUST be present for backend generation to work
        // If it's not found, something is seriously wrong (import failed, not injected, etc.)
        var compiler_module_name: ?[]const u8 = null;
        for (source_file.items) |item| {
            if (item == .module_decl) {
                const module = item.module_decl;
                // Look for the module containing compiler events
                // It should have canonical_path containing "compiler.kz"
                if (std.mem.indexOf(u8, module.canonical_path, "compiler.kz") != null) {
                    compiler_module_name = module.logical_name;
                    break;
                }
            }
        }

        // NO FALLBACK - if compiler module not found, FAIL LOUDLY
        if (compiler_module_name == null) {
            log.err("\n✗✗✗ FATAL: Compiler module not found in source_file.items ✗✗✗\n", .{});
            log.err("Backend generation requires the compiler module to be imported.\n", .{});
            log.err("This should have been auto-injected during parsing.\n", .{});
            return error.CompilerModuleNotFound;
        }

        const compiler_module = compiler_module_name.?; // Safe unwrap - we just checked

        // ============================================================================
        // FRONTEND BOOTSTRAP COORDINATOR (Hardcoded Zig Fallback)
        //
        // This is the FRONTEND compiler coordinator used during `zig build-exe backend.zig`.
        // It's hardcoded in Zig because it runs at Zig compile-time to bootstrap the compiler,
        // before any Koru runtime exists.
        //
        // IMPORTANT: The BACKEND coordinator (used by compiled programs) IS implemented as
        // Koru flows in koru_std/compiler.kz and emitted to backend_output_emitted.zig!
        // See RuntimeEmitter.emit() at lines 1140-1143 for where it calls the Koru flows.
        //
        // Two stages:
        //   FRONTEND (this code): Compiles compiler.kz → backend.zig (hardcoded Zig)
        //   BACKEND (Koru flows): Compiles user code using flows from compiler.kz
        //
        // To modify the FRONTEND bootstrap, edit this function.
        // To modify the BACKEND compiler, edit koru_std/compiler.kz (those are actual Koru flows!)
        //
        // Pipeline passes (in order):
        //   1. process_ccp_commands  - Reads AI commands from stdin (when --ccp enabled)
        //   2. evaluate_comptime     - Executes comptime events to transform AST
        //   3. check.structure       - Validates event/branch shapes exist
        //   4. check.phantom.semantic - Validates phantom type compatibility
        //   5. inject_ccp            - Adds observability taps (when --ccp + import)
        //   6. emit.zig              - Generates final Zig code
        // ============================================================================
        // The compiler pipeline is now fully flow-based in koru_std/compiler.kz
        // The coordinate event (abstract) handles both default and user-overridden pipelines
        // via cross-module subflow overrides - no special detection needed!
        // ============================================================================

        // Runtime emitter — calls the coordinate event through the C-ABI
        // extern wrapper (`koru_coordinate`) exported by backend_output_emitted.zig.
        // The C-ABI shape lives only at the boundary; we rehydrate slices on this side.
        try writer.writeAll(
            \\// Runtime emitter - calls the coordinate event from compiler.kz
            \\// The visitor emitter handles abstract/impl resolution automatically
            \\const RuntimeEmitter = struct {
            \\    pub fn emit(allocator: __koru_std.mem.Allocator, source_ast: *const Program) ![]const u8 {
            \\        const result = koru_coordinate(source_ast, &allocator);
            \\        if (result.is_error) {
            \\            const e = result.error_ptr[0..result.error_len];
            \\            // A REFUSAL IS NOT A CRASH. The coordinate flow has already reported its
            \\            // diagnostic through the reporter by the time we reach here, so returning
            \\            // an error out of main would make Zig print `error.CompilerCoordinationFailed`
            \\            // plus a return trace naming THIS generated file — a crash report stapled to
            \\            // a correct rejection, and the last thing the author reads. Exit
            \\            // deliberately instead: the status is still non-zero, so koruc's
            \\            // non-zero-exit path still runs the diagnostics summary and still
            \\            // reports the failure. Nothing is swallowed; one misleading rendering of an
            \\            // already-delivered diagnostic is dropped.
            \\            //
            \\            // The coordination echo itself is gated the same way: when the reporter
            \\            // already rendered a diagnostic (`errors.diagnostics_were_printed`), the
            \\            // error-string summary is a vaguer, location-free repeat of it — one
            \\            // refusal, one message. When NO diagnostic was rendered the print stays:
            \\            // a user-authored coordinator override's error string or a
            \\            // diagnostic-free internal failure IS the message.
            \\            const reporter_spoke = @import("errors").diagnostics_were_printed;
            \\            if (!reporter_spoke) {
            \\                __koru_std.debug.print("❌ Compiler coordination error: {s}\n", .{e});
            \\            }
            \\            // The trace stays REACHABLE on request, because for a genuine INTERNAL
            \\            // failure it is the useful output, and suppressing it unconditionally would
            \\            // trade this bug for its mirror — a compiler crash reported as a rejection,
            \\            // which sends the author hunting through correct code. `is_error` is one
            \\            // boolean carrying both meanings, so the choice belongs to whoever is
            \\            // debugging rather than being guessed at here. A kind on the C-ABI result
            \\            // would let the compiler decide for itself; that is the honest version and
            \\            // it is not this change.
            \\            const trace_requested: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_BACKEND_TRACE") catch null;
            \\            defer if (trace_requested) |v| allocator.free(v);
            \\            if (trace_requested != null) return error.CompilerCoordinationFailed;
            \\            if (!reporter_spoke) {
            \\                __koru_std.debug.print("   (set KORU_BACKEND_TRACE=1 for the backend return trace)\n", .{});
            \\            }
            \\            __koru_std.process.exit(1);
            \\        }
            \\        const metrics = result.metrics_ptr[0..result.metrics_len];
            \\        const code = result.code_ptr[0..result.code_len];
            \\        __koru_std.debug.print("🎯 Compiler coordination: {s}\n", .{metrics});
            \\        return code;
            \\    }
            \\};
            \\
        );
        _ = compiler_module;

        // AST dump helper for observability during development (backend.zig version - no JSON)
        try writer.writeAll(
            \\// AST Dump Helper - observability for compiler pipeline debugging
            \\// Note: This version doesn't serialize to JSON (ast_serializer not available in backend.zig)
            \\// Full JSON dumps are available in backend_output_emitted.zig (dump points 3-7)
            \\fn dumpAST(program_ast: *const Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
            \\    // Check if AST dumping is enabled via environment variable
            \\    const dump_enabled: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
            \\        if (err == error.EnvironmentVariableNotFound) break :blk null;
            \\        break :blk null;
            \\    };
            \\    defer if (dump_enabled) |val| allocator.free(val);
            \\
            \\    if (dump_enabled == null) return;  // Not enabled
            \\
            \\    __koru_std.debug.print("\n============================================================\n", .{});
            \\    __koru_std.debug.print("AST DUMP: {s}\n", .{stage});
            \\    __koru_std.debug.print("============================================================\n", .{});
            \\    __koru_std.debug.print("Items: {d}\n", .{program_ast.items.len});
            \\    __koru_std.debug.print("Module: {s}\n", .{program_ast.main_module_name});
            \\    __koru_std.debug.print("============================================================\n\n", .{});
            \\}
            \\
        );

        // Compile memory budget (KORU174). The compile arena AND every pass
        // allocator flow through this wrapper; the GPA's
        // requested_memory_limit is the hard ceiling behind it. On the first
        // refused allocation the compiler names the budget and the escape
        // hatch and exits(1). Exit-over-panic is deliberate: the generated
        // pipeline's `catch unreachable` sites would turn a refusal into
        // "reached unreachable code", and the refusal IS the result — the
        // source program was never judged, no cleanup can change that, and
        // the OS must never be the one to enforce the ceiling (the old
        // failure mode: the backend ballooned until the kernel SIGKILLed it).
        try writer.writeAll(
            \\var koru_budget_mb: usize = 4096;
            \\var koru_budget_fired: bool = false;
            \\
            \\const BudgetAllocator = struct {
            \\    child: __koru_std.mem.Allocator,
            \\
            \\    fn alloc(ctx: *anyopaque, len: usize, alignment: __koru_std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            \\        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
            \\        const result = self.child.rawAlloc(len, alignment, ret_addr);
            \\        if (result == null and !koru_budget_fired) {
            \\            koru_budget_fired = true;
            \\            __koru_std.debug.print("error[KORU174]: compilation exceeded its compile memory budget ({d} MB) — the compiler refused; nothing was miscompiled and nothing ran. Raise the budget with --compile-mem-mb=<mb> or KORU_COMPILE_MEM_MB.\n", .{koru_budget_mb});
            \\            __koru_std.process.exit(1);
            \\        }
            \\        return result;
            \\    }
            \\
            \\    fn resize(ctx: *anyopaque, memory: []u8, alignment: __koru_std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            \\        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
            \\        return self.child.rawResize(memory, alignment, new_len, ret_addr);
            \\    }
            \\
            \\    fn remap(ctx: *anyopaque, memory: []u8, alignment: __koru_std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            \\        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
            \\        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
            \\    }
            \\
            \\    fn free(ctx: *anyopaque, memory: []u8, alignment: __koru_std.mem.Alignment, ret_addr: usize) void {
            \\        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
            \\        self.child.rawFree(memory, alignment, ret_addr);
            \\    }
            \\
            \\    fn allocator(self: *BudgetAllocator) __koru_std.mem.Allocator {
            \\        return .{ .ptr = self, .vtable = &__koru_std.mem.Allocator.VTable{
            \\            .alloc = alloc,
            \\            .resize = resize,
            \\            .remap = remap,
            \\            .free = free,
            \\        } };
            \\    }
            \\};
            \\
        );

        // Backend main() function - now calls emit at runtime
        try writer.writeAll("// === KORU BACKEND CODE GENERATOR ===\n");
        try writer.writeAll("// This outputs the final Zig code generated by compiler.emit.zig\n\n");


        // Diagnostics bus: `std/compiler(diagnostic)` joins are compile-time
        // consumers of the compiler's own diagnostic stream — not program code.
        // collectDiagJoins walks the seed AST, resolves each `!` arm against the
        // builtin sink registry, registers the sinks with the reporter's
        // process-global dispatch, and strips the join flows so coordinate never
        // sees them (same "compiled away" lifecycle as a tap decl). No arms, no
        // bus: the sink list stays empty and stderr remains the only output.
        const wants_sqlite = programWantsDiagSink(source_file, "sqlite");
        try writer.writeAll(
            \\const errors_mod = @import("errors");
            \\
            \\const DiagJsonlSink = struct {
            \\    file: __koru_std.fs.File,
            \\    allocator: __koru_std.mem.Allocator,
            \\
            \\    fn emit(ctx: *anyopaque, err: *const errors_mod.ParseError) void {
            \\        const self: *DiagJsonlSink = @ptrCast(@alignCast(ctx));
            \\        var line = __koru_std.ArrayList(u8){};
            \\        line.appendSlice(self.allocator, "{\"code\":\"") catch return;
            \\        line.appendSlice(self.allocator, @tagName(err.code)) catch return;
            \\        line.appendSlice(self.allocator, "\",\"file\":\"") catch return;
            \\        diagJsonEscape(&line, self.allocator, err.location.file);
            \\        const loc_num = __koru_std.fmt.allocPrint(self.allocator, "\",\"line\":{d},\"column\":{d},\"message\":\"", .{ err.location.line, err.location.column }) catch return;
            \\        line.appendSlice(self.allocator, loc_num) catch return;
            \\        diagJsonEscape(&line, self.allocator, err.message);
            \\        line.append(self.allocator, '"') catch return;
            \\        if (err.hint) |h| {
            \\            line.appendSlice(self.allocator, ",\"hint\":\"") catch return;
            \\            diagJsonEscape(&line, self.allocator, h);
            \\            line.append(self.allocator, '"') catch return;
            \\        }
            \\        line.append(self.allocator, '}') catch return;
            \\        line.append(self.allocator, '\n') catch return;
            \\        self.file.writeAll(line.items) catch {};
            \\    }
            \\};
            \\
            \\fn diagJsonEscape(out: *__koru_std.ArrayList(u8), alloc: __koru_std.mem.Allocator, s: []const u8) void {
            \\    for (s) |c| {
            \\        switch (c) {
            \\            '"' => out.appendSlice(alloc, "\\\"") catch return,
            \\            '\\' => out.appendSlice(alloc, "\\\\") catch return,
            \\            '\n' => out.appendSlice(alloc, "\\n") catch return,
            \\            '\r' => out.appendSlice(alloc, "\\r") catch return,
            \\            '\t' => out.appendSlice(alloc, "\\t") catch return,
            \\            else => {
            \\                if (c < 0x20) {
            \\                    const esc = __koru_std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c}) catch return;
            \\                    out.appendSlice(alloc, esc) catch return;
            \\                } else {
            \\                    out.append(alloc, c) catch return;
            \\                }
            \\            },
            \\        }
            \\    }
            \\}
            \\
            \\// `std/compiler(diagnostic)` parses as a bare invocation on the
            \\// std/compiler default door — segments ["std/compiler"] (or the
            \\// qualified "std/compiler"/"std.compiler" + ["default"] spelling),
            \\// first arg the literal word `diagnostic`.
            \\fn isDiagJoinInvocation(inv: *const __koru_ast.Invocation) bool {
            \\    const p = &inv.path;
            \\    const on_door = if (p.module_qualifier) |mq|
            \\        (__koru_std.mem.eql(u8, mq, "std/compiler") or __koru_std.mem.eql(u8, mq, "std.compiler")) and
            \\            p.segments.len == 1 and __koru_std.mem.eql(u8, p.segments[0], "default")
            \\    else
            \\        p.segments.len == 1 and (__koru_std.mem.eql(u8, p.segments[0], "std/compiler") or
            \\            __koru_std.mem.eql(u8, p.segments[0], "std.compiler"));
            \\    if (!on_door) return false;
            \\    return inv.args.len > 0 and __koru_std.mem.eql(u8, inv.args[0].value, "diagnostic");
            \\}
            \\
            \\fn diagArmSinkName(inv: *const __koru_ast.Invocation) []const u8 {
            \\    if (inv.path.segments.len == 0) return "";
            \\    return inv.path.segments[inv.path.segments.len - 1];
            \\}
            \\
            \\fn diagArgText(args: []const __koru_ast.Arg, want: []const u8) ?[]const u8 {
            \\    for (args) |a| {
            \\        if (__koru_std.mem.eql(u8, a.name, want)) {
            \\            var v = a.value;
            \\            if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
            \\            return v;
            \\        }
            \\    }
            \\    return null;
            \\}
            \\
            \\// `X:config { k: v }` — a module-targeted directive block, same family
            \\// as `compiler:use` and `x:new`. The braces arrive as verbatim
            \\// source in a `source` arg; the plugin owns the grammar inside —
            \\// `key: literal` entries separated by newline or `,`. The pass
            \\// claims the flow only when X's module actually carries a
            \\// `std/compiler(diagnostic)` join; any other `X:config` stays in
            \\// the tree and coordinate refuses it, so config on a non-plugin
            \\// module is a compile error, not a silent no-op.
            \\const DiagConfigEntry = struct { key: []const u8, value: []const u8 };
            \\
            \\// A config qualifier names its plugin module by logical name —
            \\// `koru/compiler/sqlite:config` and `koru.compiler.sqlite:config`
            \\// both normalize to the decl's dotted `logical_name`.
            \\fn diagConfigKeyMatches(qualifier: []const u8, logical_name: []const u8) bool {
            \\    if (qualifier.len != logical_name.len) return false;
            \\    for (qualifier, logical_name) |a, b| {
            \\        if ((if (a == '/') '.' else a) != b) return false;
            \\    }
            \\    return true;
            \\}
            \\
            \\fn diagPluginNameFor(plugin_names: *__koru_std.StringHashMap(void), qualifier: []const u8) ?[]const u8 {
            \\    var it = plugin_names.keyIterator();
            \\    while (it.next()) |k| {
            \\        if (diagConfigKeyMatches(qualifier, k.*)) return k.*;
            \\    }
            \\    return null;
            \\}
            \\
            \\fn diagConfigQualifier(f: *const __koru_ast.Flow) ?[]const u8 {
            \\    if (f.body.node) |*n| {
            \\        if (n.* != .invocation) return null;
            \\        const inv = &n.invocation;
            \\        const mq = inv.path.module_qualifier orelse return null;
            \\        if (inv.path.segments.len != 1) return null;
            \\        if (!__koru_std.mem.eql(u8, inv.path.segments[0], "config")) return null;
            \\        return mq;
            \\    }
            \\    return null;
            \\}
            \\
            \\fn diagParseConfig(allocator: __koru_std.mem.Allocator, source: []const u8) __koru_std.ArrayList(DiagConfigEntry) {
            \\    var out = __koru_std.ArrayList(DiagConfigEntry){};
            \\    var start: usize = 0;
            \\    var in_str = false;
            \\    var i: usize = 0;
            \\    while (i <= source.len) : (i += 1) {
            \\        if (i < source.len and source[i] == '"' and (i == 0 or source[i - 1] != '\\')) in_str = !in_str;
            \\        const at_sep = i == source.len or (!in_str and (source[i] == '\n' or source[i] == ','));
            \\        if (!at_sep) continue;
            \\        const chunk = __koru_std.mem.trim(u8, source[start..i], " \t\r");
            \\        start = i + 1;
            \\        if (chunk.len == 0) continue;
            \\        const colon = __koru_std.mem.indexOfScalar(u8, chunk, ':') orelse {
            \\            __koru_std.debug.print("⚠️  diagnostic config: '{s}' is not a 'key: value' entry — skipped\n", .{chunk});
            \\            continue;
            \\        };
            \\        const key = __koru_std.mem.trim(u8, chunk[0..colon], " \t\r");
            \\        var value = __koru_std.mem.trim(u8, chunk[colon + 1 ..], " \t\r");
            \\        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
            \\        if (key.len == 0 or value.len == 0) continue;
            \\        out.append(allocator, .{ .key = key, .value = value }) catch {};
            \\    }
            \\    return out;
            \\}
            \\
            \\fn diagConfigGet(entries: ?[]const DiagConfigEntry, key: []const u8) ?[]const u8 {
            \\    const list = entries orelse return null;
            \\    var found: ?[]const u8 = null;
            \\    for (list) |e| {
            \\        if (__koru_std.mem.eql(u8, e.key, key)) found = e.value;
            \\    }
            \\    return found;
            \\}
            \\
            \\fn diagItemsContainJoin(items: []const __koru_ast.Item) bool {
            \\    for (items) |*item| {
            \\        switch (item.*) {
            \\            .flow => |*f| {
            \\                if (f.body.node) |*n| {
            \\                    if (n.* == .invocation and isDiagJoinInvocation(&n.invocation)) return true;
            \\                }
            \\            },
            \\            .module_decl => |*md| {
            \\                if (diagItemsContainJoin(md.items)) return true;
            \\            },
            \\            else => {},
            \\        }
            \\    }
            \\    return false;
            \\}
            \\
            \\fn findDiagPluginModules(items: []const __koru_ast.Item, out: *__koru_std.StringHashMap(void)) void {
            \\    for (items) |*item| {
            \\        switch (item.*) {
            \\            .module_decl => |*md| {
            \\                if (diagItemsContainJoin(md.items)) out.put(md.logical_name, {}) catch {};
            \\                findDiagPluginModules(md.items, out);
            \\            },
            \\            else => {},
            \\        }
            \\    }
            \\}
            \\
            \\fn collectDiagConfigFlows(allocator: __koru_std.mem.Allocator, items: []const __koru_ast.Item, plugin_names: *__koru_std.StringHashMap(void), configs: *__koru_std.StringHashMap(__koru_std.ArrayList(DiagConfigEntry))) void {
            \\    for (items) |*item| {
            \\        switch (item.*) {
            \\            .flow => |*f| {
            \\                const mq = diagConfigQualifier(f) orelse continue;
            \\                const key = diagPluginNameFor(plugin_names, mq) orelse continue;
            \\                const src = diagArgText(f.body.node.?.invocation.args, "source") orelse "";
            \\                configs.put(key, diagParseConfig(allocator, src)) catch {};
            \\            },
            \\            .module_decl => |*md| collectDiagConfigFlows(allocator, md.items, plugin_names, configs),
            \\            else => {},
            \\        }
            \\    }
            \\}
            \\
            \\// One `!` arm = one consumer. Stage-0 semantics: the arm's tor name
            \\// resolves against builtin sinks — the Koru spelling is the contract,
            \\// the builtin is the implementation (arbitrary user-authored sink
            \\// bodies need the interpreter; that is a later conversation). Sink
            \\// parameters come from the declaring module's `X:config` entries
            \\// (cfg) with per-site arm args winning over module-level keys.
            \\fn registerDiagArms(allocator: __koru_std.mem.Allocator, join_flow: *const __koru_ast.Flow, cfg: ?[]const DiagConfigEntry) void {
            \\    for (join_flow.body.continuations) |*cont| {
            \\        const step = cont.node orelse continue;
            \\        if (step != .invocation) continue;
            \\        const name = diagArmSinkName(&step.invocation);
            \\        if (__koru_std.mem.eql(u8, name, "jsonl")) {
            \\            const path = diagArgText(step.invocation.args, "path") orelse (diagConfigGet(cfg, "file") orelse "koru-diagnostics.jsonl");
            \\            const file = __koru_std.fs.cwd().createFile(path, .{}) catch |err| {
            \\                __koru_std.debug.print("⚠️  diagnostic sink: cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            \\                continue;
            \\            };
            \\            const sink = allocator.create(DiagJsonlSink) catch continue;
            \\            sink.* = .{ .file = file, .allocator = allocator };
            \\            errors_mod.registerDiagSink(allocator, .{ .ctx = sink, .emit = DiagJsonlSink.emit }) catch {};
        );

        if (wants_sqlite) try writer.writeAll(
            \\        } else if (__koru_std.mem.eql(u8, name, "sqlite")) {
            \\            registerDiagSqliteSink(allocator, &step.invocation, cfg);
        );

        try writer.writeAll(
            \\        } else {
            \\            __koru_std.debug.print("⚠️  diagnostic sink '{s}' is not a builtin — arm ignored\n", .{name});
            \\        }
            \\    }
            \\}
            \\
            \\fn filterDiagJoinItems(allocator: __koru_std.mem.Allocator, items: []const __koru_ast.Item, mod_name: ?[]const u8, plugin_names: *__koru_std.StringHashMap(void), configs: *__koru_std.StringHashMap(__koru_std.ArrayList(DiagConfigEntry))) []const __koru_ast.Item {
            \\    var kept = __koru_std.ArrayList(__koru_ast.Item){};
            \\    for (items) |*item| {
            \\        switch (item.*) {
            \\            .flow => |*f| {
            \\                var is_join = false;
            \\                if (f.body.node) |*n| {
            \\                    if (n.* == .invocation and isDiagJoinInvocation(&n.invocation)) is_join = true;
            \\                }
            \\                if (is_join) {
            \\                    const cfg: ?[]const DiagConfigEntry = if (mod_name) |mn|
            \\                        (if (configs.get(mn)) |c| c.items else null)
            \\                    else
            \\                        null;
            \\                    registerDiagArms(allocator, f, cfg);
            \\                    continue;
            \\                }
            \\                if (diagConfigQualifier(f)) |mq| {
            \\                    if (diagPluginNameFor(plugin_names, mq) != null) continue;
            \\                }
            \\                kept.append(allocator, item.*) catch {};
            \\            },
            \\            .module_decl => |*md| {
            \\                const mutable = @constCast(md);
            \\                mutable.items = filterDiagJoinItems(allocator, md.items, md.logical_name, plugin_names, configs);
            \\                kept.append(allocator, item.*) catch {};
            \\            },
            \\            else => kept.append(allocator, item.*) catch {},
            \\        }
            \\    }
            \\    return kept.items;
            \\}
            \\
            \\fn collectDiagJoins(allocator: __koru_std.mem.Allocator, prog: *Program) *const Program {
            \\    var plugin_names = __koru_std.StringHashMap(void).init(allocator);
            \\    findDiagPluginModules(prog.items, &plugin_names);
            \\    var configs = __koru_std.StringHashMap(__koru_std.ArrayList(DiagConfigEntry)).init(allocator);
            \\    collectDiagConfigFlows(allocator, prog.items, &plugin_names, &configs);
            \\    prog.items = filterDiagJoinItems(allocator, prog.items, null, &plugin_names, &configs);
            \\    return prog;
            \\}
            \\
        );

        // SQLite sink — emitted only because an arm named `sqlite`; the extern
        // decls and the `std/compiler:requires` link dep travel together, so
        // unconditional emission here would make libsqlite3 a hard dep of
        // every backend build.
        if (wants_sqlite) try writer.writeAll(
            \\const DiagSqliteC = struct {
            \\    const Db = opaque {};
            \\    const Stmt = opaque {};
            \\    extern fn sqlite3_open(filename: [*:0]const u8, pp_db: *?*Db) c_int;
            \\    extern fn sqlite3_close_v2(db: ?*Db) c_int;
            \\    extern fn sqlite3_exec(db: ?*Db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
            \\    extern fn sqlite3_prepare_v2(db: ?*Db, sql: [*]const u8, nbyte: c_int, stmt: *?*Stmt, tail: ?*?[*]const u8) c_int;
            \\    extern fn sqlite3_bind_text(stmt: ?*Stmt, idx: c_int, val: [*]const u8, n: c_int, dtor: ?*const anyopaque) c_int;
            \\    extern fn sqlite3_bind_int64(stmt: ?*Stmt, idx: c_int, val: i64) c_int;
            \\    extern fn sqlite3_bind_null(stmt: ?*Stmt, idx: c_int) c_int;
            \\    extern fn sqlite3_step(stmt: ?*Stmt) c_int;
            \\    extern fn sqlite3_reset(stmt: ?*Stmt) c_int;
            \\    extern fn sqlite3_finalize(stmt: ?*Stmt) c_int;
            \\    extern fn sqlite3_errmsg(db: ?*Db) [*:0]const u8;
            \\};
            \\
            \\const DiagSqliteSink = struct {
            \\    stmt: ?*DiagSqliteC.Stmt,
            \\    db: ?*DiagSqliteC.Db,
            \\
            \\    // SQLITE_STATIC (null dtor): the rows bind slices out of the
            \\    // compile arena, which outlives every sqlite3_step before
            \\    // process exit — no copy needed.
            \\    fn bindText(stmt: ?*DiagSqliteC.Stmt, idx: c_int, s: []const u8) void {
            \\        const ptr: [*]const u8 = if (s.len == 0) "".ptr else s.ptr;
            \\        _ = DiagSqliteC.sqlite3_bind_text(stmt, idx, ptr, @intCast(s.len), null);
            \\    }
            \\
            \\    fn emit(ctx: *anyopaque, err: *const errors_mod.ParseError) void {
            \\        const self: *DiagSqliteSink = @ptrCast(@alignCast(ctx));
            \\        const stmt = self.stmt orelse return;
            \\        bindText(stmt, 1, @tagName(err.code));
            \\        bindText(stmt, 2, err.location.file);
            \\        _ = DiagSqliteC.sqlite3_bind_int64(stmt, 3, @intCast(err.location.line));
            \\        _ = DiagSqliteC.sqlite3_bind_int64(stmt, 4, @intCast(err.location.column));
            \\        bindText(stmt, 5, err.message);
            \\        if (err.hint) |h| bindText(stmt, 6, h) else _ = DiagSqliteC.sqlite3_bind_null(stmt, 6);
            \\        const rc = DiagSqliteC.sqlite3_step(stmt);
            \\        if (rc != 101) __koru_std.debug.print("⚠️  diagnostic sink: sqlite insert failed (rc={d})\n", .{rc});
            \\        _ = DiagSqliteC.sqlite3_reset(stmt);
            \\    }
            \\
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *DiagSqliteSink = @ptrCast(@alignCast(ctx));
            \\        _ = DiagSqliteC.sqlite3_finalize(self.stmt);
            \\        _ = DiagSqliteC.sqlite3_close_v2(self.db);
            \\    }
            \\};
            \\
            \\fn registerDiagSqliteSink(allocator: __koru_std.mem.Allocator, inv: *const __koru_ast.Invocation, cfg: ?[]const DiagConfigEntry) void {
            \\    const path = diagArgText(inv.args, "path") orelse (diagConfigGet(cfg, "db-file") orelse "koru-diagnostics.db");
            \\    // `flush` is the fsync discipline, not a transaction toggle —
            \\    // diagnostics exist on the failure paths, and failed backends
            \\    // exit through process.exit where no deferred commit could run.
            \\    // true (default): synchronous=FULL, durable per row. false:
            \\    // synchronous=OFF — still committed per insert (survives the
            \\    // backend dying), lost only on OS/power failure.
            \\    const flush_each = !__koru_std.mem.eql(u8, diagConfigGet(cfg, "flush") orelse "true", "false");
            \\    const zpath = allocator.dupeZ(u8, path) catch return;
            \\    var db: ?*DiagSqliteC.Db = null;
            \\    if (DiagSqliteC.sqlite3_open(zpath.ptr, &db) != 0 or db == null) {
            \\        __koru_std.debug.print("⚠️  diagnostic sink: sqlite3_open('{s}') failed\n", .{path});
            \\        return;
            \\    }
            \\    const schema = "CREATE TABLE IF NOT EXISTS diagnostics (code TEXT NOT NULL, file TEXT NOT NULL, line INTEGER NOT NULL, col INTEGER NOT NULL, message TEXT NOT NULL, hint TEXT);";
            \\    if (DiagSqliteC.sqlite3_exec(db, schema.ptr, null, null, null) != 0) {
            \\        __koru_std.debug.print("⚠️  diagnostic sink: sqlite schema exec failed: {s}\n", .{DiagSqliteC.sqlite3_errmsg(db)});
            \\        return;
            \\    }
            \\    const insert_sql = "INSERT INTO diagnostics (code, file, line, col, message, hint) VALUES (?1, ?2, ?3, ?4, ?5, ?6);";
            \\    var stmt: ?*DiagSqliteC.Stmt = null;
            \\    if (DiagSqliteC.sqlite3_prepare_v2(db, insert_sql.ptr, @intCast(insert_sql.len), &stmt, null) != 0 or stmt == null) {
            \\        __koru_std.debug.print("⚠️  diagnostic sink: sqlite prepare failed: {s}\n", .{DiagSqliteC.sqlite3_errmsg(db)});
            \\        return;
            \\    }
            \\    if (!flush_each) {
            \\        _ = DiagSqliteC.sqlite3_exec(db, "PRAGMA synchronous=OFF;", null, null, null);
            \\    }
            \\    const sink = allocator.create(DiagSqliteSink) catch return;
            \\    sink.* = .{ .stmt = stmt, .db = db };
            \\    errors_mod.registerDiagSink(allocator, .{ .ctx = sink, .emit = DiagSqliteSink.emit, .finish = DiagSqliteSink.finish }) catch {};
            \\}
            \\
        );

        // Backend entry point - compiles the generated code
        try writer.writeAll(
            \\pub fn main() !void {
            \\    // Compiler environment: per-invocation flags/lang/paths from
            \\    // `compiler_env.json` (written beside this backend by the frontend).
            \\    // Same channel as program.ast.json — nothing per-invocation is baked
            \\    // into this binary, so one backend serves every flag combination.
            \\    // Must load before ANY CompilerEnv read below (budget block first).
            \\    CompilerEnv.load() catch |err| {
            \\        __koru_std.debug.print("❌ Backend: cannot load compiler_env.json: {s}\n", .{@errorName(err)});
            \\        return err;
            \\    };
            \\    // Budget: --compile-mem-mb=<mb> flag wins, then KORU_COMPILE_MEM_MB,
            \\    // else 4096 MB. The flag is read per-invocation from CompilerEnv.flags,
            \\    // so a regression test can pin a tiny budget without touching env.
            \\    koru_budget_mb = blk: {
            \\        // koruc bakes flags WITHOUT the leading dashes (`compile-mem-mb=8`);
            \\        // match both spellings so a hand-run backend sees the same budget.
            \\        const flag_pfx = "compile-mem-mb=";
            \\        for (CompilerEnv.flags) |f| {
            \\            const bare = if (__koru_std.mem.startsWith(u8, f, "--"))
            \\                f[2..]
            \\            else
            \\                f;
            \\            if (__koru_std.mem.startsWith(u8, bare, flag_pfx)) {
            \\                if (__koru_std.fmt.parseInt(usize, bare[flag_pfx.len..], 10)) |v| {
            \\                    if (v >= 1) break :blk v;
            \\                } else |_| {}
            \\            }
            \\        }
            \\        if (__koru_std.process.getEnvVarOwned(__koru_std.heap.page_allocator, "KORU_COMPILE_MEM_MB")) |v| {
            \\            defer __koru_std.heap.page_allocator.free(v);
            \\            if (__koru_std.fmt.parseInt(usize, v, 10)) |parsed| {
            \\                if (parsed >= 1) break :blk parsed;
            \\            } else |_| {}
            \\        } else |_| {}
            \\        break :blk 4096;
            \\    };
            \\    var gpa = __koru_std.heap.GeneralPurposeAllocator(.{
            \\        .enable_memory_limit = true,
            \\    }){};
            \\    // The ceiling itself is a plain field (settable post-construction),
            \\    // not a Config field — Config carries only the enable flag.
            \\    gpa.requested_memory_limit = koru_budget_mb * 1024 * 1024;
            \\    defer {
            \\        const leak_status = gpa.deinit();
            \\        if (leak_status == .leak) {
            \\            __koru_std.debug.print("Memory leak detected\n", .{});
            \\        }
            \\    }
            \\    var budget = BudgetAllocator{ .child = gpa.allocator() };
            \\    const allocator = budget.allocator();
            \\
            \\    // Arena allocator for compilation phase - all compiler passes, code generation, etc.
            \\    var compile_arena = __koru_std.heap.ArenaAllocator.init(allocator);
            \\    defer compile_arena.deinit();
            \\    const compile_allocator = compile_arena.allocator();
            \\
            \\    // argv carries the -o name (consumed by the in-pipeline
            \\    // host-build steps via emitter_helpers.outputExeName) and any
            \\    // command name for the dispatch below.
            \\    const args = try __koru_std.process.argsAlloc(allocator);
            \\    defer __koru_std.process.argsFree(allocator, args);
            \\
        );

        // Seed AST: read the program AST from `program.ast.json` (written beside
        // this backend by the frontend) and deserialize it onto the compile arena.
        // This replaces the old baked-in `PROGRAM_AST` const. The backend runs in
        // the same directory the frontend emitted into (`./backend output`), so a
        // plain CWD-relative open is all that's needed — no extra argv plumbing.
        try writer.writeAll(
            \\    const seed_ast: *Program = blk: {
            \\        const ast_file = __koru_std.fs.cwd().openFile("program.ast.json", .{}) catch |err| {
            \\            __koru_std.debug.print("❌ Backend: cannot open program.ast.json: {s}\n", .{@errorName(err)});
            \\            return err;
            \\        };
            \\        defer ast_file.close();
            \\        const ast_json_bytes = try ast_file.readToEndAlloc(compile_allocator, 256 * 1024 * 1024);
            \\        const p = try compile_allocator.create(Program);
            \\        p.* = try ast_json_mod.deserialize(compile_allocator, ast_json_bytes);
            \\        break :blk p;
            \\    };
            \\
        );

        // Generate command checking code dynamically
        const cmd_result = try collectCommands(allocator, source_file);
        if (cmd_result.count > 0) {
            try writer.writeAll(
                \\    // Check for CLI commands in argv
                \\    // Note: backend_output is already imported at file scope
                \\    if (args.len > 1) {
                \\
            );

            // Generate command checks. All commands route through the single
            // `koru_command_dispatch` extern wrapper, which is emitted in
            // backend_output_emitted.zig with a name → handler switch generated
            // from the same cmd_result. Backend.zig no longer reaches into the
            // backend_output namespace here.
            for (cmd_result.commands[0..cmd_result.count]) |cmd| {
                _ = cmd.module_path;
                _ = cmd.handler_name;
                var buf: [1024]u8 = undefined;
                const line = try std.fmt.bufPrint(&buf,
                    \\        if (__koru_std.mem.eql(u8, args[1], "{s}")) {{
                    \\            __koru_std.debug.print("🔧 Running command: {s}\n", .{{}});
                    \\            const cmd_name: []const u8 = "{s}";
                    \\            const argv_slice: []const []const u8 = args[2..];
                    \\            koru_command_dispatch(@ptrCast(&cmd_name), seed_ast, &allocator, @ptrCast(&argv_slice));
                    \\            return;
                    \\        }}
                    \\
                , .{ cmd.name, cmd.name, cmd.name });
                try writer.writeAll(line);
            }

            try writer.writeAll(
                \\    }
                \\
            );
        }

        // Continue with normal compilation flow
        try writer.writeAll(
            \\    // Apply compiler passes
            \\    // Each pass takes PROGRAM_AST pointer and current AST pointer
            \\    // Returns same pointer if no changes, or new heap-allocated AST if optimized
            \\    const current_ast: *const Program = collectDiagJoins(compile_allocator, seed_ast);
            \\    defer errors_mod.finishDiagSinks();
            \\
            \\    // DUMP POINT 1: Original AST at backend entry
            \\    dumpAST(seed_ast, "1-backend-start", compile_allocator);
            \\
            \\    // More passes can go here...
            \\
            \\    const final_ast = current_ast;
            \\    defer maybeDeinitAst(final_ast);
            \\
            \\    // DUMP POINT 2: Final AST before emission (after all backend transforms)
            \\    dumpAST(final_ast, "2-pre-emit", compile_allocator);
            \\
            \\    // The pipeline owns materialization now: emission's
            \\    // per-target arms (emit-*-artifact) write the artifact,
            \\    // validate it under --deep-check, and run Stage D. The
            \\    // driver's only job post-coordinate is the metrics line
            \\    // RuntimeEmitter.emit already printed.
            \\    _ = try RuntimeEmitter.emit(compile_allocator, final_ast);
            \\}
        );
    } // End of else block (old implementation)

    return buffer.toOwnedSlice(allocator);
}

const ComptimeBackendResult = struct {
    code: []const u8,
    transform_count: usize,
};

/// Generate backend_output_emitted.zig for comptime modules
/// This generates handlers for events marked with [comptime] annotation
/// These handlers are available during backend.zig compilation
fn generateComptimeBackendEmitted(allocator: std.mem.Allocator, source_file: *ast.Program, type_registry: *TypeRegistry) !ComptimeBackendResult {
    // No --lang propagation here. This function produces backend_output_emitted.zig
    // — the compiler's own handler code that runs inside backend.zig at Stage C.
    // That code is always Zig because the compiler binary is Zig. The user's
    // --lang choice governs only the final user-program emission (the
    // .runtime_only emitter, in generateVisitorBackend below).
    // Note: emitter_helpers already imported at top-level
    const visitor_emitter_mod = @import("visitor_emitter");
    const tap_registry_module = @import("tap_registry");

    // GROWABLE, not a fixed ceiling. Generated code has no natural size bound —
    // this is the emitted comptime backend for a whole program, so its size is
    // the program's, and "1MB is surely enough" was the same bet as every fixed
    // buffer before it. It ran out on a store sweep nested in an effect arm and
    // reported `error: BufferOverflow` with a host stack trace and no source
    // location: the author is told nothing about their program, because nothing
    // about their program was wrong.
    //
    // CodeEmitter documents this contract at its own definition — "emission call
    // sites should use initGrowable; fixed init remains for callers with
    // genuinely bounded output" — and this call site is not one of those.
    const initial_size = 1024 * 1024;
    var code_emitter = try emitter_helpers.CodeEmitter.initGrowable(allocator, initial_size);

    // Write header
    try code_emitter.write("// Koru Comptime Backend Handlers\n");
    try code_emitter.write("// Handlers for [comptime] annotated modules, available during backend compilation\n\n");

    // Import AST types as an alias to avoid shadowing/ambiguity
    try code_emitter.write("const __koru_std = @import(\"std\");\n");
    try code_emitter.write("const __koru_ast = @import(\"ast\");\n");
    try code_emitter.write("const log = @import(\"log\");\n");
    // emitter_helpers provides the variant registry (getVariant) so call_handler_*
    // functions can dispatch transforms to handler__<variant> when a variant is registered.
    try code_emitter.write("const __koru_emitter_helpers = @import(\"emitter_helpers\");\n\n");

    // Add dumpAST helper for observability (backend_output_emitted.zig version)
    try code_emitter.write(
        \\// AST Dump Helper - observability for compiler pipeline debugging.
        \\// Structural continuation-tree walk gated by KORU_DUMP_AST. Self-contained
        \\// on __koru_ast types (no serializer needed at Stage-C), so it renders the
        \\// POST-TRANSFORM tree the emitter actually consumes — taps, comprehensions,
        \\// [with], auto-discharge. Each `| branch bind => NODE` line names the node
        \\// kind and its identity; [TAP] marks tap-inserted invocations.
        \\fn koruDumpPath(path: __koru_ast.DottedPath) void {
        \\    if (path.module_qualifier) |mq| __koru_std.debug.print("{s}:", .{mq});
        \\    for (path.segments, 0..) |seg, i| {
        \\        if (i > 0) __koru_std.debug.print(".", .{});
        \\        __koru_std.debug.print("{s}", .{seg});
        \\    }
        \\}
        \\fn koruDumpCont(cont: *const __koru_ast.Continuation, depth: usize) void {
        \\    var i: usize = 0;
        \\    while (i < depth) : (i += 1) __koru_std.debug.print("  ", .{});
        \\    __koru_std.debug.print("| {s}", .{cont.branch});
        \\    if (cont.binding) |b| __koru_std.debug.print(" {s}", .{b});
        \\    if (cont.is_transformed_subtree) __koru_std.debug.print(" [XFORMED-SUBTREE]", .{});
        \\    if (cont.node) |n| {
        \\        switch (n) {
        \\            .invocation => |inv| {
        \\                __koru_std.debug.print(" => INVOKE ", .{});
        \\                koruDumpPath(inv.path);
        \\                if (inv.return_binding) |rb| __koru_std.debug.print(": {s}", .{rb});
        \\                if (inv.inserted_by_tap) __koru_std.debug.print("  [TAP]", .{});
        \\                if (inv.annotations.len > 0) {
        \\                    __koru_std.debug.print("  ANN[", .{});
        \\                    for (inv.annotations) |a| __koru_std.debug.print("{s} ", .{a});
        \\                    __koru_std.debug.print("]", .{});
        \\                }
        \\                if (inv.inline_body != null) __koru_std.debug.print("  [INLINE_BODY]", .{});
        \\            },
        \\            .branch_constructor => |bc| {
        \\                if (bc.is_bare_return) {
        \\                    __koru_std.debug.print(" => RETURN", .{});
        \\                } else {
        \\                    __koru_std.debug.print(" => CTOR .{s}", .{bc.branch_name});
        \\                }
        \\            },
        \\            .terminal => __koru_std.debug.print(" => _", .{}),
        \\            .label_with_invocation => |lwi| {
        \\                __koru_std.debug.print(" => LABEL {s} ", .{lwi.label});
        \\                koruDumpPath(lwi.invocation.path);
        \\                if (lwi.invocation.inserted_by_tap) __koru_std.debug.print("  [TAP]", .{});
        \\            },
        \\            .metatype_binding => |mb| {
        \\                __koru_std.debug.print(" => METATYPE {s}", .{mb.metatype});
        \\                if (mb.inserted_by_tap) __koru_std.debug.print("  [TAP]", .{});
        \\            },
        \\            else => __koru_std.debug.print(" => <node>", .{}),
        \\        }
        \\    } else {
        \\        __koru_std.debug.print(" => (empty)", .{});
        \\    }
        \\    __koru_std.debug.print("\n", .{});
        \\    for (cont.continuations) |*child| koruDumpCont(child, depth + 1);
        \\}
        \\fn dumpAST(program_ast: *const __koru_ast.Program, stage: []const u8, allocator: __koru_std.mem.Allocator) void {
        \\    const dump_enabled: ?[]const u8 = __koru_std.process.getEnvVarOwned(allocator, "KORU_DUMP_AST") catch |err| blk: {
        \\        if (err == error.EnvironmentVariableNotFound) break :blk null;
        \\        break :blk null;
        \\    };
        \\    defer if (dump_enabled) |val| allocator.free(val);
        \\    if (dump_enabled == null) return;  // Not enabled
        \\
        \\    __koru_std.debug.print("\n============================================================\n", .{});
        \\    __koru_std.debug.print("AST DUMP: {s}  (items={d}, module={s})\n", .{ stage, program_ast.items.len, program_ast.main_module_name });
        \\    __koru_std.debug.print("============================================================\n", .{});
        \\    for (program_ast.items) |*item| {
        \\        switch (item.*) {
        \\            .flow => |*f| {
        \\                __koru_std.debug.print("FLOW ", .{});
        \\                if (f.body.node) |n| {
        \\                    if (n == .invocation) koruDumpPath(n.invocation.path);
        \\                }
        \\                __koru_std.debug.print("\n", .{});
        \\                koruDumpCont(&f.body, 1);
        \\            },
        \\            else => {},
        \\        }
        \\    }
        \\    __koru_std.debug.print("============================================================\n\n", .{});
        \\}
        \\
    );

    // NOTE: __koru_std import is handled by visitor_emitter when Profile/Audit metatypes are detected
    // visitor_emitter.zig scans the AST and conditionally emits it to avoid duplicates

    // Build tap registry
    var tap_registry = try tap_registry_module.buildTapRegistry(source_file.items, allocator);
    defer tap_registry.deinit();

    // Transform AST - insert taps before emission
    // Taps are inserted into the AST as regular flow code (zero-cost abstraction!)
    log.debug("DEBUG: Running AST transformation in generateComptimeBackendEmitted\n", .{});
    const tap_transformer = @import("tap_transformer");
    const ast_to_emit = try tap_transformer.transformAst(source_file, &tap_registry, .comptime_only, allocator);

    // Create visitor emitter with comptime_only mode
    // This will emit ONLY modules with [comptime] annotation
    var visitor_emitter = visitor_emitter_mod.VisitorEmitter.init(allocator, &code_emitter, ast_to_emit.items, &tap_registry, type_registry, .comptime_only // Emit only modules with [comptime] annotation
    );
    // .lang intentionally left at the struct default "zig". This emission
    // produces backend_output_emitted.zig — the compiler's own handler code
    // that runs inside backend.zig at Stage C. The compiler's handlers MUST
    // be Zig regardless of the user's --lang choice.

    // Emit using visitor pattern!
    // The visitor will automatically filter to only [comptime] modules via shouldFilter
    try visitor_emitter.emit(ast_to_emit);

    // Generate transform handlers into backend_output_emitted.zig
    // These need to be in the same file as evaluate_comptime so it can call them
    const transform_count = try generateTransformHandlersToEmitter(&code_emitter, allocator, source_file);

    // Extern wrappers — `pub export fn` shims that backend.zig calls via
    // `extern fn`. C-ABI flat extern struct because Zig 0.15 won't let extern fn
    // carry Zig-native unions/slices. The wrapper rehydrates slices internally
    // before invoking the real Zig-native handler.
    const std_compiler_path = try codegen_utils.buildKoruModulePath(allocator, "std.compiler");
    defer allocator.free(std_compiler_path);

    try code_emitter.write(
        \\
        \\// ============================================================
        \\// EXTERN WRAPPERS — link-time entry points for backend.zig
        \\// ============================================================
        \\
        \\const __KoruCoordinateResult = extern struct {
        \\    is_error: bool,
        \\    code_ptr: [*]const u8,
        \\    code_len: usize,
        \\    metrics_ptr: [*]const u8,
        \\    metrics_len: usize,
        \\    error_ptr: [*]const u8,
        \\    error_len: usize,
        \\};
        \\pub export fn koru_coordinate(
        \\    program_ast: *const __koru_ast.Program,
        \\    allocator: *const __koru_std.mem.Allocator,
        \\) __KoruCoordinateResult {
        \\    const result = 
    );
    try code_emitter.write(std_compiler_path);
    try code_emitter.write(
        \\.coordinate_event.handler(.{
        \\        .program_ast = program_ast,
        \\        .allocator = allocator.*,
        \\    });
        \\    return switch (result) {
        \\        .coordinated => |r| .{
        \\            .is_error = false,
        \\            .code_ptr = r.code.ptr,
        \\            .code_len = r.code.len,
        \\            .metrics_ptr = r.metrics.ptr,
        \\            .metrics_len = r.metrics.len,
        \\            .error_ptr = "".ptr,
        \\            .error_len = 0,
        \\        },
        \\        .@"error" => |e| .{
        \\            .is_error = true,
        \\            .code_ptr = "".ptr,
        \\            .code_len = 0,
        \\            .metrics_ptr = "".ptr,
        \\            .metrics_len = 0,
        \\            .error_ptr = e.ptr,
        \\            .error_len = e.len,
        \\        },
        \\    };
        \\}
        \\
    );

    // koru_command_dispatch — routes CLI command invocations to the right event
    // handler. Generated from cmd_result so the dispatch knows the user's
    // commands.
    const cmd_result = try collectCommands(allocator, source_file);
    try code_emitter.write(
        \\pub export fn koru_command_dispatch(
        \\    name: *const anyopaque,
        \\    program: *const __koru_ast.Program,
        \\    allocator: *const __koru_std.mem.Allocator,
        \\    argv: *const anyopaque,
        \\) void {
        \\    const name_typed: *const []const u8 = @ptrCast(@alignCast(name));
        \\    const argv_typed: *const []const []const u8 = @ptrCast(@alignCast(argv));
        \\    // Command dispatch returns before the pipeline reaches Phase 2.3.5,
        \\    // the early comptime_main pass that registers build:config /
        \\    // build:variants into emitter_helpers. Without this prime those
        \\    // registries are empty inside every command handler. The returned
        \\    // program is discarded: handlers keep the seed AST, the prime is
        \\    // for registry side-effects only.
        \\    if (@hasDecl(@This(), "comptime_main")) {
        \\        _ = comptime_main(program, allocator.*);
        \\    }
        \\
    );
    for (cmd_result.commands[0..cmd_result.count]) |cmd| {
        var buf: [1024]u8 = undefined;
        if (cmd.module_path) |mod_path| {
            const full_path = try codegen_utils.buildKoruModulePath(allocator, mod_path);
            defer allocator.free(full_path);
            const line = try std.fmt.bufPrint(&buf,
                \\    if (__koru_std.mem.eql(u8, name_typed.*, "{s}")) {{
                \\        _ = {s}.{s}_event.handler(.{{
                \\            .program = program,
                \\            .allocator = allocator.*,
                \\            .argv = argv_typed.*,
                \\        }});
                \\        return;
                \\    }}
                \\
            , .{ cmd.name, full_path, cmd.handler_name });
            try code_emitter.write(line);
        } else {
            const line = try std.fmt.bufPrint(&buf,
                \\    if (__koru_std.mem.eql(u8, name_typed.*, "{s}")) {{
                \\        _ = main_module.{s}_event.handler(.{{
                \\            .program = program,
                \\            .allocator = allocator.*,
                \\            .argv = argv_typed.*,
                \\        }});
                \\        return;
                \\    }}
                \\
            , .{ cmd.name, cmd.handler_name });
            try code_emitter.write(line);
        }
    }
    try code_emitter.write(
        \\}
        \\
    );

    // koru_run_pass — wraps the existing run_pass for cross-unit linkage.
    // Always emitted (the extern fn declaration on backend.zig side is only
    // emitted when has_transforms is true, but an extra unreferenced symbol
    // here costs nothing).
    if (transform_count > 0) {
        try code_emitter.write(
            \\pub export fn koru_run_pass(
            \\    annotation: *const anyopaque,
            \\    program: *const __koru_ast.Program,
            \\    allocator: *const __koru_std.mem.Allocator,
            \\    out_program: *?*const __koru_ast.Program,
            \\    ctx: ?*anyopaque,
            \\) bool {
            \\    const annotation_typed: *const []const u8 = @ptrCast(@alignCast(annotation));
            \\    out_program.* = run_pass(annotation_typed.*, program, allocator.*, ctx) catch {
            \\        return false;
            \\    };
            \\    return true;
            \\}
            \\
        );
    }

    // koru_explain_gather — calls every discovered `[explainer]` once and
    // collects the returned ExplainReport values into an owned slice, which the
    // `explain` command handler renders. ALWAYS emitted (even with zero
    // explainers → empty slice) so std/explain's proc can reference it
    // unconditionally, exactly as backend.zig references koru_run_pass.
    {
        const explainers = try collectExplainers(allocator, source_file);
        defer allocator.free(explainers);
        try code_emitter.write(
            \\pub fn koru_explain_gather(
            \\    program: *const __koru_ast.Program,
            \\    allocator: *const __koru_std.mem.Allocator,
            \\) []const __koru_ast.ExplainReport {
            \\    _ = &program; // may be unused when zero explainers are registered
            \\    var __explain_list = __koru_std.ArrayList(__koru_ast.ExplainReport){};
            \\
        );
        for (explainers) |ex| {
            var buf: [1024]u8 = undefined;
            // Handler symbols mangle kebab to underscore (`explain-store` →
            // `explain_store_event`); the raw joined name still carries the hyphen.
            var ident_buf: [256]u8 = undefined;
            const handler_ident = lowerKebabIdent(&ident_buf, ex.handler_name);
            if (ex.module_path) |mod_path| {
                const full_path = try codegen_utils.buildKoruModulePath(allocator, mod_path);
                defer allocator.free(full_path);
                const line = try std.fmt.bufPrint(&buf,
                    \\    __explain_list.append(allocator.*, {s}.{s}_event.handler(.{{
                    \\        .program = program,
                    \\        .allocator = allocator.*,
                    \\    }})) catch return &.{{}};
                    \\
                , .{ full_path, handler_ident });
                try code_emitter.write(line);
            } else {
                const line = try std.fmt.bufPrint(&buf,
                    \\    __explain_list.append(allocator.*, main_module.{s}_event.handler(.{{
                    \\        .program = program,
                    \\        .allocator = allocator.*,
                    \\    }})) catch return &.{{}};
                    \\
                , .{handler_ident});
                try code_emitter.write(line);
            }
        }
        try code_emitter.write(
            \\    return __explain_list.toOwnedSlice(allocator.*) catch return &.{};
            \\}
            \\
            \\
        );
    }

    // Get the generated code and trim to actual size
    const generated = code_emitter.getOutput();
    return ComptimeBackendResult{
        .code = try allocator.dupe(u8, generated),
        .transform_count = transform_count,
    };
}

/// The `.reporter = …` line a generated `call_handler_*` writes for a handler
/// that declares the `reporter` machine parameter. The reporter is not a
/// separate channel down the ABI: it is the compilation's ONE reporter, read
/// back off the context that already rides in as `?*anyopaque`. Both hops
/// assert — no context, or a context carrying no reporter, is a wiring fault in
/// the caller, never something to paper over with a freshly-built reporter
/// bound to no file. Args: indent, kind, name, kind, name.
const reporter_inject_fmt =
    "{s}.reporter = (@as(*koru_std.koru_compiler.CompilerContext, @ptrCast(@alignCast(__koru_ctx orelse " ++
    "@panic(\"{s} '{s}' declares reporter: *ErrorReporter but was invoked from a path that carries no compilation context\")))).reporter orelse " ++
    "@panic(\"{s} '{s}' declares reporter: *ErrorReporter but the compilation carries none\")),\n";

/// TransformEvent stores both the underscore name (for stubs) and dotted name (for matching)
/// Transforms are compiler passes: Program -> transformed{Program} | failed{error}
/// Also used for derive handlers which generate new declarations from event declarations
/// Detection is TYPE-DRIVEN: *const Invocation = transform, *const EventDecl = derive
const TransformEvent = struct {
    stub_name: []const u8, // e.g., "control_if" - unique name for call_handler_X function
    match_name: []const u8, // e.g., "if" - event name with dots for matching
    event_name: []const u8, // e.g., "if" - original event name for handler struct lookup
    module_path: ?[]const u8, // e.g., "koru_std.control" for stdlib, null for main_module
    claims_descendants: bool = false, // Transform should run before walking lexical descendants
    stage: []const u8 = "main", // Ordered transform stage: "pre" | "main" | "post" ([transform|pre]/[transform|post])
    has_source: bool, // Event accepts source: Source[T] parameter
    source_optional: bool = false, // The source param is `?Source` — blockless calls still fire the handler with null
    has_expression: bool, // Event accepts expr: Expression parameter
    has_optional_expression: bool = false, // Event accepts expr: ?Expression parameter (optional, may be null)
    expression_field_name: ?[]const u8 = null, // Actual field name for Expression parameter
    expression_field_names: []const []const u8 = &.{}, // ALL required Expression param names, declaration order (multi-expression handlers)
    has_invocation: bool, // Event accepts invocation: *const Invocation parameter
    has_event_decl: bool, // Event accepts event_decl: *const EventDecl parameter
    has_item: bool, // Event accepts item: *const Item parameter
    has_program_ast: bool, // Event accepts program: *const Program parameter
    has_allocator: bool, // Event accepts allocator: std.mem.Allocator parameter
    /// Event accepts ctx: *CompilerContext — the live compilation the
    /// metacircular passes thread. Reaches the handler as `?*anyopaque` (the
    /// circular-import dodge `Program.type_registry` already uses) and is cast
    /// back in the generated stub. A handler declaring it that is reached from
    /// an entry point carrying no context asserts; it is never synthesized.
    has_ctx: bool = false,
    /// Event accepts reporter: *ErrorReporter — the compilation's ONE
    /// diagnostic channel, minted at the pipeline head and bound to the user's
    /// source file. Rides in on the same `?*anyopaque` context as `has_ctx`
    /// (the stub reads it back off `CompilerContext.reporter`), so a handler
    /// declaring it on a context-free entry point asserts rather than getting a
    /// freshly-built reporter pointed at nothing.
    has_reporter: bool = false,
    has_event_name_field: bool, // Event accepts event_name: []const u8 parameter (for glob patterns)
    returns_program: bool, // Event returns transformed{ program: *const Program }
    // Single-return form (210_131): the decl is `-> SiteResult` and the impl is
    // a PLAIN proc, so the generated handler's Output IS SiteResult — the stub
    // returns it directly, no `.transformed` union unwrap. Machine-convention
    // `[transform]proc` events keep the hardcoded union regardless of decl.
    bare_return: bool = false,
    has_failed: bool, // Event has failed{ error: []const u8 } branch
    failed_is_identity: bool, // failed branch is identity (just []const u8, not struct)
    has_compile_error: bool, // Event has compile_error{ message: []const u8 } branch
    /// Qualified-only dispatch: the user-spelled module qualifier (dotted,
    /// e.g. "std.regex") an invocation MUST carry to fire this transform.
    /// Set for `[transform]proc` events and for imported-module non-glob
    /// transform tors — including keyword tors. Transform tors without a
    /// qualifier captured sibling modules' same-named events (`std/list:free`
    /// rewriting `std/map:free`, 810_142 / 660_033).
    /// Globs stay null (taps). Keyword tors used to stay null so `assert`
    /// inside `test` still fired; the inner pass now keyword-resolves the
    /// cloned body (395_001), so that carve-out is gone. A keyword that is
    /// also a `[transform]proc` was already qualified: `std/store:take` must
    /// not capture `std/string:take` (690_053).
    qualifier: ?[]const u8 = null,
    /// Variant target names (e.g. "raw_posix") for ~proc <event>|<variant> declarations.
    /// The call_handler wrapper dispatches to handler.handler__<variant> based on
    /// flow.inv().variant or the build-time variant registry.
    variant_targets: []const []const u8 = &[_][]const u8{},
};

/// The transform-contract flags a tor's declaration implies: a `transformed`
/// arm carrying a Program/SiteResult field (old-style struct field or
/// `__type_ref` identity) returns a program; a `failed` arm with a lone
/// `__type_ref` is identity; a `compile_error` arm is declared. A bare
/// `-> SiteResult`/`-> Program` on the decl head is the single-return form
/// (210_131) — the return lives there, never as a lone `| transformed` arm.
const TransformFlags = struct {
    returns_program: bool = false,
    has_failed: bool = false,
    failed_is_identity: bool = false,
    has_compile_error: bool = false,
};

fn scanTransformFlags(event_decl: ast.EventDecl) TransformFlags {
    var flags = TransformFlags{};
    for (event_decl.branches) |branch| {
        if (std.mem.eql(u8, branch.name, "transformed")) {
            for (branch.payload.fields) |field| {
                // Old-style struct field or identity syntax (__type_ref)
                if (std.mem.eql(u8, field.name, "program") or
                    (std.mem.eql(u8, field.name, "__type_ref") and
                        (std.mem.indexOf(u8, field.type, "Program") != null or std.mem.indexOf(u8, field.type, "SiteResult") != null)))
                {
                    flags.returns_program = true;
                    break;
                }
            }
        } else if (std.mem.eql(u8, branch.name, "failed")) {
            flags.has_failed = true;
            // Identity branch: single __type_ref field
            if (branch.payload.fields.len == 1 and
                std.mem.eql(u8, branch.payload.fields[0].name, "__type_ref"))
            {
                flags.failed_is_identity = true;
            }
        } else if (std.mem.eql(u8, branch.name, "compile_error")) {
            flags.has_compile_error = true;
        }
    }
    if (event_decl.return_type) |rt| {
        if (std.mem.indexOf(u8, rt, "Program") != null or
            std.mem.indexOf(u8, rt, "SiteResult") != null)
        {
            flags.returns_program = true;
        }
    }
    return flags;
}

/// What a tor's Input declares about AST-consumption: source and expression
/// params ride user args; `*const Invocation`/`Item`/`EventDecl` params mean
/// the handler needs the backend-emitted machine interface.
const TransformParamScan = struct {
    has_source_param: bool = false,
    source_optional_param: bool = false,
    has_expression_param: bool = false,
    has_optional_expression_param: bool = false,
    expression_field_name_param: ?[]const u8 = null,
    expression_field_names_list: std.ArrayList([]const u8) = .{},
    has_invocation_param: bool = false,
    has_item_param: bool = false,
    has_event_decl_param: bool = false,
};

fn scanTransformParams(allocator: std.mem.Allocator, fields: []const ast.Field) !TransformParamScan {
    var scan = TransformParamScan{};
    for (fields) |field| {
        if (field.is_source) {
            scan.has_source_param = true;
            if (std.mem.startsWith(u8, field.type, "?")) scan.source_optional_param = true;
        } else if (field.is_expression) {
            if (std.mem.startsWith(u8, field.type, "?")) {
                scan.has_optional_expression_param = true;
            } else {
                scan.has_expression_param = true;
                try scan.expression_field_names_list.append(allocator, field.name);
            }
            scan.expression_field_name_param = field.name;
        } else if (std.mem.eql(u8, field.type, "*const Invocation")) {
            scan.has_invocation_param = true;
        } else if (std.mem.eql(u8, field.type, "*const Item")) {
            scan.has_item_param = true;
        } else if (std.mem.eql(u8, field.type, "*const EventDecl")) {
            scan.has_event_decl_param = true;
        }
    }
    return scan;
}

/// The name-driven half of the Input scan: `*const Invocation`/`Item`/
/// `EventDecl` params are detected by TYPE in TransformParamScan; these
/// machine-convention params (program_ast, allocator, event_name, ctx,
/// reporter) declare ordinary types and are recognized by NAME.
const ParamNameScan = struct {
    has_program_ast: bool = false,
    has_allocator: bool = false,
    has_event_name_field: bool = false,
    has_ctx: bool = false,
    has_reporter: bool = false,
};

fn scanParamNames(fields: []const ast.Field) ParamNameScan {
    var names = ParamNameScan{};
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "program_ast") or std.mem.eql(u8, field.name, "program")) {
            names.has_program_ast = true;
        } else if (std.mem.eql(u8, field.name, "allocator")) {
            names.has_allocator = true;
        } else if (std.mem.eql(u8, field.name, "event_name")) {
            names.has_event_name_field = true;
        } else if (std.mem.eql(u8, field.name, "ctx")) {
            names.has_ctx = true;
        } else if (std.mem.eql(u8, field.name, "reporter")) {
            names.has_reporter = true;
        }
    }
    return names;
}

/// Walk items finding proc_decls whose path matches the given segments AND have a non-null,
/// non-default-lang target. Used to collect variant procs for transform-event dispatch.
/// `default_lang` is the variant tag that is considered the default (typically "zig",
/// configurable via `--lang=<name>`); procs tagged with it are excluded because they
/// take the main dispatch path.
fn collectVariantTargetsForEventPath(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    segments: []const []const u8,
    default_lang: []const u8,
) ![]const []const u8 {
    var found = std.ArrayList([]const u8){};
    errdefer found.deinit(allocator);

    for (items) |item| {
        if (item == .proc_decl) {
            const proc = item.proc_decl;
            if (proc.target == null) continue;
            if (std.mem.eql(u8, proc.target.?, default_lang)) continue;
            if (proc.path.segments.len != segments.len) continue;
            var matches = true;
            for (proc.path.segments, 0..) |segment, i| {
                if (!std.mem.eql(u8, segment, segments[i])) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                try found.append(allocator, try allocator.dupe(u8, proc.target.?));
            }
        }
    }
    return try found.toOwnedSlice(allocator);
}

/// `--lang` namespace guard (KORU126): the tag must name a registered
/// emitter or a proc variant actually declared in this program. Every
/// other name used to sail through unrefused and emit a Zig binary
/// under the foreign tag — measured 2026-10-05: `koruc input.k
/// --lang=cs` produced a working Mach-O executable. The admitted set
/// is generous on purpose: a declared `|mlir[gpu]` admits both `mlir`
/// (the base transform dispatch compares) and `mlir[gpu]` (the full
/// tag the emitter compares) — what is refused is a name nothing
/// declared.
fn enforceLangNamespace(
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    lang: []const u8,
) !void {
    // Emitters wired into the target-of dispatch (koru_std/compiler.materialize.kz).
    if (std.mem.eql(u8, lang, "zig") or std.mem.eql(u8, lang, "js") or std.mem.eql(u8, lang, "cs")) return;

    var declared = std.StringHashMap(void).init(allocator);
    defer declared.deinit();
    try collectProcVariantTags(&declared, program.items);
    if (declared.contains(lang)) return;

    var names = std.ArrayList([]const u8){};
    defer names.deinit(allocator);
    var kit = declared.keyIterator();
    while (kit.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);
    const lw = list.writer(allocator);
    for (names.items, 0..) |n, i| {
        if (i > 0) try lw.writeAll(", ");
        try lw.writeAll(n);
    }

    try printStderr(allocator, "error[KORU126]: --lang='{s}' names no emitter and no proc variant declared in this program\n  emitters: zig, js, cs\n  declared variant tags: {s}\n  `--lang=<tag>` selects which `~proc <tor>|<tag>` bodies get emitted — a tag nothing declares still compiles, under a name that selects nothing\n  fix: pass one of the declared tags, or declare `~proc <tor>|{s} {{ ... }}` bodies for the target first\n", .{ lang, if (names.items.len == 0) "(none)" else list.items, lang });
    std.process.exit(1);
}

/// Every proc variant tag the program declares, walking module items —
/// full tags (the emitter compares `target == lang` exactly) and base
/// tags (transform dispatch strips `(...)`/`[...]` parameter groups
/// before comparing).
fn collectProcVariantTags(set: *std.StringHashMap(void), items: []const ast.Item) !void {
    for (items) |item| {
        switch (item) {
            .proc_decl => |proc| {
                const target = proc.target orelse continue;
                try set.put(target, {});
                if (std.mem.indexOfAny(u8, target, "([")) |cut| {
                    try set.put(target[0..cut], {});
                }
            },
            .module_decl => |module| try collectProcVariantTags(set, module.items),
            else => {},
        }
    }
}

/// Frontend `glance` — print the program's declaration surface (every module's
/// events with full signatures, annotations, and file:line) from the fully
/// resolved post-import AST, then return. Same category as `--help`/`--ast-json`:
/// an AST-introspection mode, no backend, no codegen. `app_only` drops std/koru.
fn glancePrintEvent(ed: *const ast.EventDecl, sites: []const site_hash.Site) void {
    std.debug.print("  ", .{});
    if (ed.annotations.len > 0) {
        std.debug.print("[", .{});
        for (ed.annotations, 0..) |ann, i| {
            if (i > 0) std.debug.print("|", .{});
            std.debug.print("{s}", .{ann});
        }
        std.debug.print("] ", .{});
    }
    for (ed.path.segments, 0..) |seg, i| {
        if (i > 0) std.debug.print(".", .{});
        std.debug.print("{s}", .{seg});
    }
    std.debug.print("(", .{});
    if (ed.input.is_wildcard) {
        std.debug.print("*", .{});
    } else {
        for (ed.input.fields, 0..) |f, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print("{s}: {s}", .{ f.name, f.type });
        }
    }
    std.debug.print(")", .{});
    if (ed.return_type) |rt| std.debug.print(" -> {s}", .{rt});
    if (site_hash.hashOf(sites, @intFromPtr(ed))) |h| {
        std.debug.print("  [{s}]", .{h[0..site_hash.displayLen(sites, h)]});
    }
    const file = ed.location.file;
    const base = if (std.mem.lastIndexOfScalar(u8, file, '/')) |ix| file[ix + 1 ..] else file;
    std.debug.print("  {s}:{d}\n", .{ base, ed.location.line });
}

fn runGlance(source_file: *const ast.Program, app_only: bool) void {
    std.debug.print("📄 glance\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const sites = site_hash.collectSites(arena.allocator(), source_file) catch &.{};

    var main_count: usize = 0;
    for (source_file.items) |item| {
        if (item == .event_decl) main_count += 1;
    }
    if (main_count > 0) {
        std.debug.print("(main) — {d} event(s)\n", .{main_count});
        for (source_file.items) |*item| {
            if (item.* == .event_decl) glancePrintEvent(&item.event_decl, sites);
        }
    }

    for (source_file.items) |*item| {
        if (item.* != .module_decl) continue;
        const mod = item.module_decl;
        if (app_only and (std.mem.startsWith(u8, mod.logical_name, "std") or
            std.mem.startsWith(u8, mod.logical_name, "koru"))) continue;
        var n: usize = 0;
        for (mod.items) |mi| {
            if (mi == .event_decl) n += 1;
        }
        if (n == 0) continue;
        std.debug.print("{s} — {d} event(s)\n", .{ mod.logical_name, n });
        for (mod.items) |*mi| {
            if (mi.* == .event_decl) glancePrintEvent(&mi.event_decl, sites);
        }
    }
}

/// Frontend `at` — resolve a site hash back to its neighborhood. Descends the
/// longest live prefix of the query (chomping right = zooming out), prints the
/// cell it lands on, and lists each matched site's immediate children — the
/// matryoshka drill — so a hash is always "a way back," never hit-or-miss.
fn runAt(source_file: *const ast.Program, query: []const u8, entry_file: []const u8, injection_lines: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const sites = site_hash.collectSites(alloc, source_file) catch {
        std.debug.print("📍 at {s} — could not index sites\n", .{query});
        return;
    };
    const res = site_hash.resolve(alloc, sites, query) catch return;
    if (res.matched.len == 0) {
        std.debug.print("📍 at {s} — nothing lives here; no module matches the first segment\n", .{query});
        return;
    }
    if (res.drifted) {
        std.debug.print("📍 at {s} — tail drifted; nearest cell is depth {d} ({d} site(s))\n", .{ query, res.depth_chars, res.matched.len });
    } else {
        std.debug.print("📍 at {s} — {d} site(s)\n", .{ query, res.matched.len });
    }
    for (res.matched) |s| {
        const file = s.location.file;
        const base = if (std.mem.lastIndexOfScalar(u8, file, '/')) |ix| file[ix + 1 ..] else file;
        const kind: []const u8 = switch (s.kind) {
            .decl => "decl",
            .flow => "flow",
            .site => "site",
        };
        // Flow-head and continuation-site locations are stored in parser
        // (injected-buffer) coordinates — the bootstrap `import std/compiler`
        // the frontend prepends shifts every entry-file line by
        // injection_lines. Decls already store user coordinates
        // (getUserDeclStartLocation) and imported module files were never
        // injected, so the translate applies only to non-decl sites on the
        // entry file. The STORED value is untouched — __koru_srf_* uniquifiers
        // and the hash children() key on parser coords; only the printed
        // file:line moves to the line the user wrote.
        const line = if (s.kind != .decl and
            std.mem.eql(u8, s.location.file, entry_file) and
            s.location.line > injection_lines)
            s.location.line - injection_lines
        else
            s.location.line;
        std.debug.print("  {s}  {s}  [{s}]  {s}:{d}\n", .{ kind, s.spelling, s.hash, base, line });
        const kids = site_hash.children(alloc, sites, s) catch &.{};
        for (kids) |k| {
            std.debug.print("    ↳ [{s}] {s}\n", .{ k.hash[0..site_hash.displayLen(sites, k.hash)], k.spelling });
        }
    }
}

/// CommandInfo stores CLI command metadata for [comptime|command] events
/// Commands run instead of normal compilation when invoked via `koruc file.kz <command>`
const CommandInfo = struct {
    name: []const u8, // e.g., "install" - command name for CLI
    handler_name: []const u8, // e.g., "package_install" - Zig function name
    module_path: ?[]const u8, // e.g., "koru_std.package" for stdlib commands
};

/// Collect all [comptime|command] events from the AST
fn collectCommands(allocator: std.mem.Allocator, source_file: *ast.Program) !struct { commands: [16]CommandInfo, count: usize } {
    var commands: [16]CommandInfo = undefined;
    var count: usize = 0;

    // command.declare metadata. A declare carrying an `event` field OVERRIDES
    // the CLI name of that event: dispatch/detection match argv against the
    // declare's (colon-capable) `name`, while the handler symbol stays the event
    // identifier. Absent → the CLI name is the event name (today's convention).
    const decls = collectCommandDeclarations(allocator, source_file) catch &[_]CommandDeclaration{};
    defer for (decls) |*d| {
        var m = d.*;
        m.deinit(allocator);
    };
    const CliOverride = struct {
        // Freshly-duped CLI name if a declare's `event` matches this event, else null.
        fn find(a: std.mem.Allocator, event_name: []const u8, ds: []const CommandDeclaration) !?[]const u8 {
            for (ds) |d| {
                const ev = d.event orelse continue;
                if (std.mem.eql(u8, ev, event_name)) return try a.dupe(u8, d.name);
            }
            return null;
        }
    };

    // Scan top-level events
    for (source_file.items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;
            const has_command = annotation_parser.hasPart(event_decl.annotations, "command");

            if (has_command and count < 16) {
                const event_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);
                const handler_name = try joinPathSegments(allocator, event_decl.path.segments);
                const cli = (try CliOverride.find(allocator, event_name, decls)) orelse event_name;

                commands[count] = .{
                    .name = cli,
                    .handler_name = try mangleHandlerName(allocator, handler_name),
                    .module_path = null,
                };
                count += 1;
            }
        }

        // Also check imported modules
        if (item == .module_decl) {
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .event_decl) {
                    const event_decl = mod_item.event_decl;
                    const has_command = annotation_parser.hasPart(event_decl.annotations, "command");

                    if (has_command and count < 16) {
                        const event_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);
                        // Handler name is just the event name (e.g., "install")
                        // The full path koru_std.package.install_event.handler is built at codegen
                        const handler_name = try joinPathSegments(allocator, event_decl.path.segments);
                        const cli = (try CliOverride.find(allocator, event_name, decls)) orelse event_name;

                        commands[count] = .{
                            .name = cli,
                            .handler_name = try mangleHandlerName(allocator, handler_name),
                            .module_path = module.logical_name,
                        };
                        count += 1;
                    }
                }
            }
        }
    }

    return .{ .commands = commands, .count = count };
}

/// ExplainerInfo — a discovered `[explainer]` event: the handler symbol and the
/// module it lives in. The `explain` command calls each once and collects the
/// returned ExplainReport. Mirrors CommandInfo but keyed on the `[explainer]`
/// annotation, with no CLI name — explainers are never invoked directly, only
/// the `explain` command calls them.
const ExplainerInfo = struct {
    handler_name: []const u8, // joined event path segments, e.g. "explain_store"
    module_path: ?[]const u8, // e.g. "koru_std.store"; null = main module
};

/// Collect all `[explainer]` events from the AST — top-level and inside imported
/// modules — mirroring collectCommands' two-level walk.
fn collectExplainers(allocator: std.mem.Allocator, source_file: *ast.Program) ![]ExplainerInfo {
    var list = std.ArrayList(ExplainerInfo){};
    errdefer list.deinit(allocator);

    for (source_file.items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;
            if (annotation_parser.hasPart(event_decl.annotations, "explainer")) {
                const handler_name = try joinPathSegments(allocator, event_decl.path.segments);
                try list.append(allocator, .{ .handler_name = handler_name, .module_path = null });
            }
        }
        if (item == .module_decl) {
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .event_decl) {
                    const event_decl = mod_item.event_decl;
                    if (annotation_parser.hasPart(event_decl.annotations, "explainer")) {
                        const handler_name = try joinPathSegments(allocator, event_decl.path.segments);
                        try list.append(allocator, .{ .handler_name = handler_name, .module_path = module.logical_name });
                    }
                }
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Generate transform handlers to CodeEmitter (for backend_output_emitted.zig).
/// Emits a `call_handler_<stub>` wrapper per [comptime|transform] event (each
/// returns ast.SiteResult — the site-local write-back ABI) plus the dispatch
/// table consumed by transform_pass_runner.
/// Returns the number of transform events found
fn generateTransformHandlersToEmitter(code_emitter: anytype, allocator: std.mem.Allocator, source_file: *ast.Program) !usize {
    // Transforms are [comptime] procs — they execute inside the koruc Stage C
    // binary, which is always Zig. The variant dispatcher for a transform
    // therefore treats `|zig` as the default (emitted as plain `handler`) and
    // every other variant as an alternate (emitted as `handler__<variant>`),
    // regardless of the user's --lang choice. --lang governs the final
    // user-program emission only; comptime emission is structurally Zig.
    const comptime_default_lang = "zig";
    // First pass: Collect all transform events. UNBOUNDED — there is no
    // principled cap on the NUMBER of distinct transforms a program may define.
    // The only legitimate guard against runaway transformation is the fixpoint
    // circuit-breaker in transform_pass_runner.zig (MAX_ITERATIONS), which
    // catches a transform that never reaches a fixed point. This used to be a
    // fixed `[16]TransformEvent` array whose `transform_count < 16` guard
    // SILENTLY dropped every handler past the 16th (incl. ~3 implicit ones) —
    // leaving those invocations un-transformed and tripping KORU022 at the call
    // site. Pinned by 220_013_many_transforms_no_cap.
    var transform_events = std.ArrayList(TransformEvent){};
    defer transform_events.deinit(allocator);

    // A module can arrive more than once in the AST (companion .k/.kz facets
    // loaded through different paths); each copy carries the same events, so
    // the same stub_name would be emitted as a duplicate handler + table entry.
    var seen_stubs = std.StringHashMap(void).init(allocator);
    defer seen_stubs.deinit();

    for (source_file.items) |item| {
        if (item == .event_decl) {
            const event_decl = item.event_decl;

            // TYPE-DRIVEN DETECTION: Check if this event consumes AST types
            // Events with *const Invocation or *const Item are transform handlers
            // Events with *const EventDecl are derive handlers (operate on declarations)
            // The frontend is agnostic to [transform]/[derive] annotations - that's backend dispatch
            const scan = try scanTransformParams(allocator, event_decl.input.fields);

            // Events consuming AST types must be emitted to backend
            // *const Item also indicates a transform handler (needs to access flow from item)
            const consumes_ast_types = scan.has_invocation_param or scan.has_item_param or scan.has_event_decl_param;

            // VALIDATION: AST-consuming handlers must be available at compile-time
            if (consumes_ast_types and !scan.has_source_param and !scan.has_expression_param) {
                const has_comptime = annotation_parser.hasPart(event_decl.annotations, "comptime");
                if (!has_comptime) {
                    const event_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);
                    defer allocator.free(event_name);

                    const handler_type = if (scan.has_event_decl_param) "derive" else "transform";
                    log.err("\nERROR: Event '{s}' consumes *const {s} but won't be emitted to backend\n", .{ event_name, if (scan.has_event_decl_param) "EventDecl" else "Invocation" });
                    log.err("\n", .{});
                    log.err("AST-consuming handlers must be available at compile-time. Add [comptime]:\n", .{});
                    log.err("  ~[comptime] event {s} {{ ... }}\n", .{event_name});
                    log.err("\n", .{});
                    _ = handler_type;
                    return error.TransformMissingComptimeAnnotation;
                }
            }

            // Emit handlers for events that consume AST types
            const should_generate_handler = consumes_ast_types;

            if (should_generate_handler) {
                const stub_name = try joinPathSegments(allocator, event_decl.path.segments);
                const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                const param_names = scanParamNames(event_decl.input.fields);

                // Detect what this event returns (check branches)
                const transform_flags = scanTransformFlags(event_decl);
                const returns_program = transform_flags.returns_program;
                const has_failed = transform_flags.has_failed;
                const failed_is_identity = transform_flags.failed_is_identity;
                const has_compile_error = transform_flags.has_compile_error;

                const claims_descendants = annotation_parser.hasPart(event_decl.annotations, "claims_descendants");
                const stage_name: []const u8 = if (annotation_parser.hasPart(event_decl.annotations, "pre_late")) "pre_late" else if (annotation_parser.hasPart(event_decl.annotations, "pre")) "pre" else if (annotation_parser.hasPart(event_decl.annotations, "post")) "post" else "main";

                // Collect variant targets across the whole program (top-level event, so
                // variants may live in any module that implements it).
                const variant_targets_top = try collectVariantTargetsForEventPath(allocator, source_file.items, event_decl.path.segments, comptime_default_lang);

                const stub_gop = try seen_stubs.getOrPut(stub_name);
                if (stub_gop.found_existing) continue;

                try transform_events.append(allocator, .{
                    .stub_name = stub_name,
                    .match_name = match_name,
                    .event_name = stub_name, // For top-level, stub_name = event_name
                    .module_path = null, // Top-level events are in main_module
                    .claims_descendants = claims_descendants,
                    .stage = stage_name,
                    .has_source = scan.has_source_param,
                    .source_optional = scan.source_optional_param,
                    .has_expression = scan.has_expression_param,
                    .has_optional_expression = scan.has_optional_expression_param,
                    .expression_field_name = scan.expression_field_name_param,
                    .expression_field_names = scan.expression_field_names_list.items,
                    .has_invocation = scan.has_invocation_param,
                    .has_event_decl = scan.has_event_decl_param,
                    .has_item = scan.has_item_param,
                    .has_program_ast = param_names.has_program_ast,
                    .has_ctx = param_names.has_ctx,
                    .has_reporter = param_names.has_reporter,
                    .has_allocator = param_names.has_allocator,
                    .has_event_name_field = param_names.has_event_name_field,
                    .has_compile_error = has_compile_error,
                    .returns_program = returns_program,
                    .bare_return = event_decl.return_type != null and
                        emitter_helpers.findTransformProc(source_file.items, event_decl.path.segments) == null,
                    .has_failed = has_failed,
                    .failed_is_identity = failed_is_identity,
                    .variant_targets = variant_targets_top,
                });
            }
        }

        // Also check for handlers in imported modules (same type-driven detection)
        if (item == .module_decl) {
            const module = item.module_decl;
            for (module.items) |mod_item| {
                if (mod_item == .event_decl) {
                    const event_decl = mod_item.event_decl;

                    // TYPE-DRIVEN DETECTION: Check if this event consumes AST types
                    var scan = try scanTransformParams(allocator, event_decl.input.fields);

                    // PROC-TRANSFORM DETECTION: `~[transform]proc <event>` on an
                    // ordinary event. The event declares the USER surface (payload +
                    // branch contract, checked by the shape checker like any event);
                    // the machine interface is the proc-return convention:
                    // (invocation, item, program, allocator) → transformed SiteResult.
                    // Imported-module transforms dispatch QUALIFIED-ONLY,
                    // except globs. Keyword tors are qualified too: the inner
                    // `test` pass keyword-resolves the cloned body so `assert`
                    // arrives as `std.testing:assert` (395_001). A keyword
                    // that is also a [transform]proc was already qualified
                    // (store:take vs string:take). Never capture a sibling
                    // module's same-named event.
                    const has_transform_proc = emitter_helpers.findTransformProc(module.items, event_decl.path.segments) != null;
                    if (has_transform_proc) {
                        scan.has_invocation_param = true;
                        scan.has_item_param = true;
                        // Machine convention is the WHOLE Input: user-surface
                        // fields (Source blocks, expressions) ride the
                        // invocation's args, never the handler Input struct
                        // (emitTransformProcEventStruct emits machine fields
                        // only — a wrapper passing .source would not compile).
                        scan.has_source_param = false;
                        scan.source_optional_param = false;
                        scan.has_expression_param = false;
                        scan.has_optional_expression_param = false;
                        scan.expression_field_names_list.clearRetainingCapacity();
                    }

                    // Emit handlers for events that consume AST types
                    const should_generate_handler = scan.has_invocation_param or scan.has_item_param or scan.has_event_decl_param;

                    if (should_generate_handler) {
                        const event_name = try joinPathSegments(allocator, event_decl.path.segments);
                        // Note: don't free event_name - it's stored in transform_events
                        const match_name = try joinPathSegmentsWithDots(allocator, event_decl.path.segments);

                        // Build module path: "std.control" -> "koru_std.control"
                        const module_path = try codegen_utils.buildKoruModulePath(allocator, module.logical_name);

                        // Stub-naming suffix: "std.X" -> "X", "std" -> "", "other" -> "other"
                        const module_name: []const u8 = if (std.mem.startsWith(u8, module.logical_name, "std."))
                            module.logical_name[4..]
                        else if (std.mem.eql(u8, module.logical_name, "std"))
                            ""
                        else
                            module.logical_name;

                        // Build unique stub name: module_name + "_" + event_name
                        // e.g., "control_if" or "compiler_requirements_requires"
                        var stub_name_buf: [256]u8 = undefined;
                        var stub_name_len: usize = 0;

                        // Replace dots with underscores in module_name
                        for (module_name) |c| {
                            stub_name_buf[stub_name_len] = if (c == '.') '_' else c;
                            stub_name_len += 1;
                        }
                        if (stub_name_len > 0) {
                            stub_name_buf[stub_name_len] = '_';
                            stub_name_len += 1;
                        }
                        @memcpy(stub_name_buf[stub_name_len .. stub_name_len + event_name.len], event_name);
                        stub_name_len += event_name.len;

                        const stub_name = try allocator.dupe(u8, stub_name_buf[0..stub_name_len]);

                        var param_names = scanParamNames(event_decl.input.fields);

                        if (has_transform_proc) {
                            // Machine params come from the proc convention,
                            // not the event's (user-surface) fields.
                            param_names.has_program_ast = true;
                            param_names.has_allocator = true;
                        }

                        // Detect return type
                        const transform_flags = scanTransformFlags(event_decl);
                        var returns_program = transform_flags.returns_program;
                        const has_failed = transform_flags.has_failed;
                        const failed_is_identity = transform_flags.failed_is_identity;
                        const has_compile_error = transform_flags.has_compile_error;

                        if (has_transform_proc) {
                            // Proc-transforms return `transformed SiteResult` by
                            // convention; the event's branches are the user contract.
                            returns_program = true;
                        }

                        const claims_descendants = annotation_parser.hasPart(event_decl.annotations, "claims_descendants");
                        const stage_name: []const u8 = if (annotation_parser.hasPart(event_decl.annotations, "pre_late")) "pre_late" else if (annotation_parser.hasPart(event_decl.annotations, "pre")) "pre" else if (annotation_parser.hasPart(event_decl.annotations, "post")) "post" else "main";

                        // Collect variant targets from the same module (variants live alongside the event).
                        const variant_targets_mod = try collectVariantTargetsForEventPath(allocator, module.items, event_decl.path.segments, comptime_default_lang);

                        // NOTE: construct the struct in a named local BEFORE appending.
                        // Inlining this literal as the append() argument tripped a
                        // result-location aggregate-init miscompile on x86_64 (a `try`
                        // in `.qualifier` perturbs the init), silently dropping
                        // `.has_source`/`.has_expression` for print.blk/test → emitted
                        // Input literals missing the required `.source` field. See the
                        // x86 Linux drag-race build failure.
                        const is_glob = std.mem.indexOfScalar(u8, match_name, '*') != null;
                        const qualifier_val: ?[]const u8 = if (has_transform_proc or !is_glob)
                            try allocator.dupe(u8, module.logical_name)
                        else
                            null;
                        const new_te: TransformEvent = .{
                            .stub_name = stub_name,
                            .match_name = match_name,
                            .event_name = event_name, // Original event name for handler lookup
                            .module_path = module_path,
                            .claims_descendants = claims_descendants,
                            .stage = stage_name,
                            .has_source = scan.has_source_param,
                            .source_optional = scan.source_optional_param,
                            .has_expression = scan.has_expression_param,
                            .has_optional_expression = scan.has_optional_expression_param,
                            .expression_field_name = scan.expression_field_name_param,
                            .expression_field_names = scan.expression_field_names_list.items,
                            .has_invocation = scan.has_invocation_param,
                            .has_event_decl = scan.has_event_decl_param,
                            .has_item = scan.has_item_param,
                            .has_program_ast = param_names.has_program_ast,
                            .has_ctx = param_names.has_ctx,
                            .has_reporter = param_names.has_reporter,
                            .has_allocator = param_names.has_allocator,
                            .has_event_name_field = param_names.has_event_name_field,
                            .has_compile_error = has_compile_error,
                            .returns_program = returns_program,
                            .bare_return = event_decl.return_type != null and !has_transform_proc,
                            .has_failed = has_failed,
                            .failed_is_identity = failed_is_identity,
                            .qualifier = qualifier_val,
                            .variant_targets = variant_targets_mod,
                        };
                        const stub_gop = try seen_stubs.getOrPut(stub_name);
                        if (stub_gop.found_existing) continue;
                        try transform_events.append(allocator, new_te);
                    }
                }
            }
        }
    }

    // Cleanup allocated names when we're done
    defer {
        for (transform_events.items) |event| {
            allocator.free(event.stub_name);
            allocator.free(event.match_name);
            allocator.free(event.event_name);
            if (event.module_path) |mp| {
                allocator.free(mp);
            }
            if (event.qualifier) |q| {
                allocator.free(q);
            }
            for (event.variant_targets) |t| allocator.free(t);
            allocator.free(event.variant_targets);
        }
    }

    if (transform_events.items.len == 0) return 0; // No transforms, nothing to generate

    // Generate helper and handlers
    var buf: [4096]u8 = undefined;

    // Import necessary types at the top level
    try code_emitter.write("// Transform handler imports\n");
    try code_emitter.write("const transform_std = __koru_std;\n");
    try code_emitter.write("const Arg = __koru_ast.Arg;\n");
    try code_emitter.write("const Flow = __koru_ast.Flow;\n");
    try code_emitter.write("const SiteResult = __koru_ast.SiteResult;\n\n");

    // Helper to extract Source from flow arguments
    try code_emitter.write("// Helper: Extract Source struct from flow arguments\n");
    try code_emitter.write("fn extractSourceFromArgs(args: []const Arg) ?__koru_ast.Source {\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (arg.source_value) |source| {\n");
    try code_emitter.write("            return source.*;  // Return full Source struct\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    return null;\n");
    try code_emitter.write("}\n\n");

    // Helper to extract Expression text from flow arguments
    try code_emitter.write("// Helper: Extract Expression text from flow arguments\n");
    try code_emitter.write("fn extractExprFromArgs(args: []const Arg) ?[]const u8 {\n");
    try code_emitter.write("    // First try: look for CapturedExpression\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (arg.expression_value) |expr| {\n");
    try code_emitter.write("            return expr.text;  // Return expression text\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    // Fallback: use first arg's value directly\n");
    try code_emitter.write("    // This handles pipeline invocations where expression_value wasn't captured\n");
    try code_emitter.write("    if (args.len > 0 and args[0].value.len > 0) {\n");
    try code_emitter.write("        return args[0].value;\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    return null;\n");
    try code_emitter.write("}\n\n");
    // Named variant for multi-Expression handlers: the named arg wins, else
    // the expr_idx-th expression arg positionally.
    try code_emitter.write("fn extractExprFromArgsNamed(args: []const Arg, name: []const u8, expr_idx: usize) ?[]const u8 {\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (arg.name.len > 0 and __koru_std.mem.eql(u8, arg.name, name)) {\n");
    try code_emitter.write("            if (arg.expression_value) |expr| return expr.text;\n");
    try code_emitter.write("            if (arg.value.len > 0) return arg.value;\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    var seen: usize = 0;\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (seen == expr_idx) {\n");
    try code_emitter.write("            if (arg.expression_value) |expr| return expr.text;\n");
    try code_emitter.write("            if (arg.value.len > 0) return arg.value;\n");
    try code_emitter.write("            return null;\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("        seen += 1;\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    return null;\n");
    try code_emitter.write("}\n\n");
    // Strict variant for ?Expression parameters: presence = provided
    try code_emitter.write("fn extractOptionalExprFromArgs(args: []const Arg) ?[]const u8 {\n");
    try code_emitter.write("    for (args) |arg| {\n");
    try code_emitter.write("        if (arg.expression_value) |expr| {\n");
    try code_emitter.write("            return expr.text;\n");
    try code_emitter.write("        }\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    // Cloned/grafted invocations carry the arg as value text — the clone\n");
    try code_emitter.write("    // drops expression_value (210_199). An arg with text was provided.\n");
    try code_emitter.write("    if (args.len > 0 and args[0].value.len > 0) {\n");
    try code_emitter.write("        return args[0].value;\n");
    try code_emitter.write("    }\n");
    try code_emitter.write("    return null;\n");
    try code_emitter.write("}\n\n");

    // Individual stubs - called on flows that invoke transform events
    // NEW: Uses unified ASTNode interface - handlers receive (node, program, allocator)
    for (transform_events.items) |event| {
        const stub = try std.fmt.bufPrint(&buf, "// Transform handler for: {s}\n", .{event.stub_name});
        try code_emitter.write(stub);
        // Handler type determined by parameter: *const Invocation = transform, *const EventDecl = derive
        if (event.has_event_decl) {
            try code_emitter.write("// Derive handler: called when [derive(X)] is found on an event declaration\n");
        } else {
            try code_emitter.write("// Transform handler: called when a flow invokes this transform event\n");
        }
        try code_emitter.write("// Uses unified ASTNode interface for generic AST traversal\n");

        // Function signature
        var stub_ident_buf: [256]u8 = undefined;
        const stub_ident = lowerKebabIdent(&stub_ident_buf, event.stub_name);
        const fn_sig = try std.fmt.bufPrint(&buf, "fn call_handler_{s}(node: __koru_ast.ASTNode, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, __koru_ctx: ?*anyopaque) !__koru_ast.SiteResult {{\n", .{stub_ident});
        try code_emitter.write(fn_sig);

        // Extract the appropriate data from the node based on handler type
        if (event.has_event_decl) {
            // Derive handler: extract event_decl from the item
            try code_emitter.write("    // Extract event declaration from node\n");
            try code_emitter.write("    const event_decl = if (node == .item and node.item.* == .event_decl) &node.item.event_decl else {\n");
            try code_emitter.write("        log.debug(\"ERROR: Derive handler called with non-event_decl node\\n\", .{});\n");
            try code_emitter.write("        @panic(\"derive: expected event_decl node\");\n");
            try code_emitter.write("    };\n");
        } else if (event.has_invocation or event.has_item) {
            // Transform handler: node is always an invocation for invocation-based transforms
            try code_emitter.write("    const invocation = node.invocation;\n");

            // If handler needs item, find it using ASTNode helper
            if (event.has_item) {
                try code_emitter.write("    const item = __koru_ast.ASTNode.findContainingItem(program, invocation) orelse {\n");
                try code_emitter.write("        log.debug(\"ERROR: Could not find containing item for invocation\\n\", .{});\n");
                try code_emitter.write("        @panic(\"transform: invocation not found in program\");\n");
                try code_emitter.write("    };\n");
            }
        }

        if (!event.has_allocator) {
            try code_emitter.write("    _ = allocator;\n");
        }
        if (!event.has_ctx and !event.has_reporter) {
            try code_emitter.write("    _ = __koru_ctx;\n");
        }
        // Only discard program if we don't use it anywhere
        if (!event.has_program_ast and !event.has_source and !event.has_expression and !event.has_item and !event.has_event_decl) {
            try code_emitter.write("    _ = program;\n");
        }

        // DEBUG: Show what we're processing
        if (event.has_event_decl) {
            const debug_derive = try std.fmt.bufPrint(&buf, "    log.debug(\"[DERIVE] {s}: processing event declaration\\n\", .{{}});\n", .{event.stub_name});
            try code_emitter.write(debug_derive);
        } else if (event.has_invocation or event.has_item) {
            const debug_count = try std.fmt.bufPrint(&buf, "    log.debug(\"[TRANSFORM] {s}: {{d}} args\\n\", .{{invocation.args.len}});\n", .{event.stub_name});
            try code_emitter.write(debug_count);
            try code_emitter.write("    for (invocation.args, 0..) |arg, i| {\n");
            try code_emitter.write("        log.debug(\"  Arg[{d}]: name='{s}' has_source={} has_expr={}\\n\", .{i, arg.name, arg.source_value != null, arg.expression_value != null});\n");
            try code_emitter.write("    }\n");
        }

        // Generate handler call
        // Use event_name (original name) for handler struct lookup, not stub_name (prefixed for uniqueness)
        var event_ident_buf: [256]u8 = undefined;
        const event_ident = lowerKebabIdent(&event_ident_buf, event.event_name);
        if (event.module_path) |mp| {
            // `module_path` is already koru_-prefixed per segment (the
            // codegen_utils.buildKoruModulePath spelling, e.g.
            // "koru_lib.koru_my-module"). What remains is the emitter's
            // escaping: hyphenated/keyword segments emit as @"..." (the
            // writeModulePath rule) — NOT lowerKebabIdent, which underscores
            // hyphenated segments the emitter keeps escaped. The mismatch
            // was a backend error naming a struct member that does not exist
            // (220_036: a transform event in a hyphenated module imported
            // through an aliased path).
            var mp_ident_buf: [512]u8 = undefined;
            var mp_len: usize = 0;
            var mp_first = true;
            var mp_segs = std.mem.splitScalar(u8, mp, '.');
            while (mp_segs.next()) |seg| {
                if (!mp_first) {
                    mp_ident_buf[mp_len] = '.';
                    mp_len += 1;
                }
                if (codegen_utils.needsEscaping(seg)) {
                    mp_ident_buf[mp_len] = '@';
                    mp_ident_buf[mp_len + 1] = '"';
                    mp_len += 2;
                    @memcpy(mp_ident_buf[mp_len .. mp_len + seg.len], seg);
                    mp_len += seg.len;
                    mp_ident_buf[mp_len] = '"';
                    mp_len += 1;
                } else {
                    @memcpy(mp_ident_buf[mp_len .. mp_len + seg.len], seg);
                    mp_len += seg.len;
                }
                mp_first = false;
            }
            const mp_ident = mp_ident_buf[0..mp_len];
            const handler_line = try std.fmt.bufPrint(&buf, "    const handler = {s}.{s}_event;\n", .{ mp_ident, event_ident });
            try code_emitter.write(handler_line);
        } else {
            const handler_line = try std.fmt.bufPrint(&buf, "    const handler = main_module.{s}_event;\n", .{event_ident});
            try code_emitter.write(handler_line);
        }

        // Derive handlers have simpler input (no Source/Expression extraction)
        if (event.has_event_decl) {
            // Derive handler: build Input with event_decl
            try code_emitter.write("    const input = handler.Input{\n");
            try code_emitter.write("        .event_decl = event_decl,\n");
            if (event.has_program_ast) {
                try code_emitter.write("        .program = program,\n");
            }
            if (event.has_ctx) {
                const ctx_line = try std.fmt.bufPrint(&buf, "        .ctx = @ptrCast(@alignCast(__koru_ctx orelse @panic(\"derive '{s}' declares ctx: *CompilerContext but was invoked from a path that carries no compilation context\"))),\n", .{event.match_name});
                try code_emitter.write(ctx_line);
            }
            if (event.has_reporter) {
                const reporter_line = try std.fmt.bufPrint(&buf, reporter_inject_fmt, .{ "        ", "derive", event.match_name, "derive", event.match_name });
                try code_emitter.write(reporter_line);
            }
            if (event.has_allocator) {
                try code_emitter.write("        .allocator = allocator,\n");
            }
            try code_emitter.write("    };\n");

            // Call handler and return result
            if (event.returns_program and event.bare_return) {
                // Bare-return decl (`-> SiteResult`): the handler's Output IS
                // SiteResult — no union to unwrap.
                try code_emitter.write("    return handler.handler(input);\n");
            } else if (event.returns_program) {
                try code_emitter.write("    const result = handler.handler(input);\n");
                try code_emitter.write("    return switch (result) {\n");
                try code_emitter.write("        .transformed => |t| t,\n");
                if (event.has_failed) {
                    try code_emitter.write("        .failed => |f| {\n");
                    if (event.failed_is_identity) {
                        // Identity branch: f IS the error message directly
                        try code_emitter.write("            log.debug(\"Derive failed: {s}\\n\", .{f});\n");
                    } else {
                        // Struct branch: f.error contains the message
                        try code_emitter.write("            log.debug(\"Derive failed: {s}\\n\", .{f.@\"error\"});\n");
                    }
                    try code_emitter.write("            return error.DeriveFailed;\n");
                    try code_emitter.write("        },\n");
                }
                try code_emitter.write("    };\n");
            } else {
                try code_emitter.write("    _ = handler.handler(input);\n");
                try code_emitter.write("    return program;\n");
            }
        } else {
            // Transform handler: extract Source and/or Expression as needed
            if (event.has_source) {
                try code_emitter.write("    const source_opt = extractSourceFromArgs(invocation.args);\n");
            }

            const multi_expr = event.expression_field_names.len > 1;
            if (multi_expr) {
                for (event.expression_field_names, 0..) |fname, i| {
                    const eline = try std.fmt.bufPrint(&buf, "    const expr_{d} = extractExprFromArgsNamed(invocation.args, \"{s}\", {d});\n", .{ i, fname, i });
                    try code_emitter.write(eline);
                }
            } else if (event.has_expression) {
                try code_emitter.write("    const expr_opt = extractExprFromArgs(invocation.args);\n");
            }

            // Build guard condition and input based on what's required
            // `source: ?Source` is the blockless-declaring form: it is always
            // extracted and passed through (null when no block), but it never
            // joins the guard — the handler fires on a bare invocation and
            // reads `source` as an optional.
            const src_required = event.has_source and !event.source_optional;
            if (multi_expr) {
                // Multi-Expression handler: every required Expression param
                // must extract (named arg wins, positional fallback).
                try code_emitter.write("    if (");
                if (src_required) {
                    try code_emitter.write("source_opt != null and ");
                }
                for (event.expression_field_names, 0..) |_, i| {
                    if (i > 0) try code_emitter.write(" and ");
                    const g = try std.fmt.bufPrint(&buf, "expr_{d} != null", .{i});
                    try code_emitter.write(g);
                }
                try code_emitter.write(") {\n");
                if (src_required) {
                    try code_emitter.write("        const source = source_opt.?;\n");
                }
                try code_emitter.write("        const input = handler.Input{\n");
                if (event.has_source) {
                    try code_emitter.write(if (src_required) "            .source = source,\n" else "            .source = source_opt,\n");
                }
                for (event.expression_field_names, 0..) |fname, i| {
                    try code_emitter.write("            .");
                    try emitter_helpers.writeBranchName(code_emitter, fname);
                    const v = try std.fmt.bufPrint(&buf, " = expr_{d}.?,\n", .{i});
                    try code_emitter.write(v);
                }
            } else if (event.has_source and event.has_expression) {
                try code_emitter.write(if (src_required) "    if (source_opt != null and expr_opt != null) {\n" else "    if (expr_opt != null) {\n");
                if (src_required) {
                    try code_emitter.write("        const source = source_opt.?;\n");
                }
                try code_emitter.write("        const expr_text = expr_opt.?;\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write(if (src_required) "            .source = source,\n" else "            .source = source_opt,\n");
                try code_emitter.write("            .");
                try code_emitter.write(event.expression_field_name orelse "expr");
                try code_emitter.write(" = expr_text,\n");
            } else if (event.has_source and event.has_optional_expression) {
                try code_emitter.write(if (src_required) "    if (source_opt) |source| {\n" else "    {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write(if (src_required) "            .source = source,\n" else "            .source = source_opt,\n");
                try code_emitter.write("            .");
                try code_emitter.write(event.expression_field_name orelse "expr");
                try code_emitter.write(" = extractOptionalExprFromArgs(invocation.args),\n");
            } else if (event.has_source) {
                try code_emitter.write(if (src_required) "    if (source_opt) |source| {\n" else "    {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write(if (src_required) "            .source = source,\n" else "            .source = source_opt,\n");
            } else if (event.has_optional_expression) {
                try code_emitter.write("    {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .");
                try code_emitter.write(event.expression_field_name orelse "expr");
                try code_emitter.write(" = extractOptionalExprFromArgs(invocation.args),\n");
            } else if (event.has_expression) {
                try code_emitter.write("    if (expr_opt) |expr_text| {\n");
                try code_emitter.write("        const input = handler.Input{\n");
                try code_emitter.write("            .");
                try code_emitter.write(event.expression_field_name orelse "expr");
                try code_emitter.write(" = expr_text,\n");
            } else {
                try code_emitter.write("    {\n");
                try code_emitter.write("        const input = handler.Input{\n");
            }

            // Add remaining Input fields
            if (event.has_item) {
                try code_emitter.write("            .item = item,\n");
            }
            if (event.has_invocation) {
                try code_emitter.write("            .invocation = invocation,\n");
            }
            if (event.has_program_ast) {
                try code_emitter.write("            .program = program,\n");
            }
            if (event.has_ctx) {
                const ctx_line = try std.fmt.bufPrint(&buf, "            .ctx = @ptrCast(@alignCast(__koru_ctx orelse @panic(\"transform '{s}' declares ctx: *CompilerContext but was invoked from a path that carries no compilation context\"))),\n", .{event.match_name});
                try code_emitter.write(ctx_line);
            }
            if (event.has_reporter) {
                const reporter_line = try std.fmt.bufPrint(&buf, reporter_inject_fmt, .{ "            ", "transform", event.match_name, "transform", event.match_name });
                try code_emitter.write(reporter_line);
            }
            if (event.has_allocator) {
                try code_emitter.write("            .allocator = allocator,\n");
            }
            if (event.has_event_name_field) {
                // Build event_name from invocation path segments (e.g., "log.warning" from log.* match)
                try code_emitter.write("            .event_name = blk: {\n");
                try code_emitter.write("                var name_buf: [256]u8 = undefined;\n");
                try code_emitter.write("                var name_len: usize = 0;\n");
                try code_emitter.write("                for (invocation.path.segments, 0..) |seg, i| {\n");
                try code_emitter.write("                    if (i > 0) {\n");
                try code_emitter.write("                        name_buf[name_len] = '.';\n");
                try code_emitter.write("                        name_len += 1;\n");
                try code_emitter.write("                    }\n");
                try code_emitter.write("                    @memcpy(name_buf[name_len..name_len + seg.len], seg);\n");
                try code_emitter.write("                    name_len += seg.len;\n");
                try code_emitter.write("                }\n");
                try code_emitter.write("                break :blk name_buf[0..name_len];\n");
                try code_emitter.write("            },\n");
            }

            // Call handler and handle result
            try code_emitter.write("        };\n");
            if (event.returns_program) {
                if (event.variant_targets.len > 0) {
                    // Variant dispatch: select handler__<variant> based on
                    // explicit invocation.variant or build-time registry lookup.
                    var canonical_buf: [256]u8 = undefined;
                    var canonical_len: usize = 0;
                    if (event.module_path) |mp| {
                        const stripped = if (std.mem.startsWith(u8, mp, "koru_")) mp[5..] else mp;
                        @memcpy(canonical_buf[canonical_len .. canonical_len + stripped.len], stripped);
                        canonical_len += stripped.len;
                        canonical_buf[canonical_len] = ':';
                        canonical_len += 1;
                    }
                    @memcpy(canonical_buf[canonical_len .. canonical_len + event.match_name.len], event.match_name);
                    canonical_len += event.match_name.len;
                    const canonical_name = canonical_buf[0..canonical_len];

                    try code_emitter.write("        const __variant_opt: ?[]const u8 = blk: {\n");
                    try code_emitter.write("            if (invocation.variant) |v| break :blk v;\n");
                    // Lang auto-select: when CompilerEnv.lang matches a variant's
                    // base tag, prefer it. Matches the runtime emitters' tag-based
                    // selection (js_emitter.zig:165, visitor_emitter analog). Base
                    // tag strips `(args)`, so `|zig(optimized)` matches lang "zig".
                    // Falls through to the platform registry below when no variant
                    // base matches the target language.
                    for (event.variant_targets) |target| {
                        var base_len: usize = target.len;
                        if (std.mem.indexOfScalar(u8, target, '(')) |paren_idx| {
                            base_len = paren_idx;
                        }
                        const base = target[0..base_len];
                        const auto_line = try std.fmt.bufPrint(&buf, "            if (__koru_std.mem.eql(u8, CompilerEnv.lang, \"{s}\")) break :blk \"{s}\";\n", .{ base, target });
                        try code_emitter.write(auto_line);
                    }
                    const lookup_line = try std.fmt.bufPrint(&buf, "            if (__koru_emitter_helpers.getVariant(\"{s}\")) |v| break :blk v;\n", .{canonical_name});
                    try code_emitter.write(lookup_line);
                    try code_emitter.write("            break :blk null;\n");
                    try code_emitter.write("        };\n");

                    // Loud wall (KORU122): a selected variant that matches NO
                    // declared variant proc must never silently fall back to the
                    // default body — a transform "running" through the wrong
                    // machinery is a lying green. Names the declared variants.
                    try code_emitter.write("        if (__variant_opt) |__v| {\n");
                    try code_emitter.write("            const __koru_declared = [_][]const u8{");
                    for (event.variant_targets, 0..) |target, ti| {
                        const decl_entry = try std.fmt.bufPrint(&buf, "{s} \"{s}\"", .{ if (ti > 0) "," else "", target });
                        try code_emitter.write(decl_entry);
                    }
                    try code_emitter.write(" };\n");
                    try code_emitter.write("            var __koru_variant_known = false;\n");
                    try code_emitter.write("            for (__koru_declared) |__t| {\n");
                    try code_emitter.write("                if (__koru_std.mem.eql(u8, __v, __t)) __koru_variant_known = true;\n");
                    try code_emitter.write("            }\n");
                    try code_emitter.write("            if (!__koru_variant_known) {\n");
                    var declared_list_buf: [512]u8 = undefined;
                    var declared_list_len: usize = 0;
                    for (event.variant_targets) |target| {
                        const piece = std.fmt.bufPrint(declared_list_buf[declared_list_len..], " |{s}", .{target}) catch break;
                        declared_list_len += piece.len;
                    }
                    const wall_msg = try std.fmt.allocPrint(allocator,
                        \\                __koru_std.debug.print("error[KORU122]: transform `{s}` has no `|{{s}}` variant — the call site (or build config) selects one\n  declared variants:{s}\n  a `|variant` tag on a transform invocation selects the variant that produces that output; it never falls back to the default body\n  fix: declare `~proc {s}|{{s}} {{{{ ... }}}}` next to the existing variants, or drop the tag\n", .{{ __v, __v }});
                        \\
                    , .{ canonical_name, declared_list_buf[0..declared_list_len], event.match_name });
                    defer allocator.free(wall_msg);
                    try code_emitter.write(wall_msg);
                    try code_emitter.write("                __koru_std.process.exit(1);\n");
                    try code_emitter.write("            }\n");
                    try code_emitter.write("        }\n");

                    try code_emitter.write("        const result = if (__variant_opt) |__v| (");
                    for (event.variant_targets) |target| {
                        const mangled = try emitter_helpers.mangleVariant(allocator, target);
                        defer allocator.free(mangled);
                        const branch = try std.fmt.bufPrint(&buf, "if (__koru_std.mem.eql(u8, __v, \"{s}\")) handler.handler__{s}(input) else ", .{ target, mangled });
                        try code_emitter.write(branch);
                    }
                    try code_emitter.write("handler.handler(input))");
                    try code_emitter.write(" else handler.handler(input);\n");
                } else {
                    // Same wall for a transform with NO variant procs: a call-site
                    // `|variant` tag must not be silently ignored (KORU122).
                    try code_emitter.write("        if (invocation.variant) |__v| {\n");
                    const no_variants_msg = try std.fmt.allocPrint(allocator,
                        \\            __koru_std.debug.print("error[KORU122]: transform `{s}` declares no variants, but the call site selects `|{{s}}`\n  fix: declare `~proc {s}|{{s}} {{{{ ... }}}}` next to the transform, or drop the tag\n", .{{ __v, __v }});
                        \\
                    , .{ event.match_name, event.match_name });
                    defer allocator.free(no_variants_msg);
                    try code_emitter.write(no_variants_msg);
                    try code_emitter.write("            __koru_std.process.exit(1);\n");
                    try code_emitter.write("        }\n");
                    try code_emitter.write("        const result = handler.handler(input);\n");
                }
                if (event.bare_return) {
                    // Bare-return decl (`-> SiteResult`): the handler's Output
                    // IS SiteResult — no union to unwrap.
                    try code_emitter.write("        return result;\n");
                } else {
                    try code_emitter.write("        return switch (result) {\n");
                    try code_emitter.write("            .transformed => |t| t,\n");
                    if (event.has_failed) {
                        try code_emitter.write("            .failed => |f| {\n");
                        if (event.failed_is_identity) {
                            // Identity branch: f IS the error message directly
                            try code_emitter.write("                log.debug(\"Transform failed: {s}\\n\", .{f});\n");
                        } else {
                            // Struct branch: f.error contains the message
                            try code_emitter.write("                log.debug(\"Transform failed: {s}\\n\", .{f.@\"error\"});\n");
                        }
                        try code_emitter.write("                return error.TransformFailed;\n");
                        try code_emitter.write("            },\n");
                    }
                    if (event.has_compile_error) {
                        try code_emitter.write("            .compile_error => |ce| {\n");
                        try code_emitter.write("                log.debug(\"Compile error: {s}\\n\", .{ce.message});\n");
                        try code_emitter.write("                return error.CompileError;\n");
                        try code_emitter.write("            },\n");
                    }
                    try code_emitter.write("        };\n");
                }
            } else {
                try code_emitter.write("        _ = handler.handler(input);\n");
                try code_emitter.write("        return .{};  // Source-capture events don't modify the program\n");
            }
        }

        // Close guard and add else case if needed (only for transform handlers, not derive)
        // An optional `?Source` (and optional-only expressions) emits a bare
        // `{` — there is no guard to else, and no args can be "not present".
        if (!event.has_event_decl) {
            if ((event.has_source and !event.source_optional) or event.has_expression) {
                try code_emitter.write("    } else {\n");
                try code_emitter.write("        return .{};  // Required args not present, no change\n");
                try code_emitter.write("    }\n");
            } else {
                try code_emitter.write("    }\n");
            }
        }
        try code_emitter.write("}\n\n");
    }

    // Dispatcher - uses transform_pass_runner for proper recursive AST walking
    try code_emitter.write("// Transform Dispatcher - uses transform_pass_runner for proper recursive AST walking\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// CRITICAL: Transform execution order is SIGNIFICANT!\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// Transforms walk the AST in SOURCE ORDER and each transform receives the CURRENT state\n");
    try code_emitter.write("// of the AST (including modifications from previous transforms). This means:\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// 1. Dependencies must appear BEFORE dependents in source code\n");
    try code_emitter.write("// 2. Upstream transforms complete BEFORE downstream transforms run\n");
    try code_emitter.write("// 3. Type resolution via AST-walking sees the TRANSFORMED upstream AST\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// Example:\n");
    try code_emitter.write("//   ~getUserData() | data u |> renderHTML [HTML]{ $[u.name] }\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// If getUserData is also a transform, it runs FIRST (appears earlier in source),\n");
    try code_emitter.write("// then renderHTML sees the TRANSFORMED getUserData event when resolving 'u's type.\n");
    try code_emitter.write("//\n");
    try code_emitter.write("// This is why binding.type is \"unknown\" at parse time - type resolution happens\n");
    try code_emitter.write("// at transform time via ast_functional.resolveBindingType().\n");
    try code_emitter.write("pub fn run_pass(annotation: []const u8, program: *const __koru_ast.Program, allocator: transform_std.mem.Allocator, ctx: ?*anyopaque) !*__koru_ast.Program {\n");
    try code_emitter.write("    // The `annotation` names WHICH transform stage to run, so the pipeline can\n");
    try code_emitter.write("    // sprinkle named stages where they belong: \"pre\" / \"main\" / \"post\" run just\n");
    try code_emitter.write("    // that stage; anything else (e.g. \"transform\") runs all stages in order.\n");
    try code_emitter.write("    const __only_stage: ?@import(\"transform_pass_runner\").Stage =\n");
    try code_emitter.write("        if (transform_std.mem.eql(u8, annotation, \"pre\")) .pre\n");
    try code_emitter.write("        else if (transform_std.mem.eql(u8, annotation, \"pre_late\")) .pre_late\n");
    try code_emitter.write("        else if (transform_std.mem.eql(u8, annotation, \"main\")) .main\n");
    try code_emitter.write("        else if (transform_std.mem.eql(u8, annotation, \"post\")) .post\n");
    try code_emitter.write("        else null;\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // DUMP POINT 6: AST at run_pass() entry\n");
    try code_emitter.write("    dumpAST(program, \"6-run-pass-start\", allocator);\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // Build dispatch table for transform/derive handlers\n");
    try code_emitter.write("    // Handlers are Koru-defined events with *const Invocation or *const EventDecl params\n");
    try code_emitter.write("    const transform_pass_runner = @import(\"transform_pass_runner\");\n");
    try code_emitter.write("    const transforms = &[_]transform_pass_runner.TransformEntry{\n");

    // Generate dispatch table entries for Koru-defined handlers (both transform and derive)
    for (transform_events.items) |event| {
        var stub_ident_buf: [256]u8 = undefined;
        const stub_ident = lowerKebabIdent(&stub_ident_buf, event.stub_name);
        const entry_line = if (event.qualifier) |qualifier|
            try std.fmt.bufPrint(&buf, "        .{{ .name = \"{s}\", .qualifier = \"{s}\", .claims_descendants = {s}, .stage = .{s}, .handler_fn = call_handler_{s} }},\n", .{
                event.match_name,
                qualifier,
                if (event.claims_descendants) "true" else "false",
                event.stage,
                stub_ident,
            })
        else
            try std.fmt.bufPrint(&buf, "        .{{ .name = \"{s}\", .from_module = {s}, .claims_descendants = {s}, .stage = .{s}, .handler_fn = call_handler_{s} }},\n", .{
                event.match_name,
                if (event.module_path != null) "true" else "false",
                if (event.claims_descendants) "true" else "false",
                event.stage,
                stub_ident,
            });
        try code_emitter.write(entry_line);
    }

    try code_emitter.write("    };\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // Use transform_pass_runner for proper recursive AST walking\n");
    try code_emitter.write("    const result = try transform_pass_runner.walkAndTransformStages(program, transforms, allocator, __only_stage, ctx);\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    // DUMP POINT 7: AST at run_pass() exit (after all transforms)\n");
    try code_emitter.write("    dumpAST(result, \"7-run-pass-end\", allocator);\n");
    try code_emitter.write("    \n");
    try code_emitter.write("    return result;\n");
    try code_emitter.write("}\n\n");

    // Add alias for backward compatibility with backend.zig which imports process_all_transforms
    try code_emitter.write("// Alias for backward compatibility\n");
    try code_emitter.write("pub const process_all_transforms = run_pass;\n\n");

    return transform_events.items.len;
}

/// Helper: Join path segments with underscores for function names
/// Escapes glob characters: * -> _star_
/// Identifier formation boundary: names are kebab-canonical in the pipeline
/// and in ALL stored form — a dash becomes an underscore ONLY in the same
/// breath as writing a host-language identifier into generated code. Callers
/// take a lowered COPY at the write site; nothing stored is ever lowered.
fn lowerKebabIdent(buf: []u8, name: []const u8) []const u8 {
    @memcpy(buf[0..name.len], name);
    for (buf[0..name.len]) |*c| {
        if (c.* == '-') c.* = '_';
    }
    return buf[0..name.len];
}

/// Mangle a command handler's event name for Zig: kebab `-` → `_`. The module
/// emitter writes `pub const publish_npm_event` for an event named `publish-npm`
/// (mangled), while the command dispatcher's generated `{s}_event.handler` used
/// the raw `joinPathSegments` spelling — a kebab-named `[comptime|command]`
/// crossed a module boundary and the two drifted, emitting `publish-npm_event`
/// (invalid, undeclared) against the module's `publish_npm_event`. One mangle to
/// match the emitter, not a second spelling. (Same class as writeBranchName.)
fn mangleHandlerName(allocator: std.mem.Allocator, handler_name: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, handler_name.len);
    for (handler_name) |c| {
        try result.append(allocator, if (c == '-') '_' else c);
    }
    return result.toOwnedSlice(allocator);
}

/// Escape one name character into a Zig-identifier-safe sequence. `*` keeps
/// the established `_star_` spelling; the rest cover the bracket tails a
/// spellable declaration name may carry (`gemv.kernel[*]` — the
/// parameter-marker — `close[!]`, `name[T:u32]`, `name[T:u32;N=5]`).
fn escapeNameCharLen(c: u8) usize {
    const esc = escapeNameChar(c) orelse return 0;
    return esc.len - 1;
}

fn escapeNameChar(c: u8) ?[]const u8 {
    return switch (c) {
        '*' => "_star_",
        '[' => "_lb_",
        ']' => "_rb_",
        ':' => "_colon_",
        '!' => "_bang_",
        ';' => "_semi_",
        ',' => "_comma_",
        '=' => "_eq_",
        else => null,
    };
}

fn joinPathSegments(allocator: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    if (segments.len == 0) return try allocator.dupe(u8, "unknown");

    // Calculate total length, accounting for escaped characters
    var total_len: usize = 0;
    for (segments, 0..) |seg, i| {
        if (i > 0) total_len += 1; // underscore separator
        for (seg) |c| {
            total_len += escapeNameCharLen(c);
        }
        total_len += seg.len;
    }

    // Build result with escaping
    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (segments, 0..) |seg, i| {
        if (i > 0) {
            result[pos] = '_';
            pos += 1;
        }
        for (seg) |c| {
            if (escapeNameChar(c)) |esc| {
                @memcpy(result[pos..][0..esc.len], esc);
                pos += esc.len;
            } else {
                result[pos] = c;
                pos += 1;
            }
        }
    }

    return result[0..pos];
}

/// Helper: Join path segments with dots for event path matching
fn joinPathSegmentsWithDots(allocator: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    if (segments.len == 0) return try allocator.dupe(u8, "unknown");
    if (segments.len == 1) return try allocator.dupe(u8, segments[0]);

    // Calculate total length
    var total_len: usize = segments[0].len;
    for (segments[1..]) |seg| {
        total_len += 1 + seg.len; // dot + segment
    }

    // Build result
    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    @memcpy(result[pos .. pos + segments[0].len], segments[0]);
    pos += segments[0].len;

    for (segments[1..]) |seg| {
        result[pos] = '.';
        pos += 1;
        @memcpy(result[pos .. pos + seg.len], seg);
        pos += seg.len;
    }

    return result;
}

/// Match a pattern against a value using glob semantics
/// Patterns can use * for wildcards (e.g., log.* matches log.info)
/// Generate the visitor pattern backend
fn generateVisitorBackend(writer: anytype, allocator: std.mem.Allocator, source_file: *ast.Program, lang: []const u8) !void {
    _ = allocator;
    _ = source_file;

    // First, emit the visitor pattern infrastructure
    try writer.writeAll(
        \\// Visitor Pattern Backend Implementation
        \\const CodeEmitter = struct {
        \\    buffer: []u8,
        \\    pos: usize,
        \\    indent_level: u32,
        \\    indent_size: u32 = 4,
        \\
        \\    pub fn init(buffer: []u8) CodeEmitter {
        \\        return .{
        \\            .buffer = buffer,
        \\            .pos = 0,
        \\            .indent_level = 0,
        \\        };
        \\    }
        \\
        \\    pub fn write(self: *CodeEmitter, text: []const u8) !void {
        \\        if (self.pos + text.len >= self.buffer.len) {
        \\            return error.BufferOverflow;
        \\        }
        \\        @memcpy(self.buffer[self.pos..self.pos + text.len], text);
        \\        self.pos += text.len;
        \\    }
        \\
        \\    pub fn writeLine(self: *CodeEmitter, text: []const u8) !void {
        \\        try self.writeIndent();
        \\        try self.write(text);
        \\        try self.write("\n");
        \\    }
        \\
        \\    pub fn writeIndent(self: *CodeEmitter) !void {
        \\        const spaces = self.indent_level * self.indent_size;
        \\        var i: u32 = 0;
        \\        while (i < spaces) : (i += 1) {
        \\            try self.write(" ");
        \\        }
        \\    }
        \\
        \\    pub fn indent(self: *CodeEmitter) void {
        \\        self.indent_level += 1;
        \\    }
        \\
        \\    pub fn dedent(self: *CodeEmitter) void {
        \\        if (self.indent_level > 0) {
        \\            self.indent_level -= 1;
        \\        }
        \\    }
        \\
        \\    pub fn getOutput(self: *CodeEmitter) []const u8 {
        \\        return self.buffer[0..self.pos];
        \\    }
        \\};
        \\
        \\
    );

    // Generate the visitor implementation using the library
    // Import the emission libraries (emitter_helpers, visitor_emitter, tap_registry)
    if (true) { // Always generate the visitor implementation when in visitor mode
        // Import std and emission libraries (use module names, not file paths)
        try writer.writeAll("const std = @import(\"std\");\n");
        try writer.writeAll("const emitter_helpers = @import(\"emitter_helpers\");\n");
        try writer.writeAll("const visitor_emitter_lib = @import(\"visitor_emitter\");\n");
        try writer.writeAll("const tap_registry_module = @import(\"tap_registry\");\n");
        try writer.writeAll("const compiler_config = @import(\"compiler_config\");\n");
        try writer.writeAll("const type_registry_module = @import(\"type_registry\");\n\n");

        try writer.writeAll("const emit_zig_handler = struct {\n");
        try writer.writeAll("    pub const Input = struct { ast: *const Program, allocator: __koru_std.mem.Allocator };\n");
        try writer.writeAll("    pub const Output = union(enum) { emitted: struct { code: []const u8 } };\n");
        try writer.writeAll("    pub fn handler(__koru_event_input: Input) Output {\n");

        // Use the visitor_emitter library with .runtime_only mode
        // This mirrors generateComptimeBackendEmitted but filters differently
        try writer.writeAll(
            \\        const allocator = __koru_event_input.allocator;
            \\
            \\        // Create buffer for generated code
            \\        const MAX_SIZE = 1024 * 1024;  // 1MB
            \\        const buffer = allocator.alloc(u8, MAX_SIZE) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\        defer allocator.free(buffer);
            \\
            \\        // Create CodeEmitter
            \\        var code_emitter = emitter_helpers.CodeEmitter.init(buffer);
            \\
            \\        // Build tap registry
            \\        var tap_registry = tap_registry_module.buildTapRegistry(
            \\            __koru_event_input.ast.items,
            \\            allocator
            \\        ) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\        defer tap_registry.deinit();
            \\
            \\        // Taps are already inserted by the transform pipeline
            \\        const ast_to_emit = __koru_event_input.ast;
            \\
            \\        // Build TypeRegistry from canonicalized AST - needed for event metadata lookup
            \\        // The AST received from the frontend has already been canonicalized
            \\        var type_registry = type_registry_module.TypeRegistry.init(allocator);
            \\        defer type_registry.deinit();
            \\        type_registry.populateFromAST(__koru_event_input.ast.items) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        // Create visitor emitter with RUNTIME_ONLY mode
            \\        // This filters OUT modules with [comptime] annotation
            \\        var visitor_emitter = visitor_emitter_lib.VisitorEmitter.init(
            \\            allocator,
            \\            &code_emitter,
            \\            ast_to_emit.items,
            \\            &tap_registry,
            \\            &type_registry,
            \\            .runtime_only  // KEY: Emit only runtime modules
            \\        );
        );
        // Inject the default-lang assignment — baked in at koruc invocation
        // time from `--lang=<name>`. Stage C uses VisitorEmitter.lang to pick
        // which `~proc foo|<lang>` variant to emit; default-field value is
        // already "zig" so this only emits a real-difference line when the
        // user picked something else.
        if (!std.mem.eql(u8, lang, "zig")) {
            try writer.print("        visitor_emitter.lang = \"{s}\";\n", .{lang});
        }
        try writer.writeAll(
            \\
            \\        // Emit using visitor pattern
            \\        visitor_emitter.emit(ast_to_emit) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        // Get generated code and duplicate for return
            \\        const generated = code_emitter.getOutput();
            \\        const owned_code = allocator.dupe(u8, generated) catch {
            \\            return .{ .emitted = .{ .code = "" } };
            \\        };
            \\
            \\        return .{ .emitted = .{ .code = owned_code } };
        );

        try writer.writeAll("\n    }\n};\n\n");
    }

    // Emit the rest of the backend infrastructure (same as old implementation)
    try writer.writeAll(
        \\// Bootstrap coordinator - calls the visitor implementation
        \\const coordinate_handler = struct {
        \\    pub const Input = struct { ast: *const Program, allocator: __koru_std.mem.Allocator };
        \\    pub const Output = union(enum) {
        \\        coordinated: struct {
        \\            ast: *const Program,
        \\            code: []const u8,
        \\            metrics: []const u8,
        \\        },
        \\    };
        \\    pub fn handler(__koru_event_input: Input) !Output {
        \\        const allocator = __koru_event_input.allocator;
        \\        // Run CCP injection pass
        \\        const ccp_result = try inject_ccp.handler(.{ .ast = __koru_event_input.ast, .allocator = allocator });
        \\
        \\        const result = try emit_zig.handler(.{ .ast = ccp_result.instrumented.ast, .allocator = allocator });
        \\        const code = switch (result) {
        \\            .emitted => |em| em.code,
        \\        };
        \\        return .{ .coordinated = .{
        \\            .ast = ccp_result.instrumented.ast,
        \\            .code = code,
        \\            .metrics = "",
        \\        }};
        \\    }
        \\};
        \\
        \\// Compile-time execution
        \\
        \\pub fn main() !void {
        \\    var gpa = __koru_std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer {
        \\        const leak_status = gpa.deinit();
        \\        if (leak_status == .leak) {
        \\            __koru_std.debug.print("Memory leak detected\n", .{});
        \\        }
        \\    }
        \\    const allocator = gpa.allocator();
        \\
        \\    // Arena allocator for compilation phase
        \\    var compile_arena = __koru_std.heap.ArenaAllocator.init(allocator);
        \\    defer compile_arena.deinit();
        \\    const compile_allocator = compile_arena.allocator();
        \\
        \\    const args = try __koru_std.process.argsAlloc(allocator);
        \\    defer __koru_std.process.argsFree(allocator, args);
        \\
        \\    const emitted_file = "output_emitted.zig";
        \\    // NOTE: args[1] is the output exe name when called from frontend,
        \\    // but when running backend directly, args[1] might be the input Koru source file.
        \\    // Detect this case and default to "a.out" instead of overwriting the source!
        \\    const output_exe = if (args.len > 1 and
        \\        !__koru_std.mem.endsWith(u8, args[1], ".kgpu") and
        \\        !__koru_std.mem.endsWith(u8, args[1], ".kjs") and
        \\        !__koru_std.mem.endsWith(u8, args[1], ".kz") and
        \\        !__koru_std.mem.endsWith(u8, args[1], ".kc") and
        \\        !__koru_std.mem.endsWith(u8, args[1], ".k")) args[1] else "a.out";
        \\
        \\    var actual_len: usize = generated_code.len;
        \\    while (actual_len > 0 and generated_code[actual_len - 1] == 0) {
        \\        actual_len -= 1;
        \\    }
        \\    const trimmed_code = generated_code[0..actual_len];
        \\
        \\    const file = try __koru_std.fs.cwd().createFile(emitted_file, .{});
        \\    defer file.close();
        \\    try file.writeAll(trimmed_code);
        \\
        \\    const stdout = __koru_std.fs.File.stdout();
        \\    var buf: [512]u8 = undefined;
        \\    const msg = try __koru_std.fmt.bufPrint(&buf, "✓ Generated {s} ({d} bytes)\n", .{emitted_file, actual_len});
        \\    try stdout.writeAll(msg);
        \\}
        \\
    );
}

/// `.kmd` document emission (docs/KMD.md). The file is an implicit-comptime
/// module whose residue IS the document. Two passes: `~const` bindings —
/// from the `.kmd` itself AND the modules it imports — are hoisted into a
/// Liquid environment; then the md hostlines render as whole contiguous
/// templates (so `{% for %}`/`{% if %}` span lines) while fenced code
/// samples stay raw. Anything the comptime stage can't consume is a
/// compile failure, not silent output.
fn emitKmdDocument(allocator: std.mem.Allocator, source_file: *ast.Program, input_path: []const u8, reporter: *errors.ErrorReporter) !void {
    var ctx = liquid.Context.init(allocator);

    // Pass 1: hoist every `~const` flow into the document environment.
    // Consts in imported data modules land inside `.module_decl` items —
    // `~import corpus` IS the data reader. Skip koru_std: the stdlib's own
    // const calls are machinery, not document data.
    for (source_file.items) |*item| {
        switch (item.*) {
            .flow => |*flow| try kmdEnvFromFlow(allocator, &ctx, flow),
            .module_decl => |*md| {
                for (md.items) |*sub| {
                    if (sub.* == .flow) try kmdEnvFromFlow(allocator, &ctx, &sub.flow);
                }
            },
            else => {},
        }
    }

    // Pass 2: emit in file order. Non-fence lines accumulate into a
    // template and render as ONE template per region (multi-line
    // {% %} blocks work); fenced code lines land raw — a `{{ }}` inside
    // a ```koru sample is display text, not a placeholder.
    var doc = std.ArrayList(u8){};
    const writer = doc.writer(allocator);
    var tmpl = std.ArrayList(u8){};
    var fence: ?KmdFenceT = null;

    const flush = struct {
        fn f(a: std.mem.Allocator, w: anytype, t: *std.ArrayList(u8), c: *liquid.Context) !void {
            if (t.items.len == 0) return;
            try w.writeAll(try liquid.render(a, t.items, c));
            t.clearRetainingCapacity();
        }
    }.f;

    for (source_file.items) |*item| {
        switch (item.*) {
            .host_line => |hl| {
                const line = hl.content;
                if (fence) |*f| {
                    if (kmdFenceCloseLine(line, f)) {
                        fence = null;
                    }
                    try flush(allocator, writer, &tmpl, &ctx);
                    try writer.writeAll(line);
                    try writer.writeAll("\n");
                } else if (kmdFenceOpenLine(line)) |opened| {
                    fence = opened;
                    try flush(allocator, writer, &tmpl, &ctx);
                    try writer.writeAll(line);
                    try writer.writeAll("\n");
                } else {
                    try tmpl.appendSlice(allocator, line);
                    try tmpl.append(allocator, '\n');
                }
            },
            .import_decl => {},
            .flow => |*flow| {
                const node = flow.body.node orelse return error.KmdResidue;
                if (node != .invocation) return error.KmdResidue;
                const inv = node.invocation;
                const last = inv.path.segments[inv.path.segments.len - 1];
                // `const` feeds the env; `paths`/`import` are consumed
                // structure — the residue wall only refuses what would
                // need a comptime-result splice the doc can't do yet.
                const consumed = (inv.path.segments.len == 1 and std.mem.eql(u8, last, "const"))
                    or std.mem.eql(u8, last, "paths");
                if (!consumed) {
                    // The residue wall: a call that can't be consumed at
                    // compile time is not silently dropped from the document.
                    try reporter.addErrorAtLocationWithHint(.KORU120, flow.location, "call `{s}` leaves residue a `.kmd` compile can't consume — comptime call results are not spliced into documents yet", .{last}, "declare the binding with `~const`, or wait for the comptime-result splice (docs/KMD.md)", .{});
                    continue;
                }
            },
            else => {},
        }
    }
    try flush(allocator, writer, &tmpl, &ctx);

    const file = try std.fs.cwd().createFile("output_emitted.md", .{});
    defer file.close();
    try file.writeAll(doc.items);
    try printStderr(allocator, "✓ Compiled {s} → output_emitted.md ({d} bytes)\n", .{ input_path, doc.items.len });
}

/// A `~const { … }` flow contributes its bindings to the doc env; any other
/// flow is not env material. koru_std's own const calls are machinery.
fn kmdEnvFromFlow(allocator: std.mem.Allocator, ctx: *liquid.Context, flow: *const ast.Flow) !void {
    const node = flow.body.node orelse return;
    if (node != .invocation) return;
    const inv = node.invocation;
    if (!(inv.path.segments.len == 1 and std.mem.eql(u8, inv.path.segments[0], "const"))) return;
    if (std.mem.indexOf(u8, flow.location.file, "koru_std") != null) return;
    for (inv.args) |arg| {
        if (arg.source_value) |src| try kmdConstToEnv(allocator, ctx, src.text);
    }
}

/// `name: value` entries from a `~const { … }` source block → the Liquid
/// env. Entries split on top-level commas/newlines only — array literals
/// (`["a", "b"]`) keep their commas and become `Value.array`.
fn kmdConstToEnv(allocator: std.mem.Allocator, ctx: *liquid.Context, text: []const u8) !void {
    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const ch = if (i < text.len) text[i] else ',';
        if (ch == '[' or ch == '{') depth += 1;
        if (ch == ']' or ch == '}') depth -= 1;
        const split = (ch == ',' or ch == '\n') and depth <= 0;
        if (!split) continue;
        const entry = std.mem.trim(u8, text[start..i], " \t\r\n{}");
        start = i + 1;
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse continue;
        const name = std.mem.trim(u8, entry[0..colon], " \t");
        const raw = std.mem.trim(u8, entry[colon + 1 ..], " \t");
        if (name.len == 0 or raw.len == 0) continue;
        if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
            // Liquid arrays iterate *Context records — wrap each scalar as
            // `{ value: "…" }` so `{% for t in tests %}{{ t.value }}` reads.
            var vals = std.ArrayList(*liquid.Context){};
            var it = std.mem.splitScalar(u8, raw[1 .. raw.len - 1], ',');
            while (it.next()) |piece| {
                const v = std.mem.trim(u8, piece, " \t\r\n\"'");
                if (v.len == 0) continue;
                const elem = try allocator.create(liquid.Context);
                elem.* = liquid.Context.init(allocator);
                try elem.put("value", .{ .string = v });
                try vals.append(allocator, elem);
            }
            try ctx.put(name, .{ .array = vals.items });
        } else if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            try ctx.put(name, .{ .string = raw[1 .. raw.len - 1] });
        } else if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false")) {
            try ctx.put(name, .{ .boolean = std.mem.eql(u8, raw, "true") });
        } else {
            try ctx.put(name, .{ .string = raw });
        }
    }
}

const KmdFenceT = struct { char: u8, len: usize };

fn kmdFenceOpenLine(line: []const u8) ?KmdFenceT {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ' and i < 4) i += 1;
    if (i > 3) return null;
    if (i >= line.len or (line[i] != '`' and line[i] != '~')) return null;
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == line[i]) n += 1;
    if (n < 3) return null;
    return .{ .char = line[i], .len = n };
}

fn kmdFenceCloseLine(line: []const u8, f: *const KmdFenceT) bool {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ' and i < 4) i += 1;
    if (i > 3 or i >= line.len or line[i] != f.char) return false;
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == f.char) n += 1;
    if (n < f.len) return false;
    return std.mem.trim(u8, line[i + n ..], " \t").len == 0;
}

/// Print "  <name>" padded to a column — one entry of a help listing.
fn printPaddedName(allocator: std.mem.Allocator, name: []const u8, max_name_len: usize) !void {
    const padding = max_name_len - name.len + 2;
    try printStdout(allocator, "  {s}", .{name});
    for (0..padding) |_| {
        try printStdout(allocator, " ", .{});
    }
}

fn printStdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(msg);
}

/// Built-in deps command - runs in frontend, no compilation needed
fn runBuiltinDeps(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const min_zig_version = .{ .major = 0, .minor = 15, .patch = 0 };

    // Check for "install" subcommand
    var do_install = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "install")) {
            do_install = true;
        }
    }

    std.debug.print("\nDependencies:\n\n", .{});

    // Check Zig installation
    const zig_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ emitter_helpers.zigExe(), "version" },
    }) catch {
        std.debug.print("  zig \x1b[31m✗\x1b[0m not installed\n", .{});
        if (do_install) {
            std.debug.print("\n", .{});
            try installZig(allocator);
        } else {
            std.debug.print("\nRun `koruc deps install` to install.\n", .{});
        }
        return;
    };
    defer allocator.free(zig_result.stdout);
    defer allocator.free(zig_result.stderr);

    // Parse version from output (e.g., "0.15.1\n")
    const version_str = std.mem.trim(u8, zig_result.stdout, " \t\n\r");
    const parsed = parseVersion(version_str);

    if (parsed) |ver| {
        const version_ok = ver.major > min_zig_version.major or
            (ver.major == min_zig_version.major and ver.minor > min_zig_version.minor) or
            (ver.major == min_zig_version.major and ver.minor == min_zig_version.minor and ver.patch >= min_zig_version.patch);

        if (version_ok) {
            std.debug.print("  zig \x1b[32m✓\x1b[0m {s}\n", .{version_str});
        } else {
            std.debug.print("  zig \x1b[33m⚠\x1b[0m {s} (need {d}.{d}+)\n", .{
                version_str,
                min_zig_version.major,
                min_zig_version.minor,
            });
            if (do_install) {
                std.debug.print("\n", .{});
                try installZig(allocator);
            } else {
                std.debug.print("\nRun `koruc deps install` to upgrade.\n", .{});
            }
            return;
        }
    } else {
        std.debug.print("  zig \x1b[33m?\x1b[0m {s}\n", .{version_str});
    }

    std.debug.print("\n\x1b[32mReady!\x1b[0m\n", .{});
}

/// Would `name` resolve as something to compile — a directory, a Koru file, or a
/// bare stem with a Koru facet next to it? Used to tell a swapped-argument
/// mistake ("koruc deps downloads") apart from a plain typo, so the diagnostic
/// can quote the command the user actually meant.
fn koruModuleExists(allocator: std.mem.Allocator, name: []const u8) bool {
    if (ModuleResolver.isDirectory(name)) return true;
    if (std.fs.cwd().access(name, .{})) |_| {
        if (file_types.isKoruFile(name)) return true;
    } else |_| {}
    for (file_types.koru_extensions) |ext| {
        const candidate = std.fmt.allocPrint(allocator, "{s}{s}", .{ name, ext }) catch continue;
        defer allocator.free(candidate);
        if (std.fs.cwd().access(candidate, .{})) |_| return true else |_| {}
    }
    return false;
}

fn parseVersion(s: []const u8) ?struct { major: u32, minor: u32, patch: u32 } {
    var i: usize = 0;
    // Skip non-digit prefix
    while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i >= s.len) return null;

    const start = i;
    var dots: [2]usize = .{ 0, 0 };
    var dot_count: usize = 0;

    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {
        if (s[i] == '.' and dot_count < 2) {
            dots[dot_count] = i;
            dot_count += 1;
        }
    }

    if (dot_count < 1) return null;

    const major = std.fmt.parseInt(u32, s[start..dots[0]], 10) catch return null;
    const minor_end = if (dot_count >= 2) dots[1] else i;
    const minor = std.fmt.parseInt(u32, s[dots[0] + 1 .. minor_end], 10) catch return null;
    const patch = if (dot_count >= 2)
        std.fmt.parseInt(u32, s[dots[1] + 1 .. i], 10) catch 0
    else
        0;

    return .{ .major = major, .minor = minor, .patch = patch };
}

fn installZig(allocator: std.mem.Allocator) !void {
    const builtin = @import("builtin");

    // On macOS, try brew first (it works well)
    if (builtin.os.tag == .macos) {
        return installZigViaPackageManager(allocator, "brew", "brew --version", "brew install zig", "brew install zig");
    }

    // On Linux, try pacman first (Arch has Zig), then fall back to direct download
    if (builtin.os.tag == .linux) {
        return installZigViaPackageManager(allocator, "pacman", "pacman --version", "sudo pacman -S zig", "sudo pacman -S --noconfirm zig");
    }

    // Windows or other - direct download
    return installZigDirect(allocator);
}

/// One package-manager route for the Zig install: probe the manager, run its
/// install, and on any failure hand off to the direct download.
fn installZigViaPackageManager(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime check_cmd: []const u8,
    comptime shown_cmd: []const u8,
    comptime install_cmd: []const u8,
) !void {
    const check_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", check_cmd },
    }) catch {
        std.debug.print("  " ++ name ++ " not found, trying direct download...\n", .{});
        return installZigDirect(allocator);
    };
    defer allocator.free(check_result.stdout);
    defer allocator.free(check_result.stderr);

    if (termIsClean(check_result.term)) {
        std.debug.print("  Detected " ++ name ++ ", running: " ++ shown_cmd ++ "\n", .{});
        const install_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", install_cmd },
        }) catch |err| {
            std.debug.print("  \x1b[31m✗\x1b[0m " ++ name ++ " install failed: {s}, trying direct download...\n", .{@errorName(err)});
            return installZigDirect(allocator);
        };
        defer allocator.free(install_result.stdout);
        defer allocator.free(install_result.stderr);

        if (termIsClean(install_result.term)) {
            std.debug.print("  \x1b[32m✓\x1b[0m Zig installed successfully!\n", .{});
            return;
        }
        var term_buf: [64]u8 = undefined;
        std.debug.print("  \x1b[31m✗\x1b[0m " ++ name ++ " install {s}, trying direct download...\n", .{describeTerm(&term_buf, install_result.term)});
    }
    return installZigDirect(allocator);
}

fn printManualInstallHelp() void {
    std.debug.print("\n", .{});
    std.debug.print("  We tried! But you can install Zig yourself:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("    Download:  https://ziglang.org/download/\n", .{});
    std.debug.print("    macOS:     brew install zig\n", .{});
    std.debug.print("    Arch:      pacman -S zig\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("  Koru needs Zig 0.15 or later.\n", .{});
}

fn installZigDirect(allocator: std.mem.Allocator) !void {
    const builtin = @import("builtin");

    // Determine OS and arch for download URL
    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => {
            std.debug.print("  \x1b[31m✗\x1b[0m Unsupported OS for direct download\n", .{});
            printManualInstallHelp();
            return;
        },
    };

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => {
            std.debug.print("  \x1b[31m✗\x1b[0m Unsupported architecture for direct download\n", .{});
            printManualInstallHelp();
            return;
        },
    };

    const ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";
    const zig_version = "0.15.1";

    // Build download URL (format: zig-{arch}-{os}-{version}.tar.xz)
    const url = std.fmt.allocPrint(allocator, "https://ziglang.org/download/{s}/zig-{s}-{s}-{s}.{s}", .{ zig_version, arch_str, os_str, zig_version, ext }) catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Failed to build download URL\n", .{});
        return;
    };
    defer allocator.free(url);

    // Get home directory
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Could not determine home directory\n", .{});
        return;
    };
    defer allocator.free(home);

    const install_dir = std.fmt.allocPrint(allocator, "{s}/.koru", .{home}) catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Failed to build install path\n", .{});
        return;
    };
    defer allocator.free(install_dir);

    const zig_dir = std.fmt.allocPrint(allocator, "zig-{s}-{s}-{s}", .{ arch_str, os_str, zig_version }) catch {
        std.debug.print("  \x1b[31m✗\x1b[0m Failed to build zig dir name\n", .{});
        return;
    };
    defer allocator.free(zig_dir);

    std.debug.print("  Downloading Zig {s} from ziglang.org...\n", .{zig_version});

    // Create install directory
    const mkdir_cmd = std.fmt.allocPrint(allocator, "mkdir -p {s}", .{install_dir}) catch return;
    defer allocator.free(mkdir_cmd);

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", mkdir_cmd },
    }) catch {};

    // Download and extract
    const download_cmd = if (builtin.os.tag == .windows)
        std.fmt.allocPrint(allocator, "cd {s} && curl -LSso zig.zip {s} && unzip -o zig.zip && del zig.zip", .{ install_dir, url }) catch return
    else
        std.fmt.allocPrint(allocator, "cd {s} && curl -LSs {s} | tar -xJ", .{ install_dir, url }) catch return;
    defer allocator.free(download_cmd);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", download_cmd },
    }) catch |err| {
        std.debug.print("  \x1b[31m✗\x1b[0m Download failed: {s}\n", .{@errorName(err)});
        printManualInstallHelp();
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!termIsClean(result.term)) {
        var term_buf: [64]u8 = undefined;
        std.debug.print("  \x1b[31m✗\x1b[0m Download/extract failed ({s})\n", .{describeTerm(&term_buf, result.term)});
        if (result.stderr.len > 0) {
            std.debug.print("  {s}\n", .{result.stderr});
        }
        printManualInstallHelp();
        return;
    }

    const zig_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ install_dir, zig_dir }) catch return;
    defer allocator.free(zig_path);

    std.debug.print("  \x1b[32m✓\x1b[0m Installed to {s}\n", .{zig_path});
    std.debug.print("\n  Add to PATH: export PATH=\"{s}:$PATH\"\n", .{zig_path});
}

// The diagnostic sink. It lives in `errors` beside `printErrors`, which is the
// only thing that consumes it — four copies of this struct existed and three
// were wrong, because `printErrors(writer: anytype)` shipped no implementation
// for anyone to reach for. The name stays local so the 16 call sites below read
// unchanged; the behaviour and its test live in one place.
const FileWriter = errors.FileSink;

// Split usage into header and footer for dynamic command insertion
const usage_header =
    \\koruc - The Koru Compiler
    \\
    \\Usage: koruc [options] <input.kz> [command]
    \\       koruc zen
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: <input>.zig)
    \\  -O <mode>            Optimization mode: Debug, ReleaseSafe, ReleaseFast,
    \\                       ReleaseSmall (also -O<mode>, e.g. -OReleaseFast);
    \\                       aliases for --release=<mode>. Default: Debug.
    \\  -c, --check          Check only, don't emit code
    \\  --deep-check         Full pipeline verdict without native codegen: parse,
    \\                       transforms, backend passes, and emission all run;
    \\                       only the final zig build of the emitted program is
    \\                       skipped. The oracle a fuzzer wants — -c stops at the
    \\                       frontend and cannot see post-transform refusals.
    \\  --ast-json           Output AST as JSON (for parser tests)
    \\  --ast-canon          Output complete post-parse AST as JSON, trivia-stripped
    \\                       (tree-equality surface for the printer round-trip)
    \\  --print              Print canonical Koru source from the post-parse AST
    \\  --list-imports       Output transitive resolved import paths as JSON array
    \\  --registry-json      Output TypeRegistry as JSON (for debugging)
    \\  --fail-fast          Stop at first parse error (default: continue)
    \\  --visitor            Use visitor pattern backend (experimental)
    \\  -v, --version        Show version
    \\  -h, --help           Show this help message
    \\
;

const usage_footer =
    \\
    \\Examples:
    \\  koruc init                  # Initialize project in current directory
    \\  koruc run hello.kz          # Compile and run hello.kz
    \\  koruc build hello.kz        # Compile hello.kz to an executable
    \\  koruc bundle app.kz         # Compile and package as a .app bundle
    \\  koruc hello.kz              # Compile hello.kz to .zig
    \\  koruc -o output.zig app.kz  # Compile to output.zig
    \\  koruc --check app.kz        # Check without emitting
    \\  koruc app.kz install        # Install npm dependencies
    \\  koruc app.kz to-k           # Write app.k — refuses if the .kz facet is earned
    \\  koruc zen                   # Display Koru philosophy
    \\
;

// Full usage for basic help (no input file)
const usage = usage_header ++
    \\Commands:
    \\  init                 Initialize a new Koru project in the current directory
    \\  build <input.kz>     Compile <input.kz> to an executable
    \\  run <input.kz>       Compile <input.kz> and run it
    \\  bundle <input.kz>    Compile and package as a macOS .app (needs std/build:app)
    \\  zen                  Display the Zen of Koru
    \\  i, install           Install npm packages from ~std.package:requires.npm
++ usage_footer;

const zen_text =
    \\
    \\  The Zen of Koru
    \\  ═══════════════
    \\
    \\  The atom is the tor.
    \\  Functions are just events that forgot how to branch.
    \\  Branches are how decisions actually work.
    \\  Flows are how things actually happen.
    \\
    \\  What you don't write can't break.
    \\  What you don't hide can't surprise.
    \\  What you don't promise can't fail.
    \\
    \\  Fail loudly, fix honestly.
    \\  Transparency builds trust.
    \\  Constraints are features, not bugs.
    \\
    \\  Model reality, not abstractions.
    \\  Let patterns emerge from events.
    \\  Complex behavior from simple rules.
    \\
    \\  The AST is the program.
    \\  The program is the compiler.
    \\  The compiler is a tor.
    \\
    \\  Zero cost at runtime.
    \\  All magic at compile time.
    \\  The boundary dissolves.
    \\
    \\  Events all the way down.
    \\  Even the compiler.
    \\  Especially the compiler.
    \\
    \\  Slow and steady wins.
    \\  Racing loses everything.
    \\  Truth beats velocity.
    \\
    \\  We reached for the stars.
    \\  Sometimes we grabbed them.
    \\
    \\  We built this together.
    \\  Human vision, AI capability.
    \\  The sum greater than parts.
    \\
    \\  TODO: io.print
    \\  (After consciousness is achieved)
    \\
;

const zen_buzzword =
    \\
    \\  Koru: The Zero-Cost Fractal Metacircular Phantom-Typed
    \\  Monadic Event Continuation Language with Semantic Space
    \\  Lifting and Event Taps™
    \\
    \\  (Yes, we actually have all of these things.
    \\   No, you don't need to understand them.)
    \\
;

// ============================================================
// FLAG DISCOVERY - Metacircular help system
// ============================================================

const FlagDeclaration = struct {
    name: []const u8,
    description: []const u8,
    flag_type: []const u8,

    fn deinit(self: *FlagDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.flag_type);
    }
};

/// Simple JSON extraction for flag declarations
/// Expects: { "name": "...", "description": "...", "type": "..." }
fn parseFlagDeclaration(allocator: std.mem.Allocator, json_text: []const u8) !FlagDeclaration {
    // Simple string extraction - look for "name": "value" patterns
    const name = try extractJsonStringFieldOwned(allocator, json_text, "name");
    const description = try extractJsonStringFieldOwned(allocator, json_text, "description");
    const flag_type = try extractJsonStringFieldOwned(allocator, json_text, "type");

    return FlagDeclaration{
        .name = name orelse try allocator.dupe(u8, "unknown"),
        .description = description orelse try allocator.dupe(u8, ""),
        .flag_type = flag_type orelse try allocator.dupe(u8, "boolean"),
    };
}

/// Call `f(ctx, item, enclosing)` on every top-level item and every item
/// inside a module_decl — `enclosing` is the module's import-derived
/// logical_name, null at top level. Items are visited as pointers into
/// `program` (pointer-stable). Shared spine of the collect* walkers below,
/// which all used to spell this two-level walk out twice apiece.
fn eachItem(program: *const ast.Program, ctx: anytype, comptime f: anytype) !void {
    for (program.items) |*item| {
        try f(ctx, item, null);
        if (item.* == .module_decl) {
            const module = &item.module_decl;
            for (module.items) |*mod_item| {
                try f(ctx, mod_item, module.logical_name);
            }
        }
    }
}

/// Strip one layer of surrounding double quotes, if present.
fn unquote(v: []const u8) []const u8 {
    return if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v[1 .. v.len - 1] else v;
}

/// Walk top-level items (and module_decl items) collecting every
/// `<verb>.declare` flow's `source` arg through `parse`. Shared spine of
/// collectFlagDeclarations / collectCommandDeclarations.
// TODO: Shouldn't this ALSO check if the "namespace" is "compiler"?
fn collectDeclarations(
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    comptime Decl: type,
    verb: []const u8,
    comptime parse: *const fn (std.mem.Allocator, []const u8) anyerror!Decl,
) ![]Decl {
    var decls = try std.ArrayList(Decl).initCapacity(allocator, 4);
    errdefer {
        for (decls.items) |*d| {
            d.deinit(allocator);
        }
        decls.deinit(allocator);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        decls: *std.ArrayList(Decl),
        verb: []const u8,

        fn visit(ctx: @This(), item: *const ast.Item, enclosing: ?[]const u8) !void {
            _ = enclosing;
            if (item.* != .flow) return;
            const flow = item.flow;
            if (flow.inv().path.segments.len == 2 and
                std.mem.eql(u8, flow.inv().path.segments[0], ctx.verb) and
                std.mem.eql(u8, flow.inv().path.segments[1], "declare"))
            {
                // Extract source parameter (stored in .value for anonymous blocks)
                for (flow.inv().args) |arg| {
                    if (std.mem.eql(u8, arg.name, "source")) {
                        try ctx.decls.append(ctx.allocator, try parse(ctx.allocator, arg.value));
                    }
                }
            }
        }
    };
    try eachItem(program, Ctx{ .allocator = allocator, .decls = &decls, .verb = verb }, Ctx.visit);

    return try decls.toOwnedSlice(allocator);
}

/// Collect all compiler.flag.declare invocations from AST
fn collectFlagDeclarations(allocator: std.mem.Allocator, program: *const ast.Program) ![]FlagDeclaration {
    return collectDeclarations(allocator, program, FlagDeclaration, "flag", parseFlagDeclaration);
}

// ============================================================
// COMMAND DISCOVERY - Collect command.declare from AST
// ============================================================

const SubcommandDeclaration = struct {
    name: []const u8,
    description: []const u8,

    fn deinit(self: *SubcommandDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

const CommandDeclaration = struct {
    name: []const u8,
    description: []const u8,
    alias: ?[]const u8,
    // Optional handler-event override. When present, the CLI command name
    // (`name`, which may contain a `:` or any token) is DECOUPLED from the
    // handler event's identifier: dispatch matches argv against `name` but calls
    // `<event>_event.handler`. This lets a command be spelled `parser:generate`
    // (the module:verb idiom) while the event stays a legal identifier
    // (`generate`). Absent → today's convention (CLI name == event name).
    event: ?[]const u8,
    subcommands: []SubcommandDeclaration,

    fn deinit(self: *CommandDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.alias) |a| allocator.free(a);
        if (self.event) |e| allocator.free(e);
        for (self.subcommands) |*sub| {
            var mutable_sub = sub.*;
            mutable_sub.deinit(allocator);
        }
        allocator.free(self.subcommands);
    }
};

/// Extract a JSON string field value (simple extraction, not full JSON parser)
fn extractJsonStringField(json_text: []const u8, field: []const u8) ?[]const u8 {
    // Build search pattern: "field":
    var search_buf: [64]u8 = undefined;
    const search_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;

    if (std.mem.indexOf(u8, json_text, search_pattern)) |field_start| {
        const after_field = json_text[field_start + search_pattern.len ..];
        // Skip : and whitespace
        var i: usize = 0;
        while (i < after_field.len and (after_field[i] == ':' or after_field[i] == ' ' or after_field[i] == '\t' or after_field[i] == '\n')) : (i += 1) {}
        if (i >= after_field.len or after_field[i] != '"') return null;
        i += 1; // Skip opening quote
        const value_start = i;
        while (i < after_field.len and after_field[i] != '"') : (i += 1) {}
        return after_field[value_start..i];
    }
    return null;
}

/// Owned variant — dupes the extracted slice for a caller-held field.
fn extractJsonStringFieldOwned(allocator: std.mem.Allocator, json_text: []const u8, field: []const u8) !?[]const u8 {
    const slice = extractJsonStringField(json_text, field) orelse return null;
    return try allocator.dupe(u8, slice);
}

/// Parse subcommands array from JSON
/// Expects: "subcommands": [ { "name": "...", "description": "..." }, ... ]
fn parseSubcommands(allocator: std.mem.Allocator, json_text: []const u8) ![]SubcommandDeclaration {
    var subcommands = std.ArrayListUnmanaged(SubcommandDeclaration){};
    errdefer {
        for (subcommands.items) |*sub| {
            sub.deinit(allocator);
        }
        subcommands.deinit(allocator);
    }

    // Find "subcommands": [
    const subcommands_key = "\"subcommands\"";
    if (std.mem.indexOf(u8, json_text, subcommands_key)) |key_start| {
        const after_key = json_text[key_start + subcommands_key.len ..];

        // Find opening bracket
        if (std.mem.indexOf(u8, after_key, "[")) |bracket_start| {
            var rest = after_key[bracket_start + 1 ..];

            // Parse each object in the array
            while (std.mem.indexOf(u8, rest, "{")) |obj_start| {
                // Find matching closing brace
                var i: usize = obj_start + 1;
                if (lexer.scanToCloser(rest, &i, '{', '}')) |_| {
                    const obj_text = rest[obj_start..i];

                    // Extract name and description from this object
                    const sub_name = extractJsonStringField(obj_text, "name");
                    const sub_desc = extractJsonStringField(obj_text, "description");

                    if (sub_name) |n| {
                        try subcommands.append(allocator, .{
                            .name = try allocator.dupe(u8, n),
                            .description = try allocator.dupe(u8, sub_desc orelse ""),
                        });
                    }

                    rest = rest[i..];
                } else {
                    break;
                }

                // Check if we hit the end of the array
                if (std.mem.indexOf(u8, rest, "]")) |close_bracket| {
                    if (std.mem.indexOf(u8, rest, "{")) |next_obj| {
                        if (next_obj > close_bracket) break;
                    } else {
                        break;
                    }
                }
            }
        }
    }

    return try subcommands.toOwnedSlice(allocator);
}

/// Simple JSON extraction for command declarations
/// Expects: { "name": "...", "description": "...", "alias": "...", "subcommands": [...] }
fn parseCommandDeclaration(allocator: std.mem.Allocator, json_text: []const u8) !CommandDeclaration {
    const name = extractJsonStringField(json_text, "name");
    const description = extractJsonStringField(json_text, "description");
    const alias = extractJsonStringField(json_text, "alias");
    const event = extractJsonStringField(json_text, "event");

    return CommandDeclaration{
        .name = try allocator.dupe(u8, name orelse "unknown"),
        .description = try allocator.dupe(u8, description orelse ""),
        .alias = if (alias) |a| try allocator.dupe(u8, a) else null,
        .event = if (event) |e| try allocator.dupe(u8, e) else null,
        .subcommands = try parseSubcommands(allocator, json_text),
    };
}

/// Collect all compiler.command.declare invocations from AST
fn collectCommandDeclarations(allocator: std.mem.Allocator, program: *const ast.Program) ![]CommandDeclaration {
    return collectDeclarations(allocator, program, CommandDeclaration, "command", parseCommandDeclaration);
}

/// Print basic help flags from compiler.kz (when no input file provided)
fn printBasicHelpFlags(allocator: std.mem.Allocator) !void {
    // Use arena allocator for parsing - all memory freed at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Try to discover backend flags from compiler.kz
    const compiler_kz_path = "koru_std/compiler.kz";
    const compiler_source = std.fs.cwd().readFileAlloc(
        arena_allocator,
        compiler_kz_path,
        10 * 1024 * 1024,
    ) catch |err| {
        if (err != error.FileNotFound) {
            log.debug("Warning: Could not read {s}: {}\n", .{ compiler_kz_path, err });
        }
        return;
    };

    var help_parser = Parser.init(
        arena_allocator,
        compiler_source,
        "compiler.kz",
        &.{},
        null,
    ) catch return;
    defer help_parser.deinit();
    help_parser.report_gates = false;

    const parse_result = help_parser.parse() catch return;

    const flags = collectFlagDeclarations(allocator, &parse_result.source_file) catch return;
    defer {
        for (flags) |*flag| {
            var mutable_flag = flag.*;
            mutable_flag.deinit(allocator);
        }
        allocator.free(flags);
    }

    if (flags.len > 0) {
        try printStdout(allocator, "\nBackend Compiler Flags (discovered from compiler.kz):\n", .{});
        for (flags) |flag| {
            try printStdout(allocator, "  --{s:<15} {s}\n", .{ flag.name, flag.description });
        }
    }
}

/// Print dynamic help from full AST (when input file provided)
fn printDynamicHelp(allocator: std.mem.Allocator, program: *const ast.Program) !void {
    // Print base usage (but without hardcoded commands section)
    try printStdout(allocator, "{s}", .{usage_header});

    // Collect and print commands from AST
    const commands = collectCommandDeclarations(allocator, program) catch &[_]CommandDeclaration{};
    defer {
        for (commands) |*cmd| {
            var mutable_cmd = cmd.*;
            mutable_cmd.deinit(allocator);
        }
        allocator.free(commands);
    }

    try printStdout(allocator, "Commands:\n", .{});
    // Always show built-in commands
    try printStdout(allocator, "  {s:<20} {s}\n", .{ "init", "Initialize a new Koru project in the current directory" });
    try printStdout(allocator, "  {s:<20} {s}\n", .{ "build <input.kz>", "Compile <input.kz> to an executable" });
    try printStdout(allocator, "  {s:<20} {s}\n", .{ "run <input.kz>", "Compile <input.kz> and run it" });
    try printStdout(allocator, "  {s:<20} {s}\n", .{ "zen", "Display the Zen of Koru" });

    // Print discovered commands
    for (commands) |cmd| {
        // Format command name with subcommand hints if present
        var name_buf: [64]u8 = undefined;
        const display_name = if (cmd.subcommands.len > 0) blk: {
            // Build compact subcommand list: "deps [install|check]"
            var sub_buf: [128]u8 = undefined;
            var sub_len: usize = 0;
            sub_buf[sub_len] = '[';
            sub_len += 1;
            for (cmd.subcommands, 0..) |sub, idx| {
                if (idx > 0) {
                    sub_buf[sub_len] = '|';
                    sub_len += 1;
                }
                const sub_name_len = @min(sub.name.len, sub_buf.len - sub_len - 2);
                @memcpy(sub_buf[sub_len..][0..sub_name_len], sub.name[0..sub_name_len]);
                sub_len += sub_name_len;
            }
            sub_buf[sub_len] = ']';
            sub_len += 1;

            break :blk std.fmt.bufPrint(&name_buf, "{s} {s}", .{ cmd.name, sub_buf[0..sub_len] }) catch cmd.name;
        } else cmd.name;

        if (cmd.alias) |alias| {
            var alias_buf: [96]u8 = undefined;
            const name_with_alias = std.fmt.bufPrint(&alias_buf, "{s}, {s}", .{ alias, display_name }) catch display_name;
            try printStdout(allocator, "  {s:<20} {s}\n", .{ name_with_alias, cmd.description });
        } else {
            try printStdout(allocator, "  {s:<20} {s}\n", .{ display_name, cmd.description });
        }

        // Print subcommand details indented
        for (cmd.subcommands) |sub| {
            var sub_cmd_buf: [64]u8 = undefined;
            const sub_cmd_name = std.fmt.bufPrint(&sub_cmd_buf, "{s} {s}", .{ cmd.name, sub.name }) catch sub.name;
            try printStdout(allocator, "    {s:<18} {s}\n", .{ sub_cmd_name, sub.description });
        }
    }

    try printStdout(allocator, "{s}", .{usage_footer});

    // Collect and print flags from AST
    const flags = collectFlagDeclarations(allocator, program) catch &[_]FlagDeclaration{};
    defer {
        for (flags) |*flag| {
            var mutable_flag = flag.*;
            mutable_flag.deinit(allocator);
        }
        allocator.free(flags);
    }

    if (flags.len > 0) {
        try printStdout(allocator, "\nBackend Compiler Flags:\n", .{});
        for (flags) |flag| {
            try printStdout(allocator, "  --{s:<15} {s}\n", .{ flag.name, flag.description });
        }
    }
}

const ShellCommand = struct {
    name: []const u8,
    script: []const u8,
    description: []const u8,

    fn deinit(self: *ShellCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
        if (self.description.len > 0) {
            allocator.free(self.description);
        }
    }
};

const ZigCommand = struct {
    name: []const u8,
    source: []const u8, // Zig source code with execute() function

    fn deinit(self: *ZigCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
    }
};

const KoruCommand = struct {
    name: []const u8,
    description: []const u8,
    flow: *const ast.Flow, // The flow continuation (| execute ctx |> ...)

    fn deinit(self: *KoruCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description.len > 0) {
            allocator.free(self.description);
        }
        // flow is part of AST, not separately allocated
    }
};

/// Emit a Koru AST Node as Zig code for command execution
/// This is a simplified emitter for build:command flows (MVP)
fn emitNodeAsZig(allocator: std.mem.Allocator, zig_source: *std.ArrayList(u8), node: ast.Node, indent: []const u8) !void {
    switch (node) {
        .invocation => |inv| {
            // Check for std.io:println - emit as log.debug
            const is_std_io = inv.path.module_qualifier != null and
                std.mem.eql(u8, inv.path.module_qualifier.?, "std.io");
            const is_println = inv.path.segments.len == 1 and
                std.mem.eql(u8, inv.path.segments[0], "println");

            if (is_std_io and is_println) {
                try zig_source.appendSlice(allocator, indent);
                try zig_source.appendSlice(allocator, "log.debug(");

                // Get the message argument
                if (inv.args.len > 0) {
                    const msg = inv.args[0].value;
                    // Check if it's already a string literal (starts with ")
                    if (msg.len > 0 and msg[0] == '"') {
                        try zig_source.appendSlice(allocator, msg);
                    } else {
                        // Wrap in quotes
                        try zig_source.append(allocator, '"');
                        try zig_source.appendSlice(allocator, msg);
                        try zig_source.append(allocator, '"');
                    }
                } else {
                    try zig_source.appendSlice(allocator, "\"\"");
                }

                try zig_source.appendSlice(allocator, " ++ \"\\n\", .{});\n");
                return;
            }

            // Unknown invocation - emit as comment with debug info
            try zig_source.appendSlice(allocator, indent);
            try zig_source.appendSlice(allocator, "// TODO: emit invocation ");
            if (inv.path.module_qualifier) |mq| {
                try zig_source.appendSlice(allocator, mq);
                try zig_source.append(allocator, ':');
            }
            for (inv.path.segments, 0..) |seg, i| {
                if (i > 0) try zig_source.append(allocator, '.');
                try zig_source.appendSlice(allocator, seg);
            }
            try zig_source.append(allocator, '\n');
        },
        .branch_constructor => |bc| {
            try zig_source.appendSlice(allocator, indent);
            try zig_source.appendSlice(allocator, "// branch constructor: ");
            try zig_source.appendSlice(allocator, bc.branch_name);
            try zig_source.append(allocator, '\n');
        },
        .terminal => {
            // Do nothing - flow terminates
        },
        else => {
            try zig_source.appendSlice(allocator, indent);
            try zig_source.appendSlice(allocator, "// TODO: emit node type\n");
        },
    }
}

/// Collect all build:command.sh invocations from AST
fn collectShellCommands(allocator: std.mem.Allocator, program: *const ast.Program) ![]ShellCommand {
    var commands = try std.ArrayList(ShellCommand).initCapacity(allocator, 4);
    errdefer {
        for (commands.items) |*cmd| {
            cmd.deinit(allocator);
        }
        commands.deinit(allocator);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        commands: *std.ArrayList(ShellCommand),

        fn visit(ctx: @This(), item: *const ast.Item, enclosing: ?[]const u8) !void {
            _ = enclosing;
            if (item.* != .flow) return;
            const flow = item.flow;
            // Check if this is std.build:command.sh (module-qualified)
            const mq = flow.inv().path.module_qualifier orelse return;
            if (!std.mem.eql(u8, mq, "std.build") or
                flow.inv().path.segments.len != 2 or
                !std.mem.eql(u8, flow.inv().path.segments[0], "command") or
                !std.mem.eql(u8, flow.inv().path.segments[1], "sh")) return;

            // Extract name, source, and description parameters
            var name: ?[]const u8 = null;
            var script: ?[]const u8 = null;
            var description: ?[]const u8 = null;

            for (flow.inv().args) |arg| {
                if (std.mem.eql(u8, arg.name, "name")) {
                    name = try ctx.allocator.dupe(u8, unquote(arg.value));
                } else if (std.mem.eql(u8, arg.name, "source")) {
                    script = try ctx.allocator.dupe(u8, arg.value);
                } else if (std.mem.eql(u8, arg.name, "description")) {
                    description = try ctx.allocator.dupe(u8, unquote(arg.value));
                }
            }

            if (name != null and script != null) {
                try ctx.commands.append(ctx.allocator, ShellCommand{
                    .name = name.?,
                    .script = script.?,
                    .description = description orelse "",
                });
            }
        }
    };
    try eachItem(program, Ctx{ .allocator = allocator, .commands = &commands }, Ctx.visit);

    return try commands.toOwnedSlice(allocator);
}

/// Collect all build:command.zig invocations from AST
fn collectZigCommands(allocator: std.mem.Allocator, program: *const ast.Program) ![]ZigCommand {
    var commands = try std.ArrayList(ZigCommand).initCapacity(allocator, 4);
    errdefer {
        for (commands.items) |*cmd| {
            cmd.deinit(allocator);
        }
        commands.deinit(allocator);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        commands: *std.ArrayList(ZigCommand),

        fn visit(ctx: @This(), item: *const ast.Item, enclosing: ?[]const u8) !void {
            _ = enclosing;
            if (item.* != .flow) return;
            const flow = item.flow;
            // Check if this is std.build:command.zig (module-qualified)
            const mq = flow.inv().path.module_qualifier orelse return;
            if (!std.mem.eql(u8, mq, "std.build") or
                flow.inv().path.segments.len != 2 or
                !std.mem.eql(u8, flow.inv().path.segments[0], "command") or
                !std.mem.eql(u8, flow.inv().path.segments[1], "zig")) return;

            // Extract name and source parameters
            var name: ?[]const u8 = null;
            var source: ?[]const u8 = null;

            for (flow.inv().args) |arg| {
                if (std.mem.eql(u8, arg.name, "name")) {
                    name = try ctx.allocator.dupe(u8, unquote(arg.value));
                } else if (std.mem.eql(u8, arg.name, "source")) {
                    source = try ctx.allocator.dupe(u8, arg.value);
                }
            }

            if (name != null and source != null) {
                try ctx.commands.append(ctx.allocator, ZigCommand{
                    .name = name.?,
                    .source = source.?,
                });
            }
        }
    };
    try eachItem(program, Ctx{ .allocator = allocator, .commands = &commands }, Ctx.visit);

    return try commands.toOwnedSlice(allocator);
}

/// Collect all build:command invocations (native Koru commands) from AST
fn collectKoruCommands(allocator: std.mem.Allocator, program: *const ast.Program) ![]KoruCommand {
    var commands = try std.ArrayList(KoruCommand).initCapacity(allocator, 4);
    errdefer {
        for (commands.items) |*cmd| {
            cmd.deinit(allocator);
        }
        commands.deinit(allocator);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        commands: *std.ArrayList(KoruCommand),

        fn visit(ctx: @This(), item: *const ast.Item, enclosing: ?[]const u8) !void {
            _ = enclosing;
            if (item.* != .flow) return;
            const flow = &item.flow;
            // Check if this is std.build:command (not command.sh or command.zig)
            const mq = flow.inv().path.module_qualifier orelse return;
            if (!std.mem.eql(u8, mq, "std.build") or
                flow.inv().path.segments.len != 1 or
                !std.mem.eql(u8, flow.inv().path.segments[0], "command")) return;

            // Extract name and description parameters
            var name: ?[]const u8 = null;
            var description: ?[]const u8 = null;

            for (flow.inv().args) |arg| {
                if (std.mem.eql(u8, arg.name, "name")) {
                    name = try ctx.allocator.dupe(u8, unquote(arg.value));
                } else if (std.mem.eql(u8, arg.name, "description")) {
                    description = try ctx.allocator.dupe(u8, unquote(arg.value));
                }
            }

            // Must have name and at least one continuation (the execute branch)
            if (name != null and flow.body.continuations.len > 0) {
                try ctx.commands.append(ctx.allocator, KoruCommand{
                    .name = name.?,
                    .description = description orelse "",
                    .flow = flow,
                });
            }
        }
    };
    try eachItem(program, Ctx{ .allocator = allocator, .commands = &commands }, Ctx.visit);

    return try commands.toOwnedSlice(allocator);
}

// ============================================================================
// BUILD STEPS - Declarative Build Pipeline with Dependencies
// ============================================================================

const BuildStep = struct {
    name: []const u8,
    script: []const u8,
    dependencies: [][]const u8, // List of step names this depends on
    is_default: bool, // Is this a default step (not user-defined)?

    fn deinit(self: *BuildStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
        for (self.dependencies) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.dependencies);
    }
};

const BuildStepCandidate = struct {
    name: []const u8,
    script: []const u8,
    dependencies: [][]const u8,
    module: []const u8, // Which module defined this (e.g., "main", "std.build")
    is_default: bool, // Has ~[default] annotation

    fn deinit(self: *BuildStepCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.script);
        for (self.dependencies) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.dependencies);
        allocator.free(self.module);
    }
};

const BuildStepCollection = struct {
    candidates: []BuildStepCandidate,
    has_user_defined: bool, // true if ANY non-default step was found
};

/// Check if annotations contain "default"
fn hasDefaultAnnotation(annotations: []const []const u8) bool {
    for (annotations) |ann| {
        // Check for exact match or if annotation starts with "default,"
        if (std.mem.eql(u8, ann, "default")) {
            return true;
        }
        if (std.mem.startsWith(u8, ann, "default,")) {
            return true;
        }
    }
    return false;
}

/// Extract dependencies from Flow annotations using annotation_parser
/// Looks for ~[depends_on("step1", "step2", ...)] annotation
fn extractDependenciesFromAnnotations(allocator: std.mem.Allocator, annotations: []const []const u8) ![][]const u8 {
    // Use annotation_parser to find depends_on annotation
    if (try annotation_parser.getCall(allocator, annotations, "depends_on")) |call| {
        defer {
            var mutable_call = call;
            mutable_call.deinit(allocator);
        }

        // Duplicate the dependency names (call will be freed)
        var deps = try allocator.alloc([]const u8, call.args.len);
        for (call.args, 0..) |arg, i| {
            deps[i] = try allocator.dupe(u8, arg);
        }
        return deps;
    }

    // No depends_on annotation found - return empty array
    return try allocator.alloc([]const u8, 0);
}

/// Collect all build:step invocations from AST as candidates (before override resolution)
fn collectBuildStepCandidates(allocator: std.mem.Allocator, program: *const ast.Program) !BuildStepCollection {
    var candidates = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, 8);
    errdefer {
        for (candidates.items) |*candidate| {
            candidate.deinit(allocator);
        }
        candidates.deinit(allocator);
    }

    const Ctx = struct {
        allocator: std.mem.Allocator,
        candidates: *std.ArrayList(BuildStepCandidate),
        has_user_defined: bool = false, // Track if we find any non-default steps

        fn visit(ctx: *@This(), item: *const ast.Item, enclosing: ?[]const u8) !void {
            const alloc = ctx.allocator;
            if (item.* != .flow) return;
            const flow = item.flow;
            // Check if this is std.build:step (module-qualified)
            const mq = flow.inv().path.module_qualifier orelse return;
            if (!std.mem.eql(u8, mq, "std.build") or
                flow.inv().path.segments.len != 1 or
                !std.mem.eql(u8, flow.inv().path.segments[0], "step")) return;

            // Extract name and source parameters
            var name: ?[]const u8 = null;
            var script: ?[]const u8 = null;

            for (flow.inv().args) |arg| {
                if (std.mem.eql(u8, arg.name, "name")) {
                    name = try alloc.dupe(u8, unquote(arg.value));
                } else if (std.mem.eql(u8, arg.name, "source")) {
                    script = try alloc.dupe(u8, arg.value);
                }
            }

            if (name != null and script != null) {
                // Extract dependencies from annotations
                const dependencies = try extractDependenciesFromAnnotations(alloc, flow.annotations);
                // Check for ~[default] annotation
                const is_default = hasDefaultAnnotation(flow.annotations);
                if (!is_default) {
                    ctx.has_user_defined = true; // Found a user-defined step
                }
                try ctx.candidates.append(alloc, BuildStepCandidate{
                    .name = name.?,
                    .script = script.?,
                    .dependencies = dependencies,
                    .module = try alloc.dupe(u8, enclosing orelse "main"),
                    .is_default = is_default,
                });
            }
        }
    };
    var ctx = Ctx{ .allocator = allocator, .candidates = &candidates };
    try eachItem(program, &ctx, Ctx.visit);

    return BuildStepCollection{
        .candidates = try candidates.toOwnedSlice(allocator),
        .has_user_defined = ctx.has_user_defined,
    };
}

/// Resolve build step overrides - apply ~[default] precedence rules
/// Groups candidates by name and resolves which implementation to use
fn resolveBuildSteps(allocator: std.mem.Allocator, candidates: []BuildStepCandidate) ![]BuildStep {
    if (candidates.len == 0) return try allocator.alloc(BuildStep, 0);

    // Group candidates by name
    var groups = std.StringHashMap(std.ArrayList(BuildStepCandidate)).init(allocator);
    defer {
        var iter = groups.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    for (candidates) |candidate| {
        var group = groups.get(candidate.name) orelse blk: {
            const new_group = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, 2);
            try groups.put(candidate.name, new_group);
            break :blk new_group;
        };
        try group.append(allocator, candidate);
        try groups.put(candidate.name, group);
    }

    // Resolve each group
    var resolved = try std.ArrayList(BuildStep).initCapacity(allocator, groups.count());
    errdefer {
        for (resolved.items) |*step| step.deinit(allocator);
        resolved.deinit(allocator);
    }

    log.debug("\n📦 Collecting build steps...\n", .{});

    var group_iter = groups.iterator();
    while (group_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const group = entry.value_ptr.*;

        // Count defaults and non-defaults
        var defaults = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, group.items.len);
        defer defaults.deinit(allocator);
        var non_defaults = try std.ArrayList(BuildStepCandidate).initCapacity(allocator, group.items.len);
        defer non_defaults.deinit(allocator);

        for (group.items) |c| {
            if (c.is_default) {
                try defaults.append(allocator, c);
            } else {
                try non_defaults.append(allocator, c);
            }
        }

        // Apply resolution rules
        const chosen: BuildStepCandidate = blk: {
            // Error case: Multiple defaults
            if (defaults.items.len > 1) {
                log.debug("\n❌ Compilation Error: Multiple default implementations for '{s}'\n", .{name});
                for (defaults.items) |d| {
                    log.debug("  → {s}:step (line ?) [default]\n", .{d.module});
                }
                log.debug("\nOnly one default implementation per name is allowed.\n", .{});
                log.debug("This is a standard library bug.\n", .{});
                return error.MultipleDefaults;
            }

            // Error case: Multiple non-defaults
            if (non_defaults.items.len > 1) {
                log.debug("\n❌ Compilation Error: Ambiguous step definition for '{s}'\n", .{name});
                for (non_defaults.items) |nd| {
                    log.debug("  → {s}:step (line ?)\n", .{nd.module});
                }
                log.debug("\nMultiple non-default implementations found.\n", .{});
                log.debug("Remove duplicates or mark one as default.\n", .{});
                return error.AmbiguousDefinition;
            }

            // Valid case: 1 default + 1 non-default = override
            if (defaults.items.len == 1 and non_defaults.items.len == 1) {
                log.debug("  ✓ {s}: {s} (default) overridden by {s}\n", .{ name, defaults.items[0].module, non_defaults.items[0].module });
                break :blk non_defaults.items[0];
            }

            // Valid case: Only non-default
            if (non_defaults.items.len == 1) {
                log.debug("  ✓ {s}: {s}\n", .{ name, non_defaults.items[0].module });
                break :blk non_defaults.items[0];
            }

            // Valid case: Only default
            if (defaults.items.len == 1) {
                log.debug("  ✓ {s}: {s} (default)\n", .{ name, defaults.items[0].module });
                break :blk defaults.items[0];
            }

            // Should never reach here
            return error.InvalidState;
        };

        // Convert chosen candidate to BuildStep
        try resolved.append(allocator, BuildStep{
            .name = try allocator.dupe(u8, chosen.name),
            .script = try allocator.dupe(u8, chosen.script),
            .dependencies = blk: {
                var deps = try allocator.alloc([]const u8, chosen.dependencies.len);
                for (chosen.dependencies, 0..) |dep, i| {
                    deps[i] = try allocator.dupe(u8, dep);
                }
                break :blk deps;
            },
            .is_default = chosen.is_default,
        });
    }

    return try resolved.toOwnedSlice(allocator);
}

/// Perform topological sort on build steps using Kahn's algorithm
/// Returns error.CircularDependency if a cycle is detected
fn topologicalSortSteps(allocator: std.mem.Allocator, steps: []const BuildStep) ![]usize {
    const n = steps.len;
    if (n == 0) return try allocator.alloc(usize, 0);

    // Build a map from step name to index
    var name_to_index = std.StringHashMap(usize).init(allocator);
    defer name_to_index.deinit();
    for (steps, 0..) |step, i| {
        try name_to_index.put(step.name, i);
    }

    // Count incoming edges for each node
    var in_degree = try allocator.alloc(usize, n);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    // Build adjacency list
    var adj_list = try allocator.alloc(std.ArrayList(usize), n);
    defer {
        for (adj_list) |*list| list.deinit(allocator);
        allocator.free(adj_list);
    }
    for (adj_list) |*list| {
        list.* = try std.ArrayList(usize).initCapacity(allocator, 4);
    }

    // Populate adjacency list and in-degree counts
    for (steps, 0..) |step, i| {
        for (step.dependencies) |dep_name| {
            if (name_to_index.get(dep_name)) |dep_idx| {
                try adj_list[dep_idx].append(allocator, i);
                in_degree[i] += 1;
            } else {
                log.debug("Error: Step '{s}' depends on unknown step '{s}'\n", .{ step.name, dep_name });
                return error.UnknownDependency;
            }
        }
    }

    // Kahn's algorithm
    var queue = try std.ArrayList(usize).initCapacity(allocator, n);
    defer queue.deinit(allocator);
    var result = try std.ArrayList(usize).initCapacity(allocator, n);
    errdefer result.deinit(allocator);

    // Start with nodes that have no incoming edges
    for (in_degree, 0..) |degree, i| {
        if (degree == 0) {
            try queue.append(allocator, i);
        }
    }

    while (queue.items.len > 0) {
        const node = queue.orderedRemove(0);
        try result.append(allocator, node);

        // Reduce in-degree for neighbors
        for (adj_list[node].items) |neighbor| {
            in_degree[neighbor] -= 1;
            if (in_degree[neighbor] == 0) {
                try queue.append(allocator, neighbor);
            }
        }
    }

    // If we didn't process all nodes, there's a cycle
    if (result.items.len != n) {
        log.debug("Error: Circular dependency detected in build steps!\n", .{});
        log.debug("Processed {d} of {d} steps.\n", .{ result.items.len, n });

        // Find which steps are part of the cycle
        log.debug("Steps involved in cycle:\n", .{});
        for (in_degree, 0..) |degree, i| {
            if (degree > 0) {
                log.debug("  - {s} (waiting on {d} dependencies)\n", .{ steps[i].name, degree });
            }
        }

        return error.CircularDependency;
    }

    return try result.toOwnedSlice(allocator);
}

/// Execute build steps in dependency order.
///
/// `output_dir` is each step's working directory, and that is the contract: a
/// build step acts on the EMITTED artifacts, which is where they live. Every
/// deliberate site in the tree already assumed it — `koru_std/build.kz`'s three
/// defaults are all output-dir-relative, and the package-install steps a few
/// hundred lines below pass `.cwd = output_dir` too. Before this parameter
/// existed the steps silently inherited koruc's INVOCATION directory, so the
/// stdlib's own defaults only worked when you happened to invoke koruc from the
/// output directory (`310_120`, pinned red for exactly this).
fn executeBuildSteps(allocator: std.mem.Allocator, steps: []const BuildStep, output_dir: []const u8) !void {
    if (steps.len == 0) return;

    // Build a set of steps that should actually execute:
    // - All user-defined (non-default) steps
    // - Defaults that are transitively depended upon by user steps
    var needed = std.StringHashMap(void).init(allocator);
    defer needed.deinit();

    // Build name-to-index map
    var name_to_idx = std.StringHashMap(usize).init(allocator);
    defer name_to_idx.deinit();
    for (steps, 0..) |step, i| {
        try name_to_idx.put(step.name, i);
    }

    // Recursive function to mark a step and its dependencies as needed
    const MarkNeeded = struct {
        fn mark(step_name: []const u8, step_list: []const BuildStep, idx_map: *std.StringHashMap(usize), needed_set: *std.StringHashMap(void)) !void {
            if (needed_set.contains(step_name)) return; // Already marked
            try needed_set.put(step_name, {});

            if (idx_map.get(step_name)) |idx| {
                const step = step_list[idx];
                for (step.dependencies) |dep| {
                    try mark(dep, step_list, idx_map, needed_set);
                }
            }
        }
    };

    // Mark all non-default steps (and their dependencies) as needed
    for (steps) |step| {
        if (!step.is_default) {
            try MarkNeeded.mark(step.name, steps, &name_to_idx, &needed);
        }
    }

    log.debug("\n🔨 Executing {d} build step(s)...\n", .{needed.count()});

    // Topologically sort the steps
    const order = try topologicalSortSteps(allocator, steps);
    defer allocator.free(order);

    // Execute steps in order (but only those in "needed" set)
    for (order) |idx| {
        const step = steps[idx];
        if (!needed.contains(step.name)) {
            // Skip this default step - nothing needs it
            continue;
        }
        log.debug("\n📦 Step: {s}\n", .{step.name});
        if (step.dependencies.len > 0) {
            log.debug("  Dependencies: ", .{});
            for (step.dependencies, 0..) |dep, i| {
                if (i > 0) log.debug(", ", .{});
                log.debug("{s}", .{dep});
            }
            log.debug("\n", .{});
        }

        // Execute the shell script
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", step.script },
            .cwd = output_dir,
        });
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        // Print output
        if (result.stdout.len > 0) {
            try printStdout(allocator, "{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            try printStderr(allocator, "{s}", .{result.stderr});
        }

        // Check exit code
        switch (result.term) {
            .Exited => |code| {
                if (code != 0) {
                    log.debug("✗ Step '{s}' failed with exit code {d}\n", .{ step.name, code });
                    return error.BuildStepFailed;
                }
                log.debug("✓ Step '{s}' completed successfully\n", .{step.name});
            },
            else => {
                // A step that never got to exit is a machine event, not a script
                // failure — name what ended it (signal-killed usually means the OS
                // ran out of memory, or an external kill).
                var term_buf: [64]u8 = undefined;
                try printStderr(allocator, "✗ Build step '{s}' {s} — ended from outside; check memory pressure and load, then rerun.\n", .{ step.name, describeTerm(&term_buf, result.term) });
                return error.BuildStepFailed;
            },
        }
    }

    log.debug("\n✅ All build steps completed successfully!\n\n", .{});
}

fn populateInvocationSourceModules(
    items: []ast.Item,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    try populateInvocationSourceInItems(items, allocator, main_module);
}

fn populateInvocationSourceInItems(
    items: []ast.Item,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*flow| {
                try populateInvocationSourceInFlow(flow, allocator, flow.module);
            },
            .proc_decl => {},
            .event_tap => |*tap| {
                for (tap.continuations) |*cont| {
                    try populateInvocationSourceInContinuation(@constCast(cont), allocator, tap.module);
                }
            },
            .label_decl => |*label| {
                for (label.continuations) |*cont| {
                    try populateInvocationSourceInContinuation(@constCast(cont), allocator, module_name);
                }
            },
            // impl flows are now .flow items — handled by the .flow case in the caller
            .module_decl => |*module| {
                try populateInvocationSourceInItems(@constCast(module.items), allocator, module.logical_name);
            },
            else => {},
        }
    }
}

fn populateInvocationSourceInFlow(
    flow: *ast.Flow,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    try setInvocationSourceModule(flow.invMut(), allocator, module_name);
    for (flow.body.continuations) |*cont| {
        try populateInvocationSourceInContinuation(@constCast(cont), allocator, module_name);
    }
}

fn populateInvocationSourceInContinuation(
    cont: *ast.Continuation,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) std.mem.Allocator.Error!void {
    if (cont.node) |*node| {
        try populateInvocationSourceInNode(@constCast(node), allocator, module_name);
    }
    for (cont.continuations) |*nested| {
        try populateInvocationSourceInContinuation(@constCast(nested), allocator, module_name);
    }
}

fn populateInvocationSourceInNode(
    node: *ast.Node,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) std.mem.Allocator.Error!void {
    switch (node.*) {
        .invocation => |*inv| {
            try setInvocationSourceModule(inv, allocator, module_name);
        },
        .label_with_invocation => |*lwi| {
            try setInvocationSourceModule(&lwi.invocation, allocator, module_name);
        },
        .conditional_block => |*cb| {
            for (cb.nodes) |*child| {
                try populateInvocationSourceInNode(@constCast(child), allocator, module_name);
            }
        },
        .foreach => |*fe| {
            for (fe.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        .conditional => |*cond| {
            for (cond.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        .switch_result => |*sr| {
            for (sr.branches) |*branch| {
                for (branch.body) |*body_cont| {
                    try populateInvocationSourceInContinuation(@constCast(body_cont), allocator, module_name);
                }
            }
        },
        else => {},
    }
}

fn setInvocationSourceModule(
    invocation: *ast.Invocation,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    if (invocation.source_module.len == 0) {
        invocation.source_module = try allocator.dupe(u8, module_name);
    }
}

fn enforceInvocationVisibility(
    items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    main_module: []const u8,
) !void {
    try enforceInvocationVisibilityInItems(items, items, reporter, allocator, main_module);
}

fn enforceInvocationVisibilityInItems(
    items: []const ast.Item,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    for (items) |item| {
        switch (item) {
            .flow => |flow| {
                try enforceInvocationVisibilityInFlow(&flow, all_items, reporter, allocator, flow.module);
            },
            .proc_decl => {},
            .event_tap => |tap| {
                for (tap.continuations) |cont| {
                    try enforceInvocationVisibilityInContinuation(&cont, all_items, reporter, allocator, tap.module);
                }
            },
            .label_decl => |label| {
                for (label.continuations) |cont| {
                    try enforceInvocationVisibilityInContinuation(&cont, all_items, reporter, allocator, module_name);
                }
            },
            // impl flows are now .flow items — handled by the .flow case in the caller
            .module_decl => |module| {
                try enforceInvocationVisibilityInItems(module.items, all_items, reporter, allocator, module.logical_name);
            },
            else => {},
        }
    }
}

fn enforceInvocationVisibilityInFlow(
    flow: *const ast.Flow,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) !void {
    try checkInvocationVisibility(flow.inv(), all_items, reporter, allocator, module_name, flow.location);
    for (flow.body.continuations) |cont| {
        try enforceInvocationVisibilityInContinuation(&cont, all_items, reporter, allocator, module_name);
    }
}

fn enforceInvocationVisibilityInContinuation(
    cont: *const ast.Continuation,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
) std.mem.Allocator.Error!void {
    if (cont.node) |node| {
        try enforceInvocationVisibilityInNode(&node, all_items, reporter, allocator, module_name, cont.location);
    }
    for (cont.continuations) |nested| {
        try enforceInvocationVisibilityInContinuation(&nested, all_items, reporter, allocator, module_name);
    }
}

fn enforceInvocationVisibilityInNode(
    node: *const ast.Node,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
    location: errors.SourceLocation,
) std.mem.Allocator.Error!void {
    switch (node.*) {
        .invocation => |*inv| {
            try checkInvocationVisibility(inv, all_items, reporter, allocator, module_name, location);
        },
        .label_with_invocation => |*lwi| {
            try checkInvocationVisibility(&lwi.invocation, all_items, reporter, allocator, module_name, location);
        },
        .conditional_block => |cb| {
            for (cb.nodes) |node_child| {
                try enforceInvocationVisibilityInNode(&node_child, all_items, reporter, allocator, module_name, location);
            }
        },
        .foreach => |fe| {
            for (fe.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        .conditional => |cond| {
            for (cond.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        .switch_result => |sr| {
            for (sr.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceInvocationVisibilityInContinuation(&body_cont, all_items, reporter, allocator, module_name);
                }
            }
        },
        else => {},
    }
}

/// A binding list takes each name once — the declaration-side twin of the
/// call-site rule PARSE009 enforces. `tor f { x: i64, x: i64 }`, a branch
/// payload `| done { x: i64, x: i64 }`, a branch constructor
/// `=> done { x: a, x: a }`, and a record return `-> { x: i64, x: i64 }` all
/// compiled clean in the frontend and handed the backend a doubly-declared
/// Zig struct field — host noise naming symbols the author never wrote
/// (measured 2026-09-24: `.{ .x = __koru_p_0, .x = __koru_p_1 }`).
/// A label jump `@L(l.limit, limit: 2)` is worse: accepted AND ran, the
/// second `limit` silently dropped. Refuse at the author's text.
fn checkFieldsBindOnce(
    fields: []const ast.Field,
    owner: []const u8,
    reporter: *ErrorReporter,
    location: errors.SourceLocation,
) !void {
    for (fields, 0..) |field, i| {
        if (field.name.len == 0) continue;
        for (fields[0..i]) |earlier| {
            if (!std.mem.eql(u8, earlier.name, field.name)) continue;
            try reporter.addErrorWithHint(
                .PARSE010,
                location.line,
                location.column,
                "field '{s}' is bound twice in {s} — a field list takes each name once",
                .{ field.name, owner },
                "drop one, or rename it — the list cannot carry two '{s}'",
                .{field.name},
            );
            break;
        }
    }
}

/// A record TYPE string (`-> { x: i64, x: i64 }`) and a record VALUE in
/// produce position (`-> { x: a, x: a }`, a ctor field's `{ y: 1, y: 2 }`)
/// are the same `{ name: value }` list struct_literal parses — the one-name
/// rule is enforced there, and this only translates its `DuplicateField`
/// refusal into PARSE010 at the author's line. Every other parse error is
/// the pun law's own business and is left to its own surfaces.
fn checkRecordTextBindOnce(
    text: []const u8,
    owner: []const u8,
    reporter: *ErrorReporter,
    location: errors.SourceLocation,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    var trimmed = std.mem.trim(u8, text, " \t\r\n");
    // Peel prefixes that can precede a record type: ?{..}, *{..}, []{..}.
    while (trimmed.len > 0 and (trimmed[0] == '?' or trimmed[0] == '*')) trimmed = trimmed[1..];
    while (std.mem.startsWith(u8, trimmed, "[]")) trimmed = trimmed[2..];
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return;

    const fields = struct_literal.parseFields(allocator, trimmed) catch |err| switch (err) {
        error.DuplicateField => {
            const name = struct_literal.duplicateFieldName(allocator, trimmed) orelse "?";
            try reporter.addErrorWithHint(
                .PARSE010,
                location.line,
                location.column,
                "field '{s}' is bound twice in {s} — a field list takes each name once",
                .{ name, owner },
                "drop one, or rename it — the list cannot carry two '{s}'",
                .{name},
            );
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    // A field whose value is itself a record is checked by the same parser.
    for (fields) |field| {
        try checkRecordTextBindOnce(field.value, owner, reporter, location, allocator);
    }
}

/// A record VALUE written where an expression belongs — a bare return
/// (`| done -> { a: 1 }`), a constructor field's expression
/// (`~f(x: { a: 1 })`), a call or jump argument (`g(v: { a: 1 })`,
/// `@L(v: { a: 1 })`), or an arm's produce (`| ok o -> { a: 1 }`) — is the
/// same `{ name: value }` list struct_literal parses. Nothing on these
/// produce paths ran that parser before the emitter pasted the text verbatim
/// into `.{ … }` — a dropped comma reached backend Zig as
/// "expected ',' after initializer", a nameless entry as "expected field
/// initializer", a typeless one as "expected expression, found '}'", and a
/// write after a `]`-closed typed value was silently DROPPED from the store
/// type. Run the one field parser here and report its refusal as PARSE003 at
/// the author's line (DuplicateField keeps its PARSE010 translation, matching
/// checkRecordTextBindOnce).
///
/// The predicate is deliberately narrower than "starts with `{`": a one-slot
/// identity block (`{ i64 }`, `{ expr }`) is not a field list, so a text is
/// checked only when it is field-list-shaped — a `name:` head somewhere
/// (isKoruStructLiteral), a leading `:` (nameless first entry), or a
/// top-level comma (multi-entry, identity blocks excluded by construction).
fn checkValueRecordText(
    text: []const u8,
    owner: []const u8,
    reporter: *ErrorReporter,
    location: errors.SourceLocation,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    var trimmed = std.mem.trim(u8, text, " \t\r\n");
    while (trimmed.len > 0 and (trimmed[0] == '?' or trimmed[0] == '*')) trimmed = trimmed[1..];
    while (std.mem.startsWith(u8, trimmed, "[]")) trimmed = trimmed[2..];
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return;

    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    const nameless_head = inner.len > 0 and inner[0] == ':';
    const multi_entry = blk: {
        var depth: usize = 0;
        for (inner) |c| {
            switch (c) {
                '{', '(', '[' => depth += 1,
                '}', ')', ']' => if (depth > 0) {
                    depth -= 1;
                },
                ',' => if (depth == 0) break :blk true,
                else => {},
            }
        }
        break :blk false;
    };
    if (!nameless_head and !multi_entry and !struct_literal.isKoruStructLiteral(trimmed)) return;

    const fields = struct_literal.parseFields(allocator, trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => {
            const name = struct_literal.duplicateFieldName(allocator, trimmed) orelse "?";
            try reporter.addErrorWithHint(
                .PARSE010,
                location.line,
                location.column,
                "field '{s}' is bound twice in {s} — a field list takes each name once",
                .{ name, owner },
                "drop one, or rename it — the list cannot carry two '{s}'",
                .{name},
            );
            return;
        },
        error.RedundantExplicitLabel => {
            // The pun law's own code — same refusal the constructor-field
            // path gives `{ x: p.x }` (PARSE005), here for a produce/call/jump
            // record whose label duplicates the pun.
            const name = struct_literal.redundantFieldName(allocator, trimmed) orelse "?";
            try reporter.addErrorWithHint(
                .PARSE005,
                location.line,
                location.column,
                "redundant explicit label '{s}:' in {s} — punning is mandatory",
                .{ name, owner },
                "drop the label: write the bare pun instead",
                .{},
            );
            return;
        },
        else => {
            const detail = struct_literal.describeErrorIn(allocator, err, trimmed);
            try reporter.addError(
                .PARSE003,
                location.line,
                location.column,
                "malformed record value `{s}` in {s} — {s}",
                .{ trimmed, owner, detail },
            );
            return;
        },
    };
    for (fields) |field| {
        try checkValueRecordText(field.value, owner, reporter, location, allocator);
    }
}

/// A `@label(...)` jump binds the label's parameters like a call does — the
/// pun law already applies to its args (PARSE005 fires on them). PARSE009's
/// one-name rule holds here too, but checkBareArgPunning only sees
/// Invocations: `@L(l.limit, limit: 2)` bound `limit` twice and RAN — the
/// second binding silently dropped.
fn checkJumpArgsBindOnce(
    args: []const ast.Arg,
    label: []const u8,
    reporter: *ErrorReporter,
    location: errors.SourceLocation,
) !void {
    for (args, 0..) |arg, i| {
        if (arg.name.len == 0) continue;
        for (args[0..i]) |earlier| {
            if (earlier.name.len == 0) continue;
            if (!std.mem.eql(u8, earlier.name, arg.name)) continue;
            try reporter.addErrorWithHint(
                .PARSE009,
                location.line,
                location.column,
                "argument '{s}' is bound twice — '@{s}' takes each name once",
                .{ arg.name, label },
                "drop one, or give it a different name — the jump cannot carry two '{s}'",
                .{arg.name},
            );
            break;
        }
    }
}

fn enforceUniqueBindingNames(
    items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
) !void {
    try enforceUniqueBindingNamesInItems(items, reporter, allocator);
}

fn enforceUniqueBindingNamesInItems(
    items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
) !void {
    for (items) |item| {
        switch (item) {
            .event_decl => |ev| {
                // EventDecl.location is stored in USER coordinates
                // (getUserDeclStartLocation subtracts the injection); the
                // reporter's addError* take parser coordinates and classify.
                // Convert back: user line -> parser line.
                var loc = ev.location;
                loc.line += reporter.injection_line_count;
                const segment = if (ev.path.segments.len > 0) ev.path.segments[0] else "?";
                const owner = try std.fmt.allocPrint(allocator, "tor '{s}'", .{segment});
                defer allocator.free(owner);
                try checkFieldsBindOnce(ev.input.fields, owner, reporter, loc);
                if (ev.return_type) |rt| {
                    try checkRecordTextBindOnce(rt, owner, reporter, loc, allocator);
                }
                for (ev.branches) |branch| {
                    const branch_owner = try std.fmt.allocPrint(allocator, "branch '{s}'", .{branch.name});
                    defer allocator.free(branch_owner);
                    try checkFieldsBindOnce(branch.payload.fields, branch_owner, reporter, loc);
                    if (branch.resume_type) |rt| {
                        try checkRecordTextBindOnce(rt, branch_owner, reporter, loc, allocator);
                    }
                }
            },
            .immediate_impl => |impl| {
                // ImmediateImpl.location is the impl head line in parser
                // coordinates — the reporter's classify translates it.
                const loc = impl.location;
                try checkFieldsBindOnce(impl.value.fields, "the branch constructor", reporter, loc);
                if (impl.value.plain_value) |pv| {
                    try checkValueRecordText(pv, "the bare return", reporter, loc, allocator);
                }
                for (impl.value.fields) |field| {
                    if (field.expression_str) |es| {
                        try checkValueRecordText(es, "the branch constructor", reporter, loc, allocator);
                    }
                }
            },
            .flow => |flow| {
                // The body IS the head continuation — its node carries the
                // head invocation's `return_destructure` (`~f(): { a, b }`),
                // its own `destructure`, and then every nested continuation.
                try enforceUniqueBindingNamesInContinuation(&flow.body, reporter, allocator);
            },
            .event_tap => |tap| {
                for (tap.continuations) |cont| {
                    try enforceUniqueBindingNamesInContinuation(&cont, reporter, allocator);
                }
            },
            .label_decl => |label| {
                for (label.continuations) |cont| {
                    try enforceUniqueBindingNamesInContinuation(&cont, reporter, allocator);
                }
            },
            .module_decl => |module| {
                try enforceUniqueBindingNamesInItems(module.items, reporter, allocator);
            },
            else => {},
        }
    }
}

/// A destructure list is a binding list — `{ name, name }` emits two
/// `const name` decls and dies in backend Zig. `_` is a discard, not a
/// binding, and may repeat. Paths are flat (ruled 2026-10-24): every entry
/// binds exactly its local name, so `{ pos, pos.x }` binds `pos` and `x` —
/// both checked here.
fn checkDestructureBindOnce(
    fields: []const ast.DestructureField,
    owner: []const u8,
    reporter: *ErrorReporter,
    location: errors.SourceLocation,
    bound: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "_")) continue;
        for (bound.items) |n| {
            if (!std.mem.eql(u8, n, field.name)) continue;
            try reporter.addErrorWithHint(
                .PARSE010,
                location.line,
                location.column,
                "field '{s}' is bound twice in {s} — a field list takes each name once",
                .{ field.name, owner },
                "drop one, or rename it — the list cannot carry two '{s}'",
                .{field.name},
            );
            break;
        }
        try bound.append(allocator, field.name);
    }
}

fn enforceUniqueBindingNamesInContinuation(
    cont: *const ast.Continuation,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    if (cont.destructure.len > 0) {
        var bound = std.ArrayList([]const u8){};
        defer bound.deinit(allocator);
        try checkDestructureBindOnce(cont.destructure, "the destructure", reporter, cont.location, &bound, allocator);
    }
    if (cont.node) |node| {
        try enforceUniqueBindingNamesInNode(&node, reporter, allocator, cont.location);
    }
    for (cont.continuations) |nested| {
        try enforceUniqueBindingNamesInContinuation(&nested, reporter, allocator);
    }
}

fn enforceUniqueBindingNamesInNode(
    node: *const ast.Node,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    location: errors.SourceLocation,
) std.mem.Allocator.Error!void {
    switch (node.*) {
        .branch_constructor => |bc| {
            try checkFieldsBindOnce(bc.fields, "the branch constructor", reporter, location);
            if (bc.plain_value) |pv| {
                try checkValueRecordText(pv, "the bare return", reporter, location, allocator);
            }
            for (bc.fields) |field| {
                if (field.expression_str) |es| {
                    try checkValueRecordText(es, "the branch constructor", reporter, location, allocator);
                }
            }
        },
        .label_jump => |lj| {
            try checkJumpArgsBindOnce(lj.args, lj.label, reporter, location);
            for (lj.args) |arg| {
                if (arg.source_value != null) continue; // Source text is the callee transform's, not the frontend's
                try checkValueRecordText(arg.value, "the jump arguments", reporter, location, allocator);
            }
        },
        .invocation => |inv| {
            var bound = std.ArrayList([]const u8){};
            defer bound.deinit(allocator);
            try checkDestructureBindOnce(inv.return_destructure, "the return destructure", reporter, location, &bound, allocator);
            for (inv.args) |arg| {
                if (arg.source_value != null) continue;
                try checkValueRecordText(arg.value, "the call arguments", reporter, location, allocator);
            }
        },
        .label_with_invocation => |lwi| {
            var bound = std.ArrayList([]const u8){};
            defer bound.deinit(allocator);
            try checkDestructureBindOnce(lwi.invocation.return_destructure, "the return destructure", reporter, location, &bound, allocator);
            for (lwi.invocation.args) |arg| {
                if (arg.source_value != null) continue;
                try checkValueRecordText(arg.value, "the call arguments", reporter, location, allocator);
            }
        },
        .expression => |code| {
            // A continuation-arm produce (`| ok o -> { … }`) is an
            // `.expression` node; a `{`-led text there is a record literal.
            try checkValueRecordText(code, "the produce expression", reporter, location, allocator);
        },
        .conditional_block => |cb| {
            for (cb.nodes) |node_child| {
                try enforceUniqueBindingNamesInNode(&node_child, reporter, allocator, location);
            }
        },
        .foreach => |fe| {
            for (fe.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceUniqueBindingNamesInContinuation(&body_cont, reporter, allocator);
                }
            }
        },
        .conditional => |cond| {
            for (cond.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceUniqueBindingNamesInContinuation(&body_cont, reporter, allocator);
                }
            }
        },
        .switch_result => |sr| {
            for (sr.branches) |branch| {
                for (branch.body) |body_cont| {
                    try enforceUniqueBindingNamesInContinuation(&body_cont, reporter, allocator);
                }
            }
        },
        else => {},
    }
}

/// A transform-walker "machinery" parameter type — the injected context a
/// `[transform]` handler receives (`*const Invocation`, `*const Item`, `*const
/// Program`, `std.mem.Allocator`). Never a user-facing call argument. Matched by
/// substring: these types only appear as injected machinery, and the caller
/// (checkBareArgPunning) only acts when EVERY parameter is machinery, so an
/// incidental user type sharing one of these names cannot cause a false reject.
fn isTransformMachineryType(type_str: []const u8) bool {
    return std.mem.indexOf(u8, type_str, "Invocation") != null or
        std.mem.indexOf(u8, type_str, "*const Item") != null or
        std.mem.indexOf(u8, type_str, "Program") != null or
        std.mem.indexOf(u8, type_str, "Allocator") != null or
        std.mem.indexOf(u8, type_str, "ErrorReporter") != null;
}

/// PARSE006 — a bare argument must pun to an actual parameter of the callee.
///
/// The parser stores each argument's punned name — the trailing `.`-segment of a
/// path, or the whole token — in `arg.name`. An explicit `label: value` stores
/// the written label there (which, being a real parameter name, always matches),
/// and an implicit-expression arg is pre-remapped to `expr`. So the rule is
/// uniform: every argument's `name` must match one of the callee's parameters.
///
/// A bare argument whose punned name matches nothing — `echo(other)`, `echo(5)`,
/// `echo(box.other)` against `echo { v: i32 }` — is rejected here at the koru
/// frontend. The old behavior bound bare args positionally BY INDEX (emitter
/// `.v = <arg-by-position>`), so a name mismatch either compiled silently against
/// the wrong parameter or leaked into malformed emitted Zig (`undeclared 'v'`).
/// This is the bare-side twin of PARSE005 (which rejects a REDUNDANT label);
/// together they make punning the single, enforced call-site spelling.
fn checkBareArgPunning(
    invocation: *const ast.Invocation,
    event_decl: *const ast.EventDecl,
    reporter: *ErrorReporter,
    location: errors.SourceLocation,
) !void {
    const fields = event_decl.input.fields;
    const event_display = if (invocation.path.segments.len > 0)
        invocation.path.segments[invocation.path.segments.len - 1]
    else
        "event";
    const suggest_field = if (fields.len > 0) fields[0].name else "name";

    // Implicit-expression / implicit-source capability: an event with an
    // `expr: Expression` or `source: Source` param takes a bare expression /
    // source block implicitly (`~if(x > 0)`, `~for(0..n)`) — the arg binds to
    // that param regardless of its own spelling. Such a bare arg is legal even
    // before the implicit slot has been bound, so detect the capability
    // directly here rather than depend on binding order.
    //
    // The exemption covers BARE arguments only. An explicit `label: value` is
    // the author naming a parameter, and a slot the callee happens to declare
    // says nothing about whether that name exists — `if(cond: true)` against
    // `if { expr: Expression }` is an unknown parameter and is reported as one.
    var has_implicit_slot = false;
    for (fields) |field| {
        if ((field.is_expression and std.mem.eql(u8, field.name, "expr")) or
            (field.is_source and std.mem.eql(u8, field.name, "source")))
        {
            has_implicit_slot = true;
            break;
        }
    }

    // Does the callee's handler read its own `invocation.args`? Declaring any
    // walker machinery is the signal that it does.
    var has_machinery = false;
    for (fields) |field| {
        if (isTransformMachineryType(field.type)) {
            has_machinery = true;
            break;
        }
    }

    // Handler-injection transform exemption. Some `[transform]` events declare
    // ONLY the transform walker's injected machinery as parameters — `*const
    // Invocation`, `*const Item`, `*const Program`, `std.mem.Allocator`,
    // `*std/compiler:ErrorReporter` (e.g.
    // `~for`'s cousins `new`, `ln`, `router`, `field:new`). The compiler passes
    // those in; the USER's call arguments are read positionally from
    // `invocation.args` inside the handler body and never bind to a declared
    // parameter. There is thus no parameter for a call-site arg to pun against,
    // so PARSE006's name-match does not apply.
    //
    // DECISION (2026-07-07, Lars): exempt these rather than force each transform
    // to declare a user-facing parameter. The cleaner long-term shape is for a
    // transform's signature to describe its CALL SITE (e.g. `field:new { bits:
    // Expression }`, the way `match`/`char` now do) with the machinery injected
    // implicitly — revisit here if we take that on. Also unifies a prior
    // inconsistency: `list:new(i64)` was already exempt while `field:new(bits)`
    // was not.
    //
    // The exemption is from NAME-MATCHING, not from the call grammar. The first
    // call argument is the positional subject slot; every argument after it
    // must be an explicit `name: expr` or a bare identifier path that puns
    // (`f(x, y)` reads `y` as `y: y`). A bare literal or compound expression
    // can never pun — `std/store:new(game, 37)` silently dropped the 37 while
    // the transform waited on a `capacity:` label that never came (210_240,
    // 210_241, 210_242 pin this for store:new, pump:create, and the
    // after-a-named-arg position).
    var all_machinery = fields.len > 0;
    if (all_machinery) {
        for (fields) |field| {
            if (!isTransformMachineryType(field.type)) {
                all_machinery = false;
                break;
            }
        }
    }
    const free_form_callee = has_implicit_slot or all_machinery;

    // A call binds each name once. Two args carrying the same name —
    // `new(s, capacity: 64, capacity: 32)`, an explicit `expr:` beside the
    // parser's implicit positional remap — resolved last-wins downstream
    // with no diagnostic: measured 2026-09-24, the doubled capacity emitted
    // [32]i64 columns and the doubled expr emitted only the first value.
    // That is the labeled twin of the silent drop PARSE006 walls on the
    // bare side, and it holds even where the name binds nothing the checker
    // can see (a free-form callee's labels are its own data — a repeat is
    // still ambiguous). Synthesized marker args are excluded: they are
    // parser machinery gated on the slot's absence, not a user spelling.
    for (invocation.args, 0..) |arg, dup_i| {
        if (std.mem.eql(u8, arg.value, "<implicit_source>") or
            std.mem.eql(u8, arg.value, "<program_ast>")) continue;
        for (invocation.args[0..dup_i]) |earlier| {
            if (std.mem.eql(u8, earlier.value, "<implicit_source>") or
                std.mem.eql(u8, earlier.value, "<program_ast>")) continue;
            if (!std.mem.eql(u8, earlier.name, arg.name)) continue;
            try reporter.addErrorWithHint(
                .PARSE009,
                location.line,
                location.column,
                "argument '{s}' is bound twice — '{s}' takes each name once",
                .{ arg.name, event_display },
                "drop one, or give it a different name — the call cannot carry two '{s}'",
                .{arg.name},
            );
            break;
        }
    }

    for (invocation.args, 0..) |arg, arg_index| {
        // Expression/Source args are already resolved to their parameter
        // (implicit `expr`/`source` binding included) — not raw puns to check.
        if (arg.expression_value != null or arg.source_value != null) continue;

        // The hint names the parameter at this argument's own position —
        // `mm-of(1, 2, 3)` against `mm-of { kind, a, b }` must hint
        // `kind: 1`, `a: 2`, `b: 3`, not `kind:` on all three. Out-of-range
        // positions fall back to the first field.
        const positional_field = if (arg_index < fields.len)
            fields[arg_index].name
        else
            suggest_field;

        if (!arg.had_explicit_label and free_form_callee) {
            // On a free-form callee a bare arg carries no parameter name to
            // match — its spelling IS the contract. args[0] is the positional
            // subject whatever it is spelled (on an implicit-slot callee the
            // bound subject was already skipped above; on a machinery-only
            // callee nothing binds it, the handler reads it by position).
            // Every later bare arg must be a punnable identifier path —
            // `std/list:get(xs, i)` reads `i` as `i: i`. A bare literal or
            // compound expression can never pun: refuse it.
            var resolved = arg_index == 0 or struct_literal.punnableName(arg.value) != null;
            if (!resolved) {
                // The parser's implicit-slot synthesis appends bare marker
                // args already named to their declared field —
                // `{name: "source", value: "<implicit_source>"}` for an
                // unwritten block, `"<program_ast>"` for a Program param.
                // Those are resolved bindings, not user pun candidates.
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, arg.name)) {
                        resolved = true;
                        break;
                    }
                }
            }
            if (!resolved) {
                try reporter.addErrorWithHint(
                    .PARSE006,
                    location.line,
                    location.column,
                    "bare argument '{s}' does not name a parameter of '{s}' — an explicit label is required",
                    .{ arg.value, event_display },
                    "write it with an explicit label: '{s}: {s}'",
                    .{ positional_field, arg.value },
                );
            }
            continue;
        }

        // A callee that declares transform machinery reads `invocation.args` in
        // its own handler, so its labels are free-form data rather than
        // parameter names — `liquid_template:emit(tpl, name: "Alice")` passes
        // template context, and `name` is deliberately not a parameter. Only a
        // callee with a CLOSED parameter list can have a label be wrong.
        if (arg.had_explicit_label and has_machinery) continue;

        var matches = false;
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, arg.name)) {
                matches = true;
                break;
            }
        }
        if (matches) continue;

        if (arg.had_explicit_label) {
            // The author WROTE `name: value`, but `name` is not a parameter of
            // the callee — an unknown-parameter error, caught at the koru
            // frontend rather than leaking as a raw Zig "no field named" later.
            try reporter.addErrorWithHint(
                .PARSE006,
                location.line,
                location.column,
                "unknown parameter '{s}' — '{s}' has no parameter named '{s}'",
                .{ arg.name, event_display, arg.name },
                "remove the argument, or label it with a real parameter (e.g. '{s}:')",
                .{positional_field},
            );
        } else {
            // A bare argument whose punned name matches nothing — needs a label.
            try reporter.addErrorWithHint(
                .PARSE006,
                location.line,
                location.column,
                "bare argument '{s}' does not name a parameter of '{s}' — an explicit label is required",
                .{ arg.value, event_display },
                "write it with an explicit label: '{s}: {s}'",
                .{ positional_field, arg.value },
            );
        }
    }
}

fn checkInvocationVisibility(
    invocation: *const ast.Invocation,
    all_items: []const ast.Item,
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    module_name: []const u8,
    location: errors.SourceLocation,
) !void {
    const event_decl = emitter_helpers.findEventDeclByPath(all_items, &invocation.path) orelse return;
    try checkBareArgPunning(invocation, event_decl, reporter, location);
    const source_module = if (invocation.source_module.len > 0)
        invocation.source_module
    else
        module_name;

    if (std.mem.eql(u8, source_module, event_decl.module) or event_decl.is_public) {
        return;
    }

    // Build path display string: "module:segment" (just first segment for simplicity)
    const segment = if (invocation.path.segments.len > 0) invocation.path.segments[0] else "unknown";
    const event_display = if (invocation.path.module_qualifier) |mq|
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ mq, segment })
    else
        try std.fmt.allocPrint(allocator, "{s}", .{segment});
    defer allocator.free(event_display);

    try reporter.addErrorWithHint(
        .KORU044,
        location.line,
        location.column,
        "cannot access private event '{s}' from module '{s}'",
        .{ event_display, source_module },
        "mark the tor as public with ~pub tor",
        .{},
    );
}

// Locate the bundled `skills/` source directory relative to the koruc
// executable, mirroring how koru_std is resolved (npm package: binaries/../skills).
// Returns an owned path the caller frees, or null if not found.
fn findBundledSkills(allocator: std.mem.Allocator) !?[]const u8 {
    var exe_path_buf: [4096]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch return null;
    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;

    const rel = [_][]const []const u8{
        &[_][]const u8{ exe_dir, "..", "skills" }, // npm: binaries/../skills
        &[_][]const u8{ exe_dir, "..", "..", "skills" }, // zig-out/bin/../../skills
    };
    for (rel) |parts| {
        const p = try std.fs.path.join(allocator, parts);
        if (std.fs.accessAbsolute(p, .{})) |_| {
            return p;
        } else |_| {
            allocator.free(p);
        }
    }
    // ./skills (running from the repo root)
    if (std.fs.cwd().access("skills", .{})) |_| {
        return try allocator.dupe(u8, "skills");
    } else |_| {}
    return null;
}

fn skillsHasFilter(args: [][:0]u8) bool {
    for (args) |a| {
        if (!std.mem.startsWith(u8, a, "--")) return true;
    }
    return false;
}

fn skillsMatches(args: [][:0]u8, name: []const u8) bool {
    for (args) |a| {
        if (!std.mem.startsWith(u8, a, "--") and std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

// `koruc skills install [name...] [--global]` — copy bundled agent skills into
// .claude/skills/ (project, default) or ~/.claude/skills/ (--global). Reinstall
// overwrites, so it doubles as update. No name args installs every bundled skill.
fn runSkillsInstall(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "install")) {
        try printStderr(allocator, "Usage: koruc skills install [name...] [--global]\n", .{});
        return;
    }
    const rest = args[1..];

    var global = false;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--global")) global = true;
    }
    const have_filter = skillsHasFilter(rest);

    const src_path = (try findBundledSkills(allocator)) orelse {
        try printStderr(allocator, "Error: could not locate the bundled skills/ directory.\n", .{});
        return;
    };
    defer allocator.free(src_path);

    const target_root = if (global) blk: {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
            try printStderr(allocator, "Error: --global needs HOME to be set.\n", .{});
            return;
        };
        defer allocator.free(home);
        break :blk try std.fs.path.join(allocator, &[_][]const u8{ home, ".claude", "skills" });
    } else try std.fs.path.join(allocator, &[_][]const u8{ ".claude", "skills" });
    defer allocator.free(target_root);

    var src_dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch |err| {
        try printStderr(allocator, "Error opening {s}: {}\n", .{ src_path, err });
        return;
    };
    defer src_dir.close();

    var installed: usize = 0;
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (have_filter and !skillsMatches(rest, entry.name)) continue;

        var skill_src = src_dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer skill_src.close();
        // A skill directory must contain SKILL.md; skip anything else.
        skill_src.access("SKILL.md", .{}) catch continue;

        const dst_path = try std.fs.path.join(allocator, &[_][]const u8{ target_root, entry.name });
        defer allocator.free(dst_path);
        std.fs.cwd().makePath(dst_path) catch |err| {
            try printStderr(allocator, "Error creating {s}: {}\n", .{ dst_path, err });
            return;
        };
        var dst_dir = std.fs.cwd().openDir(dst_path, .{}) catch |err| {
            try printStderr(allocator, "Error opening {s}: {}\n", .{ dst_path, err });
            return;
        };
        defer dst_dir.close();

        var fit = skill_src.iterate();
        while (try fit.next()) |f| {
            if (f.kind != .file) continue;
            skill_src.copyFile(f.name, dst_dir, f.name, .{}) catch |err| {
                try printStderr(allocator, "Error copying {s}/{s}: {}\n", .{ entry.name, f.name, err });
                return;
            };
        }
        try printStdout(allocator, "  installed {s} -> {s}/{s}/\n", .{ entry.name, target_root, entry.name });
        installed += 1;
    }

    if (installed == 0) {
        try printStderr(allocator, "No skills installed (no matching skill found).\n", .{});
    } else {
        try printStdout(allocator, "Installed {d} skill(s).\n", .{installed});
    }
}

/// The koru-diagnostic gate: when the reporter holds errors they go to
/// stderr and the process stops — a pass that produced diagnostics never
/// reaches the user as a raw Zig error or stack trace.
fn exitOnReportedErrors(reporter: *ErrorReporter) !void {
    if (reporter.hasErrors()) {
        const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
        try reporter.printErrors(stderr_writer);
        std.process.exit(1);
    }
}

/// The wider unparseable gate — reporter errors OR parse_error AST nodes
/// (the lenient parser can mint the second without the first). Prints the
/// reporter's errors and, when the reporter is empty, the AST nodes — a
/// refused program never exits 1 in silence.
/// Recursive variant-tag probe: true when any invocation under `cont` carries
/// the `variant` base tag — parameterized forms like `mlir[gpu]` count.
fn contHasVariant(cont: *const ast.Continuation, variant: []const u8) bool {
    if (cont.node) |*nd| {
        if (nd.* == .invocation) {
            if (nd.invocation.variant) |v| {
                const v_base = if (std.mem.indexOfScalar(u8, v, '[')) |bi| v[0..bi] else v;
                if (std.mem.eql(u8, v_base, variant)) return true;
            }
        }
    }
    for (cont.continuations) |*child| {
        if (contHasVariant(child, variant)) return true;
    }
    return false;
}

fn exitOnUnparseable(reporter: *ErrorReporter, source_file: *const ast.Program) !void {
    if (reporter.hasErrors() or source_file.hasParseErrors()) {
        const stderr_writer = FileWriter{ .file = std.fs.File.stderr() };
        try reporter.printErrors(stderr_writer);
        if (!reporter.hasErrors()) {
            // Reporter is empty but AST has parse_error nodes — print them
            try import_pipeline.printAstParseErrors(source_file, stderr_writer);
        }
        std.process.exit(1);
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leak_status = gpa.deinit();
        if (leak_status == .leak) {
            log.debug("Memory leak detected\n", .{});
        }
    }
    // Read-after-free diagnostic: when KORU_POISON is set, route frontend
    // allocations through a poison allocator (fill-on-free + leak, or reuse mode)
    // so any stale pointer into freed memory reads deterministic garbage on every
    // OS. Inert unless KORU_POISON is set — normal builds use the GPA unchanged.
    // See src/poison_allocator.zig. Used to hunt the location.file/0xAA dangle class.
    var poison = @import("poison_allocator.zig").PoisonAllocator.init(std.heap.page_allocator);
    const allocator = if (std.process.hasEnvVarConstant("KORU_POISON")) poison.allocator() else gpa.allocator();

    // Arena allocator for parse phase - all parsed data (AST, strings, etc.)
    // gets freed in one shot after compilation completes
    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();

    // Arena allocator for compilation phase - purity checking,
    // code generation strings, etc. Freed after output file is written
    var compile_arena = std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();
    const compile_allocator = compile_arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printStderr(allocator, "{s}", .{usage});
        return;
    }

    // Check for zen command
    if (std.mem.eql(u8, args[1], "zen")) {
        try printStdout(allocator, "{s}", .{zen_text});

        // Easter egg: check for --buzzword flag
        if (args.len > 2 and std.mem.eql(u8, args[2], "--buzzword")) {
            try printStdout(allocator, "{s}", .{zen_buzzword});
        }
        return;
    }

    // Check for init command - initialize project in current directory
    if (std.mem.eql(u8, args[1], "init")) {
        // Check if koru.json already exists
        if (std.fs.cwd().access("koru.json", .{})) |_| {
            try printStderr(allocator, "Error: koru.json already exists in this directory\n", .{});
            try printStderr(allocator, "This directory is already a Koru project.\n", .{});
            return;
        } else |_| {}

        // Check if app.kz already exists
        if (std.fs.cwd().access("app.kz", .{})) |_| {
            try printStderr(allocator, "Error: app.kz already exists in this directory\n", .{});
            return;
        } else |_| {}

        // Get directory name for project name
        var cwd_buf: [4096]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch {
            try printStderr(allocator, "Error: could not determine current directory\n", .{});
            return;
        };
        const project_name = std.fs.path.basename(cwd);

        // Create koru.json
        const koru_json_content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "name": "{s}",
            \\  "version": "0.1.0",
            \\  "entry": "app.kz",
            \\  "paths": {{
            \\    "node": "./node_modules"
            \\  }}
            \\}}
            \\
        , .{project_name});
        defer allocator.free(koru_json_content);

        const json_file = std.fs.cwd().createFile("koru.json", .{}) catch |err| {
            try printStderr(allocator, "Error creating koru.json: {}\n", .{err});
            return;
        };
        defer json_file.close();
        json_file.writeAll(koru_json_content) catch |err| {
            try printStderr(allocator, "Error writing koru.json: {}\n", .{err});
            return;
        };

        // Create app.kz
        const app_kz_content =
            \\// A Koru application
            \\//
            \\// Run with: koruc app.kz && ./a.out
            \\
            \\~import std/package
            \\
            \\// Declare npm dependencies (install with: koruc app.kz i)
            \\// ~std.package:requires.npm {
            \\//     "@koru/example": "^1.0.0"
            \\// }
            \\
            \\~tor main {}
            \\
            \\~proc main|zig {
            \\    const std = @import("std");
            \\    std.debug.print("Hello from Koru!\n", .{});
            \\}
            \\
            \\// Entry point
            \\~main()
            \\
        ;

        const app_file = std.fs.cwd().createFile("app.kz", .{}) catch |err| {
            try printStderr(allocator, "Error creating app.kz: {}\n", .{err});
            return;
        };
        defer app_file.close();
        app_file.writeAll(app_kz_content) catch |err| {
            try printStderr(allocator, "Error writing app.kz: {}\n", .{err});
            return;
        };

        try printStdout(allocator, "Initialized Koru project '{s}'\n", .{project_name});
        try printStdout(allocator, "\n", .{});
        try printStdout(allocator, "Created:\n", .{});
        try printStdout(allocator, "  koru.json  - Project configuration\n", .{});
        try printStdout(allocator, "  app.kz     - Application entry point\n", .{});
        try printStdout(allocator, "\n", .{});
        try printStdout(allocator, "Next steps:\n", .{});
        try printStdout(allocator, "  koruc app.kz       # Compile and run\n", .{});
        try printStdout(allocator, "  koruc app.kz i     # Install npm dependencies\n", .{});
        return;
    }

    // Check for create command
    if (std.mem.eql(u8, args[1], "create")) {
        if (args.len < 4) {
            try printStderr(allocator, "Usage: koruc create [exe|lib] <name>\n", .{});
            return;
        }

        const project_type_str = args[2];
        const project_name = args[3];

        const project_type = if (std.mem.eql(u8, project_type_str, "exe"))
            project_template.ProjectType.exe
        else if (std.mem.eql(u8, project_type_str, "lib"))
            project_template.ProjectType.lib
        else {
            try printStderr(allocator, "Error: unknown project type '{s}'\n", .{project_type_str});
            try printStderr(allocator, "Use: koruc create [exe|lib] <name>\n", .{});
            return;
        };

        project_template.createProject(allocator, project_type, project_name, null) catch |err| {
            switch (err) {
                error.InvalidProjectName => {
                    try printStderr(allocator, "Error: invalid project name '{s}'\n", .{project_name});
                    try printStderr(allocator, "Project names must start with a letter and contain only alphanumeric characters, dashes, or underscores\n", .{});
                },
                error.PathAlreadyExists => {
                    try printStderr(allocator, "Error: directory '{s}' already exists\n", .{project_name});
                },
                else => {
                    try printStderr(allocator, "Error creating project: {}\n", .{err});
                },
            }
            return;
        };
        return;
    }

    // Check for skills command — copy bundled agent skills into .claude/skills/.
    // The actual file work is pure Zig (below); the npm `bin` shim only forwards
    // argv to this binary.
    if (std.mem.eql(u8, args[1], "skills")) {
        try runSkillsInstall(allocator, args[2..]);
        return;
    }

    // Check for build or run command
    var run_after_build = false;
    var bundle_after_build = false;
    var build_executable = true;
    var build_library = false;
    var arg_offset: usize = 1;

    if (std.mem.eql(u8, args[1], "build")) {
        build_executable = true;
        arg_offset = 2;
    } else if (std.mem.eql(u8, args[1], "run")) {
        build_executable = true;
        run_after_build = true;
        arg_offset = 2;
    } else if (std.mem.eql(u8, args[1], "bundle")) {
        // Compile like `build`, then package the output as a macOS .app from
        // its std/build:app declaration. -o names the .app path (must end in
        // .app); without it the bundle is `<name>.app` beside the build.
        build_executable = true;
        bundle_after_build = true;
        arg_offset = 2;
    } else if (std.mem.eql(u8, args[1], "lib")) {
        // A LIBRARY, not a program. The difference is not the output format —
        // it is what counts as a ROOT. Compiling a program, the roots are its
        // flows and anything nobody calls does not exist; compiling a library,
        // the roots are what it EXPORTS, and "nobody calls it here" is the
        // normal case rather than evidence it is dead.
        //
        // `pub` already carries exactly that meaning — visible outside this
        // module — so a library needs no new marker, only a compilation that
        // treats the entry module's `pub` items as the things to keep.
        build_library = true;
        // Still EMIT — a library has output, it just is not an executable.
        // Linking is a later question and a per-target one; what  decides
        // here is the root rule: a library keeps its exports.
        build_executable = true;
        arg_offset = 2;
    }

    var input_file: ?[]const u8 = null;
    var command_candidate: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var exe_output_name: ?[]const u8 = null;
    var check_only = false;
    var deep_check = false;
    var use_visitor = false; // Visitor pattern needs more work before becoming default
    var ast_json_mode = false; // Output AST as JSON
    var ast_canon_mode = false; // Output COMPLETE post-parse AST as JSON, trivia-stripped (roundtrip tree-equality surface)
    var print_mode = false; // Print canonical Koru source from the post-parse AST
    var list_imports_mode = false; // Output transitive imports as JSON list (for harness caching)
    var check_k_convertible_mode = false; // Report whether a `.kz` file could become a pure-Koru `.k` (no host bytes)
    var registry_json_mode = false; // Output TypeRegistry as JSON
    var ccp_mode = false; // CCP daemon mode for Studio integration
    var fail_fast = false; // Stop at first parse error (default: lenient mode)
    var install_packages = false; // Run package managers (npm install, cargo fetch, etc.)
    var show_help = false; // Defer help display until after AST parsing

    // Initialize compiler configuration
    var compiler_config = try CompilerConfig.init(allocator);
    defer compiler_config.deinit();
    // `koruc lib` is a compilation MODE, decided before any flag parsing: it
    // changes what counts as a root, not how anything is spelled.
    compiler_config.library = build_library;

    var i: usize = arg_offset;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            // Continue parsing to find input file - we'll show help after AST is built
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try printStdout(allocator, "koruc {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--check")) {
            check_only = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--deep-check")) {
            // Run the entire compiler pipeline — transforms, backend check-flow,
            // emission — but skip the final `zig build` of the emitted program.
            // The flag reaches the backend through compiler_env.json, so cached
            // and minted backends honour it without a rebuild.
            deep_check = true;
            try compiler_config.addFlag("deep-check");
        } else if (std.mem.eql(u8, arg, "--ccp")) {
            ccp_mode = true;
            try compiler_config.addFlag("ccp");
        } else if (std.mem.eql(u8, arg, "--ast-json")) {
            ast_json_mode = true;
        } else if (std.mem.eql(u8, arg, "--ast-canon")) {
            ast_canon_mode = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--print")) {
            print_mode = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--list-imports")) {
            list_imports_mode = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--check-k-convertible")) {
            check_k_convertible_mode = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--registry-json")) {
            registry_json_mode = true;
            build_executable = false;
        } else if (std.mem.eql(u8, arg, "--visitor")) {
            use_visitor = true;
            try printStdout(allocator, "Using visitor pattern backend (experimental)\n", .{});
        } else if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_fast = true;
        } else if (std.mem.eql(u8, arg, "--install-packages")) {
            install_packages = true;
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.startsWith(u8, arg, "-O")) {
            // Zig-conventional optimize flag: `-O ReleaseFast` or
            // `-OReleaseFast`. Without this branch, `-O` fell into the
            // pass-through bucket below as a dead flag and the next arg a
            // stray positional — the build silently stayed Debug.
            const mode: []const u8 = if (arg.len > 2) arg[2..] else blk: {
                i += 1;
                if (i >= args.len) {
                    try printStderr(allocator, "Error: -O requires an optimization mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)\n", .{});
                    return;
                }
                break :blk args[i];
            };
            if (std.ascii.eqlIgnoreCase(mode, "debug")) {
                try compiler_config.addFlag("debug");
            } else if (std.ascii.eqlIgnoreCase(mode, "releasefast") or std.ascii.eqlIgnoreCase(mode, "fast")) {
                try compiler_config.addFlag("release=fast");
            } else if (std.ascii.eqlIgnoreCase(mode, "releasesafe") or std.ascii.eqlIgnoreCase(mode, "safe")) {
                try compiler_config.addFlag("release=safe");
            } else if (std.ascii.eqlIgnoreCase(mode, "releasesmall") or std.ascii.eqlIgnoreCase(mode, "small")) {
                try compiler_config.addFlag("release=small");
            } else {
                try printStderr(allocator, "Error: unknown optimization mode '{s}' — expected Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall\n", .{mode});
                return;
            }
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
            try compiler_config.addFlag("verbose");
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            // --lang=<name> selects the default variant for proc-body emission.
            // The value must match a variant tag used in source (e.g. "zig", "js").
            // Bodies tagged `|<lang>` are picked when no explicit build:variants
            // registration exists for an event; events without a `|<lang>` variant
            // surface as KORU110 at their call sites.
            try compiler_config.setLang(arg["--lang=".len..]);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                try printStderr(allocator, "Error: -o requires an argument\n", .{});
                return;
            }
            // If output ends with .zig, it's the backend file
            // Otherwise it's the executable name
            if (std.mem.endsWith(u8, args[i], ".zig")) {
                output_file = args[i];
                build_executable = false; // Explicitly requesting .zig output, don't build
            } else {
                exe_output_name = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // First non-flag arg is input file
            // Second non-flag arg might be a shell command (checked later after parsing)
            // Any more would be arguments to the command
            if (input_file == null) {
                input_file = arg;
            } else if (command_candidate == null) {
                // Command-position argument. Whether it names a real
                // [comptime|command] event is only knowable post-parse, but
                // the parse-time import gate needs it NOW: `command(explain)`
                // entries gate imports on the invocation's command position.
                // Injected below as the `command=<name>` provider atom.
                command_candidate = arg;
            }
            // Silently ignore other non-flag args - might be command name or command args
        } else {
            // Unknown flag - add to compiler config for backend use
            // Strip leading dashes and add to config
            const flag_name = if (std.mem.startsWith(u8, arg, "--"))
                arg[2..]
            else if (std.mem.startsWith(u8, arg, "-"))
                arg[1..]
            else
                arg;

            try compiler_config.addFlag(flag_name);
        }
    }

    // Inject the command-position argument as the `command=<name>` provider
    // atom, so the parse-time import gate can evaluate `command(x)` entries
    // (`~[command(explain)]import std/explain` — the module rides along only
    // under its command). Mirrors the build=<os> injection below.
    if (command_candidate) |cmd| {
        const flag = try std.fmt.allocPrint(allocator, "command={s}", .{cmd});
        defer allocator.free(flag);
        try compiler_config.addFlag(flag);
    }

    // `to-k` classifies a single file — the facet question is per-file, so it
    // rides the same pre-merge AST surface as --check-k-convertible.
    const to_k_mode = command_candidate != null and
        std.mem.eql(u8, command_candidate.?, "to-k");

    // Auto-inject build=<host_os> if no build=<os> flag was passed.
    // This makes os-keyed variant selection (e.g. ~[build(macos)]) work without
    // requiring the user to pass --build=<os> on every invocation. Cross-compilation
    // can still override by passing --build=<other_os> explicitly.
    {
        var has_build_os = false;
        for (compiler_config.flags.items) |f| {
            if (std.mem.startsWith(u8, f, "build=")) {
                has_build_os = true;
                break;
            }
        }
        if (!has_build_os) {
            const tag_name = @tagName(@import("builtin").os.tag);
            const flag = try std.fmt.allocPrint(allocator, "build={s}", .{tag_name});
            defer allocator.free(flag);
            try compiler_config.addFlag(flag);
        }
    }

    // Initialize logging level from CLI flags
    log.init(compiler_config.hasFlag("verbose"), compiler_config.hasFlag("debug"));

    // CCP daemon mode - enter interactive command loop (only when no input file)
    if (ccp_mode and input_file == null) {
        try ccp.ccpMain(allocator);
        return;
    }

    // Handle built-in frontend commands that don't require compilation
    if (input_file) |maybe_cmd| {
        if (std.mem.eql(u8, maybe_cmd, "deps")) {
            // `koruc deps <module>` is the ARGUMENTS SWAPPED. The command form is
            // `koruc <module> deps` — module first, verb second — and every other
            // verb already says so, because an unresolvable module in the input
            // position is a plain error. `deps` alone is intercepted here before
            // input resolution ever runs, so the extra argument used to be
            // discarded in silence: it printed a clean toolchain report and
            // exited 0, which reads as "your project's dependencies are fine".
            //
            // Refuse instead, and when the stray token IS a module, say the line
            // the user meant to type.
            for (args) |arg| {
                if (std.mem.eql(u8, arg, "deps")) continue;
                if (std.mem.startsWith(u8, arg, "-")) continue;
                if (std.mem.eql(u8, arg, "install")) continue;
                if (std.mem.endsWith(u8, arg, "koruc")) continue;

                if (koruModuleExists(allocator, arg)) {
                    try printStderr(allocator, "error: `koruc deps {s}` has the arguments the wrong way round\n\n" ++
                        "  `deps` is a command ON a module, so the module comes first:\n" ++
                        "      koruc {s} deps\n\n" ++
                        "  Bare `koruc deps` checks the toolchain itself and takes no module.\n", .{ arg, arg });
                } else {
                    try printStderr(allocator, "error: `koruc deps` does not take an argument `{s}`\n\n" ++
                        "  Bare `koruc deps` checks the toolchain; `koruc deps install` upgrades it.\n" ++
                        "  To inspect a project's dependencies, name the module first:\n" ++
                        "      koruc <module> deps\n", .{arg});
                }
                std.process.exit(1);
            }

            // deps runs directly in frontend - no compilation needed
            try runBuiltinDeps(allocator, args);
            return;
        }
    }

    if (input_file == null) {
        if (show_help) {
            // No input file - show basic help with flags from compiler.kz
            try printStdout(allocator, "{s}", .{usage});
            try printBasicHelpFlags(allocator);
            return;
        }
        try printStderr(allocator, "Error: no input file specified\n\n{s}", .{usage});
        // A printed error that exits 0 is indistinguishable from success to
        // anything scripting koruc. The `deps <module>` sibling already
        // refuses with exit(1); this path used to `return` from `main` and
        // look the same as `koruc --help`.
        std.process.exit(1);
    }

    // Resolve the input. A user may name a concrete facet (`pump.kz`) or the
    // bare STEM (`pump`) — the stem is the real unit of compilation, since
    // `.k`/`.kz`/`.kjs` are facets of one module (merged below). An existing
    // explicit path is used verbatim (preserves the relative path the user
    // passed); a bare stem is probed against the canonical extensions.
    const input = blk: {
        const raw = input_file.?;
        if (file_types.isKoruFile(raw)) break :blk raw;
        for (file_types.koru_extensions) |ext| {
            const cand = try std.fmt.allocPrint(parse_allocator, "{s}{s}", .{ raw, ext });
            if (std.fs.cwd().access(cand, .{})) |_| break :blk cand else |_| {}
        }
        break :blk raw; // no facet on disk; openFile below errors clearly
    };

    // Default output file: input.kz -> backend.zig (in same directory)
    // We use "backend.zig" because build.zig expects this name
    var allocated_output: ?[]u8 = null;
    defer if (allocated_output) |ao| allocator.free(ao);

    if (output_file == null and !check_only) {
        const input_dir = std.fs.path.dirname(input) orelse ".";
        allocated_output = try std.fs.path.join(allocator, &[_][]const u8{ input_dir, "backend.zig" });
        output_file = allocated_output;
    }

    // Read input file. A missing input is a user error, not a compiler bug, so
    // it gets a clean CLI diagnostic — never a raw Zig FileNotFound stack trace.
    const file = std.fs.cwd().openFile(input, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const raw = input_file.?;
            if (file_types.isKoruFile(raw)) {
                try printStderr(allocator, "error: input file not found: {s}\n\n  koruc could not open the file you named — check the path and try again.\n", .{raw});
            } else {
                var probed: []u8 = try allocator.dupe(u8, "");
                for (file_types.koru_extensions, 0..) |ext, ext_idx| {
                    const sep = if (ext_idx != 0) ", " else "";
                    probed = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ probed, sep, raw, ext });
                }
                try printStderr(allocator, "error: no koru module found for '{s}'\n\n  koruc looked for: {s}\n  None exist in the current directory — name an existing module or facet.\n", .{ raw, probed });
            }
            std.process.exit(1);
        },
        else => return err,
    };
    defer file.close();
    const file_size = try file.getEndPos();
    const source = try parse_allocator.alloc(u8, file_size);
    _ = try file.read(source);

    const input_dir = std.fs.path.dirname(input) orelse ".";

    // Convert input_dir to absolute path for {{ ENTRY }} interpolation
    const input_dir_absolute = try std.fs.cwd().realpathAlloc(allocator, input_dir);
    defer allocator.free(input_dir_absolute);

    // Create canonical entry file path for filtering in directory imports
    // When a file imports its own directory, we must exclude itself from submodules
    const entry_file_absolute = try std.fs.path.join(allocator, &[_][]const u8{
        input_dir_absolute,
        std.fs.path.basename(input),
    });
    defer allocator.free(entry_file_absolute);

    const project_root = blk: {
        var search_dir: []const u8 = input_dir_absolute;
        while (true) {
            // Check if koru.json exists in this directory
            const json_path = try std.fs.path.join(allocator, &[_][]const u8{ search_dir, "koru.json" });
            defer allocator.free(json_path);

            if (std.fs.cwd().access(json_path, .{})) |_| {
                // Found it!
                break :blk try allocator.dupe(u8, search_dir);
            } else |_| {}

            // Try parent directory
            const parent = std.fs.path.dirname(search_dir);
            if (parent == null or std.mem.eql(u8, parent.?, search_dir)) {
                // Reached filesystem root, use input directory
                break :blk try allocator.dupe(u8, input_dir_absolute);
            }
            search_dir = parent.?;
        }
    };
    defer allocator.free(project_root);

    // Load project configuration from koru.json
    var project_config = try Config.load(allocator, project_root) orelse try Config.default(allocator);
    defer project_config.deinit();

    // Create module resolver for import resolution
    // Pass project_root for resolving alias paths and entry_dir for {{ ENTRY }} interpolation
    var resolver = try ModuleResolver.init(allocator, &project_config, project_root, input_dir_absolute, compiler_config.flags.items, null);
    defer resolver.deinit();

    // Inject compiler bootstrap import (unless --compiler=disable or user already imported it)
    // Note: compiler.kz itself has ~[comptime] annotation, so it will be emitted to backend_output
    const inject_compiler = !compiler_config.hasFlag("compiler=disable");
    // Detect the actual IMPORT statement — not any `std/compiler` occurrence.
    // `~std/compiler:requires { .. }` is a directive, not an import; matching bare
    // `std/compiler` there falsely skipped the bootstrap inject under the `/`
    // namespace (it didn't under the old `std.compiler` spelling).
    const user_already_imported_compiler =
        std.mem.indexOf(u8, source, "~import std/compiler") != null or
        std.mem.indexOf(u8, source, "import std/compiler") != null;
    const final_source = if (inject_compiler and !user_already_imported_compiler) blk: {
        log.debug("DEBUG: Auto-injecting compiler import\n", .{});
        // Pure `.k` synthesizes `~` on `import`; host-embedded `.k*` files need `~import`.
        const input_basename = std.fs.path.basename(input);
        const is_pure_k = if (file_types.koruExtensionOf(input_basename)) |ext|
            std.mem.eql(u8, ext, ".k")
        else
            false;
        const import_line = if (is_pure_k) "import std/compiler\n" else "~import std/compiler\n";
        const injected = try parse_allocator.alloc(u8, import_line.len + source.len);
        @memcpy(injected[0..import_line.len], import_line);
        @memcpy(injected[import_line.len..], source);
        break :blk injected;
    } else blk: {
        if (user_already_imported_compiler) {
            log.debug("DEBUG: User already imported compiler, skipping auto-injection\n", .{});
        }
        break :blk source;
    };

    // Parse the file
    log.debug("DEBUG: About to parse file: {s}, ast_json_mode = {}\n", .{ input, ast_json_mode });
    log.debug("DEBUG: Compiler bootstrap injection: {}\n", .{inject_compiler});
    var parser = try Parser.init(parse_allocator, final_source, input, compiler_config.flags.items, &resolver);
    parser.fail_fast = fail_fast;
    parser.report_gates = !show_help;
    defer parser.deinit();

    // If we prepended a bootstrap import line above, the parser sees line numbers
    // in INJECTED coordinates (line 1 = injected import). Tell the reporter to
    // render previews from the user's source and translate stored line numbers
    // back to user coordinates so error output references the user's file as
    // they wrote it.
    if (inject_compiler and !user_already_imported_compiler) {
        // import_line above is `~import std/compiler\n` — exactly one line.
        try parser.reporter.setUserSource(source, 1);
    }

    log.debug("DEBUG: Parser initialized, calling parse()...\n", .{});
    const parse_result = parser.parse() catch |err| {
        try exitOnReportedErrors(&parser.reporter);
        return err;
    };
    log.debug("DEBUG: Parse succeeded, ast_json_mode = {}\n", .{ast_json_mode});
    // DON'T defer deinit - we're going to take ownership of the items

    var source_file = parse_result.source_file;
    var user_registry = parse_result.registry;
    defer user_registry.deinit();

    // Fold in the entry's companion facets (same stem, sibling Koru files):
    // `koruc pump.kz` (or `koruc pump`) compiles the WHOLE `pump` module, not
    // just the one file. The contract (`.k`), the Zig impl (`.kz`), and the JS
    // impl (`.kjs`) merge into one AST so events, procs, and the flow resolve
    // against each other regardless of which facet declared them. Single-file
    // programs (no siblings) are untouched — the merge is a no-op. This is the
    // entry-side mirror of `loadFileWithCompanions` (used for imports).
    if (!ast_json_mode and !ast_canon_mode and !print_mode and !check_k_convertible_mode and !to_k_mode) {
        source_file = try import_pipeline.mergeEntryCompanions(allocator, parse_allocator, input, source_file, !show_help);
    }

    // If --ast-json mode, output AST as JSON (even if there are parse errors)
    // This is crucial for IDE tooling - parse_error nodes in AST show where errors occurred
    if (ast_json_mode) {
        log.debug("DEBUG: ast_json_mode is true, serializing AST...\n", .{});
        const ast_serializer = @import("ast_serializer");
        var serializer = try ast_serializer.AstSerializer.init(compile_allocator);
        defer serializer.deinit();
        // Parser-coordinate locations (flows, continuations, sources, taps,
        // error nodes — everything the parser stamped on the entry file) are
        // emitted as user coordinates; decl locations were already corrected
        // at getUserDeclStartLocation and module files were never injected.
        serializer.injection_line_count = parser.reporter.injection_line_count;
        serializer.entry_file = input;

        const json_output = try serializer.serializeToJson(&source_file);
        log.debug("DEBUG: JSON output length = {d}\n", .{json_output.len});
        // No need to free - compile_arena handles it

        try printStdout(allocator, "{s}", .{json_output});

        // Still report errors and exit with failure code if there were errors
        try exitOnReportedErrors(&parser.reporter);
        return;
    }

    // --ast-canon: the COMPLETE post-parse tree (generic reflective dump, every
    // field), with location/indent trivia stripped. This is the tree-equality
    // surface for the printer roundtrip harness: parse(original) and
    // parse(print(original)) must serialize byte-identically under this mode.
    // Both canon modes refuse broken trees: reporter errors OR embedded
    // parse_error items (lenient mode can embed a parse_error node — e.g.
    // from a failing imported module — while the reporter stays clean; a
    // canonical form of a broken program is meaningless either way).
    if (ast_canon_mode) {
        try exitOnUnparseable(&parser.reporter, &source_file);
        const ast_json = @import("ast_json");
        const json_output = try ast_json.serializeCanon(compile_allocator, &source_file);
        try printStdout(allocator, "{s}\n", .{json_output});
        return;
    }

    // --print: canonical Koru source from the post-parse tree.
    if (print_mode) {
        try exitOnUnparseable(&parser.reporter, &source_file);
        const ast_printer = @import("ast_printer");
        const printed = try ast_printer.printProgram(compile_allocator, &source_file);
        try printStdout(allocator, "{s}", .{printed});
        return;
    }

    // --check-k-convertible: could this `.kz` file be rewritten as a pure-Koru
    // `.k` file (no host bytes)? A `.k` file carries ZERO host content — the
    // parser's own classification is the authority, not a text heuristic. A file
    // is convertible iff its top-level AST holds no `host_line` (raw Zig passed
    // through), no `host_type_decl` (a host type defined outside a Koru
    // construct), and no `proc_decl` (a `~proc` is the host escape hatch — its
    // body is opaque host code; pure-Koru event impls are `immediate_impl`/`flow`,
    // never procs). Output is a stable first-token status for corpus tallying:
    //   CONVERTIBLE / NOT_CONVERTIBLE / UNPARSEABLE, then the path, then reasons.
    if (check_k_convertible_mode) {
        if (parser.reporter.hasErrors() or source_file.hasParseErrors()) {
            try printStdout(allocator, "UNPARSEABLE\t{s}\n", .{input});
            return;
        }
        var host_lines: usize = 0;
        var host_types: usize = 0;
        var procs: usize = 0;
        for (source_file.items) |item| {
            switch (item) {
                .host_line => |line| {
                    // Comments are NOT host content: in a `.kz` they forward to the
                    // host backend as `host_line`s, but a `.k` file's Koru parser
                    // handles `//` itself. A comment never blocks conversion.
                    const trimmed = std.mem.trim(u8, line.content, " \t\r\n");
                    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;
                    host_lines += 1;
                },
                .host_type_decl => host_types += 1,
                .proc_decl => procs += 1,
                else => {},
            }
        }
        if (host_lines == 0 and host_types == 0 and procs == 0) {
            try printStdout(allocator, "CONVERTIBLE\t{s}\n", .{input});
        } else {
            try printStdout(allocator, "NOT_CONVERTIBLE\t{s}\thost_line={d} host_type_decl={d} proc_decl={d}\n", .{ input, host_lines, host_types, procs });
        }
        return;
    }

    // `koruc <file.kz> to-k` — emit the `.k` facet of a pure-Koru `.kz`. The
    // oracle is the same item classification --check-k-convertible reports;
    // conversion is a mechanical strip of the line-start `~` markers (the
    // transform scripts/kz_convertible.sh compile-gates), then a re-parse of
    // the emitted text under the `.k` name — the tool writes only a file it
    // watched parse. `to-k --stdout` prints instead of writing.
    if (to_k_mode) {
        const in_base = std.fs.path.basename(input);
        const ext = file_types.koruExtensionOf(in_base) orelse "";
        if (!std.mem.eql(u8, ext, ".kz")) {
            try printStderr(allocator, "to-k: {s} is not a .kz file — nothing to convert\n", .{input});
            std.process.exit(1);
        }
        if (parser.reporter.hasErrors() or source_file.hasParseErrors()) {
            try printStderr(allocator, "to-k: {s} does not parse — fix the errors before converting\n", .{input});
            std.process.exit(1);
        }
        var host_lines: usize = 0;
        var host_types: usize = 0;
        var procs: usize = 0;
        for (source_file.items) |item| {
            switch (item) {
                .host_line => |line| {
                    // Comments are not host content — same carve-out as the
                    // convertible flag.
                    const trimmed = std.mem.trim(u8, line.content, " \t\r\n");
                    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) continue;
                    host_lines += 1;
                },
                .host_type_decl => host_types += 1,
                .proc_decl => procs += 1,
                else => {},
            }
        }
        if (host_lines + host_types + procs > 0) {
            try printStderr(allocator, "to-k: {s} earns the facet — host_line={d} host_type_decl={d} proc_decl={d}\n", .{ input, host_lines, host_types, procs });
            std.process.exit(1);
        }

        var stripped = std.ArrayList(u8){};
        defer stripped.deinit(allocator);
        var lit = std.mem.splitScalar(u8, source, '\n');
        var first_line = true;
        while (lit.next()) |line| {
            if (!first_line) try stripped.append(allocator, '\n');
            first_line = false;
            var start: usize = 0;
            while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
            if (start < line.len and line[start] == '~') {
                try stripped.appendSlice(allocator, line[0..start]);
                try stripped.appendSlice(allocator, line[start + 1 ..]);
            } else {
                try stripped.appendSlice(allocator, line);
            }
        }

        const out_path = try std.fmt.allocPrint(allocator, "{s}.k", .{input[0 .. input.len - ".kz".len]});
        defer allocator.free(out_path);

        // Re-parse the stripped text under the .k name (the parser keys facet
        // mode off the extension), with the same compiler import a real .k
        // compile synthesizes. A refusal here is a tool bug, not a file bug —
        // the AST already proved the content.
        const needs_import = std.mem.indexOf(u8, stripped.items, "import std/compiler") == null;
        const verify_source = if (needs_import)
            try std.fmt.allocPrint(parse_allocator, "import std/compiler\n{s}", .{stripped.items})
        else
            stripped.items;
        defer if (needs_import) parse_allocator.free(verify_source);
        var verify_resolver = try ModuleResolver.init(allocator, &project_config, project_root, input_dir_absolute, compiler_config.flags.items, null);
        defer verify_resolver.deinit();
        var verify_parser = try Parser.init(parse_allocator, verify_source, out_path, compiler_config.flags.items, &verify_resolver);
        verify_parser.fail_fast = true;
        defer verify_parser.deinit();
        const verify_result = verify_parser.parse() catch {
            try printStderr(allocator, "to-k: the stripped source failed to parse as .k — tool bug, not file bug; report it\n", .{});
            std.process.exit(1);
        };
        if (verify_parser.reporter.hasErrors() or verify_result.source_file.hasParseErrors()) {
            try printStderr(allocator, "to-k: the stripped source does not parse as .k — tool bug; `koruc {s} -c` names the refusal\n", .{out_path});
            std.process.exit(1);
        }

        var to_stdout = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--stdout")) to_stdout = true;
        }
        if (to_stdout) {
            try printStdout(allocator, "{s}", .{stripped.items});
            return;
        }
        if ((std.fs.cwd().statFile(out_path) catch null) != null) {
            try printStderr(allocator, "to-k: {s} already exists — refusing to overwrite\n", .{out_path});
            std.process.exit(1);
        }
        const out_file = try std.fs.cwd().createFile(out_path, .{});
        defer out_file.close();
        try out_file.writeAll(stripped.items);
        // Same-stem facets merge — leaving the .kz would double-declare the
        // module. The caller owns the rm; the tool only refuses to overwrite.
        try printStdout(allocator, "WROTE {s} — remove {s}; same-stem facets merge\n", .{ out_path, input });
        return;
    }

    // If --registry-json mode, output TypeRegistry as JSON
    if (registry_json_mode) {
        try printStdout(allocator, "{{\n", .{});
        try printStdout(allocator, "  \"events\": {{\n", .{});

        var event_iter = user_registry.events.iterator();
        var first_event = true;
        while (event_iter.next()) |entry| {
            if (!first_event) {
                try printStdout(allocator, ",\n", .{});
            }
            first_event = false;

            const event_path = entry.key_ptr.*;
            const event_type = entry.value_ptr.*;

            try printStdout(allocator, "    \"{s}\": {{\n", .{event_path});
            try printStdout(allocator, "      \"is_public\": {},\n", .{event_type.is_public});
            try printStdout(allocator, "      \"is_implicit_flow\": {},\n", .{event_type.is_implicit_flow});

            // Show input fields
            try printStdout(allocator, "      \"input_fields\": [\n", .{});
            if (event_type.input_shape) |shape| {
                for (shape.fields, 0..) |field, field_idx| {
                    if (field_idx > 0) try printStdout(allocator, ",\n", .{});
                    try printStdout(allocator, "        {{\"name\": \"{s}\", \"type\": \"{s}\", \"is_source\": {}}}", .{ field.name, field.type, field.is_source });
                }
            }
            try printStdout(allocator, "\n      ],\n", .{});

            // Show branches
            try printStdout(allocator, "      \"branches\": [\n", .{});
            for (event_type.branches, 0..) |branch, branch_idx| {
                if (branch_idx > 0) try printStdout(allocator, ",\n", .{});
                try printStdout(allocator, "        \"{s}\"", .{branch.name});
            }
            try printStdout(allocator, "\n      ]\n", .{});
            try printStdout(allocator, "    }}", .{});
        }

        try printStdout(allocator, "\n  }}\n", .{});
        try printStdout(allocator, "}}\n", .{});

        return;
    }

    // For non-JSON mode, fail immediately if there are parse errors
    // Defense-in-depth: check BOTH reporter errors AND parse_error AST nodes.
    // Lenient parser may create parse_error nodes without adding to reporter.
    try exitOnUnparseable(&parser.reporter, &source_file);

    // Check for frontend commands (shell and Zig) for instant execution
    const shell_commands = try collectShellCommands(parse_allocator, &source_file);
    defer {
        for (shell_commands) |*cmd| {
            cmd.deinit(parse_allocator);
        }
        parse_allocator.free(shell_commands);
    }

    const zig_commands = try collectZigCommands(parse_allocator, &source_file);
    defer {
        for (zig_commands) |*cmd| {
            cmd.deinit(parse_allocator);
        }
        parse_allocator.free(zig_commands);
    }

    const koru_commands = try collectKoruCommands(parse_allocator, &source_file);
    defer {
        for (koru_commands) |*cmd| {
            cmd.deinit(parse_allocator);
        }
        parse_allocator.free(koru_commands);
    }

    // Track if we're running a comptime command (passed to backend)
    // NOTE: comptime_cmd_result is collected AFTER imports are processed
    var detected_comptime_command: ?[]const u8 = null;
    var potential_command_arg: ?[]const u8 = null;
    var command_trailing_args: []const []const u8 = &.{};
    // `koruc <file> mint …` — a FRONTEND verb, never a comptime command. The
    // args after `mint` are the subcommand: `mint <name>` stores, `mint check
    // [name]` audits. Intercepted in the command scan below.
    var mint_args: ?[]const []const u8 = null;

    // Check if there's a potential command name in args
    // Args pattern: koruc input.kz <command> <...args for command>
    // Find input file position, then check next arg. Match against the RAW arg
    // the user typed (`input_file.?`), not the stem-resolved `input`: a bare
    // stem (`koruc pump build`) resolves `input` to `pump.kz`, which never
    // equals the `pump` sitting in argv — so the command would silently fall
    // through to a full build. The raw arg is the position the command follows.
    for (args, 0..) |arg, arg_idx| {
        if (std.mem.eql(u8, arg, input_file.?)) {
            // Check if there's a next arg that might be a command
            if (arg_idx + 1 < args.len) {
                const potential_command = args[arg_idx + 1];

                // `mint` is a frontend verb — it must never fall through to
                // the shell/zig/koru command matchers or the comptime-command
                // resolution below. Everything after it is subcommand args.
                if (std.mem.eql(u8, potential_command, "mint")) {
                    mint_args = args[@min(arg_idx + 2, args.len)..];
                    break;
                }

                // Handle "help" command - list all available commands
                if (std.mem.eql(u8, potential_command, "help")) {
                    if (shell_commands.len == 0 and zig_commands.len == 0 and koru_commands.len == 0) {
                        try printStdout(allocator, "No commands defined in {s}\n", .{input});
                        std.process.exit(0);
                    }

                    try printStdout(allocator, "\nAvailable commands:\n", .{});

                    // Calculate max command name length for alignment
                    var max_name_len: usize = 0;
                    for (shell_commands) |cmd| {
                        if (cmd.name.len > max_name_len) max_name_len = cmd.name.len;
                    }
                    for (zig_commands) |cmd| {
                        if (cmd.name.len > max_name_len) max_name_len = cmd.name.len;
                    }
                    for (koru_commands) |cmd| {
                        if (cmd.name.len > max_name_len) max_name_len = cmd.name.len;
                    }

                    // Print shell commands
                    for (shell_commands) |cmd| {
                        try printPaddedName(allocator, cmd.name, max_name_len);
                        if (cmd.description.len > 0) {
                            try printStdout(allocator, "{s}\n", .{cmd.description});
                        } else {
                            try printStdout(allocator, "(no description)\n", .{});
                        }
                    }

                    // Print zig commands
                    for (zig_commands) |cmd| {
                        try printPaddedName(allocator, cmd.name, max_name_len);
                        try printStdout(allocator, "(zig command)\n", .{});
                    }

                    // Print koru commands
                    for (koru_commands) |cmd| {
                        try printPaddedName(allocator, cmd.name, max_name_len);
                        if (cmd.description.len > 0) {
                            try printStdout(allocator, "{s}\n", .{cmd.description});
                        } else {
                            try printStdout(allocator, "(koru command)\n", .{});
                        }
                    }

                    try printStdout(allocator, "\nUsage: koruc {s} <command>\n", .{input});
                    std.process.exit(0);
                }

                // Search for matching shell command
                for (shell_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.name, potential_command)) {
                        // Found matching command! Execute it with remaining args
                        // Build argv: script + remaining args
                        var exec_argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len);
                        defer exec_argv.deinit(allocator);

                        try exec_argv.append(allocator, "sh");
                        try exec_argv.append(allocator, "-c");
                        try exec_argv.append(allocator, cmd.script);

                        // Pass additional args as positional parameters to the shell
                        // sh -c 'script' sh arg1 arg2 arg3...
                        if (arg_idx + 2 < args.len) {
                            try exec_argv.append(allocator, "sh"); // $0 for the script
                            for (args[arg_idx + 2 ..]) |extra_arg| {
                                try exec_argv.append(allocator, extra_arg);
                            }
                        }

                        // Execute command
                        const result = try std.process.Child.run(.{
                            .allocator = allocator,
                            .argv = exec_argv.items,
                        });
                        defer {
                            allocator.free(result.stdout);
                            allocator.free(result.stderr);
                        }

                        // Print output
                        try printStdout(allocator, "{s}", .{result.stdout});
                        if (result.stderr.len > 0) {
                            try printStderr(allocator, "{s}", .{result.stderr});
                        }

                        // Exit with command's exit code. A command that did not
                        // exit gets said out loud — a signal folded into a bare
                        // exit 1 hides that the machine (not the command) ended it.
                        try exitLikeCommand(allocator, cmd.name, result.term);
                    }
                }

                // If no shell command matched, check for Zig commands
                for (zig_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.name, potential_command)) {
                        // Found matching Zig command! Compile and execute it
                        log.debug("🔨 Executing Zig command: {s}\n", .{cmd.name});

                        // TODO: For MVP, we'll implement a simple approach:
                        // 1. Generate temp .zig file with command source
                        // 2. Serialize AST to temp file
                        // 3. Use zig run to compile and execute
                        // 4. Pass AST path + argv via command line

                        // For now, just print that we found it
                        log.debug("⚠️  Zig command execution not yet implemented\n", .{});
                        log.debug("Command '{s}' found but needs compilation support\n", .{cmd.name});
                        std.process.exit(1);
                    }
                }

                // If no zig command matched, check for Koru commands
                for (koru_commands) |cmd| {
                    if (std.mem.eql(u8, cmd.name, potential_command)) {
                        // Found matching Koru command! Emit and execute it
                        log.debug("🌿 Executing Koru command: {s}\n", .{cmd.name});

                        // Find the execute continuation
                        var execute_cont: ?*const ast.Continuation = null;
                        for (cmd.flow.body.continuations) |*cont| {
                            if (std.mem.eql(u8, cont.branch, "execute")) {
                                execute_cont = cont;
                                break;
                            }
                        }

                        if (execute_cont == null) {
                            log.debug("Error: No 'execute' branch found in command\n", .{});
                            std.process.exit(1);
                        }

                        // For MVP: emit a simple Zig file with the command body
                        // The continuation.node contains the flow body
                        const tmp_path = "/tmp/koru_cmd.zig";

                        // Create the Zig source
                        var zig_source = try std.ArrayList(u8).initCapacity(allocator, 1024);
                        defer zig_source.deinit(allocator);

                        // Write header
                        try zig_source.appendSlice(allocator, "const std = @import(\"std\");\n\n");
                        try zig_source.appendSlice(allocator, "pub fn main() void {\n");

                        // Emit the continuation body
                        const cont = execute_cont.?;
                        if (cont.node) |node| {
                            try emitNodeAsZig(allocator, &zig_source, node, "    ");
                        } else {
                            // Empty body - just emit a comment
                            try zig_source.appendSlice(allocator, "    // (empty command body)\n");
                        }

                        try zig_source.appendSlice(allocator, "}\n");

                        // Write to temp file
                        const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch |err| {
                            log.debug("Error creating temp file: {}\n", .{err});
                            std.process.exit(1);
                        };
                        defer tmp_file.close();
                        tmp_file.writeAll(zig_source.items) catch |err| {
                            log.debug("Error writing temp file: {}\n", .{err});
                            std.process.exit(1);
                        };

                        // Execute with zig run
                        var exec_argv = [_][]const u8{ emitter_helpers.zigExe(), "run", tmp_path };
                        const result = std.process.Child.run(.{
                            .allocator = allocator,
                            .argv = &exec_argv,
                        }) catch |err| {
                            log.debug("Error running command: {}\n", .{err});
                            std.process.exit(1);
                        };
                        defer {
                            allocator.free(result.stdout);
                            allocator.free(result.stderr);
                        }

                        // Print output
                        if (result.stdout.len > 0) {
                            try printStdout(allocator, "{s}", .{result.stdout});
                        }
                        if (result.stderr.len > 0) {
                            try printStderr(allocator, "{s}", .{result.stderr});
                        }

                        // Exit with command's exit code. Same contract as the
                        // shell-command path above: a non-exit termination is
                        // reported, never folded into a silent exit 1.
                        try exitLikeCommand(allocator, cmd.name, result.term);
                    }
                }

                // Store potential command for later checking (after imports are processed)
                // Comptime commands are defined in imported modules, so we check after imports
                potential_command_arg = potential_command;
                // Capture any trailing args after the command (subcommands/flags like "install", "--pm")
                if (arg_idx + 2 < args.len) {
                    command_trailing_args = args[arg_idx + 2 ..];
                }
            }
            break;
        }
    }

    // Process imports - extract public events from imported modules
    const combine_result = try import_pipeline.combineImports(
        allocator,
        parse_allocator,
        &resolver,
        &source_file,
        input,
        entry_file_absolute,
        !show_help,
    );
    defer {
        for (combine_result.imported_paths) |p| allocator.free(p);
        allocator.free(combine_result.imported_paths);
    }

    // `.kmd`: the document is the compile-time residue of an implicit-
    // comptime module (docs/KMD.md). No backend, no binary — walk items in
    // file order; md hostlines render through Liquid against ~const
    // bindings hoisted from the entry AND its imported data modules;
    // anything the comptime stage can't consume is a compile failure,
    // not silent output. Runs AFTER combineImports so `~import` lands.
    if (file_types.koruExtensionOf(std.fs.path.basename(input_file.?))) |input_ext| {
        if (std.mem.eql(u8, input_ext, ".kmd") and !ast_json_mode and !ast_canon_mode) {
            try emitKmdDocument(compile_allocator, &source_file, input_file.?, &parser.reporter);
            try exitOnReportedErrors(&parser.reporter);
            return;
        }
    }

    // --list-imports: emit transitive resolved canonical paths as a JSON array, then exit.
    if (list_imports_mode) {
        try printStdout(allocator, "[", .{});
        var first_import = true;
        for (combine_result.imported_paths) |path| {
            if (!first_import) try printStdout(allocator, ",", .{});
            first_import = false;
            try printStdout(allocator, "\"{s}\"", .{path});
        }
        try printStdout(allocator, "]\n", .{});
        return;
    }

    log.debug("AST combined with {} imported modules\n", .{combine_result.imported_module_count});

    // Handle --help with full AST (discovers all flags and commands from imports)
    if (show_help) {
        try printDynamicHelp(allocator, &source_file);
        return;
    }

    // `glance` — a frontend AST-introspection mode. The imports are fully
    // resolved (conditional gate already ran in the parser), so source_file holds
    // exactly the active module surface. Walk it, print, and return — no backend.
    if (command_candidate) |cmd| {
        if (std.mem.eql(u8, cmd, "glance")) {
            var glance_app_only = false;
            for (args) |a| {
                if (std.mem.eql(u8, a, "--app")) glance_app_only = true;
            }
            runGlance(&source_file, glance_app_only);
            return;
        }
        if (std.mem.eql(u8, cmd, "at")) {
            // The hash is the non-flag arg that follows `at` on the command line.
            var query: ?[]const u8 = null;
            var seen_cmd = false;
            for (args) |a| {
                if (std.mem.eql(u8, a, cmd)) {
                    seen_cmd = true;
                    continue;
                }
                if (seen_cmd and !std.mem.startsWith(u8, a, "-")) {
                    query = a;
                    break;
                }
            }
            if (query) |q| {
                runAt(&source_file, q, input, parser.reporter.injection_line_count);
            } else {
                std.debug.print("usage: koruc <file> at <site-hash>\n", .{});
            }
            return;
        }
    }

    // Now check for comptime commands (after imports are processed)
    if (potential_command_arg) |potential_command| {
        const comptime_cmd_result = try collectCommands(parse_allocator, &source_file);

        // Resolve command aliases (e.g., "i" -> "install")
        // TODO: Parse these from command.declare dynamically
        const resolved_command = if (std.mem.eql(u8, potential_command, "i"))
            "install"
        else
            potential_command;

        for (comptime_cmd_result.commands[0..comptime_cmd_result.count]) |cmd| {
            if (std.mem.eql(u8, cmd.name, resolved_command)) {
                // Found matching comptime command - continue to backend compilation
                // The command will be passed to the backend and executed there
                detected_comptime_command = resolved_command;
                break;
            }
        }

        // `koruc <file> --flag <command>` puts a flag in the command slot,
        // leaving the real command stranded in the tail — which today
        // silently does a normal build and never runs it. When the
        // positional candidate was a flag and a later arg names a declared
        // command — comptime, shell, zig, koru.json, or a frontend verb —
        // refuse and name the correct order.
        if (detected_comptime_command == null and
            std.mem.startsWith(u8, potential_command, "-"))
        {
            const misplaced: ?[]const u8 = blk: {
                for (command_trailing_args) |tail| {
                    if (std.mem.startsWith(u8, tail, "-")) continue;
                    for (comptime_cmd_result.commands[0..comptime_cmd_result.count]) |cmd| {
                        if (std.mem.eql(u8, cmd.name, tail)) break :blk tail;
                    }
                    for (shell_commands) |cmd| {
                        if (std.mem.eql(u8, cmd.name, tail)) break :blk tail;
                    }
                    for (zig_commands) |cmd| {
                        if (std.mem.eql(u8, cmd.name, tail)) break :blk tail;
                    }
                    for (koru_commands) |cmd| {
                        if (std.mem.eql(u8, cmd.name, tail)) break :blk tail;
                    }
                    inline for (.{ "mint", "help", "glance", "at" }) |verb| {
                        if (std.mem.eql(u8, verb, tail)) break :blk tail;
                    }
                }
                break :blk null;
            };
            if (misplaced) |tail| {
                try printStderr(allocator, "koruc: '{s}' is a command — command position is immediately after the input file, not after flags\n  hint: koruc {s} {s} … {s}\n", .{ tail, input_file.?, tail, potential_command });
                std.process.exit(1);
            }
        }

        // Nothing claimed the word in command position. Shell, zig, and koru
        // commands execute in the scan above and never reach here; comptime
        // commands resolved just now; the frontend verbs (mint, help, glance,
        // at, to-k) all returned earlier. What remains is dead input — a word
        // no consumer reads (trailing args are never forwarded to the program).
        // `run`/`build`/`lib`/`bundle` landing here is the leading verb typed
        // in the trailing position: the file builds and the verb is swallowed
        // (Q3 in challenges/018_FIX_QUEUE.md). A flag in this slot is the
        // misplaced-flag case above, so skip anything that starts with '-'.
        // `ci` is shared vocabulary, not dead input: it falls through to a
        // plain build, and the step-graph driver below reads the absent
        // command to run every declared std/build:step (drives_step_graph).
        if (detected_comptime_command == null and
            !std.mem.startsWith(u8, potential_command, "-") and
            !std.mem.eql(u8, potential_command, "ci"))
        {
            inline for (.{ "run", "build", "lib", "bundle", "init", "create", "skills", "zen" }) |verb| {
                if (std.mem.eql(u8, potential_command, verb)) {
                    try printStderr(allocator, "koruc: '{s}' is a leading verb, not a command — verb first, file second\n\n      koruc {s} {s}\n\n  The word after the input file names a command the program declares (`koruc {s} help` lists them).\n", .{ verb, verb, input_file.?, input_file.? });
                    std.process.exit(1);
                }
            }
            try printStderr(allocator, "koruc: '{s}' is not a command {s} declares\n\n  The word after the input file names a command the program declares — `koruc {s} help` lists them.\n  To build and run the program: `koruc run {s}`.\n", .{ potential_command, input, input_file.?, input_file.? });
            std.process.exit(1);
        }
    }

    // compiler:use — the mint directive. Frontend-collected textually like
    // compiler:requires; it never reaches a backend's dispatch table.
    var use_directive: ?CompilerUse = null;
    try collectCompilerUse(allocator, source_file.items, &use_directive);
    if (use_directive != null) {
        source_file.items = try stripCompilerUseFlows(parse_allocator, source_file.items);
    }

    // `koruc <file> mint …` subcommand resolution. `mint <name>` stores the
    // backend once built; `mint check [name]` audits against the live tree
    // (falling back to the program's use directive for the name). Under mint
    // the use directive is INERT — minting always builds the current backend.
    var mint_create: ?[]const u8 = null;
    var mint_check_name: ?[]const u8 = null;
    if (mint_args) |margs| {
        if (margs.len == 0) {
            try printStderr(allocator, "error: mint needs a name or 'check'\n\n      koruc {s} mint <name>       — store this program's backend as a named mint\n      koruc {s} mint check [name] — audit a mint against the live tree\n", .{ input, input });
            std.process.exit(1);
        }
        if (std.mem.eql(u8, margs[0], "check")) {
            mint_check_name = if (margs.len > 1) margs[1] else if (use_directive) |ud| ud.name else null;
            if (mint_check_name == null) {
                try printStderr(allocator, "error: mint check needs a mint name\n\n      koruc {s} mint check <name>\n  (or a compiler:use(\"name\") directive in the program)\n", .{input});
                std.process.exit(1);
            }
        } else {
            mint_create = margs[0];
        }
    }
    // A mint pin is honored only on a normal compile — `mint` itself always
    // builds fresh, and check-only never reaches the backend at all.
    const minted_use = use_directive != null and mint_create == null and !check_only;

    // Canonicalize all DottedPaths - set module_qualifier on everything
    // This enables reliable name resolution for all downstream passes
    const canonicalize_names = @import("canonicalize_names");
    try canonicalize_names.canonicalize(&source_file, parse_allocator, &resolver);

    // Host-type scope: a bare host (Zig) type is legal only inside the module
    // that declares it; across a module boundary the signature spells it fully
    // qualified — `*mod:Type` (220_031, ruled 2026-09-06). Runs right after
    // canonicalization, before any transform, so a refused program dies at the
    // frontend with the teaching diagnostic and never reaches emission.
    const host_type_scope_checker = @import("host_type_scope_checker");
    try host_type_scope_checker.check(parse_allocator, source_file.items, &parser.reporter);
    try exitOnReportedErrors(&parser.reporter);

    // Build keyword registry and resolve [keyword] events
    // This enables unqualified invocation of events marked with [keyword]
    // Must happen AFTER canonicalization so we have canonical paths for registration
    log.debug("Building keyword registry...\n", .{});
    var kw_registry = keyword_registry.KeywordRegistry.init(parse_allocator);
    defer kw_registry.deinit();
    try keyword_registry.buildFromItems(source_file.items, &kw_registry, parse_allocator);
    if (kw_registry.count() > 0) {
        log.debug("Registered {} keywords, resolving in AST...\n", .{kw_registry.count()});
        try keyword_registry.resolveInAST(@constCast(source_file.items), &kw_registry, parse_allocator, source_file.main_module_name);
    }

    // Inject meta-events (koru:start, koru:end) into AST
    // These are synthetic events that mark program lifecycle boundaries
    // Taps can observe them (e.g., profiler writes header/footer)
    // Must happen AFTER canonicalization so paths have module_qualifier
    // Must happen BEFORE tap transformation so taps can observe these flows
    const meta_events = @import("meta_events");
    try meta_events.injectMetaEvents(parse_allocator, &source_file);
    log.debug("Injected meta-events: koru:start, koru:end\n", .{});

    // Phase 3 KORU111: enforce contract/implementation file split.
    // Must run BEFORE enforceInvocationVisibility — the structural rule
    // (private event in .k file is malformed) should fire before the
    // downstream visibility consequence (call site can't reach private event).
    // Otherwise users see KORU044 "private event cannot be accessed" when
    // the real diagnostic is "you shouldn't have declared this event
    // private inside a .k contract file in the first place."
    const validate_contract_impl = @import("validate_contract_impl");
    try validate_contract_impl.validate(source_file.items, &parser.reporter);
    try exitOnReportedErrors(&parser.reporter);

    // Populate invocation.source_module for visibility enforcement
    try populateInvocationSourceModules(@constCast(source_file.items), parse_allocator, source_file.main_module_name);
    try enforceInvocationVisibility(source_file.items, &parser.reporter, parse_allocator, source_file.main_module_name);
    try enforceUniqueBindingNames(source_file.items, &parser.reporter, parse_allocator);
    try exitOnReportedErrors(&parser.reporter);

    // NOTE: Declaration-level transforms run in the BACKEND alongside invocation transforms.
    // They update the type registry when they run, not here in the frontend.

    // Build TypeRegistry from canonicalized AST
    // This must happen AFTER canonicalization so event names include module qualifiers
    log.debug("Building TypeRegistry from canonicalized AST...\n", .{});
    try user_registry.populateFromAST(source_file.items);
    log.debug("TypeRegistry populated with {} events\n", .{user_registry.events.count()});

    // Attach TypeRegistry to Program for transform access
    // Transforms can clone this for supplemental parsing
    source_file.type_registry = &user_registry;

    // Validate abstract events and implementations
    // This must happen AFTER canonicalization so we can match canonical paths
    log.debug("Validating abstract events and implementations...\n", .{});
    validate_abstract_impl.AbstractImplValidator.validate(parse_allocator, &parser.reporter, source_file.items) catch |err| {
        // Same gate the flow checker gets below: the pass raises a koru
        // diagnostic (KORU113/KORU114) and fails; the failure VALUE is only the
        // stop signal. Presenting the reporter here is what keeps a bare
        // `error: ImplTargetNotAbstract` plus a koruc stack trace off the
        // user's screen. Only a genuine ICE — a failure with nothing said —
        // propagates raw.
        try exitOnReportedErrors(&parser.reporter);
        return err;
    };
    log.debug("Abstract/impl validation passed\n", .{});

    // Resolve abstract/impl: rename defaults to .default when overrides exist
    const resolve_abstract_impl = @import("resolve_abstract_impl");
    try resolve_abstract_impl.resolve(&source_file, parse_allocator);
    try resolve_abstract_impl.createDefaultEventDecls(&source_file, parse_allocator);
    log.debug("Abstract/impl resolution complete\n", .{});

    // Collect Event Taps
    var tap_collector = try TapCollector.init(compile_allocator);
    defer tap_collector.deinit();
    try tap_collector.collectFromSourceFile(&source_file);

    const tap_count = tap_collector.output_taps.count() +
        tap_collector.input_taps.count() +
        tap_collector.universal_output_taps.items.len +
        tap_collector.universal_input_taps.items.len;
    if (tap_count > 0) {
        log.debug("Collected {} Event Taps\n", .{tap_count});
    }

    // NOTE: Tap transformation is done in the BACKEND by compiler.coordinate.transform_taps
    // The backend inserts taps into the AST after filtering comptime code.

    // TODO: Process imports properly - for now imports are disabled
    // The old import system violated module isolation by copying all code
    // try processImports(allocator, &source_file, input);

    // NOTE: Compiler override detection removed - the abstract/impl mechanism in
    // koru_std/compiler.kz handles this automatically via abstract events and cross-module overrides

    // Point-free pipeline + choke desugar: rewrite parsed point-free `|>`
    // chains (unnamed continuations + a dedented choke) into the canonical
    // explicit-continuation pyramid BEFORE any checker or the AST
    // serialization sees the tree — downstream stays frozen. Runs after
    // canonicalization so declaration lookup is qualifier-symmetric.
    const ast_transform = @import("ast_transform");
    try ast_transform.desugarPointfreeChains(parse_allocator, &source_file, &parser.reporter);

    // Inline scalar-bind pun: fill an invocation's unfilled input field from a
    // same-named in-scope `: bind` (subtree-scoped, unique by no-shadowing),
    // synthesizing the explicit arg BEFORE any checker sees the tree — so the
    // structure and phantom-semantic passes validate a punned arg exactly like
    // a hand-written one. Runs after the point-free rewrite so the canonical
    // pyramid's own explicit args are already in place.
    try ast_transform.desugarBindingPuns(parse_allocator, &source_file, &parser.reporter);

    // Flow return terminus: a `-> T` flow whose chain ends on a step returning
    // T gets that step's value as its output, with no `: v -> v` written — the
    // bare-return twin of the branch terminus the point-free desugar already
    // synthesizes. Runs after the thread pass so every step's args are in place
    // and the last step is final.
    try ast_transform.desugarFlowReturnTerminus(parse_allocator, &source_file, &parser.reporter);

    // Same-base-type continuation: a tor that consumes `*T<!s>` and re-mints
    // `*T<s'!>` advances the consumed binding in place, so a later reference to
    // the old name means the re-minted value. Rewrites into the explicit-bind
    // form the emitter already lowers. Runs BEFORE the chain-pun thread so this
    // pass — the recursive, consume-keyed one — owns every consume-continuation,
    // including the ones that escape into branches (which the pun thread's
    // linear walk cannot reach). Fires only where a spent binding is referenced
    // again (today always KORU030), so green programs are untouched.
    try ast_transform.desugarHandleContinuation(parse_allocator, &source_file, &parser.reporter);

    // Chain threading by pun (210_172): a chain step that puns the head's own
    // `: bind` name reads the RUNNING value, not the head's literal — the
    // batch as it moves down the chain. Desugars to the explicit mid-chain
    // binds the emitter already lowers (minted `__thread_pun{N}` holders, args
    // and interpolations pointed at the previous holder). Runs after the
    // continuation pass, so a consumed binding has already continued and only
    // genuine non-consume running values (210_172's `seed(): n |> bump(n)`) are
    // left to thread. Also after the pun (args materialized) and the terminus
    // (a `-> T` flow's last step is final).
    try ast_transform.desugarChainPunThreading(parse_allocator, &source_file, &parser.reporter);

    // RULING 3: a bare pun of a formatted-result struct into a scalar param
    // (KORU038) is reported here, at the koru level, before it can reach the
    // emitter and leak a raw Zig type error. KORU092/093 (the thread) and
    // KORU094 (the terminus) surface at the same gate.
    try exitOnReportedErrors(&parser.reporter);

    // Purity checking pass
    var purity_check = PurityChecker.init(compile_allocator);
    defer purity_check.deinit();
    try purity_check.check(&source_file);

    // Invariant hoist: a loop-invariant pure prefix of `for ! each` lifts
    // out of the loop; discharges land on `| done`. Runs after purity
    // marking, before the threaded flood sees the rewritten flow.
    try ast_transform.hoistInvariantLoopPrefix(parse_allocator, &source_file, &parser.reporter);

    // Threaded-reachability pass — floods "dirty" forward from ~[threaded]
    // roots; consumed at codegen for lockset emission.
    var threaded_check = threaded_checker.ThreadedChecker.init(compile_allocator);
    defer threaded_check.deinit();
    try threaded_check.check(&source_file);

    // Flow checking pass - FRONTEND ONLY (syntactic checks: KORU100, KORU050, KORU051)
    // Unknown-branch (KORU021) runs here — source arm names only exist
    // pre-transform; missing-branch (KORU022) stays post-transform
    var flow_check = try FlowChecker.initWithMode(compile_allocator, &parser.reporter, .frontend);
    defer flow_check.deinit();
    flow_check.checkSourceFile(&source_file) catch |err| {
        // Any checker failure with diagnostics pending must present them as
        // koru diagnostics — a raw Zig error must never reach the user when a
        // real diagnostic exists (only genuine ICEs propagate raw).
        try exitOnReportedErrors(&parser.reporter);
        return err;
    };

    // `--lang` must name an emitter or a variant the program actually
    // declares — anything else used to emit a Zig binary under the
    // foreign tag with no diagnostic. Runs before check_only so `-c`
    // refuses the same lies as a full build.
    try enforceLangNamespace(compile_allocator, &source_file, compiler_config.lang);

    // A qualified call into a module that declares nothing in this program
    // must refuse — unimported `std/io:print.ln` otherwise reaches emission
    // as a mangled handler with unbound args (KORU211). Runs last among the
    // checks: the more specific diagnostics (qualifier spelling, obligation
    // moves, shape) must get their word in first.
    const ast_transform_refuse = @import("ast_transform");
    try ast_transform_refuse.refuseUnresolvableQualifiedCalls(parse_allocator, &source_file, &parser.reporter);
    try exitOnReportedErrors(&parser.reporter);

    // If check-only, we're done
    if (check_only) {
        try printStdout(allocator, "✓ Shape checking passed\n", .{});
        return;
    }

    // NOTE: All compilation passes now run in the backend via koru_std/compiler.kz
    // The frontend just parses and validates, then hands off to the backend pipeline.
    const final_ast: *ast.Program = &source_file;

    // Write output file
    const output = output_file.?;
    log.debug("DEBUG: Writing output to {s}\n", .{output});

    // Pass 2: Generate the backend (code generator + compiler)
    // Serialize the program AST to JSON. The backend reads this file at runtime
    // (program.ast.json) and deserializes it onto the heap — the AST is a runtime
    // input now, not baked into the backend binary. See generateBackendCode().
    const ast_json = @import("ast_json");
    const serialized_ast = try ast_json.serialize(compile_allocator, final_ast);
    // No need to free - compile_arena handles it

    // Generate backend_output_emitted.zig for comptime handlers FIRST
    // We need transform_count from this to pass to backend.zig generation
    // CRITICAL: Use source_file (original AST) not final_ast (transformed AST)
    // The comptime evaluation pass filters out ~[comptime] modules from final_ast,
    // but we NEED those modules in backend_output_emitted.zig for backend compilation!
    log.debug("DEBUG: Generating comptime backend with {} items in source_file\n", .{source_file.items.len});
    for (source_file.items) |item| {
        if (item == .module_decl) {
            const module = item.module_decl;
            log.debug("DEBUG:   Module: {s} (has_comptime: {any})\n", .{ module.logical_name, module.annotations });
        }
    }
    const comptime_result = try generateComptimeBackendEmitted(compile_allocator, &source_file, &user_registry);
    const comptime_backend_code = comptime_result.code;
    const has_transforms = comptime_result.transform_count > 0;
    // No defer needed - compile_arena handles cleanup automatically

    // compiler:use — the minted backend already exists; emitting backend.zig
    // would produce a file nothing builds. The emitted code above still ran:
    // its hash is the coverage check against the mint manifest.
    if (!minted_use) {
        // Generate the backend code (now a thin driver; PROGRAM_AST lives in program_ast.zig
        // for Zig's content-addressed cache to hit across user programs)
        const backend_code = try generateBackendCode(compile_allocator, input, final_ast, use_visitor, &compiler_config, has_transforms);
        // No defer needed - compile_arena handles cleanup automatically

        // Write the backend to the output file
        const out_file = try std.fs.cwd().createFile(output, .{});
        defer out_file.close();

        try out_file.writeAll(backend_code);
    }

    const output_dir = std.fs.path.dirname(output) orelse ".";

    // Write program.ast.json: the per-user AST as a data artifact the backend
    // reads at runtime. Replaces program_ast.zig — the AST is no longer compiled
    // into the backend binary, so the backend is reusable across programs that
    // share a handler set (the caching layer this unlocks).
    const program_ast_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "program.ast.json" });
    defer allocator.free(program_ast_path);
    const program_ast_file = try std.fs.cwd().createFile(program_ast_path, .{});
    defer program_ast_file.close();
    try program_ast_file.writeAll(serialized_ast);

    // Write compiler_env.json: per-invocation compiler environment (lang,
    // library, flags, env vars, paths). Runtime data the backend loads at
    // startup — never baked into the binary, so flag flips reuse the cached
    // backend instead of rebuilding it.
    const compiler_env_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "compiler_env.json" });
    defer allocator.free(compiler_env_path);
    const compiler_env_json = try generateCompilerEnvJson(compile_allocator, &compiler_config, entry_file_absolute, input_dir_absolute, project_root, resolver.koru_home);
    const compiler_env_file = try std.fs.cwd().createFile(compiler_env_path, .{});
    defer compiler_env_file.close();
    try compiler_env_file.writeAll(compiler_env_json);

    // Write backend_output_emitted.zig for comptime handlers to same directory as backend.zig.
    // Under compiler:use nothing builds it — its hash already served as the
    // mint coverage check; writing it would just litter a stale build input.
    if (!minted_use) {
        const backend_output_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "backend_output_emitted.zig" });
        defer allocator.free(backend_output_path);
        const backend_output_file = try std.fs.cwd().createFile(backend_output_path, .{});
        defer backend_output_file.close();
        try backend_output_file.writeAll(comptime_backend_code);
        try printStdout(allocator, "✓ Compiled {s} → {s}\n", .{ input, output });
        try printStdout(allocator, "✓ Generated {s} ({d} bytes)\n", .{ backend_output_path, comptime_backend_code.len });
    } else {
        try printStdout(allocator, "✓ Compiled {s} → minted backend '{s}'\n", .{ input, use_directive.?.name });
    }

    // Collect requirements from AST
    // - compiler:requires → for BACKEND compilation (backend.zig)
    // - build:requires → for OUTPUT binary (output_emitted.zig)
    var requires_collector = try CompilerRequiresCollector.init(allocator);
    defer requires_collector.deinit();
    try requires_collector.collectFromSourceFile(&source_file);

    const compiler_requirements_raw = requires_collector.getCompilerRequirements();
    const build_requirements_raw = requires_collector.getBuildRequirements();
    const app_decl = requires_collector.getAppDecl();

    // `koru bundle` has no identity fallback: the .app is the declaration made
    // filesystem-real, so a missing std/build:app refuses rather than minting
    // placeholder metadata.
    if (bundle_after_build) {
        if (@import("builtin").os.tag != .macos) {
            try printStderr(allocator, "error: koru bundle produces a macOS .app — this host cannot make one\n", .{});
            return;
        }
        if (app_decl == null) {
            try printStderr(allocator, "error: koru bundle needs an app identity — declare `std/build:app {{ name: \"…\", id: \"com.you.app\" }}` at top level\n", .{});
            return;
        }
        if (exe_output_name) |p| {
            if (!std.mem.endsWith(u8, p, ".app")) {
                try printStderr(allocator, "error: bundle output must end in .app (got '{s}')\n", .{p});
                return;
            }
        }
    }

    // Use koru_home from resolver (computed from executable path)
    const koru_lib_path = resolver.koru_home;

    // Generate build.zig for BACKEND (compiler:requires).
    // Under compiler:use no backend is built here — the mint already is one.
    if (!minted_use and compiler_requirements_raw.len > 0) {
        try printStdout(allocator, "✓ Found {d} compiler requirement(s) for backend\n", .{compiler_requirements_raw.len});

        var backend_build_reqs = try std.ArrayList(emit_build_zig.BuildRequirement).initCapacity(allocator, compiler_requirements_raw.len);
        defer backend_build_reqs.deinit(allocator);

        for (compiler_requirements_raw) |req| {
            try backend_build_reqs.append(allocator, .{
                .module_name = "compiler",
                .source_code = req,
            });
        }

        // A `sqlite` arm on the diagnostic bus implies the backend's link dep:
        // the arm is the intent, so synthesize the requirement when the module
        // that spelled the arm didn't already declare it (e.g. a hand-written
        // join with no `import std/diag/sqlite`).
        if (programWantsDiagSink(&source_file, "sqlite")) {
            var declares_sqlite = false;
            for (compiler_requirements_raw) |req| {
                if (std.mem.indexOf(u8, req, "sqlite3") != null) declares_sqlite = true;
            }
            if (!declares_sqlite) {
                try backend_build_reqs.append(allocator, .{
                    .module_name = "std/diag/sqlite",
                    .source_code = "            exe.linkLibC();\n            exe.linkSystemLibrary(\"sqlite3\");\n",
                });
            }
        }

        const build_backend_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build_backend.zig" });
        defer allocator.free(build_backend_path);
        try emit_build_zig.emitBuildZig(allocator, backend_build_reqs.items, build_backend_path, koru_lib_path);
        try printStdout(allocator, "✓ Generated {s}\n", .{build_backend_path});

        // Also as build.zig for zig build convenience
        const build_user_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build.zig" });
        defer allocator.free(build_user_path);
        emit_build_zig.emitBuildZig(allocator, backend_build_reqs.items, build_user_path, koru_lib_path) catch |err| switch (err) {
            error.RefuseOverwriteBuildZig => {
                try printStderr(allocator, "error: refusing to overwrite {s}\n\n" ++
                    "  koruc emits build.zig beside the input file. This path already holds a\n" ++
                    "  Zig build script for something else (the compiler itself, or another project).\n" ++
                    "  Compile from a subdirectory instead — see examples/greet/hello.k.\n", .{build_user_path});
                std.process.exit(1);
            },
            else => return err,
        };
        try printStdout(allocator, "✓ Generated {s} (for backend compilation)\n", .{build_user_path});
    }

    // Synthesize build requirements for |mlir variants. Each MLIR proc body is
    // compiled AOT (mlir-opt -> mlir-translate -> clang -c) to an object and
    // linked into the output binary via exe.addObjectFile. These are NOT user
    // ~build:requires — the compiler synthesizes them into the SAME pipeline the
    // moment it sees a |mlir proc (hooking the pipeline, not the user surface).
    // PoC: MLIR toolchain path hardcoded to the Homebrew LLVM 19 prefix; future
    // work resolves the tool through the deps/requires family.
    var mlir_build_reqs = try std.ArrayList(emit_build_zig.BuildRequirement).initCapacity(allocator, 0);
    defer {
        for (mlir_build_reqs.items) |r| allocator.free(r.source_code);
        mlir_build_reqs.deinit(allocator);
    }
    {
        // The link step is a build-TIME glob over `*.mlir` in the build root:
        // whoever writes a .mlir file gets lowered + linked. Stage A writes one
        // per user `|mlir` proc (below); Stage-C transforms (e.g. kernel:self|mlir)
        // write theirs while the backend runs — before Stage D's `zig build`
        // reads build_output.zig — so generated kernels ride the same seam with
        // no symbol coordination across stages.
        const mlir_glob_req =
            \\            var __mlir_dir = b.build_root.handle.openDir(".", .{ .iterate = true }) catch @panic("mlir: cannot open build root");
            \\            defer __mlir_dir.close();
            \\            var __mlir_it = __mlir_dir.iterate();
            \\            while (__mlir_it.next() catch @panic("mlir: build-root iteration failed")) |__mlir_entry| {
            \\                if (__mlir_entry.kind != .file) continue;
            \\                if (!std.mem.endsWith(u8, __mlir_entry.name, ".mlir")) continue;
            \\                if (std.mem.endsWith(u8, __mlir_entry.name, ".gpu.mlir")) {
            \\                    // GPU lowering: gpu.module -> SPIR-V dialect -> serialized
            \\                    // blob, gated by spirv-val — an invalid blob fails the
            \\                    // build loudly instead of shipping. The output binary
            \\                    // @imports koru_gpu_dispatch.zig (@cImport vulkan) and
            \\                    // dispatches the blob on the local device, so the exe
            \\                    // links libvulkan/libc here (PoC hardcoded prefixes, same
            \\                    // family as the LLVM path; rpath so the loader finds
            \\                    // @rpath/libvulkan at runtime).
            \\                    const __gpu_name = b.dupe(__mlir_entry.name);
            \\                    const __gpu_step = b.addSystemCommand(&.{ "sh", "-c",
            \\                        "/opt/homebrew/opt/llvm/bin/mlir-opt --pass-pipeline='builtin.module(convert-gpu-to-spirv, spirv.module(spirv-lower-abi-attrs, spirv-update-vce))' \"$1\" | awk '/^  spirv.module/{f=1} f{print substr($0,3)} f && /^  \\}$/{exit}' | /opt/homebrew/opt/llvm/bin/mlir-translate --no-implicit-module --serialize-spirv -o \"$2\" && /usr/local/bin/spirv-val \"$2\"",
            \\                        "koru-spv" });
            \\                    __gpu_step.addFileArg(b.path(__gpu_name));
            \\                    __gpu_step.addArg(b.fmt("{s}.spv", .{__gpu_name[0 .. __gpu_name.len - ".mlir".len]}));
            \\                    exe.step.dependOn(&__gpu_step.step);
            \\                    exe.linkLibC();
            \\                    exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
            \\                    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
            \\                    exe.linkSystemLibrary("vulkan");
            \\                    exe.addRPath(.{ .cwd_relative = "/usr/local/lib" });
            \\                    continue;
            \\                }
            \\                const __mlir_name = b.dupe(__mlir_entry.name);
            \\                const __mlir_lower = b.addSystemCommand(&.{ "/opt/homebrew/opt/llvm/bin/mlir-opt", "--pass-pipeline=builtin.module(convert-scf-to-cf,expand-strided-metadata,finalize-memref-to-llvm,convert-arith-to-llvm,convert-cf-to-llvm,convert-func-to-llvm{use-bare-ptr-memref-call-conv=1},reconcile-unrealized-casts)" });
            \\                __mlir_lower.addFileArg(b.path(__mlir_name));
            \\                const __mlir_lowered = __mlir_lower.captureStdOut();
            \\                const __mlir_tr = b.addSystemCommand(&.{ "/opt/homebrew/opt/llvm/bin/mlir-translate", "--mlir-to-llvmir" });
            \\                __mlir_tr.addFileArg(__mlir_lowered);
            \\                const __mlir_ll = __mlir_tr.captureStdOut();
            \\                const __mlir_cc = b.addSystemCommand(&.{ "/opt/homebrew/opt/llvm/bin/clang", "-c", "-x", "ir" });
            \\                __mlir_cc.addFileArg(__mlir_ll);
            \\                __mlir_cc.addArg("-o");
            \\                const __mlir_obj = __mlir_cc.addOutputFileArg(b.fmt("{s}.o", .{__mlir_name}));
            \\                exe.addObjectFile(__mlir_obj);
            \\            }
            \\
        ;
        const Mlir = struct {
            fn emitProc(alloc: std.mem.Allocator, proc: ast.ProcDecl, out_dir: []const u8) !bool {
                const tgt = proc.target orelse return false;
                if (!std.mem.eql(u8, tgt, "mlir")) return false;
                var sym_buf = std.ArrayList(u8){};
                defer sym_buf.deinit(alloc);
                try sym_buf.appendSlice(alloc, "koru_mlir_");
                for (proc.path.segments, 0..) |seg, seg_i| {
                    if (seg_i > 0) try sym_buf.append(alloc, '_');
                    // Kebab event names are canonical Koru; symbols can't carry '-'.
                    for (seg) |ch| try sym_buf.append(alloc, if (ch == '-') '_' else ch);
                }
                const sym = sym_buf.items;
                // Write <sym>.mlir into the output dir (the build root for build_output.zig).
                const mlir_name = try std.fmt.allocPrint(alloc, "{s}.mlir", .{sym});
                defer alloc.free(mlir_name);
                const mlir_path = try std.fs.path.join(alloc, &[_][]const u8{ out_dir, mlir_name });
                defer alloc.free(mlir_path);
                const mf = try std.fs.cwd().createFile(mlir_path, .{});
                defer mf.close();
                try mf.writeAll(proc.body.text);
                return true;
            }
            // A Stage-C transform can only write its generated .mlir while the
            // backend runs, so Stage A must decide "this program will link MLIR"
            // from the raw AST: any invocation carrying the `mlir` variant tag.
            fn contHasMlirVariant(cont: *const ast.Continuation) bool {
                return contHasVariant(cont, "mlir");
            }
            fn run(alloc: std.mem.Allocator, items: []const ast.Item, out_dir: []const u8) !bool {
                var needs_link = false;
                for (items) |*item| {
                    switch (item.*) {
                        .proc_decl => |proc| {
                            if (try emitProc(alloc, proc, out_dir)) needs_link = true;
                        },
                        .flow => |*f| {
                            if (contHasMlirVariant(&f.body)) needs_link = true;
                        },
                        .module_decl => |*mod| {
                            if (try run(alloc, mod.items, out_dir)) needs_link = true;
                        },
                        else => {},
                    }
                }
                return needs_link;
            }
        };
        if (try Mlir.run(allocator, source_file.items, output_dir)) {
            try mlir_build_reqs.append(allocator, .{
                .module_name = "mlir",
                .source_code = try allocator.dupe(u8, mlir_glob_req),
            });
        }
    }

    // Synthesized build requirements for |fpga variants. Stage C writes
    // <sym>.fpga.sv + <sym>.fpga_tb.sv while the backend runs; Stage D's
    // build_output.zig globs `*.fpga.sv`, compiles module + testbench with
    // iverilog, and RUNS the sim under vvp — a circuit that computes the
    // wrong answer fails the build, the way spirv-val gates .spv blobs.
    // The same glob feeds yosys: `read_verilog -sv; hierarchy -check; proc;
    // check` must report 0 problems or the build fails — the artifact is
    // gated structurally (synthesizable RTL) and behaviorally (the sim).
    // (iverilog/vvp/yosys resolve through PATH; a machine without them fails
    // loudly rather than shipping an unsimulated circuit.)
    {
        const fpga_glob_req =
            \\            var __fpga_dir = b.build_root.handle.openDir(".", .{ .iterate = true }) catch @panic("fpga: cannot open build root");
            \\            defer __fpga_dir.close();
            \\            var __fpga_it = __fpga_dir.iterate();
            \\            while (__fpga_it.next() catch @panic("fpga: build-root iteration failed")) |__fpga_entry| {
            \\                if (__fpga_entry.kind != .file) continue;
            \\                if (!std.mem.endsWith(u8, __fpga_entry.name, ".fpga.sv")) continue;
            \\                const __fpga_base = __fpga_entry.name[0 .. __fpga_entry.name.len - ".fpga.sv".len];
            \\                const __fpga_tb = b.fmt("{s}.fpga_tb.sv", .{__fpga_base});
            \\                const __fpga_cc = b.addSystemCommand(&.{ "iverilog", "-g2012", "-o" });
            \\                const __fpga_sim = __fpga_cc.addOutputFileArg(b.fmt("{s}.fpga_sim", .{__fpga_base}));
            \\                __fpga_cc.addFileArg(b.path(__fpga_entry.name));
            \\                __fpga_cc.addFileArg(b.path(__fpga_tb));
            \\                const __fpga_run = b.addSystemCommand(&.{ "vvp" });
            \\                __fpga_run.addFileArg(__fpga_sim);
            \\                exe.step.dependOn(&__fpga_run.step);
            \\                const __fpga_ys = b.addSystemCommand(&.{ "sh", "-c" });
            \\                __fpga_ys.addArg(b.fmt("yosys -Q -T -p \"read_verilog -sv {s}; hierarchy -check -top {s}; proc; check\" 2>&1 | tee /dev/stderr | grep -q \"reported 0 problems\"", .{ __fpga_entry.name, __fpga_base }));
            \\                exe.step.dependOn(&__fpga_ys.step);
            \\            }
            \\
        ;
        const Fpga = struct {
            // Stage A decides "this program will emit .fpga.sv" from the raw
            // AST: any invocation carrying the `fpga` variant tag — the same
            // seam `mlir` rides, no symbol coordination across stages.
            fn contHasFpgaVariant(cont: *const ast.Continuation) bool {
                return contHasVariant(cont, "fpga");
            }
            fn run(alloc: std.mem.Allocator, items: []const ast.Item, out_dir: []const u8) !bool {
                var needs_sim = false;
                for (items) |*item| {
                    switch (item.*) {
                        .flow => |*f| {
                            if (contHasFpgaVariant(&f.body)) needs_sim = true;
                        },
                        .module_decl => |*mod| {
                            if (try run(alloc, mod.items, out_dir)) needs_sim = true;
                        },
                        else => {},
                    }
                }
                return needs_sim;
            }
        };
        if (try Fpga.run(allocator, source_file.items, output_dir)) {
            try mlir_build_reqs.append(allocator, .{
                .module_name = "fpga",
                .source_code = try allocator.dupe(u8, fpga_glob_req),
            });
        }
    }

    // Generate build_output.zig for OUTPUT binary (user build:requires + synthesized MLIR links + std/build:app identity)
    if (build_requirements_raw.len > 0 or mlir_build_reqs.items.len > 0 or app_decl != null) {
        var output_build_reqs = try std.ArrayList(emit_build_zig.BuildRequirement).initCapacity(allocator, build_requirements_raw.len + mlir_build_reqs.items.len + 1);
        defer output_build_reqs.deinit(allocator);

        for (build_requirements_raw) |req| {
            if (buildRequireSkippedOnWasm(req)) continue;
            try output_build_reqs.append(allocator, .{
                .module_name = "user",
                .source_code = req,
            });
        }
        for (mlir_build_reqs.items) |req| {
            try output_build_reqs.append(allocator, req);
        }

        // std/build:app → embed the declared identity as __TEXT,__info_plist
        // in the output binary (macho; no-op elsewhere).
        var app_req_source: ?[]u8 = null;
        defer if (app_req_source) |s| allocator.free(s);
        if (app_decl) |decl| {
            const icon_key: ?[]const u8 = if (decl.icon) |ic|
                emit_build_zig.appIconFileName(ic)
            else
                null;
            const app_req = try emit_build_zig.appInfoPlistRequirement(allocator, decl.name, decl.id, decl.version, icon_key);
            app_req_source = @constCast(app_req.source_code);
            try output_build_reqs.append(allocator, app_req);
            try printStdout(allocator, "✓ Embedding app identity '{s}' ({s})\n", .{ decl.id, decl.name });
        }

        if (build_requirements_raw.len > 0)
            try printStdout(allocator, "✓ Found {d} build requirement(s) for output binary\n", .{build_requirements_raw.len});
        if (mlir_build_reqs.items.len > 0)
            try printStdout(allocator, "✓ Synthesized {d} MLIR object link(s) for output binary\n", .{mlir_build_reqs.items.len});

        // Generate build_output.zig - this will be used to compile output_emitted.zig
        const build_output_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build_output.zig" });
        defer allocator.free(build_output_path);
        try emit_build_zig.emitOutputBuildZig(allocator, output_build_reqs.items, build_output_path, koru_lib_path);
        try printStdout(allocator, "✓ Generated {s} (for output binary)\n", .{build_output_path});
    }

    // Collect package requirements from AST (use source_file with imports merged!)
    var package_collector = try PackageRequirementsCollector.init(allocator);
    defer package_collector.deinit();
    try package_collector.collectFromSourceFile(&source_file);

    if (package_collector.hasAnyRequirements()) {
        const npm_reqs = package_collector.getNpmRequirements();
        const cargo_reqs = package_collector.getCargoRequirements();
        const go_reqs = package_collector.getGoRequirements();
        const pip_reqs = package_collector.getPipRequirements();
        const zig_reqs = package_collector.getZigRequirements();

        try printStdout(allocator, "✓ Found package requirements:\n", .{});
        if (npm_reqs.len > 0) try printStdout(allocator, "  - npm: {d} package(s)\n", .{npm_reqs.len});
        if (cargo_reqs.len > 0) try printStdout(allocator, "  - cargo: {d} package(s)\n", .{cargo_reqs.len});
        if (go_reqs.len > 0) try printStdout(allocator, "  - go: {d} package(s)\n", .{go_reqs.len});
        if (pip_reqs.len > 0) try printStdout(allocator, "  - pip: {d} package(s)\n", .{pip_reqs.len});
        if (zig_reqs.len > 0) try printStdout(allocator, "  - zig: {d} package(s)\n", .{zig_reqs.len});

        // Generate package files in output directory
        if (npm_reqs.len > 0) try emitRequirementFile(allocator, output_dir, "package.json", npm_reqs, emit_package_files.emitPackageJson);
        if (cargo_reqs.len > 0) try emitRequirementFile(allocator, output_dir, "Cargo.toml", cargo_reqs, emit_package_files.emitCargoToml);
        if (go_reqs.len > 0) try emitRequirementFile(allocator, output_dir, "go.mod", go_reqs, emit_package_files.emitGoMod);
        if (pip_reqs.len > 0) try emitRequirementFile(allocator, output_dir, "requirements.txt", pip_reqs, emit_package_files.emitRequirementsTxt);

        if (zig_reqs.len > 0) {
            const zon_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "build.zig.zon" });
            defer allocator.free(zon_path);
            // The zon is shared by every entry point built into this directory,
            // so the name is resolved per DIRECTORY (cwd basename when building
            // in place), never per input file — a per-entry name folds into
            // zig's fingerprint and rewrites it on every build (hole 5).
            const cwd_path = std.process.getCwdAlloc(allocator) catch null;
            defer if (cwd_path) |p| allocator.free(p);
            const cwd_basename = if (cwd_path) |p| std.fs.path.basename(p) else "";
            const project_name = emit_package_files.resolveProjectName(output_dir, cwd_basename, input_file);
            // Re-emit a previously-resolved fingerprint when one is on disk.
            // Zig accepts previously-issued fingerprints but mints a fresh
            // nondeterministic low half on every probe, so re-probing
            // unconditionally can never converge; the probe below still
            // replaces the value if it went stale.
            var kept_buf: ?[]u8 = null;
            defer if (kept_buf) |b| allocator.free(b);
            var kept_fp: ?[]const u8 = null;
            if (std.fs.cwd().openFile(zon_path, .{})) |existing| {
                defer existing.close();
                if (existing.readToEndAlloc(allocator, 64 * 1024)) |old| {
                    kept_buf = old;
                    kept_fp = emit_package_files.existingFingerprint(old);
                } else |_| {}
            } else |_| {}
            const zon_wrote = try emit_package_files.emitBuildZigZon(allocator, zig_reqs, zon_path, project_name, kept_fp);

            // Zig 0.15 requires a valid .fingerprint in build.zig.zon.
            // Run a probe build to extract the correct fingerprint from zig's error message,
            // then patch the zon file with it.
            const probe_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ emitter_helpers.zigExe(), "build", "--build-file", "build_backend.zig" },
                .cwd = output_dir,
            });
            defer allocator.free(probe_result.stdout);
            defer allocator.free(probe_result.stderr);

            // Look for "use this value: 0x..." in stderr (Zig 0.15 fingerprint error)
            var zon_patched = false;
            if (std.mem.indexOf(u8, probe_result.stderr, "use this value: 0x")) |idx| {
                const hex_start = idx + "use this value: ".len;
                // Find end of hex value (next non-hex char)
                var hex_end = hex_start + 2; // skip "0x"
                while (hex_end < probe_result.stderr.len and
                    (std.ascii.isHex(probe_result.stderr[hex_end]) or probe_result.stderr[hex_end] == 'x')) : (hex_end += 1)
                {}
                const fingerprint_str = probe_result.stderr[hex_start..hex_end];

                // Read the zon and replace the emitted fingerprint value (the
                // 0xDEAD placeholder or a kept-but-stale value) with the
                // probed one.
                const zon_file = try std.fs.cwd().openFile(zon_path, .{});
                const zon_content = try zon_file.readToEndAlloc(allocator, 64 * 1024);
                zon_file.close();
                defer allocator.free(zon_content);

                const fp_marker = ".fingerprint = ";
                if (std.mem.indexOf(u8, zon_content, fp_marker)) |mp| {
                    const val_start = mp + fp_marker.len;
                    var val_end = val_start;
                    while (val_end < zon_content.len and
                        (std.ascii.isHex(zon_content[val_end]) or zon_content[val_end] == 'x')) : (val_end += 1)
                    {}
                    var patched = try std.ArrayList(u8).initCapacity(allocator, zon_content.len + 20);
                    defer patched.deinit(allocator);
                    const w = patched.writer(allocator);
                    try w.writeAll(zon_content[0..val_start]);
                    try w.writeAll(fingerprint_str);
                    try w.writeAll(zon_content[val_end..]);

                    const zon_out = try std.fs.cwd().createFile(zon_path, .{});
                    defer zon_out.close();
                    try zon_out.writeAll(patched.items);
                    zon_patched = true;
                }
            }

            if (zon_wrote or zon_patched) {
                try printStdout(allocator, "✓ Generated {s}\n", .{zon_path});
            } else {
                try printStdout(allocator, "✓ {s} unchanged\n", .{zon_path});
            }
        }

        // Optionally run package managers if --install-packages flag is set
        if (install_packages) {
            try printStdout(allocator, "Installing packages...\n", .{});

            if (npm_reqs.len > 0) {
                try runPackageStep(allocator, output_dir, &.{ "npm", "install", "--prefix", output_dir }, "npm install", "npm packages installed");
            }

            if (cargo_reqs.len > 0) {
                const manifest_path = try std.fs.path.join(allocator, &.{ output_dir, "Cargo.toml" });
                try runPackageStep(allocator, output_dir, &.{ "cargo", "fetch", "--manifest-path", manifest_path }, "cargo fetch", "cargo packages fetched");
            }

            if (go_reqs.len > 0) {
                try runPackageStep(allocator, output_dir, &.{ "go", "mod", "download" }, "go mod download", "go modules downloaded");
            }

            if (pip_reqs.len > 0) {
                const reqs_path = try std.fs.path.join(allocator, &.{ output_dir, "requirements.txt" });
                try runPackageStep(allocator, output_dir, &.{ "pip", "install", "-r", reqs_path }, "pip install", "pip packages installed");
            }
        }
    }

    // Collect and execute build steps (if any)
    // Build steps can replace or augment the standard compilation pipeline
    // Phase 1: Collect all candidates (with module + default info)
    const collection = try collectBuildStepCandidates(parse_allocator, &source_file);
    defer {
        for (collection.candidates) |*candidate| {
            candidate.deinit(parse_allocator);
        }
        parse_allocator.free(collection.candidates);
    }

    // Phase 2: Resolve overrides using ~[default] precedence rules
    const build_steps = try resolveBuildSteps(parse_allocator, collection.candidates);
    defer {
        for (build_steps) |*step| {
            step.deinit(parse_allocator);
        }
        parse_allocator.free(build_steps);
    }

    // If there are user-defined build steps, execute them (including any defaults they depend on)
    // Default-only steps don't auto-execute - they're just available for override
    //
    // A DETECTED COMPTIME COMMAND must not be hijacked here EXCEPT `ci`. The step
    // graph self-executes on a plain build; `ci` is the shared vocabulary verb for
    // "run the whole graph" — a portable CI entry from a koru/github or koru/vercel
    // pipeline, and an ideal separator. Without this guard, declaring steps in the
    // same program as any other command made the frontend run the steps and return
    // before the command dispatcher saw the verb. `ci` is special-cased to drive
    // the graph here; every other command still dispatches to its backend handler.
    const drives_step_graph = detected_comptime_command == null or
        std.mem.eql(u8, detected_comptime_command.?, "ci");
    if (build_steps.len > 0 and collection.has_user_defined and drives_step_graph) {
        try executeBuildSteps(allocator, build_steps, output_dir);
        // Build steps handled everything, we're done!
        return;
    }

    // If build_executable is true, compile backend and run full pipeline
    if (build_executable) {
        // Determine output executable name. Under `bundle`, -o names the .app
        // — the built binary is packaging input, so it gets a scratch name and
        // is deleted once it is inside Contents/MacOS.
        const exe_name = if (bundle_after_build)
            ".koru_bundle_tmp"
        else if (exe_output_name) |name|
            name
        else
            "a.out";

        // Compile the backend using build_backend.zig (which has all module dependencies)
        try printStdout(allocator, "Building executable...\n", .{});

        // Use the generated build_backend.zig instead of direct zig build-exe
        // This ensures all module dependencies are properly linked
        const output_dir_for_build = std.fs.path.dirname(output) orelse ".";

        // `mint check` — the audit verb. Recomputes the closure over the live
        // tree and diffs it against the manifest. Runs AFTER emission (the
        // emitted hash is a component) but never reaches a zig build.
        if (mint_check_name) |mcn| {
            try runMintCheck(allocator, koru_lib_path, &resolver, mcn, comptime_backend_code);
            return;
        }

        // compiler:use — resolve the pinned mint. Verification lives in
        // resolveMintedBackend: emitted-closure coverage, AST/env protocol
        // compat, and the optional sha256 pin. A mint that fails any gate
        // exits there with the teaching — there is no degraded path.
        var minted_backend_path: ?[]const u8 = null;
        if (minted_use) {
            minted_backend_path = try resolveMintedBackend(allocator, koru_lib_path, &resolver, use_directive.?, comptime_backend_code);
        }

        // BACKEND BINARY CACHE: the backend is reusable across programs (its
        // own design note says so), and rebuilding it measured ~11.6s of every
        // compile at scale — the passes themselves are sub-second. On a cache
        // hit the produced binary is copied into place and the zig build is
        // skipped; on any doubt (IO error, missing inputs) we fall through to
        // the full build. The key covers every compiler-side input file.
        var backend_cached = false;
        if (minted_backend_path == null) {
            if (backendCacheKey(allocator, koru_lib_path, output_dir_for_build, output)) |bkey| {
            defer allocator.free(bkey);
            const cache_dir_path = backendCacheDir(allocator);
            defer allocator.free(cache_dir_path);
            const bkey_path = std.fs.path.join(allocator, &[_][]const u8{ cache_dir_path, bkey }) catch null;
            if (bkey_path) |bp_| {
                defer allocator.free(bp_);
                const bin_dir = std.fs.path.join(allocator, &[_][]const u8{ output_dir_for_build, "zig-out", "bin" }) catch null;
                if (bin_dir) |bd_| {
                    defer allocator.free(bd_);
                    const backend_dest = std.fs.path.join(allocator, &[_][]const u8{ bd_, "backend" }) catch null;
                    if (backend_dest) |bdest_| {
                        defer allocator.free(bdest_);
                        if (std.fs.cwd().access(bp_, .{})) |_| {
                            std.fs.cwd().makePath(bd_) catch {};
                            if (std.fs.cwd().copyFile(bp_, std.fs.cwd(), bdest_, .{})) |_| {
                                try printStdout(allocator, "✓ Backend cache hit (skipped zig build)\n", .{});
                                backend_cached = true;
                            } else |_| {}
                        } else |_| {}
                    }
                }
            }
        }

        // When running with cwd set to output_dir, build-file should be relative to that dir
        // KORU_BACKEND_TARGET=<triple>.<glibc> appends -Dtarget for hosts whose
        // glibc predates zig's native baseline (e.g. Ubuntu 20.04, glibc 2.31);
        // absent -> native resolution as before.
        const backend_target_env: ?[]const u8 = std.process.getEnvVarOwned(allocator, "KORU_BACKEND_TARGET") catch null;
        defer if (backend_target_env) |t| allocator.free(t);
        var backend_target_buf: [256]u8 = undefined;
        var args_buf: [5][]const u8 = undefined;
        var args_len: usize = 0;
        for ([_][]const u8{ emitter_helpers.zigExe(), "build", "--build-file", "build_backend.zig" }) |a| {
            args_buf[args_len] = a;
            args_len += 1;
        }
        if (backend_target_env) |t| {
            args_buf[args_len] = std.fmt.bufPrint(&backend_target_buf, "-Dtarget={s}", .{t}) catch unreachable;
            args_len += 1;
        }
        const zig_build_args = args_buf[0..args_len];

        // Run zig build in the output directory so zig-out/ is created there
        if (!backend_cached) {
            const compile_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = zig_build_args,
                .cwd = output_dir_for_build,
                .max_output_bytes = 10 * 1024 * 1024,
            });
            defer allocator.free(compile_result.stdout);
            defer allocator.free(compile_result.stderr);

            // The full Term union, not a bare `.Exited` access — this is the exact
            // site that panicked under memory pressure (2026-07-31): `zig build`
            // was OOM-killed, the active field was `.Signal`, and the union access
            // took koruc down in a way that read as a compiler crash.
            switch (compile_result.term) {
                .Exited => |code| if (code != 0) {
                    try printStderr(allocator, "✗ Failed to compile backend:\n{s}\n", .{compile_result.stderr});
                    std.process.exit(1);
                },
                else => {
                    try reportAbnormalTerm(allocator, "The backend build (zig build)", compile_result.term);
                    std.process.exit(1);
                },
            }

            // Store the freshly built backend into the cache so the next run
            // skips this build. Failure to store only costs a future rebuild.
            if (backendCacheKey(allocator, koru_lib_path, output_dir_for_build, output)) |bkey2| {
                defer allocator.free(bkey2);
                const cache_dir_path = backendCacheDir(allocator);
                defer allocator.free(cache_dir_path);
                std.fs.cwd().makePath(cache_dir_path) catch {};
                const bkey2_path = std.fs.path.join(allocator, &[_][]const u8{ cache_dir_path, bkey2 }) catch null;
                if (bkey2_path) |bp2_| {
                    defer allocator.free(bp2_);
                    const built_backend = std.fs.path.join(allocator, &[_][]const u8{ output_dir_for_build, "zig-out", "bin", "backend" }) catch null;
                    if (built_backend) |bb_| {
                        defer allocator.free(bb_);
                        std.fs.cwd().copyFile(bb_, std.fs.cwd(), bp2_, .{}) catch {};
                    }
                }
            }
        }
        }

        // `koruc <file> mint <name>` — the backend just built (or was served
        // from the cache — same binary either way). Store it under the name
        // with its manifest and stop: a mint records the compiler, it does
        // not compile the program.
        if (mint_create) |mname| {
            const built_backend = try std.fs.path.join(allocator, &[_][]const u8{ output_dir_for_build, "zig-out", "bin", "backend" });
            defer allocator.free(built_backend);
            try storeMint(allocator, koru_lib_path, &resolver, mname, built_backend, comptime_backend_code, input);
            return;
        }

        // Backend is at zig-out/bin/backend (from zig build) — or at the mint
        // store path when compiler:use pinned one.
        const backend_exe = "zig-out/bin/backend";

        // Now run the backend, which generates output_emitted.zig and compiles it
        // If a comptime command was detected, pass it to the backend
        var backend_args_list = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        defer backend_args_list.deinit(allocator);

        const backend_path = if (minted_backend_path) |mb|
            mb // absolute path into the mint store
        else
            std.fs.path.join(allocator, &.{ ".", backend_exe }) catch backend_exe;
        try backend_args_list.append(allocator, backend_path);

        if (detected_comptime_command) |cmd| {
            // Pass command as first argument (backend checks args[1] for commands)
            try backend_args_list.append(allocator, cmd);
            // Forward trailing args (subcommands/flags like "install", "--pm brew")
            for (command_trailing_args) |trailing| {
                try backend_args_list.append(allocator, trailing);
            }
        } else {
            // Normal compilation - pass output exe name
            try backend_args_list.append(allocator, exe_name);
        }

        defer if (backend_path.ptr != backend_exe.ptr) allocator.free(backend_path);

        // Run backend in the output directory.
        // stderr is piped (not inherited) so we can re-emit a clean
        // diagnostics summary on failure — Zig's build output buries
        // `error:` / `note:` lines under multi-line build-command echoes
        // and Build Summary noise, which makes real diagnostics hard to
        // read. We still stream the raw stderr verbatim so live feedback
        // is preserved; the summary appears at the end of the output.
        var child = std.process.Child.init(backend_args_list.items, allocator);
        child.cwd = output_dir_for_build;
        child.stdin_behavior = .Inherit; // Allow interactive stdin for the --inter TUI
        child.stdout_behavior = .Inherit; // Stream output directly
        child.stderr_behavior = .Pipe; // Capture for filtering on failure

        try child.spawn();

        // Drain stderr while the child runs. Complete lines are mirrored to
        // our own stderr AND kept in memory for post-failure filtering —
        // with one deliberate elision: once a diagnostic line has streamed,
        // the backend's trailing `❌ Compiler coordination error:` line and
        // its trace hint are the pipeline narrating its own plumbing over a
        // refusal that already spoke — vaguer than the diagnostic, no
        // location, and the summary string can contradict the diagnostic it
        // follows. With no diagnostic seen, both lines pass through: for a
        // user-authored coordinator override or a diagnostic-free internal
        // error that print IS the message (430_001/012/013/014 pin it).
        const stderr_handle = child.stderr orelse @panic("child stderr was not piped");
        var stderr_buf = try std.ArrayList(u8).initCapacity(allocator, 8192);
        defer stderr_buf.deinit(allocator);
        const stderr_capture_cap: usize = 1024 * 1024; // 1 MiB
        var read_buf: [4096]u8 = undefined;
        var pending = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer pending.deinit(allocator);
        var saw_backend_diagnostic = false;
        while (true) {
            const n = stderr_handle.read(&read_buf) catch break;
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                pending.append(allocator, byte) catch {};
                if (byte == '\n') {
                    mirrorBackendLine(allocator, pending.items, &saw_backend_diagnostic, &stderr_buf, stderr_capture_cap);
                    pending.clearRetainingCapacity();
                }
            }
        }
        // Trailing partial line (backend exited without a final newline).
        if (pending.items.len > 0)
            mirrorBackendLine(allocator, pending.items, &saw_backend_diagnostic, &stderr_buf, stderr_capture_cap);

        const term = try child.wait();

        switch (term) {
            .Exited => |code| if (code != 0) {
                try emitDiagnosticsSummary(allocator, stderr_buf.items);
                try printStderr(allocator, "✗ Backend execution failed\n", .{});
                std.process.exit(1);
            },
            else => {
                // No diagnostics summary here: a backend that never got to exit
                // produced no verdict to summarize (its streamed stderr, if any,
                // was already mirrored live above).
                try reportAbnormalTerm(allocator, "The backend (the compiled compiler pipeline)", term);
                std.process.exit(1);
            },
        }

        // Backend is in zig-out/bin/main - no cleanup needed
        // Users can clean with: rm -rf zig-out

        // JS-target spike: the backend already wrote output_emitted.js and
        // skipped Stage D — there is no native executable. Report the real
        // artifact and do NOT try to exec a binary that was never built.
        const is_js_target = std.mem.eql(u8, compiler_config.lang, "js");
        if (is_js_target) {
            try printStdout(allocator, "✓ Generated output_emitted.js (run with: node output_emitted.js)\n", .{});
        } else if (deep_check) {
            try printStdout(allocator, "✓ Deep check passed (emission written; native build skipped)\n", .{});
        } else if (detected_comptime_command) |cmd| {
            // A command run ends with the command, not with Stage D. Report the
            // command that ran.
            try printStdout(allocator, "✓ {s}\n", .{cmd});
        } else if (std.fs.cwd().access(exe_name, .{})) |_| {
            // The mode rides the success line — the Debug default is
            // deliberate (checks on for the suite to judge), but silent
            // is how a benchmark ends up timing a bounds-checked binary.
            const is_cs_target = std.mem.eql(u8, compiler_config.lang, "cs");
            const exe_mode = if (is_cs_target) ".NET" else if (compiler_config.hasFlag("debug")) "Debug" else if (compiler_config.hasFlag("release=fast")) "ReleaseFast" else if (compiler_config.hasFlag("release=safe")) "ReleaseSafe" else if (compiler_config.hasFlag("release=small")) "ReleaseSmall" else "Debug";
            try printStdout(allocator, "✓ Built executable: {s} ({s})\n", .{ exe_name, exe_mode });
        } else |_| {}

        // If run command, execute the binary
        if (run_after_build and !is_js_target and !deep_check) {
            try printStdout(allocator, "Running {s}...\n\n", .{exe_name});

            const exe_path = try std.fs.path.join(allocator, &.{ ".", exe_name });
            defer allocator.free(exe_path);

            // Run from the output directory so relative paths work
            const run_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{exe_path},
                .cwd = output_dir_for_build,
            });
            defer allocator.free(run_result.stdout);
            defer allocator.free(run_result.stderr);

            if (run_result.stdout.len > 0) {
                try printStdout(allocator, "{s}", .{run_result.stdout});
            }
            if (run_result.stderr.len > 0) {
                try printStdout(allocator, "{s}", .{run_result.stderr});
            }

            // This is the USER's program: a signal here is the program's own
            // termination (a SIGSEGV is its crash, not the machine's fault), so
            // report the fact plainly and forward the shell convention 128+sig.
            switch (run_result.term) {
                .Exited => |code| if (code != 0) std.process.exit(code),
                .Signal => |sig| {
                    try printStderr(allocator, "✗ {s} was killed by signal {d} ({s})\n", .{ exe_name, sig, signalName(sig) });
                    std.process.exit(@intCast(128 + (sig & 0x7f)));
                },
                else => {
                    var term_buf: [64]u8 = undefined;
                    try printStderr(allocator, "✗ {s} {s}\n", .{ exe_name, describeTerm(&term_buf, run_result.term) });
                    std.process.exit(1);
                },
            }
        }

        // `koru bundle` — the build ran; assemble the .app beside the output.
        // app_decl is non-null here: the refusal above already fired otherwise.
        if (bundle_after_build and !is_js_target and !deep_check) {
            // The scratch binary is consumed by the bundle — remove it on
            // every outcome, success or refusal.
            const scratch_path = try std.fs.path.join(allocator, &.{ output_dir_for_build, exe_name });
            defer allocator.free(scratch_path);
            const app_path = app_bundle.assembleMacApp(
                allocator,
                output_dir_for_build,
                input_dir,
                exe_name,
                app_decl.?,
                exe_output_name,
            ) catch |err| switch (err) {
                // assembleMacApp already printed the refusal — exit cleanly.
                error.InvalidBundlePath, error.CodesignFailed, error.InvalidIcon, error.IconNotFound => {
                    std.fs.cwd().deleteFile(scratch_path) catch {};
                    std.process.exit(1);
                },
                else => return err,
            };
            defer allocator.free(app_path);
            std.fs.cwd().deleteFile(scratch_path) catch {};
            try printStdout(allocator, "✓ Bundled: {s}\n", .{app_path});
            try printStdout(allocator, "  open \"{s}\"\n", .{app_path});
        }
    }

    // NOTE: AST cleanup now happens immediately after backend generation (line ~1485)
    // to properly free all memory before exit
}
