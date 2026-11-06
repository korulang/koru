// ASPIRATION — pin (gallery transition spike, 2026-11-06): a multi-field
// stored{} envelope refuses cross-store writes — "a multi-field envelope
// writes ONE store this rung ('a' vs 'b')". Wanted per Lars: stored chains
// and the source-block names the store, so per-frame derived state across
// two stores lands in one envelope. Today the only spelling is N separate
// stored calls — which also cannot read a sibling field written upstream
// in the same logical update without store round-trips.
import std/io
import std/store

std/store:new(a) { x: 0[i64] }
std/store:new(b) { y: 0[i64] }

std/store:watch(a)
! x v |> std/io:print.ln("ax {{ v:d }}")

std/store:watch(b)
! y v |> std/io:print.ln("by {{ v:d }}")

std/store:stored { a.x: 1, b.y: 2 }
