// The bare `std/store(<name>)` reference form is a PROGRAM-WIDE reactive attach:
// `std/store(game) ! hp h |> …` registers a standing rule that fires on every
// write to that field — exactly like `watch`. A [pre]-phase rewrite renames the
// bare `default` invocation to `watch` before create scans, so the entire
// write-path-fused watch machinery handles it with no duplication. This is the
// store as a reference you hang reactive rules off — the reactive-substrate face.
import std/io
import std/store

std/store:new(game) { hp: 0[i64] }

std/store(game)
! hp h |> std/io:print.ln("hp {{ h:d }}")

std/store:stored { game.hp: 5 }
std/store:stored { game.hp: 9 }
