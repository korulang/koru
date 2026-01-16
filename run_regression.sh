#!/bin/bash
# Koru Regression Test Suite
# This CANNOT lie - it actually compiles and runs everything

# NOTE: We do NOT use 'set -e' because we need to capture and handle
# all errors explicitly. set -e can cause the script to exit unexpectedly
# when a test fails, preventing proper error reporting.
#
# However, we DO use 'set -o pipefail' to ensure pipeline failures are caught.
# Without this, 'zig build | tail' would always succeed even if zig build fails.
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Shared regression helpers
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./scripts/regression_lib.sh
source "$SCRIPT_DIR/scripts/regression_lib.sh"

# Set up environment for module resolution
export KORU_STDLIB="$PWD/koru_std"
export KORU_PATH="$PWD"

# Initialize counters
TOTAL_TESTS=0
PASSED_TESTS=0
SKIPPED_TESTS=0
TODO_TESTS=0
BROKEN_TESTS=0
BENCHMARK_TESTS=0
LEAKED_TESTS=0
PRIORITY_TESTS=0
FAILED_TESTS=""
PRIORITY_LIST=""

# Memory leak detection flag (default: ON)
# Use --ignore-leaks to disable strict leak checking
CHECK_LEAKS=true

# Unit test execution flag (default: OFF)
# Use --run-units to run unit tests
RUN_UNIT_TESTS=false

# Compiler rebuild flag (default: ON)
# Use --no-rebuild to skip rebuilding the compiler (for rapid iteration)
REBUILD_COMPILER=true

# Verbose error output flag (default: OFF)
# Use --verbose to show full stderr output on failures (not truncated)
VERBOSE=false

# Priority list flag (default: OFF)
# Use --priority to list all priority items
SHOW_PRIORITY=false

# Shared Zig cache for faster builds (reuse compiled modules across tests)
# This dramatically speeds up the test suite by not rebuilding koru modules for each test
ZIG_GLOBAL_CACHE="${TMPDIR:-/tmp}/koru-regression-cache"

# Clean cache flag (default: OFF)
# Use --clean to remove all Zig caches before running tests
CLEAN_CACHE=false

# Parallel execution (default: 1 = sequential)
# Use --parallel N to run N tests concurrently
PARALLEL_JOBS=1

echo "════════════════════════════════════════"
echo "    KORU REGRESSION TEST SUITE"
echo "════════════════════════════════════════"
echo ""

# Check for help first
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "KORU REGRESSION TEST SUITE - Comprehensive Testing & Debugging"
    echo ""
    echo -e "${CYAN}RUNNING TESTS:${NC}"
    echo "  ./run_regression.sh                    Run all tests (memory leak checks enabled)"
    echo "  ./run_regression.sh 1                  Run tests 100-199"
    echo "  ./run_regression.sh 83                 Run tests 830-839"
    echo "  ./run_regression.sh 501                Run exact test 501"
    echo "  ./run_regression.sh 501 502 503        Run multiple specific tests"
    echo "  ./run_regression.sh smoke              Run curated smoke test suite"
    echo ""
    echo -e "${CYAN}TEST STATUS & INSPECTION:${NC}"
    echo "  ./run_regression.sh --status           Show current test status from disk markers"
    echo "  ./run_regression.sh --list             List all tests with their status"
    echo "  ./run_regression.sh --last-run         Show results from last full run"
    echo ""
    echo -e "${CYAN}REGRESSION DETECTION & DEBUGGING:${NC}"
    echo "  ./run_regression.sh --diff             Compare current vs last snapshot"
    echo "  ./run_regression.sh --diff OLD NEW     Compare two specific snapshots"
    echo "  ./run_regression.sh --regressions      Show failing tests and when they last passed"
    echo "  ./run_regression.sh --history 123      Show test history across all snapshots"
    echo "  ./run_regression.sh --history 9100/998 Show history with category/number"
    echo ""
    echo -e "${CYAN}OPTIONS:${NC}"
    echo "  --ignore-leaks                         Run without memory leak checks"
    echo "  --no-rebuild                           Skip compiler rebuild (for rapid iteration)"
    echo "  --run-units                            Run unit tests before regression tests"
    echo "  --verbose                              Show full stderr output on failures (not truncated)"
    echo "  --priority                             List all tests marked as PRIORITY"
    echo "  --clean                                Clean all Zig caches before running (fresh build)"
    echo "  --parallel N                           Run N tests concurrently (default: 1 = sequential)"
    echo ""
    echo -e "${CYAN}SNAPSHOT SYSTEM:${NC}"
    echo "  After each full run, a snapshot is saved to test-results/ with:"
    echo "    - Timestamp and git commit hash"
    echo "    - Complete test status (pass/fail/skip/todo/broken)"
    echo "    - Automatically tracked for regression detection"
    echo ""
    echo -e "${CYAN}HISTORY TRACKER:${NC}"
    echo "  The --history command shows when a test was last passing and identifies"
    echo "  the exact commit where it broke. Includes git bisect hints for debugging."
    echo ""
    echo -e "${CYAN}EXAMPLES:${NC}"
    echo "  ${GREEN}# Run specific test and check if it regressed${NC}"
    echo "  ./run_regression.sh 501"
    echo "  ./run_regression.sh --history 501"
    echo ""
    echo "  ${GREEN}# Run full suite, then check for regressions${NC}"
    echo "  ./run_regression.sh"
    echo "  ./run_regression.sh --diff"
    echo ""
    echo "  ${GREEN}# Debug a failing test across history${NC}"
    echo "  ./run_regression.sh --history 998"
    echo "  git bisect start"
    echo "  git bisect bad <commit-where-it-broke>"
    echo "  git bisect good <commit-where-it-passed>"
    echo ""
    exit 0
fi

# Check for special commands first (--status, --list, --priority)
if [ "$1" = "--status" ]; then
    # Generate and display status using Node script
    # This reads actual test markers (SUCCESS/FAILURE/TODO/SKIP/BROKEN) from test dirs
    if command -v node >/dev/null 2>&1; then
        node scripts/generate-status.js --format=cli
    else
        echo -e "${RED}❌ Node.js not found. Install Node.js v18+ to use --status${NC}"
        echo ""
        echo "Alternative: Run tests to see current state:"
        echo "  ./run_regression.sh"
        exit 1
    fi
    exit 0
fi

if [ "$1" = "--priority" ]; then
    # List all tests marked with PRIORITY
    echo -e "${RED}🔥 PRIORITY ITEMS${NC}"
    echo "════════════════════════════════════════"
    echo ""
    FOUND_ANY=false
    while IFS= read -r -d '' priority_file; do
        FOUND_ANY=true
        test_dir=$(dirname "$priority_file")
        test_name=$(basename "$test_dir")
        priority_content=$(cat "$priority_file" 2>/dev/null)
        echo -e "${YELLOW}$test_name${NC}"
        if [ -n "$priority_content" ]; then
            echo "$priority_content" | sed 's/^/  /'
        fi
        echo ""
    done < <(find tests/regression -name "PRIORITY" -type f -print0 | sort -z)

    if [ "$FOUND_ANY" = false ]; then
        echo "No priority items found."
        echo ""
        echo "To mark a test as priority:"
        echo "  echo 'Description of issue' > tests/regression/.../PRIORITY"
    fi
    exit 0
fi

if [ "$1" = "--last-run" ]; then
    # Show results from last full run (snapshot)
    if command -v node >/dev/null 2>&1; then
        if [ -f "test-results/latest.json" ]; then
            # Format and display the snapshot
            node -e "
const fs = require('fs');
const snap = JSON.parse(fs.readFileSync('test-results/latest.json', 'utf-8'));
console.log('═══════════════════════════════════════════════════════════');
console.log('LAST FULL RUN RESULTS');
console.log('═══════════════════════════════════════════════════════════');
console.log('');
console.log('Timestamp:', new Date(snap.timestamp).toLocaleString());
console.log('Git commit:', snap.gitCommit);
console.log('Flags:', snap.commandFlags || '(none)');
console.log('');
console.log(\`RESULTS: \${snap.summary.passed}/\${snap.summary.total} passed (\${snap.summary.passRate}%)\`);
console.log(\`  ✅ \${snap.summary.passed} passing\`);
if (snap.summary.todo > 0) console.log(\`  📝 \${snap.summary.todo} TODO\`);
if (snap.summary.skipped > 0) console.log(\`  ⏭️  \${snap.summary.skipped} skipped\`);
if (snap.summary.broken > 0) console.log(\`  🔧 \${snap.summary.broken} broken\`);
if (snap.summary.failed > 0) console.log(\`  ❌ \${snap.summary.failed} failed\`);
if (snap.summary.untested > 0) console.log(\`  ❔ \${snap.summary.untested} untested\`);
"
        else
            echo -e "${RED}❌ No snapshot found${NC}"
            echo ""
            echo "Run a full test suite first:"
            echo "  ./run_regression.sh"
        fi
    else
        echo -e "${RED}❌ Node.js not found. Install Node.js v18+ to use --last-run${NC}"
        exit 1
    fi
    exit 0
fi

if [ "$1" = "--diff" ]; then
    # Compare snapshots to detect regressions
    if command -v node >/dev/null 2>&1; then
        if [ $# -eq 1 ]; then
            # Compare current state vs last snapshot
            node scripts/diff-snapshots.js
        elif [ $# -eq 3 ]; then
            # Compare two specific snapshots
            node scripts/diff-snapshots.js "$2" "$3"
        else
            echo "Usage:"
            echo "  ./run_regression.sh --diff              # Compare current vs last run"
            echo "  ./run_regression.sh --diff <old> <new>  # Compare two snapshots"
            exit 1
        fi
    else
        echo -e "${RED}❌ Node.js not found. Install Node.js v18+ to use --diff${NC}"
        exit 1
    fi
    exit 0
fi

if [ "$1" = "--history" ]; then
    # Show history of a specific test across snapshots
    if command -v node >/dev/null 2>&1; then
        if [ $# -eq 2 ]; then
            # Show history for specified test
            node scripts/test-history.js "$2"
        else
            echo "Usage:"
            echo "  ./run_regression.sh --history <test-id>"
            echo ""
            echo "Examples:"
            echo "  ./run_regression.sh --history 123          # Show history for test 123"
            echo "  ./run_regression.sh --history 9100/456     # Test 456 in category 9100"
            echo ""
            echo "Shows when a test was last passing and which commits broke it."
            exit 1
        fi
    else
        echo -e "${RED}❌ Node.js not found. Install Node.js v18+ to use --history${NC}"
        exit 1
    fi
    exit 0
fi

if [ "$1" = "--regressions" ]; then
    # Show currently-failing tests and when they last passed
    if command -v node >/dev/null 2>&1; then
        node scripts/show-regressions.js
    else
        echo -e "${RED}❌ Node.js not found. Install Node.js v18+ to use --regressions${NC}"
        exit 1
    fi
    exit 0
fi

if [ "$1" = "--list" ]; then
    # List all tests with descriptions
    echo "═══════════════════════════════════════════════════════════"
    echo "KORU REGRESSION TESTS"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    CURRENT_CATEGORY=""
    while IFS= read -r -d '' test_dir; do
        TEST_NAME=$(basename "$test_dir")

        # Only process directories that match test naming pattern (digits optionally followed by letter, then underscore)
        # This matches the Node.js generate-status.js filtering logic and prevents listing subdirectories like test_lib/
        if ! [[ "$TEST_NAME" =~ ^[0-9]+[a-z]?_ ]]; then
            continue
        fi

        # Check if this is a test directory (has input.kz or TODO or SKIP or BROKEN)
        # Note: Tests can have README.md for documentation - that doesn't make them category directories
        if [ ! -f "$test_dir/input.kz" ] && [ ! -f "$test_dir/TODO" ] && [ ! -f "$test_dir/SKIP" ] && [ ! -f "$test_dir/BROKEN" ]; then
            # Not a test directory - skip it (might be category/docs directory)
            continue
        fi

        # Print category header
        PARENT_DIR=$(basename "$(dirname "$test_dir")")
        if [ "$PARENT_DIR" != "regression" ] && [ "$PARENT_DIR" != "$CURRENT_CATEGORY" ]; then
            CURRENT_CATEGORY="$PARENT_DIR"
            CATEGORY=$(echo "$PARENT_DIR" | sed 's/^[0-9]*_//' | tr '_' ' ')
            echo ""
            echo -e "${CYAN}$CATEGORY${NC}"
            echo "────────────────────────────────────"
        fi

        # Show test with status
        if [ -f "$test_dir/TODO" ]; then
            DESC=$(head -1 "$test_dir/TODO" 2>/dev/null || echo "")
            echo -e "  ${YELLOW}📝${NC} $TEST_NAME - $DESC"
        elif [ -f "$test_dir/SKIP" ]; then
            REASON=$(head -1 "$test_dir/SKIP" 2>/dev/null || echo "")
            echo -e "  ${GREEN}⏭️ ${NC} $TEST_NAME - $REASON"
        elif [ -f "$test_dir/BROKEN" ]; then
            REASON=$(head -1 "$test_dir/BROKEN" 2>/dev/null || echo "")
            echo -e "  ${RED}🔧${NC} $TEST_NAME - $REASON"
        elif [ -f "$test_dir/SUCCESS" ]; then
            # Try to get description from test or parent SPEC.md
            echo -e "  ${GREEN}✅${NC} $TEST_NAME"
        elif [ -f "$test_dir/FAILURE" ]; then
            FAIL_REASON=$(cat "$test_dir/FAILURE" 2>/dev/null || echo "")
            echo -e "  ${RED}❌${NC} $TEST_NAME ($FAIL_REASON)"
        else
            echo -e "     $TEST_NAME"
        fi
    done < <(find tests/regression -mindepth 1 -type d -print0 | sort -z)

    echo ""
    exit 0
fi

# Parse command line arguments for test selection and options
TEST_FILTERS=()
SMOKE_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ignore-leaks)
            CHECK_LEAKS=false
            shift
            ;;
        --check-leaks)
            CHECK_LEAKS=true
            shift
            ;;
        --no-rebuild)
            REBUILD_COMPILER=false
            shift
            ;;
        --run-units)
            RUN_UNIT_TESTS=true
            echo "🧪 Unit tests ENABLED"
            echo ""
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            echo "📢 Verbose mode ENABLED - full stderr output on failures"
            ;;
        --priority)
            SHOW_PRIORITY=true
            echo ""
            shift
            ;;
        --clean)
            CLEAN_CACHE=true
            shift
            ;;
        --parallel)
            shift
            if [ -n "$1" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
                PARALLEL_JOBS="$1"
                shift
            else
                echo "Error: --parallel requires a number"
                exit 1
            fi
            ;;
        smoke)
            SMOKE_MODE=true
            TEST_FILTERS+=(
                "102_*" "205_*" "302_*" "401_*" "501_*" 
                "603_*" "609_*" "701_*" "801_*" "831_*" "916_*" 
            )
            shift
            ;;
        --filter)
            if [[ -n "$2" ]]; then
                TEST_FILTERS+=("*$2*")
                shift 2
            else
                echo -e "${RED}❌ Error: --filter requires an argument${NC}"
                exit 1
            fi
            ;;
        -*)
            # Other flags are handled by early exit sections (like --help, --status)
            # If we get here, it's an unrecognized flag
            echo -e "${RED}❌ Error: Unrecognized option $1${NC}"
            exit 1
            ;;
        *)
            arg="$1"
            # Normalize path if user provided one (strip trailing slash and directories)
            if [[ "$arg" == *"/"* ]]; then
                arg=$(basename "$arg")
            fi

            if [[ "$arg" =~ ^[0-9]+$ ]]; then
                # Numeric shortcut
                if [ ${#arg} -eq 1 ]; then
                    # 1 -> 100-199 and 1000-1999
                    TEST_FILTERS+=("${arg}[0-9][0-9]_*")
                    TEST_FILTERS+=("${arg}[0-9][0-9][0-9]_*")
                elif [ ${#arg} -eq 2 ]; then
                    # 83 -> 830-839
                    TEST_FILTERS+=("${arg}[0-9]_*")
                else
                    # 320 -> 320_*
                    TEST_FILTERS+=("${arg}_*")
                fi
            else
                # Arbitrary substring search
                TEST_FILTERS+=("*${arg}*")
            fi
            shift
            ;;
    esac
done

# Display what we're running
if [ "$SMOKE_MODE" = true ]; then
    echo "🔥 SMOKE TEST MODE - Running curated test suite"
    echo ""
elif [ ${#TEST_FILTERS[@]} -gt 0 ]; then
    # Join patterns with space for display
    DISPLAY_FILTERS=$(echo "${TEST_FILTERS[*]}" | sed 's/\*//g')
    echo -e "${CYAN}Running with filters:${NC} $DISPLAY_FILTERS"
    echo ""
fi

# ════════════════════════════════════════
# COMPILER BUILD - Ensure tests run against current code
# ════════════════════════════════════════
if [ "$REBUILD_COMPILER" = true ]; then
    echo "🔨 Building compiler..."
    if ! zig build 2>&1 | tail -5; then
        echo ""
        echo -e "${RED}❌ Compiler build failed${NC}"
        exit 1
    fi
    echo ""
fi

# ════════════════════════════════════════
# ZIG CACHE MANAGEMENT - Speed up compilation
# ════════════════════════════════════════
if [ "$CLEAN_CACHE" = true ]; then
    echo "🧹 Cleaning Zig caches..."
    rm -rf "$ZIG_GLOBAL_CACHE"
    find tests/regression -name ".zig-cache" -type d -exec rm -rf {} + 2>/dev/null || true
    find tests/regression -name "zig-out" -type d -exec rm -rf {} + 2>/dev/null || true
    echo "   Cleaned global cache and per-test caches"
    echo ""
fi

# Ensure global cache directory exists
mkdir -p "$ZIG_GLOBAL_CACHE"

if [ "$CHECK_LEAKS" = true ]; then
    echo "🔍 Memory leak checking ENABLED - leaks will fail tests"
else
    echo "⚠️  Memory leak checking DISABLED - leaks will NOT fail tests"
fi
echo ""

# ════════════════════════════════════════
# PARALLEL MODE - Fast execution with helper script
# ════════════════════════════════════════
if [ "$PARALLEL_JOBS" -gt 1 ]; then
    echo "⚡ Parallel mode: $PARALLEL_JOBS concurrent jobs"
    echo ""

    # Collect test directories
    if [ ${#TEST_FILTERS[@]} -eq 0 ]; then
        TEST_DIRS=$(find tests/regression -mindepth 1 -type d -print0 | sort -z | xargs -0 -n1)
    else
        find_args=(tests/regression -mindepth 1 -type d "(")
        for i in "${!TEST_FILTERS[@]}"; do
            if [ $i -gt 0 ]; then find_args+=("-or"); fi
            find_args+=("-name" "${TEST_FILTERS[$i]}")
        done
        find_args+=(")" "-print0")
        TEST_DIRS=$(find "${find_args[@]}" | sort -z | xargs -0 -n1)
    fi

    # Filter to actual test directories
    FILTERED_DIRS=""
    for dir in $TEST_DIRS; do
        TEST_NAME=$(basename "$dir")
        if [[ "$TEST_NAME" =~ ^[0-9]+[a-z]?_ ]]; then
            if [ -f "$dir/input.kz" ] || [ -f "$dir/TODO" ] || [ -f "$dir/SKIP" ] || [ -f "$dir/BROKEN" ] || [ -f "$dir/BENCHMARK" ]; then
                FILTERED_DIRS="$FILTERED_DIRS $dir"
            fi
        fi
    done

    TOTAL_TESTS=$(echo $FILTERED_DIRS | wc -w | tr -d ' ')
    echo "Running $TOTAL_TESTS tests..."
    echo ""

    # Clean up previous SUCCESS/FAILURE markers for tests we're about to run.
    # Match serial behavior: do not clear markers for TODO/SKIP/BENCHMARK/BROKEN or category-skipped tests.
    for dir in $FILTERED_DIRS; do
        if [ -f "$dir/BENCHMARK" ] || [ -f "$dir/TODO" ] || [ -f "$dir/SKIP" ] || [ -f "$dir/BROKEN" ]; then
            continue
        fi
        if [ -f "$(dirname "$dir")/SKIP" ]; then
            continue
        fi
        rm -f "$dir/SUCCESS" "$dir/FAILURE" 2>/dev/null
    done

    # Run in parallel, capture output for debugging only
    PARALLEL_OUTPUT="/tmp/koru-parallel-output.txt"
    : > "$PARALLEL_OUTPUT"
    echo "$FILTERED_DIRS" | tr ' ' '\n' | grep -v '^$' | \
        env REGRESSION_QUIET=true CHECK_LEAKS="$CHECK_LEAKS" VERBOSE="$VERBOSE" ZIG_GLOBAL_CACHE="$ZIG_GLOBAL_CACHE" \
        xargs -P "$PARALLEL_JOBS" -I{} ./run_single_test.sh {} 2>&1 | \
        tee "$PARALLEL_OUTPUT"

    # Count results from on-disk markers (source of truth)
    PASSED_TESTS=0
    FAILED_COUNT=0
    TODO_TESTS=0
    SKIPPED_TESTS=0
    BROKEN_TESTS=0
    BENCHMARK_TESTS=0
    FAILED_LIST=()

    for dir in $FILTERED_DIRS; do
        TEST_NAME=$(basename "$dir")
        CATEGORY_DIR="$(dirname "$dir")"

        if [ -f "$dir/BENCHMARK" ]; then
            BENCHMARK_TESTS=$((BENCHMARK_TESTS + 1))
            continue
        fi
        if [ -f "$dir/TODO" ]; then
            TODO_TESTS=$((TODO_TESTS + 1))
            continue
        fi
        if [ -f "$CATEGORY_DIR/SKIP" ]; then
            SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
            continue
        fi
        if [ -f "$dir/SKIP" ]; then
            SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
            continue
        fi
        if [ -f "$dir/BROKEN" ]; then
            BROKEN_TESTS=$((BROKEN_TESTS + 1))
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAIL_REASON=$(head -1 "$dir/FAILURE" 2>/dev/null || echo "broken-test")
            FAILED_LIST+=("$TEST_NAME(${FAIL_REASON:-broken-test})")
            continue
        fi

        if [ -f "$dir/SUCCESS" ] && [ -f "$dir/FAILURE" ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_LIST+=("$TEST_NAME(unknown)")
            continue
        fi
        if [ -f "$dir/SUCCESS" ]; then
            PASSED_TESTS=$((PASSED_TESTS + 1))
            continue
        fi
        if [ -f "$dir/FAILURE" ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAIL_REASON=$(head -1 "$dir/FAILURE" 2>/dev/null || echo "failure")
            FAILED_LIST+=("$TEST_NAME(${FAIL_REASON:-failure})")
            continue
        fi

        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_LIST+=("$TEST_NAME(no-marker)")
    done

    echo ""
    echo "════════════════════════════════════════"
    SUMMARY_LINE="RESULTS: $PASSED_TESTS passed, $FAILED_COUNT failed"
    if [ $TODO_TESTS -gt 0 ]; then
        SUMMARY_LINE="$SUMMARY_LINE, $TODO_TESTS TODO"
    fi
    if [ $SKIPPED_TESTS -gt 0 ]; then
        SUMMARY_LINE="$SUMMARY_LINE, $SKIPPED_TESTS skipped"
    fi
    if [ $BROKEN_TESTS -gt 0 ]; then
        SUMMARY_LINE="$SUMMARY_LINE, $BROKEN_TESTS broken"
    fi
    if [ $BENCHMARK_TESTS -gt 0 ]; then
        if [ $BENCHMARK_TESTS -eq 1 ]; then
            SUMMARY_LINE="$SUMMARY_LINE, 1 benchmark"
        else
            SUMMARY_LINE="$SUMMARY_LINE, $BENCHMARK_TESTS benchmarks"
        fi
    fi
    echo "$SUMMARY_LINE"
    echo "════════════════════════════════════════"

    # Save snapshot after full run (not for filtered runs)
    if [ ${#TEST_FILTERS[@]} -eq 0 ] && [ "$SMOKE_MODE" = false ]; then
        if command -v node >/dev/null 2>&1; then
            GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
            CMD_FLAGS="$*"
            echo ""
            node scripts/save-snapshot.js \
                --passed="$PASSED_TESTS" \
                --total="$TOTAL_TESTS" \
                --flags="$CMD_FLAGS" \
                --commit="$GIT_COMMIT" 2>&1 | while read line; do
                echo "  $line"
            done
        fi
    fi

    # Show failed tests
    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${RED}FAILED TESTS:${NC}"
        for item in "${FAILED_LIST[@]}"; do
            echo "  $item"
        done
        echo ""
        echo -e "${RED}❌ Some tests failed${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
        exit 0
    fi
fi

# ════════════════════════════════════════
# UNIT TESTS - Run first for fast feedback
# ════════════════════════════════════════
UNIT_TESTS_PASSED=true
if [ "$RUN_UNIT_TESTS" = true ]; then
    echo "════════════════════════════════════════"
    echo "    UNIT TESTS (zig build test)"
    echo "════════════════════════════════════════"
    echo ""

    if zig build test 2>&1; then
        echo ""
        echo -e "${GREEN}✅ All unit tests passed${NC}"
        echo ""
    else
        echo ""
        echo -e "${RED}❌ Unit tests FAILED${NC}"
        echo ""
        UNIT_TESTS_PASSED=false
    fi

    echo "════════════════════════════════════════"
    echo "    REGRESSION TESTS"
    echo "════════════════════════════════════════"
    echo ""
fi

# Find all test directories recursively
# Use find to walk both flat and nested structures
# Sort to maintain consistent ordering
CURRENT_CATEGORY=""
while IFS= read -r -d '' test_dir; do
    TEST_NAME=$(basename "$test_dir")

    # Only process directories that match test naming pattern (digits optionally followed by letter, then underscore)
    # This matches the Node.js generate-status.js filtering logic and prevents counting subdirectories like test_lib/
    if ! [[ "$TEST_NAME" =~ ^[0-9]+[a-z]?_ ]]; then
        continue
    fi

    # Check if this is a test directory (has input.kz or TODO or SKIP or BROKEN or BENCHMARK)
    # Note: Tests can have README.md for documentation - that doesn't make them category directories
    if [ ! -f "$test_dir/input.kz" ] && [ ! -f "$test_dir/TODO" ] && [ ! -f "$test_dir/SKIP" ] && [ ! -f "$test_dir/BROKEN" ] && [ ! -f "$test_dir/BENCHMARK" ]; then
        # Not a test directory - skip it (might be category/docs directory)
        continue
    fi

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    regression_run_one_test "$test_dir"
done < <(
    # Sort to maintain consistent ordering
    if [ ${#TEST_FILTERS[@]} -eq 0 ]; then
        # No filter: find all test directories
        find tests/regression -mindepth 1 -type d -print0 | sort -z
    else
        # With filters: build find command with multiple -name patterns joined by -or
        # Using an array for arguments is safer than building a string for eval
        find_args=(tests/regression -mindepth 1 -type d "(")
        for i in "${!TEST_FILTERS[@]}"; do
            if [ $i -gt 0 ]; then
                find_args+=("-or")
            fi
            find_args+=("-name" "${TEST_FILTERS[$i]}")
        done
        find_args+=(")" "-print0")
        
        find "${find_args[@]}" | sort -z
    fi
)

# Summary
echo ""
echo "════════════════════════════════════════"

# Build status line with all counters
STATUS_LINE="RESULTS: $PASSED_TESTS/$TOTAL_TESTS passed"

# Add TODO/SKIP/BROKEN counts if any exist
MARKERS=""
if [ $TODO_TESTS -gt 0 ]; then
    MARKERS="$TODO_TESTS TODO"
fi
if [ $SKIPPED_TESTS -gt 0 ]; then
    if [ -n "$MARKERS" ]; then
        MARKERS="$MARKERS, $SKIPPED_TESTS skipped"
    else
        MARKERS="$SKIPPED_TESTS skipped"
    fi
fi
if [ $BROKEN_TESTS -gt 0 ]; then
    if [ -n "$MARKERS" ]; then
        MARKERS="$MARKERS, $BROKEN_TESTS broken"
    else
        MARKERS="$BROKEN_TESTS broken"
    fi
fi

if [ -n "$MARKERS" ]; then
    STATUS_LINE="$STATUS_LINE ($MARKERS)"
fi

if [ $BENCHMARK_TESTS -gt 0 ]; then
    if [ $BENCHMARK_TESTS -eq 1 ]; then
        STATUS_LINE="$STATUS_LINE (1 benchmark)"
    else
        STATUS_LINE="$STATUS_LINE ($BENCHMARK_TESTS benchmarks)"
    fi
fi

if [ $LEAKED_TESTS -gt 0 ]; then
    if [ "$CHECK_LEAKS" = true ]; then
        STATUS_LINE="$STATUS_LINE ($LEAKED_TESTS with memory leaks)"
    else
        STATUS_LINE="$STATUS_LINE ($LEAKED_TESTS with memory leaks [not failing])"
    fi
fi

echo "$STATUS_LINE"
echo "════════════════════════════════════════"

# Report unit test status
if [ "$RUN_UNIT_TESTS" = true ]; then
    if [ "$UNIT_TESTS_PASSED" = true ]; then
        echo -e "${GREEN}✅ Unit tests: PASSED${NC}"
    else
        echo -e "${RED}❌ Unit tests: FAILED${NC}"
    fi
fi

# Report failed tests
if [ -n "$FAILED_TESTS" ]; then
    echo -e "${RED}❌ FAILED TESTS:$FAILED_TESTS${NC}"
fi

# Report priority tests
if [ "$PRIORITY_TESTS" -gt 0 ]; then
    echo -e "${RED}🔥 PRIORITY ($PRIORITY_TESTS):$PRIORITY_LIST${NC}"
    echo "   Run './run_regression.sh --priority' for details"
fi

# Save snapshot after full run (not for filtered runs)
# Only save if Node.js is available and this was a full run
if [ ${#TEST_FILTERS[@]} -eq 0 ] && [ "$SMOKE_MODE" = false ]; then
    if command -v node >/dev/null 2>&1; then
        # Get git commit hash
        GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

        # Capture command flags
        CMD_FLAGS="$*"

        # Save snapshot
        echo ""
        node scripts/save-snapshot.js \
            --passed="$PASSED_TESTS" \
            --total="$TOTAL_TESTS" \
            --flags="$CMD_FLAGS" \
            --commit="$GIT_COMMIT" 2>&1 | while read line; do
            echo "  $line"
        done
    fi
fi

# Exit with appropriate code
# Success = all regression tests passed AND (unit tests passed OR skipped)
if [ -z "$FAILED_TESTS" ]; then
    if [ "$RUN_UNIT_TESTS" = true ] && [ "$UNIT_TESTS_PASSED" = false ]; then
        echo -e "${YELLOW}⚠️  Regression tests passed, but UNIT TESTS FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
        exit 0
    fi
else
    echo -e "${RED}❌ Some tests failed${NC}"
    exit 1
fi
