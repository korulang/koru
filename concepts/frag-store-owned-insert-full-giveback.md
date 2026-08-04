---
type: belief
id: frag-store-owned-insert-full-giveback
provenance: session 2026-07-23 (Lars + Grok) — todo_tui capacity; 690_077
ts: 2026-07-23
tags: [toolchain, store, owned, obligation, insert]
---

# Owned `| full` reissues the value the store never kept

Scalar `| full` (pin `690_011`) can return an empty payload — there is
nothing to free. An **owned** column is different: insert *consumed* the
caller's obligation before discovering the pool was full. Returning
without reissuing that obligation is a silent leak; panicking instead is
the soft-capacity wall the language rejected.

Ruling: when an owned store's insert handles `| full`, the full arm
**reissues every column** (owned fields with their `<mod:state!>`,
scalars bare) so the caller can free or keep. Sites without `| full`
still panic via the void/inserth path — exhaustion without a branch is
still loud. Pin `690_077`.
