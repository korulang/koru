// std/num: sqrt(2) at 40 significant digits.
import std/io
import std/num

std/num:lit(s: "2")
| exact s |> std/num:sqrt(a: s, prec: 40)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | negative |> std/io:print.ln("neg")
| bad y |> std/io:print.ln("bad")
