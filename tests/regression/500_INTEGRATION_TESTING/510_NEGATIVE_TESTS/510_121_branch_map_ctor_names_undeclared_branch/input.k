// The 240-shape twin: mapping ANOTHER tor's branches onto this tor's outcomes
// must still name outcomes this tor declares.
//
// This is the third reachable path to one construct, and it is the one that
// shows the defect was never about `if`. 240_subflow_defines_semantics is the
// canonical pin for this shape — `run = step() | return => stopped | ...` — and
// it establishes that branch names are inert identifiers whose meaning comes
// from the subflow that resolves them. Inert does not mean unchecked: the name
// on the RIGHT of `=>` is an outcome of the tor being implemented, and a name
// that is not one of those is a typo the author should hear about at their own
// line.
//
// All three of 510_119/120/121 produce the identical diagnostic, which is the
// point: the three paths now refuse identically instead of one refusing and
// three leaking generated-code errors.
//
// Belief: concepts/frag-a-fix-lands-in-one-lowering-path.md
import std/io

pub tor divide { a: i64, b: i64 }
| ok i64
| divzero

tor iszero { b: i64 }
| yes
| no

iszero = if(b == 0)
| then => yes
| else => no

divide = iszero(b)
| yes => divzero
| no => nosuchbranch 7

divide(a: 84, b: 2)
| ok q |> std/io:print.ln("q={{ q:d }}")
| divzero |> std/io:print.ln("divzero")
