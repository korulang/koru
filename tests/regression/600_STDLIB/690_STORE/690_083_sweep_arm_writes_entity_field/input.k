// PINS: a `! query` arm can WRITE the row it is standing on, not only read it.
//
// GREEN since the sweep->query migration.
//
// It was RED under the old `sweep` verb, where the same write was refused and
// the diagnostic read the projection name as a store:
//
//     std/store:stored: unknown store 'entity' - no std/store:new(entity) found
//
// Each row writes a value derived from its OWN column, which is what proves
// the write lands on the row the arm is standing on. It was unguarded on
// purpose back when a `when` guard was silently ignored (690_084), so that a
// guarded write could not pass for the wrong reason; that guard now gates, and
// the shape is kept as-is because writing from an unguarded arm is the
// stronger assertion.
//
// This is the difference between a store you can render and a store you can
// MAINTAIN from a running program. Task #6 carried it as one of three
// query-side read gaps — see 690_084 (guards, also green) and 690_239 (char
// columns, still red).
//
// TWO STALE CLAIMS REMOVED, both false as of the migration: that `sweep` is
// "query's momentary, nestable twin" (the twin belief was held since July, in
// both the code comments and the concept, and the corpus disagreed once
// someone migrated it), and that `query` is "top-level-only by design" —
// koru-examples/kopium/d_turns.k calls `std/store:query` nested inside vaxis
// `! draw` and `! key` arms, and it compiles and runs.
//
// Found writing koru-examples/downloads, where curl's `! progress pr` names
// WHICH transfer moved (`pr.index`) and the program wants to bump that row's
// percent. Three concurrent bars need it; one shared cell is not information.
//
// SIBLING GAP, not pinned here: a sweep body cannot reference the enclosing
// EVENT's parameters either — captures collects mid-chain binds (690_073) and
// not inputs — so the guard above reaches `target` while a body reaching `v`
// gets `use of undeclared identifier 'v'`.
import std/io
import std/store

std/store:new(rows, capacity: 8) { idx: i64, pct: 0[i64] }

std/store:insert(rows) { idx: 0, pct: 0 }
| row _ |> _
std/store:insert(rows) { idx: 1, pct: 0 }
| row _ |> _

std/store:query(rows)
! query e |> std/store:stored { e.pct: e.idx + 10 }

std/store:query(rows)
! query e |> std/io:print.ln("idx {{ e.idx:d }} pct {{ e.pct:d }}")
