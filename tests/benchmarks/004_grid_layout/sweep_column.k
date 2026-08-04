// Sweep-dominated shape, COLUMN layout (the default).
//
// Nine i64 fields; the timed sweeps read exactly ONE of them across every
// cell. Column layout stores that field as its own contiguous array, so the
// read vectorises. Pairs with sweep_row.k, which is byte-identical except for
// the annotation — see README.md for the measured pair.
import std/io
import std/store
import std/grid

std/grid:new(gg, size: 1000000) { a: 0[i64], b: 0[i64], c: 0[i64], d: 0[i64], e: 0[i64], f: 0[i64], g: 0[i64], h: 0[i64], i: 0[i64] }
std/store:new(acc) { n: 0[i64] }

for(0..1000000)
! each k |> std/grid:stored { gg[k].a: @as(i64, @intCast(k)) }

std/io:print.ln("seeded")

for(0..400)
! each _ |> std/grid:sweep(gg)
    ! sweep c |> std/store:stored { acc.n: acc.n + c.a }

std/io:print.ln("total {{ acc.n:d }}")
