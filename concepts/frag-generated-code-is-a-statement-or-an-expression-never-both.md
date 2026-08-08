---
type: belief
id: frag-generated-code-is-a-statement-or-an-expression-never-both
provenance: continuation_codegen wrapped every transform-generated arm as `const result_N = __koru_inline_N: <code>;`. An arm that only prints never breaks with a value, so the label had nothing to label and Zig refused it. Found 2026-08-08 compiling orisha's router; fixed, and 350_010_orisha_router_showcase flipped red→green
ts: 2026-08-08
---

# Generated code is a statement or an expression, and a generator that assumes one shape breaks on the other

A code generator that emits `const result = <generated>;` has decided, on the
caller's behalf, that whatever it generated **produces a value**. That is a claim
about the generated text, and it is a claim the generator can actually check —
but only if it occurs to anyone that both kinds exist.

koruc's continuation generator wrapped every arm of a transform-built dispatch as
`const result_N = __koru_inline_N: <code>;`. The label is there because a
value-producing arm ends in `break :__koru_inline_N <value>`. An arm that merely
*does* something — a print, in a router's route handler — never writes that break,
so the emitted line was a label glued to a call expression, which Zig rejects
outright. The consequence was total: a route arm that printed could not compile,
which is most route arms anyone would write first.

**The generator already held the evidence.** The placeholder the arm must contain
to be an expression is a literal string the generator itself substitutes. Testing
for it is one `indexOf`. The bug was not missing information; it was never asking
a question whose answer was already in hand — the shape of the generated text
went unexamined because the generator was written from one example, and that
example produced a value.

Two tells, both visible in the output and both ignored for a night: the emitted
line ended in **two semicolons**, because the arm brought its own and the wrapper
added another; and `result_N` was bound but never read. Either would have said
"this text is a statement" to anyone reading the artifact rather than the error.

The general rule: **when a generator wraps generated text, the wrapper is a claim
about that text's grammatical category, and the category must be derived from the
text, not assumed from the call site.** The same applies to any splice — a value
into a statement slot, a statement into an expression slot, a block where a single
expression is expected.

Related: [[frag-a-diagnostics-hint-is-a-claim-not-a-tested-path]] — also a claim
about the language that nothing exercised. Here the untested claim was made by the
emitter about its own output.
