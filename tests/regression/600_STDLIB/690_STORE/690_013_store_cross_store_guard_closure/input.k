// ASPIRATION — TODO idea pin. Queue (j) cross-store reactive closure:
// the hp watch is guarded on ui.mode — writing ui.mode must RE-EVALUATE
// the guard and fire the watch with hp's current value (false->true
// transition), because taps follow the guard's free-name CLOSURE, not
// just the row store. Without (j) the ui.mode write fires nothing.
// TRANSITION SEMANTICS PROVISIONAL (couples to O1's enter/leave ruling).

import std/io
import std/store

std/store:new(game) { hp: 0[i64] }
std/store:new(ui) { mode: 0[i64] }

std/store:watch(game)
! hp h when ui.mode == 1 |> std/io:print.ln("shown: {{ h:d }}")

std/store:stored { game.hp: 7 }
std/store:stored { ui.mode: 1 }
