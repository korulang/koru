// std/quantity: pure-Koru neg/sub impls — 5 m - 2 m = 3 m, and
// -(5+-0.5 m/s) = -5+-0.5 m/s (sigma preserved, dims preserved).
import std/io
import std/quantity

std/quantity:lit { 5 m }
| exact a |> std/quantity:lit { 2 m }
    | exact b |> std/quantity:sub(a, b)
        | exact r |> std/quantity:render(n: r): t |> std/io:print.ln("{{ t:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

std/quantity:lit { 5+-0.5 m/s }
| exact v |> std/quantity:neg(n: v): nv |> std/quantity:render(n: nv): t2 |> std/io:print.ln("{{ t2:s }}")
| bad z |> std/io:print.ln("bad")

// 5 m - 2 s refuses dims, same lawful branch as add.
std/quantity:lit { 5 m }
| exact c |> std/quantity:lit { 2 s }
    | exact d |> std/quantity:sub(a: c, b: d)
        | exact r |> std/io:print.ln("subtracted") |> std/quantity:free(n: r)
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
