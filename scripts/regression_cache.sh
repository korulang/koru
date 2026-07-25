#!/bin/bash
# Regression test result cache.
#
# A test PASS can be cached by fingerprint over inputs. On the next suite run,
# tests whose inputs all match the stored fingerprint are reported as
# "cached-pass" without actually being run.
#
# Fingerprint inputs:
#   - Compiler snapshot mtime (env KORU_COMPILER_MTIME, set once per suite run).
#   - This test's input.kz mtime.
#   - This test's expected.txt mtime (if present).
#   - This test's EXPECT marker mtime (if present).
#   - Walk-up koru.json mtimes (test dir and regression root).
#   - Each transitively-imported file's mtime (from `koruc --list-imports`).
#
# Cache file lives at $test_dir/.cache-fingerprint. Plain text, one entry per
# line, sorted. Format:
#   compiler:<mtime>
#   input:<mtime>
#   expected:<mtime>
#   EXPECT:<mtime>
#   koru_json:<abs_path>:<mtime>
#   import:<abs_path>:<mtime>

# Portable mtime helper. Returns 0 (epoch) if file doesn't exist.
cache_mtime() {
    if [ -e "$1" ]; then
        date -r "$1" +%s 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Compute "compiler snapshot mtime" — newest mtime across compiler source trees
# and the koruc binary. Caller usually sets KORU_COMPILER_MTIME once per suite
# run; this is the fallback for standalone invocations.
#
# Args: $1 = repo root (e.g. /Users/larsde/src/koru)
cache_compute_compiler_mtime() {
    local repo_root="$1"
    local newest=0
    local f mt
    while IFS= read -r f; do
        mt=$(cache_mtime "$f")
        if [ "$mt" -gt "$newest" ]; then newest=$mt; fi
    done < <(find "$repo_root/src" "$repo_root/koru_std" "$repo_root/build.zig" "$repo_root/zig-out/bin/koruc" -type f 2>/dev/null)
    echo "$newest"
}

# Emit the fingerprint to stdout (sorted, one line per entry).
# Args: $1 = test_dir, $2 = koruc binary path, $3 = compiler_mtime
#
# Returns nonzero if --list-imports fails (test has malformed source etc).
cache_emit_fingerprint() {
    local test_dir="$1"
    local koruc_bin="$2"
    local compiler_mtime="$3"

    {
        echo "compiler:$compiler_mtime"
        echo "input:$(cache_mtime "$test_dir/input.kz")"
        # Fixed-name markers: emit unconditionally with mtime=0 when absent so
        # additions of these files invalidate the cache (stored=0 vs current!=0).
        # If we only emitted when present, adding MUST_ERROR to a previously-cached
        # test would not invalidate — the stored fingerprint just wouldn't mention it.
        echo "expected:$(cache_mtime "$test_dir/expected.txt")"
        echo "EXPECT:$(cache_mtime "$test_dir/EXPECT")"
        echo "expected_patterns:$(cache_mtime "$test_dir/expected_patterns.txt")"
        echo "marker_MUST_COMPILE:$(cache_mtime "$test_dir/MUST_COMPILE")"
        echo "marker_MUST_COMPILE_KZ:$(cache_mtime "$test_dir/MUST_COMPILE_KZ")"
        echo "marker_MUST_COMPILE_ZIG:$(cache_mtime "$test_dir/MUST_COMPILE_ZIG")"
        echo "marker_MUST_ERROR:$(cache_mtime "$test_dir/MUST_ERROR")"
        echo "marker_MUST_RUN:$(cache_mtime "$test_dir/MUST_RUN")"

        # Walk up for koru.json files. Stop at the regression root or filesystem root.
        # Always emit absent ones too (mtime=0), so adding a koru.json invalidates.
        local d
        d=$(cd "$test_dir" && pwd)
        while [ -n "$d" ] && [ "$d" != "/" ]; do
            echo "koru_json:$d/koru.json:$(cache_mtime "$d/koru.json")"
            case "$d" in
                */tests/regression) break ;;
            esac
            d=$(dirname "$d")
        done

        # Transitive imports via --list-imports. The output is a JSON array of paths.
        local imports_json
        if ! imports_json=$("$koruc_bin" --list-imports "$test_dir/input.kz" 2>/dev/null); then
            # If --list-imports fails (e.g. parse error), the cache cannot be
            # written reliably. Emit a marker and bail.
            echo "ERROR:list-imports-failed"
            return 1
        fi
        # Parse `["p1","p2",...]` → one path per line.
        echo "$imports_json" \
            | tr ',' '\n' \
            | sed 's/^\[//; s/\]$//; s/^"//; s/"$//' \
            | while IFS= read -r p; do
                [ -n "$p" ] && echo "import:$p:$(cache_mtime "$p")"
            done
    } | sort
}

# Check whether the cache is fresh for a test.
# Args: $1 = test_dir, $2 = compiler_mtime
# Returns 0 on hit (cache is fresh), 1 on miss (no cache, stale, or invalid).
#
# Does NOT consult SUCCESS/FAILURE markers — the fingerprint is the source of
# truth. If inputs are byte-identical, the outcome is deterministic; whether
# the prior run passed or failed is just data carried on disk in those markers.
# Caller decides how to render a cached pass vs. cached fail.
#
# Does NOT call --list-imports — uses only the stored fingerprint's paths and
# stats them. The premise: if input.kz mtime is unchanged, the import set
# cannot have changed.
cache_check() {
    local test_dir="$1"
    local compiler_mtime="$2"

    local cache_file="$test_dir/.cache-fingerprint"
    [ ! -f "$cache_file" ] && return 1

    local line kind a b
    while IFS= read -r line; do
        # Split on first two colons: kind:rest_or_value, then path:value for 3-field forms.
        kind="${line%%:*}"
        case "$kind" in
            ERROR)
                return 1
                ;;
            compiler)
                a="${line#compiler:}"
                [ "$a" = "$compiler_mtime" ] || return 1
                ;;
            input)
                a="${line#input:}"
                [ "$a" = "$(cache_mtime "$test_dir/input.kz")" ] || return 1
                ;;
            expected)
                a="${line#expected:}"
                [ "$a" = "$(cache_mtime "$test_dir/expected.txt")" ] || return 1
                ;;
            EXPECT)
                a="${line#EXPECT:}"
                [ "$a" = "$(cache_mtime "$test_dir/EXPECT")" ] || return 1
                ;;
            expected_patterns)
                a="${line#expected_patterns:}"
                [ "$a" = "$(cache_mtime "$test_dir/expected_patterns.txt")" ] || return 1
                ;;
            marker_MUST_COMPILE|marker_MUST_COMPILE_KZ|marker_MUST_COMPILE_ZIG|marker_MUST_ERROR|marker_MUST_RUN)
                local marker_name="${kind#marker_}"
                a="${line#${kind}:}"
                [ "$a" = "$(cache_mtime "$test_dir/$marker_name")" ] || return 1
                ;;
            koru_json|import)
                # Format: <kind>:<abs_path>:<stored_mtime>. Path may contain
                # nothing weird (we control these). Strip kind: prefix, then
                # split path/mtime on the LAST colon.
                local rest="${line#${kind}:}"
                local path="${rest%:*}"
                local stored="${rest##*:}"
                [ "$stored" = "$(cache_mtime "$path")" ] || return 1
                ;;
            *)
                # Unknown line → treat as miss.
                return 1
                ;;
        esac
    done < "$cache_file"
    return 0
}

# Write a fresh fingerprint after a test run completes (pass OR fail).
# Args: $1 = test_dir, $2 = koruc binary, $3 = compiler_mtime
#
# Sanity check: at least one of SUCCESS/FAILURE must exist, meaning the test
# actually completed. If neither marker is present (e.g., the harness crashed
# mid-run), refuse to write — we don't know the outcome.
cache_write() {
    local test_dir="$1"
    local koruc_bin="$2"
    local compiler_mtime="$3"

    if [ ! -f "$test_dir/SUCCESS" ] && [ ! -f "$test_dir/FAILURE" ]; then
        return 1
    fi

    cache_emit_fingerprint "$test_dir" "$koruc_bin" "$compiler_mtime" \
        > "$test_dir/.cache-fingerprint.tmp" \
        && mv "$test_dir/.cache-fingerprint.tmp" "$test_dir/.cache-fingerprint"
}

# Invalidate the cache. Called when a test fails so a passing-cache from a
# previous run doesn't survive.
cache_invalidate() {
    rm -f "$1/.cache-fingerprint"
}
