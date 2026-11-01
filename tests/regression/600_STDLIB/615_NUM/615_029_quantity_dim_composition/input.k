// std/quantity: measures compose to a normal form on the result —
// (m/s)*s -> m, (m/s)/s -> m/s^2, N*m == J. The composition IS the
// return type: canonical dims make equiv a string comparison.
import std/io
import std/quantity

std/quantity:lit { 5 m/s }
| exact v |> std/quantity:lit { 3 s }
    | exact t |> std/quantity:mul(a: v, b: t)
        | exact d |> std/quantity:render(n: d): o |> std/io:print.ln("{{ o:s }}") |> std/io:free(content: o)
        | mixed-cov |> std/io:print.ln("mixed-cov")
        | bad x |> std/io:print.ln("{{ x:s }}")
        | sym-unc |> std/io:print.ln("sym-unc")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

std/quantity:lit { 5 m/s }
| exact v2 |> std/quantity:lit { 2 s }
    | exact s2 |> std/quantity:div(a: v2, b: s2, prec: 15)
        | exact acc |> std/quantity:render(n: acc): o2 |> std/io:print.ln("{{ o2:s }}") |> std/io:free(content: o2)
        | div-zero |> std/io:print.ln("div-zero")
        | mixed-cov |> std/io:print.ln("mixed-cov")
        | bad x |> std/io:print.ln("{{ x:s }}")
        | sym-unc |> std/io:print.ln("sym-unc")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

// N*m ≡ J — normalized canonical equivalence.
std/quantity:lit { 4 N }
| exact f |> std/quantity:lit { 2 m }
    | exact mm |> std/quantity:mul(a: f, b: mm)
        | exact w |> std/quantity:lit { 8 J }
            | exact j |> std/quantity:equiv(a: w, b: j)
                | same |> std/io:print.ln("N*m == J")
                | diff |> std/io:print.ln("not equal")
                |> std/quantity:free(n: w) |> std/quantity:free(n: j)
            | bad x |> std/io:print.ln("bad")
        | mixed-cov |> std/io:print.ln("mixed-cov")
        | bad x |> std/io:print.ln("{{ x:s }}")
        | sym-unc |> std/io:print.ln("sym-unc")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
