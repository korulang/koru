// Pins that an [entity] store's take obligation rides the AUTO-DISCHARGE rails.
// `take` mints Enemy<std/store:taken!>; the branch ends WITHOUT an explicit
// discharge call, and auto-discharge inserts the sole <std/store:!taken>
// consumer (discharge-enemy) before the terminator — exactly as 335_050
// auto-inserts `release` for a bare <held!>. The entity obligation is not
// special: one discharger, resolved by type ("exactly one disposal option" —
// auto_discharge_inserter), planted for us. Contrast 690_023 (same setup,
// discharge called EXPLICITLY) and 690_024 (take with no discharger authored
// at all — rejected).
import std/io
import std/store

[entity(enemy)]std/store:new(enemies, capacity: 64) { hp: i64 }

pub event discharge-enemy { enemy: Enemy<std/store:!taken> }
discharge-enemy = std/io:print.ln("despawned an enemy")

std/store:insert(enemies) { hp: 9 }
| row r |> std/store:take(enemies[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}")
