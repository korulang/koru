---
type: belief
id: frag-dispatch-record-is-the-source
provenance: KOPIUM context-assembly call_step emission, 2026-11-10 — the
  receipt corpus's 95,555 empty branch fields are the measured cost of
  the old shape
ts: 2026-11-10
---

# The dispatch record is the source; prose is a rendering of it

Every dispatched call produces exactly one `TraceEntry`, and every
consumer — the model-facing trace line, the `call_step` JSONL stream,
`state()`'s `path:` — reads that same entry. The structured record is
not derived from the prose and the prose is not re-parsed into records;
both are renderings of one capture made at the dispatch site, where the
arguments, arm words, cost, and held handles still exist as facts.

The corollary that cost us a corpus: state that only exists inside
rendered text is state that will be lost. The old receipt corpus proved
it — 95,555 result observations with branch keys present and every
value empty, because the reporting layer flattened the structure and
nothing kept the original. When a consumer needs a field the prose
doesn't carry, the fix is a field on the record, never a parser for
the prose.

Open: `armed` captures the arm *words* at a node but not guard
outcomes; `fired_guides` is a placeholder until the guide ledger
exists; arg-eval failures produce no record (the dispatch never
armed).
