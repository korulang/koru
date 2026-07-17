// ASPIRATION — TODO idea pin. Ruling 4: subscriptions are consumer-level
// and MANY — two watches on the same field both fire, in source order.
// Today store.kz walls this loudly (multi-watch sequencing splice).

import std/io
import std/store

std/store:new(game) { entities: 0[i64] }

std/store:watch(game)
! entities e |> std/io:print.ln("first: {{ e:d }}")

std/store:watch(game)
! entities e |> std/io:print.ln("second: {{ e:d }}")

std/store:stored { game.entities: game.entities + 1 }
