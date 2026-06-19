# Float synthesis — WMFX-modelable boundaries of the koru system (2026-06-19)

Four blind contestants, sealed, each handed only `world_model_float.md` + `CHARTER.md`
+ `signal_map.md`, blind to each other. The validity signal is **blind convergence**:
where contestants who couldn't see each other named the *same* boundary, the same
faucet, the same flinch — that candidate is real. Divergence is information too.

Raw deliverables: the four returned catalogs (agent ids `a8aefdee`, `a2268271`,
`a3fbaf5e`, `aaffb823`). This file is the merged, deduped, convergence-ranked
synthesis — and it points first at **what already exists**, so new candidates are
situated against the real corpus, not floated in a vacuum.

---

## 0. What we already have (point here first)

**Real, runnable WMFX models — the proven engine (6digit-world `models/`):** 22
`.wmfx` instruments, `002`–`023`, each a stateful model over a real series checked
against an oracle. The corpus that proves the toolchain works.

- **The dogfood dev-loop watchers — the template to copy:** `013_dev_silence`
  (fires when git commits go quieter than in-sample cadence), `014_dev_completion`,
  `015_dev_example_decay`. These watch *our own* development. `013` is the literal
  shape every koru candidate below should follow: `@init` freezes a threshold,
  `@block` steps a real series tick-by-tick, flinches on out-of-sample surprise,
  verified bit-for-bit against `oracle.zig`.
- The rest (`002`–`012`, `016`–`023`) watch external-world series (reservoir
  balance, SP500, attention, carbon, flu excess, geomagnetic/steamboat regimes,
  …) — the breadth that shows the engine generalizes.

**koru's existing instrumentation (real faucet, no model yet):**
- `koru/wm/run.sh` (adapter) + `wm/producer/regression.ts` — a real **faucet**:
  runs the regression suite, pushes green↔red flips to Convex. Produces a series;
  emits no surprise. This is the dog koru already eats.
- Dated regression snapshots: `koru/test-results/*.json` — **598 snapshots**,
  2026-01-26 → 2026-06-18. The densest real series in the system. Most candidates
  below drink from it.

**Prior koru floats (the gap catalog so far):**
- `wm/floats/2026-06-07-transparency/` — 21 ranked gaps (`commission_queue.json` +
  `synthesis.md`); rank-1 is diagnostic-registry coherence.
- `wm/floats/2026-06-18-gap-hunt/` — `commission_queue.json`.
- `wm/floats/drain-loop.md` — the proof the cold-agent loop fixed real koru gaps.

**The aspirational catalog (in `world_model_float.md`, the diverge-from baseline):**
breath / perf-promise / pass-floor / trust-in-tests / dev-loop-cadence (internal);
release-coherence / playground-currency / blog-cadence / open-issues (external);
site-data-convergence / meta-auditor (seam).

**The fakes being replaced (NOT a catalog of value):** `koru/models/probe_pass_floor`,
`koru/models/probe_perf_promise` — stateless bash scripts that echo `signal` lines,
never touch the engine. The masquerade the charter exists to kill. **Zero real
`.wmfx` models exist in koru today.**

---

## 1. Newly floated candidates, ranked by blind convergence

★ = number of the 4 blind contestants who independently named it. New = not in the
aspirational catalog above.

### Strong convergence (3–4 of 4) — the real ones

| ★ | Candidate | Boundary | Faucet | Series on disk? |
|---|---|---|---|---|
| ★★★★ | **Playground WASM currency** — compiler commits since the deployed `koru-playground.wasm` was rebuilt | seam/external | `git rev-list <wasm-commit>..HEAD` over `koru/src` + `korulang_org/static/koru-playground.wasm` mtime | yes (git log) — **RED NOW: ~14d / 240 commits stale** |
| ★★★★ | **Metacircular LOC ratio** — Zig lines vs Koru lines (is the compiler self-hosting faster than it bloats?) | internal | `korulang_org/src/lib/data/history.json` `loc.{Zig,Koru}.lines` | yes — 332 points |
| ★★★ | **Unit-test track** — the embedded `unitTests.summary` (264 Zig unit tests, 37 suites), a *second* series distinct from the regression suite; frozen `skipped=12` since 2026-05-28 | internal | `koru/test-results/*.json` `.unitTests` | yes — 386 snapshots |
| ★★★ | **AoC-2015 completion frontier** — solved parts of 44, regression + stall flinch | internal/seam | `koru/test-results/*.json` `810_AOC_2015` category | yes — since 2026-06-11 |
| ★★★ | **npm release / version lag + coherence** — days since last publish; `koru.json` (0.1.4) vs `dist` (0.1.7) vs npm | external/seam | `npm view @korulang/koru time`; `koru.json` vs `dist/package.json` | partial (8 publish events, thin) |
| ★★★ | **Site-data freshness** — lag between a new koru snapshot and the site/`status.json` reflecting it (overlaps existing site-convergence) | seam | git logs of both repos | yes |

### Moderate (2 of 4)

- **Obligation-matrix coverage frontier** (internal) — green/red/empty cells over
  time; ties to phantom-type progress. `336_OBLIGATION_MATRIX` cluster + `obligation-matrix.md`.
- **Benchmark/perf-claim reality** (seam) — koru-vs-host ratio vs the 10% band;
  *0 Zig baselines exist*, so the headline is unbacked (overlaps existing perf-promise).
- **Lesson / stdlib surface coverage** (external) — documented-category fraction;
  `totalEvents` growth in `stdlib.json`.

### Singletons (1 of 4) — frontier finds worth keeping

Diagnostic-registry coherence (`EMITTED⊆DECLARED⊆PINNED` error codes — matches the
06-07 float's rank-1, so really a re-confirmation); **MUST_RUN gate erosion** (619
signed-promise tests, no todo/skip cushion — C4's top pick); todo-vs-failed
inversion; recovery-shape fingerprint (dip-duration); scope-hygiene drift;
test-oscillation stability; Twitch live-pill currency; feedback-backlog trajectory.

---

## 2. Residue — WMFX language gaps the float surfaced (first-class findings)

The float's *other* deliverable: where real models resisted today's engine.
Convergence here matters as much as on candidates.

| ★ | Gap | What it would unlock |
|---|---|---|
| ★★★ | **`@init` learns the threshold from the in-sample series** (mean/σ/floor), instead of a human-set `slider1` constant (013's pattern). | Statistical models (bands, drift, recovery) instead of hand-set thresholds. The single biggest convergent finding. |
| ★★ | **`prev(port)` / delta-over-previous-tick.** `@block` carries a frozen constant, not last tick's value. | Velocity/trend models (backlog growing, ratio reversing). |
| ★★ | **Network-polled faucets** (HTTP/Convex/npm), not just local-CSV series. | Live external-world faucets (npm registry, Twitch, feedback table). |
| ★★ | **Collection / set-state ports** — carry a named set across ticks for set-difference. | Registry-coherence, per-test ensemble health. |
| ★★ | **Multi-alarm ports** — two distinct flinches per tick (regression vs stall). | Frontier models that fire for different reasons. |
| ? | **Arithmetic in `@block`** (`/`, `max`) beyond threshold-ternary. | Ratio models inline. *Flagged "verify against engine source first" — 013 is a minimal example, may not be a ceiling.* |

These are the engine's roadmap, discovered from outside — exactly what the float is
for. None is an excuse to fake a model; each is a thing to *close*.

---

## 3. First-instrument recommendation — the picks diverged (that's information)

The four debut recommendations split, which is itself a finding:

- C1 → **Perf-claim vs benchmark** (seam) — hardest boundary, but faucet blocked (0 Zig baselines).
- C2 → **Unit-test track** (internal) — exists, but oracle is ~trivially `failed==0`.
- C3 → **Playground currency** (seam) — strongest *candidate* convergence, red now.
- C4 → **MUST_RUN gate erosion** (internal) — deepest series (598 snaps), watches koru keeping its own promises.

**Synthesized read:** two co-leaders.
1. **Playground currency** — the only 4/4 convergence, it's **red right now**, it's a
   pure `013`-shape (silence-on-an-event-clock → *zero* language residue), and the
   faucet is two `git` calls. Lowest-risk debut that also lands on the "hardest
   seam" the charter names. Caveat: the *threshold* series (rebuild events) is thin,
   so the threshold is a design constant, not learned.
2. **A snapshot-floor model** (MUST_RUN erosion, or the existing-catalog **breath**)
   — richest real on-disk series (598 snapshots), genuine carried state, pure
   floor-detector, zero residue. The most honest "exercise WMFX on koru's own
   series" debut.

Both are real, both `013`-shaped, both buildable with no engine change. The walk
(human taste-gate) picks which earns the first real `.wmfx`. My lean: **playground
currency first** (it's red, it's unanimous, it's the hardest seam, and shipping a
real model that fires on a live problem is the strongest possible proof the
toolchain works) — with the **breath/MUST_RUN floor** as the immediate second, to
validate the snapshot-clock shape on the densest series.

---

## 4. Status & next move

- Candidates floated, converged, deduped against the existing catalog. ✓
- Nothing built. The next step is the walk: pick the debut, then build it the `013`
  way — `series.csv` + `model.wmfx` + `oracle.zig` + a `run.sh` that drives the
  engine — and delete the bash probes as the real model lands.
- The strong residue findings (esp. in-sample-learned thresholds) are logged here
  as the WMFX roadmap; they are not blockers for the two co-leader debuts (both fit
  today's engine).
