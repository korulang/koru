// CONTROL for 115_019: the same `std/store:query` wrapped in a `pub tor`, but
// left in the ENTRY file. `query` is a standing-rule installation the store
// coordinator scans for, so this pins that a tor body IS a position the scan
// reaches — leaving module placement as the only remaining variable in the
// mirror.
//
// `ui.sel` HOLDS A HANDLE, not a row position — ruled 2026-08-02. It was the
// literal 0 until then, which only addressed a row because the handle-validity
// wall was off for the first store declared (690_242). Position is not identity
// (O10.iii): a take swap-removes the last row into the freed slot, so an offset
// names a different row afterwards while a handle names the same one or traps.
// The handle comes from `| row`, the only place one is minted.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: -1[i64] }

pub tor run {}
run = std/store:insert(todos) { done: 0 }
| row r |> std/store:stored { ui.sel: r }
    |> std/store:stored { todos[ui.sel].done: 1 - todos[ui.sel].done }

pub tor show {}
show = std/store:query(todos)
! query e |> std/io:print.ln("done {{ e.done:d }}")

run() |> show()
