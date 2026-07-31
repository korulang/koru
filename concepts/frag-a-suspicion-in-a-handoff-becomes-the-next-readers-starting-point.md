---
type: belief
id: frag-a-suspicion-in-a-handoff-becomes-the-next-readers-starting-point
provenance: the 395_010 regression, 2026-07-31 — I bisected correctly, then attached a mechanism guess to the handoff, and both halves of the guess were wrong in the same direction
ts: 2026-07-31
---

# A suspected mechanism, handed off, stops being a suspicion (belief)

I bisected `395_010`'s regression correctly: it passed on one branch, failed
after the other merge, so the culprit was certain. Then I wrote the handoff and
added what I thought was helpful — a suspected mechanism, with the reasoning
shown:

> *My first suspicion is the `partitioned_dispatch` work… you already flagged
> `395_008` as a false positive from the widening and adjusted for it; `395_010`
> is likely its sibling and the adjustment may have gone one step too far.*

Both halves were wrong, and wrong in the same direction. The agent had **never
touched or flagged `395_008`** — I had inferred that from an earlier report and
carried the inference forward as fact. And the defect was not the adjustment
going *one step too far*; it was the exact opposite. A guard had appeared at
head sites that **had never had one**, and the fix was to suppress it *more*
widely, not less.

The agent found the real mechanism anyway and corrected the record unprompted.
That is the system working. But it worked *despite* the handoff, not because of
it.

## Why a handoff is different from a note to yourself

Holding a wrong hypothesis privately costs one wasted probe, and the evidence
corrects you.

Writing one into a handoff does something else: **it becomes the next reader's
starting point.** They open the file you named, look for the shape you
described, and their attention is spent along the axis you chose. A wrong axis
does not merely fail to help — it competes with the evidence for the first hour
of their reasoning.

And the more carefully the suspicion is argued, the worse this gets. Mine came
with a bisect, a quoted mechanism and a named sibling test. Everything around it
was verified, so the guess inherited the credibility of its neighbours. **A
guess shipped next to facts reads as a fact.**

## The rule

Hand over the **verified** part in full — the bisect, the reproduction, the
exact failing output, what the test pins and why it matters. That is what
actually accelerates someone.

Where a suspicion is genuinely useful, **mark it as costing nothing to
discard**, and put it after the evidence rather than woven into it. "I have not
checked this" is a complete sentence and it changes how the reader spends their
first hour.

Best of all, prefer the question to the answer: *"find out why the guard fires
here"* points at the same place without pre-committing what will be found.

## Open

- This is adjacent to the standing correction that the stamp covers design
  claims and not only greps, but it is a distinct failure: there the cost is a
  wrong statement, here the cost is **someone else's misdirected attention**,
  which is larger and invisible to the person who caused it.
- The agent caught it. Whether that generalises is untested — a less careful
  reader would have gone looking for over-suppression, found something
  plausible, and "fixed" it.
