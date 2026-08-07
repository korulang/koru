---
type: belief
id: frag-a-port-that-keeps-its-spelling-is-invisible
provenance: repairing the js parity map 2026-08-07 — it reported std/store as blocking 129 tests and ranked porting it first, on a port that had shipped that morning and had not changed a single declaration line
ts: 2026-08-07
---

# A static instrument reads the signal it was built to read, and a port is free to leave that signal alone (belief)

The parity map decides whether a stdlib proc can reach JavaScript, and it decided
it from the declaration line: a `|js` variant means ported, a lone `|zig` means
debt. That predicate was true of every port that existed when it was written,
because every one of them had grown a sibling.

Then store and kernel were ported a different way — one body, branching on
`CompilerEnv.lang`, rendering whichever host it is handed. Nothing in the
declaration moved. The map went on calling `store:new` an unported blocker for
129 tests it had already rendered, `unlock` ranked that finished port as the
single highest-value thing to do next, and the tests themselves sat outside the
board entirely, unmeasurable by construction.

**The lie was not that the map was out of date. It was that the map could not be
brought up to date by re-running it.** It re-derives from the tree on every
invocation — that discipline was deliberate and it held — and it re-derived the
same wrong answer every time, because the fact it needed had never been written
in the place it was looking.

## Widening the predicate produces a second lie, in the other direction

The obvious repair is to read the body instead of the line, and it works for the
case that motivated it: a body naming `CompilerEnv.lang` renders both hosts, and
a body that constructs none of the four host-carrying AST nodes cannot be
target-specific at all. Thirty transforms in `koru_std` are that second shape and
every one had been counted as debt for being spelled `|zig`.

But `taps:tap` takes an `inline_code` step **it was handed**, rewrites a binding
name inside it, and puts it back. It constructs the node, so the predicate fires;
it originates no host text, so the verdict is wrong. Twenty-four tests that node
runs green were called blocked.

Originating host source and passing it through are the same construction. No
regex over the body separates them, and neither would the next three refinements
— each one buys back some of the population and mislabels a new corner, because
the property being tested is semantic and the thing being read is syntax.

## So the resolution is not a better predicate

There is an oracle. The scan runs the test on node, and a green run is proof that
every proc the test reached rendered JavaScript — stronger evidence than any
static claim about the same question, and already sitting on disk.

**Where the oracle has spoken, the predictor defers to it and says so.** The map
now reads the board as evidence and reports how many of its own verdicts were
overruled, by which proc. That number is the map's honesty surface: it is not
zero, it names the exact place the static reading is wrong, and it goes to zero
only when someone fixes the reading or the proc.

This is not circular even though the scan derives its scope from the map. The
board decides nothing about *what to measure* — only what not to re-litigate. A
green row survives re-measurement or stops being one. A missing board costs a
static verdict and no more.

## The inference that looks equivalent and is not

If a green test calls `store:query`, is `store:query` ported? Tempting, and it
would collapse the whole blocker list in one line. It is false. `store:query`
renders JavaScript on its per-row road and emits a Zig `for` loop with a `.{}`
struct literal on its sweep road; twenty-two store tests are green through the
first. Demoting the proc would re-hide the sixty-four the second still blocks.

**Evidence from a run attaches to the run, not to the parts it touched.** The
override is per test, and staying at that granularity is what keeps it sound.

## What follows

- **An instrument keyed on a spelling has an expiry date it cannot announce.** It
  stays correct exactly as long as nobody solves the problem a different way, and
  the day someone does, the instrument's confidence is unchanged.
- **A predictor with a live oracle should be measured against it, continuously,
  and the disagreement count published.** Both agreeing proves little; the map
  and the scan disagreed on 24 rows for a day and neither side reported a
  problem, because neither was asked.
- **Prefer the honest gap to the clever inference.** Nine of the store tests that
  pass on JS are still bucketed blocked, because they reach `store:query` and the
  map cannot tell which road they take. Under-claiming is recoverable by
  measurement; over-claiming sends someone to port something that is done.

## Open

Whether `emitsHost` should survive at all now that the board overrules it where
it is wrong. Keeping it means the map still has a useful answer for a test nobody
has run; dropping it means the map's only claim about an unmeasured test is "we
do not know", which is honest and much less useful. The current answer is keep
it and publish the overrule count — but that count is the thing to watch, and if
it grows the predicate is decoration.
