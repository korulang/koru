// CONTROL for 115_003: the same `std/regex:scan` body wrapped in a `pub tor`,
// but left in the ENTRY file. Holds the module constant so tor-wrapping and
// module placement separate as causes for the missing `__koru_scan_find_*`
// helper.
import std/io
import std/regex

pub tor run {}
run = std/regex:scan(input: "no digits here")
! `[0-9]+` n |> std/io:print.ln("n={{ n:s }}")
| done |> std/io:print.ln("done")

run()
