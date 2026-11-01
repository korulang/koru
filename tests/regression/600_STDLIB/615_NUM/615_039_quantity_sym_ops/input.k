// std/quantity: symbolic magnitudes — lit-sym packs a <std/sym:sexpr!>
// canon into the self-describing mag field; unpack routes it to the sym
// lane. Mixed decimal/symbolic operands promote via sym:of-dec, and the
// magnitude normal form cancels exactly where the decimal lane would
// approximate.
import std/io
import std/num
import std/sym
import std/quantity

// pi m + pi m -> (2e0*pi) m
std/sym:lit(π)
| exact s1 |> std/quantity:lit-sym(mag: s1, unit: "m", unc: "0", cov: "-")
    | exact q1 |> std/quantity:dup(n: q1): d1 |> std/quantity:add(d1.a, d1.b)
        | exact r |> std/quantity:render(n: r): t |> std/io:print.ln("{{ t:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// mixed lane: pi m + 2 m -> (2e0+pi) m (a numeric sexpr mag takes the
// dec lane on unpack, then promotes)
std/sym:lit(π)
| exact s2 |> std/quantity:lit-sym(mag: s2, unit: "m", unc: "0", cov: "-")
    | exact qp |> std/sym:lit(2e0)
        | exact t2 |> std/quantity:lit-sym(mag: t2, unit: "m", unc: "0", cov: "-")
            | exact qn |> std/quantity:add(a: qp, b: qn)
                | exact r |> std/quantity:render(n: r): ta |> std/io:print.ln("{{ ta:s }}")
                | dim-mismatch |> std/io:print.ln("dim-mismatch")
                | mixed-cov |> std/io:print.ln("mixed-cov")
            | bad-lit x |> std/io:print.ln("{{ x:s }}")
        | bad |> std/io:print.ln("bad-sym")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// sym mul composes dims: pi m * 2 s -> (2e0*pi) m*s
std/sym:lit(π)
| exact s3 |> std/quantity:lit-sym(mag: s3, unit: "m", unc: "0", cov: "-")
    | exact qm |> std/sym:lit(2e0)
        | exact t3 |> std/quantity:lit-sym(mag: t3, unit: "s", unc: "0", cov: "-")
            | exact qs |> std/quantity:mul(a: qm, b: qs)
                | exact r |> std/quantity:render(n: r): tb |> std/io:print.ln("{{ tb:s }}")
                | mixed-cov |> std/io:print.ln("mixed-cov")
                | bad x |> std/io:print.ln("{{ x:s }}")
                | sym-unc |> std/io:print.ln("sym-unc")
            | bad-lit x |> std/io:print.ln("{{ x:s }}")
        | bad |> std/io:print.ln("bad-sym")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// the headline: (1/3 m/s) * 3 s -> 1 m exactly — the decimal lane would
// carry 3.333e-1 and answer 0.9999...
std/sym:lit(1/3)
| exact s4 |> std/quantity:lit-sym(mag: s4, unit: "m/s", unc: "0", cov: "-")
    | exact qc |> std/sym:lit(3e0)
        | exact t4 |> std/quantity:lit-sym(mag: t4, unit: "s", unc: "0", cov: "-")
            | exact q3 |> std/quantity:mul(a: qc, b: q3)
                | exact r |> std/quantity:render(n: r): tc |> std/io:print.ln("{{ tc:s }}")
                | mixed-cov |> std/io:print.ln("mixed-cov")
                | bad x |> std/io:print.ln("{{ x:s }}")
                | sym-unc |> std/io:print.ln("sym-unc")
            | bad-lit x |> std/io:print.ln("{{ x:s }}")
        | bad |> std/io:print.ln("bad-sym")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// sym div: (pi m)/(pi s) -> 1 m/s — atom cancels
std/sym:lit(π)
| exact sa |> std/quantity:lit-sym(mag: sa, unit: "m", unc: "0", cov: "-")
    | exact qa |> std/sym:lit(π)
        | exact sb |> std/quantity:lit-sym(mag: sb, unit: "s", unc: "0", cov: "-")
            | exact qb |> std/quantity:div(a: qa, b: qb, prec: 15)
                | exact r |> std/quantity:render(n: r): td |> std/io:print.ln("{{ td:s }}")
                | div-zero |> std/io:print.ln("div-zero")
                | mixed-cov |> std/io:print.ln("mixed-cov")
                | bad x |> std/io:print.ln("{{ x:s }}")
                | sym-unc |> std/io:print.ln("sym-unc")
            | bad-lit x |> std/io:print.ln("{{ x:s }}")
        | bad |> std/io:print.ln("bad-sym")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// neg: -(pi m) -> (-1*pi) m
std/sym:lit(π)
| exact s5 |> std/quantity:lit-sym(mag: s5, unit: "m", unc: "0", cov: "-")
    | exact qn5 |> std/quantity:neg(n: qn5): ng |> std/quantity:render(n: ng): te |> std/io:print.ln("{{ te:s }}")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// pow: (pi m)^2 -> (pi*pi) m^2
std/sym:lit(π)
| exact s6 |> std/quantity:lit-sym(mag: s6, unit: "m", unc: "0", cov: "-")
    | exact qp6 |> std/quantity:pow(a: qp6, n: 2)
        | exact r |> std/quantity:render(n: r): tf |> std/io:print.ln("{{ tf:s }}")
        | div-zero |> std/io:print.ln("div-zero")
        | sym-unc |> std/io:print.ln("sym-unc")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// sigma on a sym mag still flows (add's sigma is decimal-only):
// (pi+-0.1@x) + (pi+-0.1@x) -> (2pi)+-0.2@x
std/sym:lit(π)
| exact s7 |> std/quantity:lit-sym(mag: s7, unit: "m", unc: "0.1", cov: "x")
    | exact qb |> std/quantity:dup(n: qb): db |> std/quantity:add(db.a, db.b)
        | exact r |> std/quantity:render(n: r): tg |> std/io:print.ln("{{ tg:s }}")
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// mag union: a symbolic magnitude unpacks on the | sym arm
std/sym:lit(π)
| exact s8 |> std/quantity:lit-sym(mag: s8, unit: "m", unc: "0", cov: "-")
    | exact q8 |> std/quantity:mag(q: q8)
        | num m |> std/io:print.ln("num-lane") |> std/num:free(n: m)
        | sym m |> std/sym:render(n: m): th |> std/io:print.ln("{{ th:s }}")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")
