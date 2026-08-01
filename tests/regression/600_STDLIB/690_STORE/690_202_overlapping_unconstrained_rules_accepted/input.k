// PINS: two standing rules whose WRITE sets overlap on one column, with NO
// declared edge, are ACCEPTED — no refusal, no demanded [depends_on] — and
// both fire per firing point. Their relative order is contractually
// UNSPECIFIED (690_044's fusion license), so this pin's writes commute
// (+1, +10): hp 100 +11 at the root sites +11 under the stripe = 122 under
// ANY legal schedule. The non-commuting sibling — a reader overlapping a
// writer, edge undeclared — has no order-independent observable to pin:
// nothing computes a rule's read/write sets, so the reorder license is
// checked by nobody and that shape's result is whatever the scheduler
// happens to do. Serializing it is the author's job, via the edge 690_201
// pins; refusing or proving it is the O13 fusion work's admission ticket.
import std/io
import std/store

std/store:new(game, capacity: 8) { hp: i64 }

std/store:insert(game) { hp: 100 }
| row _ |> _
| full |> _

std/store:rule(game)
! row a |> std/store:stored { a.hp: a.hp + 1 }

std/store:rule(game)
! row b |> std/store:stored { b.hp: b.hp + 10 }

std/store:stripe(game)

std/store:query(game)
! query r |> std/io:print.ln("hp {{ r.hp:d }}")
