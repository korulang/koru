import std/io

tor t-a { x: i64 }
| ok i64
| fail i64

tor t-b { v: i64 }
| ok i64
| fail i64

tor t-c { v: i64 }
| ok i64
| fail [:0]u8

t-a(x: 1): r0
|> t-b()
    | ok r1 |> t-c()
        | ok r2 |> std/io:print.ln("done")
        | fail f2 |> std/io:print.ln("cf")
| fail f1 |> std/io:print.ln("bf")
