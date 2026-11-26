// std/linalg: matrix custody over rat cells + the Bareiss engine —
// fraction-free elimination over Z with honest back-substitution over Q.
import std/io
import std/rational
import std/linalg

// lit+render round-trip: cells canonicalize to n:d, zeroes to 0:1.
std/linalg:lit(s: "2x2: 1/2 0 3 -4")
| exact m |> std/linalg:render(m): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

// det: exact rational determinant, non-square names |bad-dims.
std/linalg:lit(s: "2x2: 1/2 0 3 -4")
| exact m |> std/linalg:det(m)
    | exact d |> std/io:print.ln("det={{ d:s }}") |> std/rational:free(n: d)
    | bad-dims |> std/io:print.ln("bad-dims")
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "2x1: 1 3")
| exact m |> std/linalg:det(m)
    | exact d |> std/io:print.ln("det={{ d:s }}") |> std/rational:free(n: d)
    | bad-dims |> std/io:print.ln("bad-dims")
| bad x |> std/io:print.ln("bad-lit")

// inv: diagonal inverse mints reciprocal entries; singular names |singular.
std/linalg:lit(s: "2x2: 2 0 0 4")
| exact a |> std/linalg:inv(m: a)
    | exact ai |> std/linalg:render(m: ai): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | singular |> std/io:print.ln("singular")
    | bad-dims |> std/io:print.ln("bad-dims")
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "2x2: 1 2 2 4")
| exact a |> std/linalg:inv(m: a)
    | exact ai |> std/linalg:render(m: ai): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
    | singular |> std/io:print.ln("singular")
    | bad-dims |> std/io:print.ln("bad-dims")
| bad x |> std/io:print.ln("bad-lit")

// solve: exact Q solution by back-substitution off the Bareiss tableau.
std/linalg:lit(s: "2x2: 2 1 1 1")
| exact a |> std/linalg:lit(s: "2x1: 5 4")
    | exact b |> std/linalg:solve(a, b)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// mul: inner-dim mismatch names |dims.
std/linalg:lit(s: "2x2: 1 2 3 4")
| exact a |> std/linalg:lit(s: "2x2: 5 6 7 8")
    | exact b |> std/linalg:mul(a, b)
        | exact p |> std/linalg:render(m: p): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | dims |> std/io:print.ln("dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "2x2: 1 2 3 4")
| exact a |> std/linalg:lit(s: "2x3: 1 0 0 0 1 0")
    | exact b |> std/linalg:mul(a, b)
        | exact p |> std/linalg:render(m: p): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | dims |> std/io:print.ln("dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "2x2: 1 2 3 4")
| exact a |> std/linalg:lit(s: "3x2: 1 0 0 1 0 0")
    | exact b |> std/linalg:mul(a, b)
        | exact p |> std/linalg:render(m: p): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | dims |> std/io:print.ln("dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// add/sub: cellwise rat arithmetic.
std/linalg:lit(s: "2x2: 1/2 1 0 1/3")
| exact a |> std/linalg:lit(s: "2x2: 1/2 0 1 2/3")
    | exact b |> std/linalg:add(a, b)
        | exact s |> std/linalg:render(m: s): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
        | dims |> std/io:print.ln("dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// transpose.
std/linalg:lit(s: "2x2: 1/3 2/7 5/11 1/13")
| exact a |> std/linalg:transpose(m: a): t2 |> std/linalg:render(m: t2): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad x |> std/io:print.ln("bad-lit")

// identity + get + range arm.
std/linalg:identity(n: 3)
| exact m |> std/linalg:render(m): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t)
| bad |> std/io:print.ln("bad")

std/linalg:lit(s: "2x2: 1 2 3 4")
| exact m |> std/linalg:get(m, i: 1, j: 0)
    | exact g |> std/io:print.ln("g10={{ g:s }}") |> std/rational:free(n: g)
    | range |> std/io:print.ln("range")
    |> std/linalg:free(m)
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "2x2: 1 2 3 4")
| exact m |> std/linalg:get(m, i: 5, j: 0)
    | exact g |> std/io:print.ln("g={{ g:s }}") |> std/rational:free(n: g)
    | range |> std/io:print.ln("range")
    |> std/linalg:free(m)
| bad x |> std/io:print.ln("bad-lit")

// equiv / is-zero: canon-string equality, all-zero scan.
std/linalg:lit(s: "1x2: 2/4 6/8")
| exact a |> std/linalg:lit(s: "1x2: 1/2 3/4")
    | exact b |> std/linalg:equiv(a, b)
        | same |> std/io:print.ln("same")
        | diff |> std/io:print.ln("diff")
        |> std/linalg:free(m: b)
    | bad _ |> std/linalg:free(m: a) |> std/io:print.ln("bad-lit")
    |> std/linalg:free(m: a)
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "1x2: 0 0")
| exact a |> std/linalg:is-zero(m: a)
    | zero |> std/io:print.ln("zero")
    | nonzero |> std/io:print.ln("nonzero")
    |> std/linalg:free(m: a)
| bad x |> std/io:print.ln("bad-lit")

// dup: two independent custody copies.
std/linalg:lit(s: "1x2: 1/7 -3")
| exact a |> std/linalg:dup(m: a): d |> std/linalg:render(m: d.a): t |> std/io:print.ln("{{ t:s }}") |> std/io:free(content: t) |> std/linalg:render(m: d.b): t2 |> std/io:print.ln("{{ t2:s }}") |> std/io:free(content: t2)
| bad x |> std/io:print.ln("bad-lit")
