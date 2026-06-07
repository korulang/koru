// registry_check.zig — diagnostic-code registry coherence watcher
//
// HEAD-CARRIED TRUST: `src/errors.zig` ErrorCode enum is the single source of truth
// for diagnostic codes. Nothing keeps the things that reference it honest. This watcher
// makes that trust visible by materializing three sets and diffing them:
//
//   DECLARED = members of the `pub const ErrorCode = enum(u16)` block in src/errors.zig
//   EMITTED  = codes the compiler actually uses:  `.KORUxxx` enum-tags + `error[KORUxxx]`
//              literals across src/ (excluding errors.zig itself)
//   PINNED   = codes asserted by the regression suite: `error[KORUxxx]` in tests/regression
//
// It FIRES (exit 1) on any of three drifts:
//   ORPHAN_EMIT = EMITTED \ DECLARED  — a code emitted that the dictionary never declared
//   DEAD        = DECLARED \ EMITTED  — a declared code nothing emits (a lie: claims the
//                 compiler catches something it doesn't), minus an explicit reserved-list
//   ROTTEN_PIN  = PINNED \ DECLARED   — a test pinned to a code that can't resolve
//
// Reserved-but-unimplemented codes are whitelisted in scripts/registry_reserved.txt
// (one code per line, `#` comments). Empty/absent = every dead code fires.
//
// Run from the koru repo root:  zig run scripts/registry_check.zig
// This is the lean first watcher of the `wm` toolchain (FACT-only; no judge).

const std = @import("std");

const Set = std.StringHashMap(void);

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const Mode = enum { emit, pin, declared };

/// Scan `content` for diagnostic-code tokens (>=3 uppercase letters followed by >=3 digits)
/// and add the ones matching `mode`'s context filter to `set`.
fn collect(a: std.mem.Allocator, set: *Set, content: []const u8, mode: Mode) !void {
    var i: usize = 0;
    while (i < content.len) {
        if (isUpper(content[i])) {
            var j = i;
            while (j < content.len and isUpper(content[j])) j += 1;
            if (j < content.len and isDigit(content[j])) {
                var k = j;
                while (k < content.len and isDigit(content[k])) k += 1;
                if (j - i >= 3 and k - j >= 3) {
                    const tok = content[i..k];
                    const prev: u8 = if (i > 0) content[i - 1] else 0;
                    const next: u8 = if (k < content.len) content[k] else 0;
                    const take = switch (mode) {
                        // `.KORU030` (enum literal) or `error[KORU200]` (literal)
                        .emit => prev == '.' or prev == '[',
                        // `error[KORU030]` inside an expected_error.txt
                        .pin => prev == '[',
                        // an enum member line: `    KORU001, // ...`
                        .declared => (prev == ' ' or prev == '\t' or prev == '\n' or prev == '{') and next == ',',
                    };
                    if (take) try set.put(try a.dupe(u8, tok), {});
                }
                i = k;
                continue;
            }
        }
        i += 1;
    }
}

/// Walk `root` recursively, reading every `.zig` file (optionally skipping one basename),
/// collecting codes under `mode` into `set`.
fn collectTree(a: std.mem.Allocator, set: *Set, root: []const u8, ext: []const u8, mode: Mode, skip_basename: ?[]const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ext)) continue;
        if (skip_basename) |sb| if (std.mem.eql(u8, entry.basename, sb)) continue;
        const content = dir.readFileAlloc(a, entry.path, 16 * 1024 * 1024) catch continue;
        try collect(a, set, content, mode);
    }
}

/// PINNED: codes inside `error[...]` across regression expected/EXPECT files.
fn collectPins(a: std.mem.Allocator, set: *Set, root: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const b = entry.basename;
        const is_pin_file = std.mem.startsWith(u8, b, "expected") or std.mem.eql(u8, b, "EXPECT");
        if (!is_pin_file) continue;
        const content = dir.readFileAlloc(a, entry.path, 16 * 1024 * 1024) catch continue;
        try collect(a, set, content, .pin);
    }
}

fn strLess(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

/// Sorted list of keys in `from` that are NOT in `notin` (and not in `exclude`, if given).
fn diff(a: std.mem.Allocator, from: *Set, notin: *Set, exclude: ?*Set) ![][]const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(a, 0);
    var it = from.keyIterator();
    while (it.next()) |kp| {
        if (notin.contains(kp.*)) continue;
        if (exclude) |ex| if (ex.contains(kp.*)) continue;
        try out.append(a, kp.*);
    }
    std.mem.sort([]const u8, out.items, {}, strLess);
    return out.items;
}

fn extractEnumBlock(content: []const u8) []const u8 {
    const marker = "pub const ErrorCode = enum(u16) {";
    const s = std.mem.indexOf(u8, content, marker) orelse return content;
    const start = s + marker.len;
    const rest = content[start..];
    const e = std.mem.indexOf(u8, rest, "\n};") orelse return rest;
    return rest[0..e];
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var declared = Set.init(a);
    var emitted = Set.init(a);
    var pinned = Set.init(a);
    var reserved = Set.init(a);

    // DECLARED — only within the enum block.
    const errors_src = try std.fs.cwd().readFileAlloc(a, "src/errors.zig", 16 * 1024 * 1024);
    try collect(a, &declared, extractEnumBlock(errors_src), .declared);

    // EMITTED — all of src/, INCLUDING errors.zig. The enum-declaration lines are
    // space-prefixed (`KORU002,`) so they never match the `.emit` filter (which needs a
    // `.` or `[` prefix); but errors.zig's HELPER functions emit via `.KORUxxx` enum-tags
    // (e.g. `moduleNotFound` -> `.KORU002`) and those ARE real emit sites. Excluding the
    // whole file dropped them and produced false "dead" positives on helper-dispatched,
    // test-pinned codes (KORU002 has 5 pins). So scan it like any other source file.
    try collectTree(a, &emitted, "src", ".zig", .emit, null);
    try collectTree(a, &emitted, "koru_std", ".zig", .emit, null);

    // PINNED — the regression suite's expected outputs.
    try collectPins(a, &pinned, "tests/regression");

    // Reserved (intentionally-unimplemented) codes are not "dead".
    loadReserved(a, &reserved, "scripts/registry_reserved.txt");

    const orphan = try diff(a, &emitted, &declared, null);
    const dead = try diff(a, &declared, &emitted, &reserved);
    const rotten = try diff(a, &pinned, &declared, null);

    const out = std.debug.print;
    out("registry-check — koru diagnostic-code coherence\n", .{});
    out("  DECLARED={d}  EMITTED={d}  PINNED={d}  RESERVED={d}\n\n", .{ declared.count(), emitted.count(), pinned.count(), reserved.count() });

    out("  ORPHAN_EMIT (emitted, never declared) [{d}]:\n", .{orphan.len});
    for (orphan) |c| out("    {s}  <- emitted but absent from the ErrorCode enum\n", .{c});
    out("  DEAD (declared, never emitted, not reserved) [{d}]:\n", .{dead.len});
    for (dead) |c| out("    {s}  <- the enum claims this code; nothing emits it\n", .{c});
    out("  ROTTEN_PIN (pinned by a test, not declared) [{d}]:\n", .{rotten.len});
    for (rotten) |c| out("    {s}  <- a regression test pins a code that can't resolve\n", .{c});

    const total = orphan.len + dead.len + rotten.len;
    out("\n", .{});
    if (total == 0) {
        out("result: PASS — the registry is coherent.\n", .{});
    } else {
        out("result: FAIL — {d} code(s) drifted from the registry. (FIRE)\n", .{total});
        std.process.exit(1);
    }
}
