// std/map:each — the same effect-stream iteration surface as
// std/string-map:each (same ruling): `! pair {k, v}` fires once per entry,
// `| done` delivers the pair count. Hash order is unstable, so the pin
// aggregates key and value sums — order-free.
import std/io
import std/map

std/map:new()
| map m |> std/map:set(m, k: 10, v: 100)
    |> std/map:set(m, k: 20, v: 200)
    |> std/map:set(m, k: 30, v: 300)
    |> capture { keys: 0[i64], vals: 0[i64], pairs: 0[i64] }
        ! as acc |> std/map:each(m)
            ! pair { k, v } |> captured { keys: acc.keys + k, vals: acc.vals + v }
            | done n |> captured { pairs: @as(i64, @intCast(n)) }
        | captured t |> std/io:print.ln("pairs: {{ t.pairs:d }} keys: {{ t.keys:d }} vals: {{ t.vals:d }}")
            |> std/map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
