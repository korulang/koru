// PINS: a [depends_on] edge orders WHOLE corpus passes, not per-row visits —
// under the stripe the dependent rule's FIRST firing follows the depended-on
// rule's LAST (`A 2` precedes `B 1`). Row-fused execution of these two rules
// (A 1, B 1, A 2, B 2) would break this pin: the fusion license 690_044 names
// covers only UNCONSTRAINED rules, and the declared edge is the stratification
// unit — ruling (h)'s DBSP-strata reading, a stratum completes before the next
// begins. First four lines are the two sites' root-position sweeps (per site,
// textual order); the last four are the stripe.
import std/io
import std/store

std/store:new(game, capacity: 8) { hp: i64 }

std/store:insert(game) { hp: 1 }
| row _ |> _
| full |> _

std/store:insert(game) { hp: 2 }
| row _ |> _
| full |> _

[name(alpha)]std/store:rule(game)
! row a |> std/io:print.ln("A {{ a.hp:d }}")

[name(beta)|depends_on(alpha)]std/store:rule(game)
! row b |> std/io:print.ln("B {{ b.hp:d }}")

std/store:stripe(game)
