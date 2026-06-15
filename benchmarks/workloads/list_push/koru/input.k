// Push N i64 into a std/list, report len. Measures the list-abstraction cost
// (new + N×push + len + free) vs hand-written Zig std.ArrayList.
import std/io
import std/list
std/list:new(i64)
| list xs |> for(0..50000000)
    ! each _ |> std/list:push(xs, 1)
    | done |> std/list:len(xs)
        | len m |> std/io:print.ln("len={{ m:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
