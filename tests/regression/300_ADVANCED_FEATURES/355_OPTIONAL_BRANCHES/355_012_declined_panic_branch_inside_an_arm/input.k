// PINS: a declined `?!` panic branch is LOUD from inside an arm, not only at
// the top level of a flow.
//
// `?!` exists to mean "unsafe to ignore": a consumer may decline to write the
// arm, and the compiler synthesizes a loud one so the path cannot silently
// proceed. 355_009 pins that a plain `?` optional stays silent, which is the
// deliberate contrast.
//
// Both takes below decline `| empty` — the first at flow top level, the
// second nested inside the `for` arm's body. Synthesis descends into arm
// continuations, so the nested decline gets the same synthesized @panic:
// the second take's `| empty` fire traps (EXPECT_TRAP) instead of reaching
// the final print. This pin was RED when written (a538e98c3) and went green
// when the synthesis learned to descend (00341d7c4).
import std/io
import std/store
import std/control

std/store:new(log) { h: -1[i64] }
std/store:new(rows, capacity: 4) { v: i64 }

std/store:insert(rows) { v: 42 }
    | row r |> std/store:stored { log.h: r }
    | full |> _

std/store:take(rows[log.h])
    | item first |> std/io:print.ln("first take: {{ first.v:d }}")

// The same declined branch, one level in. The row is already gone, so `| empty`
// is the only outcome this call can produce.
for(0..1)
! each _ |> std/store:take(rows[log.h])
    | item second |> std/io:print.ln("SECOND TAKE RETURNED A ROW: {{ second.v:d }}")

std/io:print.ln("REACHED THE END — the declined panic branch was silent")
