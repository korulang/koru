// std/string-map:del — evict a key and take its payload back. del("nope") on
// an absent key answers | missing; del("foo") answers | value 10 and the key
// is really gone (count drops, get misses, contains says no) — not parked at
// a sentinel. Re-setting "foo" afterwards lands cleanly in the slot Zig's
// table tombstoned, and a second del still answers | missing.
import std/io
import std/string-map

std/string-map:new()
| map m |> std/string-map:set(m, k: "foo", v: 10) |> std/string-map:set(m, k: "bar", v: 20) |> std/string-map:del(m, k: "nope")
    | value _ |> std/io:print.ln("PHANTOM") |> std/string-map:free(m)
    | missing |> std/io:print.ln("absent") |> std/string-map:del(m, k: "foo")
        | value v |> std/io:print.ln("del={{ v:d }}") |> std/string-map:count(m): n |> std/io:print.ln("keys={{ n:d }}") |> std/string-map:contains(m, k: "foo")
            | yes |> std/io:print.ln("STILL THERE") |> std/string-map:free(m)
            | no |> std/io:print.ln("gone") |> std/string-map:set(m, k: "foo", v: 30) |> std/string-map:get(m, k: "foo")
                | value r |> std/io:print.ln("reset={{ r:d }}") |> std/string-map:free(m)
                | missing |> std/io:print.ln("RESET LOST") |> std/string-map:free(m)
        | missing |> std/io:print.ln("DEL MISS") |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
