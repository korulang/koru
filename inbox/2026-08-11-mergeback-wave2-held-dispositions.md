# Mergeback wave 2 — held-branch dispositions (2026-08-11)

Anchor: origin/main = `5e13b389` at write time. Six branches landed this wave
(store-module-scans, worktree-produce-position, parser/dogfood, ctx-seam-impl,
thread-unbound-payloads, thread-binds-by-type — the last two as history links
whose content main already had; the renumber was landed after re-checking, see
THE HELD PILE IS FULLY RESOLVED OR RULED — one ruling remains for Lars
(2026-08-11). koru-blogpost landed; sweep-nested-key ruled DROPPED
(superseded); koruc-run-snapshot landed; the a9c7ae chain-bind branch
verified-superseded and deleted; pin-inline-flow-gate ruled DROPPED (superseded
by a ruling); the concurrency probe archived + distilled; worktree-zig-0.16-
upgrade RULED NO by Lars and deleted. The wave's branch-level work is DONE and
every held branch is resolved except the one RULE-REQUIRED block below: the
GLSL/spike merge.

**Changed since the wave receipt:** `thread-binds-by-type` was held in the
receipt ("renumbers pins absent from main") — that check used a mistyped path.
Main DOES have the 210_185 chain-arrow pin and a stale parser comment saying
210_184, so the branch (the actual renumber commit) merged cleanly and landed as
`5e13b389`, fixing the stale comment. Only these eight remain.

---

## 🟥 RULE REQUIRED — one big hold left, Lars decides

### 1. worktree-zig-0.16-upgrade — ✅ RULED NO, deleted (2026-08-11)
- Tip `af1473a4` (2026-07-19), 10 commits, ~81 files ±15k lines: koru_std and
  harness ported to Zig 0.16 (`@Struct` emitters, std.c I/O, etc.).
- **RULING (Lars, 2026-08-11): NO** — "I don't think it's good for us."
  The port is not wanted; the toolchain stays on Zig 0.15.2 (the suite's
  current build).
- Executed: local branch deleted (tip `af1473a4`); confirmed absent — no
  worktree, no origin ref, `rev-parse` fails. NOTE on the disposition's "no
  data loss" phrasing: the port was never pushed and is now unreachable, so
  this is a deliberate discard, not a parked deferral. Recorded here so the
  direction choice isn't re-litigated from the branch's existence alone.

### 2. worktree-agent-a4f597f80521eb6ad — is a GLSL backend real? (OPEN)
- Tip `71d3e568` (2026-07-31): a merge whose SECOND parent is the local-only
  spike branch `a2b3fff43e67e9db2` (never pushed). Everything else in its
  history already reached main by other routes; the ONLY delta vs main is that
  spike merge.
- Spike content: a new `src/compiler_passes/glsl_compiler.zig` (GLSL backend
  pass), a ~290-line `src/main.zig` rework, pins 690_169/690_170 (chain-bind
  swap at scale), membrane doc frags.
- **Yes** → the spike needs proper handling: its own branch off current main,
  review, suite run, then land. **No** → drop the branch. Note: its worktree is
  CLEAN, so removal+deletion loses nothing (pre-spike state is pushed at
  `origin/worktree-agent-a4f597f80521eb6ad`).

---

## 🟡 Fleet pickup — actionable without a ruling

### 3. koru-blogpost — ✅ LANDED (re-migration complete, 2026-08-11)
- Tip `91b2a8fc` (2026-07-15). Two commits: `2efa0bb1` migrates prototype-mode
  tests 400_160–166 from `.kz` (proc/zig prototypes) to pure-Koru `.k`;
  `91b2a8fc` docs(skills): blogpost titles lead with the subject by name
  (Lars-ruled 2026-07-15).
- **Done, as `ea2a0a88` on origin/main.** All seven pins migrated to input.k
  and verified green: KORU022 (161), KORU029 (162, 164 transitive via
  lib/proto.k), KORU021 (166), and the three runtime pins print their pinned
  outputs (160/163/165). Current-syntax fixes applied vs the old branch:
  `event`→`tor`, `[]const u8`→`string`, `MUST_FAIL` (dead marker) dropped for
  main's `MUST_ERROR`, three dormant `input.kjs` facets removed (no LANGUAGES
  marker; construct arms leave nothing for a `|js` facet). Belief frag
  frag-prototype-mode-panic-holes landed with the migration. The `91b2a8fc`
  docs edit was already in main's blogpost SKILL.md (line 126) via another
  route — cherry-pick no-op'd. Branch deleted as superseded.

### 4. worktree-agent-a9c7ae24224d192c0 — ✅ DELETED (verified superseded, 2026-08-11)
- Tip `e00cfe12` (2026-07-31): test(store) — a chain bind reaches a stored
  write, the swap needs no temp column (690_130-131).
- The same work is ALREADY in main via `993287f6` (came through the
  a4f597f80521eb6ad lineage, merged 28f3fd59). The trees differ slightly
  (input.k 34 vs 32 lines) — treat as a variant, not extra coverage.
- **Verified variant-adds-nothing then deleted.** Main's twins are strict
  supersets: 690_131 covers the same swap + two-row rebinding (branch: single
  row); 690_130 uses stronger initials (b: 7→3 vs b: 0→3) and the canonical
  identity name (`echo`, 230_014's real name, vs the branch's `hold`); both
  landed pins pass against current main (direct runs). Prose figures
  (1.00:1.93:3.20 column cost) are in main's comments too. Worktree removed
  with `-f` — its only dirt was the regenerable test-results/unit-tests.json
  snapshot; nothing authored was discarded.

### 5. koruc-run-snapshot — ✅ LANDED (2026-08-11, `6f04140b` on origin/main)
- Tip `d4634158` (2026-08-04): wip(harness) — rescued uncommitted
  run_regression/run_single_test edits (4 files, 72 insertions): freeze the
  compiler under test. Every koruc invocation now goes through $KORUC —
  run_regression.sh snapshots `zig-out/bin/koruc` (cp -p; mtime is the cache
  salt) before a run, run_single_test.sh reuses it or takes its own
  (trap-cleaned), the three koruc call sites in regression_lib.sh (compile,
  js-facet, ast-json) require it. A mid-run rebuild can no longer swap the
  compiler under a live suite.
- **Landed with a fix, not as-written:** the rescue's placements (lock dir,
  `.koruc-run-$$`) failed koruc's koru_home probe (module_resolver.zig steps
  up past bin/ twice only when the bin-parent is named "zig-out*") — the
  emitted backend referenced `<snapshot>/src/ast.zig` and the run failed.
  Snapshots now live at `<checkout>/zig-out-run-$$/bin/koruc`, same shape as
  zig-out/bin, removed with the lock trap. Verified on all three paths
  (standalone run, must-error pin, suite-preset reuse). Branch deleted as
  superseded.

### 6. sweep-nested-key — ✅ RULED DROPPED (superseded, 2026-08-11)
- Tip `b92f8661` (2026-07-30): wip(store) — self-labeled "HALF FIX, DO NOT
  MERGE ALONE", on top of pin 690_112 (65a1063d: a row binding does not survive
  nesting).
- **Ruling: the defect is FIXED in main; drop the branch — nothing unique
  remains.** Verified: pins 690_110/690_111/690_112 all PASS against current
  main (direct runs; correct pairwise totals — the shared-cursor wrong answer
  the half-fix warned about is gone). Main's store.kz now holds BOTH halves the
  commit demanded ("land only together with the cursor fix"): arm-line symbol
  keying (`__store_sweepbody_{s}_L{sc.location.line}`) AND a per-bind dense
  cursor (`__koru_sdix_{bind_key}_L{line}`, landed 2026-07-31 `9a05ded8` /
  08-02 `94ae27eb` — one day after the half-fix). The branch's belief frag
  (frag-store-verb-placement.md) is in main via another route. Branch/worktree
  left in place (worktree dirty with test-results/unit-tests.json snapshot
  noise) — safe to `worktree remove -f && branch -D` whenever the dirt is
  cleaned.

---

## ⚪ Low-temperature holds — decide or drop, no urgency

### 7. pin-inline-flow-gate — ✅ RULED DROPPED (superseded by a ruling, 2026-08-11)
- Tip `89c2615d` (2026-08-08): wip(210_190) — a loose working-tree edit,
  "preserved not discarded" (comment-only: 21 lines removed, 2 added — a
  revised diagnosis of the still-red named-single-outcome pin). Pushed at
  `origin/pin-inline-flow-gate`.
- **Dropped: the diagnosis thread it preserved was settled by a ruling.** Main
  now REFUSES the shape by design — 210_190 became
  `210_190_reject_named_single_outcome` ("a single outcome does not get a NAME",
  an acceptance window `b8570de5` was reverted; the error message teaches the
  replacement `-> { … }` bare return) — and the arm-produce case the revised
  diagnosis pointed at has its own positive pin (350_019). The old
  `210_190_named_single_outcome` dir is gone from main (0 paths). Folding would
  add commentary about a dead pin whose premise main repudiates. Local branch
  deleted; `origin/pin-inline-flow-gate` left in place (remote-ref policy).

### 8. worktree-agent-a4c0e547f7e3868fc — ✅ LANDED (archived + distilled, 2026-08-11)
- Tip `932d76d6` (2026-08-08): 3 probe commits, no product code —
  probes/concurrency_calibration/ (sabotage.py + measured.txt): the
  concurrent-region colouring is 56.7% "can't-tell", and the region has no Koru
  in it.
- **Landing: `7bdfe468` on origin/main.** The reproducible instrument
  (sabotage.py, analyse.py, measured.txt, three dump scripts) is archived at
  probes/concurrency_calibration/; the finding is distilled into
  frag-region-colouring-cannot-see-its-regions (premise defect: threading.kz
  is a host shim with no Koru region to colour; opacity blocks colouring
  inside real regions; the next rung is visibility, not the algorithm).
  Branch deleted; worktree removed (-f). Discarded dirt, all non-authored:
  python __pycache__, two auto-registered orphan signal placeholders ("refine
  me"), and a hooks/post-commit.cjs local edit replicated in ~9 other
  checkouts.

---

## Context that matters for any pickup

- The wave's merges were fast-forward pushes to origin/main, no force anywhere;
  all 7 landed SHAs (`2fb148f6`, `3468e2a9`, `9c52c989`, `ce8d9e43`,
  `fff03b3a`, `5e13b389`) are in origin/main's history.
- Local `main` in `~/src/koru` is a moving target owned by the active
  "cascade-arm" session; work in temp worktrees, never in that checkout
  (30 uncommitted entries there are not yours).
- The full Koru suite was not run for these merges; the claims-registry pins
  (310_111/310_112) were verified green against the merged build.