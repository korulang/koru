// 400_171 — `!` (effect marker) on a continuation/OUTCOME branch MUST be rejected.
// `take` returns ONE outcome branch, `| item`. Writing `! item` (the EFFECT
// marker) is a marker/kind mismatch and must be a FRONTEND reject.
//
// GOLD (2026-07-23, found reviewing the todo store-half): today koru SILENTLY
// ACCEPTS `! item` on take and MISCOMPILES it — the owned obligation
// (`free(s: taken.label)`) never discharges, so the program LEAKS at runtime
// with NO compile-time diagnostic (worst class: wrong program, no wall). `!` and
// `|` are separate KINDS (effect vs continuation); a call site must use the
// marker matching the event's declared branch-kind. RED until koru rejects the
// mismatch at its own boundary (flip when the frontend wall lands).
import std/string
import std/store
std/store:new(todos, capacity: 8) { label: *std/string:String<std/string:instance!> }
std/string:from-page(text: "x")
| ok s |> std/string:take(s): owned |> std/store:insert(todos) { label: owned }
    | row r |> std/store:take(todos[r])
        ! item taken |> std/string:free(s: taken.label)
| err _ |> _
