// Pure-Koru bare return: the `.k` (no ``) twin of 020_022's proc form. `-> i32`
// declares the single output; `double -> a * 2` is the SUBFLOW impl that PRODUCES
// the bare value (no proc, no tagged union — Output is plain i32); `: d` binds the
// result at the call site. Pure Koru is always the `.k` no-`` shape.
import std/io

pub tor double { a: i32 } -> i32
double -> a * 2

double(a: 21): d |> std/io:print.ln("{{ d:d }}")
