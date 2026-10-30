// std/quantity: 10 m / 4 s = 2.5 m/s — dims subtract.
import std/io
import std/quantity

std/quantity:lit(s: "10 m")
| exact a |> std/quantity:lit(s: "4 s")
    | exact b |> std/quantity:div(a, b, prec: 20)
        | exact r |> std/quantity:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | div-zero |> std/io:print.ln("divzero")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
