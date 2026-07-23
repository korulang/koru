// std/store:take gains an `| empty` branch — a take on an out-of-range row (an
// empty store, or a handle past len) is a GRACEFUL, handleable outcome, not a
// panic. `is_panic` (`?!`): a site that omits `| empty` still gets the old
// synthesized panic (existing take sites unchanged); a site that handles it —
// an interactive delete off an empty list — stays alive. No payload, no
// obligation on the empty arm.
import std/io
import std/store
std/store:new(items, capacity: 4) { v: i64 }
std/store:insert(items) { v: 42 }
| row _ |> _
std/store:take(items[0])
| item i |> std/io:print.ln("took {{ i.v:d }}")
| empty |> std/io:print.ln("empty")
std/store:take(items[0])
| item i |> std/io:print.ln("took {{ i.v:d }}")
| empty |> std/io:print.ln("empty")
