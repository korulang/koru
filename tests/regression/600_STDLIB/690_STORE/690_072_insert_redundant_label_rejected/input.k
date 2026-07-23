// PIN — store write blocks reject a redundant `label: label`
// ("punning is mandatory; write `label`"), same law as koru destructures.
import std/string
import std/store
std/store:new(todos, capacity: 4) { label: *std/string:String<std/string:instance!> }
std/string:from-page(text: "hi")
| ok a |> std/string:take(s: a): label |> std/store:insert(todos) { label: label }
    | row _ |> _
| err _ |> _
