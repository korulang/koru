const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
pub fn main() !void {
    const allocator = gpa.allocator();
    var list = try std.ArrayList(i64).initCapacity(allocator, 0);
    var i: usize = 0;
    while (i < 50000000) : (i += 1) {
        try list.append(allocator, 1);
    }
    std.debug.print("len={d}\n", .{list.items.len});
    list.deinit(allocator);
}
