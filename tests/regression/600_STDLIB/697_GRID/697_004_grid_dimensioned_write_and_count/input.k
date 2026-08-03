// The DIMENSIONED grid's trunk: declare a field, write two cells by `[x, y]`,
// count the lit ones with a guarded sweep. Two cells set => 2.
//
// This test used to live in 660_COLLECTIONS beside list/set/map and read
// `new(rows: 3, cols: 3) | grid g |> set(g, x, y, v) |> count-nonzero(g) |>
// free(g)`. Every part of that spelling is gone, and the reason it moved
// clusters is that the grid is no longer the same KIND of thing: a collection
// is a first-class heap value you hold, thread and discharge, and a grid is a
// static table addressed by position. There is no handle to thread, so there is
// no `| grid` arm; nothing was allocated, so there is no `free` and no `| err`;
// and `count-nonzero` is not a verb the grid owes anyone — it is a sweep with a
// guard, which is the same three lines that count lit lights or surviving
// primes.
//
// 697_003 pins the flat form of this; the 2-D address and its row-major
// linearisation are what is pinned here.
import std/io
import std/store
import std/grid

std/grid:new(cells, dimensions: 3x3) { v: 0[i64] }
std/store:new(acc) { n: 0[i64] }

std/grid:stored { cells[0, 0].v: 1 }
std/grid:stored { cells[2, 1].v: 1 }

std/grid:sweep(cells)
! sweep c when c.v > 0 |> std/store:stored { acc.n: acc.n + 1 }

std/io:print.ln("{{ acc.n:d }}")
