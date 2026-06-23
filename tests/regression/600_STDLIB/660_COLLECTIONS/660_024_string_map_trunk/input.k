// std/string-map trunk: new → set → overwrite same key → set another → get →
// count → free. String (byte-slice) keys, i64 values; keys are duped-and-owned
// (freed on teardown — no leak). set("foo",10) then set("foo",99) overwrites
// (still 1 key); set("bar",20) => 2 keys. get("foo")=99.
import std/io
import std/string-map

std/string-map:new()
| map m |> std/string-map:set(m, k: "foo", v: 10) |> std/string-map:set(m, k: "bar", v: 20) |> std/string-map:set(m, k: "foo", v: 99) |> std/string-map:get(m, k: "foo")
    | value v |> std/io:print.ln("foo={{ v:d }}") |> std/string-map:count(m): n |> std/io:print.ln("keys={{ n:d }}") |> std/string-map:free(m)
    | missing |> std/io:print.ln("MISSING") |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
