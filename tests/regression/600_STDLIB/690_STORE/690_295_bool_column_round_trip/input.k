// A bool proto field lands as a real store column. `std/proto:bool(Alive)`
// lowers to `const Alive = bool` and the column is `[N]Alive` — one byte per
// row per flag, not one bit. This test pins the current shape and the
// round-trip; bit-packing is unmeasured and unplanned (checked this session:
// no bool store column existed in the suite before this pin).
import std/io
import std/proto
import std/store

std/proto:bool(Alive)

std/proto(Creature) {
    alive: Alive
}

std/store:new(critters, capacity: 8) { creature: Creature }

std/store:insert(critters) { creature.alive: true }
std/store:insert(critters) { creature.alive: false }

std/store:query(critters)
! query e |> std/io:print.ln("alive {{ e.creature.alive:any }}")
