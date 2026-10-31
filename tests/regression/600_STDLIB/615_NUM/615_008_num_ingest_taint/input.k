// std/num: outside text enters as <external!>; parse discharges it
// into <exact!>. The taint is the boundary.
import std/io
import std/num

std/num:ingest(s: "-7.5e-3"): t |> std/num:parse(s: t)
    | exact n |> std/io:print.ln("{{ n:s }}") |> std/num:free(n)
    | bad x |> std/io:print.ln("bad") |> std/io:free(content: x)
