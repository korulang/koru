---
name: regression
description: Koru regression test harness workflow. Use when checking test status, investigating failures, or coordinating test runs with the user.
---

# Regression Test Harness

The regression suite is the hub for all Koru compiler progress. ~600 tests, 40+ minutes for a full run.

## Our Workflow

**The user runs the full suite** (it takes too long for me to run):
```bash
./run_regression.sh              # Full run
./run_regression.sh --parallel 8 # Parallel (faster)
```

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
- `SUCCESS` / `FAILURE` - Result of last run
- `TODO` - Not yet implemented
- `SKIP` - Intentionally skipped
- `BROKEN` - Known broken, needs fix
- `BENCHMARK` - Performance test, not run normally
- `PRIORITY` - Urgent, needs attention

## Snapshots

After each full run, a snapshot is saved to `test-results/` with:
- Timestamp and git commit
- Complete test status
- Used for regression detection via `--diff` and `--history`

## Important Notes

- **Don't run the full suite** - it takes 40+ minutes. Use targeted commands.
- **User runs full suite, I check regressions** - that's our division of labor.
- **Tests that MUST_ERROR are negative tests** - they're supposed to fail compilation.
- **Check `--regressions` first** when the user reports failures.
