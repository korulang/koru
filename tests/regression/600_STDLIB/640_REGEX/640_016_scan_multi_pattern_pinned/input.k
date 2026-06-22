// Multi-pattern scan (leftmost-across-patterns) is a PINNED follow-up: `match`
// already does multi-pattern via `|` dispatch, and scan reaching parity is
// future work. For now a second `!` pattern is rejected loudly so the
// limitation is visible, not silent. When multi-pattern lands, this test flips
// to MUST_RUN.
import std/io
import std/regex

std/regex:scan(input: "a12")
! `[a-z]+` w |> std/io:print.ln("w={{ w:s }}")
! `[0-9]+` n |> std/io:print.ln("n={{ n:s }}")
| done |> std/io:print.ln("done")
