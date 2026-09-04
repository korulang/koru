// Once any insert names a kind, the tag exists and every insert must name
// one. The second insert below is kindless on a kinded store — refused with
// the naming it needs, never silently tagged zero.
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
std/store:insert(arena) { health: 30.0 }
