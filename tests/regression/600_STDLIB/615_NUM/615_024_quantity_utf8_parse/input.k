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

// text lane: g^-1 inverts the gram scale (2 m g^-1 = 2e3 m/kg)
std/quantity:ingest(s: "2 m·g⁻¹"): e1 |> std/quantity:parse(s: e1)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad") |> std/io:free(content: x)

std/quantity:ingest(s: "2 m g^-1"): e2 |> std/quantity:parse(s: e2)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad") |> std/io:free(content: x)

// text lane: a negated named constant stays symbolic
std/quantity:ingest(s: "-π m"): e3 |> std/quantity:parse(s: e3)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad") |> std/io:free(content: x)
