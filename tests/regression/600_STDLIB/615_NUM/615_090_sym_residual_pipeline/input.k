// The public discovery pipeline: derive-ode decomposed at tor boundaries.
// residual-sys emits the residual block as canon mats (z = solve rows,
// w = held-out witness rows); linalg:kernel solves the null space;
// mul+is-zero is the witness; cert-of-kernel emits the certificate.
// The composed pipeline must emit the identical certificate derive-ode
// produces internally.
import std/io
import std/sym
import std/linalg

// x/(1-x-x^2) — the Fibonacci generating function
std/sym:lit((x*inv((1e0+(-1e0*x)+(-1e0*x*x)))))
| exact a |> std/sym:residual-sys(a, order: 2, deg: 2)
    | exact r |> std/linalg:ingest-owned(s: r.z): ez |> std/linalg:ingest-owned(s: r.w): ew |> std/linalg:parse(s: ez)
        | exact zm |> std/linalg:parse(s: ew)
            | exact wm |> std/linalg:kernel(a: zm)
                | exact xm |> std/linalg:dup(m: xm): d |> std/linalg:mul(a: wm, b: d.a)
                    | exact wx |> std/linalg:is-zero(m: wx)
                        | zero |> std/linalg:free(m: wx) |> std/linalg:render(m: d.b): xt |> std/sym:cert-of-kernel(x: xt, order: 2, deg: 2, verified: 30)
                            | exact cert |> std/io:print.ln("cert={{ cert:s }}") |> std/io:free(content: cert) |> std/io:free(content: xt)
                            | bad |> std/io:print.ln("cert-bad") |> std/io:free(content: xt)
                        | nonzero |> std/io:print.ln("witness-fail") |> std/linalg:free(m: wx) |> std/linalg:free(m: d.b)
                    | dims |> std/io:print.ln("dims") |> std/linalg:free(m: d.b)
                | singular |> std/io:print.ln("singular") |> std/linalg:free(m: wm)
                | bad-dims |> std/io:print.ln("bad-dims") |> std/linalg:free(m: wm)
            | bad ewb |> std/io:print.ln("bad-w") |> std/io:free(content: ewb) |> std/linalg:free(m: zm)
        | bad ezb |> std/io:print.ln("bad-z") |> std/io:free(content: ezb) |> std/linalg:parse(s: ew)
            | exact x1 |> std/linalg:free(m: x1)
            | bad e2 |> std/io:free(content: e2)
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// contrast: derive-ode on the same expression — must emit identically.
std/sym:lit((x*inv((1e0+(-1e0*x)+(-1e0*x*x)))))
| exact a2 |> std/sym:derive-ode(a: a2, max-order: 2, max-deg: 2)
    | exact c |> std/io:print.ln("derive={{ c:s }}") |> std/io:free(content: c)
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// sqrt(1+x) through the composed pipeline — a second data point.
// 2(1+x) g' - g = 0 -> p0=[-1,0], p1=[2,2] over ints
std/sym:lit(√((1e0+x)))
| exact a3 |> std/sym:residual-sys(a: a3, order: 1, deg: 1)
    | exact r3 |> std/linalg:ingest-owned(s: r3.z): ez3 |> std/linalg:ingest-owned(s: r3.w): ew3 |> std/linalg:parse(s: ez3)
        | exact zm3 |> std/linalg:parse(s: ew3)
            | exact wm3 |> std/linalg:kernel(a: zm3)
                | exact xm3 |> std/linalg:dup(m: xm3): d3 |> std/linalg:mul(a: wm3, b: d3.a)
                    | exact wx3 |> std/linalg:is-zero(m: wx3)
                        | zero |> std/linalg:free(m: wx3) |> std/linalg:render(m: d3.b): xt3 |> std/sym:cert-of-kernel(x: xt3, order: 1, deg: 1, verified: 25)
                            | exact c3 |> std/io:print.ln("cert={{ c3:s }}") |> std/io:free(content: c3) |> std/io:free(content: xt3)
                            | bad |> std/io:print.ln("cert-bad") |> std/io:free(content: xt3)
                        | nonzero |> std/io:print.ln("witness-fail") |> std/linalg:free(m: wx3) |> std/linalg:free(m: d3.b)
                    | dims |> std/io:print.ln("dims") |> std/linalg:free(m: d3.b)
                | singular |> std/io:print.ln("singular") |> std/linalg:free(m: wm3)
                | bad-dims |> std/io:print.ln("bad-dims") |> std/linalg:free(m: wm3)
            | bad ewb3 |> std/io:print.ln("bad-w") |> std/io:free(content: ewb3) |> std/linalg:free(m: zm3)
        | bad ezb3 |> std/io:print.ln("bad-z") |> std/io:free(content: ezb3) |> std/linalg:parse(s: ew3)
            | exact x2 |> std/linalg:free(m: x2)
            | bad e3 |> std/io:free(content: e3)
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")
