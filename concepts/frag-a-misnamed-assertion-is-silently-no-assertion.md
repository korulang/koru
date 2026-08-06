---
type: belief
id: frag-a-misnamed-assertion-is-silently-no-assertion
provenance: wall built 2026-08-06 (anchor:cfg-dead-expectation-filename); all 25 live carriers triaged individually — 11 promoted and hand-run, 14 deleted as litter, exactly 1 fictional expectation found. Originally measured 2026-07-31 while probing 440_RESOURCE_BRIDGE.
ts: 2026-08-06
---

# A test whose assertion file is misnamed asserts nothing, and reports the same green as one that passes (belief)

**Walled.** `expected_output.txt` is now a `config-error`
(`anchor:cfg-dead-expectation-filename`): the harness reads `expected.txt` and
`expected_patterns.txt`, so a file with `expected` in its name and nothing
reading it is dead weight shaped like diligence.

## Why this is worse than a missing test

A missing test is a known hole; a census finds it. A **misnamed** assertion is
worse, because the directory contains every artifact of diligence — a `MUST_RUN`,
a file with `expected` in the name, four lines of carefully written output. An
auditor reading that directory concludes the behaviour is pinned. One word in a
filename is the only thing wrong, and nothing in the corpus, the board, or the
reviewer's eye distinguishes it from the working case.

So the test does not merely fail to guard. **It occupies the place where a guard
would go**, and it reports the same green a real one would.

## The symmetry rule this established, now paid off

`regression_lib.sh` had failed a test with expected output and no `MUST_RUN`
since long before, and its source stated the reasoning. The symmetric case —
`MUST_RUN` with no readable expectation — was simply never built. Both are one
defect from opposite ends: an intention to check output, and no check happening.
**Whenever a wall guards one direction of a symmetry, ask what guards the other**
— and that question is now cheap to ask, because `scripts/WALLS.md` carries a
`MIRROR, unbuilt:` note per row. This wall was in that column, in writing, before
anyone went looking for it.

## The 2026-07-31 caution was right, and honouring it changed the count

The prior belief warned: *the carriers must not be bulk-renamed — switching them
all on at once converts assumptions into claims the board makes on our behalf.*
Held. Each of the 25 live carriers was triaged by hand:

- **11** were the test's only expectation → promoted to `expected.txt` and each
  compiled and run individually. **10 were already true.**
- **14** sat beside a real assertion (`expected.txt`, `post.sh`, an `EXPECT`
  `CONTAINS`) → deleted as litter.
- **1** was fiction: `220_005_cross_module_type_nullable` expected `done` from a
  program with no flow, which could never have printed anything.
- `321_nested_recursive_label`'s whole content was *"// Expected output
  placeholder — test currently fails at codegen stage"* — state prose inside an
  assertion. Deleted; the test honestly pins that it runs clean, which it does.

The 8 remaining carriers are under `_archive/`, which the harness excludes from
collection, so the wall never sees them.

**The measured cost of the caution: bulk-renaming would have been right 10 times
out of 11 and wrong once, and the once is the whole point — a board that claims
something false is worse than a board that claims nothing.**

## What it originally cost, and the question now answered

Two of the four contradicting-green tests were the entire evidence base for a
commissioning brief describing cross-session discharge as a working beachhead
worth building on. The brief was wrong because it trusted a green.

**Did `440_RESOURCE_BRIDGE` ever work?** Answered: **no, not once.** The failure
was `NoBranchMatch` — both tests asked the interpreter for a branch named
`opened` from a bare-return tor that reports the empty branch. The programs were
written against semantics that never existed, and `d7e2eae9` ("440_RESOURCE_BRIDGE
goes green", 2026-07-25) recorded only that the marker had flipped.

## The rule that follows

**A green is a claim about a program, and a claim needs a claimant.** Before
citing a passing test as evidence for anything load-bearing — a design decision,
a commissioning brief, a published capability — confirm that the test *asserts*
something, not merely that it *passes*.

Related: [[frag-compliance-is-counted-with-the-enforcers-predicate]] — the same
failure shape one level up. Related: [[frag-a-handle-count-is-not-a-capability-check]]
— the same shape one level DOWN, found underneath this one: there a green
reported a claim nothing checked, here a handle count reported a guarantee
nothing enforced.
