// AoC 2015 Day 6 Part 2 — brightness. Statement examples sequenced:
// on 0,0 (+1) then toggle-all (+2 each) → 2000001.
//
// Same static 1000x1000 grid and same rectangle logic as part 1; the per-cell
// operation is arithmetic on the cell's own current value — on adds 1, toggle
// adds 2, off subtracts 1 CLAMPED AT ZERO — and the answer is total brightness
// rather than a count.
//
// THE CLAMP IS WHY THIS TEST WAITED. `off` is the one instruction that cannot
// be written as a single arithmetic write: it has to ask what the cell holds
// before deciding, and a guard is not a write block. Until the grid's
// declaration owned a whole-program read pass there was no way to ask, and
// `if(lights[x, y].on == 0)` compiled to a Zig undeclared identifier. That is
// the ordinary way anyone uses a table, so the gap was load-bearing rather
// than exotic — this puzzle is the smallest program that proves it closed.
//
// The reduction is a sweep with NO guard: every cell contributes its
// brightness, so filtering would only be an optimisation, and stating it as a
// filter would misdescribe the sum.
import std/io
import std/fs
import std/regex
import std/store
import std/grid

std/grid:new(lights, dimensions: 1000x1000) { on: 0[i64] }
std/store:new(acc) { total: 0[i64] }

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_062_day06_part2/input.txt")
! line l |> std/regex:match(l)
    | `turn on (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
        ! each y |> for(x1..x2 + 1)
            ! each x |> std/grid:stored { lights[x, y].on: lights[x, y].on + 1 }
            | done |> _
        | done |> _
    | `turn off (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
        ! each y |> for(x1..x2 + 1)
            ! each x |> if(lights[x, y].on == 0)
                | then |> _
                | else |> std/grid:stored { lights[x, y].on: lights[x, y].on - 1 }
            | done |> _
        | done |> _
    | `toggle (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
        ! each y |> for(x1..x2 + 1)
            ! each x |> std/grid:stored { lights[x, y].on: lights[x, y].on + 2 }
            | done |> _
        | done |> _
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")

std/grid:sweep(lights)
! sweep c |> std/store:stored { acc.total: acc.total + c.on }

std/io:print.ln("{{ acc.total:d }}")
