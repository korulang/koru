// COMPOSITION: match dispatched INSIDE a runtime event's ! line handler
// (different lowering than match-under-for, 640_002: this is the synthesized
// Handlers-struct path). Match composes here; counting rides | done.
// Full-match [0-9]+ hits 123, 42, 7 → prints 3 hits of 5 lines.

import std/io
import std/fs
import std/regex

std/fs:read-lines(path: "tests/regression/600_STDLIB/650_FS/650_003_lines_match_capture/input.txt")
! line l |> std/regex:match(l)
    | `[0-9]+` m |> std/io:print.ln("number: {{ m:s }}")
    | no-match |> _
| done n |> std/io:print.ln("{{ n:d }} lines scanned")
| failed e |> std/io:print.ln("FAILED: {{ e:s }}")
