// NESTING SWEEP — ifcond under a scalar branch (std/args:count).
import std/io
import std/args

std/args:count()
| count _ |> if(1 == 1)
    | then |> std/io:print.ln("then")
    | else |> std/io:print.ln("else")
