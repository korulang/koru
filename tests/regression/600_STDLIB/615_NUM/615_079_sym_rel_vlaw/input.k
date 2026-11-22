import std/io
import std/sym

// value-laws: `name=(lhs=rhs)` and bare `(lhs=rhs)` entries. The label is
// advisory — it never interns a generator atom, so g(pythag) must refuse
// unknown-generator. Emitted registries re-parse byte-identically; each
// side canonicalizes independently (nested parens survive the walk).
std/sym:rel-new(): r0
|> std/sym:rel-decls {
      sin=g(cos)
      cos=(-1e0*g(sin))
      exp=g(exp)
      pythag=(g(sin)*(g(sin))+g(cos)*g(cos)=1e0)
      (g(exp)=g(exp))
   }
    | exact r1 |> std/io:print.ln("{{ r1:s }}")
        |> std/sym:rel-new(): q0
        |> std/sym:rel-decls(reg: q0, source: r1)
            | exact q1 |> std/io:print.ln("{{ q1:s }}")
                |> std/sym:rel-derive(reg: q1, source: "g(pythag)")
                    | exact d |> std/io:print.ln("resolved {{ d:s }}")
                    | unknown-generator |> std/io:print.ln("ug")
                    | lawless |> std/io:print.ln("ll")
                    | bad |> std/io:print.ln("bad-d")
            | bad |> std/io:print.ln("bad-rp")
            | dup |> std/io:print.ln("dup-rp")
            | full |> std/io:print.ln("full-rp")
            | unknown-generator |> std/io:print.ln("ug-rp")
    | bad |> std/io:print.ln("bad-1")
    | dup |> std/io:print.ln("dup-1")
    | full |> std/io:print.ln("full-1")
    | unknown-generator |> std/io:print.ln("ug-1")

// a value-law label may not collide with a generator name, or repeat.
std/sym:rel-new(): d0
|> std/sym:rel-decls(reg: d0, source: "f=;f=(g(x)=g(x))")
    | exact dr |> std/io:print.ln("bad-dup")
    | bad |> std/io:print.ln("bad")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug-d")

// an eq side that fails to parse is `bad`, not a silent generator law.
std/sym:rel-new(): m0
|> std/sym:rel-decls(reg: m0, source: "foo=(x=)")
    | exact mr |> std/io:print.ln("bad-missed")
    | bad |> std/io:print.ln("bad")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug-m")
