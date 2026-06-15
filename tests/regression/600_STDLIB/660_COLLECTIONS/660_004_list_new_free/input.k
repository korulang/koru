// Step 1: list construction + teardown round-trip. `new` issues the <list!>
// obligation on `xs`; `free` consumes <!list> and discharges it. No push/len
// yet — this proves the ownership lifecycle compiles and runs in pure Koru.
import std/io
import std/list

std/list:new-i64()
| list xs |> std/io:print.ln("made a list") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
