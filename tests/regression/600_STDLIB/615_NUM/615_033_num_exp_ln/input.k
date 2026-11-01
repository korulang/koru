// std/num:exp + ln — Taylor/artanh series over the Dec core with guard
// digits. exp refuses huge results on |overflow (a Debug-mode multiply of a
// 400k-digit bigint is a hang, not an answer); ln refuses x <= 0 on |non-pos.
import std/io
import std/num

std/num:lit { 1 }
| exact a |> std/num:exp(a, prec: 30)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | overflow |> std/io:print.ln("exp:overflow")
| bad x |> std/io:print.ln("bad")

std/num:lit { 2.718281828459045235360287471353 }
| exact a |> std/num:ln(a, prec: 30)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | non-pos |> std/io:print.ln("ln:non-pos")
| bad x |> std/io:print.ln("bad")

std/num:lit { 0 }
| exact a |> std/num:ln(a, prec: 20)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | non-pos |> std/io:print.ln("ln0:non-pos")
| bad x |> std/io:print.ln("bad")

std/num:lit { -2 }
| exact a |> std/num:ln(a, prec: 20)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | non-pos |> std/io:print.ln("lnneg:non-pos")
| bad x |> std/io:print.ln("bad")

std/num:lit { 1e6 }
| exact a |> std/num:exp(a, prec: 20)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | overflow |> std/io:print.ln("exp:overflow")
| bad x |> std/io:print.ln("bad")
