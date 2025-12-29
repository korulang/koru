const std = @import("std");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var koru_root_env: ?[]u8 = std.process.getEnvVarOwned(allocator, "KORU_ROOT") catch null;
    defer if (koru_root_env) |p| allocator.free(p);
    const rel_to_root = if (koru_root_env) |p| p else {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll("ERROR: KORU_ROOT environment variable not set\n");
        std.process.exit(1);
    };
    std.debug.print("{s}\n", .{rel_to_root});
}
