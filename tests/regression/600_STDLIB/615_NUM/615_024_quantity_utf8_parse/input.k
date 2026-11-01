// std/quantity: UTF-8 surface forms — ± separator, · product,
// superscript exponents, named constant pi.
import std/io
import std/quantity

std/quantity:lit(5.0*m/s, unc: 0.2)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad")

std/quantity:lit(π*m)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad")
