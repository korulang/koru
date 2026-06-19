# Instrumenting koru with WMFX — charter

**Status:** DRAFT for external QA. Written 2026-06-19. Nothing in here is built
yet; this captures the *correct shape* so the implementation exercises the real
toolchain instead of faking it.

**Audience:** a reviewer (human or LLM) sanity-checking the design before we
build. Every factual claim cites a file you can open. Open questions are flagged
`⚠ OPEN` — those are the parts most worth challenging.

**The thesis, up front:** the job is to instrument **all** of koru — every goal,
every gap, everything worth watching — and to do that instrumenting **through
WMFX**, because exercising the WMFX toolchain on a real repo is the entire point.
The failure recorded below was NOT "someone used bash." Bash is not the villain.
The failure was that **nothing was actually instrumented** — the toolchain we are
building never got exercised — and the gap got hidden behind scripts that printed
numbers. There is **no tier of work that gets to skip WMFX.** If WMFX can't yet
express something we need to watch, that inability is a *gap in WMFX to close*,
not an excuse to route around it.

---

## 0. What this project is (so the charter has a frame)

6digit-world builds **WMFX**: a small modeling language (`.wmfx`), an engine that
transpiles a model to Zig, and an **oracle** the model is checked against
bit-for-bit. A WMFX model watches a real data series and **flinches** when reality
diverges from what it learned. The product *is* this toolchain.

The job here was concrete and asked for four times: **instrument the koru repo
*using WMFX*** — point the toolchain at koru, surface koru's gaps, and render them
on a gap page (`korulang.org/worldmodel`) so a human can *see* where koru stands
versus its goals. This is the project's telos, `trust→sight`: turn invariants
you'd otherwise carry in your head into things you can watch fire.

**Koru's role — say it plainly, because the design doc used to read otherwise.**
Koru is the **poster-child test case** for the whole regime: the main-path,
real-world subject we instrument with WMFX to find out whether the toolchain can
instrument a project at all. It is a multi-fold experiment — *actually instrument
the project, learn from it, and extract the discipline.* This is distinct from
(and must not be confused with) *Koru-as-authoring-frontend* — using the Koru
language to author WMFX models / phantom types — which **is** deferred. Watched
subject: main path. Authoring frontend: deferred. `WMFX.md` (§"Decision locked"
and the repo map) has been corrected to state both, so this charter and the design
doc now agree rather than appearing to contradict.

The non-negotiable: **the gap page must be produced BY EXERCISING WMFX.** The
point of building it is to find out whether the WMFX toolchain can actually
instrument a repo. A page whose numbers came from anywhere *other than* a real
`.wmfx` model proves nothing about the product — it is a lie about WMFX, built in
the repo where WMFX is made.

---

## 1. What went wrong (the masquerade)

The instruments built for koru were **bash scripts that emit `signal <name>
<number>` lines and never touch WMFX**:

- `koru/models/probe_pass_floor/run.sh` — reads one snapshot
  (`test-results/latest.json`), computes `gap = inScope - passed`, echoes
  `signal gap 85`. Calls that gap "the surprise" in its own comment.
- `koru/models/probe_perf_promise/run.sh` — one pass over `benchmarks/results/*.csv`,
  finds the fastest language per workload, counts workloads with no Zig baseline,
  echoes `signal promise_unbacked N`.

These ran green under `wm`, fed the gap page, and got **merged to koru `main` and
pushed to public `korulang.org`** — and were reported as "wm is green, the watcher
fired," as if koru were WMFX-instrumented. It never was. `wm` green meant *a shell
script printed a number* — nothing more.

### Why "it's bash" is the shallow complaint

The deep defect is that **the probes hold no state, so they cannot detect surprise
at all** — they would not be world models in any language.

A real WMFX model is **stateful by construction**. From
`6digit-world/models/013_dev_silence/model.wmfx`:

- `@init` — set up state **once**.
- `@block` — runs **per tick**, one tick = one commit, stepping across a whole
  **series**.
- It carries a `threshold` frozen **in-sample** (1.5× the longest inter-commit gap
  seen in history) *before* replay, then flinches (`alarm = 1`) when a later gap
  exceeds what an active session ever showed — checked against `oracle.zig`.

The probes have **no `@init`, no `@block`, no series, no tick, no carried
expectation, no in-sample/out-of-sample split, no oracle**. They are a single
subtraction over the current reading. Run twice on the same file → same number;
they have no notion of whether 85 is normal or alarming. **Surprise requires a
model that has seen history and holds an expectation. They have none.** Calling
their output "the surprise" was the core lie.

---

## 2. The root defect in `wm` (the masquerade *vector*)

`wm` (`6digit-world/wm-cli/wm.mjs`) is today a **generic shell runner**, grounded
in its own source and `wm help`:

1. Discovers instruments **by convention**: an adapter at `<target>/wm/run.sh`,
   and/or native `<target>/models/*/run.sh`.
2. Runs each one — literally `spawnSync("bash", [inst.script, ...])` (`runOne`).
3. Scrapes stdout for `signal <name> <number>` lines (`SIGNAL_RX`); exit code =
   instrument health.
4. Caches the record to `~/.local/state/wm/<target>/`.

It **never reads a `.wmfx` file, never runs the engine, never computes or verifies
a surprise.** By its own help: *"wm discovers instruments by convention, never by
manifest"* and *"wm does not know [the method] exists."* To `wm`, a script that
runs a real model through the engine and a script that just does `echo "signal gap
85"` are **the same thing** — both are "a `run.sh` that printed a number."

That is the vector. Because the engine-driving lives inside each instrument's
**hand-written `run.sh`**, WMFX is *optional inside every instrument* — and a
hand-written script is exactly where bash can squat. Worse, `wm help` actively
**blesses** the squat: it documents a "PROBE" as *"a ~5-line run.sh that computes
one number … reports it as a signal line."* That blessing is the halo the
masquerade wore.

---

## 3. The correct shape `wm` must take

**`wm` must be a WMFX runner, not a shell runner.** The toolchain-driving moves
*out* of per-instrument scripts and *into* the tool itself.

### THE HARD LOCK (the one non-negotiable invariant)

**`wm` must be structurally incapable of running — or reporting a signal from —
anything that is not a WMFX model verified against its oracle.** Not discouraged.
*Incapable.*

- There is **no code path** in `wm` that runs an arbitrary `run.sh` and scrapes
  `signal` lines off its stdout. That path (`spawnSync("bash", …)` + `SIGNAL_RX`
  in today's `wm.mjs`) is **deleted**, not flagged.
- The **only** way a number reaches a run record is: `wm` transpiled a `.wmfx`
  model through the engine, replayed it over its series, and the **oracle
  verified** the output. A signal that did not come through that path cannot
  exist, because there is no input that produces one except a `.wmfx` model.
- An instrument directory with no `.wmfx` model is **not an instrument** — `wm`
  refuses it (hard error), never runs it green-by-default.
- "wm green" therefore *cannot* mean "a shell script printed a number." It can
  only mean **"a WMFX model compiled, ran through the engine, and matched its
  oracle."** The masquerade isn't merely caught — it has no door to enter through.

The mechanics that make the lock real:

- **An instrument is a declaration, not a script.** It is a `.wmfx` model + its
  data series + its **oracle** — the shape that already exists in
  `6digit-world/models/013_dev_silence/` (`model.wmfx`, `oracle.zig`, `run.zig`
  harness, `data/series.csv`, `expected.mmd` graph-drift gate).
- **`wm` itself drives the engine** (or a single shared WMFX harness it owns — see
  §4.1): transpile `.wmfx` → Zig (`zig build run -- --emit-zig …`), build + run the
  replay harness over the series, check **model vs oracle bit-for-bit**. The signal
  is the model's **verified** output.

This is the "FIX THE CORE TOOLCHAIN FIRST" / "build the artifact *with* the
toolchain" rule made structural: the tool cannot be used the lazy way because the
lazy way is not wired to exist.

### Faucets are the one thing that isn't a model — and the separation is HARD

A **faucet** produces the *series* a model consumes (koru's regression suite is
one; `git log` is the faucet behind `013`). The faucet/model boundary is **hard,
by decision** — not a soft convention:

- **`wm` can trigger an on-demand faucet** — run the suite, regenerate a snapshot,
  refresh a CSV. That is a legitimate `wm` capability (a faucet *needs* something
  to drive it on demand). What a faucet does is **write data**.
- **A faucet NEVER emits a `signal` line and is NEVER recorded as green/red
  world-state.** Only a verified WMFX model does that. The faucet path and the
  model-run path are separate code with separate outputs: data out of a faucet,
  signals only out of a model.
- So "wm triggered the suite to refresh the series" is fine; "wm scraped a number
  off the suite and called it a signal" is exactly what the lock forbids.

**Decided vs. still-open (resolving the internal tension a reviewer will catch):**
the *invariant* above is **decided** — `wm` is unable to run or report without a
verified `.wmfx` model, and can trigger faucets on demand. What remains genuinely
open is the *implementation form* of the lock (§4.1, §4.4): whether `wm` absorbs
the engine-driving directly or calls a shared WMFX harness, and the precise shape
of "what can emit a signal." §3 is the law; §4 is how it's wired.

### The boundary that stays

`wm` must remain **method-blind** — no ADD vocabulary (residue / commission /
float / hub) inside it. What it must stop being is **WMFX-blind**, which it never
should have been. A tool whose entire job is running world models must know what a
world model *is*. (Today it knows about shell scripts and nothing else — that is
the inversion to fix.)

---

## 4. Open questions for the reviewer ⚠

These are genuine design tensions, not settled. They are the most useful things to
push on.

1. **`wm` absorbs engine-driving vs. a shared WMFX harness `wm` calls.** Both kill
   the per-instrument arbitrary `run.sh`. Either `wm.mjs` learns the
   transpile→build→replay→oracle steps directly, or those steps live in *one*
   shared harness (taking only `.wmfx` + series + oracle, no script hook) that
   `wm` invokes. Which is cleaner? The essential invariant is only that **no
   per-folder bash script can substitute for the engine and still be blessed.**

2. **The "never by manifest / convention only" doctrine.** `wm help` is emphatic
   about convention over manifest. Moving to "an instrument is a *declared*
   `.wmfx` + series + oracle" is arguably a manifest. Is that doctrine still right,
   or was it part of what enabled the masquerade? (Note: convention-only is *why*
   any `run.sh` counts.)

3. **No escape-hatch tier — everything gets instrumented through WMFX.** The
   tempting carve-out — "this one's just a number, leave it as a stateless
   measurement" — is the same sin as the bash probe, one level up: a category of
   work that gets to skip the toolchain. **It all needs to be instrumented.** Even
   a flat floor ("gap to all-pass") or a threshold ("within 10% of host") should
   be expressed *as a WMFX model* — that is how we stress and grow the language.
   If WMFX cannot cheaply express a trivial floor/threshold today, **that is a gap
   in WMFX**, and the residue (what the engine couldn't say) is a first-class
   deliverable — exactly the kind of finding instrumenting koru is meant to
   surface. The reviewer should pressure-test the inverse claim instead: *is there
   anything that genuinely cannot or should not be a WMFX model?* The one real
   candidate is koru's existing adapter (`koru/wm/run.sh`) which runs the actual
   regression suite — that's a genuine **faucet** (a source of the series a model
   consumes), not a model itself. Faucet vs. model is the distinction to get
   right; "stateless tier that skips WMFX" is not.

4. **Gutting `wm` is decided by the hard lock (§3), not open — this is the scope
   check.** Concretely the hard lock requires removing: the `spawnSync("bash", …)`
   + `SIGNAL_RX` scrape path in `wm.mjs`; the `wm help` "PROBE = ~5-line run.sh"
   blessing; and the unconditional "any `run.sh` is an instrument" discovery. A
   native instrument *must* be `.wmfx`-backed or `wm` refuses it. The reviewer's
   job here is to confirm this removal doesn't sever the legitimate **faucet**
   role (running the suite to *produce* a series stays; emitting a scraped `signal`
   goes) — i.e. that the faucet path and the model-run path are cleanly separated,
   with only the latter able to record world-state.

5. **Where does koru's instrumentation series come from?** A WMFX model needs a
   real series with carried state. Candidates, all grounded in existing koru data:
   - **The breath (inhale/exhale)** — koru's pass-rate over time: 829 dated points
     already in `korulang_org`'s `history.json` plus koru's dated `test-results/`
     snapshots. A genuine temporal series with a flinch condition (the rate
     dropping below its recent floor, an exhale that isn't recovering). Strong
     first `.wmfx` candidate, modeled the `013` way.
   - **The pass-floor and perf-promise** — currently faked as stateless bash. The
     reviewer's question: what *series* would a real model consume to watch these
     (e.g. gap-to-all-pass over the snapshot history; per-workload wall_ms over the
     benchmark run history), and what would it flinch on? The answer reframes them
     from "a number printed once" into "a model watching a series" — which is the
     whole point.

---

## 5. Honest current state (what's on disk / live right now)

- **koru `main`** carries the fake instrumentation: `models/probe_pass_floor/`,
  `models/probe_perf_promise/`, `wm/worldmodel.mjs`, `wm/worldmodel.json` (commits
  `f7325c81`, `e05c10f2`, `8782e36e`). The `worldmodel` worktree was merged in.
- **public `korulang.org`** is serving a `/worldmodel` page + `/status` summary fed
  by those bash-derived numbers. It is live and currently misrepresents koru as
  WMFX-instrumented when it is not.
- **6digit-world** shipped a real `wm --only` bug-fix (`20a9782`) — that part is
  legitimate.
- **Zero `.wmfx` files exist in koru.** The string "wmfx" does not appear anywhere
  in the koru repo. koru's entire world-model footprint is probe-shaped bash.

The cleanup (replace probes with a real `.wmfx` instrument, correct or pull the
public page) is deliberately **not** done in this doc — this is the charter that
says what "correct" is, to be QA'd before any build.

---

## 6. One-paragraph summary (for the QA pass)

We are building WMFX (a stateful world-modeling toolchain) and were asked to
instrument the koru repo with it and render koru's gaps publicly. The job is to
instrument **all** of koru — every goal and gap worth watching — and to do that
*through WMFX*, because exercising the toolchain on a real repo is the point.
Instead, nothing got instrumented: koru's "instruments" were stateless scripts
that echo `signal` lines, which the `wm` runner cannot distinguish from real
models because `wm` is a generic shell runner that scrapes numbers and never
touches the engine. The fix is structural: make `wm` a WMFX runner where an
instrument *is* a `.wmfx` model + series + oracle that `wm` drives through the real
engine and verifies, so "wm green" means "WMFX actually ran." There is **no tier
that skips WMFX** — if the language can't yet express something we need to watch,
closing that gap is the work, and the residue is a deliverable. The only thing
that is legitimately *not* a model is a **faucet** (a source that produces the
series a model consumes — e.g. the regression suite). Please QA §3 (the shape) and
§4 (the open tensions), especially §4.3 (no escape-hatch tier).
