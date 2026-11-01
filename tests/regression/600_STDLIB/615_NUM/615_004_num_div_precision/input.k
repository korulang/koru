// std/num: 1/3 at 30 significant digits.
import std/io
import std/num

std/num:lit { 1 }
| exact c |> std/num:lit { 3 }
    | exact d |> std/num:div(a: c, b: d, prec: 30)
        | exact q |> std/io:print.ln("{{ q:s }}") |> std/num:free(n: q)
        | div-zero |> std/io:print.ln("divzero")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
