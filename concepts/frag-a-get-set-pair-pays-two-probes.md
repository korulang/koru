---
type: belief
id: frag-a-get-set-pair-pays-two-probes
provenance: seqdefects kernel commission 2026-11-24 — wordfreq disassembly/timing investigation; cache mitigation landed in std/string-map
ts: 2026-11-24
---

# A map get→set pair is two probes unless the implementation carries the entry forward (belief)

The naive `get(m,k)` then `set(m,k,v)` idiom is semantically simple but mechanically two independent hash-table probes when both operations are opaque collection verbs. In the wordfreq kernel this shape is the hot loop: 200k tokens, two lookups per token, and the double probe — not token generation or teardown — is the dominant difference from a one-probe hand-written C map. A generated single-probe experiment preserved the oracle and moved Koru to rough parity with the honest chained-map C comparator; the uncached two-probe form did not.

`std/string-map` therefore carries a one-entry interior cache: `get` records the stored key and value-slot it found; `set` first compares the requested key against that stored key and writes through the cached slot on equality. This does not change the language or the faithful source shape — callers still write the naive get-then-set — but the implementation avoids the second table probe for the immediate-update idiom. Mutations that can invalidate table storage clear the cache: insertion misses inside `set`, and every `del` before removal. The cache is an implementation detail, never a lifetime extension: it stores the map-owned key bytes, not the scoped lookup slice.

Measured local arm64 oracle-green min-of-15 interleaved process walls during the commission: wordfreq before 4.304 ms, cached 3.841 ms, honest C map 3.124 ms, corner-cut fixed-array C 2.173 ms. The remaining gap to honest C is not closed by the cache because the cached-hit path still pays a dynamic string equality and the Koru source still executes two collection verbs; a true single-probe update is either a new surface or an optimizer fusion, not a transparent implementation detail.

Open: whether a general compiler fusion across opaque tor boundaries is desirable or whether collections should grow an explicit update/mutate verb. Do not use this cache as evidence that fusion is unnecessary; it is a mitigation with nonzero residual cost.
