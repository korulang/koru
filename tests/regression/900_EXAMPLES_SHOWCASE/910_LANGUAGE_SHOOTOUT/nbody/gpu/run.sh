#!/bin/bash
set -e
cd "$(dirname "$0")"

ITERATIONS=${1:-1000}
export VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/MoltenVK_icd.json

echo "Compiling shaders..."
glslc -o shaders/pairwise_vel.spv shaders/pairwise_vel.comp
glslc -o shaders/advance_pos.spv shaders/advance_pos.comp
echo "  pairwise_vel.spv"
echo "  advance_pos.spv"

echo "Building host..."
zig build -Doptimize=ReleaseFast

echo "Running ($ITERATIONS iterations)..."
./zig-out/bin/nbody-gpu $ITERATIONS
