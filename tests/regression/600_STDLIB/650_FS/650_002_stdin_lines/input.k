// The INTERACTIVE/PIPE vertical: stdin as a stream of lines, same effect
// contract as the file twin (std/io:read-lines — the event owns the buffer).
// The harness pipes the STDIN file; a human at a terminal is the same code.

import std/io

std/io:read-lines()
! line l |> std/io:print.ln("got: {{ l:s }}")
| done n |> std/io:print.ln("{{ n:d }} lines from stdin")
| failed e |> std/io:print.ln("FAILED: {{ e:s }}")
