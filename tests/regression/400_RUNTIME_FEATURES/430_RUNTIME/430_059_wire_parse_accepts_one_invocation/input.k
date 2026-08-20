// Pins the wire grammar's accept side: `std/runtime:parse.wire` takes a turn
// exactly as a model emits it — one `verb(field: "value")` invocation, quoted
// string values, nothing else — and hands back a parsed flow. The restricted
// channel accepts what the register block can dispatch; the escape hatch is
// closed on the other side (430_060..430_062 pin the refusals).
import std/runtime
import std/io

pub tor greet { name: string } -> string
greet -> name

std/runtime:register(scope: "api") {
    greet(1)
}

std/runtime:parse.wire(source: "greet(name: \"kopium\")")
| parsed f |> std/io:print.ln("PARSED")
| parse-error e |> std/io:print.ln("UNEXPECTED: {{ e.message:s }}")

std/runtime:parse.wire(source: "greet()")
| parsed f |> std/io:print.ln("PARSED EMPTY ARGS")
| parse-error e |> std/io:print.ln("UNEXPECTED: {{ e.message:s }}")

std/runtime:parse.wire(source: "  greet(name: \"escaped \\\"quotes\\\" inside\")  ")
| parsed f |> std/io:print.ln("PARSED ESCAPED")
| parse-error e |> std/io:print.ln("UNEXPECTED: {{ e.message:s }}")
