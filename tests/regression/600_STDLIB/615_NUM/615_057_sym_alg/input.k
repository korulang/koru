import std/io
import std/sym

// C1: algebraic numbers as Q[x]/(p) residue classes — canon
// alg:v1;<p>;<v> with p monic and deg v < deg p. The ring laws are exact
// polynomial remainder arithmetic; the modulus is embedded per value so
// mixed-modulus arithmetic refuses |modulus-mismatch, and a non-unit
// element refuses |zero-divisor carrying the gcd factor (Q[x]/(p) is a
// ring, not automatically a field — that is the honest name).

// alg-mod: x^2 - 2 -> monic canon
std/sym:lit((x*x+(-2e0)))
| exact p |> std/sym:alg-mod(p)
    | exact m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | bad |> std/io:print.ln("bad-mod")
| bad |> std/io:print.ln("bad-lit")

// sqrt(2) literal: x mod (x^2-2)
std/sym:lit(x)
| exact v |> std/sym:alg-lit(mod: "algm:v1;(-2e0+(x*x))", v)
    | exact a |> std/io:print.ln("{{ a:s }}") |> std/io:free(content: a)
    | bad |> std/io:print.ln("bad-lit2")
| bad |> std/io:print.ln("bad-lit0")

// x^3 mod (x^2-2) = 2x — reduction on entry
std/sym:lit((x*x*x))
| exact v |> std/sym:alg-lit(mod: "algm:v1;(-2e0+(x*x))", v)
    | exact a |> std/io:print.ln("{{ a:s }}") |> std/io:free(content: a)
    | bad |> std/io:print.ln("bad-lit3")
| bad |> std/io:print.ln("bad-lit0")
// t*t = 2 in Q(sqrt(2))
std/sym:alg-mul(a: "alg:v1;(-2e0+(x*x));x", b: "alg:v1;(-2e0+(x*x));x")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// (1+t)*(1-t) = -1
std/sym:alg-mul(a: "alg:v1;(-2e0+(x*x));(1e0+x)", b: "alg:v1;(-2e0+(x*x));(1e0+(-1e0*x))")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// inv(t) = t/2
std/sym:alg-inv(a: "alg:v1;(-2e0+(x*x));x")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd:{{ z:s }}") |> std/io:free(content: z)
    | bad |> std/io:print.ln("bad")

// inv(1+t) = -1+t
std/sym:alg-inv(a: "alg:v1;(-2e0+(x*x));(1e0+x)")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd:{{ z:s }}") |> std/io:free(content: z)
    | bad |> std/io:print.ln("bad")

// inv(x-1) in Q[x]/(x^2-1): gcd = x-1, named zero divisor
std/sym:alg-inv(a: "alg:v1;(-1e0+(x*x));(-1e0+x)")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd:{{ z:s }}") |> std/io:free(content: z)
    | bad |> std/io:print.ln("bad")

// Q(sqrt(2)) elt + Q(sqrt(3)) elt refuses
std/sym:alg-add(a: "alg:v1;(-2e0+(x*x));x", b: "alg:v1;(-3e0+(x*x));x")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// t^4 = 4
std/sym:alg-pow(a: "alg:v1;(-2e0+(x*x));x", n: 4)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd:{{ z:s }}") |> std/io:free(content: z)
    | bad |> std/io:print.ln("bad")

// t^-1 = t/2 — negative exponent through the inverse
std/sym:alg-pow(a: "alg:v1;(-2e0+(x*x));x", n: -1)
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd:{{ z:s }}") |> std/io:free(content: z)
    | bad |> std/io:print.ln("bad")

// (1+t)/t = 1 + t/2
std/sym:alg-div(a: "alg:v1;(-2e0+(x*x));(1e0+x)", b: "alg:v1;(-2e0+(x*x));x")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/io:free(content: r)
    | zero-divisor z |> std/io:print.ln("zd:{{ z:s }}") |> std/io:free(content: z)
    | modulus-mismatch |> std/io:print.ln("mm")
    | bad |> std/io:print.ln("bad")

// constant modulus -> bad (the zero ring is refused, not normalized)
std/sym:lit(2e0)
| exact p |> std/sym:alg-mod(p)
    | exact m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | bad |> std/io:print.ln("bad-mod-const")
| bad |> std/io:print.ln("bad-lit")

// non-poly modulus -> bad
std/sym:lit(exp(x))
| exact p |> std/sym:alg-mod(p)
    | exact m |> std/io:print.ln("{{ m:s }}") |> std/io:free(content: m)
    | bad |> std/io:print.ln("bad-mod-nonpoly")
| bad |> std/io:print.ln("bad-lit")
