---
type: belief
id: frag-lifo-carries-ordered-release
provenance: 2026-08-16 — cordis gauntlet rounds R5-R7 (chain, diamond, dual-provider falsifications all had no bite); branch gauntlet/r567
ts: 2026-08-16
---

# LIFO reversion, not a dependency guard, carries ordered release on the handle pool (belief)

The resource bridge's release ordering — dependents before providers — is
carried by one mechanism: LIFO (reverse acquisition order) plus in-pass
discharge marking. The dependency guard (`hasUndischargedDependents`) is
defense-in-depth that no reachable shape can turn red once release walks the
pool in reverse.

Three candidate ordering theorems from the Cordis paper were pinned as
shapes (transitive chain, diamond, dual-provider) and each falsification
attempted a plausible broken runtime — single-pass scan, guard deleted
entirely, first-provider-edge-only — and every one still released correctly.
The reason is structural: a dependent is always acquired after its provider
(higher pool index), reverse walk reaches it first, and marking it
discharged in the same pass clears the provider's block before the provider
is consulted. For any acyclic dependency set, LIFO alone is correct.

Historical note: the guard earned its keep when release was FIFO (round R1
falsified forward-order-with-guard; 440_010). R2's LIFO flip made it
unreachable. The paper's ordering theorems, mirrored on this pool, are
satisfied by R2's one-line change plus retry logic (the re-scan loop) for
failed discharges.

What would correct this: a handle acquired BEFORE a provider it depends on
(the pool's acquire order and the dependency order diverging), or an
environment where release order must respect a constraint LIFO cannot
express. Both are outside the current surface; the bridge's acquire-then-use
protocol makes the divergence impossible.

Related: [[frag-an-obligation-is-a-liveness-interval]] — obligations as
liveness intervals is the adjacent belief; this one names the mechanism that
respects them at release.