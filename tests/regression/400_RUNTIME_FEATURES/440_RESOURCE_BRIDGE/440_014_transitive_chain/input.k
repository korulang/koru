// R5 — TRANSITIVE CHAINS: the guard propagates depth-first.
//
// Cordis's recovery composed across levels (Theorem 16 + Corollary 21:
// inverses release in reverse application order, dependents before
// providers at every depth). The bridge pool must release a CHAIN
// leaf-first: query2 depends on query1 depends on file_1 — closing must
// release query_2, then query_1, then file_1.
//
// A single-pass release (releasing only handles with no dependents in one
// sweep, no re-scan) would release query_2 and then strand the rest — the
// pool reports stranded handles and close panics. The guarded loop must
// re-scan until everything is released.

import std/io
import std/bridge
import std/runtime

tor open { path: string } -> string<opened!>
proc open|zig {
    const std = @import("std");
    std.debug.print("open({s})\n", .{path});
    return path;
}

tor query { conn: string, handle: string } -> string<queried!>
proc query|zig {
    _ = conn;
    return handle;
}

tor close-file { handle: string<!opened> }
proc close-file|zig {
    const std = @import("std");
    std.debug.print("close-file() ran for '{s}'\n", .{handle});
}

tor close-query { handle: string<!queried> }
proc close-query|zig {
    const std = @import("std");
    std.debug.print("close-query() ran for '{s}'\n", .{handle});
}

std/runtime:register(scope: "files") {
    open(10)
    query(10)
    close-file(1)
    close-query(1)
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

[with]std/bridge:create(id: "chain", scope: "files"): br
|> std/io:print.ln("--- bridge open")
|> run-turn(br, source: "open(path: \"a.txt\")", label: "open")
|> run-turn(br, source: "query(conn: \"a.txt\", handle: \"q1.txt\")", label: "q1")
|> run-turn(br, source: "query(conn: \"q1.txt\", handle: \"q2.txt\")", label: "q2")
|> std/io:print.ln("--- hang up; chain must release leaf-first, all three")
|> std/bridge:close(br)
|> std/io:print.ln("--- done")
