# Cross-language gauntlet — the trace closer

Both languages execute the SAME dynamic-composition scenario and each emits
an observable trace. The closer runs BOTH sides and diffs them against
per-scenario lifecycle invariants — it is the machine that checks the two
runtimes agree on the shared theorem.

## Scenarios

### R1 — ordering (retired provider with a live dependent, Thm 63)

- A provider installs a binding (`store` service / `opened!` file handle).
- A dependent resolves against it (`inject` / `query(conn: file)`).
- The provider is retired; the system hangs up.

Invariant: `dependent leaves ACTIVE strictly before the provider's binding
withdraws`.

The order of DISPOSER callbacks is an implementation detail and DIFFERS
between the runtimes (measured: Cordis fires provider-teardown → withdraw →
consumer-teardown; Koru fires consumer-teardown → provider-teardown →
withdraw-ack). The lifecycle order is the theorem; disposer order is not.
This is why the closer compares lifecycle events, not disposers.

### R2 — recovery exactness (explicit release then hang-up, Thm 61)

- A parent owns two provider children (`storeA`/`storeB`; Koru:
  `open(a.txt)` + `open(b.txt)`).
- The A child is explicitly disposed mid-session (Koru: `close-file(a.txt)`
  called explicitly).
- The parent hangs up (Koru: `std/bridge:close`).

Invariant: `each binding withdraws EXACTLY ONCE` — the explicit dispose plus
hang-up apply A's inverse a single time; B's a single time. Double-release
is a doubled inverse (the 12M-line bug Koru caught in-repo as EX-004).
Measured: Cordis re-emits `service|set` during notify (the R1-documented
artifact) — the invariant is on the WITHDRAW side, the irreversible half.

## Running

```bash
cd /Users/larsde/src/koru
node gauntlet/crosslang/closer.mjs          # requires /Users/larsde/src/cordis-ref
# optional: --cordis-ref <path> --koru <path>
```

Exit: `0` = every scenario satisfies its invariant on both sides; `1` = a
violation; `2` = closer infrastructure error.

## What the closer does

1. Runs the Cordis side: copies each `xlang-r*-cordis.spec.ts` into the
   reference repo's test dir, runs it under vitest, parses the
   `XLANG_CORDIS` JSON trace.
2. Runs the Koru side: the scenario's regression pin under the harness,
   reads its `actual.txt`.
3. Reduces each side to the scenario's canonical markers, checks the
   invariant per side, prints per-side rows and a VERDICT.

If the Koru harness rejects the run (expected.txt mismatch), the closer
reports it as a FAIL with "substrate caught a violation" — it never crashes
on a substrate failure.

## Falsification

The closer was falsified before being trusted, per the gauntlet rule: with
the Koru release loop reverted to the pre-R1 flat shape (forward order, no
guard, no rescan), `440_010` fails and the closer reports:

```
FAIL  Koru bridge consumer-leaves@-1 provider-withdraw@-1  []
VERDICT: FAIL
```

The per-scenario discrimination is measured: under probe A (flat release),
R1-ordering goes FAIL on the Koru side (provider released under its
dependent) while R2-exactness stays PASS — the two theorems are
independently checkable by one closer.

## The falsification battery (2026-08-17)

The single manual falsification became a **scripted, batched battery**
(`falsify.mjs`) so the "can't be flattered" claim is re-checked in one
command per rung — not by hand-flipping the interpreter and re-running the
full board. Only the pinned tests are exercised; uncached full sweeps stay
in the publish ceremony.

```bash
node gauntlet/crosslang/falsify.mjs          # runs every probe, restores tree
```

Each probe in `probes/*.patch` edits the `dischargeAllHandles` loop; the
contract is per-probe:

| probe | edit | expected | why |
|---|---|---|---|
| `A-flat` | forward walk + no guard | **FAIL** | pre-R1 flat release — the one real violation |
| `B-guardless` | LIFO, guard removed | PASS | LIFO carries ordering alone (near-miss) |
| `C-forward` | forward walk, guard kept | PASS | guard alone enforces ordering (near-miss) |

Exit `0` = every probe met its contract and the tree was restored
byte-identical. The battery refuses to run on a dirty tree and aborts if a
restore fails, so it can never be left with a modified `interpreter.kz`.
Probes B and C are the discriminating half: a closer that fired on them
would be over-eager. Their staying green is what makes the battery's one
FAIL meaningful.

## The semantic discovery

The fixture's first attempts failed informatively: retiring a single Cordis
fiber does NOT cascade to dependents (the guard engages only on subtree
teardown), and Cordis's disposer order is provider-then-consumer. Both
surface the same lesson — the behavioral closer must compare lifecycle
events, not callback order. That is now the documented contract.

## Files

- `xlang-r1-cordis.spec.ts` — Cordis-side fixture for ordering.
- `xlang-r2-cordis.spec.ts` — Cordis-side fixture for recovery exactness.
- `closer.mjs` — runs both sides per scenario, reduces, diffs, verdicts.
- `falsify.mjs` + `probes/*.patch` — the batched falsification battery
  (the closest-without-flattery check, scripted).
- This README — the contract.
- Koru side lives in the regression corpus: `440_010_guarded_withdrawal`
  (R1), `440_013_recovery_exactness` (R2).

## Next rungs

- Broaden scenarios: each in-repo theorem that has a seat in BOTH runtimes
  gets a cross-language twin — candidates: re-resolution (440_012),
  transitive chain (440_014), dual-provider (440_015).
- Make the closer a standing wall (`invariants/` guard) if the rungs hold.
