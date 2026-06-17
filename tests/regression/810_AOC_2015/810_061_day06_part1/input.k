// AoC 2015 Day 6 Part 1 — a million lights. Statement examples sequenced:
// on-all (1000000) → toggle row 0 (999000) → off 2x2 (998996). NOW PURE .k
// end-to-end on std/grid: three full-match regex patterns classify the
// instruction and deliver the rectangle typed (named groups), the grid is a
// dense managed buffer threaded as a handle through the read-lines loop, and
// each instruction's rectangle is iterated in KORU (nested for) — on/off set a
// constant, toggle reads then flips. 2D-ness is NOT first-class: the grid is a
// flat shaped buffer (set/get/count), the rectangle logic lives here.
import std/io
import std/fs
import std/regex
import std/grid

std/grid:new(rows: 1000, cols: 1000)
| grid g |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_061_day06_part1/input.txt")
    ! line l |> std/regex:match(l)
        | `turn on (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
            ! each y |> for(x1..x2 + 1)
                ! each x |> std/grid:set(g, x, y, 1)
                | done |> _
            | done |> _
        | `turn off (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
            ! each y |> for(x1..x2 + 1)
                ! each x |> std/grid:set(g, x, y, 0)
                | done |> _
            | done |> _
        | `toggle (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
            ! each y |> for(x1..x2 + 1)
                ! each x |> std/grid:get(g, x, y)
                    | val v |> if(v == 0)
                        | then |> std/grid:set(g, x, y, 1)
                        | else |> std/grid:set(g, x, y, 0)
                | done |> _
            | done |> _
        | no-match |> std/io:print.ln("BAD: {{ l:s }}")
    | done _ |> std/grid:count-nonzero(g)
        | count n |> std/io:print.ln("{{ n:d }}") |> std/grid:free(g)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/grid:free(g)
| err e |> std/io:print.ln("ERR {{ e:s }}")
