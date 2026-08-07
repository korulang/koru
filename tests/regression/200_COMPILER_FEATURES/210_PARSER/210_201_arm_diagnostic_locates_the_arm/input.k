// ASPIRATIONAL, RED ON PURPOSE (2026-08-04). Flips to green when a flow
// continuation carries its OWN source location.
//
// A refusal aimed at an arm points one line PAST the arm — here at the blank
// line after the flow, column 0, so the caret underlines nothing. The
// diagnostic is otherwise correct: right file, right tor, right branch name
// (510_119/120/121 pin that wall on the three paths that reach it).
//
// CAUSE, and it is why this lives in 210_PARSER rather than beside those pins:
// a flow continuation's location is stamped with the parser's CURRENT cursor
// position at the moment the continuation struct is built — which is after the
// arm's text has been consumed. So every continuation records where the parser
// had got to, not where the arm is. Nothing is off by one in the arithmetic;
// the value was never the arm's line to begin with. Fixing it means capturing
// the arm's line BEFORE consuming it, at the site that builds the struct.
//
// WHY THIS ASSERTION AND NOT AN AST TEST. Neither serializer can express it:
// `--ast-canon` strips locations as trivia by design (it is the tree-equality
// surface for the printer round-trip), and `--ast-json` never emitted a
// continuation location at all. So the only surface that can see this value is
// the rendered diagnostic, and `ERROR_AT` is the assertion for it.
//
// SECOND WITNESS, 2026-08-07 — this is not only an arm problem, and not only
// KORU021. Writing a real app (koru-examples kopium-headless) produced:
//
//     tor send { req: string }
//     send = recall(): auth |> multi.new() |> multi.add.post(url: ..., body, ...) |> multi.start()
//     | started p |> await(p)
//
//     error[KORU080]: 'multi.add.post' requires input 'body'
//       --> live.k:61      <- the `| started` line. The fault is on line 60.
//
// A whole chain on ONE physical line, so every stage's continuation records the
// same stale cursor — which by then has reached the line AFTER the chain. The
// caret lands on the first branch arm and the author reads it as a problem with
// the arm. Reproduced minimally: the identical chain written across three lines
// reports the CORRECT line, so the defect needs stages to share a line.
//
// That widens the blast radius twice over. It is not specific to arms (this
// case is a mid-chain call), and it is not specific to KORU021 (this is
// KORU080) — any diagnostic that resolves through a continuation location
// inherits it. `ast.Invocation` carries no location of its own, which is why
// every consumer has to borrow the continuation's.
//
// It cost three rebuild cycles in the app before the error was read as anything
// other than a complaint about `multi.start()`. Keeping that measurement here
// because it is the argument for the fix: the value is not merely imprecise,
// it points at working code.
//
// NOT MARKED `TODO`. A TODO file makes the harness return before running the
// test, so a TODO-marked aspirational test pins nothing and would not flip when
// the cause is fixed. Red is the honest state, and red is what flips.
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
