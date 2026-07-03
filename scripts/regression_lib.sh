#!/bin/bash
# Shared regression test helpers for run_regression.sh and run_single_test.sh.
# Sourced by callers; do not execute directly.

: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"

# Portable SHA-256 over stdin → bare hex digest.
_backend_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        sha256sum | awk '{print $1}'
    fi
}

# Cache key for a test's backend binary. The binary is fully determined by its
# build inputs (backend.zig + the handler set + flags + module graph) and the
# compiler-source salt — NOT by the program AST, which is now a runtime input
# (program.ast.json) and is deliberately excluded. Tests with the same handler
# set therefore collide to one key and share one built binary.
backend_cache_key() {
    local td="$1"
    {
        printf 'salt:%s\n' "$BACKEND_CACHE_SALT"
        cat "$td/backend.zig" \
            "$td/backend_output_emitted.zig" \
            "$td/compiler_env.zig" \
            "$td/build_backend.zig" 2>/dev/null
    } | _backend_sha256
}

# Stage the backend binary for a test: restore from cache on a hit (placing it at
# zig-out/bin/backend so the caller's existing `mv` path is untouched), else run
# `zig build`. Sets BACKEND_CACHE_HIT for the caller's store-on-miss decision.
# Args: $1 = test_dir, $2 = BUILD_FILE, $3 = cache key (may be empty).
backend_stage_or_build() {
    local td="$1" bf="$2" key="$3"
    if [ "$BACKEND_CACHE_MODE" = "on" ] && [ -n "$key" ] && [ -f "$BACKEND_CACHE_DIR/$key" ]; then
        mkdir -p "$td/zig-out/bin"
        if cp "$BACKEND_CACHE_DIR/$key" "$td/zig-out/bin/backend" 2>/dev/null; then
            chmod +x "$td/zig-out/bin/backend" 2>/dev/null
            BACKEND_CACHE_HIT=true
            return 0
        fi
    fi
    BACKEND_CACHE_HIT=false
    ( cd "$td" && zig build --build-file "$bf" --global-cache-dir "$ZIG_GLOBAL_CACHE" 2>"compile_backend.err" )
}

# Store a freshly-built backend binary into the cache (atomic via tmp+mv so
# parallel workers never read a partial file). No-op on a hit or when disabled.
backend_cache_store() {
    local td="$1" key="$2"
    [ "$BACKEND_CACHE_MODE" = "on" ] || return 0
    [ "$BACKEND_CACHE_HIT" = true ] && return 0
    [ -n "$key" ] || return 0
    local tmp="$BACKEND_CACHE_DIR/.$key.$$.tmp"
    if cp "$td/backend" "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$BACKEND_CACHE_DIR/$key" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
}

# Resolve a test's module entry file: input.kz (host-impl entry) if present,
# else input.k (pure-Koru entry — no host facet). Lets the harness run a
# self-contained `.k` program, not just `.kz`-rooted modules.
test_entry() {
    if [ -f "$1/input.kz" ]; then
        echo "$1/input.kz"
    else
        echo "$1/input.k"
    fi
}

: "${CHECK_LEAKS:=true}"
: "${VERBOSE:=false}"
: "${ZIG_GLOBAL_CACHE:=${TMPDIR:-/tmp}/koru-regression-cache}"
: "${KEEP_ARTIFACTS:=false}"

mark_test_passed() {
    local test_dir="$1"
    echo "PASS" > "$test_dir/SUCCESS"

    # Clean up PRIORITY file - work is done
    if [ -f "$test_dir/PRIORITY" ]; then
        rm "$test_dir/PRIORITY"
        echo -e "  ${CYAN}(PRIORITY resolved)${NC}"
    fi
}

# Match a patterns file against an actual-output file.
# Each non-empty, non-comment line in the patterns file is a POSIX ERE regex
# that MUST match somewhere in the actual output (grep -E semantics).
# Returns 0 if all patterns match, 1 otherwise. On failure, prints the
# patterns that failed to match with their line numbers.
check_expected_patterns() {
    local patterns_file="$1"
    local actual_file="$2"
    local unmatched=()
    local line_num=0
    local pattern
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        line_num=$((line_num + 1))
        [ -z "$pattern" ] && continue
        case "$pattern" in
            \#*) continue ;;
        esac
        if ! grep -qE -- "$pattern" "$actual_file"; then
            unmatched+=("$line_num: $pattern")
        fi
    done < "$patterns_file"

    if [ ${#unmatched[@]} -eq 0 ]; then
        return 0
    fi

    echo "  Patterns not matched in actual output:"
    local entry
    for entry in "${unmatched[@]}"; do
        echo "    $entry"
    done
    return 1
}

# Check EXPECT-file assertions against an actual-output file.
# Recognized lines (after skipping blanks, #-comments, and one leading
# category marker like SUCCESS / FRONTEND_COMPILE_ERROR / MUST_FAIL):
#   CONTAINS <substr>        — substr must appear in target (literal)
#   NOT_CONTAINS <substr>    — substr must NOT appear in target
#   STDOUT_CONTAINS:<substr> — substr must appear (alias of CONTAINS)
# Returns:
#   0 = at least one assertion was present and ALL satisfied
#   1 = at least one assertion failed (details printed)
#   2 = no recognized assertions in the file (caller should fall through)
check_expect_assertions() {
    local expect_file="$1"
    local actual_file="$2"
    local failed=()
    local count=0
    local seen_first_non_comment=false
    local line substr
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        # First non-comment line: skip if it's a known category marker
        if [ "$seen_first_non_comment" = false ]; then
            seen_first_non_comment=true
            case "$line" in
                SUCCESS|COMPILE_ONLY|FRONTEND_COMPILE_ERROR|BACKEND_COMPILE_ERROR|BACKEND_RUNTIME_ERROR|BACKEND_EXEC_ERROR|MUST_FAIL)
                    continue ;;
            esac
        fi
        case "$line" in
            "CONTAINS "*)
                count=$((count + 1))
                substr="${line#CONTAINS }"
                if ! grep -qF -- "$substr" "$actual_file" 2>/dev/null; then
                    failed+=("CONTAINS '$substr' not found")
                fi
                ;;
            "NOT_CONTAINS "*)
                count=$((count + 1))
                substr="${line#NOT_CONTAINS }"
                if grep -qF -- "$substr" "$actual_file" 2>/dev/null; then
                    failed+=("NOT_CONTAINS '$substr' should not appear")
                fi
                ;;
            "STDOUT_CONTAINS:"*)
                count=$((count + 1))
                substr="${line#STDOUT_CONTAINS:}"
                if ! grep -qF -- "$substr" "$actual_file" 2>/dev/null; then
                    failed+=("STDOUT_CONTAINS '$substr' not found")
                fi
                ;;
        esac
    done < "$expect_file"

    if [ "$count" -eq 0 ]; then
        return 2
    fi
    if [ ${#failed[@]} -eq 0 ]; then
        return 0
    fi
    echo "  EXPECT assertions not satisfied (target: $actual_file):"
    local entry
    for entry in "${failed[@]}"; do
        echo "    $entry"
    done
    return 1
}

# Probe whether an EXPECT file contains any CONTAINS / NOT_CONTAINS /
# STDOUT_CONTAINS assertion lines. Returns 0 if at least one exists, 1 otherwise.
# Used by callers that need to choose a control-flow branch BEFORE running the
# full assertion check.
expect_has_assertions() {
    local expect_file="$1"
    [ -f "$expect_file" ] || return 1
    grep -qE '^(CONTAINS |NOT_CONTAINS |STDOUT_CONTAINS:)' "$expect_file"
}

# Cross-target equivalence check. If a test's LANGUAGES marker lists `js`, the
# JS emitter must produce a program whose output matches the SAME expected.txt
# the Zig target just satisfied — one test, two targets, one source of truth.
#
# DEFAULT-OFF: no LANGUAGES file (or one that doesn't list js) → immediate
# no-op, so the entire existing Zig-only suite is byte-identical. Only runs for
# positive MUST_RUN tests that already PASSED the Zig baseline (SUCCESS, no
# FAILURE). On any JS divergence it flips SUCCESS→FAILURE so the test fails iff
# all listed languages don't agree. First increment scope: positive-run tests
# only; MUST_FAIL / EXPECT-error tests stay Zig-only.
regression_check_js_equivalence() {
    local test_dir="$1"
    local TEST_NAME
    TEST_NAME=$(basename "$test_dir")

    [ -f "$test_dir/LANGUAGES" ] || return 0
    grep -qiw 'js' "$test_dir/LANGUAGES" || return 0
    [ -f "$test_dir/SUCCESS" ] && [ ! -f "$test_dir/FAILURE" ] || return 0
    [ -f "$test_dir/MUST_RUN" ] && [ -f "$test_dir/expected.txt" ] || return 0

    local flags=""
    [ -f "$test_dir/COMPILER_FLAGS" ] && flags=$(tr '\n' ' ' < "$test_dir/COMPILER_FLAGS")

    # Durable per-target record. The collapse into SUCCESS/FAILURE below is for
    # suite accounting; TARGETS.json is the granular truth the website reads to
    # show each target side by side. We are the ONLY place that knows the JS
    # result, so we own this record. zig is known-success here (guarded above).
    # Built with node (already a dependency on this path) for correct JSON
    # escaping of arbitrary program output. Written in every exit branch.
    _write_targets() {
        TGT_DIR="$test_dir" TGT_JS_STATUS="$1" TGT_JS_REASON="$2" node -e '
            const fs = require("fs");
            const d = process.env.TGT_DIR;
            const rd = (f) => { try { return fs.readFileSync(d + "/" + f, "utf8"); } catch { return null; } };
            const out = {
                expected: rd("expected.txt"),
                targets: [
                    { lang: "zig", label: "Zig", status: "success", actual: rd("actual.txt") },
                    { lang: "js", label: "JavaScript", status: process.env.TGT_JS_STATUS,
                      reason: process.env.TGT_JS_REASON || null, actual: rd("actual.js.txt") }
                ]
            };
            fs.writeFileSync(d + "/TARGETS.json", JSON.stringify(out, null, 2));
        ' 2>/dev/null
    }

    _js_equiv_fail() {
        rm -f "$test_dir/SUCCESS"
        echo "$1" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME($1)"
        [ "${PASSED_TESTS:-0}" -gt 0 ] && PASSED_TESTS=$((PASSED_TESTS - 1))
        echo -e "${RED}  ✗ JS equivalence: $2${NC}"
        _write_targets "failure" "$1"
    }

    # Compile to JS via the full-pipeline invocation (no -o): koruc drives the
    # metacircular backend itself and drops output_emitted.js into the input's
    # dir (= test_dir). (-o would stop after Stage A, like the Zig path, which
    # then needs a manual build — unnecessary here since JS skips Stage D.) The
    # backend can die via signal on an unsupported construct, so don't trust the
    # exit code alone — also require the emitted file to exist and be non-empty.
    if ! ./zig-out/bin/koruc "$(test_entry "$test_dir")" --lang=js $flags \
            >"$test_dir/compile_js.err" 2>&1; then
        _js_equiv_fail "js-compile" "koruc --lang=js failed (see compile_js.err)"
        return 0
    fi
    local js_out="$test_dir/output_emitted.js"
    if [ ! -s "$js_out" ]; then
        _js_equiv_fail "js-noemit" "no output_emitted.js produced"
        return 0
    fi

    # Run under node, compare to the SAME expected.txt (trimmed, as the Zig path).
    # Mirror the Zig path's optional ARGS passthrough so CLI-style dual-target
    # tests feed the same argv to both runtimes. (node prepends node + script to
    # process.argv, so a $std/args |js impl reads from process.argv[1..].)
    local js_actual="$test_dir/actual.js.txt"
    local -a RUN_ARGS=()
    if [ -f "$test_dir/ARGS" ]; then
        while IFS= read -r _arg || [ -n "$_arg" ]; do
            RUN_ARGS+=("$_arg")
        done < "$test_dir/ARGS"
    fi
    timeout "${REGRESSION_TEST_TIMEOUT:-30}" node "$js_out" "${RUN_ARGS[@]}" >"$js_actual" 2>&1
    local node_exit=$?
    if [ "$node_exit" -ne 0 ]; then
        _js_equiv_fail "js-runtime" "node exited $node_exit (see actual.js.txt)"
        return 0
    fi
    local exp act
    exp=$(sed 's/[[:space:]]*$//' "$test_dir/expected.txt")
    act=$(sed 's/[[:space:]]*$//' "$js_actual")
    if [ "$exp" != "$act" ]; then
        _js_equiv_fail "js-mismatch" "JS output != expected.txt"
        diff -u "$test_dir/expected.txt" "$js_actual" 2>/dev/null | head -15 | sed 's/^/    /'
        return 0
    fi
    _write_targets "success" ""
    echo -e "${GREEN}  ✓ JS equivalence (node output matches expected.txt)${NC}"
}

regression_run_one_test() {
    local test_dir="$1"
    local TEST_NAME
    TEST_NAME=$(basename "$test_dir")

    regression_cleanup_test_artifacts() {
        # Only clean up artifacts for successful tests.
        # Failed tests keep artifacts to help with debugging.
        if [ "$KEEP_ARTIFACTS" = true ]; then
            return 0
        fi
        if [ -f "$test_dir/SUCCESS" ] && [ ! -f "$test_dir/FAILURE" ]; then
            rm -f "$test_dir/backend" \
                  "$test_dir/output"

            rm -rf "$test_dir/zig-out" \
                   "$test_dir/.zig-cache"
        fi
    }
    trap regression_cleanup_test_artifacts RETURN

# CRITICAL: Reset compilation status variables for each test
    # Without this, variables leak from previous test causing false passes!
    COMPILE_KZ_SUCCESS=false
    COMPILE_ZIG_SUCCESS=false
    RUN_SUCCESS=false

    # Print category header when entering a new category directory
    PARENT_DIR=$(basename "$(dirname "$test_dir")")
    SKIP_CATEGORY=false
    BENCHMARK_CATEGORY=false
    BENCHMARK_REASON=""
    TODO_CATEGORY=false
    TODO_REASON=""
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

        # Check for category-level BENCHMARK file
        if [ -f "$CATEGORY_DIR/BENCHMARK" ]; then
            BENCHMARK_CATEGORY=true
            BENCHMARK_REASON=$(head -1 "$CATEGORY_DIR/BENCHMARK" 2>/dev/null || echo "No description")
            echo -e "${CYAN}📊 Category benchmark: $BENCHMARK_REASON${NC}"
            echo ""
        fi

        # Check for category-level TODO file
        if [ -f "$CATEGORY_DIR/TODO" ]; then
            TODO_CATEGORY=true
            TODO_REASON=$(head -1 "$CATEGORY_DIR/TODO" 2>/dev/null || echo "No description provided")
            echo -e "${YELLOW}📝 Category TODO: $TODO_REASON${NC}"
            echo ""
        fi
    elif [ "$PARENT_DIR" != "regression" ]; then
        # Still in same category, check if category was marked to skip
        CATEGORY_DIR="$(dirname "$test_dir")"
        if [ -f "$CATEGORY_DIR/SKIP" ]; then
            SKIP_CATEGORY=true
        fi
        if [ -f "$CATEGORY_DIR/BENCHMARK" ]; then
            BENCHMARK_CATEGORY=true
            BENCHMARK_REASON=$(head -1 "$CATEGORY_DIR/BENCHMARK" 2>/dev/null || echo "No description")
        fi
        if [ -f "$CATEGORY_DIR/TODO" ]; then
            TODO_CATEGORY=true
            TODO_REASON=$(head -1 "$CATEGORY_DIR/TODO" 2>/dev/null || echo "No description provided")
        fi
    fi

    echo -n "Running $TEST_NAME... "

    # Check for BENCHMARK file - print contents and skip
    if [ -f "$test_dir/BENCHMARK" ]; then
        echo -e "${CYAN}📊 BENCHMARK${NC}"
        BENCHMARK_CONTENT=$(cat "$test_dir/BENCHMARK" 2>/dev/null || echo "No description")
        echo "  $BENCHMARK_CONTENT"
        BENCHMARK_TESTS=$((BENCHMARK_TESTS + 1))
        return 0
    fi

    # Check for category-level BENCHMARK - skip all tests in this category
    if [ "$BENCHMARK_CATEGORY" = true ]; then
        echo -e "${CYAN}📊 BENCHMARK (category)${NC}"
        if [ -n "$BENCHMARK_REASON" ]; then
            echo "  $BENCHMARK_REASON"
        fi
        BENCHMARK_TESTS=$((BENCHMARK_TESTS + 1))
        return 0
    fi

    # Check for TODO file - feature not yet implemented (aspirational test)
    if [ -f "$test_dir/TODO" ]; then
        echo -e "${YELLOW}📝 TODO${NC}"
        # Read first line of TODO file as the feature description
        TODO_FEATURE=$(head -1 "$test_dir/TODO" 2>/dev/null || echo "No description provided")
        echo "  Feature: $TODO_FEATURE"
        TODO_TESTS=$((TODO_TESTS + 1))  # Count separately from skips
        return 0
    fi

    # Check for category-level TODO - mark all tests in this category as TODO
    if [ "$TODO_CATEGORY" = true ]; then
        echo -e "${YELLOW}📝 TODO (category)${NC}"
        if [ -n "$TODO_REASON" ]; then
            echo "  Feature: $TODO_REASON"
        fi
        TODO_TESTS=$((TODO_TESTS + 1))
        return 0
    fi

    # Check for category-level SKIP - skip all tests in this category
    if [ "$SKIP_CATEGORY" = true ]; then
        echo -e "${GREEN}⏭️  SKIPPED (category)${NC}"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        return 0
    fi

    # Check for SKIP file - feature implemented but test skipped for specific reason
    if [ -f "$test_dir/SKIP" ]; then
        echo -e "${GREEN}⏭️  SKIPPED${NC}"
        # Read first line of SKIP file as the reason
        SKIP_REASON=$(head -1 "$test_dir/SKIP" 2>/dev/null || echo "No reason provided")
        echo "  Reason: $SKIP_REASON"
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))  # Count separately, not as pass or fail
        return 0
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
        rm -f "$test_dir/SUCCESS" "$test_dir/FAILURE"
        echo "broken-test" > "$test_dir/FAILURE"
        BROKEN_TESTS=$((BROKEN_TESTS + 1))
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(broken-test)"
        return 0
    fi

    # Check for input file: input.kz (host entry) or input.k (pure-Koru entry).
    if [ ! -f "$test_dir/input.kz" ] && [ ! -f "$test_dir/input.k" ]; then
        echo -e "${RED}❌ Missing input.kz / input.k${NC}"
        rm -f "$test_dir/SUCCESS" "$test_dir/FAILURE"
        echo "no-input" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-input)"
        return 0
    fi
    # ───────────────────────────────────────────────────────────────────────
    # AoC PURITY INVARIANT — 810_AOC_2015 must be PURE KORU, no exceptions.
    # A green AoC test must demonstrate THE LANGUAGE, not Koru orchestrating a
    # host algorithm. So a host entry (.kz/.kjs), a host `~proc`, or an `@import`
    # is the "green-via-Zig" fraud: it fakes a capability the language can't yet
    # do. Such a test is FORCED RED here — the pure-Koru gap stays on the board
    # until the language can express it. Leaf builtins (`@max`, `@divTrunc`, …)
    # inside Koru expressions are fine; pulling in host code is not.
    # (Encoded 2026-06-14 after a day18 .kz green-via-Zig was written, committed,
    #  AND published before being caught. A memory note didn't stop it; this does.)
    case "$test_dir" in
      *810_AOC_2015*)
        AOC_IMPURITY=""
        if [ -f "$test_dir/input.kz" ] || [ -f "$test_dir/input.kjs" ]; then
            AOC_IMPURITY="host entry file (.kz/.kjs) — AoC must be a pure .k"
        elif grep -qE '~proc\b|@(import|cImport|embedFile)\(' "$test_dir/input.k" 2>/dev/null; then
            AOC_IMPURITY="host code (~proc / @import) in source — AoC must be pure Koru"
        fi
        if [ -n "$AOC_IMPURITY" ]; then
            echo -e "${RED}❌ AoC NOT PURE KORU${NC}"
            echo "  $AOC_IMPURITY"
            echo "  AoC proves the LANGUAGE, not Koru-over-Zig. This gap stays RED until pure Koru can do it."
            rm -f "$test_dir/SUCCESS" "$test_dir/FAILURE"
            echo "aoc-not-pure-koru" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(aoc-not-pure-koru)"
            return 0
        fi
        ;;
    esac

    local ENTRY
    ENTRY="$(test_entry "$test_dir")"

    # Check for inconsistent test configuration
    # CRITICAL: Tests that define expected output MUST run to validate it
    # Otherwise they dishonestly pass by claiming "compile only" when they should verify output
    # Note: Tests with EXPECT file use a different validation mechanism (expected errors/output patterns)
    if [ -f "$test_dir/expected.txt" ] && [ -f "$test_dir/expected_patterns.txt" ]; then
        echo -e "${RED}❌ Test has both expected.txt and expected_patterns.txt${NC}"
        echo "  Use exactly one: expected.txt for exact match, expected_patterns.txt for regex per line"
        rm -f "$test_dir/SUCCESS" "$test_dir/FAILURE"
        echo "config-error" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(config-error)"
        return 0
    fi
    if { [ -f "$test_dir/expected.txt" ] || [ -f "$test_dir/expected_patterns.txt" ]; } \
       && [ ! -f "$test_dir/MUST_RUN" ] && [ ! -f "$test_dir/EXPECT" ]; then
        echo -e "${RED}❌ Test has expected output but no MUST_RUN or EXPECT marker${NC}"
        echo "  This test expects output but won't run! Add MUST_RUN/EXPECT or remove the expected file"
        rm -f "$test_dir/SUCCESS" "$test_dir/FAILURE"
        echo "config-error" > "$test_dir/FAILURE"
        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(config-error)"
        return 0
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
          "$test_dir/program.ast.json" \
          "$test_dir/program_ast.zig" \
          "$test_dir/_combined_emit.zig" \
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
        ./zig-out/bin/koruc "$ENTRY" --ast-json $COMPILER_FLAGS > "$test_dir/actual.json" 2>"$test_dir/ast.err"
        AST_GEN_EXIT=$?

        # Check if AST JSON was actually generated
        if [ ! -s "$test_dir/actual.json" ]; then
            echo -e "${RED}❌ Failed to generate AST JSON (no output)${NC}"
            if [ -s "$test_dir/ast.err" ]; then
                head -5 "$test_dir/ast.err"
            fi
            echo "ast-gen-empty" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(ast-gen-empty)"
            return 0
        fi

        # Compare against expected.json
        if [ ! -f "$test_dir/expected.json" ]; then
            echo -e "${RED}❌ PARSER_TEST requires expected.json${NC}"
            echo "no-expected" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-expected)"
            return 0
        fi

        # TODO: Use proper JSON comparison (for now, use diff)
        # In future: parse both JSONs and do structural comparison
        if diff -q "$test_dir/expected.json" "$test_dir/actual.json" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ PASS (AST validated)${NC}"
            mark_test_passed "$test_dir"
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
        return 0
    fi

    # TWO-PASS COMPILATION
    # Pass 1: Frontend - Parse .kz -> backend.zig (serialized AST + code generator)
    if ./zig-out/bin/koruc "$ENTRY" -o "$test_dir/backend.zig" $COMPILER_FLAGS 2>"$test_dir/compile_kz.err"; then
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
                # Otherwise, check expected.txt for exact error output match
                if [ ! -f "$test_dir/PARSER_TEST" ]; then
                    # Check for expected.txt - if present, verify exact error output
                    if [ -f "$test_dir/expected.txt" ]; then
                        # Compare outputs after trimming trailing whitespace
                        EXPECTED_TRIMMED=$(sed 's/[[:space:]]*$//' "$test_dir/expected.txt")
                        ACTUAL_TRIMMED=$(sed 's/[[:space:]]*$//' "$test_dir/compile_kz.err")
                        if [ "$EXPECTED_TRIMMED" = "$ACTUAL_TRIMMED" ]; then
                            if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                                echo -e "${RED}❌ Expected frontend error but memory leak detected ($LEAK_PHASE)${NC}"
                                echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            else
                                echo -e "${GREEN}✅ PASS (error output matches expected.txt)${NC}"
                                mark_test_passed "$test_dir"
                                PASSED_TESTS=$((PASSED_TESTS + 1))
                                if [ "$HAS_MEMORY_LEAK" = true ]; then
                                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                                fi
                            fi
                        else
                            echo -e "${RED}❌ Error output mismatch${NC}"
                            echo "  Diff (expected vs actual):"
                            diff -u "$test_dir/expected.txt" "$test_dir/compile_kz.err" | head -20 | sed 's/^/    /'
                            echo "  Full files: $test_dir/expected.txt vs $test_dir/compile_kz.err"
                            echo "error-output" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(error-output)"
                        fi
                        return 0
                    fi
                    # Check for expected_patterns.txt - if present, every regex must match
                    if [ -f "$test_dir/expected_patterns.txt" ]; then
                        if check_expected_patterns "$test_dir/expected_patterns.txt" "$test_dir/compile_kz.err"; then
                            if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                                echo -e "${RED}❌ Expected frontend error but memory leak detected ($LEAK_PHASE)${NC}"
                                echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            else
                                echo -e "${GREEN}✅ PASS (error output matches expected_patterns.txt)${NC}"
                                mark_test_passed "$test_dir"
                                PASSED_TESTS=$((PASSED_TESTS + 1))
                                if [ "$HAS_MEMORY_LEAK" = true ]; then
                                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                                fi
                            fi
                        else
                            echo -e "${RED}❌ Error output patterns did not all match${NC}"
                            echo "  Patterns: $test_dir/expected_patterns.txt"
                            echo "  Actual:   $test_dir/compile_kz.err"
                            echo "error-output" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(error-output)"
                        fi
                        return 0
                    fi
                    # Check for EXPECT assertions (CONTAINS / NOT_CONTAINS) against compile_kz.err
                    if expect_has_assertions "$test_dir/EXPECT"; then
                        if check_expect_assertions "$test_dir/EXPECT" "$test_dir/compile_kz.err"; then
                            if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                                echo -e "${RED}❌ Expected frontend error but memory leak detected ($LEAK_PHASE)${NC}"
                                echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            else
                                echo -e "${GREEN}✅ PASS (EXPECT assertions matched in compile_kz.err)${NC}"
                                mark_test_passed "$test_dir"
                                PASSED_TESTS=$((PASSED_TESTS + 1))
                                if [ "$HAS_MEMORY_LEAK" = true ]; then
                                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                                fi
                            fi
                        else
                            echo -e "${RED}❌ EXPECT assertions did not match compile_kz.err${NC}"
                            echo "  EXPECT: $test_dir/EXPECT"
                            echo "  Actual: $test_dir/compile_kz.err"
                            echo "error-output" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(error-output)"
                        fi
                        return 0
                    fi
                    # Check for expected_error.txt (literal substring pin) — mirror of
                    # the backend path, so the pin mechanism is symmetric across stages.
                    if [ -f "$test_dir/expected_error.txt" ]; then
                        EXPECTED_ERROR=$(cat "$test_dir/expected_error.txt" | tr -d '\n\r')
                        if [ -s "$test_dir/compile_kz.err" ] && grep -qF -- "$EXPECTED_ERROR" "$test_dir/compile_kz.err"; then
                            if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                                echo -e "${RED}❌ Expected frontend error but memory leak detected ($LEAK_PHASE)${NC}"
                                echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            else
                                echo -e "${GREEN}✅ PASS (error output matches expected_error.txt)${NC}"
                                mark_test_passed "$test_dir"
                                PASSED_TESTS=$((PASSED_TESTS + 1))
                                if [ "$HAS_MEMORY_LEAK" = true ]; then
                                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                                fi
                            fi
                        else
                            echo -e "${RED}❌ Error output did not contain expected_error.txt substring${NC}"
                            echo "  Expected substring: $test_dir/expected_error.txt"
                            echo "  Actual:   $test_dir/compile_kz.err"
                            echo "error-output" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(error-output)"
                        fi
                        return 0
                    fi
                    # No pin matched above (expected.txt / expected_patterns.txt /
                    # EXPECT CONTAINS-NOT_CONTAINS / expected_error.txt). The error was
                    # EXPECTED, but nothing pins WHICH error. Policy: a Koru diagnostic
                    # (error[KORU####]) is an error WE own and MUST be pinned; a raw
                    # host/Zig error we don't control may pass on the bare marker.
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ Expected frontend error but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    elif grep -q 'error\[KORU' "$test_dir/compile_kz.err"; then
                        # A Koru diagnostic fired but nothing pins WHICH one. Passing here
                        # would let the test pass on ANY Koru error — even one fired for a
                        # different reason than it was written to catch (false defender).
                        echo -e "${RED}❌ Koru diagnostic not pinned${NC}"
                        echo "  A Koru diagnostic (error[KORU…]) fired, but nothing pins WHICH one."
                        echo "  A bare FRONTEND_COMPILE_ERROR marker is not enough — pin the error WE own. Add one of:"
                        echo "    - expected.txt (exact frontend error output)"
                        echo "    - expected_patterns.txt (regex per line, matched against compile_kz.err)"
                        echo "    - EXPECT with CONTAINS / NOT_CONTAINS assertions (e.g. CONTAINS error[KORU033])"
                        echo "    - expected_error.txt (literal substring of the expected error)"
                        echo "no-error-pin" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-error-pin)"
                    else
                        echo -e "${GREEN}✅ PASS (expected frontend compile error — non-Koru/host error, bare marker OK)${NC}"
                        mark_test_passed "$test_dir"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                        if [ "$HAS_MEMORY_LEAK" = true ]; then
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        fi
                    fi
                    return 0
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
            return 0
        fi
    fi

    # CRITICAL: Check if frontend SUCCESS was unexpected
    # If EXPECT says FRONTEND_COMPILE_ERROR but compile succeeded, this is a BUG
    if [ "$COMPILE_KZ_SUCCESS" = true ] && [ -f "$test_dir/EXPECT" ]; then
        if grep -q "^FRONTEND_COMPILE_ERROR$" "$test_dir/EXPECT"; then
            echo -e "${RED}❌ Expected frontend compile error but compilation SUCCEEDED${NC}"
            echo "  This test expects the compiler to reject the code, but it was accepted."
            echo "  This usually means a compiler feature is not implemented or has a bug."
            echo "expected-error-missing" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(expected-error-missing)"
            return 0
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
    emitter_helpers_module.addImport("annotation_parser", annotation_parser_module);
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
        # Backend-binary cache key (empty unless --backend-cache). Computed from the
        # build inputs now in place; program.ast.json is excluded (runtime input).
        BKEY=""
        if [ "$BACKEND_CACHE_MODE" = "on" ]; then
            BKEY=$(backend_cache_key "$test_dir")
        fi
        # Restore the backend from cache on a hit (placing it at zig-out/bin/backend),
        # else `zig build`. Use shared global cache so koru modules cache across tests.
        if backend_stage_or_build "$test_dir" "$BUILD_FILE" "$BKEY"; then
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
                return 0
            fi

            # Verify backend executable actually exists and is executable
            if [ ! -x "$test_dir/backend" ]; then
                echo -e "${RED}❌ Backend executable missing or not executable${NC}"
                echo "backend-missing" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(backend-missing)"
                return 0
            fi

            # Store the freshly-built binary for sibling tests (no-op on a cache hit).
            backend_cache_store "$test_dir" "$BKEY"

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
                    return 0
                fi
                # The backend should have created output_emitted.zig for debugging
                if [ -f "output_emitted.zig" ]; then
                    mv output_emitted.zig "$test_dir/output_emitted.zig"
                fi

                # Clean up zig build artifacts now that we're done
                rm -rf "$test_dir/zig-out" "$test_dir/temp_build.zig"
            else
                # Backend execution failed - check if this was expected
                BACKEND_ERROR_EXPECTED=false

                # Check for MUST_FAIL marker - negative tests that must fail to pass.
                # The error reason MUST be pinned by one of: expected_patterns.txt,
                # EXPECT with CONTAINS/NOT_CONTAINS assertions, expected_error.txt, or
                # EXPECT=BACKEND_COMPILE_ERROR. Without a pin, a segfault or any
                # unrelated failure would count as "expected" and mask real bugs.
                if [ -f "$test_dir/MUST_FAIL" ]; then
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ Expected failure (MUST_FAIL) but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        BACKEND_ERROR_EXPECTED=true
                    elif [ -f "$test_dir/expected_patterns.txt" ]; then
                        if check_expected_patterns "$test_dir/expected_patterns.txt" "$test_dir/backend.err"; then
                            echo -e "${GREEN}✅ PASS (MUST_FAIL + error matches expected_patterns.txt)${NC}"
                            mark_test_passed "$test_dir"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        else
                            echo -e "${RED}❌ MUST_FAIL failed at backend, but error did not match expected_patterns.txt${NC}"
                            echo "  Patterns: $test_dir/expected_patterns.txt"
                            echo "  Actual:   $test_dir/backend.err"
                            echo "wrong-error" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(wrong-error)"
                        fi
                        BACKEND_ERROR_EXPECTED=true
                    elif [ -f "$test_dir/EXPECT" ] && expect_has_assertions "$test_dir/EXPECT"; then
                        check_expect_assertions "$test_dir/EXPECT" "$test_dir/backend.err"
                        case $? in
                            0)
                                echo -e "${GREEN}✅ PASS (MUST_FAIL + EXPECT assertions matched)${NC}"
                                mark_test_passed "$test_dir"
                                PASSED_TESTS=$((PASSED_TESTS + 1))
                                if [ "$HAS_MEMORY_LEAK" = true ]; then
                                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                                fi
                                BACKEND_ERROR_EXPECTED=true
                                ;;
                            1)
                                echo -e "${RED}❌ MUST_FAIL failed at backend, but EXPECT assertions did not match${NC}"
                                echo "  EXPECT:  $test_dir/EXPECT"
                                echo "  Actual:  $test_dir/backend.err"
                                echo "wrong-error" > "$test_dir/FAILURE"
                                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(wrong-error)"
                                BACKEND_ERROR_EXPECTED=true
                                ;;
                            # 2 can't happen here — guarded by expect_has_assertions.
                        esac
                    elif [ -f "$test_dir/post.sh" ]; then
                        # Custom validation for negative tests. Runs in test dir;
                        # exit 0 = pass, non-zero = fail. Use when the diagnostic
                        # shape is too rich for a regex pin — multiple required
                        # substrings, absence-checks, semantic assertions.
                        if (cd "$test_dir" && PATH="$SCRIPT_DIR/zig-out/bin:$PATH" bash post.sh) > "$test_dir/post.log" 2>&1; then
                            echo -e "${GREEN}✅ PASS (MUST_FAIL + post.sh validated)${NC}"
                            mark_test_passed "$test_dir"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        else
                            echo -e "${RED}❌ MUST_FAIL post.sh validation failed${NC}"
                            echo "  See $test_dir/post.log for details"
                            echo "post-validation" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(post-validation)"
                        fi
                        BACKEND_ERROR_EXPECTED=true
                    fi
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
                            mark_test_passed "$test_dir"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        fi
                        BACKEND_ERROR_EXPECTED=true
                    fi
                fi

                # Check for EXPECT file with BACKEND_COMPILE_ERROR. Policy: the bare
                # marker is sufficient ONLY for a raw host/Zig error we don't own. If a
                # Koru diagnostic (error[KORU####]) fired, it MUST be pinned — leave
                # BACKEND_ERROR_EXPECTED=false so it falls through to the no-error-pin guard.
                if [ "$BACKEND_ERROR_EXPECTED" = false ] && [ -f "$test_dir/EXPECT" ]; then
                    if grep -q "^BACKEND_COMPILE_ERROR$" "$test_dir/EXPECT" && ! grep -q 'error\[KORU' "$test_dir/backend.err"; then
                        if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                            echo -e "${RED}❌ Expected backend compile error but memory leak detected ($LEAK_PHASE)${NC}"
                            echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        else
                            echo -e "${GREEN}✅ PASS (expected backend compile error — non-Koru/host error, bare marker OK)${NC}"
                            mark_test_passed "$test_dir"
                            PASSED_TESTS=$((PASSED_TESTS + 1))
                            if [ "$HAS_MEMORY_LEAK" = true ]; then
                                LEAKED_TESTS=$((LEAKED_TESTS + 1))
                            fi
                        fi
                        BACKEND_ERROR_EXPECTED=true
                    fi
                fi

                # If error wasn't expected, mark as failure. We reach here with a backend
                # error and no matched pin. A test that DECLARED it expects a backend error
                # — via MUST_FAIL, or a bare BACKEND_COMPILE_ERROR marker that did NOT pass
                # because a Koru diagnostic fired — must pin WHICH error.
                if [ "$BACKEND_ERROR_EXPECTED" = false ] && { [ -f "$test_dir/MUST_FAIL" ] || { [ -f "$test_dir/EXPECT" ] && grep -q "^BACKEND_COMPILE_ERROR$" "$test_dir/EXPECT"; }; }; then
                    echo -e "${RED}❌ Backend error has no pin${NC}"
                    echo "  Backend failed, but nothing pins WHICH error to expect."
                    echo "  A bare BACKEND_COMPILE_ERROR marker only covers raw host/Zig"
                    echo "  errors we don't control — a Koru diagnostic (error[KORU…]) must"
                    echo "  be pinned. Add one of:"
                    echo "    - expected_patterns.txt (regex per line, matched against backend.err)"
                    echo "    - EXPECT with CONTAINS / NOT_CONTAINS assertions (e.g. CONTAINS error[KORU025])"
                    echo "    - expected_error.txt (literal substring of the expected error)"
                    echo "no-error-pin" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(no-error-pin)"
                elif [ "$BACKEND_ERROR_EXPECTED" = false ]; then
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
                            # Normal mode: KORU error codes first, then coordination summary
                            KORU_ERRORS=$(grep "error\[KORU[0-9]*\]:" "$test_dir/backend.err" | head -3)
                            SUMMARY=$(grep "Compiler coordination error:" "$test_dir/backend.err" | head -1)
                            ZIG_ERRORS=$(grep "output_emitted\.zig.*error:\|error:.*output_emitted\.zig" "$test_dir/backend.err" | head -3)
                            if [ -n "$KORU_ERRORS" ]; then
                                echo "$KORU_ERRORS" | sed 's/^/  ❌ /'
                            fi
                            if [ -n "$SUMMARY" ]; then
                                echo "  $SUMMARY"
                            elif [ -n "$ZIG_ERRORS" ]; then
                                echo "$ZIG_ERRORS" | sed 's/^/  /'
                            elif [ -z "$KORU_ERRORS" ]; then
                                echo "  Error: $(head -1 "$test_dir/backend.err")"
                            fi
                            echo "  (Use --verbose or: cat $test_dir/backend.err)"
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
                rm -rf "$test_dir/zig-out" "$test_dir/temp_build.zig"
                return 0
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
                    # Normal mode: prefer output_emitted.zig errors (user code) over backend machinery
                    EMITTED_ERRORS=$(grep "output_emitted\.zig.*error:" "$test_dir/compile_backend.err" | head -4)
                    if [ -n "$EMITTED_ERRORS" ]; then
                        echo "$EMITTED_ERRORS" | sed 's/^/  /'
                        echo "  (Use --verbose or: cat $test_dir/compile_backend.err)"
                    else
                        # Fall back to any error lines referencing known files
                        ERROR_LINES=$(grep "error:" "$test_dir/compile_backend.err" | grep -v "^--$\|build command failed" | head -4)
                        if [ -n "$ERROR_LINES" ]; then
                            echo "$ERROR_LINES" | sed 's/^/  /'
                        else
                            head -3 "$test_dir/compile_backend.err" | sed 's/^/  /'
                        fi
                        echo "  (Use --verbose or: cat $test_dir/compile_backend.err)"
                    fi
                fi
            fi
            echo "backend" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(backend)"
            # Clean up zig build artifacts
            rm -rf "$test_dir/zig-out" "$test_dir/temp_build.zig"
            return 0
        fi
    fi
    
    # Step 3: Run executable and check output (only if executable exists)
    if [ -f "$test_dir/output" ] && [ -f "$test_dir/MUST_RUN" ]; then
        # Run the program under a timeout so a runaway binary can't wedge the harness.
        # Override the default with REGRESSION_TEST_TIMEOUT (seconds).
        TEST_TIMEOUT="${REGRESSION_TEST_TIMEOUT:-30}"
        # Watchdog self-test: an EXPECT_TIMEOUT test is SUPPOSED to hang at runtime
        # (it pins the timeout safety net). Cap the binary timeout low so the
        # self-test resolves in seconds rather than the default 30.
        [ -f "$test_dir/EXPECT_TIMEOUT" ] && TEST_TIMEOUT="${SELFTEST_TIMEOUT:-5}"
        # Optional ARGS file: one argv entry per line, passed to the binary as
        # argv (and to node on the JS path). Lets CLI-style tests feed argv so
        # the same .kz can be exercised with real command-line arguments.
        local -a RUN_ARGS=()
        if [ -f "$test_dir/ARGS" ]; then
            while IFS= read -r _arg || [ -n "$_arg" ]; do
                RUN_ARGS+=("$_arg")
            done < "$test_dir/ARGS"
        fi
        # Optional STDIN file: piped to the binary (else /dev/null) — the
        # interactive/pipe vertical, parallel to ARGS.
        if [ -f "$test_dir/STDIN" ]; then
            timeout "$TEST_TIMEOUT" "$test_dir/output" "${RUN_ARGS[@]}" < "$test_dir/STDIN" > "$test_dir/actual.txt" 2>&1
        else
            timeout "$TEST_TIMEOUT" "$test_dir/output" "${RUN_ARGS[@]}" < /dev/null > "$test_dir/actual.txt" 2>&1
        fi
        RUN_EXIT=$?
        if [ $RUN_EXIT -eq 0 ]; then
            if [ -f "$test_dir/EXPECT_TIMEOUT" ]; then
                # The binary was SUPPOSED to hang but finished — a real infinite
                # loop would NOT have been caught. That broken safety net is the fail.
                echo -e "${RED}❌ EXPECT_TIMEOUT but the binary finished in <${TEST_TIMEOUT}s — the timeout net would not catch a hang${NC}"
                echo "expect-timeout-but-finished" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(expect-timeout-but-finished)"
                return 0
            fi
            RUN_SUCCESS=true
        elif [ $RUN_EXIT -eq 124 ] || [ $RUN_EXIT -eq 137 ]; then
            if [ -f "$test_dir/EXPECT_TIMEOUT" ]; then
                # The runaway binary was caught by the timeout — exactly what the
                # watchdog self-test pins. Pass.
                echo -e "${GREEN}✅ Watchdog caught the expected hang after ${TEST_TIMEOUT}s${NC}"
                rm -f "$test_dir/FAILURE"
                mark_test_passed "$test_dir"
                PASSED_TESTS=$((PASSED_TESTS + 1))
                return 0
            fi
            echo -e "${RED}❌ Test binary timed out after ${TEST_TIMEOUT}s${NC}"
            echo "timeout-${TEST_TIMEOUT}s" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(timeout)"
            return 0
        else
            RUN_SUCCESS=false
        fi

        # PRODUCED-PROGRAM LEAK CHECK: the emitted main() deinits the
        # koru_allocator GPA and exits 1 with a marker line if anything
        # leaked (traces land in actual.txt via 2>&1). A leak is its own
        # failure category — it outranks the output diff.
        if grep -q "KORU LEAK CHECK FAILED" "$test_dir/actual.txt" 2>/dev/null; then
            echo -e "${RED}❌ Produced program leaked memory (see actual.txt for GPA trace)${NC}"
            echo "leak-output" > "$test_dir/FAILURE"
            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-output)"
            LEAKED_TESTS=$((LEAKED_TESTS + 1))
            return 0
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
                    if (cd "$test_dir" && PATH="$SCRIPT_DIR/zig-out/bin:$PATH" bash post.sh) > "$test_dir/post.log" 2>&1; then
                        if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                            echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                            echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        else
                            echo -e "${GREEN}✅ PASS (post-validated)${NC}"
                            mark_test_passed "$test_dir"
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
                        mark_test_passed "$test_dir"
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
        elif [ -f "$test_dir/expected_patterns.txt" ]; then
            if check_expected_patterns "$test_dir/expected_patterns.txt" "$test_dir/actual.txt"; then
                if [ -f "$test_dir/post.sh" ]; then
                    if (cd "$test_dir" && PATH="$SCRIPT_DIR/zig-out/bin:$PATH" bash post.sh) > "$test_dir/post.log" 2>&1; then
                        if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                            echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                            echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                            FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        else
                            echo -e "${GREEN}✅ PASS (patterns + post-validated)${NC}"
                            mark_test_passed "$test_dir"
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
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    else
                        echo -e "${GREEN}✅ PASS (patterns matched)${NC}"
                        mark_test_passed "$test_dir"
                        PASSED_TESTS=$((PASSED_TESTS + 1))
                        if [ "$HAS_MEMORY_LEAK" = true ]; then
                            LEAKED_TESTS=$((LEAKED_TESTS + 1))
                        fi
                    fi
                fi
            else
                echo -e "${RED}❌ Output patterns did not all match${NC}"
                echo "  Patterns: $test_dir/expected_patterns.txt"
                echo "  Actual:   $test_dir/actual.txt"
                echo "output" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(output)"
            fi
        elif [ -f "$test_dir/EXPECT" ] && expect_has_assertions "$test_dir/EXPECT"; then
            if check_expect_assertions "$test_dir/EXPECT" "$test_dir/actual.txt"; then
                if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                    echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                    echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                else
                    echo -e "${GREEN}✅ PASS (EXPECT assertions matched)${NC}"
                    mark_test_passed "$test_dir"
                    PASSED_TESTS=$((PASSED_TESTS + 1))
                    if [ "$HAS_MEMORY_LEAK" = true ]; then
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    fi
                fi
            else
                echo -e "${RED}❌ EXPECT assertions did not match actual output${NC}"
                echo "  EXPECT: $test_dir/EXPECT"
                echo "  Actual: $test_dir/actual.txt"
                echo "output" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(output)"
            fi
        elif [ -f "$test_dir/post.sh" ]; then
            # Run custom post-validation script
            # The script has access to: test_dir, actual.txt, output_emitted.zig, backend.zig, output (executable)
            # Script should exit 0 for pass, non-zero for fail
            if (cd "$test_dir" && PATH="$SCRIPT_DIR/zig-out/bin:$PATH" bash post.sh) > "$test_dir/post.log" 2>&1; then
                if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                    echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                    echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                else
                    echo -e "${GREEN}✅ PASS (post-validated)${NC}"
                    mark_test_passed "$test_dir"
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
            elif [ -f "$test_dir/MUST_FAIL" ]; then
                echo -e "${RED}❌ MUST_FAIL test passed unexpectedly — expected failure didn't fire${NC}"
                echo "must-fail-passed" > "$test_dir/FAILURE"
                FAILED_TESTS="$FAILED_TESTS $TEST_NAME(must-fail-passed)"
            else
                echo -e "${GREEN}✅ PASS (ran successfully)${NC}"
                mark_test_passed "$test_dir"
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
                if (cd "$test_dir" && PATH="$SCRIPT_DIR/zig-out/bin:$PATH" bash post.sh) > "$test_dir/post.log" 2>&1; then
                    if [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                        echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                        echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                        LEAKED_TESTS=$((LEAKED_TESTS + 1))
                    elif [ -f "$test_dir/MUST_FAIL" ]; then
                        echo -e "${RED}❌ MUST_FAIL test passed unexpectedly — expected failure didn't fire${NC}"
                        echo "must-fail-passed" > "$test_dir/FAILURE"
                        FAILED_TESTS="$FAILED_TESTS $TEST_NAME(must-fail-passed)"
                    else
                        echo -e "${GREEN}✅ PASS (post-validated)${NC}"
                        mark_test_passed "$test_dir"
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
                # No post.sh - check if this test is genuinely compile-only
                # or if it's a "lazy" test that should run but lacks MUST_RUN.
                # Compile-only is only acceptable for parser/syntax tests.
                IS_LAZY_COMPILE_ONLY=false
                if [ ! -f "$test_dir/PARSER_TEST" ] && [ ! -f "$test_dir/EXPECT" ] && [ ! -f "$test_dir/COMPILE_ONLY" ]; then
                    if [ -f "$test_dir/input.kz" ]; then
                        # Scan for runtime indicators
                        if grep -qE 'std\.debug\.print|std\.io:|std\.fs\.|~std\.runtime:|~std\.interpreter:|~\[comptime|~compiler:' "$test_dir/input.kz"; then
                            IS_LAZY_COMPILE_ONLY=true
                            LAZY_REASON="contains runtime I/O or runtime/interpreter invocation"
                        elif grep -qE '~\s*proc\s+\w+' "$test_dir/input.kz" && grep -qE '(return\s|return\s*\.\{)' "$test_dir/input.kz"; then
                            # Has a proc with a return statement - likely produces a value that should be verified
                            IS_LAZY_COMPILE_ONLY=true
                            LAZY_REASON="contains proc with return value"
                        fi
                    fi
                fi

                if [ "$IS_LAZY_COMPILE_ONLY" = true ]; then
                    echo -e "${RED}❌ FAIL (compile-only-lazy)${NC}"
                    echo "  This test $LAZY_REASON but has no MUST_RUN marker."
                    echo "  It compiled successfully but was never executed."
                    echo "  Add MUST_RUN if the test needs runtime validation,"
                    echo "  or add COMPILE_ONLY if compile-time validation is sufficient."
                    echo "compile-only-lazy" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(compile-only-lazy)"
                elif [ "$CHECK_LEAKS" = true ] && [ "$HAS_MEMORY_LEAK" = true ]; then
                    echo -e "${RED}❌ PASS but memory leak detected ($LEAK_PHASE)${NC}"
                    echo "leak-$LEAK_PHASE" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(leak-$LEAK_PHASE)"
                    LEAKED_TESTS=$((LEAKED_TESTS + 1))
                elif [ -f "$test_dir/MUST_FAIL" ]; then
                    echo -e "${RED}❌ MUST_FAIL test passed unexpectedly — expected failure didn't fire${NC}"
                    echo "must-fail-passed" > "$test_dir/FAILURE"
                    FAILED_TESTS="$FAILED_TESTS $TEST_NAME(must-fail-passed)"
                else
                    echo -e "${GREEN}✅ PASS (compile only)${NC}"
                    mark_test_passed "$test_dir"
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

    # Cross-target: if this test opted into JS (LANGUAGES lists js) and passed
    # the Zig baseline, require the JS target to agree on the same expected.txt.
    regression_check_js_equivalence "$test_dir"

    return 0
}

# ── Per-test watchdog (shared by run_single_test.sh and run_regression.sh serial)
# The harness otherwise has NO timeout: a koru test that infinite-loops at runtime
# (a non-terminating `#loop`), or a koruc/zig build that blows up on pathological
# generated code, would spin FOREVER — block a worker and, once orphaned, become
# an un-killable zombie that accumulates across runs (observed 2026-06-25).
#
# regression_run_one_test runs in its OWN process group (job control, `set -m`);
# on expiry we SIGKILL the whole group (`kill -- -PGID`), tearing down the entire
# koruc→zig→backend tree. Killing only the parent — the default — is exactly why
# orphans survived. A fired watchdog is recorded as a loud FAILURE, never a silent
# stall. Default 300s ≫ the slowest legit test (no false positives); tune via
# KORU_TEST_TIMEOUT.
: "${KORU_TEST_TIMEOUT:=300}"

run_one_test_watched() {
    local tdir="$1"
    local quiet="${2:-false}"
    set -m  # job control → the backgrounded job becomes its own process-group leader
    if [ "$quiet" = "true" ]; then
        regression_run_one_test "$tdir" >/dev/null 2>&1 &
    else
        regression_run_one_test "$tdir" &
    fi
    local job=$!
    ( sleep "$KORU_TEST_TIMEOUT"; kill -KILL -"$job" 2>/dev/null ) &
    local watchdog=$!
    wait "$job" 2>/dev/null
    local rc=$?
    kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
    set +m
    # rc 137 = 128 + SIGKILL(9): the watchdog fired (a koruc/zig-build compile hang —
    # the inner binary run already has its own `timeout`). The killed test wrote no
    # SUCCESS/FAILURE, so classify it as a hang here.
    if [ "$rc" -eq 137 ]; then
        rm -f "$tdir/SUCCESS"
        echo "TIMEOUT after ${KORU_TEST_TIMEOUT}s — possible infinite loop / hang in compile (koruc or zig build)" > "$tdir/FAILURE"
    fi
    return "$rc"
}
