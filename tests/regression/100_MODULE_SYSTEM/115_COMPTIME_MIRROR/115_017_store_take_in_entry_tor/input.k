// CONTROL for 115_023: the same `std/store:take` body wrapped in a `pub tor`,
// but left in the ENTRY file. Holds the module constant so tor-wrapping and
// module placement separate as causes for the empty addressing head `take`
// reports for `todos[ui.sel]`.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: 0[i64] }

pub tor run {}
run = std/store:insert(todos) { done: 0 }
| row _ |> std/store:stored { todos[ui.sel].done: 1 }
    |> std/store:take(todos[ui.sel])
        | item gone |> std/io:print.ln("done {{ gone.done:d }}")
        | empty |> std/io:print.ln("empty")

run()
