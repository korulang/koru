// std/quantity: mag unwraps the magnitude INTO the number tower as
// <std/num:exact!> — the lawful crossing between the two marks.
import std/io
import std/num
import std/quantity

std/quantity:lit(s: "2.5 kg")
| exact q |> std/quantity:mag(q): m |> std/num:lit(s: "0.5")
    | exact h |> std/num:add(a: m, b: h): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
