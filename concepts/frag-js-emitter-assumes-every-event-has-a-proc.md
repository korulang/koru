---
type: belief
id: frag-js-emitter-assumes-every-event-has-a-proc
provenance: first measured JS baseline (100 of 175 on NoJsProcBody); re-measured 2026-08-06 on the host-fixture wave, where the SECOND refusal family behaved the same way — one construct, metatype_binding, held 13 of the 32 residual failures in one 81-test slice and 4 more across three others
ts: 2026-08-06
---

# The JS emitter fails in FAMILIES, and each family is one assumption

The JavaScript target was understood as immature-in-general: a ~310-line
emitter covering a narrow slice of constructs, with the spike's own
"KNOWN NARROWNESS" list naming half a dozen unsupported shapes. The implied
model was breadth — many small gaps, each worth a few tests, closed by
grinding through the list.

The first measured baseline contradicted that. Scanning the 220 tests whose
failures can only be the emitter's, 45 passed and 175 failed — and **100 of
those 175 failed on a single cause, `NoJsProcBody`.** Of those 100, **94
declared no local proc at all**: their events are implemented by a
**subflow**, and the emitter treated a missing `|js` proc body as fatal
rather than looking for the flow that implements the event.
`020_014_pure_subflow_impl` states the case in its own first line: *"Pure
subflow implementation (no proc needed)."*

The original form of this belief was "the ceiling is ONE wrong assumption,
not the length of the unsupported-construct list." The second measurement
says that was half right, and the wrong half is the interesting one. **The
unsupported-construct list is load-bearing too — and it is concentrated in
exactly the same way.** Porting host fixtures across six slices exposed the
next population, and one entry, `metatype_binding` (the `~tap(x -> *) |
Profile p |> log(p.source)` arm), held **13 of the 32 residual failures in
one 81-test slice**, plus 4 more in three other slices. Not a long tail.
One case, thirteen tests, forty lines to close.

So the durable form is not "one assumption underneath everything" but:
**the emitter's failures arrive in families, each family is one missing
assumption, and the family-size distribution is violently heavy-headed at
every level you cut it.** That is a claim about how to WORK the target, and
it is the opposite of the narrowness list's advice. Never grind the list.
Measure, sort by family, take the head, re-measure — the second-largest
family after a fix is routinely a different kind of thing from the first,
and the ordering cannot be predicted from reading the emitter.

**The corollary that cost the most to learn: a fixture wave cannot see its
own ceiling.** The host-fixture wave was framed as decision-free porting
work — write `.kjs` facets, no compiler changes. That frame is honest for
the head of the distribution and structurally blind after it: **no fixture
can supply a construct the emitter refuses.** In the measured slice, `.kjs`
files carried 0 → 49 of 81 and then stopped dead, and the next 11 came from
forty lines in `emitVoidStatementNode`. Both numbers are real and they are
different kinds of progress; a wave that reports only the blended figure
cannot tell a contestant who ran out of fixture work from one who ran out of
emitter. Any porting campaign against a young target needs a standing
escape hatch — a way for a contestant to say "this one is not mine" and have
it counted — or it will silently report the emitter's refusal set as the
corpus's difficulty.

The methodological point from the first measurement still stands and is
reinforced. This gap was **visible in the tree for weeks** — `koru_std/args.kjs`
carries a dated note (2026-07-04) about the emitter never reading
`return_type` — and nobody knew what it was worth, because nothing counted.
The gap did not need discovering; it needed **weighting**. A frontier that is
measured tells you which known gap is load-bearing, and that is a different
service from finding unknown ones.

Open question, unchanged and now sharper: whether subflow-implemented events
want the emitter to synthesise a proc-shaped body from the flow, or whether
the emit path should dispatch to flows and procs through one seam so the
distinction never reaches codegen. The Zig emitter's answer is not
automatically the right one to copy — it has had far longer to accrete
special cases, and this is the rare moment where the second target can pick
the cleaner shape before it has anything to preserve. `metatype_binding` is
the small worked example of that choice going well: Zig spells a
Transition's `source`/`branch` as generated enum literals and Profile's as
strings, an artefact of Zig having enums; JavaScript does not, so all three
are strings, matching the tag vocabulary the emitter already uses. Copying
the Zig shape would have carried a host accident into a target that never
had it.
