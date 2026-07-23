// Cross-store cell as plural row index: `todos[ui.sel]` — `ui.sel` is a
// singleton cell, NOT a self-FK column of `todos`. stored/take must lower
// the index to `__koru_store_ui.sel` (todo_tui space/x).
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: 0[i64] }

std/store:insert(todos) { done: 0 }
| row _ |> std/store:stored { todos[ui.sel].done: 1 }
    |> std/store:take(todos[ui.sel])
        | item gone |> std/io:print.ln("done {{ gone.done:d }}")
        | empty |> std/io:print.ln("empty")
