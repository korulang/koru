// The re-resolution rung: a DEFINED FLOW is a provider of a verb. When the
// agent redefines it, the next dispatch MUST resolve against the new body —
// the provider was replaced, dependents (the next caller) re-resolve.
//
// Cordis's notify cascade does this at the component level: a provider
// replaced, fibers that resolved to it reconfigure against the new one
// (Theorem 63/64). The bridge's REPL define is the same shape: `define`
// installs a flow, a later `define` of the same name REPLACES it, and
// subsequent `run` dispatches see the new body, not a stale one.
//
// The assertion is the second `shout(...)` — after the redefine it must
// return `exclaim:hi`, never the stale `echo:hi`.
import std/io
import std/bridge
import std/runtime
import std/interpreter

tor echo { text: string } -> string
proc echo|zig {
    const std = @import("std");
    return std.fmt.allocPrint(std.heap.page_allocator, "echo:{s}", .{text}) catch unreachable;
}

tor exclaim { text: string } -> string
proc exclaim|zig {
    const std = @import("std");
    return std.fmt.allocPrint(std.heap.page_allocator, "exclaim:{s}", .{text}) catch unreachable;
}

std/runtime:register(scope: "api") {
    echo(1)
    exclaim(1)
}

tor do-define { br: *std/bridge:Bridge, source: string }
do-define = std/bridge:define(br, source)
| defined d |> std/io:print.ln("  defined {{ d:s }}")
| parse-error e |> std/io:print.ln("  define failed: {{ e.message:s }}")

tor run-shout { br: *std/bridge:Bridge }
run-shout = std/bridge:run(br, source: "shout(text: \"hi\")")
| result r |> std/interpreter:value.stringify(r.value): j |> std/io:print.ln("  shout -> {{ j:s }}")
| defined d |> std/io:print.ln("  shout DEFINED {{ d:s }} (unexpected)")
| event-denied ev |> std/io:print.ln("  shout DENIED {{ ev:s }}")
| shape-error s |> std/io:print.ln("  shout SHAPE {{ s.branch:s }}")
| dispatch-error e |> std/io:print.ln("  shout DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  shout PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  shout EXHAUSTED")
| validation-error _ |> std/io:print.ln("  shout VALIDATION")
| scope-not-found _ |> std/io:print.ln("  shout NO SCOPE")

[with]std/bridge:create(id: "redefine", scope: "api"): br
|> std/io:print.ln("--- bridge open")
|> do-define(br, source: "tor shout { text: string }\nshout = echo(text)")
|> run-shout(br)
|> do-define(br, source: "tor shout { text: string }\nshout = exclaim(text)")
|> std/io:print.ln("--- redefined")
|> run-shout(br)
|> std/io:print.ln("--- done")
