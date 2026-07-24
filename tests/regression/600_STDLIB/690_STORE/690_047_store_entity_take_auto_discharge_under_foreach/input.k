// COMBINATORIAL (challenge 007) — an [entity] store's `<std/store:taken!>`
// obligation, minted and auto-discharged once PER ITERATION of a generic
// `for(0..n) ! each` loop, rather than once at flow-head.
// Grounded on: 690_034 (bare take-with-no-explicit-discharge resolves via
// auto-discharge — the sole `<std/store:!taken>` consumer is inserted before
// the branch terminator) + 330_098/330_053 (an obligation's tracking survives
// being nested one level inside a for-each `! each` iteration body) + 670_030/
// 670_033 (the for-each shape itself, and its arms indenting one level under
// an enclosing branch's target expression).
// Compositionality predicts the per-iteration scope the for-each opens is
// exactly the branch auto-discharge already resolves against at flow-head —
// so each of the 3 iterations independently mints, tracks and auto-discharges
// its own `Enemy<std/store:taken!>`, with no explicit discharge call anywhere.
import std/io
import std/store

[entity(enemy)]std/store:new(enemies, capacity: 64) { hp: i64 }

pub tor discharge-enemy { enemy: Enemy<std/store:!taken> }
discharge-enemy = std/io:print.ln("despawned an enemy")

for(0..3)
! each _ |> std/store:insert(enemies) { hp: 9 }
    | row r |> std/store:take(enemies[r])
        | item it |> std/io:print.ln("took hp {{ it.hp:d }}")
