// AoC 2015 Day 1 Part 1 — "Not Quite Lisp" (statement example: "(()(()(" → 3).
// PURE KORU (.k): no host facet at all. const { } declares the input,
// capture { } declares the cell, for iterates, if branches, captured { }
// computes next values. Host code is zero lines; expression values only.

import std/io
import std/control

const { input: "(()(()(" }

capture { floor: 0[i32] }
! as acc |> for(input)
    ! each c |> if(c == '(')
        | then |> captured { floor: acc.floor + 1 }
        | else |> captured { floor: acc.floor - 1 }
| captured result |> std/io:print.ln("{{ result.floor:d }}")
