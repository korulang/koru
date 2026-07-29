// 690_060 — QUERY over an OWNED-STRING column: the read/react/write rung
// (Path B). A store column holds *std/string:String<std/string:instance!>
// (690_053 built insert/take/teardown). `query` must BORROW each live
// element read-only — hand a *String<view> of the still-owned pointer —
// WITHOUT moving it out. `take` moves out (reissues <instance!>); `query`
// borrows and leaves the store owning <instance!>. The projected `name`
// binds the <view>; std/string:read accepts <view|instance> (string.kz:106)
// so the borrow reads cleanly. Teardown still auto-frees every live element.
//
// Currently WALLED at store.kz:1361 ("query over a store with an owned-string
// column is a later rung"). This pins the TARGET behavior — MUST_RUN, red
// until the rung lands. The query fires per matching insert (690_005 model),
// borrowing the just-moved-in element and reading it.
import std/io
import std/string
import std/store

std/store:new(names, capacity: 8) { name: *std/string:String<std/string:instance!> }

std/store:query(names)
! query e |> std/string:read(s: e.name): text |> std/io:print.ln("{{ text:s }}")

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/store:insert(names) { name: owned }
    | row _ |> _
| err _ |> _

std/string:from-page(text: "world")
| ok s2 |> std/string:take(s: s2): owned2 |> std/store:insert(names) { name: owned2 }
    | row _ |> _
| err _ |> _
