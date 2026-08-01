// PINS: a `when` guard on a `! query` arm actually GATES the arm.
//
// GREEN since the sweep->query migration. This prints `hit 1` alone.
//
// It was RED, and the header used to say so: under the old `sweep` verb the
// guard parsed, was accepted, and did nothing — every row ran the body and
// this program printed `hit 0` and `hit 1`. Silence is what earned it a pin.
// A rejected guard sends the author to a different spelling in one compile;
// an ignored one reads as working and quietly widens every write behind it.
//
// What closed it was not a fix to `sweep` but the migration retiring `sweep`
// altogether: the arm now spells `query`, the verb that honours its guard
// (690_008 is `! row { … } when kind == 1 |> …`, matching rows only). Task #6
// carried this as one of three query-side read gaps; this is the one that had
// already closed by the time the task was read. The other two: 690_083
// (row-binding writes, also green) and 690_239 (char columns, still red).
//
// Found writing koru-examples/downloads: `! progress pr` names WHICH transfer
// moved, and the natural update is a guarded sweep that touches only that row.
// With the guard ignored, every transfer's bar takes every transfer's percent —
// the exact bug the three-bar rewrite existed to remove.
import std/io
import std/store

std/store:new(rows, capacity: 8) { idx: i64, pct: 0[i64] }

std/store:insert(rows) { idx: 0, pct: 0 }
| row _ |> _
std/store:insert(rows) { idx: 1, pct: 0 }
| row _ |> _

std/store:query(rows)
! query e when e.idx == 1 |> std/io:print.ln("hit {{ e.idx:d }}")
