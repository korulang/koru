---
type: belief
id: frag-js-emitter-assumes-every-event-has-a-proc
provenance: first measured JS baseline (docs/js-parity/baseline-2026-08-06.json) — one cause, NoJsProcBody, accounts for 100 of 175 failures across the emitter-testable population
ts: 2026-08-06
---

# The JS emitter's dominant gap is one structural assumption, not missing breadth

The JavaScript target was understood as immature-in-general: a ~310-line
emitter covering a narrow slice of constructs, with the spike's own
"KNOWN NARROWNESS" list naming half a dozen unsupported shapes. The implied
model was breadth — many small gaps, each worth a few tests, closed by
grinding through the list.

The first measured baseline contradicts that. Scanning the 220 tests whose
failures can only be the emitter's (fixture host code and stdlib gaps both
excluded), 45 pass and 175 fail — and **100 of those 175 fail on a single
cause, `js_emitter.emit failed: NoJsProcBody`.** Of those 100, **94 declare
no local proc at all.** Their events are implemented by a **subflow**, and
the emitter treats a missing `|js` proc body as fatal rather than looking
for the flow that implements the event. `020_014_pure_subflow_impl` states
the case in its own first line: *"Pure subflow implementation (no proc
needed)."*

The belief this leaves us with: **the JS emitter's ceiling is one wrong
assumption — that every event is implemented by a proc — and not the length
of its unsupported-construct list.** Subflow implementation is not an exotic
corner of Koru; it is a primary way events get bodies, which is why one
assumption swallows 43% of the emitter-testable corpus. Breadth work on the
narrowness list would have moved the number by single digits while this sat
underneath it.

The methodological point is the more durable half. This gap was **visible in
the tree for weeks** — `koru_std/args.kjs` carries a dated note
(2026-07-04) about the emitter never reading `return_type`, an adjacent
symptom of the same area — and nobody knew what it was worth, because
nothing counted. The gap did not need discovering; it needed **weighting**.
A frontier that is measured tells you which known gap is load-bearing, and
that is a different service from finding unknown ones.

Open question: whether subflow-implemented events want the emitter to
synthesise a proc-shaped body from the flow, or whether the emit path should
dispatch to flows and procs through one seam so the distinction never
reaches codegen. The Zig emitter's answer is not automatically the right one
to copy — it has had far longer to accrete special cases, and this is the
rare moment where the second target can pick the cleaner shape before it has
anything to preserve.
