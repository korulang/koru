import std/io
import std/regex

pub tor run {}
run = std/regex:match("21,9")
| `(?<row>[0-9]+),(?<col>[0-9]+)` pos |> std/io:print.ln("row={{ pos.row:s }} col={{ pos.col:s }}")
| no-match |> std/io:print.ln("no")
