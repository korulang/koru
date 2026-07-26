---
challenge: toolchain-hardening
kind: frame
status: standing
yields: one confirmed toolchain defect drained into a fix or a curation
family: toolchain
---

# Challenge 002 — Toolchain & harness hardening

> Make the *machine* better, not the language. Find where the toolchain — build,
> `run_regression.sh`, the generators (`scripts/generate-*.js`), the CLI, and the curated
> corpus itself — has friction, bugs, redundancy, or rot. Each real issue the arbiters
> confirm drains into a fix or a curation. Run it repeatedly — a flywheel for the soil the
> garden grows in.

A standing **generative frame**, not a backlog. Each run re-derives fresh probes from the
live toolchain; only the *outputs* (fixes, removed cruft, sharper harness) persist.

---

## The faucet — how contestants generate signal

Three faucets, all draining into the same arbiter judgment.

1. **Cold-operator friction (primary).** Use the toolchain as someone who has never seen it:
   build it, run `./run_regression.sh` (and a single test, and `--help`, and the generators),
   read the output. Where did it confuse you, lie to you, fail silently, make you guess, or
   take a step that shouldn't exist? Ground every friction in the exact command + what it did.
2. **Corpus quality (the garden).** The curated `koru-by-example.json` test selection has rot:
   audit it for **Zig-example bias** (examples that are really host-language demos, not Koru),
   **redundancy** (N tests that demonstrate the same shape), and **low-value/horrible entries**.
   Propose specific removals/replacements with the reason.
3. **Harness correctness.** Find a place where the harness *cannot-lie* claim is actually a
   lie: a test that passes for the wrong reason, a status that misreports, a generator that
   emits stale/duplicate output, a cache that hides a real failure.

---

## ⚖️ THE HARD STANCE — make a qualified guess, never a verdict (binding on EVERYONE)

When you hit friction or a suspected bug, there are always two readings, and they are not
yours to choose between:

- **(A) the toolchain is wrong** — a real bug, gap, or redundancy in the machine.
- **(B) your expectation is wrong** — the tool works as intended and you misread its contract.

You MUST make a **qualified guess** (A / B / unsettled) with a `confidence` **defined by
evidence**: `grounded` = you cite the toolchain's own stated contract (a `build.zig` step, a
`run_regression.sh` flag, a generator's header comment, an existing passing run) — the only
level at which a hard lean is allowed; `inferred` = reasoning, no cited contract; `unsettled`
= no prior art (a frontier). A 50/50 shrug is forbidden. You still write **both** readings in
full even when you lean A. You NEVER edit a tracked file or "fix" anything — propose only. The
arbiters rule which side moves, on the walk. Everything you report is a hypothesis grounded in
something you actually ran.

---

## For contestants (the brief, sealed)

Dropped into `/Users/larsde/src/koru`. **Read the repo-root standards first** (`CLAUDE.md`,
`AGENTS.md`). Build once (`zig build`). Then exercise the toolchain on your assigned surface.

Return 4–8 **findings**. For each: `what` (the friction/bug/cruft), `where` (the exact
command + file:line), `evidence` (what you ran and what happened), `divergence_class`
(friction / bug / redundancy / corpus-rot), `reading_A_toolchain_wrong`,
`reading_B_expectation_wrong`, `qualified_guess` {lean, confidence, prior_art},
`proposed_action` (the fix or curation — proposed, NOT applied), `severity`.

Do NOT edit tracked files. Everything is a hypothesis — ground it in a real run.

---

## For arbiters (Lars + Claude)

On the walk, per finding: decide which side moves (own that it's a judgment), then drain the
real ones — fix the harness/generator/CLI, or curate the corpus (remove the Zig-biased /
redundant / horrible entries). **Verify before merging** — re-run the command yourself; every
contestant claim is hypothesis. **Never** "fix" a tool to match a misread contract (the mirror
of conformance fraud); never let a sealed contestant settle which side is wrong.

## Pass / value contract

A run earns its keep when it produces **≥1 confirmed improvement** the arbiters merge: a harness/
generator/CLI fix, or a curation that removes real cruft. Zero confirmed = the toolchain's solid
on the probed surface; move the probes.
