// Indexed field READ in a stored RHS: `todos[ui.sel].done` must lower to the
// SoA column (`__koru_store_todos.done[…]`), not a bare Zig `todos[…]`.
// todo_tui space-toggle: `done: 1 - todos[ui.sel].done`.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: 0[i64] }

std/store:insert(todos) { done: 0 }
| row _ |> std/store:stored { todos[ui.sel].done: 1 - todos[ui.sel].done }

std/store:sweep(todos)
! sweep e |> std/io:print.ln("done {{ e.done:d }}")
