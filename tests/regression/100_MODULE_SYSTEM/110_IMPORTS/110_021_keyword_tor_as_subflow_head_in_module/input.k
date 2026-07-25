// A keyword tor (`cond`, `if`, `for`) is a keyword everywhere it is imported —
// including as a subflow's DEFINITION HEAD inside a module, which is the
// position this pins. `app/pick` is a plain `.k` module that never names
// std/control: `pick = cond(n)` has to resolve from the bare name alone.
//
// Keyword resolution is scoped by the ENCLOSING module, not by entry-file-ness.
// Canonicalization stamps every bare path with its own module's name, so that
// stamp is what says "the user wrote this bare" — read against the entry module
// instead, every module's own flows look explicitly qualified and are skipped.
// The `~lib_a:process` case that must still be skipped is pinned by 120_002.
//
// What it buys: an app can be split into modules. Every per-page key vocabulary
// in a TUI is `name = cond(ch)`, so without this the flow vocabulary — most of
// what an app is — has to stay in the entry file, even though value tors
// already modularise fine.
import std/io
import app/pick

app/pick:pick(n: 2): v |> std/io:print.ln("v={{ v:d }}")
