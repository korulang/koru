// std/sym supgen — power-series coefficients over exact rationals and
// bounded holonomic ODE discovery (SupGen derive). The series of any
// expression in the grammar has rational coefficients; derive-ode
// enumerates (order,degree) within declared bounds, solves the series
// residual over Q, verifies on terms the solve never used, and emits a
// certificate — or names the refusal axis.
import std/io
import std/sym

// series of 1/(1-x) — geometric coefficients
std/sym:lit(inv((1e0+(-1e0*x))))
| exact a1 |> std/sym:series(a: a1, terms: 8)
    | exact s |> std/io:print.ln("{{ s:s }}")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// derive-ode of 1/(1-x): f = (1-x) f'
std/sym:lit(inv((1e0+(-1e0*x))))
| exact a2 |> std/sym:derive-ode(a: a2, max-order: 2, max-deg: 2)
    | exact c |> std/io:print.ln("{{ c:s }}")
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// series of sqrt(1+x) — binomial coefficients
std/sym:lit(√((1e0+x)))
| exact a3 |> std/sym:series(a: a3, terms: 8)
    | exact s |> std/io:print.ln("{{ s:s }}")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// derive-ode of sqrt(1+x): 2(1+x) f' = f
std/sym:lit(√((1e0+x)))
| exact a4 |> std/sym:derive-ode(a: a4, max-order: 2, max-deg: 2)
    | exact c |> std/io:print.ln("{{ c:s }}")
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// derive-ode of 1/(1+x^2): (1+x^2) f' + 2x f = 0
std/sym:lit(inv((1e0+x*x)))
| exact a5 |> std/sym:derive-ode(a: a5, max-order: 2, max-deg: 3)
    | exact c |> std/io:print.ln("{{ c:s }}")
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// pi is not a rational constant — series refuses | non-rational
std/sym:lit(π)
| exact a6 |> std/sym:series(a: a6, terms: 4)
    | exact s |> std/io:print.ln("{{ s:s }}")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// inv(x) has a pole at 0 — series refuses | non-analytic
std/sym:lit(inv(x))
| exact a7 |> std/sym:series(a: a7, terms: 4)
    | exact s |> std/io:print.ln("{{ s:s }}")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// order-0 bound on sqrt(1+x) finds nothing — | not-found within bounds
std/sym:lit(√((1e0+x)))
| exact a8 |> std/sym:derive-ode(a: a8, max-order: 0, max-deg: 3)
    | exact c |> std/io:print.ln("{{ c:s }}")
    | not-found |> std/io:print.ln("not-found")
    | non-analytic |> std/io:print.ln("non-analytic")
    | non-rational |> std/io:print.ln("non-rational")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")
