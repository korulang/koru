// `is`-sugar in guards (2026-09-05): the kind tag reads by NAME, so guards
// never name magic ordinals. `e is enemy` is `e.kind == 2` with the
// seed-order ordinal filled in from the member vocabulary; `e.kind is ...`
// spells the same read; `!(e is ...)` negates it. The standing rule below
// pins the rule path too — its projection carries the tag column, which a
// hand-written `e.kind == 2` rule guard could not reach before this.
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
std/store:insert(arena, kind: enemy) { health: 30.0 }

std/store:rule(arena)
! row e when e is enemy |> std/store:stored { e.health: e.health - 5.0 }

std/store:query(arena)
! query e when e is enemy and e.health < 40 |> std/io:print.ln("hurt enemy {{ e.health:f }}")

std/store:query(arena)
! query e when e.kind is player or !(e is enemy) |> std/io:print.ln("player {{ e.health:f }}")
