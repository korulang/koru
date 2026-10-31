// qcalc — a quantity calculator over stdin.
//
// One operation per line, semicolon-separated:
//     <qty> ; <add|sub|mul|div> ; <qty>
//
//     5 m/s ; mul ; 3 s           ->  1.5e1 | m^1 ...        (15 m)
//     5 m/s ; div ; 2 s           ->  2.5e0 | m^1 s^-2 ...   (2.5 m/s^2)
//     4 N ; mul ; 2 m             ->  8e0 | kg^1 m^2 s^-2    (== 8 J)
//     2 m±0.1 ; add ; 1 m±0.1     ->  uncertainty in quadrature
//     2 m±0.1@bias ; sub ; 1 m±0.1@bias
//                                 ->  correlated sigma cancels
//     2 m ; add ; 3 s             ->  dim-mismatch (a lawful refusal,
//                                     not a silent wrong answer)
//
// Taint is real: the raw line text is `external`, must pass `qty:parse`
// before any op touches it, and every `exact` result is consumed —
// render+free or free. A `no-match` op arm still discharges both parsed
// quantities; linear obligations leave nothing dangling.

import std/io
import std/regex
import std/quantity
import std/string

tor eval { a: string, op: string, b: string }

eval = std/quantity:ingest(s: a): ea |> std/quantity:parse(s: ea)
| bad m |> std/io:print.ln("bad left qty: {{ m:s }}") |> std/io:free(content: m)
| exact qa |> std/quantity:ingest(s: b): eb |> std/quantity:parse(s: eb)
    | bad m |> std/quantity:free(n: qa) |> std/io:print.ln("bad right qty: {{ m:s }}") |> std/io:free(content: m)
    | exact qb |> std/regex:match(op)
        | `add` _ |> std/quantity:add(a: qa, b: qb)
            | exact r |> std/quantity:render(n: r): o |> std/io:print.ln("{{ o:s }}") |> std/io:free(content: o)
            | dim-mismatch |> std/io:print.ln("dim-mismatch")
            | mixed-cov |> std/io:print.ln("mixed-cov")
        | `sub` _ |> std/quantity:sub(a: qa, b: qb)
            | exact r |> std/quantity:render(n: r): o |> std/io:print.ln("{{ o:s }}") |> std/io:free(content: o)
            | dim-mismatch |> std/io:print.ln("dim-mismatch")
            | mixed-cov |> std/io:print.ln("mixed-cov")
        | `mul` _ |> std/quantity:mul(a: qa, b: qb)
            | exact r |> std/quantity:render(n: r): o |> std/io:print.ln("{{ o:s }}") |> std/io:free(content: o)
            | mixed-cov |> std/io:print.ln("mixed-cov")
            | bad x |> std/io:print.ln("{{ x:s }}")
            | sym-unc |> std/io:print.ln("sym-unc: relative sigma over a symbolic magnitude needs sym:eval")
        | `div` _ |> std/quantity:div(a: qa, b: qb, prec: 25)
            | exact r |> std/quantity:render(n: r): o |> std/io:print.ln("{{ o:s }}") |> std/io:free(content: o)
            | div-zero |> std/io:print.ln("div-zero")
            | mixed-cov |> std/io:print.ln("mixed-cov")
            | bad x |> std/io:print.ln("{{ x:s }}")
            | sym-unc |> std/io:print.ln("sym-unc: relative sigma over a symbolic magnitude needs sym:eval")
        | no-match |> std/quantity:free(n: qa) |> std/quantity:free(n: qb) |> std/io:print.ln("unknown op: {{ op:s }}")

std/io:read-stdin()
| ok s |> std/string:split(s, sep: "\n")
    ! piece l |> std/regex:match(l)
        | ` *` _ |> _
        | `(?<a>[^;]*[^; ]) *; *(?<op>[a-z-]+) *; *(?<b>[^;]*[^; ]) *` { a: string, op: string, b: string } |> eval(a, op, b)
        | no-match |> std/io:print.ln("bad line: {{ l:s }}")
    | done _ |> std/io:free(content: s)
| eof |> std/io:print.ln("qcalc: empty input")
| failed m |> std/io:print.ln("qcalc: stdin failed {{ m:s }}")
