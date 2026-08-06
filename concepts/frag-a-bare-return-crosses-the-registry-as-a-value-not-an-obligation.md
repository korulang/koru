---
type: belief
id: frag-a-bare-return-crosses-the-registry-as-a-value-not-an-obligation
provenance: closed 2026-08-06 — extractObligations now reads EventDecl.return_phantom; 410_006 mints a handle and auto-discharges where it previously asserted a PASS it never earned, and 440_001/002 run for the first time. Originally measured 2026-07-31.
ts: 2026-08-06
---

# One pass's canonical spelling was another pass's blind spot, and neither pass was wrong (belief)

**Closed.** The runtime registry's obligation extraction read create-phantoms
only off an event's declared branch payloads. A bare-return tor
(`-> T<state!>`) has no branches, so its obligation was silently absent from the
scope's tables and the interpreter ran with a pool that never heard about the
resource. `extractObligations` now also reads `EventDecl.return_phantom`; the
spec it builds is identical to the branch case, because the dispatcher reports
both on the same `__type_ref` channel.

## The part worth keeping is not the fix — it is the pincer

The reason this survived is that **the parser forces the shape the registry could
not read.** `| opened { h: string<opened!> }` is rejected outright — *"a single
continuation branch carrying a payload is a one-variant tag union — declare the
single output as a bare return instead"* — and a lone-field payload is pushed to
an identity branch. So for the single-resource-producing events obligations exist
for (open, create, acquire), the author has essentially one legal spelling, and
that spelling was the invisible one.

Neither component was misbehaving by its own lights. The parser was enforcing a
real canonicalization; the extractor was reading the shape that existed when it
was written. The defect lived in the **relation** between them, which is
precisely where nothing is tested and no one is responsible.

**The generalisation: when one pass narrows the legal spellings of a construct,
every downstream reader of that construct is silently re-scoped.** A
canonicalization is a change to what other passes will ever see, and the passes
it silences do not fail — they just stop having work to do, which reads exactly
like correctness.

## The tell we now know to look for

The corpus could not distinguish "works" from "we never wrote the legal form".
`410_003`/`410_004` were green the whole time on the *identity-branch* spelling,
and a comment in `410_004` had already recorded the gap in plain words — *"a bare
return's obligation is not seen by the registry's obligation extraction today"* —
where it sat, true and inert, for six days. A defect written down inside a passing
test is not a record; it is camouflage. The green beside it is what gets read.

Related: [[frag-a-handle-count-is-not-a-capability-check]] — found in the same
probe, one layer down: with the obligation finally visible, the pool that tracked
it still refused nothing.
