// Pins in-flow compiler-annotation capture: a `[...]` compiler annotation on a
// PIPED chain step is peeled and attached to that step's invocation
// (Invocation.annotations), exactly as the flow-head path does for the `[with]`
// on 641_010's grammar opener. The annotated step still executes; the annotation
// is metadata the resolver acts on. A leading `[` never begins a valid bare step
// otherwise (looksLikeInvocation requires an identifier start), so there is no
// ambiguity. This is the parser capability behind multi-source `[with]`
// resolution — several `[with]`s in one subtree, each opening a module.
import std/io
std/io:print.ln("head") |> [with]std/io:print.ln("captured")
