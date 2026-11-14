// std/sym: rel-decls — a whole declaration block in one call. src is the
// rel:v1 tail grammar (name or name=law entries, semicolon-separated,
// optional prefix), names seed before laws attach (two-phase, cyclics
// resolve), and any refusal voids the entire block.
import std/io
import std/sym

// the sin/cos cyclic pair as one block — identical registry to the
// threaded seed/law path
std/sym:rel-new(): r0
|> std/sym:rel-decls(reg: r0, src: "sin=g(cos);cos=(-1e0*g(sin))")
    | exact r |> std/io:print.ln("{{ r:s }}") |> std/sym:rel-derive(reg: r, a: "g(sin)*g(sin)+g(cos)*g(cos)")
        | exact d |> std/io:print.ln("{{ d:s }}") |> std/io:free(content: d) |> std/io:free(content: r)
        | unknown-generator |> std/io:print.ln("d:ug") |> std/io:free(content: r)
        | lawless |> std/io:print.ln("d:lawless") |> std/io:free(content: r)
        | bad |> std/io:print.ln("d:bad") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")

// merge: rel:v1-prefixed registry text composes — the block grammar
// and the emitted format are the same language
std/sym:rel-new(): q0
|> std/sym:rel-decls(reg: q0, src: "exp=g(exp)")
    | exact q |> std/sym:rel-decls(reg: q, src: "rel:v1;f=")
        | exact q2 |> std/io:print.ln("{{ q2:s }}") |> std/io:free(content: q2)
        | dup |> std/io:print.ln("m:dup")
        | full |> std/io:print.ln("m:full")
        | unknown-generator |> std/io:print.ln("m:ug")
        | bad |> std/io:print.ln("m:bad")
    | dup |> std/io:print.ln("q:dup")
    | full |> std/io:print.ln("q:full")
    | unknown-generator |> std/io:print.ln("q:ug")
    | bad |> std/io:print.ln("q:bad")

// dup: same name twice in one block
std/sym:rel-new(): d0
|> std/sym:rel-decls(reg: d0, src: "a=;a=g(x)")
    | exact r |> std/io:print.ln("dup?") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")

// unknown-generator: a law referencing an undeclared name
std/sym:rel-new(): u0
|> std/sym:rel-decls(reg: u0, src: "sin=g(cos)")
    | exact r |> std/io:print.ln("ug?") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")

// bare name entry = lawless seed; deriving it refuses lawless
std/sym:rel-new(): l0
|> std/sym:rel-decls(reg: l0, src: "f")
    | exact l |> std/sym:rel-derive(reg: l, a: "g(f)")
        | exact d |> std/io:print.ln("lawless?") |> std/io:free(content: d) |> std/io:free(content: l)
        | unknown-generator |> std/io:print.ln("l:ug") |> std/io:free(content: l)
        | lawless |> std/io:print.ln("lawless") |> std/io:free(content: l)
        | bad |> std/io:print.ln("l:bad") |> std/io:free(content: l)
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")

// malformed: name that is not a name
std/sym:rel-new(): b0
|> std/sym:rel-decls(reg: b0, src: "9bad=g(x)")
    | exact r |> std/io:print.ln("bad?") |> std/io:free(content: r)
    | dup |> std/io:print.ln("dup")
    | full |> std/io:print.ln("full")
    | unknown-generator |> std/io:print.ln("ug")
    | bad |> std/io:print.ln("bad")

// empty block is an honest no-op — the registry comes back unchanged
std/sym:rel-new(): e0
|> std/sym:rel-decls(reg: e0, src: "exp=g(exp)")
    | exact e1 |> std/sym:rel-decls(reg: e1, src: "")
        | exact e2 |> std/io:print.ln("{{ e2:s }}") |> std/io:free(content: e2)
        | dup |> std/io:print.ln("e:dup")
        | full |> std/io:print.ln("e:full")
        | unknown-generator |> std/io:print.ln("e:ug")
        | bad |> std/io:print.ln("e:bad")
    | dup |> std/io:print.ln("e0:dup")
    | full |> std/io:print.ln("e0:full")
    | unknown-generator |> std/io:print.ln("e0:ug")
    | bad |> std/io:print.ln("e0:bad")
