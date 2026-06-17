const std = @import("std");
var __koru_gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
fn koru_allocator() std.mem.Allocator { return __koru_gpa.allocator(); }
const List_i64 = struct { items: std.ArrayList(i64), allocator: std.mem.Allocator };

const push_event = struct {
    const Input = struct { xs: *List_i64, v: i64 };
    const Output = void;
    fn handler(__koru_event_input: Input) Output {
        const xs = __koru_event_input.xs;
        const v = __koru_event_input.v;
        _ = &xs;
        _ = &v;
        _ = &__koru_event_input;
        xs.items.append(xs.allocator, v) catch { @panic("oom"); };
    }
};
pub fn main() !void {
    const allocator = koru_allocator();
    const xs = try allocator.create(List_i64);
    xs.* = .{ .items = try std.ArrayList(i64).initCapacity(allocator, 0), .allocator = allocator };
    for (0..50000000) |__koru_item_0| {
        { const _auto_6 = __koru_item_0; _ = &_auto_6; _ = push_event.handler(.{ .xs = xs, .v = 1 }); }
    }
    std.debug.print("len={d}\n", .{xs.items.items.len});
    xs.items.deinit(xs.allocator);
    allocator.destroy(xs);
}
