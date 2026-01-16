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

TEST_NAME=$(basename "$test_dir")
ZIG_GLOBAL_CACHE="${TMPDIR:-/tmp}/koru-regression-cache"

# Quick checks for skip/todo/benchmark
if [ -f "$test_dir/BENCHMARK" ]; then
    echo "BENCHMARK: $TEST_NAME"
    exit 0
fi

if [ -f "$test_dir/TODO" ]; then
    echo "TODO: $TEST_NAME"
    exit 0
fi

if [ -f "$test_dir/SKIP" ]; then
    echo "SKIP: $TEST_NAME"
    exit 0
fi

if [ ! -f "$test_dir/input.kz" ]; then
    echo "FAIL: $TEST_NAME (no input.kz)"
    echo "no-input" > "$test_dir/FAILURE"
    exit 1
fi

# Clean artifacts
rm -f "$test_dir/backend.zig" "$test_dir/backend" "$test_dir/output" \
      "$test_dir/compile_backend.err" "$test_dir/backend.err" \
      "$test_dir/compile_kz.err" "$test_dir/SUCCESS" "$test_dir/FAILURE"
rm -rf "$test_dir/zig-out"

# Get compiler flags
COMPILER_FLAGS=""
if [ -f "$test_dir/COMPILER_FLAGS" ]; then
    COMPILER_FLAGS=$(cat "$test_dir/COMPILER_FLAGS" | tr '\n' ' ')
fi

# Step 1: Compile Koru to Zig
if ! ./zig-out/bin/koruc "$test_dir/input.kz" --output "$test_dir/backend.zig" $COMPILER_FLAGS 2>"$test_dir/compile_kz.err"; then
    # Check if failure was expected
    if [ -f "$test_dir/MUST_FAIL" ] || [ -f "$test_dir/EXPECT" ]; then
        if [ -f "$test_dir/EXPECT" ]; then
            EXPECTED=$(cat "$test_dir/EXPECT")
            if [ "$EXPECTED" = "FRONTEND_COMPILE_ERROR" ]; then
                echo "PASS: $TEST_NAME (expected frontend error)"
                echo "PASS" > "$test_dir/SUCCESS"
                exit 0
            fi
        fi
        echo "PASS: $TEST_NAME (expected failure)"
        echo "PASS" > "$test_dir/SUCCESS"
        exit 0
    fi
    echo "FAIL: $TEST_NAME (frontend)"
    echo "frontend" > "$test_dir/FAILURE"
    exit 1
fi

# Step 2: Compile Zig backend
BUILD_FILE="build_backend.zig"
if [ ! -f "$test_dir/$BUILD_FILE" ]; then
    BUILD_FILE="build.zig"
fi

if ! (cd "$test_dir" && zig build --build-file "$BUILD_FILE" --global-cache-dir "$ZIG_GLOBAL_CACHE" 2>"compile_backend.err"); then
    # Check if failure was expected
    if [ -f "$test_dir/MUST_FAIL" ]; then
        echo "PASS: $TEST_NAME (expected backend failure)"
        echo "PASS" > "$test_dir/SUCCESS"
        exit 0
    fi
    echo "FAIL: $TEST_NAME (backend)"
    echo "backend" > "$test_dir/FAILURE"
    exit 1
fi

# Move binary
mv "$test_dir/zig-out/bin/backend" "$test_dir/backend" 2>/dev/null || true

# Step 3: Run backend to generate output binary
if [ -f "$test_dir/backend" ]; then
    # Run backend with "output" argument to generate the output binary
    if ! (cd "$test_dir" && ./backend output) >"$test_dir/backend.out" 2>"$test_dir/backend.err"; then
        if [ -f "$test_dir/MUST_FAIL" ]; then
            echo "PASS: $TEST_NAME (expected backend-exec failure)"
            echo "PASS" > "$test_dir/SUCCESS"
            exit 0
        fi
        echo "FAIL: $TEST_NAME (backend-exec)"
        echo "backend-exec" > "$test_dir/FAILURE"
        exit 1
    fi
fi

# Step 4: Run output binary and check results if MUST_RUN
if [ -f "$test_dir/MUST_RUN" ] && [ -f "$test_dir/output" ]; then
    if ! "$test_dir/output" > "$test_dir/actual.txt" 2>&1; then
        if [ -f "$test_dir/MUST_FAIL" ]; then
            echo "PASS: $TEST_NAME (expected exec failure)"
            echo "PASS" > "$test_dir/SUCCESS"
            exit 0
        fi
        echo "FAIL: $TEST_NAME (exec)"
        echo "exec" > "$test_dir/FAILURE"
        exit 1
    fi

    # Check output if expected.txt exists
    if [ -f "$test_dir/expected.txt" ]; then
        # Compare with whitespace trimming like main script
        EXPECTED_TRIMMED=$(sed 's/[[:space:]]*$//' "$test_dir/expected.txt")
        ACTUAL_TRIMMED=$(sed 's/[[:space:]]*$//' "$test_dir/actual.txt")
        if [ "$EXPECTED_TRIMMED" != "$ACTUAL_TRIMMED" ]; then
            echo "FAIL: $TEST_NAME (output)"
            echo "output" > "$test_dir/FAILURE"
            exit 1
        fi
    fi
fi

# Clean up
rm -rf "$test_dir/zig-out"

echo "PASS: $TEST_NAME"
echo "PASS" > "$test_dir/SUCCESS"
exit 0
