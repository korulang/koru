// Pins the `cond` surface: flat multi-way dispatch replacing the nested
// `if | else |> if …` cascade (810_121). `cond(scrutinee)` takes the value; each
// `| c <binding> when <pred> -> <value>` arm binds the scrutinee and guards it,
// producing when its guard holds; a guardless `| c _` arm is the default. cond
// does no matching itself — it sits on the `when`-guard + branch-binding
// primitive (400_087, 210_078) and lowers to a first-match if/else-if cascade,
// the same way ~if/~for are templates in koru_std/control.kz.
import std/io

pub event coin-value { k: i64 } -> i64

coin-value = cond(k)
| c k when k == 1 -> 1
| c k when k == 2 -> 5
| c k when k == 3 -> 10
| c k when k == 4 -> 25
| c _ -> 50

coin-value(k: 3): v |> std/io:print.ln("{{ v:d }}")
