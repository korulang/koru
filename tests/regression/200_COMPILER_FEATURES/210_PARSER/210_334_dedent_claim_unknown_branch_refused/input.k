import std/io

tor t-a { x: i64 }
| ok i64
| fail

tor t-b { v: i64 }
| ok i64
| fail

tor t-c { v: i64 }
| ok i64
| fail

t-a(x: 1): r0
|> t-b()
    | ok r1 |> t-c()
        | ok r2 |> std/io:print.ln("done")
        | fail |> std/io:print.ln("cf")
| fail |> std/io:print.ln("bf")
| bogus-name |> std/io:print.ln("bogus")
