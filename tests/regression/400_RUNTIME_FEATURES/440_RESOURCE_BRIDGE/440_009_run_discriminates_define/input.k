// The REPL rung (KOPIUM_RUNTIME.md, R1): `std/bridge:run` discriminates
// declaration from invocation — the same verb a REPL's `def` lives in.
//
// Before this rung, installing a flow needed the separate `define` verb.
// Today a DECLARATION arriving at `run` (a source that starts with `tor`)
// installs into the session's defined-flows table and returns `defined`,
// while an INVOCATION dispatches as before. The agent does not need to know
// which verb it is using; the run loop tells.
//
// The visibility half is pinned too: `std/bridge:vocabulary` renders the
// scope's compiled events PLUS the session's defined flows, so an invention
// shows up in the derived prompt on the next turn as `greet(text: string)`.
import std/io
import std/bridge
import std/runtime
import std/interpreter

tor echo { text: string } -> string
proc echo|zig {
    return text;
}

std/runtime:register(scope: "api") {
    echo(1)
}

// Turn A: an invocation of a verb that does not exist yet — denied.
tor turn-a { br: *std/bridge:Bridge }
turn-a = std/bridge:run(br, source: "greet(text: \"hi\")")
| result r |> std/io:print.ln("  A: DISPATCHED (unexpected): {{ r.value.branch:s }}")
| defined d |> std/io:print.ln("  A: DEFINED (unexpected): {{ d:s }}")
| event-denied ev |> std/io:print.ln("  A: DENIED {{ ev:s }} (expected)")
| shape-error _ |> std/io:print.ln("  A: SHAPE")
| dispatch-error e |> std/io:print.ln("  A: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  A: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  A: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  A: VALIDATION")
| scope-not-found _ |> std/io:print.ln("  A: NO SCOPE")

// Turn B: the same `run`, with a DECLARATION — installs.
tor turn-b { br: *std/bridge:Bridge }
turn-b = std/bridge:run(br, source: "tor greet { text: string }\ngreet = echo(text)")
| defined d |> std/io:print.ln("  B: defined {{ d:s }} (expected)")
| result r |> std/io:print.ln("  B: DISPATCHED (unexpected): {{ r.value.branch:s }}")
| event-denied ev |> std/io:print.ln("  B: DENIED {{ ev:s }}")
| shape-error _ |> std/io:print.ln("  B: SHAPE")
| dispatch-error e |> std/io:print.ln("  B: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  B: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  B: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  B: VALIDATION")
| scope-not-found _ |> std/io:print.ln("  B: NO SCOPE")

// Turn C: the invention dispatched through the same run — params bound.
tor turn-c { br: *std/bridge:Bridge }
turn-c = std/bridge:run(br, source: "greet(text: \"hi\")")
| result r |> std/interpreter:value.stringify(r.value): j |> std/io:print.ln("  C: greet -> {{ j:s }} (expected)")
| defined d |> std/io:print.ln("  C: DEFINED (unexpected): {{ d:s }}")
| event-denied ev |> std/io:print.ln("  C: DENIED {{ ev:s }}")
| shape-error _ |> std/io:print.ln("  C: SHAPE")
| dispatch-error e |> std/io:print.ln("  C: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  C: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  C: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  C: VALIDATION")
| scope-not-found _ |> std/io:print.ln("  C: NO SCOPE")

// Turn D: the derived vocabulary carries the invention, typed.
tor turn-d { br: *std/bridge:Bridge }
turn-d = std/bridge:vocabulary(br)
| ok v |> std/io:print.ln("  D: vocabulary contains greet: {{ v:s }}") |> std/io:print.ln("  D: (expected greet(text: string) present)")
| not-found s |> std/io:print.ln("  D: NO SCOPE {{ s:s }}")

[with]std/bridge:create(id: "rtdisc", scope: "api"): br
|> std/io:print.ln("--- bridge open")
|> turn-a(br)
|> turn-b(br)
|> turn-c(br)
|> turn-d(br)
|> std/io:print.ln("--- done")