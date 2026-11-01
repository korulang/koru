// std/num: the equivalence law — canonical form makes value equality
// string equality: 0.50 == 5e-1, 1 != 2.
import std/io
import std/num

std/num:lit { 0.50 }
| exact a |> std/num:lit { 5e-1 }
    | exact b |> std/num:equiv(a, b)
        | same |> std/io:print.ln("0.50 == 5e-1")
        | diff |> std/io:print.ln("not equal")
        |> std/num:free(n: a) |> std/num:free(n: b)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")

std/num:lit { 1 }
| exact a |> std/num:lit { 2 }
    | exact b |> std/num:equiv(a, b)
        | same |> std/io:print.ln("1 == 2")
        | diff |> std/io:print.ln("1 != 2")
        |> std/num:free(n: a) |> std/num:free(n: b)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
