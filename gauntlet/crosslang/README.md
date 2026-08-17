# Cross-language gauntlet — rung R1: the trace closer

Both languages execute the SAME dynamic-composition scenario — "retired
provider with a live dependent" (Cordis Theorem 63 ordering) — and each
emits an observable trace. The closer runs BOTH sides and diffs them
against one shared lifecycle invariant.

## The scenario (both sides)

- A provider installs a binding (`store` service / `opened!` file handle).
- A dependent resolves against it (`inject` / `query(conn: file)`).
- The provider is retired; the system hangs up.

## The invariant (lifecycle form, per Theorem 63)

```
dependent leaves ACTIVE strictly before the provider's binding withdraws
```

The order of DISPOSER callbacks is an implementation detail and DIFFERS
between the runtimes (measured: Cordis fires provider-teardown → withdraw →
consumer-teardown; Koru fires consumer-teardown → provider-teardown →
withdraw-ack). The lifecycle order is the theorem; disposer order is not.
This is why the closer compares lifecycle events, not disposers.

## Running

```bash
cd /Users/larsde/src/koru
node gauntlet/crosslang/closer.mjs          # requires /Users/larsde/src/cordis-ref
# optional: --cordis-ref <path> --koru <path>
```

Exit: `0` = both sides satisfy the invariant; `1` = a violation; `2` = closer
infrastructure error.

## What the closer does

1. Runs the Cordis side: copies `xlang-r1-cordis.spec.ts` into the reference
   repo's test dir, runs it under vitest, parses the `XLANG_CORDIS` JSON trace.
2. Runs the Koru side: `440_010_guarded_withdrawal` under the regression
   harness, reads its `actual.txt`.
3. Normalizes both to a canonical vocabulary:
   - `consumer-leaves-active` — dependent exits ACTIVE (Cordis: fiber state
     2->5; Koru: `close-query() ran`)
   - `provider-withdraw` — binding leaves (Cordis: `service|withdraw`;
     Koru: `[BRIDGE] Invoked close-file`)
4. Checks the invariant on each side; prints a per-side row and a VERDICT.

If the Koru harness rejects the run (expected.txt mismatch), the closer
reports it as a FAIL with "substrate caught a violation" — it never crashes
on a substrate failure.

## Falsification (2026-08-16)

The closer was falsified before being trusted, per the gauntlet rule: with
the Koru release loop reverted to the pre-R1 flat shape (forward order, no
guard, no rescan), `440_010` fails and the closer reports:

```
FAIL  Koru bridge consumer-leaves@-1 provider-withdraw@-1  []
VERDICT: FAIL
```

It cannot be flattered: green on the true ordering, red on the known
violation.

## The semantic discovery

The fixture's first attempts failed informatively: retiring a single Cordis
fiber does NOT cascade to dependents (the guard engages only on subtree
teardown), and Cordis's disposer order is provider-then-consumer. Both
surface the same lesson — the behavioral closer must compare lifecycle
events, not callback order. That is now the documented contract.

## Files

- `xlang-r1-cordis.spec.ts` — the Cordis-side fixture (trace recorder +
  invariant assertion).
- `closer.mjs` — runs both sides, normalizes, diffs, verdicts.
- This README — the contract.
- Koru side lives in the regression corpus: `440_010_guarded_withdrawal`.

## Next rungs

- Broaden scenarios: chain (440_014), dual-provider (440_015), redefine
  (440_012) each get a cross-language twin.
- Make the closer a standing wall (`invariants/` guard) if the rungs hold.