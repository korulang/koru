// Pins profiler + plural std/store:new: universal * -> * taps splice void-branch
// continuations onto terminal store declarations; store transforms must skip
// those when collecting interceptors (KORU161 on branch '').
//
// Store:new/insert lower to direct handler calls at runtime — the pin also
// runs a ordinary flow so the trace proves profiling stayed live.
[profile]import std/profiler
import std/store
import std/io

std/store:new(items, capacity: 4) { data: f64 }
std/store:insert(items) { data: 1.0 }

tor ping {}

proc ping|zig {
    const std = @import("std");
    std.debug.print("store profile ok\n", .{});
}

ping() |> std/io:print.ln("profiled store run complete")
