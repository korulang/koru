// PINS `std/grid:sweep` — visit every cell — and with it the STORE/GRID BRIDGE.
//
// The body here is a nested `std/store:stored`: a grid sweep accumulating into a
// store singleton. That is the shape every reduction over a grid takes (count
// the lit lights, count the primes, sum the bucket), and it is the shape a
// flocking gather takes too.
//
// NO BOUNDS CHECK in the loop. The index comes from `0..__koru_size`, so
// validating it would re-establish a fact from one line above — the same
// floor-then-prove-away arc that makes the store's handle check a floor rather
// than a tax, and the reason the grid's trap costs nothing here.
//
// Three mechanisms have to cooperate for this to work, and each was a separate
// failure on the way in:
//   - `c.count` in the body and in the GUARD lowers to a direct cell read, so
//     nested transforms see ordinary host text and need to know nothing about
//     grids;
//   - the body rides an event with the loop index as its input, and the loop is
//     a counted `|zig` for — a grid cannot take, so the trip count is known
//     before the loop starts;
//   - that event is `retain`ed, because the loop calls it from raw Zig and
//     dead_strip's koru-visible reachability cannot see the call. Without it the
//     event is stripped and the emitted loop names a member that does not exist.
//
// 5 + 9 = 14, and the six untouched cells are filtered by the guard rather than
// summed as zeros — so the guard is doing real work, not decoration.
import std/io
import std/store
import std/grid

std/grid:new(cells, size: 8) { count: 0[i64] }
std/store:new(acc) { n: 0[i64] }

std/grid:stored { cells[2].count: 5 }
std/grid:stored { cells[6].count: 9 }

std/grid:sweep(cells)
! sweep c when c.count > 0 |> std/store:stored { acc.n: acc.n + c.count }

std/io:print.ln("sum {{ acc.n:d }}")
