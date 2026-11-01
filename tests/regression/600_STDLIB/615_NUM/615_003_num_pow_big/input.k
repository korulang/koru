// std/num: 2^70 — exact arbitrary precision, no float rounding.
import std/io
import std/num

std/num:lit { 2 }
| exact a |> std/num:pow(a, n: 70)
    | exact p |> std/io:print.ln("{{ p:s }}") |> std/num:free(n: p)
    | neg-exp |> std/io:print.ln("negexp")
| bad y |> std/io:print.ln("bad")
