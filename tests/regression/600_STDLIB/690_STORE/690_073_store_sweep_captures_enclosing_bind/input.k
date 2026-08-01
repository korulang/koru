// std/store:sweep body must capture enclosing mid-pipe binds. The sweep loop
// is site-local (inline at the call site — where `: n` is in Zig scope), but
// the transplanted sweepbody was a separate event that only took the row's
// own columns. Referencing `n` inside `! sweep` leaked a raw host
// `undeclared identifier` — the flagship todo_tui hit this as `: body` (a
// Window from sub-fill) used inside the row paint. Momentary sweep runs HERE,
// so enclosing binds are in scope and must be threaded into the sweepbody.
import std/io
import std/store

pub tor make {} -> i64
proc make|zig {
    return 7;
}

std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }

make(): n |> for(0..1)
! each _ |> std/store:query(items)
    ! query e |> std/io:print.ln("n {{ n:d }} v {{ e.v:d }}")
