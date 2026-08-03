// Sieve of Eratosthenes — count the primes <= 1,000,000 (the classic 78,498).
// Dave Plummer's PrimeSieve "drag race" workload, in pure Koru.
//
// The sieve buffer is a STATIC 1,000,001-cell grid. That is the same
// representation hand-written C/Zig/Rust use — one dense flat array, zeroed,
// mutated in place — except that here it is not allocated at all: it is a
// zero-initialised table in the program's own image, so there is no handle to
// thread through the marking loops, no allocation to fail, and no free.
//
// THE PRIMALITY GUARD IS THE POINT. `if(sieve[p].composite == 0)` is what makes
// this the sieve rather than a slow trial-marking of every multiple of every
// number — and it is a READ IN A GUARD, which is precisely what a grid could
// not do until its declaration took ownership of a whole-program read pass.
// Marking every p's multiples unconditionally would still print 78498 and would
// still be "correct"; it would be roughly 3.5x the writes and it would not be
// the algorithm this benchmark is named after. Correctness was never the thing
// at risk — honesty about which program is being timed was.
//
// 0 AND 1 ARE STRUCK UP FRONT. The old spelling asked `count-zeros(lo: 2, hi:
// N)` and the range carried the fact that neither is prime; a sweep visits
// every cell, so the fact has to live in the data instead of in the reduction's
// arguments. That is better placed: it is a statement about 0 and 1, not about
// how they are counted.
import std/io
import std/store
import std/grid

std/grid:new(sieve, size: 1000001) { composite: 0[i64] }
std/store:new(acc) { n: 0[i64] }

std/grid:stored { sieve[0].composite: 1 }
std/grid:stored { sieve[1].composite: 1 }

for(2..1001)
! each p |> if(sieve[p].composite == 0)
    | then |> for(0..(1000000 - p * p) / p + 1)
        ! each k |> std/grid:stored { sieve[p * p + k * p].composite: 1 }
        | done |> _

std/grid:sweep(sieve)
! sweep c when c.composite == 0 |> std/store:stored { acc.n: acc.n + 1 }

std/io:print.ln("{{ acc.n:d }}")
