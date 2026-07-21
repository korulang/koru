// 690_054 — an owned-string column REJECTS an insert whose value does not
// hold the live <std/string:instance!> obligation the column consumes.
// from-page issues <view!>; the synthesized insert param consumes
// <std/string:!instance> — view cannot satisfy instance (the 330_033 /
// 330_067 wall, here at the store boundary). Ownership must be TAKEN
// (std/string:take → <instance!>) before it can move into the store.
import std/io
import std/string
import std/store

std/store:new(names, capacity: 8) { name: *std/string:String<std/string:instance!> }

std/string:from-page(text: "nope")
| ok s |> std/store:insert(names) { name: s }
    | row _ |> _
| err _ |> _
