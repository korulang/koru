import std/io
import std/sym

// rel band 1: declared generators with derivative laws.
// Conservation: D(sin^2+cos^2) = 0 mechanically under sin'=cos, cos'=-sin.
std/sym:rel-new(): r0
|> std/sym:rel-seed(name: sin, reg: r0)
    | exact r1 |> std/sym:rel-seed(name: cos, reg: r1)
        | exact r2 |> std/sym:rel-law(name: sin, reg: r2) { g(cos) }
            | exact r3 |> std/sym:rel-law(name: cos, reg: r3) { -1e0*g(sin) }
                | exact r4 |> std/sym:rel-derive(reg: r4) { g(sin)*g(sin)+g(cos)*g(cos) }
                    | exact d |> std/io:print.ln("{{ d:s }}")
                        |> std/sym:rel-norm(reg: r4) { g(sin)*g(cos)+g(cos)*g(sin) }
                            | exact n |> std/io:print.ln("{{ n:s }}")
                                |> std/sym:rel-derive(reg: r4) { g(ln) }
                                    | exact d2 |> std/io:print.ln("{{ d2:s }}")
                                        |> std/io:print.ln("{{ r4:s }}")
                                    | unknown-generator |> std/io:print.ln("ug") |> std/io:print.ln("{{ r4:s }}")
                                    | lawless |> std/io:print.ln("ll-d")
                                    | bad |> std/io:print.ln("bad-d2")
                            | unknown-generator |> std/io:print.ln("ug-n")
                            | bad |> std/io:print.ln("bad-n")
                    | unknown-generator |> std/io:print.ln("ug-d")
                    | lawless |> std/io:print.ln("ll-d1")
                    | bad |> std/io:print.ln("bad-d")
                | unknown-generator |> std/io:print.ln("ug-law2")
                | bad |> std/io:print.ln("bad-law2")
            | unknown-generator |> std/io:print.ln("ug-law1")
            | bad |> std/io:print.ln("bad-law1")
        | dup |> std/io:print.ln("dup2")
        | full |> std/io:print.ln("full2")
        | bad |> std/io:print.ln("bad-s2")
    | dup |> std/io:print.ln("dup1")
    | full |> std/io:print.ln("full1")
    | bad |> std/io:print.ln("bad-s1")

// exp self-law + product rule; then lawless + dup refusals.
std/sym:rel-new(): q0
|> std/sym:rel-seed(name: exp, reg: q0)
    | exact q1 |> std/sym:rel-law(name: exp, reg: q1) { g(exp) }
        | exact q2 |> std/sym:rel-derive(reg: q2) { g(exp)*x }
            | exact d |> std/io:print.ln("{{ d:s }}")
                |> std/sym:rel-seed(name: f, reg: q2)
                    | exact q3 |> std/sym:rel-derive(reg: q3) { g(f) }
                        | exact d3 |> std/io:print.ln("{{ d3:s }}")
                        | unknown-generator |> std/io:print.ln("ug-f")
                        | lawless |> std/io:print.ln("ll-f")
                        | bad |> std/io:print.ln("bad-f")
                    | dup |> std/io:print.ln("dup-f")
                    | full |> std/io:print.ln("full-f")
                    | bad |> std/io:print.ln("bad-sf")
            | unknown-generator |> std/io:print.ln("ug-e")
            | lawless |> std/io:print.ln("ll-e")
            | bad |> std/io:print.ln("bad-e")
        | unknown-generator |> std/io:print.ln("ug-e1")
        | bad |> std/io:print.ln("bad-e1")
    | dup |> std/io:print.ln("dup-e")
    | full |> std/io:print.ln("full-e")
    | bad |> std/io:print.ln("bad-es")

// dup refusal on re-seed.
std/sym:rel-new(): p0
|> std/sym:rel-seed(name: a, reg: p0)
    | exact p1 |> std/sym:rel-seed(name: a, reg: p1)
        | exact p2 |> std/io:print.ln("no-dup")
        | dup |> std/io:print.ln("dup-ok")
        | full |> std/io:print.ln("full-p")
        | bad |> std/io:print.ln("bad-p")
    | dup |> std/io:print.ln("dup-p0")
    | full |> std/io:print.ln("full-p0")
    | bad |> std/io:print.ln("bad-p0")
