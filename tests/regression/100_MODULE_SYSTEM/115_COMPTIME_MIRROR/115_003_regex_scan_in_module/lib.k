import std/io
import std/regex

pub tor run {}
run = std/regex:scan(input: "no digits here")
! `[0-9]+` n |> std/io:print.ln("n={{ n:s }}")
| done |> std/io:print.ln("done")
