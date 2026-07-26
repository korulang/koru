import std/io
import std/field

pub tor run {}
run = std/field:new(bits: 500000)
| field f |> for(1..500)
    ! each i |> std/field:test(f, i): pv |> if(pv == 0)
        | then |> std/field:mark-multiples(f, from: 2 * i * (i + 1), stride: 2 * i + 1, limit: 499999)
    | done |> std/field:count-zeros(f, lo: 1, hi: 500000): c |> std/io:print.ln("{{ c + 1:d }}") |> std/field:free(f)
| err e |> std/io:print.ln("ERR {{ e:s }}")
