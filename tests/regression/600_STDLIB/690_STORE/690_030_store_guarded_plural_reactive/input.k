// A guarded standing reactive rule on a PLURAL store: the `std/store(name)`
// reference face carries a `when` guard, exactly as it does on a singleton
// (690_026). The guard fuses into the write path — checked at each hp write,
// not by a runtime filter — so only rows that cross the threshold announce.
//
// Three rows are damaged by an AoE query (-20 each); the guarded rule fires
// only for the two that drop to <= 0 (15→-5, 18→-2). The survivor (50→30) is
// written too, but the guard filters it out — proving the fuse, not a filter.

import std/io
import std/store

std/store:new(arena, capacity: 64) { hp: i64 }

std/store(arena)
! hp h when h <= 0 |> std/io:print.ln("an enemy has fallen (hp {{ h:d }})")

std/store:insert(arena) { hp: 15 }
| row _ |> _
| full |> _
std/store:insert(arena) { hp: 18 }
| row _ |> _
| full |> _
std/store:insert(arena) { hp: 50 }
| row _ |> _
| full |> _

std/store:query(arena)
! query { entity.hp } when hp > 0 |> std/store:stored { entity.hp: entity.hp - 20 }
