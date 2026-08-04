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
