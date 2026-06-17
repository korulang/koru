// std/grid trunk: new(rows,cols) → set cells → count-nonzero → free.
// Pins the dense-grid collection primitive (the day06 lights backing) before
// AoC consumes it. Two cells set => count 2. <grid!> discharged by free.
import std/io
import std/grid

std/grid:new(rows: 3, cols: 3)
| grid g |> std/grid:set(g, x: 0, y: 0, v: 1) |> std/grid:set(g, x: 2, y: 1, v: 1) |> std/grid:count-nonzero(g)
    | count n |> std/io:print.ln("{{ n:d }}") |> std/grid:free(g)
| err e |> std/io:print.ln("ERR {{ e:s }}")
