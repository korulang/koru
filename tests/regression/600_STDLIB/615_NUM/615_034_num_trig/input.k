// std/num:sin/cos/atan — mod-2pi reduction + fold to [0,pi/2], Taylor with
// guard digits; atan reduces to |x|<=1, three argument halvings, Taylor.
import std/io
import std/num

std/num:lit(s: "0")
| exact a |> std/num:sin(a, prec: 20)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | overflow |> std/io:print.ln("of")
| bad x |> std/io:print.ln("bad")

std/num:lit(s: "0.5")
| exact a |> std/num:sin(a, prec: 20)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | overflow |> std/io:print.ln("of")
| bad x |> std/io:print.ln("bad")

std/num:lit(s: "1.5707963267948966192313216916398")
| exact a |> std/num:sin(a, prec: 30)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | overflow |> std/io:print.ln("of")
| bad x |> std/io:print.ln("bad")

std/num:lit(s: "0")
| exact a |> std/num:cos(a, prec: 20)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | overflow |> std/io:print.ln("of")
| bad x |> std/io:print.ln("bad")

std/num:lit(s: "0.5")
| exact a |> std/num:atan(a, prec: 20): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
| bad x |> std/io:print.ln("bad")

std/num:lit(s: "1")
| exact a |> std/num:atan(a, prec: 30): r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
| bad x |> std/io:print.ln("bad")
