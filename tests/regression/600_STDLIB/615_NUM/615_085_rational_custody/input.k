// std/rational: custody kit over canon "rat:v1;<n>;<d>" — literals reduce
// on mint, arms name the honest outcomes, borrows vs consumes.
import std/io
import std/num
import std/rational

// lit spellings: "n/d" (reduced), integer, decimal (reduced), bad.
std/rational:lit(s: "1/3")
| exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "4/6")
| exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "1.5")
| exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "1/0")
| exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

// 1/3 + 1/6 = 1/2 — the result Dec cannot hold exactly.
std/rational:lit(s: "1/3")
| exact a |> std/rational:lit(s: "1/6")
    | exact b |> std/rational:add(a, b): s |> std/rational:render(n: s): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "5/6")
| exact a |> std/rational:lit(s: "1/6")
    | exact b |> std/rational:sub(a, b): s |> std/rational:render(n: s): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "2/3")
| exact a |> std/rational:lit(s: "3/4")
    | exact b |> std/rational:mul(a, b): s |> std/rational:render(n: s): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// div is exact — no prec — and names |div-zero.
std/rational:lit(s: "2/3")
| exact a |> std/rational:lit(s: "4/5")
    | exact b |> std/rational:div(a, b)
        | exact s |> std/rational:render(n: s): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | div-zero |> std/io:print.ln("dz")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "2/3")
| exact a |> std/rational:lit(s: "0")
    | exact b |> std/rational:div(a, b)
        | exact s |> std/rational:render(n: s): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | div-zero |> std/io:print.ln("dz")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// cmp borrows; equiv is the canon-string law; is-zero arms.
std/rational:lit(s: "1/3")
| exact a |> std/rational:lit(s: "2/7")
    | exact b |> std/rational:cmp(a, b)
        | lt |> std/io:print.ln("lt")
        | eq |> std/io:print.ln("eq")
        | gt |> std/io:print.ln("gt")
        |> std/rational:equiv(a, b)
            | same |> std/io:print.ln("same")
            | diff |> std/io:print.ln("diff")
        |> std/rational:is-zero(n: a)
            | zero |> std/io:print.ln("zero")
            | nonzero |> std/io:print.ln("nonzero")
        |> std/rational:free(n: a) |> std/rational:free(n: b)
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// numer/denom mint Decs (borrows); neg/abs; dup splits custody.
std/rational:lit(s: "-22/7")
| exact a |> std/rational:numer(a): n |> std/io:print.ln("n={{ n:s }}") |> std/num:free(n)
    |> std/rational:denom(a): d |> std/io:print.ln("d={{ d:s }}") |> std/num:free(n: d)
    |> std/rational:free(n: a)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "-2/3")
| exact a |> std/rational:neg(a): n |> std/rational:render(n): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "-2/3")
| exact a |> std/rational:abs(a): n |> std/rational:render(n): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

std/rational:lit(s: "7/9")
| exact a |> std/rational:dup(n: a): d |> std/rational:render(n: d.a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t) |> std/rational:render(n: d.b): t2 |> std/io:print.ln("{{ t2:s }}") |> std/io:free(content: t2)
| bad x |> std/io:print.ln("bad-lit")

std/rational:from-int(i: -5): r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)

// external boundary: ingest -> parse | drop.
std/rational:ingest(s: "11/13"): e |> std/rational:parse(s: e)
| exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-parse") |> std/io:free(content: x)

std/rational:ingest(s: "junk!"): e |> std/rational:parse(s: e)
| exact r |> std/rational:render(n: r): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-parse") |> std/io:free(content: x)

std/rational:ingest(s: "3/5"): e |> std/rational:drop(s: e)
