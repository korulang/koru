// std/quantity: unit scale normalization — 1000 g ≡ 1 kg, the
// equivalence law across unit prefixes.
import std/io
import std/quantity

std/quantity:lit { 1000 g }
| exact g |> std/quantity:lit { 1 kg }
    | exact k |> std/quantity:equiv(a: g, b: k)
        | same |> std/io:print.ln("1000 g == 1 kg")
        | diff |> std/io:print.ln("not equal")
        |> std/quantity:free(n: g) |> std/quantity:free(n: k)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
