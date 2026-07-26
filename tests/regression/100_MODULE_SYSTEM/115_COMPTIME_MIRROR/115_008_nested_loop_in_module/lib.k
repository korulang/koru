import std/io

pub tor run {}
run = for(0..2)
! each i |> for(0..2)
    ! each j |> std/io:print.ln("{{ i:d }}{{ j:d }}")
