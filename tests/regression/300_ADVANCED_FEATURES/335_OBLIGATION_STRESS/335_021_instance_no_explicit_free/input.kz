// PINS: the two arms settle the same `<instance!>` obligation differently and
// both are legal — the `| ok` arm calls `std/string:free` explicitly, the
// `| err` arm leaves `owned` undischarged and auto-discharge inserts the same
// `free` there.
//
// The sibling half of 335_020: `free` is the only discharger `<instance!>` has,
// because `std/string:release` is a bare-return transfer that re-issues an
// obligation on the same resource and so is filtered out of the candidate set
// (auto_discharge_inserter.zig:2511). One candidate means no ambiguity to
// report — on either arm, happy or error.
~import std/string
~import std/io

~std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/string:append(s: owned, text: " world")
        | ok |> std/string:read(s: owned): text |> std/io:print.ln(text) |> std/string:free(s: owned)
        | err _ |> _
| err _ |> _
