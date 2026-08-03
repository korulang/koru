// PINS the grid's bounds floor, PER AXIS.
//
// An index outside the grid traps, naming the grid and — for a dimensioned grid
// — WHICH AXIS escaped. `[x, y]` with a good x and a bad y is the common slip,
// and "index out of range" alone would not locate it.
//
// Ruled 2026-08-03: trapping mirrors the store's stale-handle floor. Fail loud,
// never silently address a neighbouring cell. WRAPPING IS THE PROGRAM'S
// DECISION and belongs in the source as an explicit `% size` where a reader can
// see it — a spatial hash wants exactly that and should say so rather than have
// the container guess on its behalf.
//
// The check is a floor, not a permanent tax: an index the compiler can prove in
// range needs none, and a sweep arm over a grid is exactly that case, since the
// loop builds the index from `0..size`. Same floor-then-prove-away arc the
// handle check follows.
import std/io
import std/grid

std/grid:new(lights, dimensions: 4x5) { on: 0[i64] }

std/io:print.ln("before")
std/grid:stored { lights[1, 9].on: 1 }
std/io:print.ln("unreachable")
