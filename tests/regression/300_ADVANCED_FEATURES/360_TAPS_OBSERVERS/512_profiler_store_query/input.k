// Pins profiler + std/store:query — tap transform can run before the query
// sweep transform; store.kz peels tap-wrapped effect bodies to the author's
// invocation (KORU161 "sweep body must start with an invocation").
//
// Store sweeps lower to direct handler calls — the pin also runs a runtime flow
// so the trace proves profiling stayed live.
[profile]import std/profiler
import std/store
import std/io

std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 10 }
| row _ |> _
std/store:insert(items) { v: 20 }
| row _ |> _

std/store:query(items)
! query e |> std/io:print.ln("v={{ e.v:d }}")

tor ping {}

proc ping|zig {
    const std = @import("std");
    std.debug.print("query profile ok\n", .{});
}

ping() |> std/io:print.ln("profiled query run complete")
