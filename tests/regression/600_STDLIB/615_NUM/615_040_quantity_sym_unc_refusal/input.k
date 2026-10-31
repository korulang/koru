// std/quantity: relative sigma over a symbolic magnitude would need
// |sym| — an evaluation rung that does not exist yet. mul/div/pow on a
// nonzero-uncertainty symbolic magnitude refuse by name: | sym-unc.
// Exact symbolic quantities (sigma 0) are unaffected. add/sub still
// carry sigma — their sigma math never inspects the magnitude.
import std/io
import std/num
import std/sym
import std/quantity

// (pi+-0.1 m) * (1 s) -> sym-unc
std/sym:lit(s: "π")
| exact s1 |> std/quantity:lit-sym(mag: s1, unit: "m", unc: "0.1", cov: "-")
    | exact qu |> std/sym:lit(s: "1e0")
        | exact t1 |> std/quantity:lit-sym(mag: t1, unit: "s", unc: "0", cov: "-")
            | exact qs |> std/quantity:mul(a: qu, b: qs)
                | exact r |> std/quantity:render(n: r): ta |> std/io:print.ln("{{ ta:s }}") |> std/io:free(content: ta)
                | mixed-cov |> std/io:print.ln("mixed-cov")
                | bad x |> std/io:print.ln("{{ x:s }}")
                | sym-unc |> std/io:print.ln("sym-unc")
            | bad-lit x |> std/io:print.ln("{{ x:s }}")
        | bad |> std/io:print.ln("bad-sym")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// (pi m) / (1+-0.1 s) -> sym-unc
std/sym:lit(s: "π")
| exact s2 |> std/quantity:lit-sym(mag: s2, unit: "m", unc: "0", cov: "-")
    | exact qd |> std/sym:lit(s: "1e0")
        | exact t2 |> std/quantity:lit-sym(mag: t2, unit: "s", unc: "0.1", cov: "-")
            | exact qe |> std/quantity:div(a: qd, b: qe, prec: 15)
                | exact r |> std/quantity:render(n: r): tb |> std/io:print.ln("{{ tb:s }}") |> std/io:free(content: tb)
                | div-zero |> std/io:print.ln("div-zero")
                | mixed-cov |> std/io:print.ln("mixed-cov")
                | bad x |> std/io:print.ln("{{ x:s }}")
                | sym-unc |> std/io:print.ln("sym-unc")
            | bad-lit x |> std/io:print.ln("{{ x:s }}")
        | bad |> std/io:print.ln("bad-sym")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// (pi+-0.1 m)^2 -> sym-unc
std/sym:lit(s: "π")
| exact s3 |> std/quantity:lit-sym(mag: s3, unit: "m", unc: "0.1", cov: "-")
    | exact qf |> std/quantity:pow(a: qf, n: 2)
        | exact r |> std/quantity:render(n: r): tc |> std/io:print.ln("{{ tc:s }}") |> std/io:free(content: tc)
        | div-zero |> std/io:print.ln("div-zero")
        | sym-unc |> std/io:print.ln("sym-unc")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// add carries sigma fine — (pi+-0.1 m)+(pi+-0.1 m) -> (2pi)+-0.2
std/sym:lit(s: "π")
| exact s4 |> std/quantity:lit-sym(mag: s4, unit: "m", unc: "0.1", cov: "-")
    | exact qa |> std/quantity:dup(n: qa): da |> std/quantity:add(da.a, da.b)
        | exact r |> std/quantity:render(n: r): td |> std/io:print.ln("{{ td:s }}") |> std/io:free(content: td)
        | dim-mismatch |> std/io:print.ln("dim-mismatch")
        | mixed-cov |> std/io:print.ln("mixed-cov")
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")

// and the decimal sigma lane still reads off a symbolic quantity
std/sym:lit(s: "π")
| exact s5 |> std/quantity:lit-sym(mag: s5, unit: "m", unc: "0.1", cov: "-")
    | exact qg |> std/quantity:unc(q: qg): u |> std/io:print.ln("{{ u:s }}") |> std/io:free(content: u)
    | bad-lit x |> std/io:print.ln("{{ x:s }}")
| bad |> std/io:print.ln("bad-sym")
