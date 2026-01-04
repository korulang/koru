// Test with global state like Koru uses
const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

// Global state (like Koru's pattern)
var vx: vaxis.Vaxis = undefined;
var tty: vaxis.Tty = undefined;
var event_loop: vaxis.Loop(Event) = undefined;
var alloc: std.mem.Allocator = undefined;
var tty_buffer: [4096]u8 = undefined;

fn init() !void {
    alloc = std.heap.page_allocator;

    tty = try vaxis.Tty.init(&tty_buffer);
    vx = try vaxis.init(alloc, .{});

    event_loop = .{ .vaxis = &vx, .tty = &tty };
    try event_loop.init();
    try event_loop.start();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);
}

fn cleanup() void {
    vx.deinit(alloc, tty.writer());
    tty.deinit();
}

fn render(msg: []const u8, x: u16, y: u16) void {
    const win = vx.window();
    win.clear();

    const child = win.child(.{ .x_off = x, .y_off = y });
    for (msg, 0..) |_, i| {
        child.writeCell(@intCast(i), 0, .{
            .char = .{ .grapheme = msg[i .. i + 1] },
        });
    }

    vx.render(tty.writer()) catch {};
}

pub fn main() !void {
    try init();
    defer cleanup();

    while (true) {
        const event = event_loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'q' or key.mods.ctrl) {
                    break;
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty.writer(), ws);
            },
            else => {},
        }

        render("Hello from global state test! Press 'q' to exit...", 5, 3);
    }
}
