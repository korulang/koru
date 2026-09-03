// PINNED GAP (currently RED) — one Health extent shared across kinds. Player
// and Enemy rows name the same (home, Health) terminal, so the store must
// hold ONE f64 column both write through: same column, different rows. Today
// the store has no entry-resolution step — `KORU161: field 'health' is Health
// — columns are scalars...`: the terminal is refused in field position.
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
