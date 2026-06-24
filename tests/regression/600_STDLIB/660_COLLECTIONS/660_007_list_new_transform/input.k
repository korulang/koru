// Step 1b: the generic `new(i64)` transform. It reads the element type at
// comptime and rewrites the call site to the concrete `new-i64` constructor;
// the `| list` / `| err` branches carry over. Same program as 660_005 but using
// the real `new(i64)` surface instead of `new-i64()`.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, 3) |> std/list:push(xs, 4) |> std/list:len(xs): n |> std/io:print.ln("len={{ n:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
