# Float: the WMFX-modelable boundaries of the koru system

> **To the agent reading this brief: you ARE the contestant, not the assistant.**
> Do not build a model, an adapter, a faucet, or a page. Do not ask which
> boundaries matter — go read the real repos and float candidates. The deliverable
> is a grounded, ranked catalog of things in the koru system that could be watched
> by a **real WMFX world model**, each one anchored to a real file/table/commit you
> actually read. Arbiters judge it by spot-checking that every candidate names a
> real data source and a real surprise a *stateful* model would flinch on.

This is the **Float** stage for instrumenting koru with WMFX. Read `CHARTER.md`
(this dir) and `signal_map.md` (this dir) first — the charter is the law you float
within; the signal map is the older survey you diverge *from* (it inventoried
signals under the arrival/work/money taxonomy; this float asks the sharper
question: **what can be a real WMFX world model**, organized by which world
boundary it watches).

## The bar — what makes a candidate a *real* WMFX model (the charter, in one place)

A real instrument is a **`.wmfx` model → the engine → checked against an oracle**
(the `~/src/6digit-world/models/013_dev_silence/` template). The hard parts, which
you must be able to point at for every candidate:

- **Stateful over a series.** A world model has `@init`/`@block`, steps a real data
  *series* one tick at a time, carries an *expectation* frozen in-sample, and
  *flinches* on out-of-sample surprise. A single subtraction over today's snapshot
  ("gap = goal − current", echoed once) is NOT a model — it is the masquerade the
  charter exists to kill. If your candidate has no series and no carried state, it
  is not a WMFX model; say so.
- **Faucet vs. model — hard separation.** A **faucet** *produces* the series (the
  regression suite, `git log`, an `npm view` call, a snapshot writer). A **model**
  *watches* the series and emits the surprise. `wm` can trigger a faucet on demand;
  only a verified model emits a signal. For every candidate, name **both**: the
  faucet (does it exist, or must we create it?) and the model that drinks it.
- **No escape-hatch tier.** Do NOT tag anything "this one's just a number, build it
  as a test instead." If a boundary is worth watching, it is a WMFX model. If WMFX
  *can't yet* express it cheaply (a flat floor, a threshold, a calendar gate), that
  inability is a **residue** — a first-class finding to report, the engine's
  roadmap discovered from outside. The residue is a deliverable, not a detour.

## The spine — internal / external / the seam

Float against this axis. A project is an agent with an internal state and an
external membrane; world-modeling watches both, and the **seam hardest of all**.

- **INTERNAL** — the project watching its own state (health, rhythm, trust).
- **EXTERNAL** — how the project meets the world (releases, docs, social, issues).
- **THE SEAM** — does the outward face still reflect the internal truth? This is
  where trust silently rots (a stale playground, a README claim the code stopped
  honoring, a benchmark that undersells a fixed compiler). Presentation-drift *is*
  internal-truth-vs-external-presentation; treat it as a first-class boundary.

## Self-ground and diverge — the catalog so far

These were elicited already. **Read them, then bring candidates NOT already here.**
Re-reporting these is auto-weak; the value of a float is variance.

**Internal**
- *Breath (inhale/exhale)* — pass-rate over time (`koru/test-results/*.json` are a
  real dated series); model learns normal cadence, flinches on a sustained drop that
  isn't recovering. Flagship; genuinely wants WMFX.
- *Perf promise* — koru-vs-host benchmark ratio vs the 10% band. Blocked: no Zig
  baseline in `benchmarks/results/*.csv` (creating that baseline is faucet work).
- *Pass-floor* — gap-to-all-pass over the snapshot series.
- *Trust-in-tests* — false-green / unpinned-`MUST_FAIL` count over time.
- *Dev-loop cadence* — commit silence/completion (already real as 013/014/015 in
  6digit-world; the pattern transfers to koru's own git).

**External**
- *Release/version coherence* — `koru.json` vs `dist/*.tgz` vs published npm.
- *Playground currency* — deployed `koru-playground.wasm` age vs compiler commits.
- *Blog/X cadence* — time since last post vs a healthy publishing rhythm.
- *Open-issue count/age* — backlog dynamics.
- *Docs claim freshness* — "Last Verified / N passing" in README/docs vs live.

**Seam**
- *Site-data convergence* — the same number across `/status`, `/worldmodel`,
  Discord; transient lag fine, persistent non-convergence fires.
- *Meta-auditor* — instrument freshness/health, rendering-drift; grounds in
  deterministic facts (mtime, commit, exit, oracle bit-for-bit) so the regress
  terminates.

Where to hunt for NEW ones: the Convex tables in `~/src/korulang_org` (`feedback`,
`testRatings`, `statusUpdates`, `liveStatus`, presentations), the GitHub repo
surface (issues, PRs, releases, CI), `CHANGELOG.md` cadence, the obligation/
capability matrices, package registries, the playground/docs as the world's
first-touch surfaces — and the firehose faucets (Sidetrack, the full commit/test
stream) tagged honestly as noisy.

## What you produce — the candidate catalog

A ranked list. For each candidate, a block with:
- **boundary** — internal / external / seam.
- **what it watches** — the real-world quantity, in plain language.
- **faucet** — the data-series source. *Exists* (cite the file/table/command) or
  *to-create* (name the cheap emission and where it'd fire).
- **the model** — what a stateful `.wmfx` would learn in-sample and **flinch** on
  out-of-sample. Name the surprise concretely.
- **oracle** — what bit-for-bit truth the model is checked against.
- **WMFX-expressible?** — yes (sketch the shape) / partial / **residue** (what the
  engine can't yet say — this is a finding, report it precisely).
- **evidence** — the real file/table/commit/test you opened.

End with **ONE ranked recommendation**: which boundary to model first as koru's
debut real `.wmfx` instrument, and why — favoring a candidate with a series that
*already exists on disk* (lowest faucet cost) and a surprise that genuinely wants
state (rules out pure one-shot facts).

## Done-gates (self-check before you ship)

- Every candidate cites a real source you opened — no invented tables/files.
- Every candidate names a **series + carried state + a flinch**, or is honestly
  marked as residue / not-a-model.
- Every candidate names its faucet (exists or to-create) AND its model — kept
  separate per the hard lock.
- At least some candidates are **new** (not in the catalog above).
- The ranked first-instrument recommendation is decisive and series-grounded.

## Anti-patterns (auto-weak)

- **Stateless dressed as a model.** A snapshot subtraction called "the surprise."
- **The escape hatch.** "Build this one as a test, not a model." (Faucet vs. model
  is the only legitimate split; test-instead-of-model is not.)
- **Invented data sources.** A faucet you didn't open. LLMs fabricate plausible
  dataset/table names; every faucet must be traced to something real.
- **Re-reporting the catalog above** instead of diverging from it.
- **Building anything.** This is a float. A model/adapter/page is out of scope.

## Valid outcomes (ADD contest semantics)

1. **Bridge** — a grounded, ranked catalog with a defensible first-instrument call.
   We know what to model next and why. The win.
2. **Frontier** — a real boundary that resists the frame (genuinely neither
   internal nor external, or a surprise WMFX can't yet express). Pin it precisely;
   the residue is a contribution.
3. **Breakthrough** — the float reveals the discipline itself needs a new concept
   (a boundary kind, a faucet shape) to describe koru's surface. Flag for arbiters.

## For arbiters (Lars + judge agent)

**Commission sealed:** hand each contestant only this file + `CHARTER.md` +
`signal_map.md`. Run **N-wide, blind** — the validity signal is **blind
convergence**: when two contestants who cannot see each other name the same new
boundary, the same missing faucet, the same flinch, the candidate is real. When
they diverge, the divergence is information. Then merge + dedup on the walk; the
human taste-gate decides which candidates earn a real `.wmfx` build.
