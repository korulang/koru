// PINS: a rule arm's row-reference rewrite stays OUT OF STRING LITERALS.
//
// The arm's body says `e.<column>` to read a column, and the store rewrites
// that into a cell read. The rewrite is TEXTUAL, so without a mask it fires
// wherever those characters appear — including inside a string the author
// wrote as data. `"e.label is a column"` shipped as a Zig cell read: it
// compiled, it ran, and it stored something nobody wrote. Silent on the JS
// lane; on the Zig lane an "expected ',' after initializer" naming emitted
// code the author never sees.
//
// The mask existed and was consulted by ONE branch (the bare identity binding)
// and not the other, so a bare `e` was safe while `e.<column>` — the shape
// every rule arm uses — was not.
//
// Same disease as 230_016, where the visitor emitter rewrote identifiers
// inside literals. Two sites, one rule: a textual substitution over source
// gets a code/text mask, never a special case.
//
// The second write is the control: a REAL column reference in expression
// position must still become a cell read, or the mask has been applied too
// widely and reading a column has stopped working.
import std/io
import std/store

std/store:new(rows, capacity: 4) { label: char[32], v: i64, w: i64 }

std/store:insert(rows) { label: "start", v: 7, w: 0 }
    | row _ |> _
    | full |> _

std/store:rule(rows)
! row e |> std/store:stored { e.label: "e.label is a column" }
    |> std/store:stored { e.w: e.v + 1 }
    |> std/io:print.ln("label {{ e.label:s }} · v {{ e.v:d }} · w {{ e.w:d }}")
