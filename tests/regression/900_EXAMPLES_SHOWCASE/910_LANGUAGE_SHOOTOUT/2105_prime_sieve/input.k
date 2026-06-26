// Sieve of Eratosthenes — count the primes <= 1,000,000 (the classic answer:
// 78,498). Dave Plummer's PrimeSieve "drag race" workload, brought home to
// pure Koru. The sieve buffer is a std/grid used as a flat 1-row shaped buffer
// (index i -> cell (i, 0)) — a runtime-sized, dense, in-place-mutable heap
// buffer, the same representation hand-written C/Zig/Rust use.
//
// CORRECTNESS PASS (no prime-skip guard yet): for every p in 2..1000 we strike
// out p's multiples starting at p*p with a strided write. Striking from a
// composite p only re-marks already-struck cells, so the final composite set is
// exactly right; the guard is a faithfulness/speed refinement for the next pass.
// Survivors (cells still 0) in 2..1,000,000 are the primes — counted by a fold.
import std/io
import std/grid

std/grid:new(rows: 1, cols: 1000001)
| grid g |> for(2..1001)
    ! each p |> for(0..(1000000 - p * p) / p + 1)
        ! each k |> std/grid:set(g, p * p + k * p, 0, 1)
        | done |> _
    | done |> capture { cnt: 0[i64] }
        ! as a |> for(2..1000001)
            ! each i |> std/grid:get(g, i, 0): v |> captured { cnt: a.cnt + @intFromBool(v == 0) }
        | captured r |> std/io:print.ln("{{ r.cnt:d }}") |> std/grid:free(g)
| err e |> std/io:print.ln("ERR {{ e:s }}")
