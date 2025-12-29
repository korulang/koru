#!/bin/bash
# Build script for Koru TCP echo server

set -e  # Exit on error

echo "Building Koru TCP echo server..."

# Get the Koru project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KORU_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Set up environment
export KORU_STDLIB="$KORU_ROOT/koru_std"
export KORU_PATH="$KORU_ROOT"

# Step 1: Compile .kz to backend.zig
echo "Step 1: Compiling main.kz → main.zig"
"$KORU_ROOT/koruc" main.kz

# Step 2: Run backend to generate output
echo "Step 2: Running backend to generate output_emitted.zig"
zig build-exe \
    --dep emitter \
    --dep ast \
    --dep ast_functional \
    --dep fusion_optimizer.zig \
    -M=main.zig \
    -Memitter="$KORU_ROOT/src/emitter.zig" \
    -Mast="$KORU_ROOT/src/ast.zig" \
    -Mast_functional="$KORU_ROOT/src/ast_functional.zig" \
    -Mfusion_optimizer.zig="$KORU_ROOT/src/fusion_optimizer.zig" \
    -femit-bin=backend
./backend tcp-echo

# Step 3: Compile final executable
echo "Step 3: Compiling final executable"
zig build-exe output_emitted.zig -femit-bin=tcp-echo

echo "✓ Build complete! Run with: ./tcp-echo"
