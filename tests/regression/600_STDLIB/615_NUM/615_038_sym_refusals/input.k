// std/sym rung 3 — named refusals and the taint boundary: outside text rides
// <sexpr-external!> until parse discharges it; div by a zero canon and a
// negative-decimal radicand refuse on named arms, never silently.
import std/io
import std/sym

std/sym:ingest(s: "π*e"): x |> std/sym:parse(s: x)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
    | bad b |> std/io:free(content: b)

std/sym:ingest(s: "not-an-expr!!"): x |> std/sym:parse(s: x)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
    | bad b |> std/io:print.ln("sym:parse bad") |> std/io:free(content: b)

std/sym:lit(expr: 5)
| exact a |> std/sym:lit(expr: 0)
    | exact b |> std/sym:div(a, b)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
        | div-zero |> std/io:print.ln("sym:div-zero")
    | bad |> std/io:print.ln("bad2") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: -4)
| exact a |> std/sym:sqrt(a)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
    | neg-root |> std/io:print.ln("sym:neg-root")
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: 4)
| exact a |> std/sym:sqrt(a)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
    | neg-root |> std/io:print.ln("nr")
| bad |> std/io:print.ln("bad")

std/sym:lit(expr: √(2))
| exact a |> std/sym:neg(a): r |> std/io:print.ln("{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")
