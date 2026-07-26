import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: 0[i64] }

pub tor run {}
run = std/store:insert(todos) { done: 0 }
| row _ |> std/store:stored { todos[ui.sel].done: 1 - todos[ui.sel].done }

pub tor show {}
show = std/store:query(todos)
! query { entity.done } |> std/io:print.ln("done {{ done:d }}")
