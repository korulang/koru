// CONTROL for 115_019: the same `std/store:query` wrapped in a `pub tor`, but
// left in the ENTRY file. `query` is a standing-rule installation the store
// coordinator scans for, so this pins that a tor body IS a position the scan
// reaches — leaving module placement as the only remaining variable in the
// mirror.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: 0[i64] }

pub tor run {}
run = std/store:insert(todos) { done: 0 }
| row _ |> std/store:stored { todos[ui.sel].done: 1 - todos[ui.sel].done }

pub tor show {}
show = std/store:query(todos)
! query e |> std/io:print.ln("done {{ e.done:d }}")

run() |> show()
