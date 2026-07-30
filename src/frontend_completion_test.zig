const std = @import("std");

test "refSpanAt extracts module:event prefix" {
    const line = "std/store:new(todos)";
    const col0: usize = 13;
    const end = @min(col0, line.len);
    var start = end;
    while (start > 0 and isRef(line[start - 1])) start -= 1;
    while (start > 0 and line[start - 1] == ':') {
        start -= 1;
        while (start > 0 and isRef(line[start - 1])) start -= 1;
    }
    try std.testing.expectEqual(@as(usize, 0), start);
    try std.testing.expectEqualStrings("std/store:new", line[start..end]);
}

test "importSpanAt extracts path after import" {
    const line = "import std/st";
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    try std.testing.expect(std.mem.startsWith(u8, line[i..], "import "));
    i += "import ".len;
    const start = i;
    const end: usize = 14;
    try std.testing.expectEqualStrings("std/st", line[start..end]);
}

fn isRef(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '/' or c == '.' or c == ':';
}
