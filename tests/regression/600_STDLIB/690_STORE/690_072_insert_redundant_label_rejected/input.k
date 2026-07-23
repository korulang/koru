// PIN (RED until mandatory-punning lands) — koru destructures REJECT a redundant
// `label: label` ("punning is mandatory; write `label`"). A store write block
// should too. Today `insert { label: label }` compiles silently — the exact
// redundancy koru forbids elsewhere. This MUST_FAIL pins that it should be
// rejected with the same teaching diagnostic. RED (compiles today).
import std/string
import std/store
std/store:new(todos, capacity: 4) { label: *std/string:String<std/string:instance!> }
std/string:from-page(text: "hi")
| ok a |> std/string:take(s: a): label |> std/store:insert(todos) { label: label }
    | row _ |> _
| err _ |> _
