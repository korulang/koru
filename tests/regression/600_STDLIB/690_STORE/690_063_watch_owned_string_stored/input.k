// 690_063 — WATCH over an OWNED column: a field-watch fires on the
// stored-WRITE of an owned String, borrow-reading the just-written value.
// The downstream half of the WRITE rung (690_062): once owned columns can be
// WRITTEN, `watch` has something to fire on. The watch arm binds the written
// field as a BARE BORROW (`*mod:Type<mod:state>`, no `!` — the 690_060
// projection), read by std/string:read (accepts <view|instance>, consumes
// nothing); the store keeps the live <instance!> it frees at teardown.
//
// The apply body fires the watch arm reading the field FRESH from the stored
// cell (__koru_store.<f>[row]), NOT the incoming param (whose <!instance> the
// write just consumed) — the 690_061 fresh-from-cell rule.
//
// Fires ONCE, on the stored-write (birth-is-not-a-write: insert does NOT fire
// watches — only standing queries do; 690_001 O9). Output: "watch: new".
import std/io
import std/string
import std/store

std/store:new(names, capacity: 8) { label: *std/string:String<std/string:instance!> }

std/store:watch(names)
! label lbl |> std/string:read(s: lbl): t |> std/io:print.ln("watch: {{ t:s }}")

std/string:from-page(text: "old")
| ok s |> std/string:take(s): owned |> std/store:insert(names) { label: owned }
    | row r |> std/string:from-page(text: "new")
        | ok s2 |> std/string:take(s: s2): owned2 |> std/store:stored { names[r].label: owned2 }
        | err _ |> _
| err _ |> _
