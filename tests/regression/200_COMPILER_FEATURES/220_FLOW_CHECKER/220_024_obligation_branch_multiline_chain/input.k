// MULTI-LINE `|>` FIX-LOCK — an OBLIGATION branch's `|>` pipeline (`| ok s |> ...`)
// spread over multiple EQUAL-INDENT lines. Pins that it compiles and runs
// identically to its inline sibling on the same branch (prints a/b/hello). The
// pieces: the obligation shape is 610_001_string_basic's shape (green); the
// equal-indent multi-line `|>` continuation is koru_std/compiler.kz's `analysis`
// pipeline shape (green — the live compiler). Only the combination — a multi-line
// chain INSIDE an obligation branch `| ok s` — is what this locks.
//
// This is the multi-line `|>` sibling-form seam at a BRANCH-HANDLER context
// (obligation `|`), the sibling of 220_017 (effect `!`) and the green flow-head
// control 220_020. The branch-handler forms were a real SHAPE002 misparse: the
// duplicate-branch-handler check (implemented independently in shape_checker.zig
// and flow_checker.zig) read the equal-indent `|>` continuation lines as
// duplicate same-level branch handlers when nested inside a branch's continuation
// list — and it crashed out with a bare Zig `error.DuplicateBranchHandler` trace,
// no koru-level diagnostic. That check was unified and the misparse fixed; this
// test now GUARDS the fix for the obligation context. If it regresses to a
// SHAPE002 reject, the branch/continuation unification has come undone.
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/io:print.ln("a")
    |> std/io:print.ln("b")
    |> std/io:print.ln("{{ s:S }}")
    |> std/string:free(s)
| err _ |> _
