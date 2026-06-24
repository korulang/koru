// Push inside a for-loop: for(0..n) ! each _ |> push(xs, 1), then len. The
// loop index is usize and push wants i64, so we push a constant; the point is
// that push composes as the per-iteration body of a for. free in | done.
import std/io
import std/list
std/list:new(i64)
| list xs |> for(0..5)
    ! each _ |> std/list:push(xs, 1)
    | done |> std/list:len(xs): m |> std/io:print.ln("len={{ m:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
