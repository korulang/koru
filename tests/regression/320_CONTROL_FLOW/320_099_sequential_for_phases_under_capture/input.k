// PIN (failing): two sequential for-loops chained by `| done |>` under a single
// capture `! as` mis-group — BOTH loops' `done` branches get attributed to the
// capture flow root, tripping KORU051 ("branch 'done' has 2 continuations").
// Surfaced by AoC day18 (Conway), whose phases (parse / step-compute / step-copy
// / count) are sequential loops over a shared capture-array.
//
// The green multi-phase days (14/17/24) all chain phases via capture-fold
// `| captured` terminals, never via bare `for … | done |> for …` under a
// capture — so this is either a parser done-grouping bug or an unsupported
// idiom. Either way it blocks the natural shared-mutable-array-across-phases
// shape. Expected output: 20 (two passes summing 1+2+3+4).
import std/io

capture { sum: 0[i64], g: [4]i64{ 1, 2, 3, 4 } }
! as acc |> for(0..4)
    ! each i |> captured { sum: acc.sum + acc.g[i] }
  | done |> for(0..4)
    ! each j |> captured { sum: acc.sum + acc.g[j] }
  | done |> _
| captured result |> std/io:print.ln("{{ result.sum:d }}")
