// PIN (std/rand + for i64 bounds):
//  - `for(0..n)` compiles with a runtime i64 bound — the lowering
//    emits the intCast itself (previously the caller had to write
//    `@as(usize, @intCast(n))` or be refused at the zig stage).
//  - std/rand:between stays inside [lo, hi); a bad range answers
//    `| empty` — a named outcome, not an exception.
//  - std/rand:below(n <= 0) is `| empty`; below(n > 0) lands in [0, n).
// STDIN: "200" — 200 rolls, every one must land in [1,6].

import std/io
import std/string
import std/control
import std/rand

std/io:readln()
| line s |> std/string:parse-int(s)
    | ok n |> for(0..n)
        ! each _ |> std/rand:between(lo: 1, hi: 7)
            | n f when f < 1 |> std/io:print.ln("BAD low {{ f:d }}")
            | n f when f > 6 |> std/io:print.ln("BAD high {{ f:d }}")
            | n _ |> _
            | empty |> std/io:print.ln("BAD empty")
        | done |> std/io:print.ln("all in range")
    | err _ |> std/io:print.ln("BAD parse")
| eof |> _
| failed _ |> std/io:print.ln("BAD read")

std/rand:between(lo: 7, hi: 1)
| n _ |> std/io:print.ln("BAD inverted")
| empty |> std/io:print.ln("empty ok")

std/rand:below(n: 6)
| v f when f < 0 |> std/io:print.ln("BAD below low {{ f:d }}")
| v f when f > 5 |> std/io:print.ln("BAD below high {{ f:d }}")
| v _ |> std/io:print.ln("below in range")
| empty |> std/io:print.ln("BAD below empty")

std/rand:below(n: 0)
| v _ |> std/io:print.ln("BAD below value")
| empty |> std/io:print.ln("below empty ok")
