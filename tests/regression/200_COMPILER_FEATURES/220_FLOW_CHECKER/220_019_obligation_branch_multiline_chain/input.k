// PIN: an OBLIGATION branch's `|>` pipeline (`| ok s |> ...`) spread over
// multiple EQUAL-INDENT lines must compile and run identically to its inline
// sibling on the same branch. Ground truth for the pieces: the obligation
// shape `std/string:from-page(...) | ok s |> std/string:read(s): text |> ...
// |> std/string:free(s) | err _ |> _` is exactly 610_001_string_basic's shape
// (green); the equal-indent multi-line `|>` continuation is exactly
// koru_std/compiler.kz's `~analysis = check-release-gate |> check-structure
// |> ... |> check-purity` shape (green — it's the live compiler pipeline).
// Neither piece is novel; only the combination — a multi-line chain living
// INSIDE an obligation branch rather than at bare flow-head (220_018) or
// under a store-watch effect branch (220_017) — is untested.
//
// This is the sibling-form seam (inline <-> multi-line) at a THIRD context:
// obligation. It localizes the shared multi-line `|>` continuation bug
// (SHAPE002 implemented independently in shape_checker.zig:1963 and
// flow_checker.zig:1169-1187, per 220_017/220_018) to a third branch kind,
// and additionally surfaces a WORSE symptom here: the SHAPE002 diagnostic
// text is never printed at all on this path — koruc exits 1 with a bare
// `error: DuplicateBranchHandler` and a raw Zig stack trace
// (flow_checker.FlowChecker.checkDuplicateBranchHandlers), no koru-level
// message, no location, no advice. The inline form of the identical three
// steps on the same `| ok s` branch compiles and prints a/b/hello.
//
// RESIDUAL: today the multi-line form crashes out with the bare Zig trace
// above instead of running; pins the desired unified behavior — one rule for
// multi-line `|>` chains everywhere, surfaced as a koru-level diagnostic if
// ever rejected on purpose (same ruling 220_017/220_018 pin).
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:read(s): text
    |> std/io:print.ln("a")
    |> std/io:print.ln("b")
    |> std/io:print.ln("{{ text:s }}")
    |> std/string:free(s)
| err _ |> _
