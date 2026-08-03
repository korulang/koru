// AoC 2015 Day 6 Part 1 — a million lights. Statement examples sequenced:
// on-all (1000000) → toggle row 0 (999000) → off 2x2 (998996).
//
// The lights are a STATIC 1000x1000 grid: declared once, addressed `[x, y]`,
// never allocated and never freed. That deletes three things the heap-grid
// version needed and none of which was ever about day 6 — the `| grid g` arm
// that minted a handle, the `| err e` arm for an allocation that can no longer
// fail, and the `free(g)` on both exits. What is left is the instruction
// dispatch and the rectangle, which is all this puzzle ever was.
//
// TOGGLE IS ARITHMETIC, not a branch: `1 - on` flips 0 and 1 in one write, and
// it is a write whose value READS THE CELL IT WRITES. That read is the reason
// this test could not be migrated the day the static grid landed — a cell read
// only lowered inside a write block, so `if(lights[x, y].on == 0)` reached the
// host as an undeclared identifier. The declaration now owns a whole-program
// read pass (the same one `std/store:new` runs for singleton cell paths), so a
// read is a read wherever it is written.
//
// The count is a guarded sweep into a store singleton, not a `count-nonzero`
// verb. Same three lines as 697_003 and 697_004 — a reduction over a grid is
// one shape, and the grid does not owe the program a reduction per question.
import std/io
import std/fs
import std/regex
import std/store
import std/grid

std/grid:new(lights, dimensions: 1000x1000) { on: 0[i64] }
std/store:new(acc) { n: 0[i64] }

std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_061_day06_part1/input.txt")
! line l |> std/regex:match(l)
    | `turn on (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
        ! each y |> for(x1..x2 + 1)
            ! each x |> std/grid:stored { lights[x, y].on: 1 }
            | done |> _
        | done |> _
    | `turn off (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
        ! each y |> for(x1..x2 + 1)
            ! each x |> std/grid:stored { lights[x, y].on: 0 }
            | done |> _
        | done |> _
    | `toggle (?<x1>[0-9]+),(?<y1>[0-9]+) through (?<x2>[0-9]+),(?<y2>[0-9]+)` { x1: usize, y1: usize, x2: usize, y2: usize } |> for(y1..y2 + 1)
        ! each y |> for(x1..x2 + 1)
            ! each x |> std/grid:stored { lights[x, y].on: 1 - lights[x, y].on }
            | done |> _
        | done |> _
    | no-match |> std/io:print.ln("BAD: {{ l:s }}")
| done _ |> _
| failed e |> std/io:print.ln("FAILED {{ e:s }}")

std/grid:sweep(lights)
! sweep c when c.on > 0 |> std/store:stored { acc.n: acc.n + 1 }

std/io:print.ln("{{ acc.n:d }}")
