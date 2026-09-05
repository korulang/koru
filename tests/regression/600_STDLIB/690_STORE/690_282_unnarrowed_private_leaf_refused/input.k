// A private leaf is unreadable until the guard names a kind that owns it.
// Unnarrowed `e.score` on a Player/Enemy store refuses — the column exists
// (every row has a slot) but only player rows hold a score.
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

std/store:query(arena)
! query e |> std/io:print.ln("score {{ e.score:d }}")
