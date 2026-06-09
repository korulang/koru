# The koru drain loop — toolchain-fixing via cold-room probes (2026-06-07)

Proof that the `wm` methodology works: a watcher, discovered by a transparency float, was made
**clean-start-usable** not by guessing what a cold operator needs, but by *measuring* it — dropping
zero-context agents on the tool, watching where they flailed, fixing the tool, and re-measuring.
Three rounds. The friction is the product; the fixes are downstream of it.

## Setup

- **Target:** the `registry-coherence` watcher in koru (`scripts/registry_check.zig`) — fires on
  diagnostic-code drift in `src/errors.zig`. 11 DEAD codes outstanding.
- **Probe:** 3 cold-room agents, each assigned one DEAD code (`KORU061`, `PARSE002`, `KORU082`),
  minimal brief ("the watcher fires; drive your code to green; propose-only; **log every friction**").
  They get the tool and nothing of what the builder knows.
- **Loop:** probe → read the friction → fix the toolchain → re-probe the *identical* task → compare.

## The three rounds

| code | R1 (plain checker) | R2 (+per-code diagnosis) | R3 (+`confirm` battery) |
|---|---|---|---|
| KORU061 | reserved (high) | reserved (high) | reserved (high) ✓ |
| PARSE002 | **bug** (high) | reserved (med) | reserved (high) ✓ |
| KORU082 | reserved (med) | **bug** (high) ⚠ | reserved (high) ✓ |

Ground truth (verified against live source): all three are **reserved**. KORU082 is a redundant
duplicate of TYPE003; PARSE002's indent-validator was never built (the parser breaks comparatively,
no `addError`); KORU061's cycle-detector doesn't exist (the one `visiting` set is a self-loop guard).

### R1 → R2: fixed "no diagnosis", introduced anchoring
R1's friction, all three agents: *"the tool reports the disease, not the diagnosis or cure."* They
reverse-engineered bug-vs-reserved from compiler source. **Fix:** the checker now prints each DEAD
code's declaring line, its family's emitted siblings with counts, and a "lone gap → likely bug"
hint. **Cost, measured in R2:** the hint *anchored* KORU082 from a correct RESERVED (R1, careful)
to a wrong BUG (R2, followed the steer). The heuristic counts siblings; it can't see a semantic
duplicate. The fix lowered friction *and* created a new, subtler failure — exactly the trade to
watch for.

### R2 → R3: fixed anchoring with `confirm`, verdicts converged
R2's friction: *"the steer can mislead, and there's no way to confirm."* Every agent reinvented the
same verification ritual (grep src for emit, grep docs for policy, grep tests for a pin, look for a
same-description twin, `git log -S`). **Fix:** `wm confirm <CODE>` codifies that battery — and the
key signal it adds is the **same-description DUPLICATE** the heuristic can't see (`KORU082 ≡
TYPE003`). **Result in R3:** all three agents discovered and ran `confirm`; **all verdicts converged
to correct/high-confidence**; PARSE002 hit *zero* friction.

### R3: the friction climbed another rung
R3's top blocker is no longer "the tool fails me" — it's that the **check output and `confirm`
disagree** for a duplicate (the softened lone-gap hint is seen before the operator runs `confirm`),
and a deeper finding: **"reserved" conflates two dispositions** — *unbuilt future* (KORU061) and
*redundant duplicate* (KORU082, a delete/consolidate candidate). Different problems, one list.

## What this demonstrates

- **The toolchain is the product, and friction is how you measure it.** Draining the codes by hand
  (with builder context) would have proved nothing. A cold operator's stuck moments are the spec.
- **Each fix raises the floor.** Friction went from "no signal" → "signal that can mislead" → "two
  correct tools that slightly disagree." Every rung is a better problem than the last.
- **Agent output is a hypothesis.** The probes produced confident *false* findings (a non-scanned
  "double-counted mirror"; a non-existent "named in CLAUDE.md" policy). Every load-bearing claim was
  verified against source before acting — two were rejected.
- **Convergence is the success signal.** Not "friction dropped" — *the verdicts became correct and
  confident* once the tool handed over the evidence instead of making operators reconstruct it.

## Artifacts

- The watcher + `confirm` + the playbook live in koru: `scripts/registry_check.zig`,
  `scripts/registry_reserved.txt`, `skills/registry-drain/SKILL.md`.
- Open next rungs (R3 backlog): unify the check-output hint with the duplicate-check so the two
  surfaces agree; give the toolchain vocabulary for *retire/consolidate* vs *reserve*.
- The actual draining is left to a koru-resident session using the `registry-drain` skill — not done
  from the building session, on purpose (that would re-introduce builder-context bypass).
