const std = @import("std");
const vaxis = @import("vaxis");

// Mimic our generated code: struct-level statics
var vx: vaxis.Vaxis = undefined;
var tty: vaxis.Tty = undefined;
var event_loop: vaxis.Loop(Event) = undefined;
var tty_buffer: [4096]u8 = undefined;
var alloc: std.mem.Allocator = undefined;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

pub fn main() !void {
    alloc = std.heap.page_allocator;

    tty = try vaxis.Tty.init(&tty_buffer);
    vx = try vaxis.init(alloc, .{});

    event_loop = .{ .vaxis = &vx, .tty = &tty };
    try event_loop.init();
    try event_loop.start();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    // Wait for initial resize (same as our run proc)
    while (true) {
        const event = event_loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                try vx.resize(alloc, tty.writer(), ws);
                break;
            },
            else => {},
        }
    }

    // Now render once (same as our generated flow)
    const win = vx.window();
    win.clear();

    const child1 = win.child(.{ .x_off = 2, .y_off = 1 });
    _ = child1.print(&.{.{ .text = "Hello, World!" }}, .{});

    const child2 = win.child(.{ .x_off = 2, .y_off = 3 });
    _ = child2.print(&.{.{ .text = "Press 'q' to quit." }}, .{});

    vx.queueRefresh();
    try vx.render(tty.writer());

    // Poll loop
    while (true) {
        const event = event_loop.nextEvent();
        switch (event) {
            .key_press => |k| {
                if (k.codepoint == 'q') break;
            },
            else => {},
        }
    }

    vx.deinit(alloc, tty.writer());
    tty.deinit();
}
