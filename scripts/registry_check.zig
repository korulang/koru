// registry_check.zig — diagnostic-code registry coherence watcher
//
// HEAD-CARRIED TRUST: `src/errors.zig` ErrorCode enum is the single source of truth
// for diagnostic codes. Nothing keeps the things that reference it honest. This watcher
// makes that trust visible by materializing three sets and diffing them:
//
//   DECLARED = members of the `pub const ErrorCode = enum(u16)` block in src/errors.zig
//   EMITTED  = codes the compiler actually uses:  `.KORUxxx` enum-tags + `error[KORUxxx]`
//              literals across src/ (errors.zig INCLUDED — its helper fns emit, e.g.
//              moduleNotFound -> .KORU002; the bare enum-declaration lines are space-
//              prefixed so they never match the emit filter)
//   PINNED   = codes asserted by the regression suite: `error[KORUxxx]` in tests/regression
//
// It FIRES (exit 1) on any of three drifts:
//   ORPHAN_EMIT = EMITTED \ DECLARED  — a code emitted that the dictionary never declared
//   DEAD        = DECLARED \ EMITTED  — a declared code nothing emits (a lie: claims the
//                 compiler catches something it doesn't), minus an explicit reserved-list
//   ROTTEN_PIN  = PINNED \ DECLARED   — a test pinned to a code that can't resolve
//
// For each DEAD code it prints the DIAGNOSIS, not just the symptom: the declaring
// file:line, the emitted siblings in its family with site-counts, and the bug-vs-reserved
// signal (a lone gap in an emitted family is almost always an unwired BUG; a whole-family
// gap is almost always an unbuilt detector = RESERVED). Then the two-lever remedy.
//
// Reserved-but-unimplemented codes are whitelisted in scripts/registry_reserved.txt
// (one bare code per line below the marker; rationale on a preceding `#` line).
//
// Run from the koru repo root:  zig run scripts/registry_check.zig
// This is the lean first watcher of the `wm` toolchain (FACT-only; no judge).

const std = @import("std");

const CountMap = std.StringHashMap(u32);
const LineMap = std.StringHashMap(usize);
const DescMap = std.StringHashMap([]const u8); // code -> its enum-comment description
const Set = std.StringHashMap(void);

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Match a diagnostic-code token at the START of `s`: >=3 uppercase letters then >=3 digits.
/// Returns the token length, or 0 if `s` does not start with one.
fn codeAt(s: []const u8) usize {
    var j: usize = 0;
    while (j < s.len and isUpper(s[j])) j += 1;
    if (j < 3) return 0;
    var k = j;
    while (k < s.len and isDigit(s[k])) k += 1;
    if (k - j < 3) return 0;
    return k;
}

/// The "family" of a code = the code minus its last digit (PARSE002 -> PARSE00,
/// KORU061 -> KORU06). Groups siblings that share an error class/section.
fn familyOf(code: []const u8) []const u8 {
    return if (code.len > 0) code[0 .. code.len - 1] else code;
}

fn bump(a: std.mem.Allocator, map: *CountMap, tok: []const u8) !void {
    if (map.getPtr(tok)) |p| {
        p.* += 1;
    } else {
        try map.put(try a.dupe(u8, tok), 1);
    }
}

const Mode = enum { emit, pin };

/// Scan `content` for code tokens matching `mode`'s context filter, counting into `map`.
fn collect(a: std.mem.Allocator, map: *CountMap, content: []const u8, mode: Mode) !void {
    var i: usize = 0;
    while (i < content.len) {
        if (isUpper(content[i])) {
            const len = codeAt(content[i..]);
            if (len > 0) {
                const tok = content[i .. i + len];
                const prev: u8 = if (i > 0) content[i - 1] else 0;
                const take = switch (mode) {
                    .emit => prev == '.' or prev == '[', // `.KORU030` or `error[KORU200]`
                    .pin => prev == '[', // `error[KORU030]` in an expected_error.txt
                };
                if (take) try bump(a, map, tok);
                i += len;
                continue;
            }
        }
        i += 1;
    }
}

fn collectTree(a: std.mem.Allocator, map: *CountMap, root: []const u8, ext: []const u8, mode: Mode) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ext)) continue;
        const content = dir.readFileAlloc(a, entry.path, 16 * 1024 * 1024) catch continue;
        try collect(a, map, content, mode);
    }
}

fn collectPins(a: std.mem.Allocator, map: *CountMap, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const b = entry.basename;
        if (!(std.mem.startsWith(u8, b, "expected") or std.mem.eql(u8, b, "EXPECT"))) continue;
        const content = dir.readFileAlloc(a, entry.path, 16 * 1024 * 1024) catch continue;
        try collect(a, map, content, .pin);
    }
}

/// DECLARED — parse the `pub const ErrorCode = enum(u16) { ... };` block line-by-line,
/// recording each member code -> its 1-based line number in src/errors.zig.
fn collectDeclared(a: std.mem.Allocator, lines: *LineMap, descs: *DescMap, src: []const u8) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var lineno: usize = 0;
    var inside = false;
    while (it.next()) |raw| {
        lineno += 1;
        if (!inside) {
            if (std.mem.indexOf(u8, raw, "pub const ErrorCode = enum(u16) {") != null) inside = true;
            continue;
        }
        const t = std.mem.trimLeft(u8, raw, " \t");
        if (std.mem.startsWith(u8, t, "};")) break;
        const len = codeAt(t);
        if (len > 0 and len < t.len and t[len] == ',') {
            const code = try a.dupe(u8, t[0..len]);
            try lines.put(code, lineno);
            // description = the trailing `// ...` comment, if any.
            var desc: []const u8 = "";
            if (std.mem.indexOf(u8, t, "//")) |ci| desc = std.mem.trim(u8, t[ci + 2 ..], " \t\r");
            try descs.put(code, try a.dupe(u8, desc));
        }
    }
}

fn loadReserved(a: std.mem.Allocator, set: *Set, path: []const u8) void {
    const content = std.fs.cwd().readFileAlloc(a, path, 1024 * 1024) catch return;
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Take the first whitespace-delimited token so `CODE  # rationale` suppresses
        // safely (a trailing comment used to become part of the key and silently NOT match).
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const code = toks.next() orelse continue;
        set.put(a.dupe(u8, code) catch return, {}) catch return;
    }
}

fn strLess(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

/// Sorted keys of `from` that are absent from `emit` (count map) and `exclude` (optional set).
fn deadDiff(a: std.mem.Allocator, from: *LineMap, emit: *CountMap, exclude: *Set) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(a, 0);
    var it = from.keyIterator();
    while (it.next()) |kp| {
        if (emit.contains(kp.*)) continue;
        if (exclude.contains(kp.*)) continue;
        try list.append(a, kp.*);
    }
    std.mem.sort([]const u8, list.items, {}, strLess);
    return list.items;
}

/// Sorted keys of count map `from` absent from line map `decl`.
fn orphanDiff(a: std.mem.Allocator, from: *CountMap, decl: *LineMap) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(a, 0);
    var it = from.keyIterator();
    while (it.next()) |kp| {
        if (decl.contains(kp.*)) continue;
        try list.append(a, kp.*);
    }
    std.mem.sort([]const u8, list.items, {}, strLess);
    return list.items;
}

const out = std.debug.print;

/// Print the family context + bug-vs-reserved signal for one DEAD code.
fn diagnose(a: std.mem.Allocator, code: []const u8, declared: *LineMap, emit: *CountMap) !void {
    const fam = familyOf(code);
    // Gather declared siblings sharing the family.
    var sibs = try std.ArrayList([]const u8).initCapacity(a, 0);
    var it = declared.keyIterator();
    while (it.next()) |kp| {
        if (std.mem.eql(u8, familyOf(kp.*), fam)) try sibs.append(a, kp.*);
    }
    std.mem.sort([]const u8, sibs.items, {}, strLess);

    const line = declared.get(code) orelse 0;
    out("    {s}  declared src/errors.zig:{d}\n", .{ code, line });

    // family line: each sibling with its emit count (this one marked).
    out("        family {s}: ", .{fam});
    var emitted_sibs: usize = 0;
    var dead_sibs: usize = 0;
    for (sibs.items) |s| {
        const n = if (emit.get(s)) |c| c else 0;
        const is_self = std.mem.eql(u8, s, code);
        if (is_self) {
            out("{s}={d}(this,DEAD) ", .{ s, n });
        } else {
            out("{s}={d} ", .{ s, n });
            if (n > 0) emitted_sibs += 1 else dead_sibs += 1;
        }
    }
    out("\n", .{});

    // bug-vs-reserved signal.
    if (sibs.items.len == 1) {
        out("        -> no siblings to compare; inspect the declaring section manually.\n", .{});
    } else if (emitted_sibs > 0 and dead_sibs == 0) {
        out("        -> LONE GAP in a fully-emitted family: emit-density HINTS a BUG (wire a `.{s}` emit).\n", .{code});
        out("           but this signal only counts siblings — it cannot see a never-built detector or a\n", .{});
        out("           semantic duplicate of another code. VERIFY before wiring (grep src/ + docs + tests).\n", .{});
    } else if (emitted_sibs == 0) {
        out("        -> WHOLE family unemitted: likely RESERVED (detector/feature unbuilt). Confirm, then reserve.\n", .{});
    } else {
        out("        -> mixed family ({d} emitted, {d} dead siblings): inspect — could be either.\n", .{ emitted_sibs, dead_sibs });
    }
}

// ---- `confirm <CODE>`: the verification battery a cold operator kept reinventing ----
// Two cold-room probes showed every agent ran the SAME ritual to make the bug-vs-reserved
// call (grep src for emit, grep docs for policy, grep tests for a pin, check for a
// same-description twin, git log -S). This subcommand runs it and prints the evidence, so
// the verdict is HANDED to the operator instead of reverse-engineered.

const Loc = struct { path: []const u8, line: usize, text: []const u8 };

fn grepContent(a: std.mem.Allocator, label: []const u8, content: []const u8, needle: []const u8, list: *std.ArrayList(Loc)) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    var ln: usize = 0;
    while (it.next()) |raw| {
        ln += 1;
        if (std.mem.indexOf(u8, raw, needle) != null) {
            try list.append(a, .{ .path = label, .line = ln, .text = try a.dupe(u8, std.mem.trim(u8, raw, " \t\r")) });
        }
    }
}

fn grepTree(a: std.mem.Allocator, root: []const u8, ext: []const u8, needle: []const u8, list: *std.ArrayList(Loc)) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (ext.len > 0 and !std.mem.endsWith(u8, entry.basename, ext)) continue;
        const content = dir.readFileAlloc(a, entry.path, 16 * 1024 * 1024) catch continue;
        const label = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.path });
        try grepContent(a, label, content, needle, list);
    }
}

fn grepFile(a: std.mem.Allocator, path: []const u8, needle: []const u8, list: *std.ArrayList(Loc)) !void {
    const content = std.fs.cwd().readFileAlloc(a, path, 16 * 1024 * 1024) catch return;
    try grepContent(a, path, content, needle, list);
}

fn gitLogS(a: std.mem.Allocator, code: []const u8) []const u8 {
    const res = std.process.Child.run(.{ .allocator = a, .argv = &[_][]const u8{ "git", "log", "--oneline", "-S", code, "--", "src/errors.zig" } }) catch return "";
    return res.stdout;
}

fn confirm(a: std.mem.Allocator, code: []const u8, lines: *LineMap, descs: *DescMap, emit: *CountMap) !void {
    const desc = descs.get(code) orelse "";
    out("wm confirm {s}", .{code});
    if (desc.len > 0) out("  —  {s}", .{desc});
    out("\n", .{});

    if (lines.get(code)) |ln| {
        out("  DECLARED : src/errors.zig:{d}\n", .{ln});
    } else {
        out("  DECLARED : NOT in the ErrorCode enum (unknown/orphan code)\n", .{});
    }

    // EMITTED sites — `.CODE` tags + `error[CODE]` literals (the declaration line is
    // `CODE,` with no `.`, so it never matches the tag needle).
    var emits = try std.ArrayList(Loc).initCapacity(a, 0);
    const tag = try std.fmt.allocPrint(a, ".{s}", .{code});
    const lit = try std.fmt.allocPrint(a, "error[{s}]", .{code});
    try grepTree(a, "src", ".zig", tag, &emits);
    try grepTree(a, "koru_std", ".zig", tag, &emits);
    try grepTree(a, "src", ".zig", lit, &emits);
    out("  EMITTED  : {d} site(s)\n", .{emits.items.len});
    for (emits.items) |loc| out("             {s}:{d}\n", .{ loc.path, loc.line });

    // PINNED — regression expectations referencing the code.
    var pins = try std.ArrayList(Loc).initCapacity(a, 0);
    try grepTree(a, "tests/regression", "", lit, &pins);
    out("  PINNED   : {d} test reference(s)\n", .{pins.items.len});
    for (pins.items) |loc| out("             {s}:{d}\n", .{ loc.path, loc.line });

    // POLICY — does any design doc speak to this code / its semantics?
    var pol = try std.ArrayList(Loc).initCapacity(a, 0);
    try grepTree(a, "docs", ".md", code, &pol);
    for ([_][]const u8{ "CLAUDE.md", "README.md", "AGENTS.md", "CONTRIBUTING.md", "PLAN.md" }) |f| try grepFile(a, f, code, &pol);
    out("  POLICY   : {d} doc mention(s) of {s}\n", .{ pol.items.len, code });
    for (pol.items) |loc| out("             {s}:{d}: {s}\n", .{ loc.path, loc.line, loc.text });

    // DUPLICATE — another declared code with the same description (the KORU082≡TYPE003 trap).
    var dups = try std.ArrayList([]const u8).initCapacity(a, 0);
    if (desc.len > 0) {
        var dit = descs.iterator();
        while (dit.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, code)) continue;
            if (std.ascii.eqlIgnoreCase(e.value_ptr.*, desc)) try dups.append(a, e.key_ptr.*);
        }
    }
    std.mem.sort([]const u8, dups.items, {}, strLess);
    if (dups.items.len > 0) {
        out("  DUPLICATE: same description as", .{});
        for (dups.items) |dcode| out(" {s}(emit={d})", .{ dcode, if (emit.get(dcode)) |c| c else 0 });
        out("\n", .{});
    } else {
        out("  DUPLICATE: none (description is unique)\n", .{});
    }

    // HISTORY — when did this code enter, and has anything touched it since?
    const hist = std.mem.trim(u8, gitLogS(a, code), "\n \t");
    if (hist.len > 0) {
        out("  HISTORY  : commits changing `{s}` in errors.zig:\n", .{code});
        var hit = std.mem.splitScalar(u8, hist, '\n');
        while (hit.next()) |h| out("             {s}\n", .{h});
    }

    // VERDICT HINT — a hint, not an assertion (the re-probe taught us a confident steer anchors).
    const ec: u32 = if (emit.get(code)) |c| c else 0;
    out("  ---\n", .{});
    if (ec > 0) {
        out("  HINT: EMITTED already ({d} site(s)) — not dead; nothing to confirm.\n", .{ec});
    } else if (dups.items.len > 0) {
        out("  HINT: RESERVED / CONSOLIDATE — a same-description sibling exists, so this is likely a\n", .{});
        out("        redundant declaration, not an unwired bug. Reserve it, or merge it with its twin.\n", .{});
    } else if (pol.items.len > 0) {
        out("  HINT: a design doc mentions this code — read those lines first; the intent may be\n", .{});
        out("        deliberate (reserved) or may name the exact site that should emit it (bug).\n", .{});
    } else {
        out("  HINT: no twin, no doc policy. The call turns on whether the DETECTOR exists: grep src/\n", .{});
        out("        for the condition this code names. No detector code -> RESERVED (feature unbuilt);\n", .{});
        out("        a detector that runs but never tags this code -> BUG (wire `.{s}`).\n", .{code});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);

    var declared = LineMap.init(a);
    var descs = DescMap.init(a);
    var emitted = CountMap.init(a);

    const errors_src = try std.fs.cwd().readFileAlloc(a, "src/errors.zig", 16 * 1024 * 1024);
    try collectDeclared(a, &declared, &descs, errors_src);

    // EMITTED — all of src/ (incl. errors.zig helper fns) + koru_std.
    try collectTree(a, &emitted, "src", ".zig", .emit);
    try collectTree(a, &emitted, "koru_std", ".zig", .emit);

    // Subcommand: `confirm <CODE>` runs the verification battery for one code.
    if (args.len >= 3 and std.mem.eql(u8, args[1], "confirm")) {
        try confirm(a, args[2], &declared, &descs, &emitted);
        return;
    }

    var pinned = CountMap.init(a);
    var reserved = Set.init(a);
    try collectPins(a, &pinned, "tests/regression");
    loadReserved(a, &reserved, "scripts/registry_reserved.txt");

    const orphan = try orphanDiff(a, &emitted, &declared);
    const dead = try deadDiff(a, &declared, &emitted, &reserved);
    const rotten = try orphanDiff(a, &pinned, &declared);

    out("registry-check — koru diagnostic-code coherence\n", .{});
    out("  DECLARED={d}  EMITTED={d}  PINNED={d}  RESERVED={d}\n\n", .{ declared.count(), emitted.count(), pinned.count(), reserved.count() });

    out("  ORPHAN_EMIT (emitted, never declared) [{d}]:\n", .{orphan.len});
    for (orphan) |c| out("    {s}  <- emitted but absent from the ErrorCode enum (declare it in src/errors.zig)\n", .{c});

    out("  DEAD (declared, never emitted, not reserved) [{d}]:\n", .{dead.len});
    for (dead) |c| try diagnose(a, c, &declared, &emitted);

    out("  ROTTEN_PIN (pinned by a test, not declared) [{d}]:\n", .{rotten.len});
    for (rotten) |c| out("    {s}  <- a regression test pins a code that can't resolve (declare it, or fix the test)\n", .{c});

    const total = orphan.len + dead.len + rotten.len;
    out("\n", .{});
    if (total == 0) {
        out("result: PASS — the registry is coherent.\n", .{});
    } else {
        out("  Unsure if a DEAD code is a BUG or RESERVED? Run the verification battery (emit/pin/doc/\n", .{});
        out("  twin/history evidence + a verdict hint):  zig run scripts/registry_check.zig -- confirm <CODE>\n", .{});
        out("  To clear a DEAD code: wire a `.CODE` emit in src/ (a LONE GAP is almost always this),\n", .{});
        out("  OR add the bare code to scripts/registry_reserved.txt below the marker (unbuilt/intentional).\n", .{});
        out("  ORPHAN_EMIT: declare the code in the enum. ROTTEN_PIN: declare it, or fix the pinning test.\n", .{});
        out("  Full playbook (when to wire / reserve / consolidate): skills/registry-drain/SKILL.md\n\n", .{});
        out("result: FAIL — {d} code(s) drifted from the registry. (FIRE)\n", .{total});
        std.process.exit(1);
    }
}
