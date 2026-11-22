import std/io
import std/quantity

// Juxtaposition is multiplication in the lit grammar: 5 m/s, 5m/s and
// 5*m/s are the same quantity. A bare unit run is a product — kgm is
// kg*m, longest match wins (mol, kg before m, s). Non-unit tails refuse.

std/quantity:lit(5 m/s)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(5m/s)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(5*m/s)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(2 kgm)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(5*mol/s)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(5 m m/s)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(2.5 kg m/s, unc: 0.1, cov: "bias")
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(5xyz)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(5 m / s)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")

std/quantity:lit(kg)
| exact a |> std/quantity:render(n: a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad:{{ x:s }}")
