// `is` on a kindless store refuses loudly: no insert names `kind:`, so
// there is no tag to read. Tag the inserts first.
import std/proto
import std/store

std/proto:float(Health)

std/proto(Player) {
    health: Health
}

std/proto(Enemy) {
    health: Health
}

std/store:new(arena, capacity: 8) { player: Player, enemy: Enemy }

std/store:insert(arena) { health: 98.6 }

std/store:query(arena)
! query e when e is enemy |> std/store:stored { e.health: 0.0 }
