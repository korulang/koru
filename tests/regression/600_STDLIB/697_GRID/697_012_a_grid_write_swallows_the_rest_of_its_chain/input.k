// RED ON PURPOSE, and SILENT — this program compiles, runs, exits 0, and skips
// a line of code without saying anything.
//
// A `std/grid:stored` DISCARDS THE ENTIRE REST OF ITS CHAIN. The write itself
// lands; everything piped after it disappears. Here the write sets `x` to 1 and
// the `|> print.ln` that follows never runs, so the output is one line instead
// of two.
//
// The chain does not have to contain another write — any step after the write
// is dropped. That is the general statement, and it is worse than the shape
// this test was first written for (two chained writes, where the second is
// lost); that is just the instance where the lost step happened to be a write.
//
// Written as separate STATEMENTS, the identical program is correct. 697_001 has
// relied on that form since the grid landed, which is why this survived: every
// existing grid test writes in statements, never in a chain.
//
// TWO SHAPES, ONLY ONE OF THEM VISIBLE:
//
//   top level (this test)   compiles, drops the rest of the chain, silent
//   inside a `for` arm      backend error, `duplicate struct member name
//                           '__grid_write_L<n>_event'`
//
// The loop error is the same bug caught by accident. A grid write mints a
// per-site event named for the FLOW's line, which every link of a chain shares,
// so two links in a loop arm mint one name and the Zig backend refuses the
// program. That is an internal leak with no Koru-level diagnostic, and it is
// the only thing making any of this loud.
//
// DO NOT "FIX" THE NAME COLLISION FIRST. Keying the unit uniquely (a text hash,
// a counter) was tried and MEASURED: the loop case then compiles and silently
// drops too, so the one loud shape goes quiet. The drop is the bug; the
// collision is a symptom that happens to be useful. The comment at that site in
// `grid.kz` says so.
//
// WHY THE STORE DOES NOT HAVE THIS: `std/store:stored` mints ONE unit per store
// and passes the field as an argument, so chained store writes are ordinary
// repeated calls to a shared event — koru-libs' `bounce.k` chains two per
// entity and has always worked. A grid's unit carries the assignment itself and
// is installed by replacing the flow, which evidently only survives once.
//
// COST, measured: koru-libs' boids renderer draws a black window. Its frame arm
// is `std/grid:stored {..} |> draw.rect(..)`, the draw is the swallowed step,
// and nothing anywhere reports it. Reordering to draw BEFORE the write is the
// workaround, and needing to know that is the bug.
//
// Flip to green when a step piped after a grid write runs.
import std/io
import std/grid

std/grid:new(g, size: 4) { x: 0[i64] }

std/grid:stored { g[1].x: 1 }
    |> std/io:print.ln("the chain continues")

std/io:print.ln("x {{ g[1].x:d }}")
