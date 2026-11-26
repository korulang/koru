// std/linalg:kernel — the null-space tor. RREF over Q, last free column
// = 1, coefficients in the pivot columns. |singular names the trivial
// kernel (full column rank); |bad-dims names a degenerate matrix.
import std/io
import std/linalg

// 3x3 rank-2 kernel: third column = sum of first two -> kernel direction (free col = 1): x = [-1,-1,1]
// rows: (1 0 1) (0 1 1) (1 1 2)
std/linalg:lit(s: "3x3: 1 0 1 0 1 1 1 1 2")
| exact m |> std/linalg:kernel(a: m)
    | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
    | singular |> std/io:print.ln("singular")
    | bad-dims |> std/io:print.ln("bad-dims")
| bad e |> std/io:print.ln("bad-lit")

// the same system, checked by the witness: W*x = 0 for the full block
std/linalg:lit(s: "3x3: 1 0 1 0 1 1 1 1 2")
| exact m |> std/linalg:dup(m): d |> std/linalg:kernel(d.a)
    | exact x |> std/linalg:mul(a: d.b, b: x)
        | exact p |> std/linalg:is-zero(m: p)
            | zero |> std/io:print.ln("witness=zero") |> std/linalg:free(m: p)
            | nonzero |> std/io:print.ln("witness=nonzero") |> std/linalg:free(m: p)
        | dims |> std/io:print.ln("dims")
    | singular |> std/io:print.ln("singular") |> std/linalg:free(m: d.b)
    | bad-dims |> std/io:print.ln("bad-dims") |> std/linalg:free(m: d.b)
| bad e |> std/io:print.ln("bad-lit")

// full column rank -> trivial kernel only -> |singular
std/linalg:lit(s: "2x2: 1 0 0 1")
| exact m |> std/linalg:kernel(a: m)
    | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
    | singular |> std/io:print.ln("singular")
    | bad-dims |> std/io:print.ln("bad-dims")
| bad e |> std/io:print.ln("bad-lit")

// rectangular overdetermined with a kernel direction: cols of a 4x3
std/linalg:lit(s: "4x3: 1 0 1 0 1 1 1 1 2 2 1 3")
| exact m |> std/linalg:kernel(a: m)
    | exact x |> std/linalg:render(m: x): t |> std/io:print.ln("x={{ t:s }}") |> std/io:free(content: t)
    | singular |> std/io:print.ln("singular")
    | bad-dims |> std/io:print.ln("bad-dims")
| bad e |> std/io:print.ln("bad-lit")
