// PIN: a chain-transform product bound by `: t` and referenced from inside
// a NESTED sweep body keeps its record shape. `t.text` is in-body member
// access, not a pre-projected field on the captured input.
//
// `fmt:ln(...) : t |> query(b2) |> append(b2, t.text)` — the fmt product
// (a `.text` record) is a free variable of the inner sweep. The capture
// threads the whole record; the body projects.
//
// Found 2026-09-06, minimized from the d_turns transcript-append ladder.
import std/io
import std/store
import std/string
import std/fmt

std/store:new(transcript, capacity: 2) { *std/string:String<std/string:instance!> }
std/string:from-page(text: "t:")
| ok a |> std/string:take(s: a): t |> std/store:insert(transcript) { t }
    | row _ |> _
    | full f |> std/string:free(s: f)
| err _ |> _

std/store:query(transcript)
! query buf |> std/fmt:ln("{{ buf:S }}"): t |> std/store:query(transcript)
    ! query b2 |> std/string:append(s: b2, t.text)
        | ok |> _
        | err _ |> _
