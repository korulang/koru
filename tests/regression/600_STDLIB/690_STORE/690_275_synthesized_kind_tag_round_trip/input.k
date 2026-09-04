// Tag synthesis (write-demand): the store holds Players and Enemies over
// ONE folded Health column, and because inserts name kinds the store
// synthesizes a hidden `kind` column (seed order, 1-based: player=1,
// enemy=2). The query reads `e.kind` like any column — no hand tag, no new
// syntax. When this landed, 690_273's manual tag became the same shape
// minus synthesis.
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

std/store:insert(arena, kind: player) { health: 98.6 }
std/store:insert(arena, kind: player) { health: 72.0 }
std/store:insert(arena, kind: enemy) { health: 30.0 }

std/store:query(arena)
! query e when e.kind == 2 and e.health < 40 |> std/io:print.ln("hurt enemy {{ e.health:f }}")
