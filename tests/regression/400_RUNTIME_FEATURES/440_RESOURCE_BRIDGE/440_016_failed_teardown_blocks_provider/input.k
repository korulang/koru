// probe — the failed-teardown route: discharge spec without a dispatcher.

import std/io
import std/bridge
import app/session

tor run-turn { br: *std/bridge:Bridge, source: string, label: string }
run-turn = std/bridge:run(br, source)
| result r |> std/io:print.ln("  {{ label:s }}: held={{ r.handles:d }}")
| defined d |> std/io:print.ln("  {{ label:s }}: DEFINED {{ d:s }}")
| event-denied ev |> std/io:print.ln("  {{ label:s }}: DENIED {{ ev:s }}")
| dispatch-error e |> std/io:print.ln("  {{ label:s }}: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  {{ label:s }}: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  {{ label:s }}: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  {{ label:s }}: VALIDATION")
| shape-error _ |> std/io:print.ln("  {{ label:s }}: SHAPE")
| scope-not-found _ |> std/io:print.ln("  {{ label:s }}: NO SCOPE")

[with]std/bridge:create(id: "probe", scope: "files"): br
|> std/io:print.ln("--- bridge open")
|> run-t(br, source: "open(path: \"a.txt\")", label: "open")
|> run-t(br, source: "query(conn: \"a.txt\", handle: \"cur1.txt\")", label: "cursor")
|> std/io:print.ln("--- hang up; close-query has NO proc — discharge must fail")
|> std/bridge:close(br)
|> std/io:print.ln("--- done")

tor run-t { br: *std/bridge:Bridge, source: string, label: string }
run-t = std/bridge:run(br, source)
| result r |> std/io:print.ln("  {{ label:s }}: held={{ r.handles:d }}")
| defined d |> std/io:print.ln("  {{ label:s }}: DEFINED {{ d:s }}")
| event-denied ev |> std/io:print.ln("  {{ label:s }}: DENIED {{ ev:s }}")
| dispatch-error e |> std/io:print.ln("  {{ label:s }}: DISPATCH {{ e.message:s }}")
| parse-error e |> std/io:print.ln("  {{ label:s }}: PARSE {{ e.message:s }}")
| exhausted _ |> std/io:print.ln("  {{ label:s }}: EXHAUSTED")
| validation-error _ |> std/io:print.ln("  {{ label:s }}: VALIDATION")
| shape-error _ |> std/io:print.ln("  {{ label:s }}: SHAPE")
| scope-not-found _ |> std/io:print.ln("  {{ label:s }}: NO SCOPE")