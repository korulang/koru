// PINS: a standing rule whose body is ONLY a tor call — `bump(n: e.x)` —
// reaches a store write through the callee's subflow, and that write LANDS.
// The rule site's own text names no store and no written column: its visible
// footprint is the argument read `e.x`. The write to `b` lives in the callee.
// This is the shape where a PER-SITE syntactic read/write-set derivation
// stops: the site's sets require chasing the call graph (subflows are in the
// AST and chaseable; a `|zig` proc body is opaque and is not). Sibling of
// 690_202, which names the unchecked reorder license this footprint feeds.
import std/io
import std/store

std/store:new(a, capacity: 4) { x: i64 }
std/store:new(b, capacity: 8) { y: i64 }

pub tor bump { n: i64 }

bump = std/store:insert(b) { y: n * 2 }
| row _ |> std/io:print.ln("callee wrote b")
| full |> _

std/store:query(a)
! query e |> bump(n: e.x)

std/store:insert(a) { x: 5 }
| row _ |> _
| full |> _

std/store:sweep(b)
! sweep r |> std/io:print.ln("b has {{ r.y:d }}")
