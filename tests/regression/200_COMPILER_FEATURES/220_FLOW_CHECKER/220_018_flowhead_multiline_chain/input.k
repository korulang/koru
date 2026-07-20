// PIN: a `|>` pipeline chain spread over multiple EQUAL-INDENT lines at the
// bare FLOW HEAD (no effect branch, no subflow, no store) must compile and run
// identically to its inline sibling `A |> B |> C`, which is green everywhere.
// This is the sibling-form seam inline<->multi-line at position 0 — the most
// basic context there is. It localizes the 220_017 divergence to the pipeline
// continuation itself: the SHAPE002 multi-line reject is NOT specific to `!`
// effect-branch arms (220_017) — it fires at a plain top-level chain too, so
// the drift lives in the shared multi-line `|>` continuation handling, below
// any branch context. Pins the desired unified behavior: one rule for
// multi-line `|>` chains everywhere (same ruling 220_017 pins).
//
// RESIDUAL: today this false-rejects at flow_check:4:0 with SHAPE002
// ("duplicate handler for branch '' ... indent it further"); the inline form
// of the same three steps compiles and prints a/b/d. Root shared with 220_017:
// SHAPE002 implemented independently in shape_checker.zig:1963 and
// flow_checker.zig:1169.
import std/io

std/io:print.ln("a")
    |> std/io:print.ln("b")
    |> std/io:print.ln("d")
