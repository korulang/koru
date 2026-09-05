// PINS: a `*String<instance!>` has exactly ONE discharger, so auto-discharge
// settles it silently and the program runs.
//
// `std/string:free` (koru_std/string.kz:89, `s: *String<!view|!instance>`) is
// void, so it can be inserted at scope exit. `std/string:release`
// (koru_std/string.kz:78) also accepts `<!instance>` — but it is
// `-> *String<view!>`, a bare-return transfer that hands back a NEW obligation
// on the same resource. Calling it settles nothing, and the inserter's own
// filter (auto_discharge_inserter.zig:2511) refuses any candidate carrying
// output, exactly as 330_118 asks: candidates are chosen by EFFECT, not by
// signature.
//
// So there is no ambiguity to report. `owned` leaves both the `| ok` and the
// `| err` arm in `<instance!>`, auto-discharge inserts `free` on each, and the
// handle print below happens before either (610_007: `read` retired).
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/string:append(s: owned, text: " world")
        | ok |> std/io:print.ln("{{ owned:S }}")
        | err _ |> _
| err _ |> _
