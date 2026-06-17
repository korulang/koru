const std = @import("std");
var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
// Mirror Koru's List_i64: a heap-allocated handle carrying its own allocator.
const List_i64 = struct {
    items: std.ArrayList(i64),
    allocator: std.mem.Allocator,
};
pub fn main() !void {
    const allocator = gpa.allocator();
    const xs = try allocator.create(List_i64);
    xs.* = .{ .items = try std.ArrayList(i64).initCapacity(allocator, 0), .allocator = allocator };
    var i: usize = 0;
    while (i < 50000000) : (i += 1) {
        // exactly Koru's push: reload xs.items / xs.allocator through the heap ptr
        xs.items.append(xs.allocator, 1) catch @panic("oom");
    }
    std.debug.print("len={d}\n", .{xs.items.items.len});
    xs.items.deinit(xs.allocator);
    allocator.destroy(xs);
}
