// std/quantity: mag unwraps the magnitude as a lane union —
// decimal canon under <std/num:exact!>, symbolic canon under
// <std/sym:sexpr!>. A decimal magnitude crosses into the number tower.
import std/io
import std/num
import std/sym
import std/quantity

std/quantity:lit { 2.5 kg }
| exact q |> std/quantity:mag(q)
    | num m |> std/num:lit { 0.5 }
        | exact h |> std/num:add(a: m, b: h): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
        | bad x |> std/io:print.ln("bad")
    | sym m |> std/io:print.ln("sym-lane") |> std/sym:free(n: m)
| bad y |> std/io:print.ln("bad")
