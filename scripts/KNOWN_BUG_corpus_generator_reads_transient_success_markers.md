# RESIDUE: the corpus generators derive pass/fail from transient run state

**The destructive half is walled.** `scripts/lib/corpus.js`
`assertMarkerSetSettled()` refuses to generate when the live `SUCCESS` marker
count is under half of `test-results/latest.json`'s `summary.passed`, and all
three generators call it before reading a single test. A mid-run invocation
throws with the reason and exits non-zero instead of publishing a truncated
corpus. `prose_check.sh` additionally regenerates into a temp root
(`KORU_GEN_OUT_ROOT`) so its check A cannot write over tracked files at all, and
refuses outright while a FOREIGN suite holds the lock.

**What is still true.** The generators still answer "which tests pass?" by
scanning for per-test `SUCCESS` marker files — `corpus.js` `walk()`
(`hasSuccess = entries.some(e => e.name === 'SUCCESS')`). Those markers are run
state, not a record: `./run_regression.sh` clears and rewrites them per-test as
it goes. The guard makes a partial read *loud* rather than *silent*; it does not
make the input stable.

Two consequences remain, both non-destructive:

- A generation attempted mid-run **fails** rather than succeeding. Correct, but
  that is a wall around the symptom, not a fix for the input.
- The threshold is a heuristic. A marker set partial by less than half passes
  it and would yield a corpus quietly missing a few tests. Nothing catches that.

**Fix direction (unchanged).** Read the verdicts from
`test-results/latest.json` directly rather than from live markers. Then the
input is a record, the guard becomes unnecessary, and the sub-threshold case
disappears with it.

**Why the wall exists at all.** On 2026-07-18 a `--no-cache` run briefly
overlapped a second regression run and the post-test regen collapsed the corpus
docs to "1 hand-picked test" — roughly 5000 lines deleted across
`docs/by-example/*`, `koru-by-example.md` and `skills/*/SKILL.md` — silently,
exit 0, looking like a real diff. Re-running after the suite settled produced
the correct "22 tests across 9 categories", which is what established that the
script was right and its input was not.
