import std/io
import std/sym

std/sym:rel-new()
|> std/sym:rel-seed(name: sin)
    | exact |> std/sym:rel-seed(name: cos)
        | exact |> std/sym:rel-law(name: sin) { g(cos) }
            | exact |> std/sym:rel-law(name: cos) { -1e0*g(sin) }
                | exact |> std/sym:rel-derive() { g(sin)*g(sin)+g(cos)*g(cos) }
                    | exact d |> std/io:print.ln("{{ d:s }}")
| dup |> std/io:print.ln("dup")
| full |> std/io:print.ln("full")
| bad |> std/io:print.ln("bad")
| unknown-generator |> std/io:print.ln("unknown-generator")
| lawless |> std/io:print.ln("lawless")
