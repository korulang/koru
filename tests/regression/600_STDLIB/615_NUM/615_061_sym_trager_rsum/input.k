import std/io
import std/sym

// B4: residue cofactors of degree >= 3 — the algebraic-coefficient
// Rothstein-Trager lane.  The K[x] gcd runs over K = Q[t]/(f) through
// std/sym.alg's residue-ring arithmetic; a non-invertible leading
// coefficient names a modulus factor (Davenport-Trager) and the lane
// splits there, so every constructed component is a field.  The emitted
// node is the root-sum
//   rsum(f ; s0|s1|...) = sum_{f(alpha)=0} alpha * log S(x, alpha)
// and the exact check keeps checked-exact without algebraic numerics:
//   sum_alpha alpha * dS/S = Tr_K(t * dS * Q) / Norm(S),
//   Norm(S) = Res_t(S,f) in Q[x],  Q = Norm/S in K[x],
// the element trace read off the Newton power sums of f.

// 1/(x^3-2): irreducible cubic residue factor -> one rsum
std/sym:lit((inv((x*x*x-2))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(x^4+1): irreducible quartic residue factor -> rsum (256t^4+1)
std/sym:lit((inv((x*x*x*x+1))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// x^2/(x^4+1): same modulus, different numerator and S
std/sym:lit((x*x*inv((x*x*x*x+1))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/((x^2-2)(x^2-3)): squarefree-but-reducible residue factor — no zero
// divisor arose, and one rsum over the product ring is still exact
// (trace splits over components; the derivative check verifies it)
std/sym:lit((inv((x*x-2)*(x*x-3))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// 1/(x^2-2) + 1/(x^4+1): quadratic log lane and rsum in one integrand
std/sym:lit((inv((x*x-2))+inv((x*x*x*x+1))))
| exact a |> std/sym:decide-integral(a, max-order: 3, max-deg: 6)
    | elementary m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | holonomic-special m |> std/io:print.ln("hs:{{ m:s }}") |> std/io:free(content: m)
    | unresolved m |> std/io:print.ln("un:{{ m:s }}") |> std/io:free(content: m)
    | not-holonomic m |> std/io:print.ln("nh:{{ m:s }}") |> std/io:free(content: m)
    | non-rational |> std/io:print.ln("nr")
    | non-analytic |> std/io:print.ln("na")
    | bad |> std/io:print.ln("bad")
| bad |> std/io:print.ln("bad-lit")

// malformed rsum payload (empty section) refuses at parse
std/sym:lit((rsum(1,0,1;;0,1)))
| exact a |> std/io:print.ln("lit:{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad-rsum")

// a canonical rsum round-trips through lit
std/sym:lit((rsum(-1/108,0,0,1;0,-6|1)))
| exact a |> std/io:print.ln("lit:{{ a:s }}") |> std/sym:free(n: a)
| bad |> std/io:print.ln("bad-rsum2")
