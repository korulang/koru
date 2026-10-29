// PIN (std/rand + for i64 bounds):
//  - `for(0..n)` compiles with a runtime i64 bound — the lowering
//    emits the intCast itself (previously the caller had to write
//    `@as(usize, @intCast(n))` or be refused at the zig stage).
//  - std/rand:between stays inside [lo, hi); below(n > 0) lands in
//    [0, n). Bad ranges are a contract violation (panic), not a
//    branch — so no `| empty` arm is ever owed at a call site.
// STDIN: "200" — 200 rolls, every one must land in [1,6].

import std/io
import std/string
import std/control
import std/rand

std/io:readln()
| line s |> std/string:parse-int(s)
    | ok n |> for(0..n)
        ! each _ |> std/rand:between(lo: 1, hi: 7): f |> if(f < 1 or f > 6)
            | then |> std/io:print.ln("BAD range {{ f:d }}")
        | done |> std/io:print.ln("all in range")
    | err _ |> std/io:print.ln("BAD parse")
| eof |> _
| failed _ |> std/io:print.ln("BAD read")

std/rand:below(n: 6): v |> if(v < 0 or v > 5)
| then |> std/io:print.ln("BAD below {{ v:d }}")
| else |> std/io:print.ln("below in range")
