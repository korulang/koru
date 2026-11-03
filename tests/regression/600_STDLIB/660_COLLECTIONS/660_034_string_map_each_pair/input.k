// std/string-map:each — iterate every key→value pair through the `! pair`
// effect arm (the corpus streaming idiom: read-lines' `! line`, split's
// `! piece`, control:for's `! each`). Pins the 820_004 word-frequency gap:
// "print every distinct word" was unspellable — the report could only
// re-query a fixed vocabulary. Hash order is unstable, so the pin
// aggregates: pair count and key-byte sum folded into a capture cell,
// pair count delivered again by `| done` — order-free sums.
import std/io
import std/string-map

std/string-map:new()
| map m |> std/string-map:set(m, k: "the", v: 9)
    |> std/string-map:set(m, k: "of", v: 6)
    |> std/string-map:set(m, k: "a", v: 4)
    |> std/string-map:set(m, k: "and", v: 3)
    |> capture { words: 0[i64], keybytes: 0[i64], pairs: 0[i64] }
        ! as acc |> std/string-map:each(m)
            ! pair { k, v } |> captured { words: acc.words + v, keybytes: acc.keybytes + @as(i64, @intCast(k.len)) }
            | done n |> captured { pairs: @as(i64, @intCast(n)) }
        | captured t |> std/io:print.ln("pairs: {{ t.pairs:d }} words: {{ t.words:d }} keybytes: {{ t.keybytes:d }}")
            |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
