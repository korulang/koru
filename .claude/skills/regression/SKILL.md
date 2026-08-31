---
name: regression
description: Koru regression test harness workflow. Use when checking test status, investigating failures, or coordinating test runs with the user.
---

# Regression Test Harness

The regression suite is the hub for all Koru compiler progress. 1511 tests, 1442
in scope; ~11 minutes for a full `--parallel 8` board (measured 2026-08-01).

## Our Workflow

**I run the suite myself** — full agency, no hand-off. What differs is *which*
suite:

```bash
./run_regression.sh <name> <name> ...   # while iterating: affected tests + controls
./run_regression.sh --parallel 8        # the full board — for PUBLISHING, not iterating
```

Filtered runs write no snapshot, so they cannot clobber `latest.json`. Running
the full board repeatedly while iterating is the mistake to avoid — it costs
~11 minutes a turn and buys nothing a filtered run doesn't.

**A filter that matches nothing is dropped in silence.** `./run_regression.sh
<real_name> <typo>` runs one test and prints `ALL TESTS PASSED`, exit 0. Zero
matches refuses; a *partial* match does not. **Always check the `Running N
tests` line against the number you asked for** — a control set only verifies the
names that happened to be spelled right.

**Never `zig build`, or edit `src/` or `koru_std/`, while a suite is live.** Each
test compiles its emitted Zig against the live `src/` tree, so a half-written
file there becomes reds that quote your own edit — 33 in one measured case, all
reported as `backend`, none real.

**I check what broke and investigate**:
```bash
./run_regression.sh --regressions   # What's failing + when it last passed
./run_regression.sh --status        # Current state from disk markers
./run_regression.sh --diff          # Compare current vs last snapshot
```

**We debug specific tests together**:
```bash
./run_regression.sh 501             # Run single test (by number)
./run_regression.sh 330             # Run range 330-339
./run_regression.sh --history 501   # When did this test break?
```

**After fixing, verify**:
```bash
./run_regression.sh 501 502 503     # Re-run affected tests
./run_regression.sh smoke           # Quick sanity check
```

## Key Commands

| Command | Purpose |
|---------|---------|
| `--status` | Show current test state from disk markers |
| `--regressions` | List failing tests + when they last passed |
| `--diff` | Compare current run vs last snapshot |
| `--history <id>` | Show test history across all snapshots |
| `--list` | List all tests with descriptions |
| `--priority` | Show tests marked as PRIORITY |
| `--last-run` | Show results from last full run |

## Test Markers

Tests are marked with files in their directory:
- `MUST_RUN` - the built binary is executed and graded
- `MUST_ERROR` - a negative test: compilation is supposed to fail, and the
  test must NAME the diagnostic it pins
- `SUCCESS` / `FAILURE` - Result of last run (`FAILURE` holds the reason)
- `TODO` - Not yet implemented
- `SKIP` - Intentionally skipped
- `BROKEN` - Known broken, needs fix
- `BENCHMARK` - Performance test, not run normally
- `PRIORITY` - Urgent, needs attention
- `EXPECT_TIMEOUT` - the binary is SUPPOSED to hang; the watchdog catching it is
  the pass, and finishing early is the failure
- `EXPECT_TRAP` - the binary is SUPPOSED to die (see below)
- `ARGS` / `STDIN` - argv lines / stdin fed to the binary

New extensionless markers must be allowlisted in `tests/regression/.gitignore`
— a blanket `*` ignores every file without an extension, so an unlisted marker
is silently never committed.

## A MUST_RUN test is graded on its exit code, not only its output

Since 2026-08-01 (`7fe1434d`) the harness reads `RUN_EXIT` alongside
`actual.txt`. Before that, the `expected.txt` / `expected_patterns.txt` /
`EXPECT` branches graded output alone, so a binary that printed the right thing
and then segfaulted got a PASS — and a segfault writes nothing to `actual.txt`,
so the stored artifact didn't show it either.

**A death that is the behaviour under test is declared, never inferred.** Drop
an `EXPECT_TRAP` file in the test dir — empty for "any non-zero exit", or the
exit codes it pins, one per line. A Zig panic aborts at **134** (128 + SIGABRT).
Nothing is read out of the message text; inferring intent from output is what
opened the hole.

Four verdicts come from this gate:

| verdict | meaning |
|---|---|
| `crash-<code>` | abnormal exit nobody pinned — output is not graded at all |
| `trap-exit-<code>` | `EXPECT_TRAP` names codes and the binary died with a different one |
| `expect-trap-but-exited-clean` | the pinned trap stopped firing |
| `trap-without-message-pin` | `EXPECT_TRAP` with no output expectation — a trap must pin the message it dies with |

Live examples: `690_115`, `690_116`, `690_196`, `837_let_it_crash_uncaught`.

Every harness guard must have a row in `scripts/WALLS.md`; `scripts/wall_check.sh`
fails the run on an unregistered one, and its **mirror column** — the direction
a wall does *not* guard — is a live worklist, not a disclaimer.

**Git wall:** `scripts/git_wall.sh --committed` runs in the coherence watchers;
`hooks/pre-commit` runs `--staged`. The oracle is `.gitignore` via
`check-ignore --no-index`. Grandfather rows in `scripts/git_wall_allowlist.txt`
must shrink — never widen without a purge.

## Snapshots

After each full run, a snapshot is saved to `test-results/` with:
- Timestamp and git commit
- Complete test status
- Used for regression detection via `--diff` and `--history`

## Important Notes

- **The full board is for publishing.** While iterating, run affected tests plus
  controls, and check the `Running N tests` line against what you asked for.
- **Tests that MUST_ERROR are negative tests** - they're supposed to fail
  compilation, and must name the diagnostic they pin.
- **Check `--regressions` first** when the user reports failures.
- **`--keep-artifacts` is a CLI flag on `run_regression.sh`, not an env var.**
  `KEEP_ARTIFACTS=true ./run_regression.sh …` is silently ignored and the test
  binaries are cleaned on success anyway.
- **Capture an exit status on its own line.** `echo "$(basename "$d") -> $?"`
  reports the *basename's* status: the command substitution runs first and
  resets `$?`. This produced a confident, wrong "all four exit 0" reading of
  four binaries that all exit 134.
