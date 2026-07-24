// `[entity(<name>)]` opts a store into the per-store disposal contract: `take`
// mints `<std/store:taken!>` on the synthesized entity type (`Enemy`), and the
// USER authors the discharger — the despawn handler consuming `<std/store:!taken>`.
// The store presumes nothing; base-type filtering gives per-store distinctness
// while the obligation state stays shared. Here take + discharge compiles and runs.
import std/io
import std/store

[entity(enemy)]std/store:new(enemies, capacity: 64) { hp: i64 }

pub tor discharge-enemy { enemy: Enemy<std/store:!taken> }
discharge-enemy = std/io:print.ln("despawned an enemy")

std/store:insert(enemies) { hp: 9 }
| row r |> std/store:take(enemies[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}") |> discharge-enemy(enemy: i)
