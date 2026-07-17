// THE ARENA, RUNG 4 — a live SUM(hp) aggregate maintained by the store's
// full lifecycle contract, all three faces of Ruling 5 on one plural store:
//   `inserted { hp }`      — births ADD to the pool
//   `updated { old, new }` — damage flows its DELTA into the pool
//   `removed { hp }`       — deaths remove the corpse's REMAINING hp
// The pool therefore equals the sum over live rows at every settled point —
// including the overkill case: a foe driven to -8 subtracts past zero at
// damage time, and its removal adds the overshoot back. No reconciliation
// pass, no scan: the aggregate rides the write paths ("everything reactive
// compiles down into these same interceptor branches").
//
// Contract-before-subscription: each damage write settles the pool (and
// prints it, via the board's own reactive rule) BEFORE the arena's guarded
// death-announcement rule observes the new hp.

import std/io
import std/store

std/store:new(board) { alive: 0[i64], kills: 0[i64], pool: 0[i64] }

std/store:new(arena) { hp: i64, kind: i64 }
! inserted { hp } |> std/store:stored { board.alive: board.alive + 1 } |> std/store:stored { board.pool: board.pool + hp }
! removed { hp } |> std/store:stored { board.alive: board.alive - 1 } |> std/store:stored { board.kills: board.kills + 1 } |> std/store:stored { board.pool: board.pool - hp }
! updated { old, new } |> std/store:stored { board.pool: board.pool + new - old }

std/store(board)
! alive a |> std/io:print.ln("board: {{ a:d }} alive")
! kills k |> std/io:print.ln("board: {{ k:d }} killed")
! pool p |> std/io:print.ln("board: hp pool {{ p:d }}")

std/store(arena)
! hp h when h <= 0 |> std/io:print.ln("a foe reels ({{ h:d }} hp)")

std/store:insert(arena) { hp: 30, kind: 1 }
| row _ |> _
| full |> _
std/store:insert(arena) { hp: 12, kind: 1 }
| row _ |> _
| full |> _
std/store:insert(arena) { hp: 40, kind: 2 }
| row _ |> _
| full |> _

std/store:query(arena)
! query { entity.hp, entity.kind } when kind == 1 |> std/store:stored { entity.hp: entity.hp - 20 }

std/store:query(arena)
! query { entity.hp } when hp <= 0 |> std/store:take(arena[entity])
    | item i |> std/io:print.ln("culled a foe at {{ i.hp:d }} hp")
