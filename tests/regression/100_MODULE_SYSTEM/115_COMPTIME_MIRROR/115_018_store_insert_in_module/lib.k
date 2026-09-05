import std/io
import std/string
import std/store

std/store:new(todos, capacity: 4) { label: *std/string:String<std/string:instance!> }
! inserted { label } |> std/io:print.ln("added {{ label:S }}")

pub tor run {}
run = std/string:from-page(text: "hi")
| ok a |> std/string:take(s: a): label |> std/store:insert(todos) { label }
    | row _ |> _
| err _ |> _
