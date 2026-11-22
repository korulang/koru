// PIN: a produce-stage rebind evaluates its RHS in the pre-stage scope —
// `{ i: i + 1 }` reads the each-bound `i`, then mints the stage `i` holding
// `i + 1`. Minimal isolate of 320_179.
import std/io

for(1..3)
    ! each i { i: i + 1 } |> std/io:print.ln("n{{ i:d }}")
