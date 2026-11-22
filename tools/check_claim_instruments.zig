// check_claim_instruments — instrumented claim stamps must name a running
// instrument, and the instrument must still exist.
//
// `std/rules` claim entries (`- aspirational|inferred|measured|proven <name>`)
// live in the `~[ ... ]` annotation block on a declaration. `aspirational` is
// the honest undischarged claim and needs nothing. Every stamp above it is a
// standing instrument, not a certificate: the entry must carry a pointer that
// RESOLVES to something that runs —
//
//   - a repo-relative path that exists     (a pin dir, a benchmark file,
//                                           a proof artifact)
//   - a directory name under tests/        (a bare pin name resolves too)
//   - a `"name": "<x>"` row in invariants/invariants.kz  (a gate row is an
//                                           instrument: it re-discharges the
//                                           claim on every commit)
//
// A stamp whose pointer resolves to nothing is prose claiming to be
// discharged — the content class this check exists to delete. It reads the
// WORKING tree, not the staged diff: an instrument that died yesterday
// (a deleted pin, a renamed row) must fail the next commit, whoever wrote it.
//
//   zig run tools/check_claim_instruments.zig -- <repo_root> <scan_root>...
//
// Exit: 0 clean, 1 violations, 2 broken (self-test failed or a root vanished).

const std = @import("std");

const STAMPS = [_][]const u8{ "aspirational", "inferred", "measured", "proven" };

const Claim = struct {
    stamp: []const u8,
    pointer: []const u8,
    file: []const u8,
    line: usize,
};

const ANN_OPEN = "~[";
const ANN_OPEN_BARE = "[";

fn isStampWord(w: []const u8) bool {
    for (STAMPS) |s| if (std.mem.eql(u8, w, s)) return true;
    return false;
}

/// A claim entry line: optional whitespace, `-`, whitespace, a stamp word.
/// Anything else (incl. `// - measured x` — a comment) is not an entry.
fn parseEntry(line: []const u8) ?struct { stamp: []const u8, pointer: []const u8 } {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 2 or t[0] != '-') return null;
    if (t[1] != ' ' and t[1] != '\t') return null; // `->` is not an entry
    const rest = std.mem.trim(u8, t[1..], " \t\r");
    const sp = std.mem.indexOfAny(u8, rest, " \t");
    const word = if (sp) |i| rest[0..i] else rest;
    if (!isStampWord(word)) return null;
    const pointer = if (sp) |i| std.mem.trim(u8, rest[i..], " \t\r") else "";
    return .{ .stamp = word, .pointer = pointer };
}

/// Annotation-block state machine over lines. A block opens on a line that is
/// exactly `~[` or `[` (up to trailing whitespace) and closes at the first
/// line starting with `]`. A line that opens and closes itself
/// (`~[comptime]`) is not a block.
fn scanFile(alloc: std.mem.Allocator, path: []const u8, out: *std.ArrayList(Claim)) !void {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 10 << 20) catch |e| {
        std.debug.print("check_claim_instruments: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    var in_ann = false;
    var lineno: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        lineno += 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (!in_ann) {
            const opens = std.mem.eql(u8, t, ANN_OPEN) or std.mem.eql(u8, t, ANN_OPEN_BARE);
            if (opens) in_ann = true;
            continue;
        }
        if (t.len > 0 and t[0] == ']') {
            in_ann = false;
            continue;
        }
        if (parseEntry(t)) |e| {
            try out.append(alloc, .{ .stamp = e.stamp, .pointer = e.pointer, .file = path, .line = lineno });
        }
    }
}

fn walkDir(alloc: std.mem.Allocator, root: []const u8, out: *std.ArrayList(Claim)) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e| {
        std.debug.print("check_claim_instruments: cannot open root {s}: {s}\n", .{ root, @errorName(e) });
        return e;
    };
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |ent| {
        if (ent.kind != .file) continue;
        const base = std.fs.path.basename(ent.path);
        if (!std.mem.endsWith(u8, base, ".k") and !std.mem.endsWith(u8, base, ".kz")) continue;
        const full = try std.fs.path.join(alloc, &.{ root, ent.path });
        try scanFile(alloc, full, out);
    }
}

/// Does `name` appear as a directory name anywhere under `<root>/tests`?
/// `- measured 690_351_pump_retired_unit_fires_once` resolves to the pin dir.
fn testsDirHas(repo_root: []const u8, name: []const u8, alloc: std.mem.Allocator) bool {
    const tests_root = std.fs.path.join(alloc, &.{ repo_root, "tests" }) catch return false;
    var dir = std.fs.cwd().openDir(tests_root, .{ .iterate = true }) catch return false;
    defer dir.close();
    var walker = dir.walk(alloc) catch return false;
    defer walker.deinit();
    while (walker.next() catch return false) |ent| {
        if (ent.kind == .directory and std.mem.eql(u8, ent.basename, name)) return true;
    }
    return false;
}

/// Does `name` match a `"name": "<x>"` row in <repo_root>/invariants/invariants.kz?
fn manifestRowExists(repo_root: []const u8, name: []const u8, alloc: std.mem.Allocator) bool {
    const path = std.fs.path.join(alloc, &.{ repo_root, "invariants", "invariants.kz" }) catch return false;
    const text = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return false;
    const needle = std.fmt.allocPrint(alloc, "\"name\": \"{s}\"", .{name}) catch return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

fn pointerResolves(repo_root: []const u8, pointer: []const u8, alloc: std.mem.Allocator) enum { path, pin, row, nowhere } {
    if (pointer.len == 0) return .nowhere;
    const rel = std.fs.path.join(alloc, &.{ repo_root, pointer }) catch return .nowhere;
    if (std.fs.cwd().access(rel, .{})) |_| return .path else |_| {}
    if (testsDirHas(repo_root, pointer, alloc)) return .pin;
    if (manifestRowExists(repo_root, pointer, alloc)) return .row;
    return .nowhere;
}

/// Declared exemptions: `<repo-relative path> | <entry text> | <reason>`.
/// An exemption is a ruling that this fixture's stamp asserts no real claim
/// (claims-registry test inputs exercise the collector, not the codebase).
/// An allow entry that matches no violation is STALE and fails the check —
/// same mechanics as emitted-while.allow.
const Allow = struct {
    path: []const u8,
    entry: []const u8,
    used: bool = false,
};

fn loadAllow(alloc: std.mem.Allocator, path: []const u8) !std.ArrayList(Allow) {
    var list = std.ArrayList(Allow){};
    const text = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |e| {
        std.debug.print("check_claim_instruments: cannot read allow file {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, t, '|');
        const p = std.mem.trim(u8, parts.next() orelse continue, " \t\r");
        const entry = std.mem.trim(u8, parts.next() orelse continue, " \t\r");
        try list.append(alloc, .{ .path = p, .entry = entry });
    }
    return list;
}

fn selfTest(alloc: std.mem.Allocator) bool {
    const e1 = parseEntry("- measured tests/regression/x") orelse return false;
    if (!std.mem.eql(u8, e1.stamp, "measured")) return false;
    if (!std.mem.eql(u8, e1.pointer, "tests/regression/x")) return false;
    if (parseEntry("-> measured x") != null) return false;
    if (parseEntry("// - measured x") != null) return false;
    if (parseEntry("- notastamp x") != null) return false;
    const e2 = parseEntry("  - aspirational") orelse return false;
    if (e2.pointer.len != 0) return false;
    // resolution sanity: a path that exists must resolve as .path
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    if (pointerResolves("..", "tests", aa) != .path) return false;
    return true;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 3) {
        std.debug.print("usage: check_claim_instruments <repo_root> [--allow <file>] <scan_root>...\n", .{});
        return 2;
    }
    const repo_root = args[1];
    var allow_path: ?[]const u8 = null;
    var roots = std.ArrayList([]const u8){};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("usage: check_claim_instruments <repo_root> [--allow <file>] <scan_root>...\n", .{});
                return 2;
            }
            allow_path = args[i];
        } else {
            try roots.append(alloc, args[i]);
        }
    }
    if (roots.items.len == 0) {
        std.debug.print("usage: check_claim_instruments <repo_root> [--allow <file>] <scan_root>...\n", .{});
        return 2;
    }

    if (!selfTest(alloc)) {
        std.debug.print("BROKEN claim-instruments: self-test failed — the entry parser or resolver no longer matches the claim grammar in koru_std/rules.kz\n", .{});
        return 2;
    }

    var allows = std.ArrayList(Allow){};
    if (allow_path) |ap| {
        allows = loadAllow(alloc, ap) catch return 2;
    }

    var claims = std.ArrayList(Claim){};
    for (roots.items) |root| {
        walkDir(alloc, root, &claims) catch return 2;
    }

    var violations: usize = 0;
    for (claims.items) |c| {
        if (std.mem.eql(u8, c.stamp, "aspirational")) continue;
        switch (pointerResolves(repo_root, c.pointer, alloc)) {
            .nowhere => {
                // repo-relative path for allow matching: strip a leading "../"
                // and normalize separators — a Windows walk emits `tests\…`
                // while the allow file is written in `/`.
                const rel = if (std.mem.startsWith(u8, c.file, "../")) c.file[3..] else c.file;
                const rel_norm = alloc.dupe(u8, rel) catch unreachable;
                for (rel_norm) |*ch| {
                    if (ch.* == '\\') ch.* = '/';
                }
                const entry_text = std.fmt.allocPrint(alloc, "- {s} {s}", .{ c.stamp, c.pointer }) catch unreachable;
                var exempt = false;
                for (allows.items) |*a| {
                    if (std.mem.eql(u8, a.path, rel_norm) and std.mem.eql(u8, a.entry, entry_text)) {
                        a.used = true;
                        exempt = true;
                    }
                }
                if (exempt) continue;
                violations += 1;
                std.debug.print("VIOLATION {s}:{d}  {s}\n", .{ c.file, c.line, entry_text });
            },
            else => {},
        }
    }

    for (allows.items) |a| {
        if (!a.used) {
            violations += 1;
            std.debug.print("STALE {s}  | {s} — exemption matches no site; remove it or fix the claim it named\n", .{ a.path, a.entry });
        }
    }

    if (violations > 0) {
        std.debug.print(
            \\
            \\A stamp above `aspirational` is a standing instrument, not a
            \\certificate — it must name what keeps discharging it, and the
            \\pointer must resolve. Fix by naming, after the stamp:
            \\  - a repo path that exists     (tests/regression/…/pin,
            \\                                a benchmark, a proof artifact)
            \\  - a pin directory name        (690_351_pump_retired_unit_fires_once)
            \\  - an invariants row name      (the gate row is the instrument)
            \\If nothing runs it, the claim is `aspirational`. Show me.
            \\
        , .{});
        return 1;
    }
    return 0;
}
