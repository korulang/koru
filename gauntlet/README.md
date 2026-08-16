# The Cordis Gauntlet

A repeatable, closed loop that grinds KOPIUM's dynamic-composition semantics
against an external oracle: the **Cordis** meta-framework (cordiverse/cordis),
which implements the *"Programming Paradigm for Spatiotemporal Composability"*
paper (Peking University / DeepSeek-AI) with a passing test suite.

The gauntlet's wager: the paper's theorems are **discovery engines for KOPIUM's
bugs as well as its features**. Each rung takes one theorem, states its
observable form in KOPIUM's own vocabulary (handles, pools, sessions, defines),
pins it with a regression test, and *falsifies* the test before trusting it —
the test must go red against the violating implementation, then green against
the fix. A property that cannot be falsified is a prayer, not a pin.

The runner's discipline comes from `skill://arbiters-gauntlet`: the closer is
rung-1 (mechanical, no LLM in the verdict), the ledger is version-controlled,
and the board grows one row per rung.

---

## Why the oracle is trusted (read this before you doubt a diff)

- **It is a running library, not a paper.** `cordiverse/cordis` core compiles
  and passes 70/70 of its own tests under `bunx vitest`. The paper's prose has
  no authority here; the code does.
- **The properties are read as primary source.** The withdrawal-ordering guard
  is not "described by Theorem 63" — it is bytes in `reflect.ts:161` (`await
  Promise.allSettled(fibers.map(f => f.await()))` before the provider's own
  cleanup). Every rung was mirrored from such bytes.
- **The setup is reproduceable:**
  ```bash
  git clone https://github.com/cordiverse/cordis.git /Users/larsde/src/cordis-ref
  cd /Users/larsde/src/cordis-ref && bun install && bunx vitest run packages/core/tests
  ```
  If the reference repo moves or breaks, the gauntlet is still meaningful — the
  theorems are independently stated in the paper's metatheory — but a fresh
  clone should be re-run before trusting a new mirror.

## The rhythm — one rung, five moves

1. **Theorem → shape.** Take one stated guarantee (ordering, LIFO reversion,
   re-resolution, recovery exactness) and find its observable form in KOPIUM's
   own seam.
2. **Pin** — write a regression test (`440_0NN_...`) whose `expected.txt`
   would FAIL if the property were violated.
3. **Falsify** — temporarily break the runtime (neuter the guard, flip the
   order, drop the skip), rebuild, watch the test go red, and re-record the
   violating output. The falsification IS the evidence that the pin is real.
   If the test passes against the violation, the property was already a lie —
   keep digging (that's how EX-003's memory bug was found).
4. **Sweep** — full `440_RESOURCE_BRIDGE` cluster green, not just the new test.
5. **Record** — one ledger row + one postscript entry, with the falsification
   evidence. The ledger is a judgment file: exclusions are *proposed*, never
   enacted; a run that grows the ledger faster than the score is a finding
   (the bar was too high), worth more than the parity.

## The board (what has landed)

| rung | theorem | property | pin | falsified by | result |
|---|---|---|---|---|---|
| R1 | guarded withdrawal (Thm 63) | provider outlives dependents; release ordered | `440_010_guarded_withdrawal` | guard neutered → provider released first, red | CLOSED |
| R2 | LIFO reversion (Thm 16) | independent handles release in reverse acquisition | `440_011_lifo_release_order` | forward iteration → red | CLOSED |
| R3 | re-resolution (Thm 63/64) | redefine replaces; next dispatch sees the NEW body | `440_012_redefine_resolves` | stale-first-wins under owned memory → red | CLOSED |
| R4 | recovery exactness (Thm 7), φ(γ)=γ₀ | accumulator applies each inverse exactly once | `440_013_recovery_exactness` | discharged-check removed → 12M double-releases → timeout-red | CLOSED |

Cluster standings: **13/13 green** in a clean worktree (R4).

`440_0NN` tests live in `tests/regression/400_RUNTIME_FEATURES/440_RESOURCE_BRIDGE/`
alongside the earlier bridge tests (440_001–440_009). Each is `MUST_RUN` +
`input.k` + `expected.txt`.

## Files in this directory

- `LEDGER.md` — the exclusion ledger. Every exclusion, with its resolution
  and falsification evidence. Read this before proposing scope exclusions.
- `FIRST_PULL.md` — the closer self-certification: what the gauntlet is
  chasing, the can't-tell fraction history, and the postscript of every round.
- `RUN_01_VERDICT.md` — the run-one verdict: board, ledger, frontier, what
  plateaued, whether the bar held. Replaced or amended when the run ends, not
  per-round.

## How to add rung five

Pick a theorem from the paper's metatheory (Section 4.4: preservation,
temporal recovery, spatial ordering, progress, confluence) that KOPIUM's
runtime does not yet claim. Then:

- Verify the oracle is live (`bunx vitest` on the reference core).
- State the property in Koru semantics — is it a handle, a scope, a defined
  flow, a session?
- Write the test with **no** prior expectation of passing. Its `expected.txt`
  is what the honest runtime must produce; if today's runtime disagrees, that
  disagreement is the find, and the fix is the rung.
- Falsify against the old behavior; sweep the cluster; log a ledger row.

Every rung so far went: the property was *already half-claimed* by KOPIUM
(flat release, FIFO order, "durable" table) and the truth was a lie each time.
Expect to keep finding that pattern; the best rung is the one that starts by
passing.

## The frontier

Each property has been mirrored structurally and falsified in-repo — which
buys the guarantee at the semantic level. The un-crossed boundary is **rung-2
behavioral A/B**: a live cross-language trace diff that runs the same scenario
through Cordis and through KOPIUM and compares observable behavior. That
instrument is the next step if a property's mirror cannot be expressed
in-repo; until then, in-repo falsification is the higher bar.

Also standing: **the working tree's `src/transform_pass_runner.zig`** was
carrying a concurrent, uncommitted edit (another session's) that broke the
backend build during R3/R4; a clean worktree at the last commit was used for
verification. Land or revert that before running the full board here.