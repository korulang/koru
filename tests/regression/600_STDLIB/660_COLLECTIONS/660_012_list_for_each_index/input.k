// "for each" over a list via index loop: len gives the count, for(0..n) walks
// indices, get(xs,i) reads each. No new feature needed — iteration composes from
// len + for + get. Prints each element in order.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, v: 10) |> std/list:push(xs, v: 20) |> std/list:push(xs, v: 30) |> std/list:len(xs): n |> for(0..n)
        ! each i |> std/list:get(xs, i)
            | item v |> std/io:print.ln("{{ v:d }}")
            | out-of-bounds |> _
        | done |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
