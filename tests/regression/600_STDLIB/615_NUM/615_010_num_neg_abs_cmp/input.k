// std/num: neg, abs, cmp (borrow — operands keep their mark).
import std/io
import std/num

std/num:lit(-2.5)
| exact a |> std/num:neg(a): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
| bad x |> std/io:print.ln("bad")

std/num:lit(-2.5)
| exact a |> std/num:abs(a): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
| bad x |> std/io:print.ln("bad")

std/num:lit(1)
| exact a |> std/num:lit(2)
    | exact b |> std/num:cmp(a, b)
        | lt |> std/io:print.ln("lt")
        | eq |> std/io:print.ln("eq")
        | gt |> std/io:print.ln("gt")
        |> std/num:free(n: a) |> std/num:free(n: b)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
