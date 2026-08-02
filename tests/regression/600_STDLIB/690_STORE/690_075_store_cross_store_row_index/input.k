// Cross-store cell as a plural row address: `todos[ui.sel]` — `ui.sel` is a
// singleton cell, NOT a self-FK column of `todos`. stored/take must lower the
// address to `__koru_store_ui.sel` (todo_tui space/x).
//
// `ui.sel` HOLDS A HANDLE, not a row position — ruled 2026-08-02, and the
// directory name is now half a lie kept for its id. It was an integer until
// then, and that only worked because the handle-validity wall was off for the
// first store declared (690_242). Verified against the pre-fix compiler: moving
// `ui` above `todos` made this exact program panic. A surface that works only
// when its store is declared first is not a surface.
//
// Why identity rather than position, on this program specifically: it writes
// through `ui.sel` and then TAKES through `ui.sel`, meaning the same row both
// times. Under dense-index reading the take is "whatever row sits at that
// offset now" — and since a take swap-removes the last row into the freed slot,
// the two uses can name different rows the moment anything else is removed.
// The program means identity; it was spelled positionally. O10.iii.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64 }
std/store:new(ui) { sel: -1[i64] }

std/store:insert(todos) { done: 0 }
| row r |> std/store:stored { ui.sel: r }
    |> std/store:stored { todos[ui.sel].done: 1 }
        |> std/store:take(todos[ui.sel])
            | item gone |> std/io:print.ln("done {{ gone.done:d }}")
            | empty |> std/io:print.ln("empty")
