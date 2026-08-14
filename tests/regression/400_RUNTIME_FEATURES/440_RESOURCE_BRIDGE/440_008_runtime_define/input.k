// The REPL define: a bridge's vocabulary grows at runtime. A subflow
// declaration (`tor name { args }` + `name = <body>`) becomes a verb callable
// on subsequent turns, stored in the session's durable defined-flows table.
// The body's calls run through the same possession machinery as any dispatch.
//
// THE SHAPE (KOPIUM_RUNTIME.md, R1): run discriminates invocation from
// declaration; here the declaration path is the explicit `define` verb.
// Before define, the verb is event-denied; after, it dispatches with params
// bound — `{"branch":"","value":"hi"}` is the identity-return shape (value in
// `__type_ref`, the empty branch is the bare-return convention).
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

tor check-pre { br: *std/bridge:Bridge }
check-pre = std/bridge:run(br, source: "shout(text: \"hi\")")
| result r |> std/io:print.ln("  pre-define: {{ r.value.branch:s }}")
| event-denied ev |> std/io:print.ln("  pre-define: DENIED {{ ev:s }} (expected)")
| shape-error _ |> std/io:print.ln("  pre-define: SHAPE")
| dispatch-error e |> std/io:print.ln("  pre-define: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  pre-define: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  pre-define: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  pre-define: VALIDATION")
| scope-not-found _ |> std/io:print.ln("  pre-define: NO SCOPE")

tor do-define { br: *std/bridge:Bridge }
do-define = std/bridge:define(br, source: "tor shout { text: string }\nshout = echo(text)")
| defined d |> std/io:print.ln("  defined {{ d:s }}")
| parse-error e |> std/io:print.ln("  define failed: {{ e.message:s }}")

tor check-post { br: *std/bridge:Bridge }
check-post = std/bridge:run(br, source: "shout(text: \"hi\")")
| result r |> std/interpreter:value.stringify(r.value): j |> std/io:print.ln("  shout -> {{ j:s }}")
| event-denied ev |> std/io:print.ln("  shout DENIED {{ ev:s }}")
| shape-error _ |> std/io:print.ln("  shout SHAPE")
| dispatch-error e |> std/io:print.ln("  shout DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  shout PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  shout EXHAUSTED")
| validation-error _ |> std/io:print.ln("  shout VALIDATION")
| scope-not-found _ |> std/io:print.ln("  shout NO SCOPE")

[with]std/bridge:create(id: "rtdefine", scope: "api"): br
|> std/io:print.ln("--- bridge open")
|> check-pre(br)
|> do-define(br)
|> check-post(br)
|> std/io:print.ln("--- done")
