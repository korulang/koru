---
challenge: comptime-stdlib
kind: frame
status: standing
yields: one duplicated comptime mechanism promoted to a first-class std surface, every prior copy converted, and a wall that keeps it that way
family: toolchain
---

*Walker context — the recurrence that earned this generator. koru's comptime
transforms have no stdlib. Each one hand-rolls the machinery it needs, so the
same mechanism exists N times with N-1 chances to drift, and the copy nobody
wrote yet is always the broken one. Measured, not felt: `errItem` is defined
**nine times** inside `store.kz` alone; the effect-Handlers dance is implemented
**three** times (`emitFlow`, `emitContinuationBody`, and a third added
2026-07-28 — knowingly, by an agent that had diagnosed the duplication four
hours earlier and still had no shared surface to reach for); `koru_std` carries
**72** literal `@compileError` sites and **120** `errItem` calls. The 2026-07-28
session found five compiler gaps with one app, and the two deepest were a
lowering that knew exactly one call shape.*

*This is 008's inverse. 008 writes a transform nobody has written and reports
what the surface LACKS, outward. This one takes what already exists in
duplicate and makes it ONE thing, inward — 008's "what a library could hand you"
bucket is this challenge's input. Run 008 to find the absence; run this to close
it.*

*⚖️ Duplication is NOT the sin here, and a contestant who reads it that way will
build the wrong thing. Copying is what velocity costs: you are mid-inhale, the
shared surface does not exist yet, and stopping to build it every time is how a
session dies. The copies are supposed to happen. **This frame is the exhale** —
the scheduled herding of what the fast work left scattered, run on its own clock
rather than as a tax on every commit. So it is never a judgement on the author
who copied (usually us, often knowingly, and right to). It is the other half of
a two-stroke method, and the only real failure mode is never running it.*

---

## The brief (sealed — you are the contestant)

Find a mechanism that koru's comptime transforms implement **more than once**.
Promote it to a **first-class std surface**. Convert **every** existing copy.
Then build the **wall** that fails when a new copy appears.

Do not ask which mechanism. Count them, pick one, ship it.

## Why this challenge exists

A comptime transform in koru is a program that writes programs, and it is
written with no library. So every transform author re-derives: how to report an
error, how to rewrite an `entity.` path, how to synthesize an event plus its
proc, how to thread a row cursor into a transplanted body, how to hand a callee
its effect handlers. The result is not merely repetitive — it is **divergent**.
The copies do not stay equal. One learns about cross-module qualification and
the others do not; one honours the `[!]` preferred-discharge annotation and the
other counts candidates and gets the annotated case wrong.

That is the actual defect this challenge attacks. Duplication is the mechanism;
**silent divergence between copies is the damage.**

## Ground yourself FIRST — count, do not guess

Before you choose, measure. The catalog you diverge from is the codebase itself.

```
grep -c "@compileError" koru_std/*.kz
grep -c "fn errItem" koru_std/*.kz
grep -rn "mirror\|same dance\|same move\|same rule\|twin\|as .* does" koru_std/*.kz src/*.zig
```

That last grep is the highest-yield one, and it is not a trick: **the copies are
usually commented as copies.** `emitContinuationBody` says it is "mirror[ing]
emitFlow's top-level dance." The sweep's rewrite says it is "the same rewrite
query runs at store.kz:1481." An author who knows they are copying says so. Read
those comments as a work list.

Pick a mechanism that has **not already been promoted**. Check `koru_std/` for
an existing shared surface before you build a second one — promoting the same
thing twice is this challenge failing at its own subject.

## ⚖️ VARIANCE IS THE METRIC

Replays are only productive if they differ. Diagnostics, path rewriting, event
synthesis, cursor threading, handler synthesis, module qualification, phantom
parsing at a transform boundary — these are different organs. Two replays that
both promote "error reporting" have produced one result and one duplicate.

Name the mechanism in one line before you start. If that line already describes
a promoted surface, pick again.

## What "first-class" means here — the bar

A surface is first-class when a transform author reaches for it **instead of**
re-deriving, and cannot silently do otherwise:

- **It is spelled in koru, not smuggled.** A transform declares what it needs
  (`reporter: *std/compiler:ErrorReporter` is the worked precedent, 220_027) and
  receives it. A helper that must be `@import`ed from Zig by hand is a step
  forward, not a first-class surface.
- **It speaks koru's own error voice.** A promoted mechanism that still emits a
  spliced `@compileError` has moved the duplication without removing the damage —
  a Stage-D host error the analysis passes talk over. KORU160 is the precedent.
- **It has ONE definition.** Not "a canonical one plus the old ones." If a copy
  survives, name it in the report and say why it could not be converted.
- **Its guarantees are pinned.** A regression test the surface owns, so the next
  author inherits the contract rather than the folklore.

## ⚖️ THE WALL IS THE DELIVERABLE

Extraction without a wall decays. The copy comes back, because the next emission
path is written by someone who never saw your work and had no way to be stopped.

So every replay ships a **wall**: a check that fails when a new copy appears, or
when a site that should use the surface does not. Precedent is prose-check wall
D — *"all koru_std comptime transforms accounted for by the mirror wall (55
rows)"* — an enumeration that forces accounting rather than trusting memory.

The wall may be a `MUST_ERROR` test, a `scripts/` check wired into the suite, or
a mirror-wall row. It may not be a comment asking future authors to be careful.

If the mechanism genuinely cannot be walled, that is a finding: say so, say what
would have to exist first, and pin the gap.

## THE REPORT — two buckets, same split as 008

Every replay files what it learned, sorted:

1. **Promoted** — the mechanism, the count before (N copies) and after, the
   sites converted, the wall that holds it, the divergences you found between
   copies while converting. **The divergences are the valuable half.** Every
   place two copies disagreed was a live or latent bug; say which.
2. **Refused promotion** — what you could not unify and why. Distinguish "these
   two only look alike" from "these are the same thing and the language cannot
   express the shared form yet." The second is a language finding and belongs in
   a pin.

## Done-gates — self-check ALL of these before claiming finished

- [ ] The mechanism is named in one line, and that line does not describe an
      already-promoted surface.
- [ ] The count is real: N copies before, stated with `file:line` for each.
- [ ] The surface exists, is reachable the way koru reaches things, and speaks
      koru's error voice where it reports.
- [ ] **Every** counted site is converted, or the survivors are named with
      reasons.
- [ ] A wall exists and **fails when you plant a fresh copy** — plant one and
      watch it fail before you delete it. A wall never observed failing is a
      wall you are guessing about.
- [ ] The suite is green on a clean `--no-cache` sweep, run AFTER the last
      change, with the board delta stated.
- [ ] Any divergence found between copies is pinned as a test, whether or not it
      was already fixed by unification.
- [ ] The report is filed with both buckets.

## ⚖️ THE HARD STANCE

**Do not promote by widening.** A surface that grows a flag per caller so every
old behaviour survives has re-created the copies inside one function and made
them harder to see. If two sites genuinely need different behaviour, that is a
refusal — file it in bucket 2.

**Do not convert a site you cannot test.** A converted site with no coverage is
a claim, not a change. Pin it first if it has no pin.

**The board is the referee.** A promotion that moves the board down has not
simplified anything; it has broken something and hidden it behind a tidier
shape. Report the number.

## What survives

The promoted surface, its wall, its pins, and the report. The copies are gone —
that is the point, and `git log` remembers them for anyone who needs to know
what the shape used to be.
