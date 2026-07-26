// CONTROL for 115_008: the identical nested loop in a `pub tor` in the ENTRY
// file. Isolates module placement as the only difference.
import std/io

pub tor run {}
run = for(0..2)
! each i |> for(0..2)
    ! each j |> std/io:print.ln("{{ i:d }}{{ j:d }}")

run()
