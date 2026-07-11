// Sieve of Eratosthenes where the MARKING IS COMPILER-GENERATED. std/field:mark-multiples
// is a [transform]: composite multiples of a prime p occupy exactly the residue class
// (p-1)/2 mod p, so for each dense stride the compiler EMITS a fully-unrolled marker with
// the per-word masks baked as immediate literals (the same residue-class trick the Zig
// champion hand-writes with comptime). The Koru program just says "mark the multiples";
// Koru's compiler generates the specialized SIMD marker per stride and dispatches at
// runtime. Same machinery as regex->DFA and kernel->SIMD. This pin proves the generated
// marker is CORRECT: 78,498 primes <= 1,000,000. (Speed lives in the drag-race
// submission, measured under the official protocol — not asserted here.)
import std/io
import std/field

std/field:new(bits: 500000)
| field f |> for(1..500)
    ! each i |> std/field:test(f, i): pv |> if(pv == 0)
        | then |> std/field:mark-multiples(f, from: 2 * i * (i + 1), stride: 2 * i + 1, limit: 499999)
    | done |> std/field:count-zeros(f, lo: 1, hi: 500000): c |> std/io:print.ln("{{ c + 1:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")
