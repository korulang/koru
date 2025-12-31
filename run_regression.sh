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

if [ "$CHECK_LEAKS" = true ]; then
    echo "🔍 Memory leak checking ENABLED - leaks will fail tests"
    echo ""
else
    echo "⚠️  Memory leak checking DISABLED - leaks will NOT fail tests"
    echo ""
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

    # CRITICAL: Reset compilation status variables for each test
    # Without this, variables leak from previous test causing false passes!
    COMPILE_KZ_SUCCESS=false
    COMPILE_ZIG_SUCCESS=false
    RUN_SUCCESS=false

    # Print category header when entering a new category directory
    PARENT_DIR=$(basename "$(dirname "$test_dir")")
    SKIP_CATEGORY=false
    if [ "$PARENT_DIR" != "regression" ] && [ "$PARENT_DIR" != "$CURRENT_CATEGORY" ]; then
        CURRENT_CATEGORY="$PARENT_DIR"
        # Extract category name from directory name
        CATEGORY=$(echo "$PARENT_DIR" | sed 's/^[0-9]*_//' | tr '_' ' ' | tr '[:lower:]' '[:upper:]')
        echo ""
        # Calculate padding to align the right border
        # 64 (internal width) - 5 (visual width of "  📁 ") - length of category name
        PADDING_SIZE=$((64 - 5 - ${#CATEGORY}))
        # Ensure padding is not negative
        if [ "$PADDING_SIZE" -lt 0 ]; then PADDING_SIZE=0; fi
        PADDING=$(printf '%*s' "$PADDING_SIZE" "")

        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}  📁 ${CYAN}${CATEGORY}${NC}${PADDING}${BLUE}║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        # Check for category-level SKIP file
        CATEGORY_DIR="$(dirname "$test_dir")"
        if [ -f "$CATEGORY_DIR/SKIP" ]; then
            SKIP_CATEGORY=true
            SKIP_REASON=$(head -1 "$CATEGORY_DIR/SKIP" 2>/dev/null || echo "No reason provided")
            echo -e "${YELLOW}⏭️  Category skipped: $SKIP_REASON${NC}"
            echo ""
        fi
    elif [ "$PARENT_DIR" != "regression" ]; then
        # Still in same category, check if category was marked to skip
        CATEGORY_DIR="$(dirname "$test_dir")"
        if [ -f "$CATEGORY_DIR/SKIP" ]; then
            SKIP_CATEGORY=true
        fi
    fi

    echo -n "Running $TEST_NAME... "

    # Check for BENCHMARK file - print contents and skip
    if [ -f "$test_dir/BENCHMARK" ]; then
        echo -e "${CYAN}📊 BENCHMARK${NC}"
        BENCHMARK_CONTENT=$(cat "$test_dir/BENCHMARK" 2>/dev/null || echo "No description")
        echo "  $BENCHMARK_CONTENT"
        BENCHMARK_TESTS=$((BENCHMARK_TESTS + 1))
        continue
    fi

    # Check for TODO file - feature not yet implemented (aspirational test)
    if [ -f "$test_dir/TODO" ]; then
        echo -e "${YELLOW}📝 TODO${NC}"
        # Read first line of TODO file as the feature description
        TODO_FEATURE=$(head -1 "$test_dir/TODO" 2>/dev/null || echo "No description provided")
        echo "  Feature: $TODO_FEATURE"
        TODO_TESTS=$((TODO_TESTS + 1))  # Count separately from skips
        continue
    fi

    # Check for category-level SKIP - skip all tests in this category
    if [ "$SKIP_CATEGORY" = true ]; then
        echo -e "${GREEN}⏭️  SKIPPED (category)${NC}"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        continue
    fi

    # Check for SKIP file - feature implemented but test skipped for specific reason
    if [ -f "$test_dir/SKIP" ]; then
        echo -e "${GREEN}⏭️  SKIPPED${NC}"
        # Read first line of SKIP file as the reason
        SKIP_REASON=$(head -1 "$test_dir/SKIP" 2>/dev/null || echo "No reason provided")
        echo "  Reason: $SKIP_REASON"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))  # Count separately, not as pass or fail
        continue
    fi

    # Check for PRIORITY file - track tests that need attention
    if [ -f "$test_dir/PRIORITY" ]; then
        PRIORITY_TESTS=$((PRIORITY_TESTS + 1))
        PRIORITY_REASON=$(head -1 "$test_dir/PRIORITY" 2>/dev/null || echo "")
        PRIORITY_LIST="$PRIORITY_LIST $TEST_NAME"
        echo -e "${RED}🔥 PRIORITY${NC}: $PRIORITY_REASON"
    fi

    # Check for BROKEN file - test itself is broken/incorrect
    # These tests fail immediately to mark them as needing fixes
    if [ -f "$test_dir/BROKEN" ]; then
        echo -e "${RED}❌ BROKEN TEST${NC}"
        BROKEN_REASON=$(cat "$test_dir/BROKEN" 2>/dev/null || echo "No reason provided")
        echo "  Reason: $BROKEN_REASON"
        echo "broken-test" > "$test_dir/FAILURE"
        BROKEN_TESTS=$((BROKEN_TESTS + 1))
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(broken-test)"
        continue
    fi

    # Check for input file
    if [ ! -f "$test_dir/input.kz" ]; then
        echo -e "${RED}❌ Missing input.kz${NC}"
        echo "no-input" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-input)"
        continue
    fi

    # Check for inconsistent test configuration
    # CRITICAL: Tests that define expected output MUST run to validate it
    # Otherwise they dishonestly pass by claiming "compile only" when they should verify output
    # Note: Tests with EXPECT file use a different validation mechanism (expected errors/output patterns)
    if [ -f "$test_dir/expected.txt" ] && [ ! -f "$test_dir/MUST_RUN" ] && [ ! -f "$test_dir/EXPECT" ]; then
        echo -e "${RED}❌ Test has expected.txt but no MUST_RUN marker${NC}"
        echo "  This test expects output but won't run! Add MUST_RUN or remove expected.txt"
        echo "config-error" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(config-error)"
        continue
    fi

    # CRITICAL: Clean up artifacts from previous runs to prevent false passes
    # Only remove generated files, never test inputs or expected outputs
    # Clean ALL artifacts including build directories to ensure fresh start
    # (especially important if previous test was interrupted/crashed)
    rm -f "$test_dir/backend.zig" \
          "$test_dir/backend" \
          "$test_dir/output" \
          "$test_dir/output_emitted.zig" \
          "$test_dir/actual.txt" \
          "$test_dir/compile_backend.err" \
          "$test_dir/backend.err" \
          "$test_dir/compile_kz.err" \
          "$test_dir/backend.out" \
          "$test_dir/post.log" \
          "$test_dir/ast.err" \
          "$test_dir/actual.json" \
          "$test_dir/temp_build.zig" \
          "$test_dir/build.zig" \
          "$test_dir/SUCCESS" \
          "$test_dir/FAILURE"

    # Clean up build directories from crashed/interrupted tests
    rm -rf "$test_dir/zig-out" \
           "$test_dir/.zig-cache"

    # Check for COMPILER_FLAGS file to pass additional flags
    COMPILER_FLAGS=""
    if [ -f "$test_dir/COMPILER_FLAGS" ]; then
        COMPILER_FLAGS=$(cat "$test_dir/COMPILER_FLAGS" | tr '\n' ' ')
    fi

    # PARSER_TEST: AST validation tests - check BEFORE attempting full compilation
    # These tests only validate the parser output (AST structure) without code generation
    if [ -f "$test_dir/PARSER_TEST" ]; then
        # Generate AST JSON (allow non-zero exit for lenient parse error tests)
        # Use COMPILER_FLAGS if present (needed for conditional imports)
        ./zig-out/bin/koruc "$test_dir/input.kz" --ast-json $COMPILER_FLAGS > "$test_dir/actual.json" 2>"$test_dir/ast.err"
        AST_GEN_EXIT=$?

        # Check if AST JSON was actually generated
        if [ ! -s "$test_dir/actual.json" ]; then
            echo -e "${RED}❌ Failed to generate AST JSON (no output)${NC}"
            if [ -s "$test_dir/ast.err" ]; then
                head -5 "$test_dir/ast.err"
            fi
            echo "ast-gen-empty" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(ast-gen-empty)"
            continue
        fi

        # Compare against expected.json
        if [ ! -f "$test_dir/expected.json" ]; then
            echo -e "${RED}❌ PARSER_TEST requires expected.json${NC}"
            echo "no-expected" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-expected)"
            continue
        fi

        # TODO: Use proper JSON comparison (for now, use diff)
        # In future: parse both JSONs and do structural comparison
        if diff -q "$test_dir/expected.json" "$test_dir/actual.json" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ PASS (AST validated)${NC}"
            echo "PASS" > "$test_dir/SUCCESS"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            echo -e "${RED}❌ AST mismatch${NC}"
            echo "  Expected: $test_dir/expected.json"
            echo "  Actual:   $test_dir/actual.json"
            # Show first difference
            diff "$test_dir/expected.json" "$test_dir/actual.json" | head -10
            echo "ast-mismatch" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(ast-mismatch)"
        fi
        continue
    fi

    # TWO-PASS COMPILATION
    # Pass 1: Frontend - Parse .kz -> backend.zig (serialized AST + code generator)
    if ./zig-out/bin/koruc "$test_dir/input.kz" -o "$test_dir/backend.zig" $COMPILER_FLAGS 2>"$test_dir/compile_kz.err"; then
        COMPILE_KZ_SUCCESS=true
    else
        COMPILE_KZ_SUCCESS=false
    fi

    # Check for memory leaks in frontend compilation (stderr)
    # We track leaks separately per phase to give better diagnostics
    HAS_MEMORY_LEAK=false
    LEAK_PHASE=""
    if [ -f "$test_dir/compile_kz.err" ] && grep -q "memory address.*leaked" "$test_dir/compile_kz.err"; then
        HAS_MEMORY_LEAK=true
        LEAK_PHASE="frontend"
    fi
    
    # Check if frontend error was expected
    if [ "$COMPILE_KZ_SUCCESS" = false ]; then
        FRONTEND_ERROR_EXPECTED=false

        # Check for EXPECT file with FRONTEND_COMPILE_ERROR
        if [ -f "$test_dir/EXPECT" ]; then
            if grep -q "^FRONTEND_COMPILE_ERROR$" "$test_dir/EXPECT"; then
                FRONTEND_ERROR_EXPECTED=true
                # If this is a PARSER_TEST, we still need to validate AST
                # Otherwise, we're done - the error was expected
                if [ ! -f "$test_dir/PARSER_TEST" ]; then
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ Expected frontend error but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    else
                        echo -e "${GREEN}✅ PASS (expected frontend compile error)${NC}"
                        echo "PASS" > "$test_dir/SUCCESS"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                        if [ "$HAS_MEMORY_LEAK" = true ]; then
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        fi
                    fi
                    continue
                fi
                # Fall through to PARSER_TEST section for AST validation
            fi
        fi

        # CRITICAL FIX: If frontend failed and it wasn't expected, ALWAYS fail the test
        # This prevents using stale backend.zig from previous runs
        if [ "$FRONTEND_ERROR_EXPECTED" = false ]; then
            echo -e "${RED}❌ Frontend compilation failed${NC}"
            if [ -s "$test_dir/compile_kz.err" ]; then
                if [ "$VERBOSE" = true ]; then
                    # Verbose mode: show FULL stderr output
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  FULL OUTPUT from $test_dir/compile_kz.err:"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    cat "$test_dir/compile_kz.err" | sed 's/^/  /'
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                else
                    # Normal mode: show truncated error (first real error line)
                    FIRST_ERROR=$(grep -v "memory address.*leaked\|/opt/homebrew\|/Users.*\.zig:" "$test_dir/compile_kz.err" | grep "error:" | head -1)
                    if [ -n "$FIRST_ERROR" ]; then
                        echo "  $FIRST_ERROR"
                        echo "  (Use --verbose to see full stderr output)"
                    fi
                fi
            fi
            echo "frontend" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(frontend)"
            continue
        fi
    fi

    # Pass 2: Backend - Compiles the backend and runs it to generate and compile final code
    if [ -f "$test_dir/backend.zig" ]; then
        # Compile the backend - use zig build instead for proper module handling
        # Calculate relative path from test_dir to repo root
        # Count directory depth from PWD (repo root) to test_dir
        REL_TO_ROOT=$(realpath --relative-to="$test_dir" "$PWD")

        # Create a temporary build.zig for this backend
        cat > "$test_dir/temp_build.zig" <<EOF
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const errors_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ast_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_module.addImport("errors", errors_module);
    const lexer_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const annotation_parser_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/annotation_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const type_registry_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/type_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_registry_module.addImport("ast", ast_module);
    const expression_parser_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/expression_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    expression_parser_module.addImport("lexer", lexer_module);
    expression_parser_module.addImport("ast", ast_module);
    const union_collector_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/union_collector.zig"),
        .target = target,
        .optimize = optimize,
    });
    union_collector_module.addImport("ast", ast_module);
    const parser_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_module.addImport("ast", ast_module);
    parser_module.addImport("lexer", lexer_module);
    parser_module.addImport("errors", errors_module);
    parser_module.addImport("type_registry", type_registry_module);
    parser_module.addImport("expression_parser", expression_parser_module);
    parser_module.addImport("union_collector", union_collector_module);
    const phantom_parser_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/koru_std/phantom_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const type_inference_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/type_inference.zig"),
        .target = target,
        .optimize = optimize,
    });
    type_inference_module.addImport("ast", ast_module);
    type_inference_module.addImport("errors", errors_module);
    const branch_checker_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/branch_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shape_checker_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/shape_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    shape_checker_module.addImport("ast", ast_module);
    shape_checker_module.addImport("errors", errors_module);
    shape_checker_module.addImport("phantom_parser", phantom_parser_module);
    shape_checker_module.addImport("type_inference", type_inference_module);
    shape_checker_module.addImport("branch_checker", branch_checker_module);
    const flow_checker_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/flow_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    flow_checker_module.addImport("ast", ast_module);
    flow_checker_module.addImport("errors", errors_module);
    flow_checker_module.addImport("branch_checker", branch_checker_module);
    const phantom_semantic_checker_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/phantom_semantic_checker.zig"),
        .target = target,
        .optimize = optimize,
    });
    phantom_semantic_checker_module.addImport("ast", ast_module);
    phantom_semantic_checker_module.addImport("errors", errors_module);
    phantom_semantic_checker_module.addImport("phantom_parser", phantom_parser_module);
    const ast_functional_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/ast_functional.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast_functional_module.addImport("ast", ast_module);
    const compiler_config_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/compiler_config.zig"),
        .target = target,
        .optimize = optimize,
    });
    const emitter_helpers_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/emitter_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    emitter_helpers_module.addImport("ast", ast_module);
    emitter_helpers_module.addImport("compiler_config", compiler_config_module);
    emitter_helpers_module.addImport("type_registry", type_registry_module);
    const tap_pattern_matcher_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/tap_pattern_matcher.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tap_registry_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/tap_registry.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_registry_module.addImport("ast", ast_module);
    tap_registry_module.addImport("errors", errors_module);
    tap_registry_module.addImport("tap_pattern_matcher", tap_pattern_matcher_module);
    const tap_transformer_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/tap_transformer.zig"),
        .target = target,
        .optimize = optimize,
    });
    tap_transformer_module.addImport("ast", ast_module);
    tap_transformer_module.addImport("tap_registry", tap_registry_module);
    tap_transformer_module.addImport("emitter_helpers", emitter_helpers_module);
    const purity_helpers_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/compiler_passes/purity_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    purity_helpers_module.addImport("ast", ast_module);
    purity_helpers_module.addImport("lexer", lexer_module);
    tap_transformer_module.addImport("compiler_passes/purity_helpers", purity_helpers_module);
    emitter_helpers_module.addImport("tap_registry", tap_registry_module);
    emitter_helpers_module.addImport("compiler_passes/purity_helpers", purity_helpers_module);
    const visitor_emitter_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/visitor_emitter.zig"),
        .target = target,
        .optimize = optimize,
    });
    visitor_emitter_module.addImport("ast", ast_module);
    visitor_emitter_module.addImport("emitter_helpers", emitter_helpers_module);
    visitor_emitter_module.addImport("tap_registry", tap_registry_module);
    visitor_emitter_module.addImport("type_registry", type_registry_module);
    visitor_emitter_module.addImport("annotation_parser", annotation_parser_module);
    const fusion_detector_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/fusion_detector.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_detector_module.addImport("ast", ast_module);
    const fusion_optimizer_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/fusion_optimizer.zig"),
        .target = target,
        .optimize = optimize,
    });
    fusion_optimizer_module.addImport("ast", ast_module);
    fusion_optimizer_module.addImport("ast_functional", ast_functional_module);
    fusion_optimizer_module.addImport("fusion_detector.zig", fusion_detector_module);
    const emit_build_zig_module = b.createModule(.{
        .root_source_file = b.path("${REL_TO_ROOT}/src/emit_build_zig.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("backend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("ast", ast_module);
    exe.root_module.addImport("ast_functional", ast_functional_module);
    exe.root_module.addImport("emitter_helpers", emitter_helpers_module);
    exe.root_module.addImport("tap_registry", tap_registry_module);
    exe.root_module.addImport("tap_transformer", tap_transformer_module);
    exe.root_module.addImport("visitor_emitter", visitor_emitter_module);
    exe.root_module.addImport("parser", parser_module);
    exe.root_module.addImport("fusion_optimizer", fusion_optimizer_module);
    exe.root_module.addImport("emit_build_zig", emit_build_zig_module);
    exe.root_module.addImport("shape_checker", shape_checker_module);
    exe.root_module.addImport("flow_checker", flow_checker_module);
    exe.root_module.addImport("phantom_semantic_checker", phantom_semantic_checker_module);
    exe.root_module.addImport("errors", errors_module);
    exe.root_module.addImport("type_registry", type_registry_module);
    exe.root_module.addImport("annotation_parser", annotation_parser_module);
    b.installArtifact(exe);
}
EOF

        # Build using build_backend.zig if it exists (has proper deps), else use temp_build.zig
        BUILD_FILE="temp_build.zig"
        if [ -f "$test_dir/build_backend.zig" ]; then
            BUILD_FILE="build_backend.zig"
        fi
        if (cd "$test_dir" && zig build --build-file "$BUILD_FILE" 2>"compile_backend.err"); then
            # Check for memory leaks in backend compilation
            if [ -f "$test_dir/compile_backend.err" ] && grep -q "memory address.*leaked" "$test_dir/compile_backend.err"; then
                if [ "$HAS_MEMORY_LEAK" = false ]; then
                    HAS_MEMORY_LEAK=true
                    LEAK_PHASE="backend-compile"
                fi
            fi

            # Move the built binary to expected location
            # CRITICAL: This must succeed or we'll use a stale backend from previous run!
            if ! mv "$test_dir/zig-out/bin/backend" "$test_dir/backend" 2>/dev/null; then
                echo -e "${RED}❌ Failed to move backend executable${NC}"
                echo "backend-move" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(backend-move)"
                continue
            fi

            # Verify backend executable actually exists and is executable
            if [ ! -x "$test_dir/backend" ]; then
                echo -e "${RED}❌ Backend executable missing or not executable${NC}"
                echo "backend-missing" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(backend-missing)"
                continue
            fi

            # Run backend (it now generates AND compiles the final code)
            # Run from test directory so generated files (like build.zig) go to the right place
            if (cd "$test_dir" && ./backend output) >"$test_dir/backend.out" 2>"$test_dir/backend.err"; then
                # Check for memory leaks in backend execution
                if [ -f "$test_dir/backend.err" ] && grep -q "memory address.*leaked" "$test_dir/backend.err"; then
                    if [ "$HAS_MEMORY_LEAK" = false ]; then
                        HAS_MEMORY_LEAK=true
                        LEAK_PHASE="backend-exec"
                    fi
                fi

                COMPILE_ZIG_SUCCESS=true
                # Check if the executable was created
                if [ ! -f "$test_dir/output" ]; then
                    echo -e "${RED}❌ Backend didn't create executable${NC}"
                    echo "no-exe" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-exe)"
                    continue
                fi
                # The backend should have created output_emitted.zig for debugging
                if [ -f "output_emitted.zig" ]; then
                    mv output_emitted.zig "$test_dir/output_emitted.zig"
                fi

                # Clean up zig build artifacts now that we're done
                rm -rf "$test_dir/zig-out" "$test_dir/.zig-cache" "$test_dir/temp_build.zig"
            else
                # Backend execution failed - check if this was expected
                BACKEND_ERROR_EXPECTED=false

                # Check for MUST_FAIL marker - negative tests that must fail to pass
                if [ -f "$test_dir/MUST_FAIL" ]; then
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ Expected failure (MUST_FAIL) but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    else
                        echo -e "${GREEN}✅ PASS (expected failure - MUST_FAIL)${NC}"
                        echo "PASS" > "$test_dir/SUCCESS"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                        if [ "$HAS_MEMORY_LEAK" = true ]; then
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        fi
                    fi
                    BACKEND_ERROR_EXPECTED=true
                fi

                # Check for expected_error.txt
                if [ "$BACKEND_ERROR_EXPECTED" = false ] && [ -f "$test_dir/expected_error.txt" ]; then
                    EXPECTED_ERROR=$(cat "$test_dir/expected_error.txt" | tr -d '\n\r')
                    if [ -s "$test_dir/backend.err" ] && grep -qF "$EXPECTED_ERROR" "$test_dir/backend.err"; then
                        if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                            echo -e "${RED}❌ Expected backend error but memory leak detected ($LEAK_PHASE)${NC}"
                            echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        else
                            echo -e "${GREEN}✅ PASS (expected backend error)${NC}"
                            echo "PASS" > "$test_dir/SUCCESS"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        fi
                        BACKEND_ERROR_EXPECTED=true
                    fi
                fi

                # Check for EXPECT file with BACKEND_COMPILE_ERROR
                if [ "$BACKEND_ERROR_EXPECTED" = false ] && [ -f "$test_dir/EXPECT" ]; then
                    if grep -q "^BACKEND_COMPILE_ERROR$" "$test_dir/EXPECT"; then
                        if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                            echo -e "${RED}❌ Expected backend compile error but memory leak detected ($LEAK_PHASE)${NC}"
                            echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        else
                            echo -e "${GREEN}✅ PASS (expected backend compile error)${NC}"
                            echo "PASS" > "$test_dir/SUCCESS"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        fi
                        BACKEND_ERROR_EXPECTED=true
                    fi
                fi

                # If error wasn't expected, mark as failure
                if [ "$BACKEND_ERROR_EXPECTED" = false ]; then
                    echo -e "${RED}❌ Backend execution failed${NC}"
                    if [ -s "$test_dir/backend.err" ]; then
                        if [ "$VERBOSE" = true ]; then
                            # Verbose mode: show FULL stderr output
                            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            echo "  FULL OUTPUT from $test_dir/backend.err:"
                            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                            cat "$test_dir/backend.err" | sed 's/^/  /'
                            echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                        else
                            # Normal mode: show truncated error (6 lines around errors)
                            ERROR_LINES=$(grep -A 2 "error:" "$test_dir/backend.err" | head -6)
                            if [ -n "$ERROR_LINES" ]; then
                                echo "$ERROR_LINES" | sed 's/^/  /'
                                echo "  (Use --verbose to see full stderr output)"
                            else
                                echo "  Error: $(head -1 "$test_dir/backend.err")"
                                echo "  (Use --verbose to see full stderr output)"
                            fi
                        fi
                    fi
                    # Save output_emitted.zig for debugging even on failure
                    if [ -f "$test_dir/output_emitted.zig" ]; then
                        # Already in test_dir from backend generation
                        :
                    elif [ -f "output_emitted.zig" ]; then
                        mv output_emitted.zig "$test_dir/output_emitted.zig"
                    fi
                    echo "backend-exec" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(backend-exec)"
                fi
                # Clean up zig build artifacts
                rm -rf "$test_dir/zig-out" "$test_dir/.zig-cache" "$test_dir/temp_build.zig"
                continue
            fi
        else
            echo -e "${RED}❌ Failed to compile backend (Pass 2)${NC}"
            if [ -s "$test_dir/compile_backend.err" ]; then
                if [ "$VERBOSE" = true ]; then
                    # Verbose mode: show FULL stderr output
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  FULL OUTPUT from $test_dir/compile_backend.err:"
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    cat "$test_dir/compile_backend.err" | sed 's/^/  /'
                    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                else
                    # Normal mode: show truncated error (8 lines around backend.zig errors)
                    ERROR_LINES=$(grep -B 1 "error:" "$test_dir/compile_backend.err" | grep -A 1 "backend.zig" | head -8)
                    if [ -n "$ERROR_LINES" ]; then
                        echo "$ERROR_LINES" | sed 's/^/  /'
                        echo "  (Use --verbose to see full stderr output)"
                    else
                        echo "  Error: $(head -3 "$test_dir/compile_backend.err")"
                        echo "  (Use --verbose to see full stderr output)"
                    fi
                fi
            fi
            echo "backend" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(backend)"
            # Clean up zig build artifacts
            rm -rf "$test_dir/zig-out" "$test_dir/.zig-cache" "$test_dir/temp_build.zig"
            continue
        fi
    fi
    
    # Step 3: Run executable and check output (only if executable exists)
    if [ -f "$test_dir/output" ] && [ -f "$test_dir/MUST_RUN" ]; then
        # Run the program and capture output
        if "$test_dir/output" > "$test_dir/actual.txt" 2>&1; then
            RUN_SUCCESS=true
        else
            RUN_SUCCESS=false
        fi
        
        # Check if we have expected output or post-validation script
        if [ -f "$test_dir/expected.txt" ]; then
            # Compare outputs after trimming trailing whitespace
            EXPECTED_TRIMMED=$(sed 's/[[:space:]]*$//' "$test_dir/expected.txt")
            ACTUAL_TRIMMED=$(sed 's/[[:space:]]*$//' "$test_dir/actual.txt")
            if [ "$EXPECTED_TRIMMED" = "$ACTUAL_TRIMMED" ]; then
                # Output matches - now check if there's also a post.sh validation
                if [ -f "$test_dir/post.sh" ]; then
                    # Run post-validation script after output check
                    if (cd "$test_dir" && bash post.sh) > "$test_dir/post.log" 2>&1; then
                        if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                            echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                            echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        else
                            echo -e "${GREEN}✅ PASS (post-validated)${NC}"
                            echo "PASS" > "$test_dir/SUCCESS"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        fi
                    else
                        echo -e "${RED}❌ Post-validation failed${NC}"
                        echo "  See $test_dir/post.log for details"
                        echo "post-validation" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(post-validation)"
                    fi
                else
                    # No post.sh - just check leaks
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    else
                        echo -e "${GREEN}✅ PASS${NC}"
                        echo "PASS" > "$test_dir/SUCCESS"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                        if [ "$HAS_MEMORY_LEAK" = true ]; then
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        fi
                    fi
                fi
            else
                echo -e "${RED}❌ Output mismatch${NC}"
                echo "  Diff (expected vs actual):"
                # Show unified diff to make differences visible
                # Use head to limit output but show enough to see what's wrong
                diff -u "$test_dir/expected.txt" "$test_dir/actual.txt" | head -15 | sed 's/^/    /'
                echo "  Full files: $test_dir/expected.txt vs $test_dir/actual.txt"
                echo "output" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(output)"
            fi
        elif [ -f "$test_dir/post.sh" ]; then
            # Run custom post-validation script
            # The script has access to: test_dir, actual.txt, output_emitted.zig, backend.zig, output (executable)
            # Script should exit 0 for pass, non-zero for fail
            if (cd "$test_dir" && bash post.sh) > "$test_dir/post.log" 2>&1; then
                if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                    echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                    echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                else
                    echo -e "${GREEN}✅ PASS (post-validated)${NC}"
                    echo "PASS" > "$test_dir/SUCCESS"
                    PASSED_TESTS=$((PASSED_TESTS + 1))
                    if [ "$HAS_MEMORY_LEAK" = true ]; then
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    fi
                fi
            else
                echo -e "${RED}❌ Post-validation failed${NC}"
                echo "  See $test_dir/post.log for details"
                echo "post-validation" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(post-validation)"
            fi
        elif [ "$RUN_SUCCESS" = true ]; then
            if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                LEAKED_TESTS=$((LEAKED_TESTS + 1))
            else
                echo -e "${GREEN}✅ PASS (ran successfully)${NC}"
                echo "PASS" > "$test_dir/SUCCESS"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                if [ "$HAS_MEMORY_LEAK" = true ]; then
                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                fi
            fi
        else
            echo -e "${RED}❌ Runtime error${NC}"
            echo "runtime" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(runtime)"
        fi
    elif [ -f "$test_dir/MUST_RUN" ]; then
        echo -e "${RED}❌ No executable generated${NC}"
        echo "no-exe" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-exe)"
    else
        # Test only required compilation, not running
        if [ "$COMPILE_KZ_SUCCESS" = true ] || [ "$COMPILE_ZIG_SUCCESS" = true ]; then
            # Check for post-validation script even without MUST_RUN
            # This allows tests to validate compiler artifacts (build.zig, AST, etc.)
            # without needing to run the final executable
            if [ -f "$test_dir/post.sh" ]; then
                # Run post-validation script from test directory
                if (cd "$test_dir" && bash post.sh) > "$test_dir/post.log" 2>&1; then
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    else
                        echo -e "${GREEN}✅ PASS (post-validated)${NC}"
                        echo "PASS" > "$test_dir/SUCCESS"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                        if [ "$HAS_MEMORY_LEAK" = true ]; then
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        fi
                    fi
                else
                    echo -e "${RED}❌ Post-validation failed${NC}"
                    echo "  See $test_dir/post.log for details"
                    echo "post-validation" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(post-validation)"
                fi
            else
                # No post.sh - just check leaks and mark as compile-only pass
                if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                    echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                    echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                else
                    echo -e "${GREEN}✅ PASS (compile only)${NC}"
                    echo "PASS" > "$test_dir/SUCCESS"
                    PASSED_TESTS=$((PASSED_TESTS + 1))
                    if [ "$HAS_MEMORY_LEAK" = true ]; then
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    fi
                fi
            fi
        else
            echo -e "${RED}❌ Failed${NC}"
            echo "failed" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME"
        fi
    fi
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