import std/io
import std/sym

// B5: exp-theta substitution lane.  An integrand rational in a single
// exponential element t = e^{g}, g = c0*x + b0 affine, reduces by
// dt = c0*t dx to the rational integral of F(t)/(c0*t), which re-enters
// the decider; the t-antiderivative substitutes x -> e^g node-wise and is
// re-verified exactly at the Frac level.  Every exp leaf must carry an
// integer multiple of one affine g0 (a Z-lattice on a common root);
// nonlinear arguments, multiple roots, bare-x factors, and nested exp
// name their own refusal arms.

// 1/(1+e^x) -> log(e^x) - log(1+e^x)  [= x - log(1+e^x)]
std/sym:lit((inv((1+exp(x)))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x/(1+e^x) -> log(1+e^x)
std/sym:lit((exp(x)*inv((1+exp(x)))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^{2x}/(1+e^x): lattice k=2 -> e^x - log(1+e^x)
std/sym:lit((exp((2*x))*inv((1+exp(x)))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(1+e^{2x+3}): affine arg with nonzero intercept
std/sym:lit((inv((1+exp(((2*x)+3))))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^{-x}/(1+e^{-x}): negative lattice index
std/sym:lit((exp((0-x))*inv((1+exp((0-x))))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^{x^2}/(1+e^x): nonlinear arg -> named refusal (not theta-rational)
std/sym:lit((exp((x*x))*inv((1+exp(x)))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// e^x/(e^{x+1}+1): arguments on different roots -> lattice refusal
std/sym:lit((exp(x)*inv((exp((x+1))+1))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x*e^x/(1+e^x): bare x factor -> not-rational-in-theta refusal
std/sym:lit((x*exp(x)*inv((1+exp(x)))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// exp(exp(x)): nested tower -> arg-nonpoly refusal
std/sym:lit((exp(exp(x))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")
