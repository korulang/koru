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
