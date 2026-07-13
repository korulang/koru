// Pins in-flow compiler-annotation capture: a `[...]` compiler annotation on a
// PIPED chain step must be peeled and attached to that step's invocation
// (Invocation.annotations), exactly as the flow-head path already does for the
// `[with]` on 641_010's grammar opener. The annotated step still executes; the
// annotation is metadata the resolver acts on. This is the parser capability
// that unlocks multi-source `[with]` resolution — several `[with]`s in one
// subtree, each opening a module, with the collision case forcing an explicit
// pick.
//
// RESIDUAL: today the chain-step classifier (src/parser.zig:7162
// `looksLikeInvocation`) sees the leading `[` and can't recognise an annotated
// step, so it falls through to KORU103 ("`|>` cannot introduce a value"). The
// fix is to peel a leading `[...]` annotation before classifying, mirroring the
// flow-head path — there is no genuine ambiguity: `[ident]` immediately followed
// by an invocation path is unmistakably an annotated step.
import std/io
std/io:print.ln("head") |> [with]std/io:print.ln("captured")
