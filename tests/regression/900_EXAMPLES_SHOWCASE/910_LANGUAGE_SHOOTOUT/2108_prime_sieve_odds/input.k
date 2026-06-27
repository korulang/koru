// Sieve of Eratosthenes, odds-only + stepMask word-wise marking — the fast path.
// bit b is the odd number 2b+1, so prime p has a uniform bit-stride of p, which
// std/field:strike marks word-wise (one OR per 64-bit word, NEON-lowered, doubled
// cycle to drop the scalar tail) + an 8-way byte scatter for large strides, in pure
// Koru. Expected: 78,498 primes <= 1,000,000. (Contrast 2107: the elegant mod-30030 wheel,
// which does less work but scatters — a vectorization dead-end. See the blog.)
import std/io
import std/field

std/field:new(bits: 500000)
| field f |> for(1..500)
    ! each i |> std/field:test(f, i): pv |> if(pv == 0)
        | then |> std/field:strike(f, 2 * i * (i + 1), 2 * i + 1, 499999)
    | done |> std/field:count-zeros(f, 1, 500000): c |> std/io:print.ln("{{ c + 1:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")
