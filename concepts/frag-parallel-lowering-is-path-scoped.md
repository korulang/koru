---
type: belief
id: frag-parallel-lowering-is-path-scoped
provenance: Osprey tak-par investigation, 2026-11-24 — quiet-board cell
  showed tak-par identical to tak-seq; emitted-Zig inspection traced it
  to flat-continuation segments bypassing emitInvocation and tail-reentry
  conversion skipping the join drain
ts: 2026-11-24
---

# Parallel lowering is path-scoped — a mark is honored only where emitInvocation runs

`[parallel]` is not a global property of a call; it is honored only on emission
paths that pass through `emitInvocation`'s forkable/worklist branches. Two
paths bypassed it silently:

- **Flat-continuation segments** (`flowIsFlatEligible` → `emitFlatSegments`)
  lowered tak's chained self-calls to `__koru_seg_*` tail-call chains and never
  consulted the annotations — tak-par measured bit-identical to tak-seq
  (44.7 vs 44.4 ms on the quiet board) with live `[parallel]` marks in the
  source. Dead syntax is worse than no syntax: it reads as a request the
  compiler ignored.
- **Tail-reentry conversion** (`emitSelfTailReentry`/`emitMutualTailReentry`)
  emitted reargs+`continue` without draining `pending_parallel` — reentry args
  can read spawned bindings, and the undrained pending list leaked into sibling
  branches whose scopes never declared the flag vars (backend failure:
  undeclared `__koru_par_sp_t1`).

The ruling: any emission path that can carry a `[parallel]`-marked invocation
either honors it or must make the flow ineligible for that path. Flat
eligibility now excludes flows containing parallel annotations; both tail
reentry paths drain joins before reading bindings. The general invariant —
*pending_parallel is scoped to the block that declared its flags; every exit
from that scope drains first* — is the thing to keep checking as new emission
paths accrete.

Open: the worklist gate's "unsure → fork/join" default still leaves tak's
permuted self-calls on spawn-per-call fork/join, which measured ~nothing on
the quiet board (Bend-par tak 23.3 vs our ~45). Whether tak's shape wants the
worklist despite failing the asymmetry classifier is an open measurement.
