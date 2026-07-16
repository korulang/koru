// Pins: a `cond` arm's `c <name>` binder binds the SCRUTINEE under that name,
// in scope for BOTH the guard AND the produce — regardless of whether <name>
// happens to coincide with an existing in-scope variable. (320_133 uses `c k`
// where the event input is also `k`, so its binder is a coincidental no-op and
// its produces are literals; this exercises the binder itself.) Base surface: 320_133.
import std/io

pub event classify { k: i64 } -> i64

classify = cond(k)
| c v when v > 2 and v < 5 -> v * 10
| c v when v == 0 -> 999
| c _ -> -1

classify(k: 3): a |> std/io:print.ln("{{ a:d }}")
classify(k: 0): b |> std/io:print.ln("{{ b:d }}")
classify(k: 9): c |> std/io:print.ln("{{ c:d }}")
