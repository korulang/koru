// std/num: Avogadro * milli — 6.022e23 * 1e-3 == 6.022e20.
import std/io
import std/num

std/num:lit(s: "6.022e23")
| exact e |> std/num:lit(s: "1e-3")
    | exact f |> std/num:mul(a: e, b: f): m |> std/io:print.ln("{{ m:s }}") |> std/num:free(n: m)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
