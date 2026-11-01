import std/io
import std/sym

// Hermite reduction: a rational integrand's whole rational part is
// constructed and checked exactly (Q + (B/D-)' + C/D* == N/D). A nonzero
// squarefree remainder is the log part, named rather than built.

// x/(1+x^2)^2 -> -1/(2(1+x^2)), no log part
std/sym:lit(x*inv((1+x*x)*(1+x*x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 4)
    | elementary m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unresolved m |> std/io:print.ln("un:{{ m:s }}")
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}")
    | non-rational |> std/io:print.ln("non-rational")
    | non-analytic |> std/io:print.ln("non-analytic")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-literal")

// non-monic denominator: 1/(2x+2)^2 -> -1/(4(x+1))
std/sym:lit(inv((2*x+2)*(2*x+2)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unresolved m |> std/io:print.ln("un:{{ m:s }}")
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}")
    | non-rational |> std/io:print.ln("non-rational")
    | non-analytic |> std/io:print.ln("non-analytic")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-literal")

// mixed: (x+1)/x^2 -> rational part -1/x, log part 1/x
std/sym:lit((x+1)*inv(x*x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unresolved m |> std/io:print.ln("un:{{ m:s }}")
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}")
    | non-rational |> std/io:print.ln("non-rational")
    | non-analytic |> std/io:print.ln("non-analytic")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-literal")

// polynomial part plus a cubic pole: (x^4+1)/x^3 = x + x^-3 -> x^2/2 - 1/(2x^2), no log part
std/sym:lit((x*x*x*x+1)*inv(x*x*x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unresolved m |> std/io:print.ln("un:{{ m:s }}")
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}")
    | non-rational |> std/io:print.ln("non-rational")
    | non-analytic |> std/io:print.ln("non-analytic")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-literal")

// Kovacic soundness: y'' = (x^2+1) y has y = exp(x^2/2) — case 1 open,
// so no proof of non-Liouvillian may be issued
std/sym:lit(x*x+1)
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("liouvillian:{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("unclassifiable:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// y'' = 2/x^2 y has y = x^2 — a double pole leaves all three cases open
std/sym:lit(2*inv(x*x))
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("liouvillian:{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("unclassifiable:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")

// y'' = x^3 y: odd order -3 at infinity, no poles -> all cases fail, proven
std/sym:lit(x*x*x)
| exact r |> std/sym:decide-ode(r)
    | liouvillian m |> std/io:print.ln("liouvillian:{{ m:s }}")
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}")
    | unclassifiable m |> std/io:print.ln("unclassifiable:{{ m:s }}")
    | bad m |> std/io:print.ln("bad:{{ m:s }}")
| bad |> std/io:print.ln("bad-literal")
