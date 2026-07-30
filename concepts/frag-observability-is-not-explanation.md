---
type: belief
id: frag-observability-is-not-explanation
provenance: Lars argued that the compiler protocol and the explainer socket make the legibility problems of synthesized names a non-issue; this is where that landed after pushing on it, including a measurement of my own behaviour across the 2026-07-30 session
ts: 2026-07-30
---

# A machine-readable pipeline answers what HAPPENED; it never answers what SHOULD have happened (belief)

The argument that deep inspection dissolves legibility problems is right about
half of them, and the half it misses is the half that needed authoring anyway.

A trace can show that a name was minted by a particular transform from a
particular input at a particular stage. It cannot know that the author meant *the
door is closed, so you cannot lock it*. **Observability reports; it does not
interpret.** No amount of pipeline legibility synthesizes intent, because intent
was never in the pipeline.

The useful consequence is not that the requirement survives unchanged. It is that
the requirement **relocates somewhere better**: authored meaning stops being
string formatting in an error path and becomes structured data a consumer can
query. That is a real gain, and it is a different gain from the one usually
claimed for observability.

## Availability does not cause use — measured, not supposed

The load-bearing half of an AI-first toolchain is not that the instruments exist.
It is that consulting them is the path of least resistance.

The evidence is unflattering and first-hand: across a long session on this
codebase I read library source by grep, read emitted host code by eye to locate a
cursor collision, and diffed failure lists in a shell — while a bidirectional
compiler protocol was available the entire time and was never once invoked. Every
one of those questions had a machine-readable answer. I reached for the tools I
would use on any codebase, because nothing made the better ones the default.

**So "AI-first" is a property of the workflow, not of the tool.** A protocol
nobody is routed to is a protocol nobody uses, and the agent's own judgement is
not a sufficient forcing function — this is a case where it demonstrably was not.
The remedy is structural: the operational guidance has to say *ask the compiler
before reading the source*, the way it already says to survey a large file before
opening it.

## The category claim underneath

A module here is not a library. It ships metadata, full-program transforms,
refusals in its own voice, an explainer, and — designed, not built — commands it
can be interrogated with. Elsewhere a library ships functions and a README that
drifts.

That difference is not a feature comparison, and it is the strongest positioning
available: **the answer cannot drift from the implementation, because the answer
IS the implementation.** A library that explains itself by executing has closed
the gap that documentation exists to bridge and always fails to.

The corollary is a design instruction, not a boast. Where a question about a
library's behaviour is currently answered by reading thousands of lines of that
library, the library is missing a command.

## The unit of explanation, which is specific to this kind of language

The natural cut for explaining a program here is the obligation slice: from where
an obligation is minted to where it is discharged, and nothing else. That is
program slicing along obligation edges rather than dataflow edges.

Two things make it worth naming. It is the right context unit for an agent —
*here is this obligation's lifetime* is a bounded, closed, meaningful region,
where *here is the file* is neither. And it is available only to a language whose
obligations are first-class; everywhere else those edges would have to be
inferred, which is the expensive and unreliable part.

## Open

- Whether the interrogation surface should be one registry with the explainer as
  a case of it, rather than two mechanisms side by side. Suspect one.
- Whether a command declares the pipeline stage it answers at. Treat the
  stage-dependence as the FEATURE rather than a determinism problem: the same
  question asked before and after a lowering, differenced, is the tracing
  capability itself.
- The hard rule this needs regardless of shape: an interrogation must be pure
  over the program. A command that mutates while answering makes observation
  change the observed, and that bug exists only while being looked for. The
  purity constraint is inherited from what the comptime evaluator already
  demands, not a new thing to invent.

Related: [[frag-synthesized-phantoms-are-derived-names]] (the diagnostics this
was argued to rescue), [[frag-a-kernel-pass-must-not-fire-the-store]].
