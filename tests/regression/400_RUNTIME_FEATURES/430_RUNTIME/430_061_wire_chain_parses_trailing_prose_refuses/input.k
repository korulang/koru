// Pins the wire grammar's termination guarantee: a `|>` chain is legal wire
// (bare pipes sequence calls), but trailing prose after the closing paren is
// not — the refusal names what was attempted so the model is taught the
// boundary instead of just failing.
import std/runtime
import std/io

pub tor greet { name: string } -> string
greet -> name

std/runtime:register(scope: "api") {
    greet(1)
}

std/runtime:parse.wire(source: "greet(name: \"a\") |> greet(name: \"b\")")
| parsed f |> std/io:print.ln("PARSED CHAIN")
| parse-error e |> std/io:print.ln("PARSE ERROR CHAIN")

std/runtime:parse.wire(source: "greet(name: \"a\") because the user asked")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR TRAILING")
