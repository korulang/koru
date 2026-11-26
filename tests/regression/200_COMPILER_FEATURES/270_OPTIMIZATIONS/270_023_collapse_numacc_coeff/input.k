// PIN (collapse-recursion, C3 general leg): the num-custody recurrence
// generalizes to x_{i+1} = p*x_i + q*x_{i-1} — companion matrix
// [[0,1],[q,p]] fast-doubled over Dec, coefficients either carried as
// custody params (lrec: p,q are string<!exact> threaded through the
// recursion) or minted as literals (pelln: from-int + mul).
// lrec:  dup(b) -> dup(p) -> dup(q) -> mul -> mul -> add -> self-call,
//   pell(10) -> 2.378e3.
// pelln: dup(b) -> from-int -> mul -> add -> self-call (q=1 bare a term),
//   pell(12) -> 1.386e4.
import std/io
import std/num

pub tor lrec { m: i64, a: string<!std/num:exact>, b: string<!std/num:exact>, p: string<!std/num:exact>, q: string<!std/num:exact> } -> string<std/num:exact!>

lrec = if(m <= 0)
| then |> std/num:free(n: b) |> std/num:free(n: p) |> std/num:free(n: q) -> a
| else |> std/num:dup(n: b): d |> std/num:dup(n: p): dp |> std/num:dup(n: q): dq |> std/num:mul(d.b, dp.a): pb |> std/num:mul(dq.a, b: a): qa |> std/num:add(a: pb, b: qa): s |> lrec(m: m - 1, d.a, b: s, p: dp.b, q: dq.b): r -> r

pub tor pelln { m: i64, a: string<!std/num:exact>, b: string<!std/num:exact> } -> string<std/num:exact!>

pelln = if(m <= 0)
| then |> std/num:free(n: b) -> a
| else |> std/num:dup(n: b): d |> std/num:from-int(i: 2): two |> std/num:mul(d.b, a: two): pb |> std/num:add(a: pb, b: a): s |> pelln(m: m - 1, d.a, b: s): r -> r

std/num:from-int(i: 0): a0 |> std/num:from-int(i: 1): b0 |> std/num:from-int(i: 2): p0 |> std/num:from-int(i: 1): q0
|> lrec(m: 10, a: a0, b: b0, p: p0, q: q0): f
|> std/io:print.ln("{{ f:s }}") |> std/num:free(n: f)

std/num:from-int(i: 0): a1 |> std/num:from-int(i: 1): b1
|> pelln(m: 12, a: a1, b: b1): g
|> std/io:print.ln("{{ g:s }}") |> std/num:free(n: g)
