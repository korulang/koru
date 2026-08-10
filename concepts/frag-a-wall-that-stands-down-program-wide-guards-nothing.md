---
type: belief
id: frag-a-wall-that-stands-down-program-wide-guards-nothing
provenance: probing whether Koru can compile a scaffold — an application written as high-level flow with its boxes still empty — 2026-08-10; four programs measured, and the one carrying a test block built clean and printed a fabricated `0`
ts: 2026-08-10
---

# A wall whose stand-down is program-wide guards nothing (belief)

[[frag-a-check-that-cannot-match-reports-clean]] describes a guard that runs and
cannot match. [[frag-a-watcher-off-the-normal-path-is-not-a-wall]] describes one
that never runs at all. This is the third shape, and it is the hardest to see,
because the guard runs, matches correctly, and is switched off by a fact
established somewhere else in the same file — usually for a reason that is
locally impeccable.

The instance: KORU047 refuses a program that invokes an event nothing implements,
and its own comment names the stakes exactly — without it the emitter "synthesizes
a silent stub" and "the program prints a confident wrong answer at runtime." The
refusal then stands down, in full, for any program that carries a `~test` block.
That reasoning is *correct at every step*. A mock inside a test body genuinely is
an implementation; test bodies genuinely reach this pass unparsed; the pass
genuinely cannot claim "unimplemented anywhere" while it cannot see them. Each
link holds. The conclusion is that one test anywhere in a program removes the
protection from all of it, application flows included — and the exact stub the
comment warns about is what ships.

## Why the local correctness is the trap

Every reachable-condition exemption is scoped to the thing it excuses: an event
marked never-run, an event that is comptime-only, a payload the shape is not
allowed to inspect. Those narrow the wall by *one event*, and a reader can check
each one against the event in front of them.

A program-wide stand-down is a different animal wearing the same clothes. It is
written in the same list, in the same style, with the same care — and it is not
an exemption, it is an off switch. The distinguishing question is not "is this
justified?" (it usually is) but **"how many things does this excuse, and did the
author of the excused thing know?"** Here the answer is: everything, and no. A
person writing an application flow has no way to know that a test file elsewhere
disabled the check that would have caught their empty box.

## What follows

- **Scope every stand-down to the thing it excuses.** If a pass cannot see some
  implementations, it must narrow to the events those implementations could
  plausibly belong to, or defer to a point where it can see them — never disable
  itself for the whole program.
- **A check that can be turned off from a distance must say so at the site.** The
  diagnostic that would have fired is the only place the absence is noticeable,
  and it is precisely the place that stays silent.
- **Prefer moving the honesty into the emitted artifact.** A check that must
  stand down because it lacks information cannot be made honest by better
  checking; but the thing it was protecting against — the fabricated answer — can
  be made loud unconditionally at the point of fabrication, where no information
  is missing. Then the wall standing down costs a compile-time error, not a
  silent wrong answer, and the failure keeps its volume in every configuration.

## Settled by building it

The loud failure **backs up** the refusal rather than replacing it, and the two
turn out not to compete. The refusal still rejects at compile time wherever it
can see the whole picture; the emitted panic covers where it cannot. Scaffolding
— a whole application written as flow with its boxes still empty, run before
anything fills them — survives because the stand-down still permits the build; it
stops being dangerous because the empty box now announces itself.

The predicate the two readers share is the **shape** question only: would an
empty body have to invent its answer? Everything about *reachability* stayed with
the refusal, and measurement forced one more separation that reading would not
have found. `[abstract]` looks like it belongs in the shared question — an
abstract event with no implementation is exactly the thing the refusal rejects —
and putting it there breaks a working program (030_016), because an abstract
event's emitted body is a live dispatch stub resolved elsewhere, not a fabricated
answer. **"Has no implementation here" and "would lie if reached" are different
questions about the same event**, and only the second one belongs to the emitter.

## Open

Whether the loud panic should carry the *reason the box is empty* — a scaffold
compiled on purpose reads differently from an implementation someone forgot — and
whether that distinction should exist at compile time at all, as a mode the build
was asked for, rather than being inferred from what happens to be missing.
