// Pins the bridge's complete derived prompt: grammar renders the wire's shape
// rules, then the scope's compiled verbs, then the session's OWN defined
// flows — the register block plus the agent's growth, with nothing
// hand-typed. A prompt built from this render and a turn judged by the wire
// gate in run are the same declaration read twice: the lesson and the law.
import std/io
import std/bridge
import std/runtime

tor echo { text: string } -> string
echo -> text

std/runtime:register(scope: "api") {
    echo(1)
}

tor do-define { br: *std/bridge:Bridge }
do-define = std/bridge:define(br, source: "tor shout { text: string }\nshout = echo(text)")
| defined d |> std/io:print.ln("defined {{ d:s }}")
| parse-error e |> std/io:print.ln("define failed: {{ e.message:s }}")

tor show-grammar { br: *std/bridge:Bridge }
show-grammar = std/bridge:grammar(br)
| ok g |> std/io:print.ln("{{ g:s }}")
| not-found s |> std/io:print.ln("NO SCOPE {{ s:s }}")

[with]std/bridge:create(id: "gram", scope: "api"): br
|> do-define(br)
|> show-grammar(br)
|> std/io:print.ln("--- done")
