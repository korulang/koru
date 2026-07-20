// Pins std/store's [explainer]: `koruc input.k explain` reports what std/store
// DECIDED about these stores — count, per-store layout (singleton vs SoA), field
// count, watcher count — every value DERIVED from the raw call-forms (the same
// is_plural / field / watch logic `new` uses), never hardcoded. Two singleton
// stores; `global` is watched once, `game` not at all.
import std/io
import std/store
import std/explain

std/store:new(global) { total: 0[i64] }
std/store:new(game) { hp: 0[i64] }
! updated { old, new } |> std/store:stored { global.total: global.total + new - old }
std/store:watch(global)
! total t |> std/io:print.ln("total: {{ t:d }}")
std/store:stored { game.hp: 5 }
std/store:stored { game.hp: 12 }
