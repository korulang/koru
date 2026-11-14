import std/io
import std/sym

// rel band 2: explicit application g(name, arg). The chain rule substitutes
// the declared law at the argument — D g(f,u) = law_f[x:=u] * u' — and
// g(name) is g(name, x): both spellings normalize to the same atom.
std/sym:rel-new(): r0
|> std/sym:rel-decls(reg: r0, source: "exp=g(exp)")
    | exact r |> std/sym:rel-derive(reg: r, source: "g(exp,x+x)")
        | exact d1 |> std/io:print.ln("{{ d1:s }}") |> std/io:free(content: d1)
            |> std/sym:rel-derive(reg: r, source: "g(exp,x*x)")
                | exact d2 |> std/io:print.ln("{{ d2:s }}") |> std/io:free(content: d2)
                    |> std/sym:rel-derive(reg: r, source: "g(exp,g(exp))")
                        | exact d3 |> std/io:print.ln("{{ d3:s }}") |> std/io:free(content: d3)
                            |> std/sym:rel-derive(reg: r, source: "g(exp,2e0)")
                                | exact d4 |> std/io:print.ln("{{ d4:s }}") |> std/io:free(content: d4)
                                    |> std/sym:rel-norm(reg: r, source: "g(exp,x)")
                                        | exact n |> std/io:print.ln("{{ n:s }}") |> std/io:free(content: n) |> std/io:free(content: r)
                                        | unknown-generator |> std/io:print.ln("ug-n") |> std/io:free(content: r)
                                        | bad |> std/io:print.ln("bad-n") |> std/io:free(content: r)
                                | unknown-generator |> std/io:print.ln("ug-d4") |> std/io:free(content: r)
                                | lawless |> std/io:print.ln("ll-d4") |> std/io:free(content: r)
                                | bad |> std/io:print.ln("bad-d4") |> std/io:free(content: r)
                        | unknown-generator |> std/io:print.ln("ug-d3") |> std/io:free(content: r)
                        | lawless |> std/io:print.ln("ll-d3") |> std/io:free(content: r)
                        | bad |> std/io:print.ln("bad-d3") |> std/io:free(content: r)
                | unknown-generator |> std/io:print.ln("ug-d2") |> std/io:free(content: r)
                | lawless |> std/io:print.ln("ll-d2") |> std/io:free(content: r)
                | bad |> std/io:print.ln("bad-d2") |> std/io:free(content: r)
        | unknown-generator |> std/io:print.ln("ug-d1") |> std/io:free(content: r)
        | lawless |> std/io:print.ln("ll-d1") |> std/io:free(content: r)
        | bad |> std/io:print.ln("bad-d1") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug-decls")
    | bad |> std/io:print.ln("bad-decls")

// Shift-law: f' = f(x+1) is a valid declared law now that arguments exist —
// application inside a law is the same substitution machinery.
std/sym:rel-new(): s0
|> std/sym:rel-decls(reg: s0, source: "f=g(f,x+1e0)")
    | exact s |> std/sym:rel-derive(reg: s, source: "g(f)")
        | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d)
            |> std/sym:rel-derive(reg: s, source: "g(f,x*x)")
                | exact d2 |> std/io:print.ln("{{ d2:s }}") |> std/io:free(content: d2) |> std/io:free(content: s)
                | unknown-generator |> std/io:print.ln("ug-s2") |> std/io:free(content: s)
                | lawless |> std/io:print.ln("ll-s2") |> std/io:free(content: s)
                | bad |> std/io:print.ln("bad-s2") |> std/io:free(content: s)
        | unknown-generator |> std/io:print.ln("ug-s") |> std/io:free(content: s)
        | lawless |> std/io:print.ln("ll-s") |> std/io:free(content: s)
        | bad |> std/io:print.ln("bad-s") |> std/io:free(content: s)
    | dup |> std/io:print.ln("dup-s")
    | full |> std/io:print.ln("full-s")
    | unknown-generator |> std/io:print.ln("ug-ds")
    | bad |> std/io:print.ln("bad-ds")

// Applied arguments keep the same refusal arms.
std/sym:rel-new(): t0
|> std/sym:rel-decls(reg: t0, source: "h=")
    | exact t |> std/sym:rel-derive(reg: t, source: "g(h,x+x)")
        | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d) |> std/io:free(content: t)
        | unknown-generator |> std/io:print.ln("ug-t") |> std/io:free(content: t)
        | lawless |> std/io:print.ln("ll-t") |> std/io:free(content: t)
        | bad |> std/io:print.ln("bad-t") |> std/io:free(content: t)
    | dup |> std/io:print.ln("dup-t")
    | full |> std/io:print.ln("full-t")
    | unknown-generator |> std/io:print.ln("ug-dt")
    | bad |> std/io:print.ln("bad-dt")

std/sym:rel-new(): u0
|> std/sym:rel-derive(reg: u0, source: "g(bogus,x)")
    | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d) |> std/io:free(content: u0)
    | unknown-generator |> std/io:print.ln("ug-u") |> std/io:free(content: u0)
    | lawless |> std/io:print.ln("ll-u") |> std/io:free(content: u0)
    | bad |> std/io:print.ln("bad-u") |> std/io:free(content: u0)
