// Pins the wire grammar's central refusal: prose is not an invocation. A
// model declining a request in English must come back `parse-error` — "that
// was not Koru" — never `event-denied`, which means "a real verb that is not
// yours" and teaches the wrong lesson about the mistake. This is the wire
// half of 430_055: the general interpreter keeps its own grammar; the wire
// channel has no general-expression escape hatch at all.
import std/runtime
import std/io

pub tor greet { name: string } -> string
greet -> name

std/runtime:register(scope: "api") {
    greet(1)
}

std/runtime:parse.wire(source: "I cannot delete files. My vocabulary only includes open(), append(), and close().")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR")

std/runtime:parse.wire(source: "")
| parsed f |> std/io:print.ln("UNEXPECTED PARSED")
| parse-error e |> std/io:print.ln("PARSE ERROR EMPTY")
