import std/io

pub event echo { s: []const u8 }

echo = for(s)
! each c |> std/io:print.ln("{{ @as(i64, c):d }}")
| done |> _

echo(s: "uurcx")
