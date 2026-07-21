// Pins the CROSS-MODULE entity discharger. An [entity] store synthesizes Enemy
// and its `take` mints <std/store:taken!>; the despawn handler lives in a
// SEPARATE module (despawner.k), names the type as `input:Enemy`, and consumes
// <std/store:!taken> (bare state is illegal outside the declaring module —
// 330_088). Discharge is LEFT IMPLICIT: auto-discharge must resolve the sole
// consumer ACROSS the module boundary and insert it. Sibling to 330_087 /
// 330_089 — here on the discharger-resolution side rather than the checker.
import std/io
import std/store
import app/despawner

[entity(enemy)]std/store:new(enemies, capacity: 64) { hp: i64 }

std/store:insert(enemies) { hp: 9 }
| row r |> std/store:take(enemies[r])
    | item i |> std/io:print.ln("took hp {{ i.hp:d }}")
