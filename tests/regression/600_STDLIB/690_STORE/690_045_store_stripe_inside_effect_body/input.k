// stripe(store) is a MOMENTARY verb: legal inside an inlined effect-branch
// body (the per-frame firing point — koru-libs raylib bounce.k). The rule
// fires once at its root position, once from the in-body stripe.
import std/io
import std/store

std/store:new(game, capacity: 64) { hp: i64 }

std/store:insert(game) { hp: 3 }
| row _ |> _
| full |> _

[name(report)]std/store:query(game)
! query e |> std/io:print.ln("hp {{ e.hp:d }}")

pub tor beat { x: i64 }
! tick i64

beat = tick(x)

beat(x: 2)
! tick t |> std/store:stripe(game)
