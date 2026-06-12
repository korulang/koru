// AoC 2015 Day 1 Part 1 — "Not Quite Lisp" ("(()(()(" → 3). PURE .k,
// EMPTY LEDGER, and CANONICAL REAL-SOLVER SHAPE: the input comes off disk.
// The deepest composition in the corpus: capture cell → INLINED read-lines
// (effect lowering: one flat frame) → for template → if template →
// captured writes. Swap input.txt for a personal puzzle input and this
// file is a real solver, unchanged.

import std/io
import std/fs

capture { floor: 0[i32] }
! as acc |> std/fs:read-lines(path: "tests/regression/810_AOC_2015/810_011_day01_part1/input.txt")
    ! line l |> for(l)
        ! each c |> if(c == '(')
            | then |> captured { floor: acc.floor + 1 }
            | else |> captured { floor: acc.floor - 1 }
    | done _ |> _
    | failed e |> std/io:print.ln("FAILED {{ e:s }}")
| captured result |> std/io:print.ln("{{ result.floor:d }}")
