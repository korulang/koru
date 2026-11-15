import std/io
import std/sym

// Nonlinear jets pin: laws may be nonlinear in the generators
// (D(y)=y^2 Riccati), higher-order systems spell as auxiliary
// generators (y'=yp, yp'=-y is the harmonic oscillator), and a
// second jet feeds the derived canon text back through source —
// 'source: string<*>' borrows any qualification. Self-application
// g(f,g(f)) chains law-of-law mechanically.
std/sym:rel-new()
|> std/sym:rel-decls { y=g(y)*g(y) }
    | exact |> std/sym:rel-derive { g(y)*x }
        | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d)
        | unknown-generator |> std/io:print.ln("ug")
        | lawless |> std/io:print.ln("ll")
        | bad |> std/io:print.ln("bad-d")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")
std/sym:rel-new()
|> std/sym:rel-decls { y=g(y)*g(y) }
    | exact r |> std/sym:rel-derive(reg: r) { g(y) }
        | exact d |> std/sym:rel-derive(reg: r, source: d)
            | exact e |> std/io:print.ln("{{ e:s }}") |> std/io:free(content: e) |> std/io:free(content: d)
            | unknown-generator |> std/io:print.ln("ug")
            | lawless |> std/io:print.ln("ll")
            | bad |> std/io:print.ln("bad-e")
        | unknown-generator |> std/io:print.ln("ug")
        | lawless |> std/io:print.ln("ll")
        | bad |> std/io:print.ln("bad-d")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")
std/sym:rel-new()
|> std/sym:rel-decls {
      y=g(yp)
      yp=(-1e0*g(y))
   }
    | exact r |> std/sym:rel-derive(reg: r) { g(y) }
        | exact d |> std/sym:rel-derive(reg: r, source: d)
            | exact e |> std/io:print.ln("{{ e:s }}") |> std/io:free(content: e) |> std/io:free(content: d)
            | unknown-generator |> std/io:print.ln("ug")
            | lawless |> std/io:print.ln("ll")
            | bad |> std/io:print.ln("bad-e")
        | unknown-generator |> std/io:print.ln("ug")
        | lawless |> std/io:print.ln("ll")
        | bad |> std/io:print.ln("bad-d")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")
std/sym:rel-new()
|> std/sym:rel-decls { f=g(f)*g(f) }
    | exact |> std/sym:rel-derive { g(f,g(f)) }
        | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d)
        | unknown-generator |> std/io:print.ln("ug")
        | lawless |> std/io:print.ln("ll")
        | bad |> std/io:print.ln("bad-d")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")
