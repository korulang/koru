// collapse-recursion C3 numacc race — the SAME source, built twice:
// once with the pass firing (default), once with KORU_COLLAPSE_OFF=1.
// Two accumulator arms, each stepped n = 10,100,1000,10000,65536:
//   fibn — x_{i+1} = x_i + x_{i-1}        (bare a+b step, p=q=1)
//   lrec — x_{i+1} = p*x_i + q*x_{i-1}    (param-carried coefficients,
//                                        pell p=2 q=1)
// Uncollapsed every step pays dup + 2 decParse + decToString; collapsed
// parses once, fast-doubles the companion matrix on Dec limbs, formats
// once — time tracks the value's limb width, not n.
import std/io
import std/num
import std/time

pub tor fibn { n: i64, a: string<!std/num:exact>, b: string<!std/num:exact> } -> string<std/num:exact!>

fibn = if(n <= 0)
| then |> std/num:free(n: b) -> a
| else |> std/num:dup(n: b): d |> std/num:add(a, d.b): s |> fibn(n: n - 1, d.a, b: s): r -> r

pub tor lrec { m: i64, a: string<!std/num:exact>, b: string<!std/num:exact>, p: string<!std/num:exact>, q: string<!std/num:exact> } -> string<std/num:exact!>

lrec = if(m <= 0)
| then |> std/num:free(n: b) |> std/num:free(n: p) |> std/num:free(n: q) -> a
| else |> std/num:dup(n: b): d |> std/num:dup(n: p): dp |> std/num:dup(n: q): dq |> std/num:mul(d.b, dp.a): pb |> std/num:mul(dq.a, b: a): qa |> std/num:add(a: pb, b: qa): s |> lrec(m: m - 1, d.a, b: s, p: dp.b, q: dq.b): r -> r

pub tor nextn { x: i64, cap: i64 } -> i64
nextn = if(x * 10 <= cap)
| then -> x * 10
| else |> if(x < cap)
    | then -> cap
    | else -> cap + 1

pub tor gate { n: i64, cap: i64 }
| go { n: i64, cap: i64 }
| stop

gate = if(n <= cap)
| then => go { n, cap }
| else => stop

pub tor driver { cap: i64 }

driver = #L gate(n: 10, cap)
| go g |> std/time:now(): t0
    |> std/num:from-int(i: 0): a0
    |> std/num:from-int(i: 1): b0
    |> fibn(g.n, a: a0, b: b0): f
    |> std/time:elapsed(start: t0): e
    |> std/num:length(a: f): digs
    |> std/io:print.ln("fibn n={{ g.n:d }} digits={{ digs:d }} ms={{ e.ms:f }}")
    |> std/num:free(n: f)
    |> nextn(x: g.n, g.cap): nxt |> @L(n: nxt, g.cap)
| stop |> std/io:print.ln("--")
    |> #M gate(n: 10, cap)
    | go g |> std/time:now(): t0
        |> std/num:from-int(i: 0): a0
        |> std/num:from-int(i: 1): b0
        |> std/num:from-int(i: 2): p0
        |> std/num:from-int(i: 1): q0
        |> lrec(m: g.n, a: a0, b: b0, p: p0, q: q0): f
        |> std/time:elapsed(start: t0): e
        |> std/num:length(a: f): digs
        |> std/io:print.ln("lrec n={{ g.n:d }} digits={{ digs:d }} ms={{ e.ms:f }}")
        |> std/num:free(n: f)
        |> nextn(x: g.n, g.cap): nxt |> @M(n: nxt, g.cap)
    | stop |> std/io:print.ln("done")

driver(cap: 65536)
