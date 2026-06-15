// NESTING SWEEP — ifcond under flow-head (BASELINE).
// The construct (if(1==1) printing "then") IS the top-level flow head.
import std/io

if(1 == 1)
| then |> std/io:print.ln("then")
| else |> std/io:print.ln("else")
