// PINS the wall that 510_114 pins, on the OTHER path.
//
// 510_114 pins `get-input => nope "hi"` at item position — an `immediate_impl`,
// caught by flow_checker.checkImplMatchesDecl. Its header memorialises the leak
// that used to happen there: Zig's `no field named 'nope' ... in union
// 'get_input_event.Output'`, reported against output_emitted.zig, a file the
// author never opened.
//
// The SAME construct nested inside a flow arm still leaked that way until
// 2026-08-04, because the wall was installed on one of the two paths that can
// reach it. `=>` versus `|>` is decided by the delimiter alone (parser.zig:7696
// — "delimiter is authoritative; parseStepKind never guesses from content"), so
// a wrong name arrives here preserved verbatim as a branch name; shape_checker
// had the wall for effect resume-arms (with a comment saying an unknown arm
// would otherwise "sail through to a raw Zig error in the emitted union
// construction") and fell through to a TODO for ordinary outcome branches.
//
// THE ASSERTION THAT MATTERS IS `NOT_CONTAINS output_emitted.zig`. A Koru
// diagnostic naming the author's own tor is the pin; a Zig union error about
// generated code is the regression, and it is the shape that gets misfiled as a
// language limitation rather than a missing check — which is exactly how it was
// misfiled the day this test was written.
//
// Belief: concepts/frag-a-fix-lands-in-one-lowering-path.md
import std/io

pub tor divide { a: i64, b: i64 }
| ok i64
| divzero

divide = if(b == 0)
| then => divzero
| else => nosuchbranch 7

divide(a: 84, b: 2)
| ok q |> std/io:print.ln("q={{ q:d }}")
| divzero |> std/io:print.ln("divzero")
