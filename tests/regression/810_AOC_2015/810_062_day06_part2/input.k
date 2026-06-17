// AoC 2015 Day 6 Part 2 — brightness. Statement examples sequenced:
// BRIGHTNESS: on 0,0 (+1) then toggle-all (+2 each) → 2000001. NOW PURE .k
// end-to-end on std/grid: same regex dispatch + grid-handle + nested-for
// rectangle as part 1, but the per-cell op is brightness arithmetic — on adds
// 1, off subtracts 1 clamped at 0, toggle adds 2 — and the answer is grid:sum
// (total brightness) rather than count-nonzero. 2D-ness stays out of the grid.
import std/io
import std/fs
import std/regex
import std/grid

std/grid:new(rows: 1000, cols: 1000)
| grid g |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_062_day06_part2/input.txt")
    ! line l |> std/regex:match(l)
        | `turn on (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
            ! each y |> for(x1..x2 + 1)
                ! each x |> std/grid:get(g, x, y)
                    | val v |> std/grid:set(g, x, y, v + 1)
                | done |> _
            | done |> _
        | `turn off (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
            ! each y |> for(x1..x2 + 1)
                ! each x |> std/grid:get(g, x, y)
                    | val v |> if(v == 0)
                        | then |> std/grid:set(g, x, y, 0)
                        | else |> std/grid:set(g, x, y, v - 1)
                | done |> _
            | done |> _
        | `toggle (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
            ! each y |> for(x1..x2 + 1)
                ! each x |> std/grid:get(g, x, y)
                    | val v |> std/grid:set(g, x, y, v + 2)
                | done |> _
            | done |> _
        | no-match |> std/io:print.ln("BAD: {{ l:s }}")
    | done _ |> std/grid:sum(g)
        | total t |> std/io:print.ln("{{ t:d }}") |> std/grid:free(g)
    | failed e |> std/io:print.ln("FAILED {{ e:s }}") |> std/grid:free(g)
| err e |> std/io:print.ln("ERR {{ e:s }}")
