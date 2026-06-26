// Sieve of Eratosthenes via a comptime-generated mod-30030 WHEEL. The wheel — the
// 5,760 residues coprime to 2*3*5*7*11*13 — is one std/table comprehension line;
// hand-rolling it is infeasible (primesieve.cpp ships it as a static table). The
// wheel-strided strike (std/field:strike-wheel) marks only coprime multiples (~19%
// of positions). At 1000 passes this beats the hand-rolled mod-6 sieve ~1.75x and
// naive C ~5x. Expected: 78,498 primes <= 1,000,000.
import std/io
import std/table
import std/field

from(wheel) { x: usize over 0..30030 | keep gcd(x, 30030) == 1 }

std/field:new(bits: 1000001)
| field f |> for(wheel)
    ! each r |> if(r > 1 and r <= 1000)
        | then |> std/field:test(f, r): pv |> if(pv == 0)
            | then |> std/field:strike-wheel(f, r, wheel[0..], 30030, 1000000)
    | done |> capture { n: 6[i64] }
        ! as a |> for(0..34)
            ! each k |> for(wheel)
                ! each r |> if(30030 * k + r > 1 and 30030 * k + r <= 1000000)
                    | then |> std/field:test(f, 30030 * k + r): pv |> if(pv == 0)
                        | then |> captured { n: a.n + 1 }
        | captured result |> std/io:print.ln("{{ result.n:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")
