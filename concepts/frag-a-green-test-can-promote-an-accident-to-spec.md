---
type: belief
id: frag-a-green-test-can-promote-an-accident-to-spec
provenance: 2026-08-03 — std/store's write block was found to land entries in written order, contradicting the design's own spine line; the behaviour had been pinned green by a test that says, in its own header, that the question "was never asked"
ts: 2026-08-03
---

# A test written from observed behaviour is indistinguishable from a ruling once it is green (belief)

The truth hierarchy here says runnable tests are the source of truth for
semantics, and that rule is load-bearing — prose drifts, tests do not. But it
has an edge that had not been named: **it does not distinguish a test that
encodes a decision from a test that encodes an observation.** Both are green,
both are cited, and only one of them means anything.

The store's write block is the case. A `stored { … }` block is one write and
every right-hand side reads pre-state; the design says so in its spine, in one
line, for a reason that is not stylistic — subscriptions are compiled into the
write path, so a block that landed entries in sequence would fire a subscriber
against a half-updated row, a state the program never intended to exist.

The implementation instead lands entries in written order. Someone hit the
question, ran the compiler, saw a duplicate, and pinned the duplicate. Then a
second test was written that exploits the ordering to factor a value into a
column and reuse it, citing the first test as its licence. Two green tests, one
of them doing real and valuable work, both encoding a defect.

## What makes this worse than an ordinary wrong test

**It was flagged and it still stuck.** The pin's own header recorded that the
question "was never asked" and left a note that a future ruling would flip it.
So the author knew they were writing down an observation rather than a decision,
said so, and the green mark erased the distinction anyway. A caveat in prose
attached to a passing test is not a caveat; it is a footnote under an assertion.

**The dependent test creates sunk cost.** By the time anyone questions the
behaviour there is something real to lose — a seventeen-fold reduction in work,
in this case — so the defect acquires defenders on performance grounds. The
argument shifts from "is this right" to "what will it cost to change", which is
the wrong question asked convincingly.

**The sibling disagreed the whole time.** std/grid's write block reads pre-state
and always has, so the same three-line program produced two different answers in
two tables in the same repository. Nothing noticed, because no test ran the same
program against both. A divergence between two implementations of one idea is
invisible unless something is written to look at exactly that.

## What to do about it, which is cheap

- **When writing a test whose expectation you got by running the compiler,
  say so in the header and go read the design before committing it.** The cost
  is one grep. The alternative is what happened here.
- **A test that pins an unruled question should be RED, not green.** Assert what
  the design says and let it fail. A red pin is a question with a deadline; a
  green pin is an answer.
- **When two constructs are siblings, write the same program against both.** The
  divergence is the finding, and it costs one file.

## Open

Whether the corpus contains other pins of this kind. There is no mechanical way
to spot one — a characterisation test and a ruling test are the same artifact —
so the only signal is a header that hedges, and hedging headers are not
greppable in any reliable way. The honest position is that this is probably not
the only one.
