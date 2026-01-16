# Regression Suite Rewrite Specification

## Executive Summary

The `run_regression.sh` script is the **heart of the Koru project**. It validates that the compiler works correctly, tracks regressions over time, and generates data for the project website. A broken regression suite means we're flying blind during development.

**Current state**: ~1600 lines of bash, works correctly in serial mode, has broken parallel mode.
**Goal**: Rewrite for correctness first, parallelization second.

---

## The Correctness Contract

### What This Script MUST Do

1. **Run every test according to its type** - Each test type has specific execution rules
2. **Write SUCCESS/FAILURE markers to disk** - These markers are the source of truth for:
   - `scripts/generate-status.js` → status.json → korulang.org
   - `scripts/save-snapshot.js` → test-results/*.json → `./run_regression.sh --regressions`
   - `scripts/show-regressions.js` → regression detection
3. **Preserve test artifacts** - Keep generated files for debugging
4. **Memory leak detection** - Fail tests if leaks detected (unless `--ignore-leaks`)
5. **Test configuration validation** - Detect inconsistent test setups

### What Happens If This Fails

- **Regression tracking breaks**: We can't detect when commits break tests
- **Website breaks**: korulang.org shows stale or incorrect data
- **Development blind spot**: We can't tell if we're making progress or breaking things
- **False confidence**: Tests pass for the wrong reasons

---

## Test Types and Execution Rules

### Test Markers (presence determines test type)

| Marker | Meaning | Execution Rules |
|--------|---------|-----------------|
| `input.kz` | Has test code | Required for most tests |
| `TODO` | Feature not implemented | Skip immediately, count as TODO |
| `SKIP` | Test skipped for reason | Skip immediately, count as skipped |
| `BROKEN` | Test itself is broken | Fail immediately, write "broken-test" to FAILURE, count as broken |
| `BENCHMARK` | Performance test | Skip, display description |
| `PARSER_TEST` | AST validation only | Compile to AST JSON, compare to expected.json, stop |
| `MUST_RUN` | Must execute output binary | After backend compilation, run and validate output |
| `MUST_FAIL` | Negative test | Pass if compilation fails, fail if succeeds |
| `EXPECT` | Specific error expected | Pass if error matches, fail otherwise |
| `COMPILER_FLAGS` | Extra flags for compiler | Pass to koruc invocation |
| `PRIORITY` | Needs attention | Track in output, clean up on pass |
| `expected.txt` | Expected stdout | Compare against actual.txt (if MUST_RUN) |

### Execution Precedence (CRITICAL)

When a test directory has multiple markers, this order matters:

1. **TODO** - Highest priority: test is aspirational, don't run
2. **Category-level SKIP** - Parent directory has SKIP file
3. **Individual SKIP** - This test is skipped
4. **BROKEN** - Test is invalid, fail immediately
5. **PARSER_TEST** - Only validate AST, don't compile backend
6. **MUST_FAIL/EXPECT** - Negative test logic
7. **Regular test** - Full compilation pipeline

### The Two-Pass Compilation Pipeline

Every non-PARSER_TEST test goes through:

```
input.kz → [koruc] → backend.zig → [zig build] → backend executable
backend executable → [run] → output binary (if MUST_RUN)
output binary → [run] → actual.txt (validate against expected.txt)
```

**At each stage, check for memory leaks in stderr**: "memory address.*leaked"

---

## Critical Test Types (Examples)

### PARSER_TEST (12 tests)
- Only validate AST JSON
- Skip backend compilation entirely
- Example: `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_001_event_multiline_shape/`

### BROKEN (7 tests)
- Test itself is broken/incorrect
- Fail immediately without running
- Write "broken-test" to FAILURE marker
- Example: `tests/regression/200_COMPILER_FEATURES/210_PARSER/210_021_source_phantom_syntax/`

### MUST_FAIL (31 tests)
- Negative test - expects compilation to fail
- Pass if compilation fails, fail if succeeds
- Example: `tests/regression/200_COMPILER_FEATURES/220_FLOW_CHECKER/220_001_unused_binding_error/`

### MUST_RUN
- Must execute the generated binary
- Validate output against expected.txt
- Example: Most functional tests

---

## File Markers: Source of Truth

### What Gets Written

For each test, the script writes:

- **SUCCESS** → `test_dir/SUCCESS` (contains "PASS")
- **FAILURE** → `test_dir/FAILURE` (contains reason like "frontend", "backend", "output")
- **Cleanup**: Remove both markers before running test

### What Gets Read (Snapshot Generation)

The `scripts/save-snapshot.js` script scans test directories and:

1. Looks for SUCCESS/FAILURE markers
2. Reads TODO/SKIP/BROKEN marker files
3. Generates timestamped JSON snapshot to `test-results/*.json`
4. Updates `test-results/latest.json` symlink

### What Depends on This

1. **`./run_regression.sh --regressions`**
   - Reads snapshots from `test-results/*.json`
   - Compares current markers against history
   - Reports new regressions (broke in last 3 snapshots)

2. **`node scripts/generate-status.js`**
   - Scans current markers from disk
   - Generates `status.json`
   - Used by korulang.org website

3. **`node scripts/generate-lessons.js`** (in ~/src/korulang_org)
   - Reads status.json
   - Prepares data for website

**If markers are wrong, everything breaks.**

---

## Memory Leak Detection

### How It Works

1. Each compilation stage writes stderr to a log file
2. Script searches for pattern: "memory address.*leaked"
3. If found, track which stage failed (frontend, backend-compile, backend-exec)
4. If `--ignore-leaks` is NOT set: fail the test with reason "leak-<stage>"
5. If `--ignore-leaks` is set: count leaks but don't fail

### Example

```bash
# Compile .kz to backend.zig
./zig-out/bin/koruc "$test_dir/input.kz" -o "$test_dir/backend.zig" 2>"$test_dir/compile_kz.err"

# Check for leaks
if grep -q "memory address.*leaked" "$test_dir/compile_kz.err"; then
    HAS_MEMORY_LEAK=true
    LEAK_PHASE="frontend"
fi
```

### Critical Requirement

Memory leak checking must happen **at every stage** and **before** determining pass/fail status.

---

## Test Configuration Validation

### Critical Check

If a test has `expected.txt` but no `MUST_RUN` marker, the test is **dishonest**:

- It claims to validate output but never runs
- Silent false positive

**Action**: Fail test with "config-error" reason.

```bash
if [ -f "$test_dir/expected.txt" ] && [ ! -f "$test_dir/MUST_RUN" ] && [ ! -f "$test_dir/EXPECT" ]; then
    echo -e "${RED}❌ Test has expected.txt but no MUST_RUN marker${NC}"
    echo "config-error" > "$test_dir/FAILURE"
    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(config-error)"
    continue
fi
```

---

## Category Handling

### Category Structure

Tests are organized in nested directories:

```
tests/regression/
  ├── 000_CORE_LANGUAGE/
  │   ├── 010_BASIC_SYNTAX/
  │   │   ├── 001_hello_world/
  │   │   └── 002_comments/
  │   └── 020_TYPES/
  └── 100_IMPORTS/
```

### Category-Level SKIP

A category directory can have a `SKIP` file:

```
tests/regression/200_COMPILER_FEATURES/SKIP
```

**Effect**: All tests in this category are skipped with reason "Category skipped"

**Precedence**: Between individual SKIP and TODO markers.

---

## Build System

### Backend Compilation

Each test generates a backend Zig program. The script must:

1. Generate `backend.zig` (from koruc)
2. Create `build_backend.zig` with all module dependencies
3. Run `zig build --build-file build_backend.zig --global-cache-dir <cache-dir>`
4. Move binary: `zig-out/bin/backend` → `backend`

### Module Dependencies

The `build_backend.zig` must include ALL these modules:

```zig
errors.zig, ast.zig, lexer.zig, annotation_parser.zig, type_registry.zig,
expression_parser.zig, union_collector.zig, parser.zig, phantom_parser.zig,
type_inference.zig, branch_checker.zig, shape_checker.zig, flow_checker.zig,
phantom_semantic_checker.zig, ast_functional.zig, compiler_config.zig,
emitter_helpers.zig, tap_pattern_matcher.zig, tap_registry.zig,
tap_transformer.zig, purity_helpers.zig, visitor_emitter.zig,
fusion_detector.zig, fusion_optimizer.zig, emit_build_zig.zig
```

**Each module must properly import its dependencies.**

### Shared Cache

Use `--global-cache-dir` to share compiled modules across tests:

```bash
ZIG_GLOBAL_CACHE="${TMPDIR:-/tmp}/koru-regression-cache"
zig build --global-cache-dir "$ZIG_GLOBAL_CACHE"
```

This dramatically speeds up tests.

---

## Snapshot Generation

### When to Save

Only save snapshot after **full run** (no filters, not smoke mode):

```bash
if [ ${#TEST_FILTERS[@]} -eq 0 ] && [ "$SMOKE_MODE" = false ]; then
    # Save snapshot
    node scripts/save-snapshot.js \
        --passed="$PASSED_TESTS" \
        --total="$TOTAL_TESTS" \
        --flags="$CMD_FLAGS" \
        --commit="$GIT_COMMIT"
fi
```

### What Gets Saved

The snapshot JSON contains:

```json
{
  "timestamp": "2025-01-16T...",
  "gitCommit": "abc123",
  "commandFlags": "--ignore-leaks",
  "summary": {
    "total": 468,
    "passed": 420,
    "failed": 10,
    "todo": 20,
    "skipped": 15,
    "broken": 3,
    "passRate": "89.7"
  },
  "categories": [
    {
      "name": "CORE LANGUAGE",
      "slug": "000_CORE_LANGUAGE",
      "tests": [
        {
          "name": "hello world",
          "directory": "001_hello_world",
          "status": "success",
          "mustRun": true,
          "failureReason": ""
        }
      ]
    }
  ]
}
```

**Critical**: Status is determined by SUCCESS/FAILURE markers on disk, not by exit codes.

---

## Command-Line Interface

### Basic Usage

```bash
./run_regression.sh                    # Run all tests
./run_regression.sh 123                # Run test 123
./run_regression.sh 1                  # Run tests 100-199, 1000-1999
./run_regression.sh smoke              # Run curated smoke test suite
```

### Options

| Option | Purpose |
|--------|---------|
| `--ignore-leaks` | Don't fail tests with memory leaks |
| `--no-rebuild` | Skip compiler rebuild (rapid iteration) |
| `--run-units` | Run unit tests before regression tests |
| `--verbose` | Show full stderr on failures |
| `--priority` | List tests marked as PRIORITY |
| `--clean` | Clean all Zig caches |
| `--parallel N` | Run N tests concurrently (BROKEN - DON'T USE) |

### Special Commands

```bash
./run_regression.sh --status       # Show current test status
./run_regression.sh --list         # List all tests
./run_regression.sh --regressions  # Show NEW regressions (CRITICAL)
./run_regression.sh --history 123  # Show test history
./run_regression.sh --diff         # Compare snapshots
```

---

## The Parallelization Problem

### Current State

The current parallel mode (`--parallel N`) uses `run_single_test.sh` which is **incomplete**:

**Missing features:**
- ❌ PARSER_TEST handling (runs full compilation instead)
- ❌ BROKEN marker handling (treats as regular failure)
- ❌ Memory leak checking (no checks at all)
- ❌ Full build.zig generation (uses incomplete build files)
- ❌ Test configuration validation
- ❌ PRIORITY file cleanup
- ❌ Snapshot generation

**Result**: Parallel mode gives DIFFERENT results than serial mode.

### Example of the Bug

Test `210_001_event_multiline_shape` (PARSER_TEST):

- **Serial**: Validates AST JSON → PASS (AST validated)
- **Parallel**: Runs full compilation → PASS (for wrong reason)

Test `210_021_source_phantom_syntax` (BROKEN):

- **Serial**: FAIL (broken-test) - recognized as broken test
- **Parallel**: FAIL (backend) - treats as regular failing test

### Why This Matters

- **Regression tracking breaks**: Different results mean snapshots don't match
- **Website shows wrong data**: Parallel runs would corrupt status.json
- **Flying blind**: `--regressions` would detect false regressions

---

## Rewrite Strategy: Correctness First

### Phase 1: Make Serial Mode Rock Solid

1. **Audit the serial execution path** (lines 590-1572 in current script)
2. **Extract test execution logic** into a reusable function
3. **Validate every edge case**:
   - PARSER_TEST tests work correctly
   - BROKEN tests fail immediately
   - MUST_FAIL tests pass on error
   - Memory leaks detected at all stages
   - Configuration validation catches issues
4. **Verify snapshot generation** works correctly

**Success criteria:**
- All test types pass for the right reasons
- SUCCESS/FAILURE markers are correct
- `./run_regression.sh --regressions` works
- Website gets correct data

### Phase 2: Add Parallelization

Once correctness is guaranteed:

1. **Extract test-to-run** into a list
2. **Use GNU parallel** (or xargs -P) to run tests in parallel
3. **Each test run MUST**:
   - Use the same execution logic as Phase 1
   - Write SUCCESS/FAILURE markers correctly
   - Handle all test types properly
   - Check memory leaks
4. **After all tests complete**:
   - Scan test directories for markers
   - Generate counts (like generate-status.js)
   - Call save-snapshot if full run

**Critical constraint**: Parallel execution must produce **identical results** to serial.

### Phase 3: Validation

1. **Run smoke test suite** in serial mode → save results
2. **Run smoke test suite** in parallel mode → compare results
3. **Must be byte-for-byte identical**:
   - Same number of passes/failures
   - Same FAILURE reasons
   - Same marker files on disk

**If any difference found, fix parallel mode before proceeding.**

---

## Technical Constraints

### Must Use

- **Bash**: The script is bash, must stay bash
- **Zig**: Compiler is built with Zig
- **Node.js**: Snapshot/status scripts require Node.js v18+

### Must NOT Do

- ❌ Change SUCCESS/FAILURE marker format
- ❌ Change snapshot JSON format
- ❌ Break `--regressions` functionality
- ❌ Change test directory structure
- ❌ Change marker file names

### Must Preserve

- ✅ All command-line arguments
- ✅ All special commands (--status, --regressions, etc.)
- ✅ Snapshot format (scripts/generate-status.js reads it)
- ✅ Status format (korulang.org reads it)
- ✅ Memory leak detection behavior
- ✅ Test type execution rules

---

## Success Metrics

### Correctness

1. **All 468+ tests run** with correct behavior:
   - PARSER_TEST: AST validation only
   - BROKEN: immediate failure
   - MUST_FAIL: pass on compilation error
   - Regular: full compilation pipeline

2. **Markers are correct**:
   - SUCCESS/FAILURE files match test outcome
   - FAILURE reasons are accurate
   - No leftover markers from previous runs

3. **Regression tracking works**:
   - `./run_regression.sh --regressions` shows current regressions
   - Snapshots saved after full runs
   - Can detect when tests broke

4. **Website data is correct**:
   - `node scripts/generate-status.js` runs without error
   - status.json is valid
   - korulang.org shows current state

### Performance

After correctness is guaranteed:

1. **Parallel mode must be faster** than serial (2-4x speedup)
2. **Must use shared cache** (no recompiling modules)
3. **Must be deterministic** (same results every time)

### Maintainability

1. **Clear separation of concerns**:
   - Test discovery logic
   - Test execution logic
   - Result aggregation logic
   - Snapshot generation

2. **Well-documented edge cases**:
   - PARSER_TEST special handling
   - BROKEN marker precedence
   - Memory leak detection
   - Configuration validation

3. **Easy to test**:
   - Can run single tests
   - Can run smoke tests
   - Can validate against serial mode

---

## Known Edge Cases

### Test with Both SUCCESS and FAILURE

If both markers exist, status is "unknown" - weird state, should be investigated.

### Stale Artifacts

If a test crashes, it leaves behind:
- `backend.zig`, `backend`, `output`
- `zig-out/`, `.zig-cache/`

**Action**: Clean all artifacts before running each test.

### Category Directory Has SKIP

Tests in category should skip, but category may also contain README.md or SPEC.md.

**Action**: SKIP applies to test directories only.

### Test Without input.kz But Has TODO

This is valid: TODO marker means feature not implemented, no input.kz needed.

**Action**: Accept as valid TODO test.

---

## Files Involved

### Core Files

- `run_regression.sh` (~1600 lines) - Main script to rewrite
- `run_single_test.sh` (140 lines) - Incomplete, DO NOT USE as reference

### Dependency Files

- `scripts/save-snapshot.js` - Generates snapshots (must preserve format)
- `scripts/generate-status.js` - Scans markers, generates status.json
- `scripts/show-regressions.js` - Compares current state vs snapshots
- `scripts/test-history.js` - Shows test history
- `scripts/diff-snapshots.js` - Compares snapshots

### Output Files

- `test-results/*.json` - Timestamped snapshots
- `test-results/latest.json` - Symlink to latest snapshot
- `status.json` - Current test state (read by korulang.org)
- `tests/*/SUCCESS` - Test passed marker
- `tests/*/FAILURE` - Test failed marker

---

## Hidden Couplings & Safe Extraction Boundary

### Hidden Couplings to Preserve (or Make Explicit)

1. **Test discovery must match marker scanners**
   - `run_regression.sh` and `scripts/generate-status.js` only treat directories matching `^[0-9]+[a-z]?_` as tests.
   - A directory counts as a test only if it contains `input.kz` **or** a marker (`TODO`, `SKIP`, `BROKEN`, `BENCHMARK`).
   - `scripts/save-snapshot.js` currently scans all subdirs and only checks marker presence (not the name pattern). This is a potential mismatch to resolve; the rewrite must make all three agree.

2. **Category-level SKIP scope is ambiguous today**
   - `run_regression.sh` only checks the immediate parent directory for `SKIP`.
   - `generate-status.js` / `save-snapshot.js` propagate `SKIP` down the entire subtree.
   - The rewrite must pick one behavior and align all scripts.

3. **Marker precedence is a shared contract**
   - `TODO` > category `SKIP` > test `SKIP` > `BROKEN` > `SUCCESS`/`FAILURE`.
   - `scripts/generate-status.js` encodes this order; any change must be mirrored.

4. **Failure reason is the first line of `FAILURE`**
   - `generate-status.js`, `save-snapshot.js`, `show-regressions.js`, and `diff-snapshots.js` all display the first line only.
   - Keep reason strings stable (e.g., `frontend`, `backend`, `output`, `config-error`, `leak-frontend`).

5. **Snapshots and status depend on `test.directory` being unique**
   - `show-regressions.js` and `test-history.js` match tests by `directory` name only.
   - Do not change directory naming or the `directory` field semantics.

6. **`status.json` is a build artifact with a fixed location**
   - `generate-status.js` always writes `status.json` at repo root; other scripts read it from there.
   - Do not relocate or rename this output.

7. **Error expectation mechanisms are non-obvious**
   - `EXPECT` with `FRONTEND_COMPILE_ERROR` or `BACKEND_COMPILE_ERROR` short-circuits failure.
   - `expected_error.txt` is a separate backend error matcher (not documented elsewhere).

8. **Artifact cleanup and output paths are part of correctness**
   - Each test run removes `backend.zig`, `backend`, `output`, `actual.txt`, `compile_*.err`, `zig-out/`, `.zig-cache/`, plus `SUCCESS/FAILURE`.
   - Backend build is expected to emit `zig-out/bin/backend`, which is moved to `backend` in the test dir.
   - `post.sh` executes in the test dir and writes `post.log`.

9. **Memory leak detection is stage-specific**
   - Leak checks run on `compile_kz.err`, `compile_backend.err`, `backend.err`, looking for `memory address.*leaked`.
   - The current PARSER_TEST path does not check leaks; decide whether to keep or fix this and align expectations.

10. **Snapshot generation is only for full runs**
    - `save-snapshot.js` is invoked only when no filters are used and not in smoke mode.
    - Parallel mode must preserve this rule.

11. **`realpath --relative-to` is a hidden platform dependency**
    - The backend build uses `realpath --relative-to="$test_dir" "$PWD"` to build module paths.
    - If this is rewritten, ensure portability or preserve equivalent semantics.

### Smallest Safe Extraction Boundary (for Phase 1)

Extract a single "run one test" function that:

- Accepts `test_dir` and shared flags (`CHECK_LEAKS`, `VERBOSE`, `ZIG_GLOBAL_CACHE`).
- Implements **all** marker precedence, config validation, cleanup, compilation, execution, and leak checks.
- Writes only `SUCCESS`/`FAILURE` (and cleans `PRIORITY` on pass).
- Returns a structured result `{status, failureReason, leaked, priorityHit}` for aggregation.

This isolates correctness in one place and enables parallel mode to call the exact same logic.

---

## Parallel Divergence (Current run_single_test.sh)

The helper used by `--parallel` is materially incomplete. Divergences include:

- **No PARSER_TEST path** (runs full compilation instead of AST-only validation).
- **No BROKEN handling** (fails as backend/exec rather than `broken-test`).
- **No memory leak checks** (missing all leak detection).
- **No expected_error.txt support** (backend error matching).
- **No EXPECT BACKEND_COMPILE_ERROR handling** (only frontend special-cases).
- **No configuration validation** (`expected.txt` without MUST_RUN).
- **No category-level SKIP** (only per-test SKIP).
- **No PRIORITY cleanup** on pass.
- **Build file mismatch** (uses `build.zig`/`build_backend.zig`, but serial creates a full `temp_build.zig` with module wiring).
- **Artifact cleanup incomplete** (misses `actual.txt`, `output_emitted.zig`, `post.log`, `.zig-cache`).
- **Post-validation missing** (`post.sh` is never run).
- **Marker precedence differs** (BENCHMARK/TODO/SKIP handled, but BROKEN and MUST_FAIL rules diverge).
- **Wrong compile flag** (`--output` vs `-o`), which may silently differ from serial.

Until this is replaced by the shared “run one test” function, `--parallel` results cannot be trusted.

---

## Parity Guardrail Checklist

Before enabling parallel mode as “real”:

- Run a fixed subset (smoke suite) serial vs parallel.
- Diff SUCCESS/FAILURE markers and failure reasons (first line).
- Ensure leak detection decisions match.
- Ensure PARSER_TEST, BROKEN, EXPECT/MUST_FAIL cases match exactly.
- Verify `scripts/generate-status.js` and `--regressions` results are unchanged.

Example command:

```bash
./scripts/regression_parity.sh
PARITY_JOBS=8 ./scripts/regression_parity.sh smoke
```

---

## Next Steps for CODEX

1. **Read the current run_regression.sh** thoroughly
2. **Identify all test types and execution paths**
3. **Extract test execution logic** into a pure function
4. **Implement serial mode** with correct marker writing
5. **Test with smoke suite** → verify markers are correct
6. **Implement parallel mode** using extracted function
7. **Compare serial vs parallel** → must be identical
8. **Add snapshot generation** to parallel mode
9. **Validate --regressions works**
10. **Test with full suite** → ensure no regressions

**Remember: Correctness is non-negotiable. Speed is a bonus.**

---

## Appendix: Smoke Test Suite

Run this first to validate correctness:

```bash
./run_regression.sh smoke
```

Tests: 12 curated tests covering:
- 102_* - Basic syntax
- 205_* - Control flow
- 302_* - Subflows
- 401_* - Imports
- 501_* - Branch coverage
- 603_* - Taps
- 609_* - Observers
- 701_* - Types
- 801_* - Integration
- 831_* - Advanced
- 916_* - Multitaps

Expected result: All tests pass for correct reasons.
