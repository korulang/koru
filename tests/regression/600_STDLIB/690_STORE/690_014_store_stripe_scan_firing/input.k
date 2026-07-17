// ASPIRATION — TODO idea pin. O13 (RULED: no archetypes; fusion) gave
// (l) query temporality its candidate resolution: a query is a STANDING
// RULE, and `stripe(game)` is its scan-driven firing mode — run the
// compiled rules across the corpus once, now, no write required.
// Scalar-degenerate case: the watch fires with the CURRENT value under a
// stripe. `stripe` verb spelling PROVISIONAL.

import std/io
import std/store

std/store:new(game) { hp: 0[i64] }

std/store:watch(game)
! hp h |> std/io:print.ln("hp {{ h:d }}")

std/store:stored { game.hp: 5 }
std/store:stripe(game)
