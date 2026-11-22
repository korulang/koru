// std/quantity: both operands of add trace to authored lit() literals —
// the dims are statically decidable, so a mismatch is an authoring error
// refused at compile time (KORU189), not a |dim-mismatch branch.
import std/io
import std/quantity

std/quantity:lit(1*m)
| exact a |> std/quantity:lit(2*s)
    | exact b |> std/quantity:add(a, b)
        | exact r |> std/io:print.ln("added") |> std/quantity:free(n: r)
        | dim-mismatch |> std/io:print.ln("dims do not add")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
