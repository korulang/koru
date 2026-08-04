// Sweep-dominated shape, ROW layout.
//
// Byte-identical to sweep_column.k except for `[layout(row)]`. Every cell's
// nine fields are packed into one record, so reading a single field across all
// cells now strides 72 bytes per element and cannot vectorise. This is the
// LOSING direction of the annotation, and it exists so the trade is on the
// board next to the boids win rather than only the half that flatters it.
import std/io
import std/store
import std/grid

[layout(row)]std/grid:new(gg, size: 1000000) { a: 0[i64], b: 0[i64], c: 0[i64], d: 0[i64], e: 0[i64], f: 0[i64], g: 0[i64], h: 0[i64], i: 0[i64] }
std/store:new(acc) { n: 0[i64] }

for(0..1000000)
! each k |> std/grid:stored { gg[k].a: @as(i64, @intCast(k)) }

std/io:print.ln("seeded")

for(0..400)
! each _ |> std/grid:sweep(gg)
    ! sweep c |> std/store:stored { acc.n: acc.n + c.a }

std/io:print.ln("total {{ acc.n:d }}")
