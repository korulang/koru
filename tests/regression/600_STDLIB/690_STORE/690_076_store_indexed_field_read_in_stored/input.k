// Indexed field READ in a stored RHS: `todos[ui.sel].done` must lower to the
// SoA column (`__koru_store_todos.done[…]`), not a bare Zig `todos[…]`.
// todo_tui space-toggle: `done: 1 - todos[ui.sel].done`.
//
// `ui.sel` HOLDS A HANDLE, not a row position — ruled 2026-08-02. It was an
// integer until then, and that only worked because the handle-validity wall was
// off for the first store declared (690_242): the literal 0 in `sel` passed the
// brand check and addressed dense row 0. Moving `ui` above `todos` broke it,
// which is how a positional address masquerading as a handle gets found.
//
// The ruling is O10.iii applied to the surface: position is not identity, so a
// cell that names a row names it by IDENTITY. A dense index says "whatever row
// is third right now" and a take swap-removes the last row into the freed slot,
// so the third row silently becomes a different todo. A handle says "that row,
// wherever it moved, or a loud trap if it is gone." A selection is the second
// thing. The handle comes from `| row`, which is the only place one is minted.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: -1[i64] }

std/store:insert(todos) { done: 0 }
| row r |> std/store:stored { ui.sel: r }
    |> std/store:stored { todos[ui.sel].done: 1 - todos[ui.sel].done }

std/store:query(todos)
! query e |> std/io:print.ln("done {{ e.done:d }}")
