// Slice A (2026-09-04): one Health extent shared across kinds. Player
// and Enemy rows name the same (home, Health) terminal, so the store holds
// ONE column both write through: same column, different rows. The store
// resolves the bare in-scope terminal and emits the alias verbatim (the
// `const Health = f64` alias lowers it). `30.0` prints as `30` — the `:f`
// formatter's honest float spelling (690_021's `23 C` precedent), not a
// second concept smuggled in by spelling.
import std/io
import std/proto
import std/store

std/proto:float(Health)

std/proto(Player) {
    health: Health
}

std/proto(Enemy) {
    health: Health
}

std/store:new(arena, capacity: 8) { health: Health }

std/store:insert(arena) { health: 98.6 }
std/store:insert(arena) { health: 30.0 }

std/store:query(arena)
! query e |> std/io:print.ln("health {{ e.health:f }}")
