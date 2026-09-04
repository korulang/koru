// A kind must name a seed member. `ghost` is no member of this store —
// the vocabulary is the seed's field names (player, enemy), refused loudly
// rather than tagged as a phantom third kind.
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

std/store:insert(arena, kind: ghost) { health: 10.0 }
