#!/bin/bash
# post.sh - Verify that explicit disconnect and auto-discharge emit identical Zig
#
# The regression runner already compiled input.kz (explicit version) through
# the full two-pass pipeline, producing output_emitted.zig.
#
# This script:
# 1. Saves the explicit version's emitted code
# 2. Compiles input_auto.kz through the same pipeline
# 3. Normalizes both (strips source-location comments that reference filenames)
# 4. Diffs them — any difference means auto-discharge isn't inlining identically

set -e

# --- Sanity check: explicit version's emission must exist ---
if [ ! -f output_emitted.zig ]; then
    echo "FAIL: No output_emitted.zig from explicit version"
    exit 1
fi

cp output_emitted.zig explicit_emitted.zig

# --- Locate tools ---
REPO_ROOT=$(git rev-parse --show-toplevel)
KORUC="$REPO_ROOT/zig-out/bin/koruc"
ZIG_CACHE="${ZIG_GLOBAL_CACHE:-${TMPDIR:-/tmp}/koru-regression-cache}"

if [ ! -x "$KORUC" ]; then
    echo "FAIL: koruc not found at $KORUC"
    exit 1
fi

# --- Pass 1: Compile auto version frontend ---
if ! "$KORUC" "$(pwd)/input_auto.kz" -o "$(pwd)/backend.zig" 2>compile_auto_kz.err; then
    echo "FAIL: Auto version failed frontend compilation"
    cat compile_auto_kz.err
    exit 1
fi

# --- Pass 2: Build and run auto backend ---
# koruc generates build_backend.zig; runner may also have temp_build.zig as fallback
BUILD_FILE="build_backend.zig"
if [ ! -f "$BUILD_FILE" ]; then
    BUILD_FILE="temp_build.zig"
fi

if ! zig build --build-file "$BUILD_FILE" --global-cache-dir "$ZIG_CACHE" 2>compile_auto_backend.err; then
    echo "FAIL: Auto version failed backend compilation"
    cat compile_auto_backend.err
    exit 1
fi

mv zig-out/bin/backend backend

if ! ./backend output >auto_backend.out 2>auto_backend.err; then
    echo "FAIL: Auto version backend execution failed"
    cat auto_backend.err
    exit 1
fi

if [ ! -f output_emitted.zig ]; then
    echo "FAIL: Auto version didn't produce output_emitted.zig"
    exit 1
fi

cp output_emitted.zig auto_emitted.zig

# --- Normalize: strip all comment-only lines and blank lines ---
# Source comments, >>> FLOW/PROC/BRANCH markers, and embedded .kz comments
# all reference filenames and will always differ. We're testing CODE parity.
grep -v '^[[:space:]]*//' explicit_emitted.zig | grep -v '^[[:space:]]*$' > explicit_normalized.zig
grep -v '^[[:space:]]*//' auto_emitted.zig | grep -v '^[[:space:]]*$' > auto_normalized.zig

# --- Compare ---
if diff -u explicit_normalized.zig auto_normalized.zig > emission_diff.txt 2>&1; then
    echo "PASS: Explicit and auto-discharge versions emit identical code"
    exit 0
else
    echo "FAIL: Emission mismatch between explicit and auto-discharge versions"
    echo ""
    echo "Explicit disconnect should produce identical code to auto-discharge."
    echo "The auto-discharge mechanism is not inlining the same way."
    echo ""
    echo "Diff (explicit vs auto):"
    cat emission_diff.txt
    exit 1
fi
