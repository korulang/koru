import std/io
import std/sym

// source blocks bind 'source: string' params by name: 'tor { ... }' hands
// the captured text to the runtime callee, the same transport Expression
// params use. rel-decls takes the whole registry in one block; rel-law
// takes one law per block. D(sin^2+cos^2) folds to 0e0 either way.
std/sym:rel-new()
|> std/sym:rel-decls { sin=g(cos); cos=(-1e0*g(sin)) }
    | exact |> std/sym:rel-derive { g(sin)*g(sin)+g(cos)*g(cos) }
        | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d)
        | unknown-generator |> std/io:print.ln("ug")
        | lawless |> std/io:print.ln("ll")
        | bad |> std/io:print.ln("bad-d")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad-s")

std/sym:rel-new()
|> std/sym:rel-seed(name: "f")
    | exact |> std/sym:rel-law(name: "f") { g(f, x+1e0) }
        | exact |> std/sym:rel-derive { g(f, x*x) }
            | exact d2 |> std/io:print.ln("{{ d2:s }}") |> std/io:free(content: d2)
            | unknown-generator |> std/io:print.ln("ug")
            | lawless |> std/io:print.ln("ll")
            | bad |> std/io:print.ln("bad-d2")
        | unknown-generator |> std/io:print.ln("ug")
        | bad |> std/io:print.ln("bad-l")
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | bad |> std/io:print.ln("bad-s")
