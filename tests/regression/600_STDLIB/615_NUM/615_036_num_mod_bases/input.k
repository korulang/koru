// std/num rung 2 — exact mod (trunc-mod, sign follows the dividend),
// length/scale introspection, and integer base conversion. to-base refuses
// non-integers outright rather than emitting bc's digit-vector notation.
import std/io
import std/num

std/num:lit { 17 }
| exact a |> std/num:lit { 5 }
    | exact b |> std/num:mod(a, b)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
        | div-zero |> std/io:print.ln("dz")
    | bad y |> std/io:print.ln("bad-b")
| bad x |> std/io:print.ln("bad-a")

std/num:lit { -17 }
| exact a |> std/num:lit { 5 }
    | exact b |> std/num:mod(a, b)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
        | div-zero |> std/io:print.ln("dz")
    | bad y |> std/io:print.ln("bad-b")
| bad x |> std/io:print.ln("bad-a")

std/num:lit { 5.5 }
| exact a |> std/num:lit { 2 }
    | exact b |> std/num:mod(a, b)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
        | div-zero |> std/io:print.ln("dz")
    | bad y |> std/io:print.ln("bad-b")
| bad x |> std/io:print.ln("bad-a")

std/num:lit { 7 }
| exact a |> std/num:lit { 0 }
    | exact b |> std/num:mod(a, b)
        | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
        | div-zero |> std/io:print.ln("mod:div-zero")
    | bad y |> std/io:print.ln("bad-b")
| bad x |> std/io:print.ln("bad-a")

std/num:lit { 1.234e5 }
| exact a |> std/num:length(a): n |> std/io:print.ln("len={{ n:d }}") |> std/num:free(n: a)
| bad x |> std/io:print.ln("bad")

std/num:lit { 1.234e-5 }
| exact a |> std/num:scale(a): n |> std/io:print.ln("sc={{ n:d }}") |> std/num:free(n: a)
| bad x |> std/io:print.ln("bad")

std/num:lit { 255 }
| exact a |> std/num:to-base(a, base: 16)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | non-int |> std/io:print.ln("ni")
    | bad-base |> std/io:print.ln("bb")
| bad x |> std/io:print.ln("bad")

std/num:lit { -255 }
| exact a |> std/num:to-base(a, base: 2)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | non-int |> std/io:print.ln("ni")
    | bad-base |> std/io:print.ln("bb")
| bad x |> std/io:print.ln("bad")

std/num:lit { 1.5 }
| exact a |> std/num:to-base(a, base: 16)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | non-int |> std/io:print.ln("to-base:non-int")
    | bad-base |> std/io:print.ln("bb")
| bad x |> std/io:print.ln("bad")

std/num:from-base(s: "ff", base: 16)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | bad-digit |> std/io:print.ln("bd")
    | bad-base |> std/io:print.ln("bb")

std/num:from-base(s: "1z", base: 10)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | bad-digit |> std/io:print.ln("from-base:bad-digit")
    | bad-base |> std/io:print.ln("bb")

std/num:from-base(s: "-1010", base: 2)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/num:free(n: r)
    | bad-digit |> std/io:print.ln("bd")
    | bad-base |> std/io:print.ln("bb")
