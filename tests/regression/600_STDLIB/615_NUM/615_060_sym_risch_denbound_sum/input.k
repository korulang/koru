import std/io
import std/sym

// B3c: the Rothstein denominator bound + the termwise sum lane.
//
// For F*exp(G) with den(F) nonconstant and G polynomial: a pole of order
// m in R appears at order m+1 in R' and at most m in G'R, so every pole
// of R satisfies nu_p(R) = nu_p(F) - 1.  A simple pole of F is therefore
// unreachable (proven non-elementary), and otherwise den R | gcd(d,d')
// reduces the DE to the polynomial equation D*T' + (G'D - D')T = F*D^2,
// solved by the same dominance argument (deg A >= deg D).
//
// The sum lane splits an .add integrand that no monomial lane caught,
// re-enters decide per term, and constructs the sum exactly when every
// term constructs; a refusing term names its verdict in the lane tag.

// e^x/x — simple pole -> proven non-elementary
std/sym:lit((exp(x)*inv(x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x/x^2 — D=x, T forced constant, degree check fails -> proven
std/sym:lit((exp(x)*inv((x*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x*(x-1)/x^2 -> e^x/x — constructed through the den-bound
std/sym:lit((exp(x)*((x+(-1e0))*inv((x*x)))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x*(x-1)^2/(x^2+1)^2 -> e^x/(x^2+1) — poles at ±i, no algebraic
// factoring needed: the squarefree tower works over Q alone
std/sym:lit((exp(x)*(((x+(-1e0))*(x+(-1e0)))*inv((((x*x)+1e0)*((x*x)+1e0))))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x/x^3 — D=x^2, degree argument fails -> proven
std/sym:lit((exp(x)*inv(((x*x)*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x + e^x -> x^2/2 + e^x (poly term + exp term)
std/sym:lit((x+exp(x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x + e^(-x) -> e^x - e^(-x) (two exp terms)
std/sym:lit((exp(x)+exp((-1e0*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x + e^x*(x-1)/x^2 -> x^2/2 + e^x/x (poly + den-bound term)
std/sym:lit((x+(exp(x)*((x+(-1e0))*inv((x*x))))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x + e^(x^2) — the e^(x^2) term proves non-elementary -> named tag + cert
std/sym:lit((x+exp((x*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// i*(x + e^x) -> const-split then sum -> i*(x^2/2 + e^x)
std/sym:lit((i*(x+exp(x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/x + x — the whole is rational; hermite+trager must still own it
std/sym:lit((inv(x)+x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")
