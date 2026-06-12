// The FULL VERTICAL (FRONTIERS gap 5): argv → path → file → streamed lines.
// PURE .k, ledger born empty: std/args delivers the path, std/fs:read-lines
// streams each line as an effect — the EVENT owns the buffer (created and
// freed inside its own scope; handlers borrow only DURING), so the resource
// is safe without any phantom ceremony. `| done n` is the after-count.

import std/io
import std/args
import std/fs

std/args:get(index: 1)
| arg path |> std/fs:read-lines(path)
    ! line l |> std/io:print.ln("{{ l:s }}")
    | done n |> std/io:print.ln("{{ n:d }} lines")
    | failed e |> std/io:print.ln("FAILED: {{ e:s }}")
| out-of-bounds |> std/io:print.ln("usage: <input file>")
