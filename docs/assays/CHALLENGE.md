# koru-assay — gap-mapping challenge

Parameterized generator. One target per contestant; the brief carries the
target in the `TARGET:` slot. The deliverable is a gap MAP, not an
implementation — a measured answer to "what would it take to build X in
Koru?" filed under `docs/assays/` as `YYYY-MM-DD-<target>.md`.

## Targets (draw at fire time)

- **tool-assay** — an external CLI tool (jq, rg, sd, watchexec…). Map the
  surfaces a faithful port needs.
- **capability-assay** — an internal question ("can the bridge ingest
  compiled resources at runtime?", "what does runtime regex need?"). Map
  what exists vs. what's missing across koru/koru-libs/orisha.
- **package-assay** — an existing koru-libs package's fitness for its
  stated purpose.

## The rules — what makes a map honest

1. **Probe every claim.** A claimed gap is either (a) a minimal compile
   attempt that refused (quote the diagnostic), or (b) a cited surface
   that proves absence. ~50% of "the compiler can't" claims are the
   claimant's misunderstanding — an unprobed gap is an unmeasured one.
2. **Survey before you claim.** Inventory `koru_std/`, `koru-libs/`, and
   the relevant `tests/regression/` surface FIRST. A map claiming a gap
   in something we already ship is worse than no map.
3. **Three columns, no fourth.** Every surface needed lands in exactly
   one of: *exists* (named surface + evidence), *missing-blocker*
   (probed refusal — the commission-worthy items), *missing-but-
   portable* (absent but the workaround shape is obvious). An item that
   fits no column is a question, not a map entry.
4. **End with a recommendation.** The map's last section answers: would
   you commission this? At what cost class — stdlib surface, compiler
   feature, package work?
5. **Spellings are Lars's.** A map names needs, not spellings. Never
   invent a surface spelling as part of the map.

## Judging

The seat verifies claims at the artifact level: every *missing-blocker*
must reproduce or cite; every *exists* must name the surface. A map that
guesses gets evaporated; a map that measures gets filed to
`docs/assays/` and its blockers become commission candidates.

## Replayability

The catalog is the answered-question set, not the target set — the same
target may be assayed again later and "the map moved" is its own
finding. A class goes dormant when its interesting targets run out;
fires.json records each fire with its targets.
