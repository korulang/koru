// `is` with a member outside the vocabulary refuses loudly, naming the
// members — the guard-side mirror of 690_276's insert refusal.
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

std/store:insert(arena, kind: player) { health: 98.6 }

std/store:query(arena)
! query e when e is ghost |> std/store:stored { e.health: 0.0 }
