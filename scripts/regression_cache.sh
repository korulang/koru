#!/bin/bash
# Regression test result cache.
#
# A test PASS can be cached by fingerprint over inputs. On the next suite run,
# tests whose inputs all match the stored fingerprint are reported as
# "cached-pass" without actually being run.
#
# Fingerprint inputs:
#   - Compiler snapshot mtime (env KORU_COMPILER_MTIME, set once per suite run).
#   - This test's entry-file mtime (input.kz, else input.k — see test_entry).
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

# ═══════════════════════════════════════════════════════════════════════════
# Backend-cache keys: the LINKED CLOSURE, not the directory
# ═══════════════════════════════════════════════════════════════════════════
# A build-cache key must be COMPLETE (every file the binary embeds) and MINIMAL
# (nothing else), and the two errors cost opposite things. An omission serves a
# stale backend — see frag-a-backend-cache-keyed-on-mtime-can-serve-poison. An
# inclusion re-mints every cached backend for an edit that cannot change one.
#
# This cache spent its life over-approximating instead: the salt hashed
# src/ + koru_std/ + build.zig, 269 files, while a test's backend links 51 of
# them. So any edit to anything covered re-minted all ~121 backends — including
# src/main.zig (8k lines of CLI the backend never links) and koru_std/*.kz
# (comptime module sources whose effect on a given test is already carried by
# that test's emitted file, which the key hashes by itself). Measured
# 2026-09-17: 5 of the day's 13 compiler commits touched nothing the backend
# links, and each threw the whole cache away — all-or-nothing, per commit.
#
# The closure is derivable, so the approximation is not needed.
#
# Cost discipline: this runs once per test, so the walk spawns nothing per file.
# It was written with a per-file `shasum` first and measured 3.2s per key —
# `shasum` is a Perl script here, ~87ms of startup per call, against 3ms for one
# `sha256sum` over ten files. What remains is one awk for the build graph, zero
# subprocesses per walked file, and one bulk hash for the whole closure.
_KORU_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_KORU_REPO_ROOT=$(cd "$_KORU_SCRIPT_DIR/.." && pwd)

# The files that determine a test's backend binary — its LINKED CLOSURE,
# computed by scripts/backend_closure.js, which owns the resolution rules and the
# Zig lexing (see its header: the walk needs string/char/comment state, and the
# bash-and-awk version of this measured 5.5s per test against ~60ms there).
#
# Prints "<relative path> <sha256>" per line, sorted, for every linked file
# EXCEPT the test's own generated inputs — the caller hashes those under its own
# rules (the emitted handlers are comment-stripped, so the emitter's absolute
# path markers cannot make identical sources differ per worktree). Paths are
# relative to the repo root so that two checkouts holding the same compiler
# content still key identically.
#
# Returns nonzero, printing nothing, when the closure cannot be proven — an
# unresolvable import, an `@import` whose argument is not a literal string — or
# when node is missing. A closure that cannot be proven must never key an entry,
# so the caller keys nothing and the test rebuilds.
#
# Args: $1 = test dir, $2 = build file
backend_cache_inputs() {
    local td="$1" bf="$2"
    [ -f "$bf" ] || return 1

    # Reuse a closure already computed for this exact build file. Sound because a
    # suite run FREEZES the compiler sources — editing src/ while a suite is live
    # already makes every test red with errors quoting the edit, which is why the
    # harness forbids it — and because reuse is validated by comparing the build
    # file byte for byte. A standalone run carries its own pid in the path, so it
    # always recomputes.
    local reuse="${KORU_BACKEND_CLOSURE:-}"
    if [ -n "$reuse" ] && [ -s "$reuse" ] && cmp -s "$bf" "$reuse.bf" 2>/dev/null; then
        cat "$reuse"
        return 0
    fi

    if ! command -v node >/dev/null 2>&1; then
        if [ "${_KORU_NODE_WARNED:-false}" != true ]; then
            _KORU_NODE_WARNED=true
            echo "⚠️  node not found — backend-binary cache disabled (the backend's closure cannot be computed)" >&2
        fi
        return 1
    fi

    local out
    out=$(node "$_KORU_SCRIPT_DIR/backend_closure.js" "$bf" 2>&1) || {
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return 1
    }
    [ -n "$out" ] || return 1

    if [ -n "$reuse" ]; then
        printf '%s\n' "$out" > "$reuse.tmp.$$" && mv -f "$reuse.tmp.$$" "$reuse"
        cp -f "$bf" "$reuse.bf" 2>/dev/null || true
    fi
    printf '%s\n' "$out"
}

# The backend-binary cache key for one test:
#
#   sha256( the test's three generated inputs
#           + path:content of every file in the LINKED CLOSURE )
#
# Comment-only lines are dropped from the emitted handlers — measured 2026-09-10:
# across the corpus this merged 216 keys into 210 — because the emitter stamps
# `// >>> PROC: name [file:line]` markers (visitor_emitter.zig) carrying absolute
# checkout paths, which would otherwise make identical sources hash differently
# per worktree. Only comment-only lines are dropped; trailing comments on code
# lines are kept, so `//` inside a string literal can never collide.
#
# There is no salt any more, and none is wanted: the closure IS the salt, and it
# is computed per test from the build file the test already carries. A file that
# cannot change the binary cannot change the key.
#
# Args: $1 = test dir, $2 = build file (default $1/build_backend.zig)
# Prints the key, or nothing when the closure cannot be proven.
backend_cache_key() {
    local td="$1" bf="${2:-build_backend.zig}"
    # The staging site passes a bare name (`build_backend.zig`) — that is what
    # `zig build --build-file` takes after its own `cd "$td"` — while a standalone
    # caller may pass an absolute path. A bare name resolves against the TEST DIR,
    # never the caller's CWD: a stray `build_backend.zig` at the repo root would
    # otherwise key one test's backend from another build file's graph.
    case "$bf" in
        /*) ;;
        *) [ -f "$td/$bf" ] && bf="$td/$bf" ;;
    esac
    local inputs f
    inputs=$(backend_cache_inputs "$td" "$bf") || return 0
    [ -n "$inputs" ] || return 0
    {
        cat "$td/backend.zig" "$bf" 2>/dev/null
        grep -v '^[[:space:]]*//' "$td/backend_output_emitted.zig" 2>/dev/null || true
        printf '%s\n' "$inputs"
        # ABI salt: backend binaries are dynamically linked and versioned
        # symbols make a foreign-glibc binary hard-fail on exec — a cache that
        # keys on content alone replays it anyway (measured 2026-10-13: a
        # glibc-2.34 host's mints all refused on a 2.31 image). Same fix shape
        # as the env override: name the ABI the binary was built for.
        printf 'KORU_BACKEND_TARGET=%s\n' "${KORU_BACKEND_TARGET-}"
        ldd --version 2>/dev/null | head -1 || true
    } | _backend_sha256
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
        # Schema 2: the run's *policy* is part of the fingerprint. A pass cached
        # with --ignore-leaks or with cross-target checks on is not a pass under
        # the defaults, and a LANGUAGES edit changes whether the check runs at
        # all. Without these, flipping either flag would serve the old verdict.
        echo "cache_schema:2"
        echo "check_leaks:${CHECK_LEAKS:-true}"
        echo "cross_targets:${KORU_CROSS_TARGETS:-off}"
        echo "languages:$(cache_mtime "$test_dir/LANGUAGES")"
        echo "input:$(cache_mtime "$(test_entry "$test_dir")")"
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
        if ! imports_json=$("$koruc_bin" --list-imports "$(test_entry "$test_dir")" 2>/dev/null); then
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
# stats them. The premise: if the entry's mtime is unchanged, the import set
# cannot have changed.
cache_check() {
    local test_dir="$1"
    local compiler_mtime="$2"

    local cache_file="$test_dir/.cache-fingerprint"
    [ ! -f "$cache_file" ] && return 1

    # A pre-schema-2 fingerprint predates the cross-target and leak flags; it
    # cannot describe this run, so it must miss rather than silently hit.
    grep -qx 'cache_schema:2' "$cache_file" || return 1

    local line kind a b
    while IFS= read -r line; do
        # Split on first two colons: kind:rest_or_value, then path:value for 3-field forms.
        kind="${line%%:*}"
        case "$kind" in
            ERROR)
                return 1
                ;;
            cache_schema)
                a="${line#cache_schema:}"
                [ "$a" = "2" ] || return 1
                ;;
            check_leaks)
                a="${line#check_leaks:}"
                [ "$a" = "${CHECK_LEAKS:-true}" ] || return 1
                ;;
            cross_targets)
                a="${line#cross_targets:}"
                [ "$a" = "${KORU_CROSS_TARGETS:-off}" ] || return 1
                ;;
            languages)
                a="${line#languages:}"
                [ "$a" = "$(cache_mtime "$test_dir/LANGUAGES")" ] || return 1
                ;;
            compiler)
                a="${line#compiler:}"
                [ "$a" = "$compiler_mtime" ] || return 1
                ;;
            input)
                a="${line#input:}"
                [ "$a" = "$(cache_mtime "$(test_entry "$test_dir")")" ] || return 1
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

# ═══════════════════════════════════════════════════════════════════════════
# Backend-binary cache hygiene
# ═══════════════════════════════════════════════════════════════════════════
# $BACKEND_CACHE_DIR is ONE flat directory shared by every checkout on this
# machine ($TMPDIR is per-user, not per-worktree) and written by TWO producers
# with different naming schemes:
#
#   - this harness — backend_cache_key (regression_lib.sh): sha256 of the
#     backend's build inputs, 64 hex chars.
#   - koruc itself — backendCacheKey (src/main.zig): FNV1a-64 over src/ and
#     koru_std/, printed `{x}` — unpadded, so 14..16 hex chars.
#
# Neither evicted. Measured 2026-09-17: 3382 entries / 33.8 GB, of which 223 of
# koruc's entries were byte-identical to a harness entry (two schemes, one
# binary, stored twice). The only in-tree way it ever shrank was
# run_regression.sh --clean, which rm -rf's the whole cache by hand.
#
# So the prune below is SCHEME-AGNOSTIC on purpose: it must bound koruc's
# entries too, or the leak survives in the half no harness code touches.

# Byte cap on the shared backend cache (env KORU_BACKEND_CACHE_MAX_BYTES).
# Sized for the working set, not for tidiness: a generation is ~1.2 GB (121
# distinct backends x 9.6 MB) and this machine runs ~14 compiler checkouts, each
# legitimately at a different commit and wanting its own. Below ~14 generations
# the checkouts evict each other and the cache stops paying for itself — an
# entry costs 1.2 GB of disk to save ~120 backend builds, so the cap exists to
# stop unbounded growth, not to make the cache small.
: "${KORU_BACKEND_CACHE_MAX_BYTES:=21474836480}"   # 20 GiB

# Never evict an entry touched this recently (env
# KORU_BACKEND_CACHE_LIVE_SECONDS). An entry's mtime is when it was last STORED
# or HIT, and a suite stores its generation at the start of the run — so a
# 30-minute board holds entries that look half an hour stale while it is still
# using them. This window is what makes eviction safe under concurrent suites:
# several boards share the one directory, and no prune can reach a generation
# any of them might still need.
: "${KORU_BACKEND_CACHE_LIVE_SECONDS:=7200}"       # 2 h

backend_human() {
    awk -v b="$1" 'BEGIN{
        if (b >= 1073741824)   printf "%.2f GiB", b/1073741824;
        else if (b >= 1048576) printf "%.1f MiB", b/1048576;
        else if (b >= 1024)    printf "%.1f KiB", b/1024;
        else                   printf "%d B", b;
    }'
}

# "mtime size path", one line per file, least-recently-used first.
# Dotfiles are excluded: staging residue and the closure memo are not entries,
# so they must not be evicted as if they were, nor counted toward the cap.
#
# GNU and BSD stat disagree on BOTH the flag and the format letters, and this
# machine has both (a Nix profile shadows /usr/bin), so the dialect is probed
# rather than assumed — the same shape as _backend_sha256's shasum/sha256sum
# probe. A GNU-shaped stat driven with -f silently mis-parses as filesystem mode
# the moment it is handed several files (`{} +`), so the GNU branch must use -c.
backend_cache_lru() {
    if stat -c '%Y %s %n' / >/dev/null 2>&1; then
        find "$1" -maxdepth 1 -type f ! -name '.*' -exec stat -c '%Y %s %n' {} + 2>/dev/null | sort -n
    else
        find "$1" -maxdepth 1 -type f ! -name '.*' -exec stat -f '%m %z %N' {} + 2>/dev/null | sort -n
    fi
}

# Evict least-recently-used entries until the directory is at or under the cap.
# Args: $1 = cache dir, $2 = cap in bytes (default $KORU_BACKEND_CACHE_MAX_BYTES)
#
# Deleting an entry can only ever cost a rebuild, never a wrong answer, so this
# needs no coordination with a running suite: a concurrent store either writes a
# fresh entry or loses a race and rebuilds. The live window is what keeps it
# from costing a rebuild the machine is not willing to pay mid-board.
backend_cache_prune() {
    local dir="$1" max="${2:-$KORU_BACKEND_CACHE_MAX_BYTES}"
    [ -d "$dir" ] || return 0

    # An interrupted store leaves `.$key.$$.tmp` (both producers stage that way).
    # A live one renames it away within milliseconds, so anything an hour old is
    # crash residue rather than a race in progress.
    find "$dir" -maxdepth 1 -name '.*.tmp' -type f -mmin +60 -delete 2>/dev/null

    local entries total
    entries=$(backend_cache_lru "$dir")
    [ -n "$entries" ] || return 0
    total=$(printf '%s\n' "$entries" | awk '{s += $2} END {print s + 0}')
    [ "$total" -le "$max" ] && return 0

    # The live window is honoured even when it alone exceeds the cap: a board in
    # flight is worth more than a bound on the residue, and the residue is what
    # ages out on the next run instead.
    local cutoff=$(( $(date +%s) - KORU_BACKEND_CACHE_LIVE_SECONDS ))
    local before="$total" removed=0 freed=0 mt sz path
    while IFS=' ' read -r mt sz path; do
        [ "$total" -le "$max" ] && break
        [ -n "$path" ] || continue
        [ "$mt" -ge "$cutoff" ] && break        # LRU order: this and the rest are live
        rm -f "$path" 2>/dev/null || continue
        total=$((total - sz))
        freed=$((freed + sz))
        removed=$((removed + 1))
    done <<< "$entries"

    [ "$removed" -eq 0 ] && return 0
    printf '   cache prune: removed %d entries, freed %s (%s -> %s, cap %s)\n' \
        "$removed" "$(backend_human "$freed")" \
        "$(backend_human "$before")" "$(backend_human "$total")" \
        "$(backend_human "$max")"
}

# Prune once per shell, from the staging path rather than from the entry
# scripts, so every consumer gets it without having to remember — including the
# parallel workers, which only ever source these files.
backend_cache_prune_once() {
    [ "${_BACKEND_CACHE_PRUNED:-false}" = true ] && return 0
    _BACKEND_CACHE_PRUNED=true
    [ "${BACKEND_CACHE_MODE:-off}" = "on" ] || return 0
    [ -n "${BACKEND_CACHE_DIR:-}" ] || return 0
    backend_cache_prune "$BACKEND_CACHE_DIR"
}
