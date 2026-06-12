// std/fs:read-lines — the effect shape, against a real data file.
// The event owns the buffer (created and freed inside its own scope;
// `! line` handlers borrow only DURING the read) — resource-safe without
// phantom ceremony. Was a TODO ("fs.read_lines not implemented") from the
// array-shape era; the effect shape IS the implementation.

import std/io
import std/fs

std/fs:read-lines(path: "tests/regression/300_ADVANCED_FEATURES/320_STDLIB/320_060_fs_read_lines/input.txt")
! line l |> std/io:print.ln("> {{ l:s }}")
| done n |> std/io:print.ln("{{ n:d }} lines")
| failed e |> std/io:print.ln("Error: {{ e:s }}")
