import std/io
import std/sym

// Chained alg ops on the cyclotomic ring: an alg-* tor's produced wire
// value must feed the next alg-* call (a/b/mod params accept <*>).
// Shape: rotation arithmetic mod x^2+1 — x^j is a quarter-turn, an
// arrow-sum is a polynomial = Gaussian integer; the butterfly emits
// e + z*o and e - z*o where the half-turn arrow x^2 is negation.
//
//   add a b      -> std/sym:alg-add          (concat the bags)
//   mul z b k    -> std/sym:alg-mul(b, x^z) + k   (rotate each arrow)
//   dbl a        -> std/sym:alg-add(a, a)
//   e + z*o      -> alg-add(e, alg-mul(o, x^z))   (the butterfly emit)

// the full turn is the identity arrow: x^4 == 1, proved not asserted
std/sym:alg-pow(a: "alg:v1;(1e0+(x*x));x", n: 4)
    | exact r |> std/io:print.ln("x^4      = {{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd")
    | bad |> std/io:print.ln("bad")

// add (1+x) (x+x^2) = 1 + 2x + x^2  ==  2x   (opposite arrows cancel —
// his bag keeps all four; the ring does the circle arithmetic for free)
std/sym:alg-add(a: "alg:v1;(1e0+(x*x));(1e0+x)", b: "alg:v1;(1e0+(x*x));(x+(x*x))")
    | exact r |> std/io:print.ln("add      = {{ r:s }}") |> std/io:free(content: r)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// mul z: rotate every arrow in (1+x) by the half-turn arrow x^2
std/sym:alg-mul(a: "alg:v1;(1e0+(x*x));(1e0+x)", b: "alg:v1;(1e0+(x*x));(x*x)")
    | exact r |> std/io:print.ln("mul x^2  = {{ r:s }}") |> std/io:free(content: r)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// the butterfly emit e + z*o,  e = 1+x, o = x, z = x:
//   z*o = x*x = x^2,  e + x^2 = 1 + x + (-1) = x — a single arrow out
std/sym:alg-mul(a: "alg:v1;(1e0+(x*x));x", b: "alg:v1;(1e0+(x*x));x")
    | exact wo |> std/sym:alg-add(a: "alg:v1;(1e0+(x*x));(1e0+x)", b: wo)
        | exact r |> std/io:print.ln("e+z*o    = {{ r:s }}") |> std/io:free(content: r) |> std/io:free(content: wo)
        | modulus-mismatch |> std/io:print.ln("mm") |> std/io:free(content: wo)
        | bad |> std/io:print.ln("bad") |> std/io:free(content: wo)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// and the half his encoding cannot spell: the second butterfly output
// e - z*o = e + x^2*(z*o).  x^3*x = x^4 = 1, so e - z*o = (1+x) + 1 = 2+x
std/sym:alg-mul(a: "alg:v1;(1e0+(x*x));((x*x)*x)", b: "alg:v1;(1e0+(x*x));x")
    | exact wo2 |> std/sym:alg-add(a: "alg:v1;(1e0+(x*x));(1e0+x)", b: wo2)
        | exact r |> std/io:print.ln("e-z*o    = {{ r:s }}") |> std/io:free(content: r) |> std/io:free(content: wo2)
        | modulus-mismatch |> std/io:print.ln("mm") |> std/io:free(content: wo2)
        | bad |> std/io:print.ln("bad") |> std/io:free(content: wo2)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")
