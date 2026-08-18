// Pins: a call-site bind on a bare-return call binds that call's result at a
// SUBFLOW head (`double(...): d`), the same as at a flow head (210_195).
// A sole `| doubled` continuation is illegal — a bare return has no tags.
import std/io

tor double { value: i64 } -> i64
double -> value * 2

tor plain { n: i64 } -> i64
plain = double(value: n): d -> d

[abstract] tor viaAbstract { n: i64 } -> i64

input:viaAbstract = double(value: n): d -> d + 1

plain(n: 21): a |> std/io:print.ln("{{ a:d }}")
viaAbstract(n: 10): b |> std/io:print.ln("{{ b:d }}")
