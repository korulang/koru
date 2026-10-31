// std/quantity: independent uncertainties add in quadrature —
// sqrt(0.1^2 + 0.1^2) = 0.1414213562373095...
import std/io
import std/quantity

std/quantity:lit(s: "2.0+-0.1 kg")
| exact a |> std/quantity:lit(s: "1.0+-0.1 kg")
    | exact b |> std/quantity:add(a, b)
        | exact r |> std/quantity:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
