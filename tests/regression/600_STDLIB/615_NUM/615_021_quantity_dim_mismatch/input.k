// std/quantity: metre + second is a lawful |dim-mismatch branch,
// not an error path. Runtime values from the text lane (ingest+parse)
// cannot be dimension-checked until they exist — the arm is the law.
// (The same mismatch between two authored lit() literals refuses at
// compile time instead — pinned in 615_075.)
import std/io
import std/quantity

std/quantity:ingest(s: "1 m"): e1 |> std/quantity:parse(s: e1)
| exact a |> std/quantity:ingest(s: "2 s"): e2 |> std/quantity:parse(s: e2)
    | exact b |> std/quantity:add(a, b)
        | exact r |> std/io:print.ln("added") |> std/quantity:free(n: r)
        | dim-mismatch |> std/io:print.ln("dims do not add")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
