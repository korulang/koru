#!/bin/bash
# Parity harness: compare serial vs parallel results on a fixed subset.

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

PARITY_JOBS=${PARITY_JOBS:-4}

RUN_ARGS=()
TEST_FILTERS=()
SMOKE_MODE=false
HAS_NO_REBUILD=false

if [ "$#" -eq 0 ]; then
    SMOKE_MODE=true
    TEST_FILTERS+=("102_*" "205_*" "302_*" "401_*" "501_*" "603_*" "609_*" "701_*" "801_*" "831_*" "916_*")
    RUN_ARGS+=("smoke")
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --parallel)
                shift 2
                ;;
            --no-rebuild)
                HAS_NO_REBUILD=true
                RUN_ARGS+=("$1")
                shift
                ;;
            --ignore-leaks|--run-units|--verbose|-v|--clean|--priority)
                RUN_ARGS+=("$1")
                shift
                ;;
            --filter)
                if [[ -n "$2" ]]; then
                    TEST_FILTERS+=("*$2*")
                    RUN_ARGS+=("$1" "$2")
                    shift 2
                else
                    echo "Error: --filter requires an argument"
                    exit 1
                fi
                ;;
            smoke)
                SMOKE_MODE=true
                TEST_FILTERS+=("102_*" "205_*" "302_*" "401_*" "501_*" "603_*" "609_*" "701_*" "801_*" "831_*" "916_*")
                RUN_ARGS+=("smoke")
                shift
                ;;
            -* )
                RUN_ARGS+=("$1")
                shift
                ;;
            *)
                arg="$1"
                if [[ "$arg" == *"/"* ]]; then
                    arg=$(basename "$arg")
                fi
                if [[ "$arg" =~ ^[0-9]+$ ]]; then
                    if [ ${#arg} -eq 1 ]; then
                        TEST_FILTERS+=("${arg}[0-9][0-9]_*")
                        TEST_FILTERS+=("${arg}[0-9][0-9][0-9]_*")
                    elif [ ${#arg} -eq 2 ]; then
                        TEST_FILTERS+=("${arg}[0-9]_*")
                    else
                        TEST_FILTERS+=("${arg}_*")
                    fi
                else
                    TEST_FILTERS+=("*${arg}*")
                fi
                RUN_ARGS+=("$1")
                shift
                ;;
        esac
    done
fi

collect_test_dirs() {
    local test_dirs
    if [ ${#TEST_FILTERS[@]} -eq 0 ]; then
        test_dirs=$(find tests/regression -mindepth 1 -type d -print0 | sort -z | xargs -0 -n1)
    else
        find_args=(tests/regression -mindepth 1 -type d "(")
        for i in "${!TEST_FILTERS[@]}"; do
            if [ $i -gt 0 ]; then find_args+=("-or"); fi
            find_args+=("-name" "${TEST_FILTERS[$i]}")
        done
        find_args+=(")" "-print0")
        test_dirs=$(find "${find_args[@]}" | sort -z | xargs -0 -n1)
    fi

    FILTERED_DIRS=""
    for dir in $test_dirs; do
        TEST_NAME=$(basename "$dir")
        if [[ "$TEST_NAME" =~ ^[0-9]+[a-z]?_ ]]; then
            if [ -f "$dir/input.kz" ] || [ -f "$dir/TODO" ] || [ -f "$dir/SKIP" ] || [ -f "$dir/BROKEN" ] || [ -f "$dir/BENCHMARK" ]; then
                FILTERED_DIRS="$FILTERED_DIRS $dir"
            fi
        fi
    done
}

capture_state() {
    local output_file="$1"
    : > "$output_file"

    for dir in $FILTERED_DIRS; do
        local category_dir
        local status
        local reason
        category_dir="$(dirname "$dir")"
        status="untested"
        reason=""

        if [ -f "$dir/BENCHMARK" ]; then
            status="benchmark"
        elif [ -f "$dir/TODO" ]; then
            status="todo"
        elif [ -f "$category_dir/SKIP" ]; then
            status="skipped"
        elif [ -f "$dir/SKIP" ]; then
            status="skipped"
        elif [ -f "$dir/BROKEN" ]; then
            status="broken"
            reason=$(head -1 "$dir/FAILURE" 2>/dev/null)
            [ -n "$reason" ] || reason="broken-test"
        elif [ -f "$dir/SUCCESS" ] && [ -f "$dir/FAILURE" ]; then
            status="unknown"
            reason="both-markers"
        elif [ -f "$dir/SUCCESS" ]; then
            status="success"
        elif [ -f "$dir/FAILURE" ]; then
            status="failure"
            reason=$(head -1 "$dir/FAILURE" 2>/dev/null)
        else
            status="untested"
            reason="no-marker"
        fi

        echo "$dir|$status|$reason" >> "$output_file"
    done

    sort -o "$output_file" "$output_file"
}

collect_test_dirs

SERIAL_STATE=$(mktemp /tmp/koru-parity-serial.XXXXXX)
PARALLEL_STATE=$(mktemp /tmp/koru-parity-parallel.XXXXXX)

cleanup() {
    rm -f "$SERIAL_STATE" "$PARALLEL_STATE"
}
trap cleanup EXIT

cd "$REPO_ROOT" || exit 1

echo "Running serial parity pass..."
./run_regression.sh "${RUN_ARGS[@]}"
SERIAL_EXIT=$?

capture_state "$SERIAL_STATE"

echo "Running parallel parity pass ($PARITY_JOBS jobs)..."
if [ "$HAS_NO_REBUILD" = true ]; then
    ./run_regression.sh --parallel "$PARITY_JOBS" "${RUN_ARGS[@]}"
else
    ./run_regression.sh --parallel "$PARITY_JOBS" --no-rebuild "${RUN_ARGS[@]}"
fi
PARALLEL_EXIT=$?

capture_state "$PARALLEL_STATE"

if diff -u "$SERIAL_STATE" "$PARALLEL_STATE"; then
    echo "Parity check passed"
    exit 0
else
    echo "Parity check failed (serial vs parallel mismatch)"
    echo "Serial exit: $SERIAL_EXIT, parallel exit: $PARALLEL_EXIT"
    exit 1
fi
