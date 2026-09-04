// K1 (2026-09-04): union members expand to folded columns. GameEntities
// holds Players and Enemies; both name (home, Health), so the store derives
// ONE Health column from its members. No tag, nothing asks — plain full-row
// inserts, plain query. The members are the column source of truth: adding a
// leaf to Player re-folds here.
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

std/store:new(arena, capacity: 8) { player: Player, enemy: Enemy }

std/store:insert(arena) { health: 98.6 }
std/store:insert(arena) { health: 30.0 }

std/store:query(arena)
! query e |> std/io:print.ln("health {{ e.health:f }}")
