---
name: registry-drain
description: Drive koru's diagnostic-code registry to green. Use when `zig run scripts/registry_check.zig` FIRES on DEAD/ORPHAN_EMIT/ROTTEN_PIN codes and you need to disposition each one (wire an emit / reserve / consolidate). The watcher detects drift in src/errors.zig's ErrorCode enum; this is the playbook for clearing it. Derived from three cold-room probes — trust the procedure, verify every claim.
---

# Draining the diagnostic-code registry

`scripts/registry_check.zig` is a FACT-only watcher: it fires when a diagnostic code drifts
between three sets — DECLARED (the `ErrorCode` enum in `src/errors.zig`), EMITTED (codes the
compiler actually raises), and PINNED (codes the regression suite asserts). When it's red, each
flagged code needs a **disposition**. This is how you decide and apply it.

## The loop

1. **See the drift.** `zig run scripts/registry_check.zig`
   - `DEAD` = declared but never emitted (a lie: the enum claims a check the compiler doesn't do)
   - `ORPHAN_EMIT` = emitted but never declared (declare it in the enum)
   - `ROTTEN_PIN` = a test pins a code that can't resolve (declare it, or fix the test)
   - Each DEAD code prints its declaring line, its family's emitted siblings with counts, and a
     bug-vs-reserved **hint**. The hint is a hint, not a verdict — see the warnings.

2. **Get the evidence.** For any code: `zig run scripts/registry_check.zig -- confirm <CODE>`
   - prints EMITTED sites, PINNED tests, POLICY (doc mentions), a same-description DUPLICATE,
     git HISTORY, and a verdict hint. This is the battery — don't reconstruct it by hand.

3. **Decide the disposition** from the `confirm` evidence:

   | Evidence | Disposition | Why |
   |---|---|---|
   | DUPLICATE: a same-description sibling that IS emitted (e.g. `KORU082` ≡ `TYPE003`) | **CONSOLIDATE / RETIRE** | redundant declaration, not unwired work — merge call sites onto one code or delete it |
   | No detector exists (whole family dead; nothing in src/ computes the condition) | **RESERVE** | unbuilt future semantics — the feature was never built |
   | Detector EXISTS but never tags this code (lone gap, detector present) | **BUG → wire** | the check runs but forgot to raise this code |

4. **Apply:**
   - **Reserve:** append the bare code below the marker in `scripts/registry_reserved.txt`, with a
     `#`-prefixed rationale line above it.
   - **Wire (bug):** add a `.CODE` emit at the detector site (or an `errors.zig` helper like
     `moduleNotFound → .KORU002`), then pin a regression test:
     `tests/regression/<CLUSTER>/<NNN_name>/` with `input.kz`, `MUST_ERROR`,
     `EXPECT=FRONTEND_COMPILE_ERROR`, `expected_error` containing the code. Run `./run_regression.sh <id>`.
   - **Consolidate:** point the duplicate's call sites at the kept code; reserve or delete the husk.

5. **Verify:** re-run `registry_check.zig`. The code drops out of its bucket. (The suite stays red
   until ALL flagged codes are dispositioned — GREEN-for-one ≠ checker-passes.)

## Warnings (each cost a cold operator real time — heed them)

- **The lone-gap hint is NOT a verdict.** "LONE GAP → likely a BUG" only counts sibling
  emit-density. It cannot see a same-description duplicate or a never-built detector. ALWAYS run
  `confirm` before wiring an emit. (In a probe, this hint anchored an agent into flipping a
  correct RESERVED verdict to a wrong BUG.)
- **Proving RESERVED is proving a negative.** You must confirm NO detector exists — so you have to
  know the *shape* of the missing detector. A cycle-detector needs a visiting/in-progress set over
  a call graph; an indent-validator needs a magnitude check, not a comparison. Grep for that
  *shape*, not just the code token. (A bare `grep KORU061` proves nothing.)
- **LLM/agent reasoning is a hypothesis, not ground truth.** The probes that built this skill also
  produced confident *false* claims (a "double-counted generated mirror" that wasn't scanned; a
  "named in CLAUDE.md" policy that didn't exist). Verify every load-bearing claim against live
  source before acting.
- **`registry_reserved.txt` format:** any uncommented line suppresses, regardless of the `---`
  marker (the marker is decorative). One bare code per line; put rationale on a preceding `#` line,
  not a trailing comment.
- **"Reserved" ≠ "redundant."** A duplicate code (delete/consolidate candidate) is not unbuilt
  future semantics. Don't file a redundant code as reserved — note it as a consolidation target.

## Why trust this procedure

It was *derived*, not designed — see `floats/2026-06-07-koru-drain-loop.md` in the 6digit-world
repo. Three cold-room probes (zero-context agents driving the same codes) measured where the
toolchain failed to guide them; each failure became a fix (the per-code diagnosis, then the
`confirm` battery), and re-probing showed the verdicts converge to correct/high-confidence and the
friction climb from "the tool tells me nothing" to a subtle two-surface disagreement. The
procedure above is what survived that loop.
