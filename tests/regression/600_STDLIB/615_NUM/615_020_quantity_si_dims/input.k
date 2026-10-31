// std/quantity: kinetic energy — E = 0.5 * m * v^2.
// 0.5 * (2.0+-0.1 kg) * (3.0 m/s)^2 = 9 J (dims compose, uncertainty
// propagates: 9 * 0.1/2.0 = 0.45).
import std/io
import std/quantity

std/quantity:lit(s: "0.5")
| exact h |> std/quantity:lit(s: "2.0+-0.1 kg")
    | exact m |> std/quantity:lit(s: "3.0 m/s")
        | exact v |> std/quantity:pow(a: v, n: 2)
            | exact v2 |> std/quantity:mul(a: h, b: m)
                | exact hm |> std/quantity:mul(a: hm, b: v2)
                    | exact e |> std/quantity:render(n: e): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
                    | mixed-cov |> std/io:print.ln("mixed-cov")
                    | bad x |> std/io:print.ln("{{ x:s }}")
                    | sym-unc |> std/io:print.ln("sym-unc")
                | mixed-cov |> std/io:print.ln("mixed-cov")
                | bad x |> std/io:print.ln("{{ x:s }}")
                | sym-unc |> std/io:print.ln("sym-unc")
            | div-zero |> std/io:print.ln("div-zero")
            | sym-unc |> std/io:print.ln("sym-unc")
        | bad x |> std/io:print.ln("bad v")
    | bad x |> std/io:print.ln("bad m")
| bad y |> std/io:print.ln("bad h")
