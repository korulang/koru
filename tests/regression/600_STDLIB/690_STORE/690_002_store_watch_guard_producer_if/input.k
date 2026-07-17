// ASPIRATIONAL (RED by design until std/store rung 1 lands — see DESIGN.md).
// The guard is compiled INTO the write path: `when` on a watch branch is
// planted at the producer site, taps-style (koru_std/taps.kz
// wrapContinuation, ".condition = rewritten_condition" — the grounded
// precedent). No call happens unless the guard passes; a non-matching
// write costs one comparison, zero dispatch.
//
// Guard grammar grounded: `! tick i when i % 2 == 0 |>` (400_087),
// `! key k when k.ch == 'q' |>` (koru-libs hello_vaxis).
//
// Writes drive entities to 1, 2, 3; the watch fires only past the
// threshold.

import std/io
import std/store

std/store:new(game) { entities: 0[i64] }

std/store:watch(game)
! entities e when e > 1 |> std/io:print.ln("big: {{ e:d }}")

std/store:stored { game.entities: game.entities + 1 }
std/store:stored { game.entities: game.entities + 1 }
std/store:stored { game.entities: game.entities + 1 }
