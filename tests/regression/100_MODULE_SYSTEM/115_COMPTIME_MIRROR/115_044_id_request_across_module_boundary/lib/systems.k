// A system in a DIFFERENT module than the store: it captures a value per row
// (`k`, lexical) AND asks for the visited row's handle (`[id]`, synthesized).
import std/store

pub tor tick {} -> i64
tick -> 2

pub tor scale-and-link {}
scale-and-link = tick(): k |> std/store:query(cells)
! query { [row]e, [id]h } |> std/store:stored { e.v: e.v * k }
    |> std/store:stored { e.next: head.h }
    |> std/store:stored { head.h: h }
