// std/quantity: two DIFFERENT shared sources can't be combined — the
// correlation between @bias and @other is unknowable, so the op
// refuses on a named branch rather than assuming independence.
import std/io
import std/quantity

std/quantity:lit { 2+-0.1@bias m }
| exact a |> std/quantity:lit { 1+-0.1@other m }
    | exact b |> std/quantity:add(a, b)
        | exact r |> std/quantity:render(n: r): t |> std/io:print.ln("{{ t:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov refused")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

// one-sided tag: independent sigma, tag carried forward conservatively
std/quantity:lit { 2+-0.1@bias m }
| exact c |> std/quantity:lit { 1+-0.1 m }
    | exact d |> std/quantity:add(a: c, b: d)
        | exact r2 |> std/quantity:render(n: r2): t2 |> std/io:print.ln("{{ t2:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
