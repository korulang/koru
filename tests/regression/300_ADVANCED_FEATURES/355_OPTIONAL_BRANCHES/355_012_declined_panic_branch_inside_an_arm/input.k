// PINS: a declined `?!` panic branch is LOUD from inside an arm, not only at
// the top level of a flow.
//
// `?!` exists to mean "unsafe to ignore": a consumer may decline to write the
// arm, and the compiler synthesizes a loud one so the path cannot silently
// proceed. 355_009 pins that a plain `?` optional stays silent, which is the
// deliberate contrast.
//
// The synthesis reads a flow's own continuations and never descends, so an
// invocation nested inside an arm gets NO synthesized arm and NO dispatch
// guard. The written arm's body then runs whatever the callee actually
// returned. Both takes below decline `| empty`; only the top-level one is
// currently protected.
//
// Measured on both lanes when this was pinned: Zig ran to completion printing
// the final line, exit 0. JavaScript failed only by accident, with a
// TypeError, because this arm's body happens to dereference the payload — a
// body that merely binds it stays silent there too, which is how a shipped
// consumer (koru-libs dom/app, the row removal) carried it unnoticed.
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
