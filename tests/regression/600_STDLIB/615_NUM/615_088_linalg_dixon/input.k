// std/linalg solve-dixon: the p-adic engine — Gaussian elimination mod p,
// Hensel lift, Wang rational reconstruction per entry, and a full-Q
// residual check as the honest stop condition (no Hadamard bound).
import std/io
import std/rational
import std/linalg

// exact: same system as the Bareiss pin — engines agree on x=[1,3].
std/linalg:lit(s: "2x2: 2 1 1 1")
| exact a |> std/linalg:lit(s: "2x1: 5 4")
    | exact b |> std/linalg:solve-dixon(a, b, prime: 13)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
        | bad-prime |> std/io:print.ln("bad-prime")
        | open |> std/io:print.ln("open")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// a rational-denominator system — the point of p-adic solves.
std/linalg:lit(s: "2x2: 1/2 1/3 1/5 1/7")
| exact a |> std/linalg:lit(s: "2x1: 5/6 12/35")
    | exact b |> std/linalg:solve-dixon(a, b, prime: 7)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
        | bad-prime |> std/io:print.ln("bad-prime")
        | open |> std/io:print.ln("open")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// the same system through Bareiss — engines must agree.
std/linalg:lit(s: "2x2: 1/2 1/3 1/5 1/7")
| exact a |> std/linalg:lit(s: "2x1: 5/6 12/35")
    | exact b |> std/linalg:solve(a, b)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// singular mod the prime but invertible over Q — the honest dixon refusal:
// det=13 makes the mod-13 matrix singular, so |singular names it while
// Bareiss still solves the same system exactly.
std/linalg:lit(s: "2x2: 13 0 0 1")
| exact a |> std/linalg:lit(s: "2x1: 26 1")
    | exact b |> std/linalg:solve-dixon(a, b, prime: 13)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
        | bad-prime |> std/io:print.ln("bad-prime")
        | open |> std/io:print.ln("open")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

std/linalg:lit(s: "2x2: 13 0 0 1")
| exact a |> std/linalg:lit(s: "2x1: 26 1")
    | exact b |> std/linalg:solve(a, b)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// bad-prime: prime < 2 names it instead of running Fermat on a non-prime.
std/linalg:lit(s: "2x2: 2 1 1 1")
| exact a |> std/linalg:lit(s: "2x1: 5 4")
    | exact b |> std/linalg:solve-dixon(a, b, prime: 1)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
        | bad-prime |> std/io:print.ln("bad-prime")
        | open |> std/io:print.ln("open")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")

// bad-dims: non-square coefficient matrix.
std/linalg:lit(s: "2x3: 1 0 0 0 1 0")
| exact a |> std/linalg:lit(s: "2x1: 1 1")
    | exact b |> std/linalg:solve-dixon(a, b, prime: 13)
        | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
        | singular |> std/io:print.ln("singular")
        | bad-dims |> std/io:print.ln("bad-dims")
        | bad-prime |> std/io:print.ln("bad-prime")
        | open |> std/io:print.ln("open")
    | bad y |> std/io:print.ln("bad-lit")
| bad x |> std/io:print.ln("bad-lit")
