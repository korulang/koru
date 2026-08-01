// `pop-char` down to empty must FREE the buffer — sibling of 610_023.
//
// `s.data.len -= 1` shrinks the slice without telling the allocator, and the
// last pop lands on len 0, which is exactly the orphaned state 610_023 pins:
// `free` early-returns and a later `realloc` allocates fresh. Backspacing a
// draft line empty therefore leaks the whole buffer — a path every TUI hits.
//
// Both tors are the same defect: a String's slice IS its allocation record,
// so any spelling that edits `len` behind the allocator's back loses the
// block. Every other mutator (append, append-char) already reallocs; these
// two were the exceptions.
import std/io
import std/string

std/string:from-page(text: "ab")
| ok a |> std/string:take(s: a): s |> std/string:pop-char(s) |> std/string:pop-char(s)
    |> std/string:read(s): text |> std/io:print.ln("[{{ text:s }}]") |> std/string:free(s)
| err _ |> _
