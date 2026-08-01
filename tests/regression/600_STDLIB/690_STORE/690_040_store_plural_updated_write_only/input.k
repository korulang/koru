// FIRING DISCIPLINE for plural `! updated`: it observes WRITES and only
// writes. Three non-writes must stay silent — (1) insert: births arrive
// whole (O9 birth-is-not-a-write); (2) take's swap-remove: relocating the
// last row into the freed slot is storage mechanics, not a semantic
// update; (3) the take itself. The one genuine row write fires exactly
// once.
//
// `! updated _` is the discard form (same KORU100 discipline as
// `! inserted _`, 690_016): the body needs no images, so — per the (c)
// usage-synthesis lean — NO pre-image read is synthesized; the write path
// stays write-only.

import std/io
import std/store

std/store:new(tally) { writes: 0[i64] }

std/store:new(crew, capacity: 64) { hp: i64 }
! updated _ |> std/store:stored { tally.writes: tally.writes + 1 }

std/store:watch(tally)
! writes w |> std/io:print.ln("write {{ w:d }}")

std/store:insert(crew) { hp: 10 }
| row a |> std/store:insert(crew) { hp: 20 }
    | row _ |> std/store:insert(crew) { hp: 30 }
        | row _ |> std/store:take(crew[a])
            | item i |> std/io:print.ln("took {{ i.hp:d }}")

std/store:query(crew)
! query e when e.hp == 30 |> std/store:stored { e.hp: e.hp + 1 }
