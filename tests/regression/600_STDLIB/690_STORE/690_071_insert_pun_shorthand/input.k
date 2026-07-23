// PIN (RED until pun lands) — a store write block should support koru's
// mandatory PUNNING: `insert(todos) { label }` = "column label <- binding label".
// Today the write block is a `source: Source` parsed by struct_literal (not
// koru's destructure machinery), so a bare `label` is "missing column 'label'".
// koru puns EVERYWHERE (`! sweep { label }`, destructures) — except writing to
// a store. This MUST_RUN pins the pun should work.
import std/io
import std/string
import std/store
std/store:new(todos, capacity: 4) { label: *std/string:String<std/string:instance!> }
! inserted { label } |> std/string:read(s: label): t |> std/io:print.ln("added {{ t:s }}")
std/string:from-page(text: "hi")
| ok a |> std/string:take(s: a): label |> std/store:insert(todos) { label }
    | row _ |> _
| err _ |> _
