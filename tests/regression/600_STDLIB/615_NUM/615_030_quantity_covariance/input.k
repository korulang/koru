// std/quantity: shared-source covariance — `unc@<group>` tags a sigma
// as stemming from a common source. Same group adds linearly (fully
// correlated); a negated instance makes subtraction CANCEL the bias.
import std/io
import std/quantity

// 2+-0.1@bias + 1+-0.1@bias = 3 +- 0.2 (linear, not quadrature)
std/quantity:lit { 2+-0.1@bias m }
| exact a |> std/quantity:lit { 1+-0.1@bias m }
    | exact b |> std/quantity:add(a, b)
        | exact r |> std/quantity:render(n: r): t |> std/io:print.ln("{{ t:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

// 2+-0.1@bias - 1+-0.1@bias = 1 (certain — the bias cancels)
std/quantity:lit { 2+-0.1@bias m }
| exact c |> std/quantity:lit { 1+-0.1@bias m }
    | exact d |> std/quantity:sub(a: c, b: d)
        | exact r2 |> std/quantity:render(n: r2): t2 |> std/io:print.ln("{{ t2:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

// same-group relative sigmas add under mul: 2+-0.1@b * 3+-0.3@b
// rel: 0.05 + 0.1 = 0.15 -> sigma = 6 * 0.15 = 0.9
std/quantity:lit { 2+-0.1@b m }
| exact e |> std/quantity:lit { 3+-0.3@b s }
    | exact g |> std/quantity:mul(a: e, b: g)
        | exact r3 |> std/quantity:render(n: r3): t3 |> std/io:print.ln("{{ t3:s }}")
        | mixed-cov |> std/io:print.ln("mixed-cov")
        | bad x |> std/io:print.ln("{{ x:s }}")
        | sym-unc |> std/io:print.ln("sym-unc")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
