// std/sym rung 3 — canonical normal form: atoms, exact-decimal folding,
// sorted products/sums, coefficient grouping, cancellation. Equivalence is
// canon string equality, same law as std/num.
import std/io
import std/sym

std/sym:lit(expr: π)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: π+π)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: (2*π)+(3*π))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: 2*π+3)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: 1/4)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: 1/3)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: √(0.25))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: √(2)*√(2))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: π-π)
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: 1/(1/π))
| exact a |> std/io:print.ln("{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

// commutativity: both spellings land on one canon
std/sym:lit(expr: e*π)
| exact a |> std/sym:lit(expr: π*e)
    | exact b |> std/sym:equiv(a, b)
        | same |> std/io:print.ln("commuted: same") |> std/sym:free(n: a) |> std/sym:free(n: b)
        | diff |> std/io:print.ln("commuted: diff") |> std/sym:free(n: a) |> std/sym:free(n: b)
    | bad |> std/io:print.ln("bad2") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: π)
| exact a |> std/sym:lit(expr: π)
    | exact b |> std/sym:mul(a, b): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
    | bad |> std/io:print.ln("bad2") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: π)
| exact a |> std/sym:lit(expr: π)
    | exact b |> std/sym:div(a, b)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
        | div-zero |> std/io:print.ln("dz")
    | bad |> std/io:print.ln("bad2") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")
