// std/num: 30-digit + 30-digit — well past i64/f64 range, exact.
import std/io
import std/num

std/num:lit(123456789012345678901234567890)
| exact a |> std/num:lit(987654321098765432109876543210)
    | exact b |> std/num:add(a, b): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | bad x |> std/io:print.ln("bad")
| bad y |> std/io:print.ln("bad")
