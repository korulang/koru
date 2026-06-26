// Sieve of Eratosthenes on the bit-packed std/field primitive (1 bit per flag)
// instead of std/grid's i64 cells. Same Koru marking logic; the buffer is 64x
// smaller. Rung 1 of the std/field (codename std/castles) vision — see
// docs/std_field_castles_vision.md. Expected: 78,498 primes <= 1,000,000.
import std/io
import std/field

std/field:new(bits: 1000001)
| field f |> for(2..1001)
    ! each p |> std/field:test(f, p): pv |> if(pv == 0)
        | then |> for(0..(1000000 - p * p) / p + 1)
            ! each k |> std/field:set(f, p * p + k * p)
    | done |> std/field:count-zeros(f, 2, 1000001): c |> std/io:print.ln("{{ c:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")
