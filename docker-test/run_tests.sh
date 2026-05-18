#!/bin/bash
# Drives the smoke-test sample through the installed koruc.
# For each test dir: run koruc (full pipeline → a.out), execute, diff vs
# expected.txt if present, run post.sh if present.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

cd /work/tests
for dir in */; do
    name="${dir%/}"
    cd "/work/tests/$name"
    echo "=== $name ==="

    if ! koruc input.kz > koruc.log 2>&1; then
        # koruc failed — check if MUST_FAIL is declared
        if [ -f MUST_FAIL ]; then
            echo "  koruc failed as expected (MUST_FAIL)"
            PASS=$((PASS+1))
            cd /work/tests
            continue
        fi
        echo "  ✗ koruc failed"
        sed 's/^/    /' koruc.log | tail -10
        FAIL=$((FAIL+1))
        FAILED_TESTS+=("$name [koruc]")
        cd /work/tests
        continue
    fi

    if [ -f MUST_RUN ] && [ -f a.out ]; then
        if ./a.out > actual.txt 2>&1; then
            if [ -f expected.txt ]; then
                if diff -u expected.txt actual.txt > diff.txt; then
                    echo "  ✓ output matches expected.txt"
                else
                    echo "  ✗ output differs from expected.txt"
                    sed 's/^/    /' diff.txt | head -20
                    FAIL=$((FAIL+1))
                    FAILED_TESTS+=("$name [output]")
                    cd /work/tests
                    continue
                fi
            else
                echo "  ✓ a.out ran successfully (no expected.txt to compare)"
            fi
        else
            if [ -f MUST_FAIL ]; then
                echo "  ✓ a.out failed as expected (MUST_FAIL)"
            else
                echo "  ✗ a.out crashed"
                sed 's/^/    /' actual.txt | tail -10
                FAIL=$((FAIL+1))
                FAILED_TESTS+=("$name [runtime]")
                cd /work/tests
                continue
            fi
        fi
    fi

    if [ -f post.sh ]; then
        if bash post.sh > post.log 2>&1; then
            echo "  ✓ post.sh passed"
        else
            echo "  ✗ post.sh failed"
            sed 's/^/    /' post.log | tail -10
            FAIL=$((FAIL+1))
            FAILED_TESTS+=("$name [post.sh]")
            cd /work/tests
            continue
        fi
    fi

    PASS=$((PASS+1))
    cd /work/tests
done

echo
echo "════════════════════════════════════════"
echo "Pass: $PASS  Fail: $FAIL"
if [ $FAIL -gt 0 ]; then
    echo "Failed:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
fi
echo "════════════════════════════════════════"
exit $FAIL
