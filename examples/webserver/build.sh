#!/bin/bash
# Build script for Koru webserver example

set -e  # Exit on error

echo "Building Koru webserver..."

# Get the Koru project root (two directories up from this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KORU_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Set up environment for module resolution
export KORU_STDLIB="$KORU_ROOT/koru_std"
export KORU_PATH="$KORU_ROOT"

# Compile .kz to backend.zig
echo "Step 1: Compiling server.kz → backend.zig"
"$KORU_ROOT/koruc" server.kz -o backend.zig

# Run backend to generate output_emitted.zig
echo "Step 2: Running backend to generate output_emitted.zig"
zig build-exe backend.zig -femit-bin=backend
./backend server

# Compile final executable with all required modules
echo "Step 3: Compiling final executable"
zig build-exe output_emitted.zig \
    --mod "emitter::$KORU_ROOT/src/emitter.zig" \
    --mod "ast::$KORU_ROOT/src/ast.zig" \
    --mod "ast_functional::$KORU_ROOT/src/ast_functional.zig" \
    --mod "fusion_optimizer.zig::$KORU_ROOT/src/fusion_optimizer.zig" \
    --deps emitter,ast,ast_functional,fusion_optimizer.zig \
    -femit-bin=server

echo "✓ Build complete! Run with: ./server"
