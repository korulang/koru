// PIN (2026-07-04, positive): bare-return produce from NESTED if arms — a
// three-way branch inside a single-return event, spelled as `| else |> if(...)`
// (the passing 810_121 nesting) with `->` produces and recursive binds in the
// NESTED then/else arms:
//     collatz = if(n == 1)
//     | then -> 0
//     | else |> if(@rem(n, 2) == 0)
//         | then |> collatz(...): v -> 1 + v
//         | else |> collatz(...): v -> 1 + v
// The corpus had nested ifs ending in captured{}/_ only — never producing a
// value through the outer event's bare return. Surfaced green by the
// koru-benchmarks collatz kernel (sum over [1,100001) = 10753840 through
// koruc); pinned here minimal as collatz(6) = 8 (6→3→10→5→16→8→4→2→1).
import std/io

pub tor collatz { n: i64 } -> i64

collatz = if(n == 1)
| then -> 0
| else |> if(@rem(n, 2) == 0)
    | then |> collatz(n: @divTrunc(n, 2)): v -> 1 + v
    | else |> collatz(n: 3 * n + 1): v -> 1 + v

collatz(n: 6): r |> std/io:print.ln("{{ r:d }}")
