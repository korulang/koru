// Pins the ENTITY analogue of 335_020: when a taken Enemy<taken!> reaches scope
// exit with TWO events consuming <!taken>, auto-discharge has multiple discharge
// options and must NOT silently pick — KORU030 fires, forcing an explicit choice.
// Same "ambiguity forces a pick" wall as KORU140 ([with] collision) and 335_020
// (string free vs release). The discharger is authored per type; two of them is
// the ambiguity. Removing either despawn-* below makes 690_034's auto-insert fire.
import std/io
import std/store

[entity(enemy)]std/store:new(enemies) { hp: i64 }

pub event despawn-quietly { enemy: Enemy<!taken> }
despawn-quietly = std/io:print.ln("quietly despawned")

pub event despawn-loudly { enemy: Enemy<!taken> }
despawn-loudly = std/io:print.ln("LOUDLY despawned")

std/store:insert(enemies) { hp: 9 }
| row r |> std/store:take(enemies[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}")
