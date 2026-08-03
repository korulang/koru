// PINS: the swept cell is a WRITE TARGET, not only a value.
//
//   std/grid:sweep(cells)
//   ! sweep c when c.n > 0 |> std/grid:stored { c.avg: c.sum / c.n }
//
// `std/store` has always worked this way — `! query e |> stored { e.px: e.px +
// e.vx }` writes through the row binding — and the grid did not, so this was
// an ASYMMETRY between the two tables rather than a missing feature. The cause
// was one line: the sweep rewrote `c.field` directly to an indexed LOAD, which
// is the right emitted code and leaves nothing on the left of a write for
// `stored` to parse. Rewriting to the source-level ADDRESS instead
// (`cells[<cursor>].field`) makes the binding an ordinary address, so the
// existing write path threads it with no new machinery and reads lower through
// the one lowering every other read uses.
//
// WHAT IT COST, and it is the honest half: the address goes through
// `__koru_at`, so the sweep's reads now carry a bounds check they did not
// carry before. The index is constructed by the loop from `0..size` against a
// comptime-known bound, which is exactly the case the declaration's header
// calls a floor rather than a tax — provable in range, and deleted by the
// optimizer. The claim is checkable: `boids` in tests/benchmarks is the
// workload that would show it if it were wrong.
//
// A REQUEST BLOCK exposing the cell's index (`! sweep { [cell]c, [id]i }`) was
// built alongside this and CUT before shipping. It hands the program a raw
// position as a value — the thing the store's handle discipline forbids — and
// what it buys is addressing a cell other than the one being visited. DOTS'
// BoidSystem reads only a boid's own bucket, so nothing here asks for it yet.
//
// The oracle is arithmetic that cannot come out right by accident: two cells
// with different counts and sums, averaged in place, then summed with a third
// cell written from a neighbour's sweep. 29 + 99 + 37 = 165.
import std/io
import std/store
import std/grid

std/grid:new(cells, size: 8) { n: 0[i64], avg: 0.0[f32], sum: 0.0[f32] }
std/store:new(acc) { total: 0[i64] }

std/grid:stored { cells[2].n: 4 }
std/grid:stored { cells[2].sum: 10.0 }
std/grid:stored { cells[5].n: 2 }
std/grid:stored { cells[5].sum: 7.0 }

// The write reads three columns of the cell it is writing, in one block.
std/grid:sweep(cells)
! sweep c when c.n > 0 |> std/grid:stored { c.avg: c.sum / @as(f32, @floatFromInt(c.n)) }

// A guarded sweep may still write a cell it names outright — the binding form
// and the addressed form are the same mechanism.
std/grid:sweep(cells)
! sweep c when c.n == 4 |> std/grid:stored { cells[3].n: 99 }

std/grid:sweep(cells)
! sweep c |> std/store:stored { acc.total: acc.total + @as(i64, @intFromFloat(c.avg * 10.0)) + c.n }

std/io:print.ln("total {{ acc.total:d }}")
