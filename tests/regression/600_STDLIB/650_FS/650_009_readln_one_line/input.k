// std/io:readln is the blocking one-line read. An empty STDIN is eof;
// a line without a trailing newline is still a line.
import std/io

std/io:readln()
| line s |> std/io:print.ln("got: {{ s:s }}")
| eof |> std/io:print.ln("eof")
| failed e |> std/io:print.ln("FAILED: {{ e:s }}")
