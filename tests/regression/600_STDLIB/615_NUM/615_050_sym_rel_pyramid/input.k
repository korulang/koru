import std/io
import std/sym

std/sym:rel-new(): r0
|> std/sym:rel-seed(name: sin, reg: r0)
    | exact r1 |> std/sym:rel-seed(name: cos, reg: r1)
        | exact r2 |> std/sym:rel-law(name: sin, reg: r2) { g(cos) }
            | exact r3 |> std/sym:rel-law(name: cos, reg: r3) { -1e0*g(sin) }
                | exact r4 |> std/sym:rel-derive(reg: r4) { g(sin)*g(sin)+g(cos)*g(cos) }
                    | exact d |> std/io:print.ln("{{ d:s }}")
| dup |> std/io:print.ln("dup")
| full |> std/io:print.ln("full")
| bad |> std/io:print.ln("bad")
| unknown-generator |> std/io:print.ln("unknown-generator")
| lawless |> std/io:print.ln("lawless")
