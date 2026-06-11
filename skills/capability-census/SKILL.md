---
name: capability-census
description: Run a progressive capability census — prove Koru can do real tasks of increasing complexity, pristinely, or pin the precise frontier that blocks it. Use when climbing a proof corpus (e.g. tests/regression/810_AOC_2015), authoring or judging a proof submission (tests/regression/820_PROOFS), or deciding whether a task solution is "done" — the pristine bar lives here.
---

# Capability census — pristine or frontier, nothing in between

The method: point Koru at a ladder of **real tasks** ordered by complexity and
climb it in order. The deliverable is never the solutions — solutions to these
tasks exist by the thousand in every language. The deliverable is the **map**:
for each rung, either a pristine proof that Koru does it beautifully, or a
precisely-pinned frontier naming what blocks it. The ordered red map IS the
language roadmap.

## Why external corpora are ideal ladders

A corpus someone else wrote (Advent of Code, Project Euler, Rosetta tasks,
exercism tracks) gives you three things free:

1. **No solving glory.** The answers are known, so the only honest deliverable
   is the census — there is nothing else a submission could be for.
2. **Free oracles.** Published statements come with worked examples and their
   answers. Pin those (`MUST_RUN` + `expected.txt`); never republish licensed
   puzzle inputs (e.g. personal AoC inputs run locally, gitignored).
3. **An ordering you didn't choose.** Early rungs are pure language surface;
   complexity arrives in an order designed to teach humans — which means gaps
   surface in the right order to teach a language.

## The pristine bar (ratified 2026-06-11)

A rung has exactly **two terminal states**:

- **Pristine green** — the idiomatic, streamlined spelling compiles and runs.
  Koru carries the structure; host code is leaves only. This is a proof and it
  is swept into the corpus.
- **RED frontier pin** — `input.kz` spells the solution the way we *wish* it
  read (the 010_058 pattern: pins as design documents), it fails today, and
  the header names the gap precisely.

**Never commit plumbed-green as a rung's solution.** A green test whose
structure lives in host Zig reads as "Koru can do this" when the host did it —
a lie that compiles, the conformance-fraud twin. There is no point in solutions
that aren't pristine.

## The .k covenant (ratified 2026-06-12)

The terminal form of every rung is a **pure `.k` file** — no `~`, no host
lines. The point of the whole climb is gap-closing until user programs NEVER
need a `.kz` file; `koru_std`'s own `.kz` facets are where host leaves
legitimately live, and the climb's job is to migrate every user-side leaf
into stdlib events.

The transitional form is the **dual-facet split**: `input.k` holds the pure
structure (contract events must be `pub` — KORU111 enforces this), and the
same-stem `input.kz` facet holds the remaining procs. **The facet IS the
rung's frontier ledger** — its header lists each proc and the gap that
retires it; the facet shrinking to zero bytes is the metric of the climb.

## Plumbing probes — encouraged, never committed as solutions

Writing the ugly version FIRST is good method, not a violation of the bar. The
probe answers "does the range work at all" end-to-end, and its ugliness is the
design data: the exact line where you reached into the host is the exact
surface the language is missing. Stare at the reach, design the surface it
wants, then either close the gap in the toolchain (the default) or pin the rung
RED with the wished-for spelling. The probe itself is then rewritten or
discarded — it never ships as the proof.

## The per-rung loop

1. **Statement** → read it; extract the published worked examples.
2. **Pin** → test dir with the examples as oracle (`MUST_RUN` +
   `expected.txt`). Cluster convention: one dir per rung, e.g.
   `810_011_day01_part1`.
3. **Attempt the natural shape** — the code you'd write if the toolchain were
   already perfect. Do not pre-defend, do not dodge walls you feel coming.
4. **Pristine green?** → next rung.
5. **Blocked?** → RED pin + frontier note naming the gap, then decide on the
   walk: close the gap now (default for surface gaps — go back to the
   toolchain first) or climb on past a consciously-parked wall.

Gap-closing sessions interleave as the red map dictates. Every plumbing reach
that survives into a green proof must itself be a named frontier note — host
leaves are legal, undocumented host structure is not.

## Instances and siblings

- **`tests/regression/810_AOC_2015/`** — the chartered corpus climb (AoC 2015,
  in order). Charter: days 1–5 green is milestone 1; success metric is "every
  attempted rung either pristine green or a named frontier," never stars.
- **`tests/regression/820_PROOFS/`** — the open generator: contestants pick
  their own use cases to expand the proof catalog. Brief at
  `820_PROOFS/CHALLENGE.md`.
- **`tests/regression/800_CHALLENGES/`** — the sibling organ: pressure programs
  that hunt cockroaches in feature *combinations*. Different selection axis:
  800 selects for language-corner stress, the census selects for use-case
  coverage.
