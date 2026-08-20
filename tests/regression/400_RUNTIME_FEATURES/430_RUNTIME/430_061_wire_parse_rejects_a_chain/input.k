// Pins the wire grammar's termination guarantee: one invocation per turn,
// nothing after the closing paren. A `|>` chain is general Koru — legal in a
// program, not expressible on the wire. The refusal names what was attempted
// so the model is taught the boundary instead of just failing.
import std/runtime
import std/io

pub tor greet { name: string } -> string
greet -> name

std/runtime:register(scope: "api") {
    greet(1)
}

std/runtime:parse.wire(source: "greet(name: \"a\") |> greet(name: \"b\")")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR CHAIN")

std/runtime:parse.wire(source: "greet(name: \"a\") because the user asked")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR TRAILING")
