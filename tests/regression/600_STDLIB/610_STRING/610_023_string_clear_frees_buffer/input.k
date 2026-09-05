// `clear` must FREE the buffer, not just forget its length.
//
// A String's `data` slice IS its allocation record — koru_std/string.kz has
// no capacity field — so `s.data.len = 0` orphans the allocation by two
// independent routes in std.mem.Allocator:
//
//   free(s.data)            -> `if (bytes_len == 0) return;`  frees nothing
//   realloc(s.data, n)      -> `if (old_mem.len == 0)` allocs fresh, never
//                              releasing the old pointer
//
// So a cleared String leaks its whole buffer whether it is disposed or
// appended to next. This program does both: clear, then append, then free.
// The output was always correct — only the memory was wrong, which is why
// it took an app to find it.
//
// Found by kopium's chat pane: the draft line is cleared once per turn, so
// it leaked one buffer per message the user sent.
import std/io
import std/string

std/string:from-page(text: "abcd")
| ok a |> std/string:take(s: a): s |> std/string:clear(s)
    |> std/string:append(s, text: "xy")
        | ok |> std/io:print.ln("[{{ s:S }}]") |> std/string:free(s)
        | err _ |> std/string:free(s)
| err _ |> _
