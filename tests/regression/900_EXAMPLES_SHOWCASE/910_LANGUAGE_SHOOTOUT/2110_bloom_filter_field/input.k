// Bloom filter on std/field — proving the bitset is a GENERAL primitive, not a
// sieve tool. Add 10,000 items, each multiplicatively double-hashed to k=4 bit
// positions via std/field:set (a HASH-SCATTERED access pattern — the opposite of
// the sieve's regular strides). Then test every added position: each must read
// back set, so the hit-sum is exactly 10,000*4 = 40,000 (no false negatives).
// Exercises field:new/set/test/free + capture-accumulate flow on a non-sieve
// workload — the reuse case the blog claims. Expected: 40000.
import std/io
import std/field

std/field:new(bits: 100000)
| field f |> for(0..10000)
    ! each x |> for(0..4)
        ! each i |> std/field:set(f, i: ((x * 2654435761) % 100000 + i * (((x * 40503) % 100000) + 1)) % 100000)
    | done |> capture { hits: 0[i64] }
        ! as a |> for(0..10000)
            ! each x |> for(0..4)
                ! each i |> std/field:test(f, i: ((x * 2654435761) % 100000 + i * (((x * 40503) % 100000) + 1)) % 100000): t |> captured { hits: a.hits + t }
        | captured r |> std/io:print.ln("{{ r.hits:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")
