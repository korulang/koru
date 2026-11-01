// std/num + std/quantity: parse |bad carries the offending buffer under
// <allocated!> — the receiver owns it and disposes via io:free. Leak check
// pins the ownership transfer (earlier the buffer was returned unmarked and
// the free never ran).
import std/io
import std/num
import std/quantity

std/num:ingest(s: "not-a-number"): t |> std/num:parse(s: t)
    | exact n |> std/io:print.ln("parsed") |> std/num:free(n)
    | bad x |> std/io:print.ln("bad num: {{ x:s }}")

std/quantity:ingest(s: "5 furlongs per fortnight!!"): q |> std/quantity:parse(s: q)
    | exact v |> std/io:print.ln("parsed") |> std/quantity:free(n: v)
    | bad m |> std/io:print.ln("bad qty: {{ m:s }}")
