// std/store:sweep over an OWNED-string store, nested, multi-step body.
// The render-bridge shape: a retained renderer sweeps a todo store to repaint.
//
// Covers two rungs together:
//  1. OWNED-COLUMN projection — `label: *String<instance!>` projects as a BARE
//     borrow (`mod:state`, no `!`), so the body may `read` it without
//     discharging and the store keeps its live `<state!>` (query's qbody model).
//  2. KORU100 nested-transform deferral — the projected `label`/`done` are used
//     DOWNSTREAM in a multi-step body (`read(s: label): t |> print(...done...)`),
//     invisible to the frontend unused-binding scan. sweep is a transform in
//     CONTINUATION position (nested under `! each`), so the binding-usage check
//     must defer to `all` mode exactly as a top-level query does — the
//     nested-position twin of flowRootIsTransform.

import std/io
import std/string
import std/store

std/store:new(todos, capacity: 16) { label: *std/string:String<std/string:instance!>, done: i64 }

std/string:from-page(text: "buy milk")
| ok a |> std/string:take(s: a): milk |> std/store:insert(todos) { label: milk, done: 0 }
    | row _ |> std/string:from-page(text: "write koru")
        | ok b |> std/string:take(s: b): koru |> std/store:insert(todos) { label: koru, done: 1 }
            | row _ |> _
        | err _ |> _
| err _ |> _

for(0..2)
! each _ |> std/store:query(todos)
    ! query e |> std/io:print.ln("{{ e.label:S }} [{{ e.done:d }}]")
