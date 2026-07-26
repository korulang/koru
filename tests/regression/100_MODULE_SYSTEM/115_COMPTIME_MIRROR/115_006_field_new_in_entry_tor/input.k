// CONTROL for 115_004: the same `std/field:new` body wrapped in a `pub tor`, but
// left in the ENTRY file. 115_004 changes two things at once relative to
// 2106_prime_sieve_bitfield — the body moves into a module AND it becomes a
// tor body instead of a top-level flow. This arm holds the module constant so
// the two causes separate: a failure here indicts tor-wrapping, a pass here
// leaves the module boundary as the only remaining difference.
import std/io
import std/field

pub tor run {}
run = std/field:new(bits: 1000001)
| field f |> for(2..1001)
    ! each p |> std/field:test(f, i: p): pv |> if(pv == 0)
        | then |> for(0..(1000000 - p * p) / p + 1)
            ! each k |> std/field:set(f, i: p * p + k * p)
    | done |> std/field:count-zeros(f, lo: 2, hi: 1000001): c |> std/io:print.ln("{{ c:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")

run()
