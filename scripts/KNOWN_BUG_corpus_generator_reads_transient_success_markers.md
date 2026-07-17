# BUG: corpus/skills generators silently truncate when run mid-suite

**Defect.** `scripts/generate-corpus.js` (and the sibling `generate-skills.js`)
resolve "which tests are passing" by scanning each test directory for a
per-test **`SUCCESS` marker file** — see `scripts/lib/corpus.js` `walk()`
(`hasSuccess = entries.some(e => e.name === 'SUCCESS')`, ~line 38). Those
markers are **transient run-state**: a `./run_regression.sh --no-cache` run
clears them and rewrites them per-test as each test passes. So if a generator
runs while the marker set is partial — which is exactly what the post-test
`scripts/prose_check.sh` watcher does (`node scripts/generate-corpus.js`), and
what any concurrent/interleaved suite run produces — it sees only the handful of
tests currently marked `SUCCESS`, generates a **truncated corpus**, and
**overwrites the committed generated docs** with it. There is no guard: the
generator will happily shrink `koru-by-example.md` from 22 tests to 1 (deleting
~5000 lines across `docs/by-example/*`, `koru-by-example.md`,
`skills/*/SKILL.md`) and exit 0. The corruption is silent and looks like a real
diff.

**Observed (2026-07-18).** During a `--no-cache` suite run that briefly overlapped
a second regression run, the post-test `prose_check` regen collapsed the corpus
docs to "1 hand-picked test." Re-running `node scripts/generate-corpus.js` after
the suite fully settled regenerated the correct "22 tests across 9 categories" —
confirming the script is correct but its **input (the SUCCESS-marker set) is
unstable**.

**Repro.**
1. `rm tests/regression/**/SUCCESS` (or start a `--no-cache` run and interrupt it
   partway, or run two suites at once so markers are half-written).
2. `node scripts/generate-corpus.js`
3. Observe `koru-by-example.md` header drops to `> N hand-picked tests` for a
   small N and thousands of lines are deleted — a corrupt corpus, exit 0.

**Fix direction (not yet done).** The generator must read a **stable** source of
truth for pass/fail — the committed `test-results/latest.json` final verdicts,
not live `SUCCESS` markers — and/or refuse to overwrite when the result is
obviously degenerate (e.g. corpus shrank by >50% vs the committed version).
`prose_check.sh` should not regenerate against transient markers at all.
