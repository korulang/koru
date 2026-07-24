// Pins the cond DESTRUCTURING frontier: a `cond` over a struct scrutinee whose
// arm binder DESTRUCTURES it — `| c { field } when <pred over field> -> …`. The
// destructured name `value` deliberately does NOT coincide with the event input
// (`n`), so a green here means the destructure binder GENUINELY binds the field
// (not a name-coincidence like 320_133). FRONTIER PROBE — spelling is a best
// guess pending next-session grounding. Base surface: 320_133.
import std/io

pub tor classify { n: i64 } -> i64

classify = cond({ value: n })
| c { value } when value == 4 -> value * 100
| c _ -> -1

classify(n: 4): r |> std/io:print.ln("{{ r:d }}")
