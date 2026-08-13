---
type: belief
id: frag-a-scope-must-describe-its-own-vocabulary
provenance: 430_057 — scope-vocabulary, the enumeration surface for a model driving the interpreter
ts: 2026-08-13
---

# A scope must be able to describe its own vocabulary at runtime; the prompt and the enforcement are the same bytes (belief)

Every runtime lookup a scope exposed was event-KEYED: `get-scope` answered
"what does THIS verb consume, what does it issue" only if you already knew the
verb's name. There was no way to enumerate — to ask a scope what it holds. For
a language model driving the interpreter, that is fatal: the model must be told
what it may call, and if that description is hand-typed English beside a
`register` block, the two halves drift and only `event-denied` catches it at
runtime. The fix is structural, not editorial: a scope renders its own
vocabulary (`name(arg: type<!obligation>)`, one line per event) from the same
compiled descriptor the interpreter dispatches against. The model's prompt and
the enforcement are the same bytes; there is no second source of truth to keep
in step.

The argument-vocabulary half was the missing piece, not the names: branch specs
describe OUTPUT shapes, so plain input args (`path`, `text`) lived nowhere at
runtime — only handle args appeared in the obligation specs. The input shape
(`ed.input.fields`) had to be captured into the compiled descriptor for the
vocabulary to be truthful about `open(path: string)`.

What would correct this: the interpreter gaining a separate, hand-maintained
tool schema (the JSON-schema route), where the prompt comes from somewhere other
than the declaration the compiler enforces — then "same bytes" is false and this
belief is stale.

Related: [[frag-two-parse-paths-feed-one-dispatch]] — the other half of "an
interpreter fed by a language model gets garbage-in routinely; make the
diagnostics and surfaces honest."