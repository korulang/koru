const std = @import("std");

/// Canonical list of Koru file extensions, longest-first.
///
/// `.kgpu` must precede `.k` so that `koruExtensionOf("foo.kgpu")` returns
/// ".kgpu" rather than ".k". Greedy first-match is the contract.
///
/// Naming convention: `.k` + host-language abbreviation. `.k` itself is
/// pure Koru (contract-only: events, types, obligations — no proc bodies).
pub const koru_extensions = [_][]const u8{ ".kgpu", ".kjs", ".kz", ".kc", ".k" };

/// True if `name` ends with any Koru file extension.
pub fn isKoruFile(name: []const u8) bool {
    for (koru_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Return the matching extension slice (e.g. ".kjs") if `name` has a Koru
/// extension, else null. Longest-first match.
pub fn koruExtensionOf(name: []const u8) ?[]const u8 {
    for (koru_extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return ext;
    }
    return null;
}

/// The host language a Koru file's bytes are written in, derived from its
/// extension — returned as a variant-tag string in the SAME namespace as
/// `--lang` / `proc.target` (`"zig"`, `"js"`, `"c"`, `"gpu"`).
///
/// This is the unifying point of the multi-variant design: a host line and a
/// proc body are both host-language bytes, so an emitter targeting language L
/// selects them by the same test. Proc-body selection already does
/// `proc.target == L`; host-line selection does `hostLangOfFile(file) == L`.
/// No emitter needs to know about file extensions — they ask for the host
/// language, exactly as they ask a proc for its target.
///
/// Returns null when the file carries no host bytes (`.k`, the pure contract)
/// or has no recognized Koru extension (e.g. compiler-synthesized items whose
/// `location.file` is `"generated"`). Callers decide what null means for them:
/// the JS emitter skips such lines; the Zig emitter (the default path) emits
/// host-agnostic synthesized lines regardless.
pub fn hostLangOfFile(name: []const u8) ?[]const u8 {
    const ext = koruExtensionOf(name) orelse return null;
    if (std.mem.eql(u8, ext, ".kz")) return "zig";
    if (std.mem.eql(u8, ext, ".kjs")) return "js";
    if (std.mem.eql(u8, ext, ".kc")) return "c";
    if (std.mem.eql(u8, ext, ".kgpu")) return "gpu";
    // ".k" — pure contract, no host bytes.
    return null;
}

const testing = std.testing;

test "isKoruFile recognizes all canonical extensions" {
    try testing.expect(isKoruFile("foo.k"));
    try testing.expect(isKoruFile("foo.kz"));
    try testing.expect(isKoruFile("foo.kjs"));
    try testing.expect(isKoruFile("foo.kc"));
    try testing.expect(isKoruFile("foo.kgpu"));
}

test "isKoruFile rejects non-Koru extensions" {
    try testing.expect(!isKoruFile("foo.zig"));
    try testing.expect(!isKoruFile("foo.js"));
    try testing.expect(!isKoruFile("foo.txt"));
    try testing.expect(!isKoruFile("foo"));
    try testing.expect(!isKoruFile(""));
}

test "koruExtensionOf returns longest match (greedy)" {
    // .kgpu must beat .k
    try testing.expectEqualStrings(".kgpu", koruExtensionOf("foo.kgpu").?);
    try testing.expectEqualStrings(".kjs", koruExtensionOf("foo.kjs").?);
    try testing.expectEqualStrings(".kz", koruExtensionOf("foo.kz").?);
    try testing.expectEqualStrings(".kc", koruExtensionOf("foo.kc").?);
    try testing.expectEqualStrings(".k", koruExtensionOf("foo.k").?);
}

test "koruExtensionOf returns null for non-Koru" {
    try testing.expect(koruExtensionOf("foo.zig") == null);
    try testing.expect(koruExtensionOf("foo") == null);
    try testing.expect(koruExtensionOf("") == null);
}

test "hostLangOfFile maps each extension to its variant-tag string" {
    try testing.expectEqualStrings("zig", hostLangOfFile("chain.kz").?);
    try testing.expectEqualStrings("js", hostLangOfFile("chain.kjs").?);
    try testing.expectEqualStrings("c", hostLangOfFile("chain.kc").?);
    try testing.expectEqualStrings("gpu", hostLangOfFile("chain.kgpu").?);
}

test "hostLangOfFile returns null for the pure contract and synthesized items" {
    // `.k` carries no host bytes — it's the contract only.
    try testing.expect(hostLangOfFile("contract.k") == null);
    // Compiler-synthesized items default their location.file to "generated".
    try testing.expect(hostLangOfFile("generated") == null);
    try testing.expect(hostLangOfFile("foo.zig") == null);
    try testing.expect(hostLangOfFile("") == null);
}

test "hostLangOfFile shares the --lang / proc.target namespace" {
    // The whole point: the string a host line resolves to is directly
    // comparable to a proc's target tag and the --lang flag value. A JS
    // emitter selects both a .kjs host line and a |js proc body with "js".
    const js_host = hostLangOfFile("widget.kjs").?;
    const js_target = "js"; // what `proc.target` holds for `~proc x|js`
    try testing.expectEqualStrings(js_target, js_host);
}
