// PINS: a qualified host-type collection BORROW survives a user-tor
// parameter boundary. `rd` takes `xs: *std/list:List_i64<list>` and
// re-passes it to `std/list:get-i64` — the param's phantom must be seeded
// into the impl's binding context, or the inner call reads `xs` as
// untracked and refuses KORU030 "no tracked phantom state".
//
// Sibling of 660_027 (owned `<!list>`/`<list!>` through the same
// boundary) and 660_032 (proto-element borrow through a user tor).
import std/io
import std/list

pub tor rd { xs: *std/list:List_i64<list> } -> i64

rd = std/list:get-i64(xs, i: 0)
| item v -> v
| out-of-bounds -> 0

std/list:new-i64()
| list xs |> std/list:push-i64(xs, v: 7) |> rd(xs): v |> std/io:print.ln("{{ v:d }}") |> std/list:free-i64(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
