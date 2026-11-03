// std/map:del — evict an i64 key and take its payload back. del(9) on an
// absent key answers | missing; del(7) answers | value 100 and the key is
// really gone (count drops, get misses, contains says no). Re-setting 7
// afterwards lands cleanly in the slot Zig's table tombstoned, and a second
// del still answers | missing. i64 keys carry no ownership — nothing is
// freed on eviction (string-map's sibling frees the duped key bytes).
import std/io
import std/map

std/map:new()
| map m |> std/map:set(m, k: 7, v: 100) |> std/map:set(m, k: 8, v: 200) |> std/map:del(m, k: 9)
    | value _ |> std/io:print.ln("PHANTOM") |> std/map:free(m)
    | missing |> std/io:print.ln("absent") |> std/map:del(m, k: 7)
        | value v |> std/io:print.ln("del={{ v:d }}") |> std/map:count(m): n |> std/io:print.ln("keys={{ n:d }}") |> std/map:contains(m, k: 7)
            | yes |> std/io:print.ln("STILL THERE") |> std/map:free(m)
            | no |> std/io:print.ln("gone") |> std/map:set(m, k: 7, v: 300) |> std/map:get(m, k: 7)
                | value r |> std/io:print.ln("reset={{ r:d }}") |> std/map:free(m)
                | missing |> std/io:print.ln("RESET LOST") |> std/map:free(m)
        | missing |> std/io:print.ln("DEL MISS") |> std/map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
