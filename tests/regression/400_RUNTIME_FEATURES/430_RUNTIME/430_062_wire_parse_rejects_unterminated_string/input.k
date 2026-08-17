// Pins the wire grammar's string discipline: a value opens with a double
// quote and must close with one. An unterminated string is a truncated model
// reply — the refusal says so, rather than letting a partial line dispatch
// with a silently shortened argument.
import std/runtime
import std/io

pub tor greet { name: string } -> string
greet -> { name }

std/runtime:register(scope: "api") {
    greet(1)
}

std/runtime:parse.wire(source: "greet(name: \"kopium)")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR UNTERMINATED")

std/runtime:parse.wire(source: "greet(name: kopium)")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR UNQUOTED")
