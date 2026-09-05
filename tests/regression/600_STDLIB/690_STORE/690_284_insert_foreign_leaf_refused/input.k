// A kinded insert names only that member's leaves. `damage` belongs to
// enemy; a player row that writes it is refused — zero-fill is the
// call site's job, not a back door for the other kind's columns.
import std/proto
import std/store

std/proto:float(Health)

std/proto(Player) {
    health: Health
    score: i64
}

std/proto(Enemy) {
    health: Health
    damage: i64
}

std/store:new(arena, capacity: 8) { player: Player, enemy: Enemy }

std/store:insert(arena, kind: player) { health: 98.6, score: 3, damage: 7 }
