---
type: belief
id: frag-a-rename-can-improve-the-board-without-improving-the-compiler
provenance: introduced on branch store-surface — the query/rule rename came back +2 green with two source files byte-identical to their base
ts: 2026-08-01
---

# A green whose source did not change is a compiler behaviour change — chase it, never bank it (belief)

A rename that moves a construct from one code path to another can turn tests
green **without fixing anything**, because the new path does not have the old
path's bug. The board improves, the compiler does not, and the improvement
arrives wearing the costume of evidence *for* the rename.

The instance: the store surface rename made `query` mean the read instead of the
rule. Two tests written as `query` back when `query` was the rule went green —
and their source files were byte-identical to base, because a two-step migration
(`query` → `sweep` → `query`) had returned them to their original text. Same
spelling, different verb. The defect they had been pinning — a rule over an
owned-string column losing the row binding's phantom through the qrow/qbody
transplant — was completely untouched, and now had no coverage anywhere.

**Why this is easy to bank rather than chase.** The number moved the right way
on a change you believe in, so it reads as confirmation. Nothing in the run says
"two tests changed meaning"; a test that passes reports no story at all. And the
pass is *legitimate* on its own terms — both files really are reads, the rule's
standing half really was dead weight for them, and forcing them back onto the
rule verb would be preserving coverage by writing programs nobody should write.
There is no villain here, which is exactly why it slips through: every local
judgement is correct and the aggregate still loses a pin.

**The tell is mechanical, and it is the only reliable one.** A green whose
source file did not change is, by definition, the compiler behaving differently.
So diff the inputs of every test whose status improved. An empty diff on a
newly-green test is not good news — it is an unexplained behaviour change, and
it is one of exactly two things: a real fix, or a test that has quietly stopped
testing what it was written for. Both deserve a sentence; only one deserves the
number.

**The rule.** When a rename moves constructs between code paths, the tests that
turn green are the ones to audit hardest, not the ones to celebrate. Ask what
each was pinning and whether anything still pins it. If the answer is nothing,
the coverage must be re-created against the path that still has the bug —
[[frag-a-red-pin-is-unfalsifiable-documentation]] is the counterweight to keep
in view here, because the re-created pin has to be a real runnable red, not a
comment saying the defect exists.

**Open:** the general form is a board-level check nobody has written — flag any
test whose status improves while its inputs are unchanged, and require the run
to say so out loud. Today it took a human-scale hunch and a `git diff`.
