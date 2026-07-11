// Auto-discharge for a dropped list (the phantom type forces cleanup). `new`
// issues <list!>; `free` is the single disposer for <!list>; so a list dropped
// at scope exit gets `free(xs)` auto-inserted — exactly like a dropped File
// auto-inserts `close` in 330_041. No explicit free here, yet no leak: the
// generated program carries an auto-inserted free_event call. A leak is always a
// bug; this proves the obligation makes the simple-drop case leak-proof for free.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, v: 1) |> std/io:print.ln("done")
| err e |> std/io:print.ln("ERR {{ e:s }}")
