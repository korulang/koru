// cs_emitter.zig — minimal, hello-world-shaped Koru → C# emitter (the K#
// vertical spike).
//
// SCOPE: this is the `cs` target's first emitter, forked off js_emitter.zig's
// architecture — same AST walk, same four-spelling impl resolution, same
// reached-gating for module events, same fail-loud contract — with every
// output site retargeted to C# 9 (net9.0):
//
//   - event decls → `static class <name>_event { static <Out>
//     handler(<Input> __koru_input) { … } }` nested in `main_module`, where
//     <Input>/<Out> are the generated Input/Output structs — and a
//     named-record payload gets its own generated `<b>_payload` nested
//     struct, a resume sum its `<b>_resume`. `dynamic` survives only where
//     a member genuinely cannot be named (wildcard shapes, `*T` handles,
//     `Source` params, the closure fallback); the contract elsewhere is
//     static — a wrong-typed cross-assembly call fails C# compilation, not
//     the runtime binder (220_054).
//   - `|cs` proc bodies, spliced verbatim (opaque host code) after binding
//     input fields as `var field = __koru_input.field;`.
//   - top-level flows → `flowN()` static methods; `Program.Main` invokes them.
//   - rendered-template inline bodies (`~if`, `~for`, `~cond`): the
//     `__koru_continue_N` / `__koru_inline_N` markers resolved inline, same
//     walk the JS emitter does.
//
// It is deliberately NARROW — narrower than the JS emitter, which started the
// same way. Effect-bearing events, label folds (`#L`/`@L`), taps/metatype
// records, destructure payloads and the void-effect splice all REFUSE by
// name rather than emit a shape no test has run. The vertical is `print.ln`
// through `~if`/`~for`/`~cond`; grow construct-by-construct from there.
//
// FAIL LOUD: an invocation it can't resolve, a construct it doesn't model, or
// Zig text detected in the finished buffer is an error, not an approximation.

const std = @import("std");
const ast = @import("ast");
const log = @import("log");
const file_types = @import("file_types");
const annotation_parser = @import("annotation_parser");
const struct_literal = @import("struct_literal");
const codegen_utils = @import("codegen_utils");
const emitter_helpers = @import("emitter_helpers");

pub const CsEmitError = error{
    OutOfMemory,
    UnresolvedEvent,
    UnsupportedConstruct,
    NoCsProcBody,
    // Emitted C# contained Zig-only syntax (an un-lowered construct was pasted
    // verbatim instead of refused). Surfaced as `error[KORU047]` by the driver.
    ZigTextInOutput,
};

/// The variant-tag string this emitter targets — the SAME namespace as
/// `--lang` / `proc.target` / `file_types.hostLangOfFile`, so it selects both
/// a `|cs` proc body and a `.kcs` host line.
const CS_TARGET = "cs";

/// The handler's payload parameter. RESERVED, not `input`: an event may
/// declare a field literally named `input`, and `var input = input.input;` is
/// a redeclaration C# refuses outright. Same reason as the JS/Zig targets.
const INPUT_PARAM = "__koru_input";

/// Emit C# for the given program. Returns a heap-allocated string owned by the
/// caller's allocator. `library` suppresses `Program.Main`: a program runs its
/// flows; a library emits the module class and no entry point.
pub fn emit(allocator: std.mem.Allocator, program: *const ast.Program, library: bool) CsEmitError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var em = Emitter{ .allocator = allocator, .buf = &buf, .items = program.items, .main_module_name = program.main_module_name };
    defer em.ops_buf.deinit(allocator);
    defer em.cells.deinit(allocator);
    defer em.host_text.deinit(allocator);

    // Phase 0: `.kcs` host lines verbatim at the TOP of the file (using
    // directives, file-scope declarations) — routed by host language, the same
    // test that selects a `|cs` proc body. Descends into module_decl so an
    // imported facet's host state reaches the output.
    try emitCsHostLines(&em, program.items);
    // …and collect the module cells those lines declare, for the
    // handler-scope hoist in emitEventDecl.
    try collectCsCells(&em, program.items);

    // A library build is consumed cross-assembly — `internal` (the C#
    // default) would make every `public` event class unreachable through
    // the .dll. Program mode stays internal: nothing outside references it.
    try em.write(if (library) "public static class main_module {\n" else "static class main_module {\n");
    // The stdout/stderr surface lives INSIDE main_module so the unqualified
    // `__koru_stdout_write(…)` a |cs transform emits resolves from every flow
    // and proc body. Write (not WriteLine): the transform appends its own
    // newline, mirroring the JS helpers.
    try em.write(
        \\  public static void __koru_stdout_write(object s) => global::System.Console.Out.Write(s);
        \\  public static void __koru_stderr_write(object s) => global::System.Console.Error.Write(s);
        \\  // The mutable handle carrier — `*String`-style resources are
        \\  // `new __KoruBox { data = … }` because C# anonymous types are
        \\  // read-only: `s.data = …` (std/string append/clear, handle
        \\  // mutation generally) needs a settable member. `object`, not
        \\  // `dynamic`: the field is storage — every `x.data` read reaches
        \\  // it through a dynamic-typed handle (`*T` Input fields, the
        \\  // `dynamic` borrow locals below), so the member itself only
        \\  // needs to hold the value, and `object` keeps the DLR out of
        \\  // the store/load path.
        \\  public class __KoruBox { public object data; }
        \\  // Textification for `{{ … }}` operands: C# bool ToStrings as
        \\  // `True` where Koru prints `true`, and the operand's static type
        \\  // is unknown at this boundary — a `(x) is bool` inline test would
        \\  // be a compile error on statically-typed operands instead. Generic
        \\  // on purpose: `dynamic` boxed every value-type operand — measured
        \\  // ~1s/10M elements on 012_threat_scanner — while T specializes to
        \\  // the operand's own ToString() with no box.
        \\  public static string __koru_str<T>(T v) => v is bool b ? (b ? "true" : "false") : v?.ToString();
        \\
    );

    // Phase 0.5: module-scope [declaration] flows and transform-appended
    // .inline_code, spliced as class members (C# has no file-scope statements;
    // whatever a |cs transform renders there is its own spelling problem).
    try emitCsDeclarations(&em, program.items);
    try emitTopLevelInlineCode(&em, program.items);

    // Which module events the emitted program actually REACHES — computed
    // before anything is written, because Phase 1b needs it to tell an event
    // nobody wants (skip in silence) from one a call site is about to
    // dispatch to (must account for itself). See collectReachedEvents.
    var reached = ReachedEvents.init(allocator);
    defer reached.deinit();
    try em.collectReachedEvents(&reached);

    // Every `<name>_event` key written into main_module so far — the nested
    // classes are one flat namespace while Koru event paths are not, so a
    // refusal stub must never clobber a working handler.
    var emitted_keys = EmittedKeys.init(allocator);
    defer {
        var it = emitted_keys.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        emitted_keys.deinit();
    }

    // Phase 1: each top-level event decl as a nested `<name>_event` class.
    // `[comptime]` events are compile-time-only by contract — their bodies
    // are always zig, and no runtime flow may dispatch them (the same skip
    // flowIsNorunSite applies at the call edge).
    for (program.items) |*item| {
        if (item.* == .event_decl) {
            if (annotation_parser.hasPart(item.event_decl.annotations, "comptime")) continue;
            try em.emitEventDecl(&item.event_decl, program.items);
            try em.claimEventKey(&emitted_keys, &item.event_decl);
        }
    }

    // Phase 1b: event decls in IMPORTED MODULES — gated on transitive
    // cs-implementability, with a self-naming refusal for anything reached
    // but unlowerable.
    for (program.items) |*item| {
        if (item.* != .module_decl) continue;
        try em.emitModuleEventDecls(&item.module_decl, &reached, &emitted_keys);
    }

    // Phase 2: each top-level flow as a flowN() method. Module runtime
    // flows emit first in the method table — a module's top-level flows are
    // its initialization, and Main calls them between koru:start and the
    // importer's own flows (mirrors the Zig emitter's module_runtime_flows
    // ordering).
    var flow_num: usize = 0;
    var koru_start_num: ?usize = null;
    var koru_end_num: ?usize = null;
    var module_flow_nums: std.ArrayList(usize) = .empty;
    defer module_flow_nums.deinit(allocator);
    var main_flow_nums: std.ArrayList(usize) = .empty;
    defer main_flow_nums.deinit(allocator);
    for (program.items) |*item| {
        if (item.* != .module_decl) continue;
        try em.emitModuleRuntimeFlows(&item.module_decl, &flow_num, &module_flow_nums);
    }
    for (program.items) |*item| {
        if (item.* == .flow) {
            // Subflow implementations are emitted inside their event's
            // handler, not as standalone methods.
            if (item.flow.impl_of != null) continue;
            if (em.isDeclarationFlow(&item.flow)) continue;
            // Injected meta-event flows (koru:start / koru:end) emit as
            // ordinary flowN methods — their continuations carry the
            // lifecycle taps — but Main calls them at the edges, not in
            // declaration order.
            if (item.flow.inv().path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "koru")) {
                    const leaf = item.flow.inv().path.segments[item.flow.inv().path.segments.len - 1];
                    if (std.mem.eql(u8, leaf, "start")) {
                        koru_start_num = flow_num;
                    } else if (std.mem.eql(u8, leaf, "end")) {
                        koru_end_num = flow_num;
                    } else continue;
                    try em.emitFlow(&item.flow, flow_num);
                    flow_num += 1;
                    continue;
                }
            }
            if (em.flowIsNorunSite(&item.flow)) continue;
            try em.emitFlow(&item.flow, flow_num);
            try main_flow_nums.append(allocator, flow_num);
            flow_num += 1;
        }
    }

    try em.write(em.ops_buf.items);
    try em.write("}\n");

    // The entry point: Program.Main invokes every emitted flow. A library
    // emits the module class and no door into it.
    if (!library) {
        try em.write("\nstatic class Program {\n  static void Main() {\n");
        if (koru_start_num) |n| try em.writeFmt("    main_module.flow{d}();\n", .{n});
        for (module_flow_nums.items) |n| try em.writeFmt("    main_module.flow{d}();\n", .{n});
        for (main_flow_nums.items) |n| try em.writeFmt("    main_module.flow{d}();\n", .{n});
        if (koru_end_num) |n| try em.writeFmt("    main_module.flow{d}();\n", .{n});
        try em.write("  }\n}\n");
    }

    // THE WALL — same invariant as the JS emitter's validateNoZigInJs: the
    // lowering is permissive by design, so validate the COMPLETE output once
    // here, where every paste path has already landed.
    try validateNoZigInCs(&buf);

    return buf.toOwnedSlice(allocator);
}

/// The refuse-not-paste wall, cs twin of validateNoZigInJs. Same token set —
/// every entry is invalid C# the same way it is invalid JavaScript, and `@` is
/// not a call sigil in either host, so an `@builtin` reaching the buffer can
/// only be an un-lowered construct. Adds one C#-specific catch: `.{` — a Zig
/// anonymous-struct opener that parses as a member access on nothing.
fn validateNoZigInCs(buf: *const std.ArrayList(u8)) CsEmitError!void {
    const text = buf.items;
    var i: usize = 0;
    var in_line_comment = false;
    var in_block_comment = false;
    var in_str: ?u8 = null;
    var line: usize = 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') line += 1;

        if (in_str) |q| {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
            } else if (c == q) {
                in_str = null;
            }
            continue;
        }
        if (in_line_comment) {
            if (c == '\n') in_line_comment = false;
            continue;
        }
        if (in_block_comment) {
            if (c == '*' and i + 1 < text.len and text[i + 1] == '/') {
                in_block_comment = false;
                i += 1;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            in_line_comment = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            in_block_comment = true;
            i += 1;
            continue;
        }

        if (c == '@') {
            // `@name(` is no C# call — but `@name` alone IS a verbatim
            // identifier, so only the call shape refuses here. The mangle
            // produces `@event`/ `@is` which never have `(` next.
            var p = i + 1;
            while (p < text.len and isIdentChar(text[p])) p += 1;
            const name = text[i .. p];
            if (name.len > 1) {
                for (ZIG_BUILTINS) |b| {
                    if (std.mem.eql(u8, name, b)) {
                        if (p < text.len and text[p] == '(') {
                            return refuseZigInCs(buf, line, b);
                        }
                    }
                }
            }
        } else if (c == ']' and i + 1 < text.len and (text[i + 1] == 'u' or text[i + 1] == 'i') and
            i + 2 < text.len and std.ascii.isDigit(text[i + 2]))
        {
            return refuseZigInCs(buf, line, "]uN Zig array type");
        } else if (c == '.' and i + 2 < text.len and text[i + 1] == '.' and text[i + 2] == ']') {
            return refuseZigInCs(buf, line, "..] Zig slice");
        } else if (c == '.' and i + 1 < text.len and text[i + 1] == '{') {
            return refuseZigInCs(buf, line, ".{ Zig struct literal");
        } else if (c == 'f' and i + 2 < text.len and text[i + 1] == 'n' and text[i + 2] == ' ' and
            (i == 0 or !std.ascii.isAlphanumeric(text[i - 1])) and (i == 0 or text[i - 1] != '_'))
        {
            return refuseZigInCs(buf, line, "fn Zig declaration");
        }
    }
}

fn refuseZigInCs(buf: *const std.ArrayList(u8), line: usize, what: []const u8) CsEmitError {
    const text = buf.items;
    var start: usize = 0;
    if (line > 1) {
        var found: usize = 0;
        var l: usize = 1;
        while (l < line and found < text.len) : (found += 1) {
            if (text[found] == '\n') l += 1;
        }
        start = found;
    }
    var end = start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    const ctx_len = @min(end - start, @as(usize, 80));
    log.err("[cs_emitter] REFUSE: {s} found in emitted C# at line {d} (un-lowered construct reached the output instead of refusing)\n", .{ what, line });
    log.err("  context: {s}\n", .{text[start .. start + ctx_len]});
    return CsEmitError.ZigTextInOutput;
}

const ZIG_BUILTINS = [_][]const u8{
    "@import",   "@as",        "@intCast",  "@floatCast", "@ptrCast",
    "@bitCast",  "@truncate",  "@min",      "@max",       "@mod",
    "@memcpy",   "@memset",    "@sizeOf",   "@TypeOf",    "@typeOf",
    "@alignOf",  "@field",     "@call",     "@intFrom",   "@floatFrom",
    "@enumFrom", "@unionInit", "@splat",    "@reduce",    "@panic",
    "@compileError", "@intTo", "@floatTo",  "@enumTo",    "@intFromFloat",
    "@floatFromInt", "@intFromBool", "@intFromEnum", "@enumFromInt",
    "@errorName", "@setRuntimeSafety", "@this", "@typeInfo", "@typeName",
    "@embedFile", "@cImport",  "@extern",   "@select",    "@mulAdd",
    "@addWithOverflow", "@subWithOverflow", "@mulWithOverflow",
    "@divTrunc",  "@divFloor", "@divExact", "@rem",       "@abs",
    "@clz",       "@ctz",      "@popCount", "@byteSwap",  "@bitReverse",
    "@log2",      "@log10",    "@exp2",     "@floor",     "@ceil",
    "@round",     "@fabs",     "@fmin",     "@fmax",      "@copysign",
    "@tagName",   "@breakpoint", "@returnAddress", "@frameAddress",
    "@hasDecl",   "@hasField", "@wasmMemorySize", "@wasmMemoryGrow",
};

/// Phase 0's walker: every `.kcs`-sourced host line in `items`, in order,
/// descending through `module_decl` so an imported facet's module-level C#
/// state reaches the output alongside the entry file's.
fn emitCsHostLines(em: *Emitter, items: []const ast.Item) CsEmitError!void {
    for (items) |*item| {
        switch (item.*) {
            .host_line => |*line| {
                const host = file_types.hostLangOfFile(line.location.file) orelse continue;
                if (!std.mem.eql(u8, host, CS_TARGET)) continue;
                try em.write(line.content);
                try em.write("\n");
            },
            .module_decl => |*m| try emitCsHostLines(em, m.items),
            else => {},
        }
    }
}

/// A module cell — a `static` field declared on a facet-authored
/// `static class` (the KoruHost convention). Slices borrow from the host
/// line text, which outlives emission.
const Cell = struct {
    name: []const u8,
    owner: []const u8,
    cs_ty: []const u8,
};

fn csIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `name` appears in `text` as a standalone identifier (word-boundary both
/// sides). `KoruHost.total`'s `total` qualifies — the boundary test only
/// asks about identifier characters, not `.`.
fn textMentionsIdent(text: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, name)) |at| {
        if ((at == 0 or !csIdentChar(text[at - 1])) and
            (at + name.len >= text.len or !csIdentChar(text[at + name.len])))
            return true;
        pos = at + 1;
    }
    return false;
}

/// Gather every cs host line into one buffer for the cell scan — the same
/// selection emitCsHostLines writes.
fn gatherCsHostLines(items: []const ast.Item, out: *std.ArrayList(u8), allocator: std.mem.Allocator) CsEmitError!void {
    for (items) |*item| {
        switch (item.*) {
            .host_line => |*line| {
                const host = file_types.hostLangOfFile(line.location.file) orelse continue;
                if (!std.mem.eql(u8, host, CS_TARGET)) continue;
                try out.appendSlice(allocator, line.content);
                try out.append(allocator, '\n');
            },
            .module_decl => |*m| try gatherCsHostLines(m.items, out, allocator),
            else => {},
        }
    }
}

/// Scan cs host text for `static class <Owner> { … static <T> <name> = … }`
/// field declarations — the module cells a handler may hoist. A name shared
/// by two owners is ambiguous under `using static` already; first wins, and
/// every gate in cellMayHoist drops on doubt anyway.
fn collectCsCells(em: *Emitter, items: []const ast.Item) CsEmitError!void {
    // The gathered text MOVES ONTO the emitter — Cell slices borrow from it,
    // so it must outlive emission, not this function.
    try gatherCsHostLines(items, &em.host_text, em.allocator);
    const t = em.host_text.items;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, t, pos, "static class")) |at| {
        var i = at + "static class".len;
        while (i < t.len and !csIdentChar(t[i])) i += 1;
        const ostart = i;
        while (i < t.len and csIdentChar(t[i])) i += 1;
        const owner = t[ostart..i];
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len or t[i] != '{') {
            pos = i;
            continue;
        }
        // matching close brace
        var depth: usize = 1;
        i += 1;
        while (i < t.len and depth > 0) : (i += 1) {
            if (t[i] == '{') depth += 1;
            if (t[i] == '}') depth -= 1;
        }
        const end = i -| 1;
        // Scan the class body for `static <T> <name>` FIELD decls — `(` after
        // the name is a method; `class`/`static` in the type slot is a nested
        // decl. Anything else that lexes odd simply isn't a cell.
        var j = ostart + owner.len;
        while (j + 6 < end) : (j += 1) {
            if (!std.mem.eql(u8, t[j .. j + 6], "static")) continue;
            if (j > 0 and csIdentChar(t[j - 1])) continue;
            var k = j + 6;
            if (k < end and csIdentChar(t[k])) continue;
            while (k < end and (t[k] == ' ' or t[k] == '\t')) k += 1;
            const tstart = k;
            while (k < end and csIdentChar(t[k])) k += 1;
            const ty = t[tstart..k];
            while (k < end and (t[k] == ' ' or t[k] == '\t')) k += 1;
            const nstart = k;
            while (k < end and csIdentChar(t[k])) k += 1;
            const nm = t[nstart..k];
            while (k < end and (t[k] == ' ' or t[k] == '\t')) k += 1;
            if (ty.len == 0 or nm.len == 0 or k >= end) continue;
            if (std.mem.eql(u8, ty, "class") or std.mem.eql(u8, ty, "static")) continue;
            if (t[k] != '=' and t[k] != ';') continue;
            try em.addCell(owner, ty, nm);
            j = k;
        }
        pos = end;
    }
}

/// Word-boundary rename of `name` to `replacement` inside `text` — used to
/// rebind an inlined proc's params to `__koru_p_<name>` so a splice can't
/// collide with an in-scope local. String/char literals and comments are
/// masked out — except interpolation holes, where the name IS a use-site.
fn replaceIdent(allocator: std.mem.Allocator, text: []const u8, name: []const u8, replacement: []const u8) CsEmitError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Positions where an identifier can live: anywhere EXCEPT inside string
    // and char literals and comments. A param named `n` rebinds the `{n}` in
    // `$"tick {n}\n"` but must NOT touch the `n` of `\n` — the escape's tail
    // is string content, not a use-site (236). Interpolation holes keep
    // code=true — `{n}` inside `$"…"` names the param.
    const code = try allocator.alloc(bool, text.len);
    defer allocator.free(code);
    @memset(code, true);
    {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') : (i += 1) code[i] = false;
                continue;
            }
            if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*') {
                code[i] = false;
                code[i + 1] = false;
                i += 2;
                while (i < text.len and !(i + 1 < text.len and text[i] == '*' and text[i + 1] == '/')) : (i += 1) code[i] = false;
                if (i < text.len) {
                    code[i] = false;
                    code[i + 1] = false;
                    i += 2;
                }
                continue;
            }
            var j = i;
            var interp = false;
            var verbatim = false;
            while (j < text.len and (text[j] == '$' or text[j] == '@')) : (j += 1) {
                if (text[j] == '$') interp = true;
                if (text[j] == '@') verbatim = true;
            }
            if (j < text.len and text[j] == '"') {
                code[j] = false;
                j += 1;
                while (j < text.len and text[j] != '"') {
                    if (!verbatim and text[j] == '\\') {
                        code[j] = false;
                        j += 1;
                        if (j < text.len) {
                            code[j] = false;
                            j += 1;
                        }
                        continue;
                    }
                    if (interp and text[j] == '{') {
                        if (j + 1 < text.len and text[j + 1] == '{') {
                            code[j] = false;
                            code[j + 1] = false;
                            j += 2;
                            continue;
                        }
                        code[j] = false;
                        j += 1;
                        var depth: usize = 1;
                        while (j < text.len and depth > 0) : (j += 1) {
                            if (text[j] == '{') depth += 1;
                            if (text[j] == '}') {
                                depth -= 1;
                                code[j] = false;
                            }
                        }
                        continue;
                    }
                    if (interp and text[j] == '}' and j + 1 < text.len and text[j + 1] == '}') {
                        code[j] = false;
                        code[j + 1] = false;
                        j += 2;
                        continue;
                    }
                    code[j] = false;
                    j += 1;
                }
                if (j < text.len) {
                    code[j] = false;
                    j += 1;
                }
                i = j;
                continue;
            }
            if (text[i] == '\'') {
                code[i] = false;
                i += 1;
                while (i < text.len and text[i] != '\'') {
                    if (text[i] == '\\') {
                        code[i] = false;
                        i += 1;
                        if (i < text.len) {
                            code[i] = false;
                            i += 1;
                        }
                        continue;
                    }
                    code[i] = false;
                    i += 1;
                }
                if (i < text.len) {
                    code[i] = false;
                    i += 1;
                }
                continue;
            }
            i += 1;
        }
    }
    // Positions inside a `new <T> { … }` object initializer — a name
    // appearing there as `<name> =` is a MEMBER KEY of the callee's Input
    // struct, not a use of the caller's local (a sweepbody capture at an
    // inlined-proc site: `Input { d = __koru_p_d }` — the value renames,
    // the key must not; 690_234/243).
    const in_init = try allocator.alloc(bool, text.len);
    defer allocator.free(in_init);
    @memset(in_init, false);
    {
        var stack: std.ArrayList(bool) = .empty; // true = an initializer brace
        defer stack.deinit(allocator);
        var i: usize = 0;
        while (i < text.len) {
            if (i + 3 <= text.len and std.mem.eql(u8, text[i .. i + 3], "new") and
                (i + 3 == text.len or !csIdentChar(text[i + 3])) and
                (i == 0 or !csIdentChar(text[i - 1])))
            {
                // Skip the type/member spelling; a `{` terminates it as an
                // initializer, anything else (`(`, `=`, `;`, `,`, `)`)
                // means an expression `new` with no initializer.
                var j = i + 3;
                while (j < text.len and (csIdentChar(text[j]) or text[j] == '.' or text[j] == ' ' or text[j] == '\t' or text[j] == '<' or text[j] == '>' or text[j] == '?')) j += 1;
                if (j < text.len and text[j] == '{') {
                    try stack.append(allocator, true);
                    i = j + 1;
                    continue;
                }
                i += 3;
                continue;
            }
            if (text[i] == '{') {
                try stack.append(allocator, false);
            } else if (text[i] == '}') {
                if (stack.pop()) |_| {}
            }
            if (stack.items.len > 0 and stack.items[stack.items.len - 1]) in_init[i] = true;
            i += 1;
        }
    }
    // `wrote` marks appended-until; `scan` marks searched-from. They differ:
    // a match that FAILS the boundary (`width` inside `width_sum`) advances
    // the scan but must not consume — its characters still need emitting.
    var wrote: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, text, scan, name)) |at| {
        // `.name` is member access — `store.hp` does not bind the local `hp`
        // an inlined callee's param rebind would rename (the plural store's
        // cell columns share their names with insert's parameters).
        const member_access = at > 0 and text[at - 1] == '.';
        // Inside an initializer, `name =` is a member key — skip it.
        var member_key = false;
        if (at < in_init.len and in_init[at]) {
            var k = at + name.len;
            while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
            member_key = k < text.len and text[k] == '=' and (k + 1 >= text.len or text[k + 1] != '=');
        }
        if (code[at] and !member_access and !member_key and
            (at == 0 or !csIdentChar(text[at - 1])) and
            (at + name.len >= text.len or !csIdentChar(text[at + name.len])))
        {
            try out.appendSlice(allocator, text[wrote..at]);
            try out.appendSlice(allocator, replacement);
            wrote = at + name.len;
            scan = wrote;
        } else {
            scan = at + 1;
        }
    }
    try out.appendSlice(allocator, text[wrote..]);
    return out.toOwnedSlice(allocator);
}

/// Module-scope `[declaration]` flows — a `const {}` introducing names into
/// the enclosing scope. Spliced inside main_module as class members through
/// the host-text lowering (a rendered `const|zig` body with `@as` refuses
/// there; a `const|cs` template renders its own spelling).
fn emitCsDeclarations(em: *Emitter, items: []const ast.Item) CsEmitError!void {
    for (items) |*item| {
        switch (item.*) {
            .flow => |*f| {
                if (!em.isDeclarationFlow(f)) continue;
                const body = stripInlineStmtMarker(f.inline_body.?);
                try em.write("  ");
                try em.writeHostText(std.mem.trim(u8, body, " \t\r\n"));
                try em.write("\n");
            },
            .module_decl => |*m| try emitCsDeclarations(em, m.items),
            else => {},
        }
    }
}

/// Every top-level `.inline_code` item, descending through `module_decl` —
/// host declarations a comptime transform appended beside the site it rewrote.
/// Emitted as class members; the transform renders them in the build language.
fn emitTopLevelInlineCode(em: *Emitter, items: []const ast.Item) CsEmitError!void {
    for (items) |*item| {
        switch (item.*) {
            .inline_code => |*ic| {
                try em.write("  ");
                try em.write(ic.code);
                try em.write("\n");
            },
            .module_decl => |*m| try emitTopLevelInlineCode(em, m.items),
            else => {},
        }
    }
}

/// Event decls the emitted program reaches, by POINTER identity — two modules
/// may declare the same path, and only the pointer distinguishes them.
const ReachedEvents = std.AutoHashMap(*const ast.EventDecl, void);

/// The `<name>_event` keys already written into `main_module`. Nested classes
/// are one flat namespace; Koru event paths are not.
const EmittedKeys = std.StringHashMap(void);

/// One enclosing `#L` fold on the `label_frame` chain.
const LabelFrame = struct {
    label: []const u8,
    /// The `var result_<id>` the fold reassigns on every turn.
    result_name: []const u8,
    /// The head invocation to re-run. Its arg NAMES are the fold's parameters.
    inv: *const ast.Invocation,
    /// The fold this one sits inside, or null at the outermost.
    outer: ?*const LabelFrame = null,
};

const Emitter = struct {
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    items: []const ast.Item,
    /// The program's main module name — reconciles a qualified call
    /// (`std.io:print.ln`) against the entry module's own decls.
    main_module_name: []const u8 = "",
    /// Monotonic counter for unique `result_<id>` names.
    id_counter: usize = 0,
    /// The event whose SUBFLOW impl body is currently being emitted, or null
    /// outside one — a call to one of that event's own effect arms is a
    /// FIRING, not an event invocation. The vertical refuses both anyway;
    /// the field stays so the shape of the check survives.
    impl_event: ?*const ast.EventDecl = null,
    /// `#L` fold frames, innermost first — a `@L(…)` jump finds its target
    /// by walking OUT through the enclosing folds, so an inner fold may
    /// jump to an outer label. Same chain the JS emitter keeps
    /// (js_emitter.zig:505); here it costs no allocation either.
    label_frame: ?*const LabelFrame = null,

    /// How produce sites inside the current impl spell their result. `dynamic`
    /// keeps the anonymous-object/`return <expr>` shape (opaque |cs bodies and
    /// any context outside a generated impl — including ARM delegate bodies,
    /// whose produce is a resume value, not the tor's Output). `tagged` turns
    /// `=> b` into `new <Output> { tag = "b", … }`; `bare` turns `-> expr`
    /// into `return (<T>)(<expr>)`.
    impl_out: ImplOut = .dynamic,
    /// Handler STRUCT decls collected while emitting call sites — flushed at
    /// main_module scope before the class closes. C# has no type decls inside
    /// methods and a call site may sit inside a nested event class, so the
    /// struct must land one scope up no matter which body produced it.
    ops_buf: std.ArrayList(u8) = .empty,
    /// The names currently in scope as locals of the method being emitted —
    /// the candidates an arm-body METHOD may capture into `__cap_*` struct
    /// fields (the C# spelling of Zig's const-capture: `Handlers_N.fn` reads
    /// the enclosing `const` directly; a C# struct member cannot, so the
    /// value copies in at construction). Stored in emitted spelling —
    /// kebab-lowered, `@`-escaped — the form the body text contains.
    flow_locals: std.ArrayList([]const u8) = .empty,
    /// Module cells — `static` fields declared on facet-authored
    /// `static class`es (the KoruHost convention: C# has no file-scope
    /// variables, so module state is a class static). Nothing outside the
    /// program's own text can name a cell — there are no variables, so the
    /// accessor list is the grammar — which is what makes a handler allowed
    /// to materialize one as a LOCAL for its body's duration and write back
    /// once at the end.
    cells: std.ArrayList(Cell) = .empty,
    /// The concatenated `.kcs` host text the cells' slices borrow from —
    /// kept alive until emit() returns.
    host_text: std.ArrayList(u8) = .empty,

    fn nextId(self: *Emitter) usize {
        const id = self.id_counter;
        self.id_counter += 1;
        return id;
    }

    /// Record a name just emitted as a local of the current method — a
    /// capture candidate for arm-body methods. Internal names (`__koru_*`,
    /// `result_*`) can never be written as koru bindings and are skipped.
    /// A `result-1` binding collides with the internal prefix on purpose:
    /// that name simply cannot be captured.
    fn registerLocal(self: *Emitter, name: []const u8) CsEmitError!void {
        var buf: [300]u8 = undefined;
        const spelled = spelledName(&buf, name) orelse return;
        if (std.mem.startsWith(u8, spelled, "__koru_") or
            std.mem.startsWith(u8, spelled, "result_")) return;
        for (self.flow_locals.items) |n| {
            if (std.mem.eql(u8, n, spelled)) return;
        }
        try self.flow_locals.append(self.allocator, try self.allocator.dupe(u8, spelled));
    }

    /// A binding name in emitted spelling, owned — for `var` declarations
    /// the result-binding path writes as plain `{s}` text.
    fn dupeSpelled(self: *Emitter, name: []const u8) CsEmitError![]u8 {
        var buf: [300]u8 = undefined;
        const s = spelledName(&buf, name) orelse name;
        return self.allocator.dupe(u8, s);
    }

    /// Record a module cell discovered in the host lines — first owner wins
    /// on a name collision (a bare name ambiguous under `using static` is a
    /// broken facet to begin with; cellMayHoist drops on doubt regardless).
    fn addCell(self: *Emitter, owner: []const u8, cs_ty: []const u8, name: []const u8) CsEmitError!void {
        for (self.cells.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return;
        }
        try self.cells.append(self.allocator, .{ .name = name, .owner = owner, .cs_ty = cs_ty });
    }

    pub fn write(self: *Emitter, text: []const u8) CsEmitError!void {
        try self.buf.appendSlice(self.allocator, text);
    }

    pub fn writeFmt(self: *Emitter, comptime fmt: []const u8, args: anytype) CsEmitError!void {
        try self.buf.print(self.allocator, fmt, args);
    }

    /// Identifier formation boundary: names are kebab-canonical in the
    /// pipeline; a dash lowers to underscore while writing a C# identifier
    /// (C# cannot spell `-` in one — unlike JS object keys, an anonymous-
    /// object's member names are identifiers, so keys lower here too).
    fn writeIdent(self: *Emitter, name: []const u8) CsEmitError!void {
        for (name) |c| {
            // `-` is Koru's kebab and `.` the dotted-name join (a union-folded
            // column like `creature.alive` is ONE name, Zig's `@"…"` quoting
            // notwithstanding); both fold into the cs identifier.
            try self.buf.append(self.allocator, if (c == '-' or c == '.') '_' else c);
        }
    }

    /// Same boundary, for a name in BINDING position — `var <n>`, a member
    /// name on an anonymous object, a member read. Adds the C# reserved-word
    /// escape on top of the kebab lowering: `event` → `@event`, which is a
    /// verbatim identifier and still readable — the native mechanism JS's
    /// `$`-suffix stands in for. Keys come here too (unlike JS, whose keys
    /// stay raw): `new { @event = v }` and `result.@event` are both valid C#,
    /// so writer and reader agree by construction.
    fn writeBinding(self: *Emitter, name: []const u8) CsEmitError!void {
        const needs_mangle = blk: {
            var stem_buf: [256]u8 = undefined;
            if (name.len <= stem_buf.len) {
                for (name, 0..) |c, i| stem_buf[i] = if (c == '-' or c == '.') '_' else c;
                break :blk codegen_utils.isCsReservedForEmit(stem_buf[0..name.len]);
            }
            break :blk false;
        };
        if (needs_mangle) try self.buf.append(self.allocator, '@');
        try self.writeIdent(name);
    }

    /// Buffer variant of the identifier lowering, for sites that need the
    /// lowered name as a string (format args).
    fn lowerIdentBuf(buf: []u8, name: []const u8) []const u8 {
        @memcpy(buf[0..name.len], name);
        for (buf[0..name.len]) |*c| {
            if (c.* == '-' or c.* == '.') c.* = '_';
        }
        return buf[0..name.len];
    }

    /// A terminal branch's payload member name — `tag` collides with the
    /// Output struct's discriminator member (a `tag` column's apply arm,
    /// 690_336), so it reads and writes as `__ktag`. Transform-authored
    /// text maps through `HostShape.csPayloadMember`, the same spelling.
    fn csPayloadName(name: []const u8) []const u8 {
        return if (std.mem.eql(u8, name, "tag")) "__ktag" else name;
    }

    /// The emitted class name for an event — the module qualifier then the
    /// FULL dotted path joined (`io:print.ln` → `std_io_print_ln_event`),
    /// EXCEPT the main module's own decls, which keep the bare joined path:
    /// transform-authored call text spells `<name>_event` for the
    /// synthesized events it placed there (`__store_sweepbody_*`,
    /// `__store_qrow_*`, …) and cannot predict a qualifier it never wrote.
    /// Nested classes are one flat namespace while Koru tor identities are
    /// qualifier + path: `fmt:ln` and `io:print.ln` share the last segment
    /// `ln`, and `io:free`/`string:free` share the WHOLE path — last-
    /// segment naming emitted duplicate `<name>_event` classes in one file
    /// (690_046, 690_190). JS keeps the dot inside the object key, which is
    /// why that target never collided.
    fn eventClassName(self: *Emitter, buf: []u8, ev: *const ast.EventDecl) []const u8 {
        var n: usize = 0;
        if (ev.path.module_qualifier) |mq| {
            if (!std.mem.eql(u8, mq, self.main_module_name)) {
                for (mq) |c| {
                    buf[n] = switch (c) {
                        '/', '.', '-' => '_',
                        else => c,
                    };
                    n += 1;
                }
                buf[n] = '_';
                n += 1;
            }
        }
        for (ev.path.segments, 0..) |seg, si| {
            if (si > 0) {
                buf[n] = '_';
                n += 1;
            }
            for (seg) |c| {
                buf[n] = if (c == '-' or c == '.') '_' else c;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Read a property off a `dynamic` — `base.key`. A payload key lowers to a
    /// C# identifier (kebab → underscore; the producer wrote it through the
    /// same writeIdent on the anonymous object's member name).
    fn writeMember(self: *Emitter, base: []const u8, key: []const u8) CsEmitError!void {
        try self.write(base);
        try self.write(".");
        try self.writeBinding(key);
    }

    /// Find the |cs proc for `event_path` WITHIN a given item scope
    /// (segment-equal). Mirrors findJsProcIn: `[transform]`/`[template]` procs
    /// are skipped — their `|cs` bodies are stage-C host code that EMITS C#,
    /// not C# itself, and splicing one put Zig inside the JS output the first
    /// time this distinction was missed.
    fn findCsProcIn(self: *Emitter, scope: []const ast.Item, event_path: *const ast.DottedPath) ?*const ast.ProcDecl {
        _ = self;
        var joined_ev: [256]u8 = undefined;
        var joined_ev_len: usize = 0;
        for (event_path.segments, 0..) |seg, si| {
            if (si > 0) {
                if (joined_ev_len >= joined_ev.len) return null;
                joined_ev[joined_ev_len] = '.';
                joined_ev_len += 1;
            }
            if (joined_ev_len + seg.len > joined_ev.len) return null;
            @memcpy(joined_ev[joined_ev_len .. joined_ev_len + seg.len], seg);
            joined_ev_len += seg.len;
        }
        const event_joined = joined_ev[0..joined_ev_len];
        for (scope) |*item| {
            if (item.* != .proc_decl) continue;
            const proc = &item.proc_decl;
            var joined_p: [256]u8 = undefined;
            var joined_p_len: usize = 0;
            var overflow = false;
            for (proc.path.segments, 0..) |seg, si| {
                if (si > 0) {
                    if (joined_p_len >= joined_p.len) { overflow = true; break; }
                    joined_p[joined_p_len] = '.';
                    joined_p_len += 1;
                }
                if (joined_p_len + seg.len > joined_p.len) { overflow = true; break; }
                @memcpy(joined_p[joined_p_len .. joined_p_len + seg.len], seg);
                joined_p_len += seg.len;
            }
            if (overflow) continue;
            // Joined compare: the abstract-default machinery splits a tor's
            // default body into `x.default` — the .kz surface writes it as a
            // dotted segment while a facet path tokenizes dots apart. Both
            // spellings name the same tor.
            if (!std.mem.eql(u8, joined_p[0..joined_p_len], event_joined)) continue;
            const target = proc.target orelse continue;
            if (!std.mem.eql(u8, target, CS_TARGET)) continue;
            if (annotation_parser.hasPart(proc.annotations, "transform")) continue;
            if (annotation_parser.hasPart(proc.annotations, "template")) continue;
            return proc;
        }
        // `.default` fallback: an abstract tor's synthesized `x.default`
        // event shares the `x` proc's body — the zig emitter does this
        // split at AST time; cs facets only ever name `x`.
        if (event_joined.len > 8 and
            std.mem.eql(u8, event_joined[event_joined.len - 8 ..], ".default"))
        {
            const base = event_joined[0 .. event_joined.len - 8];
            for (scope) |*item| {
                if (item.* != .proc_decl) continue;
                const proc = &item.proc_decl;
                var pb: [256]u8 = undefined;
                if (!std.mem.eql(u8, joinedPath(&pb, &proc.path), base)) continue;
                const target = proc.target orelse continue;
                if (!std.mem.eql(u8, target, CS_TARGET)) continue;
                if (annotation_parser.hasPart(proc.annotations, "transform")) continue;
                if (annotation_parser.hasPart(proc.annotations, "template")) continue;
                return proc;
            }
        }
        return null;
    }

    /// Resolve an invocation path to its event decl, descending into imported
    /// modules — module-qualified call sites reconciled by pathsEqualWithModule.
    fn findEventDecl(self: *Emitter, path: *const ast.DottedPath) ?*const ast.EventDecl {
        return self.findEventDeclIn(self.items, path, null);
    }

    /// Invocation-side resolution. Inside an override subflow
    /// (`~mod:x = x(...)`) a call back to `x` means "delegate to the
    /// default" — zig emits `_default_handler` for that self-call; the cs
    /// surface has the synthesized `x.default` event decl instead, so the
    /// invocation resolves to it. Every other call resolves plainly.
    fn resolveInvocationEvent(self: *Emitter, inv: *const ast.Invocation) ?*const ast.EventDecl {
        const ev = self.findEventDecl(&inv.path) orelse return null;
        const impl_ev = self.impl_event orelse return ev;
        var ib: [256]u8 = undefined;
        var eb: [256]u8 = undefined;
        const inv_joined = joinedPath(&ib, &inv.path);
        const impl_joined = joinedPath(&eb, &impl_ev.path);
        if (!std.mem.eql(u8, inv_joined, impl_joined)) return ev;
        var want_buf: [256]u8 = undefined;
        const want = std.fmt.bufPrint(&want_buf, "{s}.default", .{inv_joined}) catch return ev;
        const want_mod = impl_ev.path.module_qualifier orelse "";
        for (self.items) |*item| {
            switch (item.*) {
                .event_decl => |*ed| {
                    var db: [256]u8 = undefined;
                    if (std.mem.eql(u8, ed.path.module_qualifier orelse "", want_mod) and
                        std.mem.eql(u8, joinedPath(&db, &ed.path), want)) return ed;
                },
                .module_decl => |*md| {
                    for (md.items) |*it2| {
                        if (it2.* != .event_decl) continue;
                        const ed2 = &it2.event_decl;
                        var db: [256]u8 = undefined;
                        if (std.mem.eql(u8, ed2.path.module_qualifier orelse "", want_mod) and
                            std.mem.eql(u8, joinedPath(&db, &ed2.path), want))
                            return ed2;
                    }
                },
                else => {},
            }
        }
        return ev;
    }

    fn findEventDeclIn(self: *Emitter, scope: []const ast.Item, path: *const ast.DottedPath, current_module: ?[]const u8) ?*const ast.EventDecl {
        for (scope) |*item| {
            switch (item.*) {
                .event_decl => |*e| {
                    if (pathsEqualWithModule(&e.path, path, current_module, self.main_module_name)) return e;
                },
                .module_decl => |*m| {
                    if (self.findEventDeclIn(m.items, path, m.logical_name)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }

    /// A `[declaration]` flow introduces names into the enclosing scope rather
    /// than executing — spliced as a class member (Phase 0.5), never a flowN().
    fn isDeclarationFlow(self: *Emitter, flow: *const ast.Flow) bool {
        if (flow.inline_body == null) return false;
        const decl = self.findEventDecl(&flow.inv().path) orelse return false;
        return annotation_parser.hasPart(decl.annotations, "declaration");
    }

    /// A `[norun]` event claims its site as AST data — the flow never
    /// executes and no handler call may reach the output. A `[comptime]`
    /// event's flows already ran during compilation — they print to the
    /// BUILD log, and emitting a runtime dispatch for them would run the
    /// body a second time. Mirrors the JS emitter's guard (visitor walk's
    /// is_norun twin).
    fn flowIsNorunSite(self: *Emitter, flow: *const ast.Flow) bool {
        if (flow.inline_body != null or flow.preamble_code != null) return false;
        for (flow.inv().marks) |ann| {
            if (std.mem.startsWith(u8, ann, "@pass_ran")) return false;
        }
        const site = self.findDeclSiteIn(self.items, &flow.inv().path, null) orelse return false;
        return annotation_parser.hasPart(site.decl.annotations, "norun") or
            annotation_parser.hasPart(site.decl.annotations, "comptime");
    }

    /// How an event's behaviour is supplied — the four spellings, resolved in
    /// the same order the JS emitter resolves them: `|cs` proc first, then an
    /// immediate/arrow impl, then a subflow, and LAST a `|template|` proc
    /// (not a body — the absence of one at the decl site).
    const EventImpl = union(enum) {
        proc: *const ast.ProcDecl,
        template_stub: *const ast.ProcDecl,
        /// `[norun]`/`[expand]` decl with no body of its own — call sites
        /// are rewritten/claimed as data, so the handler is unreachable.
        dead_stub,
        /// Declared + dispatched but no body in ANY language — zig's
        /// `return undefined` spelled `return default`.
        empty_body,
        immediate: *const ast.ImmediateImpl,
        subflow: *const ast.Flow,
    };

    /// The joined dotted spelling of a path — `x` and `x.y` segments both
    /// spell `x.y` — the shape the abstract-default split writes.
    fn joinedPath(buf: []u8, path: *const ast.DottedPath) []const u8 {
        var n: usize = 0;
        for (path.segments, 0..) |seg, si| {
            if (si > 0 and n < buf.len) {
                buf[n] = '.';
                n += 1;
            }
            if (n + seg.len > buf.len) return buf[0..n];
            @memcpy(buf[n .. n + seg.len], seg);
            n += seg.len;
        }
        return buf[0..n];
    }

    /// True when `scope` declares an event whose joined path is
    /// `<event_joined>.default` — the shape the `[abstract]` machinery
    /// synthesizes when a tor carries BOTH a default body and an override.
    /// In that split the base-named proc belongs to `.default` and the base
    /// event's behaviour is the override impl.
    fn hasAbstractDefaultSibling(scope: []const ast.Item, event_joined: []const u8) bool {
        for (scope) |*item| {
            if (item.* != .event_decl) continue;
            var buf: [256]u8 = undefined;
            const joined = joinedPath(&buf, &item.event_decl.path);
            if (joined.len == event_joined.len + 8 and
                std.mem.eql(u8, joined[0..event_joined.len], event_joined) and
                std.mem.eql(u8, joined[event_joined.len..], ".default"))
            {
                return true;
            }
        }
        return false;
    }

    fn findImplIn(self: *Emitter, scope: []const ast.Item, event_path: *const ast.DottedPath) ?EventImpl {
        var ev_buf: [256]u8 = undefined;
        const ev_joined = joinedPath(&ev_buf, event_path);
        const has_default = hasAbstractDefaultSibling(scope, ev_joined);
        // `[abstract]` split present: proc `x` is the default's body, not
        // `x`'s — skip it here so the override impl (subflow/immediate)
        // binds. `x.default` itself still resolves to the same proc below.
        if (!has_default) {
            if (self.findCsProcIn(scope, event_path)) |proc| return .{ .proc = proc };
        }

        // Impls bind by TARGET, not declaration site — an override flow in
        // the main module implements `app/lib/hook:closed` while the event
        // decl lives inside `hook`'s module items. Scan the whole program;
        // each enclosing module supplies the qualifier context as the walk
        // descends, so an unqualified `foo` in module A still cannot bind
        // `B:foo`.
        if (findImmediateImplIn(self.items, event_path, self.main_module_name, self.main_module_name)) |ii| return .{ .immediate = ii };
        if (findSubflowImplIn(self.items, event_path, self.main_module_name, self.main_module_name)) |flow| return .{ .subflow = flow };

        for (scope) |*item| {
            if (item.* != .proc_decl) continue;
            const proc = &item.proc_decl;
            if (!pathsEqual(&proc.path, event_path)) continue;
            if (templateProcTargetsCs(proc)) return .{ .template_stub = proc };
        }

        return null;
    }

    /// Any `proc_decl` for `event_path` at all — language-blind. Used to
    /// tell "no impl exists" (emit the `undefined`-stub) apart from "an
    /// impl exists but not for cs" (refuse).
    fn anyProcDeclFor(scope: []const ast.Item, event_path: *const ast.DottedPath) bool {
        for (scope) |*item| {
            switch (item.*) {
                .proc_decl => |*p| {
                    var pb: [256]u8 = undefined;
                    var eb: [256]u8 = undefined;
                    if (std.mem.eql(u8, joinedPath(&pb, &p.path), joinedPath(&eb, event_path))) return true;
                },
                .module_decl => |*md| {
                    if (anyProcDeclFor(md.items, event_path)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// `x -> expr` impls bind by their TARGET path, not by where they're
    /// declared — a gated override in `test_lib/override.k` implements
    /// `input:calc` from inside a module item. Descend so module-scoped
    /// impls resolve the same as top-level ones — but the TARGET's
    /// module qualifier must still match the event's (pathsEqual ignores
    /// it): without that check `std.compiler:coordinate`'s own impl would
    /// bind a main-module `coordinate`.
    /// `x -> expr` impls bind by their TARGET path, not by where they're
    /// declared — a gated override in `test_lib/override.k` implements
    /// `input:calc` from inside a module item. Descend so module-scoped
    /// impls resolve the same as top-level ones — but the TARGET must
    /// qualify-match the event (pathsEqual ignores it): without that check
    /// `std.compiler:coordinate`'s own impl would bind a main-module
    /// `coordinate`. `home` is the enclosing module's logical name.
    fn findImmediateImplIn(
        scope: []const ast.Item,
        event_path: *const ast.DottedPath,
        home: []const u8,
        main_module: []const u8,
    ) ?*const ast.ImmediateImpl {
        for (scope) |*item| {
            switch (item.*) {
                .immediate_impl => |*ii| {
                    if (implTargetsEvent(event_path, &ii.event_path, home, main_module)) return ii;
                },
                .module_decl => |*md| {
                    if (findImmediateImplIn(md.items, event_path, md.logical_name, main_module)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }

    fn findSubflowImplIn(
        scope: []const ast.Item,
        event_path: *const ast.DottedPath,
        home: []const u8,
        main_module: []const u8,
    ) ?*const ast.Flow {
        for (scope) |*item| {
            switch (item.*) {
                .flow => |*flow| {
                    const impl_of = flow.impl_of orelse continue;
                    if (flow.impl_variant != null) continue;
                    if (implTargetsEvent(event_path, &impl_of, home, main_module)) return flow;
                },
                .module_decl => |*md| {
                    if (findSubflowImplIn(md.items, event_path, md.logical_name, main_module)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }

    /// Emit one EventDecl as `static class <name>_event { … handler … }`.
    fn emitEventDecl(self: *Emitter, ev: *const ast.EventDecl, scope: []const ast.Item) CsEmitError!void {
        const saved_locals = self.flow_locals.items.len;
        defer self.flow_locals.shrinkRetainingCapacity(saved_locals);
        const impl = self.findImplIn(scope, &ev.path) orelse blk: {
            // `[norun]`/`[expand]` events are AST data at their call sites —
            // no runtime body exists to emit (zig emits nothing). The class
            // still declares for typing; the handler is a dead stub.
            if (annotation_parser.hasPart(ev.annotations, "norun") or
                annotation_parser.hasPart(ev.annotations, "expand"))
                break :blk EventImpl{ .dead_stub = {} };
            // A bodiless tor — declared and dispatched, but no proc in ANY
            // language and no impl anywhere — zig emits `return undefined`.
            // `default` is the cs spelling of that shrug; a |zig-only proc
            // still refuses above this line via the impl search.
            if (!anyProcDeclFor(self.items, &ev.path) and
                findImmediateImplIn(self.items, &ev.path, self.main_module_name, self.main_module_name) == null and
                findSubflowImplIn(self.items, &ev.path, self.main_module_name, self.main_module_name) == null)
                break :blk EventImpl{ .empty_body = {} };
            log.err("[cs_emitter] tor '{s}' has no |cs proc, immediate, or subflow body\n", .{ev.path.segments[ev.path.segments.len - 1]});
            return CsEmitError.NoCsProcBody;
        };

        const name = ev.path.segments[ev.path.segments.len - 1];

        var has_effect = false;
        var has_terminal = false;
        for (ev.branches) |b| {
            if (b.kind == .effect) {
                has_effect = true;
            } else {
                has_terminal = true;
            }
        }

        // The envelope is the tor's contract, whoever writes the body:
        // handler returns `Output` for a branch tor, `<T>` for a bare
        // `-> T`, `object` when the decl cannot name a type — storage, not
        // binding (a `dynamic` return would let a consumer's member read
        // compile against a member that is not there and detonate at the
        // DLR call-site cache). That includes opaque |cs text — host-authored
        // impls must produce `new Output { tag = "done", … }` /
        // `return <T>;` and the compiler enforces it (an anonymous
        // `new { tag, done }` is now a type error, not a convention). Input
        // is typed regardless (zig passes `Input` to opaque procs too); the
        // wildcard-input shape stays dynamic because its members cannot be
        // named at decl time.
        const typed_input = !ev.input.is_wildcard;
        const input_cs: []const u8 = if (typed_input) "Input" else "dynamic";
        const output_cs: []const u8 = if (has_terminal)
            "Output"
        else if (ev.return_type) |rt|
            csType(rt)
        else
            "object";

        var name_buf: [256]u8 = undefined;
        const ev_name = self.eventClassName(&name_buf, ev);
        try self.writeFmt("  public static class {s}_event {{\n", .{ev_name});

        // The Input struct mirrors zig's `pub const Input` — declared fields
        // carry the declared types, `= <expr>` field defaults become C# field
        // initializers (the explicit parameterless ctor is what makes them
        // run, so `new Input { q = 41 }` still fills the rest).
        if (typed_input) {
            try self.write("    public struct Input {\n");
            var has_init = false;
            for (ev.input.fields) |field| {
                try self.writeFmt("      public {s} ", .{csInputFieldType(field)});
                try self.writeBinding(field.name);
                if (field.default) |dflt| {
                    try self.write(" = ");
                    try self.writeCsExpr(dflt);
                    has_init = true;
                }
                try self.write(";\n");
            }
            if (has_init) try self.write("      public Input() { }\n");
            try self.write("    }\n");
        }
        // Branch tors get the union analogue: `tag` discriminates, one member
        // per terminal branch carries the payload.
        if (has_terminal) {
            try self.write("    public struct Output {\n      public string tag;\n");
            for (ev.branches) |*b| {
                if (b.kind != .terminal) continue;
                try self.writeFmt("      public {s} ", .{try branchPayloadCsType(self.allocator, b)});
                try self.writeBinding(csPayloadName(b.name));
                try self.write(";\n");
            }
            try self.write("    }\n");
        }
        // Generated payload/resume types, nested in the class — impl text
        // (and transform-authored text) spells them bare the way it spells
        // `Output` bare; main_module scope reaches them as
        // `<ev>_event.<b>_payload`. A record payload is a real nominal
        // struct; a resume sum carries `tag` plus one member per arm.
        try self.emitNestedTypeDecls(ev);
        if (has_effect) {
            // IOps is the `comptime __H: type` analogue: each call site hands
            // a STRUCT implementing every arm, and `handler<H>` monomorphizes
            // per site. Arm members are METHODS — devirtualized and inlined
            // the way a `Handlers_N.fn` direct call is — not Func properties:
            // a delegate invoke cannot inline, and measured ~1.9ns/call over
            // the method path. The ONE exception is an optional resuming
            // arm: its presence is observable (`if (ask != null)`), and a
            // method has no "absent" spelling — it keeps a nullable Func.
            try self.write("    public interface IOps {\n");
            for (ev.branches) |*b| {
                if (b.kind != .effect) continue;
                if (optionalResumingArm(b)) {
                    // The nullable-Func exception keeps its surface but not
                    // its blindness: in/out spell the same types the method
                    // arms do, so a wrong-typed invoke fails compilation.
                    if (armIsPayloadless(b)) {
                        try self.writeFmt("      global::System.Func<{s}> ", .{try armReturnCsType(self.allocator, ev_name, b, false)});
                    } else {
                        try self.writeFmt("      global::System.Func<{s}, {s}> ", .{
                            try armParamCsType(self.allocator, ev_name, b, false),
                            try armReturnCsType(self.allocator, ev_name, b, false),
                        });
                    }
                    try self.writeBinding(b.name);
                    try self.write(" { get; }\n");
                } else {
                    try self.writeFmt("      {s} ", .{try armReturnCsType(self.allocator, ev_name, b, false)});
                    try self.writeBinding(b.name);
                    try self.write("(");
                    if (!armIsPayloadless(b)) {
                        try self.writeFmt("{s} __koru_arg", .{try armParamCsType(self.allocator, ev_name, b, false)});
                    }
                    try self.write(");\n");
                }
            }
            try self.write("    }\n");
            try self.writeFmt("    public static {s} handler<H>({s} {s}, H ops) where H : struct, IOps {{\n", .{ output_cs, input_cs, INPUT_PARAM });
            // Bare `tick()` spellings in impl bodies (opaque |cs text AND
            // generated subflow fires) resolve to these: an optional resuming
            // arm keeps its `var` alias (the Func IS the value, presence
            // included); a method arm gets a local-function shim forwarding
            // to `ops.<arm>(...)` — one extra static hop the JIT inlines
            // through, and the only way a bare name can reach a member.
            for (ev.branches) |*b| {
                if (b.kind != .effect) continue;
                try self.write("      ");
                if (optionalResumingArm(b)) {
                    try self.write("var ");
                    try self.writeBinding(b.name);
                    try self.write(" = ops.");
                    try self.writeBinding(b.name);
                    try self.write(";\n");
                } else {
                    try self.writeFmt("{s} ", .{try armReturnCsType(self.allocator, ev_name, b, false)});
                    try self.writeBinding(b.name);
                    try self.write("(");
                    if (!armIsPayloadless(b)) {
                        try self.writeFmt("{s} __koru_arg", .{try armParamCsType(self.allocator, ev_name, b, false)});
                    }
                    try self.write(") => ops.");
                    try self.writeBinding(b.name);
                    try self.write("(");
                    if (!armIsPayloadless(b)) try self.write("__koru_arg");
                    try self.write(");\n");
                }
            }
        } else {
            try self.writeFmt("    public static {s} handler({s} {s}) {{\n", .{ output_cs, input_cs, INPUT_PARAM });
        }

        // Bind input fields as locals: `var n = __koru_input.n;`. Every impl
        // kind reads its inputs by bare name, so this precedes all four
        // bodies. Under a typed Input the struct ctor already applied field
        // defaults; under the dynamic (wildcard) path `?? <dflt>` reads
        // through dynamic the way JS's `??` does.
        for (ev.input.fields) |field| {
            try self.write("      var ");
            try self.writeBinding(field.name);
            try self.writeFmt(" = {s}.", .{INPUT_PARAM});
            try self.writeBinding(field.name);
            if (!typed_input) {
                if (field.default) |dflt| {
                    try self.write(" ?? ");
                    try self.writeCsExpr(dflt);
                }
            }
            try self.write(";\n");
            try self.registerLocal(field.name);
        }

        const saved_impl_out = self.impl_out;
        defer self.impl_out = saved_impl_out;
        self.impl_out = switch (impl) {
            .immediate => |ii| if (ii.value.is_bare_return)
                (if (ev.return_type) |rt| ImplOut{ .bare = csType(rt) } else .dynamic)
            else if (has_terminal)
                ImplOut{ .tagged = "Output" }
            else
                .dynamic,
            // Host-authored bodies get the same typed contract — see the
            // envelope comment above. Produces inside a preamble/subflow's
            // generated continuations emit `new Output { … }` alongside.
            else => if (has_terminal)
                ImplOut{ .tagged = "Output" }
            else if (ev.return_type) |rt|
                ImplOut{ .bare = csType(rt) }
            else
                .dynamic,
        };

        switch (impl) {
            .template_stub => try self.writeFmt(
                "      throw new global::System.Exception(\"{s}: |template| proc is inlined at call sites and must never be called\");\n",
                .{name},
            ),
            .dead_stub => try self.writeFmt(
                "      throw new global::System.Exception(\"{s}: [expand] tor is inlined at call sites and must never be called\");\n",
                .{name},
            ),
            .empty_body => try self.write("      return default;\n"),
            .immediate => |ii| {
                const saved_ev = self.impl_event;
                self.impl_event = ev;
                defer self.impl_event = saved_ev;
                try self.emitBranchConstructorReturn(&ii.value, "      ");
            },
            .proc, .subflow => {
                // CELL HOIST — emit the body into a scratch buffer, then for
                // every module cell it names bare, materialize the cell as a
                // local for the body's duration and write back once at the
                // end. Legal because there are no variables: a cell's whole
                // accessor list is the program text, so no unnamed path can
                // read the stale static while the region runs. `return` in
                // the body or `=>` (a lambda can outlive the region and its
                // cell reads bind the static) both refuse the hoist outright.
                var scratch: std.ArrayList(u8) = .empty;
                defer scratch.deinit(self.allocator);
                {
                    const saved_buf = self.buf;
                    defer self.buf = saved_buf;
                    self.buf = &scratch;
                    switch (impl) {
                        .proc => |proc| {
                            // A [transform] tor has NO runtime body: the
                            // transform's output replaced every call site, so
                            // the decl-site handler is dead — splice a
                            // self-naming stub, not the proc's stage-C Zig
                            // source.
                            if (annotation_parser.hasPart(ev.annotations, "transform")) {
                                try self.writeFmt("      throw new global::System.Exception(\"{s}: [transform] tor is lowered at compile time and must never be called\");\n", .{name});
                            } else {
                                try self.emitReindented(proc.body.text, "      ");
                                // A trailing `//` line would swallow whatever
                                // lands next — terminate the last line.
                                try self.write("\n");
                            }
                        },
                        .subflow => |flow| try self.emitSubflowImplBody(ev, flow, "      "),
                        else => unreachable,
                    }
                }

                const body = scratch.items;
                var hoisted: std.ArrayList(Cell) = .empty;
                defer hoisted.deinit(self.allocator);
                if (std.mem.indexOf(u8, body, "return") == null and
                    std.mem.indexOf(u8, body, "=>") == null)
                {
                    for (self.cells.items) |cell| {
                        // An input binding already owns the name — a second
                        // `var` would collide (CS0128), not shadow.
                        var input_takes = false;
                        for (ev.input.fields) |field| {
                            var nb: [300]u8 = undefined;
                            if (std.mem.eql(u8, spelledName(&nb, field.name) orelse field.name, cell.name)) {
                                input_takes = true;
                                break;
                            }
                        }
                        if (input_takes) continue;
                        if (try self.cellMayHoist(body, cell)) {
                            try hoisted.append(self.allocator, cell);
                        }
                    }
                }
                for (hoisted.items) |cell| {
                    try self.writeFmt("      var {s} = {s}.{s};\n", .{ cell.name, cell.owner, cell.name });
                }
                try self.write(body);
                for (hoisted.items) |cell| {
                    try self.writeFmt("      {s}.{s} = {s};\n", .{ cell.owner, cell.name, cell.name });
                }
                const is_transform_stub = std.meta.activeTag(impl) == .proc and
                    annotation_parser.hasPart(ev.annotations, "transform");
                if (!is_transform_stub) try self.emitImplTail();
                try self.write("\n");
            },
        }
        try self.write("    }\n  }\n");
    }

    /// The generated types nested inside an `<ev>_event` class:
    ///
    ///   `<b>_payload` — one struct per named-record payload, on terminal
    ///     branches AND effect arms. `dynamic`/`object`/anonymous-object
    ///     spellings all fail the same test: they cannot be NAMED in a
    ///     signature, so a record arm param or Output member could only
    ///     ever be typed by giving the record a nominal type. Field types
    ///     come from csType — unknown shapes stay `dynamic` because the
    ///     field's whole job is being membered through.
    ///   `<b>_resume` — the resume-sum for `! arm | r1 T1 | r2 T2`: `tag`
    ///     discriminates, one member per arm carries its declared type
    ///     (`object` when the arm declares none — storage, not binding).
    ///
    /// Both spellings are what transform-authored HostShape text and the
    /// emitter's own constructors reference; decl and use agree by sharing
    /// payloadStructNameBuf / resumeStructRef.
    fn emitNestedTypeDecls(self: *Emitter, ev: *const ast.EventDecl) CsEmitError!void {
        for (ev.branches) |*b| {
            if (payloadIsRecord(b)) {
                var pnb: [300]u8 = undefined;
                try self.writeFmt("    public struct {s} {{\n", .{payloadStructNameBuf(&pnb, b.name)});
                for (b.payload.fields) |f| {
                    try self.writeFmt("      public {s} ", .{csType(f.type)});
                    try self.writeBinding(f.name);
                    try self.write(";\n");
                }
                try self.write("    }\n");
            }
            if (b.kind != .effect) continue;
            if (b.resume_arms) |arms| {
                var rnb: [300]u8 = undefined;
                const lowered = Emitter.lowerIdentBuf(&rnb, b.name);
                try self.writeFmt("    public struct {s}_resume {{\n      public string tag;\n", .{lowered});
                for (arms) |ra| {
                    const mt = if (ra.type) |rt| csType(rt) else "object";
                    try self.writeFmt("      public {s} ", .{mt});
                    try self.writeBinding(ra.name);
                    try self.write(";\n");
                }
                try self.write("    }\n");
            }
        }
    }

    /// The handler-scope fall-through for impl bodies the emitter cannot
    /// prove return on every path — pasted |cs text and subflow
    /// continuations with conditional produces. `return default;` is the one
    /// spelling that is always legal here: `null` under a dynamic signature,
    /// the zero value under Output or a bare <T> — the arm-tail rule, one
    /// scope up. Dead after a proven return, and WarningLevel is 0.
    fn emitImplTail(self: *Emitter) CsEmitError!void {
        try self.write("\n      return default;\n");
    }

    /// Emit `return <value>;` for a BranchConstructor — the shared shape
    /// behind an immediate impl (`greet -> "hi"`, `step => continue`) and a
    /// subflow arm that produces an outcome. The C# spelling reads back
    /// through `dynamic` exactly as the JS tagged object does:
    ///
    ///   `-> expr`          → `return <expr>;`                    (no tag)
    ///   `=> b`             → `return new { tag = "b" };`
    ///   `=> b v`           → `return new { tag = "b", b = v };`
    ///   `=> b { f: v, … }` → `return new { tag = "b", b = new { f = v, … } };`
    ///
    /// Payload member names go through writeBinding (kebab → underscore,
    /// reserved → `@name`); the tag string stays raw. Producer and reader
    /// agree by construction.
    fn emitBranchConstructorReturn(self: *Emitter, bc: *const ast.BranchConstructor, indent: []const u8) CsEmitError!void {
        if (bc.is_bare_return) {
            switch (self.impl_out) {
                // The impl's own `-> T` produce under a typed return:
                // `return (long)(x + 1);`. An arm's resume produce stays on
                // the dynamic path — its value is not the tor's Output.
                .bare => |t| {
                    if (bc.plain_value) |pv| {
                        try self.writeFmt("{s}return ({s})(", .{ indent, t });
                        try self.writeProduceValue(pv);
                        try self.write(");\n");
                    } else {
                        try self.writeFmt("{s}return default({s});\n", .{ indent, t });
                    }
                },
                else => {
                    try self.writeFmt("{s}return ", .{indent});
                    if (bc.plain_value) |pv| {
                        try self.writeProduceValue(pv);
                    } else {
                        try self.write("null");
                    }
                    try self.write(";\n");
                },
            }
            return;
        }

        // `tagged` carries the ENVELOPE name — "Output" inside the event
        // class, the qualified `<ev>_event.<arm>_resume` in an arm body.
        // Everything else produces anonymously the way it always has.
        const env: []const u8 = switch (self.impl_out) {
            .tagged => |e| e,
            else => "",
        };
        try self.writeFmt("{s}return new {s}{{ tag = \"{s}\"", .{
            indent,
            if (env.len > 0) try std.fmt.allocPrint(self.allocator, "{s} ", .{env}) else "",
            bc.branch_name,
        });
        if (bc.plain_value) |pv| {
            try self.write(", ");
            try self.writeBinding(csPayloadName(bc.branch_name));
            try self.write(" = ");
            try self.writeProduceValue(pv);
        } else if (bc.fields.len > 0) {
            try self.write(", ");
            try self.writeBinding(csPayloadName(bc.branch_name));
            // A record field-set on a branch whose decl carries named
            // payload fields constructs the generated `<b>_payload`
            // struct — `b = new b_payload { f = v, … }`. Anything else
            // stays the anonymous object (a `dynamic`/wildcard member
            // still answers there; a scalar member refuses at C# compile
            // time, which is the honest outcome).
            const decl_b: ?*const ast.Branch = if (self.impl_event) |ie| blk: {
                for (ie.branches) |*tb| {
                    if (tb.kind == .terminal and std.mem.eql(u8, tb.name, bc.branch_name)) break :blk tb;
                }
                break :blk null;
            } else null;
            const rec = if (decl_b) |tb| payloadIsRecord(tb) else false;
            if (rec) {
                var pnb: [300]u8 = undefined;
                try self.writeFmt(" = new {s} {{ ", .{payloadStructNameBuf(&pnb, bc.branch_name)});
            } else {
                try self.write(" = new { ");
            }
            for (bc.fields, 0..) |field, k| {
                if (k > 0) try self.write(", ");
                try self.writeBinding(field.name);
                try self.write(" = ");
                try self.writeCsExpr(if (field.expression_str) |e| e else field.type);
            }
            try self.write(" }");
        }
        try self.write(" };\n");
    }

    /// A produce value is an expression or a Koru STRUCT LITERAL in braces
    /// (`-> { final.sum, final.max }`). The braced form re-emits as a C#
    /// anonymous object under the pun law; plain-value braces unwrap.
    /// `struct_literal`'s predicates decide which — the same law the parser
    /// and both other emitters read.
    fn writeProduceValue(self: *Emitter, value: []const u8) CsEmitError!void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
            return self.writeCsExpr(value);
        }
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        if (inner.len > 0 and struct_literal.isBracedPlainExpression(trimmed)) {
            return self.writeCsExpr(inner);
        }
        const fields = struct_literal.parseFields(self.allocator, trimmed) catch
            return self.writeCsExpr(value);
        if (fields.len == 0) return self.writeCsExpr(value);
        try self.write("new { ");
        for (fields, 0..) |f, i| {
            if (i > 0) try self.write(", ");
            try self.writeBinding(f.name);
            try self.write(" = ");
            try self.writeCsExpr(f.value);
        }
        try self.write(" }");
    }

    /// Emit the body of a SUBFLOW implementation — a flow whose `impl_of`
    /// names the event being emitted. The body is an ordinary dispatch; the
    /// only difference is that it sits inside a handler method, which is what
    /// turns a branch-constructor arm into a `return`.
    fn emitSubflowImplBody(self: *Emitter, event: *const ast.EventDecl, flow: *const ast.Flow, indent: []const u8) CsEmitError!void {
        const saved = self.impl_event;
        self.impl_event = event;
        defer self.impl_event = saved;

        if (flow.preamble_code != null and !preambleThenCall(flow.inv())) {
            try self.emitPreamble(flow.preamble_code, indent);
            try self.emitPreambleContinuations(flow.body.continuations, indent);
            return;
        }
        try self.emitPreamble(flow.preamble_code, indent);

        if (flow.inline_body) |raw| {
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripInlineStmtMarker(raw), flow.body.continuations, indent, &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(flow.body.continuations, consumed, indent);
            return;
        }
        if (flow.pre_label) |label| {
            try self.emitLabelFoldAt(flow.inv(), flow.body.continuations, label, indent);
            return;
        }
        try self.emitInvocationWithContinuations(flow.inv(), flow.body.continuations, indent);
    }

    /// Write a KORU expression as C# — through codegen_utils's `.cs` arm:
    /// `and`/`or` → `&&`/`||`, `.len` → `.Length`, `++` → `+`, unknown
    /// `@builtins` refuse.
    pub fn writeCsExpr(self: *Emitter, expr: []const u8) CsEmitError!void {
        try self.writeLowered(expr, .koru_expr);
    }

    /// Write HOST text (a rendered template body) — the `.host_text` mode:
    /// `++` stays (a genuine increment in C# text), operators and builtins
    /// still lower.
    fn writeHostText(self: *Emitter, text: []const u8) CsEmitError!void {
        try self.writeLowered(text, .host_text);
    }

    const LowerMode = codegen_utils.ExprMode;

    /// The emitter's door onto the shared lowering — turns a refused
    /// operation into this emitter's own diagnostic.
    fn writeLowered(self: *Emitter, text: []const u8, mode: LowerMode) CsEmitError!void {
        var diag = codegen_utils.LowerDiag{};
        const lowered = codegen_utils.lowerKoruExpr(self.allocator, text, .cs, mode, &diag) catch |err| switch (err) {
            error.OutOfMemory => return CsEmitError.OutOfMemory,
            error.UnsupportedBuiltin => {
                log.err("[cs_emitter] host builtin '@{s}' has no C# lowering\n", .{diag.unknown_builtin});
                log.err("[cs_emitter]   in: {s}\n", .{text[0..@min(text.len, 400)]});
                return CsEmitError.UnsupportedConstruct;
            },
        };
        defer self.allocator.free(lowered);
        try self.buf.appendSlice(self.allocator, lowered);
    }

    /// Where an event declaration was found, paired with the item list its
    /// implementation resolves against.
    const DeclSite = struct {
        decl: *const ast.EventDecl,
        scope: []const ast.Item,
    };

    /// Bound for the implementability walk — the event graph is cyclic, so
    /// the walk needs a stop. Same cap as the JS emitter.
    const IMPL_WALK_DEPTH: u8 = 32;

    fn findDeclSiteIn(self: *Emitter, scope: []const ast.Item, path: *const ast.DottedPath, current_module: ?[]const u8) ?DeclSite {
        for (scope) |*item| {
            switch (item.*) {
                .event_decl => |*e| {
                    if (pathsEqualWithModule(&e.path, path, current_module, self.main_module_name)) {
                        return .{ .decl = e, .scope = scope };
                    }
                },
                .module_decl => |*m| {
                    if (self.findDeclSiteIn(m.items, path, m.logical_name)) |found| return found;
                },
                else => {},
            }
        }
        return null;
    }

    /// Is this event's behaviour reachable ON THE CS TARGET — does every leaf
    /// its body reaches have a cs body? The transitive predicate that keeps
    /// unported stdlib events out of the output without skipping anything a
    /// call site can dispatch to.
    fn eventIsCsImplementable(self: *Emitter, site: DeclSite, depth: u8) bool {
        if (depth == 0) return false;
        const impl = self.findImplIn(site.scope, &site.decl.path) orelse return false;
        return switch (impl) {
            .proc, .template_stub, .dead_stub, .empty_body => true,
            .immediate => true,
            .subflow => |flow| self.subflowIsCsImplementable(site.decl, flow, depth - 1),
        };
    }

    fn subflowIsCsImplementable(self: *Emitter, event: *const ast.EventDecl, flow: *const ast.Flow, depth: u8) bool {
        if (flow.inline_body != null) return true;
        if (!self.invocationIsCsImplementable(event, flow.inv(), depth)) return false;
        return self.continuationsAreCsImplementable(event, flow.body.continuations, depth);
    }

    fn continuationsAreCsImplementable(self: *Emitter, event: *const ast.EventDecl, conts: []const ast.Continuation, depth: u8) bool {
        for (conts) |*cont| {
            if (cont.node) |*node| {
                switch (node.*) {
                    .invocation => |*inv| {
                        if (!self.invocationIsCsImplementable(event, inv, depth)) return false;
                    },
                    .label_with_invocation => |*lwi| {
                        if (!lwi.is_declaration) return false;
                        if (!self.invocationIsCsImplementable(event, &lwi.invocation, depth)) return false;
                    },
                    .terminal, .branch_constructor, .expression, .assignment, .label_jump, .label_apply, .metatype_binding => {},
                    .inline_code => |text| if (!self.csHostTextLowers(text)) return false,
                    else => return false,
                }
            }
            if (!self.continuationsAreCsImplementable(event, cont.continuations, depth)) return false;
        }
        return true;
    }

    /// Trial-lower `.inline_code` text the way `emitPreamble` will — a
    /// lowering failure means this leaf cannot emit.
    fn csHostTextLowers(self: *Emitter, text: []const u8) bool {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var diag = codegen_utils.LowerDiag{};
            const lowered = codegen_utils.lowerKoruExpr(self.allocator, trimmed, .cs, .host_text, &diag) catch return false;
            self.allocator.free(lowered);
        }
        return true;
    }

    fn invocationIsCsImplementable(self: *Emitter, impl_event: *const ast.EventDecl, inv: *const ast.Invocation, depth: u8) bool {
        if (inv.inline_body != null) return true;
        if (findEffectArm(impl_event, &inv.path) != null) return true;
        const site = self.findDeclSiteIn(self.items, &inv.path, null) orelse return false;
        return self.eventIsCsImplementable(site, depth);
    }

    /// Record `event`'s lowered class key as taken.
    fn claimEventKey(self: *Emitter, keys: *EmittedKeys, event: *const ast.EventDecl) CsEmitError!void {
        var buf: [256]u8 = undefined;
        const key = self.eventClassName(&buf, event);
        if (keys.contains(key)) return;
        try keys.put(try self.allocator.dupe(u8, key), {});
    }

    /// Emit the events of an imported module. Three outcomes, same as the JS
    /// emitter: implementable → ordinary handler; not implementable + not
    /// reached → absent in silence (most of the stdlib); not implementable
    /// but REACHED → a handler that throws, naming itself and its module —
    /// `NullReferenceException` at the call frame would say neither.
    fn emitModuleEventDecls(
        self: *Emitter,
        module: *const ast.ModuleDecl,
        reached: *const ReachedEvents,
        emitted_keys: *EmittedKeys,
    ) CsEmitError!void {
        for (module.items) |*item| {
            switch (item.*) {
                .event_decl => |*event| {
                    if (annotation_parser.hasPart(event.annotations, "comptime")) continue;
                    var name_buf: [256]u8 = undefined;
                    const key = self.eventClassName(&name_buf, event);
                    if (emitted_keys.contains(key)) continue;
                    const site = DeclSite{ .decl = event, .scope = module.items };
                    if (self.eventIsCsImplementable(site, IMPL_WALK_DEPTH)) {
                        try self.emitEventDecl(event, module.items);
                        try self.claimEventKey(emitted_keys, event);
                        continue;
                    }
                    if (!reached.contains(event)) continue;
                    // A body-less event with exactly one terminal branch
                    // produces it unconditionally — the injected
                    // koru:start / koru:end meta-events land here.
                    if (soleTerminalBranch(event)) |branch| {
                        try self.emitSoleBranchEvent(event, branch);
                    } else {
                        try self.emitUnlowerableEventRefusal(event, module);
                    }
                    try self.claimEventKey(emitted_keys, event);
                },
                .module_decl => |*nested| try self.emitModuleEventDecls(nested, reached, emitted_keys),
                else => {},
            }
        }
    }

    /// The branch an impl-less event produces when it has exactly one —
    /// there is no other outcome it could spell. Multi-branch or
    /// effect-bearing events return null: genuinely unlowerable.
    fn soleTerminalBranch(event: *const ast.EventDecl) ?*const ast.Branch {
        var found: ?*const ast.Branch = null;
        for (event.branches) |*b| {
            if (b.kind == .effect) return null;
            if (found != null) return null;
            found = b;
        }
        return found;
    }

    /// `handler` for a body-less single-branch event — returns that branch,
    /// the only output the event can produce.
    fn emitSoleBranchEvent(self: *Emitter, event: *const ast.EventDecl, branch: *const ast.Branch) CsEmitError!void {
        var name_buf: [256]u8 = undefined;
        try self.writeFmt("  public static class {s}_event {{\n", .{self.eventClassName(&name_buf, event)});
        try self.write("    public struct Input {\n");
        for (event.input.fields) |field| {
            try self.writeFmt("      public {s} ", .{csInputFieldType(field)});
            try self.writeBinding(field.name);
            try self.write(";\n");
        }
        try self.write("    }\n    public struct Output {\n      public string tag;\n      public ");
        try self.write(try branchPayloadCsType(self.allocator, branch));
        try self.write(" ");
        try self.writeBinding(csPayloadName(branch.name));
        try self.write(";\n    }\n");
        try self.emitNestedTypeDecls(event);
        try self.writeFmt("    public static Output handler(Input {s}) => new Output {{ tag = \"{s}\" }};\n  }}\n", .{ INPUT_PARAM, branch.name });
    }

    /// A handler for an event this target cannot lower, whose whole body is
    /// the diagnostic — the exception that arrives AT the call frame and says
    /// which event and why.
    fn emitUnlowerableEventRefusal(self: *Emitter, event: *const ast.EventDecl, module: *const ast.ModuleDecl) CsEmitError!void {
        var name_buf: [256]u8 = undefined;
        const name = event.path.segments[event.path.segments.len - 1];
        try self.writeFmt("  public static class {s}_event {{\n", .{self.eventClassName(&name_buf, event)});
        // Call sites construct `new <ev>_event.Input { … }` — the members
        // must exist for the program to build, or the refusal arrives at
        // compile time instead of the call frame it was written for.
        try self.write("    public struct Input {\n");
        for (event.input.fields) |field| {
            try self.writeFmt("      public {s} ", .{csInputFieldType(field)});
            try self.writeBinding(field.name);
            try self.write(";\n");
        }
        try self.write("    }\n");
        // Wildcard inputs keep the dynamic param — their call sites hand an
        // anonymous object no `Input` member list can name.
        try self.writeFmt("    public static object handler({s} {s}) {{\n", .{
            if (event.input.is_wildcard) "dynamic" else "Input",
            INPUT_PARAM,
        });
        try self.writeFmt(
            "      throw new global::System.Exception(\"{s}:{s} has no C# implementation — its body resolves only to a non-cs target (|zig / [comptime]), directly or through a callee\");\n",
            .{ module.logical_name, name },
        );
        try self.write("    }\n  }\n");
    }

    /// The event decls the emitted program actually reaches, seeded from the
    /// flows Phase 2 will emit — the same filter, so the two cannot disagree.
    fn collectReachedEvents(self: *Emitter, reached: *ReachedEvents) CsEmitError!void {
        for (self.items) |*item| {
            if (item.* != .flow) continue;
            const flow = &item.flow;
            if (flow.impl_of != null) continue;
            if (self.isDeclarationFlow(flow)) continue;
            if (flow.inv().path.module_qualifier) |mq| {
                if (std.mem.eql(u8, mq, "koru")) {
                    const leaf = flow.inv().path.segments[flow.inv().path.segments.len - 1];
                    if (!std.mem.eql(u8, leaf, "start") and !std.mem.eql(u8, leaf, "end")) continue;
                }
            }
            if (self.flowIsNorunSite(flow)) continue;
            try self.reachFlow(null, flow, reached, IMPL_WALK_DEPTH);
        }
        for (self.items) |*item| {
            if (item.* != .module_decl) continue;
            try self.reachModuleFlows(&item.module_decl, reached);
        }
    }

    /// Imported-module runtime flows are real dispatch sites too — their
    /// callees must count as reached or Phase 1b would skip (or stub) an
    /// event a module flow is about to call.
    fn reachModuleFlows(self: *Emitter, module: *const ast.ModuleDecl, reached: *ReachedEvents) CsEmitError!void {
        for (module.items) |*item| {
            switch (item.*) {
                .module_decl => |*nested| try self.reachModuleFlows(nested, reached),
                .flow => |*flow| {
                    if (flow.impl_of != null) continue;
                    if (self.isDeclarationFlow(flow)) continue;
                    if (flow.inv().path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, "koru")) continue;
                    }
                    if (self.flowIsNorunSite(flow)) continue;
                    try self.reachFlow(null, flow, reached, IMPL_WALK_DEPTH);
                },
                else => {},
            }
        }
    }

    fn reachFlow(self: *Emitter, impl_event: ?*const ast.EventDecl, flow: *const ast.Flow, reached: *ReachedEvents, depth: u8) CsEmitError!void {
        if (depth == 0) return;
        try self.reachInvocation(impl_event, flow.inv(), reached, depth);
        try self.reachContinuations(impl_event, flow.body.continuations, reached, depth);
    }

    fn reachContinuations(self: *Emitter, impl_event: ?*const ast.EventDecl, conts: []const ast.Continuation, reached: *ReachedEvents, depth: u8) CsEmitError!void {
        if (depth == 0) return;
        for (conts) |*cont| {
            if (cont.node) |*node| switch (node.*) {
                .invocation => |*inv| try self.reachInvocation(impl_event, inv, reached, depth),
                .label_with_invocation => |*lwi| try self.reachInvocation(impl_event, &lwi.invocation, reached, depth),
                else => {},
            };
            try self.reachContinuations(impl_event, cont.continuations, reached, depth);
        }
    }

    fn reachInvocation(self: *Emitter, impl_event: ?*const ast.EventDecl, inv: *const ast.Invocation, reached: *ReachedEvents, depth: u8) CsEmitError!void {
        if (depth == 0) return;
        if (impl_event) |ie| {
            if (findEffectArm(ie, &inv.path) != null) return;
        }
        // A call site a comptime transform already rendered to host text is
        // spliced, not dispatched — the callee is NOT reached.
        if (inv.inline_body != null) return;
        const site = self.findDeclSiteIn(self.items, &inv.path, null) orelse return;
        if ((try reached.getOrPut(site.decl)).found_existing) return;
        const impl = self.findImplIn(site.scope, &site.decl.path) orelse return;
        switch (impl) {
            .subflow => |flow| {
                if (flow.inline_body != null) return;
                try self.reachFlow(site.decl, flow, reached, depth - 1);
            },
            else => {},
        }
    }

    /// Emit an imported module's runtime flows as `flowN()` methods on
    /// main_module — a module's top-level flows are its initialization, and
    /// the flat `<module>_<event>_event` namespace already puts their
    /// callees in scope. Recurses into nested module decls; records each
    /// emitted number so Main can call them in traversal order.
    fn emitModuleRuntimeFlows(
        self: *Emitter,
        module: *const ast.ModuleDecl,
        flow_num: *usize,
        module_flow_nums: *std.ArrayList(usize),
    ) CsEmitError!void {
        for (module.items) |*item| {
            switch (item.*) {
                .module_decl => |*nested| try self.emitModuleRuntimeFlows(nested, flow_num, module_flow_nums),
                .flow => |*flow| {
                    if (flow.impl_of != null) continue;
                    if (self.isDeclarationFlow(flow)) continue;
                    if (flow.inv().path.module_qualifier) |mq| {
                        if (std.mem.eql(u8, mq, "koru")) continue;
                    }
                    if (self.flowIsNorunSite(flow)) continue;
                    try self.emitFlow(flow, flow_num.*);
                    try module_flow_nums.append(self.allocator, flow_num.*);
                    flow_num.* += 1;
                },
                else => {},
            }
        }
    }

    /// Emit a top-level flow as `flowN()`.
    fn emitFlow(self: *Emitter, flow: *const ast.Flow, flow_num: usize) CsEmitError!void {
        const saved_locals = self.flow_locals.items.len;
        defer self.flow_locals.shrinkRetainingCapacity(saved_locals);
        try self.writeFmt("  public static void flow{d}() {{\n", .{flow_num});
        // PREAMBLE REPLACES THE CALL — a dissolving transform hangs the real
        // declaration on `preamble_code`; emitting the handler call as well
        // would call a comptime event that has no runtime body.
        if (flow.preamble_code != null and !preambleThenCall(flow.inv())) {
            try self.emitPreamble(flow.preamble_code, "    ");
            try self.emitPreambleContinuations(flow.body.continuations, "    ");
            try self.write("  }\n");
            return;
        }
        try self.emitPreamble(flow.preamble_code, "    ");
        if (flow.inline_body) |inline_body_raw| {
            const stripped = stripInlineStmtMarker(inline_body_raw);
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripped, flow.body.continuations, "    ", &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(flow.body.continuations, consumed, "    ");
        } else if (flow.pre_label) |label| {
            try self.emitLabelFoldAt(flow.inv(), flow.body.continuations, label, "    ");
        } else {
            try self.emitInvocationWithContinuations(flow.inv(), flow.body.continuations, "    ");
        }
        try self.write("  }\n");
    }

    /// `<branch> <payload>` expression-produce — the cs twin of zig's
    /// `emitBranchProduce` (emitter_helpers). A continuation arm's
    /// `.expression` node carrying `finished d` is the parser's spelling of
    /// `-> finished d`: the head word is the branch, the rest its payload.
    /// Fires only when the enclosing impl event declares the head as a
    /// terminal branch — everything else is an ordinary expression return.
    /// Returns true when it emitted.
    fn emitProduceExpr(self: *Emitter, expr: []const u8, indent: []const u8) CsEmitError!bool {
        const decl = self.impl_event orelse return false;
        if (decl.branches.len == 0) return false;
        const trimmed = std.mem.trim(u8, expr, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "_")) return false;

        var split: usize = 0;
        while (split < trimmed.len and trimmed[split] != ' ' and trimmed[split] != '\t') : (split += 1) {}
        const head = trimmed[0..split];
        const payload = std.mem.trim(u8, trimmed[split..], " \t");

        const branch = for (decl.branches) |*b| {
            if (b.kind != .terminal) continue;
            if (std.mem.eql(u8, b.name, head)) break b;
        } else return false;

        const env: []const u8 = switch (self.impl_out) {
            .tagged => |e| e,
            else => "",
        };
        const env_pre = if (env.len > 0) try std.fmt.allocPrint(self.allocator, "{s} ", .{env}) else "";
        if (branch.payload.fields.len == 0 and !branch.payload.is_wildcard) {
            if (payload.len != 0) return false; // shape mismatch — let the checker speak
            try self.writeFmt("{s}return new {s}{{ tag = \"{s}\" }};\n", .{ indent, env_pre, head });
            return true;
        }
        if (payload.len == 0) return false;

        try self.writeFmt("{s}return new {s}{{ tag = \"{s}\", ", .{ indent, env_pre, head });
        try self.writeBinding(csPayloadName(head));
        try self.write(" = ");
        // A record-brace payload on a branch whose decl carries named
        // fields constructs the generated `<b>_payload` struct — the same
        // ruling emitBranchConstructorReturn makes for `-> b {f: v}`.
        // `dynamic`/wildcard members still take the anonymous object.
        if (payload[0] == '{' and payloadIsRecord(branch)) {
            try self.writeRecordPayloadInit(head, payload);
        } else {
            try self.writeProduceValue(payload);
        }
        try self.write(" };\n");
        return true;
    }

    /// `{ k: v, … }` produce text → `new <b>_payload { k = v, … }` — kebab
    /// field names mangle through writeBinding, values lower through
    /// writeCsExpr. Top-level comma split; nested braces/brackets/parens and
    /// string literals don't split.
    fn writeRecordPayloadInit(self: *Emitter, branch_name: []const u8, payload: []const u8) CsEmitError!void {
        var inner = std.mem.trim(u8, payload, " \t");
        if (inner.len >= 2 and inner[0] == '{' and inner[inner.len - 1] == '}') {
            inner = std.mem.trim(u8, inner[1 .. inner.len - 1], " \t");
        }
        var pnb: [300]u8 = undefined;
        try self.writeFmt("new {s} {{ ", .{payloadStructNameBuf(&pnb, branch_name)});
        var pos: usize = 0;
        var field_i: usize = 0;
        while (pos <= inner.len) {
            var depth: usize = 0;
            var quote: ?u8 = null;
            var end = pos;
            while (end < inner.len) : (end += 1) {
                const c = inner[end];
                if (quote) |q| {
                    if (c == '\\') end += 1 else if (c == q) quote = null;
                    continue;
                }
                switch (c) {
                    '"', '\'' => quote = c,
                    '{', '(', '[' => depth += 1,
                    '}', ')', ']' => depth -|= 1,
                    ',' => if (depth == 0) break,
                    else => {},
                }
            }
            const part = std.mem.trim(u8, inner[pos..end], " \t");
            pos = end + 1;
            if (part.len == 0) continue;
            if (field_i > 0) try self.write(", ");
            field_i += 1;
            const colon = std.mem.indexOfScalar(u8, part, ':') orelse part.len;
            const fname = std.mem.trim(u8, part[0..colon], " \t");
            const fval = std.mem.trim(u8, part[@min(colon + 1, part.len)..], " \t");
            if (fname.len == 0) continue;
            try self.writeBinding(fname);
            try self.write(" = ");
            // No colon is the pun `{x}` — the value is the binding itself.
            try self.writeCsExpr(if (colon < part.len) fval else fname);
        }
        try self.write(" }");
    }

    /// Emit a flow's `preamble_code` — host DECLARATION text a comptime
    /// transform hung on the flow to run ahead of its dispatch. Authored in
    /// the BUILD language by the transform itself, so it goes through
    /// writeHostText only.
    fn emitPreamble(self: *Emitter, preamble: ?[]const u8, indent: []const u8) CsEmitError!void {
        const text = preamble orelse return;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |line| {
            const line_trimmed = std.mem.trim(u8, line, " \t\r");
            if (line_trimmed.len == 0) continue;
            try self.write(indent);
            try self.writeHostText(line_trimmed);
            try self.write("\n");
        }
    }

    /// Emit the continuations of a flow whose `preamble_code` REPLACED its
    /// invocation — body-only, in source order (no result value, no tag to
    /// dispatch on).
    fn emitPreambleContinuations(
        self: *Emitter,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) CsEmitError!void {
        for (continuations) |*cont| {
            try self.emitInlineContinuationBody(cont, indent);
        }
    }

    /// Emit a rendered template body (e.g. `~if`'s `if (cond) { … } else { …
    /// }`), resolving the splice markers template_processor mints:
    ///
    ///   - `__koru_continue_N`             — a terminal continuation hand-off.
    ///   - `__koru_inline[_scoped]_N(arg)` — an EFFECT-handler splice — the
    ///                                       vertical refuses these (effects
    ///                                       are unmodelled).
    ///
    /// Scan by marker POSITION: earliest remaining marker, verbatim text
    /// before it through writeHostText, resolve, repeat.
    fn emitInlineBodyResolvingContinuations(
        self: *Emitter,
        body: []const u8,
        continuations: []const ast.Continuation,
        indent: []const u8,
        consumed: ?*u64,
    ) CsEmitError!void {
        if (consumed) |c| {
            if (continuations.len > 64) c.* = ~@as(u64, 0);
        }
        const body_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(body_indent);

        const SPLICE_PREFIX = "__koru_inline_";
        const CONTINUE_PREFIX = "__koru_continue_";
        const SCOPED_INFIX = "scoped_";
        const BARE_INFIX = "bare_";

        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        var pos: usize = 0;
        while (true) {
            const splice_at = std.mem.indexOfPos(u8, trimmed, pos, SPLICE_PREFIX);
            const continue_at = std.mem.indexOfPos(u8, trimmed, pos, CONTINUE_PREFIX);
            var m: usize = undefined;
            var is_continue: bool = undefined;
            if (splice_at) |s| {
                if (continue_at) |r| {
                    is_continue = r < s;
                    m = if (is_continue) r else s;
                } else {
                    is_continue = false;
                    m = s;
                }
            } else if (continue_at) |r| {
                is_continue = true;
                m = r;
            } else {
                break;
            }

            try self.writeHostText(trimmed[pos..m]);

            if (is_continue) {
                var i = m + CONTINUE_PREFIX.len;
                const is_bare = std.mem.startsWith(u8, trimmed[i..], BARE_INFIX);
                if (is_bare) i += BARE_INFIX.len;
                const idx = codegen_utils.scanDecimalIndex(trimmed, &i) orelse {
                    log.err("[cs_emitter] malformed __koru_continue marker\n", .{});
                    return CsEmitError.UnsupportedConstruct;
                };
                if (idx >= continuations.len) {
                    log.err("[cs_emitter] __koru_continue_{d} has no matching continuation (have {d})\n", .{ idx, continuations.len });
                    return CsEmitError.UnsupportedConstruct;
                }
                if (consumed) |c| {
                    if (idx < 64) c.* |= @as(u64, 1) << @intCast(idx);
                }
                const cont = &continuations[idx];
                const guarded = !is_bare and cont.condition != null;
                try self.write("{ ");
                if (guarded) {
                    try self.write("if (");
                    try self.writeCsExpr(cont.condition.?);
                    try self.write(") { ");
                }
                try self.emitInlineContinuationBody(cont, body_indent);
                if (guarded) try self.write(" }");
                try self.write(" }");
                pos = i;
                continue;
            }

            // EFFECT splice — `__koru_inline[_scoped]_N(arg)`: bind `arg` to
            // the handler's parameter, then run the handler body in a block.
            // The optional `scoped_` infix carries no emission meaning (scope
            // is an obligation-checker concept, already stamped on the
            // continuation), so skip past it to the digits — same ruling as
            // the JS and Zig emitters.
            var i = m + SPLICE_PREFIX.len;
            if (std.mem.startsWith(u8, trimmed[i..], SCOPED_INFIX)) i += SCOPED_INFIX.len;
            const maybe_idx = codegen_utils.scanDecimalIndex(trimmed, &i);

            // Read the `(arg)` immediately following (balanced parens).
            var arg: []const u8 = "";
            if (maybe_idx != null and i < trimmed.len and trimmed[i] == '(') {
                const arg_start = i + 1;
                var depth: usize = 1;
                var j = arg_start;
                while (j < trimmed.len and depth > 0) : (j += 1) {
                    if (trimmed[j] == '(') {
                        depth += 1;
                    } else if (trimmed[j] == ')') {
                        depth -= 1;
                    }
                }
                arg = std.mem.trim(u8, trimmed[arg_start .. j - 1], " \t");
                i = j; // past the closing ')'
                // The marker resolves to a block statement; swallow a trailing `;`
                // the template wrote in call-statement shape (`marker(arg);`).
                if (i < trimmed.len and trimmed[i] == ';') i += 1;
            }

            const idx = maybe_idx orelse {
                log.err("[cs_emitter] malformed __koru_inline marker\n", .{});
                return CsEmitError.UnsupportedConstruct;
            };
            if (idx >= continuations.len) {
                log.err("[cs_emitter] __koru_inline_{d} has no matching continuation (have {d})\n", .{ idx, continuations.len });
                return CsEmitError.UnsupportedConstruct;
            }
            if (consumed) |c| {
                if (idx < 64) c.* |= @as(u64, 1) << @intCast(idx);
            }
            const cont = &continuations[idx];
            const binding = cont.binding orelse "_";
            try self.write("{ ");
            if (cont.destructure.len > 0) {
                // Shape-destructure at the binding position — payload into a
                // temp first (arg may be a multi-read expression), then each
                // field once. Mirrors emitDestructureBindings at every other
                // arm path.
                const tmp = try std.fmt.allocPrint(self.allocator, "__koru_payload_{d}", .{self.nextId()});
                defer self.allocator.free(tmp);
                try self.writeFmt("var {s} = {s}; ", .{ tmp, arg });
                if (!std.mem.eql(u8, binding, "_")) {
                    try self.writeFmt("var {s} = {s}; ", .{ binding, tmp });
                    try self.registerLocal(binding);
                }
                try self.emitDestructureBindings(cont.destructure, tmp, "", true);
            } else if (!std.mem.eql(u8, binding, "_")) {
                try self.writeFmt("var {s} = {s}; ", .{ binding, arg });
                try self.registerLocal(binding);
            }
            const guarded = cont.condition != null;
            if (guarded) {
                try self.write("if (");
                try self.writeCsExpr(cont.condition.?);
                try self.write(") { ");
            }
            try self.emitInlineContinuationBody(cont, body_indent);
            if (guarded) try self.write(" }");
            try self.write(" }");
            pos = i;
        }
        try self.writeHostText(trimmed[pos..]);
    }

    /// Emit the continuations of an inline body that resolved NO splice
    /// marker — the caller's own chain steps that drain body-only after a
    /// template consumed its arms. Mirrors emitUnconsumedContinuations in the
    /// JS emitter: named leftovers of a dispatcher body are the template's
    /// own (skip); unnamed leftovers (and everything on a rendered-statement
    /// body) drain.
    fn emitUnconsumedContinuations(
        self: *Emitter,
        continuations: []const ast.Continuation,
        consumed: u64,
        indent: []const u8,
    ) CsEmitError!void {
        for (continuations, 0..) |*cont, ci| {
            if (cont.kind != .terminal) continue;
            if (ci < 64 and (consumed & (@as(u64, 1) << @intCast(ci))) != 0) continue;
            if (consumed != 0) {
                if (cont.branch.len != 0) continue;
                try self.emitInlineContinuationBody(cont, indent);
            } else {
                try self.emitTerminalContinuation(cont, null, continuations, null, indent, false, false, null);
            }
        }
    }

    /// Emit the body of a terminal continuation spliced inline by a template
    /// marker — the body itself, no tag-dispatch guard and no payload bind
    /// (the template's own conditional does the branching).
    fn emitInlineContinuationBody(self: *Emitter, cont: *const ast.Continuation, indent: []const u8) CsEmitError!void {
        const node = cont.node orelse return;
        switch (node) {
            .invocation => |*inv| {
                if (inv.preamble_code) |preamble| try self.emitPreamble(preamble, indent);
                try self.emitInvocationWithContinuations(inv, cont.continuations, indent);
            },
            .terminal => {},
            .branch_constructor => |*bc| try self.emitBranchConstructorReturn(bc, indent),
            .expression => |expr| {
                if (!try self.emitProduceExpr(expr, indent)) {
                    try self.writeFmt("{s}return ", .{indent});
                    try self.writeCsExpr(expr);
                    try self.write(";\n");
                }
            },
            .assignment => |asgn| {
                try codegen_utils.emitCapturedAssignment(self, .cs, &asgn, indent);
                try self.emitPreambleContinuations(cont.continuations, indent);
            },
            .inline_code => |text| {
                try self.emitPreamble(text, indent);
                try self.emitPreambleContinuations(cont.continuations, indent);
            },
            .metatype_binding => |*mb| try self.emitMetatypeBinding(mb, cont.continuations, indent),
            else => {
                log.err("[cs_emitter] inline continuation body is a {s}, which the cs target does not model\n", .{@tagName(node)});
                return CsEmitError.UnsupportedConstruct;
            },
        }
    }

    /// A `~tap(x -> *) | Profile p |> …` arm's observation record — produces
    /// no dispatchable value; its continuations run in the record's scope.
    /// Same three shapes as JS (js_emitter.zig:1895): Transition is the cheap
    /// metatype, Profile adds the timestamp, Audit the payload slot.
    fn emitMetatypeBinding(
        self: *Emitter,
        mb: anytype,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) CsEmitError!void {
        try self.writeFmt("{s}{{\n", .{indent});
        const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(inner);
        try self.writeFmt("{s}var ", .{inner});
        try self.writeBinding(mb.binding);
        try self.writeFmt(" = new {{ source = \"{s}\", destination = ", .{mb.source_event});
        if (mb.dest_event) |dest| {
            try self.writeFmt("\"{s}\"", .{dest});
        } else {
            try self.write("(string)null");
        }
        try self.writeFmt(", branch = \"{s}\"", .{if (mb.branch.len == 0) "__void" else mb.branch});
        if (!std.mem.eql(u8, mb.metatype, "Transition")) {
            try self.write(", timestamp_ns = global::System.DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000000L");
            if (std.mem.eql(u8, mb.metatype, "Audit")) try self.write(", payload = (object)null");
        }
        try self.write(" };\n");
        try self.emitPreambleContinuations(continuations, inner);
        try self.writeFmt("{s}}}\n", .{indent});
    }

    /// The call-site `: name` bind, or null when there is nothing to NAME
    /// (`_` is a discard).
    fn namedReturnBinding(inv: *const ast.Invocation) ?[]const u8 {
        const rb = inv.return_binding orelse return null;
        if (std.mem.eql(u8, rb, "_")) return null;
        return rb;
    }

    /// Recursively emit a dispatch: resolve `inv`'s event, call its handler,
    /// then drive the TERMINAL continuations on the returned `.tag`.
    /// Effect-bearing events and arm fires REFUSE — the Handlers-object
    /// machinery is a design conversation the vertical does not pre-empt.
    fn emitInvocationWithContinuations(
        self: *Emitter,
        inv: *const ast.Invocation,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) CsEmitError!void {
        // TRANSFORM-PRODUCED INLINE BODY: a comptime|transform rerouted this
        // invocation to an impl stub and stored target-lowered code on
        // inv.inline_body. Splice it here, at every depth.
        if (inv.inline_body) |inline_body_raw| {
            const stripped = stripInlineStmtMarker(inline_body_raw);
            var consumed: u64 = 0;
            try self.emitInlineBodyResolvingContinuations(stripped, continuations, indent, &consumed);
            try self.write("\n");
            try self.emitUnconsumedContinuations(continuations, consumed, indent);
            return;
        }
        // SUBFLOW-IMPLEMENTED EFFECT FIRE. Inside the impl of an
        // effect-bearing tor, a call to one of THAT tor's own effect arms is
        // the FIRING — it invokes the `Func` the caller installed on its ops
        // struct, bound to a local at handler entry.
        if (self.impl_event) |impl_ev| {
            if (findEffectArm(impl_ev, &inv.path)) |arm| {
                try self.emitEffectArmFire(arm, inv, continuations, indent);
                return;
            }
        }

        const ev = self.resolveInvocationEvent(inv) orelse {
            log.err("[cs_emitter] flow invokes unresolved tor\n", .{});
            return CsEmitError.UnresolvedEvent;
        };

        // VARIANT SELECTION — `std/build:variants {"input:pump": "alt"}` (or a
        // call-site `pump|alt(…)`) routes this dispatch to `~proc pump|alt`,
        // not `pump|cs`. Emitting the default lang body answers the wrong
        // impl silently (370_012: `21`/`default` where `42`/`alt` was
        // selected). The selected variant's body is not a |cs body — refuse.
        if (inv.inline_body == null) {
            var selected = inv.variant;
            if (selected == null) {
                const canonical = try emitter_helpers.buildCanonicalEventName(&inv.path, self.allocator, self.main_module_name);
                defer self.allocator.free(canonical);
                selected = emitter_helpers.getVariant(canonical);
            }
            if (selected) |v| {
                if (!std.mem.eql(u8, v, CS_TARGET)) {
                    const leaf = inv.path.segments[inv.path.segments.len - 1];
                    log.err("[cs_emitter] tor '{s}' dispatch selects variant '{s}', which has no |cs body\n", .{ leaf, v });
                    return CsEmitError.UnsupportedConstruct;
                }
            }
        }

        // A dispatch to a MODULE event with no cs implementable body would
        // emit a call to the throwing refusal class — a refusal deferred to
        // runtime. Refuse here, where the call is made. Top-level decls are
        // exempt: Phase 1 emits their real handler or refuses them itself —
        // only Phase 1b's module path can leave a live stub behind a call.
        if (inv.inline_body == null) {
            if (self.findDeclSiteIn(self.items, &inv.path, null)) |site| {
                if (site.scope.ptr != self.items.ptr and
                    !self.eventIsCsImplementable(site, IMPL_WALK_DEPTH) and
                    soleTerminalBranch(site.decl) == null)
                {
                    const leaf = inv.path.segments[inv.path.segments.len - 1];
                    log.err("[cs_emitter] tor '{s}' has no |cs proc, immediate, or subflow body\n", .{leaf});
                    return CsEmitError.UnsupportedConstruct;
                }
            }
        }

        var ev_has_effect = false;
        var terminal_branches: usize = 0;
        for (ev.branches) |b| {
            if (b.kind == .effect) {
                ev_has_effect = true;
            } else {
                terminal_branches += 1;
            }
        }
        const callee_bare_return = terminal_branches == 0 and ev.return_type != null;

        // Only allocate a result binding when a continuation actually reads
        // it (a payload bind, a 2+ branch dispatch, a call-site `: name`).
        var needs_result = false;
        var terminal_count: usize = 0;
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            terminal_count += 1;
            if (cont.is_catchall) needs_result = true; // the gate reads .tag
            if (cont.binding != null and !std.mem.eql(u8, cont.binding.?, "_")) {
                needs_result = true;
            }
            if (cont.destructure.len > 0) needs_result = true;
        }
        if (terminal_count >= 2 and !callee_bare_return) needs_result = true;
        if (namedReturnBinding(inv) != null) needs_result = true;

        // Build the Handlers struct from the EFFECT continuations — a
        // generated `Handlers_N` implementing the event's IOps interface.
        // Lambdas capture the enclosing flow's locals the way a JS object
        // literal's methods close over theirs, so the call site's names
        // reach the handler body unchanged. The id is monotonic so nested
        // frames get distinct names.
        var handlers_name: ?[]const u8 = null;
        defer if (handlers_name) |hn| self.allocator.free(hn);

        if (ev_has_effect) {
            // Arm bodies produce RESUME values, not the enclosing tor's
            // Output — emitOpsStructDecl installs each arm's envelope
            // itself; `.dynamic` here is only the default under which the
            // ops/init text emits. The struct decl lands in ops_buf;
            // `init_buf` collects the call site's `new H { … }` entries —
            // `__cap_<n>` capture copies and the Func values a forwarded or
            // optional-resuming arm keeps.
            const saved_out = self.impl_out;
            defer self.impl_out = saved_out;
            self.impl_out = .dynamic;
            const hid = self.nextId();
            handlers_name = try std.fmt.allocPrint(self.allocator, "__koru_handlers_{d}", .{hid});
            var init_buf: std.ArrayList(u8) = .empty;
            defer init_buf.deinit(self.allocator);
            const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
            defer self.allocator.free(inner_indent);
            try self.emitOpsStructDecl(ev, continuations, handlers_name.?, &init_buf, inner_indent);
            try self.writeFmt("{s}var {s} = new {s} {{ {s} }};\n", .{ indent, handlers_name.?, handlers_name.?, std.mem.trim(u8, init_buf.items, " \t\r\n") });
        }

        var ev_name_buf: [256]u8 = undefined;
        const ev_name = self.eventClassName(&ev_name_buf, ev);
        const result_name: ?[]const u8 = if (!needs_result) null else if (namedReturnBinding(inv)) |rb|
            try self.dupeSpelled(rb)
        else blk: {
            const rid = self.nextId();
            break :blk try std.fmt.allocPrint(self.allocator, "result_{d}", .{rid});
        };
        defer if (result_name) |rn| self.allocator.free(rn);

        // `&name` borrow args become `__KoruBox` handles hoisted BEFORE the
        // call — the callee writes `.data`, and the write-back after the
        // call puts the mutation back on the caller's binding. A box without
        // the write-back would silently drop the mutation — the wrong-answer
        // lie a refusal exists to prevent.
        var borrow_box: [16]?[]const u8 = .{null} ** 16;
        var borrow_target: [16][]const u8 = undefined;
        defer for (borrow_box) |b| {
            if (b) |s| self.allocator.free(s);
        };
        var borrow_count: usize = 0;

        // CALL-SITE INLINE — a tor whose whole cs impl is one return-free
        // opaque |cs| proc splices its body here instead of dispatching: the
        // same inlining the JIT already does, one scope earlier, so a bare
        // cell name in the body binds the caller's hoisted local and the
        // write can register-materialize. A body holding `return` produces
        // through the callee's frame and cannot splice into a statement
        // chain; a result-binding or destructuring call site still needs the
        // handler's return value.
        const inlined = result_name == null and !ev_has_effect and
            inv.return_destructure.len == 0 and
            try self.tryEmitInlinedProcCall(inv, ev, indent);
        if (!inlined) {
            for (inv.args, 0..) |arg, ai| {
                if (ai >= borrow_box.len) break;
                if (borrowTarget(arg.value)) |t| {
                    const bname = try std.fmt.allocPrint(self.allocator, "__koru_borrow_{d}", .{self.nextId()});
                    // `dynamic`, not `var`: `var` would infer __KoruBox and
                    // pin `.data` reads to `object`, breaking member chains
                    // in spliced text that expects the dynamic handle.
                    try self.writeFmt("{s}dynamic {s} = new __KoruBox {{ data = ", .{ indent, bname });
                    try self.writeBinding(t);
                    try self.write(" };\n");
                    borrow_box[ai] = bname;
                    borrow_target[ai] = t;
                    borrow_count += 1;
                }
            }
            if (result_name) |rn| {
                try self.writeFmt("{s}var {s} = main_module.{s}_event.handler(", .{ indent, rn, ev_name });
                try self.registerLocal(rn);
            } else {
                try self.writeFmt("{s}main_module.{s}_event.handler(", .{ indent, ev_name });
            }
            try self.emitArgsObject(inv.args, ev, ev_name, borrow_box[0..]);
            if (ev_has_effect) {
                try self.writeFmt(", {s}", .{handlers_name.?});
            }
            try self.write(");\n");
            for (borrow_box, 0..) |b, bi| {
                if (b) |bname| {
                    try self.writeFmt("{s}", .{indent});
                    try self.writeBinding(borrow_target[bi]);
                    try self.writeFmt(" = {s}.data;\n", .{bname});
                }
            }
        }

        // A BIND-POSITION destructure (`~locate(): { pos: { x, y } } |> …`).
        if (inv.return_destructure.len > 0) {
            if (result_name) |rn| {
                try self.emitDestructureBindings(inv.return_destructure, rn, indent, true);
            }
        }

        // Drive terminal continuations — 2+ branches dispatch on `.tag`.
        const needs_dispatch = terminal_count >= 2 and !callee_bare_return;
        try self.emitTerminalContinuations(continuations, ev, result_name, indent, needs_dispatch, callee_bare_return);
    }

    /// Emit the terminal `| branch` continuations of a dispatch. A `when`
    /// guard anywhere in the set switches the whole group to the guarded
    /// `__matched` chain (first match wins, conditions read their bindings).
    fn emitTerminalContinuations(
        self: *Emitter,
        continuations: []const ast.Continuation,
        ev: ?*const ast.EventDecl,
        result_name: ?[]const u8,
        indent: []const u8,
        dispatch: bool,
        bare_return: bool,
    ) CsEmitError!void {
        var needs_chain = false;
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            if (cont.condition != null) needs_chain = true;
        }

        var matched: ?[]const u8 = null;
        defer if (matched) |m| self.allocator.free(m);
        if (needs_chain) {
            matched = try std.fmt.allocPrint(self.allocator, "__matched_{d}", .{self.nextId()});
            try self.writeFmt("{s}var {s} = false;\n", .{ indent, matched.? });
        }

        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            try self.emitTerminalContinuation(cont, ev, continuations, result_name, indent, dispatch, bare_return, matched);
        }
    }

    /// `(<rn>.tag == "a" || <rn>.tag == "b" || …)` over the callee's OPTIONAL
    /// terminal branches that no sibling arm names — the residual's route set.
    fn emitResidualTagGateBare(
        self: *Emitter,
        rn: []const u8,
        ev: ?*const ast.EventDecl,
        siblings: []const ast.Continuation,
    ) CsEmitError!void {
        const evd = ev orelse {
            try self.write("true");
            return;
        };
        var first = true;
        try self.write("(");
        for (evd.branches) |b| {
            if (!b.is_optional or b.kind == .effect) continue;
            var named = false;
            for (siblings) |*sib| {
                if (!sib.is_catchall and std.mem.eql(u8, sib.branch, b.name)) {
                    named = true;
                    break;
                }
            }
            if (named) continue;
            if (!first) try self.write(" || ");
            first = false;
            try self.writeFmt("{s}.tag == \"{s}\"", .{ rn, b.name });
        }
        if (first) try self.write("false");
        try self.write(")");
    }

    /// Same gate as an `&&`-clause inside a `__matched` chain condition.
    fn emitResidualTagGate(
        self: *Emitter,
        rn: []const u8,
        ev: ?*const ast.EventDecl,
        siblings: []const ast.Continuation,
    ) CsEmitError!void {
        try self.write(" && ");
        try self.emitResidualTagGateBare(rn, ev, siblings);
    }

    /// Emit a terminal continuation: `| done r |> BODY` →
    /// `var r = <result>.done;` then BODY. A `|*` residual gates on the
    /// callee's OPTIONAL branches not already named at this site — the same
    /// set the Zig emitter routes into the residual arm.
    fn emitTerminalContinuation(
        self: *Emitter,
        cont: *const ast.Continuation,
        ev: ?*const ast.EventDecl,
        siblings: []const ast.Continuation,
        result_name: ?[]const u8,
        indent: []const u8,
        dispatch: bool,
        bare_return: bool,
        matched: ?[]const u8,
    ) CsEmitError!void {
        var indents: [2][]u8 = undefined;
        var indent_count: usize = 0;
        defer for (indents[0..indent_count]) |s| self.allocator.free(s);
        var body_indent = indent;
        var open_braces: usize = 0;

        const deeper = struct {
            fn f(em: *Emitter, base: []const u8) CsEmitError![]u8 {
                return std.fmt.allocPrint(em.allocator, "{s}  ", .{base});
            }
        }.f;

        if (matched) |mv| {
            try self.writeFmt("{s}if (!{s}", .{ indent, mv });
            if (dispatch and cont.branch.len > 0) {
                const rn = result_name orelse {
                    log.err("[cs_emitter] guarded terminal chain needs a result value but none was emitted\n", .{});
                    return CsEmitError.UnsupportedConstruct;
                };
                if (cont.is_catchall) {
                    try self.emitResidualTagGate(rn, ev, siblings);
                } else {
                    try self.writeFmt(" && {s}.tag == \"{s}\"", .{ rn, cont.branch });
                }
            }
            try self.write(") {\n");
            indents[indent_count] = try deeper(self, indent);
            body_indent = indents[indent_count];
            indent_count += 1;
            open_braces += 1;
        } else if (dispatch or (cont.is_catchall and result_name != null)) {
            const rn = result_name orelse {
                log.err("[cs_emitter] terminal dispatch needs a result value but none was emitted\n", .{});
                return CsEmitError.UnsupportedConstruct;
            };
            if (cont.is_catchall) {
                try self.writeFmt("{s}if (", .{indent});
                try self.emitResidualTagGateBare(rn, ev, siblings);
                try self.write(") {\n");
            } else {
                try self.writeFmt("{s}if ({s}.tag == \"{s}\") {{\n", .{ indent, rn, cont.branch });
            }
            indents[indent_count] = try deeper(self, indent);
            body_indent = indents[indent_count];
            indent_count += 1;
            open_braces += 1;
        }

        if (cont.binding) |binding| {
            if (!std.mem.eql(u8, binding, "_")) {
                const rn = result_name orelse {
                    log.err("[cs_emitter] terminal continuation binds '{s}' (branch '{s}') but no result binding was emitted\n", .{ binding, cont.branch });
                    return CsEmitError.UnsupportedConstruct;
                };
                if (cont.is_catchall) {
                    // `|* M b` — the residual record carries which branch
                    // fired (the metatype record's testimony field).
                    try self.writeFmt("{s}var ", .{body_indent});
                    try self.writeBinding(binding);
                    try self.writeFmt(" = new {{ branch = {s}.tag }};\n", .{rn});
                } else if (bare_return or cont.branch.len == 0) {
                    try self.writeFmt("{s}var ", .{body_indent});
                    try self.writeBinding(binding);
                    try self.writeFmt(" = {s};\n", .{rn});
                } else {
                    try self.writeFmt("{s}var ", .{body_indent});
                    try self.writeBinding(binding);
                    try self.write(" = ");
                    try self.writeMember(rn, csPayloadName(cont.branch));
                    try self.write(";\n");
                }
                try self.registerLocal(binding);
            }
        }

        if (cont.destructure.len > 0) {
            const rn = result_name orelse {
                log.err("[cs_emitter] terminal continuation destructures a payload but no result binding was emitted\n", .{});
                return CsEmitError.UnsupportedConstruct;
            };
            var base_buf = std.ArrayList(u8).empty;
            defer base_buf.deinit(self.allocator);
            try base_buf.appendSlice(self.allocator, rn);
            if (!(bare_return or cont.branch.len == 0)) {
                try base_buf.append(self.allocator, '.');
                var kb: [256]u8 = undefined;
                const branch_key = csPayloadName(cont.branch);
                if (branch_key.len <= kb.len) {
                    const lowered = lowerIdentBuf(&kb, branch_key);
                    try base_buf.appendSlice(self.allocator, lowered);
                }
            }
            try self.emitDestructureBindings(cont.destructure, base_buf.items, body_indent, true);
        }

        // The `when` guard runs AFTER the bindings — it reads them.
        if (cont.condition) |condition| {
            try self.writeFmt("{s}if (", .{body_indent});
            try self.writeCsExpr(condition);
            try self.write(") {\n");
            indents[indent_count] = try deeper(self, body_indent);
            body_indent = indents[indent_count];
            indent_count += 1;
            open_braces += 1;
        }

        if (matched) |mv| try self.writeFmt("{s}{s} = true;\n", .{ body_indent, mv });

        if (cont.node) |node| {
            switch (node) {
                .invocation => |*inv| {
                    try self.emitInvocationWithContinuations(inv, cont.continuations, body_indent);
                },
                .terminal => {},
                .branch_constructor => |*bc| try self.emitBranchConstructorReturn(bc, body_indent),
                .expression => |expr| {
                    if (!try self.emitProduceExpr(expr, body_indent)) {
                        try self.writeFmt("{s}return ", .{body_indent});
                        try self.writeCsExpr(expr);
                        try self.write(";\n");
                    }
                },
                .assignment => |asgn| {
                    try codegen_utils.emitCapturedAssignment(self, .cs, &asgn, body_indent);
                    try self.emitPreambleContinuations(cont.continuations, body_indent);
                },
                .inline_code => |text| {
                    try self.emitPreamble(text, body_indent);
                    try self.emitPreambleContinuations(cont.continuations, body_indent);
                },
                // A `@L(…)` jump ENDS its arm: it re-seeds the fold and the
                // `goto` landing on the `while` header decides the next turn —
                // C#'s spelling of JS's labelled `continue` (C# has none).
                .label_jump => |lj| {
                    try self.emitLabelJump(lj.label, lj.args, body_indent);
                },
                .label_apply => |l| {
                    try self.emitLabelJump(l, &.{}, body_indent);
                },
                // `#loop counter(n: 1)` in continuation position — the fold
                // ANCHOR. A `@loop(…)` JUMP also parses here with
                // is_declaration false; refuse that one by name rather than
                // fold on it (the Zig reference agrees, emitter_helpers.zig).
                .label_with_invocation => |*lwi| {
                    if (!lwi.is_declaration) {
                        log.err("[cs_emitter] @{s}(…) reached as a fold ANCHOR; a jump must sit inside its own #{s}\n", .{ lwi.label, lwi.label });
                        return CsEmitError.UnsupportedConstruct;
                    }
                    try self.emitLabelFoldAt(&lwi.invocation, cont.continuations, lwi.label, body_indent);
                },
                // A `~tap(x -> *) | Profile p |> log(msg: p.source)` arm's
                // observation record, grafted by the tap transformer: it
                // produces no dispatchable value; its continuations run in
                // the record's scope. Same three shapes as JS's
                // (js_emitter.zig:1895) — Transition is the cheap metatype,
                // Profile adds the timestamp, Audit the payload slot.
                .metatype_binding => |*mb| try self.emitMetatypeBinding(mb, cont.continuations, body_indent),
                else => {
                    log.err("[cs_emitter] terminal continuation body is a {s}, which the cs target does not model\n", .{@tagName(node)});
                    return CsEmitError.UnsupportedConstruct;
                },
            }
        }

        var to_close = open_braces;
        while (to_close > 0) : (to_close -= 1) {
            const close_at = if (to_close == 1) indent else indents[to_close - 2];
            try self.writeFmt("{s}}}\n", .{close_at});
        }
    }

    /// Bind a shape-destructure's fields off `base`, recursing into nested
    /// destructures by lengthening the access path. `track` registers the
    /// names as capture candidates — true at flow level, false inside an arm
    /// body where the names are method-locals that must not escape into a
    /// later site's `__cap_*` initializer.
    fn emitDestructureBindings(
        self: *Emitter,
        fields: []const ast.DestructureField,
        base: []const u8,
        indent: []const u8,
        track: bool,
    ) CsEmitError!void {
        // Flat paths: `{ pos.x }` → `var x = base.pos.x`.
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, "_")) continue;
            try self.writeFmt("{s}var ", .{indent});
            try self.writeBinding(field.name);
            try self.write(" = ");
            try self.write(base);
            try self.write(".");
            try self.write(field.path);
            try self.write(";\n");
            if (track) try self.registerLocal(field.name);
        }
    }

    /// Emit the args as the callee's typed Input struct — `new
    /// beat_event.Input { q = 41 }` — the zero-allocation twin of zig's
    /// `.{ .q = 41 }`. A wildcard-input tor keeps the anonymous object: its
    /// members cannot be named at decl time.
    fn emitArgsObject(self: *Emitter, args: []const ast.Arg, ev: *const ast.EventDecl, ev_name: []const u8, borrow_boxes: ?[]const ?[]const u8) CsEmitError!void {
        const typed = !ev.input.is_wildcard;
        try self.write("new ");
        if (typed) try self.writeFmt("{s}_event.Input ", .{ev_name});
        try self.write("{ ");
        for (args, 0..) |arg, idx| {
            if (idx > 0) try self.write(", ");
            try self.writeBinding(arg.name);
            try self.write(" = ");
            if (borrow_boxes) |bb| {
                if (idx < bb.len) if (bb[idx]) |bname| {
                    try self.write(bname);
                    continue;
                };
            }
            // An `Expression` param transports the captured SOURCE TEXT, not
            // the evaluated value — `calc(expr: 2 + 3)` hands the callee
            // "2 + 3" (parser.zig: "an Expression is just another way to
            // pass a string"). Same quoting the zig emitter's
            // is_expression_arg path writes.
            var is_expression = false;
            var is_source = false;
            if (typed) {
                for (ev.input.fields) |field| {
                    if (std.mem.eql(u8, field.name, arg.name)) {
                        is_expression = field.is_expression;
                        is_source = field.is_source;
                        break;
                    }
                }
            }
            if (is_expression or is_source) {
                // A `Source` param transports captured BLOCK text — the
                // callee reads `source.text`, so the value is an anonymous
                // record carrying the literal.
                if (is_source) try self.write("new { text = ");
                try self.write("\"");
                const captured = if (is_source and arg.source_value != null) arg.source_value.?.text else arg.value;
                for (captured) |c| {
                    switch (c) {
                        '"' => try self.write("\\\""),
                        '\\' => try self.write("\\\\"),
                        '\n' => try self.write("\\n"),
                        '\r' => try self.write("\\r"),
                        '\t' => try self.write("\\t"),
                        else => try self.write(&[_]u8{c}),
                    }
                }
                try self.write("\"");
                if (is_source) try self.write(" }");
                continue;
            }
            // The declared field type wraps the value in an explicit cast —
            // the same `(<T>)(<expr>)` rule bare produces use. Literal `0.5`
            // is a `double` in C# and will not convert into a `float` field;
            // `(float)(0.5)` is legal, as is `(long)(v)` on a dynamic arg —
            // one rule covers every narrow type, not just the f32 that
            // measured first.
            const ft = argFieldCsType(ev, arg.name);
            if (typed and !std.mem.eql(u8, ft, "dynamic")) {
                try self.writeFmt("({s})(", .{ft});
                try self.writeCsExpr(arg.value);
                try self.write(")");
            } else {
                try self.writeCsExpr(arg.value);
            }
        }
        try self.write("}");
    }

    /// `#L` fold — `~start() |> #loop counter(n: 1) | next c |> @loop(n: c) | done`.
    /// State variables carry the turn's parameters; the `while` header tests
    /// the latest result's tag; each looping arm re-invokes and `goto`s back
    /// to the check. C# has no labelled `continue`, so the turn-end is a
    /// `goto` landing on a label before the `while` — same-level and
    /// cross-level jumps share the spelling (js_emitter.zig:1375 uses a
    /// labelled `while` for exactly the same reason).
    fn emitLabelFoldAt(
        self: *Emitter,
        inv: *const ast.Invocation,
        conts: []const ast.Continuation,
        label: []const u8,
        indent: []const u8,
    ) CsEmitError!void {
        const event = self.resolveInvocationEvent(inv) orelse {
            log.err("[cs_emitter] #{s} fold head invokes an unresolved event\n", .{label});
            return CsEmitError.UnresolvedEvent;
        };
        if (self.findDeclSiteIn(self.items, &inv.path, null)) |site| {
            if (site.scope.ptr != self.items.ptr and
                !self.eventIsCsImplementable(site, IMPL_WALK_DEPTH) and
                soleTerminalBranch(site.decl) == null)
            {
                log.err("[cs_emitter] #{s} fold head '{s}' has no |cs proc, immediate, or subflow body\n", .{ label, inv.path.segments[inv.path.segments.len - 1] });
                return CsEmitError.UnsupportedConstruct;
            }
        }

        var terminal_branches: usize = 0;
        for (event.branches) |b| {
            if (b.kind == .effect) {
                // Same refusal as JS: rebuilding Handlers per turn is
                // unmodelled on both targets.
                log.err("[cs_emitter] #{s} fold head '{s}' declares effect branches, which this target does not model\n", .{ label, event.path.segments[event.path.segments.len - 1] });
                return CsEmitError.UnsupportedConstruct;
            }
            terminal_branches += 1;
        }
        const bare_return = terminal_branches == 0 and event.return_type != null;

        // One state variable per head parameter, seeded from the head's args.
        // Declared with the Input field's type, not `var`: the literal `0`
        // would infer `int` and a `long` payload could not be re-seeded into it.
        for (inv.args) |arg| {
            const ft = argFieldCsType(event, arg.name);
            try self.writeFmt("{s}{s} {s}", .{ indent, ft, label });
            try self.writeBinding(arg.name);
            try self.write(" = ");
            try self.writeCsExpr(arg.value);
            try self.write(";\n");
        }

        var ev_name_buf: [256]u8 = undefined;
        const ev_name = self.eventClassName(&ev_name_buf, event);
        const result_name = try std.fmt.allocPrint(self.allocator, "result_{d}", .{self.nextId()});
        defer self.allocator.free(result_name);

        try self.writeFmt("{s}var {s} = main_module.{s}_event.handler(", .{ indent, result_name, ev_name });
        try self.emitLabelStateArgs(inv.args, event, ev_name, label);
        try self.write(");\n");

        var looping: usize = 0;
        var exiting: usize = 0;
        for (conts) |*cont| {
            if (cont.kind != .terminal) continue;
            if (contLoopsTo(cont, label)) looping += 1 else exiting += 1;
        }

        const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(inner);

        if (looping > 0) {
            try self.writeFmt("{s}__fold_{s}_check:\n", .{ indent, label });
            try self.writeFmt("{s}while (", .{indent});
            var written: usize = 0;
            for (conts) |*cont| {
                if (cont.kind != .terminal or !contLoopsTo(cont, label)) continue;
                if (written > 0) try self.write(" || ");
                try self.writeFmt("{s}.tag == \"{s}\"", .{ result_name, cont.branch });
                written += 1;
            }
            try self.write(") {\n");

            const saved = self.label_frame;
            const frame = LabelFrame{
                .label = label,
                .result_name = result_name,
                .inv = inv,
                .outer = saved,
            };
            self.label_frame = &frame;
            defer self.label_frame = saved;

            // Inside the loop the condition already selected the arm when
            // there is only one; with two or more each needs its tag test.
            for (conts) |*cont| {
                if (cont.kind != .terminal or !contLoopsTo(cont, label)) continue;
                try self.emitTerminalContinuation(cont, event, conts, result_name, inner, looping >= 2, bare_return, null);
            }
            try self.writeFmt("{s}}}\n", .{indent});
        }

        // The exit arms run AFTER the loop, where every looping tag is
        // impossible.
        for (conts) |*cont| {
            if (cont.kind != .terminal or contLoopsTo(cont, label)) continue;
            try self.emitTerminalContinuation(cont, event, conts, result_name, indent, exiting >= 2, bare_return, null);
        }
    }

    /// `new <ev>_event.Input { <param> = <label>_<param>, … }` — the fold's
    /// head args read out of the state variables, written at the seed call
    /// and again at every jump so the two cannot disagree.
    fn emitLabelStateArgs(
        self: *Emitter,
        args: []const ast.Arg,
        ev: *const ast.EventDecl,
        ev_name: []const u8,
        label: []const u8,
    ) CsEmitError!void {
        const typed = !ev.input.is_wildcard;
        try self.write("new ");
        if (typed) try self.writeFmt("{s}_event.Input ", .{ev_name});
        try self.write("{ ");
        for (args, 0..) |arg, i| {
            if (i > 0) try self.write(", ");
            try self.writeBinding(arg.name);
            try self.write(" = ");
            const ft = argFieldCsType(ev, arg.name);
            if (typed and !std.mem.eql(u8, ft, "dynamic")) try self.writeFmt("({s})(", .{ft});
            try self.writeFmt("{s}", .{label});
            try self.writeBinding(arg.name);
            if (typed and !std.mem.eql(u8, ft, "dynamic")) try self.write(")");
        }
        try self.write("}");
    }

    /// `@L(args…)` — re-seed the state variables, re-run the head, and
    /// `goto` back to the fold's `while` header. The target walks OUT
    /// through the frame chain, so a cross-level jump leaves the inner loop
    /// entirely — the case `goto` exists for.
    fn emitLabelJump(self: *Emitter, label: []const u8, args: []const ast.Arg, indent: []const u8) CsEmitError!void {
        var walk = self.label_frame;
        const frame = while (walk) |f| : (walk = f.outer) {
            if (std.mem.eql(u8, f.label, label)) break f;
        } else {
            if (self.label_frame) |innermost| {
                log.err("[cs_emitter] @{s}(…) names no enclosing fold; innermost is #{s}\n", .{ label, innermost.label });
            } else {
                log.err("[cs_emitter] @{s}(…) jump outside any #{s} fold\n", .{ label, label });
            }
            return CsEmitError.UnsupportedConstruct;
        };
        const frame_event = self.resolveInvocationEvent(frame.inv) orelse {
            log.err("[cs_emitter] @{s}(…) re-invokes an unresolved event\n", .{label});
            return CsEmitError.UnresolvedEvent;
        };
        for (args) |arg| {
            try self.writeFmt("{s}{s}", .{ indent, label });
            try self.writeBinding(arg.name);
            try self.write(" = ");
            try self.writeCsExpr(arg.value);
            try self.write(";\n");
        }
        var ev_name_buf: [256]u8 = undefined;
        const ev_name = self.eventClassName(&ev_name_buf, frame_event);
        try self.writeFmt("{s}{s} = main_module.{s}_event.handler(", .{ indent, frame.result_name, ev_name });
        try self.emitLabelStateArgs(frame.inv.args, frame_event, ev_name, label);
        try self.write(");\n");
        try self.writeFmt("{s}goto __fold_{s}_check;\n", .{ indent, frame.label });
    }

    /// The C# spelling of the declared type of a named Input field —
    /// `dynamic` when the name does not resolve (wildcard members, stray
    /// args) so callers can keep the uncast shape.
    fn argFieldCsType(ev: *const ast.EventDecl, name: []const u8) []const u8 {
        if (ev.input.is_wildcard) return "dynamic";
        for (ev.input.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return csType(field.type);
        }
        return "dynamic";
    }

    /// Re-indent a multi-line opaque body to `indent`, trimming leading blank
    /// lines and trailing whitespace. `$mod.` resolves to `main_module.` —
    /// the module-scope spelling a |cs body uses, where JS's file scope made
    /// the same name bare.
    fn emitReindented(self: *Emitter, body: []const u8, indent: []const u8) CsEmitError!void {
        const stripped = try csModQualify(self.allocator, body);
        defer self.allocator.free(stripped);
        const trimmed = std.mem.trim(u8, stripped, " \t\r\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try self.write("\n");
            first = false;
            const line_trimmed = std.mem.trimRight(u8, line, " \t\r");
            const content = std.mem.trimLeft(u8, line_trimmed, " \t");
            if (content.len == 0) continue;
            try self.write(indent);
            try self.write(content);
        }
    }

    /// Splice an opaque `|cs` proc impl at its call site —
    /// `acc(v: r)` becomes `{ var __koru_p_v = (long)(r); <body> }`. Params
    /// rebind to reserved `__koru_p_<name>` locals because C# forbids a `var`
    /// that shadows an in-scope local (CS0136 — a param named `i` inside a
    /// `for`'s arm block would collide with the induction binding), and a
    /// uniform rename keeps the body's own uses intact. The payoff over a
    /// call: a bare cell name in the body binds whatever is in scope HERE —
    /// a hoisted local when the enclosing handler materialized the cell.
    /// Returns false — caller emits the ordinary call — when the impl isn't
    /// a plain proc or the body can't splice (`return` would escape the
    /// caller's frame, not the callee's).
    fn tryEmitInlinedProcCall(self: *Emitter, inv: *const ast.Invocation, ev: *const ast.EventDecl, indent: []const u8) CsEmitError!bool {
        const site = self.findDeclSiteIn(self.items, &inv.path, null) orelse return false;
        const impl = self.findImplIn(site.scope, &ev.path) orelse return false;
        const proc = switch (impl) {
            .proc => |p| p,
            else => return false,
        };
        if (std.mem.indexOf(u8, proc.body.text, "return") != null) return false;

        var body = try self.allocator.dupe(u8, proc.body.text);
        defer self.allocator.free(body);
        if (!ev.input.is_wildcard) {
            for (ev.input.fields) |field| {
                var nb: [300]u8 = undefined;
                const spelled = spelledName(&nb, field.name) orelse field.name;
                const fresh = try std.fmt.allocPrint(self.allocator, "__koru_p_{s}", .{spelled});
                defer self.allocator.free(fresh);
                const rebound = try replaceIdent(self.allocator, body, spelled, fresh);
                self.allocator.free(body);
                body = rebound;
            }
        }

        try self.writeFmt("{s}{{\n", .{indent});
        const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(inner);
        // `&name` args bind a `__KoruBox` instead — write-backs land after
        // the spliced body so the callee's `.data` writes reach the caller's
        // binding (see emitInvocationWithContinuations).
        var wb_target: [16][]const u8 = undefined;
        var wb_param: [16][]const u8 = undefined;
        var wb_count: usize = 0;
        if (ev.input.is_wildcard) {
            for (inv.args) |arg| {
                if (arg.name.len == 0) continue;
                var nb: [300]u8 = undefined;
                const spelled = spelledName(&nb, arg.name) orelse arg.name;
                if (borrowTarget(arg.value)) |t| {
                    if (wb_count < 16) {
                        wb_target[wb_count] = t;
                        wb_param[wb_count] = try self.allocator.dupe(u8, spelled);
                        wb_count += 1;
                    }
                    try self.writeFmt("{s}dynamic __koru_p_{s} = new __KoruBox {{ data = ", .{ inner, spelled });
                    try self.writeBinding(t);
                    try self.write(" };\n");
                    continue;
                }
                try self.writeFmt("{s}var __koru_p_{s} = ", .{ inner, spelled });
                try self.writeCsExpr(arg.value);
                try self.write(";\n");
            }
        } else {
            for (ev.input.fields) |field| {
                var nb: [300]u8 = undefined;
                const spelled = spelledName(&nb, field.name) orelse field.name;
                const ft = csType(field.type);
                const arg_field = findArgForField(inv.args, field.name);
                const borrow = if (arg_field) |a| borrowTarget(a.value) else null;
                // `dynamic` decl for the box: `var` would pin `.data` to
                // `object` in the spliced body (see the borrow hoist above).
                try self.writeFmt("{s}{s} __koru_p_{s} = ", .{ inner, if (borrow != null) "dynamic" else "var", spelled });
                if (arg_field) |a| {
                    if (borrow) |t| {
                        if (wb_count < 16) {
                            wb_target[wb_count] = t;
                            wb_param[wb_count] = try self.allocator.dupe(u8, spelled);
                            wb_count += 1;
                        }
                        try self.write("new __KoruBox { data = ");
                        try self.writeBinding(t);
                        try self.write(" }");
                    } else if (!std.mem.eql(u8, ft, "dynamic")) {
                        try self.writeFmt("({s})(", .{ft});
                        try self.writeCsExpr(a.value);
                        try self.write(")");
                    } else {
                        try self.writeCsExpr(a.value);
                    }
                } else if (field.default) |dflt| {
                    try self.writeCsExpr(dflt);
                } else {
                    try self.writeFmt("default({s})", .{ft});
                }
                try self.write(";\n");
            }
        }
        try self.emitReindented(body, inner);
        for (wb_param[0..wb_count], wb_target[0..wb_count]) |p, t| {
            try self.writeFmt("{s}", .{inner});
            try self.writeBinding(t);
            try self.writeFmt(" = __koru_p_{s}.data;\n", .{p});
            self.allocator.free(p);
        }
        // Newline before the close — a trailing `//` comment in the body
        // would otherwise eat the `}`.
        try self.write("\n");
        try self.writeFmt("{s}}}\n", .{indent});
        return true;
    }

    /// The arg bound to a declared input field — names arrive resolved (a
    /// positional `work(i)` already carries `i`), same read emitArgsObject
    /// makes.
    fn findArgForField(args: []const ast.Arg, name: []const u8) ?*const ast.Arg {
        for (args) |*arg| {
            if (std.mem.eql(u8, arg.name, name)) return arg;
        }
        return null;
    }

    /// May `cell` materialize as a handler-scope local for `body`? The gates
    /// — in order, each one a place the name could hide: the body must name
    /// it bare at all; `Owner.name` qualified (or any `<x>.name`) bypasses
    /// the local so one mention disqualifies; `<ident> <name>` is a
    /// declaration the hoist would shadow-collide with; `<name>(` is a
    /// method, not the field; and every `<x>_event.handler(` callee inside
    /// the body must be clean — a callee touching the cell behind a call
    /// boundary would read the stale static mid-region.
    fn cellMayHoist(self: *Emitter, body: []const u8, cell: Cell) CsEmitError!bool {
        var mentioned = false;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, body, pos, cell.name)) |at| {
            pos = at + 1;
            if (at > 0 and csIdentChar(body[at - 1])) continue;
            if (at + cell.name.len < body.len and csIdentChar(body[at + cell.name.len])) continue;
            mentioned = true;
            if (at > 0 and body[at - 1] == '.') return false;
            var q = at;
            while (q > 0 and (body[q - 1] == ' ' or body[q - 1] == '\t')) q -= 1;
            if (q > 0 and csIdentChar(body[q - 1])) return false;
            var r = at + cell.name.len;
            while (r < body.len and (body[r] == ' ' or body[r] == '\t')) r += 1;
            if (r < body.len and body[r] == '(') return false;
        }
        if (!mentioned) return false;
        return !try self.calleeMentionsIdent(body, cell.name);
    }

    /// Scan `body` for `<leaf>_event.handler(` callees and refuse the hoist
    /// when any of their impls names the cell. A lowered leaf name that
    /// matches several events checks them all — ambiguous by construction,
    /// conservative by default.
    fn calleeMentionsIdent(self: *Emitter, body: []const u8, name: []const u8) CsEmitError!bool {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, body, pos, "_event.handler(")) |at| {
            pos = at + 1;
            var s = at;
            while (s > 0 and csIdentChar(body[s - 1])) s -= 1;
            const leaf = body[s..at];
            if (leaf.len == 0) continue;
            if (try self.leafImplMentionsIdent(self.items, leaf, name)) return true;
        }
        return false;
    }

    /// Every event whose lowered leaf name matches — impl-bodies checked.
    fn leafImplMentionsIdent(self: *Emitter, items: []const ast.Item, leaf: []const u8, name: []const u8) CsEmitError!bool {
        for (items) |*item| {
            switch (item.*) {
                .event_decl => |*e| {
                    var nb: [256]u8 = undefined;
                    if (!std.mem.eql(u8, self.eventClassName(&nb, e), leaf)) continue;
                    const impl = self.findImplIn(items, &e.path) orelse continue;
                    if (implMentionsIdent(impl, name)) return true;
                },
                .module_decl => |*m| {
                    if (try self.leafImplMentionsIdent(m.items, leaf, name)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Does this impl's emitted text name the cell? Proc bodies and bare
    /// expressions lower to checkable text; a subflow can hold the name in a
    /// continuation's inline text anywhere down its spine — out of textual
    /// reach here, so it counts as a mention (drops the hoist, never wrong).
    fn implMentionsIdent(impl: EventImpl, name: []const u8) bool {
        return switch (impl) {
            .proc => |p| textMentionsIdent(p.body.text, name),
            .immediate => |ii| blk: {
                const pv = ii.value.plain_value orelse break :blk false;
                break :blk textMentionsIdent(pv, name);
            },
            .subflow, .template_stub, .dead_stub, .empty_body => true,
        };
    }

    /// Emit an arm's BODY as a `{ … }` block — the shared shape behind the
    /// struct METHOD spelling (`dynamic ask(dynamic p) { … }`) and the
    /// Func-lambda spelling (`p => { … }`) an optional-resuming arm or the
    /// closure fallback keeps. `param` is the payload parameter name the
    /// block binds from; `tail` spells the fall-through return a guarded or
    /// non-returning body still needs: `.null` for `Func<dynamic>`/`dynamic`
    /// returns, `.default` for typed returns (`return default;` — `null`
    /// won't compile), `.none` for `void`.
    const ArmTail = enum { none, null_t, default_t };

    fn emitArmBodyBlock(
        self: *Emitter,
        all: []const ast.Continuation,
        branch: []const u8,
        arm: *const ast.Branch,
        param: []const u8,
        indent: []const u8,
        tail: ArmTail,
    ) CsEmitError!void {
        const payloadless = armIsPayloadless(arm);
        var arm_count: usize = 0;
        var first_arm: ?*const ast.Continuation = null;
        for (all) |*c| {
            if (c.kind != .effect or !std.mem.eql(u8, c.branch, branch)) continue;
            arm_count += 1;
            if (first_arm == null) first_arm = c;
        }
        const cont = first_arm orelse {
            try self.write("{ }");
            return;
        };

        // The one-continuation, unguarded, undestructured arm — bare body.
        if (arm_count == 1 and cont.condition == null and cont.destructure.len == 0) {
            try self.write("{\n");
            const inner = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
            defer self.allocator.free(inner);
            if (!payloadless) {
                if (cont.binding) |b| {
                    if (!std.mem.eql(u8, b, "_")) {
                        try self.write(inner);
                        try self.write("var ");
                        try self.writeBinding(b);
                        try self.writeFmt(" = {s};\n", .{param});
                    }
                }
            }
            var arm_returns = false;
            if (cont.node) |node| {
                switch (node) {
                    .expression => |expr| {
                        try self.writeFmt("{s}return ", .{inner});
                        try self.writeCsExpr(expr);
                        try self.write(";\n");
                        arm_returns = true;
                    },
                    .terminal => {},
                    else => {
                        arm_returns = try self.emitEffectArmBody(cont, inner, tail != .none);
                    },
                }
            }
            if (!arm_returns) try self.emitArmTail(tail, inner);
            try self.writeFmt("{s}}}", .{indent});
            return;
        }

        // Guarded / destructured / multicast arms — a block each so two arms
        // may both name `a` off the same fire.
        try self.write("{\n");
        const arm_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        defer self.allocator.free(arm_indent);
        const body_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{arm_indent});
        defer self.allocator.free(body_indent);

        for (all) |*cont_arm| {
            if (cont_arm.kind != .effect or !std.mem.eql(u8, cont_arm.branch, branch)) continue;

            try self.writeFmt("{s}{{\n", .{arm_indent});
            if (!payloadless and cont_arm.destructure.len > 0) {
                try self.emitDestructureBindings(cont_arm.destructure, param, body_indent, false);
            } else if (!payloadless) {
                if (cont_arm.binding) |b| {
                    if (!std.mem.eql(u8, b, "_")) {
                        try self.write(body_indent);
                        try self.write("var ");
                        try self.writeBinding(b);
                        try self.writeFmt(" = {s};\n", .{param});
                    }
                }
            }

            const guard_indent = if (cont_arm.condition != null) body_indent else arm_indent;
            if (cont_arm.condition) |condition| {
                try self.writeFmt("{s}if (", .{body_indent});
                try self.writeCsExpr(condition);
                try self.write(") {\n");
            }
            const inner_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{guard_indent});
            defer self.allocator.free(inner_indent);

            const arm_returns = try self.emitEffectArmBody(cont_arm, inner_indent, tail != .none);
            if (!arm_returns) {
                if (tail == .none and cont_arm.condition != null) {
                    // A fired guarded arm ends the dispatch — first match
                    // wins over the unguarded fallback (zig emits `return`
                    // inside its own `if`, 400_089).
                    try self.writeFmt("{s}return;\n", .{inner_indent});
                } else {
                    try self.emitArmTail(tail, inner_indent);
                }
            }

            if (cont_arm.condition != null) try self.writeFmt("{s}}}\n", .{body_indent});
            try self.writeFmt("{s}}}\n", .{arm_indent});
        }
        try self.emitArmTail(tail, arm_indent);
        try self.writeFmt("{s}}}", .{indent});
    }

    /// The fall-through return at a block's end — see ArmTail.
    fn emitArmTail(self: *Emitter, tail: ArmTail, indent: []const u8) CsEmitError!void {
        switch (tail) {
            .none => {},
            .null_t => try self.writeFmt("{s}return null;\n", .{indent}),
            .default_t => try self.writeFmt("{s}return default;\n", .{indent}),
        }
    }

    /// The BODY of one effect arm, payload already bound. Shared by the
    /// simple and chained shapes — same node kinds as a terminal body, and
    /// `emitInlineContinuationBody` already lowers all of them. Returns true
    /// when the body ends in its own `return` (`expression`, `branch_
    /// constructor`) — the caller must then NOT append the `return null;` a
    /// void body still needs to satisfy `Func<dynamic>`. For `.invocation`
    /// the answer is deliberately conservative: a guarded terminal
    /// continuation leaves a fall-through path where the missing return is a
    /// CS0161 compile error, so the `null` stays — load-bearing when guarded,
    /// dead-but-silent when a continuation already returned.
    fn emitEffectArmBody(
        self: *Emitter,
        cont: *const ast.Continuation,
        indent: []const u8,
        expects_produce: bool,
    ) CsEmitError!bool {
        if (cont.node) |*node| {
            // `! step p -> mix(x: p)` — the bare invocation's result IS the
            // arm's resume produce; emitting it as a discarded statement and
            // tailing `return default` answers 0 instead of 42 (400_117).
            if (expects_produce and node.* == .invocation and cont.continuations.len == 0) {
                const inv = &node.invocation;
                if (inv.inline_body == null) {
                    if (self.resolveInvocationEvent(inv)) |callee| {
                        var callee_has_effect = false;
                        for (callee.branches) |b| {
                            if (b.kind == .effect) callee_has_effect = true;
                        }
                        if (!callee_has_effect) {
                            var ev_name_buf: [256]u8 = undefined;
                            const ev_name = self.eventClassName(&ev_name_buf, callee);
                            try self.writeFmt("{s}return main_module.{s}_event.handler(", .{ indent, ev_name });
                            try self.emitArgsObject(inv.args, callee, ev_name, null);
                            try self.write(");\n");
                            return true;
                        }
                    }
                }
            }
        }
        try self.emitInlineContinuationBody(cont, indent);
        const node = cont.node orelse return false;
        return switch (node) {
            .expression, .branch_constructor => true,
            else => false,
        };
    }

    /// Emit the STRUCT a call site instantiates as its ops argument — arm
    /// METHODS implementing `<ev>_event.IOps`, the `Handlers_N` fn-members
    /// analogue. Written into `ops_buf` (flushed at main_module scope);
    /// `init_buf` collects the call site's `new H { … }` entries — one
    /// `__cap_<n> = <n>` per captured flow local, and the Func value where a
    /// Func still answers (an optional-resuming prop, or a body whose free
    /// names the scan can't classify — the closure fallback).
    ///
    /// Member shapes:
    ///   installed arm          → `public <ret> <b>(<p>) { <body> }`
    ///   omitted optional void  → `public void <b>(<p>) { }`  (the noop fill)
    ///   omitted required       → no member; CS0535 names the site
    ///   optional resuming      → `public Func<…> <b> { get; set; }` (presence)
    ///   unclassifiable body    → `Func` field + a forwarding method
    fn emitOpsStructDecl(
        self: *Emitter,
        ev: *const ast.EventDecl,
        continuations: []const ast.Continuation,
        struct_name: []const u8,
        init_buf: *std.ArrayList(u8),
        init_indent: []const u8,
    ) CsEmitError!void {
        const saved_buf = self.buf;
        defer self.buf = saved_buf;

        // The struct lands at main_module scope — outside the event class —
        // so every generated type it names spells the qualified
        // `<ev>_event.<b>_…` reference.
        var ev_name_buf: [256]u8 = undefined;
        const ev_name = self.eventClassName(&ev_name_buf, ev);

        self.buf = &self.ops_buf;
        try self.writeFmt("  struct {s} : {s}_event.IOps {{\n", .{ struct_name, ev_name });

        for (ev.branches) |*b| {
            if (b.kind != .effect) continue;
            const installed = continuationForBranch(continuations, b.name) != null;

            // The arm body's produce envelope: a resume-sum arm produces
            // `new <ev>_event.<b>_resume { tag = "r", … }`, qualified so the
            // reference resolves inside the struct AND inside whichever
            // scope the init lambda lands in.
            const arm_env: ?[]const u8 = if (b.resume_arms != null)
                try resumeStructRef(self.allocator, ev_name, b.name, true)
            else
                null;
            defer if (arm_env) |e| self.allocator.free(e);

            // Optional RESUMING arm: presence is observable, so it keeps the
            // nullable Func surface — prop here, closure-bodied init below —
            // but the Func is TYPED to the arm's signature now: a wrong-typed
            // invoke fails at C# compile time instead of the runtime binder.
            if (optionalResumingArm(b)) {
                const ret = try armReturnCsType(self.allocator, ev_name, b, true);
                const param_t = try armParamCsType(self.allocator, ev_name, b, true);
                try self.write("    public global::System.Func<");
                if (!armIsPayloadless(b)) try self.writeFmt("{s}, ", .{param_t});
                try self.writeFmt("{s}> ", .{ret});
                try self.writeBinding(b.name);
                try self.write(" { get; set; }\n");
                if (installed) {
                    const param = try std.fmt.allocPrint(self.allocator, "__koru_arm_{d}", .{self.nextId()});
                    defer self.allocator.free(param);
                    self.buf = init_buf;
                    try self.write(init_indent);
                    try self.writeBinding(b.name);
                    try self.write(" = (global::System.Func<");
                    if (!armIsPayloadless(b)) try self.writeFmt("{s}, ", .{param_t});
                    try self.writeFmt("{s}>)(", .{ret});
                    if (!armIsPayloadless(b)) try self.write(param);
                    try self.write(" => ");
                    {
                        const saved_io = self.impl_out;
                        defer self.impl_out = saved_io;
                        self.impl_out = if (arm_env) |e| ImplOut{ .tagged = e } else .dynamic;
                        try self.emitArmBodyBlock(continuations, b.name, b, param, init_indent, if (std.mem.eql(u8, ret, "void")) .none else .default_t);
                    }
                    try self.write("),\n");
                    self.buf = &self.ops_buf;
                }
                continue;
            }

            if (!installed) {
                // Omitted OPTIONAL non-resuming arm — the always-callable
                // noop member; omitted REQUIRED arm — no member at all, so
                // CS0535 names the call site the way `@hasDecl` failure does.
                if (b.is_optional) {
                    try self.writeFmt("    public {s} ", .{try armReturnCsType(self.allocator, ev_name, b, true)});
                    try self.writeBinding(b.name);
                    try self.write("(");
                    if (!armIsPayloadless(b)) try self.writeFmt("{s} __koru_arg", .{try armParamCsType(self.allocator, ev_name, b, true)});
                    try self.write(") { }\n");
                }
                continue;
            }

            // Installed method arm — body to a scratch buffer first: the
            // capture scan decides whether the struct spells it as a METHOD
            // (with `__cap_*` fields) or as a Func field the method forwards
            // to (host-text locals and other unprovable free names keep the
            // closure that already answered them).
            const param = try std.fmt.allocPrint(self.allocator, "__koru_arm_{d}", .{self.nextId()});
            defer self.allocator.free(param);
            const ret = try armReturnCsType(self.allocator, ev_name, b, true);
            const tail: ArmTail = if (std.mem.eql(u8, ret, "void")) .none else .default_t;

            var body_buf: std.ArrayList(u8) = .empty;
            defer body_buf.deinit(self.allocator);
            self.buf = &body_buf;
            {
                const saved_io = self.impl_out;
                defer self.impl_out = saved_io;
                self.impl_out = if (arm_env) |e| ImplOut{ .tagged = e } else .dynamic;
                try self.emitArmBodyBlock(continuations, b.name, b, param, "      ", tail);
            }
            self.buf = &self.ops_buf;

            var scan = try self.scanArmBody(body_buf.items, ev, param);
            defer scan.captures.deinit(self.allocator);

            if (scan.needs_closure) {
                // Forwarder: the method is the static surface, the Func field
                // is the body — the lambda captures whatever the scan could
                // not prove, at the delegate-invoke cost measured before.
                // The field stays `Func<dynamic>` regardless of the method's
                // return — this IS the unclassifiable fallback, and a
                // dynamic return converts implicitly at the forward call —
                // so a void arm's body re-emits with the null tail a `Func`
                // conversion still requires.
                try self.write("    public global::System.Func<dynamic");
                if (!armIsPayloadless(b)) try self.write(", dynamic");
                try self.write("> __koru_fn_");
                try self.writeBinding(b.name);
                try self.write(";\n");
                try self.writeFmt("    public {s} ", .{ret});
                try self.writeBinding(b.name);
                try self.write("(");
                if (!armIsPayloadless(b)) try self.writeFmt("{s} {s}", .{ try armParamCsType(self.allocator, ev_name, b, true), param });
                try self.write(") => __koru_fn_");
                try self.writeBinding(b.name);
                try self.write("(");
                if (!armIsPayloadless(b)) {
                    // The Func's arg is dynamic — the body (written for the
                    // anonymous shape) reads `.f` through a REAL object, so
                    // the method re-wraps the typed payload struct's fields.
                    if (payloadIsRecord(b)) {
                        try self.write("new { ");
                        for (b.payload.fields, 0..) |f, i| {
                            if (i > 0) try self.write(", ");
                            try self.writeBinding(f.name);
                            try self.writeFmt(" = {s}.", .{param});
                            try self.writeBinding(f.name);
                        }
                        try self.write(" }");
                    } else {
                        try self.write(param);
                    }
                }
                try self.write(");\n");
                self.buf = init_buf;
                try self.write(init_indent);
                try self.write("__koru_fn_");
                try self.writeBinding(b.name);
                try self.write(" = (");
                if (!armIsPayloadless(b)) try self.write(param);
                try self.write(") => ");
                {
                    // The Func field is `Func<dynamic*>` — the body ALWAYS
                    // re-emits with the null tail (`return null;`), and
                    // anonymously: a `=> r` produce in a body the dynamic
                    // Func carries keeps the anonymous-object spelling.
                    var fn_buf: std.ArrayList(u8) = .empty;
                    defer fn_buf.deinit(self.allocator);
                    const saved = self.buf;
                    self.buf = &fn_buf;
                    {
                        const saved_io = self.impl_out;
                        defer self.impl_out = saved_io;
                        self.impl_out = .dynamic;
                        try self.emitArmBodyBlock(continuations, b.name, b, param, "      ", .null_t);
                    }
                    self.buf = saved;
                    try self.write(fn_buf.items);
                    self.buf = init_buf;
                }
                try self.write(",\n");
                self.buf = &self.ops_buf;
                continue;
            }

            // Method arm: `__cap_<n>` fields for the captured locals, the
            // initializer copies them in — Zig's const-capture, spelled.
            for (scan.captures.items) |cap| {
                try self.writeFmt("    public dynamic __cap_{s};\n", .{capFieldName(cap)});
            }
            const rewritten = try self.rewriteArmCaptures(body_buf.items, scan.captures.items);
            defer self.allocator.free(rewritten);
            try self.writeFmt("    public {s} ", .{ret});
            try self.writeBinding(b.name);
            try self.write("(");
            if (!armIsPayloadless(b)) try self.writeFmt("{s} {s}", .{ try armParamCsType(self.allocator, ev_name, b, true), param });
            try self.write(") ");
            try self.write(rewritten);
            try self.write("\n");
            self.buf = init_buf;
            for (scan.captures.items) |cap| {
                try self.writeFmt("{s}__cap_{s} = {s},\n", .{ init_indent, capFieldName(cap), cap });
            }
            self.buf = &self.ops_buf;
        }
        try self.write("  }\n");
    }

    /// What an emitted arm body reads from its enclosing method. `captures`
    /// are flow_locals found in reference position — they become `__cap_*`
    /// fields. `needs_closure` is anything the scan cannot prove — a
    /// host-text local, a lambda parameter, an unknown method name — those
    /// arms keep the closure (a Func field the method forwards to). The
    /// fallback is never wrong code: it is the pre-method shape, verbatim.
    const ArmScan = struct {
        captures: std.ArrayList([]const u8) = .empty,
        needs_closure: bool = false,
    };

    /// Classify the free identifiers of an emitted arm body. Member position
    /// (`.name`), object-initializer labels (`new { name = … }`), `var`
    /// declarations, the payload param, sibling arm names, and known globals
    /// are skipped; flow_locals become captures; anything else forces the
    /// closure fallback. Interpolated/verbatim strings hide references the
    /// scanner cannot see — their presence alone forwards.
    fn scanArmBody(
        self: *Emitter,
        body: []const u8,
        ev: *const ast.EventDecl,
        param: []const u8,
    ) CsEmitError!ArmScan {
        var scan = ArmScan{};
        errdefer scan.captures.deinit(self.allocator);
        if (std.mem.indexOf(u8, body, "$\"") != null or
            std.mem.indexOf(u8, body, "@\"") != null)
        {
            scan.needs_closure = true;
            return scan;
        }

        var toks: std.ArrayList(ArmTok) = .empty;
        defer toks.deinit(self.allocator);
        var declared: std.ArrayList([]const u8) = .empty;
        defer declared.deinit(self.allocator);
        try self.tokenizeArmBody(body, &toks, &declared);

        for (toks.items) |tok| {
            if (tok.member or tok.label) continue;
            const name = tok.text;
            var is_declared = false;
            for (declared.items) |d| {
                if (std.mem.eql(u8, d, name)) is_declared = true;
            }
            if (is_declared) continue;
            if (std.mem.eql(u8, name, param)) continue;
            var is_local = false;
            for (self.flow_locals.items) |n| {
                if (std.mem.eql(u8, n, name)) {
                    is_local = true;
                    var seen = false;
                    for (scan.captures.items) |c| {
                        if (std.mem.eql(u8, c, name)) seen = true;
                    }
                    if (!seen) try scan.captures.append(self.allocator, name);
                }
            }
            if (is_local) continue;
            var is_arm = false;
            for (ev.branches) |b| {
                if (b.kind != .effect) continue;
                var nb: [256]u8 = undefined;
                if (b.name.len <= nb.len) {
                    const lowered = lowerIdentBuf(&nb, b.name);
                    var spelled: [257]u8 = undefined;
                    const cmp = if (codegen_utils.isCsReservedForEmit(lowered)) blk: {
                        spelled[0] = '@';
                        @memcpy(spelled[1 .. lowered.len + 1], lowered);
                        break :blk spelled[0 .. lowered.len + 1];
                    } else lowered;
                    if (std.mem.eql(u8, name, cmp)) is_arm = true;
                }
            }
            if (is_arm) continue;
            if (std.mem.startsWith(u8, name, "__koru_") or
                std.mem.startsWith(u8, name, "result_") or
                std.mem.startsWith(u8, name, "__cap_") or
                std.mem.endsWith(u8, name, "_event") or
                isFlowMethodName(name) or
                isArmGlobalWord(name)) continue;
            scan.needs_closure = true;
        }
        return scan;
    }

    /// Rewrite `cap` references in `body` to `__cap_<n>` field reads — the
    /// same tokenizer as the scan: member position and initializer labels
    /// are left alone (a `new { count = … }` key is a member name, not a
    /// reference).
    fn rewriteArmCaptures(
        self: *Emitter,
        body: []const u8,
        captures: []const []const u8,
    ) CsEmitError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        var lit_stack: std.ArrayList(usize) = .empty;
        defer lit_stack.deinit(self.allocator);
        var brace_depth: usize = 0;
        var pending_new = false;
        var prev_nonspace: u8 = 0;
        while (i < body.len) {
            const c = body[i];
            if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
                const end = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
                try out.appendSlice(self.allocator, body[i..end]);
                i = end;
                continue;
            }
            if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, body, i + 2, "*/") orelse body.len - 1;
                try out.appendSlice(self.allocator, body[i .. @min(body.len, end + 2)]);
                i = @min(body.len, end + 2);
                continue;
            }
            if (c == '"' or c == '\'') {
                const q = c;
                var j = i + 1;
                while (j < body.len and body[j] != q) {
                    if (body[j] == '\\') j += 1;
                    j += 1;
                }
                j = @min(body.len, j + 1);
                try out.appendSlice(self.allocator, body[i..j]);
                i = j;
                prev_nonspace = q;
                continue;
            }
            if (isArmIdentStart(c) or (c == '@' and i + 1 < body.len and isArmIdentStart(body[i + 1]))) {
                const start = i;
                if (c == '@') i += 1;
                while (i < body.len and isArmIdentChar(body[i])) i += 1;
                const tok = body[start..i];
                const member = prev_nonspace == '.';
                var j = i;
                while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
                const label = lit_stack.items.len > 0 and j < body.len and body[j] == '=' and
                    (j + 1 >= body.len or (body[j + 1] != '=' and body[j + 1] != '>'));
                var is_cap = false;
                if (!member and !label) {
                    for (captures) |cap| {
                        if (std.mem.eql(u8, cap, tok)) is_cap = true;
                    }
                }
                if (is_cap) {
                    try out.appendSlice(self.allocator, "__cap_");
                    try out.appendSlice(self.allocator, capFieldName(tok));
                } else {
                    try out.appendSlice(self.allocator, tok);
                }
                if (std.mem.eql(u8, tok, "new")) pending_new = true;
                prev_nonspace = tok[tok.len - 1];
                continue;
            }
            if (c == '{') {
                brace_depth += 1;
                if (pending_new) {
                    try lit_stack.append(self.allocator, brace_depth);
                    pending_new = false;
                }
            } else if (c == '}') {
                if (lit_stack.items.len > 0 and lit_stack.items[lit_stack.items.len - 1] == brace_depth) {
                    _ = lit_stack.pop();
                }
                brace_depth -= 1;
            } else if (c == '(' or c == ';' or c == '=') {
                pending_new = false;
            }
            if (!std.ascii.isWhitespace(c)) prev_nonspace = c;
            try out.append(self.allocator, c);
            i += 1;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Tokenize an arm body into candidate-reference identifiers plus the
    /// `var`-declared names that exclude them. Shares the string/comment/
    /// initializer-label rules with `rewriteArmCaptures`.
    fn tokenizeArmBody(
        self: *Emitter,
        body: []const u8,
        toks: *std.ArrayList(ArmTok),
        declared: *std.ArrayList([]const u8),
    ) CsEmitError!void {
        var i: usize = 0;
        var lit_stack: std.ArrayList(usize) = .empty;
        defer lit_stack.deinit(self.allocator);
        var brace_depth: usize = 0;
        var pending_new = false;
        var pending_var = false;
        var prev_nonspace: u8 = 0;
        while (i < body.len) {
            const c = body[i];
            if (c == '/' and i + 1 < body.len and body[i + 1] == '/') {
                const end = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
                i = end;
                continue;
            }
            if (c == '/' and i + 1 < body.len and body[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, body, i + 2, "*/") orelse body.len - 1;
                i = @min(body.len, end + 2);
                continue;
            }
            if (c == '"' or c == '\'') {
                const q = c;
                i += 1;
                while (i < body.len and body[i] != q) {
                    if (body[i] == '\\') i += 1;
                    i += 1;
                }
                if (i < body.len) i += 1;
                prev_nonspace = q;
                continue;
            }
            if (isArmIdentStart(c) or (c == '@' and i + 1 < body.len and isArmIdentStart(body[i + 1]))) {
                const start = i;
                if (c == '@') i += 1;
                while (i < body.len and isArmIdentChar(body[i])) i += 1;
                const tok = body[start..i];
                const member = prev_nonspace == '.';
                var j = i;
                while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
                const label = lit_stack.items.len > 0 and j < body.len and body[j] == '=' and
                    (j + 1 >= body.len or (body[j + 1] != '=' and body[j + 1] != '>'));
                if (std.mem.eql(u8, tok, "var")) {
                    pending_var = true;
                } else if (std.mem.eql(u8, tok, "new")) {
                    pending_new = true;
                    pending_var = false;
                } else if (pending_var and !member) {
                    try declared.append(self.allocator, tok);
                    pending_var = false;
                } else {
                    pending_var = false;
                    if (!member and !label and !isArmKeyword(tok)) {
                        try toks.append(self.allocator, .{ .text = tok, .member = member, .label = label });
                    }
                }
                prev_nonspace = tok[tok.len - 1];
                continue;
            }
            if (c == '{') {
                brace_depth += 1;
                if (pending_new) {
                    try lit_stack.append(self.allocator, brace_depth);
                    pending_new = false;
                }
            } else if (c == '}') {
                if (lit_stack.items.len > 0 and lit_stack.items[lit_stack.items.len - 1] == brace_depth) {
                    _ = lit_stack.pop();
                }
                brace_depth -= 1;
            } else if (c == '(' or c == ';' or c == '=') {
                pending_new = false;
            }
            if (!std.ascii.isWhitespace(c)) prev_nonspace = c;
            i += 1;
        }
    }

    /// Emit a FIRE of one of the enclosing tor's own effect arms. The handler
    /// already bound every arm to a bare name — a local-function shim for a
    /// method arm, a `var` alias for an optional-resuming Func — so the fire
    /// is a plain call. A void arm is a bare statement; a resuming arm's
    /// value binds to the call-site `: name` or dispatches through the
    /// ordinary terminal-continuation path.
    fn emitEffectArmFire(
        self: *Emitter,
        arm: *const ast.Branch,
        inv: *const ast.Invocation,
        continuations: []const ast.Continuation,
        indent: []const u8,
    ) CsEmitError!void {
        const has_resume = arm.resume_type != null or arm.resume_arms != null;

        var terminal_count: usize = 0;
        var needs_result = false;
        for (continuations) |*cont| {
            if (cont.kind != .terminal) continue;
            terminal_count += 1;
            if (cont.binding != null and !std.mem.eql(u8, cont.binding.?, "_")) needs_result = true;
        }
        if (terminal_count >= 2) needs_result = true;
        if (namedReturnBinding(inv) != null) needs_result = true;
        if (!has_resume) needs_result = false;

        const result_name: ?[]const u8 = if (!needs_result) null else if (namedReturnBinding(inv)) |rb|
            try self.dupeSpelled(rb)
        else blk: {
            const rid = self.nextId();
            break :blk try std.fmt.allocPrint(self.allocator, "result_{d}", .{rid});
        };
        defer if (result_name) |rn| self.allocator.free(rn);

        // An OPTIONAL RESUMING arm may simply not be installed — the alias is
        // null, and the fire plus everything consuming its result lives
        // inside a presence guard. (Optional VOID arms are always-callable:
        // the ops struct fills a shared noop, so no guard is needed — the
        // `@hasDecl ? __H.x : noop` contract.)
        const guard_presence = arm.is_optional and has_resume;
        var fire_indent = indent;
        if (guard_presence) {
            try self.write(indent);
            try self.write("if (");
            try self.writeBinding(arm.name);
            try self.write(" != null) {\n");
            fire_indent = try std.fmt.allocPrint(self.allocator, "{s}  ", .{indent});
        }
        defer if (guard_presence) self.allocator.free(fire_indent);

        try self.write(fire_indent);
        if (result_name) |rn| {
            try self.writeFmt("var {s} = ", .{rn});
            try self.registerLocal(rn);
        }
        try self.writeBinding(arm.name);
        try self.write("(");
        try self.emitArmFirePayload(arm, inv);
        try self.write(");\n");

        // A single `-> T` resume hands back the value untagged; only a
        // multi-arm resume sum carries a `.tag`.
        const plain_resume = arm.resume_type != null and arm.resume_arms == null;
        const needs_dispatch = terminal_count >= 2 and !plain_resume;
        try self.emitTerminalContinuations(continuations, null, result_name, fire_indent, needs_dispatch, plain_resume);
        if (guard_presence) try self.writeFmt("{s}}}\n", .{indent});
    }

    /// The payload passed to an arm fire, in C# spelling:
    ///   payloadless arm → nothing (`ask()`)
    ///   identity / wildcard payload → the single arg's value (`each(i * i)`)
    ///   named-field payload → `new <arm>_payload { f = v, … }` — the
    ///     generated struct the arm's signature declares. The struct is
    ///     nested in the firing tor's event class, resolved through
    ///     impl_event and spelled qualified so the reference is legal at
    ///     either scope the fire text can land in.
    fn emitArmFirePayload(self: *Emitter, arm: *const ast.Branch, inv: *const ast.Invocation) CsEmitError!void {
        if (arm.payload.fields.len == 0 and !arm.payload.is_wildcard) return;

        const is_identity = arm.payload.fields.len == 1 and
            std.mem.eql(u8, arm.payload.fields[0].name, "__type_ref");
        if (is_identity or arm.payload.is_wildcard) {
            if (inv.args.len > 0) try self.writeCsExpr(inv.args[0].value);
            return;
        }

        if (payloadIsRecord(arm)) {
            var evb: [256]u8 = undefined;
            const ev_name: []const u8 = if (self.impl_event) |ie|
                self.eventClassName(&evb, ie)
            else
                "";
            const ptype = try payloadStructRef(self.allocator, ev_name, arm.name, ev_name.len > 0);
            defer self.allocator.free(ptype);
            // A single POSITIONAL arg is the whole record — `token({k: v})`.
            // A braced literal spells the struct's member-init directly; a
            // named value (a tuple-typed local, the old record spelling)
            // converts field-by-field — C# tuples keep element names, so
            // `rec.kind` reads straight off it.
            if (inv.args.len == 1 and inv.args[0].name.len == 0) {
                const v = std.mem.trim(u8, inv.args[0].value, " \t\r\n");
                if (v.len > 0 and v[0] == '{') {
                    try self.writeRecordPayloadInit(arm.name, v);
                    return;
                }
                try self.writeFmt("new {s} {{ ", .{ptype});
                for (arm.payload.fields, 0..) |f, i| {
                    if (i > 0) try self.write(", ");
                    try self.writeBinding(f.name);
                    try self.write(" = (");
                    try self.writeCsExpr(v);
                    try self.write(").");
                    try self.writeBinding(f.name);
                }
                try self.write(" }");
                return;
            }
            try self.writeFmt("new {s} {{ ", .{ptype});
            var wrote = false;
            for (arm.payload.fields) |f| {
                const arg = findArgForField(inv.args, f.name);
                if (wrote) try self.write(", ");
                try self.writeBinding(f.name);
                try self.write(" = ");
                if (arg) |a| {
                    try self.writeCsExpr(a.value);
                } else {
                    try self.writeFmt("default({s})", .{csType(f.type)});
                }
                wrote = true;
            }
            try self.write(" }");
            return;
        }

        try self.write("new { ");
        for (inv.args, 0..) |arg, i| {
            if (i > 0) try self.write(", ");
            try self.writeBinding(arg.name);
            try self.write(" = ");
            try self.writeCsExpr(arg.value);
        }
        try self.write(" }");
    }
};

/// How a generated impl spells its produces — the typed-envelope port of
/// zig's `Input`/`Output` pair. Zig's handler is `fn(Input) Output` where
/// Output is a `union(enum)` for branch tors and the declared `-> T` for
/// bare-return tors; C# has no union, so the branch-tor Output is a struct
/// carrying `tag` plus one field per terminal branch.
const ImplOut = union(enum) {
    dynamic,
    /// `=> b` → `new <env> { tag = "b", … }`. The envelope name is the
    /// whole point: `"Output"` inside an event class, the qualified
    /// `"<ev>_event.<arm>_resume"` inside arm bodies (ops structs and
    /// lambdas live at main_module scope, outside the class).
    tagged: []const u8,
    bare: []const u8, // `-> expr` → `return (<T>)(<expr>)` — T is the C# spelling
};

// The Koru→C# type spelling lives in codegen_utils — shared with the
// `@as` builtin lowering so the two sites can never drift on it.
const csType = codegen_utils.csType;

/// The declared C# type of an Input field. `Expression` params transport
/// the argument's SOURCE TEXT — the call site emits a string literal, so
/// the honest member type is `string`, not the escape-hatch `dynamic`.
/// `Source` params stay `dynamic`: the call site hands an anonymous
/// `new { text = "…" }` record and the body members `.text` off it —
/// exactly the late binding `dynamic` exists for.
fn csInputFieldType(field: ast.Field) []const u8 {
    if (field.is_expression) return "string";
    if (field.is_source) return "dynamic";
    return csType(field.type);
}

/// A named-record payload — one or more declared fields that are not the
/// `__type_ref` identity marker — gets a generated `<b>_payload` struct
/// nested in the event class. Wildcard and payloadless shapes do not.
fn payloadIsRecord(b: *const ast.Branch) bool {
    if (b.payload.is_wildcard or b.payload.fields.len == 0) return false;
    return !(b.payload.fields.len == 1 and
        std.mem.eql(u8, b.payload.fields[0].name, "__type_ref"));
}

/// `<b>_payload` into a caller buffer — kebab/dot folded, and NOT routed
/// through csPayloadName: the `tag`→`__ktag` escape is a MEMBER-position
/// fix, while the struct name `tag_payload` never collides (the `_payload`
/// suffix also escapes keywords, so no @-mangle is needed). The same
/// spelling codegen_utils.HostShape.csMember + "_payload" produces for
/// transform-authored text — the two must agree.
fn payloadStructNameBuf(buf: []u8, bname: []const u8) []const u8 {
    const lowered = Emitter.lowerIdentBuf(buf, bname);
    const n = lowered.len;
    @memcpy(buf[n .. n + "_payload".len], "_payload");
    return buf[0 .. n + "_payload".len];
}

/// The payload struct's name as a REFERENCE — bare `<b>_payload` inside
/// the event class, `<ev>_event.<b>_payload` at main_module scope.
fn payloadStructRef(allocator: std.mem.Allocator, ev_name: []const u8, bname: []const u8, qualified: bool) CsEmitError![]const u8 {
    var nb: [300]u8 = undefined;
    const pname = if (bname.len + "_payload".len <= nb.len)
        payloadStructNameBuf(&nb, bname)
    else
        return CsEmitError.OutOfMemory;
    if (qualified) {
        return std.fmt.allocPrint(allocator, "{s}_event.{s}", .{ ev_name, pname });
    }
    return allocator.dupe(u8, pname);
}

/// The resume-sum struct's name as a reference — same scoping rule.
fn resumeStructRef(allocator: std.mem.Allocator, ev_name: []const u8, bname: []const u8, qualified: bool) CsEmitError![]const u8 {
    var nb: [300]u8 = undefined;
    const lowered = if (bname.len <= nb.len - "_resume".len) blk: {
        const l = Emitter.lowerIdentBuf(&nb, bname);
        @memcpy(nb[l.len .. l.len + "_resume".len], "_resume");
        break :blk nb[0 .. l.len + "_resume".len];
    } else return CsEmitError.OutOfMemory;
    if (qualified) {
        return std.fmt.allocPrint(allocator, "{s}_event.{s}", .{ ev_name, lowered });
    }
    return allocator.dupe(u8, lowered);
}

/// An arm whose ABSENCE is observable — `! ?ask -> T`. It alone keeps the
/// nullable-Func surface: `ask != null` in impl text is the presence read,
/// and a method member has no absent spelling. Every other arm is a method —
/// omitted optional voids included (`{ }` is the `@hasDecl ? __H.x : noop`
/// fill, cheaper than the shared-delegate trick it replaces).
fn optionalResumingArm(b: *const ast.Branch) bool {
    return b.is_optional and (b.resume_type != null or b.resume_arms != null);
}

/// The C# return type of an arm's METHOD. `-> T` → T's spelling, a resume
/// sum → the generated `<b>_resume` struct (the arm-tag object made
/// nominal), void otherwise. A produce inside a void arm is refused by the
/// C# compiler — the same refusal zig's `fn tick() void` hands a
/// `return .{ .done = … }`. `qualified` picks the reference spelling:
/// bare inside the event class, `<ev>_event.`-prefixed outside.
fn armReturnCsType(allocator: std.mem.Allocator, ev_name: []const u8, b: *const ast.Branch, qualified: bool) CsEmitError![]const u8 {
    if (b.resume_arms != null) return try resumeStructRef(allocator, ev_name, b.name, qualified);
    if (b.resume_type) |rt| return csType(rt);
    return "void";
}

/// The C# parameter type of an arm's METHOD — identity payloads take the
/// declared type; named-field payloads take the generated `<b>_payload`
/// struct; wildcard stays `dynamic` (its members cannot be named).
/// `qualified` picks the reference spelling — see armReturnCsType.
fn armParamCsType(allocator: std.mem.Allocator, ev_name: []const u8, b: *const ast.Branch, qualified: bool) CsEmitError![]const u8 {
    if (b.payload.fields.len == 1 and
        std.mem.eql(u8, b.payload.fields[0].name, "__type_ref"))
    {
        return csType(b.payload.fields[0].type);
    }
    if (payloadIsRecord(b)) return try payloadStructRef(allocator, ev_name, b.name, qualified);
    return "dynamic";
}

/// The C# type of a terminal branch's payload member in `Output`. `| done
/// i64` is an identity payload — one `__type_ref` field — so `done` is
/// `long`; a record payload is the generated `<b>_payload` struct; a
/// wildcard stays `dynamic` (its members cannot be named); a payloadless
/// branch's member is `object` — it exists so `result.b` reads compile,
/// and storage is all it needs.
fn branchPayloadCsType(allocator: std.mem.Allocator, b: *const ast.Branch) CsEmitError![]const u8 {
    if (b.payload.fields.len == 1 and
        std.mem.eql(u8, b.payload.fields[0].name, "__type_ref"))
    {
        return csType(b.payload.fields[0].type);
    }
    if (payloadIsRecord(b)) {
        var nb: [256]u8 = undefined;
        const lowered = if (b.name.len <= nb.len) Emitter.lowerIdentBuf(&nb, b.name) else b.name;
        return std.fmt.allocPrint(allocator, "{s}_payload", .{lowered});
    }
    if (b.payload.is_wildcard) return "dynamic";
    return "object";
}

/// Find the tor's branch decl for `name` — the fire-signature decl a
/// Handlers member must match arity against.
fn findBranchDecl(ev: *const ast.EventDecl, name: []const u8) ?*const ast.Branch {
    for (ev.branches) |*b| {
        if (b.kind == .effect and std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// Does this arm's fire take no payload — `tick()` rather than `beep(7)`?
/// The opaque proc body spells the call literally, so the installed delegate
/// must accept exactly the args the decl declares.
fn armIsPayloadless(arm: *const ast.Branch) bool {
    return arm.payload.fields.len == 0 and !arm.payload.is_wildcard;
}

/// Does a continuation set install a handler for `op`?
fn continuationForBranch(continuations: []const ast.Continuation, op: []const u8) ?*const ast.Continuation {
    for (continuations) |*cont| {
        if (cont.kind == .effect and std.mem.eql(u8, cont.branch, op)) return cont;
    }
    return null;
}

/// Does this proc declare `[template]` and apply to the cs build? A null
/// target is target-agnostic, `|cs` is ours, anything else is not.
fn templateProcTargetsCs(proc: *const ast.ProcDecl) bool {
    var annotated = false;
    for (proc.annotations) |ann| {
        if (std.mem.eql(u8, ann, "template")) {
            annotated = true;
            break;
        }
    }
    if (!annotated) return false;
    const target = proc.target orelse return true;
    return std.mem.eql(u8, target, CS_TARGET);
}

/// Strip the leading `//@koru:inline_stmt\n` marker that template_processor
/// prepends to a statement-shaped rendered body.
fn stripInlineStmtMarker(text: []const u8) []const u8 {
    const marker = "//@koru:inline_stmt\n";
    if (std.mem.startsWith(u8, text, marker)) return text[marker.len..];
    return text;
}

/// A free-identifier token from the arm-body scan: `member` is `.name`
/// position (a field/label, never a local reference); `label` is the
/// initializer-label position inside `new { … }`/`new T { … }`.
const ArmTok = struct {
    text: []const u8,
    member: bool,
    label: bool,
};

/// The `__cap_*` field suffix for a captured local — the flow_locals
/// spelling minus its `@` escape (`@base` → `base`). Captured names are
/// already kebab-lowered.
fn capFieldName(spelled: []const u8) []const u8 {
    if (spelled.len > 0 and spelled[0] == '@') return spelled[1..];
    return spelled;
}

/// The name as it appears in emitted text: kebab-lowered, `@`-escaped when
/// reserved. Buffers the `@` ahead of the lowered name — writeBinding's
/// spelling as a string.
fn spelledName(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len + 1 > buf.len) return null;
    var i: usize = 0;
    if (name.len <= buf.len - 1) {
        var stem_buf: [256]u8 = undefined;
        if (name.len > stem_buf.len) return null;
        for (name, 0..) |c, k| stem_buf[k] = if (c == '-' or c == '.') '_' else c;
        if (codegen_utils.isCsReservedForEmit(stem_buf[0..name.len])) {
            buf[0] = '@';
            i = 1;
        }
    }
    for (name) |c| {
        buf[i] = if (c == '-' or c == '.') '_' else c;
        i += 1;
    }
    return buf[0..i];
}

fn isArmIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isArmIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// `flow0`…`flowN` — the sibling method names a body's identifier can never
/// be: koru bindings do not lower to that shape, so the check is exact.
fn isFlowMethodName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "flow") or name.len <= 4) return false;
    for (name[4..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// C# keywords plus the handful of framework/main-module names that resolve
/// without being captures. Anything missing here costs a closure fallback —
/// conservative, never wrong.
fn isArmKeyword(name: []const u8) bool {
    const words = [_][]const u8{
        "var",       "new",      "return",   "if",       "else",    "for",
        "foreach",   "while",    "do",       "switch",   "case",    "break",
        "continue",  "default",  "try",      "catch",    "finally", "throw",
        "in",        "out",      "ref",      "is",       "as",      "typeof",
        "nameof",    "sizeof",   "checked",  "unchecked", "lock",   "dynamic",
        "object",    "string",   "long",     "int",      "short",   "byte",
        "sbyte",     "uint",     "ulong",    "ushort",   "double",  "float",
        "bool",      "char",     "void",     "static",   "public",  "private",
        "internal",  "protected", "sealed",  "abstract", "virtual", "override",
        "readonly",  "const",    "volatile", "struct",   "class",   "interface",
        "enum",      "delegate", "event",    "namespace", "get",    "set",
        "value",     "params",   "implicit", "explicit", "operator", "await",
        "async",     "yield",    "with",     "init",     "record",  "null",
        "true",      "false",    "base",     "this",
    };
    for (words) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// Names that resolve at class/framework scope inside generated bodies —
/// never captures. The `_event` suffix gets its own check upstream.
fn isArmGlobalWord(name: []const u8) bool {
    const words = [_][]const u8{
        "main_module",  "Program",  "ops",    "__koru_input", "global",
        "System",       "Console",  "Math",   "Convert",      "Exception",
        "String",       "Int64",    "Int32",  "Double",       "Boolean",
        "Object",       "Array",    "List",   "Dictionary",   "DateTime",
        "Task",         "Func",     "Action", "Tuple",        "ValueTuple",
        "Enumerable",   "StringBuilder", "Guid", "Random",    "Environment",
    };
    for (words) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// Is `path` a bare reference to one of `event`'s own EFFECT arms?
fn findEffectArm(event: *const ast.EventDecl, path: *const ast.DottedPath) ?*const ast.Branch {
    if (path.segments.len != 1) return null;
    if (path.module_qualifier) |mq| {
        if (event.path.module_qualifier) |emq| {
            if (!std.mem.eql(u8, mq, emq)) return null;
        }
    }
    for (event.branches) |*b| {
        if (b.kind == .effect and std.mem.eql(u8, b.name, path.segments[0])) return b;
    }
    return null;
}

/// `$mod.` → `main_module.` — the sanctioned module-scope spelling resolves
/// to the named static class on C#, where JS's file scope made it bare.
/// Skips string/char literal contents.
fn csModQualify(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, body.len + 32);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var q: u8 = 0;
    while (i < body.len) {
        const c = body[i];
        if (q != 0) {
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < body.len) {
                try out.append(allocator, body[i + 1]);
                i += 2;
                continue;
            }
            if (c == q) q = 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            q = c;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '$' and i + 5 < body.len and std.mem.eql(u8, body[i .. i + 5], "$mod.")) {
            try out.appendSlice(allocator, "main_module.");
            i += 5;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// True when the invocation asks for its preamble AND its handler call — the
/// `@preamble_then_call` contract. Every other preamble REPLACES the call.
fn preambleThenCall(inv: *const ast.Invocation) bool {
    for (inv.marks) |ann| {
        if (std.mem.eql(u8, ann, "@preamble_then_call")) return true;
    }
    return false;
}

fn pathsEqual(a: *const ast.DottedPath, b: *const ast.DottedPath) bool {
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

/// `long` ends with `short` on a `.`/`:` boundary — so `std.io` matches `io`.
fn qualifierSuffixMatch(long: []const u8, short: []const u8) bool {
    if (long.len <= short.len) return false;
    if (!std.mem.endsWith(u8, long, short)) return false;
    const sep = long[long.len - short.len - 1];
    return sep == '.' or sep == ':';
}

/// Two module qualifiers refer to the same module if equal, or one is a
/// dotted suffix of the other (`std.io` ≡ `io`).
fn moduleQualifiersMatch(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return qualifierSuffixMatch(a, b) or qualifierSuffixMatch(b, a);
}

/// Impl-target binding is stricter than call-site resolution: a qualified
/// target names that module's event and nothing else, while an unqualified
/// target means the event in the impl's OWN enclosing module. Compare each
/// side's EFFECTIVE module — the qualifier when present, else the decl's
/// home (or the main module for unqualified events).
fn implTargetsEvent(
    event_path: *const ast.DottedPath,
    target_path: *const ast.DottedPath,
    impl_home: []const u8,
    main_module: []const u8,
) bool {
    const ev_eff = event_path.module_qualifier orelse main_module;
    const t_eff = target_path.module_qualifier orelse impl_home;
    if (!moduleQualifiersMatch(ev_eff, t_eff)) return false;
    return pathsEqual(event_path, target_path);
}

/// Module-aware path equality — declaration path vs call-site path, with
/// the qualifier reconciled against the effective module context.
fn pathsEqualWithModule(
    decl_path: *const ast.DottedPath,
    inv_path: *const ast.DottedPath,
    current_module: ?[]const u8,
    main_module: []const u8,
) bool {
    const a_mod = decl_path.module_qualifier;
    const b_mod = inv_path.module_qualifier;
    if (a_mod != null and b_mod != null) {
        if (!moduleQualifiersMatch(a_mod.?, b_mod.?)) return false;
    } else if ((a_mod != null) != (b_mod != null)) {
        const qual = if (a_mod != null) a_mod.? else b_mod.?;
        const effective = current_module orelse main_module;
        if (effective.len == 0) return false;
        if (!moduleQualifiersMatch(effective, qual)) return false;
    }
    if (decl_path.segments.len != inv_path.segments.len) return false;
    for (decl_path.segments, inv_path.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

/// Does this continuation (or any nested sequel) loop back to `label`?
/// Mirrors js_emitter.zig:3196 — an arm whose sequel contains `@L(…)`
/// belongs INSIDE the fold's `while`; the rest run after it.
fn contLoopsTo(cont: *const ast.Continuation, label: []const u8) bool {
    if (cont.node) |node| switch (node) {
        .label_jump => |lj| if (std.mem.eql(u8, lj.label, label)) return true,
        .label_apply => |l| if (std.mem.eql(u8, l, label)) return true,
        else => {},
    };
    for (cont.continuations) |*nested| {
        if (contLoopsTo(nested, label)) return true;
    }
    return false;
}

/// `&name` — the only borrow spelling `arg.value` can carry — returns the
/// borrowed ident. `&f(x)` and `&(a + b)` are not borrows and keep falling
/// through to the expression lowering, where the raw `&` becomes a compile
/// error rather than a wrong answer.
fn borrowTarget(value: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (t.len < 2 or t[0] != '&') return null;
    const name = t[1..];
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch == '-';
        if (!ok) return null;
    }
    return name;
}
