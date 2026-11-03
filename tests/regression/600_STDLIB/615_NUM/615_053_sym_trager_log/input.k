import std/io
import std/sym

// B1: Rothstein-Trager log-part construction on the squarefree Hermite
// remainder. Each emitted antiderivative is checked exactly by summing the
// rational-function derivatives of all constructed terms before it is
// returned — checked-exact means d(result)/dx == integrand in Q(x).

// 1/(1+x) -> log(1+x), one rational residue
std/sym:lit(inv((1+x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(1+x^2) -> atan(x), negative-discriminant quadratic residue field
std/sym:lit(inv((1+x*x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/x -> log(x)
std/sym:lit(inv(x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/((x-1)(x-2)) -> log(x-2) - log(x-1), two rational residues
std/sym:lit(inv(((x-1)*(x-2))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x/(1+x^2) -> (1/2) log(1+x^2), rational residue on the x^2+1 factor
std/sym:lit(x*inv((1+x*x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(x^2-3) -> conjugate real-log pair in Q(sqrt(1/12))
std/sym:lit(inv((x*x-3)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(x^2+2x+2) -> atan(x+1), shifted negative-discriminant quadratic
std/sym:lit(inv((x*x+2*x+2)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(x^3+x) = 1/(x(x^2+1)) -> log(x) - (1/2) log(x^2+1), rational residues
std/sym:lit(inv((x*x*x+x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(x^3-2): residues live in a cubic extension, no algebraic-number
// layer yet -> elementary layer names the refusal, Hermite part preserved
std/sym:lit(inv((x*x*x-2)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// mixed Hermite+log: 1/(x(x+1)^2) -> 1/(x+1) + log(x) - log(x+1)
std/sym:lit(inv((x*(x+1)*(x+1))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 3)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// the new nodes differentiate: d log(1+x)/dx = 1/(1+x)
std/sym:lit(log((1+x)))
| exact s1 |> std/sym:deriv(a: s1): r |> std/io:print.ln("D:{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

// d atan(x)/dx = 1/(1+x^2)
std/sym:lit(atan(x))
| exact s2 |> std/sym:deriv(a: s2): r |> std/io:print.ln("D:{{ r:s }}") |> std/sym:free(n: r)
| bad |> std/io:print.ln("bad")

// log(0) stays a named norm error -> bad literal; log(-1) used to refuse
// LogNeg — post-B3a the principal complex branch answers i*pi
std/sym:lit(log(0))
| exact s3 |> std/io:print.ln("C:{{ s3:s }}") |> std/sym:free(n: s3)
| bad |> std/io:print.ln("bad-lit")

std/sym:lit(log((0-1)))
| exact s4 |> std/io:print.ln("C:{{ s4:s }}") |> std/sym:free(n: s4)
| bad |> std/io:print.ln("bad-lit")

// norm folds: log(1) -> 0, atan(0) -> 0, atan(1) stays a node
std/sym:lit(log(1))
| exact s5 |> std/io:print.ln("C:{{ s5:s }}") |> std/sym:free(n: s5)
| bad |> std/io:print.ln("bad-lit")

std/sym:lit(atan(0))
| exact s6 |> std/io:print.ln("C:{{ s6:s }}") |> std/sym:free(n: s6)
| bad |> std/io:print.ln("bad-lit")

// canonical serialization round-trips the new nodes
std/sym:lit(log(x))
| exact s7 |> std/io:print.ln("C:{{ s7:s }}") |> std/sym:free(n: s7)
| bad |> std/io:print.ln("bad-lit")

// atan(+-1) folds to +-(pi/4) — the sign rides the dec coefficient
std/sym:lit(atan(1))
| exact s8 |> std/io:print.ln("C:{{ s8:s }}") |> std/sym:free(n: s8)
| bad |> std/io:print.ln("bad-lit")

std/sym:lit(atan((0-1)))
| exact s9 |> std/io:print.ln("C:{{ s9:s }}") |> std/sym:free(n: s9)
| bad |> std/io:print.ln("bad-lit")
