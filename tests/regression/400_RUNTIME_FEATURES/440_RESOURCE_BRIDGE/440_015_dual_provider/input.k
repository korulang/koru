// R7 — DUAL PROVIDER: one handle depends on two providers, both must
// outlive it (the guard is a SET, not a single edge).
//
// merge(left: a.txt, right: b.txt) mints merged_1 whose depends_on holds
// BOTH pool ids. At hang-up merged_1 must release first, then a.txt and
// b.txt in any order — but neither file may release while merged_1 (which
// depends on it) is still held.
//
// A guard that checked only ONE provider per handle would release the
// unchecked file early — under a live dependent. The depends_on set is
// what the release check must consult.

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

[with]std/bridge:create(id: "dual", scope: "files"): br
|> std/io:print.ln("--- bridge open")
|> run-turn(br, source: "open(path: \"a.txt\")", label: "open a")
|> run-turn(br, source: "open(path: \"b.txt\")", label: "open b")
|> run-turn(br, source: "merge(left: \"a.txt\", right: \"b.txt\")", label: "merge")
|> std/io:print.ln("--- hang up; merged first, both providers after, never under it")
|> std/bridge:close(br)
|> std/io:print.ln("--- done")