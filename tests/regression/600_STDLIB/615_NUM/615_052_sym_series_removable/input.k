import std/io
import std/sym

// Series work in exact Laurent form: cancellation shrinks the known prefix
// instead of inventing zeros, so removable singularities divide out and
// only a pole or a branch point that survives refuses.

// Catalan generating function (1 - sqrt(1-4x)) / (2x): removable at 0
std/sym:lit((1+(-1*√(1+(-4*x))))*inv(2*x))
| exact a |> std/sym:series(a, terms: 10)
    | exact s |> std/io:print.ln("catalan series: {{ s:s }}")
    | non-analytic |> std/io:print.ln("catalan series: non-analytic")
    | non-rational |> std/io:print.ln("catalan series: non-rational")
    | bad |> std/io:print.ln("catalan series: bad")
| bad |> std/io:print.ln("bad-literal")

std/sym:lit((1+(-1*√(1+(-4*x))))*inv(2*x))
| exact a |> std/sym:derive-ode(a, max-order: 2, max-deg: 2)
    | exact c |> std/io:print.ln("catalan ode: {{ c:s }}")
        |> std/sym:cert-bridge(c)
            | exact r |> std/io:print.ln("catalan recurrence: {{ r:s }}")
            | bad-cert m |> std/io:print.ln("catalan recurrence: bad-cert {{ m:s }}")
    | not-found |> std/io:print.ln("catalan ode: not-found")
    | non-analytic |> std/io:print.ln("catalan ode: non-analytic")
    | non-rational |> std/io:print.ln("catalan ode: non-rational")
    | bad |> std/io:print.ln("catalan ode: bad")
| bad |> std/io:print.ln("bad-literal")

// a genuine pole still refuses
std/sym:lit(inv(x))
| exact a |> std/sym:series(a, terms: 4)
    | exact s |> std/io:print.ln("1/x series: {{ s:s }}")
    | non-analytic |> std/io:print.ln("1/x series: non-analytic")
    | non-rational |> std/io:print.ln("1/x series: non-rational")
    | bad |> std/io:print.ln("1/x series: bad")
| bad |> std/io:print.ln("bad-literal")

// (sqrt(1+x) - 1)/x: removable, -> 1/2 - x/8 + ...
std/sym:lit((√(1+x)+(-1))*inv(x))
| exact a |> std/sym:series(a, terms: 5)
    | exact s |> std/io:print.ln("(sqrt(1+x)-1)/x: {{ s:s }}")
    | non-analytic |> std/io:print.ln("(sqrt(1+x)-1)/x: non-analytic")
    | non-rational |> std/io:print.ln("(sqrt(1+x)-1)/x: non-rational")
    | bad |> std/io:print.ln("(sqrt(1+x)-1)/x: bad")
| bad |> std/io:print.ln("bad-literal")

// sqrt(x^2) = |x|: not analytic at 0 on the real lane, refuses
std/sym:lit(√(x*x))
| exact a |> std/sym:series(a, terms: 4)
    | exact s |> std/io:print.ln("sqrt(x^2): {{ s:s }}")
    | non-analytic |> std/io:print.ln("sqrt(x^2): non-analytic")
    | non-rational |> std/io:print.ln("sqrt(x^2): non-rational")
    | bad |> std/io:print.ln("sqrt(x^2): bad")
| bad |> std/io:print.ln("bad-literal")

// sqrt(x): branch point, refuses
std/sym:lit(√(x))
| exact a |> std/sym:series(a, terms: 4)
    | exact s |> std/io:print.ln("sqrt(x): {{ s:s }}")
    | non-analytic |> std/io:print.ln("sqrt(x): non-analytic")
    | non-rational |> std/io:print.ln("sqrt(x): non-rational")
    | bad |> std/io:print.ln("sqrt(x): bad")
| bad |> std/io:print.ln("bad-literal")

// sqrt(x^4 (1+x)) = x^2 sqrt(1+x): valuation 4, analytic
std/sym:lit(√(x*x*x*x*(1+x)))
| exact a |> std/sym:series(a, terms: 5)
    | exact s |> std/io:print.ln("sqrt(x^4(1+x)): {{ s:s }}")
    | non-analytic |> std/io:print.ln("sqrt(x^4(1+x)): non-analytic")
    | non-rational |> std/io:print.ln("sqrt(x^4(1+x)): non-rational")
    | bad |> std/io:print.ln("sqrt(x^4(1+x)): bad")
| bad |> std/io:print.ln("bad-literal")
