---
type: belief
id: frag-a-generated-artifact-can-be-shaped-right-and-say-nothing
provenance: fixing the `__test__.kz` dialect bug 2026-08-07 — the test harness emitted the right number of correctly-named `test` blocks, every one of them empty, and reported them as passing for months
ts: 2026-08-07
---

# A generated artifact can have the right shape and no content (belief)

A code generator is checked, in practice, by asking whether it produced the
thing. Did the blocks appear? Are they named correctly? Is the count right? All
three can be yes while every block is **empty**, and nothing downstream is
positioned to notice, because each downstream check is asking about structure.

The instance: test bodies were re-parsed under an invented filename whose
extension declared the wrong language. Every line of a `.k` body then parsed as
host text, so no mock and no flow were collected — and the emitter dutifully
produced correctly-named `test` blocks containing nothing. `zig test` ran them.
They passed. Passing zero assertions is what passing zero assertions looks like.

## Why it survives longer than a malformed artifact

A generator that emits *garbage* is caught immediately: the next tool refuses
it. A generator that emits a well-formed skeleton is accepted by every
consumer, and the only thing that would notice is a reader comparing the output
against the input's *meaning* — which is exactly the comparison nobody automates,
because automating it is most of the way to writing the generator twice.

So the failure has an unusual signature: **more machinery downstream makes it
less likely to be caught, not more.** Each additional consumer validates shape
and passes it along, and the chain of green checks reads as corroboration.

## The rule

For anything generated, the test is never "did it appear" — it is **"does it
contain the thing that makes it worth having"**. For a test block, an assertion.
For a dispatcher, a case per event. For a manifest, an entry per subject. Count
the payload, not the container; a container count is a measure of the generator's
plumbing, and plumbing is the part that was never in doubt.

Corollary, and it is the practical one: when a generated artifact is committed
to a repo, a reader can see this in seconds and no tool can. That argues for
checking in a sample of generated output where the emptiness would be visible —
which is what a regression suite's `output_emitted.zig` already is, if anyone
reads it.

Related: [[frag-a-check-that-cannot-match-reports-clean]] — the consumer-side
twin. There a check ran and could not match; here the artifact was faithfully
produced and had nothing in it to match against. Both report clean, and clean is
what an empty world looks like from the inside.
