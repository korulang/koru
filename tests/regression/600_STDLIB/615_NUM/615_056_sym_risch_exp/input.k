import std/io
import std/sym

// B3b: the Risch exp-monomial lane. For F*exp(G) with F rational and G
// polynomial the ansatz integral = R*exp(G) gives R' + G'R = F; a
// rational R is forced polynomial (a pole of order m in R appears at
// order m+1 in R' and cannot cancel), so deg R = deg F - deg G' and the
// coefficients solve top-down — null means proven non-elementary, and
// the integrand's order-1 holonomic certificate rides along either way.
// Constant factors (i, exp(2), ...) are split off and multiply the
// emitted antiderivative.
// exp(x) — bare monomial, F=1
std/sym:lit(exp(x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x*exp(x) -> (x-1)*exp(x), linear G
std/sym:lit((x*exp(x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x*exp(x^2) -> (1/2)*exp(x^2), quadratic G
std/sym:lit((x*exp((x*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// exp(x^2) — proven non-elementary (erf-class), cert attached
std/sym:lit(exp((x*x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// inv(exp(x)) norms to exp(-x) -> -exp(-x)
std/sym:lit(inv(exp(x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x^2*exp(3x) — coefficient recurrence through the DE
std/sym:lit(((x*x)*exp((3*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// exp(x)/x — rational-denominator DE: classified, cert attached
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

// exp(1/x) — non-rational integrand
std/sym:lit(exp(inv(x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// (1+x)*exp(x^3) — proven non-elementary by the degree argument
std/sym:lit(((1+x)*exp((x*x*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// i/x — constant factor split through the Trager lane
std/sym:lit(((i)*inv(x)))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// i*x — constant factor through the polynomial lane
std/sym:lit(((i)*x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// exp(2)*x — constant exp factor multiplies the antiderivative
std/sym:lit((exp(2)*x))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// i — pure-constant integrand -> i*x
std/sym:lit((i))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x^3*exp(x^2) -> (x^2/2 - 1/2)*exp(x^2), residual equations engaged
std/sym:lit(((x*x*x)*exp((x*x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 5)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")
