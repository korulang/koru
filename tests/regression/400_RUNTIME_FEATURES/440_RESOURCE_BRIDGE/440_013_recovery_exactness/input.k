// RECOVERY EXACTNESS — the accumulator applies each inverse exactly once.
//
// Cordis Theorem 7 (soundness invariant phi(gamma) = gamma_0): recovery
// returns the context to its initial state. The corollary the bridge must
// honor: a handle EXPLICITLY discharged during a turn is not released again
// at hang-up. Double-release is a doubled inverse — the very thing the
// accumulator exists to prevent.
//
// Scenario: open a.txt (held), open b.txt (held), explicitly close a.txt.
// Then hang up. Only b.txt may be released by the bridge. If a.txt is
// released again, `close-file() ran for 'a.txt'` prints twice — red.

import std/io
import std/bridge
import std/runtime

tor open { path: string } -> string<opened!>
proc open|zig {
    const std = @import("std");
    std.debug.print("open({s})\n", .{path});
    return path;
}

tor close-file { handle: string<!opened> }
proc close-file|zig {
    const std = @import("std");
    std.debug.print("close-file() ran for '{s}'\n", .{handle});
}

std/runtime:register(scope: "files") {
    open(10)
    close-file(1)
}

tor run-turn { br: *std/bridge:Bridge, source: string, label: string }
run-turn = std/bridge:run(br, source)
| result r |> std/io:print.ln("  {{ label:s }}: held={{ r.handles:d }}")
| defined d |> std/io:print.ln("  {{ label:s }}: DEFINED {{ d:s }}")
| event-denied ev |> std/io:print.ln("  {{ label:s }}: DENIED {{ ev:s }}")
| dispatch-error e |> std/io:print.ln("  {{ label:s }}: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  {{ label:s }}: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  {{ label:s }}: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  {{ label:s }}: VALIDATION")
| shape-error _ |> std/io:print.ln("  {{ label:s }}: SHAPE")
| scope-not-found _ |> std/io:print.ln("  {{ label:s }}: NO SCOPE")

[with]std/bridge:create(id: "exactness", scope: "files"): br
|> std/io:print.ln("--- bridge open")
|> run-turn(br, source: "open(path: \"a.txt\")", label: "open a")
|> run-turn(br, source: "open(path: \"b.txt\")", label: "open b")
|> run-turn(br, source: "close-file(handle: \"a.txt\")", label: "close a")
|> std/io:print.ln("--- hang up; only b.txt may be released")
|> std/bridge:close(br)
|> std/io:print.ln("--- done")
