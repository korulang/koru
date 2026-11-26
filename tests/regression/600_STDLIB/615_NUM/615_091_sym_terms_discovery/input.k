// Discovery FROM numbers — the inverse direction. series emits
// coefficients; residual-sys-of-terms builds the residual block from
// them (it never needed the expression, only the array); the same
// kernel/witness/cert pipeline then discovers the law. | too-few-terms
// names the bound when terms < U+K+21 — the witness rows must be real
// coefficients, not zero-padded lies.
import std/io
import std/sym
import std/linalg

std/sym:lit((x*inv((1e0+(-1e0*x)+(-1e0*x*x)))))
| exact a |> std/sym:series(a, terms: 40)
    | exact s |> std/sym:residual-sys-of-terms(terms: s, order: 2, deg: 2)
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
        | too-few-terms |> std/io:print.ln("too-few-terms")
        | bad |> std/io:print.ln("bad")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// too few terms for (2,2): need U+K+21 = 32
std/sym:lit((x*inv((1e0+(-1e0*x)+(-1e0*x*x)))))
| exact a2 |> std/sym:series(a: a2, terms: 10)
    | exact s2 |> std/sym:residual-sys-of-terms(terms: s2, order: 2, deg: 2)
        | exact r2 |> std/io:print.ln("should-not-print") |> std/io:free(content: r2.z) |> std/io:free(content: r2.w)
        | too-few-terms |> std/io:print.ln("too-few-terms")
        | bad |> std/io:print.ln("bad")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// contrast: derive-ode on the expression — must emit identically.
std/sym:lit((x*inv((1e0+(-1e0*x)+(-1e0*x*x)))))
| exact a3 |> std/sym:derive-ode(a: a3, max-order: 2, max-deg: 2)
    | exact c3 |> std/io:print.ln("derive={{ c3:s }}") |> std/io:free(content: c3)
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")
