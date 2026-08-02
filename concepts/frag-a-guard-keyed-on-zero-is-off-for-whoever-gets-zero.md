---
type: belief
id: frag-a-guard-keyed-on-zero-is-off-for-whoever-gets-zero
provenance: 2026-08-02 — the store handle brand was the declaration ordinal, so the first store declared in any program had brand 0 and its handle-validity check accepted any small integer; three green tests turned out to depend on the hole
ts: 2026-08-02
---

# A guard keyed on a tag is off for whoever draws the tag that means "no tag" (belief)

A row handle carries the minting store's brand, and every address is refused
unless its brand matches. The brand was the store's declaration ordinal, and
ordinals start at zero — so for exactly one store per program, "carries my
brand" and "carries no brand at all" were the same test, and the guard admitted
any small integer as an address.

Which store got it was decided by **source position**. Move one
`std/store:new` line above another and a safety wall that had never fired
starts firing, on unchanged logic. That is the tell for this whole family: a
guard whose strength depends on where something appears in a file is not
guarding a property, it is guarding a coincidence.

## The part that makes it expensive: features grow into the hole

This did not stay a latent bug, and that is the real lesson. Addressing a row
by a plain integer held in another store's cell — the selected-row idiom a UI
wants — was **built, pinned by tests, and used**, and it only ever worked
because the check was off. It worked for the first store declared and would
have failed for any other, and nothing said so, because nobody writes the
second store first.

So the hole was not merely unguarded space; it was **occupied**. Closing the
guard turned green tests red, and those reds are not regressions in the fix —
they are the invoice for the interval during which the wall was down. Expect
this: a disabled guard is a vacuum, and design pressure fills it. The longer it
is off, the more of the language is standing on it, and the harder it becomes
to tell "this fix broke something" from "this fix revealed what was already
broken."

The two are distinguishable, and the distinguishing question is worth naming:
*would this have worked if the declaration order had been different?* If no,
the feature was never real, and what the fix broke was an illusion.

## What follows

- **Never let a tag's zero value be a live tag.** Reserve it, so "unset",
  "uninitialised" and "not mine" are one value that is never legitimately
  produced. The cost is one lost slot out of the tag space; the benefit is that
  the guard has no blind holder.
- **Reserving zero buys a second thing here**, and it is why this matters
  beyond the bug: it makes a dense row index and a handle disjoint as values.
  A cursor leaked into a handle position can then fail loudly rather than
  addressing an unrelated row — which is the precondition for letting the rule
  path carry a dense cursor at all.
- **A guard that can be switched off by reordering declarations should be
  tested that way.** The pin for this fix puts the vulnerable store first *on
  purpose*, because written the other way round it would pass for the wrong
  reason and never say so.
- **Position is not identity (O10.iii) cuts both ways.** The rule is usually
  invoked to stop callers treating a dense index as durable. The same rule says
  a handle is not an index — and a surface that accepts either, silently, has
  already conceded the point.

## Ruled, same day: `store[cell]` addresses by HANDLE

Lars ruled it on a general principle rather than on the case: **almost nothing
in Koru is positional, and `stored`/`captured` must not be where that gets
introduced.** That is stronger than arguing the UI case, and it decided a
question the case itself is genuinely ambiguous about — a list cursor really is
positional in most languages.

The programs then agreed. 690_075 writes through `ui.sel` and TAKES through
`ui.sel`, meaning the same row both times; under the positional reading a take
swap-removes the last row into the freed slot, so the two uses can name
different rows. Every migrated test kept its expected output byte-for-byte,
including 690_070's — the intent was identity all along and only the spelling
was positional.

**The migration cost less than the surface it was standing on suggested**, and
that is worth remembering when the next disabled guard turns tests red. The
scariest-looking casualty, `take`'s `| empty` branch, appeared to lose its only
trigger with out-of-range addressing gone. It had not: `take` resolves through
the NON-panicking lookup precisely so absence is a branch, and its own comment
already listed the family — never inserted, already taken, the -1 sentinel. A
stale handle reaches `| empty` on identity grounds, which is a better trigger
than an out-of-bounds offset ever was. The answer was in the code before the
question was asked.

**What the ruling unlocks is larger than what it cost.** With no user-facing
surface accepting a raw row index, a dense cursor becomes purely internal to a
lowering. The rule path can then carry one with nothing to leak into, so the
handle-elision rung is unconditionally safe rather than safe-if-we-can-prove-
the-body-never-observes-it. Ruling out a positional surface made a positional
*optimisation* legal.

## Open

Whether the reserved `row` ordinal a sweep arm can bind (690_069, red) survives
this principle. It hands the body a row's POSITION, which is the same thing the
ruling just refused at the addressing surface. It may be that the ordinal is
fine because it is read-only and never round-trips into an address — or it may
be the last positional surface, still open only because it was never finished.
Not examined.
