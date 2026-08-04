---
type: belief
id: frag-bounded-read-of-a-no-delete-corpus
provenance: Lars + Claude 2026-07-26 — evaluating OptMem (VictorTaelin) and prose against the membrane
ts: 2026-07-26
---

# A no-delete corpus owes a bounded read, and the write-time summary already is one (belief)

The membrane's founding axiom is that **nothing is deleted and history is never
rewritten**. That axiom is right and stays. But it has a consequence nobody
priced: *"read the membrane before you improvise anything it governs"* is an
instruction whose cost grows monotonically and forever. It was affordable when
the corpus held a handful of concepts. It is not a promise a corpus can keep, and
an orientation instruction that quietly becomes unfollowable is worse than none —
every reader who skips it learns that the discipline's instructions are optional.

**The resolution is not pruning.** Pruning would trade the axiom for comfort, and
the axiom is load-bearing (content-addressed value-tickets, replay, and the
honest record of having been wrong all depend on immutability). The resolution is
that **detail decays at read time while existence stays total**: a bounded read
shows the hot beliefs whole, degrades the rest through progressively cheaper
renderings, and still names every concept in the store. Coverage is never
sacrificed — only resolution. What must never happen is a read that silently
presents a subset as the whole, which is why every truncation in `snap.mjs` is
announced and the tail is counted rather than dropped.

## The summary tier was already being written

The genuinely surprising part. Compaction schemes for agent memory (OptMem's
binary merge tree is the sharpest example) spend real effort generating summary
lines, and pay for it with lossy, bottom-up smear: a bad low-level summary
propagates upward and is never revisited.

We had been writing the summary tier by hand, every commit, for free, and
discarding it at read time. The lineage discipline requires a subject in
`verb(id): what changed` form — that *is* the compressed line, authored with the
full judgment of the person who made the change, at the moment they made it. It
never needs recomputation and it cannot smear, because it was never derived from
another summary.

**Consequence, and it is a real cost:** the commit subject is now load-bearing at
*read* time, not only in the log. A lazy or vague subject silently degrades every
future orientation over that concept. The discipline of writing a good one just
got a second, larger payoff — and a second, larger penalty.

## Rejected: a persisted summary tier

The obvious alternative — a stored, incrementally-maintained summary index (the
shape of OptMem's `LOG.txt` + `TREE/`) — was considered and refused. A store whose
entire thesis is *one ledger, git, no proprietary sidecar* cannot grow a second
source of truth without inheriting a synchronization problem it had specifically
been designed to avoid. Everything the bounded read needs is derivable from git
plus the working tree in a single pass, so it is derived on every call and
nothing persists. There is nothing to invalidate, nothing to rebuild, and no way
for the summary to disagree with the corpus.

The same reasoning already governs embeddings here (a deferred, back-fillable
cache). This is that rule applied a second time, and it should be the default
answer whenever a derived layer is proposed.

## Open

- Heat is currently recency-first. Whether *relevance to the session's actual
  work* should outrank recency is unresolved, and would need a query term the
  bounded read does not yet take.
- Corpora in the 6digit family are walled off per-repo while the koru family
  shares one store. Whether a bounded read should resolve across a project family
  (prose does this for sessions by IDF-weighted sibling matching) is open.
