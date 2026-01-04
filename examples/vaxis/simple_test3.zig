// Test matching Koru's exact event handler pattern
const std = @import("std");
const vaxis = @import("vaxis");

const VaxisEvent = union(enum) {
    key_press: vaxis.Key,
    // key_release removed - was causing issues!
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

// Global state exactly like Koru
var vx: vaxis.Vaxis = undefined;
var tty: vaxis.Tty = undefined;
var event_loop: vaxis.Loop(VaxisEvent) = undefined;
var is_initialized: bool = false;
var should_quit: bool = false;
var alloc: std.mem.Allocator = undefined;
var tty_buffer: [4096]u8 = undefined;

// Simulates run_event.handler()
const RunResult = union(enum) {
    ready: struct {},
    err: struct { message: []const u8 },
};

var log_file: ?std.fs.File = null;

fn initLog() void {
    log_file = std.fs.cwd().createFile("debug.log", .{}) catch null;
}

fn log(msg: []const u8) void {
    if (log_file) |f| {
        f.writeAll(msg) catch {};
    }
}

fn run_handler() RunResult {
    log("run_handler: starting\n");

    alloc = std.heap.page_allocator;

    tty = vaxis.Tty.init(&tty_buffer) catch |e| {
        // std.debug.print("run_handler: TTY init failed: {s}\n", .{@errorName(e)});
        return .{ .err = .{ .message = @errorName(e) } };
    };
    // std.debug.print("run_handler: TTY OK\n", .{});

    vx = vaxis.init(alloc, .{}) catch |e| {
        // std.debug.print("run_handler: vaxis init failed: {s}\n", .{@errorName(e)});
        return .{ .err = .{ .message = @errorName(e) } };
    };
    // std.debug.print("run_handler: vaxis OK\n", .{});

    event_loop = .{ .vaxis = &vx, .tty = &tty };
    event_loop.init() catch |e| {
        // std.debug.print("run_handler: event_loop init failed: {s}\n", .{@errorName(e)});
        return .{ .err = .{ .message = @errorName(e) } };
    };
    // std.debug.print("run_handler: event_loop init OK\n", .{});

    event_loop.start() catch |e| {
        // std.debug.print("run_handler: event_loop start failed: {s}\n", .{@errorName(e)});
        return .{ .err = .{ .message = @errorName(e) } };
    };
    // std.debug.print("run_handler: event_loop start OK\n", .{});

    vx.enterAltScreen(tty.writer()) catch {};
    vx.queryTerminal(tty.writer(), 1 * std.time.ns_per_s) catch {};

    is_initialized = true;
    // std.debug.print("run_handler: returning ready\n", .{});
    return .{ .ready = .{} };
}

fn cleanup_handler() void {
    vx.deinit(alloc, tty.writer());
    tty.deinit();
}

const PollResult = union(enum) {
    key: vaxis.Key,  // Pass actual key data!
    resize: struct {},
    focus_in: struct {},
    focus_out: struct {},
    quit: struct {},
};

fn poll_handler() PollResult {
    log("poll_handler: called\n");

    if (should_quit or !is_initialized) {
        log("poll_handler: quit early\n");
        return .{ .quit = .{} };
    }

    log("poll_handler: calling nextEvent\n");
    const event = event_loop.nextEvent();
    log("poll_handler: got event\n");
    switch (event) {
        .key_press => |k| return .{ .key = k },
        .winsize => |ws| {
            vx.resize(alloc, tty.writer(), ws) catch {};
            return .{ .resize = .{} };
        },
        .focus_in => return .{ .focus_in = .{} },
        .focus_out => return .{ .focus_out = .{} },
    }
}

fn render_handler() void {
    // std.debug.print("render_handler: called\n", .{});
    // Disabled for debugging - no alt screen
}

pub fn main() void {
    initLog();
    log("main: start\n");

    const result = run_handler();
    log("main: run_handler returned\n");

    switch (result) {
        .ready => {
            log("main: matched .ready\n");
            while (true) {
                const poll_result = poll_handler();
                switch (poll_result) {
                    .key => |k| {
                        // Log what we got
                        var buf: [100]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "main: key codepoint={d} char={c}\n", .{k.codepoint, if (k.codepoint > 31 and k.codepoint < 127) @as(u8, @intCast(k.codepoint)) else '?'}) catch "?";
                        log(msg);

                        // Only exit on 'q' or ctrl
                        if (k.codepoint == 'q' or k.mods.ctrl) {
                            log("main: GOT REAL KEY - exiting\n");
                            cleanup_handler();
                            break;
                        }
                    },
                    .quit => {
                        log("main: GOT QUIT\n");
                        cleanup_handler();
                        break;
                    },
                    .resize => {
                        log("main: got resize\n");
                        render_handler();
                    },
                    .focus_in => {
                        log("main: got focus_in\n");
                        render_handler();
                    },
                    .focus_out => {
                        log("main: got focus_out\n");
                        render_handler();
                    },
                }
            }
        },
        .err => |_| {
            log("main: got error\n");
        },
    }
    log("main: done\n");
    if (log_file) |f| f.close();
}
