---
type: belief
id: frag-capability-declarations-are-module-owned-claims
provenance: koru session — capability declaration design arc, ruled with Lars across the census/tree/explainer builds; enforcement explicitly out of scope
ts: 2026-11-08
---

`cap(...)` entries on procs (and optionally on the contract tor) declare
the effect surface a module claims for its own implementations. The
compiler carries them as opaque annotation text; `std/caps` collects,
censuses, walks impl graphs transitively (`caps <subject>`), scans proc
bodies lexically (`[scan]` — inferred tier, comments count), and reports
them through `explain`. Nothing refuses, gates, or transforms on cap
data: a wrong declaration produces a wrong report, not a wrong program.

The pre-existing `cap()` narrowing head (`[cap(x)]import`, `--cap=`
grants, the `claimed_caps` audit) was ruled dead weight — it restated
per-import what modules should self-declare, its names were ungrounded,
and its spelling resembled a declaration while being a consult.
Excision is parked, not done; enforcement, if it ever lands, re-founds
on computed requirements vs grants — never on per-import consults.

Proc bodies stay opaque to the tree walk (edges inside `|zig` are
invisible, so proc declarations must be self-contained) while the
scanner reads them as text — opacity is a per-consumer choice, and the
two tiers never mix: declarations are claims, scans are inferred
evidence.
