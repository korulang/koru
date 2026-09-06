// ASPIRATIONAL (design capture 2026-09-06 — red until the surface lands).
// The `set` surface as designed: a POOL over `kind` declarations. A kind is
// shape + kind identity with NO storage and NO capacity slot; the set owns
// the capacity; inserts route through the kind (the kind name IS the kind);
// shared leaves fold into one contiguous extent, private leaves per-kind.
// The current implementation of `set` is a view over new stores (sequential
// loops, no shared extent) — this test pins the TARGET, not that behavior.
// Flips green when `std/store:kind` + the pooled `std/store:set` land.
// Currently red: unknown transform `std/store:kind`. Output is identical to
// 690_287 (same program, new surface).
import std/io
import std/proto
import std/store

std/proto:int(Strength)
std/proto:int(Mana)
std/proto:int(Armor)

std/proto(Player) {
    str: Strength
    mana: Mana
}

std/proto(Enemy) {
    str: Strength
    armor: Armor
}

std/store:kind(Player) { Player }
std/store:kind(Enemy) { Enemy }

std/store:set(Entities, capacity: 16) {
    Player
    Enemy
}

std/store:insert(Player) { str: 18, mana: 12 }
std/store:insert(Enemy) { str: 10, armor: 5 }

std/store:query(Entities)
! query e |> std/io:print.ln("entity {{ e.str:d }}")

std/store:query(Entities)
! query e when e is Player |> std/io:print.ln("player {{ e.str:d }} {{ e.mana:d }}")

std/store:query(Entities)
! query e when e is Enemy |> std/io:print.ln("enemy {{ e.str:d }} {{ e.armor:d }}")
