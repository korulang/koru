// std/quantity: metre + second is a lawful |dim-mismatch branch,
// not an error path.
import std/io
import std/quantity

std/quantity:lit { 1 m }
| exact a |> std/quantity:lit { 2 s }
    | exact b |> std/quantity:add(a, b)
        | exact r |> std/io:print.ln("added") |> std/quantity:free(n: r)
        | dim-mismatch |> std/io:print.ln("dims do not add")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
