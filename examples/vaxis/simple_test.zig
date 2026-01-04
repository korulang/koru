// Minimal vaxis test - mirrors libvaxis/examples/main.zig
const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buffer);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .tty = &tty, .vaxis = &vx };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s);

    const msg = "Hello from simple test! Press any key to exit...";

    while (true) {
        const event = loop.nextEvent();
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

        const win = vx.window();
        win.clear();

        // Write message in center-ish
        const child = win.child(.{ .x_off = 5, .y_off = 3 });
        for (msg, 0..) |_, i| {
            child.writeCell(@intCast(i), 0, .{
                .char = .{ .grapheme = msg[i .. i + 1] },
            });
        }

        try vx.render(tty.writer());
    }
}
