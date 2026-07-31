---
type: belief
id: frag-a-misnamed-assertion-is-silently-no-assertion
provenance: probing 440_RESOURCE_BRIDGE, 2026-07-31 — both tests are green on the board and both print FAIL when run; they carry expected_output.txt, a filename the harness never reads
ts: 2026-07-31
---

# A test whose assertion file is misnamed asserts nothing, and reports the same green as one that passes (belief)

`440_002_cross_session_discharge` is the only evidence that a resource obligation
can outlive the interpreter run that issued it — the "Hollywood OS" pattern, an
obligation opened on one turn and discharged on another. The board reports it
green. Its own `actual.txt` reads:

```
FAIL: session 1 dispatch_error
```

Its sibling `440_001` reads `FAIL: dispatch_error`. Both carry a `SUCCESS` marker.
Reproduced by hand with the shipped `koruc`: session 1 does not reach session 2.

The mechanism is a filename. The harness diffs `expected.txt`
(`regression_lib.sh:1490`). Both tests carry **`expected_output.txt`**, which
nothing reads. A `MUST_RUN` test with no readable expectation asserts nothing and
passes on exit 0.

## Why this is not the same as a missing test

A missing test is a known hole. Someone can count the constructs and find it —
that is what a mirror-test census does.

A **misnamed** assertion is worse, because the directory contains every artifact
of diligence. There is a `MUST_RUN`. There is a file with the word `expected` in
its name, holding four lines of carefully-written expected output. An auditor
reading that directory concludes the behaviour is pinned. The only thing wrong is
one word in a filename, and nothing in the corpus, the board, or the reviewer's
eye distinguishes it from the working case.

So the test does not merely fail to guard. **It occupies the place where a guard
would go**, and it reports the same green a real one would.

## The wall exists in one direction only

`regression_lib.sh:581` already fails a test that has expected output but no
`MUST_RUN` marker, and the source states the reasoning: *"Otherwise they
dishonestly pass by claiming compile-only when they should verify output."*

The symmetric case — `MUST_RUN` with no readable expectation — was never built.
Both are the same defect seen from opposite ends: an intention to check output,
and no check happening. One end is guarded and the other is open, which suggests
walls get built where someone was bitten rather than where the shape says they
belong. **Whenever a wall guards one direction of a symmetry, ask what guards the
other.**

## What it cost

Corpus-wide: 35 tests carry `expected_output.txt`; **29** have no `expected.txt`
or `expected_patterns.txt` and therefore assert nothing; **4** are green while
their captured output contradicts their own stated expectation. Two of those four
were the entire evidence base for a commissioning brief that described
cross-session discharge as a working beachhead worth building on. It is not
working. The brief was wrong, and it was wrong because it trusted a green.

One of the four, `321_nested_recursive_label`, has an expected file whose whole
content is *"// Expected output placeholder - test currently fails at codegen
stage"* — state prose inside an assertion, failing a second rule at the same
time.

## The rule that follows

**A green is a claim about a program, and a claim needs a claimant.** Before
citing a passing test as evidence for anything load-bearing — a design decision,
a commissioning brief, a published capability — confirm that the test *asserts*
something, not merely that it *passes*. The cheap version of that check is: open
the directory and find the file the harness actually reads.

Related: [[frag-compliance-is-counted-with-the-enforcers-predicate]] — the same
failure shape one level up. There, a rule was enforced and I measured with the
wrong predicate. Here, an assertion was written and the harness read the wrong
filename. Both are a gap between the thing believed and the thing executed, and
both are invisible until someone compares the two directly.

## Open

- Did `440_RESOURCE_BRIDGE` ever work? `d7e2eae9` ("440_RESOURCE_BRIDGE goes
  green", 2026-07-25) claims it did, and the board had no way to check that
  claim. Unresolved.
- The 29 must not be bulk-renamed. Each holds an *unverified* expectation;
  switching them all on at once would convert 29 assumptions into 29 claims the
  board makes on our behalf.
