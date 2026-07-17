// `[entity(<name>)]` opts a store into the per-store disposal contract: `take`
// mints the `<taken!>` obligation on the synthesized entity type (`Enemy`), and
// the USER authors the discharger — the despawn handler consuming `<!taken>`.
// The store presumes nothing; base-type filtering + the local `taken` state give
// per-store distinctness. Here take + discharge compiles and runs.
import std/io
import std/store

[entity(enemy)]std/store:new(enemies) { hp: i64 }

pub event discharge-enemy { enemy: Enemy<!taken> }
discharge-enemy = std/io:print.ln("despawned an enemy")

std/store:insert(enemies) { hp: 9 }
| row r |> std/store:take(enemies[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}") |> discharge-enemy(enemy: i)
