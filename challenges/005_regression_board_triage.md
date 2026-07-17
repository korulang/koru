# Challenge 005 — Regression-board triage & fix

> The suite is already carrying **166 honest reds**. Each one is a question the language
> hasn't answered yet — a compiler bug, a missing feature, a diagnostic that leaks host
> noise, or a *test* encoding intent the language has moved past. This challenge points the
> arbiter engine at that standing board: claim a red, **read it in the compiler's own terms**,
> and hand up a grounded diagnosis — optionally with a candidate fix. Toolchain-first: a green
> is a *side effect* of the language answering the question, never the goal. Run it repeatedly —
> a flywheel that drains the board one honest reading at a time.

A standing **generative frame**, not a backlog. The reds are not a to-do list to burn down;
they are a live *surface* the arbiters re-read every run. Only the *outputs* persist —
confirmed readings drained into minimal pins, merged root-fixes, and named language gaps.
Where 001 generates **fresh** probes and 004 ports **new** kernels, this challenge mines the
board **that already exists**.

---

## The surface — the red board

- **The board:** `./run_regression.sh --regressions` (what broke, when it last passed, the
  breaking commit, the failure mode) and `./run_regression.sh --status` (166 reds across
  categories). A single test: `./run_regression.sh <id>`. Its history: `--history <id>`.
- **A test lives at** `tests/regression/<CLUSTER>/<NNN_name>/` — `input.k`/`input.kz`, an
  `EXPECT` stage, `MUST_RUN` + `expected.txt` (positive) or `MUST_FAIL` + `expected_error.txt`
  (negative), and `post.sh`. `EXPECT` maps to the pipeline stage: `FRONTEND_COMPILE_ERROR` = A,
  `BACKEND_COMPILE_ERROR` = B, `BACKEND_RUNTIME_ERROR` = C (see `CLAUDE.md`, "four stages").
- **Compiler:** `./zig-out/bin/koruc` (`--check`, `build`, `run`). Build it fresh once:
  `zig build`. Not on PATH; run from repo root.
- **The three failure classes worth knowing** (from the harness verdict): a normal red
  (`MUST_RUN` fails to run/produce output), an `expected-error-missing` (a `MUST_FAIL` no
  longer emits its diagnostic), and a **`must-fail-passed`** — a negative test that now *passes
  clean*. That last class is the highest-value target: a guard that silently stopped biting is
  a hole in the language's law, not merely a stale test.

---

## Two entry types

Mirror of LIFT's new-lift / quality-pass — same act at two commitment levels:

1. **Diagnosis (the float) — primary, sealed, propose-only.** Claim a red, run the triage,
   hand up both readings + a qualified guess + a *proposed* pin. Touches no tracked file.
   This is the engine; most runs are this.
2. **Candidate fix (the escalated float) — worktree, still a proposal.** Only when your
   diagnosis reaches a **grounded** lean-A (a passing adjacent test cited): you MAY spin an
   isolated `git worktree`, close the **root**, run the gates, and hand up the **diff as
   evidence**. It does **not** merge and does **not** settle the ruling — it is the strongest
   possible float, judged on the walk. The worktree evaporates if not judged in.

> **Current stance (2026-07-17): run this FLOAT-ONLY.** The compiler and the corpus are still
> moving too fast for a contestant to responsibly close a root — a fix floated today may be
> obsolete tomorrow, and a diagnosis grounded deeply in the suite is the far higher-value
> output right now. So **entry type 1 is the whole challenge for now.** Entry type 2 is
> documented as the escalation we grow into once the ground settles — it is not the current
> default and contestants should not reach for it unless the walk explicitly opens it.

**The variance lives in *which red you claim and what reading it gets* — never in *how* a
single red is fixed.** Fixing one red is convergent: there is one correct root move, not a
catalog of creative variants. Producing divergent *fixes* for the same red is noise. Producing
divergent *coverage* across the 166-red board, and honest divergent *readings* where a red is
genuinely ambiguous, is the whole value.

---

## ⚖️ THE HARD STANCE — make a qualified guess, never a verdict (binding on EVERYONE)

A red tells you something is misaligned. It tells you **nothing about which side is wrong.**
There are always at least two readings, and they are **not the contestant's to choose between**
(the asymmetric truth hierarchy — `ARBITER_DRIVEN_DEVELOPMENT.md`):

- **(A) the toolchain is wrong** — a compiler bug (silent wrong answer, crash, bad codegen), a
  missing language feature, or a diagnostic that leaks host (Zig) noise instead of a Koru-level
  error. The red is honest; the *compiler* moves.
- **(B) the test is wrong** — it encodes intent the language has moved past, invented syntax
  that never was law, or a wrong expectation. The red is stale; the *test* moves (changed or
  deleted, **with a visible reason**).

You MUST give a **qualified guess** (A / B / unsettled) with `confidence` **defined by
evidence, not a vibe** (a self-assigned percentage is theater — an LLM isn't calibrated):
`grounded` = you cite a **passing** `SUCCESS`-marked regression test of this exact shape or an
adjacent one (verifiable; the **only** level at which a hard A/B lean — or a candidate fix — is
allowed); `inferred` = spec/code reasoning with no passing test found (weak lean, flagged);
`unsettled` = no prior art (a frontier finding, not a guess). A 50/50 shrug is forbidden — it is
just permission to stop digging. Write **both** readings in full even when you lean A; skimping
the side you guessed against is the exact failure this stance exists to prevent.

**The two frauds stay forbidden, at maximum force** (this challenge is one bad incentive away
from manufacturing exactly the lying-green the corpus spent months purging):

- **Conformance fraud** — editing a test until the red goes green with no investigation in
  between (`CLAUDE.md`, "the one pathology to never commit"). A green earned by contorting the
  test is worth **less** than the red was.
- **Route-around / green-farming** — patching the *artifact* or contorting `input.k` to dodge a
  toolchain gap the red exists to surface, then reporting green. The green checkmark is the lure;
  a pass that hides the gap is a loss.

A candidate fix (entry type 2) is a **hypothesis with a diff attached**, never a ruling. It does
not license editing a test to match the compiler, and it does not settle which side moves — the
arbiters do, on the walk.

---

## For contestants (the brief, sealed)

You are dropped into `/Users/larsde/src/koru`. **Read the repo-root standards first** —
`CLAUDE.md` and `AGENTS.md` — before anything else; they are the language's stated rules. Build
koru once (`zig build`) so `./zig-out/bin/koruc` is fresh. Pick your reds off the live board
(`./run_regression.sh --regressions` / `--status`) — **read the board first and claim reds no
prior finding in this run already covers** (variance is the metric; diverge across the board).
Prefer a `must-fail-passed` when one is open — it is the richest signal.

Produce **3–6 findings**, one per red claimed. For each:

- `test_id` — the regression id / path (e.g. `305_subflow_invalid_branch`).
- `failure` — the harness verdict (`must-fail-passed` / `expected-error-missing` / the red
  mode), the `EXPECT` stage, and — from `--history` — when it last passed and the breaking
  commit, if any.
- `what_the_test_pins` — in your own words, the shape or law this test exists to guard (its
  *intent*, not its current red/green state).
- `actual` — what `koruc` does on the input **right now** (the exact command, exit, stderr /
  the diagnostic or its absence / the wrong value).
- `reading_A_toolchain_wrong` — the concrete evidence the *compiler* is at fault. If the red is
  a real language gap, **name the gap in the compiler's own terms** (the missing feature, the
  missing diagnostic, the missing guarantee).
- `reading_B_test_wrong` — the concrete evidence the *test* is stale or misconceived. **Hunt the
  `SUCCESS`-marked regression tests** for this shape or an adjacent one; cite the path. If you
  find none, say "no prior art found" — that absence is signal, not an excuse to skip the hunt.
- `qualified_guess` — `{ lean: A | B | unsettled, confidence: grounded | inferred | unsettled,
  prior_art: <cited SUCCESS test path or "none found"> }`.
- `proposed_pin` — IF the arbiter rules it real: the **minimal** runnable test that isolates the
  reading (a small `input.k` + `MUST_FAIL`+`EXPECT`+`expected_error`, or `MUST_RUN`+`expected`).
  A minimal pin that isolates the exact gap is worth more than the compound application test it
  came from. Proposed, not applied.
- `severity` — low / med / high.

**Diagnosis contestants edit no tracked file, add no test, fix nothing — propose only.**

**Candidate-fix contestants (only on a `grounded` lean-A):** additionally spin an isolated
worktree off `main` — `git worktree add ../koru-fix-<test_id> main` — work **only** there, close
the root, and self-check the gates below. Hand up: the `git diff`, the exact `koruc` command
proving the target red now goes green **through the full pipeline** (`build`/`run`, never
`--check` alone), and a `./run_regression.sh --cache --parallel 8` tail proving **zero NEW
reds**. Never touch the main checkout. Never edit a test to make the red go green. If your fix
needs a test changed, that is a `reading_B` finding to hand up separately, not a quiet edit.

Everything you report is a **hypothesis** grounded in something you ran through `koruc` this
session. Do NOT commit. Do NOT merge. The worktree is scratch.

---

## For arbiters (Lars + Claude)

On the walk, per finding:

1. **Verify before draining.** Re-run `koruc` on the input yourself; re-read the diff. Every
   contestant claim is hypothesis — confirm the red mode, the reading, and (for a fix) that the
   green is earned by the language getting more capable, not by a contortion.
2. **Decide which side moves** — a *design* call, not a mechanical one. A newer commit is not
   evidence; "the compiler is what runs" is not evidence. Weigh the stated rules against the
   passing examples.
   - **Toolchain wrong** → fix the root (merge the candidate diff or commission the fix), then
     confirm the **minimal pin** lands so the reading is captured runnably.
   - **Test wrong** → change or delete it **with the reason visible in the commit** (per
     `CLAUDE.md`, "understand tests before changing them"); a `MUST_FAIL` that should now pass
     becomes a positive pin locking in the confirmed legality.
   - **Real language gap** → keep the red honest and name the gap in the compiler's own terms;
     the red *is* the ledger entry.
3. **Surface regressions loudly.** A candidate fix that turns any *other* green red is a
   regression — named before merge, never absorbed.

**Never:** treat a red as automatically the test's fault (or the compiler's); edit an expectation
to match the compiler to make red go away (conformance fraud); merge a fix that dodges the gap
the red exists to surface; let a sealed contestant settle which side is wrong.

---

## Pass / value contract

A run earns its keep when it produces **≥1 confirmed drainable outcome** the arbiters merge: a
root-fix that turns a red green by the language genuinely answering it, a minimal pin that
captures a confirmed reading, a stale test corrected/retired with a visible reason, or a
confirmed-and-named language gap. Findings that merely restate a red without a grounded reading
are ballast, not the deliverable. Zero confirmed across a full run is itself signal — the reds
you probed are settled honest-roadmap markers; move to a different cluster of the board.

---

*Planted 2026-07-17 on a challenge-authoring walk. This brief is a slow-clock artifact —
read-many, write-rarely; tuning it is a Gardener act, logged here. Modeled on `001_parser_
hardening.md` (the propose-then-drain spine) and `004_compute_kernel_gap_mining.md` (the
toolchain-first, minimal-pin drain), pointed at the standing red board instead of fresh probes.*
