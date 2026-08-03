// PIN — a `|>` chain in a subflow body written on the line AFTER `=` keeps
// every step. Measured 2026-08-03: it kept only the FIRST.
//
// This is a SILENT MISCOMPILE, not a diagnostic gap. The same chain returns
// 12 written inline (`go = bump(x: 3): d1 |> bump(x: d1): d2 -> d2`) and 6
// written across two lines. No error, no warning — the tail steps are simply
// discarded by the parser and the flow produces the head step's value.
//
// parser.zig:6114 already states the invariant this pins: "multi-line pipe
// chain parses EXACTLY like its inline spelling — the same stitch the `=`
// subflow body applies. ONE rule for `|>` chains everywhere." The `=`
// subflow body was the one place that did not apply it: its multi-line
// branch parsed the whole body line as a single invocation and never split
// the pipeline, while its same-line branch scans for a depth-0 `|>` first.
//
// The corpus had exactly ONE user of the shape (110_006's helper.kz) and it
// was red — reported as `KORU100 unused binding 'd1'`, which is TRUE of the
// tree the parser built and false of the program the author wrote. A wrong
// tree makes an honest checker lie; that is why this pins the VALUE and not
// the diagnostic.
import std/io

tor bump { x: i64 } -> i64
proc bump|zig { return x * 2; }

// Two steps: 3 -> 6 -> 12. A dropped tail yields 6.
tor go {} -> i64
go =
    bump(x: 3): d1 |> bump(x: d1): d2 -> d2

// Three steps: 1 -> 2 -> 4 -> 8. A dropped tail yields 2.
tor deep {} -> i64
deep =
    bump(x: 1): a |> bump(x: a): b |> bump(x: b): c -> c

go(): r |> std/io:print.ln("go={{ r:d }}")
deep(): s |> std/io:print.ln("deep={{ s:d }}")
