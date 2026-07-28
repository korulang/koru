// PINS: handling ONE of a callee's several terminals reads the branch that is
// actually active, not the one the author happened to name.
//
// The store is capacity 4 and holds one row, so `insert` returns `| row`. The
// arm names only `| full`. Before the fix the emitter took its single-branch
// shortcut and read the payload unconditionally —
//
//     const f = result_2.full;
//
// — which is `access of union field 'full' while field 'row' is active` at
// runtime, and a segfault in a release build. Nothing at compile time sees it.
//
// The shortcut is sound when the callee has nowhere else to go; it is unsound
// the moment the callee declares several terminals and the author names one.
// 690_085 made exactly that ordinary by making `| row` OPTIONAL — before it,
// every insert named both outcomes and the unsound path was unreachable. So the
// defect is not in either change; it is the pair, and it shipped green because
// no test handled `| full` alone.
//
// An unhandled sibling outcome stays a no-op (690_085's rule), so the guard
// needs no `else`: this program simply inserts the row and runs on.
//
// Found by Lars running koru-examples/downloads after `| row _ |> _` was dropped
// as ceremony — the drop was correct and the crash was underneath it, waiting.
import std/io
import std/string
import std/store

std/store:new(bin, capacity: 4) { label: *std/string:String<std/string:instance!> }

std/string:from-page(text: "a")
| ok a |> std/string:take(s: a): m |> std/store:insert(bin) { label: m }
    | full f |> std/string:free(s: f)
| err _ |> _

std/io:print.ln("survived")
