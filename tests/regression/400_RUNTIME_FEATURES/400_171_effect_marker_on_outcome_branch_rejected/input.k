// 400_171 — `!` (effect marker) on an OUTCOME branch is a kind error.
// `take` returns one outcome branch, `| item`. Writing `! item` (the effect
// marker) is a marker/kind mismatch: `!` and `|` are separate KINDS (effect vs
// continuation), and a call site must use the marker matching the branch's
// declared kind. Left unchecked the mismatch miscompiles — the owned obligation
// (`free(s: taken.label)`) silently fails to discharge and the program leaks —
// so koru rejects it with KORU025 where take's generated outcome event first
// exposes its branch kinds: the phantom semantic checker.
import std/string
import std/store
std/store:new(todos, capacity: 8) { label: *std/string:String<std/string:instance!> }
std/string:from-page(text: "x")
| ok s |> std/string:take(s): owned |> std/store:insert(todos) { label: owned }
    | row r |> std/store:take(todos[r])
        ! item taken |> std/string:free(s: taken.label)
| err _ |> _
