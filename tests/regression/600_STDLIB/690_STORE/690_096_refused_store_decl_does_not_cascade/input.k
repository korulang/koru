import std/io
import std/store

std/store:new(ui) { n: 0[i64] }
std/store:new(batch, capacity: 2) { p: i64 }
! discharge |> std/io:print.ln("teardown")

seed = std/store:insert(batch) { p: 1 }
|> std/store:query(batch)
! query b |> std/store:stored { ui.n: ui.n + b.p }

main = seed()
