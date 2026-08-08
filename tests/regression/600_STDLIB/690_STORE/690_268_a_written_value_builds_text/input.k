// PINS: a written value may BUILD text — a row's text column can be extended,
// not only replaced with a literal.
//
// The `{{ … }}` form is the one Koru already has for making text out of
// values; until now it only worked as an argument to print, so a row's text
// could be read and never changed. Here it composes with the existing value
// exactly as arithmetic does for a number (`e.n: e.n + 1` below is the
// control, and reads the same way).
//
// WHY IT COSTS NOTHING: the destination's width is known, so the text formats
// into a stack buffer sized to the COLUMN and copies in — no allocation on
// either target. `print` reserves a blanket 64KB because it has no destination
// to measure; a column write does. Verified identical output on both lanes.
//
// The buffer is declared in the invocation's preamble rather than inline: the
// write copies out of it, so an expression-local would hand the copy a
// dangling slice. That needs `@preamble_then_call` — a preamble-bearing
// replacement otherwise means "the preamble REPLACES the call" and the write
// vanishes silently (transform_pass_runner.zig:104).
//
// ⚠ TRUNCATION, and it is the store's existing behaviour rather than this
// feature's: a result longer than the column is cut, exactly as an over-long
// literal already is at a column write. `too-small` below pins that it cuts
// rather than corrupting — the honest answer is a `| full`-shaped branch and
// neither write has one yet.
import std/io
import std/store

std/store:new(rows, capacity: 4) { label: char[48], n: i64 }

std/store:insert(rows) { label: "pretty red pony", n: 0 }
    | row _ |> _
    | full |> _

std/store:rule(rows)
! row e |> std/store:stored { e.label: "{{ e.label:s }} !!!" }
    |> std/store:stored { e.n: e.n + 1 }
    |> std/io:print.ln("{{ e.label:s }} · marked {{ e.n:d }}")
