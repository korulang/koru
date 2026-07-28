// PINS: a `when` guard on a `! sweep` arm actually GATES the arm.
//
// It parses, it is accepted, and it does nothing: this program prints `hit 0`
// and `hit 1`. Every row runs the body regardless of the condition.
//
// Silence is what makes this worth a pin of its own. A rejected guard would
// send the author to a different spelling in one compile; an ignored one reads
// as working and quietly widens every write behind it. The sibling verb honours
// its guard — 690_008 is `! query { … } when kind == 1 |> …` and only the
// matching rows are written — so the shape is established and sweep is the one
// that drops it.
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

std/store:sweep(rows)
! sweep { entity.idx } when idx == 1 |> std/io:print.ln("hit {{ idx:d }}")
