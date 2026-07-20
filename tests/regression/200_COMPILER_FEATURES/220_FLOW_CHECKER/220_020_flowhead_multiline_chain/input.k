// MULTI-LINE `|>` FIX-LOCK — a `|>` pipeline chain spread over multiple
// EQUAL-INDENT lines at the bare FLOW HEAD (no branch handler enclosing it).
// Pins that the multi-line equal-indent continuation compiles and runs
// identically to its inline sibling `A |> B |> C`.
//
// Sibling of 220_017 (effect `!`) and 220_024 (obligation `|`), which pin the
// same multi-line `|>` shape under branch handlers. The branch-handler forms
// were a real SHAPE002 misparse (the duplicate-branch-handler check read the
// continuation lines as duplicate same-level handlers, implemented independently
// in shape_checker.zig and flow_checker.zig); that check was unified and the
// misparse fixed. This trio now GUARDS that fix — one rule for multi-line `|>`
// continuation everywhere, flow-head and inside branch handlers alike. If any of
// them regresses to a SHAPE002 reject, the unification has come undone.
import std/io

std/io:print.ln("a")
    |> std/io:print.ln("b")
    |> std/io:print.ln("d")
