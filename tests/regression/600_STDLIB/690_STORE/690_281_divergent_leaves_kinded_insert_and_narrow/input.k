// Disjoint extra leaves become columns. A kinded insert names only its
// member's leaves; the other kind's columns are zero-filled at the call
// site. A query reads a private leaf only after the guard narrows to a
// kind that owns it (`e is player` / `e is enemy`).
import std/io
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

std/store:insert(arena, kind: player) { health: 98.6, score: 3 }
std/store:insert(arena, kind: enemy) { health: 30.0, damage: 7 }

std/store:query(arena)
! query e when e is player |> std/io:print.ln("player score {{ e.score:d }} health {{ e.health:f }}")

std/store:query(arena)
! query e when e is enemy |> std/io:print.ln("enemy dmg {{ e.damage:d }} health {{ e.health:f }}")
