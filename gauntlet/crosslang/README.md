# Cross-language gauntlet — rung R1: the trace closer

Both languages execute the SAME dynamic-composition scenario — "retired
provider with a live dependent" (Cordis Theorem 63 ordering) — and each
emits an observable trace. The closer diffs the two against one shared
event vocabulary.

## The scenario (both sides)

- A provider installs a binding (`store` service / `opened!` file handle).
- A dependent resolves against it (`inject` / `query(conn: file)`).
- The provider is retired; the system hangs up.
- REQUIRED ORDER: dependent teardown strictly before provider teardown;
  the provider's binding withdrawal strictly last.

## Cordis side (packages/core/tests, fixture below)

Trade: parent fiber owns both plugins; retiring it runs both disposers.
Observed trace (normalized):
  service|set|store ... consumer install ... provider teardown ...
  service|withdraw|store
Guarantee: the disposer runs before the binding leaves the store.
True divergence discovered: Cordis does NOT cascade a provider retire
to dependent fibers by itself — dependents retire only under a shared
parent. The paper's Theorem 63 guard (`await allSettled(dependents)`)
engages on subtree teardown, not single-fiber dispose.

## Koru side (440_010_guarded_withdrawal)

Observed trace (normalized):
  consumer|teardown|close-query  →  provider|teardown|close-file
  with a `[BRIDGE] Invoked` acknowledgment per handle after the run.
Guarantee: dependent (query) releases strictly before provider (file).

## The closer

Both traces normalized to:
  1. dependent teardown index < provider teardown index
  2. provider binding withdraw index > provider teardown index
Koru satisfies; Cordis satisfies. The diff is the assertion.

## Rung status

Both sides green; fixture = this dir + 440_010. The next rung should
automate the diff (a script that runs both and compares normalized
indices) and add scenario breadth (chain, LIFO, redefine).
