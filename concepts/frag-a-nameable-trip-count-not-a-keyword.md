---
type: belief
id: frag-a-nameable-trip-count-not-a-keyword
provenance: the stdlib was believed to be riddled with `while` — 34 sites in store.kz alone; classified properly, 21 emitted loops exist across the whole stdlib and two thirds of the remainder are correct as they stand
ts: 2026-07-31
---

# The rule is a nameable trip count, not a banned keyword (belief)

`CLAUDE.md` says emit `for`, never `while`, and gives the reason: `for (0..n) |i|`
hands the optimizer a known trip count, `for (xs, ys) |*x, y|` additionally
proves non-aliasing and removes bounds checks, while `while (i < len) : (i += 1)`
hands it a mutable induction variable and a loop-carried condition. That is
right, and it was worth **-40%** on a real workload when applied to the sweep
loop.

But the rule as *stated* invites a keyword hunt, and a keyword hunt gets the
question wrong in both directions.

## It over-counts

A `while` in a transform's own compile-time Zig is irrelevant — that code runs
in the compiler, not in the user's program. So is a `while` inside a keyword
list or a string comparison. And many emitted `while`s are correct: a loop is
honestly a `while` when the trip count is not knowable before entry.

Of 21 genuinely emitted loops in the stdlib, **fourteen were left alone with
reasons**: strided loops (Zig's `for` has no stride, and forcing one adds a
multiply per iteration), the query loop that is *pinned* removal-aware at
690_031 because `take` swap-removes and the loop must revisit the same index,
ancestor walks and stack-driven DFS, early-breaking init searches that run once.

Converting those would be worse code justified by a rule.

## It under-counts

The single most important site — the store sweep loop, the hottest loop the
language has — **is invisible to a line grep**. The format string spells it
`\nwhile`, and the `n` of the escape defeats a `\b` word boundary. The first
detector written for this had the bug too, and only found it after decoding
escapes before matching.

So the naive check simultaneously flags things that are fine and misses the one
that mattered most. It is not a weak version of the real check; it points
somewhere else entirely.

## What follows

- **Ask "can I name the end before I begin?"** not "does this say `while`?"
  That question is what the rule is *for*, and it is the one a check has to
  implement.
- **A check over emitted output must decode before it matches.** Escapes,
  concatenated fragments, and `{s}` placeholders all hide the construct being
  checked. See `frag-a-check-that-cannot-match-reports-clean` — a checker that
  cannot see the hot site reports the codebase clean.
- **Exemptions must be declared and must rot loudly.** Fourteen honest `while`s
  need somewhere to say so that is not a comment nobody reads; a stale
  exemption should fail the check rather than quietly persist.

## The stronger half, measured: worth nothing where the columns are globals

The open question — does `for (xs, ys) |*x, y|` beat `for (0..n) |i|` on a
store sweep — is answered by measurement (the simple_iter slice-form probe,
2026-07-31): **no gap, f64 or f32, both directions inside noise.** The reason
is structural, not luck: store columns are distinct fields of one global
struct with inline arrays, so their addresses are statically known and
disjoint — LLVM already holds the non-aliasing proof the slice form would
supply, and the emitted index form already vectorizes. The slice form's extra
guarantee is redundant *on this representation*.

Two boundaries keep the belief honest:

- **The proof rides on the representation.** If columns ever become heap
  slices or pointers (any indirection), the static-disjointness proof
  evaporates and the slice form becomes load-bearing — re-measure at that
  moment, not before.
- **The fence that actually remains is FP reduction order, and no loop
  spelling crosses it.** A strict-order f64 fold through the sweep stays
  scalar and latency-bound; reassociating the same sum runs at memory speed
  (the fold probe, same day: ~4x). That license is semantic — a summation
  order the surface would have to grant — not an aliasing fact any `for`
  form can assert.
