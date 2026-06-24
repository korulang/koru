// Flow-scope growable list: new → push → push → len → free.
//
// Reads go through the `list:len` event — the canonical Koru read surface.
// `.len` field-paste is a slice/array host affordance (a Zig slice has a real
// `.len`), NOT a growable-list operation; a List handle reads through events
// like everything else in Koru. new(i64) issues <list!>; free discharges <!list>.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, 3) |> std/list:push(xs, 4) |> std/list:len(xs): n |> std/io:print.ln("{{ n:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
