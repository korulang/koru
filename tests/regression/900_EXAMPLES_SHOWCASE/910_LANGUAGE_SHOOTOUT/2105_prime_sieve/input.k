// Sieve of Eratosthenes — count the primes <= 1,000,000 (the classic 78,498).
// Dave Plummer's PrimeSieve "drag race" workload, in pure Koru. A std/grid used
// as a flat 1-row buffer is the runtime-sized, dense, in-place-mutable sieve
// buffer (same representation hand-written C/Zig/Rust use). The marking LOGIC —
// for each prime p, strike its multiples from p*p — is visible Koru flow; only
// the per-cell write and the count reduction are the Zig leaf. Survivors (cells
// still 0) in 2..1,000,000 are the primes.
import std/io
import std/grid

std/grid:new(rows: 1, cols: 1000001)
| grid g |> for(2..1001)
    ! each p |> std/grid:get(g, x: p, y: 0): pv |> if(pv == 0)
        | then |> for(0..(1000000 - p * p) / p + 1)
            ! each k |> std/grid:set(g, x: p * p + k * p, y: 0, v: 1)
    | done |> std/grid:count-zeros(g, lo: 2, hi: 1000001): c |> std/io:print.ln("{{ c:d }}") |> std/grid:free(g)
| err e |> std/io:print.ln("ERR {{ e:s }}")
