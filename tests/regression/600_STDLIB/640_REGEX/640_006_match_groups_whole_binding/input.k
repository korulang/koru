// Whole-payload binding on a grouped pattern: a plain binding receives ALL
// named groups as one struct (fields are the matched text, untyped = slices).
// KORU100 on the binding covers usage, dotted splices read the fields.
import std/io
import std/regex

std/regex:match("21,9")
| `(?<row>[0-9]+),(?<col>[0-9]+)` pos |> std/io:print.ln("row={{ pos.row:s }} col={{ pos.col:s }}")
| no-match |> std/io:print.ln("no")
