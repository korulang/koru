// Plural stripe fires standing rules in depends_on TOPO order (2026-07-18
// rung): [name(x)] names a rule (bare idents, module-namespaced),
// [depends_on(x)] orders it. Root-position sweeps keep textual order
// (first two lines); the stripe inverts it per the declared edge (last
// two). Unconstrained rules are contractually UNORDERED (fusion license).
import std/io
import std/store

std/store:new(game, capacity: 64) { hp: i64 }

std/store:insert(game) { hp: 5 }
| row _ |> _
| full |> _

[name(second)|depends_on(first)]std/store:rule(game)
! row e |> std/io:print.ln("second {{ e.hp:d }}")

[name(first)]std/store:rule(game)
! row e |> std/io:print.ln("first {{ e.hp:d }}")

std/store:stripe(game)
