// PIN: `std/fs:write` persists a buffer to a path, then `read-lines`
// streams that same content back. `| written` is the outcome; `| failed`
// is loud. This is the missing half of `read-lines` — Ward's POST
// `/api/setup` writes `setup.ini` through this surface, not a host hatch.
import std/io
import std/fs

std/fs:write(path: "written.txt", content: "alpha\nbeta\n")
| written |> std/fs:read-lines(path: "written.txt")
    ! line l |> std/io:print.ln("{{ l:s }}")
    | done n |> std/io:print.ln("{{ n:d }} lines")
    | failed e |> std/io:print.ln("FAILED: {{ e:s }}")
| failed e |> std/io:print.ln("FAILED: {{ e:s }}")
