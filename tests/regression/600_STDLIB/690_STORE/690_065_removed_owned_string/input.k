// 690_065 — REMOVED interceptor over an OWNED column: react to a row's
// deletion, borrow-reading its owned value on the way OUT. The delete half of
// the reactive-todo CRUD (insert/query/react/write all landed; this is the
// "react when a todo is removed" piece).
//
// `removed` fires in the take path (store.kz 2440), BEFORE the swap-remove,
// with the row's outgoing values — for an owned column the BARE-BORROW
// projection (690_060/061, LC.emit already builds it): the interceptor reads
// the label, consumes nothing; `take` then moves the owned value OUT to the
// caller (reissued <instance!>), which frees it. No leak: the store took its
// only row, teardown has nothing live.
//
// The machinery already exists (LC.emit bare-borrow payload + the take-path
// removed firing); only the create-time wall (store.kz 1432, "removed/updated
// interceptors over an owned column are a later rung") blocked it. This rung
// splits that wall to admit `removed` while `updated` stays walled (updated
// carries TWO owned images — a distinct later rung).
import std/io
import std/string
import std/store

std/store:new(todos, capacity: 8) { label: *std/string:String<std/string:instance!> }
! removed { label } |> std/io:print.ln("removed: {{ label:S }}")

std/string:from-page(text: "task")
| ok s |> std/string:take(s): owned |> std/store:insert(todos) { label: owned }
    | row r |> std/store:take(todos[r])
        | item taken |> std/string:free(s: taken)
| err _ |> _
