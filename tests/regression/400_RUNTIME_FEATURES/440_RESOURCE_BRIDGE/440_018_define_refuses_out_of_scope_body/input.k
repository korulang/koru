// Definition-time scope filter (KOPIUM_RUNTIME.md, remaining R1 rung):
// a body that names an event outside the session must refuse at INSTALL,
// not wait for dispatch. Call-time possession is the floor; this pin is
// the install wall.
//
// Scope `api` holds only `echo`. `tor sneak = sync(...)` must not enter
// the defined-flows table. A later `sneak(...)` is still denied. A legal
// `tor greet = echo(...)` still installs.
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

tor try-define { br: *std/bridge:Bridge, source: string, label: string }
try-define = std/bridge:run(br, source)
| defined d |> std/io:print.ln("  {{ label:s }}: INSTALLED {{ d:s }}")
| result r |> std/io:print.ln("  {{ label:s }}: DISPATCHED {{ r.value.branch:s }}")
| event-denied ev |> std/io:print.ln("  {{ label:s }}: DENIED {{ ev:s }}")
| parse-error e |> std/io:print.ln("  {{ label:s }}: REFUSED {{ e.message:s }}")
| shape-error _ |> std/io:print.ln("  {{ label:s }}: SHAPE")
| dispatch-error e |> std/io:print.ln("  {{ label:s }}: DISPATCH {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  {{ label:s }}: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  {{ label:s }}: VALIDATION")
| scope-not-found _ |> std/io:print.ln("  {{ label:s }}: NO SCOPE")

tor try-call { br: *std/bridge:Bridge, source: string, label: string }
try-call = std/bridge:run(br, source)
| result r |> std/interpreter:value.stringify(r.value): j |> std/io:print.ln("  {{ label:s }}: {{ j:s }}")
| defined d |> std/io:print.ln("  {{ label:s }}: DEFINED {{ d:s }}")
| event-denied ev |> std/io:print.ln("  {{ label:s }}: DENIED {{ ev:s }}")
| parse-error e |> std/io:print.ln("  {{ label:s }}: PARSE {{ e.message:s }}")
| shape-error _ |> std/io:print.ln("  {{ label:s }}: SHAPE")
| dispatch-error e |> std/io:print.ln("  {{ label:s }}: DISPATCH {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  {{ label:s }}: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  {{ label:s }}: VALIDATION")
| scope-not-found _ |> std/io:print.ln("  {{ label:s }}: NO SCOPE")

tor show-vocab { br: *std/bridge:Bridge }
show-vocab = std/bridge:vocabulary(br)
| ok v |> std/io:print.ln("  vocab: {{ v:s }}")
| not-found s |> std/io:print.ln("  vocab: NO SCOPE {{ s:s }}")

[with]std/bridge:create(id: "scopefilter", scope: "api"): br
|> std/io:print.ln("--- bridge open")
|> try-define(br, source: "tor sneak { text: string }\nsneak = sync(handle: text)", label: "A")
|> try-call(br, source: "sneak(text: \"x\")", label: "B")
|> try-define(br, source: "tor greet { text: string }\ngreet = echo(text)", label: "C")
|> try-call(br, source: "greet(text: \"hi\")", label: "D")
|> show-vocab(br)
|> std/io:print.ln("--- done")
