// Store cell paths (`ui.sel`) must lower in if/when expressions outside
// transplanted watch arms — same rewrite watch bodies already get. Without
// it, Zig sees undeclared `ui` (todo_tui selection cursor).
import std/io
import std/store

std/store:new(ui) { sel: 0[i64] }

std/store:stored { ui.sel: 3 }
if(ui.sel > 0)
| then |> std/io:print.ln("sel {{ ui.sel:d }}")
| else |> std/io:print.ln("zero")
