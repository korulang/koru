#!/bin/bash
# Run a single regression test (used by run_regression.sh --parallel)
# Usage: ./run_single_test.sh <test_dir>
# Writes SUCCESS or FAILURE to test_dir, outputs single line summary

set -o pipefail

test_dir="$1"
if [ -z "$test_dir" ] || [ ! -d "$test_dir" ]; then
    echo "SKIP: Invalid directory"
    exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The compiler under test is FROZEN, never read live from zig-out: a rebuild
# during a run would otherwise swap it mid-flight. When the suite drives us it
# has already snapshotted and exported KORUC, and we reuse that exact binary —
# every worker in a run must test the same one. A standalone invocation takes
# its own snapshot and removes it on exit. `cp -p` preserves the mtime the cache
# salt is computed from.
if [ -z "${KORUC:-}" ]; then
    if [ ! -x "$SCRIPT_DIR/zig-out/bin/koruc" ]; then
        echo "SKIP: no compiler at $SCRIPT_DIR/zig-out/bin/koruc — build it first"
        exit 0
    fi
    # Named zig-out-run-*, NOT a hidden dot-dir, on purpose: koruc computes its
    # koru_home from its own exe path (module_resolver.zig), stepping up past
    # bin/ and ONE LEVEL MORE only when that parent's basename starts with
    # "zig-out" — the dev-checkout layout. <checkout>/zig-out-run-$$/bin/koruc
    # is the same shape as zig-out/bin, so the snapshot resolves src/ and
    # koru_std/ to the checkout; a $TMPDIR copy would look for /tmp/src/ast.zig
    # (measured), and a differently-named in-checkout dir resolves koru_home to
    # itself. Cleaned by the trap on exit.
    KORUC_SNAPSHOT_DIR="$SCRIPT_DIR/zig-out-run-$$"
    mkdir -p "$KORUC_SNAPSHOT_DIR/bin"
    trap 'rm -rf "$KORUC_SNAPSHOT_DIR"' EXIT
    KORUC="$KORUC_SNAPSHOT_DIR/bin/koruc"
    cp -p "$SCRIPT_DIR/zig-out/bin/koruc" "$KORUC" || {
        echo "SKIP: could not snapshot the compiler"
        exit 0
    }
    export KORUC
fi

# shellcheck source=./scripts/regression_lib.sh
source "$SCRIPT_DIR/scripts/regression_lib.sh"
# shellcheck source=./scripts/regression_cache.sh
source "$SCRIPT_DIR/scripts/regression_cache.sh"

# A standalone single-test run during a full suite run in the SAME checkout
# clobbers that test's artifacts/markers under the suite's feet (this bit us
# 2026-07-02, minutes after the suite-level lock landed). The suite's own
# workers are exempt (they run under REGRESSION_QUIET=true). Escape hatch:
# KORU_SUITE_LOCK_BYPASS=1 when you know the colliding test sets are disjoint.
if [ "${REGRESSION_QUIET:-false}" != "true" ] && [ -z "${KORU_SUITE_LOCK_BYPASS:-}" ] && [ -d "$SCRIPT_DIR/.regression-run.lock" ]; then
    SUITE_PID=$(cat "$SCRIPT_DIR/.regression-run.lock/pid" 2>/dev/null || echo "")
    if [ -n "$SUITE_PID" ] && kill -0 "$SUITE_PID" 2>/dev/null; then
        echo "❌ A full suite run (pid $SUITE_PID) is active in this checkout — a single-test"
        echo "   run would clobber its per-test artifacts. Wait, use another worktree, or"
        echo "   KORU_SUITE_LOCK_BYPASS=1 if you are certain the test sets are disjoint."
        exit 1
    fi
fi

# Backend-binary cache: default ON for standalone invocations too (when the
# suite drives us it exports MODE/DIR/SALT itself, including MODE=off under
# --no-backend-cache, and this block is skipped). Reuses a cached backend
# binary across tests sharing a handler set; the compiler-mtime salt makes a
# binary unusable after any compiler/stdlib edit. Disable a standalone run
# with BACKEND_CACHE_MODE=off ./run_single_test.sh <test>.
if [ -z "${BACKEND_CACHE_MODE:-}" ]; then
    BACKEND_CACHE_MODE=on
    BACKEND_CACHE_SALT=$(cache_compute_compiler_mtime "$SCRIPT_DIR")
    BACKEND_CACHE_DIR="$ZIG_GLOBAL_CACHE/koru-backend-cache"
    mkdir -p "$BACKEND_CACHE_DIR"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# run_one_test_watched + KORU_TEST_TIMEOUT come from regression_lib.sh (shared
# with run_regression.sh's serial path). It runs each test in its own process
# group and SIGKILLs the whole koruc→zig→backend tree on timeout.

# Ensure category logic starts clean when invoked per-test.
CURRENT_CATEGORY=""

TEST_NAME=$(basename "$test_dir")
CATEGORY_DIR="$(dirname "$test_dir")"

# Cache mode is opt-in via KORU_CACHE_MODE=on (set by run_regression.sh --cache).
# When on, check fingerprint before running; skip the actual test on cache hit.
CACHE_HIT=false
if [ "${KORU_CACHE_MODE:-off}" = "on" ]; then
    # Compute compiler mtime if the suite didn't already export it.
    if [ -z "${KORU_COMPILER_MTIME:-}" ]; then
        KORU_COMPILER_MTIME=$(cache_compute_compiler_mtime "$SCRIPT_DIR")
    fi
    # Don't try to cache skip/todo/broken/benchmark — those have their own
    # marker semantics and re-run cheaply. EXPECT_TIMEOUT is a watchdog self-test
    # that must ACTUALLY run every time (a cached pass would hide a watchdog
    # regression), and it's only a few seconds anyway.
    if [ ! -f "$test_dir/BENCHMARK" ] && [ ! -f "$test_dir/TODO" ] && \
       [ ! -f "$test_dir/SKIP" ] && [ ! -f "$test_dir/BROKEN" ] && \
       [ ! -f "$test_dir/EXPECT_TIMEOUT" ] && \
       [ ! -f "$CATEGORY_DIR/SKIP" ] && [ ! -f "$CATEGORY_DIR/BENCHMARK" ] && \
       [ ! -f "$CATEGORY_DIR/TODO" ]; then
        if cache_check "$test_dir" "$KORU_COMPILER_MTIME"; then
            CACHE_HIT=true
        fi
    fi
fi

if [ "$CACHE_HIT" = true ]; then
    # Determine what the cached outcome was from the markers on disk.
    cached_outcome="unknown"
    [ -f "$test_dir/SUCCESS" ] && [ ! -f "$test_dir/FAILURE" ] && cached_outcome="pass"
    [ -f "$test_dir/FAILURE" ] && cached_outcome="fail"

    if [ "${KORU_VERIFY_CACHE:-off}" = "on" ]; then
        # Force a fresh uncached run and compare outcomes.
        rm -f "$test_dir/SUCCESS" "$test_dir/FAILURE"
        cache_invalidate "$test_dir"
        run_one_test_watched "$test_dir" true
        uncached_outcome="unknown"
        [ -f "$test_dir/SUCCESS" ] && [ ! -f "$test_dir/FAILURE" ] && uncached_outcome="pass"
        [ -f "$test_dir/FAILURE" ] && uncached_outcome="fail"

        if [ "$cached_outcome" = "$uncached_outcome" ]; then
            cache_write "$test_dir" "$KORUC" "$KORU_COMPILER_MTIME"
            echo -e "${GREEN}✓ PARITY${NC}  ${DIM}$TEST_NAME${NC} ${DIM}(cached+uncached both $cached_outcome)${NC}"
            [ "$cached_outcome" = "pass" ] && exit 0 || exit 1
        else
            echo "cache_said=$cached_outcome uncached_said=$uncached_outcome" > "$test_dir/PARITY_VIOLATION"
            echo -e "${RED}🚨 PARITY VIOLATION${NC} $TEST_NAME ${DIM}(cache: $cached_outcome, uncached: $uncached_outcome)${NC}"
            exit 1
        fi
    fi

    if [ "$cached_outcome" = "pass" ]; then
        echo -e "${GREEN}💾 CACHED${NC} ${GREEN}✓${NC} ${DIM}$TEST_NAME${NC}"
        exit 0
    else
        reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null || echo "cached-fail")
        echo -e "${RED}💾 CACHED${NC} ${RED}✗${NC} ${DIM}$TEST_NAME${NC} ${DIM}($reason)${NC}"
        exit 1
    fi
fi

if [ "${REGRESSION_QUIET:-false}" = "true" ]; then
    run_one_test_watched "$test_dir" true
else
    run_one_test_watched "$test_dir" false
fi

# After the test ran, update the cache. Both pass and fail outcomes are
# cacheable — if inputs haven't changed, the outcome won't change either.
# cache_write internally requires SUCCESS or FAILURE to exist (so a crash
# mid-run doesn't poison the cache).
if [ "${KORU_CACHE_MODE:-off}" = "on" ]; then
    cache_write "$test_dir" "$KORUC" "$KORU_COMPILER_MTIME" \
        || cache_invalidate "$test_dir"
fi

if [ -f "$test_dir/BENCHMARK" ] || [ -f "$CATEGORY_DIR/BENCHMARK" ]; then
    echo -e "${CYAN}📊 BENCH${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$test_dir/TODO" ]; then
    echo -e "${YELLOW}📝 TODO ${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
# Category-level TODO: regression_run_one_test skips the test without writing a
# SUCCESS/FAILURE marker (mirrors regression_lib.sh's category-TODO path), so we
# must classify it here — otherwise it falls through to the "(unknown)" FAIL at
# the bottom. The serial runner and the summary tally treat it as TODO; match them.
if [ -f "$CATEGORY_DIR/TODO" ]; then
    echo -e "${YELLOW}📝 TODO ${NC}  ${DIM}$TEST_NAME${NC} ${DIM}(category)${NC}"
    exit 0
fi
if [ -f "$CATEGORY_DIR/SKIP" ]; then
    echo -e "${CYAN}⏭️ SKIP${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$test_dir/SKIP" ]; then
    echo -e "${CYAN}⏭️ SKIP${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi
if [ -f "$test_dir/BROKEN" ]; then
    reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null || echo "broken-test")
    echo -e "${RED}🔧 BROKEN${NC} $TEST_NAME ${DIM}($reason)${NC}"
    exit 1
fi
if [ -f "$test_dir/FAILURE" ]; then
    reason=$(head -1 "$test_dir/FAILURE" 2>/dev/null)
    if [ -n "$reason" ]; then
        echo -e "${RED}❌ FAIL ${NC}  $TEST_NAME ${DIM}($reason)${NC}"
    else
        echo -e "${RED}❌ FAIL ${NC}  $TEST_NAME"
    fi
    exit 1
fi
if [ -f "$test_dir/SUCCESS" ]; then
    echo -e "${GREEN}✅ PASS ${NC}  ${DIM}$TEST_NAME${NC}"
    exit 0
fi

echo -e "${RED}❌ FAIL ${NC}  $TEST_NAME ${DIM}(unknown)${NC}"
exit 1
