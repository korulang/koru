const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");
const type_registry = @import("type_registry");

/// Refuse a BARE host (Zig) type reference that crosses a module boundary.
///
/// A host type name is bare inside the module that declares it; across a
/// module boundary the signature spells it fully qualified — `*app/holder:Token`
/// — the same discipline invocations already follow. Bare cross-module names
/// used to resolve program-wide, first declaration wins, and a consumer's
/// import order rewrote a bystander module's own signatures; the spelling is
/// retired (220_031, ruled 2026-09-06).
///
/// Module-local bare stays legal, and so does the program top level's own bare
/// spelling: the writer is checked against the SET of declaring modules
/// (HostTypeDeclSites), not the first-wins winner — on a two-provider
/// collision the writer's own declaration still licenses its bare form.
///
/// What is NOT a refusal site:
///   - already-qualified spellings (`*std/string:String`) — they carry the
///     qualifier in the AST (`field.module_path`, or a `:` inside a
///     return/resume type string) and are the ruled fix, not the fault;
///   - parser-intrinsic types (`Source`, `File`, `Expression`, ...) — keywords,
///     not host-type references;
///   - names no module declares — the backend owns those.
pub const CheckError = error{OutOfMemory};

const TypePrefixes = [_][]const u8{ "[]const ", "?*const ", "*const ", "[]", "?*", "?", "*" };

const Intrinsics = [_][]const u8{ "Source", "File", "EmbedFile", "Expression", "InvocationMeta" };

/// Capture kinds that may never appear in a VALUE position (return type,
/// resume type, resume arm, outcome payload): they exist only at the call
/// site — a proc receives `Expression`/`Source`/`File`/`EmbedFile`/
/// `InvocationMeta` as the invocation's own text/metadata, so the producing
/// side has nothing to capture (R1/C1, ruled 2026-11-17). `-> Expression`
/// previously emitted `pub const Output = Expression;` — an undeclared Zig
/// identifier and a backend crash with no Koru diagnostic.
/// `Program` is deliberately NOT in this list: it is both a capture kind and
/// transform ABI (`-> *const Program`, 210_054/220_023), refused separately
/// only on events that are not comptime transforms.
const CaptureKinds = [_][]const u8{ "Expression", "Source", "File", "EmbedFile", "InvocationMeta" };

/// Input shapes carry capture-kind params legally; outcome payloads never do.
const ShapePosition = enum { input, outcome };

/// Where a type string sits on the event's surface.
const TypePosition = enum {
    /// An input-shape field: capture kinds and `Program`/`Source` handles are
    /// legal — `program_ast: *const Program` is a runtime AST handle
    /// (compiler.kz's `context-create` is the carrier), `*const Source` the
    /// testing lane's handle spelling.
    input,
    /// A return/resume/resume-arm type: capture kinds refuse (R1); bare
    /// `Program` refuses unless the event is a comptime transform.
    value,
};

/// Compiler-owned transform-ABI names that behave as keywords in RETURN
/// positions: the machinery string-matches them BARE (main.zig's
/// returns_program detects `-> Program` / `-> SiteResult` by substring;
/// emitter_helpers' ast_return_types lowers the bare form to `__koru_ast.X`).
/// They are protocol spellings of the compiler's own contract, not
/// module-owned host types — refusing them would break the transform ABI the
/// pins depend on (210_054's `-> *const Program` is load-bearing). PARAM
/// positions stay ruled-strict: `program: *std/compiler:Program` is the
/// migrated spelling and works (proven across the 2026-09-06 board).
const AbiReturnTypes = [_][]const u8{
    "ExplainReport", "SiteResult", "Program", "Item", "Source",
    "Invocation",    "EventDecl",  "ProcDecl", "Flow", "Branch",
    "Continuation",  "ASTNode",
};

pub fn check(allocator: std.mem.Allocator, items: []const ast.Item, reporter: *errors.ErrorReporter) CheckError!void {
    var sites = try type_registry.buildHostTypeDeclSites(allocator, items);
    defer type_registry.deinitHostTypeDeclSites(allocator, &sites);
    try checkItems(allocator, items, "", &sites, reporter);
}

fn checkItems(
    allocator: std.mem.Allocator,
    items: []const ast.Item,
    enclosing_module: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
) CheckError!void {
    for (items) |item| {
        switch (item) {
            .event_decl => |ev| try checkEvent(&ev, enclosing_module, sites, reporter),
            .module_decl => |m| try checkItems(allocator, m.items, m.logical_name, sites, reporter),
            else => {},
        }
    }
}

fn checkEvent(
    event: *const ast.EventDecl,
    writer_module: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
) CheckError!void {
    // Bare `Program` in a value position is transform ABI — legal only where
    // the event is a comptime transform: its input carries a capture kind
    // (isComptimeOnly) or it is annotated [comptime|transform] outright
    // (220_023's `*const ast.Program` param is qualified and keys on the
    // annotation alone).
    const allow_program = event.isComptimeOnly() or
        event.hasAnnotation("comptime") or event.hasAnnotation("transform");
    try checkShape(event.input.fields, writer_module, sites, reporter, event.location, .input, allow_program);
    for (event.branches) |branch| {
        try checkShape(branch.payload.fields, writer_module, sites, reporter, event.location, .outcome, allow_program);
        try checkTypeString(branch.resume_type, writer_module, sites, reporter, event.location, .value, allow_program);
        if (branch.resume_arms) |arms| {
            for (arms) |arm| try checkTypeString(arm.type, writer_module, sites, reporter, event.location, .value, allow_program);
        }
    }
    try checkTypeString(event.return_type, writer_module, sites, reporter, event.location, .value, allow_program);
    try refuseRedundantPhantom(event.return_type, event.return_phantom, reporter, event.location);
}

fn checkShape(
    fields: []const ast.Field,
    writer_module: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
    position: ShapePosition,
    allow_program: bool,
) CheckError!void {
    for (fields) |field| {
        const is_capture = field.is_source or field.is_file or field.is_embed_file or
            field.is_expression or field.is_invocation_meta;
        if (is_capture) {
            if (position == .outcome)
                try refuseCaptureValue(field.type, reporter, location, "an outcome payload");
            continue;
        }
        // The parser only flags capture params on the input shape; in outcome
        // position also name-match the unflagged spellings (`| exact Expression`,
        // `| exact Program`). A qualified field type names a module's own type
        // that happens to share the word — not the capture kind.
        if (position == .outcome and field.module_path == null) {
            if (qualifiedBaseName(field.type)) |base| {
                if (isCaptureKind(base) or
                    (std.mem.eql(u8, base, "Program") and !allow_program))
                {
                    try refuseCaptureValue(field.type, reporter, location, "an outcome payload");
                    continue;
                }
            }
        }
        try refuseRedundantPhantomOnField(field, reporter, location);
        // The qualified spelling carries its module in the AST — legal, but a
        // POINTERED qualified ref is a host handle and must still resolve to a
        // type its module declares (220_037).
        if (field.module_path) |mod| {
            try refuseIfQualifiedHostUnknown(mod, field.type, sites, reporter, location);
            continue;
        }
        try checkTypeString(field.type, writer_module, sites, reporter, location,
            if (position == .input) .input else .value, allow_program);
    }
}

fn isCaptureKind(base: []const u8) bool {
    for (CaptureKinds) |kind| {
        if (std.mem.eql(u8, base, kind)) return true;
    }
    return false;
}

/// R1 (ruled 2026-11-17): a syntax kind is call-site text — there is no call
/// site on the producing side to capture from, so naming one in a value
/// position can only crash the backend (undeclared `Output = Expression`) or
/// emit a `__koru_ast.*` type no proc can construct.
fn refuseCaptureValue(
    type_spelling: []const u8,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
    position: []const u8,
) CheckError!void {
    try reporter.addErrorAtLocationWithHint(
        .KORU118,
        location,
        "'{s}' is call-site syntax — it produces no runtime value and cannot appear in {s}",
        .{ type_spelling, position },
        "capture kinds (Expression, Source, File, EmbedFile, InvocationMeta) exist only as tor parameters; produce a runtime type instead",
        .{},
    );
}

/// Check a type spelled as a bare string (return types, effect resume types,
/// resume arms). The parser keeps these as written: a qualified spelling keeps
/// its `module:` colon; a bare one does not. A phantom tail (`<state>`) is
/// normally split off by the parser; cut defensively anyway.
fn checkTypeString(
    type_str: ?[]const u8,
    writer_module: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
    position: TypePosition,
    allow_program: bool,
) CheckError!void {
    const rt = type_str orelse return;
    const trimmed = std.mem.trim(u8, rt, " \t");
    // A record return (`-> { ctx: X, value: u32 }`) stays one raw string; its
    // per-field types each get the bare check (top-level commas only — commas
    // nested in <>/{}/[]/() belong to a field's own type).
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const inner = trimmed[1 .. trimmed.len - 1];
        var depth: i32 = 0;
        var start: usize = 0;
        for (inner, 0..) |c, i| {
            switch (c) {
                '<', '{', '[', '(' => depth += 1,
                '>', '}', ']', ')' => depth -= 1,
                ',' => if (depth == 0) {
                    try checkRecordField(inner[start..i], writer_module, sites, reporter, location, position, allow_program);
                    start = i + 1;
                },
                else => {},
            }
        }
        try checkRecordField(inner[start..], writer_module, sites, reporter, location, position, allow_program);
        return;
    }
    if (std.mem.indexOfScalar(u8, rt, '<')) |lt| {
        if (std.mem.lastIndexOfScalar(u8, rt, '>')) |gt| {
            if (gt > lt) try refuseRedundantPhantom(rt[0..lt], rt[lt + 1 .. gt], reporter, location);
        }
    }
    if (std.mem.indexOfScalar(u8, rt, ':') != null) { // qualified spelling
        try refuseIfQualifiedHostUnknown(null, rt, sites, reporter, location);
        return;
    }
    var base = rt;
    if (std.mem.indexOfScalar(u8, base, '<')) |lt| base = base[0..lt];
    for (TypePrefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) {
            base = base[prefix.len..];
            break;
        }
    }
    // R1/C1: capture kinds are call-site text — never a produced value. Bare
    // `Program` is refused the same way except where the event is a comptime
    // transform, for which `-> *const Program` is the ABI (210_054/220_023).
    // Input fields skip this entirely: `*const Program`/`*const Source` there
    // are runtime handles, not captures.
    if (position == .value and
        (isCaptureKind(base) or (std.mem.eql(u8, base, "Program") and !allow_program)))
        try refuseCaptureValue(base, reporter, location, "a return or resume type");
    for (AbiReturnTypes) |abi| {
        if (std.mem.eql(u8, base, abi)) return;
    }
    try refuseIfForeign(base, writer_module, sites, reporter, location);
}

/// One `name: type` pair of a record return. The pair's own `:` separator is
/// not a type qualifier — split at the FIRST top-level colon and check the
/// type tail alone.
fn checkRecordField(
    field_text: []const u8,
    writer_module: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
    position: TypePosition,
    allow_program: bool,
) CheckError!void {
    const text = std.mem.trim(u8, field_text, " \t");
    if (text.len == 0) return;
    var depth: i32 = 0;
    for (text, 0..) |c, i| {
        switch (c) {
            '<', '{', '[', '(' => depth += 1,
            '>', '}', ']', ')' => depth -= 1,
            ':' => if (depth == 0) {
                try checkTypeString(text[i + 1 ..], writer_module, sites, reporter, location, position, allow_program);
                return;
            },
            else => {},
        }
    }
}

/// A qualified host handle is POINTERED (`*Mod:Type`, `?*const Mod:Type`); a
/// proto/Koru terminal is value-typed (`app/alpha:Health`). Only pointered
/// qualified refs are host refs, so only those are validated here (665_012's
/// `app/alpha:Health` is a terminal, not a host type).
fn isPointerHostType(type_str: []const u8) bool {
    const t = std.mem.trim(u8, type_str, " \t");
    return std.mem.startsWith(u8, t, "*") or
        std.mem.startsWith(u8, t, "?*") or
        std.mem.startsWith(u8, t, "*const") or
        std.mem.startsWith(u8, t, "?*const");
}

/// The bare type name at the end of a qualified type: prefixes and any trailing
/// phantom stripped, then everything after the last `:`. `*libs/gzip:Deflater`
/// → `Deflater`; a field's `*Token` (module held separately) → `Token`.
fn qualifiedBaseName(type_str: []const u8) ?[]const u8 {
    var base = std.mem.trim(u8, type_str, " \t");
    if (std.mem.indexOfScalar(u8, base, '<')) |lt| base = base[0..lt];
    for (TypePrefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) {
            base = base[prefix.len..];
            break;
        }
    }
    if (std.mem.lastIndexOfScalar(u8, base, ':')) |c| base = base[c + 1 ..];
    return if (base.len == 0) null else base;
}

/// A POINTERED qualified host ref must name a host type that its module
/// declares. Otherwise a typo'd type or a wrong module reaches codegen and
/// surfaces as a raw Zig `has no member named` on an emitted artifact name
/// (`output_emitted.koru_app.koru_holder.Tokn`) — no source line, no Koru
/// diagnostic (220_037). Value-typed qualified refs (proto/Koru terminals) are
/// not host refs and are left to their own resolver.
fn refuseIfQualifiedHostUnknown(
    fallback_module: ?[]const u8,
    type_str: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
) CheckError!void {
    if (!isPointerHostType(type_str)) return;
    const module = typeModule(type_str) orelse fallback_module orelse return;
    const name = qualifiedBaseName(type_str) orelse return;
    const homes = sites.get(name) orelse {
        try reporter.addErrorAtLocationWithHint(
            .KORU117,
            location,
            "unknown host type '{s}' — no module declares it",
            .{name},
            "check the spelling; a qualified host reference must name a type its module declares",
            .{},
        );
        return;
    };
    for (homes.items) |home| {
        if (type_registry.moduleNamesMatch(home, module)) return;
    }
    var homes_buf = try std.ArrayList(u8).initCapacity(reporter.allocator, 0);
    defer homes_buf.deinit(reporter.allocator);
    for (homes.items, 0..) |home, i| {
        const home_slash = try dottedToSlash(reporter.allocator, home);
        defer reporter.allocator.free(home_slash);
        if (i > 0) try homes_buf.appendSlice(reporter.allocator, ", ");
        try homes_buf.appendSlice(reporter.allocator, home_slash);
    }
    const mod_slash = try dottedToSlash(reporter.allocator, module);
    defer reporter.allocator.free(mod_slash);
    try reporter.addErrorAtLocationWithHint(
        .KORU117,
        location,
        "host type '{s}' is declared by {s}, not '{s}'",
        .{ name, homes_buf.items, mod_slash },
        "write the declaring module: *<module>:{s}",
        .{name},
    );
}

fn refuseIfForeign(
    base: []const u8,
    writer_module: []const u8,
    sites: *const type_registry.HostTypeDeclSites,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
) CheckError!void {
    if (base.len == 0) return;
    for (base) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return;
    }
    for (Intrinsics) |intrinsic| {
        if (std.mem.eql(u8, base, intrinsic)) return;
    }
    const decls = sites.get(base) orelse return;
    // Module-local bare: the writer (or the top level, for its own decls)
    // declares the name itself — legal, however many other modules also do.
    for (decls.items) |home| {
        if (type_registry.moduleNamesMatch(home, writer_module)) return;
    }
    if (decls.items.len == 1) {
        const home = decls.items[0];
        const home_slash = try dottedToSlash(reporter.allocator, home);
        defer reporter.allocator.free(home_slash);
        try reporter.addErrorAtLocationWithHint(
            .KORU115,
            location,
            "host type '{s}' crosses a module boundary bare — write it qualified: *{s}:{s}",
            .{ base, home_slash, base },
            "the bare spelling is legal only inside the module that declares it ('{s}', same rule as invocations)",
            .{home_slash},
        );
    } else {
        var homes_buf = try std.ArrayList(u8).initCapacity(reporter.allocator, 0);
        defer homes_buf.deinit(reporter.allocator);
        for (decls.items, 0..) |home, i| {
            const home_slash = try dottedToSlash(reporter.allocator, home);
            defer reporter.allocator.free(home_slash);
            if (i > 0) try homes_buf.appendSlice(reporter.allocator, ", ");
            try homes_buf.appendSlice(reporter.allocator, home_slash);
        }
        try reporter.addErrorAtLocationWithHint(
            .KORU115,
            location,
            "bare host type '{s}' is declared by several modules ({s}) — the bare spelling cannot say which one a signature means",
            .{ base, homes_buf.items },
            "qualify it with the module you mean: *<module>:{s}",
            .{base},
        );
    }
}

/// A phantom qualifier that restates the base type's module is redundant:
/// `*app/lib/db:Transaction<app/lib/db:!active>` — the type already names
/// `app/lib/db`, so the state is `<!active>`. Deviation
/// (`string<app/lib/store:!secret>`, `Store<std/store:!taken>`) stays legal:
/// those phantoms name a different home than the type carries.
fn refuseRedundantPhantomOnField(
    field: ast.Field,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
) CheckError!void {
    const type_mod = field.module_path orelse typeModule(field.type) orelse return;
    try refuseRedundantPhantomAgainst(type_mod, field.phantom, reporter, location);
}

fn refuseRedundantPhantom(
    type_str: ?[]const u8,
    phantom: ?[]const u8,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
) CheckError!void {
    const ts = type_str orelse return;
    const type_mod = typeModule(ts) orelse return;
    try refuseRedundantPhantomAgainst(type_mod, phantom, reporter, location);
}

fn refuseRedundantPhantomAgainst(
    type_mod: []const u8,
    phantom: ?[]const u8,
    reporter: *errors.ErrorReporter,
    location: errors.SourceLocation,
) CheckError!void {
    const ph = phantom orelse return;
    const ph_mod = phantomModule(ph) orelse return;
    if (!type_registry.moduleNamesMatch(type_mod, ph_mod)) return;
    const state = phantomBareState(ph);
    const type_slash = try dottedToSlash(reporter.allocator, type_mod);
    defer reporter.allocator.free(type_slash);
    try reporter.addErrorAtLocationWithHint(
        .KORU116,
        location,
        "redundant phantom qualifier: bare '<{s}>' already scopes to the base type's module '{s}' — drop the qualifier",
        .{ state, type_slash },
        "write <{s}>; qualify a phantom only when its home differs from the type's",
        .{state},
    );
}

/// Module half of a qualified type (`*std/list:List_i64` → `std/list`).
/// Pointer prefixes and a trailing phantom are stripped first; no `:` means
/// the type carries no module (a primitive, or a module-local bare name).
fn typeModule(type_str: []const u8) ?[]const u8 {
    var base = std.mem.trim(u8, type_str, " \t");
    if (std.mem.indexOfScalar(u8, base, '<')) |lt| base = base[0..lt];
    for (TypePrefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) {
            base = base[prefix.len..];
            break;
        }
    }
    const colon = std.mem.lastIndexOfScalar(u8, base, ':') orelse return null;
    if (colon == 0) return null;
    return base[0..colon];
}

/// Module half of a qualified phantom (`std/list:!list` → `std/list`).
/// No `:` means the phantom is already the bare form.
fn phantomModule(phantom: []const u8) ?[]const u8 {
    const p = std.mem.trim(u8, phantom, " \t");
    const colon = std.mem.lastIndexOfScalar(u8, p, ':') orelse return null;
    if (colon == 0) return null;
    return p[0..colon];
}

fn phantomBareState(phantom: []const u8) []const u8 {
    const p = std.mem.trim(u8, phantom, " \t");
    if (std.mem.lastIndexOfScalar(u8, p, ':')) |c| return p[c + 1 ..];
    return p;
}

/// Diagnostic spellings use the surface (slash) form the writer would type;
/// the registry's logical names are dotted canon (`app.holder` → `app/holder`).
fn dottedToSlash(allocator: std.mem.Allocator, dotted: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, dotted);
    for (out) |*c| {
        if (c.* == '.') c.* = '/';
    }
    return out;
}

const testing = std.testing;

fn siteMap(allocator: std.mem.Allocator, pairs: []const struct { []const u8, []const u8 }) !type_registry.HostTypeDeclSites {
    var sites = type_registry.HostTypeDeclSites.init(allocator);
    for (pairs) |pair| {
        const gop = try sites.getOrPut(pair[0]);
        if (!gop.found_existing) gop.value_ptr.* = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        try gop.value_ptr.append(allocator, pair[1]);
    }
    return sites;
}

test "refusal: a bare host type written outside its declaring module is refused, naming the qualified fix" {
    const a = testing.allocator;
    var sites = try siteMap(a, &.{ .{ "Token", "app.holder" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "tor x { t: *Token }");
    defer reporter.deinit();

    try refuseIfForeign("Token", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 10 });
    try testing.expect(reporter.hasErrors());
    const err = reporter.errors.items[0];
    try testing.expectEqual(errors.ErrorCode.KORU115, err.code);
    // The fix must be in the MESSAGE, not only the hint: an agent scanning
    // errors reads the headline first, and reading only the hint's rationale
    // is what produced a false "host types are unnameable" rule.
    try testing.expect(std.mem.indexOf(u8, err.message, "*app/holder:Token") != null);
    try testing.expect(err.hint != null);
}

test "refusal: a pointered qualified host ref must name the declaring module" {
    const a = testing.allocator;
    var sites = try siteMap(a, &.{ .{ "Token", "app.holder" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();

    // Wrong module: Token IS a host type, but app.wrong does not declare it.
    try refuseIfQualifiedHostUnknown("app.wrong", "*Token", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    try testing.expect(reporter.hasErrors());
    try testing.expectEqual(errors.ErrorCode.KORU117, reporter.errors.items[0].code);
    try testing.expect(std.mem.indexOf(u8, reporter.errors.items[0].message, "app/holder") != null);
}

test "refusal: a pointered qualified host ref to an undeclared type is refused" {
    const a = testing.allocator;
    var sites = try siteMap(a, &.{ .{ "Token", "app.holder" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();

    // Typo: `Tokn` is declared by no module.
    try refuseIfQualifiedHostUnknown(null, "*app/holder:Tokn", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    try testing.expect(reporter.hasErrors());
    try testing.expectEqual(errors.ErrorCode.KORU117, reporter.errors.items[0].code);
}

test "legal: a correct pointered host ref, and a value-typed terminal ref, both pass" {
    const a = testing.allocator;
    var sites = try siteMap(a, &.{ .{ "Token", "app.holder" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();

    // Pointered, correct module -> legal.
    try refuseIfQualifiedHostUnknown(null, "*app/holder:Token", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    // Value-typed qualified ref (a proto terminal) -> not this check's business.
    try refuseIfQualifiedHostUnknown("app.alpha", "Health", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    try testing.expect(!reporter.hasErrors());
}

test "module-local bare stays legal: the writer declaring the name licenses its bare spelling" {
    const a = testing.allocator;
    // Two providers for the same name: only the WRITER's own declaration counts.
    var sites = try siteMap(a, &.{ .{ "Value", "std.eval" }, .{ "Value", "std.interpreter" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "eval.kz", "");
    defer reporter.deinit();

    try refuseIfForeign("Value", "std.eval", &sites, &reporter, .{ .file = "eval.kz", .line = 1, .column = 1 });
    try testing.expect(!reporter.hasErrors());
}

test "transform-ABI return keywords keep their bare spelling (behavior-bearing)" {
    const a = testing.allocator;
    var sites = try siteMap(a, &.{ .{ "Program", "std.compiler" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();

    // `-> *const Program` / `-> SiteResult` are the transform protocol's own
    // spellings: main.zig's returns_program and the emitter's ast_return_types
    // string-match them bare. A bare foreign `*Token` return still refuses,
    // and so does a capture kind in value position (R1/C1).
    try checkTypeString("*const Program", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 }, .value, true);
    try checkTypeString("SiteResult", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 }, .value, true);
    try checkTypeString("Expression", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 }, .value, true);
    try refuseIfForeign("Token", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    try testing.expect(reporter.hasErrors());
    try testing.expectEqual(@as(usize, 2), reporter.errors.items.len);
}

test "qualified spellings and undeclared names are not refusal sites" {
    const a = testing.allocator;
    var sites = try siteMap(a, &.{ .{ "Token", "app.holder" } });
    defer type_registry.deinitHostTypeDeclSites(a, &sites);
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();

    // Qualified spelling: legal everywhere (this is the ruled fix).
    try checkTypeString("*app/holder:Token", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 }, .value, true);
    // A name no module declares: the backend owns it, no refusal.
    try refuseIfForeign("u32", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    // Parser-intrinsic metatypes are keywords, not host-type references.
    try refuseIfForeign("Source", "", &sites, &reporter, .{ .file = "input.kz", .line = 1, .column = 1 });
    try testing.expect(!reporter.hasErrors());
}

test "redundant same-module phantom qualifier is refused, naming the bare fix" {
    const a = testing.allocator;
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();
    const loc = errors.SourceLocation{ .file = "input.kz", .line = 1, .column = 1 };

    try refuseRedundantPhantom("*app/lib/db:Transaction", "app/lib/db:!active", &reporter, loc);
    try testing.expect(reporter.hasErrors());
    try testing.expectEqual(errors.ErrorCode.KORU116, reporter.errors.items[0].code);
    try testing.expect(std.mem.indexOf(u8, reporter.errors.items[0].message, "redundant") != null);
    try testing.expect(std.mem.indexOf(u8, reporter.errors.items[0].message, "<!active>") != null);
    try testing.expect(std.mem.indexOf(u8, reporter.errors.items[0].message, "app/lib/db") != null);
}

test "a phantom whose home differs from the type's is not redundant" {
    const a = testing.allocator;
    var reporter = try errors.ErrorReporter.init(a, "input.kz", "");
    defer reporter.deinit();
    const loc = errors.SourceLocation{ .file = "input.kz", .line = 1, .column = 1 };

    // Primitive: no type module — qualifier is load-bearing (330_087).
    try refuseRedundantPhantom("string", "app/lib/store:!secret", &reporter, loc);
    // Local entity alias + store's taken (690_037).
    try refuseRedundantPhantom("Store", "std/store:!taken", &reporter, loc);
    // Typed base, foreign vocabulary — deviation.
    try refuseRedundantPhantom("*app/lib/db:Transaction", "app/lib/taint:tainted", &reporter, loc);
    // Already-bare phantom on a qualified type — the legal form.
    try refuseRedundantPhantom("*std/list:List_i64", "!list", &reporter, loc);
    try testing.expect(!reporter.hasErrors());
}
